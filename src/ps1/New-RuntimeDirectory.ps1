[CmdletBinding()]
param(
    [string] $RuntimeRootPath,
    [string] $OutputPath,
    [string] $Format = 'Json',
    [switch] $ModuleOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-RuntimeDirectoryPath {
    param([Parameter(Mandatory = $true)][string] $Path)
    $executionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function New-DeploymentRunId {
    return 'run-' + [guid]::NewGuid().ToString('N')
}

function New-DeploymentRuntimeDirectory {
    param([Parameter(Mandatory = $true)][string] $RuntimeRootPath)

    if ([string]::IsNullOrWhiteSpace($RuntimeRootPath)) {
        throw 'Runtime directory validation failed: RuntimeRootPath is required.'
    }
    $root = Resolve-RuntimeDirectoryPath -Path $RuntimeRootPath
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        throw "Runtime directory validation failed: runtime root does not exist: $root"
    }

    $subdirectories = @('artifacts', 'decisions', 'events', 'input', 'inventory', 'logs', 'reports')
    for ($attempt = 0; $attempt -lt 10; $attempt++) {
        $runId = New-DeploymentRunId
        $runtimeDirectory = Join-Path -Path $root -ChildPath $runId
        if (-not (Test-Path -LiteralPath $runtimeDirectory)) {
            New-Item -ItemType Directory -Path $runtimeDirectory | Out-Null
            foreach ($name in $subdirectories) {
                New-Item -ItemType Directory -Path (Join-Path -Path $runtimeDirectory -ChildPath $name) | Out-Null
            }

            return [pscustomobject]@{
                schemaVersion = '0.1'
                runtimeType = 'deployment-runtime-directory'
                runId = $runId
                runtimeRootDirectory = $root
                runtimeDirectory = $runtimeDirectory
                artifactsDirectory = Join-Path -Path $runtimeDirectory -ChildPath 'artifacts'
                decisionsDirectory = Join-Path -Path $runtimeDirectory -ChildPath 'decisions'
                eventsDirectory = Join-Path -Path $runtimeDirectory -ChildPath 'events'
                inputDirectory = Join-Path -Path $runtimeDirectory -ChildPath 'input'
                inventoryDirectory = Join-Path -Path $runtimeDirectory -ChildPath 'inventory'
                logsDirectory = Join-Path -Path $runtimeDirectory -ChildPath 'logs'
                reportsDirectory = Join-Path -Path $runtimeDirectory -ChildPath 'reports'
            }
        }
    }

    throw 'Runtime directory validation failed: unable to allocate a unique run directory.'
}

function Write-RuntimeDirectoryJson {
    param([Parameter(Mandatory = $true)][object] $Runtime, [string] $OutputPath)
    $json = $Runtime | ConvertTo-Json -Depth 20
    if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
        $resolvedOutputPath = Resolve-RuntimeDirectoryPath -Path $OutputPath
        $outputDirectory = Split-Path -Path $resolvedOutputPath -Parent
        if (-not [string]::IsNullOrWhiteSpace($outputDirectory)) { New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null }
        $json | Set-Content -LiteralPath $resolvedOutputPath -Encoding utf8
    }
    return $json
}

function Invoke-RuntimeDirectoryCreation {
    param([Parameter(Mandatory = $true)][string] $RuntimeRootPath, [string] $OutputPath, [string] $Format = 'Json')
    if ($Format -ne 'Json') { throw "create-runtime-directory only supports -Format Json." }
    $runtime = New-DeploymentRuntimeDirectory -RuntimeRootPath $RuntimeRootPath
    return Write-RuntimeDirectoryJson -Runtime $runtime -OutputPath $OutputPath
}

if (-not $ModuleOnly) {
    if ([string]::IsNullOrWhiteSpace($RuntimeRootPath)) { throw "Missing required parameter for 'create-runtime-directory': -RuntimeRootPath" }
    Invoke-RuntimeDirectoryCreation -RuntimeRootPath $RuntimeRootPath -OutputPath $OutputPath -Format $Format
}
