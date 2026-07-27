[CmdletBinding()]
param(
    [string] $AssessmentPath,
    [string] $OutputPath,
    [string] $Format = 'Json'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path -Path $PSScriptRoot -ChildPath 'DeploymentAdapters.ps1')

function Resolve-AdapterEligibilityPath {
    param([Parameter(Mandatory = $true)][string] $Path)

    $executionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function Read-AdapterEligibilityJsonFile {
    param([Parameter(Mandatory = $true)][string] $Path)

    $resolved = Resolve-AdapterEligibilityPath -Path $Path
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
        throw "Assessed tool inventory file does not exist: $resolved"
    }

    try {
        return (Get-Content -LiteralPath $resolved -Raw | ConvertFrom-Json)
    } catch {
        throw "Invalid assessed tool inventory JSON in '$resolved': $($_.Exception.Message)"
    }
}

function Test-AdapterEligibilityProperty {
    param(
        [object] $Object,
        [Parameter(Mandatory = $true)][string] $Name
    )

    return ($null -ne $Object -and $Object.PSObject.Properties.Name -contains $Name)
}

function Test-AdapterEligibilityObjectLike {
    param([object] $Value)

    if ($null -eq $Value -or $Value -is [string] -or $Value -is [System.ValueType]) {
        return $false
    }
    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [System.Collections.IDictionary]) -and -not ($Value -is [pscustomobject])) {
        return $false
    }

    return ($null -ne $Value.PSObject -and $null -ne $Value.PSObject.Properties)
}

function Assert-AdapterEligibilityString {
    param(
        [Parameter(Mandatory = $true)][object] $Object,
        [Parameter(Mandatory = $true)][string] $Name,
        [Parameter(Mandatory = $true)][string] $Context
    )

    if (-not (Test-AdapterEligibilityProperty -Object $Object -Name $Name)) {
        throw "$Context validation failed: missing required field '$Name'."
    }
    if (-not ($Object.$Name -is [string])) {
        throw "$Context validation failed: field '$Name' must be a string."
    }
}

function Assert-AdapterEligibilityBool {
    param(
        [Parameter(Mandatory = $true)][object] $Object,
        [Parameter(Mandatory = $true)][string] $Name,
        [Parameter(Mandatory = $true)][string] $Context
    )

    if (-not (Test-AdapterEligibilityProperty -Object $Object -Name $Name)) {
        throw "$Context validation failed: missing required field '$Name'."
    }
    if (-not ($Object.$Name -is [bool])) {
        throw "$Context validation failed: field '$Name' must be boolean."
    }
}

function Assert-AdapterEligibilityStatus {
    param(
        [Parameter(Mandatory = $true)][string] $Status,
        [Parameter(Mandatory = $true)][string[]] $AllowedStatuses,
        [Parameter(Mandatory = $true)][string] $Context
    )

    if ($Status -notin $AllowedStatuses) {
        throw "$Context validation failed: unsupported status '$Status'."
    }
}

function Get-AssessedInventoryStatuses {
    return @('ready', 'incomplete')
}

function Get-AssessedToolStatuses {
    return @('available-both', 'available-local-only', 'available-remote-only', 'not-found', 'degraded', 'unknown')
}

function Get-AssessedSourceStatuses {
    return @('completed', 'incomplete', 'missing')
}

function Get-AdapterEligibilityToolStatuses {
    return @('available', 'not-found', 'version-unavailable', 'probe-failed', 'unsupported')
}

function Get-AdapterEligibilityStatuses {
    return @('eligible', 'ineligible', 'unknown')
}

function Assert-AssessedToolInventory {
    param([Parameter(Mandatory = $true)][object] $Assessment)

    if ($null -eq $Assessment) {
        throw "Adapter eligibility validation failed: assessed tool inventory is missing."
    }
    Assert-AdapterEligibilityString -Object $Assessment -Name 'schemaVersion' -Context 'Assessed tool inventory'
    if ($Assessment.schemaVersion -ne '0.1') {
        throw "Assessed tool inventory validation failed: unsupported schemaVersion '$($Assessment.schemaVersion)'."
    }
    Assert-AdapterEligibilityString -Object $Assessment -Name 'assessmentType' -Context 'Assessed tool inventory'
    if ($Assessment.assessmentType -ne 'tool-inventory') {
        throw "Assessed tool inventory validation failed: assessmentType must be 'tool-inventory'."
    }
    Assert-AdapterEligibilityString -Object $Assessment -Name 'status' -Context 'Assessed tool inventory'
    Assert-AdapterEligibilityStatus -Status ([string] $Assessment.status) -AllowedStatuses (Get-AssessedInventoryStatuses) -Context 'Assessed tool inventory'

    foreach ($field in @('sources', 'tools')) {
        if (-not (Test-AdapterEligibilityProperty -Object $Assessment -Name $field)) {
            throw "Assessed tool inventory validation failed: missing required field '$field'."
        }
        if (-not (Test-AdapterEligibilityObjectLike -Value $Assessment.$field)) {
            throw "Assessed tool inventory validation failed: field '$field' must be an object."
        }
    }

    foreach ($sourceName in @('local', 'remote')) {
        if (-not (Test-AdapterEligibilityProperty -Object $Assessment.sources -Name $sourceName)) {
            throw "Assessed tool inventory validation failed: missing source '$sourceName'."
        }
        $source = $Assessment.sources.$sourceName
        $context = "Assessed tool inventory source '$sourceName'"
        Assert-AdapterEligibilityBool -Object $source -Name 'present' -Context $context
        Assert-AdapterEligibilityString -Object $source -Name 'status' -Context $context
        Assert-AdapterEligibilityStatus -Status ([string] $source.status) -AllowedStatuses (Get-AssessedSourceStatuses) -Context $context
    }

    $knownToolIds = @(Get-DeploymentToolIds)
    $knownSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    foreach ($toolId in $knownToolIds) {
        [void] $knownSet.Add($toolId)
    }
    foreach ($property in @($Assessment.tools.PSObject.Properties)) {
        if (-not $knownSet.Contains($property.Name)) {
            throw "Assessed tool inventory validation failed: unknown tool id '$($property.Name)'."
        }
    }

    foreach ($toolId in $knownToolIds) {
        if (-not ($Assessment.tools.PSObject.Properties.Name -contains $toolId)) {
            throw "Assessed tool inventory validation failed: missing required tool result '$toolId'."
        }
        $tool = $Assessment.tools.$toolId
        foreach ($sideName in @('local', 'remote')) {
            if (-not (Test-AdapterEligibilityProperty -Object $tool -Name $sideName)) {
                throw "Assessed tool inventory tool '$toolId' validation failed: missing '$sideName' result."
            }
            $side = $tool.$sideName
            $context = "Assessed tool inventory tool '$toolId' $sideName"
            Assert-AdapterEligibilityBool -Object $side -Name 'present' -Context $context
            if ($side.present) {
                Assert-AdapterEligibilityBool -Object $side -Name 'available' -Context $context
                Assert-AdapterEligibilityString -Object $side -Name 'status' -Context $context
                Assert-AdapterEligibilityStatus -Status ([string] $side.status) -AllowedStatuses (Get-AdapterEligibilityToolStatuses) -Context $context
            }
        }
        if (-not (Test-AdapterEligibilityProperty -Object $tool -Name 'assessment')) {
            throw "Assessed tool inventory tool '$toolId' validation failed: missing 'assessment' result."
        }
        Assert-AdapterEligibilityString -Object $tool.assessment -Name 'status' -Context "Assessed tool inventory tool '$toolId' assessment"
        Assert-AdapterEligibilityStatus -Status ([string] $tool.assessment.status) -AllowedStatuses (Get-AssessedToolStatuses) -Context "Assessed tool inventory tool '$toolId' assessment"
    }
}

function Assert-DeploymentAdapterCatalog {
    param([Parameter(Mandatory = $true)][object] $Catalog)

    $knownToolIds = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    foreach ($toolId in Get-DeploymentToolIds) {
        [void] $knownToolIds.Add($toolId)
    }

    foreach ($property in @($Catalog.GetEnumerator())) {
        $adapter = $property.Value
        if ($adapter.adapterId -ne $property.Key) {
            throw "Deployment adapter catalog validation failed: adapter key '$($property.Key)' does not match adapterId '$($adapter.adapterId)'."
        }
        foreach ($groupName in @('producer', 'consumer')) {
            $group = $adapter.$groupName
            foreach ($toolId in @($group.oneOf)) {
                if (-not $knownToolIds.Contains($toolId)) {
                    throw "Deployment adapter '$($adapter.adapterId)' validation failed: unknown tool id '$toolId'."
                }
            }
        }
    }
}

function Get-AdapterToolAlternativeState {
    param(
        [Parameter(Mandatory = $true)][object] $Assessment,
        [Parameter(Mandatory = $true)][string] $ToolId,
        [Parameter(Mandatory = $true)][string] $Environment
    )

    $source = $Assessment.sources.$Environment
    $tool = $Assessment.tools.$ToolId
    $side = $tool.$Environment

    if (-not $source.present -or $source.status -ne 'completed') {
        return [pscustomobject]@{
            toolId = $ToolId
            state = 'unknown'
            present = $false
            available = $false
            status = 'unknown'
            diagnostic = 'Source inventory is missing or incomplete.'
        }
    }
    if ($null -eq $side -or -not $side.present) {
        return [pscustomobject]@{
            toolId = $ToolId
            state = 'unknown'
            present = $false
            available = $false
            status = 'unknown'
            diagnostic = 'Tool result is missing.'
        }
    }

    return [pscustomobject]@{
        toolId = $ToolId
        state = if ($side.available) { 'available' } else { 'not-available' }
        present = $true
        available = [bool] $side.available
        status = [string] $side.status
        diagnostic = if (Test-AdapterEligibilityProperty -Object $side -Name 'diagnostic') { [string] $side.diagnostic } else { '' }
    }
}

function Resolve-AdapterRequirementGroup {
    param(
        [Parameter(Mandatory = $true)][object] $Assessment,
        [Parameter(Mandatory = $true)][object] $Requirement
    )

    $alternatives = @(
        foreach ($toolId in @($Requirement.oneOf)) {
            Get-AdapterToolAlternativeState -Assessment $Assessment -ToolId $toolId -Environment $Requirement.environment
        }
    )
    $states = @($alternatives | ForEach-Object { $_.state })
    $status = if ($states -contains 'available') {
        'satisfied'
    } elseif ($states -contains 'unknown') {
        'unknown'
    } else {
        'not-satisfied'
    }

    return [pscustomobject]@{
        environment = [string] $Requirement.environment
        role = [string] $Requirement.role
        status = $status
        oneOf = @($alternatives)
    }
}

function Resolve-AdapterEligibilityStatus {
    param(
        [Parameter(Mandatory = $true)][object] $ProducerResult,
        [Parameter(Mandatory = $true)][object] $ConsumerResult
    )

    if ($ProducerResult.status -eq 'not-satisfied' -or $ConsumerResult.status -eq 'not-satisfied') {
        return 'ineligible'
    }
    if ($ProducerResult.status -eq 'unknown' -or $ConsumerResult.status -eq 'unknown') {
        return 'unknown'
    }

    return 'eligible'
}

function New-AdapterEligibilityDiagnostic {
    param(
        [Parameter(Mandatory = $true)][string] $Status,
        [Parameter(Mandatory = $true)][object] $ProducerResult,
        [Parameter(Mandatory = $true)][object] $ConsumerResult
    )

    switch ($Status) {
        'eligible' { return 'Producer and consumer requirements are satisfied.' }
        'unknown' { return 'Eligibility cannot be determined because at least one requirement group is unknown.' }
        'ineligible' {
            if ($ProducerResult.status -eq 'not-satisfied' -and $ConsumerResult.status -eq 'not-satisfied') {
                return 'Producer and consumer requirements are not satisfied.'
            }
            if ($ProducerResult.status -eq 'not-satisfied') {
                return 'Producer requirement is not satisfied.'
            }
            return 'Consumer requirement is not satisfied.'
        }
    }

    return ''
}

function Resolve-DeploymentAdapterEligibility {
    param(
        [Parameter(Mandatory = $true)][object] $Assessment,
        [object] $AdapterCatalog = (Get-DeploymentAdapterCatalog)
    )

    Assert-AssessedToolInventory -Assessment $Assessment
    Assert-DeploymentAdapterCatalog -Catalog $AdapterCatalog

    $adapterResults = @(
        foreach ($entry in @($AdapterCatalog.GetEnumerator() | Sort-Object { $_.Value.priority }, { $_.Value.adapterId })) {
            $adapter = $entry.Value
            $producer = Resolve-AdapterRequirementGroup -Assessment $Assessment -Requirement $adapter.producer
            $consumer = Resolve-AdapterRequirementGroup -Assessment $Assessment -Requirement $adapter.consumer
            $eligibilityStatus = Resolve-AdapterEligibilityStatus -ProducerResult $producer -ConsumerResult $consumer
            [pscustomobject]@{
                adapterId = [string] $adapter.adapterId
                priority = [int] $adapter.priority
                eligibilityStatus = $eligibilityStatus
                producerRequirements = $producer
                consumerRequirements = $consumer
                compatibility = [pscustomobject]@{
                    status = 'assumed'
                    checked = $false
                }
                diagnostic = New-AdapterEligibilityDiagnostic -Status $eligibilityStatus -ProducerResult $producer -ConsumerResult $consumer
            }
        }
    )

    $statuses = @($adapterResults | ForEach-Object { $_.eligibilityStatus })
    $overallStatus = if ($statuses -contains 'eligible') {
        'ready'
    } elseif ($statuses -contains 'unknown') {
        'incomplete'
    } else {
        'blocked'
    }

    return [pscustomobject]@{
        schemaVersion = '0.1'
        evaluationType = 'adapter-eligibility'
        status = $overallStatus
        diagnostic = ''
        adapters = @($adapterResults)
    }
}

function Write-AdapterEligibilityJson {
    param(
        [Parameter(Mandatory = $true)][object] $Evaluation,
        [string] $OutputPath
    )

    $json = $Evaluation | ConvertTo-Json -Depth 40
    if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
        $resolvedOutputPath = Resolve-AdapterEligibilityPath -Path $OutputPath
        $outputDirectory = Split-Path -Path $resolvedOutputPath -Parent
        if (-not [string]::IsNullOrWhiteSpace($outputDirectory)) {
            New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
        }
        $json | Set-Content -LiteralPath $resolvedOutputPath -Encoding utf8
    }

    return $json
}

function Invoke-AdapterEligibilityEvaluation {
    param(
        [Parameter(Mandatory = $true)][string] $AssessmentPath,
        [string] $OutputPath,
        [string] $Format = 'Json'
    )

    if ($Format -ne 'Json') {
        throw "evaluate-adapter-eligibility only supports -Format Json."
    }
    $assessment = Read-AdapterEligibilityJsonFile -Path $AssessmentPath
    $evaluation = Resolve-DeploymentAdapterEligibility -Assessment $assessment
    return Write-AdapterEligibilityJson -Evaluation $evaluation -OutputPath $OutputPath
}

if ($MyInvocation.InvocationName -ne '.') {
    if ([string]::IsNullOrWhiteSpace($AssessmentPath)) {
        throw "Missing required parameter for 'evaluate-adapter-eligibility': -AssessmentPath"
    }
    Invoke-AdapterEligibilityEvaluation -AssessmentPath $AssessmentPath -OutputPath $OutputPath -Format $Format
}
