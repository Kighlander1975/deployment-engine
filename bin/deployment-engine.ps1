[CmdletBinding()]
param(
    [Parameter(Position = 0, Mandatory = $true)]
    [ValidateSet('plan', 'discover-tools')]
    [string] $Command,

    [string] $Analysis,

    [string] $Manifest,

    [string] $ProjectPath,

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
}
