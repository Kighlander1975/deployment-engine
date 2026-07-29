[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:failures = New-Object System.Collections.Generic.List[string]
$engineRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '..'))
$builderPath = Join-Path -Path $engineRoot -ChildPath 'src/ps1/Invoke-ExecutionPlanBuild.ps1'

. $builderPath -AnalysisPath 'unused-analysis.json' -ProjectManifestPath 'unused-manifest.json'

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

function New-TestManifest {
    return @'
{
  "schemaVersion": "0.1",
  "project": {
    "id": "demo",
    "name": "Demo",
    "applicationRoot": "laravel_app",
    "type": "laravel"
  },
  "deployment": {
    "environment": "staging",
    "serverRoot": "deployment-target",
    "markerFile": ".deploy-version"
  },
  "protection": {
    "neverUpload": [".env", "storage/**", "vendor/**", "node_modules/**"],
    "neverOverwrite": [".env", ".deploy-version", "storage/**"]
  },
  "sharedStorage": {
    "root": "shared",
    "directories": [
      {
        "sharedPath": "laravel_app/storage/app/private",
        "releaseLinkPath": "laravel_app/storage/app/private",
        "pathKind": "directory",
        "conflictPolicy": "fail",
        "initializationPolicy": "explicit"
      }
    ],
    "files": []
  },
  "classification": {
    "persistentData": ["laravel_app/storage/app/private/**"]
  }
}
'@ | ConvertFrom-Json
}

function New-TestAnalysis {
    param(
        [bool] $RuntimeDeploymentRequired = $true,
        [bool] $FrontendBuildRequired = $true,
        [bool] $ComposerInstallRequired = $false,
        [bool] $MigrationsRequired = $true,
        [bool] $EnvironmentReviewRequired = $true,
        [bool] $SeederReviewRequired = $true,
        [bool] $CleanupRequired = $true,
        [bool] $ProtectedFileReviewRequired = $false,
        [bool] $DocumentationOnly = $false,
        [string[]] $Blockers = @()
    )

    $analysis = @'
{
  "engineVersion": "0.1",
  "project": { "id": "demo", "name": "Demo" },
  "environment": {
    "name": "staging",
    "serverRoot": "/var/www/demo",
    "markerFile": ".deploy-version"
  },
  "baselineCommit": "1111111111111111111111111111111111111111",
  "targetCommit": "2222222222222222222222222222222222222222",
  "classifications": [
    { "status": "M", "path": "laravel_app/.env.example", "classes": ["environmentContract"] },
    { "status": "D", "path": "laravel_app/app/OldController.php", "classes": ["backendRuntime", "deletion"] },
    { "status": "A", "path": "laravel_app/database/migrations/2026_01_01_000000_demo.php", "classes": ["migrations"] },
    { "status": "M", "path": "laravel_app/resources/js/app.jsx", "classes": ["frontendSource"] }
  ],
  "environmentChanges": {
    "path": "laravel_app/.env.example",
    "addedKeys": ["NEW_KEY"],
    "removedKeys": [],
    "keyAssessments": [
      {
        "key": "NEW_KEY",
        "changeType": "added",
        "contractStatus": "missing-rule",
        "strategy": null,
        "secret": null,
        "overwrite": null,
        "required": null,
        "recommendedAction": "add-manifest-rule",
        "executionAllowed": false,
        "reviewRequired": true
      }
    ],
    "unknownKeys": ["NEW_KEY"],
    "contractIssues": []
  },
  "seederReview": {
    "changed": true,
    "files": [
      {
        "path": "laravel_app/database/seeders/RoleSeeder.php",
        "status": "M",
        "changeType": "modified",
        "probablePurpose": "reference-data",
        "affectedModels": ["Role"],
        "affectedTables": [],
        "destructiveOperations": [],
        "writeOperations": ["updateOrCreate"],
        "probableIdempotency": "likely",
        "riskLevel": "medium",
        "confidence": "medium",
        "reviewRequired": true,
        "recommendations": ["Do not execute automatically.", "Review changed seeders before deployment."],
        "evidence": ["References App\\Models\\Role", "Uses updateOrCreate"]
      }
    ],
    "summary": {
      "total": 1,
      "added": 0,
      "modified": 1,
      "deleted": 0,
      "highRisk": 0,
      "reviewRequired": true
    }
  },
  "decisions": {
    "runtimeDeploymentRequired": true,
    "frontendBuildRequired": true,
    "composerInstallRequired": false,
    "migrationsRequired": true,
    "environmentReviewRequired": true,
    "cleanupRequired": true,
    "protectedFileReviewRequired": false,
    "environmentContractIncomplete": true,
    "seederReviewRequired": true,
    "documentationOnly": false
  },
  "warnings": ["Git working tree is not clean."],
  "blockers": [],
  "manualApprovalPoints": ["Migration phase requires explicit approval."]
}
'@ | ConvertFrom-Json

    $analysis.decisions.runtimeDeploymentRequired = $RuntimeDeploymentRequired
    $analysis.decisions.frontendBuildRequired = $FrontendBuildRequired
    $analysis.decisions.composerInstallRequired = $ComposerInstallRequired
    $analysis.decisions.migrationsRequired = $MigrationsRequired
    $analysis.decisions.environmentReviewRequired = $EnvironmentReviewRequired
    $analysis.decisions.cleanupRequired = $CleanupRequired
    $analysis.decisions.protectedFileReviewRequired = $ProtectedFileReviewRequired
    $analysis.seederReview.changed = $SeederReviewRequired
    $analysis.seederReview.summary.reviewRequired = $SeederReviewRequired
    if ($analysis.decisions.PSObject.Properties.Name -contains 'seederReviewRequired') { $analysis.decisions.seederReviewRequired = $SeederReviewRequired }
    $analysis.decisions.documentationOnly = $DocumentationOnly
    $analysis.blockers = @($Blockers)

    if ($ProtectedFileReviewRequired) {
        $analysis.classifications += [pscustomobject]@{
            status = 'M'
            path = 'laravel_app/public/.htaccess'
            classes = @('protected-server-file')
        }
    }

    return $analysis
}

function New-TestRemoteTarget {
    param(
        [string] $RemoteRoot = '/var/www/demo',
        [string] $ApplicationPath = 'app.example.test',
        [string] $TargetId = 'staging'
    )

    return [pscustomobject]@{
        schemaVersion = '0.1'
        targetId = $TargetId
        targetConfigurationPath = 'D:\Targets\staging.json'
        logicalServerRoot = 'deployment-target'
        remoteRoot = $RemoteRoot
        applicationPath = $ApplicationPath
        applicationRemoteDirectory = "$($RemoteRoot.TrimEnd('/'))/$ApplicationPath"
        resolution = 'remoteRoot-plus-applicationPath'
    }
}

function New-TestTargetConfiguration {
    param(
        [string] $RemoteRoot = '/var/www/demo',
        [string] $ApplicationPath = 'app.example.test',
        [string] $TargetId = 'staging'
    )

    return [pscustomobject]@{
        path = 'D:\Targets\staging.json'
        value = [pscustomobject]@{
            schemaVersion = '0.1'
            targetId = $TargetId
            remoteRoot = $RemoteRoot
            applicationPath = $ApplicationPath
        }
    }
}

function Get-Step {
    param([object] $Plan, [string] $Id)
    return @($Plan.steps | Where-Object { $_.id -eq $Id } | Select-Object -First 1)[0]
}

$manifest = New-TestManifest
$analysis = New-TestAnalysis
$remoteTarget = New-TestRemoteTarget
$resolvedRemoteTarget = Resolve-RemoteTarget -Manifest $manifest -TargetConfiguration (New-TestTargetConfiguration -RemoteRoot '/var/www/demo/')
Assert-Equal $resolvedRemoteTarget.remoteRoot '/var/www/demo' 'Remote root must be normalized without trailing slash.'
Assert-Equal $manifest.project.applicationRoot 'laravel_app' 'Local applicationRoot must remain a valid local project path value.'
Assert-Equal $resolvedRemoteTarget.applicationPath 'app.example.test' 'Remote target resolution must carry target applicationPath.'
Assert-Equal $resolvedRemoteTarget.applicationRemoteDirectory '/var/www/demo/app.example.test' 'Remote target resolution must combine remoteRoot and target applicationPath.'
Assert-Equal $resolvedRemoteTarget.logicalServerRoot 'deployment-target' 'Remote target resolution must preserve logical server root.'

foreach ($badRemoteRoot in @('', 'relative/root', './relative', '/var/www/../escape', '/var/www/.', '/var//www')) {
    try {
        [void] (Resolve-RemoteTarget -Manifest $manifest -TargetConfiguration (New-TestTargetConfiguration -RemoteRoot $badRemoteRoot))
        $script:failures.Add("Invalid remoteRoot must be rejected: '$badRemoteRoot'")
    } catch {
        Assert-True ($_.Exception.Message -match 'remoteRoot|absolute POSIX|segments') "Invalid remoteRoot must produce controlled error: '$badRemoteRoot'"
    }
}

try {
    $missingRemoteRootTarget = New-TestTargetConfiguration
    $missingRemoteRootTarget.value.PSObject.Properties.Remove('remoteRoot')
    [void] (Resolve-RemoteTarget -Manifest $manifest -TargetConfiguration $missingRemoteRootTarget)
    $script:failures.Add('Missing remoteRoot must be rejected.')
} catch {
    Assert-True ($_.Exception.Message -match 'remoteRoot') 'Missing remoteRoot must produce controlled error.'
}

try {
    $missingApplicationPathTarget = New-TestTargetConfiguration
    $missingApplicationPathTarget.value.PSObject.Properties.Remove('applicationPath')
    [void] (Resolve-RemoteTarget -Manifest $manifest -TargetConfiguration $missingApplicationPathTarget)
    $script:failures.Add('Missing applicationPath must be rejected.')
} catch {
    Assert-True ($_.Exception.Message -match 'applicationPath') 'Missing applicationPath must produce controlled error.'
}

foreach ($badApplicationPath in @('', '/absolute', '.', '..', 'app/../laravel_app', 'app/./laravel_app', 'app//laravel_app')) {
    try {
        [void] (Resolve-RemoteTarget -Manifest $manifest -TargetConfiguration (New-TestTargetConfiguration -ApplicationPath $badApplicationPath))
        $script:failures.Add("Invalid target.applicationPath must be rejected: '$badApplicationPath'")
    } catch {
        Assert-True ($_.Exception.Message -match 'applicationPath|relative|segments|empty') "Invalid applicationPath must produce controlled error: '$badApplicationPath'"
    }
}

$remoteOnlyManifest = New-TestManifest
$remoteOnlyManifest.project.applicationRoot = 'different-local-app'
$remoteOnlyTarget = Resolve-RemoteTarget -Manifest $remoteOnlyManifest -TargetConfiguration (New-TestTargetConfiguration -RemoteRoot '/var/www/demo' -ApplicationPath 'remote-app')
Assert-Equal $remoteOnlyTarget.applicationRemoteDirectory '/var/www/demo/remote-app' 'project.applicationRoot must not influence remote target resolution.'

$unresolvedPlan = New-UnresolvedExecutionPlan -Analysis $analysis -Manifest $manifest -RemoteTarget $remoteTarget
$unresolvedBeforeResolve = $unresolvedPlan | ConvertTo-Json -Depth 30
$resolvedFromUnresolved = Resolve-DeploymentCapabilities -Plan $unresolvedPlan
$unresolvedAfterResolve = $unresolvedPlan | ConvertTo-Json -Depth 30
$plan = New-ExecutionPlan -Analysis $analysis -Manifest $manifest -RemoteTarget $remoteTarget
$planJsonA = $plan | ConvertTo-Json -Depth 30
$planJsonB = (New-ExecutionPlan -Analysis $analysis -Manifest $manifest -RemoteTarget $remoteTarget) | ConvertTo-Json -Depth 30

Assert-Equal $unresolvedBeforeResolve $unresolvedAfterResolve 'Resolver must not mutate the unresolved input plan.'
Assert-True (-not (Test-PropertyValue -Object $unresolvedPlan -Name 'resolved')) 'Unresolved input plan must not receive resolved flag.'
Assert-True $resolvedFromUnresolved.resolved 'Resolved plan must receive resolved flag.'
Assert-Equal $plan.blocked $false 'Empty blocker list must not block the plan.'
Assert-Equal ($plan.phases -join ',') 'preconditions,environment-review,local-frontend-build,local-deployment-preparation,runtime-file-transfer,runtime-cleanup,remote-dependency-installation,database-review,remote-migrations,remote-runtime-maintenance,deployment-verification,deployment-marker-update' 'Phase order must be stable.'
Assert-Equal $planJsonA $planJsonB 'Execution plan output must be deterministic.'
Assert-True (-not [string]::IsNullOrWhiteSpace([string] $plan.executionPlanFingerprint)) 'Resolved execution plan must include an executionPlanFingerprint.'
Assert-Equal $plan.executionPlanFingerprint (Get-ExecutionPlanFingerprint -Plan $plan) 'Resolved execution plan fingerprint must match canonical plan content.'
Assert-Equal $plan.steps[-1].id 'deployment-marker.update' 'Deployment marker update must be the final step.'
Assert-Equal $plan.environment.applicationRemoteDirectory '/var/www/demo/app.example.test' 'Resolved plan must contain absolute application remote directory.'
Assert-Equal $plan.environment.remoteTarget.remoteRoot '/var/www/demo' 'Resolved plan must carry normalized remote root.'
Assert-Equal $plan.environment.remoteTarget.applicationPath 'app.example.test' 'Resolved plan must carry target application path.'
Assert-True $plan.environment.sharedStorage.configurationPresent 'Resolved plan must mark shared storage configuration as present.'
Assert-True $plan.environment.sharedStorage.rootResolved 'Resolved plan must mark shared storage root as resolved.'
Assert-Equal $plan.environment.sharedStorage.root 'shared' 'Resolved plan must carry explicit shared storage root.'
Assert-Equal $plan.environment.sharedStorage.sharedRootAbsolutePath '/var/www/demo/app.example.test/shared' 'Shared storage root must resolve below applicationRemoteDirectory.'
Assert-Equal @($plan.environment.sharedStorage.directories).Count 1 'Resolved plan must carry exactly one shared directory.'
Assert-Equal @($plan.environment.sharedStorage.files).Count 0 'Resolved plan must carry zero shared files.'
Assert-Equal $plan.environment.sharedStorage.directories[0].sharedPath 'laravel_app/storage/app/private' 'Resolved plan must carry the configured shared target path.'
Assert-Equal $plan.environment.sharedStorage.directories[0].releaseLinkPath 'laravel_app/storage/app/private' 'Resolved plan must carry the configured release link path.'
Assert-Equal $plan.environment.sharedStorage.directories[0].pathKind 'directory' 'Resolved plan must carry path kind.'
Assert-Equal $plan.environment.sharedStorage.directories[0].conflictPolicy 'fail' 'Resolved plan must carry fail conflict policy.'
Assert-Equal $plan.environment.sharedStorage.directories[0].initializationPolicy 'explicit' 'Resolved plan must carry explicit initialization policy.'
Assert-Equal $plan.environment.sharedStorage.directories[0].sharedAbsolutePath '/var/www/demo/app.example.test/shared/laravel_app/storage/app/private' 'Shared target must resolve below shared root.'
Assert-Equal $plan.environment.sharedStorage.directories[0].releaseLinkAbsolutePath '/var/www/demo/app.example.test/laravel_app/storage/app/private' 'Release link must resolve below application directory before release binding.'
Assert-True ('laravel_app/storage/app/private/**' -in @($manifest.classification.persistentData)) 'Manifest persistentData must include the shared storage boundary.'
$remoteRootChangedPlan = New-ExecutionPlan -Analysis $analysis -Manifest $manifest -RemoteTarget (New-TestRemoteTarget -RemoteRoot '/var/www/other' -ApplicationPath 'app.example.test' -TargetId 'staging')
$applicationPathChangedPlan = New-ExecutionPlan -Analysis $analysis -Manifest $manifest -RemoteTarget (New-TestRemoteTarget -RemoteRoot '/var/www/demo' -ApplicationPath 'other.example.test' -TargetId 'staging')
$targetIdChangedPlan = New-ExecutionPlan -Analysis $analysis -Manifest $manifest -RemoteTarget (New-TestRemoteTarget -RemoteRoot '/var/www/demo' -ApplicationPath 'app.example.test' -TargetId 'production')
$remoteDirectoryChangedPlan = New-ExecutionPlan -Analysis $analysis -Manifest $manifest -RemoteTarget ([pscustomobject]@{
    schemaVersion = '0.1'
    targetId = 'staging'
    targetConfigurationPath = 'D:\Targets\staging.json'
    logicalServerRoot = 'deployment-target'
    remoteRoot = '/var/www/demo'
    applicationPath = 'app.example.test'
    applicationRemoteDirectory = '/var/www/demo/manual-different'
    resolution = 'test-manual-difference'
})
Assert-True ($remoteRootChangedPlan.executionPlanFingerprint -ne $plan.executionPlanFingerprint) 'Changing remoteRoot must change executionPlanFingerprint.'
Assert-True ($applicationPathChangedPlan.executionPlanFingerprint -ne $plan.executionPlanFingerprint) 'Changing applicationPath must change executionPlanFingerprint.'
Assert-True ($targetIdChangedPlan.executionPlanFingerprint -ne $plan.executionPlanFingerprint) 'Changing targetId must change executionPlanFingerprint.'
Assert-True ($remoteDirectoryChangedPlan.executionPlanFingerprint -ne $plan.executionPlanFingerprint) 'Changing applicationRemoteDirectory must change executionPlanFingerprint.'
$sharedRootChangedManifest = New-TestManifest
$sharedRootChangedManifest.sharedStorage.root = 'other-shared'
$sharedRootChangedPlan = New-ExecutionPlan -Analysis $analysis -Manifest $sharedRootChangedManifest -RemoteTarget $remoteTarget
Assert-True ($sharedRootChangedPlan.executionPlanFingerprint -ne $plan.executionPlanFingerprint) 'Changing shared storage contract must change executionPlanFingerprint.'

foreach ($badSharedPath in @('', '/absolute', '.', '..', 'laravel_app/../storage', 'laravel_app//storage')) {
    $badManifest = New-TestManifest
    $badManifest.sharedStorage.directories[0].sharedPath = $badSharedPath
    try {
        [void] (New-ExecutionPlan -Analysis $analysis -Manifest $badManifest -RemoteTarget $remoteTarget)
        $script:failures.Add("Invalid sharedPath must be rejected: '$badSharedPath'")
    } catch {
        Assert-True ($_.Exception.Message -match 'sharedPath|relative|empty|segments|traversal') "Invalid sharedPath must produce controlled error: '$badSharedPath'"
    }
}

foreach ($badReleaseLinkPath in @('', '/absolute', '.', '..', 'laravel_app/../storage', 'laravel_app//storage')) {
    $badManifest = New-TestManifest
    $badManifest.sharedStorage.directories[0].releaseLinkPath = $badReleaseLinkPath
    try {
        [void] (New-ExecutionPlan -Analysis $analysis -Manifest $badManifest -RemoteTarget $remoteTarget)
        $script:failures.Add("Invalid releaseLinkPath must be rejected: '$badReleaseLinkPath'")
    } catch {
        Assert-True ($_.Exception.Message -match 'releaseLinkPath|relative|empty|segments|traversal') "Invalid releaseLinkPath must produce controlled error: '$badReleaseLinkPath'"
    }
}

$missingSharedRoot = New-TestManifest
$missingSharedRoot.sharedStorage.root = ''
try {
    [void] (New-ExecutionPlan -Analysis $analysis -Manifest $missingSharedRoot -RemoteTarget $remoteTarget)
    $script:failures.Add('Missing shared storage root must be rejected.')
} catch {
    Assert-True ($_.Exception.Message -match 'Shared storage.*root') 'Missing shared storage root must produce controlled error.'
}

$duplicateShared = New-TestManifest
$duplicateShared.sharedStorage.directories += ($duplicateShared.sharedStorage.directories[0] | ConvertTo-Json -Depth 10 | ConvertFrom-Json)
try {
    [void] (New-ExecutionPlan -Analysis $analysis -Manifest $duplicateShared -RemoteTarget $remoteTarget)
    $script:failures.Add('Duplicate shared storage entry must be rejected.')
} catch {
    Assert-True ($_.Exception.Message -match 'duplicate') 'Duplicate shared storage entry must produce controlled error.'
}

$badKind = New-TestManifest
$badKind.sharedStorage.directories[0].pathKind = 'folder'
try {
    [void] (New-ExecutionPlan -Analysis $analysis -Manifest $badKind -RemoteTarget $remoteTarget)
    $script:failures.Add('Unsupported shared storage pathKind must be rejected.')
} catch {
    Assert-True ($_.Exception.Message -match 'pathKind') 'Unsupported shared storage pathKind must produce controlled error.'
}

$badConflict = New-TestManifest
$badConflict.sharedStorage.directories[0].conflictPolicy = 'replace'
try {
    [void] (New-ExecutionPlan -Analysis $analysis -Manifest $badConflict -RemoteTarget $remoteTarget)
    $script:failures.Add('Unsupported shared storage conflict policy must be rejected.')
} catch {
    Assert-True ($_.Exception.Message -match 'conflictPolicy') 'Unsupported shared storage conflict policy must produce controlled error.'
}

$badInitialization = New-TestManifest
$badInitialization.sharedStorage.directories[0].initializationPolicy = 'copy-from-release'
try {
    [void] (New-ExecutionPlan -Analysis $analysis -Manifest $badInitialization -RemoteTarget $remoteTarget)
    $script:failures.Add('Unsupported shared storage initialization policy must be rejected.')
} catch {
    Assert-True ($_.Exception.Message -match 'initializationPolicy') 'Unsupported shared storage initialization policy must produce controlled error.'
}
$stepIds = @($plan.steps | ForEach-Object { $_.id })
$existingStepIds = @(
    'preconditions.analysis-review',
    'environment.review',
    'environment.protected-files-review',
    'local.frontend-build.prepare',
    'local.deployment-package.prepare',
    'runtime.transfer.review',
    'runtime.cleanup.review',
    'remote.dependencies.composer-install',
    'database.seeders.review',
    'remote.migrations.execute',
    'remote.runtime.cache-clear',
    'deployment.verification.remote-about',
    'deployment-marker.update'
)
foreach ($existingStepId in $existingStepIds) {
    Assert-True ($stepIds -contains $existingStepId) "Existing step id must remain present: $existingStepId"
}
Assert-True ([array]::IndexOf($stepIds, 'remote.migrations.status') -lt [array]::IndexOf($stepIds, 'remote.migrations.execute')) 'Migration status must be ordered before migration execution.'
Assert-Equal (Get-Step -Plan $plan -Id 'remote.dependencies.composer-install').required $false 'Composer step must be skipped when composer install is not required.'
Assert-Equal (Get-Step -Plan $plan -Id 'local.frontend-build.prepare').required $true 'Frontend build step must be required.'
Assert-Equal (Get-Step -Plan $plan -Id 'environment.review').executionMode 'review' 'Environment changes must create a review gate.'
Assert-Equal (Get-Step -Plan $plan -Id 'environment.review').status 'waiting-for-review' 'Environment review gate must pause.'
$environmentStep = Get-Step -Plan $plan -Id 'environment.review'
Assert-True (@($environmentStep.instructions.displayedInformation.keyAssessments).Count -gt 0) 'Environment review must include key assessments.'
Assert-True (@($environmentStep.instructions.displayedInformation.unknownKeys) -contains 'NEW_KEY') 'Environment review must include unknown keys.'
Assert-True $environmentStep.continuation.blocksAutomaticContinuation 'Unknown environment keys must block automatic continuation.'

$seederStep = Get-Step -Plan $plan -Id 'database.seeders.review'
Assert-Equal $seederStep.executionMode 'review' 'Seeder changes must create a review step.'
Assert-Equal $seederStep.status 'blocked' 'Seeder review must wait behind earlier review gates.'
Assert-True $seederStep.approvalRequired 'Seeder review must require approval.'
Assert-True ($seederStep.instructions.automaticExecutionAllowed -eq $false) 'Seeder review must not allow automatic execution.'
Assert-True (@($seederStep.instructions.changedSeeders).Count -eq 1) 'Seeder review must list changed seeders.'
Assert-True (-not (Test-PropertyValue -Object $seederStep.instructions -Name 'command')) 'Seeder review must not contain a command.'
Assert-True ([string]::IsNullOrWhiteSpace([string] $seederStep.capabilityId)) 'Seeder review must not contain a capability.'

$migrationStep = Get-Step -Plan $plan -Id 'remote.migrations.execute'
$unresolvedMigrationStep = Get-Step -Plan $unresolvedPlan -Id 'remote.migrations.execute'
Assert-Equal $unresolvedMigrationStep.capabilityId 'artisan.migrate' 'Builder must emit migration capability id.'
Assert-Equal $unresolvedMigrationStep.instructions.capabilityId 'artisan.migrate' 'Builder instructions must carry migration capability id.'
Assert-True (-not (Test-PropertyValue -Object $unresolvedMigrationStep.instructions -Name 'command')) 'Unresolved builder output must not contain a shell command.'
Assert-True (-not (Test-PropertyValue -Object $unresolvedMigrationStep.instructions -Name 'displayCommand')) 'Unresolved builder output must not contain a display command.'
Assert-Equal $migrationStep.executionMode 'human' 'Migration step must be a human gate.'
Assert-Equal $migrationStep.status 'blocked' 'Migration step must remain blocked while earlier review gates are open.'
Assert-Equal $migrationStep.instructions.command 'php artisan migrate --force' 'Migration command must be complete.'
Assert-Equal $migrationStep.instructions.displayCommand 'php artisan migrate --force' 'Resolver must add display command.'
Assert-Equal $migrationStep.instructions.workingDirectory '/var/www/demo/app.example.test' 'Migration working directory must be displayed.'
Assert-Equal $migrationStep.riskLevel 'high' 'Migration execution must be marked high risk.'
Assert-True $migrationStep.approvalRequired 'Migration execution must require approval.'
Assert-True $migrationStep.validation.requiresOutput 'Migration validation must require output.'
Assert-True $migrationStep.validation.ambiguousWithoutSuccessMatch 'Missing positive migration evidence must be ambiguous.'

$migrationOnlyPlan = New-ExecutionPlan -Analysis (New-TestAnalysis -RuntimeDeploymentRequired $false -FrontendBuildRequired $false -MigrationsRequired $true -EnvironmentReviewRequired $false -SeederReviewRequired $false -CleanupRequired $false) -Manifest $manifest -RemoteTarget $remoteTarget
$migrationSafetyStep = Get-Step -Plan $migrationOnlyPlan -Id 'remote.migrations.safety-review'
$migrationStatusStep = Get-Step -Plan $migrationOnlyPlan -Id 'remote.migrations.status'
$waitingMigrationStep = Get-Step -Plan $migrationOnlyPlan -Id 'remote.migrations.execute'
Assert-Equal $migrationSafetyStep.status 'waiting-for-review' 'Migration safety review must be the first active migration gate.'
Assert-Equal $migrationSafetyStep.riskLevel 'high' 'Migration safety review must be high risk.'
Assert-True $migrationSafetyStep.approvalRequired 'Migration safety review must require explicit approval.'
Assert-True $migrationSafetyStep.instructions.backupRequired 'Migration safety review must require backup confirmation.'
Assert-True (@($migrationSafetyStep.instructions.affectedMigrationFiles) -contains 'laravel_app/database/migrations/2026_01_01_000000_demo.php') 'Migration safety review must list affected migration files.'
Assert-Equal $migrationStatusStep.instructions.command 'php artisan migrate:status' 'Migration status command must be present before migrate.'
Assert-Equal $migrationStatusStep.capabilityId 'artisan.migrate.status' 'Migration status must use its own capability.'
Assert-Equal $migrationStatusStep.riskLevel 'high' 'Migration status step must be high risk.'
Assert-True $migrationStatusStep.approvalRequired 'Migration status step must require approval.'
Assert-Equal $waitingMigrationStep.status 'blocked' 'Migration execution must remain blocked by safety review and status check.'

$cleanupStep = Get-Step -Plan $plan -Id 'runtime.cleanup.review'
Assert-Equal $cleanupStep.destructive $true 'Cleanup must be marked destructive.'
Assert-True (@($cleanupStep.instructions.affectedPaths) -contains 'laravel_app/app/OldController.php') 'Cleanup must list affected runtime paths.'
Assert-True ($cleanupStep.approvalRequired) 'Cleanup must require explicit approval.'
Assert-True (-not (Test-PropertyValue -Object $cleanupStep.instructions -Name 'command')) 'Cleanup review must not generate a delete command.'

$verificationStep = Get-Step -Plan $plan -Id 'deployment.verification.remote-about'
Assert-Equal $verificationStep.executionMode 'human' 'Deployment verification must be a human gate.'
Assert-True $verificationStep.validation.verificationCommandRequired 'Deployment verification must mark verification command requirement.'

Assert-Equal (Test-ManualStepOutput -Step $waitingMigrationStep -Output 'Migrated: 2026_01_01_000000_demo' -ExitCode 0) 'completed' 'Successful output must classify as completed.'
Assert-Equal (Test-ManualStepOutput -Step $waitingMigrationStep -Output 'SQLSTATE[HY000]: Migration failed' -ExitCode 0) 'failed' 'Failure pattern must classify as failed.'
Assert-Equal (Test-ManualStepOutput -Step $waitingMigrationStep -Output 'Command produced neutral output' -ExitCode 0) 'ambiguous' 'Missing success pattern must classify as ambiguous.'
Assert-Equal (Test-ManualStepOutput -Step $waitingMigrationStep -Output '' -ExitCode 0) 'incomplete' 'Missing required output must classify as incomplete.'
Assert-Equal (Test-ManualStepOutput -Step $waitingMigrationStep -Output 'erledigt' -ExitCode 0) 'incomplete' 'Pure user confirmation must not be accepted.'

foreach ($forbiddenCommand in @('php artisan migrate:fresh', 'php artisan migrate:refresh', 'php artisan migrate:reset', 'php artisan migrate:rollback', 'php artisan db:wipe')) {
    try {
        Assert-DeploymentCommandAllowed -Command $forbiddenCommand
        $script:failures.Add("Forbidden Artisan command must be rejected: $forbiddenCommand")
    } catch {
        Assert-True ($_.Exception.Message -match 'Forbidden deployment command rejected') "Forbidden command must produce a controlled error: $forbiddenCommand"
    }
}

try {
    $badPlan = New-UnresolvedExecutionPlan -Analysis $analysis -Manifest $manifest -RemoteTarget $remoteTarget
    $badStep = Get-Step -Plan $badPlan -Id 'remote.migrations.execute'
    $badStep.capabilityId = 'unknown.capability'
    $badStep.instructions.capabilityId = 'unknown.capability'
    [void] (Resolve-DeploymentCapabilities -Plan $badPlan)
    $script:failures.Add('Unknown capability id must be rejected.')
} catch {
    Assert-True ($_.Exception.Message -match 'Unknown deployment capability') 'Unknown capability must produce a controlled error.'
}

$resolvedStatusStep = Get-Step -Plan $plan -Id 'remote.migrations.status'
Assert-Equal $resolvedStatusStep.executionMode 'human' 'Resolver must apply capability execution mode.'
Assert-Equal $resolvedStatusStep.riskLevel 'high' 'Resolver must apply capability risk level.'
Assert-True $resolvedStatusStep.approvalRequired 'Resolver must apply capability approval flag.'
Assert-True $resolvedStatusStep.validation.requiresOutput 'Resolver must apply capability validation rules.'

$backupCapabilityTruePlan = New-UnresolvedExecutionPlan -Analysis $analysis -Manifest $manifest -RemoteTarget $remoteTarget
$backupCapabilityTrueStep = Get-Step -Plan $backupCapabilityTruePlan -Id 'remote.migrations.status'
Add-Member -InputObject $backupCapabilityTrueStep.instructions -MemberType NoteProperty -Name 'requiresBackupConfirmation' -Value $false
$resolvedBackupCapabilityTruePlan = Resolve-DeploymentCapabilities -Plan $backupCapabilityTruePlan
$resolvedBackupCapabilityTrueStep = Get-Step -Plan $resolvedBackupCapabilityTruePlan -Id 'remote.migrations.status'
Assert-True $resolvedBackupCapabilityTrueStep.instructions.requiresBackupConfirmation 'Capability backup requirement true must not be lowered by builder false.'

$backupBuilderTruePlan = New-UnresolvedExecutionPlan -Analysis $analysis -Manifest $manifest -RemoteTarget $remoteTarget
$backupBuilderTrueStep = Get-Step -Plan $backupBuilderTruePlan -Id 'deployment.verification.remote-about'
Add-Member -InputObject $backupBuilderTrueStep.instructions -MemberType NoteProperty -Name 'requiresBackupConfirmation' -Value $true
$resolvedBackupBuilderTruePlan = Resolve-DeploymentCapabilities -Plan $backupBuilderTruePlan
$resolvedBackupBuilderTrueStep = Get-Step -Plan $resolvedBackupBuilderTruePlan -Id 'deployment.verification.remote-about'
Assert-True $resolvedBackupBuilderTrueStep.instructions.requiresBackupConfirmation 'Builder backup requirement true must be preserved when capability is false.'

$mergePlan = New-UnresolvedExecutionPlan -Analysis $analysis -Manifest $manifest -RemoteTarget $remoteTarget
$mergeStep = Get-Step -Plan $mergePlan -Id 'remote.migrations.execute'
$mergeStep.validation = [pscustomobject]@{
    requiresOutput = $false
    requiresExitCode = $true
    successPatterns = @('Migrated:', 'Custom success')
    failurePatterns = @('SQLSTATE', 'error')
    ambiguousWithoutSuccessMatch = $false
    verificationCommandRequired = $true
    requiredResponse = 'Exit-Code und betroffene Migrationen'
}
$mergeStep.continuation = [pscustomobject]@{
    allowedStatusesForDependents = @('completed')
    blocksAutomaticContinuation = $false
    requiredUserAction = 'Zusatzfreigabe pruefen'
}
$resolvedMergePlan = Resolve-DeploymentCapabilities -Plan $mergePlan
$resolvedMergeStep = Get-Step -Plan $resolvedMergePlan -Id 'remote.migrations.execute'
Assert-True $resolvedMergeStep.validation.requiresOutput 'Validation boolean merge must preserve capability requiresOutput.'
Assert-True $resolvedMergeStep.validation.requiresExitCode 'Validation boolean merge must include stricter builder requiresExitCode.'
Assert-True $resolvedMergeStep.validation.verificationCommandRequired 'Validation boolean merge must include stricter builder verification command requirement.'
Assert-Equal ($resolvedMergeStep.validation.failurePatterns -join ',') 'ERROR,Exception,Migration failed,SQLSTATE' 'Failure patterns must merge capability-first and deduplicate case-insensitively.'
Assert-Equal ($resolvedMergeStep.validation.successPatterns -join ',') 'Migrated:,Nothing to migrate,Custom success' 'Success patterns must merge capability-first and deduplicate.'
Assert-True ($resolvedMergeStep.validation.requiredResponse -match 'Vollstaendige relevante Konsolenausgabe') 'Required response must retain capability response.'
Assert-True ($resolvedMergeStep.validation.requiredResponse -match 'Exit-Code und betroffene Migrationen') 'Required response must include builder response.'
Assert-Equal ($resolvedMergeStep.continuation.allowedStatusesForDependents -join ',') 'completed' 'Continuation statuses must use intersection.'
Assert-True $resolvedMergeStep.continuation.blocksAutomaticContinuation 'Continuation boolean merge must preserve capability blocking.'
Assert-True ($resolvedMergeStep.continuation.requiredUserAction -match 'Der Prozess wartet') 'Required user action must retain capability action.'
Assert-True ($resolvedMergeStep.continuation.requiredUserAction -match 'Zusatzfreigabe pruefen') 'Required user action must include builder action.'

try {
    $badContinuationPlan = New-UnresolvedExecutionPlan -Analysis $analysis -Manifest $manifest -RemoteTarget $remoteTarget
    $badContinuationStep = Get-Step -Plan $badContinuationPlan -Id 'remote.migrations.execute'
    $badContinuationStep.continuation = [pscustomobject]@{
        allowedStatusesForDependents = @('failed')
        blocksAutomaticContinuation = $false
        requiredUserAction = ''
    }
    [void] (Resolve-DeploymentCapabilities -Plan $badContinuationPlan)
    $script:failures.Add('Empty continuation status intersection must be rejected.')
} catch {
    Assert-True ($_.Exception.Message -match 'no compatible allowed statuses') 'Empty continuation status intersection must produce a controlled error.'
}

try {
    $modeConflictPlan = New-UnresolvedExecutionPlan -Analysis $analysis -Manifest $manifest -RemoteTarget $remoteTarget
    $modeConflictStep = Get-Step -Plan $modeConflictPlan -Id 'remote.migrations.execute'
    $modeConflictStep.executionMode = 'agent'
    [void] (Resolve-DeploymentCapabilities -Plan $modeConflictPlan)
    $script:failures.Add('Execution mode conflict must be rejected.')
} catch {
    Assert-True ($_.Exception.Message -match 'Execution mode conflict') 'Execution mode conflict must produce a controlled error.'
}

try {
    $idConflictPlan = New-UnresolvedExecutionPlan -Analysis $analysis -Manifest $manifest -RemoteTarget $remoteTarget
    $idConflictStep = Get-Step -Plan $idConflictPlan -Id 'remote.migrations.execute'
    $idConflictStep.instructions.capabilityId = 'artisan.about'
    [void] (Resolve-DeploymentCapabilities -Plan $idConflictPlan)
    $script:failures.Add('Capability id mismatch must be rejected.')
} catch {
    Assert-True ($_.Exception.Message -match 'Capability id mismatch') 'Capability id mismatch must produce a controlled error.'
}

$weakenedPlan = New-UnresolvedExecutionPlan -Analysis $analysis -Manifest $manifest -RemoteTarget $remoteTarget
$weakenedStep = Get-Step -Plan $weakenedPlan -Id 'remote.migrations.status'
$weakenedStep.riskLevel = 'low'
$weakenedStep.approvalRequired = $false
$resolvedWeakenedPlan = Resolve-DeploymentCapabilities -Plan $weakenedPlan
$resolvedWeakenedStep = Get-Step -Plan $resolvedWeakenedPlan -Id 'remote.migrations.status'
Assert-Equal $resolvedWeakenedStep.riskLevel 'high' 'Resolver must not let builder lower capability risk level.'
Assert-True $resolvedWeakenedStep.approvalRequired 'Resolver must not let builder lower capability approval requirement.'

$protectedPlan = New-ExecutionPlan -Analysis (New-TestAnalysis -ProtectedFileReviewRequired $true) -Manifest $manifest -RemoteTarget $remoteTarget
$protectedStep = Get-Step -Plan $protectedPlan -Id 'environment.protected-files-review'
Assert-Equal $protectedStep.executionMode 'review' 'Protected files must create a review gate.'
Assert-Equal $protectedStep.status 'waiting-for-review' 'Protected file review must block continuation.'
Assert-True (@($protectedStep.instructions.affectedPaths) -contains 'laravel_app/public/.htaccess') 'Protected review must list affected paths.'

$documentationPlan = New-ExecutionPlan -Analysis (New-TestAnalysis -RuntimeDeploymentRequired $false -FrontendBuildRequired $false -MigrationsRequired $false -EnvironmentReviewRequired $false -CleanupRequired $false -DocumentationOnly $true) -Manifest $manifest -RemoteTarget $remoteTarget
Assert-Equal (Get-Step -Plan $documentationPlan -Id 'runtime.transfer.review').required $false 'Documentation-only analysis must skip runtime transfer.'
Assert-Equal (Get-Step -Plan $documentationPlan -Id 'deployment-marker.update').status 'skipped' 'Documentation-only analysis must skip marker update.'

$blockedPlan = New-ExecutionPlan -Analysis (New-TestAnalysis -Blockers @('Baseline commit is not an ancestor of the target commit.')) -Manifest $manifest -RemoteTarget $remoteTarget
Assert-Equal $blockedPlan.blocked $true 'Analyzer blockers must block the plan.'
Assert-Equal (Get-Step -Plan $blockedPlan -Id 'preconditions.analysis-review').status 'blocked' 'Blockers must not become normal executable steps.'

try {
    $invalidVersion = New-TestAnalysis
    $invalidVersion.engineVersion = '9.9'
    [void] (New-ExecutionPlan -Analysis $invalidVersion -Manifest $manifest -RemoteTarget $remoteTarget)
    $script:failures.Add('Unknown analysis version must be rejected.')
} catch {
    Assert-True ($_.Exception.Message -match 'Unsupported analysis version') 'Unknown analysis version must produce a controlled error.'
}

try {
    $invalidManifest = New-TestManifest
    $invalidManifest.deployment.serverRoot = ''
    [void] (New-ExecutionPlan -Analysis $analysis -Manifest $invalidManifest -RemoteTarget $remoteTarget)
    $script:failures.Add('Invalid manifest must be rejected.')
} catch {
    Assert-True ($_.Exception.Message -match 'Manifest validation failed') 'Invalid manifest must produce a controlled error.'
}

if ($script:failures.Count -gt 0) {
    Write-Host 'Execution Plan Builder tests failed:'
    $script:failures | ForEach-Object { Write-Host "- $_" }
    throw 'Execution Plan Builder tests failed.'
}

Write-Host 'Execution Plan Builder tests passed.'
