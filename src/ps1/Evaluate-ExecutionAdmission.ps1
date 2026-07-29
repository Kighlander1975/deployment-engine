[CmdletBinding()]
param(
    [string] $CommandPlanPath,
    [string] $CommandSessionPath,
    [string] $OutputPath,
    [string] $Format = 'Json'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-ExecutionAdmissionPath {
    param([Parameter(Mandatory = $true)][string] $Path)
    $executionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function Read-ExecutionAdmissionJsonFile {
    param([Parameter(Mandatory = $true)][string] $Path, [Parameter(Mandatory = $true)][string] $Description)
    $resolved = Resolve-ExecutionAdmissionPath -Path $Path
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
        throw "$Description file does not exist: $resolved"
    }
    try {
        return (Get-Content -LiteralPath $resolved -Raw | ConvertFrom-Json)
    } catch {
        throw "Invalid $Description JSON in '$resolved': $($_.Exception.Message)"
    }
}

function Copy-ExecutionAdmissionObject {
    param([Parameter(Mandatory = $true)][object] $Value)
    return $Value | ConvertTo-Json -Depth 80 | ConvertFrom-Json
}

function Test-ExecutionAdmissionProperty {
    param([object] $Object, [Parameter(Mandatory = $true)][string] $Name)
    return ($null -ne $Object -and @($Object.PSObject.Properties | Where-Object { $_.Name -eq $Name }).Count -gt 0)
}

function Assert-ExecutionAdmissionString {
    param([Parameter(Mandatory = $true)][object] $Object, [Parameter(Mandatory = $true)][string] $Name, [Parameter(Mandatory = $true)][string] $Context, [bool] $AllowEmpty = $false)
    if (-not (Test-ExecutionAdmissionProperty -Object $Object -Name $Name)) { throw "$Context validation failed: missing required field '$Name'." }
    if (-not ($Object.$Name -is [string])) { throw "$Context validation failed: field '$Name' must be a string." }
    if (-not $AllowEmpty -and [string]::IsNullOrWhiteSpace([string] $Object.$Name)) { throw "$Context validation failed: field '$Name' must not be empty." }
}

function Assert-ExecutionAdmissionBool {
    param([Parameter(Mandatory = $true)][object] $Object, [Parameter(Mandatory = $true)][string] $Name, [Parameter(Mandatory = $true)][string] $Context)
    if (-not (Test-ExecutionAdmissionProperty -Object $Object -Name $Name)) { throw "$Context validation failed: missing required field '$Name'." }
    if (-not ($Object.$Name -is [bool])) { throw "$Context validation failed: field '$Name' must be boolean." }
}

function Assert-ExecutionAdmissionInteger {
    param([Parameter(Mandatory = $true)][object] $Value, [Parameter(Mandatory = $true)][string] $Context, [Parameter(Mandatory = $true)][string] $Field)
    if (-not ($Value -is [byte] -or $Value -is [int16] -or $Value -is [int] -or $Value -is [long])) {
        throw "$Context validation failed: field '$Field' must be an integer."
    }
}

function Assert-ExecutionAdmissionStatus {
    param([Parameter(Mandatory = $true)][string] $Status, [Parameter(Mandatory = $true)][string[]] $Allowed, [Parameter(Mandatory = $true)][string] $Context)
    if ($Status -notin $Allowed) { throw "$Context validation failed: unsupported status '$Status'." }
}

function Test-ExecutionAdmissionObjectLike {
    param([object] $Value)
    if ($null -eq $Value -or $Value -is [string] -or $Value -is [System.ValueType]) { return $false }
    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [System.Collections.IDictionary]) -and -not ($Value -is [pscustomobject])) { return $false }
    return ($null -ne $Value.PSObject -and $null -ne $Value.PSObject.Properties)
}

function Test-ExecutionAdmissionSecretLike {
    param([string] $Text)
    return (-not [string]::IsNullOrEmpty($Text) -and $Text -match '(?i)(password=|token=|private key|BEGIN OPENSSH PRIVATE KEY|api[_-]?key|client[_-]?secret)')
}

function Assert-NoExecutionAdmissionSecrets {
    param([Parameter(Mandatory = $true)][object] $Value, [Parameter(Mandatory = $true)][string] $Context)
    $json = $Value | ConvertTo-Json -Depth 80
    if (Test-ExecutionAdmissionSecretLike -Text $json) { throw "$Context validation failed: secret-like content is not allowed." }
}

function Get-ExecutionAdmissionPlanStatuses { return @('ready', 'incomplete') }
function Get-ExecutionAdmissionSessionStatuses { return @('created', 'waiting', 'in-progress', 'completed', 'blocked', 'failed', 'cancelled') }
function Get-ExecutionAdmissionItemStatuses { return @('pending', 'ready', 'waiting-for-human', 'running', 'completed', 'failed', 'skipped', 'blocked', 'cancelled') }
function Get-ExecutionAdmissionActors { return @('automation', 'human-decision', 'human-command', 'review') }
function Get-ExecutionAdmissionLocations { return @('local', 'remote', 'artifact-transport', 'decision', 'review') }
function Get-ExecutionAdmissionModes { return @('none', 'automatic', 'copy-and-run') }
function Get-ExecutionAdmissionPrograms { return @('local-operation', 'interactive-ssh', 'network-share') }
function Get-ExecutionAdmissionEventTypes { return @('automation-started', 'automation-result', 'human-decision-submitted', 'human-command-started', 'human-command-result', 'review-result', 'session-cancelled') }
function Get-ExecutionAdmissionItemEventTypes { return @('automation-started', 'automation-result', 'human-decision-submitted', 'human-command-started', 'human-command-result', 'review-result') }

function Assert-AcyclicExecutionAdmissionDependencies {
    param([Parameter(Mandatory = $true)][object[]] $Items, [string] $Context = 'Execution admission')
    $byId = @{}
    foreach ($item in @($Items)) { $byId[[string] $item.itemId] = $item }
    $visiting = @{}
    $visited = @{}
    function Visit-ExecutionAdmissionItem {
        param([Parameter(Mandatory = $true)][string] $ItemId)
        if ($visited.ContainsKey($ItemId)) { return }
        if ($visiting.ContainsKey($ItemId)) { throw "$Context validation failed: cyclic dependency detected at item '$ItemId'." }
        $visiting[$ItemId] = $true
        foreach ($dependency in @($byId[$ItemId].dependsOn)) {
            $dependencyId = [string] $dependency
            if (-not [string]::IsNullOrWhiteSpace($dependencyId)) { Visit-ExecutionAdmissionItem -ItemId $dependencyId }
        }
        $visiting.Remove($ItemId)
        $visited[$ItemId] = $true
    }
    foreach ($item in @($Items)) { Visit-ExecutionAdmissionItem -ItemId ([string] $item.itemId) }
}

function Assert-CommandPlanForExecutionAdmission {
    param([Parameter(Mandatory = $true)][object] $CommandPlan)
    if ($null -eq $CommandPlan) { throw 'Execution admission validation failed: command plan is missing.' }
    Assert-ExecutionAdmissionString -Object $CommandPlan -Name 'schemaVersion' -Context 'Command plan'
    if ($CommandPlan.schemaVersion -ne '0.1') { throw "Command plan validation failed: unsupported schemaVersion '$($CommandPlan.schemaVersion)'." }
    Assert-ExecutionAdmissionString -Object $CommandPlan -Name 'commandPlanType' -Context 'Command plan'
    if ($CommandPlan.commandPlanType -ne 'deployment-command-plan') { throw "Command plan validation failed: commandPlanType must be 'deployment-command-plan'." }
    Assert-ExecutionAdmissionString -Object $CommandPlan -Name 'status' -Context 'Command plan'
    Assert-ExecutionAdmissionStatus -Status ([string] $CommandPlan.status) -Allowed (Get-ExecutionAdmissionPlanStatuses) -Context 'Command plan'
    Assert-ExecutionAdmissionString -Object $CommandPlan -Name 'selectedAdapterId' -Context 'Command plan'
    if (-not (Test-ExecutionAdmissionProperty -Object $CommandPlan -Name 'executionPolicy') -or -not (Test-ExecutionAdmissionObjectLike -Value $CommandPlan.executionPolicy)) { throw 'Command plan validation failed: missing executionPolicy.' }
    Assert-ExecutionAdmissionBool -Object $CommandPlan.executionPolicy -Name 'executionAllowed' -Context 'Command plan executionPolicy'
    Assert-ExecutionAdmissionBool -Object $CommandPlan.executionPolicy -Name 'automaticExecutionAllowed' -Context 'Command plan executionPolicy'
    if ($CommandPlan.executionPolicy.executionAllowed -or $CommandPlan.executionPolicy.automaticExecutionAllowed) { throw 'Command plan validation failed: execution must remain disabled.' }
    if (-not (Test-ExecutionAdmissionProperty -Object $CommandPlan -Name 'commands') -or $null -eq $CommandPlan.commands) { throw 'Command plan validation failed: commands must not be null.' }
    if (-not (Test-ExecutionAdmissionProperty -Object $CommandPlan -Name 'humanGates') -or $null -eq $CommandPlan.humanGates) { throw 'Command plan validation failed: humanGates must not be null.' }

    $ids = @{}
    $allItems = @()
    foreach ($gate in @($CommandPlan.humanGates)) {
        Assert-ExecutionAdmissionString -Object $gate -Name 'gateId' -Context 'Command plan human gate'
        Assert-ExecutionAdmissionString -Object $gate -Name 'stepId' -Context "Command plan human gate '$($gate.gateId)'"
        Assert-ExecutionAdmissionInteger -Value $gate.sequence -Context "Command plan human gate '$($gate.gateId)'" -Field 'sequence'
        if (-not (Test-ExecutionAdmissionProperty -Object $gate -Name 'dependsOn') -or $null -eq $gate.dependsOn) { throw "Command plan human gate '$($gate.gateId)' validation failed: dependsOn must not be null." }
        if (-not (Test-ExecutionAdmissionProperty -Object $gate -Name 'allowedResponses') -or $null -eq $gate.allowedResponses) { throw "Command plan human gate '$($gate.gateId)' validation failed: allowedResponses must not be null." }
        if ($ids.ContainsKey([string] $gate.gateId)) { throw "Command plan validation failed: duplicate item id '$($gate.gateId)'." }
        $ids[[string] $gate.gateId] = $true
        $allItems += [pscustomobject]@{ itemId = [string] $gate.gateId; dependsOn = @($gate.dependsOn) }
    }
    foreach ($command in @($CommandPlan.commands)) {
        Assert-ExecutionAdmissionString -Object $command -Name 'commandId' -Context 'Command plan command'
        $commandId = [string] $command.commandId
        if ($ids.ContainsKey($commandId)) { throw "Command plan validation failed: duplicate item id '$commandId'." }
        $ids[$commandId] = $true
        Assert-ExecutionAdmissionInteger -Value $command.sequence -Context "Command plan command '$commandId'" -Field 'sequence'
        Assert-ExecutionAdmissionString -Object $command -Name 'actor' -Context "Command plan command '$commandId'"
        Assert-ExecutionAdmissionStatus -Status ([string] $command.actor) -Allowed (Get-ExecutionAdmissionActors) -Context "Command plan command '$commandId'"
        Assert-ExecutionAdmissionString -Object $command -Name 'executionLocation' -Context "Command plan command '$commandId'"
        Assert-ExecutionAdmissionStatus -Status ([string] $command.executionLocation) -Allowed (Get-ExecutionAdmissionLocations) -Context "Command plan command '$commandId'"
        Assert-ExecutionAdmissionString -Object $command -Name 'executionMode' -Context "Command plan command '$commandId'"
        Assert-ExecutionAdmissionStatus -Status ([string] $command.executionMode) -Allowed (Get-ExecutionAdmissionModes) -Context "Command plan command '$commandId'"
        Assert-ExecutionAdmissionString -Object $command -Name 'program' -Context "Command plan command '$commandId'"
        Assert-ExecutionAdmissionStatus -Status ([string] $command.program) -Allowed (Get-ExecutionAdmissionPrograms) -Context "Command plan command '$commandId'"
        Assert-ExecutionAdmissionString -Object $command -Name 'renderedCommand' -Context "Command plan command '$commandId'" -AllowEmpty $true
        if (-not (Test-ExecutionAdmissionProperty -Object $command -Name 'safety') -or -not (Test-ExecutionAdmissionObjectLike -Value $command.safety)) { throw "Command plan command '$commandId' validation failed: missing safety." }
        Assert-ExecutionAdmissionBool -Object $command.safety -Name 'executionPermitted' -Context "Command plan command '$commandId' safety"
        if ($command.safety.executionPermitted) { throw "Command plan command '$commandId' validation failed: executionPermitted must remain false." }
        if (-not (Test-ExecutionAdmissionProperty -Object $command -Name 'dependsOn') -or $null -eq $command.dependsOn) { throw "Command plan command '$commandId' validation failed: dependsOn must not be null." }
        if (-not (Test-ExecutionAdmissionProperty -Object $command -Name 'feedback') -or -not (Test-ExecutionAdmissionObjectLike -Value $command.feedback)) { throw "Command plan command '$commandId' validation failed: missing feedback." }
        Assert-ExecutionAdmissionBool -Object $command.feedback -Name 'required' -Context "Command plan command '$commandId' feedback"
        $allItems += [pscustomobject]@{ itemId = $commandId; dependsOn = @($command.dependsOn) }
    }
    foreach ($item in @($allItems)) {
        foreach ($dependency in @($item.dependsOn)) {
            $dependencyId = [string] $dependency
            if ($dependencyId -eq [string] $item.itemId) { throw "Command plan validation failed: item '$($item.itemId)' depends on itself." }
            if (-not $ids.ContainsKey($dependencyId)) { throw "Command plan validation failed: item '$($item.itemId)' depends on unknown item '$dependencyId'." }
        }
    }
    Assert-AcyclicExecutionAdmissionDependencies -Items @($allItems) -Context 'Command plan'
    Assert-NoExecutionAdmissionSecrets -Value $CommandPlan -Context 'Command plan'
}

function Assert-CommandSessionForExecutionAdmission {
    param([Parameter(Mandatory = $true)][object] $CommandSession)
    if ($null -eq $CommandSession) { throw 'Execution admission validation failed: command session is missing.' }
    Assert-ExecutionAdmissionString -Object $CommandSession -Name 'schemaVersion' -Context 'Command session'
    if ($CommandSession.schemaVersion -ne '0.1') { throw "Command session validation failed: unsupported schemaVersion '$($CommandSession.schemaVersion)'." }
    Assert-ExecutionAdmissionString -Object $CommandSession -Name 'sessionType' -Context 'Command session'
    if ($CommandSession.sessionType -ne 'deployment-command-session') { throw "Command session validation failed: sessionType must be 'deployment-command-session'." }
    Assert-ExecutionAdmissionString -Object $CommandSession -Name 'status' -Context 'Command session'
    Assert-ExecutionAdmissionStatus -Status ([string] $CommandSession.status) -Allowed (Get-ExecutionAdmissionSessionStatuses) -Context 'Command session'
    Assert-ExecutionAdmissionString -Object $CommandSession -Name 'commandPlanType' -Context 'Command session'
    Assert-ExecutionAdmissionString -Object $CommandSession -Name 'selectedAdapterId' -Context 'Command session'
    Assert-ExecutionAdmissionString -Object $CommandSession -Name 'currentItemId' -Context 'Command session' -AllowEmpty $true
    if (-not (Test-ExecutionAdmissionProperty -Object $CommandSession -Name 'items') -or $null -eq $CommandSession.items) { throw 'Command session validation failed: items must not be null.' }
    if (-not (Test-ExecutionAdmissionProperty -Object $CommandSession -Name 'eventHistory') -or $null -eq $CommandSession.eventHistory) { throw 'Command session validation failed: eventHistory must not be null.' }
    $ids = @{}
    foreach ($item in @($CommandSession.items)) {
        Assert-ExecutionAdmissionString -Object $item -Name 'itemId' -Context 'Command session item'
        if ($ids.ContainsKey([string] $item.itemId)) { throw "Command session validation failed: duplicate item id '$($item.itemId)'." }
        $ids[[string] $item.itemId] = $true
        Assert-ExecutionAdmissionString -Object $item -Name 'commandId' -Context "Command session item '$($item.itemId)'"
        Assert-ExecutionAdmissionInteger -Value $item.sequence -Context "Command session item '$($item.itemId)'" -Field 'sequence'
        Assert-ExecutionAdmissionString -Object $item -Name 'actor' -Context "Command session item '$($item.itemId)'"
        Assert-ExecutionAdmissionStatus -Status ([string] $item.actor) -Allowed (Get-ExecutionAdmissionActors) -Context "Command session item '$($item.itemId)'"
        Assert-ExecutionAdmissionString -Object $item -Name 'executionMode' -Context "Command session item '$($item.itemId)'"
        Assert-ExecutionAdmissionStatus -Status ([string] $item.executionMode) -Allowed (Get-ExecutionAdmissionModes) -Context "Command session item '$($item.itemId)'"
        Assert-ExecutionAdmissionString -Object $item -Name 'status' -Context "Command session item '$($item.itemId)'"
        Assert-ExecutionAdmissionStatus -Status ([string] $item.status) -Allowed (Get-ExecutionAdmissionItemStatuses) -Context "Command session item '$($item.itemId)'"
        Assert-ExecutionAdmissionInteger -Value $item.attempt -Context "Command session item '$($item.itemId)'" -Field 'attempt'
        if (-not (Test-ExecutionAdmissionProperty -Object $item -Name 'dependsOn') -or $null -eq $item.dependsOn) { throw "Command session item '$($item.itemId)' validation failed: dependsOn must not be null." }
        if (-not (Test-ExecutionAdmissionProperty -Object $item -Name 'feedbackRequired')) { throw "Command session item '$($item.itemId)' validation failed: missing feedbackRequired." }
        if (-not ($item.feedbackRequired -is [bool])) { throw "Command session item '$($item.itemId)' validation failed: feedbackRequired must be boolean." }
    }
    foreach ($item in @($CommandSession.items)) {
        foreach ($dependency in @($item.dependsOn)) {
            $dependencyId = [string] $dependency
            if (-not $ids.ContainsKey($dependencyId)) { throw "Command session validation failed: item '$($item.itemId)' depends on unknown item '$dependencyId'." }
            $dependencyItem = @($CommandSession.items | Where-Object { $_.itemId -eq $dependencyId } | Select-Object -First 1)[0]
            if ($item.status -eq 'ready' -and $dependencyItem.status -ne 'completed') { throw "Command session validation failed: ready item '$($item.itemId)' has open dependency '$dependencyId'." }
        }
    }
    Assert-AcyclicExecutionAdmissionDependencies -Items @($CommandSession.items) -Context 'Command session'
    if (-not [string]::IsNullOrWhiteSpace([string] $CommandSession.currentItemId) -and -not $ids.ContainsKey([string] $CommandSession.currentItemId)) {
        throw "Command session validation failed: currentItemId '$($CommandSession.currentItemId)' does not reference an item."
    }
    Assert-ExecutionAdmissionEventHistory -CommandSession $CommandSession
    Assert-NoExecutionAdmissionSecrets -Value $CommandSession -Context 'Command session'
}

function New-ExecutionAdmissionPolicy {
    return [pscustomobject]@{
        productiveExecutionAllowed = $false
        processStartAllowed = $false
        networkAccessAllowed = $false
        remoteExecutionAllowed = $false
    }
}

function New-ExecutionAdmissionDecision {
    param([bool] $Eligible, [string] $Actor = '', [string] $Location = '', [string] $Mode = '', [string] $Program = '')
    return [pscustomobject]@{
        executionAdmitted = $false
        executionEligible = $Eligible
        executionScope = 'local-only'
        actor = $Actor
        executionLocation = $Location
        executionMode = $Mode
        program = $Program
    }
}

function New-ExecutionAdmissionRequirements {
    param([bool] $Ready, [bool] $DependenciesCompleted, [bool] $ApprovalSatisfied, [bool] $ExecutionPermittedByPlan)
    return [pscustomobject]@{
        sessionItemReady = $Ready
        dependenciesCompleted = $DependenciesCompleted
        humanApprovalSatisfied = $ApprovalSatisfied
        executionPermittedByCommandPlan = $ExecutionPermittedByPlan
        executorImplementationAvailable = $false
    }
}

function New-ExecutionAdmissionResult {
    param(
        [Parameter(Mandatory = $true)][string] $Status,
        [Parameter(Mandatory = $true)][string] $SessionStatus,
        [string] $CurrentItemId = '',
        [string] $CommandId = '',
        [object] $Decision = (New-ExecutionAdmissionDecision -Eligible:$false),
        [object] $Requirements = (New-ExecutionAdmissionRequirements -Ready:$false -DependenciesCompleted:$false -ApprovalSatisfied:$false -ExecutionPermittedByPlan:$false),
        [object] $Handoff = ([pscustomobject]@{ type = 'none' }),
        [string] $Diagnostic = ''
    )
    return [pscustomobject]@{
        schemaVersion = '0.1'
        admissionType = 'execution-admission'
        status = $Status
        sessionStatus = $SessionStatus
        currentItemId = $CurrentItemId
        commandId = $CommandId
        decision = $Decision
        requirements = $Requirements
        handoff = $Handoff
        executionPolicy = New-ExecutionAdmissionPolicy
        diagnostic = $Diagnostic
    }
}

function Get-ExecutionAdmissionPlanItems {
    param([Parameter(Mandatory = $true)][object] $CommandPlan)
    $items = @(
        foreach ($gate in @($CommandPlan.humanGates | Sort-Object gateId)) {
            [pscustomobject]@{
                itemId = [string] $gate.gateId
                commandId = [string] $gate.gateId
                sourceKind = 'humanGate'
                stepId = [string] $gate.stepId
                sequence = [int] $gate.sequence
                actor = 'human-decision'
                executionLocation = 'decision'
                executionMode = 'none'
                dependsOn = @($gate.dependsOn | ForEach-Object { [string] $_ } | Sort-Object -Unique)
                program = ''
                renderedCommand = ''
                feedbackRequired = $false
                executionPermitted = $false
                gateType = if (Test-ExecutionAdmissionProperty -Object $gate -Name 'gateType') { [string] $gate.gateType } else { '' }
                allowedResponses = @($gate.allowedResponses | ForEach-Object { [string] $_ })
            }
        }
        foreach ($command in @($CommandPlan.commands | Sort-Object commandId)) {
            [pscustomobject]@{
                itemId = [string] $command.commandId
                commandId = [string] $command.commandId
                sourceKind = 'command'
                stepId = if (Test-ExecutionAdmissionProperty -Object $command -Name 'strategyStepId') { [string] $command.strategyStepId } else { [string] $command.commandId }
                sequence = [int] $command.sequence
                actor = [string] $command.actor
                executionLocation = [string] $command.executionLocation
                executionMode = [string] $command.executionMode
                dependsOn = @($command.dependsOn | ForEach-Object { [string] $_ } | Sort-Object -Unique)
                program = [string] $command.program
                renderedCommand = [string] $command.renderedCommand
                feedbackRequired = [bool] $command.feedback.required
                executionPermitted = [bool] $command.safety.executionPermitted
                gateType = ''
                allowedResponses = @()
            }
        }
    )
    return @($items | Sort-Object itemId)
}

function Get-ExecutionAdmissionSessionItems {
    param([Parameter(Mandatory = $true)][object] $CommandSession)
    return @(
        foreach ($item in @($CommandSession.items | Sort-Object itemId)) {
            [pscustomobject]@{
                itemId = [string] $item.itemId
                commandId = [string] $item.commandId
                sequence = [int] $item.sequence
                actor = [string] $item.actor
                executionMode = [string] $item.executionMode
                dependsOn = @($item.dependsOn | ForEach-Object { [string] $_ } | Sort-Object -Unique)
                renderedCommand = [string] $item.renderedCommand
                feedbackRequired = [bool] $item.feedbackRequired
                status = [string] $item.status
                gateType = if ((Test-ExecutionAdmissionProperty -Object $item -Name 'gate') -and $null -ne $item.gate -and (Test-ExecutionAdmissionProperty -Object $item.gate -Name 'gateType')) { [string] $item.gate.gateType } else { '' }
                allowedResponses = if ((Test-ExecutionAdmissionProperty -Object $item -Name 'gate') -and $null -ne $item.gate -and (Test-ExecutionAdmissionProperty -Object $item.gate -Name 'allowedResponses')) { @($item.gate.allowedResponses | ForEach-Object { [string] $_ }) } else { @() }
            }
        }
    )
}

function Get-ExecutionAdmissionPlanItemById {
    param([Parameter(Mandatory = $true)][object[]] $PlanItems, [Parameter(Mandatory = $true)][string] $ItemId)
    $item = @($PlanItems | Where-Object { $_.itemId -eq $ItemId } | Select-Object -First 1)
    if ($item.Count -eq 0) { return $null }
    return $item[0]
}

function Get-ExecutionAdmissionSessionItemById {
    param([Parameter(Mandatory = $true)][object[]] $SessionItems, [Parameter(Mandatory = $true)][string] $ItemId)
    $item = @($SessionItems | Where-Object { $_.itemId -eq $ItemId } | Select-Object -First 1)
    if ($item.Count -eq 0) { return $null }
    return $item[0]
}

function Test-ExecutionAdmissionItemMatch {
    param([Parameter(Mandatory = $true)][object] $PlanItem, [Parameter(Mandatory = $true)][object] $SessionItem, [ref] $Diagnostic)
    foreach ($field in @('commandId', 'sequence', 'actor', 'executionMode', 'renderedCommand', 'feedbackRequired')) {
        if ([string] $PlanItem.$field -ne [string] $SessionItem.$field) {
            $Diagnostic.Value = "Command plan and command session differ: item '$($SessionItem.itemId)' field '$field'."
            return $false
        }
    }
    $planDependencies = (@($PlanItem.dependsOn | ForEach-Object { [string] $_ } | Sort-Object -Unique) -join ',')
    $sessionDependencies = (@($SessionItem.dependsOn | ForEach-Object { [string] $_ } | Sort-Object -Unique) -join ',')
    if ($planDependencies -ne $sessionDependencies) {
        $Diagnostic.Value = "Command plan and command session differ: item '$($SessionItem.itemId)' field 'dependsOn'."
        return $false
    }
    if ($PlanItem.actor -eq 'human-decision') {
        if ($PlanItem.gateType -ne $SessionItem.gateType) {
            $Diagnostic.Value = "Command plan and command session differ: human gate '$($SessionItem.itemId)' field 'gateType'."
            return $false
        }
        $planResponses = (@($PlanItem.allowedResponses | ForEach-Object { [string] $_ }) -join ',')
        $sessionResponses = (@($SessionItem.allowedResponses | ForEach-Object { [string] $_ }) -join ',')
        if ($planResponses -ne $sessionResponses) {
            $Diagnostic.Value = "Command plan and command session differ: human gate '$($SessionItem.itemId)' field 'allowedResponses'."
            return $false
        }
    }
    return $true
}

function Assert-ExecutionAdmissionCrossConsistency {
    param([Parameter(Mandatory = $true)][object] $CommandPlan, [Parameter(Mandatory = $true)][object] $CommandSession)
    if ([string] $CommandPlan.selectedAdapterId -ne [string] $CommandSession.selectedAdapterId -or [string] $CommandPlan.commandPlanType -ne [string] $CommandSession.commandPlanType) {
        return 'Command plan and command session differ: identity fields.'
    }
    $planItems = @(Get-ExecutionAdmissionPlanItems -CommandPlan $CommandPlan)
    $sessionItems = @(Get-ExecutionAdmissionSessionItems -CommandSession $CommandSession)
    $planIds = @($planItems | ForEach-Object { [string] $_.itemId } | Sort-Object)
    $sessionIds = @($sessionItems | ForEach-Object { [string] $_.itemId } | Sort-Object)
    foreach ($planId in $planIds) {
        if ($sessionIds -notcontains $planId) { return "Command plan and command session differ: missing session item '$planId'." }
    }
    foreach ($sessionId in $sessionIds) {
        if ($planIds -notcontains $sessionId) { return "Command plan and command session differ: unexpected session item '$sessionId'." }
    }
    foreach ($planItem in @($planItems | Sort-Object itemId)) {
        $sessionItem = Get-ExecutionAdmissionSessionItemById -SessionItems $sessionItems -ItemId ([string] $planItem.itemId)
        $diagnostic = ''
        if (-not (Test-ExecutionAdmissionItemMatch -PlanItem $planItem -SessionItem $sessionItem -Diagnostic ([ref] $diagnostic))) { return $diagnostic }
    }
    return ''
}

function Get-ExecutionAdmissionEventTarget {
    param([Parameter(Mandatory = $true)][object] $Event)
    if ([string] $Event.eventType -eq 'session-cancelled') { return '' }
    Assert-ExecutionAdmissionString -Object $Event -Name 'targetItemId' -Context 'Command session event history'
    return [string] $Event.targetItemId
}

function Assert-ExecutionAdmissionAutomationEvent {
    param([Parameter(Mandatory = $true)][object] $Event, [Parameter(Mandatory = $true)][object] $Item)
    if ($Item.actor -ne 'automation') { throw "Command session event history validation failed: event '$($Event.eventId)' type '$($Event.eventType)' does not match actor '$($Item.actor)' for item '$($Item.itemId)'." }
    if ($Event.eventType -eq 'automation-result') {
        if (Test-ExecutionAdmissionProperty -Object $Event -Name 'result') {
            Assert-ExecutionAdmissionString -Object $Event.result -Name 'status' -Context "Command session automation event '$($Event.eventId)' result"
            Assert-ExecutionAdmissionStatus -Status ([string] $Event.result.status) -Allowed @('completed', 'failed') -Context "Command session automation event '$($Event.eventId)' result"
        }
    }
}

function Assert-ExecutionAdmissionHumanCommandEvent {
    param([Parameter(Mandatory = $true)][object] $Event, [Parameter(Mandatory = $true)][object] $Item)
    if ($Item.actor -ne 'human-command') { throw "Command session event history validation failed: event '$($Event.eventId)' type '$($Event.eventType)' does not match actor '$($Item.actor)' for item '$($Item.itemId)'." }
    if ($Event.eventType -eq 'human-command-result') {
        if (Test-ExecutionAdmissionProperty -Object $Event -Name 'result') {
            if (-not (Test-ExecutionAdmissionProperty -Object $Event.result -Name 'exitStatus')) { throw "Command session human command event '$($Event.eventId)' result validation failed: missing required field 'exitStatus'." }
            Assert-ExecutionAdmissionInteger -Value $Event.result.exitStatus -Context "Command session human command event '$($Event.eventId)' result" -Field 'exitStatus'
            foreach ($field in @('stdout', 'stderr')) {
                Assert-ExecutionAdmissionString -Object $Event.result -Name $field -Context "Command session human command event '$($Event.eventId)' result" -AllowEmpty $true
            }
        }
    }
}

function Assert-ExecutionAdmissionHumanDecisionEvent {
    param([Parameter(Mandatory = $true)][object] $Event, [Parameter(Mandatory = $true)][object] $Item)
    if ($Item.actor -ne 'human-decision') { throw "Command session event history validation failed: event '$($Event.eventId)' type '$($Event.eventType)' does not match actor '$($Item.actor)' for item '$($Item.itemId)'." }
    if (Test-ExecutionAdmissionProperty -Object $Event -Name 'decision') {
        Assert-ExecutionAdmissionString -Object $Event.decision -Name 'value' -Context "Command session decision event '$($Event.eventId)'"
        $allowed = @()
        if ((Test-ExecutionAdmissionProperty -Object $Item -Name 'gate') -and $null -ne $Item.gate -and (Test-ExecutionAdmissionProperty -Object $Item.gate -Name 'allowedResponses')) {
            $allowed = @($Item.gate.allowedResponses | ForEach-Object { [string] $_ })
        }
        if ($allowed.Count -eq 0 -or [string] $Event.decision.value -notin $allowed) { throw "Command session event history validation failed: decision '$($Event.decision.value)' is not allowed for item '$($Item.itemId)'." }
    }
}

function Assert-ExecutionAdmissionReviewEvent {
    param([Parameter(Mandatory = $true)][object] $Event, [Parameter(Mandatory = $true)][object] $Item)
    if ($Item.actor -ne 'review') { throw "Command session event history validation failed: event '$($Event.eventId)' type '$($Event.eventType)' does not match actor '$($Item.actor)' for item '$($Item.itemId)'." }
    if (Test-ExecutionAdmissionProperty -Object $Event -Name 'review') {
        Assert-ExecutionAdmissionString -Object $Event.review -Name 'status' -Context "Command session review event '$($Event.eventId)'"
        Assert-ExecutionAdmissionStatus -Status ([string] $Event.review.status) -Allowed @('approved', 'rejected', 'inconclusive') -Context "Command session review event '$($Event.eventId)'"
    }
}

function Assert-ExecutionAdmissionEventHistory {
    param([Parameter(Mandatory = $true)][object] $CommandSession)
    $itemsById = @{}
    foreach ($item in @($CommandSession.items)) { $itemsById[[string] $item.itemId] = $item }
    $eventIds = @{}
    $cancelSeen = $false
    $cancelCount = 0
    $itemState = @{}
    foreach ($item in @($CommandSession.items)) {
        $itemState[[string] $item.itemId] = [pscustomobject]@{
            startCount = 0
            resultCount = 0
            decisionCount = 0
            reviewCount = 0
            startEventType = ''
            resultEventType = ''
            resultStatus = ''
            exitStatus = $null
            decisionValue = ''
            reviewStatus = ''
            terminalSeen = $false
        }
    }
    $expectedSequence = 1
    foreach ($event in @($CommandSession.eventHistory)) {
        Assert-ExecutionAdmissionString -Object $event -Name 'eventId' -Context 'Command session event history'
        Assert-ExecutionAdmissionString -Object $event -Name 'eventType' -Context 'Command session event history'
        Assert-ExecutionAdmissionStatus -Status ([string] $event.eventType) -Allowed (Get-ExecutionAdmissionEventTypes) -Context 'Command session event history'
        if ($eventIds.ContainsKey([string] $event.eventId)) { throw "Command session validation failed: duplicate event id '$($event.eventId)'." }
        $eventIds[[string] $event.eventId] = $true
        if (Test-ExecutionAdmissionProperty -Object $event -Name 'sequence') {
            Assert-ExecutionAdmissionInteger -Value $event.sequence -Context "Command session event '$($event.eventId)'" -Field 'sequence'
            if ([int] $event.sequence -ne $expectedSequence) { throw "Command session event history validation failed: event '$($event.eventId)' has invalid sequence." }
        }
        $expectedSequence++
        if ($cancelSeen) { throw "Command session event history validation failed: event '$($event.eventId)' appears after session-cancelled." }
        if ($event.eventType -eq 'session-cancelled') {
            $cancelSeen = $true
            $cancelCount++
            if ($cancelCount -gt 1) { throw 'Command session event history validation failed: duplicate session-cancelled event.' }
            continue
        }
        $targetId = Get-ExecutionAdmissionEventTarget -Event $event
        if (-not $itemsById.ContainsKey($targetId)) { throw "Command session event history validation failed: event '$($event.eventId)' targets unknown item '$targetId'." }
        $item = $itemsById[$targetId]
        $state = $itemState[$targetId]
        if ($state.terminalSeen) { throw "Command session event history validation failed: event '$($event.eventId)' appears after terminal event for item '$targetId'." }
        switch ([string] $event.eventType) {
            'automation-started' {
                Assert-ExecutionAdmissionAutomationEvent -Event $event -Item $item
                $state.startCount++
                if ($state.startCount -gt 1) { throw "Command session event history validation failed: duplicate automation-started event for item '$targetId'." }
                if ($state.resultCount -gt 0) { throw "Command session event history validation failed: automation-started event appears after result for item '$targetId'." }
                $state.startEventType = 'automation-started'
            }
            'automation-result' {
                Assert-ExecutionAdmissionAutomationEvent -Event $event -Item $item
                if ($state.startCount -ne 1) { throw "Command session event history validation failed: automation-result event for item '$targetId' requires a prior automation-started event." }
                $state.resultCount++
                if ($state.resultCount -gt 1) { throw "Command session event history validation failed: duplicate automation-result event for item '$targetId'." }
                $state.resultEventType = 'automation-result'
                $hasItemFeedbackStatus = ((Test-ExecutionAdmissionProperty -Object $item -Name 'feedback') -and $null -ne $item.feedback -and (Test-ExecutionAdmissionProperty -Object $item.feedback -Name 'status'))
                $state.resultStatus = if (Test-ExecutionAdmissionProperty -Object $event -Name 'result') { [string] $event.result.status } elseif ($hasItemFeedbackStatus) { [string] $item.feedback.status } elseif (Test-ExecutionAdmissionProperty -Object $event -Name 'resultingStatus') { [string] $event.resultingStatus } else { '' }
                $state.terminalSeen = $true
            }
            'human-command-started' {
                Assert-ExecutionAdmissionHumanCommandEvent -Event $event -Item $item
                $state.startCount++
                if ($state.startCount -gt 1) { throw "Command session event history validation failed: duplicate human-command-started event for item '$targetId'." }
                if ($state.resultCount -gt 0) { throw "Command session event history validation failed: human-command-started event appears after result for item '$targetId'." }
                $state.startEventType = 'human-command-started'
            }
            'human-command-result' {
                Assert-ExecutionAdmissionHumanCommandEvent -Event $event -Item $item
                if ($state.startCount -ne 1) { throw "Command session event history validation failed: human-command-result event for item '$targetId' requires a prior human-command-started event." }
                $state.resultCount++
                if ($state.resultCount -gt 1) { throw "Command session event history validation failed: duplicate human-command-result event for item '$targetId'." }
                $state.resultEventType = 'human-command-result'
                $hasItemFeedbackExitStatus = ((Test-ExecutionAdmissionProperty -Object $item -Name 'feedback') -and $null -ne $item.feedback -and (Test-ExecutionAdmissionProperty -Object $item.feedback -Name 'exitStatus'))
                $state.exitStatus = if (Test-ExecutionAdmissionProperty -Object $event -Name 'result') { [int] $event.result.exitStatus } elseif ($hasItemFeedbackExitStatus) { [int] $item.feedback.exitStatus } else { $null }
                $state.terminalSeen = $true
            }
            'human-decision-submitted' {
                Assert-ExecutionAdmissionHumanDecisionEvent -Event $event -Item $item
                $state.decisionCount++
                if ($state.decisionCount -gt 1) { throw "Command session event history validation failed: duplicate human-decision-submitted event for item '$targetId'." }
                $hasItemDecisionValue = ((Test-ExecutionAdmissionProperty -Object $item -Name 'decision') -and $null -ne $item.decision -and (Test-ExecutionAdmissionProperty -Object $item.decision -Name 'value'))
                $state.decisionValue = if (Test-ExecutionAdmissionProperty -Object $event -Name 'decision') { [string] $event.decision.value } elseif ($hasItemDecisionValue) { [string] $item.decision.value } elseif ((Test-ExecutionAdmissionProperty -Object $event -Name 'resultingStatus') -and [string] $event.resultingStatus -eq 'completed') { 'approved' } elseif ((Test-ExecutionAdmissionProperty -Object $event -Name 'resultingStatus') -and [string] $event.resultingStatus -eq 'cancelled') { 'rejected' } else { '' }
                $state.terminalSeen = $true
            }
            'review-result' {
                Assert-ExecutionAdmissionReviewEvent -Event $event -Item $item
                $state.reviewCount++
                if ($state.reviewCount -gt 1) { throw "Command session event history validation failed: duplicate review-result event for item '$targetId'." }
                $state.reviewStatus = if (Test-ExecutionAdmissionProperty -Object $event -Name 'review') { [string] $event.review.status } elseif (Test-ExecutionAdmissionProperty -Object $event -Name 'resultingStatus') {
                    if ([string] $event.resultingStatus -eq 'completed') { 'approved' } elseif ([string] $event.resultingStatus -eq 'failed') { 'rejected' } else { 'inconclusive' }
                } else { '' }
                if ($state.reviewStatus -in @('approved', 'rejected')) { $state.terminalSeen = $true }
            }
        }
    }
    if ($cancelSeen) {
        if ($CommandSession.status -ne 'cancelled') { throw 'Command session event history validation failed: session-cancelled requires session status cancelled.' }
    }
    foreach ($item in @($CommandSession.items)) {
        Assert-ExecutionAdmissionItemEventConsistency -Item $item -State $itemState[[string] $item.itemId] -SessionStatus ([string] $CommandSession.status)
    }
}

function Assert-ExecutionAdmissionItemEventConsistency {
    param([Parameter(Mandatory = $true)][object] $Item, [Parameter(Mandatory = $true)][object] $State, [Parameter(Mandatory = $true)][string] $SessionStatus)
    $itemId = [string] $Item.itemId
    switch ([string] $Item.actor) {
        'automation' {
            if ($Item.status -eq 'cancelled' -and $SessionStatus -eq 'cancelled') {
                if ($State.resultCount -ne 0 -or $State.startCount -gt 1) { throw "Command session item '$itemId' validation failed: cancelled automation item must not have completed result history." }
                return
            }
            if ($Item.status -in @('pending', 'ready', 'waiting-for-human') -and ($State.startCount -gt 0 -or $State.resultCount -gt 0)) { throw "Command session item '$itemId' validation failed: non-started automation item has execution event history." }
            if ($Item.status -eq 'running' -and -not ($State.startCount -eq 1 -and $State.resultCount -eq 0)) { throw "Command session item '$itemId' validation failed: running automation item requires exactly one start event and no result event." }
            if ($Item.status -eq 'completed' -and -not ($State.startCount -eq 1 -and $State.resultCount -eq 1 -and $State.resultStatus -eq 'completed')) { throw "Command session item '$itemId' validation failed: completed automation item requires successful automation-result event." }
            if ($Item.status -eq 'failed' -and -not ($State.startCount -eq 1 -and $State.resultCount -eq 1 -and $State.resultStatus -eq 'failed')) { throw "Command session item '$itemId' validation failed: failed automation item requires failed automation-result event." }
        }
        'human-command' {
            if ($Item.status -eq 'cancelled' -and $SessionStatus -eq 'cancelled') {
                if ($State.resultCount -ne 0 -or $State.startCount -gt 1) { throw "Command session item '$itemId' validation failed: cancelled human-command item must not have completed result history." }
                return
            }
            if ($Item.status -in @('pending', 'ready', 'waiting-for-human') -and ($State.startCount -gt 0 -or $State.resultCount -gt 0)) { throw "Command session item '$itemId' validation failed: non-started human-command item has command event history." }
            if ($Item.status -eq 'running' -and -not ($State.startCount -eq 1 -and $State.resultCount -eq 0)) { throw "Command session item '$itemId' validation failed: running human-command item requires exactly one start event and no result event." }
            if ($Item.status -eq 'completed' -and -not ($State.startCount -eq 1 -and $State.resultCount -eq 1 -and [int] $State.exitStatus -eq 0)) { throw "Command session item '$itemId' validation failed: completed human-command item requires exitStatus 0." }
            if ($Item.status -eq 'failed' -and -not ($State.startCount -eq 1 -and $State.resultCount -eq 1 -and [int] $State.exitStatus -ne 0)) { throw "Command session item '$itemId' validation failed: failed human-command item requires non-zero exitStatus." }
        }
        'human-decision' {
            if ($Item.status -eq 'cancelled' -and $SessionStatus -eq 'cancelled') {
                if ($State.decisionCount -eq 0 -or ($State.decisionCount -eq 1 -and $State.decisionValue -eq 'rejected')) { return }
                throw "Command session item '$itemId' validation failed: cancelled human-decision item requires no decision or rejected decision event."
            }
            if ($Item.status -in @('pending', 'waiting-for-human') -and $State.decisionCount -ne 0) { throw "Command session item '$itemId' validation failed: open human-decision item has decision event history." }
            if ($Item.status -eq 'completed' -and -not ($State.decisionCount -eq 1 -and $State.decisionValue -eq 'approved')) { throw "Command session item '$itemId' validation failed: completed human-decision item requires approved decision event." }
            if ($Item.status -eq 'cancelled' -and -not ($State.decisionCount -eq 1 -and $State.decisionValue -eq 'rejected')) { throw "Command session item '$itemId' validation failed: cancelled human-decision item requires rejected decision event." }
        }
        'review' {
            if ($Item.status -eq 'cancelled' -and $SessionStatus -eq 'cancelled') {
                if ($State.reviewCount -eq 0 -or ($State.reviewCount -eq 1 -and $State.reviewStatus -eq 'inconclusive')) { return }
                throw "Command session item '$itemId' validation failed: cancelled review item must not have terminal review history."
            }
            if ($Item.status -eq 'waiting-for-human' -and ($State.reviewCount -gt 1 -or ($State.reviewCount -eq 1 -and $State.reviewStatus -ne 'inconclusive'))) { throw "Command session item '$itemId' validation failed: waiting review item may only have an inconclusive review event." }
            if ($Item.status -eq 'completed' -and -not ($State.reviewCount -eq 1 -and $State.reviewStatus -eq 'approved')) { throw "Command session item '$itemId' validation failed: completed review item requires approved review event." }
            if ($Item.status -eq 'failed' -and -not ($State.reviewCount -eq 1 -and $State.reviewStatus -eq 'rejected')) { throw "Command session item '$itemId' validation failed: failed review item requires rejected review event." }
        }
    }
}

function Test-AdmissionDependenciesCompleted {
    param([Parameter(Mandatory = $true)][object] $CommandSession, [Parameter(Mandatory = $true)][object] $Item)
    foreach ($dependency in @($Item.dependsOn)) {
        $dependencyId = [string] $dependency
        $dependencyItem = @($CommandSession.items | Where-Object { $_.itemId -eq $dependencyId } | Select-Object -First 1)
        if ($dependencyItem.Count -eq 0 -or $dependencyItem[0].status -ne 'completed') { return $false }
    }
    return $true
}

function Test-AdmissionApprovalSatisfied {
    param([Parameter(Mandatory = $true)][object] $CommandPlan, [Parameter(Mandatory = $true)][object] $CommandSession, [Parameter(Mandatory = $true)][object] $Item)
    $planItems = @(Get-ExecutionAdmissionPlanItems -CommandPlan $CommandPlan)
    $sessionItems = @(Get-ExecutionAdmissionSessionItems -CommandSession $CommandSession)
    $requiredGateIds = Get-RequiredHumanApprovalItems -PlanItems $planItems -ItemId ([string] $Item.itemId)
    foreach ($gateId in @($requiredGateIds)) {
        $approvalSessionItem = Get-ExecutionAdmissionSessionItemById -SessionItems $sessionItems -ItemId ([string] $gateId)
        $sourceSessionItem = @($CommandSession.items | Where-Object { $_.itemId -eq [string] $gateId } | Select-Object -First 1)
        if ($null -eq $approvalSessionItem -or $sourceSessionItem.Count -eq 0 -or $approvalSessionItem.status -ne 'completed') { return $false }
        if (-not (Test-ExecutionAdmissionProperty -Object $sourceSessionItem[0] -Name 'decision') -or $null -eq $sourceSessionItem[0].decision) { return $false }
        if (-not (Test-ExecutionAdmissionProperty -Object $sourceSessionItem[0].decision -Name 'value') -or [string] $sourceSessionItem[0].decision.value -ne 'approved') { return $false }
    }
    return $true
}

function Get-RequiredHumanApprovalItems {
    param([Parameter(Mandatory = $true)][object[]] $PlanItems, [Parameter(Mandatory = $true)][string] $ItemId)
    $byId = @{}
    foreach ($planItem in @($PlanItems)) { $byId[[string] $planItem.itemId] = $planItem }
    $required = New-Object 'System.Collections.Generic.List[string]'
    $visited = @{}
    function Visit-AdmissionDependency {
        param([Parameter(Mandatory = $true)][string] $DependencyId)
        if ($visited.ContainsKey($DependencyId)) { return }
        $visited[$DependencyId] = $true
        if (-not $byId.ContainsKey($DependencyId)) { return }
        $dependencyItem = $byId[$DependencyId]
        if ($dependencyItem.actor -eq 'human-decision') {
            $required.Add($DependencyId)
        }
        foreach ($nestedDependency in @($dependencyItem.dependsOn)) {
            $nestedId = [string] $nestedDependency
            if (-not [string]::IsNullOrWhiteSpace($nestedId)) { Visit-AdmissionDependency -DependencyId $nestedId }
        }
    }
    if ($byId.ContainsKey($ItemId)) {
        foreach ($dependency in @($byId[$ItemId].dependsOn)) {
            $dependencyId = [string] $dependency
            if (-not [string]::IsNullOrWhiteSpace($dependencyId)) { Visit-AdmissionDependency -DependencyId $dependencyId }
        }
    }
    return @($required | Sort-Object -Unique)
}

function Resolve-ExecutionAdmission {
    param([Parameter(Mandatory = $true)][object] $CommandPlan, [Parameter(Mandatory = $true)][object] $CommandSession)

    $plan = Copy-ExecutionAdmissionObject -Value $CommandPlan
    $session = Copy-ExecutionAdmissionObject -Value $CommandSession
    Assert-CommandPlanForExecutionAdmission -CommandPlan $plan
    Assert-CommandSessionForExecutionAdmission -CommandSession $session

    $crossDiagnostic = Assert-ExecutionAdmissionCrossConsistency -CommandPlan $plan -CommandSession $session
    if (-not [string]::IsNullOrWhiteSpace($crossDiagnostic)) {
        return New-ExecutionAdmissionResult -Status 'inconsistent' -SessionStatus ([string] $session.status) -CurrentItemId ([string] $session.currentItemId) -Diagnostic $crossDiagnostic
    }

    if ($session.status -in @('completed', 'failed', 'cancelled', 'blocked')) {
        return New-ExecutionAdmissionResult -Status ([string] $session.status) -SessionStatus ([string] $session.status) -CurrentItemId ([string] $session.currentItemId) -Diagnostic "Session is terminal with status '$($session.status)'."
    }

    if ([string]::IsNullOrWhiteSpace([string] $session.currentItemId)) {
        return New-ExecutionAdmissionResult -Status 'inconsistent' -SessionStatus ([string] $session.status) -Diagnostic 'Command session has no current item.'
    }

    $sessionItem = @($session.items | Where-Object { $_.itemId -eq [string] $session.currentItemId } | Select-Object -First 1)[0]
    $planItems = @(Get-ExecutionAdmissionPlanItems -CommandPlan $plan)
    $planItem = Get-ExecutionAdmissionPlanItemById -PlanItems $planItems -ItemId ([string] $sessionItem.itemId)
    if ($null -eq $planItem) {
        return New-ExecutionAdmissionResult -Status 'inconsistent' -SessionStatus ([string] $session.status) -CurrentItemId ([string] $session.currentItemId) -CommandId ([string] $sessionItem.commandId) -Diagnostic "Current item '$($sessionItem.itemId)' is not present in the command plan."
    }

    $dependenciesCompleted = Test-AdmissionDependenciesCompleted -CommandSession $session -Item $sessionItem
    $approvalSatisfied = Test-AdmissionApprovalSatisfied -CommandPlan $plan -CommandSession $session -Item $sessionItem
    $ready = ($sessionItem.status -eq 'ready' -or $sessionItem.status -eq 'waiting-for-human')
    $requirements = New-ExecutionAdmissionRequirements -Ready:$ready -DependenciesCompleted:$dependenciesCompleted -ApprovalSatisfied:$approvalSatisfied -ExecutionPermittedByPlan:([bool] $planItem.executionPermitted)
    $decision = New-ExecutionAdmissionDecision -Eligible:$false -Actor ([string] $planItem.actor) -Location ([string] $planItem.executionLocation) -Mode ([string] $planItem.executionMode) -Program ([string] $planItem.program)

    if (-not $dependenciesCompleted -or $sessionItem.status -eq 'pending') {
        return New-ExecutionAdmissionResult -Status 'not-ready' -SessionStatus ([string] $session.status) -CurrentItemId ([string] $session.currentItemId) -CommandId ([string] $sessionItem.commandId) -Decision $decision -Requirements $requirements -Diagnostic 'Current item is not ready because dependencies are open or the item is pending.'
    }

    switch ([string] $planItem.actor) {
        'automation' {
            $isEligible = ($session.status -eq 'waiting' -and $sessionItem.status -eq 'ready' -and $planItem.executionLocation -eq 'local' -and $planItem.executionMode -eq 'automatic' -and $planItem.program -eq 'local-operation')
            if ($isEligible) {
                $eligibleDecision = New-ExecutionAdmissionDecision -Eligible:$true -Actor ([string] $planItem.actor) -Location ([string] $planItem.executionLocation) -Mode ([string] $planItem.executionMode) -Program ([string] $planItem.program)
                return New-ExecutionAdmissionResult -Status 'eligible-but-disabled' -SessionStatus ([string] $session.status) -CurrentItemId ([string] $session.currentItemId) -CommandId ([string] $sessionItem.commandId) -Decision $eligibleDecision -Requirements $requirements -Handoff ([pscustomobject]@{ type = 'local-executor'; eventOnStart = 'automation-started'; eventOnResult = 'automation-result' })
            }
            return New-ExecutionAdmissionResult -Status 'blocked' -SessionStatus ([string] $session.status) -CurrentItemId ([string] $session.currentItemId) -CommandId ([string] $sessionItem.commandId) -Decision $decision -Requirements $requirements -Diagnostic 'Automation item is not eligible for V1 local-only admission.'
        }
        'human-command' {
            return New-ExecutionAdmissionResult -Status 'requires-human' -SessionStatus ([string] $session.status) -CurrentItemId ([string] $session.currentItemId) -CommandId ([string] $sessionItem.commandId) -Decision $decision -Requirements $requirements -Handoff ([pscustomobject]@{ type = 'human-command'; eventOnStart = 'human-command-started'; eventOnResult = 'human-command-result'; renderedCommand = [string] $planItem.renderedCommand; copyable = $true })
        }
        'human-decision' {
            return New-ExecutionAdmissionResult -Status 'requires-human' -SessionStatus ([string] $session.status) -CurrentItemId ([string] $session.currentItemId) -CommandId ([string] $sessionItem.commandId) -Decision $decision -Requirements $requirements -Handoff ([pscustomobject]@{ type = 'human-decision'; eventOnSubmit = 'human-decision-submitted' })
        }
        'review' {
            return New-ExecutionAdmissionResult -Status 'requires-review' -SessionStatus ([string] $session.status) -CurrentItemId ([string] $session.currentItemId) -CommandId ([string] $sessionItem.commandId) -Decision $decision -Requirements $requirements -Handoff ([pscustomobject]@{ type = 'review'; eventOnSubmit = 'review-result' })
        }
    }
}

function Write-ExecutionAdmissionJson {
    param([Parameter(Mandatory = $true)][object] $Admission, [string] $OutputPath)
    $json = $Admission | ConvertTo-Json -Depth 80
    if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
        $resolvedOutputPath = Resolve-ExecutionAdmissionPath -Path $OutputPath
        $outputDirectory = Split-Path -Path $resolvedOutputPath -Parent
        if (-not [string]::IsNullOrWhiteSpace($outputDirectory)) {
            New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
        }
        $json | Set-Content -LiteralPath $resolvedOutputPath -Encoding utf8
    }
    return $json
}

function Invoke-ExecutionAdmissionEvaluation {
    param([Parameter(Mandatory = $true)][string] $CommandPlanPath, [Parameter(Mandatory = $true)][string] $CommandSessionPath, [string] $OutputPath, [string] $Format = 'Json')
    if ($Format -ne 'Json') { throw "evaluate-execution-admission only supports -Format Json." }
    $commandPlan = Read-ExecutionAdmissionJsonFile -Path $CommandPlanPath -Description 'Command plan'
    $commandSession = Read-ExecutionAdmissionJsonFile -Path $CommandSessionPath -Description 'Command session'
    $admission = Resolve-ExecutionAdmission -CommandPlan $commandPlan -CommandSession $commandSession
    return Write-ExecutionAdmissionJson -Admission $admission -OutputPath $OutputPath
}

if ($MyInvocation.InvocationName -ne '.') {
    if ([string]::IsNullOrWhiteSpace($CommandPlanPath)) { throw "Missing required parameter for 'evaluate-execution-admission': -CommandPlanPath" }
    if ([string]::IsNullOrWhiteSpace($CommandSessionPath)) { throw "Missing required parameter for 'evaluate-execution-admission': -CommandSessionPath" }
    Invoke-ExecutionAdmissionEvaluation -CommandPlanPath $CommandPlanPath -CommandSessionPath $CommandSessionPath -OutputPath $OutputPath -Format $Format
}
