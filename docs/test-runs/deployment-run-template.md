# Deployment Run Template

## Metadaten

- Lauf-ID:
- Laufart: explorativer Referenzlauf / Validierungslauf
- Datum:
- Codex-Task:
- Engine-Repository:
- Engine-Branch:
- Engine-Commit:
- Engine-Git-Status:
- Zielprojekt:
- Zielprojekt-Branch:
- Zielprojekt-Commit:
- Zielprojekt-Git-Status:
- ProjectsRoot:
- Projektmanifest:
- Zielumgebung:

## Sicherheitsnotizen

- Keine Secrets in diesen Bericht uebernehmen.
- Keine vollstaendigen `.env`-Inhalte dokumentieren.
- Terminalausgaben vor Aufnahme auf Tokens, Passwoerter, private Schluessel, personenbezogene Daten und produktive Kundendaten pruefen.
- Lange Ausgaben zusammenfassen, sofern die vollstaendige Ausgabe fuer die Entscheidung nicht erforderlich ist.
- Beobachtung und Bewertung getrennt halten.

## Schrittprotokoll

| Zeitpunkt | Workflowzustand vorher | Ausloeser | Aktion | Klasse | verwendeter Befehl | erwartetes Ergebnis | tatsaechliches Ergebnis | Entscheidung | Workflowzustand nachher | Abweichung | Verbesserung |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
|  | Idle | Benutzer | Deployment-Intent aeussern | A | n/a | Codex erkennt Deployment-Intent |  |  | DeploymentIntentDetected |  |  |
|  | DeploymentIntentDetected | Codex | Project Discovery oder Project Resolution | A |  | strukturierte JSON-Ausgabe |  |  | ProjectDiscovery / ProjectResolution |  |  |
|  | ProjectResolved | Benutzer | Projekt bestaetigen | B | n/a | Projekt ist ausdruecklich bestaetigt |  |  | ProjectConfirmed |  |  |
|  | ProjectConfirmed | Codex | Analyse ausfuehren | A |  | Analyseergebnis liegt vor |  |  | Analysis |  |  |
|  | WaitingForOutput | Benutzer | Copy-and-Paste-Block ausfuehren | C |  | reale Terminalausgabe liegt vor |  |  |  |  |  |

## Beobachtungen

-

## Nachtraegliche Bewertung

-

## Offene Punkte

-

## Vergleichsnotiz Fuer Lauf 2

| Erkenntnis aus diesem Lauf | vorgesehene Anpassung | Pruefung in Lauf 2 | Status |
| --- | --- | --- | --- |
|  |  |  | offen |
