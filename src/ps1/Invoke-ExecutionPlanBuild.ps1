[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $AnalysisPath,

    [Parameter(Mandatory = $true)]
    [string] $ProjectManifestPath,

    [string] $TargetPath,

    [ValidateSet('Text', 'Json')]
    [string] $Format = 'Text',

    [string] $OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$executionPlanSchemaVersion = '0.1'
$supportedAnalysisVersions = @('0.1')

. (Join-Path -Path $PSScriptRoot -ChildPath 'Resolve-DeploymentCapabilities.ps1')

function Get-ExecutionPlanFingerprint {
    param([Parameter(Mandatory = $true)][object] $Plan)

    $copy = $Plan | ConvertTo-Json -Depth 60 | ConvertFrom-Json
    if (Test-PropertyValue -Object $copy -Name 'executionPlanFingerprint') {
        $copy.PSObject.Properties.Remove('executionPlanFingerprint')
    }

    $bytes = [System.Text.Encoding]::UTF8.GetBytes(($copy | ConvertTo-Json -Depth 60 -Compress))
    $hash = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($hash.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    } finally {
        $hash.Dispose()
    }
}

function Add-ExecutionPlanFingerprint {
    param([Parameter(Mandatory = $true)][object] $Plan)

    $fingerprint = Get-ExecutionPlanFingerprint -Plan $Plan
    if (Test-PropertyValue -Object $Plan -Name 'executionPlanFingerprint') {
        $Plan.executionPlanFingerprint = $fingerprint
    } else {
        Add-Member -InputObject $Plan -MemberType NoteProperty -Name 'executionPlanFingerprint' -Value $fingerprint
    }

    return $Plan
}

function Resolve-LocalPath {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,

        [string] $BasePath
    )

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    if ([string]::IsNullOrWhiteSpace($BasePath)) {
        $BasePath = (Get-Location).Path
    }

    return [System.IO.Path]::GetFullPath((Join-Path -Path $BasePath -ChildPath $Path))
}

function Read-JsonFile {
    param([Parameter(Mandatory = $true)][string] $Path)

    $resolved = Resolve-LocalPath -Path $Path
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
        throw "JSON file not found: $resolved"
    }

    try {
        return [pscustomobject]@{
            path = $resolved
            value = Get-Content -LiteralPath $resolved -Raw | ConvertFrom-Json
        }
    } catch {
        throw "Invalid JSON in '$resolved': $($_.Exception.Message)"
    }
}

function Assert-RequiredValue {
    param(
        [Parameter(Mandatory = $true)]
        [object] $Object,

        [Parameter(Mandatory = $true)]
        [string] $Path,

        [Parameter(Mandatory = $true)]
        [string] $SourceName
    )

    $current = $Object
    foreach ($part in $Path.Split('.')) {
        if ($null -eq $current -or -not ($current.PSObject.Properties.Name -contains $part)) {
            throw "$SourceName validation failed: missing required field '$Path'."
        }
        $current = $current.$part
    }

    if ($null -eq $current -or ([string] $current).Trim().Length -eq 0) {
        throw "$SourceName validation failed: required field '$Path' is empty."
    }
}

function Get-StringArray {
    param($Value)

    if ($null -eq $Value) {
        return @()
    }

    $items = New-Object System.Collections.Generic.List[string]
    foreach ($item in @($Value)) {
        if ($null -ne $item) {
            $items.Add([string] $item)
        }
    }

    return $items.ToArray()
}

function ConvertTo-Array {
    param($Value)

    if ($null -eq $Value) {
        return ,@()
    }

    return ,@($Value)
}

function Get-ItemCount {
    param($Value)

    if ($null -eq $Value) {
        return 0
    }

    return @($Value).Count
}

function Test-PropertyValue {
    param(
        [object] $Object,
        [Parameter(Mandatory = $true)]
        [string] $Name
    )

    return ($null -ne $Object -and $Object.PSObject.Properties.Name -contains $Name -and $null -ne $Object.$Name)
}

function ConvertTo-Bool {
    param(
        [object] $Value,
        [string] $Name
    )

    if ($Value -is [bool]) {
        return $Value
    }

    throw "Analysis validation failed: decision '$Name' must be boolean."
}

function Join-DeploymentPath {
    param(
        [Parameter(Mandatory = $true)][string] $Root,
        [string] $Child
    )

    $normalizedRoot = ($Root -replace '\\', '/').TrimEnd('/')
    if ([string]::IsNullOrWhiteSpace($Child)) {
        return $normalizedRoot
    }

    $normalizedChild = ($Child -replace '\\', '/').Trim('/')
    if ([string]::IsNullOrWhiteSpace($normalizedChild)) {
        return $normalizedRoot
    }

    return "$normalizedRoot/$normalizedChild"
}

function Test-AbsolutePosixPath {
    param([string] $Path)

    return (-not [string]::IsNullOrWhiteSpace($Path) -and $Path.StartsWith('/') -and -not ($Path -match '\\') -and -not ($Path -match '//'))
}

function Get-PosixPathSegments {
    param([Parameter(Mandatory = $true)][string] $Path)

    return @($Path.Split('/') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Assert-RelativePosixPath {
    param(
        [string] $Path,
        [Parameter(Mandatory = $true)][string] $Context
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "$Context validation failed: path must not be empty."
    }
    $normalized = $Path -replace '\\', '/'
    if ($normalized.StartsWith('/')) {
        throw "$Context validation failed: path must be relative."
    }
    if ($normalized -match '//') {
        throw "$Context validation failed: path must not contain empty segments."
    }
    foreach ($segment in (Get-PosixPathSegments -Path $normalized)) {
        if ($segment -eq '.' -or $segment -eq '..') {
            throw "$Context validation failed: path must not contain '.' or '..' segments."
        }
    }
}

function Normalize-RelativePosixPath {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Context
    )

    Assert-RelativePosixPath -Path $Path -Context $Context
    return (($Path -replace '\\', '/').Trim('/'))
}

function Test-RemotePathInside {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Root
    )

    $normalizedPath = ($Path -replace '\\', '/').TrimEnd('/')
    $normalizedRoot = ($Root -replace '\\', '/').TrimEnd('/')
    return ($normalizedPath -eq $normalizedRoot -or $normalizedPath.StartsWith("$normalizedRoot/"))
}

function Test-RelativePathOverlaps {
    param(
        [Parameter(Mandatory = $true)][string] $Left,
        [Parameter(Mandatory = $true)][string] $Right
    )

    $normalizedLeft = $Left.Trim('/')
    $normalizedRight = $Right.Trim('/')
    return ($normalizedLeft -eq $normalizedRight -or $normalizedLeft.StartsWith("$normalizedRight/") -or $normalizedRight.StartsWith("$normalizedLeft/"))
}

function Normalize-AbsoluteRemoteRoot {
    param(
        [string] $Path,
        [Parameter(Mandatory = $true)][string] $Context
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "$Context validation failed: remoteRoot must not be empty."
    }
    $normalized = ($Path -replace '\\', '/').TrimEnd('/')
    if (-not (Test-AbsolutePosixPath -Path $normalized)) {
        throw "$Context validation failed: remoteRoot must be an absolute POSIX path."
    }
    foreach ($segment in (Get-PosixPathSegments -Path $normalized)) {
        if ($segment -eq '.' -or $segment -eq '..') {
            throw "$Context validation failed: remoteRoot must not contain '.' or '..' segments."
        }
    }
    return $normalized
}

function Resolve-SharedStorageContract {
    param(
        [Parameter(Mandatory = $true)][object] $Manifest,
        [Parameter(Mandatory = $true)][object] $RemoteTarget
    )

    if (-not (Test-PropertyValue -Object $Manifest -Name 'sharedStorage')) {
        return [pscustomobject]@{
            configurationPresent = $false
            rootResolved = $false
            root = ''
            sharedRootAbsolutePath = ''
            directories = @()
            files = @()
            diagnostics = @('shared-storage-configuration-missing')
        }
    }

    $contract = $Manifest.sharedStorage
    Assert-RequiredValue -Object $contract -Path 'root' -SourceName 'Shared storage'
    if (-not (Test-PropertyValue -Object $contract -Name 'directories') -or $null -eq $contract.directories) {
        throw "Shared storage validation failed: missing required field 'directories'."
    }
    if (-not (Test-PropertyValue -Object $contract -Name 'files') -or $null -eq $contract.files) {
        throw "Shared storage validation failed: missing required field 'files'."
    }

    $applicationRemoteDirectory = [string] $RemoteTarget.applicationRemoteDirectory
    $workspaceRoots = @('.deployment', '.deployment/uploads', '.deployment/work', '.deployment/releases', '.deployment/metadata')
    $root = Normalize-RelativePosixPath -Path ([string] $contract.root) -Context 'Shared storage root'
    foreach ($workspaceRoot in $workspaceRoots) {
        if (Test-RelativePathOverlaps -Left $root -Right $workspaceRoot) {
            throw "Shared storage validation failed: root must not overlap deployment workspace path '$workspaceRoot'."
        }
    }

    $sharedRootAbsolutePath = Join-DeploymentPath -Root $applicationRemoteDirectory -Child $root
    if (-not (Test-RemotePathInside -Path $sharedRootAbsolutePath -Root $applicationRemoteDirectory)) {
        throw 'Shared storage validation failed: resolved root escapes applicationRemoteDirectory.'
    }

    $releaseLinks = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    $sharedTargets = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    $releaseLinkList = New-Object System.Collections.Generic.List[string]
    $sharedTargetList = New-Object System.Collections.Generic.List[string]
    $entries = New-Object System.Collections.Generic.List[object]

    foreach ($collectionInfo in @(
        [pscustomobject]@{ value = $contract.directories; expectedKind = 'directory'; label = 'directories' },
        [pscustomobject]@{ value = $contract.files; expectedKind = 'file'; label = 'files' }
    )) {
        foreach ($entry in @($collectionInfo.value)) {
            if ($null -eq $entry) {
                throw "Shared storage validation failed: entry in '$($collectionInfo.label)' must not be null."
            }
            foreach ($field in @('sharedPath', 'releaseLinkPath', 'pathKind', 'conflictPolicy', 'initializationPolicy')) {
                Assert-RequiredValue -Object $entry -Path $field -SourceName 'Shared storage entry'
            }

            $pathKind = [string] $entry.pathKind
            if ($pathKind -notin @('directory', 'file')) {
                throw "Shared storage validation failed: unsupported pathKind '$pathKind'."
            }
            if ($pathKind -ne [string] $collectionInfo.expectedKind) {
                throw "Shared storage validation failed: entry in '$($collectionInfo.label)' must use pathKind '$($collectionInfo.expectedKind)'."
            }
            if ([string] $entry.conflictPolicy -ne 'fail') {
                throw "Shared storage validation failed: unsupported conflictPolicy '$($entry.conflictPolicy)'."
            }
            if ([string] $entry.initializationPolicy -ne 'explicit') {
                throw "Shared storage validation failed: unsupported initializationPolicy '$($entry.initializationPolicy)'."
            }

            $sharedPath = Normalize-RelativePosixPath -Path ([string] $entry.sharedPath) -Context 'Shared storage sharedPath'
            $releaseLinkPath = Normalize-RelativePosixPath -Path ([string] $entry.releaseLinkPath) -Context 'Shared storage releaseLinkPath'
            foreach ($workspaceRoot in $workspaceRoots) {
                if ((Test-RelativePathOverlaps -Left $releaseLinkPath -Right $workspaceRoot) -or (Test-RelativePathOverlaps -Left $sharedPath -Right $workspaceRoot)) {
                    throw "Shared storage validation failed: shared entry must not overlap deployment workspace path '$workspaceRoot'."
                }
            }
            if (-not $releaseLinks.Add($releaseLinkPath)) {
                throw "Shared storage validation failed: duplicate releaseLinkPath '$releaseLinkPath'."
            }
            if (-not $sharedTargets.Add($sharedPath)) {
                throw "Shared storage validation failed: duplicate sharedPath '$sharedPath'."
            }
            foreach ($existingReleaseLink in @($releaseLinkList)) {
                if (Test-RelativePathOverlaps -Left $releaseLinkPath -Right $existingReleaseLink) {
                    throw "Shared storage validation failed: overlapping releaseLinkPath '$releaseLinkPath'."
                }
            }
            foreach ($existingSharedTarget in @($sharedTargetList)) {
                if (Test-RelativePathOverlaps -Left $sharedPath -Right $existingSharedTarget) {
                    throw "Shared storage validation failed: overlapping sharedPath '$sharedPath'."
                }
            }
            $releaseLinkList.Add($releaseLinkPath)
            $sharedTargetList.Add($sharedPath)

            $sharedAbsolutePath = Join-DeploymentPath -Root $sharedRootAbsolutePath -Child $sharedPath
            $releaseLinkAbsolutePath = Join-DeploymentPath -Root ([string] $RemoteTarget.applicationRemoteDirectory) -Child $releaseLinkPath
            if (-not (Test-RemotePathInside -Path $sharedAbsolutePath -Root $sharedRootAbsolutePath)) {
                throw "Shared storage validation failed: shared target '$sharedPath' escapes shared root."
            }
            if (-not (Test-RemotePathInside -Path $releaseLinkAbsolutePath -Root ([string] $RemoteTarget.applicationRemoteDirectory)) -or (Test-RemotePathInside -Path $releaseLinkAbsolutePath -Root $sharedRootAbsolutePath)) {
                throw "Shared storage validation failed: release link '$releaseLinkPath' must stay inside the release directory and outside shared root."
            }
            if ($sharedAbsolutePath.TrimEnd('/') -eq $releaseLinkAbsolutePath.TrimEnd('/')) {
                throw "Shared storage validation failed: shared target and release link must not resolve to the same path."
            }

            $entries.Add([pscustomobject]@{
                sharedPath = $sharedPath
                releaseLinkPath = $releaseLinkPath
                pathKind = $pathKind
                conflictPolicy = [string] $entry.conflictPolicy
                initializationPolicy = [string] $entry.initializationPolicy
                sharedRootRelativePath = $root
                sharedRootAbsolutePath = $sharedRootAbsolutePath
                sharedAbsolutePath = $sharedAbsolutePath
                releaseLinkAbsolutePath = $releaseLinkAbsolutePath
                writeBoundary = [pscustomobject]@{
                    allowedWriteTargets = @('shared-target-directory', 'missing-parents-inside-shared-root', 'release-link-path')
                    forbiddenTargets = @('existing-shared-data', 'other-shared-paths', 'other-release-paths', 'current-link', 'composer-files', 'database', 'configuration', 'secrets')
                }
            })
        }
    }

    if ($entries.Count -eq 0) {
        throw 'Shared storage validation failed: root requires at least one concrete shared entry.'
    }

    return [pscustomobject]@{
        configurationPresent = $true
        rootResolved = $true
        root = $root
        sharedRootAbsolutePath = $sharedRootAbsolutePath
        directories = @($entries | Where-Object { $_.pathKind -eq 'directory' })
        files = @($entries | Where-Object { $_.pathKind -eq 'file' })
        diagnostics = @()
    }
}

function Read-DeploymentTarget {
    param([string] $Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "Target configuration validation failed: -TargetPath is required for remote target resolution."
    }

    $targetResult = Read-JsonFile -Path $Path
    $target = $targetResult.value

    foreach ($requiredPath in @('schemaVersion', 'targetId', 'remoteRoot', 'applicationPath')) {
        Assert-RequiredValue -Object $target -Path $requiredPath -SourceName 'Target configuration'
    }
    if ($target.schemaVersion -ne '0.1') {
        throw "Target configuration validation failed: unsupported schemaVersion '$($target.schemaVersion)'."
    }
    $allowedFields = @('$schema', 'schemaVersion', 'targetId', 'remoteRoot', 'applicationPath')
    foreach ($property in @($target.PSObject.Properties)) {
        if ($property.Name -notin $allowedFields) {
            throw "Target configuration validation failed: field '$($property.Name)' is not allowed."
        }
    }
    foreach ($forbiddenField in @('host', 'hostname', 'user', 'username', 'password', 'token', 'secret')) {
        if (Test-PropertyValue -Object $target -Name $forbiddenField) {
            throw "Target configuration validation failed: field '$forbiddenField' is not allowed."
        }
    }

    return [pscustomobject]@{
        path = $targetResult.path
        value = $target
    }
}

function Resolve-RemoteTarget {
    param(
        [Parameter(Mandatory = $true)][object] $Manifest,
        [Parameter(Mandatory = $true)][object] $TargetConfiguration
    )

    $target = $TargetConfiguration.value
    $remoteRoot = Normalize-AbsoluteRemoteRoot -Path ([string] $target.remoteRoot) -Context 'Target configuration'
    $applicationPath = [string] $target.applicationPath
    Assert-RelativePosixPath -Path $applicationPath -Context 'Target configuration applicationPath'

    $applicationRemoteDirectory = Join-DeploymentPath -Root $remoteRoot -Child $applicationPath
    if (-not (Test-AbsolutePosixPath -Path $applicationRemoteDirectory)) {
        throw "Remote target resolution failed: applicationRemoteDirectory must be an absolute POSIX path."
    }
    if (-not ($applicationRemoteDirectory -eq $remoteRoot -or $applicationRemoteDirectory.StartsWith("$remoteRoot/"))) {
        throw "Remote target resolution failed: normalized application path escapes remoteRoot."
    }

    return [pscustomobject]@{
        schemaVersion = '0.1'
        targetId = [string] $target.targetId
        targetConfigurationPath = [string] $TargetConfiguration.path
        logicalServerRoot = [string] $Manifest.deployment.serverRoot
        remoteRoot = $remoteRoot
        applicationPath = $applicationPath
        applicationRemoteDirectory = $applicationRemoteDirectory
        resolution = 'remoteRoot-plus-applicationPath'
    }
}

function New-ValidationRule {
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

function New-ContinuationRule {
    param(
        [string[]] $AllowedStatuses = @('completed', 'skipped'),
        [bool] $blocksAutomaticContinuation = $false,
        [string] $requiredUserAction = ''
    )

    return [pscustomobject]@{
        allowedStatusesForDependents = @($AllowedStatuses)
        blocksAutomaticContinuation = $blocksAutomaticContinuation
        requiredUserAction = $requiredUserAction
    }
}

function New-ExecutionPlanStep {
    param(
        [Parameter(Mandatory = $true)][string] $Id,
        [Parameter(Mandatory = $true)][string] $Phase,
        [Parameter(Mandatory = $true)][string] $Title,
        [Parameter(Mandatory = $true)][ValidateSet('agent', 'human', 'review')][string] $ExecutionMode,
        [bool] $Required = $true,
        [Parameter(Mandatory = $true)][string] $Status,
        [Parameter(Mandatory = $true)][string] $Reason,
        [bool] $ApprovalRequired = $false,
        [bool] $Destructive = $false,
        [ValidateSet('low', 'normal', 'high')]
        [string] $RiskLevel = 'normal',
        [string] $CapabilityId = '',
        [string[]] $DependsOn = @(),
        [object] $Instructions,
        [object] $Validation,
        [object] $Continuation
    )

    if ($null -eq $Instructions) {
        $Instructions = [pscustomobject]@{}
    }
    if ($null -eq $Validation) {
        $Validation = New-ValidationRule
    }
    if ($null -eq $Continuation) {
        $Continuation = New-ContinuationRule
    }

    return [pscustomobject]@{
        id = $Id
        phase = $Phase
        title = $Title
        executionMode = $ExecutionMode
        required = $Required
        status = $Status
        reason = $Reason
        approvalRequired = $ApprovalRequired
        destructive = $Destructive
        riskLevel = $RiskLevel
        capabilityId = $CapabilityId
        dependsOn = @($DependsOn)
        instructions = $Instructions
        validation = $Validation
        continuation = $Continuation
    }
}

function New-CapabilityInstructions {
    param(
        [Parameter(Mandatory = $true)][object] $Manifest,
        [Parameter(Mandatory = $true)][object] $RemoteTarget,
        [Parameter(Mandatory = $true)][string] $CapabilityId,
        [string] $Purpose,
        [string] $ExpectedOutcome,
        [string] $WorkingDirectory,
        [string] $RequiredResponse = 'Vollstaendige relevante Konsolenausgabe'
    )

    if ([string]::IsNullOrWhiteSpace($WorkingDirectory)) {
        $WorkingDirectory = [string] $RemoteTarget.applicationRemoteDirectory
    }

    return [pscustomobject]@{
        environment = [string] $Manifest.deployment.environment
        channel = 'ssh'
        workingDirectory = $WorkingDirectory
        capabilityId = $CapabilityId
        purpose = $Purpose
        expectedOutcome = $ExpectedOutcome
        requiredResponse = $RequiredResponse
    }
}

function Get-BlockedOrWaitingStatus {
    param(
        [string[]] $BlockingDependencies,
        [Parameter(Mandatory = $true)][string] $WaitingStatus
    )

    if ((Get-ItemCount $BlockingDependencies) -gt 0) {
        return 'blocked'
    }

    return $WaitingStatus
}

function Get-DeletedRuntimePaths {
    param([Parameter(Mandatory = $true)][object] $Analysis)

    if (-not (Test-PropertyValue -Object $Analysis -Name 'classifications')) {
        return @()
    }

    return @(
        $Analysis.classifications |
            Where-Object { $_.status -eq 'D' -and $_.classes -notcontains 'ignored' } |
            ForEach-Object { [string] $_.path } |
            Sort-Object -Unique
    )
}

function Get-ProtectedPaths {
    param([Parameter(Mandatory = $true)][object] $Analysis)

    if (-not (Test-PropertyValue -Object $Analysis -Name 'classifications')) {
        return @()
    }

    return @(
        $Analysis.classifications |
            Where-Object { $_.classes -contains 'protected-server-file' -or $_.classes -contains 'protectedServerFile' } |
            ForEach-Object { [string] $_.path } |
            Sort-Object -Unique
    )
}

function Get-MigrationPaths {
    param([Parameter(Mandatory = $true)][object] $Analysis)

    if (-not (Test-PropertyValue -Object $Analysis -Name 'classifications')) {
        return @()
    }

    return @(
        $Analysis.classifications |
            Where-Object { $_.classes -contains 'migrations' } |
            ForEach-Object { [string] $_.path } |
            Sort-Object -Unique
    )
}

function Test-CommandReady {
    param([Parameter(Mandatory = $true)][object] $Instructions)

    @('environment', 'channel', 'workingDirectory', 'capabilityId', 'purpose', 'expectedOutcome', 'requiredResponse') | ForEach-Object {
        if (-not (Test-PropertyValue -Object $Instructions -Name $_) -or [string]::IsNullOrWhiteSpace([string] $Instructions.$_)) {
            return $false
        }
    }

    $text = @($Instructions.environment, $Instructions.channel, $Instructions.workingDirectory, $Instructions.capabilityId) -join ' '
    return -not ($text -match '<[^>]+>' -or $text -match '\{\{[^}]+\}\}' -or $text -match '\$\{[^}]+\}')
}

function Assert-AnalysisShape {
    param([Parameter(Mandatory = $true)][object] $Analysis)

    @(
        'engineVersion',
        'project.id',
        'environment.name',
        'environment.serverRoot',
        'decisions'
    ) | ForEach-Object { Assert-RequiredValue -Object $Analysis -Path $_ -SourceName 'Analysis' }

    if ($Analysis.engineVersion -notin $supportedAnalysisVersions) {
        throw "Unsupported analysis version '$($Analysis.engineVersion)'. Supported versions: $($supportedAnalysisVersions -join ', ')."
    }

    @(
        'runtimeDeploymentRequired',
        'frontendBuildRequired',
        'composerInstallRequired',
        'migrationsRequired',
        'environmentReviewRequired',
        'cleanupRequired',
        'protectedFileReviewRequired',
        'documentationOnly'
    ) | ForEach-Object {
        Assert-RequiredValue -Object $Analysis.decisions -Path $_ -SourceName 'Analysis'
        [void] (ConvertTo-Bool -Value $Analysis.decisions.$_ -Name $_)
    }
}

function Assert-ManifestShape {
    param([Parameter(Mandatory = $true)][object] $Manifest)

    @(
        'schemaVersion',
        'project.id',
        'project.name',
        'project.applicationRoot',
        'project.type',
        'deployment.environment',
        'deployment.serverRoot',
        'deployment.markerFile',
        'protection.neverUpload',
        'protection.neverOverwrite'
    ) | ForEach-Object { Assert-RequiredValue -Object $Manifest -Path $_ -SourceName 'Manifest' }
}

function New-ExecutionPlanContext {
    param(
        [Parameter(Mandatory = $true)][object] $Analysis,
        [Parameter(Mandatory = $true)][object] $Manifest,
        [Parameter(Mandatory = $true)][object] $RemoteTarget
    )

    $environmentChanges = if (Test-PropertyValue -Object $Analysis -Name 'environmentChanges') { $Analysis.environmentChanges } else { [pscustomobject]@{} }
    $seederReview = if (Test-PropertyValue -Object $Analysis -Name 'seederReview') { $Analysis.seederReview } else { [pscustomobject]@{ changed = $false; files = @(); summary = [pscustomobject]@{ total = 0; added = 0; modified = 0; deleted = 0; highRisk = 0; reviewRequired = $false } } }

    return [pscustomobject]@{
        analysis = $Analysis
        manifest = $Manifest
        decisions = $Analysis.decisions
        blockers = if (Test-PropertyValue -Object $Analysis -Name 'blockers') { @(Get-StringArray $Analysis.blockers) } else { @() }
        warnings = if (Test-PropertyValue -Object $Analysis -Name 'warnings') { @(Get-StringArray $Analysis.warnings) } else { @() }
        manualApprovalPoints = if (Test-PropertyValue -Object $Analysis -Name 'manualApprovalPoints') { @(Get-StringArray $Analysis.manualApprovalPoints) } else { @() }
        environmentChanges = $environmentChanges
        environmentChangePath = if (Test-PropertyValue -Object $environmentChanges -Name 'path') { $environmentChanges.path } else { 'laravel_app/.env.example' }
        environmentAddedKeys = if (Test-PropertyValue -Object $environmentChanges -Name 'addedKeys') { @($environmentChanges.addedKeys) } else { @() }
        environmentRemovedKeys = if (Test-PropertyValue -Object $environmentChanges -Name 'removedKeys') { @($environmentChanges.removedKeys) } else { @() }
        environmentKeyAssessments = if (Test-PropertyValue -Object $environmentChanges -Name 'keyAssessments') { @($environmentChanges.keyAssessments) } else { @() }
        environmentUnknownKeys = if (Test-PropertyValue -Object $environmentChanges -Name 'unknownKeys') { @($environmentChanges.unknownKeys) } else { @() }
        environmentContractIssues = if (Test-PropertyValue -Object $environmentChanges -Name 'contractIssues') { @($environmentChanges.contractIssues) } else { @() }
        seederReview = $seederReview
        seederReviewRequired = if (Test-PropertyValue -Object $Analysis.decisions -Name 'seederReviewRequired') { [bool] $Analysis.decisions.seederReviewRequired } else { [bool] $seederReview.changed }
        baselineCommit = if (Test-PropertyValue -Object $Analysis -Name 'baselineCommit') { [string] $Analysis.baselineCommit } else { '' }
        targetCommit = if (Test-PropertyValue -Object $Analysis -Name 'targetCommit') { [string] $Analysis.targetCommit } else { '' }
        remoteTarget = $RemoteTarget
        applicationRemoteDirectory = [string] $RemoteTarget.applicationRemoteDirectory
        sharedStorage = (Resolve-SharedStorageContract -Manifest $Manifest -RemoteTarget $RemoteTarget)
        runtimeDeletions = @(Get-DeletedRuntimePaths -Analysis $Analysis)
        protectedPaths = @(Get-ProtectedPaths -Analysis $Analysis)
        migrationPaths = @(Get-MigrationPaths -Analysis $Analysis)
        steps = New-Object System.Collections.Generic.List[object]
        gateIds = New-Object System.Collections.Generic.List[string]
        blocked = $false
    }
}

function Add-ExecutionPlanStep {
    param(
        [Parameter(Mandatory = $true)][object] $Context,
        [Parameter(Mandatory = $true)][object] $Step,
        [bool] $BlocksFollowingSteps = $false
    )

    $Context.steps.Add($Step)
    if ($BlocksFollowingSteps -and $Step.required) {
        $Context.gateIds.Add($Step.id)
    }
}

function BuildPreconditions {
    param([Parameter(Mandatory = $true)][object] $Context)

    $Context.blocked = (Get-ItemCount $Context.blockers) -gt 0
    $status = if ($Context.blocked) { 'blocked' } else { 'ready' }
    Add-ExecutionPlanStep -Context $Context -BlocksFollowingSteps:$Context.blocked -Step (New-ExecutionPlanStep `
        -Id 'preconditions.analysis-review' `
        -Phase 'preconditions' `
        -Title 'Analyseergebnis pruefen' `
        -ExecutionMode 'agent' `
        -Status $status `
        -Reason 'Das Analyzer-Ergebnis und das Projektmanifest muessen vor der Planung gueltig sein.' `
        -Instructions ([pscustomobject]@{
            purpose = 'Lokale, rein lesende Pruefung der Analyzer-Ausgabe und Manifestdaten.'
            blockedBy = @($Context.blockers)
            warnings = @($Context.warnings)
        }) `
        -Validation (New-ValidationRule -SuccessPatterns @('Analyzer result accepted') -FailurePatterns @('missing required field', 'Unsupported analysis version', 'Invalid JSON') -AmbiguousWithoutSuccessMatch $false) `
        -Continuation (New-ContinuationRule -blocksAutomaticContinuation:$Context.blocked -requiredUserAction 'Blocker muessen vor jeder Fortsetzung fachlich geklaert werden.'))
}

function BuildEnvironmentReview {
    param([Parameter(Mandatory = $true)][object] $Context)

    if ($Context.decisions.environmentReviewRequired) {
        Add-ExecutionPlanStep -Context $Context -BlocksFollowingSteps $true -Step (New-ExecutionPlanStep `
            -Id 'environment.review' `
            -Phase 'environment-review' `
            -Title 'Environment-Aenderungen pruefen' `
            -ExecutionMode 'review' `
            -Status 'waiting-for-review' `
            -Reason 'Der Analyzer hat Aenderungen am Environment-Vertrag erkannt.' `
            -ApprovalRequired $true `
            -DependsOn @('preconditions.analysis-review') `
            -Instructions ([pscustomobject]@{
                reviewSubject = 'Zielsystem-.env gegen geaenderte .env.example pruefen.'
                environment = [string] $Context.manifest.deployment.environment
                displayedInformation = [pscustomobject]@{
                    path = $Context.environmentChangePath
                    addedKeys = @($Context.environmentAddedKeys)
                    removedKeys = @($Context.environmentRemovedKeys)
                    keyAssessments = @($Context.environmentKeyAssessments)
                    unknownKeys = @($Context.environmentUnknownKeys)
                    contractIssues = @($Context.environmentContractIssues)
                }
                requiredResponse = 'Ausdrueckliche fachliche Freigabe inklusive Bewertung der angezeigten Environment-Aenderungen.'
            }) `
            -Validation (New-ValidationRule -RequiredResponse 'Explizite Review-Freigabe; reine Laufmeldung reicht nicht aus.') `
            -Continuation (New-ContinuationRule -blocksAutomaticContinuation $true -requiredUserAction 'Der Prozess wartet auf ausdrueckliche Environment-Freigabe.'))
    } else {
        Add-ExecutionPlanStep -Context $Context -Step (New-ExecutionPlanStep -Id 'environment.review' -Phase 'environment-review' -Title 'Environment-Aenderungen pruefen' -ExecutionMode 'review' -Required $false -Status 'skipped' -Reason 'Der Analyzer hat keine Environment-Aenderungen erkannt.')
    }

    if ($Context.decisions.protectedFileReviewRequired) {
        Add-ExecutionPlanStep -Context $Context -BlocksFollowingSteps $true -Step (New-ExecutionPlanStep `
            -Id 'environment.protected-files-review' `
            -Phase 'environment-review' `
            -Title 'Geschuetzte Serverdateien pruefen' `
            -ExecutionMode 'review' `
            -Status 'waiting-for-review' `
            -Reason 'Mindestens eine geschuetzte Datei ist betroffen und darf nicht automatisch ueberschrieben werden.' `
            -ApprovalRequired $true `
            -DependsOn @('preconditions.analysis-review') `
            -Instructions ([pscustomobject]@{
                reviewSubject = 'Auswirkungen auf geschuetzte Zielsystemdateien pruefen.'
                affectedPaths = @($Context.protectedPaths)
                requiredResponse = 'Explizite Freigabe oder Ablehnung fuer jede betroffene geschuetzte Datei.'
            }) `
            -Validation (New-ValidationRule -RequiredResponse 'Explizite Review-Freigabe je betroffener Datei.') `
            -Continuation (New-ContinuationRule -blocksAutomaticContinuation $true -requiredUserAction 'Der Prozess wartet auf Review der geschuetzten Dateien.'))
    } else {
        Add-ExecutionPlanStep -Context $Context -Step (New-ExecutionPlanStep -Id 'environment.protected-files-review' -Phase 'environment-review' -Title 'Geschuetzte Serverdateien pruefen' -ExecutionMode 'review' -Required $false -Status 'skipped' -Reason 'Der Analyzer hat keine betroffenen geschuetzten Dateien erkannt.')
    }
}

function BuildSeederReviewPlan {
    param([Parameter(Mandatory = $true)][object] $Context)

    if ($Context.seederReviewRequired) {
        $status = Get-BlockedOrWaitingStatus -BlockingDependencies $Context.gateIds.ToArray() -WaitingStatus 'waiting-for-review'
        Add-ExecutionPlanStep -Context $Context -BlocksFollowingSteps $true -Step (New-ExecutionPlanStep `
            -Id 'database.seeders.review' `
            -Phase 'database-review' `
            -Title 'Geaenderte Seeder statisch pruefen' `
            -ExecutionMode 'review' `
            -Status $status `
            -Reason 'Seeder wurden geaendert und duerfen nicht automatisch ausgefuehrt werden.' `
            -ApprovalRequired $true `
            -RiskLevel $(if ($Context.seederReview.summary.highRisk -gt 0) { 'high' } else { 'normal' }) `
            -DependsOn @($Context.gateIds) `
            -Instructions ([pscustomobject]@{
                reviewSubject = 'Statische Seeder-Bewertung ohne Datenbankzugriff pruefen.'
                automaticExecutionAllowed = $false
                changedSeeders = @($Context.seederReview.files)
                summary = $Context.seederReview.summary
                forbiddenCommands = @('php artisan db:seed', 'php artisan db:seed --force', 'php artisan migrate --seed')
                requiredResponse = 'Fachliche Bewertung der geaenderten Seeder. Keine automatische Ausfuehrung.'
            }) `
            -Validation (New-ValidationRule -RequiredResponse 'Explizite Seeder-Review-Freigabe; keine Ausfuehrung.') `
            -Continuation (New-ContinuationRule -blocksAutomaticContinuation $true -requiredUserAction 'Der Prozess wartet auf fachliche Seeder-Bewertung.'))
    } else {
        Add-ExecutionPlanStep -Context $Context -Step (New-ExecutionPlanStep -Id 'database.seeders.review' -Phase 'database-review' -Title 'Geaenderte Seeder statisch pruefen' -ExecutionMode 'review' -Required $false -Status 'skipped' -Reason 'Der Analyzer hat keine geaenderten Seeder erkannt.')
    }
}

function BuildFrontendPlan {
    param([Parameter(Mandatory = $true)][object] $Context)

    if ($Context.decisions.frontendBuildRequired) {
        Add-ExecutionPlanStep -Context $Context -Step (New-ExecutionPlanStep `
            -Id 'local.frontend-build.prepare' `
            -Phase 'local-frontend-build' `
            -Title 'Lokalen Frontend-Build vorbereiten' `
            -ExecutionMode 'agent' `
            -Status $(if ((Get-ItemCount $Context.gateIds) -gt 0) { 'blocked' } else { 'ready' }) `
            -Reason 'Frontend-Quellen oder Frontend-Abhaengigkeiten haben sich geaendert.' `
            -DependsOn @($Context.gateIds) `
            -Instructions ([pscustomobject]@{
                purpose = 'Lokale Build-Voraussetzungen und Build-Artefakte pruefen; kein Remote-Befehl.'
                expectedOutcome = 'Ein konsistenter lokaler Vite-Build kann vorbereitet werden.'
            }))
    } else {
        Add-ExecutionPlanStep -Context $Context -Step (New-ExecutionPlanStep -Id 'local.frontend-build.prepare' -Phase 'local-frontend-build' -Title 'Lokalen Frontend-Build vorbereiten' -ExecutionMode 'agent' -Required $false -Status 'skipped' -Reason 'Der Analyzer hat keinen Frontend-Build-Bedarf erkannt.')
    }
}

function BuildLocalPreparationPlan {
    param([Parameter(Mandatory = $true)][object] $Context)

    if ($Context.decisions.runtimeDeploymentRequired -and -not $Context.decisions.documentationOnly) {
        Add-ExecutionPlanStep -Context $Context -Step (New-ExecutionPlanStep `
            -Id 'local.deployment-package.prepare' `
            -Phase 'local-deployment-preparation' `
            -Title 'Lokale Deployment-Vorbereitung modellieren' `
            -ExecutionMode 'agent' `
            -Status $(if ((Get-ItemCount $Context.gateIds) -gt 0) { 'blocked' } else { 'ready' }) `
            -Reason 'Runtime-relevante Artefakte muessen geordnet fuer ein spaeteres Deployment vorbereitet werden.' `
            -DependsOn @($Context.gateIds) `
            -Instructions ([pscustomobject]@{
                purpose = 'Spaetere lokale Paket- oder Pruefsummenbildung vorbereiten; keine Dateiuebertragung.'
                excludedPatterns = @($Context.manifest.protection.neverUpload)
            }))
    } else {
        Add-ExecutionPlanStep -Context $Context -Step (New-ExecutionPlanStep -Id 'local.deployment-package.prepare' -Phase 'local-deployment-preparation' -Title 'Lokale Deployment-Vorbereitung modellieren' -ExecutionMode 'agent' -Required $false -Status 'skipped' -Reason 'Kein Runtime-Deployment erforderlich.')
    }
}

function BuildTransferPlan {
    param([Parameter(Mandatory = $true)][object] $Context)

    if ($Context.decisions.runtimeDeploymentRequired -and -not $Context.decisions.documentationOnly) {
        $dependsOn = @($Context.gateIds + @('local.deployment-package.prepare') | Select-Object -Unique)
        $status = Get-BlockedOrWaitingStatus -BlockingDependencies $Context.gateIds.ToArray() -WaitingStatus 'waiting-for-review'
        Add-ExecutionPlanStep -Context $Context -BlocksFollowingSteps $true -Step (New-ExecutionPlanStep `
            -Id 'runtime.transfer.review' `
            -Phase 'runtime-file-transfer' `
            -Title 'Dateiuebertragung fachlich freigeben' `
            -ExecutionMode 'review' `
            -Status $status `
            -Reason 'Dateiuebertragung ist produktiv wirksam und wird in diesem Auftrag nicht ausgefuehrt.' `
            -ApprovalRequired $true `
            -DependsOn $dependsOn `
            -Instructions ([pscustomobject]@{
                reviewSubject = 'Spaeteren Uebertragungsumfang gegen Schutzregeln und Zielpfad pruefen.'
                environment = [string] $Context.manifest.deployment.environment
                targetRoot = [string] $Context.manifest.deployment.serverRoot
                requiredResponse = 'Explizite Freigabe des spaeteren Uebertragungsplans mit Zielpfad und Umfang.'
            }) `
            -Validation (New-ValidationRule -RequiredResponse 'Explizite Review-Freigabe des Uebertragungsplans.') `
            -Continuation (New-ContinuationRule -blocksAutomaticContinuation $true -requiredUserAction 'Der Prozess wartet auf Freigabe des Uebertragungsplans.'))
    } else {
        Add-ExecutionPlanStep -Context $Context -Step (New-ExecutionPlanStep -Id 'runtime.transfer.review' -Phase 'runtime-file-transfer' -Title 'Dateiuebertragung fachlich freigeben' -ExecutionMode 'review' -Required $false -Status 'skipped' -Reason 'Keine Runtime-Dateiuebertragung erforderlich.')
    }
}

function BuildCleanupPlan {
    param([Parameter(Mandatory = $true)][object] $Context)

    if ($Context.decisions.cleanupRequired) {
        $status = Get-BlockedOrWaitingStatus -BlockingDependencies $Context.gateIds.ToArray() -WaitingStatus 'waiting-for-review'
        Add-ExecutionPlanStep -Context $Context -BlocksFollowingSteps $true -Step (New-ExecutionPlanStep `
            -Id 'runtime.cleanup.review' `
            -Phase 'runtime-cleanup' `
            -Title 'Kontrollierten Runtime-Cleanup freigeben' `
            -ExecutionMode 'review' `
            -Status $status `
            -Reason 'Der Analyzer hat geloeschte Runtime-Pfade erkannt.' `
            -ApprovalRequired $true `
            -Destructive $true `
            -DependsOn @($Context.gateIds) `
            -Instructions ([pscustomobject]@{
                reviewSubject = 'Jeden zu entfernenden Runtime-Pfad einzeln pruefen; keine generische rekursive Loeschung.'
                affectedPaths = @($Context.runtimeDeletions)
                forbiddenCommandShapes = @('rm -rf *', 'Remove-Item -Recurse ohne explizite LiteralPath-Liste')
                requiredResponse = 'Explizite destruktive Freigabe inklusive konkret bestaetigter Pfadliste.'
            }) `
            -Validation (New-ValidationRule -RequiredResponse 'Explizite destruktive Freigabe je Pfad; reine Bestaetigung reicht nicht.') `
            -Continuation (New-ContinuationRule -blocksAutomaticContinuation $true -requiredUserAction 'Der Prozess wartet auf destruktive Cleanup-Freigabe.'))
    } else {
        Add-ExecutionPlanStep -Context $Context -Step (New-ExecutionPlanStep -Id 'runtime.cleanup.review' -Phase 'runtime-cleanup' -Title 'Kontrollierten Runtime-Cleanup freigeben' -ExecutionMode 'review' -Required $false -Status 'skipped' -Reason 'Der Analyzer hat keine Runtime-Loeschungen erkannt.')
    }
}

function BuildComposerPlan {
    param([Parameter(Mandatory = $true)][object] $Context)

    if ($Context.decisions.composerInstallRequired) {
        $instructions = New-CapabilityInstructions -Manifest $Context.manifest -RemoteTarget $Context.remoteTarget -CapabilityId 'composer.install.production' -Purpose 'PHP-Abhaengigkeiten auf der Zielumgebung installieren.' -ExpectedOutcome 'Composer installiert die benoetigten produktiven Abhaengigkeiten ohne Fehler.'
        $status = if (Test-CommandReady -Instructions $instructions) { Get-BlockedOrWaitingStatus -BlockingDependencies $Context.gateIds.ToArray() -WaitingStatus 'waiting-for-human' } else { 'blocked' }
        Add-ExecutionPlanStep -Context $Context -BlocksFollowingSteps $true -Step (New-ExecutionPlanStep `
            -Id 'remote.dependencies.composer-install' `
            -Phase 'remote-dependency-installation' `
            -Title 'Remote Composer-Installation ausfuehren lassen' `
            -ExecutionMode 'human' `
            -Status $status `
            -Reason 'Composer-Abhaengigkeiten haben sich laut Analyzer geaendert.' `
            -ApprovalRequired $true `
            -CapabilityId 'composer.install.production' `
            -DependsOn @($Context.gateIds) `
            -Instructions $instructions `
            -Continuation (New-ContinuationRule -blocksAutomaticContinuation $true -requiredUserAction 'Der Prozess wartet auf Konsolenausgabe und erfolgreiche Bewertung.'))
    } else {
        Add-ExecutionPlanStep -Context $Context -Step (New-ExecutionPlanStep -Id 'remote.dependencies.composer-install' -Phase 'remote-dependency-installation' -Title 'Remote Composer-Installation ausfuehren lassen' -ExecutionMode 'human' -Required $false -Status 'skipped' -Reason 'Der Analyzer hat keinen Composer-Installationsbedarf erkannt.')
    }
}

function BuildMigrationPlan {
    param([Parameter(Mandatory = $true)][object] $Context)

    if (-not $Context.decisions.migrationsRequired) {
        Add-ExecutionPlanStep -Context $Context -Step (New-ExecutionPlanStep -Id 'remote.migrations.execute' -Phase 'remote-migrations' -Title 'Datenbankmigrationen ausfuehren' -ExecutionMode 'human' -Required $false -Status 'skipped' -Reason 'Der Analyzer hat keinen Migrationsbedarf erkannt.')
        return
    }

    $reviewStatus = Get-BlockedOrWaitingStatus -BlockingDependencies $Context.gateIds.ToArray() -WaitingStatus 'waiting-for-review'
    Add-ExecutionPlanStep -Context $Context -BlocksFollowingSteps $true -Step (New-ExecutionPlanStep `
        -Id 'remote.migrations.safety-review' `
        -Phase 'remote-migrations' `
        -Title 'Migrationsrisiko und Backup pruefen' `
        -ExecutionMode 'review' `
        -Status $reviewStatus `
        -Reason 'Migrationen koennen Datenbankstruktur und Datenbestand veraendern und benoetigen eine vorgelagerte Sicherheitsfreigabe.' `
        -ApprovalRequired $true `
        -RiskLevel 'high' `
        -DependsOn @($Context.gateIds) `
        -Instructions ([pscustomobject]@{
            reviewSubject = 'Auszufuehrende Migrationen, Datenbank-Backup und Freigabe vor migrate:status und migrate pruefen.'
            affectedMigrationFiles = @($Context.migrationPaths)
            backupRequired = $true
            requiredResponse = 'Ausdrueckliche Freigabe inklusive Bestaetigung, dass ein geeignetes Datenbank-Backup vorhanden ist.'
        }) `
        -Validation (New-ValidationRule -RequiredResponse 'Explizite High-Risk-Freigabe mit Backup-Bestaetigung.') `
        -Continuation (New-ContinuationRule -blocksAutomaticContinuation $true -requiredUserAction 'Der Prozess wartet auf Migrationsfreigabe und Backup-Bestaetigung.'))

    $statusInstructions = New-CapabilityInstructions -Manifest $Context.manifest -RemoteTarget $Context.remoteTarget -CapabilityId 'artisan.migrate.status' -Purpose 'Pruefen, welche Migrationen auf der Zielumgebung offen oder bereits ausgefuehrt sind.' -ExpectedOutcome 'Laravel gibt den Status der Migrationen ohne Fehler aus.' -RequiredResponse 'Vollstaendige relevante Konsolenausgabe von migrate:status'
    $statusStatus = if (Test-CommandReady -Instructions $statusInstructions) { Get-BlockedOrWaitingStatus -BlockingDependencies $Context.gateIds.ToArray() -WaitingStatus 'waiting-for-human' } else { 'blocked' }
    Add-ExecutionPlanStep -Context $Context -BlocksFollowingSteps $true -Step (New-ExecutionPlanStep `
        -Id 'remote.migrations.status' `
        -Phase 'remote-migrations' `
        -Title 'Migrationsstatus pruefen lassen' `
        -ExecutionMode 'human' `
        -Status $statusStatus `
        -Reason 'Vor der Ausfuehrung muss der aktuelle Migrationsstatus der Zielumgebung sichtbar sein.' `
        -ApprovalRequired $true `
        -RiskLevel 'high' `
        -CapabilityId 'artisan.migrate.status' `
        -DependsOn @($Context.gateIds) `
        -Instructions $statusInstructions `
        -Continuation (New-ContinuationRule -blocksAutomaticContinuation $true -requiredUserAction 'Der Prozess wartet auf migrate:status-Ausgabe und Bewertung.'))

    $instructions = New-CapabilityInstructions -Manifest $Context.manifest -RemoteTarget $Context.remoteTarget -CapabilityId 'artisan.migrate' -Purpose 'Ausfuehren der noch offenen Datenbankmigrationen.' -ExpectedOutcome 'Alle offenen Migrationen werden erfolgreich abgeschlossen.'
    $executeStatus = if (Test-CommandReady -Instructions $instructions) { Get-BlockedOrWaitingStatus -BlockingDependencies $Context.gateIds.ToArray() -WaitingStatus 'waiting-for-human' } else { 'blocked' }
    Add-ExecutionPlanStep -Context $Context -BlocksFollowingSteps $true -Step (New-ExecutionPlanStep `
        -Id 'remote.migrations.execute' `
        -Phase 'remote-migrations' `
        -Title 'Datenbankmigrationen ausfuehren' `
        -ExecutionMode 'human' `
        -Status $executeStatus `
        -Reason 'Seit der Deployment-Baseline wurden neue oder geaenderte Migrationen erkannt.' `
        -ApprovalRequired $true `
        -RiskLevel 'high' `
        -CapabilityId 'artisan.migrate' `
        -DependsOn @($Context.gateIds) `
        -Instructions $instructions `
        -Continuation (New-ContinuationRule -blocksAutomaticContinuation $true -requiredUserAction 'Der Prozess wartet auf Konsolenausgabe und erfolgreiche Bewertung.'))
}

function BuildMaintenancePlan {
    param([Parameter(Mandatory = $true)][object] $Context)

    $maintenanceRequired = $Context.decisions.runtimeDeploymentRequired -and -not $Context.decisions.documentationOnly
    if ($maintenanceRequired) {
        $instructions = New-CapabilityInstructions -Manifest $Context.manifest -RemoteTarget $Context.remoteTarget -CapabilityId 'artisan.optimize.clear' -Purpose 'Laravel Runtime-Caches nach dem Deployment kontrolliert leeren.' -ExpectedOutcome 'Laravel meldet erfolgreich geleerte Caches.'
        $status = if (Test-CommandReady -Instructions $instructions) { Get-BlockedOrWaitingStatus -BlockingDependencies $Context.gateIds.ToArray() -WaitingStatus 'waiting-for-human' } else { 'blocked' }
        Add-ExecutionPlanStep -Context $Context -BlocksFollowingSteps $true -Step (New-ExecutionPlanStep `
            -Id 'remote.runtime.cache-clear' `
            -Phase 'remote-runtime-maintenance' `
            -Title 'Remote Runtime-Caches leeren lassen' `
            -ExecutionMode 'human' `
            -Status $status `
            -Reason 'Nach Runtime-Aenderungen ist eine serverseitige Runtime-Wartung einzuplanen.' `
            -ApprovalRequired $true `
            -CapabilityId 'artisan.optimize.clear' `
            -DependsOn @($Context.gateIds) `
            -Instructions $instructions `
            -Continuation (New-ContinuationRule -blocksAutomaticContinuation $true -requiredUserAction 'Der Prozess wartet auf Konsolenausgabe und erfolgreiche Bewertung.'))
    } else {
        Add-ExecutionPlanStep -Context $Context -Step (New-ExecutionPlanStep -Id 'remote.runtime.cache-clear' -Phase 'remote-runtime-maintenance' -Title 'Remote Runtime-Caches leeren lassen' -ExecutionMode 'human' -Required $false -Status 'skipped' -Reason 'Keine Runtime-Wartung erforderlich.')
    }
}

function BuildVerificationPlan {
    param([Parameter(Mandatory = $true)][object] $Context)

    if ($Context.decisions.runtimeDeploymentRequired -and -not $Context.decisions.documentationOnly) {
        $instructions = New-CapabilityInstructions -Manifest $Context.manifest -RemoteTarget $Context.remoteTarget -CapabilityId 'artisan.about' -Purpose 'Kontrolle, dass die Laravel-Anwendung auf der Zielumgebung antwortet.' -ExpectedOutcome 'Der Befehl gibt Anwendungs- und Umgebungsinformationen ohne Fehler aus.' -RequiredResponse 'Vollstaendige relevante Verifikationsausgabe'
        $status = if (Test-CommandReady -Instructions $instructions) { Get-BlockedOrWaitingStatus -BlockingDependencies $Context.gateIds.ToArray() -WaitingStatus 'waiting-for-human' } else { 'blocked' }
        Add-ExecutionPlanStep -Context $Context -BlocksFollowingSteps $true -Step (New-ExecutionPlanStep `
            -Id 'deployment.verification.remote-about' `
            -Phase 'deployment-verification' `
            -Title 'Deployment auf Zielumgebung verifizieren lassen' `
            -ExecutionMode 'human' `
            -Status $status `
            -Reason 'Vor dem Marker-Update muss das Deployment serverseitig verifiziert werden.' `
            -ApprovalRequired $true `
            -CapabilityId 'artisan.about' `
            -DependsOn @($Context.gateIds) `
            -Instructions $instructions `
            -Continuation (New-ContinuationRule -blocksAutomaticContinuation $true -requiredUserAction 'Der Prozess wartet auf Verifikationsausgabe und erfolgreiche Bewertung.'))
    } else {
        Add-ExecutionPlanStep -Context $Context -Step (New-ExecutionPlanStep -Id 'deployment.verification.remote-about' -Phase 'deployment-verification' -Title 'Deployment auf Zielumgebung verifizieren lassen' -ExecutionMode 'human' -Required $false -Status 'skipped' -Reason 'Keine serverseitige Deployment-Verifikation erforderlich.')
    }
}

function BuildMarkerPlan {
    param([Parameter(Mandatory = $true)][object] $Context)

    Add-ExecutionPlanStep -Context $Context -Step (New-ExecutionPlanStep `
        -Id 'deployment-marker.update' `
        -Phase 'deployment-marker-update' `
        -Title 'Deployment-Marker aktualisieren' `
        -ExecutionMode 'review' `
        -Status $(if ($Context.decisions.documentationOnly -or -not $Context.decisions.runtimeDeploymentRequired) { 'skipped' } else { 'blocked' }) `
        -Required $($Context.decisions.runtimeDeploymentRequired -and -not $Context.decisions.documentationOnly) `
        -Reason 'Die .deploy-version darf erst nach vollstaendig erfolgreichem Deployment und erfolgreicher Verifikation aktualisiert werden.' `
        -ApprovalRequired $true `
        -DependsOn @($Context.gateIds) `
        -Instructions ([pscustomobject]@{
            markerFile = [string] $Context.manifest.deployment.markerFile
            targetCommit = $Context.targetCommit
            requiredConditions = @(
                'Alle erforderlichen Schritte sind completed oder fachlich korrekt skipped.',
                'Keine Blocker bestehen.',
                'Alle Human Gates wurden anhand der Konsolenausgabe erfolgreich bewertet.',
                'Alle Review Gates und destruktiven Schritte wurden ausdruecklich freigegeben.',
                'Die Deployment-Verifikation war erfolgreich.'
            )
            requiredResponse = 'Explizite finale Freigabe nach erfolgreicher Verifikation; in diesem Auftrag wird die Datei nicht geschrieben.'
        }) `
        -Validation (New-ValidationRule -RequiredResponse 'Finale Freigabe nach nachweislich erfolgreicher Verifikation.') `
        -Continuation (New-ContinuationRule -blocksAutomaticContinuation $true -requiredUserAction 'Marker-Update bleibt bis zum vollstaendigen Erfolg blockiert.'))
}

function ConvertTo-ExecutionPlanResult {
    param([Parameter(Mandatory = $true)][object] $Context)

    $result = [ordered]@{}
    $result.schemaVersion = $executionPlanSchemaVersion
    $result.sourceAnalysisVersion = [string] $Context.analysis.engineVersion
    $result.blocked = [bool] $Context.blocked
    $result.project = [pscustomobject]@{
        id = [string] $Context.manifest.project.id
        name = [string] $Context.manifest.project.name
        type = [string] $Context.manifest.project.type
    }
    $result.environment = [pscustomobject]@{
        name = [string] $Context.manifest.deployment.environment
        serverRoot = [string] $Context.manifest.deployment.serverRoot
        applicationRemoteDirectory = $Context.applicationRemoteDirectory
        markerFile = [string] $Context.manifest.deployment.markerFile
        remoteTarget = $Context.remoteTarget
        sharedStorage = $Context.sharedStorage
    }
    $result.baselineCommit = $Context.baselineCommit
    $result.targetCommit = $Context.targetCommit
    $result.decisions = $Context.decisions
    $result.warnings = ConvertTo-Array $Context.warnings
    $result.blockers = ConvertTo-Array $Context.blockers
    $result.manualApprovalPoints = ConvertTo-Array $Context.manualApprovalPoints
    $result.phases = @(
        'preconditions',
        'environment-review',
        'local-frontend-build',
        'local-deployment-preparation',
        'runtime-file-transfer',
        'runtime-cleanup',
        'remote-dependency-installation',
        'database-review',
        'remote-migrations',
        'remote-runtime-maintenance',
        'deployment-verification',
        'deployment-marker-update'
    )
    $result.steps = $Context.steps.ToArray()

    return [pscustomobject] $result
}

function New-UnresolvedExecutionPlan {
    param(
        [Parameter(Mandatory = $true)][object] $Analysis,
        [Parameter(Mandatory = $true)][object] $Manifest,
        [Parameter(Mandatory = $true)][object] $RemoteTarget
    )

    Assert-AnalysisShape -Analysis $Analysis
    Assert-ManifestShape -Manifest $Manifest

    $context = New-ExecutionPlanContext -Analysis $Analysis -Manifest $Manifest -RemoteTarget $RemoteTarget
    BuildPreconditions -Context $context
    BuildEnvironmentReview -Context $context
    BuildFrontendPlan -Context $context
    BuildLocalPreparationPlan -Context $context
    BuildTransferPlan -Context $context
    BuildCleanupPlan -Context $context
    BuildComposerPlan -Context $context
    BuildSeederReviewPlan -Context $context
    BuildMigrationPlan -Context $context
    BuildMaintenancePlan -Context $context
    BuildVerificationPlan -Context $context
    BuildMarkerPlan -Context $context

    return ConvertTo-ExecutionPlanResult -Context $context
}

function New-ExecutionPlan {
    param(
        [Parameter(Mandatory = $true)][object] $Analysis,
        [Parameter(Mandatory = $true)][object] $Manifest,
        [Parameter(Mandatory = $true)][object] $RemoteTarget
    )

    $plan = New-UnresolvedExecutionPlan -Analysis $Analysis -Manifest $Manifest -RemoteTarget $RemoteTarget
    $resolvedPlan = Resolve-DeploymentCapabilities -Plan $plan
    return Add-ExecutionPlanFingerprint -Plan $resolvedPlan
}

function Test-ManualStepOutput {
    param(
        [Parameter(Mandatory = $true)][object] $Step,
        [string] $Output,
        [int] $ExitCode
    )

    if ($Step.executionMode -ne 'human') {
        return 'ambiguous'
    }

    $validation = $Step.validation
    $outputText = if ($null -eq $Output) { '' } else { [string] $Output }

    if ($validation.requiresOutput -and [string]::IsNullOrWhiteSpace($outputText)) {
        return 'incomplete'
    }

    $confirmationOnly = @('erledigt', 'lief durch', 'done', 'ok', 'fertig')
    if ($validation.requiresOutput -and $confirmationOnly -contains $outputText.Trim().ToLowerInvariant()) {
        return 'incomplete'
    }

    foreach ($pattern in @($validation.failurePatterns)) {
        if (-not [string]::IsNullOrWhiteSpace($pattern) -and $outputText -match $pattern) {
            return 'failed'
        }
    }

    if ($validation.requiresExitCode -and $ExitCode -ne 0) {
        return 'failed'
    }

    foreach ($pattern in @($validation.successPatterns)) {
        if (-not [string]::IsNullOrWhiteSpace($pattern) -and $outputText -match $pattern) {
            return 'completed'
        }
    }

    if ($validation.ambiguousWithoutSuccessMatch) {
        return 'ambiguous'
    }

    return 'completed'
}

function Write-HumanGateText {
    param([Parameter(Mandatory = $true)][object] $Step)

    Write-Host 'PAUSE - MANUELLE AUSFUEHRUNG ERFORDERLICH'
    Write-Host ''
    if ($Step.destructive) {
        Write-Host 'WARNUNG: Dieser Schritt ist destruktiv oder kann irreversible Auswirkungen haben.'
        Write-Host ''
    }
    Write-Host 'Schritt:'
    Write-Host $Step.title
    Write-Host ''
    Write-Host 'Zielumgebung:'
    Write-Host $Step.instructions.environment
    Write-Host ''
    Write-Host 'Arbeitsverzeichnis:'
    Write-Host $Step.instructions.workingDirectory
    Write-Host ''
    Write-Host 'Auszufuehrender Befehl:'
    Write-Host $Step.instructions.command
    Write-Host ''
    Write-Host 'Zweck:'
    Write-Host $Step.instructions.purpose
    Write-Host ''
    Write-Host 'Erwartetes Ergebnis:'
    Write-Host $Step.instructions.expectedOutcome
    Write-Host ''
    Write-Host 'Moegliche Fehlermerkmale:'
    @($Step.validation.failurePatterns) | ForEach-Object { Write-Host $_ }
    Write-Host ''
    Write-Host 'Benoetigte Rueckmeldung:'
    Write-Host ('Bitte die {0} posten.' -f $Step.instructions.requiredResponse.ToLowerInvariant())
    Write-Host ''
    Write-Host 'Der Deployment-Prozess bleibt bis zur erfolgreichen Analyse der Ausgabe pausiert.'
}

function Write-ExecutionPlanSummary {
    param([Parameter(Mandatory = $true)][object] $Plan)

    Write-Host "SHK-MOMM Execution Plan v$($Plan.schemaVersion)"
    Write-Host "Project: $($Plan.project.name) [$($Plan.environment.name)]"
    Write-Host "Blocked: $($Plan.blocked)"
    Write-Host "Steps: $(@($Plan.steps).Count)"
    Write-Host ''
    Write-Host 'Decisions:'
    $Plan.decisions.PSObject.Properties | ForEach-Object {
        Write-Host ("- {0}: {1}" -f $_.Name, $_.Value)
    }

    if (@($Plan.blockers).Count -gt 0) {
        Write-Host ''
        Write-Host 'Blockers:'
        $Plan.blockers | ForEach-Object { Write-Host "- $_" }
    }

    Write-Host ''
    Write-Host 'Steps:'
    foreach ($step in $Plan.steps) {
        $flag = if ($step.required) { 'required' } else { 'skipped' }
        Write-Host ("- {0} [{1}/{2}/{3}]" -f $step.id, $step.phase, $step.executionMode, $flag)
        Write-Host ("  Status: {0}" -f $step.status)
        if ($step.executionMode -eq 'human' -and $step.required) {
            Write-Host ("  Command: {0}" -f $step.instructions.command)
            Write-Host ("  Working directory: {0}" -f $step.instructions.workingDirectory)
        }
    }

    [object[]] $firstHumanStep = @($Plan.steps | Where-Object { $_.executionMode -eq 'human' -and $_.required -and $_.status -eq 'waiting-for-human' } | Select-Object -First 1)
    if (@($firstHumanStep).Count -gt 0) {
        Write-Host ''
        Write-HumanGateText -Step $firstHumanStep[0]
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    $analysisResult = Read-JsonFile -Path $AnalysisPath
    $manifestResult = Read-JsonFile -Path $ProjectManifestPath
    $targetResult = Read-DeploymentTarget -Path $TargetPath
    $remoteTarget = Resolve-RemoteTarget -Manifest $manifestResult.value -TargetConfiguration $targetResult
    $requestedOutputPath = $OutputPath
    $executionPlan = New-ExecutionPlan -Analysis $analysisResult.value -Manifest $manifestResult.value -RemoteTarget $remoteTarget

    if (-not [string]::IsNullOrWhiteSpace($requestedOutputPath)) {
        $resolvedOutputPath = Resolve-LocalPath -Path $requestedOutputPath
        $outputDirectory = Split-Path -Path $resolvedOutputPath -Parent
        if (-not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
            throw "Output directory does not exist: $outputDirectory"
        }
        $executionPlan | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $resolvedOutputPath -Encoding utf8
    }

    if ($Format -eq 'Json') {
        $executionPlan | ConvertTo-Json -Depth 30
    } else {
        Write-ExecutionPlanSummary -Plan $executionPlan
    }

    if ($executionPlan.blocked) {
        exit 2
    }

    exit 0
}
