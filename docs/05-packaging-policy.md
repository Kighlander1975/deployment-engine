# Deployment Packaging Policy

## Zweck

Die Packaging Policy beschreibt verbindlich, welche Inhalte Bestandteil eines Deployment-Artefakts sind und welche ausgeschlossen werden.

Der Execution Plan beschreibt das Deployment. Die Packaging Policy beschreibt den erlaubten Inhalt des Deployment-Archivs. Das Runtime-Artefakt beschreibt das tatsaechlich erzeugte Archiv. Diese drei Verträge duerfen nicht vermischt werden.

## Pflichtfelder

Eine Packaging Policy enthaelt mindestens:

- `policyId`
- `projectId`
- `artifactType`
- `vendorStrategy`
- `includedPaths`
- `excludedPaths`
- `executionPlanFingerprint`
- `createdAt`

Das Schema liegt unter `schemas/deployment.packaging-policy.schema.json`.

## Ausschluesse

Normale Deployment-Artefakte duerfen keine persistenten Laufzeitdaten oder lokalen Arbeitsdaten enthalten.

Mindestens auszuschliessen sind:

- `storage/app/private/**`
- `storage/logs/**`
- `storage/framework/cache/**`
- `storage/framework/sessions/**`
- `storage/framework/views/**`
- `tests/**`
- `node_modules/**`
- `vendor/**`, sofern die Vendor-Strategie eine Zielinstallation aus Lockfiles vorsieht
- `deployment-runs/**`
- `.deployment/**`
- `.git/**`
- `.env` und `.env.*`
- Betriebssystemdateien wie `Thumbs.db`, `Desktop.ini`, `.DS_Store`
- IDE-Verzeichnisse wie `.idea/**` und `.vscode/**`
- temporaere Dateien und lokale Backups wie `*.tmp`, `*.bak`, `*.old`, `*.orig`, `*.swp`, `*.swo`
- verschachtelte Archive und Datenbankdumps wie `*.zip`, `*.tar`, `*.tgz`, `*.sql`, `*.dump`

## Vendor-Strategie

`vendorStrategy = exclude-install-on-target-from-lockfiles` bedeutet:

- `vendor/**` wird nicht gepackt.
- `node_modules/**` wird nicht gepackt.
- `composer.json` und `composer.lock` werden gepackt.
- `package.json` und `package-lock.json` koennen als Build-Nachweis gepackt werden.
- Frontend-Abhaengigkeiten muessen vor dem Packaging lokal gebaut sein.
- Die benoetigten Frontend-Assets muessen in `public/build/**` enthalten sein.
- PHP-Abhaengigkeiten muessen auf dem Zielsystem aus `composer.lock` installiert oder anderweitig bereitgestellt werden.

Wenn der nachfolgende Deployment-Plan keine passende Composer-/Vendor-Bereitstellung enthaelt, darf daraus keine implizite Freigabe fuer `remote.application.finalize` abgeleitet werden.

## Runtime-Artefaktbindung

`archive.create` darf kein Deployment-Archiv ohne Packaging Policy erzeugen. Das Runtime-Artefakt enthaelt:

- `executionPlanFingerprint`
- `packagingPolicyId`
- `packagingPolicyFingerprint`
- `packagingValidation`

Ein Runtime-Artefakt darf nicht mit einem anderen Execution Plan oder einer anderen Packaging Policy wiederverwendet werden.

## Runtime-Artefaktwechsel

Wenn ein bereits erzeugtes oder hochgeladenes Runtime-Artefakt durch eine korrigierte Packaging Policy fachlich ungueltig wird, bleibt es historischer Bestandteil des Laufs. Es darf nicht automatisch geloescht, ueberschrieben, entpackt oder aktiviert werden.

Der Wechsel erfolgt ueber ein Runtime-Artifact-Reconciliation-Artefakt. Dieses dokumentiert mindestens alte und neue Artefakt-ID, Grund, alte und neue Artefaktstatus, `executionPlanFingerprint`, alte und neue Packaging-Policy-Bindung, Zeitpunkt und Akteur. Nach erfolgreicher Reconciliation gilt genau ein `activeRuntimeArtifactId`; alle nachfolgenden Upload-, Validierungs-, Extract-, Composer- und Release-Schritte duerfen die alte Artefakt-ID nicht mehr referenzieren.

Die Reconciliation setzt den Lauf auf `artifact.upload / WaitingForHuman` zurueck. Der Upload-Zielpfad muss die neue Runtime-Artefakt-ID enthalten, damit ein altes Remote-Artefakt nicht ueberschrieben wird.
