[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:failures = New-Object System.Collections.Generic.List[string]
$engineRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '..'))
$strategyPath = Join-Path -Path $engineRoot -ChildPath 'src/ps1/Build-DeploymentStrategy.ps1'
$cliPath = Join-Path -Path $engineRoot -ChildPath 'bin/deployment-engine.ps1'

. $strategyPath

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) {
        $script:failures.Add($Message)
    }
}

function Assert-Equal {
    param($Actual, $Expected, [string] $Message)
    if ($Actual -ne $Expected) {
        $script:failures.Add("$Message Expected '$Expected', got '$Actual'.")
    }
}

function Assert-ThrowsLike {
    param(
        [scriptblock] $Script,
        [string] $Pattern,
        [string] $Message
    )

    try {
        & $Script
        $script:failures.Add($Message)
    } catch {
        Assert-True ($_.Exception.Message -match $Pattern) "$Message Actual error: $($_.Exception.Message)"
    }
}

function New-TestPlanStep {
    param(
        [Parameter(Mandatory = $true)][string] $Id,
        [string] $ExecutionMode = 'agent',
        [string] $Status = 'ready',
        [bool] $Required = $true,
        [bool] $ApprovalRequired = $false,
        [string] $CapabilityId = '',
        [string[]] $DependsOn = @()
    )

    return [pscustomobject]@{
        id = $Id
        phase = 'test'
        title = $Id
        executionMode = $ExecutionMode
        required = $Required
        status = $Status
        reason = 'Test plan step.'
        approvalRequired = $ApprovalRequired
        destructive = $false
        riskLevel = 'normal'
        capabilityId = $CapabilityId
        dependsOn = @($DependsOn)
        instructions = [pscustomobject]@{
            capabilityId = $CapabilityId
            displayCommand = if ([string]::IsNullOrWhiteSpace($CapabilityId)) { '' } else { 'display only' }
        }
        validation = [pscustomobject]@{}
        continuation = [pscustomobject]@{}
    }
}

function New-TestResolvedPlan {
    return [pscustomobject]@{
        schemaVersion = '0.1'
        sourceAnalysisVersion = '0.1'
        resolved = $true
        blocked = $false
        project = [pscustomobject]@{
            id = 'pilot'
            name = 'Pilot'
            type = 'laravel'
        }
        environment = [pscustomobject]@{
            name = 'production'
            serverRoot = '/var/www'
            applicationRemoteDirectory = '/var/www/laravel_app'
            markerFile = '.deploy-version'
        }
        baselineCommit = 'abc'
        targetCommit = 'def'
        decisions = [pscustomobject]@{
            runtimeDeploymentRequired = $true
        }
        warnings = @()
        blockers = @()
        manualApprovalPoints = @()
        phases = @('preconditions')
        steps = @(
            New-TestPlanStep -Id 'preconditions.analysis-review'
            New-TestPlanStep -Id 'remote.migrations.execute' -ExecutionMode 'human' -Status 'waiting-for-human' -ApprovalRequired $true -CapabilityId 'artisan.migrate' -DependsOn @('preconditions.analysis-review')
        )
    }
}

function New-TestCandidate {
    param(
        [Parameter(Mandatory = $true)][string] $AdapterId,
        [Parameter(Mandatory = $true)][int] $Priority,
        [Parameter(Mandatory = $true)][string] $EligibilityStatus,
        [bool] $Selected
    )

    return [pscustomobject]@{
        adapterId = $AdapterId
        priority = $Priority
        eligibilityStatus = $EligibilityStatus
        selected = $Selected
        diagnostic = ''
    }
}

function New-TestAdapterSelection {
    param(
        [string] $SelectedAdapterId = 'archive.zip',
        [string] $Status = 'selected',
        [string] $ZipStatus = 'eligible',
        [string] $TarStatus = 'eligible'
    )

    return [pscustomobject]@{
        schemaVersion = '0.1'
        selectionType = 'deployment-adapter'
        status = $Status
        selectedAdapterId = $SelectedAdapterId
        strategy = [pscustomobject]@{ type = 'priority'; order = 'ascending'; tieBreaker = 'adapterId' }
        candidates = @(
            New-TestCandidate -AdapterId 'archive.zip' -Priority 100 -EligibilityStatus $ZipStatus -Selected ($SelectedAdapterId -eq 'archive.zip' -and $Status -eq 'selected')
            New-TestCandidate -AdapterId 'archive.tar' -Priority 200 -EligibilityStatus $TarStatus -Selected ($SelectedAdapterId -eq 'archive.tar' -and $Status -eq 'selected')
        )
        diagnostic = ''
    }
}

function Get-StrategyStep {
    param([object] $Strategy, [string] $StepId)
    return @($Strategy.steps | Where-Object { $_.stepId -eq $StepId } | Select-Object -First 1)[0]
}

function Assert-NoConcreteCommands {
    param([object] $Strategy)

    $json = $Strategy | ConvertTo-Json -Depth 40
    foreach ($pattern in @('ssh\s+\S', 'scp\s+\S', 'rsync\s+\S', 'unzip\s+\S', 'tar\s+-x', '7z\s+\S', 'composer\s+\S', 'artisan\s+\S', 'git\s+\S')) {
        Assert-True (-not ($json -match $pattern)) "Strategy output must not contain concrete command pattern '$pattern'."
    }
    Assert-True (-not ($Strategy.PSObject.Properties.Name -contains 'commands')) 'Strategy output must not expose a commands array.'
    Assert-True (-not ($Strategy.PSObject.Properties.Name -contains 'executor')) 'Strategy output must not expose executor data.'
}

$zipStrategy = Resolve-DeploymentStrategy -ExecutionPlan (New-TestResolvedPlan) -AdapterSelection (New-TestAdapterSelection)
Assert-Equal $zipStrategy.status 'ready' 'ZIP selection must produce ready strategy.'
Assert-Equal $zipStrategy.selectedAdapterId 'archive.zip' 'Selected ZIP adapter must be preserved.'
Assert-Equal ((@($zipStrategy.steps) | ForEach-Object { $_.stepId }) -join ',') 'source.validate,artifact.prepare,archive.create,deployment.approval,remote.release-directory.prepare,remote.archive.upload,remote.archive.extract,remote.application.finalize,deployment.verify' 'Strategy steps must be deterministic.'
Assert-Equal ((Get-StrategyStep -Strategy $zipStrategy -StepId 'remote.archive.upload').dependsOn -join ',') 'remote.release-directory.prepare' 'Dependencies must be deterministic.'
Assert-Equal @($zipStrategy.humanGates).Count 1 'Strategy must create exactly one central deployment approval gate.'
Assert-Equal $zipStrategy.humanGates[0].gateId 'deployment.approval' 'Deployment approval gate must be present.'
Assert-Equal (Get-StrategyStep -Strategy $zipStrategy -StepId 'source.validate').actor 'automation' 'Local source validation must be automation.'
Assert-Equal (Get-StrategyStep -Strategy $zipStrategy -StepId 'archive.create').commandExecutionMode 'automatic' 'Local archive creation must be automatic.'
foreach ($stepId in @('remote.release-directory.prepare', 'remote.archive.upload', 'remote.archive.extract', 'remote.application.finalize')) {
    $step = Get-StrategyStep -Strategy $zipStrategy -StepId $stepId
    Assert-Equal $step.actor 'human-command' "$stepId must be a human-command step."
    Assert-Equal $step.commandExecutionMode 'copy-and-run' "$stepId must require copy-and-run execution."
    Assert-True $step.feedback.required "$stepId must require feedback."
}
Assert-Equal (Get-StrategyStep -Strategy $zipStrategy -StepId 'deployment.verify').actor 'review' 'Deployment verification must be a review step.'
Assert-NoConcreteCommands -Strategy $zipStrategy

$tarStrategy = Resolve-DeploymentStrategy -ExecutionPlan (New-TestResolvedPlan) -AdapterSelection (New-TestAdapterSelection -SelectedAdapterId 'archive.tar' -ZipStatus 'ineligible' -TarStatus 'eligible')
Assert-Equal $tarStrategy.status 'ready' 'TAR selection must produce ready strategy.'
Assert-Equal $tarStrategy.selectedAdapterId 'archive.tar' 'Selected TAR adapter must be preserved.'

$incompleteSelection = New-TestAdapterSelection -Status 'incomplete' -SelectedAdapterId '' -ZipStatus 'unknown' -TarStatus 'ineligible'
Assert-ThrowsLike -Script { Resolve-DeploymentStrategy -ExecutionPlan (New-TestResolvedPlan) -AdapterSelection $incompleteSelection | Out-Null } -Pattern "status must be 'selected'" -Message 'Incomplete selection must be rejected.'

$blockedSelection = New-TestAdapterSelection -Status 'blocked' -SelectedAdapterId '' -ZipStatus 'ineligible' -TarStatus 'ineligible'
Assert-ThrowsLike -Script { Resolve-DeploymentStrategy -ExecutionPlan (New-TestResolvedPlan) -AdapterSelection $blockedSelection | Out-Null } -Pattern "status must be 'selected'" -Message 'Blocked selection must be rejected.'

$emptySelected = New-TestAdapterSelection
$emptySelected.selectedAdapterId = ''
Assert-ThrowsLike -Script { Resolve-DeploymentStrategy -ExecutionPlan (New-TestResolvedPlan) -AdapterSelection $emptySelected | Out-Null } -Pattern "field 'selectedAdapterId' must not be empty" -Message 'Empty selectedAdapterId must be rejected.'

$unknownSelected = New-TestAdapterSelection -SelectedAdapterId 'archive.rar'
Assert-ThrowsLike -Script { Resolve-DeploymentStrategy -ExecutionPlan (New-TestResolvedPlan) -AdapterSelection $unknownSelected | Out-Null } -Pattern "unknown selected adapter id 'archive.rar'" -Message 'Unknown selected adapter must be rejected.'

$missingCandidate = New-TestAdapterSelection
$missingCandidate.candidates = @($missingCandidate.candidates | Where-Object { $_.adapterId -ne 'archive.tar' })
Assert-ThrowsLike -Script { Resolve-DeploymentStrategy -ExecutionPlan (New-TestResolvedPlan) -AdapterSelection $missingCandidate | Out-Null } -Pattern "missing known candidate adapter id 'archive.tar'" -Message 'Missing candidate must be rejected.'

$duplicateCandidate = New-TestAdapterSelection
$duplicateCandidate.candidates += New-TestCandidate -AdapterId 'archive.zip' -Priority 100 -EligibilityStatus 'eligible' -Selected $false
Assert-ThrowsLike -Script { Resolve-DeploymentStrategy -ExecutionPlan (New-TestResolvedPlan) -AdapterSelection $duplicateCandidate | Out-Null } -Pattern "duplicate candidate adapter id 'archive.zip'" -Message 'Duplicate candidate must be rejected.'

$multipleSelected = New-TestAdapterSelection
$multipleSelected.candidates[1].selected = $true
Assert-ThrowsLike -Script { Resolve-DeploymentStrategy -ExecutionPlan (New-TestResolvedPlan) -AdapterSelection $multipleSelected | Out-Null } -Pattern 'exactly one candidate must be selected' -Message 'Multiple selected candidates must be rejected.'

$selectedNotEligible = New-TestAdapterSelection
$selectedNotEligible.candidates[0].eligibilityStatus = 'ineligible'
Assert-ThrowsLike -Script { Resolve-DeploymentStrategy -ExecutionPlan (New-TestResolvedPlan) -AdapterSelection $selectedNotEligible | Out-Null } -Pattern 'selected candidate must be eligible' -Message 'Selected ineligible candidate must be rejected.'

$badPriority = New-TestAdapterSelection
$badPriority.candidates[0].priority = 999
Assert-ThrowsLike -Script { Resolve-DeploymentStrategy -ExecutionPlan (New-TestResolvedPlan) -AdapterSelection $badPriority | Out-Null } -Pattern "does not match catalog priority '100'" -Message 'Candidate priority mismatch must be rejected.'

$wrongSelectedFlag = New-TestAdapterSelection
$wrongSelectedFlag.candidates[0].selected = $false
$wrongSelectedFlag.candidates[1].selected = $true
Assert-ThrowsLike -Script { Resolve-DeploymentStrategy -ExecutionPlan (New-TestResolvedPlan) -AdapterSelection $wrongSelectedFlag | Out-Null } -Pattern 'selected candidate does not match selectedAdapterId' -Message 'Contradictory selected candidate must be rejected.'

$badPlanSchema = New-TestResolvedPlan
$badPlanSchema.schemaVersion = '0.2'
Assert-ThrowsLike -Script { Resolve-DeploymentStrategy -ExecutionPlan $badPlanSchema -AdapterSelection (New-TestAdapterSelection) | Out-Null } -Pattern "unsupported schemaVersion '0.2'" -Message 'Bad plan schema must be rejected.'

$unresolvedPlan = New-TestResolvedPlan
$unresolvedPlan.resolved = $false
Assert-ThrowsLike -Script { Resolve-DeploymentStrategy -ExecutionPlan $unresolvedPlan -AdapterSelection (New-TestAdapterSelection) | Out-Null } -Pattern 'expected resolved = true' -Message 'Unresolved plan must be rejected.'

$missingSteps = New-TestResolvedPlan
$missingSteps.steps = @()
Assert-ThrowsLike -Script { Resolve-DeploymentStrategy -ExecutionPlan $missingSteps -AdapterSelection (New-TestAdapterSelection) | Out-Null } -Pattern 'missing required steps' -Message 'Missing steps must be rejected.'

$duplicateSteps = New-TestResolvedPlan
$duplicateSteps.steps += New-TestPlanStep -Id 'preconditions.analysis-review'
Assert-ThrowsLike -Script { Resolve-DeploymentStrategy -ExecutionPlan $duplicateSteps -AdapterSelection (New-TestAdapterSelection) | Out-Null } -Pattern "duplicate step id 'preconditions.analysis-review'" -Message 'Duplicate step IDs must be rejected.'

$unknownDependency = New-TestResolvedPlan
$unknownDependency.steps[1].dependsOn = @('missing.step')
Assert-ThrowsLike -Script { Resolve-DeploymentStrategy -ExecutionPlan $unknownDependency -AdapterSelection (New-TestAdapterSelection) | Out-Null } -Pattern "depends on unknown step 'missing.step'" -Message 'Unknown dependencies must be rejected.'

$selfDependency = New-TestResolvedPlan
$selfDependency.steps[0].dependsOn = @('preconditions.analysis-review')
Assert-ThrowsLike -Script { Resolve-DeploymentStrategy -ExecutionPlan $selfDependency -AdapterSelection (New-TestAdapterSelection) | Out-Null } -Pattern 'depends on itself' -Message 'Self dependencies must be rejected.'

$cycle = New-TestResolvedPlan
$cycle.steps[0].dependsOn = @('remote.migrations.execute')
Assert-ThrowsLike -Script { Resolve-DeploymentStrategy -ExecutionPlan $cycle -AdapterSelection (New-TestAdapterSelection) | Out-Null } -Pattern 'cyclic dependency detected' -Message 'Cyclic dependencies must be rejected.'

$badExecutionMode = New-TestResolvedPlan
$badExecutionMode.steps[0].executionMode = 'robot'
Assert-ThrowsLike -Script { Resolve-DeploymentStrategy -ExecutionPlan $badExecutionMode -AdapterSelection (New-TestAdapterSelection) | Out-Null } -Pattern "unsupported status 'robot'" -Message 'Invalid execution mode must be rejected.'

$missingPlanInfo = New-TestResolvedPlan
$missingPlanInfo.environment.applicationRemoteDirectory = ''
Assert-ThrowsLike -Script { Resolve-DeploymentStrategy -ExecutionPlan $missingPlanInfo -AdapterSelection (New-TestAdapterSelection) | Out-Null } -Pattern "field 'applicationRemoteDirectory' must not be empty" -Message 'Missing necessary plan information must be rejected.'

$planInput = New-TestResolvedPlan
$selectionInput = New-TestAdapterSelection
$planBefore = $planInput | ConvertTo-Json -Depth 40
$selectionBefore = $selectionInput | ConvertTo-Json -Depth 40
$strategy = Resolve-DeploymentStrategy -ExecutionPlan $planInput -AdapterSelection $selectionInput
Assert-Equal ($planInput | ConvertTo-Json -Depth 40) $planBefore 'Strategy must not mutate execution plan input.'
Assert-Equal ($selectionInput | ConvertTo-Json -Depth 40) $selectionBefore 'Strategy must not mutate adapter selection input.'
$strategy.steps[0].inputReferences = @('changed')
Assert-Equal (($planInput.steps[0].dependsOn) -join ',') '' 'Strategy output must not reference-mutate execution plan input.'
Assert-Equal $selectionInput.selectedAdapterId 'archive.zip' 'Strategy output must not reference-mutate adapter selection input.'

$tmp = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('deployment-strategy-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    $planPath = Join-Path -Path $tmp -ChildPath 'execution-plan.json'
    $selectionPathInput = Join-Path -Path $tmp -ChildPath 'adapter-selection.json'
    $outputPath = Join-Path -Path $tmp -ChildPath 'nested/deployment-strategy.json'
    New-TestResolvedPlan | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $planPath -Encoding UTF8
    New-TestAdapterSelection | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $selectionPathInput -Encoding UTF8

    Assert-ThrowsLike -Script { & $cliPath build-deployment-strategy -AdapterSelectionPath $selectionPathInput -Format Json | Out-Null } -Pattern "Missing required parameter for 'build-deployment-strategy': -ExecutionPlanPath" -Message 'CLI missing ExecutionPlanPath must be rejected.'
    Assert-ThrowsLike -Script { & $cliPath build-deployment-strategy -ExecutionPlanPath $planPath -Format Json | Out-Null } -Pattern "Missing required parameter for 'build-deployment-strategy': -AdapterSelectionPath" -Message 'CLI missing AdapterSelectionPath must be rejected.'
    Assert-ThrowsLike -Script { & $cliPath build-deployment-strategy -ExecutionPlanPath $planPath -AdapterSelectionPath $selectionPathInput -Format Text | Out-Null } -Pattern 'only supports -Format Json' -Message 'CLI invalid format must be rejected.'

    & $cliPath build-deployment-strategy -ExecutionPlanPath $planPath -AdapterSelectionPath $selectionPathInput -OutputPath $outputPath -Format Json | Out-Null
    Assert-True (Test-Path -LiteralPath $outputPath -PathType Leaf) 'CLI must create exactly the explicit output file.'
    $fileStrategy = Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json
    Assert-Equal $fileStrategy.strategyType 'deployment' 'CLI output file must contain deployment strategy JSON.'

    $fileCountBeforeStdout = @(Get-ChildItem -LiteralPath $tmp -File -Recurse).Count
    $stdoutJson = & $cliPath build-deployment-strategy -ExecutionPlanPath $planPath -AdapterSelectionPath $selectionPathInput -Format Json
    $fileCountAfterStdout = @(Get-ChildItem -LiteralPath $tmp -File -Recurse).Count
    $stdoutStrategy = $stdoutJson | ConvertFrom-Json
    Assert-Equal $stdoutStrategy.strategyType 'deployment' 'CLI without OutputPath must emit parseable JSON.'
    Assert-Equal $fileCountAfterStdout $fileCountBeforeStdout 'CLI without OutputPath must not create files in the test run directory.'
    Assert-Equal @($stdoutJson).Count 1 'CLI without OutputPath must not emit additional stdout lines.'

    $invalidJsonPath = Join-Path -Path $tmp -ChildPath 'invalid.json'
    Set-Content -LiteralPath $invalidJsonPath -Value '{ invalid json' -Encoding UTF8
    Assert-ThrowsLike -Script { & $cliPath build-deployment-strategy -ExecutionPlanPath $invalidJsonPath -AdapterSelectionPath $selectionPathInput -Format Json | Out-Null } -Pattern 'Invalid Resolved execution plan JSON' -Message 'Invalid execution plan JSON must be rejected.'

    $missingPath = Join-Path -Path $tmp -ChildPath 'missing.json'
    Assert-ThrowsLike -Script { & $cliPath build-deployment-strategy -ExecutionPlanPath $missingPath -AdapterSelectionPath $selectionPathInput -Format Json | Out-Null } -Pattern 'Resolved execution plan file does not exist' -Message 'Missing execution plan file must be rejected.'
} finally {
    if (Test-Path -LiteralPath $tmp) {
        Remove-Item -LiteralPath $tmp -Recurse -Force
    }
}

if ($script:failures.Count -gt 0) {
    Write-Host 'Deployment Strategy tests failed:'
    $script:failures | ForEach-Object { Write-Host "- $_" }
    exit 1
}

Write-Host 'Deployment Strategy tests passed.'
exit 0
