#requires -version 5.1
<#
  winio.ps1 -- minimal, dependency-free window I/O toolkit for driving chat clients.

  Why this exists: on this machine the UIA tree is effectively HWND-level only
  (RootElement descendants across the whole desktop = 25; a Chromium window reports 0
  descendants), so classic "find control by AutomationId" automation is not available.
  Everything here therefore uses plain Win32 + screen capture, which was verified to work:
    - foreground / focus stealing across processes        PASS
    - clipboard + Ctrl+V text injection                   PASS
    - direct SendKeys typing                              PASS
    - synthetic mouse click (SetCursorPos + mouse_event)  PASS
    - window capture via CopyFromScreen and PrintWindow    PASS

  Dot-source it:  . '.\winio.ps1'

  Chinese text MUST go through the clipboard + Ctrl+V path; SendKeys cannot type CJK.
#>

if (-not ('DshWin.Native' -as [type])) {
  Add-Type -Namespace DshWin -Name Native -MemberDefinition @'
[System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
[System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
public struct POINT { public int X; public int Y; }

[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern System.IntPtr GetForegroundWindow();
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr hWnd);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr hWnd, int nCmdShow);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool IsIconic(System.IntPtr hWnd);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool CloseWindow(System.IntPtr hWnd);   // despite the name: minimises the window, without activating it
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool BringWindowToTop(System.IntPtr hWnd);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool GetWindowRect(System.IntPtr hWnd, out RECT lpRect);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool GetClientRect(System.IntPtr hWnd, out RECT lpRect);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool ClientToScreen(System.IntPtr hWnd, ref POINT lpPoint);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool PrintWindow(System.IntPtr hWnd, System.IntPtr hdcBlt, uint nFlags);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetCursorPos(int X, int Y);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern void mouse_event(uint dwFlags, uint dx, uint dy, uint dwData, System.IntPtr dwExtraInfo);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(System.IntPtr hWnd, out uint pid);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern System.IntPtr SetFocus(System.IntPtr hWnd);
[System.Runtime.InteropServices.DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Auto)] public static extern int GetClassName(System.IntPtr hWnd, System.Text.StringBuilder lpClassName, int nMaxCount);
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Auto)] public static extern int GetWindowText(System.IntPtr hWnd, System.Text.StringBuilder lpString, int nMaxCount);
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Auto)] public static extern System.IntPtr SendMessage(System.IntPtr hWnd, uint msg, System.IntPtr wParam, System.Text.StringBuilder lParam);
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Auto)] public static extern System.IntPtr SendMessage(System.IntPtr hWnd, uint msg, System.IntPtr wParam, System.IntPtr lParam);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern int GetSystemMetrics(int nIndex);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT lpPoint);
'@
}

# CRITICAL: become DPI-aware BEFORE any coordinate work.
# This machine is 2880x1800 physical / 1440x900 logical (200% scaling). While the process
# is DPI-unaware, GetWindowRect returns VIRTUALIZED (logical) pixels but CopyFromScreen,
# SetCursorPos and UIA bounding rectangles work in PHYSICAL pixels. Mixing the two shifted
# every capture by exactly the scale factor (WeChat at logical 82,90 appeared at image
# offset 82,90 inside an 893x647 shot instead of filling a 1786x1293 one).
$script:DshDpiAware = $false
try { $script:DshDpiAware = [DshWin.Native]::SetProcessDPIAware() } catch { }

if (-not ('System.Windows.Automation.AutomationElement' -as [type])) {
  Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
}
Add-Type -AssemblyName System.Drawing, System.Windows.Forms

$script:DshWin = @{
  WM_GETTEXT       = 0x000D
  WM_GETTEXTLENGTH = 0x000E
  WM_SETTEXT       = 0x000C
  MOUSEEVENTF_LEFTDOWN  = 0x0002
  MOUSEEVENTF_LEFTUP    = 0x0004
  MOUSEEVENTF_RIGHTDOWN = 0x0008
  MOUSEEVENTF_RIGHTUP   = 0x0010
  SW_RESTORE = 9
}

# ---------------------------------------------------------------- window lookup
function Get-DshWindow {
  <#  Returns top-level window descriptors. Title/process filtering is optional.
      Uses UIA child enumeration of the desktop (works here) rather than
      Get-Process MainWindowTitle (which returned empty for every process). #>
  param(
    [string]$TitleLike,
    [string]$ClassLike,
    [string]$ProcessName
  )
  $AE = [System.Windows.Automation.AutomationElement]
  $wins = $AE::RootElement.FindAll([System.Windows.Automation.TreeScope]::Children,
                                   [System.Windows.Automation.Condition]::TrueCondition)
  $out = @()
  foreach ($w in $wins) {
    # NOTE: $pid is a read-only automatic variable in PowerShell -- never assign to it.
    # UIA's own ProcessId is used first: it is reliable here, whereas a [ref] into
    # GetWindowThreadProcessId's `out uint` silently fails when the local is an Int32.
    $hwnd = [IntPtr]$w.Current.NativeWindowHandle
    if ($hwnd -eq [IntPtr]::Zero) { continue }
    $procId = 0
    try { $procId = [int]$w.Current.ProcessId } catch { }
    if ($procId -le 0) {
      [uint32]$outProc = 0
      try { [void][DshWin.Native]::GetWindowThreadProcessId($hwnd, [ref]$outProc); $procId = [int]$outProc } catch { }
    }
    $title = ''
    try { $title = [string]$w.Current.Name } catch { }
    $cls = ''
    try { $cls = [string]$w.Current.ClassName } catch { }
    $pname = ''
    try { $pname = (Get-Process -Id $procId -ErrorAction Stop).ProcessName } catch { }
    if ($TitleLike   -and $title -notlike $TitleLike) { continue }
    if ($ClassLike   -and $cls   -notlike $ClassLike) { continue }
    if ($ProcessName -and $pname -ne $ProcessName)    { continue }
    $out += [pscustomobject]@{ Hwnd = $hwnd; Pid = $procId; Title = $title; Class = $cls; Process = $pname }
  }
  return $out
}

function Get-DshWindowRect {
  param([IntPtr]$Hwnd)
  $rc = New-Object DshWin.Native+RECT
  if (-not [DshWin.Native]::GetWindowRect($Hwnd, [ref]$rc)) { return $null }
  return [pscustomobject]@{
    Left = $rc.Left; Top = $rc.Top; Right = $rc.Right; Bottom = $rc.Bottom
    Width = $rc.Right - $rc.Left; Height = $rc.Bottom - $rc.Top
  }
}

function Get-DshClientRect {
  param([IntPtr]$Hwnd)
  $rc = New-Object DshWin.Native+RECT
  if (-not [DshWin.Native]::GetClientRect($Hwnd, [ref]$rc)) { return $null }
  $pt = New-Object DshWin.Native+POINT
  $pt.X = 0; $pt.Y = 0
  [void][DshWin.Native]::ClientToScreen($Hwnd, [ref]$pt)
  return [pscustomobject]@{
    ScreenX = $pt.X; ScreenY = $pt.Y
    Width = $rc.Right - $rc.Left; Height = $rc.Bottom - $rc.Top
  }
}

# ---------------------------------------------------------------- focus
function Set-DshForeground {
  param([IntPtr]$Hwnd, [int]$Retries = 5)
  for ($i = 0; $i -lt $Retries; $i++) {
    if ([DshWin.Native]::IsIconic($Hwnd)) { [void][DshWin.Native]::ShowWindow($Hwnd, $script:DshWin.SW_RESTORE) }
    else { [void][DshWin.Native]::ShowWindow($Hwnd, $script:DshWin.SW_RESTORE) }
    [void][DshWin.Native]::BringWindowToTop($Hwnd)
    [void][DshWin.Native]::SetForegroundWindow($Hwnd)
    Start-Sleep -Milliseconds 250
    if ([DshWin.Native]::GetForegroundWindow() -eq $Hwnd) { return $true }
    # Windows blocks background processes from stealing focus; AttachThreadInput bypasses it.
    $fg = [DshWin.Native]::GetForegroundWindow()
    $fpid = 0
    $tOther = [DshWin.Native]::GetWindowThreadProcessId($fg, [ref]$fpid)
    $tMe = [DshWin.Native]::GetCurrentThreadId()
    [void][DshWin.Native]::AttachThreadInput($tMe, $tOther, $true)
    [void][DshWin.Native]::SetForegroundWindow($Hwnd)
    [void][DshWin.Native]::AttachThreadInput($tMe, $tOther, $false)
    Start-Sleep -Milliseconds 300
    if ([DshWin.Native]::GetForegroundWindow() -eq $Hwnd) { return $true }
  }
  return $false
}

function Set-DshFocusHwnd {
  param([IntPtr]$Hwnd, [IntPtr]$TopHwnd)
  $procId = 0
  $tTarget = [DshWin.Native]::GetWindowThreadProcessId($TopHwnd, [ref]$procId)
  $tMe = [DshWin.Native]::GetCurrentThreadId()
  $ok = $false
  try {
    [void][DshWin.Native]::AttachThreadInput($tMe, $tTarget, $true)
    [void][DshWin.Native]::SetFocus($Hwnd)
    [void][DshWin.Native]::AttachThreadInput($tMe, $tTarget, $false)
    $ok = $true
  } catch { }
  Start-Sleep -Milliseconds 200
  return $ok
}

# ---------------------------------------------------------------- capture
function Save-DshWindowCapture {
  <#  Method 'Screen' captures what is really on screen (foreground the window first).
      Method 'PrintWindow' asks the window to render itself; works even when occluded,
      and is the only usable path for a minimised/covered window. #>
  param(
    [IntPtr]$Hwnd,
    [string]$OutFile,
    [ValidateSet('Screen', 'PrintWindow')][string]$Method = 'Screen',
    [int]$Pad = 0
  )
  $rc = Get-DshWindowRect -Hwnd $Hwnd
  if ($rc -eq $null -or $rc.Width -le 0 -or $rc.Height -le 0) { throw 'window rect unavailable' }
  $bmp = New-Object System.Drawing.Bitmap($rc.Width, $rc.Height)
  if ($Method -eq 'Screen') {
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($rc.Left, $rc.Top, 0, 0, (New-Object System.Drawing.Size($rc.Width, $rc.Height)))
    $g.Dispose()
  } else {
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $hdc = $g.GetHdc()
    $ok = [DshWin.Native]::PrintWindow($Hwnd, $hdc, 2)   # PW_RENDERFULLCONTENT
    $g.ReleaseHdc($hdc)
    $g.Dispose()
    if (-not $ok) { Write-Warning 'PrintWindow returned false' }
  }
  $dir = Split-Path -Parent $OutFile
  if ($dir -and -not (Test-Path $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
  $bmp.Save($OutFile, [System.Drawing.Imaging.ImageFormat]::Png)
  $bmp.Dispose()
  return (Get-Item $OutFile)
}

function Save-DshScreenRegion {
  param([int]$X, [int]$Y, [int]$Width, [int]$Height, [string]$OutFile)
  $bmp = New-Object System.Drawing.Bitmap($Width, $Height)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen($X, $Y, 0, 0, (New-Object System.Drawing.Size($Width, $Height)))
  $g.Dispose()
  $bmp.Save($OutFile, [System.Drawing.Imaging.ImageFormat]::Png)
  $bmp.Dispose()
  return (Get-Item $OutFile)
}

# ---------------------------------------------------------------- input
function Invoke-DshClick {
  <#  Clicks at screen coordinates. Coordinates are absolute screen pixels. #>
  param(
    [int]$X,
    [int]$Y,
    [ValidateSet('Left', 'Right')][string]$Button = 'Left',
    [int]$DelayMs = 60
  )
  [void][DshWin.Native]::SetCursorPos($X, $Y)
  Start-Sleep -Milliseconds 200
  $down = if ($Button -eq 'Left') { $script:DshWin.MOUSEEVENTF_LEFTDOWN } else { $script:DshWin.MOUSEEVENTF_RIGHTDOWN }
  $up   = if ($Button -eq 'Left') { $script:DshWin.MOUSEEVENTF_LEFTUP }   else { $script:DshWin.MOUSEEVENTF_RIGHTUP }
  [DshWin.Native]::mouse_event([uint32]$down, 0, 0, 0, [IntPtr]::Zero)
  Start-Sleep -Milliseconds $DelayMs
  [DshWin.Native]::mouse_event([uint32]$up, 0, 0, 0, [IntPtr]::Zero)
  Start-Sleep -Milliseconds 250
}

function Invoke-DshClickClient {
  <#  Clicks at client-area coordinates of a window (0,0 = top-left of client area). #>
  param([IntPtr]$Hwnd, [int]$ClientX, [int]$ClientY, [ValidateSet('Left', 'Right')][string]$Button = 'Left')
  $c = Get-DshClientRect -Hwnd $Hwnd
  if ($c -eq $null) { throw 'client rect unavailable' }
  Invoke-DshClick -X ($c.ScreenX + $ClientX) -Y ($c.ScreenY + $ClientY) -Button $Button
}

function Send-DshKeys {
  param([string]$Keys, [int]$DelayMs = 150)
  if ($DelayMs -gt 0) { Start-Sleep -Milliseconds $DelayMs }
  [System.Windows.Forms.SendKeys]::SendWait($Keys)
}

function Set-DshClipboardText {
  param([string]$Text)
  Set-Clipboard -Value $Text
  Start-Sleep -Milliseconds 200
}

function Send-DshText {
  <#  Types arbitrary text (including CJK) by putting it on the clipboard and pasting.
      The target input must already have keyboard focus.
      ASCII fast path uses direct SendKeys when -PreferKeys is given (more reliable for
      short tokens; the clipboard path is the default because it handles CJK and avoids
      per-character IME interference). #>
  param(
    [string]$Text,
    [switch]$PreferKeys,
    [int]$SettleMs = 700
  )
  if ($PreferKeys -and $Text -match '^[\x20-\x7E]*$') {
    [System.Windows.Forms.SendKeys]::SendWait($Text)
  } else {
    Set-DshClipboardText -Text $Text
    [System.Windows.Forms.SendKeys]::SendWait('^v')
  }
  Start-Sleep -Milliseconds $SettleMs
}

function Send-DshEnter {
  param([int]$SettleMs = 600)
  [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
  Start-Sleep -Milliseconds $SettleMs
}

# ---------------------------------------------------------------- raw control text
function Get-DshControlText {
  <#  Straight WM_GETTEXT read. Only works for real HWND-backed controls; the
      WeChat/Chromium UI has no such child HWNDs, so this is a diagnostic only. #>
  param([IntPtr]$Hwnd)
  try {
    $len = [int][DshWin.Native]::SendMessage($Hwnd, $script:DshWin.WM_GETTEXTLENGTH, [IntPtr]::Zero, [IntPtr]::Zero)
    if ($len -le 0) { return '' }
    $sb = New-Object System.Text.StringBuilder ($len + 2)
    [void][DshWin.Native]::SendMessage($Hwnd, $script:DshWin.WM_GETTEXT, [IntPtr]($len + 2), $sb)
    return $sb.ToString()
  } catch { return '' }
}

# ---------------------------------------------------------------- UIA diagnostics
function Get-DshUiaTree {
  <#  Read-only UIA dump. Expected to be very shallow on this machine. #>
  param(
    [IntPtr]$Hwnd,
    [int]$MaxDepth = 4,
    [int]$MaxNodes = 200
  )
  $AE = [System.Windows.Automation.AutomationElement]
  if ($Hwnd -eq [IntPtr]::Zero) { $root = $AE::RootElement } else { $root = $AE::FromHandle($Hwnd) }
  $lines = New-Object System.Collections.ArrayList
  $script:dshCount = 0
  function Walk {
    param($El, [int]$Depth)
    if ($script:dshCount -ge $MaxNodes -or $Depth -gt $MaxDepth) { return }
    $script:dshCount++
    $name = ''; $cls = ''; $aid = ''; $ct = ''
    try { $name = [string]$El.Current.Name } catch { }
    try { $cls  = [string]$El.Current.ClassName } catch { }
    try { $aid  = [string]$El.Current.AutomationId } catch { }
    try { $ct   = [string]$El.Current.ControlType.ProgrammaticName } catch { }
    $pats = @()
    foreach ($pn in @('ValuePattern', 'TextPattern', 'InvokePattern', 'SelectionItemPattern')) {
      try {
        $pat = [System.Windows.Automation.AutomationPattern]::$pn
        $obj = $null
        if ($El.TryGetCurrentPattern($pat, [ref]$obj)) { $pats += $pn }
      } catch { }
    }
    [void]$lines.Add(('{0}{1} | Name="{2}" | AutoId="{3}" | Class="{4}" | Patterns={5}' -f ('  ' * $Depth), $ct, $name, $aid, $cls, ($(if ($pats.Count) { $pats -join ',' } else { '-' }))))
    try {
      $kids = $El.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition)
      foreach ($k in $kids) { Walk -El $k -Depth ($Depth + 1) }
    } catch { }
  }
  Walk -El $root -Depth 0
  return ($lines -join "`r`n")
}

function New-DshTimestamp { return (Get-Date).ToString('yyyyMMdd-HHmmss') }
