[CmdletBinding()]
param(
    [string] $CommandPlanPath,
    [string] $SourceRepositoryPath,
    [string] $RuntimeRootPath,
    [int] $MaxAutomationSteps = 50,
    [string] $OutputPath,
    [string] $Format = 'Json',
    [switch] $ModuleOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$orchestratorEntryCommandPlanPath = $CommandPlanPath
$orchestratorEntrySourceRepositoryPath = $SourceRepositoryPath
$orchestratorEntryRuntimeRootPath = $RuntimeRootPath
$orchestratorEntryMaxAutomationSteps = $MaxAutomationSteps
$orchestratorEntryOutputPath = $OutputPath
$orchestratorEntryFormat = $Format
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
$MaxAutomationSteps = $orchestratorEntryMaxAutomationSteps
$OutputPath = $orchestratorEntryOutputPath
$Format = $orchestratorEntryFormat
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
    $directory = Split-Path -Path $resolved -Parent
    if (-not [string]::IsNullOrWhiteSpace($directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    $json = $Value | ConvertTo-Json -Depth 100
    $json | Set-Content -LiteralPath $resolved -Encoding utf8
    return $json
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
        executedAutomationCount = $ExecutedAutomationCount
        humanActionRequired = $HumanActionRequired
        diagnostic = $Diagnostic
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
            Write-OrchestratorJson -Value $summary -Path (Join-Path -Path $runtime.reportsDirectory -ChildPath 'execution-summary.json') -RuntimeDirectory $runtime.runtimeDirectory | Out-Null
            if (-not [string]::IsNullOrWhiteSpace($OutputPath)) { Write-OrchestratorJson -Value $summary -Path $OutputPath | Out-Null }
            return $summary | ConvertTo-Json -Depth 100
        }

        $effectivePlan = Set-OrchestratorRuntimeArtifactPaths -CommandPlan $commandPlan -Runtime $runtime
        Write-OrchestratorJson -Value $effectivePlan -Path (Join-Path -Path $runtime.decisionsDirectory -ChildPath 'command-plan-effective.json') -RuntimeDirectory $runtime.runtimeDirectory | Out-Null
        $session = New-CommandSession -CommandPlan $effectivePlan
        Write-OrchestratorJson -Value $session -Path (Join-Path -Path $runtime.decisionsDirectory -ChildPath 'command-session-0000.json') -RuntimeDirectory $runtime.runtimeDirectory | Out-Null

        for ($step = 1; $step -le ($MaxAutomationSteps + 1); $step++) {
            $admission = Resolve-ExecutionAdmission -CommandPlan $effectivePlan -CommandSession $session
            Write-OrchestratorJson -Value $admission -Path (Join-Path -Path $runtime.decisionsDirectory -ChildPath ('execution-admission-{0:0000}.json' -f $step)) -RuntimeDirectory $runtime.runtimeDirectory | Out-Null

            if ($session.status -in @('completed', 'failed', 'blocked', 'cancelled')) {
                $summary = New-OrchestratorResult -Status (Get-OrchestratorFinalStatus -SessionStatus ([string] $session.status)) -Runtime $runtime -Session $session -ExecutedAutomationCount $executedAutomationCount
                break
            }

            if ($admission.status -in @('requires-human', 'requires-review')) {
                $summary = New-OrchestratorResult -Status 'waiting-for-human' -Runtime $runtime -Session $session -ExecutedAutomationCount $executedAutomationCount -HumanActionRequired:$true -Diagnostic "Execution paused because admission status is '$($admission.status)'."
                break
            }

            if ($admission.status -ne 'eligible-but-disabled') {
                $summary = New-OrchestratorResult -Status 'blocked' -Runtime $runtime -Session $session -ExecutedAutomationCount $executedAutomationCount -Diagnostic "Execution paused because admission status is '$($admission.status)'."
                break
            }

            if ($executedAutomationCount -ge $MaxAutomationSteps) {
                $summary = New-OrchestratorResult -Status 'failed' -Runtime $runtime -Session $session -ExecutedAutomationCount $executedAutomationCount -Diagnostic "MaxAutomationSteps limit reached before the next automation could start."
                break
            }

            $request = Resolve-ExecutorRequest -CommandPlan $effectivePlan -CommandSession $session -ExecutionAdmission $admission
            Write-OrchestratorJson -Value $request -Path (Join-Path -Path $runtime.decisionsDirectory -ChildPath ('executor-request-{0:0000}.json' -f $step)) -RuntimeDirectory $runtime.runtimeDirectory | Out-Null

            $startedEvent = Build-AutomationStartedEvent -CommandSession $session -ExecutorRequest $request -Timestamp (Get-OrchestratorTimestamp)
            Write-OrchestratorJson -Value $startedEvent -Path (Join-Path -Path $runtime.eventsDirectory -ChildPath ('automation-started-{0:0000}.json' -f $step)) -RuntimeDirectory $runtime.runtimeDirectory | Out-Null
            $runningSession = Apply-CommandSessionEvent -CommandSession $session -Event $startedEvent
            Write-OrchestratorJson -Value $runningSession -Path (Join-Path -Path $runtime.decisionsDirectory -ChildPath ('command-session-{0:0000}-started.json' -f $step)) -RuntimeDirectory $runtime.runtimeDirectory | Out-Null

            $executorResult = Invoke-LocalOperationRequest -ExecutorRequest $request
            Write-OrchestratorJson -Value $executorResult -Path (Join-Path -Path $runtime.decisionsDirectory -ChildPath ('executor-result-{0:0000}.json' -f $step)) -RuntimeDirectory $runtime.runtimeDirectory | Out-Null

            $resultEvent = Build-AutomationResultEvent -CommandSession $runningSession -ExecutorRequest $request -ExecutorResult $executorResult -Timestamp (Get-OrchestratorTimestamp)
            Write-OrchestratorJson -Value $resultEvent -Path (Join-Path -Path $runtime.eventsDirectory -ChildPath ('automation-result-{0:0000}.json' -f $step)) -RuntimeDirectory $runtime.runtimeDirectory | Out-Null
            $session = Apply-CommandSessionEvent -CommandSession $runningSession -Event $resultEvent
            Write-OrchestratorJson -Value $session -Path (Join-Path -Path $runtime.decisionsDirectory -ChildPath ('command-session-{0:0000}-result.json' -f $step)) -RuntimeDirectory $runtime.runtimeDirectory | Out-Null
            $executedAutomationCount++
        }

        if ($null -eq $summary) {
            $summary = New-OrchestratorResult -Status 'failed' -Runtime $runtime -Session $session -ExecutedAutomationCount $executedAutomationCount -Diagnostic 'Execution loop ended without a terminal or pause state.'
        }
    } catch {
        $status = if ($null -eq $runtime) { 'rejected' } else { 'failed' }
        $summary = New-OrchestratorResult -Status $status -Runtime $runtime -Session $session -ExecutedAutomationCount $executedAutomationCount -Diagnostic $_.Exception.Message
    }

    if ($null -ne $runtime) {
        Write-OrchestratorJson -Value $summary -Path (Join-Path -Path $runtime.reportsDirectory -ChildPath 'execution-summary.json') -RuntimeDirectory $runtime.runtimeDirectory | Out-Null
    }
    if (-not [string]::IsNullOrWhiteSpace($OutputPath)) { Write-OrchestratorJson -Value $summary -Path $OutputPath | Out-Null }
    return $summary | ConvertTo-Json -Depth 100
}

if (-not $ModuleOnly) {
    if ([string]::IsNullOrWhiteSpace($CommandPlanPath)) { throw "Missing required parameter for 'orchestrate-local-execution': -CommandPlanPath" }
    if ([string]::IsNullOrWhiteSpace($SourceRepositoryPath)) { throw "Missing required parameter for 'orchestrate-local-execution': -SourceRepositoryPath" }
    if ([string]::IsNullOrWhiteSpace($RuntimeRootPath)) { throw "Missing required parameter for 'orchestrate-local-execution': -RuntimeRootPath" }
    Invoke-LocalExecutionOrchestrator -CommandPlanPath $CommandPlanPath -SourceRepositoryPath $SourceRepositoryPath -RuntimeRootPath $RuntimeRootPath -MaxAutomationSteps $MaxAutomationSteps -OutputPath $OutputPath -Format $Format
}
