[CmdletBinding()]
param(
    [Parameter(Position = 0, Mandatory = $true)]
    [ValidateSet('plan', 'discover-tools', 'remote-discovery-plan', 'resolve-remote-discovery', 'assess-tool-inventories')]
    [string] $Command,

    [string] $Analysis,

    [string] $Manifest,

    [string] $ProjectPath,

    [string] $Platform,

    [string] $PlanPath,

    [string] $ResponsePath,

    [string] $LocalInventoryPath,

    [string] $RemoteInventoryPath,

    [string] $Format,

    [string] $OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$engineRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '..'))

switch ($Command) {
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

        $builderPath = Join-Path -Path $engineRoot -ChildPath 'src/ps1/Invoke-ExecutionPlanBuild.ps1'
        & $builderPath -AnalysisPath $Analysis -ProjectManifestPath $Manifest -Format $planFormat -OutputPath $OutputPath
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

        $remotePlanPath = Join-Path -Path $engineRoot -ChildPath 'src/ps1/New-RemoteToolDiscoveryPlan.ps1'
        & $remotePlanPath -Platform $Platform -ProjectPath $ProjectPath -Format Json -OutputPath $OutputPath
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
}
