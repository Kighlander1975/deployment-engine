[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:failures = New-Object System.Collections.Generic.List[string]
$engineRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '..'))
$cliPath = Join-Path -Path $engineRoot -ChildPath 'bin/deployment-engine.ps1'

function Assert-True { param([bool] $Condition, [string] $Message) if (-not $Condition) { $script:failures.Add($Message) } }
function Assert-Equal { param($Actual, $Expected, [string] $Message) if ($Actual -ne $Expected) { $script:failures.Add("$Message Expected '$Expected', got '$Actual'.") } }

function Invoke-TestGit {
    param([Parameter(Mandatory = $true)][string] $RepositoryPath, [Parameter(Mandatory = $true)][string[]] $Arguments)
    $output = & git -C $RepositoryPath @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw (($output | ForEach-Object { [string] $_ }) -join ' ') }
    return $output
}

function New-TestRepository {
    param([Parameter(Mandatory = $true)][string] $RootPath, [Parameter(Mandatory = $true)][string] $Name)
    $repo = Join-Path -Path $RootPath -ChildPath $Name
    New-Item -ItemType Directory -Path $repo | Out-Null
    Invoke-TestGit -RepositoryPath $repo -Arguments @('init') | Out-Null
    Invoke-TestGit -RepositoryPath $repo -Arguments @('config', 'user.email', 'deployment-engine@example.invalid') | Out-Null
    Invoke-TestGit -RepositoryPath $repo -Arguments @('config', 'user.name', 'Deployment Engine Tests') | Out-Null
    Set-Content -LiteralPath (Join-Path -Path $repo -ChildPath 'hello.txt') -Value 'hello' -Encoding UTF8
    Invoke-TestGit -RepositoryPath $repo -Arguments @('add', 'hello.txt') | Out-Null
    Invoke-TestGit -RepositoryPath $repo -Arguments @('commit', '-m', 'initial') | Out-Null
    return $repo
}

function New-TestCommand {
    param(
        [string] $Id,
        [int] $Sequence,
        [string] $OperationType,
        [string[]] $DependsOn = @(),
        [object] $Operation
    )
    return [pscustomobject]@{
        commandId = $Id
        sequence = $Sequence
        strategyStepId = $Id
        operationType = $OperationType
        actor = 'automation'
        executionLocation = 'local'
        executionMode = 'automatic'
        dependsOn = @($DependsOn)
        program = 'local-operation'
        arguments = @($OperationType)
        workingDirectory = ''
        environment = [pscustomobject]@{}
        operation = $Operation
        renderedCommand = ''
        display = [pscustomobject]@{ title = $Id; description = ''; copyable = $false }
        feedback = [pscustomobject]@{ required = $false; expectedData = @() }
        safety = [pscustomobject]@{ destructive = $false; containsSecret = $false; requiresApproval = $false; executionPermitted = $false }
        diagnostic = ''
    }
}

function New-TestPackagingPolicy {
    return [pscustomobject]@{
        policyId = 'packaging-policy-failure-paths'
        projectId = 'failure-paths'
        artifactType = 'deployment-archive'
        vendorStrategy = 'exclude-install-on-target-from-lockfiles'
        includedPaths = @('**')
        excludedPaths = @('storage/**', 'vendor/**', 'node_modules/**', 'tests/**', '.git/**', '.deployment/**', 'deployment-runs/**')
        executionPlanFingerprint = 'execution-plan-fingerprint-failure-paths'
        createdAt = '2026-07-28T12:00:00Z'
    }
}

function New-TestCommandPlan {
    param([Parameter(Mandatory = $true)][string] $SourcePath, [bool] $IncludeHumanGate = $true, [bool] $IncludePostApproval = $true)
    $commands = @(
        New-TestCommand -Id 'source.validate' -Sequence 100 -OperationType 'source.validate' -Operation ([pscustomobject]@{ sourcePath = $SourcePath })
        New-TestCommand -Id 'archive.create' -Sequence 200 -OperationType 'archive.create' -DependsOn @('source.validate') -Operation ([pscustomobject]@{ sourcePath = $SourcePath; artifactPath = ''; executionPlanFingerprint = 'execution-plan-fingerprint-failure-paths'; packagingPolicy = New-TestPackagingPolicy })
    )
    $humanGates = @()
    if ($IncludeHumanGate) {
        $humanGates = @([pscustomobject]@{ gateId = 'deployment.approval'; stepId = 'deployment.approval'; sequence = 300; dependsOn = @('archive.create'); gateType = 'approval'; blocksContinuation = $true; allowedResponses = @('approved', 'rejected') })
        if ($IncludePostApproval) {
            $commands += New-TestCommand -Id 'post.approval.source.validate' -Sequence 400 -OperationType 'source.validate' -DependsOn @('deployment.approval') -Operation ([pscustomobject]@{ sourcePath = $SourcePath })
        }
    }

    return [pscustomobject]@{
        schemaVersion = '0.1'
        commandPlanType = 'deployment-command-plan'
        status = 'ready'
        sourceStrategyType = 'deployment'
        selectedAdapterId = 'archive.zip'
        executionPolicy = [pscustomobject]@{ executionAllowed = $false; automaticExecutionAllowed = $false; remoteExecutionMode = 'copy-and-run' }
        commands = @($commands)
        humanGates = @($humanGates)
        diagnostic = ''
    }
}

function Save-Json {
    param([Parameter(Mandatory = $true)][object] $Value, [Parameter(Mandatory = $true)][string] $Path)
    $Value | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Read-Json {
    param([Parameter(Mandatory = $true)][string] $Path)
    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Get-RuntimeFileNames {
    param([Parameter(Mandatory = $true)][string] $RuntimeDirectory)
    return @(Get-ChildItem -LiteralPath $RuntimeDirectory -Recurse -File | ForEach-Object { $_.FullName.Substring($RuntimeDirectory.Length) } | Sort-Object)
}

function Get-LatestSessionPath {
    param([Parameter(Mandatory = $true)][string] $RuntimeDirectory)
    $sessions = @()
    foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $RuntimeDirectory 'decisions') -Filter 'command-session-*.json' -File)) {
        if ($file.Name -match '^command-session-(\d{4})(?:-(started|external|result))?\.json$') {
            $suffix = if ($Matches.Count -gt 2) { [string] $Matches[2] } else { '' }
            $rank = switch ($suffix) { 'started' { 1 } 'external' { 2 } 'result' { 3 } default { 0 } }
            $sessions += [pscustomobject]@{ path = $file.FullName; index = [int] $Matches[1]; rank = $rank }
        }
    }
    return [string] (@($sessions | Sort-Object index, rank, path | Select-Object -Last 1)[0].path)
}

function New-ApprovalEvent {
    param([string] $SessionId, [string] $EventId = 'failure-path-approval', [string] $EventType = 'human-decision-submitted')
    return [pscustomobject]@{
        schemaVersion = '0.1'
        sessionId = $SessionId
        eventId = $EventId
        eventType = $EventType
        targetItemId = 'deployment.approval'
        decision = [pscustomobject]@{ value = 'approved' }
    }
}

function Invoke-ResumeCli {
    param([Parameter(Mandatory = $true)][string] $RuntimeDirectory, [Parameter(Mandatory = $true)][string] $EventPath)
    $json = & $cliPath resume-local-execution -RuntimeDirectoryPath $RuntimeDirectory -SessionEventPath $EventPath -Format Json
    $exitCode = $LASTEXITCODE
    return [pscustomobject]@{ exitCode = $exitCode; json = ($json -join [Environment]::NewLine); result = (($json -join [Environment]::NewLine) | ConvertFrom-Json) }
}

function New-PausedRun {
    param([Parameter(Mandatory = $true)][string] $Tmp, [Parameter(Mandatory = $true)][string] $Name, [bool] $IncludeHumanGate = $true, [bool] $IncludePostApproval = $true)
    $repo = New-TestRepository -RootPath $Tmp -Name "$Name-repo"
    $runtimeRoot = Join-Path -Path $Tmp -ChildPath "$Name-runs"
    New-Item -ItemType Directory -Path $runtimeRoot | Out-Null
    $planPath = Join-Path -Path $Tmp -ChildPath "$Name-command-plan.json"
    Save-Json -Value (New-TestCommandPlan -SourcePath $repo -IncludeHumanGate:$IncludeHumanGate -IncludePostApproval:$IncludePostApproval) -Path $planPath
    $startJson = & $cliPath orchestrate-local-execution -CommandPlanPath $planPath -SourceRepositoryPath $repo -RuntimeRootPath $runtimeRoot -Format Json
    if ($LASTEXITCODE -ne 0) { throw "orchestrate-local-execution failed for $Name." }
    $start = $startJson | ConvertFrom-Json
    return [pscustomobject]@{ repo = $repo; runtimeRoot = $runtimeRoot; planPath = $planPath; summary = $start; runtimeDirectory = [string] $start.runtimeDirectory }
}

function Invoke-RejectedResumeCase {
    param(
        [Parameter(Mandatory = $true)][string] $Tmp,
        [Parameter(Mandatory = $true)][string] $Name,
        [Parameter(Mandatory = $true)][scriptblock] $MutateRuntime,
        [string] $DiagnosticPattern = ''
    )
    $run = New-PausedRun -Tmp $Tmp -Name $Name
    $session = Read-Json -Path (Get-LatestSessionPath -RuntimeDirectory $run.runtimeDirectory)
    $eventPath = Join-Path -Path $Tmp -ChildPath "$Name-event.json"
    Save-Json -Value (New-ApprovalEvent -SessionId ([string] $session.sessionId) -EventId "$Name-event") -Path $eventPath
    & $MutateRuntime $run $eventPath
    $summaryBefore = Get-Content -LiteralPath (Join-Path $run.runtimeDirectory 'reports/execution-summary.json') -Raw
    $latestSessionPathBefore = if (@(Get-ChildItem -LiteralPath (Join-Path $run.runtimeDirectory 'decisions') -Filter 'command-session-*.json' -File).Count -gt 0) { Get-LatestSessionPath -RuntimeDirectory $run.runtimeDirectory } else { '' }
    $sessionBefore = if (-not [string]::IsNullOrWhiteSpace($latestSessionPathBefore)) { Get-Content -LiteralPath $latestSessionPathBefore -Raw } else { '' }
    $filesBefore = Get-RuntimeFileNames -RuntimeDirectory $run.runtimeDirectory
    $resume = Invoke-ResumeCli -RuntimeDirectory $run.runtimeDirectory -EventPath $eventPath
    Assert-Equal $resume.result.status 'rejected' "$Name must return rejected."
    Assert-Equal $resume.exitCode 1 "$Name CLI must return non-zero for rejected resume."
    Assert-True (-not [string]::IsNullOrWhiteSpace([string] $resume.result.diagnostic)) "$Name must provide a diagnostic."
    if (-not [string]::IsNullOrWhiteSpace($DiagnosticPattern)) {
        Assert-True ([string] $resume.result.diagnostic -match $DiagnosticPattern) "$Name diagnostic must match '$DiagnosticPattern'. Actual: $($resume.result.diagnostic)"
    }
    Assert-Equal (Get-Content -LiteralPath (Join-Path $run.runtimeDirectory 'reports/execution-summary.json') -Raw) $summaryBefore "$Name must not overwrite the existing summary on rejection."
    if (-not [string]::IsNullOrWhiteSpace($latestSessionPathBefore) -and (Test-Path -LiteralPath $latestSessionPathBefore -PathType Leaf)) {
        Assert-Equal (Get-Content -LiteralPath $latestSessionPathBefore -Raw) $sessionBefore "$Name must leave the latest session snapshot unchanged."
    }
    Assert-Equal @(Get-ChildItem -LiteralPath (Join-Path $run.runtimeDirectory 'events') -Filter 'external-session-event-*.json' -File).Count 0 "$Name must not archive the external event on rejection."
    Assert-Equal @(Get-ChildItem -LiteralPath (Join-Path $run.runtimeDirectory 'decisions') -Filter 'executor-request-0004.json' -File).Count 0 "$Name must not create post-rejection executor requests."
    $filesAfter = Get-RuntimeFileNames -RuntimeDirectory $run.runtimeDirectory
    foreach ($file in $filesBefore) { Assert-True ($file -in $filesAfter) "$Name must preserve runtime artifact '$file'." }
}

$tmp = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('execution-failure-paths-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    Invoke-RejectedResumeCase -Tmp $tmp -Name 'bad-summary-json' -DiagnosticPattern 'Invalid Execution summary JSON' -MutateRuntime {
        param($Run, $EventPath)
        Set-Content -LiteralPath (Join-Path $Run.runtimeDirectory 'reports/execution-summary.json') -Value '{ bad json' -Encoding UTF8
    }

    Invoke-RejectedResumeCase -Tmp $tmp -Name 'missing-session-snapshot' -DiagnosticPattern 'no command-session snapshot' -MutateRuntime {
        param($Run, $EventPath)
        Get-ChildItem -LiteralPath (Join-Path $Run.runtimeDirectory 'decisions') -Filter 'command-session-*.json' -File | Remove-Item -Force
    }

    Invoke-RejectedResumeCase -Tmp $tmp -Name 'wrong-event-session' -DiagnosticPattern 'sessionId' -MutateRuntime {
        param($Run, $EventPath)
        Save-Json -Value (New-ApprovalEvent -SessionId 'session-other' -EventId 'wrong-event-session') -Path $EventPath
    }

    Invoke-RejectedResumeCase -Tmp $tmp -Name 'duplicate-event-id' -DiagnosticPattern 'already applied' -MutateRuntime {
        param($Run, $EventPath)
        $existing = Read-Json -Path (Join-Path $Run.runtimeDirectory 'events/automation-started-0001.json')
        $session = Read-Json -Path (Get-LatestSessionPath -RuntimeDirectory $Run.runtimeDirectory)
        Save-Json -Value (New-ApprovalEvent -SessionId ([string] $session.sessionId) -EventId ([string] $existing.eventId)) -Path $EventPath
    }

    $completedRun = New-PausedRun -Tmp $tmp -Name 'resume-completed'
    $completedSession = Read-Json -Path (Get-LatestSessionPath -RuntimeDirectory $completedRun.runtimeDirectory)
    $completedEventPath = Join-Path -Path $tmp -ChildPath 'resume-completed-event.json'
    Save-Json -Value (New-ApprovalEvent -SessionId ([string] $completedSession.sessionId) -EventId 'resume-completed-approval') -Path $completedEventPath
    $completedResume = Invoke-ResumeCli -RuntimeDirectory $completedRun.runtimeDirectory -EventPath $completedEventPath
    Assert-Equal $completedResume.result.status 'completed' 'Fixture resume must complete before terminal-resume rejection check.'
    $terminalSession = Read-Json -Path (Get-LatestSessionPath -RuntimeDirectory $completedRun.runtimeDirectory)
    $terminalEventPath = Join-Path -Path $tmp -ChildPath 'resume-completed-again-event.json'
    Save-Json -Value (New-ApprovalEvent -SessionId ([string] $terminalSession.sessionId) -EventId 'resume-completed-again') -Path $terminalEventPath
    $terminalAgain = Invoke-ResumeCli -RuntimeDirectory $completedRun.runtimeDirectory -EventPath $terminalEventPath
    Assert-Equal $terminalAgain.result.status 'rejected' 'Resume on completed runtime must be rejected.'
    Assert-Equal $terminalAgain.exitCode 1 'Resume on completed runtime must return non-zero.'
    Assert-True ($terminalAgain.result.diagnostic -match 'waiting-for-human|terminal') "Resume on completed runtime must explain terminal or non-waiting state. Actual: $($terminalAgain.result.diagnostic)"

    Invoke-RejectedResumeCase -Tmp $tmp -Name 'not-paused-session' -DiagnosticPattern 'currentItemId|expect human|requires' -MutateRuntime {
        param($Run, $EventPath)
        $sessionPath = Get-LatestSessionPath -RuntimeDirectory $Run.runtimeDirectory
        $session = Read-Json -Path $sessionPath
        $session.currentItemId = ''
        Save-Json -Value $session -Path $sessionPath
        $summaryPath = Join-Path $Run.runtimeDirectory 'reports/execution-summary.json'
        $summary = Read-Json -Path $summaryPath
        $summary.currentItemId = ''
        Save-Json -Value $summary -Path $summaryPath
    }

    Invoke-RejectedResumeCase -Tmp $tmp -Name 'invalid-event-type' -DiagnosticPattern 'unsupported external event type' -MutateRuntime {
        param($Run, $EventPath)
        $session = Read-Json -Path (Get-LatestSessionPath -RuntimeDirectory $Run.runtimeDirectory)
        Save-Json -Value (New-ApprovalEvent -SessionId ([string] $session.sessionId) -EventId 'invalid-event-type' -EventType 'automation-started') -Path $EventPath
    }

    Invoke-RejectedResumeCase -Tmp $tmp -Name 'apply-rejects-valid-event' -DiagnosticPattern 'review-result requires review item' -MutateRuntime {
        param($Run, $EventPath)
        $session = Read-Json -Path (Get-LatestSessionPath -RuntimeDirectory $Run.runtimeDirectory)
        Save-Json -Value ([pscustomobject]@{
            schemaVersion = '0.1'
            sessionId = [string] $session.sessionId
            eventId = 'apply-rejects-valid-event'
            eventType = 'review-result'
            targetItemId = 'deployment.approval'
            review = [pscustomobject]@{ status = 'approved' }
        }) -Path $EventPath
    }

    $artifactRun = New-PausedRun -Tmp $tmp -Name 'existing-artifact-slot'
    $artifactSession = Read-Json -Path (Get-LatestSessionPath -RuntimeDirectory $artifactRun.runtimeDirectory)
    $artifactEventPath = Join-Path -Path $tmp -ChildPath 'existing-artifact-slot-event.json'
    Save-Json -Value (New-ApprovalEvent -SessionId ([string] $artifactSession.sessionId) -EventId 'existing-artifact-slot-event') -Path $artifactEventPath
    $preexistingAdmissionPath = Join-Path $artifactRun.runtimeDirectory 'decisions/execution-admission-0004.json'
    Set-Content -LiteralPath $preexistingAdmissionPath -Value '{"preexisting":true}' -Encoding UTF8
    $artifactResume = Invoke-ResumeCli -RuntimeDirectory $artifactRun.runtimeDirectory -EventPath $artifactEventPath
    Assert-Equal $artifactResume.result.status 'completed' 'Resume must continue without overwriting an already present numbered artifact slot.'
    Assert-Equal ((Get-Content -LiteralPath $preexistingAdmissionPath -Raw).Trim()) '{"preexisting":true}' 'Preexisting artifact slot must not be overwritten.'
    Assert-True (Test-Path -LiteralPath (Join-Path $artifactRun.runtimeDirectory 'decisions/execution-admission-0006.json') -PathType Leaf) 'Resume must continue numbering after the preexisting artifact slot.'

    Invoke-RejectedResumeCase -Tmp $tmp -Name 'inconsistent-effective-plan' -DiagnosticPattern 'Current item|not present|depends' -MutateRuntime {
        param($Run, $EventPath)
        $planPath = Join-Path $Run.runtimeDirectory 'decisions/command-plan-effective.json'
        $plan = Read-Json -Path $planPath
        $plan.humanGates[0].gateId = 'other.approval'
        Save-Json -Value $plan -Path $planPath
    }

    Invoke-RejectedResumeCase -Tmp $tmp -Name 'wrong-summary-session' -DiagnosticPattern 'summary sessionId' -MutateRuntime {
        param($Run, $EventPath)
        $summaryPath = Join-Path $Run.runtimeDirectory 'reports/execution-summary.json'
        $summary = Read-Json -Path $summaryPath
        $summary.sessionId = 'session-other'
        Save-Json -Value $summary -Path $summaryPath
    }

    Invoke-RejectedResumeCase -Tmp $tmp -Name 'invalid-event-json' -DiagnosticPattern 'Invalid External command session event JSON' -MutateRuntime {
        param($Run, $EventPath)
        Set-Content -LiteralPath $EventPath -Value '{ event' -Encoding UTF8
    }

    $missingArgumentOutput = & pwsh -NoProfile -ExecutionPolicy Bypass -File $cliPath resume-local-execution -RuntimeDirectoryPath (Join-Path $tmp 'missing-runtime') -Format Json 2>&1
    $missingArgumentExitCode = $LASTEXITCODE
    Assert-True ($missingArgumentExitCode -ne 0) 'CLI must return non-zero for a technical missing-parameter violation.'
    Assert-True (($missingArgumentOutput | Out-String) -match 'SessionEventPath') 'CLI technical input violation must identify the missing parameter.'
} finally {
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
}

if ($script:failures.Count -gt 0) {
    Write-Host 'Execution Failure Paths tests failed:'
    $script:failures | ForEach-Object { Write-Host "- $_" }
    exit 1
}

Write-Host 'Execution Failure Paths tests passed.'
exit 0
