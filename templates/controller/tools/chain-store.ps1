[CmdletBinding()]
param(
  [ValidateSet('Get', 'Put', 'Verify', 'Rebuild', 'RemoveCandidate')]
  [string]$Action = 'Verify',
  [Parameter(Mandatory = $true)]
  [string]$ControllerRoot,
  [string]$ChainId,
  [string]$CandidatePath,
  [string]$CandidateHash,
  [string]$ExpectedEntryHash,
  [switch]$ConfirmTerminal,
  [switch]$ConfirmCleanup
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
$utf8 = New-Object Text.UTF8Encoding($false, $true)
$root = [IO.Path]::GetFullPath($ControllerRoot)
$activeDir = Join-Path $root 'state\active'
$archiveDir = Join-Path $root 'state\archive'
$indexPath = Join-Path $root 'state\index.json'
$configPath = Join-Path $root '.chain-store.json'
$secretPattern = '(?is)(?:-----BEGIN [A-Z ]*PRIVATE KEY-----|\bbearer\s+[A-Za-z0-9._~+/=-]{8,}|\b(?:api[_-]?key|access[_-]?token|refresh[_-]?token|client[_-]?secret|password|passwd|pwd)\s*[:=]\s*\S+|\bgh[pousr]_[A-Za-z0-9]{20,}|\bgithub_pat_[A-Za-z0-9_]{20,}|\bsk-(?:proj-)?[A-Za-z0-9_-]{20,}|\bAKIA[0-9A-Z]{16}\b)'

function Get-Hash {
  param([byte[]]$Bytes)
  $sha = [Security.Cryptography.SHA256]::Create()
  try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
  finally { $sha.Dispose() }
}

function Get-LineHash {
  param([string]$Line)
  return Get-Hash ($utf8.GetBytes($Line))
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

function Read-Config {
  if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) { return $null }
  try { return (Get-Content -Raw -Encoding UTF8 -LiteralPath $configPath | ConvertFrom-Json) } catch { return $null }
}

function Get-ChainPath {
  param([string]$ChainId, [switch]$Archived)
  if ($Archived) { return Join-Path $archiveDir ($ChainId + '.jsonl') }
  return Join-Path $activeDir ($ChainId + '.jsonl')
}

function Get-ArchiveChainPath {
  param([string]$ChainId)
  $files = @(Get-ChildItem -LiteralPath $archiveDir -Recurse -Filter ($ChainId + '.jsonl') -File -ErrorAction SilentlyContinue)
  if ($files.Count -eq 1) { return $files[0].FullName }
  return $null
}

function Read-ChainFile {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return [pscustomobject]@{ Found=$false; Lines=@(); LastHash=$null; Corrupt=$false; Terminal=$false } }
  $lines = @([IO.File]::ReadAllLines($Path, $utf8))
  $lastHash = $null
  $corrupt = $false
  $terminal = $false
  $parsed = New-Object Collections.Generic.List[object]
  foreach ($line in $lines) {
    $expected = $null
    try {
      $entry = $line | ConvertFrom-Json -ErrorAction Stop
      $expected = if ($null -ne $entry.prevHash) { [string]$entry.prevHash } else { 'GENESIS' }
    }
    catch { $corrupt = $true; break }
    $computed = if ($lastHash -eq $null) { 'GENESIS' } else { $lastHash }
    if ($computed -cne $expected) { $corrupt = $true; break }
    $lastHash = Get-LineHash $line
    $parsed.Add($entry)
    if ([string]$entry.record.state -ceq 'terminal') { $terminal = $true }
  }
  return [pscustomobject]@{ Found=$true; Lines=$lines; Entries=$parsed.ToArray(); LastHash=$lastHash; Corrupt=$corrupt; Terminal=$terminal }
}

function Validate-Entry {
  param([object]$Entry, [bool]$Terminal)
  if ($null -eq $Entry -or $null -eq $Entry.record) { return $false }
  $record = $Entry.record
  foreach ($name in @($record.PSObject.Properties.Name)) {
    if ($name -cnotin @('schemaVersion','chainId','state','phase','status','createdAtUtc','updatedAtUtc','objective','nextAction','payload')) { return $false }
  }
  if ([int]$record.schemaVersion -ne 1) { return $false }
  if ($Terminal) {
    if ([string]$record.state -cne 'terminal') { return $false }
    if ([string]$record.status -cnotin @('accepted-success','deterministic-failure','transient-failure','blocked','superseded','canceled')) { return $false }
  }
  else {
    if ([string]$record.state -cne 'open') { return $false }
    if ([string]$record.status -cne 'running') { return $false }
  }
  if ([string]::IsNullOrWhiteSpace([string]$record.phase) -or ([string]$record.phase).Length -gt 64 -or [string]$record.phase -match '[\x00-\x1f\x7f]') { return $false }
  if ([string]::IsNullOrWhiteSpace([string]$record.objective) -or ([string]$record.objective).Length -gt 2000) { return $false }
  if ($null -ne $record.nextAction -and ([string]$record.nextAction).Length -gt 500) { return $false }
  $payloadJson = if ($null -ne $record.payload) { $record.payload | ConvertTo-Json -Depth 12 -Compress } else { '{}' }
  if ($payloadJson.Length -gt 16384) { return $false }
  if ($payloadJson -match $secretPattern) { return $false }
  $text = ($record | ConvertTo-Json -Depth 12 -Compress)
  if ($text -match $secretPattern) { return $false }
  return $true
}

function Read-Index {
  if (-not (Test-Path -LiteralPath $indexPath -PathType Leaf)) {
    return [pscustomobject]@{ Exists=$false; Data=$null }
  }
  try { return [pscustomobject]@{ Exists=$true; Data=(Get-Content -Raw -Encoding UTF8 -LiteralPath $indexPath | ConvertFrom-Json) } }
  catch { return [pscustomobject]@{ Exists=$true; Data=$null } }
}

function Update-Index {
  param([string]$ClosedChainId, [string]$ClosedAtUtc, [string]$ArchiveRelPath)
  $config = Read-Config
  $window = if ($null -ne $config -and $null -ne $config.recentTerminalWindow) { [int]$config.recentTerminalWindow } else { 20 }
  $index = Read-Index
  $recent = New-Object Collections.Generic.List[object]
  $totalArchived = 0
  if ($index.Exists -and $null -ne $index.Data) {
    foreach ($item in @($index.Data.recentTerminal)) { if ([string]$item.chainId -cne $ClosedChainId) { $recent.Add($item) } }
    $totalArchived = [int]$index.Data.totalArchived
  }
  $totalArchived = $totalArchived + 1
  $recent.Insert(0, [pscustomobject][ordered]@{ chainId=$ClosedChainId; closedAtUtc=$ClosedAtUtc; archivePath=$ArchiveRelPath })
  $trimmed = New-Object Collections.Generic.List[object]
  for ($i = 0; $i -lt [Math]::Min($window, $recent.Count); $i++) { $trimmed.Add($recent[$i]) }
  $activeChains = @(Get-ChildItem -LiteralPath $activeDir -Filter '*.jsonl' -File -ErrorAction SilentlyContinue | ForEach-Object { $_.BaseName } | Sort-Object)
  $newIndex = [pscustomobject][ordered]@{
    schemaVersion = 1
    activeChains = @($activeChains)
    recentTerminal = $trimmed.ToArray()
    totalArchived = $totalArchived
  }
  $bytes = $utf8.GetBytes(($newIndex | ConvertTo-Json -Depth 8 -Compress) + "`n")
  $stream = New-Object IO.FileStream($indexPath, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
  try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush() }
  finally { $stream.Dispose() }
  return $newIndex
}

switch ($Action) {
  'Get' {
    if ([string]::IsNullOrWhiteSpace($ChainId) -or $ChainId -notmatch '^chain-[0-9a-f]{16}$') { Write-Result 'invalid' ([ordered]@{ reasonCode='invalid-chain-id' }) 2 }
    $active = Read-ChainFile (Get-ChainPath $ChainId)
    if ($active.Found) {
      Write-Result 'verified' ([ordered]@{ chainId=$ChainId; entries=$active.Entries; lastHash=$active.LastHash; terminal=$active.Terminal; corrupt=$active.Corrupt; archived=$false; archivePath=$null }) 0
    }
    $archivePath = Get-ArchiveChainPath $ChainId
    if ($null -ne $archivePath) {
      $archived = Read-ChainFile $archivePath
      Write-Result 'verified' ([ordered]@{ chainId=$ChainId; entries=$archived.Entries; lastHash=$archived.LastHash; terminal=$archived.Terminal; corrupt=$archived.Corrupt; archived=$true; archivePath=$archivePath }) 0
    }
    Write-Result 'missing' ([ordered]@{ chainId=$ChainId }) 0
  }
  'Put' {
    if ([string]::IsNullOrWhiteSpace($CandidatePath) -or -not (Test-Path -LiteralPath $CandidatePath -PathType Leaf)) {
      Write-Result 'invalid' ([ordered]@{ reasonCode='candidate-not-found' }) 2
    }
    if ($CandidatePath -notmatch '(^|[\\/])\.[0-9a-f]{32}\.chain\.tmp$') { Write-Result 'invalid' ([ordered]@{ reasonCode='candidate-name-mismatch' }) 2 }
    $candidateBytes = [IO.File]::ReadAllBytes($CandidatePath)
    if ([string]::IsNullOrWhiteSpace($CandidateHash) -or $CandidateHash -cne (Get-Hash $candidateBytes)) {
      Write-Result 'conflict' ([ordered]@{ reasonCode='candidate-hash-mismatch' }) 1
    }
    $candidate = $null
    try { $candidate = ($utf8.GetString($candidateBytes)) | ConvertFrom-Json -ErrorAction Stop } catch { Write-Result 'invalid' ([ordered]@{ reasonCode='candidate-not-json' }) 2 }
    $chainId = [string]$candidate.chainId
    if ($chainId -notmatch '^chain-[0-9a-f]{16}$') { Write-Result 'invalid' ([ordered]@{ reasonCode='invalid-chain-id' }) 2 }
    $confirmTerminal = [bool]$candidate.confirmTerminal
    if ($confirmTerminal -and -not $ConfirmTerminal) { Write-Result 'authorization-required' ([ordered]@{ reasonCode='confirm-terminal-required' }) 1 }
    if ($ConfirmTerminal -and -not $confirmTerminal) { Write-Result 'invalid' ([ordered]@{ reasonCode='terminal-flag-mismatch' }) 2 }
    $entry = [pscustomobject]@{ record=$candidate.record }
    if (-not (Validate-Entry $entry $confirmTerminal)) { Write-Result 'invalid' ([ordered]@{ reasonCode='invalid-record' }) 2 }

    $active = Read-ChainFile (Get-ChainPath $chainId)
    if ($active.Corrupt) { Write-Result 'corrupt' ([ordered]@{ reasonCode='chain-corrupt' }) 1 }
    $expected = if ([string]::IsNullOrWhiteSpace($ExpectedEntryHash)) { if ($active.Found) { $active.LastHash } else { 'MISSING' } } else { $ExpectedEntryHash }
    if (-not $active.Found) {
      if ($expected -cne 'MISSING') { Write-Result 'conflict' ([ordered]@{ reasonCode='expected-missing-but-exists' }) 1 }
      [IO.Directory]::CreateDirectory($activeDir) | Out-Null
    }
    else {
      if ($expected -cne $active.LastHash) { Write-Result 'conflict' ([ordered]@{ reasonCode='stale-expected-hash'; currentHash=$active.LastHash }) 1 }
      if ($active.Terminal) { Write-Result 'conflict' ([ordered]@{ reasonCode='chain-already-terminal' }) 1 }
    }

    $now = ([DateTime]::UtcNow).ToString('o')
    $chainIdOfRecord = [string]$candidate.record.chainId
    if ($chainIdOfRecord -cne $chainId) { Write-Result 'invalid' ([ordered]@{ reasonCode='record-chain-id-mismatch' }) 2 }
    $seq = if ($active.Found) { $active.Entries.Count + 1 } else { 1 }
    $lineRecord = [pscustomobject][ordered]@{
      schemaVersion = [int]$candidate.record.schemaVersion
      chainId = [string]$candidate.record.chainId
      state = [string]$candidate.record.state
      phase = [string]$candidate.record.phase
      status = [string]$candidate.record.status
      createdAtUtc = if ($null -ne $candidate.record.createdAtUtc) { [string]$candidate.record.createdAtUtc } else { $now }
      updatedAtUtc = $now
      objective = [string]$candidate.record.objective
      nextAction = if ($null -ne $candidate.record.nextAction) { [string]$candidate.record.nextAction } else { $null }
      payload = if ($null -ne $candidate.record.payload) { $candidate.record.payload } else { $null }
    }
    $line = [pscustomobject][ordered]@{ seq=$seq; prevHash=if ($null -eq $active.LastHash) { $null } else { $active.LastHash }; record=$lineRecord } | ConvertTo-Json -Depth 12 -Compress
    $lineBytes = $utf8.GetBytes($line + "`n")
    $targetPath = Get-ChainPath $chainId
    $stream = New-Object IO.FileStream($targetPath, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.Write($lineBytes, 0, $lineBytes.Length); $stream.Flush() }
    finally { $stream.Dispose() }

    $after = Read-ChainFile $targetPath
    if ($after.Corrupt) { Write-Result 'corrupt' ([ordered]@{ reasonCode='chain-corrupt-after-write' }) 1 }
    $lastHash = Get-LineHash $line
    Remove-Item -LiteralPath $CandidatePath -Force -ErrorAction SilentlyContinue

    if ($confirmTerminal) {
      $month = ([DateTime]::UtcNow).ToString('yyyy-MM')
      $monthDir = Join-Path $archiveDir $month
      [IO.Directory]::CreateDirectory($monthDir) | Out-Null
      $archivePath = Join-Path $monthDir ($chainId + '.jsonl')
      if (Test-Path -LiteralPath $archivePath) { Write-Result 'conflict' ([ordered]@{ reasonCode='archive-path-exists' }) 1 }
      [IO.File]::Move($targetPath, $archivePath)
      $relPath = 'state\archive\' + $month + '\' + $chainId + '.jsonl'
      $index = Update-Index -ClosedChainId $chainId -ClosedAtUtc $now -ArchiveRelPath $relPath
      Write-Result 'applied' ([ordered]@{ chainId=$chainId; resultHash=$lastHash; archived=$true; archivePath=$archivePath; index=$index }) 0
    }
    else {
      $activeChains = @(Get-ChildItem -LiteralPath $activeDir -Filter '*.jsonl' -File -ErrorAction SilentlyContinue | ForEach-Object { $_.BaseName } | Sort-Object)
      $index = Read-Index
      if ($index.Exists -and $null -ne $index.Data) {
        $index.Data.activeChains = @($activeChains)
        $bytes = $utf8.GetBytes(($index.Data | ConvertTo-Json -Depth 8 -Compress) + "`n")
        $stream = New-Object IO.FileStream($indexPath, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush() }
        finally { $stream.Dispose() }
      }
      Write-Result 'applied' ([ordered]@{ chainId=$chainId; resultHash=$lastHash; archived=$false }) 0
    }
  }
  'Verify' {
    $failures = New-Object Collections.Generic.List[string]
    $files = @(Get-ChildItem -LiteralPath $activeDir -Filter '*.jsonl' -File -ErrorAction SilentlyContinue)
    foreach ($file in $files) {
      $chain = Read-ChainFile $file.FullName
      if ($chain.Corrupt -or $chain.Lines.Count -eq 0) { $failures.Add($file.BaseName) }
    }
    $index = Read-Index
    if (-not $index.Exists -or $null -eq $index.Data) { $failures.Add('index-missing-or-invalid') }
    if ($failures.Count -gt 0) {
      Write-Result 'corrupt' ([ordered]@{ failures=$failures.ToArray() }) 1
    }
    Write-Result 'verified' ([ordered]@{ activeChains=@($files | ForEach-Object { $_.BaseName }) }) 0
  }
  'Rebuild' {
    [IO.Directory]::CreateDirectory($activeDir) | Out-Null
    [IO.Directory]::CreateDirectory($archiveDir) | Out-Null
    $config = Read-Config
    $window = if ($null -ne $config -and $null -ne $config.recentTerminalWindow) { [int]$config.recentTerminalWindow } else { 20 }
    $activeChains = @(Get-ChildItem -LiteralPath $activeDir -Filter '*.jsonl' -File -ErrorAction SilentlyContinue | ForEach-Object { $_.BaseName } | Sort-Object)
    $archiveFiles = @(Get-ChildItem -LiteralPath $archiveDir -Recurse -Filter '*.jsonl' -File -ErrorAction SilentlyContinue)
    $terminals = New-Object Collections.Generic.List[object]
    foreach ($file in $archiveFiles) {
      $chain = Read-ChainFile $file.FullName
      if ($chain.Corrupt) { Write-Result 'corrupt' ([ordered]@{ reasonCode='archive-chain-corrupt'; chainId=$file.BaseName }) 1 }
      if ($chain.Terminal) {
        $updated = $null
        if ($chain.Entries.Count -gt 0) {
          try { $updated = [DateTime]::Parse([string]$chain.Entries[$chain.Entries.Count - 1].record.updatedAtUtc).ToUniversalTime() } catch { }
        }
        $relPath = 'state\archive\' + ([IO.Path]::GetFileName([IO.Path]::GetDirectoryName($file.FullName))) + '\' + $file.Name
        $terminals.Add([pscustomobject]@{ chainId=$file.BaseName; closedAtUtc=if ($null -ne $updated) { $updated.ToString('o') } else { $null }; archivePath=$relPath; file=$file.FullName })
      }
    }
    $sorted = @($terminals | Sort-Object { if ($null -ne $_.closedAtUtc) { [DateTime]::Parse($_.closedAtUtc).Ticks } else { 0 } } -Descending)
    $recent = New-Object Collections.Generic.List[object]
    for ($i = 0; $i -lt [Math]::Min($window, $sorted.Count); $i++) {
      $recent.Add([pscustomobject][ordered]@{ chainId=$sorted[$i].chainId; closedAtUtc=$sorted[$i].closedAtUtc; archivePath=$sorted[$i].archivePath })
    }
    $newIndex = [pscustomobject][ordered]@{
      schemaVersion = 1
      activeChains = @($activeChains)
      recentTerminal = $recent.ToArray()
      totalArchived = $archiveFiles.Count
    }
    $bytes = $utf8.GetBytes(($newIndex | ConvertTo-Json -Depth 8 -Compress) + "`n")
    $stream = New-Object IO.FileStream($indexPath, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush() }
    finally { $stream.Dispose() }
    Write-Result 'applied' ([ordered]@{ index=$newIndex }) 0
  }
  'RemoveCandidate' {
    if (-not $ConfirmCleanup) { Write-Result 'authorization-required' ([ordered]@{ reasonCode='confirm-cleanup-required' }) 1 }
    if ([string]::IsNullOrWhiteSpace($CandidatePath) -or -not (Test-Path -LiteralPath $CandidatePath -PathType Leaf)) {
      Write-Result 'invalid' ([ordered]@{ reasonCode='candidate-not-found' }) 2
    }
    if ($CandidatePath -notmatch '(^|[\\/])\.[0-9a-f]{32}\.chain\.tmp$') { Write-Result 'invalid' ([ordered]@{ reasonCode='candidate-name-mismatch' }) 2 }
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
