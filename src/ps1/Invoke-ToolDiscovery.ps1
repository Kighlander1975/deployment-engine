[CmdletBinding()]
param(
    [string] $ProjectPath,

    [ValidateSet('Json')]
    [string] $Format = 'Json',

    [string] $OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path -Path $PSScriptRoot -ChildPath 'DeploymentTools.ps1')

function Resolve-DiscoveryPath {
    param([Parameter(Mandatory = $true)][string] $Path)

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    return [System.IO.Path]::GetFullPath((Join-Path -Path (Get-Location).Path -ChildPath $Path))
}

function ConvertTo-DiscoveryPath {
    param([string] $Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ''
    }

    return [System.IO.Path]::GetFullPath($Path)
}

function Get-PlatformInformation {
    $os = if ($IsWindows) {
        'windows'
    } elseif ($IsLinux) {
        'linux'
    } elseif ($IsMacOS) {
        'macos'
    } else {
        'unknown'
    }

    return [pscustomobject]@{
        os = $os
        architecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
        shell = 'powershell'
        powerShellVersion = $PSVersionTable.PSVersion.ToString()
    }
}

function Find-Executable {
    param([Parameter(Mandatory = $true)][string[]] $CommandNames)

    foreach ($commandName in $CommandNames) {
        $commands = @(Get-Command -Name $commandName -CommandType Application -All -ErrorAction SilentlyContinue)
        if ($commands.Count -gt 0) {
            $primary = $commands[0]
            $allPaths = @(
                $commands |
                    ForEach-Object { ConvertTo-DiscoveryPath -Path $_.Source } |
                    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                    Sort-Object -Unique
            )

            return [pscustomobject]@{
                found = $true
                commandName = $commandName
                path = ConvertTo-DiscoveryPath -Path $primary.Source
                allPaths = @($allPaths)
            }
        }
    }

    return [pscustomobject]@{
        found = $false
        commandName = ''
        path = ''
        allPaths = @()
    }
}

function Invoke-ReadOnlyToolProbe {
    param(
        [Parameter(Mandatory = $true)][string] $ExecutablePath,
        [string[]] $Arguments = @(),
        [int] $TimeoutSeconds = 5
    )

    if ($TimeoutSeconds -lt 1) {
        $TimeoutSeconds = 1
    }
    if ($TimeoutSeconds -gt 10) {
        $TimeoutSeconds = 10
    }

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $ExecutablePath
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in @($Arguments)) {
        [void] $startInfo.ArgumentList.Add($argument)
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo

    try {
        [void] $process.Start()
        $completed = $process.WaitForExit($TimeoutSeconds * 1000)
        if (-not $completed) {
            try {
                $process.Kill()
            } catch {
            }

            return [pscustomobject]@{
                exitCode = $null
                stdout = ''
                stderr = ''
                timedOut = $true
                failed = $true
                diagnostic = "Probe timed out after $TimeoutSeconds seconds."
            }
        }

        return [pscustomobject]@{
            exitCode = $process.ExitCode
            stdout = $process.StandardOutput.ReadToEnd()
            stderr = $process.StandardError.ReadToEnd()
            timedOut = $false
            failed = $false
            diagnostic = ''
        }
    } catch {
        return [pscustomobject]@{
            exitCode = $null
            stdout = ''
            stderr = ''
            timedOut = $false
            failed = $true
            diagnostic = $_.Exception.Message
        }
    } finally {
        $process.Dispose()
    }
}

function Get-ToolVersion {
    param(
        [Parameter(Mandatory = $true)][object] $ToolDefinition,
        [Parameter(Mandatory = $true)][object] $Executable,
        [scriptblock] $Probe
    )

    $probeResult = if ($null -ne $Probe) {
        & $Probe $ToolDefinition $Executable
    } else {
        Invoke-ReadOnlyToolProbe -ExecutablePath $Executable.path -Arguments @($ToolDefinition.probeArguments)
    }

    if ($probeResult.failed -or $probeResult.timedOut) {
        return [pscustomobject]@{
            version = ''
            status = 'probe-failed'
            diagnostic = [string] $probeResult.diagnostic
        }
    }

    $combinedOutput = @($probeResult.stdout, $probeResult.stderr) -join "`n"
    $firstLine = @($combinedOutput -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1)
    if ($firstLine.Count -eq 0) {
        return [pscustomobject]@{
            version = ''
            status = 'version-unavailable'
            diagnostic = 'Version probe produced no readable output.'
        }
    }

    return [pscustomobject]@{
        version = [string] $firstLine[0]
        status = 'available'
        diagnostic = ''
    }
}

function New-ToolResult {
    param(
        [Parameter(Mandatory = $true)][object] $ToolDefinition,
        [scriptblock] $Finder,
        [scriptblock] $Probe
    )

    $executable = if ($null -ne $Finder) {
        & $Finder $ToolDefinition
    } else {
        Find-Executable -CommandNames @($ToolDefinition.commandNames)
    }

    if (-not $executable.found) {
        return [pscustomobject]@{
            available = $false
            path = ''
            version = ''
            status = 'not-found'
            diagnostic = ''
            commandName = ''
            allPaths = @()
        }
    }

    $versionResult = Get-ToolVersion -ToolDefinition $ToolDefinition -Executable $executable -Probe $Probe
    return [pscustomobject]@{
        available = $true
        path = ConvertTo-DiscoveryPath -Path $executable.path
        version = [string] $versionResult.version
        status = [string] $versionResult.status
        diagnostic = [string] $versionResult.diagnostic
        commandName = [string] $executable.commandName
        allPaths = @($executable.allPaths)
    }
}

function Test-ProjectFile {
    param(
        [Parameter(Mandatory = $true)][string] $ProjectRoot,
        [Parameter(Mandatory = $true)][string] $RelativePath
    )

    $path = Join-Path -Path $ProjectRoot -ChildPath $RelativePath
    return [pscustomobject]@{
        available = (Test-Path -LiteralPath $path -PathType Leaf)
        path = (ConvertTo-DiscoveryPath -Path $path)
    }
}

function Get-ProjectToolInformation {
    param([string] $ProjectPath)

    if ([string]::IsNullOrWhiteSpace($ProjectPath)) {
        return [pscustomobject]@{
            path = ''
            available = $false
            artisan = [pscustomobject]@{ available = $false; path = '' }
            composerJson = [pscustomobject]@{ available = $false; path = '' }
            packageJson = [pscustomobject]@{ available = $false; path = '' }
            deployVersion = [pscustomobject]@{ available = $false; path = '' }
            deploymentProjectJson = [pscustomobject]@{ available = $false; path = '' }
        }
    }

    $resolvedProjectPath = Resolve-DiscoveryPath -Path $ProjectPath
    if (-not (Test-Path -LiteralPath $resolvedProjectPath -PathType Container)) {
        throw "Project path does not exist: $resolvedProjectPath"
    }

    $artisan = Test-ProjectFile -ProjectRoot $resolvedProjectPath -RelativePath 'artisan'
    if (-not $artisan.available) {
        $nestedArtisan = Test-ProjectFile -ProjectRoot $resolvedProjectPath -RelativePath 'laravel_app/artisan'
        if ($nestedArtisan.available) {
            $artisan = $nestedArtisan
        }
    }

    return [pscustomobject]@{
        path = $resolvedProjectPath
        available = $true
        artisan = $artisan
        composerJson = Test-ProjectFile -ProjectRoot $resolvedProjectPath -RelativePath 'composer.json'
        packageJson = Test-ProjectFile -ProjectRoot $resolvedProjectPath -RelativePath 'package.json'
        deployVersion = Test-ProjectFile -ProjectRoot $resolvedProjectPath -RelativePath '.deploy-version'
        deploymentProjectJson = Test-ProjectFile -ProjectRoot $resolvedProjectPath -RelativePath 'deployment.project.json'
    }
}

function New-ToolDiscoveryResult {
    param(
        [string] $ProjectPath,
        [scriptblock] $Finder,
        [scriptblock] $Probe,
        [datetime] $NowUtc = ([DateTime]::UtcNow)
    )

    $toolResults = [ordered]@{}

    foreach ($toolId in Get-DeploymentToolIds) {
        try {
            $toolDefinition = Get-DeploymentToolDefinition -ToolId $toolId
            $toolResults[$toolId] = New-ToolResult -ToolDefinition $toolDefinition -Finder $Finder -Probe $Probe
        } catch {
            throw "Tool discovery failed for '$toolId': $($_.Exception.Message)"
        }
    }

    return [pscustomobject]@{
        schemaVersion = '0.1'
        generatedAt = $NowUtc.ToUniversalTime().ToString('o')
        platform = Get-PlatformInformation
        project = Get-ProjectToolInformation -ProjectPath $ProjectPath
        tools = [pscustomobject] $toolResults
    }
}

function Write-ToolDiscoveryJson {
    param(
        [Parameter(Mandatory = $true)][object] $Result,
        [string] $OutputPath
    )

    $json = $Result | ConvertTo-Json -Depth 20
    if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
        $resolvedOutputPath = Resolve-DiscoveryPath -Path $OutputPath
        $outputDirectory = Split-Path -Path $resolvedOutputPath -Parent
        if (-not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
            throw "Output directory does not exist: $outputDirectory"
        }
        $json | Set-Content -LiteralPath $resolvedOutputPath -Encoding utf8
    }

    return $json
}

function Invoke-ToolDiscovery {
    param(
        [string] $ProjectPath,
        [string] $OutputPath,
        [ValidateSet('Json')]
        [string] $Format = 'Json',
        [scriptblock] $Finder,
        [scriptblock] $Probe,
        [datetime] $NowUtc = ([DateTime]::UtcNow)
    )

    $result = New-ToolDiscoveryResult -ProjectPath $ProjectPath -Finder $Finder -Probe $Probe -NowUtc $NowUtc

    if ($Format -eq 'Json') {
        return Write-ToolDiscoveryJson -Result $result -OutputPath $OutputPath
    }

    throw "Unsupported format: $Format"
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-ToolDiscovery -ProjectPath $ProjectPath -OutputPath $OutputPath -Format $Format
}
