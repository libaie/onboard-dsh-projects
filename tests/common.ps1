# Shared harness for the dsh-flotilla test suites.
# Dot-source this file from a suite script: . (Join-Path $PSScriptRoot 'common.ps1')

$ErrorActionPreference = 'Stop'
$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:TestFailures = 0
$script:LastReason = ''

function New-TestController {
  $tmp = Join-Path ([IO.Path]::GetTempPath()) ('dsh-flotilla-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Path $tmp | Out-Null
  $tpl = Get-Content (Join-Path $script:RepoRoot 'templates\controller\.dsh-controller.json') -Raw
  $tpl = $tpl.Replace('__CONTROLLER_NAME_JSON__', '"Test Control Center"')
  [IO.File]::WriteAllText((Join-Path $tmp '.dsh-controller.json'), $tpl, [Text.UTF8Encoding]::new($false))
  New-Item -ItemType Directory -Path (Join-Path $tmp 'tools') | Out-Null
  Copy-Item (Join-Path $script:RepoRoot 'templates\controller\tools\control-state.ps1') (Join-Path $tmp 'tools')
  return $tmp
}

function Remove-TestController([string]$ControllerRoot) {
  Remove-Item $ControllerRoot -Recurse -Force -ErrorAction SilentlyContinue
}

function Run-Op([string]$ControllerRoot, [string]$Op, [string]$Json) {
  $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Json))
  $prep = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $ControllerRoot 'tools\control-state.ps1') -Action PrepareCandidate -Operation $Op -PayloadJsonBase64 $b64 -ControllerRoot $ControllerRoot | ConvertFrom-Json
  if ($prep.status -ne 'prepared') { $script:LastReason = [string]$prep.reasonCode; return [pscustomobject]@{ ok = $false; status = [string]$prep.status; reason = [string]$prep.reasonCode } }
  $apply = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $ControllerRoot 'tools\control-state.ps1') -Action ApplyCandidate -Operation $Op -CandidatePath $prep.candidatePath -CandidateHash $prep.candidateHash -ControllerRoot $ControllerRoot | ConvertFrom-Json
  if ($apply.status -ne 'applied') { $script:LastReason = [string]$apply.reasonCode; return [pscustomobject]@{ ok = $false; status = [string]$apply.status; reason = [string]$apply.reasonCode } }
  $script:LastReason = ''
  return [pscustomobject]@{ ok = $true; status = [string]$apply.status; reason = $null }
}

function Expect([string]$Label, [bool]$Cond) {
  $extra = if ($Cond) { '' } else { "  <- reason: $script:LastReason" }
  Write-Output ("{0} {1}{2}" -f $(if ($Cond) { 'PASS' } else { 'FAIL' }), $Label, $extra)
  if (-not $Cond) { $script:TestFailures++ }
}

function Read-Manifest([string]$ControllerRoot) {
  return (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $ControllerRoot 'tools\control-state.ps1') -Action Read -ControllerRoot $ControllerRoot | ConvertFrom-Json).data
}

function Get-PendingTailId([string]$ControllerRoot, [string]$Repo) {
  $m = Read-Manifest $ControllerRoot
  $q = $m.dispatchQueues | Where-Object { $_.repoId -eq $Repo }
  return $q.pending[-1].dispatchId
}

function Finish-Tests([string]$SuiteName) {
  Write-Output ("{0}: TOTAL FAILURES: {1}" -f $SuiteName, $script:TestFailures)
  if ($script:TestFailures -gt 0) { exit 1 }
  exit 0
}
