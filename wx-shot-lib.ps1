# wx-shot-lib.ps1 - silent capture of the WeChat window (or one layout area) to a PNG.
# READ-ONLY: never clicks, never types, never sends.
#
# Dot-source this file, then call:
#   Invoke-WxShot -Area chatctx [-Upscale 1] [-Method PrintWindow|Screen] [-KeepForeground]
# It returns a status object (Ok, File, Latest, Width, Height, Bytes, Sha16, Blank,
# ForegroundOk, Method, Notes, Error, ExitCode). Both wx-capture.ps1 (CLI) and wx-watch.ps1
# (the loop) go through this one implementation, so an in-process capture costs no child
# PowerShell start-up (~1s saved per event).
#
# Capture method: WeChat 4.x draws through a GPU-composited mmui surface, so a plain screen
# grab only sees whatever happens to be on top of it. PrintWindow with PW_RENDERFULLCONTENT
# (flag 2) asks the window to render into our bitmap: it works while WeChat sits behind
# other windows and never touches the foreground window. -Method Screen is a fallback that
# does need WeChat in front; focus is handed back right afterwards unless -KeepForeground.

if (-not (Get-Command Get-WxMainWindow -ErrorAction SilentlyContinue)) {
  . (Join-Path $PSScriptRoot 'wx-core.ps1')
}
Add-Type -AssemblyName System.Drawing

function Test-DshImageBlank {
  param([string]$Path, [int]$MinColors = 6)
  $b = New-Object System.Drawing.Bitmap($Path)
  $set = New-Object 'System.Collections.Generic.HashSet[int]'
  for ($y = 0; $y -lt $b.Height; $y += 9) {
    for ($x = 0; $x -lt $b.Width; $x += 9) {
      $c = $b.GetPixel($x, $y)
      [void]$set.Add(($c.R -shl 16) -bor ($c.G -shl 8) -bor $c.B)
    }
  }
  $n = $set.Count
  $b.Dispose()
  return ($n -lt $MinColors)
}

function Invoke-WxShot {
  param(
    [ValidateSet('window', 'chat', 'chatctx', 'input', 'list', 'header', 'send')][string]$Area = 'window',
    [int]$Upscale = 1,
    [ValidateSet('PrintWindow', 'Screen')][string]$Method = 'PrintWindow',
    [switch]$KeepForeground
  )

  $notes = New-Object System.Collections.ArrayList
  $fail = {
    param([string]$msg, [int]$code)
    return [pscustomobject]@{
      Ok = $false; Error = $msg; ExitCode = $code; Notes = @(); Area = $Area; Method = $Method
      File = ''; Latest = ''; Width = 0; Height = 0; Bytes = 0; Sha16 = ''; Blank = $true
      ForegroundOk = $false; Window = ''
    }
  }

  $m = Get-WxMainWindow
  if (-not $m) { return (& $fail 'WeChat main window not found (tray only?)' 3) }

  # A minimized window reports a meaningless client rect, so un-minimize it first. This
  # restore is silent (SW_SHOWNOACTIVATE): it does not steal the user's focus.
  if ($m.Minimized) {
    [void](Restore-WxWindow -Hwnd $m.Hwnd -NoActivate)
    $m = Get-WxMainWindow
    if (-not $m) { return (& $fail 'WeChat window vanished after restore.' 3) }
  }

  $prevFg = [IntPtr]::Zero
  $fgOk = $true
  if ($Method -eq 'Screen') {
    $prevFg = [DshWin.Native]::GetForegroundWindow()
    [void](Set-DshForeground -Hwnd $m.Hwnd)
    Start-Sleep -Milliseconds 350
    $fgOk = ([DshWin.Native]::GetForegroundWindow() -eq $m.Hwnd)
  }

  $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
  $dir = Get-WxShotDir
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }

  $full = Join-Path $dir ('win-' + $stamp + '.png')
  [void](Save-DshWindowCapture -Hwnd $m.Hwnd -OutFile $full -Method $Method)

  # PrintWindow can answer with a black frame if the window is mid-repaint; fall back once.
  $blank = Test-DshImageBlank -Path $full
  if ($blank -and $Method -eq 'PrintWindow') {
    [void]$notes.Add('PrintWindow produced a blank frame, retrying once in 600ms')
    Start-Sleep -Milliseconds 600
    [void](Save-DshWindowCapture -Hwnd $m.Hwnd -OutFile $full -Method $Method)
    $blank = Test-DshImageBlank -Path $full
  }
  if ($blank -and $Method -eq 'PrintWindow') {
    [void]$notes.Add('still blank, falling back to Screen (this briefly foregrounds WeChat)')
    $Method = 'Screen'
    $prevFg = [DshWin.Native]::GetForegroundWindow()
    [void](Set-DshForeground -Hwnd $m.Hwnd)
    Start-Sleep -Milliseconds 350
    $fgOk = ([DshWin.Native]::GetForegroundWindow() -eq $m.Hwnd)
    [void](Save-DshWindowCapture -Hwnd $m.Hwnd -OutFile $full -Method 'Screen')
    # $blank has to be recomputed here: it still describes the failed PrintWindow frame, and
    # a stale "blank" would make callers throw away a perfectly good capture.
    $blank = Test-DshImageBlank -Path $full
  }

  # pixels are on disk now; hand the user's focus back if we took it
  if ($Method -eq 'Screen' -and -not $KeepForeground -and $prevFg -ne [IntPtr]::Zero -and $prevFg -ne $m.Hwnd) {
    try { [void](Set-DshForeground -Hwnd $prevFg) } catch { }
  }

  $bmp = New-Object System.Drawing.Bitmap($full)
  $crop = $null
  switch ($Area) {
    'chat'   { $crop = Get-WxAnchor -Name msgRect }
    'chatctx' { $crop = Get-WxAnchor -Name chatctxRect }
    'input'  { $crop = Get-WxAnchor -Name inputRect }
    'list'   { $crop = Get-WxAnchor -Name listRect }
    'header' { $p = Get-WxAnchor -Name header; $crop = [pscustomobject]@{ X = $p.X - 120; Y = $p.Y - 45; W = 520; H = 90 } }
    'send'   { $b = Get-WxSendButton; $crop = [pscustomobject]@{ X = $b.X - 170; Y = $b.Y - 130; W = 340; H = 260 } }
  }

  $outFile = $full
  $w = $bmp.Width; $h = $bmp.Height
  if ($crop) {
    # convert screen coords -> image coords (image origin == window rect origin)
    $x = [int]($crop.X - $m.Left); $y = [int]($crop.Y - $m.Top)
    $cw = [int]$crop.W; $ch = [int]$crop.H
    if ($x -lt 0) { $cw += $x; $x = 0 }
    if ($y -lt 0) { $ch += $y; $y = 0 }
    if ($x + $cw -gt $w) { $cw = $w - $x }
    if ($y + $ch -gt $h) { $ch = $h - $y }
    if ($cw -le 0 -or $ch -le 0) { $bmp.Dispose(); return (& $fail 'crop rect empty.' 4) }
    $r = New-Object System.Drawing.Rectangle($x, $y, $cw, $ch)
    $cropped = $bmp.Clone($r, $bmp.PixelFormat)
    $outFile = Join-Path $dir ($Area + '-' + $stamp + '.png')
    $latest = Join-Path $dir ($Area + '-latest.png')
    $cropped.Save($outFile, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    if ($Upscale -gt 1) {
      $src = New-Object System.Drawing.Bitmap($outFile)
      $big = New-Object System.Drawing.Bitmap(($src.Width * $Upscale), ($src.Height * $Upscale))
      $g = [System.Drawing.Graphics]::FromImage($big)
      $g.InterpolationMode = 'NearestNeighbor'
      $g.DrawImage($src, 0, 0, $big.Width, $big.Height)
      $g.Dispose(); $src.Dispose()
      $big.Save($outFile, [System.Drawing.Imaging.ImageFormat]::Png)
      $big.Dispose()
    }
    Copy-Item -Path $outFile -Destination $latest -Force
    $bmp = New-Object System.Drawing.Bitmap($outFile)
  } else {
    $latest = Join-Path $dir ('window-latest.png')
    Copy-Item -Path $outFile -Destination $latest -Force
  }

  # Change detection has to survive the sub-pixel antialiasing differences that two
  # PrintWindow renders of one static frame can produce, so hash a strongly downscaled copy
  # instead of the raw PNG bytes: at 1/8 scale a new chat bubble still moves the hash, text
  # rendering noise does not.
  $sw = [int][Math]::Max(1, ($bmp.Width / 8))
  $sh = [int][Math]::Max(1, ($bmp.Height / 8))
  $small = New-Object System.Drawing.Bitmap($sw, $sh)
  $sg = [System.Drawing.Graphics]::FromImage($small)
  $sg.InterpolationMode = 'HighQualityBilinear'
  $sg.DrawImage($bmp, 0, 0, $sw, $sh)
  # The window buttons in the top-right corner repaint whenever WeChat gains or loses
  # activation (the Screen fallback raises the window). Measured effect: the hash flipped
  # between two values every round, burning a model call each time. Paint that corner a
  # constant colour before hashing so activation changes cannot look like a message.
  $maskW = [int][Math]::Max(1, ($sw * 0.10))
  $maskH = [int][Math]::Max(1, ($sh * 0.06))
  $sg.FillRectangle([System.Drawing.Brushes]::Black, ($sw - $maskW), 0, $maskW, $maskH)
  $sg.Dispose()
  $ms = New-Object System.IO.MemoryStream
  $small.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
  $small.Dispose()
  $shaBytes = [System.Security.Cryptography.SHA256]::Create().ComputeHash($ms.ToArray())
  $ms.Dispose()
  $sha = -join ($shaBytes[0..7] | ForEach-Object { $_.ToString('X2') })

  $info = [pscustomobject]@{
    Ok           = $true
    Error        = ''
    ExitCode     = 0
    Notes        = $notes.ToArray()
    Area         = $Area
    Method       = $Method
    File         = $outFile
    Latest       = $latest
    Width        = $bmp.Width
    Height       = $bmp.Height
    Bytes        = (Get-Item $outFile).Length
    Sha16        = $sha
    Stamp        = $stamp
    Blank        = $blank
    ForegroundOk = $fgOk
    Window       = ('{0},{1} {2}x{3}' -f $m.Left, $m.Top, $m.Width, $m.Height)
  }
  $bmp.Dispose()
  return $info
}
