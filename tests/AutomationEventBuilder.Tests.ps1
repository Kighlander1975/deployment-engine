[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:failures = New-Object System.Collections.Generic.List[string]
$engineRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '..'))
$sessionModulePath = Join-Path -Path $engineRoot -ChildPath 'src/ps1/CommandSession.ps1'
$requestModulePath = Join-Path -Path $engineRoot -ChildPath 'src/ps1/Build-ExecutorRequest.ps1'
$executorModulePath = Join-Path -Path $engineRoot -ChildPath 'src/ps1/Invoke-LocalOperationExecutor.ps1'
$eventBuilderPath = Join-Path -Path $engineRoot -ChildPath 'src/ps1/Build-AutomationEvent.ps1'
$cliPath = Join-Path -Path $engineRoot -ChildPath 'bin/deployment-engine.ps1'

. $sessionModulePath
. $requestModulePath -ModuleOnly
. $executorModulePath -ModuleOnly
. $eventBuilderPath -ModuleOnly

function Assert-True { param([bool] $Condition, [string] $Message) if (-not $Condition) { $script:failures.Add($Message) } }
function Assert-Equal { param($Actual, $Expected, [string] $Message) if ($Actual -ne $Expected) { $script:failures.Add("$Message Expected '$Expected', got '$Actual'.") } }
function Assert-ThrowsLike {
    param([scriptblock] $Script, [string] $Pattern, [string] $Message)
    try { & $Script; $script:failures.Add($Message) } catch { Assert-True ($_.Exception.Message -match $Pattern) "$Message Actual error: $($_.Exception.Message)" }
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
    param([string] $SourcePath = 'D:\Projects\demo', [string] $ArtifactPath = 'D:\Projects\artifact.zip')
    return [pscustomobject]@{
        schemaVersion = '0.1'
        commandPlanType = 'deployment-command-plan'
        status = 'ready'
        sourceStrategyType = 'deployment'
        selectedAdapterId = 'archive.zip'
        executionPolicy = [pscustomobject]@{ executionAllowed = $false; automaticExecutionAllowed = $false; remoteExecutionMode = 'copy-and-run' }
        commands = @(
            New-TestCommand -Id 'source.validate' -Sequence 100 -Actor 'automation' -Location 'local' -Mode 'automatic' -Program 'local-operation' -Operation ([pscustomobject]@{ sourcePath = $SourcePath })
            New-TestCommand -Id 'archive.create' -Sequence 300 -Actor 'automation' -Location 'local' -Mode 'automatic' -Program 'local-operation' -DependsOn @('source.validate') -Operation ([pscustomobject]@{ sourcePath = $SourcePath; artifactPath = $ArtifactPath })
            New-TestCommand -Id 'remote.archive.upload' -Sequence 600 -Actor 'human-command' -Location 'local-to-remote' -Mode 'copy-and-run' -Program 'scp' -DependsOn @('deployment.approval') -RenderedCommand 'scp artifact deploy@example.org:/absolute/artifact.zip'
        )
        humanGates = @(
            [pscustomobject]@{ gateId = 'deployment.approval'; stepId = 'deployment.approval'; sequence = 400; dependsOn = @('archive.create'); gateType = 'approval'; blocksContinuation = $true; allowedResponses = @('approved', 'rejected') }
        )
        diagnostic = ''
    }
}

function New-SessionEvent {
    param([string] $Id, [string] $Type, [string] $Target, [object] $Payload)
    $event = [pscustomobject]@{ schemaVersion = '0.1'; eventId = $Id; eventType = $Type; targetItemId = $Target }
    if ($null -ne $Payload) {
        foreach ($property in $Payload.PSObject.Properties) { Add-Member -InputObject $event -MemberType NoteProperty -Name $property.Name -Value $property.Value }
    }
    return $event
}

function Copy-TestObject {
    param([Parameter(Mandatory = $true)][object] $Value)
    return $Value | ConvertTo-Json -Depth 100 | ConvertFrom-Json
}

function New-TestRequest {
    param([object] $Plan, [object] $Session)
    $admission = Resolve-ExecutionAdmission -CommandPlan $Plan -CommandSession $Session
    return Resolve-ExecutorRequest -CommandPlan $Plan -CommandSession $Session -ExecutionAdmission $admission
}

function Complete-AutomationWithBuilder {
    param([object] $Session, [object] $Request, [object] $Result, [string] $Prefix = 'flow')
    $startedEvent = Build-AutomationStartedEvent -CommandSession $Session -ExecutorRequest $Request -Timestamp "2026-07-27T12:00:00Z"
    $runningSession = Apply-CommandSessionEvent -CommandSession $Session -Event $startedEvent
    $resultEvent = Build-AutomationResultEvent -CommandSession $runningSession -ExecutorRequest $Request -ExecutorResult $Result -Timestamp "2026-07-27T12:00:01Z"
    return Apply-CommandSessionEvent -CommandSession $runningSession -Event $resultEvent
}

$timestamp = '2026-07-27T12:00:00Z'
$plan = New-TestCommandPlan
$session = New-CommandSession -CommandPlan $plan
$request = New-TestRequest -Plan $plan -Session $session

$sessionBefore = $session | ConvertTo-Json -Depth 100
$requestBefore = $request | ConvertTo-Json -Depth 100
$started = Build-AutomationStartedEvent -CommandSession $session -ExecutorRequest $request -Timestamp $timestamp
Assert-Equal $started.schemaVersion '0.1' 'Started event schema must match command session events.'
Assert-Equal $started.eventType 'automation-started' 'Started builder must create automation-started event.'
Assert-Equal $started.targetItemId 'source.validate' 'Started event target must match request item.'
Assert-Equal $started.commandId 'source.validate' 'Started event commandId must match request command.'
Assert-Equal $started.actor 'automation' 'Started event actor must be automation.'
Assert-Equal $started.operationType 'source.validate' 'Started event operation type must match request.'
Assert-Equal $started.timestamp '2026-07-27T12:00:00.0000000Z' 'Started event timestamp must be normalized to UTC.'
Assert-Equal ($session | ConvertTo-Json -Depth 100) $sessionBefore 'Started builder must not mutate session input.'
Assert-Equal ($request | ConvertTo-Json -Depth 100) $requestBefore 'Started builder must not mutate request input.'
Assert-Equal (Build-AutomationStartedEvent -CommandSession $session -ExecutorRequest $request -Timestamp $timestamp | ConvertTo-Json -Depth 100) ($started | ConvertTo-Json -Depth 100) 'Started event output must be deterministic.'

$sessionWithId = Copy-TestObject -Value $session
$sessionWithId.sessionId = 'session-1'
$requestWithOtherId = Copy-TestObject -Value $request
$requestWithOtherId.sessionId = 'session-2'
Assert-ThrowsLike -Script { Build-AutomationStartedEvent -CommandSession $sessionWithId -ExecutorRequest $requestWithOtherId -Timestamp $timestamp | Out-Null } -Pattern 'Session-ID' -Message 'Started builder must reject mismatched Session-ID.'
$wrongItem = Copy-TestObject -Value $request
$wrongItem.itemId = 'archive.create'
Assert-ThrowsLike -Script { Build-AutomationStartedEvent -CommandSession $session -ExecutorRequest $wrongItem -Timestamp $timestamp | Out-Null } -Pattern 'current item|dependency' -Message 'Started builder must reject wrong itemId.'
$wrongCommand = Copy-TestObject -Value $request
$wrongCommand.commandId = 'archive.create'
Assert-ThrowsLike -Script { Build-AutomationStartedEvent -CommandSession $session -ExecutorRequest $wrongCommand -Timestamp $timestamp | Out-Null } -Pattern 'commandId' -Message 'Started builder must reject wrong commandId.'
$humanRequest = Copy-TestObject -Value $request
$humanRequest.itemId = 'remote.archive.upload'
$humanRequest.commandId = 'remote.archive.upload'
Assert-ThrowsLike -Script { Build-AutomationStartedEvent -CommandSession $session -ExecutorRequest $humanRequest -Timestamp $timestamp | Out-Null } -Pattern 'current item|does not match' -Message 'Started builder must reject human item targets.'
$remoteRequest = Copy-TestObject -Value $request
$remoteRequest.executionLocation = 'remote'
Assert-ThrowsLike -Script { Build-AutomationStartedEvent -CommandSession $session -ExecutorRequest $remoteRequest -Timestamp $timestamp | Out-Null } -Pattern 'executionLocation' -Message 'Started builder must reject remote automation.'
$running = Apply-CommandSessionEvent -CommandSession $session -Event $started
Assert-ThrowsLike -Script { Build-AutomationStartedEvent -CommandSession $running -ExecutorRequest $request -Timestamp $timestamp | Out-Null } -Pattern 'must be ready|already has' -Message 'Started builder must reject already started item.'
$completed = Apply-CommandSessionEvent -CommandSession $running -Event (New-SessionEvent -Id 'manual-result' -Type 'automation-result' -Target 'source.validate' -Payload ([pscustomobject]@{ result = [pscustomobject]@{ status = 'completed'; diagnostic = '' } }))
Assert-ThrowsLike -Script { Build-AutomationStartedEvent -CommandSession $completed -ExecutorRequest $request -Timestamp $timestamp | Out-Null } -Pattern 'current item|must be ready|already' -Message 'Started builder must reject completed item.'
$cancelled = Apply-CommandSessionEvent -CommandSession $session -Event (New-SessionEvent -Id 'cancel-start-test' -Type 'session-cancelled' -Target '' -Payload $null)
Assert-ThrowsLike -Script { Build-AutomationStartedEvent -CommandSession $cancelled -ExecutorRequest $request -Timestamp $timestamp | Out-Null } -Pattern 'terminal session|cancelled' -Message 'Started builder must reject cancelled session.'

$completedResult = [pscustomobject]@{
    schemaVersion = '0.1'
    executorResultType = 'deployment-executor-result'
    status = 'completed'
    sessionId = [string] $request.sessionId
    itemId = 'source.validate'
    commandId = 'source.validate'
    operationType = 'source.validate'
    exitStatus = 0
    stdout = 'token=must-stay-out'
    stderr = '.env must stay out'
    diagnostic = ''
    artifacts = @()
}
$failedResult = Copy-TestObject -Value $completedResult
$failedResult.status = 'failed'
$failedResult.exitStatus = 1
$failedResult.diagnostic = 'Operation failed.'
$rejectedResult = Copy-TestObject -Value $completedResult
$rejectedResult.status = 'rejected'
$rejectedResult.exitStatus = 1
$rejectedResult.diagnostic = 'Operation rejected.'

$resultBefore = $completedResult | ConvertTo-Json -Depth 100
$resultEvent = Build-AutomationResultEvent -CommandSession $running -ExecutorRequest $request -ExecutorResult $completedResult -Timestamp '2026-07-27T12:00:01Z'
Assert-Equal $resultEvent.eventType 'automation-result' 'Result builder must create automation-result event.'
Assert-Equal $resultEvent.targetItemId 'source.validate' 'Result event target must match request item.'
Assert-Equal $resultEvent.result.status 'completed' 'Completed executor result must produce successful session result.'
Assert-Equal $resultEvent.result.resultStatus 'completed' 'Completed executor status must be preserved as resultStatus.'
Assert-Equal $resultEvent.result.exitStatus 0 'Result event must preserve exitStatus.'
Assert-Equal (($resultEvent | ConvertTo-Json -Depth 100) -match 'token=|\\.env') $false 'Result event must not copy stdout or stderr secret-like content.'
Assert-Equal ($completedResult | ConvertTo-Json -Depth 100) $resultBefore 'Result builder must not mutate executor result input.'
Assert-Equal (Build-AutomationResultEvent -CommandSession $running -ExecutorRequest $request -ExecutorResult $completedResult -Timestamp '2026-07-27T12:00:01Z' | ConvertTo-Json -Depth 100) ($resultEvent | ConvertTo-Json -Depth 100) 'Result event output must be deterministic.'
$sessionResult = Copy-TestObject -Value $completedResult
$sessionResult.sessionId = [string] $request.sessionId
Assert-Equal (Build-AutomationResultEvent -CommandSession $running -ExecutorRequest $request -ExecutorResult $sessionResult -Timestamp '2026-07-27T12:00:01Z').sessionId ([string] $session.sessionId) 'Matching Session-ID in session, request and result must create event.'
$missingResultSessionId = Copy-TestObject -Value $completedResult
$missingResultSessionId.PSObject.Properties.Remove('sessionId')
Assert-ThrowsLike -Script { Build-AutomationResultEvent -CommandSession $running -ExecutorRequest $request -ExecutorResult $missingResultSessionId -Timestamp '2026-07-27T12:00:01Z' | Out-Null } -Pattern 'sessionId' -Message 'Result without sessionId must be rejected.'
$nullResultSessionId = Copy-TestObject -Value $completedResult
$nullResultSessionId.sessionId = $null
Assert-ThrowsLike -Script { Build-AutomationResultEvent -CommandSession $running -ExecutorRequest $request -ExecutorResult $nullResultSessionId -Timestamp '2026-07-27T12:00:01Z' | Out-Null } -Pattern 'sessionId' -Message 'Result with null sessionId must be rejected.'
$emptyResultSessionId = Copy-TestObject -Value $completedResult
$emptyResultSessionId.sessionId = ''
Assert-ThrowsLike -Script { Build-AutomationResultEvent -CommandSession $running -ExecutorRequest $request -ExecutorResult $emptyResultSessionId -Timestamp '2026-07-27T12:00:01Z' | Out-Null } -Pattern 'sessionId' -Message 'Result with empty sessionId must be rejected.'
$whitespaceResultSessionId = Copy-TestObject -Value $completedResult
$whitespaceResultSessionId.sessionId = '   '
Assert-ThrowsLike -Script { Build-AutomationResultEvent -CommandSession $running -ExecutorRequest $request -ExecutorResult $whitespaceResultSessionId -Timestamp '2026-07-27T12:00:01Z' | Out-Null } -Pattern 'sessionId' -Message 'Result with whitespace sessionId must be rejected.'
$foreignResultSessionId = Copy-TestObject -Value $completedResult
$foreignResultSessionId.sessionId = 'session-foreign-result'
Assert-ThrowsLike -Script { Build-AutomationResultEvent -CommandSession $running -ExecutorRequest $request -ExecutorResult $foreignResultSessionId -Timestamp '2026-07-27T12:00:01Z' | Out-Null } -Pattern 'Session-ID|sessionId' -Message 'Result with different sessionId than request must be rejected.'
$foreignSession = Copy-TestObject -Value $running
$foreignSession.sessionId = 'session-foreign-session'
Assert-ThrowsLike -Script { Build-AutomationResultEvent -CommandSession $foreignSession -ExecutorRequest $request -ExecutorResult $completedResult -Timestamp '2026-07-27T12:00:01Z' | Out-Null } -Pattern 'Session-ID|sessionId' -Message 'Result with different sessionId than command session must be rejected.'
$foreignButMatchingIds = Copy-TestObject -Value $completedResult
$foreignButMatchingIds.sessionId = 'session-B'
Assert-ThrowsLike -Script { Build-AutomationResultEvent -CommandSession $running -ExecutorRequest $request -ExecutorResult $foreignButMatchingIds -Timestamp '2026-07-27T12:00:01Z' | Out-Null } -Pattern 'Session-ID|sessionId' -Message 'Foreign session result must be rejected even when item, command and operation match.'
$failedEvent = Build-AutomationResultEvent -CommandSession $running -ExecutorRequest $request -ExecutorResult $failedResult -Timestamp '2026-07-27T12:00:01Z'
Assert-Equal $failedEvent.result.status 'failed' 'Failed executor result must produce failed session result.'
Assert-Equal $failedEvent.result.resultStatus 'failed' 'Failed executor status must be preserved.'
$rejectedEvent = Build-AutomationResultEvent -CommandSession $running -ExecutorRequest $request -ExecutorResult $rejectedResult -Timestamp '2026-07-27T12:00:01Z'
Assert-Equal $rejectedEvent.result.status 'failed' 'Rejected executor result must map to failed session result.'
Assert-Equal $rejectedEvent.result.resultStatus 'rejected' 'Rejected executor status must remain distinguishable.'

Assert-ThrowsLike -Script { Build-AutomationResultEvent -CommandSession $session -ExecutorRequest $request -ExecutorResult $completedResult -Timestamp '2026-07-27T12:00:01Z' | Out-Null } -Pattern 'running|automation-started' -Message 'Result builder must reject missing started event.'
$afterResult = Apply-CommandSessionEvent -CommandSession $running -Event $resultEvent
Assert-ThrowsLike -Script { Build-AutomationResultEvent -CommandSession $afterResult -ExecutorRequest $request -ExecutorResult $completedResult -Timestamp '2026-07-27T12:00:02Z' | Out-Null } -Pattern 'terminal session|automation-result|running' -Message 'Result builder must reject duplicate result.'
$wrongResultId = Copy-TestObject -Value $completedResult
$wrongResultId.itemId = 'archive.create'
Assert-ThrowsLike -Script { Build-AutomationResultEvent -CommandSession $running -ExecutorRequest $request -ExecutorResult $wrongResultId -Timestamp '2026-07-27T12:00:01Z' | Out-Null } -Pattern 'itemId' -Message 'Result builder must reject wrong itemId.'
$wrongResultCommand = Copy-TestObject -Value $completedResult
$wrongResultCommand.commandId = 'archive.create'
Assert-ThrowsLike -Script { Build-AutomationResultEvent -CommandSession $running -ExecutorRequest $request -ExecutorResult $wrongResultCommand -Timestamp '2026-07-27T12:00:01Z' | Out-Null } -Pattern 'commandId' -Message 'Result builder must reject wrong commandId.'
$wrongOperation = Copy-TestObject -Value $completedResult
$wrongOperation.operationType = 'archive.create'
Assert-ThrowsLike -Script { Build-AutomationResultEvent -CommandSession $running -ExecutorRequest $request -ExecutorResult $wrongOperation -Timestamp '2026-07-27T12:00:01Z' | Out-Null } -Pattern 'operationType' -Message 'Result builder must reject changed operationType.'
$cancelWhileRunning = Apply-CommandSessionEvent -CommandSession $running -Event (New-SessionEvent -Id 'cancel-result-test' -Type 'session-cancelled' -Target '' -Payload $null)
Assert-ThrowsLike -Script { Build-AutomationResultEvent -CommandSession $cancelWhileRunning -ExecutorRequest $request -ExecutorResult $completedResult -Timestamp '2026-07-27T12:00:01Z' | Out-Null } -Pattern 'terminal session|cancelled' -Message 'Result builder must reject event after cancellation.'
$artifactResult = Copy-TestObject -Value $completedResult
$artifactResult.artifacts = @([pscustomobject]@{ type = 'zip'; path = 'D:\Artifacts\deployment.zip' })
$artifactEvent = Build-AutomationResultEvent -CommandSession $running -ExecutorRequest $request -ExecutorResult $artifactResult -Timestamp '2026-07-27T12:00:01Z'
Assert-Equal @($artifactEvent.result.artifacts).Count 1 'Result event must keep structured artifacts.'
Assert-Equal $artifactEvent.result.artifacts[0].type 'zip' 'Artifact type must be preserved.'
Assert-Equal $artifactEvent.result.artifacts[0].path 'D:\Artifacts\deployment.zip' 'Artifact path must be preserved.'

$tmp = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('automation-event-builder-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    $source = Join-Path -Path $tmp -ChildPath 'source'
    New-Item -ItemType Directory -Path $source | Out-Null
    Set-Content -LiteralPath (Join-Path -Path $source -ChildPath 'index.php') -Value 'hello' -Encoding UTF8
    $artifact = Join-Path -Path $tmp -ChildPath 'artifacts/deployment.zip'
    $realPlan = New-TestCommandPlan -SourcePath $source -ArtifactPath $artifact
    $realSession = New-CommandSession -CommandPlan $realPlan
    $realRequest = New-TestRequest -Plan $realPlan -Session $realSession
    $realStarted = Build-AutomationStartedEvent -CommandSession $realSession -ExecutorRequest $realRequest -Timestamp '2026-07-27T12:00:00Z'
    $realRunning = Apply-CommandSessionEvent -CommandSession $realSession -Event $realStarted
    $realExecutorResult = Invoke-LocalOperationRequest -ExecutorRequest $realRequest
    $realResultEvent = Build-AutomationResultEvent -CommandSession $realRunning -ExecutorRequest $realRequest -ExecutorResult $realExecutorResult -Timestamp '2026-07-27T12:00:01Z'
    $realCompleted = Apply-CommandSessionEvent -CommandSession $realRunning -Event $realResultEvent
    Assert-Equal $realCompleted.items[0].status 'completed' 'Source validation happy path must complete the item.'
    Assert-Equal @($realCompleted.eventHistory | Where-Object { $_.eventType -in @('automation-started', 'automation-result') }).Count 2 'Source validation history must contain start and result.'
    $nextAdmission = Resolve-ExecutionAdmission -CommandPlan $realPlan -CommandSession $realCompleted
    Assert-Equal $nextAdmission.currentItemId 'archive.create' 'Admission after source validation must select the next automation item.'

    $rejectPlan = New-TestCommandPlan -SourcePath $source -ArtifactPath $artifact
    $rejectSession = New-CommandSession -CommandPlan $rejectPlan
    $rejectRequest = New-TestRequest -Plan $rejectPlan -Session $rejectSession
    $rejectRequest.operation.sourcePath = Join-Path -Path $tmp -ChildPath 'missing'
    $rejectStarted = Build-AutomationStartedEvent -CommandSession $rejectSession -ExecutorRequest $rejectRequest -Timestamp '2026-07-27T12:00:00Z'
    $rejectRunning = Apply-CommandSessionEvent -CommandSession $rejectSession -Event $rejectStarted
    $rejectExecutorResult = Invoke-LocalOperationRequest -ExecutorRequest $rejectRequest
    $rejectResultEvent = Build-AutomationResultEvent -CommandSession $rejectRunning -ExecutorRequest $rejectRequest -ExecutorResult $rejectExecutorResult -Timestamp '2026-07-27T12:00:01Z'
    $rejectFailed = Apply-CommandSessionEvent -CommandSession $rejectRunning -Event $rejectResultEvent
    Assert-Equal $rejectExecutorResult.status 'rejected' 'Missing source path must be rejected by local operation executor.'
    Assert-Equal $rejectFailed.items[0].status 'failed' 'Rejected source validation must become a failed session item.'
    Assert-Equal $rejectFailed.items[0].feedback.resultStatus 'rejected' 'Rejected executor result must remain visible in item feedback.'

    $archivePlan = New-TestCommandPlan -SourcePath $source -ArtifactPath $artifact
    $archiveSession = New-CommandSession -CommandPlan $archivePlan
    $archiveSourceRequest = New-TestRequest -Plan $archivePlan -Session $archiveSession
    $archiveSourceCompleted = Complete-AutomationWithBuilder -Session $archiveSession -Request $archiveSourceRequest -Result (Invoke-LocalOperationRequest -ExecutorRequest $archiveSourceRequest)
    $archiveRequest = New-TestRequest -Plan $archivePlan -Session $archiveSourceCompleted
    $archiveStarted = Build-AutomationStartedEvent -CommandSession $archiveSourceCompleted -ExecutorRequest $archiveRequest -Timestamp '2026-07-27T12:00:02Z'
    $archiveRunning = Apply-CommandSessionEvent -CommandSession $archiveSourceCompleted -Event $archiveStarted
    $archiveExecutorResult = Invoke-LocalOperationRequest -ExecutorRequest $archiveRequest
    $archiveResultEvent = Build-AutomationResultEvent -CommandSession $archiveRunning -ExecutorRequest $archiveRequest -ExecutorResult $archiveExecutorResult -Timestamp '2026-07-27T12:00:03Z'
    $archiveCompleted = Apply-CommandSessionEvent -CommandSession $archiveRunning -Event $archiveResultEvent
    Assert-Equal $archiveExecutorResult.status 'completed' 'Archive creation happy path must complete.'
    Assert-True (Test-Path -LiteralPath $artifact -PathType Leaf) 'Archive creation must create the artifact in temp.'
    Assert-Equal $archiveCompleted.items[1].status 'completed' 'Archive event must be accepted by command session.'
    Assert-Equal @($archiveCompleted.items[1].feedback.artifacts).Count 1 'Archive feedback must contain artifact data.'

    $sessionPathInput = Join-Path -Path $tmp -ChildPath 'command-session.json'
    $requestPathInput = Join-Path -Path $tmp -ChildPath 'executor-request.json'
    $resultPathInput = Join-Path -Path $tmp -ChildPath 'executor-result.json'
    $startedOutput = Join-Path -Path $tmp -ChildPath 'events/automation-started.json'
    $resultOutput = Join-Path -Path $tmp -ChildPath 'events/automation-result.json'
    $realSession | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $sessionPathInput -Encoding UTF8
    $realRequest | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $requestPathInput -Encoding UTF8
    $realExecutorResult | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $resultPathInput -Encoding UTF8
    $fileCountBeforeStdout = @(Get-ChildItem -LiteralPath $tmp -File -Recurse).Count
    $stdoutStarted = & $cliPath build-automation-started-event -CommandSessionPath $sessionPathInput -ExecutorRequestPath $requestPathInput -Timestamp '2026-07-27T12:00:00Z' -Format Json
    $fileCountAfterStdout = @(Get-ChildItem -LiteralPath $tmp -File -Recurse).Count
    Assert-Equal ($stdoutStarted | ConvertFrom-Json).eventType 'automation-started' 'Started CLI without OutputPath must emit parseable JSON.'
    Assert-Equal @($stdoutStarted).Count 1 'Started CLI without OutputPath must not emit additional stdout lines.'
    Assert-Equal $fileCountAfterStdout $fileCountBeforeStdout 'Started CLI without OutputPath must not create files.'
    & $cliPath build-automation-started-event -CommandSessionPath $sessionPathInput -ExecutorRequestPath $requestPathInput -Timestamp '2026-07-27T12:00:00Z' -OutputPath $startedOutput -Format Json | Out-Null
    Assert-True (Test-Path -LiteralPath $startedOutput -PathType Leaf) 'Started CLI with OutputPath must write the explicit output file.'
    $runningForCli = Apply-CommandSessionEvent -CommandSession $realSession -Event ($stdoutStarted | ConvertFrom-Json)
    $runningForCli | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $sessionPathInput -Encoding UTF8
    $stdoutResult = & $cliPath build-automation-result-event -CommandSessionPath $sessionPathInput -ExecutorRequestPath $requestPathInput -ExecutorResultPath $resultPathInput -Timestamp '2026-07-27T12:00:01Z' -Format Json
    Assert-Equal ($stdoutResult | ConvertFrom-Json).eventType 'automation-result' 'Result CLI without OutputPath must emit parseable JSON.'
    & $cliPath build-automation-result-event -CommandSessionPath $sessionPathInput -ExecutorRequestPath $requestPathInput -ExecutorResultPath $resultPathInput -Timestamp '2026-07-27T12:00:01Z' -OutputPath $resultOutput -Format Json | Out-Null
    Assert-True (Test-Path -LiteralPath $resultOutput -PathType Leaf) 'Result CLI with OutputPath must write the explicit output file.'
} finally {
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
}

$sourceText = Get-Content -LiteralPath $eventBuilderPath -Raw
foreach ($forbidden in @('Start-Process', 'Invoke-Expression', 'System.Diagnostics.Process', 'ProcessStartInfo', 'Invoke-Command', 'New-PSSession', 'ssh.exe', 'scp.exe', 'Get-Date')) {
    Assert-True (-not ($sourceText -match [regex]::Escape($forbidden))) "Automation event builder source must not contain forbidden token '$forbidden'."
}
foreach ($forbiddenCall in @('Apply-CommandSession' + 'Event', 'Invoke-LocalOperation' + 'Request')) {
    Assert-True (-not ($sourceText -match [regex]::Escape($forbiddenCall))) "Automation event builder source must not contain forbidden call '$forbiddenCall'."
}

if ($script:failures.Count -gt 0) {
    Write-Host 'Automation Event Builder tests failed:'
    $script:failures | ForEach-Object { Write-Host "- $_" }
    exit 1
}

Write-Host 'Automation Event Builder tests passed.'
exit 0
