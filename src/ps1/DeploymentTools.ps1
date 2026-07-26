Set-StrictMode -Version Latest

function Get-DeploymentToolCatalog {
    $catalog = [ordered]@{
        php = [pscustomobject]@{
            toolId = 'php'
            commandNames = @('php')
            probeArguments = @('--version')
        }
        composer = [pscustomobject]@{
            toolId = 'composer'
            commandNames = @('composer')
            probeArguments = @('--version')
        }
        docker = [pscustomobject]@{
            toolId = 'docker'
            commandNames = @('docker')
            probeArguments = @('--version')
        }
        '7z' = [pscustomobject]@{
            toolId = '7z'
            commandNames = @('7z', '7za', '7zr')
            probeArguments = @()
        }
        zip = [pscustomobject]@{
            toolId = 'zip'
            commandNames = @('zip')
            probeArguments = @('-v')
        }
        tar = [pscustomobject]@{
            toolId = 'tar'
            commandNames = @('tar')
            probeArguments = @('--version')
        }
    }

    return $catalog
}

function Get-DeploymentToolDefinition {
    param([Parameter(Mandatory = $true)][string] $ToolId)

    $catalog = Get-DeploymentToolCatalog
    if (-not $catalog.Contains($ToolId)) {
        throw "Unknown deployment tool id: '$ToolId'."
    }

    return $catalog[$ToolId]
}

function Get-DeploymentToolIds {
    return @((Get-DeploymentToolCatalog).Keys)
}
