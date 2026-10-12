# wx-contacts.ps1 - command line access to state\contacts.json, the store the
# watcher (through wx-core.ps1) and the control panel both use.
#
#   wx-contacts.ps1                       list contacts
#   wx-contacts.ps1 -SetActive 张三      make a contact the one being answered
#   wx-contacts.ps1 -Add 小明 -PromptFile C:\path\prompt.txt
#   wx-contacts.ps1 -Remove 小明
#   wx-contacts.ps1 -Enable 小明 | -Disable 小明
#   wx-contacts.ps1 -Peek 小明            print that contact's stored prompts
#
# Names with Chinese characters are safest typed by the panel; the console code
# page can mangle them. ASCII names always work here.
param(
  [string]$SetActive = '',
  [string]$Add = '',
  [string]$Remove = '',
  [string]$Enable = '',
  [string]$Disable = '',
  [string]$Peek = '',
  [string]$PromptFile = '',
  [string]$ProactiveFile = ''
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'wx-core.ps1')

function Show-WxContactList {
  $d = Get-WxContacts
  Write-Output ('store   : {0}' -f $script:WxContactsFile)
  Write-Output ('active  : {0}' -f $d.active)
  $n = 0
  foreach ($c in @($d.contacts)) {
    $flag = 'off'
    if ($c.enabled) { $flag = 'on ' }
    $rp = 0
    if ($c.replyPrompt) { $rp = ([string]$c.replyPrompt).Length }
    $pp = 0
    if ($c.proactivePrompt) { $pp = ([string]$c.proactivePrompt).Length }
    Write-Output ('  [{0}] {1}   reply={2} chars  proactive={3} chars' -f $flag, $c.name, $rp, $pp)
    $n++
  }
  Write-Output ('total   : {0}' -f $n)
}

function Get-WxContactByName {
  param([string]$Name)
  $d = Get-WxContacts
  foreach ($c in @($d.contacts)) { if ([string]$c.name -eq $Name) { return $c } }
  return $null
}

if ($SetActive) {
  $null = Set-WxActiveContact -Name $SetActive
  Write-Output ('active -> {0}' -f $SetActive)
}

if ($Add) {
  $d = Get-WxContacts
  $list = @($d.contacts)
  $reply = ''
  $pro = ''
  if ($PromptFile) { $reply = Get-Content -LiteralPath $PromptFile -Raw -Encoding UTF8 }
  if ($ProactiveFile) { $pro = Get-Content -LiteralPath $ProactiveFile -Raw -Encoding UTF8 }
  $found = $null
  foreach ($c in $list) { if ([string]$c.name -eq $Add) { $found = $c } }
  if ($found) {
    if ($PromptFile) { $found.replyPrompt = $reply }
    if ($ProactiveFile) { $found.proactivePrompt = $pro }
    Write-Output ('updated {0}' -f $Add)
  } else {
    $c = [pscustomobject]@{ name = $Add; enabled = $true; replyPrompt = $reply; proactivePrompt = $pro }
    $d.contacts = @($list) + @($c)
    Write-Output ('added {0}' -f $Add)
  }
  Save-WxContacts $d
}

if ($Remove) {
  $d = Get-WxContacts
  $keep = @()
  $hit = $false
  foreach ($c in @($d.contacts)) { if ([string]$c.name -eq $Remove) { $hit = $true } else { $keep += $c } }
  if (-not $hit) { Write-Output ('not found: {0}' -f $Remove); exit 1 }
  if (@($keep).Count -eq 0) { Write-Output 'refusing to remove the last contact'; exit 1 }
  $d.contacts = $keep
  if ([string]$d.active -eq $Remove) { $d.active = [string]@($keep)[0].name }
  Save-WxContacts $d
  Write-Output ('removed {0}' -f $Remove)
}

if ($Enable -or $Disable) {
  $name = $Enable
  $on = $true
  if ($Disable) { $name = $Disable; $on = $false }
  $d = Get-WxContacts
  foreach ($c in @($d.contacts)) { if ([string]$c.name -eq $name) { $c.enabled = $on } }
  Save-WxContacts $d
  Write-Output ('{0} -> enabled={1}' -f $name, $on)
}

if ($Peek) {
  $c = Get-WxContactByName -Name $Peek
  if (-not $c) { Write-Output ('not found: {0}' -f $Peek); exit 1 }
  Write-Output ('--- reply prompt ({0} chars) ---' -f ([string]$c.replyPrompt).Length)
  Write-Output ([string]$c.replyPrompt)
  Write-Output ('--- proactive prompt ({0} chars) ---' -f ([string]$c.proactivePrompt).Length)
  Write-Output ([string]$c.proactivePrompt)
}

if (-not ($SetActive -or $Add -or $Remove -or $Enable -or $Disable -or $Peek)) { Show-WxContactList }
