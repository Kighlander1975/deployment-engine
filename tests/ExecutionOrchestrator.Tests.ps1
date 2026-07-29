[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:failures = New-Object System.Collections.Generic.List[string]
$script:runIdQueue = New-Object System.Collections.Generic.Queue[string]
$engineRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '..'))
$orchestratorPath = Join-Path -Path $engineRoot -ChildPath 'src/ps1/Invoke-ExecutionOrchestrator.ps1'
$cliPath = Join-Path -Path $engineRoot -ChildPath 'bin/deployment-engine.ps1'

. $orchestratorPath -ModuleOnly

function New-DeploymentRunId {
    if ($script:runIdQueue.Count -gt 0) { return $script:runIdQueue.Dequeue() }
    return 'run-' + [guid]::NewGuid().ToString('N')
}

function Use-TestRunId {
    param([Parameter(Mandatory = $true)][string] $RunId)
    $script:runIdQueue.Enqueue($RunId)
}

function Assert-True { param([bool] $Condition, [string] $Message) if (-not $Condition) { $script:failures.Add($Message) } }
function Assert-Equal { param($Actual, $Expected, [string] $Message) if ($Actual -ne $Expected) { $script:failures.Add("$Message Expected '$Expected', got '$Actual'.") } }

function Invoke-TestGit {
    param([Parameter(Mandatory = $true)][string] $RepositoryPath, [Parameter(Mandatory = $true)][string[]] $Arguments)
    $output = & git -C $RepositoryPath @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw (($output | ForEach-Object { [string] $_ }) -join ' ') }
    return $output
}

function New-TestRepository {
    param([Parameter(Mandatory = $true)][string] $RootPath, [Parameter(Mandatory = $true)][string] $Name)
    $repo = Join-Path -Path $RootPath -ChildPath $Name
    New-Item -ItemType Directory -Path $repo | Out-Null
    Invoke-TestGit -RepositoryPath $repo -Arguments @('init') | Out-Null
    Invoke-TestGit -RepositoryPath $repo -Arguments @('config', 'user.email', 'deployment-engine@example.invalid') | Out-Null
    Invoke-TestGit -RepositoryPath $repo -Arguments @('config', 'user.name', 'Deployment Engine Tests') | Out-Null
    Set-Content -LiteralPath (Join-Path -Path $repo -ChildPath 'index.php') -Value 'hello' -Encoding UTF8
    Invoke-TestGit -RepositoryPath $repo -Arguments @('add', 'index.php') | Out-Null
    Invoke-TestGit -RepositoryPath $repo -Arguments @('commit', '-m', 'initial') | Out-Null
    return $repo
}

function New-TestCommand {
    param(
        [string] $Id,
        [int] $Sequence,
        [string] $Actor,
        [string] $Location,
        [string] $Mode,
        [string] $Program,
        [string[]] $DependsOn = @(),
        [object] $Operation = ([pscustomobject]@{}),
        [string] $RenderedCommand = ''
    )
    return [pscustomobject]@{
        commandId = $Id
        sequence = $Sequence
        strategyStepId = $Id
        operationType = $Id
        actor = $Actor
        executionLocation = $Location
        executionMode = $Mode
        dependsOn = @($DependsOn)
        program = $Program
        arguments = if ($Program -eq 'local-operation') { @($Id) } else { @() }
        workingDirectory = ''
        environment = [pscustomobject]@{}
        operation = $Operation
        renderedCommand = $RenderedCommand
        display = [pscustomobject]@{ title = $Id; description = ''; copyable = ($Actor -eq 'human-command') }
        feedback = [pscustomobject]@{ required = ($Actor -eq 'human-command'); expectedData = if ($Actor -eq 'human-command') { @('exitStatus', 'stdout', 'stderr') } else { @() } }
        safety = [pscustomobject]@{ destructive = $false; containsSecret = $false; requiresApproval = $false; executionPermitted = $false }
        diagnostic = ''
    }
}

function New-TestPackagingPolicy {
    return [pscustomobject]@{
        policyId = 'packaging-policy-orchestrator'
        projectId = 'orchestrator'
        artifactType = 'deployment-archive'
        vendorStrategy = 'exclude-install-on-target-from-lockfiles'
        includedPaths = @('**')
        excludedPaths = @('storage/**', 'vendor/**', 'node_modules/**', 'tests/**', '.git/**', '.deployment/**', 'deployment-runs/**')
        executionPlanFingerprint = 'execution-plan-fingerprint-orchestrator'
        createdAt = '2026-07-28T12:00:00Z'
    }
}

function New-TestCommandPlan {
    param(
        [Parameter(Mandatory = $true)][string] $SourcePath,
        [string] $ArtifactPath = '',
        [bool] $IncludeArchive = $true,
        [bool] $IncludeHumanGate = $false,
        [bool] $IncludeHumanCommandAfterGate = $false,
        [string] $ArchiveSourcePath = ''
    )
    if ([string]::IsNullOrWhiteSpace($ArchiveSourcePath)) { $ArchiveSourcePath = $SourcePath }
    $commands = @()
    $commands += New-TestCommand -Id 'source.validate' -Sequence 100 -Actor 'automation' -Location 'local' -Mode 'automatic' -Program 'local-operation' -Operation ([pscustomobject]@{ sourcePath = $SourcePath })
    if ($IncludeArchive) {
        $commands += New-TestCommand -Id 'archive.create' -Sequence 300 -Actor 'automation' -Location 'local' -Mode 'automatic' -Program 'local-operation' -DependsOn @('source.validate') -Operation ([pscustomobject]@{ sourcePath = $ArchiveSourcePath; artifactPath = $ArtifactPath; executionPlanFingerprint = 'execution-plan-fingerprint-orchestrator'; packagingPolicy = New-TestPackagingPolicy })
    }
    $humanGates = @()
    if ($IncludeHumanGate) {
        $humanGates = @([pscustomobject]@{ gateId = 'deployment.approval'; stepId = 'deployment.approval'; sequence = 400; dependsOn = @('archive.create'); gateType = 'approval'; blocksContinuation = $true; allowedResponses = @('approved', 'rejected') })
    }
    if ($IncludeHumanCommandAfterGate) {
        if (-not $IncludeHumanGate) { throw 'Test setup requires IncludeHumanGate when IncludeHumanCommandAfterGate is set.' }
        $commands += New-TestCommand -Id 'artifact.upload' -Sequence 500 -Actor 'human-command' -Location 'artifact-transport' -Mode 'copy-and-run' -Program 'network-share' -DependsOn @('deployment.approval') -RenderedCommand 'Copy-Item -LiteralPath artifact.zip -Destination upload.zip'
    }

    return [pscustomobject]@{
        schemaVersion = '0.1'
        commandPlanType = 'deployment-command-plan'
        status = 'ready'
        sourceStrategyType = 'deployment'
        selectedAdapterId = 'archive.zip'
        executionPolicy = [pscustomobject]@{ executionAllowed = $false; automaticExecutionAllowed = $false; remoteExecutionMode = 'copy-and-run' }
        commands = @($commands)
        humanGates = @($humanGates)
        diagnostic = ''
    }
}

function Save-Plan {
    param([Parameter(Mandatory = $true)][object] $Plan, [Parameter(Mandatory = $true)][string] $Path)
    $Plan | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Get-Summary {
    param([Parameter(Mandatory = $true)][string] $RuntimePath)
    return Get-Content -LiteralPath (Join-Path -Path $RuntimePath -ChildPath 'reports/execution-summary.json') -Raw | ConvertFrom-Json
}

function Assert-RuntimeOnlyFiles {
    param([Parameter(Mandatory = $true)][string] $RuntimePath)
    foreach ($file in @(Get-ChildItem -LiteralPath $RuntimePath -Recurse -File)) {
        Assert-True ($file.FullName.StartsWith($RuntimePath, [System.StringComparison]::OrdinalIgnoreCase)) "Runtime file must stay within runtime directory: $($file.FullName)"
    }
}

$tmp = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('execution-orchestrator-tests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    $runtimeRoot = Join-Path -Path $tmp -ChildPath 'deployment-runs'
    New-Item -ItemType Directory -Path $runtimeRoot | Out-Null

    $successRepo = New-TestRepository -RootPath $tmp -Name 'success-repo'
    $successPlanPath = Join-Path -Path $tmp -ChildPath 'success-command-plan.json'
    Save-Plan -Plan (New-TestCommandPlan -SourcePath $successRepo) -Path $successPlanPath
    Use-TestRunId -RunId 'run-success'
    $successJson = Invoke-LocalExecutionOrchestrator -CommandPlanPath $successPlanPath -SourceRepositoryPath $successRepo -RuntimeRootPath $runtimeRoot -Format Json
    $success = $successJson | ConvertFrom-Json
    Assert-Equal $success.status 'completed' 'Successful local automation must complete.'
    Assert-Equal $success.sessionStatus 'completed' 'Successful summary must report completed session.'
    Assert-Equal $success.executedAutomationCount 2 'Successful source and archive plan must execute two automation items.'
    Assert-Equal $success.humanActionRequired $false 'Successful automation-only run must not require human action.'
    Assert-True (Test-Path -LiteralPath $success.runtimeDirectory -PathType Container) 'Successful run must create runtime directory.'
    Assert-True (Test-Path -LiteralPath (Join-Path $success.runtimeDirectory 'input/command-plan.json') -PathType Leaf) 'Input command plan copy must exist.'
    Assert-True (Test-Path -LiteralPath (Join-Path $success.runtimeDirectory 'decisions/clean-tree-assessment.json') -PathType Leaf) 'Clean-tree assessment must be stored.'
    Assert-Equal (Get-Content -LiteralPath (Join-Path $success.runtimeDirectory 'decisions/clean-tree-assessment.json') -Raw | ConvertFrom-Json).status 'clean' 'Successful run must have clean tree assessment.'
    Assert-True (Test-Path -LiteralPath (Join-Path $success.runtimeDirectory 'events/automation-started-0001.json') -PathType Leaf) 'Started event for first automation must be stored.'
    Assert-True (Test-Path -LiteralPath (Join-Path $success.runtimeDirectory 'events/automation-result-0002.json') -PathType Leaf) 'Result event for second automation must be stored.'
    Assert-True (Test-Path -LiteralPath (Join-Path $success.runtimeDirectory 'artifacts/deployment.zip') -PathType Leaf) 'Archive artifact must be created inside runtime artifacts.'
    $runtimeArtifactFiles = @(Get-ChildItem -LiteralPath (Join-Path $success.runtimeDirectory 'artifacts') -Filter 'runtime-artifact-*.json' -File)
    Assert-Equal $runtimeArtifactFiles.Count 1 'Successful archive creation must persist one runtime artifact metadata file.'
    $runtimeArtifact = Get-Content -LiteralPath $runtimeArtifactFiles[0].FullName -Raw | ConvertFrom-Json
    Assert-Equal $runtimeArtifact.artifactType 'deployment-archive' 'Runtime artifact metadata must describe deployment archive.'
    Assert-Equal $runtimeArtifact.executionPlanFingerprint 'execution-plan-fingerprint-orchestrator' 'Runtime artifact metadata must be bound to execution plan fingerprint.'
    Assert-Equal $runtimeArtifact.packagingPolicyId 'packaging-policy-orchestrator' 'Runtime artifact metadata must be bound to packaging policy.'
    Assert-Equal (Get-Summary -RuntimePath $success.runtimeDirectory).status 'completed' 'Execution summary file must report completed.'
    Assert-Equal @((Get-ChildItem -LiteralPath (Join-Path $success.runtimeDirectory 'decisions') -Filter 'command-session-*-result.json')).Count 2 'Session result snapshots must be preserved without overwrite.'
    Assert-RuntimeOnlyFiles -RuntimePath $success.runtimeDirectory
    Assert-Equal ((Invoke-TestGit -RepositoryPath $successRepo -Arguments @('status', '--porcelain=v1', '--untracked-files=all')) -join '') '' 'Source repository must remain clean after orchestration.'
    Assert-Equal @(Get-ChildItem -LiteralPath $successRepo -Filter 'command-session*.json' -Recurse -File -Force).Count 0 'No session files may be written to source repository.'

    $incompletePlan = New-TestCommandPlan -SourcePath $successRepo -IncludeHumanGate:$true
    $incompletePlan.status = 'incomplete'
    $incompleteArchiveCommand = @($incompletePlan.commands | Where-Object { $_.commandId -eq 'archive.create' } | Select-Object -First 1)[0]
    $incompleteArchiveCommand.operation.PSObject.Properties.Remove('packagingPolicy')
    $bootstrapPlan = New-OrchestratorBootstrapCommandPlan -CommandPlan $incompletePlan -PackagingPolicy (New-TestPackagingPolicy)
    $bootstrapArchiveCommand = @($bootstrapPlan.commands | Where-Object { $_.commandId -eq 'archive.create' } | Select-Object -First 1)[0]
    Assert-Equal $bootstrapPlan.status 'ready' 'Bootstrap plan must be ready even when the source command plan is incomplete.'
    Assert-Equal $bootstrapArchiveCommand.operation.packagingPolicy.policyId 'packaging-policy-orchestrator' 'Bootstrap archive command must receive the explicit packaging policy.'

    $dirtyRepo = New-TestRepository -RootPath $tmp -Name 'dirty-repo'
    Set-Content -LiteralPath (Join-Path -Path $dirtyRepo -ChildPath 'dirty.txt') -Value 'dirty' -Encoding UTF8
    $dirtyPlanPath = Join-Path -Path $tmp -ChildPath 'dirty-command-plan.json'
    Save-Plan -Plan (New-TestCommandPlan -SourcePath $dirtyRepo) -Path $dirtyPlanPath
    Use-TestRunId -RunId 'run-dirty'
    $dirty = Invoke-LocalExecutionOrchestrator -CommandPlanPath $dirtyPlanPath -SourceRepositoryPath $dirtyRepo -RuntimeRootPath $runtimeRoot -Format Json | ConvertFrom-Json
    Assert-Equal $dirty.status 'blocked' 'Dirty repository must block orchestration.'
    Assert-True (Test-Path -LiteralPath (Join-Path $dirty.runtimeDirectory 'decisions/clean-tree-assessment.json') -PathType Leaf) 'Dirty run must still store clean-tree assessment.'
    Assert-Equal @(Get-ChildItem -LiteralPath (Join-Path $dirty.runtimeDirectory 'decisions') -Filter 'command-session*.json' -File).Count 0 'Dirty run must not create a command session.'
    Assert-Equal @(Get-ChildItem -LiteralPath (Join-Path $dirty.runtimeDirectory 'decisions') -Filter 'executor-request*.json' -File).Count 0 'Dirty run must not create executor requests.'
    Assert-Equal @(Get-ChildItem -LiteralPath (Join-Path $dirty.runtimeDirectory 'artifacts') -File).Count 0 'Dirty run must not create archives.'

    $humanRepo = New-TestRepository -RootPath $tmp -Name 'human-repo'
    $humanPlanPath = Join-Path -Path $tmp -ChildPath 'human-command-plan.json'
    Save-Plan -Plan (New-TestCommandPlan -SourcePath $humanRepo -IncludeHumanGate:$true) -Path $humanPlanPath
    Use-TestRunId -RunId 'run-human'
    $human = Invoke-LocalExecutionOrchestrator -CommandPlanPath $humanPlanPath -SourceRepositoryPath $humanRepo -RuntimeRootPath $runtimeRoot -Format Json | ConvertFrom-Json
    Assert-Equal $human.status 'waiting-for-human' 'Human gate must pause orchestration.'
    Assert-Equal $human.humanActionRequired $true 'Human gate summary must require human action.'
    Assert-Equal $human.currentItemId 'deployment.approval' 'Human gate must be the current item.'
    Assert-Equal $human.executedAutomationCount 2 'Human gate run must complete local automation first.'
    $humanSession = Get-Content -LiteralPath (Join-Path $human.runtimeDirectory 'decisions/command-session-0002-result.json') -Raw | ConvertFrom-Json
    Assert-Equal (@($humanSession.items | Where-Object { $_.itemId -eq 'deployment.approval' })[0].status) 'waiting-for-human' 'Approval gate must wait for human input.'

    $handoffRepo = New-TestRepository -RootPath $tmp -Name 'human-command-handoff-repo'
    $handoffPlanPath = Join-Path -Path $tmp -ChildPath 'human-command-handoff-plan.json'
    Save-Plan -Plan (New-TestCommandPlan -SourcePath $handoffRepo -IncludeHumanGate:$true -IncludeHumanCommandAfterGate:$true) -Path $handoffPlanPath
    Use-TestRunId -RunId 'run-human-command-handoff'
    $handoff = Invoke-LocalExecutionOrchestrator -CommandPlanPath $handoffPlanPath -SourceRepositoryPath $handoffRepo -RuntimeRootPath $runtimeRoot -Format Json | ConvertFrom-Json
    Assert-Equal $handoff.currentItemId 'deployment.approval' 'Handoff run must first pause at approval.'
    $handoffApprovalPath = Join-Path -Path $tmp -ChildPath 'handoff-approval.json'
    Save-Plan -Plan ([pscustomobject]@{ schemaVersion = '0.1'; sessionId = [string] $handoff.sessionId; eventId = 'handoff-approval'; eventType = 'human-decision-submitted'; targetItemId = 'deployment.approval'; decision = [pscustomobject]@{ value = 'approved' } }) -Path $handoffApprovalPath
    $handoffApproved = Invoke-LocalExecutionResume -RuntimeDirectoryPath $handoff.runtimeDirectory -SessionEventPath $handoffApprovalPath -Format Json | ConvertFrom-Json
    Assert-Equal $handoffApproved.currentItemId 'artifact.upload' 'Approval must advance to the human command.'
    $handoffStartPath = Join-Path -Path $tmp -ChildPath 'handoff-start.json'
    Save-Plan -Plan ([pscustomobject]@{ schemaVersion = '0.1'; sessionId = [string] $handoff.sessionId; eventId = 'handoff-start'; eventType = 'human-command-started'; targetItemId = 'artifact.upload' }) -Path $handoffStartPath
    $handoffStarted = Invoke-LocalExecutionResume -RuntimeDirectoryPath $handoff.runtimeDirectory -SessionEventPath $handoffStartPath -Format Json | ConvertFrom-Json
    Assert-Equal $handoffStarted.status 'waiting-for-human' 'Started human command must keep orchestration waiting for output.'
    Assert-Equal $handoffStarted.sessionStatus 'in-progress' 'Started human command must put the session in progress.'
    $handoffStartedSessionFile = @(Get-ChildItem -LiteralPath (Join-Path $handoff.runtimeDirectory 'decisions') -Filter 'command-session-*-external.json' -File | Sort-Object Name | Select-Object -Last 1)
    Assert-True ($handoffStartedSessionFile.Count -eq 1) 'Human command start resume must persist an external session snapshot.'
    $handoffStartedSession = Get-Content -LiteralPath $handoffStartedSessionFile[0].FullName -Raw | ConvertFrom-Json
    Assert-Equal (@($handoffStartedSession.items | Where-Object { $_.itemId -eq 'artifact.upload' })[0].status) 'running' 'Human command start event must be persisted as running.'

    $failedRepo = New-TestRepository -RootPath $tmp -Name 'failed-repo'
    $failedSource = Join-Path -Path $tmp -ChildPath 'failed-source'
    New-Item -ItemType Directory -Path $failedSource | Out-Null
    Set-Content -LiteralPath (Join-Path -Path $failedSource -ChildPath 'locked.txt') -Value 'locked' -Encoding UTF8
    $failedPlanPath = Join-Path -Path $tmp -ChildPath 'failed-command-plan.json'
    Save-Plan -Plan (New-TestCommandPlan -SourcePath $failedSource) -Path $failedPlanPath
    Use-TestRunId -RunId 'run-failed'
    $lockedFile = [System.IO.File]::Open((Join-Path -Path $failedSource -ChildPath 'locked.txt'), [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    try {
        $failed = Invoke-LocalExecutionOrchestrator -CommandPlanPath $failedPlanPath -SourceRepositoryPath $failedRepo -RuntimeRootPath $runtimeRoot -Format Json | ConvertFrom-Json
    } finally {
        $lockedFile.Dispose()
    }
    Assert-Equal $failed.status 'failed' 'Executor failed result must fail orchestration.'
    $failedResultFiles = @(Get-ChildItem -LiteralPath (Join-Path $failed.runtimeDirectory 'decisions') -Filter 'executor-result-*.json' -File | Sort-Object Name)
    Assert-True ($failedResultFiles.Count -gt 0) "Failed executor run must store an executor result. Diagnostic: $($failed.diagnostic)"
    if ($failedResultFiles.Count -gt 0) {
        $failedResult = Get-Content -LiteralPath $failedResultFiles[-1].FullName -Raw | ConvertFrom-Json
        Assert-Equal $failedResult.status 'failed' 'Failed executor result must remain stored.'
    }
    Assert-True (@(Get-ChildItem -LiteralPath (Join-Path $failed.runtimeDirectory 'events') -Filter 'automation-result-*.json' -File).Count -gt 0) 'Failed executor result must still produce result event.'

    $rejectRepo = New-TestRepository -RootPath $tmp -Name 'reject-repo'
    $rejectPlanPath = Join-Path -Path $tmp -ChildPath 'reject-command-plan.json'
    Save-Plan -Plan (New-TestCommandPlan -SourcePath (Join-Path $tmp 'missing-source') -IncludeArchive:$false) -Path $rejectPlanPath
    Use-TestRunId -RunId 'run-reject'
    $rejected = Invoke-LocalExecutionOrchestrator -CommandPlanPath $rejectPlanPath -SourceRepositoryPath $rejectRepo -RuntimeRootPath $runtimeRoot -Format Json | ConvertFrom-Json
    Assert-Equal $rejected.status 'failed' 'Executor rejected result must become failed session summary.'
    $rejectedResult = Get-Content -LiteralPath (Join-Path $rejected.runtimeDirectory 'decisions/executor-result-0001.json') -Raw | ConvertFrom-Json
    Assert-Equal $rejectedResult.status 'rejected' 'Rejected executor result must remain stored.'
    $rejectedSession = Get-Content -LiteralPath (Join-Path $rejected.runtimeDirectory 'decisions/command-session-0001-result.json') -Raw | ConvertFrom-Json
    Assert-Equal $rejectedSession.status 'failed' 'Rejected result event must fail the command session.'

    $invalidRepoPlanPath = Join-Path -Path $tmp -ChildPath 'invalid-repo-command-plan.json'
    Save-Plan -Plan (New-TestCommandPlan -SourcePath $successRepo -IncludeArchive:$false) -Path $invalidRepoPlanPath
    Use-TestRunId -RunId 'run-invalid-repo'
    $invalidRepo = Invoke-LocalExecutionOrchestrator -CommandPlanPath $invalidRepoPlanPath -SourceRepositoryPath (Join-Path $tmp 'missing-repo') -RuntimeRootPath $runtimeRoot -Format Json | ConvertFrom-Json
    Assert-True ($invalidRepo.status -in @('failed', 'rejected')) 'Invalid repository path must produce controlled structured result.'
    Assert-True (Test-Path -LiteralPath (Join-Path $invalidRepo.runtimeDirectory 'reports/execution-summary.json') -PathType Leaf) 'Invalid repository run must keep runtime summary.'
    Assert-Equal @(Get-ChildItem -LiteralPath (Join-Path $invalidRepo.runtimeDirectory 'decisions') -Filter 'executor-result*.json' -File).Count 0 'Invalid repository must not run local operations.'

    $limitRepo = New-TestRepository -RootPath $tmp -Name 'limit-repo'
    $limitPlanPath = Join-Path -Path $tmp -ChildPath 'limit-command-plan.json'
    Save-Plan -Plan (New-TestCommandPlan -SourcePath $limitRepo -IncludeArchive:$false) -Path $limitPlanPath
    Use-TestRunId -RunId 'run-limit'
    $limit = Invoke-LocalExecutionOrchestrator -CommandPlanPath $limitPlanPath -SourceRepositoryPath $limitRepo -RuntimeRootPath $runtimeRoot -MaxAutomationSteps 0 -Format Json | ConvertFrom-Json
    Assert-Equal $limit.status 'failed' 'Loop protection must stop before unbounded automation.'
    Assert-True ($limit.diagnostic -match 'MaxAutomationSteps') 'Loop protection summary must explain the limit.'
    Assert-Equal @(Get-ChildItem -LiteralPath (Join-Path $limit.runtimeDirectory 'events') -File).Count 0 'Loop protection must not create automation events after limit.'

    $cliRepo = New-TestRepository -RootPath $tmp -Name 'cli-repo'
    $cliPlanPath = Join-Path -Path $tmp -ChildPath 'cli-command-plan.json'
    Save-Plan -Plan (New-TestCommandPlan -SourcePath $cliRepo -IncludeArchive:$false) -Path $cliPlanPath
    $cliRuntimeRoot = Join-Path -Path $tmp -ChildPath 'cli-runs'
    New-Item -ItemType Directory -Path $cliRuntimeRoot | Out-Null
    $cliJson = & $cliPath orchestrate-local-execution -CommandPlanPath $cliPlanPath -SourceRepositoryPath $cliRepo -RuntimeRootPath $cliRuntimeRoot -Format Json
    $cliSummary = $cliJson | ConvertFrom-Json
    Assert-Equal $cliSummary.orchestratorResultType 'deployment-execution-orchestrator-result' 'CLI must emit orchestrator result JSON.'
    Assert-Equal $cliSummary.status 'completed' 'CLI source-only orchestration must complete.'
} finally {
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
}

$sourceText = Get-Content -LiteralPath $orchestratorPath -Raw
foreach ($forbidden in @('Invoke-Expression', 'Start-Process', 'System.Diagnostics.Process', 'ProcessStartInfo', 'Invoke-Command', 'New-PSSession', 'git add', 'git commit', 'git reset', 'git clean', 'git push')) {
    Assert-True (-not ($sourceText -match [regex]::Escape($forbidden))) "Execution orchestrator source must not contain forbidden token '$forbidden'."
}

if ($script:failures.Count -gt 0) {
    Write-Host 'Execution Orchestrator tests failed:'
    $script:failures | ForEach-Object { Write-Host "- $_" }
    exit 1
}

Write-Host 'Execution Orchestrator tests passed.'
exit 0
