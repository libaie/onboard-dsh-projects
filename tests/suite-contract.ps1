# Contract freeze and dispatch refs suite.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

$c = New-TestController
try {
  $H = 'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc'

  $r = Run-Op $c 'freeze-contract' ('{"contractId":"mall-steward-debt-evidence","version":"1.0.0","hash":"' + $H + '","docPath":"docs/cross-project-contracts.md"}')
  Expect 'freeze-contract applied' $r.ok
  $r = Run-Op $c 'freeze-contract' ('{"contractId":"mall-steward-debt-evidence","version":"1.0.0","hash":"' + $H + '","docPath":"docs/cross-project-contracts.md"}')
  Expect 'same id+version conflicts' (-not $r.ok -and $r.reason -eq 'contract-version-already-frozen')
  $r = Run-Op $c 'freeze-contract' ('{"contractId":"mall-steward-debt-evidence","version":"1.0.1","hash":"' + $H + '","docPath":"docs/cross-project-contracts.md"}')
  Expect 'new version freezes (amendment)' $r.ok
  $r = Run-Op $c 'freeze-contract' ('{"contractId":"x","version":"1.0.0","hash":"nothash","docPath":"d.md"}')
  Expect 'invalid hash rejected' (-not $r.ok -and $r.reason -eq 'invalid-contract-hash')
  $r = Run-Op $c 'freeze-contract' ('{"contractId":"x","version":"1.0.0","hash":"' + $H + '","docPath":"C:\\abs\\d.md"}')
  Expect 'absolute docPath rejected' (-not $r.ok -and $r.reason -eq 'invalid-contract-doc-path')

  $r = Run-Op $c 'register-goal' '{"goalId":"goal-contract-v1","objective":"contract gating verification"}'
  Expect 'goal registered' $r.ok

  $enq = '{"repoId":"crmeb-backend","modelClass":"frontier","generation":1,"rework":false,"taskSpec":{"objective":"contract work"},"contractRef":"mall-steward-debt-evidence","contractVersion":"1.0.0","goalIdRef":"goal-contract-v1"}'
  $r = Run-Op $c 'enqueue-dispatch' $enq
  Expect 'enqueue with valid contractRef+goalIdRef' $r.ok
  $m = Read-Manifest $c
  $q = $m.dispatchQueues | Where-Object { $_.repoId -eq 'crmeb-backend' }
  $item = $q.pending[-1]
  Expect 'pending item pins contract version and hash' ($item.contractRef -eq 'mall-steward-debt-evidence' -and $item.contractVersion -eq '1.0.0' -and $item.contractHash -eq $H)
  Expect 'pending item carries goalIdRef' ($item.goalIdRef -eq 'goal-contract-v1')

  $r = Run-Op $c 'enqueue-dispatch' '{"repoId":"crmeb-backend","modelClass":"balanced","generation":1,"rework":false,"taskSpec":{"objective":"x"},"contractRef":"never-frozen","contractVersion":"1.0.0"}'
  Expect 'unknown contractRef rejected' (-not $r.ok -and $r.reason -eq 'contract-not-frozen')
  $r = Run-Op $c 'enqueue-dispatch' '{"repoId":"crmeb-backend","modelClass":"balanced","generation":1,"rework":false,"taskSpec":{"objective":"x"},"goalIdRef":"missing-goal"}'
  Expect 'unknown goalIdRef rejected' (-not $r.ok -and $r.reason -eq 'goal-not-found')

  $m = Read-Manifest $c
  Expect 'manifest contracts persisted (2 versions)' (@($m.contracts).Count -eq 2)
}
finally {
  Remove-TestController $c
}
Finish-Tests 'contract'
