# Composer Install Contract

## Scope

This document defines the `remote.composer.install` contract for the exploratory Laravel deployment flow.

The contract completes planning only. It does not authorize or execute `composer install`.

`remote.composer.install` is a separate Remote Execution step after a successful `remote.composer.preflight`. It must never be merged into `remote.composer.preflight`, `remote.archive.extract`, `remote.release.activate`, or any finalization step.

## Write Boundary

Every deployment step has an explicit Write Boundary. The contract defines not only what the step does, but also which paths and resources it may modify. Changes outside that Write Boundary are forbidden and must abort the step.

Every writing deployment step must document its actual write paths in the execution result. For `remote.composer.install`, the result must emit `WriteBoundarySatisfied=true`, `WrittenPathCount`, and one `WrittenPath=<relative-path>` line for each detected changed, created, or updated path.

For `remote.composer.install` the write boundary is:

| Field | Value |
| --- | --- |
| Boundary root | `remote.releaseDirectory` |
| Allowed paths | `vendor`, `vendor/**`, `bootstrap/cache`, `bootstrap/cache/packages.php`, `bootstrap/cache/services.php` |
| Forbidden paths | `.env`, `.env.*`, `storage/**`, `public/**`, `.deployment/**`, `../**` |
| Forbidden resources | shared storage, live release, deployment metadata, file permissions |

`composer.json` and `composer.lock` may be read but must not be changed. Other files below `bootstrap/cache` remain forbidden unless they are explicitly added to this contract.

## Install Strategy

| Contract Field | Value |
| --- | --- |
| ComposerCommand | `composer install` |
| WorkingDirectory | `remote.releaseDirectory` |
| NetworkAccessPolicy | Allowed only for Composer package metadata and dist archive downloads needed by `composer.lock`; no generic network commands |
| AllowedFlags | `--no-dev`, `--prefer-dist`, `--optimize-autoloader`, `--no-interaction` |
| ForbiddenFlags | `--ignore-platform-reqs`, `--ignore-platform-req`, `--dev`, `--working-dir`, `--global`, arbitrary additional flags |
| ScriptExecutionPolicy | Only reviewed install-lifecycle scripts are allowed; for this project that is `post-autoload-dump` only |
| PluginExecutionPolicy | Only lockfile-present and reviewed Composer plugins may execute |
| ExpectedVendorState | `vendor` exists, dev packages absent, contents derived from `composer.lock` |
| ExpectedAutoloadState | `vendor/autoload.php` exists; optimized autoloader generated |
| FailureHandling | Stop, no retry, preserve release directory for diagnostics |
| RollbackBehaviour | No live state is changed by this step; rollback is not triggered |
| PostValidation | Validate vendor, autoload, exit code, write boundary, scripts, plugins |

## Composer Script Review

Source: `projects/shk-momm-kundendaten/laravel_app/composer.json`.

| ScriptName | DefinedCommand | ExecutionPhase | SideEffects | WritesFiles | ExecutesPhp | ExecutesArtisan | TouchesStorage | TouchesPublic | RunsMigrations | RunsCaches | RequiresNetwork | AllowedByPolicy | Reason |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `setup` | `composer install`; `@php -r "file_exists('.env') || copy('.env.example', '.env');"`; `@php artisan key:generate`; `@php artisan migrate --force`; `npm install --ignore-scripts`; `npm run build` | Manual root script, not Composer install lifecycle | Installs PHP and npm dependencies, creates `.env`, generates key, runs migrations, builds frontend | true | true | true | false | true | true | true | true | false | Setup writes outside the install Write Boundary and performs migrations/builds. |
| `dev` | `Composer\Config::disableProcessTimeout`; `npx concurrently ... "php artisan serve" "php artisan queue:listen --tries=1 --timeout=0" "php artisan pail --timeout=0" "npm run dev" ...` | Manual development script | Starts long-running development server, queue listener, log tail and Vite dev server | false | true | true | false | false | false | false | true | false | Development runtime processes are outside deployment install scope. |
| `test` | `@php artisan config:clear --ansi @no_additional_args`; `@php artisan test` | Manual test script | Clears config cache and runs tests | true | true | true | false | false | false | true | false | false | Test execution and cache clearing are outside deployment install scope. |
| `post-autoload-dump` | `Illuminate\Foundation\ComposerScripts::postAutoloadDump`; `@php artisan package:discover --ansi` | Composer install/update lifecycle after autoload generation | Runs Laravel package discovery after Composer autoload generation | true | true | true | false | false | false | true | false | true | This is the only reviewed install-lifecycle script; allowed writes are limited to Laravel package discovery files under `bootstrap/cache`. |
| `post-update-cmd` | `@php artisan vendor:publish --tag=laravel-assets --ansi --force` | Composer update lifecycle, not install lifecycle | Publishes Laravel assets with force | true | true | true | false | true | false | false | false | false | Update-only asset publishing may touch public assets and is outside install scope. |
| `post-root-package-install` | `@php -r "file_exists('.env') || copy('.env.example', '.env');"` | Create-project/root install lifecycle | Creates `.env` if missing | true | true | false | false | false | false | false | false | false | `.env` writes are forbidden. |
| `post-create-project-cmd` | `@php artisan key:generate --ansi`; `@php -r "file_exists('database/database.sqlite') || touch('database/database.sqlite');"`; `@php artisan migrate --graceful --ansi` | Create-project lifecycle | Generates key, creates SQLite file, runs migrations | true | true | true | false | false | true | false | false | false | Creates local database state and runs migrations; forbidden for deployment install. |
| `pre-package-uninstall` | `Illuminate\Foundation\ComposerScripts::prePackageUninstall` | Package uninstall lifecycle | Laravel package uninstall hook | false | true | false | false | false | false | false | false | false | Uninstall lifecycle is outside deployment install scope. |

## Composer Plugin Review

Source: `composer.json` `config.allow-plugins` and `composer.lock`.

No package with `type = composer-plugin` was found in the current `composer.lock`. The following plugin allowances are configured in `composer.json`, but the packages are not present in the lockfile and therefore must not be treated as active plugins for this deployment install.

| Package | Version | ActivationMechanism | Purpose | WritesFiles | NetworkAccess | AllowedByPolicy | Reason |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `pestphp/pest-plugin` | Not present in `composer.lock` | Listed in `config.allow-plugins`, but no locked package is installed | Pest test framework Composer plugin when present | false | false | false | Not present in lockfile and test tooling is not runtime deployment scope. |
| `php-http/discovery` | Not present in `composer.lock` | Listed in `config.allow-plugins`, but no locked package is installed | HTTP discovery plugin when present | false | false | false | Not present in lockfile; no activation is allowed without a locked package and explicit review. |

## Post-Validation Contract

After a future approved `remote.composer.install`, the result must report at least:

| Field | Required Result |
| --- | --- |
| `VendorPresent` | `true` |
| `AutoloadPresent` | `true` |
| `ComposerExitCode` | `0` |
| `FilesChangedOnlyInsideRelease` | `true` |
| `UnexpectedFileChanges` | `false` |
| `UnexpectedDirectories` | `false` |
| `WriteBoundarySatisfied` | `true` |
| `WrittenPathCount` / `WrittenPath` | Actual changed, created, or updated paths |
| `ScriptExecutionEvidence` | `observed` only when the Composer output contains the reviewed script class and reviewed Composer command; otherwise `not-observed` |
| `ObservedComposerScripts` | `Illuminate\Foundation\ComposerScripts::postAutoloadDump` when observed |
| `ObservedComposerCommands` | `@php artisan package:discover --ansi` when observed |
| `PluginsExecuted` | `false` unless a lockfile-present plugin was explicitly reviewed |

If any post-validation field violates the contract, the step fails. It must not clean up, retry, activate the release, change shared storage, change permissions, or run Artisan cache/migration commands as a repair.

## Read-only Reconciliation

`remote.composer.install.validate` is a separate read-only validation step for an already completed Composer install. It validates existing `vendor`, `vendor/autoload.php`, Composer file immutability evidence, the corrected Write Boundary, observed Composer script evidence, and outside-boundary evidence without running Composer again.

The validation step must report `ComposerInstallPreviouslyCompleted=true`, `ComposerReexecuted=false`, `DoesExecutionPlanFingerprintChange=false`, `DoesRuntimeArtifactChange=false`, and whether the Composer Strategy fingerprint changed. Because the corrected Write Boundary and Evidence rules are part of the Composer Strategy contract, this correction changes the Composer Strategy fingerprint. The original Composer process output remains historical evidence and is not rebound; only the validation decision is bound to the corrected validation contract.
