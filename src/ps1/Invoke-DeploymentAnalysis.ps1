[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $ProjectManifestPath,

    [string] $BaselineCommit,

    [string] $TargetCommit = 'HEAD',

    [string] $OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$engineVersion = '0.1'

function Resolve-LocalPath {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,

        [string] $BasePath
    )

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    if ([string]::IsNullOrWhiteSpace($BasePath)) {
        $BasePath = (Get-Location).Path
    }

    return [System.IO.Path]::GetFullPath((Join-Path -Path $BasePath -ChildPath $Path))
}

function ConvertTo-RepositoryPath {
    param([Parameter(Mandatory = $true)][string] $Path)
    return ($Path -replace '\\', '/').TrimStart('/')
}

function Convert-GlobToRegex {
    param([Parameter(Mandatory = $true)][string] $Pattern)

    $normalized = ConvertTo-RepositoryPath $Pattern
    $builder = [System.Text.StringBuilder]::new()
    [void] $builder.Append('^')

    for ($i = 0; $i -lt $normalized.Length; $i++) {
        $char = $normalized[$i]

        if ($char -eq '*') {
            if (($i + 1) -lt $normalized.Length -and $normalized[$i + 1] -eq '*') {
                [void] $builder.Append('.*')
                $i++
            } else {
                [void] $builder.Append('[^/]*')
            }
            continue
        }

        if ($char -eq '?') {
            [void] $builder.Append('[^/]')
            continue
        }

        [void] $builder.Append([regex]::Escape([string] $char))
    }

    [void] $builder.Append('$')
    return $builder.ToString()
}

function Test-PathPattern {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,

        [Parameter(Mandatory = $true)]
        [string[]] $Patterns
    )

    $normalizedPath = ConvertTo-RepositoryPath $Path

    foreach ($pattern in $Patterns) {
        $regex = Convert-GlobToRegex $pattern
        if ($normalizedPath -match $regex) {
            return $true
        }
    }

    return $false
}

function Get-StringArray {
    param($Value)

    if ($null -eq $Value) {
        return @()
    }

    return @($Value | ForEach-Object { [string] $_ })
}

function Assert-RequiredValue {
    param(
        [Parameter(Mandatory = $true)]
        [object] $Object,

        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    $current = $Object
    foreach ($part in $Path.Split('.')) {
        if ($null -eq $current -or -not ($current.PSObject.Properties.Name -contains $part)) {
            throw "Manifest validation failed: missing required field '$Path'."
        }
        $current = $current.$part
    }

    if ($null -eq $current -or ([string] $current).Trim().Length -eq 0) {
        throw "Manifest validation failed: required field '$Path' is empty."
    }
}

function Invoke-Git {
    param(
        [Parameter(Mandatory = $true)]
        [string] $RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [string[]] $Arguments
    )

    $output = & git -C $RepositoryRoot @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Git command failed: git -C '$RepositoryRoot' $($Arguments -join ' ')`n$output"
    }
    return $output
}

function Resolve-GitCommit {
    param(
        [Parameter(Mandatory = $true)]
        [string] $RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [string] $Commitish
    )

    $resolved = Invoke-Git -RepositoryRoot $RepositoryRoot -Arguments @('rev-parse', '--verify', "$Commitish^{commit}")
    return [string] ($resolved | Select-Object -First 1)
}

function Read-MarkerCommit {
    param(
        [Parameter(Mandatory = $true)]
        [string] $MarkerPath
    )

    if (-not (Test-Path -LiteralPath $MarkerPath -PathType Leaf)) {
        throw "BaselineCommit was not provided and marker file '$MarkerPath' does not exist."
    }

    $content = Get-Content -LiteralPath $MarkerPath -ErrorAction Stop
    foreach ($line in $content) {
        if ($line -match '^\s*commit\s*=\s*(?<commit>[0-9a-fA-F]{7,40})\s*$') {
            return $Matches.commit
        }
        if ($line -match '^\s*(?<commit>[0-9a-fA-F]{7,40})\s*$') {
            return $Matches.commit
        }
    }

    throw "Marker file '$MarkerPath' does not contain a readable commit."
}

function Get-EnvKeysAtCommit {
    param(
        [Parameter(Mandatory = $true)]
        [string] $RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [string] $Commit,

        [Parameter(Mandatory = $true)]
        [string] $RepositoryPath
    )

    $content = & git -C $RepositoryRoot show "${Commit}:$RepositoryPath" 2>$null
    if ($LASTEXITCODE -ne 0) {
        return @()
    }

    $keys = New-Object System.Collections.Generic.List[string]
    foreach ($line in $content) {
        if ($line -match '^\s*(?<key>[A-Za-z_][A-Za-z0-9_]*)\s*=') {
            $keys.Add($Matches.key)
        }
    }

    return $keys | Sort-Object -Unique
}

function Convert-NameStatusLine {
    param([Parameter(Mandatory = $true)][string] $Line)

    $parts = $Line -split "`t"
    if ($parts.Count -lt 2) {
        throw "Unexpected git diff --name-status line: '$Line'"
    }

    $status = $parts[0]
    if ($status -like 'R*' -or $status -like 'C*') {
        return [pscustomobject]@{
            status = $status
            path = ConvertTo-RepositoryPath $parts[2]
            previousPath = ConvertTo-RepositoryPath $parts[1]
        }
    }

    return [pscustomobject]@{
        status = $status
        path = ConvertTo-RepositoryPath $parts[1]
        previousPath = $null
    }
}

function Get-Classification {
    param(
        [Parameter(Mandatory = $true)]
        [object] $Manifest,

        [Parameter(Mandatory = $true)]
        [string] $Path,

        [string] $Status
    )

    $classes = New-Object System.Collections.Generic.List[string]

    foreach ($property in $Manifest.classification.PSObject.Properties) {
        $patterns = @(Get-StringArray $property.Value)
        if ($patterns.Count -gt 0 -and (Test-PathPattern -Path $Path -Patterns $patterns)) {
            $classes.Add($property.Name)
        }
    }

    if (Test-PathPattern -Path $Path -Patterns (Get-StringArray $Manifest.protection.neverOverwrite)) {
        if (-not $classes.Contains('protected-server-file')) {
            $classes.Add('protected-server-file')
        }
    }

    if (Test-PathPattern -Path $Path -Patterns (Get-StringArray $Manifest.protection.neverUpload)) {
        if (-not $classes.Contains('ignored')) {
            $classes.Add('ignored')
        }
    }

    if ($Status -eq 'D') {
        $classes.Add('deletion')
    }

    if ($classes.Count -eq 0) {
        $classes.Add('unclassified')
    }

    return $classes.ToArray()
}

function Read-DeploymentManifest {
    param([Parameter(Mandatory = $true)][string] $Path)

    $manifestPathResolved = Resolve-LocalPath -Path $Path
    if (-not (Test-Path -LiteralPath $manifestPathResolved -PathType Leaf)) {
        throw "Project manifest not found: $manifestPathResolved"
    }

    $manifest = Get-Content -LiteralPath $manifestPathResolved -Raw | ConvertFrom-Json

    @(
        'schemaVersion',
        'project.id',
        'project.name',
        'project.root',
        'project.applicationRoot',
        'project.type',
        'repository.branch',
        'deployment.environment',
        'deployment.serverRoot',
        'deployment.markerFile',
        'protection.neverUpload',
        'protection.neverOverwrite',
        'classification.documentation',
        'classification.backendRuntime',
        'classification.frontendSource',
        'classification.frontendBuild',
        'classification.phpDependencies',
        'classification.frontendDependencies',
        'classification.migrations',
        'classification.seeders',
        'classification.environmentContract',
        'classification.ignored',
        'rules.composerTrigger',
        'rules.frontendBuildTrigger',
        'rules.migrationTrigger',
        'rules.environmentTrigger',
        'rules.cleanupTrigger'
    ) | ForEach-Object { Assert-RequiredValue -Object $manifest -Path $_ }

    return [pscustomobject]@{
        path = $manifestPathResolved
        manifest = $manifest
    }
}

function Resolve-DeploymentProjectContext {
    param(
        [Parameter(Mandatory = $true)]
        [object] $ManifestResult
    )

    $manifest = $ManifestResult.manifest
    $projectRoot = Resolve-LocalPath -Path $manifest.project.root
    $applicationRoot = Resolve-LocalPath -Path $manifest.project.applicationRoot -BasePath $projectRoot
    $markerFile = Resolve-LocalPath -Path $manifest.deployment.markerFile -BasePath $projectRoot

    if (-not (Test-Path -LiteralPath $projectRoot -PathType Container)) {
        throw "Project root does not exist: $projectRoot"
    }

    if (-not (Test-Path -LiteralPath $applicationRoot -PathType Container)) {
        throw "Application root does not exist: $applicationRoot"
    }

    return [pscustomobject]@{
        manifestPath = $ManifestResult.path
        projectRoot = $projectRoot
        applicationRoot = $applicationRoot
        markerFile = $markerFile
    }
}

function Get-RepositoryAnalysis {
    param(
        [Parameter(Mandatory = $true)]
        [object] $ProjectContext,

        [string] $BaselineCommit,

        [Parameter(Mandatory = $true)]
        [string] $TargetCommit
    )

    $repositoryRoot = Invoke-Git -RepositoryRoot $ProjectContext.projectRoot -Arguments @('rev-parse', '--show-toplevel')
    $repositoryRoot = [System.IO.Path]::GetFullPath([string] ($repositoryRoot | Select-Object -First 1))
    if ($repositoryRoot.TrimEnd('\', '/') -ne $ProjectContext.projectRoot.TrimEnd('\', '/')) {
        throw "Project root is not the Git repository root. Project root: '$($ProjectContext.projectRoot)'. Git root: '$repositoryRoot'."
    }

    $warnings = New-Object System.Collections.Generic.List[string]
    $blockers = New-Object System.Collections.Generic.List[string]

    $statusLines = @(Invoke-Git -RepositoryRoot $ProjectContext.projectRoot -Arguments @('status', '--porcelain'))
    $repositoryClean = ($statusLines.Count -eq 0)
    if (-not $repositoryClean) {
        $warnings.Add('Git working tree is not clean.')
    }

    $targetCommitResolved = Resolve-GitCommit -RepositoryRoot $ProjectContext.projectRoot -Commitish $TargetCommit

    if ([string]::IsNullOrWhiteSpace($BaselineCommit)) {
        $BaselineCommit = Read-MarkerCommit -MarkerPath $ProjectContext.markerFile
    }
    $baselineCommitResolved = Resolve-GitCommit -RepositoryRoot $ProjectContext.projectRoot -Commitish $BaselineCommit

    & git -C $ProjectContext.projectRoot merge-base --is-ancestor $baselineCommitResolved $targetCommitResolved
    $baselineIsAncestor = ($LASTEXITCODE -eq 0)
    if (-not $baselineIsAncestor) {
        $blockers.Add('Baseline commit is not an ancestor of the target commit.')
    }

    $commitsSinceBaseline = [int] (Invoke-Git -RepositoryRoot $ProjectContext.projectRoot -Arguments @('rev-list', '--count', "$baselineCommitResolved..$targetCommitResolved") | Select-Object -First 1)

    return [pscustomobject]@{
        repositoryRoot = $repositoryRoot
        repositoryClean = $repositoryClean
        statusLines = $statusLines
        baselineCommit = $baselineCommitResolved
        targetCommit = $targetCommitResolved
        baselineIsAncestor = $baselineIsAncestor
        commitsSinceBaseline = $commitsSinceBaseline
        warnings = $warnings.ToArray()
        blockers = $blockers.ToArray()
    }
}

function Get-ChangedArtifacts {
    param(
        [Parameter(Mandatory = $true)]
        [object] $RepositoryAnalysis
    )

    $diffLines = @(Invoke-Git -RepositoryRoot $RepositoryAnalysis.repositoryRoot -Arguments @('diff', '--name-status', '--find-renames', $RepositoryAnalysis.baselineCommit, $RepositoryAnalysis.targetCommit))
    return @($diffLines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { Convert-NameStatusLine -Line $_ })
}

function Get-ClassifiedArtifacts {
    param(
        [Parameter(Mandatory = $true)]
        [object] $Manifest,

        [Parameter(Mandatory = $true)]
        [object[]] $ChangedFiles
    )

    return @(
        foreach ($file in $ChangedFiles) {
            $classes = Get-Classification -Manifest $Manifest -Path $file.path -Status $file.status
            [pscustomobject]@{
                status = $file.status
                path = $file.path
                previousPath = $file.previousPath
                classes = $classes
            }
        }
    )
}

function Get-EnvironmentContractAnalysis {
    param(
        [Parameter(Mandatory = $true)]
        [string] $RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [string] $BaselineCommit,

        [Parameter(Mandatory = $true)]
        [string] $TargetCommit,

        [Parameter(Mandatory = $true)]
        [object[]] $ChangedFiles
    )

    $envPath = 'laravel_app/.env.example'
    $envChanged = @($ChangedFiles | Where-Object { $_.path -eq $envPath -or $_.previousPath -eq $envPath }).Count -gt 0
    $baselineEnvKeys = Get-EnvKeysAtCommit -RepositoryRoot $RepositoryRoot -Commit $BaselineCommit -RepositoryPath $envPath
    $targetEnvKeys = Get-EnvKeysAtCommit -RepositoryRoot $RepositoryRoot -Commit $TargetCommit -RepositoryPath $envPath
    $addedEnvKeys = @($targetEnvKeys | Where-Object { $_ -notin $baselineEnvKeys })
    $removedEnvKeys = @($baselineEnvKeys | Where-Object { $_ -notin $targetEnvKeys })

    return [pscustomobject]@{
        path = $envPath
        changed = $envChanged
        baselineKeys = $baselineEnvKeys
        targetKeys = $targetEnvKeys
        addedKeys = $addedEnvKeys
        removedKeys = $removedEnvKeys
    }
}

function Get-DeploymentDecisions {
    param(
        [Parameter(Mandatory = $true)]
        [object] $Manifest,

        [Parameter(Mandatory = $true)]
        [object[]] $ChangedFiles,

        [Parameter(Mandatory = $true)]
        [object[]] $ClassifiedFiles,

        [Parameter(Mandatory = $true)]
        [object] $EnvironmentAnalysis
    )

    $composerInstallRequired = @($ChangedFiles | Where-Object { Test-PathPattern -Path $_.path -Patterns @(Get-StringArray $Manifest.rules.composerTrigger) }).Count -gt 0
    $frontendBuildRequired = @($ChangedFiles | Where-Object { Test-PathPattern -Path $_.path -Patterns @(Get-StringArray $Manifest.rules.frontendBuildTrigger) }).Count -gt 0
    $migrationsRequired = @($ChangedFiles | Where-Object { Test-PathPattern -Path $_.path -Patterns @(Get-StringArray $Manifest.rules.migrationTrigger) }).Count -gt 0
    $environmentReviewRequired = $EnvironmentAnalysis.changed -or $EnvironmentAnalysis.addedKeys.Count -gt 0 -or $EnvironmentAnalysis.removedKeys.Count -gt 0
    $cleanupRequired = @($ChangedFiles | Where-Object { $_.status -eq 'D' -and (Test-PathPattern -Path $_.path -Patterns @(Get-StringArray $Manifest.rules.cleanupTrigger)) }).Count -gt 0
    $protectedFileReviewRequired = @($ClassifiedFiles | Where-Object { $_.classes -contains 'protected-server-file' }).Count -gt 0

    $runtimeClasses = @('backendRuntime', 'frontendBuild', 'phpDependencies', 'frontendDependencies', 'migrations', 'seeders', 'environmentContract')
    $runtimeDeploymentRequired = @($ClassifiedFiles | Where-Object {
            $intersection = @($_.classes | Where-Object { $_ -in $runtimeClasses })
            $intersection.Count -gt 0
        }).Count -gt 0

    $deploymentRelevant = @($ClassifiedFiles | Where-Object { $_.classes -notcontains 'ignored' })
    $documentationOnly = (
        $deploymentRelevant.Count -gt 0 -and
        (@($deploymentRelevant | Where-Object { $_.classes -notcontains 'documentation' }).Count -eq 0)
    )

    return [pscustomobject]@{
        runtimeDeploymentRequired = $runtimeDeploymentRequired
        frontendBuildRequired = $frontendBuildRequired
        composerInstallRequired = $composerInstallRequired
        migrationsRequired = $migrationsRequired
        environmentReviewRequired = $environmentReviewRequired
        cleanupRequired = $cleanupRequired
        protectedFileReviewRequired = $protectedFileReviewRequired
        documentationOnly = $documentationOnly
    }
}

function Get-ManualApprovalPoints {
    param(
        [Parameter(Mandatory = $true)]
        [object] $Decisions
    )

    $manualApprovalPoints = New-Object System.Collections.Generic.List[string]

    if ($Decisions.migrationsRequired) {
        $manualApprovalPoints.Add('Migration phase requires explicit approval.')
    }
    if ($Decisions.environmentReviewRequired) {
        $manualApprovalPoints.Add('Environment contract changes require manual review of target .env.')
    }
    if ($Decisions.cleanupRequired) {
        $manualApprovalPoints.Add('Runtime deletions require a controlled cleanup plan.')
    }
    if ($Decisions.protectedFileReviewRequired) {
        $manualApprovalPoints.Add('Protected server files require manual review and must not be overwritten automatically.')
    }

    return $manualApprovalPoints.ToArray()
}

function New-DeploymentPlan {
    param(
        [Parameter(Mandatory = $true)]
        [string] $EngineVersion,

        [Parameter(Mandatory = $true)]
        [object] $Manifest,

        [Parameter(Mandatory = $true)]
        [object] $ProjectContext,

        [Parameter(Mandatory = $true)]
        [object] $RepositoryAnalysis,

        [Parameter(Mandatory = $true)]
        [object[]] $ChangedFiles,

        [Parameter(Mandatory = $true)]
        [object[]] $ClassifiedFiles,

        [Parameter(Mandatory = $true)]
        [object] $EnvironmentAnalysis,

        [Parameter(Mandatory = $true)]
        [object] $Decisions,

        [Parameter(Mandatory = $true)]
        [string[]] $ManualApprovalPoints
    )

    return [pscustomobject]@{
        engineVersion = $EngineVersion
        generatedAt = (Get-Date).ToUniversalTime().ToString('o')
        project = [pscustomobject]@{
            id = $Manifest.project.id
            name = $Manifest.project.name
            root = $ProjectContext.projectRoot
            applicationRoot = $ProjectContext.applicationRoot
            type = $Manifest.project.type
        }
        environment = [pscustomobject]@{
            name = $Manifest.deployment.environment
            serverRoot = $Manifest.deployment.serverRoot
            markerFile = $Manifest.deployment.markerFile
        }
        baselineCommit = $RepositoryAnalysis.baselineCommit
        targetCommit = $RepositoryAnalysis.targetCommit
        branch = $Manifest.repository.branch
        repositoryClean = $RepositoryAnalysis.repositoryClean
        baselineIsAncestor = $RepositoryAnalysis.baselineIsAncestor
        commitsSinceBaseline = $RepositoryAnalysis.commitsSinceBaseline
        changedFiles = $ChangedFiles
        classifications = $ClassifiedFiles
        environmentChanges = [pscustomobject]@{
            path = $EnvironmentAnalysis.path
            changed = $EnvironmentAnalysis.changed
            addedKeys = $EnvironmentAnalysis.addedKeys
            removedKeys = $EnvironmentAnalysis.removedKeys
        }
        decisions = $Decisions
        warnings = $RepositoryAnalysis.warnings
        blockers = $RepositoryAnalysis.blockers
        manualApprovalPoints = $ManualApprovalPoints
    }
}

function Write-DeploymentSummary {
    param([Parameter(Mandatory = $true)][object] $Plan)

    Write-Host "SHK-MOMM Deployment Analysis v$($Plan.engineVersion)"
    Write-Host "Project: $($Plan.project.name) [$($Plan.environment.name)]"
    Write-Host "Baseline: $($Plan.baselineCommit)"
    Write-Host "Target:   $($Plan.targetCommit)"
    Write-Host "Changed files: $($Plan.changedFiles.Count)"
    Write-Host "Repository clean: $($Plan.repositoryClean)"
    Write-Host "Baseline is ancestor: $($Plan.baselineIsAncestor)"
    Write-Host ''
    Write-Host 'Decisions:'
    $Plan.decisions.PSObject.Properties | ForEach-Object {
        Write-Host ("- {0}: {1}" -f $_.Name, $_.Value)
    }

    if ($Plan.warnings.Count -gt 0) {
        Write-Host ''
        Write-Host 'Warnings:'
        $Plan.warnings | ForEach-Object { Write-Host "- $_" }
    }

    if ($Plan.blockers.Count -gt 0) {
        Write-Host ''
        Write-Host 'Blockers:'
        $Plan.blockers | ForEach-Object { Write-Host "- $_" }
    }

    if ($Plan.manualApprovalPoints.Count -gt 0) {
        Write-Host ''
        Write-Host 'Manual approval points:'
        $Plan.manualApprovalPoints | ForEach-Object { Write-Host "- $_" }
    }
}

function Write-DeploymentPlanJson {
    param(
        [Parameter(Mandatory = $true)]
        [object] $Plan,

        [string] $Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return
    }

    $outputPathResolved = Resolve-LocalPath -Path $Path
    $outputDirectory = Split-Path -Path $outputPathResolved -Parent
    if (-not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
        throw "Output directory does not exist: $outputDirectory"
    }

    $Plan | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $outputPathResolved -Encoding utf8
    Write-Host ''
    Write-Host "JSON plan written to: $outputPathResolved"
}

function Invoke-DeploymentAnalysisPipeline {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ProjectManifestPath,

        [string] $BaselineCommit,

        [Parameter(Mandatory = $true)]
        [string] $TargetCommit,

        [Parameter(Mandatory = $true)]
        [string] $EngineVersion
    )

    $manifestResult = Read-DeploymentManifest -Path $ProjectManifestPath
    $manifest = $manifestResult.manifest
    $projectContext = Resolve-DeploymentProjectContext -ManifestResult $manifestResult
    $repositoryAnalysis = Get-RepositoryAnalysis -ProjectContext $projectContext -BaselineCommit $BaselineCommit -TargetCommit $TargetCommit
    $changedFiles = Get-ChangedArtifacts -RepositoryAnalysis $repositoryAnalysis
    $classifiedFiles = Get-ClassifiedArtifacts -Manifest $manifest -ChangedFiles $changedFiles
    $environmentAnalysis = Get-EnvironmentContractAnalysis -RepositoryRoot $repositoryAnalysis.repositoryRoot -BaselineCommit $repositoryAnalysis.baselineCommit -TargetCommit $repositoryAnalysis.targetCommit -ChangedFiles $changedFiles
    $decisions = Get-DeploymentDecisions -Manifest $manifest -ChangedFiles $changedFiles -ClassifiedFiles $classifiedFiles -EnvironmentAnalysis $environmentAnalysis
    $manualApprovalPoints = Get-ManualApprovalPoints -Decisions $decisions

    return New-DeploymentPlan `
        -EngineVersion $EngineVersion `
        -Manifest $manifest `
        -ProjectContext $projectContext `
        -RepositoryAnalysis $repositoryAnalysis `
        -ChangedFiles $changedFiles `
        -ClassifiedFiles $classifiedFiles `
        -EnvironmentAnalysis $environmentAnalysis `
        -Decisions $decisions `
        -ManualApprovalPoints $manualApprovalPoints
}

$plan = Invoke-DeploymentAnalysisPipeline `
    -ProjectManifestPath $ProjectManifestPath `
    -BaselineCommit $BaselineCommit `
    -TargetCommit $TargetCommit `
    -EngineVersion $engineVersion

Write-DeploymentSummary -Plan $plan
Write-DeploymentPlanJson -Plan $plan -Path $OutputPath
