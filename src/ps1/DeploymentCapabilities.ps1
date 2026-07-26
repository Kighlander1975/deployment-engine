Set-StrictMode -Version Latest

function New-CapabilityValidationRule {
    param(
        [bool] $RequiresOutput = $false,
        [bool] $RequiresExitCode = $false,
        [string[]] $SuccessPatterns = @(),
        [string[]] $FailurePatterns = @(),
        [bool] $AmbiguousWithoutSuccessMatch = $false,
        [bool] $VerificationCommandRequired = $false,
        [string] $RequiredResponse = 'Keine Konsolenausgabe erforderlich.'
    )

    return [pscustomobject]@{
        requiresOutput = $RequiresOutput
        requiresExitCode = $RequiresExitCode
        successPatterns = @($SuccessPatterns)
        failurePatterns = @($FailurePatterns)
        ambiguousWithoutSuccessMatch = $AmbiguousWithoutSuccessMatch
        verificationCommandRequired = $VerificationCommandRequired
        requiredResponse = $RequiredResponse
    }
}

function New-CapabilityContinuationRule {
    param(
        [string[]] $AllowedStatuses = @('completed', 'skipped'),
        [bool] $BlocksAutomaticContinuation = $false,
        [string] $RequiredUserAction = ''
    )

    return [pscustomobject]@{
        allowedStatusesForDependents = @($AllowedStatuses)
        blocksAutomaticContinuation = $BlocksAutomaticContinuation
        requiredUserAction = $RequiredUserAction
    }
}

function Get-ForbiddenDeploymentCommands {
    return @(
        'php artisan migrate:fresh',
        'php artisan migrate:refresh',
        'php artisan migrate:reset',
        'php artisan migrate:rollback',
        'php artisan db:wipe'
    )
}

function Assert-DeploymentCommandAllowed {
    param([Parameter(Mandatory = $true)][string] $Command)

    $normalizedCommand = ($Command -replace '\s+', ' ').Trim().ToLowerInvariant()
    foreach ($forbiddenCommand in Get-ForbiddenDeploymentCommands) {
        if ($normalizedCommand -eq $forbiddenCommand -or $normalizedCommand.StartsWith("$forbiddenCommand ")) {
            throw "Forbidden deployment command rejected: '$Command'. This command must never be proposed by the Capability Catalog."
        }
    }
}

function Get-DeploymentCapabilityCatalog {
    $catalog = @{
        'composer.install.production' = [pscustomobject]@{
            capabilityId = 'composer.install.production'
            displayCommand = 'composer install --no-dev --optimize-autoloader'
            executionMode = 'human'
            riskLevel = 'normal'
            approvalRequired = $true
            validationRules = New-CapabilityValidationRule -RequiresOutput $true -SuccessPatterns @('Generating optimized autoload files', 'Nothing to install, update or remove') -FailurePatterns @('ERROR', 'Exception', 'failed', 'Could not', 'Script .* returned with error code') -AmbiguousWithoutSuccessMatch $true -RequiredResponse 'Vollstaendige relevante Composer-Konsolenausgabe'
            continuationRules = New-CapabilityContinuationRule -BlocksAutomaticContinuation $true -RequiredUserAction 'Der Prozess wartet auf Konsolenausgabe und erfolgreiche Bewertung.'
            requiresBackupConfirmation = $false
        }
        'artisan.migrate.status' = [pscustomobject]@{
            capabilityId = 'artisan.migrate.status'
            displayCommand = 'php artisan migrate:status'
            executionMode = 'human'
            riskLevel = 'high'
            approvalRequired = $true
            validationRules = New-CapabilityValidationRule -RequiresOutput $true -SuccessPatterns @('Migration', 'Ran?') -FailurePatterns @('ERROR', 'Exception', 'SQLSTATE', 'failed') -AmbiguousWithoutSuccessMatch $true -RequiredResponse 'Vollstaendige relevante Konsolenausgabe von migrate:status'
            continuationRules = New-CapabilityContinuationRule -BlocksAutomaticContinuation $true -RequiredUserAction 'Der Prozess wartet auf migrate:status-Ausgabe und Bewertung.'
            requiresBackupConfirmation = $true
        }
        'artisan.migrate' = [pscustomobject]@{
            capabilityId = 'artisan.migrate'
            displayCommand = 'php artisan migrate --force'
            executionMode = 'human'
            riskLevel = 'high'
            approvalRequired = $true
            validationRules = New-CapabilityValidationRule -RequiresOutput $true -SuccessPatterns @('Migrated:', 'Nothing to migrate') -FailurePatterns @('ERROR', 'Exception', 'Migration failed', 'SQLSTATE') -AmbiguousWithoutSuccessMatch $true -RequiredResponse 'Vollstaendige relevante Konsolenausgabe'
            continuationRules = New-CapabilityContinuationRule -BlocksAutomaticContinuation $true -RequiredUserAction 'Der Prozess wartet auf Konsolenausgabe und erfolgreiche Bewertung.'
            requiresBackupConfirmation = $true
        }
        'artisan.optimize.clear' = [pscustomobject]@{
            capabilityId = 'artisan.optimize.clear'
            displayCommand = 'php artisan optimize:clear'
            executionMode = 'human'
            riskLevel = 'normal'
            approvalRequired = $true
            validationRules = New-CapabilityValidationRule -RequiresOutput $true -SuccessPatterns @('cleared', 'Caches cleared successfully') -FailurePatterns @('ERROR', 'Exception', 'failed', 'Permission denied') -AmbiguousWithoutSuccessMatch $true -RequiredResponse 'Vollstaendige relevante Konsolenausgabe'
            continuationRules = New-CapabilityContinuationRule -BlocksAutomaticContinuation $true -RequiredUserAction 'Der Prozess wartet auf Konsolenausgabe und erfolgreiche Bewertung.'
            requiresBackupConfirmation = $false
        }
        'artisan.about' = [pscustomobject]@{
            capabilityId = 'artisan.about'
            displayCommand = 'php artisan about'
            executionMode = 'human'
            riskLevel = 'normal'
            approvalRequired = $true
            validationRules = New-CapabilityValidationRule -RequiresOutput $true -SuccessPatterns @('Environment', 'Laravel') -FailurePatterns @('ERROR', 'Exception', 'failed', 'SQLSTATE') -AmbiguousWithoutSuccessMatch $true -VerificationCommandRequired $true -RequiredResponse 'Vollstaendige relevante Verifikationsausgabe'
            continuationRules = New-CapabilityContinuationRule -BlocksAutomaticContinuation $true -RequiredUserAction 'Der Prozess wartet auf Verifikationsausgabe und erfolgreiche Bewertung.'
            requiresBackupConfirmation = $false
        }
        'deployment.marker.read' = [pscustomobject]@{
            capabilityId = 'deployment.marker.read'
            displayCommand = ''
            executionMode = 'agent'
            riskLevel = 'low'
            approvalRequired = $false
            validationRules = New-CapabilityValidationRule
            continuationRules = New-CapabilityContinuationRule
            requiresBackupConfirmation = $false
        }
        'deployment.marker.write' = [pscustomobject]@{
            capabilityId = 'deployment.marker.write'
            displayCommand = ''
            executionMode = 'review'
            riskLevel = 'high'
            approvalRequired = $true
            validationRules = New-CapabilityValidationRule -RequiredResponse 'Finale Freigabe nach nachweislich erfolgreicher Verifikation.'
            continuationRules = New-CapabilityContinuationRule -BlocksAutomaticContinuation $true -RequiredUserAction 'Marker-Update bleibt bis zum vollstaendigen Erfolg blockiert.'
            requiresBackupConfirmation = $false
        }
        'archive.create' = [pscustomobject]@{
            capabilityId = 'archive.create'
            displayCommand = ''
            executionMode = 'agent'
            riskLevel = 'normal'
            approvalRequired = $false
            validationRules = New-CapabilityValidationRule
            continuationRules = New-CapabilityContinuationRule
            requiresBackupConfirmation = $false
        }
    }

    foreach ($capability in $catalog.Values) {
        if (-not [string]::IsNullOrWhiteSpace($capability.displayCommand)) {
            Assert-DeploymentCommandAllowed -Command $capability.displayCommand
        }
    }

    return $catalog
}

function Get-DeploymentCapability {
    param([Parameter(Mandatory = $true)][string] $CapabilityId)

    $catalog = Get-DeploymentCapabilityCatalog
    if (-not $catalog.ContainsKey($CapabilityId)) {
        throw "Unknown deployment capability: '$CapabilityId'."
    }

    return $catalog[$CapabilityId]
}

function Get-RiskLevelRank {
    param([string] $RiskLevel)

    switch ($RiskLevel) {
        'low' { return 1 }
        'normal' { return 2 }
        'high' { return 3 }
        default { return 2 }
    }
}

function Merge-RiskLevel {
    param([string] $BuilderRiskLevel, [string] $CapabilityRiskLevel)

    if ((Get-RiskLevelRank -RiskLevel $BuilderRiskLevel) -gt (Get-RiskLevelRank -RiskLevel $CapabilityRiskLevel)) {
        return $BuilderRiskLevel
    }

    return $CapabilityRiskLevel
}

function Merge-ApprovalRequired {
    param([bool] $BuilderApprovalRequired, [bool] $CapabilityApprovalRequired)

    return ($BuilderApprovalRequired -or $CapabilityApprovalRequired)
}

function Test-CapabilityPropertyValue {
    param(
        [object] $Object,
        [Parameter(Mandatory = $true)][string] $Name
    )

    return ($null -ne $Object -and $Object.PSObject.Properties.Name -contains $Name -and $null -ne $Object.$Name)
}

function Get-CapabilityBoolValue {
    param([object] $Object, [Parameter(Mandatory = $true)][string] $Name)

    if (Test-CapabilityPropertyValue -Object $Object -Name $Name) {
        return [bool] $Object.$Name
    }

    return $false
}

function Get-CapabilityStringValue {
    param([object] $Object, [Parameter(Mandatory = $true)][string] $Name)

    if (Test-CapabilityPropertyValue -Object $Object -Name $Name) {
        return [string] $Object.$Name
    }

    return ''
}

function Get-CapabilityStringArrayValue {
    param([object] $Object, [Parameter(Mandatory = $true)][string] $Name)

    if (-not (Test-CapabilityPropertyValue -Object $Object -Name $Name)) {
        return @()
    }

    $items = New-Object System.Collections.Generic.List[string]
    foreach ($item in @($Object.$Name)) {
        if ($null -ne $item -and -not [string]::IsNullOrWhiteSpace([string] $item)) {
            $items.Add([string] $item)
        }
    }

    return $items.ToArray()
}

function Merge-UniqueStringArray {
    param(
        [string[]] $CapabilityValues = @(),
        [string[]] $BuilderValues = @()
    )

    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $merged = New-Object System.Collections.Generic.List[string]

    foreach ($value in @($CapabilityValues + $BuilderValues)) {
        if ([string]::IsNullOrWhiteSpace($value)) {
            continue
        }
        if ($seen.Add($value)) {
            $merged.Add($value)
        }
    }

    return $merged.ToArray()
}

function Test-NeutralRequirementText {
    param([string] $Value)

    return ([string]::IsNullOrWhiteSpace($Value) -or $Value -eq 'Keine Konsolenausgabe erforderlich.')
}

function Merge-RequirementText {
    param(
        [string] $CapabilityValue,
        [string] $BuilderValue,
        [string] $NeutralResult = 'Keine Konsolenausgabe erforderlich.'
    )

    if (Test-NeutralRequirementText -Value $CapabilityValue) {
        if (Test-NeutralRequirementText -Value $BuilderValue) {
            return $NeutralResult
        }
        return $BuilderValue
    }

    if (Test-NeutralRequirementText -Value $BuilderValue) {
        return $CapabilityValue
    }

    if ($CapabilityValue -eq $BuilderValue) {
        return $CapabilityValue
    }

    return "$CapabilityValue; zusaetzlich: $BuilderValue"
}

function Merge-ValidationRules {
    param([object] $BuilderValidation, [object] $CapabilityValidation)

    return [pscustomobject]@{
        requiresOutput = ((Get-CapabilityBoolValue -Object $CapabilityValidation -Name 'requiresOutput') -or (Get-CapabilityBoolValue -Object $BuilderValidation -Name 'requiresOutput'))
        requiresExitCode = ((Get-CapabilityBoolValue -Object $CapabilityValidation -Name 'requiresExitCode') -or (Get-CapabilityBoolValue -Object $BuilderValidation -Name 'requiresExitCode'))
        successPatterns = Merge-UniqueStringArray -CapabilityValues (Get-CapabilityStringArrayValue -Object $CapabilityValidation -Name 'successPatterns') -BuilderValues (Get-CapabilityStringArrayValue -Object $BuilderValidation -Name 'successPatterns')
        failurePatterns = Merge-UniqueStringArray -CapabilityValues (Get-CapabilityStringArrayValue -Object $CapabilityValidation -Name 'failurePatterns') -BuilderValues (Get-CapabilityStringArrayValue -Object $BuilderValidation -Name 'failurePatterns')
        ambiguousWithoutSuccessMatch = ((Get-CapabilityBoolValue -Object $CapabilityValidation -Name 'ambiguousWithoutSuccessMatch') -or (Get-CapabilityBoolValue -Object $BuilderValidation -Name 'ambiguousWithoutSuccessMatch'))
        verificationCommandRequired = ((Get-CapabilityBoolValue -Object $CapabilityValidation -Name 'verificationCommandRequired') -or (Get-CapabilityBoolValue -Object $BuilderValidation -Name 'verificationCommandRequired'))
        requiredResponse = Merge-RequirementText -CapabilityValue (Get-CapabilityStringValue -Object $CapabilityValidation -Name 'requiredResponse') -BuilderValue (Get-CapabilityStringValue -Object $BuilderValidation -Name 'requiredResponse') -NeutralResult 'Keine Konsolenausgabe erforderlich.'
    }
}

function Merge-AllowedStatuses {
    param(
        [Parameter(Mandatory = $true)][string] $CapabilityId,
        [string[]] $CapabilityValues = @(),
        [string[]] $BuilderValues = @()
    )

    $capabilityStatuses = @(Merge-UniqueStringArray -CapabilityValues $CapabilityValues -BuilderValues @())
    $builderStatuses = @(Merge-UniqueStringArray -CapabilityValues $BuilderValues -BuilderValues @())

    if ($capabilityStatuses.Count -eq 0) {
        return $builderStatuses
    }

    if ($builderStatuses.Count -eq 0) {
        return $capabilityStatuses
    }

    $builderSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($status in $builderStatuses) {
        [void] $builderSet.Add($status)
    }

    $intersection = New-Object System.Collections.Generic.List[string]
    foreach ($status in $capabilityStatuses) {
        if ($builderSet.Contains($status)) {
            $intersection.Add($status)
        }
    }

    if ($intersection.Count -eq 0) {
        throw "Continuation rules for capability '$CapabilityId' have no compatible allowed statuses."
    }

    return $intersection.ToArray()
}

function Merge-ContinuationRules {
    param(
        [object] $BuilderContinuation,
        [object] $CapabilityContinuation,
        [string] $CapabilityId = ''
    )

    return [pscustomobject]@{
        allowedStatusesForDependents = Merge-AllowedStatuses -CapabilityId $CapabilityId -CapabilityValues (Get-CapabilityStringArrayValue -Object $CapabilityContinuation -Name 'allowedStatusesForDependents') -BuilderValues (Get-CapabilityStringArrayValue -Object $BuilderContinuation -Name 'allowedStatusesForDependents')
        blocksAutomaticContinuation = ((Get-CapabilityBoolValue -Object $CapabilityContinuation -Name 'blocksAutomaticContinuation') -or (Get-CapabilityBoolValue -Object $BuilderContinuation -Name 'blocksAutomaticContinuation'))
        requiredUserAction = Merge-RequirementText -CapabilityValue (Get-CapabilityStringValue -Object $CapabilityContinuation -Name 'requiredUserAction') -BuilderValue (Get-CapabilityStringValue -Object $BuilderContinuation -Name 'requiredUserAction') -NeutralResult ''
    }
}
