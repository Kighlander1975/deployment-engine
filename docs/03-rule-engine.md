# Rule Engine

Version `0.1` bewertet Regeln deterministisch aus Git-Diff, Klassifikationen und Environment-Vergleich.

## Composer

Wenn `composer.lock` geaendert wurde, ist ein Composer-Schritt erforderlich. In Version `0.1` wird dieser Schritt nur im Plan markiert und nicht ausgefuehrt.

## Frontend-Build

Wenn `package-lock.json` oder Frontendquellen geaendert wurden, ist ein lokaler Frontend-Build erforderlich. Die Engine baut nicht selbst.

## Migrationen

Neue oder geaenderte Migrationen aktivieren die Migrationsphase. Jede Migrationsausfuehrung braucht einen ausdruecklichen Freigabepunkt.

## Environment

Wenn `.env.example` geaendert wurde, analysiert die Engine neue und entfernte Schluessel. Zielsystem-Dateien wie `.env` werden nicht geaendert.

## Cleanup

Geloeschte Runtime-Dateien fuehren zu einem kontrollierten Cleanup-Plan. Die Engine loescht keine Dateien.

## Documentation Only

Wenn ausschliesslich Dokumentation geaendert wurde, ist kein Runtime-Deployment erforderlich.

## Geschuetzte Serverdateien

Wenn eine geschuetzte Serverdatei betroffen ist, wird keine automatische Ueberschreibung geplant. Stattdessen entsteht ein Review-Punkt.

## Deployment-Marker

Ein Deployment-Marker darf erst nach erfolgreichem Deploy und erfolgreicher Verifikation aktualisiert werden. Version `0.1` liest Marker nur und schreibt sie nie.
