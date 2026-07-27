[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:failures = New-Object System.Collections.Generic.List[string]
$engineRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '..'))
$cleanTreePath = Join-Path -Path $engineRoot -ChildPath 'src/ps1/Test-CleanTree.ps1'
$cliPath = Join-Path -Path $engineRoot -ChildPath 'bin/deployment-engine.ps1'

. $cleanTreePath -ModuleOnly

function Assert-True { param([bool] $Condition, [string] $Message) if (-not $Condition) { $script:failures.Add($Message) } }
function Assert-Equal { param($Actual, $Expected, [string] $Message) if ($Actual -ne $Expected) { $script:failures.Add("$Message Expected '$Expected', got '$Actual'.") } }
function Assert-ThrowsLike {
    param([scriptblock] $Script, [string] $Pattern, [string] $Message)
    try { & $Script; $script:failures.Add($Message) } catch { Assert-True ($_.Exception.Message -match $Pattern) "$Message Actual error: $($_.Exception.Message)" }
}

function Invoke-TestGit {
    param([Parameter(Mandatory = $true)][string] $RepositoryPath, [Parameter(Mandatory = $true)][string[]] $Arguments)
    $output = & git -C $RepositoryPath @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw (($output | ForEach-Object { [string] $_ }) -join ' ') }
    return $output
}

function New-TestRepository {
    param([Parameter(Mandatory = $true)][string] $RootPath, [Parameter(Mandatory = $true)][string] $Name)
    $repo = Join-Path -Path $RootPath -ChildPath $Name
    New-Item -ItemType Directory -Path $repo | Out-Null
    Invoke-TestGit -RepositoryPath $repo -Arguments @('init') | Out-Null
    Invoke-TestGit -RepositoryPath $repo -Arguments @('config', 'user.email', 'deployment-engine@example.invalid') | Out-Null
    Invoke-TestGit -RepositoryPath $repo -Arguments @('config', 'user.name', 'Deployment Engine Tests') | Out-Null
    Set-Content -LiteralPath (Join-Path -Path $repo -ChildPath 'tracked.txt') -Value 'initial' -Encoding UTF8
    Invoke-TestGit -RepositoryPath $repo -Arguments @('add', 'tracked.txt') | Out-Null
    Invoke-TestGit -RepositoryPath $repo -Arguments @('commit', '-m', 'initial') | Out-Null
    return $repo
}

$tmp = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('clean-tree-assessment-tests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    $cleanRepo = New-TestRepository -RootPath $tmp -Name 'clean'
    $clean = New-CleanTreeAssessment -RepositoryPath $cleanRepo
    Assert-Equal $clean.schemaVersion '0.1' 'Clean tree schema version must be stable.'
    Assert-Equal $clean.assessmentType 'deployment-source-state-assessment' 'Assessment type must be explicit.'
    Assert-Equal $clean.status 'clean' 'Clean repository must be clean.'
    Assert-Equal $clean.deploymentAllowed $true 'Clean repository must be deploymentAllowed.'
    Assert-Equal @($clean.changedPaths).Count 0 'Clean repository must not contain changed paths.'
    Assert-Equal $clean.hasStagedChanges $false 'Clean repository must not report staged changes.'
    Assert-Equal $clean.hasUnstagedChanges $false 'Clean repository must not report unstaged changes.'
    Assert-Equal $clean.hasUntrackedFiles $false 'Clean repository must not report untracked files.'

    $unstagedRepo = New-TestRepository -RootPath $tmp -Name 'unstaged'
    Set-Content -LiteralPath (Join-Path -Path $unstagedRepo -ChildPath 'tracked.txt') -Value 'changed' -Encoding UTF8
    $unstaged = New-CleanTreeAssessment -RepositoryPath $unstagedRepo
    Assert-Equal $unstaged.status 'dirty' 'Unstaged modification must be dirty.'
    Assert-Equal $unstaged.deploymentAllowed $false 'Dirty repository must not be deploymentAllowed.'
    Assert-Equal $unstaged.hasUnstagedChanges $true 'Unstaged modification must be detected.'
    Assert-Equal $unstaged.hasStagedChanges $false 'Unstaged-only modification must not be staged.'
    Assert-Equal @($unstaged.changedPaths | Where-Object { $_.path -eq 'tracked.txt' -and $_.unstaged }).Count 1 'Unstaged path must be listed.'

    $stagedRepo = New-TestRepository -RootPath $tmp -Name 'staged'
    Set-Content -LiteralPath (Join-Path -Path $stagedRepo -ChildPath 'tracked.txt') -Value 'changed' -Encoding UTF8
    Invoke-TestGit -RepositoryPath $stagedRepo -Arguments @('add', 'tracked.txt') | Out-Null
    $staged = New-CleanTreeAssessment -RepositoryPath $stagedRepo
    Assert-Equal $staged.status 'dirty' 'Staged modification must be dirty.'
    Assert-Equal $staged.hasStagedChanges $true 'Staged modification must be detected.'
    Assert-Equal $staged.hasUnstagedChanges $false 'Staged-only modification must not be unstaged.'
    Assert-Equal @($staged.changedPaths | Where-Object { $_.path -eq 'tracked.txt' -and $_.staged }).Count 1 'Staged path must be listed.'

    $untrackedRepo = New-TestRepository -RootPath $tmp -Name 'untracked'
    Set-Content -LiteralPath (Join-Path -Path $untrackedRepo -ChildPath 'new-file.txt') -Value 'new' -Encoding UTF8
    $untracked = New-CleanTreeAssessment -RepositoryPath $untrackedRepo
    Assert-Equal $untracked.status 'dirty' 'Untracked file must be dirty.'
    Assert-Equal $untracked.hasUntrackedFiles $true 'Untracked file must be detected.'
    Assert-Equal @($untracked.changedPaths | Where-Object { $_.path -eq 'new-file.txt' -and $_.untracked }).Count 1 'Untracked path must be listed.'

    $notRepo = Join-Path -Path $tmp -ChildPath 'not-repo'
    New-Item -ItemType Directory -Path $notRepo | Out-Null
    Assert-ThrowsLike -Script { New-CleanTreeAssessment -RepositoryPath $notRepo | Out-Null } -Pattern 'not a git|failed' -Message 'Non-repository path must be rejected.'
    Assert-ThrowsLike -Script { New-CleanTreeAssessment -RepositoryPath (Join-Path $tmp 'missing') | Out-Null } -Pattern 'does not exist' -Message 'Missing repository path must be rejected.'

    $outputPath = Join-Path -Path $tmp -ChildPath 'assessment/clean-tree.json'
    & $cliPath assess-clean-tree -RepositoryPath $cleanRepo -OutputPath $outputPath -Format Json | Out-Null
    Assert-True (Test-Path -LiteralPath $outputPath -PathType Leaf) 'Clean tree CLI must write explicit output file.'
    Assert-Equal (Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json).status 'clean' 'Clean tree CLI output must be parseable JSON.'

    $fileCountBeforeStdout = @(Get-ChildItem -LiteralPath $tmp -File -Recurse).Count
    $stdoutJson = & $cliPath assess-clean-tree -RepositoryPath $cleanRepo -Format Json
    $fileCountAfterStdout = @(Get-ChildItem -LiteralPath $tmp -File -Recurse).Count
    Assert-Equal ($stdoutJson | ConvertFrom-Json).assessmentType 'deployment-source-state-assessment' 'Clean tree CLI without OutputPath must emit parseable JSON.'
    Assert-Equal @($stdoutJson).Count 1 'Clean tree CLI without OutputPath must not emit extra stdout.'
    Assert-Equal $fileCountAfterStdout $fileCountBeforeStdout 'Clean tree CLI without OutputPath must not create files.'
} finally {
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
}

if ($script:failures.Count -gt 0) {
    Write-Host 'Clean Tree Assessment tests failed:'
    $script:failures | ForEach-Object { Write-Host "- $_" }
    exit 1
}

Write-Host 'Clean Tree Assessment tests passed.'
exit 0
