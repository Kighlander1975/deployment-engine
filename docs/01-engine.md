# Engine Pipeline

Die Pipeline der Version `0.1` ist bewusst in Analyse, Planerzeugung, Capability-Aufloesung, Tool Discovery und spaetere Ausfuehrung getrennt.

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
    -> spaetere Adapter Selection
```

Die Discovery erkennt nur lokal verfuegbare Werkzeuge und optionale Projektdateien. Sie installiert nichts, startet keine Builds, startet keine Container, fuehrt keine Deployment-Schritte aus und trifft keine Adapterentscheidung.

In Phase 2a werden mindestens folgende globale Werkzeuge ueber eine geschlossene Allowlist erkannt:

- `php`
- `composer`
- `docker`
- `7z`
- `zip`
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

Das Tool Inventory Assessment ist eine rein analytische Zwischenschicht vor einer spaeteren Adapter Selection.

```text
Local Tool Inventory
    + Remote Tool Inventory
    -> Tool Inventory Assessment
    -> Assessed Tool Inventory
    -> spaetere Adapter Selection
```

Die Komponente laedt nur explizit angegebene Inventory-JSON-Dateien. Sie startet keine Local Discovery, keine Remote Discovery, keine Installation und keine Ausfuehrung. Mindestens ein Inventory muss vorhanden sein; fehlen beide Quellen, wird die Eingabe kontrolliert abgelehnt.

Local und Remote bleiben getrennte Quellen. Pfade, Versionen und Projektmerkmale werden erhalten und nicht zusammengefuehrt. Fehlt genau eine Quelle oder ist ein vorhandenes Inventory `incomplete`, wird das Gesamtassessment `incomplete`. Toolbewertungen, fuer die keine ausreichende Datenbasis vorliegt, erhalten `unknown`.

Toolstatuswerte sind `available-both`, `available-local-only`, `available-remote-only`, `not-found`, `degraded` und `unknown`. `available-local-only` und `available-remote-only` setzen voraus, dass beide Seiten geprueft wurden. Ein fehlendes Remote Inventory macht ein lokal verfuegbares Tool daher nicht zu `available-local-only`, sondern zu `unknown`.

Versionen werden nur angezeigt und gegenuebergestellt. Unterschiedliche Versionen erzeugen hoechstens einen neutralen Hinweis, aber keine Kompatibilitaetsbewertung und keine Adapterentscheidung.

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
