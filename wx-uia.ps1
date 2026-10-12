# WeChat 4.x ("Radium"/mmui) exposes a real Microsoft UI Automation tree: chat text is readable
# verbatim, the input box accepts ValuePattern.SetValue and the send button accepts
# InvokePattern.Invoke. That replaces screenshot + OCR for reading and mouse + clipboard +
# keystrokes for sending, and it works while the window is covered, off-screen or minimized.
#
# Two things UIA does NOT give us:
#   * who sent a bubble - a message row carries no sender field, so the side is decided from the
#     rendered row exactly as before (WeChat-green = mine, and right-aligned = mine);
#   * a guaranteed quiet ride - SetValue/Invoke make WeChat the foreground window for a few
#     milliseconds (13ms / 7ms measured), so every entry point records the previous foreground
#     window and hands it back before returning.
#
# Everything here is defensive: any failure returns $null so callers can fall back to the old
# screenshot path instead of breaking the watcher.

$script:WxUiaReady = $null   # $null = not tried yet, $false = unavailable, $true = loaded
# A minimised window cannot be rendered, so sender sides have to be read after a brief silent
# un-minimise. The rows themselves stay readable while minimised, so their signature is used to
# hand out the previous frame until the chat really changes (see Get-WxUiaFrame).
$script:WxUiaMinCache = $null

function Initialize-WxUia {
  if ($null -ne $script:WxUiaReady) { return [bool]$script:WxUiaReady }
  try {
    Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop
    Add-Type -AssemblyName UIAutomationTypes -ErrorAction Stop
    $script:WxUiaReady = $true
  } catch {
    $script:WxUiaReady = $false
    Add-WxLog 'WARN' ('UIA is unavailable: ' + $_.Exception.Message) | Out-Null
  }
  return [bool]$script:WxUiaReady
}

function Get-WxUiaRoot {
  param([IntPtr]$Hwnd)
  if (-not (Initialize-WxUia)) { return $null }
  $h = $Hwnd
  if ((-not $h) -or ($h -eq [IntPtr]::Zero)) {
    $m = Get-WxMainWindow
    if (-not $m) { return $null }
    $h = $m.Hwnd
  }
  try { return [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$h) } catch { return $null }
}

function Get-WxUiaNodes {
  param([System.Windows.Automation.AutomationElement]$Root)
  $out = New-Object System.Collections.ArrayList
  if (-not $Root) { return $out }
  try {
    $all = $Root.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
    foreach ($e in $all) { [void]$out.Add($e) }
  } catch { }
  return $out
}

function Get-WxUiaByAutoId {
  param([System.Windows.Automation.AutomationElement]$Root, [string]$AutoId)
  foreach ($e in (Get-WxUiaNodes -Root $Root)) {
    try { if ($e.Current.AutomationId -eq $AutoId) { return $e } } catch { }
  }
  return $null
}

function Get-WxUiaInput {
  param([System.Windows.Automation.AutomationElement]$Root)
  return (Get-WxUiaByAutoId -Root $Root -AutoId 'chat_input_field')
}

function Get-WxUiaChatTitle {
  param([System.Windows.Automation.AutomationElement]$Root)
  $e = Get-WxUiaByAutoId -Root $Root -AutoId 'content_view.top_content_view.title_h_view.left_v_view.left_content_v_view.left_ui_.big_title_line_h_view.current_chat_name_label'
  if (-not $e) { return '' }
  try { return [string]$e.Current.Name } catch { return '' }
}

# The input row has exactly one outlined button - the send button. Match on the class instead of
# the label so the code does not depend on the UI language. (Do NOT require it to sit right of the
# message list: that list spans nearly the whole client width while the button sits inside it.)
function Get-WxUiaSendButton {
  param([System.Windows.Automation.AutomationElement]$Root, $List = $null)
  $best = $null
  foreach ($e in (Get-WxUiaNodes -Root $Root)) {
    try {
      if ($e.Current.ClassName -ne 'mmui::XOutlineButton') { continue }
      $r = $e.Current.BoundingRectangle
      if ($r.Width -lt 8 -or $r.Height -lt 8) { continue }
      # keep the lowest-then-rightmost candidate: the send button lives in the bottom input row
      if ((-not $best) -or ($r.Y -gt $best.Rect.Y) -or (($r.Y -eq $best.Rect.Y) -and ($r.X -gt $best.Rect.X))) {
        $best = [pscustomobject]@{ Element = $e; Rect = $r }
      }
    } catch { }
  }
  if ($best) { return $best.Element }
  return $null
}

function Get-WxWindowBitmap {
  param($Window)
  $m = if ($Window) { $Window } else { Get-WxMainWindow }
  if (-not $m) { return $null }
  $w = [int]$m.Width
  $h = [int]$m.Height
  if ($w -le 0 -or $h -le 0) { return $null }
  $bmp = $null
  $g = $null
  try {
    $bmp = New-Object System.Drawing.Bitmap($w, $h)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $hdc = $g.GetHdc()
    $ok = $false
    try { $ok = [DshWin.Native]::PrintWindow($m.Hwnd, $hdc, 2) } catch { $ok = $false }
    $g.ReleaseHdc($hdc)
  } catch {
    if ($g) { $g.Dispose() }
    if ($bmp) { $bmp.Dispose() }
    return $null
  }
  $g.Dispose()
  if (-not $ok) { $bmp.Dispose(); return $null }
  return $bmp
}

# Which side is this row on? Green ink means my bubble; otherwise right-aligned means mine.
# Rows are sampled coarsely (step 3-4px) - a rounded corner or a thin glyph does not matter for
# either signal.
function Get-WxRowSide {
  param($Item, $Bmp, $Window, $ListRect = $null, [double]$GreenMin = 60)
  if ((-not $Item) -or (-not $Bmp) -or (-not $Window)) { return 'unknown' }
  try { $r = $Item.Current.BoundingRectangle } catch { return 'unknown' }
  $x0 = [int]$r.X - [int]$Window.Left
  $y0 = [int]$r.Y - [int]$Window.Top
  $x1 = $x0 + [int]$r.Width
  $y1 = $y0 + [int]$r.Height
  # A virtualised row can report a rectangle far taller than the list itself (one long message from
  # him came back as y=-938 h=1936 inside an 838px list). Clamp to the list first, so only pixels
  # that are really visible in the list can vote.
  if ($ListRect) {
    $lx0 = [int]$ListRect.X - [int]$Window.Left
    $ly0 = [int]$ListRect.Y - [int]$Window.Top
    $lx1 = $lx0 + [int]$ListRect.Width
    $ly1 = $ly0 + [int]$ListRect.Height
    if ($x0 -lt $lx0) { $x0 = $lx0 }
    if ($y0 -lt $ly0) { $y0 = $ly0 }
    if ($x1 -gt $lx1) { $x1 = $lx1 }
    if ($y1 -gt $ly1) { $y1 = $ly1 }
  }
  # Still implausibly tall? Then this row is one long message filling the list, and the interesting
  # bubble is its bottom: sample the tail instead of the whole area.
  if (($y1 - $y0) -gt 500) { $y0 = [Math]::Max($y0, $y1 - 320) }
  if ($x0 -lt 0) { $x0 = 0 }
  if ($y0 -lt 0) { $y0 = 0 }
  if ($x1 -gt $Bmp.Width) { $x1 = $Bmp.Width }
  if ($y1 -gt $Bmp.Height) { $y1 = $Bmp.Height }
  if ($x1 -le $x0 -or $y1 -le $y0) { return 'unknown' }

  $hist = @{}
  for ($y = $y0; $y -lt $y1; $y += 4) {
    for ($x = $x0; $x -lt $x1; $x += 4) {
      $c = $Bmp.GetPixel($x, $y)
      $k = '{0},{1},{2}' -f $c.R, $c.G, $c.B
      if ($hist.ContainsKey($k)) { $hist[$k]++ } else { $hist[$k] = 1 }
    }
  }
  if ($hist.Count -eq 0) { return 'unknown' }
  $bgKey = ($hist.GetEnumerator() | Sort-Object -Property Value -Descending | Select-Object -First 1).Key
  $bp = $bgKey -split ','
  $br = [int]$bp[0]; $bg = [int]$bp[1]; $bb = [int]$bp[2]

  $sx = 0.0; $n = 0; $green = 0
  for ($y = $y0; $y -lt $y1; $y += 3) {
    for ($x = $x0; $x -lt $x1; $x += 3) {
      $c = $Bmp.GetPixel($x, $y)
      $d = [Math]::Abs($c.R - $br) + [Math]::Abs($c.G - $bg) + [Math]::Abs($c.B - $bb)
      if ($d -le 60) { continue }
      $sx += $x; $n++
      if (($c.G -gt 120) -and (($c.G - $c.R) -gt 40) -and (($c.G - $c.B) -gt 30)) { $green++ }
    }
  }
  if ($green -ge $GreenMin) { return 'me' }
  if ($n -le 0) { return 'unknown' }
  $frac = (($sx / $n) - $x0) / ($x1 - $x0)
  if ($frac -gt 0.55) { return 'me' }
  return 'them'
}

# The message rows the list currently exposes, top to bottom. These stay readable even while the
# window is minimised - it is only the pixel colours (sender attribution) that need a rendered
# window, so a minimised chat can still be read, just not attributed without un-minimising once.
function Get-WxUiaItemList {
  param([System.Windows.Automation.AutomationElement]$Root)
  $list = Get-WxUiaByAutoId -Root $Root -AutoId 'chat_message_list'
  if (-not $list) { return @() }
  try { return @($list.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition)) } catch { return @() }
}

# Cheap fingerprint of the visible rows, so a change can be noticed without rendering anything.
function Get-WxUiaMessageSignature {
  param([System.Windows.Automation.AutomationElement]$Root)
  $sb = New-Object System.Text.StringBuilder
  foreach ($it in (Get-WxUiaItemList -Root $Root)) {
    try { [void]$sb.Append([string]$it.Current.ClassName + ':' + [string]$it.Current.Name + "`n") } catch { }
  }
  return $sb.ToString()
}

# One entry per message row, in the order the list exposes them (top to bottom).
function Get-WxUiaMessages {
  param([System.Windows.Automation.AutomationElement]$Root, $Window, $Bmp)
  $items = Get-WxUiaItemList -Root $Root
  if ($items.Count -eq 0) { return @() }
  # The list's own rectangle is the clipping box for row rectangles (see Get-WxRowSide).
  $listRect = $null
  $listEl = Get-WxUiaByAutoId -Root $Root -AutoId 'chat_message_list'
  if ($listEl) { try { $listRect = $listEl.Current.BoundingRectangle } catch { $listRect = $null } }
  $out = New-Object System.Collections.ArrayList
  foreach ($it in $items) {
    $cls = ''
    $txt = ''
    try { $cls = [string]$it.Current.ClassName; $txt = [string]$it.Current.Name } catch { continue }
    if ($cls -like '*ChatItemView*') { continue }   # time separator, not a message
    if ([string]::IsNullOrWhiteSpace($txt)) { continue }
    $side = Get-WxRowSide -Item $it -Bmp $Bmp -Window $Window -ListRect $listRect
    $top = 0
    try { $top = [int]$it.Current.BoundingRectangle.Y - [int]$Window.Top } catch { $top = 0 }
    [void]$out.Add([pscustomobject]@{ Side = $side; Text = $txt; Top = $top; Class = $cls })
  }
  return $out
}

# Same shape as the OCR transcript (Title + Blocks{Side,Text,Top} + Transcript), plus Sha16 so the
# watcher can use it as the frame fingerprint and skip screenshots entirely.
function Get-WxUiaFrame {
  param([switch]$NoCache)
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  if (-not (Initialize-WxUia)) { return $null }
  $m = Get-WxMainWindow
  if (-not $m) { return $null }
  $root = Get-WxUiaRoot -Hwnd $m.Hwnd
  if (-not $root) { return $null }
  $title = Get-WxUiaChatTitle -Root $root

  # A minimised window renders nothing but a 314x50 placeholder, so Get-WxRowSide cannot tell the
  # senders apart and every row would come back as "unknown". The rows themselves are readable, so
  # reuse the previous frame while they are unchanged, and only when the chat really changed
  # un-minimise the window for a moment (SW_SHOWNOACTIVATE: it stays in the background, it does not
  # take the focus) to attribute the rows, then minimise it again the same silent way.
  $rowSig = Get-WxUiaMessageSignature -Root $root
  if (-not $NoCache -and $script:WxUiaMinCache -and $script:WxUiaMinCache.Sig -eq $rowSig -and $script:WxUiaMinCache.Frame) {
    return $script:WxUiaMinCache.Frame
  }
  $reminimise = $false
  try { $reminimise = [bool][DshWin.Native]::IsIconic($m.Hwnd) } catch { $reminimise = $false }
  $canMinimise = $false
  try { $canMinimise = ($null -ne [DshWin.Native].GetMethod('CloseWindow')) } catch { $canMinimise = $false }
  if ($reminimise -and $canMinimise) {
    try { [void][DshWin.Native]::ShowWindow($m.Hwnd, 4) } catch { }   # SW_SHOWNOACTIVATE
    Start-Sleep -Milliseconds 400
    $m2 = Get-WxMainWindow
    if ($m2) { $m = $m2 }
  } else {
    $reminimise = $false
  }

  $bmp = Get-WxWindowBitmap -Window $m
  $blocks = @()
  try { $blocks = @(Get-WxUiaMessages -Root $root -Window $m -Bmp $bmp) }
  finally { if ($bmp) { $bmp.Dispose() } }
  if ($reminimise) {
    # CloseWindow() is the Win32 call that minimises without activating - the name is a red herring.
    try { [void][DshWin.Native]::CloseWindow($m.Hwnd) } catch { }
  }
  if ($blocks.Count -eq 0) { return $null }

  $sig = New-Object System.Text.StringBuilder
  [void]$sig.Append($title)
  foreach ($b in $blocks) { [void]$sig.Append('|' + $b.Side + ':' + $b.Text) }
  $sha = [System.Security.Cryptography.SHA1]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes($sig.ToString()))
  $hex = ([System.BitConverter]::ToString($sha) -replace '-', '').Substring(0, 16)

  $sb = New-Object System.Text.StringBuilder
  [void]$sb.AppendLine('标题: ' + $title)
  foreach ($b in $blocks) {
    $tag = if ($b.Side -eq 'me') { '我' } else { '对方' }
    [void]$sb.AppendLine(('[{0}] {1}' -f $tag, $b.Text))
  }

  $frame = [pscustomobject]@{
    Ok         = $true
    Sha16      = $hex
    Title      = $title
    Blocks     = $blocks
    Transcript = $sb.ToString().TrimEnd()
    Lines      = $blocks.Count
    Ms         = $sw.ElapsedMilliseconds
    Method     = 'uia'
    File       = ''
    Blank      = $false
  }
  if ($reminimise -and -not $NoCache) { $script:WxUiaMinCache = [pscustomobject]@{ Sig = $rowSig; Frame = $frame } }
  return $frame
}

# Has this exact text already landed as my newest message?
function Test-WxUiaDelivered {
  param([string]$Text)
  # Goes through Get-WxUiaFrame on purpose: that is the only reader that knows how to deal with a
  # minimised window (it briefly un-minimises it, without taking the focus, to attribute the rows).
  $fr = Get-WxUiaFrame
  if (-not $fr) { return $false }
  $blocks = @($fr.Blocks)
  if ($blocks.Count -eq 0) { return $false }
  $last = $blocks[$blocks.Count - 1]
  if ($last.Side -ne 'me') { return $false }
  $a = ($last.Text -replace '\s+', '')
  $b = ($Text -replace '\s+', '')
  if ($a -eq $b) { return $true }
  if ($b.Length -ge 4 -and $a.StartsWith($b)) { return $true }
  if ($a.Length -ge 4 -and $b.StartsWith($a)) { return $true }
  return $false
}

function Test-WxUiaTargetTitle {
  <#  True when the conversation open right now is still the expected one. Fails open: an empty
      expectation, missing UIA or an unreadable title all return true, so it can never block a send
      by itself - it only catches "the user switched chats while we were thinking". #>
  param([string]$ExpectTitle)
  if ([string]::IsNullOrWhiteSpace($ExpectTitle)) { return $true }
  if (-not (Initialize-WxUia)) { return $true }
  $m = Get-WxMainWindow
  if (-not $m) { return $true }
  $root = Get-WxUiaRoot -Hwnd $m.Hwnd
  if (-not $root) { return $true }
  $t = Get-WxUiaChatTitle -Root $root
  if ([string]::IsNullOrWhiteSpace($t)) { return $true }
  return (([string]$t).Trim() -eq $ExpectTitle.Trim())
}

# Write the draft into the input box and (with -Commit) press the send button through UIA.
#   returns $true  - committed and verified in the chat
#   returns $false - UIA worked but the send failed or could not be verified
#   returns $null  - UIA is not usable, caller should fall back to the screenshot path
function Send-WxTextUia {
  param(
    [Parameter(Mandatory = $true)][string]$Text,
    [switch]$Commit,
    [switch]$DryRun,
    [switch]$KeepTyped,
    # The owner wants the fixed "wall of text" line to go out every single time, right away: that
    # exact text is meant to repeat, so the duplicate check and the send throttle are skipped.
    [switch]$AllowRepeat
  )
  if (-not (Initialize-WxUia)) { return $null }
  $m = Get-WxMainWindow
  if (-not $m) { return $null }
  $root = Get-WxUiaRoot -Hwnd $m.Hwnd
  if (-not $root) { return $null }
  $input = Get-WxUiaInput -Root $root
  if (-not $input) { return $null }
  $vpat = $null
  try { $vpat = $input.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern) } catch { return $null }
  if (-not $vpat) { return $null }

  $prevFg = [IntPtr]::Zero
  try { $prevFg = [DshWin.Native]::GetForegroundWindow() } catch { $prevFg = [IntPtr]::Zero }
  $restore = {
    if ($prevFg -ne [IntPtr]::Zero -and $prevFg -ne $m.Hwnd) {
      try { [void](Set-DshForeground -Hwnd $prevFg) } catch { }
    }
  }

  try {
    $before = ''
    try { $before = [string]$vpat.Current.Value } catch { $before = '' }
    if ($before -and (($before -replace '\s+', '') -ne ($Text -replace '\s+', ''))) {
      # Whatever sat here is dropped - say so loudly, it could have been the user's own typing.
      Add-WxLog 'INFO' ('UIA: input box held "' + $before + '" - replaced by the draft') | Out-Null
    }
    $vpat.SetValue($Text)
    Start-Sleep -Milliseconds 120
    $back = ''
    try { $back = [string]$vpat.Current.Value } catch { $back = '' }
    if (($back -replace '\s+', '') -ne ($Text -replace '\s+', '')) {
      Add-WxLog 'ERROR' 'UIA: the input box did not take the draft' | Out-Null
      return $false
    }

    $btn = $null
    $list = Get-WxUiaByAutoId -Root $root -AutoId 'chat_message_list'
    $listRect = $null
    if ($list) { try { $listRect = $list.Current.BoundingRectangle } catch { $listRect = $null } }
    $btn = Get-WxUiaSendButton -Root $root -List $listRect
    if (-not $btn) {
      Add-WxLog 'ERROR' 'UIA: send button not found' | Out-Null
      return $false
    }

    if ($DryRun -or -not $Commit) {
      if (-not $KeepTyped) {
        try { $vpat.SetValue('') } catch { }
        Start-Sleep -Milliseconds 80
        $empty = ''
        try { $empty = [string]$vpat.Current.Value } catch { $empty = '' }
        Add-WxLog 'DRYRUN' ('UIA: typed then cleared (box empty: ' + [bool](-not $empty) + '): ' + $Text) | Out-Null
      } else {
        Add-WxLog 'DRYRUN' ('UIA: typed, left in the box (NOT sent): ' + $Text) | Out-Null
      }
      return $false
    }

    if ($AllowRepeat) {
      Add-WxLog 'INFO' 'AllowRepeat: this line is meant to repeat - skipping the duplicate check and the send throttle' | Out-Null
    } else {
      $gate = Test-WxSendAllowed
      if (-not $gate.Ok) { Add-WxLog 'BLOCKED' $gate.Reason | Out-Null; return $false }
      if (Test-WxDuplicate -Text $Text) { Add-WxLog 'DUP' $Text | Out-Null; return $false }
    }

    # Sending: InvokePattern.Invoke() on the send button does nothing at all in WeChat 4.x
    # (verified: the box kept the text and the chat never changed). What does work is asking the
    # input field for the focus and then sending a real Enter keystroke: the field takes the focus,
    # which makes WeChat the foreground window for a moment, and the keystroke lands there.
    $btnEnabled = $false
    try { $btnEnabled = [bool]$btn.Current.IsEnabled } catch { $btnEnabled = $false }
    if (-not $btnEnabled) {
      Add-WxLog 'ERROR' 'UIA: the send button is disabled even though the draft is in the box' | Out-Null
      if (-not $KeepTyped) { try { $vpat.SetValue('') } catch { } }
      return $false
    }
    # A minimised window can never be brought to the foreground, so the real Enter keystroke would
    # never land (verified 2026-10-05 22:25:59: "focusing the input field did not bring WeChat
    # forward - the Enter key was not sent"). Show it silently for the duration of the send and put
    # it back the way the owner left it in the "finally" below.
    $didShow = $false
    try {
      if ([DshWin.Native]::IsIconic($m.Hwnd)) {
        [void][DshWin.Native]::ShowWindow($m.Hwnd, 4)   # SW_SHOWNOACTIVATE
        $didShow = $true
      }
    } catch { $didShow = $false }
    if ($didShow) { Start-Sleep -Milliseconds 400 }
    try { Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue } catch { }
    try { $input.SetFocus() } catch {
      Add-WxLog 'ERROR' ('UIA: cannot focus the input field: ' + $_.Exception.Message) | Out-Null
      if (-not $KeepTyped) { try { $vpat.SetValue('') } catch { } }
      return $false
    }
    Start-Sleep -Milliseconds 120
    $fgNow = [IntPtr]::Zero
    try { $fgNow = [DshWin.Native]::GetForegroundWindow() } catch { }
    if ($fgNow -ne $m.Hwnd) {
      # Windows blocks foreground changes from a background process; the AttachThreadInput trick in
      # Set-DshForeground usually gets it through.
      try { [void](Set-DshForeground -Hwnd $m.Hwnd) } catch { }
      Start-Sleep -Milliseconds 200
      try { $fgNow = [DshWin.Native]::GetForegroundWindow() } catch { }
    }
    if ($fgNow -ne $m.Hwnd) {
      # Never type Enter into whatever window happens to be in front instead.
      Add-WxLog 'ERROR' 'UIA: focusing the input field did not bring WeChat forward - the Enter key was not sent' | Out-Null
      if (-not $KeepTyped) { try { $vpat.SetValue('') } catch { } }
      return $false
    }
    [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
    # Hand the foreground straight back: the send happens now, verification can run in the background.
    & $restore

    # Verify by asking the chat itself: the draft must show up as my newest message and the input
    # box must be empty again. Nothing here depends on the pixel colour of the send button.
    $delivered = $false
    $boxEmpty = $false
    for ($i = 0; $i -lt 8; $i++) {
      Start-Sleep -Milliseconds 250
      if (Test-WxUiaDelivered -Text $Text) { $delivered = $true; break }
      try { if ([string]::IsNullOrWhiteSpace([string]$vpat.Current.Value)) { $boxEmpty = $true } } catch { }
      if ($boxEmpty -and $i -ge 3) { break }
    }
    # A minimised window does not render its rows, so Test-WxUiaDelivered cannot see the new
    # message there (verified 2026-10-05: the message did arrive, the check just could not see it).
    # The input box going empty right after the Enter key is the client telling us it took the
    # text - accept that, otherwise wx-record queues the reply and the watcher sends it twice.
    $boxProof = $false
    if (-not $delivered -and $boxEmpty) { $delivered = $true; $boxProof = $true }
    if ($delivered) {
      $s = Get-WxState
      $s.replied = @($s.replied) + [pscustomobject]@{ hash = (Get-WxTextHash -Text $Text); ts = (Get-Date).ToString('s'); text = $Text }
      $s.sends = @($s.sends) + (Get-Date).ToString('s')
      Set-WxState $s
      Add-WxLog 'SENT' $Text | Out-Null
      if ($boxProof) { Add-WxLog 'INFO' 'UIA: delivery accepted because the input box emptied - the chat rows are not readable while the window is minimised' | Out-Null }
      return $true
    }
    # Not confirmed: take the draft back out of the box so a stray click cannot send it later.
    if (-not $KeepTyped) { try { $vpat.SetValue('') } catch { } }
    Add-WxLog 'WARN' ('UIA: pressed Enter but the chat does not show it yet (box empty: ' + $boxEmpty + ') - delivery is unverified, draft withdrawn') | Out-Null
    return $false
  } catch {
    Add-WxLog 'ERROR' ('UIA send failed: ' + $_.Exception.Message) | Out-Null
    return $false
  } finally {
    & $restore
    # If we un-minimised the window for the send, put it back - unless the owner is using it now.
    if ($didShow) {
      $fgAfter = [IntPtr]::Zero
      try { $fgAfter = [DshWin.Native]::GetForegroundWindow() } catch { }
      if ($fgAfter -ne $m.Hwnd) { try { [void][DshWin.Native]::CloseWindow($m.Hwnd) } catch { } }
    }
  }
}
