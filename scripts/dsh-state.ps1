[CmdletBinding()]
param(
  [ValidateSet('Read', 'Prepare', 'Apply', 'Verify', 'RemoveCandidate')]
  [string]$Action = 'Read',
  [Parameter(Mandatory = $true)]
  [string]$StateRoot,
  [Parameter(Mandatory = $true)]
  [string]$Name,
  [string]$PayloadJson,
  [string]$PayloadJsonBase64,
  [string]$CandidatePath,
  [string]$CandidateHash,
  [string]$ExpectedEntryHash,
  [switch]$ConfirmCleanup,
  [switch]$ConfirmTerminal
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
$utf8 = New-Object Text.UTF8Encoding($false, $true)

# ---------------------------------------------------------------------------
# Generic compare-and-swap state adapter for DSH workspace state files.
# One JSON file per name: <StateRoot>/<Name>.json
# Candidates:            <StateRoot>/.<Name>.<32hex>.tmp
#
# The adapter is the ONLY writer of the state file. Callers must never edit
# <Name>.json directly. Every mutation is a Read -> Prepare -> Apply -> Read
# (exact readback) cycle.
# ---------------------------------------------------------------------------

if ([string]::IsNullOrWhiteSpace($StateRoot) -or -not [IO.Path]::IsPathRooted($StateRoot)) {
  throw 'StateRoot must be an absolute directory path'
}
if ($Name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}(\\[A-Za-z0-9][A-Za-z0-9._-]{0,127}){0,4}$' -or
    $Name -match '^[A-Za-z]:' -or $Name -match '^[\\/]' -or $Name -match '(^|[\\/])\.\.([\\/]|$)') {
  throw 'Name must be a safe relative path (no drive, no leading slash, no dot-dot segments)'
}
$stateRoot = [IO.Path]::GetFullPath($StateRoot)
$targetPath = Join-Path $stateRoot ($Name + '.json')
$candidateLeaf = [IO.Path]::GetFileNameWithoutExtension($targetPath)

function Get-Hash {
  param([byte[]]$Bytes)
  $sha = [Security.Cryptography.SHA256]::Create()
  try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
  finally { $sha.Dispose() }
}

function Get-TextHash {
  param([string]$Text)
  return Get-Hash ($utf8.GetBytes($Text))
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
  $obj | ConvertTo-Json -Depth 12 -Compress
  exit $ExitCode
}

function Read-Current {
  if (-not (Test-Path -LiteralPath $targetPath -PathType Leaf)) {
    return [pscustomobject]@{ Exists=$false; Bytes=$null; Text=$null; Hash=$null; Data=$null }
  }
  $bytes = [IO.File]::ReadAllBytes($targetPath)
  $text = $utf8.GetString($bytes)
  $data = $null
  try { $data = $text | ConvertFrom-Json -ErrorAction Stop } catch { $data = $null }
  return [pscustomobject]@{ Exists=$true; Bytes=$bytes; Text=$text; Hash=(Get-Hash $bytes); Data=$data }
}

function Assert-ExpectedHash {
  param([string]$Expected, [object]$Current)
  if ($Expected -ceq 'MISSING') {
    if ($Current.Exists) { Write-Result 'conflict' ([ordered]@{ reasonCode='expected-missing-but-exists'; currentHash=$Current.Hash }) 1 }
    return
  }
  if (-not $Current.Exists) { Write-Result 'conflict' ([ordered]@{ reasonCode='expected-entry-missing' }) 1 }
  if ($Expected -cne $Current.Hash) { Write-Result 'conflict' ([ordered]@{ reasonCode='stale-expected-hash'; currentHash=$Current.Hash }) 1 }
}

$validatePayload = {
  param([string]$Json)
  if ([string]::IsNullOrWhiteSpace($Json) -or $Json.Length -gt 1MB) { return $null }
  try { return ($Json | ConvertFrom-Json -ErrorAction Stop) } catch { return $null }
}

switch ($Action) {
  'Read' {
    $current = Read-Current
    $orphans = @(Get-ChildItem -Force -LiteralPath (Split-Path -Parent $targetPath) -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -cmatch ('^\.' + [regex]::Escape($candidateLeaf) + '\.[0-9a-f]{32}\.tmp$') -and -not $_.PSIsContainer })
    if ($orphans.Count -gt 0) {
      Write-Result 'orphaned' ([ordered]@{ reasonCode='candidate-orphaned'; candidates=@($orphans | ForEach-Object { $_.Name }); currentHash=$current.Hash }) 0
    }
    Write-Result 'verified' ([ordered]@{ currentHash=$current.Hash; data=$current.Data; missing=(-not $current.Exists) }) 0
  }
  'Prepare' {
    if (-not [string]::IsNullOrWhiteSpace($PayloadJsonBase64)) {
      if (-not [string]::IsNullOrWhiteSpace($PayloadJson)) { Write-Result 'invalid' ([ordered]@{ reasonCode='both-payload-inputs-provided' }) 2 }
      try { $PayloadJson = $utf8.GetString([Convert]::FromBase64String($PayloadJsonBase64)) }
      catch { Write-Result 'invalid' ([ordered]@{ reasonCode='invalid-payload-base64' }) 2 }
    }
    $payload = & $validatePayload $PayloadJson
    if ($null -eq $payload) { Write-Result 'invalid' ([ordered]@{ reasonCode='invalid-payload' }) 2 }
    $current = Read-Current
    $expected = if ([string]::IsNullOrWhiteSpace($ExpectedEntryHash)) { if ($current.Exists) { $current.Hash } else { 'MISSING' } } else { $ExpectedEntryHash }
    Assert-ExpectedHash -Expected $expected -Current $current
    [IO.Directory]::CreateDirectory((Split-Path -Parent $targetPath)) | Out-Null
    [IO.Directory]::CreateDirectory($stateRoot) | Out-Null
    $candidateBytes = $utf8.GetBytes($PayloadJson.TrimEnd() + "`n")
    $candidateId = [guid]::NewGuid().ToString('N').ToLowerInvariant()
    $candidate = Join-Path (Split-Path -Parent $targetPath) ('.' + $candidateLeaf + '.' + $candidateId + '.tmp')
    $stream = New-Object IO.FileStream($candidate, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.Write($candidateBytes, 0, $candidateBytes.Length); $stream.Flush() }
    finally { $stream.Dispose() }
    Write-Result 'prepared' ([ordered]@{ candidatePath=$candidate; candidateHash=(Get-Hash $candidateBytes); expectedEntryHash=$expected; entryExists=$current.Exists }) 0
  }
  'Apply' {
    if ([string]::IsNullOrWhiteSpace($CandidatePath) -or -not (Test-Path -LiteralPath $CandidatePath -PathType Leaf)) {
      Write-Result 'invalid' ([ordered]@{ reasonCode='candidate-not-found' }) 2
    }
    if ($CandidatePath -notmatch ('(^|[\\/])\.' + [regex]::Escape($candidateLeaf) + '\.[0-9a-f]{32}\.tmp$')) {
      Write-Result 'invalid' ([ordered]@{ reasonCode='candidate-name-mismatch' }) 2
    }
    $candidateBytes = [IO.File]::ReadAllBytes($CandidatePath)
    if ([string]::IsNullOrWhiteSpace($CandidateHash) -or $CandidateHash -cne (Get-Hash $candidateBytes)) {
      Write-Result 'conflict' ([ordered]@{ reasonCode='candidate-hash-mismatch' }) 1
    }
    $current = Read-Current
    $expected = if ([string]::IsNullOrWhiteSpace($ExpectedEntryHash)) { if ($current.Exists) { $current.Hash } else { 'MISSING' } } else { $ExpectedEntryHash }
    Assert-ExpectedHash -Expected $expected -Current $current
    try {
      if ($candidateBytes.Length -eq 0 -or ($candidateBytes.Length -ge 3 -and $candidateBytes[0] -eq 0xEF -and $candidateBytes[1] -eq 0xBB -and $candidateBytes[2] -eq 0xBF)) {
        throw 'candidate-not-utf8-no-bom'
      }
      $candidateText = $utf8.GetString($candidateBytes)
      if (-not $candidateText.EndsWith("`n") -or $candidateText.Contains("`r") -or ($null -eq (& $validatePayload $candidateText))) {
        throw 'candidate-not-canonical-json'
      }
      [IO.Directory]::CreateDirectory((Split-Path -Parent $targetPath)) | Out-Null
      [IO.Directory]::CreateDirectory($stateRoot) | Out-Null
      if ($current.Exists) {
        Move-Item -LiteralPath $CandidatePath -Destination $targetPath -Force
      }
      else {
        [IO.File]::Move($CandidatePath, $targetPath)
      }
    }
    catch {
      throw
    }
    $after = Read-Current
    if (-not $after.Exists -or $after.Hash -cne (Get-Hash $candidateBytes)) {
      Write-Result 'conflict' ([ordered]@{ reasonCode='apply-readback-mismatch'; currentHash=$after.Hash }) 1
    }
    Write-Result 'applied' ([ordered]@{ resultHash=$after.Hash; previousHash=$current.Hash }) 0
  }
  'Verify' {
    $current = Read-Current
    if (-not $current.Exists) {
      Write-Result 'verified' ([ordered]@{ currentHash=$null; missing=$true; data=$null }) 0
    }
    if ($null -eq $current.Data) {
      Write-Result 'invalid' ([ordered]@{ reasonCode='state-file-not-json'; currentHash=$current.Hash }) 1
    }
    Write-Result 'verified' ([ordered]@{ currentHash=$current.Hash; missing=$false; data=$current.Data }) 0
  }
  'RemoveCandidate' {
    if (-not $ConfirmCleanup) { Write-Result 'authorization-required' ([ordered]@{ reasonCode='confirm-cleanup-required' }) 1 }
    if ([string]::IsNullOrWhiteSpace($CandidatePath) -or -not (Test-Path -LiteralPath $CandidatePath -PathType Leaf)) {
      Write-Result 'invalid' ([ordered]@{ reasonCode='candidate-not-found' }) 2
    }
    if ($CandidatePath -notmatch ('(^|[\\/])\.' + [regex]::Escape($candidateLeaf) + '\.[0-9a-f]{32}\.tmp$')) {
      Write-Result 'invalid' ([ordered]@{ reasonCode='candidate-name-mismatch' }) 2
    }
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
