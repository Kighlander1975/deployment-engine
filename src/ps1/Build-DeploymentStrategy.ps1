[CmdletBinding()]
param(
    [string] $ExecutionPlanPath,
    [string] $AdapterSelectionPath,
    [string] $OutputPath,
    [string] $Format = 'Json'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path -Path $PSScriptRoot -ChildPath 'DeploymentAdapters.ps1')

function Resolve-DeploymentStrategyPath {
    param([Parameter(Mandatory = $true)][string] $Path)

    $executionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function Read-DeploymentStrategyJsonFile {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Description
    )

    $resolved = Resolve-DeploymentStrategyPath -Path $Path
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
        throw "$Description file does not exist: $resolved"
    }

    try {
        return (Get-Content -LiteralPath $resolved -Raw | ConvertFrom-Json)
    } catch {
        throw "Invalid $Description JSON in '$resolved': $($_.Exception.Message)"
    }
}

function Test-DeploymentStrategyProperty {
    param([object] $Object, [Parameter(Mandatory = $true)][string] $Name)

    return ($null -ne $Object -and $Object.PSObject.Properties.Name -contains $Name)
}

function Test-DeploymentStrategyObjectLike {
    param([object] $Value)

    if ($null -eq $Value -or $Value -is [string] -or $Value -is [System.ValueType]) {
        return $false
    }
    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [System.Collections.IDictionary]) -and -not ($Value -is [pscustomobject])) {
        return $false
    }

    return ($null -ne $Value.PSObject -and $null -ne $Value.PSObject.Properties)
}

function Assert-DeploymentStrategyString {
    param(
        [Parameter(Mandatory = $true)][object] $Object,
        [Parameter(Mandatory = $true)][string] $Name,
        [Parameter(Mandatory = $true)][string] $Context
    )

    if (-not (Test-DeploymentStrategyProperty -Object $Object -Name $Name)) {
        throw "$Context validation failed: missing required field '$Name'."
    }
    if (-not ($Object.$Name -is [string])) {
        throw "$Context validation failed: field '$Name' must be a string."
    }
    if ([string]::IsNullOrWhiteSpace([string] $Object.$Name)) {
        throw "$Context validation failed: field '$Name' must not be empty."
    }
}

function Assert-DeploymentStrategyBool {
    param(
        [Parameter(Mandatory = $true)][object] $Object,
        [Parameter(Mandatory = $true)][string] $Name,
        [Parameter(Mandatory = $true)][string] $Context
    )

    if (-not (Test-DeploymentStrategyProperty -Object $Object -Name $Name)) {
        throw "$Context validation failed: missing required field '$Name'."
    }
    if (-not ($Object.$Name -is [bool])) {
        throw "$Context validation failed: field '$Name' must be boolean."
    }
}

function Assert-DeploymentStrategyInteger {
    param(
        [Parameter(Mandatory = $true)][object] $Value,
        [Parameter(Mandatory = $true)][string] $Context,
        [string] $Field = 'priority'
    )

    if (-not ($Value -is [byte] -or $Value -is [int16] -or $Value -is [int] -or $Value -is [long])) {
        throw "$Context validation failed: field '$Field' must be an integer."
    }
}

function Assert-DeploymentStrategyStatus {
    param(
        [Parameter(Mandatory = $true)][string] $Status,
        [Parameter(Mandatory = $true)][string[]] $AllowedStatuses,
        [Parameter(Mandatory = $true)][string] $Context
    )

    if ($Status -notin $AllowedStatuses) {
        throw "$Context validation failed: unsupported status '$Status'."
    }
}

function Assert-AdapterSelectionForStrategy {
    param(
        [Parameter(Mandatory = $true)][object] $AdapterSelection,
        [object] $AdapterCatalog = (Get-DeploymentAdapterCatalog)
    )

    if ($null -eq $AdapterSelection) {
        throw "Deployment strategy validation failed: adapter selection is missing."
    }
    Assert-DeploymentStrategyString -Object $AdapterSelection -Name 'schemaVersion' -Context 'Adapter selection'
    if ($AdapterSelection.schemaVersion -ne '0.1') {
        throw "Adapter selection validation failed: unsupported schemaVersion '$($AdapterSelection.schemaVersion)'."
    }
    Assert-DeploymentStrategyString -Object $AdapterSelection -Name 'selectionType' -Context 'Adapter selection'
    if ($AdapterSelection.selectionType -ne 'deployment-adapter') {
        throw "Adapter selection validation failed: selectionType must be 'deployment-adapter'."
    }
    Assert-DeploymentStrategyString -Object $AdapterSelection -Name 'status' -Context 'Adapter selection'
    if ($AdapterSelection.status -ne 'selected') {
        throw "Adapter selection validation failed: status must be 'selected' before building a deployment strategy."
    }
    Assert-DeploymentStrategyString -Object $AdapterSelection -Name 'selectedAdapterId' -Context 'Adapter selection'
    if ([string]::IsNullOrWhiteSpace([string] $AdapterSelection.selectedAdapterId)) {
        throw "Adapter selection validation failed: selectedAdapterId must not be empty."
    }

    $selectedAdapterId = [string] $AdapterSelection.selectedAdapterId
    if (-not $AdapterCatalog.Contains($selectedAdapterId)) {
        throw "Adapter selection validation failed: unknown selected adapter id '$selectedAdapterId'."
    }
    if (-not (Test-DeploymentStrategyProperty -Object $AdapterSelection -Name 'candidates') -or $null -eq $AdapterSelection.candidates) {
        throw "Adapter selection validation failed: candidates must not be null."
    }

    $knownIds = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    foreach ($entry in @($AdapterCatalog.GetEnumerator())) {
        [void] $knownIds.Add([string] $entry.Key)
    }

    $seenIds = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    $selectedCandidates = New-Object System.Collections.Generic.List[object]
    foreach ($candidate in @($AdapterSelection.candidates)) {
        if (-not (Test-DeploymentStrategyObjectLike -Value $candidate)) {
            throw "Adapter selection validation failed: each candidate must be an object."
        }
        Assert-DeploymentStrategyString -Object $candidate -Name 'adapterId' -Context 'Adapter selection candidate'
        $candidateId = [string] $candidate.adapterId
        if (-not $knownIds.Contains($candidateId)) {
            throw "Adapter selection validation failed: unknown candidate adapter id '$candidateId'."
        }
        if (-not $seenIds.Add($candidateId)) {
            throw "Adapter selection validation failed: duplicate candidate adapter id '$candidateId'."
        }
        if (-not (Test-DeploymentStrategyProperty -Object $candidate -Name 'priority')) {
            throw "Adapter selection candidate '$candidateId' validation failed: missing required field 'priority'."
        }
        Assert-DeploymentStrategyInteger -Value $candidate.priority -Context "Adapter selection candidate '$candidateId'"
        if ([int] $candidate.priority -ne [int] $AdapterCatalog[$candidateId].priority) {
            throw "Adapter selection candidate '$candidateId' validation failed: priority '$($candidate.priority)' does not match catalog priority '$($AdapterCatalog[$candidateId].priority)'."
        }
        Assert-DeploymentStrategyString -Object $candidate -Name 'eligibilityStatus' -Context "Adapter selection candidate '$candidateId'"
        Assert-DeploymentStrategyStatus -Status ([string] $candidate.eligibilityStatus) -AllowedStatuses @('eligible', 'ineligible', 'unknown') -Context "Adapter selection candidate '$candidateId'"
        Assert-DeploymentStrategyBool -Object $candidate -Name 'selected' -Context "Adapter selection candidate '$candidateId'"
        if ($candidate.selected) {
            $selectedCandidates.Add($candidate)
        }
    }

    foreach ($adapterId in @($knownIds)) {
        if (-not $seenIds.Contains($adapterId)) {
            throw "Adapter selection validation failed: missing known candidate adapter id '$adapterId'."
        }
    }
    if ($selectedCandidates.Count -ne 1) {
        throw "Adapter selection validation failed: exactly one candidate must be selected."
    }
    $selectedCandidate = $selectedCandidates[0]
    if ([string] $selectedCandidate.adapterId -ne $selectedAdapterId) {
        throw "Adapter selection validation failed: selected candidate does not match selectedAdapterId."
    }
    if ([string] $selectedCandidate.eligibilityStatus -ne 'eligible') {
        throw "Adapter selection validation failed: selected candidate must be eligible."
    }
}

function Get-DeploymentStrategyPlanStatuses {
    return @('ready', 'blocked', 'waiting-for-review', 'waiting-for-human', 'skipped')
}

function Assert-ResolvedExecutionPlanForStrategy {
    param([Parameter(Mandatory = $true)][object] $ExecutionPlan)

    if ($null -eq $ExecutionPlan) {
        throw "Deployment strategy validation failed: resolved execution plan is missing."
    }
    Assert-DeploymentStrategyString -Object $ExecutionPlan -Name 'schemaVersion' -Context 'Resolved execution plan'
    if ($ExecutionPlan.schemaVersion -ne '0.1') {
        throw "Resolved execution plan validation failed: unsupported schemaVersion '$($ExecutionPlan.schemaVersion)'."
    }
    if (-not (Test-DeploymentStrategyProperty -Object $ExecutionPlan -Name 'resolved') -or $ExecutionPlan.resolved -ne $true) {
        throw "Resolved execution plan validation failed: expected resolved = true."
    }
    foreach ($field in @('project', 'environment', 'decisions')) {
        if (-not (Test-DeploymentStrategyProperty -Object $ExecutionPlan -Name $field) -or -not (Test-DeploymentStrategyObjectLike -Value $ExecutionPlan.$field)) {
            throw "Resolved execution plan validation failed: missing required object '$field'."
        }
    }
    foreach ($field in @('id', 'name', 'type')) {
        Assert-DeploymentStrategyString -Object $ExecutionPlan.project -Name $field -Context 'Resolved execution plan project'
    }
    foreach ($field in @('name', 'serverRoot', 'applicationRemoteDirectory', 'markerFile')) {
        Assert-DeploymentStrategyString -Object $ExecutionPlan.environment -Name $field -Context 'Resolved execution plan environment'
    }
    if (-not (Test-DeploymentStrategyProperty -Object $ExecutionPlan.environment -Name 'sharedStorage') -or -not (Test-DeploymentStrategyObjectLike -Value $ExecutionPlan.environment.sharedStorage)) {
        throw "Resolved execution plan validation failed: sharedStorage contract is required."
    }
    Assert-DeploymentStrategyBool -Object $ExecutionPlan.environment.sharedStorage -Name 'configurationPresent' -Context 'Resolved execution plan sharedStorage'
    Assert-DeploymentStrategyBool -Object $ExecutionPlan.environment.sharedStorage -Name 'rootResolved' -Context 'Resolved execution plan sharedStorage'
    if ($ExecutionPlan.environment.sharedStorage.configurationPresent) {
        Assert-DeploymentStrategyString -Object $ExecutionPlan.environment.sharedStorage -Name 'root' -Context 'Resolved execution plan sharedStorage'
        Assert-DeploymentStrategyString -Object $ExecutionPlan.environment.sharedStorage -Name 'sharedRootAbsolutePath' -Context 'Resolved execution plan sharedStorage'
    }
    if (-not (Test-DeploymentStrategyProperty -Object $ExecutionPlan -Name 'steps') -or $null -eq $ExecutionPlan.steps -or @($ExecutionPlan.steps).Count -eq 0) {
        throw "Resolved execution plan validation failed: missing required steps."
    }

    $stepIds = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    foreach ($step in @($ExecutionPlan.steps)) {
        if (-not (Test-DeploymentStrategyObjectLike -Value $step)) {
            throw "Resolved execution plan validation failed: each step must be an object."
        }
        Assert-DeploymentStrategyString -Object $step -Name 'id' -Context 'Resolved execution plan step'
        $stepId = [string] $step.id
        if (-not $stepIds.Add($stepId)) {
            throw "Resolved execution plan validation failed: duplicate step id '$stepId'."
        }
        Assert-DeploymentStrategyString -Object $step -Name 'executionMode' -Context "Resolved execution plan step '$stepId'"
        Assert-DeploymentStrategyStatus -Status ([string] $step.executionMode) -AllowedStatuses @('agent', 'human', 'review') -Context "Resolved execution plan step '$stepId'"
        Assert-DeploymentStrategyString -Object $step -Name 'status' -Context "Resolved execution plan step '$stepId'"
        Assert-DeploymentStrategyStatus -Status ([string] $step.status) -AllowedStatuses (Get-DeploymentStrategyPlanStatuses) -Context "Resolved execution plan step '$stepId'"
        Assert-DeploymentStrategyBool -Object $step -Name 'required' -Context "Resolved execution plan step '$stepId'"
        Assert-DeploymentStrategyBool -Object $step -Name 'approvalRequired' -Context "Resolved execution plan step '$stepId'"
        if (-not (Test-DeploymentStrategyProperty -Object $step -Name 'dependsOn') -or $null -eq $step.dependsOn) {
            throw "Resolved execution plan step '$stepId' validation failed: missing required field 'dependsOn'."
        }
        if ((Test-DeploymentStrategyProperty -Object $step -Name 'capabilityId') -and -not [string]::IsNullOrWhiteSpace([string] $step.capabilityId)) {
            if (-not (Test-DeploymentStrategyProperty -Object $step -Name 'instructions') -or -not (Test-DeploymentStrategyObjectLike -Value $step.instructions)) {
                throw "Resolved execution plan step '$stepId' validation failed: capability step requires instructions."
            }
            foreach ($field in @('capabilityId', 'displayCommand')) {
                Assert-DeploymentStrategyString -Object $step.instructions -Name $field -Context "Resolved execution plan step '$stepId' instructions"
            }
            if ([string] $step.instructions.capabilityId -ne [string] $step.capabilityId) {
                throw "Resolved execution plan step '$stepId' validation failed: capabilityId mismatch."
            }
        }
    }

    foreach ($step in @($ExecutionPlan.steps)) {
        foreach ($dependency in @($step.dependsOn | Sort-Object -Unique)) {
            $dependencyId = [string] $dependency
            if ([string]::IsNullOrWhiteSpace($dependencyId)) {
                continue
            }
            if ($dependencyId -eq [string] $step.id) {
                throw "Resolved execution plan validation failed: step '$($step.id)' depends on itself."
            }
            if (-not $stepIds.Contains($dependencyId)) {
                throw "Resolved execution plan validation failed: step '$($step.id)' depends on unknown step '$dependencyId'."
            }
        }
    }

    Assert-DeploymentStrategyAcyclicDependencies -Steps @($ExecutionPlan.steps)
}

function Assert-DeploymentStrategyAcyclicDependencies {
    param([Parameter(Mandatory = $true)][object[]] $Steps)

    $visiting = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    $visited = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    $byId = @{}
    foreach ($step in @($Steps)) {
        $byId[[string] $step.id] = $step
    }

    function Visit-Step {
        param([Parameter(Mandatory = $true)][string] $StepId)

        if ($visited.Contains($StepId)) {
            return
        }
        if ($visiting.Contains($StepId)) {
            throw "Resolved execution plan validation failed: cyclic dependency detected at step '$StepId'."
        }
        [void] $visiting.Add($StepId)
        foreach ($dependency in @($byId[$StepId].dependsOn)) {
            $dependencyId = [string] $dependency
            if (-not [string]::IsNullOrWhiteSpace($dependencyId)) {
                Visit-Step -StepId $dependencyId
            }
        }
        [void] $visiting.Remove($StepId)
        [void] $visited.Add($StepId)
    }

    foreach ($step in @($Steps)) {
        Visit-Step -StepId ([string] $step.id)
    }
}

function New-DeploymentStrategyFeedback {
    return [pscustomobject]@{
        required = $true
        type = 'command-result'
        expectedData = @('exitStatus', 'stdout', 'stderr')
    }
}

function New-DeploymentStrategyStep {
    param(
        [Parameter(Mandatory = $true)][string] $StepId,
        [Parameter(Mandatory = $true)][int] $Sequence,
        [Parameter(Mandatory = $true)][string] $OperationType,
        [Parameter(Mandatory = $true)][ValidateSet('automation', 'human-decision', 'human-command', 'review')][string] $Actor,
        [Parameter(Mandatory = $true)][ValidateSet('local', 'remote', 'artifact-transport', 'decision', 'review')][string] $ExecutionLocation,
        [string[]] $DependsOn = @(),
        [bool] $CommandGenerationRequired = $false,
        [Parameter(Mandatory = $true)][ValidateSet('none', 'automatic', 'copy-and-run')][string] $CommandExecutionMode,
        [bool] $ApprovalRequired = $false,
        [string[]] $InputReferences = @(),
        [string[]] $OutputReferences = @(),
        [string] $Diagnostic = '',
        [object] $Feedback
    )

    $step = [pscustomobject]@{
        stepId = $StepId
        sequence = $Sequence
        operationType = $OperationType
        actor = $Actor
        executionLocation = $ExecutionLocation
        dependsOn = @($DependsOn | Sort-Object -Unique)
        commandGenerationRequired = $CommandGenerationRequired
        commandExecutionMode = $CommandExecutionMode
        approvalRequired = $ApprovalRequired
        inputReferences = @($InputReferences)
        outputReferences = @($OutputReferences)
        diagnostic = $Diagnostic
    }
    if ($null -ne $Feedback) {
        Add-Member -InputObject $step -MemberType NoteProperty -Name 'feedback' -Value $Feedback
    }

    return $step
}

function New-DeploymentStrategyApprovalGate {
    param(
        [Parameter(Mandatory = $true)][int] $Sequence,
        [string[]] $DependsOn = @()
    )

    return [pscustomobject]@{
        gateId = 'deployment.approval'
        stepId = 'deployment.approval'
        sequence = $Sequence
        dependsOn = @($DependsOn | Sort-Object -Unique)
        gateType = 'approval'
        title = 'Deployment freigeben'
        reason = 'Das Deployment veraendert den Stand des Zielsystems.'
        riskLevel = 'high'
        blocksContinuation = $true
        requiredContext = @('project', 'sourceCommit', 'targetEnvironment', 'selectedAdapter', 'plannedOperations', 'risks')
        allowedResponses = @('approved', 'rejected')
    }
}

function New-ComposerStrategyContract {
    return [pscustomobject]@{
        composerStrategyId = 'composer-strategy-laravel-staging-install-from-lock'
        composerStrategyVersion = '0.1'
        composerExecutableResolution = 'system-composer'
        composerWorkingDirectory = 'remote.releaseDirectory'
        composerManifestPath = 'composer.json'
        composerLockPath = 'composer.lock'
        requiredPhpVersion = 'from-composer-manifest-and-lock'
        requiredPhpExtensions = 'from-composer-manifest-and-lock'
        installMode = 'install-from-lock'
        productionMode = $true
        devDependenciesAllowed = $false
        scriptsAllowed = 'explicit-contract-required'
        pluginsAllowed = 'according-to-composer-lock-and-policy'
        networkAccessRequired = $true
        interactionMode = 'non-interactive'
        preferredInstallMode = 'dist'
        optimizationMode = 'optimized-autoloader'
        platformRequirementMode = 'enforce'
        installContract = [pscustomobject]@{
            composerCommand = 'composer install'
            workingDirectory = 'remote.releaseDirectory'
            networkAccessPolicy = 'allowed-for-composer-dist-downloads-only'
            allowedFlags = @('--no-dev', '--prefer-dist', '--optimize-autoloader', '--no-interaction')
            forbiddenFlags = @('--ignore-platform-reqs', '--ignore-platform-req', '--no-scripts', '--dev', '--working-dir', '--global')
            scriptExecutionPolicy = [pscustomobject]@{
                mode = 'reviewed-install-lifecycle-only'
                allowedScriptNames = @('post-autoload-dump')
                allowedDefinedCommands = @('Illuminate\Foundation\ComposerScripts::postAutoloadDump', '@php artisan package:discover --ansi')
                forbiddenScriptNames = @('setup', 'dev', 'test', 'post-update-cmd', 'post-root-package-install', 'post-create-project-cmd', 'pre-package-uninstall')
                requiresReview = $true
            }
            pluginExecutionPolicy = [pscustomobject]@{
                mode = 'lockfile-present-reviewed-plugins-only'
                configuredAllowPlugins = @('pestphp/pest-plugin', 'php-http/discovery')
                lockfilePluginPackagesRequiredForExecution = $true
                requiresReview = $true
            }
            expectedVendorState = [pscustomobject]@{
                vendorDirectoryPresent = $true
                devPackagesInstalled = $false
                generatedFromLockFile = $true
            }
            expectedAutoloadState = [pscustomobject]@{
                autoloadFile = 'vendor/autoload.php'
                optimizedAutoloader = $true
                packageDiscoveryFiles = @('bootstrap/cache/packages.php', 'bootstrap/cache/services.php')
            }
            writeBoundary = [pscustomobject]@{
                root = 'remote.releaseDirectory'
                allowedPaths = @('vendor', 'vendor/**', 'bootstrap/cache', 'bootstrap/cache/packages.php', 'bootstrap/cache/services.php')
                forbiddenPaths = @('.env', '.env.*', 'storage/**', 'public/**', '.deployment/**', '../**')
                externalResourcesForbidden = @('shared-storage', 'live-release', 'deployment-metadata', 'file-permissions')
            }
            failureHandling = 'stop-no-retry-preserve-release-directory-for-diagnostics'
            rollbackBehaviour = 'no-live-state-changed-no-rollback-triggered'
            postValidation = [pscustomobject]@{
                requiredChecks = @('VendorPresent', 'AutoloadPresent', 'ComposerExitCode', 'FilesChangedOnlyInsideRelease', 'UnexpectedFileChanges', 'UnexpectedDirectories', 'ScriptsExecuted', 'PluginsExecuted')
                vendorPath = 'vendor'
                autoloadPath = 'vendor/autoload.php'
            }
        }
        timeoutPolicy = [pscustomobject]@{
            preflightSeconds = 120
            installSeconds = 600
        }
        environmentPolicy = [pscustomobject]@{
            allowComposerHome = $false
            allowComposerCache = $true
            requireNoDev = $true
            requireNoInteraction = $true
        }
    }
}

function Resolve-DeploymentStrategy {
    param(
        [Parameter(Mandatory = $true)][object] $ExecutionPlan,
        [Parameter(Mandatory = $true)][object] $AdapterSelection,
        [object] $AdapterCatalog = (Get-DeploymentAdapterCatalog)
    )

    Assert-ResolvedExecutionPlanForStrategy -ExecutionPlan $ExecutionPlan
    Assert-AdapterSelectionForStrategy -AdapterSelection $AdapterSelection -AdapterCatalog $AdapterCatalog

    $selectedAdapterId = [string] $AdapterSelection.selectedAdapterId
    $steps = @(
        New-DeploymentStrategyStep -StepId 'source.validate' -Sequence 100 -OperationType 'source-validate' -Actor 'automation' -ExecutionLocation 'local' -CommandGenerationRequired $true -CommandExecutionMode 'automatic' -InputReferences @('resolvedExecutionPlan.project', 'resolvedExecutionPlan.targetCommit') -Diagnostic 'Requires later executable source validation before deployment.'
        New-DeploymentStrategyStep -StepId 'artifact.prepare' -Sequence 200 -OperationType 'artifact-prepare' -Actor 'automation' -ExecutionLocation 'local' -DependsOn @('source.validate') -CommandGenerationRequired $false -CommandExecutionMode 'automatic' -InputReferences @('resolvedExecutionPlan.steps') -OutputReferences @('runtimeArtifact.stagingArea') -Diagnostic 'Prepare the external runtime artifact workspace without creating commands in this phase.'
        New-DeploymentStrategyStep -StepId 'archive.create' -Sequence 300 -OperationType 'archive-create' -Actor 'automation' -ExecutionLocation 'local' -DependsOn @('artifact.prepare') -CommandGenerationRequired $true -CommandExecutionMode 'automatic' -InputReferences @('runtimeArtifact.stagingArea', 'adapterSelection.selectedAdapterId') -OutputReferences @('runtimeArtifact.archive') -Diagnostic "Create a deployment archive using the selected adapter format '$selectedAdapterId' in a later command generation phase."
        New-DeploymentStrategyStep -StepId 'deployment.approval' -Sequence 400 -OperationType 'deployment-approval' -Actor 'human-decision' -ExecutionLocation 'decision' -DependsOn @('archive.create') -CommandGenerationRequired $false -CommandExecutionMode 'none' -ApprovalRequired $true -InputReferences @('resolvedExecutionPlan.project', 'resolvedExecutionPlan.environment', 'adapterSelection.selectedAdapterId') -Diagnostic 'Central deployment approval is required before changing the target system.'
        New-DeploymentStrategyStep -StepId 'remote.release-directory.prepare' -Sequence 500 -OperationType 'release-directory-prepare' -Actor 'human-command' -ExecutionLocation 'remote' -DependsOn @('deployment.approval') -CommandGenerationRequired $true -CommandExecutionMode 'copy-and-run' -InputReferences @('resolvedExecutionPlan.environment') -Diagnostic 'Later command generation must provide a copyable remote preparation command.' -Feedback (New-DeploymentStrategyFeedback)
        New-DeploymentStrategyStep -StepId 'artifact.upload' -Sequence 600 -OperationType 'artifact-upload' -Actor 'human-command' -ExecutionLocation 'artifact-transport' -DependsOn @('remote.release-directory.prepare') -CommandGenerationRequired $true -CommandExecutionMode 'copy-and-run' -InputReferences @('runtimeArtifact.archive', 'artifactTransport.networkShare') -OutputReferences @('artifactTransport.uploadedArchive') -Diagnostic 'Later command generation must provide a copyable network-share artifact transport command.' -Feedback (New-DeploymentStrategyFeedback)
        New-DeploymentStrategyStep -StepId 'remote.release.prepare' -Sequence 650 -OperationType 'release-prepare' -Actor 'human-command' -ExecutionLocation 'remote' -DependsOn @('artifact.upload') -CommandGenerationRequired $true -CommandExecutionMode 'copy-and-run' -InputReferences @('deploymentRunId', 'runtimeArtifact.artifactId', 'resolvedExecutionPlan.environment', 'resolvedExecutionPlan.executionPlanFingerprint') -OutputReferences @('remote.releaseDirectory') -Diagnostic 'Later command generation must provide a copyable remote release directory preparation command.' -Feedback (New-DeploymentStrategyFeedback)
        New-DeploymentStrategyStep -StepId 'remote.archive.extract' -Sequence 700 -OperationType 'archive-extract' -Actor 'human-command' -ExecutionLocation 'remote' -DependsOn @('remote.release.prepare') -CommandGenerationRequired $true -CommandExecutionMode 'copy-and-run' -InputReferences @('artifactTransport.uploadedArchive', 'remote.releaseDirectory', 'adapterSelection.selectedAdapterId') -OutputReferences @('remote.extractedReleaseDirectory') -Diagnostic "Later command generation must provide a copyable extraction command for adapter '$selectedAdapterId'." -Feedback (New-DeploymentStrategyFeedback)
        New-DeploymentStrategyStep -StepId 'remote.composer.preflight' -Sequence 750 -OperationType 'composer-preflight' -Actor 'human-command' -ExecutionLocation 'remote' -DependsOn @('remote.archive.extract') -CommandGenerationRequired $true -CommandExecutionMode 'copy-and-run' -InputReferences @('remote.releaseDirectory', 'composerStrategy') -OutputReferences @('remote.composerPreflight') -Diagnostic 'Later command generation must provide a copyable read-only Composer preflight command.' -Feedback (New-DeploymentStrategyFeedback)
        New-DeploymentStrategyStep -StepId 'remote.composer.install' -Sequence 775 -OperationType 'composer-install' -Actor 'human-command' -ExecutionLocation 'remote' -DependsOn @('remote.composer.preflight') -CommandGenerationRequired $true -CommandExecutionMode 'copy-and-run' -InputReferences @('remote.releaseDirectory', 'composerStrategy', 'remote.composerPreflight') -OutputReferences @('remote.vendorDirectory', 'remote.composerInstallEvidence') -Diagnostic 'Composer install requires an explicit follow-up command after successful preflight.' -Feedback (New-DeploymentStrategyFeedback)
        New-DeploymentStrategyStep -StepId 'remote.composer.install.validate' -Sequence 790 -OperationType 'composer-install-validate' -Actor 'human-command' -ExecutionLocation 'remote' -DependsOn @('remote.composer.install') -CommandGenerationRequired $true -CommandExecutionMode 'copy-and-run' -InputReferences @('remote.releaseDirectory', 'composerStrategy', 'remote.composerInstallEvidence') -OutputReferences @('remote.composerInstallValidation') -Diagnostic 'Read-only reconciliation validates the previous Composer install evidence without re-running Composer.' -Feedback (New-DeploymentStrategyFeedback)
        New-DeploymentStrategyStep -StepId 'remote.shared-storage.prepare' -Sequence 795 -OperationType 'shared-storage-prepare' -Actor 'human-command' -ExecutionLocation 'remote' -DependsOn @('remote.composer.install.validate') -CommandGenerationRequired $true -CommandExecutionMode 'copy-and-run' -InputReferences @('resolvedExecutionPlan.environment.sharedStorage', 'remote.releaseDirectory', 'remote.composerInstallValidation') -OutputReferences @('remote.sharedStoragePreparation') -Diagnostic 'Prepare configured shared storage targets and release links conservatively after explicit approval.' -Feedback (New-DeploymentStrategyFeedback)
        New-DeploymentStrategyStep -StepId 'remote.application.finalize' -Sequence 800 -OperationType 'application-finalize' -Actor 'human-command' -ExecutionLocation 'remote' -DependsOn @('remote.shared-storage.prepare') -CommandGenerationRequired $true -CommandExecutionMode 'copy-and-run' -InputReferences @('resolvedExecutionPlan.steps', 'remote.releaseDirectory', 'remote.sharedStoragePreparation') -Diagnostic 'Later command generation must derive required application finalization operations from the resolved execution plan.' -Feedback (New-DeploymentStrategyFeedback)
        New-DeploymentStrategyStep -StepId 'deployment.verify' -Sequence 900 -OperationType 'deployment-verify' -Actor 'review' -ExecutionLocation 'review' -DependsOn @('remote.application.finalize') -CommandGenerationRequired $false -CommandExecutionMode 'none' -InputReferences @('remote.commandResults') -Diagnostic 'Review required evidence from previous remote steps; success is not assumed automatically.'
    )
    $approvalStep = @($steps | Where-Object { $_.stepId -eq 'deployment.approval' } | Select-Object -First 1)[0]

    return [pscustomobject]@{
        schemaVersion = '0.1'
        strategyType = 'deployment'
        status = 'ready'
        selectedAdapterId = $selectedAdapterId
        strategy = [pscustomobject]@{
            executionModel = 'human-gated-automation'
            artifactTransport = 'network-share'
            remoteExecution = 'interactive-ssh'
            localAutomationPolicy = 'automatic-unless-decision-required'
        }
        artifactTransport = [pscustomobject]@{
            adapterId = 'network-share'
            purpose = 'Transfer deployment artifacts through the configured project network share.'
            containsRemoteCommands = $false
        }
        remoteExecution = [pscustomobject]@{
            mode = 'interactive-ssh'
            startsConnection = $false
            readsConnectionContext = $false
            derivesHostFromPrompt = $false
        }
        deploymentWorkspace = [pscustomobject]@{
            baseDirectory = '.deployment'
            uploadsDirectory = '.deployment/uploads'
            workDirectory = '.deployment/work'
            releasesDirectory = '.deployment/releases'
            metadataDirectory = '.deployment/metadata'
            rollback = [pscustomobject]@{
                maxCompleteStates = 2
                cleanupAfterSuccessfulFinalizationOnly = $true
                preserveExistingStatesOnFailure = $true
            }
        }
        composerStrategy = New-ComposerStrategyContract
        sharedStorage = ($ExecutionPlan.environment.sharedStorage | ConvertTo-Json -Depth 30 | ConvertFrom-Json)
        steps = @($steps | Sort-Object sequence, stepId)
        humanGates = @((New-DeploymentStrategyApprovalGate -Sequence ([int] $approvalStep.sequence) -DependsOn @($approvalStep.dependsOn)))
        diagnostic = 'Deployment strategy is ready for later command generation.'
    }
}

function Write-DeploymentStrategyJson {
    param(
        [Parameter(Mandatory = $true)][object] $Strategy,
        [string] $OutputPath
    )

    $json = $Strategy | ConvertTo-Json -Depth 40
    if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
        $resolvedOutputPath = Resolve-DeploymentStrategyPath -Path $OutputPath
        $outputDirectory = Split-Path -Path $resolvedOutputPath -Parent
        if (-not [string]::IsNullOrWhiteSpace($outputDirectory)) {
            New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
        }
        $json | Set-Content -LiteralPath $resolvedOutputPath -Encoding utf8
    }

    return $json
}

function Invoke-DeploymentStrategyBuilder {
    param(
        [Parameter(Mandatory = $true)][string] $ExecutionPlanPath,
        [Parameter(Mandatory = $true)][string] $AdapterSelectionPath,
        [string] $OutputPath,
        [string] $Format = 'Json'
    )

    if ($Format -ne 'Json') {
        throw "build-deployment-strategy only supports -Format Json."
    }

    $executionPlan = Read-DeploymentStrategyJsonFile -Path $ExecutionPlanPath -Description 'Resolved execution plan'
    $adapterSelection = Read-DeploymentStrategyJsonFile -Path $AdapterSelectionPath -Description 'Adapter selection'
    $strategy = Resolve-DeploymentStrategy -ExecutionPlan $executionPlan -AdapterSelection $adapterSelection
    return Write-DeploymentStrategyJson -Strategy $strategy -OutputPath $OutputPath
}

if ($MyInvocation.InvocationName -ne '.') {
    if ([string]::IsNullOrWhiteSpace($ExecutionPlanPath)) {
        throw "Missing required parameter for 'build-deployment-strategy': -ExecutionPlanPath"
    }
    if ([string]::IsNullOrWhiteSpace($AdapterSelectionPath)) {
        throw "Missing required parameter for 'build-deployment-strategy': -AdapterSelectionPath"
    }
    Invoke-DeploymentStrategyBuilder -ExecutionPlanPath $ExecutionPlanPath -AdapterSelectionPath $AdapterSelectionPath -OutputPath $OutputPath -Format $Format
}
