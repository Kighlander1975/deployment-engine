[CmdletBinding()]
param(
    [string] $ExecutionPlanPath,
    [string] $DeploymentStrategyPath,
    [string] $OutputPath,
    [string] $Format = 'Json'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path -Path $PSScriptRoot -ChildPath 'DeploymentAdapters.ps1')

function Resolve-CommandPlanPath {
    param([Parameter(Mandatory = $true)][string] $Path)

    $executionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function Read-CommandPlanJsonFile {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Description
    )

    $resolved = Resolve-CommandPlanPath -Path $Path
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
        throw "$Description file does not exist: $resolved"
    }

    try {
        return (Get-Content -LiteralPath $resolved -Raw | ConvertFrom-Json)
    } catch {
        throw "Invalid $Description JSON in '$resolved': $($_.Exception.Message)"
    }
}

function Test-CommandPlanProperty {
    param([object] $Object, [Parameter(Mandatory = $true)][string] $Name)

    return ($null -ne $Object -and @($Object.PSObject.Properties | Where-Object { $_.Name -eq $Name }).Count -gt 0)
}

function Test-CommandPlanObjectLike {
    param([object] $Value)

    if ($null -eq $Value -or $Value -is [string] -or $Value -is [System.ValueType]) {
        return $false
    }
    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [System.Collections.IDictionary]) -and -not ($Value -is [pscustomobject])) {
        return $false
    }

    return ($null -ne $Value.PSObject -and $null -ne $Value.PSObject.Properties)
}

function Assert-CommandPlanString {
    param(
        [Parameter(Mandatory = $true)][object] $Object,
        [Parameter(Mandatory = $true)][string] $Name,
        [Parameter(Mandatory = $true)][string] $Context,
        [bool] $AllowEmpty = $false
    )

    if (-not (Test-CommandPlanProperty -Object $Object -Name $Name)) {
        throw "$Context validation failed: missing required field '$Name'."
    }
    if (-not ($Object.$Name -is [string])) {
        throw "$Context validation failed: field '$Name' must be a string."
    }
    if (-not $AllowEmpty -and [string]::IsNullOrWhiteSpace([string] $Object.$Name)) {
        throw "$Context validation failed: field '$Name' must not be empty."
    }
}

function Assert-CommandPlanBool {
    param(
        [Parameter(Mandatory = $true)][object] $Object,
        [Parameter(Mandatory = $true)][string] $Name,
        [Parameter(Mandatory = $true)][string] $Context
    )

    if (-not (Test-CommandPlanProperty -Object $Object -Name $Name)) {
        throw "$Context validation failed: missing required field '$Name'."
    }
    if (-not ($Object.$Name -is [bool])) {
        throw "$Context validation failed: field '$Name' must be boolean."
    }
}

function Assert-CommandPlanInteger {
    param(
        [Parameter(Mandatory = $true)][object] $Value,
        [Parameter(Mandatory = $true)][string] $Context,
        [Parameter(Mandatory = $true)][string] $Field
    )

    if (-not ($Value -is [byte] -or $Value -is [int16] -or $Value -is [int] -or $Value -is [long])) {
        throw "$Context validation failed: field '$Field' must be an integer."
    }
}

function Assert-CommandPlanStatus {
    param(
        [Parameter(Mandatory = $true)][string] $Status,
        [Parameter(Mandatory = $true)][string[]] $AllowedStatuses,
        [Parameter(Mandatory = $true)][string] $Context
    )

    if ($Status -notin $AllowedStatuses) {
        throw "$Context validation failed: unsupported status '$Status'."
    }
}

function Test-AbsolutePosixPath {
    param([string] $Path)

    return (-not [string]::IsNullOrWhiteSpace($Path) -and $Path.StartsWith('/') -and -not $Path.StartsWith('//') -and $Path -notmatch '(^|/)\.\.?(/|$)')
}

function Test-SecretLikeText {
    param([string] $Text)

    if ([string]::IsNullOrEmpty($Text)) {
        return $false
    }

    return ($Text -match '(?i)(password=|token=|private key|BEGIN OPENSSH PRIVATE KEY|\.env|api[_-]?key|client[_-]?secret)')
}

function Assert-NoCommandPlanSecrets {
    param([Parameter(Mandatory = $true)][object] $Value, [Parameter(Mandatory = $true)][string] $Context)

    $json = $Value | ConvertTo-Json -Depth 50
    if (Test-SecretLikeText -Text $json) {
        throw "$Context validation failed: secret-like content is not allowed."
    }
}

function Assert-ResolvedExecutionPlanForCommandGeneration {
    param([Parameter(Mandatory = $true)][object] $ExecutionPlan)

    if ($null -eq $ExecutionPlan) {
        throw "Command generation validation failed: resolved execution plan is missing."
    }
    Assert-CommandPlanString -Object $ExecutionPlan -Name 'schemaVersion' -Context 'Resolved execution plan'
    if ($ExecutionPlan.schemaVersion -ne '0.1') {
        throw "Resolved execution plan validation failed: unsupported schemaVersion '$($ExecutionPlan.schemaVersion)'."
    }
    if (-not (Test-CommandPlanProperty -Object $ExecutionPlan -Name 'resolved') -or $ExecutionPlan.resolved -ne $true) {
        throw "Resolved execution plan validation failed: expected resolved = true."
    }
    foreach ($field in @('project', 'environment', 'steps')) {
        if (-not (Test-CommandPlanProperty -Object $ExecutionPlan -Name $field) -or $null -eq $ExecutionPlan.$field) {
            throw "Resolved execution plan validation failed: missing required field '$field'."
        }
    }
    Assert-CommandPlanString -Object $ExecutionPlan.project -Name 'id' -Context 'Resolved execution plan project'
    Assert-CommandPlanString -Object $ExecutionPlan.environment -Name 'name' -Context 'Resolved execution plan environment'
    Assert-CommandPlanString -Object $ExecutionPlan.environment -Name 'applicationRemoteDirectory' -Context 'Resolved execution plan environment'
    if (-not (Test-AbsolutePosixPath -Path ([string] $ExecutionPlan.environment.applicationRemoteDirectory))) {
        throw "Resolved execution plan validation failed: applicationRemoteDirectory must be an absolute remote path."
    }

    $stepIds = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    foreach ($step in @($ExecutionPlan.steps)) {
        if (-not (Test-CommandPlanObjectLike -Value $step)) {
            throw "Resolved execution plan validation failed: each step must be an object."
        }
        Assert-CommandPlanString -Object $step -Name 'id' -Context 'Resolved execution plan step'
        if (-not $stepIds.Add([string] $step.id)) {
            throw "Resolved execution plan validation failed: duplicate step id '$($step.id)'."
        }
    }
    Assert-NoCommandPlanSecrets -Value $ExecutionPlan -Context 'Resolved execution plan'
}

function Assert-DeploymentStrategyForCommandGeneration {
    param(
        [Parameter(Mandatory = $true)][object] $DeploymentStrategy,
        [object] $AdapterCatalog = (Get-DeploymentAdapterCatalog)
    )

    if ($null -eq $DeploymentStrategy) {
        throw "Command generation validation failed: deployment strategy is missing."
    }
    Assert-CommandPlanString -Object $DeploymentStrategy -Name 'schemaVersion' -Context 'Deployment strategy'
    if ($DeploymentStrategy.schemaVersion -ne '0.1') {
        throw "Deployment strategy validation failed: unsupported schemaVersion '$($DeploymentStrategy.schemaVersion)'."
    }
    Assert-CommandPlanString -Object $DeploymentStrategy -Name 'strategyType' -Context 'Deployment strategy'
    if ($DeploymentStrategy.strategyType -ne 'deployment') {
        throw "Deployment strategy validation failed: strategyType must be 'deployment'."
    }
    Assert-CommandPlanString -Object $DeploymentStrategy -Name 'status' -Context 'Deployment strategy'
    if ($DeploymentStrategy.status -ne 'ready') {
        throw "Deployment strategy validation failed: status must be 'ready' before command generation."
    }
    Assert-CommandPlanString -Object $DeploymentStrategy -Name 'selectedAdapterId' -Context 'Deployment strategy'
    if (-not $AdapterCatalog.Contains([string] $DeploymentStrategy.selectedAdapterId)) {
        throw "Deployment strategy validation failed: unknown selected adapter id '$($DeploymentStrategy.selectedAdapterId)'."
    }
    if (-not (Test-CommandPlanProperty -Object $DeploymentStrategy -Name 'steps') -or $null -eq $DeploymentStrategy.steps -or @($DeploymentStrategy.steps).Count -eq 0) {
        throw "Deployment strategy validation failed: steps must not be empty."
    }
    if (-not (Test-CommandPlanProperty -Object $DeploymentStrategy -Name 'humanGates') -or $null -eq $DeploymentStrategy.humanGates) {
        throw "Deployment strategy validation failed: humanGates must not be null."
    }

    $stepIds = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    $sequences = New-Object 'System.Collections.Generic.HashSet[int]'
    foreach ($step in @($DeploymentStrategy.steps)) {
        if (-not (Test-CommandPlanObjectLike -Value $step)) {
            throw "Deployment strategy validation failed: each step must be an object."
        }
        Assert-CommandPlanString -Object $step -Name 'stepId' -Context 'Deployment strategy step'
        $stepId = [string] $step.stepId
        if (-not $stepIds.Add($stepId)) {
            throw "Deployment strategy validation failed: duplicate step id '$stepId'."
        }
        foreach ($field in @('sequence', 'commandGenerationRequired')) {
            if (-not (Test-CommandPlanProperty -Object $step -Name $field)) {
                throw "Deployment strategy step '$stepId' validation failed: missing required field '$field'."
            }
        }
        Assert-CommandPlanInteger -Value $step.sequence -Context "Deployment strategy step '$stepId'" -Field 'sequence'
        [void] $sequences.Add([int] $step.sequence)
        Assert-CommandPlanString -Object $step -Name 'operationType' -Context "Deployment strategy step '$stepId'"
        Assert-CommandPlanString -Object $step -Name 'actor' -Context "Deployment strategy step '$stepId'"
        Assert-CommandPlanStatus -Status ([string] $step.actor) -AllowedStatuses @('automation', 'human-decision', 'human-command', 'review') -Context "Deployment strategy step '$stepId'"
        Assert-CommandPlanString -Object $step -Name 'executionLocation' -Context "Deployment strategy step '$stepId'"
        Assert-CommandPlanStatus -Status ([string] $step.executionLocation) -AllowedStatuses @('local', 'remote', 'local-to-remote', 'decision', 'review') -Context "Deployment strategy step '$stepId'"
        Assert-CommandPlanString -Object $step -Name 'commandExecutionMode' -Context "Deployment strategy step '$stepId'"
        Assert-CommandPlanStatus -Status ([string] $step.commandExecutionMode) -AllowedStatuses @('none', 'automatic', 'copy-and-run') -Context "Deployment strategy step '$stepId'"
        Assert-CommandPlanBool -Object $step -Name 'commandGenerationRequired' -Context "Deployment strategy step '$stepId'"
        Assert-CommandPlanBool -Object $step -Name 'approvalRequired' -Context "Deployment strategy step '$stepId'"
        if (-not (Test-CommandPlanProperty -Object $step -Name 'dependsOn') -or $null -eq $step.dependsOn) {
            throw "Deployment strategy step '$stepId' validation failed: missing required field 'dependsOn'."
        }
        if ($step.actor -eq 'human-command' -and $step.commandExecutionMode -ne 'copy-and-run') {
            throw "Deployment strategy step '$stepId' validation failed: human-command requires copy-and-run."
        }
        if ($step.actor -eq 'human-decision' -and $step.commandExecutionMode -ne 'none') {
            throw "Deployment strategy step '$stepId' validation failed: human-decision requires commandExecutionMode none."
        }
        if ($step.actor -eq 'review' -and $step.commandExecutionMode -ne 'none') {
            throw "Deployment strategy step '$stepId' validation failed: review requires commandExecutionMode none."
        }
        if ($step.commandExecutionMode -eq 'copy-and-run') {
            if (-not (Test-CommandPlanProperty -Object $step -Name 'feedback') -or -not (Test-CommandPlanObjectLike -Value $step.feedback)) {
                throw "Deployment strategy step '$stepId' validation failed: copy-and-run requires feedback."
            }
            Assert-CommandPlanBool -Object $step.feedback -Name 'required' -Context "Deployment strategy step '$stepId' feedback"
            if (-not $step.feedback.required) {
                throw "Deployment strategy step '$stepId' validation failed: copy-and-run feedback must be required."
            }
        }
    }

    foreach ($step in @($DeploymentStrategy.steps)) {
        foreach ($dependency in @($step.dependsOn | Sort-Object -Unique)) {
            $dependencyId = [string] $dependency
            if ([string]::IsNullOrWhiteSpace($dependencyId)) {
                continue
            }
            if (-not $stepIds.Contains($dependencyId)) {
                throw "Deployment strategy validation failed: step '$($step.stepId)' depends on unknown step '$dependencyId'."
            }
        }
    }

    $approvalGates = @($DeploymentStrategy.humanGates | Where-Object { $_.gateId -eq 'deployment.approval' })
    if ($approvalGates.Count -ne 1) {
        throw "Deployment strategy validation failed: exactly one central deployment approval gate is required."
    }

    $json = $DeploymentStrategy | ConvertTo-Json -Depth 50
    if ($json -match '"commands"\s*:|"renderedCommand"\s*:') {
        throw "Deployment strategy validation failed: strategy must not contain concrete commands."
    }
    Assert-NoCommandPlanSecrets -Value $DeploymentStrategy -Context 'Deployment strategy'
}

function Quote-PowerShellArgument {
    param([AllowNull()][object] $Value)

    $text = if ($null -eq $Value) { '' } else { [string] $Value }
    if ($text -match '^[A-Za-z0-9_@%+=:,./\\\\-]+$') {
        return $text
    }
    return "'" + ($text -replace "'", "''") + "'"
}

function Quote-PosixShellArgument {
    param([AllowNull()][object] $Value)

    $text = if ($null -eq $Value) { '' } else { [string] $Value }
    if ($text -match '^[A-Za-z0-9_@%+=:,./-]+$') {
        return $text
    }
    return "'" + ($text -replace "'", "'\''") + "'"
}

function ConvertTo-RenderedCommand {
    param(
        [Parameter(Mandatory = $true)][string] $Program,
        [string[]] $Arguments = @()
    )

    switch ($Program) {
        'local-operation' { return '' }
        'ssh' {
            if (@($Arguments).Count -le 1) {
                return (@('ssh') + @($Arguments | ForEach-Object { Quote-PowerShellArgument -Value $_ })) -join ' '
            }
            $target = Quote-PowerShellArgument -Value $Arguments[0]
            $remoteCommand = (@($Arguments | Select-Object -Skip 1 | ForEach-Object { Quote-PosixShellArgument -Value $_ }) -join ' ')
            return (@('ssh', $target, (Quote-PowerShellArgument -Value $remoteCommand)) -join ' ')
        }
        'scp' { return (@('scp') + @($Arguments | ForEach-Object { Quote-PowerShellArgument -Value $_ })) -join ' ' }
        default { throw "Command rendering failed: unsupported program '$Program'." }
    }
}

function Get-CommandGenerationInputs {
    param([Parameter(Mandatory = $true)][object] $DeploymentStrategy)

    if ((Test-CommandPlanProperty -Object $DeploymentStrategy -Name 'commandInputs') -and (Test-CommandPlanObjectLike -Value $DeploymentStrategy.commandInputs)) {
        return $DeploymentStrategy.commandInputs
    }

    return [pscustomobject]@{}
}

function Get-OptionalInputString {
    param([Parameter(Mandatory = $true)][object] $Inputs, [Parameter(Mandatory = $true)][string] $Name)

    if (Test-CommandPlanProperty -Object $Inputs -Name $Name) {
        return [string] $Inputs.$Name
    }

    return ''
}

function New-CommandPlanFeedback {
    param([object] $StrategyStep)

    if ((Test-CommandPlanProperty -Object $StrategyStep -Name 'feedback') -and (Test-CommandPlanObjectLike -Value $StrategyStep.feedback)) {
        return [pscustomobject]@{
            required = [bool] $StrategyStep.feedback.required
            expectedData = @($StrategyStep.feedback.expectedData | ForEach-Object { [string] $_ })
        }
    }

    return [pscustomobject]@{
        required = $false
        expectedData = @()
    }
}

function New-CommandPlanEntry {
    param(
        [Parameter(Mandatory = $true)][object] $StrategyStep,
        [Parameter(Mandatory = $true)][string] $Program,
        [string[]] $Arguments = @(),
        [string] $RenderedCommand = '',
        [string] $Title = '',
        [string] $Description = '',
        [bool] $Copyable = $false,
        [string] $Diagnostic = ''
    )

    return [pscustomobject]@{
        commandId = [string] $StrategyStep.stepId
        sequence = [int] $StrategyStep.sequence
        strategyStepId = [string] $StrategyStep.stepId
        operationType = [string] $StrategyStep.operationType
        actor = [string] $StrategyStep.actor
        executionLocation = [string] $StrategyStep.executionLocation
        executionMode = [string] $StrategyStep.commandExecutionMode
        program = $Program
        arguments = @($Arguments)
        workingDirectory = ''
        environment = [pscustomobject]@{}
        renderedCommand = $RenderedCommand
        display = [pscustomobject]@{
            title = $Title
            description = $Description
            copyable = $Copyable
        }
        feedback = New-CommandPlanFeedback -StrategyStep $StrategyStep
        safety = [pscustomobject]@{
            destructive = $false
            containsSecret = $false
            requiresApproval = [bool] $StrategyStep.approvalRequired
            executionPermitted = $false
        }
        diagnostic = $Diagnostic
    }
}

function New-IncompleteCommandEntry {
    param([Parameter(Mandatory = $true)][object] $StrategyStep, [Parameter(Mandatory = $true)][string] $Diagnostic)

    return New-CommandPlanEntry -StrategyStep $StrategyStep -Program 'local-operation' -Arguments @([string] $StrategyStep.operationType) -RenderedCommand '' -Title ([string] $StrategyStep.stepId) -Description 'Command generation is incomplete.' -Copyable $false -Diagnostic $Diagnostic
}

function Resolve-RemoteInputsDiagnostic {
    param(
        [Parameter(Mandatory = $true)][object] $ExecutionPlan,
        [Parameter(Mandatory = $true)][object] $Inputs,
        [bool] $RequiresLocalArtifact = $false
    )

    $sshTarget = Get-OptionalInputString -Inputs $Inputs -Name 'sshTarget'
    $remoteRoot = Get-OptionalInputString -Inputs $Inputs -Name 'remoteProjectPath'
    $localArtifactPath = Get-OptionalInputString -Inputs $Inputs -Name 'localArtifactPath'
    $artifactFileName = Get-OptionalInputString -Inputs $Inputs -Name 'artifactFileName'

    if ([string]::IsNullOrWhiteSpace($sshTarget)) {
        return 'SSH target is missing.'
    }
    if (Test-SecretLikeText -Text $sshTarget) {
        return 'SSH target contains secret-like content.'
    }
    if ([string]::IsNullOrWhiteSpace($remoteRoot)) {
        $remoteRoot = [string] $ExecutionPlan.environment.applicationRemoteDirectory
    }
    if (-not (Test-AbsolutePosixPath -Path $remoteRoot)) {
        return 'Absolute remote target path is missing.'
    }
    if ($RequiresLocalArtifact -and [string]::IsNullOrWhiteSpace($localArtifactPath)) {
        return 'Local artifact path is missing.'
    }
    if ($RequiresLocalArtifact -and [string]::IsNullOrWhiteSpace($artifactFileName)) {
        return 'Artifact file name is missing.'
    }
    foreach ($value in @($remoteRoot, $localArtifactPath, $artifactFileName)) {
        if (Test-SecretLikeText -Text ([string] $value)) {
            return 'Command input contains secret-like content.'
        }
    }

    return ''
}

function New-HumanCommandEntry {
    param(
        [Parameter(Mandatory = $true)][object] $ExecutionPlan,
        [Parameter(Mandatory = $true)][object] $DeploymentStrategy,
        [Parameter(Mandatory = $true)][object] $StrategyStep
    )

    $inputs = Get-CommandGenerationInputs -DeploymentStrategy $DeploymentStrategy
    $requiresLocalArtifact = ([string] $StrategyStep.stepId -eq 'remote.archive.upload')
    $diagnostic = Resolve-RemoteInputsDiagnostic -ExecutionPlan $ExecutionPlan -Inputs $inputs -RequiresLocalArtifact:$requiresLocalArtifact
    if (-not [string]::IsNullOrWhiteSpace($diagnostic)) {
        return New-IncompleteCommandEntry -StrategyStep $StrategyStep -Diagnostic $diagnostic
    }

    $sshTarget = Get-OptionalInputString -Inputs $inputs -Name 'sshTarget'
    $remoteRoot = Get-OptionalInputString -Inputs $inputs -Name 'remoteProjectPath'
    if ([string]::IsNullOrWhiteSpace($remoteRoot)) {
        $remoteRoot = [string] $ExecutionPlan.environment.applicationRemoteDirectory
    }
    $releasePath = Get-OptionalInputString -Inputs $inputs -Name 'remoteReleasePath'
    if ([string]::IsNullOrWhiteSpace($releasePath)) {
        $releasePath = $remoteRoot
    }
    if (-not (Test-AbsolutePosixPath -Path $releasePath)) {
        return New-IncompleteCommandEntry -StrategyStep $StrategyStep -Diagnostic 'Absolute remote release path is missing.'
    }
    $remoteArchivePath = Get-OptionalInputString -Inputs $inputs -Name 'remoteArchivePath'
    $localArtifactPath = Get-OptionalInputString -Inputs $inputs -Name 'localArtifactPath'
    $artifactFileName = Get-OptionalInputString -Inputs $inputs -Name 'artifactFileName'

    switch ([string] $StrategyStep.stepId) {
        'remote.release-directory.prepare' {
            $remoteArguments = @('mkdir', '-p', $releasePath)
            $arguments = @($sshTarget) + $remoteArguments
            return New-CommandPlanEntry -StrategyStep $StrategyStep -Program 'ssh' -Arguments $arguments -RenderedCommand (ConvertTo-RenderedCommand -Program 'ssh' -Arguments $arguments) -Title 'Remote Release-Verzeichnis vorbereiten' -Description 'Copyable SSH command for manual execution.' -Copyable $true
        }
        'remote.archive.upload' {
            if ([string]::IsNullOrWhiteSpace($remoteArchivePath)) {
                $remoteArchivePath = ($releasePath.TrimEnd('/') + '/' + $artifactFileName)
            }
            if (-not (Test-AbsolutePosixPath -Path $remoteArchivePath)) {
                return New-IncompleteCommandEntry -StrategyStep $StrategyStep -Diagnostic 'Absolute remote archive path is missing.'
            }
            $arguments = @($localArtifactPath, "$sshTarget`:$remoteArchivePath")
            return New-CommandPlanEntry -StrategyStep $StrategyStep -Program 'scp' -Arguments $arguments -RenderedCommand (ConvertTo-RenderedCommand -Program 'scp' -Arguments $arguments) -Title 'Deployment-Archiv uebertragen' -Description 'Copyable SCP command for manual execution.' -Copyable $true
        }
        'remote.archive.extract' {
            if ([string]::IsNullOrWhiteSpace($remoteArchivePath)) {
                $remoteArchivePath = ($releasePath.TrimEnd('/') + '/' + $artifactFileName)
            }
            if (-not (Test-AbsolutePosixPath -Path $remoteArchivePath)) {
                return New-IncompleteCommandEntry -StrategyStep $StrategyStep -Diagnostic 'Absolute remote archive path is missing.'
            }
            $operation = if ($DeploymentStrategy.selectedAdapterId -eq 'archive.zip') { 'extract-zip' } else { 'extract-tar' }
            $remoteArguments = @($operation, $remoteArchivePath, $releasePath)
            $arguments = @($sshTarget) + $remoteArguments
            return New-CommandPlanEntry -StrategyStep $StrategyStep -Program 'ssh' -Arguments $arguments -RenderedCommand (ConvertTo-RenderedCommand -Program 'ssh' -Arguments $arguments) -Title 'Remote Archiv entpacken' -Description 'Copyable SSH command intent for manual execution.' -Copyable $true
        }
        'remote.application.finalize' {
            $remoteArguments = @('finalize-application', $releasePath)
            $arguments = @($sshTarget) + $remoteArguments
            return New-CommandPlanEntry -StrategyStep $StrategyStep -Program 'ssh' -Arguments $arguments -RenderedCommand (ConvertTo-RenderedCommand -Program 'ssh' -Arguments $arguments) -Title 'Remote Anwendung finalisieren' -Description 'Copyable SSH command intent for manual execution.' -Copyable $true
        }
    }

    return New-IncompleteCommandEntry -StrategyStep $StrategyStep -Diagnostic "No V1 renderer exists for strategy step '$($StrategyStep.stepId)'."
}

function New-AutomationCommandEntry {
    param([Parameter(Mandatory = $true)][object] $StrategyStep, [Parameter(Mandatory = $true)][string] $SelectedAdapterId)

    $arguments = @([string] $StrategyStep.operationType)
    if ($StrategyStep.operationType -eq 'archive-create') {
        $arguments += $SelectedAdapterId
    }
    return New-CommandPlanEntry -StrategyStep $StrategyStep -Program 'local-operation' -Arguments $arguments -RenderedCommand '' -Title ([string] $StrategyStep.stepId) -Description 'Structured local operation for later executor support.' -Copyable $false
}

function Resolve-CommandPlan {
    param(
        [Parameter(Mandatory = $true)][object] $ExecutionPlan,
        [Parameter(Mandatory = $true)][object] $DeploymentStrategy
    )

    Assert-ResolvedExecutionPlanForCommandGeneration -ExecutionPlan $ExecutionPlan
    Assert-DeploymentStrategyForCommandGeneration -DeploymentStrategy $DeploymentStrategy

    $commands = New-Object System.Collections.Generic.List[object]
    foreach ($step in @($DeploymentStrategy.steps | Sort-Object sequence, stepId)) {
        if (-not [bool] $step.commandGenerationRequired) {
            continue
        }
        if ($step.actor -eq 'automation') {
            $commands.Add((New-AutomationCommandEntry -StrategyStep $step -SelectedAdapterId ([string] $DeploymentStrategy.selectedAdapterId)))
        } elseif ($step.actor -eq 'human-command') {
            $commands.Add((New-HumanCommandEntry -ExecutionPlan $ExecutionPlan -DeploymentStrategy $DeploymentStrategy -StrategyStep $step))
        }
    }

    $status = if (@($commands | Where-Object { [string]::IsNullOrWhiteSpace([string] $_.renderedCommand) -and $_.actor -eq 'human-command' }).Count -gt 0) {
        'incomplete'
    } else {
        'ready'
    }

    return [pscustomobject]@{
        schemaVersion = '0.1'
        commandPlanType = 'deployment-command-plan'
        status = $status
        sourceStrategyType = 'deployment'
        selectedAdapterId = [string] $DeploymentStrategy.selectedAdapterId
        executionPolicy = [pscustomobject]@{
            executionAllowed = $false
            automaticExecutionAllowed = $false
            remoteExecutionMode = 'copy-and-run'
        }
        commands = @($commands | Sort-Object sequence, commandId)
        diagnostic = if ($status -eq 'ready') { 'Command plan is ready for manual review and copy-and-run handling.' } else { 'Command plan is incomplete because required target or artifact information is missing.' }
    }
}

function Write-CommandPlanJson {
    param(
        [Parameter(Mandatory = $true)][object] $CommandPlan,
        [string] $OutputPath
    )

    $json = $CommandPlan | ConvertTo-Json -Depth 50
    if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
        $resolvedOutputPath = Resolve-CommandPlanPath -Path $OutputPath
        $outputDirectory = Split-Path -Path $resolvedOutputPath -Parent
        if (-not [string]::IsNullOrWhiteSpace($outputDirectory)) {
            New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
        }
        $json | Set-Content -LiteralPath $resolvedOutputPath -Encoding utf8
    }

    return $json
}

function Invoke-CommandPlanBuilder {
    param(
        [Parameter(Mandatory = $true)][string] $ExecutionPlanPath,
        [Parameter(Mandatory = $true)][string] $DeploymentStrategyPath,
        [string] $OutputPath,
        [string] $Format = 'Json'
    )

    if ($Format -ne 'Json') {
        throw "generate-commands only supports -Format Json."
    }

    $executionPlan = Read-CommandPlanJsonFile -Path $ExecutionPlanPath -Description 'Resolved execution plan'
    $deploymentStrategy = Read-CommandPlanJsonFile -Path $DeploymentStrategyPath -Description 'Deployment strategy'
    $commandPlan = Resolve-CommandPlan -ExecutionPlan $executionPlan -DeploymentStrategy $deploymentStrategy
    return Write-CommandPlanJson -CommandPlan $commandPlan -OutputPath $OutputPath
}

if ($MyInvocation.InvocationName -ne '.') {
    if ([string]::IsNullOrWhiteSpace($ExecutionPlanPath)) {
        throw "Missing required parameter for 'generate-commands': -ExecutionPlanPath"
    }
    if ([string]::IsNullOrWhiteSpace($DeploymentStrategyPath)) {
        throw "Missing required parameter for 'generate-commands': -DeploymentStrategyPath"
    }
    Invoke-CommandPlanBuilder -ExecutionPlanPath $ExecutionPlanPath -DeploymentStrategyPath $DeploymentStrategyPath -OutputPath $OutputPath -Format $Format
}
