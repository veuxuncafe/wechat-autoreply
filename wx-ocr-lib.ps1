#requires -version 5.1
<#
  wx-ocr-lib.ps1 - local OCR + transcript building for the WeChat chat pane.

  Dot-source this file, then:
    Initialize-WxOcr                 -> loads the Windows OCR engine (zh-Hans-CN)
    Invoke-WxOcr -Path <png>         -> array of lines: Top/Left/Right/Bottom/H/Text
    Get-WxTranscript -Lines <lines>  -> contact title + message blocks with L/R sides

  Why: the OCR engine that ships with Windows reads the chat pane in ~0.2 s on the CPU,
  with no network and no model call. Feeding the model a text transcript instead of an
  image removes the vision pass (and the whole class of "which bubble is the newest"
  mistakes, because the side of each message is decided here, in code, by x position).
#>

$script:WxOcrEngine = $null
$script:WxOcrAsTask = $null

function Initialize-WxOcr {
  param([string]$Lang = 'zh-Hans-CN')

  if ($script:WxOcrEngine) { return $script:WxOcrEngine }

  Add-Type -AssemblyName System.Runtime.WindowsRuntime | Out-Null
  $script:WxOcrAsTask = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
      $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
    })[0]

  [void][Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime]
  [void][Windows.Graphics.Imaging.BitmapDecoder, Windows.Graphics.Imaging, ContentType = WindowsRuntime]
  [void][Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime]

  $engine = $null
  try {
    $language = New-Object Windows.Globalization.Language($Lang)
    $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage($language)
  } catch { }
  if (-not $engine) { $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages() }
  if (-not $engine) { throw 'no Windows OCR engine is available' }

  $script:WxOcrEngine = $engine
  return $engine
}

function Invoke-WxOcrAwait {
  param($Operation, [Type]$ResultType)
  $m = $script:WxOcrAsTask.MakeGenericMethod($ResultType)
  $t = $m.Invoke($null, @($Operation))
  $null = $t.Wait(-1)
  return $t.Result
}

function Invoke-WxOcr {
  param([Parameter(Mandatory = $true)][string]$Path)

  $engine = Initialize-WxOcr
  $full = (Resolve-Path -LiteralPath $Path).Path
  $sw = [System.Diagnostics.Stopwatch]::StartNew()

  $file = Invoke-WxOcrAwait ([Windows.Storage.StorageFile]::GetFileFromPathAsync($full)) ([Windows.Storage.StorageFile])
  $stream = Invoke-WxOcrAwait ($file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
  $decoder = Invoke-WxOcrAwait ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
  $bitmap = Invoke-WxOcrAwait ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
  $result = Invoke-WxOcrAwait ($engine.RecognizeAsync($bitmap)) ([Windows.Media.Ocr.OcrResult])
  $stream.Dispose()

  $out = New-Object System.Collections.ArrayList
  foreach ($ln in $result.Lines) {
    $top = [double]::MaxValue; $left = [double]::MaxValue; $right = 0; $bottom = 0
    foreach ($w in $ln.Words) {
      $r = $w.BoundingRect
      if ($r.Top -lt $top) { $top = $r.Top }
      if ($r.Left -lt $left) { $left = $r.Left }
      if (($r.Left + $r.Width) -gt $right) { $right = ($r.Left + $r.Width) }
      if (($r.Top + $r.Height) -gt $bottom) { $bottom = ($r.Top + $r.Height) }
    }
    [void]$out.Add([pscustomobject]@{
        Top    = [int]$top
        Left   = [int]$left
        Right  = [int]$right
        Bottom = [int]$bottom
        H      = [int]($bottom - $top)
        Text   = $ln.Text
      })
  }
  $sw.Stop()
  return [pscustomobject]@{
    Width  = $bitmap.PixelWidth
    Height = $bitmap.PixelHeight
    Ms     = $sw.ElapsedMilliseconds
    Lines  = $out.ToArray()
  }
}

# OCR splits CJK into separate "words"; the spaces it inserts are noise.
function Get-WxOcrClean {
  param([string]$Text)
  if (-not $Text) { return '' }
  return ($Text -replace ' ', '').Trim()
}

function Test-WxOcrTimestamp {
  param([string]$Text)
  $t = Get-WxOcrClean $Text
  if (-not $t) { return $true }
  # "20:12", "昨天22:34", "19:37" and OCR manglings of them (only digits, punctuation, C)
  return ($t -match '^[0-9０-９:：.,，、\-~℃°A-Za-z]{1,12}$')
}

<#
  Turns OCR lines into: the chat title, and the ordered message blocks with a side.
  Side comes from the x position of the text: their bubbles hug the left, mine the right.
#>
function Get-WxTranscript {
  param(
    [Parameter(Mandatory = $true)][object[]]$Lines,
    # Real image size. Deriving the width from the widest line is wrong: the avatar image
    # OCRs as a stray "0" far right, which inflated the width and pushed every fraction
    # (title band, noise filter, me/them split) so far out that the title and the contact's
    # newest bubble were both filtered away - the watcher went blind without saying so.
    [int]$ImageWidth = 0,
    [int]$ImageHeight = 0,
    # The header sits ~57px into the crop; a 20% band (183px) also swallowed the first
    # visible bubble, so the model never saw the message at the top of the screen.
    [double]$TitleZone = 0.12,
    [double]$LeftNoise = 0.10,
    [double]$MeSplit = 0.45
  )

  if (-not $Lines -or $Lines.Count -eq 0) {
    return [pscustomobject]@{ Title = ''; Blocks = @(); Transcript = ''; Height = 0; Width = 0 }
  }

  $width = if ($ImageWidth -gt 0) { $ImageWidth } else { ($Lines | Measure-Object -Property Right -Maximum).Maximum }
  $height = if ($ImageHeight -gt 0) { $ImageHeight } else { ($Lines | Measure-Object -Property Bottom -Maximum).Maximum }
  $titleMax = $TitleZone * $height
  $noiseMax = $LeftNoise * $width
  $meMin = $MeSplit * $width
  # My bubbles hug the right edge, theirs the left. A long multi-line message of mine starts
  # well left of MeSplit (measured x=357 of 1318), which used to label my own text "对方".
  $edge = 0.12 * $width

  # Title: the header row is the TOPMOST text in the crop. Picking the longest line in the
  # band instead used to grab a message bubble whenever the chat was scrolled so that a
  # message sat just under the header (measured: "大雨疯了" beat "好友" and a real round
  # was skipped as "wrong chat").
  $titleCands = @($Lines | Where-Object {
      $_.Top -lt $titleMax -and $_.Left -ge (0.03 * $width) -and $_.Left -le (0.55 * $width) -and
      -not (Test-WxOcrTimestamp $_.Text)
    } | Sort-Object Top)
  $title = ''
  foreach ($c in $titleCands) {
    $title = Get-WxOcrClean $c.Text
    if ($title) { break }
  }

  # Lines first: drop the title band, the session list bleed and the avatar glyphs, then group
  # consecutive lines that share a left edge into one bubble ("run"). The side is decided per
  # run from the widest line it reaches: a long multi-line message of mine starts far left of
  # MeSplit (measured x=357 of 1318) and its short lines end nowhere near the right margin, so
  # a per-line rule labelled my own text "对方" and the watcher answered itself.
  $kept = New-Object System.Collections.ArrayList
  $forceBreak = $true
  foreach ($l in ($Lines | Sort-Object Top)) {
    if ($l.Top -lt $titleMax) { continue }
    if ($l.Left -lt $noiseMax) { continue }   # session list bleeding into the crop
    if ($l.Left -gt (0.90 * $width)) { continue }   # my avatar image, OCR reads glyphs off it
    $text = Get-WxOcrClean $l.Text
    if (-not $text) { continue }
    if (Test-WxOcrTimestamp $l.Text) { $forceBreak = $true; continue }
    [void]$kept.Add([pscustomobject]@{ Text = $text; Left = $l.Left; Right = $l.Right; Top = $l.Top; Break = $forceBreak })
    $forceBreak = $false
  }

  $tol = 0.06 * $width
  $runs = New-Object System.Collections.ArrayList
  foreach ($k in $kept) {
    $r = $null
    if ($runs.Count -gt 0) { $r = $runs[$runs.Count - 1] }
    if (-not $r -or $k.Break -or [Math]::Abs($k.Left - $r.Left) -gt $tol -or [Math]::Abs($k.Right - $r.MaxRight) -gt (0.40 * $width)) {
      $r = [pscustomobject]@{ Left = $k.Left; MaxRight = $k.Right; Top = $k.Top; Parts = @($k.Text) }
      [void]$runs.Add($r)
    } else {
      if ($k.Right -gt $r.MaxRight) { $r.MaxRight = $k.Right }
      $r.Parts = @($r.Parts) + $k.Text
    }
  }

  $blocks = New-Object System.Collections.ArrayList
  $cur = $null
  foreach ($r in $runs) {
    $side = if (($width - $r.MaxRight) -le $edge) { 'me' }
    elseif ($r.Left -le $edge) { 'them' }
    elseif ($r.Left -ge $meMin) { 'me' }
    else { 'them' }
    if ($cur -and $cur.Side -eq $side) {
      foreach ($part in $r.Parts) {
        $join = if ($cur.Text -match '[\u4e00-\u9fff]$' -and $part -match '^[\u4e00-\u9fff]') { '' } else { ' ' }
        $cur.Text = $cur.Text + $join + $part
      }
    } else {
      $cur = [pscustomobject]@{ Side = $side; Text = ($r.Parts -join ' '); Top = $r.Top }
      [void]$blocks.Add($cur)
    }
  }

  $sb = New-Object System.Text.StringBuilder
  [void]$sb.AppendLine('标题: ' + $title)
  foreach ($b in $blocks) {
    [void]$sb.AppendLine(('[{0}] {1}' -f $(if ($b.Side -eq 'me') { '我' } else { '对方' }), $b.Text))
  }

  return [pscustomobject]@{
    Title      = $title
    Blocks     = $blocks.ToArray()
    Transcript = $sb.ToString().TrimEnd()
    Width      = $width
    Height     = $height
  }
}
