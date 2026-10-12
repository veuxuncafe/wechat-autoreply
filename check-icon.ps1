# check-icon.ps1 - read the desktop shortcut's icon back the same way Explorer does
#   powershell -File check-icon.ps1
# Checks: assets\icon.ico loads -> wx-panel.exe carries the icon -> the .lnk points at it
# and shows the exe's icon. Writes assets\icon-check.png (upscaled 32px view).
param([string]$Out = '')

Add-Type -AssemblyName System.Drawing

$root = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$assets = Join-Path $root 'assets'
$ico = Join-Path $assets 'icon.ico'
$exe = Join-Path $root 'wx-panel.exe'
if (-not $Out) { $Out = Join-Path $assets 'icon-check.png' }

function Get-ColorStats {
  param([System.Drawing.Bitmap]$Bmp)
  $green = 0; $white = 0; $other = 0
  for ($y = 0; $y -lt $Bmp.Height; $y++) {
    for ($x = 0; $x -lt $Bmp.Width; $x++) {
      $c = $Bmp.GetPixel($x, $y)
      if ($c.G -gt 140 -and $c.R -lt 130 -and $c.B -lt 190) { $green++ }
      elseif ($c.R -gt 215 -and $c.G -gt 215 -and $c.B -gt 215) { $white++ }
      else { $other++ }
    }
  }
  return @{ Green = $green; White = $white; Other = $other }
}

function New-Upscale {
  param([System.Drawing.Bitmap]$Bmp, [int]$Target, [string]$Path)
  $dst = New-Object System.Drawing.Bitmap($Target, $Target)
  $g = [System.Drawing.Graphics]::FromImage($dst)
  $g.Clear([System.Drawing.Color]::White)
  $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
  $g.DrawImage($Bmp, 0, 0, $Target, $Target)
  $g.Dispose()
  $dst.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
  $dst.Dispose()
}

Write-Output ("icon file : {0} exists={1}" -f $ico, (Test-Path -LiteralPath $ico))
$ok = $false
if (Test-Path -LiteralPath $ico) {
  try {
    $i = New-Object System.Drawing.Icon($ico, 32, 32)
    $b = $i.ToBitmap()
    $s = Get-ColorStats $b
    Write-Output ("  .ico 32px   green={0} white={1} other={2}" -f $s.Green, $s.White, $s.Other)
    New-Upscale -Bmp $b -Target 128 -Path (Join-Path $assets 'icon-check-ico.png')
    $b.Dispose(); $i.Dispose()
    $ok = $true
  } catch {
    Write-Output ("  .ico load FAILED: {0}" -f $_.Exception.Message)
  }
}

Write-Output ("launcher  : {0} exists={1}" -f $exe, (Test-Path -LiteralPath $exe))
if (Test-Path -LiteralPath $exe) {
  try {
    $xi = [System.Drawing.Icon]::ExtractAssociatedIcon($exe)
    $xb = $xi.ToBitmap()
    $xs = Get-ColorStats $xb
    Write-Output ("  exe icon    green={0} white={1} other={2}   <- what the shell draws" -f $xs.Green, $xs.White, $xs.Other)
    New-Upscale -Bmp $xb -Target 128 -Path $Out
    Write-Output ("  preview     {0}" -f $Out)
    $xb.Dispose(); $xi.Dispose()
  } catch {
    Write-Output ("  exe icon FAILED: {0}" -f $_.Exception.Message)
  }
}

# find the shortcut by what it launches (its name is Chinese, and this file is ASCII on purpose)
$desktop = [Environment]::GetFolderPath('Desktop')
$shell = New-Object -ComObject WScript.Shell
$lnk = ''
foreach ($f in @(Get-ChildItem -LiteralPath $desktop -Filter *.lnk -File -ErrorAction SilentlyContinue)) {
  $cand = $shell.CreateShortcut($f.FullName)
  if ($cand.TargetPath -ieq $exe) { $lnk = $f.FullName; break }
}
Write-Output ("shortcut  : {0} found={1}" -f $lnk, [bool]$lnk)
if (Test-Path -LiteralPath $lnk) {
  $sh = New-Object -ComObject WScript.Shell
  $sc = $sh.CreateShortcut($lnk)
  Write-Output ("  target    = {0}" -f $sc.TargetPath)
  Write-Output ("  icon      = {0}" -f $sc.IconLocation)
  Write-Output ("  points at the launcher = {0}" -f ($sc.TargetPath -ieq $exe))
  Write-Output ("  icon is the launcher's = {0}" -f ($sc.IconLocation -like "$exe*"))
}

if (-not $ok) { Write-Output 'RESULT: the .ico itself does not load - rebuild with build-icon.ps1' }
