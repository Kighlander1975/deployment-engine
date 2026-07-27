[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:failures = New-Object System.Collections.Generic.List[string]
$engineRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '..'))
$commandPlanPath = Join-Path -Path $engineRoot -ChildPath 'src/ps1/Build-CommandPlan.ps1'
$cliPath = Join-Path -Path $engineRoot -ChildPath 'bin/deployment-engine.ps1'

. $commandPlanPath

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
    param([scriptblock] $Script, [string] $Pattern, [string] $Message)

    try {
        & $Script
        $script:failures.Add($Message)
    } catch {
        Assert-True ($_.Exception.Message -match $Pattern) "$Message Actual error: $($_.Exception.Message)"
    }
}

function New-TestPlanStep {
    param([Parameter(Mandatory = $true)][string] $Id)

    return [pscustomobject]@{
        id = $Id
        phase = 'test'
        title = $Id
        executionMode = 'agent'
        required = $true
        status = 'ready'
        reason = ''
        approvalRequired = $false
        destructive = $false
        riskLevel = 'normal'
        capabilityId = ''
        dependsOn = @()
        instructions = [pscustomobject]@{}
        validation = [pscustomobject]@{}
        continuation = [pscustomobject]@{}
    }
}

function New-TestResolvedPlan {
    param([string] $RemotePath = '/www/htdocs/w017bd08/shk-momm.de')

    return [pscustomobject]@{
        schemaVersion = '0.1'
        sourceAnalysisVersion = '0.1'
        resolved = $true
        blocked = $false
        project = [pscustomobject]@{ id = 'pilot'; name = 'Pilot'; type = 'laravel' }
        environment = [pscustomobject]@{
            name = 'production'
            serverRoot = '/www/htdocs/w017bd08'
            applicationRemoteDirectory = $RemotePath
            markerFile = 'deploy-version'
        }
        baselineCommit = 'abc'
        targetCommit = 'def'
        decisions = [pscustomobject]@{ runtimeDeploymentRequired = $true }
        warnings = @()
        blockers = @()
        manualApprovalPoints = @()
        phases = @('preconditions')
        steps = @(New-TestPlanStep -Id 'preconditions.analysis-review')
    }
}

function New-TestFeedback {
    return [pscustomobject]@{
        required = $true
        type = 'command-result'
        expectedData = @('exitStatus', 'stdout', 'stderr')
    }
}

function New-TestStrategyStep {
    param(
        [Parameter(Mandatory = $true)][string] $StepId,
        [Parameter(Mandatory = $true)][int] $Sequence,
        [Parameter(Mandatory = $true)][string] $OperationType,
        [Parameter(Mandatory = $true)][string] $Actor,
        [Parameter(Mandatory = $true)][string] $Location,
        [Parameter(Mandatory = $true)][string] $Mode,
        [bool] $Required = $true,
        [string[]] $DependsOn = @()
    )

    $step = [pscustomobject]@{
        stepId = $StepId
        sequence = $Sequence
        operationType = $OperationType
        actor = $Actor
        executionLocation = $Location
        dependsOn = @($DependsOn)
        commandGenerationRequired = $Required
        commandExecutionMode = $Mode
        approvalRequired = ($Actor -eq 'human-decision')
        inputReferences = @()
        outputReferences = @()
        diagnostic = ''
    }
    if ($Mode -eq 'copy-and-run') {
        Add-Member -InputObject $step -MemberType NoteProperty -Name 'feedback' -Value (New-TestFeedback)
    }
    return $step
}

function New-TestDeploymentStrategy {
    param(
        [string] $SelectedAdapterId = 'archive.zip',
        [string] $Status = 'ready',
        [bool] $WithCommandInputs = $true
    )

    $strategy = [pscustomobject]@{
        schemaVersion = '0.1'
        strategyType = 'deployment'
        status = $Status
        selectedAdapterId = $SelectedAdapterId
        strategy = [pscustomobject]@{ executionModel = 'human-gated-automation'; sshExecutionMode = 'human-command'; localAutomationPolicy = 'automatic-unless-decision-required' }
        steps = @(
            New-TestStrategyStep -StepId 'source.validate' -Sequence 100 -OperationType 'source-validate' -Actor 'automation' -Location 'local' -Mode 'automatic'
            New-TestStrategyStep -StepId 'artifact.prepare' -Sequence 200 -OperationType 'artifact-prepare' -Actor 'automation' -Location 'local' -Mode 'automatic' -Required $false -DependsOn @('source.validate')
            New-TestStrategyStep -StepId 'archive.create' -Sequence 300 -OperationType 'archive-create' -Actor 'automation' -Location 'local' -Mode 'automatic' -DependsOn @('artifact.prepare')
            New-TestStrategyStep -StepId 'deployment.approval' -Sequence 400 -OperationType 'deployment-approval' -Actor 'human-decision' -Location 'decision' -Mode 'none' -Required $false -DependsOn @('archive.create')
            New-TestStrategyStep -StepId 'remote.release-directory.prepare' -Sequence 500 -OperationType 'release-directory-prepare' -Actor 'human-command' -Location 'remote' -Mode 'copy-and-run' -DependsOn @('deployment.approval')
            New-TestStrategyStep -StepId 'remote.archive.upload' -Sequence 600 -OperationType 'archive-upload' -Actor 'human-command' -Location 'local-to-remote' -Mode 'copy-and-run' -DependsOn @('remote.release-directory.prepare')
            New-TestStrategyStep -StepId 'remote.archive.extract' -Sequence 700 -OperationType 'archive-extract' -Actor 'human-command' -Location 'remote' -Mode 'copy-and-run' -DependsOn @('remote.archive.upload')
            New-TestStrategyStep -StepId 'remote.application.finalize' -Sequence 800 -OperationType 'application-finalize' -Actor 'human-command' -Location 'remote' -Mode 'copy-and-run' -DependsOn @('remote.archive.extract')
            New-TestStrategyStep -StepId 'deployment.verify' -Sequence 900 -OperationType 'deployment-verify' -Actor 'review' -Location 'review' -Mode 'none' -Required $false -DependsOn @('remote.application.finalize')
        )
        humanGates = @(
            [pscustomobject]@{ gateId = 'deployment.approval'; stepId = 'deployment.approval'; gateType = 'approval'; blocksContinuation = $true }
        )
        diagnostic = ''
    }
    if ($WithCommandInputs) {
        Add-Member -InputObject $strategy -MemberType NoteProperty -Name 'commandInputs' -Value ([pscustomobject]@{
            sshTarget = 'deploy@example.org'
            remoteProjectPath = '/www/htdocs/w017bd08/shk-momm.de'
            remoteReleasePath = '/www/htdocs/w017bd08/shk-momm.de/releases/current candidate'
            localArtifactPath = 'C:\Build Output\release (final) & safe\artifact''s "$demo" `tick`.zip'
            artifactFileName = 'artifact ä final.zip'
            remoteArchivePath = '/www/htdocs/w017bd08/shk-momm.de/releases/current candidate/artifact ä final.zip'
        })
    }

    return $strategy
}

function Get-Command {
    param([object] $CommandPlan, [string] $CommandId)
    return @($CommandPlan.commands | Where-Object { $_.commandId -eq $CommandId } | Select-Object -First 1)[0]
}

function Assert-CommandPlanSafe {
    param([object] $CommandPlan)

    Assert-True (-not $CommandPlan.executionPolicy.executionAllowed) 'Command plan must never allow execution.'
    Assert-True (-not $CommandPlan.executionPolicy.automaticExecutionAllowed) 'Command plan must never allow automatic execution.'
    foreach ($command in @($CommandPlan.commands)) {
        Assert-True (-not $command.safety.executionPermitted) "Command '$($command.commandId)' must not permit execution."
    }
    $json = $CommandPlan | ConvertTo-Json -Depth 60
    foreach ($pattern in @('password=', 'token=', 'private key', 'BEGIN OPENSSH PRIVATE KEY', '\.env')) {
        Assert-True (-not ($json -match $pattern)) "Command plan must not contain forbidden content '$pattern'."
    }
}

$zipPlan = Resolve-CommandPlan -ExecutionPlan (New-TestResolvedPlan) -DeploymentStrategy (New-TestDeploymentStrategy -SelectedAdapterId 'archive.zip')
Assert-Equal $zipPlan.commandPlanType 'deployment-command-plan' 'Command plan type must be correct.'
Assert-Equal $zipPlan.status 'ready' 'Complete ZIP inputs must produce ready command plan.'
Assert-Equal $zipPlan.selectedAdapterId 'archive.zip' 'ZIP adapter must be preserved.'
Assert-Equal ((@($zipPlan.commands) | ForEach-Object { $_.commandId }) -join ',') 'source.validate,archive.create,remote.release-directory.prepare,remote.archive.upload,remote.archive.extract,remote.application.finalize' 'Commands must be sorted deterministically.'
Assert-Equal (Get-Command -CommandPlan $zipPlan -CommandId 'archive.create').program 'local-operation' 'Local automation must use structured local-operation program.'
Assert-Equal (Get-Command -CommandPlan $zipPlan -CommandId 'archive.create').renderedCommand '' 'Local operation must not invent a shell command.'
Assert-Equal (Get-Command -CommandPlan $zipPlan -CommandId 'remote.release-directory.prepare').program 'ssh' 'Remote prepare must use ssh program.'
Assert-Equal (Get-Command -CommandPlan $zipPlan -CommandId 'remote.archive.upload').program 'scp' 'Archive upload must use scp program.'
Assert-Equal (Get-Command -CommandPlan $zipPlan -CommandId 'remote.archive.extract').executionMode 'copy-and-run' 'Remote extract must be copy-and-run.'
Assert-True (Get-Command -CommandPlan $zipPlan -CommandId 'remote.archive.extract').display.copyable 'Human commands must be copyable.'
Assert-Equal ((Get-Command -CommandPlan $zipPlan -CommandId 'remote.archive.upload').feedback.expectedData -join ',') 'exitStatus,stdout,stderr' 'Human commands must request structured feedback.'
Assert-True ((Get-Command -CommandPlan $zipPlan -CommandId 'remote.archive.extract').arguments -contains 'extract-zip') 'ZIP adapter must affect extraction intent.'
Assert-CommandPlanSafe -CommandPlan $zipPlan

$tarPlan = Resolve-CommandPlan -ExecutionPlan (New-TestResolvedPlan) -DeploymentStrategy (New-TestDeploymentStrategy -SelectedAdapterId 'archive.tar')
Assert-Equal $tarPlan.status 'ready' 'Complete TAR inputs must produce ready command plan.'
Assert-Equal $tarPlan.selectedAdapterId 'archive.tar' 'TAR adapter must be preserved.'
Assert-True ((Get-Command -CommandPlan $tarPlan -CommandId 'remote.archive.extract').arguments -contains 'extract-tar') 'TAR adapter must affect extraction intent.'

$noInputPlan = Resolve-CommandPlan -ExecutionPlan (New-TestResolvedPlan) -DeploymentStrategy (New-TestDeploymentStrategy -WithCommandInputs:$false)
Assert-Equal $noInputPlan.status 'incomplete' 'Missing SSH target must produce incomplete command plan.'
Assert-Equal (Get-Command -CommandPlan $noInputPlan -CommandId 'remote.release-directory.prepare').renderedCommand '' 'Incomplete human command must not render a command.'

$relativeRemote = New-TestDeploymentStrategy
$relativeRemote.commandInputs.remoteProjectPath = './release'
Assert-Equal (Resolve-CommandPlan -ExecutionPlan (New-TestResolvedPlan) -DeploymentStrategy $relativeRemote).status 'incomplete' 'Relative remote path must produce incomplete command plan.'

$missingRemotePath = New-TestResolvedPlan -RemotePath ''
Assert-ThrowsLike -Script { Resolve-CommandPlan -ExecutionPlan $missingRemotePath -DeploymentStrategy (New-TestDeploymentStrategy) | Out-Null } -Pattern "field 'applicationRemoteDirectory' must not be empty" -Message 'Missing remote path must be rejected by execution plan validation.'

$missingArtifact = New-TestDeploymentStrategy
$missingArtifact.commandInputs.localArtifactPath = ''
Assert-Equal (Resolve-CommandPlan -ExecutionPlan (New-TestResolvedPlan) -DeploymentStrategy $missingArtifact).status 'incomplete' 'Missing local artifact path must produce incomplete command plan.'

$unknownAdapter = New-TestDeploymentStrategy -SelectedAdapterId 'archive.rar'
Assert-ThrowsLike -Script { Resolve-CommandPlan -ExecutionPlan (New-TestResolvedPlan) -DeploymentStrategy $unknownAdapter | Out-Null } -Pattern "unknown selected adapter id 'archive.rar'" -Message 'Unknown adapter must be rejected.'

$blockedStrategy = New-TestDeploymentStrategy -Status 'blocked'
Assert-ThrowsLike -Script { Resolve-CommandPlan -ExecutionPlan (New-TestResolvedPlan) -DeploymentStrategy $blockedStrategy | Out-Null } -Pattern "status must be 'ready'" -Message 'Blocked strategy must be rejected.'

$incompleteStrategy = New-TestDeploymentStrategy -Status 'incomplete'
Assert-ThrowsLike -Script { Resolve-CommandPlan -ExecutionPlan (New-TestResolvedPlan) -DeploymentStrategy $incompleteStrategy | Out-Null } -Pattern "status must be 'ready'" -Message 'Incomplete strategy must be rejected.'

$badSchema = New-TestDeploymentStrategy
$badSchema.schemaVersion = '0.2'
Assert-ThrowsLike -Script { Resolve-CommandPlan -ExecutionPlan (New-TestResolvedPlan) -DeploymentStrategy $badSchema | Out-Null } -Pattern "unsupported schemaVersion '0.2'" -Message 'Bad strategy schema must be rejected.'

$noApproval = New-TestDeploymentStrategy
$noApproval.humanGates = @()
Assert-ThrowsLike -Script { Resolve-CommandPlan -ExecutionPlan (New-TestResolvedPlan) -DeploymentStrategy $noApproval | Out-Null } -Pattern 'exactly one central deployment approval gate' -Message 'Missing approval gate must be rejected.'

$badActorMode = New-TestDeploymentStrategy
@($badActorMode.steps | Where-Object { $_.stepId -eq 'remote.archive.extract' } | Select-Object -First 1)[0].commandExecutionMode = 'automatic'
Assert-ThrowsLike -Script { Resolve-CommandPlan -ExecutionPlan (New-TestResolvedPlan) -DeploymentStrategy $badActorMode | Out-Null } -Pattern 'human-command requires copy-and-run' -Message 'Invalid human-command mode must be rejected.'

$planInput = New-TestResolvedPlan
$strategyInput = New-TestDeploymentStrategy
$planBefore = $planInput | ConvertTo-Json -Depth 60
$strategyBefore = $strategyInput | ConvertTo-Json -Depth 60
$commandPlan = Resolve-CommandPlan -ExecutionPlan $planInput -DeploymentStrategy $strategyInput
Assert-Equal ($planInput | ConvertTo-Json -Depth 60) $planBefore 'Command generation must not mutate execution plan input.'
Assert-Equal ($strategyInput | ConvertTo-Json -Depth 60) $strategyBefore 'Command generation must not mutate deployment strategy input.'
$commandPlan.commands[0].arguments = @('changed')
Assert-Equal $strategyInput.steps[0].operationType 'source-validate' 'Command output must not reference-mutate strategy input.'

$quoted = ConvertTo-RenderedCommand -Program 'ssh' -Arguments @('deploy@example.org', 'show', "space path", "single'quote", 'double"quote', '(paren)', 'amp&ersand', 'semi;colon', 'dollar$sign', 'back`tick', 'ümlaut')
foreach ($expected in @("'show ''space path''", 'single', 'quote', 'double"quote', '(paren)', 'amp&ersand', 'semi;colon', 'dollar$sign', 'back`tick', 'ümlaut')) {
    Assert-True ($quoted -match [regex]::Escape($expected)) "Rendered SSH command must preserve quoted argument fragment '$expected'."
}

$source = Get-Content -LiteralPath $commandPlanPath -Raw
foreach ($forbidden in @('Start-Process', 'Invoke-Expression', 'System.Diagnostics.Process', 'ProcessStartInfo', 'ssh.exe', 'scp.exe', 'git.exe', 'tar.exe', '7z.exe', 'iex ', 'cmd /c', 'bash -c', 'sh -c')) {
    Assert-True (-not ($source -match [regex]::Escape($forbidden))) "Command generation source must not contain process starter '$forbidden'."
}

$tmp = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('command-generation-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    $planPath = Join-Path -Path $tmp -ChildPath 'execution-plan.json'
    $strategyPathInput = Join-Path -Path $tmp -ChildPath 'deployment-strategy.json'
    $outputPath = Join-Path -Path $tmp -ChildPath 'nested/command-plan.json'
    New-TestResolvedPlan | ConvertTo-Json -Depth 60 | Set-Content -LiteralPath $planPath -Encoding UTF8
    New-TestDeploymentStrategy | ConvertTo-Json -Depth 60 | Set-Content -LiteralPath $strategyPathInput -Encoding UTF8

    Assert-ThrowsLike -Script { & $cliPath generate-commands -DeploymentStrategyPath $strategyPathInput -Format Json | Out-Null } -Pattern "Missing required parameter for 'generate-commands': -ExecutionPlanPath" -Message 'CLI missing ExecutionPlanPath must be rejected.'
    Assert-ThrowsLike -Script { & $cliPath generate-commands -ExecutionPlanPath $planPath -Format Json | Out-Null } -Pattern "Missing required parameter for 'generate-commands': -DeploymentStrategyPath" -Message 'CLI missing DeploymentStrategyPath must be rejected.'
    Assert-ThrowsLike -Script { & $cliPath generate-commands -ExecutionPlanPath $planPath -DeploymentStrategyPath $strategyPathInput -Format Text | Out-Null } -Pattern 'only supports -Format Json' -Message 'CLI invalid format must be rejected.'

    & $cliPath generate-commands -ExecutionPlanPath $planPath -DeploymentStrategyPath $strategyPathInput -OutputPath $outputPath -Format Json | Out-Null
    Assert-True (Test-Path -LiteralPath $outputPath -PathType Leaf) 'CLI must create exactly the explicit command plan file.'
    $filePlan = Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json
    Assert-Equal $filePlan.commandPlanType 'deployment-command-plan' 'CLI output file must contain command plan JSON.'

    $fileCountBeforeStdout = @(Get-ChildItem -LiteralPath $tmp -File -Recurse).Count
    $stdoutJson = & $cliPath generate-commands -ExecutionPlanPath $planPath -DeploymentStrategyPath $strategyPathInput -Format Json
    $fileCountAfterStdout = @(Get-ChildItem -LiteralPath $tmp -File -Recurse).Count
    $stdoutPlan = $stdoutJson | ConvertFrom-Json
    Assert-Equal $stdoutPlan.commandPlanType 'deployment-command-plan' 'CLI without OutputPath must emit parseable JSON.'
    Assert-Equal @($stdoutJson).Count 1 'CLI without OutputPath must not emit additional stdout lines.'
    Assert-Equal $fileCountAfterStdout $fileCountBeforeStdout 'CLI without OutputPath must not create files in the test run directory.'

    $invalidJsonPath = Join-Path -Path $tmp -ChildPath 'invalid.json'
    Set-Content -LiteralPath $invalidJsonPath -Value '{ invalid json' -Encoding UTF8
    Assert-ThrowsLike -Script { & $cliPath generate-commands -ExecutionPlanPath $invalidJsonPath -DeploymentStrategyPath $strategyPathInput -Format Json | Out-Null } -Pattern 'Invalid Resolved execution plan JSON' -Message 'Invalid JSON must be rejected.'
} finally {
    if (Test-Path -LiteralPath $tmp) {
        Remove-Item -LiteralPath $tmp -Recurse -Force
    }
}

if ($script:failures.Count -gt 0) {
    Write-Host 'Command Generation tests failed:'
    $script:failures | ForEach-Object { Write-Host "- $_" }
    exit 1
}

Write-Host 'Command Generation tests passed.'
exit 0
