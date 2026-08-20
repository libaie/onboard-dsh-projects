# Regression coverage for dispatch identity, repository isolation, contracts, and CHAIN integrity.
. (Join-Path $PSScriptRoot 'common.ps1')

function New-ChainController {
  $root = Join-Path ([IO.Path]::GetTempPath()) ('dsh-flotilla-chain-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  $result = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:RepoRoot 'scripts\init-controller-dsh.ps1') -Action Apply -ControllerRoot $root | ConvertFrom-Json
  if ($result.status -ne 'applied') { throw 'chain-controller-init-failed' }
  return $root
}

function Put-ChainRecord([string]$ControllerRoot, [object]$Record, [bool]$Terminal, [string]$ExpectedHash) {
  $chainId = [string]$Record.chainId
  $candidate = [pscustomobject][ordered]@{ chainId=$chainId; confirmTerminal=$Terminal; record=$Record }
  $candidatePath = Join-Path $ControllerRoot ('.' + [guid]::NewGuid().ToString('N') + '.chain.tmp')
  [IO.File]::WriteAllText($candidatePath, ($candidate | ConvertTo-Json -Depth 12 -Compress), [Text.UTF8Encoding]::new($false))
  $candidateHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $candidatePath).Hash.ToLowerInvariant()
  $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $ControllerRoot 'tools\chain-store.ps1'), '-Action', 'Put', '-ControllerRoot', $ControllerRoot, '-CandidatePath', $candidatePath, '-CandidateHash', $candidateHash, '-ExpectedEntryHash', $ExpectedHash)
  if ($Terminal) { $arguments += '-ConfirmTerminal' }
  $output = & powershell.exe @arguments 2>&1
  $exitCode = $LASTEXITCODE
  try { $result = (($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine) | ConvertFrom-Json -ErrorAction Stop }
  catch { $result = $null }
  return [pscustomobject]@{ exitCode=$exitCode; result=$result; output=$output }
}

$c = New-TestController
try {
  $r = Run-Op $c 'enqueue-dispatch' '{"repoId":"repo-a","modelClass":"balanced","generation":1,"rework":false,"taskSpec":{"objective":"old"}}'
  Expect 'identity old dispatch enqueued' $r.ok
  $oldId = Get-PendingTailId $c 'repo-a'
  $r = Run-Op $c 'start-next-dispatch' '{"repoId":"repo-a","leaseId":"lease-old"}'
  Expect 'identity old dispatch started' $r.ok
  $r = Run-Op $c 'request-dispatch-cancel' '{"repoId":"repo-a"}'
  Expect 'identity old dispatch canceled' $r.ok

  $r = Run-Op $c 'enqueue-dispatch' '{"repoId":"repo-a","modelClass":"balanced","generation":2,"rework":false,"taskSpec":{"objective":"new"}}'
  Expect 'identity new dispatch enqueued' $r.ok
  $newId = Get-PendingTailId $c 'repo-a'
  $r = Run-Op $c 'start-next-dispatch' '{"repoId":"repo-a","leaseId":"lease-new"}'
  Expect 'identity new dispatch started' $r.ok
  $m = Read-Manifest $c
  $q = $m.dispatchQueues | Where-Object { $_.repoId -eq 'repo-a' }

  $late = '{"repoId":"repo-a","dispatchId":"' + $oldId + '","leaseId":"lease-old","taskSpecHash":"' + ('1' * 64) + '","resultState":"accepted-success","evidenceHash":"' + ('1' * 64) + '","finishedAtUtc":"2026-08-20T00:00:00Z"}'
  $r = Run-Op $c 'record-dispatch-outcome' $late
  Expect 'late outcome rejected by dispatch identity' (-not $r.ok -and $r.reason -eq 'active-dispatch-mismatch')
  $m = Read-Manifest $c
  $q = $m.dispatchQueues | Where-Object { $_.repoId -eq 'repo-a' }
  Expect 'late outcome leaves current dispatch active' ($q.active.dispatchId -eq $newId -and $q.active.leaseId -eq 'lease-new')

  $current = '{"repoId":"repo-a","dispatchId":"' + $newId + '","leaseId":"lease-new","taskSpecHash":"' + $q.active.taskSpecHash + '","resultState":"accepted-success","evidenceHash":"' + ('2' * 64) + '","finishedAtUtc":"2026-08-20T00:01:00Z"}'
  $r = Run-Op $c 'record-dispatch-outcome' $current
  Expect 'matching outcome closes current dispatch' $r.ok
}
finally { Remove-TestController $c }

$c = New-TestController
try {
  $r = Run-Op $c 'register-project' '{"projectRoot":"C:\\audit\\one","repoId":"same","entryAgentId":"agent-one"}'
  Expect 'unique repo id first binding registered' $r.ok
  $r = Run-Op $c 'register-project' '{"projectRoot":"C:\\audit\\two","repoId":"same","entryAgentId":"agent-two"}'
  Expect 'duplicate repo id rejected' (-not $r.ok -and $r.reason -eq 'repo-id-conflict')
  $m = Read-Manifest $c
  Expect 'duplicate repo id leaves one binding and queue' (@($m.projectBindings).Count -eq 1 -and @($m.dispatchQueues).Count -eq 1)
}
finally { Remove-TestController $c }

$c = New-TestController
try {
  $r = Run-Op $c 'enqueue-dispatch' '{"repoId":"repo-a","modelClass":"balanced","generation":1,"rework":false,"taskSpec":{"objective":"first"}}'
  $firstId = Get-PendingTailId $c 'repo-a'
  [void](Run-Op $c 'start-next-dispatch' '{"repoId":"repo-a","leaseId":"lease-1"}')
  [void](Complete-ActiveDispatch $c 'repo-a' '2026-08-20T01:00:00Z')
  [void](Run-Op $c 'enqueue-dispatch' '{"repoId":"repo-a","modelClass":"balanced","generation":1,"rework":false,"taskSpec":{"objective":"second"}}')
  [void](Run-Op $c 'start-next-dispatch' '{"repoId":"repo-a","leaseId":"lease-2"}')
  [void](Complete-ActiveDispatch $c 'repo-a' '2026-08-20T01:01:00Z')
  $dependent = '{"repoId":"repo-a","modelClass":"balanced","generation":1,"rework":false,"taskSpec":{"objective":"third"},"dependencies":[{"dispatchId":"' + $firstId + '"}]}'
  [void](Run-Op $c 'enqueue-dispatch' $dependent)
  $r = Run-Op $c 'start-next-dispatch' '{"repoId":"repo-a","leaseId":"lease-3"}'
  Expect 'historical accepted dependency remains resolvable' $r.ok
}
finally { Remove-TestController $c }

$c = New-TestController
try {
  [void](Run-Op $c 'freeze-contract' ('{"contractId":"api","version":"v1","hash":"' + ('1' * 64) + '","docPath":"docs\\api-v1.md"}'))
  [void](Run-Op $c 'freeze-contract' ('{"contractId":"api","version":"v2","hash":"' + ('2' * 64) + '","docPath":"docs\\api-v2.md"}'))
  $withoutVersion = '{"repoId":"repo-a","modelClass":"frontier","generation":1,"rework":false,"taskSpec":{"objective":"ambiguous contract"},"contractRef":"api"}'
  $r = Run-Op $c 'enqueue-dispatch' $withoutVersion
  Expect 'contract reference requires an exact version' (-not $r.ok -and $r.reason -eq 'contract-version-required')
  $withVersion = '{"repoId":"repo-a","modelClass":"frontier","generation":1,"rework":false,"taskSpec":{"objective":"pinned contract"},"contractRef":"api","contractVersion":"v1"}'
  $r = Run-Op $c 'enqueue-dispatch' $withVersion
  Expect 'versioned contract reference enqueued' $r.ok
  $m = Read-Manifest $c
  $item = ($m.dispatchQueues | Where-Object { $_.repoId -eq 'repo-a' }).pending[0]
  Expect 'dispatch stores contract version and hash' ($item.contractRef -eq 'api' -and $item.contractVersion -eq 'v1' -and $item.contractHash -eq ('1' * 64))
}
finally { Remove-TestController $c }

$c = New-ChainController
try {
  $record = [pscustomobject][ordered]@{ schemaVersion=1; chainId='chain-0123456789abcdef'; state='open'; phase='dispatch'; status='running'; objective='optional fields omitted' }
  $r = Put-ChainRecord $c $record $false 'MISSING'
  Expect 'chain accepts omitted optional fields' ($r.exitCode -eq 0 -and $null -ne $r.result -and $r.result.status -eq 'applied')
  $terminal = [pscustomobject][ordered]@{ schemaVersion=1; chainId='chain-0123456789abcdef'; state='terminal'; phase='complete'; status='accepted-success'; objective='archive integrity' }
  $closed = Put-ChainRecord $c $terminal $true ([string]$r.result.resultHash)
  Expect 'chain terminal record archived' ($closed.exitCode -eq 0 -and $closed.result.archived)
  [IO.File]::AppendAllText([string]$closed.result.archivePath, "not-json`n", [Text.UTF8Encoding]::new($false))
  $verify = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $c 'tools\chain-store.ps1') -Action Verify -ControllerRoot $c | ConvertFrom-Json
  Expect 'verify rejects corrupt archive' ($verify.status -eq 'corrupt' -and @($verify.failures) -contains 'chain-0123456789abcdef')
}
finally { Remove-TestController $c }

Finish-Tests 'integrity'
