[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:failures = New-Object System.Collections.Generic.List[string]
$engineRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '..'))
$reconciliationPath = Join-Path -Path $engineRoot -ChildPath 'src/ps1/Build-RuntimeArtifactReconciliation.ps1'
$cliPath = Join-Path -Path $engineRoot -ChildPath 'bin/deployment-engine.ps1'

. $reconciliationPath -ModuleOnly

function Assert-True { param([bool] $Condition, [string] $Message) if (-not $Condition) { $script:failures.Add($Message) } }
function Assert-Equal { param($Actual, $Expected, [string] $Message) if ($Actual -ne $Expected) { $script:failures.Add("$Message Expected '$Expected', got '$Actual'.") } }
function Assert-ThrowsLike {
    param([scriptblock] $Script, [string] $Pattern, [string] $Message)
    try { & $Script; $script:failures.Add($Message) } catch { Assert-True ($_.Exception.Message -match $Pattern) "$Message Actual error: $($_.Exception.Message)" }
}

function Copy-TestObject {
    param([Parameter(Mandatory = $true)][object] $Value)
    return $Value | ConvertTo-Json -Depth 100 | ConvertFrom-Json -NoEnumerate
}

function New-TestExecutionPlan {
    return [pscustomobject]@{
        executionPlanFingerprint = 'execution-plan-fingerprint-a'
        project = [pscustomobject]@{ id = 'demo-project'; name = 'Demo'; type = 'laravel' }
        environment = [pscustomobject]@{ applicationRemoteDirectory = '/var/www/demo-app' }
    }
}

function New-TestManifest {
    param([string] $Root)
    return [pscustomobject]@{
        project = [pscustomobject]@{ root = $Root; id = 'demo-project' }
        deployment = [pscustomobject]@{ serverRoot = 'netzlaufwerk' }
    }
}

function New-TestPackagingPolicy {
    return [pscustomobject]@{
        policyId = 'packaging-policy-test'
        projectId = 'demo-project'
        artifactType = 'deployment-archive'
        vendorStrategy = 'exclude-install-on-target-from-lockfiles'
        includedPaths = @('**')
        excludedPaths = @('storage/**')
        executionPlanFingerprint = 'execution-plan-fingerprint-a'
        createdAt = '2026-07-28T12:00:00Z'
    }
}

function New-TestArtifact {
    param(
        [string] $ArtifactId,
        [string] $FileName,
        [string] $Hash,
        [bool] $WithPackaging = $false,
        [string] $ExecutionPlanFingerprint = 'execution-plan-fingerprint-a',
        [string] $PolicyFingerprint = ''
    )
    $artifact = [pscustomobject]@{
        artifactId = $ArtifactId
        artifactType = 'deployment-archive'
        archiveFormat = 'zip'
        localPath = "D:\Artifacts\$FileName"
        fileName = $FileName
        fileSize = 123
        hash = $Hash
        executionPlanFingerprint = $ExecutionPlanFingerprint
        createdAt = '2026-07-28T12:00:00Z'
    }
    if ($WithPackaging) {
        Add-Member -InputObject $artifact -MemberType NoteProperty -Name 'packagingPolicyId' -Value 'packaging-policy-test'
        Add-Member -InputObject $artifact -MemberType NoteProperty -Name 'packagingPolicyFingerprint' -Value $PolicyFingerprint
        Add-Member -InputObject $artifact -MemberType NoteProperty -Name 'packagingValidation' -Value ([pscustomobject]@{ includedFileCount = 1; excludedFileCount = 0; includedBytes = 123 })
    }
    return $artifact
}

$tmp = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('runtime-artifact-reconciliation-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    $plan = New-TestExecutionPlan
    $manifest = New-TestManifest -Root $tmp
    $policy = New-TestPackagingPolicy
    $policyFingerprint = Get-PackagingPolicyFingerprintForReconciliation -Policy $policy
    $previous = New-TestArtifact -ArtifactId 'runtime-artifact-old' -FileName 'old.zip' -Hash 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    $replacement = New-TestArtifact -ArtifactId 'runtime-artifact-new' -FileName 'new.zip' -Hash 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' -WithPackaging $true -PolicyFingerprint $policyFingerprint

    $result = Resolve-RuntimeArtifactReconciliation -DeploymentRunId 'run-1' -ExecutionPlan $plan -ProjectManifest $manifest -PreviousRuntimeArtifact $previous -ReplacementRuntimeArtifact $replacement -PackagingPolicy $policy -CurrentStep 'remote.archive.extract' -CurrentStatus 'WaitingForHuman' -ReconciledBy 'test'
    Assert-Equal $result.previousArtifactStatus 'superseded' 'Previous artifact must be superseded.'
    Assert-Equal $result.replacementArtifactStatus 'active-candidate' 'Replacement artifact must be active candidate.'
    Assert-Equal $result.activeRuntimeArtifactId 'runtime-artifact-new' 'Active artifact must be replacement.'
    Assert-Equal $result.stateTransition.to.currentStep 'artifact.upload' 'Reconciliation must return to upload step.'
    Assert-Equal $result.stateTransition.to.nextStep 'remote.artifact.validate' 'Upload must be followed by remote artifact validation.'
    Assert-Equal $result.stateTransition.to.status 'WaitingForHuman' 'Reconciliation must stop for human upload.'
    Assert-Equal @($result.artifactStates | Where-Object status -eq 'active-candidate').Count 1 'Only one active candidate is allowed.'
    Assert-Equal (@($result.artifactStates | Where-Object artifactId -eq 'runtime-artifact-old')[0]).eligibleForExtract $false 'Old artifact must not be eligible for extract.'
    Assert-True (($result.blockedArtifactReferences | Where-Object { $_.stepId -eq 'remote.archive.extract' -and $_.forbiddenRuntimeArtifactId -eq 'runtime-artifact-old' }).Count -eq 1) 'Old artifact must be blocked from remote archive extract.'
    Assert-True ($result.uploadPreview.finalDestination -match 'runtime-artifact-new') 'Upload destination must include replacement artifact id.'

    $otherReplacement = New-TestArtifact -ArtifactId 'runtime-artifact-other' -FileName 'new.zip' -Hash 'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc' -WithPackaging $true -PolicyFingerprint $policyFingerprint
    $otherResult = Resolve-RuntimeArtifactReconciliation -DeploymentRunId 'run-1' -ExecutionPlan $plan -ProjectManifest $manifest -PreviousRuntimeArtifact $previous -ReplacementRuntimeArtifact $otherReplacement -PackagingPolicy $policy -CurrentStep 'remote.archive.extract' -CurrentStatus 'WaitingForHuman' -ReconciledBy 'test'
    Assert-True ($otherResult.uploadPreview.finalDestination -ne $result.uploadPreview.finalDestination) 'Different artifact IDs must produce different remote/network paths.'

    $wrongFingerprint = Copy-TestObject -Value $replacement
    $wrongFingerprint.executionPlanFingerprint = 'other'
    Assert-ThrowsLike -Script { Resolve-RuntimeArtifactReconciliation -DeploymentRunId 'run-1' -ExecutionPlan $plan -ProjectManifest $manifest -PreviousRuntimeArtifact $previous -ReplacementRuntimeArtifact $wrongFingerprint -PackagingPolicy $policy -CurrentStep 'remote.archive.extract' -CurrentStatus 'WaitingForHuman' -ReconciledBy 'test' | Out-Null } -Pattern 'executionPlanFingerprint' -Message 'Replacement artifact with wrong execution plan binding must be rejected.'

    $wrongPolicy = Copy-TestObject -Value $replacement
    $wrongPolicy.packagingPolicyFingerprint = 'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd'
    Assert-ThrowsLike -Script { Resolve-RuntimeArtifactReconciliation -DeploymentRunId 'run-1' -ExecutionPlan $plan -ProjectManifest $manifest -PreviousRuntimeArtifact $previous -ReplacementRuntimeArtifact $wrongPolicy -PackagingPolicy $policy -CurrentStep 'remote.archive.extract' -CurrentStatus 'WaitingForHuman' -ReconciledBy 'test' | Out-Null } -Pattern 'packagingPolicyFingerprint' -Message 'Replacement artifact with wrong packaging policy binding must be rejected.'

    Assert-ThrowsLike -Script { Resolve-RuntimeArtifactReconciliation -DeploymentRunId 'run-1' -ExecutionPlan $plan -ProjectManifest $manifest -PreviousRuntimeArtifact $previous -ReplacementRuntimeArtifact $replacement -PackagingPolicy $policy -CurrentStep 'remote.application.finalize' -CurrentStatus 'WaitingForHuman' -ReconciledBy 'test' | Out-Null } -Pattern 'unsupported current step|release activation' -Message 'Reconciliation after release activation/finalize must be rejected.'

    Assert-ThrowsLike -Script { Resolve-RuntimeArtifactReconciliation -DeploymentRunId 'run-1' -ExecutionPlan $plan -ProjectManifest $manifest -PreviousRuntimeArtifact $previous -ReplacementRuntimeArtifact $replacement -PackagingPolicy $policy -CurrentStep 'remote.archive.extract' -CurrentStatus 'WaitingForHuman' -ReconciledBy 'test' -DeleteRemoteArtifact | Out-Null } -Pattern 'remote deletion' -Message 'Automatic remote deletion attempt must be rejected.'

    $planPath = Join-Path $tmp 'execution-plan.json'
    $manifestPath = Join-Path $tmp 'deployment.project.json'
    $previousPath = Join-Path $tmp 'previous.json'
    $replacementPath = Join-Path $tmp 'replacement.json'
    $policyPath = Join-Path $tmp 'policy.json'
    $outputPath = Join-Path $tmp 'reconciliation.json'
    $plan | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $planPath -Encoding UTF8
    $manifest | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
    $previous | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $previousPath -Encoding UTF8
    $replacement | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $replacementPath -Encoding UTF8
    $policy | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $policyPath -Encoding UTF8
    $cliJson = & $cliPath build-runtime-artifact-reconciliation -DeploymentRunId 'run-1' -ExecutionPlanPath $planPath -Manifest $manifestPath -PreviousRuntimeArtifactPath $previousPath -ReplacementRuntimeArtifactPath $replacementPath -PackagingPolicyPath $policyPath -OutputPath $outputPath -Format Json
    Assert-Equal ($cliJson | ConvertFrom-Json).activeRuntimeArtifactId 'runtime-artifact-new' 'CLI must emit reconciliation JSON.'
    Assert-True (Test-Path -LiteralPath $outputPath -PathType Leaf) 'CLI must write explicit reconciliation output.'
} finally {
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
}

if ($script:failures.Count -gt 0) {
    Write-Host 'Runtime Artifact Reconciliation tests failed:'
    $script:failures | ForEach-Object { Write-Host "- $_" }
    exit 1
}

Write-Host 'Runtime Artifact Reconciliation tests passed.'
exit 0
