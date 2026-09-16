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
$CockpitVersion = '0.51.0'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# Hide the console window this script may have inherited (belt and braces next to the launcher).
Add-Type -Name ConsoleWin -Namespace Cockpit -MemberDefinition @"
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")]   public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
"@
try { $hCon = [Cockpit.ConsoleWin]::GetConsoleWindow(); if ($hCon -ne [IntPtr]::Zero) { [void][Cockpit.ConsoleWin]::ShowWindow($hCon, 0) } } catch { }

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
$ST = @{   # state (multi-letter names on purpose: PowerShell variables are case-insensitive, $s/$i/$t loop vars would clash)
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
$UI = @{}   # controls
$TM = @{}   # timers
$ICO = @{}   # icons

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
$MG   = 16    # outer margin
$BW  = 150   # standard button width
$BH  = 30    # standard button height
$GAP = 8     # gap between buttons
$SBW = 120   # small button width (header / picker)
$SBH = 26    # small button height

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
    $dotIcon = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
    $bmp.Dispose()
    return $dotIcon
}
$ICO.active  = New-DotIcon $clGreen
$ICO.paused  = New-DotIcon $clAmber
$ICO.busy    = New-DotIcon $clBlue
$ICO.unknown = New-DotIcon $clGray
$ICO.error   = New-DotIcon $clRed

# ---------- form ----------
$form = New-Object System.Windows.Forms.Form
$form.Text          = 'Fabric Capacity Cockpit ' + $chDash + ' Pay-as-you-go (F-SKU)'
$form.ClientSize    = New-Object System.Drawing.Size(720, 712)
$form.MinimumSize   = New-Object System.Drawing.Size(736, 660)
$form.StartPosition = 'CenterScreen'
$form.BackColor     = $clBg
$form.Font          = $fCap
$form.Icon          = $ICO.unknown

$root = New-Object System.Windows.Forms.TableLayoutPanel
$root.Dock = 'Fill'; $root.ColumnCount = 1
$root.Padding = New-Object System.Windows.Forms.Padding(0)
[void]$root.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
$form.Controls.Add($root)

# rows: header, picker, card, actions, banner (0 until shown), details, log head, log (fill), footer
$rowHeights = @(58, 46, 254, 70, 0, 68, 26, -1, 56)
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
    return (New-Label $parent $text $MG $y 400 22 $clMuted $fLegend)
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
$UI.lblAccount = New-Label $pnlHeader ('Checking sign-in ' + $chDash + ' please wait ...') $MG 14 520 $BH $clMuted $fVal 'Top,Left,Right'
$UI.btnLogin   = New-FlatButton $pnlHeader 'Sign in' (720-$MG-$SBW) 16 $SBW $SBH $clBtnTxt 'Top,Right'
$tt.SetToolTip($UI.btnLogin, "Runs 'az login' - a browser window opens. Also use this to switch tenant/account.")

# ---------- row 1: capacity picker ----------
New-Label $pnlPick 'Capacity' $MG 12 80 24 $clMuted $fLegend | Out-Null
$UI.cmb = New-Object System.Windows.Forms.ComboBox
$UI.cmb.DropDownStyle = 'DropDownList'; $UI.cmb.Font = $fCap
$UI.cmb.Location = New-Object System.Drawing.Point(96, 11); $UI.cmb.Size = New-Object System.Drawing.Size((720-96-$MG-$SBW-$GAP), 26)
$UI.cmb.Anchor = 'Top,Left,Right'
$pnlPick.Controls.Add($UI.cmb)
$UI.btnReload = New-FlatButton $pnlPick 'Reload list' (720-$MG-$SBW) 11 $SBW $SBH $clBtnTxt 'Top,Right'
$tt.SetToolTip($UI.btnReload, 'Re-query all enabled subscriptions for Fabric capacities')
$tt.SetToolTip($UI.cmb, 'Name ' + $chDash + ' Subscription / Resource group')

# ---------- row 2: info card (full width; refresh controls in its header) ----------
$card = New-Object System.Windows.Forms.Panel
$card.Location = New-Object System.Drawing.Point($MG, 4); $card.Size = New-Object System.Drawing.Size((720-2*$MG), 246)
$card.BackColor = $clCard; $card.Anchor = 'Top,Left,Right'
$card.Add_Paint({ param($sender,$e)
    $pen = New-Object System.Drawing.Pen $clBorder
    $e.Graphics.DrawRectangle($pen, 0, 0, $sender.Width-1, $sender.Height-1)
    $pen.Dispose()
})
$pnlCard.Controls.Add($card)
New-Label $card 'Capacity Info' 12 10 200 22 $clLegend $fLegend | Out-Null

$UI.chkAuto = New-Object System.Windows.Forms.CheckBox
$UI.chkAuto.Text = ('Auto-refresh ({0}s)' -f [int]$ST.settings.autoRefreshSeconds)
$UI.chkAuto.ForeColor = $clInk; $UI.chkAuto.Font = $fCap
$UI.chkAuto.AutoSize = $true
$UI.chkAuto.Anchor = 'Top,Right'
$card.Controls.Add($UI.chkAuto)
# right edge flush with the Refresh button below (AutoSize first, then position by measured width)
$UI.chkAuto.Location = New-Object System.Drawing.Point(($card.Width-12-$UI.chkAuto.Width), 10)
$UI.btnRefresh = New-FlatButton $card 'Refresh' ($card.Width-12-100) 40 100 $SBH $clBtnTxt 'Top,Right'
$tt.SetToolTip($UI.btnRefresh, 'Reload status and cost of the selected capacity')

function New-CardRow([string]$caption,[int]$y) {
    New-Label $card $caption 14 $y 128 22 $clMuted $fCap | Out-Null
    return (New-Label $card '' 148 $y 300 22 $clInk $fVal)
}
$y = 42; $step = 25
$UI.lblName   = New-CardRow 'Name'           $y; $y += $step
$UI.lblSub    = New-CardRow 'Subscription'   $y; $y += $step
$UI.lblRg     = New-CardRow 'Resource group' $y; $y += $step
$UI.lblRegion = New-CardRow 'Region'         $y; $y += $step
$UI.lblSku    = New-CardRow 'SKU'            $y; $y += $step
$UI.lblStatus = New-CardRow 'Status'         $y
$UI.lblStatus.AutoSize = $true
$UI.lblUpdated = New-Label $card '' 148 $y 300 22 $clInk $fVal
$UI.lblUpdated.AutoSize = $true
$y += $step
$UI.lblProv   = New-CardRow 'Provisioning'   $y; $y += $step
$UI.lblCost   = New-CardRow 'Cost (MTD)'     $y; $y += $step
$tt.SetToolTip($UI.lblCost, 'Month-to-date cost of this capacity (Cost Management, resource-level): compute (CU meters) plus OneLake storage. The storage share keeps accruing while the capacity is paused. Data has latency of up to ~24-48h.')

# ---------- row 3: capacity actions ----------
New-Heading $pnlActions 'Capacity actions:' 6 | Out-Null
$ay = 32
$UI.btnResume = New-FlatButton $pnlActions 'Resume' $MG $ay $BW $BH $clGreen
$UI.btnPause  = New-FlatButton $pnlActions 'Pause'  ($MG+$BW+$GAP) $ay $BW $BH $clAmber

$apx = $MG + 2*($BW+$GAP) + 8
New-Label $pnlActions 'Auto-pause' $apx ($ay+2) 84 26 $clMuted $fCap | Out-Null
$UI.cmbAutoPause = New-Object System.Windows.Forms.ComboBox
$UI.cmbAutoPause.DropDownStyle = 'DropDownList'; $UI.cmbAutoPause.Font = $fCap
$UI.cmbAutoPause.Location = New-Object System.Drawing.Point(($apx+84), ($ay+2)); $UI.cmbAutoPause.Size = New-Object System.Drawing.Size(130, 26)
[void]$UI.cmbAutoPause.Items.AddRange(@('Off','in 15 minutes','in 30 minutes','in 60 minutes','in 120 minutes'))
$pnlActions.Controls.Add($UI.cmbAutoPause)
$UI.lblApCountdown = New-Label $pnlActions '' ($apx+84+130+$GAP) ($ay+2) (720-$MG-($apx+84+130+$GAP)) 26 $clMuted $fSmall 'Top,Left,Right'
$apHint = 'Pauses the selected capacity when the timer elapses - regardless of what happens in the cockpit or on the capacity. The cockpit only has to keep running (window or tray). One-shot: after pausing, the setting returns to Off.'
$tt.SetToolTip($UI.cmbAutoPause, $apHint); $tt.SetToolTip($UI.lblApCountdown, $apHint)

$UI.pnlOp = New-Object System.Windows.Forms.Panel
$UI.pnlOp.Location = New-Object System.Drawing.Point($MG, ($ay+$BH+8)); $UI.pnlOp.Size = New-Object System.Drawing.Size((720-2*$MG), 34)
$UI.pnlOp.Anchor = 'Top,Left,Right'; $UI.pnlOp.Visible = $false
$pnlActions.Controls.Add($UI.pnlOp)
$UI.lblOp = New-Label $UI.pnlOp 'Working ...' 0 0 ($UI.pnlOp.Width-120-$GAP) 18 $clInk $fVal 'Top,Left,Right'
$UI.prg = New-Object System.Windows.Forms.ProgressBar
$UI.prg.Style = 'Marquee'; $UI.prg.MarqueeAnimationSpeed = 30
$UI.prg.Location = New-Object System.Drawing.Point(0, 22); $UI.prg.Size = New-Object System.Drawing.Size(($UI.pnlOp.Width-120-$GAP), 8); $UI.prg.Anchor = 'Top,Left,Right'
$UI.pnlOp.Controls.Add($UI.prg)
$UI.btnStopWait = New-FlatButton $UI.pnlOp 'Stop waiting' ($UI.pnlOp.Width-120) 2 120 $BH $clBtnTxt 'Top,Right'
$tt.SetToolTip($UI.btnStopWait, 'Stops only the polling in this window. The operation in Azure continues.')


# ---------- row 4: auto-pause warning banner (hidden until 2 min before) ----------
$pnlBanner.BackColor = $clWarnBg; $pnlBanner.Visible = $false
$UI.lblBanner   = New-Label $pnlBanner 'Auto-pause in 02:00' $MG 7 220 26 $clAmber $fVal
$bx = 720 - $MG - 3*120 - 2*$GAP
$UI.btnApNow    = New-FlatButton $pnlBanner 'Pause now' $bx 5 120 $BH $clAmber 'Top,Right'
$UI.btnApExtend = New-FlatButton $pnlBanner 'Extend'    ($bx+120+$GAP) 5 120 $BH $clBtnTxt 'Top,Right'
$UI.btnApCancel = New-FlatButton $pnlBanner 'Cancel'    ($bx+2*(120+$GAP)) 5 120 $BH $clBtnTxt 'Top,Right'
$tt.SetToolTip($UI.btnApExtend, 'Postpones the auto-pause by the chosen span')
$tt.SetToolTip($UI.btnApCancel, 'Cancels the auto-pause timer (setting returns to Off)')

# ---------- row 5: details / links ----------
New-Heading $pnlDetails 'Click here for details:' 6 | Out-Null
$dy = 32
$UI.btnPortal  = New-FlatButton $pnlDetails 'Capacity Overview'  $MG $dy $BW $BH $clBtnTxt
$UI.btnCostA   = New-FlatButton $pnlDetails 'Cost Analysis (RG)' ($MG+$BW+$GAP) $dy $BW $BH $clBtnTxt
$UI.btnMetrics = New-FlatButton $pnlDetails 'Metrics App'        ($MG+2*($BW+$GAP)) $dy $BW $BH $clBtnTxt
$tt.SetToolTip($UI.btnPortal,  'Azure portal: overview page of the selected capacity')
$tt.SetToolTip($UI.btnCostA,   'Azure portal: cost analysis scoped to the resource group of the selected capacity')
$tt.SetToolTip($UI.btnMetrics, 'Fabric Capacity Metrics app (metricsAppUrl in settings.json) or the Power BI Apps page')

# ---------- row 6/7: log ----------
New-Heading $pnlLogHead 'Log' 2 | Out-Null
$UI.btnCopyLog = New-FlatButton $pnlLogHead 'Copy log' (720-$MG-100) 0 100 24 $clBtnTxt 'Top,Right'
$UI.btnCopyLog.Font = $fSmall
$UI.txtLog = New-Object System.Windows.Forms.TextBox
$UI.txtLog.Multiline = $true; $UI.txtLog.ScrollBars = 'Vertical'; $UI.txtLog.ReadOnly = $true
$UI.txtLog.BorderStyle = 'FixedSingle'; $UI.txtLog.BackColor = $clLogBg; $UI.txtLog.ForeColor = $clLogFg; $UI.txtLog.Font = $fMono
$UI.txtLog.Dock = 'Fill'
$pnlLog.Padding = New-Object System.Windows.Forms.Padding($MG, 0, $MG, 0)
$pnlLog.Controls.Add($UI.txtLog)

# ---------- row 8: pay-as-you-go footer ----------
$UI.lblFooter = New-Label $pnlFooter ('Designed for F-SKUs with pay-as-you-go billing. Pausing saves the compute cost; OneLake storage is still billed. ' +
    'With an existing reservation, pausing yields no savings ' + $chDash + ' this tool cannot detect reservations.') 0 0 10 10 $clMuted $fSmall
$UI.lblFooter.TextAlign = 'TopLeft'; $UI.lblFooter.Dock = 'Fill'
$pnlFooter.Padding = New-Object System.Windows.Forms.Padding($MG, 6, $MG, 4)

# ---------- tray ----------
$UI.tray = New-Object System.Windows.Forms.NotifyIcon
$UI.tray.Icon = $ICO.unknown
$UI.tray.Text = 'Fabric Capacity Cockpit'
$UI.menu = New-Object System.Windows.Forms.ContextMenuStrip
$UI.menu.Font = $fCap
$UI.miOpen   = $UI.menu.Items.Add('Open cockpit')
[void]$UI.menu.Items.Add('-')
$UI.miResume = $UI.menu.Items.Add('Resume')
$UI.miPause  = $UI.menu.Items.Add('Pause')
[void]$UI.menu.Items.Add('-')
$UI.miExit   = $UI.menu.Items.Add('Exit')
$UI.miOpen.Font = $fVal
$UI.tray.ContextMenuStrip = $UI.menu
$UI.tray.Visible = $true

# ---------- helpers ----------
function Format-Elapsed([timespan]$ts) { return ('{0:00}:{1:00}' -f [int][math]::Floor($ts.TotalMinutes), $ts.Seconds) }

function Write-Log([string]$msg) {
    $ts = (Get-Date).ToString('HH:mm:ss')
    if ($UI.txtLog.TextLength -gt 400000) { $UI.txtLog.Text = $UI.txtLog.Text.Substring(200000) }
    $UI.txtLog.AppendText("[$ts] $msg`r`n")
}
function Format-Currency([string]$code) {
    switch ($code) { 'EUR' { return [string][char]0x20AC } 'USD' { return '$' } 'GBP' { return [string][char]0x00A3 } default { return $code } }
}
function Get-CapKey($c) { return ('{0}|{1}|{2}' -f $c.subscriptionId, $c.resourceGroup, $c.name).ToLowerInvariant() }

function Update-Tray {
    $stateText = $ST.status
    $dotIcon = $ICO.unknown
    if (-not $ST.loggedIn)         { $dotIcon = $ICO.error }
    elseif ($ST.op)                { $dotIcon = $ICO.busy }
    elseif ($stateText -eq 'Active')     { $dotIcon = $ICO.active }
    elseif ($stateText -eq 'Paused')     { $dotIcon = $ICO.paused }
    elseif ($stateText)                  { $dotIcon = $ICO.busy }
    $UI.tray.Icon = $dotIcon; $form.Icon = $dotIcon
    $name = if ($ST.selected) { $ST.selected.name } else { 'no capacity' }
    $line = if (-not $ST.loggedIn) { 'not signed in' } elseif ($ST.op) { $ST.opVerb + ' ...' } elseif ($stateText) { $stateText } else { 'unknown' }
    if ($ST.apDeadline) { $line += (' ' + $chDot + ' auto-pause {0:HH:mm}' -f $ST.apDeadline) }
    $txt = 'Fabric Cockpit ' + $chDash + ' ' + $name + ': ' + $line
    if ($txt.Length -gt 63) { $txt = $txt.Substring(0, 63) }
    $UI.tray.Text = $txt
    $UI.miResume.Enabled = $UI.btnResume.Enabled
    $UI.miPause.Enabled  = $UI.btnPause.Enabled
}

function Update-Controls {
    $li = [bool]$ST.loggedIn; $sel = ($null -ne $ST.selected); $op = [bool]$ST.op
    $UI.btnLogin.Enabled   = $ST.azOk -and -not $ST.loginBusy
    $UI.btnLogin.Text      = if ($li) { 'Switch account' } else { 'Sign in' }
    $UI.cmb.Enabled        = $li -and -not $ST.listBusy -and -not $op
    $UI.btnReload.Enabled  = $li -and -not $ST.listBusy -and -not $ST.loginBusy
    $UI.btnRefresh.Enabled = $li -and $sel -and -not $ST.statusBusy -and -not $op
    $UI.btnResume.Enabled  = $li -and $sel -and -not $op
    $UI.btnPause.Enabled   = $li -and $sel -and -not $op
    $UI.cmbAutoPause.Enabled = $li -and $sel
    foreach ($b in @($UI.btnPortal,$UI.btnCostA,$UI.btnMetrics)) { $b.Enabled = $sel }
    $UI.pnlOp.Visible = $op
    $root.RowStyles[3].Height = $(if ($op) { 112 } else { 70 })
    Update-Tray
}

function Show-Banner([bool]$on) {
    if ($on) { $root.RowStyles[4].Height = 40; $pnlBanner.Visible = $true }
    else     { $pnlBanner.Visible = $false; $root.RowStyles[4].Height = 0 }
}

function Show-Card($c) {
    if ($null -eq $c) {
        foreach ($l in @($UI.lblName,$UI.lblSub,$UI.lblRg,$UI.lblRegion,$UI.lblSku,$UI.lblStatus,$UI.lblProv,$UI.lblCost,$UI.lblUpdated)) { $l.Text = '' }
        $UI.lblStatus.ForeColor = $clInk; $ST.status = ''
        Update-Tray
        return
    }
    $UI.lblName.Text   = $c.name
    if ($c.subscriptionName) { $UI.lblSub.Text = $c.subscriptionName } elseif ($c.subscriptionId) { $UI.lblSub.Text = $c.subscriptionId }
    $UI.lblRg.Text     = $c.resourceGroup
    $UI.lblRegion.Text = $c.location
    $UI.lblSku.Text    = $c.sku
    $stateText = if ($c.state) { [string]$c.state } else { '(unknown)' }
    $UI.lblStatus.Text = $stateText
    $UI.lblStatus.ForeColor = if ($stateText -eq 'Active') { $clGreen } elseif ($stateText -eq 'Paused') { $clAmber } else { $clBlue }
    $UI.lblProv.Text   = if ($c.provisioningState) { $c.provisioningState } else { '(unknown)' }
    $UI.lblUpdated.Left = $UI.lblStatus.Left + $UI.lblStatus.Width + 4
    $ST.status = $stateText
    Update-Tray
}
function Set-Updated([string]$text) {
    $UI.lblUpdated.Text = if ($text) { '(' + $text + ')' } else { '' }
    $UI.lblUpdated.Left = $UI.lblStatus.Left + $UI.lblStatus.Width + 4
}

function Set-LoggedIn($acct) {
    $ST.loggedIn = $true; $ST.account = $acct
    $shortTenant = ($acct.TenantId -split '-')[0]
    $UI.lblAccount.Text = ('{0} {1} {2} Tenant {3}' -f $chCheck, $acct.User, $chDot, $shortTenant)
    $UI.lblAccount.ForeColor = $clGreen
    $tip = ('Tenant {0}' + [char]10 + 'Default subscription: {1}') -f $acct.TenantId, $acct.SubscriptionName
    $tt.SetToolTip($UI.lblAccount, $tip)
    Update-Controls
}
function Set-LoggedOut([string]$headline) {
    $wasIn = $ST.loggedIn
    $ST.loggedIn = $false; $ST.account = $null
    $UI.lblAccount.Text = ('{0} {1}' -f $chCross, $headline)
    $UI.lblAccount.ForeColor = $clRed
    $tt.SetToolTip($UI.lblAccount, '')
    if ($UI.lblCost.Text -eq '(loading ...)') { $UI.lblCost.Text = '-' }
    if ($ST.op) { Finish-Operation 'cancelled' }
    if ($ST.apDeadline) { Clear-AutoPause; Write-Log 'Auto-pause timer cancelled (not signed in).' }
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
    $ST.loading = $true
    $UI.cmb.Items.Clear()
    $idx = -1; $i = 0
    foreach ($c in $items) {
        $it = New-Object FabricCapacityItem
        $it.Key = Get-CapKey $c
        $it.Display = ('{0} {1} {2} / {3}' -f $c.name, $chDash, $c.subscriptionName, $c.resourceGroup)
        $it.Record = $c
        [void]$UI.cmb.Items.Add($it)
        if ($selectKey -and $it.Key -eq $selectKey) { $idx = $i }
        $i++
    }
    $UI.cmb.SelectedIndex = $idx
    $ST.loading = $false
    return ($idx -ge 0)
}

function Select-Capacity($c) {
    $ST.selected = $c
    Show-Card $c
    $UI.lblCost.Text = if ($c) { '(loading ...)' } else { '' }
    if ($c) {
        $ST.settings.lastCapacity = @{ subscriptionId = $c.subscriptionId; resourceGroup = $c.resourceGroup; name = $c.name }
        try { Save-CockpitSettings $ST.settings } catch { }
        Write-Log ("Selected capacity '{0}' ({1} / {2})." -f $c.name, $c.subscriptionName, $c.resourceGroup)
        if ($ST.apDeadline) { Write-Log ('Note: the running auto-pause timer ({0:HH:mm}) now applies to this capacity.' -f $ST.apDeadline) }
    }
    Update-Controls
    if ($c -and $ST.loggedIn) { Invoke-StatusRefresh }
}

function Invoke-ListRefresh {
    if ($ST.listBusy -or -not $ST.loggedIn) { return }
    $ST.listBusy = $true
    Write-Log 'Loading capacities ...'
    Update-Controls
    Start-Async -Work $wList -WorkArgs @($common) -OnDone {
        param($r)
        $ST.listBusy = $false
        if (-not $r -or -not $r.Ok) {
            foreach ($e in @($r.Errors)) { if ($e) { Write-Log ('Capacity list: ' + $e) } }
            if ($r.AuthError) { Set-LoggedOut 'Sign-in expired' } else { Write-Log 'Could not load capacities.' }
            Update-Controls
            return
        }
        foreach ($l in @($r.Log))    { Write-Log $l }
        foreach ($e in @($r.Errors)) { Write-Log ('  warning: ' + $e) }
        $items = @($r.Items)
        $ST.settings.capacityCache = $items
        $ST.settings.capacityCacheUpdated = (Get-Date).ToUniversalTime().ToString('o')
        try { Save-CockpitSettings $ST.settings } catch { Write-Log ('Could not save settings: ' + $_.Exception.Message) }

        $prevKey = if ($ST.selected) { Get-CapKey $ST.selected } else { '' }
        $kept = Populate-Combo $items $prevKey
        if ($items.Count -eq 0) {
            Write-Log 'No Fabric capacities found. Check the signed-in account / tenant.'
            Select-Capacity $null
        } elseif ($kept) {
            # keep the selection; the list record already carries a fresh state
            $ST.selected = $UI.cmb.SelectedItem.Record
            Show-Card $ST.selected
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
    $cap = $ST.selected
    if (-not $cap) { return }
    $key = Get-CapKey $cap
    $UI.lblCost.ForeColor = $clInk
    Start-Async -Work $wCost -WorkArgs @($costFunc,$cap.subscriptionId,$cap.resourceGroup,$cap.name,$env:TEMP) -OnDone {
        param($r)
        if (-not $ST.selected -or (Get-CapKey $ST.selected) -ne $key) { return }   # selection changed meanwhile
        if (-not $r) { $UI.lblCost.Text = '(error)'; return }
        if (-not $r.Ok) {
            if ($r.Throttled) { $UI.lblCost.Text = 'rate-limited (429) - retry later'; $UI.lblCost.ForeColor = $clAmber }
            else { $UI.lblCost.Text = 'n/a'; $UI.lblCost.ForeColor = $clRed }
            if ($r.Error) { Write-Log ('Cost: ' + $r.Error) }
            return
        }
        $suffix = if ($r.FromCache) { (' (cached {0:HH:mm})' -f $r.AsOf) } else { '' }
        if ($null -ne $r.FabricCost) {
            $cur = Format-Currency $r.FabricCurrency
            $storage = if ($null -ne $r.FabricStorageCost) { (' (of which storage {0} {1})' -f ([double]$r.FabricStorageCost).ToString('N2'), $cur) } else { '' }
            $UI.lblCost.Text = ('{0} {1}{2}{3}' -f ([double]$r.FabricCost).ToString('N2'), $cur, $storage, $suffix)
        } elseif (-not $r.Rows -or $r.Rows.Count -eq 0) {
            $UI.lblCost.Text = 'no data yet (latency ~24-48h)'
        } else {
            $UI.lblCost.Text = ('n/a for capacity; RG total {0} {1}{2}' -f ([double]$r.Total).ToString('N2'), (Format-Currency $r.Currency), $suffix)
        }
    }.GetNewClosure()
}

function Invoke-StatusRefresh([switch]$Silent) {
    $cap = $ST.selected
    if (-not $cap -or $ST.statusBusy -or -not $ST.loggedIn -or $ST.op) { return }
    $ST.statusBusy = $true
    $key = Get-CapKey $cap
    Set-Updated 'refreshing ...'
    Update-Controls
    Start-Async -Work $wStatus -WorkArgs @($common,$cap.subscriptionId,$cap.resourceGroup,$cap.name,$cap.subscriptionName) -OnDone {
        param($r)
        $ST.statusBusy = $false
        Update-Controls
        if (-not $ST.selected -or (Get-CapKey $ST.selected) -ne $key) { return }
        if (-not $r -or -not $r.Ok) {
            Write-Log ('Status query failed: ' + $r.Error)
            if ($r.AuthError) { Set-LoggedOut 'Sign-in expired' }
            else { Set-Updated ('refresh failed {0} - see log' -f (Get-Date).ToString('HH:mm:ss')); $UI.lblStatus.Text = '(error)'; $UI.lblStatus.ForeColor = $clRed }
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
    if ($ST.op -or -not $ST.selected -or -not $ST.loggedIn) { return }
    $cap = $ST.selected
    $ST.op = $action
    $ST.opTarget = if ($action -eq 'pause') { 'Paused' } else { 'Active' }
    $ST.opVerb   = if ($action -eq 'pause') { 'Pausing' } else { 'Resuming' }
    $ST.opStart  = Get-Date; $ST.opLastState = ''
    $UI.lblOp.Text = $ST.opVerb + ' ... (00:00)'
    Update-Controls
    Write-Log ("{0} capacity '{1}' ... ({2})" -f $ST.opVerb, $cap.name, $reason)
    $azAction = if ($action -eq 'pause') { 'suspend' } else { 'resume' }
    Start-Async -Work $wAction -WorkArgs @($common,$azAction,$cap.subscriptionId,$cap.resourceGroup,$cap.name) -OnDone {
        param($r)
        if (-not $ST.op) { return }
        if (-not $r -or -not $r.Ok) {
            Write-Log ('Command failed: ' + $r.Command)
            Write-Log ('  ' + $r.Error)
            if ($r.AuthError) { Set-LoggedOut 'Sign-in expired' } else { Finish-Operation 'failed' }
            return
        }
        Write-Log ('Command accepted (--no-wait): ' + $r.Command)
        $TM.poll.Start()
        Invoke-Poll
    }
}

function Invoke-Poll {
    if (-not $ST.op -or $ST.pollBusy) { return }
    $ST.pollBusy = $true
    $cap = $ST.selected
    Start-Async -Work $wStatus -WorkArgs @($common,$cap.subscriptionId,$cap.resourceGroup,$cap.name,$cap.subscriptionName) -OnDone {
        param($r)
        $ST.pollBusy = $false
        if (-not $ST.op) { return }
        if (-not $r -or -not $r.Ok) {
            Write-Log ('Poll failed: ' + $r.Error)
            if ($r.AuthError) { Set-LoggedOut 'Sign-in expired' }
            return
        }
        $stateText = [string]$r.Item.state
        if ($stateText -ne $ST.opLastState) {
            Write-Log ('  state: {0} (provisioning {1}) after {2}' -f $stateText, $r.Item.provisioningState, (Format-Elapsed ((Get-Date) - $ST.opStart)))
            $ST.opLastState = $stateText
        }
        Show-Card $r.Item
        Set-Updated ('updated {0}' -f (Get-Date).ToString('HH:mm:ss'))
        if ($stateText -eq $ST.opTarget) { Finish-Operation 'success'; return }
        if (((Get-Date) - $ST.opStart).TotalMinutes -ge 10) { Finish-Operation 'timeout' }
    }
}

function Finish-Operation([string]$how) {
    $TM.poll.Stop()
    $dur  = Format-Elapsed ((Get-Date) - $ST.opStart)
    $verb = $ST.opVerb; $target = $ST.opTarget
    $ST.op = ''; $ST.pollBusy = $false
    switch ($how) {
        'success'   { Write-Log ('{0} finished - state {1} reached after {2}.' -f $verb, $target, $dur)
                      if (-not $form.Visible) { $UI.tray.ShowBalloonTip(5000, 'Fabric Cockpit', ('{0}: {1} ({2})' -f $ST.selected.name, $target, $dur), [System.Windows.Forms.ToolTipIcon]::Info) }
                      Update-Controls; Invoke-StatusRefresh -Silent; return }
        'cancelled' { Write-Log ('Waiting cancelled after {0}. The operation in Azure continues; the next refresh picks up the state.' -f $dur) }
        'timeout'   { $l = Get-FabricLinks -Capacity $ST.selected -MetricsAppUrl $ST.settings.metricsAppUrl
                      Write-Log ('Target state {0} not reached after 10 minutes. Check the status in the Azure portal: {1}' -f $target, $l.Portal)
                      Set-Updated 'target state not reached after 10 min - check the portal' }
        'failed'    { Write-Log ($verb + ' failed.')
                      if (-not $form.Visible) { $UI.tray.ShowBalloonTip(5000, 'Fabric Cockpit', ($verb + ' failed - see log.'), [System.Windows.Forms.ToolTipIcon]::Error) } }
    }
    Update-Controls
}

function Confirm-Operation([string]$action) {
    $cap = $ST.selected
    if ($action -eq 'pause') {
        $msg = "Pause capacity '$($cap.name)'?`n`nTarget state: Paused.`nAssigned workspaces are unavailable until the capacity is resumed.`nOneLake storage is still billed while paused."
        $r = [System.Windows.Forms.MessageBox]::Show($msg, 'Confirm pause', 'YesNo', 'Warning')
    } else {
        $msg = "Resume capacity '$($cap.name)'?`n`nTarget state: Active.`nCompute billing starts again as soon as the capacity is active."
        $r = [System.Windows.Forms.MessageBox]::Show($msg, 'Confirm resume', 'YesNo', 'Question')
    }
    return ($r -eq [System.Windows.Forms.DialogResult]::Yes)
}
function Request-Operation([string]$action) {
    if ($ST.op -or -not $ST.selected -or -not $ST.loggedIn) { return }
    if (Confirm-Operation $action) { Start-Operation $action 'manual' }
}

# ---------- sign-in ----------
function Invoke-Login {
    if ($ST.loginBusy -or -not $ST.azOk) { return }
    $ST.loginBusy = $true
    $UI.lblAccount.Text = 'Signing in - please complete the sign-in in the browser window ...'
    $UI.lblAccount.ForeColor = $clAmber
    Write-Log "Starting 'az login' - complete the sign-in in the browser."
    Update-Controls
    Start-Async -Work $wLogin -WorkArgs @($common) -OnDone {
        param($r)
        $ST.loginBusy = $false
        if ($r -and $r.Account -and $r.Account.LoggedIn) {
            Set-LoggedIn $r.Account
            Write-Log ('Signed in as {0} (tenant {1}).' -f $r.Account.User, $r.Account.TenantId)
            Invoke-ListRefresh
            if ($ST.selected) { Invoke-StatusRefresh }
        } else {
            $err = if ($r) { ($r.Out).Trim() } else { 'no result' }
            Write-Log ("'az login' did not complete: " + $err)
            Set-LoggedOut 'Not signed in'
        }
    }
}

# ---------- auto-pause timer ----------
function Clear-AutoPause {
    $ST.apDeadline = $null; $ST.apMinutes = 0
    $ST.loading = $true; $UI.cmbAutoPause.SelectedIndex = 0; $ST.loading = $false
    $UI.lblApCountdown.Text = ''
    Show-Banner $false
    Update-Tray
}
function Set-AutoPause([int]$minutes) {
    $ST.apMinutes = $minutes
    $ST.apDeadline = (Get-Date).AddMinutes($minutes)
    Show-Banner $false
    Write-Log ("Auto-pause set: capacity '{0}' will be paused at {1:HH:mm} (in {2} min)." -f $ST.selected.name, $ST.apDeadline, $minutes)
    if ($ST.status -eq 'Paused') { Write-Log 'Note: the capacity is currently paused; the timer runs anyway.' }
    Update-AutoPause
    Update-Tray
}
function Update-AutoPause {
    if (-not $ST.apDeadline) { return }
    $rem = $ST.apDeadline - (Get-Date)
    if ($rem.TotalSeconds -le 0) {
        if ($ST.op) { $UI.lblApCountdown.Text = 'waiting for the running operation ...'; return }
        $m = $ST.apMinutes
        Clear-AutoPause
        if (-not $ST.loggedIn -or -not $ST.selected) { Write-Log 'Auto-pause timer elapsed - skipped (not signed in / no capacity).'; return }
        if ($ST.status -eq 'Paused') { Write-Log 'Auto-pause timer elapsed - capacity is already paused.'; return }
        Start-Operation 'pause' ('Auto-pause timer, {0} min' -f $m)
        return
    }
    $UI.lblApCountdown.Text = ('at {0:HH:mm} (in {1})' -f $ST.apDeadline, (Format-Elapsed $rem))
    if ($rem.TotalSeconds -le 120) {
        $UI.lblBanner.Text = 'Auto-pause in ' + (Format-Elapsed $rem)
        if (-not $pnlBanner.Visible) {
            Show-Banner $true
            Write-Log ('Auto-pause warning: pausing in {0}.' -f (Format-Elapsed $rem))
            if (-not $form.Visible) { $UI.tray.ShowBalloonTip(10000, 'Fabric Cockpit', ("Auto-pause of '{0}' in 2 minutes." -f $ST.selected.name), [System.Windows.Forms.ToolTipIcon]::Warning) }
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
    if (-not $ST.trayHintShown) {
        $ST.trayHintShown = $true
        $UI.tray.ShowBalloonTip(4000, 'Fabric Cockpit', "Still running in the tray. Use 'Exit' in the tray menu to quit.", [System.Windows.Forms.ToolTipIcon]::Info)
    }
}

# ---------- handlers ----------
$UI.btnLogin.Add_Click({ Invoke-Login })
$UI.btnReload.Add_Click({ Invoke-ListRefresh })
$UI.btnRefresh.Add_Click({ Invoke-StatusRefresh })

$UI.cmb.Add_SelectedIndexChanged({
    if ($ST.loading) { return }
    $it = $UI.cmb.SelectedItem
    Select-Capacity $(if ($it) { $it.Record } else { $null })
})

$UI.btnResume.Add_Click({ Request-Operation 'resume' })
$UI.btnPause.Add_Click({  Request-Operation 'pause' })
$UI.btnStopWait.Add_Click({ if ($ST.op) { Finish-Operation 'cancelled' } })

$UI.btnApNow.Add_Click({ Clear-AutoPause; Write-Log 'Auto-pause: pausing now on request.'; Start-Operation 'pause' 'auto-pause banner: Pause now' })
$UI.btnApExtend.Add_Click({
    if (-not $ST.apDeadline) { return }
    $ST.apDeadline = $ST.apDeadline.AddMinutes($ST.apMinutes)
    Show-Banner $false
    Write-Log ('Auto-pause postponed by {0} min - now at {1:HH:mm}.' -f $ST.apMinutes, $ST.apDeadline)
    Update-AutoPause; Update-Tray
})
$UI.btnApCancel.Add_Click({ Clear-AutoPause; Write-Log 'Auto-pause cancelled.' })

$UI.cmbAutoPause.Add_SelectedIndexChanged({
    if ($ST.loading) { return }
    $m = [int]$ST.apValues[[math]::Max(0, $UI.cmbAutoPause.SelectedIndex)]
    if ($m -le 0) { if ($ST.apDeadline) { Clear-AutoPause; Write-Log 'Auto-pause cancelled.' } ; return }
    if (-not $ST.selected) { Clear-AutoPause; return }
    Set-AutoPause $m
})

$UI.chkAuto.Add_CheckedChanged({ if ($UI.chkAuto.Checked) { $TM.auto.Start() } else { $TM.auto.Stop() } })

function Open-Link([string]$which,[string]$label) {
    if (-not $ST.selected) { return }
    try {
        $l = Get-FabricLinks -Capacity $ST.selected -MetricsAppUrl $ST.settings.metricsAppUrl
        Start-Process $l.$which
        Write-Log ('Opened {0}.' -f $label)
    } catch { Write-Log ('Could not open {0}: {1}' -f $label, $_.Exception.Message) }
}
$UI.btnPortal.Add_Click({  Open-Link 'Portal'  'capacity overview' })
$UI.btnCostA.Add_Click({   Open-Link 'Cost'    'cost analysis (RG)' })
$UI.btnMetrics.Add_Click({ Open-Link 'Metrics' 'Metrics app' })

$UI.btnCopyLog.Add_Click({
    try { [System.Windows.Forms.Clipboard]::SetText($UI.txtLog.Text); Write-Log 'Log copied to clipboard.' }
    catch { Write-Log ('Copy failed: ' + $_.Exception.Message) }
})

# tray
$UI.miOpen.Add_Click({ Show-Window })
$UI.tray.Add_DoubleClick({ Show-Window })
$UI.miResume.Add_Click({ Request-Operation 'resume' })
$UI.miPause.Add_Click({  Request-Operation 'pause' })
$UI.miExit.Add_Click({ $ST.exiting = $true; $form.Close() })

# ---------- timers ----------
$TM.auto = New-Object System.Windows.Forms.Timer
$TM.auto.Interval = [int]$ST.settings.autoRefreshSeconds * 1000
$TM.auto.Add_Tick({ Invoke-StatusRefresh -Silent })

$TM.poll = New-Object System.Windows.Forms.Timer
$TM.poll.Interval = 5000
$TM.poll.Add_Tick({ Invoke-Poll })

$TM.ui = New-Object System.Windows.Forms.Timer
$TM.ui.Interval = 1000
$TM.ui.Add_Tick({
    if ($ST.op) { $UI.lblOp.Text = ('{0} ... ({1})' -f $ST.opVerb, (Format-Elapsed ((Get-Date) - $ST.opStart))) }
    Update-AutoPause
})

# ---------- startup ----------
$form.Add_Shown({
    $ST.loading = $true; $UI.cmbAutoPause.SelectedIndex = 0; $ST.loading = $false
    Show-Card $null
    Write-Log ('Fabric Capacity Cockpit ' + $CockpitVersion + ' - settings: ' + (Get-CockpitSettingsPath))
    $cache = @($ST.settings.capacityCache)
    $lc = $ST.settings.lastCapacity
    $lastKey = if ($lc -and $lc.name) { ('{0}|{1}|{2}' -f $lc.subscriptionId, $lc.resourceGroup, $lc.name).ToLowerInvariant() } else { '' }
    if ($cache.Count -gt 0) {
        $found = Populate-Combo $cache $lastKey
        Write-Log ('Loaded {0} capacity(ies) from cache (updated {1}).' -f $cache.Count, $ST.settings.capacityCacheUpdated)
        if ($found) { $ST.selected = $UI.cmb.SelectedItem.Record; Show-Card $ST.selected; $UI.lblCost.Text = '(loading ...)'; Set-Updated 'cached' }
    } elseif ($lastKey) {
        # no cache yet, but a last capacity is known (e.g. migrated settings) - show it until the list arrives
        $rec = [pscustomobject]@{ name = $lc.name; id = ''; subscriptionId = $lc.subscriptionId; subscriptionName = ''; resourceGroup = $lc.resourceGroup; location = ''; sku = ''; state = ''; provisioningState = '' }
        Populate-Combo @($rec) $lastKey | Out-Null
        $ST.selected = $rec; Show-Card $rec; $UI.lblCost.Text = '(loading ...)'
    }
    Update-Controls
    $TM.ui.Start()
    $UI.chkAuto.Checked = $true

    if (-not $ST.azOk) {
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
            if ($ST.selected) { Invoke-StatusRefresh }
            Invoke-ListRefresh
        } else {
            $err = if ($r -and $r.Account) { $r.Account.Error } else { '' }
            if ($err) { Write-Log ('az account show: ' + $err) }
            Set-LoggedOut 'Not signed in'
        }
    }
})

$form.Add_FormClosing({ param($sender,$e)
    if (-not $ST.exiting -and $e.CloseReason -eq [System.Windows.Forms.CloseReason]::UserClosing) {
        $e.Cancel = $true
        Hide-Window
        return
    }
    foreach ($t in $TM.Values) { try { $t.Stop() } catch { } }
    try { Save-CockpitSettings $ST.settings } catch { }
    $UI.tray.Visible = $false
})

[System.Windows.Forms.Application]::Run($form)
$UI.tray.Dispose()
foreach ($t in $TM.Values) { try { $t.Dispose() } catch { } }
