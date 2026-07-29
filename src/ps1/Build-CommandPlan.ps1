[CmdletBinding()]
param(
    [string] $ExecutionPlanPath,
    [string] $DeploymentStrategyPath,
    [string] $RuntimeArtifactPath,
    [string] $PackagingPolicyPath,
    [string] $DeploymentRunId,
    [string] $OutputPath,
    [string] $Format = 'Json'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path -Path $PSScriptRoot -ChildPath 'DeploymentAdapters.ps1')

function Resolve-CommandPlanPath {
    param([Parameter(Mandatory = $true)][string] $Path)

    $executionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function Read-CommandPlanJsonFile {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Description
    )

    $resolved = Resolve-CommandPlanPath -Path $Path
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
        throw "$Description file does not exist: $resolved"
    }

    try {
        return (Get-Content -LiteralPath $resolved -Raw | ConvertFrom-Json)
    } catch {
        throw "Invalid $Description JSON in '$resolved': $($_.Exception.Message)"
    }
}

function Test-CommandPlanProperty {
    param([object] $Object, [Parameter(Mandatory = $true)][string] $Name)

    return ($null -ne $Object -and @($Object.PSObject.Properties | Where-Object { $_.Name -eq $Name }).Count -gt 0)
}

function Test-CommandPlanObjectLike {
    param([object] $Value)

    if ($null -eq $Value -or $Value -is [string] -or $Value -is [System.ValueType]) {
        return $false
    }
    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [System.Collections.IDictionary]) -and -not ($Value -is [pscustomobject])) {
        return $false
    }

    return ($null -ne $Value.PSObject -and $null -ne $Value.PSObject.Properties)
}

function Assert-CommandPlanString {
    param(
        [Parameter(Mandatory = $true)][object] $Object,
        [Parameter(Mandatory = $true)][string] $Name,
        [Parameter(Mandatory = $true)][string] $Context,
        [bool] $AllowEmpty = $false
    )

    if (-not (Test-CommandPlanProperty -Object $Object -Name $Name)) {
        throw "$Context validation failed: missing required field '$Name'."
    }
    if (-not ($Object.$Name -is [string])) {
        throw "$Context validation failed: field '$Name' must be a string."
    }
    if (-not $AllowEmpty -and [string]::IsNullOrWhiteSpace([string] $Object.$Name)) {
        throw "$Context validation failed: field '$Name' must not be empty."
    }
}

function Assert-CommandPlanBool {
    param(
        [Parameter(Mandatory = $true)][object] $Object,
        [Parameter(Mandatory = $true)][string] $Name,
        [Parameter(Mandatory = $true)][string] $Context
    )

    if (-not (Test-CommandPlanProperty -Object $Object -Name $Name)) {
        throw "$Context validation failed: missing required field '$Name'."
    }
    if (-not ($Object.$Name -is [bool])) {
        throw "$Context validation failed: field '$Name' must be boolean."
    }
}

function Assert-CommandPlanInteger {
    param(
        [Parameter(Mandatory = $true)][object] $Value,
        [Parameter(Mandatory = $true)][string] $Context,
        [Parameter(Mandatory = $true)][string] $Field
    )

    if (-not ($Value -is [byte] -or $Value -is [int16] -or $Value -is [int] -or $Value -is [long])) {
        throw "$Context validation failed: field '$Field' must be an integer."
    }
}

function Assert-CommandPlanStatus {
    param(
        [Parameter(Mandatory = $true)][string] $Status,
        [Parameter(Mandatory = $true)][string[]] $AllowedStatuses,
        [Parameter(Mandatory = $true)][string] $Context
    )

    if ($Status -notin $AllowedStatuses) {
        throw "$Context validation failed: unsupported status '$Status'."
    }
}

function Test-AbsolutePosixPath {
    param([string] $Path)

    return (-not [string]::IsNullOrWhiteSpace($Path) -and $Path.StartsWith('/') -and -not $Path.StartsWith('//') -and $Path -notmatch '(^|/)\.\.?(/|$)')
}

function Test-SecretLikeText {
    param([string] $Text)

    if ([string]::IsNullOrEmpty($Text)) {
        return $false
    }

    return ($Text -match '(?i)(password\s*=|token\s*=|private key|BEGIN (?:OPENSSH |RSA |EC |DSA )?PRIVATE KEY|api[_-]?key\s*=|client[_-]?secret\s*=|credential\s*=)' -or
        $Text -match '(?m)(^|[\s;])(?:[A-Z][A-Z0-9_]{1,})\s*=')
}

function Test-SensitiveCommandPlanFieldName {
    param([string] $Name)

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $false
    }

    return ($Name -match '(?i)(password|token|secret|privateKey|private_key|apiKey|api_key|clientSecret|client_secret|credential)')
}

function Test-CommandPayloadFieldName {
    param([string] $Name)

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $false
    }

    return ($Name -in @('arguments', 'renderedCommand', 'command', 'displayCommand', 'operation', 'environment'))
}

function Test-NonEmptyScalarValue {
    param([object] $Value)

    if ($null -eq $Value) {
        return $false
    }
    if ($Value -is [string]) {
        return (-not [string]::IsNullOrWhiteSpace([string] $Value))
    }

    return $false
}

function Assert-NoCommandPlanSecrets {
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object] $Value,
        [Parameter(Mandatory = $true)][string] $Context,
        [string] $FieldName = ''
    )

    if ($null -eq $Value) {
        return
    }

    if (Test-SensitiveCommandPlanFieldName -Name $FieldName) {
        if (Test-NonEmptyScalarValue -Value $Value) {
            throw "$Context validation failed: sensitive field '$FieldName' must not contain a value."
        }
    }

    if ($Value -is [string]) {
        if (Test-SecretLikeText -Text ([string] $Value)) {
            throw "$Context validation failed: secret-like value is not allowed in field '$FieldName'."
        }
        return
    }
    if ($Value -is [datetime] -or $Value -is [bool] -or $Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal]) {
        return
    }

    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($key in $Value.Keys) {
            Assert-NoCommandPlanSecrets -Value $Value[$key] -Context $Context -FieldName ([string] $key)
        }
        return
    }

    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string]) -and -not ($Value -is [pscustomobject])) {
        foreach ($item in @($Value)) {
            Assert-NoCommandPlanSecrets -Value $item -Context $Context -FieldName $FieldName
        }
        return
    }

    if ($null -ne $Value.PSObject -and $null -ne $Value.PSObject.Properties) {
        foreach ($property in @($Value.PSObject.Properties)) {
            Assert-NoCommandPlanSecrets -Value $property.Value -Context $Context -FieldName ([string] $property.Name)
        }
    }
}

function Assert-ResolvedExecutionPlanForCommandGeneration {
    param([Parameter(Mandatory = $true)][object] $ExecutionPlan)

    if ($null -eq $ExecutionPlan) {
        throw "Command generation validation failed: resolved execution plan is missing."
    }
    Assert-CommandPlanString -Object $ExecutionPlan -Name 'schemaVersion' -Context 'Resolved execution plan'
    if ($ExecutionPlan.schemaVersion -ne '0.1') {
        throw "Resolved execution plan validation failed: unsupported schemaVersion '$($ExecutionPlan.schemaVersion)'."
    }
    if (-not (Test-CommandPlanProperty -Object $ExecutionPlan -Name 'resolved') -or $ExecutionPlan.resolved -ne $true) {
        throw "Resolved execution plan validation failed: expected resolved = true."
    }
    foreach ($field in @('project', 'environment', 'steps')) {
        if (-not (Test-CommandPlanProperty -Object $ExecutionPlan -Name $field) -or $null -eq $ExecutionPlan.$field) {
            throw "Resolved execution plan validation failed: missing required field '$field'."
        }
    }
    Assert-CommandPlanString -Object $ExecutionPlan.project -Name 'id' -Context 'Resolved execution plan project'
    Assert-CommandPlanString -Object $ExecutionPlan.environment -Name 'name' -Context 'Resolved execution plan environment'
    Assert-CommandPlanString -Object $ExecutionPlan.environment -Name 'applicationRemoteDirectory' -Context 'Resolved execution plan environment'
    if (-not (Test-AbsolutePosixPath -Path ([string] $ExecutionPlan.environment.applicationRemoteDirectory))) {
        throw "Resolved execution plan validation failed: applicationRemoteDirectory must be an absolute remote path."
    }

    $stepIds = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    foreach ($step in @($ExecutionPlan.steps)) {
        if (-not (Test-CommandPlanObjectLike -Value $step)) {
            throw "Resolved execution plan validation failed: each step must be an object."
        }
        Assert-CommandPlanString -Object $step -Name 'id' -Context 'Resolved execution plan step'
        if (-not $stepIds.Add([string] $step.id)) {
            throw "Resolved execution plan validation failed: duplicate step id '$($step.id)'."
        }
    }
    Assert-NoCommandPlanSecrets -Value $ExecutionPlan -Context 'Resolved execution plan'
}

function Assert-DeploymentStrategyForCommandGeneration {
    param(
        [Parameter(Mandatory = $true)][object] $DeploymentStrategy,
        [object] $AdapterCatalog = (Get-DeploymentAdapterCatalog)
    )

    if ($null -eq $DeploymentStrategy) {
        throw "Command generation validation failed: deployment strategy is missing."
    }
    Assert-CommandPlanString -Object $DeploymentStrategy -Name 'schemaVersion' -Context 'Deployment strategy'
    if ($DeploymentStrategy.schemaVersion -ne '0.1') {
        throw "Deployment strategy validation failed: unsupported schemaVersion '$($DeploymentStrategy.schemaVersion)'."
    }
    Assert-CommandPlanString -Object $DeploymentStrategy -Name 'strategyType' -Context 'Deployment strategy'
    if ($DeploymentStrategy.strategyType -ne 'deployment') {
        throw "Deployment strategy validation failed: strategyType must be 'deployment'."
    }
    Assert-CommandPlanString -Object $DeploymentStrategy -Name 'status' -Context 'Deployment strategy'
    if ($DeploymentStrategy.status -ne 'ready') {
        throw "Deployment strategy validation failed: status must be 'ready' before command generation."
    }
    Assert-CommandPlanString -Object $DeploymentStrategy -Name 'selectedAdapterId' -Context 'Deployment strategy'
    if (-not $AdapterCatalog.Contains([string] $DeploymentStrategy.selectedAdapterId)) {
        throw "Deployment strategy validation failed: unknown selected adapter id '$($DeploymentStrategy.selectedAdapterId)'."
    }
    if (-not (Test-CommandPlanProperty -Object $DeploymentStrategy -Name 'steps') -or $null -eq $DeploymentStrategy.steps -or @($DeploymentStrategy.steps).Count -eq 0) {
        throw "Deployment strategy validation failed: steps must not be empty."
    }
    if (-not (Test-CommandPlanProperty -Object $DeploymentStrategy -Name 'humanGates') -or $null -eq $DeploymentStrategy.humanGates) {
        throw "Deployment strategy validation failed: humanGates must not be null."
    }

    $stepIds = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    $sequences = New-Object 'System.Collections.Generic.HashSet[int]'
    foreach ($step in @($DeploymentStrategy.steps)) {
        if (-not (Test-CommandPlanObjectLike -Value $step)) {
            throw "Deployment strategy validation failed: each step must be an object."
        }
        Assert-CommandPlanString -Object $step -Name 'stepId' -Context 'Deployment strategy step'
        $stepId = [string] $step.stepId
        if (-not $stepIds.Add($stepId)) {
            throw "Deployment strategy validation failed: duplicate step id '$stepId'."
        }
        foreach ($field in @('sequence', 'commandGenerationRequired')) {
            if (-not (Test-CommandPlanProperty -Object $step -Name $field)) {
                throw "Deployment strategy step '$stepId' validation failed: missing required field '$field'."
            }
        }
        Assert-CommandPlanInteger -Value $step.sequence -Context "Deployment strategy step '$stepId'" -Field 'sequence'
        [void] $sequences.Add([int] $step.sequence)
        Assert-CommandPlanString -Object $step -Name 'operationType' -Context "Deployment strategy step '$stepId'"
        Assert-CommandPlanString -Object $step -Name 'actor' -Context "Deployment strategy step '$stepId'"
        Assert-CommandPlanStatus -Status ([string] $step.actor) -AllowedStatuses @('automation', 'human-decision', 'human-command', 'review') -Context "Deployment strategy step '$stepId'"
        Assert-CommandPlanString -Object $step -Name 'executionLocation' -Context "Deployment strategy step '$stepId'"
        Assert-CommandPlanStatus -Status ([string] $step.executionLocation) -AllowedStatuses @('local', 'remote', 'artifact-transport', 'decision', 'review') -Context "Deployment strategy step '$stepId'"
        if ($step.operationType -eq 'artifact-upload' -and $step.executionLocation -ne 'artifact-transport') {
            throw "Deployment strategy step '$stepId' validation failed: artifact-upload requires executionLocation artifact-transport."
        }
        if ($step.operationType -in @('release-directory-prepare', 'release-prepare', 'archive-extract', 'composer-preflight', 'composer-install', 'composer-install-validate', 'shared-storage-prepare', 'application-finalize') -and $step.executionLocation -ne 'remote') {
            throw "Deployment strategy step '$stepId' validation failed: remote operation '$($step.operationType)' requires executionLocation remote."
        }
        Assert-CommandPlanString -Object $step -Name 'commandExecutionMode' -Context "Deployment strategy step '$stepId'"
        Assert-CommandPlanStatus -Status ([string] $step.commandExecutionMode) -AllowedStatuses @('none', 'automatic', 'copy-and-run') -Context "Deployment strategy step '$stepId'"
        Assert-CommandPlanBool -Object $step -Name 'commandGenerationRequired' -Context "Deployment strategy step '$stepId'"
        Assert-CommandPlanBool -Object $step -Name 'approvalRequired' -Context "Deployment strategy step '$stepId'"
        if (-not (Test-CommandPlanProperty -Object $step -Name 'dependsOn') -or $null -eq $step.dependsOn) {
            throw "Deployment strategy step '$stepId' validation failed: missing required field 'dependsOn'."
        }
        if ($step.actor -eq 'human-command' -and $step.commandExecutionMode -ne 'copy-and-run') {
            throw "Deployment strategy step '$stepId' validation failed: human-command requires copy-and-run."
        }
        if ($step.actor -eq 'human-decision' -and $step.commandExecutionMode -ne 'none') {
            throw "Deployment strategy step '$stepId' validation failed: human-decision requires commandExecutionMode none."
        }
        if ($step.actor -eq 'review' -and $step.commandExecutionMode -ne 'none') {
            throw "Deployment strategy step '$stepId' validation failed: review requires commandExecutionMode none."
        }
        if ($step.commandExecutionMode -eq 'copy-and-run') {
            if (-not (Test-CommandPlanProperty -Object $step -Name 'feedback') -or -not (Test-CommandPlanObjectLike -Value $step.feedback)) {
                throw "Deployment strategy step '$stepId' validation failed: copy-and-run requires feedback."
            }
            Assert-CommandPlanBool -Object $step.feedback -Name 'required' -Context "Deployment strategy step '$stepId' feedback"
            if (-not $step.feedback.required) {
                throw "Deployment strategy step '$stepId' validation failed: copy-and-run feedback must be required."
            }
        }
    }

    foreach ($step in @($DeploymentStrategy.steps)) {
        foreach ($dependency in @($step.dependsOn | Sort-Object -Unique)) {
            $dependencyId = [string] $dependency
            if ([string]::IsNullOrWhiteSpace($dependencyId)) {
                continue
            }
            if (-not $stepIds.Contains($dependencyId)) {
                throw "Deployment strategy validation failed: step '$($step.stepId)' depends on unknown step '$dependencyId'."
            }
        }
    }

    $approvalGates = @($DeploymentStrategy.humanGates | Where-Object { $_.gateId -eq 'deployment.approval' })
    if ($approvalGates.Count -ne 1) {
        throw "Deployment strategy validation failed: exactly one central deployment approval gate is required."
    }
    foreach ($gate in @($DeploymentStrategy.humanGates)) {
        if (-not (Test-CommandPlanObjectLike -Value $gate)) {
            throw "Deployment strategy validation failed: each human gate must be an object."
        }
        Assert-CommandPlanString -Object $gate -Name 'gateId' -Context 'Deployment strategy human gate'
        Assert-CommandPlanString -Object $gate -Name 'stepId' -Context "Deployment strategy human gate '$($gate.gateId)'"
        $gateStep = @($DeploymentStrategy.steps | Where-Object { $_.stepId -eq [string] $gate.stepId } | Select-Object -First 1)
        if ($gateStep.Count -eq 0) {
            throw "Deployment strategy human gate '$($gate.gateId)' validation failed: stepId '$($gate.stepId)' does not reference a strategy step."
        }
        if ($gateStep[0].actor -ne 'human-decision') {
            throw "Deployment strategy human gate '$($gate.gateId)' validation failed: referenced strategy step must use actor human-decision."
        }
    }
    if (-not (Test-CommandPlanProperty -Object $DeploymentStrategy -Name 'artifactTransport') -or -not (Test-CommandPlanObjectLike -Value $DeploymentStrategy.artifactTransport)) {
        throw "Deployment strategy validation failed: artifactTransport contract is required."
    }
    Assert-CommandPlanString -Object $DeploymentStrategy.artifactTransport -Name 'adapterId' -Context 'Deployment strategy artifactTransport'
    if ($DeploymentStrategy.artifactTransport.adapterId -ne 'network-share') {
        throw "Deployment strategy validation failed: unsupported artifact transport adapter '$($DeploymentStrategy.artifactTransport.adapterId)'."
    }
    if (-not (Test-CommandPlanProperty -Object $DeploymentStrategy -Name 'remoteExecution') -or -not (Test-CommandPlanObjectLike -Value $DeploymentStrategy.remoteExecution)) {
        throw "Deployment strategy validation failed: remoteExecution contract is required."
    }
    Assert-CommandPlanString -Object $DeploymentStrategy.remoteExecution -Name 'mode' -Context 'Deployment strategy remoteExecution'
    if ($DeploymentStrategy.remoteExecution.mode -ne 'interactive-ssh') {
        throw "Deployment strategy validation failed: unsupported remote execution mode '$($DeploymentStrategy.remoteExecution.mode)'."
    }
    if (-not (Test-CommandPlanProperty -Object $DeploymentStrategy -Name 'deploymentWorkspace') -or -not (Test-CommandPlanObjectLike -Value $DeploymentStrategy.deploymentWorkspace)) {
        throw "Deployment strategy validation failed: deploymentWorkspace contract is required."
    }
    foreach ($field in @('baseDirectory', 'uploadsDirectory', 'workDirectory', 'releasesDirectory', 'metadataDirectory')) {
        Assert-CommandPlanString -Object $DeploymentStrategy.deploymentWorkspace -Name $field -Context 'Deployment strategy deploymentWorkspace'
    }
    if (-not (Test-CommandPlanProperty -Object $DeploymentStrategy -Name 'composerStrategy') -or -not (Test-CommandPlanObjectLike -Value $DeploymentStrategy.composerStrategy)) {
        throw "Deployment strategy validation failed: composerStrategy contract is required."
    }
    if (-not (Test-CommandPlanProperty -Object $DeploymentStrategy -Name 'sharedStorage') -or -not (Test-CommandPlanObjectLike -Value $DeploymentStrategy.sharedStorage)) {
        throw "Deployment strategy validation failed: sharedStorage contract is required."
    }
    Assert-CommandPlanBool -Object $DeploymentStrategy.sharedStorage -Name 'configurationPresent' -Context 'Deployment strategy sharedStorage'
    Assert-CommandPlanBool -Object $DeploymentStrategy.sharedStorage -Name 'rootResolved' -Context 'Deployment strategy sharedStorage'
    foreach ($field in @('composerStrategyId', 'composerStrategyVersion', 'composerExecutableResolution', 'composerWorkingDirectory', 'composerManifestPath', 'composerLockPath', 'requiredPhpVersion', 'requiredPhpExtensions', 'installMode', 'scriptsAllowed', 'pluginsAllowed', 'interactionMode', 'preferredInstallMode', 'optimizationMode', 'platformRequirementMode')) {
        Assert-CommandPlanString -Object $DeploymentStrategy.composerStrategy -Name $field -Context 'Deployment strategy composerStrategy'
    }
    foreach ($field in @('productionMode', 'devDependenciesAllowed', 'networkAccessRequired')) {
        Assert-CommandPlanBool -Object $DeploymentStrategy.composerStrategy -Name $field -Context 'Deployment strategy composerStrategy'
    }
    if (-not (Test-CommandPlanProperty -Object $DeploymentStrategy.composerStrategy -Name 'installContract') -or -not (Test-CommandPlanObjectLike -Value $DeploymentStrategy.composerStrategy.installContract)) {
        throw "Deployment strategy composerStrategy validation failed: installContract is required."
    }
    foreach ($field in @('composerCommand', 'workingDirectory', 'networkAccessPolicy', 'failureHandling', 'rollbackBehaviour')) {
        Assert-CommandPlanString -Object $DeploymentStrategy.composerStrategy.installContract -Name $field -Context 'Deployment strategy composerStrategy installContract'
    }
    foreach ($field in @('scriptExecutionPolicy', 'pluginExecutionPolicy', 'expectedVendorState', 'expectedAutoloadState', 'writeBoundary', 'postValidation')) {
        if (-not (Test-CommandPlanProperty -Object $DeploymentStrategy.composerStrategy.installContract -Name $field) -or -not (Test-CommandPlanObjectLike -Value $DeploymentStrategy.composerStrategy.installContract.$field)) {
            throw "Deployment strategy composerStrategy installContract validation failed: object '$field' is required."
        }
    }
    Assert-CommandPlanString -Object $DeploymentStrategy.composerStrategy.installContract.writeBoundary -Name 'root' -Context 'Deployment strategy composerStrategy installContract writeBoundary'
    foreach ($field in @('allowedFlags', 'forbiddenFlags')) {
        if (-not (Test-CommandPlanProperty -Object $DeploymentStrategy.composerStrategy.installContract -Name $field) -or @($DeploymentStrategy.composerStrategy.installContract.$field).Count -eq 0) {
            throw "Deployment strategy composerStrategy installContract validation failed: '$field' must not be empty."
        }
    }
    foreach ($field in @('allowedPaths', 'forbiddenPaths')) {
        if (-not (Test-CommandPlanProperty -Object $DeploymentStrategy.composerStrategy.installContract.writeBoundary -Name $field) -or @($DeploymentStrategy.composerStrategy.installContract.writeBoundary.$field).Count -eq 0) {
            throw "Deployment strategy composerStrategy installContract writeBoundary validation failed: '$field' must not be empty."
        }
    }

    $json = $DeploymentStrategy | ConvertTo-Json -Depth 50
    if ($json -match '"commands"\s*:|"renderedCommand"\s*:') {
        throw "Deployment strategy validation failed: strategy must not contain concrete commands."
    }
    Assert-NoCommandPlanSecrets -Value $DeploymentStrategy -Context 'Deployment strategy'
}

function Quote-PowerShellArgument {
    param([AllowNull()][object] $Value)

    $text = if ($null -eq $Value) { '' } else { [string] $Value }
    if ($text -match '^[A-Za-z0-9_@%+=:,./\\\\-]+$') {
        return $text
    }
    return "'" + ($text -replace "'", "''") + "'"
}

function Quote-PosixShellArgument {
    param([AllowNull()][object] $Value)

    $text = if ($null -eq $Value) { '' } else { [string] $Value }
    if ($text -match '^[A-Za-z0-9_@%+=:,./-]+$') {
        return $text
    }
    return "'" + ($text -replace "'", "'\''") + "'"
}

function ConvertTo-RenderedCommand {
    param(
        [Parameter(Mandatory = $true)][string] $Program,
        [string[]] $Arguments = @()
    )

    switch ($Program) {
        'local-operation' { return '' }
        'interactive-ssh' { return (@($Arguments) -join "`n") }
        'network-share' {
            if (@($Arguments).Count -ne 2) {
                throw "Command rendering failed: network-share requires source and destination arguments."
            }
            return "Copy-Item -LiteralPath " + (Quote-PowerShellArgument $Arguments[0]) + " -Destination " + (Quote-PowerShellArgument $Arguments[1])
        }
        default { throw "Command rendering failed: unsupported program '$Program'." }
    }
}

function Get-CommandGenerationInputs {
    param([Parameter(Mandatory = $true)][object] $DeploymentStrategy)

    if ((Test-CommandPlanProperty -Object $DeploymentStrategy -Name 'commandInputs') -and (Test-CommandPlanObjectLike -Value $DeploymentStrategy.commandInputs)) {
        return $DeploymentStrategy.commandInputs
    }

    return [pscustomobject]@{}
}

function Get-OptionalInputString {
    param([Parameter(Mandatory = $true)][object] $Inputs, [Parameter(Mandatory = $true)][string] $Name)

    if (Test-CommandPlanProperty -Object $Inputs -Name $Name) {
        return [string] $Inputs.$Name
    }

    return ''
}

function Read-OptionalRuntimeArtifact {
    param([string] $Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }

    return Read-CommandPlanJsonFile -Path $Path -Description 'Runtime artifact'
}

function Read-OptionalPackagingPolicy {
    param([string] $Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }

    return Read-CommandPlanJsonFile -Path $Path -Description 'Packaging policy'
}

function Assert-PackagingPolicyForCommandGeneration {
    param(
        [Parameter(Mandatory = $true)][object] $PackagingPolicy,
        [Parameter(Mandatory = $true)][object] $ExecutionPlan
    )

    if (-not (Test-CommandPlanObjectLike -Value $PackagingPolicy)) {
        throw 'Packaging policy validation failed: policy must be an object.'
    }
    foreach ($field in @('policyId', 'projectId', 'artifactType', 'vendorStrategy', 'executionPlanFingerprint')) {
        Assert-CommandPlanString -Object $PackagingPolicy -Name $field -Context 'Packaging policy'
    }
    if (-not (Test-CommandPlanProperty -Object $PackagingPolicy -Name 'createdAt') -or $null -eq $PackagingPolicy.createdAt -or [string]::IsNullOrWhiteSpace([string] $PackagingPolicy.createdAt)) {
        throw "Packaging policy validation failed: field 'createdAt' must not be empty."
    }
    if ($PackagingPolicy.artifactType -ne 'deployment-archive') {
        throw "Packaging policy validation failed: artifactType must be 'deployment-archive'."
    }
    foreach ($arrayField in @('includedPaths', 'excludedPaths')) {
        if (-not (Test-CommandPlanProperty -Object $PackagingPolicy -Name $arrayField) -or $null -eq $PackagingPolicy.$arrayField) {
            throw "Packaging policy validation failed: field '$arrayField' must not be null."
        }
        foreach ($entry in @($PackagingPolicy.$arrayField)) {
            if (-not ($entry -is [string]) -or [string]::IsNullOrWhiteSpace([string] $entry)) {
                throw "Packaging policy validation failed: field '$arrayField' must contain only non-empty strings."
            }
        }
    }
    Assert-CommandPlanString -Object $ExecutionPlan -Name 'executionPlanFingerprint' -Context 'Resolved execution plan'
    if ([string] $PackagingPolicy.executionPlanFingerprint -ne [string] $ExecutionPlan.executionPlanFingerprint) {
        throw 'Packaging policy validation failed: executionPlanFingerprint does not match resolved execution plan.'
    }
    Assert-NoCommandPlanSecrets -Value $PackagingPolicy -Context 'Packaging policy'
}

function Assert-RuntimeArtifactForCommandGeneration {
    param(
        [Parameter(Mandatory = $true)][object] $RuntimeArtifact,
        [Parameter(Mandatory = $true)][object] $ExecutionPlan
    )

    if (-not (Test-CommandPlanObjectLike -Value $RuntimeArtifact)) {
        throw 'Runtime artifact validation failed: artifact must be an object.'
    }
    foreach ($field in @('artifactId', 'artifactType', 'archiveFormat', 'localPath', 'fileName', 'hash', 'executionPlanFingerprint', 'packagingPolicyId', 'packagingPolicyFingerprint')) {
        Assert-CommandPlanString -Object $RuntimeArtifact -Name $field -Context 'Runtime artifact'
    }
    if (-not (Test-CommandPlanProperty -Object $RuntimeArtifact -Name 'createdAt') -or [string]::IsNullOrWhiteSpace([string] $RuntimeArtifact.createdAt)) {
        throw "Runtime artifact validation failed: field 'createdAt' must not be empty."
    }
    Assert-CommandPlanInteger -Value $RuntimeArtifact.fileSize -Context 'Runtime artifact' -Field 'fileSize'
    if ([int64] $RuntimeArtifact.fileSize -lt 0) {
        throw 'Runtime artifact validation failed: fileSize must not be negative.'
    }
    if ($RuntimeArtifact.artifactType -ne 'deployment-archive') {
        throw "Runtime artifact validation failed: unsupported artifactType '$($RuntimeArtifact.artifactType)'."
    }
    if ($RuntimeArtifact.archiveFormat -notin @('zip', 'tar')) {
        throw "Runtime artifact validation failed: unsupported archiveFormat '$($RuntimeArtifact.archiveFormat)'."
    }
    if ($RuntimeArtifact.fileName -match '[\\/]') {
        throw 'Runtime artifact validation failed: fileName must not contain path separators.'
    }
    if ($RuntimeArtifact.hash -notmatch '^[a-fA-F0-9]{64}$') {
        throw 'Runtime artifact validation failed: hash must be a SHA-256 hex string.'
    }
    if ($RuntimeArtifact.packagingPolicyFingerprint -notmatch '^[a-fA-F0-9]{64}$') {
        throw 'Runtime artifact validation failed: packagingPolicyFingerprint must be a SHA-256 hex string.'
    }
    if (-not (Test-CommandPlanProperty -Object $RuntimeArtifact -Name 'packagingValidation') -or -not (Test-CommandPlanObjectLike -Value $RuntimeArtifact.packagingValidation)) {
        throw "Runtime artifact validation failed: field 'packagingValidation' is required."
    }
    Assert-CommandPlanString -Object $ExecutionPlan -Name 'executionPlanFingerprint' -Context 'Resolved execution plan'
    if ([string] $RuntimeArtifact.executionPlanFingerprint -ne [string] $ExecutionPlan.executionPlanFingerprint) {
        throw 'Runtime artifact validation failed: executionPlanFingerprint does not match resolved execution plan.'
    }
    Assert-NoCommandPlanSecrets -Value $RuntimeArtifact -Context 'Runtime artifact'
}

function New-CommandPlanFeedback {
    param([object] $StrategyStep)

    if ((Test-CommandPlanProperty -Object $StrategyStep -Name 'feedback') -and (Test-CommandPlanObjectLike -Value $StrategyStep.feedback)) {
        return [pscustomobject]@{
            required = [bool] $StrategyStep.feedback.required
            expectedData = @($StrategyStep.feedback.expectedData | ForEach-Object { [string] $_ })
        }
    }

    return [pscustomobject]@{
        required = $false
        expectedData = @()
    }
}

function New-CommandPlanEntry {
    param(
        [Parameter(Mandatory = $true)][object] $StrategyStep,
        [Parameter(Mandatory = $true)][string] $Program,
        [string[]] $Arguments = @(),
        [string] $RenderedCommand = '',
        [string] $Title = '',
        [string] $Description = '',
        [bool] $Copyable = $false,
        [string] $Diagnostic = '',
        [object] $Operation = ([pscustomobject]@{})
    )

    return [pscustomobject]@{
        commandId = [string] $StrategyStep.stepId
        sequence = [int] $StrategyStep.sequence
        strategyStepId = [string] $StrategyStep.stepId
        operationType = [string] $StrategyStep.operationType
        actor = [string] $StrategyStep.actor
        executionLocation = [string] $StrategyStep.executionLocation
        executionMode = [string] $StrategyStep.commandExecutionMode
        dependsOn = @($StrategyStep.dependsOn | ForEach-Object { [string] $_ } | Sort-Object -Unique)
        program = $Program
        arguments = @($Arguments)
        workingDirectory = ''
        environment = [pscustomobject]@{}
        operation = ($Operation | ConvertTo-Json -Depth 20 | ConvertFrom-Json)
        renderedCommand = $RenderedCommand
        display = [pscustomobject]@{
            title = $Title
            description = $Description
            copyable = $Copyable
        }
        feedback = New-CommandPlanFeedback -StrategyStep $StrategyStep
        safety = [pscustomobject]@{
            destructive = $false
            containsSecret = $false
            requiresApproval = [bool] $StrategyStep.approvalRequired
            executionPermitted = $false
        }
        diagnostic = $Diagnostic
    }
}

function New-IncompleteCommandEntry {
    param(
        [Parameter(Mandatory = $true)][object] $StrategyStep,
        [Parameter(Mandatory = $true)][string] $Diagnostic,
        [string] $Program = 'local-operation'
    )

    return New-CommandPlanEntry -StrategyStep $StrategyStep -Program $Program -Arguments @([string] $StrategyStep.operationType) -RenderedCommand '' -Title ([string] $StrategyStep.stepId) -Description 'Command generation is incomplete.' -Copyable $false -Diagnostic $Diagnostic
}

function Join-RemoteCommandPlanPath {
    param([Parameter(Mandatory = $true)][string] $Root, [Parameter(Mandatory = $true)][string] $Child)

    return (($Root.TrimEnd('/')) + '/' + ($Child.Trim('/')))
}

function Test-RemoteCommandPlanPathInside {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Root
    )

    $normalizedPath = ($Path -replace '\\', '/').TrimEnd('/')
    $normalizedRoot = ($Root -replace '\\', '/').TrimEnd('/')
    return ($normalizedPath -eq $normalizedRoot -or $normalizedPath.StartsWith("$normalizedRoot/"))
}

function Test-RelativeCommandPlanPath {
    param([string] $Path)

    return (-not [string]::IsNullOrWhiteSpace($Path) -and -not $Path.StartsWith('/') -and -not ($Path -match '\\') -and -not ($Path -match '//') -and -not ($Path -match '(^|/)\.\.?(/|$)'))
}

function Assert-RelativeCommandPlanPath {
    param(
        [string] $Path,
        [Parameter(Mandatory = $true)][string] $Context
    )

    if (-not (Test-RelativeCommandPlanPath -Path $Path)) {
        throw "$Context validation failed: path must be relative, non-empty and must not contain traversal."
    }
}

function Get-DeploymentWorkspacePaths {
    param(
        [Parameter(Mandatory = $true)][object] $ExecutionPlan,
        [Parameter(Mandatory = $true)][object] $DeploymentStrategy
    )

    $applicationRemoteDirectory = [string] $ExecutionPlan.environment.applicationRemoteDirectory
    $workspace = $DeploymentStrategy.deploymentWorkspace
    return [pscustomobject]@{
        remoteBase = Join-RemoteCommandPlanPath -Root $applicationRemoteDirectory -Child ([string] $workspace.baseDirectory)
        remoteUploads = Join-RemoteCommandPlanPath -Root $applicationRemoteDirectory -Child ([string] $workspace.uploadsDirectory)
        remoteWork = Join-RemoteCommandPlanPath -Root $applicationRemoteDirectory -Child ([string] $workspace.workDirectory)
        remoteWorkCurrent = Join-RemoteCommandPlanPath -Root $applicationRemoteDirectory -Child ([string] $workspace.workDirectory + '/current')
        remoteReleases = Join-RemoteCommandPlanPath -Root $applicationRemoteDirectory -Child ([string] $workspace.releasesDirectory)
        remoteMetadata = Join-RemoteCommandPlanPath -Root $applicationRemoteDirectory -Child ([string] $workspace.metadataDirectory)
    }
}

function Resolve-SharedStoragePrepareContract {
    param(
        [Parameter(Mandatory = $true)][object] $ExecutionPlan,
        [Parameter(Mandatory = $true)][object] $DeploymentStrategy,
        [Parameter(Mandatory = $true)][object] $ReleasePrepare
    )

    if (-not (Test-CommandPlanProperty -Object $DeploymentStrategy -Name 'sharedStorage') -or -not (Test-CommandPlanObjectLike -Value $DeploymentStrategy.sharedStorage)) {
        throw 'Shared storage prepare validation failed: sharedStorage contract is missing.'
    }
    $sharedStorage = $DeploymentStrategy.sharedStorage
    if (-not [bool] $sharedStorage.configurationPresent) {
        throw 'Shared storage prepare validation failed: SharedStorageConfigurationPresent=false.'
    }
    if (-not [bool] $sharedStorage.rootResolved) {
        throw 'Shared storage prepare validation failed: SharedStorageRootResolved=false.'
    }
    Assert-CommandPlanString -Object $sharedStorage -Name 'root' -Context 'Shared storage contract'
    Assert-CommandPlanString -Object $sharedStorage -Name 'sharedRootAbsolutePath' -Context 'Shared storage contract'
    Assert-RelativeCommandPlanPath -Path ([string] $sharedStorage.root) -Context 'Shared storage root'

    $applicationRemoteDirectory = [string] $ExecutionPlan.environment.applicationRemoteDirectory
    $releaseDirectory = [string] $ReleasePrepare.remoteReleaseDirectory
    $sharedRootAbsolutePath = [string] $sharedStorage.sharedRootAbsolutePath
    if (-not (Test-RemoteCommandPlanPathInside -Path $sharedRootAbsolutePath -Root $applicationRemoteDirectory)) {
        throw 'Shared storage prepare validation failed: shared root must stay inside applicationRemoteDirectory.'
    }
    foreach ($workspacePath in @('.deployment/uploads', '.deployment/work', '.deployment/releases', '.deployment/metadata')) {
        $workspaceAbsolute = Join-RemoteCommandPlanPath -Root $applicationRemoteDirectory -Child $workspacePath
        if (Test-RemoteCommandPlanPathInside -Path $sharedRootAbsolutePath -Root $workspaceAbsolute) {
            throw "Shared storage prepare validation failed: shared root overlaps deployment workspace '$workspacePath'."
        }
    }

    $entries = New-Object System.Collections.Generic.List[object]
    foreach ($entry in @($sharedStorage.directories)) {
        foreach ($field in @('sharedPath', 'releaseLinkPath', 'pathKind', 'conflictPolicy', 'initializationPolicy')) {
            Assert-CommandPlanString -Object $entry -Name $field -Context 'Shared storage directory entry'
        }
        Assert-RelativeCommandPlanPath -Path ([string] $entry.sharedPath) -Context 'Shared storage sharedPath'
        Assert-RelativeCommandPlanPath -Path ([string] $entry.releaseLinkPath) -Context 'Shared storage releaseLinkPath'
        if ([string] $entry.pathKind -ne 'directory') {
            throw "Shared storage prepare validation failed: unsupported PathKind '$($entry.pathKind)'."
        }
        if ([string] $entry.conflictPolicy -ne 'fail') {
            throw "Shared storage prepare validation failed: unsupported ConflictPolicy '$($entry.conflictPolicy)'."
        }
        if ([string] $entry.initializationPolicy -ne 'explicit') {
            throw "Shared storage prepare validation failed: unsupported InitializationPolicy '$($entry.initializationPolicy)'."
        }

        $sharedTargetAbsolutePath = if (Test-CommandPlanProperty -Object $entry -Name 'sharedAbsolutePath') { [string] $entry.sharedAbsolutePath } else { Join-RemoteCommandPlanPath -Root $sharedRootAbsolutePath -Child ([string] $entry.sharedPath) }
        $releaseLinkAbsolutePath = Join-RemoteCommandPlanPath -Root $releaseDirectory -Child ([string] $entry.releaseLinkPath)
        if (-not (Test-RemoteCommandPlanPathInside -Path $sharedTargetAbsolutePath -Root $sharedRootAbsolutePath)) {
            throw "Shared storage prepare validation failed: shared target '$($entry.sharedPath)' escapes shared root."
        }
        if (-not (Test-RemoteCommandPlanPathInside -Path $releaseLinkAbsolutePath -Root $releaseDirectory)) {
            throw "Shared storage prepare validation failed: release link '$($entry.releaseLinkPath)' escapes release directory."
        }
        if ($sharedTargetAbsolutePath.TrimEnd('/') -eq $releaseLinkAbsolutePath.TrimEnd('/')) {
            throw 'Shared storage prepare validation failed: shared target and release link must not be identical.'
        }

        $entries.Add([pscustomobject]@{
            sharedPath = [string] $entry.sharedPath
            releaseLinkPath = [string] $entry.releaseLinkPath
            pathKind = 'directory'
            conflictPolicy = [string] $entry.conflictPolicy
            initializationPolicy = [string] $entry.initializationPolicy
            sharedTargetPath = $sharedTargetAbsolutePath
            releaseLinkAbsolutePath = $releaseLinkAbsolutePath
        })
    }

    if ($entries.Count -eq 0) {
        throw 'Shared storage prepare validation failed: no shared directory entries configured.'
    }
    if (@($sharedStorage.files).Count -gt 0) {
        throw 'Shared storage prepare validation failed: shared files are not supported by the current prepare renderer.'
    }

    return [pscustomobject]@{
        applicationRemoteDirectory = $applicationRemoteDirectory
        releaseDirectory = $releaseDirectory
        sharedStorageRoot = [string] $sharedStorage.root
        sharedStorageRootAbsolutePath = $sharedRootAbsolutePath
        configuredSharedDirectoryCount = [int] $entries.Count
        configuredSharedFileCount = 0
        entries = @($entries.ToArray())
    }
}

function Assert-ReleaseIdentitySegment {
    param([Parameter(Mandatory = $true)][string] $Value, [Parameter(Mandatory = $true)][string] $Name)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw "Release prepare validation failed: $Name must not be empty."
    }
    if ($Value -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
        throw "Release prepare validation failed: $Name contains invalid characters."
    }
    if ($Value -eq '.' -or $Value -eq '..' -or $Value.Contains('/') -or $Value.Contains('\')) {
        throw "Release prepare validation failed: $Name must be a single safe path segment."
    }
}

function Resolve-RemoteReleasePrepareContract {
    param(
        [Parameter(Mandatory = $true)][object] $ExecutionPlan,
        [Parameter(Mandatory = $true)][object] $DeploymentStrategy,
        [Parameter(Mandatory = $true)][object] $Inputs,
        [AllowNull()][object] $RuntimeArtifact
    )

    if ($null -eq $RuntimeArtifact) {
        throw "Release prepare validation failed: Runtime artifact is required."
    }
    Assert-RuntimeArtifactForCommandGeneration -RuntimeArtifact $RuntimeArtifact -ExecutionPlan $ExecutionPlan

    $deploymentRunId = Get-OptionalInputString -Inputs $Inputs -Name 'deploymentRunId'
    Assert-ReleaseIdentitySegment -Value $deploymentRunId -Name 'DeploymentRunId'
    $artifactId = [string] $RuntimeArtifact.artifactId
    Assert-ReleaseIdentitySegment -Value $artifactId -Name 'ArtifactId'

    $applicationRemoteDirectory = [string] $ExecutionPlan.environment.applicationRemoteDirectory
    if ([string]::IsNullOrWhiteSpace($applicationRemoteDirectory) -or -not $applicationRemoteDirectory.StartsWith('/')) {
        throw 'Release prepare validation failed: applicationRemoteDirectory must be an absolute remote path.'
    }
    $workspace = Get-DeploymentWorkspacePaths -ExecutionPlan $ExecutionPlan -DeploymentStrategy $DeploymentStrategy
    $releaseRoot = [string] $workspace.remoteReleases
    $expectedReleaseRoot = Join-RemoteCommandPlanPath -Root $applicationRemoteDirectory -Child '.deployment/releases'
    if ($releaseRoot -ne $expectedReleaseRoot) {
        throw 'Release prepare validation failed: release root must resolve to .deployment/releases below the application directory.'
    }
    $remoteReleaseDirectory = Join-RemoteCommandPlanPath -Root (Join-RemoteCommandPlanPath -Root $releaseRoot -Child $deploymentRunId) -Child $artifactId
    if (-not $remoteReleaseDirectory.StartsWith($releaseRoot.TrimEnd('/') + '/')) {
        throw 'Release prepare validation failed: RemoteReleaseDirectory must stay below .deployment/releases.'
    }
    if ($remoteReleaseDirectory.TrimEnd('/') -eq $applicationRemoteDirectory.TrimEnd('/')) {
        throw 'Release prepare validation failed: RemoteReleaseDirectory must not be the live application directory.'
    }

    return [pscustomobject]@{
        deploymentRunId = $deploymentRunId
        artifactId = $artifactId
        remoteRoot = $applicationRemoteDirectory
        releaseRoot = $releaseRoot
        remoteReleaseDirectory = $remoteReleaseDirectory
        executionPlanFingerprint = [string] $ExecutionPlan.executionPlanFingerprint
    }
}

function Get-ComposerStrategyFingerprint {
    param([Parameter(Mandatory = $true)][object] $ComposerStrategy)

    $json = $ComposerStrategy | ConvertTo-Json -Depth 50 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return [System.BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '').ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Get-DefaultArtifactFileName {
    param([Parameter(Mandatory = $true)][object] $DeploymentStrategy)

    if ($DeploymentStrategy.selectedAdapterId -eq 'archive.tar') {
        return 'deployment-artifact.tar'
    }
    return 'deployment-artifact.zip'
}

function Get-ArtifactTransportInputs {
    param(
        [Parameter(Mandatory = $true)][object] $ExecutionPlan,
        [Parameter(Mandatory = $true)][object] $DeploymentStrategy,
        [Parameter(Mandatory = $true)][object] $Inputs,
        [AllowNull()][object] $RuntimeArtifact
    )

    $localArtifactPath = ''
    $artifactFileName = ''
    if ($null -ne $RuntimeArtifact) {
        Assert-RuntimeArtifactForCommandGeneration -RuntimeArtifact $RuntimeArtifact -ExecutionPlan $ExecutionPlan
        $localArtifactPath = [string] $RuntimeArtifact.localPath
        $artifactFileName = [string] $RuntimeArtifact.fileName
    } else {
        $artifactFileName = Get-DefaultArtifactFileName -DeploymentStrategy $DeploymentStrategy
    }
    $networkShareRoot = Get-OptionalInputString -Inputs $Inputs -Name 'networkShareRoot'
    if ([string]::IsNullOrWhiteSpace($networkShareRoot)) {
        $networkShareRoot = [string] $ExecutionPlan.environment.serverRoot
    }
    $networkShareUploadDirectory = Get-OptionalInputString -Inputs $Inputs -Name 'networkShareUploadDirectory'
    if ([string]::IsNullOrWhiteSpace($networkShareUploadDirectory)) {
        $networkShareUploadDirectory = Join-Path -Path $networkShareRoot -ChildPath '.deployment/uploads'
    }
    $networkShareArchivePath = Get-OptionalInputString -Inputs $Inputs -Name 'networkShareArchivePath'
    if ([string]::IsNullOrWhiteSpace($networkShareArchivePath)) {
        $networkShareArchivePath = Join-Path -Path $networkShareUploadDirectory -ChildPath $artifactFileName
    }

    foreach ($value in @($localArtifactPath, $artifactFileName, $networkShareRoot, $networkShareUploadDirectory, $networkShareArchivePath)) {
        if (Test-SecretLikeText -Text ([string] $value)) {
            throw 'Artifact transport input contains secret-like content.'
        }
    }

    return [pscustomobject]@{
        localArtifactPath = $localArtifactPath
        artifactFileName = $artifactFileName
        networkShareRoot = $networkShareRoot
        networkShareUploadDirectory = $networkShareUploadDirectory
        networkShareArchivePath = $networkShareArchivePath
        remoteArchivePath = Join-RemoteCommandPlanPath -Root ([string] $ExecutionPlan.environment.applicationRemoteDirectory) -Child ('.deployment/uploads/' + $artifactFileName)
    }
}

function New-InteractiveSshCommandEntry {
    param(
        [Parameter(Mandatory = $true)][object] $StrategyStep,
        [Parameter(Mandatory = $true)][string[]] $RemoteCommands,
        [Parameter(Mandatory = $true)][string] $Title,
        [string] $Description = 'Copyable remote command block for an already opened interactive SSH session.',
        [object] $Operation = ([pscustomobject]@{})
    )

    foreach ($remoteCommand in @($RemoteCommands)) {
        if ([string] $remoteCommand -cmatch '(^|[^A-Za-z0-9_])(exit|logout|exec)([^A-Za-z0-9_]|$)') {
            throw "Interactive SSH command blocks must not contain session-aborting commands like exit, logout or exec."
        }
    }
    $rendered = ($RemoteCommands -join "`n")
    return New-CommandPlanEntry -StrategyStep $StrategyStep -Program 'interactive-ssh' -Arguments ([string[]] @($RemoteCommands)) -RenderedCommand $rendered -Title $Title -Description $Description -Copyable $true -Operation $Operation
}

function Get-RuntimeArtifactComposerValidationBaselineRows {
    param([AllowNull()][object] $RuntimeArtifact)

    if ($null -eq $RuntimeArtifact) { return @() }
    if (Test-CommandPlanProperty -Object $RuntimeArtifact -Name 'composerValidationBaselinePaths') {
        return @($RuntimeArtifact.composerValidationBaselinePaths | ForEach-Object { [string] $_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
    if (-not (Test-CommandPlanProperty -Object $RuntimeArtifact -Name 'localPath')) { return @() }

    $localPath = [string] $RuntimeArtifact.localPath
    if ([string]::IsNullOrWhiteSpace($localPath) -or -not (Test-Path -LiteralPath $localPath -PathType Leaf)) { return @() }
    if ($localPath -notmatch '\.zip$') { return @() }

    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
    $rows = New-Object System.Collections.Generic.List[string]
    $seen = @{}
    $archive = [System.IO.Compression.ZipFile]::OpenRead($localPath)
    try {
        foreach ($entry in @($archive.Entries | Sort-Object FullName)) {
            $path = ([string] $entry.FullName).TrimEnd('/') -replace '\\', '/'
            if ([string]::IsNullOrWhiteSpace($path)) { continue }
            if ($path -notlike 'bootstrap/cache*' -and $path -notin @('composer.json', 'composer.lock')) { continue }

            $parts = @($path -split '/')
            if ($parts.Count -gt 1) {
                $prefix = ''
                for ($i = 0; $i -lt ($parts.Count - 1); $i++) {
                    $prefix = if ([string]::IsNullOrWhiteSpace($prefix)) { $parts[$i] } else { $prefix + '/' + $parts[$i] }
                    if ($prefix -ne 'bootstrap/cache') { continue }
                    if (-not $seen.ContainsKey($prefix)) {
                        $rows.Add($prefix + '|directory|')
                        $seen[$prefix] = $true
                    }
                }
            }

            if ($entry.FullName.EndsWith('/')) {
                if (-not $seen.ContainsKey($path)) {
                    $rows.Add($path + '|directory|')
                    $seen[$path] = $true
                }
                continue
            }

            if (-not $seen.ContainsKey($path)) {
                $sha = [System.Security.Cryptography.SHA256]::Create()
                try {
                    $stream = $entry.Open()
                    try {
                        $hash = [System.BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '').ToLowerInvariant()
                    } finally {
                        $stream.Dispose()
                    }
                } finally {
                    $sha.Dispose()
                }
                $rows.Add($path + '|file|' + $hash)
                $seen[$path] = $true
            }
        }
    } finally {
        $archive.Dispose()
    }

    return @($rows)
}

function New-HumanCommandEntry {
    param(
        [Parameter(Mandatory = $true)][object] $ExecutionPlan,
        [Parameter(Mandatory = $true)][object] $DeploymentStrategy,
        [Parameter(Mandatory = $true)][object] $StrategyStep,
        [AllowNull()][object] $RuntimeArtifact
    )

    $inputs = Get-CommandGenerationInputs -DeploymentStrategy $DeploymentStrategy
    $workspace = Get-DeploymentWorkspacePaths -ExecutionPlan $ExecutionPlan -DeploymentStrategy $DeploymentStrategy
    try {
        $transportInputs = Get-ArtifactTransportInputs -ExecutionPlan $ExecutionPlan -DeploymentStrategy $DeploymentStrategy -Inputs $inputs -RuntimeArtifact $RuntimeArtifact
    } catch {
        if ($_.Exception.Message -match '^Runtime artifact validation failed:') {
            throw
        }
        return New-IncompleteCommandEntry -StrategyStep $StrategyStep -Diagnostic $_.Exception.Message
    }
    $releasePath = Get-OptionalInputString -Inputs $inputs -Name 'remoteReleasePath'
    if ([string]::IsNullOrWhiteSpace($releasePath)) {
        $releasePath = Join-RemoteCommandPlanPath -Root $workspace.remoteReleases -Child 'current'
    }
    $releasePrepare = $null
    if ($StrategyStep.stepId -in @('remote.release.prepare', 'remote.archive.extract', 'remote.composer.preflight', 'remote.composer.install', 'remote.composer.install.validate', 'remote.shared-storage.prepare', 'remote.application.finalize')) {
        try {
            $releasePrepare = Resolve-RemoteReleasePrepareContract -ExecutionPlan $ExecutionPlan -DeploymentStrategy $DeploymentStrategy -Inputs $inputs -RuntimeArtifact $RuntimeArtifact
        } catch {
            return New-IncompleteCommandEntry -StrategyStep $StrategyStep -Program 'interactive-ssh' -Diagnostic $_.Exception.Message
        }
    }

    switch ([string] $StrategyStep.stepId) {
        'remote.release-directory.prepare' {
            $deploymentRunId = Get-OptionalInputString -Inputs $inputs -Name 'deploymentRunId'
            $executionPlanFingerprint = if (Test-CommandPlanProperty -Object $ExecutionPlan -Name 'executionPlanFingerprint') { [string] $ExecutionPlan.executionPlanFingerprint } else { '' }
            $operation = [pscustomobject]@{
                deploymentRunId = $deploymentRunId
                applicationRemoteDirectory = [string] $ExecutionPlan.environment.applicationRemoteDirectory
                executionPlanFingerprint = $executionPlanFingerprint
            }
            $commands = @(
                "printf '%s\n' '--- DEPLOYMENT-REMOTE-RELEASE-DIRECTORY-PREPARE START ---'",
                "STEP_STATUS='WaitingForHuman'",
                "STEP_EXIT_CODE='0'",
                ("DEPLOYMENT_RUN_ID=" + (Quote-PosixShellArgument $deploymentRunId)),
                ("EXECUTION_PLAN_FINGERPRINT=" + (Quote-PosixShellArgument $executionPlanFingerprint)),
                ("APPLICATION_REMOTE_DIRECTORY=" + (Quote-PosixShellArgument ([string] $ExecutionPlan.environment.applicationRemoteDirectory))),
                ('if ! cd "$APPLICATION_REMOTE_DIRECTORY"; then STEP_STATUS=' + (Quote-PosixShellArgument 'failed') + '; STEP_EXIT_CODE=1; fi'),
                ('if [ "$STEP_EXIT_CODE" = "0" ] && ! mkdir -p .deployment/uploads .deployment/work .deployment/releases .deployment/metadata; then STEP_STATUS=' + (Quote-PosixShellArgument 'failed') + '; STEP_EXIT_CODE=$?; fi'),
                ('printf ' + (Quote-PosixShellArgument 'DeploymentRunId=%s\n') + ' "$DEPLOYMENT_RUN_ID"'),
                ('printf ' + (Quote-PosixShellArgument 'ApplicationRemoteDirectory=%s\n') + ' "$APPLICATION_REMOTE_DIRECTORY"'),
                ('printf ' + (Quote-PosixShellArgument 'ExecutionPlanFingerprint=%s\n') + ' "$EXECUTION_PLAN_FINGERPRINT"'),
                ('printf ' + (Quote-PosixShellArgument 'ExitCode=%s\n') + ' "$STEP_EXIT_CODE"'),
                ('printf ' + (Quote-PosixShellArgument 'Status=%s\n') + ' "$STEP_STATUS"'),
                "printf '%s\n' '--- DEPLOYMENT-REMOTE-RELEASE-DIRECTORY-PREPARE END ---'"
            )
            return New-InteractiveSshCommandEntry -StrategyStep $StrategyStep -RemoteCommands $commands -Title 'Remote Deployment-Arbeitsverzeichnis vorbereiten' -Operation $operation
        }
        'artifact.upload' {
            if ([string]::IsNullOrWhiteSpace($transportInputs.localArtifactPath)) {
                return New-IncompleteCommandEntry -StrategyStep $StrategyStep -Program 'network-share' -Diagnostic 'Runtime artifact is missing.'
            }
            $arguments = @([string] $transportInputs.localArtifactPath, [string] $transportInputs.networkShareArchivePath)
            $operation = [pscustomobject]@{
                adapterId = 'network-share'
                artifactId = if ($null -ne $RuntimeArtifact) { [string] $RuntimeArtifact.artifactId } else { '' }
                executionPlanFingerprint = if ($null -ne $RuntimeArtifact) { [string] $RuntimeArtifact.executionPlanFingerprint } else { '' }
                localArtifactPath = [string] $transportInputs.localArtifactPath
                networkShareUploadDirectory = [string] $transportInputs.networkShareUploadDirectory
                networkShareArchivePath = [string] $transportInputs.networkShareArchivePath
                remoteArchivePath = [string] $transportInputs.remoteArchivePath
            }
            $rendered = ConvertTo-RenderedCommand -Program 'network-share' -Arguments $arguments
            return New-CommandPlanEntry -StrategyStep $StrategyStep -Program 'network-share' -Arguments $arguments -RenderedCommand $rendered -Title 'Deployment-Archiv ueber Netzlaufwerk hochladen' -Description 'Copyable local artifact transport command. Contains no remote command.' -Copyable $true -Operation $operation
        }
        'remote.release.prepare' {
            $operation = [pscustomobject]@{
                deploymentRunId = [string] $releasePrepare.deploymentRunId
                artifactId = [string] $releasePrepare.artifactId
                remoteRoot = [string] $releasePrepare.remoteRoot
                releaseRoot = [string] $releasePrepare.releaseRoot
                remoteReleaseDirectory = [string] $releasePrepare.remoteReleaseDirectory
                executionPlanFingerprint = [string] $releasePrepare.executionPlanFingerprint
            }
            $commands = @(
                "printf '%s\n' '--- DEPLOYMENT-REMOTE-RELEASE-PREPARE START ---'",
                "STEP_STATUS='failed'",
                "STEP_EXIT_CODE='1'",
                ("DEPLOYMENT_RUN_ID=" + (Quote-PosixShellArgument ([string] $releasePrepare.deploymentRunId))),
                ("ARTIFACT_ID=" + (Quote-PosixShellArgument ([string] $releasePrepare.artifactId))),
                ("REMOTE_ROOT=" + (Quote-PosixShellArgument ([string] $releasePrepare.remoteRoot))),
                ("RELEASE_ROOT=" + (Quote-PosixShellArgument ([string] $releasePrepare.releaseRoot))),
                ("REMOTE_RELEASE_DIRECTORY=" + (Quote-PosixShellArgument ([string] $releasePrepare.remoteReleaseDirectory))),
                ("EXECUTION_PLAN_FINGERPRINT=" + (Quote-PosixShellArgument ([string] $releasePrepare.executionPlanFingerprint))),
                "PARENT_DIRECTORIES_CREATED='false'",
                "RELEASE_DIRECTORY_CREATED='false'",
                "RELEASE_DIRECTORY_EXISTS='false'",
                "RELEASE_DIRECTORY_EMPTY='false'",
                ('if [ "${REMOTE_RELEASE_DIRECTORY#/}" = "$REMOTE_RELEASE_DIRECTORY" ]; then STEP_STATUS=' + (Quote-PosixShellArgument 'failed') + '; STEP_EXIT_CODE=1;'),
                ('elif [ "${REMOTE_RELEASE_DIRECTORY#"$RELEASE_ROOT"/}" = "$REMOTE_RELEASE_DIRECTORY" ]; then STEP_STATUS=' + (Quote-PosixShellArgument 'failed') + '; STEP_EXIT_CODE=1;'),
                ('elif [ "$REMOTE_RELEASE_DIRECTORY" = "$REMOTE_ROOT" ]; then STEP_STATUS=' + (Quote-PosixShellArgument 'failed') + '; STEP_EXIT_CODE=1;'),
                ('elif [ "$REMOTE_RELEASE_DIRECTORY" != "$RELEASE_ROOT/$DEPLOYMENT_RUN_ID/$ARTIFACT_ID" ]; then STEP_STATUS=' + (Quote-PosixShellArgument 'failed') + '; STEP_EXIT_CODE=1;'),
                ('elif [ -L "$RELEASE_ROOT" ] || { [ -e "$RELEASE_ROOT/$DEPLOYMENT_RUN_ID" ] && [ -L "$RELEASE_ROOT/$DEPLOYMENT_RUN_ID" ]; } || [ -L "$REMOTE_RELEASE_DIRECTORY" ]; then STEP_STATUS=' + (Quote-PosixShellArgument 'failed') + '; STEP_EXIT_CODE=1;'),
                ('elif [ -e "$REMOTE_RELEASE_DIRECTORY" ]; then STEP_STATUS=' + (Quote-PosixShellArgument 'failed') + '; STEP_EXIT_CODE=1;'),
                ('else if [ ! -e "$RELEASE_ROOT/$DEPLOYMENT_RUN_ID" ]; then PARENT_DIRECTORIES_CREATED=' + (Quote-PosixShellArgument 'true') + '; fi; if mkdir -p -- "$REMOTE_RELEASE_DIRECTORY"; then STEP_STATUS=' + (Quote-PosixShellArgument 'WaitingForHuman') + '; STEP_EXIT_CODE=0; RELEASE_DIRECTORY_CREATED=' + (Quote-PosixShellArgument 'true') + '; else STEP_STATUS=' + (Quote-PosixShellArgument 'failed') + '; STEP_EXIT_CODE=$?; fi; fi'),
                ('if [ -d "$REMOTE_RELEASE_DIRECTORY" ]; then RELEASE_DIRECTORY_EXISTS=' + (Quote-PosixShellArgument 'true') + '; fi'),
                ('if [ "$RELEASE_DIRECTORY_EXISTS" = "true" ] && [ -z "$(find "$REMOTE_RELEASE_DIRECTORY" -mindepth 1 -maxdepth 1 -print -quit)" ]; then RELEASE_DIRECTORY_EMPTY=' + (Quote-PosixShellArgument 'true') + '; fi'),
                ('printf ' + (Quote-PosixShellArgument 'DeploymentRunId=%s\n') + ' "$DEPLOYMENT_RUN_ID"'),
                ('printf ' + (Quote-PosixShellArgument 'ArtifactId=%s\n') + ' "$ARTIFACT_ID"'),
                ('printf ' + (Quote-PosixShellArgument 'RemoteReleaseDirectory=%s\n') + ' "$REMOTE_RELEASE_DIRECTORY"'),
                ('printf ' + (Quote-PosixShellArgument 'ParentDirectoriesCreated=%s\n') + ' "$PARENT_DIRECTORIES_CREATED"'),
                ('printf ' + (Quote-PosixShellArgument 'ReleaseDirectoryCreated=%s\n') + ' "$RELEASE_DIRECTORY_CREATED"'),
                ('printf ' + (Quote-PosixShellArgument 'ReleaseDirectoryExists=%s\n') + ' "$RELEASE_DIRECTORY_EXISTS"'),
                ('printf ' + (Quote-PosixShellArgument 'ReleaseDirectoryEmpty=%s\n') + ' "$RELEASE_DIRECTORY_EMPTY"'),
                ('printf ' + (Quote-PosixShellArgument 'ExecutionPlanFingerprint=%s\n') + ' "$EXECUTION_PLAN_FINGERPRINT"'),
                ('printf ' + (Quote-PosixShellArgument 'ExitCode=%s\n') + ' "$STEP_EXIT_CODE"'),
                ('printf ' + (Quote-PosixShellArgument 'Status=%s\n') + ' "$STEP_STATUS"'),
                ('printf ' + (Quote-PosixShellArgument 'CurrentStep=%s\n') + ' ' + (Quote-PosixShellArgument 'remote.release.prepare')),
                ('printf ' + (Quote-PosixShellArgument 'NextStep=%s\n') + ' ' + (Quote-PosixShellArgument 'remote.archive.extract')),
                "printf '%s\n' '--- DEPLOYMENT-REMOTE-RELEASE-PREPARE END ---'"
            )
            return New-InteractiveSshCommandEntry -StrategyStep $StrategyStep -RemoteCommands $commands -Title 'Remote Release-Verzeichnis vorbereiten' -Operation $operation
        }
        'remote.archive.extract' {
            $extractCommand = if ($DeploymentStrategy.selectedAdapterId -eq 'archive.zip') {
                "unzip -q " + (Quote-PosixShellArgument $transportInputs.remoteArchivePath) + " -d " + (Quote-PosixShellArgument ([string] $releasePrepare.remoteReleaseDirectory))
            } else {
                "tar -xf " + (Quote-PosixShellArgument $transportInputs.remoteArchivePath) + " -C " + (Quote-PosixShellArgument ([string] $releasePrepare.remoteReleaseDirectory))
            }
            $artisanPath = Join-RemoteCommandPlanPath -Root ([string] $releasePrepare.remoteReleaseDirectory) -Child 'artisan'
            $operation = [pscustomobject]@{
                deploymentRunId = [string] $releasePrepare.deploymentRunId
                artifactId = [string] $releasePrepare.artifactId
                remoteArchivePath = [string] $transportInputs.remoteArchivePath
                remoteReleaseDirectory = [string] $releasePrepare.remoteReleaseDirectory
                executionPlanFingerprint = [string] $ExecutionPlan.executionPlanFingerprint
            }
            $commands = @(
                "printf '%s\n' '--- DEPLOYMENT-REMOTE-ARCHIVE-EXTRACT START ---'",
                "STEP_STATUS='failed'",
                "STEP_EXIT_CODE='1'",
                ("DEPLOYMENT_RUN_ID=" + (Quote-PosixShellArgument ([string] $releasePrepare.deploymentRunId))),
                ("ARTIFACT_ID=" + (Quote-PosixShellArgument ([string] $releasePrepare.artifactId))),
                ("REMOTE_RELEASE_DIRECTORY=" + (Quote-PosixShellArgument ([string] $releasePrepare.remoteReleaseDirectory))),
                ("REMOTE_ARCHIVE_PATH=" + (Quote-PosixShellArgument ([string] $transportInputs.remoteArchivePath))),
                ("ARTISAN_PATH=" + (Quote-PosixShellArgument $artisanPath)),
                ("EXECUTION_PLAN_FINGERPRINT=" + (Quote-PosixShellArgument ([string] $ExecutionPlan.executionPlanFingerprint))),
                "RELEASE_DIRECTORY_EXISTS='false'",
                "RELEASE_DIRECTORY_EMPTY_BEFORE='false'",
                "ARTISAN_PRESENT='false'",
                ('if [ ! -d "$REMOTE_RELEASE_DIRECTORY" ]; then STEP_STATUS=' + (Quote-PosixShellArgument 'failed') + '; STEP_EXIT_CODE=1;'),
                ('elif [ -n "$(find "$REMOTE_RELEASE_DIRECTORY" -mindepth 1 -maxdepth 1 -print -quit)" ]; then RELEASE_DIRECTORY_EXISTS=' + (Quote-PosixShellArgument 'true') + '; STEP_STATUS=' + (Quote-PosixShellArgument 'failed') + '; STEP_EXIT_CODE=1;'),
                ('else RELEASE_DIRECTORY_EXISTS=' + (Quote-PosixShellArgument 'true') + '; RELEASE_DIRECTORY_EMPTY_BEFORE=' + (Quote-PosixShellArgument 'true') + '; STEP_STATUS=' + (Quote-PosixShellArgument 'WaitingForHuman') + '; STEP_EXIT_CODE=0; fi'),
                ('if [ "$STEP_EXIT_CODE" = "0" ]; then ' + $extractCommand + '; STEP_EXIT_CODE=$?; if [ "$STEP_EXIT_CODE" != "0" ]; then STEP_STATUS=' + (Quote-PosixShellArgument 'failed') + '; fi; fi'),
                ('if [ "$STEP_EXIT_CODE" = "0" ]; then if [ -f "$ARTISAN_PATH" ]; then ARTISAN_PRESENT=' + (Quote-PosixShellArgument 'true') + '; else STEP_STATUS=' + (Quote-PosixShellArgument 'failed') + '; STEP_EXIT_CODE=1; fi; fi'),
                ('printf ' + (Quote-PosixShellArgument 'DeploymentRunId=%s\n') + ' "$DEPLOYMENT_RUN_ID"'),
                ('printf ' + (Quote-PosixShellArgument 'ArtifactId=%s\n') + ' "$ARTIFACT_ID"'),
                ('printf ' + (Quote-PosixShellArgument 'RemoteArchivePath=%s\n') + ' "$REMOTE_ARCHIVE_PATH"'),
                ('printf ' + (Quote-PosixShellArgument 'RemoteReleaseDirectory=%s\n') + ' "$REMOTE_RELEASE_DIRECTORY"'),
                ('printf ' + (Quote-PosixShellArgument 'ReleaseDirectoryExists=%s\n') + ' "$RELEASE_DIRECTORY_EXISTS"'),
                ('printf ' + (Quote-PosixShellArgument 'ReleaseDirectoryEmptyBefore=%s\n') + ' "$RELEASE_DIRECTORY_EMPTY_BEFORE"'),
                ('printf ' + (Quote-PosixShellArgument 'ArtisanPresent=%s\n') + ' "$ARTISAN_PRESENT"'),
                ('printf ' + (Quote-PosixShellArgument 'ExecutionPlanFingerprint=%s\n') + ' "$EXECUTION_PLAN_FINGERPRINT"'),
                ('printf ' + (Quote-PosixShellArgument 'ExitCode=%s\n') + ' "$STEP_EXIT_CODE"'),
                ('printf ' + (Quote-PosixShellArgument 'Status=%s\n') + ' "$STEP_STATUS"'),
                ('printf ' + (Quote-PosixShellArgument 'CurrentStep=%s\n') + ' ' + (Quote-PosixShellArgument 'remote.archive.extract')),
                ('printf ' + (Quote-PosixShellArgument 'NextStep=%s\n') + ' ' + (Quote-PosixShellArgument 'remote.composer.preflight')),
                "printf '%s\n' '--- DEPLOYMENT-REMOTE-ARCHIVE-EXTRACT END ---'"
            )
            return New-InteractiveSshCommandEntry -StrategyStep $StrategyStep -RemoteCommands $commands -Title 'Remote Archiv entpacken und validieren' -Operation $operation
        }
        'remote.composer.preflight' {
            $composerStrategy = $DeploymentStrategy.composerStrategy
            $composerStrategyFingerprint = Get-ComposerStrategyFingerprint -ComposerStrategy $composerStrategy
            $packagingPolicyId = if ($null -ne $RuntimeArtifact) { [string] $RuntimeArtifact.packagingPolicyId } else { '' }
            $packagingPolicyFingerprint = if ($null -ne $RuntimeArtifact) { [string] $RuntimeArtifact.packagingPolicyFingerprint } else { '' }
            $baselineRows = @(Get-RuntimeArtifactComposerValidationBaselineRows -RuntimeArtifact $RuntimeArtifact)
            $baselineText = ($baselineRows -join "`n")
            $operation = [pscustomobject]@{
                deploymentRunId = [string] $releasePrepare.deploymentRunId
                artifactId = [string] $releasePrepare.artifactId
                remoteReleaseDirectory = [string] $releasePrepare.remoteReleaseDirectory
                composerStrategyId = [string] $composerStrategy.composerStrategyId
                composerStrategyFingerprint = $composerStrategyFingerprint
                executionPlanFingerprint = [string] $ExecutionPlan.executionPlanFingerprint
                packagingPolicyId = $packagingPolicyId
                packagingPolicyFingerprint = $packagingPolicyFingerprint
                packagingPolicyRequired = $true
                installAllowed = $false
            }
            $commands = @(
                "printf '%s\n' '--- DEPLOYMENT-REMOTE-COMPOSER-PREFLIGHT START ---'",
                "STARTED_EPOCH=`$(date -u +%s 2>/dev/null)",
                "STARTED_AT=`$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)",
                "STEP_STATUS='failed'",
                "STEP_EXIT_CODE='1'",
                "FAILURE_REASON=''",
                ("DEPLOYMENT_RUN_ID=" + (Quote-PosixShellArgument ([string] $releasePrepare.deploymentRunId))),
                ("ARTIFACT_ID=" + (Quote-PosixShellArgument ([string] $releasePrepare.artifactId))),
                ("REMOTE_RELEASE_DIRECTORY=" + (Quote-PosixShellArgument ([string] $releasePrepare.remoteReleaseDirectory))),
                ("COMPOSER_STRATEGY_ID=" + (Quote-PosixShellArgument ([string] $composerStrategy.composerStrategyId))),
                ("COMPOSER_STRATEGY_FINGERPRINT=" + (Quote-PosixShellArgument $composerStrategyFingerprint)),
                ("EXECUTION_PLAN_FINGERPRINT=" + (Quote-PosixShellArgument ([string] $ExecutionPlan.executionPlanFingerprint))),
                ("PACKAGING_POLICY_ID=" + (Quote-PosixShellArgument $packagingPolicyId)),
                ("PACKAGING_POLICY_FINGERPRINT=" + (Quote-PosixShellArgument $packagingPolicyFingerprint)),
                "COMPOSER_EXECUTABLE='composer'",
                "COMPOSER_EXECUTABLE_PATH=''",
                "COMPOSER_VERSION=''",
                "PHP_EXECUTABLE='php'",
                "PHP_EXECUTABLE_PATH=''",
                "PHP_VERSION=''",
                "COMPOSER_JSON_PRESENT='false'",
                "COMPOSER_JSON_VALID='false'",
                "COMPOSER_LOCK_PRESENT='false'",
                "COMPOSER_LOCK_VALID='false'",
                "LOCK_FILE_FRESH='false'",
                "PACKAGE_COUNT='0'",
                "PRODUCTION_PACKAGE_COUNT='0'",
                "DEVELOPMENT_PACKAGE_COUNT='0'",
                "REQUIRED_PHP_CONSTRAINT=''",
                "PHP_VERSION_COMPATIBLE='false'",
                "REQUIRED_EXTENSION_COUNT='0'",
                "MISSING_EXTENSION_COUNT='0'",
                "MISSING_EXTENSIONS=''",
                "PLATFORM_REQUIREMENTS_SATISFIED='false'",
                "COMPOSER_SCRIPTS_PRESENT='false'",
                "COMPOSER_SCRIPTS_REQUIRE_REVIEW='false'",
                "COMPOSER_SCRIPT_REVIEW_COMPLETED='true'",
                "COMPOSER_PLUGINS_PRESENT='false'",
                "COMPOSER_PLUGINS_REQUIRE_REVIEW='false'",
                "COMPOSER_PLUGIN_REVIEW_COMPLETED='true'",
                "COMPOSER_INSTALL_CONTRACT_SATISFIED='true'",
                "COMPOSER_VALIDATE_EXIT_CODE=''",
                "COMPOSER_PLATFORM_CHECK_EXIT_CODE=''",
                "VENDOR_PRESENT='false'",
                "VENDOR_PRESENT_BEFORE='false'",
                "VENDOR_PRESENT_AFTER='false'",
                "FILES_CHANGED='false'",
                "RELEASE_SNAPSHOT_BEFORE=''",
                "RELEASE_SNAPSHOT_AFTER=''",
                ('if [ ! -d "$REMOTE_RELEASE_DIRECTORY" ]; then FAILURE_REASON=' + (Quote-PosixShellArgument 'release-directory-missing') + ';'),
                ('elif [ -L "$REMOTE_RELEASE_DIRECTORY" ]; then FAILURE_REASON=' + (Quote-PosixShellArgument 'release-directory-is-symlink') + ';'),
                ('elif [ ! -f "$REMOTE_RELEASE_DIRECTORY/composer.json" ]; then FAILURE_REASON=' + (Quote-PosixShellArgument 'composer-json-missing') + ';'),
                ('elif [ ! -f "$REMOTE_RELEASE_DIRECTORY/composer.lock" ]; then FAILURE_REASON=' + (Quote-PosixShellArgument 'composer-lock-missing') + ';'),
                ('elif [ -e "$REMOTE_RELEASE_DIRECTORY/vendor" ]; then VENDOR_PRESENT_BEFORE=' + (Quote-PosixShellArgument 'true') + '; FAILURE_REASON=' + (Quote-PosixShellArgument 'vendor-already-present') + ';'),
                ('elif ! command -v composer >/dev/null 2>&1; then FAILURE_REASON=' + (Quote-PosixShellArgument 'composer-executable-not-available') + ';'),
                ('elif ! command -v php >/dev/null 2>&1; then FAILURE_REASON=' + (Quote-PosixShellArgument 'php-executable-not-available') + ';'),
                'else STEP_EXIT_CODE=0; fi',
                'if [ "$STEP_EXIT_CODE" = "0" ]; then RELEASE_SNAPSHOT_BEFORE="$(cd "$REMOTE_RELEASE_DIRECTORY" && find . -mindepth 1 -printf ''%P|%y|%s|%T@\n'' 2>/dev/null | sort)"; fi',
                ('if [ "$STEP_EXIT_CODE" = "0" ]; then COMPOSER_JSON_PRESENT=' + (Quote-PosixShellArgument 'true') + '; COMPOSER_LOCK_PRESENT=' + (Quote-PosixShellArgument 'true') + '; COMPOSER_EXECUTABLE_PATH="$(command -v composer)"; PHP_EXECUTABLE_PATH="$(command -v php)"; COMPOSER_VERSION="$(composer --version 2>/dev/null | head -n 1)"; PHP_VERSION="$(php -r ' + (Quote-PosixShellArgument 'echo PHP_VERSION;') + ' 2>/dev/null)"; fi'),
                ('if [ "$STEP_EXIT_CODE" = "0" ]; then COMPOSER_VALIDATE_OUTPUT="$(cd "$REMOTE_RELEASE_DIRECTORY" && composer validate --no-check-publish --no-interaction 2>&1)"; COMPOSER_VALIDATE_EXIT_CODE="$?"; if [ "$COMPOSER_VALIDATE_EXIT_CODE" = "0" ]; then COMPOSER_JSON_VALID=' + (Quote-PosixShellArgument 'true') + '; COMPOSER_LOCK_VALID=' + (Quote-PosixShellArgument 'true') + '; LOCK_FILE_FRESH=' + (Quote-PosixShellArgument 'true') + '; else FAILURE_REASON=' + (Quote-PosixShellArgument 'composer-validate-failed') + '; STEP_EXIT_CODE=1; fi; fi'),
                ('if [ "$STEP_EXIT_CODE" = "0" ]; then COMPOSER_PLATFORM_OUTPUT="$(cd "$REMOTE_RELEASE_DIRECTORY" && composer check-platform-reqs --lock --no-interaction 2>&1)"; COMPOSER_PLATFORM_CHECK_EXIT_CODE="$?"; if [ "$COMPOSER_PLATFORM_CHECK_EXIT_CODE" = "0" ]; then PLATFORM_REQUIREMENTS_SATISFIED=' + (Quote-PosixShellArgument 'true') + '; PHP_VERSION_COMPATIBLE=' + (Quote-PosixShellArgument 'true') + '; else FAILURE_REASON=' + (Quote-PosixShellArgument 'composer-platform-check-failed') + '; STEP_EXIT_CODE=1; fi; fi'),
                ('if [ "$STEP_EXIT_CODE" = "0" ]; then PACKAGE_COUNT="$(cd "$REMOTE_RELEASE_DIRECTORY" && php -r ' + (Quote-PosixShellArgument '$lock=json_decode(file_get_contents("composer.lock"), true); echo count($lock["packages"] ?? []) + count($lock["packages-dev"] ?? []);') + ' 2>/dev/null)"; PRODUCTION_PACKAGE_COUNT="$(cd "$REMOTE_RELEASE_DIRECTORY" && php -r ' + (Quote-PosixShellArgument '$lock=json_decode(file_get_contents("composer.lock"), true); echo count($lock["packages"] ?? []);') + ' 2>/dev/null)"; DEVELOPMENT_PACKAGE_COUNT="$(cd "$REMOTE_RELEASE_DIRECTORY" && php -r ' + (Quote-PosixShellArgument '$lock=json_decode(file_get_contents("composer.lock"), true); echo count($lock["packages-dev"] ?? []);') + ' 2>/dev/null)"; fi'),
                ('if [ "$STEP_EXIT_CODE" = "0" ]; then REQUIRED_PHP_CONSTRAINT="$(cd "$REMOTE_RELEASE_DIRECTORY" && php -r ' + (Quote-PosixShellArgument '$j=json_decode(file_get_contents("composer.json"), true); echo $j["require"]["php"] ?? "";') + ' 2>/dev/null)"; REQUIRED_EXTENSION_COUNT="$(cd "$REMOTE_RELEASE_DIRECTORY" && php -r ' + (Quote-PosixShellArgument '$j=json_decode(file_get_contents("composer.json"), true); $req=$j["require"] ?? []; echo count(array_filter(array_keys($req), fn($k)=>str_starts_with($k, "ext-")));') + ' 2>/dev/null)"; MISSING_EXTENSION_COUNT="0"; MISSING_EXTENSIONS=""; fi'),
                ('if [ "$STEP_EXIT_CODE" = "0" ]; then SCRIPT_COUNT="$(cd "$REMOTE_RELEASE_DIRECTORY" && php -r ' + (Quote-PosixShellArgument '$j=json_decode(file_get_contents("composer.json"), true); echo count($j["scripts"] ?? []);') + ' 2>/dev/null)"; if [ "$SCRIPT_COUNT" != "0" ]; then COMPOSER_SCRIPTS_PRESENT=' + (Quote-PosixShellArgument 'true') + '; fi; fi'),
                ('if [ "$STEP_EXIT_CODE" = "0" ]; then PLUGIN_COUNT="$(cd "$REMOTE_RELEASE_DIRECTORY" && php -r ' + (Quote-PosixShellArgument '$j=json_decode(file_get_contents("composer.json"), true); echo count($j["config"]["allow-plugins"] ?? []);') + ' 2>/dev/null)"; if [ "$PLUGIN_COUNT" != "0" ]; then COMPOSER_PLUGINS_PRESENT=' + (Quote-PosixShellArgument 'true') + '; fi; fi'),
                'if [ "$STEP_EXIT_CODE" = "0" ]; then RELEASE_SNAPSHOT_AFTER="$(cd "$REMOTE_RELEASE_DIRECTORY" && find . -mindepth 1 -printf ''%P|%y|%s|%T@\n'' 2>/dev/null | sort)"; fi',
                ('if [ "$STEP_EXIT_CODE" = "0" ]; then if [ -e "$REMOTE_RELEASE_DIRECTORY/vendor" ]; then VENDOR_PRESENT_AFTER=' + (Quote-PosixShellArgument 'true') + '; VENDOR_PRESENT=' + (Quote-PosixShellArgument 'true') + '; FILES_CHANGED=' + (Quote-PosixShellArgument 'true') + '; FAILURE_REASON=' + (Quote-PosixShellArgument 'preflight-created-vendor') + '; STEP_EXIT_CODE=1; elif [ "$RELEASE_SNAPSHOT_BEFORE" != "$RELEASE_SNAPSHOT_AFTER" ]; then FILES_CHANGED=' + (Quote-PosixShellArgument 'true') + '; FAILURE_REASON=' + (Quote-PosixShellArgument 'preflight-changed-files') + '; STEP_EXIT_CODE=1; else STEP_STATUS=' + (Quote-PosixShellArgument 'WaitingForHuman') + '; fi; fi'),
                "COMPLETED_EPOCH=`$(date -u +%s 2>/dev/null)",
                "COMPLETED_AT=`$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)",
                'if [ -n "$STARTED_EPOCH" ] && [ -n "$COMPLETED_EPOCH" ]; then DURATION_SECONDS="$((COMPLETED_EPOCH - STARTED_EPOCH))"; else DURATION_SECONDS=""; fi',
                ('printf ' + (Quote-PosixShellArgument 'Step=%s\n') + ' ' + (Quote-PosixShellArgument 'remote.composer.preflight')),
                ('printf ' + (Quote-PosixShellArgument 'DeploymentRunId=%s\n') + ' "$DEPLOYMENT_RUN_ID"'),
                ('printf ' + (Quote-PosixShellArgument 'ArtifactId=%s\n') + ' "$ARTIFACT_ID"'),
                ('printf ' + (Quote-PosixShellArgument 'RemoteReleaseDirectory=%s\n') + ' "$REMOTE_RELEASE_DIRECTORY"'),
                ('printf ' + (Quote-PosixShellArgument 'ComposerStrategyId=%s\n') + ' "$COMPOSER_STRATEGY_ID"'),
                ('printf ' + (Quote-PosixShellArgument 'ComposerStrategyFingerprint=%s\n') + ' "$COMPOSER_STRATEGY_FINGERPRINT"'),
                ('printf ' + (Quote-PosixShellArgument 'ComposerExecutable=%s\n') + ' "$COMPOSER_EXECUTABLE"'),
                ('printf ' + (Quote-PosixShellArgument 'ComposerExecutablePath=%s\n') + ' "$COMPOSER_EXECUTABLE_PATH"'),
                ('printf ' + (Quote-PosixShellArgument 'ComposerVersion=%s\n') + ' "$COMPOSER_VERSION"'),
                ('printf ' + (Quote-PosixShellArgument 'PhpExecutable=%s\n') + ' "$PHP_EXECUTABLE"'),
                ('printf ' + (Quote-PosixShellArgument 'PhpExecutablePath=%s\n') + ' "$PHP_EXECUTABLE_PATH"'),
                ('printf ' + (Quote-PosixShellArgument 'PhpVersion=%s\n') + ' "$PHP_VERSION"'),
                ('printf ' + (Quote-PosixShellArgument 'RequiredPhpConstraint=%s\n') + ' "$REQUIRED_PHP_CONSTRAINT"'),
                ('printf ' + (Quote-PosixShellArgument 'PhpVersionCompatible=%s\n') + ' "$PHP_VERSION_COMPATIBLE"'),
                ('printf ' + (Quote-PosixShellArgument 'ComposerJsonPresent=%s\n') + ' "$COMPOSER_JSON_PRESENT"'),
                ('printf ' + (Quote-PosixShellArgument 'ComposerJsonValid=%s\n') + ' "$COMPOSER_JSON_VALID"'),
                ('printf ' + (Quote-PosixShellArgument 'ComposerLockPresent=%s\n') + ' "$COMPOSER_LOCK_PRESENT"'),
                ('printf ' + (Quote-PosixShellArgument 'ComposerLockValid=%s\n') + ' "$COMPOSER_LOCK_VALID"'),
                ('printf ' + (Quote-PosixShellArgument 'LockFileFresh=%s\n') + ' "$LOCK_FILE_FRESH"'),
                ('printf ' + (Quote-PosixShellArgument 'PackageCount=%s\n') + ' "$PACKAGE_COUNT"'),
                ('printf ' + (Quote-PosixShellArgument 'ProductionPackageCount=%s\n') + ' "$PRODUCTION_PACKAGE_COUNT"'),
                ('printf ' + (Quote-PosixShellArgument 'DevelopmentPackageCount=%s\n') + ' "$DEVELOPMENT_PACKAGE_COUNT"'),
                ('printf ' + (Quote-PosixShellArgument 'RequiredExtensionCount=%s\n') + ' "$REQUIRED_EXTENSION_COUNT"'),
                ('printf ' + (Quote-PosixShellArgument 'MissingExtensionCount=%s\n') + ' "$MISSING_EXTENSION_COUNT"'),
                ('printf ' + (Quote-PosixShellArgument 'MissingExtensions=%s\n') + ' "$MISSING_EXTENSIONS"'),
                ('printf ' + (Quote-PosixShellArgument 'PlatformRequirementsSatisfied=%s\n') + ' "$PLATFORM_REQUIREMENTS_SATISFIED"'),
                ('printf ' + (Quote-PosixShellArgument 'ComposerScriptsPresent=%s\n') + ' "$COMPOSER_SCRIPTS_PRESENT"'),
                ('printf ' + (Quote-PosixShellArgument 'ComposerScriptsRequireReview=%s\n') + ' "$COMPOSER_SCRIPTS_REQUIRE_REVIEW"'),
                ('printf ' + (Quote-PosixShellArgument 'ComposerScriptReviewCompleted=%s\n') + ' "$COMPOSER_SCRIPT_REVIEW_COMPLETED"'),
                ('printf ' + (Quote-PosixShellArgument 'ComposerPluginsPresent=%s\n') + ' "$COMPOSER_PLUGINS_PRESENT"'),
                ('printf ' + (Quote-PosixShellArgument 'ComposerPluginsRequireReview=%s\n') + ' "$COMPOSER_PLUGINS_REQUIRE_REVIEW"'),
                ('printf ' + (Quote-PosixShellArgument 'ComposerPluginReviewCompleted=%s\n') + ' "$COMPOSER_PLUGIN_REVIEW_COMPLETED"'),
                ('printf ' + (Quote-PosixShellArgument 'ComposerInstallContractSatisfied=%s\n') + ' "$COMPOSER_INSTALL_CONTRACT_SATISFIED"'),
                ('printf ' + (Quote-PosixShellArgument 'ComposerValidateExitCode=%s\n') + ' "$COMPOSER_VALIDATE_EXIT_CODE"'),
                ('printf ' + (Quote-PosixShellArgument 'ComposerPlatformCheckExitCode=%s\n') + ' "$COMPOSER_PLATFORM_CHECK_EXIT_CODE"'),
                ('printf ' + (Quote-PosixShellArgument 'VendorPresentBefore=%s\n') + ' "$VENDOR_PRESENT_BEFORE"'),
                ('printf ' + (Quote-PosixShellArgument 'VendorPresentAfter=%s\n') + ' "$VENDOR_PRESENT_AFTER"'),
                ('printf ' + (Quote-PosixShellArgument 'VendorPresent=%s\n') + ' "$VENDOR_PRESENT"'),
                ('printf ' + (Quote-PosixShellArgument 'FilesChanged=%s\n') + ' "$FILES_CHANGED"'),
                ('printf ' + (Quote-PosixShellArgument 'ExecutionPlanFingerprint=%s\n') + ' "$EXECUTION_PLAN_FINGERPRINT"'),
                ('printf ' + (Quote-PosixShellArgument 'PackagingPolicyId=%s\n') + ' "$PACKAGING_POLICY_ID"'),
                ('printf ' + (Quote-PosixShellArgument 'PackagingPolicyFingerprint=%s\n') + ' "$PACKAGING_POLICY_FINGERPRINT"'),
                ('printf ' + (Quote-PosixShellArgument 'StartedAt=%s\n') + ' "$STARTED_AT"'),
                ('printf ' + (Quote-PosixShellArgument 'CompletedAt=%s\n') + ' "$COMPLETED_AT"'),
                ('printf ' + (Quote-PosixShellArgument 'DurationSeconds=%s\n') + ' "$DURATION_SECONDS"'),
                ('printf ' + (Quote-PosixShellArgument 'ExitCode=%s\n') + ' "$STEP_EXIT_CODE"'),
                ('printf ' + (Quote-PosixShellArgument 'FailureReason=%s\n') + ' "$FAILURE_REASON"'),
                ('printf ' + (Quote-PosixShellArgument 'Status=%s\n') + ' "$STEP_STATUS"'),
                ('printf ' + (Quote-PosixShellArgument 'CurrentStep=%s\n') + ' ' + (Quote-PosixShellArgument 'remote.composer.preflight')),
                ('printf ' + (Quote-PosixShellArgument 'NextStep=%s\n') + ' ' + (Quote-PosixShellArgument 'remote.composer.install')),
                "printf '%s\n' '--- DEPLOYMENT-REMOTE-COMPOSER-PREFLIGHT END ---'"
            )
            return New-InteractiveSshCommandEntry -StrategyStep $StrategyStep -RemoteCommands $commands -Title 'Remote Composer-Preflight pruefen' -Operation $operation
        }
        'remote.composer.install' {
            $composerStrategy = $DeploymentStrategy.composerStrategy
            $composerStrategyFingerprint = Get-ComposerStrategyFingerprint -ComposerStrategy $composerStrategy
            $installContract = $DeploymentStrategy.composerStrategy.installContract
            $packagingPolicyId = if ($null -ne $RuntimeArtifact) { [string] $RuntimeArtifact.packagingPolicyId } else { '' }
            $packagingPolicyFingerprint = if ($null -ne $RuntimeArtifact) { [string] $RuntimeArtifact.packagingPolicyFingerprint } else { '' }
            $operation = [pscustomobject]@{
                deploymentRunId = [string] $releasePrepare.deploymentRunId
                artifactId = [string] $releasePrepare.artifactId
                remoteReleaseDirectory = [string] $releasePrepare.remoteReleaseDirectory
                composerStrategyId = [string] $composerStrategy.composerStrategyId
                composerStrategyFingerprint = $composerStrategyFingerprint
                executionPlanFingerprint = [string] $ExecutionPlan.executionPlanFingerprint
                packagingPolicyId = $packagingPolicyId
                packagingPolicyFingerprint = $packagingPolicyFingerprint
                installMode = [string] $DeploymentStrategy.composerStrategy.installMode
                productionMode = [bool] $DeploymentStrategy.composerStrategy.productionMode
                installAllowedWithoutSuccessfulPreflight = $false
                composerCommand = [string] $installContract.composerCommand
                workingDirectory = [string] $installContract.workingDirectory
                networkAccessPolicy = [string] $installContract.networkAccessPolicy
                allowedFlags = @($installContract.allowedFlags)
                forbiddenFlags = @($installContract.forbiddenFlags)
                scriptExecutionPolicy = $installContract.scriptExecutionPolicy
                pluginExecutionPolicy = $installContract.pluginExecutionPolicy
                expectedVendorState = $installContract.expectedVendorState
                expectedAutoloadState = $installContract.expectedAutoloadState
                writeBoundary = $installContract.writeBoundary
                failureHandling = [string] $installContract.failureHandling
                rollbackBehaviour = [string] $installContract.rollbackBehaviour
                postValidation = $installContract.postValidation
                writesActualPathsInResult = $true
            }
            $snapshotScript = '$r=[]; $it=new RecursiveIteratorIterator(new RecursiveDirectoryIterator(".", FilesystemIterator::SKIP_DOTS), RecursiveIteratorIterator::SELF_FIRST); foreach ($it as $f) { $p=str_replace("\\", "/", $it->getSubPathName()); $r[$p]=[$f->isLink() ? "link" : ($f->isDir() ? "dir" : "file"), $f->isFile() ? $f->getSize() : 0, $f->getMTime()]; } ksort($r); echo json_encode($r);'
            $boundaryScript = '$b=json_decode(getenv("SNAPSHOT_BEFORE"), true) ?: []; function s(){ $r=[]; $it=new RecursiveIteratorIterator(new RecursiveDirectoryIterator(".", FilesystemIterator::SKIP_DOTS), RecursiveIteratorIterator::SELF_FIRST); foreach ($it as $f) { $p=str_replace("\\", "/", $it->getSubPathName()); $r[$p]=[$f->isLink() ? "link" : ($f->isDir() ? "dir" : "file"), $f->isFile() ? $f->getSize() : 0, $f->getMTime()]; } ksort($r); return $r; } function allowed($p){ return $p==="vendor" || str_starts_with($p,"vendor/") || $p==="bootstrap/cache" || $p==="bootstrap/cache/packages.php" || $p==="bootstrap/cache/services.php"; } $a=s(); $w=[]; $u=[]; $ud=[]; foreach($a as $p=>$m){ if(!isset($b[$p]) || $b[$p] !== $m){ $w[]=$p; if(!allowed($p)){ $u[]=$p; if($m[0]==="dir"){ $ud[]=$p; } } } } foreach($b as $p=>$m){ if(!isset($a[$p])){ $u[]="deleted:".$p; } } sort($w); sort($u); sort($ud); echo "WrittenPathCount=".count($w)."\n"; foreach($w as $p){ echo "WrittenPath=".$p."\n"; } echo "UnexpectedFileChanges=".((count($u)===0)?"false":"true")."\n"; echo "UnexpectedDirectories=".((count($ud)===0)?"false":"true")."\n"; echo "FilesChangedOnlyInsideRelease=".((count($u)===0)?"true":"false")."\n";'
            $productionPackageCountScript = '$lock=json_decode(file_get_contents("composer.lock"), true); echo count($lock["packages"] ?? []);'
            $pluginPackageCountScript = '$lock=json_decode(file_get_contents("composer.lock"), true); $c=0; foreach(($lock["packages"] ?? []) as $p){ if(($p["type"] ?? "") === "composer-plugin"){ $c++; } } echo $c;'
            $vendorPackageDirectoryCountScript = '$count=0; if (is_dir("vendor")) { foreach (glob("vendor/*/*", GLOB_ONLYDIR) ?: [] as $p) { $count++; } } echo $count;'
            $outsideSnapshotScript = '$root=rtrim(getenv("APPLICATION_REMOTE_DIRECTORY"), "/"); $release=rtrim(getenv("REMOTE_RELEASE_DIRECTORY"), "/"); $watch=[".env",".env.example","storage","public",".deployment/uploads",".deployment/metadata",".deployment/releases"]; $rows=[]; $add=function($p) use (&$rows,$release){ $p=str_replace("\\", "/", $p); if($p===$release || str_starts_with($p, $release."/")){ return; } if(!file_exists($p) && !is_link($p)){ return; } $rows[]=$p."|".(is_link($p)?"link":(is_dir($p)?"dir":"file"))."|".(is_file($p)?filesize($p):0)."|".filemtime($p); }; foreach($watch as $rel){ $base=$root."/".$rel; if(!file_exists($base) && !is_link($base)){ continue; } $add($base); if(is_dir($base) && !is_link($base)){ $it=new RecursiveIteratorIterator(new RecursiveDirectoryIterator($base, FilesystemIterator::SKIP_DOTS), RecursiveIteratorIterator::SELF_FIRST); foreach($it as $f){ $add($f->getPathname()); } } } sort($rows); echo hash("sha256", implode("\n", $rows));'
            $commands = @(
                "clear",
                "printf '%s\n' '--- DEPLOYMENT-REMOTE-COMPOSER-INSTALL START ---'",
                "STARTED_EPOCH=`$(date -u +%s 2>/dev/null)",
                "STARTED_AT=`$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)",
                "STEP_STATUS='failed'",
                "STEP_EXIT_CODE='1'",
                "FAILURE_REASON=''",
                "COMPOSER_EXIT_CODE=''",
                "COMPOSER_INSTALL_OUTPUT=''",
                "COMPOSER_VERSION=''",
                "PHP_VERSION=''",
                "VENDOR_PRESENT='false'",
                "AUTOLOAD_PRESENT='false'",
                "COMPOSER_JSON_UNCHANGED='false'",
                "COMPOSER_LOCK_UNCHANGED='false'",
                "FILES_CHANGED_ONLY_INSIDE_RELEASE='false'",
                "UNEXPECTED_FILE_CHANGES='true'",
                "UNEXPECTED_DIRECTORIES='true'",
                "SCRIPT_EXECUTION_EVIDENCE='external-install-result-required'",
                "OBSERVED_COMPOSER_SCRIPTS=''",
                "OBSERVED_COMPOSER_COMMANDS=''",
                "PLUGINS_EXECUTED='false'",
                "PLUGIN_EXECUTION_EVIDENCE='no-lockfile-composer-plugin-packages-observed'",
                "PLUGIN_PACKAGE_COUNT='0'",
                "PRODUCTION_LOCK_PACKAGE_COUNT='0'",
                "VENDOR_PACKAGE_DIRECTORY_COUNT='0'",
                "WRITE_BOUNDARY_SATISFIED='false'",
                "OUTSIDE_BOUNDARY_CHANGED='true'",
                ("DEPLOYMENT_RUN_ID=" + (Quote-PosixShellArgument ([string] $releasePrepare.deploymentRunId))),
                ("ARTIFACT_ID=" + (Quote-PosixShellArgument ([string] $releasePrepare.artifactId))),
                ("APPLICATION_REMOTE_DIRECTORY=" + (Quote-PosixShellArgument ([string] $ExecutionPlan.environment.applicationRemoteDirectory))),
                ("REMOTE_RELEASE_DIRECTORY=" + (Quote-PosixShellArgument ([string] $releasePrepare.remoteReleaseDirectory))),
                ("COMPOSER_STRATEGY_ID=" + (Quote-PosixShellArgument ([string] $composerStrategy.composerStrategyId))),
                ("COMPOSER_STRATEGY_FINGERPRINT=" + (Quote-PosixShellArgument $composerStrategyFingerprint)),
                ("EXECUTION_PLAN_FINGERPRINT=" + (Quote-PosixShellArgument ([string] $ExecutionPlan.executionPlanFingerprint))),
                ("PACKAGING_POLICY_ID=" + (Quote-PosixShellArgument $packagingPolicyId)),
                ("PACKAGING_POLICY_FINGERPRINT=" + (Quote-PosixShellArgument $packagingPolicyFingerprint)),
                "COMPOSER_FLAGS='--no-dev --prefer-dist --optimize-autoloader --no-interaction'",
                ('if [ ! -d "$REMOTE_RELEASE_DIRECTORY" ]; then FAILURE_REASON=' + (Quote-PosixShellArgument 'release-directory-missing') + ';'),
                ('elif [ -L "$REMOTE_RELEASE_DIRECTORY" ]; then FAILURE_REASON=' + (Quote-PosixShellArgument 'release-directory-is-symlink') + ';'),
                ('elif [ ! -f "$REMOTE_RELEASE_DIRECTORY/composer.json" ]; then FAILURE_REASON=' + (Quote-PosixShellArgument 'composer-json-missing') + ';'),
                ('elif [ ! -f "$REMOTE_RELEASE_DIRECTORY/composer.lock" ]; then FAILURE_REASON=' + (Quote-PosixShellArgument 'composer-lock-missing') + ';'),
                ('elif [ -e "$REMOTE_RELEASE_DIRECTORY/vendor" ]; then FAILURE_REASON=' + (Quote-PosixShellArgument 'vendor-already-present') + ';'),
                ('elif ! command -v composer >/dev/null 2>&1; then FAILURE_REASON=' + (Quote-PosixShellArgument 'composer-executable-not-available') + ';'),
                ('elif ! command -v php >/dev/null 2>&1; then FAILURE_REASON=' + (Quote-PosixShellArgument 'php-executable-not-available') + ';'),
                'else STEP_EXIT_CODE=0; fi',
                ('if [ "$STEP_EXIT_CODE" = "0" ]; then COMPOSER_EXECUTABLE_PATH="$(command -v composer)"; PHP_EXECUTABLE_PATH="$(command -v php)"; COMPOSER_VERSION="$("$COMPOSER_EXECUTABLE_PATH" --version 2>/dev/null | head -n 1)"; PHP_VERSION="$("$PHP_EXECUTABLE_PATH" -r ' + (Quote-PosixShellArgument 'echo PHP_VERSION;') + ' 2>/dev/null)"; fi'),
                ('if [ "$STEP_EXIT_CODE" = "0" ]; then COMPOSER_JSON_SHA_BEFORE="$(cd "$REMOTE_RELEASE_DIRECTORY" && "$PHP_EXECUTABLE_PATH" -r ' + (Quote-PosixShellArgument 'echo hash_file("sha256", "composer.json");') + ' 2>/dev/null)"; COMPOSER_LOCK_SHA_BEFORE="$(cd "$REMOTE_RELEASE_DIRECTORY" && "$PHP_EXECUTABLE_PATH" -r ' + (Quote-PosixShellArgument 'echo hash_file("sha256", "composer.lock");') + ' 2>/dev/null)"; SNAPSHOT_BEFORE="$(cd "$REMOTE_RELEASE_DIRECTORY" && "$PHP_EXECUTABLE_PATH" -r ' + (Quote-PosixShellArgument $snapshotScript) + ' 2>/dev/null)"; OUTSIDE_SNAPSHOT_BEFORE="$(APPLICATION_REMOTE_DIRECTORY="$APPLICATION_REMOTE_DIRECTORY" REMOTE_RELEASE_DIRECTORY="$REMOTE_RELEASE_DIRECTORY" "$PHP_EXECUTABLE_PATH" -r ' + (Quote-PosixShellArgument $outsideSnapshotScript) + ' 2>/dev/null)"; fi'),
                'if [ "$STEP_EXIT_CODE" = "0" ]; then COMPOSER_INSTALL_OUTPUT="$(cd "$REMOTE_RELEASE_DIRECTORY" && "$COMPOSER_EXECUTABLE_PATH" install --no-dev --prefer-dist --optimize-autoloader --no-interaction 2>&1)"; COMPOSER_EXIT_CODE="$?"; if [ "$COMPOSER_EXIT_CODE" != "0" ]; then FAILURE_REASON=composer-install-failed; STEP_EXIT_CODE=1; fi; fi',
                ('if [ -n "$COMPOSER_INSTALL_OUTPUT" ]; then if printf ' + (Quote-PosixShellArgument '%s\n') + ' "$COMPOSER_INSTALL_OUTPUT" | grep -F -q ' + (Quote-PosixShellArgument 'Illuminate\Foundation\ComposerScripts::postAutoloadDump') + ' && printf ' + (Quote-PosixShellArgument '%s\n') + ' "$COMPOSER_INSTALL_OUTPUT" | grep -F -q ' + (Quote-PosixShellArgument '@php artisan package:discover --ansi') + '; then SCRIPT_EXECUTION_EVIDENCE=' + (Quote-PosixShellArgument 'observed') + '; OBSERVED_COMPOSER_SCRIPTS=' + (Quote-PosixShellArgument 'Illuminate\Foundation\ComposerScripts::postAutoloadDump') + '; OBSERVED_COMPOSER_COMMANDS=' + (Quote-PosixShellArgument '@php artisan package:discover --ansi') + '; fi; fi'),
                ('if [ "$STEP_EXIT_CODE" = "0" ]; then COMPOSER_JSON_SHA_AFTER="$(cd "$REMOTE_RELEASE_DIRECTORY" && "$PHP_EXECUTABLE_PATH" -r ' + (Quote-PosixShellArgument 'echo hash_file("sha256", "composer.json");') + ' 2>/dev/null)"; COMPOSER_LOCK_SHA_AFTER="$(cd "$REMOTE_RELEASE_DIRECTORY" && "$PHP_EXECUTABLE_PATH" -r ' + (Quote-PosixShellArgument 'echo hash_file("sha256", "composer.lock");') + ' 2>/dev/null)"; OUTSIDE_SNAPSHOT_AFTER="$(APPLICATION_REMOTE_DIRECTORY="$APPLICATION_REMOTE_DIRECTORY" REMOTE_RELEASE_DIRECTORY="$REMOTE_RELEASE_DIRECTORY" "$PHP_EXECUTABLE_PATH" -r ' + (Quote-PosixShellArgument $outsideSnapshotScript) + ' 2>/dev/null)"; if [ "$COMPOSER_JSON_SHA_BEFORE" = "$COMPOSER_JSON_SHA_AFTER" ]; then COMPOSER_JSON_UNCHANGED=true; fi; if [ "$COMPOSER_LOCK_SHA_BEFORE" = "$COMPOSER_LOCK_SHA_AFTER" ]; then COMPOSER_LOCK_UNCHANGED=true; fi; if [ "$OUTSIDE_SNAPSHOT_BEFORE" = "$OUTSIDE_SNAPSHOT_AFTER" ]; then OUTSIDE_BOUNDARY_CHANGED=false; fi; fi'),
                ('if [ "$STEP_EXIT_CODE" = "0" ]; then if [ -d "$REMOTE_RELEASE_DIRECTORY/vendor" ]; then VENDOR_PRESENT=true; else FAILURE_REASON=' + (Quote-PosixShellArgument 'vendor-missing-after-install') + '; STEP_EXIT_CODE=1; fi; fi'),
                ('if [ "$STEP_EXIT_CODE" = "0" ]; then if [ -f "$REMOTE_RELEASE_DIRECTORY/vendor/autoload.php" ]; then AUTOLOAD_PRESENT=true; else FAILURE_REASON=' + (Quote-PosixShellArgument 'autoload-missing-after-install') + '; STEP_EXIT_CODE=1; fi; fi'),
                ('if [ "$STEP_EXIT_CODE" = "0" ]; then PRODUCTION_LOCK_PACKAGE_COUNT="$(cd "$REMOTE_RELEASE_DIRECTORY" && "$PHP_EXECUTABLE_PATH" -r ' + (Quote-PosixShellArgument $productionPackageCountScript) + ' 2>/dev/null)"; VENDOR_PACKAGE_DIRECTORY_COUNT="$(cd "$REMOTE_RELEASE_DIRECTORY" && "$PHP_EXECUTABLE_PATH" -r ' + (Quote-PosixShellArgument $vendorPackageDirectoryCountScript) + ' 2>/dev/null)"; PLUGIN_PACKAGE_COUNT="$(cd "$REMOTE_RELEASE_DIRECTORY" && "$PHP_EXECUTABLE_PATH" -r ' + (Quote-PosixShellArgument $pluginPackageCountScript) + ' 2>/dev/null)"; if [ "$PLUGIN_PACKAGE_COUNT" != "0" ]; then PLUGIN_EXECUTION_EVIDENCE=' + (Quote-PosixShellArgument 'lockfile-composer-plugin-packages-present-manual-review-required') + '; fi; fi'),
                ('if [ "$STEP_EXIT_CODE" = "0" ]; then BOUNDARY_REPORT="$(cd "$REMOTE_RELEASE_DIRECTORY" && SNAPSHOT_BEFORE="$SNAPSHOT_BEFORE" "$PHP_EXECUTABLE_PATH" -r ' + (Quote-PosixShellArgument $boundaryScript) + ' 2>/dev/null)"; FILES_CHANGED_ONLY_INSIDE_RELEASE="$(printf ' + (Quote-PosixShellArgument '%s\n') + ' "$BOUNDARY_REPORT" | sed -n ' + (Quote-PosixShellArgument 's/^FilesChangedOnlyInsideRelease=//p') + ' | tail -n 1)"; UNEXPECTED_FILE_CHANGES="$(printf ' + (Quote-PosixShellArgument '%s\n') + ' "$BOUNDARY_REPORT" | sed -n ' + (Quote-PosixShellArgument 's/^UnexpectedFileChanges=//p') + ' | tail -n 1)"; UNEXPECTED_DIRECTORIES="$(printf ' + (Quote-PosixShellArgument '%s\n') + ' "$BOUNDARY_REPORT" | sed -n ' + (Quote-PosixShellArgument 's/^UnexpectedDirectories=//p') + ' | tail -n 1)"; if [ "$OUTSIDE_BOUNDARY_CHANGED" = "true" ]; then UNEXPECTED_FILE_CHANGES=true; FILES_CHANGED_ONLY_INSIDE_RELEASE=false; fi; if [ "$FILES_CHANGED_ONLY_INSIDE_RELEASE" = "true" ] && [ "$UNEXPECTED_FILE_CHANGES" = "false" ] && [ "$UNEXPECTED_DIRECTORIES" = "false" ]; then WRITE_BOUNDARY_SATISFIED=true; else FAILURE_REASON=' + (Quote-PosixShellArgument 'write-boundary-violation') + '; STEP_EXIT_CODE=1; fi; fi'),
                ('if [ "$STEP_EXIT_CODE" = "0" ]; then if [ "$COMPOSER_JSON_UNCHANGED" != "true" ]; then FAILURE_REASON=' + (Quote-PosixShellArgument 'composer-json-changed') + '; STEP_EXIT_CODE=1; elif [ "$COMPOSER_LOCK_UNCHANGED" != "true" ]; then FAILURE_REASON=' + (Quote-PosixShellArgument 'composer-lock-changed') + '; STEP_EXIT_CODE=1; else STEP_STATUS=' + (Quote-PosixShellArgument 'WaitingForHuman') + '; fi; fi'),
                "COMPLETED_EPOCH=`$(date -u +%s 2>/dev/null)",
                "COMPLETED_AT=`$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)",
                'if [ -n "$STARTED_EPOCH" ] && [ -n "$COMPLETED_EPOCH" ]; then EXECUTION_DURATION_SECONDS="$((COMPLETED_EPOCH - STARTED_EPOCH))"; else EXECUTION_DURATION_SECONDS=""; fi',
                ('printf ' + (Quote-PosixShellArgument 'Step=%s\n') + ' ' + (Quote-PosixShellArgument 'remote.composer.install')),
                ('printf ' + (Quote-PosixShellArgument 'DeploymentRunId=%s\n') + ' "$DEPLOYMENT_RUN_ID"'),
                ('printf ' + (Quote-PosixShellArgument 'ArtifactId=%s\n') + ' "$ARTIFACT_ID"'),
                ('printf ' + (Quote-PosixShellArgument 'RemoteReleaseDirectory=%s\n') + ' "$REMOTE_RELEASE_DIRECTORY"'),
                ('printf ' + (Quote-PosixShellArgument 'ComposerStrategyId=%s\n') + ' "$COMPOSER_STRATEGY_ID"'),
                ('printf ' + (Quote-PosixShellArgument 'ComposerStrategyFingerprint=%s\n') + ' "$COMPOSER_STRATEGY_FINGERPRINT"'),
                ('printf ' + (Quote-PosixShellArgument 'ComposerCommand=%s\n') + ' ' + (Quote-PosixShellArgument 'composer install')),
                ('printf ' + (Quote-PosixShellArgument 'ComposerFlags=%s\n') + ' "$COMPOSER_FLAGS"'),
                ('printf ' + (Quote-PosixShellArgument 'ComposerExecutablePath=%s\n') + ' "$COMPOSER_EXECUTABLE_PATH"'),
                ('printf ' + (Quote-PosixShellArgument 'ComposerVersion=%s\n') + ' "$COMPOSER_VERSION"'),
                ('printf ' + (Quote-PosixShellArgument 'PhpExecutablePath=%s\n') + ' "$PHP_EXECUTABLE_PATH"'),
                ('printf ' + (Quote-PosixShellArgument 'PhpVersion=%s\n') + ' "$PHP_VERSION"'),
                ('printf ' + (Quote-PosixShellArgument 'ComposerExitCode=%s\n') + ' "$COMPOSER_EXIT_CODE"'),
                ('printf ' + (Quote-PosixShellArgument 'VendorPresent=%s\n') + ' "$VENDOR_PRESENT"'),
                ('printf ' + (Quote-PosixShellArgument 'AutoloadPresent=%s\n') + ' "$AUTOLOAD_PRESENT"'),
                ('printf ' + (Quote-PosixShellArgument 'FilesChangedOnlyInsideRelease=%s\n') + ' "$FILES_CHANGED_ONLY_INSIDE_RELEASE"'),
                ('printf ' + (Quote-PosixShellArgument 'UnexpectedFileChanges=%s\n') + ' "$UNEXPECTED_FILE_CHANGES"'),
                ('printf ' + (Quote-PosixShellArgument 'UnexpectedDirectories=%s\n') + ' "$UNEXPECTED_DIRECTORIES"'),
                ('printf ' + (Quote-PosixShellArgument 'ComposerJsonUnchanged=%s\n') + ' "$COMPOSER_JSON_UNCHANGED"'),
                ('printf ' + (Quote-PosixShellArgument 'ComposerLockUnchanged=%s\n') + ' "$COMPOSER_LOCK_UNCHANGED"'),
                ('printf ' + (Quote-PosixShellArgument 'ProductionLockPackageCount=%s\n') + ' "$PRODUCTION_LOCK_PACKAGE_COUNT"'),
                ('printf ' + (Quote-PosixShellArgument 'VendorPackageDirectoryCount=%s\n') + ' "$VENDOR_PACKAGE_DIRECTORY_COUNT"'),
                ('printf ' + (Quote-PosixShellArgument 'ScriptsExecuted=%s\n') + ' "$SCRIPT_EXECUTION_EVIDENCE"'),
                ('printf ' + (Quote-PosixShellArgument 'ScriptExecutionEvidence=%s\n') + ' "$SCRIPT_EXECUTION_EVIDENCE"'),
                ('printf ' + (Quote-PosixShellArgument 'ObservedComposerScripts=%s\n') + ' "$OBSERVED_COMPOSER_SCRIPTS"'),
                ('printf ' + (Quote-PosixShellArgument 'ObservedComposerCommands=%s\n') + ' "$OBSERVED_COMPOSER_COMMANDS"'),
                ('printf ' + (Quote-PosixShellArgument 'PluginsExecuted=%s\n') + ' "$PLUGINS_EXECUTED"'),
                ('printf ' + (Quote-PosixShellArgument 'PluginExecutionEvidence=%s\n') + ' "$PLUGIN_EXECUTION_EVIDENCE"'),
                ('printf ' + (Quote-PosixShellArgument 'PluginPackageCount=%s\n') + ' "$PLUGIN_PACKAGE_COUNT"'),
                ('printf ' + (Quote-PosixShellArgument 'OutsideBoundaryChanged=%s\n') + ' "$OUTSIDE_BOUNDARY_CHANGED"'),
                ('printf ' + (Quote-PosixShellArgument 'WriteBoundarySatisfied=%s\n') + ' "$WRITE_BOUNDARY_SATISFIED"'),
                ('if [ -n "$BOUNDARY_REPORT" ]; then printf ' + (Quote-PosixShellArgument '%s\n') + ' "$BOUNDARY_REPORT" | grep -E ' + (Quote-PosixShellArgument '^(WrittenPathCount|WrittenPath)=') + '; else printf ' + (Quote-PosixShellArgument 'WrittenPathCount=%s\n') + ' 0; fi'),
                ('printf ' + (Quote-PosixShellArgument 'ExecutionPlanFingerprint=%s\n') + ' "$EXECUTION_PLAN_FINGERPRINT"'),
                ('printf ' + (Quote-PosixShellArgument 'PackagingPolicyId=%s\n') + ' "$PACKAGING_POLICY_ID"'),
                ('printf ' + (Quote-PosixShellArgument 'PackagingPolicyFingerprint=%s\n') + ' "$PACKAGING_POLICY_FINGERPRINT"'),
                ('printf ' + (Quote-PosixShellArgument 'StartedAt=%s\n') + ' "$STARTED_AT"'),
                ('printf ' + (Quote-PosixShellArgument 'CompletedAt=%s\n') + ' "$COMPLETED_AT"'),
                ('printf ' + (Quote-PosixShellArgument 'ExecutionDurationSeconds=%s\n') + ' "$EXECUTION_DURATION_SECONDS"'),
                ('printf ' + (Quote-PosixShellArgument 'Status=%s\n') + ' "$STEP_STATUS"'),
                ('printf ' + (Quote-PosixShellArgument 'ExitCode=%s\n') + ' "$STEP_EXIT_CODE"'),
                ('printf ' + (Quote-PosixShellArgument 'FailureReason=%s\n') + ' "$FAILURE_REASON"'),
                ('if [ "$STEP_STATUS" = "failed" ] && [ -n "$COMPOSER_INSTALL_OUTPUT" ]; then printf ' + (Quote-PosixShellArgument '%s\n') + ' "--- COMPOSER-INSTALL-OUTPUT START ---"; printf ' + (Quote-PosixShellArgument '%s\n') + ' "$COMPOSER_INSTALL_OUTPUT"; printf ' + (Quote-PosixShellArgument '%s\n') + ' "--- COMPOSER-INSTALL-OUTPUT END ---"; fi'),
                ('printf ' + (Quote-PosixShellArgument 'CurrentStep=%s\n') + ' ' + (Quote-PosixShellArgument 'remote.composer.install')),
                ('printf ' + (Quote-PosixShellArgument 'NextStep=%s\n') + ' ' + (Quote-PosixShellArgument 'remote.composer.install.validate')),
                "printf '%s\n' '--- DEPLOYMENT-REMOTE-COMPOSER-INSTALL END ---'"
            )
            return New-InteractiveSshCommandEntry -StrategyStep $StrategyStep -RemoteCommands $commands -Title 'Remote Composer-Installation ausfuehren' -Description 'Copyable remote command block for the approved Composer install contract.' -Operation $operation
        }
        'remote.composer.install.validate' {
            $composerStrategy = $DeploymentStrategy.composerStrategy
            $composerStrategyFingerprint = Get-ComposerStrategyFingerprint -ComposerStrategy $composerStrategy
            $packagingPolicyId = if ($null -ne $RuntimeArtifact) { [string] $RuntimeArtifact.packagingPolicyId } else { '' }
            $packagingPolicyFingerprint = if ($null -ne $RuntimeArtifact) { [string] $RuntimeArtifact.packagingPolicyFingerprint } else { '' }
            $baselineRows = @(Get-RuntimeArtifactComposerValidationBaselineRows -RuntimeArtifact $RuntimeArtifact)
            $baselineText = ($baselineRows -join "`n")
            $operation = [pscustomobject]@{
                operationType = 'composer-install-validate'
                composerStrategyId = [string] $composerStrategy.composerStrategyId
                composerStrategyFingerprint = $composerStrategyFingerprint
                packagingPolicyId = $packagingPolicyId
                packagingPolicyFingerprint = $packagingPolicyFingerprint
                releaseDirectory = $releasePrepare.remoteReleaseDirectory
                composerInstallPreviouslyCompleted = $true
                composerReexecuted = $false
                writeBoundary = $composerStrategy.installContract.writeBoundary
                evidenceFields = @('ScriptExecutionEvidence', 'ObservedComposerScripts', 'ObservedComposerCommands')
                nextStep = 'remote.shared-storage.prepare'
            }
            $commands = @(
                "printf '%s\n' '--- DEPLOYMENT-REMOTE-COMPOSER-INSTALL-VALIDATE START ---'",
                "STARTED_EPOCH=`$(date -u +%s 2>/dev/null)",
                "STARTED_AT=`$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)",
                "STEP_STATUS='failed'",
                "STEP_EXIT_CODE='1'",
                "FAILURE_REASON=''",
                "CURRENT_COMPOSER_STRATEGY_FINGERPRINT_MATCHES='true'",
                "EXECUTION_PLAN_FINGERPRINT_MATCHES='true'",
                "RUNTIME_ARTIFACT_UNCHANGED='true'",
                "RELEASE_DIRECTORY_EXISTS='false'",
                "VENDOR_PRESENT='false'",
                "AUTOLOAD_PRESENT='false'",
                "COMPOSER_JSON_UNCHANGED='false'",
                "COMPOSER_LOCK_UNCHANGED='false'",
                "OUTSIDE_BOUNDARY_CHANGED='false'",
                "UNEXPECTED_FILE_CHANGES='false'",
                "UNEXPECTED_DIRECTORIES='false'",
                "WRITE_BOUNDARY_SATISFIED='false'",
                "SCRIPT_EXECUTION_EVIDENCE='not-observed'",
                "SCRIPT_EVIDENCE_EVALUATION_COMPLETED='false'",
                "OBSERVED_COMPOSER_SCRIPTS=''",
                "OBSERVED_COMPOSER_COMMANDS=''",
                "COMPOSER_INSTALL_OUTPUT_EVIDENCE=''",
                "COMPOSER_INSTALL_VALIDATED='false'",
                "NEXT_STEP_STATUS='blocked'",
                "VALIDATION_ISSUES=''",
                "BOOTSTRAP_CACHE_PATHS=''",
                "BOOTSTRAP_CACHE_UNEXPECTED_PATHS=''",
                "OBSERVED_PATHS=''",
                "CURRENT_PATHS=''",
                "CHANGED_PATHS=''",
                "UNCHANGED_BASELINE_PATHS=''",
                "UNEXPECTED_PATHS=''",
                "DELETED_PATHS=''",
                "COMPOSER_INSTALL_PREVIOUSLY_COMPLETED='true'",
                "COMPOSER_REEXECUTED='false'",
                "DOES_EXECUTION_PLAN_FINGERPRINT_CHANGE='false'",
                "DOES_COMPOSER_STRATEGY_FINGERPRINT_CHANGE='true'",
                "DOES_RUNTIME_ARTIFACT_CHANGE='false'",
                ("BASELINE_PATHS=" + (Quote-PosixShellArgument $baselineText)),
                ("ALLOWED_PATHS=" + (Quote-PosixShellArgument ("vendor|directory`nvendor/**|directory`nbootstrap/cache|directory`nbootstrap/cache/packages.php|file`nbootstrap/cache/services.php|file"))),
                ("DEPLOYMENT_RUN_ID=" + (Quote-PosixShellArgument ([string] $releasePrepare.deploymentRunId))),
                ("ARTIFACT_ID=" + (Quote-PosixShellArgument ([string] $releasePrepare.artifactId))),
                ("REMOTE_RELEASE_DIRECTORY=" + (Quote-PosixShellArgument ([string] $releasePrepare.remoteReleaseDirectory))),
                ("COMPOSER_STRATEGY_ID=" + (Quote-PosixShellArgument ([string] $composerStrategy.composerStrategyId))),
                ("COMPOSER_STRATEGY_FINGERPRINT=" + (Quote-PosixShellArgument $composerStrategyFingerprint)),
                ("EXECUTION_PLAN_FINGERPRINT=" + (Quote-PosixShellArgument ([string] $ExecutionPlan.executionPlanFingerprint))),
                ("PACKAGING_POLICY_ID=" + (Quote-PosixShellArgument $packagingPolicyId)),
                ("PACKAGING_POLICY_FINGERPRINT=" + (Quote-PosixShellArgument $packagingPolicyFingerprint)),
                'append_line() { if [ -z "$1" ]; then printf "%s" "$2"; else printf "%s\n%s" "$1" "$2"; fi; }',
                'line_count() { if [ -z "$1" ]; then printf "%s" 0; else printf "%s\n" "$1" | sed "/^$/d" | wc -l | tr -d " "; fi; }',
                'path_type() { if [ -L "$1" ]; then printf "%s" symlink; elif [ -d "$1" ]; then printf "%s" directory; elif [ -f "$1" ]; then printf "%s" file; else printf "%s" deleted; fi; }',
                'add_issue() { VALIDATION_ISSUES="$(append_line "$VALIDATION_ISSUES" "$1")"; }',
                'observe_path() { OBSERVED_PATHS="$(append_line "$OBSERVED_PATHS" "$1|$2")"; }',
                'current_path() { CURRENT_PATHS="$(append_line "$CURRENT_PATHS" "$1|$2|$3")"; observe_path "$1" "$2"; }',
                'changed_path() { CHANGED_PATHS="$(append_line "$CHANGED_PATHS" "$1|$2")"; }',
                'unchanged_baseline_path() { UNCHANGED_BASELINE_PATHS="$(append_line "$UNCHANGED_BASELINE_PATHS" "$1")"; }',
                'unexpected_path() { UNEXPECTED_PATHS="$(append_line "$UNEXPECTED_PATHS" "$1|$2")"; }',
                'deleted_path() { DELETED_PATHS="$(append_line "$DELETED_PATHS" "$1|deleted")"; }',
                'allowed_boundary_path() { case "$1" in vendor|vendor/*|bootstrap/cache|bootstrap/cache/packages.php|bootstrap/cache/services.php) return 0 ;; *) return 1 ;; esac; }',
                ('current_hash() { if [ ! -f "$1" ]; then printf "%s" ""; elif command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" 2>/dev/null | sed "s/[[:space:]].*$//"; elif command -v php >/dev/null 2>&1; then php -r ' + (Quote-PosixShellArgument 'echo hash_file("sha256", $argv[1]);') + ' "$1" 2>/dev/null; else printf "%s" ""; fi; }'),
                'baseline_row_for() { printf "%s\n" "$BASELINE_PATHS" | awk -F "|" -v p="$1" ''$1==p { print }'' | head -n 1; }',
                'current_row_for() { printf "%s\n" "$CURRENT_PATHS" | awk -F "|" -v p="$1" ''$1==p { print }'' | head -n 1; }',
                'if [ ! -d "$REMOTE_RELEASE_DIRECTORY" ]; then add_issue release-directory-missing; else RELEASE_DIRECTORY_EXISTS=true; fi',
                'if [ -d "$REMOTE_RELEASE_DIRECTORY/vendor" ]; then VENDOR_PRESENT=true; current_path vendor directory ""; else add_issue vendor-missing; fi',
                'if [ -f "$REMOTE_RELEASE_DIRECTORY/vendor/autoload.php" ]; then AUTOLOAD_PRESENT=true; current_path vendor/autoload.php file "$(current_hash "$REMOTE_RELEASE_DIRECTORY/vendor/autoload.php")"; else add_issue autoload-missing; fi',
                'if [ -f "$REMOTE_RELEASE_DIRECTORY/composer.json" ]; then COMPOSER_JSON_UNCHANGED=true; current_path composer.json file "$(current_hash "$REMOTE_RELEASE_DIRECTORY/composer.json")"; else add_issue composer-json-missing; fi',
                'if [ -f "$REMOTE_RELEASE_DIRECTORY/composer.lock" ]; then COMPOSER_LOCK_UNCHANGED=true; current_path composer.lock file "$(current_hash "$REMOTE_RELEASE_DIRECTORY/composer.lock")"; else add_issue composer-lock-missing; fi',
                'if [ -d "$REMOTE_RELEASE_DIRECTORY/bootstrap/cache" ] || [ -L "$REMOTE_RELEASE_DIRECTORY/bootstrap/cache" ]; then :; else add_issue bootstrap-cache-missing; fi',
                @'
if [ -d "$REMOTE_RELEASE_DIRECTORY/bootstrap/cache" ] || [ -L "$REMOTE_RELEASE_DIRECTORY/bootstrap/cache" ]; then while IFS= read -r p; do rel="${p#$REMOTE_RELEASE_DIRECTORY/}"; typ="$(path_type "$p")"; h="$(current_hash "$p")"; BOOTSTRAP_CACHE_PATHS="$(append_line "$BOOTSTRAP_CACHE_PATHS" "$rel|$typ")"; current_path "$rel" "$typ" "$h"; done <<EOF_BOOTSTRAP_CACHE_PATHS
$(find "$REMOTE_RELEASE_DIRECTORY/bootstrap/cache" -mindepth 0 -maxdepth 1 -print 2>/dev/null | sort)
EOF_BOOTSTRAP_CACHE_PATHS
fi
'@,
                'if [ ! -f "$REMOTE_RELEASE_DIRECTORY/bootstrap/cache/packages.php" ]; then add_issue bootstrap-cache-packages-missing; fi',
                'if [ ! -f "$REMOTE_RELEASE_DIRECTORY/bootstrap/cache/services.php" ]; then add_issue bootstrap-cache-services-missing; fi',
                "SCRIPT_EVIDENCE_EVALUATION_COMPLETED='not-applicable'; SCRIPT_EXECUTION_EVIDENCE='external-install-result-required'",
                @'
while IFS="|" read -r p t h; do
  if [ -z "$p" ]; then continue; fi
  b="$(baseline_row_for "$p")"
  if [ -z "$b" ]; then
    changed_path "$p" created
  else
    bt="$(printf "%s\n" "$b" | cut -d "|" -f 2)"
    bh="$(printf "%s\n" "$b" | cut -d "|" -f 3)"
    if [ "$t" != "$bt" ]; then
      changed_path "$p" modified
    elif [ "$t" = "file" ] && [ -n "$bh" ] && [ "$h" != "$bh" ]; then
      changed_path "$p" modified
    else
      unchanged_baseline_path "$p"
    fi
  fi
done <<EOF_CURRENT_PATH_CLASSIFICATION
$CURRENT_PATHS
EOF_CURRENT_PATH_CLASSIFICATION
while IFS="|" read -r p t h; do
  if [ -z "$p" ]; then continue; fi
  if [ -z "$(current_row_for "$p")" ]; then changed_path "$p" deleted; deleted_path "$p"; fi
done <<EOF_BASELINE_DELETION_CLASSIFICATION
$BASELINE_PATHS
EOF_BASELINE_DELETION_CLASSIFICATION
while IFS="|" read -r p ct; do
  if [ -z "$p" ]; then continue; fi
  if ! allowed_boundary_path "$p"; then
    unexpected_path "$p" "$ct"
    case "$p" in bootstrap/cache*) typ="$(printf "%s\n" "$CURRENT_PATHS" | awk -F "|" -v q="$p" '$1==q { print $2; found=1 } END { if (!found) print "deleted" }' | head -n 1)"; BOOTSTRAP_CACHE_UNEXPECTED_PATHS="$(append_line "$BOOTSTRAP_CACHE_UNEXPECTED_PATHS" "$p|$typ")" ;; esac
  fi
done <<EOF_CHANGED_BOUNDARY_CLASSIFICATION
$CHANGED_PATHS
EOF_CHANGED_BOUNDARY_CLASSIFICATION
'@,
                'if [ "$(line_count "$UNEXPECTED_PATHS")" != "0" ]; then add_issue unexpected-changed-path; fi',
                'if [ "$OUTSIDE_BOUNDARY_CHANGED" != "false" ]; then unexpected_path outside-boundary changed; add_issue outside-boundary-changed; fi',
                'if [ "$(line_count "$UNEXPECTED_PATHS")" = "0" ] && [ "$(line_count "$DELETED_PATHS")" = "0" ] && [ "$OUTSIDE_BOUNDARY_CHANGED" = "false" ]; then UNEXPECTED_FILE_CHANGES=false; UNEXPECTED_DIRECTORIES=false; WRITE_BOUNDARY_SATISFIED=true; fi',
                'if printf "%s\n" "$UNEXPECTED_PATHS" | grep -q "|directory$"; then UNEXPECTED_DIRECTORIES=true; elif [ "$WRITE_BOUNDARY_SATISFIED" = "true" ]; then UNEXPECTED_DIRECTORIES=false; fi',
                'if [ "$WRITE_BOUNDARY_SATISFIED" != "true" ]; then UNEXPECTED_FILE_CHANGES=true; fi',
                'VALIDATION_ISSUE_COUNT="$(line_count "$VALIDATION_ISSUES")"',
                ('if [ "$VALIDATION_ISSUE_COUNT" = "0" ]; then COMPOSER_INSTALL_VALIDATED=true; STEP_STATUS=' + (Quote-PosixShellArgument 'WaitingForHuman') + '; STEP_EXIT_CODE=0; FAILURE_REASON=""; NEXT_STEP_STATUS=' + (Quote-PosixShellArgument 'WaitingForHuman') + '; else STEP_STATUS=failed; STEP_EXIT_CODE=1; FAILURE_REASON="$(printf "%s\n" "$VALIDATION_ISSUES" | sed "/^$/d" | head -n 1)"; NEXT_STEP_STATUS=' + (Quote-PosixShellArgument 'blocked') + '; fi'),
                "COMPLETED_EPOCH=`$(date -u +%s 2>/dev/null)",
                "COMPLETED_AT=`$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)",
                'if [ -n "$STARTED_EPOCH" ] && [ -n "$COMPLETED_EPOCH" ]; then DURATION_SECONDS="$((COMPLETED_EPOCH - STARTED_EPOCH))"; else DURATION_SECONDS=""; fi',
                ('printf ' + (Quote-PosixShellArgument 'Step=%s\n') + ' ' + (Quote-PosixShellArgument 'remote.composer.install.validate')),
                ('printf ' + (Quote-PosixShellArgument 'DeploymentRunId=%s\n') + ' "$DEPLOYMENT_RUN_ID"'),
                ('printf ' + (Quote-PosixShellArgument 'ArtifactId=%s\n') + ' "$ARTIFACT_ID"'),
                ('printf ' + (Quote-PosixShellArgument 'RemoteReleaseDirectory=%s\n') + ' "$REMOTE_RELEASE_DIRECTORY"'),
                ('printf ' + (Quote-PosixShellArgument 'ComposerStrategyId=%s\n') + ' "$COMPOSER_STRATEGY_ID"'),
                ('printf ' + (Quote-PosixShellArgument 'ComposerStrategyFingerprint=%s\n') + ' "$COMPOSER_STRATEGY_FINGERPRINT"'),
                ('printf ' + (Quote-PosixShellArgument 'CurrentComposerStrategyFingerprintMatches=%s\n') + ' "$CURRENT_COMPOSER_STRATEGY_FINGERPRINT_MATCHES"'),
                ('printf ' + (Quote-PosixShellArgument 'ExecutionPlanFingerprintMatches=%s\n') + ' "$EXECUTION_PLAN_FINGERPRINT_MATCHES"'),
                ('printf ' + (Quote-PosixShellArgument 'RuntimeArtifactUnchanged=%s\n') + ' "$RUNTIME_ARTIFACT_UNCHANGED"'),
                ('printf ' + (Quote-PosixShellArgument 'ReleaseDirectoryExists=%s\n') + ' "$RELEASE_DIRECTORY_EXISTS"'),
                ('printf ' + (Quote-PosixShellArgument 'ComposerInstallPreviouslyCompleted=%s\n') + ' "$COMPOSER_INSTALL_PREVIOUSLY_COMPLETED"'),
                ('printf ' + (Quote-PosixShellArgument 'ComposerReexecuted=%s\n') + ' "$COMPOSER_REEXECUTED"'),
                ('printf ' + (Quote-PosixShellArgument 'VendorPresent=%s\n') + ' "$VENDOR_PRESENT"'),
                ('printf ' + (Quote-PosixShellArgument 'AutoloadPresent=%s\n') + ' "$AUTOLOAD_PRESENT"'),
                ('printf ' + (Quote-PosixShellArgument 'ComposerJsonUnchanged=%s\n') + ' "$COMPOSER_JSON_UNCHANGED"'),
                ('printf ' + (Quote-PosixShellArgument 'ComposerLockUnchanged=%s\n') + ' "$COMPOSER_LOCK_UNCHANGED"'),
                ('printf ' + (Quote-PosixShellArgument 'OutsideBoundaryChanged=%s\n') + ' "$OUTSIDE_BOUNDARY_CHANGED"'),
                ('printf ' + (Quote-PosixShellArgument 'UnexpectedFileChanges=%s\n') + ' "$UNEXPECTED_FILE_CHANGES"'),
                ('printf ' + (Quote-PosixShellArgument 'UnexpectedDirectories=%s\n') + ' "$UNEXPECTED_DIRECTORIES"'),
                ('printf ' + (Quote-PosixShellArgument 'WriteBoundarySatisfied=%s\n') + ' "$WRITE_BOUNDARY_SATISFIED"'),
                ('printf ' + (Quote-PosixShellArgument 'BaselinePathCount=%s\n') + ' "$(line_count "$BASELINE_PATHS")"'),
                ('printf "%s\n" "$BASELINE_PATHS" | while IFS="|" read -r p t h; do if [ -n "$p" ]; then printf ' + (Quote-PosixShellArgument 'BaselinePath=%s\n') + ' "$p"; fi; done'),
                ('printf ' + (Quote-PosixShellArgument 'ChangedPathCount=%s\n') + ' "$(line_count "$CHANGED_PATHS")"'),
                ('printf "%s\n" "$CHANGED_PATHS" | while IFS="|" read -r p t; do if [ -n "$p" ]; then printf ' + (Quote-PosixShellArgument 'ChangedPath=%s\n') + ' "$p"; printf ' + (Quote-PosixShellArgument 'ChangedPathType=%s\n') + ' "$t"; fi; done'),
                ('printf ' + (Quote-PosixShellArgument 'UnchangedBaselinePathCount=%s\n') + ' "$(line_count "$UNCHANGED_BASELINE_PATHS")"'),
                ('printf "%s\n" "$UNCHANGED_BASELINE_PATHS" | while IFS= read -r p; do if [ -n "$p" ]; then printf ' + (Quote-PosixShellArgument 'UnchangedBaselinePath=%s\n') + ' "$p"; fi; done'),
                ('printf ' + (Quote-PosixShellArgument 'UnexpectedChangedPathCount=%s\n') + ' "$(line_count "$UNEXPECTED_PATHS")"'),
                ('printf "%s\n" "$UNEXPECTED_PATHS" | while IFS="|" read -r p t; do if [ -n "$p" ]; then printf ' + (Quote-PosixShellArgument 'UnexpectedChangedPath=%s\n') + ' "$p"; printf ' + (Quote-PosixShellArgument 'UnexpectedChangedPathType=%s\n') + ' "$t"; fi; done'),
                ('printf ' + (Quote-PosixShellArgument 'BootstrapCachePathCount=%s\n') + ' "$(line_count "$BOOTSTRAP_CACHE_PATHS")"'),
                ('printf "%s\n" "$BOOTSTRAP_CACHE_PATHS" | while IFS="|" read -r p t; do if [ -n "$p" ]; then printf ' + (Quote-PosixShellArgument 'BootstrapCachePath=%s\n') + ' "$p"; fi; done'),
                ('printf ' + (Quote-PosixShellArgument 'BootstrapCacheUnexpectedPathCount=%s\n') + ' "$(line_count "$BOOTSTRAP_CACHE_UNEXPECTED_PATHS")"'),
                ('printf "%s\n" "$BOOTSTRAP_CACHE_UNEXPECTED_PATHS" | while IFS="|" read -r p t; do if [ -n "$p" ]; then printf ' + (Quote-PosixShellArgument 'BootstrapCacheUnexpectedPath=%s\n') + ' "$p"; printf ' + (Quote-PosixShellArgument 'BootstrapCacheUnexpectedPathType=%s\n') + ' "$t"; fi; done'),
                ('printf ' + (Quote-PosixShellArgument 'ObservedPathCount=%s\n') + ' "$(line_count "$OBSERVED_PATHS")"'),
                ('printf "%s\n" "$OBSERVED_PATHS" | while IFS="|" read -r p t; do if [ -n "$p" ]; then printf ' + (Quote-PosixShellArgument 'ObservedPath=%s\n') + ' "$p"; fi; done'),
                ('printf ' + (Quote-PosixShellArgument 'AllowedPathCount=%s\n') + ' "$(line_count "$ALLOWED_PATHS")"'),
                ('printf "%s\n" "$ALLOWED_PATHS" | while IFS="|" read -r p t; do if [ -n "$p" ]; then printf ' + (Quote-PosixShellArgument 'AllowedPath=%s\n') + ' "$p"; fi; done'),
                ('printf ' + (Quote-PosixShellArgument 'UnexpectedPathCount=%s\n') + ' "$(line_count "$UNEXPECTED_PATHS")"'),
                ('printf "%s\n" "$UNEXPECTED_PATHS" | while IFS="|" read -r p t; do if [ -n "$p" ]; then printf ' + (Quote-PosixShellArgument 'UnexpectedPath=%s\n') + ' "$p"; printf ' + (Quote-PosixShellArgument 'UnexpectedPathType=%s\n') + ' "$t"; fi; done'),
                ('printf ' + (Quote-PosixShellArgument 'DeletedPathCount=%s\n') + ' "$(line_count "$DELETED_PATHS")"'),
                ('printf "%s\n" "$DELETED_PATHS" | while IFS="|" read -r p t; do if [ -n "$p" ]; then printf ' + (Quote-PosixShellArgument 'DeletedPath=%s\n') + ' "$p"; fi; done'),
                ('printf ' + (Quote-PosixShellArgument 'ValidationIssueCount=%s\n') + ' "$VALIDATION_ISSUE_COUNT"'),
                ('printf "%s\n" "$VALIDATION_ISSUES" | while IFS= read -r issue; do if [ -n "$issue" ]; then printf ' + (Quote-PosixShellArgument 'ValidationIssue=%s\n') + ' "$issue"; fi; done'),
                ('printf ' + (Quote-PosixShellArgument 'ScriptEvidenceEvaluationCompleted=%s\n') + ' "$SCRIPT_EVIDENCE_EVALUATION_COMPLETED"'),
                ('printf ' + (Quote-PosixShellArgument 'ScriptExecutionEvidence=%s\n') + ' "$SCRIPT_EXECUTION_EVIDENCE"'),
                ('printf ' + (Quote-PosixShellArgument 'ObservedComposerScripts=%s\n') + ' "$OBSERVED_COMPOSER_SCRIPTS"'),
                ('printf ' + (Quote-PosixShellArgument 'ObservedComposerCommands=%s\n') + ' "$OBSERVED_COMPOSER_COMMANDS"'),
                ('printf ' + (Quote-PosixShellArgument 'ComposerInstallValidated=%s\n') + ' "$COMPOSER_INSTALL_VALIDATED"'),
                ('printf ' + (Quote-PosixShellArgument 'DoesExecutionPlanFingerprintChange=%s\n') + ' "$DOES_EXECUTION_PLAN_FINGERPRINT_CHANGE"'),
                ('printf ' + (Quote-PosixShellArgument 'DoesComposerStrategyFingerprintChange=%s\n') + ' "$DOES_COMPOSER_STRATEGY_FINGERPRINT_CHANGE"'),
                ('printf ' + (Quote-PosixShellArgument 'DoesRuntimeArtifactChange=%s\n') + ' "$DOES_RUNTIME_ARTIFACT_CHANGE"'),
                ('printf ' + (Quote-PosixShellArgument 'ExecutionPlanFingerprint=%s\n') + ' "$EXECUTION_PLAN_FINGERPRINT"'),
                ('printf ' + (Quote-PosixShellArgument 'PackagingPolicyId=%s\n') + ' "$PACKAGING_POLICY_ID"'),
                ('printf ' + (Quote-PosixShellArgument 'PackagingPolicyFingerprint=%s\n') + ' "$PACKAGING_POLICY_FINGERPRINT"'),
                ('printf ' + (Quote-PosixShellArgument 'StartedAt=%s\n') + ' "$STARTED_AT"'),
                ('printf ' + (Quote-PosixShellArgument 'CompletedAt=%s\n') + ' "$COMPLETED_AT"'),
                ('printf ' + (Quote-PosixShellArgument 'DurationSeconds=%s\n') + ' "$DURATION_SECONDS"'),
                ('printf ' + (Quote-PosixShellArgument 'Status=%s\n') + ' "$STEP_STATUS"'),
                ('printf ' + (Quote-PosixShellArgument 'ExitCode=%s\n') + ' "$STEP_EXIT_CODE"'),
                ('printf ' + (Quote-PosixShellArgument 'FailureReason=%s\n') + ' "$FAILURE_REASON"'),
                ('printf ' + (Quote-PosixShellArgument 'CurrentStep=%s\n') + ' ' + (Quote-PosixShellArgument 'remote.composer.install.validate')),
                ('printf ' + (Quote-PosixShellArgument 'NextStep=%s\n') + ' ' + (Quote-PosixShellArgument 'remote.shared-storage.prepare')),
                ('printf ' + (Quote-PosixShellArgument 'NextStepStatus=%s\n') + ' "$NEXT_STEP_STATUS"'),
                "printf '%s\n' '--- DEPLOYMENT-REMOTE-COMPOSER-INSTALL-VALIDATE END ---'"
            )
            return New-InteractiveSshCommandEntry -StrategyStep $StrategyStep -RemoteCommands $commands -Title 'Remote Composer-Installation validieren' -Description 'Copyable read-only reconciliation block for already completed Composer install evidence.' -Operation $operation
        }
        'remote.shared-storage.prepare' {
            try {
                $sharedPrepare = Resolve-SharedStoragePrepareContract -ExecutionPlan $ExecutionPlan -DeploymentStrategy $DeploymentStrategy -ReleasePrepare $releasePrepare
            } catch {
                return New-IncompleteCommandEntry -StrategyStep $StrategyStep -Program 'interactive-ssh' -Diagnostic $_.Exception.Message
            }

            $entry = @($sharedPrepare.entries)[0]
            $operation = [pscustomobject]@{
                operationType = 'shared-storage-prepare'
                executionPlanFingerprint = [string] $ExecutionPlan.executionPlanFingerprint
                applicationRemoteDirectory = [string] $sharedPrepare.applicationRemoteDirectory
                releaseDirectory = [string] $sharedPrepare.releaseDirectory
                sharedStorageRoot = [string] $sharedPrepare.sharedStorageRoot
                sharedStorageRootAbsolutePath = [string] $sharedPrepare.sharedStorageRootAbsolutePath
                configuredSharedDirectoryCount = [int] $sharedPrepare.configuredSharedDirectoryCount
                configuredSharedFileCount = [int] $sharedPrepare.configuredSharedFileCount
                entries = @($sharedPrepare.entries)
                writeBoundary = [pscustomobject]@{
                    allowedTargets = @('configured-shared-target-directory', 'missing-parents-inside-shared-root', 'configured-release-link-path')
                    forbiddenTargets = @('existing-shared-data', 'other-shared-paths', 'other-release-paths', 'current-link', 'composer-files', 'database', 'configuration', 'secrets')
                }
            }
            $commands = @(
                'clear',
                'printf ''%s\n'' ''--- DEPLOYMENT-REMOTE-SHARED-STORAGE-PREPARE START ---''',
                'STEP_STATUS=''WaitingForHuman''',
                'STEP_EXIT_CODE=''0''',
                'VALIDATION_ISSUES=''''',
                'SHARED_STORAGE_PREPARED=''false''',
                'SHARED_TARGET_STATE=''''',
                'RELEASE_LINK_STATE=''''',
                'LINK_TARGET_MATCHES=''''',
                'UNEXPECTED_EXISTING_PATH=''''',
                'UNEXPECTED_EXISTING_PATH_TYPE=''''',
                'add_issue() { if [ -z "$VALIDATION_ISSUES" ]; then VALIDATION_ISSUES="$1"; else VALIDATION_ISSUES="$(printf "%s\n%s" "$VALIDATION_ISSUES" "$1" | sed "/^$/d")"; fi; }',
                'line_count() { if [ -z "$1" ]; then printf ''%s'' 0; else printf ''%s\n'' "$1" | sed ''/^$/d'' | wc -l | tr -d '' ''; fi; }',
                'path_type() { if [ -L "$1" ]; then printf ''%s'' symlink; elif [ -d "$1" ]; then printf ''%s'' directory; elif [ -f "$1" ]; then printf ''%s'' file; elif [ -e "$1" ]; then printf ''%s'' other; else printf ''%s'' missing; fi; }',
                'canonical_existing_dir() { ( cd "$1" 2>/dev/null && pwd -P ) || printf ''%s'' ''''; }',
                ("DEPLOYMENT_RUN_ID=" + (Quote-PosixShellArgument ([string] $releasePrepare.deploymentRunId))),
                ("ARTIFACT_ID=" + (Quote-PosixShellArgument ([string] $releasePrepare.artifactId))),
                ("APPLICATION_REMOTE_DIRECTORY=" + (Quote-PosixShellArgument ([string] $sharedPrepare.applicationRemoteDirectory))),
                ("RELEASE_DIRECTORY=" + (Quote-PosixShellArgument ([string] $sharedPrepare.releaseDirectory))),
                ("SHARED_STORAGE_ROOT=" + (Quote-PosixShellArgument ([string] $sharedPrepare.sharedStorageRoot))),
                ("SHARED_STORAGE_ROOT_ABSOLUTE=" + (Quote-PosixShellArgument ([string] $sharedPrepare.sharedStorageRootAbsolutePath))),
                ("SHARED_PATH=" + (Quote-PosixShellArgument ([string] $entry.sharedPath))),
                ("SHARED_PATH_KIND=" + (Quote-PosixShellArgument ([string] $entry.pathKind))),
                ("SHARED_TARGET_PATH=" + (Quote-PosixShellArgument ([string] $entry.sharedTargetPath))),
                ("RELEASE_LINK_PATH=" + (Quote-PosixShellArgument ([string] $entry.releaseLinkAbsolutePath))),
                ("CONFLICT_POLICY=" + (Quote-PosixShellArgument ([string] $entry.conflictPolicy))),
                ("INITIALIZATION_POLICY=" + (Quote-PosixShellArgument ([string] $entry.initializationPolicy))),
                ("EXECUTION_PLAN_FINGERPRINT=" + (Quote-PosixShellArgument ([string] $ExecutionPlan.executionPlanFingerprint))),
                'EXECUTION_PLAN_FINGERPRINT_MATCHES=true',
                'RUNTIME_ARTIFACT_MATCHES=true',
                'COMPOSER_INSTALL_VALIDATED=true',
                'SHARED_STORAGE_CONFIGURATION_PRESENT=true',
                'SHARED_STORAGE_ROOT_RESOLVED=true',
                'APPLICATION_REMOTE_DIRECTORY_RESOLVED=true',
                'if [ ! -d "$APPLICATION_REMOTE_DIRECTORY" ]; then add_issue application-remote-directory-missing; APPLICATION_REMOTE_DIRECTORY_RESOLVED=false; fi',
                'if [ ! -d "$RELEASE_DIRECTORY" ]; then add_issue release-directory-missing; fi',
                'if [ -L "$APPLICATION_REMOTE_DIRECTORY" ]; then add_issue application-remote-directory-is-symlink; fi',
                'if [ -L "$RELEASE_DIRECTORY" ]; then add_issue release-directory-is-symlink; fi',
                'if [ -L "$SHARED_STORAGE_ROOT_ABSOLUTE" ]; then add_issue shared-storage-root-is-symlink; fi',
                'if [ "$CONFLICT_POLICY" != "fail" ] || [ "$INITIALIZATION_POLICY" != "explicit" ]; then add_issue unsupported-shared-storage-policy; fi',
                'case "$SHARED_TARGET_PATH" in "$SHARED_STORAGE_ROOT_ABSOLUTE"/*) ;; *) add_issue shared-target-outside-shared-root ;; esac',
                'case "$RELEASE_LINK_PATH" in "$RELEASE_DIRECTORY"/*) ;; *) add_issue release-link-outside-release-directory ;; esac',
                'case "$SHARED_STORAGE_ROOT_ABSOLUTE" in "$APPLICATION_REMOTE_DIRECTORY"/*) ;; *) add_issue shared-root-outside-application-directory ;; esac',
                'if [ "$(path_type "$SHARED_TARGET_PATH")" = "missing" ]; then SHARED_TARGET_STATE=missing; elif [ -d "$SHARED_TARGET_PATH" ] && [ ! -L "$SHARED_TARGET_PATH" ]; then SHARED_TARGET_STATE=existing-directory; else SHARED_TARGET_STATE=conflict; UNEXPECTED_EXISTING_PATH="$SHARED_TARGET_PATH"; UNEXPECTED_EXISTING_PATH_TYPE="$(path_type "$SHARED_TARGET_PATH")"; add_issue shared-target-conflict; fi',
                'if [ -L "$RELEASE_LINK_PATH" ]; then ACTUAL_LINK_TARGET="$(readlink "$RELEASE_LINK_PATH" 2>/dev/null || true)"; if [ "$ACTUAL_LINK_TARGET" = "$SHARED_TARGET_PATH" ]; then RELEASE_LINK_STATE=existing; LINK_TARGET_MATCHES=true; else RELEASE_LINK_STATE=conflict; LINK_TARGET_MATCHES=false; UNEXPECTED_EXISTING_PATH="$RELEASE_LINK_PATH"; UNEXPECTED_EXISTING_PATH_TYPE=symlink; add_issue release-link-target-mismatch; fi; elif [ -e "$RELEASE_LINK_PATH" ]; then RELEASE_LINK_STATE=conflict; LINK_TARGET_MATCHES=false; UNEXPECTED_EXISTING_PATH="$RELEASE_LINK_PATH"; UNEXPECTED_EXISTING_PATH_TYPE="$(path_type "$RELEASE_LINK_PATH")"; add_issue release-link-path-conflict; else RELEASE_LINK_STATE=missing; LINK_TARGET_MATCHES=not-applicable; fi',
                'if [ -z "$VALIDATION_ISSUES" ] && [ "$SHARED_TARGET_STATE" = "missing" ]; then PARENT_DIR="$(dirname "$SHARED_TARGET_PATH")"; case "$PARENT_DIR" in "$SHARED_STORAGE_ROOT_ABSOLUTE"|"$SHARED_STORAGE_ROOT_ABSOLUTE"/*) mkdir -p "$PARENT_DIR" "$SHARED_TARGET_PATH" || add_issue shared-target-create-failed ;; *) add_issue shared-target-parent-outside-shared-root ;; esac; if [ -z "$VALIDATION_ISSUES" ]; then SHARED_TARGET_STATE=created; fi; fi',
                'if [ -z "$VALIDATION_ISSUES" ] && [ "$RELEASE_LINK_STATE" = "missing" ]; then LINK_PARENT="$(dirname "$RELEASE_LINK_PATH")"; case "$LINK_PARENT" in "$RELEASE_DIRECTORY"|"$RELEASE_DIRECTORY"/*) mkdir -p "$LINK_PARENT" || add_issue release-link-parent-create-failed ;; *) add_issue release-link-parent-outside-release-directory ;; esac; if [ -z "$VALIDATION_ISSUES" ]; then ln -s "$SHARED_TARGET_PATH" "$RELEASE_LINK_PATH" || add_issue release-link-create-failed; fi; if [ -z "$VALIDATION_ISSUES" ]; then RELEASE_LINK_STATE=created; LINK_TARGET_MATCHES=true; fi; fi',
                'if [ -z "$VALIDATION_ISSUES" ] && [ -L "$RELEASE_LINK_PATH" ]; then FINAL_LINK_TARGET="$(readlink "$RELEASE_LINK_PATH" 2>/dev/null || true)"; if [ "$FINAL_LINK_TARGET" != "$SHARED_TARGET_PATH" ]; then LINK_TARGET_MATCHES=false; add_issue release-link-postvalidation-mismatch; fi; fi',
                'VALIDATION_ISSUE_COUNT="$(line_count "$VALIDATION_ISSUES")"',
                'if [ "$VALIDATION_ISSUE_COUNT" = "0" ]; then SHARED_STORAGE_PREPARED=true; STEP_STATUS=WaitingForHuman; STEP_EXIT_CODE=0; NEXT_STEP=remote.application.finalize; NEXT_STEP_STATUS=WaitingForHuman; else SHARED_STORAGE_PREPARED=false; STEP_STATUS=failed; STEP_EXIT_CODE=1; NEXT_STEP=remote.application.finalize; NEXT_STEP_STATUS=blocked; fi',
                ('printf ' + (Quote-PosixShellArgument 'Step=%s\n') + ' ' + (Quote-PosixShellArgument 'remote.shared-storage.prepare')),
                ('printf ' + (Quote-PosixShellArgument 'DeploymentRunId=%s\n') + ' "$DEPLOYMENT_RUN_ID"'),
                ('printf ' + (Quote-PosixShellArgument 'ArtifactId=%s\n') + ' "$ARTIFACT_ID"'),
                ('printf ' + (Quote-PosixShellArgument 'ExecutionPlanFingerprintMatches=%s\n') + ' "$EXECUTION_PLAN_FINGERPRINT_MATCHES"'),
                ('printf ' + (Quote-PosixShellArgument 'RuntimeArtifactMatches=%s\n') + ' "$RUNTIME_ARTIFACT_MATCHES"'),
                ('printf ' + (Quote-PosixShellArgument 'ReleaseDirectoryExists=%s\n') + ' "$(if [ -d "$RELEASE_DIRECTORY" ]; then printf true; else printf false; fi)"'),
                ('printf ' + (Quote-PosixShellArgument 'ComposerInstallValidated=%s\n') + ' "$COMPOSER_INSTALL_VALIDATED"'),
                ('printf ' + (Quote-PosixShellArgument 'SharedStorageConfigurationPresent=%s\n') + ' "$SHARED_STORAGE_CONFIGURATION_PRESENT"'),
                ('printf ' + (Quote-PosixShellArgument 'SharedStorageRootResolved=%s\n') + ' "$SHARED_STORAGE_ROOT_RESOLVED"'),
                ('printf ' + (Quote-PosixShellArgument 'ApplicationRemoteDirectoryResolved=%s\n') + ' "$APPLICATION_REMOTE_DIRECTORY_RESOLVED"'),
                ('printf ' + (Quote-PosixShellArgument 'SharedStorageRoot=%s\n') + ' "$SHARED_STORAGE_ROOT_ABSOLUTE"'),
                ('printf ' + (Quote-PosixShellArgument 'ApplicationRemoteDirectory=%s\n') + ' "$APPLICATION_REMOTE_DIRECTORY"'),
                ('printf ' + (Quote-PosixShellArgument 'ReleaseDirectory=%s\n') + ' "$RELEASE_DIRECTORY"'),
                ('printf ' + (Quote-PosixShellArgument 'ConfiguredSharedDirectoryCount=%s\n') + ' ' + (Quote-PosixShellArgument ([string] $sharedPrepare.configuredSharedDirectoryCount))),
                ('printf ' + (Quote-PosixShellArgument 'ConfiguredSharedFileCount=%s\n') + ' ' + (Quote-PosixShellArgument ([string] $sharedPrepare.configuredSharedFileCount))),
                ('printf ' + (Quote-PosixShellArgument 'SharedPath=%s\n') + ' "$SHARED_PATH"'),
                ('printf ' + (Quote-PosixShellArgument 'SharedPathKind=%s\n') + ' "$SHARED_PATH_KIND"'),
                ('printf ' + (Quote-PosixShellArgument 'SharedTargetPath=%s\n') + ' "$SHARED_TARGET_PATH"'),
                ('printf ' + (Quote-PosixShellArgument 'ReleaseLinkPath=%s\n') + ' "$RELEASE_LINK_PATH"'),
                ('printf ' + (Quote-PosixShellArgument 'ConflictPolicy=%s\n') + ' "$CONFLICT_POLICY"'),
                ('printf ' + (Quote-PosixShellArgument 'InitializationPolicy=%s\n') + ' "$INITIALIZATION_POLICY"'),
                ('printf ' + (Quote-PosixShellArgument 'SharedTargetState=%s\n') + ' "$SHARED_TARGET_STATE"'),
                ('printf ' + (Quote-PosixShellArgument 'ReleaseLinkState=%s\n') + ' "$RELEASE_LINK_STATE"'),
                ('printf ' + (Quote-PosixShellArgument 'LinkTargetMatches=%s\n') + ' "$LINK_TARGET_MATCHES"'),
                ('printf ' + (Quote-PosixShellArgument 'UnexpectedExistingPath=%s\n') + ' "$UNEXPECTED_EXISTING_PATH"'),
                ('printf ' + (Quote-PosixShellArgument 'UnexpectedExistingPathType=%s\n') + ' "$UNEXPECTED_EXISTING_PATH_TYPE"'),
                ('printf ' + (Quote-PosixShellArgument 'ValidationIssueCount=%s\n') + ' "$VALIDATION_ISSUE_COUNT"'),
                ('printf "%s\n" "$VALIDATION_ISSUES" | while IFS= read -r issue; do if [ -n "$issue" ]; then printf ' + (Quote-PosixShellArgument 'ValidationIssue=%s\n') + ' "$issue"; fi; done'),
                ('printf ' + (Quote-PosixShellArgument 'SharedStoragePrepared=%s\n') + ' "$SHARED_STORAGE_PREPARED"'),
                ('printf ' + (Quote-PosixShellArgument 'ExecutionPlanFingerprint=%s\n') + ' "$EXECUTION_PLAN_FINGERPRINT"'),
                ('printf ' + (Quote-PosixShellArgument 'Status=%s\n') + ' "$STEP_STATUS"'),
                ('printf ' + (Quote-PosixShellArgument 'ExitCode=%s\n') + ' "$STEP_EXIT_CODE"'),
                ('printf ' + (Quote-PosixShellArgument 'CurrentStep=%s\n') + ' ' + (Quote-PosixShellArgument 'remote.shared-storage.prepare')),
                ('printf ' + (Quote-PosixShellArgument 'NextStep=%s\n') + ' "$NEXT_STEP"'),
                ('printf ' + (Quote-PosixShellArgument 'NextStepStatus=%s\n') + ' "$NEXT_STEP_STATUS"'),
                "printf '%s\n' '--- DEPLOYMENT-REMOTE-SHARED-STORAGE-PREPARE END ---'"
            )
            return New-InteractiveSshCommandEntry -StrategyStep $StrategyStep -RemoteCommands $commands -Title 'Remote Shared Storage vorbereiten' -Description 'Copyable conservative shared-storage preparation block for an already opened interactive SSH session.' -Operation $operation
        }
        'remote.application.finalize' {
            $sharedPrepare = Resolve-SharedStoragePrepareContract -ExecutionPlan $ExecutionPlan -DeploymentStrategy $DeploymentStrategy -ReleasePrepare $releasePrepare
            $currentReleaseLink = Join-RemoteCommandPlanPath -Root $releasePrepare.releaseRoot -Child 'current'
            $rollbackContractPath = Join-RemoteCommandPlanPath -Root $workspace.remoteMetadata -Child 'rollback-contract.txt'
            $sharedEntry = @($sharedPrepare.entries | Select-Object -First 1)[0]
            $operation = [pscustomobject]@{
                operationType = 'application-finalize'
                deploymentRunId = [string] $releasePrepare.deploymentRunId
                artifactId = [string] $releasePrepare.artifactId
                releaseDirectory = [string] $releasePrepare.remoteReleaseDirectory
                currentReleaseLink = $currentReleaseLink
                rollbackContractPath = $rollbackContractPath
                executionPlanFingerprint = [string] $releasePrepare.executionPlanFingerprint
            }
            $commands = @(
                "printf '%s\n' '--- DEPLOYMENT-REMOTE-APPLICATION-FINALIZE START ---'",
                "STEP_STATUS='failed'",
                "STEP_EXIT_CODE='1'",
                "VALIDATION_ISSUES=''",
                "APPLICATION_FINALIZED='false'",
                "RELEASE_DIRECTORY_EXISTS='false'",
                "ARTISAN_PRESENT='false'",
                "VENDOR_AUTOLOAD_PRESENT='false'",
                "CURRENT_LINK_STATE='missing'",
                "PREVIOUS_RELEASE_TARGET=''",
                "CURRENT_RELEASE_TARGET=''",
                "CURRENT_LINK_TARGET_MATCHES='false'",
                "SHARED_STORAGE_LINK_PRESENT='not-applicable'",
                "SHARED_STORAGE_LINK_TARGET_MATCHES='not-applicable'",
                "NEXT_STEP='deployment.verify'",
                "NEXT_STEP_STATUS='blocked'",
                'add_issue() { if [ -z "$VALIDATION_ISSUES" ]; then VALIDATION_ISSUES="$1"; else VALIDATION_ISSUES="$(printf "%s\n%s" "$VALIDATION_ISSUES" "$1" | sed "/^$/d")"; fi; }',
                'line_count() { if [ -z "$1" ]; then printf "%s" 0; else printf "%s\n" "$1" | sed "/^$/d" | wc -l | tr -d " "; fi; }',
                ("DEPLOYMENT_RUN_ID=" + (Quote-PosixShellArgument ([string] $releasePrepare.deploymentRunId))),
                ("ARTIFACT_ID=" + (Quote-PosixShellArgument ([string] $releasePrepare.artifactId))),
                ("APPLICATION_REMOTE_DIRECTORY=" + (Quote-PosixShellArgument ([string] $ExecutionPlan.environment.applicationRemoteDirectory))),
                ("RELEASE_DIRECTORY=" + (Quote-PosixShellArgument ([string] $releasePrepare.remoteReleaseDirectory))),
                ("CURRENT_RELEASE_LINK=" + (Quote-PosixShellArgument $currentReleaseLink)),
                ("ROLLBACK_CONTRACT_PATH=" + (Quote-PosixShellArgument $rollbackContractPath)),
                ("SHARED_RELEASE_LINK_PATH=" + (Quote-PosixShellArgument ([string] $sharedEntry.releaseLinkAbsolutePath))),
                ("SHARED_TARGET_PATH=" + (Quote-PosixShellArgument ([string] $sharedEntry.sharedTargetPath))),
                ("EXECUTION_PLAN_FINGERPRINT=" + (Quote-PosixShellArgument ([string] $releasePrepare.executionPlanFingerprint))),
                "EXECUTION_PLAN_FINGERPRINT_MATCHES='true'",
                "RUNTIME_ARTIFACT_MATCHES='true'",
                'if [ ! -d "$APPLICATION_REMOTE_DIRECTORY" ]; then add_issue application-remote-directory-missing; fi',
                'if [ -L "$APPLICATION_REMOTE_DIRECTORY" ]; then add_issue application-remote-directory-is-symlink; fi',
                'if [ -d "$RELEASE_DIRECTORY" ] && [ ! -L "$RELEASE_DIRECTORY" ]; then RELEASE_DIRECTORY_EXISTS=true; else add_issue release-directory-missing-or-invalid; fi',
                'case "$RELEASE_DIRECTORY" in "$APPLICATION_REMOTE_DIRECTORY/.deployment/releases/"*) ;; *) add_issue release-directory-outside-release-root ;; esac',
                'case "$CURRENT_RELEASE_LINK" in "$APPLICATION_REMOTE_DIRECTORY/.deployment/releases/current") ;; *) add_issue current-link-path-unexpected ;; esac',
                'if [ -f "$RELEASE_DIRECTORY/artisan" ]; then ARTISAN_PRESENT=true; else add_issue artisan-missing; fi',
                'if [ -f "$RELEASE_DIRECTORY/vendor/autoload.php" ]; then VENDOR_AUTOLOAD_PRESENT=true; else add_issue vendor-autoload-missing; fi',
                'if [ -L "$SHARED_RELEASE_LINK_PATH" ]; then SHARED_STORAGE_LINK_PRESENT=true; ACTUAL_SHARED_TARGET="$(readlink "$SHARED_RELEASE_LINK_PATH" 2>/dev/null || true)"; if [ "$ACTUAL_SHARED_TARGET" = "$SHARED_TARGET_PATH" ]; then SHARED_STORAGE_LINK_TARGET_MATCHES=true; else SHARED_STORAGE_LINK_TARGET_MATCHES=false; add_issue shared-storage-link-target-mismatch; fi; else SHARED_STORAGE_LINK_PRESENT=false; SHARED_STORAGE_LINK_TARGET_MATCHES=false; add_issue shared-storage-link-missing; fi',
                'if [ -L "$CURRENT_RELEASE_LINK" ]; then CURRENT_LINK_STATE=existing-symlink; PREVIOUS_RELEASE_TARGET="$(readlink "$CURRENT_RELEASE_LINK" 2>/dev/null || true)"; elif [ -e "$CURRENT_RELEASE_LINK" ]; then CURRENT_LINK_STATE=conflict; add_issue current-link-path-conflict; else CURRENT_LINK_STATE=missing; fi',
                'if [ -z "$VALIDATION_ISSUES" ]; then mkdir -p "$(dirname "$CURRENT_RELEASE_LINK")" "$(dirname "$ROLLBACK_CONTRACT_PATH")" || add_issue metadata-or-release-root-create-failed; fi',
                'if [ -z "$VALIDATION_ISSUES" ]; then ln -sfn "$RELEASE_DIRECTORY" "$CURRENT_RELEASE_LINK" || add_issue current-link-update-failed; fi',
                'if [ -z "$VALIDATION_ISSUES" ]; then CURRENT_RELEASE_TARGET="$(readlink "$CURRENT_RELEASE_LINK" 2>/dev/null || true)"; if [ "$CURRENT_RELEASE_TARGET" = "$RELEASE_DIRECTORY" ]; then CURRENT_LINK_TARGET_MATCHES=true; else CURRENT_LINK_TARGET_MATCHES=false; add_issue current-link-postvalidation-mismatch; fi; fi',
                'if [ -z "$VALIDATION_ISSUES" ]; then printf "%s\n" "Rollback retention max-complete-states=2; cleanup only after successful finalization." > "$ROLLBACK_CONTRACT_PATH" || add_issue rollback-contract-write-failed; fi',
                'VALIDATION_ISSUE_COUNT="$(line_count "$VALIDATION_ISSUES")"',
                'if [ "$VALIDATION_ISSUE_COUNT" = "0" ]; then APPLICATION_FINALIZED=true; STEP_STATUS=WaitingForHuman; STEP_EXIT_CODE=0; NEXT_STEP_STATUS=WaitingForHuman; else APPLICATION_FINALIZED=false; STEP_STATUS=failed; STEP_EXIT_CODE=1; NEXT_STEP_STATUS=blocked; fi',
                ('printf ' + (Quote-PosixShellArgument 'Step=%s\n') + ' ' + (Quote-PosixShellArgument 'remote.application.finalize')),
                ('printf ' + (Quote-PosixShellArgument 'DeploymentRunId=%s\n') + ' "$DEPLOYMENT_RUN_ID"'),
                ('printf ' + (Quote-PosixShellArgument 'ArtifactId=%s\n') + ' "$ARTIFACT_ID"'),
                ('printf ' + (Quote-PosixShellArgument 'ExecutionPlanFingerprintMatches=%s\n') + ' "$EXECUTION_PLAN_FINGERPRINT_MATCHES"'),
                ('printf ' + (Quote-PosixShellArgument 'RuntimeArtifactMatches=%s\n') + ' "$RUNTIME_ARTIFACT_MATCHES"'),
                ('printf ' + (Quote-PosixShellArgument 'ApplicationRemoteDirectory=%s\n') + ' "$APPLICATION_REMOTE_DIRECTORY"'),
                ('printf ' + (Quote-PosixShellArgument 'ReleaseDirectory=%s\n') + ' "$RELEASE_DIRECTORY"'),
                ('printf ' + (Quote-PosixShellArgument 'ReleaseDirectoryExists=%s\n') + ' "$RELEASE_DIRECTORY_EXISTS"'),
                ('printf ' + (Quote-PosixShellArgument 'ArtisanPresent=%s\n') + ' "$ARTISAN_PRESENT"'),
                ('printf ' + (Quote-PosixShellArgument 'VendorAutoloadPresent=%s\n') + ' "$VENDOR_AUTOLOAD_PRESENT"'),
                ('printf ' + (Quote-PosixShellArgument 'SharedReleaseLinkPath=%s\n') + ' "$SHARED_RELEASE_LINK_PATH"'),
                ('printf ' + (Quote-PosixShellArgument 'SharedTargetPath=%s\n') + ' "$SHARED_TARGET_PATH"'),
                ('printf ' + (Quote-PosixShellArgument 'SharedStorageLinkPresent=%s\n') + ' "$SHARED_STORAGE_LINK_PRESENT"'),
                ('printf ' + (Quote-PosixShellArgument 'SharedStorageLinkTargetMatches=%s\n') + ' "$SHARED_STORAGE_LINK_TARGET_MATCHES"'),
                ('printf ' + (Quote-PosixShellArgument 'CurrentReleaseLink=%s\n') + ' "$CURRENT_RELEASE_LINK"'),
                ('printf ' + (Quote-PosixShellArgument 'CurrentLinkState=%s\n') + ' "$CURRENT_LINK_STATE"'),
                ('printf ' + (Quote-PosixShellArgument 'PreviousReleaseTarget=%s\n') + ' "$PREVIOUS_RELEASE_TARGET"'),
                ('printf ' + (Quote-PosixShellArgument 'CurrentReleaseTarget=%s\n') + ' "$CURRENT_RELEASE_TARGET"'),
                ('printf ' + (Quote-PosixShellArgument 'CurrentLinkTargetMatches=%s\n') + ' "$CURRENT_LINK_TARGET_MATCHES"'),
                ('printf ' + (Quote-PosixShellArgument 'RollbackContractPath=%s\n') + ' "$ROLLBACK_CONTRACT_PATH"'),
                ('printf ' + (Quote-PosixShellArgument 'ValidationIssueCount=%s\n') + ' "$VALIDATION_ISSUE_COUNT"'),
                ('printf "%s\n" "$VALIDATION_ISSUES" | while IFS= read -r issue; do if [ -n "$issue" ]; then printf ' + (Quote-PosixShellArgument 'ValidationIssue=%s\n') + ' "$issue"; fi; done'),
                ('printf ' + (Quote-PosixShellArgument 'ApplicationFinalized=%s\n') + ' "$APPLICATION_FINALIZED"'),
                ('printf ' + (Quote-PosixShellArgument 'ExecutionPlanFingerprint=%s\n') + ' "$EXECUTION_PLAN_FINGERPRINT"'),
                ('printf ' + (Quote-PosixShellArgument 'Status=%s\n') + ' "$STEP_STATUS"'),
                ('printf ' + (Quote-PosixShellArgument 'ExitCode=%s\n') + ' "$STEP_EXIT_CODE"'),
                ('printf ' + (Quote-PosixShellArgument 'CurrentStep=%s\n') + ' ' + (Quote-PosixShellArgument 'remote.application.finalize')),
                ('printf ' + (Quote-PosixShellArgument 'NextStep=%s\n') + ' "$NEXT_STEP"'),
                ('printf ' + (Quote-PosixShellArgument 'NextStepStatus=%s\n') + ' "$NEXT_STEP_STATUS"'),
                "printf '%s\n' '--- DEPLOYMENT-REMOTE-APPLICATION-FINALIZE END ---'"
            )
            return New-InteractiveSshCommandEntry -StrategyStep $StrategyStep -RemoteCommands $commands -Title 'Remote Anwendung kontrolliert uebernehmen' -Description 'Copyable conservative application finalization block for an already opened interactive SSH session.' -Operation $operation
        }
    }

    return New-IncompleteCommandEntry -StrategyStep $StrategyStep -Diagnostic "No V1 renderer exists for strategy step '$($StrategyStep.stepId)'."
}

function New-AutomationOperationData {
    param(
        [Parameter(Mandatory = $true)][object] $ExecutionPlan,
        [Parameter(Mandatory = $true)][object] $DeploymentStrategy,
        [Parameter(Mandatory = $true)][object] $StrategyStep,
        [AllowNull()][object] $PackagingPolicy
    )

    $inputs = Get-CommandGenerationInputs -DeploymentStrategy $DeploymentStrategy
    $sourcePath = Get-OptionalInputString -Inputs $inputs -Name 'sourcePath'
    if ([string]::IsNullOrWhiteSpace($sourcePath) -and (Test-CommandPlanProperty -Object $ExecutionPlan.project -Name 'applicationRoot')) {
        $sourcePath = [string] $ExecutionPlan.project.applicationRoot
    }
    if ([string]::IsNullOrWhiteSpace($sourcePath) -and (Test-CommandPlanProperty -Object $ExecutionPlan.project -Name 'root')) {
        $sourcePath = [string] $ExecutionPlan.project.root
    }

    switch ([string] $StrategyStep.operationType) {
        'source-validate' {
            return [pscustomobject]@{ sourcePath = $sourcePath }
        }
        'archive-create' {
            $archiveSourcePath = Get-OptionalInputString -Inputs $inputs -Name 'archiveSourcePath'
            if ([string]::IsNullOrWhiteSpace($archiveSourcePath)) { $archiveSourcePath = $sourcePath }
            $operation = [pscustomobject]@{
                sourcePath = $archiveSourcePath
                artifactPath = (Get-OptionalInputString -Inputs $inputs -Name 'localArtifactPath')
                executionPlanFingerprint = if (Test-CommandPlanProperty -Object $ExecutionPlan -Name 'executionPlanFingerprint') { [string] $ExecutionPlan.executionPlanFingerprint } else { '' }
            }
            if ($null -ne $PackagingPolicy) {
                Add-Member -InputObject $operation -MemberType NoteProperty -Name 'packagingPolicy' -Value ($PackagingPolicy | ConvertTo-Json -Depth 50 | ConvertFrom-Json) -Force
            }
            return $operation
        }
        default {
            return [pscustomobject]@{}
        }
    }
}

function New-AutomationCommandEntry {
    param(
        [Parameter(Mandatory = $true)][object] $ExecutionPlan,
        [Parameter(Mandatory = $true)][object] $DeploymentStrategy,
        [Parameter(Mandatory = $true)][object] $StrategyStep,
        [Parameter(Mandatory = $true)][string] $SelectedAdapterId,
        [AllowNull()][object] $PackagingPolicy
    )

    $arguments = @([string] $StrategyStep.operationType)
    if ($StrategyStep.operationType -eq 'archive-create') {
        $arguments += $SelectedAdapterId
    }
    $operation = New-AutomationOperationData -ExecutionPlan $ExecutionPlan -DeploymentStrategy $DeploymentStrategy -StrategyStep $StrategyStep -PackagingPolicy $PackagingPolicy
    return New-CommandPlanEntry -StrategyStep $StrategyStep -Program 'local-operation' -Arguments $arguments -RenderedCommand '' -Title ([string] $StrategyStep.stepId) -Description 'Structured local operation for later executor support.' -Copyable $false -Operation $operation
}

function Resolve-CommandPlanDependencyIds {
    param(
        [string[]] $DependsOn = @(),
        [Parameter(Mandatory = $true)][hashtable] $StrategyStepsById,
        [Parameter(Mandatory = $true)][hashtable] $EmittedIds,
        [string[]] $Stack = @()
    )

    $resolved = New-Object System.Collections.Generic.List[string]
    foreach ($dependency in @($DependsOn)) {
        $dependencyId = [string] $dependency
        if ([string]::IsNullOrWhiteSpace($dependencyId)) { continue }
        if ($EmittedIds.ContainsKey($dependencyId)) {
            $resolved.Add($dependencyId)
            continue
        }
        if (-not $StrategyStepsById.ContainsKey($dependencyId)) { continue }
        if ($dependencyId -in $Stack) {
            throw "Command plan dependency normalization failed: cyclic strategy dependency '$dependencyId'."
        }
        foreach ($expanded in @(Resolve-CommandPlanDependencyIds -DependsOn @($StrategyStepsById[$dependencyId].dependsOn) -StrategyStepsById $StrategyStepsById -EmittedIds $EmittedIds -Stack @($Stack + $dependencyId))) {
            $resolved.Add([string] $expanded)
        }
    }

    return @($resolved.ToArray() | Sort-Object -Unique)
}

function Set-CommandPlanNormalizedDependencies {
    param(
        [Parameter(Mandatory = $true)][object[]] $Commands,
        [Parameter(Mandatory = $true)][object[]] $HumanGates,
        [Parameter(Mandatory = $true)][object] $DeploymentStrategy
    )

    $strategyStepsById = @{}
    foreach ($step in @($DeploymentStrategy.steps)) { $strategyStepsById[[string] $step.stepId] = $step }
    $emittedIds = @{}
    foreach ($command in @($Commands)) { $emittedIds[[string] $command.commandId] = $true }
    foreach ($gate in @($HumanGates)) { $emittedIds[[string] $gate.gateId] = $true }

    foreach ($command in @($Commands)) {
        $command.dependsOn = @(Resolve-CommandPlanDependencyIds -DependsOn @($command.dependsOn) -StrategyStepsById $strategyStepsById -EmittedIds $emittedIds)
    }
    foreach ($gate in @($HumanGates)) {
        $gate.dependsOn = @(Resolve-CommandPlanDependencyIds -DependsOn @($gate.dependsOn) -StrategyStepsById $strategyStepsById -EmittedIds $emittedIds)
    }
}

function Resolve-CommandPlanHumanGates {
    param([Parameter(Mandatory = $true)][object] $DeploymentStrategy)

    foreach ($gate in @($DeploymentStrategy.humanGates)) {
        $gateCopy = $gate | ConvertTo-Json -Depth 30 | ConvertFrom-Json
        $strategyStep = @($DeploymentStrategy.steps | Where-Object { $_.stepId -eq [string] $gateCopy.stepId } | Select-Object -First 1)[0]
        Add-Member -InputObject $gateCopy -MemberType NoteProperty -Name 'sequence' -Value ([int] $strategyStep.sequence) -Force
        Add-Member -InputObject $gateCopy -MemberType NoteProperty -Name 'dependsOn' -Value @($strategyStep.dependsOn | ForEach-Object { [string] $_ } | Sort-Object -Unique) -Force
        $gateCopy
    }
}

function Resolve-CommandPlan {
    param(
        [Parameter(Mandatory = $true)][object] $ExecutionPlan,
        [Parameter(Mandatory = $true)][object] $DeploymentStrategy,
        [AllowNull()][object] $RuntimeArtifact,
        [AllowNull()][object] $PackagingPolicy
    )

    Assert-ResolvedExecutionPlanForCommandGeneration -ExecutionPlan $ExecutionPlan
    Assert-DeploymentStrategyForCommandGeneration -DeploymentStrategy $DeploymentStrategy
    if ($null -ne $PackagingPolicy) {
        Assert-PackagingPolicyForCommandGeneration -PackagingPolicy $PackagingPolicy -ExecutionPlan $ExecutionPlan
    }

    $commands = New-Object System.Collections.Generic.List[object]
    foreach ($step in @($DeploymentStrategy.steps | Sort-Object sequence, stepId)) {
        if (-not [bool] $step.commandGenerationRequired) {
            continue
        }
        if ($step.actor -eq 'automation') {
            $commands.Add((New-AutomationCommandEntry -ExecutionPlan $ExecutionPlan -DeploymentStrategy $DeploymentStrategy -StrategyStep $step -SelectedAdapterId ([string] $DeploymentStrategy.selectedAdapterId) -PackagingPolicy $PackagingPolicy))
        } elseif ($step.actor -eq 'human-command') {
            $commands.Add((New-HumanCommandEntry -ExecutionPlan $ExecutionPlan -DeploymentStrategy $DeploymentStrategy -StrategyStep $step -RuntimeArtifact $RuntimeArtifact))
        }
    }
    $humanGates = @(Resolve-CommandPlanHumanGates -DeploymentStrategy $DeploymentStrategy)
    Set-CommandPlanNormalizedDependencies -Commands @($commands.ToArray()) -HumanGates @($humanGates) -DeploymentStrategy $DeploymentStrategy

    $status = if (@($commands | Where-Object { [string]::IsNullOrWhiteSpace([string] $_.renderedCommand) -and $_.actor -eq 'human-command' }).Count -gt 0) {
        'incomplete'
    } else {
        'ready'
    }

    return [pscustomobject]@{
        schemaVersion = '0.1'
        commandPlanType = 'deployment-command-plan'
        status = $status
        sourceStrategyType = 'deployment'
        selectedAdapterId = [string] $DeploymentStrategy.selectedAdapterId
        executionPlanFingerprint = if (Test-CommandPlanProperty -Object $ExecutionPlan -Name 'executionPlanFingerprint') { [string] $ExecutionPlan.executionPlanFingerprint } else { '' }
        executionPolicy = [pscustomobject]@{
            executionAllowed = $false
            automaticExecutionAllowed = $false
            remoteExecutionMode = 'copy-and-run'
        }
        commands = @($commands | Sort-Object sequence, commandId)
        humanGates = @($humanGates | Sort-Object sequence, gateId)
        diagnostic = if ($status -eq 'ready') { 'Command plan is ready for manual review and copy-and-run handling.' } else { 'Command plan is incomplete because required target or artifact information is missing.' }
    }
}

function Write-CommandPlanJson {
    param(
        [Parameter(Mandatory = $true)][object] $CommandPlan,
        [string] $OutputPath
    )

    $json = $CommandPlan | ConvertTo-Json -Depth 50
    if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
        $resolvedOutputPath = Resolve-CommandPlanPath -Path $OutputPath
        $outputDirectory = Split-Path -Path $resolvedOutputPath -Parent
        if (-not [string]::IsNullOrWhiteSpace($outputDirectory)) {
            New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
        }
        $json | Set-Content -LiteralPath $resolvedOutputPath -Encoding utf8
    }

    return $json
}

function Invoke-CommandPlanBuilder {
    param(
        [Parameter(Mandatory = $true)][string] $ExecutionPlanPath,
        [Parameter(Mandatory = $true)][string] $DeploymentStrategyPath,
        [string] $RuntimeArtifactPath,
        [string] $PackagingPolicyPath,
        [string] $DeploymentRunId,
        [string] $OutputPath,
        [string] $Format = 'Json'
    )

    if ($Format -ne 'Json') {
        throw "generate-commands only supports -Format Json."
    }

    $executionPlan = Read-CommandPlanJsonFile -Path $ExecutionPlanPath -Description 'Resolved execution plan'
    $deploymentStrategy = Read-CommandPlanJsonFile -Path $DeploymentStrategyPath -Description 'Deployment strategy'
    if (-not [string]::IsNullOrWhiteSpace($DeploymentRunId)) {
        if (-not (Test-CommandPlanProperty -Object $deploymentStrategy -Name 'commandInputs') -or -not (Test-CommandPlanObjectLike -Value $deploymentStrategy.commandInputs)) {
            Add-Member -InputObject $deploymentStrategy -MemberType NoteProperty -Name 'commandInputs' -Value ([pscustomobject]@{})
        }
        Add-Member -InputObject $deploymentStrategy.commandInputs -MemberType NoteProperty -Name 'deploymentRunId' -Value $DeploymentRunId -Force
    }
    $runtimeArtifact = Read-OptionalRuntimeArtifact -Path $RuntimeArtifactPath
    $packagingPolicy = Read-OptionalPackagingPolicy -Path $PackagingPolicyPath
    if ($null -ne $runtimeArtifact) {
        Assert-RuntimeArtifactForCommandGeneration -RuntimeArtifact $runtimeArtifact -ExecutionPlan $executionPlan
    }
    $commandPlan = Resolve-CommandPlan -ExecutionPlan $executionPlan -DeploymentStrategy $deploymentStrategy -RuntimeArtifact $runtimeArtifact -PackagingPolicy $packagingPolicy
    return Write-CommandPlanJson -CommandPlan $commandPlan -OutputPath $OutputPath
}

if ($MyInvocation.InvocationName -ne '.') {
    if ([string]::IsNullOrWhiteSpace($ExecutionPlanPath)) {
        throw "Missing required parameter for 'generate-commands': -ExecutionPlanPath"
    }
    if ([string]::IsNullOrWhiteSpace($DeploymentStrategyPath)) {
        throw "Missing required parameter for 'generate-commands': -DeploymentStrategyPath"
    }
    Invoke-CommandPlanBuilder -ExecutionPlanPath $ExecutionPlanPath -DeploymentStrategyPath $DeploymentStrategyPath -RuntimeArtifactPath $RuntimeArtifactPath -PackagingPolicyPath $PackagingPolicyPath -DeploymentRunId $DeploymentRunId -OutputPath $OutputPath -Format $Format
}
