[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:failures = New-Object System.Collections.Generic.List[string]
$engineRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '..'))
$discoveryPath = Join-Path -Path $engineRoot -ChildPath 'src/ps1/Invoke-ToolDiscovery.ps1'

. $discoveryPath

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

function New-FinderResult {
    param(
        [bool] $Found,
        [string] $CommandName = '',
        [string] $Path = ''
    )

    return [pscustomobject]@{
        found = $Found
        commandName = $CommandName
        path = $Path
        allPaths = if ($Found) { @($Path) } else { @() }
    }
}

$toolState = @{
    php = [pscustomobject]@{ found = $true; path = 'C:\Tools\php.exe'; stdout = "PHP 8.3.0`n"; stderr = ''; failed = $false; timedOut = $false; diagnostic = '' }
    composer = [pscustomobject]@{ found = $false; path = ''; stdout = ''; stderr = ''; failed = $false; timedOut = $false; diagnostic = '' }
    docker = [pscustomobject]@{ found = $true; path = 'C:\Tools\docker.exe'; stdout = ''; stderr = ''; failed = $false; timedOut = $false; diagnostic = '' }
    '7z' = [pscustomobject]@{ found = $true; path = 'C:\Tools\7z.exe'; stdout = ''; stderr = ''; failed = $true; timedOut = $true; diagnostic = 'Probe timed out after 5 seconds.' }
    zip = [pscustomobject]@{ found = $true; path = 'C:\Tools\zip.exe'; stdout = "Zip 3.0`n"; stderr = ''; failed = $false; timedOut = $false; diagnostic = '' }
    unzip = [pscustomobject]@{ found = $false; path = ''; stdout = ''; stderr = ''; failed = $false; timedOut = $false; diagnostic = '' }
    tar = [pscustomobject]@{ found = $true; path = 'C:\Tools\tar.exe'; stdout = "tar (GNU tar) 1.34`n"; stderr = ''; failed = $false; timedOut = $false; diagnostic = '' }
}
$script:probeCalls = New-Object System.Collections.Generic.List[object]
$finder = {
    param($ToolDefinition)
    $state = $toolState[$ToolDefinition.toolId]
    if ($state.found) {
        return New-FinderResult -Found $true -CommandName $ToolDefinition.commandNames[0] -Path $state.path
    }

    return New-FinderResult -Found $false
}
$probe = {
    param($ToolDefinition, $Executable)
    $script:probeCalls.Add([pscustomobject]@{
        toolId = $ToolDefinition.toolId
        path = $Executable.path
        arguments = @($ToolDefinition.probeArguments)
    })
    $state = $toolState[$ToolDefinition.toolId]
    return [pscustomobject]@{
        exitCode = if ($state.failed) { $null } else { 0 }
        stdout = $state.stdout
        stderr = $state.stderr
        timedOut = $state.timedOut
        failed = $state.failed
        diagnostic = $state.diagnostic
    }
}

$fixedNow = [datetime]::Parse('2026-07-26T12:00:00Z').ToUniversalTime()
$result = New-ToolDiscoveryResult -Finder $finder -Probe $probe -NowUtc $fixedNow

Assert-Equal $result.schemaVersion '0.1' 'Discovery result must expose schema version.'
Assert-Equal $result.generatedAt '2026-07-26T12:00:00.0000000Z' 'Discovery result must use injected deterministic timestamp.'
Assert-Equal $result.tools.php.available $true 'Found tool must be available.'
Assert-Equal $result.tools.php.path 'C:\Tools\php.exe' 'Found tool path must be used.'
Assert-Equal $result.tools.php.version 'PHP 8.3.0' 'Version must use first readable line.'
Assert-Equal $result.tools.php.status 'available' 'Found tool with version must be available.'
Assert-Equal $result.tools.composer.available $false 'Missing tool must not be available.'
Assert-Equal $result.tools.composer.status 'not-found' 'Missing tool must be not-found.'
Assert-Equal $result.tools.composer.path '' 'Missing tool path must be empty.'
Assert-Equal $result.tools.docker.available $true 'Tool with unreadable version must be available when executable was found.'
Assert-Equal $result.tools.docker.status 'version-unavailable' 'Tool without readable version must be version-unavailable.'
Assert-Equal $result.tools.'7z'.available $true 'Failed probe must be available when executable was found.'
Assert-Equal $result.tools.'7z'.status 'probe-failed' 'Failed probe must be probe-failed.'
Assert-True ($result.tools.'7z'.diagnostic -match 'timed out') 'Failed probe must include diagnostic.'
Assert-Equal $result.tools.unzip.available $false 'Missing unzip must not be available.'
Assert-Equal $result.tools.unzip.status 'not-found' 'Missing unzip must be not-found.'
Assert-Equal ($result.tools.PSObject.Properties.Name -join ',') 'php,composer,docker,7z,zip,unzip,tar' 'Tools must be emitted in deterministic catalog order.'
Assert-True (-not ($result.PSObject.Properties.Name -contains 'errors')) 'Discovery result must not expose unused global errors.'

$toolState.unzip = [pscustomobject]@{ found = $true; path = 'C:\Tools\unzip.exe'; stdout = "UnZip 6.00 of 20 April 2009`n"; stderr = ''; failed = $false; timedOut = $false; diagnostic = '' }
$unzipPresentResult = New-ToolDiscoveryResult -Finder $finder -Probe $probe -NowUtc $fixedNow
Assert-Equal $unzipPresentResult.tools.unzip.available $true 'Found unzip must be available.'
Assert-Equal $unzipPresentResult.tools.unzip.path 'C:\Tools\unzip.exe' 'Found unzip path must be used.'
Assert-Equal $unzipPresentResult.tools.unzip.status 'available' 'Found unzip with version output must be available.'

try {
    [void] (Get-DeploymentToolDefinition -ToolId 'unknown')
    $script:failures.Add('Unknown tool id must be rejected.')
} catch {
    Assert-True ($_.Exception.Message -match 'Unknown deployment tool id') 'Unknown tool id must produce a controlled error.'
}

$missingProjectPath = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath 'deployment-engine-missing-project'
try {
    [void] (New-ToolDiscoveryResult -ProjectPath $missingProjectPath -Finder $finder -Probe $probe -NowUtc $fixedNow)
    $script:failures.Add('Invalid explicit project path must be rejected.')
} catch {
    Assert-True ($_.Exception.Message -match 'Project path does not exist') 'Invalid project path must produce a controlled error.'
}

$projectPath = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('deployment-engine-discovery-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $projectPath | Out-Null
New-Item -ItemType File -Path (Join-Path -Path $projectPath -ChildPath 'artisan') | Out-Null
New-Item -ItemType File -Path (Join-Path -Path $projectPath -ChildPath 'deployment.project.json') | Out-Null
$projectResult = New-ToolDiscoveryResult -ProjectPath $projectPath -Finder $finder -Probe $probe -NowUtc $fixedNow
Assert-True $projectResult.project.available 'Existing project path must be available.'
Assert-True $projectResult.project.artisan.available 'Artisan file must be detected.'
Assert-Equal $projectResult.project.artisan.path (Join-Path -Path $projectPath -ChildPath 'artisan') 'Artisan path must be reported.'
Assert-True $projectResult.project.deploymentProjectJson.available 'deployment.project.json must be detected.'
Remove-Item -LiteralPath $projectPath -Recurse -Force

$projectWithoutArtisan = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('deployment-engine-discovery-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $projectWithoutArtisan | Out-Null
$projectWithoutArtisanResult = New-ToolDiscoveryResult -ProjectPath $projectWithoutArtisan -Finder $finder -Probe $probe -NowUtc $fixedNow
Assert-Equal $projectWithoutArtisanResult.project.artisan.available $false 'Missing artisan must be a normal result.'
Remove-Item -LiteralPath $projectWithoutArtisan -Recurse -Force

$jsonA = (New-ToolDiscoveryResult -Finder $finder -Probe $probe -NowUtc $fixedNow) | ConvertTo-Json -Depth 20
$jsonB = (New-ToolDiscoveryResult -Finder $finder -Probe $probe -NowUtc $fixedNow) | ConvertTo-Json -Depth 20
Assert-Equal $jsonA $jsonB 'Discovery output must be deterministic with injected timestamp.'

foreach ($call in $script:probeCalls) {
    $definition = Get-DeploymentToolDefinition -ToolId $call.toolId
    Assert-Equal ($call.arguments -join ',') (@($definition.probeArguments) -join ',') 'Probe arguments must come from allowlisted tool definition.'
}
Assert-True (-not ((Get-Command Invoke-ToolDiscovery).Parameters.Keys -contains 'Command')) 'Discovery must not expose a free command parameter.'

if ($script:failures.Count -gt 0) {
    Write-Host 'Tool Discovery tests failed:'
    $script:failures | ForEach-Object { Write-Host "- $_" }
    exit 1
}

Write-Host 'Tool Discovery tests passed.'
exit 0
