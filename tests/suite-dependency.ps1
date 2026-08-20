# Dependency gating suite.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

$c = New-TestController
try {
  # baseline dispatch on crmeb-backend
  $r = Run-Op $c 'enqueue-dispatch' '{"repoId":"crmeb-backend","modelClass":"balanced","generation":1,"rework":false,"taskSpec":{"objective":"baseline fix"}}'
  Expect 'baseline enqueued' $r.ok
  $id1 = Get-PendingTailId $c 'crmeb-backend'
  $r = Run-Op $c 'start-next-dispatch' '{"repoId":"crmeb-backend","leaseId":"lease-b1"}'
  Expect 'baseline started' $r.ok
  $r = Complete-ActiveDispatch $c 'crmeb-backend' '2026-08-17T00:00:00Z'
  Expect 'baseline accepted' $r.ok

  # dependent dispatch (default allowed accepted-success)
  $depJson = '{"repoId":"crmeb-backend","modelClass":"balanced","generation":1,"rework":false,"taskSpec":{"objective":"after baseline"},"dependencies":[{"dispatchId":"' + $id1 + '"}]}'
  $r = Run-Op $c 'enqueue-dispatch' $depJson
  Expect 'dependent enqueued' $r.ok
  $r = Run-Op $c 'start-next-dispatch' '{"repoId":"crmeb-backend","leaseId":"lease-b2"}'
  Expect 'dependent starts (dependency satisfied)' $r.ok
  $r = Complete-ActiveDispatch $c 'crmeb-backend' '2026-08-17T00:05:00Z'
  Expect 'dependent accepted' $r.ok

  # missing dependency blocks, then cancel-pending unblocks the FIFO
  $r = Run-Op $c 'enqueue-dispatch' '{"repoId":"price","modelClass":"balanced","generation":1,"rework":false,"taskSpec":{"objective":"gated"},"dependencies":[{"dispatchId":"D-9999"}]}'
  Expect 'missing-dep enqueued' $r.ok
  $r = Run-Op $c 'start-next-dispatch' '{"repoId":"price","leaseId":"lease-m1"}'
  Expect 'blocked dependency-unsatisfied (missing dep)' (-not $r.ok -and $r.reason -eq 'dependency-unsatisfied')
  $blockedId = Get-PendingTailId $c 'price'
  $cancelJson = '{"repoId":"price","dispatchId":"' + $blockedId + '"}'
  $r = Run-Op $c 'cancel-pending-dispatch' $cancelJson
  Expect 'blocked head canceled' $r.ok
  $r = Run-Op $c 'enqueue-dispatch' '{"repoId":"price","modelClass":"balanced","generation":1,"rework":false,"taskSpec":{"objective":"unblocked"}}'
  Expect 'queue unblocked enqueue' $r.ok
  $r = Run-Op $c 'start-next-dispatch' '{"repoId":"price","leaseId":"lease-u1"}'
  Expect 'queue unblocked start' $r.ok
  $r = Complete-ActiveDispatch $c 'price' '2026-08-17T00:10:00Z'
  Expect 'unblocked accepted' $r.ok

  # wrong allowed terminal state blocks
  $depJson2 = '{"repoId":"supplyapi","modelClass":"balanced","generation":1,"rework":false,"taskSpec":{"objective":"gated2"},"dependencies":[{"dispatchId":"' + $id1 + '","allowedTerminalStates":["deterministic-failure"]}]}'
  $r = Run-Op $c 'enqueue-dispatch' $depJson2
  Expect 'wrong-state enqueued' $r.ok
  $r = Run-Op $c 'start-next-dispatch' '{"repoId":"supplyapi","leaseId":"lease-w1"}'
  Expect 'blocked dependency-unsatisfied (state not allowed)' (-not $r.ok -and $r.reason -eq 'dependency-unsatisfied')

  # duplicate dependency ids rejected
  $depJson3 = '{"repoId":"supplyapi","modelClass":"balanced","generation":1,"rework":false,"taskSpec":{"objective":"bad"},"dependencies":[{"dispatchId":"' + $id1 + '"},{"dispatchId":"' + $id1 + '"}]}'
  $r = Run-Op $c 'enqueue-dispatch' $depJson3
  Expect 'duplicate dependency ids rejected' (-not $r.ok -and $r.reason -eq 'invalid-dependencies')

  # invalid allowed terminal state rejected
  $depJson4 = '{"repoId":"supplyapi","modelClass":"balanced","generation":1,"rework":false,"taskSpec":{"objective":"badstate"},"dependencies":[{"dispatchId":"' + $id1 + '","allowedTerminalStates":["exploded"]}]}'
  $r = Run-Op $c 'enqueue-dispatch' $depJson4
  Expect 'invalid allowed terminal state rejected' (-not $r.ok -and $r.reason -eq 'invalid-dependencies')

  # cancel of a non-pending id rejected
  $r = Run-Op $c 'cancel-pending-dispatch' '{"repoId":"supplyapi","dispatchId":"D-4242"}'
  Expect 'cancel missing pending rejected' (-not $r.ok -and $r.reason -eq 'dispatch-not-in-pending')

  # goal smoke
  $r = Run-Op $c 'register-goal' '{"goalId":"goal-dep-test","objective":"dependency gating verification"}'
  Expect 'goal registered' $r.ok
  $r = Run-Op $c 'terminal-goal' '{"goalId":"goal-dep-test","outcome":"completed"}'
  Expect 'goal terminal' $r.ok
}
finally {
  Remove-TestController $c
}
Finish-Tests 'dependency'
