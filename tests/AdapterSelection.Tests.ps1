[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:failures = New-Object System.Collections.Generic.List[string]
$engineRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '..'))
$selectionPath = Join-Path -Path $engineRoot -ChildPath 'src/ps1/Select-DeploymentAdapter.ps1'
$cliPath = Join-Path -Path $engineRoot -ChildPath 'bin/deployment-engine.ps1'

. $selectionPath

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

function New-TestAdapterCatalog {
    param(
        [int] $ZipPriority = 100,
        [int] $TarPriority = 200
    )

    return [ordered]@{
        'archive.zip' = [pscustomobject]@{
            adapterId = 'archive.zip'
            priority = $ZipPriority
        }
        'archive.tar' = [pscustomobject]@{
            adapterId = 'archive.tar'
            priority = $TarPriority
        }
    }
}

function New-TestEligibilityAdapter {
    param(
        [Parameter(Mandatory = $true)][string] $AdapterId,
        [Parameter(Mandatory = $true)][int] $Priority,
        [Parameter(Mandatory = $true)][string] $EligibilityStatus
    )

    return [pscustomobject]@{
        adapterId = $AdapterId
        priority = $Priority
        eligibilityStatus = $EligibilityStatus
        producerRequirements = [pscustomobject]@{}
        consumerRequirements = [pscustomobject]@{}
        compatibility = [pscustomobject]@{
            status = 'assumed'
            checked = $false
        }
        diagnostic = ''
    }
}

function New-TestEligibilityEvaluation {
    param(
        [string] $ZipStatus = 'eligible',
        [string] $TarStatus = 'eligible',
        [object] $AdapterCatalog = (New-TestAdapterCatalog),
        [string] $Status
    )

    if ([string]::IsNullOrWhiteSpace($Status)) {
        $statuses = @($ZipStatus, $TarStatus)
        $Status = if ($statuses -contains 'eligible') {
            'ready'
        } elseif ($statuses -contains 'unknown') {
            'incomplete'
        } else {
            'blocked'
        }
    }

    return [pscustomobject]@{
        schemaVersion = '0.1'
        evaluationType = 'adapter-eligibility'
        status = $Status
        diagnostic = ''
        adapters = @(
            New-TestEligibilityAdapter -AdapterId 'archive.zip' -Priority ([int] $AdapterCatalog['archive.zip'].priority) -EligibilityStatus $ZipStatus
            New-TestEligibilityAdapter -AdapterId 'archive.tar' -Priority ([int] $AdapterCatalog['archive.tar'].priority) -EligibilityStatus $TarStatus
        )
    }
}

function Get-Candidate {
    param([object] $Selection, [string] $AdapterId)
    return @($Selection.candidates | Where-Object { $_.adapterId -eq $AdapterId } | Select-Object -First 1)[0]
}

function Assert-NoExecutionSurface {
    param([object] $Selection)

    Assert-True (-not ($Selection.PSObject.Properties.Name -contains 'commands')) 'Selection output must not expose commands.'
    Assert-True (-not ($Selection.PSObject.Properties.Name -contains 'steps')) 'Selection output must not expose steps.'
    $json = $Selection | ConvertTo-Json -Depth 40
    Assert-True (-not ($json -match '"commands"|"steps"|"command"|"executionSteps"')) 'Selection output must not contain execution instructions.'
}

$bothEligible = Resolve-DeploymentAdapterSelection -EligibilityEvaluation (New-TestEligibilityEvaluation)
Assert-Equal $bothEligible.status 'selected' 'Both eligible adapters must produce selected status.'
Assert-Equal $bothEligible.selectedAdapterId 'archive.zip' 'archive.zip must be selected when both adapters are eligible.'
Assert-Equal (@($bothEligible.candidates | Where-Object { $_.selected }).Count) 1 'Exactly one candidate must be selected.'
Assert-Equal ((@($bothEligible.candidates) | ForEach-Object { $_.adapterId }) -join ',') 'archive.zip,archive.tar' 'Candidates must be deterministically ordered.'
Assert-NoExecutionSurface -Selection $bothEligible

$onlyZip = Resolve-DeploymentAdapterSelection -EligibilityEvaluation (New-TestEligibilityEvaluation -TarStatus 'ineligible')
Assert-Equal $onlyZip.status 'selected' 'Only ZIP eligible must produce selected status.'
Assert-Equal $onlyZip.selectedAdapterId 'archive.zip' 'Only ZIP eligible must select archive.zip.'

$onlyTar = Resolve-DeploymentAdapterSelection -EligibilityEvaluation (New-TestEligibilityEvaluation -ZipStatus 'ineligible')
Assert-Equal $onlyTar.status 'selected' 'Only TAR eligible must produce selected status.'
Assert-Equal $onlyTar.selectedAdapterId 'archive.tar' 'Only TAR eligible must select archive.tar.'

$zipUnknownTarEligible = Resolve-DeploymentAdapterSelection -EligibilityEvaluation (New-TestEligibilityEvaluation -ZipStatus 'unknown' -TarStatus 'eligible')
Assert-Equal $zipUnknownTarEligible.selectedAdapterId 'archive.tar' 'TAR must be selected when ZIP is unknown and TAR is eligible.'
Assert-Equal (Get-Candidate -Selection $zipUnknownTarEligible -AdapterId 'archive.zip').eligibilityStatus 'unknown' 'Unknown ZIP candidate must remain visible.'
Assert-Equal (Get-Candidate -Selection $zipUnknownTarEligible -AdapterId 'archive.zip').selected $false 'Unknown ZIP candidate must not be selected.'

$zipIneligibleTarEligible = Resolve-DeploymentAdapterSelection -EligibilityEvaluation (New-TestEligibilityEvaluation -ZipStatus 'ineligible' -TarStatus 'eligible')
Assert-Equal $zipIneligibleTarEligible.selectedAdapterId 'archive.tar' 'TAR must be selected when ZIP is ineligible and TAR is eligible.'

$incomplete = Resolve-DeploymentAdapterSelection -EligibilityEvaluation (New-TestEligibilityEvaluation -ZipStatus 'unknown' -TarStatus 'ineligible')
Assert-Equal $incomplete.status 'incomplete' 'No eligible and at least one unknown adapter must produce incomplete status.'
Assert-Equal $incomplete.selectedAdapterId '' 'Incomplete selection must not select an adapter.'
Assert-Equal (@($incomplete.candidates | Where-Object { $_.selected }).Count) 0 'Incomplete selection must not mark any candidate selected.'
Assert-Equal @($incomplete.candidates).Count 2 'Incomplete selection must still expose all candidates.'

$blocked = Resolve-DeploymentAdapterSelection -EligibilityEvaluation (New-TestEligibilityEvaluation -ZipStatus 'ineligible' -TarStatus 'ineligible')
Assert-Equal $blocked.status 'blocked' 'All ineligible adapters must produce blocked status.'
Assert-Equal $blocked.selectedAdapterId '' 'Blocked selection must not select an adapter.'
Assert-Equal (@($blocked.candidates | Where-Object { $_.selected }).Count) 0 'Blocked selection must not mark any candidate selected.'
Assert-Equal @($blocked.candidates).Count 2 'Blocked selection must still expose all candidates.'

$reversed = New-TestEligibilityEvaluation
$reversed.adapters = @($reversed.adapters[1], $reversed.adapters[0])
$reversedSelection = Resolve-DeploymentAdapterSelection -EligibilityEvaluation $reversed
Assert-Equal $reversedSelection.selectedAdapterId 'archive.zip' 'Input order must not affect selected adapter.'
Assert-Equal ((@($reversedSelection.candidates) | ForEach-Object { $_.adapterId }) -join ',') 'archive.zip,archive.tar' 'Input order must not affect candidate order.'

$tieCatalog = [ordered]@{
    'archive.beta' = [pscustomobject]@{ adapterId = 'archive.beta'; priority = 100 }
    'archive.alpha' = [pscustomobject]@{ adapterId = 'archive.alpha'; priority = 100 }
}
$tieEvaluation = [pscustomobject]@{
    schemaVersion = '0.1'
    evaluationType = 'adapter-eligibility'
    status = 'ready'
    diagnostic = ''
    adapters = @(
        New-TestEligibilityAdapter -AdapterId 'archive.beta' -Priority 100 -EligibilityStatus 'eligible'
        New-TestEligibilityAdapter -AdapterId 'archive.alpha' -Priority 100 -EligibilityStatus 'eligible'
    )
}
$tieSelection = Resolve-DeploymentAdapterSelection -EligibilityEvaluation $tieEvaluation -AdapterCatalog $tieCatalog
Assert-Equal $tieSelection.selectedAdapterId 'archive.alpha' 'Alphabetically smaller adapterId must win equal priority ties.'
Assert-Equal ((@($tieSelection.candidates) | ForEach-Object { $_.adapterId }) -join ',') 'archive.alpha,archive.beta' 'Tie candidates must be ordered by adapterId.'

$unknownAdapter = New-TestEligibilityEvaluation
$unknownAdapter.adapters += New-TestEligibilityAdapter -AdapterId 'archive.rar' -Priority 300 -EligibilityStatus 'eligible'
Assert-ThrowsLike -Script { Resolve-DeploymentAdapterSelection -EligibilityEvaluation $unknownAdapter | Out-Null } -Pattern "unknown adapter id 'archive.rar'" -Message 'Unknown adapter IDs must be rejected.'

$missingAdapter = New-TestEligibilityEvaluation
$missingAdapter.adapters = @($missingAdapter.adapters | Where-Object { $_.adapterId -ne 'archive.tar' })
Assert-ThrowsLike -Script { Resolve-DeploymentAdapterSelection -EligibilityEvaluation $missingAdapter | Out-Null } -Pattern "missing known adapter id 'archive.tar'" -Message 'Missing known adapter IDs must be rejected.'

$duplicateAdapter = New-TestEligibilityEvaluation
$duplicateAdapter.adapters += New-TestEligibilityAdapter -AdapterId 'archive.zip' -Priority 100 -EligibilityStatus 'eligible'
Assert-ThrowsLike -Script { Resolve-DeploymentAdapterSelection -EligibilityEvaluation $duplicateAdapter | Out-Null } -Pattern "duplicate adapter id 'archive.zip'" -Message 'Duplicate adapter IDs must be rejected.'

$invalidPriority = New-TestEligibilityEvaluation
$invalidPriority.adapters[0].priority = 'high'
Assert-ThrowsLike -Script { Resolve-DeploymentAdapterSelection -EligibilityEvaluation $invalidPriority | Out-Null } -Pattern "field 'priority' must be an integer" -Message 'Non-integer priorities must be rejected.'

$mismatchedPriority = New-TestEligibilityEvaluation
$mismatchedPriority.adapters[0].priority = 999
Assert-ThrowsLike -Script { Resolve-DeploymentAdapterSelection -EligibilityEvaluation $mismatchedPriority | Out-Null } -Pattern "does not match catalog priority '100'" -Message 'Priority mismatches must be rejected.'

$invalidEligibilityStatus = New-TestEligibilityEvaluation
$invalidEligibilityStatus.adapters[0].eligibilityStatus = 'maybe'
Assert-ThrowsLike -Script { Resolve-DeploymentAdapterSelection -EligibilityEvaluation $invalidEligibilityStatus | Out-Null } -Pattern "unsupported status 'maybe'" -Message 'Invalid adapter eligibility statuses must be rejected.'

$invalidOverallStatus = New-TestEligibilityEvaluation
$invalidOverallStatus.status = 'maybe'
Assert-ThrowsLike -Script { Resolve-DeploymentAdapterSelection -EligibilityEvaluation $invalidOverallStatus | Out-Null } -Pattern "unsupported status 'maybe'" -Message 'Invalid evaluation status must be rejected.'

$readyWithoutEligible = New-TestEligibilityEvaluation -ZipStatus 'ineligible' -TarStatus 'ineligible' -Status 'ready'
Assert-ThrowsLike -Script { Resolve-DeploymentAdapterSelection -EligibilityEvaluation $readyWithoutEligible | Out-Null } -Pattern "status 'ready' requires at least one eligible adapter" -Message 'Contradictory ready status must be rejected.'

$blockedWithUnknown = New-TestEligibilityEvaluation -ZipStatus 'ineligible' -TarStatus 'unknown' -Status 'blocked'
Assert-ThrowsLike -Script { Resolve-DeploymentAdapterSelection -EligibilityEvaluation $blockedWithUnknown | Out-Null } -Pattern "status 'blocked' requires all adapters to be ineligible" -Message 'Contradictory blocked status must be rejected.'

$incompleteWithEligible = New-TestEligibilityEvaluation -ZipStatus 'eligible' -TarStatus 'unknown' -Status 'incomplete'
Assert-ThrowsLike -Script { Resolve-DeploymentAdapterSelection -EligibilityEvaluation $incompleteWithEligible | Out-Null } -Pattern "status 'incomplete' requires no eligible adapters" -Message 'Contradictory incomplete status must be rejected.'

$invalidSchema = New-TestEligibilityEvaluation
$invalidSchema.schemaVersion = '0.2'
Assert-ThrowsLike -Script { Resolve-DeploymentAdapterSelection -EligibilityEvaluation $invalidSchema | Out-Null } -Pattern "unsupported schemaVersion '0.2'" -Message 'Invalid schemaVersion must be rejected.'

$invalidType = New-TestEligibilityEvaluation
$invalidType.evaluationType = 'tool-inventory'
Assert-ThrowsLike -Script { Resolve-DeploymentAdapterSelection -EligibilityEvaluation $invalidType | Out-Null } -Pattern "evaluationType must be 'adapter-eligibility'" -Message 'Invalid evaluationType must be rejected.'

$nullAdapters = New-TestEligibilityEvaluation
$nullAdapters.adapters = $null
Assert-ThrowsLike -Script { Resolve-DeploymentAdapterSelection -EligibilityEvaluation $nullAdapters | Out-Null } -Pattern "field 'adapters' must not be null" -Message 'Null adapters must be rejected.'

$invalidCompatibility = New-TestEligibilityEvaluation
$invalidCompatibility.adapters[0].compatibility = 'assumed'
Assert-ThrowsLike -Script { Resolve-DeploymentAdapterSelection -EligibilityEvaluation $invalidCompatibility | Out-Null } -Pattern "field 'compatibility' must be an object" -Message 'Invalid compatibility structure must be rejected.'

$invalidCompatibilityStatus = New-TestEligibilityEvaluation
$invalidCompatibilityStatus.adapters[0].compatibility.status = 'verified'
Assert-ThrowsLike -Script { Resolve-DeploymentAdapterSelection -EligibilityEvaluation $invalidCompatibilityStatus | Out-Null } -Pattern "compatibility.status must be 'assumed'" -Message 'Unexpected compatibility status must be rejected.'

$invalidCompatibilityChecked = New-TestEligibilityEvaluation
$invalidCompatibilityChecked.adapters[0].compatibility.checked = $true
Assert-ThrowsLike -Script { Resolve-DeploymentAdapterSelection -EligibilityEvaluation $invalidCompatibilityChecked | Out-Null } -Pattern "compatibility.checked must be false" -Message 'Unexpected compatibility checked value must be rejected.'

$input = New-TestEligibilityEvaluation
$before = $input | ConvertTo-Json -Depth 40
$selection = Resolve-DeploymentAdapterSelection -EligibilityEvaluation $input
Assert-Equal ($input | ConvertTo-Json -Depth 40) $before 'Adapter selection must not mutate input.'
$selection.candidates[0].eligibilityStatus = 'changed'
Assert-Equal $input.adapters[0].eligibilityStatus 'eligible' 'Output candidates must not hold mutable references to input adapters.'

$tmp = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('adapter-selection-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    $eligibilityPath = Join-Path -Path $tmp -ChildPath 'eligibility.json'
    $outputPath = Join-Path -Path $tmp -ChildPath 'nested/selection.json'
    New-TestEligibilityEvaluation | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $eligibilityPath -Encoding UTF8

    & $cliPath select-adapter -EligibilityPath $eligibilityPath -OutputPath $outputPath -Format Json | Out-Null
    Assert-True (Test-Path -LiteralPath $outputPath -PathType Leaf) 'CLI invocation must create explicit output path.'
    $cliSelection = Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json
    Assert-Equal $cliSelection.selectionType 'deployment-adapter' 'CLI output file must contain adapter selection JSON.'
    Assert-Equal $cliSelection.selectedAdapterId 'archive.zip' 'CLI output file must contain selected adapter.'

    $fileCountBeforeStdout = @(Get-ChildItem -LiteralPath $tmp -File -Recurse).Count
    $stdoutJson = & $cliPath select-adapter -EligibilityPath $eligibilityPath -Format Json
    $fileCountAfterStdout = @(Get-ChildItem -LiteralPath $tmp -File -Recurse).Count
    $stdoutSelection = $stdoutJson | ConvertFrom-Json
    Assert-Equal $stdoutSelection.selectionType 'deployment-adapter' 'CLI without OutputPath must emit parseable JSON.'
    Assert-Equal $fileCountAfterStdout $fileCountBeforeStdout 'CLI without OutputPath must not create files in the test run directory.'

    Assert-ThrowsLike -Script { & $cliPath select-adapter -EligibilityPath $eligibilityPath -Format Text | Out-Null } -Pattern 'only supports -Format Json' -Message 'CLI invalid format must be rejected.'
    Assert-ThrowsLike -Script { & $cliPath select-adapter -Format Json | Out-Null } -Pattern "Missing required parameter for 'select-adapter': -EligibilityPath" -Message 'CLI missing EligibilityPath must be rejected.'

    $invalidJsonPath = Join-Path -Path $tmp -ChildPath 'invalid.json'
    Set-Content -LiteralPath $invalidJsonPath -Value '{ invalid json' -Encoding UTF8
    Assert-ThrowsLike -Script { & $cliPath select-adapter -EligibilityPath $invalidJsonPath -Format Json | Out-Null } -Pattern 'Invalid adapter eligibility evaluation JSON' -Message 'CLI invalid input JSON must be rejected.'

    $missingPath = Join-Path -Path $tmp -ChildPath 'missing.json'
    Assert-ThrowsLike -Script { & $cliPath select-adapter -EligibilityPath $missingPath -Format Json | Out-Null } -Pattern 'Adapter eligibility evaluation file does not exist' -Message 'CLI missing input file must be rejected.'
} finally {
    if (Test-Path -LiteralPath $tmp) {
        Remove-Item -LiteralPath $tmp -Recurse -Force
    }
}

if ($script:failures.Count -gt 0) {
    Write-Host 'Adapter Selection tests failed:'
    $script:failures | ForEach-Object { Write-Host "- $_" }
    exit 1
}

Write-Host 'Adapter Selection tests passed.'
exit 0
