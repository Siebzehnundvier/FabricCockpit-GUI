# Fabric-Cost.ps1 - reusable cost query used by the GUI (Fabric-Cockpit.ps1).
# Defines Invoke-FabricCostQuery, which returns an object (no console output),
# with a local cache and 429 retry. Uses the built-in 'az rest'.
# Rows are aggregated per resource; for the Fabric capacity the cost is also
# split into compute (CU meters) and storage (OneLake meters) via FabricMeters.

function Invoke-FabricCostQuery {
    param(
        [string]$Subscription,
        [Parameter(Mandatory)][string]$ResourceGroup,
        [Parameter(Mandatory)][string]$CapacityName,
        [int]$CacheMinutes = 10,
        [switch]$Refresh,
        [string]$TempDir = $env:TEMP
    )
    $result = [ordered]@{
        Ok = $false; FromCache = $false; AsOf = (Get-Date)
        FabricCost = $null; FabricCurrency = ''; Total = $null; Currency = ''
        FabricComputeCost = $null; FabricStorageCost = $null; FabricMeters = @()
        Rows = @(); Throttled = $false; Error = ''
    }

    if (-not [string]::IsNullOrWhiteSpace($Subscription)) {
        $subId = az account show --subscription $Subscription --query id -o tsv 2>$null
    } else {
        $subId = az account show --query id -o tsv 2>$null
    }
    if ([string]::IsNullOrWhiteSpace($subId)) {
        $result.Error = 'Could not determine subscription id (not logged in?).'
        return [pscustomobject]$result
    }

    $scope     = "/subscriptions/$subId/resourceGroups/$ResourceGroup"
    $uri       = "https://management.azure.com$scope/providers/Microsoft.CostManagement/query?api-version=2024-08-01"
    $cacheKey  = ("{0}_{1}" -f $subId, $ResourceGroup) -replace '[^A-Za-z0-9_]', '_'
    $cacheFile = Join-Path $TempDir ("fabcost_cache_v2_{0}.json" -f $cacheKey)

    $rawJson = $null; $fromCache = $false; $asOf = (Get-Date)

    if (-not $Refresh -and (Test-Path $cacheFile)) {
        try {
            $c = Get-Content -LiteralPath $cacheFile -Raw | ConvertFrom-Json
            $ts = [datetime]$c.timestamp
            if (((Get-Date) - $ts).TotalMinutes -lt $CacheMinutes) { $rawJson = $c.response; $fromCache = $true; $asOf = $ts }
        } catch { }
    }

    if (-not $rawJson) {
        $bodyObj = @{
            type      = 'ActualCost'
            timeframe = 'MonthToDate'
            dataset   = @{
                granularity = 'None'
                aggregation = @{ totalCost = @{ name = 'Cost'; function = 'Sum' } }
                grouping    = @(
                    @{ type = 'Dimension'; name = 'ResourceId' },
                    @{ type = 'Dimension'; name = 'Meter' }
                )
            }
        }
        $body = $bodyObj | ConvertTo-Json -Depth 10
        $tmp  = Join-Path $TempDir ("fabcost_{0}.json" -f ([guid]::NewGuid().ToString('N')))
        [System.IO.File]::WriteAllText($tmp, $body)

        $attempts = 3; $waits = @(20, 40); $raw = $null
        for ($i = 1; $i -le $attempts; $i++) {
            $raw = az rest --method post --uri $uri --headers "Content-Type=application/json" --body "@$tmp" 2>&1 | Out-String
            if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($raw) -and $raw -notmatch '429|Too Many Requests|TooManyRequests') { break }
            if ($raw -match '429|Too Many Requests|TooManyRequests' -and $i -lt $attempts) {
                Start-Sleep -Seconds $waits[[math]::Min($i-1, $waits.Count-1)]; continue
            }
            break
        }
        Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue

        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($raw) -or $raw -match '429|Too Many Requests|TooManyRequests') {
            if ($raw -match '429|Too Many Requests|TooManyRequests') { $result.Throttled = $true; $result.Error = 'Rate limited (429).' }
            else { $result.Error = ($raw).Trim() }
            if (Test-Path $cacheFile) {
                try { $c = Get-Content -LiteralPath $cacheFile -Raw | ConvertFrom-Json; $rawJson = $c.response; $fromCache = $true; $asOf = [datetime]$c.timestamp } catch { }
            }
            if (-not $rawJson) { return [pscustomobject]$result }
        } else {
            $rawJson = $raw; $fromCache = $false; $asOf = (Get-Date)
            try { $store = @{ timestamp = (Get-Date).ToString('o'); response = ($raw | Out-String) }; [System.IO.File]::WriteAllText($cacheFile, ($store | ConvertTo-Json -Depth 5)) } catch { }
        }
    }

    try {
        $data = ($rawJson | Out-String) | ConvertFrom-Json
        $q = if ($data.properties) { $data.properties } else { $data }
        $cols = @($q.columns | ForEach-Object { $_.name })
        $ciCost = [array]::IndexOf($cols,'Cost'); if ($ciCost -lt 0) { $ciCost = [array]::IndexOf($cols,'PreTaxCost') }
        $ciRes  = [array]::IndexOf($cols,'ResourceId')
        $ciCur  = [array]::IndexOf($cols,'Currency')
        $ciMet  = [array]::IndexOf($cols,'Meter')

        # one row per (ResourceId, Meter) -> aggregate per resource, keep the
        # meters of the Fabric capacity for the compute/storage split
        $byRes = [ordered]@{}
        $meters = @()
        if ($ciCost -ge 0 -and $q.rows) {
            foreach ($r in $q.rows) {
                $resId = if ($ciRes -ge 0) { [string]$r[$ciRes] } else { '' }
                $cost  = [double]$r[$ciCost]
                $cur   = if ($ciCur -ge 0) { [string]$r[$ciCur] } else { '' }
                $meter = if ($ciMet -ge 0) { [string]$r[$ciMet] } else { '' }
                $isFab = ($resId -like "*/Microsoft.Fabric/capacities/$CapacityName")
                if (-not $byRes.Contains($resId)) {
                    $byRes[$resId] = [pscustomobject]@{
                        Resource = if ($resId) { ($resId -split '/')[-1] } else { '(total)' }
                        Cost     = 0.0
                        Currency = $cur
                        IsFabric = $isFab
                    }
                }
                $byRes[$resId].Cost += $cost
                if ($isFab) {
                    $meters += [pscustomobject]@{
                        Meter     = $meter
                        Cost      = [math]::Round($cost,2)
                        Currency  = $cur
                        # stored-data meters (e.g. 'OneLake Storage Hot Data Stored', BCDR) count as
                        # storage; anything billed in CU (incl. OneLake read/write ops) is compute
                        IsStorage = ($meter -match 'OneLake|Storage' -and $meter -notmatch 'Capacity Usage|CU')
                    }
                }
            }
        }
        $rows = @($byRes.Values | ForEach-Object { $_.Cost = [math]::Round($_.Cost,2); $_ })
        $result.Rows = $rows
        $result.FabricMeters = $meters
        $fab = $rows | Where-Object IsFabric | Select-Object -First 1
        if ($fab) {
            $result.FabricCost = $fab.Cost; $result.FabricCurrency = $fab.Currency
            if ($ciMet -ge 0) {
                $sto = ($meters | Where-Object IsStorage      | Measure-Object Cost -Sum).Sum
                $cmp = ($meters | Where-Object { -not $_.IsStorage } | Measure-Object Cost -Sum).Sum
                $result.FabricStorageCost = [math]::Round([double]$sto,2)
                $result.FabricComputeCost = [math]::Round([double]$cmp,2)
            }
        }
        $result.Total = if ($rows -and $rows.Count -gt 0) { [math]::Round((($rows | Measure-Object Cost -Sum).Sum),2) } else { 0 }
        if ($rows -and $rows.Count -gt 0 -and $rows[0].Currency) { $result.Currency = $rows[0].Currency }
        $result.Ok = $true; $result.FromCache = $fromCache; $result.AsOf = $asOf
    } catch {
        $result.Error = "Parse error: $($_.Exception.Message)"
    }
    return [pscustomobject]$result
}
