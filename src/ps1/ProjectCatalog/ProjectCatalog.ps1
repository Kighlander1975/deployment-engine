[CmdletBinding()]
param(
    [ValidateSet('', 'Discover', 'Resolve')]
    [string] $Operation = '',

    [string] $ProjectsRoot,

    [string] $ProjectIdentifier,

    [ValidateSet('Json')]
    [string] $Format = 'Json',

    [string] $OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectCatalogSchemaVersion = '0.1'
$projectManifestSchemaPath = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../../../schemas/deployment.project.schema.json'))

function Resolve-CatalogPath {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [ValidateSet('Container', 'Leaf')][string] $PathType = 'Container'
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw 'Path must not be empty.'
    }

    $resolved = [System.IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $resolved -PathType $PathType)) {
        throw "$PathType path does not exist: $resolved"
    }

    $item = Get-Item -LiteralPath $resolved -Force
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$PathType path must not be a reparse point: $resolved"
    }

    return $item.FullName
}

function Test-ReparsePointInPath {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Root
    )

    $resolvedPath = [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    $resolvedRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    if (-not (Test-PathInsideRoot -Path $resolvedPath -Root $resolvedRoot)) {
        return $true
    }

    $current = $resolvedPath
    while (-not [string]::IsNullOrWhiteSpace($current)) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                return $true
            }
        }
        if ($current.Equals($resolvedRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $false
        }
        $parent = Split-Path -Path $current -Parent
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $current) {
            return $true
        }
        $current = $parent
    }

    return $true
}

function Test-PathInsideRoot {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Root
    )

    $resolvedPath = [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    $resolvedRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    if ($resolvedPath.Equals($resolvedRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }

    $rootPrefix = $resolvedRoot + [System.IO.Path]::DirectorySeparatorChar
    return $resolvedPath.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)
}

function New-ProjectCatalogIssue {
    param(
        [Parameter(Mandatory = $true)][string] $Code,
        [Parameter(Mandatory = $true)][string] $Message,
        [string] $Path = '',
        [string] $Identifier = ''
    )

    return [pscustomobject]@{
        code = $Code
        message = $Message
        path = $Path
        identifier = $Identifier
    }
}

function Add-ProjectIssue {
    param(
        [Parameter(Mandatory = $true)][object] $Project,
        [Parameter(Mandatory = $true)][object] $Issue,
        [Parameter(Mandatory = $true)][string] $Eligibility
    )

    $Project.issues += @($Issue)
    if ($Project.eligibility -eq 'eligible' -or $Project.eligibility -eq 'ineligible') {
        $Project.eligibility = $Eligibility
        return
    }

    if ($Project.eligibility -eq 'duplicate-id') {
        return
    }

    if ($Eligibility -eq 'duplicate-id') {
        $Project.eligibility = 'duplicate-id'
        return
    }

    if ($Eligibility -eq 'identifier-conflict') {
        $Project.eligibility = 'identifier-conflict'
    }
}

function Get-StringArray {
    param($Value)

    if ($null -eq $Value) {
        return @()
    }

    $items = New-Object System.Collections.Generic.List[string]
    foreach ($item in @($Value)) {
        if ($null -ne $item) {
            $items.Add([string] $item)
        }
    }
    return $items.ToArray()
}

function Test-JsonAgainstProjectManifestSchema {
    param([Parameter(Mandatory = $true)][string] $Json)

    if (-not (Get-Command Test-Json -ErrorAction SilentlyContinue)) {
        return
    }

    $schema = Get-Content -LiteralPath $projectManifestSchemaPath -Raw
    [void] (Test-Json -Json $Json -Schema $schema -ErrorAction Stop)
}

function Get-SafeDeploymentManifestPaths {
    param([Parameter(Mandatory = $true)][string] $ProjectsRoot)

    $root = Resolve-CatalogPath -Path $ProjectsRoot -PathType Container
    $maxDepth = 4
    $skipDirectoryNames = @('.git', '.hg', '.svn', 'node_modules', 'vendor', 'storage')
    $stack = [System.Collections.Generic.Stack[object]]::new()
    $stack.Push([pscustomobject]@{ path = $root; depth = 0 })
    $manifestPaths = New-Object System.Collections.Generic.List[string]

    while ($stack.Count -gt 0) {
        $stackItem = $stack.Pop()
        $directoryPath = [string] $stackItem.path
        $depth = [int] $stackItem.depth
        if (-not (Test-PathInsideRoot -Path $directoryPath -Root $root)) {
            continue
        }

        $directory = Get-Item -LiteralPath $directoryPath -Force
        if (($directory.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            continue
        }

        $manifestPath = Join-Path -Path $directory.FullName -ChildPath 'deployment.project.json'
        if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
            $manifestItem = Get-Item -LiteralPath $manifestPath -Force
            if (($manifestItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0 -and (Test-PathInsideRoot -Path $manifestItem.FullName -Root $root)) {
                $manifestPaths.Add($manifestItem.FullName)
            }
        }

        if ($depth -ge $maxDepth) {
            continue
        }

        foreach ($childDirectory in @(Get-ChildItem -LiteralPath $directory.FullName -Directory -Force | Sort-Object FullName)) {
            if ($childDirectory.Name -in $skipDirectoryNames) {
                continue
            }
            if (($childDirectory.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                continue
            }
            if (Test-PathInsideRoot -Path $childDirectory.FullName -Root $root) {
                $stack.Push([pscustomobject]@{ path = $childDirectory.FullName; depth = ($depth + 1) })
            }
        }
    }

    return @($manifestPaths.ToArray() | Sort-Object)
}

function Read-ProjectCatalogManifest {
    param(
        [Parameter(Mandatory = $true)][string] $ManifestPath,
        [Parameter(Mandatory = $true)][string] $ProjectsRoot
    )

    $issues = @()
    $manifest = $null
    $raw = ''
    $id = ''
    $name = ''
    $aliases = @()
    $deployable = $true
    $projectRoot = [System.IO.Path]::GetFullPath((Split-Path -Path $ManifestPath -Parent))
    $eligibility = 'eligible'

    try {
        $raw = Get-Content -LiteralPath $ManifestPath -Raw
        $manifest = $raw | ConvertFrom-Json
        Test-JsonAgainstProjectManifestSchema -Json $raw
    } catch {
        $issues += New-ProjectCatalogIssue -Code 'invalid-manifest' -Message "Invalid project manifest: $($_.Exception.Message)" -Path $ManifestPath
        $eligibility = 'invalid-manifest'
    }

    if ($null -ne $manifest) {
        if ($null -ne $manifest.project) {
            if ($manifest.project.PSObject.Properties.Name -contains 'id') { $id = ([string] $manifest.project.id).Trim() }
            if ($manifest.project.PSObject.Properties.Name -contains 'name') { $name = ([string] $manifest.project.name).Trim() }
            if ($manifest.project.PSObject.Properties.Name -contains 'root' -and -not [string]::IsNullOrWhiteSpace([string] $manifest.project.root)) {
                $projectRoot = [System.IO.Path]::GetFullPath([string] $manifest.project.root)
            }
            if ($manifest.project.PSObject.Properties.Name -contains 'aliases') { $aliases = @(Get-StringArray $manifest.project.aliases | ForEach-Object { $_.Trim() }) }
            if ($manifest.project.PSObject.Properties.Name -contains 'deployable') { $deployable = [bool] $manifest.project.deployable }
        }

        if ($eligibility -eq 'eligible') {
            if ([string]::IsNullOrWhiteSpace($id)) {
                $issues += New-ProjectCatalogIssue -Code 'missing-project-id' -Message 'Project manifest is missing project.id.' -Path $ManifestPath
                $eligibility = 'invalid-manifest'
            }
            if (-not (Test-PathInsideRoot -Path $projectRoot -Root $ProjectsRoot)) {
                $issues += New-ProjectCatalogIssue -Code 'project-root-outside-projects-root' -Message 'Manifest project.root resolves outside ProjectsRoot.' -Path $ManifestPath
                $eligibility = 'invalid-manifest'
            }
            if (Test-ReparsePointInPath -Path $projectRoot -Root $ProjectsRoot) {
                $issues += New-ProjectCatalogIssue -Code 'project-root-reparse-point' -Message 'Manifest project.root contains a reparse point in its path.' -Path $ManifestPath
                $eligibility = 'invalid-manifest'
            }
            if (-not $deployable) {
                $eligibility = 'ineligible'
                $issues += New-ProjectCatalogIssue -Code 'project-not-deployable' -Message 'project.deployable is false.' -Path $ManifestPath -Identifier $id
            }
        }
    }

    $seenAliases = @{}
    foreach ($alias in @($aliases)) {
        if ([string]::IsNullOrWhiteSpace($alias)) {
            $issues += New-ProjectCatalogIssue -Code 'invalid-alias' -Message 'Project aliases must not be empty.' -Path $ManifestPath -Identifier $id
            $eligibility = if ($eligibility -eq 'eligible' -or $eligibility -eq 'ineligible') { 'identifier-conflict' } else { $eligibility }
            continue
        }
        $normalizedAlias = $alias.ToLowerInvariant()
        if ($seenAliases.ContainsKey($normalizedAlias)) {
            $issues += New-ProjectCatalogIssue -Code 'duplicate-alias' -Message "Duplicate project alias '$alias' in one manifest." -Path $ManifestPath -Identifier $alias
            $eligibility = if ($eligibility -eq 'eligible' -or $eligibility -eq 'ineligible') { 'identifier-conflict' } else { $eligibility }
        } else {
            $seenAliases[$normalizedAlias] = $true
        }
    }

    return [pscustomobject]@{
        id = $id
        name = $name
        aliases = @($aliases | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        projectRoot = $projectRoot
        manifestPath = $ManifestPath
        eligibility = $eligibility
        issues = @($issues)
    }
}

function Add-ProjectIdentifierConflicts {
    param([AllowEmptyCollection()][object[]] $Projects = @())

    $entries = New-Object System.Collections.Generic.List[object]
    foreach ($project in @($Projects)) {
        if (-not [string]::IsNullOrWhiteSpace([string] $project.id)) {
            $entries.Add([pscustomobject]@{ normalized = ([string] $project.id).ToLowerInvariant(); value = [string] $project.id; kind = 'id'; project = $project })
        }
        foreach ($alias in @($project.aliases)) {
            $entries.Add([pscustomobject]@{ normalized = ([string] $alias).ToLowerInvariant(); value = [string] $alias; kind = 'alias'; project = $project })
        }
    }

    foreach ($group in @($entries | Group-Object normalized)) {
        $groupEntries = @($group.Group)
        if ($groupEntries.Count -lt 2) {
            continue
        }

        $idEntries = @($groupEntries | Where-Object { $_.kind -eq 'id' })
        $aliasEntries = @($groupEntries | Where-Object { $_.kind -eq 'alias' })
        $distinctProjects = @($groupEntries | ForEach-Object { $_.project.manifestPath } | Sort-Object -Unique)
        if ($idEntries.Count -gt 1) {
            foreach ($entry in $idEntries) {
                Add-ProjectIssue -Project $entry.project -Eligibility 'duplicate-id' -Issue (New-ProjectCatalogIssue -Code 'duplicate-project-id' -Message "Project ID '$($entry.value)' is not globally unique." -Path $entry.project.manifestPath -Identifier $entry.value)
            }
        }

        if ($distinctProjects.Count -eq 1 -and $idEntries.Count -eq 1 -and $aliasEntries.Count -ge 1) {
            $project = $groupEntries[0].project
            Add-ProjectIssue -Project $project -Eligibility 'identifier-conflict' -Issue (New-ProjectCatalogIssue -Code 'identifier-conflict' -Message "Project alias conflicts with its own project ID '$($idEntries[0].value)'." -Path $project.manifestPath -Identifier $idEntries[0].value)
            continue
        }

        if ($distinctProjects.Count -gt 1 -or $aliasEntries.Count -gt 1) {
            foreach ($entry in $groupEntries) {
                if ($entry.kind -eq 'alias' -or $idEntries.Count -eq 0) {
                    Add-ProjectIssue -Project $entry.project -Eligibility 'identifier-conflict' -Issue (New-ProjectCatalogIssue -Code 'identifier-conflict' -Message "Identifier '$($entry.value)' conflicts with another project identifier." -Path $entry.project.manifestPath -Identifier $entry.value)
                } elseif (@($groupEntries | Where-Object { $_.kind -eq 'alias' -and $_.project.manifestPath -ne $entry.project.manifestPath }).Count -gt 0) {
                    Add-ProjectIssue -Project $entry.project -Eligibility 'identifier-conflict' -Issue (New-ProjectCatalogIssue -Code 'identifier-conflict' -Message "Project ID '$($entry.value)' conflicts with another project's alias." -Path $entry.project.manifestPath -Identifier $entry.value)
                }
            }
        }
    }
}

function New-ProjectCatalog {
    param([Parameter(Mandatory = $true)][string] $ProjectsRoot)

    $resolvedRoot = Resolve-CatalogPath -Path $ProjectsRoot -PathType Container
    $manifestPaths = @(Get-SafeDeploymentManifestPaths -ProjectsRoot $resolvedRoot)
    $projects = @(
        foreach ($manifestPath in $manifestPaths) {
            Read-ProjectCatalogManifest -ManifestPath $manifestPath -ProjectsRoot $resolvedRoot
        }
    )

    Add-ProjectIdentifierConflicts -Projects $projects
    $sortedProjects = @($projects | Sort-Object @{ Expression = { ([string] $_.id).ToLowerInvariant() } }, manifestPath)
    $issues = @($sortedProjects | ForEach-Object { $_.issues } | Where-Object { $null -ne $_ })

    return [pscustomobject]@{
        schemaVersion = $projectCatalogSchemaVersion
        operation = 'project-discovery'
        status = 'success'
        projectsRoot = $resolvedRoot
        projects = @($sortedProjects)
        issues = @($issues)
    }
}

function New-ProjectSuggestion {
    param([Parameter(Mandatory = $true)][object] $Project)

    return [pscustomobject]@{
        id = [string] $Project.id
        name = [string] $Project.name
    }
}

function Get-ProjectResolutionSuggestions {
    param(
        [AllowEmptyCollection()][object[]] $Projects = @(),
        [Parameter(Mandatory = $true)][string] $ProjectIdentifier
    )

    $needle = $ProjectIdentifier.Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($needle)) {
        return @()
    }

    return @(
        $Projects |
            Where-Object {
                $_.eligibility -eq 'eligible' -and (
                    ([string] $_.id).ToLowerInvariant().Contains($needle) -or
                    @($_.aliases | Where-Object { ([string] $_).ToLowerInvariant().Contains($needle) }).Count -gt 0
                )
            } |
            Sort-Object @{ Expression = { ([string] $_.id).ToLowerInvariant() } }, manifestPath |
            ForEach-Object { New-ProjectSuggestion -Project $_ }
    )
}

function Resolve-DeploymentProject {
    param(
        [Parameter(Mandatory = $true)][string] $ProjectsRoot,
        [Parameter(Mandatory = $true)][string] $ProjectIdentifier
    )

    if ([string]::IsNullOrWhiteSpace($ProjectIdentifier)) {
        throw "Missing required parameter for 'resolve-project': -ProjectIdentifier"
    }

    $catalog = New-ProjectCatalog -ProjectsRoot $ProjectsRoot
    $requested = $ProjectIdentifier.Trim()
    $normalized = $requested.ToLowerInvariant()
    $matches = New-Object System.Collections.Generic.List[object]

    foreach ($project in @($catalog.projects)) {
        if (-not [string]::IsNullOrWhiteSpace([string] $project.id) -and ([string] $project.id).ToLowerInvariant() -eq $normalized) {
            $matches.Add([pscustomobject]@{ project = $project; matchType = 'id' })
        }
        foreach ($alias in @($project.aliases)) {
            if (([string] $alias).ToLowerInvariant() -eq $normalized) {
                $matches.Add([pscustomobject]@{ project = $project; matchType = 'alias' })
            }
        }
    }

    $distinctMatches = @($matches | Sort-Object { $_.project.manifestPath }, matchType -Unique)
    $suggestions = @(Get-ProjectResolutionSuggestions -Projects $catalog.projects -ProjectIdentifier $requested)

    $status = 'not-found'
    $matchType = $null
    $project = $null
    $issues = @()

    $matchedProjects = @($distinctMatches | ForEach-Object { $_.project } | Sort-Object manifestPath -Unique)
    if ($matchedProjects.Count -gt 1) {
        $status = 'ambiguous'
        $issues += New-ProjectCatalogIssue -Code 'ambiguous-identifier' -Message "Identifier '$requested' matches multiple project identifiers." -Identifier $requested
    } elseif ($matchedProjects.Count -eq 1) {
        $matchedProject = $distinctMatches[0].project
        $matchTypes = @($distinctMatches | ForEach-Object { $_.matchType } | Sort-Object -Unique)
        $matchType = if ($matchTypes.Count -eq 1) { $matchTypes[0] } else { ($matchTypes -join '+') }
        switch ($matchedProject.eligibility) {
            'eligible' { $status = 'resolved'; $project = $matchedProject }
            'ineligible' { $status = 'ineligible'; $project = $matchedProject }
            'invalid-manifest' { $status = 'invalid'; $project = $matchedProject }
            'duplicate-id' { $status = 'identifier-conflict'; $project = $matchedProject }
            'identifier-conflict' { $status = 'identifier-conflict'; $project = $matchedProject }
            default { $status = 'invalid'; $project = $matchedProject }
        }
        $issues += @($matchedProject.issues)
    }

    return [pscustomobject]@{
        schemaVersion = $projectCatalogSchemaVersion
        operation = 'project-resolution'
        status = $status
        requestedIdentifier = $requested
        matchType = $matchType
        project = $project
        suggestions = @($suggestions)
        issues = @($issues)
    }
}

function Write-ProjectCatalogJson {
    param(
        [Parameter(Mandatory = $true)][object] $Value,
        [string] $Path
    )

    $json = $Value | ConvertTo-Json -Depth 20
    if ([string]::IsNullOrWhiteSpace($Path)) {
        $json
        return
    }

    $resolvedOutputPath = [System.IO.Path]::GetFullPath($Path)
    $outputDirectory = Split-Path -Path $resolvedOutputPath -Parent
    if (-not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
        throw "Output directory does not exist: $outputDirectory"
    }
    $json | Set-Content -LiteralPath $resolvedOutputPath -Encoding utf8
}

if ($MyInvocation.InvocationName -ne '.') {
    if ($Format -ne 'Json') {
        throw 'Project Catalog only supports -Format Json.'
    }

    switch ($Operation) {
        'Discover' {
            if ([string]::IsNullOrWhiteSpace($ProjectsRoot)) {
                throw "Missing required parameter for 'discover-projects': -ProjectsRoot"
            }
            Write-ProjectCatalogJson -Value (New-ProjectCatalog -ProjectsRoot $ProjectsRoot) -Path $OutputPath
        }
        'Resolve' {
            if ([string]::IsNullOrWhiteSpace($ProjectsRoot)) {
                throw "Missing required parameter for 'resolve-project': -ProjectsRoot"
            }
            Write-ProjectCatalogJson -Value (Resolve-DeploymentProject -ProjectsRoot $ProjectsRoot -ProjectIdentifier $ProjectIdentifier) -Path $OutputPath
        }
        default {
            throw 'Project Catalog requires -Operation Discover or Resolve.'
        }
    }
}
