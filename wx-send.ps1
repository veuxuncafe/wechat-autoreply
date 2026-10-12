# wx-send.ps1 - put text into the open WeChat chat input box, optionally commit it.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File wx-send.ps1 -Text "..."            # type only
#   powershell ... -File wx-send.ps1 -Text "..." -Commit                                   # type + Enter (LIVE)
#   powershell ... -File wx-send.ps1 -Clear                                                # clear the input box
#
# Safety model
#   * The default mode only PASTES into the input box and takes a screenshot so the caller
#     can verify with vision. Nothing is sent.
#   * -Commit presses Enter and is what actually sends. -DryRun makes -Commit a no-op.
#   * Live commits go through the throttle + duplicate guards in wx-core.
#   * Chinese text always goes clipboard + Ctrl+V (SendKeys cannot type CJK).

param(
  [string]$Text = '',
  [switch]$Commit,
  [switch]$Clear,
  [switch]$DryRun,
  [switch]$NoShot,
  [switch]$AsJson
)

$ErrorActionPreference = 'Continue'
$here = $PSScriptRoot
. (Join-Path $here 'wx-core.ps1')

$steps = New-Object System.Collections.ArrayList
function Step { param([string]$s) [void]$steps.Add($s); Write-Output $s }

$m = Get-WxMainWindow
if (-not $m) { Write-Output 'ERROR: WeChat main window not found (tray only?).'; exit 3 }
Step ('window : ' + $m.Hwnd.ToString() + '  ' + $m.Left + ',' + $m.Top + ' ' + $m.Width + 'x' + $m.Height)

# Bring WeChat forward; synthetic clicks land on the foreground window.
$ok = Set-DshForeground -Hwnd $m.Hwnd
Start-Sleep -Milliseconds 400
Step ('foreground: ' + $ok)

# Focus the input box by clicking it.
$p = Invoke-WxClickAnchor -Name input -SettleMs 400
Step ('clicked input anchor at ' + $p.X + ',' + $p.Y)

if ($Clear) {
  [System.Windows.Forms.SendKeys]::SendWait('^a')
  Start-Sleep -Milliseconds 200
  [System.Windows.Forms.SendKeys]::SendWait('{DEL}')
  Start-Sleep -Milliseconds 300
  Step 'cleared input box (Ctrl+A, Delete)'
}

if ($Text -ne '') {
  Set-DshClipboardText -Text $Text
  Start-Sleep -Milliseconds 250
  [System.Windows.Forms.SendKeys]::SendWait('^v')
  Start-Sleep -Milliseconds 700
  Step ('pasted ' + $Text.Length + ' chars')
}

if (-not $NoShot) {
  $shot = Join-Path (Get-WxShotDir) 'input-latest.png'
  $full = Join-Path (Get-WxShotDir) ('send-' + (Get-Date).ToString('yyyyMMdd-HHmmss') + '.png')
  $fi = Save-DshWindowCapture -Hwnd $m.Hwnd -OutFile $full -Method Screen
  Add-Type -AssemblyName System.Drawing
  $bmp = New-Object System.Drawing.Bitmap($full)
  $ci = Get-WxClientInfo
  $r = New-Object System.Drawing.Rectangle((0.26 * $ci.W), (0.70 * $ci.H), (0.74 * $ci.W), (0.30 * $ci.H))
  $c = $bmp.Clone($r, $bmp.PixelFormat)
  $c.Save($shot, [System.Drawing.Imaging.ImageFormat]::Png)
  $bmp.Dispose(); $c.Dispose()
  Step ('shot  : ' + $shot)
}

$sent = $false
if ($Commit) {
  if ($DryRun) {
    Add-WxLog 'DRYRUN' ('would press Enter to send: ' + $Text) | Out-Null
    Step 'DRYRUN: Enter not pressed'
  } else {
    if (-not $Text -and -not $Clear) { Step 'ERROR: -Commit needs -Text'; exit 5 }
    $gate = Test-WxSendAllowed
    if (-not $gate.Ok) { Add-WxLog 'BLOCKED' $gate.Reason | Out-Null; Step ('BLOCKED: ' + $gate.Reason); exit 6 }
    if (Test-WxDuplicate -Text $Text) { Add-WxLog 'DUP' $Text | Out-Null; Step 'DUP: same reply sent recently'; exit 7 }
    Send-DshEnter
    Start-Sleep -Milliseconds 800
    $s = Get-WxState
    $s.replied = @($s.replied) + [pscustomobject]@{ hash = (Get-WxTextHash -Text $Text); ts = (Get-Date).ToString('s'); text = $Text }
    $s.sends = @($s.sends) + (Get-Date).ToString('s')
    Set-WxState $s
    Add-WxLog 'SENT' $Text | Out-Null
    $sent = $true
    Step 'SENT (Enter pressed)'
  }
}

if ($AsJson) {
  [pscustomobject]@{ Steps = $steps; Sent = $sent; Text = $Text } | ConvertTo-Json -Depth 4
}
