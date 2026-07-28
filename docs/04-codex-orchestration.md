# Codex Orchestration

Dieses Dokument beschreibt die Codex-gefuehrte Nutzung der Deployment Engine. Es ist kein neues Engine-Modul, keine technische State-Machine-Implementierung und kein Executor.

Codex ist der zustandsfuehrende Orchestrator. Die Deployment Engine bleibt ein deterministisches technisches Backend fuer Project Discovery, Project Resolution, Analyse, Planung und bereits vorhandene Pipeline-Komponenten. Die Engine kennt keinen Chat, keine natuerliche Sprache, keine implizite Projektauswahl und keine fachlichen Freigaben.

## Rollenmodell

Benutzer:

- trifft fachliche Zielentscheidungen,
- waehlt Projekte ausdruecklich aus,
- bestaetigt aufgeloeste Projekte,
- gibt kritische Aktionen frei,
- fuehrt Copy-and-Paste-Bloecke aus, wenn Codex sie nicht sicher selbst ausfuehren darf,
- bewertet fachliche Ergebnisse, wenn technische Ausgabe allein nicht ausreicht.

Codex:

- erkennt Deployment-Intent in natuerlicher Sprache,
- fuehrt den Dialog und den Workflowzustand,
- ruft Engine-Kommandos mit expliziten Parametern auf,
- fuehrt freigegebene unkritische Aktionen aus,
- erzeugt sichere PowerShell- oder SSH-Bloecke fuer Benutzer-Ausfuehrung,
- wartet auf reale Terminalausgaben,
- bewertet Ausgaben und entscheidet erst danach ueber den naechsten erlaubten Schritt,
- stoppt bei unklaren, unerwarteten oder widerspruechlichen Zustaenden.

Deployment Engine:

- liefert deterministische technische Operationen,
- erzeugt maschinenlesbare Ergebnisse,
- interpretiert keine natuerliche Sprache,
- trifft keine Benutzerauswahl,
- startet keine produktiven Remote-Aktionen in Version `0.1`.

## Fachliches Zustandsmodell

Dieses Modell beschreibt Codex-Orchestrierung. Es ersetzt nicht die technischen Command-Session- oder Engine-Statusmodelle.

```text
Idle
→ DeploymentIntentDetected
→ ProjectDiscovery beziehungsweise ProjectResolution
→ ProjectResolved
→ ProjectConfirmed
→ Analysis
→ AnalysisReviewed
→ ExecutionPlan
→ ExecutionApproved beziehungsweise WaitingForHuman
→ ExecutionRunning
→ Verification
→ Finished
```

Halte- und Endzustaende:

```text
Blocked
Failed
Cancelled
WaitingForHuman
WaitingForOutput
```

Die spaetere technische Persistierung dieses Codex-Zustands ist nicht Teil von Version `0.1`.

## Uebergangsregeln

| Vorheriger Zustand       | Ausloeser                              | Erlaubte Aktion                                      | Klasse      | Erwartetes Ergebnis              | Stop-Bedingung                                           | Naechster Zustand                     |
| ------------------------ | -------------------------------------- | ---------------------------------------------------- | ----------- | -------------------------------- | -------------------------------------------------------- | ------------------------------------- |
| Idle                     | Benutzer aeussert Deployment-Intent    | Intent erkennen, keinen Projekt-Default setzen       | A           | Intent ist erkannt               | Immer nach Entscheidung allgemeiner/spezifischer Trigger | DeploymentIntentDetected              |
| DeploymentIntentDetected | allgemeiner Trigger                    | `discover-projects` mit explizitem `ProjectsRoot`    | A           | Projektkatalog mit Eligibility   | Immer Projektauswahl verlangen                           | ProjectDiscovery                      |
| DeploymentIntentDetected | spezifischer Identifier                | `resolve-project` mit explizitem `ProjectIdentifier` | A           | Resolution-Status                | Immer Projektbestaetigung oder Klaerung verlangen        | ProjectResolution                     |
| ProjectDiscovery         | Benutzer waehlt Projekt-ID oder Alias  | `resolve-project` ausfuehren                         | A           | eindeutiger Status               | Bei `resolved` Bestaetigung verlangen, sonst klaeren     | ProjectResolved oder Blocked          |
| ProjectResolution        | `resolved`                             | ID, Name, Pfade anzeigen                             | A           | Projekt ist technisch aufgeloest | Immer ausdrueckliche Bestaetigung verlangen              | ProjectResolved                       |
| ProjectResolved          | Benutzer bestaetigt                    | Analyse vorbereiten                                  | B           | Projekt ist bestaetigt           | Vor Analyseparameter oder Baseline klaeren               | ProjectConfirmed                      |
| ProjectConfirmed         | Analysefreigabe liegt vor              | Analyzer ausfuehren                                  | A           | Analyseergebnis                  | Zusammenfassung anzeigen und pruefen                     | Analysis                              |
| Analysis                 | Analyse liegt vor                      | Risiken, Blocker, Reviews darstellen                 | A           | Entscheidungen sichtbar          | Bei Blocker oder Review stoppen                          | AnalysisReviewed oder Blocked         |
| AnalysisReviewed         | Plan angefordert                       | Execution Plan erzeugen                              | A           | strukturierter Plan              | Plan und Gates anzeigen                                  | ExecutionPlan                         |
| ExecutionPlan            | unkritischer lokaler Schritt           | freigegebene lokale Aktion ausfuehren                | A oder B    | reales Ergebnis                  | Ausgabe bewerten                                         | ExecutionRunning oder Blocked         |
| ExecutionPlan            | kritischer oder privilegierter Schritt | Copy-and-Paste-Block ausgeben                        | C           | Benutzer fuehrt aus              | Auf reale Ausgabe warten                                 | WaitingForOutput                      |
| WaitingForOutput         | Benutzer liefert Ausgabe               | Ausgabe pruefen                                      | A           | Erfolg, Fehler oder unklar       | Bei unklarer Ausgabe stoppen                             | ExecutionRunning, Blocked oder Failed |
| ExecutionRunning         | Verifikation erforderlich              | Verifikation ausfuehren oder Block ausgeben          | A, B oder C | reale Verifikationsausgabe       | Ergebnis bewerten                                        | Verification                          |
| Verification             | Verifikation erfolgreich               | Abschluss zusammenfassen                             | A           | Lauf ist nachvollziehbar beendet | Keine blinde Fortsetzung                                 | Finished                              |

## Aktionsklassen

Klasse A - autonom:

Codex darf die Aktion selbst ausfuehren, Ergebnis pruefen und weiterarbeiten. Typische Merkmale sind lesend, lokal begrenzt, deterministisch, reversibel, ohne fachliche Auswahl, ohne produktive Datenaenderung und ohne direkten privilegierten Serverzugriff.

Klasse B - Zustimmung erforderlich:

Codex erklaert die Aktion und holt vorher eine ausdrueckliche Zustimmung ein. Danach darf Codex sie ausfuehren, sofern der Zugriffsweg sicher erlaubt ist.

Klasse C - Benutzer-Ausfuehrung:

Codex erzeugt einen vollstaendigen sicheren Copy-and-Paste-Block. Der Benutzer fuehrt ihn aus und liefert die reale Ausgabe zurueck. Codex arbeitet erst nach Pruefung dieser Ausgabe weiter.

Klasse D - unzulaessig:

Die Aktion wird nicht ausgefuehrt. Codex darf keine Umgehung konstruieren.

## Sonderregeln

Lesender Netzlaufwerkzugriff kann Klasse A sein, wenn keine Datei, Berechtigung oder Struktur veraendert wird, keine Secrets ausgegeben werden, kein rekursiver Zugriff ausserhalb des erlaubten Ziels erfolgt und das Netzlaufwerk nicht als Deployment-Quelle interpretiert wird. Beispiele sind Laravel-Logs, Dateilisten, Release-Verzeichnisse, Statusdateien, Diagnoseinformationen, Zeitstempel und lesbare Healthcheck-Ergebnisse.

Schreibender Netzlaufwerkzugriff ist nicht automatisch Klasse A. Direkte SSH-Ausfuehrung derselben fachlichen Pruefung ist grundsaetzlich Klasse C.

Git-Abschlussarbeiten koennen nach vollstaendiger technischer Pruefung Klasse A sein. Die Preconditions beziehungsweise Vorbedingungen sind: Autonomes Staging setzt voraus, dass der erwartete Datei-Scope bekannt ist, keine unerwarteten Aenderungen vorliegen, untracked Dateien sichtbar sind, der Diff geprueft ist, erforderliche Syntaxpruefungen und Tests erfolgreich waren und ausschliesslich erwartete Dateien gestaged werden. Autonomer Commit setzt zusaetzlich exakt passenden Staging-Scope, erfolgreiches `git diff --cached --check` und eindeutige Commit-Nachricht voraus. Autonomer Push setzt eindeutigen Branch und Upstream, Fetch, keinen Rueckstand hinter Remote, keinen Force-Push und anschliessenden Commit-ID-Vergleich voraus.

Git-Abschluss im Zielprojekt und Git-Abschluss der Deployment Engine sind getrennte Vorgaenge.

## Stop-and-Wait

Codex darf reale Ausfuehrungsergebnisse nicht annehmen oder erfinden. Nach Klasse-C-Aktionen wartet Codex auf die tatsaechliche Terminalausgabe. Fehlende, unvollstaendige oder widerspruechliche Ausgabe blockiert den Uebergang. Codex bewertet die Ausgabe vor dem naechsten Schritt. Bei Fehlern wird kein nachgelagerter Schritt blind ausgefuehrt.

## Abweichungsverhalten

Codex stoppt oder fragt gezielt zurueck bei:

- unbekanntem Projekt,
- mehrdeutiger Aufloesung,
- `ineligible` Projekt,
- `identifier-conflict`,
- unerwartetem Git-Status,
- abweichendem Branch oder Upstream,
- Remote-Divergenz,
- fehlendem Manifest,
- ungueltigem Manifest,
- unbekannten Environment-Keys,
- fehlender Freigabe,
- nicht bestaetigtem Ziel,
- nicht auswertbarer Terminalausgabe,
- entdeckten Secrets in Ausgabe oder Dateien.

## Projektwahl

Allgemeiner Trigger:

```text
Deploye ein Projekt.
```

Codex fuehrt nur Project Discovery aus, zeigt `eligible` Projekte und wartet auf die Auswahl. Auch ein einziger Kandidat wird nicht automatisch gewaehlt. Auch ein eindeutiges `resolve-project`-Ergebnis ist noch keine Projektauswahl. Codex zeigt das aufgelöste Projekt an und wartet vor der Analyse auf die ausdrückliche Bestätigung des Benutzers.

Spezifischer Trigger:

```text
Deploye shk-momm-kundendaten.
```

Codex fuehrt Project Resolution aus und akzeptiert nur exakte `project.id` oder `project.aliases`, case-insensitive. `project.name`, Teilstrings, Fuzzy Matching, aktuelles Arbeitsverzeichnis, zuletzt verwendetes Projekt, erstes Projekt oder einziges Projekt sind keine Aufloesung.

## Verbotene Aktionen

Grundsaetzlich Klasse D sind:

- bestehende Secrets automatisch ueberschreiben,
- Secrets anzeigen oder loggen,
- vollstaendige `.env` hochladen,
- Seeder automatisch ausfuehren,
- Projekt automatisch auswaehlen,
- Force-Push im normalen Deployment-Prozess.

## Aktueller Stand und Ausblick

Bereits implementiert sind Project Catalog, Analyzer, Execution Plan Builder, Tool Discovery, Remote Discovery Plan, Inventory Assessment, Adapter Eligibility, Adapter Selection, Deployment Strategy, Command Generation, Command Session, Execution Admission, Executor Request, Local Operation Executor V1 und lokale Orchestrierung fuer erlaubte lokale Operationen.

Bereits als Architekturvertrag dokumentiert ist die Codex-Orchestrierung mit Stop-and-Wait und Aktionsklassen A/B/C/D.

Fuer den ersten realen Testlauf wird Codex den Workflow manuell orchestrieren und Ergebnisse protokollieren.

Spaetere V2-Themen sind eine importierbare Moduloberflaeche statt Skript-zu-Skript-Aufruf, systematische Entfernung historischer `exit`-Anweisungen und technische Persistierung einer vollstaendigen Codex-Workflow-State-Machine.
