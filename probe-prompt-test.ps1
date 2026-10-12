# Runs the real reply prompt against a synthetic transcript, through the same
# headless model path the watcher uses. Prints elapsed time and the raw answer.
param([Parameter(Mandatory = $true)][string]$TranscriptFile, [int]$TimeoutSec = 150)
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$node = (Join-Path $env:APPDATA 'dsh-tauri\runtime\node.exe')
$bin = (Join-Path $env:APPDATA 'dsh-tauri\dependencies\dsh\node_modules\@deepseek-ai\dsh\lib\bin.js')
$patch = Join-Path $root 'wx-model-patch.yml'
$tpl = Get-Content -LiteralPath (Join-Path $root 'reply-prompt-text.txt') -Raw -Encoding UTF8
$transcript = (Get-Content -LiteralPath $TranscriptFile -Raw -Encoding UTF8).TrimEnd()
# The watcher substitutes these too; derive them here from the synthetic transcript's last line.
$lastLine = ''
$lines = @($transcript -split "`r?`n" | Where-Object { $_.Trim() })
if ($lines.Count -gt 0) { $lastLine = $lines[$lines.Count - 1].Trim() }
$inLen = ($lastLine -replace '^\[(对方|我)\]\s*', '').Length
$longIn = 'no'
if ($inLen -gt 100) { $longIn = 'yes' }
$task = $tpl.Replace('{{TRANSCRIPT}}', $transcript).Replace('{{INBOUND_LEN}}', [string]$inLen).Replace('{{LONG_INBOUND}}', $longIn).Replace('{{NOW}}', (Get-Date).ToString('yyyy-MM-dd HH:mm'))
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$ask = Join-Path $root ('state\probe-ask-' + $stamp + '.txt')
$out = Join-Path $root ('state\probe-out-' + $stamp + '.txt')
$err = Join-Path $root ('state\probe-err-' + $stamp + '.txt')
[System.IO.File]::WriteAllText($ask, $task, (New-Object System.Text.UTF8Encoding($false)))
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$p = Start-Process -FilePath $node -ArgumentList @($bin, '--profile', 'headless', '--patch', $patch, '-') -RedirectStandardInput $ask -RedirectStandardOutput $out -RedirectStandardError $err -NoNewWindow -PassThru
if (-not $p.WaitForExit($TimeoutSec * 1000)) { try { $p.Kill() } catch { } }
$sw.Stop()
Write-Output ('elapsed=' + $sw.ElapsedMilliseconds + 'ms  exit=' + $p.ExitCode)
Write-Output '--- answer ---'
Get-Content -LiteralPath $out -Raw -Encoding UTF8
