[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:failures = New-Object System.Collections.Generic.List[string]
$engineRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '..'))
$sessionPath = Join-Path -Path $engineRoot -ChildPath 'src/ps1/CommandSession.ps1'
$requestPath = Join-Path -Path $engineRoot -ChildPath 'src/ps1/Build-ExecutorRequest.ps1'
$cliPath = Join-Path -Path $engineRoot -ChildPath 'bin/deployment-engine.ps1'

. $sessionPath
. $requestPath -ModuleOnly

function Assert-True { param([bool] $Condition, [string] $Message) if (-not $Condition) { $script:failures.Add($Message) } }
function Assert-Equal { param($Actual, $Expected, [string] $Message) if ($Actual -ne $Expected) { $script:failures.Add("$Message Expected '$Expected', got '$Actual'.") } }
function Assert-ThrowsLike {
    param([scriptblock] $Script, [string] $Pattern, [string] $Message)
    try { & $Script; $script:failures.Add($Message) } catch { Assert-True ($_.Exception.Message -match $Pattern) "$Message Actual error: $($_.Exception.Message)" }
}

function New-TestCommand {
    param([string] $Id, [int] $Sequence, [string] $Actor, [string] $Location, [string] $Mode, [string] $Program, [string[]] $DependsOn = @(), [string] $RenderedCommand = '')
    return [pscustomobject]@{
        commandId = $Id
        sequence = $Sequence
        strategyStepId = $Id
        operationType = $Id
        actor = $Actor
        executionLocation = $Location
        executionMode = $Mode
        dependsOn = @($DependsOn)
        program = $Program
        arguments = if ($Program -eq 'local-operation') { @($Id) } else { @() }
        workingDirectory = ''
        environment = [pscustomobject]@{}
        operation = if ($Id -eq 'source.validate') { [pscustomobject]@{ sourcePath = 'D:\Projects\demo' } } else { [pscustomobject]@{} }
        renderedCommand = $RenderedCommand
        display = [pscustomobject]@{ title = $Id; description = ''; copyable = ($Actor -eq 'human-command') }
        feedback = [pscustomobject]@{ required = ($Actor -eq 'human-command'); expectedData = if ($Actor -eq 'human-command') { @('exitStatus', 'stdout', 'stderr') } else { @() } }
        safety = [pscustomobject]@{ destructive = $false; containsSecret = $false; requiresApproval = $false; executionPermitted = $false }
        diagnostic = ''
    }
}

function New-TestCommandPlan {
    return [pscustomobject]@{
        schemaVersion = '0.1'
        commandPlanType = 'deployment-command-plan'
        status = 'ready'
        sourceStrategyType = 'deployment'
        selectedAdapterId = 'archive.zip'
        executionPolicy = [pscustomobject]@{ executionAllowed = $false; automaticExecutionAllowed = $false; remoteExecutionMode = 'copy-and-run' }
        commands = @(
            New-TestCommand -Id 'source.validate' -Sequence 100 -Actor 'automation' -Location 'local' -Mode 'automatic' -Program 'local-operation'
            New-TestCommand -Id 'archive.create' -Sequence 300 -Actor 'automation' -Location 'local' -Mode 'automatic' -Program 'local-operation' -DependsOn @('source.validate')
            New-TestCommand -Id 'artifact.upload' -Sequence 600 -Actor 'human-command' -Location 'artifact-transport' -Mode 'copy-and-run' -Program 'network-share' -DependsOn @('deployment.approval') -RenderedCommand 'Copy-Item -LiteralPath artifact.zip -Destination D:\\Share\\.deployment\\uploads\\artifact.zip'
        )
        humanGates = @(
            [pscustomobject]@{ gateId = 'deployment.approval'; stepId = 'deployment.approval'; sequence = 400; dependsOn = @('archive.create'); gateType = 'approval'; blocksContinuation = $true; allowedResponses = @('approved', 'rejected') }
        )
        diagnostic = ''
    }
}

function New-Event {
    param([string] $Id, [string] $Type, [string] $Target, [object] $Payload)
    $event = [pscustomobject]@{ schemaVersion = '0.1'; eventId = $Id; eventType = $Type; targetItemId = $Target }
    if ($null -ne $Payload) {
        foreach ($property in $Payload.PSObject.Properties) { Add-Member -InputObject $event -MemberType NoteProperty -Name $property.Name -Value $property.Value }
    }
    return $event
}

function Complete-Automation {
    param([object] $Session, [string] $ItemId, [string] $Prefix)
    $started = Apply-CommandSessionEvent -CommandSession $Session -Event (New-Event -Id "$Prefix-start" -Type 'automation-started' -Target $ItemId -Payload $null)
    return Apply-CommandSessionEvent -CommandSession $started -Event (New-Event -Id "$Prefix-result" -Type 'automation-result' -Target $ItemId -Payload ([pscustomobject]@{ result = [pscustomobject]@{ status = 'completed'; diagnostic = '' } }))
}

$plan = New-TestCommandPlan
$session = New-CommandSession -CommandPlan $plan
$admission = Resolve-ExecutionAdmission -CommandPlan $plan -CommandSession $session
$planBefore = $plan | ConvertTo-Json -Depth 100
$sessionBefore = $session | ConvertTo-Json -Depth 100
$admissionBefore = $admission | ConvertTo-Json -Depth 100
$request = Resolve-ExecutorRequest -CommandPlan $plan -CommandSession $session -ExecutionAdmission $admission
Assert-Equal $request.executorRequestType 'deployment-executor-request' 'Executor request type must be correct.'
Assert-Equal $request.status 'disabled' 'Valid local automation must create a disabled request.'
Assert-Equal $request.sessionId $session.sessionId 'Executor request must copy command session sessionId.'
Assert-Equal $request.itemId 'source.validate' 'Request item id must match admission current item.'
Assert-Equal $request.commandId 'source.validate' 'Request command id must match command plan.'
Assert-Equal $request.operationType 'source.validate' 'Request operation type must be explicit.'
Assert-Equal $request.operation.sourcePath 'D:\Projects\demo' 'Request must carry structured operation data.'
Assert-Equal $request.executorType 'local-operation' 'Executor type must remain local-operation.'
Assert-Equal $request.executionPolicy.processStartAllowed $false 'Process start must remain disabled.'
Assert-Equal $request.executionPolicy.networkAccessAllowed $false 'Network access must remain disabled.'
Assert-Equal $request.executionPolicy.remoteExecutionAllowed $false 'Remote execution must remain disabled.'
Assert-Equal $request.expectedEvents.onStart 'automation-started' 'Request must declare automation start event.'
Assert-Equal $request.expectedEvents.onResult 'automation-result' 'Request must declare automation result event.'
Assert-Equal (($request.arguments) -join ',') 'source.validate' 'Request must carry structured arguments.'
Assert-Equal ($plan | ConvertTo-Json -Depth 100) $planBefore 'Executor request must not mutate command plan.'
Assert-Equal ($session | ConvertTo-Json -Depth 100) $sessionBefore 'Executor request must not mutate command session.'
Assert-Equal ($admission | ConvertTo-Json -Depth 100) $admissionBefore 'Executor request must not mutate admission.'
Assert-Equal (Resolve-ExecutorRequest -CommandPlan $plan -CommandSession $session -ExecutionAdmission $admission | ConvertTo-Json -Depth 100) ($request | ConvertTo-Json -Depth 100) 'Executor request output must be deterministic.'

$tamperedAdmission = Copy-ExecutorRequestObject -Value $admission
$tamperedAdmission.decision.executionEligible = $false
Assert-ThrowsLike -Script { Resolve-ExecutorRequest -CommandPlan $plan -CommandSession $session -ExecutionAdmission $tamperedAdmission | Out-Null } -Pattern 'executionEligible must be true|does not match' -Message 'Manipulated admission must be rejected.'
$admittedAdmission = Copy-ExecutorRequestObject -Value $admission
$admittedAdmission.decision.executionAdmitted = $true
Assert-ThrowsLike -Script { Resolve-ExecutorRequest -CommandPlan $plan -CommandSession $session -ExecutionAdmission $admittedAdmission | Out-Null } -Pattern 'executionAdmitted must remain false|does not match' -Message 'Admission with executionAdmitted true must be rejected.'
$wrongItemAdmission = Copy-ExecutorRequestObject -Value $admission
$wrongItemAdmission.currentItemId = 'archive.create'
Assert-ThrowsLike -Script { Resolve-ExecutorRequest -CommandPlan $plan -CommandSession $session -ExecutionAdmission $wrongItemAdmission | Out-Null } -Pattern 'does not match' -Message 'Wrong admission currentItemId must be rejected.'
$wrongCommandAdmission = Copy-ExecutorRequestObject -Value $admission
$wrongCommandAdmission.commandId = 'archive.create'
Assert-ThrowsLike -Script { Resolve-ExecutorRequest -CommandPlan $plan -CommandSession $session -ExecutionAdmission $wrongCommandAdmission | Out-Null } -Pattern 'does not match|commandId must match' -Message 'Wrong admission commandId must be rejected.'

$readyForApproval = Complete-Automation -Session (Complete-Automation -Session $session -ItemId 'source.validate' -Prefix 'approval-source') -ItemId 'archive.create' -Prefix 'approval-archive'
$humanAdmission = Resolve-ExecutionAdmission -CommandPlan $plan -CommandSession $readyForApproval
Assert-ThrowsLike -Script { Resolve-ExecutorRequest -CommandPlan $plan -CommandSession $readyForApproval -ExecutionAdmission $humanAdmission | Out-Null } -Pattern "status must be 'eligible-but-disabled'" -Message 'Human decision admission must be rejected.'
$approved = Apply-CommandSessionEvent -CommandSession $readyForApproval -Event (New-Event -Id 'approve' -Type 'human-decision-submitted' -Target 'deployment.approval' -Payload ([pscustomobject]@{ decision = [pscustomobject]@{ value = 'approved' } }))
$humanCommandAdmission = Resolve-ExecutionAdmission -CommandPlan $plan -CommandSession $approved
Assert-ThrowsLike -Script { Resolve-ExecutorRequest -CommandPlan $plan -CommandSession $approved -ExecutionAdmission $humanCommandAdmission | Out-Null } -Pattern "status must be 'eligible-but-disabled'" -Message 'Human command admission must be rejected.'

$remotePlan = Copy-ExecutorRequestObject -Value $plan
$remotePlan.commands[0].executionLocation = 'remote'
$remoteAdmission = Resolve-ExecutionAdmission -CommandPlan $remotePlan -CommandSession $session
Assert-ThrowsLike -Script { Resolve-ExecutorRequest -CommandPlan $remotePlan -CommandSession $session -ExecutionAdmission $remoteAdmission | Out-Null } -Pattern "status must be 'eligible-but-disabled'" -Message 'Remote automation must be rejected.'
$remoteProgramPlan = Copy-ExecutorRequestObject -Value $plan
$remoteProgramPlan.commands[0].program = 'interactive-ssh'
$remoteProgramAdmission = Resolve-ExecutionAdmission -CommandPlan $remoteProgramPlan -CommandSession $session
Assert-ThrowsLike -Script { Resolve-ExecutorRequest -CommandPlan $remoteProgramPlan -CommandSession $session -ExecutionAdmission $remoteProgramAdmission | Out-Null } -Pattern "status must be 'eligible-but-disabled'" -Message 'Remote execution automation must be rejected.'
$enabledPlan = Copy-ExecutorRequestObject -Value $plan
$enabledPlan.executionPolicy.executionAllowed = $true
Assert-ThrowsLike -Script { Resolve-ExecutorRequest -CommandPlan $enabledPlan -CommandSession $session -ExecutionAdmission $admission | Out-Null } -Pattern 'execution must remain disabled' -Message 'Plan with enabled execution must be rejected.'
$notReadySession = Apply-CommandSessionEvent -CommandSession $session -Event (New-Event -Id 'source-start' -Type 'automation-started' -Target 'source.validate' -Payload $null)
$notReadyAdmission = Copy-ExecutorRequestObject -Value $admission
Assert-ThrowsLike -Script { Resolve-ExecutorRequest -CommandPlan $plan -CommandSession $notReadySession -ExecutionAdmission $notReadyAdmission | Out-Null } -Pattern 'does not match command plan and command session' -Message 'No-longer-ready session item must be rejected.'
$inconsistentSession = Copy-ExecutorRequestObject -Value $session
$inconsistentSession.items[1].sequence = 301
Assert-ThrowsLike -Script { Resolve-ExecutorRequest -CommandPlan $plan -CommandSession $inconsistentSession -ExecutionAdmission $admission | Out-Null } -Pattern 'does not match command plan and command session' -Message 'Inconsistent plan/session data must be rejected.'
$secretAdmission = Copy-ExecutorRequestObject -Value $admission
$secretAdmission.diagnostic = 'token=secret'
Assert-ThrowsLike -Script { Resolve-ExecutorRequest -CommandPlan $plan -CommandSession $session -ExecutionAdmission $secretAdmission | Out-Null } -Pattern 'secret-like content' -Message 'Secret-like admission content must be rejected.'

$source = Get-Content -LiteralPath $requestPath -Raw
foreach ($forbidden in @('Start-Process', 'Invoke-Expression', 'System.Diagnostics.Process', 'ProcessStartInfo', 'Invoke-Command', 'New-PSSession', 'ssh.exe', 'scp.exe', 'Apply-CommandSessionEvent', 'New-Event')) {
    Assert-True (-not ($source -match [regex]::Escape($forbidden))) "Executor request source must not contain forbidden token '$forbidden'."
}

$tmp = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('executor-request-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    $planPath = Join-Path -Path $tmp -ChildPath 'command-plan.json'
    $sessionPathInput = Join-Path -Path $tmp -ChildPath 'command-session.json'
    $admissionPathInput = Join-Path -Path $tmp -ChildPath 'execution-admission.json'
    $outputPath = Join-Path -Path $tmp -ChildPath 'nested/executor-request.json'
    $plan | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $planPath -Encoding UTF8
    $session | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $sessionPathInput -Encoding UTF8
    $admission | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $admissionPathInput -Encoding UTF8
    $fileCountBeforeStdout = @(Get-ChildItem -LiteralPath $tmp -File -Recurse).Count
    $stdoutJson = & $cliPath build-executor-request -CommandPlanPath $planPath -CommandSessionPath $sessionPathInput -ExecutionAdmissionPath $admissionPathInput -Format Json
    $fileCountAfterStdout = @(Get-ChildItem -LiteralPath $tmp -File -Recurse).Count
    $stdoutRequest = $stdoutJson | ConvertFrom-Json
    Assert-Equal $stdoutRequest.executorRequestType 'deployment-executor-request' 'CLI without OutputPath must emit parseable JSON.'
    Assert-Equal @($stdoutJson).Count 1 'CLI without OutputPath must not emit additional stdout lines.'
    Assert-Equal $fileCountAfterStdout $fileCountBeforeStdout 'CLI without OutputPath must not create files.'
    & $cliPath build-executor-request -CommandPlanPath $planPath -CommandSessionPath $sessionPathInput -ExecutionAdmissionPath $admissionPathInput -OutputPath $outputPath -Format Json | Out-Null
    Assert-True (Test-Path -LiteralPath $outputPath -PathType Leaf) 'CLI with OutputPath must create explicit output file.'
    Assert-Equal (Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json).status 'disabled' 'CLI output must be disabled executor request.'
} finally {
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
}

if ($script:failures.Count -gt 0) {
    Write-Host 'Executor Request tests failed:'
    $script:failures | ForEach-Object { Write-Host "- $_" }
    exit 1
}

Write-Host 'Executor Request tests passed.'
exit 0
