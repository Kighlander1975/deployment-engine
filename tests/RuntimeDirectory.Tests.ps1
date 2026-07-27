[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:failures = New-Object System.Collections.Generic.List[string]
$engineRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '..'))
$runtimePath = Join-Path -Path $engineRoot -ChildPath 'src/ps1/New-RuntimeDirectory.ps1'
$cliPath = Join-Path -Path $engineRoot -ChildPath 'bin/deployment-engine.ps1'

. $runtimePath -ModuleOnly

function Assert-True { param([bool] $Condition, [string] $Message) if (-not $Condition) { $script:failures.Add($Message) } }
function Assert-Equal { param($Actual, $Expected, [string] $Message) if ($Actual -ne $Expected) { $script:failures.Add("$Message Expected '$Expected', got '$Actual'.") } }
function Assert-ThrowsLike {
    param([scriptblock] $Script, [string] $Pattern, [string] $Message)
    try { & $Script; $script:failures.Add($Message) } catch { Assert-True ($_.Exception.Message -match $Pattern) "$Message Actual error: $($_.Exception.Message)" }
}

$tmp = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('runtime-directory-tests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    $runtimeRoot = Join-Path -Path $tmp -ChildPath 'deployment-runs'
    New-Item -ItemType Directory -Path $runtimeRoot | Out-Null

    $runtime = New-DeploymentRuntimeDirectory -RuntimeRootPath $runtimeRoot
    Assert-Equal $runtime.schemaVersion '0.1' 'Runtime schema version must be stable.'
    Assert-Equal $runtime.runtimeType 'deployment-runtime-directory' 'Runtime type must be explicit.'
    Assert-True (-not [string]::IsNullOrWhiteSpace($runtime.runId)) 'Runtime metadata must contain runId.'
    Assert-True (Test-Path -LiteralPath $runtime.runtimeDirectory -PathType Container) 'Runtime directory must be created.'
    Assert-True ($runtime.runtimeDirectory.StartsWith($runtimeRoot, [System.StringComparison]::OrdinalIgnoreCase)) 'Runtime directory must be below runtime root.'

    foreach ($property in @('artifactsDirectory', 'decisionsDirectory', 'eventsDirectory', 'inputDirectory', 'inventoryDirectory', 'logsDirectory', 'reportsDirectory')) {
        Assert-True (Test-Path -LiteralPath $runtime.$property -PathType Container) "Runtime subdirectory '$property' must exist."
        Assert-True ([string] $runtime.$property -like ([string] $runtime.runtimeDirectory + '*')) "Runtime subdirectory '$property' must be below run directory."
    }

    $second = New-DeploymentRuntimeDirectory -RuntimeRootPath $runtimeRoot
    Assert-True ($second.runId -ne $runtime.runId) 'Multiple runtime calls must create different runIds.'
    Assert-True ($second.runtimeDirectory -ne $runtime.runtimeDirectory) 'Multiple runtime calls must create different directories.'
    Assert-True (Test-Path -LiteralPath $second.runtimeDirectory -PathType Container) 'Second runtime directory must exist.'

    Assert-ThrowsLike -Script { New-DeploymentRuntimeDirectory -RuntimeRootPath (Join-Path $tmp 'missing') | Out-Null } -Pattern 'runtime root does not exist' -Message 'Missing runtime root must be rejected.'

    $outputPath = Join-Path -Path $tmp -ChildPath 'runtime-output/runtime.json'
    & $cliPath create-runtime-directory -RuntimeRootPath $runtimeRoot -OutputPath $outputPath -Format Json | Out-Null
    Assert-True (Test-Path -LiteralPath $outputPath -PathType Leaf) 'Runtime CLI must write explicit output file.'
    $output = Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json
    Assert-Equal $output.runtimeType 'deployment-runtime-directory' 'Runtime CLI output must be parseable JSON.'

    $fileCountBeforeStdout = @(Get-ChildItem -LiteralPath $tmp -File -Recurse).Count
    $stdoutJson = & $cliPath create-runtime-directory -RuntimeRootPath $runtimeRoot -Format Json
    $fileCountAfterStdout = @(Get-ChildItem -LiteralPath $tmp -File -Recurse).Count
    Assert-Equal ($stdoutJson | ConvertFrom-Json).runtimeType 'deployment-runtime-directory' 'Runtime CLI without OutputPath must emit parseable JSON.'
    Assert-Equal @($stdoutJson).Count 1 'Runtime CLI without OutputPath must not emit extra stdout.'
    Assert-Equal ($fileCountAfterStdout - $fileCountBeforeStdout) 0 'Runtime CLI without OutputPath must not create metadata files.'
} finally {
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
}

if ($script:failures.Count -gt 0) {
    Write-Host 'Runtime Directory tests failed:'
    $script:failures | ForEach-Object { Write-Host "- $_" }
    exit 1
}

Write-Host 'Runtime Directory tests passed.'
exit 0
