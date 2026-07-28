# Deployment Test Runs

Dieses Verzeichnis enthaelt Vorlagen fuer reale, Codex-gefuehrte Deployment-Testlaeufe. Es enthaelt keine erfundenen Ergebnisse.

Der erste Lauf kann als explorativer Referenzlauf dokumentiert werden. Der zweite Lauf kann als Validierungslauf gegen die Erkenntnisse des ersten Laufs dokumentiert werden.

Vorlagen:

- [deployment-run-template.md](deployment-run-template.md): Schrittprotokoll fuer einen einzelnen realen Lauf.

Sicherheitsregeln:

- Keine Secrets dokumentieren.
- Keine vollstaendigen `.env`-Inhalte uebernehmen.
- Lange Terminalausgaben nur soweit noetig zitieren oder sicher zusammenfassen.
- Fehlerausgaben vor Aufnahme auf Secrets pruefen.
- Beobachtung und nachtraegliche Bewertung trennen.
- Engine-Commit, Zielprojekt-Commit und Git-Status erfassen.

Vergleich Lauf 1 zu Lauf 2:

| Erkenntnis aus Lauf 1 | vorgenommene Anpassung | Ergebnis in Lauf 2 | Status |
| --- | --- | --- | --- |
|  |  |  | offen |
