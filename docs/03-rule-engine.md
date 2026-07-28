# Rule Engine

Version `0.1` bewertet Regeln deterministisch aus Git-Diff, Klassifikationen, Environment-Vergleich und statischer Seeder-Analyse.

## Composer

Wenn `composer.lock` geaendert wurde, ist ein Composer-Schritt erforderlich. In Version `0.1` wird dieser Schritt nur im Plan markiert und nicht ausgefuehrt.

## Frontend-Build

Wenn `package-lock.json` oder Frontendquellen geaendert wurden, ist ein lokaler Frontend-Build erforderlich. Die Engine baut nicht selbst.

## Migrationen

Neue oder geaenderte Migrationen aktivieren die Migrationsphase. Jede Migrationsausfuehrung braucht einen ausdruecklichen Freigabepunkt.

## Environment

Wenn `.env.example` oder eine im Manifest konfigurierte Vertragsdatei geaendert wurde, analysiert die Engine neue, entfernte und unbekannte Schluessel. Optionale `environmentManagement`-Regeln liefern Strategie, Secret-Kennzeichnung, Ueberschreibschutz und Pflichtstatus. Zielsystem-Dateien wie `.env` werden nicht gelesen und nicht geaendert.

## Seeder

Wenn Seeder-Dateien geaendert wurden, erzeugt die Engine eine statische Review-Bewertung. Sie sucht nur im versionierten Dateitext nach einfachen Hinweisen auf Models, Tabellen, Schreiboperationen und destruktive Operationen. Seeder werden nicht ausgefuehrt und es wird kein `db:seed`-Befehl geplant.

## Cleanup

Geloeschte Runtime-Dateien fuehren zu einem kontrollierten Cleanup-Plan. Die Engine loescht keine Dateien.

## Documentation Only

Wenn ausschliesslich Dokumentation geaendert wurde, ist kein Runtime-Deployment erforderlich.

## Geschuetzte Serverdateien

Wenn eine geschuetzte Serverdatei betroffen ist, wird keine automatische Ueberschreibung geplant. Stattdessen entsteht ein Review-Punkt.

## Deployment-Marker

Ein Deployment-Marker darf erst nach erfolgreichem Deploy und erfolgreicher Verifikation aktualisiert werden. Version `0.1` liest Marker nur und schreibt sie nie.
