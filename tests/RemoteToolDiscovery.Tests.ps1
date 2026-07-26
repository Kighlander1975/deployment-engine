[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:failures = New-Object System.Collections.Generic.List[string]
$engineRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '..'))
$planPath = Join-Path -Path $engineRoot -ChildPath 'src/ps1/New-RemoteToolDiscoveryPlan.ps1'
$resolverPath = Join-Path -Path $engineRoot -ChildPath 'src/ps1/Resolve-RemoteToolDiscovery.ps1'

. $planPath
. $resolverPath

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) {
        $script:failures.Add($Message)
    }
}

function Assert-Equal {
    param($Actual, $Expected, [string] $Message)
    if ($Actual -ne $Expected) {
        $script:failures.Add("$Message Expected '$Expected', got '$Actual'.")
    }
}

function Assert-ThrowsLike {
    param(
        [scriptblock] $Script,
        [string] $Pattern,
        [string] $Message
    )

    try {
        & $Script
        $script:failures.Add($Message)
    } catch {
        Assert-True ($_.Exception.Message -match $Pattern) "$Message Actual error: $($_.Exception.Message)"
    }
}

function New-RemoteResponse {
    param(
        [Parameter(Mandatory = $true)][object] $Plan,
        [hashtable] $Outputs = @{},
        [string] $Fingerprint
    )

    if ([string]::IsNullOrWhiteSpace($Fingerprint)) {
        $Fingerprint = [string] $Plan.planFingerprint
    }

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('=== PLAN-FINGERPRINT ===')
    $lines.Add($Fingerprint)
    $lines.Add('=== END PLAN-FINGERPRINT ===')
    $lines.Add('')

    foreach ($probe in @($Plan.probes)) {
        if ($Outputs.ContainsKey($probe.probeId)) {
            $lines.Add("=== BEGIN $($probe.probeId) ===")
            $lines.Add([string] $Outputs[$probe.probeId])
            $lines.Add("=== END $($probe.probeId) ===")
            $lines.Add('')
        }
    }

    return ($lines -join "`n")
}

function New-CompleteOutputMap {
    param([Parameter(Mandatory = $true)][object] $Plan)

    $outputs = @{}
    foreach ($probe in @($Plan.probes)) {
        $outputs[$probe.probeId] = ''
    }

    $outputs['remote.tool.php.location'] = '/usr/bin/php'
    $outputs['remote.tool.php.version'] = "PHP 8.3.12 (cli)`nCopyright"
    $outputs['remote.tool.composer.location'] = '/usr/local/bin/composer'
    $outputs['remote.tool.composer.version'] = 'Composer version 2.8.1 2025-01-01'
    $outputs['remote.tool.docker.location'] = ''
    $outputs['remote.tool.docker.version'] = 'docker: command not found'
    $outputs['remote.tool.7z.location'] = '/usr/bin/7z'
    $outputs['remote.tool.7z.version'] = '7-Zip 24.09 (x64)'
    $outputs['remote.tool.zip.location'] = '/usr/bin/zip'
    $outputs['remote.tool.zip.version'] = 'Unclear zip banner'
    $outputs['remote.tool.tar.location'] = '/usr/bin/tar'
    $outputs['remote.tool.tar.version'] = 'tar: error while loading shared libraries: libacl.so'
    $outputs['remote.project.artisan.exists'] = 'present'
    $outputs['remote.project.composer-json.exists'] = 'present'
    $outputs['remote.project.package-json.exists'] = 'absent'
    $outputs['remote.project.deploy-version.exists'] = 'absent'
    $outputs['remote.project.deployment-project-json.exists'] = 'present'

    return $outputs
}

$fixedNow = [datetime]::Parse('2026-07-26T12:00:00Z').ToUniversalTime()
$plan = New-RemoteToolDiscoveryPlan -Platform linux -ProjectPath '/var/www/demo/current' -NowUtc $fixedNow
$samePlanLater = New-RemoteToolDiscoveryPlan -Platform linux -ProjectPath '/var/www/demo/current' -NowUtc ([datetime]::Parse('2026-07-27T12:00:00Z').ToUniversalTime())

Assert-Equal $plan.schemaVersion '0.1' 'Remote plan schema version must be stable.'
Assert-Equal $plan.discoveryType 'remote' 'Remote plan must declare discovery type.'
Assert-Equal $plan.platform 'linux' 'Remote plan must use explicit linux platform.'
Assert-Equal $plan.executionMode 'human' 'Remote plan must be a human gate.'
Assert-Equal $plan.status 'waiting-for-human' 'Remote plan must wait for human output.'
Assert-Equal $plan.blocksAutomaticContinuation $true 'Remote plan must block automatic continuation.'
Assert-Equal (@($plan.probes).Count) 17 'Remote plan must include expected probe count.'
Assert-Equal ((@($plan.probes) | Select-Object -First 1).probeId) 'remote.tool.php.location' 'Remote probe order must be deterministic.'
Assert-Equal ((@($plan.probes) | Select-Object -Last 1).probeId) 'remote.project.deployment-project-json.exists' 'Remote probe order must include project probes deterministically.'
Assert-Equal $plan.planFingerprint $samePlanLater.planFingerprint 'Plan timestamp must not affect fingerprint.'
Assert-True ($plan.responseTemplate -match [regex]::Escape($plan.planFingerprint)) 'Response template must include plan fingerprint.'
Assert-True (-not ($plan.responseTemplate -match 'php artisan')) 'Response template must not execute artisan.'
$planJson = $plan | ConvertTo-Json -Depth 30

Assert-True `
    (-not ($planJson -match [regex]::Escape('/var/www/demo/current'))) `
    'Remote plan must not contain the provided project path.'

$changedCore = [pscustomobject]@{
    schemaVersion = '0.1'
    discoveryType = 'remote'
    platform = 'linux'
    probes = @($plan.probes | Select-Object -Skip 1)
}
Assert-True ((Get-RemoteDiscoveryPlanFingerprint -PlanCore $changedCore) -ne $plan.planFingerprint) 'Changed probe ids must change fingerprint.'

Assert-ThrowsLike -Script { New-RemoteToolDiscoveryPlan -Platform windows | Out-Null } -Pattern 'Unsupported remote discovery platform' -Message 'Unknown remote platform must be rejected.'
Assert-ThrowsLike -Script { Get-RemoteDiscoveryProbeDefinition -Platform linux -ProbeId 'remote.unknown' | Out-Null } -Pattern 'Unknown remote discovery probe id' -Message 'Unknown remote probe id must be rejected.'

$commands = (@($plan.probes) | ForEach-Object { $_.displayCommand }) -join "`n"
foreach ($forbidden in @('sudo', 'apt', 'apt-get', 'yum', 'dnf', 'apk', 'brew', 'choco', 'winget', 'curl', 'wget', 'scp', 'ssh', 'rsync', 'rm', 'mv', 'cp', 'chmod', 'chown', 'docker run', 'docker compose up', 'php artisan', 'composer install')) {
    Assert-True (-not ($commands -match [regex]::Escape($forbidden))) "Remote commands must not contain forbidden pattern '$forbidden'."
}

$outputs = New-CompleteOutputMap -Plan $plan
$response = New-RemoteResponse -Plan $plan -Outputs $outputs
$inventory = Resolve-RemoteToolDiscovery -Plan $plan -ResponseText $response

Assert-Equal $inventory.environment 'remote' 'Inventory must declare remote environment.'
Assert-Equal $inventory.discoveryMethod 'human' 'Inventory must declare human discovery method.'
Assert-Equal $inventory.status 'completed' 'Complete marked response must produce completed inventory.'
Assert-Equal $inventory.platform.os 'linux' 'Inventory platform must be linux.'
Assert-Equal $inventory.tools.php.available $true 'Remote PHP must be available when location exists.'
Assert-Equal $inventory.tools.php.version '8.3.12' 'Remote PHP version must be parsed.'
Assert-Equal $inventory.tools.php.status 'available' 'Remote PHP status must be available.'
Assert-Equal $inventory.tools.composer.version '2.8.1' 'Remote Composer version must be parsed.'
Assert-Equal $inventory.tools.docker.available $false 'Empty docker location must be not available.'
Assert-Equal $inventory.tools.docker.status 'not-found' 'Empty docker location must be not-found.'
Assert-Equal $inventory.tools.zip.available $true 'Zip with unreadable version must remain available.'
Assert-Equal $inventory.tools.zip.status 'version-unavailable' 'Unreadable zip version must be version-unavailable.'
Assert-Equal $inventory.tools.tar.available $true 'Tar with failed version probe must remain available.'
Assert-Equal $inventory.tools.tar.status 'probe-failed' 'Technical probe failure must be isolated.'
Assert-Equal $inventory.tools.'7z'.version '24.09' '7z version must be parsed from banner.'
Assert-Equal $inventory.project.artisan.available $true 'Remote artisan file must be detected without execution.'
Assert-Equal $inventory.project.composerJson.available $true 'Remote composer.json must be detected.'
Assert-Equal $inventory.project.packageJson.available $false 'Missing optional project file must be normal result.'
Assert-True (-not ($inventory.PSObject.Properties.Name -contains 'errors')) 'Remote inventory must not expose undefined global errors.'
Assert-Equal (($inventory.tools.PSObject.Properties.Name) -join ',') 'php,composer,docker,7z,zip,tar' 'Remote inventory tool order must match local tool order.'

$missingOutputs = New-CompleteOutputMap -Plan $plan
$missingOutputs.Remove('remote.tool.php.version')
$incomplete = Resolve-RemoteToolDiscovery -Plan $plan -ResponseText (New-RemoteResponse -Plan $plan -Outputs $missingOutputs)
Assert-Equal $incomplete.status 'incomplete' 'Missing required probe must produce incomplete inventory.'
Assert-True ($incomplete.diagnostic -match 'remote.tool.php.version') 'Incomplete inventory must name missing probe.'

Assert-ThrowsLike -Script { Resolve-RemoteToolDiscovery -Plan $plan -ResponseText (New-RemoteResponse -Plan $plan -Outputs $outputs -Fingerprint 'badfingerprint') | Out-Null } -Pattern 'fingerprint mismatch' -Message 'Fingerprint mismatch must be rejected.'

$unknownResponse = "=== PLAN-FINGERPRINT ===`n$($plan.planFingerprint)`n=== END PLAN-FINGERPRINT ===`n`n=== BEGIN remote.unknown ===`nvalue`n=== END remote.unknown ==="
Assert-ThrowsLike -Script { Resolve-RemoteToolDiscovery -Plan $plan -ResponseText $unknownResponse | Out-Null } -Pattern 'unknown probe id' -Message 'Unknown marker probe id must be rejected.'

$duplicateResponse = "=== PLAN-FINGERPRINT ===`n$($plan.planFingerprint)`n=== END PLAN-FINGERPRINT ===`n`n=== BEGIN remote.tool.php.location ===`n/usr/bin/php`n=== END remote.tool.php.location ===`n=== BEGIN remote.tool.php.location ===`n/usr/bin/php`n=== END remote.tool.php.location ==="
Assert-ThrowsLike -Script { Resolve-RemoteToolDiscovery -Plan $plan -ResponseText $duplicateResponse | Out-Null } -Pattern 'duplicate probe id' -Message 'Duplicate marker probe id must be rejected.'

$missingEndResponse = "=== PLAN-FINGERPRINT ===`n$($plan.planFingerprint)`n=== END PLAN-FINGERPRINT ===`n`n=== BEGIN remote.tool.php.location ===`n/usr/bin/php"
Assert-ThrowsLike -Script { Resolve-RemoteToolDiscovery -Plan $plan -ResponseText $missingEndResponse | Out-Null } -Pattern 'missing end marker' -Message 'Missing end marker must be rejected.'

$unmarkedResponse = "=== PLAN-FINGERPRINT ===`n$($plan.planFingerprint)`n=== END PLAN-FINGERPRINT ===`nnot marked"
Assert-ThrowsLike -Script { Resolve-RemoteToolDiscovery -Plan $plan -ResponseText $unmarkedResponse | Out-Null } -Pattern 'unmarked text' -Message 'Unmarked text must be rejected.'

$tooLargeResponse = 'x' * 1048577
Assert-ThrowsLike -Script { Resolve-RemoteToolDiscovery -Plan $plan -ResponseText $tooLargeResponse | Out-Null } -Pattern 'exceeds maximum size' -Message 'Oversized response must be rejected.'

$textOnlyOutputs = New-CompleteOutputMap -Plan $plan
$textOnlyOutputs['remote.tool.php.version'] = '$(Remove-Item important.txt)'
$textInventory = Resolve-RemoteToolDiscovery -Plan $plan -ResponseText (New-RemoteResponse -Plan $plan -Outputs $textOnlyOutputs)
Assert-Equal $textInventory.tools.php.status 'version-unavailable' 'Command-like output must be treated as plain text.'

$cliTemp = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('remote-discovery-cli-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $cliTemp | Out-Null
$cliPlanPath = Join-Path -Path $cliTemp -ChildPath 'plan.json'
$cliResponsePath = Join-Path -Path $cliTemp -ChildPath 'response.txt'
$cliOutputPath = Join-Path -Path $cliTemp -ChildPath 'nested/inventory.json'
$plan | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $cliPlanPath -Encoding UTF8
New-RemoteResponse -Plan $plan -Outputs (New-CompleteOutputMap -Plan $plan) | Set-Content -LiteralPath $cliResponsePath -Encoding UTF8
& $resolverPath -PlanPath $cliPlanPath -ResponsePath $cliResponsePath -OutputPath $cliOutputPath -Format Json | Out-Null
Assert-True (Test-Path -LiteralPath $cliOutputPath -PathType Leaf) 'Direct remote resolver CLI call must create the explicit output path.'
$cliInventory = Get-Content -LiteralPath $cliOutputPath -Raw | ConvertFrom-Json
Assert-Equal $cliInventory.schemaVersion '0.1' 'Direct remote resolver output must be parseable inventory JSON.'
Assert-Equal $cliInventory.environment 'remote' 'Direct remote resolver output must keep remote environment.'
Assert-Equal $cliInventory.discoveryMethod 'human' 'Direct remote resolver output must keep human discovery method.'
Assert-Equal $cliInventory.tools.php.status 'available' 'Direct remote resolver output must include tool results.'
Assert-ThrowsLike -Script { & $resolverPath -PlanPath $cliPlanPath -ResponsePath $cliResponsePath -OutputPath (Join-Path $cliTemp 'invalid.json') -Format Text | Out-Null } -Pattern 'only supports -Format Json' -Message 'Direct remote resolver invalid format must be rejected.'
Remove-Item -LiteralPath $cliTemp -Recurse -Force

if ($script:failures.Count -gt 0) {
    Write-Host 'Remote Tool Discovery tests failed:'
    $script:failures | ForEach-Object { Write-Host "- $_" }
    exit 1
}

Write-Host 'Remote Tool Discovery tests passed.'
exit 0
