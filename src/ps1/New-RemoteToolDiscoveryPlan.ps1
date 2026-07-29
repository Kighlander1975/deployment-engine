[CmdletBinding()]
param(
    [string] $Platform,
    [string] $ProjectPath,
    [string] $ExecutionPlanPath,
    [string] $OutputPath,
    [string] $Format = 'Json',
    [datetime] $NowUtc = ([DateTime]::UtcNow)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path -Path $PSScriptRoot -ChildPath 'RemoteDiscoveryProbes.ps1')

function Resolve-RemoteDiscoveryLocalPath {
    param([Parameter(Mandatory = $true)][string] $Path)

    $executionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function Read-RemoteDiscoveryJsonFile {
    param([Parameter(Mandatory = $true)][string] $Path)

    $resolved = Resolve-RemoteDiscoveryLocalPath -Path $Path
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
        throw "File does not exist: $resolved"
    }

    try {
        return Get-Content -LiteralPath $resolved -Raw | ConvertFrom-Json
    } catch {
        throw "Invalid JSON in '$resolved': $($_.Exception.Message)"
    }
}

function Test-RemoteDiscoveryProperty {
    param([object] $Object, [Parameter(Mandatory = $true)][string] $Name)

    return ($null -ne $Object -and $Object.PSObject.Properties.Name -contains $Name -and $null -ne $Object.$Name)
}

function Assert-RemoteDiscoveryBindingString {
    param([Parameter(Mandatory = $true)][object] $Object, [Parameter(Mandatory = $true)][string] $Name)

    if (-not (Test-RemoteDiscoveryProperty -Object $Object -Name $Name) -or [string]::IsNullOrWhiteSpace([string] $Object.$Name)) {
        throw "Remote discovery target binding validation failed: missing required field '$Name'."
    }
}

function Get-RemoteDiscoveryTargetBindingFromExecutionPlan {
    param([Parameter(Mandatory = $true)][object] $ExecutionPlan)

    if (-not (Test-RemoteDiscoveryProperty -Object $ExecutionPlan -Name 'environment')) {
        throw 'Remote discovery target binding validation failed: execution plan environment is missing.'
    }
    Assert-RemoteDiscoveryBindingString -Object $ExecutionPlan.environment -Name 'applicationRemoteDirectory'
    if (-not (Test-RemoteDiscoveryProperty -Object $ExecutionPlan.environment -Name 'remoteTarget')) {
        throw 'Remote discovery target binding validation failed: execution plan remoteTarget is missing.'
    }

    $remoteTarget = $ExecutionPlan.environment.remoteTarget
    foreach ($field in @('targetId', 'remoteRoot', 'applicationPath', 'applicationRemoteDirectory')) {
        Assert-RemoteDiscoveryBindingString -Object $remoteTarget -Name $field
    }

    return [pscustomobject]@{
        executionPlanFingerprint = if (Test-RemoteDiscoveryProperty -Object $ExecutionPlan -Name 'executionPlanFingerprint') { [string] $ExecutionPlan.executionPlanFingerprint } else { '' }
        targetId = [string] $remoteTarget.targetId
        remoteRoot = [string] $remoteTarget.remoteRoot
        applicationPath = [string] $remoteTarget.applicationPath
        applicationRemoteDirectory = [string] $ExecutionPlan.environment.applicationRemoteDirectory
    }
}

function Get-RemotePlanFingerprintInput {
    param([Parameter(Mandatory = $true)][object] $PlanCore)

    $parts = New-Object System.Collections.Generic.List[string]
    $parts.Add("schemaVersion=$($PlanCore.schemaVersion)")
    $parts.Add("discoveryType=$($PlanCore.discoveryType)")
    $parts.Add("platform=$($PlanCore.platform)")
    if (Test-RemoteDiscoveryProperty -Object $PlanCore -Name 'targetBinding') {
        $binding = $PlanCore.targetBinding
        $parts.Add("executionPlanFingerprint=$($binding.executionPlanFingerprint)")
        $parts.Add("targetId=$($binding.targetId)")
        $parts.Add("remoteRoot=$($binding.remoteRoot)")
        $parts.Add("applicationPath=$($binding.applicationPath)")
        $parts.Add("applicationRemoteDirectory=$($binding.applicationRemoteDirectory)")
    }

    foreach ($probe in @($PlanCore.probes)) {
        $parts.Add("probeId=$($probe.probeId)")
        $parts.Add("displayCommand=$($probe.displayCommand)")
    }

    return ($parts -join "`n")
}

function Get-RemoteDiscoveryPlanFingerprint {
    param([Parameter(Mandatory = $true)][object] $PlanCore)

    $bytes = [System.Text.Encoding]::UTF8.GetBytes((Get-RemotePlanFingerprintInput -PlanCore $PlanCore))
    $hash = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($hash.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    } finally {
        $hash.Dispose()
    }
}

function New-RemoteDiscoveryResponseTemplate {
    param([Parameter(Mandatory = $true)][object] $Plan)

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('=== PLAN-FINGERPRINT ===')
    $lines.Add([string] $Plan.planFingerprint)
    $lines.Add('=== END PLAN-FINGERPRINT ===')
    $lines.Add('')

    foreach ($probe in @($Plan.probes)) {
        $lines.Add("=== BEGIN $($probe.probeId) ===")
        $lines.Add('<vollstaendige Konsolenausgabe hier einfuegen>')
        $lines.Add("=== END $($probe.probeId) ===")
        $lines.Add('')
    }

    return ($lines -join "`n")
}

function New-RemoteToolDiscoveryPlan {
    param(
        [Parameter(Mandatory = $true)][string] $Platform,
        [string] $ProjectPath = '',
        [object] $TargetBinding,
        [datetime] $NowUtc = ([DateTime]::UtcNow)
    )

    if ([string]::IsNullOrWhiteSpace($Platform)) {
        throw "Remote discovery requires an explicit -Platform."
    }

    $probeCatalog = Get-RemoteDiscoveryProbeCatalog -Platform $Platform
    $probes = New-Object System.Collections.Generic.List[object]
    foreach ($probeId in $probeCatalog.Keys) {
        $probes.Add($probeCatalog[$probeId])
    }

    $planCore = [pscustomobject]@{
        schemaVersion = '0.1'
        discoveryType = 'remote'
        platform = $Platform
        targetBinding = $TargetBinding
        probes = $probes.ToArray()
    }

    $fingerprint = Get-RemoteDiscoveryPlanFingerprint -PlanCore $planCore
    $plan = [pscustomobject]@{
        schemaVersion = '0.1'
        discoveryType = 'remote'
        generatedAt = $NowUtc.ToUniversalTime().ToString('o')
        platform = $Platform
        executionMode = 'human'
        status = 'waiting-for-human'
        blocksAutomaticContinuation = $true
        planFingerprint = $fingerprint
        targetBinding = $TargetBinding
        projectPathInstruction = 'Vor Ausfuehrung der Projektprobes selbst in das bekannte Projektverzeichnis wechseln.'
        requiredUserAction = 'Pruefkommandos auf dem Zielserver ausfuehren und vollstaendige markierte Konsolenausgabe zurueckgeben.'
        secretHandling = 'Keine Passwoerter, Tokens, Zugangsdaten, .env-Inhalte, Hostnamen, Benutzernamen, IP-Adressen oder Umgebungsvariablen einfuegen.'
        responseFormat = 'Markerformat mit PLAN-FINGERPRINT sowie BEGIN/END je bekannter Probe-ID.'
        probes = $probes.ToArray()
    }

    Add-Member -InputObject $plan -MemberType NoteProperty -Name 'responseTemplate' -Value (New-RemoteDiscoveryResponseTemplate -Plan $plan)
    return $plan
}

function Write-RemoteToolDiscoveryPlanJson {
    param(
        [Parameter(Mandatory = $true)][object] $Plan,
        [string] $OutputPath
    )

    $json = $Plan | ConvertTo-Json -Depth 30
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

function Invoke-RemoteToolDiscoveryPlan {
    param(
        [Parameter(Mandatory = $true)][string] $Platform,
        [string] $ProjectPath,
        [string] $ExecutionPlanPath,
        [string] $OutputPath,
        [string] $Format = 'Json',
        [datetime] $NowUtc = ([DateTime]::UtcNow)
    )

    if ($Format -ne 'Json') {
        throw "remote-discovery-plan only supports -Format Json."
    }

    $targetBinding = $null
    if (-not [string]::IsNullOrWhiteSpace($ExecutionPlanPath)) {
        $executionPlan = Read-RemoteDiscoveryJsonFile -Path $ExecutionPlanPath
        $targetBinding = Get-RemoteDiscoveryTargetBindingFromExecutionPlan -ExecutionPlan $executionPlan
    }

    $plan = New-RemoteToolDiscoveryPlan -Platform $Platform -ProjectPath $ProjectPath -TargetBinding $targetBinding -NowUtc $NowUtc
    return Write-RemoteToolDiscoveryPlanJson -Plan $plan -OutputPath $OutputPath
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-RemoteToolDiscoveryPlan -Platform $Platform -ProjectPath $ProjectPath -ExecutionPlanPath $ExecutionPlanPath -OutputPath $OutputPath -Format $Format -NowUtc $NowUtc
}
