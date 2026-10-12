# wx-core.ps1 - shared helpers for the WeChat auto-reply driver.
# ASCII-only source on purpose (PowerShell 5.1 here reads non-ASCII .ps1 as GBK).
# Chinese text must never be sent via SendKeys; it always goes clipboard + Ctrl+V.
#
# Dot-source this file:
#     . '.\wx-core.ps1'
#
# Layout-independent by design: this sandbox cannot enumerate process names, so the
# WeChat process is identified by the window class of its tray icon message window,
# and the main window is the largest visible window owned by that pid.

$script:WxRoot      = $PSScriptRoot
$script:WxStateDir  = Join-Path $script:WxRoot 'state'
$script:WxShotDir   = Join-Path $script:WxRoot 'shots'
$script:WxLogDir    = Join-Path $script:WxRoot 'logs'
$script:WxStateFile = Join-Path $script:WxStateDir 'wx-state.json'
# Replies whose send failed (window off-screen, focus stolen, ...) wait here so a failed
# send loses nothing: the watcher retries them on later rounds.
$script:WxPendingFile = Join-Path $script:WxStateDir 'pending.json'
# ---------------------------------------------------------------- contacts
# Several contacts, each with its own prompts. The store is state\contacts.json:
#   { "active": "<name>", "contacts": [ { "name": .., "enabled": true,
#     "replyPrompt": .., "proactivePrompt": .. } ] }
# The watcher answers the active contact only; the panel switches it and edits the
# prompts. The two prompt .txt files stay as the seed for a fresh install, so an
# existing setup keeps working with no migration step.
$script:WxContactsFile = Join-Path $script:WxStateDir 'contacts.json'
$script:WxActiveReplyFile = Join-Path $script:WxStateDir 'active-reply-prompt.txt'
$script:WxActiveProactiveFile = Join-Path $script:WxStateDir 'active-proactive-prompt.txt'

function Get-WxLegacyPrompt {
  param([string]$Name)
  $p = Join-Path $script:WxRoot $Name
  if (Test-Path -LiteralPath $p) { return (Get-Content -LiteralPath $p -Raw -Encoding UTF8) }
  return ''
}

function ConvertTo-WxJsonText {
  # A plain JSON string. ConvertTo-Json cannot be used here: PowerShell 5.1 turns a
  # multi-line string into { "value": .. }, which no other JSON reader understands.
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

function Save-WxContacts {
  param($Data)
  $dir = Split-Path -Parent $script:WxContactsFile
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  $list = @($Data.contacts)
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.AppendLine('{')
  [void]$sb.AppendLine('  "active": ' + (ConvertTo-WxJsonText ([string]$Data.active)) + ',')
  [void]$sb.AppendLine('  "contacts": [')
  for ($i = 0; $i -lt $list.Count; $i++) {
    $c = $list[$i]
    $en = 'false'
    if ($c.enabled) { $en = 'true' }
    [void]$sb.AppendLine('    {')
    [void]$sb.AppendLine('      "name": ' + (ConvertTo-WxJsonText ([string]$c.name)) + ',')
    [void]$sb.AppendLine('      "enabled": ' + $en + ',')
    [void]$sb.AppendLine('      "replyPrompt": ' + (ConvertTo-WxJsonText ([string]$c.replyPrompt)) + ',')
    [void]$sb.AppendLine('      "proactivePrompt": ' + (ConvertTo-WxJsonText ([string]$c.proactivePrompt)))
    if ($i -lt ($list.Count - 1)) { [void]$sb.AppendLine('    },') } else { [void]$sb.AppendLine('    }') }
  }
  [void]$sb.AppendLine('  ]')
  [void]$sb.AppendLine('}')
  [System.IO.File]::WriteAllText($script:WxContactsFile, $sb.ToString(), (New-Object System.Text.UTF8Encoding($true)))
}

function Get-WxContacts {
  if (Test-Path -LiteralPath $script:WxContactsFile) {
    try {
      $d = Get-Content -LiteralPath $script:WxContactsFile -Raw -Encoding UTF8 | ConvertFrom-Json
      if ($d -and $d.contacts) { return $d }
    } catch { }
  }
  $c = [pscustomobject]@{ name = $script:WxTargetTitle; enabled = $true; replyPrompt = (Get-WxLegacyPrompt 'reply-prompt-text.txt'); proactivePrompt = (Get-WxLegacyPrompt 'proactive-prompt-text.txt') }
  $d = [pscustomobject]@{ active = $script:WxTargetTitle; contacts = @($c) }
  Save-WxContacts $d
  return $d
}

function Get-WxActiveContact {
  param($Data)
  if (-not $Data) { $Data = Get-WxContacts }
  $list = @($Data.contacts)
  foreach ($c in $list) { if ($c.name -eq $Data.active) { return $c } }
  foreach ($c in $list) { if ($c.enabled) { return $c } }
  if ($list.Count -gt 0) { return $list[0] }
  return $null
}

function Set-WxActiveContact {
  param([string]$Name)
  $d = Get-WxContacts
  $d.active = $Name
  foreach ($c in @($d.contacts)) { if ($c.name -eq $Name) { $c.enabled = $true } }
  Save-WxContacts $d
  return $d
}

function Resolve-WxPromptFiles {
  param($Contact)
  if (-not $Contact) { $Contact = Get-WxActiveContact }
  if (-not $Contact) { return $null }
  $reply = [string]$Contact.replyPrompt
  $pro = [string]$Contact.proactivePrompt
  if (-not $reply) { $reply = Get-WxLegacyPrompt 'reply-prompt-text.txt' }
  if (-not $pro) { $pro = Get-WxLegacyPrompt 'proactive-prompt-text.txt' }
  [System.IO.File]::WriteAllText($script:WxActiveReplyFile, $reply, (New-Object System.Text.UTF8Encoding($false)))
  [System.IO.File]::WriteAllText($script:WxActiveProactiveFile, $pro, (New-Object System.Text.UTF8Encoding($false)))
  return [pscustomobject]@{ Reply = $script:WxActiveReplyFile; Proactive = $script:WxActiveProactiveFile }
}

# The contact this driver is allowed to answer. It lives here, in the file that already
# carries a UTF-8 BOM, because a BOM-less .ps1 gets decoded as GBK by PowerShell 5.1 and a
# non-ASCII literal there swallows the following quote and breaks the whole file.
# Callers that must stay pure ASCII reference $script:WxTargetTitle instead of the name.
$script:WxTargetTitle = 'my-friend'

foreach ($d in @($script:WxStateDir, $script:WxShotDir, $script:WxLogDir)) {
  if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
}

if (-not ('WinEnum' -as [type])) { . (Join-Path $script:WxRoot 'winenum.ps1') }
if (-not (Get-Command Get-DshWindowRect -ErrorAction SilentlyContinue)) { . (Join-Path $script:WxRoot 'winio.ps1') }
try { Add-Type -AssemblyName System.Windows.Forms } catch { }

function Get-WxRoot { return $script:WxRoot }
function Get-WxShotDir { return $script:WxShotDir }
function Get-WxLogDir { return $script:WxLogDir }

# ---------------------------------------------------------------- discovery

function Get-WxPid {
  foreach ($l in [WinEnum]::TopLevel()) {
    $f = $l -split '\|'
    if ($f[3] -like '*WxTrayIconMessageWindow*' -or $f[4] -like '*WxTrayIconMessageWindow*') {
      return [int]$f[2]
    }
  }
  return $null
}

function Get-WxTrayWindow {
  foreach ($l in [WinEnum]::TopLevel()) {
    $f = $l -split '\|'
    if ($f[3] -like '*WxTrayIconMessageWindow*' -or $f[4] -like '*WxTrayIconMessageWindow*') {
      return [pscustomobject]@{ Hwnd = [IntPtr][int]$f[0]; Pid = [int]$f[2]; Class = $f[3]; Title = $f[4] }
    }
  }
  return $null
}

# Largest VISIBLE window owned by the WeChat pid = main window (once it exists).
function Get-WxMainWindow {
  param([int]$WxPid, [int]$MinArea = 90000)
  if (-not $WxPid) { $WxPid = Get-WxPid }
  if (-not $WxPid) { return $null }
  $best = $null; $bestArea = 0
  foreach ($l in [WinEnum]::TopLevel()) {
    $f = $l -split '\|'
    if ([int]$f[2] -ne $WxPid) { continue }
    if ($f[1] -ne 'vis') { continue }
    $r = Get-DshWindowRect -Hwnd ([IntPtr][int]$f[0])
    if (-not $r) { continue }
    if ($r.Width -le 0 -or $r.Height -le 0) { continue }
    $a = $r.Width * $r.Height
    if ($a -gt $bestArea) {
      $bestArea = $a
      $best = [pscustomobject]@{
        Hwnd = [IntPtr][int]$f[0]; Pid = $WxPid; Class = $f[3]; Title = $f[4]
        Left = $r.Left; Top = $r.Top; Width = $r.Width; Height = $r.Height; Area = $a
      }
    }
  }
  if (-not $best) { return $null }
  # A minimized window parks its rect at -32000,-32000 and collapses to a ~160x25 stub,
  # so the area test would reject the one window we actually need. Report the minimised
  # state instead of hiding the window; callers restore it before doing anchor maths.
  $best | Add-Member -NotePropertyName Minimized -NotePropertyValue ([DshWin.Native]::IsIconic($best.Hwnd)) -Force
  if (-not $best.Minimized -and $best.Area -lt $MinArea) { return $null }
  return $best
}

# Un-minimize WeChat. -NoActivate restores it without stealing the user's keyboard focus.
function Restore-WxWindow {
  param([IntPtr]$Hwnd, [switch]$NoActivate)
  if (-not $Hwnd -or $Hwnd -eq [IntPtr]::Zero) { return $false }
  if (-not [DshWin.Native]::IsIconic($Hwnd)) { return $true }
  if ($NoActivate) { [void][DshWin.Native]::ShowWindow($Hwnd, 4) }   # SW_SHOWNOACTIVATE
  else { [void][DshWin.Native]::ShowWindow($Hwnd, 9) }               # SW_RESTORE
  Start-Sleep -Milliseconds 400
  return (-not [DshWin.Native]::IsIconic($Hwnd))
}

function Get-WxStatus {
  $p = Get-WxPid
  $m = if ($p) { Get-WxMainWindow -WxPid $p } else { $null }
  return [pscustomobject]@{
    WeixinPid      = $p
    MainWindowOpen = [bool]$m
    MainWindow     = $m
    TrayWindow     = Get-WxTrayWindow
  }
}

# ---------------------------------------------------------------- capture

function Save-WxChatShot {
  param([IntPtr]$Hwnd, [string]$Name = 'chat-latest.png', [string]$Method = 'Screen')
  if (-not $Hwnd) {
    $m = Get-WxMainWindow
    if (-not $m) { throw 'WeChat main window not found (tray only?).' }
    $Hwnd = $m.Hwnd
  }
  $out = Join-Path $script:WxShotDir $Name
  $f = Save-DshWindowCapture -Hwnd $Hwnd -OutFile $out -Method $Method
  return $f
}

# ---------------------------------------------------------------- layout anchors
# Fractions of the WeChat CLIENT area, measured from a DPI-aware capture
# (window 1786x1293 at screen 163,180 ; client 1760x1280 at screen 176,180).
# WeChat's layout is stable for a given window size, and every action is verified by a
# screenshot afterwards, so these only need to be approximately right.
$script:WxFractions = @{
  input     = @(0.627, 0.828)                  # centre of the chat input box
  send      = @(0.855, 0.781)                  # the "send" button (fallback for Enter)
  header    = @(0.286, 0.085)                  # chat title -> which chat is open
  navchat   = @(0.033, 0.285)                  # left rail: chats tab
  msgRect   = @(0.232, 0.113, 0.985, 0.742)    # chat transcript area. Left edge must clear the pane
                                               # divider, otherwise the incoming avatars and the
                                               # first character of the chat title get cut off.
                                               # Right edge stops short of the fading scrollbar,
                                               # whose animation would churn the frame hash.
  inputRect = @(0.270, 0.759, 0.985, 0.898)    # the input box area
  headerRect = @(0.232, 0.030, 0.985, 0.140)   # chat title band -> proves WHICH chat is open
  chatctxRect = @(0.232, 0.030, 0.985, 0.742)  # header + transcript: what the reply model reads
  listRect  = @(0.066, 0.113, 0.230, 0.980)    # session list column
}

function Get-WxClientInfo {
  $m = Get-WxMainWindow
  if (-not $m) { return $null }
  if ($m.Minimized) {
    [void](Restore-WxWindow -Hwnd $m.Hwnd -NoActivate)
    $m = Get-WxMainWindow          # refresh: the rect moved when it was restored
    if (-not $m) { return $null }
  }
  $c = Get-DshClientRect -Hwnd $m.Hwnd
  if (-not $c) { return $null }
  return [pscustomobject]@{ Hwnd = $m.Hwnd; Left = $m.Left; Top = $m.Top; X = $c.ScreenX; Y = $c.ScreenY; W = $c.Width; H = $c.Height }
}

function Get-WxAnchor {
  param([Parameter(Mandatory = $true)][string]$Name)
  $ci = Get-WxClientInfo
  if (-not $ci) { throw 'WeChat main window not found.' }
  $f = $script:WxFractions[$Name]
  if (-not $f) { throw ('unknown anchor: ' + $Name) }
  $x = [int]($ci.X + $f[0] * $ci.W)
  $y = [int]($ci.Y + $f[1] * $ci.H)
  if ($f.Count -eq 2) { return [pscustomobject]@{ X = $x; Y = $y } }
  return [pscustomobject]@{
    X = $x; Y = $y
    W = [int](($f[2] - $f[0]) * $ci.W); H = [int](($f[3] - $f[1]) * $ci.H)
  }
}

# Returns the window rect once it has held still for a few samples, else $null.
# Anchored clicks are computed from the client rect, so a window that is still sliding
# (or being dragged) turns a click aimed at the input box into a click somewhere else -
# this is how a test draft once got SENT: the click meant for the input box landed on the
# send button while the window was moving. Never click a window that is still moving.
function Wait-DshGeometryStable {
  param([IntPtr]$Hwnd, [int]$MaxMs = 1200)
  if (-not $Hwnd -or $Hwnd -eq [IntPtr]::Zero) { return $null }
  $prev = $null
  $stable = 0
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  while ($sw.ElapsedMilliseconds -lt $MaxMs) {
    $r = Get-DshWindowRect -Hwnd $Hwnd
    if ($r -and $prev -and $r.Left -eq $prev.Left -and $r.Top -eq $prev.Top -and
        $r.Width -eq $prev.Width -and $r.Height -eq $prev.Height) { $stable++ } else { $stable = 0 }
    $prev = $r
    if ($stable -ge 2 -and $r) { return $r }
    Start-Sleep -Milliseconds 60
  }
  return $null
}

function Invoke-WxClickAnchor {
  param([Parameter(Mandatory = $true)][string]$Name, [switch]$Right, [int]$SettleMs = 350)
  $m = Get-WxMainWindow
  if (-not $m) { return $null }
  $settled = Wait-DshGeometryStable -Hwnd $m.Hwnd -MaxMs 1200
  if (-not $settled) {
    Add-WxLog 'ERROR' ('WeChat window is still moving - anchored click on "' + $Name + '" aborted') | Out-Null
    return $null
  }
  $p = Get-WxAnchor -Name $Name
  $now = Get-DshWindowRect -Hwnd $m.Hwnd
  if (-not $now -or $now.Left -ne $settled.Left -or $now.Top -ne $settled.Top -or
      $now.Width -ne $settled.Width -or $now.Height -ne $settled.Height) {
    Add-WxLog 'ERROR' ('WeChat window moved between measuring and clicking "' + $Name + '" - aborted') | Out-Null
    return $null
  }
  if ($Right) { Invoke-DshClick -X $p.X -Y $p.Y -Button Right } else { Invoke-DshClick -X $p.X -Y $p.Y -Button Left }
  Start-Sleep -Milliseconds $SettleMs
  return $p
}

# ---------------------------------------------------------------- state

function Get-WxState {
  $s = $null
  if (Test-Path $script:WxStateFile) {
    try { $s = (Get-Content $script:WxStateFile -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { }
  }
  if (-not $s) { $s = [pscustomobject]@{ } }
  # normalize: a missing key must behave like an empty list, never like a one-element
  # list holding $null (that bug made "@($s.inbound).Count" report 1 on a fresh state)
  foreach ($k in 'replied', 'sends', 'inbound') {
    $v = $null
    if ($s.PSObject.Properties.Name -contains $k) { $v = $s.$k }
    if ($null -eq $v) { $s | Add-Member -NotePropertyName $k -NotePropertyValue @() -Force }
    elseif ($v -isnot [array]) { $s | Add-Member -NotePropertyName $k -NotePropertyValue @($v) -Force }
  }
  return $s
}

function Set-WxState {
  param($State)
  $State | Add-Member -NotePropertyName updated -NotePropertyValue ((Get-Date).ToString('s')) -Force
  $State | ConvertTo-Json -Depth 6 | Set-Content -Path $script:WxStateFile -Encoding UTF8
}

function Get-WxTextHash {
  param([string]$Text)
  $norm = ($Text -replace '\s+', ' ').Trim()
  $sha = [System.Security.Cryptography.SHA256]::Create()
  $b = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($norm))
  return (($b | ForEach-Object { $_.ToString('x2') }) -join '').Substring(0, 16)
}

# Same reply text inside the window = do not send twice.
function Test-WxDuplicate {
  param([string]$Text, [int]$WithinMinutes = 30)
  $h = Get-WxTextHash -Text $Text
  $s = Get-WxState
  foreach ($r in @($s.replied)) {
    if ($null -eq $r) { continue }
    if ($r.hash -eq $h) {
      $age = (New-TimeSpan -Start ([datetime]$r.ts) -End (Get-Date)).TotalMinutes
      if ($age -lt $WithinMinutes) { return $true }
    }
  }
  return $false
}

# Throttle: minimum gap between sends + hourly cap.
function Test-WxSendAllowed {
  param([int]$MinIntervalSec = 20, [int]$MaxPerHour = 30)
  $s = Get-WxState
  $now = Get-Date
  $sends = @()
  foreach ($t in @($s.sends)) { if ($t) { $sends += [datetime]$t } }
  $last = $sends | Sort-Object -Descending | Select-Object -First 1
  if ($last) {
    $gap = ($now - $last).TotalSeconds
    if ($gap -lt $MinIntervalSec) {
      return [pscustomobject]@{ Ok = $false; Reason = ('min-interval: last send ' + [int]$gap + 's ago (< ' + $MinIntervalSec + 's)') }
    }
  }
  $hour = @($sends | Where-Object { ($now - $_).TotalMinutes -lt 60 })
  if ($hour.Count -ge $MaxPerHour) {
    return [pscustomobject]@{ Ok = $false; Reason = ('hourly cap: ' + $hour.Count + ' sends (>= ' + $MaxPerHour + ')') }
  }
  return [pscustomobject]@{ Ok = $true; Reason = 'ok' }
}

function Add-WxLog {
  param([string]$Kind, [string]$Message)
  $line = ('{0} [{1}] {2}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Kind, $Message)
  Add-Content -Path (Join-Path $script:WxLogDir 'wx-reply-log.txt') -Value $line -Encoding UTF8
  Write-Output $line
}

# ---------------------------------------------------------------- send

# ---------------------------------------------------------------- send button
# WeChat's send button is the only saturated-green thing in the bottom-right of the
# window: WeChat green is about #07C160. It is GREY while the input box is empty and
# GREEN as soon as there is text to send. That makes it both a precise click target and
# a free "is there text in the input box?" sensor, so the driver never has to guess.
function Get-WxSendButton {
  param([double]$MinPixels = 300)
  $m = Get-WxMainWindow
  if (-not $m) { return [pscustomobject]@{ Found = $false; Pixels = 0; X = 0; Y = 0 } }
  $ci = Get-WxClientInfo -Hwnd $m.Hwnd
  if (-not $ci) { return [pscustomobject]@{ Found = $false; Pixels = 0; X = 0; Y = 0 } }
  # Capture the WINDOW, never the screen. CopyFromScreen reads whatever happens to be on
  # top, so another window's green pixels were once mistaken for the send button - and the
  # click target computed from them pointed into that other window. A test draft got sent
  # that way. PrintWindow renders WeChat itself, occluded or not.
  $wW = [int]$m.Width; $wH = [int]$m.Height
  if ($wW -le 0 -or $wH -le 0) { return [pscustomobject]@{ Found = $false; Pixels = 0; X = 0; Y = 0 } }
  $bmp = New-Object System.Drawing.Bitmap($wW, $wH)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $hdc = $g.GetHdc()
  $ok = $false
  try { $ok = [DshWin.Native]::PrintWindow($m.Hwnd, $hdc, 2) } catch { $ok = $false }
  $g.ReleaseHdc($hdc)
  $g.Dispose()
  if (-not $ok) { $bmp.Dispose(); return [pscustomobject]@{ Found = $false; Pixels = 0; X = 0; Y = 0 } }
  $ox = [int]$ci.X - [int]$m.Left
  $oy = [int]$ci.Y - [int]$m.Top
  $zx = [int]($ox + 0.78 * $ci.W); $zy = [int]($oy + 0.74 * $ci.H)
  $zw = [int](($ox + $ci.W) - $zx); $zh = [int](($oy + 0.97 * $ci.H) - $zy)
  if ($zw -le 0 -or $zh -le 0 -or $zx -lt 0 -or $zy -lt 0 -or ($zx + $zw) -gt $wW -or ($zy + $zh) -gt $wH) {
    $bmp.Dispose(); return [pscustomobject]@{ Found = $false; Pixels = 0; X = 0; Y = 0 }
  }
  $sumX = 0.0; $sumY = 0.0; $n = 0
  $minX = [int]::MaxValue; $minY = [int]::MaxValue; $maxX = -1; $maxY = -1
  for ($y = $zy; $y -lt ($zy + $zh); $y += 2) {
    for ($x = $zx; $x -lt ($zx + $zw); $x += 2) {
      $c = $bmp.GetPixel($x, $y)
      if ($c.G -gt 150 -and ($c.G - $c.R) -gt 60 -and ($c.G - $c.B) -gt 40) {
        $sumX += $x; $sumY += $y; $n++
        if ($x -lt $minX) { $minX = $x }; if ($y -lt $minY) { $minY = $y }
        if ($x -gt $maxX) { $maxX = $x }; if ($y -gt $maxY) { $maxY = $y }
      }
    }
  }
  $bmp.Dispose()
  if ($n -lt $MinPixels) { return [pscustomobject]@{ Found = $false; Pixels = ($n * 4); X = 0; Y = 0 } }
  # a real button is a compact block, not a smear of green from a chat bubble
  $bw = $maxX - $minX; $bh = $maxY - $minY
  if ($bw -lt 8 -or $bh -lt 8 -or $bw -gt 260 -or $bh -gt 160) {
    return [pscustomobject]@{ Found = $false; Pixels = ($n * 4); X = 0; Y = 0 }
  }
  return [pscustomobject]@{
    Found = $true; Pixels = ($n * 4)
    X = [int]($m.Left + $sumX / $n); Y = [int]($m.Top + $sumY / $n)
    W = $bw; H = $bh
  }
}

function Test-WxInputHasText { return (Get-WxSendButton).Found }

# ---------------------------------------------------------------- send

# Types text into the open WeChat chat input box and (optionally) sends it.
#   default  : focus the input, clear it, paste Text, verify the send button turned
#              green, then STOP. Nothing is sent.
#   -DryRun  : same as default (kept for explicitness) - never sends.
#   -Commit  : additionally click the send button (precise pixel target, not Enter,
#              so it does not matter whether WeChat is set to Enter or Ctrl+Enter).
function Send-WxText {
  param(
    [Parameter(Mandatory = $true)][string]$Text,
    [switch]$Commit,
    [switch]$DryRun,
    [IntPtr]$Hwnd,
    [switch]$KeepTyped,
    # Which conversation this draft belongs to. If the user switches chats between the read and
    # the send, the reply must not land in the wrong conversation.
    [string]$ExpectTitle = '',
    # Intentionally repeatable line (see wx-uia.ps1): skips the duplicate and throttle gates.
    [switch]$AllowRepeat
  )
  if ($ExpectTitle -and (Get-Command Test-WxUiaTargetTitle -ErrorAction SilentlyContinue)) {
    if (-not (Test-WxUiaTargetTitle -ExpectTitle $ExpectTitle)) {
      Add-WxLog 'BLOCKED' ('the open chat is not "' + $ExpectTitle + '" any more - the reply was not sent') | Out-Null
      return $false
    }
  }
  # UIA first: no window coordinates, no clipboard, no keystrokes, and it works while
  # WeChat is covered or off-screen. $null = UIA is unusable -> fall through to the screen path.
  if (Get-Command Send-WxTextUia -ErrorAction SilentlyContinue) {
    $uiaRes = Send-WxTextUia -Text $Text -Commit:$Commit -DryRun:$DryRun -KeepTyped:$KeepTyped -AllowRepeat:$AllowRepeat
    if ($null -ne $uiaRes) { return $uiaRes }
  }

  $m = if ($Hwnd) { [pscustomobject]@{ Hwnd = $Hwnd } } else { Get-WxMainWindow }
  if (-not $m) { Add-WxLog 'ERROR' 'no WeChat main window' | Out-Null; return $false }
  $hwnd = $m.Hwnd

  $prevFg = [DshWin.Native]::GetForegroundWindow()
  [void](Set-DshForeground -Hwnd $hwnd)
  Start-Sleep -Milliseconds 200
  # Never type into whatever happens to be in front. If WeChat is not the foreground
  # window the keystrokes and the Ctrl+V would land in some other application.
  if ([DshWin.Native]::GetForegroundWindow() -ne $hwnd) {
    Add-WxLog 'ERROR' 'WeChat could not be brought to the foreground - aborted without typing' | Out-Null
    return $false
  }
  $restore = {
    if ($prevFg -ne [IntPtr]::Zero -and $prevFg -ne $hwnd) {
      try { [void](Set-DshForeground -Hwnd $prevFg) } catch { }
    }
  }

  # Guard: the send path is real mouse input, and SetCursorPos silently clamps a point to
  # the screen edge - so a click aimed at an off-screen input box would land somewhere
  # else entirely. If the input box is not inside the visible screen, abort instead.
  $scr = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
  $probe = Get-WxAnchor -Name input
  if ($probe.X -lt 0 -or $probe.Y -lt 0 -or $probe.X -gt ($scr.Width - 20) -or $probe.Y -gt ($scr.Height - 20)) {
    Add-WxLog 'ERROR' ('WeChat input box is off-screen (' + $probe.X + ',' + $probe.Y + ' vs screen ' + $scr.Width + 'x' + $scr.Height + ') - aborted without clicking; move the WeChat window fully onto the screen') | Out-Null
    & $restore
    return $false
  }

  $anchor = Invoke-WxClickAnchor -Name input -SettleMs 250
  if (-not $anchor) { & $restore; return $false }
  # The click can also change who owns the keyboard: if WeChat did not end up in front,
  # Ctrl+A / DEL / Ctrl+V would land in whatever the click did activate. Never type then.
  if ([DshWin.Native]::GetForegroundWindow() -ne $hwnd) {
    Add-WxLog 'ERROR' 'input box click did not leave WeChat in the foreground - aborted without typing' | Out-Null
    & $restore
    return $false
  }
  # clear whatever was left in the box (a stray draft is a real risk)
  [System.Windows.Forms.SendKeys]::SendWait('^a')
  Start-Sleep -Milliseconds 100
  [System.Windows.Forms.SendKeys]::SendWait('{DEL}')
  Start-Sleep -Milliseconds 150

  # One silent second attempt: a paste can miss when the foreground changes between the click and
  # the keystroke, and without this a transient miss burned every queued retry in under a minute.
  $btn = $null
  for ($attempt = 1; $attempt -le 2; $attempt++) {
    Set-DshClipboardText -Text $Text
    Start-Sleep -Milliseconds 150
    [System.Windows.Forms.SendKeys]::SendWait('^v')

    # Poll for the paste instead of sleeping a fixed 800ms: the green send button IS the
    # "is there text in the box" sensor, so waiting on it is both faster and less fragile.
    $btn = Get-WxSendButton
    for ($i = 0; $i -lt 5 -and -not $btn.Found; $i++) {
      Start-Sleep -Milliseconds 120
      $btn = Get-WxSendButton
    }
    if ($btn.Found) { break }
    if ($attempt -eq 1) {
      Add-WxLog 'WARN' 'the paste did not land - taking the foreground again and retrying it once' | Out-Null
      try { if ([DshWin.Native]::GetForegroundWindow() -ne $hwnd) { [void](Set-DshForeground -Hwnd $hwnd); Start-Sleep -Milliseconds 200 } } catch { }
      $again = Invoke-WxClickAnchor -Name input -SettleMs 200
      if (-not $again) { break }
      start-sleep -Milliseconds 120
      [System.Windows.Forms.SendKeys]::SendWait('^a')
      Start-Sleep -Milliseconds 80
      [System.Windows.Forms.SendKeys]::SendWait('{DEL}')
      Start-Sleep -Milliseconds 120
    }
  }
  if (-not $btn.Found) {
    Add-WxLog 'ERROR' ('paste did not reach the input box (send button stayed grey) at ' + $anchor.X + ',' + $anchor.Y + ' - WeChat did not take the keyboard focus; the reply stays queued and the next try backs off') | Out-Null
    & $restore
    return $false
  }

  if ($DryRun -or -not $Commit) {
    Add-WxLog 'DRYRUN' ('typed (NOT sent, button green at ' + $btn.X + ',' + $btn.Y + '): ' + $Text) | Out-Null
    if (-not $KeepTyped) {
      [System.Windows.Forms.SendKeys]::SendWait('^a')
      Start-Sleep -Milliseconds 150
      [System.Windows.Forms.SendKeys]::SendWait('{DEL}')
      Start-Sleep -Milliseconds 300
      $after = Get-WxSendButton
      Add-WxLog 'DRYRUN' ('input box cleared again: ' + (-not $after.Found)) | Out-Null
    }
    & $restore
    return $false
  }

  if (-not $AllowRepeat) {
    $gate = Test-WxSendAllowed
    if (-not $gate.Ok) { Add-WxLog 'BLOCKED' $gate.Reason | Out-Null; & $restore; return $false }
    if (Test-WxDuplicate -Text $Text) { Add-WxLog 'DUP' $Text | Out-Null; & $restore; return $false }
  }

  Invoke-DshClick -X $btn.X -Y $btn.Y
  # Poll until the box empties (button back to grey) instead of a flat 1s wait.
  $after = Get-WxSendButton
  for ($i = 0; $i -lt 7 -and $after.Found; $i++) {
    Start-Sleep -Milliseconds 120
    $after = Get-WxSendButton
  }
  $ok = -not $after.Found
  if ($ok) {
    $s = Get-WxState
    $s.replied = @($s.replied) + [pscustomobject]@{ hash = (Get-WxTextHash -Text $Text); ts = (Get-Date).ToString('s'); text = $Text }
    $s.sends = @($s.sends) + (Get-Date).ToString('s')
    Set-WxState $s
    Add-WxLog 'SENT' $Text | Out-Null
  } else {
    # Not proof of failure: a green bubble that has just landed above the input row sits inside
    # the scanned zone and reads as "the box still holds text" (four such false negatives were
    # logged). The caller queues the draft, and the watcher drops the queue entry once the chat
    # itself shows the draft as my newest message.
    Add-WxLog 'WARN' 'clicked send but the send button still looked green - delivery is unverified' | Out-Null
  }
  & $restore
  return $ok
}

# ---------------------------------------------------------------- policy / dedupe

# state\mode.txt is the user's switch: "dryrun" (default) or "live".
function Get-WxMode {
  $f = Join-Path $script:WxRoot 'state\mode.txt'
  if (-not (Test-Path -LiteralPath $f)) { return 'dryrun' }
  $v = (Get-Content -LiteralPath $f -Raw).Trim().ToLower()
  if ($v -eq 'live') { return 'live' }
  return 'dryrun'
}

function Set-WxMode {
  param([ValidateSet('dryrun', 'live')][string]$Mode)
  $f = Join-Path $script:WxRoot 'state\mode.txt'
  Set-Content -LiteralPath $f -Value $Mode -Encoding ASCII -NoNewline
}

# Recent-inbound dedupe. Two rules, both deliberately narrow:
#   1. the same frame hash was already handled - re-processing one frame must never send twice
#   2. the same TEXT was handled within a couple of minutes - the re-entrancy case
# Rule 2 used to be 15 minutes, which silently ate a real reply when the other side repeated
# the same short line ("大雨爽昏了") a few minutes later. Keep it short.
function Test-WxInboundSeen {
  param([string]$Text, [string]$FrameSha, [int]$WithinMinutes = 3)
  $s = Get-WxState
  $h = Get-WxTextHash -Text $Text
  $cut = (Get-Date).AddMinutes(-$WithinMinutes)
  $frameCut = (Get-Date).AddMinutes(-30)
  foreach ($e in @($s.inbound)) {
    if (-not $e) { continue }
    $t = [datetime]::MinValue
    try { $t = [datetime]::Parse([string]$e.ts) } catch { }
    if ($FrameSha -and $e.frameSha -eq $FrameSha -and $t -ge $frameCut) { return $true }
    if ($e.hash -eq $h -and $t -ge $cut) { return $true }
  }
  return $false
}

function Add-WxInbound {
  param([string]$Text, [string]$FrameSha)
  $s = Get-WxState
  $s.inbound = @($s.inbound) + [pscustomobject]@{
    hash = (Get-WxTextHash -Text $Text); ts = (Get-Date).ToString('s'); text = $Text; frameSha = $FrameSha
  }
  Set-WxState $s
}

function Get-WxPending {
  if (-not (Test-Path $script:WxPendingFile)) { return @() }
  $raw = Get-Content -LiteralPath $script:WxPendingFile -Raw -Encoding UTF8
  if (-not $raw -or -not $raw.Trim()) { return @() }
  try { return @((ConvertFrom-Json -InputObject $raw) | Where-Object { $_ }) } catch { return @() }
}

function Set-WxPending {
  param($List)
  $arr = @($List | Where-Object { $_ })
  ConvertTo-Json -InputObject $arr -Depth 6 | Set-Content -LiteralPath $script:WxPendingFile -Encoding UTF8
}

# A queued reply is retried with a growing delay. A paste that did not land usually means Windows
# briefly gave the foreground to something else (IME popup, notification, the user alt-tabbing),
# and retrying in a tight loop just burns the five allowed tries in under a minute.
function Get-WxRetryDelaySec {
  param([int]$Tries)
  $d = 20 * [Math]::Pow(2, [Math]::Max(0, $Tries - 1))
  if ($d -gt 300) { $d = 300 }
  return [int]$d
}

function Add-WxPending {
  param([string]$Inbound, [string]$Draft, [switch]$Instant)
  $list = @(Get-WxPending)
  # -Instant marks the repeated "wall of text" one-liner: it only makes sense right after the
  # message that triggered it, so the watcher retries it for three minutes and then drops it.
  $list += [pscustomobject]@{ inbound = $Inbound; draft = $Draft; ts = (Get-Date).ToString('s'); tries = 0; instant = [bool]$Instant; nextTry = (Get-Date).ToString('s') }
  Set-WxPending $list
}

function Remove-WxPending {
  param([string]$Draft)
  $list = @(Get-WxPending | Where-Object { $_.draft -ne $Draft })
  Set-WxPending $list
}

# The UIA driver lives in its own file: a bad edit in there cannot take wx-core down.
$script:WxUiaLib = Join-Path $script:WxRoot 'wx-uia.ps1'
if (Test-Path -LiteralPath $script:WxUiaLib) { . $script:WxUiaLib }
