# Artifact Classification

## documentation

Typische Pfade: `README.md`, `CHANGELOG.md`, `DECISIONS.md`, `BACKLOG.md`, `KANBAN.md`, `docs/**`, `*_docs/**`, `*.md`.

Bedeutung: Dokumentation, Arbeitsnotizen und Architekturtexte.

Konsequenz: Alleinige Dokumentationsaenderungen benoetigen kein Runtime-Deployment.

## backend-runtime

Typische Pfade: `laravel_app/app/**`, `laravel_app/bootstrap/**`, `laravel_app/config/**`, `laravel_app/routes/**`, `laravel_app/resources/views/**`.

Bedeutung: Serverseitiger Laravel-Code und Laufzeitkonfiguration.

Konsequenz: Runtime-Deployment erforderlich.

## frontend-source

Typische Pfade: `laravel_app/resources/js/**`, `laravel_app/resources/css/**`, `laravel_app/vite.config.*`, `laravel_app/tailwind.config.*`.

Bedeutung: Frontend-Quellcode, der lokal gebaut werden muss.

Konsequenz: Frontend-Build erforderlich; Build-Artefakte muessen konsistent deployt werden.

## frontend-build

Typische Pfade: `laravel_app/public/build/**`.

Bedeutung: Gebaute Vite-Artefakte.

Konsequenz: Als zusammenhaengender Build-Stand deployen, nicht dateiweise mischen.

## php-dependencies

Typische Pfade: `laravel_app/composer.json`, `laravel_app/composer.lock`.

Bedeutung: PHP-Abhaengigkeitsvertrag.

Konsequenz: Bei geaenderter `composer.lock` ist ein Composer-Schritt erforderlich.

## frontend-dependencies

Typische Pfade: `laravel_app/package.json`, `laravel_app/package-lock.json`.

Bedeutung: Frontend-Abhaengigkeitsvertrag.

Konsequenz: Bei geaenderter Lockdatei oder Frontendquellen ist ein lokaler Build erforderlich.

## database-migration

Typische Pfade: `laravel_app/database/migrations/**`.

Bedeutung: Datenbankschema-Aenderungen.

Konsequenz: Migrationsphase und ausdruecklicher Freigabepunkt erforderlich.

## database-seeder

Typische Pfade: `laravel_app/database/seeders/**`.

Bedeutung: Dateninitialisierung oder Referenzdatenpflege.

Konsequenz: Keine stille Ausfuehrung; statischer Review mit Hinweisen auf Models, Tabellen, Schreiboperationen und potenziell destruktive Operationen; moeglicher manueller Freigabepunkt.

## environment-contract

Typische Pfade: `laravel_app/.env.example`.

Bedeutung: Vertrag ueber erwartete Umgebungsvariablen.

Konsequenz: Neue, entfernte und unbekannte Schluessel analysieren; optionale `environmentManagement`-Regeln aus dem Manifest beruecksichtigen; `.env` nicht lesen und nicht automatisch aendern.

## protected-server-file

Typische Pfade: `laravel_app/public/.htaccess`, `.deploy-version`, `.env`, `storage/**`.

Bedeutung: Datei, die auf dem Zielsystem bewusst abweichen oder persistent sein kann.

Konsequenz: Keine automatische Ueberschreibung; Review erforderlich.

## persistent-data

Typische Pfade: `laravel_app/storage/**`, Upload- und private Datenbereiche.

Bedeutung: Persistente Laufzeitdaten des Zielsystems.

Konsequenz: Nicht hochladen und nicht loeschen.

## deletion

Typische Pfade: alle geloeschten Git-Pfade.

Bedeutung: Datei existiert im Zielstand nicht mehr.

Konsequenz: Fuer Runtime-Dateien ist ein kontrollierter Cleanup-Plan erforderlich.

## ignored

Typische Pfade: `.git/**`, `node_modules/**`, `vendor/**`, Tests, lokale Hilfsbereiche, Entwicklungsmarker.

Bedeutung: Nicht deploymentrelevante oder bewusst ausgeschlossene Inhalte.

Konsequenz: Kein Upload und keine Deployment-Entscheidung aus diesen Dateien ableiten.
