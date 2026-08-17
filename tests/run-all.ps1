# Runs every onboard-dsh-projects test suite in fresh child processes.
# Exits non-zero when any suite fails. Works on Windows PowerShell 5.1.
$ErrorActionPreference = 'Stop'

$suites = @(
  'suite-lane.ps1',
  'suite-goal.ps1',
  'suite-dependency.ps1',
  'suite-contract.ps1'
)

$failed = 0
foreach ($suite in $suites) {
  Write-Output ''
  Write-Output ("===== suite: {0} =====" -f $suite)
  $path = Join-Path $PSScriptRoot $suite
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $path
  $code = $LASTEXITCODE
  if ($code -ne 0) {
    Write-Output ("===== suite {0} FAILED (exit {1}) =====" -f $suite, $code)
    $failed++
  }
}

Write-Output ''
Write-Output ("RESULT: {0}/{1} suites passed" -f ($suites.Count - $failed), $suites.Count)
if ($failed -gt 0) { exit 1 }
exit 0
