[CmdletBinding()]
param(
  [switch]$RequireGit,
  [switch]$RequireSsh,
  [switch]$RequireLfs,
  [switch]$RequireNode,
  [Parameter(ValueFromRemainingArguments=$true)]
  [object[]]$RemainingArgs
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

function Invoke-OnboardingPreflight {
  param(
    [bool]$RequireGit,
    [bool]$RequireSsh,
    [bool]$RequireLfs,
    [bool]$RequireNode,
    [scriptblock]$CommandResolver = {
      param($Name)
      Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue
    },
    [scriptblock]$CommandInvoker = {
      param($Path, $Arguments)
      $output = & $Path @Arguments 2>&1
      [pscustomobject]@{ ExitCode=$LASTEXITCODE; Output=(($output | ForEach-Object { [string]$_ }) -join "`n").Trim() }
    }
  )

  $tools = [ordered]@{}
  $missingRequired = @()
  $warnings = @()
  $powerShellReady = $PSVersionTable.PSVersion -ge [Version]'5.1'
  $tools.powershell = [ordered]@{
    available = $powerShellReady
    required = $true
    version = $PSVersionTable.PSVersion.ToString()
  }
  if (-not $powerShellReady) { $missingRequired += 'powershell>=5.1' }

  $checks = @(
    [pscustomobject]@{ Key='git'; Command='git'; Required=$RequireGit },
    [pscustomobject]@{ Key='ssh'; Command='ssh'; Required=$RequireSsh },
    [pscustomobject]@{ Key='gitLfs'; Command='git-lfs'; Required=$RequireLfs },
    [pscustomobject]@{ Key='node'; Command='node'; Required=$RequireNode }
  )
  foreach ($check in $checks) {
    $command = $null
    try { $command = @(& $CommandResolver $check.Command | Select-Object -First 1)[0] }
    catch { $warnings += "Unable to resolve $($check.Command)" }
    $path = $null
    if ($null -ne $command) {
      foreach ($property in @('Path','Source','Definition')) {
        if ($command.PSObject.Properties.Name -contains $property -and
          -not [string]::IsNullOrWhiteSpace([string]$command.$property)) {
          $path = [string]$command.$property
          break
        }
      }
    }
    $available = -not [string]::IsNullOrWhiteSpace($path)
    $tools[$check.Key] = [ordered]@{
      available = $available
      required = [bool]$check.Required
      path = $path
    }
    if ($check.Required -and -not $available) { $missingRequired += $check.Command }
  }

  $tools.node.minimumVersion = '18.0.0'
  $tools.node.version = $null
  $tools.node.compatible = $null
  if ($RequireNode -and $tools.node.available) {
    $tools.node.compatible = $false
    try {
      $nodeResult = & $CommandInvoker $tools.node.path ([string[]]@('--version'))
      $nodeText = [string]$nodeResult.Output
      if ($nodeResult.ExitCode -eq 0 -and $nodeText -match '^v(?<version>[0-9]+\.[0-9]+\.[0-9]+)(?:[-+].*)?$') {
        $tools.node.version = $Matches.version
        $tools.node.compatible = [Version]$Matches.version -ge [Version]'18.0.0'
      }
    }
    catch { $warnings += 'Unable to execute Node.js version probe' }
    if (-not $tools.node.compatible) { $missingRequired += 'node>=18.0.0' }
  }

  [pscustomobject][ordered]@{
    schemaVersion = 1
    status = if ($missingRequired.Count -eq 0) { 'ready' } else { 'blocked' }
    tools = [pscustomobject]$tools
    missingRequired = @($missingRequired)
    warnings = @($warnings)
  }
}

if ($null -ne $RemainingArgs -and $RemainingArgs.Length -gt 0) {
  [pscustomobject][ordered]@{ schemaVersion=1; status='invalid'; tools=$null; missingRequired=@(); warnings=@('Invalid invocation') } |
    ConvertTo-Json -Depth 6 -Compress
  exit 2
}

$result = Invoke-OnboardingPreflight `
  -RequireGit ([bool]$RequireGit) `
  -RequireSsh ([bool]$RequireSsh) `
  -RequireLfs ([bool]$RequireLfs) `
  -RequireNode ([bool]$RequireNode)

if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT -and
    $RequireGit -and $result.tools.git.available) {
  $longPaths = & $result.tools.git.path config --global --get core.longpaths 2>$null
  if ($LASTEXITCODE -ne 0 -or [string]$longPaths -ine 'true') {
    $result.warnings = @($result.warnings) + 'git core.longpaths is not enabled globally'
  }
}

$result | ConvertTo-Json -Depth 6 -Compress
if ($result.status -ceq 'ready') { exit 0 } else { exit 1 }
