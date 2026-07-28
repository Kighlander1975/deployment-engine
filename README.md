# SHK-MOMM Deployment Engine

Die SHK-MOMM Deployment Engine ist ein projektuebergreifendes Werkzeug zur nachvollziehbaren Deployment-Analyse, Planerzeugung und spaeteren kontrollierten Ausfuehrung von Deployments.

Version `0.1` liefert ausschliesslich Analyse- und Planungsfunktionen. Sie liest ein Projektmanifest, vergleicht zwei Git-Commits, klassifiziert geaenderte Artefakte und kann daraus einen strukturierten Execution Plan mit verbindlichen Human Gates ableiten.

## Analyse und Ausfuehrung

Die aktuelle Version fuehrt keine Deployments aus. Sie kopiert keine Dateien, erzeugt keine Pakete, fuehrt keine Migrationen aus, verbindet sich nicht per SSH und aktualisiert keine Deployment-Marker. Die spaetere Execution-Phase wird bewusst von Analyse und Planerzeugung getrennt.

Die fachliche Trennung lautet:

```text
Analyzer
    -> Execution Plan Builder
    -> Capability Resolver
    -> Resolved Execution Plan
    -> Tool Discovery
    -> Tool Inventory
    -> Remote Discovery Plan
    -> Remote Tool Inventory
    -> Tool Inventory Assessment
    -> Assessed Tool Inventory
    -> Adapter Eligibility Evaluation
    -> Adapter Selection
    -> Deployment Strategy
    -> Command Generation
    -> Command Session
    -> Execution Admission
    -> Executor Request
    -> Local Operation Executor
    -> spaetere Orchestrierung
```

Der Analyzer ermittelt Aenderungen und Deployment-Entscheidungen. Der Execution Plan Builder uebersetzt dieses Ergebnis in stabile, maschinenlesbare Schritte mit `capabilityId`. Der Capability Resolver ist eine pure Transformation: Er veraendert den uebergebenen unresolved Plan nicht, sondern erzeugt ein neues Resolved Execution Plan-Objekt mit konkreten Anzeigeinformationen wie `displayCommand`, Ausfuehrungsmodus, Risikostufe, Freigabepflicht, Validierungsregeln und Fortsetzungsregeln. Ein spaeterer Executor darf den resolved Plan nur schrittweise verarbeiten und muss an Human- und Review-Gates verbindlich pausieren.

Remote-Befehle werden nur angezeigt. Der Agent besitzt keinen SSH-Zugriff und soll keinen SSH-Zugriff erhalten. Befehle auf dem Zielsystem werden ausschliesslich vom Benutzer ausgefuehrt. Wenn ein Schritt Konsolenausgabe verlangt, reicht eine reine Bestaetigung wie `erledigt` oder `lief durch` nicht aus.

Sicherheitsgrundsatz: Analyse ist standardmaessig rein lesend. Eine Ausgabe wird nur dann geschrieben, wenn ein lokaler `-OutputPath` explizit angegeben wird.

Technische Befehle stammen aus dem zentralen Capability-Katalog. Damit bleibt der fachliche Schritt vom konkreten Werkzeug getrennt: `Remote Migration` ist der fachliche Schritt, `artisan.migrate` ist die Capability und `php artisan migrate --force` ist nur der aktuell aufgeloeste Anzeigebefehl. Spaetere Werkzeuge wie `7z`, `zip`, `unzip`, `tar`, `composer` oder `artisan` sollen austauschbar bleiben, ohne das Planmodell umzubauen.

Capability-Regeln bilden die minimale Sicherheitsbasis. Builder-Regeln duerfen diese Basis nur ergaenzen oder verschaerfen: Validation-Patterns werden capability-first vereinigt, boolesche Sicherheitsanforderungen per OR zusammengefuehrt, erlaubte Fortsetzungszustaende geschnitten und widerspruechliche Execution Modes abgelehnt.

Tool Discovery ist eine neutrale, read-only Inventur lokaler Werkzeuge und optionaler Projektdateien. Sie trifft keine Adapterentscheidung, installiert nichts und fuehrt keine Deployment-Schritte aus. Fehlende Werkzeuge sind normale Inventory-Ergebnisse.

Remote Discovery erzeugt dagegen nur einen sicheren Human-Gate-Pruefplan. Die Engine besitzt keinen SSH-Zugriff und fuehrt keine Serverbefehle aus; der Benutzer fuehrt ausschliesslich die angezeigten statischen Pruefkommandos selbst aus und gibt die vollstaendige markierte Konsolenausgabe zur Validierung zurueck.

Tool Inventory Assessment fuehrt vorhandene Local- und Remote-Inventare analytisch zusammen. Eine Quelle darf fehlen; dann bleibt die vorhandene Quelle sichtbar, das Gesamtassessment wird `incomplete` und Toolbewertungen mit unzureichender Datenbasis werden `unknown`.

Adapter Eligibility Evaluation bewertet aus einem Assessed Tool Inventory, welche bekannten Deployment-Adapter ihre Voraussetzungen erfuellen. Sie trifft keine finale Adapterauswahl, erzeugt keine Befehle und fuehrt nichts aus.

Adapter Selection liest ausschliesslich das Eligibility-Ergebnis und waehlt deterministisch genau einen eligible Adapter aus, sofern eine Auswahl moeglich ist. Sie bewertet keine Tool-Verfuegbarkeit neu, erzeugt keine Commands und fuehrt nichts aus.

Deployment Strategy kombiniert den Resolved Execution Plan mit der Adapter Selection zu einem fachlichen Ablauf fuer spaetere Command Generation. Sie beschreibt Operationen, Akteure, Orte, Human Gates und Rueckmeldeanforderungen, erzeugt aber keine konkreten Shell-, SSH- oder SCP-Kommandos und fuehrt nichts aus.

Command Generation erzeugt aus Resolved Execution Plan und Deployment Strategy einen strukturierten Command Plan. `program` und `arguments` sind die fuehrenden Daten; `renderedCommand` ist nur eine deterministische Darstellung zum Kopieren. Die Phase fuehrt nichts aus und erlaubt keine automatische Ausfuehrung.

Command Session trennt den Command Plan vom spaeteren Laufzeitstatus. Sie erzeugt einen deterministischen Session-Zustand, verarbeitet ausschliesslich strukturierte Events und fuehrt keine Commands aus.

Execution Admission ist die letzte analytische Sicherheitsbarriere vor einem spaeteren Local Executor. Sie liest Command Plan und Command Session, validiert zuerst die vollstaendige Plan-/Session-Konsistenz und Event-History, bewertet danach ausschliesslich `currentItemId` und erzeugt eine deterministische Zulassungsentscheidung. In V1 kann lokale Automation nur `eligible-but-disabled` werden; `admitted` wird erst mit einem spaeteren Executor und expliziter Ausfuehrungsfreigabe eingefuehrt.

Executor Request ueberfuehrt eine freigegebene, aber weiterhin deaktivierte Execution Admission in einen validierten Vertrag fuer den Local Operation Executor. Der Request bleibt `status = disabled`, enthaelt `operationType` und strukturierte `operation`-Daten und veraendert weder Command Session noch Events.

Local Operation Executor V1 verarbeitet ausschliesslich solche Executor Requests und fuehrt nur explizit erlaubte lokale Operationen aus. Unterstuetzt sind `source.validate` und `archive.create`; SSH, SCP, generische Shell-Ausfuehrung, Netzwerkzugriff, Session-Mutation und Event-Erzeugung bleiben ausgeschlossen.

## Unterstuetzter Umfang in Version 0.1

- Projektmanifest lesen und validieren
- Git-Baseline und Zielcommit aufloesen
- Git-Diff mit Umbenennungen auswerten
- Artefakte anhand projektspezifischer Regeln klassifizieren
- `.env.example`-Schluessel vergleichen und optional gegen `environmentManagement` bewerten
- geaenderte Laravel-Seeders statisch fuer Review-Zwecke einschaetzen
- Deployment-Entscheidungen und manuelle Freigabepunkte ableiten
- Konsolenzusammenfassung und optionales Analyzer-JSON erzeugen
- Analyzer-JSON in einen Execution Plan mit Capability IDs uebersetzen
- Capability IDs in einen Resolved Execution Plan aufloesen
- lokale Tool Discovery fuer `php`, `composer`, `docker`, `7z`, `zip`, `unzip`, `tar` und projektbezogen `artisan`
- Remote Tool Discovery als Human Gate mit statischer Probe-Allowlist und markierter Konsolenausgabe
- Tool Inventory Assessment ohne Versionskompatibilitaetsentscheidung
- Adapter Eligibility Evaluation fuer `archive.zip` und `archive.tar` ohne finale Adapterauswahl
- Adapter Selection fuer `archive.zip` und `archive.tar` nach zentraler Adapter-Prioritaet
- Deployment Strategy mit Actor-Modell `automation`, `human-decision`, `human-command` und `review`
- Command Generation mit strukturiertem Command Model und `executionAllowed = false`
- Command Session mit eventbasiertem Statusmodell ohne Ausfuehrung oder automatische Freigabe
- Execution Admission als analytische Zulassungsschicht mit `eligible-but-disabled`, ohne Prozessstart und ohne Netzwerkzugriff
- Executor Request als deaktivierter Vertrag fuer lokale Automation
- Local Operation Executor V1 fuer `source.validate` und `archive.create` mit enger Allowlist
- Agent-, Human- und Review-Schritte unterscheiden
- verbindliche Pausepunkte, Abhaengigkeiten und Validierungsanforderungen modellieren
- Migrationen als High-Risk-Schritte mit Safety Review, `migrate:status` und ausdruecklicher Freigabe modellieren

## Environment-Vertrag

Das Projektmanifest kann optional `environmentManagement` enthalten. Dieser Abschnitt beschreibt erwartete Environment-Schluessel, ihre Strategie, ob sie geheim sind, ob bestehende Zielwerte ueberschrieben werden duerfen und ob ein Wert zwingend benoetigt wird.

Der Analyzer liest dafuer ausschliesslich versionierte Vertragsdateien wie `laravel_app/.env.example`. Zielsystemdateien wie `.env` werden nicht gelesen, nicht geschrieben und nicht aus Beispielwerten rekonstruiert. Secret-Schluessel duerfen keine konkreten Werte oder `suggestedValue` im Manifest enthalten.

Unbekannte, hinzugefuegte oder entfernte Schluessel sowie unvollstaendige Regeln erzeugen Review-Bedarf. Die spaetere Umsetzung bleibt ein Human-Gate; es wird keine Environment-Datei automatisch erzeugt oder veraendert.

## Seeder-Review

Geaenderte Dateien unter der Seeder-Klassifikation werden statisch analysiert. Die Engine erkennt einfache Hinweise wie betroffene Models, Tabellen, Schreiboperationen und potenziell destruktive Operationen und erzeugt daraus eine Review-Zusammenfassung.

Seeder werden dadurch nicht ausgefuehrt. Es gibt keine `db:seed`-Planung, keine Datenbankverbindung und keine Idempotenzgarantie. Das Ergebnis dient ausschliesslich als fachlicher Review-Hinweis vor einem Deployment.
- verbotene Artisan-Kommandos wie `migrate:fresh`, `migrate:refresh`, `migrate:reset`, `migrate:rollback` und `db:wipe` ablehnen
- Deployment-Marker-Update nur als letzten bedingten Planschritt modellieren

## Beispielaufruf fuer das Pilotprojekt

Deployment-Laufzeitdaten sollen in einem externen Run-Verzeichnis liegen, nicht im Deployment-Engine-Repository und nicht im zu deployenden Projekt-Repository. `<run-id>` ist ein Platzhalter fuer eine eindeutige Laufkennung.

```powershell
$runPath = Join-Path $env:LOCALAPPDATA 'SHK-MOMM\deployment-engine\runs\<run-id>'
New-Item -ItemType Directory -Force -Path `
    (Join-Path $runPath 'input'), `
    (Join-Path $runPath 'plans'), `
    (Join-Path $runPath 'inventories'), `
    (Join-Path $runPath 'decisions') | Out-Null
```

```powershell
.\tools\deployment-engine\src\ps1\Invoke-DeploymentAnalysis.ps1 `
    -ProjectManifestPath C:\path\to\your-project\deployment.project.json `
    -BaselineCommit e1cdff9 `
    -TargetCommit HEAD `
    -OutputPath (Join-Path $runPath 'input\deployment-analysis.json')
```

## Execution Plan erzeugen

```powershell
.\tools\deployment-engine\bin\deployment-engine.ps1 plan `
    -Analysis (Join-Path $runPath 'input\deployment-analysis.json') `
    -Manifest C:\path\to\your-project\deployment.project.json `
    -Format Text
```

JSON-Ausgabe:

```powershell
.\tools\deployment-engine\bin\deployment-engine.ps1 plan `
    -Analysis (Join-Path $runPath 'input\deployment-analysis.json') `
    -Manifest C:\path\to\your-project\deployment.project.json `
    -Format Json `
    -OutputPath (Join-Path $runPath 'plans\execution-plan.json')
```

Die `plan`-Ausgabe ist bereits ein resolved Plan. Der Resolver ist auch separat als PowerShell-Komponente vorhanden:

```powershell
.\tools\deployment-engine\src\ps1\Resolve-DeploymentCapabilities.ps1 `
    -PlanPath C:\path\to\execution-plan.json `
    -Format Json
```

## Tool Discovery ausfuehren

```powershell
.\tools\deployment-engine\bin\deployment-engine.ps1 discover-tools `
    -ProjectPath C:\path\to\your-project `
    -Format Json
```

Beispielstruktur:

```json
{
  "schemaVersion": "0.1",
  "platform": {
    "os": "windows",
    "architecture": "x64",
    "shell": "powershell"
  },
  "project": {
    "available": true,
    "artisan": {
      "available": true,
      "path": "C:\\path\\to\\project\\artisan"
    }
  },
  "tools": {
    "php": {
      "available": true,
      "path": "C:\\php\\php.exe",
      "version": "PHP 8.3.0",
      "status": "available",
      "diagnostic": ""
    }
  }
}
```

`available` beschreibt, ob ein Executable gefunden wurde. `status` beschreibt das Ergebnis der Discovery beziehungsweise Versionsprobe.

Statuswerte sind `available`, `not-found`, `version-unavailable`, `probe-failed` und `unsupported`. Tool Discovery selbst trifft keine Capability-zu-Tool-Zuordnung und keine Adapterentscheidung.

## Remote Tool Discovery ausfuehren

```powershell
.\tools\deployment-engine\bin\deployment-engine.ps1 remote-discovery-plan `
    -Platform linux `
    -OutputPath (Join-Path $runPath 'plans\remote-discovery-plan.json')
```

Der Plan enthaelt ein Human Gate, einen deterministischen `planFingerprint`, feste Probe-IDs, feste Anzeigebefehle und ein Marker-Template. Vor den Projektprobes wechselt der Benutzer selbst in das bekannte Projektverzeichnis; Projektpfade werden nicht in Shell-Kommandos interpoliert.

Nach der manuellen Ausfuehrung wird die vollstaendige Ausgabe im Markerformat ausgewertet:

```powershell
.\tools\deployment-engine\bin\deployment-engine.ps1 resolve-remote-discovery `
    -PlanPath (Join-Path $runPath 'plans\remote-discovery-plan.json') `
    -ResponsePath (Join-Path $runPath 'input\remote-discovery-response.txt') `
    -OutputPath (Join-Path $runPath 'inventories\remote-tool-inventory.json')
```

Eine blosse Bestaetigung wie `erledigt` reicht nicht aus. Unbekannte, doppelte oder unvollstaendige Marker werden kontrolliert abgelehnt beziehungsweise als unvollstaendig bewertet. Die Ausgabe wird nur als Text verarbeitet und in ein Remote Tool Inventory ueberfuehrt. Es findet keine Adapter Selection, Installation oder Deployment-Ausfuehrung statt. Keine Passwoerter, Tokens, Zugangsdaten oder `.env`-Inhalte einfuegen.

## Tool Inventories bewerten

```powershell
.\tools\deployment-engine\bin\deployment-engine.ps1 assess-tool-inventories `
    -LocalInventoryPath (Join-Path $runPath 'inventories\local-tool-inventory.json') `
    -RemoteInventoryPath (Join-Path $runPath 'inventories\remote-tool-inventory.json') `
    -OutputPath (Join-Path $runPath 'decisions\assessed-tool-inventory.json')
```

Mindestens ein Inventory-Pfad muss angegeben werden. Local und Remote bleiben getrennte Quellen; Pfade und Versionen werden nicht zusammengefuehrt. Fehlt eine Quelle, entsteht `status = incomplete`. `available-local-only` und `available-remote-only` bedeuten, dass beide Seiten tatsaechlich geprueft wurden. Unterschiedliche Versionen werden nur angezeigt und nicht als kompatibel oder inkompatibel bewertet.

## Adapter Eligibility bewerten

```powershell
.\tools\deployment-engine\bin\deployment-engine.ps1 evaluate-adapter-eligibility `
    -AssessmentPath (Join-Path $runPath 'decisions\assessed-tool-inventory.json') `
    -OutputPath (Join-Path $runPath 'decisions\adapter-eligibility.json')
```

V1 kennt `archive.zip` und `archive.tar`. `archive.zip` benoetigt lokal `7z` oder `zip` und remote `unzip` oder `7z`. `archive.tar` benoetigt lokal `7z` oder `tar` und remote `tar` oder `7z`. Adapterstatuswerte sind `eligible`, `ineligible` und `unknown`; das Gesamtergebnis ist `ready`, `incomplete` oder `blocked`. Die Kompatibilitaet wird in V1 nur als angenommen ausgewiesen. Eligibility erzeugt keine finale Auswahl; ein alternativer manueller Deploymentplan bei blockiertem automatischem Deployment ist Roadmap, nicht Teil dieser Phase.

## Adapter auswaehlen

```powershell
.\tools\deployment-engine\bin\deployment-engine.ps1 select-adapter `
    -EligibilityPath (Join-Path $runPath 'decisions\adapter-eligibility.json') `
    -OutputPath (Join-Path $runPath 'decisions\adapter-selection.json')
```

Die Selection ist eine reine Entscheidungsphase nach der Eligibility Evaluation. Eligibility beantwortet, welche Adapter grundsaetzlich nutzbar sind; Selection beantwortet, welcher eligible Adapter tatsaechlich gewaehlt wird. Auswaehlbar sind nur Kandidaten mit `eligibilityStatus = eligible`. Die Sortierung ist deterministisch nach `priority` aufsteigend und danach `adapterId` aufsteigend. Aktuell wird ZIP bei gleicher Eligibility gegenueber TAR bevorzugt, weil `archive.zip` Prioritaet `100` und `archive.tar` Prioritaet `200` besitzt.

Das Ergebnis enthaelt `selectedAdapterId` ausschliesslich in der Selection-Ausgabe. Bei `selected` ist genau ein Kandidat ausgewaehlt. Bei `incomplete` oder `blocked` bleibt `selectedAdapterId = ""`; es wird kein Adapter ausgewaehlt. Selection erzeugt keine Commands, keine Steps, keine Archive und fuehrt nichts aus. Runtime Directory Management, Clean-Tree Assessment, Command Generation und Executor bleiben getrennte Phasen.

## Runtime Directory erzeugen

```powershell
.\tools\deployment-engine\bin\deployment-engine.ps1 create-runtime-directory `
    -RuntimeRootPath 'D:\DeploymentRuntime\deployment-runs' `
    -OutputPath 'D:\DeploymentRuntime\deployment-runs\runtime.json'
```

Runtime Directory Management erzeugt unter einem expliziten, bereits vorhandenen Runtime Root ein eindeutiges Run-Verzeichnis mit `artifacts`, `decisions`, `events`, `input`, `inventory`, `logs` und `reports`. Die Ausgabe enthaelt nur Metadaten und Pfade. Die Komponente erzeugt keine Session, startet keinen Executor, prueft kein Git und fuehrt kein Deployment aus.

## Clean-Tree bewerten

```powershell
.\tools\deployment-engine\bin\deployment-engine.ps1 assess-clean-tree `
    -RepositoryPath 'D:\Projekte\kunde\app' `
    -OutputPath (Join-Path $runPath 'reports\source-state.json')
```

Clean-Tree Assessment bewertet den Git-Zustand eines Repository-Pfads rein lesend. Die Ausgabe unterscheidet `clean` und `dirty`, setzt `deploymentAllowed` nur bei sauberem Working Tree auf `true` und listet staged, unstaged sowie untracked Pfade. Die Komponente fuehrt kein `git add`, keinen Commit, keinen Reset, keine Bereinigung und keine Deployment-Aktion aus.

## Deployment Strategy erzeugen

```powershell
.\tools\deployment-engine\bin\deployment-engine.ps1 build-deployment-strategy `
    -ExecutionPlanPath (Join-Path $runPath 'plans\execution-plan.json') `
    -AdapterSelectionPath (Join-Path $runPath 'decisions\adapter-selection.json') `
    -OutputPath (Join-Path $runPath 'decisions\deployment-strategy.json')
```

Die Deployment Strategy ist eine reine Planungsphase nach Adapter Selection und vor spaeterer Command Generation. Sie unterscheidet `automation`, `human-decision`, `human-command` und `review`. Lokale automatisierbare Schritte werden als `automation` modelliert. Ein zentrales Deployment-Approval ist ein `human-decision` Gate. SSH- und Upload-nahe Schritte bleiben in V1 `human-command`: Die Strategy markiert nur, dass spaeter ein vollstaendig kopierbarer Befehl erzeugt werden muss; der Benutzer fuehrt ihn aus und liefert strukturierte Rueckmeldung wie Exit-Status, stdout und stderr.

Statuswerte sind `ready`, `incomplete` und `blocked`. Der normale V1-Erfolgsfall ist `ready`, weil eine vorherige Adapter Selection mit `status = selected` erforderlich ist. Bei `incomplete` oder `blocked` aus der Adapter Selection wird keine ausfuehrbare Strategy erzeugt. Die Phase erzeugt keine Commands, fuehrt keine Git-Pruefung aus, legt kein Runtime-Verzeichnis an und startet keinen Executor.

## Command Plan erzeugen

```powershell
.\tools\deployment-engine\bin\deployment-engine.ps1 generate-commands `
    -ExecutionPlanPath (Join-Path $runPath 'plans\execution-plan.json') `
    -DeploymentStrategyPath (Join-Path $runPath 'decisions\deployment-strategy.json') `
    -OutputPath (Join-Path $runPath 'decisions\command-plan.json')
```

Der Command Plan beschreibt spaetere Ausfuehrungseinheiten, fuehrt sie aber nicht aus. Jeder Eintrag besitzt `program`, `arguments`, `renderedCommand`, Anzeigeinformationen, Feedback-Anforderungen und Safety-Flags. `program` und `arguments` sind fachlich fuehrend; `renderedCommand` wird nur daraus erzeugt.

In V1 sind `local-operation`, `ssh` und `scp` als Programmart unterstuetzt. `local-operation` ist ein nicht ausfuehrbarer Platzhalter fuer spaetere lokale Automation. SSH- und SCP-Eintraege bleiben `copy-and-run`, `copyable = true` und `executionPermitted = false`; der Benutzer fuehrt sie spaeter manuell aus und liefert Rueckmeldung. Fehlen SSH-Ziel, absoluter Remote-Pfad oder lokaler Artefaktpfad, wird der Command Plan `incomplete` statt Pfade oder Ziele zu erfinden. Target Discovery, Runtime Directory Management und Executor bleiben spaetere Bausteine.

## Command Session verwalten

```powershell
.\tools\deployment-engine\bin\deployment-engine.ps1 create-command-session `
    -CommandPlanPath (Join-Path $runPath 'decisions\command-plan.json') `
    -OutputPath (Join-Path $runPath 'decisions\command-session.json')
```

```powershell
.\tools\deployment-engine\bin\deployment-engine.ps1 update-command-session `
    -CommandSessionPath (Join-Path $runPath 'decisions\command-session.json') `
    -SessionEventPath (Join-Path $runPath 'input\session-event.json') `
    -OutputPath (Join-Path $runPath 'decisions\command-session.updated.json')
```

Die Command Session verwaltet nur Zustand. Items entstehen aus Command-Plan-Commands und Human Gates. Statuswerte sind `created`, `waiting`, `in-progress`, `completed`, `blocked`, `failed` und `cancelled`; einzelne Items verwenden `pending`, `ready`, `waiting-for-human`, `running`, `completed`, `failed`, `skipped`, `blocked` und `cancelled`.

Zustandsaenderungen erfolgen ausschliesslich ueber Events mit stabiler `eventId`, zum Beispiel `automation-started`, `automation-result`, `human-decision-submitted`, `human-command-started`, `human-command-result`, `review-result` oder `session-cancelled`. Automation-Items benoetigen ein Start-Event und danach ein strukturiertes Result-Event; die Command Session startet dabei keinen Prozess. Human Gates uebernehmen `sequence` und `dependsOn` aus Strategy beziehungsweise Command Plan und werden erst aktiv, wenn ihre modellierten Abhaengigkeiten abgeschlossen sind. Human Commands benoetigen ebenfalls ein Start-Event und danach ein Result-Event; der technische Erfolg wird ausschliesslich ueber `exitStatus = 0` bewertet. Sobald mindestens ein Item `running` ist, steht die Session auf `in-progress`. Es gibt keine automatische Freigabe, keine automatische Erfolgserkennung aus Freitext, keine versteckten Zeitstempel und keinen Retry.

## Execution Admission bewerten

```powershell
.\tools\deployment-engine\bin\deployment-engine.ps1 evaluate-execution-admission `
    -CommandPlanPath (Join-Path $runPath 'decisions\command-plan.json') `
    -CommandSessionPath (Join-Path $runPath 'decisions\command-session.json') `
    -OutputPath (Join-Path $runPath 'decisions\execution-admission.json')
```

Execution Admission prueft den gesamten Command Plan und die gesamte Command Session gegeneinander und bewertet erst danach das aktuelle `currentItemId`. Alle Session-Items muessen ihren Plan-Urspruengen entsprechen; die Event-History muss actor-spezifisch zu Start-, Result-, Decision- und Review-Status passen. Human Approvals werden aus Human Gates und dem Dependency-Graph ermittelt, nicht aus einer fest codierten Gate-ID.

In V1 wird ausschliesslich lokale Automation mit `actor = automation`, `executionLocation = local`, `executionMode = automatic`, `program = local-operation` und Item-Status `ready` als `eligible-but-disabled` markiert. `executionEligible = true` bedeutet dabei nur fachliche Eignung fuer einen spaeteren lokalen Executor; `executionAdmitted` bleibt immer `false`.

Human Decisions und Human Commands ergeben `requires-human`, Review Items ergeben `requires-review`. Remote-Ausfuehrung, SSH, SCP und lokale-zu-remote Schritte werden niemals automatisch zugelassen. Die Ausgabe enthaelt eine konstante `executionPolicy` mit `productiveExecutionAllowed = false`, `processStartAllowed = false`, `networkAccessAllowed = false` und `remoteExecutionAllowed = false`. Die Phase erzeugt keine Events, startet keine Prozesse, baut kein Netzwerk auf, veraendert keine Session und fuehrt kein Deployment aus. Der Status `admitted` wird erst mit dem spaeteren Executor eingefuehrt.

## Executor Request erzeugen

```powershell
.\tools\deployment-engine\bin\deployment-engine.ps1 build-executor-request `
    -CommandPlanPath (Join-Path $runPath 'decisions\command-plan.json') `
    -CommandSessionPath (Join-Path $runPath 'decisions\command-session.json') `
    -ExecutionAdmissionPath (Join-Path $runPath 'decisions\execution-admission.json') `
    -OutputPath (Join-Path $runPath 'decisions\executor-request.json')
```

Der Executor Request liest Command Plan, Command Session und Execution Admission und validiert, dass alle drei Artefakte dasselbe aktuelle lokale Automation-Item referenzieren. Er wird nur fuer `eligible-but-disabled` mit `executionEligible = true` und `executionAdmitted = false` erzeugt. Human Commands, Remote-Ausfuehrung, SSH, SCP, aktivierte Plan-Ausfuehrung, nicht mehr bereite Items, inkonsistente IDs und secret-artige Inhalte werden kontrolliert abgelehnt.

Das Ergebnis ist ein deterministisches JSON-Objekt mit `executorRequestType = deployment-executor-request` und `status = disabled`. Es beschreibt den `local-operation`-Vertrag inklusive `operationType`, strukturierter `operation`-Daten und `expectedEvents`, startet aber keinen Prozess, erzeugt keine Events, mutiert keine Session, verwendet kein Netzwerk und fuehrt kein Deployment aus.

## Lokale Operation ausfuehren

```powershell
.\tools\deployment-engine\bin\deployment-engine.ps1 execute-local-operation `
    -ExecutorRequestPath (Join-Path $runPath 'decisions\executor-request.json') `
    -OutputPath (Join-Path $runPath 'decisions\executor-result.json')
```

V1 akzeptiert nur `deployment-executor-request` mit `status = disabled`, `actor = automation`, `executionLocation = local`, `executionMode = automatic`, `program = local-operation` und explizitem `operationType`. `source.validate` prueft ein vorhandenes lokales Quellverzeichnis read-only. `archive.create` erzeugt ein ZIP-Archiv aus einem expliziten Quellverzeichnis an einem expliziten, noch nicht vorhandenen Artefaktpfad.

Archivierung schliesst mindestens `.env`, `.env.*`, `.git`, Schluesseldateien und typische private Key-Dateinamen aus. Bestehende Archive werden nicht ueberschrieben. Das Ergebnis ist ein `deployment-executor-result` mit `completed`, `failed` oder `rejected` und enthaelt immer die unveraenderte `sessionId` aus dem Executor Request; auch `failed` und `rejected` werden als parsebares JSON ausgegeben, sofern der Request strukturell verarbeitbar ist.

## Automation Events erzeugen

```powershell
.\tools\deployment-engine\bin\deployment-engine.ps1 build-automation-started-event `
    -CommandSessionPath (Join-Path $runPath 'decisions\command-session.json') `
    -ExecutorRequestPath (Join-Path $runPath 'decisions\executor-request.json') `
    -Timestamp '2026-07-27T12:00:00Z' `
    -OutputPath (Join-Path $runPath 'input\automation-started.json')
```

```powershell
.\tools\deployment-engine\bin\deployment-engine.ps1 build-automation-result-event `
    -CommandSessionPath (Join-Path $runPath 'decisions\command-session.running.json') `
    -ExecutorRequestPath (Join-Path $runPath 'decisions\executor-request.json') `
    -ExecutorResultPath (Join-Path $runPath 'decisions\executor-result.json') `
    -Timestamp '2026-07-27T12:00:01Z' `
    -OutputPath (Join-Path $runPath 'input\automation-result.json')
```

Der Automation Event Builder erzeugt genau ein Command-Session-Event und wendet es nicht an. Der Started Builder prueft eine startbereite lokale Automation und erzeugt `automation-started`. Der Result Builder prueft eine laufende lokale Automation, denselben Executor Request und ein `deployment-executor-result`; dabei muessen Command Session, Executor Request und Executor Result dieselbe `sessionId` tragen. `completed` bleibt erfolgreich, `failed` und `rejected` werden fuer das bestehende Session-Modell als fehlgeschlagenes `automation-result` abgebildet, wobei der urspruengliche Result-Status als `resultStatus` erhalten bleibt.

Der Zeitstempel wird immer explizit uebergeben und nach UTC normalisiert. Der Builder uebernimmt keine freien Request-Daten, keine Environment-Daten, kein `renderedCommand`, kein stdout/stderr und keine Secret-artigen Inhalte in Eventfelder. Die Session wird erst durch `update-command-session` mit dem erzeugten Event veraendert.

## Lokale Ausfuehrung orchestrieren

```powershell
.\tools\deployment-engine\bin\deployment-engine.ps1 orchestrate-local-execution `
    -CommandPlanPath (Join-Path $runPath 'decisions\command-plan.json') `
    -SourceRepositoryPath 'D:\Projekte\kunde\app' `
    -RuntimeRootPath 'D:\DeploymentRuntime\deployment-runs' `
    -Format Json
```

Der Execution Orchestrator V1 koordiniert nur bestehende Bausteine. Er erzeugt ein Runtime-Verzeichnis, kopiert den Command Plan nach `input/command-plan.json`, fuehrt vor jeder Session-Ausfuehrung das Clean-Tree Assessment aus und erstellt erst bei sauberem Repository eine Command Session. Bei Dirty Repository endet der Lauf kontrolliert mit `blocked`, ohne Session, Executor Request, lokale Operation oder Archiv.

Bei zulaessiger lokaler Automation verwendet der Orchestrator die bestehende Kette `Execution Admission -> Executor Request -> automation-started Event -> Command Session Update -> Local Operation Executor -> automation-result Event -> Command Session Update`. Session-Zustaende werden ausschliesslich durch bestehende Events veraendert. Unterstuetzt sind nur die vorhandenen lokalen Operationen `source.validate` und `archive.create`.

Der Orchestrator beendet den Lauf mit `completed`, `failed`, `blocked`, `cancelled`, `waiting-for-human` oder kontrolliert `rejected`. Human Decisions, Human Commands und Review Gates werden nicht automatisch beantwortet; der Lauf pausiert mit `waiting-for-human`. Alle Zwischenartefakte und `reports/execution-summary.json` liegen im erzeugten Runtime-Verzeichnis. V1 ist kein vollstaendiges Deployment, fuehrt kein SSH/SCP aus, nutzt kein Netzwerk, macht kein Git-Staging, keinen Commit, keinen Push, keinen Reset und keinen Rollback.

Ein pausierter lokaler Lauf kann mit einem explizit bereitgestellten Session-Event fortgesetzt werden:

```powershell
.\tools\deployment-engine\bin\deployment-engine.ps1 resume-local-execution `
    -RuntimeDirectoryPath 'D:\DeploymentRuntime\deployment-runs\run-...' `
    -SessionEventPath 'D:\DeploymentRuntime\input\human-decision-event.json' `
    -Format Json
```

Resume laedt `input/command-plan.json`, `decisions/command-plan-effective.json`, `reports/execution-summary.json` und den deterministisch letzten Command-Session-Snapshot. Zulaessig ist nur ein vorheriger Status `waiting-for-human` mit passendem Human- oder Review-Current-Item. Unterstuetzt werden ausschliesslich vorhandene Session-Events `human-decision-submitted`, `human-command-result` und `review-result`; das Event muss dieselbe `sessionId` tragen und darf noch nicht in der Event-History enthalten sein. Die Engine erzeugt keine Entscheidung selbst, wendet das Event nur ueber `Apply-CommandSessionEvent` an, archiviert es unter `events/external-session-event-*.json` und schreibt neue Snapshots ohne bestehende Artefakte zu ueberschreiben.

## Local End-to-End Example

Ein minimales lokales Beispiel liegt unter `examples/e2e`. Der Beispiel-Command-Plan modelliert `source.validate`, `archive.create`, eine Human Approval und danach einen weiteren vorhandenen lokalen `source.validate`-Schritt als Post-Approval-Pruefung.

```powershell
.\tools\deployment-engine\bin\deployment-engine.ps1 orchestrate-local-execution `
    -CommandPlanPath '.\tools\deployment-engine\examples\e2e\command-plan.example.json' `
    -SourceRepositoryPath 'D:\Projekte\kunde\app' `
    -RuntimeRootPath 'D:\DeploymentRuntime\deployment-runs' `
    -Format Json

.\tools\deployment-engine\bin\deployment-engine.ps1 resume-local-execution `
    -RuntimeDirectoryPath 'D:\DeploymentRuntime\deployment-runs\run-...' `
    -SessionEventPath 'D:\DeploymentRuntime\input\human-approval-event.json' `
    -Format Json
```

Der automatisierte Test `tests/ExecutionE2E.Tests.ps1` kopiert das Fixture in ein temporaeres sauberes Git-Repository, startet den lokalen Lauf ueber die CLI bis `waiting-for-human`, reicht ein explizites Human-Decision-Event ein und setzt denselben Runtime-Run bis `completed` fort.

Exit-Codes:

- `0`: Der angeforderte CLI-Vorgang wurde erfolgreich abgeschlossen.
- ungleich `0`: Der Vorgang ist kontrolliert fehlgeschlagen oder wurde wegen ungueltiger Eingaben abgebrochen.
