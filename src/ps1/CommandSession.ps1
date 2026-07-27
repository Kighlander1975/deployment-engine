[CmdletBinding()]
param(
    [string] $CommandPlanPath,
    [string] $CommandSessionPath,
    [string] $SessionEventPath,
    [string] $OutputPath,
    [string] $Format = 'Json',
    [ValidateSet('Create', 'Update')]
    [string] $Operation = 'Create'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path -Path $PSScriptRoot -ChildPath 'DeploymentAdapters.ps1')

function Resolve-CommandSessionPath {
    param([Parameter(Mandatory = $true)][string] $Path)
    $executionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function Read-CommandSessionJsonFile {
    param([Parameter(Mandatory = $true)][string] $Path, [Parameter(Mandatory = $true)][string] $Description)
    $resolved = Resolve-CommandSessionPath -Path $Path
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
        throw "$Description file does not exist: $resolved"
    }
    try {
        return (Get-Content -LiteralPath $resolved -Raw | ConvertFrom-Json)
    } catch {
        throw "Invalid $Description JSON in '$resolved': $($_.Exception.Message)"
    }
}

function Copy-CommandSessionObject {
    param([Parameter(Mandatory = $true)][object] $Value)
    return $Value | ConvertTo-Json -Depth 60 | ConvertFrom-Json
}

function Test-CommandSessionProperty {
    param([object] $Object, [Parameter(Mandatory = $true)][string] $Name)
    return ($null -ne $Object -and @($Object.PSObject.Properties | Where-Object { $_.Name -eq $Name }).Count -gt 0)
}

function Assert-CommandSessionString {
    param([Parameter(Mandatory = $true)][object] $Object, [Parameter(Mandatory = $true)][string] $Name, [Parameter(Mandatory = $true)][string] $Context, [bool] $AllowEmpty = $false)
    if (-not (Test-CommandSessionProperty -Object $Object -Name $Name)) {
        throw "$Context validation failed: missing required field '$Name'."
    }
    if (-not ($Object.$Name -is [string])) {
        throw "$Context validation failed: field '$Name' must be a string."
    }
    if (-not $AllowEmpty -and [string]::IsNullOrWhiteSpace([string] $Object.$Name)) {
        throw "$Context validation failed: field '$Name' must not be empty."
    }
}

function Assert-CommandSessionBool {
    param([Parameter(Mandatory = $true)][object] $Object, [Parameter(Mandatory = $true)][string] $Name, [Parameter(Mandatory = $true)][string] $Context)
    if (-not (Test-CommandSessionProperty -Object $Object -Name $Name)) {
        throw "$Context validation failed: missing required field '$Name'."
    }
    if (-not ($Object.$Name -is [bool])) {
        throw "$Context validation failed: field '$Name' must be boolean."
    }
}

function Assert-CommandSessionInteger {
    param([Parameter(Mandatory = $true)][object] $Value, [Parameter(Mandatory = $true)][string] $Context, [Parameter(Mandatory = $true)][string] $Field)
    if (-not ($Value -is [byte] -or $Value -is [int16] -or $Value -is [int] -or $Value -is [long])) {
        throw "$Context validation failed: field '$Field' must be an integer."
    }
}

function Assert-CommandSessionStatus {
    param([Parameter(Mandatory = $true)][string] $Status, [Parameter(Mandatory = $true)][string[]] $Allowed, [Parameter(Mandatory = $true)][string] $Context)
    if ($Status -notin $Allowed) {
        throw "$Context validation failed: unsupported status '$Status'."
    }
}

function Test-CommandSessionSecretLike {
    param([string] $Text)
    return (-not [string]::IsNullOrEmpty($Text) -and $Text -match '(?i)(password=|token=|private key|BEGIN OPENSSH PRIVATE KEY|\.env|api[_-]?key|client[_-]?secret)')
}

function Assert-NoCommandSessionSecrets {
    param([Parameter(Mandatory = $true)][object] $Value, [Parameter(Mandatory = $true)][string] $Context)
    $json = $Value | ConvertTo-Json -Depth 60
    if (Test-CommandSessionSecretLike -Text $json) {
        throw "$Context validation failed: secret-like content is not allowed."
    }
}

function Get-CommandSessionStatuses { return @('created', 'waiting', 'in-progress', 'completed', 'blocked', 'failed', 'cancelled') }
function Get-CommandSessionItemStatuses { return @('pending', 'ready', 'waiting-for-human', 'running', 'completed', 'failed', 'skipped', 'blocked', 'cancelled') }
function Get-CommandSessionActors { return @('automation', 'human-decision', 'human-command', 'review') }
function Get-CommandSessionExecutionModes { return @('none', 'automatic', 'copy-and-run') }
function Get-CommandSessionEventTypes { return @('automation-started', 'automation-result', 'human-decision-submitted', 'human-command-started', 'human-command-result', 'review-result', 'session-cancelled') }

function Assert-AcyclicSessionDependencies {
    param([Parameter(Mandatory = $true)][object[]] $Items)
    $byId = @{}
    foreach ($item in @($Items)) { $byId[[string] $item.itemId] = $item }
    $visiting = @{}
    $visited = @{}
    function Visit-SessionItem {
        param([Parameter(Mandatory = $true)][string] $ItemId)
        if ($visited.ContainsKey($ItemId)) { return }
        if ($visiting.ContainsKey($ItemId)) { throw "Command session validation failed: cyclic dependency detected at item '$ItemId'." }
        $visiting[$ItemId] = $true
        foreach ($dependency in @($byId[$ItemId].dependsOn)) {
            $dependencyId = [string] $dependency
            if (-not [string]::IsNullOrWhiteSpace($dependencyId)) { Visit-SessionItem -ItemId $dependencyId }
        }
        $visiting.Remove($ItemId)
        $visited[$ItemId] = $true
    }
    foreach ($item in @($Items)) { Visit-SessionItem -ItemId ([string] $item.itemId) }
}

function Assert-CommandPlanForSession {
    param([Parameter(Mandatory = $true)][object] $CommandPlan)
    if ($null -eq $CommandPlan) { throw 'Command session validation failed: command plan is missing.' }
    Assert-CommandSessionString -Object $CommandPlan -Name 'schemaVersion' -Context 'Command plan'
    if ($CommandPlan.schemaVersion -ne '0.1') { throw "Command plan validation failed: unsupported schemaVersion '$($CommandPlan.schemaVersion)'." }
    Assert-CommandSessionString -Object $CommandPlan -Name 'commandPlanType' -Context 'Command plan'
    if ($CommandPlan.commandPlanType -ne 'deployment-command-plan') { throw "Command plan validation failed: commandPlanType must be 'deployment-command-plan'." }
    Assert-CommandSessionString -Object $CommandPlan -Name 'status' -Context 'Command plan'
    if ($CommandPlan.status -ne 'ready') { throw "Command plan validation failed: status must be 'ready' before creating a command session." }
    Assert-CommandSessionString -Object $CommandPlan -Name 'selectedAdapterId' -Context 'Command plan'
    $selectedAdapterKey = [string] $CommandPlan.selectedAdapterId
    $adapterCatalog = Get-DeploymentAdapterCatalog
    if (-not $adapterCatalog.Contains($selectedAdapterKey)) { throw "Command plan validation failed: unknown selected adapter id '$($CommandPlan.selectedAdapterId)'." }
    if (-not (Test-CommandSessionProperty -Object $CommandPlan -Name 'executionPolicy')) { throw "Command plan validation failed: missing executionPolicy." }
    Assert-CommandSessionBool -Object $CommandPlan.executionPolicy -Name 'executionAllowed' -Context 'Command plan executionPolicy'
    Assert-CommandSessionBool -Object $CommandPlan.executionPolicy -Name 'automaticExecutionAllowed' -Context 'Command plan executionPolicy'
    if ($CommandPlan.executionPolicy.executionAllowed -or $CommandPlan.executionPolicy.automaticExecutionAllowed) { throw 'Command plan validation failed: execution must not be allowed.' }
    if (-not (Test-CommandSessionProperty -Object $CommandPlan -Name 'commands') -or $null -eq $CommandPlan.commands) { throw 'Command plan validation failed: commands must not be null.' }
    if (-not (Test-CommandSessionProperty -Object $CommandPlan -Name 'humanGates') -or $null -eq $CommandPlan.humanGates) { throw 'Command plan validation failed: humanGates must not be null.' }

    $ids = @{}
    $allItems = @()
    foreach ($gate in @($CommandPlan.humanGates)) {
        Assert-CommandSessionString -Object $gate -Name 'gateId' -Context 'Command plan human gate'
        Assert-CommandSessionString -Object $gate -Name 'stepId' -Context "Command plan human gate '$($gate.gateId)'"
        if (-not (Test-CommandSessionProperty -Object $gate -Name 'sequence')) {
            throw "Command plan human gate '$($gate.gateId)' validation failed: missing required field 'sequence'."
        }
        Assert-CommandSessionInteger -Value $gate.sequence -Context "Command plan human gate '$($gate.gateId)'" -Field 'sequence'
        if (-not (Test-CommandSessionProperty -Object $gate -Name 'dependsOn') -or $null -eq $gate.dependsOn) {
            throw "Command plan human gate '$($gate.gateId)' validation failed: dependsOn must not be null."
        }
        if (-not (Test-CommandSessionProperty -Object $gate -Name 'allowedResponses') -or $null -eq $gate.allowedResponses) {
            throw "Command plan human gate '$($gate.gateId)' validation failed: allowedResponses must not be null."
        }
        if ($ids.ContainsKey([string] $gate.gateId)) { throw "Command plan validation failed: duplicate item id '$($gate.gateId)'." }
        $ids[[string] $gate.gateId] = $true
        $allItems += [pscustomobject]@{ itemId = [string] $gate.gateId; dependsOn = @($gate.dependsOn) }
    }
    foreach ($command in @($CommandPlan.commands)) {
        Assert-CommandSessionString -Object $command -Name 'commandId' -Context 'Command plan command'
        $commandId = [string] $command.commandId
        if ($ids.ContainsKey($commandId)) { throw "Command plan validation failed: duplicate item id '$commandId'." }
        $ids[$commandId] = $true
        Assert-CommandSessionInteger -Value $command.sequence -Context "Command plan command '$commandId'" -Field 'sequence'
        Assert-CommandSessionString -Object $command -Name 'actor' -Context "Command plan command '$commandId'"
        Assert-CommandSessionStatus -Status ([string] $command.actor) -Allowed (Get-CommandSessionActors) -Context "Command plan command '$commandId'"
        Assert-CommandSessionString -Object $command -Name 'executionMode' -Context "Command plan command '$commandId'"
        Assert-CommandSessionStatus -Status ([string] $command.executionMode) -Allowed (Get-CommandSessionExecutionModes) -Context "Command plan command '$commandId'"
        if (-not (Test-CommandSessionProperty -Object $command -Name 'safety') -or $command.safety.executionPermitted) { throw "Command plan command '$commandId' validation failed: executionPermitted must be false." }
        if (-not (Test-CommandSessionProperty -Object $command -Name 'dependsOn') -or $null -eq $command.dependsOn) { throw "Command plan command '$commandId' validation failed: dependsOn must not be null." }
        $allItems += [pscustomobject]@{ itemId = $commandId; dependsOn = @($command.dependsOn) }
    }
    foreach ($item in @($allItems)) {
        foreach ($dependency in @($item.dependsOn)) {
            $dependencyId = [string] $dependency
            if ($dependencyId -eq [string] $item.itemId) { throw "Command plan validation failed: item '$($item.itemId)' depends on itself." }
            if (-not $ids.ContainsKey($dependencyId)) { throw "Command plan validation failed: item '$($item.itemId)' depends on unknown item '$dependencyId'." }
        }
    }
    Assert-AcyclicSessionDependencies -Items @($allItems)
    Assert-NoCommandSessionSecrets -Value $CommandPlan -Context 'Command plan'
}

function New-SessionItemFromCommand {
    param([Parameter(Mandatory = $true)][object] $Command)
    return [pscustomobject]@{
        itemId = [string] $Command.commandId
        commandId = [string] $Command.commandId
        sequence = [int] $Command.sequence
        actor = [string] $Command.actor
        executionMode = [string] $Command.executionMode
        dependsOn = @($Command.dependsOn | ForEach-Object { [string] $_ } | Sort-Object -Unique)
        status = 'pending'
        attempt = 0
        renderedCommand = [string] $Command.renderedCommand
        feedbackRequired = [bool] $Command.feedback.required
        feedback = $null
        decision = $null
        diagnostic = ''
    }
}

function New-SessionItemFromGate {
    param([Parameter(Mandatory = $true)][object] $Gate)
    return [pscustomobject]@{
        itemId = [string] $Gate.gateId
        commandId = [string] $Gate.gateId
        sequence = [int] $Gate.sequence
        actor = 'human-decision'
        executionMode = 'none'
        dependsOn = @($Gate.dependsOn | ForEach-Object { [string] $_ } | Sort-Object -Unique)
        status = 'pending'
        attempt = 0
        renderedCommand = ''
        feedbackRequired = $false
        feedback = $null
        decision = $null
        diagnostic = ''
        gate = Copy-CommandSessionObject -Value $Gate
    }
}

function Resolve-CommandSessionState {
    param([Parameter(Mandatory = $true)][object] $Session)
    if ($Session.status -in @('failed', 'cancelled', 'blocked')) { return $Session }
    $items = @($Session.items | Sort-Object sequence, itemId)
    foreach ($item in $items) {
        if ($item.status -eq 'pending') {
            $ready = $true
            foreach ($dependency in @($item.dependsOn)) {
                $dep = @($items | Where-Object { $_.itemId -eq [string] $dependency } | Select-Object -First 1)[0]
                if ($null -eq $dep -or $dep.status -ne 'completed') { $ready = $false }
            }
            if ($ready) {
                if ($item.actor -eq 'automation') { $item.status = 'ready' } else { $item.status = 'waiting-for-human' }
            }
        }
    }
    $Session.items = @($items | Sort-Object sequence, itemId)
    $failed = @($Session.items | Where-Object { $_.status -eq 'failed' }).Count -gt 0
    $running = @($Session.items | Where-Object { $_.status -eq 'running' }).Count -gt 0
    $active = @($Session.items | Where-Object { $_.status -in @('ready', 'waiting-for-human', 'running') }).Count -gt 0
    $unfinished = @($Session.items | Where-Object { $_.status -notin @('completed', 'skipped') }).Count -gt 0
    if ($failed) { $Session.status = 'failed' }
    elseif (-not $unfinished) { $Session.status = 'completed' }
    elseif ($running) { $Session.status = 'in-progress' }
    elseif ($active -or @($Session.items | Where-Object { $_.status -eq 'pending' }).Count -gt 0) { $Session.status = 'waiting' }
    else { $Session.status = 'blocked' }
    $Session.currentItemId = Get-NextActionableSessionItem -Session $Session
    return $Session
}

function Get-NextActionableSessionItem {
    param([Parameter(Mandatory = $true)][object] $Session)
    $item = @($Session.items | Where-Object { $_.status -in @('ready', 'waiting-for-human', 'running') } | Sort-Object sequence, itemId | Select-Object -First 1)
    if ($item.Count -eq 0) { return '' }
    return [string] $item[0].itemId
}

function New-CommandSession {
    param([Parameter(Mandatory = $true)][object] $CommandPlan)
    Assert-CommandPlanForSession -CommandPlan $CommandPlan
    $items = @(
        foreach ($gate in @($CommandPlan.humanGates)) { New-SessionItemFromGate -Gate $gate }
        foreach ($command in @($CommandPlan.commands)) { New-SessionItemFromCommand -Command $command }
    ) | Sort-Object sequence, itemId
    $session = [pscustomobject]@{
        schemaVersion = '0.1'
        sessionType = 'deployment-command-session'
        status = 'created'
        commandPlanType = [string] $CommandPlan.commandPlanType
        selectedAdapterId = [string] $CommandPlan.selectedAdapterId
        executionPolicy = [pscustomobject]@{
            executionAllowed = $false
            automaticExecutionAllowed = $false
        }
        currentItemId = ''
        items = @($items)
        eventHistory = @()
        diagnostic = ''
    }
    return Resolve-CommandSessionState -Session $session
}

function Assert-CommandSession {
    param([Parameter(Mandatory = $true)][object] $Session)
    Assert-CommandSessionString -Object $Session -Name 'schemaVersion' -Context 'Command session'
    if ($Session.schemaVersion -ne '0.1') { throw "Command session validation failed: unsupported schemaVersion '$($Session.schemaVersion)'." }
    Assert-CommandSessionString -Object $Session -Name 'sessionType' -Context 'Command session'
    if ($Session.sessionType -ne 'deployment-command-session') { throw "Command session validation failed: sessionType must be 'deployment-command-session'." }
    Assert-CommandSessionString -Object $Session -Name 'status' -Context 'Command session'
    Assert-CommandSessionStatus -Status ([string] $Session.status) -Allowed (Get-CommandSessionStatuses) -Context 'Command session'
    if (-not (Test-CommandSessionProperty -Object $Session -Name 'items') -or $null -eq $Session.items) { throw 'Command session validation failed: items must not be null.' }
    if (-not (Test-CommandSessionProperty -Object $Session -Name 'eventHistory') -or $null -eq $Session.eventHistory) { throw 'Command session validation failed: eventHistory must not be null.' }
    $ids = @{}
    foreach ($item in @($Session.items)) {
        Assert-CommandSessionString -Object $item -Name 'itemId' -Context 'Command session item'
        if ($ids.ContainsKey([string] $item.itemId)) { throw "Command session validation failed: duplicate item id '$($item.itemId)'." }
        $ids[[string] $item.itemId] = $true
        Assert-CommandSessionString -Object $item -Name 'status' -Context "Command session item '$($item.itemId)'"
        Assert-CommandSessionStatus -Status ([string] $item.status) -Allowed (Get-CommandSessionItemStatuses) -Context "Command session item '$($item.itemId)'"
        Assert-CommandSessionInteger -Value $item.attempt -Context "Command session item '$($item.itemId)'" -Field 'attempt'
        if ([int] $item.attempt -lt 0) { throw "Command session item '$($item.itemId)' validation failed: attempt must not be negative." }
        if ($item.status -eq 'running') {
            $expectedStartEvent = switch ([string] $item.actor) {
                'automation' { 'automation-started' }
                'human-command' { 'human-command-started' }
                default { '' }
            }
            if ([string]::IsNullOrWhiteSpace($expectedStartEvent)) {
                throw "Command session item '$($item.itemId)' validation failed: actor '$($item.actor)' cannot be running."
            }
            $startEvents = @($Session.eventHistory | Where-Object { $_.targetItemId -eq $item.itemId -and $_.eventType -eq $expectedStartEvent })
            if ($startEvents.Count -eq 0) { throw "Command session item '$($item.itemId)' validation failed: running item requires a start event." }
        }
        if ($item.feedbackRequired -and $item.status -eq 'completed' -and $item.actor -eq 'human-command' -and $null -eq $item.feedback) {
            throw "Command session item '$($item.itemId)' validation failed: completed human command requires feedback."
        }
    }
    foreach ($item in @($Session.items)) {
        foreach ($dependency in @($item.dependsOn)) {
            if (-not $ids.ContainsKey([string] $dependency)) { throw "Command session validation failed: item '$($item.itemId)' depends on unknown item '$dependency'." }
        }
    }
    Assert-AcyclicSessionDependencies -Items @($Session.items)
    $eventIds = @{}
    foreach ($historyEvent in @($Session.eventHistory)) {
        Assert-CommandSessionString -Object $historyEvent -Name 'eventId' -Context 'Command session event history'
        if ($eventIds.ContainsKey([string] $historyEvent.eventId)) { throw "Command session validation failed: duplicate event id '$($historyEvent.eventId)'." }
        $eventIds[[string] $historyEvent.eventId] = $true
    }
    if (-not [string]::IsNullOrWhiteSpace([string] $Session.currentItemId) -and -not $ids.ContainsKey([string] $Session.currentItemId)) {
        throw "Command session validation failed: currentItemId '$($Session.currentItemId)' does not reference an item."
    }
    Assert-NoCommandSessionSecrets -Value $Session -Context 'Command session'
}

function Assert-CommandSessionEvent {
    param([Parameter(Mandatory = $true)][object] $Event, [Parameter(Mandatory = $true)][object] $Session)
    Assert-CommandSessionString -Object $Event -Name 'schemaVersion' -Context 'Command session event'
    if ($Event.schemaVersion -ne '0.1') { throw "Command session event validation failed: unsupported schemaVersion '$($Event.schemaVersion)'." }
    Assert-CommandSessionString -Object $Event -Name 'eventId' -Context 'Command session event'
    Assert-CommandSessionString -Object $Event -Name 'eventType' -Context 'Command session event'
    Assert-CommandSessionStatus -Status ([string] $Event.eventType) -Allowed (Get-CommandSessionEventTypes) -Context 'Command session event'
    if (@($Session.eventHistory | Where-Object { $_.eventId -eq [string] $Event.eventId }).Count -gt 0) { throw "Command session event validation failed: duplicate eventId '$($Event.eventId)'." }
    if ($Event.eventType -ne 'session-cancelled') { Assert-CommandSessionString -Object $Event -Name 'targetItemId' -Context 'Command session event' }
    Assert-NoCommandSessionSecrets -Value $Event -Context 'Command session event'
}

function Add-SessionHistoryEvent {
    param([Parameter(Mandatory = $true)][object] $Session, [Parameter(Mandatory = $true)][object] $Event, [Parameter(Mandatory = $true)][string] $ResultingStatus)
    $history = @($Session.eventHistory)
    $Session.eventHistory = @($history + [pscustomobject]@{
        sequence = ($history.Count + 1)
        eventId = [string] $Event.eventId
        eventType = [string] $Event.eventType
        targetItemId = if (Test-CommandSessionProperty -Object $Event -Name 'targetItemId') { [string] $Event.targetItemId } else { '' }
        resultingStatus = $ResultingStatus
    })
}

function Apply-CommandSessionEvent {
    param([Parameter(Mandatory = $true)][object] $CommandSession, [Parameter(Mandatory = $true)][object] $Event)
    $session = Copy-CommandSessionObject -Value $CommandSession
    $eventCopy = Copy-CommandSessionObject -Value $Event
    Assert-CommandSession -Session $session
    Assert-CommandSessionEvent -Event $eventCopy -Session $session
    if ($session.status -in @('failed', 'cancelled', 'blocked', 'completed')) { throw "Command session event validation failed: terminal session '$($session.status)' cannot be updated." }
    if ($eventCopy.eventType -eq 'session-cancelled') {
        foreach ($item in @($session.items | Where-Object { $_.status -notin @('completed', 'failed', 'cancelled') })) { $item.status = 'cancelled' }
        $session.status = 'cancelled'
        Add-SessionHistoryEvent -Session $session -Event $eventCopy -ResultingStatus 'cancelled'
        return $session
    }
    $matchingItems = @($session.items | Where-Object { $_.itemId -eq [string] $eventCopy.targetItemId } | Select-Object -First 1)
    if ($matchingItems.Count -eq 0) { throw "Command session event validation failed: target item '$($eventCopy.targetItemId)' does not exist." }
    $item = $matchingItems[0]
    if ($item.status -in @('completed', 'failed', 'cancelled')) { throw "Command session event validation failed: target item '$($item.itemId)' is already terminal." }
    switch ([string] $eventCopy.eventType) {
        'automation-started' {
            if ($item.actor -ne 'automation') { throw "Command session event validation failed: automation-started requires automation item." }
            if ($item.status -ne 'ready') { throw "Command session event validation failed: automation item must be ready before start." }
            $item.status = 'running'; $item.attempt = [int] $item.attempt + 1
            Add-SessionHistoryEvent -Session $session -Event $eventCopy -ResultingStatus 'running'
            return Resolve-CommandSessionState -Session $session
        }
        'automation-result' {
            if ($item.actor -ne 'automation') { throw "Command session event validation failed: automation-result requires automation item." }
            if ($item.status -ne 'running') { throw "Command session event validation failed: automation result requires running item." }
            if (-not (Test-CommandSessionProperty -Object $eventCopy -Name 'result')) { throw "Command session event validation failed: result is required." }
            Assert-CommandSessionString -Object $eventCopy.result -Name 'status' -Context 'Command session automation result'
            Assert-CommandSessionStatus -Status ([string] $eventCopy.result.status) -Allowed @('completed', 'failed') -Context 'Command session automation result'
            if (Test-CommandSessionProperty -Object $eventCopy.result -Name 'diagnostic') {
                Assert-CommandSessionString -Object $eventCopy.result -Name 'diagnostic' -Context 'Command session automation result' -AllowEmpty $true
            }
            $item.feedback = Copy-CommandSessionObject -Value $eventCopy.result
            if ($eventCopy.result.status -eq 'completed') { $item.status = 'completed'; Add-SessionHistoryEvent -Session $session -Event $eventCopy -ResultingStatus 'completed'; return Resolve-CommandSessionState -Session $session }
            $item.status = 'failed'; $session.status = 'failed'; Add-SessionHistoryEvent -Session $session -Event $eventCopy -ResultingStatus 'failed'; return $session
        }
        'human-decision-submitted' {
            if ($item.actor -ne 'human-decision') { throw "Command session event validation failed: human decision event requires human-decision item." }
            if ($item.status -ne 'waiting-for-human') { throw "Command session event validation failed: human decision item must be waiting-for-human." }
            if (-not (Test-CommandSessionProperty -Object $eventCopy -Name 'decision')) { throw "Command session event validation failed: decision is required." }
            Assert-CommandSessionString -Object $eventCopy.decision -Name 'value' -Context 'Command session decision'
            $allowed = @($item.gate.allowedResponses | ForEach-Object { [string] $_ })
            if ([string] $eventCopy.decision.value -notin $allowed) { throw "Command session event validation failed: decision '$($eventCopy.decision.value)' is not allowed." }
            $item.decision = Copy-CommandSessionObject -Value $eventCopy.decision
            if ($eventCopy.decision.value -eq 'approved') { $item.status = 'completed'; Add-SessionHistoryEvent -Session $session -Event $eventCopy -ResultingStatus 'completed'; return Resolve-CommandSessionState -Session $session }
            $item.status = 'cancelled'; $session.status = 'cancelled'; Add-SessionHistoryEvent -Session $session -Event $eventCopy -ResultingStatus 'cancelled'; return $session
        }
        'human-command-started' {
            if ($item.actor -ne 'human-command') { throw "Command session event validation failed: human-command-started requires human-command item." }
            if ($item.status -ne 'waiting-for-human') { throw "Command session event validation failed: human command must be waiting-for-human before start." }
            $item.status = 'running'; $item.attempt = [int] $item.attempt + 1
            Add-SessionHistoryEvent -Session $session -Event $eventCopy -ResultingStatus 'running'
            return Resolve-CommandSessionState -Session $session
        }
        'human-command-result' {
            if ($item.actor -ne 'human-command') { throw "Command session event validation failed: human-command-result requires human-command item." }
            if ($item.status -ne 'running') { throw "Command session event validation failed: human command result requires running item." }
            if (-not (Test-CommandSessionProperty -Object $eventCopy -Name 'result')) { throw "Command session event validation failed: result is required." }
            Assert-CommandSessionInteger -Value $eventCopy.result.exitStatus -Context 'Command session command result' -Field 'exitStatus'
            foreach ($field in @('stdout', 'stderr')) { Assert-CommandSessionString -Object $eventCopy.result -Name $field -Context 'Command session command result' -AllowEmpty $true }
            $item.feedback = Copy-CommandSessionObject -Value $eventCopy.result
            if ([int] $eventCopy.result.exitStatus -eq 0) { $item.status = 'completed'; Add-SessionHistoryEvent -Session $session -Event $eventCopy -ResultingStatus 'completed'; return Resolve-CommandSessionState -Session $session }
            $item.status = 'failed'; $session.status = 'failed'; Add-SessionHistoryEvent -Session $session -Event $eventCopy -ResultingStatus 'failed'; return $session
        }
        'review-result' {
            if ($item.actor -ne 'review') { throw "Command session event validation failed: review-result requires review item." }
            if ($item.status -ne 'waiting-for-human') { throw "Command session event validation failed: review item must be waiting-for-human." }
            if (-not (Test-CommandSessionProperty -Object $eventCopy -Name 'review')) { throw "Command session event validation failed: review is required." }
            Assert-CommandSessionString -Object $eventCopy.review -Name 'status' -Context 'Command session review'
            Assert-CommandSessionStatus -Status ([string] $eventCopy.review.status) -Allowed @('approved', 'rejected', 'inconclusive') -Context 'Command session review'
            if ($eventCopy.review.status -eq 'approved') { $item.status = 'completed'; Add-SessionHistoryEvent -Session $session -Event $eventCopy -ResultingStatus 'completed'; return Resolve-CommandSessionState -Session $session }
            if ($eventCopy.review.status -eq 'rejected') { $item.status = 'failed'; $session.status = 'failed'; Add-SessionHistoryEvent -Session $session -Event $eventCopy -ResultingStatus 'failed'; return $session }
            Add-SessionHistoryEvent -Session $session -Event $eventCopy -ResultingStatus 'waiting-for-human'; return Resolve-CommandSessionState -Session $session
        }
    }
}

function Write-CommandSessionJson {
    param([Parameter(Mandatory = $true)][object] $Session, [string] $OutputPath)
    $json = $Session | ConvertTo-Json -Depth 60
    if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
        $resolvedOutputPath = Resolve-CommandSessionPath -Path $OutputPath
        $outputDirectory = Split-Path -Path $resolvedOutputPath -Parent
        if (-not [string]::IsNullOrWhiteSpace($outputDirectory)) { New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null }
        $json | Set-Content -LiteralPath $resolvedOutputPath -Encoding utf8
    }
    return $json
}

function Invoke-SessionCreation {
    param([Parameter(Mandatory = $true)][string] $CommandPlanPath, [string] $OutputPath, [string] $Format = 'Json')
    if ($Format -ne 'Json') { throw "create-command-session only supports -Format Json." }
    $commandPlan = Read-CommandSessionJsonFile -Path $CommandPlanPath -Description 'Command plan'
    $session = New-CommandSession -CommandPlan $commandPlan
    return Write-CommandSessionJson -Session $session -OutputPath $OutputPath
}

function Invoke-SessionUpdate {
    param([Parameter(Mandatory = $true)][string] $CommandSessionPath, [Parameter(Mandatory = $true)][string] $SessionEventPath, [string] $OutputPath, [string] $Format = 'Json')
    if ($Format -ne 'Json') { throw "update-command-session only supports -Format Json." }
    $session = Read-CommandSessionJsonFile -Path $CommandSessionPath -Description 'Command session'
    $event = Read-CommandSessionJsonFile -Path $SessionEventPath -Description 'Command session event'
    $updated = Apply-CommandSessionEvent -CommandSession $session -Event $event
    return Write-CommandSessionJson -Session $updated -OutputPath $OutputPath
}

if ($MyInvocation.InvocationName -ne '.') {
    if ($Operation -eq 'Create') {
        if ([string]::IsNullOrWhiteSpace($CommandPlanPath)) { throw "Missing required parameter for 'create-command-session': -CommandPlanPath" }
        Invoke-SessionCreation -CommandPlanPath $CommandPlanPath -OutputPath $OutputPath -Format $Format
    } else {
        if ([string]::IsNullOrWhiteSpace($CommandSessionPath)) { throw "Missing required parameter for 'update-command-session': -CommandSessionPath" }
        if ([string]::IsNullOrWhiteSpace($SessionEventPath)) { throw "Missing required parameter for 'update-command-session': -SessionEventPath" }
        Invoke-SessionUpdate -CommandSessionPath $CommandSessionPath -SessionEventPath $SessionEventPath -OutputPath $OutputPath -Format $Format
    }
}
