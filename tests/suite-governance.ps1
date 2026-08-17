# Governance suite: dispatch phase state machine + dashboard regeneration.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

$c = New-TestController
try {
  $H = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
  $E = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'

  # phase state machine
  $r = Run-Op $c 'enqueue-dispatch' '{"repoId":"crmeb-backend","modelClass":"balanced","generation":1,"rework":false,"taskSpec":{"objective":"phase checks"}}'
  Expect 'enqueue for phase checks' $r.ok
  $r = Run-Op $c 'start-next-dispatch' '{"repoId":"crmeb-backend","leaseId":"lease-p1"}'
  Expect 'start sets phase dispatched' $r.ok
  $m = Read-Manifest $c
  $q = $m.dispatchQueues | Where-Object { $_.repoId -eq 'crmeb-backend' }
  Expect 'active phase = dispatched' ($q.active.phase -eq 'dispatched')
  $r = Run-Op $c 'advance-dispatch' '{"repoId":"crmeb-backend","phase":"in-progress"}'
  Expect 'advance to in-progress' $r.ok
  $r = Run-Op $c 'advance-dispatch' '{"repoId":"crmeb-backend","phase":"evidence-collected"}'
  Expect 'advance to evidence-collected' $r.ok
  $r = Run-Op $c 'advance-dispatch' '{"repoId":"crmeb-backend","phase":"dispatched"}'
  Expect 'backward transition rejected' (-not $r.ok -and $r.reason -eq 'invalid-phase-transition')
  $r = Run-Op $c 'advance-dispatch' '{"repoId":"crmeb-backend","phase":"flying"}'
  Expect 'unknown phase rejected' (-not $r.ok -and $r.reason -eq 'invalid-phase')
  $r = Run-Op $c 'record-dispatch-outcome' ('{"repoId":"crmeb-backend","taskSpecHash":"' + $H + '","resultState":"accepted-success","evidenceHash":"' + $E + '","finishedAtUtc":"2026-08-17T00:00:00Z"}')
  Expect 'outcome recorded' $r.ok
  $r = Run-Op $c 'advance-dispatch' '{"repoId":"crmeb-backend","phase":"in-progress"}'
  Expect 'advance after terminal rejected' (-not $r.ok -and $r.reason -eq 'no-active-dispatch')

  # queue some more shapes for the dashboard
  $r = Run-Op $c 'register-capability' '{"capId":"jenkins-root","kind":"jenkins","label":"Jenkins","targets":["jenkins-root"],"allowedOps":["trigger-build"],"secretRef":"env:JENKINS_TOKEN"}'
  Expect 'capability registered' $r.ok
  $r = Run-Op $c 'enqueue-dispatch' '{"repoId":"price","modelClass":"frontier","generation":1,"rework":false,"accessMode":"external-write","capabilityRefs":["jenkins-root"],"authorizationRequired":true,"taskSpec":{"objective":"deploy","verification":["v"],"rollback":["r"]}}'
  Expect 'external-write pending enqueued' $r.ok

  # dashboard regeneration
  $dash = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:RepoRoot 'scripts\rebuild-dashboard.ps1') -ControllerRoot $c 2>&1 | Out-String
  Expect 'dashboard script reported success' ($dash -match 'regenerated')
  $tasks = Join-Path $c 'TASKS.md'
  Expect 'TASKS.md created' (Test-Path $tasks)
  $content = Get-Content -LiteralPath $tasks -Raw
  Expect 'dashboard lists active/terminal/pending rows' ($content -match 'crmeb-backend' -and $content -match 'auth-pending' -and $content -match 'accepted-success')
  Expect 'dashboard header present' ($content -match '\| Dispatch \| Repo \| Phase \| Status \| Updated \|')
}
finally {
  Remove-TestController $c
}
Finish-Tests 'governance'
