Set-StrictMode -Version Latest

. (Join-Path -Path $PSScriptRoot -ChildPath 'DeploymentTools.ps1')

function New-RemoteDiscoveryValidationRule {
    param(
        [bool] $RequiresMarkedOutput = $true,
        [bool] $AllowsEmptyOutput = $true
    )

    return [pscustomobject]@{
        requiresMarkedOutput = $RequiresMarkedOutput
        allowsEmptyOutput = $AllowsEmptyOutput
    }
}

function New-RemoteDiscoveryContinuationRule {
    return [pscustomobject]@{
        blocksAutomaticContinuation = $true
        requiredUserAction = 'Vollstaendige markierte Konsolenausgabe fuer diese Probe einfuegen.'
    }
}

function New-RemoteProbeDefinition {
    param(
        [Parameter(Mandatory = $true)][string] $ProbeId,
        [Parameter(Mandatory = $true)][string] $Kind,
        [string] $ToolId = '',
        [string] $ProjectFeature = '',
        [Parameter(Mandatory = $true)][string] $Purpose,
        [Parameter(Mandatory = $true)][string] $DisplayCommand,
        [Parameter(Mandatory = $true)][string] $ExpectedOutput
    )

    if (-not [string]::IsNullOrWhiteSpace($ToolId)) {
        [void] (Get-DeploymentToolDefinition -ToolId $ToolId)
    }

    return [pscustomobject]@{
        probeId = $ProbeId
        kind = $Kind
        toolId = $ToolId
        projectFeature = $ProjectFeature
        platform = 'linux'
        executionMode = 'human'
        purpose = $Purpose
        displayCommand = $DisplayCommand
        required = $true
        readOnly = $true
        expectedOutput = $ExpectedOutput
        validation = New-RemoteDiscoveryValidationRule
        continuation = New-RemoteDiscoveryContinuationRule
    }
}

function Get-RemoteDiscoveryProbeCatalog {
    param([Parameter(Mandatory = $true)][string] $Platform)

    if ($Platform -ne 'linux') {
        throw "Unsupported remote discovery platform: '$Platform'. Supported platforms: linux."
    }

    $catalog = [ordered]@{
        'remote.tool.php.location' = New-RemoteProbeDefinition -ProbeId 'remote.tool.php.location' -Kind 'tool-location' -ToolId 'php' -Purpose 'PHP im Server-PATH erkennen.' -DisplayCommand 'command -v php' -ExpectedOutput 'Pfad oder leere Ausgabe'
        'remote.tool.php.version' = New-RemoteProbeDefinition -ProbeId 'remote.tool.php.version' -Kind 'tool-version' -ToolId 'php' -Purpose 'PHP-Version als Text ausgeben.' -DisplayCommand 'php --version' -ExpectedOutput 'Versionsausgabe oder Fehlermeldung'
        'remote.tool.composer.location' = New-RemoteProbeDefinition -ProbeId 'remote.tool.composer.location' -Kind 'tool-location' -ToolId 'composer' -Purpose 'Composer im Server-PATH erkennen.' -DisplayCommand 'command -v composer' -ExpectedOutput 'Pfad oder leere Ausgabe'
        'remote.tool.composer.version' = New-RemoteProbeDefinition -ProbeId 'remote.tool.composer.version' -Kind 'tool-version' -ToolId 'composer' -Purpose 'Composer-Version als Text ausgeben.' -DisplayCommand 'composer --version' -ExpectedOutput 'Versionsausgabe oder Fehlermeldung'
        'remote.tool.docker.location' = New-RemoteProbeDefinition -ProbeId 'remote.tool.docker.location' -Kind 'tool-location' -ToolId 'docker' -Purpose 'Docker im Server-PATH erkennen.' -DisplayCommand 'command -v docker' -ExpectedOutput 'Pfad oder leere Ausgabe'
        'remote.tool.docker.version' = New-RemoteProbeDefinition -ProbeId 'remote.tool.docker.version' -Kind 'tool-version' -ToolId 'docker' -Purpose 'Docker-Version als Text ausgeben.' -DisplayCommand 'docker --version' -ExpectedOutput 'Versionsausgabe oder Fehlermeldung'
        'remote.tool.7z.location' = New-RemoteProbeDefinition -ProbeId 'remote.tool.7z.location' -Kind 'tool-location' -ToolId '7z' -Purpose '7z im Server-PATH erkennen.' -DisplayCommand 'command -v 7z' -ExpectedOutput 'Pfad oder leere Ausgabe'
        'remote.tool.7z.version' = New-RemoteProbeDefinition -ProbeId 'remote.tool.7z.version' -Kind 'tool-version' -ToolId '7z' -Purpose '7z-Version als Text ausgeben.' -DisplayCommand '7z' -ExpectedOutput 'Versionsausgabe oder Fehlermeldung'
        'remote.tool.zip.location' = New-RemoteProbeDefinition -ProbeId 'remote.tool.zip.location' -Kind 'tool-location' -ToolId 'zip' -Purpose 'zip im Server-PATH erkennen.' -DisplayCommand 'command -v zip' -ExpectedOutput 'Pfad oder leere Ausgabe'
        'remote.tool.zip.version' = New-RemoteProbeDefinition -ProbeId 'remote.tool.zip.version' -Kind 'tool-version' -ToolId 'zip' -Purpose 'zip-Version als Text ausgeben.' -DisplayCommand 'zip -v' -ExpectedOutput 'Versionsausgabe oder Fehlermeldung'
        'remote.tool.unzip.location' = New-RemoteProbeDefinition -ProbeId 'remote.tool.unzip.location' -Kind 'tool-location' -ToolId 'unzip' -Purpose 'unzip im Server-PATH erkennen.' -DisplayCommand 'command -v unzip' -ExpectedOutput 'Pfad oder leere Ausgabe'
        'remote.tool.unzip.version' = New-RemoteProbeDefinition -ProbeId 'remote.tool.unzip.version' -Kind 'tool-version' -ToolId 'unzip' -Purpose 'unzip-Version als Text ausgeben.' -DisplayCommand 'unzip -v' -ExpectedOutput 'Versionsausgabe oder Fehlermeldung'
        'remote.tool.tar.location' = New-RemoteProbeDefinition -ProbeId 'remote.tool.tar.location' -Kind 'tool-location' -ToolId 'tar' -Purpose 'tar im Server-PATH erkennen.' -DisplayCommand 'command -v tar' -ExpectedOutput 'Pfad oder leere Ausgabe'
        'remote.tool.tar.version' = New-RemoteProbeDefinition -ProbeId 'remote.tool.tar.version' -Kind 'tool-version' -ToolId 'tar' -Purpose 'tar-Version als Text ausgeben.' -DisplayCommand 'tar --version' -ExpectedOutput 'Versionsausgabe oder Fehlermeldung'
        'remote.project.artisan.exists' = New-RemoteProbeDefinition -ProbeId 'remote.project.artisan.exists' -Kind 'project-file' -ProjectFeature 'artisan' -Purpose 'Artisan-Datei im aktuellen Projektverzeichnis erkennen, ohne sie auszufuehren.' -DisplayCommand "test -f artisan && printf 'present\n' || printf 'absent\n'" -ExpectedOutput 'present oder absent'
        'remote.project.composer-json.exists' = New-RemoteProbeDefinition -ProbeId 'remote.project.composer-json.exists' -Kind 'project-file' -ProjectFeature 'composerJson' -Purpose 'composer.json im aktuellen Projektverzeichnis erkennen.' -DisplayCommand "test -f composer.json && printf 'present\n' || printf 'absent\n'" -ExpectedOutput 'present oder absent'
        'remote.project.package-json.exists' = New-RemoteProbeDefinition -ProbeId 'remote.project.package-json.exists' -Kind 'project-file' -ProjectFeature 'packageJson' -Purpose 'package.json im aktuellen Projektverzeichnis erkennen.' -DisplayCommand "test -f package.json && printf 'present\n' || printf 'absent\n'" -ExpectedOutput 'present oder absent'
        'remote.project.deploy-version.exists' = New-RemoteProbeDefinition -ProbeId 'remote.project.deploy-version.exists' -Kind 'project-file' -ProjectFeature 'deployVersion' -Purpose '.deploy-version im aktuellen Projektverzeichnis erkennen.' -DisplayCommand "test -f .deploy-version && printf 'present\n' || printf 'absent\n'" -ExpectedOutput 'present oder absent'
        'remote.project.deployment-project-json.exists' = New-RemoteProbeDefinition -ProbeId 'remote.project.deployment-project-json.exists' -Kind 'project-file' -ProjectFeature 'deploymentProjectJson' -Purpose 'deployment.project.json im aktuellen Projektverzeichnis erkennen.' -DisplayCommand "test -f deployment.project.json && printf 'present\n' || printf 'absent\n'" -ExpectedOutput 'present oder absent'
    }

    return $catalog
}

function Get-RemoteDiscoveryProbeIds {
    param([Parameter(Mandatory = $true)][string] $Platform)

    return @((Get-RemoteDiscoveryProbeCatalog -Platform $Platform).Keys)
}

function Get-RemoteDiscoveryProbeDefinition {
    param(
        [Parameter(Mandatory = $true)][string] $Platform,
        [Parameter(Mandatory = $true)][string] $ProbeId
    )

    $catalog = Get-RemoteDiscoveryProbeCatalog -Platform $Platform
    if (-not $catalog.Contains($ProbeId)) {
        throw "Unknown remote discovery probe id: '$ProbeId'."
    }

    return $catalog[$ProbeId]
}
