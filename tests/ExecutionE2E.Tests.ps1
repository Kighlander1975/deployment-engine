[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:failures = New-Object System.Collections.Generic.List[string]
$engineRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '..'))
$cliPath = Join-Path -Path $engineRoot -ChildPath 'bin/deployment-engine.ps1'
$fixtureSourcePath = Join-Path -Path $engineRoot -ChildPath 'examples/e2e/source'

function Assert-True { param([bool] $Condition, [string] $Message) if (-not $Condition) { $script:failures.Add($Message) } }
function Assert-Equal { param($Actual, $Expected, [string] $Message) if ($Actual -ne $Expected) { $script:failures.Add("$Message Expected '$Expected', got '$Actual'.") } }

function Invoke-TestGit {
    param([Parameter(Mandatory = $true)][string] $RepositoryPath, [Parameter(Mandatory = $true)][string[]] $Arguments)
    $output = & git -C $RepositoryPath @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw (($output | ForEach-Object { [string] $_ }) -join ' ') }
    return $output
}

function New-E2ECommand {
    param(
        [string] $Id,
        [int] $Sequence,
        [string] $OperationType,
        [string[]] $DependsOn = @(),
        [object] $Operation
    )
    return [pscustomobject]@{
        commandId = $Id
        sequence = $Sequence
        strategyStepId = $Id
        operationType = $OperationType
        actor = 'automation'
        executionLocation = 'local'
        executionMode = 'automatic'
        dependsOn = @($DependsOn)
        program = 'local-operation'
        arguments = @($OperationType)
        workingDirectory = ''
        environment = [pscustomobject]@{}
        operation = $Operation
        renderedCommand = ''
        display = [pscustomobject]@{ title = $Id; description = ''; copyable = $false }
        feedback = [pscustomobject]@{ required = $false; expectedData = @() }
        safety = [pscustomobject]@{ destructive = $false; containsSecret = $false; requiresApproval = $false; executionPermitted = $false }
        diagnostic = ''
    }
}

function New-E2ECommandPlan {
    param([Parameter(Mandatory = $true)][string] $SourcePath)
    return [pscustomobject]@{
        schemaVersion = '0.1'
        commandPlanType = 'deployment-command-plan'
        status = 'ready'
        sourceStrategyType = 'deployment'
        selectedAdapterId = 'archive.zip'
        executionPolicy = [pscustomobject]@{ executionAllowed = $false; automaticExecutionAllowed = $false; remoteExecutionMode = 'copy-and-run' }
        commands = @(
            New-E2ECommand -Id 'source.validate' -Sequence 100 -OperationType 'source.validate' -Operation ([pscustomobject]@{ sourcePath = $SourcePath })
            New-E2ECommand -Id 'archive.create' -Sequence 200 -OperationType 'archive.create' -DependsOn @('source.validate') -Operation ([pscustomobject]@{ sourcePath = $SourcePath; artifactPath = '' })
            New-E2ECommand -Id 'post.approval.source.validate' -Sequence 400 -OperationType 'source.validate' -DependsOn @('deployment.approval') -Operation ([pscustomobject]@{ sourcePath = $SourcePath })
        )
        humanGates = @(
            [pscustomobject]@{
                gateId = 'deployment.approval'
                stepId = 'deployment.approval'
                sequence = 300
                dependsOn = @('archive.create')
                gateType = 'approval'
                blocksContinuation = $true
                allowedResponses = @('approved', 'rejected')
            }
        )
        diagnostic = ''
    }
}

function Save-Json {
    param([Parameter(Mandatory = $true)][object] $Value, [Parameter(Mandatory = $true)][string] $Path)
    $Value | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Read-Json {
    param([Parameter(Mandatory = $true)][string] $Path)
    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

$tmp = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('deployment-engine-e2e-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    $sourceRepo = Join-Path -Path $tmp -ChildPath 'source-repo'
    New-Item -ItemType Directory -Path $sourceRepo | Out-Null
    Copy-Item -LiteralPath (Join-Path -Path $fixtureSourcePath -ChildPath 'hello.txt') -Destination (Join-Path -Path $sourceRepo -ChildPath 'hello.txt')
    Invoke-TestGit -RepositoryPath $sourceRepo -Arguments @('init') | Out-Null
    Invoke-TestGit -RepositoryPath $sourceRepo -Arguments @('config', 'user.email', 'deployment-engine@example.invalid') | Out-Null
    Invoke-TestGit -RepositoryPath $sourceRepo -Arguments @('config', 'user.name', 'Deployment Engine E2E Tests') | Out-Null
    Invoke-TestGit -RepositoryPath $sourceRepo -Arguments @('add', 'hello.txt') | Out-Null
    Invoke-TestGit -RepositoryPath $sourceRepo -Arguments @('commit', '-m', 'initial e2e fixture') | Out-Null

    $runtimeRoot = Join-Path -Path $tmp -ChildPath 'deployment-runs'
    New-Item -ItemType Directory -Path $runtimeRoot | Out-Null
    $planPath = Join-Path -Path $tmp -ChildPath 'command-plan.json'
    Save-Json -Value (New-E2ECommandPlan -SourcePath $sourceRepo) -Path $planPath

    $startJson = & $cliPath orchestrate-local-execution -CommandPlanPath $planPath -SourceRepositoryPath $sourceRepo -RuntimeRootPath $runtimeRoot -Format Json
    if ($LASTEXITCODE -ne 0) { throw 'orchestrate-local-execution CLI failed.' }
    $start = $startJson | ConvertFrom-Json
    Assert-Equal $start.status 'waiting-for-human' 'Initial E2E run must pause for human approval.'
    Assert-Equal $start.currentItemId 'deployment.approval' 'Initial E2E run must pause at deployment.approval.'
    Assert-True (Test-Path -LiteralPath $start.runtimeDirectory -PathType Container) 'Runtime directory must be created.'
    Assert-True ($start.runtimeDirectory.StartsWith($runtimeRoot, [System.StringComparison]::OrdinalIgnoreCase)) 'Runtime directory must be below test runtime root.'
    Assert-True (Test-Path -LiteralPath (Join-Path $start.runtimeDirectory 'artifacts/deployment.zip') -PathType Leaf) 'Archive must exist after initial automation.'
    Assert-Equal @(Get-ChildItem -LiteralPath (Join-Path $start.runtimeDirectory 'events') -Filter 'external-session-event-*.json' -File).Count 0 'Initial run must not archive external events.'

    $runtimeFilesBeforeResume = @(Get-ChildItem -LiteralPath $start.runtimeDirectory -Recurse -File | ForEach-Object { $_.FullName.Substring($start.runtimeDirectory.Length) } | Sort-Object)
    $sessionBeforeResume = @(Get-ChildItem -LiteralPath (Join-Path $start.runtimeDirectory 'decisions') -Filter 'command-session-*.json' -File | Sort-Object Name | Select-Object -Last 1)
    Assert-True ($sessionBeforeResume.Count -eq 1) 'Latest session snapshot before resume must be discoverable through stored artifacts.'
    $session = Read-Json -Path $sessionBeforeResume[0].FullName

    $eventPath = Join-Path -Path $tmp -ChildPath 'human-approval-event.json'
    Save-Json -Value ([pscustomobject]@{
        schemaVersion = '0.1'
        sessionId = [string] $session.sessionId
        eventId = 'e2e-human-approval-approved'
        eventType = 'human-decision-submitted'
        targetItemId = 'deployment.approval'
        decision = [pscustomobject]@{ value = 'approved' }
    }) -Path $eventPath

    $resumeJson = & $cliPath resume-local-execution -RuntimeDirectoryPath $start.runtimeDirectory -SessionEventPath $eventPath -Format Json
    if ($LASTEXITCODE -ne 0) { throw 'resume-local-execution CLI failed.' }
    $resume = $resumeJson | ConvertFrom-Json
    Assert-Equal $resume.status 'completed' 'E2E resume must finish completed.'
    Assert-Equal $resume.sessionStatus 'completed' 'E2E resumed command session must complete.'
    Assert-Equal $resume.resumed $true 'E2E result must record that resume was used.'
    Assert-Equal $resume.appliedExternalEventId 'e2e-human-approval-approved' 'E2E result must expose the applied external event id.'

    $summary = Read-Json -Path (Join-Path $start.runtimeDirectory 'reports/execution-summary.json')
    Assert-Equal $summary.status 'completed' 'Runtime execution summary must be completed.'
    Assert-Equal $summary.resumed $true 'Runtime execution summary must record resume.'
    $completedSessions = @(Get-ChildItem -LiteralPath (Join-Path $start.runtimeDirectory 'decisions') -Filter 'command-session-*.json' -File | ForEach-Object { Read-Json -Path $_.FullName } | Where-Object { $_.status -eq 'completed' })
    Assert-True ($completedSessions.Count -gt 0) 'A completed command session snapshot must be stored after resume.'
    Assert-True (Test-Path -LiteralPath (Join-Path $start.runtimeDirectory 'events/external-session-event-0001.json') -PathType Leaf) 'External human event must be archived.'
    $postApprovalRequests = @(Get-ChildItem -LiteralPath (Join-Path $start.runtimeDirectory 'decisions') -Filter 'executor-request-*.json' -File | ForEach-Object { Read-Json -Path $_.FullName } | Where-Object { $_.itemId -eq 'post.approval.source.validate' })
    Assert-True ($postApprovalRequests.Count -eq 1) 'Post-approval local step must run exactly once after resume.'

    $runtimeFilesAfterResume = @(Get-ChildItem -LiteralPath $start.runtimeDirectory -Recurse -File | ForEach-Object { $_.FullName.Substring($start.runtimeDirectory.Length) } | Sort-Object)
    foreach ($file in $runtimeFilesBeforeResume) {
        Assert-True ($file -in $runtimeFilesAfterResume) "Resume must preserve existing runtime artifact '$file'."
    }
    Assert-Equal @(Get-ChildItem -LiteralPath (Join-Path $start.runtimeDirectory 'artifacts') -Filter 'deployment.zip' -File).Count 1 'Archive artifact must not be overwritten or duplicated.'
    Assert-Equal ((Invoke-TestGit -RepositoryPath $sourceRepo -Arguments @('status', '--porcelain=v1', '--untracked-files=all')) -join '') '' 'Source repository must remain clean after E2E run.'

    $outsideRuntimeUnexpected = @(Get-ChildItem -LiteralPath $tmp -File | Where-Object { $_.Name -notin @('command-plan.json', 'human-approval-event.json') })
    Assert-Equal $outsideRuntimeUnexpected.Count 0 'Engine must not create temporary files in the E2E temp root outside runtime.'
} finally {
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
}

if ($script:failures.Count -gt 0) {
    Write-Host 'Execution E2E tests failed:'
    $script:failures | ForEach-Object { Write-Host "- $_" }
    exit 1
}

Write-Host 'Execution E2E tests passed.'
exit 0
