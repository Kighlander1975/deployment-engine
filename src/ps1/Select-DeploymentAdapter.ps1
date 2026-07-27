[CmdletBinding()]
param(
    [string] $EligibilityPath,
    [string] $OutputPath,
    [string] $Format = 'Json'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path -Path $PSScriptRoot -ChildPath 'DeploymentAdapters.ps1')

function Resolve-AdapterSelectionPath {
    param([Parameter(Mandatory = $true)][string] $Path)

    $executionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function Read-AdapterSelectionJsonFile {
    param([Parameter(Mandatory = $true)][string] $Path)

    $resolved = Resolve-AdapterSelectionPath -Path $Path
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
        throw "Adapter eligibility evaluation file does not exist: $resolved"
    }

    try {
        return (Get-Content -LiteralPath $resolved -Raw | ConvertFrom-Json)
    } catch {
        throw "Invalid adapter eligibility evaluation JSON in '$resolved': $($_.Exception.Message)"
    }
}

function Test-AdapterSelectionProperty {
    param(
        [object] $Object,
        [Parameter(Mandatory = $true)][string] $Name
    )

    return ($null -ne $Object -and $Object.PSObject.Properties.Name -contains $Name)
}

function Test-AdapterSelectionObjectLike {
    param([object] $Value)

    if ($null -eq $Value -or $Value -is [string] -or $Value -is [System.ValueType]) {
        return $false
    }
    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [System.Collections.IDictionary]) -and -not ($Value -is [pscustomobject])) {
        return $false
    }

    return ($null -ne $Value.PSObject -and $null -ne $Value.PSObject.Properties)
}

function Assert-AdapterSelectionString {
    param(
        [Parameter(Mandatory = $true)][object] $Object,
        [Parameter(Mandatory = $true)][string] $Name,
        [Parameter(Mandatory = $true)][string] $Context
    )

    if (-not (Test-AdapterSelectionProperty -Object $Object -Name $Name)) {
        throw "$Context validation failed: missing required field '$Name'."
    }
    if (-not ($Object.$Name -is [string])) {
        throw "$Context validation failed: field '$Name' must be a string."
    }
}

function Assert-AdapterSelectionBool {
    param(
        [Parameter(Mandatory = $true)][object] $Object,
        [Parameter(Mandatory = $true)][string] $Name,
        [Parameter(Mandatory = $true)][string] $Context
    )

    if (-not (Test-AdapterSelectionProperty -Object $Object -Name $Name)) {
        throw "$Context validation failed: missing required field '$Name'."
    }
    if (-not ($Object.$Name -is [bool])) {
        throw "$Context validation failed: field '$Name' must be boolean."
    }
}

function Assert-AdapterSelectionStatus {
    param(
        [Parameter(Mandatory = $true)][string] $Status,
        [Parameter(Mandatory = $true)][string[]] $AllowedStatuses,
        [Parameter(Mandatory = $true)][string] $Context
    )

    if ($Status -notin $AllowedStatuses) {
        throw "$Context validation failed: unsupported status '$Status'."
    }
}

function Assert-AdapterSelectionPriority {
    param(
        [Parameter(Mandatory = $true)][object] $Value,
        [Parameter(Mandatory = $true)][string] $Context
    )

    if (-not ($Value -is [byte] -or $Value -is [int16] -or $Value -is [int] -or $Value -is [long])) {
        throw "$Context validation failed: field 'priority' must be an integer."
    }
}

function Get-AdapterSelectionEvaluationStatuses {
    return @('ready', 'incomplete', 'blocked')
}

function Get-AdapterSelectionEligibilityStatuses {
    return @('eligible', 'ineligible', 'unknown')
}

function Assert-DeploymentAdapterSelectionCatalog {
    param([Parameter(Mandatory = $true)][object] $Catalog)

    if ($null -eq $Catalog) {
        throw "Deployment adapter catalog validation failed: catalog is missing."
    }

    $ids = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    foreach ($entry in @($Catalog.GetEnumerator())) {
        $adapter = $entry.Value
        if (-not (Test-AdapterSelectionProperty -Object $adapter -Name 'adapterId')) {
            throw "Deployment adapter catalog validation failed: adapter '$($entry.Key)' is missing adapterId."
        }
        if (-not (Test-AdapterSelectionProperty -Object $adapter -Name 'priority')) {
            throw "Deployment adapter catalog validation failed: adapter '$($entry.Key)' is missing priority."
        }
        if ($adapter.adapterId -ne $entry.Key) {
            throw "Deployment adapter catalog validation failed: adapter key '$($entry.Key)' does not match adapterId '$($adapter.adapterId)'."
        }
        Assert-AdapterSelectionPriority -Value $adapter.priority -Context "Deployment adapter catalog '$($entry.Key)'"
        if (-not $ids.Add([string] $adapter.adapterId)) {
            throw "Deployment adapter catalog validation failed: duplicate adapter id '$($adapter.adapterId)'."
        }
    }
}

function Assert-AdapterCompatibility {
    param(
        [Parameter(Mandatory = $true)][object] $Adapter,
        [Parameter(Mandatory = $true)][string] $AdapterId
    )

    if (-not (Test-AdapterSelectionProperty -Object $Adapter -Name 'compatibility')) {
        throw "Adapter eligibility '$AdapterId' validation failed: missing required field 'compatibility'."
    }
    if (-not (Test-AdapterSelectionObjectLike -Value $Adapter.compatibility)) {
        throw "Adapter eligibility '$AdapterId' validation failed: field 'compatibility' must be an object."
    }

    Assert-AdapterSelectionString -Object $Adapter.compatibility -Name 'status' -Context "Adapter eligibility '$AdapterId' compatibility"
    Assert-AdapterSelectionBool -Object $Adapter.compatibility -Name 'checked' -Context "Adapter eligibility '$AdapterId' compatibility"
    if ($Adapter.compatibility.status -ne 'assumed') {
        throw "Adapter eligibility '$AdapterId' validation failed: compatibility.status must be 'assumed'."
    }
    if ($Adapter.compatibility.checked -ne $false) {
        throw "Adapter eligibility '$AdapterId' validation failed: compatibility.checked must be false."
    }
}

function Assert-AdapterEligibilityEvaluation {
    param(
        [Parameter(Mandatory = $true)][object] $EligibilityEvaluation,
        [object] $AdapterCatalog = (Get-DeploymentAdapterCatalog)
    )

    if ($null -eq $EligibilityEvaluation) {
        throw "Adapter selection validation failed: eligibility evaluation is missing."
    }
    Assert-DeploymentAdapterSelectionCatalog -Catalog $AdapterCatalog

    Assert-AdapterSelectionString -Object $EligibilityEvaluation -Name 'schemaVersion' -Context 'Adapter eligibility evaluation'
    if ($EligibilityEvaluation.schemaVersion -ne '0.1') {
        throw "Adapter eligibility evaluation validation failed: unsupported schemaVersion '$($EligibilityEvaluation.schemaVersion)'."
    }
    Assert-AdapterSelectionString -Object $EligibilityEvaluation -Name 'evaluationType' -Context 'Adapter eligibility evaluation'
    if ($EligibilityEvaluation.evaluationType -ne 'adapter-eligibility') {
        throw "Adapter eligibility evaluation validation failed: evaluationType must be 'adapter-eligibility'."
    }
    Assert-AdapterSelectionString -Object $EligibilityEvaluation -Name 'status' -Context 'Adapter eligibility evaluation'
    Assert-AdapterSelectionStatus -Status ([string] $EligibilityEvaluation.status) -AllowedStatuses (Get-AdapterSelectionEvaluationStatuses) -Context 'Adapter eligibility evaluation'

    if (-not (Test-AdapterSelectionProperty -Object $EligibilityEvaluation -Name 'adapters')) {
        throw "Adapter eligibility evaluation validation failed: missing required field 'adapters'."
    }
    if ($null -eq $EligibilityEvaluation.adapters) {
        throw "Adapter eligibility evaluation validation failed: field 'adapters' must not be null."
    }

    $knownIds = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    foreach ($entry in @($AdapterCatalog.GetEnumerator())) {
        [void] $knownIds.Add([string] $entry.Key)
    }

    $seenIds = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    $statuses = New-Object System.Collections.Generic.List[string]
    foreach ($adapter in @($EligibilityEvaluation.adapters)) {
        if (-not (Test-AdapterSelectionObjectLike -Value $adapter)) {
            throw "Adapter eligibility evaluation validation failed: each adapter must be an object."
        }
        Assert-AdapterSelectionString -Object $adapter -Name 'adapterId' -Context 'Adapter eligibility entry'
        $adapterId = [string] $adapter.adapterId
        if (-not $knownIds.Contains($adapterId)) {
            throw "Adapter eligibility evaluation validation failed: unknown adapter id '$adapterId'."
        }
        if (-not $seenIds.Add($adapterId)) {
            throw "Adapter eligibility evaluation validation failed: duplicate adapter id '$adapterId'."
        }
        if (-not (Test-AdapterSelectionProperty -Object $adapter -Name 'priority')) {
            throw "Adapter eligibility '$adapterId' validation failed: missing required field 'priority'."
        }
        Assert-AdapterSelectionPriority -Value $adapter.priority -Context "Adapter eligibility '$adapterId'"
        if ([int] $adapter.priority -ne [int] $AdapterCatalog[$adapterId].priority) {
            throw "Adapter eligibility '$adapterId' validation failed: priority '$($adapter.priority)' does not match catalog priority '$($AdapterCatalog[$adapterId].priority)'."
        }
        Assert-AdapterSelectionString -Object $adapter -Name 'eligibilityStatus' -Context "Adapter eligibility '$adapterId'"
        Assert-AdapterSelectionStatus -Status ([string] $adapter.eligibilityStatus) -AllowedStatuses (Get-AdapterSelectionEligibilityStatuses) -Context "Adapter eligibility '$adapterId'"
        Assert-AdapterCompatibility -Adapter $adapter -AdapterId $adapterId
        $statuses.Add([string] $adapter.eligibilityStatus)
    }

    foreach ($adapterId in @($knownIds)) {
        if (-not $seenIds.Contains($adapterId)) {
            throw "Adapter eligibility evaluation validation failed: missing known adapter id '$adapterId'."
        }
    }

    $eligibleCount = @($statuses | Where-Object { $_ -eq 'eligible' }).Count
    $unknownCount = @($statuses | Where-Object { $_ -eq 'unknown' }).Count
    $ineligibleCount = @($statuses | Where-Object { $_ -eq 'ineligible' }).Count
    switch ($EligibilityEvaluation.status) {
        'ready' {
            if ($eligibleCount -lt 1) {
                throw "Adapter eligibility evaluation validation failed: status 'ready' requires at least one eligible adapter."
            }
        }
        'incomplete' {
            if ($eligibleCount -gt 0 -or $unknownCount -lt 1) {
                throw "Adapter eligibility evaluation validation failed: status 'incomplete' requires no eligible adapters and at least one unknown adapter."
            }
        }
        'blocked' {
            if ($ineligibleCount -ne $seenIds.Count) {
                throw "Adapter eligibility evaluation validation failed: status 'blocked' requires all adapters to be ineligible."
            }
        }
    }
}

function New-AdapterSelectionCandidateDiagnostic {
    param(
        [Parameter(Mandatory = $true)][string] $EligibilityStatus,
        [Parameter(Mandatory = $true)][bool] $Selected
    )

    if ($Selected) {
        return 'Selected as the highest-preference eligible adapter.'
    }
    switch ($EligibilityStatus) {
        'eligible' { return 'Eligible but not selected because a higher-preference adapter was selected.' }
        'unknown' { return 'Not selectable because eligibility is unknown.' }
        'ineligible' { return 'Not selectable because the adapter is ineligible.' }
    }

    return ''
}

function Resolve-DeploymentAdapterSelection {
    param(
        [Parameter(Mandatory = $true)][object] $EligibilityEvaluation,
        [object] $AdapterCatalog = (Get-DeploymentAdapterCatalog)
    )

    Assert-AdapterEligibilityEvaluation -EligibilityEvaluation $EligibilityEvaluation -AdapterCatalog $AdapterCatalog

    $adaptersById = @{}
    foreach ($adapter in @($EligibilityEvaluation.adapters)) {
        $adaptersById[[string] $adapter.adapterId] = $adapter
    }

    $orderedCatalogEntries = @($AdapterCatalog.GetEnumerator() | Sort-Object { $_.Value.priority }, { $_.Value.adapterId })
    $eligibleEntries = @($orderedCatalogEntries | Where-Object { $adaptersById[[string] $_.Key].eligibilityStatus -eq 'eligible' })
    $selectedAdapterId = if ($eligibleEntries.Count -gt 0) { [string] $eligibleEntries[0].Key } else { '' }

    $status = if (-not [string]::IsNullOrWhiteSpace($selectedAdapterId)) {
        'selected'
    } elseif (@($EligibilityEvaluation.adapters | Where-Object { $_.eligibilityStatus -eq 'unknown' }).Count -gt 0) {
        'incomplete'
    } else {
        'blocked'
    }

    $candidates = @(
        foreach ($entry in $orderedCatalogEntries) {
            $adapterId = [string] $entry.Key
            $eligibility = $adaptersById[$adapterId]
            $isSelected = ($adapterId -eq $selectedAdapterId)
            [pscustomobject]@{
                adapterId = $adapterId
                priority = [int] $entry.Value.priority
                eligibilityStatus = [string] $eligibility.eligibilityStatus
                selected = [bool] $isSelected
                diagnostic = New-AdapterSelectionCandidateDiagnostic -EligibilityStatus ([string] $eligibility.eligibilityStatus) -Selected $isSelected
            }
        }
    )

    $diagnostic = switch ($status) {
        'selected' { 'Selected the eligible adapter with the highest configured preference.' }
        'incomplete' { 'No adapter can be selected because eligibility remains unknown.' }
        'blocked' { 'No eligible deployment adapter is available.' }
    }

    return [pscustomobject]@{
        schemaVersion = '0.1'
        selectionType = 'deployment-adapter'
        status = $status
        selectedAdapterId = $selectedAdapterId
        strategy = [pscustomobject]@{
            type = 'priority'
            order = 'ascending'
            tieBreaker = 'adapterId'
        }
        candidates = @($candidates)
        diagnostic = $diagnostic
    }
}

function Write-AdapterSelectionJson {
    param(
        [Parameter(Mandatory = $true)][object] $Selection,
        [string] $OutputPath
    )

    $json = $Selection | ConvertTo-Json -Depth 40
    if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
        $resolvedOutputPath = Resolve-AdapterSelectionPath -Path $OutputPath
        $outputDirectory = Split-Path -Path $resolvedOutputPath -Parent
        if (-not [string]::IsNullOrWhiteSpace($outputDirectory)) {
            New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
        }
        $json | Set-Content -LiteralPath $resolvedOutputPath -Encoding utf8
    }

    return $json
}

function Invoke-DeploymentAdapterSelection {
    param(
        [Parameter(Mandatory = $true)][string] $EligibilityPath,
        [string] $OutputPath,
        [string] $Format = 'Json'
    )

    if ($Format -ne 'Json') {
        throw "select-adapter only supports -Format Json."
    }
    $evaluation = Read-AdapterSelectionJsonFile -Path $EligibilityPath
    $selection = Resolve-DeploymentAdapterSelection -EligibilityEvaluation $evaluation
    return Write-AdapterSelectionJson -Selection $selection -OutputPath $OutputPath
}

if ($MyInvocation.InvocationName -ne '.') {
    if ([string]::IsNullOrWhiteSpace($EligibilityPath)) {
        throw "Missing required parameter for 'select-adapter': -EligibilityPath"
    }
    Invoke-DeploymentAdapterSelection -EligibilityPath $EligibilityPath -OutputPath $OutputPath -Format $Format
}
