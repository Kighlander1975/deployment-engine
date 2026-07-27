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

function New-TestCommandPlan {
    param(
        [Parameter(Mandatory = $true)][string] $SourcePath,
        [bool] $IncludeHumanGate = $false,
        [bool] $IncludeReview = $false
    )
    $commands = @()
    $commands += New-TestCommand -Id 'source.validate' -Sequence 100 -Actor 'automation' -Location 'local' -Mode 'automatic' -Program 'local-operation' -Operation ([pscustomobject]@{ sourcePath = $SourcePath })
    $lastDependency = 'source.validate'
    $humanGates = @()
    if ($IncludeHumanGate) {
        $humanGates = @([pscustomobject]@{ gateId = 'deployment.approval'; stepId = 'deployment.approval'; sequence = 200; dependsOn = @($lastDependency); gateType = 'approval'; blocksContinuation = $true; allowedResponses = @('approved', 'rejected') })
        $lastDependency = 'deployment.approval'
    }
    if ($IncludeReview) {
        $commands += New-TestCommand -Id 'deployment.review' -Sequence 300 -Actor 'review' -Location 'review' -Mode 'none' -Program 'local-operation' -DependsOn @($lastDependency)
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

function Save-Json {
    param([Parameter(Mandatory = $true)][object] $Value, [Parameter(Mandatory = $true)][string] $Path)
    $Value | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Get-Summary {
    param([Parameter(Mandatory = $true)][string] $RuntimePath)
    return Get-Content -LiteralPath (Join-Path -Path $RuntimePath -ChildPath 'reports/execution-summary.json') -Raw | ConvertFrom-Json
}

function Get-LatestSession {
    param([Parameter(Mandatory = $true)][string] $RuntimePath)
    $runtime = New-OrchestratorRuntimeFromDirectory -RuntimeDirectoryPath $RuntimePath
    return Get-OrchestratorLatestSessionSnapshot -Runtime $runtime
}

function New-HumanDecisionEvent {
    param([string] $SessionId, [string] $EventId = 'external-approval-approved', [string] $TargetItemId = 'deployment.approval')
    return [pscustomobject]@{
        schemaVersion = '0.1'
        sessionId = $SessionId
        eventId = $EventId
        eventType = 'human-decision-submitted'
        targetItemId = $TargetItemId
        decision = [pscustomobject]@{ value = 'approved' }
    }
}

function New-ReviewEvent {
    param([string] $SessionId, [string] $EventId = 'external-review-approved')
    return [pscustomobject]@{
        schemaVersion = '0.1'
        sessionId = $SessionId
        eventId = $EventId
        eventType = 'review-result'
        targetItemId = 'deployment.review'
        review = [pscustomobject]@{ status = 'approved' }
    }
}

function Start-WaitingRun {
    param(
        [Parameter(Mandatory = $true)][string] $Tmp,
        [Parameter(Mandatory = $true)][string] $RuntimeRoot,
        [Parameter(Mandatory = $true)][string] $RunId,
        [bool] $Review = $false
    )
    $repo = New-TestRepository -RootPath $Tmp -Name ($RunId + '-repo')
    $planPath = Join-Path -Path $Tmp -ChildPath ($RunId + '-command-plan.json')
    Save-Json -Value (New-TestCommandPlan -SourcePath $repo -IncludeHumanGate:(-not $Review) -IncludeReview:$Review) -Path $planPath
    Use-TestRunId -RunId $RunId
    $summary = Invoke-LocalExecutionOrchestrator -CommandPlanPath $planPath -SourceRepositoryPath $repo -RuntimeRootPath $RuntimeRoot -Format Json | ConvertFrom-Json
    Assert-Equal $summary.status 'waiting-for-human' "Run '$RunId' must pause for external input."
    return $summary
}

$tmp = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('execution-resume-tests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    $runtimeRoot = Join-Path -Path $tmp -ChildPath 'deployment-runs'
    New-Item -ItemType Directory -Path $runtimeRoot | Out-Null

    $human = Start-WaitingRun -Tmp $tmp -RuntimeRoot $runtimeRoot -RunId 'run-resume-human'
    $humanSession = Get-LatestSession -RuntimePath $human.runtimeDirectory
    $humanEventPath = Join-Path -Path $tmp -ChildPath 'human-event.json'
    Save-Json -Value (New-HumanDecisionEvent -SessionId ([string] $humanSession.sessionId)) -Path $humanEventPath
    $beforeSnapshots = @(Get-ChildItem -LiteralPath (Join-Path $human.runtimeDirectory 'decisions') -Filter 'command-session-*.json' -File).Count
    $resumed = Invoke-LocalExecutionResume -RuntimeDirectoryPath $human.runtimeDirectory -SessionEventPath $humanEventPath -Format Json | ConvertFrom-Json
    Assert-Equal $resumed.status 'completed' 'Human decision resume must complete when no further item remains.'
    Assert-Equal $resumed.resumed $true 'Resume summary must be marked as resumed.'
    Assert-Equal $resumed.appliedExternalEventId 'external-approval-approved' 'Resume summary must expose applied external event id.'
    Assert-True (Test-Path -LiteralPath (Join-Path $human.runtimeDirectory 'events/external-session-event-0001.json') -PathType Leaf) 'External event must be archived inside runtime events.'
    Assert-True (@(Get-ChildItem -LiteralPath (Join-Path $human.runtimeDirectory 'decisions') -Filter 'command-session-*.json' -File).Count -gt $beforeSnapshots) 'Resume must append a new session snapshot.'
    Assert-Equal (Get-Summary -RuntimePath $human.runtimeDirectory).resumed $true 'Execution summary file must be updated after resume.'

    $review = Start-WaitingRun -Tmp $tmp -RuntimeRoot $runtimeRoot -RunId 'run-resume-review' -Review:$true
    $reviewSession = Get-LatestSession -RuntimePath $review.runtimeDirectory
    Assert-Equal $review.currentItemId 'deployment.review' 'Review run must pause at review item.'
    $reviewEventPath = Join-Path -Path $tmp -ChildPath 'review-event.json'
    Save-Json -Value (New-ReviewEvent -SessionId ([string] $reviewSession.sessionId)) -Path $reviewEventPath
    $reviewResumed = Invoke-LocalExecutionResume -RuntimeDirectoryPath $review.runtimeDirectory -SessionEventPath $reviewEventPath -Format Json | ConvertFrom-Json
    Assert-Equal $reviewResumed.status 'completed' 'Review resume must complete after an explicit approved review event.'
    Assert-Equal $reviewResumed.appliedExternalEventId 'external-review-approved' 'Review resume must report the explicit review event.'

    $wrong = Start-WaitingRun -Tmp $tmp -RuntimeRoot $runtimeRoot -RunId 'run-wrong-session'
    $wrongSessionBefore = (Get-LatestSession -RuntimePath $wrong.runtimeDirectory | ConvertTo-Json -Depth 100 -Compress)
    $wrongEventPath = Join-Path -Path $tmp -ChildPath 'wrong-session-event.json'
    Save-Json -Value (New-HumanDecisionEvent -SessionId 'session-other') -Path $wrongEventPath
    $wrongResult = Invoke-LocalExecutionResume -RuntimeDirectoryPath $wrong.runtimeDirectory -SessionEventPath $wrongEventPath -Format Json | ConvertFrom-Json
    Assert-Equal $wrongResult.status 'rejected' 'Resume must reject an event from another session.'
    Assert-True ($wrongResult.diagnostic -match 'sessionId') 'Wrong-session rejection must explain sessionId mismatch.'
    Assert-Equal (Get-LatestSession -RuntimePath $wrong.runtimeDirectory | ConvertTo-Json -Depth 100 -Compress) $wrongSessionBefore 'Wrong-session rejection must leave session snapshots unchanged.'

    $duplicate = Start-WaitingRun -Tmp $tmp -RuntimeRoot $runtimeRoot -RunId 'run-duplicate-event'
    $existingEvent = Get-Content -LiteralPath (Join-Path $duplicate.runtimeDirectory 'events/automation-started-0001.json') -Raw | ConvertFrom-Json
    $duplicateEventPath = Join-Path -Path $tmp -ChildPath 'duplicate-event.json'
    $duplicateSession = Get-LatestSession -RuntimePath $duplicate.runtimeDirectory
    Save-Json -Value (New-HumanDecisionEvent -SessionId ([string] $duplicateSession.sessionId) -EventId ([string] $existingEvent.eventId)) -Path $duplicateEventPath
    $requestCountBefore = @(Get-ChildItem -LiteralPath (Join-Path $duplicate.runtimeDirectory 'decisions') -Filter 'executor-request-*.json' -File).Count
    $duplicateResult = Invoke-LocalExecutionResume -RuntimeDirectoryPath $duplicate.runtimeDirectory -SessionEventPath $duplicateEventPath -Format Json | ConvertFrom-Json
    Assert-Equal $duplicateResult.status 'rejected' 'Resume must reject an already applied eventId.'
    Assert-Equal @(Get-ChildItem -LiteralPath (Join-Path $duplicate.runtimeDirectory 'decisions') -Filter 'executor-request-*.json' -File).Count $requestCountBefore 'Duplicate event rejection must not create executor requests.'

    $terminalRepo = New-TestRepository -RootPath $tmp -Name 'terminal-repo'
    $terminalPlanPath = Join-Path -Path $tmp -ChildPath 'terminal-command-plan.json'
    Save-Json -Value (New-TestCommandPlan -SourcePath $terminalRepo) -Path $terminalPlanPath
    Use-TestRunId -RunId 'run-terminal'
    $terminal = Invoke-LocalExecutionOrchestrator -CommandPlanPath $terminalPlanPath -SourceRepositoryPath $terminalRepo -RuntimeRootPath $runtimeRoot -Format Json | ConvertFrom-Json
    $terminalSession = Get-LatestSession -RuntimePath $terminal.runtimeDirectory
    $terminalEventPath = Join-Path -Path $tmp -ChildPath 'terminal-event.json'
    Save-Json -Value (New-HumanDecisionEvent -SessionId ([string] $terminalSession.sessionId)) -Path $terminalEventPath
    $terminalResume = Invoke-LocalExecutionResume -RuntimeDirectoryPath $terminal.runtimeDirectory -SessionEventPath $terminalEventPath -Format Json | ConvertFrom-Json
    Assert-Equal $terminalResume.status 'rejected' 'Terminal sessions must not be resumed.'

    $missing = Start-WaitingRun -Tmp $tmp -RuntimeRoot $runtimeRoot -RunId 'run-missing-artifact'
    Remove-Item -LiteralPath (Join-Path $missing.runtimeDirectory 'decisions/command-plan-effective.json') -Force
    $missingSession = Get-LatestSession -RuntimePath $missing.runtimeDirectory
    $missingEventPath = Join-Path -Path $tmp -ChildPath 'missing-event.json'
    Save-Json -Value (New-HumanDecisionEvent -SessionId ([string] $missingSession.sessionId)) -Path $missingEventPath
    $missingResume = Invoke-LocalExecutionResume -RuntimeDirectoryPath $missing.runtimeDirectory -SessionEventPath $missingEventPath -Format Json | ConvertFrom-Json
    Assert-Equal $missingResume.status 'rejected' 'Missing required runtime artifact must produce controlled rejection.'

    $artifact = Start-WaitingRun -Tmp $tmp -RuntimeRoot $runtimeRoot -RunId 'run-artifact-continuation'
    $artifactSession = Get-LatestSession -RuntimePath $artifact.runtimeDirectory
    $artifactEventPath = Join-Path -Path $tmp -ChildPath 'artifact-event.json'
    Save-Json -Value (New-HumanDecisionEvent -SessionId ([string] $artifactSession.sessionId) -EventId 'external-artifact-approved') -Path $artifactEventPath
    $namesBefore = @(Get-ChildItem -LiteralPath $artifact.runtimeDirectory -Recurse -File | ForEach-Object { $_.FullName.Substring($artifact.runtimeDirectory.Length) } | Sort-Object)
    $artifactResume = Invoke-LocalExecutionResume -RuntimeDirectoryPath $artifact.runtimeDirectory -SessionEventPath $artifactEventPath -Format Json | ConvertFrom-Json
    $namesAfter = @(Get-ChildItem -LiteralPath $artifact.runtimeDirectory -Recurse -File | ForEach-Object { $_.FullName.Substring($artifact.runtimeDirectory.Length) } | Sort-Object)
    foreach ($name in $namesBefore) { Assert-True ($name -in $namesAfter) "Resume must not remove or overwrite existing artifact '$name'." }
    Assert-Equal $artifactResume.status 'completed' 'Artifact-continuation resume must complete.'
    Assert-True (Test-Path -LiteralPath (Join-Path $artifact.runtimeDirectory 'decisions/command-session-0003-external.json') -PathType Leaf) 'External session snapshot must continue numbering deterministically.'
    Assert-True (Test-Path -LiteralPath (Join-Path $artifact.runtimeDirectory 'decisions/execution-admission-0004.json') -PathType Leaf) 'Post-resume admission must continue artifact numbering.'

    $cli = Start-WaitingRun -Tmp $tmp -RuntimeRoot $runtimeRoot -RunId 'run-cli-resume'
    $cliSession = Get-LatestSession -RuntimePath $cli.runtimeDirectory
    $cliEventPath = Join-Path -Path $tmp -ChildPath 'cli-event.json'
    Save-Json -Value (New-HumanDecisionEvent -SessionId ([string] $cliSession.sessionId) -EventId 'external-cli-approved') -Path $cliEventPath
    $cliJson = & $cliPath resume-local-execution -RuntimeDirectoryPath $cli.runtimeDirectory -SessionEventPath $cliEventPath -Format Json
    $cliResult = $cliJson | ConvertFrom-Json
    Assert-Equal $cliResult.status 'completed' 'CLI resume must emit parseable completed JSON.'
    Assert-Equal $cliResult.resumed $true 'CLI resume must mark result as resumed.'

    $loopSource = Get-Content -LiteralPath $orchestratorPath -Raw
    Assert-True (($loopSource -split 'Invoke-OrchestratorExecutionLoop').Count -ge 4) 'New run and resume must both use the shared execution loop helper.'
} finally {
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
}

$sourceText = Get-Content -LiteralPath $orchestratorPath -Raw
foreach ($forbidden in @('Invoke-Expression', 'Start-Process', 'System.Diagnostics.Process', 'ProcessStartInfo', 'Invoke-Command', 'New-PSSession', 'git add', 'git commit', 'git reset', 'git clean', 'git push')) {
    Assert-True (-not ($sourceText -match [regex]::Escape($forbidden))) "Execution resume source must not contain forbidden token '$forbidden'."
}

if ($script:failures.Count -gt 0) {
    Write-Host 'Execution Resume tests failed:'
    $script:failures | ForEach-Object { Write-Host "- $_" }
    exit 1
}

Write-Host 'Execution Resume tests passed.'
exit 0
