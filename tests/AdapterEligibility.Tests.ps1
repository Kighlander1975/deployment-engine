[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:failures = New-Object System.Collections.Generic.List[string]
$engineRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '..'))
$eligibilityPath = Join-Path -Path $engineRoot -ChildPath 'src/ps1/Resolve-AdapterEligibility.ps1'

. $eligibilityPath

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

function New-AssessedSide {
    param(
        [bool] $Present,
        [bool] $Available = $false,
        [string] $Path = '',
        [string] $Version = '',
        [string] $Status = 'not-found'
    )

    if (-not $Present) {
        return [pscustomobject]@{
            present = $false
        }
    }

    return [pscustomobject]@{
        present = $true
        available = $Available
        path = $Path
        version = $Version
        status = $Status
        diagnostic = ''
    }
}

function New-AssessedTool {
    param(
        [object] $Local = (New-AssessedSide -Present $true),
        [object] $Remote = (New-AssessedSide -Present $true),
        [string] $AssessmentStatus = 'not-found'
    )

    return [pscustomobject]@{
        local = $Local
        remote = $Remote
        assessment = [pscustomobject]@{
            status = $AssessmentStatus
            diagnostic = ''
        }
    }
}

function New-AssessedInventory {
    param(
        [hashtable] $LocalAvailable = @{},
        [hashtable] $RemoteAvailable = @{},
        [string] $LocalSourceStatus = 'completed',
        [string] $RemoteSourceStatus = 'completed',
        [bool] $LocalSourcePresent = $true,
        [bool] $RemoteSourcePresent = $true,
        [string] $Status = 'ready'
    )

    $tools = [ordered]@{}
    foreach ($toolId in Get-DeploymentToolIds) {
        $localPresent = $LocalSourcePresent
        $remotePresent = $RemoteSourcePresent
        $isLocalToolAvailable = ($LocalAvailable.ContainsKey($toolId) -and [bool] ($LocalAvailable[$toolId]))
        $isRemoteToolAvailable = ($RemoteAvailable.ContainsKey($toolId) -and [bool] ($RemoteAvailable[$toolId]))
        $assessmentStatus = if ($isLocalToolAvailable -and $isRemoteToolAvailable) {
            'available-both'
        } elseif ($isLocalToolAvailable -and $RemoteSourcePresent) {
            'available-local-only'
        } elseif ($isRemoteToolAvailable -and $LocalSourcePresent) {
            'available-remote-only'
        } elseif (-not $LocalSourcePresent -or -not $RemoteSourcePresent -or $LocalSourceStatus -ne 'completed' -or $RemoteSourceStatus -ne 'completed') {
            'unknown'
        } else {
            'not-found'
        }

        $tools[$toolId] = New-AssessedTool `
            -Local (New-AssessedSide -Present $localPresent -Available $isLocalToolAvailable -Path $(if ($isLocalToolAvailable) { "local:$toolId" } else { '' }) -Version '1.0' -Status $(if ($isLocalToolAvailable) { 'available' } else { 'not-found' })) `
            -Remote (New-AssessedSide -Present $remotePresent -Available $isRemoteToolAvailable -Path $(if ($isRemoteToolAvailable) { "remote:$toolId" } else { '' }) -Version '1.0' -Status $(if ($isRemoteToolAvailable) { 'available' } else { 'not-found' })) `
            -AssessmentStatus $assessmentStatus
    }

    return [pscustomobject]@{
        schemaVersion = '0.1'
        assessmentType = 'tool-inventory'
        status = $Status
        diagnostic = ''
        sources = [pscustomobject]@{
            local = [pscustomobject]@{ present = $LocalSourcePresent; status = if ($LocalSourcePresent) { $LocalSourceStatus } else { 'missing' } }
            remote = [pscustomobject]@{ present = $RemoteSourcePresent; status = if ($RemoteSourcePresent) { $RemoteSourceStatus } else { 'missing' } }
        }
        tools = [pscustomobject] $tools
        project = [pscustomobject]@{}
    }
}

function Get-Adapter {
    param([object] $Evaluation, [string] $AdapterId)
    return @($Evaluation.adapters | Where-Object { $_.adapterId -eq $AdapterId } | Select-Object -First 1)[0]
}

$zipBy7zUnzip = Resolve-DeploymentAdapterEligibility -Assessment (New-AssessedInventory -LocalAvailable @{ '7z' = $true } -RemoteAvailable @{ unzip = $true })
Assert-Equal (Get-Adapter -Evaluation $zipBy7zUnzip -AdapterId 'archive.zip').eligibilityStatus 'eligible' 'archive.zip must be eligible with local 7z and remote unzip.'
Assert-Equal $zipBy7zUnzip.status 'ready' 'At least one eligible adapter must make evaluation ready.'

$zipByZip7z = Resolve-DeploymentAdapterEligibility -Assessment (New-AssessedInventory -LocalAvailable @{ zip = $true } -RemoteAvailable @{ '7z' = $true })
Assert-Equal (Get-Adapter -Evaluation $zipByZip7z -AdapterId 'archive.zip').eligibilityStatus 'eligible' 'archive.zip must be eligible with local zip and remote 7z.'

$zipNoLocal = Resolve-DeploymentAdapterEligibility -Assessment (New-AssessedInventory -RemoteAvailable @{ unzip = $true })
Assert-Equal (Get-Adapter -Evaluation $zipNoLocal -AdapterId 'archive.zip').eligibilityStatus 'ineligible' 'archive.zip must be ineligible without local 7z or zip.'

$zipNoRemote = Resolve-DeploymentAdapterEligibility -Assessment (New-AssessedInventory -LocalAvailable @{ zip = $true })
Assert-Equal (Get-Adapter -Evaluation $zipNoRemote -AdapterId 'archive.zip').eligibilityStatus 'ineligible' 'archive.zip must be ineligible without remote unzip or 7z.'

$localMissing = Resolve-DeploymentAdapterEligibility -Assessment (New-AssessedInventory -LocalSourcePresent:$false -RemoteAvailable @{ unzip = $true } -Status 'incomplete')
Assert-Equal (Get-Adapter -Evaluation $localMissing -AdapterId 'archive.zip').eligibilityStatus 'unknown' 'Missing local inventory must make archive.zip unknown.'

$remoteIncomplete = Resolve-DeploymentAdapterEligibility -Assessment (New-AssessedInventory -LocalAvailable @{ zip = $true } -RemoteSourceStatus 'incomplete' -Status 'incomplete')
Assert-Equal (Get-Adapter -Evaluation $remoteIncomplete -AdapterId 'archive.zip').eligibilityStatus 'unknown' 'Incomplete remote inventory must make archive.zip unknown.'

$tarBy7zTar = Resolve-DeploymentAdapterEligibility -Assessment (New-AssessedInventory -LocalAvailable @{ '7z' = $true } -RemoteAvailable @{ tar = $true })
Assert-Equal (Get-Adapter -Evaluation $tarBy7zTar -AdapterId 'archive.tar').eligibilityStatus 'eligible' 'archive.tar must be eligible with local 7z and remote tar.'

$tarByTar7z = Resolve-DeploymentAdapterEligibility -Assessment (New-AssessedInventory -LocalAvailable @{ tar = $true } -RemoteAvailable @{ '7z' = $true })
Assert-Equal (Get-Adapter -Evaluation $tarByTar7z -AdapterId 'archive.tar').eligibilityStatus 'eligible' 'archive.tar must be eligible with local tar and remote 7z.'

$tarNoLocal = Resolve-DeploymentAdapterEligibility -Assessment (New-AssessedInventory -RemoteAvailable @{ tar = $true })
Assert-Equal (Get-Adapter -Evaluation $tarNoLocal -AdapterId 'archive.tar').eligibilityStatus 'ineligible' 'archive.tar must be ineligible without local 7z or tar.'

$tarNoRemote = Resolve-DeploymentAdapterEligibility -Assessment (New-AssessedInventory -LocalAvailable @{ tar = $true })
Assert-Equal (Get-Adapter -Evaluation $tarNoRemote -AdapterId 'archive.tar').eligibilityStatus 'ineligible' 'archive.tar must be ineligible without remote tar or 7z.'

$unknownTar = Resolve-DeploymentAdapterEligibility -Assessment (New-AssessedInventory -LocalAvailable @{ tar = $true } -RemoteSourcePresent:$false -Status 'incomplete')
Assert-Equal (Get-Adapter -Evaluation $unknownTar -AdapterId 'archive.tar').eligibilityStatus 'unknown' 'Missing remote inventory must make archive.tar unknown.'

$blocked = Resolve-DeploymentAdapterEligibility -Assessment (New-AssessedInventory)
Assert-Equal $blocked.status 'blocked' 'Only ineligible adapters must make evaluation blocked.'
Assert-Equal ((@($blocked.adapters) | ForEach-Object { $_.eligibilityStatus }) -join ',') 'ineligible,ineligible' 'Blocked evaluation must contain only ineligible adapters.'

$incomplete = Resolve-DeploymentAdapterEligibility -Assessment (New-AssessedInventory -LocalSourcePresent:$false -RemoteSourcePresent:$false -Status 'incomplete')
Assert-Equal $incomplete.status 'incomplete' 'No eligible adapter and at least one unknown adapter must make evaluation incomplete.'

$bothEligible = Resolve-DeploymentAdapterEligibility -Assessment (New-AssessedInventory -LocalAvailable @{ zip = $true; tar = $true } -RemoteAvailable @{ unzip = $true; tar = $true })
Assert-Equal $bothEligible.status 'ready' 'Eligible adapters must make evaluation ready.'
Assert-Equal (Get-Adapter -Evaluation $bothEligible -AdapterId 'archive.zip').eligibilityStatus 'eligible' 'archive.zip must remain an eligible candidate.'
Assert-Equal (Get-Adapter -Evaluation $bothEligible -AdapterId 'archive.tar').eligibilityStatus 'eligible' 'archive.tar must remain an eligible candidate.'
Assert-True (-not ($bothEligible.PSObject.Properties.Name -contains 'selectedAdapterId')) 'Eligibility evaluation must not expose a selected adapter field.'
Assert-Equal ((@($bothEligible.adapters) | ForEach-Object { $_.adapterId }) -join ',') 'archive.zip,archive.tar' 'Adapters must be ordered by deterministic priority.'

$zipAdapter = Get-Adapter -Evaluation $zipBy7zUnzip -AdapterId 'archive.zip'
Assert-Equal $zipAdapter.priority 100 'archive.zip priority must be exposed.'
Assert-Equal $zipAdapter.compatibility.status 'assumed' 'Compatibility must be assumed in V1.'
Assert-Equal $zipAdapter.compatibility.checked $false 'Compatibility must not be deeply checked in V1.'
$producer7zAvailable = (@($zipAdapter.producerRequirements.oneOf | Where-Object { $_.toolId -eq '7z' -and $_.state -eq 'available' }).Count -eq 1)
$consumerUnzipAvailable = (@($zipAdapter.consumerRequirements.oneOf | Where-Object { $_.toolId -eq 'unzip' -and $_.state -eq 'available' }).Count -eq 1)
Assert-True $producer7zAvailable 'Producer alternatives must expose checked tool states.'
Assert-True $consumerUnzipAvailable 'Consumer alternatives must expose checked tool states.'

$input = New-AssessedInventory -LocalAvailable @{ zip = $true } -RemoteAvailable @{ unzip = $true }
$before = $input | ConvertTo-Json -Depth 40
$evaluation = Resolve-DeploymentAdapterEligibility -Assessment $input
$evaluation.adapters[0].producerRequirements.oneOf[0].state = 'changed'
Assert-Equal ($input | ConvertTo-Json -Depth 40) $before 'Adapter eligibility evaluation must not mutate input.'

$invalidStatus = New-AssessedInventory
$invalidStatus.status = 'banana'
Assert-ThrowsLike -Script { Resolve-DeploymentAdapterEligibility -Assessment $invalidStatus | Out-Null } -Pattern "unsupported status 'banana'" -Message 'Invalid assessed inventory status must be rejected.'

$invalidToolStatus = New-AssessedInventory
$invalidToolStatus.tools.zip.local.status = 'banana'
Assert-ThrowsLike -Script { Resolve-DeploymentAdapterEligibility -Assessment $invalidToolStatus | Out-Null } -Pattern "unsupported status 'banana'" -Message 'Invalid assessed tool status must be rejected.'

$nullTools = New-AssessedInventory
$nullTools.tools = $null
Assert-ThrowsLike -Script { Resolve-DeploymentAdapterEligibility -Assessment $nullTools | Out-Null } -Pattern "field 'tools' must be an object" -Message 'Null assessed tools structure must be rejected.'

$unknownTool = New-AssessedInventory
Add-Member -InputObject $unknownTool.tools -MemberType NoteProperty -Name 'node' -Value (New-AssessedTool)
Assert-ThrowsLike -Script { Resolve-DeploymentAdapterEligibility -Assessment $unknownTool | Out-Null } -Pattern "unknown tool id 'node'" -Message 'Unknown assessed tool id must be rejected.'

Assert-ThrowsLike -Script { Get-DeploymentAdapterDefinition -AdapterId 'archive.unknown' | Out-Null } -Pattern 'Unknown deployment adapter id' -Message 'Unknown adapter id must be rejected.'

$badCatalog = [ordered]@{
    'archive.bad' = [pscustomobject]@{
        adapterId = 'archive.bad'
        priority = 300
        producer = New-AdapterRequirementGroup -Environment 'local' -Role 'producer' -OneOf @('missing-tool')
        consumer = New-AdapterRequirementGroup -Environment 'remote' -Role 'consumer' -OneOf @('tar')
    }
}
Assert-ThrowsLike -Script { Resolve-DeploymentAdapterEligibility -Assessment (New-AssessedInventory) -AdapterCatalog $badCatalog | Out-Null } -Pattern "unknown tool id 'missing-tool'" -Message 'Adapter definitions with unknown tool references must be rejected.'

$tmp = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('adapter-eligibility-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
$assessmentPath = Join-Path -Path $tmp -ChildPath 'assessment.json'
$outputPath = Join-Path -Path $tmp -ChildPath 'nested/evaluation.json'
New-AssessedInventory -LocalAvailable @{ zip = $true } -RemoteAvailable @{ unzip = $true } | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $assessmentPath -Encoding UTF8
$fileCountBeforeStdout = @(Get-ChildItem -LiteralPath $tmp -File -Recurse).Count
$stdoutJson = & $eligibilityPath -AssessmentPath $assessmentPath -Format Json
$fileCountAfterStdout = @(Get-ChildItem -LiteralPath $tmp -File -Recurse).Count
Assert-Equal (($stdoutJson | ConvertFrom-Json).evaluationType) 'adapter-eligibility' 'CLI without OutputPath must emit parseable JSON.'
Assert-Equal $fileCountAfterStdout $fileCountBeforeStdout 'CLI without OutputPath must not create files in the test run directory.'
& $eligibilityPath -AssessmentPath $assessmentPath -OutputPath $outputPath -Format Json | Out-Null
Assert-True (Test-Path -LiteralPath $outputPath -PathType Leaf) 'CLI invocation must create explicit output path.'
$cliEvaluation = Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json
Assert-Equal $cliEvaluation.evaluationType 'adapter-eligibility' 'CLI output must be adapter eligibility JSON.'
Assert-Equal $cliEvaluation.status 'ready' 'CLI output must contain expected status.'
Assert-True (-not ($cliEvaluation.PSObject.Properties.Name -contains 'selectedAdapterId')) 'CLI output must not expose a selected adapter field.'
Assert-True (-not ($cliEvaluation.PSObject.Properties.Name -contains 'commands')) 'CLI output must not contain generated commands.'
Assert-True (-not ($cliEvaluation.PSObject.Properties.Name -contains 'steps')) 'CLI output must not contain execution steps.'
Assert-ThrowsLike -Script { & $eligibilityPath -AssessmentPath $assessmentPath -Format Text | Out-Null } -Pattern 'only supports -Format Json' -Message 'CLI invalid format must be rejected.'

$invalidPath = Join-Path -Path $tmp -ChildPath 'invalid.json'
Set-Content -LiteralPath $invalidPath -Value '{ invalid json' -Encoding UTF8
Assert-ThrowsLike -Script { & $eligibilityPath -AssessmentPath $invalidPath -Format Json | Out-Null } -Pattern 'Invalid assessed tool inventory JSON' -Message 'CLI invalid input JSON must be rejected.'
Remove-Item -LiteralPath $tmp -Recurse -Force

if ($script:failures.Count -gt 0) {
    Write-Host 'Adapter Eligibility tests failed:'
    $script:failures | ForEach-Object { Write-Host "- $_" }
    exit 1
}

Write-Host 'Adapter Eligibility tests passed.'
exit 0
