#Requires -Version 5.1
# Fabric Capacity Cockpit - WinForms GUI for pay-as-you-go Fabric capacities (F-SKU).
# Features: capacity picker across all subscriptions, sign-in status + az login,
# pause/resume with state polling, auto-pause after cockpit inactivity, MTD cost.
# Tested on Windows PowerShell 5.1 only (the launcher uses powershell.exe -STA).
# Uses .\lib\Fabric-Common.ps1 (settings, az calls) and .\lib\Fabric-Cost.ps1 (cost query).
# Settings live in %APPDATA%\FabricCockpit\settings.json (no secrets).
# File is ASCII-only on purpose: PS 5.1 reads BOM-less files as ANSI. Non-ASCII glyphs
# are built with [char].

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$libDir   = Join-Path $PSScriptRoot 'lib'
$common   = Join-Path $libDir 'Fabric-Common.ps1'
$costFunc = Join-Path $libDir 'Fabric-Cost.ps1'

try { . $common } catch {
    [System.Windows.Forms.MessageBox]::Show("Startup failed:`n$($_.Exception.Message)", 'Fabric Cockpit', 'OK', 'Error') | Out-Null
    return
}

# ComboBox needs a CLR type with ToString() for display (PSCustomObject would show its type name).
Add-Type -TypeDefinition @"
public class FabricCapacityItem {
    public string Key;
    public string Display;
    public object Record;
    public override string ToString() { return Display; }
}
"@

# ---------- glyphs ----------
$chCheck = [string][char]0x2714   # heavy check mark
$chCross = [string][char]0x2716   # heavy multiplication x
$chDash  = [string][char]0x2014   # em dash
$chDot   = [string][char]0x00B7   # middle dot
$chInfo  = [string][char]0x2139   # information source

# ---------- state ----------
$S = @{
    settings    = (Get-CockpitSettings)
    azOk        = (Test-AzAvailable)
    loggedIn    = $false
    account     = $null
    selected    = $null      # capacity record of the picked capacity
    status      = ''         # last known state of the picked capacity
    statusBusy  = $false
    listBusy    = $false
    loginBusy   = $false
    loading     = $false     # combo is being repopulated
    op          = ''         # '' | 'pause' | 'resume'
    opTarget    = ''
    opVerb      = ''
    opStart     = (Get-Date)
    opLastState = ''
    pollBusy    = $false
    idleSince   = (Get-Date)
    autoPauseOff = $false    # 'disable for today' (until restart)
    apValues    = @(0,15,30,60,120)   # minutes per auto-pause combo index
}
$U = @{}   # controls
$T = @{}   # timers

# ---------- palette (matches the post graphic) ----------
function C([int]$r,[int]$g,[int]$b){ [System.Drawing.Color]::FromArgb($r,$g,$b) }
$clBg     = C 238 240 242
$clCard   = C 248 249 251
$clBorder = C 195 201 208
$clInk    = C 31 41 55
$clMuted  = C 91 102 117
$clLegend = C 42 52 65
$clBtnBg  = C 228 231 235
$clBtnTxt = C 42 52 65
$clGreen  = C 21 128 61
$clAmber  = C 180 83 9
$clRed    = C 178 34 34
$clWarnBg = C 255 243 205
$clLogBg  = C 17 17 17
$clLogFg  = C 212 212 212

$fCap    = New-Object System.Drawing.Font('Segoe UI', 10.5)
$fVal    = New-Object System.Drawing.Font('Segoe UI', 10.5, [System.Drawing.FontStyle]::Bold)
$fLegend = New-Object System.Drawing.Font('Segoe UI', 9.75, [System.Drawing.FontStyle]::Bold)
$fBtn    = New-Object System.Drawing.Font('Segoe UI', 9.75, [System.Drawing.FontStyle]::Bold)
$fSmall  = New-Object System.Drawing.Font('Segoe UI', 9)
$fMono   = New-Object System.Drawing.Font('Consolas', 9)

# ---------- work blocks (run in background runspaces) ----------
$wAccount = { param($lib) . $lib; $ext = Ensure-FabricExtension; [pscustomobject]@{ Account = (Get-AzAccountInfo); ExtOk = $ext } }
$wLogin   = { param($lib) . $lib; $r = Invoke-Az @('login','-o','none','--only-show-errors'); [pscustomobject]@{ Exit = $r.Exit; Out = $r.Out; Account = (Get-AzAccountInfo) } }
$wList    = { param($lib) . $lib; Get-FabricCapacityList }
$wStatus  = { param($lib,$sub,$rg,$name,$subName) . $lib; Get-FabricCapacityStatus -SubscriptionId $sub -ResourceGroup $rg -CapacityName $name -SubscriptionName $subName }
$wAction  = { param($lib,$action,$sub,$rg,$name) . $lib; Invoke-FabricCapacityAction -Action $action -SubscriptionId $sub -ResourceGroup $rg -CapacityName $name }
$wCost    = { param($costPath,$sub,$rg,$name,$tempDir) . $costPath; Invoke-FabricCostQuery -Subscription $sub -ResourceGroup $rg -CapacityName $name -CacheMinutes 10 -TempDir $tempDir }

# ---------- form ----------
$form = New-Object System.Windows.Forms.Form
$form.Text          = 'Fabric Capacity Cockpit ' + $chDash + ' Pay-as-you-go (F-SKU)'
$form.ClientSize    = New-Object System.Drawing.Size(720, 760)
$form.MinimumSize   = New-Object System.Drawing.Size(736, 700)
$form.StartPosition = 'CenterScreen'
$form.BackColor     = $clBg
$form.Font          = $fCap

$root = New-Object System.Windows.Forms.TableLayoutPanel
$root.Dock = 'Fill'; $root.ColumnCount = 1; $root.RowCount = 10
$root.Padding = New-Object System.Windows.Forms.Padding(0)
[void]$root.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
$form.Controls.Add($root)

$rowHeights = @(36, 36, 252, 44, 0, 42, 26, 26, -1, 56)   # -1 = fill; banner row (index 4) is 0 until shown
$rows = @()
for ($i = 0; $i -lt $rowHeights.Count; $i++) {
    $h = $rowHeights[$i]
    if ($h -lt 0) { [void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100))) }
    else          { [void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, $h))) }
    $p = New-Object System.Windows.Forms.Panel
    $p.Dock = 'Fill'; $p.Margin = New-Object System.Windows.Forms.Padding(0); $p.BackColor = $clBg
    $root.Controls.Add($p, 0, $i)
    $rows += $p
}
$pnlHeader = $rows[0]; $pnlPick = $rows[1]; $pnlMain = $rows[2]; $pnlActions = $rows[3]; $pnlBanner = $rows[4]
$pnlLinks = $rows[5]; $pnlStatus = $rows[6]; $pnlLogHead = $rows[7]; $pnlLog = $rows[8]; $pnlFooter = $rows[9]

# ---------- control factories ----------
function New-Label($parent,[string]$text,[int]$x,[int]$y,[int]$w,[int]$h,$fore,$font,[string]$anchor='Top,Left') {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text; $l.ForeColor = $fore; $l.Font = $font
    $l.Location = New-Object System.Drawing.Point($x,$y); $l.Size = New-Object System.Drawing.Size($w,$h)
    $l.Anchor = $anchor; $l.TextAlign = 'MiddleLeft'
    $parent.Controls.Add($l); return $l
}
function New-FlatButton($parent,[string]$text,[int]$x,[int]$y,[int]$w,[int]$h,$fore,[string]$anchor='Top,Left') {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text
    $b.Location = New-Object System.Drawing.Point($x,$y); $b.Size = New-Object System.Drawing.Size($w,$h)
    $b.FlatStyle = 'Flat'; $b.BackColor = $clBtnBg; $b.ForeColor = $fore
    $b.FlatAppearance.BorderColor = $clBorder; $b.FlatAppearance.BorderSize = 1
    $b.Font = $fBtn; $b.Cursor = [System.Windows.Forms.Cursors]::Hand; $b.Anchor = $anchor
    $parent.Controls.Add($b); return $b
}

$tt = New-Object System.Windows.Forms.ToolTip
$tt.AutoPopDelay = 15000

# ---------- row 0: sign-in header ----------
$U.lblAccount = New-Label $pnlHeader ('Checking sign-in ' + $chDash + ' please wait ...') 16 6 540 24 $clMuted $fVal 'Top,Left,Right'
$U.btnLogin   = New-FlatButton $pnlHeader 'Sign in' 570 5 134 27 $clBtnTxt 'Top,Right'
$tt.SetToolTip($U.btnLogin, "Runs 'az login' - a browser window opens. Also use this to switch tenant/account.")

# ---------- row 1: capacity picker ----------
New-Label $pnlPick 'Capacity' 16 6 80 24 $clMuted $fLegend | Out-Null
$U.cmb = New-Object System.Windows.Forms.ComboBox
$U.cmb.DropDownStyle = 'DropDownList'; $U.cmb.Font = $fCap
$U.cmb.Location = New-Object System.Drawing.Point(96, 5); $U.cmb.Size = New-Object System.Drawing.Size(462, 26)
$U.cmb.Anchor = 'Top,Left,Right'
$pnlPick.Controls.Add($U.cmb)
$U.btnReload = New-FlatButton $pnlPick 'Reload list' 570 5 134 27 $clBtnTxt 'Top,Right'
$tt.SetToolTip($U.btnReload, 'Re-query all enabled subscriptions for Fabric capacities')
$tt.SetToolTip($U.cmb, 'Name ' + $chDash + ' Subscription / Resource group')

# ---------- row 2: info card + right column ----------
$card = New-Object System.Windows.Forms.Panel
$card.Location = New-Object System.Drawing.Point(16,6); $card.Size = New-Object System.Drawing.Size(430,240)
$card.BackColor = $clCard
$card.Add_Paint({ param($s,$e)
    $pen = New-Object System.Drawing.Pen $clBorder
    $e.Graphics.DrawRectangle($pen, 0, 0, $s.Width-1, $s.Height-1)
    $pen.Dispose()
})
$pnlMain.Controls.Add($card)
New-Label $card 'Capacity Info' 12 6 200 22 $clLegend $fLegend | Out-Null

function New-CardRow([string]$caption,[int]$y) {
    New-Label $card $caption 14 $y 128 22 $clMuted $fCap | Out-Null
    return (New-Label $card '' 148 $y 270 22 $clInk $fVal)
}
$y = 32; $step = 25
$U.lblName   = New-CardRow 'Name'           $y; $y += $step
$U.lblSub    = New-CardRow 'Subscription'   $y; $y += $step
$U.lblRg     = New-CardRow 'Resource group' $y; $y += $step
$U.lblRegion = New-CardRow 'Region'         $y; $y += $step
$U.lblSku    = New-CardRow 'SKU'            $y; $y += $step
$U.lblStatus = New-CardRow 'Status'         $y; $y += $step
$U.lblProv   = New-CardRow 'Provisioning'   $y; $y += $step
$U.lblCost   = New-CardRow 'Cost (MTD)'     $y; $y += $step
$tt.SetToolTip($U.lblCost, 'Month-to-date cost of this capacity (Cost Management, resource-level). Data has latency of up to ~24-48h.')

# right column
$U.btnRefresh = New-FlatButton $pnlMain 'Refresh' 462 6 242 30 $clBtnTxt 'Top,Left,Right'
$tt.SetToolTip($U.btnRefresh, 'Reload status and cost of the selected capacity')

$U.chkAuto = New-Object System.Windows.Forms.CheckBox
$U.chkAuto.Text = ('Auto-refresh ({0}s)' -f [int]$S.settings.autoRefreshSeconds)
$U.chkAuto.ForeColor = $clInk; $U.chkAuto.Font = $fCap
$U.chkAuto.Location = New-Object System.Drawing.Point(462,44); $U.chkAuto.Size = New-Object System.Drawing.Size(242,24)
$U.chkAuto.Anchor = 'Top,Left,Right'
$pnlMain.Controls.Add($U.chkAuto)

$U.lblUpdated = New-Label $pnlMain 'Updated: -' 462 72 242 22 $clMuted $fCap 'Top,Left,Right'

New-Label $pnlMain 'Auto-pause on inactivity' 462 110 242 22 $clMuted $fLegend 'Top,Left,Right' | Out-Null
$U.cmbAutoPause = New-Object System.Windows.Forms.ComboBox
$U.cmbAutoPause.DropDownStyle = 'DropDownList'; $U.cmbAutoPause.Font = $fCap
$U.cmbAutoPause.Location = New-Object System.Drawing.Point(462,134); $U.cmbAutoPause.Size = New-Object System.Drawing.Size(150,26)
[void]$U.cmbAutoPause.Items.AddRange(@('Off','15 minutes','30 minutes','60 minutes','120 minutes'))
$pnlMain.Controls.Add($U.cmbAutoPause)
$U.lblApInfo = New-Label $pnlMain $chInfo 618 134 26 26 $clMuted $fVal
$U.lblApInfo.TextAlign = 'MiddleCenter'; $U.lblApInfo.Cursor = [System.Windows.Forms.Cursors]::Help
$apHint = 'Counts the time without any interaction with this window. Load on the capacity (e.g. running refreshes, notebooks, reports) is NOT detected.'
$tt.SetToolTip($U.lblApInfo, $apHint); $tt.SetToolTip($U.cmbAutoPause, $apHint)
$U.lblApNote = New-Label $pnlMain 'Only counts cockpit inactivity, not capacity load.' 462 164 242 40 $clMuted $fSmall 'Top,Left,Right'
$U.lblApNote.TextAlign = 'TopLeft'

# ---------- row 3: actions + progress ----------
New-Label $pnlActions 'Capacity actions:' 16 12 130 22 $clMuted $fLegend | Out-Null
$U.btnResume = New-FlatButton $pnlActions 'Resume' 150 8 110 30 $clGreen
$U.btnPause  = New-FlatButton $pnlActions 'Pause'  268 8 110 30 $clAmber

$U.pnlOp = New-Object System.Windows.Forms.Panel
$U.pnlOp.Location = New-Object System.Drawing.Point(392, 6); $U.pnlOp.Size = New-Object System.Drawing.Size(312, 34)
$U.pnlOp.Anchor = 'Top,Left,Right'; $U.pnlOp.Visible = $false
$pnlActions.Controls.Add($U.pnlOp)
$U.prg = New-Object System.Windows.Forms.ProgressBar
$U.prg.Style = 'Marquee'; $U.prg.MarqueeAnimationSpeed = 30
$U.prg.Location = New-Object System.Drawing.Point(0, 22); $U.prg.Size = New-Object System.Drawing.Size(180, 8)
$U.pnlOp.Controls.Add($U.prg)
$U.lblOp = New-Label $U.pnlOp 'Working ...' 0 0 180 20 $clInk $fVal
$U.btnStopWait = New-FlatButton $U.pnlOp 'Stop waiting' 190 2 122 30 $clBtnTxt 'Top,Right'
$tt.SetToolTip($U.btnStopWait, 'Stops only the polling in this window. The operation in Azure continues.')

# ---------- row 4: auto-pause warning banner (hidden until 2 min before) ----------
$pnlBanner.BackColor = $clWarnBg; $pnlBanner.Visible = $false
$U.lblBanner = New-Label $pnlBanner 'Auto-pause in 02:00' 16 8 220 24 $clAmber $fVal
$U.btnApNow    = New-FlatButton $pnlBanner 'Pause now'          246 5 120 27 $clAmber
$U.btnApExtend = New-FlatButton $pnlBanner 'Extend'             374 5 100 27 $clBtnTxt
$U.btnApOff    = New-FlatButton $pnlBanner 'Disable for today'  482 5 150 27 $clBtnTxt
$tt.SetToolTip($U.btnApExtend, 'Resets the inactivity timer to the full value')
$tt.SetToolTip($U.btnApOff, 'Turns auto-pause off until the cockpit is restarted')

# ---------- row 5: links ----------
New-Label $pnlLinks 'Open:' 16 10 50 22 $clMuted $fLegend | Out-Null
$U.btnPortal  = New-FlatButton $pnlLinks 'Capacity Overview'  70 6 168 30 $clBtnTxt
$U.btnCostA   = New-FlatButton $pnlLinks 'Cost Analysis (RG)' 246 6 168 30 $clBtnTxt
$U.btnMetrics = New-FlatButton $pnlLinks 'Metrics App'        422 6 130 30 $clBtnTxt
$tt.SetToolTip($U.btnPortal,  'Azure portal: overview page of the selected capacity')
$tt.SetToolTip($U.btnCostA,   'Azure portal: cost analysis scoped to the resource group of the selected capacity')
$tt.SetToolTip($U.btnMetrics, 'Fabric Capacity Metrics app (metricsAppUrl in settings.json) or the Power BI Apps page')

# ---------- row 6: status line ----------
$pnlStatus.Padding = New-Object System.Windows.Forms.Padding(16,0,16,0)
$U.lblStatusLine = New-Label $pnlStatus '' 0 0 10 10 $clMuted $fSmall
$U.lblStatusLine.Dock = 'Fill'

# ---------- row 7/8: log ----------
New-Label $pnlLogHead 'Log' 16 2 60 22 $clMuted $fLegend | Out-Null
$U.btnCopyLog = New-FlatButton $pnlLogHead 'Copy log' 604 0 100 24 $clBtnTxt 'Top,Right'
$U.btnCopyLog.Font = $fSmall
$U.txtLog = New-Object System.Windows.Forms.TextBox
$U.txtLog.Multiline = $true; $U.txtLog.ScrollBars = 'Vertical'; $U.txtLog.ReadOnly = $true
$U.txtLog.BorderStyle = 'FixedSingle'; $U.txtLog.BackColor = $clLogBg; $U.txtLog.ForeColor = $clLogFg; $U.txtLog.Font = $fMono
$U.txtLog.Dock = 'Fill'
$pnlLog.Padding = New-Object System.Windows.Forms.Padding(16,0,16,0)
$pnlLog.Controls.Add($U.txtLog)

# ---------- row 9: pay-as-you-go footer ----------
$U.lblFooter = New-Label $pnlFooter ('Designed for F-SKUs with pay-as-you-go billing. Pausing saves the compute cost; OneLake storage is still billed. ' +
    'With an existing reservation, pausing yields no savings ' + $chDash + ' this tool cannot detect reservations.') 0 0 10 10 $clMuted $fSmall
$U.lblFooter.TextAlign = 'TopLeft'; $U.lblFooter.Dock = 'Fill'
$pnlFooter.Padding = New-Object System.Windows.Forms.Padding(16,4,16,4)

# ---------- helpers ----------
function Format-Elapsed([timespan]$ts) { return ('{0:00}:{1:00}' -f [int][math]::Floor($ts.TotalMinutes), $ts.Seconds) }

function Write-Log([string]$msg) {
    $ts = (Get-Date).ToString('HH:mm:ss')
    if ($U.txtLog.TextLength -gt 400000) { $U.txtLog.Text = $U.txtLog.Text.Substring(200000) }
    $U.txtLog.AppendText("[$ts] $msg`r`n")
}
function Set-Status([string]$text,[string]$kind='info') {
    $U.lblStatusLine.Text = $text
    $U.lblStatusLine.ForeColor = switch ($kind) { 'ok' { $clGreen } 'warn' { $clAmber } 'error' { $clRed } default { $clMuted } }
}
function Get-CapKey($c) { return ('{0}|{1}|{2}' -f $c.subscriptionId, $c.resourceGroup, $c.name).ToLowerInvariant() }
function Reset-Idle { $S.idleSince = Get-Date }

function Update-Controls {
    $li = [bool]$S.loggedIn; $sel = ($null -ne $S.selected); $op = [bool]$S.op
    $U.btnLogin.Enabled   = $S.azOk -and -not $S.loginBusy
    $U.btnLogin.Text      = if ($li) { 'Switch account' } else { 'Sign in' }
    $U.cmb.Enabled        = $li -and -not $S.listBusy -and -not $op
    $U.btnReload.Enabled  = $li -and -not $S.listBusy -and -not $S.loginBusy
    $U.btnRefresh.Enabled = $li -and $sel -and -not $S.statusBusy -and -not $op
    $U.btnResume.Enabled  = $li -and $sel -and -not $op
    $U.btnPause.Enabled   = $li -and $sel -and -not $op
    $U.cmbAutoPause.Enabled = $li
    foreach ($b in @($U.btnPortal,$U.btnCostA,$U.btnMetrics)) { $b.Enabled = $sel }
    $U.pnlOp.Visible = $op
}

function Show-Banner([bool]$on) {
    if ($on) { $root.RowStyles[4].Height = 40; $pnlBanner.Visible = $true }
    else     { $pnlBanner.Visible = $false; $root.RowStyles[4].Height = 0 }
}

function Show-Card($c) {
    if ($null -eq $c) {
        foreach ($l in @($U.lblName,$U.lblSub,$U.lblRg,$U.lblRegion,$U.lblSku,$U.lblStatus,$U.lblProv,$U.lblCost)) { $l.Text = '' }
        $U.lblStatus.ForeColor = $clInk; $S.status = ''
        return
    }
    $U.lblName.Text   = $c.name
    if ($c.subscriptionName) { $U.lblSub.Text = $c.subscriptionName } elseif ($c.subscriptionId) { $U.lblSub.Text = $c.subscriptionId }
    $U.lblRg.Text     = $c.resourceGroup
    $U.lblRegion.Text = $c.location
    $U.lblSku.Text    = $c.sku
    $st = if ($c.state) { [string]$c.state } else { '(unknown)' }
    $U.lblStatus.Text = $st
    $U.lblStatus.ForeColor = if ($st -eq 'Active') { $clGreen } elseif ($st -eq 'Paused') { $clAmber } else { $clMuted }
    $U.lblProv.Text   = if ($c.provisioningState) { $c.provisioningState } else { '(unknown)' }
    $S.status = $st
}

function Set-LoggedIn($acct) {
    $S.loggedIn = $true; $S.account = $acct
    $U.lblAccount.Text = ('{0} {1} {2} Tenant {3}' -f $chCheck, $acct.User, $chDot, $acct.TenantId)
    $U.lblAccount.ForeColor = $clGreen
    Update-Controls
}
function Set-LoggedOut([string]$headline) {
    $wasIn = $S.loggedIn
    $S.loggedIn = $false; $S.account = $null
    $U.lblAccount.Text = ('{0} {1}' -f $chCross, $headline)
    $U.lblAccount.ForeColor = $clRed
    Show-Banner $false
    if ($U.lblCost.Text -eq '(loading ...)') { $U.lblCost.Text = '-' }
    if ($S.op) { Finish-Operation 'cancelled' }
    if ($wasIn) { Write-Log ('Sign-in state lost: {0}. Auto-refresh and auto-pause are on hold until you sign in again.' -f $headline) }
    Set-Status ("{0} - use 'Sign in'." -f $headline) 'error'
    Update-Controls
}

# ---------- async runner ----------
function Start-Async {
    param([scriptblock]$Work, [object[]]$WorkArgs, [scriptblock]$OnDone)
    $ps = [powershell]::Create()
    [void]$ps.AddScript($Work)
    foreach ($a in $WorkArgs) { [void]$ps.AddArgument($a) }
    $handle = $ps.BeginInvoke()
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 200
    $tick = {
        if ($handle.IsCompleted) {
            $timer.Stop()
            $r = $null
            try {
                $out = $ps.EndInvoke($handle)
                if ($out.Count -gt 0) { $r = $out[$out.Count - 1] }
            } catch { $r = [pscustomobject]@{ Ok = $false; Error = $_.Exception.Message; AuthError = $false; Exit = -1; Out = $_.Exception.Message } }
            $ps.Dispose(); $timer.Dispose()
            & $OnDone $r
        }
    }.GetNewClosure()
    $timer.Add_Tick($tick)
    $timer.Start()
}

# ---------- capacity list ----------
function Populate-Combo([object[]]$items, [string]$selectKey) {
    $S.loading = $true
    $U.cmb.Items.Clear()
    $idx = -1; $i = 0
    foreach ($c in $items) {
        $it = New-Object FabricCapacityItem
        $it.Key = Get-CapKey $c
        $it.Display = ('{0} {1} {2} / {3}' -f $c.name, $chDash, $c.subscriptionName, $c.resourceGroup)
        $it.Record = $c
        [void]$U.cmb.Items.Add($it)
        if ($selectKey -and $it.Key -eq $selectKey) { $idx = $i }
        $i++
    }
    $U.cmb.SelectedIndex = $idx
    $S.loading = $false
    return ($idx -ge 0)
}

function Select-Capacity($c) {
    $S.selected = $c
    Show-Card $c
    $U.lblCost.Text = if ($c) { '(loading ...)' } else { '' }
    $U.lblUpdated.Text = 'Updated: -'
    if ($c) {
        $S.settings.lastCapacity = @{ subscriptionId = $c.subscriptionId; resourceGroup = $c.resourceGroup; name = $c.name }
        try { Save-CockpitSettings $S.settings } catch { }
        Write-Log ("Selected capacity '{0}' ({1} / {2})." -f $c.name, $c.subscriptionName, $c.resourceGroup)
    }
    Show-Banner $false
    Update-Controls
    if ($c -and $S.loggedIn) { Invoke-StatusRefresh }
}

function Invoke-ListRefresh {
    if ($S.listBusy -or -not $S.loggedIn) { return }
    $S.listBusy = $true
    Set-Status 'Loading capacities ...' 'info'
    Update-Controls
    Start-Async -Work $wList -WorkArgs @($common) -OnDone {
        param($r)
        $S.listBusy = $false
        if (-not $r -or -not $r.Ok) {
            foreach ($e in @($r.Errors)) { if ($e) { Write-Log ('Capacity list: ' + $e) } }
            if ($r.AuthError) { Set-LoggedOut 'Sign-in expired' } else { Set-Status 'Could not load capacities - see log.' 'error' }
            Update-Controls
            return
        }
        foreach ($l in @($r.Log))    { Write-Log $l }
        foreach ($e in @($r.Errors)) { Write-Log ('  warning: ' + $e) }
        $items = @($r.Items)
        $S.settings.capacityCache = $items
        $S.settings.capacityCacheUpdated = (Get-Date).ToUniversalTime().ToString('o')
        try { Save-CockpitSettings $S.settings } catch { Write-Log ('Could not save settings: ' + $_.Exception.Message) }

        $prevKey = if ($S.selected) { Get-CapKey $S.selected } else { '' }
        $kept = Populate-Combo $items $prevKey
        if ($items.Count -eq 0) {
            Set-Status 'No Fabric capacities found. Check the signed-in account / tenant.' 'warn'
            Select-Capacity $null
        } elseif ($kept) {
            # keep the selection; the list record already carries a fresh state
            $S.selected = $U.cmb.SelectedItem.Record
            Show-Card $S.selected
            Set-Status ('Capacity list updated ({0} found).' -f $items.Count) 'ok'
        } else {
            Set-Status ('Capacity list updated ({0} found) - pick a capacity.' -f $items.Count) 'ok'
            if ($prevKey) { Write-Log 'Previously selected capacity no longer exists.' }
            Select-Capacity $null
        }
        Update-Controls
    }
}

# ---------- status + cost ----------
function Invoke-CostRefresh {
    $cap = $S.selected
    if (-not $cap) { return }
    $key = Get-CapKey $cap
    $U.lblCost.ForeColor = $clInk
    Start-Async -Work $wCost -WorkArgs @($costFunc,$cap.subscriptionId,$cap.resourceGroup,$cap.name,$env:TEMP) -OnDone {
        param($r)
        if (-not $S.selected -or (Get-CapKey $S.selected) -ne $key) { return }   # selection changed meanwhile
        if (-not $r) { $U.lblCost.Text = '(error)'; return }
        if (-not $r.Ok) {
            if ($r.Throttled) { $U.lblCost.Text = 'rate-limited (429) - retry later'; $U.lblCost.ForeColor = $clAmber }
            else { $U.lblCost.Text = 'n/a'; $U.lblCost.ForeColor = $clRed }
            if ($r.Error) { Write-Log ('Cost: ' + $r.Error) }
            return
        }
        if ($null -ne $r.FabricCost) {
            $suffix = if ($r.FromCache) { (' (cached {0:HH:mm})' -f $r.AsOf) } else { '' }
            $U.lblCost.Text = ('{0} {1}{2}' -f $r.FabricCost, $r.FabricCurrency, $suffix)
        } elseif (-not $r.Rows -or $r.Rows.Count -eq 0) {
            $U.lblCost.Text = 'no data yet (latency ~24-48h)'
        } else {
            $U.lblCost.Text = ('n/a for capacity; RG total {0} {1}' -f $r.Total, $r.Currency)
        }
    }.GetNewClosure()
}

function Invoke-StatusRefresh([switch]$Silent) {
    $cap = $S.selected
    if (-not $cap -or $S.statusBusy -or -not $S.loggedIn -or $S.op) { return }
    $S.statusBusy = $true
    $key = Get-CapKey $cap
    if (-not $Silent) { Set-Status 'Refreshing status ...' 'info' }
    Update-Controls
    Start-Async -Work $wStatus -WorkArgs @($common,$cap.subscriptionId,$cap.resourceGroup,$cap.name,$cap.subscriptionName) -OnDone {
        param($r)
        $S.statusBusy = $false
        Update-Controls
        if (-not $S.selected -or (Get-CapKey $S.selected) -ne $key) { return }
        if (-not $r -or -not $r.Ok) {
            Write-Log ('Status query failed: ' + $r.Error)
            if ($r.AuthError) { Set-LoggedOut 'Sign-in expired' }
            else { Set-Status 'Status refresh failed - see log.' 'warn'; $U.lblStatus.Text = '(error)'; $U.lblStatus.ForeColor = $clRed }
            return
        }
        Show-Card $r.Item
        $U.lblUpdated.Text = ('Updated: {0}' -f (Get-Date).ToString('HH:mm:ss'))
        Set-Status ('Status: {0} (updated {1})' -f $r.Item.state, (Get-Date).ToString('HH:mm:ss')) 'info'
        if (-not $Silent) { Write-Log ('Status: {0} | SKU {1} | Provisioning {2}' -f $r.Item.state, $r.Item.sku, $r.Item.provisioningState) }
        Invoke-CostRefresh
    }.GetNewClosure()
}

# ---------- pause / resume with polling ----------
function Start-Operation([string]$action,[string]$reason) {
    if ($S.op -or -not $S.selected -or -not $S.loggedIn) { return }
    $cap = $S.selected
    $S.op = $action
    $S.opTarget = if ($action -eq 'pause') { 'Paused' } else { 'Active' }
    $S.opVerb   = if ($action -eq 'pause') { 'Pausing' } else { 'Resuming' }
    $S.opStart  = Get-Date; $S.opLastState = ''
    $U.lblOp.Text = $S.opVerb + ' ... (00:00)'
    Show-Banner $false
    Update-Controls
    Write-Log ("{0} capacity '{1}' ... ({2})" -f $S.opVerb, $cap.name, $reason)
    Set-Status ('{0} - waiting for state {1} (polling every 5s) ...' -f $S.opVerb, $S.opTarget) 'info'
    $azAction = if ($action -eq 'pause') { 'suspend' } else { 'resume' }
    Start-Async -Work $wAction -WorkArgs @($common,$azAction,$cap.subscriptionId,$cap.resourceGroup,$cap.name) -OnDone {
        param($r)
        if (-not $S.op) { return }
        if (-not $r -or -not $r.Ok) {
            Write-Log ('Command failed: ' + $r.Command)
            Write-Log ('  ' + $r.Error)
            if ($r.AuthError) { Set-LoggedOut 'Sign-in expired' } else { Finish-Operation 'failed' }
            return
        }
        Write-Log ('Command accepted (--no-wait): ' + $r.Command)
        $T.poll.Start()
        Invoke-Poll
    }
}

function Invoke-Poll {
    if (-not $S.op -or $S.pollBusy) { return }
    $S.pollBusy = $true
    $cap = $S.selected
    Start-Async -Work $wStatus -WorkArgs @($common,$cap.subscriptionId,$cap.resourceGroup,$cap.name,$cap.subscriptionName) -OnDone {
        param($r)
        $S.pollBusy = $false
        if (-not $S.op) { return }
        if (-not $r -or -not $r.Ok) {
            Write-Log ('Poll failed: ' + $r.Error)
            if ($r.AuthError) { Set-LoggedOut 'Sign-in expired' }
            return
        }
        $st = [string]$r.Item.state
        if ($st -ne $S.opLastState) {
            Write-Log ('  state: {0} (provisioning {1}) after {2}' -f $st, $r.Item.provisioningState, (Format-Elapsed ((Get-Date) - $S.opStart)))
            $S.opLastState = $st
        }
        Show-Card $r.Item
        $U.lblUpdated.Text = ('Updated: {0}' -f (Get-Date).ToString('HH:mm:ss'))
        if ($st -eq $S.opTarget) { Finish-Operation 'success'; return }
        if (((Get-Date) - $S.opStart).TotalMinutes -ge 10) { Finish-Operation 'timeout' }
    }
}

function Finish-Operation([string]$how) {
    $T.poll.Stop()
    $dur  = Format-Elapsed ((Get-Date) - $S.opStart)
    $verb = $S.opVerb; $target = $S.opTarget
    $S.op = ''; $S.pollBusy = $false
    Reset-Idle
    switch ($how) {
        'success'   { Write-Log ('{0} finished - state {1} reached after {2}.' -f $verb, $target, $dur)
                      Set-Status ('{0} complete after {1}.' -f $verb, $dur) 'ok'
                      Update-Controls; Invoke-StatusRefresh -Silent; return }
        'cancelled' { Write-Log ('Waiting cancelled after {0}. The operation in Azure continues; the next refresh picks up the state.' -f $dur)
                      Set-Status 'Waiting cancelled - the Azure operation continues.' 'warn' }
        'timeout'   { $l = Get-FabricLinks -Capacity $S.selected -MetricsAppUrl $S.settings.metricsAppUrl
                      Write-Log ('Target state {0} not reached after 10 minutes. Check the status in the Azure portal: {1}' -f $target, $l.Portal)
                      Set-Status "Target state not reached after 10 minutes. Check the Azure portal ('Capacity Overview')." 'warn' }
        'failed'    { Set-Status ($verb + ' failed - see log.') 'error' }
    }
    Update-Controls
}

function Confirm-Operation([string]$action) {
    $cap = $S.selected
    if ($action -eq 'pause') {
        $msg = "Pause capacity '$($cap.name)'?`n`nTarget state: Paused.`nAssigned workspaces are unavailable until the capacity is resumed.`nOneLake storage is still billed while paused."
        $r = [System.Windows.Forms.MessageBox]::Show($msg, 'Confirm pause', 'YesNo', 'Warning')
    } else {
        $msg = "Resume capacity '$($cap.name)'?`n`nTarget state: Active.`nCompute billing starts again as soon as the capacity is active."
        $r = [System.Windows.Forms.MessageBox]::Show($msg, 'Confirm resume', 'YesNo', 'Question')
    }
    return ($r -eq [System.Windows.Forms.DialogResult]::Yes)
}

# ---------- sign-in ----------
function Invoke-Login {
    if ($S.loginBusy -or -not $S.azOk) { return }
    $S.loginBusy = $true
    $U.lblAccount.Text = 'Signing in - please complete the sign-in in the browser window ...'
    $U.lblAccount.ForeColor = $clAmber
    Set-Status "Running 'az login' - a browser window opens." 'info'
    Write-Log "Starting 'az login' - complete the sign-in in the browser."
    Update-Controls
    Start-Async -Work $wLogin -WorkArgs @($common) -OnDone {
        param($r)
        $S.loginBusy = $false
        if ($r -and $r.Account -and $r.Account.LoggedIn) {
            Set-LoggedIn $r.Account
            Write-Log ('Signed in as {0} (tenant {1}).' -f $r.Account.User, $r.Account.TenantId)
            Set-Status 'Signed in.' 'ok'
            Invoke-ListRefresh
            if ($S.selected) { Invoke-StatusRefresh }
        } else {
            $err = if ($r) { ($r.Out).Trim() } else { 'no result' }
            Write-Log ("'az login' did not complete: " + $err)
            Set-LoggedOut 'Not signed in'
        }
    }
}

# ---------- auto-pause ----------
function Update-AutoPause {
    $mins = [int]$S.settings.autoPauseMinutes
    if ($S.op) { Reset-Idle }
    $active = ($mins -gt 0) -and (-not $S.autoPauseOff) -and $S.loggedIn -and ($null -ne $S.selected) -and ($S.status -eq 'Active') -and (-not $S.op)
    if (-not $active) { if ($pnlBanner.Visible) { Show-Banner $false }; return }
    $remaining = [timespan]::FromMinutes($mins) - ((Get-Date) - $S.idleSince)
    if ($remaining.TotalSeconds -le 0) {
        Show-Banner $false
        Reset-Idle
        Start-Operation 'pause' ('Auto-pause after {0} min of cockpit inactivity' -f $mins)
        return
    }
    if ($remaining.TotalSeconds -le 120) {
        $U.lblBanner.Text = 'Auto-pause in ' + (Format-Elapsed $remaining)
        if (-not $pnlBanner.Visible) { Show-Banner $true; Write-Log ('Auto-pause warning: pausing in {0} unless you interact.' -f (Format-Elapsed $remaining)) }
    } elseif ($pnlBanner.Visible) { Show-Banner $false }
}

# ---------- handlers ----------
$U.btnLogin.Add_Click({ Reset-Idle; Invoke-Login })
$U.btnReload.Add_Click({ Reset-Idle; Invoke-ListRefresh })
$U.btnRefresh.Add_Click({ Reset-Idle; Invoke-StatusRefresh })

$U.cmb.Add_SelectedIndexChanged({
    if ($S.loading) { return }
    Reset-Idle
    $it = $U.cmb.SelectedItem
    Select-Capacity $(if ($it) { $it.Record } else { $null })
})

$U.btnResume.Add_Click({
    Reset-Idle
    if ($S.op -or -not $S.selected) { return }
    if (Confirm-Operation 'resume') { Start-Operation 'resume' 'manual' }
})
$U.btnPause.Add_Click({
    Reset-Idle
    if ($S.op -or -not $S.selected) { return }
    if (Confirm-Operation 'pause') { Start-Operation 'pause' 'manual' }
})
$U.btnStopWait.Add_Click({ Reset-Idle; if ($S.op) { Finish-Operation 'cancelled' } })

$U.btnApNow.Add_Click({ Reset-Idle; Show-Banner $false; Start-Operation 'pause' 'auto-pause warning: Pause now' })
$U.btnApExtend.Add_Click({ Reset-Idle; Show-Banner $false; Write-Log ('Auto-pause extended - timer reset to {0} min.' -f [int]$S.settings.autoPauseMinutes) })
$U.btnApOff.Add_Click({ Reset-Idle; $S.autoPauseOff = $true; Show-Banner $false; Write-Log 'Auto-pause disabled for today (until the cockpit is restarted).'; Set-Status 'Auto-pause disabled until restart.' 'warn' })

$U.cmbAutoPause.Add_SelectedIndexChanged({
    if ($S.loading) { return }
    Reset-Idle
    $m = [int]$S.apValues[[math]::Max(0, $U.cmbAutoPause.SelectedIndex)]
    if ([int]$S.settings.autoPauseMinutes -eq $m) { return }
    $S.settings.autoPauseMinutes = $m
    $S.autoPauseOff = $false
    try { Save-CockpitSettings $S.settings } catch { }
    Write-Log $(if ($m -gt 0) { ('Auto-pause set to {0} min of cockpit inactivity.' -f $m) } else { 'Auto-pause switched off.' })
    Show-Banner $false
})

$U.chkAuto.Add_CheckedChanged({ Reset-Idle; if ($U.chkAuto.Checked) { $T.auto.Start() } else { $T.auto.Stop() } })

function Open-Link([string]$which,[string]$label) {
    Reset-Idle
    if (-not $S.selected) { return }
    try {
        $l = Get-FabricLinks -Capacity $S.selected -MetricsAppUrl $S.settings.metricsAppUrl
        Start-Process $l.$which
        Write-Log ('Opened {0}.' -f $label)
    } catch { Write-Log ('Could not open {0}: {1}' -f $label, $_.Exception.Message) }
}
$U.btnPortal.Add_Click({  Open-Link 'Portal'  'capacity overview' })
$U.btnCostA.Add_Click({   Open-Link 'Cost'    'cost analysis (RG)' })
$U.btnMetrics.Add_Click({ Open-Link 'Metrics' 'Metrics app' })

$U.btnCopyLog.Add_Click({
    Reset-Idle
    try { [System.Windows.Forms.Clipboard]::SetText($U.txtLog.Text); Set-Status 'Log copied to clipboard.' 'ok' }
    catch { Set-Status ('Copy failed: ' + $_.Exception.Message) 'error' }
})

# ---------- timers ----------
$T.auto = New-Object System.Windows.Forms.Timer
$T.auto.Interval = [int]$S.settings.autoRefreshSeconds * 1000
$T.auto.Add_Tick({ Invoke-StatusRefresh -Silent })   # deliberately does NOT reset the inactivity timer

$T.poll = New-Object System.Windows.Forms.Timer
$T.poll.Interval = 5000
$T.poll.Add_Tick({ Invoke-Poll })

$T.ui = New-Object System.Windows.Forms.Timer
$T.ui.Interval = 1000
$T.ui.Add_Tick({
    if ($S.op) { $U.lblOp.Text = ('{0} ... ({1})' -f $S.opVerb, (Format-Elapsed ((Get-Date) - $S.opStart))) }
    Update-AutoPause
})

# ---------- startup ----------
$form.Add_Shown({
    $S.loading = $true
    $m = [int]$S.settings.autoPauseMinutes
    $idx = [array]::IndexOf($S.apValues, $m)
    if ($idx -lt 0) {
        if ($m -gt 0) {   # custom value from settings.json (e.g. for testing) - show it honestly
            [void]$U.cmbAutoPause.Items.Add(('{0} minutes (custom)' -f $m)); $S.apValues += $m; $idx = $S.apValues.Count - 1
        } else { $idx = 0; $S.settings.autoPauseMinutes = 0 }
    }
    $U.cmbAutoPause.SelectedIndex = $idx
    $S.loading = $false

    Show-Card $null
    Write-Log ('Settings: ' + (Get-CockpitSettingsPath))
    $cache = @($S.settings.capacityCache)
    $lc = $S.settings.lastCapacity
    $lastKey = if ($lc -and $lc.name) { ('{0}|{1}|{2}' -f $lc.subscriptionId, $lc.resourceGroup, $lc.name).ToLowerInvariant() } else { '' }
    if ($cache.Count -gt 0) {
        $found = Populate-Combo $cache $lastKey
        Write-Log ('Loaded {0} capacity(ies) from cache (updated {1}).' -f $cache.Count, $S.settings.capacityCacheUpdated)
        if ($found) { $S.selected = $U.cmb.SelectedItem.Record; Show-Card $S.selected; $U.lblCost.Text = '(loading ...)'; $U.lblUpdated.Text = 'Updated: - (cached)' }
    } elseif ($lastKey) {
        # no cache yet, but a last capacity is known (e.g. migrated settings) - show it until the list arrives
        $rec = [pscustomobject]@{ name = $lc.name; id = ''; subscriptionId = $lc.subscriptionId; subscriptionName = ''; resourceGroup = $lc.resourceGroup; location = ''; sku = ''; state = ''; provisioningState = '' }
        Populate-Combo @($rec) $lastKey | Out-Null
        $S.selected = $rec; Show-Card $rec; $U.lblCost.Text = '(loading ...)'
    }
    Update-Controls
    $T.ui.Start()
    $U.chkAuto.Checked = $true

    if (-not $S.azOk) {
        Set-LoggedOut 'Azure CLI (az) not found'
        Set-Status 'Install the Azure CLI from https://aka.ms/installazurecli and restart the cockpit.' 'error'
        Write-Log 'Azure CLI (az) was not found in PATH.'
        return
    }
    Set-Status 'Checking sign-in ...' 'info'
    Start-Async -Work $wAccount -WorkArgs @($common) -OnDone {
        param($r)
        if ($r -and -not $r.ExtOk) { Write-Log "Warning: az extension 'microsoft-fabric' could not be installed - capacity commands will fail." }
        if ($r -and $r.Account -and $r.Account.LoggedIn) {
            Set-LoggedIn $r.Account
            Write-Log ('Signed in as {0} (tenant {1}, default subscription {2}).' -f $r.Account.User, $r.Account.TenantId, $r.Account.SubscriptionName)
            if ($S.selected) { Invoke-StatusRefresh }
            Invoke-ListRefresh
        } else {
            $err = if ($r -and $r.Account) { $r.Account.Error } else { '' }
            if ($err) { Write-Log ('az account show: ' + $err) }
            Set-LoggedOut 'Not signed in'
        }
    }
})

$form.Add_FormClosing({
    foreach ($t in $T.Values) { try { $t.Stop() } catch { } }
    try { Save-CockpitSettings $S.settings } catch { }
})

[void]$form.ShowDialog()
foreach ($t in $T.Values) { try { $t.Dispose() } catch { } }
