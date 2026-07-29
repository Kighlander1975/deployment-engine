[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:failures = New-Object System.Collections.Generic.List[string]
$script:assertionCount = 0
$engineRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '..'))
$catalogPath = Join-Path -Path $engineRoot -ChildPath 'src/ps1/ProjectCatalog/ProjectCatalog.ps1'
$cliPath = Join-Path -Path $engineRoot -ChildPath 'bin/deployment-engine.ps1'

. $catalogPath

function Add-Assertion { $script:assertionCount++ }
function Assert-True { param([bool] $Condition, [string] $Message) Add-Assertion; if (-not $Condition) { $script:failures.Add($Message) } }
function Assert-Equal { param($Actual, $Expected, [string] $Message) Add-Assertion; if ($Actual -ne $Expected) { $script:failures.Add("$Message Expected '$Expected', got '$Actual'.") } }
function Assert-NotEqual { param($Actual, $Expected, [string] $Message) Add-Assertion; if ($Actual -eq $Expected) { $script:failures.Add("$Message Value must not be '$Expected'.") } }
function Assert-ThrowsLike {
    param([scriptblock] $Script, [string] $Pattern, [string] $Message)
    Add-Assertion
    try { & $Script; $script:failures.Add($Message) } catch { Assert-True ($_.Exception.Message -match $Pattern) "$Message Actual error: $($_.Exception.Message)" }
}

function New-TestProjectManifest {
    param(
        [Parameter(Mandatory = $true)][string] $Id,
        [string] $Name = '',
        [string[]] $Aliases = @(),
        [Nullable[bool]] $Deployable = $null,
        [string] $ProjectRoot = ''
    )

    if ([string]::IsNullOrWhiteSpace($Name)) { $Name = "Project $Id" }
    $project = [ordered]@{
        id = $Id
        name = $Name
        root = $ProjectRoot
        applicationRoot = 'app'
        type = 'laravel'
    }
    if ($Aliases.Count -gt 0) { $project.aliases = @($Aliases) }
    if ($null -ne $Deployable) { $project.deployable = [bool] $Deployable }

    return [ordered]@{
        schemaVersion = '0.1'
        project = $project
        repository = [ordered]@{ branch = 'main' }
        deployment = [ordered]@{ environment = 'staging'; serverRoot = 'target'; markerFile = 'target/.deploy-version' }
        protection = [ordered]@{ neverUpload = @('.env'); neverOverwrite = @('.env') }
        classification = [ordered]@{
            documentation = @('*.md')
            backendRuntime = @('app/**')
            frontendSource = @()
            frontendBuild = @()
            phpDependencies = @()
            frontendDependencies = @()
            migrations = @()
            seeders = @()
            environmentContract = @('.env.example')
            ignored = @('.git/**')
        }
        rules = [ordered]@{
            composerTrigger = @()
            frontendBuildTrigger = @()
            migrationTrigger = @()
            environmentTrigger = @('.env.example')
            cleanupTrigger = @('app/**')
        }
    }
}

function Add-TestProject {
    param(
        [Parameter(Mandatory = $true)][string] $ProjectsRoot,
        [Parameter(Mandatory = $true)][string] $DirectoryName,
        [Parameter(Mandatory = $true)][string] $Id,
        [string] $Name = '',
        [string[]] $Aliases = @(),
        [Nullable[bool]] $Deployable = $null
    )

    $projectRoot = Join-Path -Path $ProjectsRoot -ChildPath $DirectoryName
    New-Item -ItemType Directory -Force -Path (Join-Path -Path $projectRoot -ChildPath 'app') | Out-Null
    $manifest = New-TestProjectManifest -Id $Id -Name $Name -Aliases $Aliases -Deployable $Deployable -ProjectRoot $projectRoot
    $manifest | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path -Path $projectRoot -ChildPath 'deployment.project.json') -Encoding UTF8
    return $projectRoot
}

function Add-RawManifestProject {
    param(
        [Parameter(Mandatory = $true)][string] $ProjectsRoot,
        [Parameter(Mandatory = $true)][string] $DirectoryName,
        [Parameter(Mandatory = $true)][string] $Content
    )

    $projectRoot = Join-Path -Path $ProjectsRoot -ChildPath $DirectoryName
    New-Item -ItemType Directory -Force -Path $projectRoot | Out-Null
    $Content | Set-Content -LiteralPath (Join-Path -Path $projectRoot -ChildPath 'deployment.project.json') -Encoding UTF8
    return $projectRoot
}

function New-ProjectsRoot {
    param([Parameter(Mandatory = $true)][string] $BasePath, [Parameter(Mandatory = $true)][string] $Name)
    $path = Join-Path -Path $BasePath -ChildPath $Name
    New-Item -ItemType Directory -Force -Path $path | Out-Null
    return $path
}

function Get-FileSnapshot {
    param([Parameter(Mandatory = $true)][string] $Root)
    return @(
        Get-ChildItem -LiteralPath $Root -File -Recurse -Force |
            Sort-Object FullName |
            ForEach-Object {
                [pscustomobject]@{
                    path = $_.FullName.Substring($Root.Length).TrimStart('\', '/')
                    hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
                }
            }
    ) | ConvertTo-Json -Depth 5 -Compress
}

$tmp = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('project-catalog-tests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    $emptyRoot = New-ProjectsRoot -BasePath $tmp -Name 'empty'
    $empty = New-ProjectCatalog -ProjectsRoot $emptyRoot
    Assert-Equal $empty.schemaVersion '0.1' 'Discovery schema version must be stable.'
    Assert-Equal $empty.operation 'project-discovery' 'Discovery operation must be explicit.'
    Assert-Equal $empty.status 'success' 'Empty ProjectsRoot must be a successful empty catalog.'
    Assert-Equal @($empty.projects).Count 0 'Empty ProjectsRoot must produce no projects.'

    $singleRoot = New-ProjectsRoot -BasePath $tmp -Name 'single'
    Add-TestProject -ProjectsRoot $singleRoot -DirectoryName 'alpha' -Id 'alpha-project' -Name 'Alpha Project' | Out-Null
    $singleBefore = Get-FileSnapshot -Root $singleRoot
    $single = New-ProjectCatalog -ProjectsRoot $singleRoot
    $singleAfter = Get-FileSnapshot -Root $singleRoot
    Assert-Equal @($single.projects).Count 1 'Exactly one valid project must be discovered.'
    Assert-Equal $single.projects[0].eligibility 'eligible' 'Missing project.deployable must default to eligible.'
    Assert-Equal $singleBefore $singleAfter 'Discovery must not modify files.'
    Assert-True (-not (($single | ConvertTo-Json -Depth 20) -match 'SECRET|TOKEN|PASSWORD')) 'Catalog output must not emit secret-like manifest content.'

    $multiRoot = New-ProjectsRoot -BasePath $tmp -Name 'multi'
    Add-TestProject -ProjectsRoot $multiRoot -DirectoryName 'zulu' -Id 'zulu-project' | Out-Null
    Add-TestProject -ProjectsRoot $multiRoot -DirectoryName 'alpha' -Id 'alpha-project' | Out-Null
    Add-TestProject -ProjectsRoot $multiRoot -DirectoryName 'bravo' -Id 'bravo-project' | Out-Null
    $multiA = New-ProjectCatalog -ProjectsRoot $multiRoot
    $multiB = New-ProjectCatalog -ProjectsRoot $multiRoot
    Assert-Equal (@($multiA.projects | ForEach-Object { $_.id }) -join ',') 'alpha-project,bravo-project,zulu-project' 'Projects must be sorted deterministically by normalized ID.'
    Assert-Equal (($multiA | ConvertTo-Json -Depth 20) -replace '\\\\project-catalog-tests-[^\\"]+', '<tmp>') (($multiB | ConvertTo-Json -Depth 20) -replace '\\\\project-catalog-tests-[^\\"]+', '<tmp>') 'Repeated discovery must produce equivalent JSON.'

    $invalidJsonRoot = New-ProjectsRoot -BasePath $tmp -Name 'invalid-json'
    Add-RawManifestProject -ProjectsRoot $invalidJsonRoot -DirectoryName 'bad' -Content '{ this is not json' | Out-Null
    Assert-Equal (New-ProjectCatalog -ProjectsRoot $invalidJsonRoot).projects[0].eligibility 'invalid-manifest' 'Invalid JSON must be invalid-manifest.'

    $schemaInvalidRoot = New-ProjectsRoot -BasePath $tmp -Name 'schema-invalid'
    Add-RawManifestProject -ProjectsRoot $schemaInvalidRoot -DirectoryName 'bad' -Content (@{ schemaVersion = '0.1'; project = @{ id = 'schema-bad'; name = 'Schema Bad' } } | ConvertTo-Json -Depth 10) | Out-Null
    Assert-Equal (New-ProjectCatalog -ProjectsRoot $schemaInvalidRoot).projects[0].eligibility 'invalid-manifest' 'Schema-invalid JSON must be invalid-manifest.'

    $sharedManifest = New-TestProjectManifest -Id 'shared-valid' -ProjectRoot (Join-Path $tmp 'shared-valid')
    $sharedManifest.sharedStorage = [ordered]@{
        root = 'shared'
        directories = @([ordered]@{
            sharedPath = 'laravel_app/storage/app/private'
            releaseLinkPath = 'laravel_app/storage/app/private'
            pathKind = 'directory'
            conflictPolicy = 'fail'
            initializationPolicy = 'explicit'
        })
        files = @()
    }
    Test-JsonAgainstProjectManifestSchema -Json ($sharedManifest | ConvertTo-Json -Depth 30)
    Assert-True $true 'Valid shared storage manifest must be schema-valid.'

    foreach ($case in @(
        [pscustomobject]@{ field = 'root'; value = ''; pattern = 'root' },
        [pscustomobject]@{ field = 'sharedPath'; value = '/absolute'; pattern = 'sharedPath' },
        [pscustomobject]@{ field = 'releaseLinkPath'; value = '/absolute'; pattern = 'releaseLinkPath' },
        [pscustomobject]@{ field = 'sharedPath'; value = 'laravel_app/../storage'; pattern = 'sharedPath' },
        [pscustomobject]@{ field = 'releaseLinkPath'; value = 'laravel_app/../storage'; pattern = 'releaseLinkPath' },
        [pscustomobject]@{ field = 'pathKind'; value = 'folder'; pattern = 'pathKind' },
        [pscustomobject]@{ field = 'conflictPolicy'; value = 'replace'; pattern = 'conflictPolicy' },
        [pscustomobject]@{ field = 'initializationPolicy'; value = 'copy-from-release'; pattern = 'initializationPolicy' }
    )) {
        $badSharedManifest = $sharedManifest | ConvertTo-Json -Depth 30 | ConvertFrom-Json
        if ($case.field -eq 'root') {
            $badSharedManifest.sharedStorage.root = $case.value
        } else {
            $badSharedManifest.sharedStorage.directories[0].PSObject.Properties[$case.field].Value = $case.value
        }
        Assert-ThrowsLike -Script { Test-JsonAgainstProjectManifestSchema -Json ($badSharedManifest | ConvertTo-Json -Depth 30) } -Pattern $case.pattern -Message "Invalid shared storage schema field must be rejected: $($case.field)"
    }

    $missingIdRoot = New-ProjectsRoot -BasePath $tmp -Name 'missing-id'
    $missingIdManifest = New-TestProjectManifest -Id 'temp' -ProjectRoot (Join-Path $missingIdRoot 'missing')
    $missingIdManifest.project.Remove('id')
    Add-RawManifestProject -ProjectsRoot $missingIdRoot -DirectoryName 'missing' -Content ($missingIdManifest | ConvertTo-Json -Depth 20) | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $missingIdRoot 'missing/app') | Out-Null
    Assert-Equal (New-ProjectCatalog -ProjectsRoot $missingIdRoot).projects[0].eligibility 'invalid-manifest' 'Missing project.id must be invalid-manifest.'

    $duplicateRoot = New-ProjectsRoot -BasePath $tmp -Name 'duplicate-id'
    Add-TestProject -ProjectsRoot $duplicateRoot -DirectoryName 'one' -Id 'same-id' | Out-Null
    Add-TestProject -ProjectsRoot $duplicateRoot -DirectoryName 'two' -Id 'same-id' | Out-Null
    Assert-Equal (@((New-ProjectCatalog -ProjectsRoot $duplicateRoot).projects | Where-Object { $_.eligibility -eq 'duplicate-id' }).Count) 2 'Duplicate project IDs must be marked duplicate-id.'

    $caseDuplicateRoot = New-ProjectsRoot -BasePath $tmp -Name 'case-duplicate-id'
    Add-TestProject -ProjectsRoot $caseDuplicateRoot -DirectoryName 'one' -Id 'Case-ID' | Out-Null
    Add-TestProject -ProjectsRoot $caseDuplicateRoot -DirectoryName 'two' -Id 'case-id' | Out-Null
    Assert-Equal (@((New-ProjectCatalog -ProjectsRoot $caseDuplicateRoot).projects | Where-Object { $_.eligibility -eq 'duplicate-id' }).Count) 2 'IDs differing only by case must be duplicate-id.'

    $aliasIdRoot = New-ProjectsRoot -BasePath $tmp -Name 'alias-id-conflict'
    Add-TestProject -ProjectsRoot $aliasIdRoot -DirectoryName 'one' -Id 'alpha' -Aliases @('beta') | Out-Null
    Add-TestProject -ProjectsRoot $aliasIdRoot -DirectoryName 'two' -Id 'beta' | Out-Null
    Assert-True (@((New-ProjectCatalog -ProjectsRoot $aliasIdRoot).projects | Where-Object { $_.eligibility -eq 'identifier-conflict' }).Count -ge 1) 'Alias colliding with foreign ID must be identifier-conflict.'

    $aliasAliasRoot = New-ProjectsRoot -BasePath $tmp -Name 'alias-alias-conflict'
    Add-TestProject -ProjectsRoot $aliasAliasRoot -DirectoryName 'one' -Id 'alpha' -Aliases @('shared') | Out-Null
    Add-TestProject -ProjectsRoot $aliasAliasRoot -DirectoryName 'two' -Id 'beta' -Aliases @('SHARED') | Out-Null
    Assert-Equal (@((New-ProjectCatalog -ProjectsRoot $aliasAliasRoot).projects | Where-Object { $_.eligibility -eq 'identifier-conflict' }).Count) 2 'Alias colliding with foreign alias must mark both projects.'

    $ownAliasRoot = New-ProjectsRoot -BasePath $tmp -Name 'own-alias-conflict'
    Add-TestProject -ProjectsRoot $ownAliasRoot -DirectoryName 'one' -Id 'alpha' -Aliases @('demo', 'DEMO') | Out-Null
    Assert-Equal (New-ProjectCatalog -ProjectsRoot $ownAliasRoot).projects[0].eligibility 'identifier-conflict' 'Aliases duplicated within one project case-insensitively must be identifier-conflict.'

    $ownIdAliasRoot = New-ProjectsRoot -BasePath $tmp -Name 'own-id-alias-conflict'
    Add-TestProject -ProjectsRoot $ownIdAliasRoot -DirectoryName 'one' -Id 'alpha' -Aliases @('ALPHA') | Out-Null
    $ownIdAliasCatalog = New-ProjectCatalog -ProjectsRoot $ownIdAliasRoot
    Assert-Equal $ownIdAliasCatalog.projects[0].eligibility 'identifier-conflict' 'Alias matching its own project.id case-insensitively must be identifier-conflict.'
    Assert-Equal (Resolve-DeploymentProject -ProjectsRoot $ownIdAliasRoot -ProjectIdentifier 'alpha').status 'identifier-conflict' 'Own ID/alias conflict must not become ambiguous or resolved.'

    $deployableRoot = New-ProjectsRoot -BasePath $tmp -Name 'deployable'
    Add-TestProject -ProjectsRoot $deployableRoot -DirectoryName 'off' -Id 'off' -Deployable $false | Out-Null
    Add-TestProject -ProjectsRoot $deployableRoot -DirectoryName 'on' -Id 'on' | Out-Null
    $deployableCatalog = New-ProjectCatalog -ProjectsRoot $deployableRoot
    Assert-Equal ((@($deployableCatalog.projects | Where-Object { $_.id -eq 'off' })[0]).eligibility) 'ineligible' 'project.deployable=false must be ineligible.'
    Assert-Equal ((@($deployableCatalog.projects | Where-Object { $_.id -eq 'on' })[0]).eligibility) 'eligible' 'Missing project.deployable must mean true.'

    $escapeRoot = New-ProjectsRoot -BasePath $tmp -Name 'escape'
    $outside = New-ProjectsRoot -BasePath $tmp -Name 'outside'
    Add-TestProject -ProjectsRoot $outside -DirectoryName 'outside-project' -Id 'outside-project' | Out-Null
    try {
        New-Item -ItemType Junction -Path (Join-Path $escapeRoot 'outside-link') -Target $outside | Out-Null
    } catch {
        throw "Reparse-point security test could not create required junction: $($_.Exception.Message)"
    }
    Assert-Equal @((New-ProjectCatalog -ProjectsRoot $escapeRoot).projects).Count 0 'Discovery must not follow a junction that leaves ProjectsRoot.'

    $rootTarget = New-ProjectsRoot -BasePath $tmp -Name 'root-target'
    Add-TestProject -ProjectsRoot $rootTarget -DirectoryName 'project' -Id 'root-target-project' | Out-Null
    $rootLink = Join-Path -Path $tmp -ChildPath 'root-link'
    New-Item -ItemType Junction -Path $rootLink -Target $rootTarget | Out-Null
    Assert-ThrowsLike -Script { New-ProjectCatalog -ProjectsRoot $rootLink | Out-Null } -Pattern 'reparse point' -Message 'ProjectsRoot itself must not be accepted as a reparse point.'

    $projectRootReparseRoot = New-ProjectsRoot -BasePath $tmp -Name 'project-root-reparse'
    $externalRoot = New-ProjectsRoot -BasePath $tmp -Name 'external-project-root'
    New-Item -ItemType Directory -Force -Path (Join-Path -Path $externalRoot -ChildPath 'project/app') | Out-Null
    $insideLink = Join-Path -Path $projectRootReparseRoot -ChildPath 'linked'
    New-Item -ItemType Junction -Path $insideLink -Target $externalRoot | Out-Null
    $manifestRoot = Join-Path -Path $projectRootReparseRoot -ChildPath 'manifest-holder'
    New-Item -ItemType Directory -Force -Path $manifestRoot | Out-Null
    $reparseManifest = New-TestProjectManifest -Id 'reparse-project' -ProjectRoot (Join-Path -Path $insideLink -ChildPath 'project')
    $reparseManifest | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path -Path $manifestRoot -ChildPath 'deployment.project.json') -Encoding UTF8
    $reparseCatalog = New-ProjectCatalog -ProjectsRoot $projectRootReparseRoot
    Assert-Equal $reparseCatalog.projects[0].eligibility 'invalid-manifest' 'project.root containing a reparse path segment must be invalid-manifest.'
    Assert-True (@($reparseCatalog.projects[0].issues | Where-Object { $_.code -eq 'project-root-reparse-point' }).Count -eq 1) 'project.root reparse issue must be machine-readable.'

    $resolutionRoot = New-ProjectsRoot -BasePath $tmp -Name 'resolution'
    Add-TestProject -ProjectsRoot $resolutionRoot -DirectoryName 'alpha' -Id 'alpha-project' -Name 'Display Name Only' -Aliases @('alpha-alias') | Out-Null
    $resolvedById = Resolve-DeploymentProject -ProjectsRoot $resolutionRoot -ProjectIdentifier 'alpha-project'
    Assert-Equal $resolvedById.status 'resolved' 'Exact ID must resolve.'
    Assert-Equal $resolvedById.matchType 'id' 'Exact ID matchType must be id.'
    Assert-Equal ((Resolve-DeploymentProject -ProjectsRoot $resolutionRoot -ProjectIdentifier 'ALPHA-PROJECT').status) 'resolved' 'ID comparison must be case-insensitive.'
    $resolvedByAlias = Resolve-DeploymentProject -ProjectsRoot $resolutionRoot -ProjectIdentifier 'alpha-alias'
    Assert-Equal $resolvedByAlias.status 'resolved' 'Exact alias must resolve.'
    Assert-Equal $resolvedByAlias.matchType 'alias' 'Alias matchType must be alias.'
    Assert-Equal ((Resolve-DeploymentProject -ProjectsRoot $resolutionRoot -ProjectIdentifier 'ALPHA-ALIAS').status) 'resolved' 'Alias comparison must be case-insensitive.'
    Assert-Equal ((Resolve-DeploymentProject -ProjectsRoot $resolutionRoot -ProjectIdentifier 'Display Name Only').status) 'not-found' 'project.name must not be used for resolution.'
    Assert-Equal ((Resolve-DeploymentProject -ProjectsRoot $resolutionRoot -ProjectIdentifier 'missing').status) 'not-found' 'Unknown identifier must be not-found.'
    Assert-NotEqual ((Resolve-DeploymentProject -ProjectsRoot $resolutionRoot -ProjectIdentifier 'alpha').status) 'resolved' 'Substring must not resolve.'
    Assert-True (@((Resolve-DeploymentProject -ProjectsRoot $resolutionRoot -ProjectIdentifier 'alpha').suggestions).Count -eq 1) 'Substring-like identifier may only produce suggestions.'
    Assert-Equal ((Resolve-DeploymentProject -ProjectsRoot $resolutionRoot -ProjectIdentifier 'alpha').status) 'not-found' 'A single suggestion must not resolve.'

    $cwdBefore = (Get-Location).Path
    try {
        Set-Location -LiteralPath (Join-Path $resolutionRoot 'alpha')
        Assert-Equal ((Resolve-DeploymentProject -ProjectsRoot $emptyRoot -ProjectIdentifier 'alpha-project').status) 'not-found' 'Resolution must not fall back to current working directory.'
    } finally {
        Set-Location -LiteralPath $cwdBefore
    }

    $invalidResolutionRoot = New-ProjectsRoot -BasePath $tmp -Name 'invalid-resolution'
    $badManifest = New-TestProjectManifest -Id 'bad-project' -ProjectRoot (Join-Path $invalidResolutionRoot 'bad')
    $badManifest.Remove('rules')
    Add-RawManifestProject -ProjectsRoot $invalidResolutionRoot -DirectoryName 'bad' -Content ($badManifest | ConvertTo-Json -Depth 20) | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $invalidResolutionRoot 'bad/app') | Out-Null
    Assert-Equal ((Resolve-DeploymentProject -ProjectsRoot $invalidResolutionRoot -ProjectIdentifier 'bad-project').status) 'invalid' 'Exact invalid project must resolve to invalid status.'

    Assert-Equal ((Resolve-DeploymentProject -ProjectsRoot $deployableRoot -ProjectIdentifier 'off').status) 'ineligible' 'Exact ineligible project must resolve to ineligible status.'
    Assert-True (((Resolve-DeploymentProject -ProjectsRoot $aliasAliasRoot -ProjectIdentifier 'shared').status) -in @('ambiguous', 'identifier-conflict')) 'Conflicted identifier must not resolve.'

    $snapshotBeforeResolve = Get-FileSnapshot -Root $resolutionRoot
    [void] (Resolve-DeploymentProject -ProjectsRoot $resolutionRoot -ProjectIdentifier 'alpha-project')
    Assert-Equal (Get-FileSnapshot -Root $resolutionRoot) $snapshotBeforeResolve 'Resolution must not modify files.'
    Assert-True (-not ((Resolve-DeploymentProject -ProjectsRoot $resolutionRoot -ProjectIdentifier 'alpha-project' | ConvertTo-Json -Depth 20) -match 'engineVersion|execution-plan|deployment-analysis')) 'Resolution must not run analysis or execution planning.'

    $cliDiscovery = & $cliPath discover-projects -ProjectsRoot $resolutionRoot -Format Json
    Assert-Equal ($cliDiscovery | ConvertFrom-Json).operation 'project-discovery' 'CLI discover-projects must route to Project Catalog.'
    $afterDiscoveryCliMarker = 'still-running-after-discover'
    Assert-Equal $afterDiscoveryCliMarker 'still-running-after-discover' 'discover-projects CLI must not terminate the caller process.'
    $cliResolution = & $cliPath resolve-project -ProjectsRoot $resolutionRoot -ProjectIdentifier 'alpha-project' -Format Json
    Assert-Equal ($cliResolution | ConvertFrom-Json).status 'resolved' 'CLI resolve-project must route to Project Catalog.'
    $afterResolutionCliMarker = 'still-running-after-resolve'
    Assert-Equal $afterResolutionCliMarker 'still-running-after-resolve' 'resolve-project CLI must not terminate the caller process.'
    Assert-Equal ($cliDiscovery | ConvertFrom-Json).schemaVersion '0.1' 'CLI discovery JSON must be parseable.'
    $catalogInvocation = & $catalogPath -Operation Discover -ProjectsRoot $resolutionRoot -Format Json
    Assert-Equal ($catalogInvocation | ConvertFrom-Json).operation 'project-discovery' 'Project Catalog script invocation with ampersand must return JSON.'
    $afterCatalogMarker = 'still-running-after-catalog-script'
    Assert-Equal $afterCatalogMarker 'still-running-after-catalog-script' 'Project Catalog script invocation must not terminate the caller process.'

    Assert-ThrowsLike -Script { & $cliPath discover-projects -Format Json | Out-Null } -Pattern 'ProjectsRoot' -Message 'CLI discover-projects without ProjectsRoot must fail.'
    Assert-ThrowsLike -Script { & $cliPath resolve-project -ProjectsRoot $resolutionRoot -Format Json | Out-Null } -Pattern 'ProjectIdentifier' -Message 'CLI resolve-project without ProjectIdentifier must fail.'
    Assert-ThrowsLike -Script { & $cliPath unknown-command | Out-Null } -Pattern 'ValidateSet|Cannot validate argument' -Message 'Unknown CLI command must fail through ValidateSet.'
    Assert-ThrowsLike -Script { New-ProjectCatalog -ProjectsRoot (Join-Path $tmp 'missing-root') | Out-Null } -Pattern 'does not exist' -Message 'Missing ProjectsRoot must be rejected.'
    Assert-True (-not ((Get-Content -LiteralPath $cliPath -Raw) -match 'Get-ChildItem.*deployment.project.json')) 'CLI must not implement manifest search logic.'
} finally {
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
}

if ($script:failures.Count -gt 0) {
    Write-Host 'Project Catalog tests failed:'
    $script:failures | ForEach-Object { Write-Host "- $_" }
    throw "Project Catalog tests failed after $script:assertionCount assertions."
}

Write-Host "Project Catalog tests passed. Assertions: $script:assertionCount."
