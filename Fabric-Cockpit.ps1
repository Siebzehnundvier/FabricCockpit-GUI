#Requires -Version 5.1
# Fabric Capacity Cockpit - WinForms GUI for pay-as-you-go Fabric capacities (F-SKU).
# Features: capacity picker across all subscriptions, sign-in status + az login,
# pause/resume with state polling, auto-pause timer, MTD cost, tray icon with menu.
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
    loading     = $false     # combos are being repopulated programmatically
    op          = ''         # '' | 'pause' | 'resume'
    opTarget    = ''
    opVerb      = ''
    opStart     = (Get-Date)
    opLastState = ''
    pollBusy    = $false
    apMinutes   = 0          # auto-pause span chosen (0 = off)
    apDeadline  = $null      # [datetime] when the capacity gets paused
    apValues    = @(0,15,30,60,120)
    exiting     = $false     # set by tray 'Exit'; otherwise closing hides to the tray
    trayHintShown = $false
}
$U = @{}   # controls
$T = @{}   # timers
$I = @{}   # icons

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
$clBlue   = C 37 99 235
$clGray   = C 140 148 158
$clWarnBg = C 255 243 205
$clLogBg  = C 17 17 17
$clLogFg  = C 212 212 212

$fCap    = New-Object System.Drawing.Font('Segoe UI', 10.5)
$fVal    = New-Object System.Drawing.Font('Segoe UI', 10.5, [System.Drawing.FontStyle]::Bold)
$fLegend = New-Object System.Drawing.Font('Segoe UI', 9.75, [System.Drawing.FontStyle]::Bold)
$fBtn    = New-Object System.Drawing.Font('Segoe UI', 9.75, [System.Drawing.FontStyle]::Bold)
$fSmall  = New-Object System.Drawing.Font('Segoe UI', 9)
$fMono   = New-Object System.Drawing.Font('Consolas', 9)

# unified geometry
$M   = 16    # outer margin
$BW  = 150   # standard button width
$BH  = 30    # standard button height
$GAP = 8     # gap between buttons

# ---------- work blocks (run in background runspaces) ----------
$wAccount = { param($lib) . $lib; $ext = Ensure-FabricExtension; [pscustomobject]@{ Account = (Get-AzAccountInfo); ExtOk = $ext } }
$wLogin   = { param($lib) . $lib; $r = Invoke-Az @('login','-o','none','--only-show-errors'); [pscustomobject]@{ Exit = $r.Exit; Out = $r.Out; Account = (Get-AzAccountInfo) } }
$wList    = { param($lib) . $lib; Get-FabricCapacityList }
$wStatus  = { param($lib,$sub,$rg,$name,$subName) . $lib; Get-FabricCapacityStatus -SubscriptionId $sub -ResourceGroup $rg -CapacityName $name -SubscriptionName $subName }
$wAction  = { param($lib,$action,$sub,$rg,$name) . $lib; Invoke-FabricCapacityAction -Action $action -SubscriptionId $sub -ResourceGroup $rg -CapacityName $name }
$wCost    = { param($costPath,$sub,$rg,$name,$tempDir) . $costPath; Invoke-FabricCostQuery -Subscription $sub -ResourceGroup $rg -CapacityName $name -CacheMinutes 10 -TempDir $tempDir }

# ---------- icons (state dots for tray + window) ----------
function New-DotIcon($color) {
    $bmp = New-Object System.Drawing.Bitmap 16,16
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)
    $br = New-Object System.Drawing.SolidBrush $color
    $g.FillEllipse($br, 1, 1, 13, 13); $br.Dispose()
    $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(110, 0, 0, 0))
    $g.DrawEllipse($pen, 1, 1, 13, 13); $pen.Dispose()
    $g.Dispose()
    $ico = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
    $bmp.Dispose()
    return $ico
}
$I.active  = New-DotIcon $clGreen
$I.paused  = New-DotIcon $clAmber
$I.busy    = New-DotIcon $clBlue
$I.unknown = New-DotIcon $clGray
$I.error   = New-DotIcon $clRed

# ---------- form ----------
$form = New-Object System.Windows.Forms.Form
$form.Text          = 'Fabric Capacity Cockpit ' + $chDash + ' Pay-as-you-go (F-SKU)'
$form.ClientSize    = New-Object System.Drawing.Size(720, 712)
$form.MinimumSize   = New-Object System.Drawing.Size(736, 660)
$form.StartPosition = 'CenterScreen'
$form.BackColor     = $clBg
$form.Font          = $fCap
$form.Icon          = $I.unknown

$root = New-Object System.Windows.Forms.TableLayoutPanel
$root.Dock = 'Fill'; $root.ColumnCount = 1
$root.Padding = New-Object System.Windows.Forms.Padding(0)
[void]$root.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
$form.Controls.Add($root)

# rows: header, picker, card, actions, banner (0 until shown), details, log head, log (fill), footer
$rowHeights = @(58, 46, 254, 106, 0, 68, 26, -1, 56)
$root.RowCount = $rowHeights.Count
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
$pnlHeader = $rows[0]; $pnlPick = $rows[1]; $pnlCard = $rows[2]; $pnlActions = $rows[3]; $pnlBanner = $rows[4]
$pnlDetails = $rows[5]; $pnlLogHead = $rows[6]; $pnlLog = $rows[7]; $pnlFooter = $rows[8]

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
function New-Heading($parent,[string]$text,[int]$y) {
    return (New-Label $parent $text $M $y 400 22 $clMuted $fLegend)
}

$tt = New-Object System.Windows.Forms.ToolTip
$tt.AutoPopDelay = 15000

# ---------- row 0: sign-in header band ----------
$pnlHeader.BackColor = $clCard
$pnlHeader.Add_Paint({ param($sender,$e)
    $pen = New-Object System.Drawing.Pen $clBorder
    $e.Graphics.DrawLine($pen, 0, $sender.Height-1, $sender.Width, $sender.Height-1)
    $pen.Dispose()
})
$U.lblAccount = New-Label $pnlHeader ('Checking sign-in ' + $chDash + ' please wait ...') $M 14 520 $BH $clMuted $fVal 'Top,Left,Right'
$U.btnLogin   = New-FlatButton $pnlHeader 'Sign in' (720-$M-$BW) 14 $BW $BH $clBtnTxt 'Top,Right'
$tt.SetToolTip($U.btnLogin, "Runs 'az login' - a browser window opens. Also use this to switch tenant/account.")

# ---------- row 1: capacity picker ----------
New-Label $pnlPick 'Capacity' $M 12 80 24 $clMuted $fLegend | Out-Null
$U.cmb = New-Object System.Windows.Forms.ComboBox
$U.cmb.DropDownStyle = 'DropDownList'; $U.cmb.Font = $fCap
$U.cmb.Location = New-Object System.Drawing.Point(96, 11); $U.cmb.Size = New-Object System.Drawing.Size((720-96-$M-$BW-$GAP), 26)
$U.cmb.Anchor = 'Top,Left,Right'
$pnlPick.Controls.Add($U.cmb)
$U.btnReload = New-FlatButton $pnlPick 'Reload list' (720-$M-$BW) 9 $BW $BH $clBtnTxt 'Top,Right'
$tt.SetToolTip($U.btnReload, 'Re-query all enabled subscriptions for Fabric capacities')
$tt.SetToolTip($U.cmb, 'Name ' + $chDash + ' Subscription / Resource group')

# ---------- row 2: info card (full width; refresh controls in its header) ----------
$card = New-Object System.Windows.Forms.Panel
$card.Location = New-Object System.Drawing.Point($M, 4); $card.Size = New-Object System.Drawing.Size((720-2*$M), 246)
$card.BackColor = $clCard; $card.Anchor = 'Top,Left,Right'
$card.Add_Paint({ param($sender,$e)
    $pen = New-Object System.Drawing.Pen $clBorder
    $e.Graphics.DrawRectangle($pen, 0, 0, $sender.Width-1, $sender.Height-1)
    $pen.Dispose()
})
$pnlCard.Controls.Add($card)
New-Label $card 'Capacity Info' 12 10 200 22 $clLegend $fLegend | Out-Null

$U.btnRefresh = New-FlatButton $card 'Refresh' ($card.Width-12-$BW) 8 $BW $BH $clBtnTxt 'Top,Right'
$tt.SetToolTip($U.btnRefresh, 'Reload status and cost of the selected capacity')
$U.chkAuto = New-Object System.Windows.Forms.CheckBox
$U.chkAuto.Text = ('Auto-refresh ({0}s)' -f [int]$S.settings.autoRefreshSeconds)
$U.chkAuto.ForeColor = $clInk; $U.chkAuto.Font = $fCap
$U.chkAuto.Location = New-Object System.Drawing.Point(($card.Width-12-$BW-$GAP-160), 11); $U.chkAuto.Size = New-Object System.Drawing.Size(160, 24)
$U.chkAuto.Anchor = 'Top,Right'
$card.Controls.Add($U.chkAuto)

function New-CardRow([string]$caption,[int]$y) {
    New-Label $card $caption 14 $y 128 22 $clMuted $fCap | Out-Null
    return (New-Label $card '' 148 $y 300 22 $clInk $fVal)
}
$y = 42; $step = 25
$U.lblName   = New-CardRow 'Name'           $y; $y += $step
$U.lblSub    = New-CardRow 'Subscription'   $y; $y += $step
$U.lblRg     = New-CardRow 'Resource group' $y; $y += $step
$U.lblRegion = New-CardRow 'Region'         $y; $y += $step
$U.lblSku    = New-CardRow 'SKU'            $y; $y += $step
$U.lblStatus = New-CardRow 'Status'         $y
$U.lblStatus.Size = New-Object System.Drawing.Size(160, 22)
$U.lblUpdated = New-Label $card '' 310 $y 300 22 $clMuted $fSmall
$y += $step
$U.lblProv   = New-CardRow 'Provisioning'   $y; $y += $step
$U.lblCost   = New-CardRow 'Cost (MTD)'     $y; $y += $step
$tt.SetToolTip($U.lblCost, 'Month-to-date cost of this capacity (Cost Management, resource-level). Data has latency of up to ~24-48h.')

# ---------- row 3: capacity actions ----------
New-Heading $pnlActions 'Capacity actions:' 6 | Out-Null
$ay = 32
$U.btnResume = New-FlatButton $pnlActions 'Resume' $M $ay $BW $BH $clGreen
$U.btnPause  = New-FlatButton $pnlActions 'Pause'  ($M+$BW+$GAP) $ay $BW $BH $clAmber

$U.pnlOp = New-Object System.Windows.Forms.Panel
$U.pnlOp.Location = New-Object System.Drawing.Point(($M+2*($BW+$GAP)), ($ay-2)); $U.pnlOp.Size = New-Object System.Drawing.Size((720-$M-($M+2*($BW+$GAP))), 34)
$U.pnlOp.Anchor = 'Top,Left,Right'; $U.pnlOp.Visible = $false
$pnlActions.Controls.Add($U.pnlOp)
$U.lblOp = New-Label $U.pnlOp 'Working ...' 0 0 ($U.pnlOp.Width-120-$GAP) 18 $clInk $fVal 'Top,Left,Right'
$U.prg = New-Object System.Windows.Forms.ProgressBar
$U.prg.Style = 'Marquee'; $U.prg.MarqueeAnimationSpeed = 30
$U.prg.Location = New-Object System.Drawing.Point(0, 22); $U.prg.Size = New-Object System.Drawing.Size(($U.pnlOp.Width-120-$GAP), 8); $U.prg.Anchor = 'Top,Left,Right'
$U.pnlOp.Controls.Add($U.prg)
$U.btnStopWait = New-FlatButton $U.pnlOp 'Stop waiting' ($U.pnlOp.Width-120) 2 120 $BH $clBtnTxt 'Top,Right'
$tt.SetToolTip($U.btnStopWait, 'Stops only the polling in this window. The operation in Azure continues.')

$ay2 = $ay + $BH + 10
New-Label $pnlActions 'Auto-pause' $M $ay2 90 26 $clMuted $fCap | Out-Null
$U.cmbAutoPause = New-Object System.Windows.Forms.ComboBox
$U.cmbAutoPause.DropDownStyle = 'DropDownList'; $U.cmbAutoPause.Font = $fCap
$U.cmbAutoPause.Location = New-Object System.Drawing.Point(($M+90), ($ay2+1)); $U.cmbAutoPause.Size = New-Object System.Drawing.Size(($BW+$GAP+$BW-90), 26)
[void]$U.cmbAutoPause.Items.AddRange(@('Off','in 15 minutes','in 30 minutes','in 60 minutes','in 120 minutes'))
$pnlActions.Controls.Add($U.cmbAutoPause)
$U.lblApCountdown = New-Label $pnlActions '' ($M+2*($BW+$GAP)) $ay2 (720-$M-($M+2*($BW+$GAP))) 26 $clMuted $fCap 'Top,Left,Right'
$apHint = 'Pauses the selected capacity when the timer elapses - regardless of what happens in the cockpit or on the capacity. The cockpit only has to keep running (window or tray). One-shot: after pausing, the setting returns to Off.'
$tt.SetToolTip($U.cmbAutoPause, $apHint); $tt.SetToolTip($U.lblApCountdown, $apHint)

# ---------- row 4: auto-pause warning banner (hidden until 2 min before) ----------
$pnlBanner.BackColor = $clWarnBg; $pnlBanner.Visible = $false
$U.lblBanner   = New-Label $pnlBanner 'Auto-pause in 02:00' $M 7 220 26 $clAmber $fVal
$bx = 720 - $M - 3*120 - 2*$GAP
$U.btnApNow    = New-FlatButton $pnlBanner 'Pause now' $bx 5 120 $BH $clAmber 'Top,Right'
$U.btnApExtend = New-FlatButton $pnlBanner 'Extend'    ($bx+120+$GAP) 5 120 $BH $clBtnTxt 'Top,Right'
$U.btnApCancel = New-FlatButton $pnlBanner 'Cancel'    ($bx+2*(120+$GAP)) 5 120 $BH $clBtnTxt 'Top,Right'
$tt.SetToolTip($U.btnApExtend, 'Postpones the auto-pause by the chosen span')
$tt.SetToolTip($U.btnApCancel, 'Cancels the auto-pause timer (setting returns to Off)')

# ---------- row 5: details / links ----------
New-Heading $pnlDetails 'Click here for details:' 6 | Out-Null
$dy = 32
$U.btnPortal  = New-FlatButton $pnlDetails 'Capacity Overview'  $M $dy $BW $BH $clBtnTxt
$U.btnCostA   = New-FlatButton $pnlDetails 'Cost Analysis (RG)' ($M+$BW+$GAP) $dy $BW $BH $clBtnTxt
$U.btnMetrics = New-FlatButton $pnlDetails 'Metrics App'        ($M+2*($BW+$GAP)) $dy $BW $BH $clBtnTxt
$tt.SetToolTip($U.btnPortal,  'Azure portal: overview page of the selected capacity')
$tt.SetToolTip($U.btnCostA,   'Azure portal: cost analysis scoped to the resource group of the selected capacity')
$tt.SetToolTip($U.btnMetrics, 'Fabric Capacity Metrics app (metricsAppUrl in settings.json) or the Power BI Apps page')

# ---------- row 6/7: log ----------
New-Heading $pnlLogHead 'Log' 2 | Out-Null
$U.btnCopyLog = New-FlatButton $pnlLogHead 'Copy log' (720-$M-100) 0 100 24 $clBtnTxt 'Top,Right'
$U.btnCopyLog.Font = $fSmall
$U.txtLog = New-Object System.Windows.Forms.TextBox
$U.txtLog.Multiline = $true; $U.txtLog.ScrollBars = 'Vertical'; $U.txtLog.ReadOnly = $true
$U.txtLog.BorderStyle = 'FixedSingle'; $U.txtLog.BackColor = $clLogBg; $U.txtLog.ForeColor = $clLogFg; $U.txtLog.Font = $fMono
$U.txtLog.Dock = 'Fill'
$pnlLog.Padding = New-Object System.Windows.Forms.Padding($M, 0, $M, 0)
$pnlLog.Controls.Add($U.txtLog)

# ---------- row 8: pay-as-you-go footer ----------
$U.lblFooter = New-Label $pnlFooter ('Designed for F-SKUs with pay-as-you-go billing. Pausing saves the compute cost; OneLake storage is still billed. ' +
    'With an existing reservation, pausing yields no savings ' + $chDash + ' this tool cannot detect reservations.') 0 0 10 10 $clMuted $fSmall
$U.lblFooter.TextAlign = 'TopLeft'; $U.lblFooter.Dock = 'Fill'
$pnlFooter.Padding = New-Object System.Windows.Forms.Padding($M, 6, $M, 4)

# ---------- tray ----------
$U.tray = New-Object System.Windows.Forms.NotifyIcon
$U.tray.Icon = $I.unknown
$U.tray.Text = 'Fabric Capacity Cockpit'
$U.menu = New-Object System.Windows.Forms.ContextMenuStrip
$U.menu.Font = $fCap
$U.miOpen   = $U.menu.Items.Add('Open cockpit')
[void]$U.menu.Items.Add('-')
$U.miResume = $U.menu.Items.Add('Resume')
$U.miPause  = $U.menu.Items.Add('Pause')
[void]$U.menu.Items.Add('-')
$U.miExit   = $U.menu.Items.Add('Exit')
$U.miOpen.Font = $fVal
$U.tray.ContextMenuStrip = $U.menu
$U.tray.Visible = $true

# ---------- helpers ----------
function Format-Elapsed([timespan]$ts) { return ('{0:00}:{1:00}' -f [int][math]::Floor($ts.TotalMinutes), $ts.Seconds) }

function Write-Log([string]$msg) {
    $ts = (Get-Date).ToString('HH:mm:ss')
    if ($U.txtLog.TextLength -gt 400000) { $U.txtLog.Text = $U.txtLog.Text.Substring(200000) }
    $U.txtLog.AppendText("[$ts] $msg`r`n")
}
function Get-CapKey($c) { return ('{0}|{1}|{2}' -f $c.subscriptionId, $c.resourceGroup, $c.name).ToLowerInvariant() }

function Update-Tray {
    $st = $S.status
    $ico = $I.unknown
    if (-not $S.loggedIn)         { $ico = $I.error }
    elseif ($S.op)                { $ico = $I.busy }
    elseif ($st -eq 'Active')     { $ico = $I.active }
    elseif ($st -eq 'Paused')     { $ico = $I.paused }
    elseif ($st)                  { $ico = $I.busy }
    $U.tray.Icon = $ico; $form.Icon = $ico
    $name = if ($S.selected) { $S.selected.name } else { 'no capacity' }
    $line = if (-not $S.loggedIn) { 'not signed in' } elseif ($S.op) { $S.opVerb + ' ...' } elseif ($st) { $st } else { 'unknown' }
    if ($S.apDeadline) { $line += (' ' + $chDot + ' auto-pause {0:HH:mm}' -f $S.apDeadline) }
    $txt = 'Fabric Cockpit ' + $chDash + ' ' + $name + ': ' + $line
    if ($txt.Length -gt 63) { $txt = $txt.Substring(0, 63) }
    $U.tray.Text = $txt
    $U.miResume.Enabled = $U.btnResume.Enabled
    $U.miPause.Enabled  = $U.btnPause.Enabled
}

function Update-Controls {
    $li = [bool]$S.loggedIn; $sel = ($null -ne $S.selected); $op = [bool]$S.op
    $U.btnLogin.Enabled   = $S.azOk -and -not $S.loginBusy
    $U.btnLogin.Text      = if ($li) { 'Switch account' } else { 'Sign in' }
    $U.cmb.Enabled        = $li -and -not $S.listBusy -and -not $op
    $U.btnReload.Enabled  = $li -and -not $S.listBusy -and -not $S.loginBusy
    $U.btnRefresh.Enabled = $li -and $sel -and -not $S.statusBusy -and -not $op
    $U.btnResume.Enabled  = $li -and $sel -and -not $op
    $U.btnPause.Enabled   = $li -and $sel -and -not $op
    $U.cmbAutoPause.Enabled = $li -and $sel
    foreach ($b in @($U.btnPortal,$U.btnCostA,$U.btnMetrics)) { $b.Enabled = $sel }
    $U.pnlOp.Visible = $op
    Update-Tray
}

function Show-Banner([bool]$on) {
    if ($on) { $root.RowStyles[4].Height = 40; $pnlBanner.Visible = $true }
    else     { $pnlBanner.Visible = $false; $root.RowStyles[4].Height = 0 }
}

function Show-Card($c) {
    if ($null -eq $c) {
        foreach ($l in @($U.lblName,$U.lblSub,$U.lblRg,$U.lblRegion,$U.lblSku,$U.lblStatus,$U.lblProv,$U.lblCost,$U.lblUpdated)) { $l.Text = '' }
        $U.lblStatus.ForeColor = $clInk; $S.status = ''
        Update-Tray
        return
    }
    $U.lblName.Text   = $c.name
    if ($c.subscriptionName) { $U.lblSub.Text = $c.subscriptionName } elseif ($c.subscriptionId) { $U.lblSub.Text = $c.subscriptionId }
    $U.lblRg.Text     = $c.resourceGroup
    $U.lblRegion.Text = $c.location
    $U.lblSku.Text    = $c.sku
    $st = if ($c.state) { [string]$c.state } else { '(unknown)' }
    $U.lblStatus.Text = $st
    $U.lblStatus.ForeColor = if ($st -eq 'Active') { $clGreen } elseif ($st -eq 'Paused') { $clAmber } else { $clBlue }
    $U.lblProv.Text   = if ($c.provisioningState) { $c.provisioningState } else { '(unknown)' }
    $S.status = $st
    Update-Tray
}
function Set-Updated([string]$text) { $U.lblUpdated.Text = $text }

function Set-LoggedIn($acct) {
    $S.loggedIn = $true; $S.account = $acct
    $shortTenant = ($acct.TenantId -split '-')[0]
    $U.lblAccount.Text = ('{0} {1} {2} Tenant {3}' -f $chCheck, $acct.User, $chDot, $shortTenant)
    $U.lblAccount.ForeColor = $clGreen
    $tip = ('Tenant {0}' + [char]10 + 'Default subscription: {1}') -f $acct.TenantId, $acct.SubscriptionName
    $tt.SetToolTip($U.lblAccount, $tip)
    Update-Controls
}
function Set-LoggedOut([string]$headline) {
    $wasIn = $S.loggedIn
    $S.loggedIn = $false; $S.account = $null
    $U.lblAccount.Text = ('{0} {1}' -f $chCross, $headline)
    $U.lblAccount.ForeColor = $clRed
    $tt.SetToolTip($U.lblAccount, '')
    if ($U.lblCost.Text -eq '(loading ...)') { $U.lblCost.Text = '-' }
    if ($S.op) { Finish-Operation 'cancelled' }
    if ($S.apDeadline) { Clear-AutoPause; Write-Log 'Auto-pause timer cancelled (not signed in).' }
    if ($wasIn) { Write-Log ('Sign-in state lost: {0}. Auto-refresh is on hold until you sign in again.' -f $headline) }
    else { Write-Log ("{0} - use 'Sign in'." -f $headline) }
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
    if ($c) {
        $S.settings.lastCapacity = @{ subscriptionId = $c.subscriptionId; resourceGroup = $c.resourceGroup; name = $c.name }
        try { Save-CockpitSettings $S.settings } catch { }
        Write-Log ("Selected capacity '{0}' ({1} / {2})." -f $c.name, $c.subscriptionName, $c.resourceGroup)
        if ($S.apDeadline) { Write-Log ('Note: the running auto-pause timer ({0:HH:mm}) now applies to this capacity.' -f $S.apDeadline) }
    }
    Update-Controls
    if ($c -and $S.loggedIn) { Invoke-StatusRefresh }
}

function Invoke-ListRefresh {
    if ($S.listBusy -or -not $S.loggedIn) { return }
    $S.listBusy = $true
    Write-Log 'Loading capacities ...'
    Update-Controls
    Start-Async -Work $wList -WorkArgs @($common) -OnDone {
        param($r)
        $S.listBusy = $false
        if (-not $r -or -not $r.Ok) {
            foreach ($e in @($r.Errors)) { if ($e) { Write-Log ('Capacity list: ' + $e) } }
            if ($r.AuthError) { Set-LoggedOut 'Sign-in expired' } else { Write-Log 'Could not load capacities.' }
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
            Write-Log 'No Fabric capacities found. Check the signed-in account / tenant.'
            Select-Capacity $null
        } elseif ($kept) {
            # keep the selection; the list record already carries a fresh state
            $S.selected = $U.cmb.SelectedItem.Record
            Show-Card $S.selected
        } else {
            Write-Log ('Capacity list updated ({0} found) - pick a capacity.' -f $items.Count)
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
    Set-Updated 'refreshing ...'
    Update-Controls
    Start-Async -Work $wStatus -WorkArgs @($common,$cap.subscriptionId,$cap.resourceGroup,$cap.name,$cap.subscriptionName) -OnDone {
        param($r)
        $S.statusBusy = $false
        Update-Controls
        if (-not $S.selected -or (Get-CapKey $S.selected) -ne $key) { return }
        if (-not $r -or -not $r.Ok) {
            Write-Log ('Status query failed: ' + $r.Error)
            if ($r.AuthError) { Set-LoggedOut 'Sign-in expired' }
            else { Set-Updated ('refresh failed {0} - see log' -f (Get-Date).ToString('HH:mm:ss')); $U.lblStatus.Text = '(error)'; $U.lblStatus.ForeColor = $clRed }
            return
        }
        Show-Card $r.Item
        Set-Updated ('updated {0}' -f (Get-Date).ToString('HH:mm:ss'))
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
    Update-Controls
    Write-Log ("{0} capacity '{1}' ... ({2})" -f $S.opVerb, $cap.name, $reason)
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
        Set-Updated ('updated {0}' -f (Get-Date).ToString('HH:mm:ss'))
        if ($st -eq $S.opTarget) { Finish-Operation 'success'; return }
        if (((Get-Date) - $S.opStart).TotalMinutes -ge 10) { Finish-Operation 'timeout' }
    }
}

function Finish-Operation([string]$how) {
    $T.poll.Stop()
    $dur  = Format-Elapsed ((Get-Date) - $S.opStart)
    $verb = $S.opVerb; $target = $S.opTarget
    $S.op = ''; $S.pollBusy = $false
    switch ($how) {
        'success'   { Write-Log ('{0} finished - state {1} reached after {2}.' -f $verb, $target, $dur)
                      if (-not $form.Visible) { $U.tray.ShowBalloonTip(5000, 'Fabric Cockpit', ('{0}: {1} ({2})' -f $S.selected.name, $target, $dur), [System.Windows.Forms.ToolTipIcon]::Info) }
                      Update-Controls; Invoke-StatusRefresh -Silent; return }
        'cancelled' { Write-Log ('Waiting cancelled after {0}. The operation in Azure continues; the next refresh picks up the state.' -f $dur) }
        'timeout'   { $l = Get-FabricLinks -Capacity $S.selected -MetricsAppUrl $S.settings.metricsAppUrl
                      Write-Log ('Target state {0} not reached after 10 minutes. Check the status in the Azure portal: {1}' -f $target, $l.Portal)
                      Set-Updated 'target state not reached after 10 min - check the portal' }
        'failed'    { Write-Log ($verb + ' failed.')
                      if (-not $form.Visible) { $U.tray.ShowBalloonTip(5000, 'Fabric Cockpit', ($verb + ' failed - see log.'), [System.Windows.Forms.ToolTipIcon]::Error) } }
    }
    Update-Controls
}

function Confirm-Operation([string]$action) {
    $cap = $S.selected
    if ($action -eq 'pause') {
        $msg = "Pause capacity '$($cap.name)'?`n`nTarget state: Paused.`nAssigned workspaces are unavailable until the capacity is resumed.`nOneLake storage is still billed while paused."
        $r = [System.Windows.Forms.MessageBox]::Show($msg, 'Confirm pause', 'YesNo', 'Warning', 'Button1', 'DefaultDesktopOnly')
    } else {
        $msg = "Resume capacity '$($cap.name)'?`n`nTarget state: Active.`nCompute billing starts again as soon as the capacity is active."
        $r = [System.Windows.Forms.MessageBox]::Show($msg, 'Confirm resume', 'YesNo', 'Question', 'Button1', 'DefaultDesktopOnly')
    }
    return ($r -eq [System.Windows.Forms.DialogResult]::Yes)
}
function Request-Operation([string]$action) {
    if ($S.op -or -not $S.selected -or -not $S.loggedIn) { return }
    if (Confirm-Operation $action) { Start-Operation $action 'manual' }
}

# ---------- sign-in ----------
function Invoke-Login {
    if ($S.loginBusy -or -not $S.azOk) { return }
    $S.loginBusy = $true
    $U.lblAccount.Text = 'Signing in - please complete the sign-in in the browser window ...'
    $U.lblAccount.ForeColor = $clAmber
    Write-Log "Starting 'az login' - complete the sign-in in the browser."
    Update-Controls
    Start-Async -Work $wLogin -WorkArgs @($common) -OnDone {
        param($r)
        $S.loginBusy = $false
        if ($r -and $r.Account -and $r.Account.LoggedIn) {
            Set-LoggedIn $r.Account
            Write-Log ('Signed in as {0} (tenant {1}).' -f $r.Account.User, $r.Account.TenantId)
            Invoke-ListRefresh
            if ($S.selected) { Invoke-StatusRefresh }
        } else {
            $err = if ($r) { ($r.Out).Trim() } else { 'no result' }
            Write-Log ("'az login' did not complete: " + $err)
            Set-LoggedOut 'Not signed in'
        }
    }
}

# ---------- auto-pause timer ----------
function Clear-AutoPause {
    $S.apDeadline = $null; $S.apMinutes = 0
    $S.loading = $true; $U.cmbAutoPause.SelectedIndex = 0; $S.loading = $false
    $U.lblApCountdown.Text = ''
    Show-Banner $false
    Update-Tray
}
function Set-AutoPause([int]$minutes) {
    $S.apMinutes = $minutes
    $S.apDeadline = (Get-Date).AddMinutes($minutes)
    Show-Banner $false
    Write-Log ("Auto-pause set: capacity '{0}' will be paused at {1:HH:mm} (in {2} min)." -f $S.selected.name, $S.apDeadline, $minutes)
    if ($S.status -eq 'Paused') { Write-Log 'Note: the capacity is currently paused; the timer runs anyway.' }
    Update-AutoPause
    Update-Tray
}
function Update-AutoPause {
    if (-not $S.apDeadline) { return }
    $rem = $S.apDeadline - (Get-Date)
    if ($rem.TotalSeconds -le 0) {
        if ($S.op) { $U.lblApCountdown.Text = 'waiting for the running operation ...'; return }
        $m = $S.apMinutes
        Clear-AutoPause
        if (-not $S.loggedIn -or -not $S.selected) { Write-Log 'Auto-pause timer elapsed - skipped (not signed in / no capacity).'; return }
        if ($S.status -eq 'Paused') { Write-Log 'Auto-pause timer elapsed - capacity is already paused.'; return }
        Start-Operation 'pause' ('Auto-pause timer, {0} min' -f $m)
        return
    }
    $U.lblApCountdown.Text = ('pauses at {0:HH:mm} (in {1})' -f $S.apDeadline, (Format-Elapsed $rem))
    if ($rem.TotalSeconds -le 120) {
        $U.lblBanner.Text = 'Auto-pause in ' + (Format-Elapsed $rem)
        if (-not $pnlBanner.Visible) {
            Show-Banner $true
            Write-Log ('Auto-pause warning: pausing in {0}.' -f (Format-Elapsed $rem))
            if (-not $form.Visible) { $U.tray.ShowBalloonTip(10000, 'Fabric Cockpit', ("Auto-pause of '{0}' in 2 minutes." -f $S.selected.name), [System.Windows.Forms.ToolTipIcon]::Warning) }
        }
    } elseif ($pnlBanner.Visible) { Show-Banner $false }
}

# ---------- window show / hide (tray) ----------
function Show-Window {
    $form.Show()
    if ($form.WindowState -eq 'Minimized') { $form.WindowState = 'Normal' }
    $form.Activate()
}
function Hide-Window {
    $form.Hide()
    if (-not $S.trayHintShown) {
        $S.trayHintShown = $true
        $U.tray.ShowBalloonTip(4000, 'Fabric Cockpit', "Still running in the tray. Use 'Exit' in the tray menu to quit.", [System.Windows.Forms.ToolTipIcon]::Info)
    }
}

# ---------- handlers ----------
$U.btnLogin.Add_Click({ Invoke-Login })
$U.btnReload.Add_Click({ Invoke-ListRefresh })
$U.btnRefresh.Add_Click({ Invoke-StatusRefresh })

$U.cmb.Add_SelectedIndexChanged({
    if ($S.loading) { return }
    $it = $U.cmb.SelectedItem
    Select-Capacity $(if ($it) { $it.Record } else { $null })
})

$U.btnResume.Add_Click({ Request-Operation 'resume' })
$U.btnPause.Add_Click({  Request-Operation 'pause' })
$U.btnStopWait.Add_Click({ if ($S.op) { Finish-Operation 'cancelled' } })

$U.btnApNow.Add_Click({ Clear-AutoPause; Write-Log 'Auto-pause: pausing now on request.'; Start-Operation 'pause' 'auto-pause banner: Pause now' })
$U.btnApExtend.Add_Click({
    if (-not $S.apDeadline) { return }
    $S.apDeadline = $S.apDeadline.AddMinutes($S.apMinutes)
    Show-Banner $false
    Write-Log ('Auto-pause postponed by {0} min - now at {1:HH:mm}.' -f $S.apMinutes, $S.apDeadline)
    Update-AutoPause; Update-Tray
})
$U.btnApCancel.Add_Click({ Clear-AutoPause; Write-Log 'Auto-pause cancelled.' })

$U.cmbAutoPause.Add_SelectedIndexChanged({
    if ($S.loading) { return }
    $m = [int]$S.apValues[[math]::Max(0, $U.cmbAutoPause.SelectedIndex)]
    if ($m -le 0) { if ($S.apDeadline) { Clear-AutoPause; Write-Log 'Auto-pause cancelled.' } ; return }
    if (-not $S.selected) { Clear-AutoPause; return }
    Set-AutoPause $m
})

$U.chkAuto.Add_CheckedChanged({ if ($U.chkAuto.Checked) { $T.auto.Start() } else { $T.auto.Stop() } })

function Open-Link([string]$which,[string]$label) {
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
    try { [System.Windows.Forms.Clipboard]::SetText($U.txtLog.Text); Write-Log 'Log copied to clipboard.' }
    catch { Write-Log ('Copy failed: ' + $_.Exception.Message) }
})

# tray
$U.miOpen.Add_Click({ Show-Window })
$U.tray.Add_DoubleClick({ Show-Window })
$U.miResume.Add_Click({ Request-Operation 'resume' })
$U.miPause.Add_Click({  Request-Operation 'pause' })
$U.miExit.Add_Click({ $S.exiting = $true; $form.Close() })

# ---------- timers ----------
$T.auto = New-Object System.Windows.Forms.Timer
$T.auto.Interval = [int]$S.settings.autoRefreshSeconds * 1000
$T.auto.Add_Tick({ Invoke-StatusRefresh -Silent })

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
    $S.loading = $true; $U.cmbAutoPause.SelectedIndex = 0; $S.loading = $false
    Show-Card $null
    Write-Log ('Settings: ' + (Get-CockpitSettingsPath))
    $cache = @($S.settings.capacityCache)
    $lc = $S.settings.lastCapacity
    $lastKey = if ($lc -and $lc.name) { ('{0}|{1}|{2}' -f $lc.subscriptionId, $lc.resourceGroup, $lc.name).ToLowerInvariant() } else { '' }
    if ($cache.Count -gt 0) {
        $found = Populate-Combo $cache $lastKey
        Write-Log ('Loaded {0} capacity(ies) from cache (updated {1}).' -f $cache.Count, $S.settings.capacityCacheUpdated)
        if ($found) { $S.selected = $U.cmb.SelectedItem.Record; Show-Card $S.selected; $U.lblCost.Text = '(loading ...)'; Set-Updated 'cached' }
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
        Write-Log 'Install the Azure CLI from https://aka.ms/installazurecli and restart the cockpit.'
        return
    }
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

$form.Add_FormClosing({ param($sender,$e)
    if (-not $S.exiting -and $e.CloseReason -eq [System.Windows.Forms.CloseReason]::UserClosing) {
        $e.Cancel = $true
        Hide-Window
        return
    }
    foreach ($t in $T.Values) { try { $t.Stop() } catch { } }
    try { Save-CockpitSettings $S.settings } catch { }
    $U.tray.Visible = $false
})

[System.Windows.Forms.Application]::Run($form)
$U.tray.Dispose()
foreach ($t in $T.Values) { try { $t.Dispose() } catch { } }
