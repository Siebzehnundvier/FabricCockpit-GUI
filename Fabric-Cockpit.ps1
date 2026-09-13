#Requires -Version 5.1
# Fabric Capacity Cockpit - WinForms GUI (colours/fonts matched to the post graphic;
# only styling that plain WinForms can actually render).
# Uses .\config.json and the helpers in .\lib\ (Fabric-Common.ps1 / Fabric-Cost.ps1 / Open-Links.ps1).
# Launch via Start-Cockpit.cmd (starts PowerShell in STA mode).

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$libDir      = Join-Path $PSScriptRoot 'lib'
$common      = Join-Path $libDir 'Fabric-Common.ps1'
$costFunc    = Join-Path $libDir 'Fabric-Cost.ps1'
$linksScript = Join-Path $libDir 'Open-Links.ps1'

try {
    . $common
    $cfg = Get-FabricConfig
} catch {
    [System.Windows.Forms.MessageBox]::Show("Startup failed:`n$($_.Exception.Message)", 'Fabric Cockpit', 'OK', 'Error') | Out-Null
    return
}

$subDisplay = $cfg.subscription
if ([string]::IsNullOrWhiteSpace($subDisplay)) { $subDisplay = '(default from az login)' }

$script:Busy = $false

# ---------- palette (matches the graphic) ----------
function C([int]$r,[int]$g,[int]$b){ [System.Drawing.Color]::FromArgb($r,$g,$b) }
$clBg     = C 238 240 242   # window body  #eef0f2
$clCard   = C 248 249 251   # info card    #f8f9fb
$clBorder = C 195 201 208   # #c3c9d0
$clInk    = C 31 41 55      # values       #1f2937
$clMuted  = C 91 102 117    # captions     #5b6675
$clLegend = C 42 52 65      # #2a3441
$clBtnBg  = C 228 231 235   # #e4e7eb
$clBtnTxt = C 42 52 65      # #2a3441
$clGreen  = C 21 128 61     # #15803d
$clAmber  = C 180 83 9      # #b45309
$clLogBg  = C 17 17 17      # #111
$clLogFg  = C 212 212 212   # #d4d4d4

$fCap    = New-Object System.Drawing.Font('Segoe UI', 10.5)
$fVal    = New-Object System.Drawing.Font('Segoe UI', 10.5, [System.Drawing.FontStyle]::Bold)
$fLegend = New-Object System.Drawing.Font('Segoe UI', 9.75, [System.Drawing.FontStyle]::Bold)
$fBtn    = New-Object System.Drawing.Font('Segoe UI', 9.75, [System.Drawing.FontStyle]::Bold)
$fMono   = New-Object System.Drawing.Font('Consolas', 9)

# ---------- Work blocks (background runspace) ----------
$statusWork = {
    param($rg,$cap,$sub)
    $a = @('fabric','capacity','show','--resource-group',$rg,'--capacity-name',$cap)
    if ($sub) { $a += @('--subscription',$sub) }
    $a += @('-o','json')
    $out = (& az @a 2>&1 | Out-String)
    [pscustomobject]@{ Exit = $LASTEXITCODE; Json = $out; Out = $out }
}
$suspendWork = {
    param($rg,$cap,$sub)
    $a = @('fabric','capacity','suspend','--resource-group',$rg,'--capacity-name',$cap)
    if ($sub) { $a += @('--subscription',$sub) }
    $a += @('--only-show-errors')
    $out = (& az @a 2>&1 | Out-String)
    [pscustomobject]@{ Exit = $LASTEXITCODE; Out = $out }
}
$resumeWork = {
    param($rg,$cap,$sub)
    $a = @('fabric','capacity','resume','--resource-group',$rg,'--capacity-name',$cap)
    if ($sub) { $a += @('--subscription',$sub) }
    $a += @('--only-show-errors')
    $out = (& az @a 2>&1 | Out-String)
    [pscustomobject]@{ Exit = $LASTEXITCODE; Out = $out }
}
$costWork = {
    param($funcPath,$sub,$rg,$cap,$cacheMin,$tempDir)
    . $funcPath
    Invoke-FabricCostQuery -Subscription $sub -ResourceGroup $rg -CapacityName $cap -CacheMinutes $cacheMin -TempDir $tempDir
}
$linkWork = {
    param($scriptPath,$target)
    $o = (& powershell -NoProfile -ExecutionPolicy Bypass -File $scriptPath -Target $target 2>&1 | Out-String)
    [pscustomobject]@{ Exit = $LASTEXITCODE; Out = $o }
}

# ---------- form ----------
$form = New-Object System.Windows.Forms.Form
$form.Text          = 'Fabric Capacity Cockpit'
$form.Size          = New-Object System.Drawing.Size(620, 668)
$form.StartPosition = 'CenterScreen'
$form.BackColor     = $clBg
$form.Font          = $fCap
$form.MinimumSize   = New-Object System.Drawing.Size(580, 600)

# ---------- info card ----------
$card = New-Object System.Windows.Forms.Panel
$card.Location = New-Object System.Drawing.Point(16,14)
$card.Size = New-Object System.Drawing.Size(404,224)
$card.BackColor = $clCard
$card.BorderStyle = 'None'
$card.Add_Paint({ param($s,$e)
    $pen = New-Object System.Drawing.Pen $clBorder
    $e.Graphics.DrawRectangle($pen, 0, 0, $s.Width-1, $s.Height-1)
    $pen.Dispose()
})
$form.Controls.Add($card)

$legend = New-Object System.Windows.Forms.Label
$legend.Text = 'Capacity Info'; $legend.Font = $fLegend; $legend.ForeColor = $clLegend
$legend.Location = New-Object System.Drawing.Point(12,8); $legend.AutoSize = $true
$card.Controls.Add($legend)

function New-Caption([string]$text,[int]$y) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text; $l.ForeColor = $clMuted; $l.Font = $fCap
    $l.Location = New-Object System.Drawing.Point(14,$y)
    $l.Size = New-Object System.Drawing.Size(128,22)
    $card.Controls.Add($l); return $l
}
function New-Value([int]$y) {
    $l = New-Object System.Windows.Forms.Label
    $l.ForeColor = $clInk; $l.Font = $fVal
    $l.Location = New-Object System.Drawing.Point(148,$y)
    $l.Size = New-Object System.Drawing.Size(244,22)
    $card.Controls.Add($l); return $l
}

$y = 34; $step = 26
New-Caption 'Name'           $y | Out-Null; $lblName   = New-Value $y; $y += $step
New-Caption 'Subscription'   $y | Out-Null; $lblSub    = New-Value $y; $y += $step
New-Caption 'Resource group' $y | Out-Null; $lblRg     = New-Value $y; $y += $step
New-Caption 'Region'         $y | Out-Null; $lblRegion = New-Value $y; $y += $step
New-Caption 'SKU'            $y | Out-Null; $lblSku    = New-Value $y; $y += $step
New-Caption 'Status'         $y | Out-Null; $lblStatus = New-Value $y; $y += $step
New-Caption 'Cost (MTD)'     $y | Out-Null; $lblCost   = New-Value $y; $y += $step

$lblName.Text = $cfg.capacityName
$lblSub.Text  = $subDisplay
$lblRg.Text   = $cfg.resourceGroup
$lblSku.Text  = $cfg.sku
$lblCost.Text = '(loading ...)'

# ---------- buttons ----------
function New-FlatButton([string]$text,[int]$x,[int]$y,[int]$w,[int]$h,$fore) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text
    $b.Location = New-Object System.Drawing.Point($x,$y)
    $b.Size = New-Object System.Drawing.Size($w,$h)
    $b.FlatStyle = 'Flat'
    $b.BackColor = $clBtnBg; $b.ForeColor = $fore
    $b.FlatAppearance.BorderColor = $clBorder
    $b.FlatAppearance.BorderSize = 1
    $b.Font = $fBtn
    $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    $form.Controls.Add($b); return $b
}

# right column (card ends x=420; margin, then column, then ~16px to the right edge)
$btnRefresh = New-FlatButton 'Refresh' 436 14 150 30 $clBtnTxt

$chkAuto = New-Object System.Windows.Forms.CheckBox
$chkAuto.Text = 'Auto-refresh (30s)'; $chkAuto.ForeColor = $clInk; $chkAuto.Font = $fCap
$chkAuto.Location = New-Object System.Drawing.Point(436,52)
$chkAuto.Size = New-Object System.Drawing.Size(168,24)
$form.Controls.Add($chkAuto)

$lblUpdated = New-Object System.Windows.Forms.Label
$lblUpdated.Text = 'Updated: -'; $lblUpdated.ForeColor = $clMuted; $lblUpdated.Font = $fCap
$lblUpdated.Location = New-Object System.Drawing.Point(436,84); $lblUpdated.Size = New-Object System.Drawing.Size(168,22)
$form.Controls.Add($lblUpdated)

# capacity actions
$lblActions = New-Object System.Windows.Forms.Label
$lblActions.Text = 'Capacity actions:'; $lblActions.ForeColor = $clMuted; $lblActions.Font = $fLegend
$lblActions.Location = New-Object System.Drawing.Point(18,250); $lblActions.AutoSize = $true
$form.Controls.Add($lblActions)

$btnResume = New-FlatButton 'Resume' 18  272 120 30 $clGreen
$btnPause  = New-FlatButton 'Pause'  146 272 120 30 $clAmber

# links
$lblOpen = New-Object System.Windows.Forms.Label
$lblOpen.Text = 'Open:'; $lblOpen.ForeColor = $clMuted; $lblOpen.Font = $fLegend
$lblOpen.Location = New-Object System.Drawing.Point(18,314); $lblOpen.AutoSize = $true
$form.Controls.Add($lblOpen)

$btnPortal  = New-FlatButton 'Capacity Overview' 18  336 168 30 $clBtnTxt
$btnCostA   = New-FlatButton 'Accumulated Cost (RG)' 194 336 178 30 $clBtnTxt
$btnMetrics = New-FlatButton 'Metrics App' 380 336 130 30 $clBtnTxt

$tt = New-Object System.Windows.Forms.ToolTip
$tt.SetToolTip($btnPortal,  'Azure portal: overview page of the Fabric capacity')
$tt.SetToolTip($btnCostA,   'Cost analysis (accumulated) for the resource group')
$tt.SetToolTip($btnMetrics, 'Opens the Fabric Capacity Metrics app directly')

# log
$lblLog = New-Object System.Windows.Forms.Label
$lblLog.Text = 'Log'; $lblLog.ForeColor = $clMuted; $lblLog.Font = $fLegend
$lblLog.Location = New-Object System.Drawing.Point(18,378); $lblLog.AutoSize = $true
$form.Controls.Add($lblLog)

$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Multiline = $true; $txtLog.ScrollBars = 'Vertical'; $txtLog.ReadOnly = $true
$txtLog.BorderStyle = 'FixedSingle'
$txtLog.BackColor = $clLogBg; $txtLog.ForeColor = $clLogFg; $txtLog.Font = $fMono
$txtLog.Location = New-Object System.Drawing.Point(16,398)
$txtLog.Size = New-Object System.Drawing.Size(570,205)
$txtLog.Anchor = 'Top,Bottom,Left,Right'
$form.Controls.Add($txtLog)

# ---------- helpers ----------
function Write-Log([string]$msg) {
    $ts = (Get-Date).ToString('HH:mm:ss')
    $txtLog.AppendText("[$ts] $msg`r`n")
}
function Set-Busy([bool]$b) {
    $script:Busy = $b
    foreach ($c in @($btnRefresh,$btnResume,$btnPause,$btnPortal,$btnCostA,$btnMetrics)) { $c.Enabled = -not $b }
    $form.Cursor = if ($b) { [System.Windows.Forms.Cursors]::AppStarting } else { [System.Windows.Forms.Cursors]::Default }
}
function Start-Async {
    param([scriptblock]$Work, [object[]]$WorkArgs, [scriptblock]$OnDone)
    Set-Busy $true
    $ps = [powershell]::Create()
    [void]$ps.AddScript($Work)
    foreach ($a in $WorkArgs) { [void]$ps.AddArgument($a) }
    $handle = $ps.BeginInvoke()
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 250
    $tick = {
        if ($handle.IsCompleted) {
            $timer.Stop()
            try { $result = $ps.EndInvoke($handle) }
            catch { $result = @([pscustomobject]@{ Exit = -1; Out = $_.Exception.Message; Json = ''; Ok = $false; Error = $_.Exception.Message }) }
            $ps.Dispose(); $timer.Dispose()
            Set-Busy $false
            & $OnDone $result
        }
    }.GetNewClosure()
    $timer.Add_Tick($tick)
    $timer.Start()
}

function Invoke-CostRefresh {
    $lblCost.ForeColor = $clInk
    Start-Async -Work $costWork -WorkArgs @($costFunc,$cfg.subscription,$cfg.resourceGroup,$cfg.capacityName,10,$env:TEMP) -OnDone {
        param($res); $r = $res[0]
        if (-not $r) { $lblCost.Text = '(error)'; return }
        if (-not $r.Ok) {
            if ($r.Throttled) { $lblCost.Text = 'rate-limited (429) - retry later'; $lblCost.ForeColor = $clAmber }
            else { $lblCost.Text = 'n/a'; $lblCost.ForeColor = [System.Drawing.Color]::Firebrick }
            if ($r.Error) { Write-Log ("Cost: {0}" -f $r.Error) }
            return
        }
        if ($null -ne $r.FabricCost) {
            $suffix = if ($r.FromCache) { (' (cached {0:HH:mm})' -f $r.AsOf) } else { '' }
            $lblCost.Text = ('{0} {1}{2}' -f $r.FabricCost, $r.FabricCurrency, $suffix)
        } elseif (-not $r.Rows -or $r.Rows.Count -eq 0) {
            $lblCost.Text = 'no data yet (latency ~24-48h)'
        } else {
            $lblCost.Text = ('n/a for capacity; RG total {0} {1}' -f $r.Total, $r.Currency)
        }
    }
}

$onStatus = {
    param($res)
    $r = $res[0]
    if (-not $r -or $r.Exit -ne 0) {
        $lblStatus.Text = '(error)'; $lblStatus.ForeColor = [System.Drawing.Color]::Firebrick
        Write-Log ("Status query failed: {0}" -f ($r.Out).Trim())
        Invoke-CostRefresh
        return
    }
    try {
        $c = $r.Json | ConvertFrom-Json
        $state = $null; $prov = $null
        if ($c.PSObject.Properties.Name -contains 'properties' -and $c.properties) {
            $state = $c.properties.state; $prov = $c.properties.provisioningState
        }
        if ([string]::IsNullOrWhiteSpace($state)) { $state = $c.state }
        if ([string]::IsNullOrWhiteSpace($prov))  { $prov  = $c.provisioningState }
        if ([string]::IsNullOrWhiteSpace($state)) { $state = '(unknown)' }
        if ([string]::IsNullOrWhiteSpace($prov))  { $prov  = '(unknown)' }

        $lblName.Text   = $c.name
        $lblRegion.Text = $c.location
        $lblSku.Text    = $c.sku.name
        $lblStatus.Text = $state
        $lblStatus.ForeColor = if ($state -eq 'Active') { $clGreen } elseif ($state -eq 'Paused') { $clAmber } else { $clMuted }
        $lblUpdated.Text = ('Updated: {0}' -f (Get-Date).ToString('HH:mm:ss'))
        Write-Log ("Status: {0} | SKU {1} | Provisioning {2}" -f $state, $c.sku.name, $prov)
    } catch {
        Write-Log ("Parse error: {0}" -f $_.Exception.Message)
    }
    Invoke-CostRefresh
}

function Invoke-StatusRefresh {
    Write-Log 'Refreshing status ...'
    Start-Async -Work $statusWork -WorkArgs @($cfg.resourceGroup,$cfg.capacityName,$cfg.subscription) -OnDone $onStatus
}

# ---------- handlers ----------
$btnRefresh.Add_Click({ if (-not $script:Busy) { Invoke-StatusRefresh } })

$btnResume.Add_Click({
    if ($script:Busy) { return }
    $r = [System.Windows.Forms.MessageBox]::Show("Resume capacity '$($cfg.capacityName)'?", 'Confirm resume', 'YesNo', 'Question')
    if ($r -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    Write-Log 'Resuming ...'
    Start-Async -Work $resumeWork -WorkArgs @($cfg.resourceGroup,$cfg.capacityName,$cfg.subscription) -OnDone {
        param($res); $x = $res[0]
        if ($x.Exit -eq 0) { Write-Log 'Resume OK.' } else { Write-Log ("Resume failed: {0}" -f ($x.Out).Trim()) }
        Invoke-StatusRefresh
    }
})

$btnPause.Add_Click({
    if ($script:Busy) { return }
    $r = [System.Windows.Forms.MessageBox]::Show("Pause capacity '$($cfg.capacityName)'?", 'Confirm pause', 'YesNo', 'Warning')
    if ($r -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    Write-Log 'Pausing ...'
    Start-Async -Work $suspendWork -WorkArgs @($cfg.resourceGroup,$cfg.capacityName,$cfg.subscription) -OnDone {
        param($res); $x = $res[0]
        if ($x.Exit -eq 0) { Write-Log 'Pause OK.' } else { Write-Log ("Pause failed: {0}" -f ($x.Out).Trim()) }
        Invoke-StatusRefresh
    }
})

function Open-Link([string]$target,[string]$label) {
    if ($script:Busy) { return }
    Write-Log ("Opening {0} ..." -f $label)
    Start-Async -Work $linkWork -WorkArgs @($linksScript,$target) -OnDone {
        param($res); $x = $res[0]
        $msg = ($x.Out).Trim(); if ($msg) { Write-Log $msg }
    }
}
$btnPortal.Add_Click({  Open-Link 'portal'  'capacity overview' })
$btnCostA.Add_Click({   Open-Link 'cost'    'accumulated cost' })
$btnMetrics.Add_Click({ Open-Link 'metrics' 'Metrics app' })

# ---------- auto-refresh ----------
$autoTimer = New-Object System.Windows.Forms.Timer
$autoTimer.Interval = 30000
$autoTimer.Add_Tick({ if (-not $script:Busy) { Invoke-StatusRefresh } })
$chkAuto.Add_CheckedChanged({ if ($chkAuto.Checked) { $autoTimer.Start() } else { $autoTimer.Stop() } })
$chkAuto.Checked = $true

# ---------- startup ----------
$form.Add_Shown({
    try { Assert-Az; Assert-LoggedIn; Write-Log 'Signed in - loading status.' }
    catch { Write-Log ("Warning: {0}" -f $_.Exception.Message) }
    Invoke-StatusRefresh
    $autoTimer.Start()
})

[void]$form.ShowDialog()
$autoTimer.Stop(); $autoTimer.Dispose()
