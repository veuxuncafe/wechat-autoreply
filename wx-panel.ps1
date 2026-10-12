# wx-panel.ps1 - a small control panel for the WeChat auto-reply bot.
# Pure WinForms, no dependencies. Buttons and toggles only drive the same
# functions the command-line switches use, so it can be tested headlessly.
param(
  [switch]$Shot,
  [string]$ShotPath,
  [switch]$StartBot,
  [switch]$StopBot,
  [switch]$StatusLine,
  [switch]$SelfTest,
  [string]$Theme = '',
  [switch]$Logs,
  [switch]$Stats,
  [switch]$NoticeTest,
  [switch]$Contacts
)

# remembered so the window handler can reach it from the script scope
$script:WantLogs = [bool]$Logs
$script:WantStats = [bool]$Stats
$script:WantContacts = [bool]$Contacts

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$script:Root     = Split-Path -Parent $PSCommandPath
$script:Daemon   = Join-Path $script:Root 'wx-watch-daemon.ps1'
$script:StateDir = Join-Path $script:Root 'state'
$script:LogDir   = Join-Path $script:Root 'logs'
$script:ModeFile = Join-Path $script:StateDir 'mode.txt'
$script:WatchSt  = Join-Path $script:StateDir 'watch.json'
$script:PendFile = Join-Path $script:StateDir 'pending.json'
$script:StopFlag = Join-Path $script:StateDir 'stop.flag'
$script:ReplyLog = Join-Path $script:LogDir 'wx-reply-log.txt'
$script:IconPath = Join-Path $script:Root 'assets\icon.ico'

# ------------------------------------------------------------------ palette
# Two complete palettes. Custom painting always reads $script:C, so it follows a
# theme switch for free; flat colours set at creation time are translated by
# Apply-Theme using the pair table below (one walk over the control tree).
$script:Themes = @{
  light = @{
    Bg        = '#FFFFFF'
    Header    = '#FFFFFF'
    Card      = '#FBFCFD'
    CardLine  = '#ECEEF1'
    Line      = '#F1F3F6'
    Text      = '#0F172A'
    Sub       = '#64748B'
    Muted     = '#94A3B8'
    Accent    = '#07C160'
    AccentHi  = '#06AD56'
    AccentLow = '#E9F9F1'
    AccentOn  = '#05753C'
    Danger    = '#EF4444'
    DangerHi  = '#DC2626'
    DangerLow = '#FDECEC'
    DotOff    = '#CBD5E1'
    Track     = '#E2E5E9'
    Hover     = '#F3F5F8'
    Border    = '#E6E8EC'
    CloseHov  = '#FDECEC'
  }
  dark = @{
    Bg        = '#171A21'
    Header    = '#171A21'
    Card      = '#1F242E'
    CardLine  = '#2B323D'
    Line      = '#2A303A'
    Text      = '#E8EDF4'
    Sub       = '#9AA6B6'
    Muted     = '#6E7A8A'
    Accent    = '#07C160'
    AccentHi  = '#06AD56'
    AccentLow = '#123A28'
    AccentOn  = '#4ADE9A'
    Danger    = '#EF4444'
    DangerHi  = '#DC2626'
    DangerLow = '#3A1F22'
    DotOff    = '#4A5462'
    Track     = '#39414E'
    Hover     = '#2A303B'
    Border    = '#2E3540'
    CloseHov  = '#3A1F22'
  }
}
$script:ThemeName = 'light'
$script:C = $script:Themes.light
$script:ThemePairs = @(
  @{ L = '#FFFFFF'; D = '#171A21' }
  @{ L = '#FBFCFD'; D = '#1F242E' }
  @{ L = '#FAFBFC'; D = '#1F242E' }
  @{ L = '#ECEEF1'; D = '#2B323D' }
  @{ L = '#EFF1F4'; D = '#2A303A' }
  @{ L = '#F1F3F6'; D = '#2A303A' }
  @{ L = '#E6E8EC'; D = '#2E3540' }
  @{ L = '#F3F5F8'; D = '#2A303B' }
  @{ L = '#F1F2F4'; D = '#2A303B' }
  @{ L = '#E2E5E9'; D = '#39414E' }
  @{ L = '#CBD5E1'; D = '#4A5462' }
  @{ L = '#E9F9F1'; D = '#123A28' }
  @{ L = '#FDECEC'; D = '#3A1F22' }
  @{ L = '#0F172A'; D = '#E8EDF4' }
  @{ L = '#111827'; D = '#E8EDF4' }
  @{ L = '#64748B'; D = '#9AA6B6' }
  @{ L = '#94A3B8'; D = '#6E7A8A' }
  @{ L = '#475569'; D = '#C3CDDB' }
  @{ L = '#05753C'; D = '#4ADE9A' }
  @{ L = '#334155'; D = '#D6DEE9' }
  @{ L = '#E5484D'; D = '#FF8A8A' }
)
function Get-HexOf($col) {
  try { return ('#{0:X2}{1:X2}{2:X2}' -f [int]$col.R, [int]$col.G, [int]$col.B) } catch { return '' }
}
function Get-ThemeMap([string]$From, [string]$To) {
  $m = @{}
  foreach ($p in $script:ThemePairs) {
    if ($From -eq 'light' -and $To -eq 'dark') { $m[$p.L] = (CC $p.D) }
    elseif ($From -eq 'dark' -and $To -eq 'light') { $m[$p.D] = (CC $p.L) }
  }
  return $m
}
function Get-HexMap([string]$From, [string]$To) {
  $m = @{}
  foreach ($p in $script:ThemePairs) {
    if ($From -eq 'light' -and $To -eq 'dark') { $m[$p.L] = $p.D }
    elseif ($From -eq 'dark' -and $To -eq 'light') { $m[$p.D] = $p.L }
  }
  return $m
}
$script:ThemePropNames = @('BoxFill', 'BoxLine', 'BtnFill', 'BtnHover', 'BtnPress', 'BtnLine')
function Apply-Theme {
  if (-not $script:Form) { return }
  $from = 'dark'
  if ($script:ThemeName -eq 'dark') { $from = 'light' }
  $map = Get-ThemeMap $from $script:ThemeName
  $hexMap = Get-HexMap $from $script:ThemeName
  $work = New-Object System.Collections.Stack
  $work.Push($script:Form)
  if ($script:Lv.Form -and -not $script:Lv.Form.IsDisposed) { $work.Push($script:Lv.Form) }
  if ($script:Sv.Form -and -not $script:Sv.Form.IsDisposed) { $work.Push($script:Sv.Form) }
  if ($script:Cv.Form -and -not $script:Cv.Form.IsDisposed) { $work.Push($script:Cv.Form) }
  $n = 0
  while ($work.Count -gt 0) {
    $c = $work.Pop()
    try {
      $bk = Get-HexOf $c.BackColor
      if ($bk -and $map.ContainsKey($bk)) { $c.BackColor = $map[$bk]; $n++ }
    } catch { }
    try {
      # white text belongs to the coloured primary button and has to stay white
      $fk = Get-HexOf $c.ForeColor
      if ($fk -and $fk -ne '#FFFFFF' -and $map.ContainsKey($fk)) { $c.ForeColor = $map[$fk]; $n++ }
    } catch { }
    # painted surfaces keep their colours as strings, so translate those too
    foreach ($pn in $script:ThemePropNames) {
      try {
        $pv = $c.$pn
        if (($pv -is [string]) -and $pv) {
          $key = $pv.ToUpper()
          if ($hexMap.ContainsKey($key)) { $c.$pn = $hexMap[$key]; $n++ }
        }
      } catch { }
    }
    # a label with its own background paints a rectangle that no longer matches
    # the card behind it, so let the parent draw through instead
    if ($c -is [System.Windows.Forms.Label]) { try { $c.BackColor = [System.Drawing.Color]::Transparent } catch { } }
    try { $c.Invalidate() } catch { }
    try { foreach ($ch in $c.Controls) { $work.Push($ch) } } catch { }
  }
  Add-PanelLog ('theme: {0} ({1} colours translated)' -f $script:ThemeName, $n)
}
function Set-Theme([string]$Name) {
  if ($Name -ne 'dark') { $Name = 'light' }
  $script:ThemeName = $Name
  $script:C = $script:Themes[$Name]
  Apply-Theme
  try {
    [System.IO.File]::WriteAllText((Join-Path $script:StateDir 'theme.txt'), $Name, (New-Object System.Text.ASCIIEncoding))
  } catch { }
}

function CC([string]$hex) { return [System.Drawing.ColorTranslator]::FromHtml($hex) }

function New-UiFont([single]$size, [System.Drawing.FontStyle]$style) {
  if (-not $script:DpiScale) { $script:DpiScale = 1.0 }
  try { return (New-Object System.Drawing.Font('Microsoft YaHei UI', $size, $style)) }
  catch { return (New-Object System.Drawing.Font('Segoe UI', $size, $style)) }
}

function New-RoundPath([single]$x, [single]$y, [single]$w, [single]$h, [single]$r) {
  $p = New-Object System.Drawing.Drawing2D.GraphicsPath
  $d = $r * 2
  if ($d -gt $w) { $d = $w }
  if ($d -gt $h) { $d = $h }
  $p.AddArc($x, $y, $d, $d, 180, 90)
  $p.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
  $p.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90)
  $p.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
  $p.CloseFigure()
  return $p
}

function New-RoundRegion([int]$w, [int]$h, [single]$r) {
  $p = New-RoundPath 0 0 $w $h $r
  $reg = New-Object System.Drawing.Region($p)
  $p.Dispose()
  return $reg
}

# keeps the custom painting flicker free (the property is protected)
function Set-DoubleBuffer([System.Windows.Forms.Control]$C) {
  try {
    $pr = $C.GetType().GetProperty('DoubleBuffered', [System.Reflection.BindingFlags]'Instance,NonPublic')
    if ($pr) { $pr.SetValue($C, $true, $null) }
  } catch { }
}

# optional: only used for the native WM_SETICON nudge, never for dragging
try {
  Add-Type -Namespace WxPanel -Name Native -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool ReleaseCapture();
[DllImport("user32.dll")] public static extern System.IntPtr SendMessage(System.IntPtr hWnd, int msg, System.IntPtr wParam, System.IntPtr lParam);
[DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(System.IntPtr hWnd, int attr, ref int value, int size);
'@
} catch { }

# extra user32 entry points: native dragging, taskbar minimise, focus stealing
try {
  Add-Type -Namespace WxPanel -Name Win -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool ReleaseCapture();
[DllImport("user32.dll")] public static extern System.IntPtr SendMessage(System.IntPtr hWnd, int msg, System.IntPtr wParam, System.IntPtr lParam);
[DllImport("user32.dll")] public static extern int GetWindowLong(System.IntPtr hWnd, int index);
[DllImport("user32.dll")] public static extern int SetWindowLong(System.IntPtr hWnd, int index, int value);
[DllImport("user32.dll")] public static extern bool SetWindowPos(System.IntPtr hWnd, System.IntPtr after, int x, int y, int cx, int cy, uint flags);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr hWnd);
'@
} catch { }

# ------------------------------------------------------------------ bot logic
function Set-Mode {
  param([ValidateSet('live', 'dryrun')][string]$Mode)
  if (-not (Test-Path -LiteralPath $script:StateDir)) { New-Item -ItemType Directory -Path $script:StateDir -Force | Out-Null }
  [System.IO.File]::WriteAllText($script:ModeFile, $Mode, (New-Object System.Text.ASCIIEncoding))
}

function Get-Mode {
  try {
    $m = (Get-Content -LiteralPath $script:ModeFile -Raw -ErrorAction Stop).Trim()
    if ($m -eq 'live' -or $m -eq 'dryrun') { return $m }
  } catch { }
  return 'live'
}

function Test-BotRunning {
  # the daemon holds this mutex for as long as the bot is alive; this is the
  # only liveness signal that does not depend on being able to enumerate
  # processes (which is filtered in some environments)
  if ((Get-AutoProcs).Count -gt 0) { return $true }
  try {
    $m = [System.Threading.Mutex]::OpenExisting('Local\DSH-WeChat-AutoReply')
    $m.Dispose()
    return $true
  } catch { }
  return $false
}

function Get-AutoProcs {
  $me = $PID
  try {
    return @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction Stop |
      Where-Object {
        $_.ProcessId -ne $me -and $_.CommandLine -and
        ($_.CommandLine -like '*wx-watch-daemon.ps1*' -or $_.CommandLine -like '*wx-watch.ps1*')
      })
  } catch { return @() }
}

function Start-Auto {
  if (Test-BotRunning) { return $false }
  if (Test-Path -LiteralPath $script:StopFlag) { Remove-Item -LiteralPath $script:StopFlag -Force -ErrorAction SilentlyContinue }
  $procArgs = @('-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', $script:Daemon, '-IntervalSec', '5')
  Start-Process -FilePath 'powershell.exe' -ArgumentList $procArgs -WindowStyle Hidden | Out-Null
  return $true
}

function Stop-Auto {
  $p = Get-AutoProcs
  if (-not (Test-Path -LiteralPath $script:StateDir)) { New-Item -ItemType Directory -Force -Path $script:StateDir | Out-Null }
  # the flag is the reliable stop channel: the running bot checks it between rounds
  [System.IO.File]::WriteAllText($script:StopFlag, (Get-Date).ToString('s'), (New-Object System.Text.ASCIIEncoding))
  foreach ($x in $p) { try { Stop-Process -Id $x.ProcessId -Force -ErrorAction Stop } catch { } }
  $waited = 0
  while ($waited -lt 10000) {
    Start-Sleep -Milliseconds 500
    $waited += 500
    if (-not (Test-BotRunning)) { break }
  }
  $still = Test-BotRunning
  if ($still) { return ('stop requested ({0} process(es) killed) but the bot is still alive' -f $p.Count) }
  return ('stopped ({0} process(es) killed)' -f $p.Count)
}

function Get-ReplyStats {
  # re-scanning the whole reply log on every refresh (it grows all day) was the
  # most expensive thing the panel did; only re-read it when the file changes
  try {
    $fi = Get-Item -LiteralPath $script:ReplyLog -ErrorAction Stop
    $stamp = '{0}|{1}' -f $fi.LastWriteTimeUtc.Ticks, $fi.Length
  } catch {
    return @{ Today = 0; Last = '' }
  }
  if ($script:ReplyStatsStamp -eq $stamp) {
    return @{ Today = $script:ReplyStatsToday; Last = $script:ReplyStatsLast }
  }
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $rl = @()
  try { $rl = @(Get-Content -LiteralPath $script:ReplyLog -Encoding UTF8 -ErrorAction Stop) } catch { }
  $today = (Get-Date).ToString('yyyy-MM-dd')
  $sent = @($rl | Where-Object { $_ -match '\[SENT\]' })
  $sentToday = @($sent | Where-Object { $_ -like ($today + '*') }).Count
  $last = ''
  $hit = $sent | Select-Object -Last 1
  if ($hit) {
    $last = $hit.Trim()
    if ($last -match '^\d{4}-\d{2}-\d{2} (\d{2}:\d{2}:\d{2}) \[SENT\] (.*)$') {
      $last = $Matches[1] + '   ' + $Matches[2]
    }
  }
  $sw.Stop()
  if ($sw.ElapsedMilliseconds -gt 80) { Add-PanelLog ('reply log scan: {0} ms, {1} lines' -f $sw.ElapsedMilliseconds, $rl.Count) }
  $script:ReplyStatsStamp = $stamp
  $script:ReplyStatsToday = $sentToday
  $script:ReplyStatsLast = $last
  return @{ Today = $sentToday; Last = $last }
}

# ------------------------------------------------------------------ contacts
# The panel side of state\contacts.json. The reader has to exist before the window
# is built (the header prints the active contact), the editor is defined later
# with the other viewers.
function Get-ActiveContactName {
  $p = Join-Path $script:Root 'state\contacts.json'
  if (Test-Path -LiteralPath $p) {
    try {
      $d = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json
      if ($d -and $d.active) { return [string]$d.active }
      if ($d -and $d.contacts) { return [string](@($d.contacts)[0].name) }
    } catch { }
  }
  return '未设置联系人'
}
function Get-ActionText {
  param([string]$Action)
  # A queued reply is the one thing the user must be told about: it means a real message was not
  # delivered. Report the queue instead of the (now stale) action of the last round.
  $q = 0
  try {
    if (Test-Path -LiteralPath $script:PendFile) {
      $raw = (Get-Content -LiteralPath $script:PendFile -Raw -Encoding UTF8 -ErrorAction Stop)
      $obj = $raw | ConvertFrom-Json
      if ($obj) { $q = @($obj).Count }
    }
  } catch { }
  if ($q -gt 0) {
    $one = $null
    try { $one = @(($raw | ConvertFrom-Json))[0].draft } catch { }
    if ($one) { return ('有 ' + $q + ' 条没发出去，正在排队重试：' + $one) }
    return ('有 ' + $q + ' 条没发出去，正在排队重试')
  }
  switch ($Action) {
    'mine'            { return '最新一条是我发的，无需回复' }
    'them'            { return '看到他的新消息' }
    'drafted'         { return '已生成回复草稿' }
    'sent'            { return '已回复' }
    'proactive'       { return '主动找他搭话' }
    'canned'          { return '超长文，回了固定台词' }
    'other-chat'      { return ('当前会话不是 ' + (Get-ActiveContactName)) }
    'recorder-failed' { return '发送结果未知，已入队重试' }
    'model-failed'    { return '模型超时，这条没回' }
    'ocr-failed'      { return '读不到微信画面' }
    'dryrun'          { return '草稿模式，没有真发' }
    default           { if ($Action) { return $Action } else { return '—' } }
  }
}

function Get-AutoInfo {
  $procs = Get-AutoProcs
  $running = Test-BotRunning
  $pids = (($procs | ForEach-Object { $_.ProcessId }) -join ', ')
  $mode = Get-Mode
  $st = $null
  try {
    if (Test-Path -LiteralPath $script:WatchSt) {
      $st = (Get-Content -LiteralPath $script:WatchSt -Raw -Encoding UTF8 -ErrorAction Stop) | ConvertFrom-Json
    }
  } catch { }
  $pend = 0
  try {
    if (Test-Path -LiteralPath $script:PendFile) {
      $raw = (Get-Content -LiteralPath $script:PendFile -Raw -Encoding UTF8 -ErrorAction Stop)
      $obj = $raw | ConvertFrom-Json
      if ($obj) { $pend = @($obj).Count }
    }
  } catch { }
  $rounds = 0; $pc = 0; $act = ''
  if ($st) {
    try { $rounds = [int]$st.rounds } catch { }
    # pcCount is a per-day counter; report it only while the state file says the day is today.
    try { if ([string]$st.pcDate -eq (Get-Date).ToString('yyyy-MM-dd')) { $pc = [int]$st.pcCount } } catch { }
    try { $act = [string]$st.lastAction } catch { }
  }
  $rs = Get-ReplyStats
  return [pscustomobject]@{
    Running    = $running
    Pids       = $pids
    Mode       = $mode
    Rounds     = $rounds
    Today      = $rs.Today
    Proactive  = $pc
    Queue      = $pend
    Last       = $rs.Last
    Action     = $act
    ActionText = (Get-ActionText $act)
  }
}

function Get-StatusText {
  $i = Get-AutoInfo
  $t = @()
  $t += ('模式：    ' + $i.Mode + $(if ($i.Mode -eq 'live') { '   （真实发送）' } else { '   （只造草稿，不发送）' }))
  $t += ('进程：    ' + $(if ($i.Running) { '运行中   pid ' + $i.Pids } else { '未运行' }))
  $t += ('轮次：    ' + $i.Rounds + '        今日发出：' + $i.Today + ' 条（其中主动 ' + $i.Proactive + '）')
  $t += ('最后动作：' + $i.ActionText + '        待发队列：' + $i.Queue)
  $t += ('最后发出：' + $(if ($i.Last) { $i.Last } else { '—' }))
  return ($t -join [Environment]::NewLine)
}

# --------------------------------------------------- control-plane callbacks
function Invoke-PanelButton {
  param([string]$Name)
  switch ($Name) {
    'primary' {
      if (Test-BotRunning) { [void](Stop-Auto) } else { [void](Start-Auto) }
      Start-Sleep -Milliseconds 400
      $script:ForceStyle = $true
      Update-Panel
    }
    'logs'    { Show-LogViewer }
    'stats'   { Show-StatsViewer }
    'contacts'      { Show-ContactsViewer }
    'contacts-save'   { Save-ContactForm }
    'contacts-new'    { Add-Contact }
    'contacts-del'    { Delete-Contact }
    'contacts-active' { Make-ContactActive }
    'contacts-close'  { if ($script:Cv.Form -and -not $script:Cv.Form.IsDisposed) { $script:Cv.Form.Close() } }
    'stats-refresh' { $script:Sv.Stamp = ''; $script:Sv.Data = $null; Update-StatsView }
    'stats-logs'    { Show-LogViewer }
    'stats-close'   { if ($script:Sv.Form -and -not $script:Sv.Form.IsDisposed) { $script:Sv.Form.Close() } }
    'folder'  { Start-Process -FilePath 'explorer.exe' -ArgumentList $script:Root | Out-Null }
    'refresh' { $script:ForceStyle = $true; Update-Panel }
    'min'     { $script:Form.WindowState = 'Minimized' }
    'close'   {
      $script:DragOrigin = $null
      if ($script:timer) { try { $script:timer.Stop() } catch { } }
      try { $script:Form.Close() } catch { Add-PanelLog ('close failed: {0}' -f $_.Exception.Message) }
    }
  }
}

function Invoke-PanelToggle {
  param([string]$Name, [bool]$Checked)
  switch ($Name) {
    'tgDry' {
      if ($Checked) { Set-Mode 'dryrun' } else { Set-Mode 'live' }
      # the watcher reads mode.txt once at start, so a running one has to be restarted
      if (Test-BotRunning) {
        [void](Stop-Auto)
        Start-Sleep -Milliseconds 400
        [void](Start-Auto)
      }
    }
    'tgTop' { $script:Form.TopMost = $Checked }
    'tgAuto' { Set-AutoStart $Checked }
    'tgTheme' { Set-Theme $(if ($Checked) { 'dark' } else { 'light' }) }
  }
  $script:ForceStyle = $true
  Update-Panel
}

# ------------------------------------------------------------------ window
$script:Form = New-Object System.Windows.Forms.Form
$script:Form.Text = '微信自动回复控制台'
$script:Form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
$script:Form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
# A per-monitor DPI aware host renders in real pixels, so the layout below is
# written in 96-dpi design units and DPX()/DPF() translate them.
$script:DpiScale = 1.0
try {
  $dg = [System.Drawing.Graphics]::FromHwnd($script:Form.Handle)
  $script:DpiScale = [math]::Max(1.0, [math]::Round(($dg.DpiX / 96.0), 2))
  $dg.Dispose()
} catch { $script:DpiScale = 1.0 }
function DPX([double]$v) { return [int][math]::Round($v * $script:DpiScale) }
function DPF([double]$v) { return [single]([math]::Round($v * $script:DpiScale, 2)) }
$script:Form.ClientSize = New-Object System.Drawing.Size((DPX 440), (DPX 616))
$script:Form.BackColor = CC $script:C.Bg
$script:Form.ShowInTaskbar = $true
$script:Form.KeyPreview = $true

$script:UseDwmCorners = ($env:DSH_PANEL_CORNERS -ne 'region')
$script:CornerRadius = 8
$script:Form.Region = $null

# The window is owned by wx-panel.exe (which claims the app id); running the
# script standalone still claims it here. The icon push is a nice-to-have.
function Add-PanelLog([string]$Msg) {
  try {
    $logDir = Join-Path $script:Root 'logs'
    if (-not (Test-Path -LiteralPath $logDir)) { [void](New-Item -ItemType Directory -Path $logDir -Force) }
    Add-Content -LiteralPath (Join-Path $logDir 'panel.log') -Value ('{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Msg) -Encoding UTF8
  } catch { }
}

# one control panel at a time: a second launch brings the first one forward
$script:PanelMutex = $null
if (-not ($StartBot -or $StopBot -or $StatusLine -or $SelfTest -or $Shot -or $NoticeTest)) {
  try {
    $script:PanelMutex = New-Object System.Threading.Mutex($false, 'Local\DSH-WeChatAutoReply.PanelUI')
    if (-not $script:PanelMutex.WaitOne(0)) {
      Add-PanelLog 'another panel is already open - activating it instead'
      try {
        foreach ($pr in @(Get-Process -Name 'wx-panel' -ErrorAction SilentlyContinue)) {
          if ($pr.MainWindowHandle -ne [IntPtr]::Zero) { [void][WxPanel.Win]::SetForegroundWindow($pr.MainWindowHandle) }
        }
      } catch { }
      exit 0
    }
  } catch { $script:PanelMutex = $null }
}

$script:PanelAppId = 'DSH.WeChatAutoReply.Panel'
try {
  Add-Type -Namespace WxPanel -Name Shell -MemberDefinition '[DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)] public static extern void SetCurrentProcessExplicitAppUserModelID(string appId);' -ErrorAction Stop
  [WxPanel.Shell]::SetCurrentProcessExplicitAppUserModelID($script:PanelAppId)
  Add-PanelLog ('appid: {0}' -f $script:PanelAppId)
} catch { Add-PanelLog ('appid: left to the host ({0})' -f $_.Exception.Message) }

$panelIcon = $null
foreach ($cand in @($script:IconPath, (Join-Path $script:Root 'wx-panel.exe'))) {
  if (-not (Test-Path -LiteralPath $cand)) { Add-PanelLog ('icon candidate missing: {0}' -f $cand); continue }
  try {
    if ([System.IO.Path]::GetExtension($cand) -eq '.ico') { $panelIcon = New-Object System.Drawing.Icon($cand, 32, 32) }
    else { $panelIcon = [System.Drawing.Icon]::ExtractAssociatedIcon($cand) }
  } catch { Add-PanelLog ('icon load failed for {0}: {1}' -f $cand, $_.Exception.Message) }
  if ($panelIcon) { Add-PanelLog ('icon: {0}' -f $cand); break }
}
if ($panelIcon) {
  $script:Form.Icon = $panelIcon
  try {
    [void][WxPanel.Native]::SendMessage($script:Form.Handle, 0x0080, [System.IntPtr]1, $panelIcon.Handle)
    [void][WxPanel.Native]::SendMessage($script:Form.Handle, 0x0080, [System.IntPtr]0, $panelIcon.Handle)
    Add-PanelLog 'seticon: ok'
  } catch { Add-PanelLog ('seticon: relying on Form.Icon ({0})' -f $_.Exception.Message) }
} else {
  Add-PanelLog 'icon: none of the candidates loaded'
}

# corners are applied once the window is shown: the DPI auto-scaling above
# changes the client size, so a fallback region has to be built afterwards
$script:Form.Add_Shown({
  Add-PanelLog ('dpi scale: {0}' -f $script:DpiScale)
  Restore-PanelPos
  if ($script:WantLogs) { Show-LogViewer }
  if ($script:WantStats) { Show-StatsViewer }
if ($script:WantContacts) { Show-ContactsViewer }
  # a borderless window is created without a system menu, and without
  # WS_MINIMIZEBOX the taskbar button cannot minimise or restore it
  try {
    $style = [WxPanel.Win]::GetWindowLong($script:Form.Handle, -16)
    $style = $style -bor 0x00020000 -bor 0x00080000
    [void][WxPanel.Win]::SetWindowLong($script:Form.Handle, -16, $style)
    [void][WxPanel.Win]::SetWindowPos($script:Form.Handle, [IntPtr]::Zero, 0, 0, 0, 0, 0x27)
    Add-PanelLog ('window style: 0x{0:X} - taskbar minimise enabled' -f [WxPanel.Win]::GetWindowLong($script:Form.Handle, -16))
  } catch { Add-PanelLog ('window style: n/a ({0})' -f $_.Exception.Message) }
  Set-DoubleBuffer $script:Form
  # WS_EX_COMPOSITED: one composed surface for the window and all of its child
  # controls, so dragging does not repaint every child on every frame
  try {
    $ex = [WxPanel.Win]::GetWindowLong($script:Form.Handle, -20)
    [void][WxPanel.Win]::SetWindowLong($script:Form.Handle, -20, ($ex -bor 0x02000000))
    [void][WxPanel.Win]::SetWindowPos($script:Form.Handle, [IntPtr]::Zero, 0, 0, 0, 0, 0x27)
    Add-PanelLog ('compose: exstyle 0x{0:X} - child controls composited' -f [WxPanel.Win]::GetWindowLong($script:Form.Handle, -20))
  } catch { Add-PanelLog ('compose: n/a ({0})' -f $_.Exception.Message) }
  if ($script:UseDwmCorners) {
    $dwmHr = -1
    try {
      $pref = 2
      $dwmHr = [WxPanel.Native]::DwmSetWindowAttribute($script:Form.Handle, 33, [ref]$pref, 4)
      Add-PanelLog ('dwm corners: hr={0}' -f $dwmHr)
    } catch {
      $dwmHr = -1
      Add-PanelLog ('dwm corners: n/a ({0})' -f $_.Exception.Message)
    }
    if ($dwmHr -ne 0) {
      $script:CornerRadius = 16
      $cs = $script:Form.ClientSize
      $script:Form.Region = New-RoundRegion $cs.Width $cs.Height ([int](16 * $script:DpiScale))
      Add-PanelLog 'dwm corners: fell back to the region'
    }
  }
})

$script:Form.Add_Paint({
  param($s, $e)
  $e.Graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $pth = New-RoundPath 0.5 0.5 ($s.Width - 1) ($s.Height - 1) ($script:CornerRadius * $script:DpiScale)
  $pen = New-Object System.Drawing.Pen((CC '#E8EAEE'), (1 * $script:DpiScale))
  $e.Graphics.DrawPath($pen, $pth)
  $pen.Dispose(); $pth.Dispose()
})

# ------------------------------------------------------------------ dragging
# Follow-the-cursor move. Handing the move to Windows (ReleaseCapture +
# WM_NCLBUTTONDOWN/HTCAPTION) turned every press into a modal move loop, which
# swallowed the chrome-button clicks, so we move the window ourselves again - but
# with a tight handler: plain ints, no per-event object allocation, no repaint
# while nothing moved, and the refresh timer parked until the drag ends. If a
# mouse-up goes missing the left-button check below ends the drag by itself.
Add-PanelLog 'drag: follow-the-cursor (light)'
$script:DragOrigin = $null
$script:DragMouseX = 0
$script:DragMouseY = 0
$script:DragWinX = 0
$script:DragWinY = 0
$dragDown = {
  param($s, $e)
  if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
  $p = [System.Windows.Forms.Cursor]::Position
  $script:DragMouseX = $p.X
  $script:DragMouseY = $p.Y
  $script:DragWinX = $script:Form.Left
  $script:DragWinY = $script:Form.Top
  $script:DragOrigin = $true
  if ($script:timer) { try { $script:timer.Stop() } catch { } }
  try { $s.Capture = $true } catch { }
}
$dragMove = {
  param($s, $e)
  if (-not $script:DragOrigin) { return }
  if (([System.Windows.Forms.Control]::MouseButtons -band [System.Windows.Forms.MouseButtons]::Left) -eq 0) {
    $script:DragOrigin = $null
    try { $s.Capture = $false } catch { }
    if ($script:timer) { try { $script:timer.Start() } catch { } }
    Save-PanelPos
    return
  }
  $p = [System.Windows.Forms.Cursor]::Position
  $nx = $script:DragWinX + ($p.X - $script:DragMouseX)
  $ny = $script:DragWinY + ($p.Y - $script:DragMouseY)
  if ($nx -ne $script:Form.Left -or $ny -ne $script:Form.Top) {
    $script:Form.Location = [System.Drawing.Point]::new($nx, $ny)
  }
}
$dragUp = {
  param($s, $e)
  $script:DragOrigin = $null
  try { $s.Capture = $false } catch { }
  if ($script:timer) { try { $script:timer.Start() } catch { } }
  Save-PanelPos
}
function Enable-WindowDrag {
  param([System.Windows.Forms.Control]$C)
  $skip = ($C -is [System.Windows.Forms.Button]) -or ($C.NoDrag -eq $true)
  if (-not $skip) {
    $C.Add_MouseDown($dragDown)
    $C.Add_MouseMove($dragMove)
    $C.Add_MouseUp($dragUp)
  }
  foreach ($child in $C.Controls) { Enable-WindowDrag $child }
}

# ------------------------------------------------------------------ widgets
function New-RoundBox {
  param([int]$X, [int]$Y, [int]$W, [int]$H, [string]$Bg, [single]$Radius, [string]$Line, [string]$BgParent)
  if (-not $BgParent) { $BgParent = $script:C.Bg }
  $p = New-Object System.Windows.Forms.Panel
  $p.Location = New-Object System.Drawing.Point((DPX $X), (DPX $Y))
  $p.Size = New-Object System.Drawing.Size((DPX $W), (DPX $H))
  $p.BackColor = CC $BgParent
  Set-DoubleBuffer $p
  $p | Add-Member -MemberType NoteProperty -Name BoxRadius -Value $Radius -Force
  $p | Add-Member -MemberType NoteProperty -Name BoxLine -Value $Line -Force
  $p | Add-Member -MemberType NoteProperty -Name BoxFill -Value $Bg -Force
  $p.Add_Paint({
    param($s, $e)
    $g = $e.Graphics
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $pth = New-RoundPath 0.5 0.5 ($s.Width - 1) ($s.Height - 1) ($s.BoxRadius * $script:DpiScale)
    $br = New-Object System.Drawing.SolidBrush((CC $s.BoxFill))
    $g.FillPath($br, $pth)
    $br.Dispose()
    if ($s.BoxLine) {
      $pen = New-Object System.Drawing.Pen((CC $s.BoxLine), (1 * $script:DpiScale))
      $g.DrawPath($pen, $pth)
      $pen.Dispose()
    }
    $pth.Dispose()
  })
  return $p
}

function New-UiLabel {
  param([System.Windows.Forms.Control]$Parent, [string]$Text, [int]$X, [int]$Y, [int]$W, [int]$H,
        [single]$Size, [bool]$Bold, [string]$Color, [string]$Bg, [string]$Align)
  $l = New-Object System.Windows.Forms.Label
  $l.Text = $Text
  $style = [System.Drawing.FontStyle]::Regular
  if ($Bold) { $style = [System.Drawing.FontStyle]::Bold }
  $l.Font = New-UiFont $Size $style
  $l.ForeColor = CC $Color
  $l.BackColor = CC $Bg
  $l.AutoSize = $false
  $l.TextAlign = [System.Drawing.ContentAlignment]::$Align
  $l.Location = New-Object System.Drawing.Point((DPX $X), (DPX $Y))
  $l.Size = New-Object System.Drawing.Size((DPX $W), (DPX $H))
  if ($Parent) { $Parent.Controls.Add($l) }
  return $l
}

function New-FlatButton {
  param(
    [string]$Text, [int]$X, [int]$Y, [int]$W, [int]$H, [string]$Name,
    [string]$Bg, [string]$Fg, [string]$HoverBg, [string]$PressBg, [string]$Line,
    [single]$Radius, [single]$Size, [bool]$Bold, [string]$BgParent
  )
  if (-not $BgParent) { $BgParent = $script:C.Bg }
  $b = New-Object System.Windows.Forms.Button
  $b.Text = ''
  $b.Name = $Name
  $b.Location = New-Object System.Drawing.Point((DPX $X), (DPX $Y))
  $b.Size = New-Object System.Drawing.Size((DPX $W), (DPX $H))
  $b.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
  $b.FlatAppearance.BorderSize = 0
  $b.FlatAppearance.MouseOverBackColor = (CC $BgParent)
  $b.FlatAppearance.MouseDownBackColor = (CC $BgParent)
  $b.BackColor = CC $BgParent
  $b.ForeColor = CC $Fg
  $style = [System.Drawing.FontStyle]::Regular
  if ($Bold) { $style = [System.Drawing.FontStyle]::Bold }
  $b.Font = New-UiFont $Size $style
  $b.Cursor = [System.Windows.Forms.Cursors]::Hand
  $b.UseVisualStyleBackColor = $false
  $b.TabStop = $false
  Set-DoubleBuffer $b
  $b | Add-Member -MemberType NoteProperty -Name BtnText -Value $Text -Force
  $b | Add-Member -MemberType NoteProperty -Name BtnRadius -Value $Radius -Force
  $b | Add-Member -MemberType NoteProperty -Name BtnLine -Value $Line -Force
  $b | Add-Member -MemberType NoteProperty -Name BtnFill -Value $Bg -Force
  $b | Add-Member -MemberType NoteProperty -Name BtnHover -Value $HoverBg -Force
  $b | Add-Member -MemberType NoteProperty -Name BtnPress -Value $PressBg -Force
  $b | Add-Member -MemberType NoteProperty -Name BtnState -Value 'normal' -Force
  $b.Add_Click({ param($s, $e) Invoke-PanelButton -Name $s.Name })
  $b.Add_Paint({
    param($s, $e)
    $g = $e.Graphics
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $fill = $s.BtnFill
    if ($s.BtnState -eq 'hover') { $fill = $s.BtnHover }
    if ($s.BtnState -eq 'press') { $fill = $s.BtnPress }
    $pth = New-RoundPath 0.5 0.5 ($s.Width - 1) ($s.Height - 1) ($s.BtnRadius * $script:DpiScale)
    $br = New-Object System.Drawing.SolidBrush((CC $fill))
    $g.FillPath($br, $pth)
    $br.Dispose()
    if ($s.BtnLine) {
      $pen = New-Object System.Drawing.Pen((CC $s.BtnLine), (1 * $script:DpiScale))
      $g.DrawPath($pen, $pth)
      $pen.Dispose()
    }
    $pth.Dispose()
    $rect = New-Object System.Drawing.Rectangle(0, 0, $s.Width, $s.Height)
    $flags = [System.Windows.Forms.TextFormatFlags]::HorizontalCenter -bor [System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor [System.Windows.Forms.TextFormatFlags]::NoPadding
    [System.Windows.Forms.TextRenderer]::DrawText($g, $s.BtnText, $s.Font, $rect, $s.ForeColor, $flags)
  })
  $b.Add_MouseEnter({ param($s, $e) if ($s.BtnState -eq 'normal') { $s.BtnState = 'hover'; $s.Invalidate() } })
  $b.Add_MouseLeave({ param($s, $e) if ($s.BtnState -ne 'normal') { $s.BtnState = 'normal'; $s.Invalidate() } })
  $b.Add_MouseDown({ param($s, $e) if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { $s.BtnState = 'press'; $s.Invalidate() } })
  $b.Add_MouseUp({ param($s, $e) $s.BtnState = 'hover'; $s.Invalidate() })
  return $b
}

function New-Toggle {
  param([int]$X, [int]$Y, [string]$Name)
  $t = New-Object System.Windows.Forms.Panel
  $t.Name = $Name
  $t.Location = New-Object System.Drawing.Point((DPX $X), (DPX $Y))
  $t.Size = New-Object System.Drawing.Size((DPX 40), (DPX 23))
  $t.BackColor = CC $script:C.Bg
  $t.Cursor = [System.Windows.Forms.Cursors]::Hand
  $t | Add-Member -MemberType NoteProperty -Name Checked -Value $false -Force
  $t | Add-Member -MemberType NoteProperty -Name Knob -Value ([single](2.5 * $script:DpiScale)) -Force
  $t | Add-Member -MemberType NoteProperty -Name NoDrag -Value $true -Force
  $t.Add_Paint({
    param($s, $e)
    $g = $e.Graphics
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear($s.BackColor)
    $track = CC $script:C.Track
    if ($s.Checked) { $track = CC '#07C160' }
    $path = New-RoundPath 0.5 0.5 (39 * $script:DpiScale) (22 * $script:DpiScale) (11 * $script:DpiScale)
    $br = New-Object System.Drawing.SolidBrush($track)
    $g.FillPath($br, $path)
    $knob = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
    $g.FillEllipse($knob, $s.Knob, [single](2.5 * $script:DpiScale), [single](18 * $script:DpiScale), [single](18 * $script:DpiScale))
    $br.Dispose(); $knob.Dispose(); $path.Dispose()
  })
  $t.Add_Click({
    param($s, $e)
    $s.Checked = -not $s.Checked
    $s.Invalidate()
    if ($script:AnimTimer) { $script:AnimTimer.Start() }
    Invoke-PanelToggle -Name $s.Name -Checked $s.Checked
  })
  return $t
}

function New-ChromeButton {
  param([string]$Glyph, [int]$X, [int]$Y, [bool]$IsClose)
  $l = New-Object System.Windows.Forms.Label
  $l.Text = ''
  $l.Font = New-UiFont 9.5 ([System.Drawing.FontStyle]::Regular)
  $l.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
  $l.Size = New-Object System.Drawing.Size((DPX 28), (DPX 28))
  $l.Location = New-Object System.Drawing.Point((DPX $X), (DPX $Y))
  $l.ForeColor = CC $script:C.Sub
  $l.BackColor = CC $script:C.Header
  $l.Cursor = [System.Windows.Forms.Cursors]::Hand
  Set-DoubleBuffer $l
  $l | Add-Member -MemberType NoteProperty -Name Glyph -Value $Glyph -Force
  $l | Add-Member -MemberType NoteProperty -Name IsClose -Value $IsClose -Force
  $l | Add-Member -MemberType NoteProperty -Name Hov -Value $false -Force
  $l.Add_Paint({
    param($s, $e)
    $g = $e.Graphics
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $fgc = $script:C.Sub
    if ($s.Hov) {
      $fill = $script:C.Hover
      $fgc = $script:C.Text
      if ($s.IsClose) { $fill = $script:C.CloseHov; $fgc = $script:C.Danger }
      $pth = New-RoundPath 0.5 0.5 ($s.Width - 1) ($s.Height - 1) (7 * $script:DpiScale)
      $br = New-Object System.Drawing.SolidBrush((CC $fill))
      $g.FillPath($br, $pth)
      $br.Dispose(); $pth.Dispose()
    }
    $rect = New-Object System.Drawing.Rectangle(0, 0, $s.Width, $s.Height)
    $flags = [System.Windows.Forms.TextFormatFlags]::HorizontalCenter -bor [System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor [System.Windows.Forms.TextFormatFlags]::NoPadding
    [System.Windows.Forms.TextRenderer]::DrawText($g, $s.Glyph, $s.Font, $rect, (CC $fgc), $flags)
  })
  $l | Add-Member -MemberType NoteProperty -Name NoDrag -Value $true -Force
  $l.Add_MouseEnter({ param($s, $e) $s.Hov = $true; $s.Invalidate() })
  $l.Add_MouseLeave({ param($s, $e) $s.Hov = $false; $s.Invalidate() })
  $l.Add_Click({ param($s, $e) Invoke-PanelButton -Name $(if ($s.IsClose) { 'close' } else { 'min' }) })
  return $l
}

# ------------------------------------------------------------------ layout
$W = 440
$M = 24          # side margin
$CW = $W - ($M * 2)

# header
$lblTitle = New-UiLabel -Parent $script:Form -Text '微信自动回复' -X ($M + 40) -Y 17 -W 220 -H 24 `
  -Size 12.5 -Bold $true -Color $script:C.Text -Bg $script:C.Header -Align 'MiddleLeft'
$lblSub = New-UiLabel -Parent $script:Form -Text ((Get-ActiveContactName) + ' · 会话自动应答') -X ($M + 41) -Y 40 -W 240 -H 18 `
  -Size 8.5 -Bold $false -Color $script:C.Muted -Bg $script:C.Header -Align 'MiddleLeft'

$picIcon = New-Object System.Windows.Forms.PictureBox
$picIcon.Location = New-Object System.Drawing.Point((DPX $M), (DPX 18))
$picIcon.Size = New-Object System.Drawing.Size((DPX 30), (DPX 30))
$picIcon.BackColor = CC $script:C.Header
$picIcon.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::Zoom
if ($panelIcon) { $picIcon.Image = $panelIcon.ToBitmap() }
$script:Form.Controls.Add($picIcon)

$chromeMin = New-ChromeButton -Glyph '—' -X 374 -Y 16 -IsClose $false
$chromeClose = New-ChromeButton -Glyph '✕' -X 404 -Y 16 -IsClose $true
$script:Form.Controls.Add($chromeMin)
$script:Form.Controls.Add($chromeClose)

$topStrip = New-Object System.Windows.Forms.Panel
$topStrip.Location = New-Object System.Drawing.Point(0, 0)
$topStrip.Size = New-Object System.Drawing.Size((DPX $W), (DPX 3))
$topStrip.BackColor = CC $script:C.Track
$script:Form.Controls.Add($topStrip)

$headLine = New-Object System.Windows.Forms.Panel
$headLine.Location = New-Object System.Drawing.Point(0, (DPX 64))
$headLine.Size = New-Object System.Drawing.Size((DPX $W), (DPX 1))
$headLine.BackColor = CC $script:C.Line
$script:Form.Controls.Add($headLine)

# status pill
$pill = New-RoundBox -X $M -Y 80 -W 104 -H 30 -Bg $script:C.Line -Radius 15 -Line ''
$pill | Add-Member -MemberType NoteProperty -Name PillOn -Value $false -Force
$pill.Add_Paint({
  param($s, $e)
  $e.Graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $dotColor = CC $script:C.Muted
  if ($s.PillOn) { $dotColor = CC '#07C160' }
  $br = New-Object System.Drawing.SolidBrush($dotColor)
  $e.Graphics.FillEllipse($br, [single](13.5 * $script:DpiScale), [single](10.5 * $script:DpiScale), [single](9 * $script:DpiScale), [single](9 * $script:DpiScale))
  $br.Dispose()
})
$script:Form.Controls.Add($pill)
$lblPill = New-UiLabel -Parent $script:Form -Text '已停止' -X ($M + 28) -Y 80 -W 68 -H 30 `
  -Size 9.5 -Bold $true -Color $script:C.Sub -Bg $script:C.Line -Align 'MiddleLeft'
$lblPill.BringToFront()

$lblRounds = New-UiLabel -Parent $script:Form -Text '轮次 0' -X 250 -Y 80 -W ($CW - 226) -H 30 `
  -Size 9 -Bold $false -Color $script:C.Muted -Bg $script:C.Header -Align 'MiddleRight'

# stats card
$card = New-RoundBox -X $M -Y 124 -W $CW -H 176 -Bg $script:C.Card -Radius 14 -Line $script:C.CardLine
$card.Add_Paint({
  param($s, $e)
  $e.Graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $pth = New-RoundPath 0.5 0.5 ($s.Width - 1) ($s.Height - 1) (14 * $script:DpiScale)
  $pen = New-Object System.Drawing.Pen((CC '#ECEEF1'), (1 * $script:DpiScale))
  $e.Graphics.DrawPath($pen, $pth)
  $sep = New-Object System.Drawing.Pen((CC '#F1F3F6'), (1 * $script:DpiScale))
  for ($i = 1; $i -le 4; $i++) {
    $y = (8 * $script:DpiScale) + ((32 * $script:DpiScale) * $i)
    $e.Graphics.DrawLine($sep, (20 * $script:DpiScale), $y, ($s.Width - (20 * $script:DpiScale)), $y)
  }
  $pen.Dispose(); $sep.Dispose(); $pth.Dispose()
})
$script:Form.Controls.Add($card)

$rowKeys = @('模式', '进程', '今日发出', '待发队列', '最后动作')
$rowVals = @()
for ($i = 0; $i -lt $rowKeys.Count; $i++) {
  $y = 8 + (32 * $i)
  [void](New-UiLabel -Parent $card -Text $rowKeys[$i] -X 20 -Y $y -W 84 -H 30 `
    -Size 9 -Bold $false -Color $script:C.Sub -Bg $script:C.Card -Align 'MiddleLeft')
  $rowVals += (New-UiLabel -Parent $card -Text '—' -X 112 -Y $y -W ($CW - 136) -H 30 `
    -Size 9.5 -Bold $false -Color $script:C.Text -Bg $script:C.Card -Align 'MiddleLeft')
}

# last sent
$lastBox = New-RoundBox -X $M -Y 312 -W $CW -H 56 -Bg '#FAFBFC' -Radius 12 -Line $script:C.CardLine
$script:Form.Controls.Add($lastBox)
[void](New-UiLabel -Parent $lastBox -Text '最后发出' -X 16 -Y 8 -W 100 -H 16 `
  -Size 8.5 -Bold $false -Color $script:C.Muted -Bg '#FAFBFC' -Align 'MiddleLeft')
$lblLast = New-UiLabel -Parent $lastBox -Text '—' -X 16 -Y 25 -W ($CW - 32) -H 22 `
  -Size 9.5 -Bold $false -Color $script:C.Text -Bg '#FAFBFC' -Align 'MiddleLeft'

# primary action
$btnPrimary = New-FlatButton -Text '启动' -X $M -Y 382 -W $CW -H 50 -Name 'primary' `
  -Bg $script:C.Accent -Fg '#FFFFFF' -HoverBg $script:C.AccentHi -PressBg '#04984C' -Line '' `
  -Radius 12 -Size 11.5 -Bold $true
$script:Form.Controls.Add($btnPrimary)

# secondary actions
$btnLogs = New-FlatButton -Text '看日志' -X $M -Y 444 -W 84 -H 32 -Name 'logs' `
  -Bg '#FFFFFF' -Fg $script:C.Sub -HoverBg $script:C.Hover -PressBg '#EAEDF1' -Line $script:C.Border `
  -Radius 9 -Size 9 -Bold $false
$btnFolder = New-FlatButton -Text '打开文件夹' -X ($M + 92) -Y 444 -W 96 -H 32 -Name 'folder' `
  -Bg '#FFFFFF' -Fg $script:C.Sub -HoverBg $script:C.Hover -PressBg '#EAEDF1' -Line $script:C.Border `
  -Radius 9 -Size 9 -Bold $false
$btnContacts = New-FlatButton -Text '联系人' -X ($M + 196) -Y 444 -W 64 -H 32 -Name 'contacts' `
  -Bg '#FFFFFF' -Fg $script:C.Sub -HoverBg $script:C.Hover -PressBg '#EAEDF1' -Line $script:C.Border `
  -Radius 9 -Size 9 -Bold $false
$btnStats = New-FlatButton -Text '统计' -X ($M + 268) -Y 444 -W 60 -H 32 -Name 'stats' `
  -Bg '#FFFFFF' -Fg $script:C.Sub -HoverBg $script:C.Hover -PressBg '#EAEDF1' -Line $script:C.Border `
  -Radius 9 -Size 9 -Bold $false
$btnRefresh = New-FlatButton -Text '刷新' -X ($W - $M - 64) -Y 444 -W 64 -H 32 -Name 'refresh' `
  -Bg '#FFFFFF' -Fg $script:C.Sub -HoverBg $script:C.Hover -PressBg '#EAEDF1' -Line $script:C.Border `
  -Radius 9 -Size 9 -Bold $false
$script:Form.Controls.Add($btnLogs)
$script:Form.Controls.Add($btnFolder)
$script:Form.Controls.Add($btnContacts)
$script:Form.Controls.Add($btnStats)
$script:Form.Controls.Add($btnRefresh)

# option toggles
$optCard = New-RoundBox -X $M -Y 488 -W $CW -H 86 -Bg '#FFFFFF' -Radius 12 -Line $script:C.CardLine
$script:Form.Controls.Add($optCard)

$tgDry = New-Toggle -X 16 -Y 15 -Name 'tgDry'
$lblDry = New-UiLabel -Parent $optCard -Text '只造草稿，不真的发送' -X 64 -Y 15 -W 150 -H 23 `
  -Size 9 -Bold $false -Color $script:C.Sub -Bg '#FFFFFF' -Align 'MiddleLeft'
$lblDry.Cursor = [System.Windows.Forms.Cursors]::Hand
$lblDry | Add-Member -MemberType NoteProperty -Name Toggle -Value $tgDry -Force
$lblDry.Add_Click({
  param($s, $e)
  $t = $s.Toggle
  $t.Checked = -not $t.Checked
  $t.Invalidate()
  if ($script:AnimTimer) { $script:AnimTimer.Start() }
  Invoke-PanelToggle -Name $t.Name -Checked $t.Checked
})
$optCard.Controls.Add($tgDry)
$optCard.Controls.Add($lblDry)

$tgTop = New-Toggle -X 236 -Y 15 -Name 'tgTop'
$lblTop = New-UiLabel -Parent $optCard -Text '窗口置顶' -X 284 -Y 15 -W 96 -H 23 `
  -Size 9 -Bold $false -Color $script:C.Sub -Bg '#FFFFFF' -Align 'MiddleLeft'
$lblTop.Cursor = [System.Windows.Forms.Cursors]::Hand
$lblTop | Add-Member -MemberType NoteProperty -Name Toggle -Value $tgTop -Force
$lblTop.Add_Click({
  param($s, $e)
  $t = $s.Toggle
  $t.Checked = -not $t.Checked
  $t.Invalidate()
  if ($script:AnimTimer) { $script:AnimTimer.Start() }
  Invoke-PanelToggle -Name $t.Name -Checked $t.Checked
})
$optCard.Controls.Add($tgTop)
$optCard.Controls.Add($lblTop)

$tgAuto = New-Toggle -X 16 -Y 50 -Name 'tgAuto'
$lblAuto = New-UiLabel -Parent $optCard -Text '开机自启' -X 64 -Y 50 -W 120 -H 23 `
  -Size 9 -Bold $false -Color $script:C.Sub -Bg '#FFFFFF' -Align 'MiddleLeft'
$lblAuto.Cursor = [System.Windows.Forms.Cursors]::Hand
$lblAuto | Add-Member -MemberType NoteProperty -Name Toggle -Value $tgAuto -Force
$lblAuto.Add_Click({
  param($s, $e)
  $t = $s.Toggle
  $t.Checked = -not $t.Checked
  $t.Invalidate()
  if ($script:AnimTimer) { $script:AnimTimer.Start() }
  Invoke-PanelToggle -Name $t.Name -Checked $t.Checked
})
$optCard.Controls.Add($tgAuto)
$optCard.Controls.Add($lblAuto)

$tgTheme = New-Toggle -X 220 -Y 50 -Name 'tgTheme'
$lblTheme = New-UiLabel -Parent $optCard -Text '深色主题' -X 268 -Y 50 -W 110 -H 23 `
  -Size 9 -Bold $false -Color $script:C.Sub -Bg '#FFFFFF' -Align 'MiddleLeft'
$lblTheme.Cursor = [System.Windows.Forms.Cursors]::Hand
$lblTheme | Add-Member -MemberType NoteProperty -Name Toggle -Value $tgTheme -Force
$lblTheme.Add_Click({
  param($s, $e)
  $t = $s.Toggle
  $t.Checked = -not $t.Checked
  $t.Invalidate()
  if ($script:AnimTimer) { $script:AnimTimer.Start() }
  Invoke-PanelToggle -Name $t.Name -Checked $t.Checked
})
$optCard.Controls.Add($tgTheme)
$optCard.Controls.Add($lblTheme)

$footLine = New-Object System.Windows.Forms.Panel
$footLine.Location = New-Object System.Drawing.Point(0, (DPX 586))
$footLine.Size = New-Object System.Drawing.Size((DPX $W), (DPX 1))
$footLine.BackColor = CC $script:C.Line
$script:Form.Controls.Add($footLine)

$lblFoot = New-UiLabel -Parent $script:Form -Text 'v1.0.0 · 面板只负责起停，关掉这个窗口不会停掉后台回复' -X $M -Y 592 -W ($CW) -H 18 `
  -Size 8.5 -Bold $false -Color $script:C.Muted -Bg $script:C.Header -Align 'MiddleLeft'

# let the whole window (except buttons and switches) be a drag handle
Enable-WindowDrag $script:Form

# ------------------------------------------------------------------ theme start
# -Theme wins, otherwise the remembered choice, otherwise light
if (-not $Theme) {
  try {
    $tp = Join-Path $script:StateDir 'theme.txt'
    if (Test-Path -LiteralPath $tp) { $Theme = ([System.IO.File]::ReadAllText($tp)).Trim() }
  } catch { }
}
if ($Theme -eq 'dark') { Set-Theme 'dark' } else { $script:ThemeName = 'light' }

# ------------------------------------------------------------------ refresh
$script:Ui = @{
  Pill = $pill; PillText = $lblPill; Strip = $topStrip; Rounds = $lblRounds
  Mode = $rowVals[0]; Proc = $rowVals[1]; Today = $rowVals[2]; Queue = $rowVals[3]; Action = $rowVals[4]
  Last = $lblLast; Primary = $btnPrimary; TgDry = $tgDry; TgTop = $tgTop; TgAuto = $tgAuto; TgTheme = $tgTheme
}
$script:LastRunning = $null
$script:ForceStyle = $true

# ------------------------------------------------------- window position memory
function Save-PanelPos {
  try {
    $p = Join-Path $script:StateDir 'panel-pos.txt'
    [System.IO.File]::WriteAllText($p, ('' + $script:Form.Location.X + ',' + $script:Form.Location.Y), (New-Object System.Text.ASCIIEncoding))
  } catch { }
}

function Restore-PanelPos {
  try {
    $p = Join-Path $script:StateDir 'panel-pos.txt'
    if (-not (Test-Path -LiteralPath $p)) { return }
    $bits = ([System.IO.File]::ReadAllText($p)).Trim().Split(',')
    if ($bits.Count -ne 2) { return }
    $x = [int]$bits[0]; $y = [int]$bits[1]
    $onScreen = $false
    foreach ($sc in [System.Windows.Forms.Screen]::AllScreens) {
      $b = $sc.WorkingArea
      if ($x -ge ($b.X - 40) -and $x -le ($b.Right - 80) -and $y -ge ($b.Y - 10) -and $y -le ($b.Bottom - 60)) { $onScreen = $true; break }
    }
    if (-not $onScreen) { return }
    $script:Form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $script:Form.Location = New-Object System.Drawing.Point($x, $y)
  } catch { }
}

# ------------------------------------------------------------------ autostart
function Get-AutoStartPath {
  return (Join-Path ([Environment]::GetFolderPath('Startup')) '微信自动回复（后台）.cmd')
}
function Test-AutoStart { return [bool](Test-Path -LiteralPath (Get-AutoStartPath)) }
function Set-AutoStart([bool]$On) {
  $p = Get-AutoStartPath
  try {
    if ($On) {
      $cmd = '@echo off' + "`r`n" + 'rem start the WeChat auto-reply bot in the background at sign-in' + "`r`n" +
             ('start "" /min powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -IntervalSec 5' -f (Join-Path $script:Root 'wx-watch-daemon.ps1')) + "`r`n"
      [System.IO.File]::WriteAllText($p, $cmd, (New-Object System.Text.ASCIIEncoding))
    } elseif (Test-Path -LiteralPath $p) {
      Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
    }
    Add-PanelLog ('autostart: {0}' -f $On)
  } catch { Add-PanelLog ('autostart failed: {0}' -f $_.Exception.Message) }
}

# ------------------------------------------------------------------ tray icon
$script:Tray = $null
$script:TrayMenu = $null
function Show-PanelWindow {
  try {
    $script:Form.Show()
    if ($script:Form.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) {
      $script:Form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
    }
    $script:Form.Activate()
  } catch { }
}
function Hide-PanelWindow { try { $script:Form.Hide() } catch { } }
function New-TrayItem([string]$Text, [scriptblock]$OnClick, [bool]$Checkable) {
  $it = New-Object System.Windows.Forms.ToolStripMenuItem($Text)
  $it.Add_Click($OnClick)
  if ($Checkable) { $it.CheckOnClick = $false }
  return $it
}
if ($panelIcon) {
  try {
    $script:Tray = New-Object System.Windows.Forms.NotifyIcon
    try { $script:Tray.Icon = New-Object System.Drawing.Icon($script:IconPath, 16, 16) } catch { $script:Tray.Icon = $panelIcon }
    $script:Tray.Text = '微信自动回复'
    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $miShow = New-TrayItem '显示面板' { Show-PanelWindow } $false
    $miHide = New-TrayItem '隐藏到后台' { Hide-PanelWindow } $false
    $miLogs = New-TrayItem '查看日志' { Show-LogViewer } $false
    $miStats = New-TrayItem '发送统计' { Show-StatsViewer } $false
    $miContacts = New-TrayItem '联系人…' { Show-ContactsViewer } $false
    $miNotify = New-TrayItem '气泡通知' { Set-NoticeEnabled (-not $script:NoticeOn); $script:ForceStyle = $true; Update-Panel } $true
    $miRun  = New-TrayItem '启动自动回复' { if (Test-BotRunning) { [void](Stop-Auto) } else { [void](Start-Auto) }; $script:ForceStyle = $true; Update-Panel } $false
    $miAuto = New-TrayItem '开机自启' { Set-AutoStart (-not (Test-AutoStart)); $script:ForceStyle = $true; Update-Panel } $true
    $miExit = New-TrayItem '退出' { try { $script:Tray.Visible = $false; $script:Tray.Dispose() } catch { }; $script:Form.Close() } $false
    [void]$menu.Items.Add($miShow)
    [void]$menu.Items.Add($miHide)
    [void]$menu.Items.Add($miLogs)
    [void]$menu.Items.Add($miStats)
    [void]$menu.Items.Add($miContacts)
    [void]$menu.Items.Add($miNotify)
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    [void]$menu.Items.Add($miRun)
    [void]$menu.Items.Add($miAuto)
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    [void]$menu.Items.Add($miExit)
    $script:Tray.ContextMenuStrip = $menu
    $script:Tray.Visible = $true
    $script:Tray.Add_MouseClick({ param($s, $e) if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Show-PanelWindow } })
    $script:Tray.Add_MouseDoubleClick({ param($s, $e) Show-PanelWindow })
    $script:TrayMenu = @{ Run = $miRun; Auto = $miAuto; Notify = $miNotify }
    Add-PanelLog 'tray: icon ready'
  } catch {
    Add-PanelLog ('tray failed: {0}' -f $_.Exception.Message)
    $script:Tray = $null
  }
}

$script:NoticeOn = $true
$script:WantNoticeTest = [bool]$NoticeTest

$script:Form.Add_ResizeEnd({ Save-PanelPos })
$script:Form.Add_FormClosed({
  Save-PanelPos
  try { if ($script:Tray) { $script:Tray.Visible = $false; $script:Tray.Dispose() } } catch { }
  try { if ($script:PanelMutex) { $script:PanelMutex.ReleaseMutex(); $script:PanelMutex.Dispose() } } catch { }
})

# ------------------------------------------------------------------ statistics
# 发送统计: four KPI tiles, seven day bars and today's hourly spread, parsed from
# the reply log. The parse is cached against the file stamp, so redrawing while
# nothing has been sent costs nothing.
$script:Sv = @{ Form = $null; Kpi = $null; Chart = $null; Hours = $null; Status = $null; Timer = $null; Stamp = ''; Data = $null }

function Get-SendStats {
  $path = Join-Path $script:LogDir 'wx-reply-log.txt'
  $stamp = ''
  try {
    $fi = Get-Item -LiteralPath $path -ErrorAction Stop
    $stamp = ('{0}|{1}' -f $fi.LastWriteTimeUtc.Ticks, $fi.Length)
  } catch { }
  if ($script:Sv.Data -and $stamp -eq $script:Sv.Stamp) { return $script:Sv.Data }
  $days = @{}
  $drafts = @{}
  $hours = New-Object 'int[]' 24
  $today = (Get-Date).Date
  $sent7 = 0
  if ($stamp) {
    try {
      foreach ($ln in [System.IO.File]::ReadAllLines($path)) {
        if ($ln.Length -lt 21) { continue }
        $ts = [datetime]::MinValue
        if (-not [datetime]::TryParse($ln.Substring(0, 19), [ref]$ts)) { continue }
        $k = $ts.ToString('yyyy-MM-dd')
        if ($ln -match '\[SENT\]') {
          if ($days.ContainsKey($k)) { $days[$k] = $days[$k] + 1 } else { $days[$k] = 1 }
          if ($ts.Date -eq $today) { $hours[$ts.Hour] = $hours[$ts.Hour] + 1 }
          if ($ts.Date -gt $today.AddDays(-7)) { $sent7 = $sent7 + 1 }
        } elseif ($ln -match '\[DRYRUN\]' -or $ln -match '\[DRAFT\]') {
          if ($drafts.ContainsKey($k)) { $drafts[$k] = $drafts[$k] + 1 } else { $drafts[$k] = 1 }
        }
      }
    } catch { }
  }
  $series = @()
  for ($i = 6; $i -ge 0; $i--) {
    $d = $today.AddDays(-$i)
    $k = $d.ToString('yyyy-MM-dd')
    $c = 0; if ($days.ContainsKey($k)) { $c = $days[$k] }
    $dd = 0; if ($drafts.ContainsKey($k)) { $dd = $drafts[$k] }
    $series += [pscustomobject]@{ Label = $d.ToString('MM-dd'); Sent = $c; Draft = $dd }
  }
  $total = 0
  foreach ($v in $days.Values) { $total = $total + $v }
  $data = [pscustomobject]@{
    Series = $series; Hours = $hours; Today = $series[6].Sent; TodayDraft = $series[6].Draft
    Week = $sent7; Avg = [math]::Round($sent7 / 7.0, 1); Total = $total
    Since = $series[0].Label; Until = $series[6].Label
  }
  $script:Sv.Stamp = $stamp
  $script:Sv.Data = $data
  return $data
}

function Draw-StatsKpi($p, $g, $d) {
  $s = $script:DpiScale
  $gap = 10 * $s
  $w = ($p.Width - ($gap * 5)) / 4
  $h = $p.Height - (2 * $gap)
  $caps = @('今日发出', '今日草稿', '近 7 天', '平均每天')
  $vals = @(('' + $d.Today), ('' + $d.TodayDraft), ('' + $d.Week), ('' + $d.Avg))
  $fBig = New-UiFont 14 ([System.Drawing.FontStyle]::Bold)
  $fCap = New-UiFont 8.5 ([System.Drawing.FontStyle]::Regular)
  $sf = New-Object System.Drawing.StringFormat
  $sf.Alignment = [System.Drawing.StringAlignment]::Center
  for ($i = 0; $i -lt 4; $i++) {
    $x = $gap + $i * ($w + $gap)
    $pth = New-RoundPath ($x + 0.5) ($gap + 0.5) ($w - 1) ($h - 1) (10 * $s)
    $br = New-Object System.Drawing.SolidBrush((CC $script:C.Card))
    $g.FillPath($br, $pth); $br.Dispose()
    $pen = New-Object System.Drawing.Pen((CC $script:C.CardLine), (1 * $s))
    $g.DrawPath($pen, $pth); $pen.Dispose(); $pth.Dispose()
    $bVal = New-Object System.Drawing.SolidBrush((CC $script:C.Text))
    $bCap = New-Object System.Drawing.SolidBrush((CC $script:C.Sub))
    $rVal = New-Object System.Drawing.RectangleF([float]$x, [float]($gap + (10 * $s)), [float]$w, [float](40 * $s))
    $rCap = New-Object System.Drawing.RectangleF([float]$x, [float]($gap + (52 * $s)), [float]$w, [float](20 * $s))
    $g.DrawString($vals[$i], $fBig, $bVal, $rVal, $sf)
    $g.DrawString($caps[$i], $fCap, $bCap, $rCap, $sf)
    $rVal = $null; $rCap = $null
    $bVal.Dispose(); $bCap.Dispose()
  }
  $sf.Dispose(); $fBig.Dispose(); $fCap.Dispose()
}

function Draw-StatsBars($p, $g, $d) {
  $s = $script:DpiScale
  $padL = 12 * $s; $padR = 12 * $s; $padT = 24 * $s; $padB = 30 * $s
  $plotW = $p.Width - $padL - $padR
  $plotH = $p.Height - $padT - $padB
  $base = $p.Height - $padB
  $max = 1
  foreach ($it in $d.Series) { if ($it.Sent -gt $max) { $max = $it.Sent } }
  $penLine = New-Object System.Drawing.Pen((CC $script:C.Line), (1 * $s))
  $g.DrawLine($penLine, [float]$padL, [float]($base + 0.5), [float]($p.Width - $padR), [float]($base + 0.5))
  $penLine.Dispose()
  $slot = $plotW / 7
  $bw = $slot * 0.5
  $fVal = New-UiFont 9 ([System.Drawing.FontStyle]::Bold)
  $fCap = New-UiFont 8.5 ([System.Drawing.FontStyle]::Regular)
  $sf = New-Object System.Drawing.StringFormat
  $sf.Alignment = [System.Drawing.StringAlignment]::Center
  for ($i = 0; $i -lt 7; $i++) {
    $it = $d.Series[$i]
    $x = $padL + $i * $slot + (($slot - $bw) / 2)
    $bh = 0.0
    if ($it.Sent -gt 0) { $bh = $plotH * ($it.Sent / [double]$max) }
    $col = $script:C.Accent
    if ($i -eq 6) { $col = $script:C.AccentOn }
    $br = New-Object System.Drawing.SolidBrush((CC $col))
    if ($it.Sent -gt 0) {
      if ($bh -ge (10 * $s)) {
        $pth = New-RoundPath ($x + 0.5) (($base - $bh) + 0.5) ($bw - 1) ($bh - 1) (4 * $s)
        $g.FillPath($br, $pth); $pth.Dispose()
      } else {
        $g.FillRectangle($br, [float]$x, [float]($base - $bh), [float]$bw, [float]$bh)
      }
    } else {
      $br.Dispose()
      $br = New-Object System.Drawing.SolidBrush((CC $script:C.Line))
      $g.FillRectangle($br, [float]$x, [float]($base - (2 * $s)), [float]$bw, [float](2 * $s))
    }
    $br.Dispose()
    $bVal = New-Object System.Drawing.SolidBrush((CC $(if ($i -eq 6) { $script:C.AccentOn } else { $script:C.Text })))
    $bCap = New-Object System.Drawing.SolidBrush((CC $(if ($i -eq 6) { $script:C.AccentOn } else { $script:C.Sub })))
    $rVal = New-Object System.Drawing.RectangleF([float]($x - (10 * $s)), [float]($base - $bh - (20 * $s)), [float]($bw + (20 * $s)), [float](16 * $s))
    $rCap = New-Object System.Drawing.RectangleF([float]($padL + $i * $slot), [float]($base + (5 * $s)), [float]$slot, [float](18 * $s))
    if ($it.Sent -gt 0) { $g.DrawString(('' + $it.Sent), $fVal, $bVal, $rVal, $sf) }
    $g.DrawString($it.Label, $fCap, $bCap, $rCap, $sf)
    $rVal = $null; $rCap = $null
    $bVal.Dispose(); $bCap.Dispose()
  }
  $sf.Dispose(); $fVal.Dispose(); $fCap.Dispose()
}

function Draw-StatsHours($p, $g, $d) {
  $s = $script:DpiScale
  $padL = 12 * $s; $padR = 12 * $s; $padT = 24 * $s; $padB = 22 * $s
  $plotW = $p.Width - $padL - $padR
  $base = $p.Height - $padB
  $plotH = $base - $padT
  $max = 1
  for ($i = 0; $i -lt 24; $i++) { if ($d.Hours[$i] -gt $max) { $max = $d.Hours[$i] } }
  $nowH = (Get-Date).Hour
  $slot = $plotW / 24
  $bw = $slot * 0.62
  $fCap = New-UiFont 8 ([System.Drawing.FontStyle]::Regular)
  $bCap = New-Object System.Drawing.SolidBrush((CC $script:C.Muted))
  $fTitle = New-UiFont 8.5 ([System.Drawing.FontStyle]::Regular)
  $bTitle = New-Object System.Drawing.SolidBrush((CC $script:C.Sub))
  $g.DrawString('今日各小时', $fTitle, $bTitle, [float]$padL, [float](2 * $s))
  $penLine = New-Object System.Drawing.Pen((CC $script:C.Line), (1 * $s))
  $g.DrawLine($penLine, [float]$padL, [float]($base + 0.5), [float]($p.Width - $padR), [float]($base + 0.5))
  $penLine.Dispose()
  for ($i = 0; $i -lt 24; $i++) {
    $v = $d.Hours[$i]
    $bh = 0.0
    if ($v -gt 0) { $bh = $plotH * ($v / [double]$max) }
    $x = $padL + $i * $slot + (($slot - $bw) / 2)
    if ($v -gt 0) {
      $col = $script:C.Accent
      if ($i -eq $nowH) { $col = $script:C.AccentHi }
      $br = New-Object System.Drawing.SolidBrush((CC $col))
      $g.FillRectangle($br, [float]$x, [float]($base - $bh), [float]$bw, [float]$bh)
      $br.Dispose()
    } else {
      $br = New-Object System.Drawing.SolidBrush((CC $script:C.Line))
      $g.FillRectangle($br, [float]$x, [float]($base - (2 * $s)), [float]$bw, [float](2 * $s))
      $br.Dispose()
    }
    if (($i % 6) -eq 0) {
      $sf = New-Object System.Drawing.StringFormat
      $sf.Alignment = [System.Drawing.StringAlignment]::Center
      $rCap = New-Object System.Drawing.RectangleF([float]($padL + $i * $slot - $slot), [float]($base + (3 * $s)), [float]($slot * 3), [float](16 * $s))
      $g.DrawString(('' + $i + ':00'), $fCap, $bCap, $rCap, $sf)
      $sf.Dispose(); $rCap = $null
    }
  }
  $fCap.Dispose(); $bCap.Dispose(); $fTitle.Dispose(); $bTitle.Dispose()
}

function Update-StatsView {
  $sv = $script:Sv
  if (-not $sv.Form -or $sv.Form.IsDisposed) { return }
  $d = Get-SendStats
  if ($sv.Kpi) { $sv.Kpi.Invalidate() }
  if ($sv.Chart) { $sv.Chart.Invalidate() }
  if ($sv.Hours) { $sv.Hours.Invalidate() }
  if ($sv.Status) {
    $sv.Status.Text = ('统计 {0} 至 {1} · 累计发出 {2} 条 · 数据来自 logs\wx-reply-log.txt' -f $d.Since, $d.Until, $d.Total)
  }
}

function Show-StatsViewer {
  if ($script:Sv.Form -and -not $script:Sv.Form.IsDisposed) { $script:Sv.Form.Activate(); return }
  $d = Get-SendStats
  $f = New-Object System.Windows.Forms.Form
  $f.Text = '发送统计 · 微信自动回复'
  $f.ClientSize = New-Object System.Drawing.Size((DPX 820), (DPX 500))
  $f.MinimumSize = New-Object System.Drawing.Size((DPX 660), (DPX 420))
  $f.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
  $f.BackColor = CC $script:C.Bg
  $f.ForeColor = CC $script:C.Text
  $f.Font = New-UiFont 9 ([System.Drawing.FontStyle]::Regular)
  try { $f.Icon = New-Object System.Drawing.Icon($script:IconPath, 16, 16) } catch { }

  $kpi = New-Object System.Windows.Forms.Panel
  $kpi.Location = New-Object System.Drawing.Point((DPX 12), (DPX 12))
  $kpi.Size = New-Object System.Drawing.Size((DPX 796), (DPX 92))
  $kpi.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
  $kpi.BackColor = CC $script:C.Bg
  Set-DoubleBuffer $kpi
  $kpi.Add_Paint({ param($s, $e) if ($script:Sv.Data) { Draw-StatsKpi $s $e.Graphics $script:Sv.Data } })

  $chart = New-Object System.Windows.Forms.Panel
  $chart.Location = New-Object System.Drawing.Point((DPX 12), (DPX 116))
  $chart.Size = New-Object System.Drawing.Size((DPX 796), (DPX 236))
  $chart.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
  $chart.BackColor = CC $script:C.Bg
  Set-DoubleBuffer $chart
  $chart.Add_Paint({ param($s, $e) if ($script:Sv.Data) { Draw-StatsBars $s $e.Graphics $script:Sv.Data } })

  $hours = New-Object System.Windows.Forms.Panel
  $hours.Location = New-Object System.Drawing.Point((DPX 12), (DPX 362))
  $hours.Size = New-Object System.Drawing.Size((DPX 796), (DPX 80))
  $hours.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
  $hours.BackColor = CC $script:C.Bg
  Set-DoubleBuffer $hours
  $hours.Add_Paint({ param($s, $e) if ($script:Sv.Data) { Draw-StatsHours $s $e.Graphics $script:Sv.Data } })

  $status = New-Object System.Windows.Forms.Label
  $status.Location = New-Object System.Drawing.Point((DPX 14), (DPX 451))
  $status.Size = New-Object System.Drawing.Size((DPX 540), (DPX 22))
  $status.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
  $status.ForeColor = CC $script:C.Muted
  $status.BackColor = [System.Drawing.Color]::Transparent
  $status.Text = ''

  $btnRe = New-FlatButton -Text '刷新' -X 570 -Y 448 -W 74 -H 30 -Name 'stats-refresh' `
    -Bg '#FFFFFF' -Fg $script:C.Sub -HoverBg $script:C.Hover -PressBg '#EAEDF1' -Line $script:C.Border `
    -Radius 9 -Size 9 -Bold $false
  $btnLg = New-FlatButton -Text '查看日志' -X 652 -Y 448 -W 74 -H 30 -Name 'stats-logs' `
    -Bg '#FFFFFF' -Fg $script:C.Sub -HoverBg $script:C.Hover -PressBg '#EAEDF1' -Line $script:C.Border `
    -Radius 9 -Size 9 -Bold $false
  $btnCl = New-FlatButton -Text '关闭' -X 734 -Y 448 -W 74 -H 30 -Name 'stats-close' `
    -Bg '#FFFFFF' -Fg $script:C.Sub -HoverBg $script:C.Hover -PressBg '#EAEDF1' -Line $script:C.Border `
    -Radius 9 -Size 9 -Bold $false
  $btnRe.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
  $btnLg.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
  $btnCl.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right

  $f.Controls.Add($kpi)
  $f.Controls.Add($chart)
  $f.Controls.Add($hours)
  $f.Controls.Add($status)
  $f.Controls.Add($btnRe)
  $f.Controls.Add($btnLg)
  $f.Controls.Add($btnCl)

  $f.Add_Shown({
    try {
      if ($script:ThemeName -eq 'dark') {
        $one = 1
        [void][WxPanel.Native]::DwmSetWindowAttribute($script:Sv.Form.Handle, 20, [ref]$one, 4)
      }
    } catch { }
  })
  $f.Add_FormClosed({
    try {
      if ($script:Sv.Timer) { $script:Sv.Timer.Stop(); $script:Sv.Timer.Dispose(); $script:Sv.Timer = $null }
    } catch { }
    $script:Sv.Form = $null
  })

  $script:Sv.Form = $f
  $script:Sv.Kpi = $kpi
  $script:Sv.Chart = $chart
  $script:Sv.Hours = $hours
  $script:Sv.Status = $status
  $script:Sv.Timer = New-Object System.Windows.Forms.Timer
  $script:Sv.Timer.Interval = 5000
  $script:Sv.Timer.Add_Tick({ Update-StatsView })
  $script:Sv.Timer.Start()
  Update-StatsView
  try {
    [void][WxPanel.Win]::SetForegroundWindow($f.Handle)
  } catch { }
  $f.Show($script:Form)
  $f.BringToFront()
}

# ------------------------------------------------------------------ log viewer
# A small in-app reader: pick a log file, filter it, show the last N lines and
# keep following it. Only the tail of a large file is loaded, so opening a big
# log stays instant. The state lives in $script:Lv because event handlers run
# outside the scope that created them.
$script:Lv = @{ Form = $null; Box = $null; Combo = $null; Filter = $null; Count = $null; Auto = $null; Status = $null; File = ''; Timer = $null }

function Get-LogFiles {
  $dir = Join-Path $script:Root 'logs'
  $names = @()
  try {
    if (Test-Path -LiteralPath $dir) {
      $names = @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -eq '.log' -or $_.Extension -eq '.txt' } |
        Sort-Object LastWriteTime -Descending | ForEach-Object { $_.Name })
    }
  } catch { }
  if ($names.Count -eq 0) { $names = @('panel.log') }
  return $names
}

function Read-LogTail {
  param([string]$Path, [int]$MaxLines, [int]$MaxBytes = 524288)
  try {
    $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
      $len = $fs.Length
      $take = [int][math]::Min([int64]$MaxBytes, $len)
      [void]$fs.Seek(($len - $take), [System.IO.SeekOrigin]::Begin)
      $buf = New-Object byte[] $take
      $read = $fs.Read($buf, 0, $take)
    } finally { $fs.Dispose() }
    $text = [System.Text.Encoding]::UTF8.GetString($buf, 0, $read)
    $lines = @($text -split "`r?`n")
    if ($take -lt $len -and $lines.Count -gt 0) {
      $lines[0] = ('…（更早的 ' + [math]::Round(($len - $take) / 1KB) + ' KB 未载入）')
    }
    if ($MaxLines -gt 0 -and $lines.Count -gt $MaxLines) {
      $lines = @($lines[($lines.Count - $MaxLines)..($lines.Count - 1)])
    }
    return $lines
  } catch {
    return @('（无法读取：' + $Path + '）')
  }
}

function Update-LogView {
  $lv = $script:Lv
  if (-not $lv.Box -or $lv.Box.IsDisposed) { return }
  try {
    $dir = Join-Path $script:Root 'logs'
    $name = $lv.File
    if (-not $name) { $name = 'panel.log' }
    $path = Join-Path $dir $name
    $max = 0
    if ($lv.Count.Text -match '^(\d+)') { $max = [int]$Matches[1] }
    $lines = @(Read-LogTail -Path $path -MaxLines $max)
    $total = $lines.Count
    $needle = $lv.Filter.Text
    if ($needle) { $lines = @($lines | Where-Object { $_ -like ('*' + $needle + '*') }) }
    $lv.Box.Text = ($lines -join "`r`n")
    # ScrollToCaret() is a no-op when the caret is already visible, so the offset
    # a filter change left behind would survive: jump to the first column first,
    # then walk the caret down to the last line for the tail behaviour.
    $lv.Box.Select(0, 0)
    $lv.Box.ScrollToCaret()
    try { [void][WxPanel.Win]::SendMessage($lv.Box.Handle, 0x00B6, [System.IntPtr](-4096), [System.IntPtr]::Zero) } catch { }
    $idx = $lv.Box.TextLength
    $nl = $lv.Box.Text.LastIndexOf("`r")
    if ($nl -ge 0) { $idx = $nl + 1 }
    $lv.Box.SelectionStart = $idx
    $lv.Box.SelectionLength = 0
    $lv.Box.ScrollToCaret()
    $info = ''
    try {
      $fi = Get-Item -LiteralPath $path -ErrorAction Stop
      $info = ('{0:N1} KB · 更新于 {1}' -f ($fi.Length / 1KB), $fi.LastWriteTime.ToString('MM-dd HH:mm:ss'))
    } catch { }
    $state = '已暂停'
    if ($lv.Auto.Checked) { $state = '自动刷新 2 秒' }
    $lv.Status.Text = ('显示 {0} / {1} 行 · {2} · {3} · {4}' -f $lines.Count, $total, $name, $info, $state)
  } catch { }
}

function Show-LogViewer {
  if ($script:Lv.Form -and -not $script:Lv.Form.IsDisposed) { $script:Lv.Form.Activate(); return }
  $C = $script:C
  $v = New-Object System.Windows.Forms.Form
  $v.Text = '日志查看器 · 微信自动回复'
  $v.ClientSize = New-Object System.Drawing.Size((DPX 940), (DPX 600))
  $v.MinimumSize = New-Object System.Drawing.Size((DPX 640), (DPX 400))
  $v.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
  $v.BackColor = CC $C.Bg
  $v.ForeColor = CC $C.Text
  $v.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
  try { if ($script:IconPath) { $v.Icon = New-Object System.Drawing.Icon($script:IconPath, 32, 32) } } catch { }

  $top = New-Object System.Windows.Forms.Panel
  $top.Location = New-Object System.Drawing.Point(0, 0)
  $top.Size = New-Object System.Drawing.Size($v.ClientSize.Width, (DPX 46))
  $top.BackColor = CC $C.Header
  $top.Anchor = 'Top,Left,Right'
  $v.Controls.Add($top)

  function New-LvLabel([string]$Text, [int]$X, [int]$W) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Text
    $l.Location = New-Object System.Drawing.Point((DPX $X), (DPX 15))
    $l.Size = New-Object System.Drawing.Size((DPX $W), (DPX 18))
    $l.ForeColor = CC $C.Sub
    $l.BackColor = [System.Drawing.Color]::Transparent
    return $l
  }
  $top.Controls.Add((New-LvLabel '文件' 16 40))
  $top.Controls.Add((New-LvLabel '筛选' 286 40))
  $top.Controls.Add((New-LvLabel '行数' 546 40))

  $combo = New-Object System.Windows.Forms.ComboBox
  $combo.Location = New-Object System.Drawing.Point((DPX 58), (DPX 11))
  $combo.Size = New-Object System.Drawing.Size((DPX 216), (DPX 24))
  $combo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
  $combo.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
  $combo.BackColor = CC $C.Card
  $combo.ForeColor = CC $C.Text
  foreach ($n in (Get-LogFiles)) { [void]$combo.Items.Add($n) }
  if ($combo.Items.Count -gt 0) {
    $combo.SelectedIndex = 0
    # the bot's own log is what people usually want to see first
    for ($i = 0; $i -lt $combo.Items.Count; $i++) {
      if ([string]$combo.Items[$i] -eq 'watch.log') { $combo.SelectedIndex = $i; break }
    }
  }
  $top.Controls.Add($combo)

  $filter = New-Object System.Windows.Forms.TextBox
  $filter.Location = New-Object System.Drawing.Point((DPX 328), (DPX 12))
  $filter.Size = New-Object System.Drawing.Size((DPX 200), (DPX 24))
  $filter.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
  $filter.BackColor = CC $C.Card
  $filter.ForeColor = CC $C.Text
  $top.Controls.Add($filter)

  $count = New-Object System.Windows.Forms.ComboBox
  $count.Location = New-Object System.Drawing.Point((DPX 588), (DPX 11))
  $count.Size = New-Object System.Drawing.Size((DPX 104), (DPX 24))
  $count.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
  $count.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
  $count.BackColor = CC $C.Card
  $count.ForeColor = CC $C.Text
  foreach ($n in @('200 行', '500 行', '2000 行', '全部')) { [void]$count.Items.Add($n) }
  $count.SelectedIndex = 1
  $top.Controls.Add($count)

  $auto = New-Object System.Windows.Forms.CheckBox
  $auto.Text = '自动刷新'
  $auto.Location = New-Object System.Drawing.Point((DPX 706), (DPX 13))
  $auto.Size = New-Object System.Drawing.Size((DPX 104), (DPX 22))
  $auto.ForeColor = CC $C.Sub
  $auto.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
  $auto.Checked = $true
  $top.Controls.Add($auto)

  $btnRefresh = New-Object System.Windows.Forms.Button
  $btnRefresh.Text = '刷新'
  $btnRefresh.Location = New-Object System.Drawing.Point(($top.Width - (DPX 96)), (DPX 10))
  $btnRefresh.Size = New-Object System.Drawing.Size((DPX 80), (DPX 26))
  $btnRefresh.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
  $btnRefresh.FlatAppearance.BorderColor = CC $C.Border
  $btnRefresh.BackColor = CC $C.Hover
  $btnRefresh.ForeColor = CC $C.Text
  $btnRefresh.Anchor = 'Top,Right'
  $top.Controls.Add($btnRefresh)

  $box = New-Object System.Windows.Forms.TextBox
  $box.Multiline = $true
  $box.ReadOnly = $true
  $box.WordWrap = $false
  $box.ScrollBars = [System.Windows.Forms.ScrollBars]::Both
  $box.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
  $box.Location = New-Object System.Drawing.Point((DPX 12), (DPX 56))
  $box.Size = New-Object System.Drawing.Size(($v.ClientSize.Width - (DPX 24)), ($v.ClientSize.Height - (DPX 104)))
  $box.Anchor = 'Top,Bottom,Left,Right'
  $box.BackColor = CC $C.Card
  $box.ForeColor = CC $C.Text
  try { $box.Font = New-Object System.Drawing.Font('Consolas', 9) } catch { $box.Font = New-Object System.Drawing.Font('Courier New', 9) }
  $v.Controls.Add($box)

  $bottom = New-Object System.Windows.Forms.Panel
  $bottom.Location = New-Object System.Drawing.Point(0, ($v.ClientSize.Height - (DPX 42)))
  $bottom.Size = New-Object System.Drawing.Size($v.ClientSize.Width, (DPX 42))
  $bottom.BackColor = CC $C.Header
  $bottom.Anchor = 'Bottom,Left,Right'
  $v.Controls.Add($bottom)

  $status = New-Object System.Windows.Forms.Label
  $status.Text = ''
  $status.Location = New-Object System.Drawing.Point((DPX 14), (DPX 12))
  $status.Size = New-Object System.Drawing.Size((DPX 720), (DPX 20))
  $status.ForeColor = CC $C.Muted
  $status.BackColor = [System.Drawing.Color]::Transparent
  $status.Anchor = 'Bottom,Left'
  $bottom.Controls.Add($status)

  function New-LvButton([string]$Text, [int]$Right, [int]$W) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text
    $b.Size = New-Object System.Drawing.Size((DPX $W), (DPX 26))
    $b.Location = New-Object System.Drawing.Point(($bottom.Width - (DPX ($Right + $W))), (DPX 9))
    $b.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $b.FlatAppearance.BorderColor = CC $C.Border
    $b.BackColor = CC $C.Hover
    $b.ForeColor = CC $C.Text
    $b.Anchor = 'Bottom,Right'
    return $b
  }
  $btnClose = New-LvButton '关闭' 12 76
  $btnFolder = New-LvButton '打开文件夹' 96 104
  $btnNote = New-LvButton '记事本打开' 208 104
  $bottom.Controls.Add($btnClose)
  $bottom.Controls.Add($btnFolder)
  $bottom.Controls.Add($btnNote)

  $script:Lv.Form = $v
  $script:Lv.Box = $box
  $script:Lv.Combo = $combo
  $script:Lv.Filter = $filter
  $script:Lv.Count = $count
  $script:Lv.Auto = $auto
  $script:Lv.Status = $status
  $script:Lv.File = [string]$combo.SelectedItem

  $combo.Add_SelectedIndexChanged({
    $script:Lv.File = [string]$script:Lv.Combo.SelectedItem
    Update-LogView
  })
  $filter.Add_TextChanged({ Update-LogView })
  $filter.Add_KeyDown({
    param($s, $e)
    if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Escape) { $s.Text = '' }
  })
  $count.Add_SelectedIndexChanged({ Update-LogView })
  $auto.Add_CheckedChanged({
    if ($script:Lv.Auto.Checked) { $script:Lv.Timer.Start() } else { $script:Lv.Timer.Stop() }
    Update-LogView
  })
  $btnRefresh.Add_Click({ Update-LogView })
  $btnNote.Add_Click({ Start-Process -FilePath 'notepad.exe' -ArgumentList (Join-Path (Join-Path $script:Root 'logs') $script:Lv.File) | Out-Null })
  $btnFolder.Add_Click({ Start-Process -FilePath 'explorer.exe' -ArgumentList (Join-Path $script:Root 'logs') | Out-Null })
  $btnClose.Add_Click({ $script:Lv.Form.Close() })

  $timer = New-Object System.Windows.Forms.Timer
  $timer.Interval = 2000
  $timer.Add_Tick({ if ($script:Lv.Auto.Checked) { Update-LogView } })
  $script:Lv.Timer = $timer
  $timer.Start()

  $v.Add_Shown({
    try {
      if ($script:ThemeName -eq 'dark') {
        $one = 1
        [void][WxPanel.Native]::DwmSetWindowAttribute($script:Lv.Form.Handle, 20, [ref]$one, 4)
      }
    } catch { }
    Update-LogView
  })
  $v.Add_FormClosed({
    try { $script:Lv.Timer.Stop(); $script:Lv.Timer.Dispose() } catch { }
    $script:Lv.Form = $null
    $script:Lv.Box = $null
    $script:Lv.Timer = $null
  })
  $v.Show($script:Form)
}

# ------------------------------------------------------------------ notices
# Tray balloons for the things a user actually wants to hear about. The reply log
# is followed from the last offset, so nothing is replayed after a restart.
$script:NoticeOn = $true
$script:NoticePos = 0
$script:NoticeLastSent = [datetime]::MinValue
$script:NoticeLastWarn = [datetime]::MinValue
$script:NoticeLastWarnText = ''
$script:NotifiedRun = $null

function Get-NoticeSetting {
  try {
    $p = Join-Path $script:StateDir 'notify.txt'
    if (Test-Path -LiteralPath $p) { return ((Get-Content -LiteralPath $p -Raw).Trim() -ne 'off') }
  } catch { }
  return $true
}
function Set-NoticeEnabled([bool]$On) {
  $script:NoticeOn = $On
  try {
    $p = Join-Path $script:StateDir 'notify.txt'
    [System.IO.File]::WriteAllText($p, $(if ($On) { 'on' } else { 'off' }), (New-Object System.Text.ASCIIEncoding))
  } catch { }
}
function Show-Notice([string]$Title, [string]$Text, [string]$Kind) {
  try {
    if (-not $script:Tray) { return }
    if ($Text.Length -gt 120) { $Text = $Text.Substring(0, 120) + '…' }
    $icon = [System.Windows.Forms.ToolTipIcon]::Info
    if ($Kind -eq 'warn') { $icon = [System.Windows.Forms.ToolTipIcon]::Warning }
    $script:Tray.BalloonTipIcon = $icon
    $script:Tray.BalloonTipTitle = $Title
    $script:Tray.BalloonTipText = $Text
    $script:Tray.ShowBalloonTip(5000)
    Add-PanelLog ('notice: {0} - {1}' -f $Title, $Text)
  } catch { Add-PanelLog ('notice failed: {0}' -f $_.Exception.Message) }
}
function Get-NoticeFor([string]$line) {
  if ($line -match '\[BLOCKED\]\s*(.+)$') { return @{ Title = '发送被拦'; Text = $Matches[1].Trim(); Kind = 'warn' } }
  if ($line -match '\[DEFER\]\s*(.+)$') {
    $t = $Matches[1].Trim()
    $t = $t -replace '^send failed, queued for retry:\s*', ''
    return @{ Title = '发送失败，已排队重试'; Text = $t; Kind = 'warn' }
  }
  if ($line -match '\[GIVEUP\]\s*(.+)$') {
    $t = $Matches[1].Trim()
    return @{ Title = '这条没能发出去，已放弃'; Text = $t; Kind = 'warn' }
  }
  if ($line -match '\[SENT\]\s*(.+)$') { return @{ Title = '已发送'; Text = $Matches[1].Trim(); Kind = 'info' } }
  return $null
}
function Check-Notice {
  try {
    if (-not $script:NoticeOn) { return }
    if (-not $script:Tray) { return }
    $path = Join-Path $script:LogDir 'wx-reply-log.txt'
    if (-not (Test-Path -LiteralPath $path)) { return }
    $block = ''
    $fs = New-Object System.IO.FileStream($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
      $len = $fs.Length
      if ($script:NoticePos -le 0 -or $script:NoticePos -gt $len) { $script:NoticePos = $len; return }
      if ($len -le $script:NoticePos) { return }
      [void]$fs.Seek($script:NoticePos, [System.IO.SeekOrigin]::Begin)
      $take = [int][math]::Min([int64]65536, ($len - $script:NoticePos))
      $buf = New-Object byte[] $take
      $read = $fs.Read($buf, 0, $take)
      $text = [System.Text.Encoding]::UTF8.GetString($buf, 0, $read)
      $nl = $text.LastIndexOf("`n")
      if ($nl -lt 0) { return }
      $script:NoticePos = $script:NoticePos + [System.Text.Encoding]::UTF8.GetByteCount($text.Substring(0, $nl + 1))
      $block = $text.Substring(0, $nl)
    } finally { $fs.Dispose() }
    if (-not $block) { return }
    $shown = 0
    foreach ($ln in @($block -split "`r?`n")) {
      if ($shown -ge 3) { break }
      $n = Get-NoticeFor $ln
      if (-not $n) { continue }
      if ($n.Kind -eq 'info') {
        if (((Get-Date) - $script:NoticeLastSent).TotalSeconds -lt 20) { continue }
        $script:NoticeLastSent = Get-Date
      } else {
        if ($n.Text -eq $script:NoticeLastWarnText -and ((Get-Date) - $script:NoticeLastWarn).TotalSeconds -lt 60) { continue }
        $script:NoticeLastWarn = Get-Date
        $script:NoticeLastWarnText = $n.Text
      }
      Show-Notice $n.Title $n.Text $n.Kind
      $shown = $shown + 1
    }
  } catch { }
}

$script:NoticeOn = Get-NoticeSetting
if ($script:WantNoticeTest) {
  Show-Notice '微信自动回复' '气泡通知已开启：发送失败、被拦、引擎起停都会在这里提醒你' 'info'
  Start-Sleep -Milliseconds 900
  Show-Notice '测试通知' '这是一条测试气泡，几秒后会自动消失' 'warn'
}

# ------------------------------------------------------------------ contacts editor
# state\contacts.json is the shared store (wx-core.ps1 reads it for the watcher).
# Left: the list. Right: the selected contact with its two prompts. The window
# writes the whole file on 保存, so nothing is half-applied.
$script:Cv = @{ Form = $null; List = $null; Name = $null; Enabled = $null; Reply = $null; Pro = $null; Status = $null; Store = $null; Active = ''; OldName = '' }

function Get-ContactStore {
  $p = Join-Path $script:Root 'state\contacts.json'
  if (Test-Path -LiteralPath $p) {
    try {
      $d = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json
      if ($d -and $d.contacts) { return $d }
    } catch { }
  }
  $reply = ''
  $pro = ''
  $fp = Join-Path $script:Root 'reply-prompt-text.txt'
  if (Test-Path -LiteralPath $fp) { $reply = Get-Content -LiteralPath $fp -Raw -Encoding UTF8 }
  $fp = Join-Path $script:Root 'proactive-prompt-text.txt'
  if (Test-Path -LiteralPath $fp) { $pro = Get-Content -LiteralPath $fp -Raw -Encoding UTF8 }
  $c = [pscustomobject]@{ name = (Get-ActiveContactName); enabled = $true; replyPrompt = $reply; proactivePrompt = $pro }
  return [pscustomobject]@{ active = (Get-ActiveContactName); contacts = @($c) }
}

function ConvertTo-PanelJsonText {
  # ConvertTo-Json is unusable for prompt text here: PowerShell 5.1 renders a
  # multi-line string as { "value": .. }, which no other JSON reader understands.
  param([string]$s)
  if (-not $s) { return '""' }
  $sb = New-Object System.Text.StringBuilder
  foreach ($ch in $s.ToCharArray()) {
    $code = [int]$ch
    if ($ch -eq '"') { [void]$sb.Append('\"') }
    elseif ($ch -eq '\') { [void]$sb.Append('\\') }
    elseif ($ch -eq "`r") { [void]$sb.Append('\r') }
    elseif ($ch -eq "`n") { [void]$sb.Append('\n') }
    elseif ($ch -eq "`t") { [void]$sb.Append('\t') }
    elseif ($code -lt 32) { [void]$sb.Append(('\u{0:x4}' -f $code)) }
    else { [void]$sb.Append($ch) }
  }
  return ('"' + $sb.ToString() + '"')
}

function Save-ContactStore {
  param($Data)
  $p = Join-Path $script:Root 'state\contacts.json'
  $list = @($Data.contacts)
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.AppendLine('{')
  [void]$sb.AppendLine('  "active": ' + (ConvertTo-PanelJsonText ([string]$Data.active)) + ',')
  [void]$sb.AppendLine('  "contacts": [')
  for ($i = 0; $i -lt $list.Count; $i++) {
    $c = $list[$i]
    $en = 'false'
    if ($c.enabled) { $en = 'true' }
    [void]$sb.AppendLine('    {')
    [void]$sb.AppendLine('      "name": ' + (ConvertTo-PanelJsonText ([string]$c.name)) + ',')
    [void]$sb.AppendLine('      "enabled": ' + $en + ',')
    [void]$sb.AppendLine('      "replyPrompt": ' + (ConvertTo-PanelJsonText ([string]$c.replyPrompt)) + ',')
    [void]$sb.AppendLine('      "proactivePrompt": ' + (ConvertTo-PanelJsonText ([string]$c.proactivePrompt)))
    if ($i -lt ($list.Count - 1)) { [void]$sb.AppendLine('    },') } else { [void]$sb.AppendLine('    }') }
  }
  [void]$sb.AppendLine('  ]')
  [void]$sb.AppendLine('}')
  [System.IO.File]::WriteAllText($p, $sb.ToString(), (New-Object System.Text.UTF8Encoding($true)))
}

function Get-ContactLabel {
  param($Contact, [string]$Active)
  $mark = '○'
  if ($Contact.enabled) { $mark = '●' }
  $suffix = ''
  if ([string]$Contact.name -eq $Active) { $suffix = '   ← 当前' }
  return ('{0} {1}{2}' -f $mark, $Contact.name, $suffix)
}

function Set-ContactStatus {
  param([string]$Message)
  if (-not $script:Cv.Status) { return }
  $d = Get-ContactStore
  $script:Cv.Active = [string]$d.active
  $head = ('共 {0} 个联系人 · 当前回复 {1}' -f @($d.contacts).Count, $script:Cv.Active)
  if ($Message) { $script:Cv.Status.Text = ($head + ' · ' + $Message) } else { $script:Cv.Status.Text = $head }
}

function Refresh-ContactList {
  param([string]$Select)
  $d = Get-ContactStore
  $script:Cv.Store = $d
  $script:Cv.Active = [string]$d.active
  $script:Cv.List.Items.Clear()
  $idx = 0
  $i = 0
  foreach ($c in @($d.contacts)) {
    [void]$script:Cv.List.Items.Add((Get-ContactLabel $c $script:Cv.Active))
    if ($Select -and [string]$c.name -eq $Select) { $idx = $i }
    $i++
  }
  if ($script:Cv.List.Items.Count -gt 0) { $script:Cv.List.SelectedIndex = $idx }
  Set-ContactStatus ''
}

function Save-ContactForm {
  $d = Get-ContactStore
  $list = @($d.contacts)
  $i = $script:Cv.List.SelectedIndex
  if ($i -lt 0 -or $i -ge $list.Count) { Set-ContactStatus '请先在左边选一个联系人'; return }
  $name = $script:Cv.Name.Text.Trim()
  if (-not $name) { Set-ContactStatus '名字不能为空'; return }
  $dup = $false
  $j = 0
  foreach ($c in $list) { if ($j -ne $i -and [string]$c.name -eq $name) { $dup = $true }; $j++ }
  if ($dup) { Set-ContactStatus ('已经有叫 ' + $name + ' 的联系人了'); return }
  $list[$i].name = $name
  $list[$i].enabled = [bool]$script:Cv.Enabled.Checked
  $list[$i].replyPrompt = $script:Cv.Reply.Text
  $list[$i].proactivePrompt = $script:Cv.Pro.Text
  if ([string]$d.active -eq [string]$script:Cv.OldName) { $d.active = $name }
  $d.contacts = $list
  Save-ContactStore $d
  Refresh-ContactList $name
  Set-ContactStatus ('已保存 ' + $name)
}

function Add-Contact {
  $d = Get-ContactStore
  $list = @($d.contacts)
  $base = '新联系人'
  $name = $base
  $k = 2
  while (@($list | Where-Object { [string]$_.name -eq $name }).Count -gt 0) { $name = ($base + ' ' + $k); $k++ }
  $c = [pscustomobject]@{ name = $name; enabled = $true; replyPrompt = ''; proactivePrompt = '' }
  $d.contacts = @($list) + @($c)
  Save-ContactStore $d
  Refresh-ContactList $name
  Set-ContactStatus ('已新建 ' + $name + '，改好提示词后按保存')
}

function Delete-Contact {
  $d = Get-ContactStore
  $list = @($d.contacts)
  $i = $script:Cv.List.SelectedIndex
  if ($i -lt 0 -or $i -ge $list.Count) { Set-ContactStatus '请先在左边选一个联系人'; return }
  if ($list.Count -le 1) { Set-ContactStatus '至少要留一个联系人'; return }
  $name = [string]$list[$i].name
  $keep = @()
  $j = 0
  foreach ($c in $list) { if ($j -ne $i) { $keep += $c }; $j++ }
  $d.contacts = $keep
  if ([string]$d.active -eq $name) { $d.active = [string]$keep[0].name }
  Save-ContactStore $d
  Refresh-ContactList ''
  Set-ContactStatus ('已删除 ' + $name)
}

function Make-ContactActive {
  $d = Get-ContactStore
  $list = @($d.contacts)
  $i = $script:Cv.List.SelectedIndex
  if ($i -lt 0 -or $i -ge $list.Count) { Set-ContactStatus '请先在左边选一个联系人'; return }
  $name = [string]$list[$i].name
  $list[$i].enabled = $true
  $d.contacts = $list
  $d.active = $name
  Save-ContactStore $d
  Refresh-ContactList $name
  Set-ContactStatus ('现在回复 ' + $name)
}

function Show-ContactsViewer {
  if ($script:Cv.Form -and -not $script:Cv.Form.IsDisposed) { $script:Cv.Form.Activate(); return }
  $f = New-Object System.Windows.Forms.Form
  $f.Text = '联系人 · 微信自动回复'
  $f.ClientSize = New-Object System.Drawing.Size((DPX 860), (DPX 560))
  $f.MinimumSize = New-Object System.Drawing.Size((DPX 700), (DPX 480))
  $f.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
  $f.BackColor = CC $script:C.Bg
  $f.ForeColor = CC $script:C.Text
  $f.Font = New-UiFont 9 ([System.Drawing.FontStyle]::Regular)
  try { $f.Icon = New-Object System.Drawing.Icon($script:IconPath, 16, 16) } catch { }

  $lb = New-Object System.Windows.Forms.ListBox
  $lb.Location = New-Object System.Drawing.Point((DPX 12), (DPX 12))
  $lb.Size = New-Object System.Drawing.Size((DPX 236), (DPX 492))
  $lb.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Bottom
  $lb.BackColor = CC $script:C.Card
  $lb.ForeColor = CC $script:C.Text
  $lb.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
  $lb.Font = New-UiFont 9.5 ([System.Drawing.FontStyle]::Regular)
  $lb.IntegralHeight = $false

  $lblName = New-UiLabel -Parent $f -Text '名字' -X 264 -Y 12 -W 80 -H 20 -Size 9 -Bold $false -Color $script:C.Muted -Bg $script:C.Bg -Align 'MiddleLeft'
  $tbName = New-Object System.Windows.Forms.TextBox
  $tbName.Location = New-Object System.Drawing.Point((DPX 264), (DPX 34))
  $tbName.Size = New-Object System.Drawing.Size((DPX 300), (DPX 26))
  $tbName.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left
  $tbName.BackColor = CC $script:C.Card
  $tbName.ForeColor = CC $script:C.Text
  $tbName.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
  $tbName.Font = New-UiFont 9.5 ([System.Drawing.FontStyle]::Regular)

  $ckOn = New-Object System.Windows.Forms.CheckBox
  $ckOn.Text = '启用（关掉就不回复这个人）'
  $ckOn.Location = New-Object System.Drawing.Point((DPX 578), (DPX 36))
  $ckOn.Size = New-Object System.Drawing.Size((DPX 270), (DPX 24))
  $ckOn.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left
  $ckOn.ForeColor = CC $script:C.Sub
  $ckOn.BackColor = CC $script:C.Bg
  $ckOn.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
  $ckOn.Font = New-UiFont 9 ([System.Drawing.FontStyle]::Regular)

  $lblReply = New-UiLabel -Parent $f -Text '回复提示词（收到消息时用）' -X 264 -Y 70 -W 320 -H 20 -Size 9 -Bold $false -Color $script:C.Muted -Bg $script:C.Bg -Align 'MiddleLeft'
  $tbReply = New-Object System.Windows.Forms.TextBox
  $tbReply.Location = New-Object System.Drawing.Point((DPX 264), (DPX 92))
  $tbReply.Size = New-Object System.Drawing.Size((DPX 584), (DPX 176))
  $tbReply.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
  $tbReply.Multiline = $true
  $tbReply.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
  $tbReply.AcceptsReturn = $true
  $tbReply.WordWrap = $true
  $tbReply.BackColor = CC $script:C.Card
  $tbReply.ForeColor = CC $script:C.Text
  $tbReply.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
  $tbReply.Font = New-UiFont 9.5 ([System.Drawing.FontStyle]::Regular)

  $lblPro = New-UiLabel -Parent $f -Text '主动搭话提示词（长时间没动静时用）' -X 264 -Y 278 -W 400 -H 20 -Size 9 -Bold $false -Color $script:C.Muted -Bg $script:C.Bg -Align 'MiddleLeft'
  $tbPro = New-Object System.Windows.Forms.TextBox
  $tbPro.Location = New-Object System.Drawing.Point((DPX 264), (DPX 300))
  $tbPro.Size = New-Object System.Drawing.Size((DPX 584), (DPX 150))
  $tbPro.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
  $tbPro.Multiline = $true
  $tbPro.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
  $tbPro.AcceptsReturn = $true
  $tbPro.WordWrap = $true
  $tbPro.BackColor = CC $script:C.Card
  $tbPro.ForeColor = CC $script:C.Text
  $tbPro.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
  $tbPro.Font = New-UiFont 9.5 ([System.Drawing.FontStyle]::Regular)

  $status = New-Object System.Windows.Forms.Label
  $status.Location = New-Object System.Drawing.Point((DPX 14), (DPX 522))
  $status.Size = New-Object System.Drawing.Size((DPX 400), (DPX 22))
  $status.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
  $status.ForeColor = CC $script:C.Muted
  $status.BackColor = [System.Drawing.Color]::Transparent
  $status.Text = ''

  $btnSave = New-FlatButton -Text '保存' -X 430 -Y 516 -W 74 -H 30 -Name 'contacts-save' `
    -Bg '#FFFFFF' -Fg $script:C.Sub -HoverBg $script:C.Hover -PressBg '#EAEDF1' -Line $script:C.Border `
    -Radius 9 -Size 9 -Bold $false
  $btnNew = New-FlatButton -Text '新建' -X 512 -Y 516 -W 74 -H 30 -Name 'contacts-new' `
    -Bg '#FFFFFF' -Fg $script:C.Sub -HoverBg $script:C.Hover -PressBg '#EAEDF1' -Line $script:C.Border `
    -Radius 9 -Size 9 -Bold $false
  $btnDel = New-FlatButton -Text '删除' -X 594 -Y 516 -W 74 -H 30 -Name 'contacts-del' `
    -Bg '#FFFFFF' -Fg $script:C.Sub -HoverBg $script:C.Hover -PressBg '#EAEDF1' -Line $script:C.Border `
    -Radius 9 -Size 9 -Bold $false
  $btnAct = New-FlatButton -Text '设为当前' -X 676 -Y 516 -W 100 -H 30 -Name 'contacts-active' `
    -Bg '#FFFFFF' -Fg $script:C.Sub -HoverBg $script:C.Hover -PressBg '#EAEDF1' -Line $script:C.Border `
    -Radius 9 -Size 9 -Bold $false
  $btnCl = New-FlatButton -Text '关闭' -X 784 -Y 516 -W 64 -H 30 -Name 'contacts-close' `
    -Bg '#FFFFFF' -Fg $script:C.Sub -HoverBg $script:C.Hover -PressBg '#EAEDF1' -Line $script:C.Border `
    -Radius 9 -Size 9 -Bold $false
  foreach ($b in @($btnSave, $btnNew, $btnDel, $btnAct, $btnCl)) {
    $b.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
  }

  $f.Controls.Add($lb)
  $f.Controls.Add($tbName)
  $f.Controls.Add($ckOn)
  $f.Controls.Add($tbReply)
  $f.Controls.Add($tbPro)
  $f.Controls.Add($status)
  $f.Controls.Add($btnSave)
  $f.Controls.Add($btnNew)
  $f.Controls.Add($btnDel)
  $f.Controls.Add($btnAct)
  $f.Controls.Add($btnCl)

  $lb.Add_SelectedIndexChanged({
    $i = $script:Cv.List.SelectedIndex
    $d = Get-ContactStore
    $list = @($d.contacts)
    if ($i -ge 0 -and $i -lt $list.Count) {
      $script:Cv.OldName = [string]$list[$i].name
      $script:Cv.Name.Text = [string]$list[$i].name
      $script:Cv.Enabled.Checked = [bool]$list[$i].enabled
      $script:Cv.Reply.Text = [string]$list[$i].replyPrompt
      $script:Cv.Pro.Text = [string]$list[$i].proactivePrompt
    }
  })
  $f.Add_Shown({
    try {
      if ($script:ThemeName -eq 'dark') {
        $one = 1
        [void][WxPanel.Native]::DwmSetWindowAttribute($script:Cv.Form.Handle, 20, [ref]$one, 4)
      }
    } catch { }
  })
  $f.Add_FormClosed({
    $script:Cv.Form = $null
    try { $script:ForceStyle = $true; Update-Panel } catch { }
  })

  $script:Cv.Form = $f
  $script:Cv.List = $lb
  $script:Cv.Name = $tbName
  $script:Cv.Enabled = $ckOn
  $script:Cv.Reply = $tbReply
  $script:Cv.Pro = $tbPro
  $script:Cv.Status = $status
  Refresh-ContactList ''
  try { [void][WxPanel.Win]::SetForegroundWindow($f.Handle) } catch { }
  $f.Show($script:Form)
  $f.BringToFront()
}
function Update-Panel {
  try {
    $i = Get-AutoInfo
    $run = [bool]$i.Running
    $script:Ui.PillText.Text = $(if ($run) { '运行中' } else { '已停止' })
    $script:Ui.Pill.PillOn = $run
    $pillBg = $script:C.Line
    $pillFg = $script:C.Sub
    if ($run) { $pillBg = $script:C.AccentLow; $pillFg = $script:C.AccentOn }
    $script:Ui.Pill.BackColor = CC $pillBg
    $script:Ui.PillText.BackColor = CC $pillBg
    $script:Ui.PillText.ForeColor = CC $pillFg
    $script:Ui.Pill.Invalidate()
    $script:Ui.PillText.Invalidate()
    $script:Ui.Strip.BackColor = $(if ($run) { CC $script:C.Accent } else { CC $script:C.Track })
    $script:Ui.Rounds.Text = '轮次 ' + ([int]$i.Rounds).ToString('N0')

    $script:Ui.Mode.Text = $(if ($i.Mode -eq 'live') { '真实发送（live）' } else { '只造草稿（dryrun）' })
    $script:Ui.Proc.Text = $(if ($run) { '运行中　pid ' + $i.Pids } else { '未运行' })
    $script:Ui.Today.Text = ('' + $i.Today + ' 条（其中主动 ' + $i.Proactive + '）')
    $script:Ui.Queue.Text = ('' + $i.Queue + ' 条')
    $script:Ui.Action.Text = $i.ActionText
    $last = '—'
    if ($i.Last) { $last = $i.Last }
    if ($last.Length -gt 40) { $last = $last.Substring(0, 40) + '…' }
    $script:Ui.Last.Text = $last

    if ($script:ForceStyle -or ($script:LastRunning -ne $run)) {
      $script:ForceStyle = $false
      $script:LastRunning = $run
      if ($null -eq $script:NotifiedRun) { $script:NotifiedRun = $run }
      elseif ($script:NotifiedRun -ne $run) {
        $script:NotifiedRun = $run
        if ($run) { Show-Notice '自动回复已启动' '后台进程开始监听微信消息' 'info' }
        else { Show-Notice '自动回复已停止' '后台进程已退出，发送与重试都停了下来' 'info' }
      }
      if ($run) {
        $script:Ui.Primary.BtnText = '停止'
        $script:Ui.Primary.BtnFill = $script:C.Danger
        $script:Ui.Primary.BtnHover = $script:C.DangerHi
        $script:Ui.Primary.BtnPress = '#C81E1E'
      } else {
        $script:Ui.Primary.BtnText = '启动'
        $script:Ui.Primary.BtnFill = $script:C.Accent
        $script:Ui.Primary.BtnHover = $script:C.AccentHi
        $script:Ui.Primary.BtnPress = '#04984C'
      }
      $script:Ui.Primary.Invalidate()
    }

    $wantDry = ($i.Mode -ne 'live')
    if ($script:Ui.TgDry.Checked -ne $wantDry) {
      $script:Ui.TgDry.Checked = $wantDry
      $script:Ui.TgDry.Knob = $(if ($wantDry) { [single](19.5 * $script:DpiScale) } else { [single](2.5 * $script:DpiScale) })
      $script:Ui.TgDry.Invalidate()
    }
    $wantTop = [bool]$script:Form.TopMost
    if ($script:Ui.TgTop.Checked -ne $wantTop) {
      $script:Ui.TgTop.Checked = $wantTop
      $script:Ui.TgTop.Knob = $(if ($wantTop) { [single](19.5 * $script:DpiScale) } else { [single](2.5 * $script:DpiScale) })
      $script:Ui.TgTop.Invalidate()
    }
    $wantAuto = Test-AutoStart
    if ($script:Ui.TgAuto.Checked -ne $wantAuto) {
      $script:Ui.TgAuto.Checked = $wantAuto
      $script:Ui.TgAuto.Knob = $(if ($wantAuto) { [single](19.5 * $script:DpiScale) } else { [single](2.5 * $script:DpiScale) })
      $script:Ui.TgAuto.Invalidate()
    }
    $wantTheme = ($script:ThemeName -eq 'dark')
    if ($script:Ui.TgTheme.Checked -ne $wantTheme) {
      $script:Ui.TgTheme.Checked = $wantTheme
      $script:Ui.TgTheme.Knob = $(if ($wantTheme) { [single](19.5 * $script:DpiScale) } else { [single](2.5 * $script:DpiScale) })
      $script:Ui.TgTheme.Invalidate()
    }
    if ($lblSub) { $lblSub.Text = (Get-ActiveContactName) + ' · 会话自动应答' }
    if ($script:TrayMenu) {
      $script:TrayMenu.Run.Text = $(if ($run) { '停止自动回复' } else { '启动自动回复' })
      $script:TrayMenu.Auto.Checked = $wantAuto
      $script:TrayMenu.Notify.Checked = $script:NoticeOn
    }
  } catch { }
}

# switch animation: ease the knob towards its target while it moves
$script:AnimTimer = New-Object System.Windows.Forms.Timer
$script:AnimTimer.Interval = 16
$script:AnimTimer.Add_Tick({
  $busy = $false
  foreach ($t in @($script:Ui.TgDry, $script:Ui.TgTop)) {
    if (-not $t) { continue }
    $target = [single]2.5
    if ($t.Checked) { $target = [single]19.5 }
    $delta = $target - $t.Knob
    if ([Math]::Abs($delta) -gt 0.5) {
      $t.Knob = $t.Knob + ($delta * 0.35)
      $t.Invalidate()
      $busy = $true
    } elseif ($t.Knob -ne $target) {
      $t.Knob = $target
      $t.Invalidate()
    }
  }
  if (-not $busy) { $script:AnimTimer.Stop() }
})

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 2500
$timer.Add_Tick({ Update-Panel; Check-Notice })
$timer.Start()

# -------------------------------------------------------- drag self-test hook
if ($SelfTest) {
  $priv = [System.Reflection.BindingFlags]'NonPublic,Instance,Static'
  $evField = [System.ComponentModel.Component].GetField('events', [System.Reflection.BindingFlags]'NonPublic,Instance')
  if (-not $evField) { $evField = [System.ComponentModel.Component].GetField('Events', [System.Reflection.BindingFlags]'NonPublic,Instance') }
  $keyDown = [System.Windows.Forms.Control].GetField('EventMouseDown', $priv).GetValue($null)
  $script:SelfOut = @()
  function Test-DragSurface([System.Windows.Forms.Control]$C) {
    $wired = $false
    if ($evField) { $list = $evField.GetValue($C) }
    else { $list = $null }
    if ($list -and $list[$keyDown]) { $wired = $true }
    $label = $C.Name
    if (-not $label) { $label = $C.Text }
    if (-not $label) { $label = '-' }
    if ($label.Length -gt 22) { $label = $label.Substring(0, 22) }
    $script:SelfOut += ('{0,-12} {1,-24} {2}' -f $C.GetType().Name, $label, $(if ($wired) { 'drag-ok' } else { 'fixed' }))
    foreach ($ch in $C.Controls) { Test-DragSurface $ch }
  }
  Test-DragSurface $script:Form
  $ok = @($script:SelfOut | Where-Object { $_ -like '*drag-ok' }).Count
  $fixed = @($script:SelfOut | Where-Object { $_ -like '*fixed' }).Count
  Write-Output ('drag self-test: {0} draggable, {1} fixed' -f $ok, $fixed)
  $script:SelfOut | ForEach-Object { Write-Output ('  ' + $_) }
  Write-Output 'notice classification self-test:'
  foreach ($line in @(
      '2026-10-06 00:10:00 [SENT] 测试发送内容',
      '2026-10-06 00:10:01 [BLOCKED] hourly cap: 36 sends (>= 30)',
      '2026-10-06 00:10:02 [DEFER] send failed, queued for retry: "测试重试"',
      '2026-10-06 00:10:03 [DRYRUN] inbound="x" draft="y"',
      '2026-10-06 00:10:04 [INFO] AllowRepeat: this line is meant to repeat'
    )) {
    $n = Get-NoticeFor $line
    if ($n) { Write-Output ('  {0,-6} {1} :: {2}' -f $n.Kind, $n.Title, $n.Text) }
    else { Write-Output ('  ignored ' + $line) }
  }
  $trayState = 'missing'
  if ($script:Tray) { $trayState = ('visible={0} text="{1}"' -f $script:Tray.Visible, $script:Tray.Text) }
  Write-Output ('tray self-test: {0}' -f $trayState)
  Write-Output ('notice setting self-test: on={0} pos={1}' -f $script:NoticeOn, $script:NoticePos)
  exit 0
}

# ------------------------------------------- command-line shortcuts (testing)
if ($StartBot -or $StopBot -or $StatusLine) {
  if ($StartBot) {
    if (Start-Auto) { Write-Output 'started' } else { Write-Output 'already running' }
  }
  if ($StopBot) { Write-Output (Stop-Auto) }
  if ($StatusLine) { Write-Output (Get-StatusText) }
  exit 0
}

Update-Panel

if ($Shot) {
  $path = if ($ShotPath) { $ShotPath } else { Join-Path $script:Root 'shots\panel.png' }
  $dir = Split-Path -Parent $path
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  # DrawToBitmap only paints real, created child controls, so the window has to
  # be shown for a moment; it closes itself straight after the capture.
  $script:Form.Show()
  [System.Windows.Forms.Application]::DoEvents()
  Start-Sleep -Milliseconds 400
  [System.Windows.Forms.Application]::DoEvents()
  $bmp = New-Object System.Drawing.Bitmap($script:Form.Width, $script:Form.Height)
  $script:Form.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, $script:Form.Width, $script:Form.Height)))
  $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
  $bmp.Dispose()
  Write-Output ("shot: {0}" -f $path)
  $script:Form.Close()
  exit 0
}

[void]$script:Form.ShowDialog()
$timer.Stop()
