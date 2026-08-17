# External-write lane suite: capability registry + authorization gate.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

$c = New-TestController
try {
  $H = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
  $E = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'

  $r = Run-Op $c 'register-capability' '{"capId":"jenkins-root","kind":"jenkins","label":"Jenkins root","targets":["jenkins-root","dev-crmeb"],"allowedOps":["trigger-build","get-build-status"],"secretRef":"env:JENKINS_TOKEN"}'
  Expect 'register-capability applied' $r.ok
  $r = Run-Op $c 'register-capability' '{"capId":"jenkins-root","kind":"jenkins","label":"dup","targets":["x"],"allowedOps":["y"],"secretRef":"env:Z"}'
  Expect 'duplicate capability conflicts' (-not $r.ok -and $r.reason -eq 'capability-already-registered')

  $r = Run-Op $c 'enqueue-dispatch' '{"repoId":"crmeb-backend","modelClass":"frontier","generation":1,"rework":false,"accessMode":"external-write","capabilityRefs":["nope"],"authorizationRequired":true,"taskSpec":{"objective":"rebuild dev-crmeb","verification":["before","after"],"rollback":["revert"]}}'
  Expect 'unregistered capability rejected' (-not $r.ok -and $r.reason -eq 'capability-not-registered')

  $r = Run-Op $c 'enqueue-dispatch' '{"repoId":"crmeb-backend","modelClass":"frontier","generation":1,"rework":false,"accessMode":"external-write","capabilityRefs":["jenkins-root"],"authorizationRequired":true,"taskSpec":{"objective":"rebuild dev-crmeb","verification":["before","after"],"rollback":["revert"]}}'
  Expect 'external-write enqueue applied' $r.ok
  $d7 = Get-PendingTailId $c 'crmeb-backend'

  $r = Run-Op $c 'start-next-dispatch' '{"repoId":"crmeb-backend","leaseId":"lease-ew1"}'
  Expect 'start blocked before authorization' (-not $r.ok -and $r.reason -eq 'authorization-pending')

  $r = Run-Op $c 'authorize-dispatch' ('{"repoId":"crmeb-backend","dispatchId":"' + $d7 + '","granted":true,"grantRef":"approval-ew-001"}')
  Expect 'authorize-dispatch granted' $r.ok

  $r = Run-Op $c 'start-next-dispatch' '{"repoId":"crmeb-backend","leaseId":"lease-ew1"}'
  Expect 'start succeeds after grant' $r.ok

  $payload = '{"repoId":"crmeb-backend","taskSpecHash":"' + $H + '","resultState":"accepted-success","evidenceHash":"' + $E + '","finishedAtUtc":"2026-08-17T00:00:00Z"}'
  $r = Run-Op $c 'record-dispatch-outcome' $payload
  Expect 'outcome recorded' $r.ok

  $r = Run-Op $c 'enqueue-dispatch' '{"repoId":"crmeb-backend","modelClass":"balanced","generation":1,"rework":false,"accessMode":"external-write","capabilityRefs":["jenkins-root"],"authorizationRequired":true,"taskSpec":{"objective":"deny path","verification":["v"],"rollback":["r"]}}'
  Expect 'second enqueue applied' $r.ok
  $d8 = Get-PendingTailId $c 'crmeb-backend'
  $r = Run-Op $c 'authorize-dispatch' ('{"repoId":"crmeb-backend","dispatchId":"' + $d8 + '","granted":false}')
  Expect 'deny terminates as canceled' $r.ok
  $m = Read-Manifest $c
  $q = $m.dispatchQueues | Where-Object { $_.repoId -eq 'crmeb-backend' }
  Expect 'deny wrote authorizationDenied terminal' ($q.lastTerminal.resultState -eq 'canceled' -and $q.lastTerminal.authorizationDenied -eq $true)

  $r = Run-Op $c 'remove-capability' '{"capId":"jenkins-root"}'
  Expect 'remove-capability applied' $r.ok
  $r = Run-Op $c 'enqueue-dispatch' '{"repoId":"crmeb-backend","modelClass":"balanced","generation":1,"rework":false,"accessMode":"external-write","capabilityRefs":["jenkins-root"],"authorizationRequired":true,"taskSpec":{"objective":"x","verification":["v"],"rollback":["r"]}}'
  Expect 'enqueue after remove rejected' (-not $r.ok -and $r.reason -eq 'capability-not-registered')

  $r = Run-Op $c 'enqueue-dispatch' '{"repoId":"crmeb-backend","modelClass":"balanced","generation":1,"rework":false,"accessMode":"external-write","capabilityRefs":["jenkins-root"],"authorizationRequired":false,"taskSpec":{"objective":"x","verification":["v"],"rollback":["r"]}}'
  Expect 'external-write without authorization flag rejected' (-not $r.ok -and $r.reason -eq 'authorization-required-for-external-write')

  $r = Run-Op $c 'register-capability' '{"capId":"jenkins-root","kind":"jenkins","label":"re-reg","targets":["jenkins-root"],"allowedOps":["trigger-build"],"secretRef":"env:JENKINS_TOKEN"}'
  Expect 'capability re-registered for spec checks' $r.ok
  $r = Run-Op $c 'enqueue-dispatch' '{"repoId":"crmeb-backend","modelClass":"balanced","generation":1,"rework":false,"accessMode":"external-write","capabilityRefs":["jenkins-root"],"authorizationRequired":true,"taskSpec":{"objective":"no verification fields"}}'
  Expect 'external-write spec without verification/rollback rejected' (-not $r.ok -and $r.reason -eq 'external-write-spec-missing-verification-rollback')

  $r = Run-Op $c 'enqueue-dispatch' '{"repoId":"crmeb-backend","modelClass":"balanced","generation":1,"rework":false,"accessMode":"read","authorizationRequired":true,"taskSpec":{"objective":"x"}}'
  Expect 'authorization flag on non-external rejected' (-not $r.ok -and $r.reason -eq 'authorization-only-for-external-write')
}
finally {
  Remove-TestController $c
}
Finish-Tests 'lane'
