[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:failures = New-Object System.Collections.Generic.List[string]
$engineRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '..'))
$analysisPath = Join-Path -Path $engineRoot -ChildPath 'src/ps1/Invoke-DeploymentAnalysis.ps1'

. $analysisPath -ProjectManifestPath 'unused.json' -ModuleOnly

function Assert-True { param([bool] $Condition, [string] $Message) if (-not $Condition) { $script:failures.Add($Message) } }
function Assert-Equal { param($Actual, $Expected, [string] $Message) if ($Actual -ne $Expected) { $script:failures.Add("$Message Expected '$Expected', got '$Actual'.") } }
function Assert-ThrowsLike {
    param([scriptblock] $Script, [string] $Pattern, [string] $Message)
    try { & $Script; $script:failures.Add($Message) } catch { if ($_.Exception.Message -notmatch $Pattern) { $script:failures.Add("$Message Pattern '$Pattern' not found in '$($_.Exception.Message)'.") } }
}

function Invoke-TestGit {
    param([string] $RepositoryPath, [string[]] $Arguments)
    $output = & git -C $RepositoryPath @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw (($output | ForEach-Object { [string] $_ }) -join ' ') }
    return $output
}

function New-TestManifest {
    param([object] $EnvironmentManagement = $null)
    $manifest = [pscustomobject]@{
        schemaVersion = '0.1'
        project = [pscustomobject]@{ id = 'demo'; name = 'Demo'; root = '.'; applicationRoot = 'laravel_app'; type = 'laravel' }
        repository = [pscustomobject]@{ branch = 'main' }
        deployment = [pscustomobject]@{ environment = 'staging'; serverRoot = '/var/www/demo'; markerFile = '.deploy-version' }
        protection = [pscustomobject]@{ neverUpload = @('.env'); neverOverwrite = @('.env') }
        classification = [pscustomobject]@{
            documentation = @('*.md')
            backendRuntime = @('laravel_app/app/**')
            frontendSource = @()
            frontendBuild = @()
            phpDependencies = @()
            frontendDependencies = @()
            migrations = @('laravel_app/database/migrations/**')
            seeders = @('laravel_app/database/seeders/**')
            environmentContract = @('laravel_app/.env.example')
            ignored = @('.git/**')
        }
        rules = [pscustomobject]@{
            composerTrigger = @()
            frontendBuildTrigger = @()
            migrationTrigger = @('laravel_app/database/migrations/**')
            environmentTrigger = @('laravel_app/.env.example')
            cleanupTrigger = @('laravel_app/app/**')
        }
    }
    if ($null -ne $EnvironmentManagement) {
        Add-Member -InputObject $manifest -MemberType NoteProperty -Name 'environmentManagement' -Value $EnvironmentManagement
    }
    return $manifest
}

function New-EnvManagement {
    return [pscustomobject]@{
        contractFile = 'laravel_app/.env.example'
        unknownKeyPolicy = 'review'
        keys = [pscustomobject]@{
            CONFIGURED_KEY = [pscustomobject]@{ strategy = 'prompt-if-missing'; secret = $false; overwrite = $false; required = $true; suggestedValue = '300' }
            SECRET_KEY = [pscustomobject]@{ strategy = 'generate-remote-if-missing'; secret = $true; overwrite = $false; required = $true }
            OLD_KEY = [pscustomobject]@{ strategy = 'keep-existing'; secret = $false; overwrite = $false; required = $false }
        }
    }
}

$tmp = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('deployment-analysis-extensions-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    $repo = Join-Path -Path $tmp -ChildPath 'repo'
    New-Item -ItemType Directory -Path (Join-Path $repo 'laravel_app/database/seeders') -Force | Out-Null
    Invoke-TestGit -RepositoryPath $repo -Arguments @('init') | Out-Null
    Invoke-TestGit -RepositoryPath $repo -Arguments @('config', 'user.email', 'deployment-engine@example.invalid') | Out-Null
    Invoke-TestGit -RepositoryPath $repo -Arguments @('config', 'user.name', 'Deployment Engine Tests') | Out-Null
    Set-Content -LiteralPath (Join-Path $repo 'laravel_app/.env.example') -Value "OLD_KEY=1`nSECRET_KEY=`n" -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $repo 'laravel_app/database/seeders/RoleSeeder.php') -Value "<?php`nuse App\Models\Role;`nRole::create(['name'=>'admin']);`n" -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $repo 'laravel_app/database/seeders/DeletedSeeder.php') -Value "<?php`nDB::table('old')->delete();`n" -Encoding UTF8
    Invoke-TestGit -RepositoryPath $repo -Arguments @('add', '.') | Out-Null
    Invoke-TestGit -RepositoryPath $repo -Arguments @('commit', '-m', 'baseline') | Out-Null
    $baseline = [string] (Invoke-TestGit -RepositoryPath $repo -Arguments @('rev-parse', 'HEAD') | Select-Object -First 1)

    Set-Content -LiteralPath (Join-Path $repo 'laravel_app/.env.example') -Value "SECRET_KEY=`nCONFIGURED_KEY=300`nUNKNOWN_KEY=x`n" -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $repo 'laravel_app/database/seeders/RoleSeeder.php') -Value "<?php`nuse App\Models\Role;`nRole::updateOrCreate(['name'=>'admin']);`nDB::table('roles')->upsert([]);`n" -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $repo 'laravel_app/database/seeders/TruncateSeeder.php') -Value "<?php`nDB::statement('DELETE FROM users');`nDB::table('roles')->truncate();`n" -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $repo 'laravel_app/database/seeders/DatabaseSeeder.php') -Value "<?php`nclass DatabaseSeeder { public function run(){ `$this->call([RoleSeeder::class]); } }`n" -Encoding UTF8
    Remove-Item -LiteralPath (Join-Path $repo 'laravel_app/database/seeders/DeletedSeeder.php') -Force
    Invoke-TestGit -RepositoryPath $repo -Arguments @('add', '-A') | Out-Null
    Invoke-TestGit -RepositoryPath $repo -Arguments @('commit', '-m', 'target') | Out-Null
    $target = [string] (Invoke-TestGit -RepositoryPath $repo -Arguments @('rev-parse', 'HEAD') | Select-Object -First 1)

    $manifest = New-TestManifest -EnvironmentManagement (New-EnvManagement)
    $changed = Get-ChangedArtifacts -RepositoryAnalysis ([pscustomobject]@{ repositoryRoot = $repo; baselineCommit = $baseline; targetCommit = $target })
    $classified = Get-ClassifiedArtifacts -Manifest $manifest -ChangedFiles $changed
    $env = Get-EnvironmentContractAnalysis -RepositoryRoot $repo -BaselineCommit $baseline -TargetCommit $target -ChangedFiles $changed -Manifest $manifest
    Assert-Equal $env.changed $true 'Changed .env.example must be detected.'
    Assert-True (@($env.addedKeys) -contains 'CONFIGURED_KEY') 'Existing addedKeys output must remain compatible.'
    Assert-True (@($env.removedKeys) -contains 'OLD_KEY') 'Existing removedKeys output must remain compatible.'
    Assert-True (@($env.unknownKeys) -contains 'UNKNOWN_KEY') 'Unknown keys must be listed.'
    Assert-Equal ((@($env.keyAssessments | Where-Object { $_.key -eq 'CONFIGURED_KEY' })[0]).contractStatus) 'configured' 'Configured key must use manifest rule.'
    Assert-Equal ((@($env.keyAssessments | Where-Object { $_.key -eq 'UNKNOWN_KEY' })[0]).recommendedAction) 'add-manifest-rule' 'Unknown key must recommend manifest rule.'
    Assert-Equal ((@($env.keyAssessments | Where-Object { $_.key -eq 'OLD_KEY' })[0]).recommendedAction) 'review-removal' 'Removed key must only recommend review.'
    Assert-True (-not (($env | ConvertTo-Json -Depth 20) -match 'super-secret')) 'Environment analysis must not emit secret values.'

    $seeder = Get-SeederReviewAnalysis -RepositoryRoot $repo -BaselineCommit $baseline -TargetCommit $target -ClassifiedFiles $classified
    Assert-Equal $seeder.changed $true 'Changed seeders must produce review.'
    Assert-True ($seeder.summary.total -ge 4) 'Seeder review must include added, modified and deleted seeders.'
    Assert-True ($seeder.summary.highRisk -ge 1) 'Destructive seeders must be high risk.'
    Assert-Equal ((@($seeder.files | Where-Object { $_.path -like '*RoleSeeder.php' })[0]).probableIdempotency) 'likely' 'updateOrCreate/upsert should be likely idempotent.'
    Assert-True (@((@($seeder.files | Where-Object { $_.path -like '*TruncateSeeder.php' })[0].destructiveOperations)).Count -gt 0) 'Destructive patterns must be detected.'
    Assert-True (@((@($seeder.files | Where-Object { $_.path -like '*RoleSeeder.php' })[0].affectedTables)) -contains 'roles') 'DB::table table names must be detected.'
    Assert-Equal ((@($seeder.files | Where-Object { $_.path -like '*DatabaseSeeder.php' })[0]).probablePurpose) 'orchestrator' 'DatabaseSeeder should be classified as orchestrator.'
    Assert-Equal ((@($seeder.files | Where-Object { $_.path -like '*DeletedSeeder.php' })[0]).probableIdempotency) 'not-applicable' 'Deleted seeder idempotency must be not-applicable.'

    $nonSeederReview = Get-SeederReviewAnalysis -RepositoryRoot $repo -BaselineCommit $baseline -TargetCommit $target -ClassifiedFiles @([pscustomobject]@{ status = 'M'; path = 'README.md'; previousPath = $null; classes = @('documentation') })
    Assert-Equal $nonSeederReview.changed $false 'Changed non-seeder files must not produce seeder review.'

    $decisions = Get-DeploymentDecisions -Manifest $manifest -ChangedFiles $changed -ClassifiedFiles $classified -EnvironmentAnalysis $env -SeederReview $seeder
    Assert-Equal $decisions.environmentReviewRequired $true 'Unknown keys must require environment review.'
    Assert-Equal $decisions.environmentContractIncomplete $true 'Unknown keys must mark contract incomplete.'
    Assert-Equal $decisions.seederReviewRequired $true 'Changed seeders must require review.'

    $manifestWithoutEnvironmentManagement = New-TestManifest
    $envWithoutContract = Get-EnvironmentContractAnalysis -RepositoryRoot $repo -BaselineCommit $baseline -TargetCommit $target -ChangedFiles $changed -Manifest $manifestWithoutEnvironmentManagement
    Assert-True (@($envWithoutContract.unknownKeys) -contains 'CONFIGURED_KEY') 'Manifest without environmentManagement must remain valid and mark new keys unknown.'

    $badSecret = New-EnvManagement
    $badSecret.keys.SECRET_KEY | Add-Member -MemberType NoteProperty -Name 'suggestedValue' -Value 'must-not-appear'
    Assert-ThrowsLike -Script { [void] (Get-EnvironmentManagementContract -Manifest (New-TestManifest -EnvironmentManagement $badSecret)) } -Pattern 'suggestedValue' -Message 'suggestedValue for secret rules must be rejected.'

    $badStrategy = New-EnvManagement
    $badStrategy.keys.CONFIGURED_KEY.strategy = 'magic'
    Assert-ThrowsLike -Script { [void] (Get-EnvironmentManagementContract -Manifest (New-TestManifest -EnvironmentManagement $badStrategy)) } -Pattern 'unknown environment strategy' -Message 'Unknown environment strategy must be rejected.'

    $badOverwrite = New-EnvManagement
    $badOverwrite.keys.SECRET_KEY.overwrite = $true
    Assert-ThrowsLike -Script { [void] (Get-EnvironmentManagementContract -Manifest (New-TestManifest -EnvironmentManagement $badOverwrite)) } -Pattern 'overwrite=true' -Message 'generate-remote-if-missing plus overwrite true must be rejected.'

    $badRegex = New-EnvManagement
    $badRegex.keys.CONFIGURED_KEY | Add-Member -MemberType NoteProperty -Name 'validationPattern' -Value '['
    Assert-ThrowsLike -Script { [void] (Get-EnvironmentManagementContract -Manifest (New-TestManifest -EnvironmentManagement $badRegex)) } -Pattern 'invalid validationPattern' -Message 'Invalid validationPattern must be rejected.'
} finally {
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
}

if ($script:failures.Count -gt 0) {
    Write-Host 'Deployment Analysis Extension tests failed:'
    $script:failures | ForEach-Object { Write-Host "- $_" }
    exit 1
}

Write-Host 'Deployment Analysis Extension tests passed.'
exit 0
