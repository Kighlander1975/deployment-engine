Set-StrictMode -Version Latest

. (Join-Path -Path $PSScriptRoot -ChildPath 'DeploymentTools.ps1')

function New-AdapterRequirementGroup {
    param(
        [Parameter(Mandatory = $true)][string] $Environment,
        [Parameter(Mandatory = $true)][string] $Role,
        [Parameter(Mandatory = $true)][string[]] $OneOf
    )

    return [pscustomobject]@{
        environment = $Environment
        role = $Role
        oneOf = @($OneOf)
    }
}

function Get-DeploymentAdapterCatalog {
    $catalog = [ordered]@{
        'archive.zip' = [pscustomobject]@{
            adapterId = 'archive.zip'
            priority = 100
            producer = New-AdapterRequirementGroup -Environment 'local' -Role 'producer' -OneOf @('7z', 'zip')
            consumer = New-AdapterRequirementGroup -Environment 'remote' -Role 'consumer' -OneOf @('unzip', '7z')
        }
        'archive.tar' = [pscustomobject]@{
            adapterId = 'archive.tar'
            priority = 200
            producer = New-AdapterRequirementGroup -Environment 'local' -Role 'producer' -OneOf @('7z', 'tar')
            consumer = New-AdapterRequirementGroup -Environment 'remote' -Role 'consumer' -OneOf @('tar', '7z')
        }
    }

    return $catalog
}

function Get-DeploymentAdapterIds {
    return @((Get-DeploymentAdapterCatalog).Keys)
}

function Get-DeploymentAdapterDefinition {
    param([Parameter(Mandatory = $true)][string] $AdapterId)

    $catalog = Get-DeploymentAdapterCatalog
    if (-not $catalog.Contains($AdapterId)) {
        throw "Unknown deployment adapter id: '$AdapterId'."
    }

    return $catalog[$AdapterId]
}
