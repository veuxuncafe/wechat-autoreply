param(
  [ValidateSet('install-shortcuts', 'remove-shortcuts', 'autostart-on', 'autostart-off', 'status')]
  [string]$Action = 'status'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSCommandPath
$exe = Join-Path $root 'wx-panel.exe'
$daemon = Join-Path $root 'wx-watch-daemon.ps1'
$name = '微信自动回复'
$desktopLnk = Join-Path ([Environment]::GetFolderPath('Desktop')) ($name + '.lnk')
$startLnk = Join-Path ([Environment]::GetFolderPath('Programs')) ($name + '.lnk')
$startupCmd = Join-Path ([Environment]::GetFolderPath('Startup')) ($name + '（后台）.cmd')
$oldDesktop = Join-Path ([Environment]::GetFolderPath('Desktop')) '微信自动回复控制台.lnk'
$oldStartup = Join-Path ([Environment]::GetFolderPath('Startup')) 'dsh-wechat-autoreply.cmd.disabled'

function New-Lnk([string]$path) {
  $ws = New-Object -ComObject WScript.Shell
  $lnk = $ws.CreateShortcut($path)
  $lnk.TargetPath = $exe
  $lnk.WorkingDirectory = $root
  $lnk.IconLocation = "$exe,0"
  $lnk.Description = '微信自动回复控制台'
  $lnk.Save()
}

function Remove-Quiet([string]$path) {
  if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue; Write-Output ("removed: {0}" -f $path) }
}

switch ($Action) {
  'install-shortcuts' {
    New-Lnk $desktopLnk
    New-Lnk $startLnk
    Remove-Quiet $oldDesktop
    Remove-Quiet $oldStartup
    Write-Output ("shortcuts: desktop + start menu -> {0}" -f $exe)
  }
  'remove-shortcuts' {
    Remove-Quiet $desktopLnk
    Remove-Quiet $startLnk
    Remove-Quiet $startupCmd
    Remove-Quiet $oldDesktop
    Remove-Quiet $oldStartup
    Write-Output 'shortcuts removed. The app folder itself was left untouched.'
  }
  'autostart-on' {
    $cmd = '@echo off' + "`r`n" + 'rem start the WeChat auto-reply bot in the background at sign-in' + "`r`n" +
           ('start "" /min powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -IntervalSec 5' -f $daemon) + "`r`n"
    [System.IO.File]::WriteAllText($startupCmd, $cmd, (New-Object System.Text.ASCIIEncoding))
    Write-Output ("autostart ON -> {0}" -f $startupCmd)
  }
  'autostart-off' {
    Remove-Quiet $startupCmd
    Write-Output 'autostart OFF'
  }
  'status' {
    Write-Output ("app folder      : {0}" -f $root)
    Write-Output ("launcher        : {0} ({1})" -f $exe, (Test-Path -LiteralPath $exe))
    Write-Output ("desktop shortcut: {0} ({1})" -f $desktopLnk, (Test-Path -LiteralPath $desktopLnk))
    Write-Output ("start menu      : {0} ({1})" -f $startLnk, (Test-Path -LiteralPath $startLnk))
    Write-Output ("autostart       : {0} ({1})" -f $startupCmd, (Test-Path -LiteralPath $startupCmd))
  }
}