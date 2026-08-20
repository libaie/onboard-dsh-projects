[CmdletBinding()]
param(
  [ValidateSet('Get', 'Set')]
  [string]$Action = 'Get',
  [ValidateSet('fast', 'moderate', 'full')]
  [string]$IndexMode,
  [string]$ConfigRoot
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

# DSH adaptation: the preference file lives under the DSH workspace state root
# (passed explicitly as -ConfigRoot). There is no global agent home to default
# to, so a missing ConfigRoot is an invocation error rather than a silent
# write to the wrong place.
if ([string]::IsNullOrWhiteSpace($ConfigRoot) -or -not [IO.Path]::IsPathRooted($ConfigRoot)) {
  throw 'ConfigRoot must be an absolute directory path'
}
$stateRoot = [IO.Path]::GetFullPath($ConfigRoot)
$configDirectory = Join-Path $stateRoot 'skill-state'
$configPath = Join-Path $configDirectory 'dsh-flotilla.json'

$choices = @('fast', 'moderate', 'full')

function Write-Result {
  param(
    [string]$Status,
    [AllowNull()]
    [object]$Mode,
    [AllowNull()]
    [object]$Reason
  )

  [pscustomobject][ordered]@{
    schemaVersion = 1
    status = $Status
    indexMode = $Mode
    choices = $choices
    recommended = 'full'
    configPath = $configPath
    reason = $Reason
  } | ConvertTo-Json -Depth 3 -Compress
}

function Read-Preference {
  if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
    return $null
  }

  try {
    $preference = Get-Content -Raw -Encoding UTF8 -LiteralPath $configPath | ConvertFrom-Json
    if ($null -eq $preference -or
        -not ($preference.PSObject.Properties.Name -contains 'schemaVersion') -or
        [int]$preference.schemaVersion -ne 1 -or
        -not ($preference.PSObject.Properties.Name -contains 'indexMode') -or
        $choices -cnotcontains [string]$preference.indexMode) {
      throw 'Invalid preference'
    }
    return $preference
  }
  catch {
    return $false
  }
}

if ($Action -ceq 'Get') {
  $preference = Read-Preference
  if ($null -eq $preference) {
    Write-Result -Status 'needs-selection' -Mode $null -Reason $null
    exit 0
  }
  if ($preference -is [bool] -and -not $preference) {
    Write-Result -Status 'invalid' -Mode $null -Reason 'preference-file-invalid'
    exit 2
  }
  Write-Result -Status 'ready' -Mode ([string]$preference.indexMode) -Reason $null
  exit 0
}

if ([string]::IsNullOrWhiteSpace($IndexMode)) {
  throw 'IndexMode is required for Action Set'
}

New-Item -ItemType Directory -Path $configDirectory -Force | Out-Null
$temporaryPath = Join-Path $configDirectory ('dsh-flotilla.' + [guid]::NewGuid().ToString('N') + '.tmp')
try {
  $json = [pscustomobject][ordered]@{
    schemaVersion = 1
    indexMode = $IndexMode
  } | ConvertTo-Json -Compress
  [IO.File]::WriteAllText($temporaryPath, $json + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
  Move-Item -LiteralPath $temporaryPath -Destination $configPath -Force
}
finally {
  if (Test-Path -LiteralPath $temporaryPath) {
    Remove-Item -LiteralPath $temporaryPath -Force
  }
}

Write-Result -Status 'ready' -Mode $IndexMode -Reason $null
