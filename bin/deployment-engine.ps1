[CmdletBinding()]
param(
    [Parameter(Position = 0, Mandatory = $true)]
    [ValidateSet('plan')]
    [string] $Command,

    [string] $Analysis,

    [string] $Manifest,

    [ValidateSet('Text', 'Json')]
    [string] $Format = 'Text',

    [string] $OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$engineRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '..'))

switch ($Command) {
    'plan' {
        if ([string]::IsNullOrWhiteSpace($Analysis)) {
            throw "Missing required parameter for 'plan': -Analysis"
        }
        if ([string]::IsNullOrWhiteSpace($Manifest)) {
            throw "Missing required parameter for 'plan': -Manifest"
        }

        $builderPath = Join-Path -Path $engineRoot -ChildPath 'src/ps1/Invoke-ExecutionPlanBuild.ps1'
        & $builderPath -AnalysisPath $Analysis -ProjectManifestPath $Manifest -Format $Format -OutputPath $OutputPath
        exit $LASTEXITCODE
    }
}
