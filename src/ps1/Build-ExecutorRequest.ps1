[CmdletBinding()]
param(
    [string] $CommandPlanPath,
    [string] $CommandSessionPath,
    [string] $ExecutionAdmissionPath,
    [string] $OutputPath,
    [string] $Format = 'Json',
    [switch] $ModuleOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$executorRequestEntryCommandPlanPath = $CommandPlanPath
$executorRequestEntryCommandSessionPath = $CommandSessionPath
$executorRequestEntryExecutionAdmissionPath = $ExecutionAdmissionPath
$executorRequestEntryOutputPath = $OutputPath
$executorRequestEntryFormat = $Format
$executorRequestEntryModuleOnly = $ModuleOnly
. (Join-Path -Path $PSScriptRoot -ChildPath 'Evaluate-ExecutionAdmission.ps1')
$CommandPlanPath = $executorRequestEntryCommandPlanPath
$CommandSessionPath = $executorRequestEntryCommandSessionPath
$ExecutionAdmissionPath = $executorRequestEntryExecutionAdmissionPath
$OutputPath = $executorRequestEntryOutputPath
$Format = $executorRequestEntryFormat
$ModuleOnly = $executorRequestEntryModuleOnly

function Resolve-ExecutorRequestPath {
    param([Parameter(Mandatory = $true)][string] $Path)
    $executionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function Read-ExecutorRequestJsonFile {
    param([Parameter(Mandatory = $true)][string] $Path, [Parameter(Mandatory = $true)][string] $Description)
    $resolved = Resolve-ExecutorRequestPath -Path $Path
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) { throw "$Description file does not exist: $resolved" }
    try {
        return (Get-Content -LiteralPath $resolved -Raw | ConvertFrom-Json)
    } catch {
        throw "Invalid $Description JSON in '$resolved': $($_.Exception.Message)"
    }
}

function Copy-ExecutorRequestObject {
    param([Parameter(Mandatory = $true)][object] $Value)
    return $Value | ConvertTo-Json -Depth 100 | ConvertFrom-Json -NoEnumerate
}

function Test-ExecutorRequestProperty {
    param([object] $Object, [Parameter(Mandatory = $true)][string] $Name)
    return ($null -ne $Object -and @($Object.PSObject.Properties | Where-Object { $_.Name -eq $Name }).Count -gt 0)
}

function Assert-ExecutorRequestString {
    param([Parameter(Mandatory = $true)][object] $Object, [Parameter(Mandatory = $true)][string] $Name, [Parameter(Mandatory = $true)][string] $Context, [bool] $AllowEmpty = $false)
    if (-not (Test-ExecutorRequestProperty -Object $Object -Name $Name)) { throw "$Context validation failed: missing required field '$Name'." }
    if (-not ($Object.$Name -is [string])) { throw "$Context validation failed: field '$Name' must be a string." }
    if (-not $AllowEmpty -and [string]::IsNullOrWhiteSpace([string] $Object.$Name)) { throw "$Context validation failed: field '$Name' must not be empty." }
}

function Assert-ExecutorRequestBool {
    param([Parameter(Mandatory = $true)][object] $Object, [Parameter(Mandatory = $true)][string] $Name, [Parameter(Mandatory = $true)][string] $Context)
    if (-not (Test-ExecutorRequestProperty -Object $Object -Name $Name)) { throw "$Context validation failed: missing required field '$Name'." }
    if (-not ($Object.$Name -is [bool])) { throw "$Context validation failed: field '$Name' must be boolean." }
}

function Assert-NoExecutorRequestSecrets {
    param([Parameter(Mandatory = $true)][object] $Value, [Parameter(Mandatory = $true)][string] $Context)
    $json = $Value | ConvertTo-Json -Depth 100
    if ($json -match '(?i)(password=|token=|private key|BEGIN OPENSSH PRIVATE KEY|api[_-]?key|client[_-]?secret)') {
        throw "$Context validation failed: secret-like content is not allowed."
    }
}

function Assert-ExecutionAdmissionForExecutorRequest {
    param([Parameter(Mandatory = $true)][object] $ExecutionAdmission)
    Assert-ExecutorRequestString -Object $ExecutionAdmission -Name 'schemaVersion' -Context 'Execution admission'
    if ($ExecutionAdmission.schemaVersion -ne '0.1') { throw "Execution admission validation failed: unsupported schemaVersion '$($ExecutionAdmission.schemaVersion)'." }
    Assert-ExecutorRequestString -Object $ExecutionAdmission -Name 'admissionType' -Context 'Execution admission'
    if ($ExecutionAdmission.admissionType -ne 'execution-admission') { throw "Execution admission validation failed: admissionType must be 'execution-admission'." }
    Assert-ExecutorRequestString -Object $ExecutionAdmission -Name 'status' -Context 'Execution admission'
    if ($ExecutionAdmission.status -ne 'eligible-but-disabled') { throw "Execution admission validation failed: status must be 'eligible-but-disabled'." }
    foreach ($field in @('currentItemId', 'commandId')) { Assert-ExecutorRequestString -Object $ExecutionAdmission -Name $field -Context 'Execution admission' }
    if (-not (Test-ExecutorRequestProperty -Object $ExecutionAdmission -Name 'decision')) { throw 'Execution admission validation failed: missing decision.' }
    Assert-ExecutorRequestBool -Object $ExecutionAdmission.decision -Name 'executionEligible' -Context 'Execution admission decision'
    Assert-ExecutorRequestBool -Object $ExecutionAdmission.decision -Name 'executionAdmitted' -Context 'Execution admission decision'
    if (-not $ExecutionAdmission.decision.executionEligible) { throw 'Execution admission validation failed: executionEligible must be true.' }
    if ($ExecutionAdmission.decision.executionAdmitted) { throw 'Execution admission validation failed: executionAdmitted must remain false.' }
    foreach ($field in @('actor', 'executionLocation', 'executionMode', 'program')) { Assert-ExecutorRequestString -Object $ExecutionAdmission.decision -Name $field -Context 'Execution admission decision' }
    if ($ExecutionAdmission.decision.actor -ne 'automation' -or $ExecutionAdmission.decision.executionLocation -ne 'local' -or $ExecutionAdmission.decision.executionMode -ne 'automatic' -or $ExecutionAdmission.decision.program -ne 'local-operation') {
        throw 'Execution admission validation failed: only local automatic automation with local-operation is supported.'
    }
    if (-not (Test-ExecutorRequestProperty -Object $ExecutionAdmission -Name 'requirements')) { throw 'Execution admission validation failed: missing requirements.' }
    Assert-ExecutorRequestBool -Object $ExecutionAdmission.requirements -Name 'sessionItemReady' -Context 'Execution admission requirements'
    Assert-ExecutorRequestBool -Object $ExecutionAdmission.requirements -Name 'dependenciesCompleted' -Context 'Execution admission requirements'
    Assert-ExecutorRequestBool -Object $ExecutionAdmission.requirements -Name 'executionPermittedByCommandPlan' -Context 'Execution admission requirements'
    if (-not $ExecutionAdmission.requirements.sessionItemReady -or -not $ExecutionAdmission.requirements.dependenciesCompleted) { throw 'Execution admission validation failed: item must be ready and dependencies must be completed.' }
    if ($ExecutionAdmission.requirements.executionPermittedByCommandPlan) { throw 'Execution admission validation failed: command plan execution permission must remain false.' }
    Assert-NoExecutorRequestSecrets -Value $ExecutionAdmission -Context 'Execution admission'
}

function Get-ExecutorRequestCommand {
    param([Parameter(Mandatory = $true)][object] $CommandPlan, [Parameter(Mandatory = $true)][string] $CommandId)
    $matches = @($CommandPlan.commands | Where-Object { $_.commandId -eq $CommandId } | Select-Object -First 1)
    if ($matches.Count -eq 0) { throw "Executor request validation failed: command '$CommandId' does not exist in command plan." }
    return $matches[0]
}

function Get-ExecutorRequestSessionItem {
    param([Parameter(Mandatory = $true)][object] $CommandSession, [Parameter(Mandatory = $true)][string] $ItemId)
    $matches = @($CommandSession.items | Where-Object { $_.itemId -eq $ItemId } | Select-Object -First 1)
    if ($matches.Count -eq 0) { throw "Executor request validation failed: session item '$ItemId' does not exist." }
    return $matches[0]
}

function Resolve-ExecutorRequestOperationType {
    param([Parameter(Mandatory = $true)][string] $CommandOperationType)
    switch ($CommandOperationType) {
        'source.validate' { return 'source.validate' }
        'source-validate' { return 'source.validate' }
        'archive.create' { return 'archive.create' }
        'archive-create' { return 'archive.create' }
        default { return $CommandOperationType }
    }
}

function Get-ExecutorRequestOperation {
    param([Parameter(Mandatory = $true)][object] $Command)
    if (Test-ExecutorRequestProperty -Object $Command -Name 'operation') {
        return Copy-ExecutorRequestObject -Value $Command.operation
    }
    return [pscustomobject]@{}
}

function Resolve-ExecutorRequest {
    param([Parameter(Mandatory = $true)][object] $CommandPlan, [Parameter(Mandatory = $true)][object] $CommandSession, [Parameter(Mandatory = $true)][object] $ExecutionAdmission)
    $plan = Copy-ExecutorRequestObject -Value $CommandPlan
    $session = Copy-ExecutorRequestObject -Value $CommandSession
    $admission = Copy-ExecutorRequestObject -Value $ExecutionAdmission

    Assert-CommandPlanForExecutionAdmission -CommandPlan $plan
    Assert-CommandSessionForExecutionAdmission -CommandSession $session
    $computedAdmission = Resolve-ExecutionAdmission -CommandPlan $plan -CommandSession $session
    Assert-ExecutionAdmissionForExecutorRequest -ExecutionAdmission $admission

    $computedJson = $computedAdmission | ConvertTo-Json -Depth 100
    $providedJson = $admission | ConvertTo-Json -Depth 100
    if ($computedJson -ne $providedJson) { throw 'Executor request validation failed: execution admission does not match command plan and command session.' }
    if ([string] $session.currentItemId -ne [string] $admission.currentItemId) { throw 'Executor request validation failed: admission currentItemId does not match command session.' }
    if ([string] $admission.currentItemId -ne [string] $admission.commandId) { throw 'Executor request validation failed: admission commandId must match currentItemId for local automation.' }
    Assert-ExecutorRequestString -Object $session -Name 'sessionId' -Context 'Command session'

    $item = Get-ExecutorRequestSessionItem -CommandSession $session -ItemId ([string] $admission.currentItemId)
    $command = Get-ExecutorRequestCommand -CommandPlan $plan -CommandId ([string] $admission.commandId)
    Assert-NoExecutorRequestSecrets -Value $item -Context 'Command session item'
    Assert-NoExecutorRequestSecrets -Value $command -Context 'Command plan command'
    if ($item.status -ne 'ready') { throw "Executor request validation failed: session item '$($item.itemId)' must be ready." }
    if ($item.actor -ne 'automation' -or $command.actor -ne 'automation') { throw 'Executor request validation failed: only automation items are supported.' }
    if ($command.executionLocation -ne 'local' -or $command.executionMode -ne 'automatic' -or $command.program -ne 'local-operation') { throw 'Executor request validation failed: only local automatic local-operation commands are supported.' }
    $operationType = Resolve-ExecutorRequestOperationType -CommandOperationType ([string] $command.operationType)
    $operation = Get-ExecutorRequestOperation -Command $command

    return [pscustomobject]@{
        schemaVersion = '0.1'
        executorRequestType = 'deployment-executor-request'
        status = 'disabled'
        sessionId = [string] $session.sessionId
        itemId = [string] $item.itemId
        commandId = [string] $command.commandId
        operationType = $operationType
        executorType = 'local-operation'
        actor = [string] $command.actor
        executionLocation = [string] $command.executionLocation
        executionMode = [string] $command.executionMode
        program = [string] $command.program
        renderedCommand = [string] $command.renderedCommand
        workingDirectory = [string] $command.workingDirectory
        arguments = @($command.arguments | ForEach-Object { [string] $_ })
        environment = Copy-ExecutorRequestObject -Value $command.environment
        operation = $operation
        executionPolicy = [pscustomobject]@{
            processStartAllowed = $false
            networkAccessAllowed = $false
            remoteExecutionAllowed = $false
        }
        expectedEvents = [pscustomobject]@{
            onStart = 'automation-started'
            onResult = 'automation-result'
        }
        diagnostic = 'Executor request is disabled until a local operation executor is implemented.'
    }
}

function Write-ExecutorRequestJson {
    param([Parameter(Mandatory = $true)][object] $ExecutorRequest, [string] $OutputPath)
    $json = $ExecutorRequest | ConvertTo-Json -Depth 100
    if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
        $resolvedOutputPath = Resolve-ExecutorRequestPath -Path $OutputPath
        $outputDirectory = Split-Path -Path $resolvedOutputPath -Parent
        if (-not [string]::IsNullOrWhiteSpace($outputDirectory)) { New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null }
        $json | Set-Content -LiteralPath $resolvedOutputPath -Encoding utf8
    }
    return $json
}

function Invoke-ExecutorRequestBuild {
    param([Parameter(Mandatory = $true)][string] $CommandPlanPath, [Parameter(Mandatory = $true)][string] $CommandSessionPath, [Parameter(Mandatory = $true)][string] $ExecutionAdmissionPath, [string] $OutputPath, [string] $Format = 'Json')
    if ($Format -ne 'Json') { throw "build-executor-request only supports -Format Json." }
    $commandPlan = Read-ExecutorRequestJsonFile -Path $CommandPlanPath -Description 'Command plan'
    $commandSession = Read-ExecutorRequestJsonFile -Path $CommandSessionPath -Description 'Command session'
    $executionAdmission = Read-ExecutorRequestJsonFile -Path $ExecutionAdmissionPath -Description 'Execution admission'
    $request = Resolve-ExecutorRequest -CommandPlan $commandPlan -CommandSession $commandSession -ExecutionAdmission $executionAdmission
    return Write-ExecutorRequestJson -ExecutorRequest $request -OutputPath $OutputPath
}

if (-not $ModuleOnly) {
    if ([string]::IsNullOrWhiteSpace($CommandPlanPath)) { throw "Missing required parameter for 'build-executor-request': -CommandPlanPath" }
    if ([string]::IsNullOrWhiteSpace($CommandSessionPath)) { throw "Missing required parameter for 'build-executor-request': -CommandSessionPath" }
    if ([string]::IsNullOrWhiteSpace($ExecutionAdmissionPath)) { throw "Missing required parameter for 'build-executor-request': -ExecutionAdmissionPath" }
    Invoke-ExecutorRequestBuild -CommandPlanPath $CommandPlanPath -CommandSessionPath $CommandSessionPath -ExecutionAdmissionPath $ExecutionAdmissionPath -OutputPath $OutputPath -Format $Format
}
