[CmdletBinding()]
param(
    [string] $CommandSessionPath,
    [string] $ExecutorRequestPath,
    [string] $ExecutorResultPath,
    [string] $Timestamp,
    [string] $OutputPath,
    [string] $Format = 'Json',
    [ValidateSet('Started', 'Result')]
    [string] $Operation = 'Started',
    [switch] $ModuleOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$automationEventEntryCommandSessionPath = $CommandSessionPath
$automationEventEntryExecutorRequestPath = $ExecutorRequestPath
$automationEventEntryExecutorResultPath = $ExecutorResultPath
$automationEventEntryTimestamp = $Timestamp
$automationEventEntryOutputPath = $OutputPath
$automationEventEntryFormat = $Format
$automationEventEntryOperation = $Operation
$automationEventEntryModuleOnly = $ModuleOnly
. (Join-Path -Path $PSScriptRoot -ChildPath 'CommandSession.ps1')
$CommandSessionPath = $automationEventEntryCommandSessionPath
$ExecutorRequestPath = $automationEventEntryExecutorRequestPath
$ExecutorResultPath = $automationEventEntryExecutorResultPath
$Timestamp = $automationEventEntryTimestamp
$OutputPath = $automationEventEntryOutputPath
$Format = $automationEventEntryFormat
$Operation = $automationEventEntryOperation
$ModuleOnly = $automationEventEntryModuleOnly

function Resolve-AutomationEventPath {
    param([Parameter(Mandatory = $true)][string] $Path)
    $executionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function Read-AutomationEventJsonFile {
    param([Parameter(Mandatory = $true)][string] $Path, [Parameter(Mandatory = $true)][string] $Description)
    $resolved = Resolve-AutomationEventPath -Path $Path
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) { throw "$Description file does not exist: $resolved" }
    try {
        return (Get-Content -LiteralPath $resolved -Raw | ConvertFrom-Json)
    } catch {
        throw "Invalid $Description JSON in '$resolved': $($_.Exception.Message)"
    }
}

function Copy-AutomationEventObject {
    param([Parameter(Mandatory = $true)][object] $Value)
    return $Value | ConvertTo-Json -Depth 100 | ConvertFrom-Json
}

function Test-AutomationEventProperty {
    param([object] $Object, [Parameter(Mandatory = $true)][string] $Name)
    return ($null -ne $Object -and @($Object.PSObject.Properties | Where-Object { $_.Name -eq $Name }).Count -gt 0)
}

function Assert-AutomationEventString {
    param([Parameter(Mandatory = $true)][object] $Object, [Parameter(Mandatory = $true)][string] $Name, [Parameter(Mandatory = $true)][string] $Context, [bool] $AllowEmpty = $false)
    if (-not (Test-AutomationEventProperty -Object $Object -Name $Name)) { throw "$Context validation failed: missing required field '$Name'." }
    if (-not ($Object.$Name -is [string])) { throw "$Context validation failed: field '$Name' must be a string." }
    if (-not $AllowEmpty -and [string]::IsNullOrWhiteSpace([string] $Object.$Name)) { throw "$Context validation failed: field '$Name' must not be empty." }
}

function Assert-AutomationEventInteger {
    param([Parameter(Mandatory = $true)][object] $Value, [Parameter(Mandatory = $true)][string] $Context, [Parameter(Mandatory = $true)][string] $Field)
    if (-not ($Value -is [byte] -or $Value -is [int16] -or $Value -is [int] -or $Value -is [long])) {
        throw "$Context validation failed: field '$Field' must be an integer."
    }
}

function Test-AutomationEventSecretText {
    param([string] $Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    return ($Text -match '(?i)(password=|token=|private key|BEGIN OPENSSH PRIVATE KEY|api[_-]?key|client[_-]?secret)')
}

function Assert-AutomationEventNoSecrets {
    param([Parameter(Mandatory = $true)][object] $Value, [Parameter(Mandatory = $true)][string] $Context)
    $json = $Value | ConvertTo-Json -Depth 100
    if (Test-AutomationEventSecretText -Text $json) { throw "$Context validation failed: secret-like content is not allowed." }
}

function Format-AutomationEventTimestamp {
    param([Parameter(Mandatory = $true)][string] $Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { throw 'Automation event validation failed: Timestamp is required.' }
    try {
        $parsed = [datetimeoffset]::Parse($Value, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
    } catch {
        throw 'Automation event validation failed: Timestamp must be a valid ISO-8601 value.'
    }
    return $parsed.UtcDateTime.ToString('O', [System.Globalization.CultureInfo]::InvariantCulture)
}

function Get-AutomationEventOptionalString {
    param([object] $Object, [Parameter(Mandatory = $true)][string] $Name)
    if ($null -eq $Object -or -not (Test-AutomationEventProperty -Object $Object -Name $Name) -or $null -eq $Object.$Name) { return '' }
    return [string] $Object.$Name
}

function Assert-AutomationEventSessionId {
    param([Parameter(Mandatory = $true)][object] $Session, [Parameter(Mandatory = $true)][object] $Request, [object] $Result = $null)
    $sessionId = Get-AutomationEventOptionalString -Object $Session -Name 'sessionId'
    $requestId = Get-AutomationEventOptionalString -Object $Request -Name 'sessionId'
    $resultId = Get-AutomationEventOptionalString -Object $Result -Name 'sessionId'
    $ids = @(@($sessionId, $requestId, $resultId) | Where-Object { -not [string]::IsNullOrWhiteSpace([string] $_) } | Select-Object -Unique)
    if ($ids.Count -gt 1) { throw 'Automation event validation failed: Session-ID does not match.' }
    if ((-not [string]::IsNullOrWhiteSpace($sessionId)) -and [string]::IsNullOrWhiteSpace($requestId)) { throw 'Automation event validation failed: Session-ID does not match.' }
    if ((-not [string]::IsNullOrWhiteSpace($requestId)) -and [string]::IsNullOrWhiteSpace($sessionId)) { throw 'Automation event validation failed: Session-ID does not match.' }
}

function Get-AutomationEventSessionId {
    param([Parameter(Mandatory = $true)][object] $Session, [Parameter(Mandatory = $true)][object] $Request)
    $sessionId = Get-AutomationEventOptionalString -Object $Session -Name 'sessionId'
    if (-not [string]::IsNullOrWhiteSpace($sessionId)) { return $sessionId }
    return Get-AutomationEventOptionalString -Object $Request -Name 'sessionId'
}

function Get-AutomationEventItem {
    param([Parameter(Mandatory = $true)][object] $Session, [Parameter(Mandatory = $true)][string] $ItemId)
    $matches = @($Session.items | Where-Object { $_.itemId -eq $ItemId } | Select-Object -First 1)
    if ($matches.Count -eq 0) { throw "Automation event validation failed: session item '$ItemId' does not exist." }
    return $matches[0]
}

function Assert-AutomationEventRequest {
    param([Parameter(Mandatory = $true)][object] $Request)
    Assert-AutomationEventString -Object $Request -Name 'schemaVersion' -Context 'Executor request'
    if ($Request.schemaVersion -ne '0.1') { throw "Executor request validation failed: unsupported schemaVersion '$($Request.schemaVersion)'." }
    Assert-AutomationEventString -Object $Request -Name 'executorRequestType' -Context 'Executor request'
    if ($Request.executorRequestType -ne 'deployment-executor-request') { throw "Executor request validation failed: executorRequestType must be 'deployment-executor-request'." }
    foreach ($field in @('status', 'itemId', 'commandId', 'operationType', 'actor', 'executionLocation', 'executionMode', 'program')) {
        Assert-AutomationEventString -Object $Request -Name $field -Context 'Executor request'
    }
    if ($Request.status -ne 'disabled') { throw "Executor request validation failed: status must be 'disabled'." }
    if ($Request.actor -ne 'automation') { throw "Executor request validation failed: actor must be 'automation'." }
    if ($Request.executionLocation -ne 'local') { throw "Executor request validation failed: executionLocation must be 'local'." }
    if ($Request.executionMode -ne 'automatic') { throw "Executor request validation failed: executionMode must be 'automatic'." }
    if ($Request.program -ne 'local-operation') { throw "Executor request validation failed: program must be 'local-operation'." }
    Assert-AutomationEventNoSecrets -Value $Request -Context 'Executor request'
}

function Assert-AutomationEventResult {
    param([Parameter(Mandatory = $true)][object] $Result)
    Assert-AutomationEventString -Object $Result -Name 'schemaVersion' -Context 'Executor result'
    if ($Result.schemaVersion -ne '0.1') { throw "Executor result validation failed: unsupported schemaVersion '$($Result.schemaVersion)'." }
    Assert-AutomationEventString -Object $Result -Name 'executorResultType' -Context 'Executor result'
    if ($Result.executorResultType -ne 'deployment-executor-result') { throw "Executor result validation failed: executorResultType must be 'deployment-executor-result'." }
    foreach ($field in @('status', 'sessionId', 'itemId', 'commandId', 'operationType', 'diagnostic')) {
        Assert-AutomationEventString -Object $Result -Name $field -Context 'Executor result' -AllowEmpty:($field -eq 'diagnostic')
    }
    if ($Result.status -notin @('completed', 'failed', 'rejected')) { throw "Executor result validation failed: unsupported status '$($Result.status)'." }
    Assert-AutomationEventInteger -Value $Result.exitStatus -Context 'Executor result' -Field 'exitStatus'
    if (-not (Test-AutomationEventProperty -Object $Result -Name 'artifacts') -or $null -eq $Result.artifacts) {
        throw 'Executor result validation failed: artifacts must not be null.'
    }
}

function Assert-AutomationEventItemMatchesRequest {
    param([Parameter(Mandatory = $true)][object] $Session, [Parameter(Mandatory = $true)][object] $Request, [Parameter(Mandatory = $true)][object] $Item)
    if ([string] $Session.currentItemId -ne [string] $Request.itemId) { throw 'Automation event validation failed: current item does not match executor request itemId.' }
    if ([string] $Item.commandId -ne [string] $Request.commandId) { throw 'Automation event validation failed: commandId does not match session item.' }
    if ([string] $Item.actor -ne 'automation') { throw 'Automation event validation failed: item actor must be automation.' }
    if ([string] $Item.executionMode -ne 'automatic') { throw 'Automation event validation failed: item executionMode must be automatic.' }
    foreach ($dependency in @($Item.dependsOn)) {
        $dependencyId = [string] $dependency
        $dependencyItem = @($Session.items | Where-Object { $_.itemId -eq $dependencyId } | Select-Object -First 1)
        if ($dependencyItem.Count -eq 0 -or $dependencyItem[0].status -ne 'completed') {
            throw "Automation event validation failed: dependency '$dependencyId' is not completed."
        }
    }
}

function Get-AutomationEventHistory {
    param([Parameter(Mandatory = $true)][object] $Session, [Parameter(Mandatory = $true)][string] $ItemId, [Parameter(Mandatory = $true)][string] $EventType)
    return @($Session.eventHistory | Where-Object { [string] $_.targetItemId -eq $ItemId -and [string] $_.eventType -eq $EventType })
}

function New-AutomationEventId {
    param([Parameter(Mandatory = $true)][string] $EventType, [Parameter(Mandatory = $true)][string] $ItemId, [Parameter(Mandatory = $true)][string] $Timestamp)
    return "$EventType`:$ItemId`:$Timestamp"
}

function Build-AutomationStartedEvent {
    param([Parameter(Mandatory = $true)][object] $CommandSession, [Parameter(Mandatory = $true)][object] $ExecutorRequest, [Parameter(Mandatory = $true)][string] $Timestamp)
    $session = Copy-AutomationEventObject -Value $CommandSession
    $request = Copy-AutomationEventObject -Value $ExecutorRequest
    $normalizedTimestamp = Format-AutomationEventTimestamp -Value $Timestamp

    Assert-CommandSession -Session $session
    Assert-AutomationEventRequest -Request $request
    Assert-AutomationEventSessionId -Session $session -Request $request
    if ($session.status -in @('completed', 'failed', 'cancelled', 'blocked')) { throw "Automation event validation failed: terminal session '$($session.status)' cannot start automation." }
    $item = Get-AutomationEventItem -Session $session -ItemId ([string] $request.itemId)
    Assert-AutomationEventItemMatchesRequest -Session $session -Request $request -Item $item
    if ($item.status -ne 'ready') { throw "Automation event validation failed: item '$($item.itemId)' must be ready." }
    if (@(Get-AutomationEventHistory -Session $session -ItemId ([string] $item.itemId) -EventType 'automation-started').Count -ne 0) {
        throw "Automation event validation failed: item '$($item.itemId)' already has an automation-started event."
    }
    if (@(Get-AutomationEventHistory -Session $session -ItemId ([string] $item.itemId) -EventType 'automation-result').Count -ne 0) {
        throw "Automation event validation failed: item '$($item.itemId)' already has an automation-result event."
    }

    return [pscustomobject]@{
        schemaVersion = '0.1'
        eventId = New-AutomationEventId -EventType 'automation-started' -ItemId ([string] $item.itemId) -Timestamp $normalizedTimestamp
        eventType = 'automation-started'
        targetItemId = [string] $item.itemId
        sessionId = Get-AutomationEventSessionId -Session $session -Request $request
        itemId = [string] $item.itemId
        commandId = [string] $request.commandId
        actor = 'automation'
        operationType = [string] $request.operationType
        timestamp = $normalizedTimestamp
    }
}

function Copy-AutomationResultArtifacts {
    param([Parameter(Mandatory = $true)][object] $Result)
    return @($Result.artifacts | ForEach-Object {
        foreach ($field in @('artifactId', 'artifactType', 'archiveFormat', 'localPath', 'fileName', 'hash', 'executionPlanFingerprint', 'packagingPolicyId', 'packagingPolicyFingerprint')) {
            Assert-AutomationEventString -Object $_ -Name $field -Context 'Executor result artifact'
        }
        if (-not (Test-AutomationEventProperty -Object $_ -Name 'createdAt') -or [string]::IsNullOrWhiteSpace([string] $_.createdAt)) {
            throw "Executor result artifact validation failed: field 'createdAt' must not be empty."
        }
        if (-not (Test-AutomationEventProperty -Object $_ -Name 'fileSize')) {
            throw "Executor result artifact validation failed: missing required field 'fileSize'."
        }
        if (-not (Test-AutomationEventProperty -Object $_ -Name 'packagingValidation')) {
            throw "Executor result artifact validation failed: missing required field 'packagingValidation'."
        }
        $artifact = [pscustomobject]@{
            artifactId = [string] $_.artifactId
            artifactType = [string] $_.artifactType
            archiveFormat = [string] $_.archiveFormat
            localPath = [string] $_.localPath
            fileName = [string] $_.fileName
            fileSize = [int64] $_.fileSize
            hash = [string] $_.hash
            executionPlanFingerprint = [string] $_.executionPlanFingerprint
            packagingPolicyId = [string] $_.packagingPolicyId
            packagingPolicyFingerprint = [string] $_.packagingPolicyFingerprint
            packagingValidation = Copy-AutomationEventObject -Value $_.packagingValidation
            createdAt = [string] $_.createdAt
        }
        Assert-AutomationEventNoSecrets -Value $artifact -Context 'Executor result artifact'
        $artifact
    })
}

function Build-AutomationResultEvent {
    param([Parameter(Mandatory = $true)][object] $CommandSession, [Parameter(Mandatory = $true)][object] $ExecutorRequest, [Parameter(Mandatory = $true)][object] $ExecutorResult, [Parameter(Mandatory = $true)][string] $Timestamp)
    $session = Copy-AutomationEventObject -Value $CommandSession
    $request = Copy-AutomationEventObject -Value $ExecutorRequest
    $result = Copy-AutomationEventObject -Value $ExecutorResult
    $normalizedTimestamp = Format-AutomationEventTimestamp -Value $Timestamp

    Assert-CommandSession -Session $session
    Assert-AutomationEventRequest -Request $request
    Assert-AutomationEventResult -Result $result
    Assert-AutomationEventSessionId -Session $session -Request $request -Result $result
    if ($session.status -in @('completed', 'failed', 'cancelled', 'blocked')) { throw "Automation event validation failed: terminal session '$($session.status)' cannot receive automation result." }
    $item = Get-AutomationEventItem -Session $session -ItemId ([string] $request.itemId)
    if (@(Get-AutomationEventHistory -Session $session -ItemId ([string] $item.itemId) -EventType 'automation-result').Count -ne 0) {
        throw "Automation event validation failed: item '$($item.itemId)' already has an automation-result event."
    }
    Assert-AutomationEventItemMatchesRequest -Session $session -Request $request -Item $item
    if ($item.status -ne 'running') { throw "Automation event validation failed: item '$($item.itemId)' must be running." }
    if ([string] $request.itemId -ne [string] $result.itemId) { throw 'Automation event validation failed: result itemId does not match executor request.' }
    if ([string] $request.commandId -ne [string] $result.commandId) { throw 'Automation event validation failed: result commandId does not match executor request.' }
    if ([string] $request.operationType -ne [string] $result.operationType) { throw 'Automation event validation failed: result operationType does not match executor request.' }
    if (@(Get-AutomationEventHistory -Session $session -ItemId ([string] $item.itemId) -EventType 'automation-started').Count -ne 1) {
        throw "Automation event validation failed: item '$($item.itemId)' requires exactly one automation-started event."
    }
    $artifacts = @(Copy-AutomationResultArtifacts -Result $result)
    $diagnostic = [string] $result.diagnostic
    Assert-AutomationEventNoSecrets -Value ([pscustomobject]@{ diagnostic = $diagnostic; artifacts = $artifacts }) -Context 'Automation result event payload'
    $eventStatus = if ($result.status -eq 'completed') { 'completed' } else { 'failed' }

    return [pscustomobject]@{
        schemaVersion = '0.1'
        eventId = New-AutomationEventId -EventType 'automation-result' -ItemId ([string] $item.itemId) -Timestamp $normalizedTimestamp
        eventType = 'automation-result'
        targetItemId = [string] $item.itemId
        sessionId = Get-AutomationEventSessionId -Session $session -Request $request
        itemId = [string] $item.itemId
        commandId = [string] $request.commandId
        actor = 'automation'
        operationType = [string] $request.operationType
        timestamp = $normalizedTimestamp
        result = [pscustomobject]@{
            status = $eventStatus
            resultStatus = [string] $result.status
            exitStatus = [int] $result.exitStatus
            diagnostic = $diagnostic
            artifacts = @($artifacts)
        }
    }
}

function Write-AutomationEventJson {
    param([Parameter(Mandatory = $true)][object] $Event, [string] $OutputPath)
    $json = $Event | ConvertTo-Json -Depth 100
    if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
        $resolvedOutputPath = Resolve-AutomationEventPath -Path $OutputPath
        $outputDirectory = Split-Path -Path $resolvedOutputPath -Parent
        if (-not [string]::IsNullOrWhiteSpace($outputDirectory)) { New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null }
        $json | Set-Content -LiteralPath $resolvedOutputPath -Encoding utf8
    }
    return $json
}

function Invoke-AutomationStartedEventBuild {
    param([Parameter(Mandatory = $true)][string] $CommandSessionPath, [Parameter(Mandatory = $true)][string] $ExecutorRequestPath, [Parameter(Mandatory = $true)][string] $Timestamp, [string] $OutputPath, [string] $Format = 'Json')
    if ($Format -ne 'Json') { throw "build-automation-started-event only supports -Format Json." }
    $session = Read-AutomationEventJsonFile -Path $CommandSessionPath -Description 'Command session'
    $request = Read-AutomationEventJsonFile -Path $ExecutorRequestPath -Description 'Executor request'
    $event = Build-AutomationStartedEvent -CommandSession $session -ExecutorRequest $request -Timestamp $Timestamp
    return Write-AutomationEventJson -Event $event -OutputPath $OutputPath
}

function Invoke-AutomationResultEventBuild {
    param([Parameter(Mandatory = $true)][string] $CommandSessionPath, [Parameter(Mandatory = $true)][string] $ExecutorRequestPath, [Parameter(Mandatory = $true)][string] $ExecutorResultPath, [Parameter(Mandatory = $true)][string] $Timestamp, [string] $OutputPath, [string] $Format = 'Json')
    if ($Format -ne 'Json') { throw "build-automation-result-event only supports -Format Json." }
    $session = Read-AutomationEventJsonFile -Path $CommandSessionPath -Description 'Command session'
    $request = Read-AutomationEventJsonFile -Path $ExecutorRequestPath -Description 'Executor request'
    $result = Read-AutomationEventJsonFile -Path $ExecutorResultPath -Description 'Executor result'
    $event = Build-AutomationResultEvent -CommandSession $session -ExecutorRequest $request -ExecutorResult $result -Timestamp $Timestamp
    return Write-AutomationEventJson -Event $event -OutputPath $OutputPath
}

if (-not $ModuleOnly) {
    if ([string]::IsNullOrWhiteSpace($CommandSessionPath)) { throw "Missing required parameter for automation event builder: -CommandSessionPath" }
    if ([string]::IsNullOrWhiteSpace($ExecutorRequestPath)) { throw "Missing required parameter for automation event builder: -ExecutorRequestPath" }
    if ([string]::IsNullOrWhiteSpace($Timestamp)) { throw "Missing required parameter for automation event builder: -Timestamp" }
    if ($Operation -eq 'Started') {
        Invoke-AutomationStartedEventBuild -CommandSessionPath $CommandSessionPath -ExecutorRequestPath $ExecutorRequestPath -Timestamp $Timestamp -OutputPath $OutputPath -Format $Format
    } else {
        if ([string]::IsNullOrWhiteSpace($ExecutorResultPath)) { throw "Missing required parameter for 'build-automation-result-event': -ExecutorResultPath" }
        Invoke-AutomationResultEventBuild -CommandSessionPath $CommandSessionPath -ExecutorRequestPath $ExecutorRequestPath -ExecutorResultPath $ExecutorResultPath -Timestamp $Timestamp -OutputPath $OutputPath -Format $Format
    }
}
