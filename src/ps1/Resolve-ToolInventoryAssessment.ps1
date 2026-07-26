[CmdletBinding()]
param(
    [string] $LocalInventoryPath,
    [string] $RemoteInventoryPath,
    [string] $OutputPath,
    [string] $Format = 'Json'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path -Path $PSScriptRoot -ChildPath 'DeploymentTools.ps1')

function Get-AssessmentInventoryStatuses {
    return @('completed', 'incomplete')
}

function Get-AssessmentToolStatuses {
    return @('available', 'not-found', 'version-unavailable', 'probe-failed', 'unsupported')
}

function Resolve-ToolInventoryAssessmentPath {
    param([Parameter(Mandatory = $true)][string] $Path)

    $executionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function Read-ToolInventoryAssessmentJsonFile {
    param([Parameter(Mandatory = $true)][string] $Path)

    $resolved = Resolve-ToolInventoryAssessmentPath -Path $Path
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
        throw "Inventory file does not exist: $resolved"
    }

    try {
        return (Get-Content -LiteralPath $resolved -Raw | ConvertFrom-Json)
    } catch {
        throw "Invalid inventory JSON in '$resolved': $($_.Exception.Message)"
    }
}

function Test-AssessmentProperty {
    param(
        [object] $Object,
        [Parameter(Mandatory = $true)][string] $Name
    )

    return ($null -ne $Object -and $Object.PSObject.Properties.Name -contains $Name)
}

function Assert-AssessmentStringProperty {
    param(
        [Parameter(Mandatory = $true)][object] $Object,
        [Parameter(Mandatory = $true)][string] $Name,
        [Parameter(Mandatory = $true)][string] $Context
    )

    if (-not (Test-AssessmentProperty -Object $Object -Name $Name)) {
        throw "$Context validation failed: missing required field '$Name'."
    }
    if (-not ($Object.$Name -is [string])) {
        throw "$Context validation failed: field '$Name' must be a string."
    }
}

function Assert-AssessmentBoolProperty {
    param(
        [Parameter(Mandatory = $true)][object] $Object,
        [Parameter(Mandatory = $true)][string] $Name,
        [Parameter(Mandatory = $true)][string] $Context
    )

    if (-not (Test-AssessmentProperty -Object $Object -Name $Name)) {
        throw "$Context validation failed: missing required field '$Name'."
    }
    if (-not ($Object.$Name -is [bool])) {
        throw "$Context validation failed: field '$Name' must be boolean."
    }
}

function Assert-AssessmentSupportedStatus {
    param(
        [Parameter(Mandatory = $true)][string] $Status,
        [Parameter(Mandatory = $true)][string[]] $AllowedStatuses,
        [Parameter(Mandatory = $true)][string] $Context
    )

    if ($Status -notin $AllowedStatuses) {
        throw "$Context validation failed: unsupported status '$Status'."
    }
}

function Test-AssessmentObjectLike {
    param([object] $Value)

    if ($null -eq $Value) {
        return $false
    }
    if ($Value -is [string]) {
        return $false
    }
    if ($Value -is [System.ValueType]) {
        return $false
    }
    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [System.Collections.IDictionary]) -and -not ($Value -is [pscustomobject])) {
        return $false
    }

    return ($null -ne $Value.PSObject -and $null -ne $Value.PSObject.Properties)
}

function Assert-ToolInventoryCore {
    param(
        [Parameter(Mandatory = $true)][object] $Inventory,
        [Parameter(Mandatory = $true)][string] $SourceName
    )

    if ($null -eq $Inventory) {
        throw "$SourceName inventory validation failed: inventory is missing."
    }
    Assert-AssessmentStringProperty -Object $Inventory -Name 'schemaVersion' -Context "$SourceName inventory"
    if ($Inventory.schemaVersion -ne '0.1') {
        throw "$SourceName inventory validation failed: unsupported schemaVersion '$($Inventory.schemaVersion)'."
    }
    if (-not (Test-AssessmentProperty -Object $Inventory -Name 'tools')) {
        throw "$SourceName inventory validation failed: missing required field 'tools'."
    }
    if (-not (Test-AssessmentObjectLike -Value $Inventory.tools)) {
        throw "$SourceName inventory validation failed: field 'tools' must be an object."
    }

    $knownToolIds = @(Get-DeploymentToolIds)
    $knownSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    foreach ($toolId in $knownToolIds) {
        [void] $knownSet.Add($toolId)
    }

    foreach ($property in @($Inventory.tools.PSObject.Properties)) {
        if (-not $knownSet.Contains($property.Name)) {
            throw "$SourceName inventory validation failed: unknown tool id '$($property.Name)'."
        }
    }

    if (Test-AssessmentProperty -Object $Inventory -Name 'status') {
        Assert-AssessmentStringProperty -Object $Inventory -Name 'status' -Context "$SourceName inventory"
    }
    $inventoryStatus = if (Test-AssessmentProperty -Object $Inventory -Name 'status') { [string] $Inventory.status } else { 'completed' }
    Assert-AssessmentSupportedStatus -Status $inventoryStatus -AllowedStatuses (Get-AssessmentInventoryStatuses) -Context "$SourceName inventory"
    foreach ($toolId in $knownToolIds) {
        if (-not ($Inventory.tools.PSObject.Properties.Name -contains $toolId)) {
            if ($inventoryStatus -eq 'incomplete') {
                continue
            }
            throw "$SourceName inventory validation failed: missing required tool result '$toolId'."
        }

        $tool = $Inventory.tools.$toolId
        $context = "$SourceName inventory tool '$toolId'"
        Assert-AssessmentBoolProperty -Object $tool -Name 'available' -Context $context
        Assert-AssessmentStringProperty -Object $tool -Name 'path' -Context $context
        Assert-AssessmentStringProperty -Object $tool -Name 'version' -Context $context
        Assert-AssessmentStringProperty -Object $tool -Name 'status' -Context $context
        Assert-AssessmentStringProperty -Object $tool -Name 'diagnostic' -Context $context
        Assert-AssessmentSupportedStatus -Status ([string] $tool.status) -AllowedStatuses (Get-AssessmentToolStatuses) -Context $context
    }
}

function Assert-LocalToolInventory {
    param([Parameter(Mandatory = $true)][object] $Inventory)

    Assert-ToolInventoryCore -Inventory $Inventory -SourceName 'Local'
    if (Test-AssessmentProperty -Object $Inventory -Name 'environment') {
        if ($Inventory.environment -eq 'remote') {
            throw "Local inventory validation failed: remote inventory metadata is not accepted as local input."
        }
    }
    if (Test-AssessmentProperty -Object $Inventory -Name 'discoveryMethod') {
        if ($Inventory.discoveryMethod -eq 'human') {
            throw "Local inventory validation failed: remote discovery metadata is not accepted as local input."
        }
    }
}

function Assert-RemoteToolInventory {
    param([Parameter(Mandatory = $true)][object] $Inventory)

    Assert-ToolInventoryCore -Inventory $Inventory -SourceName 'Remote'
    Assert-AssessmentStringProperty -Object $Inventory -Name 'environment' -Context 'Remote inventory'
    Assert-AssessmentStringProperty -Object $Inventory -Name 'discoveryType' -Context 'Remote inventory'
    Assert-AssessmentStringProperty -Object $Inventory -Name 'discoveryMethod' -Context 'Remote inventory'
    Assert-AssessmentStringProperty -Object $Inventory -Name 'status' -Context 'Remote inventory'
    Assert-AssessmentStringProperty -Object $Inventory -Name 'planFingerprint' -Context 'Remote inventory'
    if ($Inventory.environment -ne 'remote') {
        throw "Remote inventory validation failed: environment must be 'remote'."
    }
    if ($Inventory.discoveryType -ne 'remote') {
        throw "Remote inventory validation failed: discoveryType must be 'remote'."
    }
    if ($Inventory.discoveryMethod -ne 'human') {
        throw "Remote inventory validation failed: discoveryMethod must be 'human'."
    }
    if (-not (Test-AssessmentProperty -Object $Inventory -Name 'platform')) {
        throw "Remote inventory validation failed: missing required field 'platform'."
    }
}

function Copy-AssessmentValue {
    param([object] $Value)

    if ($null -eq $Value) {
        return $null
    }
    if ($Value -is [string]) {
        return [string] $Value
    }
    if ($Value -is [System.ValueType]) {
        return $Value
    }
    if ($Value -is [System.Collections.IDictionary]) {
        $copy = [ordered]@{}
        foreach ($key in $Value.Keys) {
            $copy[$key] = Copy-AssessmentValue -Value $Value[$key]
        }
        return $copy
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $items = New-Object System.Collections.Generic.List[object]
        foreach ($item in $Value) {
            $items.Add((Copy-AssessmentValue -Value $item))
        }
        return $items.ToArray()
    }
    if ($null -ne $Value.PSObject -and @($Value.PSObject.Properties).Count -gt 0) {
        $copy = [ordered]@{}
        foreach ($property in @($Value.PSObject.Properties)) {
            $copy[$property.Name] = Copy-AssessmentValue -Value $property.Value
        }
        return [pscustomobject] $copy
    }

    return $Value
}

function Copy-AssessmentToolResult {
    param([object] $Tool)

    if ($null -eq $Tool) {
        return [pscustomobject]@{
            present = $false
        }
    }

    return [pscustomobject]@{
        present = $true
        available = [bool] $Tool.available
        path = [string] $Tool.path
        version = [string] $Tool.version
        status = [string] $Tool.status
        diagnostic = [string] $Tool.diagnostic
    }
}

function Copy-AssessmentProject {
    param([object] $Project)

    if ($null -eq $Project) {
        return [pscustomobject]@{
            present = $false
        }
    }

    $copy = [ordered]@{
        present = $true
    }
    foreach ($property in @($Project.PSObject.Properties)) {
        $copy[$property.Name] = Copy-AssessmentValue -Value $property.Value
    }

    return [pscustomobject] $copy
}

function Test-DegradedToolStatus {
    param([string] $Status)

    return ($Status -in @('version-unavailable', 'probe-failed', 'unsupported'))
}

function Resolve-ToolAssessmentStatus {
    param(
        [bool] $LocalSourcePresent,
        [bool] $RemoteSourcePresent,
        [object] $LocalTool,
        [object] $RemoteTool
    )

    if (-not $LocalSourcePresent -or -not $RemoteSourcePresent) {
        return 'unknown'
    }
    if ($null -eq $LocalTool -or $null -eq $RemoteTool) {
        return 'unknown'
    }

    if ((Test-DegradedToolStatus -Status ([string] $LocalTool.status)) -or (Test-DegradedToolStatus -Status ([string] $RemoteTool.status))) {
        if ($LocalTool.available -or $RemoteTool.available) {
            return 'degraded'
        }
    }

    if ($LocalTool.available -and $RemoteTool.available) {
        return 'available-both'
    }
    if ($LocalTool.available -and -not $RemoteTool.available) {
        return 'available-local-only'
    }
    if (-not $LocalTool.available -and $RemoteTool.available) {
        return 'available-remote-only'
    }

    return 'not-found'
}

function New-AssessmentSourceSummary {
    param(
        [bool] $Present,
        [object] $Inventory
    )

    if (-not $Present) {
        return [pscustomobject]@{
            present = $false
            status = 'missing'
        }
    }

    return [pscustomobject]@{
        present = $true
        status = if (Test-AssessmentProperty -Object $Inventory -Name 'status') { [string] $Inventory.status } else { 'completed' }
    }
}

function New-ToolInventoryAssessment {
    param(
        [object] $LocalInventory,
        [object] $RemoteInventory
    )

    $localPresent = ($null -ne $LocalInventory)
    $remotePresent = ($null -ne $RemoteInventory)
    if (-not $localPresent -and -not $remotePresent) {
        throw "At least one tool inventory must be provided."
    }

    if ($localPresent) {
        Assert-LocalToolInventory -Inventory $LocalInventory
    }
    if ($remotePresent) {
        Assert-RemoteToolInventory -Inventory $RemoteInventory
    }

    $diagnostics = New-Object System.Collections.Generic.List[string]
    if (-not $localPresent) {
        $diagnostics.Add('Local tool inventory is missing.')
    }
    if (-not $remotePresent) {
        $diagnostics.Add('Remote tool inventory is missing.')
    }
    if ($remotePresent -and $RemoteInventory.status -eq 'incomplete') {
        $diagnostics.Add('Remote tool inventory is incomplete.')
    }
    if ($localPresent -and (Test-AssessmentProperty -Object $LocalInventory -Name 'status') -and $LocalInventory.status -eq 'incomplete') {
        $diagnostics.Add('Local tool inventory is incomplete.')
    }

    $toolAssessments = [ordered]@{}
    foreach ($toolId in Get-DeploymentToolIds) {
        $localTool = if ($localPresent -and ($LocalInventory.tools.PSObject.Properties.Name -contains $toolId)) { $LocalInventory.tools.$toolId } else { $null }
        $remoteTool = if ($remotePresent -and ($RemoteInventory.tools.PSObject.Properties.Name -contains $toolId)) { $RemoteInventory.tools.$toolId } else { $null }
        $toolStatus = Resolve-ToolAssessmentStatus -LocalSourcePresent $localPresent -RemoteSourcePresent $remotePresent -LocalTool $localTool -RemoteTool $remoteTool
        $toolDiagnostic = ''
        if ($toolStatus -eq 'unknown') {
            if ($null -eq $localTool) {
                $toolDiagnostic = "Required local tool result is missing: $toolId."
                if (-not ($diagnostics -contains $toolDiagnostic)) { $diagnostics.Add($toolDiagnostic) }
            } elseif ($null -eq $remoteTool) {
                $toolDiagnostic = "Required remote tool result is missing: $toolId."
                if (-not ($diagnostics -contains $toolDiagnostic)) { $diagnostics.Add($toolDiagnostic) }
            } else {
                $toolDiagnostic = 'Insufficient source data for tool assessment.'
            }
        } elseif ($toolStatus -eq 'degraded') {
            $toolDiagnostic = 'At least one available source has a degraded discovery status.'
        } elseif ($localTool -and $remoteTool -and $localTool.version -ne '' -and $remoteTool.version -ne '' -and $localTool.version -ne $remoteTool.version) {
            $toolDiagnostic = 'Local and remote versions differ.'
        }

        $toolAssessments[$toolId] = [pscustomobject]@{
            local = Copy-AssessmentToolResult -Tool $localTool
            remote = Copy-AssessmentToolResult -Tool $remoteTool
            assessment = [pscustomobject]@{
                status = $toolStatus
                diagnostic = $toolDiagnostic
            }
        }
    }

    $overallStatus = if ($diagnostics.Count -eq 0) { 'ready' } else { 'incomplete' }

    return [pscustomobject]@{
        schemaVersion = '0.1'
        assessmentType = 'tool-inventory'
        status = $overallStatus
        diagnostic = ($diagnostics -join ' ')
        sources = [pscustomobject]@{
            local = New-AssessmentSourceSummary -Present $localPresent -Inventory $LocalInventory
            remote = New-AssessmentSourceSummary -Present $remotePresent -Inventory $RemoteInventory
        }
        tools = [pscustomobject] $toolAssessments
        project = [pscustomobject]@{
            local = Copy-AssessmentProject -Project $(if ($localPresent -and (Test-AssessmentProperty -Object $LocalInventory -Name 'project')) { $LocalInventory.project } else { $null })
            remote = Copy-AssessmentProject -Project $(if ($remotePresent -and (Test-AssessmentProperty -Object $RemoteInventory -Name 'project')) { $RemoteInventory.project } else { $null })
        }
    }
}

function Write-ToolInventoryAssessmentJson {
    param(
        [Parameter(Mandatory = $true)][object] $Assessment,
        [string] $OutputPath
    )

    $json = $Assessment | ConvertTo-Json -Depth 30
    if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
        $resolvedOutputPath = Resolve-ToolInventoryAssessmentPath -Path $OutputPath
        $outputDirectory = Split-Path -Path $resolvedOutputPath -Parent
        if (-not [string]::IsNullOrWhiteSpace($outputDirectory)) {
            New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
        }
        $json | Set-Content -LiteralPath $resolvedOutputPath -Encoding utf8
    }

    return $json
}

function Invoke-ToolInventoryAssessment {
    param(
        [string] $LocalInventoryPath,
        [string] $RemoteInventoryPath,
        [string] $OutputPath,
        [string] $Format = 'Json'
    )

    if ($Format -ne 'Json') {
        throw "assess-tool-inventories only supports -Format Json."
    }
    if ([string]::IsNullOrWhiteSpace($LocalInventoryPath) -and [string]::IsNullOrWhiteSpace($RemoteInventoryPath)) {
        throw "Missing required parameter for 'assess-tool-inventories': provide -LocalInventoryPath, -RemoteInventoryPath, or both."
    }

    $localInventory = if ([string]::IsNullOrWhiteSpace($LocalInventoryPath)) { $null } else { Read-ToolInventoryAssessmentJsonFile -Path $LocalInventoryPath }
    $remoteInventory = if ([string]::IsNullOrWhiteSpace($RemoteInventoryPath)) { $null } else { Read-ToolInventoryAssessmentJsonFile -Path $RemoteInventoryPath }
    $assessment = New-ToolInventoryAssessment -LocalInventory $localInventory -RemoteInventory $remoteInventory
    return Write-ToolInventoryAssessmentJson -Assessment $assessment -OutputPath $OutputPath
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-ToolInventoryAssessment -LocalInventoryPath $LocalInventoryPath -RemoteInventoryPath $RemoteInventoryPath -OutputPath $OutputPath -Format $Format
}
