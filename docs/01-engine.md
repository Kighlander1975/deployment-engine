# Engine Pipeline

Die Pipeline der Version `0.1` ist bewusst in Analysephasen und spaetere Ausfuehrungsphasen getrennt.

## Project Detection

Die Engine liest das Projektmanifest, validiert Pflichtfelder und prueft, ob Projektroot und Application Root vorhanden sind. Pfade werden unabhaengig vom aktuellen Arbeitsverzeichnis aufgeloest.

## Repository Analysis

Die Engine prueft, ob der Projektroot ein Git-Repository ist, ermittelt den Arbeitsbaumstatus, loest Ziel- und Baselinecommit auf und zaehlt die Commits seit der Baseline. Ist die Baseline kein Vorfahr des Zielcommits, wird dies als Blocker ausgewiesen.

## Artifact Classification

Der Git-Diff wird mit `--name-status --find-renames` ausgewertet. Jede betroffene Datei wird anhand des Projektmanifests einer oder mehreren Artefaktklassen zugeordnet.

## Rule Evaluation

Die Regelbewertung leitet Entscheidungen aus den Klassifikationen und besonderen Dateiarten ab. Dazu gehoeren Composer-Schritte, Frontend-Build, Migrationsbedarf, Environment-Review, Cleanup und geschuetzte Dateien.

## Deployment Plan

Der Plan fasst Eingangsdaten, Git-Zustand, geaenderte Dateien, Klassifikationen, Environment-Aenderungen, Entscheidungen, Warnungen, Blocker und manuelle Freigabepunkte zusammen.

## Spaetere Execution

Die Ausfuehrung wird in Version `0.1` nicht implementiert. Eine spaetere Version darf erst nach expliziter Freigabe Pakete vorbereiten, Dateien uebertragen oder Befehle ausfuehren.

## Spaetere Verification

Die Verifikation wird ebenfalls erst spaeter umgesetzt. Sie soll nach einem Deployment technische und fachliche Pruefpunkte auswerten und erst danach die Aktualisierung eines Deployment-Markers erlauben.
