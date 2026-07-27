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
    -> spaeterer Executor
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

## Unterstuetzter Umfang in Version 0.1

- Projektmanifest lesen und validieren
- Git-Baseline und Zielcommit aufloesen
- Git-Diff mit Umbenennungen auswerten
- Artefakte anhand projektspezifischer Regeln klassifizieren
- `.env.example`-Schluessel vergleichen
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
- Agent-, Human- und Review-Schritte unterscheiden
- verbindliche Pausepunkte, Abhaengigkeiten und Validierungsanforderungen modellieren
- Migrationen als High-Risk-Schritte mit Safety Review, `migrate:status` und ausdruecklicher Freigabe modellieren
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

Das Ergebnis enthaelt `selectedAdapterId` ausschliesslich in der Selection-Ausgabe. Bei `selected` ist genau ein Kandidat ausgewaehlt. Bei `incomplete` oder `blocked` bleibt `selectedAdapterId = ""`; es wird kein Adapter ausgewaehlt. Selection erzeugt keine Commands, keine Steps, keine Archive und fuehrt nichts aus. Command Generation, Runtime Directory Management, Clean-Tree Gate und Executor bleiben spaetere Phasen.

## Deployment Strategy erzeugen

```powershell
.\tools\deployment-engine\bin\deployment-engine.ps1 build-deployment-strategy `
    -ExecutionPlanPath (Join-Path $runPath 'plans\execution-plan.json') `
    -AdapterSelectionPath (Join-Path $runPath 'decisions\adapter-selection.json') `
    -OutputPath (Join-Path $runPath 'decisions\deployment-strategy.json')
```

Die Deployment Strategy ist eine reine Planungsphase nach Adapter Selection und vor spaeterer Command Generation. Sie unterscheidet `automation`, `human-decision`, `human-command` und `review`. Lokale automatisierbare Schritte werden als `automation` modelliert. Ein zentrales Deployment-Approval ist ein `human-decision` Gate. SSH- und Upload-nahe Schritte bleiben in V1 `human-command`: Die Strategy markiert nur, dass spaeter ein vollstaendig kopierbarer Befehl erzeugt werden muss; der Benutzer fuehrt ihn aus und liefert strukturierte Rueckmeldung wie Exit-Status, stdout und stderr.

Statuswerte sind `ready`, `incomplete` und `blocked`. Der normale V1-Erfolgsfall ist `ready`, weil eine vorherige Adapter Selection mit `status = selected` erforderlich ist. Bei `incomplete` oder `blocked` aus der Adapter Selection wird keine ausfuehrbare Strategy erzeugt. Die Phase erzeugt keine Commands, fuehrt keine Git-Pruefung aus, legt kein Runtime-Verzeichnis an und startet keinen Executor.

Exit-Codes:

- `0`: Der angeforderte CLI-Vorgang wurde erfolgreich abgeschlossen.
- ungleich `0`: Der Vorgang ist kontrolliert fehlgeschlagen oder wurde wegen ungueltiger Eingaben abgebrochen.
