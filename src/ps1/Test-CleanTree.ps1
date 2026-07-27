[CmdletBinding()]
param(
    [string] $RepositoryPath,
    [string] $OutputPath,
    [string] $Format = 'Json',
    [switch] $ModuleOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-CleanTreePath {
    param([Parameter(Mandatory = $true)][string] $Path)
    $executionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function Test-CleanTreeProperty {
    param([object] $Object, [Parameter(Mandatory = $true)][string] $Name)
    return ($null -ne $Object -and @($Object.PSObject.Properties | Where-Object { $_.Name -eq $Name }).Count -gt 0)
}

function Invoke-CleanTreeGit {
    param([Parameter(Mandatory = $true)][string] $RepositoryPath, [Parameter(Mandatory = $true)][string[]] $Arguments)
    $output = & git -C $RepositoryPath @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        $diagnostic = (($output | ForEach-Object { [string] $_ }) -join ' ').Trim()
        if ([string]::IsNullOrWhiteSpace($diagnostic)) { $diagnostic = 'git command failed.' }
        throw "Source state assessment failed: $diagnostic"
    }
    return $output
}

function Split-CleanTreePorcelainRecord {
    param([Parameter(Mandatory = $true)][string] $Record)
    $pathText = if ($Record.Length -gt 3) { $Record.Substring(3) } else { '' }
    if ($pathText -match ' -> ') {
        $parts = $pathText -split ' -> ', 2
        $pathText = $parts[1]
    }
    return [pscustomobject]@{
        stagedCode = [string] $Record[0]
        unstagedCode = [string] $Record[1]
        path = $pathText
    }
}

function New-CleanTreeChangedPath {
    param([Parameter(Mandatory = $true)][object] $Record)
    $staged = ($Record.stagedCode -ne ' ' -and $Record.stagedCode -ne '?')
    $unstaged = ($Record.unstagedCode -ne ' ' -and $Record.unstagedCode -ne '?')
    $untracked = ($Record.stagedCode -eq '?' -and $Record.unstagedCode -eq '?')
    return [pscustomobject]@{
        path = [string] $Record.path
        statusCode = ([string] $Record.stagedCode + [string] $Record.unstagedCode)
        staged = [bool] $staged
        unstaged = [bool] $unstaged
        untracked = [bool] $untracked
    }
}

function Get-CleanTreeChangedPaths {
    param([string[]] $StatusLines = @())
    $changes = New-Object System.Collections.Generic.List[object]
    foreach ($line in @($StatusLines)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line.Length -lt 3) { throw "Source state assessment failed: unexpected git status record '$line'." }
        $changes.Add((New-CleanTreeChangedPath -Record (Split-CleanTreePorcelainRecord -Record $line)))
    }
    return @($changes | Sort-Object path, statusCode)
}

function New-CleanTreeAssessment {
    param([Parameter(Mandatory = $true)][string] $RepositoryPath)
    if ([string]::IsNullOrWhiteSpace($RepositoryPath)) {
        throw 'Source state assessment validation failed: RepositoryPath is required.'
    }
    $repo = Resolve-CleanTreePath -Path $RepositoryPath
    if (-not (Test-Path -LiteralPath $repo -PathType Container)) {
        throw "Source state assessment validation failed: repository path does not exist: $repo"
    }

    $insideWorkTree = ((Invoke-CleanTreeGit -RepositoryPath $repo -Arguments @('rev-parse', '--is-inside-work-tree')) -join '').Trim()
    if ($insideWorkTree -ne 'true') { throw "Source state assessment validation failed: path is not a git working tree: $repo" }

    $repositoryRoot = ((Invoke-CleanTreeGit -RepositoryPath $repo -Arguments @('rev-parse', '--show-toplevel')) -join '').Trim()
    $statusLines = @(Invoke-CleanTreeGit -RepositoryPath $repo -Arguments @('status', '--porcelain=v1', '--untracked-files=all'))
    $changedPaths = @(Get-CleanTreeChangedPaths -StatusLines $statusLines)
    $hasStaged = @($changedPaths | Where-Object { $_.staged }).Count -gt 0
    $hasUnstaged = @($changedPaths | Where-Object { $_.unstaged }).Count -gt 0
    $hasUntracked = @($changedPaths | Where-Object { $_.untracked }).Count -gt 0
    $clean = ($changedPaths.Count -eq 0)

    return [pscustomobject]@{
        schemaVersion = '0.1'
        assessmentType = 'deployment-source-state-assessment'
        repositoryPath = $repo
        repositoryRoot = $repositoryRoot
        deploymentAllowed = [bool] $clean
        status = if ($clean) { 'clean' } else { 'dirty' }
        clean = [bool] $clean
        hasStagedChanges = [bool] $hasStaged
        hasUnstagedChanges = [bool] $hasUnstaged
        hasUntrackedFiles = [bool] $hasUntracked
        changedPaths = @($changedPaths)
        diagnostic = if ($clean) { '' } else { 'Repository has staged, unstaged, or untracked changes.' }
    }
}

function Write-CleanTreeAssessmentJson {
    param([Parameter(Mandatory = $true)][object] $Assessment, [string] $OutputPath)
    $json = $Assessment | ConvertTo-Json -Depth 30
    if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
        $resolvedOutputPath = Resolve-CleanTreePath -Path $OutputPath
        $outputDirectory = Split-Path -Path $resolvedOutputPath -Parent
        if (-not [string]::IsNullOrWhiteSpace($outputDirectory)) { New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null }
        $json | Set-Content -LiteralPath $resolvedOutputPath -Encoding utf8
    }
    return $json
}

function Invoke-CleanTreeAssessment {
    param([Parameter(Mandatory = $true)][string] $RepositoryPath, [string] $OutputPath, [string] $Format = 'Json')
    if ($Format -ne 'Json') { throw "assess-clean-tree only supports -Format Json." }
    $assessment = New-CleanTreeAssessment -RepositoryPath $RepositoryPath
    return Write-CleanTreeAssessmentJson -Assessment $assessment -OutputPath $OutputPath
}

if (-not $ModuleOnly) {
    if ([string]::IsNullOrWhiteSpace($RepositoryPath)) { throw "Missing required parameter for 'assess-clean-tree': -RepositoryPath" }
    Invoke-CleanTreeAssessment -RepositoryPath $RepositoryPath -OutputPath $OutputPath -Format $Format
}
