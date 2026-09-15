# Fabric-Common.ps1 - shared helpers for the Fabric capacity cockpit (GUI).
# Dot-sourced by Fabric-Cockpit.ps1 and by the background runspaces it starts.
# Pure functions only - no UI, no console output. ASCII-only on purpose
# (Windows PowerShell 5.1 reads BOM-less files as ANSI).

$ErrorActionPreference = 'Stop'

# ---------- settings (%APPDATA%\FabricCockpit\settings.json) ----------

function Get-CockpitSettingsPath {
    return (Join-Path (Join-Path $env:APPDATA 'FabricCockpit') 'settings.json')
}

function Get-CockpitSettings {
    # Returns a hashtable with all keys present; missing/unreadable file -> defaults.
    $d = [ordered]@{
        lastCapacity         = @{ subscriptionId = ''; resourceGroup = ''; name = '' }
        autoRefreshSeconds   = 30
        metricsAppUrl        = ''
        capacityCache        = @()
        capacityCacheUpdated = ''
    }
    $p = Get-CockpitSettingsPath
    if (Test-Path -LiteralPath $p) {
        try {
            $j = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($k in @($d.Keys)) {
                if ($j.PSObject.Properties.Name -contains $k -and $null -ne $j.$k) { $d[$k] = $j.$k }
            }
            if ($d.lastCapacity -isnot [hashtable]) {
                $lc = $d.lastCapacity
                $d.lastCapacity = @{ subscriptionId = [string]$lc.subscriptionId; resourceGroup = [string]$lc.resourceGroup; name = [string]$lc.name }
            }
            $d.capacityCache = @($d.capacityCache)
        } catch { }
    }
    if ([int]$d.autoRefreshSeconds -lt 5) { $d.autoRefreshSeconds = 30 }
    return $d
}

function Save-CockpitSettings {
    param([Parameter(Mandatory)]$Settings)
    $p = Get-CockpitSettingsPath
    $dir = Split-Path -Parent $p
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    $json = $Settings | ConvertTo-Json -Depth 6
    [System.IO.File]::WriteAllText($p, $json, (New-Object System.Text.UTF8Encoding($false)))
}

# ---------- az CLI ----------

function Invoke-Az {
    # Runs az with the given arguments, merges stderr, returns exit code + text.
    param([Parameter(Mandatory)][string[]]$Arguments)
    $out = (& az @Arguments 2>&1 | Out-String)
    return [pscustomobject]@{ Exit = $LASTEXITCODE; Out = $out; Args = ($Arguments -join ' ') }
}

function Test-AzAvailable {
    return [bool](Get-Command az -ErrorAction SilentlyContinue)
}

function Ensure-FabricExtension {
    # Returns $true if the microsoft-fabric extension is present (installs it once if missing).
    $ext = az extension list --query "[?name=='microsoft-fabric'].name" -o tsv 2>$null
    if ($ext) { return $true }
    az extension add --name microsoft-fabric --only-show-errors 2>&1 | Out-Null
    $ext = az extension list --query "[?name=='microsoft-fabric'].name" -o tsv 2>$null
    return [bool]$ext
}

function Test-AuthError {
    # True if an az error text looks like a missing / expired sign-in.
    # Patterns are deliberately generous (spec 6.4): better to ask for a login
    # than to leave the user with empty fields.
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    $p = 'az login|AADSTS|ExpiredToken|ExpiredAuthenticationToken|InvalidAuthenticationToken|' +
         're-?authenticate|Interactive authentication is needed|refresh token|AuthenticationFailed|' +
         'not logged in|Please run .?az login|token has expired|Authorization failed'
    return [bool]($Text -imatch $p)
}

function Get-AzAccountInfo {
    # az account show -> signed-in user / tenant / default subscription.
    $r = Invoke-Az @('account','show','-o','json','--only-show-errors')
    $res = [pscustomobject]@{ LoggedIn = $false; User = ''; TenantId = ''; SubscriptionName = ''; SubscriptionId = ''; Error = '' }
    if ($r.Exit -ne 0 -or [string]::IsNullOrWhiteSpace($r.Out)) { $res.Error = $r.Out.Trim(); return $res }
    try {
        $a = $r.Out | ConvertFrom-Json
        $res.LoggedIn = $true
        $res.User = [string]$a.user.name
        $res.TenantId = [string]$a.tenantId
        $res.SubscriptionName = [string]$a.name
        $res.SubscriptionId = [string]$a.id
    } catch { $res.Error = $r.Out.Trim() }
    return $res
}

# ---------- capacities ----------

function ConvertTo-CapacityRecord {
    # Normalises an 'az fabric capacity list/show' item into the record the GUI and cache use.
    param($Item, [string]$SubscriptionId, [string]$SubscriptionName)
    $rg = [string]$Item.resourceGroup
    if (-not $rg -and $Item.id) { $rg = ((([string]$Item.id) -split '/resourceGroups/')[1] -split '/')[0] }
    return [pscustomobject]@{
        name              = [string]$Item.name
        id                = [string]$Item.id
        subscriptionId    = $SubscriptionId
        subscriptionName  = $SubscriptionName
        resourceGroup     = $rg
        location          = [string]$Item.location
        sku               = [string]$Item.sku.name
        state             = [string]$Item.state
        provisioningState = [string]$Item.provisioningState
    }
}

function Get-FabricCapacityList {
    # Iterates all enabled subscriptions and lists Fabric capacities with
    # 'az fabric capacity list' (returns state/sku/location - unlike 'az resource list').
    # Returns Items (sorted by name), Log (lines) and Errors (lines).
    $log = @(); $errors = @(); $items = @()
    $rs = Invoke-Az @('account','list','--all','--query',"[?state=='Enabled'].{id:id,name:name}",'-o','json','--only-show-errors')
    if ($rs.Exit -ne 0) {
        return [pscustomobject]@{ Ok = $false; Items = @(); Log = $log; Errors = @($rs.Out.Trim()); AuthError = (Test-AuthError $rs.Out) }
    }
    $subs = @()
    try { $subs = @($rs.Out | ConvertFrom-Json) } catch { }
    $log += ("Capacity list: {0} enabled subscription(s), via 'az fabric capacity list' per subscription." -f $subs.Count)
    foreach ($s in $subs) {
        $rc = Invoke-Az @('fabric','capacity','list','--subscription',$s.id,'-o','json','--only-show-errors')
        if ($rc.Exit -ne 0) {
            $errors += ("{0}: {1}" -f $s.name, $rc.Out.Trim())
            if (Test-AuthError $rc.Out) {
                return [pscustomobject]@{ Ok = $false; Items = @(); Log = $log; Errors = $errors; AuthError = $true }
            }
            continue
        }
        try {
            $arr = @($rc.Out | ConvertFrom-Json)
            foreach ($c in $arr) { $items += (ConvertTo-CapacityRecord -Item $c -SubscriptionId $s.id -SubscriptionName $s.name) }
            $log += ("  {0}: {1} capacity(ies)" -f $s.name, $arr.Count)
        } catch { $errors += ("{0}: parse error - {1}" -f $s.name, $_.Exception.Message) }
    }
    $items = @($items | Sort-Object name, subscriptionName, resourceGroup)
    return [pscustomobject]@{ Ok = $true; Items = $items; Log = $log; Errors = $errors; AuthError = $false }
}

function Get-FabricCapacityStatus {
    # 'az fabric capacity show' for one capacity -> record or error.
    param([Parameter(Mandatory)][string]$SubscriptionId,
          [Parameter(Mandatory)][string]$ResourceGroup,
          [Parameter(Mandatory)][string]$CapacityName,
          [string]$SubscriptionName = '')
    $r = Invoke-Az @('fabric','capacity','show','--subscription',$SubscriptionId,'--resource-group',$ResourceGroup,'--capacity-name',$CapacityName,'-o','json','--only-show-errors')
    if ($r.Exit -ne 0 -or [string]::IsNullOrWhiteSpace($r.Out)) {
        return [pscustomobject]@{ Ok = $false; Error = $r.Out.Trim(); AuthError = (Test-AuthError $r.Out); Item = $null }
    }
    try {
        $c = $r.Out | ConvertFrom-Json
        return [pscustomobject]@{ Ok = $true; Error = ''; AuthError = $false; Item = (ConvertTo-CapacityRecord -Item $c -SubscriptionId $SubscriptionId -SubscriptionName $SubscriptionName) }
    } catch {
        return [pscustomobject]@{ Ok = $false; Error = "Parse error: $($_.Exception.Message)"; AuthError = $false; Item = $null }
    }
}

function Invoke-FabricCapacityAction {
    # suspend | resume with --no-wait; the caller polls the state afterwards.
    # Verified 2026-09-13 (az 2.90.0, microsoft-fabric 1.0.0b1, api-version 2023-11-01):
    # without --no-wait the CLI itself blocks until the target state is reached.
    param([Parameter(Mandatory)][ValidateSet('suspend','resume')][string]$Action,
          [Parameter(Mandatory)][string]$SubscriptionId,
          [Parameter(Mandatory)][string]$ResourceGroup,
          [Parameter(Mandatory)][string]$CapacityName)
    $r = Invoke-Az @('fabric','capacity',$Action,'--subscription',$SubscriptionId,'--resource-group',$ResourceGroup,'--capacity-name',$CapacityName,'--no-wait','--only-show-errors')
    return [pscustomobject]@{ Ok = ($r.Exit -eq 0); Error = $r.Out.Trim(); AuthError = (Test-AuthError $r.Out); Command = ('az ' + $r.Args) }
}

# ---------- links ----------

function Get-FabricLinks {
    # Portal overview of the capacity, RG-scoped cost analysis, Metrics app (or Apps page).
    param([Parameter(Mandatory)]$Capacity, [string]$MetricsAppUrl = '')
    $resId   = $Capacity.id
    if (-not $resId) { $resId = "/subscriptions/$($Capacity.subscriptionId)/resourceGroups/$($Capacity.resourceGroup)/providers/Microsoft.Fabric/capacities/$($Capacity.name)" }
    $rgScope = "/subscriptions/$($Capacity.subscriptionId)/resourceGroups/$($Capacity.resourceGroup)"
    $encRg   = [uri]::EscapeDataString($rgScope)
    $metrics = if (-not [string]::IsNullOrWhiteSpace($MetricsAppUrl)) { $MetricsAppUrl } else { 'https://app.powerbi.com/groups/me/apps' }
    return [pscustomobject]@{
        Portal  = "https://portal.azure.com/#@/resource$resId/overview"
        Cost    = "https://portal.azure.com/#view/Microsoft_Azure_CostManagement/Menu/~/costanalysis/scope/$encRg"
        Metrics = $metrics
    }
}
