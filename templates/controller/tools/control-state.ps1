[CmdletBinding()]
param(
  [ValidateSet('Read', 'PrepareCandidate', 'ApplyCandidate', 'RemoveCandidate')]
  [string]$Action = 'Read',
  [Parameter(Mandatory = $true)]
  [string]$ControllerRoot,
  [ValidateSet(
    'set-controller-agent', 'register-project', 'replace-project-binding',
    'enqueue-dispatch', 'start-next-dispatch', 'advance-dispatch',
    'record-dispatch-outcome', 'request-dispatch-cancel', 'retry-dispatch',
    'set-model-tier')]
  [string]$Operation,
  [string]$PayloadJson,
  [string]$PayloadJsonBase64,
  [string]$CandidatePath,
  [string]$CandidateHash,
  [string]$ExpectedHash,
  [switch]$ConfirmCleanup
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
$utf8 = New-Object Text.UTF8Encoding($false, $true)
$manifestPath = Join-Path ([IO.Path]::GetFullPath($ControllerRoot)) '.dsh-controller.json'
$secretPattern = '(?is)(?:-----BEGIN [A-Z ]*PRIVATE KEY-----|\bbearer\s+[A-Za-z0-9._~+/=-]{8,}|\b(?:api[_-]?key|access[_-]?token|refresh[_-]?token|client[_-]?secret|password|passwd|pwd)\s*[:=]\s*\S+|\bgh[pousr]_[A-Za-z0-9]{20,}|\bgithub_pat_[A-Za-z0-9_]{20,}|\bsk-(?:proj-)?[A-Za-z0-9_-]{20,}|\bAKIA[0-9A-Z]{16}\b)'

function Get-Hash {
  param([byte[]]$Bytes)
  $sha = [Security.Cryptography.SHA256]::Create()
  try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
  finally { $sha.Dispose() }
}

function Write-Result {
  param([string]$Status, [AllowNull()][object]$Fields, [int]$ExitCode)
  $obj = New-Object PSObject
  $obj | Add-Member -NotePropertyName 'schemaVersion' -NotePropertyValue 1
  $obj | Add-Member -NotePropertyName 'status' -NotePropertyValue $Status
  if ($null -ne $Fields) {
    if ($Fields -is [Collections.IDictionary]) {
      foreach ($entry in $Fields.GetEnumerator()) {
        $obj | Add-Member -NotePropertyName ([string]$entry.Key) -NotePropertyValue $entry.Value
      }
    }
    else {
      foreach ($prop in @($Fields.PSObject.Properties)) {
        $obj | Add-Member -NotePropertyName ([string]$prop.Name) -NotePropertyValue $prop.Value
      }
    }
  }
  $obj | ConvertTo-Json -Depth 16 -Compress
  exit $ExitCode
}

function Read-Manifest {
  if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    return [pscustomobject]@{ Exists=$false; Bytes=$null; Hash=$null; Data=$null }
  }
  $bytes = [IO.File]::ReadAllBytes($manifestPath)
  $data = $null
  try { $data = ($utf8.GetString($bytes)) | ConvertFrom-Json -ErrorAction Stop } catch { $data = $null }
  return [pscustomobject]@{ Exists=$true; Bytes=$bytes; Hash=(Get-Hash $bytes); Data=$data }
}

function Assert-NoSecrets {
  param([string]$Json)
  if ($Json -match $secretPattern) { Write-Result 'invalid' ([ordered]@{ reasonCode='secret-shaped-value-rejected' }) 2 }
}

function Test-NormalizedRoot {
  param([string]$Value)
  if ([string]::IsNullOrWhiteSpace($Value) -or $Value -notmatch '^[A-Za-z]:\\' -or $Value.Contains('/') -or $Value.Substring(2).Contains(':')) { return $false }
  try { $full = [IO.Path]::GetFullPath($Value) } catch { return $false }
  return $full -ceq $Value.TrimEnd('\')
}

function Test-ClosedKeys {
  param([object]$Object, [string[]]$Allowed)
  if ($null -eq $Object) { return $false }
  foreach ($name in @($Object.PSObject.Properties.Name)) { if ($name -cnotin $Allowed) { return $false } }
  foreach ($name in $Allowed) { if (-not ($Object.PSObject.Properties.Name -contains $name)) { return $false } }
  return $true
}

function Test-DispatchTaskSpec {
  param([object]$Spec)
  if ($null -eq $Spec) { return $false }
  $text = $Spec | ConvertTo-Json -Depth 12 -Compress
  return ($text.Length -le 8192)
}

function New-Queue {
  param([string]$RepoId)
  return [pscustomobject][ordered]@{ repoId=$RepoId; active=$null; pending=@(); lastTerminal=$null }
}

function Get-QueueRef {
  param([object]$Manifest, [string]$RepoId)
  foreach ($queue in @($Manifest.dispatchQueues)) {
    if ([string]$queue.repoId -ceq $RepoId) { return [pscustomobject]@{ Found=$true; Queue=$queue } }
  }
  return [pscustomobject]@{ Found=$false; Queue=$null }
}

function Invoke-Operation {
  param([object]$Manifest, [string]$Operation, [object]$Payload)

  switch ($Operation) {
    'set-controller-agent' {
      if (-not (Test-ClosedKeys $Payload @('agentId')) -or
          [string]::IsNullOrWhiteSpace([string]$Payload.agentId) -or
          ([string]$Payload.agentId).Length -gt 128 -or
          [string]$Payload.agentId -match '[\x00-\x1f\x7f]') { return $null }
      if ($null -ne $Manifest.controllerAgentId -and [string]$Manifest.controllerAgentId -cne [string]$Payload.agentId) {
        return [pscustomobject]@{ Error='controller-agent-conflict' }
      }
      $Manifest.controllerAgentId = [string]$Payload.agentId
      return $Manifest
    }
    'register-project' {
      if (-not (Test-ClosedKeys $Payload @('projectRoot', 'repoId', 'entryAgentId'))) { return $null }
      if (-not (Test-NormalizedRoot ([string]$Payload.projectRoot))) { return [pscustomobject]@{ Error='invalid-project-root' } }
      if ([string]::IsNullOrWhiteSpace([string]$Payload.repoId) -or [string]$Payload.repoId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$') { return [pscustomobject]@{ Error='invalid-repo-id' } }
      if ([string]::IsNullOrWhiteSpace([string]$Payload.entryAgentId) -or ([string]$Payload.entryAgentId).Length -gt 128) { return [pscustomobject]@{ Error='invalid-entry-agent-id' } }
      foreach ($binding in @($Manifest.projectBindings)) {
        if ([string]$binding.projectRoot -ieq [string]$Payload.projectRoot) { return [pscustomobject]@{ Error='project-binding-conflict' } }
      }
      $Manifest.projectBindings += [pscustomobject][ordered]@{
        projectRoot = [string]$Payload.projectRoot
        repoId = [string]$Payload.repoId
        entryAgentId = [string]$Payload.entryAgentId
        registeredAtUtc = ([DateTime]::UtcNow).ToString('o')
      }
      $queueRef = Get-QueueRef -Manifest $Manifest -RepoId ([string]$Payload.repoId)
      if (-not $queueRef.Found) { $Manifest.dispatchQueues += (New-Queue ([string]$Payload.repoId)) }
      return $Manifest
    }
    'replace-project-binding' {
      if (-not (Test-ClosedKeys $Payload @('projectRoot', 'expectedEntryAgentId', 'replacementEntryAgentId'))) { return $null }
      if (-not (Test-NormalizedRoot ([string]$Payload.projectRoot))) { return [pscustomobject]@{ Error='invalid-project-root' } }
      if ([string]$Payload.expectedEntryAgentId -ceq [string]$Payload.replacementEntryAgentId) { return [pscustomobject]@{ Error='replacement-identical' } }
      $found = $false
      foreach ($binding in @($Manifest.projectBindings)) {
        if ([string]$binding.projectRoot -ieq [string]$Payload.projectRoot) {
          $found = $true
          if ([string]$binding.entryAgentId -cne [string]$Payload.expectedEntryAgentId) { return [pscustomobject]@{ Error='project-binding-conflict' } }
          $binding.entryAgentId = [string]$Payload.replacementEntryAgentId
        }
      }
      if (-not $found) { return [pscustomobject]@{ Error='project-not-registered' } }
      return $Manifest
    }
    'enqueue-dispatch' {
      if (-not (Test-ClosedKeys $Payload @('repoId', 'modelClass', 'taskSpec', 'generation', 'rework'))) { return $null }
      if ([string]$Payload.modelClass -cnotin @('economy', 'balanced', 'frontier')) { return [pscustomobject]@{ Error='invalid-model-class' } }
      if ([int]$Payload.generation -lt 1 -or [int]$Payload.generation -gt 1000) { return [pscustomobject]@{ Error='invalid-generation' } }
      if ($Payload.rework -isnot [bool]) { return [pscustomobject]@{ Error='invalid-rework' } }
      if (-not (Test-DispatchTaskSpec $Payload.taskSpec)) { return [pscustomobject]@{ Error='invalid-task-spec' } }
      $queueRef = Get-QueueRef -Manifest $Manifest -RepoId ([string]$Payload.repoId)
      if (-not $queueRef.Found) { $queueRef = [pscustomobject]@{ Found=$true; Queue=(New-Queue ([string]$Payload.repoId)) }; $Manifest.dispatchQueues += $queueRef.Queue }
      $seq = [int]$Manifest.dispatchSeq + 1
      $Manifest.dispatchSeq = $seq
      $dispatchId = 'D-' + $seq.ToString('0000')
      $queueRef.Queue.pending += [pscustomobject][ordered]@{
        dispatchId = $dispatchId
        modelClass = [string]$Payload.modelClass
        taskSpec = $Payload.taskSpec
        generation = [int]$Payload.generation
        rework = [bool]$Payload.rework
        enqueuedAtUtc = ([DateTime]::UtcNow).ToString('o')
      }
      return $Manifest
    }
    'start-next-dispatch' {
      if (-not (Test-ClosedKeys $Payload @('repoId', 'leaseId'))) { return $null }
      if ([string]::IsNullOrWhiteSpace([string]$Payload.leaseId) -or ([string]$Payload.leaseId).Length -gt 128) { return [pscustomobject]@{ Error='invalid-lease-id' } }
      $queueRef = Get-QueueRef -Manifest $Manifest -RepoId ([string]$Payload.repoId)
      if (-not $queueRef.Found) { return [pscustomobject]@{ Error='queue-not-found' } }
      if ($null -ne $queueRef.Queue.active) { return [pscustomobject]@{ Error='queue-already-active' } }
      if (@($queueRef.Queue.pending).Count -eq 0) { return [pscustomobject]@{ Error='queue-empty' } }
      $head = $queueRef.Queue.pending[0]
      $rest = New-Object Collections.Generic.List[object]
      for ($i = 1; $i -lt @($queueRef.Queue.pending).Count; $i++) { $rest.Add($queueRef.Queue.pending[$i]) }
      $queueRef.Queue.pending = $rest.ToArray()
      $queueRef.Queue.active = [pscustomobject][ordered]@{
        dispatchId = [string]$head.dispatchId
        leaseId = [string]$Payload.leaseId
        phase = 'dispatched'
        startedAtUtc = ([DateTime]::UtcNow).ToString('o')
      }
      return $Manifest
    }
    'advance-dispatch' {
      if (-not (Test-ClosedKeys $Payload @('repoId', 'phase'))) { return $null }
      if ([string]::IsNullOrWhiteSpace([string]$Payload.phase) -or ([string]$Payload.phase).Length -gt 64 -or [string]$Payload.phase -match '[\x00-\x1f\x7f]') { return [pscustomobject]@{ Error='invalid-phase' } }
      $queueRef = Get-QueueRef -Manifest $Manifest -RepoId ([string]$Payload.repoId)
      if (-not $queueRef.Found -or $null -eq $queueRef.Queue.active) { return [pscustomobject]@{ Error='no-active-dispatch' } }
      $queueRef.Queue.active.phase = [string]$Payload.phase
      return $Manifest
    }
    'record-dispatch-outcome' {
      if (-not (Test-ClosedKeys $Payload @('repoId', 'taskSpecHash', 'resultState', 'evidenceHash', 'finishedAtUtc'))) { return $null }
      if ([string]$Payload.resultState -cnotin @('accepted-success', 'deterministic-failure', 'transient-failure', 'blocked', 'superseded', 'canceled')) { return [pscustomobject]@{ Error='invalid-result-state' } }
      if ([string]::IsNullOrWhiteSpace([string]$Payload.taskSpecHash) -or [string]$Payload.taskSpecHash -notmatch '^[0-9a-f]{64}$') { return [pscustomobject]@{ Error='invalid-task-spec-hash' } }
      if ([string]::IsNullOrWhiteSpace([string]$Payload.evidenceHash) -or [string]$Payload.evidenceHash -notmatch '^[0-9a-f]{64}$') { return [pscustomobject]@{ Error='invalid-evidence-hash' } }
      try { $finished = [DateTime]::Parse([string]$Payload.finishedAtUtc).ToUniversalTime() } catch { return [pscustomobject]@{ Error='invalid-finished-at' } }
      $queueRef = Get-QueueRef -Manifest $Manifest -RepoId ([string]$Payload.repoId)
      if (-not $queueRef.Found -or $null -eq $queueRef.Queue.active) { return [pscustomobject]@{ Error='no-active-dispatch' } }
      $queueRef.Queue.lastTerminal = [pscustomobject][ordered]@{
        dispatchId = [string]$queueRef.Queue.active.dispatchId
        resultState = [string]$Payload.resultState
        taskSpecHash = [string]$Payload.taskSpecHash
        evidenceHash = [string]$Payload.evidenceHash
        finishedAtUtc = $finished.ToString('o')
      }
      $queueRef.Queue.active = $null
      return $Manifest
    }
    'request-dispatch-cancel' {
      if (-not (Test-ClosedKeys $Payload @('repoId'))) { return $null }
      $queueRef = Get-QueueRef -Manifest $Manifest -RepoId ([string]$Payload.repoId)
      if (-not $queueRef.Found -or $null -eq $queueRef.Queue.active) { return [pscustomobject]@{ Error='no-active-dispatch' } }
      $queueRef.Queue.lastTerminal = [pscustomobject][ordered]@{
        dispatchId = [string]$queueRef.Queue.active.dispatchId
        resultState = 'canceled'
        taskSpecHash = $null
        evidenceHash = $null
        finishedAtUtc = ([DateTime]::UtcNow).ToString('o')
      }
      $queueRef.Queue.active = $null
      return $Manifest
    }
    'retry-dispatch' {
      if (-not (Test-ClosedKeys $Payload @('repoId', 'expectedDispatchId', 'modelClass', 'taskSpec', 'generation'))) { return $null }
      if ([string]$Payload.modelClass -cnotin @('economy', 'balanced', 'frontier')) { return [pscustomobject]@{ Error='invalid-model-class' } }
      if (-not (Test-DispatchTaskSpec $Payload.taskSpec)) { return [pscustomobject]@{ Error='invalid-task-spec' } }
      $queueRef = Get-QueueRef -Manifest $Manifest -RepoId ([string]$Payload.repoId)
      if (-not $queueRef.Found -or $null -eq $queueRef.Queue.lastTerminal) { return [pscustomobject]@{ Error='no-terminal-dispatch' } }
      if ([string]$queueRef.Queue.lastTerminal.dispatchId -cne [string]$Payload.expectedDispatchId) { return [pscustomobject]@{ Error='stale-terminal-dispatch' } }
      $seq = [int]$Manifest.dispatchSeq + 1
      $Manifest.dispatchSeq = $seq
      $dispatchId = 'D-' + $seq.ToString('0000')
      $queueRef.Queue.pending += [pscustomobject][ordered]@{
        dispatchId = $dispatchId
        modelClass = [string]$Payload.modelClass
        taskSpec = $Payload.taskSpec
        generation = [int]$Payload.generation
        rework = $true
        enqueuedAtUtc = ([DateTime]::UtcNow).ToString('o')
      }
      return $Manifest
    }
    'set-model-tier' {
      if (-not (Test-ClosedKeys $Payload @('tier', 'model'))) { return $null }
      if ([string]$Payload.tier -cnotin @('economy', 'balanced', 'frontier')) { return [pscustomobject]@{ Error='invalid-tier' } }
      $model = $Payload.model
      if ($null -eq $model) {
        $Manifest.modelTiers.([string]$Payload.tier) = $null
        return $Manifest
      }
      if (-not (Test-ClosedKeys $model @('provider', 'model'))) { return [pscustomobject]@{ Error='invalid-model-object' } }
      if ([string]::IsNullOrWhiteSpace([string]$model.provider) -or [string]$model.provider.Length -gt 64 -or
          [string]::IsNullOrWhiteSpace([string]$model.model) -or [string]$model.model.Length -gt 128) { return [pscustomobject]@{ Error='invalid-model-object' } }
      $Manifest.modelTiers.([string]$Payload.tier) = [pscustomobject][ordered]@{ provider=[string]$model.provider; model=[string]$model.model }
      return $Manifest
    }
    default { return $null }
  }
}

switch ($Action) {
  'Read' {
    $current = Read-Manifest
    $orphans = @(Get-ChildItem -Force -LiteralPath ([IO.Path]::GetFullPath($ControllerRoot)) -ErrorAction SilentlyContinue |
      Where-Object { ($_.Name -cmatch '^\.[0-9a-f]{32}\.candidate\.tmp$' -or $_.Name -cmatch '^\.[0-9a-f]{32}\.apply\.tmp$') -and -not $_.PSIsContainer })
    if ($orphans.Count -gt 0) {
      Write-Result 'orphaned' ([ordered]@{ reasonCode='candidate-orphaned'; candidates=@($orphans | ForEach-Object { $_.Name }); currentHash=$current.Hash }) 0
    }
    if (-not $current.Exists) { Write-Result 'verified' ([ordered]@{ currentHash=$null; missing=$true; data=$null }) 0 }
    if ($null -eq $current.Data) { Write-Result 'invalid' ([ordered]@{ reasonCode='manifest-not-json'; currentHash=$current.Hash }) 1 }
    if ([int]$current.Data.schemaVersion -ne 1 -or [string]$current.Data.generator -cne 'onboard-dsh-projects') {
      Write-Result 'invalid' ([ordered]@{ reasonCode='manifest-schema-mismatch'; currentHash=$current.Hash }) 1
    }
    Write-Result 'verified' ([ordered]@{ currentHash=$current.Hash; missing=$false; data=$current.Data }) 0
  }
  'PrepareCandidate' {
    if ([string]::IsNullOrWhiteSpace($Operation)) { Write-Result 'invalid' ([ordered]@{ reasonCode='operation-required' }) 2 }
    if (-not [string]::IsNullOrWhiteSpace($PayloadJsonBase64)) {
      if (-not [string]::IsNullOrWhiteSpace($PayloadJson)) { Write-Result 'invalid' ([ordered]@{ reasonCode='both-payload-inputs-provided' }) 2 }
      try { $PayloadJson = $utf8.GetString([Convert]::FromBase64String($PayloadJsonBase64)) }
      catch { Write-Result 'invalid' ([ordered]@{ reasonCode='invalid-payload-base64' }) 2 }
    }
    Assert-NoSecrets $PayloadJson
    $payload = $null
    try { $payload = $PayloadJson | ConvertFrom-Json -ErrorAction Stop } catch { Write-Result 'invalid' ([ordered]@{ reasonCode='invalid-payload' }) 2 }
    $current = Read-Manifest
    if (-not $current.Exists -or $null -eq $current.Data) { Write-Result 'conflict' ([ordered]@{ reasonCode='manifest-missing-or-invalid' }) 1 }
    $expected = if ([string]::IsNullOrWhiteSpace($ExpectedHash)) { $current.Hash } else { $ExpectedHash }
    if ($expected -cne $current.Hash) { Write-Result 'conflict' ([ordered]@{ reasonCode='stale-expected-hash'; currentHash=$current.Hash }) 1 }
    # Apply operation to a deep copy of the manifest.
    $manifestText = ($current.Data | ConvertTo-Json -Depth 16 -Compress)
    $copy = $manifestText | ConvertFrom-Json
    $result = Invoke-Operation -Manifest $copy -Operation $Operation -Payload $payload
    if ($null -eq $result) { Write-Result 'invalid' ([ordered]@{ reasonCode='invalid-operation-payload' }) 2 }
    if (@($result.PSObject.Properties.Name) -ccontains 'Error') { Write-Result 'conflict' ([ordered]@{ reasonCode=[string]$result.Error }) 1 }
    $resultBytes = $utf8.GetBytes((($result | ConvertTo-Json -Depth 16 -Compress) + "`n"))
    $candidateId = [guid]::NewGuid().ToString('N').ToLowerInvariant()
    $candidate = Join-Path ([IO.Path]::GetFullPath($ControllerRoot)) ('.' + $candidateId + '.candidate.tmp')
    $candidateText = [pscustomobject][ordered]@{
      schemaVersion = 1
      operation = $Operation
      payload = $payload
      expectedEntryHash = $expected
      resultManifestBytesHash = (Get-Hash $resultBytes)
    } | ConvertTo-Json -Depth 12 -Compress
    $candidateContent = [pscustomobject][ordered]@{
      schemaVersion = 1
      operation = $Operation
      payload = $payload
      expectedEntryHash = $expected
      resultManifest = $result
    } | ConvertTo-Json -Depth 16 -Compress
    $candidateBytes = $utf8.GetBytes($candidateContent.TrimEnd() + "`n")
    $stream = New-Object IO.FileStream($candidate, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.Write($candidateBytes, 0, $candidateBytes.Length); $stream.Flush() }
    finally { $stream.Dispose() }
    Write-Result 'prepared' ([ordered]@{ candidatePath=$candidate; candidateHash=(Get-Hash $candidateBytes); expectedEntryHash=$expected }) 0
  }
  'ApplyCandidate' {
    if ([string]::IsNullOrWhiteSpace($CandidatePath) -or -not (Test-Path -LiteralPath $CandidatePath -PathType Leaf)) {
      Write-Result 'invalid' ([ordered]@{ reasonCode='candidate-not-found' }) 2
    }
    if ($CandidatePath -notmatch '(^|[\\/])\.[0-9a-f]{32}\.candidate\.tmp$') { Write-Result 'invalid' ([ordered]@{ reasonCode='candidate-name-mismatch' }) 2 }
    $candidateBytes = [IO.File]::ReadAllBytes($CandidatePath)
    if ([string]::IsNullOrWhiteSpace($CandidateHash) -or $CandidateHash -cne (Get-Hash $candidateBytes)) {
      Write-Result 'conflict' ([ordered]@{ reasonCode='candidate-hash-mismatch' }) 1
    }
    $candidate = $null
    try { $candidate = ($utf8.GetString($candidateBytes)) | ConvertFrom-Json -ErrorAction Stop } catch { Write-Result 'invalid' ([ordered]@{ reasonCode='candidate-not-json' }) 2 }
    if ([string]$candidate.operation -cne $Operation) { Write-Result 'invalid' ([ordered]@{ reasonCode='candidate-operation-mismatch' }) 2 }
    $current = Read-Manifest
    $expected = if ([string]::IsNullOrWhiteSpace($ExpectedHash)) { $candidate.expectedEntryHash } else { $ExpectedHash }
    if ([string]::IsNullOrWhiteSpace($expected) -or $expected -cne $current.Hash) {
      Write-Result 'conflict' ([ordered]@{ reasonCode='stale-expected-hash'; currentHash=$current.Hash }) 1
    }
    $resultBytes = $utf8.GetBytes((($candidate.resultManifest | ConvertTo-Json -Depth 16 -Compress) + "`n"))
    [IO.Directory]::CreateDirectory((Split-Path -Parent $manifestPath)) | Out-Null
    $applyTmp = Join-Path (Split-Path -Parent $manifestPath) ('.' + [guid]::NewGuid().ToString('N').ToLowerInvariant() + '.apply.tmp')
    $stream = New-Object IO.FileStream($applyTmp, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.Write($resultBytes, 0, $resultBytes.Length); $stream.Flush() }
    finally { $stream.Dispose() }
    Move-Item -LiteralPath $applyTmp -Destination $manifestPath -Force
    Remove-Item -LiteralPath $CandidatePath -Force
    $after = Read-Manifest
    if (-not $after.Exists -or $after.Hash -cne (Get-Hash $resultBytes)) {
      Write-Result 'conflict' ([ordered]@{ reasonCode='apply-readback-mismatch'; currentHash=$after.Hash }) 1
    }
    Write-Result 'applied' ([ordered]@{ resultHash=$after.Hash; previousHash=$current.Hash }) 0
  }
  'RemoveCandidate' {
    if (-not $ConfirmCleanup) { Write-Result 'authorization-required' ([ordered]@{ reasonCode='confirm-cleanup-required' }) 1 }
    if ([string]::IsNullOrWhiteSpace($CandidatePath) -or -not (Test-Path -LiteralPath $CandidatePath -PathType Leaf)) {
      Write-Result 'invalid' ([ordered]@{ reasonCode='candidate-not-found' }) 2
    }
    if ($CandidatePath -notmatch '(^|[\\/])\.[0-9a-f]{32}\.candidate\.tmp$') { Write-Result 'invalid' ([ordered]@{ reasonCode='candidate-name-mismatch' }) 2 }
    if ([string]::IsNullOrWhiteSpace($CandidateHash) -or $CandidateHash -cne (Get-Hash ([IO.File]::ReadAllBytes($CandidatePath)))) {
      Write-Result 'conflict' ([ordered]@{ reasonCode='candidate-hash-mismatch' }) 1
    }
    Remove-Item -LiteralPath $CandidatePath -Force
    Write-Result 'removed' $null 0
  }
  default {
    Write-Result 'invalid' ([ordered]@{ reasonCode='unknown-action' }) 2
  }
}
