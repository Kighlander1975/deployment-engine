[CmdletBinding()]
param(
    [string] $PlanPath,
    [ValidateSet('Json')]
    [string] $Format = 'Json',
    [string] $OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path -Path $PSScriptRoot -ChildPath 'DeploymentCapabilities.ps1')

function Resolve-LocalPath {
    param([Parameter(Mandatory = $true)][string] $Path)

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    return [System.IO.Path]::GetFullPath((Join-Path -Path (Get-Location).Path -ChildPath $Path))
}

function Read-JsonFile {
    param([Parameter(Mandatory = $true)][string] $Path)

    $resolved = Resolve-LocalPath -Path $Path
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
        throw "JSON file not found: $resolved"
    }

    try {
        return Get-Content -LiteralPath $resolved -Raw | ConvertFrom-Json
    } catch {
        throw "Invalid JSON in '$resolved': $($_.Exception.Message)"
    }
}

function Test-PropertyValue {
    param(
        [object] $Object,
        [Parameter(Mandatory = $true)][string] $Name
    )

    return ($null -ne $Object -and $Object.PSObject.Properties.Name -contains $Name -and $null -ne $Object.$Name)
}

function Copy-DeploymentPlanObject {
    param([Parameter(Mandatory = $true)][object] $InputObject)

    return $InputObject | ConvertTo-Json -Depth 30 | ConvertFrom-Json
}

function Assert-CapabilityIdConsistency {
    param(
        [Parameter(Mandatory = $true)][object] $Step,
        [Parameter(Mandatory = $true)][object] $Instructions
    )

    if (-not (Test-PropertyValue -Object $Step -Name 'capabilityId') -or [string]::IsNullOrWhiteSpace([string] $Step.capabilityId)) {
        throw "Capability step '$($Step.id)' is missing capabilityId."
    }

    if ((Test-PropertyValue -Object $Instructions -Name 'capabilityId') -and -not [string]::IsNullOrWhiteSpace([string] $Instructions.capabilityId)) {
        if ([string] $Instructions.capabilityId -ne [string] $Step.capabilityId) {
            throw "Capability id mismatch for step '$($Step.id)': step '$($Step.capabilityId)' differs from instructions '$($Instructions.capabilityId)'."
        }
    }
}

function Assert-ExecutionModeCompatible {
    param(
        [Parameter(Mandatory = $true)][object] $Step,
        [Parameter(Mandatory = $true)][object] $Capability
    )

    if ((Test-PropertyValue -Object $Step -Name 'executionMode') -and -not [string]::IsNullOrWhiteSpace([string] $Step.executionMode)) {
        if ([string] $Step.executionMode -ne [string] $Capability.executionMode) {
            throw "Execution mode conflict for capability '$($Capability.capabilityId)' on step '$($Step.id)': builder '$($Step.executionMode)' differs from capability '$($Capability.executionMode)'."
        }
    }
}

function Resolve-DeploymentCapabilityStep {
    param([Parameter(Mandatory = $true)][object] $Step)

    if (-not (Test-PropertyValue -Object $Step -Name 'capabilityId') -or [string]::IsNullOrWhiteSpace([string] $Step.capabilityId)) {
        return $Step
    }

    $capability = Get-DeploymentCapability -CapabilityId ([string] $Step.capabilityId)
    $instructions = if (Test-PropertyValue -Object $Step -Name 'instructions') { $Step.instructions } else { [pscustomobject]@{} }
    Assert-CapabilityIdConsistency -Step $Step -Instructions $instructions
    Assert-ExecutionModeCompatible -Step $Step -Capability $capability

    if (-not (Test-PropertyValue -Object $instructions -Name 'displayCommand')) {
        Add-Member -InputObject $instructions -MemberType NoteProperty -Name 'displayCommand' -Value $capability.displayCommand
    } else {
        $instructions.displayCommand = $capability.displayCommand
    }

    if (-not (Test-PropertyValue -Object $instructions -Name 'command')) {
        Add-Member -InputObject $instructions -MemberType NoteProperty -Name 'command' -Value $capability.displayCommand
    } else {
        $instructions.command = $capability.displayCommand
    }

    if (-not (Test-PropertyValue -Object $instructions -Name 'requiredResponse') -or [string]::IsNullOrWhiteSpace([string] $instructions.requiredResponse)) {
        Add-Member -InputObject $instructions -MemberType NoteProperty -Name 'requiredResponse' -Value $capability.validationRules.requiredResponse -Force
    }

    $builderRequiresBackupConfirmation = $false
    if (Test-PropertyValue -Object $instructions -Name 'requiresBackupConfirmation') {
        $builderRequiresBackupConfirmation = [bool] $instructions.requiresBackupConfirmation
    }
    $resolvedRequiresBackupConfirmation = ($builderRequiresBackupConfirmation -or [bool] $capability.requiresBackupConfirmation)
    if (-not (Test-PropertyValue -Object $instructions -Name 'requiresBackupConfirmation')) {
        Add-Member -InputObject $instructions -MemberType NoteProperty -Name 'requiresBackupConfirmation' -Value $resolvedRequiresBackupConfirmation
    } else {
        $instructions.requiresBackupConfirmation = $resolvedRequiresBackupConfirmation
    }

    if (-not (Test-PropertyValue -Object $instructions -Name 'capabilityId')) {
        Add-Member -InputObject $instructions -MemberType NoteProperty -Name 'capabilityId' -Value $capability.capabilityId
    } else {
        $instructions.capabilityId = $capability.capabilityId
    }

    $Step.instructions = $instructions
    $Step.executionMode = $capability.executionMode
    $Step.riskLevel = Merge-RiskLevel -BuilderRiskLevel ([string] $Step.riskLevel) -CapabilityRiskLevel ([string] $capability.riskLevel)
    $Step.approvalRequired = Merge-ApprovalRequired -BuilderApprovalRequired ([bool] $Step.approvalRequired) -CapabilityApprovalRequired ([bool] $capability.approvalRequired)
    $Step.validation = Merge-ValidationRules -BuilderValidation $Step.validation -CapabilityValidation $capability.validationRules
    $Step.continuation = Merge-ContinuationRules -BuilderContinuation $Step.continuation -CapabilityContinuation $capability.continuationRules -CapabilityId $capability.capabilityId

    return $Step
}

function Resolve-DeploymentCapabilities {
    param([Parameter(Mandatory = $true)][object] $Plan)

    $resolvedPlan = Copy-DeploymentPlanObject -InputObject $Plan
    $resolvedSteps = @(
        foreach ($step in @($resolvedPlan.steps)) {
            Resolve-DeploymentCapabilityStep -Step $step
        }
    )

    $resolvedPlan.steps = $resolvedSteps
    if (-not (Test-PropertyValue -Object $resolvedPlan -Name 'resolved')) {
        Add-Member -InputObject $resolvedPlan -MemberType NoteProperty -Name 'resolved' -Value $true
    } else {
        $resolvedPlan.resolved = $true
    }

    return $resolvedPlan
}

if ($MyInvocation.InvocationName -ne '.') {
    if ([string]::IsNullOrWhiteSpace($PlanPath)) {
        throw "Missing required parameter: -PlanPath"
    }

    $plan = Read-JsonFile -Path $PlanPath
    $resolvedPlan = Resolve-DeploymentCapabilities -Plan $plan

    if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
        $resolvedOutputPath = Resolve-LocalPath -Path $OutputPath
        $outputDirectory = Split-Path -Path $resolvedOutputPath -Parent
        if (-not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
            throw "Output directory does not exist: $outputDirectory"
        }
        $resolvedPlan | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $resolvedOutputPath -Encoding utf8
    }

    $resolvedPlan | ConvertTo-Json -Depth 30
}
