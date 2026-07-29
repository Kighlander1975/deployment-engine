[CmdletBinding()]
param(
    [string] $DeploymentRunId,
    [string] $ExecutionPlanPath,
    [string] $ProjectManifestPath,
    [string] $PreviousRuntimeArtifactPath,
    [string] $ReplacementRuntimeArtifactPath,
    [string] $PackagingPolicyPath,
    [string] $CurrentStep = 'remote.archive.extract',
    [string] $CurrentStatus = 'WaitingForHuman',
    [string] $ReconciledBy = 'Codex',
    [string] $OutputPath,
    [string] $Format = 'Json',
    [switch] $DeleteRemoteArtifact,
    [switch] $ModuleOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-ReconciliationPath {
    param([Parameter(Mandatory = $true)][string] $Path)
    $executionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function Read-ReconciliationJsonFile {
    param([Parameter(Mandatory = $true)][string] $Path, [Parameter(Mandatory = $true)][string] $Description)
    $resolved = Resolve-ReconciliationPath -Path $Path
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) { throw "$Description file does not exist: $resolved" }
    try {
        return (Get-Content -LiteralPath $resolved -Raw | ConvertFrom-Json -NoEnumerate)
    } catch {
        throw "Invalid $Description JSON in '$resolved': $($_.Exception.Message)"
    }
}

function Copy-ReconciliationObject {
    param([Parameter(Mandatory = $true)][object] $Value)
    return $Value | ConvertTo-Json -Depth 100 | ConvertFrom-Json -NoEnumerate
}

function Test-ReconciliationProperty {
    param([object] $Object, [Parameter(Mandatory = $true)][string] $Name)
    return ($null -ne $Object -and @($Object.PSObject.Properties | Where-Object { $_.Name -eq $Name }).Count -gt 0)
}

function Assert-ReconciliationString {
    param([Parameter(Mandatory = $true)][object] $Object, [Parameter(Mandatory = $true)][string] $Name, [Parameter(Mandatory = $true)][string] $Context, [bool] $AllowEmpty = $false)
    if (-not (Test-ReconciliationProperty -Object $Object -Name $Name)) { throw "$Context validation failed: missing required field '$Name'." }
    if (-not ($Object.$Name -is [string])) { throw "$Context validation failed: field '$Name' must be a string." }
    if (-not $AllowEmpty -and [string]::IsNullOrWhiteSpace([string] $Object.$Name)) { throw "$Context validation failed: field '$Name' must not be empty." }
}

function Assert-ReconciliationInteger {
    param([object] $Value, [Parameter(Mandatory = $true)][string] $Context, [Parameter(Mandatory = $true)][string] $Field)
    if (-not ($Value -is [byte] -or $Value -is [int16] -or $Value -is [int] -or $Value -is [long])) {
        throw "$Context validation failed: field '$Field' must be an integer."
    }
}

function Assert-NoReconciliationSecrets {
    param([Parameter(Mandatory = $true)][object] $Value, [Parameter(Mandatory = $true)][string] $Context)
    $json = $Value | ConvertTo-Json -Depth 100
    if ($json -match '(?i)(password=|token=|private key|BEGIN OPENSSH PRIVATE KEY|api[_-]?key|client[_-]?secret)') {
        throw "$Context validation failed: secret-like content is not allowed."
    }
}

function Assert-RuntimeArtifactForReconciliation {
    param([Parameter(Mandatory = $true)][object] $Artifact, [Parameter(Mandatory = $true)][string] $Context, [Parameter(Mandatory = $true)][string] $ExecutionPlanFingerprint, [bool] $RequirePackagingBinding = $true)

    foreach ($field in @('artifactId', 'artifactType', 'archiveFormat', 'localPath', 'fileName', 'hash', 'executionPlanFingerprint')) {
        Assert-ReconciliationString -Object $Artifact -Name $field -Context $Context
    }
    Assert-ReconciliationInteger -Value $Artifact.fileSize -Context $Context -Field 'fileSize'
    if ([int64] $Artifact.fileSize -lt 0) { throw "$Context validation failed: fileSize must not be negative." }
    if ($Artifact.artifactType -ne 'deployment-archive') { throw "$Context validation failed: artifactType must be deployment-archive." }
    if ($Artifact.archiveFormat -notin @('zip', 'tar')) { throw "$Context validation failed: unsupported archiveFormat '$($Artifact.archiveFormat)'." }
    if ($Artifact.fileName -match '[\\/]') { throw "$Context validation failed: fileName must not contain path separators." }
    if ($Artifact.hash -notmatch '^[a-fA-F0-9]{64}$') { throw "$Context validation failed: hash must be a SHA-256 hex string." }
    if ([string] $Artifact.executionPlanFingerprint -ne $ExecutionPlanFingerprint) { throw "$Context validation failed: executionPlanFingerprint does not match current execution plan." }
    if ($RequirePackagingBinding) {
        foreach ($field in @('packagingPolicyId', 'packagingPolicyFingerprint')) {
            Assert-ReconciliationString -Object $Artifact -Name $field -Context $Context
        }
        if ($Artifact.packagingPolicyFingerprint -notmatch '^[a-fA-F0-9]{64}$') { throw "$Context validation failed: packagingPolicyFingerprint must be a SHA-256 hex string." }
    }
}

function Join-ReconciliationRemotePath {
    param([Parameter(Mandatory = $true)][string] $Root, [Parameter(Mandatory = $true)][string] $Child)
    return $Root.TrimEnd('/') + '/' + (($Child -replace '\\', '/').TrimStart('/'))
}

function Get-PackagingPolicyFingerprintForReconciliation {
    param([Parameter(Mandatory = $true)][object] $Policy)
    $copy = Copy-ReconciliationObject -Value $Policy
    $json = $copy | ConvertTo-Json -Depth 80 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Resolve-RuntimeArtifactReconciliation {
    param(
        [Parameter(Mandatory = $true)][string] $DeploymentRunId,
        [Parameter(Mandatory = $true)][object] $ExecutionPlan,
        [Parameter(Mandatory = $true)][object] $ProjectManifest,
        [Parameter(Mandatory = $true)][object] $PreviousRuntimeArtifact,
        [Parameter(Mandatory = $true)][object] $ReplacementRuntimeArtifact,
        [Parameter(Mandatory = $true)][object] $PackagingPolicy,
        [Parameter(Mandatory = $true)][string] $CurrentStep,
        [Parameter(Mandatory = $true)][string] $CurrentStatus,
        [Parameter(Mandatory = $true)][string] $ReconciledBy,
        [switch] $DeleteRemoteArtifact
    )

    if ($DeleteRemoteArtifact) { throw 'Runtime artifact reconciliation rejected: automatic remote deletion is not allowed.' }
    if ([string]::IsNullOrWhiteSpace($DeploymentRunId)) { throw 'Runtime artifact reconciliation validation failed: DeploymentRunId is required.' }
    if ($DeploymentRunId -match '[\\/]|\.\.') { throw 'Runtime artifact reconciliation validation failed: DeploymentRunId must be a single safe path segment.' }
    if ($CurrentStep -notin @('remote.archive.extract', 'artifact.upload')) { throw "Runtime artifact reconciliation validation failed: unsupported current step '$CurrentStep'." }
    if ($CurrentStatus -ne 'WaitingForHuman') { throw "Runtime artifact reconciliation validation failed: current status must be WaitingForHuman." }

    Assert-ReconciliationString -Object $ExecutionPlan -Name 'executionPlanFingerprint' -Context 'Execution plan'
    $fingerprint = [string] $ExecutionPlan.executionPlanFingerprint
    Assert-ReconciliationString -Object $ExecutionPlan.project -Name 'id' -Context 'Execution plan project'
    Assert-ReconciliationString -Object $ExecutionPlan.environment -Name 'applicationRemoteDirectory' -Context 'Execution plan environment'
    Assert-ReconciliationString -Object $ProjectManifest.deployment -Name 'serverRoot' -Context 'Project manifest deployment'
    Assert-ReconciliationString -Object $ProjectManifest.project -Name 'root' -Context 'Project manifest project'

    Assert-RuntimeArtifactForReconciliation -Artifact $PreviousRuntimeArtifact -Context 'Previous runtime artifact' -ExecutionPlanFingerprint $fingerprint -RequirePackagingBinding:$false
    Assert-RuntimeArtifactForReconciliation -Artifact $ReplacementRuntimeArtifact -Context 'Replacement runtime artifact' -ExecutionPlanFingerprint $fingerprint -RequirePackagingBinding:$true
    if ([string] $PreviousRuntimeArtifact.artifactId -eq [string] $ReplacementRuntimeArtifact.artifactId) {
        throw 'Runtime artifact reconciliation validation failed: previous and replacement artifact IDs must differ.'
    }
    Assert-ReconciliationString -Object $PackagingPolicy -Name 'policyId' -Context 'Packaging policy'
    Assert-ReconciliationString -Object $PackagingPolicy -Name 'executionPlanFingerprint' -Context 'Packaging policy'
    if ([string] $PackagingPolicy.executionPlanFingerprint -ne $fingerprint) { throw 'Runtime artifact reconciliation validation failed: packaging policy executionPlanFingerprint does not match.' }
    if ([string] $ReplacementRuntimeArtifact.packagingPolicyId -ne [string] $PackagingPolicy.policyId) { throw 'Runtime artifact reconciliation validation failed: replacement packagingPolicyId does not match packaging policy.' }
    $policyFingerprint = Get-PackagingPolicyFingerprintForReconciliation -Policy $PackagingPolicy
    if ([string] $ReplacementRuntimeArtifact.packagingPolicyFingerprint -ne $policyFingerprint) { throw 'Runtime artifact reconciliation validation failed: replacement packagingPolicyFingerprint does not match packaging policy.' }

    if ($CurrentStep -match 'release\.activate|application\.finalize|deployment\.verify') {
        throw 'Runtime artifact reconciliation validation failed: reconciliation after release activation is not allowed.'
    }

    $networkRoot = Join-Path -Path ([string] $ProjectManifest.project.root) -ChildPath ([string] $ProjectManifest.deployment.serverRoot)
    $relativeUploadDirectory = Join-Path -Path (Join-Path -Path '.deployment/uploads' -ChildPath $DeploymentRunId) -ChildPath ([string] $ReplacementRuntimeArtifact.artifactId)
    $networkUploadDirectory = Join-Path -Path $networkRoot -ChildPath $relativeUploadDirectory
    $finalDestination = Join-Path -Path $networkUploadDirectory -ChildPath ([string] $ReplacementRuntimeArtifact.fileName)
    $temporaryDestination = $finalDestination + '.partial'
    $remoteUploadDirectory = Join-ReconciliationRemotePath -Root ([string] $ExecutionPlan.environment.applicationRemoteDirectory) -Child ('.deployment/uploads/' + $DeploymentRunId + '/' + [string] $ReplacementRuntimeArtifact.artifactId)
    $remoteFinalDestination = Join-ReconciliationRemotePath -Root $remoteUploadDirectory -Child ([string] $ReplacementRuntimeArtifact.fileName)
    $remoteTemporaryDestination = $remoteFinalDestination + '.partial'

    $previousPackagingPolicyId = ''
    if (Test-ReconciliationProperty -Object $PreviousRuntimeArtifact -Name 'packagingPolicyId') { $previousPackagingPolicyId = [string] $PreviousRuntimeArtifact.packagingPolicyId }
    $reconciledAt = (Get-Date).ToUniversalTime().ToString('o')

    $result = [pscustomobject]@{
        schemaVersion = '0.1'
        reconciliationType = 'runtime-artifact-reconciliation'
        deploymentRunId = $DeploymentRunId
        projectId = [string] $ExecutionPlan.project.id
        previousRuntimeArtifactId = [string] $PreviousRuntimeArtifact.artifactId
        replacementRuntimeArtifactId = [string] $ReplacementRuntimeArtifact.artifactId
        reason = 'packaging-policy-correction'
        previousArtifactStatus = 'superseded'
        replacementArtifactStatus = 'active-candidate'
        activeRuntimeArtifactId = [string] $ReplacementRuntimeArtifact.artifactId
        executionPlanFingerprint = $fingerprint
        previousPackagingPolicyId = $previousPackagingPolicyId
        replacementPackagingPolicyId = [string] $ReplacementRuntimeArtifact.packagingPolicyId
        replacementPackagingPolicyFingerprint = [string] $ReplacementRuntimeArtifact.packagingPolicyFingerprint
        reconciledAt = $reconciledAt
        reconciledBy = $ReconciledBy
        stateTransition = [pscustomobject]@{
            from = [pscustomobject]@{ currentStep = $CurrentStep; status = $CurrentStatus }
            via = 'runtime-artifact.reconcile'
            to = [pscustomobject]@{ currentStep = 'artifact.upload'; nextStep = 'remote.artifact.validate'; status = 'WaitingForHuman' }
            reason = 'Replacement runtime artifact requires a new upload. This is not a retry of the superseded upload.'
        }
        artifactStates = @(
            [pscustomobject]@{ artifactId = [string] $PreviousRuntimeArtifact.artifactId; status = 'superseded'; uploaded = $true; eligibleForExtract = $false; deleteAutomatically = $false }
            [pscustomobject]@{ artifactId = [string] $ReplacementRuntimeArtifact.artifactId; status = 'active-candidate'; uploaded = $false; eligibleForExtract = $false; deleteAutomatically = $false }
        )
        blockedArtifactReferences = @(
            'artifact.upload',
            'remote.artifact.validate',
            'remote.artifact.finalize',
            'remote.archive.extract',
            'remote.composer.preflight',
            'remote.composer.install',
            'remote.composer.validate',
            'remote.release.validate'
        ) | ForEach-Object { [pscustomobject]@{ stepId = $_; forbiddenRuntimeArtifactId = [string] $PreviousRuntimeArtifact.artifactId } }
        uploadPreview = [pscustomobject]@{
            deploymentRunId = $DeploymentRunId
            source = [string] $ReplacementRuntimeArtifact.localPath
            temporaryDestination = $temporaryDestination
            finalDestination = $finalDestination
            remoteTemporaryDestination = $remoteTemporaryDestination
            remoteFinalDestination = $remoteFinalDestination
            artifactId = [string] $ReplacementRuntimeArtifact.artifactId
            expectedSize = [int64] $ReplacementRuntimeArtifact.fileSize
            expectedSha256 = [string] $ReplacementRuntimeArtifact.hash
            executionPlanFingerprint = $fingerprint
            packagingPolicyId = [string] $ReplacementRuntimeArtifact.packagingPolicyId
            packagingPolicyFingerprint = [string] $ReplacementRuntimeArtifact.packagingPolicyFingerprint
            currentStep = 'artifact.upload'
            nextStep = 'remote.artifact.validate'
            status = 'WaitingForHuman'
        }
        remoteValidationFlow = @('artifact.upload', 'remote.artifact.validate', 'remote.artifact.finalize', 'remote.archive.extract')
        persistentDataNotice = [pscustomobject]@{
            path = 'storage/app/private'
            classification = 'persistent-runtime-data'
            includedInDeploymentArtifact = $false
            openArchitectureSteps = @('remote.shared-storage.prepare', 'remote.shared-storage.validate', 'remote.release.link-shared-storage')
        }
    }
    Assert-NoReconciliationSecrets -Value $result -Context 'Runtime artifact reconciliation'
    return $result
}

function Write-RuntimeArtifactReconciliationJson {
    param([Parameter(Mandatory = $true)][object] $Result, [string] $OutputPath)
    $json = $Result | ConvertTo-Json -Depth 100
    if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
        $resolvedOutputPath = Resolve-ReconciliationPath -Path $OutputPath
        $outputDirectory = Split-Path -Path $resolvedOutputPath -Parent
        if (-not [string]::IsNullOrWhiteSpace($outputDirectory)) { New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null }
        $json | Set-Content -LiteralPath $resolvedOutputPath -Encoding utf8
    }
    return $json
}

function Invoke-RuntimeArtifactReconciliationBuild {
    param(
        [Parameter(Mandatory = $true)][string] $DeploymentRunId,
        [Parameter(Mandatory = $true)][string] $ExecutionPlanPath,
        [Parameter(Mandatory = $true)][string] $ProjectManifestPath,
        [Parameter(Mandatory = $true)][string] $PreviousRuntimeArtifactPath,
        [Parameter(Mandatory = $true)][string] $ReplacementRuntimeArtifactPath,
        [Parameter(Mandatory = $true)][string] $PackagingPolicyPath,
        [Parameter(Mandatory = $true)][string] $CurrentStep,
        [Parameter(Mandatory = $true)][string] $CurrentStatus,
        [Parameter(Mandatory = $true)][string] $ReconciledBy,
        [string] $OutputPath,
        [string] $Format = 'Json',
        [switch] $DeleteRemoteArtifact
    )
    if ($Format -ne 'Json') { throw "build-runtime-artifact-reconciliation only supports -Format Json." }
    $executionPlan = Read-ReconciliationJsonFile -Path $ExecutionPlanPath -Description 'Execution plan'
    $manifest = Read-ReconciliationJsonFile -Path $ProjectManifestPath -Description 'Project manifest'
    $previous = Read-ReconciliationJsonFile -Path $PreviousRuntimeArtifactPath -Description 'Previous runtime artifact'
    $replacement = Read-ReconciliationJsonFile -Path $ReplacementRuntimeArtifactPath -Description 'Replacement runtime artifact'
    $policy = Read-ReconciliationJsonFile -Path $PackagingPolicyPath -Description 'Packaging policy'
    $result = Resolve-RuntimeArtifactReconciliation -DeploymentRunId $DeploymentRunId -ExecutionPlan $executionPlan -ProjectManifest $manifest -PreviousRuntimeArtifact $previous -ReplacementRuntimeArtifact $replacement -PackagingPolicy $policy -CurrentStep $CurrentStep -CurrentStatus $CurrentStatus -ReconciledBy $ReconciledBy -DeleteRemoteArtifact:$DeleteRemoteArtifact
    return Write-RuntimeArtifactReconciliationJson -Result $result -OutputPath $OutputPath
}

if (-not $ModuleOnly) {
    foreach ($required in @('DeploymentRunId', 'ExecutionPlanPath', 'ProjectManifestPath', 'PreviousRuntimeArtifactPath', 'ReplacementRuntimeArtifactPath', 'PackagingPolicyPath')) {
        if ([string]::IsNullOrWhiteSpace((Get-Variable -Name $required -ValueOnly))) { throw "Missing required parameter for 'build-runtime-artifact-reconciliation': -$required" }
    }
    if ([string]::IsNullOrWhiteSpace($Format)) { $Format = 'Json' }
    Invoke-RuntimeArtifactReconciliationBuild -DeploymentRunId $DeploymentRunId -ExecutionPlanPath $ExecutionPlanPath -ProjectManifestPath $ProjectManifestPath -PreviousRuntimeArtifactPath $PreviousRuntimeArtifactPath -ReplacementRuntimeArtifactPath $ReplacementRuntimeArtifactPath -PackagingPolicyPath $PackagingPolicyPath -CurrentStep $CurrentStep -CurrentStatus $CurrentStatus -ReconciledBy $ReconciledBy -OutputPath $OutputPath -Format $Format -DeleteRemoteArtifact:$DeleteRemoteArtifact
}
