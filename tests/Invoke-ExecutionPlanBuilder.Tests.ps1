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
    "serverRoot": "/var/www/demo",
    "markerFile": ".deploy-version"
  },
  "protection": {
    "neverUpload": [".env", "storage/**", "vendor/**", "node_modules/**"],
    "neverOverwrite": [".env", ".deploy-version", "storage/**"]
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
    "removedKeys": []
  },
  "decisions": {
    "runtimeDeploymentRequired": true,
    "frontendBuildRequired": true,
    "composerInstallRequired": false,
    "migrationsRequired": true,
    "environmentReviewRequired": true,
    "cleanupRequired": true,
    "protectedFileReviewRequired": false,
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

function Get-Step {
    param([object] $Plan, [string] $Id)
    return @($Plan.steps | Where-Object { $_.id -eq $Id } | Select-Object -First 1)[0]
}

$manifest = New-TestManifest
$analysis = New-TestAnalysis
$plan = New-ExecutionPlan -Analysis $analysis -Manifest $manifest
$planJsonA = $plan | ConvertTo-Json -Depth 30
$planJsonB = (New-ExecutionPlan -Analysis $analysis -Manifest $manifest) | ConvertTo-Json -Depth 30

Assert-Equal $plan.blocked $false 'Empty blocker list must not block the plan.'
Assert-Equal ($plan.phases -join ',') 'preconditions,environment-review,local-frontend-build,local-deployment-preparation,runtime-file-transfer,runtime-cleanup,remote-dependency-installation,remote-migrations,remote-runtime-maintenance,deployment-verification,deployment-marker-update' 'Phase order must be stable.'
Assert-Equal $planJsonA $planJsonB 'Execution plan output must be deterministic.'
Assert-Equal $plan.steps[-1].id 'deployment-marker.update' 'Deployment marker update must be the final step.'
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

$migrationStep = Get-Step -Plan $plan -Id 'remote.migrations.execute'
Assert-Equal $migrationStep.executionMode 'human' 'Migration step must be a human gate.'
Assert-Equal $migrationStep.status 'blocked' 'Migration step must remain blocked while earlier review gates are open.'
Assert-Equal $migrationStep.instructions.command 'php artisan migrate --force' 'Migration command must be complete.'
Assert-Equal $migrationStep.instructions.workingDirectory '/var/www/demo/laravel_app' 'Migration working directory must be displayed.'
Assert-Equal $migrationStep.riskLevel 'high' 'Migration execution must be marked high risk.'
Assert-True $migrationStep.approvalRequired 'Migration execution must require approval.'
Assert-True $migrationStep.validation.requiresOutput 'Migration validation must require output.'
Assert-True $migrationStep.validation.ambiguousWithoutSuccessMatch 'Missing positive migration evidence must be ambiguous.'

$migrationOnlyPlan = New-ExecutionPlan -Analysis (New-TestAnalysis -RuntimeDeploymentRequired $false -FrontendBuildRequired $false -MigrationsRequired $true -EnvironmentReviewRequired $false -CleanupRequired $false) -Manifest $manifest
$migrationSafetyStep = Get-Step -Plan $migrationOnlyPlan -Id 'remote.migrations.safety-review'
$migrationStatusStep = Get-Step -Plan $migrationOnlyPlan -Id 'remote.migrations.status'
$waitingMigrationStep = Get-Step -Plan $migrationOnlyPlan -Id 'remote.migrations.execute'
Assert-Equal $migrationSafetyStep.status 'waiting-for-review' 'Migration safety review must be the first active migration gate.'
Assert-Equal $migrationSafetyStep.riskLevel 'high' 'Migration safety review must be high risk.'
Assert-True $migrationSafetyStep.approvalRequired 'Migration safety review must require explicit approval.'
Assert-True $migrationSafetyStep.instructions.backupRequired 'Migration safety review must require backup confirmation.'
Assert-True (@($migrationSafetyStep.instructions.affectedMigrationFiles) -contains 'laravel_app/database/migrations/2026_01_01_000000_demo.php') 'Migration safety review must list affected migration files.'
Assert-Equal $migrationStatusStep.instructions.command 'php artisan migrate:status' 'Migration status command must be present before migrate.'
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
        [void] (New-HumanCommandInstructions -Manifest $manifest -Command $forbiddenCommand -Purpose 'Forbidden' -ExpectedOutcome 'Forbidden')
        $script:failures.Add("Forbidden Artisan command must be rejected: $forbiddenCommand")
    } catch {
        Assert-True ($_.Exception.Message -match 'Forbidden deployment command rejected') "Forbidden command must produce a controlled error: $forbiddenCommand"
    }
}

$protectedPlan = New-ExecutionPlan -Analysis (New-TestAnalysis -ProtectedFileReviewRequired $true) -Manifest $manifest
$protectedStep = Get-Step -Plan $protectedPlan -Id 'environment.protected-files-review'
Assert-Equal $protectedStep.executionMode 'review' 'Protected files must create a review gate.'
Assert-Equal $protectedStep.status 'waiting-for-review' 'Protected file review must block continuation.'
Assert-True (@($protectedStep.instructions.affectedPaths) -contains 'laravel_app/public/.htaccess') 'Protected review must list affected paths.'

$documentationPlan = New-ExecutionPlan -Analysis (New-TestAnalysis -RuntimeDeploymentRequired $false -FrontendBuildRequired $false -MigrationsRequired $false -EnvironmentReviewRequired $false -CleanupRequired $false -DocumentationOnly $true) -Manifest $manifest
Assert-Equal (Get-Step -Plan $documentationPlan -Id 'runtime.transfer.review').required $false 'Documentation-only analysis must skip runtime transfer.'
Assert-Equal (Get-Step -Plan $documentationPlan -Id 'deployment-marker.update').status 'skipped' 'Documentation-only analysis must skip marker update.'

$blockedPlan = New-ExecutionPlan -Analysis (New-TestAnalysis -Blockers @('Baseline commit is not an ancestor of the target commit.')) -Manifest $manifest
Assert-Equal $blockedPlan.blocked $true 'Analyzer blockers must block the plan.'
Assert-Equal (Get-Step -Plan $blockedPlan -Id 'preconditions.analysis-review').status 'blocked' 'Blockers must not become normal executable steps.'

try {
    $invalidVersion = New-TestAnalysis
    $invalidVersion.engineVersion = '9.9'
    [void] (New-ExecutionPlan -Analysis $invalidVersion -Manifest $manifest)
    $script:failures.Add('Unknown analysis version must be rejected.')
} catch {
    Assert-True ($_.Exception.Message -match 'Unsupported analysis version') 'Unknown analysis version must produce a controlled error.'
}

try {
    $invalidManifest = New-TestManifest
    $invalidManifest.deployment.serverRoot = ''
    [void] (New-ExecutionPlan -Analysis $analysis -Manifest $invalidManifest)
    $script:failures.Add('Invalid manifest must be rejected.')
} catch {
    Assert-True ($_.Exception.Message -match 'Manifest validation failed') 'Invalid manifest must produce a controlled error.'
}

if ($script:failures.Count -gt 0) {
    Write-Host 'Execution Plan Builder tests failed:'
    $script:failures | ForEach-Object { Write-Host "- $_" }
    exit 1
}

Write-Host 'Execution Plan Builder tests passed.'
exit 0
