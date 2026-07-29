[CmdletBinding()]
param(
    [Parameter(Position = 0, Mandatory = $true)]
    [ValidateSet('plan', 'discover-projects', 'resolve-project', 'discover-tools', 'remote-discovery-plan', 'resolve-remote-discovery', 'assess-tool-inventories', 'evaluate-adapter-eligibility', 'select-adapter', 'build-deployment-strategy', 'generate-commands', 'create-command-session', 'update-command-session', 'evaluate-execution-admission', 'build-executor-request', 'execute-local-operation', 'build-automation-started-event', 'build-automation-result-event', 'create-runtime-directory', 'assess-clean-tree', 'orchestrate-local-execution', 'resume-local-execution', 'build-runtime-artifact-reconciliation')]
    [string] $Command,

    [string] $Analysis,

    [string] $Manifest,

    [string] $TargetPath,

    [string] $ProjectPath,

    [string] $ProjectsRoot,

    [string] $ProjectIdentifier,

    [string] $RuntimeRootPath,

    [string] $RuntimeDirectoryPath,

    [string] $RepositoryPath,

    [string] $SourceRepositoryPath,

    [int] $MaxAutomationSteps = 50,

    [string] $Platform,

    [string] $PlanPath,

    [string] $ResponsePath,

    [string] $LocalInventoryPath,

    [string] $RemoteInventoryPath,

    [string] $AssessmentPath,

    [string] $EligibilityPath,

    [string] $ExecutionPlanPath,

    [string] $AdapterSelectionPath,

    [string] $DeploymentStrategyPath,

    [string] $RuntimeArtifactPath,

    [string] $PreviousRuntimeArtifactPath,

    [string] $ReplacementRuntimeArtifactPath,

    [string] $PackagingPolicyPath,

    [string] $DeploymentRunId,

    [string] $CurrentStep,

    [string] $CurrentStatus,

    [string] $ReconciledBy,

    [string] $CommandPlanPath,

    [string] $CommandSessionPath,

    [string] $ExecutionAdmissionPath,

    [string] $ExecutorRequestPath,

    [string] $ExecutorResultPath,

    [string] $SessionEventPath,

    [string] $Timestamp,

    [string] $Format,

    [string] $OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$engineRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '..'))

switch ($Command) {
    'discover-projects' {
        if ([string]::IsNullOrWhiteSpace($Format)) {
            $Format = 'Json'
        }
        if ($Format -ne 'Json') {
            throw "discover-projects only supports -Format Json."
        }
        if ([string]::IsNullOrWhiteSpace($ProjectsRoot)) {
            throw "Missing required parameter for 'discover-projects': -ProjectsRoot"
        }

        $catalogPath = Join-Path -Path $engineRoot -ChildPath 'src/ps1/ProjectCatalog/ProjectCatalog.ps1'
        & $catalogPath -Operation Discover -ProjectsRoot $ProjectsRoot -Format Json -OutputPath $OutputPath
    }
    'resolve-project' {
        if ([string]::IsNullOrWhiteSpace($Format)) {
            $Format = 'Json'
        }
        if ($Format -ne 'Json') {
            throw "resolve-project only supports -Format Json."
        }
        if ([string]::IsNullOrWhiteSpace($ProjectsRoot)) {
            throw "Missing required parameter for 'resolve-project': -ProjectsRoot"
        }
        if ([string]::IsNullOrWhiteSpace($ProjectIdentifier)) {
            throw "Missing required parameter for 'resolve-project': -ProjectIdentifier"
        }

        $catalogPath = Join-Path -Path $engineRoot -ChildPath 'src/ps1/ProjectCatalog/ProjectCatalog.ps1'
        & $catalogPath -Operation Resolve -ProjectsRoot $ProjectsRoot -ProjectIdentifier $ProjectIdentifier -Format Json -OutputPath $OutputPath
    }
    'plan' {
        if ([string]::IsNullOrWhiteSpace($Format)) {
            $planFormat = 'Text'
        } elseif ($Format -eq 'Json') {
            $planFormat = 'Json'
        } elseif ($Format -eq 'Text') {
            $planFormat = 'Text'
        } else {
            throw "plan supports -Format Text or Json."
        }
        if ([string]::IsNullOrWhiteSpace($Analysis)) {
            throw "Missing required parameter for 'plan': -Analysis"
        }
        if ([string]::IsNullOrWhiteSpace($Manifest)) {
            throw "Missing required parameter for 'plan': -Manifest"
        }

        if ([string]::IsNullOrWhiteSpace($TargetPath)) {
            throw "Missing required parameter for 'plan': -TargetPath"
        }

        $builderPath = Join-Path -Path $engineRoot -ChildPath 'src/ps1/Invoke-ExecutionPlanBuild.ps1'
        & $builderPath -AnalysisPath $Analysis -ProjectManifestPath $Manifest -TargetPath $TargetPath -Format $planFormat -OutputPath $OutputPath
        exit $LASTEXITCODE
    }
    'discover-tools' {
        if ([string]::IsNullOrWhiteSpace($Format)) {
            $Format = 'Json'
        }
        if ($Format -ne 'Json') {
            throw "discover-tools only supports -Format Json."
        }

        $discoveryPath = Join-Path -Path $engineRoot -ChildPath 'src/ps1/Invoke-ToolDiscovery.ps1'
        & $discoveryPath -ProjectPath $ProjectPath -Format Json -OutputPath $OutputPath
        exit 0
    }
    'remote-discovery-plan' {
        if ([string]::IsNullOrWhiteSpace($Format)) {
            $Format = 'Json'
        }
        if ($Format -ne 'Json') {
            throw "remote-discovery-plan only supports -Format Json."
        }
        if ([string]::IsNullOrWhiteSpace($Platform)) {
            throw "Missing required parameter for 'remote-discovery-plan': -Platform"
        }
        if ([string]::IsNullOrWhiteSpace($ExecutionPlanPath)) {
            throw "Missing required parameter for 'remote-discovery-plan': -ExecutionPlanPath"
        }

        $remotePlanPath = Join-Path -Path $engineRoot -ChildPath 'src/ps1/New-RemoteToolDiscoveryPlan.ps1'
        & $remotePlanPath -Platform $Platform -ProjectPath $ProjectPath -ExecutionPlanPath $ExecutionPlanPath -Format Json -OutputPath $OutputPath
        exit 0
    }
    'resolve-remote-discovery' {
        if ([string]::IsNullOrWhiteSpace($Format)) {
            $Format = 'Json'
        }
        if ($Format -ne 'Json') {
            throw "resolve-remote-discovery only supports -Format Json."
        }
        if ([string]::IsNullOrWhiteSpace($PlanPath)) {
            throw "Missing required parameter for 'resolve-remote-discovery': -PlanPath"
        }
        if ([string]::IsNullOrWhiteSpace($ResponsePath)) {
            throw "Missing required parameter for 'resolve-remote-discovery': -ResponsePath"
        }

        $remoteResolvePath = Join-Path -Path $engineRoot -ChildPath 'src/ps1/Resolve-RemoteToolDiscovery.ps1'
        & $remoteResolvePath -PlanPath $PlanPath -ResponsePath $ResponsePath -Format Json -OutputPath $OutputPath
        exit 0
    }
    'assess-tool-inventories' {
        if ([string]::IsNullOrWhiteSpace($Format)) {
            $Format = 'Json'
        }
        if ($Format -ne 'Json') {
            throw "assess-tool-inventories only supports -Format Json."
        }
        if ([string]::IsNullOrWhiteSpace($LocalInventoryPath) -and [string]::IsNullOrWhiteSpace($RemoteInventoryPath)) {
            throw "Missing required parameter for 'assess-tool-inventories': provide -LocalInventoryPath, -RemoteInventoryPath, or both."
        }

        $assessmentPath = Join-Path -Path $engineRoot -ChildPath 'src/ps1/Resolve-ToolInventoryAssessment.ps1'
        & $assessmentPath -LocalInventoryPath $LocalInventoryPath -RemoteInventoryPath $RemoteInventoryPath -Format Json -OutputPath $OutputPath
        exit 0
    }
    'evaluate-adapter-eligibility' {
        if ([string]::IsNullOrWhiteSpace($Format)) {
            $Format = 'Json'
        }
        if ($Format -ne 'Json') {
            throw "evaluate-adapter-eligibility only supports -Format Json."
        }
        if ([string]::IsNullOrWhiteSpace($AssessmentPath)) {
            throw "Missing required parameter for 'evaluate-adapter-eligibility': -AssessmentPath"
        }

        $eligibilityPath = Join-Path -Path $engineRoot -ChildPath 'src/ps1/Resolve-AdapterEligibility.ps1'
        & $eligibilityPath -AssessmentPath $AssessmentPath -Format Json -OutputPath $OutputPath
        exit 0
    }
    'select-adapter' {
        if ([string]::IsNullOrWhiteSpace($Format)) {
            $Format = 'Json'
        }
        if ($Format -ne 'Json') {
            throw "select-adapter only supports -Format Json."
        }
        if ([string]::IsNullOrWhiteSpace($EligibilityPath)) {
            throw "Missing required parameter for 'select-adapter': -EligibilityPath"
        }

        $selectionPath = Join-Path -Path $engineRoot -ChildPath 'src/ps1/Select-DeploymentAdapter.ps1'
        & $selectionPath -EligibilityPath $EligibilityPath -Format Json -OutputPath $OutputPath
        exit 0
    }
    'build-deployment-strategy' {
        if ([string]::IsNullOrWhiteSpace($Format)) {
            $Format = 'Json'
        }
        if ($Format -ne 'Json') {
            throw "build-deployment-strategy only supports -Format Json."
        }
        if ([string]::IsNullOrWhiteSpace($ExecutionPlanPath)) {
            throw "Missing required parameter for 'build-deployment-strategy': -ExecutionPlanPath"
        }
        if ([string]::IsNullOrWhiteSpace($AdapterSelectionPath)) {
            throw "Missing required parameter for 'build-deployment-strategy': -AdapterSelectionPath"
        }

        $strategyPath = Join-Path -Path $engineRoot -ChildPath 'src/ps1/Build-DeploymentStrategy.ps1'
        & $strategyPath -ExecutionPlanPath $ExecutionPlanPath -AdapterSelectionPath $AdapterSelectionPath -Format Json -OutputPath $OutputPath
        exit 0
    }
    'generate-commands' {
        if ([string]::IsNullOrWhiteSpace($Format)) {
            $Format = 'Json'
        }
        if ($Format -ne 'Json') {
            throw "generate-commands only supports -Format Json."
        }
        if ([string]::IsNullOrWhiteSpace($ExecutionPlanPath)) {
            throw "Missing required parameter for 'generate-commands': -ExecutionPlanPath"
        }
        if ([string]::IsNullOrWhiteSpace($DeploymentStrategyPath)) {
            throw "Missing required parameter for 'generate-commands': -DeploymentStrategyPath"
        }

        $commandPlanPath = Join-Path -Path $engineRoot -ChildPath 'src/ps1/Build-CommandPlan.ps1'
        & $commandPlanPath -ExecutionPlanPath $ExecutionPlanPath -DeploymentStrategyPath $DeploymentStrategyPath -RuntimeArtifactPath $RuntimeArtifactPath -PackagingPolicyPath $PackagingPolicyPath -DeploymentRunId $DeploymentRunId -Format Json -OutputPath $OutputPath
        exit 0
    }
    'create-command-session' {
        if ([string]::IsNullOrWhiteSpace($Format)) {
            $Format = 'Json'
        }
        if ($Format -ne 'Json') {
            throw "create-command-session only supports -Format Json."
        }
        if ([string]::IsNullOrWhiteSpace($CommandPlanPath)) {
            throw "Missing required parameter for 'create-command-session': -CommandPlanPath"
        }

        $sessionPath = Join-Path -Path $engineRoot -ChildPath 'src/ps1/CommandSession.ps1'
        & $sessionPath -Operation Create -CommandPlanPath $CommandPlanPath -Format Json -OutputPath $OutputPath
        exit 0
    }
    'update-command-session' {
        if ([string]::IsNullOrWhiteSpace($Format)) {
            $Format = 'Json'
        }
        if ($Format -ne 'Json') {
            throw "update-command-session only supports -Format Json."
        }
        if ([string]::IsNullOrWhiteSpace($CommandSessionPath)) {
            throw "Missing required parameter for 'update-command-session': -CommandSessionPath"
        }
        if ([string]::IsNullOrWhiteSpace($SessionEventPath)) {
            throw "Missing required parameter for 'update-command-session': -SessionEventPath"
        }

        $sessionPath = Join-Path -Path $engineRoot -ChildPath 'src/ps1/CommandSession.ps1'
        & $sessionPath -Operation Update -CommandSessionPath $CommandSessionPath -SessionEventPath $SessionEventPath -Format Json -OutputPath $OutputPath
        exit 0
    }
    'evaluate-execution-admission' {
        if ([string]::IsNullOrWhiteSpace($Format)) {
            $Format = 'Json'
        }
        if ($Format -ne 'Json') {
            throw "evaluate-execution-admission only supports -Format Json."
        }
        if ([string]::IsNullOrWhiteSpace($CommandPlanPath)) {
            throw "Missing required parameter for 'evaluate-execution-admission': -CommandPlanPath"
        }
        if ([string]::IsNullOrWhiteSpace($CommandSessionPath)) {
            throw "Missing required parameter for 'evaluate-execution-admission': -CommandSessionPath"
        }

        $admissionPath = Join-Path -Path $engineRoot -ChildPath 'src/ps1/Evaluate-ExecutionAdmission.ps1'
        & $admissionPath -CommandPlanPath $CommandPlanPath -CommandSessionPath $CommandSessionPath -Format Json -OutputPath $OutputPath
        exit 0
    }
    'build-executor-request' {
        if ([string]::IsNullOrWhiteSpace($Format)) {
            $Format = 'Json'
        }
        if ($Format -ne 'Json') {
            throw "build-executor-request only supports -Format Json."
        }
        if ([string]::IsNullOrWhiteSpace($CommandPlanPath)) {
            throw "Missing required parameter for 'build-executor-request': -CommandPlanPath"
        }
        if ([string]::IsNullOrWhiteSpace($CommandSessionPath)) {
            throw "Missing required parameter for 'build-executor-request': -CommandSessionPath"
        }
        if ([string]::IsNullOrWhiteSpace($ExecutionAdmissionPath)) {
            throw "Missing required parameter for 'build-executor-request': -ExecutionAdmissionPath"
        }

        $executorRequestPath = Join-Path -Path $engineRoot -ChildPath 'src/ps1/Build-ExecutorRequest.ps1'
        & $executorRequestPath -CommandPlanPath $CommandPlanPath -CommandSessionPath $CommandSessionPath -ExecutionAdmissionPath $ExecutionAdmissionPath -Format Json -OutputPath $OutputPath
        exit 0
    }
    'execute-local-operation' {
        if ([string]::IsNullOrWhiteSpace($Format)) {
            $Format = 'Json'
        }
        if ($Format -ne 'Json') {
            throw "execute-local-operation only supports -Format Json."
        }
        if ([string]::IsNullOrWhiteSpace($ExecutorRequestPath)) {
            throw "Missing required parameter for 'execute-local-operation': -ExecutorRequestPath"
        }

        $localExecutorPath = Join-Path -Path $engineRoot -ChildPath 'src/ps1/Invoke-LocalOperationExecutor.ps1'
        & $localExecutorPath -ExecutorRequestPath $ExecutorRequestPath -Format Json -OutputPath $OutputPath
        exit 0
    }
    'build-automation-started-event' {
        if ([string]::IsNullOrWhiteSpace($Format)) {
            $Format = 'Json'
        }
        if ($Format -ne 'Json') {
            throw "build-automation-started-event only supports -Format Json."
        }
        if ([string]::IsNullOrWhiteSpace($CommandSessionPath)) {
            throw "Missing required parameter for 'build-automation-started-event': -CommandSessionPath"
        }
        if ([string]::IsNullOrWhiteSpace($ExecutorRequestPath)) {
            throw "Missing required parameter for 'build-automation-started-event': -ExecutorRequestPath"
        }
        if ([string]::IsNullOrWhiteSpace($Timestamp)) {
            throw "Missing required parameter for 'build-automation-started-event': -Timestamp"
        }

        $automationEventPath = Join-Path -Path $engineRoot -ChildPath 'src/ps1/Build-AutomationEvent.ps1'
        & $automationEventPath -Operation Started -CommandSessionPath $CommandSessionPath -ExecutorRequestPath $ExecutorRequestPath -Timestamp $Timestamp -Format Json -OutputPath $OutputPath
        exit 0
    }
    'build-automation-result-event' {
        if ([string]::IsNullOrWhiteSpace($Format)) {
            $Format = 'Json'
        }
        if ($Format -ne 'Json') {
            throw "build-automation-result-event only supports -Format Json."
        }
        if ([string]::IsNullOrWhiteSpace($CommandSessionPath)) {
            throw "Missing required parameter for 'build-automation-result-event': -CommandSessionPath"
        }
        if ([string]::IsNullOrWhiteSpace($ExecutorRequestPath)) {
            throw "Missing required parameter for 'build-automation-result-event': -ExecutorRequestPath"
        }
        if ([string]::IsNullOrWhiteSpace($ExecutorResultPath)) {
            throw "Missing required parameter for 'build-automation-result-event': -ExecutorResultPath"
        }
        if ([string]::IsNullOrWhiteSpace($Timestamp)) {
            throw "Missing required parameter for 'build-automation-result-event': -Timestamp"
        }

        $automationEventPath = Join-Path -Path $engineRoot -ChildPath 'src/ps1/Build-AutomationEvent.ps1'
        & $automationEventPath -Operation Result -CommandSessionPath $CommandSessionPath -ExecutorRequestPath $ExecutorRequestPath -ExecutorResultPath $ExecutorResultPath -Timestamp $Timestamp -Format Json -OutputPath $OutputPath
        exit 0
    }
    'create-runtime-directory' {
        if ([string]::IsNullOrWhiteSpace($Format)) {
            $Format = 'Json'
        }
        if ($Format -ne 'Json') {
            throw "create-runtime-directory only supports -Format Json."
        }
        if ([string]::IsNullOrWhiteSpace($RuntimeRootPath)) {
            throw "Missing required parameter for 'create-runtime-directory': -RuntimeRootPath"
        }

        $runtimePath = Join-Path -Path $engineRoot -ChildPath 'src/ps1/New-RuntimeDirectory.ps1'
        & $runtimePath -RuntimeRootPath $RuntimeRootPath -Format Json -OutputPath $OutputPath
        exit 0
    }
    'assess-clean-tree' {
        if ([string]::IsNullOrWhiteSpace($Format)) {
            $Format = 'Json'
        }
        if ($Format -ne 'Json') {
            throw "assess-clean-tree only supports -Format Json."
        }
        if ([string]::IsNullOrWhiteSpace($RepositoryPath)) {
            throw "Missing required parameter for 'assess-clean-tree': -RepositoryPath"
        }

        $cleanTreePath = Join-Path -Path $engineRoot -ChildPath 'src/ps1/Test-CleanTree.ps1'
        & $cleanTreePath -RepositoryPath $RepositoryPath -Format Json -OutputPath $OutputPath
        exit 0
    }
    'orchestrate-local-execution' {
        if ([string]::IsNullOrWhiteSpace($Format)) {
            $Format = 'Json'
        }
        if ($Format -ne 'Json') {
            throw "orchestrate-local-execution only supports -Format Json."
        }
        if ([string]::IsNullOrWhiteSpace($CommandPlanPath)) {
            throw "Missing required parameter for 'orchestrate-local-execution': -CommandPlanPath"
        }
        if ([string]::IsNullOrWhiteSpace($SourceRepositoryPath)) {
            throw "Missing required parameter for 'orchestrate-local-execution': -SourceRepositoryPath"
        }
        if ([string]::IsNullOrWhiteSpace($RuntimeRootPath)) {
            throw "Missing required parameter for 'orchestrate-local-execution': -RuntimeRootPath"
        }

        $orchestratorPath = Join-Path -Path $engineRoot -ChildPath 'src/ps1/Invoke-ExecutionOrchestrator.ps1'
        & $orchestratorPath -CommandPlanPath $CommandPlanPath -ExecutionPlanPath $ExecutionPlanPath -DeploymentStrategyPath $DeploymentStrategyPath -PackagingPolicyPath $PackagingPolicyPath -DeploymentRunId $DeploymentRunId -SourceRepositoryPath $SourceRepositoryPath -RuntimeRootPath $RuntimeRootPath -MaxAutomationSteps $MaxAutomationSteps -Format Json -OutputPath $OutputPath
        exit 0
    }
    'resume-local-execution' {
        if ([string]::IsNullOrWhiteSpace($Format)) {
            $Format = 'Json'
        }
        if ($Format -ne 'Json') {
            throw "resume-local-execution only supports -Format Json."
        }
        if ([string]::IsNullOrWhiteSpace($RuntimeDirectoryPath)) {
            throw "Missing required parameter for 'resume-local-execution': -RuntimeDirectoryPath"
        }
        if ([string]::IsNullOrWhiteSpace($SessionEventPath)) {
            throw "Missing required parameter for 'resume-local-execution': -SessionEventPath"
        }

        $orchestratorPath = Join-Path -Path $engineRoot -ChildPath 'src/ps1/Invoke-ExecutionOrchestrator.ps1'
        $resumeJson = & $orchestratorPath -Operation Resume -RuntimeDirectoryPath $RuntimeDirectoryPath -SessionEventPath $SessionEventPath -MaxAutomationSteps $MaxAutomationSteps -Format Json -OutputPath $OutputPath
        $resumeJson
        $resumeResult = $resumeJson | ConvertFrom-Json
        if ($resumeResult.status -eq 'rejected') { exit 1 }
        exit 0
    }
    'build-runtime-artifact-reconciliation' {
        if ([string]::IsNullOrWhiteSpace($Format)) {
            $Format = 'Json'
        }
        if ($Format -ne 'Json') {
            throw "build-runtime-artifact-reconciliation only supports -Format Json."
        }
        foreach ($required in @('DeploymentRunId', 'ExecutionPlanPath', 'Manifest', 'PreviousRuntimeArtifactPath', 'ReplacementRuntimeArtifactPath', 'PackagingPolicyPath')) {
            if ([string]::IsNullOrWhiteSpace((Get-Variable -Name $required -ValueOnly))) {
                throw "Missing required parameter for 'build-runtime-artifact-reconciliation': -$required"
            }
        }
        if ([string]::IsNullOrWhiteSpace($CurrentStep)) { $CurrentStep = 'remote.archive.extract' }
        if ([string]::IsNullOrWhiteSpace($CurrentStatus)) { $CurrentStatus = 'WaitingForHuman' }
        if ([string]::IsNullOrWhiteSpace($ReconciledBy)) { $ReconciledBy = 'Codex' }

        $reconciliationPath = Join-Path -Path $engineRoot -ChildPath 'src/ps1/Build-RuntimeArtifactReconciliation.ps1'
        & $reconciliationPath -DeploymentRunId $DeploymentRunId -ExecutionPlanPath $ExecutionPlanPath -ProjectManifestPath $Manifest -PreviousRuntimeArtifactPath $PreviousRuntimeArtifactPath -ReplacementRuntimeArtifactPath $ReplacementRuntimeArtifactPath -PackagingPolicyPath $PackagingPolicyPath -CurrentStep $CurrentStep -CurrentStatus $CurrentStatus -ReconciledBy $ReconciledBy -Format Json -OutputPath $OutputPath
        exit 0
    }
}
