[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:failures = New-Object System.Collections.Generic.List[string]
$engineRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '..'))
$admissionPath = Join-Path -Path $engineRoot -ChildPath 'src/ps1/Evaluate-ExecutionAdmission.ps1'
$sessionPath = Join-Path -Path $engineRoot -ChildPath 'src/ps1/CommandSession.ps1'
$cliPath = Join-Path -Path $engineRoot -ChildPath 'bin/deployment-engine.ps1'

. $sessionPath
. $admissionPath

function Assert-True { param([bool] $Condition, [string] $Message) if (-not $Condition) { $script:failures.Add($Message) } }
function Assert-Equal { param($Actual, $Expected, [string] $Message) if ($Actual -ne $Expected) { $script:failures.Add("$Message Expected '$Expected', got '$Actual'.") } }
function Assert-ThrowsLike {
    param([scriptblock] $Script, [string] $Pattern, [string] $Message)
    try { & $Script; $script:failures.Add($Message) } catch { Assert-True ($_.Exception.Message -match $Pattern) "$Message Actual error: $($_.Exception.Message)" }
}

function New-TestCommand {
    param(
        [Parameter(Mandatory = $true)][string] $Id,
        [Parameter(Mandatory = $true)][int] $Sequence,
        [Parameter(Mandatory = $true)][string] $Actor,
        [Parameter(Mandatory = $true)][string] $Location,
        [Parameter(Mandatory = $true)][string] $Mode,
        [Parameter(Mandatory = $true)][string] $Program,
        [string[]] $DependsOn = @(),
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
        arguments = @()
        workingDirectory = ''
        environment = [pscustomobject]@{}
        renderedCommand = $RenderedCommand
        display = [pscustomobject]@{ title = $Id; description = ''; copyable = ($Actor -eq 'human-command') }
        feedback = [pscustomobject]@{ required = ($Actor -eq 'human-command'); expectedData = if ($Actor -eq 'human-command') { @('exitStatus', 'stdout', 'stderr') } else { @() } }
        safety = [pscustomobject]@{ destructive = $false; containsSecret = $false; requiresApproval = $false; executionPermitted = $false }
        diagnostic = ''
    }
}

function New-TestCommandPlan {
    return [pscustomobject]@{
        schemaVersion = '0.1'
        commandPlanType = 'deployment-command-plan'
        status = 'ready'
        sourceStrategyType = 'deployment'
        selectedAdapterId = 'archive.zip'
        executionPolicy = [pscustomobject]@{ executionAllowed = $false; automaticExecutionAllowed = $false; remoteExecutionMode = 'copy-and-run' }
        commands = @(
            New-TestCommand -Id 'source.validate' -Sequence 100 -Actor 'automation' -Location 'local' -Mode 'automatic' -Program 'local-operation'
            New-TestCommand -Id 'archive.create' -Sequence 300 -Actor 'automation' -Location 'local' -Mode 'automatic' -Program 'local-operation' -DependsOn @('source.validate')
            New-TestCommand -Id 'artifact.upload' -Sequence 600 -Actor 'human-command' -Location 'artifact-transport' -Mode 'copy-and-run' -Program 'network-share' -DependsOn @('deployment.approval') -RenderedCommand 'Copy-Item -LiteralPath artifact.zip -Destination D:\\Share\\.deployment\\uploads\\artifact.zip'
            New-TestCommand -Id 'remote.archive.extract' -Sequence 700 -Actor 'human-command' -Location 'remote' -Mode 'copy-and-run' -Program 'interactive-ssh' -DependsOn @('artifact.upload') -RenderedCommand 'unzip -oq /absolute/.deployment/uploads/artifact.zip -d /absolute/.deployment/work/current'
            New-TestCommand -Id 'deployment.verify' -Sequence 900 -Actor 'review' -Location 'review' -Mode 'none' -Program 'local-operation' -DependsOn @('remote.archive.extract')
        )
        humanGates = @(
            [pscustomobject]@{ gateId = 'deployment.approval'; stepId = 'deployment.approval'; sequence = 400; dependsOn = @('archive.create'); gateType = 'approval'; blocksContinuation = $true; allowedResponses = @('approved', 'rejected') }
        )
        diagnostic = ''
    }
}

function New-Event {
    param([string] $Id, [string] $Type, [string] $Target, [object] $Payload)
    $event = [pscustomobject]@{ schemaVersion = '0.1'; eventId = $Id; eventType = $Type; targetItemId = $Target }
    if ($null -ne $Payload) {
        foreach ($property in $Payload.PSObject.Properties) {
            Add-Member -InputObject $event -MemberType NoteProperty -Name $property.Name -Value $property.Value
        }
    }
    return $event
}

function Get-ItemById {
    param([object] $Session, [string] $ItemId)
    return @($Session.items | Where-Object { $_.itemId -eq $ItemId } | Select-Object -First 1)[0]
}

function Complete-Automation {
    param([object] $Session, [string] $ItemId, [string] $Prefix)
    $started = Apply-CommandSessionEvent -CommandSession $Session -Event (New-Event -Id "$Prefix-start" -Type 'automation-started' -Target $ItemId -Payload $null)
    return Apply-CommandSessionEvent -CommandSession $started -Event (New-Event -Id "$Prefix-result" -Type 'automation-result' -Target $ItemId -Payload ([pscustomobject]@{ result = [pscustomobject]@{ status = 'completed'; diagnostic = '' } }))
}

function Assert-Inconsistent {
    param([object] $CommandPlan, [object] $CommandSession, [string] $Message)
    $result = Resolve-ExecutionAdmission -CommandPlan $CommandPlan -CommandSession $CommandSession
    Assert-Equal $result.status 'inconsistent' $Message
    Assert-Equal $result.decision.executionEligible $false "$Message Inconsistent admission must not be eligible."
}

function New-HistoryEvent {
    param([string] $Id, [string] $Type, [string] $Target = '', [string] $ResultingStatus = '', [object] $Payload)
    $event = [pscustomobject]@{ eventId = $Id; eventType = $Type }
    if (-not [string]::IsNullOrWhiteSpace($Target)) { Add-Member -InputObject $event -MemberType NoteProperty -Name 'targetItemId' -Value $Target }
    if (-not [string]::IsNullOrWhiteSpace($ResultingStatus)) { Add-Member -InputObject $event -MemberType NoteProperty -Name 'resultingStatus' -Value $ResultingStatus }
    if ($null -ne $Payload) {
        foreach ($property in $Payload.PSObject.Properties) {
            Add-Member -InputObject $event -MemberType NoteProperty -Name $property.Name -Value $property.Value
        }
    }
    return $event
}

$plan = New-TestCommandPlan
$session = New-CommandSession -CommandPlan $plan
$sourceStarted = Apply-CommandSessionEvent -CommandSession $session -Event (New-Event -Id 'source-started-fixture' -Type 'automation-started' -Target 'source.validate' -Payload $null)
$planBefore = $plan | ConvertTo-Json -Depth 80
$sessionBefore = $session | ConvertTo-Json -Depth 80
$admission = Resolve-ExecutionAdmission -CommandPlan $plan -CommandSession $session
Assert-Equal $admission.admissionType 'execution-admission' 'Admission type must be correct.'
Assert-Equal $admission.status 'eligible-but-disabled' 'Ready local automation must be eligible but disabled.'
Assert-Equal $admission.decision.executionEligible $true 'Ready local automation must be execution-eligible.'
Assert-Equal $admission.decision.executionAdmitted $false 'Admission must not allow execution in this milestone.'
Assert-Equal $admission.handoff.type 'local-executor' 'Local automation handoff must target later local executor.'
Assert-Equal $admission.handoff.eventOnStart 'automation-started' 'Local automation handoff must declare start event.'
Assert-Equal $admission.handoff.eventOnResult 'automation-result' 'Local automation handoff must declare result event.'
Assert-Equal $admission.executionPolicy.productiveExecutionAllowed $false 'Productive execution must remain disabled.'
Assert-Equal $admission.executionPolicy.processStartAllowed $false 'Process start must remain disabled.'
Assert-Equal $admission.executionPolicy.networkAccessAllowed $false 'Network access must remain disabled.'
Assert-Equal $admission.executionPolicy.remoteExecutionAllowed $false 'Remote execution must remain disabled.'
Assert-Equal ($plan | ConvertTo-Json -Depth 80) $planBefore 'Admission must not mutate command plan input.'
Assert-Equal ($session | ConvertTo-Json -Depth 80) $sessionBefore 'Admission must not mutate command session input.'
$admission.decision.executionEligible = $false
Assert-Equal (Resolve-ExecutionAdmission -CommandPlan $plan -CommandSession $session).decision.executionEligible $true 'Admission output must not share mutable references with inputs.'

$pendingSession = Copy-ExecutionAdmissionObject -Value $session
$pendingSession.currentItemId = 'archive.create'
$pendingAdmission = Resolve-ExecutionAdmission -CommandPlan $plan -CommandSession $pendingSession
Assert-Equal $pendingAdmission.status 'not-ready' 'Pending current item must not be admitted.'
Assert-Equal $pendingAdmission.decision.executionEligible $false 'Pending current item must not be eligible.'

$openDependency = Complete-Automation -Session $session -ItemId 'source.validate' -Prefix 'open-source'
$openDependency.currentItemId = 'deployment.approval'
$openDependencyAdmission = Resolve-ExecutionAdmission -CommandPlan $plan -CommandSession $openDependency
Assert-Equal $openDependencyAdmission.status 'not-ready' 'Current item with open dependency must be not-ready.'

$unknownCurrent = Copy-ExecutionAdmissionObject -Value $session
$unknownCurrent.currentItemId = 'missing'
Assert-ThrowsLike -Script { Resolve-ExecutionAdmission -CommandPlan $plan -CommandSession $unknownCurrent | Out-Null } -Pattern "currentItemId 'missing' does not reference an item" -Message 'Unknown current item must be rejected.'

$approvalSession = Complete-Automation -Session (Complete-Automation -Session $session -ItemId 'source.validate' -Prefix 'approval-source') -ItemId 'archive.create' -Prefix 'approval-archive'
$approvalAdmission = Resolve-ExecutionAdmission -CommandPlan $plan -CommandSession $approvalSession
Assert-Equal $approvalAdmission.status 'requires-human' 'Approval gate must require a human.'
Assert-Equal $approvalAdmission.handoff.type 'human-decision' 'Approval gate handoff must target human decision.'
Assert-Equal $approvalAdmission.handoff.eventOnSubmit 'human-decision-submitted' 'Approval gate must declare decision event.'
Assert-Equal $approvalAdmission.decision.executionAdmitted $false 'Admission must not auto-approve human decisions.'

$afterApproval = Apply-CommandSessionEvent -CommandSession $approvalSession -Event (New-Event -Id 'approval-event' -Type 'human-decision-submitted' -Target 'deployment.approval' -Payload ([pscustomobject]@{ decision = [pscustomobject]@{ value = 'approved' } }))
$humanUploadAdmission = Resolve-ExecutionAdmission -CommandPlan $plan -CommandSession $afterApproval
Assert-Equal $humanUploadAdmission.status 'requires-human' 'SCP human command must require human handling.'
Assert-Equal $humanUploadAdmission.handoff.type 'human-command' 'Human command handoff must be declared.'
Assert-Equal $humanUploadAdmission.handoff.eventOnStart 'human-command-started' 'Human command handoff must declare start event.'
Assert-Equal $humanUploadAdmission.handoff.eventOnResult 'human-command-result' 'Human command handoff must declare result event.'
Assert-Equal $humanUploadAdmission.handoff.RenderedCommand 'Copy-Item -LiteralPath artifact.zip -Destination D:\\Share\\.deployment\\uploads\\artifact.zip' 'Rendered command must be carried, not regenerated.'

$uploadStarted = Apply-CommandSessionEvent -CommandSession $afterApproval -Event (New-Event -Id 'upload-start' -Type 'human-command-started' -Target 'artifact.upload' -Payload $null)
$afterUpload = Apply-CommandSessionEvent -CommandSession $uploadStarted -Event (New-Event -Id 'upload-result' -Type 'human-command-result' -Target 'artifact.upload' -Payload ([pscustomobject]@{ result = [pscustomobject]@{ exitStatus = 0; stdout = 'ok'; stderr = '' } }))
$humanExtractAdmission = Resolve-ExecutionAdmission -CommandPlan $plan -CommandSession $afterUpload
Assert-Equal $humanExtractAdmission.status 'requires-human' 'SSH human command must require human handling.'
Assert-Equal $humanExtractAdmission.handoff.RenderedCommand 'unzip -oq /absolute/.deployment/uploads/artifact.zip -d /absolute/.deployment/work/current' 'SSH command text must only be referenced.'

$extractStarted = Apply-CommandSessionEvent -CommandSession $afterUpload -Event (New-Event -Id 'extract-start' -Type 'human-command-started' -Target 'remote.archive.extract' -Payload $null)
$afterExtract = Apply-CommandSessionEvent -CommandSession $extractStarted -Event (New-Event -Id 'extract-result' -Type 'human-command-result' -Target 'remote.archive.extract' -Payload ([pscustomobject]@{ result = [pscustomobject]@{ exitStatus = 0; stdout = 'ok'; stderr = '' } }))
$reviewAdmission = Resolve-ExecutionAdmission -CommandPlan $plan -CommandSession $afterExtract
Assert-Equal $reviewAdmission.status 'requires-review' 'Review item must require review.'
Assert-Equal $reviewAdmission.handoff.type 'review' 'Review handoff must be declared.'
Assert-Equal $reviewAdmission.handoff.eventOnSubmit 'review-result' 'Review handoff must declare review result event.'

$completedSession = Apply-CommandSessionEvent -CommandSession $afterExtract -Event (New-Event -Id 'review-ok' -Type 'review-result' -Target 'deployment.verify' -Payload ([pscustomobject]@{ review = [pscustomobject]@{ status = 'approved'; diagnostic = '' } }))
Assert-Equal (Resolve-ExecutionAdmission -CommandPlan $plan -CommandSession $completedSession).status 'completed' 'Completed session must report completed.'
$failedSession = Apply-CommandSessionEvent -CommandSession $uploadStarted -Event (New-Event -Id 'upload-fail' -Type 'human-command-result' -Target 'artifact.upload' -Payload ([pscustomobject]@{ result = [pscustomobject]@{ exitStatus = 1; stdout = ''; stderr = 'failed' } }))
Assert-Equal (Resolve-ExecutionAdmission -CommandPlan $plan -CommandSession $failedSession).status 'failed' 'Failed session must report failed.'
$cancelledSession = Apply-CommandSessionEvent -CommandSession $session -Event ([pscustomobject]@{ schemaVersion = '0.1'; eventId = 'cancel-event'; eventType = 'session-cancelled' })
Assert-Equal (Resolve-ExecutionAdmission -CommandPlan $plan -CommandSession $cancelledSession).status 'cancelled' 'Cancelled session must report cancelled.'
$cancelledWithFakeAutomationCompletion = Copy-ExecutionAdmissionObject -Value $cancelledSession
(Get-ItemById -Session $cancelledWithFakeAutomationCompletion -ItemId 'source.validate').status = 'completed'
Assert-ThrowsLike -Script { Resolve-ExecutionAdmission -CommandPlan $plan -CommandSession $cancelledWithFakeAutomationCompletion | Out-Null } -Pattern 'completed automation item requires successful automation-result' -Message 'Cancelled session must still reject completed automation without start/result history.'
$cancelledWithFakeHumanCompletion = Copy-ExecutionAdmissionObject -Value $cancelledSession
(Get-ItemById -Session $cancelledWithFakeHumanCompletion -ItemId 'artifact.upload').status = 'completed'
Assert-ThrowsLike -Script { Resolve-ExecutionAdmission -CommandPlan $plan -CommandSession $cancelledWithFakeHumanCompletion | Out-Null } -Pattern 'completed human-command item requires exitStatus 0' -Message 'Cancelled session must still reject completed human command without start/result history.'
$cancelledAfterCompletedAutomation = Apply-CommandSessionEvent -CommandSession (Complete-Automation -Session $session -ItemId 'source.validate' -Prefix 'cancel-after-completed-source') -Event ([pscustomobject]@{ schemaVersion = '0.1'; eventId = 'cancel-after-completed'; eventType = 'session-cancelled' })
Assert-Equal (Resolve-ExecutionAdmission -CommandPlan $plan -CommandSession $cancelledAfterCompletedAutomation).status 'cancelled' 'Cancelled session with previously valid completed item must remain valid.'
$blockedSession = Copy-ExecutionAdmissionObject -Value $session
$blockedSession.status = 'blocked'
$blockedSession.currentItemId = ''
Assert-Equal (Resolve-ExecutionAdmission -CommandPlan $plan -CommandSession $blockedSession).status 'blocked' 'Blocked session must report blocked.'

$actorMismatch = Copy-ExecutionAdmissionObject -Value $session
(Get-ItemById -Session $actorMismatch -ItemId 'source.validate').actor = 'human-command'
Assert-Equal (Resolve-ExecutionAdmission -CommandPlan $plan -CommandSession $actorMismatch).status 'inconsistent' 'Actor mismatch must be inconsistent.'
$sequenceMismatch = Copy-ExecutionAdmissionObject -Value $session
(Get-ItemById -Session $sequenceMismatch -ItemId 'source.validate').sequence = 101
Assert-Equal (Resolve-ExecutionAdmission -CommandPlan $plan -CommandSession $sequenceMismatch).status 'inconsistent' 'Sequence mismatch must be inconsistent.'
$dependencyMismatch = Copy-ExecutionAdmissionObject -Value $afterApproval
(Get-ItemById -Session $dependencyMismatch -ItemId 'artifact.upload').dependsOn = @('archive.create')
Assert-Equal (Resolve-ExecutionAdmission -CommandPlan $plan -CommandSession $dependencyMismatch).status 'inconsistent' 'Dependency mismatch must be inconsistent.'
$missingCommandId = Copy-ExecutionAdmissionObject -Value $session
(Get-ItemById -Session $missingCommandId -ItemId 'source.validate').commandId = 'missing'
Assert-Equal (Resolve-ExecutionAdmission -CommandPlan $plan -CommandSession $missingCommandId).status 'inconsistent' 'Missing command id must be inconsistent.'
$modeMismatch = Copy-ExecutionAdmissionObject -Value $session
(Get-ItemById -Session $modeMismatch -ItemId 'source.validate').executionMode = 'none'
Assert-Equal (Resolve-ExecutionAdmission -CommandPlan $plan -CommandSession $modeMismatch).status 'inconsistent' 'Execution mode mismatch must be inconsistent.'
$planAllowsExecution = Copy-ExecutionAdmissionObject -Value $plan
$planAllowsExecution.executionPolicy.executionAllowed = $true
Assert-ThrowsLike -Script { Resolve-ExecutionAdmission -CommandPlan $planAllowsExecution -CommandSession $session | Out-Null } -Pattern 'execution must remain disabled' -Message 'Command plan executionAllowed true must be rejected.'
$commandPermitsExecution = Copy-ExecutionAdmissionObject -Value $plan
$commandPermitsExecution.commands[0].safety.executionPermitted = $true
Assert-ThrowsLike -Script { Resolve-ExecutionAdmission -CommandPlan $commandPermitsExecution -CommandSession $session | Out-Null } -Pattern 'executionPermitted must remain false' -Message 'Command executionPermitted true must be rejected.'
$remoteAutomation = Copy-ExecutionAdmissionObject -Value $plan
$remoteAutomation.commands[0].executionLocation = 'remote'
$remoteAdmission = Resolve-ExecutionAdmission -CommandPlan $remoteAutomation -CommandSession $session
Assert-Equal $remoteAdmission.status 'blocked' 'Remote automation must never be admitted in V1.'
Assert-Equal $remoteAdmission.decision.executionEligible $false 'Remote automation must not be eligible.'

$laterActorMismatch = Copy-ExecutionAdmissionObject -Value $session
(Get-ItemById -Session $laterActorMismatch -ItemId 'artifact.upload').actor = 'automation'
Assert-Inconsistent -CommandPlan $plan -CommandSession $laterActorMismatch -Message 'Actor mismatch outside currentItemId must block every admission.'
$laterSequenceMismatch = Copy-ExecutionAdmissionObject -Value $session
(Get-ItemById -Session $laterSequenceMismatch -ItemId 'artifact.upload').sequence = 601
Assert-Inconsistent -CommandPlan $plan -CommandSession $laterSequenceMismatch -Message 'Sequence mismatch outside currentItemId must block every admission.'
$laterDependencyMismatch = Copy-ExecutionAdmissionObject -Value $session
(Get-ItemById -Session $laterDependencyMismatch -ItemId 'remote.archive.extract').dependsOn = @('deployment.approval')
Assert-Inconsistent -CommandPlan $plan -CommandSession $laterDependencyMismatch -Message 'Dependency mismatch outside currentItemId must block every admission.'
$laterModeMismatch = Copy-ExecutionAdmissionObject -Value $session
(Get-ItemById -Session $laterModeMismatch -ItemId 'remote.archive.extract').executionMode = 'automatic'
Assert-Inconsistent -CommandPlan $plan -CommandSession $laterModeMismatch -Message 'Execution mode mismatch outside currentItemId must block every admission.'
$laterRenderedMismatch = Copy-ExecutionAdmissionObject -Value $session
(Get-ItemById -Session $laterRenderedMismatch -ItemId 'artifact.upload').renderedCommand = 'Copy-Item changed'
Assert-Inconsistent -CommandPlan $plan -CommandSession $laterRenderedMismatch -Message 'Rendered command mismatch outside currentItemId must block every admission.'
$laterFeedbackMismatch = Copy-ExecutionAdmissionObject -Value $session
(Get-ItemById -Session $laterFeedbackMismatch -ItemId 'artifact.upload').feedbackRequired = $false
Assert-Inconsistent -CommandPlan $plan -CommandSession $laterFeedbackMismatch -Message 'Feedback requirement mismatch outside currentItemId must block every admission.'
$missingExpectedSessionItem = Copy-ExecutionAdmissionObject -Value $session
$missingExpectedSessionItem.items = @($missingExpectedSessionItem.items | Where-Object { $_.itemId -ne 'remote.archive.extract' })
(Get-ItemById -Session $missingExpectedSessionItem -ItemId 'deployment.verify').dependsOn = @('artifact.upload')
Assert-Inconsistent -CommandPlan $plan -CommandSession $missingExpectedSessionItem -Message 'Missing expected session item must block every admission.'
$extraSessionItem = Copy-ExecutionAdmissionObject -Value $session
$extraSessionItem.items += [pscustomobject]@{ itemId = 'unexpected.item'; commandId = 'unexpected.item'; sequence = 999; actor = 'automation'; executionMode = 'automatic'; dependsOn = @(); status = 'pending'; attempt = 0; renderedCommand = ''; feedbackRequired = $false; feedback = $null; decision = $null; diagnostic = '' }
Assert-Inconsistent -CommandPlan $plan -CommandSession $extraSessionItem -Message 'Additional unknown session item must block every admission.'
$missingGateSession = Copy-ExecutionAdmissionObject -Value $session
$missingGateSession.items = @($missingGateSession.items | Where-Object { $_.itemId -ne 'deployment.approval' })
(Get-ItemById -Session $missingGateSession -ItemId 'artifact.upload').dependsOn = @('archive.create')
Assert-Inconsistent -CommandPlan $plan -CommandSession $missingGateSession -Message 'Missing human gate item must block every admission.'
$wrongGateSession = Copy-ExecutionAdmissionObject -Value $session
(Get-ItemById -Session $wrongGateSession -ItemId 'deployment.approval').gate.gateType = 'wrong'
Assert-Inconsistent -CommandPlan $plan -CommandSession $wrongGateSession -Message 'Human gate mismatch must block every admission.'

$eventUnknownTarget = Copy-ExecutionAdmissionObject -Value $session
$eventUnknownTarget.eventHistory = @(New-HistoryEvent -Id 'bad-target' -Type 'automation-started' -Target 'missing')
Assert-ThrowsLike -Script { Resolve-ExecutionAdmission -CommandPlan $plan -CommandSession $eventUnknownTarget | Out-Null } -Pattern "targets unknown item 'missing'" -Message 'Unknown event target must be rejected.'
$automationTargetsHuman = Copy-ExecutionAdmissionObject -Value $afterApproval
$automationTargetsHuman.eventHistory += New-HistoryEvent -Id 'bad-auto-human' -Type 'automation-started' -Target 'artifact.upload'
Assert-ThrowsLike -Script { Resolve-ExecutionAdmission -CommandPlan $plan -CommandSession $automationTargetsHuman | Out-Null } -Pattern "does not match actor 'human-command'" -Message 'Automation event targeting human command must be rejected.'
$humanTargetsAutomation = Copy-ExecutionAdmissionObject -Value $session
$humanTargetsAutomation.eventHistory = @(New-HistoryEvent -Id 'bad-human-auto' -Type 'human-command-started' -Target 'source.validate')
Assert-ThrowsLike -Script { Resolve-ExecutionAdmission -CommandPlan $plan -CommandSession $humanTargetsAutomation | Out-Null } -Pattern "does not match actor 'automation'" -Message 'Human command event targeting automation must be rejected.'
$reviewTargetsGate = Copy-ExecutionAdmissionObject -Value $approvalSession
$reviewTargetsGate.eventHistory += New-HistoryEvent -Id 'bad-review-gate' -Type 'review-result' -Target 'deployment.approval' -ResultingStatus 'completed'
Assert-ThrowsLike -Script { Resolve-ExecutionAdmission -CommandPlan $plan -CommandSession $reviewTargetsGate | Out-Null } -Pattern "does not match actor 'human-decision'" -Message 'Review event targeting human gate must be rejected.'
$decisionTargetsReview = Copy-ExecutionAdmissionObject -Value $afterExtract
$decisionTargetsReview.eventHistory += New-HistoryEvent -Id 'bad-decision-review' -Type 'human-decision-submitted' -Target 'deployment.verify' -ResultingStatus 'completed'
Assert-ThrowsLike -Script { Resolve-ExecutionAdmission -CommandPlan $plan -CommandSession $decisionTargetsReview | Out-Null } -Pattern "does not match actor 'review'" -Message 'Decision event targeting review must be rejected.'

$automationResultWithoutStart = Copy-ExecutionAdmissionObject -Value $session
$automationResultWithoutStart.eventHistory = @(New-HistoryEvent -Id 'auto-result-only' -Type 'automation-result' -Target 'source.validate' -ResultingStatus 'completed' -Payload ([pscustomobject]@{ result = [pscustomobject]@{ status = 'completed' } }))
Assert-ThrowsLike -Script { Resolve-ExecutionAdmission -CommandPlan $plan -CommandSession $automationResultWithoutStart | Out-Null } -Pattern 'requires a prior automation-started' -Message 'Automation result without start must be rejected.'
$humanResultWithoutStart = Copy-ExecutionAdmissionObject -Value $afterApproval
$humanResultWithoutStart.eventHistory += New-HistoryEvent -Id 'human-result-only' -Type 'human-command-result' -Target 'artifact.upload' -ResultingStatus 'completed' -Payload ([pscustomobject]@{ result = [pscustomobject]@{ exitStatus = 0; stdout = ''; stderr = '' } })
Assert-ThrowsLike -Script { Resolve-ExecutionAdmission -CommandPlan $plan -CommandSession $humanResultWithoutStart | Out-Null } -Pattern 'requires a prior human-command-started' -Message 'Human command result without start must be rejected.'
$duplicateAutomationStart = Copy-ExecutionAdmissionObject -Value $sourceStarted
$duplicateAutomationStart = Apply-CommandSessionEvent -CommandSession $session -Event (New-Event -Id 'dup-auto-start-a' -Type 'automation-started' -Target 'source.validate' -Payload $null)
$duplicateAutomationStart.eventHistory += New-HistoryEvent -Id 'dup-auto-start-b' -Type 'automation-started' -Target 'source.validate' -ResultingStatus 'running'
Assert-ThrowsLike -Script { Resolve-ExecutionAdmission -CommandPlan $plan -CommandSession $duplicateAutomationStart | Out-Null } -Pattern 'duplicate automation-started' -Message 'Duplicate automation start must be rejected.'
$duplicateHumanResult = Copy-ExecutionAdmissionObject -Value $afterUpload
$duplicateHumanResult.eventHistory += New-HistoryEvent -Id 'dup-human-result' -Type 'human-command-result' -Target 'artifact.upload' -ResultingStatus 'completed' -Payload ([pscustomobject]@{ result = [pscustomobject]@{ exitStatus = 0; stdout = ''; stderr = '' } })
Assert-ThrowsLike -Script { Resolve-ExecutionAdmission -CommandPlan $plan -CommandSession $duplicateHumanResult | Out-Null } -Pattern 'appears after terminal event' -Message 'Duplicate human result after terminal item must be rejected.'
$eventAfterCancel = Copy-ExecutionAdmissionObject -Value $cancelledSession
$eventAfterCancel.eventHistory += New-HistoryEvent -Id 'after-cancel' -Type 'automation-started' -Target 'source.validate' -ResultingStatus 'running'
Assert-ThrowsLike -Script { Resolve-ExecutionAdmission -CommandPlan $plan -CommandSession $eventAfterCancel | Out-Null } -Pattern 'appears after session-cancelled' -Message 'Event after session-cancelled must be rejected.'
$doubleCancel = Copy-ExecutionAdmissionObject -Value $cancelledSession
$doubleCancel.eventHistory += New-HistoryEvent -Id 'cancel-again' -Type 'session-cancelled'
Assert-ThrowsLike -Script { Resolve-ExecutionAdmission -CommandPlan $plan -CommandSession $doubleCancel | Out-Null } -Pattern 'appears after session-cancelled|duplicate session-cancelled' -Message 'Duplicate session-cancelled must be rejected.'

$runningWithoutStart = Copy-ExecutionAdmissionObject -Value $session
(Get-ItemById -Session $runningWithoutStart -ItemId 'source.validate').status = 'running'
Assert-ThrowsLike -Script { Resolve-ExecutionAdmission -CommandPlan $plan -CommandSession $runningWithoutStart | Out-Null } -Pattern 'running automation item requires exactly one start event' -Message 'Running item without start must be rejected.'
$runningWithResult = Copy-ExecutionAdmissionObject -Value (Complete-Automation -Session $session -ItemId 'source.validate' -Prefix 'run-result')
(Get-ItemById -Session $runningWithResult -ItemId 'source.validate').status = 'running'
(Get-ItemById -Session $runningWithResult -ItemId 'archive.create').status = 'pending'
Assert-ThrowsLike -Script { Resolve-ExecutionAdmission -CommandPlan $plan -CommandSession $runningWithResult | Out-Null } -Pattern 'running automation item requires exactly one start event and no result event' -Message 'Running item with result must be rejected.'
$completedWithoutResult = Copy-ExecutionAdmissionObject -Value $session
(Get-ItemById -Session $completedWithoutResult -ItemId 'source.validate').status = 'completed'
Assert-ThrowsLike -Script { Resolve-ExecutionAdmission -CommandPlan $plan -CommandSession $completedWithoutResult | Out-Null } -Pattern 'completed automation item requires successful automation-result' -Message 'Completed automation without result must be rejected.'
$completedHumanFailedExit = Copy-ExecutionAdmissionObject -Value $failedSession
(Get-ItemById -Session $completedHumanFailedExit -ItemId 'artifact.upload').status = 'completed'
Assert-ThrowsLike -Script { Resolve-ExecutionAdmission -CommandPlan $plan -CommandSession $completedHumanFailedExit | Out-Null } -Pattern 'completed human-command item requires exitStatus 0' -Message 'Completed human command with failed exit must be rejected.'
$failedHumanZeroExit = Copy-ExecutionAdmissionObject -Value $afterUpload
$failedHumanZeroExit.status = 'failed'
(Get-ItemById -Session $failedHumanZeroExit -ItemId 'artifact.upload').status = 'failed'
(Get-ItemById -Session $failedHumanZeroExit -ItemId 'artifact.upload').feedback.stderr = 'fatal text'
Assert-ThrowsLike -Script { Resolve-ExecutionAdmission -CommandPlan $plan -CommandSession $failedHumanZeroExit | Out-Null } -Pattern 'failed human-command item requires non-zero exitStatus' -Message 'Failed human command with exitStatus 0 must be rejected.'
$readyWithStart = Copy-ExecutionAdmissionObject -Value $sourceStarted
(Get-ItemById -Session $readyWithStart -ItemId 'source.validate').status = 'ready'
Assert-ThrowsLike -Script { Resolve-ExecutionAdmission -CommandPlan $plan -CommandSession $readyWithStart | Out-Null } -Pattern 'non-started automation item has execution event history' -Message 'Ready item with start history must be rejected.'
$pendingWithResult = Copy-ExecutionAdmissionObject -Value (Complete-Automation -Session $session -ItemId 'source.validate' -Prefix 'pending-result')
(Get-ItemById -Session $pendingWithResult -ItemId 'source.validate').status = 'pending'
(Get-ItemById -Session $pendingWithResult -ItemId 'archive.create').status = 'pending'
Assert-ThrowsLike -Script { Resolve-ExecutionAdmission -CommandPlan $plan -CommandSession $pendingWithResult | Out-Null } -Pattern 'non-started automation item has execution event history' -Message 'Pending item with result history must be rejected.'
$automationCompletedWithHumanEvents = Copy-ExecutionAdmissionObject -Value $session
(Get-ItemById -Session $automationCompletedWithHumanEvents -ItemId 'source.validate').status = 'completed'
$automationCompletedWithHumanEvents.eventHistory = @(New-HistoryEvent -Id 'wrong-start' -Type 'human-command-started' -Target 'source.validate' -ResultingStatus 'running'; New-HistoryEvent -Id 'wrong-result' -Type 'human-command-result' -Target 'source.validate' -ResultingStatus 'completed' -Payload ([pscustomobject]@{ result = [pscustomobject]@{ exitStatus = 0; stdout = ''; stderr = '' } }))
Assert-ThrowsLike -Script { Resolve-ExecutionAdmission -CommandPlan $plan -CommandSession $automationCompletedWithHumanEvents | Out-Null } -Pattern "does not match actor 'automation'" -Message 'Completed automation item with human command events must be rejected.'
$humanCompletedWithAutomationEvents = Copy-ExecutionAdmissionObject -Value $afterApproval
(Get-ItemById -Session $humanCompletedWithAutomationEvents -ItemId 'artifact.upload').status = 'completed'
$humanCompletedWithAutomationEvents.eventHistory += @(New-HistoryEvent -Id 'wrong-auto-start' -Type 'automation-started' -Target 'artifact.upload' -ResultingStatus 'running'; New-HistoryEvent -Id 'wrong-auto-result' -Type 'automation-result' -Target 'artifact.upload' -ResultingStatus 'completed' -Payload ([pscustomobject]@{ result = [pscustomobject]@{ status = 'completed' } }))
Assert-ThrowsLike -Script { Resolve-ExecutionAdmission -CommandPlan $plan -CommandSession $humanCompletedWithAutomationEvents | Out-Null } -Pattern "does not match actor 'human-command'" -Message 'Completed human-command item with automation events must be rejected.'

$missingExitStatus = Copy-ExecutionAdmissionObject -Value $uploadStarted
$missingExitStatus.eventHistory += New-HistoryEvent -Id 'missing-exit' -Type 'human-command-result' -Target 'artifact.upload' -ResultingStatus 'completed' -Payload ([pscustomobject]@{ result = [pscustomobject]@{ stdout = ''; stderr = '' } })
Assert-ThrowsLike -Script { Resolve-ExecutionAdmission -CommandPlan $plan -CommandSession $missingExitStatus | Out-Null } -Pattern "field 'exitStatus' must be an integer|missing required field 'exitStatus'" -Message 'Human command result must require exitStatus.'
$nonIntegerExitStatus = Copy-ExecutionAdmissionObject -Value $uploadStarted
$nonIntegerExitStatus.eventHistory += New-HistoryEvent -Id 'bad-exit' -Type 'human-command-result' -Target 'artifact.upload' -ResultingStatus 'failed' -Payload ([pscustomobject]@{ result = [pscustomobject]@{ exitStatus = 'nope'; stdout = ''; stderr = '' } })
Assert-ThrowsLike -Script { Resolve-ExecutionAdmission -CommandPlan $plan -CommandSession $nonIntegerExitStatus | Out-Null } -Pattern "field 'exitStatus' must be an integer" -Message 'Human command result must reject non-integer exitStatus.'
Assert-Equal (Resolve-ExecutionAdmission -CommandPlan $plan -CommandSession $afterUpload).requirements.dependenciesCompleted $true 'exitStatus 0 must be treated as technically successful.'
$failedWithPositiveStdout = Copy-ExecutionAdmissionObject -Value $failedSession
(Get-ItemById -Session $failedWithPositiveStdout -ItemId 'artifact.upload').feedback.stdout = 'success'
Assert-Equal (Resolve-ExecutionAdmission -CommandPlan $plan -CommandSession $failedWithPositiveStdout).status 'failed' 'Positive stdout must not override failed exitStatus.'
$completedWithErrorStderr = Copy-ExecutionAdmissionObject -Value $afterUpload
(Get-ItemById -Session $completedWithErrorStderr -ItemId 'artifact.upload').feedback.stderr = 'fatal error text'
Assert-Equal (Resolve-ExecutionAdmission -CommandPlan $plan -CommandSession $completedWithErrorStderr).status 'requires-human' 'Error stderr must not override exitStatus 0.'

Assert-Equal (Resolve-ExecutionAdmission -CommandPlan $plan -CommandSession $afterApproval).requirements.humanApprovalSatisfied $true 'Approved gate must satisfy human approval.'
Assert-Equal (Resolve-ExecutionAdmission -CommandPlan $plan -CommandSession $session).requirements.humanApprovalSatisfied $true 'Item without human gate dependency must have humanApprovalSatisfied true.'
$openGateUpload = Copy-ExecutionAdmissionObject -Value $approvalSession
$openGateUpload.currentItemId = 'artifact.upload'
Assert-Equal (Resolve-ExecutionAdmission -CommandPlan $plan -CommandSession $openGateUpload).requirements.humanApprovalSatisfied $false 'Open gate must not satisfy human approval.'
$rejectedGate = Apply-CommandSessionEvent -CommandSession $approvalSession -Event (New-Event -Id 'approval-rejected' -Type 'human-decision-submitted' -Target 'deployment.approval' -Payload ([pscustomobject]@{ decision = [pscustomobject]@{ value = 'rejected' } }))
Assert-Equal (Resolve-ExecutionAdmission -CommandPlan $plan -CommandSession $rejectedGate).requirements.humanApprovalSatisfied $false 'Rejected gate must not satisfy human approval.'
$unknownDecision = Copy-ExecutionAdmissionObject -Value $approvalSession
$unknownDecision.eventHistory += New-HistoryEvent -Id 'unknown-decision' -Type 'human-decision-submitted' -Target 'deployment.approval' -ResultingStatus 'completed' -Payload ([pscustomobject]@{ decision = [pscustomobject]@{ value = 'maybe' } })
Assert-ThrowsLike -Script { Resolve-ExecutionAdmission -CommandPlan $plan -CommandSession $unknownDecision | Out-Null } -Pattern "decision 'maybe' is not allowed" -Message 'Unknown human decision must be rejected.'
$doubleDecision = Copy-ExecutionAdmissionObject -Value $afterApproval
$doubleDecision.eventHistory += New-HistoryEvent -Id 'double-decision' -Type 'human-decision-submitted' -Target 'deployment.approval' -ResultingStatus 'completed' -Payload ([pscustomobject]@{ decision = [pscustomobject]@{ value = 'approved' } })
Assert-ThrowsLike -Script { Resolve-ExecutionAdmission -CommandPlan $plan -CommandSession $doubleDecision | Out-Null } -Pattern 'appears after terminal event|duplicate human-decision' -Message 'Duplicate decision event must be rejected.'

$reviewInconclusiveSession = Copy-ExecutionAdmissionObject -Value $afterExtract
$reviewInconclusiveSession.eventHistory += New-HistoryEvent -Id 'review-inconclusive-history' -Type 'review-result' -Target 'deployment.verify' -ResultingStatus 'waiting-for-human' -Payload ([pscustomobject]@{ review = [pscustomobject]@{ status = 'inconclusive' } })
Assert-Equal (Resolve-ExecutionAdmission -CommandPlan $plan -CommandSession $reviewInconclusiveSession).status 'requires-review' 'Inconclusive review may remain waiting for review.'
$unknownReview = Copy-ExecutionAdmissionObject -Value $afterExtract
$unknownReview.eventHistory += New-HistoryEvent -Id 'unknown-review' -Type 'review-result' -Target 'deployment.verify' -ResultingStatus 'failed' -Payload ([pscustomobject]@{ review = [pscustomobject]@{ status = 'banana' } })
Assert-ThrowsLike -Script { Resolve-ExecutionAdmission -CommandPlan $plan -CommandSession $unknownReview | Out-Null } -Pattern "unsupported status 'banana'" -Message 'Unknown review result must be rejected.'
$doubleReview = Copy-ExecutionAdmissionObject -Value $completedSession
$doubleReview.eventHistory += New-HistoryEvent -Id 'double-review' -Type 'review-result' -Target 'deployment.verify' -ResultingStatus 'completed' -Payload ([pscustomobject]@{ review = [pscustomobject]@{ status = 'approved' } })
Assert-ThrowsLike -Script { Resolve-ExecutionAdmission -CommandPlan $plan -CommandSession $doubleReview | Out-Null } -Pattern 'appears after terminal event|duplicate review-result' -Message 'Duplicate review result must be rejected.'

$customGatePlan = New-TestCommandPlan
$customGatePlan.humanGates[0].gateId = 'production.release.confirmation'
$customGatePlan.humanGates[0].stepId = 'production.release.confirmation'
$customGatePlan.commands[2].dependsOn = @('production.release.confirmation')
$customGatePlan.commands[3].dependsOn = @('artifact.upload')
$customGateSession = New-CommandSession -CommandPlan $customGatePlan
$customGateReady = Complete-Automation -Session (Complete-Automation -Session $customGateSession -ItemId 'source.validate' -Prefix 'custom-source') -ItemId 'archive.create' -Prefix 'custom-archive'
$customOpenUpload = Copy-ExecutionAdmissionObject -Value $customGateReady
$customOpenUpload.currentItemId = 'artifact.upload'
Assert-Equal (Resolve-ExecutionAdmission -CommandPlan $customGatePlan -CommandSession $customOpenUpload).requirements.humanApprovalSatisfied $false 'Custom open gate must be discovered without hardcoded ID.'
$customApproved = Apply-CommandSessionEvent -CommandSession $customGateReady -Event (New-Event -Id 'custom-approval' -Type 'human-decision-submitted' -Target 'production.release.confirmation' -Payload ([pscustomobject]@{ decision = [pscustomobject]@{ value = 'approved' } }))
Assert-Equal (Resolve-ExecutionAdmission -CommandPlan $customGatePlan -CommandSession $customApproved).requirements.humanApprovalSatisfied $true 'Custom approved gate must satisfy approval without hardcoded ID.'

$source = Get-Content -LiteralPath $admissionPath -Raw
foreach ($forbidden in @('Start-Process', 'Invoke-Expression', 'System.Diagnostics.Process', 'ProcessStartInfo', 'ssh.exe', 'scp.exe', 'git.exe', 'tar.exe', '7z.exe', 'Invoke-Command', 'New-PSSession', 'Enter-PSSession', 'Apply-CommandSessionEvent', 'New-Event')) {
    Assert-True (-not ($source -match [regex]::Escape($forbidden))) "Execution admission source must not contain process or network starter '$forbidden'."
}

$tmp = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('execution-admission-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    $planPath = Join-Path -Path $tmp -ChildPath 'command-plan.json'
    $sessionPathInput = Join-Path -Path $tmp -ChildPath 'command-session.json'
    $outputPath = Join-Path -Path $tmp -ChildPath 'nested/execution-admission.json'
    New-TestCommandPlan | ConvertTo-Json -Depth 80 | Set-Content -LiteralPath $planPath -Encoding UTF8
    New-CommandSession -CommandPlan (New-TestCommandPlan) | ConvertTo-Json -Depth 80 | Set-Content -LiteralPath $sessionPathInput -Encoding UTF8
    Assert-ThrowsLike -Script { & $cliPath evaluate-execution-admission -CommandSessionPath $sessionPathInput -Format Json | Out-Null } -Pattern "Missing required parameter for 'evaluate-execution-admission': -CommandPlanPath" -Message 'CLI missing CommandPlanPath must be rejected.'
    Assert-ThrowsLike -Script { & $cliPath evaluate-execution-admission -CommandPlanPath $planPath -Format Json | Out-Null } -Pattern "Missing required parameter for 'evaluate-execution-admission': -CommandSessionPath" -Message 'CLI missing CommandSessionPath must be rejected.'
    Assert-ThrowsLike -Script { & $cliPath evaluate-execution-admission -CommandPlanPath $planPath -CommandSessionPath $sessionPathInput -Format Text | Out-Null } -Pattern 'only supports -Format Json' -Message 'CLI invalid format must be rejected.'
    $fileCountBeforeStdout = @(Get-ChildItem -LiteralPath $tmp -File -Recurse).Count
    $stdoutJson = & $cliPath evaluate-execution-admission -CommandPlanPath $planPath -CommandSessionPath $sessionPathInput -Format Json
    $fileCountAfterStdout = @(Get-ChildItem -LiteralPath $tmp -File -Recurse).Count
    $stdoutAdmission = $stdoutJson | ConvertFrom-Json
    Assert-Equal $stdoutAdmission.admissionType 'execution-admission' 'CLI without OutputPath must emit parseable admission JSON.'
    Assert-Equal @($stdoutJson).Count 1 'CLI without OutputPath must not emit additional stdout lines.'
    Assert-Equal $fileCountAfterStdout $fileCountBeforeStdout 'CLI without OutputPath must not create files.'
    & $cliPath evaluate-execution-admission -CommandPlanPath $planPath -CommandSessionPath $sessionPathInput -OutputPath $outputPath -Format Json | Out-Null
    Assert-True (Test-Path -LiteralPath $outputPath -PathType Leaf) 'CLI invocation must create explicit output path.'
    Assert-Equal @(Get-ChildItem -LiteralPath (Split-Path -Path $outputPath -Parent) -File).Count 1 'CLI with OutputPath must write exactly one JSON file in the output directory.'
    Assert-Equal (Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json).status 'eligible-but-disabled' 'CLI output must contain expected admission status.'
} finally {
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
}

if ($script:failures.Count -gt 0) {
    Write-Host 'Execution Admission tests failed:'
    $script:failures | ForEach-Object { Write-Host "- $_" }
    exit 1
}

Write-Host 'Execution Admission tests passed.'
exit 0
