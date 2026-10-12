# make-icon.ps1 - draws the console logo and writes a multi-size .ico
#
#   powershell -File make-icon.ps1 -Sheet                      # comparison sheet of every style
#   powershell -File make-icon.ps1 -Style bolt -OutIco ""       # write assets\icon.ico in one style
#
# Styles: bubble (green tile, white bubble) | bolt (instant reply)
#         dark   (dark tile, green bubble)  | circle (round tile)
# Pure ASCII on purpose: no BOM needed.
param(
  [string]$Style = 'bubble',
  [string]$OutIco = '',
  [string]$Preview = '',
  [int]$PreviewSize = 256,
  [switch]$Sheet,
  [string]$SheetPath = ''
)

Add-Type -AssemblyName System.Drawing

$script:Root = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }

function Col {
  param([int]$r, [int]$g, [int]$b, [int]$a = 255)
  return [System.Drawing.Color]::FromArgb($a, $r, $g, $b)
}

function New-RoundedRect {
  param([single]$x, [single]$y, [single]$w, [single]$h, [single]$r)
  if ($r -lt 0.01) { $r = 0.01 }
  $d = [single]($r * 2)
  if ($d -gt $w) { $d = $w }
  if ($d -gt $h) { $d = $h }
  $p = New-Object System.Drawing.Drawing2D.GraphicsPath
  $p.FillMode = [System.Drawing.Drawing2D.FillMode]::Winding
  $p.AddArc($x, $y, $d, $d, 180, 90)
  $p.AddArc(($x + $w - $d), $y, $d, $d, 270, 90)
  $p.AddArc(($x + $w - $d), ($y + $h - $d), $d, $d, 0, 90)
  $p.AddArc($x, ($y + $h - $d), $d, $d, 90, 90)
  $p.CloseFigure()
  return $p
}

function New-CirclePath {
  param([single]$s)
  $p = New-Object System.Drawing.Drawing2D.GraphicsPath
  $p.AddEllipse([single]0.5, [single]0.5, ($s - 1), ($s - 1))
  return $p
}

function New-VGradient3 {
  param([single]$s, [System.Drawing.Color]$c1, [System.Drawing.Color]$c2, [System.Drawing.Color]$c3)
  $br = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
    (New-Object System.Drawing.PointF(0, 0)),
    (New-Object System.Drawing.PointF(0, $s)), $c1, $c3)
  $blend = New-Object System.Drawing.Drawing2D.ColorBlend(3)
  $blend.Colors = @($c1, $c2, $c3)
  $blend.Positions = @([single]0.0, [single]0.52, [single]1.0)
  $br.InterpolationColors = $blend
  return $br
}

function Add-Highlight {
  param($g, $path, [single]$s, [int]$alpha = 44)
  $pg = New-Object System.Drawing.Drawing2D.PathGradientBrush($path)
  $pg.CenterPoint = New-Object System.Drawing.PointF(([single]0.30 * $s), ([single]0.22 * $s))
  $pg.CenterColor = (Col 255 255 255 $alpha)
  $pg.SurroundColors = @((Col 255 255 255 0))
  $g.FillPath($pg, $path)
  $pg.Dispose()
}

function New-BubblePath {
  param([single]$x, [single]$y, [single]$w, [single]$h, [single]$s, [single]$dy = 0)
  $y = $y + $dy
  $p = New-RoundedRect $x $y $w $h ([single]($h * 0.34))
  # classic tail: a wide base inside the bubble, tapering to a tip below the bottom edge
  $ty = $y + $h - ([single]0.10 * $h)
  $tl = $x + $w * 0.28
  $tt = $tl + $w * 0.05
  $tr = $x + $w * 0.56
  # wind right-top -> tip -> left-top so the winding matches the rounded rect
  # (opposite winding cancels the overlap and the tile shows through as a seam)
  $pts = @(
    (New-Object System.Drawing.PointF($tr, $ty)),
    (New-Object System.Drawing.PointF($tt, ($y + $h + [single]0.090 * $s))),
    (New-Object System.Drawing.PointF($tl, $ty))
  )
  $p.AddPolygon($pts)
  # alternate fill counts the overlap of bubble and tail twice -> a hole right where
  # they meet (that was the bright green seam); winding fills the union solid.
  $p.FillMode = [System.Drawing.Drawing2D.FillMode]::Winding
  return $p
}

function Add-Dots {
  param($g, [single]$s, [single]$cy, [System.Drawing.Color]$c, [int]$count = 3)
  # dots have to stay readable when the shell asks for a 16-32px icon,
  # so they grow (relatively) as the canvas shrinks
  $rNorm = if ($s -le 24) { 0.075 } elseif ($s -le 40) { 0.062 } elseif ($s -le 64) { 0.050 } else { 0.038 }
  $gapNorm = if ($s -le 24) { 0.150 } elseif ($s -le 40) { 0.135 } elseif ($s -le 64) { 0.120 } else { 0.104 }
  $r = [single]($s * $rNorm)
  $gap = [single]($s * $gapNorm)
  $cx = $s / 2
  $br = New-Object System.Drawing.SolidBrush($c)
  if ($count -eq 2) {
    foreach ($dx in @(-($gap / 2), ($gap / 2))) {
      $g.FillEllipse($br, ($cx + $dx - $r), ($cy - $r), ($r * 2), ($r * 2))
    }
  } else {
    foreach ($dx in @(-$gap, 0, $gap)) {
      $g.FillEllipse($br, ($cx + $dx - $r), ($cy - $r), ($r * 2), ($r * 2))
    }
  }
  $br.Dispose()
}

function Get-LogoBitmap {
  param([int]$Size, [string]$Style)
  $s = [single]$Size
  $bmp = New-Object System.Drawing.Bitmap($Size, $Size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
  $g.Clear([System.Drawing.Color]::Transparent)

  $white = Col 255 255 255
  $deep = Col 4 120 87
  $dotCount = if ($Size -le 22) { 2 } else { 3 }
  $bw = [single]($s * 0.58)
  $bh = [single]($s * 0.38)
  $bx = ($s - $bw) / 2
  $by = ($s * 0.462) - $bh / 2
  $cy = $s * 0.462 - ([single]0.012 * $s)
  $dotCol = $deep

  if ($Style -eq 'circle') {
    $tile = New-CirclePath $s
    $grad = New-VGradient3 $s (Col 61 219 160) (Col 16 185 129) (Col 4 143 100)
  } else {
    $tile = New-RoundedRect 0.5 0.5 ($s - 1) ($s - 1) ([single]($s * 0.255))
    $grad = New-VGradient3 $s (Col 61 219 160) (Col 16 185 129) (Col 4 143 100)
  }

  if ($Style -eq 'line') {
    $g.FillPath((New-VGradient3 $s (Col 255 255 255) (Col 240 243 247) (Col 229 233 239)), $tile)
    $pen = New-Object System.Drawing.Pen((Col 224 228 233), [single][Math]::Max(1, $s * 0.006))
    $g.DrawPath($pen, $tile)
    $pen.Dispose()
    $green = Col 16 185 129
    $stroke = New-Object System.Drawing.Pen($green, [single][Math]::Max(1.4, $s * 0.052))
    $stroke.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
    $bp = New-BubblePath $bx $by $bw $bh $s
    $g.DrawPath($stroke, $bp)
    $stroke.Dispose(); $bp.Dispose()
    Add-Dots $g $s $cy $green $dotCount
  }
  elseif ($Style -eq 'dark') {
    $g.FillPath((New-VGradient3 $s (Col 43 54 72) (Col 30 41 59) (Col 17 24 39)), $tile)
    Add-Highlight $g $tile $s 30
    $bp = New-BubblePath $bx $by $bw $bh $s
    $g.FillPath((New-VGradient3 ($by + $bh) (Col 61 219 160) (Col 16 185 129) (Col 4 143 100)), $bp)
    $bp.Dispose()
    Add-Dots $g $s $cy $white $dotCount
  }
  else {
    $g.FillPath($grad, $tile)
    Add-Highlight $g $tile $s 44
    if ($Style -eq 'bolt') {
      $bp = New-BubblePath $bx $by $bw $bh $s
      $g.FillPath((New-Object System.Drawing.SolidBrush($white)), $bp)
      $bp.Dispose()
      $u = [single]($s * 0.23)
      $cx = $s / 2
      $pts = @(
        (New-Object System.Drawing.PointF(($cx + [single]0.16 * $u), ($cy - [single]0.98 * $u))),
        (New-Object System.Drawing.PointF(($cx - [single]0.60 * $u), ($cy + [single]0.14 * $u))),
        (New-Object System.Drawing.PointF(($cx - [single]0.04 * $u), ($cy + [single]0.14 * $u))),
        (New-Object System.Drawing.PointF(($cx - [single]0.22 * $u), ($cy + [single]0.98 * $u))),
        (New-Object System.Drawing.PointF(($cx + [single]0.60 * $u), ($cy - [single]0.26 * $u))),
        (New-Object System.Drawing.PointF(($cx + [single]0.04 * $u), ($cy - [single]0.26 * $u)))
      )
      $g.FillPolygon((New-Object System.Drawing.SolidBrush($deep)), $pts)
    }
    else {
      $bp = New-BubblePath $bx $by $bw $bh $s
      $g.FillPath((New-Object System.Drawing.SolidBrush($white)), $bp)
      $bp.Dispose()
      Add-Dots $g $s $cy $dotCol $dotCount
    }
  }

  $tile.Dispose()
  $grad.Dispose()
  $g.Dispose()
  return $bmp
}

function Get-IconEntryBytes {
  param([System.Drawing.Bitmap]$Bmp)
  $w = $Bmp.Width; $h = $Bmp.Height
  $maskRow = [int]([Math]::Floor(($w + 31) / 32) * 4)
  $xorSize = $w * $h * 4
  $andSize = $maskRow * $h
  $ms = New-Object System.IO.MemoryStream
  $bw = New-Object System.IO.BinaryWriter($ms)
  $bw.Write([uint32]40)
  $bw.Write([int32]$w)
  $bw.Write([int32]($h * 2))
  $bw.Write([uint16]1)
  $bw.Write([uint16]32)
  $bw.Write([uint32]0)
  $bw.Write([uint32]($xorSize + $andSize))
  $bw.Write([int32]0); $bw.Write([int32]0); $bw.Write([uint32]0); $bw.Write([uint32]0)
  $rect = New-Object System.Drawing.Rectangle(0, 0, $w, $h)
  $data = $Bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $stride = $data.Stride
  $row = New-Object byte[] $stride
  try {
    for ($y = $h - 1; $y -ge 0; $y--) {
      [System.Runtime.InteropServices.Marshal]::Copy([IntPtr]::Add($data.Scan0, $y * $stride), $row, 0, $stride)
      $bw.Write($row, 0, ($w * 4))
    }
  } finally {
    $Bmp.UnlockBits($data)
  }
  $zero = New-Object byte[] $andSize
  $bw.Write($zero, 0, $andSize)
  $bw.Flush()
  $out = $ms.ToArray()
  $bw.Dispose(); $ms.Dispose()
  return $out
}

function Write-IcoFile {
  param([string]$Path, [int[]]$Sizes, [string]$Style)
  $entries = New-Object System.Collections.ArrayList
  foreach ($sz in $Sizes) {
    $bmp = Get-LogoBitmap -Size $sz -Style $Style
    $bytes = Get-IconEntryBytes $bmp
    $bmp.Dispose()
    [void]$entries.Add([pscustomobject]@{ Size = $sz; Bytes = $bytes })
  }
  $ms = New-Object System.IO.MemoryStream
  $bw = New-Object System.IO.BinaryWriter($ms)
  $bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$entries.Count)
  $offset = 6 + 16 * $entries.Count
  foreach ($e in $entries) {
    $dim = if ($e.Size -ge 256) { 0 } else { $e.Size }
    $bw.Write([byte]$dim); $bw.Write([byte]$dim)
    $bw.Write([byte]0); $bw.Write([byte]0)
    $bw.Write([uint16]1); $bw.Write([uint16]32)
    $bw.Write([uint32]$e.Bytes.Length)
    $bw.Write([uint32]$offset)
    $offset += $e.Bytes.Length
  }
  foreach ($e in $entries) { $bw.Write($e.Bytes, 0, $e.Bytes.Length) }
  $bw.Flush()
  $all = $ms.ToArray()
  $bw.Dispose(); $ms.Dispose()
  $dir = Split-Path -Parent $Path
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
  [System.IO.File]::WriteAllBytes($Path, $all)
  Write-Output ("ico: {0}  {1} bytes  style={2}  sizes={3}" -f $Path, $all.Length, $Style, ($Sizes -join ','))
}

function Write-StyleSheet {
  param([string]$Path)
  $styles = @(
    @{ Id = 'bubble'; Label = 'A  bubble' },
    @{ Id = 'bolt';   Label = 'B  bolt' },
    @{ Id = 'dark';   Label = 'C  dark' },
    @{ Id = 'circle'; Label = 'D  circle' },
    @{ Id = 'line';   Label = 'E  line' }
  )
  $big = 150; $smalls = @(64, 48, 32, 16)
  $pad = 18; $labelW = 96
  $width = $pad + $labelW + $big + 24
  foreach ($sz in $smalls) { $width += $sz + 14 }
  $width += $pad
  $rowH = $big + 26
  $height = $pad + $rowH * $styles.Count + $pad
  $sheet = New-Object System.Drawing.Bitmap([int]$width, [int]$height)
  $g = [System.Drawing.Graphics]::FromImage($sheet)
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $g.Clear((Col 255 255 255))
  $font = New-Object System.Drawing.Font('Segoe UI', 10)
  $brush = New-Object System.Drawing.SolidBrush((Col 60 66 76))
  $y = $pad
  foreach ($st in $styles) {
    $g.DrawString($st.Label, $font, $brush, [single]$pad, [single]($y + $big / 2 - 10))
    $x = $pad + $labelW
    $bmp = Get-LogoBitmap -Size $big -Style $st.Id
    $g.DrawImage($bmp, [single]$x, [single]$y, [single]$big, [single]$big)
    $bmp.Dispose()
    $x += $big + 24
    foreach ($sz in $smalls) {
      $b = Get-LogoBitmap -Size $sz -Style $st.Id
      $g.DrawImage($b, [single]$x, [single]($y + $big - $sz), [single]$sz, [single]$sz)
      $b.Dispose()
      $x += $sz + 14
    }
    $y += $rowH
  }
  $font.Dispose(); $brush.Dispose(); $g.Dispose()
  $sheet.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
  $sheet.Dispose()
  Write-Output ("sheet: {0}" -f $Path)
}

if ($Sheet) {
  $sp = if ($SheetPath) { $SheetPath } else { Join-Path $script:Root 'assets\icon-styles.png' }
  Write-StyleSheet $sp
}
if ($OutIco) {
  $p = if ([System.IO.Path]::IsPathRooted($OutIco)) { $OutIco } else { Join-Path $script:Root $OutIco }
  Write-IcoFile -Path $p -Sizes @(16, 20, 24, 32, 40, 48, 64, 128, 256) -Style $Style
  $chk = [System.Drawing.Icon]::new($p)
  Write-Output ("  verify: base={0}x{1}" -f $chk.Width, $chk.Height)
  $chk.Dispose()
}
if ($Preview) {
  $p = if ([System.IO.Path]::IsPathRooted($Preview)) { $Preview } else { Join-Path $script:Root $Preview }
  $bmp = Get-LogoBitmap -Size $PreviewSize -Style $Style
  $bmp.Save($p, [System.Drawing.Imaging.ImageFormat]::Png)
  $bmp.Dispose()
  Write-Output ("preview: {0} ({1}px)" -f $p, $PreviewSize)
}
