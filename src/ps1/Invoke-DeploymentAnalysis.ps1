[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $ProjectManifestPath,

    [string] $BaselineCommit,

    [string] $TargetCommit = 'HEAD',

    [string] $OutputPath,

    [switch] $ModuleOnly
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

function Read-RepositoryFileAtCommit {
    param(
        [Parameter(Mandatory = $true)][string] $RepositoryRoot,
        [Parameter(Mandatory = $true)][string] $Commit,
        [Parameter(Mandatory = $true)][string] $RepositoryPath
    )
    $content = & git -C $RepositoryRoot show "${Commit}:$RepositoryPath" 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    return ($content -join "`n")
}

function Test-ObjectProperty {
    param([object] $Object, [Parameter(Mandatory = $true)][string] $Name)
    return ($null -ne $Object -and $Object.PSObject.Properties.Name -contains $Name)
}

function Assert-ManifestBoolean {
    param([object] $Object, [string] $Name, [string] $Context)
    if (-not (Test-ObjectProperty -Object $Object -Name $Name) -or -not ($Object.$Name -is [bool])) {
        throw "Manifest validation failed: $Context.$Name must be boolean."
    }
}

function Get-EnvironmentManagementContract {
    param([Parameter(Mandatory = $true)][object] $Manifest)
    $allowedStrategies = @('review', 'prompt-if-missing', 'generate-remote-if-missing', 'keep-existing')
    if (-not (Test-ObjectProperty -Object $Manifest -Name 'environmentManagement') -or $null -eq $Manifest.environmentManagement) {
        return [pscustomobject]@{
            contractFile = 'laravel_app/.env.example'
            unknownKeyPolicy = 'review'
            keys = @{}
            issues = @()
        }
    }

    $management = $Manifest.environmentManagement
    $contractFile = if ((Test-ObjectProperty -Object $management -Name 'contractFile') -and -not [string]::IsNullOrWhiteSpace([string] $management.contractFile)) { ConvertTo-RepositoryPath ([string] $management.contractFile) } else { 'laravel_app/.env.example' }
    $unknownKeyPolicy = if ((Test-ObjectProperty -Object $management -Name 'unknownKeyPolicy') -and -not [string]::IsNullOrWhiteSpace([string] $management.unknownKeyPolicy)) { [string] $management.unknownKeyPolicy } else { 'review' }
    $rules = @{}
    $issues = New-Object System.Collections.Generic.List[object]
    if (-not (Test-ObjectProperty -Object $management -Name 'keys') -or $null -eq $management.keys) {
        return [pscustomobject]@{ contractFile = $contractFile; unknownKeyPolicy = $unknownKeyPolicy; keys = $rules; issues = @($issues.ToArray()) }
    }

    if ($management.keys -is [array]) {
        $seen = @{}
        foreach ($entry in @($management.keys)) {
            if (-not (Test-ObjectProperty -Object $entry -Name 'key') -or [string]::IsNullOrWhiteSpace([string] $entry.key)) {
                throw 'Manifest validation failed: environmentManagement keys must not contain empty key names.'
            }
            $keyName = [string] $entry.key
            if ($seen.ContainsKey($keyName)) { throw "Manifest validation failed: duplicate environmentManagement key '$keyName'." }
            $seen[$keyName] = $true
            $rules[$keyName] = $entry
        }
    } else {
        foreach ($property in $management.keys.PSObject.Properties) {
            if ([string]::IsNullOrWhiteSpace([string] $property.Name)) { throw 'Manifest validation failed: environmentManagement keys must not contain empty key names.' }
            $rules[[string] $property.Name] = $property.Value
        }
    }

    foreach ($keyName in @($rules.Keys | Sort-Object)) {
        $rule = $rules[$keyName]
        foreach ($field in @('strategy', 'secret', 'overwrite', 'required')) {
            if (-not (Test-ObjectProperty -Object $rule -Name $field)) { throw "Manifest validation failed: environmentManagement key '$keyName' is missing required field '$field'." }
        }
        $strategy = [string] $rule.strategy
        if ($strategy -notin $allowedStrategies) { throw "Manifest validation failed: unknown environment strategy '$strategy' for key '$keyName'." }
        Assert-ManifestBoolean -Object $rule -Name 'secret' -Context "environmentManagement key '$keyName'"
        Assert-ManifestBoolean -Object $rule -Name 'overwrite' -Context "environmentManagement key '$keyName'"
        Assert-ManifestBoolean -Object $rule -Name 'required' -Context "environmentManagement key '$keyName'"
        if ([bool] $rule.secret -and (Test-ObjectProperty -Object $rule -Name 'suggestedValue')) { throw "Manifest validation failed: secret environment key '$keyName' must not define suggestedValue." }
        if ([bool] $rule.secret -and (Test-ObjectProperty -Object $rule -Name 'value')) { throw "Manifest validation failed: secret environment key '$keyName' must not define concrete values." }
        if ($strategy -eq 'generate-remote-if-missing' -and [bool] $rule.overwrite) { throw "Manifest validation failed: generate-remote-if-missing must not use overwrite=true for key '$keyName'." }
        if ((Test-ObjectProperty -Object $rule -Name 'validationPattern') -and -not [string]::IsNullOrWhiteSpace([string] $rule.validationPattern)) {
            try { [void] [regex]::new([string] $rule.validationPattern) } catch { throw "Manifest validation failed: invalid validationPattern for environment key '$keyName'." }
        }
    }

    return [pscustomobject]@{
        contractFile = $contractFile
        unknownKeyPolicy = $unknownKeyPolicy
        keys = $rules
        issues = @($issues.ToArray())
    }
}

function Get-EnvironmentRecommendedAction {
    param([string] $Strategy, [string] $ChangeType)
    if ($ChangeType -eq 'removed') { return 'review-removal' }
    switch ($Strategy) {
        'generate-remote-if-missing' { return 'generate-on-target-if-missing' }
        'prompt-if-missing' { return 'prompt-for-target-value-if-missing' }
        'keep-existing' { return 'keep-existing-target-value' }
        'review' { return 'review-target-environment' }
        default { return 'add-manifest-rule' }
    }
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

    try {
        $manifest = Get-Content -LiteralPath $manifestPathResolved -Raw | ConvertFrom-Json
    } catch {
        throw "Manifest validation failed: invalid JSON in '$manifestPathResolved'. $($_.Exception.Message)"
    }

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

    [void] (Get-EnvironmentManagementContract -Manifest $manifest)

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
        [object[]] $ChangedFiles,

        [Parameter(Mandatory = $true)]
        [object] $Manifest
    )

    $contract = Get-EnvironmentManagementContract -Manifest $Manifest
    $envPath = [string] $contract.contractFile
    $envChanged = @($ChangedFiles | Where-Object { $_.path -eq $envPath -or $_.previousPath -eq $envPath }).Count -gt 0
    $baselineEnvKeys = Get-EnvKeysAtCommit -RepositoryRoot $RepositoryRoot -Commit $BaselineCommit -RepositoryPath $envPath
    $targetEnvKeys = Get-EnvKeysAtCommit -RepositoryRoot $RepositoryRoot -Commit $TargetCommit -RepositoryPath $envPath
    $addedEnvKeys = @($targetEnvKeys | Where-Object { $_ -notin $baselineEnvKeys })
    $removedEnvKeys = @($baselineEnvKeys | Where-Object { $_ -notin $targetEnvKeys })
    $assessments = New-Object System.Collections.Generic.List[object]
    $unknownKeys = New-Object System.Collections.Generic.List[string]

    foreach ($key in @($addedEnvKeys | Sort-Object)) {
        if ($contract.keys.ContainsKey($key)) {
            $rule = $contract.keys[$key]
            $assessments.Add([pscustomobject]@{
                key = $key
                changeType = 'added'
                contractStatus = 'configured'
                strategy = [string] $rule.strategy
                secret = [bool] $rule.secret
                overwrite = [bool] $rule.overwrite
                required = [bool] $rule.required
                recommendedAction = Get-EnvironmentRecommendedAction -Strategy ([string] $rule.strategy) -ChangeType 'added'
                executionAllowed = $false
                reviewRequired = $true
            })
        } else {
            $unknownKeys.Add($key)
            $assessments.Add([pscustomobject]@{
                key = $key
                changeType = 'added'
                contractStatus = 'missing-rule'
                strategy = $null
                secret = $null
                overwrite = $null
                required = $null
                recommendedAction = 'add-manifest-rule'
                executionAllowed = $false
                reviewRequired = $true
            })
        }
    }

    foreach ($key in @($removedEnvKeys | Sort-Object)) {
        $configured = $contract.keys.ContainsKey($key)
        $rule = if ($configured) { $contract.keys[$key] } else { $null }
        $assessments.Add([pscustomobject]@{
            key = $key
            changeType = 'removed'
            contractStatus = if ($configured) { 'review-required' } else { 'missing-rule' }
            strategy = if ($configured) { [string] $rule.strategy } else { $null }
            secret = if ($configured) { [bool] $rule.secret } else { $null }
            overwrite = if ($configured) { [bool] $rule.overwrite } else { $null }
            required = if ($configured) { [bool] $rule.required } else { $null }
            recommendedAction = 'review-removal'
            executionAllowed = $false
            reviewRequired = $true
        })
    }

    return [pscustomobject]@{
        path = $envPath
        changed = $envChanged
        baselineKeys = $baselineEnvKeys
        targetKeys = $targetEnvKeys
        addedKeys = $addedEnvKeys
        removedKeys = $removedEnvKeys
        keyAssessments = @($assessments | Sort-Object key, changeType)
        unknownKeys = @($unknownKeys | Sort-Object -Unique)
        contractIssues = @($contract.issues)
    }
}

function Get-SeederChangeType {
    param([string] $Status)
    if ($Status -like 'R*') { return 'renamed' }
    switch ($Status.Substring(0, 1)) {
        'A' { return 'added' }
        'D' { return 'deleted' }
        default { return 'modified' }
    }
}

function Get-RegexMatches {
    param([string] $Text, [string] $Pattern)
    if ([string]::IsNullOrEmpty($Text)) { return @() }
    return @([regex]::Matches($Text, $Pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase) | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
}

function Get-SeederFileReview {
    param(
        [Parameter(Mandatory = $true)][object] $File,
        [string] $BaselineContent,
        [string] $TargetContent
    )
    $path = [string] $File.path
    $status = [string] $File.status
    $changeType = Get-SeederChangeType -Status $status
    $content = if ($changeType -eq 'deleted') { [string] $BaselineContent } else { [string] $TargetContent }
    $writePatterns = @('updateOrCreate', 'firstOrCreate', 'firstOrNew', 'forceCreate', 'create', 'insert', 'upsert', 'update', 'save', 'forceDelete', 'delete', 'destroy', 'truncate')
    $writeOperations = @($writePatterns | Where-Object { $content -match "(?i)(::|->)\s*$($_)\s*\(" } | Sort-Object -Unique)
    $dbOperations = @('DB::table', 'DB::statement', 'DB::insert', 'DB::update', 'DB::delete') | Where-Object { $content -match [regex]::Escape($_) }
    foreach ($operation in $dbOperations) {
        $operationName = ($operation -replace 'DB::', 'DB::')
        if ($writeOperations -notcontains $operationName) { $writeOperations += $operationName }
    }
    $destructive = @()
    foreach ($pattern in @('truncate', 'forceDelete', 'delete', 'destroy', 'DROP TABLE', 'TRUNCATE TABLE', 'DELETE FROM')) {
        if ($content -match "(?i)$([regex]::Escape($pattern))") { $destructive += $pattern }
    }
    $models = New-Object System.Collections.Generic.List[string]
    foreach ($model in @(Get-RegexMatches -Text $content -Pattern 'use\s+App\\Models\\([A-Za-z_][A-Za-z0-9_]*)\s*;')) { $models.Add($model) }
    foreach ($model in @(Get-RegexMatches -Text $content -Pattern '\b([A-Z][A-Za-z0-9_]*)::\s*(?:updateOrCreate|firstOrCreate|firstOrNew|forceCreate|create|insert|upsert|update|delete|destroy)\s*\(')) { $models.Add($model) }
    $tables = New-Object System.Collections.Generic.List[string]
    foreach ($table in @(Get-RegexMatches -Text $content -Pattern "DB::table\s*\(\s*['""]([^'""]+)['""]")) { $tables.Add($table) }
    foreach ($table in @(Get-RegexMatches -Text $content -Pattern "(?:FROM|INTO|UPDATE|TABLE)\s+`?([A-Za-z_][A-Za-z0-9_]*)`?")) { $tables.Add($table) }
    $callsSeeders = ($content -match '\$this->call\s*\(')
    $isDatabaseSeeder = ([System.IO.Path]::GetFileName($path) -eq 'DatabaseSeeder.php')

    $idempotency = if ($changeType -eq 'deleted') { 'not-applicable' } elseif (@($destructive).Count -gt 0) { 'unlikely' } elseif (@($writeOperations | Where-Object { $_ -in @('updateOrCreate', 'firstOrCreate', 'upsert') }).Count -gt 0) { 'likely' } elseif (@($writeOperations | Where-Object { $_ -in @('create', 'insert', 'forceCreate') }).Count -gt 0) { 'uncertain' } else { 'uncertain' }
    $purpose = 'unknown'
    $confidence = 'low'
    if ($callsSeeders -or $isDatabaseSeeder) { $purpose = 'orchestrator'; $confidence = 'medium' }
    elseif (@($destructive).Count -gt 0) { $purpose = 'data-migration'; $confidence = 'medium' }
    elseif (@($models).Count -gt 0 -or @($tables).Count -gt 0) { $purpose = 'reference-data'; $confidence = 'medium' }
    if ($content -match '(?i)(factory\(|faker|fake\()') { $purpose = 'development-seeder'; $confidence = 'medium' }

    $risk = if (@($destructive).Count -gt 0 -or ($callsSeeders -and $content -notmatch '::class')) { 'high' } elseif (@($writeOperations).Count -gt 0) { 'medium' } else { 'low' }
    $evidence = New-Object System.Collections.Generic.List[string]
    foreach ($operation in @($writeOperations | Sort-Object -Unique)) { $evidence.Add("Uses $operation") }
    foreach ($model in @($models | Sort-Object -Unique)) { $evidence.Add("References App\Models\$model") }
    foreach ($table in @($tables | Sort-Object -Unique)) { $evidence.Add("References table $table") }
    if ($callsSeeders) { $evidence.Add('Calls other seeders') }
    if (@($destructive).Count -gt 0) { $evidence.Add('Contains destructive operation pattern') }
    $recommendations = @('Review changed seeders before deployment.', 'Do not execute automatically.')
    if ($risk -eq 'high') { $recommendations += 'High-risk seeder change requires explicit database-impact review.' }

    return [pscustomobject]@{
        path = $path
        previousPath = $File.previousPath
        status = $status
        changeType = $changeType
        probablePurpose = $purpose
        affectedModels = @($models | Sort-Object -Unique)
        affectedTables = @($tables | Sort-Object -Unique)
        destructiveOperations = @($destructive | Sort-Object -Unique)
        writeOperations = @($writeOperations | Sort-Object -Unique)
        probableIdempotency = $idempotency
        riskLevel = $risk
        confidence = $confidence
        reviewRequired = $true
        recommendations = @($recommendations | Sort-Object -Unique)
        evidence = @($evidence | Sort-Object -Unique)
    }
}

function Get-SeederReviewAnalysis {
    param(
        [Parameter(Mandatory = $true)][string] $RepositoryRoot,
        [Parameter(Mandatory = $true)][string] $BaselineCommit,
        [Parameter(Mandatory = $true)][string] $TargetCommit,
        [Parameter(Mandatory = $true)][object[]] $ClassifiedFiles
    )
    $seederFiles = @($ClassifiedFiles | Where-Object { $_.classes -contains 'seeders' } | Sort-Object path)
    $reviews = @(
        foreach ($file in $seederFiles) {
            $baselinePath = if ($null -ne $file.previousPath -and -not [string]::IsNullOrWhiteSpace([string] $file.previousPath)) { [string] $file.previousPath } else { [string] $file.path }
            $baselineContent = Read-RepositoryFileAtCommit -RepositoryRoot $RepositoryRoot -Commit $BaselineCommit -RepositoryPath $baselinePath
            $targetContent = Read-RepositoryFileAtCommit -RepositoryRoot $RepositoryRoot -Commit $TargetCommit -RepositoryPath ([string] $file.path)
            Get-SeederFileReview -File $file -BaselineContent $baselineContent -TargetContent $targetContent
        }
    )
    $summary = [pscustomobject]@{
        total = @($reviews).Count
        added = @($reviews | Where-Object { $_.changeType -eq 'added' }).Count
        modified = @($reviews | Where-Object { $_.changeType -eq 'modified' -or $_.changeType -eq 'renamed' }).Count
        deleted = @($reviews | Where-Object { $_.changeType -eq 'deleted' }).Count
        highRisk = @($reviews | Where-Object { $_.riskLevel -eq 'high' }).Count
        reviewRequired = (@($reviews).Count -gt 0)
    }
    return [pscustomobject]@{
        changed = (@($reviews).Count -gt 0)
        files = @($reviews)
        summary = $summary
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
        [object] $EnvironmentAnalysis,

        [Parameter(Mandatory = $true)]
        [object] $SeederReview
    )

    function Test-AnyConfiguredPathPattern {
        param([string] $Path, [object] $Patterns)
        $configuredPatterns = @(Get-StringArray $Patterns)
        if ($configuredPatterns.Count -eq 0) { return $false }
        return Test-PathPattern -Path $Path -Patterns $configuredPatterns
    }

    $composerInstallRequired = @($ChangedFiles | Where-Object { Test-AnyConfiguredPathPattern -Path $_.path -Patterns $Manifest.rules.composerTrigger }).Count -gt 0
    $frontendBuildRequired = @($ChangedFiles | Where-Object { Test-AnyConfiguredPathPattern -Path $_.path -Patterns $Manifest.rules.frontendBuildTrigger }).Count -gt 0
    $migrationsRequired = @($ChangedFiles | Where-Object { Test-AnyConfiguredPathPattern -Path $_.path -Patterns $Manifest.rules.migrationTrigger }).Count -gt 0
    $environmentReviewRequired = $EnvironmentAnalysis.changed -or $EnvironmentAnalysis.addedKeys.Count -gt 0 -or $EnvironmentAnalysis.removedKeys.Count -gt 0 -or $EnvironmentAnalysis.unknownKeys.Count -gt 0 -or $EnvironmentAnalysis.contractIssues.Count -gt 0
    $cleanupRequired = @($ChangedFiles | Where-Object { $_.status -eq 'D' -and (Test-AnyConfiguredPathPattern -Path $_.path -Patterns $Manifest.rules.cleanupTrigger) }).Count -gt 0
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
        environmentContractIncomplete = ($EnvironmentAnalysis.unknownKeys.Count -gt 0 -or $EnvironmentAnalysis.contractIssues.Count -gt 0)
        seederReviewRequired = [bool] $SeederReview.summary.reviewRequired
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
    if ((Test-ObjectProperty -Object $Decisions -Name 'seederReviewRequired') -and $Decisions.seederReviewRequired) {
        $manualApprovalPoints.Add('Changed seeders require static human review and must never be executed automatically.')
    }

    return ,$manualApprovalPoints.ToArray()
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
        [object] $SeederReview,

        [Parameter(Mandatory = $true)]
        [object] $Decisions,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
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
            keyAssessments = $EnvironmentAnalysis.keyAssessments
            unknownKeys = $EnvironmentAnalysis.unknownKeys
            contractIssues = $EnvironmentAnalysis.contractIssues
        }
        seederReview = $SeederReview
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

    Write-Host ''
    Write-Host 'Environment contract:'
    Write-Host "- Added keys: $(@($Plan.environmentChanges.addedKeys).Count)"
    Write-Host "- Removed keys: $(@($Plan.environmentChanges.removedKeys).Count)"
    Write-Host "- Configured keys: $(@($Plan.environmentChanges.keyAssessments | Where-Object { $_.contractStatus -eq 'configured' }).Count)"
    Write-Host "- Unknown keys: $(@($Plan.environmentChanges.unknownKeys).Count)"
    Write-Host "- Review required: $(if ($Plan.decisions.environmentReviewRequired) { 'yes' } else { 'no' })"

    Write-Host ''
    Write-Host 'Seeder review:'
    Write-Host "- Changed seeders: $($Plan.seederReview.summary.total)"
    Write-Host "- High risk: $($Plan.seederReview.summary.highRisk)"
    Write-Host "- Probable reference data: $(@($Plan.seederReview.files | Where-Object { $_.probablePurpose -eq 'reference-data' }).Count)"
    Write-Host "- Unknown purpose: $(@($Plan.seederReview.files | Where-Object { $_.probablePurpose -eq 'unknown' }).Count)"
    Write-Host '- Automatic execution: never'

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
    $environmentAnalysis = Get-EnvironmentContractAnalysis -RepositoryRoot $repositoryAnalysis.repositoryRoot -BaselineCommit $repositoryAnalysis.baselineCommit -TargetCommit $repositoryAnalysis.targetCommit -ChangedFiles $changedFiles -Manifest $manifest
    $seederReview = Get-SeederReviewAnalysis -RepositoryRoot $repositoryAnalysis.repositoryRoot -BaselineCommit $repositoryAnalysis.baselineCommit -TargetCommit $repositoryAnalysis.targetCommit -ClassifiedFiles $classifiedFiles
    $decisions = Get-DeploymentDecisions -Manifest $manifest -ChangedFiles $changedFiles -ClassifiedFiles $classifiedFiles -EnvironmentAnalysis $environmentAnalysis -SeederReview $seederReview
    $manualApprovalPoints = Get-ManualApprovalPoints -Decisions $decisions

    return New-DeploymentPlan `
        -EngineVersion $EngineVersion `
        -Manifest $manifest `
        -ProjectContext $projectContext `
        -RepositoryAnalysis $repositoryAnalysis `
        -ChangedFiles $changedFiles `
        -ClassifiedFiles $classifiedFiles `
        -EnvironmentAnalysis $environmentAnalysis `
        -SeederReview $seederReview `
        -Decisions $decisions `
        -ManualApprovalPoints $manualApprovalPoints
}

if (-not $ModuleOnly) {
    $plan = Invoke-DeploymentAnalysisPipeline `
        -ProjectManifestPath $ProjectManifestPath `
        -BaselineCommit $BaselineCommit `
        -TargetCommit $TargetCommit `
        -EngineVersion $engineVersion

    Write-DeploymentSummary -Plan $plan
    Write-DeploymentPlanJson -Plan $plan -Path $OutputPath
}
