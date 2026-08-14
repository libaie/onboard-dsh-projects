[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$RepositoryRoot,
  [Parameter(Mandatory = $true)]
  [string]$IndexDir,
  [ValidateSet('fast', 'moderate', 'full')]
  [string]$IndexMode = 'fast'
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
$utf8 = New-Object Text.UTF8Encoding($false, $true)

# ---------------------------------------------------------------------------
# DSH lightweight repository index.
# Replaces the codebase-memory MCP of the upstream Codex skill with plain,
# agent-navigable markdown/JSON generated inside the DSH workspace.
#
# fast     : structure.md (file tree) + meta.json
# moderate : + entrypoints.md (package entry points, workspaces, scripts)
# full     : + docs.md (documentation pointers), glossary.md (seed template)
#
# This script NEVER writes into the repository being indexed. It only reads
# the repository and writes the index under IndexDir (inside the DSH workspace).
# ---------------------------------------------------------------------------

$repoRoot = $null
try { $repoRoot = [IO.Path]::GetFullPath($RepositoryRoot).TrimEnd('\') }
catch { }
if ([string]::IsNullOrWhiteSpace($repoRoot) -or -not (Test-Path -LiteralPath $repoRoot -PathType Container)) {
  [pscustomobject][ordered]@{ schemaVersion=1; status='index-unavailable'; reasonCode='repository-root-invalid'; repositoryRoot=$RepositoryRoot } |
    ConvertTo-Json -Depth 4 -Compress
  exit 1
}

$indexDir = [IO.Path]::GetFullPath($IndexDir)
[IO.Directory]::CreateDirectory($indexDir) | Out-Null

function Invoke-Git {
  param([string]$GitPath, [string[]]$Arguments)
  $old = $ErrorActionPreference
  $ErrorActionPreference = 'SilentlyContinue'
  try {
    $out = @(& $GitPath @Arguments 2>$null | ForEach-Object { [string]$_ })
    return [pscustomobject]@{ ExitCode=$LASTEXITCODE; Output=@($out) }
  }
  finally { $ErrorActionPreference = $old }
}

function Get-GitInfo {
  $git = @(Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1)
  if ($git.Count -ne 1) { return $null }
  $gitPath = $git[0].Source
  $isRepoResult = Invoke-Git $gitPath @('-C', $repoRoot, 'rev-parse', '--is-inside-work-tree')
  if ($isRepoResult.ExitCode -ne 0 -or @($isRepoResult.Output).Count -eq 0 -or $isRepoResult.Output[0] -cne 'true') { return $null }
  $repositoryId = $null
  $remoteResult = Invoke-Git $gitPath @('-C', $repoRoot, 'config', '--get', 'remote.origin.url')
  if ($remoteResult.ExitCode -eq 0 -and @($remoteResult.Output).Count -gt 0) { $repositoryId = $remoteResult.Output[0] }
  if ([string]::IsNullOrWhiteSpace($repositoryId)) { $repositoryId = 'no-remote' }
  $branch = $null
  $branchResult = Invoke-Git $gitPath @('-C', $repoRoot, 'rev-parse', '--abbrev-ref', 'HEAD')
  if ($branchResult.ExitCode -eq 0 -and @($branchResult.Output).Count -gt 0) { $branch = $branchResult.Output[0] }
  if ([string]::IsNullOrWhiteSpace($branch)) { $branch = 'unborn' }
  $head = $null
  $headResult = Invoke-Git $gitPath @('-C', $repoRoot, 'rev-parse', 'HEAD')
  if ($headResult.ExitCode -eq 0 -and @($headResult.Output).Count -gt 0) { $head = $headResult.Output[0] }
  $dirty = $false
  $statusResult = Invoke-Git $gitPath @('-C', $repoRoot, 'status', '--porcelain=v1')
  if (@($statusResult.Output).Count -gt 0) { $dirty = $true }
  return [pscustomobject][ordered]@{
    isGit = $true
    repositoryId = $repositoryId
    branch = $branch
    head = $head
    dirty = $dirty
    worktreeRoot = $repoRoot
  }
}

function Get-FileLines {
  $lines = New-Object Collections.Generic.List[string]
  if ((Test-Path -LiteralPath (Join-Path $repoRoot '.git'))) {
    $git = @(Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($git.Count -eq 1) {
      $tracked = Invoke-Git $git[0].Source @('-C', $repoRoot, 'ls-files')
      foreach ($line in @($tracked.Output)) { if ($lines.Count -lt 2000) { $lines.Add($line) } }
      if ($lines.Count -gt 0) { return @($lines) }
    }
  }
  # Non-git fallback: bounded recursive walk.
  Get-ChildItem -LiteralPath $repoRoot -Recurse -File -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notmatch '\\(\.git|node_modules|\.next|dist|build|target|\.venv|venv|__pycache__)\\' } |
    Select-Object -First 2000 |
    ForEach-Object { [IO.Path]::GetFullPath($_.FullName).Substring($repoRoot.Length + 1) }
}

function Write-Utf8NoBom {
  param([string]$Path, [string]$Content)
  $bytes = $utf8.GetBytes($Content)
  $stream = New-Object IO.FileStream($Path, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
  try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush() }
  finally { $stream.Dispose() }
}

try {
  $gitInfo = Get-GitInfo
  $fileLines = @(Get-FileLines)
  $fileCount = $fileLines.Count

  # --- structure.md ------------------------------------------------------
  $sb = New-Object Text.StringBuilder
  [void]$sb.AppendLine('# Structure Index')
  [void]$sb.AppendLine('')
  [void]$sb.AppendLine('Generated by `scripts/index-repo.ps1` — snapshot, not a live view. Re-index before trusting it for navigation.')
  [void]$sb.AppendLine('')
  [void]$sb.AppendLine('## Repository')
  [void]$sb.AppendLine('')
  [void]$sb.AppendLine(('- Root: `' + $repoRoot + '`'))
  if ($null -ne $gitInfo) {
    [void]$sb.AppendLine(('- Git: ' + $gitInfo.repositoryId))
    [void]$sb.AppendLine(('- Branch: ' + [string]$gitInfo.branch + '  HEAD: ' + [string]$gitInfo.head))
    [void]$sb.AppendLine(('- Dirty: ' + $gitInfo.dirty))
  }
  else {
    [void]$sb.AppendLine('- Git: not a git worktree')
  }
  [void]$sb.AppendLine('')
  [void]$sb.AppendLine('## File list (tracked files, capped at 2000)')
  [void]$sb.AppendLine('')
  [void]$sb.AppendLine('```')
  foreach ($line in $fileLines) { [void]$sb.AppendLine($line) }
  [void]$sb.AppendLine('```')
  [void]$sb.AppendLine('')
  Write-Utf8NoBom -Path (Join-Path $indexDir 'structure.md') -Content $sb.ToString()

  # --- entrypoints.md (moderate+) ----------------------------------------
  if ($IndexMode -in @('moderate', 'full')) {
    $sb = New-Object Text.StringBuilder
    [void]$sb.AppendLine('# Entrypoints Index')
    [void]$sb.AppendLine('')
    $pkgPath = Join-Path $repoRoot 'package.json'
    if (Test-Path -LiteralPath $pkgPath -PathType Leaf) {
      try {
        $pkg = Get-Content -Raw -Encoding UTF8 -LiteralPath $pkgPath | ConvertFrom-Json
        [void]$sb.AppendLine('## package.json')
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine(('- main: `' + [string]$pkg.main + '`'))
        if ($null -ne $pkg.bin) {
          [void]$sb.AppendLine('- bin:')
          foreach ($name in @($pkg.bin.PSObject.Properties.Name)) { [void]$sb.AppendLine(('  - `' + $name + '` -> `' + [string]$pkg.bin.$name + '`')) }
        }
        if ($null -ne $pkg.scripts) {
          [void]$sb.AppendLine('- scripts:')
          foreach ($name in @($pkg.scripts.PSObject.Properties.Name)) { [void]$sb.AppendLine(('  - `' + $name + '`: ' + [string]$pkg.scripts.$name)) }
        }
        if ($null -ne $pkg.workspaces) {
          [void]$sb.AppendLine('- workspaces: ' + ($pkg.workspaces | ConvertTo-Json -Compress))
        }
      }
      catch { [void]$sb.AppendLine('- package.json present but not parseable') }
    }
    else { [void]$sb.AppendLine('## package.json — none') }
    [void]$sb.AppendLine('')
    foreach ($manifest in @('pnpm-workspace.yaml', 'lerna.json', 'Cargo.toml', 'go.mod', 'pom.xml', 'build.gradle', 'requirements.txt', 'pyproject.toml')) {
      if (Test-Path -LiteralPath (Join-Path $repoRoot $manifest) -PathType Leaf) {
        [void]$sb.AppendLine(('- ' + $manifest + ': present'))
      }
    }
    [void]$sb.AppendLine('')
    Write-Utf8NoBom -Path (Join-Path $indexDir 'entrypoints.md') -Content $sb.ToString()
  }

  # --- docs.md + glossary.md (full) --------------------------------------
  if ($IndexMode -ceq 'full') {
    $sb = New-Object Text.StringBuilder
    [void]$sb.AppendLine('# Documentation Pointers')
    [void]$sb.AppendLine('')
    $docs = @()
    foreach ($candidate in @('README.md', 'README.zh-CN.md', 'AGENTS.md', 'CLAUDE.md', 'CONTEXT.md', 'CONTEXT-MAP.md', 'CONTRIBUTING.md', 'docs', 'docs/adr', 'specs', '.scratch')) {
      if (Test-Path -LiteralPath (Join-Path $repoRoot $candidate)) { $docs += $candidate }
    }
    if ($docs.Count -eq 0) { [void]$sb.AppendLine('None of the common documentation locations exist in this repository.') }
    else {
      [void]$sb.AppendLine('Read these paths directly in the repository (do not trust stale copies):')
      [void]$sb.AppendLine('')
      foreach ($doc in $docs) { [void]$sb.AppendLine(('- `' + $doc + '`')) }
    }
    [void]$sb.AppendLine('')
    Write-Utf8NoBom -Path (Join-Path $indexDir 'docs.md') -Content $sb.ToString()

    if (-not (Test-Path -LiteralPath (Join-Path $indexDir 'glossary.md'))) {
      $glossary = @'
# Glossary (seeded)
# Terms from this repository's domain model. Maintained by the domain-modeling
# skill, never by hand. Each term: name + one-line definition + synonyms to avoid.
'@
      Write-Utf8NoBom -Path (Join-Path $indexDir 'glossary.md') -Content $glossary
    }
  }

  # --- meta.json ----------------------------------------------------------
  $meta = [pscustomobject][ordered]@{
    schemaVersion = 1
    repositoryRoot = $repoRoot
    indexMode = $IndexMode
    generatedAtUtc = ([DateTime]::UtcNow).ToString('o')
    git = if ($null -ne $gitInfo) { $gitInfo } else { [pscustomobject][ordered]@{ isGit=$false; repositoryId='none'; branch=$null; head=$null; dirty=$false; worktreeRoot=$repoRoot } }
    fileCount = $fileCount
    truncated = ($fileLines.Count -ge 2000)
    coverage = $IndexMode
  }
  $metaJson = ($meta | ConvertTo-Json -Depth 6 -Compress) + "`n"
  Write-Utf8NoBom -Path (Join-Path $indexDir 'meta.json') -Content $metaJson

  [pscustomobject][ordered]@{
    schemaVersion = 1
    status = 'index-ready'
    repositoryRoot = $repoRoot
    indexDir = $indexDir
    indexMode = $IndexMode
    fileCount = $fileCount
    truncated = ($fileLines.Count -ge 2000)
    generatedAtUtc = $meta.generatedAtUtc
  } | ConvertTo-Json -Depth 4 -Compress
  exit 0
}
catch {
  [pscustomobject][ordered]@{
    schemaVersion = 1
    status = 'index-unavailable'
    reasonCode = 'index-io-failure'
    repositoryRoot = $repoRoot
    detail = $_.Exception.Message
  } | ConvertTo-Json -Depth 4 -Compress
  exit 1
}
