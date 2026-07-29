[CmdletBinding()]
param(
    [string] $PlanPath,
    [string] $ResponsePath,
    [string] $OutputPath,
    [string] $Format = 'Json'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ResolveRemoteToolDiscoveryPlanPath = $PlanPath
$script:ResolveRemoteToolDiscoveryResponsePath = $ResponsePath
$script:ResolveRemoteToolDiscoveryOutputPath = $OutputPath
$script:ResolveRemoteToolDiscoveryFormat = $Format
. (Join-Path -Path $PSScriptRoot -ChildPath 'New-RemoteToolDiscoveryPlan.ps1')
$PlanPath = $script:ResolveRemoteToolDiscoveryPlanPath
$ResponsePath = $script:ResolveRemoteToolDiscoveryResponsePath
$OutputPath = $script:ResolveRemoteToolDiscoveryOutputPath
$Format = $script:ResolveRemoteToolDiscoveryFormat

$script:RemoteDiscoveryMaxResponseBytes = 1048576
$script:RemoteDiscoveryMaxProbeBytes = 65536

function Read-RemoteDiscoveryJsonFile {
    param([Parameter(Mandatory = $true)][string] $Path)

    $resolved = Resolve-RemoteDiscoveryLocalPath -Path $Path
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
        throw "File does not exist: $resolved"
    }

    try {
        return (Get-Content -LiteralPath $resolved -Raw | ConvertFrom-Json)
    } catch {
        throw "Invalid JSON in '$resolved': $($_.Exception.Message)"
    }
}

function Read-RemoteDiscoveryTextFile {
    param([Parameter(Mandatory = $true)][string] $Path)

    $resolved = Resolve-RemoteDiscoveryLocalPath -Path $Path
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
        throw "File does not exist: $resolved"
    }

    return Get-Content -LiteralPath $resolved -Raw
}

function Assert-RemoteDiscoveryPlan {
    param([Parameter(Mandatory = $true)][object] $Plan)

    foreach ($field in @('schemaVersion', 'discoveryType', 'platform', 'planFingerprint', 'probes')) {
        if (-not ($Plan.PSObject.Properties.Name -contains $field)) {
            throw "Remote discovery plan validation failed: missing required field '$field'."
        }
    }

    if ($Plan.schemaVersion -ne '0.1') {
        throw "Unsupported remote discovery plan schema version: '$($Plan.schemaVersion)'."
    }
    if ($Plan.discoveryType -ne 'remote') {
        throw "Remote discovery plan validation failed: discoveryType must be 'remote'."
    }
    if ($Plan.platform -ne 'linux') {
        throw "Unsupported remote discovery platform: '$($Plan.platform)'."
    }

    $expectedFingerprint = Get-RemoteDiscoveryPlanFingerprint -PlanCore ([pscustomobject]@{
        schemaVersion = [string] $Plan.schemaVersion
        discoveryType = [string] $Plan.discoveryType
        platform = [string] $Plan.platform
        targetBinding = if ($Plan.PSObject.Properties.Name -contains 'targetBinding') { $Plan.targetBinding } else { $null }
        probes = @($Plan.probes)
    })

    if ($expectedFingerprint -ne $Plan.planFingerprint) {
        throw "Remote discovery plan validation failed: planFingerprint does not match plan contents."
    }
}

function Parse-RemoteDiscoveryResponse {
    param(
        [Parameter(Mandatory = $true)][object] $Plan,
        [Parameter(Mandatory = $true)][string] $ResponseText
    )

    $byteCount = [System.Text.Encoding]::UTF8.GetByteCount($ResponseText)
    if ($byteCount -gt $script:RemoteDiscoveryMaxResponseBytes) {
        throw "Remote discovery response exceeds maximum size of $script:RemoteDiscoveryMaxResponseBytes bytes."
    }

    $knownProbeIds = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    foreach ($probe in @($Plan.probes)) {
        [void] $knownProbeIds.Add([string] $probe.probeId)
    }

    $fingerprintLines = New-Object System.Collections.Generic.List[string]
    $captures = [ordered]@{}
    $currentId = ''
    $currentKind = ''
    $currentLines = New-Object System.Collections.Generic.List[string]
    $sawFingerprint = $false
    $normalized = $ResponseText -replace "`r`n", "`n" -replace "`r", "`n"

    foreach ($line in ($normalized -split "`n")) {
        if ($currentKind -eq '') {
            if ([string]::IsNullOrWhiteSpace($line)) {
                continue
            }
            if ($line -eq '=== PLAN-FINGERPRINT ===') {
                if ($sawFingerprint) {
                    throw "Remote discovery response contains duplicate plan fingerprint marker."
                }
                $currentKind = 'fingerprint'
                $currentLines = New-Object System.Collections.Generic.List[string]
                continue
            }
            if ($line -match '^=== BEGIN ([A-Za-z0-9._-]+) ===$') {
                $probeId = $Matches[1]
                if (-not $knownProbeIds.Contains($probeId)) {
                    throw "Remote discovery response contains unknown probe id: '$probeId'."
                }
                if ($captures.Contains($probeId)) {
                    throw "Remote discovery response contains duplicate probe id: '$probeId'."
                }
                $currentKind = 'probe'
                $currentId = $probeId
                $currentLines = New-Object System.Collections.Generic.List[string]
                continue
            }
            if ($line -match '^=== END ') {
                throw "Remote discovery response contains unexpected end marker: '$line'."
            }
            throw "Remote discovery response contains unmarked text outside marker blocks."
        }

        if ($currentKind -eq 'fingerprint') {
            if ($line -eq '=== END PLAN-FINGERPRINT ===') {
                $sawFingerprint = $true
                $fingerprintLines = $currentLines
                $currentKind = ''
                continue
            }
            $currentLines.Add($line)
            continue
        }

        if ($line -eq "=== END $currentId ===") {
            $probeText = ($currentLines -join "`n")
            if ([System.Text.Encoding]::UTF8.GetByteCount($probeText) -gt $script:RemoteDiscoveryMaxProbeBytes) {
                throw "Remote discovery probe output exceeds maximum size for '$currentId'."
            }
            $captures[$currentId] = $probeText
            $currentKind = ''
            $currentId = ''
            continue
        }

        if ($line -match '^=== END ') {
            throw "Remote discovery response contains mismatched end marker for '$currentId'."
        }
        if ($line -match '^=== BEGIN ') {
            throw "Remote discovery response contains nested begin marker for '$currentId'."
        }

        $currentLines.Add($line)
    }

    if ($currentKind -eq 'fingerprint') {
        throw "Remote discovery response is missing the plan fingerprint end marker."
    }
    if ($currentKind -eq 'probe') {
        throw "Remote discovery response is missing end marker for '$currentId'."
    }
    if (-not $sawFingerprint) {
        throw "Remote discovery response is missing the plan fingerprint marker."
    }

    $responseFingerprint = (($fingerprintLines -join "`n").Trim())
    if ($responseFingerprint -ne $Plan.planFingerprint) {
        throw "Remote discovery response fingerprint mismatch."
    }

    return [pscustomobject]@{
        fingerprint = $responseFingerprint
        outputs = [pscustomobject] $captures
    }
}

function Test-RemoteProbeFailureText {
    param([string] $Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $false
    }

    return ($Text -match '(?i)(permission denied|operation not permitted|segmentation fault|fatal error|traceback|error while loading shared libraries|cannot execute)')
}

function Test-RemoteNotFoundText {
    param([string] $Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $false
    }

    return ($Text -match '(?i)(command not found|not found|No such file or directory)')
}

function Get-RemoteToolVersionFromText {
    param(
        [Parameter(Mandatory = $true)][string] $ToolId,
        [string] $Text
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ''
    }

    $firstLine = (($Text -split "`n") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1)
    if ($null -eq $firstLine) {
        return ''
    }

    switch ($ToolId) {
        'php' {
            if ($firstLine -match '(?i)\bPHP\s+([0-9]+(?:\.[0-9]+){1,3})\b') { return $Matches[1] }
        }
        'composer' {
            if ($firstLine -match '(?i)\bComposer(?:\s+version)?\s+([0-9]+(?:\.[0-9]+){1,3})\b') { return $Matches[1] }
        }
        'docker' {
            if ($firstLine -match '(?i)\bDocker\s+version\s+([0-9]+(?:\.[0-9]+){1,3})\b') { return $Matches[1] }
        }
        '7z' {
            if ($Text -match '(?i)\b7-Zip(?:\s+\[64\])?\s+([0-9]+(?:\.[0-9]+){1,3})\b') { return $Matches[1] }
        }
        'zip' {
            if ($Text -match '(?i)\bZip\s+([0-9]+(?:\.[0-9]+){1,3})\b') { return $Matches[1] }
        }
        'unzip' {
            if ($Text -match '(?i)\bUnZip\s+([0-9]+(?:\.[0-9]+){1,3})\b') { return $Matches[1] }
        }
        'tar' {
            if ($firstLine -match '(?i)\btar\b.*\s([0-9]+(?:\.[0-9]+){1,3})\b') { return $Matches[1] }
        }
    }

    return ''
}

function Get-RemoteProbeOutput {
    param(
        [Parameter(Mandatory = $true)][object] $ParsedResponse,
        [Parameter(Mandatory = $true)][string] $ProbeId
    )

    if ($ParsedResponse.outputs.PSObject.Properties.Name -contains $ProbeId) {
        return [string] $ParsedResponse.outputs.$ProbeId
    }

    return $null
}

function New-RemoteToolInventoryResult {
    param(
        [Parameter(Mandatory = $true)][object] $Plan,
        [Parameter(Mandatory = $true)][object] $ParsedResponse
    )

    $missingRequired = New-Object System.Collections.Generic.List[string]
    foreach ($probe in @($Plan.probes)) {
        if ($probe.required -and -not ($ParsedResponse.outputs.PSObject.Properties.Name -contains $probe.probeId)) {
            $missingRequired.Add([string] $probe.probeId)
        }
    }

    $toolResults = [ordered]@{}
    foreach ($toolId in Get-DeploymentToolIds) {
        $locationProbeId = "remote.tool.$toolId.location"
        $versionProbeId = "remote.tool.$toolId.version"
        $locationOutput = Get-RemoteProbeOutput -ParsedResponse $ParsedResponse -ProbeId $locationProbeId
        $versionOutput = Get-RemoteProbeOutput -ParsedResponse $ParsedResponse -ProbeId $versionProbeId

        $path = if ($null -eq $locationOutput) { '' } else { (($locationOutput -split "`n") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1) }
        if ($null -eq $path) {
            $path = ''
        }
        $path = ([string] $path).Trim()

        if ([string]::IsNullOrWhiteSpace($path) -or (Test-RemoteNotFoundText -Text $locationOutput)) {
            $toolResults[$toolId] = [pscustomobject]@{
                available = $false
                path = ''
                version = ''
                status = 'not-found'
                diagnostic = ''
            }
            continue
        }

        $version = Get-RemoteToolVersionFromText -ToolId $toolId -Text $versionOutput
        $status = 'available'
        $diagnostic = ''

        if (Test-RemoteProbeFailureText -Text $versionOutput) {
            $status = 'probe-failed'
            $diagnostic = ($versionOutput.Trim())
        } elseif (Test-RemoteNotFoundText -Text $versionOutput) {
            $status = 'probe-failed'
            $diagnostic = ($versionOutput.Trim())
        } elseif ([string]::IsNullOrWhiteSpace($version)) {
            $status = 'version-unavailable'
            $diagnostic = 'Version output could not be parsed.'
        }

        $toolResults[$toolId] = [pscustomobject]@{
            available = $true
            path = $path
            version = $version
            status = $status
            diagnostic = $diagnostic
        }
    }

    $projectResults = [ordered]@{
        available = $true
    }
    $projectProbeMap = [ordered]@{
        artisan = 'remote.project.artisan.exists'
        composerJson = 'remote.project.composer-json.exists'
        packageJson = 'remote.project.package-json.exists'
        deployVersion = 'remote.project.deploy-version.exists'
        deploymentProjectJson = 'remote.project.deployment-project-json.exists'
    }
    foreach ($feature in $projectProbeMap.Keys) {
        $output = Get-RemoteProbeOutput -ParsedResponse $ParsedResponse -ProbeId $projectProbeMap[$feature]
        $projectResults[$feature] = [pscustomobject]@{
            available = (([string] $output).Trim() -eq 'present')
        }
    }

    $status = if ($missingRequired.Count -eq 0) { 'completed' } else { 'incomplete' }
    $diagnostic = if ($missingRequired.Count -eq 0) { '' } else { "Missing required probe output: $($missingRequired -join ', ')" }

    return [pscustomobject]@{
        schemaVersion = '0.1'
        environment = 'remote'
        discoveryType = 'remote'
        discoveryMethod = 'human'
        status = $status
        diagnostic = $diagnostic
        planFingerprint = [string] $Plan.planFingerprint
        platform = [pscustomobject]@{
            os = [string] $Plan.platform
        }
        project = [pscustomobject] $projectResults
        tools = [pscustomobject] $toolResults
    }
}

function Resolve-RemoteToolDiscovery {
    param(
        [Parameter(Mandatory = $true)][object] $Plan,
        [Parameter(Mandatory = $true)][string] $ResponseText
    )

    Assert-RemoteDiscoveryPlan -Plan $Plan
    $parsed = Parse-RemoteDiscoveryResponse -Plan $Plan -ResponseText $ResponseText
    return New-RemoteToolInventoryResult -Plan $Plan -ParsedResponse $parsed
}

function Write-RemoteToolInventoryJson {
    param(
        [Parameter(Mandatory = $true)][object] $Inventory,
        [string] $OutputPath
    )

    $json = $Inventory | ConvertTo-Json -Depth 30
    if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
        $resolvedOutputPath = Resolve-RemoteDiscoveryLocalPath -Path $OutputPath
        $outputDirectory = Split-Path -Path $resolvedOutputPath -Parent
        if (-not [string]::IsNullOrWhiteSpace($outputDirectory)) {
            New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
        }
        $json | Set-Content -LiteralPath $resolvedOutputPath -Encoding utf8
    }

    return $json
}

function Invoke-ResolveRemoteToolDiscovery {
    param(
        [Parameter(Mandatory = $true)][string] $PlanPath,
        [Parameter(Mandatory = $true)][string] $ResponsePath,
        [string] $OutputPath,
        [string] $Format = 'Json'
    )

    if ($Format -ne 'Json') {
        throw "resolve-remote-discovery only supports -Format Json."
    }

    $plan = Read-RemoteDiscoveryJsonFile -Path $PlanPath
    $response = Read-RemoteDiscoveryTextFile -Path $ResponsePath
    $inventory = Resolve-RemoteToolDiscovery -Plan $plan -ResponseText $response
    return Write-RemoteToolInventoryJson -Inventory $inventory -OutputPath $OutputPath
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-ResolveRemoteToolDiscovery -PlanPath $PlanPath -ResponsePath $ResponsePath -OutputPath $OutputPath -Format $Format
}
