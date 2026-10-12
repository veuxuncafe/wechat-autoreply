#requires -version 5.1
<#
  wx-watch-daemon.ps1 - keeps exactly one wx-watch.ps1 loop alive.

  The Windows scheduled task "DSH-WeChat-AutoReply" fires this every 15 minutes. A named
  mutex makes every firing after the first a no-op, so the loop keeps running across the
  ticks while a dead loop is restarted by the next tick. The loop itself never sends
  anything unless state\mode.txt says "live".
#>
param(
  [int]$IntervalSec = 20,
  [int]$MaxRounds = 0
)

$ErrorActionPreference = 'Continue'
$here = $PSScriptRoot

# a start always wins over a leftover stop request: clear it once, here, so a
# manual (or autostart) launch is never killed by a flag from a previous stop
$staleFlag = Join-Path $here 'state\stop.flag'
if (Test-Path -LiteralPath $staleFlag) {
  Remove-Item -LiteralPath $staleFlag -Force -ErrorAction SilentlyContinue
  Say 'cleared a leftover stop flag from an earlier stop'
}
$logDir = Join-Path $here 'logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
$log = Join-Path $logDir 'daemon.log'

function Say {
  param([string]$Message)
  Add-Content -LiteralPath $log -Value ('{0} | {1}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Message) -Encoding UTF8
}

$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, 'Local\DSH-WeChat-AutoReply', [ref]$createdNew)
if (-not $createdNew) {
  # Another watcher already owns the mutex: this tick has nothing to do.
  exit 0
}

try {
  Say ('starting watcher: interval={0}s daemon-pid={1} (the watcher is the child process below)' -f $IntervalSec, $PID)
  while ($true) {
    $childArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $here 'wx-watch.ps1'), '-IntervalSec', $IntervalSec)
    if ($MaxRounds -gt 0) { $childArgs += @('-MaxRounds', $MaxRounds) }
    try {
      & powershell.exe @childArgs 2>&1 | ForEach-Object { Say ('watcher: ' + [string]$_) }
    } catch {
      Say ('watcher threw: ' + $_.Exception.Message)
    }
    $stopFlag = Join-Path $here 'state\stop.flag'
    if (Test-Path -LiteralPath $stopFlag) {
      Say 'stop flag detected - the daemon is exiting'
      Remove-Item -LiteralPath $stopFlag -Force -ErrorAction SilentlyContinue
      break
    }
    Say 'watcher exited; restarting in 30s'
    Start-Sleep -Seconds 30
  }
} finally {
  try { $mutex.ReleaseMutex() } catch { }
  $mutex.Dispose()
}
