# Engine Pipeline

Die Pipeline der Version `0.1` ist bewusst in Analyse, Planerzeugung, Capability-Aufloesung, Tool Discovery, Adapterentscheidung, Deployment Strategy, Command Generation und spaetere Ausfuehrung getrennt.

## Project Detection

Die Engine liest das Projektmanifest, validiert Pflichtfelder und prueft, ob Projektroot und Application Root vorhanden sind. Pfade werden unabhaengig vom aktuellen Arbeitsverzeichnis aufgeloest.

## Repository Analysis

Die Engine prueft, ob der Projektroot ein Git-Repository ist, ermittelt den Arbeitsbaumstatus, loest Ziel- und Baselinecommit auf und zaehlt die Commits seit der Baseline. Ist die Baseline kein Vorfahr des Zielcommits, wird dies als Blocker ausgewiesen.

## Artifact Classification

Der Git-Diff wird mit `--name-status --find-renames` ausgewertet. Jede betroffene Datei wird anhand des Projektmanifests einer oder mehreren Artefaktklassen zugeordnet.

## Rule Evaluation

Die Regelbewertung leitet Entscheidungen aus den Klassifikationen und besonderen Dateiarten ab. Dazu gehoeren Composer-Schritte, Frontend-Build, Migrationsbedarf, Environment-Review, Cleanup und geschuetzte Dateien.

## Analyzer-Ergebnis

Das Analyzer-Ergebnis fasst Eingangsdaten, Git-Zustand, geaenderte Dateien, Klassifikationen, Environment-Aenderungen, Entscheidungen, Warnungen, Blocker und manuelle Freigabepunkte zusammen.

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

Spaetere Laufdaten koennen beispielsweise Inventare, Assessments, Entscheidungen, Strategien, Command Plans, Archive, Logs und Reports umfassen. Adapter Eligibility Evaluation, Adapter Selection, Deployment Strategy und Command Generation schreiben weiterhin nur dann eine Datei, wenn explizit `-OutputPath` uebergeben wurde.

Vor einem spaeteren automatischen Deployment wird der Arbeitsbaum des zu deployenden Projekts geprueft. In V1 blockieren sichtbare Aenderungen aus `git status --porcelain` den automatischen Deploy.

Runtime Directory Management und Clean-Tree Gate sind noch nicht implementiert. Beide Architekturbausteine muessen vor Archivierung oder Executor umgesetzt werden. Die aktuelle Adapter Eligibility Evaluation, Adapter Selection, Deployment Strategy und Command Generation fuehren keine Git-Statuspruefung aus.

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

Der Plan enthaelt einen deterministischen `planFingerprint`, berechnet aus Schema-Version, Discovery-Typ, Plattform, geordneten Probe-IDs und Anzeigebefehlen. Zeitstempel, lokale Pfade, Benutzer- oder Maschinennamen gehen nicht in den Fingerprint ein. Ein Fingerprint-Mismatch wird hart abgelehnt.

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

Die Strategy beschreibt fachliche Operationen, Reihenfolge, Actor, Ausfuehrungsort, Command-Generation-Anforderungen, Human Gates und Rueckmeldeanforderungen. Sie fuehrt keine Tool Discovery aus, bewertet Eligibility nicht neu, waehlt keinen Adapter neu aus, erzeugt keine konkreten Shell-, SSH-, SCP-, Composer-, Artisan- oder Git-Kommandos und fuehrt nichts aus.

Das Statusmodell ist `ready`, `incomplete` und `blocked`. In V1 setzt die Strategy eine Adapter Selection mit `status = selected` voraus; `incomplete` und `blocked` aus der Selection werden kontrolliert abgelehnt, damit keine ausfuehrbare Strategy ohne Adapterauswahl entsteht.

Das Actor-Modell unterscheidet `automation`, `human-decision`, `human-command` und `review`. Lokale automatisierbare Schritte werden als `automation` mit `commandExecutionMode = automatic` modelliert, sofern keine fachliche Entscheidung erforderlich ist. Das zentrale Deployment-Approval ist ein `human-decision` Gate. SSH- und Upload-nahe Operationen werden in V1 als `human-command` mit `commandExecutionMode = copy-and-run` modelliert; der kopierbare Befehl entsteht erst in einer spaeteren Command-Generation-Phase. Nach Human Commands ist strukturierte Rueckmeldung erforderlich, mindestens Exit-Status, stdout und stderr.

Die V1-Strategie fuer `archive.zip` und `archive.tar` verwendet denselben fachlichen Ablauf: Source-Validierung, Artefaktvorbereitung, Archiverstellung, Deployment-Freigabe, Remote-Release-Verzeichnis, Upload, Extraktion, Applikationsfinalisierung und Review-Verifikation. Unterschiede zwischen ZIP und TAR bleiben auf Adapterformat und spaetere Command Generation begrenzt. Migrationen, Composer-Schritte oder Framework-spezifische Operationen duerfen nur aus dem Resolved Execution Plan abgeleitet werden und werden nicht als freie Commands erfunden.

## Command Generation

Command Generation ist eine rein analytische Transformationsphase nach der Deployment Strategy. Sie liest einen validierten Resolved Execution Plan und eine validierte Deployment Strategy und erzeugt daraus einen strukturierten Command Plan.

```text
Resolved Execution Plan
    + Deployment Strategy
    -> Command Generation
    -> Command Plan
    -> spaeterer Executor
```

Der Command Plan fuehrt nichts aus. Fuer diesen Meilenstein gilt immer `executionAllowed = false` und `automaticExecutionAllowed = false`; diese Werte sind nicht per CLI ueberschreibbar.

Jeder Command-Eintrag beschreibt `program`, `arguments`, `renderedCommand`, Anzeigeinformationen, Feedback-Anforderungen und Safety-Flags. `program` und `arguments` sind die fuehrenden Daten. `renderedCommand` ist nur eine deterministische Darstellung daraus und darf keine fachlichen Zusatzargumente erfinden.

V1 kennt `local-operation`, `ssh` und `scp`. `local-operation` ist kein Betriebssystemprogramm, sondern ein strukturierter Platzhalter fuer spaetere lokale Automation. SSH- und SCP-Eintraege werden ausschliesslich als `copy-and-run` modelliert: copyable, aber `executionPermitted = false`. Es wird keine Verbindung aufgebaut, kein Netzwerkzugriff durchgefuehrt, keine Datei uebertragen und kein Command automatisch bestaetigt.

Remote-Ziele und Pfade werden nicht erfunden. Ein gerenderter SSH- oder SCP-Eintrag entsteht nur, wenn SSH-Ziel, absoluter Remote-Pfad und bei Upload ein lokaler Artefaktpfad eindeutig in den Eingaben vorhanden sind. Fehlen diese Angaben oder sind Remote-Pfade relativ, wird der Command Plan `incomplete`. Target Discovery, Runtime Directory Management, Archivierung und Executor bleiben spaetere Bausteine.

## Human Gates

Schritte mit Ausfuehrungsmodus `human` beschreiben Befehle, die der Benutzer selbst auf der Zielumgebung ausfuehren muss. Die Engine besitzt keinen SSH-Zugriff und fuehrt keine Remote-Befehle aus.

Ein Human Gate muss Zielumgebung, Kanal, Arbeitsverzeichnis, vollstaendigen Befehl, Zweck, erwartetes Ergebnis, Fehlermuster und benoetigte Rueckmeldung enthalten. Der Prozess bleibt pausiert, bis die geforderte Konsolenausgabe vorliegt und eindeutig erfolgreich bewertet wurde.

Eine reine Bestaetigung wie `erledigt` oder `lief durch` reicht nicht aus, wenn Konsolenausgabe verlangt wird. Fehlt ein positives Erfolgsmuster, wird die Ausgabe als mehrdeutig behandelt, sofern die Validierungsregel dies verlangt.

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

Die Ausfuehrung wird in Version `0.1` nicht implementiert. Eine spaetere Version darf erst nach expliziter Freigabe lokale Pakete vorbereiten oder lokale Pruefungen automatisieren. Remote-Befehle bleiben Human Gates und werden vom Benutzer manuell ausgefuehrt.

## Spaetere Verification

Die Verifikation wird ebenfalls erst spaeter umgesetzt. Sie soll nach einem Deployment technische und fachliche Pruefpunkte auswerten und erst danach die Aktualisierung eines Deployment-Markers erlauben.
