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
    -> spaeterer Executor
```

Der Analyzer ermittelt Aenderungen und Deployment-Entscheidungen. Der Execution Plan Builder uebersetzt dieses Ergebnis in stabile, maschinenlesbare Schritte mit `capabilityId`. Der Capability Resolver ist eine pure Transformation: Er veraendert den uebergebenen unresolved Plan nicht, sondern erzeugt ein neues Resolved Execution Plan-Objekt mit konkreten Anzeigeinformationen wie `displayCommand`, Ausfuehrungsmodus, Risikostufe, Freigabepflicht, Validierungsregeln und Fortsetzungsregeln. Ein spaeterer Executor darf den resolved Plan nur schrittweise verarbeiten und muss an Human- und Review-Gates verbindlich pausieren.

Remote-Befehle werden nur angezeigt. Der Agent besitzt keinen SSH-Zugriff und soll keinen SSH-Zugriff erhalten. Befehle auf dem Zielsystem werden ausschliesslich vom Benutzer ausgefuehrt. Wenn ein Schritt Konsolenausgabe verlangt, reicht eine reine Bestaetigung wie `erledigt` oder `lief durch` nicht aus.

Sicherheitsgrundsatz: Analyse ist standardmaessig rein lesend. Eine Ausgabe wird nur dann geschrieben, wenn ein lokaler `-OutputPath` explizit angegeben wird.

Technische Befehle stammen aus dem zentralen Capability-Katalog. Damit bleibt der fachliche Schritt vom konkreten Werkzeug getrennt: `Remote Migration` ist der fachliche Schritt, `artisan.migrate` ist die Capability und `php artisan migrate --force` ist nur der aktuell aufgeloeste Anzeigebefehl. Spaetere Werkzeuge wie `7z`, `zip`, `unzip`, `tar`, `composer` oder `artisan` sollen austauschbar bleiben, ohne das Planmodell umzubauen.

Capability-Regeln bilden die minimale Sicherheitsbasis. Builder-Regeln duerfen diese Basis nur ergaenzen oder verschaerfen: Validation-Patterns werden capability-first vereinigt, boolesche Sicherheitsanforderungen per OR zusammengefuehrt, erlaubte Fortsetzungszustaende geschnitten und widerspruechliche Execution Modes abgelehnt.

Tool Discovery ist eine neutrale, read-only Inventur lokaler Werkzeuge und optionaler Projektdateien. Sie trifft keine Adapterentscheidung, installiert nichts und fuehrt keine Deployment-Schritte aus. Fehlende Werkzeuge sind normale Inventory-Ergebnisse.

Remote Discovery erzeugt dagegen nur einen sicheren Human-Gate-Pruefplan. Die Engine besitzt keinen SSH-Zugriff und fuehrt keine Serverbefehle aus; der Benutzer fuehrt ausschliesslich die angezeigten statischen Pruefkommandos selbst aus und gibt die vollstaendige markierte Konsolenausgabe zur Validierung zurueck.

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
- lokale Tool Discovery fuer `php`, `composer`, `docker`, `7z`, `zip`, `tar` und projektbezogen `artisan`
- Remote Tool Discovery als Human Gate mit statischer Probe-Allowlist und markierter Konsolenausgabe
- Agent-, Human- und Review-Schritte unterscheiden
- verbindliche Pausepunkte, Abhaengigkeiten und Validierungsanforderungen modellieren
- Migrationen als High-Risk-Schritte mit Safety Review, `migrate:status` und ausdruecklicher Freigabe modellieren
- verbotene Artisan-Kommandos wie `migrate:fresh`, `migrate:refresh`, `migrate:reset`, `migrate:rollback` und `db:wipe` ablehnen
- Deployment-Marker-Update nur als letzten bedingten Planschritt modellieren

## Beispielaufruf fuer das Pilotprojekt

```powershell
.\tools\deployment-engine\src\ps1\Invoke-DeploymentAnalysis.ps1 `
    -ProjectManifestPath C:\path\to\your-project\deployment.project.json `
    -BaselineCommit e1cdff9 `
    -TargetCommit HEAD `
    -OutputPath C:\path\to\your-project\.tmp\deployment-analysis.json
```

## Execution Plan erzeugen

```powershell
.\tools\deployment-engine\bin\deployment-engine.ps1 plan `
    -Analysis C:\path\to\your-project\.tmp\deployment-analysis.json `
    -Manifest C:\path\to\your-project\deployment.project.json `
    -Format Text
```

JSON-Ausgabe:

```powershell
.\tools\deployment-engine\bin\deployment-engine.ps1 plan `
    -Analysis C:\path\to\your-project\.tmp\deployment-analysis.json `
    -Manifest C:\path\to\your-project\deployment.project.json `
    -Format Json `
    -OutputPath C:\path\to\your-project\.tmp\execution-plan.json
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

Statuswerte sind `available`, `not-found`, `version-unavailable`, `probe-failed` und `unsupported`. In Phase 2a gibt es noch keine Capability-zu-Tool-Zuordnung und keine Adapter Selection.

## Remote Tool Discovery ausfuehren

```powershell
.\tools\deployment-engine\bin\deployment-engine.ps1 remote-discovery-plan `
    -Platform linux `
    -OutputPath C:\path\to\your-project\.tmp\remote-discovery-plan.json
```

Der Plan enthaelt ein Human Gate, einen deterministischen `planFingerprint`, feste Probe-IDs, feste Anzeigebefehle und ein Marker-Template. Vor den Projektprobes wechselt der Benutzer selbst in das bekannte Projektverzeichnis; Projektpfade werden nicht in Shell-Kommandos interpoliert.

Nach der manuellen Ausfuehrung wird die vollstaendige Ausgabe im Markerformat ausgewertet:

```powershell
.\tools\deployment-engine\bin\deployment-engine.ps1 resolve-remote-discovery `
    -PlanPath C:\path\to\your-project\.tmp\remote-discovery-plan.json `
    -ResponsePath C:\path\to\your-project\.tmp\remote-discovery-response.txt `
    -OutputPath C:\path\to\your-project\.tmp\remote-tool-inventory.json
```

Eine blosse Bestaetigung wie `erledigt` reicht nicht aus. Unbekannte, doppelte oder unvollstaendige Marker werden kontrolliert abgelehnt beziehungsweise als unvollstaendig bewertet. Die Ausgabe wird nur als Text verarbeitet und in ein Remote Tool Inventory ueberfuehrt. Es findet keine Adapter Selection, Installation oder Deployment-Ausfuehrung statt. Keine Passwoerter, Tokens, Zugangsdaten oder `.env`-Inhalte einfuegen.

Exit-Codes:

- `0`: Plan wurde erzeugt und ist nicht durch Analyzer-Blocker blockiert.
- `1`: ungueltige Eingaben oder technische Fehler.
- `2`: Plan wurde erzeugt, enthaelt aber Blocker und darf nicht fortgesetzt werden.
