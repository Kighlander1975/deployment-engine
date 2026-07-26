# SHK-MOMM Deployment Engine

Die SHK-MOMM Deployment Engine ist ein projektuebergreifendes Werkzeug zur nachvollziehbaren Deployment-Analyse, Planerzeugung und spaeteren kontrollierten Ausfuehrung von Deployments.

Version `0.1` liefert ausschliesslich Analyse- und Planungsfunktionen. Sie liest ein Projektmanifest, vergleicht zwei Git-Commits, klassifiziert geaenderte Artefakte und kann daraus einen strukturierten Execution Plan mit verbindlichen Human Gates ableiten.

## Analyse und Ausfuehrung

Die aktuelle Version fuehrt keine Deployments aus. Sie kopiert keine Dateien, erzeugt keine Pakete, fuehrt keine Migrationen aus, verbindet sich nicht per SSH und aktualisiert keine Deployment-Marker. Die spaetere Execution-Phase wird bewusst von Analyse und Planerzeugung getrennt.

Die fachliche Trennung lautet:

```text
Analyzer
    -> Execution Plan Builder
    -> spaeterer Executor
```

Der Analyzer ermittelt Aenderungen und Deployment-Entscheidungen. Der Execution Plan Builder uebersetzt dieses Ergebnis in stabile, maschinenlesbare Schritte. Ein spaeterer Executor darf den Plan nur schrittweise verarbeiten und muss an Human- und Review-Gates verbindlich pausieren.

Remote-Befehle werden nur angezeigt. Der Agent besitzt keinen SSH-Zugriff und soll keinen SSH-Zugriff erhalten. Befehle auf dem Zielsystem werden ausschliesslich vom Benutzer ausgefuehrt. Wenn ein Schritt Konsolenausgabe verlangt, reicht eine reine Bestaetigung wie `erledigt` oder `lief durch` nicht aus.

Sicherheitsgrundsatz: Analyse ist standardmaessig rein lesend. Eine Ausgabe wird nur dann geschrieben, wenn ein lokaler `-OutputPath` explizit angegeben wird.

Technische Befehle werden zentral ueber interne Command-Definitionen erzeugt. Damit bleibt der fachliche Schritt vom konkreten Werkzeug getrennt: `Remote Migration` ist der fachliche Schritt, `php artisan migrate --force` ist nur der aktuelle technische Befehl. Spaetere Werkzeuge wie `7z`, `zip`, `unzip`, `tar`, `composer` oder `artisan` sollen austauschbar bleiben, ohne das Planmodell umzubauen.

## Unterstuetzter Umfang in Version 0.1

- Projektmanifest lesen und validieren
- Git-Baseline und Zielcommit aufloesen
- Git-Diff mit Umbenennungen auswerten
- Artefakte anhand projektspezifischer Regeln klassifizieren
- `.env.example`-Schluessel vergleichen
- Deployment-Entscheidungen und manuelle Freigabepunkte ableiten
- Konsolenzusammenfassung und optionales Analyzer-JSON erzeugen
- Analyzer-JSON in einen Execution Plan uebersetzen
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

Exit-Codes:

- `0`: Plan wurde erzeugt und ist nicht durch Analyzer-Blocker blockiert.
- `1`: ungueltige Eingaben oder technische Fehler.
- `2`: Plan wurde erzeugt, enthaelt aber Blocker und darf nicht fortgesetzt werden.
