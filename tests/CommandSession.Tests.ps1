[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:failures = New-Object System.Collections.Generic.List[string]
$engineRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '..'))
$sessionPath = Join-Path -Path $engineRoot -ChildPath 'src/ps1/CommandSession.ps1'
$cliPath = Join-Path -Path $engineRoot -ChildPath 'bin/deployment-engine.ps1'

. $sessionPath

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
        [Parameter(Mandatory = $true)][string] $Mode,
        [string[]] $DependsOn = @(),
        [string] $RenderedCommand = ''
    )
    return [pscustomobject]@{
        commandId = $Id
        sequence = $Sequence
        strategyStepId = $Id
        operationType = $Id
        actor = $Actor
        executionLocation = if ($Actor -eq 'automation') { 'local' } else { 'remote' }
        executionMode = $Mode
        dependsOn = @($DependsOn)
        program = if ($Actor -eq 'automation') { 'local-operation' } else { 'ssh' }
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
            New-TestCommand -Id 'source.validate' -Sequence 100 -Actor 'automation' -Mode 'automatic'
            New-TestCommand -Id 'archive.create' -Sequence 300 -Actor 'automation' -Mode 'automatic' -DependsOn @('source.validate')
            New-TestCommand -Id 'remote.archive.upload' -Sequence 600 -Actor 'human-command' -Mode 'copy-and-run' -DependsOn @('deployment.approval') -RenderedCommand 'scp artifact deploy@example.org:/absolute/artifact.zip'
            New-TestCommand -Id 'deployment.verify' -Sequence 900 -Actor 'review' -Mode 'none' -DependsOn @('remote.archive.upload')
        )
        humanGates = @(
            [pscustomobject]@{ gateId = 'deployment.approval'; stepId = 'deployment.approval'; sequence = 400; dependsOn = @('archive.create'); gateType = 'approval'; blocksContinuation = $true; allowedResponses = @('approved', 'rejected') }
        )
        diagnostic = ''
    }
}

function Get-ItemById {
    param([object] $Session, [string] $ItemId)
    return @($Session.items | Where-Object { $_.itemId -eq $ItemId } | Select-Object -First 1)[0]
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

$plan = New-TestCommandPlan
$planBefore = $plan | ConvertTo-Json -Depth 60
$session = New-CommandSession -CommandPlan $plan
Assert-Equal ($plan | ConvertTo-Json -Depth 60) $planBefore 'Command plan input must not be mutated.'
Assert-Equal $session.sessionType 'deployment-command-session' 'Valid command plan must create a command session.'
Assert-Equal @($session.items).Count 5 'Commands and human gates must become session items.'
Assert-Equal (Get-ItemById -Session $session -ItemId 'source.validate').status 'ready' 'First automation item must become ready but not completed.'
Assert-Equal (Get-ItemById -Session $session -ItemId 'archive.create').status 'pending' 'Dependent automation must remain pending.'
Assert-Equal (Get-ItemById -Session $session -ItemId 'deployment.approval').status 'pending' 'Human gate must wait for modeled dependencies.'
Assert-Equal ((Get-ItemById -Session $session -ItemId 'deployment.approval').dependsOn -join ',') 'archive.create' 'Human gate must carry command plan dependencies.'
Assert-Equal (Get-ItemById -Session $session -ItemId 'remote.archive.upload').status 'pending' 'Human gate must block dependent human commands.'
Assert-Equal (Get-ItemById -Session $session -ItemId 'source.validate').attempt 0 'No item may be started automatically.'

Assert-ThrowsLike -Script { Apply-CommandSessionEvent -CommandSession $session -Event (New-Event -Id 'event-001' -Type 'human-decision-submitted' -Target 'deployment.approval' -Payload ([pscustomobject]@{ decision = [pscustomobject]@{ value = 'approved' } })) | Out-Null } -Pattern 'human decision item must be waiting-for-human' -Message 'Approval must not be accepted before modeled dependencies complete.'

$sourceStarted = Apply-CommandSessionEvent -CommandSession $session -Event (New-Event -Id 'event-002' -Type 'automation-started' -Target 'source.validate' -Payload $null)
Assert-Equal (Get-ItemById -Session $sourceStarted -ItemId 'source.validate').status 'running' 'Automation start event must set automation item to running.'
Assert-Equal (Get-ItemById -Session $sourceStarted -ItemId 'source.validate').attempt 1 'Automation start event must increment attempt.'
Assert-Equal $sourceStarted.status 'in-progress' 'Session must be in-progress while at least one item is running.'
Assert-ThrowsLike -Script { Apply-CommandSessionEvent -CommandSession $session -Event (New-Event -Id 'event-003' -Type 'automation-result' -Target 'source.validate' -Payload ([pscustomobject]@{ result = [pscustomobject]@{ status = 'completed'; diagnostic = '' } })) | Out-Null } -Pattern 'automation result requires running item' -Message 'Automation result without started event must be rejected.'

$sourceCompleted = Apply-CommandSessionEvent -CommandSession $sourceStarted -Event (New-Event -Id 'event-003' -Type 'automation-result' -Target 'source.validate' -Payload ([pscustomobject]@{ result = [pscustomobject]@{ status = 'completed'; diagnostic = 'source ok' } }))
Assert-Equal (Get-ItemById -Session $sourceCompleted -ItemId 'source.validate').status 'completed' 'Completed automation result must complete automation item.'
Assert-Equal (Get-ItemById -Session $sourceCompleted -ItemId 'source.validate').feedback.diagnostic 'source ok' 'Automation result must be stored structurally.'
Assert-Equal (Get-ItemById -Session $sourceCompleted -ItemId 'archive.create').status 'ready' 'Dependencies, not sequence alone, must activate items.'
Assert-Equal (Get-ItemById -Session $sourceCompleted -ItemId 'remote.archive.upload').status 'pending' 'Upload must still wait for approval dependency.'

$archiveStarted = Apply-CommandSessionEvent -CommandSession $sourceCompleted -Event (New-Event -Id 'event-004' -Type 'automation-started' -Target 'archive.create' -Payload $null)
Assert-Equal $archiveStarted.status 'in-progress' 'Session must remain in-progress while archive automation is running.'
$failedAutomation = Apply-CommandSessionEvent -CommandSession $archiveStarted -Event (New-Event -Id 'event-005' -Type 'automation-result' -Target 'archive.create' -Payload ([pscustomobject]@{ result = [pscustomobject]@{ status = 'failed'; diagnostic = 'archive failed' } }))
Assert-Equal $failedAutomation.status 'failed' 'Failed automation result must fail the session.'
Assert-Equal (Get-ItemById -Session $failedAutomation -ItemId 'archive.create').feedback.diagnostic 'archive failed' 'Failed automation diagnostic must be stored structurally.'
$approvedBase = Apply-CommandSessionEvent -CommandSession $archiveStarted -Event (New-Event -Id 'event-006' -Type 'automation-result' -Target 'archive.create' -Payload ([pscustomobject]@{ result = [pscustomobject]@{ status = 'completed'; diagnostic = '' } }))
Assert-Equal (Get-ItemById -Session $approvedBase -ItemId 'deployment.approval').status 'waiting-for-human' 'Deployment approval must activate after modeled dependencies complete.'

$approvalEvent = New-Event -Id 'event-007' -Type 'human-decision-submitted' -Target 'deployment.approval' -Payload ([pscustomobject]@{ decision = [pscustomobject]@{ value = 'approved' } })
$afterApproval = Apply-CommandSessionEvent -CommandSession $approvedBase -Event $approvalEvent
Assert-Equal (Get-ItemById -Session $afterApproval -ItemId 'deployment.approval').status 'completed' 'Approval event must complete approval item.'
Assert-Equal (Get-ItemById -Session $afterApproval -ItemId 'remote.archive.upload').status 'waiting-for-human' 'Approval must allow dependent human command to wait for input.'
Assert-Equal @($afterApproval.eventHistory).Count 5 'Valid state changes must be recorded.'

$rejectionSession = Apply-CommandSessionEvent -CommandSession $approvedBase -Event (New-Event -Id 'event-008' -Type 'human-decision-submitted' -Target 'deployment.approval' -Payload ([pscustomobject]@{ decision = [pscustomobject]@{ value = 'rejected' } }))
Assert-Equal $rejectionSession.status 'cancelled' 'Rejected approval must cancel the session.'
Assert-ThrowsLike -Script { Apply-CommandSessionEvent -CommandSession $approvedBase -Event (New-Event -Id 'event-009' -Type 'human-decision-submitted' -Target 'deployment.approval' -Payload ([pscustomobject]@{ decision = [pscustomobject]@{ value = 'maybe' } })) | Out-Null } -Pattern 'is not allowed' -Message 'Invalid decision must be rejected.'
Assert-ThrowsLike -Script { Apply-CommandSessionEvent -CommandSession $afterApproval -Event (New-Event -Id 'event-007' -Type 'human-command-started' -Target 'remote.archive.upload' -Payload $null) | Out-Null } -Pattern 'duplicate eventId' -Message 'Duplicate event IDs must be rejected.'
Assert-ThrowsLike -Script { Apply-CommandSessionEvent -CommandSession $afterApproval -Event (New-Event -Id 'event-010' -Type 'human-decision-submitted' -Target 'deployment.approval' -Payload ([pscustomObject]@{ decision = [pscustomobject]@{ value = 'approved' } })) | Out-Null } -Pattern 'already terminal' -Message 'Doubled decision on completed item must be rejected.'

$started = Apply-CommandSessionEvent -CommandSession $afterApproval -Event (New-Event -Id 'event-011' -Type 'human-command-started' -Target 'remote.archive.upload' -Payload $null)
Assert-Equal (Get-ItemById -Session $started -ItemId 'remote.archive.upload').status 'running' 'Started event must set human command to running.'
Assert-Equal (Get-ItemById -Session $started -ItemId 'remote.archive.upload').attempt 1 'Started event must increment attempt.'
Assert-Equal $started.status 'in-progress' 'Session must be in-progress while a human command is running.'
$successful = Apply-CommandSessionEvent -CommandSession $started -Event (New-Event -Id 'event-012' -Type 'human-command-result' -Target 'remote.archive.upload' -Payload ([pscustomobject]@{ result = [pscustomobject]@{ exitStatus = 0; stdout = 'ok'; stderr = '' } }))
Assert-Equal (Get-ItemById -Session $successful -ItemId 'remote.archive.upload').status 'completed' 'Exit status 0 must complete human command.'
Assert-Equal (Get-ItemById -Session $successful -ItemId 'remote.archive.upload').feedback.stdout 'ok' 'stdout must be stored structurally.'
Assert-Equal (Get-ItemById -Session $successful -ItemId 'deployment.verify').status 'waiting-for-human' 'Review must become waiting after command dependency completes.'

$failedRun = Apply-CommandSessionEvent -CommandSession $started -Event (New-Event -Id 'event-013' -Type 'human-command-result' -Target 'remote.archive.upload' -Payload ([pscustomobject]@{ result = [pscustomobject]@{ exitStatus = 1; stdout = ''; stderr = 'permission denied' } }))
Assert-Equal $failedRun.status 'failed' 'Non-zero exit status must fail the session.'
Assert-Equal (Get-ItemById -Session $failedRun -ItemId 'remote.archive.upload').feedback.stderr 'permission denied' 'stderr must be stored structurally.'
Assert-ThrowsLike -Script { Apply-CommandSessionEvent -CommandSession $afterApproval -Event (New-Event -Id 'event-014' -Type 'human-command-result' -Target 'remote.archive.upload' -Payload ([pscustomobject]@{ result = [pscustomobject]@{ exitStatus = 0; stdout = ''; stderr = '' } })) | Out-Null } -Pattern 'requires running item' -Message 'Result without started event must be rejected.'

$reviewApproved = Apply-CommandSessionEvent -CommandSession $successful -Event (New-Event -Id 'event-015' -Type 'review-result' -Target 'deployment.verify' -Payload ([pscustomobject]@{ review = [pscustomobject]@{ status = 'approved'; diagnostic = '' } }))
Assert-Equal (Get-ItemById -Session $reviewApproved -ItemId 'deployment.verify').status 'completed' 'Approved review must complete review item.'
$reviewRejected = Apply-CommandSessionEvent -CommandSession $successful -Event (New-Event -Id 'event-016' -Type 'review-result' -Target 'deployment.verify' -Payload ([pscustomobject]@{ review = [pscustomobject]@{ status = 'rejected'; diagnostic = '' } }))
Assert-Equal $reviewRejected.status 'failed' 'Rejected review must fail session.'
$reviewInconclusive = Apply-CommandSessionEvent -CommandSession $successful -Event (New-Event -Id 'event-017' -Type 'review-result' -Target 'deployment.verify' -Payload ([pscustomobject]@{ review = [pscustomobject]@{ status = 'inconclusive'; diagnostic = '' } }))
Assert-Equal (Get-ItemById -Session $reviewInconclusive -ItemId 'deployment.verify').status 'waiting-for-human' 'Inconclusive review must remain waiting.'
Assert-ThrowsLike -Script { Apply-CommandSessionEvent -CommandSession $successful -Event (New-Event -Id 'event-018' -Type 'review-result' -Target 'deployment.verify' -Payload ([pscustomobject]@{ review = [pscustomobject]@{ status = 'unknown'; diagnostic = '' } })) | Out-Null } -Pattern "unsupported status 'unknown'" -Message 'Unknown review status must be rejected.'

Assert-ThrowsLike -Script { Apply-CommandSessionEvent -CommandSession $session -Event ([pscustomobject]@{ schemaVersion = '0.1'; eventType = 'human-command-started'; targetItemId = 'source.validate' }) | Out-Null } -Pattern "missing required field 'eventId'" -Message 'Event ID must be required.'
Assert-ThrowsLike -Script { Apply-CommandSessionEvent -CommandSession $session -Event ([pscustomobject]@{ schemaVersion = '0.1'; eventId = 'event-019'; eventType = 'magic'; targetItemId = 'source.validate' }) | Out-Null } -Pattern "unsupported status 'magic'" -Message 'Unknown event type must be rejected.'
Assert-ThrowsLike -Script { Apply-CommandSessionEvent -CommandSession $session -Event (New-Event -Id 'event-020' -Type 'human-command-started' -Target 'source.validate' -Payload $null) | Out-Null } -Pattern 'requires human-command item' -Message 'Wrong actor/event mix must be rejected.'
Assert-ThrowsLike -Script { Apply-CommandSessionEvent -CommandSession $session -Event (New-Event -Id 'event-021' -Type 'automation-started' -Target 'remote.archive.upload' -Payload $null) | Out-Null } -Pattern 'requires automation item' -Message 'Automation start must reject non-automation items.'
Assert-ThrowsLike -Script { Apply-CommandSessionEvent -CommandSession $session -Event (New-Event -Id 'event-022' -Type 'automation-result' -Target 'source.validate' -Payload ([pscustomobject]@{ result = [pscustomobject]@{ status = 'unknown'; diagnostic = '' } })) | Out-Null } -Pattern 'automation result requires running item' -Message 'Automation result must require a running item before validating result status.'
Assert-ThrowsLike -Script { Apply-CommandSessionEvent -CommandSession $sourceStarted -Event (New-Event -Id 'event-023' -Type 'automation-result' -Target 'source.validate' -Payload ([pscustomobject]@{ result = [pscustomobject]@{ status = 'unknown'; diagnostic = '' } })) | Out-Null } -Pattern "unsupported status 'unknown'" -Message 'Unknown automation result status must be rejected.'
Assert-ThrowsLike -Script { Apply-CommandSessionEvent -CommandSession $session -Event (New-Event -Id 'event-024' -Type 'human-command-started' -Target 'missing' -Payload $null) | Out-Null } -Pattern "target item 'missing' does not exist" -Message 'Unknown event target must be rejected.'

$badDependencyPlan = New-TestCommandPlan
$badDependencyPlan.commands[1].dependsOn = @('missing')
Assert-ThrowsLike -Script { New-CommandSession -CommandPlan $badDependencyPlan | Out-Null } -Pattern "depends on unknown item 'missing'" -Message 'Unknown dependencies must be rejected.'
$selfDependencyPlan = New-TestCommandPlan
$selfDependencyPlan.commands[0].dependsOn = @('source.validate')
Assert-ThrowsLike -Script { New-CommandSession -CommandPlan $selfDependencyPlan | Out-Null } -Pattern 'depends on itself' -Message 'Self dependencies must be rejected.'
$cyclePlan = New-TestCommandPlan
$cyclePlan.commands[0].dependsOn = @('archive.create')
Assert-ThrowsLike -Script { New-CommandSession -CommandPlan $cyclePlan | Out-Null } -Pattern 'cyclic dependency detected' -Message 'Dependency cycles must be rejected.'

$sessionBefore = $afterApproval | ConvertTo-Json -Depth 60
$eventBefore = (New-Event -Id 'event-025' -Type 'human-command-started' -Target 'remote.archive.upload' -Payload $null) | ConvertTo-Json -Depth 60
$eventObj = $eventBefore | ConvertFrom-Json
$updated = Apply-CommandSessionEvent -CommandSession $afterApproval -Event $eventObj
Assert-Equal ($afterApproval | ConvertTo-Json -Depth 60) $sessionBefore 'Command session input must not be mutated.'
Assert-Equal ($eventObj | ConvertTo-Json -Depth 60) $eventBefore 'Event input must not be mutated.'
$updated.items[0].status = 'changed'
Assert-True (($afterApproval.items | ForEach-Object { $_.status }) -notcontains 'changed') 'Output must not share mutable references with input session.'

$source = Get-Content -LiteralPath $sessionPath -Raw
foreach ($forbidden in @('Start-Process', 'Invoke-Expression', 'System.Diagnostics.Process', 'ProcessStartInfo', 'ssh.exe', 'scp.exe', 'git.exe', 'tar.exe', '7z.exe', 'Invoke-Command', 'New-PSSession')) {
    Assert-True (-not ($source -match [regex]::Escape($forbidden))) "Command session source must not contain process or network starter '$forbidden'."
}

$tmp = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('command-session-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    $commandPlanPathInput = Join-Path -Path $tmp -ChildPath 'command-plan.json'
    $sessionPathInput = Join-Path -Path $tmp -ChildPath 'command-session.json'
    $eventPath = Join-Path -Path $tmp -ChildPath 'event.json'
    $outputPath = Join-Path -Path $tmp -ChildPath 'nested/updated-session.json'
    New-TestCommandPlan | ConvertTo-Json -Depth 60 | Set-Content -LiteralPath $commandPlanPathInput -Encoding UTF8
    Assert-ThrowsLike -Script { & $cliPath create-command-session -Format Text -CommandPlanPath $commandPlanPathInput | Out-Null } -Pattern 'only supports -Format Json' -Message 'Create CLI must reject non-Json format.'
    Assert-ThrowsLike -Script { & $cliPath create-command-session -Format Json | Out-Null } -Pattern "Missing required parameter for 'create-command-session': -CommandPlanPath" -Message 'Create CLI must require CommandPlanPath.'
    $fileCountBeforeStdout = @(Get-ChildItem -LiteralPath $tmp -File -Recurse).Count
    $stdoutJson = & $cliPath create-command-session -CommandPlanPath $commandPlanPathInput -Format Json
    $fileCountAfterStdout = @(Get-ChildItem -LiteralPath $tmp -File -Recurse).Count
    $stdoutSession = $stdoutJson | ConvertFrom-Json
    Assert-Equal $stdoutSession.sessionType 'deployment-command-session' 'Create CLI without OutputPath must emit parseable JSON.'
    Assert-Equal @($stdoutJson).Count 1 'Create CLI must not emit additional stdout lines.'
    Assert-Equal $fileCountAfterStdout $fileCountBeforeStdout 'Create CLI without OutputPath must not create files.'
    & $cliPath create-command-session -CommandPlanPath $commandPlanPathInput -OutputPath $sessionPathInput -Format Json | Out-Null
    Assert-True (Test-Path -LiteralPath $sessionPathInput -PathType Leaf) 'Create CLI must write explicit output file.'
    Assert-ThrowsLike -Script { & $cliPath update-command-session -CommandSessionPath $sessionPathInput -Format Json | Out-Null } -Pattern "Missing required parameter for 'update-command-session': -SessionEventPath" -Message 'Update CLI must require SessionEventPath.'
    $currentSessionPath = $sessionPathInput
    $cliEvents = @(
        New-Event -Id 'event-cli-001' -Type 'automation-started' -Target 'source.validate' -Payload $null
        New-Event -Id 'event-cli-002' -Type 'automation-result' -Target 'source.validate' -Payload ([pscustomobject]@{ result = [pscustomobject]@{ status = 'completed'; diagnostic = '' } })
        New-Event -Id 'event-cli-003' -Type 'automation-started' -Target 'archive.create' -Payload $null
        New-Event -Id 'event-cli-004' -Type 'automation-result' -Target 'archive.create' -Payload ([pscustomobject]@{ result = [pscustomobject]@{ status = 'completed'; diagnostic = '' } })
        New-Event -Id 'event-cli-005' -Type 'human-decision-submitted' -Target 'deployment.approval' -Payload ([pscustomobject]@{ decision = [pscustomobject]@{ value = 'approved' } })
    )
    $eventIndex = 0
    foreach ($cliEvent in $cliEvents) {
        $eventIndex++
        $nextSessionPath = if ($eventIndex -eq @($cliEvents).Count) { $outputPath } else { Join-Path -Path $tmp -ChildPath "session-$eventIndex.json" }
        $cliEvent | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $eventPath -Encoding UTF8
        & $cliPath update-command-session -CommandSessionPath $currentSessionPath -SessionEventPath $eventPath -OutputPath $nextSessionPath -Format Json | Out-Null
        $currentSessionPath = $nextSessionPath
    }
    Assert-True (Test-Path -LiteralPath $outputPath -PathType Leaf) 'Update CLI must write explicit output file.'
    $updatedCliSession = Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json
    Assert-Equal $updatedCliSession.sessionType 'deployment-command-session' 'Update CLI output must be session JSON.'
    Assert-Equal (Get-ItemById -Session $updatedCliSession -ItemId 'deployment.approval').status 'completed' 'Update CLI must apply event-driven approval after dependencies complete.'
} finally {
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
}

if ($script:failures.Count -gt 0) {
    Write-Host 'Command Session tests failed:'
    $script:failures | ForEach-Object { Write-Host "- $_" }
    exit 1
}

Write-Host 'Command Session tests passed.'
exit 0
