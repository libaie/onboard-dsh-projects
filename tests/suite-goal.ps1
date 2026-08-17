# Goal ledger suite.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

$c = New-TestController
try {
  $r = Run-Op $c 'register-goal' '{"goalId":"goal-order-chain-v1","objective":"order chain full health verification","chainIdRef":"chain-15a8c09a5d810f80"}'
  Expect 'register-goal applied' $r.ok
  $r = Run-Op $c 'register-goal' '{"goalId":"goal-order-chain-v1","objective":"dup"}'
  Expect 'duplicate goal rejected' (-not $r.ok -and $r.reason -eq 'goal-already-registered')
  $r = Run-Op $c 'register-goal' '{"goalId":"bad id!","objective":"x"}'
  Expect 'invalid goalId rejected' (-not $r.ok -and $r.reason -eq 'invalid-goal-id')
  $r = Run-Op $c 'register-goal' '{"goalId":"g2","objective":"","chainIdRef":"x"}'
  Expect 'empty objective rejected' (-not $r.ok -and $r.reason -eq 'invalid-goal-objective')
  $r = Run-Op $c 'advance-goal' '{"goalId":"goal-order-chain-v1","status":"advancing","reason":"lanes sealed"}'
  Expect 'advance-goal applied' $r.ok
  $r = Run-Op $c 'advance-goal' '{"goalId":"goal-order-chain-v1","status":"flying"}'
  Expect 'invalid advance status rejected' (-not $r.ok -and $r.reason -eq 'invalid-goal-status')
  $r = Run-Op $c 'terminal-goal' '{"goalId":"goal-order-chain-v1","outcome":"completed"}'
  Expect 'terminal-goal applied' $r.ok
  $r = Run-Op $c 'advance-goal' '{"goalId":"goal-order-chain-v1","status":"paused"}'
  Expect 'advance after terminal rejected' (-not $r.ok -and $r.reason -eq 'goal-already-terminal')
  $r = Run-Op $c 'terminal-goal' '{"goalId":"goal-order-chain-v1","outcome":"completed"}'
  Expect 'double terminal rejected' (-not $r.ok -and $r.reason -eq 'goal-already-terminal')
  $r = Run-Op $c 'terminal-goal' '{"goalId":"missing-goal","outcome":"completed"}'
  Expect 'terminal missing goal rejected' (-not $r.ok -and $r.reason -eq 'goal-not-found')
  $r = Run-Op $c 'terminal-goal' '{"goalId":"g2","outcome":"exploded"}'
  Expect 'invalid outcome rejected' (-not $r.ok -and $r.reason -eq 'invalid-goal-outcome')
  $m = Read-Manifest $c
  $goal = $m.goals | Where-Object { $_.goalId -eq 'goal-order-chain-v1' }
  Expect 'manifest goals persisted (status=completed)' ($goal.status -eq 'completed')
  Expect 'terminalAtUtc recorded' ($null -ne $goal.terminalAtUtc)
}
finally {
  Remove-TestController $c
}
Finish-Tests 'goal'
