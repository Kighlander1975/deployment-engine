[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:failures = New-Object System.Collections.Generic.List[string]
$engineRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '..'))
$assessmentPath = Join-Path -Path $engineRoot -ChildPath 'src/ps1/Resolve-ToolInventoryAssessment.ps1'

. $assessmentPath

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

function Assert-ThrowsLike {
    param(
        [scriptblock] $Script,
        [string] $Pattern,
        [string] $Message
    )

    try {
        & $Script
        $script:failures.Add($Message)
    } catch {
        Assert-True ($_.Exception.Message -match $Pattern) "$Message Actual error: $($_.Exception.Message)"
    }
}

function New-TestToolResult {
    param(
        [bool] $Available,
        [string] $Path = '',
        [string] $Version = '',
        [string] $Status = 'not-found',
        [string] $Diagnostic = ''
    )

    return [pscustomobject]@{
        available = $Available
        path = $Path
        version = $Version
        status = $Status
        diagnostic = $Diagnostic
    }
}

function New-TestToolMap {
    param([hashtable] $Overrides = @{})

    $tools = [ordered]@{}
    foreach ($toolId in Get-DeploymentToolIds) {
        if ($Overrides.ContainsKey($toolId)) {
            $tools[$toolId] = $Overrides[$toolId]
        } else {
            $tools[$toolId] = New-TestToolResult -Available $false -Status 'not-found'
        }
    }

    return [pscustomobject] $tools
}

function New-TestProjectInfo {
    param([bool] $WithPaths = $true)

    if ($WithPaths) {
        return [pscustomobject]@{
            available = $true
            path = 'C:\Project'
            artisan = [pscustomobject]@{ available = $true; path = 'C:\Project\artisan' }
            composerJson = [pscustomobject]@{ available = $true; path = 'C:\Project\composer.json' }
            packageJson = [pscustomobject]@{ available = $false; path = 'C:\Project\package.json' }
            deployVersion = [pscustomobject]@{ available = $false; path = 'C:\Project\.deploy-version' }
            deploymentProjectJson = [pscustomobject]@{ available = $true; path = 'C:\Project\deployment.project.json' }
        }
    }

    return [pscustomobject]@{
        available = $true
        artisan = [pscustomobject]@{ available = $true }
        composerJson = [pscustomobject]@{ available = $true }
        packageJson = [pscustomobject]@{ available = $false }
        deployVersion = [pscustomobject]@{ available = $false }
        deploymentProjectJson = [pscustomobject]@{ available = $true }
    }
}

function New-LocalInventory {
    param(
        [hashtable] $Overrides = @{},
        [string] $SchemaVersion = '0.1',
        [string] $Status = ''
    )

    $inventory = [pscustomobject]@{
        schemaVersion = $SchemaVersion
        generatedAt = '2026-07-26T12:00:00.0000000Z'
        platform = [pscustomobject]@{ os = 'windows'; architecture = 'x64'; shell = 'powershell' }
        project = New-TestProjectInfo
        tools = New-TestToolMap -Overrides $Overrides
    }

    if (-not [string]::IsNullOrWhiteSpace($Status)) {
        Add-Member -InputObject $inventory -MemberType NoteProperty -Name 'status' -Value $Status
    }

    return $inventory
}

function New-RemoteInventory {
    param(
        [hashtable] $Overrides = @{},
        [string] $Status = 'completed',
        [string] $SchemaVersion = '0.1'
    )

    return [pscustomobject]@{
        schemaVersion = $SchemaVersion
        environment = 'remote'
        discoveryType = 'remote'
        discoveryMethod = 'human'
        status = $Status
        diagnostic = ''
        planFingerprint = 'abc123'
        platform = [pscustomobject]@{ os = 'linux' }
        project = New-TestProjectInfo -WithPaths:$false
        tools = New-TestToolMap -Overrides $Overrides
    }
}

$local = New-LocalInventory -Overrides @{
    php = New-TestToolResult -Available $true -Path 'C:\php\php.exe' -Version '8.3.12' -Status 'available'
}
$remote = New-RemoteInventory -Overrides @{
    php = New-TestToolResult -Available $true -Path '/usr/bin/php' -Version '8.3.12' -Status 'available'
}
$assessment = New-ToolInventoryAssessment -LocalInventory $local -RemoteInventory $remote

Assert-Equal $assessment.schemaVersion '0.1' 'Assessment schema version must be stable.'
Assert-Equal $assessment.assessmentType 'tool-inventory' 'Assessment type must be tool-inventory.'
Assert-Equal $assessment.status 'ready' 'Complete local and remote inventories must be ready.'
Assert-Equal $assessment.sources.local.present $true 'Local source must be present.'
Assert-Equal $assessment.sources.remote.present $true 'Remote source must be present.'
Assert-Equal $assessment.tools.php.assessment.status 'available-both' 'PHP available on both sides must be available-both.'
Assert-Equal $assessment.tools.php.local.path 'C:\php\php.exe' 'Local path must stay separate.'
Assert-Equal $assessment.tools.php.remote.path '/usr/bin/php' 'Remote path must stay separate.'
Assert-Equal $assessment.tools.php.local.version '8.3.12' 'Local version must be preserved.'
Assert-Equal $assessment.tools.php.remote.version '8.3.12' 'Remote version must be preserved.'

$deepLocal = New-LocalInventory
Add-Member -InputObject $deepLocal.project -MemberType NoteProperty -Name 'extra' -Value ([pscustomobject]@{
    nested = [pscustomobject]@{ enabled = $true }
    values = @('one', 'two')
})
$deepLocalAssessment = New-ToolInventoryAssessment -LocalInventory $deepLocal
$deepLocalAssessment.project.local.artisan.available = $false
$deepLocalAssessment.project.local.extra.nested.enabled = $false
$deepLocalAssessment.project.local.extra.values[0] = 'changed'
Assert-Equal $deepLocal.project.artisan.available $true 'Mutating assessed local project data must not mutate the source inventory.'
Assert-Equal $deepLocal.project.extra.nested.enabled $true 'Mutating assessed local nested project data must not mutate the source inventory.'
Assert-Equal $deepLocal.project.extra.values[0] 'one' 'Mutating assessed local project arrays must not mutate the source inventory.'

$deepRemote = New-RemoteInventory
Add-Member -InputObject $deepRemote.project -MemberType NoteProperty -Name 'extra' -Value ([pscustomobject]@{
    nested = [pscustomobject]@{ enabled = $true }
    values = @('alpha', 'beta')
})
$deepRemoteAssessment = New-ToolInventoryAssessment -RemoteInventory $deepRemote
$deepRemoteAssessment.project.remote.artisan.available = $false
$deepRemoteAssessment.project.remote.extra.nested.enabled = $false
$deepRemoteAssessment.project.remote.extra.values[0] = 'changed'
Assert-Equal $deepRemote.project.artisan.available $true 'Mutating assessed remote project data must not mutate the source inventory.'
Assert-Equal $deepRemote.project.extra.nested.enabled $true 'Mutating assessed remote nested project data must not mutate the source inventory.'
Assert-Equal $deepRemote.project.extra.values[0] 'alpha' 'Mutating assessed remote project arrays must not mutate the source inventory.'

$localOnlyAssessment = New-ToolInventoryAssessment -LocalInventory $local
Assert-Equal $localOnlyAssessment.status 'incomplete' 'Only local inventory must produce incomplete assessment.'
Assert-Equal $localOnlyAssessment.sources.remote.present $false 'Missing remote source must be explicit.'
Assert-Equal $localOnlyAssessment.tools.php.assessment.status 'unknown' 'Missing remote source must make tool assessment unknown.'
Assert-Equal $localOnlyAssessment.tools.php.local.available $true 'Local result must remain visible.'
Assert-Equal $localOnlyAssessment.tools.php.remote.present $false 'Remote result must not be invented.'

$remoteOnlyAssessment = New-ToolInventoryAssessment -RemoteInventory $remote
Assert-Equal $remoteOnlyAssessment.status 'incomplete' 'Only remote inventory must produce incomplete assessment.'
Assert-Equal $remoteOnlyAssessment.sources.local.present $false 'Missing local source must be explicit.'
Assert-Equal $remoteOnlyAssessment.tools.php.assessment.status 'unknown' 'Missing local source must make tool assessment unknown.'
Assert-Equal $remoteOnlyAssessment.tools.php.remote.available $true 'Remote result must remain visible.'

Assert-ThrowsLike -Script { New-ToolInventoryAssessment | Out-Null } -Pattern 'At least one tool inventory' -Message 'Missing both inventories must be rejected.'

$localPhpAvailable = New-LocalInventory -Overrides @{ php = New-TestToolResult -Available $true -Path 'C:\php\php.exe' -Version '8.3.12' -Status 'available' }
$remotePhpMissing = New-RemoteInventory -Overrides @{ php = New-TestToolResult -Available $false -Status 'not-found' }
$localOnlyTool = New-ToolInventoryAssessment -LocalInventory $localPhpAvailable -RemoteInventory $remotePhpMissing
Assert-Equal $localOnlyTool.tools.php.assessment.status 'available-local-only' 'Local available and remote not-found must be available-local-only.'

$localPhpMissing = New-LocalInventory -Overrides @{ php = New-TestToolResult -Available $false -Status 'not-found' }
$remotePhpAvailable = New-RemoteInventory -Overrides @{ php = New-TestToolResult -Available $true -Path '/usr/bin/php' -Version '8.3.12' -Status 'available' }
$remoteOnlyTool = New-ToolInventoryAssessment -LocalInventory $localPhpMissing -RemoteInventory $remotePhpAvailable
Assert-Equal $remoteOnlyTool.tools.php.assessment.status 'available-remote-only' 'Remote available and local not-found must be available-remote-only.'

$bothMissingTool = New-ToolInventoryAssessment -LocalInventory $localPhpMissing -RemoteInventory $remotePhpMissing
Assert-Equal $bothMissingTool.tools.php.assessment.status 'not-found' 'Not found on both checked sources must be not-found.'

$degradedVersion = New-ToolInventoryAssessment -LocalInventory (New-LocalInventory -Overrides @{ php = New-TestToolResult -Available $true -Path 'C:\php\php.exe' -Status 'version-unavailable' -Diagnostic 'Version probe produced no readable output.' }) -RemoteInventory $remotePhpAvailable
Assert-Equal $degradedVersion.tools.php.assessment.status 'degraded' 'Unreadable version on available tool must be degraded.'
Assert-Equal $degradedVersion.tools.php.local.available $true 'Degraded source availability must not be changed.'

$degradedProbe = New-ToolInventoryAssessment -LocalInventory (New-LocalInventory -Overrides @{ php = New-TestToolResult -Available $true -Path 'C:\php\php.exe' -Status 'probe-failed' -Diagnostic 'Probe failed.' }) -RemoteInventory $remotePhpAvailable
Assert-Equal $degradedProbe.tools.php.assessment.status 'degraded' 'Probe failure on available tool must be degraded.'
Assert-Equal $degradedProbe.tools.composer.assessment.status 'not-found' 'Other tools must not inherit a probe failure.'

$remoteIncomplete = New-RemoteInventory -Overrides @{ php = New-TestToolResult -Available $true -Path '/usr/bin/php' -Version '8.3.12' -Status 'available' } -Status 'incomplete'
$remoteIncomplete.tools.PSObject.Properties.Remove('composer')
$incompleteAssessment = New-ToolInventoryAssessment -LocalInventory $local -RemoteInventory $remoteIncomplete
Assert-Equal $incompleteAssessment.status 'incomplete' 'Incomplete remote inventory must make assessment incomplete.'
Assert-Equal $incompleteAssessment.tools.php.assessment.status 'available-both' 'Available tool data from incomplete inventory must still be processed.'
Assert-Equal $incompleteAssessment.tools.composer.assessment.status 'unknown' 'Missing tool result from incomplete inventory must be unknown.'

Assert-ThrowsLike -Script { New-ToolInventoryAssessment -LocalInventory (New-LocalInventory -SchemaVersion '9.9') | Out-Null } -Pattern 'unsupported schemaVersion' -Message 'Invalid schemaVersion must be rejected.'

Assert-ThrowsLike -Script { New-ToolInventoryAssessment -LocalInventory (New-LocalInventory -Status 'banana') | Out-Null } -Pattern "Local inventory validation failed: unsupported status 'banana'" -Message 'Unknown local inventory status must be rejected.'
Assert-ThrowsLike -Script { New-ToolInventoryAssessment -RemoteInventory (New-RemoteInventory -Status 'banana') | Out-Null } -Pattern "Remote inventory validation failed: unsupported status 'banana'" -Message 'Unknown remote inventory status must be rejected.'
Assert-ThrowsLike -Script { New-ToolInventoryAssessment -LocalInventory (New-LocalInventory -Overrides @{ php = New-TestToolResult -Available $true -Path 'C:\php\php.exe' -Status 'banana' }) | Out-Null } -Pattern "Local inventory tool 'php' validation failed: unsupported status 'banana'" -Message 'Unknown local tool status must be rejected.'
Assert-ThrowsLike -Script { New-ToolInventoryAssessment -RemoteInventory (New-RemoteInventory -Overrides @{ php = New-TestToolResult -Available $true -Path '/usr/bin/php' -Status 'banana' }) | Out-Null } -Pattern "Remote inventory tool 'php' validation failed: unsupported status 'banana'" -Message 'Unknown remote tool status must be rejected.'

$supportedLocalStatus = New-ToolInventoryAssessment -LocalInventory (New-LocalInventory -Status 'completed')
Assert-Equal $supportedLocalStatus.sources.local.status 'completed' 'Supported local completed status must remain valid.'
$supportedLocalIncomplete = New-ToolInventoryAssessment -LocalInventory (New-LocalInventory -Status 'incomplete')
Assert-Equal $supportedLocalIncomplete.status 'incomplete' 'Supported local incomplete status must remain valid.'
$localWithoutStatus = New-ToolInventoryAssessment -LocalInventory (New-LocalInventory)
Assert-Equal $localWithoutStatus.sources.local.status 'completed' 'Local inventory without global status must be interpreted as completed.'
$supportedRemoteIncomplete = New-ToolInventoryAssessment -RemoteInventory (New-RemoteInventory -Status 'incomplete')
Assert-Equal $supportedRemoteIncomplete.status 'incomplete' 'Remote incomplete status must remain valid and make assessment incomplete.'

$wrongLocal = New-RemoteInventory
Assert-ThrowsLike -Script { New-ToolInventoryAssessment -LocalInventory $wrongLocal | Out-Null } -Pattern 'remote inventory metadata' -Message 'Remote inventory must not be accepted as local.'
$wrongRemote = New-LocalInventory
Assert-ThrowsLike -Script { New-ToolInventoryAssessment -RemoteInventory $wrongRemote | Out-Null } -Pattern 'missing required field' -Message 'Local inventory must not be accepted as remote.'

$missingTools = New-LocalInventory
$missingTools.PSObject.Properties.Remove('tools')
Assert-ThrowsLike -Script { New-ToolInventoryAssessment -LocalInventory $missingTools | Out-Null } -Pattern 'missing required field ''tools''' -Message 'Missing tools structure must be rejected.'

$nullLocalTools = New-LocalInventory
$nullLocalTools.tools = $null
Assert-ThrowsLike -Script { New-ToolInventoryAssessment -LocalInventory $nullLocalTools | Out-Null } -Pattern "Local inventory validation failed: field 'tools' must be an object" -Message 'Local tools=null must be rejected.'

$nullRemoteTools = New-RemoteInventory
$nullRemoteTools.tools = $null
Assert-ThrowsLike -Script { New-ToolInventoryAssessment -RemoteInventory $nullRemoteTools | Out-Null } -Pattern "Remote inventory validation failed: field 'tools' must be an object" -Message 'Remote tools=null must be rejected.'

$scalarLocalTools = New-LocalInventory
$scalarLocalTools.tools = 'invalid'
Assert-ThrowsLike -Script { New-ToolInventoryAssessment -LocalInventory $scalarLocalTools | Out-Null } -Pattern "Local inventory validation failed: field 'tools' must be an object" -Message 'Scalar tools value must be rejected.'

$missingToolId = New-LocalInventory
$missingToolId.tools.PSObject.Properties.Remove('php')
Assert-ThrowsLike -Script { New-ToolInventoryAssessment -LocalInventory $missingToolId | Out-Null } -Pattern 'missing required tool result' -Message 'Completed inventory with missing known tool id must be rejected.'

$unknownToolId = New-LocalInventory
Add-Member -InputObject $unknownToolId.tools -MemberType NoteProperty -Name 'node' -Value (New-TestToolResult -Available $true -Path 'C:\node.exe' -Version '22.0.0' -Status 'available')
Assert-ThrowsLike -Script { New-ToolInventoryAssessment -LocalInventory $unknownToolId | Out-Null } -Pattern 'unknown tool id' -Message 'Unknown additional tool id must be rejected.'

$beforeLocal = $local | ConvertTo-Json -Depth 30
$beforeRemote = $remote | ConvertTo-Json -Depth 30
[void] (New-ToolInventoryAssessment -LocalInventory $local -RemoteInventory $remote)
Assert-Equal ($local | ConvertTo-Json -Depth 30) $beforeLocal 'Local input must not be mutated.'
Assert-Equal ($remote | ConvertTo-Json -Depth 30) $beforeRemote 'Remote input must not be mutated.'

Assert-Equal (($assessment.tools.PSObject.Properties.Name) -join ',') ((Get-DeploymentToolIds) -join ',') 'Assessment tool order must follow DeploymentTools.ps1.'

$versionDiff = New-ToolInventoryAssessment -LocalInventory (New-LocalInventory -Overrides @{ php = New-TestToolResult -Available $true -Path 'C:\php\php.exe' -Version '8.3.11' -Status 'available' }) -RemoteInventory $remotePhpAvailable
Assert-Equal $versionDiff.tools.php.assessment.status 'available-both' 'Different versions alone must not change availability status.'
Assert-True ($versionDiff.tools.php.assessment.diagnostic -match 'versions differ') 'Different versions may produce a neutral diagnostic.'
Assert-Equal $versionDiff.tools.php.local.version '8.3.11' 'Local version must remain separate.'
Assert-Equal $versionDiff.tools.php.remote.version '8.3.12' 'Remote version must remain separate.'

Assert-Equal $assessment.project.local.present $true 'Local project info must be present.'
Assert-Equal $assessment.project.remote.present $true 'Remote project info must be present.'
Assert-Equal $localOnlyAssessment.project.remote.present $false 'Missing remote project source must be explicit.'

$tmp = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('tool-assessment-' + [guid]::NewGuid().ToString('N'))
$outputPath = Join-Path -Path $tmp -ChildPath 'nested/assessment.json'
$json = Write-ToolInventoryAssessmentJson -Assessment $assessment -OutputPath $outputPath
Assert-True (Test-Path -LiteralPath $outputPath -PathType Leaf) 'Assessment output path must be created.'
Assert-Equal ((Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json).assessmentType) 'tool-inventory' 'Assessment output must be parseable JSON.'
Assert-Equal (($json | ConvertFrom-Json).status) 'ready' 'Returned JSON must be parseable.'
Remove-Item -LiteralPath $tmp -Recurse -Force

if ($script:failures.Count -gt 0) {
    Write-Host 'Tool Inventory Assessment tests failed:'
    $script:failures | ForEach-Object { Write-Host "- $_" }
    exit 1
}

Write-Host 'Tool Inventory Assessment tests passed.'
exit 0
