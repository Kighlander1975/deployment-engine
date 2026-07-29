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
            sharedStorage = [pscustomobject]@{
                configurationPresent = $true
                rootResolved = $true
                root = 'shared'
                sharedRootAbsolutePath = "$($RemotePath.TrimEnd('/'))/shared"
                directories = @([pscustomobject]@{
                    sharedPath = 'laravel_app/storage/app/private'
                    releaseLinkPath = 'laravel_app/storage/app/private'
                    pathKind = 'directory'
                    conflictPolicy = 'fail'
                    initializationPolicy = 'explicit'
                    sharedAbsolutePath = "$($RemotePath.TrimEnd('/'))/shared/laravel_app/storage/app/private"
                    releaseLinkAbsolutePath = "$($RemotePath.TrimEnd('/'))/laravel_app/storage/app/private"
                })
                files = @()
                diagnostics = @()
            }
        }
        baselineCommit = 'abc'
        targetCommit = 'def'
        decisions = [pscustomobject]@{ runtimeDeploymentRequired = $true }
        warnings = @()
        blockers = @()
        manualApprovalPoints = @()
        phases = @('preconditions')
        steps = @(New-TestPlanStep -Id 'preconditions.analysis-review')
        executionPlanFingerprint = 'execution-plan-fingerprint-a'
    }
}

function New-TestRuntimeArtifact {
    param(
        [string] $ExecutionPlanFingerprint = 'execution-plan-fingerprint-a',
        [string] $LocalPath = 'C:\Build Output\release (final) & safe\artifact''s "$demo" `tick`.zip',
        [string] $FileName = 'artifact final.zip',
        [string[]] $ComposerValidationBaselinePaths = @(
            'bootstrap/cache|directory|',
            'bootstrap/cache/.gitignore|file|baseline-gitignore-hash',
            'bootstrap/cache/packages.php|file|baseline-packages-hash',
            'bootstrap/cache/services.php|file|baseline-services-hash'
        )
    )

    $artifact = [pscustomobject]@{
        artifactId = 'runtime-artifact-test'
        artifactType = 'deployment-archive'
        archiveFormat = 'zip'
        localPath = $LocalPath
        fileName = $FileName
        fileSize = 12345
        hash = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
        executionPlanFingerprint = $ExecutionPlanFingerprint
        packagingPolicyId = 'packaging-policy-test'
        packagingPolicyFingerprint = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
        packagingValidation = [pscustomobject]@{ includedFileCount = 2; excludedFileCount = 1; includedBytes = 12345 }
        createdAt = '2026-07-28T11:38:00.0000000Z'
    }
    Add-Member -InputObject $artifact -MemberType NoteProperty -Name 'composerValidationBaselinePaths' -Value @($ComposerValidationBaselinePaths)
    return $artifact
}

function New-TestPackagingPolicy {
    param([string] $ExecutionPlanFingerprint = 'execution-plan-fingerprint-a')

    return [pscustomobject]@{
        policyId = 'packaging-policy-test'
        projectId = 'pilot'
        artifactType = 'deployment-archive'
        vendorStrategy = 'exclude-install-on-target-from-lockfiles'
        includedPaths = @('**')
        excludedPaths = @('storage/**', 'vendor/**', 'node_modules/**', 'tests/**', '.git/**', '.deployment/**', 'deployment-runs/**')
        executionPlanFingerprint = $ExecutionPlanFingerprint
        createdAt = '2026-07-28T12:00:00Z'
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

function New-TestComposerStrategy {
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
            expectedVendorState = [pscustomobject]@{ vendorDirectoryPresent = $true; devPackagesInstalled = $false; generatedFromLockFile = $true }
            expectedAutoloadState = [pscustomobject]@{ autoloadFile = 'vendor/autoload.php'; optimizedAutoloader = $true; packageDiscoveryFiles = @('bootstrap/cache/packages.php', 'bootstrap/cache/services.php') }
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
        strategy = [pscustomobject]@{ executionModel = 'human-gated-automation'; artifactTransport = 'network-share'; remoteExecution = 'interactive-ssh'; localAutomationPolicy = 'automatic-unless-decision-required' }
        artifactTransport = [pscustomobject]@{ adapterId = 'network-share'; purpose = 'Transfer artifacts through a network share.'; containsRemoteCommands = $false }
        remoteExecution = [pscustomobject]@{ mode = 'interactive-ssh'; startsConnection = $false; readsConnectionContext = $false; derivesHostFromPrompt = $false }
        deploymentWorkspace = [pscustomobject]@{
            baseDirectory = '.deployment'
            uploadsDirectory = '.deployment/uploads'
            workDirectory = '.deployment/work'
            releasesDirectory = '.deployment/releases'
            metadataDirectory = '.deployment/metadata'
            rollback = [pscustomobject]@{ maxCompleteStates = 2; cleanupAfterSuccessfulFinalizationOnly = $true; preserveExistingStatesOnFailure = $true }
        }
        composerStrategy = New-TestComposerStrategy
        sharedStorage = [pscustomobject]@{
            configurationPresent = $true
            rootResolved = $true
            root = 'shared'
            sharedRootAbsolutePath = '/www/htdocs/w017bd08/shk-momm.de/shared'
            directories = @([pscustomobject]@{
                sharedPath = 'laravel_app/storage/app/private'
                releaseLinkPath = 'laravel_app/storage/app/private'
                pathKind = 'directory'
                conflictPolicy = 'fail'
                initializationPolicy = 'explicit'
                sharedAbsolutePath = '/www/htdocs/w017bd08/shk-momm.de/shared/laravel_app/storage/app/private'
            })
            files = @()
            diagnostics = @()
        }
        steps = @(
            New-TestStrategyStep -StepId 'source.validate' -Sequence 100 -OperationType 'source-validate' -Actor 'automation' -Location 'local' -Mode 'automatic'
            New-TestStrategyStep -StepId 'artifact.prepare' -Sequence 200 -OperationType 'artifact-prepare' -Actor 'automation' -Location 'local' -Mode 'automatic' -Required $false -DependsOn @('source.validate')
            New-TestStrategyStep -StepId 'archive.create' -Sequence 300 -OperationType 'archive-create' -Actor 'automation' -Location 'local' -Mode 'automatic' -DependsOn @('artifact.prepare')
            New-TestStrategyStep -StepId 'deployment.approval' -Sequence 400 -OperationType 'deployment-approval' -Actor 'human-decision' -Location 'decision' -Mode 'none' -Required $false -DependsOn @('archive.create')
            New-TestStrategyStep -StepId 'remote.release-directory.prepare' -Sequence 500 -OperationType 'release-directory-prepare' -Actor 'human-command' -Location 'remote' -Mode 'copy-and-run' -DependsOn @('deployment.approval')
            New-TestStrategyStep -StepId 'artifact.upload' -Sequence 600 -OperationType 'artifact-upload' -Actor 'human-command' -Location 'artifact-transport' -Mode 'copy-and-run' -DependsOn @('remote.release-directory.prepare')
            New-TestStrategyStep -StepId 'remote.release.prepare' -Sequence 650 -OperationType 'release-prepare' -Actor 'human-command' -Location 'remote' -Mode 'copy-and-run' -DependsOn @('artifact.upload')
            New-TestStrategyStep -StepId 'remote.archive.extract' -Sequence 700 -OperationType 'archive-extract' -Actor 'human-command' -Location 'remote' -Mode 'copy-and-run' -DependsOn @('remote.release.prepare')
            New-TestStrategyStep -StepId 'remote.composer.preflight' -Sequence 750 -OperationType 'composer-preflight' -Actor 'human-command' -Location 'remote' -Mode 'copy-and-run' -DependsOn @('remote.archive.extract')
            New-TestStrategyStep -StepId 'remote.composer.install' -Sequence 775 -OperationType 'composer-install' -Actor 'human-command' -Location 'remote' -Mode 'copy-and-run' -DependsOn @('remote.composer.preflight')
            New-TestStrategyStep -StepId 'remote.composer.install.validate' -Sequence 790 -OperationType 'composer-install-validate' -Actor 'human-command' -Location 'remote' -Mode 'copy-and-run' -DependsOn @('remote.composer.install')
            New-TestStrategyStep -StepId 'remote.shared-storage.prepare' -Sequence 795 -OperationType 'shared-storage-prepare' -Actor 'human-command' -Location 'remote' -Mode 'copy-and-run' -DependsOn @('remote.composer.install.validate')
            New-TestStrategyStep -StepId 'remote.application.finalize' -Sequence 800 -OperationType 'application-finalize' -Actor 'human-command' -Location 'remote' -Mode 'copy-and-run' -DependsOn @('remote.shared-storage.prepare')
            New-TestStrategyStep -StepId 'deployment.verify' -Sequence 900 -OperationType 'deployment-verify' -Actor 'review' -Location 'review' -Mode 'none' -Required $false -DependsOn @('remote.application.finalize')
        )
        humanGates = @(
            [pscustomobject]@{ gateId = 'deployment.approval'; stepId = 'deployment.approval'; gateType = 'approval'; blocksContinuation = $true; allowedResponses = @('approved', 'rejected') }
        )
        diagnostic = ''
    }
    if ($WithCommandInputs) {
        Add-Member -InputObject $strategy -MemberType NoteProperty -Name 'commandInputs' -Value ([pscustomobject]@{
            deploymentRunId = 'run-2026-07-28'
            remoteReleasePath = '/www/htdocs/w017bd08/shk-momm.de/releases/current candidate'
            localArtifactPath = 'C:\Build Output\release (final) & safe\artifact''s "$demo" `tick`.zip'
            artifactFileName = 'artifact ä final.zip'
            networkShareRoot = 'D:\Projects\demo\netzlaufwerk'
        })
    }

    return $strategy
}

function Copy-TestObject {
    param([Parameter(Mandatory = $true)][object] $Value)
    return $Value | ConvertTo-Json -Depth 100 | ConvertFrom-Json
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
    foreach ($pattern in @('password=', 'token=', 'private key', 'BEGIN OPENSSH PRIVATE KEY')) {
        Assert-True (-not ($json -match $pattern)) "Command plan must not contain forbidden content '$pattern'."
    }
}

$zipPlan = Resolve-CommandPlan -ExecutionPlan (New-TestResolvedPlan) -DeploymentStrategy (New-TestDeploymentStrategy -SelectedAdapterId 'archive.zip') -RuntimeArtifact (New-TestRuntimeArtifact)
Assert-Equal $zipPlan.commandPlanType 'deployment-command-plan' 'Command plan type must be correct.'
Assert-Equal $zipPlan.status 'ready' 'Complete ZIP inputs must produce ready command plan.'
Assert-Equal $zipPlan.selectedAdapterId 'archive.zip' 'ZIP adapter must be preserved.'
Assert-Equal ((@($zipPlan.commands) | ForEach-Object { $_.commandId }) -join ',') 'source.validate,archive.create,remote.release-directory.prepare,artifact.upload,remote.release.prepare,remote.archive.extract,remote.composer.preflight,remote.composer.install,remote.composer.install.validate,remote.shared-storage.prepare,remote.application.finalize' 'Commands must be sorted deterministically.'
Assert-Equal (Get-Command -CommandPlan $zipPlan -CommandId 'archive.create').program 'local-operation' 'Local automation must use structured local-operation program.'
Assert-Equal (Get-Command -CommandPlan $zipPlan -CommandId 'archive.create').renderedCommand '' 'Local operation must not invent a shell command.'
Assert-Equal ((Get-Command -CommandPlan $zipPlan -CommandId 'archive.create').dependsOn -join ',') 'source.validate' 'Command plan dependencies must bypass non-emitted strategy-only preparation steps.'
Assert-Equal (Get-Command -CommandPlan $zipPlan -CommandId 'remote.release-directory.prepare').program 'interactive-ssh' 'Remote prepare must use interactive-ssh command blocks.'
Assert-Equal ((Get-Command -CommandPlan $zipPlan -CommandId 'remote.release-directory.prepare').dependsOn -join ',') 'deployment.approval' 'Command plan must carry strategy dependencies.'
$releaseDirectoryPrepare = Get-Command -CommandPlan $zipPlan -CommandId 'remote.release-directory.prepare'
Assert-True ($releaseDirectoryPrepare.renderedCommand -match 'DEPLOYMENT-REMOTE-RELEASE-DIRECTORY-PREPARE START') 'Remote prepare must emit a stable start marker.'
Assert-True ($releaseDirectoryPrepare.renderedCommand -match 'DEPLOYMENT-REMOTE-RELEASE-DIRECTORY-PREPARE END') 'Remote prepare must emit a stable end marker.'
Assert-True ($releaseDirectoryPrepare.renderedCommand -match 'DeploymentRunId=%s') 'Remote prepare must emit deployment run identity.'
Assert-True ($releaseDirectoryPrepare.renderedCommand -match 'ExecutionPlanFingerprint=%s') 'Remote prepare must emit execution plan fingerprint.'
Assert-Equal $releaseDirectoryPrepare.operation.deploymentRunId 'run-2026-07-28' 'Remote prepare operation must carry deployment run identity.'
Assert-Equal (Get-Command -CommandPlan $zipPlan -CommandId 'artifact.upload').program 'network-share' 'Archive upload must use network-share artifact transport.'
Assert-Equal (Get-Command -CommandPlan $zipPlan -CommandId 'artifact.upload').executionLocation 'artifact-transport' 'Artifact upload must use artifact-transport execution location.'
Assert-True ((Get-Command -CommandPlan $zipPlan -CommandId 'artifact.upload').renderedCommand -match '^Copy-Item ') 'Network-share upload must render a local Copy-Item command.'
Assert-True (-not ((Get-Command -CommandPlan $zipPlan -CommandId 'artifact.upload').renderedCommand -match '\bssh\b|\bscp\b')) 'Artifact transport command must not contain SSH or SCP.'
Assert-Equal (Get-Command -CommandPlan $zipPlan -CommandId 'remote.archive.extract').program 'interactive-ssh' 'Remote extract must use interactive-ssh command blocks.'
Assert-Equal (Get-Command -CommandPlan $zipPlan -CommandId 'remote.archive.extract').executionMode 'copy-and-run' 'Remote extract must be copy-and-run.'
Assert-True (Get-Command -CommandPlan $zipPlan -CommandId 'remote.archive.extract').display.copyable 'Human commands must be copyable.'
Assert-Equal ((Get-Command -CommandPlan $zipPlan -CommandId 'artifact.upload').feedback.expectedData -join ',') 'exitStatus,stdout,stderr' 'Human commands must request structured feedback.'
Assert-Equal ((Get-Command -CommandPlan $zipPlan -CommandId 'remote.release.prepare').dependsOn -join ',') 'artifact.upload' 'Release prepare must depend on artifact upload.'
Assert-Equal ((Get-Command -CommandPlan $zipPlan -CommandId 'remote.archive.extract').dependsOn -join ',') 'remote.release.prepare' 'Extract must depend on successful release prepare.'
Assert-Equal ((Get-Command -CommandPlan $zipPlan -CommandId 'remote.composer.preflight').dependsOn -join ',') 'remote.archive.extract' 'Composer preflight must depend on archive extraction.'
Assert-Equal ((Get-Command -CommandPlan $zipPlan -CommandId 'remote.composer.install').dependsOn -join ',') 'remote.composer.preflight' 'Composer install must depend on successful Composer preflight.'
Assert-Equal ((Get-Command -CommandPlan $zipPlan -CommandId 'remote.composer.install.validate').dependsOn -join ',') 'remote.composer.install' 'Composer install validation must depend on the previous install result.'
Assert-Equal (Get-Command -CommandPlan $zipPlan -CommandId 'remote.release.prepare').operation.deploymentRunId 'run-2026-07-28' 'Release prepare must carry deployment run id.'
Assert-Equal (Get-Command -CommandPlan $zipPlan -CommandId 'remote.release.prepare').operation.artifactId 'runtime-artifact-test' 'Release prepare must carry artifact id.'
Assert-Equal (Get-Command -CommandPlan $zipPlan -CommandId 'remote.release.prepare').operation.remoteReleaseDirectory '/www/htdocs/w017bd08/shk-momm.de/.deployment/releases/run-2026-07-28/runtime-artifact-test' 'Release prepare must derive nested release directory.'
Assert-True ((Get-Command -CommandPlan $zipPlan -CommandId 'remote.release.prepare').renderedCommand -match 'DEPLOYMENT-REMOTE-RELEASE-PREPARE START') 'Release prepare must emit a stable start marker.'
Assert-True ((Get-Command -CommandPlan $zipPlan -CommandId 'remote.release.prepare').renderedCommand -match 'DEPLOYMENT-REMOTE-RELEASE-PREPARE END') 'Release prepare must emit a stable end marker.'
Assert-True ((Get-Command -CommandPlan $zipPlan -CommandId 'remote.release.prepare').renderedCommand -match 'mkdir -p --') 'Release prepare may use mkdir -p for validated nested target.'
Assert-True ((Get-Command -CommandPlan $zipPlan -CommandId 'remote.release.prepare').renderedCommand -like '*-L "$RELEASE_ROOT"*') 'Release prepare must check release root symlink.'
Assert-True ((Get-Command -CommandPlan $zipPlan -CommandId 'remote.release.prepare').renderedCommand -like '*-L "$RELEASE_ROOT/$DEPLOYMENT_RUN_ID"*') 'Release prepare must check parent symlink.'
Assert-True ((Get-Command -CommandPlan $zipPlan -CommandId 'remote.archive.extract').renderedCommand -match 'unzip -q') 'ZIP adapter must affect extraction command.'
Assert-True ((Get-Command -CommandPlan $zipPlan -CommandId 'remote.archive.extract').renderedCommand -match '\\[ ! -d \"\\$REMOTE_RELEASE_DIRECTORY\" \\]') 'Extract must check prepared release directory before extracting.'
Assert-True (-not ((Get-Command -CommandPlan $zipPlan -CommandId 'remote.archive.extract').renderedCommand -match 'mkdir')) 'Extract must not create release directories.'
$archiveExtract = Get-Command -CommandPlan $zipPlan -CommandId 'remote.archive.extract'
Assert-Equal $archiveExtract.operation.deploymentRunId 'run-2026-07-28' 'Archive extract must carry deployment run id.'
Assert-Equal $archiveExtract.operation.artifactId 'runtime-artifact-test' 'Archive extract must carry artifact id.'
Assert-Equal $archiveExtract.operation.executionPlanFingerprint 'execution-plan-fingerprint-a' 'Archive extract must carry execution plan fingerprint.'
Assert-True ($archiveExtract.renderedCommand -match 'DEPLOYMENT-REMOTE-ARCHIVE-EXTRACT START') 'Archive extract must emit a stable start marker.'
Assert-True ($archiveExtract.renderedCommand -match 'DEPLOYMENT-REMOTE-ARCHIVE-EXTRACT END') 'Archive extract must emit a stable end marker.'
Assert-True ($archiveExtract.renderedCommand -match 'DeploymentRunId=%s') 'Archive extract must emit deployment run id.'
Assert-True ($archiveExtract.renderedCommand -match 'ArtifactId=%s') 'Archive extract must emit artifact id.'
Assert-True ($archiveExtract.renderedCommand -match 'ExecutionPlanFingerprint=%s') 'Archive extract must emit execution plan fingerprint.'
Assert-True ($archiveExtract.renderedCommand -match 'ArtisanPresent=%s') 'Archive extract must emit artisan validation status.'
$composerPreflight = Get-Command -CommandPlan $zipPlan -CommandId 'remote.composer.preflight'
Assert-Equal $composerPreflight.program 'interactive-ssh' 'Composer preflight must use interactive-ssh command blocks.'
Assert-Equal $composerPreflight.operation.composerStrategyId 'composer-strategy-laravel-staging-install-from-lock' 'Composer preflight must carry strategy identity.'
Assert-True ($composerPreflight.operation.composerStrategyFingerprint -match '^[a-f0-9]{64}$') 'Composer preflight must carry a deterministic strategy fingerprint.'
Assert-Equal $composerPreflight.operation.packagingPolicyId 'packaging-policy-test' 'Composer preflight must carry packaging policy identity.'
Assert-Equal $composerPreflight.operation.packagingPolicyFingerprint 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' 'Composer preflight must carry packaging policy fingerprint.'
Assert-True ($composerPreflight.renderedCommand -match 'command -v composer') 'Composer preflight must check composer availability.'
Assert-True ($composerPreflight.renderedCommand -match 'command -v php') 'Composer preflight must check PHP availability.'
Assert-True ($composerPreflight.renderedCommand -match 'DEPLOYMENT-REMOTE-COMPOSER-PREFLIGHT START') 'Composer preflight must emit a stable start marker.'
Assert-True ($composerPreflight.renderedCommand -match 'DEPLOYMENT-REMOTE-COMPOSER-PREFLIGHT END') 'Composer preflight must emit a stable end marker.'
Assert-True ($composerPreflight.renderedCommand -match 'StartedAt=%s') 'Composer preflight must emit StartedAt.'
Assert-True ($composerPreflight.renderedCommand -match 'CompletedAt=%s') 'Composer preflight must emit CompletedAt.'
Assert-True ($composerPreflight.renderedCommand -match 'DurationSeconds=%s') 'Composer preflight must emit DurationSeconds.'
Assert-True ($composerPreflight.renderedCommand -match 'composer validate --no-check-publish --no-interaction') 'Composer preflight must validate composer metadata.'
Assert-True ($composerPreflight.renderedCommand -match 'composer check-platform-reqs --lock --no-interaction') 'Composer preflight must check platform requirements from lock file.'
Assert-True ($composerPreflight.renderedCommand -match 'vendor-already-present') 'Composer preflight must detect existing vendor directory.'
Assert-True ($composerPreflight.renderedCommand -match 'ComposerScriptsRequireReview') 'Composer preflight must surface script review requirement.'
Assert-True ($composerPreflight.renderedCommand -match "COMPOSER_SCRIPTS_REQUIRE_REVIEW='false'") 'Composer preflight must not leave an open script review blocker after contract review.'
Assert-True ($composerPreflight.renderedCommand -match 'ComposerScriptReviewCompleted') 'Composer preflight must surface completed script review.'
Assert-True ($composerPreflight.renderedCommand -match 'ComposerPluginsPresent') 'Composer preflight must surface plugin presence.'
Assert-True ($composerPreflight.renderedCommand -match 'ComposerPluginsRequireReview') 'Composer preflight must surface plugin review requirement.'
Assert-True ($composerPreflight.renderedCommand -match "COMPOSER_PLUGINS_REQUIRE_REVIEW='false'") 'Composer preflight must not leave an open plugin review blocker after contract review.'
Assert-True ($composerPreflight.renderedCommand -match 'ComposerPluginReviewCompleted') 'Composer preflight must surface completed plugin review.'
Assert-True ($composerPreflight.renderedCommand -match 'ComposerInstallContractSatisfied') 'Composer preflight must surface install contract satisfaction without executing install.'
Assert-True (-not ($composerPreflight.renderedCommand -match 'composer install|composer update|--ignore-platform-reqs')) 'Composer preflight must not install, update or ignore platform requirements.'
$composerInstall = Get-Command -CommandPlan $zipPlan -CommandId 'remote.composer.install'
Assert-True ($composerInstall.renderedCommand -match '"\$COMPOSER_EXECUTABLE_PATH" install --no-dev --prefer-dist --optimize-autoloader --no-interaction') 'Composer install command must use the approved exact flags through the resolved Composer path.'
Assert-True (-not ($composerInstall.renderedCommand -match 'composer update|--ignore-platform-reqs')) 'Composer install command must not update or ignore platform requirements.'
Assert-True ($composerInstall.renderedCommand -match '"\$PHP_EXECUTABLE_PATH" -r ''echo PHP_VERSION;'' 2>/dev/null') 'Composer install command must render PHP version check as one shell command.'
Assert-True (-not ($composerInstall.renderedCommand -match "-r\\s*`r?`n")) 'Composer install command must not split php -r from its code argument.'

$policyPlan = Resolve-CommandPlan -ExecutionPlan (New-TestResolvedPlan) -DeploymentStrategy (New-TestDeploymentStrategy -SelectedAdapterId 'archive.zip') -RuntimeArtifact (New-TestRuntimeArtifact) -PackagingPolicy (New-TestPackagingPolicy)
Assert-Equal (Get-Command -CommandPlan $policyPlan -CommandId 'archive.create').operation.packagingPolicy.policyId 'packaging-policy-test' 'Archive creation must carry the explicit packaging policy before runtime artifact creation.'
$wrongPolicy = New-TestPackagingPolicy -ExecutionPlanFingerprint 'other-fingerprint'
Assert-ThrowsLike -Script { Resolve-CommandPlan -ExecutionPlan (New-TestResolvedPlan) -DeploymentStrategy (New-TestDeploymentStrategy) -RuntimeArtifact (New-TestRuntimeArtifact) -PackagingPolicy $wrongPolicy | Out-Null } -Pattern 'Packaging policy validation failed: executionPlanFingerprint does not match' -Message 'Packaging policy fingerprint mismatch must be rejected.'
Assert-True ($composerInstall.renderedCommand -match 'ComposerJsonUnchanged') 'Composer install command must validate composer.json immutability.'
Assert-True ($composerInstall.renderedCommand -match 'ComposerLockUnchanged') 'Composer install command must validate composer.lock immutability.'
Assert-True ($composerInstall.renderedCommand -match 'WriteBoundarySatisfied') 'Composer install command must surface write boundary status.'
Assert-True ($composerInstall.renderedCommand -match 'WrittenPath=') 'Composer install command must report actual written paths.'
Assert-True ($composerInstall.renderedCommand -match 'NextStep=%s\\n.*remote.composer.install.validate') 'Composer install command must stop before install validation.'
Assert-True ($composerInstall.renderedCommand -match 'p==="bootstrap/cache"') 'Composer install write boundary must allow the Laravel package discovery directory.'
Assert-True ($composerInstall.renderedCommand -match 'p==="bootstrap/cache/packages.php"') 'Composer install write boundary must allow packages.php.'
Assert-True ($composerInstall.renderedCommand -match 'p==="bootstrap/cache/services.php"') 'Composer install write boundary must allow services.php.'
Assert-True (-not ($composerInstall.renderedCommand -match 'str_starts_with\(\$p,"bootstrap/cache/"')) 'Composer install write boundary must not allow arbitrary bootstrap/cache descendants.'
Assert-True ($composerInstall.renderedCommand -match 'deleted:"\.\$p') 'Composer install write boundary must treat deleted release paths as unexpected.'
Assert-True ($composerInstall.renderedCommand -match 'OutsideBoundaryChanged') 'Composer install command must carry outside-release boundary monitoring.'
Assert-True ($composerInstall.renderedCommand -match 'Illuminate\\Foundation\\ComposerScripts::postAutoloadDump') 'Composer install command must detect the observed Laravel Composer script class.'
Assert-True ($composerInstall.renderedCommand -match '@php artisan package:discover --ansi') 'Composer install command must detect the observed Laravel Composer command.'
Assert-True ($composerInstall.renderedCommand -match 'ScriptExecutionEvidence=%s') 'Composer install command must emit script evidence separately.'
Assert-True ($composerInstall.renderedCommand -match 'ObservedComposerScripts=%s') 'Composer install command must emit observed script class names.'
Assert-True ($composerInstall.renderedCommand -match 'ObservedComposerCommands=%s') 'Composer install command must emit observed script commands.'
Assert-Equal $composerInstall.operation.composerCommand 'composer install' 'Composer install operation must carry the contracted Composer command.'
Assert-Equal (($composerInstall.operation.allowedFlags) -join ',') '--no-dev,--prefer-dist,--optimize-autoloader,--no-interaction' 'Composer install operation must carry allowed flags.'
Assert-True ('--ignore-platform-reqs' -in @($composerInstall.operation.forbiddenFlags)) 'Composer install operation must forbid ignored platform requirements.'
Assert-Equal $composerInstall.operation.writeBoundary.root 'remote.releaseDirectory' 'Composer install operation must carry write boundary root.'
Assert-True ('vendor' -in @($composerInstall.operation.writeBoundary.allowedPaths)) 'Composer install write boundary must allow the vendor directory itself.'
Assert-True ('vendor/**' -in @($composerInstall.operation.writeBoundary.allowedPaths)) 'Composer install write boundary must allow vendor.'
Assert-True ('bootstrap/cache' -in @($composerInstall.operation.writeBoundary.allowedPaths)) 'Composer install write boundary must allow the package discovery directory itself.'
Assert-True ('storage/**' -in @($composerInstall.operation.writeBoundary.forbiddenPaths)) 'Composer install write boundary must forbid storage.'
Assert-True ('AutoloadPresent' -in @($composerInstall.operation.postValidation.requiredChecks)) 'Composer install postvalidation must require autoload.'
$composerInstallValidate = Get-Command -CommandPlan $zipPlan -CommandId 'remote.composer.install.validate'
Assert-Equal $composerInstallValidate.program 'interactive-ssh' 'Composer install validation must use an interactive SSH command block.'
Assert-True ($composerInstallValidate.renderedCommand -match 'DEPLOYMENT-REMOTE-COMPOSER-INSTALL-VALIDATE START') 'Composer install validation must emit a stable start marker.'
Assert-True ($composerInstallValidate.renderedCommand -match 'ComposerReexecuted=%s') 'Composer install validation must prove Composer was not reexecuted.'
Assert-True ($composerInstallValidate.renderedCommand -match 'CurrentComposerStrategyFingerprintMatches=%s') 'Composer install validation must emit strategy fingerprint precondition status.'
Assert-True ($composerInstallValidate.renderedCommand -match 'ExecutionPlanFingerprintMatches=%s') 'Composer install validation must emit execution plan fingerprint precondition status.'
Assert-True ($composerInstallValidate.renderedCommand -match 'RuntimeArtifactUnchanged=%s') 'Composer install validation must emit runtime artifact immutability status.'
Assert-True ($composerInstallValidate.renderedCommand -match 'ReleaseDirectoryExists=%s') 'Composer install validation must emit release directory precondition status.'
Assert-True ($composerInstallValidate.renderedCommand -match 'ComposerInstallValidated=%s') 'Composer install validation must emit the reconciliation result.'
Assert-True ($composerInstallValidate.renderedCommand -match "COMPOSER_INSTALL_OUTPUT_EVIDENCE=''") 'Composer install validation must not embed previous install stdout.'
Assert-True ($composerInstallValidate.renderedCommand -match 'SCRIPT_EXECUTION_EVIDENCE=''external-install-result-required''') 'Composer install validation must defer script evidence to the previous install result.'
Assert-True (-not ($composerInstallValidate.renderedCommand -match 'script-evidence-not-observed')) 'Composer install validation must not fail remote filesystem validation because previous stdout evidence is not embedded.'
Assert-True ($composerInstallValidate.renderedCommand -match 'BootstrapCachePathCount=%s') 'Composer install validation must emit bootstrap/cache path count.'
Assert-True ($composerInstallValidate.renderedCommand -match 'BootstrapCachePath=%s') 'Composer install validation must emit concrete bootstrap/cache paths.'
Assert-True ($composerInstallValidate.renderedCommand -match 'BootstrapCacheUnexpectedPath=%s') 'Composer install validation must emit concrete unexpected bootstrap/cache file paths.'
Assert-True ($composerInstallValidate.renderedCommand -match 'BootstrapCacheUnexpectedPathType=%s') 'Composer install validation must emit unexpected bootstrap/cache path types.'
Assert-True ($composerInstallValidate.renderedCommand -match 'BaselinePathCount=%s') 'Composer install validation must emit runtime artifact baseline path count.'
Assert-True ($composerInstallValidate.renderedCommand -match 'BaselinePath=%s') 'Composer install validation must emit runtime artifact baseline paths.'
Assert-True ($composerInstallValidate.renderedCommand -match 'ChangedPath=%s') 'Composer install validation must emit changed paths.'
Assert-True ($composerInstallValidate.renderedCommand -match 'ChangedPathType=%s') 'Composer install validation must classify changed paths as created, modified or deleted.'
Assert-True ($composerInstallValidate.renderedCommand -match 'UnchangedBaselinePath=%s') 'Composer install validation must emit unchanged baseline paths.'
Assert-True ($composerInstallValidate.renderedCommand -match 'UnexpectedChangedPath=%s') 'Composer install validation must emit unexpected changed paths.'
Assert-True ($composerInstallValidate.renderedCommand -match 'UnexpectedChangedPathType=%s') 'Composer install validation must emit unexpected changed path types.'
Assert-True ($composerInstallValidate.renderedCommand -match 'bootstrap/cache/\\.gitignore\\|file\\|baseline-gitignore-hash') 'Composer install validation must bind .gitignore as runtime artifact baseline evidence.'
Assert-True (-not ('bootstrap/cache/.gitignore' -in @($composerInstallValidate.operation.writeBoundary.allowedPaths))) 'Composer install validation must not add .gitignore to the write boundary.'
Assert-True ($composerInstallValidate.renderedCommand -match 'changed_path "\$p" created') 'Composer install validation must classify non-baseline paths as created.'
Assert-True ($composerInstallValidate.renderedCommand -match 'changed_path "\$p" modified') 'Composer install validation must classify changed baseline files as modified.'
Assert-True ($composerInstallValidate.renderedCommand -match 'changed_path "\$p" deleted') 'Composer install validation must classify missing baseline paths as deleted.'
Assert-True ($composerInstallValidate.renderedCommand -match 'UnexpectedPath=%s') 'Composer install validation must emit all unexpected paths.'
Assert-True ($composerInstallValidate.renderedCommand -match 'UnexpectedPathType=%s') 'Composer install validation must emit unexpected path types.'
Assert-True ($composerInstallValidate.renderedCommand -match 'DeletedPath=%s') 'Composer install validation must emit deleted expected paths.'
Assert-True ($composerInstallValidate.renderedCommand -match 'ValidationIssueCount=%s') 'Composer install validation must aggregate validation issues.'
Assert-True ($composerInstallValidate.renderedCommand -match 'ValidationIssue=%s') 'Composer install validation must emit every validation issue.'
Assert-True ($composerInstallValidate.renderedCommand -match 'AllowedPathCount=%s') 'Composer install validation must emit allowed path count.'
Assert-True ($composerInstallValidate.renderedCommand -match 'vendor/\*\*\|directory') 'Composer install validation must render allowed paths as multiline evidence.'
Assert-True ($composerInstallValidate.renderedCommand -match 'path_type\(\).*symlink') 'Composer install validation must classify symlink paths.'
Assert-True ($composerInstallValidate.renderedCommand -match 'while IFS="\\|" read -r p t') 'Composer install validation must support multiple emitted path rows.'
Assert-True ($composerInstallValidate.renderedCommand -match 'php -r ''echo hash_file\("sha256", \$argv\[1\]\);'' "\$1" 2>/dev/null') 'Composer install validation must render current_hash php fallback as one shell command.'
Assert-True (-not ($composerInstallValidate.renderedCommand -match "-r\\s*`r?`n")) 'Composer install validation must not split php -r from its code argument.'
Assert-True ($composerInstallValidate.renderedCommand -like '*awk -F "|" -v q="$p" ''$1==q { print $2; found=1 }*') 'Composer install validation must quote the unexpected bootstrap/cache awk classifier safely.'
$brokenAwkPredicate = "''" + '$1==q'
Assert-True (-not ($composerInstallValidate.renderedCommand.Contains($brokenAwkPredicate))) 'Composer install validation must not emit broken doubled shell quotes around awk predicates.'
Assert-True ($composerInstallValidate.renderedCommand -match 'ScriptEvidenceEvaluationCompleted=%s') 'Composer install validation must report independent script evidence evaluation completion.'
Assert-True (-not ($composerInstallValidate.renderedCommand -match '\[ "\$STEP_EXIT_CODE" = "0" \].*COMPOSER_INSTALL_OUTPUT_EVIDENCE')) 'Composer install validation must not gate script evidence on a clean boundary result.'
Assert-True ($composerInstallValidate.renderedCommand -match 'DoesExecutionPlanFingerprintChange=%s') 'Composer install validation must surface Execution Plan fingerprint impact.'
Assert-True ($composerInstallValidate.renderedCommand -match 'DoesComposerStrategyFingerprintChange=%s') 'Composer install validation must surface Composer Strategy fingerprint impact.'
Assert-True ($composerInstallValidate.renderedCommand -match 'DoesRuntimeArtifactChange=%s') 'Composer install validation must surface Runtime Artifact impact.'
Assert-True ($composerInstallValidate.renderedCommand -match 'ObservedComposerScripts=%s') 'Composer install validation must emit observed script evidence.'
Assert-True ($composerInstallValidate.renderedCommand -match 'ObservedComposerCommands=%s') 'Composer install validation must emit observed command evidence.'
Assert-True ($composerInstallValidate.renderedCommand -match 'NextStepStatus=%s') 'Composer install validation must stop before shared storage preparation.'
Assert-True (-not ($composerInstallValidate.renderedCommand -match '"\$COMPOSER_EXECUTABLE_PATH" install|(^|\s)composer (install|update|dump-autoload)(\s|$)|(^|\s)php artisan (package:discover|optimize)(\s|$)|--ignore-platform-reqs|\brm\b|\bunlink\b')) 'Composer install validation must not install, update, run Artisan, delete or bypass platform requirements.'
$sharedPrepare = Get-Command -CommandPlan $zipPlan -CommandId 'remote.shared-storage.prepare'
Assert-Equal $sharedPrepare.program 'interactive-ssh' 'Shared storage prepare must use an interactive SSH command block.'
Assert-Equal ((@($sharedPrepare.dependsOn)) -join ',') 'remote.composer.install.validate' 'Shared storage prepare must depend on Composer install validation.'
Assert-True ($sharedPrepare.renderedCommand -match '^clear\r?\n') 'Shared storage prepare must clear before the start marker.'
Assert-True ($sharedPrepare.renderedCommand -match 'DEPLOYMENT-REMOTE-SHARED-STORAGE-PREPARE START') 'Shared storage prepare must emit a stable start marker.'
Assert-True ($sharedPrepare.renderedCommand -match 'SharedStorageConfigurationPresent=%s') 'Shared storage prepare must emit configuration precondition.'
Assert-True ($sharedPrepare.renderedCommand -match 'SharedStorageRootResolved=%s') 'Shared storage prepare must emit root resolution precondition.'
Assert-True ($sharedPrepare.renderedCommand -match 'ConfiguredSharedDirectoryCount=%s') 'Shared storage prepare must emit configured directory count.'
Assert-True ($sharedPrepare.renderedCommand -match 'ConfiguredSharedFileCount=%s') 'Shared storage prepare must emit configured file count.'
Assert-True ($sharedPrepare.renderedCommand -match 'SharedPath=%s') 'Shared storage prepare must emit shared path.'
Assert-True ($sharedPrepare.renderedCommand -match 'SharedPathKind=%s') 'Shared storage prepare must emit path kind.'
Assert-True ($sharedPrepare.renderedCommand -match 'SharedTargetPath=%s') 'Shared storage prepare must emit resolved shared target path.'
Assert-True ($sharedPrepare.renderedCommand -match 'ReleaseLinkPath=%s') 'Shared storage prepare must emit resolved release link path.'
Assert-True ($sharedPrepare.renderedCommand -match 'ConflictPolicy=%s') 'Shared storage prepare must emit conflict policy.'
Assert-True ($sharedPrepare.renderedCommand -match 'InitializationPolicy=%s') 'Shared storage prepare must emit initialization policy.'
Assert-True ($sharedPrepare.renderedCommand -match 'SharedTargetState=%s') 'Shared storage prepare must emit shared target state.'
Assert-True ($sharedPrepare.renderedCommand -match 'ReleaseLinkState=%s') 'Shared storage prepare must emit release link state.'
Assert-True ($sharedPrepare.renderedCommand -match 'LinkTargetMatches=%s') 'Shared storage prepare must emit link target match status.'
Assert-True ($sharedPrepare.renderedCommand -match 'UnexpectedExistingPath=%s') 'Shared storage prepare must diagnose unexpected existing paths.'
Assert-True ($sharedPrepare.renderedCommand -match 'ValidationIssueCount=%s') 'Shared storage prepare must aggregate validation issues.'
Assert-True ($sharedPrepare.renderedCommand -match 'SharedStoragePrepared=%s') 'Shared storage prepare must emit final preparation state.'
Assert-True ($sharedPrepare.renderedCommand -match 'shared-storage-root-is-symlink') 'Shared storage prepare must reject a symlink shared root.'
Assert-True ($sharedPrepare.renderedCommand -match 'release-directory-is-symlink') 'Shared storage prepare must reject a symlink release directory.'
Assert-Equal $sharedPrepare.operation.sharedStorageRoot 'shared' 'Shared storage operation must carry explicit root.'
Assert-Equal $sharedPrepare.operation.configuredSharedDirectoryCount 1 'Shared storage operation must carry one configured directory.'
Assert-Equal $sharedPrepare.operation.configuredSharedFileCount 0 'Shared storage operation must carry zero configured files.'
Assert-Equal $sharedPrepare.operation.entries[0].sharedPath 'laravel_app/storage/app/private' 'Shared storage operation must carry configured shared path.'
Assert-Equal $sharedPrepare.operation.entries[0].releaseLinkPath 'laravel_app/storage/app/private' 'Shared storage operation must carry configured release link path.'
Assert-Equal $sharedPrepare.operation.entries[0].conflictPolicy 'fail' 'Shared storage operation must carry fail conflict policy.'
Assert-Equal $sharedPrepare.operation.entries[0].initializationPolicy 'explicit' 'Shared storage operation must carry explicit initialization policy.'
Assert-True ($sharedPrepare.renderedCommand -match 'mkdir -p "\$PARENT_DIR" "\$SHARED_TARGET_PATH"') 'Shared storage prepare may create the missing target directory.'
Assert-True ($sharedPrepare.renderedCommand -match 'ln -s "\$SHARED_TARGET_PATH" "\$RELEASE_LINK_PATH"') 'Shared storage prepare may create the configured release symlink.'
Assert-True (-not ($sharedPrepare.renderedCommand -match '\brm\b|\bunlink\b|\bmv\b|\bcp\b|composer (install|update|dump-autoload)|php artisan')) 'Shared storage prepare must not delete, move, copy, run Composer or run Artisan.'
Assert-True ((Get-Command -CommandPlan $zipPlan -CommandId 'remote.release-directory.prepare').renderedCommand -match '\.deployment/uploads') 'Remote prepare must create deployment workspace upload directory.'
$finalize = Get-Command -CommandPlan $zipPlan -CommandId 'remote.application.finalize'
Assert-True ($finalize.renderedCommand -match 'DEPLOYMENT-REMOTE-APPLICATION-FINALIZE START') 'Finalize command must emit a stable start marker.'
Assert-True ($finalize.renderedCommand -match 'runtime-artifact-test') 'Finalize command must bind to the runtime artifact release directory.'
Assert-True ($finalize.renderedCommand -match 'CurrentReleaseLink=%s') 'Finalize command must emit the current release link.'
Assert-True ($finalize.renderedCommand -match 'SharedStorageLinkTargetMatches=%s') 'Finalize command must validate the prepared shared-storage link.'
Assert-True ($finalize.renderedCommand -match 'max-complete-states=2') 'Finalize command must record rollback retention contract.'
Assert-True ($finalize.renderedCommand -match 'ln -sfn "\$RELEASE_DIRECTORY" "\$CURRENT_RELEASE_LINK"') 'Finalize command must update the current release pointer to the prepared release directory.'
Assert-True (-not ($finalize.renderedCommand -match '\.deployment/work/current')) 'Finalize command must not reference the obsolete work/current directory.'
foreach ($command in @($zipPlan.commands | Where-Object { $_.program -eq 'interactive-ssh' })) {
    Assert-True (-not ($command.renderedCommand -cmatch '(^|[^A-Za-z0-9_])(exit|logout|exec)([^A-Za-z0-9_]|$)')) "Interactive SSH command '$($command.commandId)' must not abort the session."
    Assert-True (-not ($command.renderedCommand -match "STEP_STATUS=\r?\n")) "Interactive SSH command '$($command.commandId)' must not split dynamic assignments across lines."
    Assert-True (-not ($command.renderedCommand -match "printf\s*\r?\n")) "Interactive SSH command '$($command.commandId)' must not split printf commands across lines."
}
Assert-CommandPlanSafe -CommandPlan $zipPlan
Assert-Equal @($zipPlan.humanGates).Count 1 'Command plan must carry human gates for session control.'
Assert-Equal (($zipPlan.humanGates[0].allowedResponses) -join ',') 'approved,rejected' 'Command plan human gate must preserve allowed responses.'
Assert-Equal $zipPlan.humanGates[0].sequence 400 'Command plan human gate must carry strategy sequence.'
Assert-Equal (($zipPlan.humanGates[0].dependsOn) -join ',') 'archive.create' 'Command plan human gate must carry strategy dependencies.'

$tarPlan = Resolve-CommandPlan -ExecutionPlan (New-TestResolvedPlan) -DeploymentStrategy (New-TestDeploymentStrategy -SelectedAdapterId 'archive.tar') -RuntimeArtifact (New-TestRuntimeArtifact -FileName 'artifact final.tar')
Assert-Equal $tarPlan.status 'ready' 'Complete TAR runtime artifact inputs must produce ready command plan.'
Assert-Equal $tarPlan.selectedAdapterId 'archive.tar' 'TAR adapter must be preserved.'
Assert-True ((Get-Command -CommandPlan $tarPlan -CommandId 'remote.archive.extract').renderedCommand -match 'tar -xf') 'TAR adapter must affect extraction command.'
Assert-Equal (Get-Command -CommandPlan $zipPlan -CommandId 'artifact.upload').operation.artifactId 'runtime-artifact-test' 'Artifact upload must carry runtime artifact identity.'
Assert-Equal (Get-Command -CommandPlan $zipPlan -CommandId 'artifact.upload').operation.localArtifactPath (New-TestRuntimeArtifact).localPath 'Artifact upload must use local path exclusively from runtime artifact.'

$noInputPlan = Resolve-CommandPlan -ExecutionPlan (New-TestResolvedPlan) -DeploymentStrategy (New-TestDeploymentStrategy -WithCommandInputs:$false)
Assert-Equal $noInputPlan.status 'incomplete' 'Missing runtime artifact must produce incomplete command plan.'
Assert-True (-not [string]::IsNullOrWhiteSpace((Get-Command -CommandPlan $noInputPlan -CommandId 'remote.release-directory.prepare').renderedCommand)) 'Remote command blocks must not require an SSH target.'
Assert-Equal (Get-Command -CommandPlan $noInputPlan -CommandId 'artifact.upload').program 'network-share' 'Incomplete artifact transport must still keep network-share program identity.'
Assert-Equal (Get-Command -CommandPlan $noInputPlan -CommandId 'artifact.upload').renderedCommand '' 'Incomplete artifact transport command must not render a command.'

$missingRemotePath = New-TestResolvedPlan -RemotePath ''
Assert-ThrowsLike -Script { Resolve-CommandPlan -ExecutionPlan $missingRemotePath -DeploymentStrategy (New-TestDeploymentStrategy) | Out-Null } -Pattern "field 'applicationRemoteDirectory' must not be empty" -Message 'Missing remote path must be rejected by execution plan validation.'

$relativePlanRemotePath = New-TestResolvedPlan -RemotePath 'deployment-target/laravel_app'
Assert-ThrowsLike -Script { Resolve-CommandPlan -ExecutionPlan $relativePlanRemotePath -DeploymentStrategy (New-TestDeploymentStrategy) | Out-Null } -Pattern 'applicationRemoteDirectory must be an absolute remote path' -Message 'Command plan builder must remain strict and reject unresolved relative remote paths.'

$metadataPlan = New-TestResolvedPlan
Add-Member -InputObject $metadataPlan -MemberType NoteProperty -Name 'environmentChanges' -Value ([pscustomobject]@{
    path = 'laravel_app/.env.example'
    addedKeys = @('APP_KEY', 'RESOURCE_LOCK_HMAC_KEY')
    keyAssessments = @([pscustomobject]@{ key = 'APP_KEY'; strategy = 'generate-remote-if-missing'; secret = $true; valuePresent = $false })
    notes = 'The .env file is referenced as protected metadata only.'
})
Add-Member -InputObject $metadataPlan -MemberType NoteProperty -Name 'protection' -Value ([pscustomobject]@{
    neverUpload = @('.env', '.env.*')
    neverOverwrite = @('.env')
})
Assert-Equal (Resolve-CommandPlan -ExecutionPlan $metadataPlan -DeploymentStrategy (New-TestDeploymentStrategy) -RuntimeArtifact (New-TestRuntimeArtifact)).status 'ready' 'Structured .env metadata and environment key names without values must be allowed.'

$envContentPlan = Copy-TestObject -Value (New-TestResolvedPlan)
Add-Member -InputObject $envContentPlan -MemberType NoteProperty -Name 'leakedEnvironmentContent' -Value 'APP_KEY=base64:abc123'
Assert-ThrowsLike -Script { Resolve-CommandPlan -ExecutionPlan $envContentPlan -DeploymentStrategy (New-TestDeploymentStrategy) | Out-Null } -Pattern 'secret-like value' -Message 'Actual KEY=value environment content must be rejected.'

$sensitiveFieldPlan = Copy-TestObject -Value (New-TestResolvedPlan)
Add-Member -InputObject $sensitiveFieldPlan.environment -MemberType NoteProperty -Name 'password' -Value 'not-allowed'
Assert-ThrowsLike -Script { Resolve-CommandPlan -ExecutionPlan $sensitiveFieldPlan -DeploymentStrategy (New-TestDeploymentStrategy) | Out-Null } -Pattern "sensitive field 'password'" -Message 'Known secret-like fields with values must be rejected.'

$nestedSecretStrategy = New-TestDeploymentStrategy
Add-Member -InputObject $nestedSecretStrategy.commandInputs -MemberType NoteProperty -Name 'nestedCommandData' -Value ([pscustomobject]@{ arguments = @('php', 'artisan', 'demo', 'TOKEN=abc123') })
Assert-ThrowsLike -Script { Resolve-CommandPlan -ExecutionPlan (New-TestResolvedPlan) -DeploymentStrategy $nestedSecretStrategy | Out-Null } -Pattern 'secret-like value' -Message 'Secret values inside nested command data must be rejected.'

$wrongFingerprintArtifact = New-TestRuntimeArtifact -ExecutionPlanFingerprint 'other-fingerprint'
Assert-ThrowsLike -Script { Resolve-CommandPlan -ExecutionPlan (New-TestResolvedPlan) -DeploymentStrategy (New-TestDeploymentStrategy) -RuntimeArtifact $wrongFingerprintArtifact | Out-Null } -Pattern 'executionPlanFingerprint does not match' -Message 'Runtime artifact with wrong fingerprint must be rejected.'

$missingLocalPathArtifact = New-TestRuntimeArtifact
$missingLocalPathArtifact.localPath = ''
Assert-ThrowsLike -Script { Resolve-CommandPlan -ExecutionPlan (New-TestResolvedPlan) -DeploymentStrategy (New-TestDeploymentStrategy) -RuntimeArtifact $missingLocalPathArtifact | Out-Null } -Pattern "field 'localPath' must not be empty" -Message 'Runtime artifact without localPath must be rejected.'

$missingPackagingBindingArtifact = New-TestRuntimeArtifact
$missingPackagingBindingArtifact.PSObject.Properties.Remove('packagingPolicyId')
Assert-ThrowsLike -Script { Resolve-CommandPlan -ExecutionPlan (New-TestResolvedPlan) -DeploymentStrategy (New-TestDeploymentStrategy) -RuntimeArtifact $missingPackagingBindingArtifact | Out-Null } -Pattern "packagingPolicyId" -Message 'Runtime artifact without packaging policy binding must be rejected.'

$missingComposerStrategy = New-TestDeploymentStrategy
$missingComposerStrategy.PSObject.Properties.Remove('composerStrategy')
Assert-ThrowsLike -Script { Resolve-CommandPlan -ExecutionPlan (New-TestResolvedPlan) -DeploymentStrategy $missingComposerStrategy -RuntimeArtifact (New-TestRuntimeArtifact) | Out-Null } -Pattern 'composerStrategy contract is required' -Message 'Deployment strategy without Composer Strategy contract must be rejected.'

$missingSharedStorage = New-TestDeploymentStrategy
$missingSharedStorage.PSObject.Properties.Remove('sharedStorage')
Assert-ThrowsLike -Script { Resolve-CommandPlan -ExecutionPlan (New-TestResolvedPlan) -DeploymentStrategy $missingSharedStorage -RuntimeArtifact (New-TestRuntimeArtifact) | Out-Null } -Pattern 'sharedStorage contract is required' -Message 'Deployment strategy without Shared Storage contract must be rejected.'

$badComposerStrategy = New-TestDeploymentStrategy
$badComposerStrategy.composerStrategy.productionMode = 'true'
Assert-ThrowsLike -Script { Resolve-CommandPlan -ExecutionPlan (New-TestResolvedPlan) -DeploymentStrategy $badComposerStrategy -RuntimeArtifact (New-TestRuntimeArtifact) | Out-Null } -Pattern 'productionMode' -Message 'Composer Strategy boolean fields must be validated.'

$missingInstallContract = New-TestDeploymentStrategy
$missingInstallContract.composerStrategy.PSObject.Properties.Remove('installContract')
Assert-ThrowsLike -Script { Resolve-CommandPlan -ExecutionPlan (New-TestResolvedPlan) -DeploymentStrategy $missingInstallContract -RuntimeArtifact (New-TestRuntimeArtifact) | Out-Null } -Pattern 'installContract is required' -Message 'Composer Strategy without install contract must be rejected.'

$emptyAllowedFlags = New-TestDeploymentStrategy
$emptyAllowedFlags.composerStrategy.installContract.allowedFlags = @()
Assert-ThrowsLike -Script { Resolve-CommandPlan -ExecutionPlan (New-TestResolvedPlan) -DeploymentStrategy $emptyAllowedFlags -RuntimeArtifact (New-TestRuntimeArtifact) | Out-Null } -Pattern 'allowedFlags' -Message 'Composer install contract without allowed flags must be rejected.'

$badRunIdStrategy = New-TestDeploymentStrategy
$badRunIdStrategy.commandInputs.deploymentRunId = '../run'
$badRunPlan = Resolve-CommandPlan -ExecutionPlan (New-TestResolvedPlan) -DeploymentStrategy $badRunIdStrategy -RuntimeArtifact (New-TestRuntimeArtifact)
Assert-Equal (Get-Command -CommandPlan $badRunPlan -CommandId 'remote.release.prepare').program 'interactive-ssh' 'Invalid release prepare remains an interactive-ssh step identity.'
Assert-Equal (Get-Command -CommandPlan $badRunPlan -CommandId 'remote.release.prepare').renderedCommand '' 'Invalid run id must not render a release prepare command.'
Assert-True ((Get-Command -CommandPlan $badRunPlan -CommandId 'remote.release.prepare').diagnostic -match 'DeploymentRunId') 'Invalid run id must be diagnosed.'

$badArtifactId = New-TestRuntimeArtifact
$badArtifactId.artifactId = '../artifact'
$badArtifactPlan = Resolve-CommandPlan -ExecutionPlan (New-TestResolvedPlan) -DeploymentStrategy (New-TestDeploymentStrategy) -RuntimeArtifact $badArtifactId
Assert-Equal (Get-Command -CommandPlan $badArtifactPlan -CommandId 'remote.release.prepare').renderedCommand '' 'Invalid artifact id must not render release prepare.'
Assert-True ((Get-Command -CommandPlan $badArtifactPlan -CommandId 'remote.release.prepare').diagnostic -match 'ArtifactId') 'Invalid artifact id must be diagnosed.'

$outsideReleaseRoot = New-TestDeploymentStrategy
$outsideReleaseRoot.deploymentWorkspace.releasesDirectory = 'releases'
$outsidePlan = Resolve-CommandPlan -ExecutionPlan (New-TestResolvedPlan) -DeploymentStrategy $outsideReleaseRoot -RuntimeArtifact (New-TestRuntimeArtifact)
Assert-Equal (Get-Command -CommandPlan $outsidePlan -CommandId 'remote.release.prepare').renderedCommand '' 'Release prepare outside .deployment/releases must not render.'
Assert-True ((Get-Command -CommandPlan $outsidePlan -CommandId 'remote.release.prepare').diagnostic -match '\.deployment/releases') 'Release root violation must be diagnosed.'

$missingRunId = New-TestDeploymentStrategy
$missingRunId.commandInputs.PSObject.Properties.Remove('deploymentRunId')
$missingRunPlan = Resolve-CommandPlan -ExecutionPlan (New-TestResolvedPlan) -DeploymentStrategy $missingRunId -RuntimeArtifact (New-TestRuntimeArtifact)
Assert-Equal (Get-Command -CommandPlan $missingRunPlan -CommandId 'remote.release.prepare').renderedCommand '' 'Missing deployment run id must not render release prepare.'

$planBeforeRuntime = New-TestResolvedPlan
$planBeforeRuntimeJson = $planBeforeRuntime | ConvertTo-Json -Depth 60
$null = Resolve-CommandPlan -ExecutionPlan $planBeforeRuntime -DeploymentStrategy (New-TestDeploymentStrategy) -RuntimeArtifact (New-TestRuntimeArtifact)
Assert-Equal ($planBeforeRuntime | ConvertTo-Json -Depth 60) $planBeforeRuntimeJson 'Runtime artifact command generation must not mutate the resolved execution plan.'

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

$badTransport = New-TestDeploymentStrategy
$badTransport.artifactTransport.adapterId = 'scp'
Assert-ThrowsLike -Script { Resolve-CommandPlan -ExecutionPlan (New-TestResolvedPlan) -DeploymentStrategy $badTransport | Out-Null } -Pattern 'unsupported artifact transport adapter' -Message 'Command plan builder must reject SCP as artifact transport.'

$badRemoteExecution = New-TestDeploymentStrategy
$badRemoteExecution.remoteExecution.mode = 'ssh'
Assert-ThrowsLike -Script { Resolve-CommandPlan -ExecutionPlan (New-TestResolvedPlan) -DeploymentStrategy $badRemoteExecution | Out-Null } -Pattern 'unsupported remote execution mode' -Message 'Command plan builder must reject embedded SSH execution mode.'

$badLocation = New-TestDeploymentStrategy
@($badLocation.steps | Where-Object { $_.stepId -eq 'artifact.upload' } | Select-Object -First 1)[0].executionLocation = 'remote'
Assert-ThrowsLike -Script { Resolve-CommandPlan -ExecutionPlan (New-TestResolvedPlan) -DeploymentStrategy $badLocation | Out-Null } -Pattern 'artifact-upload requires executionLocation artifact-transport' -Message 'Command plan builder must reject artifact upload outside artifact-transport.'

$oldLocation = New-TestDeploymentStrategy
@($oldLocation.steps | Where-Object { $_.stepId -eq 'artifact.upload' } | Select-Object -First 1)[0].executionLocation = 'local-to-remote'
Assert-ThrowsLike -Script { Resolve-CommandPlan -ExecutionPlan (New-TestResolvedPlan) -DeploymentStrategy $oldLocation | Out-Null } -Pattern 'unsupported status' -Message 'Command plan builder must reject old local-to-remote execution location.'

$planInput = New-TestResolvedPlan
$strategyInput = New-TestDeploymentStrategy
$planBefore = $planInput | ConvertTo-Json -Depth 60
$strategyBefore = $strategyInput | ConvertTo-Json -Depth 60
$commandPlan = Resolve-CommandPlan -ExecutionPlan $planInput -DeploymentStrategy $strategyInput
Assert-Equal ($planInput | ConvertTo-Json -Depth 60) $planBefore 'Command generation must not mutate execution plan input.'
Assert-Equal ($strategyInput | ConvertTo-Json -Depth 60) $strategyBefore 'Command generation must not mutate deployment strategy input.'
$commandPlan.commands[0].arguments = @('changed')
Assert-Equal $strategyInput.steps[0].operationType 'source-validate' 'Command output must not reference-mutate strategy input.'

$quoted = ConvertTo-RenderedCommand -Program 'network-share' -Arguments @("C:\Build Output\artifact's.zip", 'D:\Share Uploads\artifact.zip')
foreach ($expected in @('Copy-Item -LiteralPath', "'C:\Build Output\artifact''s.zip'", "'D:\Share Uploads\artifact.zip'")) {
    Assert-True ($quoted -match [regex]::Escape($expected)) "Rendered network-share command must preserve quoted argument fragment '$expected'."
}

$interactiveBlock = ConvertTo-RenderedCommand -Program 'interactive-ssh' -Arguments @('STEP_STATUS=WaitingForHuman', 'printf Status=%s "$STEP_STATUS"')
Assert-Equal $interactiveBlock ('STEP_STATUS=WaitingForHuman' + "`n" + 'printf Status=%s "$STEP_STATUS"') 'interactive-ssh renderer must return the remote command block without wrapping ssh.'

$source = Get-Content -LiteralPath $commandPlanPath -Raw
foreach ($forbidden in @('Start-Process', 'Invoke-Expression', 'System.Diagnostics.Process', 'ProcessStartInfo', 'ssh.exe', 'scp.exe', 'git.exe', 'tar.exe', '7z.exe', 'iex ', 'cmd /c', 'bash -c', 'sh -c')) {
    Assert-True (-not ($source -match [regex]::Escape($forbidden))) "Command generation source must not contain process starter '$forbidden'."
}

$tmp = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('command-generation-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    $planPath = Join-Path -Path $tmp -ChildPath 'execution-plan.json'
    $strategyPathInput = Join-Path -Path $tmp -ChildPath 'deployment-strategy.json'
    $runtimeArtifactPath = Join-Path -Path $tmp -ChildPath 'runtime-artifact.json'
    $outputPath = Join-Path -Path $tmp -ChildPath 'nested/command-plan.json'
    New-TestResolvedPlan | ConvertTo-Json -Depth 60 | Set-Content -LiteralPath $planPath -Encoding UTF8
    New-TestDeploymentStrategy | ConvertTo-Json -Depth 60 | Set-Content -LiteralPath $strategyPathInput -Encoding UTF8
    New-TestRuntimeArtifact | ConvertTo-Json -Depth 60 | Set-Content -LiteralPath $runtimeArtifactPath -Encoding UTF8

    Assert-ThrowsLike -Script { & $cliPath generate-commands -DeploymentStrategyPath $strategyPathInput -Format Json | Out-Null } -Pattern "Missing required parameter for 'generate-commands': -ExecutionPlanPath" -Message 'CLI missing ExecutionPlanPath must be rejected.'
    Assert-ThrowsLike -Script { & $cliPath generate-commands -ExecutionPlanPath $planPath -Format Json | Out-Null } -Pattern "Missing required parameter for 'generate-commands': -DeploymentStrategyPath" -Message 'CLI missing DeploymentStrategyPath must be rejected.'
    Assert-ThrowsLike -Script { & $cliPath generate-commands -ExecutionPlanPath $planPath -DeploymentStrategyPath $strategyPathInput -Format Text | Out-Null } -Pattern 'only supports -Format Json' -Message 'CLI invalid format must be rejected.'

    & $cliPath generate-commands -ExecutionPlanPath $planPath -DeploymentStrategyPath $strategyPathInput -RuntimeArtifactPath $runtimeArtifactPath -OutputPath $outputPath -Format Json | Out-Null
    Assert-True (Test-Path -LiteralPath $outputPath -PathType Leaf) 'CLI must create exactly the explicit command plan file.'
    $filePlan = Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json
    Assert-Equal $filePlan.commandPlanType 'deployment-command-plan' 'CLI output file must contain command plan JSON.'
    Assert-Equal $filePlan.status 'ready' 'CLI with runtime artifact must produce a ready command plan.'

    $fileCountBeforeStdout = @(Get-ChildItem -LiteralPath $tmp -File -Recurse).Count
    $stdoutJson = & $cliPath generate-commands -ExecutionPlanPath $planPath -DeploymentStrategyPath $strategyPathInput -Format Json
    $fileCountAfterStdout = @(Get-ChildItem -LiteralPath $tmp -File -Recurse).Count
    $stdoutPlan = $stdoutJson | ConvertFrom-Json
    Assert-Equal $stdoutPlan.commandPlanType 'deployment-command-plan' 'CLI without OutputPath must emit parseable JSON.'
    Assert-Equal $stdoutPlan.status 'incomplete' 'CLI without RuntimeArtifactPath must keep artifact upload incomplete.'
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
    throw 'Command Generation tests failed.'
}

Write-Host 'Command Generation tests passed.'
