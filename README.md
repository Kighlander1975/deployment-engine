# SHK-MOMM Deployment Engine

Die SHK-MOMM Deployment Engine ist ein projektuebergreifendes Werkzeug zur nachvollziehbaren Deployment-Analyse, Planung und spaeteren Ausfuehrung von Deployments.

Version `0.1` liefert ausschliesslich Analyse- und Planungsfunktionen. Sie liest ein Projektmanifest, vergleicht zwei Git-Commits, klassifiziert geaenderte Artefakte und leitet daraus einen strukturierten Deployment-Plan ab.

## Analyse und Ausfuehrung

Die aktuelle Version fuehrt keine Deployments aus. Sie kopiert keine Dateien, erzeugt keine Pakete, fuehrt keine Migrationen aus und aktualisiert keine Deployment-Marker. Die spaetere Execution-Phase wird bewusst von der Analyse getrennt.

Sicherheitsgrundsatz: Analyse ist standardmaessig rein lesend. Eine Ausgabe wird nur dann geschrieben, wenn ein lokaler `-OutputPath` explizit angegeben wird.

## Unterstuetzter Umfang in Version 0.1

- Projektmanifest lesen und validieren
- Git-Baseline und Zielcommit aufloesen
- Git-Diff mit Umbenennungen auswerten
- Artefakte anhand projektspezifischer Regeln klassifizieren
- `.env.example`-Schluessel vergleichen
- Deployment-Entscheidungen und manuelle Freigabepunkte ableiten
- Konsolenzusammenfassung und optionalen JSON-Plan erzeugen

## Beispielaufruf fuer das Pilotprojekt

```powershell
.\tools\deployment-engine\src\ps1\Invoke-DeploymentAnalysis.ps1 `
    -ProjectManifestPath C:\path\to\your-project\deployment.project.json `
    -BaselineCommit e1cdff9 `
    -TargetCommit HEAD `
    -OutputPath C:\path\to\your-project\.tmp\deployment-analysis.json
```
