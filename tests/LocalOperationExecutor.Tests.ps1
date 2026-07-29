[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:failures = New-Object System.Collections.Generic.List[string]
$engineRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '..'))
$executorPath = Join-Path -Path $engineRoot -ChildPath 'src/ps1/Invoke-LocalOperationExecutor.ps1'
$cliPath = Join-Path -Path $engineRoot -ChildPath 'bin/deployment-engine.ps1'

. $executorPath -ModuleOnly

function Assert-True { param([bool] $Condition, [string] $Message) if (-not $Condition) { $script:failures.Add($Message) } }
function Assert-Equal { param($Actual, $Expected, [string] $Message) if ($Actual -ne $Expected) { $script:failures.Add("$Message Expected '$Expected', got '$Actual'.") } }
function Assert-ThrowsLike {
    param([scriptblock] $Script, [string] $Pattern, [string] $Message)
    try { & $Script; $script:failures.Add($Message) } catch { Assert-True ($_.Exception.Message -match $Pattern) "$Message Actual error: $($_.Exception.Message)" }
}

function New-Request {
    param(
        [string] $OperationType = 'source.validate',
        [object] $Operation = ([pscustomobject]@{}),
        [string] $Actor = 'automation',
        [string] $Location = 'local',
        [string] $Mode = 'automatic',
        [string] $Program = 'local-operation',
        [string] $RenderedCommand = '',
        [string] $SessionId = 'session-local-operation-tests'
    )
    return [pscustomobject]@{
        schemaVersion = '0.1'
        executorRequestType = 'deployment-executor-request'
        status = 'disabled'
        sessionId = $SessionId
        itemId = if ($OperationType -eq 'archive.create') { 'archive.create' } else { 'source.validate' }
        commandId = if ($OperationType -eq 'archive.create') { 'archive.create' } else { 'source.validate' }
        operationType = $OperationType
        executorType = 'local-operation'
        actor = $Actor
        executionLocation = $Location
        executionMode = $Mode
        program = $Program
        renderedCommand = $RenderedCommand
        workingDirectory = ''
        arguments = @('do-not-dispatch-from-arguments')
        environment = [pscustomobject]@{}
        operation = $Operation
        executionPolicy = [pscustomobject]@{ processStartAllowed = $false; networkAccessAllowed = $false; remoteExecutionAllowed = $false }
        expectedEvents = [pscustomobject]@{ onStart = 'automation-started'; onResult = 'automation-result' }
        diagnostic = ''
    }
}

function Get-ZipEntries {
    param([Parameter(Mandatory = $true)][string] $Path)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($Path)
    try {
        return @($zip.Entries | ForEach-Object { $_.FullName } | Sort-Object)
    } finally {
        $zip.Dispose()
    }
}

function New-ArchiveOperation {
    param([Parameter(Mandatory = $true)][string] $SourcePath, [Parameter(Mandatory = $true)][string] $ArtifactPath, [string] $ExecutionPlanFingerprint = 'execution-plan-fingerprint-a')
    return [pscustomobject]@{
        sourcePath = $SourcePath
        artifactPath = $ArtifactPath
        executionPlanFingerprint = $ExecutionPlanFingerprint
        packagingPolicy = New-PackagingPolicy -ExecutionPlanFingerprint $ExecutionPlanFingerprint
    }
}

function New-PackagingPolicy {
    param(
        [string] $ExecutionPlanFingerprint = 'execution-plan-fingerprint-a',
        [string[]] $IncludedPaths = @('**'),
        [string[]] $ExcludedPaths = @(
            'storage/app/private/**',
            'storage/logs/**',
            'storage/framework/cache/**',
            'storage/framework/sessions/**',
            'storage/framework/views/**',
            'tests/**',
            'node_modules/**',
            'vendor/**',
            'deployment-runs/**',
            '.deployment/**',
            '.git/**'
        )
    )
    return [pscustomobject]@{
        policyId = 'packaging-policy-test'
        projectId = 'demo-project'
        artifactType = 'deployment-archive'
        vendorStrategy = 'exclude-install-on-target-from-lockfiles'
        includedPaths = @($IncludedPaths)
        excludedPaths = @($ExcludedPaths)
        executionPlanFingerprint = $ExecutionPlanFingerprint
        createdAt = '2026-07-28T12:00:00Z'
    }
}

$tmp = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('local-operation-executor-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    $source = Join-Path -Path $tmp -ChildPath 'source'
    $nested = Join-Path -Path $source -ChildPath 'nested'
    $gitDir = Join-Path -Path $source -ChildPath '.git'
    New-Item -ItemType Directory -Path $nested, $gitDir | Out-Null
    Set-Content -LiteralPath (Join-Path -Path $source -ChildPath 'index.php') -Value 'hello' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path -Path $nested -ChildPath 'view.txt') -Value 'view' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path -Path $source -ChildPath '.env') -Value 'APP_KEY=hidden' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path -Path $source -ChildPath '.env.local') -Value 'APP_KEY=hidden' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path -Path $source -ChildPath 'deploy.pem') -Value 'hidden' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path -Path $source -ChildPath 'id_rsa') -Value 'hidden' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path -Path $gitDir -ChildPath 'config') -Value 'hidden' -Encoding UTF8
    foreach ($excludedDir in @(
        'storage/app/private',
        'storage/logs',
        'storage/framework/cache',
        'storage/framework/sessions',
        'storage/framework/views',
        'tests',
        'node_modules/pkg',
        'vendor/pkg',
        'deployment-runs/run-1',
        '.deployment/uploads/run-1',
        '.idea',
        '.vscode'
    )) {
        New-Item -ItemType Directory -Path (Join-Path -Path $source -ChildPath $excludedDir) -Force | Out-Null
        Set-Content -LiteralPath (Join-Path -Path $source -ChildPath (Join-Path $excludedDir 'excluded.txt')) -Value 'excluded' -Encoding UTF8
    }
    Set-Content -LiteralPath (Join-Path -Path $source -ChildPath 'Thumbs.db') -Value 'os' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path -Path $source -ChildPath 'notes.tmp') -Value 'temp' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path -Path $source -ChildPath 'local.bak') -Value 'backup' -Encoding UTF8

    $validSourceRequest = New-Request -Operation ([pscustomobject]@{ sourcePath = $source })
    $sourceBefore = @(Get-ChildItem -LiteralPath $source -Recurse -Force | ForEach-Object { $_.FullName } | Sort-Object)
    $sourceResult = Invoke-LocalOperationRequest -ExecutorRequest $validSourceRequest
    $sourceAfter = @(Get-ChildItem -LiteralPath $source -Recurse -Force | ForEach-Object { $_.FullName } | Sort-Object)
    Assert-Equal $sourceResult.status 'completed' 'Existing source directory must complete.'
    Assert-Equal $sourceResult.sessionId 'session-local-operation-tests' 'Completed source validation result must contain request sessionId.'
    Assert-Equal $sourceResult.exitStatus 0 'Completed source validation must return exit status 0.'
    Assert-Equal ($sourceBefore -join "`n") ($sourceAfter -join "`n") 'Source validation must not change files.'
    Assert-Equal (Invoke-LocalOperationRequest -ExecutorRequest $validSourceRequest | ConvertTo-Json -Depth 100) ($sourceResult | ConvertTo-Json -Depth 100) 'Executor output must be deterministic.'

    $requestBefore = $validSourceRequest | ConvertTo-Json -Depth 100
    Invoke-LocalOperationRequest -ExecutorRequest $validSourceRequest | Out-Null
    Assert-Equal ($validSourceRequest | ConvertTo-Json -Depth 100) $requestBefore 'Executor must not mutate request input.'

    $failedDirectResult = New-LocalOperationResult -Status 'failed' -Request $validSourceRequest -OperationType 'source.validate' -ExitStatus 1 -Diagnostic 'failed'
    Assert-Equal $failedDirectResult.sessionId 'session-local-operation-tests' 'Failed result must contain request sessionId.'

    $missing = Invoke-LocalOperationRequest -ExecutorRequest (New-Request -Operation ([pscustomobject]@{ sourcePath = (Join-Path $tmp 'missing') }))
    Assert-Equal $missing.status 'rejected' 'Missing source path must be rejected.'
    Assert-Equal $missing.sessionId 'session-local-operation-tests' 'Rejected result must contain request sessionId.'
    $filePath = Join-Path -Path $tmp -ChildPath 'file.txt'
    Set-Content -LiteralPath $filePath -Value 'file' -Encoding UTF8
    $fileResult = Invoke-LocalOperationRequest -ExecutorRequest (New-Request -Operation ([pscustomobject]@{ sourcePath = $filePath }))
    Assert-Equal $fileResult.status 'rejected' 'File source path must be rejected.'

    Push-Location $tmp
    try {
        $relativeResult = Invoke-LocalOperationRequest -ExecutorRequest (New-Request -Operation ([pscustomobject]@{ sourcePath = 'source' }))
        Assert-Equal $relativeResult.status 'completed' 'Relative source path must be resolved in a controlled way.'
    } finally {
        Pop-Location
    }

    $secretResult = Invoke-LocalOperationRequest -ExecutorRequest (New-Request -Operation ([pscustomobject]@{ sourcePath = 'token=abc' }))
    Assert-Equal $secretResult.status 'rejected' 'Secret-like source input must be rejected.'

    $unknown = Invoke-LocalOperationRequest -ExecutorRequest (New-Request -OperationType 'unknown.operation' -Operation ([pscustomobject]@{ sourcePath = $source }))
    Assert-Equal $unknown.status 'rejected' 'Unknown operation must be rejected.'
    $humanCommandResult = Invoke-LocalOperationRequest -ExecutorRequest (New-Request -Actor 'human-command' -Operation ([pscustomobject]@{ sourcePath = $source }))
    Assert-Equal $humanCommandResult.status 'rejected' 'Human command request must be rejected.'
    $remoteResult = Invoke-LocalOperationRequest -ExecutorRequest (New-Request -Location 'remote' -Operation ([pscustomobject]@{ sourcePath = $source }))
    Assert-Equal $remoteResult.status 'rejected' 'Remote execution request must be rejected.'
    $wrongProgramResult = Invoke-LocalOperationRequest -ExecutorRequest (New-Request -Program 'other-program' -Operation ([pscustomobject]@{ sourcePath = $source }))
    Assert-Equal $wrongProgramResult.status 'rejected' 'Wrong program type must be rejected.'
    $renderedOnly = New-Request -Operation ([pscustomobject]@{}) -RenderedCommand "sourcePath=$source"
    Assert-Equal (Invoke-LocalOperationRequest -ExecutorRequest $renderedOnly).status 'rejected' 'Rendered command must not be interpreted as operation data.'

    $artifact = Join-Path -Path $tmp -ChildPath 'artifacts/deployment.zip'
    $archiveRequest = New-Request -OperationType 'archive.create' -Operation (New-ArchiveOperation -SourcePath $source -ArtifactPath $artifact)
    $archiveResult = Invoke-LocalOperationRequest -ExecutorRequest $archiveRequest
    Assert-Equal $archiveResult.status 'completed' 'Valid archive request must complete.'
    Assert-Equal $archiveResult.sessionId 'session-local-operation-tests' 'Completed archive result must contain request sessionId.'
    Assert-Equal @($archiveResult.artifacts).Count 1 'Archive result must contain exactly one artifact.'
    $archiveArtifact = @($archiveResult.artifacts | Select-Object -First 1)
    if ($archiveArtifact.Count -eq 1) {
        Assert-Equal $archiveArtifact[0].artifactType 'deployment-archive' 'Archive artifact type must describe a deployment archive.'
        Assert-Equal $archiveArtifact[0].archiveFormat 'zip' 'Archive format must be zip.'
        Assert-Equal $archiveArtifact[0].localPath ([System.IO.Path]::GetFullPath($artifact)) 'Archive artifact path must be resolved.'
        Assert-Equal $archiveArtifact[0].fileName 'deployment.zip' 'Archive artifact file name must be preserved without directory.'
        Assert-True ([int64] $archiveArtifact[0].fileSize -gt 0) 'Archive artifact file size must be recorded.'
        Assert-True ([string] $archiveArtifact[0].hash -match '^[a-f0-9]{64}$') 'Archive artifact must contain SHA-256 hash.'
        Assert-Equal $archiveArtifact[0].executionPlanFingerprint 'execution-plan-fingerprint-a' 'Archive artifact must be bound to execution plan fingerprint.'
        Assert-Equal $archiveArtifact[0].packagingPolicyId 'packaging-policy-test' 'Archive artifact must be bound to packaging policy id.'
        Assert-True ([string] $archiveArtifact[0].packagingPolicyFingerprint -match '^[a-f0-9]{64}$') 'Archive artifact must contain packaging policy fingerprint.'
        Assert-True ([int64] $archiveArtifact[0].packagingValidation.includedFileCount -gt 0) 'Archive artifact must contain packaging included file count.'
        Assert-True ([int64] $archiveArtifact[0].packagingValidation.excludedFileCount -gt 0) 'Archive artifact must contain packaging excluded file count.'
        Assert-True (-not [string]::IsNullOrWhiteSpace([string] $archiveArtifact[0].createdAt)) 'Archive artifact creation timestamp must be recorded.'
    }
    Assert-True (Test-Path -LiteralPath $artifact -PathType Leaf) 'Archive file must be created.'
    $entries = Get-ZipEntries -Path $artifact
    Assert-True ($entries -contains 'index.php') 'ZIP must contain expected root file.'
    Assert-True ($entries -contains 'nested/view.txt') 'ZIP must contain expected nested file.'
    foreach ($blocked in @(
        '.env',
        '.env.local',
        '.git/config',
        'deploy.pem',
        'id_rsa',
        'storage/app/private/excluded.txt',
        'storage/logs/excluded.txt',
        'storage/framework/cache/excluded.txt',
        'storage/framework/sessions/excluded.txt',
        'storage/framework/views/excluded.txt',
        'tests/excluded.txt',
        'node_modules/pkg/excluded.txt',
        'vendor/pkg/excluded.txt',
        'deployment-runs/run-1/excluded.txt',
        '.deployment/uploads/run-1/excluded.txt',
        '.idea/excluded.txt',
        '.vscode/excluded.txt',
        'Thumbs.db',
        'notes.tmp',
        'local.bak'
    )) {
        Assert-True (-not ($entries -contains $blocked)) "ZIP must exclude '$blocked'."
    }

    $existing = Invoke-LocalOperationRequest -ExecutorRequest $archiveRequest
    Assert-Equal $existing.status 'rejected' 'Existing target archive must be rejected.'
    $missingFingerprintArtifact = Join-Path -Path $tmp -ChildPath 'artifacts/missing-fingerprint.zip'
    $missingFingerprint = Invoke-LocalOperationRequest -ExecutorRequest (New-Request -OperationType 'archive.create' -Operation ([pscustomobject]@{ sourcePath = $source; artifactPath = $missingFingerprintArtifact; packagingPolicy = New-PackagingPolicy }))
    Assert-Equal $missingFingerprint.status 'rejected' 'Archive creation without executionPlanFingerprint must be rejected before producing reusable runtime artifact.'
    $missingPolicyArtifact = Join-Path -Path $tmp -ChildPath 'artifacts/missing-policy.zip'
    $missingPolicy = Invoke-LocalOperationRequest -ExecutorRequest (New-Request -OperationType 'archive.create' -Operation ([pscustomobject]@{ sourcePath = $source; artifactPath = $missingPolicyArtifact; executionPlanFingerprint = 'execution-plan-fingerprint-a' }))
    Assert-Equal $missingPolicy.status 'rejected' 'Archive creation without packaging policy must be rejected.'
    $wrongPolicyArtifact = Join-Path -Path $tmp -ChildPath 'artifacts/wrong-policy.zip'
    $wrongPolicy = Invoke-LocalOperationRequest -ExecutorRequest (New-Request -OperationType 'archive.create' -Operation ([pscustomobject]@{ sourcePath = $source; artifactPath = $wrongPolicyArtifact; executionPlanFingerprint = 'execution-plan-fingerprint-a'; packagingPolicy = New-PackagingPolicy -ExecutionPlanFingerprint 'other-fingerprint' }))
    Assert-Equal $wrongPolicy.status 'rejected' 'Packaging policy with wrong executionPlanFingerprint must be rejected.'
    $inside = Invoke-LocalOperationRequest -ExecutorRequest (New-Request -OperationType 'archive.create' -Operation (New-ArchiveOperation -SourcePath $source -ArtifactPath (Join-Path $source 'inside.zip')))
    Assert-Equal $inside.status 'rejected' 'Artifact path inside source must be rejected.'
    $badDirFile = Join-Path -Path $tmp -ChildPath 'bad-parent'
    Set-Content -LiteralPath $badDirFile -Value 'not a directory' -Encoding UTF8
    $badDir = Invoke-LocalOperationRequest -ExecutorRequest (New-Request -OperationType 'archive.create' -Operation (New-ArchiveOperation -SourcePath $source -ArtifactPath (Join-Path $badDirFile 'out.zip')))
    Assert-True ($badDir.status -in @('rejected', 'failed')) 'Invalid target directory must be rejected or failed.'

    $missingSessionRequest = New-Request -Operation ([pscustomobject]@{ sourcePath = $source })
    $missingSessionRequest.PSObject.Properties.Remove('sessionId')
    Assert-ThrowsLike -Script { Invoke-LocalOperationRequest -ExecutorRequest $missingSessionRequest | Out-Null } -Pattern 'sessionId' -Message 'Request without sessionId must not be processed as valid executor request.'
    Assert-ThrowsLike -Script { Invoke-LocalOperationRequest -ExecutorRequest (New-Request -Operation ([pscustomobject]@{ sourcePath = $source }) -SessionId '') | Out-Null } -Pattern 'sessionId' -Message 'Request with empty sessionId must be rejected structurally.'
    Assert-ThrowsLike -Script { Invoke-LocalOperationRequest -ExecutorRequest (New-Request -Operation ([pscustomobject]@{ sourcePath = $source }) -SessionId '   ') | Out-Null } -Pattern 'sessionId' -Message 'Request with whitespace sessionId must be rejected structurally.'

    $requestPath = Join-Path -Path $tmp -ChildPath 'executor-request.json'
    $resultPath = Join-Path -Path $tmp -ChildPath 'executor-result.json'
    $validSourceRequest | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $requestPath -Encoding UTF8
    Assert-ThrowsLike -Script { & $cliPath execute-local-operation -Format Json | Out-Null } -Pattern 'ExecutorRequestPath' -Message 'CLI must require ExecutorRequestPath.'
    Assert-ThrowsLike -Script { & $cliPath execute-local-operation -ExecutorRequestPath $requestPath -Format Text | Out-Null } -Pattern 'only supports -Format Json' -Message 'CLI must reject non-Json format.'
    $fileCountBeforeStdout = @(Get-ChildItem -LiteralPath $tmp -File -Recurse).Count
    $stdoutJson = & $cliPath execute-local-operation -ExecutorRequestPath $requestPath -Format Json
    $fileCountAfterStdout = @(Get-ChildItem -LiteralPath $tmp -File -Recurse).Count
    $stdoutResult = $stdoutJson | ConvertFrom-Json
    Assert-Equal $stdoutResult.executorResultType 'deployment-executor-result' 'CLI without OutputPath must emit parseable JSON.'
    Assert-Equal @($stdoutJson).Count 1 'CLI without OutputPath must not emit additional stdout lines.'
    Assert-Equal $fileCountAfterStdout $fileCountBeforeStdout 'CLI without OutputPath must not create files.'
    & $cliPath execute-local-operation -ExecutorRequestPath $requestPath -OutputPath $resultPath -Format Json | Out-Null
    Assert-True (Test-Path -LiteralPath $resultPath -PathType Leaf) 'CLI with OutputPath must write exactly the explicit output file.'
    Assert-Equal (Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json).status 'completed' 'CLI output file must contain executor result.'
} finally {
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
}

$sourceText = Get-Content -LiteralPath $executorPath -Raw
foreach ($forbidden in @('Invoke-Expression', 'Start-Process', 'cmd.exe', 'powershell.exe', 'pwsh.exe', 'Invoke-Command', 'New-PSSession', 'Enter-PSSession', 'System.Diagnostics.Process', 'ProcessStartInfo', 'Apply-CommandSessionEvent')) {
    Assert-True (-not ($sourceText -match [regex]::Escape($forbidden))) "Local operation executor source must not contain forbidden token '$forbidden'."
}
foreach ($forbiddenWord in @('ssh', 'scp')) {
    Assert-True (-not ($sourceText -match "(?i)\b$forbiddenWord\b")) "Local operation executor source must not contain forbidden word '$forbiddenWord'."
}

if ($script:failures.Count -gt 0) {
    Write-Host 'Local Operation Executor tests failed:'
    $script:failures | ForEach-Object { Write-Host "- $_" }
    exit 1
}

Write-Host 'Local Operation Executor tests passed.'
exit 0
