[CmdletBinding()]
param(
    [string] $Platform,
    [string] $ProjectPath,
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

function Get-RemotePlanFingerprintInput {
    param([Parameter(Mandatory = $true)][object] $PlanCore)

    $parts = New-Object System.Collections.Generic.List[string]
    $parts.Add("schemaVersion=$($PlanCore.schemaVersion)")
    $parts.Add("discoveryType=$($PlanCore.discoveryType)")
    $parts.Add("platform=$($PlanCore.platform)")

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
        [string] $OutputPath,
        [string] $Format = 'Json',
        [datetime] $NowUtc = ([DateTime]::UtcNow)
    )

    if ($Format -ne 'Json') {
        throw "remote-discovery-plan only supports -Format Json."
    }

    $plan = New-RemoteToolDiscoveryPlan -Platform $Platform -ProjectPath $ProjectPath -NowUtc $NowUtc
    return Write-RemoteToolDiscoveryPlanJson -Plan $plan -OutputPath $OutputPath
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-RemoteToolDiscoveryPlan -Platform $Platform -ProjectPath $ProjectPath -OutputPath $OutputPath -Format $Format -NowUtc $NowUtc
}
