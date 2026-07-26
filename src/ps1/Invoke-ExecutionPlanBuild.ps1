[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $AnalysisPath,

    [Parameter(Mandatory = $true)]
    [string] $ProjectManifestPath,

    [ValidateSet('Text', 'Json')]
    [string] $Format = 'Text',

    [string] $OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$executionPlanSchemaVersion = '0.1'
$supportedAnalysisVersions = @('0.1')

function Resolve-LocalPath {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,

        [string] $BasePath
    )

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    if ([string]::IsNullOrWhiteSpace($BasePath)) {
        $BasePath = (Get-Location).Path
    }

    return [System.IO.Path]::GetFullPath((Join-Path -Path $BasePath -ChildPath $Path))
}

function Read-JsonFile {
    param([Parameter(Mandatory = $true)][string] $Path)

    $resolved = Resolve-LocalPath -Path $Path
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
        throw "JSON file not found: $resolved"
    }

    try {
        return [pscustomobject]@{
            path = $resolved
            value = Get-Content -LiteralPath $resolved -Raw | ConvertFrom-Json
        }
    } catch {
        throw "Invalid JSON in '$resolved': $($_.Exception.Message)"
    }
}

function Assert-RequiredValue {
    param(
        [Parameter(Mandatory = $true)]
        [object] $Object,

        [Parameter(Mandatory = $true)]
        [string] $Path,

        [Parameter(Mandatory = $true)]
        [string] $SourceName
    )

    $current = $Object
    foreach ($part in $Path.Split('.')) {
        if ($null -eq $current -or -not ($current.PSObject.Properties.Name -contains $part)) {
            throw "$SourceName validation failed: missing required field '$Path'."
        }
        $current = $current.$part
    }

    if ($null -eq $current -or ([string] $current).Trim().Length -eq 0) {
        throw "$SourceName validation failed: required field '$Path' is empty."
    }
}

function Get-StringArray {
    param($Value)

    if ($null -eq $Value) {
        return @()
    }

    $items = New-Object System.Collections.Generic.List[string]
    foreach ($item in @($Value)) {
        if ($null -ne $item) {
            $items.Add([string] $item)
        }
    }

    return $items.ToArray()
}

function ConvertTo-Array {
    param($Value)

    if ($null -eq $Value) {
        return ,@()
    }

    return ,@($Value)
}

function Get-ItemCount {
    param($Value)

    if ($null -eq $Value) {
        return 0
    }

    return @($Value).Count
}

function Test-PropertyValue {
    param(
        [object] $Object,
        [Parameter(Mandatory = $true)]
        [string] $Name
    )

    return ($null -ne $Object -and $Object.PSObject.Properties.Name -contains $Name -and $null -ne $Object.$Name)
}

function ConvertTo-Bool {
    param(
        [object] $Value,
        [string] $Name
    )

    if ($Value -is [bool]) {
        return $Value
    }

    throw "Analysis validation failed: decision '$Name' must be boolean."
}

function Join-DeploymentPath {
    param(
        [Parameter(Mandatory = $true)][string] $Root,
        [string] $Child
    )

    $normalizedRoot = ($Root -replace '\\', '/').TrimEnd('/')
    if ([string]::IsNullOrWhiteSpace($Child)) {
        return $normalizedRoot
    }

    $normalizedChild = ($Child -replace '\\', '/').Trim('/')
    if ([string]::IsNullOrWhiteSpace($normalizedChild)) {
        return $normalizedRoot
    }

    return "$normalizedRoot/$normalizedChild"
}

function Get-ApplicationRemoteDirectory {
    param([Parameter(Mandatory = $true)][object] $Manifest)

    return Join-DeploymentPath -Root ([string] $Manifest.deployment.serverRoot) -Child ([string] $Manifest.project.applicationRoot)
}

function New-ValidationRule {
    param(
        [bool] $RequiresOutput = $false,
        [bool] $RequiresExitCode = $false,
        [string[]] $SuccessPatterns = @(),
        [string[]] $FailurePatterns = @(),
        [bool] $AmbiguousWithoutSuccessMatch = $false,
        [bool] $VerificationCommandRequired = $false,
        [string] $RequiredResponse = 'Keine Konsolenausgabe erforderlich.'
    )

    return [pscustomobject]@{
        requiresOutput = $RequiresOutput
        requiresExitCode = $RequiresExitCode
        successPatterns = @($SuccessPatterns)
        failurePatterns = @($FailurePatterns)
        ambiguousWithoutSuccessMatch = $AmbiguousWithoutSuccessMatch
        verificationCommandRequired = $VerificationCommandRequired
        requiredResponse = $RequiredResponse
    }
}

function New-ContinuationRule {
    param(
        [string[]] $AllowedStatuses = @('completed', 'skipped'),
        [bool] $blocksAutomaticContinuation = $false,
        [string] $requiredUserAction = ''
    )

    return [pscustomobject]@{
        allowedStatusesForDependents = @($AllowedStatuses)
        blocksAutomaticContinuation = $blocksAutomaticContinuation
        requiredUserAction = $requiredUserAction
    }
}

function New-ExecutionPlanStep {
    param(
        [Parameter(Mandatory = $true)][string] $Id,
        [Parameter(Mandatory = $true)][string] $Phase,
        [Parameter(Mandatory = $true)][string] $Title,
        [Parameter(Mandatory = $true)][ValidateSet('agent', 'human', 'review')][string] $ExecutionMode,
        [bool] $Required = $true,
        [Parameter(Mandatory = $true)][string] $Status,
        [Parameter(Mandatory = $true)][string] $Reason,
        [bool] $ApprovalRequired = $false,
        [bool] $Destructive = $false,
        [ValidateSet('low', 'normal', 'high')]
        [string] $RiskLevel = 'normal',
        [string[]] $DependsOn = @(),
        [object] $Instructions,
        [object] $Validation,
        [object] $Continuation
    )

    if ($null -eq $Instructions) {
        $Instructions = [pscustomobject]@{}
    }
    if ($null -eq $Validation) {
        $Validation = New-ValidationRule
    }
    if ($null -eq $Continuation) {
        $Continuation = New-ContinuationRule
    }

    return [pscustomobject]@{
        id = $Id
        phase = $Phase
        title = $Title
        executionMode = $ExecutionMode
        required = $Required
        status = $Status
        reason = $Reason
        approvalRequired = $ApprovalRequired
        destructive = $Destructive
        riskLevel = $RiskLevel
        dependsOn = @($DependsOn)
        instructions = $Instructions
        validation = $Validation
        continuation = $Continuation
    }
}

function Get-ForbiddenDeploymentCommands {
    return @(
        'php artisan migrate:fresh',
        'php artisan migrate:refresh',
        'php artisan migrate:reset',
        'php artisan migrate:rollback',
        'php artisan db:wipe'
    )
}

function Assert-DeploymentCommandAllowed {
    param([Parameter(Mandatory = $true)][string] $Command)

    $normalizedCommand = ($Command -replace '\s+', ' ').Trim().ToLowerInvariant()
    foreach ($forbiddenCommand in Get-ForbiddenDeploymentCommands) {
        if ($normalizedCommand -eq $forbiddenCommand -or $normalizedCommand.StartsWith("$forbiddenCommand ")) {
            throw "Forbidden deployment command rejected: '$Command'. This command must never be proposed by the Execution Plan Builder."
        }
    }
}

function Get-DeploymentCommandDefinition {
    param([Parameter(Mandatory = $true)][string] $Id)

    $definitions = @{
        'composer.install-production' = [pscustomobject]@{
            command = 'composer install --no-dev --optimize-autoloader'
            purpose = 'PHP-Abhaengigkeiten auf der Zielumgebung installieren.'
            expectedOutcome = 'Composer installiert die benoetigten produktiven Abhaengigkeiten ohne Fehler.'
            requiredResponse = 'Vollstaendige relevante Composer-Konsolenausgabe'
        }
        'artisan.migrate-status' = [pscustomobject]@{
            command = 'php artisan migrate:status'
            purpose = 'Pruefen, welche Migrationen auf der Zielumgebung offen oder bereits ausgefuehrt sind.'
            expectedOutcome = 'Laravel gibt den Status der Migrationen ohne Fehler aus.'
            requiredResponse = 'Vollstaendige relevante Konsolenausgabe von migrate:status'
        }
        'artisan.migrate-force' = [pscustomobject]@{
            command = 'php artisan migrate --force'
            purpose = 'Ausfuehren der noch offenen Datenbankmigrationen.'
            expectedOutcome = 'Alle offenen Migrationen werden erfolgreich abgeschlossen.'
            requiredResponse = 'Vollstaendige relevante Konsolenausgabe'
        }
        'artisan.optimize-clear' = [pscustomobject]@{
            command = 'php artisan optimize:clear'
            purpose = 'Laravel Runtime-Caches nach dem Deployment kontrolliert leeren.'
            expectedOutcome = 'Laravel meldet erfolgreich geleerte Caches.'
            requiredResponse = 'Vollstaendige relevante Konsolenausgabe'
        }
        'artisan.about' = [pscustomobject]@{
            command = 'php artisan about'
            purpose = 'Kontrolle, dass die Laravel-Anwendung auf der Zielumgebung antwortet.'
            expectedOutcome = 'Der Befehl gibt Anwendungs- und Umgebungsinformationen ohne Fehler aus.'
            requiredResponse = 'Vollstaendige relevante Verifikationsausgabe'
        }
    }

    if (-not $definitions.ContainsKey($Id)) {
        throw "Unknown deployment command definition: '$Id'."
    }

    $definition = $definitions[$Id]
    Assert-DeploymentCommandAllowed -Command $definition.command
    return $definition
}

function New-HumanCommandInstructions {
    param(
        [Parameter(Mandatory = $true)][object] $Manifest,
        [string] $CommandId,
        [string] $Command,
        [string] $Purpose,
        [string] $ExpectedOutcome,
        [string] $WorkingDirectory,
        [string] $RequiredResponse = 'Vollstaendige relevante Konsolenausgabe'
    )

    if (-not [string]::IsNullOrWhiteSpace($CommandId)) {
        $definition = Get-DeploymentCommandDefinition -Id $CommandId
        $Command = $definition.command
        $Purpose = $definition.purpose
        $ExpectedOutcome = $definition.expectedOutcome
        $RequiredResponse = $definition.requiredResponse
    }

    if ([string]::IsNullOrWhiteSpace($Command) -or [string]::IsNullOrWhiteSpace($Purpose) -or [string]::IsNullOrWhiteSpace($ExpectedOutcome)) {
        throw "Human command instructions require a command definition or explicit command, purpose and expected outcome."
    }

    Assert-DeploymentCommandAllowed -Command $Command

    if ([string]::IsNullOrWhiteSpace($WorkingDirectory)) {
        $WorkingDirectory = Get-ApplicationRemoteDirectory -Manifest $Manifest
    }

    return [pscustomobject]@{
        environment = [string] $Manifest.deployment.environment
        channel = 'ssh'
        workingDirectory = $WorkingDirectory
        commandId = $CommandId
        command = $Command
        purpose = $Purpose
        expectedOutcome = $ExpectedOutcome
        requiredResponse = $RequiredResponse
    }
}

function Get-BlockedOrWaitingStatus {
    param(
        [string[]] $BlockingDependencies,
        [Parameter(Mandatory = $true)][string] $WaitingStatus
    )

    if ((Get-ItemCount $BlockingDependencies) -gt 0) {
        return 'blocked'
    }

    return $WaitingStatus
}

function Get-DeletedRuntimePaths {
    param([Parameter(Mandatory = $true)][object] $Analysis)

    if (-not (Test-PropertyValue -Object $Analysis -Name 'classifications')) {
        return @()
    }

    return @(
        $Analysis.classifications |
            Where-Object { $_.status -eq 'D' -and $_.classes -notcontains 'ignored' } |
            ForEach-Object { [string] $_.path } |
            Sort-Object -Unique
    )
}

function Get-ProtectedPaths {
    param([Parameter(Mandatory = $true)][object] $Analysis)

    if (-not (Test-PropertyValue -Object $Analysis -Name 'classifications')) {
        return @()
    }

    return @(
        $Analysis.classifications |
            Where-Object { $_.classes -contains 'protected-server-file' -or $_.classes -contains 'protectedServerFile' } |
            ForEach-Object { [string] $_.path } |
            Sort-Object -Unique
    )
}

function Get-MigrationPaths {
    param([Parameter(Mandatory = $true)][object] $Analysis)

    if (-not (Test-PropertyValue -Object $Analysis -Name 'classifications')) {
        return @()
    }

    return @(
        $Analysis.classifications |
            Where-Object { $_.classes -contains 'migrations' } |
            ForEach-Object { [string] $_.path } |
            Sort-Object -Unique
    )
}

function Test-CommandReady {
    param([Parameter(Mandatory = $true)][object] $Instructions)

    @('environment', 'channel', 'workingDirectory', 'command', 'purpose', 'expectedOutcome', 'requiredResponse') | ForEach-Object {
        if (-not (Test-PropertyValue -Object $Instructions -Name $_) -or [string]::IsNullOrWhiteSpace([string] $Instructions.$_)) {
            return $false
        }
    }

    $text = @($Instructions.environment, $Instructions.channel, $Instructions.workingDirectory, $Instructions.command) -join ' '
    return -not ($text -match '<[^>]+>' -or $text -match '\{\{[^}]+\}\}' -or $text -match '\$\{[^}]+\}')
}

function Assert-AnalysisShape {
    param([Parameter(Mandatory = $true)][object] $Analysis)

    @(
        'engineVersion',
        'project.id',
        'environment.name',
        'environment.serverRoot',
        'decisions'
    ) | ForEach-Object { Assert-RequiredValue -Object $Analysis -Path $_ -SourceName 'Analysis' }

    if ($Analysis.engineVersion -notin $supportedAnalysisVersions) {
        throw "Unsupported analysis version '$($Analysis.engineVersion)'. Supported versions: $($supportedAnalysisVersions -join ', ')."
    }

    @(
        'runtimeDeploymentRequired',
        'frontendBuildRequired',
        'composerInstallRequired',
        'migrationsRequired',
        'environmentReviewRequired',
        'cleanupRequired',
        'protectedFileReviewRequired',
        'documentationOnly'
    ) | ForEach-Object {
        Assert-RequiredValue -Object $Analysis.decisions -Path $_ -SourceName 'Analysis'
        [void] (ConvertTo-Bool -Value $Analysis.decisions.$_ -Name $_)
    }
}

function Assert-ManifestShape {
    param([Parameter(Mandatory = $true)][object] $Manifest)

    @(
        'schemaVersion',
        'project.id',
        'project.name',
        'project.applicationRoot',
        'project.type',
        'deployment.environment',
        'deployment.serverRoot',
        'deployment.markerFile',
        'protection.neverUpload',
        'protection.neverOverwrite'
    ) | ForEach-Object { Assert-RequiredValue -Object $Manifest -Path $_ -SourceName 'Manifest' }
}

function New-ExecutionPlanContext {
    param(
        [Parameter(Mandatory = $true)][object] $Analysis,
        [Parameter(Mandatory = $true)][object] $Manifest
    )

    $environmentChanges = if (Test-PropertyValue -Object $Analysis -Name 'environmentChanges') { $Analysis.environmentChanges } else { [pscustomobject]@{} }

    return [pscustomobject]@{
        analysis = $Analysis
        manifest = $Manifest
        decisions = $Analysis.decisions
        blockers = if (Test-PropertyValue -Object $Analysis -Name 'blockers') { @(Get-StringArray $Analysis.blockers) } else { @() }
        warnings = if (Test-PropertyValue -Object $Analysis -Name 'warnings') { @(Get-StringArray $Analysis.warnings) } else { @() }
        manualApprovalPoints = if (Test-PropertyValue -Object $Analysis -Name 'manualApprovalPoints') { @(Get-StringArray $Analysis.manualApprovalPoints) } else { @() }
        environmentChanges = $environmentChanges
        environmentChangePath = if (Test-PropertyValue -Object $environmentChanges -Name 'path') { $environmentChanges.path } else { 'laravel_app/.env.example' }
        environmentAddedKeys = if (Test-PropertyValue -Object $environmentChanges -Name 'addedKeys') { @($environmentChanges.addedKeys) } else { @() }
        environmentRemovedKeys = if (Test-PropertyValue -Object $environmentChanges -Name 'removedKeys') { @($environmentChanges.removedKeys) } else { @() }
        baselineCommit = if (Test-PropertyValue -Object $Analysis -Name 'baselineCommit') { [string] $Analysis.baselineCommit } else { '' }
        targetCommit = if (Test-PropertyValue -Object $Analysis -Name 'targetCommit') { [string] $Analysis.targetCommit } else { '' }
        applicationRemoteDirectory = Get-ApplicationRemoteDirectory -Manifest $Manifest
        runtimeDeletions = @(Get-DeletedRuntimePaths -Analysis $Analysis)
        protectedPaths = @(Get-ProtectedPaths -Analysis $Analysis)
        migrationPaths = @(Get-MigrationPaths -Analysis $Analysis)
        steps = New-Object System.Collections.Generic.List[object]
        gateIds = New-Object System.Collections.Generic.List[string]
        blocked = $false
    }
}

function Add-ExecutionPlanStep {
    param(
        [Parameter(Mandatory = $true)][object] $Context,
        [Parameter(Mandatory = $true)][object] $Step,
        [bool] $BlocksFollowingSteps = $false
    )

    $Context.steps.Add($Step)
    if ($BlocksFollowingSteps -and $Step.required) {
        $Context.gateIds.Add($Step.id)
    }
}

function BuildPreconditions {
    param([Parameter(Mandatory = $true)][object] $Context)

    $Context.blocked = (Get-ItemCount $Context.blockers) -gt 0
    $status = if ($Context.blocked) { 'blocked' } else { 'ready' }
    Add-ExecutionPlanStep -Context $Context -BlocksFollowingSteps:$Context.blocked -Step (New-ExecutionPlanStep `
        -Id 'preconditions.analysis-review' `
        -Phase 'preconditions' `
        -Title 'Analyseergebnis pruefen' `
        -ExecutionMode 'agent' `
        -Status $status `
        -Reason 'Das Analyzer-Ergebnis und das Projektmanifest muessen vor der Planung gueltig sein.' `
        -Instructions ([pscustomobject]@{
            purpose = 'Lokale, rein lesende Pruefung der Analyzer-Ausgabe und Manifestdaten.'
            blockedBy = @($Context.blockers)
            warnings = @($Context.warnings)
        }) `
        -Validation (New-ValidationRule -SuccessPatterns @('Analyzer result accepted') -FailurePatterns @('missing required field', 'Unsupported analysis version', 'Invalid JSON') -AmbiguousWithoutSuccessMatch $false) `
        -Continuation (New-ContinuationRule -blocksAutomaticContinuation:$Context.blocked -requiredUserAction 'Blocker muessen vor jeder Fortsetzung fachlich geklaert werden.'))
}

function BuildEnvironmentReview {
    param([Parameter(Mandatory = $true)][object] $Context)

    if ($Context.decisions.environmentReviewRequired) {
        Add-ExecutionPlanStep -Context $Context -BlocksFollowingSteps $true -Step (New-ExecutionPlanStep `
            -Id 'environment.review' `
            -Phase 'environment-review' `
            -Title 'Environment-Aenderungen pruefen' `
            -ExecutionMode 'review' `
            -Status 'waiting-for-review' `
            -Reason 'Der Analyzer hat Aenderungen am Environment-Vertrag erkannt.' `
            -ApprovalRequired $true `
            -DependsOn @('preconditions.analysis-review') `
            -Instructions ([pscustomobject]@{
                reviewSubject = 'Zielsystem-.env gegen geaenderte .env.example pruefen.'
                environment = [string] $Context.manifest.deployment.environment
                displayedInformation = [pscustomobject]@{
                    path = $Context.environmentChangePath
                    addedKeys = @($Context.environmentAddedKeys)
                    removedKeys = @($Context.environmentRemovedKeys)
                }
                requiredResponse = 'Ausdrueckliche fachliche Freigabe inklusive Bewertung der angezeigten Environment-Aenderungen.'
            }) `
            -Validation (New-ValidationRule -RequiredResponse 'Explizite Review-Freigabe; reine Laufmeldung reicht nicht aus.') `
            -Continuation (New-ContinuationRule -blocksAutomaticContinuation $true -requiredUserAction 'Der Prozess wartet auf ausdrueckliche Environment-Freigabe.'))
    } else {
        Add-ExecutionPlanStep -Context $Context -Step (New-ExecutionPlanStep -Id 'environment.review' -Phase 'environment-review' -Title 'Environment-Aenderungen pruefen' -ExecutionMode 'review' -Required $false -Status 'skipped' -Reason 'Der Analyzer hat keine Environment-Aenderungen erkannt.')
    }

    if ($Context.decisions.protectedFileReviewRequired) {
        Add-ExecutionPlanStep -Context $Context -BlocksFollowingSteps $true -Step (New-ExecutionPlanStep `
            -Id 'environment.protected-files-review' `
            -Phase 'environment-review' `
            -Title 'Geschuetzte Serverdateien pruefen' `
            -ExecutionMode 'review' `
            -Status 'waiting-for-review' `
            -Reason 'Mindestens eine geschuetzte Datei ist betroffen und darf nicht automatisch ueberschrieben werden.' `
            -ApprovalRequired $true `
            -DependsOn @('preconditions.analysis-review') `
            -Instructions ([pscustomobject]@{
                reviewSubject = 'Auswirkungen auf geschuetzte Zielsystemdateien pruefen.'
                affectedPaths = @($Context.protectedPaths)
                requiredResponse = 'Explizite Freigabe oder Ablehnung fuer jede betroffene geschuetzte Datei.'
            }) `
            -Validation (New-ValidationRule -RequiredResponse 'Explizite Review-Freigabe je betroffener Datei.') `
            -Continuation (New-ContinuationRule -blocksAutomaticContinuation $true -requiredUserAction 'Der Prozess wartet auf Review der geschuetzten Dateien.'))
    } else {
        Add-ExecutionPlanStep -Context $Context -Step (New-ExecutionPlanStep -Id 'environment.protected-files-review' -Phase 'environment-review' -Title 'Geschuetzte Serverdateien pruefen' -ExecutionMode 'review' -Required $false -Status 'skipped' -Reason 'Der Analyzer hat keine betroffenen geschuetzten Dateien erkannt.')
    }
}

function BuildFrontendPlan {
    param([Parameter(Mandatory = $true)][object] $Context)

    if ($Context.decisions.frontendBuildRequired) {
        Add-ExecutionPlanStep -Context $Context -Step (New-ExecutionPlanStep `
            -Id 'local.frontend-build.prepare' `
            -Phase 'local-frontend-build' `
            -Title 'Lokalen Frontend-Build vorbereiten' `
            -ExecutionMode 'agent' `
            -Status $(if ((Get-ItemCount $Context.gateIds) -gt 0) { 'blocked' } else { 'ready' }) `
            -Reason 'Frontend-Quellen oder Frontend-Abhaengigkeiten haben sich geaendert.' `
            -DependsOn @($Context.gateIds) `
            -Instructions ([pscustomobject]@{
                purpose = 'Lokale Build-Voraussetzungen und Build-Artefakte pruefen; kein Remote-Befehl.'
                expectedOutcome = 'Ein konsistenter lokaler Vite-Build kann vorbereitet werden.'
            }))
    } else {
        Add-ExecutionPlanStep -Context $Context -Step (New-ExecutionPlanStep -Id 'local.frontend-build.prepare' -Phase 'local-frontend-build' -Title 'Lokalen Frontend-Build vorbereiten' -ExecutionMode 'agent' -Required $false -Status 'skipped' -Reason 'Der Analyzer hat keinen Frontend-Build-Bedarf erkannt.')
    }
}

function BuildLocalPreparationPlan {
    param([Parameter(Mandatory = $true)][object] $Context)

    if ($Context.decisions.runtimeDeploymentRequired -and -not $Context.decisions.documentationOnly) {
        Add-ExecutionPlanStep -Context $Context -Step (New-ExecutionPlanStep `
            -Id 'local.deployment-package.prepare' `
            -Phase 'local-deployment-preparation' `
            -Title 'Lokale Deployment-Vorbereitung modellieren' `
            -ExecutionMode 'agent' `
            -Status $(if ((Get-ItemCount $Context.gateIds) -gt 0) { 'blocked' } else { 'ready' }) `
            -Reason 'Runtime-relevante Artefakte muessen geordnet fuer ein spaeteres Deployment vorbereitet werden.' `
            -DependsOn @($Context.gateIds) `
            -Instructions ([pscustomobject]@{
                purpose = 'Spaetere lokale Paket- oder Pruefsummenbildung vorbereiten; keine Dateiuebertragung.'
                excludedPatterns = @($Context.manifest.protection.neverUpload)
            }))
    } else {
        Add-ExecutionPlanStep -Context $Context -Step (New-ExecutionPlanStep -Id 'local.deployment-package.prepare' -Phase 'local-deployment-preparation' -Title 'Lokale Deployment-Vorbereitung modellieren' -ExecutionMode 'agent' -Required $false -Status 'skipped' -Reason 'Kein Runtime-Deployment erforderlich.')
    }
}

function BuildTransferPlan {
    param([Parameter(Mandatory = $true)][object] $Context)

    if ($Context.decisions.runtimeDeploymentRequired -and -not $Context.decisions.documentationOnly) {
        $dependsOn = @($Context.gateIds + @('local.deployment-package.prepare') | Select-Object -Unique)
        $status = Get-BlockedOrWaitingStatus -BlockingDependencies $Context.gateIds.ToArray() -WaitingStatus 'waiting-for-review'
        Add-ExecutionPlanStep -Context $Context -BlocksFollowingSteps $true -Step (New-ExecutionPlanStep `
            -Id 'runtime.transfer.review' `
            -Phase 'runtime-file-transfer' `
            -Title 'Dateiuebertragung fachlich freigeben' `
            -ExecutionMode 'review' `
            -Status $status `
            -Reason 'Dateiuebertragung ist produktiv wirksam und wird in diesem Auftrag nicht ausgefuehrt.' `
            -ApprovalRequired $true `
            -DependsOn $dependsOn `
            -Instructions ([pscustomobject]@{
                reviewSubject = 'Spaeteren Uebertragungsumfang gegen Schutzregeln und Zielpfad pruefen.'
                environment = [string] $Context.manifest.deployment.environment
                targetRoot = [string] $Context.manifest.deployment.serverRoot
                requiredResponse = 'Explizite Freigabe des spaeteren Uebertragungsplans mit Zielpfad und Umfang.'
            }) `
            -Validation (New-ValidationRule -RequiredResponse 'Explizite Review-Freigabe des Uebertragungsplans.') `
            -Continuation (New-ContinuationRule -blocksAutomaticContinuation $true -requiredUserAction 'Der Prozess wartet auf Freigabe des Uebertragungsplans.'))
    } else {
        Add-ExecutionPlanStep -Context $Context -Step (New-ExecutionPlanStep -Id 'runtime.transfer.review' -Phase 'runtime-file-transfer' -Title 'Dateiuebertragung fachlich freigeben' -ExecutionMode 'review' -Required $false -Status 'skipped' -Reason 'Keine Runtime-Dateiuebertragung erforderlich.')
    }
}

function BuildCleanupPlan {
    param([Parameter(Mandatory = $true)][object] $Context)

    if ($Context.decisions.cleanupRequired) {
        $status = Get-BlockedOrWaitingStatus -BlockingDependencies $Context.gateIds.ToArray() -WaitingStatus 'waiting-for-review'
        Add-ExecutionPlanStep -Context $Context -BlocksFollowingSteps $true -Step (New-ExecutionPlanStep `
            -Id 'runtime.cleanup.review' `
            -Phase 'runtime-cleanup' `
            -Title 'Kontrollierten Runtime-Cleanup freigeben' `
            -ExecutionMode 'review' `
            -Status $status `
            -Reason 'Der Analyzer hat geloeschte Runtime-Pfade erkannt.' `
            -ApprovalRequired $true `
            -Destructive $true `
            -DependsOn @($Context.gateIds) `
            -Instructions ([pscustomobject]@{
                reviewSubject = 'Jeden zu entfernenden Runtime-Pfad einzeln pruefen; keine generische rekursive Loeschung.'
                affectedPaths = @($Context.runtimeDeletions)
                forbiddenCommandShapes = @('rm -rf *', 'Remove-Item -Recurse ohne explizite LiteralPath-Liste')
                requiredResponse = 'Explizite destruktive Freigabe inklusive konkret bestaetigter Pfadliste.'
            }) `
            -Validation (New-ValidationRule -RequiredResponse 'Explizite destruktive Freigabe je Pfad; reine Bestaetigung reicht nicht.') `
            -Continuation (New-ContinuationRule -blocksAutomaticContinuation $true -requiredUserAction 'Der Prozess wartet auf destruktive Cleanup-Freigabe.'))
    } else {
        Add-ExecutionPlanStep -Context $Context -Step (New-ExecutionPlanStep -Id 'runtime.cleanup.review' -Phase 'runtime-cleanup' -Title 'Kontrollierten Runtime-Cleanup freigeben' -ExecutionMode 'review' -Required $false -Status 'skipped' -Reason 'Der Analyzer hat keine Runtime-Loeschungen erkannt.')
    }
}

function BuildComposerPlan {
    param([Parameter(Mandatory = $true)][object] $Context)

    if ($Context.decisions.composerInstallRequired) {
        $instructions = New-HumanCommandInstructions -Manifest $Context.manifest -CommandId 'composer.install-production'
        $status = if (Test-CommandReady -Instructions $instructions) { Get-BlockedOrWaitingStatus -BlockingDependencies $Context.gateIds.ToArray() -WaitingStatus 'waiting-for-human' } else { 'blocked' }
        Add-ExecutionPlanStep -Context $Context -BlocksFollowingSteps $true -Step (New-ExecutionPlanStep `
            -Id 'remote.dependencies.composer-install' `
            -Phase 'remote-dependency-installation' `
            -Title 'Remote Composer-Installation ausfuehren lassen' `
            -ExecutionMode 'human' `
            -Status $status `
            -Reason 'Composer-Abhaengigkeiten haben sich laut Analyzer geaendert.' `
            -ApprovalRequired $true `
            -DependsOn @($Context.gateIds) `
            -Instructions $instructions `
            -Validation (New-ValidationRule -RequiresOutput $true -SuccessPatterns @('Generating optimized autoload files', 'Nothing to install, update or remove') -FailurePatterns @('ERROR', 'Exception', 'failed', 'Could not', 'Script .* returned with error code') -AmbiguousWithoutSuccessMatch $true -RequiredResponse 'Vollstaendige relevante Composer-Konsolenausgabe') `
            -Continuation (New-ContinuationRule -blocksAutomaticContinuation $true -requiredUserAction 'Der Prozess wartet auf Konsolenausgabe und erfolgreiche Bewertung.'))
    } else {
        Add-ExecutionPlanStep -Context $Context -Step (New-ExecutionPlanStep -Id 'remote.dependencies.composer-install' -Phase 'remote-dependency-installation' -Title 'Remote Composer-Installation ausfuehren lassen' -ExecutionMode 'human' -Required $false -Status 'skipped' -Reason 'Der Analyzer hat keinen Composer-Installationsbedarf erkannt.')
    }
}

function BuildMigrationPlan {
    param([Parameter(Mandatory = $true)][object] $Context)

    if (-not $Context.decisions.migrationsRequired) {
        Add-ExecutionPlanStep -Context $Context -Step (New-ExecutionPlanStep -Id 'remote.migrations.execute' -Phase 'remote-migrations' -Title 'Datenbankmigrationen ausfuehren' -ExecutionMode 'human' -Required $false -Status 'skipped' -Reason 'Der Analyzer hat keinen Migrationsbedarf erkannt.')
        return
    }

    $reviewStatus = Get-BlockedOrWaitingStatus -BlockingDependencies $Context.gateIds.ToArray() -WaitingStatus 'waiting-for-review'
    Add-ExecutionPlanStep -Context $Context -BlocksFollowingSteps $true -Step (New-ExecutionPlanStep `
        -Id 'remote.migrations.safety-review' `
        -Phase 'remote-migrations' `
        -Title 'Migrationsrisiko und Backup pruefen' `
        -ExecutionMode 'review' `
        -Status $reviewStatus `
        -Reason 'Migrationen koennen Datenbankstruktur und Datenbestand veraendern und benoetigen eine vorgelagerte Sicherheitsfreigabe.' `
        -ApprovalRequired $true `
        -RiskLevel 'high' `
        -DependsOn @($Context.gateIds) `
        -Instructions ([pscustomobject]@{
            reviewSubject = 'Auszufuehrende Migrationen, Datenbank-Backup und Freigabe vor migrate:status und migrate pruefen.'
            affectedMigrationFiles = @($Context.migrationPaths)
            backupRequired = $true
            requiredResponse = 'Ausdrueckliche Freigabe inklusive Bestaetigung, dass ein geeignetes Datenbank-Backup vorhanden ist.'
        }) `
        -Validation (New-ValidationRule -RequiredResponse 'Explizite High-Risk-Freigabe mit Backup-Bestaetigung.') `
        -Continuation (New-ContinuationRule -blocksAutomaticContinuation $true -requiredUserAction 'Der Prozess wartet auf Migrationsfreigabe und Backup-Bestaetigung.'))

    $statusInstructions = New-HumanCommandInstructions -Manifest $Context.manifest -CommandId 'artisan.migrate-status'
    $statusStatus = if (Test-CommandReady -Instructions $statusInstructions) { Get-BlockedOrWaitingStatus -BlockingDependencies $Context.gateIds.ToArray() -WaitingStatus 'waiting-for-human' } else { 'blocked' }
    Add-ExecutionPlanStep -Context $Context -BlocksFollowingSteps $true -Step (New-ExecutionPlanStep `
        -Id 'remote.migrations.status' `
        -Phase 'remote-migrations' `
        -Title 'Migrationsstatus pruefen lassen' `
        -ExecutionMode 'human' `
        -Status $statusStatus `
        -Reason 'Vor der Ausfuehrung muss der aktuelle Migrationsstatus der Zielumgebung sichtbar sein.' `
        -ApprovalRequired $true `
        -RiskLevel 'high' `
        -DependsOn @($Context.gateIds) `
        -Instructions $statusInstructions `
        -Validation (New-ValidationRule -RequiresOutput $true -SuccessPatterns @('Migration', 'Ran?') -FailurePatterns @('ERROR', 'Exception', 'SQLSTATE', 'failed') -AmbiguousWithoutSuccessMatch $true -RequiredResponse 'Vollstaendige relevante Konsolenausgabe von migrate:status') `
        -Continuation (New-ContinuationRule -blocksAutomaticContinuation $true -requiredUserAction 'Der Prozess wartet auf migrate:status-Ausgabe und Bewertung.'))

    $instructions = New-HumanCommandInstructions -Manifest $Context.manifest -CommandId 'artisan.migrate-force'
    $executeStatus = if (Test-CommandReady -Instructions $instructions) { Get-BlockedOrWaitingStatus -BlockingDependencies $Context.gateIds.ToArray() -WaitingStatus 'waiting-for-human' } else { 'blocked' }
    Add-ExecutionPlanStep -Context $Context -BlocksFollowingSteps $true -Step (New-ExecutionPlanStep `
        -Id 'remote.migrations.execute' `
        -Phase 'remote-migrations' `
        -Title 'Datenbankmigrationen ausfuehren' `
        -ExecutionMode 'human' `
        -Status $executeStatus `
        -Reason 'Seit der Deployment-Baseline wurden neue oder geaenderte Migrationen erkannt.' `
        -ApprovalRequired $true `
        -RiskLevel 'high' `
        -DependsOn @($Context.gateIds) `
        -Instructions $instructions `
        -Validation (New-ValidationRule -RequiresOutput $true -SuccessPatterns @('Migrated:', 'Nothing to migrate') -FailurePatterns @('ERROR', 'Exception', 'Migration failed', 'SQLSTATE') -AmbiguousWithoutSuccessMatch $true -RequiredResponse 'Vollstaendige relevante Konsolenausgabe') `
        -Continuation (New-ContinuationRule -blocksAutomaticContinuation $true -requiredUserAction 'Der Prozess wartet auf Konsolenausgabe und erfolgreiche Bewertung.'))
}

function BuildMaintenancePlan {
    param([Parameter(Mandatory = $true)][object] $Context)

    $maintenanceRequired = $Context.decisions.runtimeDeploymentRequired -and -not $Context.decisions.documentationOnly
    if ($maintenanceRequired) {
        $instructions = New-HumanCommandInstructions -Manifest $Context.manifest -CommandId 'artisan.optimize-clear'
        $status = if (Test-CommandReady -Instructions $instructions) { Get-BlockedOrWaitingStatus -BlockingDependencies $Context.gateIds.ToArray() -WaitingStatus 'waiting-for-human' } else { 'blocked' }
        Add-ExecutionPlanStep -Context $Context -BlocksFollowingSteps $true -Step (New-ExecutionPlanStep `
            -Id 'remote.runtime.cache-clear' `
            -Phase 'remote-runtime-maintenance' `
            -Title 'Remote Runtime-Caches leeren lassen' `
            -ExecutionMode 'human' `
            -Status $status `
            -Reason 'Nach Runtime-Aenderungen ist eine serverseitige Runtime-Wartung einzuplanen.' `
            -ApprovalRequired $true `
            -DependsOn @($Context.gateIds) `
            -Instructions $instructions `
            -Validation (New-ValidationRule -RequiresOutput $true -SuccessPatterns @('cleared', 'Caches cleared successfully') -FailurePatterns @('ERROR', 'Exception', 'failed', 'Permission denied') -AmbiguousWithoutSuccessMatch $true -RequiredResponse 'Vollstaendige relevante Konsolenausgabe') `
            -Continuation (New-ContinuationRule -blocksAutomaticContinuation $true -requiredUserAction 'Der Prozess wartet auf Konsolenausgabe und erfolgreiche Bewertung.'))
    } else {
        Add-ExecutionPlanStep -Context $Context -Step (New-ExecutionPlanStep -Id 'remote.runtime.cache-clear' -Phase 'remote-runtime-maintenance' -Title 'Remote Runtime-Caches leeren lassen' -ExecutionMode 'human' -Required $false -Status 'skipped' -Reason 'Keine Runtime-Wartung erforderlich.')
    }
}

function BuildVerificationPlan {
    param([Parameter(Mandatory = $true)][object] $Context)

    if ($Context.decisions.runtimeDeploymentRequired -and -not $Context.decisions.documentationOnly) {
        $instructions = New-HumanCommandInstructions -Manifest $Context.manifest -CommandId 'artisan.about'
        $status = if (Test-CommandReady -Instructions $instructions) { Get-BlockedOrWaitingStatus -BlockingDependencies $Context.gateIds.ToArray() -WaitingStatus 'waiting-for-human' } else { 'blocked' }
        Add-ExecutionPlanStep -Context $Context -BlocksFollowingSteps $true -Step (New-ExecutionPlanStep `
            -Id 'deployment.verification.remote-about' `
            -Phase 'deployment-verification' `
            -Title 'Deployment auf Zielumgebung verifizieren lassen' `
            -ExecutionMode 'human' `
            -Status $status `
            -Reason 'Vor dem Marker-Update muss das Deployment serverseitig verifiziert werden.' `
            -ApprovalRequired $true `
            -DependsOn @($Context.gateIds) `
            -Instructions $instructions `
            -Validation (New-ValidationRule -RequiresOutput $true -SuccessPatterns @('Environment', 'Laravel') -FailurePatterns @('ERROR', 'Exception', 'failed', 'SQLSTATE') -AmbiguousWithoutSuccessMatch $true -VerificationCommandRequired $true -RequiredResponse 'Vollstaendige relevante Verifikationsausgabe') `
            -Continuation (New-ContinuationRule -blocksAutomaticContinuation $true -requiredUserAction 'Der Prozess wartet auf Verifikationsausgabe und erfolgreiche Bewertung.'))
    } else {
        Add-ExecutionPlanStep -Context $Context -Step (New-ExecutionPlanStep -Id 'deployment.verification.remote-about' -Phase 'deployment-verification' -Title 'Deployment auf Zielumgebung verifizieren lassen' -ExecutionMode 'human' -Required $false -Status 'skipped' -Reason 'Keine serverseitige Deployment-Verifikation erforderlich.')
    }
}

function BuildMarkerPlan {
    param([Parameter(Mandatory = $true)][object] $Context)

    Add-ExecutionPlanStep -Context $Context -Step (New-ExecutionPlanStep `
        -Id 'deployment-marker.update' `
        -Phase 'deployment-marker-update' `
        -Title 'Deployment-Marker aktualisieren' `
        -ExecutionMode 'review' `
        -Status $(if ($Context.decisions.documentationOnly -or -not $Context.decisions.runtimeDeploymentRequired) { 'skipped' } else { 'blocked' }) `
        -Required $($Context.decisions.runtimeDeploymentRequired -and -not $Context.decisions.documentationOnly) `
        -Reason 'Die .deploy-version darf erst nach vollstaendig erfolgreichem Deployment und erfolgreicher Verifikation aktualisiert werden.' `
        -ApprovalRequired $true `
        -DependsOn @($Context.gateIds) `
        -Instructions ([pscustomobject]@{
            markerFile = [string] $Context.manifest.deployment.markerFile
            targetCommit = $Context.targetCommit
            requiredConditions = @(
                'Alle erforderlichen Schritte sind completed oder fachlich korrekt skipped.',
                'Keine Blocker bestehen.',
                'Alle Human Gates wurden anhand der Konsolenausgabe erfolgreich bewertet.',
                'Alle Review Gates und destruktiven Schritte wurden ausdruecklich freigegeben.',
                'Die Deployment-Verifikation war erfolgreich.'
            )
            requiredResponse = 'Explizite finale Freigabe nach erfolgreicher Verifikation; in diesem Auftrag wird die Datei nicht geschrieben.'
        }) `
        -Validation (New-ValidationRule -RequiredResponse 'Finale Freigabe nach nachweislich erfolgreicher Verifikation.') `
        -Continuation (New-ContinuationRule -blocksAutomaticContinuation $true -requiredUserAction 'Marker-Update bleibt bis zum vollstaendigen Erfolg blockiert.'))
}

function ConvertTo-ExecutionPlanResult {
    param([Parameter(Mandatory = $true)][object] $Context)

    $result = [ordered]@{}
    $result.schemaVersion = $executionPlanSchemaVersion
    $result.sourceAnalysisVersion = [string] $Context.analysis.engineVersion
    $result.blocked = [bool] $Context.blocked
    $result.project = [pscustomobject]@{
        id = [string] $Context.manifest.project.id
        name = [string] $Context.manifest.project.name
        type = [string] $Context.manifest.project.type
    }
    $result.environment = [pscustomobject]@{
        name = [string] $Context.manifest.deployment.environment
        serverRoot = [string] $Context.manifest.deployment.serverRoot
        applicationRemoteDirectory = $Context.applicationRemoteDirectory
        markerFile = [string] $Context.manifest.deployment.markerFile
    }
    $result.baselineCommit = $Context.baselineCommit
    $result.targetCommit = $Context.targetCommit
    $result.decisions = $Context.decisions
    $result.warnings = ConvertTo-Array $Context.warnings
    $result.blockers = ConvertTo-Array $Context.blockers
    $result.manualApprovalPoints = ConvertTo-Array $Context.manualApprovalPoints
    $result.phases = @(
        'preconditions',
        'environment-review',
        'local-frontend-build',
        'local-deployment-preparation',
        'runtime-file-transfer',
        'runtime-cleanup',
        'remote-dependency-installation',
        'remote-migrations',
        'remote-runtime-maintenance',
        'deployment-verification',
        'deployment-marker-update'
    )
    $result.steps = $Context.steps.ToArray()

    return [pscustomobject] $result
}

function New-ExecutionPlan {
    param(
        [Parameter(Mandatory = $true)][object] $Analysis,
        [Parameter(Mandatory = $true)][object] $Manifest
    )

    Assert-AnalysisShape -Analysis $Analysis
    Assert-ManifestShape -Manifest $Manifest

    $context = New-ExecutionPlanContext -Analysis $Analysis -Manifest $Manifest
    BuildPreconditions -Context $context
    BuildEnvironmentReview -Context $context
    BuildFrontendPlan -Context $context
    BuildLocalPreparationPlan -Context $context
    BuildTransferPlan -Context $context
    BuildCleanupPlan -Context $context
    BuildComposerPlan -Context $context
    BuildMigrationPlan -Context $context
    BuildMaintenancePlan -Context $context
    BuildVerificationPlan -Context $context
    BuildMarkerPlan -Context $context

    return ConvertTo-ExecutionPlanResult -Context $context
}

function Test-ManualStepOutput {
    param(
        [Parameter(Mandatory = $true)][object] $Step,
        [string] $Output,
        [int] $ExitCode
    )

    if ($Step.executionMode -ne 'human') {
        return 'ambiguous'
    }

    $validation = $Step.validation
    $outputText = if ($null -eq $Output) { '' } else { [string] $Output }

    if ($validation.requiresOutput -and [string]::IsNullOrWhiteSpace($outputText)) {
        return 'incomplete'
    }

    $confirmationOnly = @('erledigt', 'lief durch', 'done', 'ok', 'fertig')
    if ($validation.requiresOutput -and $confirmationOnly -contains $outputText.Trim().ToLowerInvariant()) {
        return 'incomplete'
    }

    foreach ($pattern in @($validation.failurePatterns)) {
        if (-not [string]::IsNullOrWhiteSpace($pattern) -and $outputText -match $pattern) {
            return 'failed'
        }
    }

    if ($validation.requiresExitCode -and $ExitCode -ne 0) {
        return 'failed'
    }

    foreach ($pattern in @($validation.successPatterns)) {
        if (-not [string]::IsNullOrWhiteSpace($pattern) -and $outputText -match $pattern) {
            return 'completed'
        }
    }

    if ($validation.ambiguousWithoutSuccessMatch) {
        return 'ambiguous'
    }

    return 'completed'
}

function Write-HumanGateText {
    param([Parameter(Mandatory = $true)][object] $Step)

    Write-Host 'PAUSE - MANUELLE AUSFUEHRUNG ERFORDERLICH'
    Write-Host ''
    if ($Step.destructive) {
        Write-Host 'WARNUNG: Dieser Schritt ist destruktiv oder kann irreversible Auswirkungen haben.'
        Write-Host ''
    }
    Write-Host 'Schritt:'
    Write-Host $Step.title
    Write-Host ''
    Write-Host 'Zielumgebung:'
    Write-Host $Step.instructions.environment
    Write-Host ''
    Write-Host 'Arbeitsverzeichnis:'
    Write-Host $Step.instructions.workingDirectory
    Write-Host ''
    Write-Host 'Auszufuehrender Befehl:'
    Write-Host $Step.instructions.command
    Write-Host ''
    Write-Host 'Zweck:'
    Write-Host $Step.instructions.purpose
    Write-Host ''
    Write-Host 'Erwartetes Ergebnis:'
    Write-Host $Step.instructions.expectedOutcome
    Write-Host ''
    Write-Host 'Moegliche Fehlermerkmale:'
    @($Step.validation.failurePatterns) | ForEach-Object { Write-Host $_ }
    Write-Host ''
    Write-Host 'Benoetigte Rueckmeldung:'
    Write-Host ('Bitte die {0} posten.' -f $Step.instructions.requiredResponse.ToLowerInvariant())
    Write-Host ''
    Write-Host 'Der Deployment-Prozess bleibt bis zur erfolgreichen Analyse der Ausgabe pausiert.'
}

function Write-ExecutionPlanSummary {
    param([Parameter(Mandatory = $true)][object] $Plan)

    Write-Host "SHK-MOMM Execution Plan v$($Plan.schemaVersion)"
    Write-Host "Project: $($Plan.project.name) [$($Plan.environment.name)]"
    Write-Host "Blocked: $($Plan.blocked)"
    Write-Host "Steps: $(@($Plan.steps).Count)"
    Write-Host ''
    Write-Host 'Decisions:'
    $Plan.decisions.PSObject.Properties | ForEach-Object {
        Write-Host ("- {0}: {1}" -f $_.Name, $_.Value)
    }

    if (@($Plan.blockers).Count -gt 0) {
        Write-Host ''
        Write-Host 'Blockers:'
        $Plan.blockers | ForEach-Object { Write-Host "- $_" }
    }

    Write-Host ''
    Write-Host 'Steps:'
    foreach ($step in $Plan.steps) {
        $flag = if ($step.required) { 'required' } else { 'skipped' }
        Write-Host ("- {0} [{1}/{2}/{3}]" -f $step.id, $step.phase, $step.executionMode, $flag)
        Write-Host ("  Status: {0}" -f $step.status)
        if ($step.executionMode -eq 'human' -and $step.required) {
            Write-Host ("  Command: {0}" -f $step.instructions.command)
            Write-Host ("  Working directory: {0}" -f $step.instructions.workingDirectory)
        }
    }

    [object[]] $firstHumanStep = @($Plan.steps | Where-Object { $_.executionMode -eq 'human' -and $_.required -and $_.status -eq 'waiting-for-human' } | Select-Object -First 1)
    if (@($firstHumanStep).Count -gt 0) {
        Write-Host ''
        Write-HumanGateText -Step $firstHumanStep[0]
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    $analysisResult = Read-JsonFile -Path $AnalysisPath
    $manifestResult = Read-JsonFile -Path $ProjectManifestPath
    $executionPlan = New-ExecutionPlan -Analysis $analysisResult.value -Manifest $manifestResult.value

    if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
        $resolvedOutputPath = Resolve-LocalPath -Path $OutputPath
        $outputDirectory = Split-Path -Path $resolvedOutputPath -Parent
        if (-not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
            throw "Output directory does not exist: $outputDirectory"
        }
        $executionPlan | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $resolvedOutputPath -Encoding utf8
    }

    if ($Format -eq 'Json') {
        $executionPlan | ConvertTo-Json -Depth 30
    } else {
        Write-ExecutionPlanSummary -Plan $executionPlan
    }

    if ($executionPlan.blocked) {
        exit 2
    }

    exit 0
}
