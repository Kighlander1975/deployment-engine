[CmdletBinding()]
param(
    [string] $ExecutorRequestPath,
    [string] $OutputPath,
    [string] $Format = 'Json',
    [switch] $ModuleOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-LocalOperationPath {
    param([Parameter(Mandatory = $true)][string] $Path)
    $executionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function Read-LocalOperationJsonFile {
    param([Parameter(Mandatory = $true)][string] $Path)
    $resolved = Resolve-LocalOperationPath -Path $Path
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) { throw "Executor request file does not exist: $resolved" }
    try {
        return (Get-Content -LiteralPath $resolved -Raw | ConvertFrom-Json)
    } catch {
        throw "Invalid executor request JSON in '$resolved': $($_.Exception.Message)"
    }
}

function Copy-LocalOperationObject {
    param([Parameter(Mandatory = $true)][object] $Value)
    return $Value | ConvertTo-Json -Depth 100 | ConvertFrom-Json -NoEnumerate
}

function Test-LocalOperationProperty {
    param([object] $Object, [Parameter(Mandatory = $true)][string] $Name)
    return ($null -ne $Object -and @($Object.PSObject.Properties | Where-Object { $_.Name -eq $Name }).Count -gt 0)
}

function Test-LocalOperationObjectLike {
    param([object] $Value)
    return ($null -ne $Value -and @($Value.PSObject.Properties).Count -gt 0 -and -not ($Value -is [string]) -and -not ($Value -is [array]))
}

function Test-LocalOperationSecretText {
    param([string] $Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    return ($Text -match '(?i)(password=|token=|private key|BEGIN OPENSSH PRIVATE KEY|api[_-]?key|client[_-]?secret)')
}

function Test-LocalOperationSecretPath {
    param([string] $Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $leaf = [System.IO.Path]::GetFileName($Path)
    return ($leaf -match '(?i)^\.env(\..*)?$|^id_rsa$|^id_ed25519$|\.key$|\.pem$')
}

function New-LocalOperationResult {
    param(
        [string] $Status = 'rejected',
        [object] $Request,
        [string] $OperationType = '',
        [int] $ExitStatus = 1,
        [string] $Diagnostic = '',
        [object[]] $Artifacts = @()
    )
    $itemId = ''
    $commandId = ''
    $sessionId = ''
    if ($null -ne $Request) {
        if (Test-LocalOperationProperty -Object $Request -Name 'sessionId') { $sessionId = [string] $Request.sessionId }
        if (Test-LocalOperationProperty -Object $Request -Name 'itemId') { $itemId = [string] $Request.itemId }
        if (Test-LocalOperationProperty -Object $Request -Name 'commandId') { $commandId = [string] $Request.commandId }
        if ([string]::IsNullOrWhiteSpace($OperationType) -and (Test-LocalOperationProperty -Object $Request -Name 'operationType')) { $OperationType = [string] $Request.operationType }
    }

    return [pscustomobject]@{
        schemaVersion = '0.1'
        executorResultType = 'deployment-executor-result'
        status = $Status
        sessionId = $sessionId
        itemId = $itemId
        commandId = $commandId
        operationType = $OperationType
        exitStatus = $ExitStatus
        stdout = ''
        stderr = ''
        diagnostic = $Diagnostic
        artifacts = @($Artifacts)
    }
}

function Assert-LocalOperationRequestString {
    param([Parameter(Mandatory = $true)][object] $Object, [Parameter(Mandatory = $true)][string] $Name, [Parameter(Mandatory = $true)][string] $Context)
    if (-not (Test-LocalOperationProperty -Object $Object -Name $Name)) { throw "$Context validation failed: missing required field '$Name'." }
    if (-not ($Object.$Name -is [string])) { throw "$Context validation failed: field '$Name' must be a string." }
    if ([string]::IsNullOrWhiteSpace([string] $Object.$Name)) { throw "$Context validation failed: field '$Name' must not be empty." }
}

function Assert-LocalOperationRequestBool {
    param([Parameter(Mandatory = $true)][object] $Object, [Parameter(Mandatory = $true)][string] $Name, [Parameter(Mandatory = $true)][string] $Context)
    if (-not (Test-LocalOperationProperty -Object $Object -Name $Name)) { throw "$Context validation failed: missing required field '$Name'." }
    if (-not ($Object.$Name -is [bool])) { throw "$Context validation failed: field '$Name' must be boolean." }
}

function Assert-LocalOperationNoSecrets {
    param([Parameter(Mandatory = $true)][object] $Value, [Parameter(Mandatory = $true)][string] $Context)
    $json = $Value | ConvertTo-Json -Depth 100
    if (Test-LocalOperationSecretText -Text $json) { throw "$Context validation failed: secret-like content is not allowed." }
}

function Resolve-LocalOperationDirectory {
    param([Parameter(Mandatory = $true)][string] $Path, [Parameter(Mandatory = $true)][string] $Context)
    if (Test-LocalOperationSecretText -Text $Path -or Test-LocalOperationSecretPath -Path $Path) { throw "$Context validation failed: secret-like path is not allowed." }
    try {
        $resolved = Resolve-LocalOperationPath -Path $Path
    } catch {
        throw "$Context validation failed: path cannot be resolved."
    }
    if (-not (Test-Path -LiteralPath $resolved -PathType Container)) { throw "$Context validation failed: source path must be an existing directory." }
    return [System.IO.Path]::GetFullPath($resolved)
}

function Resolve-LocalOperationArtifactPath {
    param([Parameter(Mandatory = $true)][string] $Path)
    if (Test-LocalOperationSecretText -Text $Path -or Test-LocalOperationSecretPath -Path $Path) { throw 'Archive creation validation failed: secret-like artifact path is not allowed.' }
    try {
        return [System.IO.Path]::GetFullPath((Resolve-LocalOperationPath -Path $Path))
    } catch {
        throw 'Archive creation validation failed: artifact path cannot be resolved.'
    }
}

function Test-PathWithinPath {
    param([Parameter(Mandatory = $true)][string] $ChildPath, [Parameter(Mandatory = $true)][string] $ParentPath)
    $parent = [System.IO.Path]::GetFullPath($ParentPath).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    $child = [System.IO.Path]::GetFullPath($ChildPath).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    return $child.StartsWith($parent, [System.StringComparison]::OrdinalIgnoreCase)
}

function Assert-LocalOperationRequest {
    param([Parameter(Mandatory = $true)][object] $Request)
    Assert-LocalOperationRequestString -Object $Request -Name 'schemaVersion' -Context 'Executor request'
    if ($Request.schemaVersion -ne '0.1') { throw "Executor request validation failed: unsupported schemaVersion '$($Request.schemaVersion)'." }
    Assert-LocalOperationRequestString -Object $Request -Name 'executorRequestType' -Context 'Executor request'
    if ($Request.executorRequestType -ne 'deployment-executor-request') { throw "Executor request validation failed: executorRequestType must be 'deployment-executor-request'." }
    foreach ($field in @('status', 'sessionId', 'itemId', 'commandId', 'operationType', 'actor', 'executionLocation', 'executionMode', 'program')) {
        Assert-LocalOperationRequestString -Object $Request -Name $field -Context 'Executor request'
    }
    if ($Request.status -ne 'disabled') { throw "Executor request validation failed: status must be 'disabled'." }
    if ($Request.actor -ne 'automation') { throw "Executor request validation failed: actor must be 'automation'." }
    if ($Request.executionLocation -ne 'local') { throw "Executor request validation failed: executionLocation must be 'local'." }
    if ($Request.executionMode -ne 'automatic') { throw "Executor request validation failed: executionMode must be 'automatic'." }
    if ($Request.program -ne 'local-operation') { throw "Executor request validation failed: program must be 'local-operation'." }
    if (-not (Test-LocalOperationProperty -Object $Request -Name 'operation') -or -not (Test-LocalOperationObjectLike -Value $Request.operation)) {
        throw 'Executor request validation failed: structured operation data is required.'
    }
    if (Test-LocalOperationProperty -Object $Request -Name 'executionPolicy') {
        foreach ($field in @('processStartAllowed', 'networkAccessAllowed', 'remoteExecutionAllowed')) {
            Assert-LocalOperationRequestBool -Object $Request.executionPolicy -Name $field -Context 'Executor request executionPolicy'
            if ($Request.executionPolicy.$field) { throw "Executor request validation failed: executionPolicy.$field must be false." }
        }
    }
    Assert-LocalOperationNoSecrets -Value $Request -Context 'Executor request'
}

function Get-LocalOperationSourcePath {
    param([Parameter(Mandatory = $true)][object] $Operation, [Parameter(Mandatory = $true)][string] $Context)
    Assert-LocalOperationRequestString -Object $Operation -Name 'sourcePath' -Context $Context
    return Resolve-LocalOperationDirectory -Path ([string] $Operation.sourcePath) -Context $Context
}

function Invoke-SourceValidation {
    param([Parameter(Mandatory = $true)][object] $Request)
    $sourcePath = Get-LocalOperationSourcePath -Operation $Request.operation -Context 'Source validation'
    return New-LocalOperationResult -Status 'completed' -Request $Request -OperationType ([string] $Request.operationType) -ExitStatus 0 -Diagnostic 'Source directory is present and valid.'
}

function Test-ArchiveExcludedFile {
    param([Parameter(Mandatory = $true)][string] $RelativePath)
    $normalized = ConvertTo-PackagingRelativePath -RelativePath $RelativePath
    $parts = @($normalized -split '/')
    foreach ($part in $parts) {
        if ($part -eq '.git') { return $true }
    }
    $leaf = [System.IO.Path]::GetFileName($normalized)
    return ($leaf -match '(?i)^\.env(\..*)?$|^id_rsa$|^id_ed25519$|\.key$|\.pem$')
}

function ConvertTo-PackagingRelativePath {
    param([Parameter(Mandatory = $true)][string] $RelativePath)
    $normalized = ($RelativePath -replace '\\', '/').TrimStart('/')
    while ($normalized.Contains('//')) { $normalized = $normalized.Replace('//', '/') }
    return $normalized
}

function Test-PackagingGlobMatch {
    param([Parameter(Mandatory = $true)][string] $RelativePath, [Parameter(Mandatory = $true)][string] $Pattern)
    $path = ConvertTo-PackagingRelativePath -RelativePath $RelativePath
    $glob = ConvertTo-PackagingRelativePath -RelativePath $Pattern
    if ([string]::IsNullOrWhiteSpace($glob)) { return $false }
    if ($glob -eq '**' -or $glob -eq '*') { return $true }
    if ($glob.EndsWith('/**')) {
        $prefix = $glob.Substring(0, $glob.Length - 3).TrimEnd('/')
        return ($path -eq $prefix -or $path.StartsWith($prefix + '/', [System.StringComparison]::OrdinalIgnoreCase))
    }
    return ($path -like $glob)
}

function Test-PackagingIncludedPath {
    param([Parameter(Mandatory = $true)][string] $RelativePath, [Parameter(Mandatory = $true)][object[]] $IncludedPaths)
    foreach ($pattern in @($IncludedPaths)) {
        if (Test-PackagingGlobMatch -RelativePath $RelativePath -Pattern ([string] $pattern)) { return $true }
    }
    return $false
}

function Test-PackagingExcludedPath {
    param([Parameter(Mandatory = $true)][string] $RelativePath, [Parameter(Mandatory = $true)][object[]] $ExcludedPaths)
    if (Test-ArchiveExcludedFile -RelativePath $RelativePath) { return $true }
    $normalized = ConvertTo-PackagingRelativePath -RelativePath $RelativePath
    $leaf = [System.IO.Path]::GetFileName($normalized)
    if ($leaf -match '(?i)^Thumbs\.db$|^Desktop\.ini$|^\.DS_Store$|^~\$|\.tmp$|\.temp$|\.bak$|\.old$|\.orig$|\.swp$|\.swo$') { return $true }
    foreach ($part in @($normalized -split '/')) {
        if ($part -match '(?i)^\.idea$|^\.vscode$') { return $true }
    }
    foreach ($pattern in @($ExcludedPaths)) {
        if (Test-PackagingGlobMatch -RelativePath $normalized -Pattern ([string] $pattern)) { return $true }
    }
    return $false
}

function Get-PackagingPolicyFingerprint {
    param([Parameter(Mandatory = $true)][object] $Policy)
    $copy = Copy-LocalOperationObject -Value $Policy
    $json = $copy | ConvertTo-Json -Depth 80 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Assert-PackagingPolicyArray {
    param([Parameter(Mandatory = $true)][object] $Policy, [Parameter(Mandatory = $true)][string] $Name)
    if (-not (Test-LocalOperationProperty -Object $Policy -Name $Name)) { throw "Packaging policy validation failed: missing required field '$Name'." }
    if ($Policy.$Name -is [string] -or -not ($Policy.$Name -is [array])) { throw "Packaging policy validation failed: field '$Name' must be an array." }
    foreach ($item in @($Policy.$Name)) {
        if (-not ($item -is [string]) -or [string]::IsNullOrWhiteSpace([string] $item)) { throw "Packaging policy validation failed: field '$Name' must contain non-empty strings." }
        $normalized = ConvertTo-PackagingRelativePath -RelativePath ([string] $item)
        if ($normalized.StartsWith('../') -or $normalized.Contains('/../') -or $normalized -eq '..' -or $normalized -eq '.') {
            throw "Packaging policy validation failed: field '$Name' contains an invalid path segment."
        }
    }
}

function Assert-PackagingPolicy {
    param([Parameter(Mandatory = $true)][object] $Request)
    if (-not (Test-LocalOperationProperty -Object $Request.operation -Name 'packagingPolicy') -or -not (Test-LocalOperationObjectLike -Value $Request.operation.packagingPolicy)) {
        throw 'Packaging policy validation failed: packagingPolicy is required for archive.create.'
    }
    $policy = $Request.operation.packagingPolicy
    foreach ($field in @('policyId', 'projectId', 'artifactType', 'vendorStrategy', 'executionPlanFingerprint')) {
        Assert-LocalOperationRequestString -Object $policy -Name $field -Context 'Packaging policy'
    }
    if (-not (Test-LocalOperationProperty -Object $policy -Name 'createdAt') -or [string]::IsNullOrWhiteSpace([string] $policy.createdAt)) {
        throw "Packaging policy validation failed: field 'createdAt' must not be empty."
    }
    Assert-PackagingPolicyArray -Policy $policy -Name 'includedPaths'
    Assert-PackagingPolicyArray -Policy $policy -Name 'excludedPaths'
    if ($policy.artifactType -ne 'deployment-archive') { throw "Packaging policy validation failed: artifactType must be 'deployment-archive'." }
    if ([string] $policy.executionPlanFingerprint -ne [string] $Request.operation.executionPlanFingerprint) {
        throw 'Packaging policy validation failed: executionPlanFingerprint must match archive.create executionPlanFingerprint.'
    }
    Assert-LocalOperationNoSecrets -Value $policy -Context 'Packaging policy'
    return $policy
}

function New-PackagingValidationSummary {
    param(
        [object[]] $IncludedFiles = @(),
        [object[]] $ExcludedFiles = @()
    )
    $includedSize = 0L
    foreach ($file in @($IncludedFiles)) {
        if (Test-LocalOperationProperty -Object $file -Name 'length') {
            $includedSize += [int64] $file.length
        }
    }
    return [pscustomobject]@{
        includedFileCount = @($IncludedFiles).Count
        excludedFileCount = @($ExcludedFiles).Count
        includedBytes = [int64] $includedSize
    }
}

function Invoke-ArchiveCreation {
    param([Parameter(Mandatory = $true)][object] $Request)
    $sourcePath = Get-LocalOperationSourcePath -Operation $Request.operation -Context 'Archive creation'
    Assert-LocalOperationRequestString -Object $Request.operation -Name 'artifactPath' -Context 'Archive creation'
    Assert-LocalOperationRequestString -Object $Request.operation -Name 'executionPlanFingerprint' -Context 'Archive creation'
    $packagingPolicy = Assert-PackagingPolicy -Request $Request
    $packagingPolicyFingerprint = Get-PackagingPolicyFingerprint -Policy $packagingPolicy
    $artifactPath = Resolve-LocalOperationArtifactPath -Path ([string] $Request.operation.artifactPath)
    if ([string]::Equals($sourcePath.TrimEnd('\', '/'), $artifactPath.TrimEnd('\', '/'), [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Archive creation validation failed: source path and artifact path must be different.'
    }
    if (Test-PathWithinPath -ChildPath $artifactPath -ParentPath $sourcePath) {
        throw 'Archive creation validation failed: artifact path must be outside source path.'
    }
    if (Test-PathWithinPath -ChildPath $sourcePath -ParentPath $artifactPath) {
        throw 'Archive creation validation failed: source path must not be inside artifact path.'
    }
    if (Test-Path -LiteralPath $artifactPath) {
        throw 'Archive creation validation failed: artifact path already exists.'
    }
    $artifactDirectory = Split-Path -Path $artifactPath -Parent
    if ([string]::IsNullOrWhiteSpace($artifactDirectory)) { throw 'Archive creation validation failed: artifact directory is missing.' }
    if (Test-Path -LiteralPath $artifactDirectory -PathType Leaf) { throw 'Archive creation validation failed: artifact directory is not a directory.' }

    try {
        if (-not (Test-Path -LiteralPath $artifactDirectory -PathType Container)) {
            New-Item -ItemType Directory -Path $artifactDirectory -Force | Out-Null
        }
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [System.IO.Compression.ZipFile]::Open($artifactPath, [System.IO.Compression.ZipArchiveMode]::Create)
        try {
            $sourceRoot = [System.IO.Path]::GetFullPath($sourcePath).TrimEnd('\', '/')
            $files = @(Get-ChildItem -LiteralPath $sourceRoot -Recurse -File -Force | Sort-Object FullName)
            $includedFiles = New-Object System.Collections.Generic.List[object]
            $excludedFiles = New-Object System.Collections.Generic.List[object]
            foreach ($file in $files) {
                $relativePath = $file.FullName.Substring($sourceRoot.Length).TrimStart('\', '/')
                $entryName = $relativePath -replace '\\', '/'
                if (-not (Test-PackagingIncludedPath -RelativePath $entryName -IncludedPaths @($packagingPolicy.includedPaths))) { continue }
                if (Test-PackagingExcludedPath -RelativePath $entryName -ExcludedPaths @($packagingPolicy.excludedPaths)) {
                    $excludedFiles.Add([pscustomobject]@{ relativePath = $entryName; length = [int64] $file.Length }) | Out-Null
                    continue
                }
                $includedFiles.Add([pscustomobject]@{ relativePath = $entryName; length = [int64] $file.Length }) | Out-Null
                [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $file.FullName, $entryName, [System.IO.Compression.CompressionLevel]::Optimal) | Out-Null
            }
        } finally {
            $zip.Dispose()
        }
        $validationSummary = New-PackagingValidationSummary -IncludedFiles $includedFiles.ToArray() -ExcludedFiles $excludedFiles.ToArray()
        $runtimeArtifact = New-DeploymentRuntimeArchiveArtifact -ArtifactPath $artifactPath -Request $Request -PackagingPolicy $packagingPolicy -PackagingPolicyFingerprint $packagingPolicyFingerprint -PackagingValidation $validationSummary
        return New-LocalOperationResult -Status 'completed' -Request $Request -OperationType ([string] $Request.operationType) -ExitStatus 0 -Diagnostic 'Archive created.' -Artifacts @($runtimeArtifact)
    } catch {
        return New-LocalOperationResult -Status 'failed' -Request $Request -OperationType ([string] $Request.operationType) -ExitStatus 1 -Diagnostic "Archive creation failed: $($_.Exception.Message)"
    }
}

function New-DeploymentRuntimeArchiveArtifact {
    param(
        [Parameter(Mandatory = $true)][string] $ArtifactPath,
        [Parameter(Mandatory = $true)][object] $Request,
        [Parameter(Mandatory = $true)][object] $PackagingPolicy,
        [Parameter(Mandatory = $true)][string] $PackagingPolicyFingerprint,
        [Parameter(Mandatory = $true)][object] $PackagingValidation
    )

    if (-not (Test-Path -LiteralPath $ArtifactPath -PathType Leaf)) {
        throw "Runtime artifact validation failed: archive file does not exist: $ArtifactPath"
    }
    if (-not (Test-LocalOperationProperty -Object $Request.operation -Name 'executionPlanFingerprint')) {
        throw "Runtime artifact validation failed: executionPlanFingerprint is required."
    }
    $fingerprint = [string] $Request.operation.executionPlanFingerprint
    if ([string]::IsNullOrWhiteSpace($fingerprint)) {
        throw "Runtime artifact validation failed: executionPlanFingerprint must not be empty."
    }
    $file = Get-Item -LiteralPath $ArtifactPath
    $hash = (Get-FileHash -LiteralPath $ArtifactPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $extension = [System.IO.Path]::GetExtension($file.Name).TrimStart('.').ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($extension)) { $extension = 'zip' }

    return [pscustomobject]@{
        artifactId = 'runtime-artifact-' + $hash.Substring(0, 16)
        artifactType = 'deployment-archive'
        archiveFormat = $extension
        localPath = $file.FullName
        fileName = $file.Name
        fileSize = [int64] $file.Length
        hash = $hash
        executionPlanFingerprint = $fingerprint
        packagingPolicyId = [string] $PackagingPolicy.policyId
        packagingPolicyFingerprint = $PackagingPolicyFingerprint
        packagingValidation = $PackagingValidation
        createdAt = (Get-Date).ToUniversalTime().ToString('o')
    }
}

function Invoke-LocalOperationRequest {
    param([Parameter(Mandatory = $true)][object] $ExecutorRequest)
    $request = Copy-LocalOperationObject -Value $ExecutorRequest
    Assert-LocalOperationRequestString -Object $request -Name 'sessionId' -Context 'Executor request'
    try {
        Assert-LocalOperationRequest -Request $request
        switch ($request.operationType) {
            'source.validate' {
                return Invoke-SourceValidation -Request $request
            }
            'archive.create' {
                return Invoke-ArchiveCreation -Request $request
            }
            default {
                throw "Unsupported local operation '$($request.operationType)'."
            }
        }
    } catch {
        return New-LocalOperationResult -Status 'rejected' -Request $request -Diagnostic $_.Exception.Message
    }
}

function Write-LocalOperationResultJson {
    param([Parameter(Mandatory = $true)][object] $Result, [string] $OutputPath)
    $json = $Result | ConvertTo-Json -Depth 100
    if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
        $resolvedOutputPath = Resolve-LocalOperationPath -Path $OutputPath
        $outputDirectory = Split-Path -Path $resolvedOutputPath -Parent
        if (-not [string]::IsNullOrWhiteSpace($outputDirectory)) { New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null }
        $json | Set-Content -LiteralPath $resolvedOutputPath -Encoding utf8
    }
    return $json
}

function Invoke-LocalOperationExecutor {
    param([Parameter(Mandatory = $true)][string] $ExecutorRequestPath, [string] $OutputPath, [string] $Format = 'Json')
    if ($Format -ne 'Json') { throw "execute-local-operation only supports -Format Json." }
    $request = Read-LocalOperationJsonFile -Path $ExecutorRequestPath
    $result = Invoke-LocalOperationRequest -ExecutorRequest $request
    return Write-LocalOperationResultJson -Result $result -OutputPath $OutputPath
}

if (-not $ModuleOnly) {
    if ([string]::IsNullOrWhiteSpace($ExecutorRequestPath)) { throw "Missing required parameter for 'execute-local-operation': -ExecutorRequestPath" }
    Invoke-LocalOperationExecutor -ExecutorRequestPath $ExecutorRequestPath -OutputPath $OutputPath -Format $Format
}
