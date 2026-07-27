[CmdletBinding()]
param(
    [string] $CommandPlanPath,
    [string] $SourceRepositoryPath,
    [string] $RuntimeRootPath,
    [string] $RuntimeDirectoryPath,
    [string] $SessionEventPath,
    [int] $MaxAutomationSteps = 50,
    [string] $OutputPath,
    [string] $Format = 'Json',
    [ValidateSet('Start', 'Resume')]
    [string] $Operation = 'Start',
    [switch] $ModuleOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$orchestratorEntryCommandPlanPath = $CommandPlanPath
$orchestratorEntrySourceRepositoryPath = $SourceRepositoryPath
$orchestratorEntryRuntimeRootPath = $RuntimeRootPath
$orchestratorEntryRuntimeDirectoryPath = $RuntimeDirectoryPath
$orchestratorEntrySessionEventPath = $SessionEventPath
$orchestratorEntryMaxAutomationSteps = $MaxAutomationSteps
$orchestratorEntryOutputPath = $OutputPath
$orchestratorEntryFormat = $Format
$orchestratorEntryOperation = $Operation
$orchestratorEntryModuleOnly = $ModuleOnly
. (Join-Path -Path $PSScriptRoot -ChildPath 'New-RuntimeDirectory.ps1') -ModuleOnly
. (Join-Path -Path $PSScriptRoot -ChildPath 'Test-CleanTree.ps1') -ModuleOnly
. (Join-Path -Path $PSScriptRoot -ChildPath 'CommandSession.ps1')
. (Join-Path -Path $PSScriptRoot -ChildPath 'Build-ExecutorRequest.ps1') -ModuleOnly
. (Join-Path -Path $PSScriptRoot -ChildPath 'Build-AutomationEvent.ps1') -ModuleOnly
. (Join-Path -Path $PSScriptRoot -ChildPath 'Invoke-LocalOperationExecutor.ps1') -ModuleOnly
$CommandPlanPath = $orchestratorEntryCommandPlanPath
$SourceRepositoryPath = $orchestratorEntrySourceRepositoryPath
$RuntimeRootPath = $orchestratorEntryRuntimeRootPath
$RuntimeDirectoryPath = $orchestratorEntryRuntimeDirectoryPath
$SessionEventPath = $orchestratorEntrySessionEventPath
$MaxAutomationSteps = $orchestratorEntryMaxAutomationSteps
$OutputPath = $orchestratorEntryOutputPath
$Format = $orchestratorEntryFormat
$Operation = $orchestratorEntryOperation
$ModuleOnly = $orchestratorEntryModuleOnly

function Resolve-OrchestratorPath {
    param([Parameter(Mandatory = $true)][string] $Path)
    $executionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function Read-OrchestratorJsonFile {
    param([Parameter(Mandatory = $true)][string] $Path, [Parameter(Mandatory = $true)][string] $Description)
    $resolved = Resolve-OrchestratorPath -Path $Path
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) { throw "$Description file does not exist: $resolved" }
    try {
        return (Get-Content -LiteralPath $resolved -Raw | ConvertFrom-Json)
    } catch {
        throw "Invalid $Description JSON in '$resolved': $($_.Exception.Message)"
    }
}

function Copy-OrchestratorObject {
    param([Parameter(Mandatory = $true)][object] $Value)
    return $Value | ConvertTo-Json -Depth 100 | ConvertFrom-Json
}

function Test-OrchestratorProperty {
    param([object] $Object, [Parameter(Mandatory = $true)][string] $Name)
    return ($null -ne $Object -and @($Object.PSObject.Properties | Where-Object { $_.Name -eq $Name }).Count -gt 0)
}

function Test-OrchestratorPathWithinDirectory {
    param([Parameter(Mandatory = $true)][string] $Path, [Parameter(Mandatory = $true)][string] $Directory)
    $directoryFull = [System.IO.Path]::GetFullPath($Directory).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    $pathFull = [System.IO.Path]::GetFullPath($Path)
    return $pathFull.StartsWith($directoryFull, [System.StringComparison]::OrdinalIgnoreCase)
}

function Write-OrchestratorJson {
    param([Parameter(Mandatory = $true)][object] $Value, [Parameter(Mandatory = $true)][string] $Path, [string] $RuntimeDirectory = '')
    $resolved = Resolve-OrchestratorPath -Path $Path
    if (-not [string]::IsNullOrWhiteSpace($RuntimeDirectory) -and -not (Test-OrchestratorPathWithinDirectory -Path $resolved -Directory $RuntimeDirectory)) {
        throw "Execution orchestrator validation failed: output path must be inside runtime directory: $resolved"
    }
    if (-not [string]::IsNullOrWhiteSpace($RuntimeDirectory) -and (Test-Path -LiteralPath $resolved -PathType Leaf)) {
        throw "Execution orchestrator validation failed: refusing to overwrite existing artifact: $resolved"
    }
    $directory = Split-Path -Path $resolved -Parent
    if (-not [string]::IsNullOrWhiteSpace($directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    $json = $Value | ConvertTo-Json -Depth 100
    $json | Set-Content -LiteralPath $resolved -Encoding utf8
    return $json
}

function Set-OrchestratorSummaryJson {
    param([Parameter(Mandatory = $true)][object] $Summary, [Parameter(Mandatory = $true)][object] $Runtime, [string] $OutputPath)
    $summaryPath = Join-Path -Path $Runtime.reportsDirectory -ChildPath 'execution-summary.json'
    $json = $Summary | ConvertTo-Json -Depth 100
    $json | Set-Content -LiteralPath $summaryPath -Encoding utf8
    if (-not [string]::IsNullOrWhiteSpace($OutputPath)) { Write-OrchestratorJson -Value $Summary -Path $OutputPath | Out-Null }
}

function Get-OrchestratorTimestamp {
    return [DateTimeOffset]::UtcNow.UtcDateTime.ToString('O', [System.Globalization.CultureInfo]::InvariantCulture)
}

function New-OrchestratorResult {
    param(
        [Parameter(Mandatory = $true)][string] $Status,
        [object] $Runtime = $null,
        [object] $Session = $null,
        [int] $ExecutedAutomationCount = 0,
        [bool] $HumanActionRequired = $false,
        [bool] $Resumed = $false,
        [string] $AppliedExternalEventId = '',
        [string] $Diagnostic = ''
    )
    return [pscustomobject]@{
        schemaVersion = '0.1'
        orchestratorResultType = 'deployment-execution-orchestrator-result'
        status = $Status
        runtimeDirectory = if ($null -ne $Runtime) { [string] $Runtime.runtimeDirectory } else { '' }
        sessionId = if ($null -ne $Session -and (Test-OrchestratorProperty -Object $Session -Name 'sessionId')) { [string] $Session.sessionId } else { '' }
        sessionStatus = if ($null -ne $Session -and (Test-OrchestratorProperty -Object $Session -Name 'status')) { [string] $Session.status } else { '' }
        currentItemId = if ($null -ne $Session -and (Test-OrchestratorProperty -Object $Session -Name 'currentItemId')) { [string] $Session.currentItemId } else { '' }
        resumed = $Resumed
        appliedExternalEventId = $AppliedExternalEventId
        executedAutomationCount = $ExecutedAutomationCount
        humanActionRequired = $HumanActionRequired
        diagnostic = $Diagnostic
    }
}

function New-OrchestratorRuntimeFromDirectory {
    param([Parameter(Mandatory = $true)][string] $RuntimeDirectoryPath)
    $runtimeDirectory = Resolve-OrchestratorPath -Path $RuntimeDirectoryPath
    if (-not (Test-Path -LiteralPath $runtimeDirectory -PathType Container)) {
        throw "Execution resume validation failed: runtime directory does not exist: $runtimeDirectory"
    }
    $subdirs = @('artifacts', 'decisions', 'events', 'input', 'inventory', 'logs', 'reports')
    foreach ($subdir in $subdirs) {
        $path = Join-Path -Path $runtimeDirectory -ChildPath $subdir
        if (-not (Test-Path -LiteralPath $path -PathType Container)) {
            throw "Execution resume validation failed: runtime subdirectory is missing: $subdir"
        }
    }
    return [pscustomobject]@{
        schemaVersion = '0.1'
        runtimeType = 'deployment-runtime-directory'
        runId = Split-Path -Path $runtimeDirectory -Leaf
        runtimeRootDirectory = Split-Path -Path $runtimeDirectory -Parent
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

function Set-OrchestratorRuntimeArtifactPaths {
    param([Parameter(Mandatory = $true)][object] $CommandPlan, [Parameter(Mandatory = $true)][object] $Runtime)
    $plan = Copy-OrchestratorObject -Value $CommandPlan
    $defaultArtifact = Join-Path -Path ([string] $Runtime.artifactsDirectory) -ChildPath 'deployment.zip'
    foreach ($command in @($plan.commands)) {
        if ([string] $command.program -ne 'local-operation') { continue }
        $operationType = [string] $command.operationType
        if ($operationType -notin @('archive.create', 'archive-create')) { continue }
        if (-not (Test-OrchestratorProperty -Object $command -Name 'operation') -or $null -eq $command.operation) {
            Add-Member -InputObject $command -MemberType NoteProperty -Name 'operation' -Value ([pscustomobject]@{}) -Force
        }
        $artifactPath = if (Test-OrchestratorProperty -Object $command.operation -Name 'artifactPath') { [string] $command.operation.artifactPath } else { '' }
        if ([string]::IsNullOrWhiteSpace($artifactPath)) {
            Add-Member -InputObject $command.operation -MemberType NoteProperty -Name 'artifactPath' -Value $defaultArtifact -Force
        } else {
            $resolvedArtifact = Resolve-OrchestratorPath -Path $artifactPath
            if (-not (Test-OrchestratorPathWithinDirectory -Path $resolvedArtifact -Directory ([string] $Runtime.runtimeDirectory))) {
                throw "Execution orchestrator validation failed: archive artifactPath must be inside runtime directory."
            }
            $command.operation.artifactPath = $resolvedArtifact
        }
    }
    return $plan
}

function Get-OrchestratorFinalStatus {
    param([Parameter(Mandatory = $true)][string] $SessionStatus)
    if ($SessionStatus -in @('completed', 'failed', 'blocked', 'cancelled')) { return $SessionStatus }
    return 'blocked'
}

function Get-OrchestratorNextArtifactIndex {
    param([Parameter(Mandatory = $true)][object] $Runtime)
    $max = 0
    foreach ($directory in @($Runtime.decisionsDirectory, $Runtime.eventsDirectory)) {
        foreach ($file in @(Get-ChildItem -LiteralPath $directory -File -ErrorAction SilentlyContinue)) {
            if ($file.Name -match '-(\d{4})(?:[-.]|\.json$)') {
                $value = [int] $Matches[1]
                if ($value -gt $max) { $max = $value }
            }
        }
    }
    return ($max + 1)
}

function Get-OrchestratorLatestSessionSnapshot {
    param([Parameter(Mandatory = $true)][object] $Runtime)
    $entries = @()
    foreach ($file in @(Get-ChildItem -LiteralPath $Runtime.decisionsDirectory -File -Filter 'command-session-*.json' -ErrorAction SilentlyContinue)) {
        if ($file.Name -match '^command-session-(\d{4})(?:-(started|external|result))?\.json$') {
            $suffix = if ($Matches.Count -gt 2) { [string] $Matches[2] } else { '' }
            $rank = switch ($suffix) {
                'started' { 1 }
                'external' { 2 }
                'result' { 3 }
                default { 0 }
            }
            $entries += [pscustomobject]@{ path = $file.FullName; index = [int] $Matches[1]; rank = $rank }
        }
    }
    if ($entries.Count -eq 0) { throw 'Execution resume validation failed: no command-session snapshot found.' }
    $latest = @($entries | Sort-Object index, rank, path | Select-Object -Last 1)[0]
    return Read-OrchestratorJsonFile -Path ([string] $latest.path) -Description 'Command session snapshot'
}

function Get-OrchestratorNextExternalEventIndex {
    param([Parameter(Mandatory = $true)][object] $Runtime)
    $max = 0
    foreach ($file in @(Get-ChildItem -LiteralPath $Runtime.eventsDirectory -File -Filter 'external-session-event-*.json' -ErrorAction SilentlyContinue)) {
        if ($file.Name -match '^external-session-event-(\d{4})\.json$') {
            $value = [int] $Matches[1]
            if ($value -gt $max) { $max = $value }
        }
    }
    return ($max + 1)
}

function Get-OrchestratorInteger {
    param([object] $Object, [string] $Name, [int] $Default = 0)
    if ($null -eq $Object -or -not (Test-OrchestratorProperty -Object $Object -Name $Name)) { return $Default }
    return [int] $Object.$Name
}

function Assert-OrchestratorArtifactPathAvailable {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][object] $Runtime
    )
    $resolved = Resolve-OrchestratorPath -Path $Path
    if (-not (Test-OrchestratorPathWithinDirectory -Path $resolved -Directory ([string] $Runtime.runtimeDirectory))) {
        throw "Execution resume validation failed: artifact path must be inside runtime directory: $resolved"
    }
    if (Test-Path -LiteralPath $resolved -PathType Leaf) {
        throw "Execution resume validation failed: refusing to overwrite existing artifact: $resolved"
    }
}

function Assert-OrchestratorResumeArtifactSlotsAvailable {
    param(
        [Parameter(Mandatory = $true)][object] $Runtime,
        [Parameter(Mandatory = $true)][int] $ExternalEventIndex,
        [Parameter(Mandatory = $true)][int] $SessionSnapshotIndex,
        [Parameter(Mandatory = $true)][int] $LoopStartIndex
    )
    $paths = @(
        (Join-Path -Path $Runtime.eventsDirectory -ChildPath ('external-session-event-{0:0000}.json' -f $ExternalEventIndex))
        (Join-Path -Path $Runtime.decisionsDirectory -ChildPath ('command-session-{0:0000}-external.json' -f $SessionSnapshotIndex))
        (Join-Path -Path $Runtime.decisionsDirectory -ChildPath ('execution-admission-{0:0000}.json' -f $LoopStartIndex))
        (Join-Path -Path $Runtime.decisionsDirectory -ChildPath ('executor-request-{0:0000}.json' -f $LoopStartIndex))
        (Join-Path -Path $Runtime.eventsDirectory -ChildPath ('automation-started-{0:0000}.json' -f $LoopStartIndex))
        (Join-Path -Path $Runtime.decisionsDirectory -ChildPath ('command-session-{0:0000}-started.json' -f $LoopStartIndex))
        (Join-Path -Path $Runtime.decisionsDirectory -ChildPath ('executor-result-{0:0000}.json' -f $LoopStartIndex))
        (Join-Path -Path $Runtime.eventsDirectory -ChildPath ('automation-result-{0:0000}.json' -f $LoopStartIndex))
        (Join-Path -Path $Runtime.decisionsDirectory -ChildPath ('command-session-{0:0000}-result.json' -f $LoopStartIndex))
    )
    foreach ($path in $paths) { Assert-OrchestratorArtifactPathAvailable -Path $path -Runtime $Runtime }
}

function Assert-OrchestratorResumeEvent {
    param([Parameter(Mandatory = $true)][object] $Event, [Parameter(Mandatory = $true)][object] $Session)
    if (-not (Test-OrchestratorProperty -Object $Event -Name 'eventType')) {
        throw "Execution resume validation failed: external event is missing eventType."
    }
    if ([string] $Event.eventType -notin @('human-decision-submitted', 'human-command-result', 'review-result')) {
        throw "Execution resume validation failed: unsupported external event type '$($Event.eventType)'."
    }
    if (-not (Test-OrchestratorProperty -Object $Event -Name 'sessionId') -or [string]::IsNullOrWhiteSpace([string] $Event.sessionId)) {
        throw 'Execution resume validation failed: external event must contain sessionId.'
    }
    if ([string] $Event.sessionId -ne [string] $Session.sessionId) {
        throw 'Execution resume validation failed: external event sessionId does not match command session.'
    }
    if (-not (Test-OrchestratorProperty -Object $Event -Name 'eventId') -or [string]::IsNullOrWhiteSpace([string] $Event.eventId)) {
        throw 'Execution resume validation failed: external event must contain eventId.'
    }
    if (@($Session.eventHistory | Where-Object { [string] $_.eventId -eq [string] $Event.eventId }).Count -gt 0) {
        throw "Execution resume validation failed: external eventId '$($Event.eventId)' was already applied."
    }
}

function Assert-OrchestratorResumePreconditions {
    param(
        [Parameter(Mandatory = $true)][object] $Runtime,
        [Parameter(Mandatory = $true)][object] $CommandPlan,
        [Parameter(Mandatory = $true)][object] $Summary,
        [Parameter(Mandatory = $true)][object] $Session
    )
    $summaryRuntime = if (Test-OrchestratorProperty -Object $Summary -Name 'runtimeDirectory') { Resolve-OrchestratorPath -Path ([string] $Summary.runtimeDirectory) } else { '' }
    if ($summaryRuntime -ne [string] $Runtime.runtimeDirectory) {
        throw 'Execution resume validation failed: summary does not belong to this runtime directory.'
    }
    if (-not (Test-OrchestratorProperty -Object $Summary -Name 'status') -or [string] $Summary.status -ne 'waiting-for-human') {
        throw 'Execution resume validation failed: previous orchestrator status must be waiting-for-human.'
    }
    if ([string] $Session.status -in @('completed', 'failed', 'blocked', 'cancelled')) {
        throw "Execution resume validation failed: terminal command session '$($Session.status)' cannot be resumed."
    }
    if (-not (Test-OrchestratorProperty -Object $Summary -Name 'sessionId') -or [string] $Summary.sessionId -ne [string] $Session.sessionId) {
        throw 'Execution resume validation failed: summary sessionId does not match latest command session.'
    }
    if (-not (Test-OrchestratorProperty -Object $Summary -Name 'currentItemId') -or [string] $Summary.currentItemId -ne [string] $Session.currentItemId) {
        throw 'Execution resume validation failed: summary currentItemId does not match latest command session.'
    }
    $admission = Resolve-ExecutionAdmission -CommandPlan $CommandPlan -CommandSession $Session
    if ($admission.status -notin @('requires-human', 'requires-review')) {
        throw "Execution resume validation failed: latest session does not expect human or review input; admission status is '$($admission.status)'."
    }
}

function Invoke-OrchestratorExecutionLoop {
    param(
        [Parameter(Mandatory = $true)][object] $CommandPlan,
        [Parameter(Mandatory = $true)][object] $CommandSession,
        [Parameter(Mandatory = $true)][object] $Runtime,
        [int] $StartIndex = 1,
        [int] $MaxAutomationSteps = 50,
        [int] $ExecutedAutomationCount = 0,
        [bool] $Resumed = $false,
        [string] $AppliedExternalEventId = ''
    )
    $session = $CommandSession
    $executed = $ExecutedAutomationCount
    $summary = $null
    for ($step = $StartIndex; $step -le ($StartIndex + $MaxAutomationSteps); $step++) {
        $admission = Resolve-ExecutionAdmission -CommandPlan $CommandPlan -CommandSession $session
        Write-OrchestratorJson -Value $admission -Path (Join-Path -Path $Runtime.decisionsDirectory -ChildPath ('execution-admission-{0:0000}.json' -f $step)) -RuntimeDirectory $Runtime.runtimeDirectory | Out-Null

        if ($session.status -in @('completed', 'failed', 'blocked', 'cancelled')) {
            $summary = New-OrchestratorResult -Status (Get-OrchestratorFinalStatus -SessionStatus ([string] $session.status)) -Runtime $Runtime -Session $session -ExecutedAutomationCount $executed -Resumed:$Resumed -AppliedExternalEventId $AppliedExternalEventId
            break
        }

        if ($admission.status -in @('requires-human', 'requires-review')) {
            $summary = New-OrchestratorResult -Status 'waiting-for-human' -Runtime $Runtime -Session $session -ExecutedAutomationCount $executed -HumanActionRequired:$true -Resumed:$Resumed -AppliedExternalEventId $AppliedExternalEventId -Diagnostic "Execution paused because admission status is '$($admission.status)'."
            break
        }

        if ($admission.status -ne 'eligible-but-disabled') {
            $summary = New-OrchestratorResult -Status 'blocked' -Runtime $Runtime -Session $session -ExecutedAutomationCount $executed -Resumed:$Resumed -AppliedExternalEventId $AppliedExternalEventId -Diagnostic "Execution paused because admission status is '$($admission.status)'."
            break
        }

        if ($executed -ge $MaxAutomationSteps) {
            $summary = New-OrchestratorResult -Status 'failed' -Runtime $Runtime -Session $session -ExecutedAutomationCount $executed -Resumed:$Resumed -AppliedExternalEventId $AppliedExternalEventId -Diagnostic 'MaxAutomationSteps limit reached before the next automation could start.'
            break
        }

        $request = Resolve-ExecutorRequest -CommandPlan $CommandPlan -CommandSession $session -ExecutionAdmission $admission
        Write-OrchestratorJson -Value $request -Path (Join-Path -Path $Runtime.decisionsDirectory -ChildPath ('executor-request-{0:0000}.json' -f $step)) -RuntimeDirectory $Runtime.runtimeDirectory | Out-Null

        $startedEvent = Build-AutomationStartedEvent -CommandSession $session -ExecutorRequest $request -Timestamp (Get-OrchestratorTimestamp)
        Write-OrchestratorJson -Value $startedEvent -Path (Join-Path -Path $Runtime.eventsDirectory -ChildPath ('automation-started-{0:0000}.json' -f $step)) -RuntimeDirectory $Runtime.runtimeDirectory | Out-Null
        $runningSession = Apply-CommandSessionEvent -CommandSession $session -Event $startedEvent
        Write-OrchestratorJson -Value $runningSession -Path (Join-Path -Path $Runtime.decisionsDirectory -ChildPath ('command-session-{0:0000}-started.json' -f $step)) -RuntimeDirectory $Runtime.runtimeDirectory | Out-Null

        $executorResult = Invoke-LocalOperationRequest -ExecutorRequest $request
        Write-OrchestratorJson -Value $executorResult -Path (Join-Path -Path $Runtime.decisionsDirectory -ChildPath ('executor-result-{0:0000}.json' -f $step)) -RuntimeDirectory $Runtime.runtimeDirectory | Out-Null

        $resultEvent = Build-AutomationResultEvent -CommandSession $runningSession -ExecutorRequest $request -ExecutorResult $executorResult -Timestamp (Get-OrchestratorTimestamp)
        Write-OrchestratorJson -Value $resultEvent -Path (Join-Path -Path $Runtime.eventsDirectory -ChildPath ('automation-result-{0:0000}.json' -f $step)) -RuntimeDirectory $Runtime.runtimeDirectory | Out-Null
        $session = Apply-CommandSessionEvent -CommandSession $runningSession -Event $resultEvent
        Write-OrchestratorJson -Value $session -Path (Join-Path -Path $Runtime.decisionsDirectory -ChildPath ('command-session-{0:0000}-result.json' -f $step)) -RuntimeDirectory $Runtime.runtimeDirectory | Out-Null
        $executed++
    }

    if ($null -eq $summary) {
        $summary = New-OrchestratorResult -Status 'failed' -Runtime $Runtime -Session $session -ExecutedAutomationCount $executed -Resumed:$Resumed -AppliedExternalEventId $AppliedExternalEventId -Diagnostic 'Execution loop ended without a terminal or pause state.'
    }
    return $summary
}

function Invoke-LocalExecutionOrchestrator {
    param(
        [Parameter(Mandatory = $true)][string] $CommandPlanPath,
        [Parameter(Mandatory = $true)][string] $SourceRepositoryPath,
        [Parameter(Mandatory = $true)][string] $RuntimeRootPath,
        [int] $MaxAutomationSteps = 50,
        [string] $OutputPath,
        [string] $Format = 'Json'
    )
    if ($Format -ne 'Json') { throw "orchestrate-local-execution only supports -Format Json." }
    if ($MaxAutomationSteps -lt 0) { throw 'Execution orchestrator validation failed: MaxAutomationSteps must not be negative.' }

    $runtime = $null
    $session = $null
    $executedAutomationCount = 0
    $summary = $null
    try {
        $commandPlan = Read-OrchestratorJsonFile -Path $CommandPlanPath -Description 'Command plan'
        $runtime = New-DeploymentRuntimeDirectory -RuntimeRootPath $RuntimeRootPath
        Write-OrchestratorJson -Value $commandPlan -Path (Join-Path -Path $runtime.inputDirectory -ChildPath 'command-plan.json') -RuntimeDirectory $runtime.runtimeDirectory | Out-Null

        $cleanTree = New-CleanTreeAssessment -RepositoryPath $SourceRepositoryPath
        Write-OrchestratorJson -Value $cleanTree -Path (Join-Path -Path $runtime.decisionsDirectory -ChildPath 'clean-tree-assessment.json') -RuntimeDirectory $runtime.runtimeDirectory | Out-Null
        if (-not [bool] $cleanTree.deploymentAllowed) {
            $summary = New-OrchestratorResult -Status 'blocked' -Runtime $runtime -Diagnostic 'Clean-Tree Assessment blocked local execution.'
            Set-OrchestratorSummaryJson -Summary $summary -Runtime $runtime -OutputPath $OutputPath
            return $summary | ConvertTo-Json -Depth 100
        }

        $effectivePlan = Set-OrchestratorRuntimeArtifactPaths -CommandPlan $commandPlan -Runtime $runtime
        Write-OrchestratorJson -Value $effectivePlan -Path (Join-Path -Path $runtime.decisionsDirectory -ChildPath 'command-plan-effective.json') -RuntimeDirectory $runtime.runtimeDirectory | Out-Null
        $session = New-CommandSession -CommandPlan $effectivePlan
        Write-OrchestratorJson -Value $session -Path (Join-Path -Path $runtime.decisionsDirectory -ChildPath 'command-session-0000.json') -RuntimeDirectory $runtime.runtimeDirectory | Out-Null

        $summary = Invoke-OrchestratorExecutionLoop -CommandPlan $effectivePlan -CommandSession $session -Runtime $runtime -StartIndex 1 -MaxAutomationSteps $MaxAutomationSteps -ExecutedAutomationCount $executedAutomationCount
    } catch {
        $status = if ($null -eq $runtime) { 'rejected' } else { 'failed' }
        $summary = New-OrchestratorResult -Status $status -Runtime $runtime -Session $session -ExecutedAutomationCount $executedAutomationCount -Diagnostic $_.Exception.Message
    }

    if ($null -ne $runtime) { Set-OrchestratorSummaryJson -Summary $summary -Runtime $runtime -OutputPath $OutputPath }
    elseif (-not [string]::IsNullOrWhiteSpace($OutputPath)) { Write-OrchestratorJson -Value $summary -Path $OutputPath | Out-Null }
    return $summary | ConvertTo-Json -Depth 100
}

function Invoke-LocalExecutionResume {
    param(
        [Parameter(Mandatory = $true)][string] $RuntimeDirectoryPath,
        [Parameter(Mandatory = $true)][string] $SessionEventPath,
        [int] $MaxAutomationSteps = 50,
        [string] $OutputPath,
        [string] $Format = 'Json'
    )
    if ($Format -ne 'Json') { throw "resume-local-execution only supports -Format Json." }
    if ($MaxAutomationSteps -lt 0) { throw 'Execution resume validation failed: MaxAutomationSteps must not be negative.' }

    $runtime = $null
    $session = $null
    $event = $null
    $appliedExternalEventId = ''
    $executedAutomationCount = 0
    $summary = $null
    $resumeAccepted = $false
    try {
        $runtime = New-OrchestratorRuntimeFromDirectory -RuntimeDirectoryPath $RuntimeDirectoryPath
        $inputPlan = Read-OrchestratorJsonFile -Path (Join-Path -Path $runtime.inputDirectory -ChildPath 'command-plan.json') -Description 'Input command plan'
        $effectivePlan = Read-OrchestratorJsonFile -Path (Join-Path -Path $runtime.decisionsDirectory -ChildPath 'command-plan-effective.json') -Description 'Effective command plan'
        $previousSummary = Read-OrchestratorJsonFile -Path (Join-Path -Path $runtime.reportsDirectory -ChildPath 'execution-summary.json') -Description 'Execution summary'
        $session = Get-OrchestratorLatestSessionSnapshot -Runtime $runtime
        $event = Read-OrchestratorJsonFile -Path $SessionEventPath -Description 'External command session event'
        $null = $inputPlan

        Assert-OrchestratorResumePreconditions -Runtime $runtime -CommandPlan $effectivePlan -Summary $previousSummary -Session $session
        Assert-OrchestratorResumeEvent -Event $event -Session $session
        $appliedExternalEventId = [string] $event.eventId

        $externalIndex = Get-OrchestratorNextExternalEventIndex -Runtime $runtime
        $sessionSnapshotIndex = Get-OrchestratorNextArtifactIndex -Runtime $runtime
        $startIndex = $sessionSnapshotIndex + 1
        Assert-OrchestratorResumeArtifactSlotsAvailable -Runtime $runtime -ExternalEventIndex $externalIndex -SessionSnapshotIndex $sessionSnapshotIndex -LoopStartIndex $startIndex

        $updatedSession = Apply-CommandSessionEvent -CommandSession $session -Event $event
        Write-OrchestratorJson -Value $event -Path (Join-Path -Path $runtime.eventsDirectory -ChildPath ('external-session-event-{0:0000}.json' -f $externalIndex)) -RuntimeDirectory $runtime.runtimeDirectory | Out-Null
        Write-OrchestratorJson -Value $updatedSession -Path (Join-Path -Path $runtime.decisionsDirectory -ChildPath ('command-session-{0:0000}-external.json' -f $sessionSnapshotIndex)) -RuntimeDirectory $runtime.runtimeDirectory | Out-Null

        $executedAutomationCount = Get-OrchestratorInteger -Object $previousSummary -Name 'executedAutomationCount' -Default 0
        $resumeAccepted = $true
        $summary = Invoke-OrchestratorExecutionLoop -CommandPlan $effectivePlan -CommandSession $updatedSession -Runtime $runtime -StartIndex $startIndex -MaxAutomationSteps $MaxAutomationSteps -ExecutedAutomationCount $executedAutomationCount -Resumed:$true -AppliedExternalEventId $appliedExternalEventId
    } catch {
        $summary = New-OrchestratorResult -Status 'rejected' -Runtime $runtime -Session $session -ExecutedAutomationCount $executedAutomationCount -Resumed:$true -AppliedExternalEventId $appliedExternalEventId -Diagnostic $_.Exception.Message
    }

    if ($null -ne $runtime -and $resumeAccepted) { Set-OrchestratorSummaryJson -Summary $summary -Runtime $runtime -OutputPath $OutputPath }
    elseif (-not [string]::IsNullOrWhiteSpace($OutputPath)) { Write-OrchestratorJson -Value $summary -Path $OutputPath | Out-Null }
    return $summary | ConvertTo-Json -Depth 100
}

if (-not $ModuleOnly) {
    if ($Operation -eq 'Resume') {
        if ([string]::IsNullOrWhiteSpace($RuntimeDirectoryPath)) { throw "Missing required parameter for 'resume-local-execution': -RuntimeDirectoryPath" }
        if ([string]::IsNullOrWhiteSpace($SessionEventPath)) { throw "Missing required parameter for 'resume-local-execution': -SessionEventPath" }
        Invoke-LocalExecutionResume -RuntimeDirectoryPath $RuntimeDirectoryPath -SessionEventPath $SessionEventPath -MaxAutomationSteps $MaxAutomationSteps -OutputPath $OutputPath -Format $Format
    } else {
        if ([string]::IsNullOrWhiteSpace($CommandPlanPath)) { throw "Missing required parameter for 'orchestrate-local-execution': -CommandPlanPath" }
        if ([string]::IsNullOrWhiteSpace($SourceRepositoryPath)) { throw "Missing required parameter for 'orchestrate-local-execution': -SourceRepositoryPath" }
        if ([string]::IsNullOrWhiteSpace($RuntimeRootPath)) { throw "Missing required parameter for 'orchestrate-local-execution': -RuntimeRootPath" }
        Invoke-LocalExecutionOrchestrator -CommandPlanPath $CommandPlanPath -SourceRepositoryPath $SourceRepositoryPath -RuntimeRootPath $RuntimeRootPath -MaxAutomationSteps $MaxAutomationSteps -OutputPath $OutputPath -Format $Format
    }
}
