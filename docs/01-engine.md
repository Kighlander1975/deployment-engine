# Engine Pipeline

Die Pipeline der Version `0.1` ist bewusst in Analyse, Planerzeugung, Capability-Aufloesung, Tool Discovery, Adapterentscheidung, Runtime Directory Management, Clean-Tree Assessment, Deployment Strategy, Command Generation, Command Session, Execution Admission, Executor Request, Local Operation Executor, Automation Event Builder, Execution Orchestrator und spaetere Remote-/Deployment-Orchestrierung getrennt.

## Project Catalog

Der Project Catalog ist eine eigenstaendige Domaene vor der Deployment Analysis.

```text
CLI
    -> Project Catalog
    -> Manifest-Erkennung und Validierung
    -> strukturiertes Discovery- oder Resolution-Ergebnis
```

Die CLI ist dabei nur Adapter. Manifest-Suche, Eligibility-Bewertung, Identifier-Konflikte und Resolution-Regeln liegen in der Project-Catalog-Domaene.

`discover-projects` verlangt einen expliziten `ProjectsRoot`. Die Suche ist read-only, bleibt innerhalb dieses Roots, folgt keinen Reparse-Directories wie Junctions oder Symlinks und verwendet eine begrenzte Verzeichnistiefe. Gefunden werden Dateien mit dem Namen `deployment.project.json`. Das Ergebnis ist deterministisch nach normalisierter Projekt-ID und Manifestpfad sortiert.

`resolve-project` verlangt `ProjectsRoot` und `ProjectIdentifier`. Die Resolution verwendet intern den Katalog und loest nur exakte `project.id`-Werte oder exakte `project.aliases` auf, jeweils case-insensitive. `project.name` wird nicht aufgeloest. Teilstrings, Starts-with, Contains, Edit Distance, Fuzzy Matching, aktuelles Arbeitsverzeichnis, Repository-Name, einziges Projekt und zuletzt verwendete Werte sind keine automatische Aufloesung.

Eligibility-Werte sind `eligible`, `ineligible`, `invalid-manifest`, `duplicate-id` und `identifier-conflict`. Resolution-Statuswerte sind `resolved`, `not-found`, `ambiguous`, `invalid`, `ineligible` und `identifier-conflict`. Vorschlaege duerfen ausgegeben werden, bleiben aber unverbindlich; auch ein einzelner Vorschlag ergibt nicht `resolved`.

Der Project Catalog startet keinen Analyzer, erzeugt keinen Execution Plan, fuehrt keine Tool Discovery aus, erzeugt keine Archive, startet kein SSH/SCP und schreibt nur dann eine Datei, wenn `-OutputPath` explizit gesetzt ist.

Domain-Skripte im Project Catalog verwenden keine expliziten `exit`-Anweisungen. Sie liefern strukturierte Ergebnisobjekte beziehungsweise JSON und duerfen eine bestehende PowerShell-Sitzung bei Aufruf mit Dot-Sourcing oder `&` nicht beenden. Erwartbare fachliche Ablehnungen werden als Statuswerte modelliert; technische Fehler werden per `throw` signalisiert.

Die CLI-Zweige fuer `discover-projects` und `resolve-project` folgen derselben No-Exit-Regel. Andere historisch vorhandene CLI-Zweige enthalten noch explizite `exit`-Anweisungen; deren Refactoring bleibt als abgegrenzte technische Folgemassnahme offen.

## Project Detection

Die Engine liest das Projektmanifest, validiert Pflichtfelder und prueft, ob Projektroot und Application Root vorhanden sind. Pfade werden unabhaengig vom aktuellen Arbeitsverzeichnis aufgeloest.

## Repository Analysis

Die Engine prueft, ob der Projektroot ein Git-Repository ist, ermittelt den Arbeitsbaumstatus, loest Ziel- und Baselinecommit auf und zaehlt die Commits seit der Baseline. Ist die Baseline kein Vorfahr des Zielcommits, wird dies als Blocker ausgewiesen.

## Artifact Classification

Der Git-Diff wird mit `--name-status --find-renames` ausgewertet. Jede betroffene Datei wird anhand des Projektmanifests einer oder mehreren Artefaktklassen zugeordnet.

## Rule Evaluation

Die Regelbewertung leitet Entscheidungen aus den Klassifikationen und besonderen Dateiarten ab. Dazu gehoeren Composer-Schritte, Frontend-Build, Migrationsbedarf, Environment-Review, Seeder-Review, Cleanup und geschuetzte Dateien.

## Analyzer-Ergebnis

Das Analyzer-Ergebnis fasst Eingangsdaten, Git-Zustand, geaenderte Dateien, Klassifikationen, Environment-Aenderungen, Seeder-Review, Entscheidungen, Warnungen, Blocker und manuelle Freigabepunkte zusammen.

Der Analyzer fuehrt keine Deployment-Aktion aus und trifft keine Aussage darueber, ob ein Schritt bereits erledigt ist.

## Execution Plan Builder

Der Execution Plan Builder liest das Analyzer-Ergebnis und das Projektmanifest. Daraus erzeugt er einen geordneten, deterministischen Execution Plan.

Jeder Planschritt enthaelt mindestens:

- stabile Schritt-ID,
- Phase,
- Titel,
- Ausfuehrungsmodus `agent`, `human` oder `review`,
- Risikostufe,
- Pflicht-/Skip-Status,
- initialen Zustand,
- Begruendung,
- Freigabepflicht,
- destruktive Kennzeichnung,
- Abhaengigkeiten,
- Ausfuehrungsanweisungen,
- Validierungsregeln,
- Fortsetzungsbedingungen.

Blocker aus dem Analyzer werden nicht als normale ausfuehrbare Schritte behandelt. Wenn Blocker vorhanden sind, wird der Plan als blockiert markiert und darf nicht fortgesetzt werden.

## Capability Layer

Der Execution Plan Builder erzeugt fuer technische Anforderungen nur `capabilityId`-Werte. Er beschreibt damit, was benoetigt wird, nicht wie ein Werkzeug konkret aufgerufen wird.

Der Capability Resolver liest den Execution Plan und den zentralen Capability-Katalog. Daraus erzeugt er einen neuen Resolved Execution Plan. Der uebergebene unresolved Plan wird dabei nicht veraendert.

```text
Execution Plan
    -> Capability Resolver
    -> Resolved Execution Plan
```

Der Resolver fuehrt keine Aktionen aus. Er trifft keine automatische Adapterwahl, entdeckt keine Tools und erzeugt keine dynamischen Shell-Kommandos.

## Runtime-Dateien

Deployment-Laufzeitdaten und erzeugte Artefakte werden ausserhalb des Deployment-Engine-Repositories und des zu deployenden Projekt-Repositories abgelegt. Jeder Deployment-Lauf erhaelt ein eigenes externes Run-Verzeichnis.

Spaetere Laufdaten koennen beispielsweise Inventare, Assessments, Entscheidungen, Strategien, Command Plans, Command Sessions, Execution Admissions, Executor Requests, Executor Results, Archive, Logs und Reports umfassen. Adapter Eligibility Evaluation, Adapter Selection, Runtime Directory Management, Clean-Tree Assessment, Deployment Strategy, Command Generation, Command Session, Execution Admission, Executor Request und Local Operation Executor schreiben weiterhin nur dann eine Datei, wenn explizit `-OutputPath` uebergeben wurde.

Runtime Directory Management erzeugt unter einem expliziten, bereits vorhandenen Runtime Root ein eindeutiges Run-Verzeichnis mit `artifacts`, `decisions`, `events`, `input`, `inventory`, `logs` und `reports`. Die Ausgabe ist ein Metadatenobjekt mit den erzeugten Pfaden. Die Komponente erzeugt keine Session, fuehrt keine Git-Pruefung aus, startet keinen Executor und fuehrt kein Deployment aus.

Runtime-Artefakte sind laufzeitbezogene Ergebnisse eines konkreten Deployment-Laufs. Sie werden nicht in den resolved Execution Plan geschrieben. `archive.create` erzeugt fuer das Build-Archiv ein Runtime-Artefakt mit `artifactId`, `artifactType`, `archiveFormat`, `localPath`, `fileName`, `fileSize`, `hash`, `executionPlanFingerprint`, `packagingPolicyId`, `packagingPolicyFingerprint`, `packagingValidation` und `createdAt`. Das Objekt beschreibt nur das erzeugte Artefakt, keine Projekt- oder Target-Konfiguration. Es wird unter `artifacts/runtime-artifact-*.json` im Runtime-Verzeichnis persistiert und darf wegen der Fingerprint- und Packaging-Policy-Bindung nicht mit einem anderen Execution Plan oder einer anderen Policy wiederverwendet werden.

Packaging Policies sind eigene Vertragsobjekte fuer Deployment-Artefakte. Mindestfelder sind `policyId`, `projectId`, `artifactType`, `vendorStrategy`, `includedPaths`, `excludedPaths`, `executionPlanFingerprint` und `createdAt`. `includedPaths` beschreibt die erlaubten Quellpfade; `excludedPaths` beschreibt harte Ausschluesse. `archive.create` darf kein Deployment-Archiv ohne passende Policy erzeugen.

Die Standard-Sicherheitsgrenze fuer normale Deployment-Archive lautet: keine `.env`-Dateien, keine `.git`-Daten, keine verschachtelten Deployment-Artefakte, keine persistenten Laufzeitdaten, keine Logs, keine Framework-Caches, keine Sessions, keine Views, keine Betriebssystem-/IDE-Dateien, keine temporaeren Dateien und keine lokalen Backups. `vendorStrategy = exclude-install-on-target-from-lockfiles` bedeutet, dass `vendor` und `node_modules` nicht gepackt werden; PHP-Abhaengigkeiten muessen aus `composer.lock` auf dem Ziel bereitgestellt werden und Frontend-Abhaengigkeiten muessen lokal vorab in `public/build` gebaut sein.

Der Composer-Strategy-Vertrag gehoert zur Deployment Strategy, nicht zum resolved Execution Plan und nicht zum Runtime-Artefakt. Er beschreibt fuer Laravel-Deployments mit ausgeschlossener `vendor`-Auslieferung die geplante Vendor-Bereitstellung aus `composer.lock`: Strategy-ID, Version, Composer-Arbeitsverzeichnis, Manifest- und Lockfile-Pfade, Produktionsmodus, Dev-Abhaengigkeitsregel, Script-/Plugin-Review, Plattformanforderungen und Timeout-/Environment-Policy. Eine Aenderung dieses Vertrags aendert den Execution-Plan-Fingerprint nicht, invalidiert aber Strategy und Command Plan.

`remote.composer.preflight` ist ein eigener read-only Human-Command-Schritt nach `remote.archive.extract`. Er prueft das entpackte Release-Verzeichnis, Composer/PHP-Verfuegbarkeit, `composer.json`, `composer.lock`, `composer validate --no-check-publish --no-interaction`, `composer check-platform-reqs --lock --no-interaction`, Script-/Plugin-Metadaten und das Fehlen von `vendor` vor und nach der Pruefung. Er darf kein `composer install`, kein `composer update`, kein Autoload-Dump, keine Artisan-Kommandos, keine Schreiboperationen und kein Ignorieren von Plattformanforderungen ausfuehren. `remote.composer.install` bleibt ein separater Folgeschritt und benoetigt nach erfolgreichem Preflight einen eigenen Install-Vertrag und eine eigene Freigabe.

`remote.composer.install` besitzt einen expliziten Install-Vertrag. Der Vertrag definiert `composer install` im `remote.releaseDirectory`, die erlaubten Flags `--no-dev`, `--prefer-dist`, `--optimize-autoloader` und `--no-interaction`, verbotene Flags wie `--ignore-platform-reqs`, Script-/Plugin-Policy, erwarteten Vendor-/Autoload-Zustand, Failure Handling, Rollback-Verhalten und Postvalidation. Fuer das aktuelle Laravel-Projekt ist nur `post-autoload-dump` als reviewed install-lifecycle Script vorgesehen; konfigurierte, aber nicht im Lockfile vorhandene Plugins duerfen nicht aktiviert werden. Script-Ausfuehrung wird ueber `ScriptExecutionEvidence`, `ObservedComposerScripts` und `ObservedComposerCommands` dokumentiert, nicht aus unvollstaendiger Evidence behauptet.

Jeder Deployment-Schritt besitzt eine explizite Write Boundary. Sie beschreibt, welche Pfade und Ressourcen ein Schritt veraendern darf. Aenderungen ausserhalb dieser Grenze sind unzulaessig und fuehren zum Abbruch. Fuer `remote.composer.install` sind nur `vendor`, `vendor/**`, `bootstrap/cache`, `bootstrap/cache/packages.php` und `bootstrap/cache/services.php` innerhalb des Release-Verzeichnisses erlaubt; andere Dateien unter `bootstrap/cache`, `.env`, persistente Daten, Shared Storage, Live Release, Deployment-Metadaten, Public Assets und Berechtigungen sind verboten. `remote.composer.install.validate` bewertet einen bereits gelaufenen Composer-Install read-only erneut, ohne Composer erneut auszufuehren oder Dateien zu reparieren.

Clean-Tree Assessment bewertet den Arbeitsbaum des zu deployenden Projekts rein lesend ueber Git. Ein sauberer Arbeitsbaum ergibt `status = clean` und `deploymentAllowed = true`; staged, unstaged oder untracked Aenderungen ergeben `status = dirty`, `deploymentAllowed = false` und strukturierte `changedPaths`. Die Komponente fuehrt kein Staging, keinen Commit, keinen Reset, keine Bereinigung und keine Deployment-Aktion aus.

Unbekannte Capability IDs fuehren zu einem harten Fehler. Es gibt keine Fallbacks und keine impliziten Shell Commands.

Der Capability-Katalog enthaelt pro Capability mindestens:

- `capabilityId`,
- `displayCommand`,
- `executionMode`,
- `riskLevel`,
- `approvalRequired`.

Optional enthaelt er Validierungsregeln, Fortsetzungsregeln und Backup-Anforderungen.

Capability-Regeln bilden die minimale Sicherheitsbasis. Der Builder darf sie im Plan nur ergaenzen oder verschaerfen, aber nicht entfernen, abschwaechen oder still ueberschreiben.

Die Merge-Regeln sind sicherheitsorientiert:

- Boolesche Sicherheitsanforderungen werden per OR zusammengefuehrt.
- Validation-Patterns werden capability-first vereinigt und case-insensitive dedupliziert.
- Erlaubte Fortsetzungszustaende werden geschnitten; eine leere Schnittmenge ist ein harter Fehler.
- Unterschiedliche Textanforderungen wie `requiredResponse` oder `requiredUserAction` werden kombiniert.
- Widerspruechliche Execution Modes zwischen Builder und Capability werden abgelehnt.

Sicherheitsattribute stammen grundsaetzlich aus dem Capability-Katalog. Der Builder darf sie im Plan nur verschaerfen, aber nicht herabsetzen. Wenn zum Beispiel der Builder `approvalRequired: true` verlangt und die Capability `false` enthaelt, bleibt das Ergebnis `true`.

Dabei ist zwischen fachlichem Schritt und technischem Befehl zu unterscheiden:

- Fachlicher Schritt: zum Beispiel `Remote Migration`, `Deployment Verification` oder `Runtime Maintenance`.
- Capability: zum Beispiel `artisan.migrate`, `artisan.about` oder `composer.install.production`.
- Technischer Anzeigebefehl im resolved Plan: zum Beispiel `php artisan migrate --force`, `php artisan about` oder `composer install --no-dev --optimize-autoloader`.

Kuenftige technische Werkzeuge wie `7z`, `zip`, `unzip`, `tar`, `composer` oder `artisan` sollen austauschbar bleiben, ohne dass sich das fachliche Planmodell aendert.

## Tool Discovery

Tool Discovery erzeugt ein neutrales Tool Inventory.

```text
Resolved Execution Plan
    -> Tool Discovery
    -> Tool Inventory
    -> spaetere Adapterentscheidung
```

Die Discovery erkennt nur lokal verfuegbare Werkzeuge und optionale Projektdateien. Sie installiert nichts, startet keine Builds, startet keine Container, fuehrt keine Deployment-Schritte aus und trifft keine Adapterentscheidung.

In Phase 2a werden mindestens folgende globale Werkzeuge ueber eine geschlossene Allowlist erkannt:

- `php`
- `composer`
- `docker`
- `7z`
- `zip`
- `unzip`
- `tar`

Projektbezogen wird `artisan` als Datei erkannt, wenn ein Projektpfad angegeben wurde. Fehlende Werkzeuge oder fehlende optionale Projektdateien sind normale Inventory-Ergebnisse.

Versionsabfragen erfolgen nur ueber fest definierte Probe-Argumente aus dem Tool-Katalog. Es gibt keine freien Commands, keine Shell-Verkettung und keine dynamischen Probe-Argumente.

`available` beschreibt, ob ein Executable gefunden wurde. `status` beschreibt das Ergebnis der Discovery beziehungsweise Versionsprobe.

Das Statusmodell umfasst:

- `available`
- `not-found`
- `version-unavailable`
- `probe-failed`
- `unsupported`

## Remote Tool Discovery

Remote Tool Discovery ist von der lokalen Discovery getrennt. Die Engine erzeugt einen statischen Pruefplan, pausiert an einem Human Gate und verarbeitet danach ausschliesslich die vom Benutzer eingefuegte, markierte Konsolenausgabe.

```text
Remote Discovery Plan
    -> Human Gate
    -> Remote Output Validation
    -> Remote Tool Inventory
```

Die Engine besitzt keinen SSH-Zugriff, startet keine Remote-Befehle, installiert nichts und trifft keine Adapterentscheidung. Unterstuetzt ist zunaechst nur die explizit angegebene Plattform `linux`.

Remote-Probes stammen aus einer geschlossenen Allowlist. Jede Probe besitzt eine stabile Probe-ID, einen festen Anzeigebefehl, `executionMode = human`, `readOnly = true`, Validierungsregeln und eine blockierende Fortsetzungsregel. Projektmerkmale werden nur relativ zum vom Benutzer selbst gewaehlten Projektverzeichnis geprueft; `artisan` wird dabei nur als Datei erkannt und niemals ausgefuehrt.

Der resolved Execution Plan enthaelt einen `executionPlanFingerprint`, der aus der kanonischen JSON-Darstellung des vollstaendig resolved Plans berechnet wird. Aenderungen an Target-ID, `remoteRoot`, `applicationPath`, `applicationRemoteDirectory`, Steps, Gates oder anderen resolved Planinhalten muessen diesen Fingerprint aendern.

Der Remote-Discovery-Plan enthaelt einen eigenen deterministischen `planFingerprint`. Dieser beschreibt nicht den gesamten resolved Plan, sondern die konkrete Remote-Discovery-Ausfuehrung: Schema-Version, Discovery-Typ, Plattform, die aus dem resolved Plan uebernommene Target-Bindung (`executionPlanFingerprint`, `targetId`, `remoteRoot`, `applicationPath`, `applicationRemoteDirectory`), geordnete Probe-IDs und Anzeigebefehle. Zeitstempel, lokale Pfade, Benutzer- oder Maschinennamen gehen nicht in den Fingerprint ein. Ein Fingerprint-Mismatch wird hart abgelehnt.

Eine Remote-Discovery-Antwort darf nur gegen einen neu erzeugten Plan wiederverwendet werden, wenn der Marker-Fingerprint exakt identisch bleibt. Aendert sich die Target-Bindung oder der resolved Plan-Fingerprint, muss die Discovery erneut als Klasse-C-Aktion ausgefuehrt werden.

Das Human-Response-Format verwendet feste Marker:

```text
=== PLAN-FINGERPRINT ===
<fingerprint>
=== END PLAN-FINGERPRINT ===

=== BEGIN remote.tool.php.location ===
<vollstaendige Konsolenausgabe>
=== END remote.tool.php.location ===
```

Unbekannte Probe-IDs, doppelte Marker, fehlende Endmarker, unmarkierter Zusatztext und Antworten ueber 1 MiB werden kontrolliert abgelehnt. Fehlende Pflichtprobes erzeugen kein vollstaendiges Inventory. Fehlende optionale Werkzeuge bleiben normale Tool-Ergebnisse mit `available = false` und `status = not-found`.

Remote Tool Inventories verwenden denselben Tool-Kern wie lokale Inventories: `available`, `path`, `version`, `status` und `diagnostic`. Zusaetzlich kennzeichnen sie `environment = remote` und `discoveryMethod = human`. Probe-Fehler bleiben isolierte Tool-Ergebnisse; es gibt keine globale Fehlerliste ohne definierten Anwendungsfall.

Remote-Ausgaben sollen keine Secrets oder personenbezogene Hostdaten enthalten. Nicht einzufuegen sind insbesondere Passwoerter, Tokens, Zugangsdaten, `.env`-Inhalte, Hostnamen, Benutzernamen, IP-Adressen, Umgebungsvariablen oder Verzeichnislisten.

## Tool Inventory Assessment

Das Tool Inventory Assessment ist eine rein analytische Zwischenschicht vor Adapter Eligibility Evaluation und Adapter Selection.

```text
Local Tool Inventory
    + Remote Tool Inventory
    -> Tool Inventory Assessment
    -> Assessed Tool Inventory
    -> Adapter Eligibility Evaluation
    -> Adapter Selection
```

Die Komponente laedt nur explizit angegebene Inventory-JSON-Dateien. Sie startet keine Local Discovery, keine Remote Discovery, keine Installation und keine Ausfuehrung. Mindestens ein Inventory muss vorhanden sein; fehlen beide Quellen, wird die Eingabe kontrolliert abgelehnt.

Local und Remote bleiben getrennte Quellen. Pfade, Versionen und Projektmerkmale werden erhalten und nicht zusammengefuehrt. Fehlt genau eine Quelle oder ist ein vorhandenes Inventory `incomplete`, wird das Gesamtassessment `incomplete`. Toolbewertungen, fuer die keine ausreichende Datenbasis vorliegt, erhalten `unknown`.

Toolstatuswerte sind `available-both`, `available-local-only`, `available-remote-only`, `not-found`, `degraded` und `unknown`. `available-local-only` und `available-remote-only` setzen voraus, dass beide Seiten geprueft wurden. Ein fehlendes Remote Inventory macht ein lokal verfuegbares Tool daher nicht zu `available-local-only`, sondern zu `unknown`.

Versionen werden nur angezeigt und gegenuebergestellt. Unterschiedliche Versionen erzeugen hoechstens einen neutralen Hinweis, aber keine Kompatibilitaetsbewertung und keine Adapterentscheidung.

## Adapter Eligibility Evaluation

Die Adapter Eligibility Evaluation ist eine rein analytische Phase nach dem Assessed Tool Inventory und vor der Adapter Selection.

```text
Assessed Tool Inventory
    -> Adapter Eligibility Evaluation
    -> Adapter Selection
```

V1 unterstuetzt genau zwei Adapter: `archive.zip` mit Prioritaet `100` und `archive.tar` mit Prioritaet `200`. Eine niedrigere Zahl bedeutet nur eine spaetere Praeferenz; diese Phase waehlt keinen Adapter aus.

`archive.zip` ist grundsaetzlich nutzbar, wenn lokal `7z` oder `zip` verfuegbar ist und remote `unzip` oder `7z` verfuegbar ist. `archive.tar` ist grundsaetzlich nutzbar, wenn lokal `7z` oder `tar` verfuegbar ist und remote `tar` oder `7z` verfuegbar ist.

Adapterstatuswerte sind `eligible`, `ineligible` und `unknown`. Das Gesamtergebnis ist `ready`, wenn mindestens ein Adapter eligible ist, `incomplete`, wenn kein Adapter eligible ist, aber mindestens einer unknown bleibt, und `blocked`, wenn alle bekannten Adapter nachweislich ineligible sind.

In V1 findet keine tiefergehende tooluebergreifende Kompatibilitaetspruefung statt. Erfuellte Producer- und Consumer-Voraussetzungen fuehren zu `compatibility.status = assumed` und `checked = false`.

Die Phase erzeugt keine Commands, keine Archive, keine Extraktion, keine Dateiuebertragung und keine Ausfuehrung. `selectedAdapterId` gehoert nicht in diese Ausgabe, sondern ausschliesslich in die nachgelagerte Selection-Ausgabe.

## Adapter Selection

Die Adapter Selection ist eine rein analytische Phase nach der Adapter Eligibility Evaluation und vor spaeterer Command Generation oder Execution.

```text
Adapter Eligibility Evaluation
    -> Adapter Selection
    -> Deployment Strategy
    -> spaetere Command Generation
    -> spaeterer Executor
```

Eligibility beantwortet, welche Adapter grundsaetzlich nutzbar sind. Selection beantwortet, welcher eligible Adapter tatsaechlich gewaehlt wird und warum. Die Selection liest nur das Eligibility-Ergebnis, validiert es gegen den zentralen Adapter-Katalog und bewertet keine Tool-Inventare, Voraussetzungen oder Kompatibilitaet neu.

Auswaehlbar sind ausschliesslich Adapter mit `eligibilityStatus = eligible`. Eligible Kandidaten werden deterministisch nach `priority` aufsteigend und danach `adapterId` aufsteigend sortiert. Die Prioritaet stammt ausschliesslich aus `src/ps1/DeploymentAdapters.ps1`; es gibt keine zweite Prioritaetsliste. Aktuell wird `archive.zip` bei gleicher Eligibility vor `archive.tar` gewaehlt, weil ZIP Prioritaet `100` und TAR Prioritaet `200` besitzt.

Das Statusmodell der Selection ist `selected`, `incomplete` und `blocked`. Bei `selected` ist genau ein Adapter gewaehlt und `selectedAdapterId` enthaelt dessen ID. Bei `incomplete` gibt es keinen eligible Adapter, aber mindestens einen unknown Kandidaten; bei `blocked` sind alle bekannten Adapter ineligible. In beiden Faellen bleibt `selectedAdapterId = ""`.

Die Ausgabe enthaelt fuer jeden bekannten Adapter genau einen Kandidaten. Kandidaten werden nach derselben deterministischen Regel sortiert und dokumentieren Status, Prioritaet, Selection-Flag und Diagnose. Selection erzeugt keine Commands, keine Steps, keine Archive, keine Dateiuebertragung und fuehrt nichts aus. Eine spaetere V2-Idee ist ein alternativer beziehungsweise manueller Deploymentplan bei blockiertem automatischem Deployment; dieser Planner ist hier ausdruecklich nicht implementiert.

## Deployment Strategy

Die Deployment Strategy ist eine rein analytische Planungsphase nach Adapter Selection. Sie kombiniert einen validierten Resolved Execution Plan mit einem validierten Adapter-Selection-Ergebnis.

```text
Resolved Execution Plan
    + Adapter Selection
    -> Deployment Strategy
    -> Command Generation
    -> spaeterer Executor
```

Die Strategy beschreibt fachliche Operationen, Reihenfolge, Actor, Ausfuehrungsort, Command-Generation-Anforderungen, Human Gates und Rueckmeldeanforderungen. Sie fuehrt keine Tool Discovery aus, bewertet Eligibility nicht neu, waehlt keinen Adapter neu aus, erzeugt keine konkreten Shell-, Transport-, Remote-, Composer-, Artisan- oder Git-Kommandos und fuehrt nichts aus.

Das Statusmodell ist `ready`, `incomplete` und `blocked`. In V1 setzt die Strategy eine Adapter Selection mit `status = selected` voraus; `incomplete` und `blocked` aus der Selection werden kontrolliert abgelehnt, damit keine ausfuehrbare Strategy ohne Adapterauswahl entsteht.

Das Actor-Modell unterscheidet `automation`, `human-decision`, `human-command` und `review`. Lokale automatisierbare Schritte werden als `automation` mit `commandExecutionMode = automatic` modelliert, sofern keine fachliche Entscheidung erforderlich ist. Das zentrale Deployment-Approval ist ein `human-decision` Gate. Upload-nahe Operationen werden als Artifact Transport modelliert, Remote-Operationen als Remote Execution. Beide sind in V1 `human-command` mit `commandExecutionMode = copy-and-run`; der kopierbare Block entsteht erst in einer spaeteren Command-Generation-Phase. Nach Human Commands ist strukturierte Rueckmeldung erforderlich, mindestens Exit-Status, stdout und stderr.

Die Strategy trennt drei Vertraege:

- Deployment Target bleibt fuer `targetId`, `remoteRoot`, `applicationPath` und das resolved `applicationRemoteDirectory` verantwortlich und enthaelt keine SSH-, Host- oder Transportinformationen.
- Artifact Transport beschreibt ausschliesslich Artefakttransfer. Der erste Adapter ist `network-share`; er enthaelt keine Remote-Kommandos.
- Remote Execution beschreibt ausschliesslich Remote-Kommandos. Der erste Modus ist `interactive-ssh`; die Engine erzeugt nur Befehlsbloecke fuer eine bereits geoeffnete SSH-Sitzung, startet oder beendet keine Verbindung, liest keinen SSH-Kontext und leitet keine Hostinformationen aus Prompts ab.

Der Deployment-Arbeitsbereich auf dem Zielsystem ist `.deployment/` innerhalb der Laravel-Anwendung, ausserhalb des Document Roots. Mindestens vorgesehen sind `.deployment/uploads`, `.deployment/work`, `.deployment/releases` und `.deployment/metadata`. Run-spezifische Release-Ziele liegen unter `.deployment/releases/<deploymentRunId>/<artifactId>`. Diese verschachtelten Verzeichnisse werden nicht implizit durch Extract angelegt, sondern durch den eigenen Schritt `remote.release.prepare`. Der Rollback-Vertrag ist vorbereitet, aber nicht vollstaendig implementiert: maximal zwei vollstaendige Rollback-Staende, kein Cleanup vor erfolgreicher Finalisierung und vollstaendige Erhaltung vorhandener Rollback-Staende bei Fehlern.

Persistente Anwendungsdaten wie `storage/app/private` sind keine normalen Deployment-Artefakte. Shared Storage wird explizit im Projektmanifest modelliert und nicht aus Laravel-, Deployer- oder Unix-Konventionen abgeleitet. Der Vertrag enthaelt mindestens `root`, konkrete `directories`/`files`, `sharedPath`, `releaseLinkPath`, `pathKind`, `conflictPolicy` und `initializationPolicy`. `private` beschreibt dabei einen nicht oeffentlich erreichbaren beziehungsweise kontrolliert zugaenglichen Datenbereich; `shared` beschreibt einen ueber mehrere Releases derselben Umgebung hinweg persistenten Datenbereich.

Fuer `shk-momm-kundendaten` ist die Shared-Storage-Grenze genau `laravel_app/storage/app/private`. Dieser Pfad enthaelt den vollstaendigen persistenten Anwendungsdatenbestand. Dateien und Unterverzeichnisse darunter werden von der Anwendung erzeugt oder verwaltet, gehoeren nicht zu einem einzelnen Release, muessen Deployments und Rollbacks ueberleben und werden deshalb releaseuebergreifend im Shared Storage verwaltet. Nicht pauschal geteilt werden `laravel_app/storage`, `laravel_app/storage/app`, `laravel_app/storage/framework` oder `laravel_app/storage/logs`.

Der Shared-Storage-Root ist relativ zu `ApplicationRemoteDirectory`. Das Shared-Ziel wird als `ApplicationRemoteDirectory + SharedStorageRoot + SharedTargetPath` aufgeloest. Der Release-Link wird fuer den spaeteren Run als `ReleaseDirectory + ReleaseLinkPath` aufgeloest. Konfigurierte Teilpfade muessen relativ, nicht leer und frei von `.`-/`..`-Segmenten sein. Shared-Ziele duerfen den Shared-Root nicht verlassen; Release-Links duerfen das aktuelle Release-Verzeichnis nicht verlassen und duerfen nicht mit Deployment-Metadaten-, Upload-, Work- oder Release-Verwaltungsverzeichnissen ueberlappen.

`remote.shared-storage.prepare` darf ein fehlendes Shared-Zielverzeichnis und notwendige fehlende Elternverzeichnisse innerhalb des Shared-Storage-Roots anlegen und den explizit konfigurierten Release-Link erzeugen. Existiert das Shared-Ziel bereits als Verzeichnis, wird es vollstaendig erhalten. Existiert es als Datei oder Symlink, wird blockiert. Ein korrekter bestehender Release-Link ist idempotent gueltig; ein abweichender Link, eine Datei oder ein regulaeres Verzeichnis am Release-Link-Pfad wird nicht ersetzt, geloescht, zusammengefuehrt oder verschoben. Die Initialisierung bestehender Produktivdaten ist nicht Bestandteil dieses Schritts; `initializationPolicy = explicit` verlangt eine spaetere, separat freizugebende Operation.

Die V1-Strategie fuer `archive.zip` und `archive.tar` verwendet denselben fachlichen Ablauf: Source-Validierung, Artefaktvorbereitung, Archiverstellung, Deployment-Freigabe, allgemeine Remote-Workspace-Vorbereitung, Upload, Remote-Artefaktvalidierung, Remote-Artefaktfinalisierung, `remote.release.prepare`, Extraktion, Applikationsfinalisierung und Review-Verifikation. Unterschiede zwischen ZIP und TAR bleiben auf Adapterformat und spaetere Command Generation begrenzt. Migrationen, Composer-Schritte oder Framework-spezifische Operationen duerfen nur aus dem Resolved Execution Plan abgeleitet werden und werden nicht als freie Commands erfunden.

## Command Generation

Command Generation ist eine rein analytische Transformationsphase nach Runtime-Artefakterzeugung. Sie liest einen validierten Resolved Execution Plan, eine validierte Deployment Strategy, die Packaging Policy und, fuer vollstaendige Upload-/Remote-Bloecke, ein Runtime-Artefakt. Ohne Runtime-Artefakt darf ein vorlaeufiger Command Plan `incomplete` bleiben; dieser Plan ist nur als lokaler Bootstrap-Input fuer `source.validate` und `archive.create` zulaessig, nicht als Command-Session-Input.

```text
Resolved Execution Plan
    + Deployment Strategy
    + Packaging Policy
    + Runtime-Artefakt
    -> Command Generation
    -> Command Plan
    -> Command Session
```

Der Command Plan fuehrt nichts aus. Fuer diesen Meilenstein gilt immer `executionAllowed = false` und `automaticExecutionAllowed = false`; diese Werte sind nicht per CLI ueberschreibbar.

Jeder Command-Eintrag beschreibt `program`, `arguments`, `renderedCommand`, Anzeigeinformationen, Feedback-Anforderungen und Safety-Flags. `program` und `arguments` sind die fuehrenden Daten. `renderedCommand` ist nur eine deterministische Darstellung daraus und darf keine fachlichen Zusatzargumente erfinden.

V1 kennt `local-operation`, `network-share` und `interactive-ssh`. `local-operation` ist kein Betriebssystemprogramm, sondern ein strukturierter Platzhalter fuer spaetere lokale Automation. `network-share` beschreibt ausschliesslich Artefakttransport ueber das vorhandene Netzlaufwerk, aktuell als kopierbarer PowerShell-`Copy-Item`-Block. `interactive-ssh` beschreibt ausschliesslich Remote-Ausfuehrung als Befehlsblock fuer eine bereits geoeffnete SSH-Sitzung. Es wird keine Verbindung aufgebaut, kein Netzwerkzugriff durchgefuehrt, keine Datei uebertragen und kein Command automatisch bestaetigt. Generierte interaktive SSH-Bloecke duerfen keine Sitzungsabbrueche wie `exit` oder `logout` enthalten; Fehlerzustaende werden ueber Ergebnisvariablen und strukturierte Ausgabe gemeldet.

Remote-Ziele und Pfade werden nicht erfunden. Der Command Plan Builder erwartet ein bereits resolved `applicationRemoteDirectory` und fuehrt keine eigene Pfadauflösung durch. Ein fehlendes SSH-Ziel macht den Plan nicht mehr unvollstaendig, weil `interactive-ssh` keinen Hostnamen oder Verbindungsaufbau modelliert. Fehlt fuer `network-share` das Runtime-Artefakt, wird der Command Plan `incomplete`. Ist ein Runtime-Artefakt vorhanden, muss dessen `executionPlanFingerprint` exakt zum resolved Execution Plan passen; falsche Fingerprints, fehlender `localPath` oder unvollstaendige Artefaktdaten werden hart abgelehnt.

Runtime-Artefaktwechsel waehrend eines pausierten Laufs werden nicht durch Ueberschreiben des alten Uploads behandelt. Die Reconciliation erzeugt ein separates Vertragsartefakt, markiert das bisherige Runtime-Artefakt als `superseded`, markiert genau ein Ersatzartefakt als `active-candidate` und blockiert alle nachfolgenden Schritte gegen die alte Artefakt-ID. Ein Wechsel nach Release-Aktivierung ist unzulaessig. Automatische Remote-Loeschung ist kein Bestandteil der Reconciliation.

Der bestehende Reconciliation-Vertrag behandelt ausschliesslich Runtime-Artefaktwechsel innerhalb desselben `executionPlanFingerprint`. Er ist kein Plan-Rebinding, keine Run-Migration und keine Checkpoint-Kompatibilitaetspruefung fuer einen geaenderten resolved Execution Plan. Aendert sich der `executionPlanFingerprint`, darf ein pausierter Lauf erst dann unter dem neuen Plan fortgesetzt werden, wenn ein eigener, maschinenlesbarer Vertrag fuer Plan-Diff, bereits ausgefuehrte Schritte, Runtime-Artefaktbindung, Remote-State-Evidence und Resume-Zielzustand implementiert ist. Bis dahin ist `ExecutionPlanFingerprint vs. Checkpoint-/Resume-Kompatibilitaet` eine offene Architektur-Folgemassnahme.

Die remote-nahe Uploadfolge ist explizit getrennt: `artifact.upload` kopiert nur ueber den Artifact-Transport in ein artefaktspezifisches `.partial`-Ziel; `remote.artifact.validate` prueft Groesse und Hash serverseitig; `remote.artifact.finalize` fuehrt die atomare Umbenennung aus und prueft finale Existenz sowie Groesse; `remote.release.prepare` erzeugt nach strikter Pfad- und Symlink-Pruefung das leere Release-Ziel unter `.deployment/releases/<deploymentRunId>/<artifactId>`; `remote.archive.extract` darf erst danach ansetzen und legt keine Release-Parent-Verzeichnisse an.

`remote.release.prepare` erhaelt `DeploymentRunId`, `ArtifactId`, den resolved Remote-Anwendungsroot und den `executionPlanFingerprint`. Die Ausgabe enthaelt mindestens `RemoteReleaseDirectory`, `ParentDirectoriesCreated`, `ReleaseDirectoryCreated`, `ReleaseDirectoryExists` und `ReleaseDirectoryEmpty`. `mkdir -p -- "$REMOTE_RELEASE_DIRECTORY"` ist nur nach erfolgreicher Validierung erlaubt und darf keine bestehende Release-Struktur wiederverwenden.

Der Ziel-Vertragsfluss lautet:

```text
Projektvertrag
    -> Resolved Execution Plan
    -> Deployment Strategy
    -> Packaging Policy
    -> lokale Runtime-Ausfuehrung archive.create
    -> Runtime-Artefakt
    -> vollstaendiger Command Plan
    -> Command Session
```

Der Execution Plan beschreibt das Deployment und die Zielbindung. Die Deployment Strategy beschreibt die Schrittfolge und lokalen/remote Akteure. Die Packaging Policy beschreibt den erlaubten Archivinhalt. Das Runtime-Artefakt beschreibt das tatsaechlich erzeugte Archiv dieses laufenden Deployments. Laufzeitabhaengige lokale Buildpfade gehoeren nicht dauerhaft in den resolved Plan. `artifact.upload` darf den lokalen Anwendungspfad nicht direkt verwenden, sondern liest den lokalen Archivpfad ausschliesslich aus dem Runtime-Artefakt.

Der fruehere Ablauf war zyklisch: `archive.create` erzeugte das Runtime-Artefakt erst innerhalb einer Command Session; die Command Session verlangte aber einen `ready` Command Plan; der `ready` Command Plan verlangte fuer Upload-, Release-, Extract-, Composer- und Shared-Storage-Bloecke bereits das Runtime-Artefakt. Der Orchestrator darf diesen Zirkel nicht durch eine unvollstaendige Session umgehen. Stattdessen erzeugt er das Runtime-Artefakt in einer schmalen lokalen Bootstrap-Phase und erzeugt danach erst den vollstaendigen Command Plan fuer die eigentliche Session.

## Command Session

Die Command Session ist eine zustandsverwaltende Schicht nach dem Command Plan und vor spaeterer Human Interaction oder einem spaeteren Executor.

```text
Command Plan
    -> Command Session
    -> spaetere Human Interaction
    -> Execution Admission
    -> spaeterer Executor
```

Die Session trennt Plan und Laufzeitstatus. Sie liest einen validierten Command Plan, erzeugt deterministische Items fuer Commands und Human Gates, berechnet das naechste zulaessige Item und verarbeitet danach ausschliesslich strukturierte Events. Sie startet keine Prozesse, fuehrt keine Commands aus, baut keine Remote-Verbindungen auf, bestaetigt nichts automatisch und erzeugt keine Zeitstempel.

Session-Statuswerte sind `created`, `waiting`, `in-progress`, `completed`, `blocked`, `failed` und `cancelled`. Item-Statuswerte sind `pending`, `ready`, `waiting-for-human`, `running`, `completed`, `failed`, `skipped`, `blocked` und `cancelled`. Lokale Automation darf hoechstens ueber `automation-started` und `automation-result` von `ready` nach `running` und danach nach `completed` oder `failed` wechseln; dabei wird kein Prozess gestartet. Human Commands wechseln erst durch ein `human-command-started` Event nach `running` und danach durch ein `human-command-result` Event nach `completed` oder `failed`. Sobald mindestens ein Item `running` ist, steht die Session auf `in-progress`.

Events benoetigen eine stabile vom Aufrufer gelieferte `eventId`. Doppelte Event-IDs werden abgelehnt. Human Gates uebernehmen `sequence` und `dependsOn` aus Strategy beziehungsweise Command Plan; das zentrale Deployment-Approval wird erst `waiting-for-human`, wenn seine modellierten Abhaengigkeiten abgeschlossen sind. Entscheidungen werden nur ueber `human-decision-submitted` verarbeitet; `approved` erlaubt Fortsetzung, `rejected` beendet die Session kontrolliert. Fuer Human-Command-Ergebnisse ist ausschliesslich `exitStatus` technisch massgeblich; stdout und stderr werden strukturiert gespeichert, aber nicht als Freitext-Erfolgsheuristik interpretiert. Review-Ergebnisse kennen `approved`, `rejected` und `inconclusive`. Retry, Parallelisierung, Persistenzdatenbank und Executor sind nicht Teil von V1.

## Execution Admission

Execution Admission ist eine rein analytische Zulassungsschicht nach Command Plan und Command Session und vor einem spaeteren Local Executor.

```text
Command Plan
    + Command Session
    -> Execution Admission
    -> Executor Request
    -> spaeterer Local Executor
```

Die Phase validiert zuerst den gesamten Command Plan, die gesamte Command Session, alle Plan-/Session-Item-Zuordnungen und die Event-History. Erst wenn diese globale Sicherheitsvalidierung erfolgreich ist, bewertet sie ausschliesslich das aktuelle `CommandSession.currentItemId`. Sie prueft Uebereinstimmung, offene Abhaengigkeiten, Session-Terminalzustaende, Actor, Ausfuehrungsort, Ausfuehrungsmodus und Programmart. Sie waehlt kein anderes Item aus, erzeugt keine Events, setzt kein Item auf `running` oder `completed` und veraendert die Session nicht.

Das Admission-Statusmodell umfasst `eligible-but-disabled`, `requires-human`, `requires-review`, `not-ready`, `blocked`, `failed`, `cancelled`, `completed` und `inconsistent`. Der Status `admitted` wird in V1 nicht verwendet; er wird erst mit einem spaeteren Executor und expliziter Ausfuehrungsfreigabe eingefuehrt.

Die Event-History ist Teil der Sicherheitsvalidierung: Automation und Human Commands benoetigen die passende Start-/Result-Reihenfolge, Human Decisions eine erlaubte Entscheidung und Reviews ein modelliertes Review-Ergebnis. Die gespeicherten Item-Status muessen actor-spezifisch durch diese History und die strukturierten Item-Daten belegt sein. Human Approvals werden aus Human Gates und dem Dependency-Graph ermittelt, nicht aus einer fest codierten Gate-ID.

Lokale Automation kann nur dann `eligible-but-disabled` werden, wenn `actor = automation`, `executionLocation = local`, `executionMode = automatic`, `program = local-operation`, das Item `ready` ist und die modellierten Abhaengigkeiten abgeschlossen sind. Dann ist `executionEligible = true`, aber `executionAdmitted = false`, weil Command Generation weiterhin `executionAllowed = false`, `automaticExecutionAllowed = false` und `executionPermitted = false` liefert.

Human Commands und Human Decisions ergeben `requires-human`; Review Items ergeben `requires-review`. Artifact Transport, Remote Execution und alte Local-to-Remote-Eintraege werden niemals automatisch zugelassen und bleiben Copy-and-Run beziehungsweise Human Interaction. Der Handoff beschreibt nur den erwarteten naechsten Event-Typ, etwa `automation-started` und `automation-result` fuer spaetere lokale Automation oder `human-command-started` und `human-command-result` fuer manuelle Commands.

Jedes Ergebnis enthaelt eine konstante Execution Policy mit `productiveExecutionAllowed = false`, `processStartAllowed = false`, `networkAccessAllowed = false` und `remoteExecutionAllowed = false`. Execution Admission startet keine Prozesse, baut keine Netzwerkverbindungen auf, archiviert nichts, uebertraegt keine Dateien, liest keine Umgebungsvariablen und fuehrt kein Deployment aus.

## Executor Request

Executor Request ist ein sicherer Vertragsbaustein nach Execution Admission und vor einem spaeteren Local Operation Executor.

```text
Command Plan
    + Command Session
    + Execution Admission
    -> Executor Request
    -> Local Operation Executor
```

Die Phase erzeugt nur dann ein Request-Objekt, wenn die Admission exakt zu Command Plan und Command Session passt, `status = eligible-but-disabled`, `executionEligible = true` und `executionAdmitted = false` enthaelt und das aktuelle Session-Item weiterhin `ready` ist. Zulaessig sind nur lokale Automation-Items mit `executionLocation = local`, `executionMode = automatic` und `program = local-operation`; Human Commands, Artifact Transport, Remote Execution und aktivierte Plan-Ausfuehrung werden kontrolliert abgelehnt.

Das Ergebnis ist deterministisch, hat `executorRequestType = deployment-executor-request` und bleibt `status = disabled`. Es enthaelt `operationType`, `program`, `arguments`, `renderedCommand`, `workingDirectory`, eine leere beziehungsweise strukturierte Umgebung, strukturierte `operation`-Daten, eine deaktivierte Execution Policy und die erwarteten Event-Typen `automation-started` und `automation-result`.

Executor Request startet keine Prozesse, baut kein Netzwerk auf, erzeugt keine Events, wendet keine Events an, veraendert keine Command Session und fuehrt kein Deployment aus. Secret-artige Inhalte in den validierten Eingaben werden abgelehnt.

## Local Operation Executor

Der Local Operation Executor V1 ist der erste aktiv ausfuehrende Baustein. Er verarbeitet ausschliesslich validierte `deployment-executor-request`-Objekte und dispatcht nur ueber eine feste Allowlist.

```text
Executor Request
    -> Local Operation Executor
    -> Executor Result
    -> Automation Event Builder
    -> Command Session Event
```

Akzeptiert werden nur Requests mit `status = disabled`, `actor = automation`, `executionLocation = local`, `executionMode = automatic`, `program = local-operation` und explizitem `operationType`. Der Executor leitet die Operation niemals aus `commandId`, `arguments`, `renderedCommand` oder `diagnostic` ab.

V1 unterstuetzt genau zwei Operationen: `source.validate` prueft read-only, ob ein expliziter Quellpfad existiert und ein Verzeichnis ist. `archive.create` erzeugt ein ZIP-Archiv aus einem expliziten Quellverzeichnis an einem expliziten, noch nicht vorhandenen Artefaktpfad. Der Artefaktpfad muss ausserhalb des Quellverzeichnisses liegen; bestehende Archive werden nicht ueberschrieben. Nach erfolgreicher Erstellung wird ein Runtime-Artefakt mit Hash, Groesse, Dateiname, lokalem Archivpfad, `executionPlanFingerprint` und Packaging-Policy-Bindung erzeugt.

Archivierung verlangt fuer `archive.create` eine strukturierte Packaging Policy. Der Executor wendet `includedPaths` und `excludedPaths` an und schliesst zusaetzlich mindestens `.env`, `.env.*`, `.git`, `.git/**`, `*.key`, `*.pem`, `id_rsa`, `id_ed25519`, Betriebssystem-/IDE-Dateien, temporaere Dateien und lokale Backups aus. Secret-artige Eingaben werden abgelehnt und nicht in stdout, stderr oder Diagnose ausgegeben.

Das Ergebnis ist ein neues `deployment-executor-result` mit Status `completed`, `failed` oder `rejected` und der unveraenderten `sessionId` aus dem Executor Request. Validierungs- und Sicherheitsfehler ergeben `rejected`, sofern der Request strukturell verarbeitbar ist; technische Fehler nach Beginn einer Operation ergeben `failed`. Der Executor erzeugt keine Session-Events, wendet keine Events an, mutiert keine Command Session, verwendet kein Netzwerk und fuehrt keine generischen Programme oder Shell-Kommandos aus.

## Automation Event Builder

Der Automation Event Builder bildet den Rueckweg vom Local Operation Executor in das bestehende Command-Session-Eventmodell. Er erzeugt genau ein Event-Dokument und wendet es nicht auf die Session an.

```text
Command Session
    + Executor Request
    -> automation-started

Command Session
    + Executor Request
    + Executor Result
    -> automation-result
```

`build-automation-started-event` prueft, dass Session und Executor Request zur selben startbereiten lokalen Automation gehoeren, dass die Session nicht terminal ist und dass fuer das Item noch kein Automation-Start oder Automation-Result vorliegt. `build-automation-result-event` verlangt eine laufende Automation mit genau einem passenden Start-Event, demselben Request, demselben Result-Ziel, identischer `sessionId` in Command Session, Executor Request und Executor Result sowie noch keinem Result-Event.

Executor-Result-Status `completed` wird als erfolgreiches `automation-result` modelliert. `failed` und `rejected` werden fuer das bestehende Session-Statusmodell als fehlgeschlagenes `automation-result` erzeugt; der urspruengliche Status bleibt im Event unter `resultStatus` unterscheidbar. Artefakte werden strukturiert uebernommen, stdout/stderr, freie Request-Daten, Environment-Daten, `renderedCommand` und Secret-artige Inhalte werden nicht in Eventfelder uebernommen.

Der Zeitstempel wird explizit vom Aufrufer geliefert und nach UTC normalisiert. Der Builder verwendet keine versteckte Uhr, startet keine Prozesse, erzeugt kein Netzwerk, ruft keinen Executor auf und veraendert keine Command Session.

## Execution Orchestrator V1

Der lokale Execution Orchestrator V1 koordiniert bestehende Bausteine fuer einen frischen lokalen Lauf. Er erzeugt ein Runtime-Verzeichnis, speichert den unveraenderten Eingabe-Command-Plan unter `input/command-plan.json`, bewertet den Source-Repository-Zustand ueber Clean-Tree Assessment und erstellt nur bei `deploymentAllowed = true` eine Command Session.

Ist der Eingabe-Command-Plan wegen fehlendem Runtime-Artefakt `incomplete`, darf der Orchestrator vor der eigentlichen Session ausschliesslich einen Bootstrap-Plan aus `source.validate` und `archive.create` ausfuehren. Diese Phase benoetigt den Resolved Execution Plan, die Deployment Strategy, die Packaging Policy, die Adapter Selection beziehungsweise den in der Strategy gebundenen Adapter und den expliziten lokalen Source-Repository-Pfad. Sie erzeugt das Runtime-Artefakt lokal im Runtime-Verzeichnis und fuehrt keine Remote-, Upload- oder Deployment-Aktion aus.

```text
Runtime Directory
    -> Clean-Tree Assessment
    -> Bootstrap Command Plan (nur source.validate + archive.create)
    -> Runtime-Artefakt
    -> vollstaendiger Command Plan
    -> Command Session
    -> Execution Admission
    -> Executor Request
    -> automation-started Event
    -> Command Session Update
    -> Local Operation Executor
    -> automation-result Event
    -> Command Session Update
```

Bei `dirty` Repository endet der Lauf mit `blocked`, ohne Session, Executor Request, lokale Operation oder Archiv. Bei `requires-human` oder `requires-review` pausiert der Lauf mit `waiting-for-human`; der Orchestrator erzeugt keine Human Decisions, keine Human-Command-Resultate und keine Review-Ergebnisse. Terminale Session-Zustaende `completed`, `failed`, `blocked` und `cancelled` beenden die Schleife.

Nach erfolgreichem Bootstrap regeneriert der Orchestrator den Command Plan mit Runtime-Artefakt. Dieser effektive Plan muss `status = ready` haben, bevor eine Command Session erstellt wird. Die bereits lokal erledigten Bootstrap-Items werden in der echten Session als abgeschlossene lokale Automation modelliert, damit das zentrale `deployment.approval` korrekt `waiting-for-human` werden kann.

Der Orchestrator erzeugt keine Remote Executor Requests, bestaetigt keine Human Gates und erzeugt keine Human-Command-Resultate. Er erzeugt UTC-Zeitstempel fuer Automation Events, ruft die bestehenden Builder und den bestehenden Event-Applier auf und speichert sortierbare Zwischenstaende in `decisions`, `events` und `reports`. V1 unterstuetzt nur lokale Automation ueber `source.validate` und `archive.create`; Artifact Transport, Remote Execution, Netzwerkzugriff, Retry und vollstaendiger Rollback sind nicht Bestandteil der lokalen Automation.

## Resume Existing Execution Run V1

Resume setzt einen bestehenden lokalen Runtime-Run nach `waiting-for-human` kontrolliert fort. Der Baustein laedt den urspruenglichen Eingabe-Command-Plan, den effektiven Command Plan, die letzte Summary und den deterministisch letzten Command-Session-Snapshot aus dem Runtime-Verzeichnis. Diese Artefakte muessen parsebar sein, zur selben Runtime gehoeren und mit der aktuellen Admission konsistent bleiben.

```text
Runtime Run
    -> External Session Event
    -> Command Session Update
    -> Execution Orchestrator Loop
```

Unterstuetzt sind nur die vorhandenen Eventtypen `human-decision-submitted`, `human-command-result` und `review-result`. Das externe Event muss eine passende `sessionId` und eine noch nicht angewendete `eventId` enthalten. Es wird unveraendert unter `events/external-session-event-*.json` archiviert und ausschliesslich mit `Apply-CommandSessionEvent` angewendet; danach wird ein neuer Session-Snapshot gespeichert. Nummerierungen werden aus bestehenden Artefakten fortgesetzt, vorhandene Snapshots werden nicht ueberschrieben.

Resume erzeugt keine Human- oder Review-Entscheidung, startet keinen Artifact Transport oder Remote Execution, nutzt kein Netzwerk, mutiert kein Git und nimmt terminale Sessions nicht wieder auf. Nach erfolgreicher Event-Anwendung wird derselbe interne Execution Loop verwendet wie bei einem frischen lokalen Lauf.

## Human Gates

Schritte mit Ausfuehrungsmodus `human` beschreiben Befehle, die der Benutzer selbst auf der Zielumgebung ausfuehren muss. Die Engine besitzt keinen SSH-Zugriff und fuehrt keine Remote-Befehle aus.

Ein Human Gate muss Zielumgebung, Kanal, Arbeitsverzeichnis, vollstaendigen Befehl, Zweck, erwartetes Ergebnis, Fehlermuster und benoetigte Rueckmeldung enthalten. Der Prozess bleibt pausiert, bis die geforderte Konsolenausgabe vorliegt und eindeutig erfolgreich bewertet wurde.

Eine reine Bestaetigung wie `erledigt` oder `lief durch` reicht nicht aus, wenn Konsolenausgabe verlangt wird. Fehlt ein positives Erfolgsmuster, wird die Ausgabe als mehrdeutig behandelt, sofern die Validierungsregel dies verlangt.

## Environment-Vertrag

## Remote-Target-Vertrag

Das Projektmanifest beschreibt projektbezogene Deployment-Fakten. `deployment.serverRoot` ist eine logische beziehungsweise noch nicht aufgeloeste Zielwurzel; `project.applicationRoot` ist der relative lokale Anwendungspfad innerhalb des Projekt-Repositories. Absolute Remote-Pfade gehoeren nicht in das allgemeine Projektmanifest.

Zielumgebungsbezogene, nicht geheime Deployment-Informationen liegen in einem separaten versionierten Target-Artefakt, zum Beispiel `deployment.targets/staging.json`. Dieses Artefakt enthaelt mindestens `schemaVersion`, `targetId`, einen absoluten POSIX-`remoteRoot` und einen relativen POSIX-`applicationPath`. Hostnamen, Benutzernamen, Zugangsdaten, Tokens und Secrets sind dort nicht erlaubt.

Vor Deployment Strategy und Command Generation muss die Remote-Target-Resolution ausschliesslich den absoluten `target.remoteRoot` mit dem relativen `target.applicationPath` kombinieren. Leere Werte, relative Remote-Roots, absolute Application-Pfade, `.`-/`..`-Segmente, doppelte Trenner und normalisierte Pfadfluchten werden kontrolliert abgelehnt. Das gepruefte Ergebnis wird im resolved Execution Plan unter `environment.applicationRemoteDirectory` sowie mit Herkunftsinformationen unter `environment.remoteTarget` abgelegt. `project.applicationRoot` wird nicht fuer die Remote-Zielauflösung verwendet.

Der Command Plan Builder bleibt bewusst strikt. Er validiert `applicationRemoteDirectory` weiterhin als absoluten Remote-Pfad und fuehrt keine eigene Pfadauflösung durch.

Die Secret-Validierung fuer Command Generation ist feldbezogen. Pfadmetadaten wie `.env`, `.env.example`, Schutzregeln, Environment-Key-Namen und Beschreibungen sind erlaubt, solange sie keine Werte enthalten. Strikt verboten bleiben tatsaechliche Environment-Inhalte wie `KEY=value`, Credentials, Tokens, private Schluessel sowie nicht-leere Werte in sensiblen Feldern wie `password`, `token`, `secret`, `apiKey`, `clientSecret` oder `credential`. Command-Payloads, Argumente und gerenderte Befehle werden ebenfalls auf solche Werte geprueft.

## Environment-Vertrag

`environmentManagement` im Projektmanifest ist optional und erweitert den Vergleich versionierter Environment-Vertraege. Der Analyzer bewertet neue, entfernte und unbekannte Schluessel gegen die deklarierten Regeln und gibt pro Schluessel eine empfohlene Review-Aktion aus.

Die Engine liest dafuer keine Zielsystemdatei wie `.env`, schreibt keine Environment-Datei und gibt keine Secret-Werte aus. Secret-Regeln duerfen keine konkreten Werte und keine `suggestedValue` enthalten. Unvollstaendige Regeln, unbekannte Schluessel und entfernte Schluessel bleiben Review-Gates.

## Seeder Review

Seeder-Aenderungen werden statisch bewertet. Die Analyse betrachtet nur den versionierten Dateitext und sucht nach einfachen Hinweisen wie betroffenen Models, Tabellen, Schreiboperationen und destruktiven Operationen.

Der Execution Plan Builder erzeugt daraus bei Bedarf ein Review-Gate `database.seeders.review` vor Migrationen. Die Engine fuehrt keine Seeder aus, erzeugt keinen `db:seed`-Befehl und trifft keine produktive Datenentscheidung.

## Migration Safety

Migrationen werden als `riskLevel: high` modelliert und benoetigen immer eine ausdrueckliche Freigabe.

Wenn der Analyzer Migrationsbedarf erkennt, erzeugt der Builder eine Sicherheitskette:

1. Review Gate zur Pruefung der betroffenen Migrationsdateien und zur Bestaetigung eines geeigneten Datenbank-Backups.
2. Human Gate fuer `php artisan migrate:status`, damit der Zielzustand vor der Ausfuehrung sichtbar und spaeter validierbar ist.
3. Human Gate fuer `php artisan migrate --force`.

Folgende Artisan-Kommandos duerfen vom Plan Builder nicht vorgeschlagen werden und fuehren zu einem kontrollierten Abbruch, falls sie spaeter durch Konfiguration oder Erweiterungen entstehen sollten:

- `php artisan migrate:fresh`
- `php artisan migrate:refresh`
- `php artisan migrate:reset`
- `php artisan migrate:rollback`
- `php artisan db:wipe`

## Review Gates

Review-Schritte pausieren den Prozess ohne Befehl. Sie werden unter anderem fuer Environment-Aenderungen, geschuetzte Dateien, destruktive Cleanup-Plaene und nicht automatisch bewertbare Anforderungen verwendet.

Destruktive Schritte muessen `destructive: true` enthalten, die betroffenen Pfade konkret nennen und eine ausdrueckliche Freigabe verlangen. Es werden keine generischen rekursiven Loeschbefehle erzeugt.

## Deployment-Marker

Das Update der `.deploy-version` erscheint nur als letzter bedingter Planschritt. Der Builder schreibt diese Datei nicht.

Der Marker-Schritt bleibt blockiert, bis alle erforderlichen Schritte erfolgreich abgeschlossen oder fachlich korrekt uebersprungen wurden, keine Blocker bestehen, Human Gates erfolgreich validiert wurden, Review Gates freigegeben sind, destruktive Schritte bestaetigt wurden und die Deployment-Verifikation erfolgreich war.

## Spaetere Execution

Remote-Ausfuehrung, Resume, Retry, Rollback und produktive Zielsystem-Aktionen sind in Version `0.1` nicht implementiert. Remote-Befehle bleiben Human Gates und werden vom Benutzer manuell ausgefuehrt.

## Spaetere Verification

Die Verifikation wird ebenfalls erst spaeter umgesetzt. Sie soll nach einem Deployment technische und fachliche Pruefpunkte auswerten und erst danach die Aktualisierung eines Deployment-Markers erlauben.
