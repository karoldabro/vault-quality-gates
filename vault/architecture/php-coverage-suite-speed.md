---
type: architecture
project: vault-quality-gates
slug: php-coverage-suite-speed
status: current
tags: [quality, gates, phpunit, coverage, performance, php]
---

# Run a PHP whole-suite coverage row on PCOV and capped paratest workers

A PHP repo's whole-suite row (`scope: baseline`, driver `phpunit`) collects coverage with PCOV and runs
on paratest workers capped at half the cores. Xdebug stays installed for step-debugging only. GPU
offload does not apply: PHP, PCOV and the test database run on the CPU only.

## Measured on recycling-api (8 cores, Laravel 12, PHP 8.4, Postgres through PgBouncer)

| run | driver | workers | time |
|---|---|---|---|
| `tests/Feature/Http/Controllers/FaqControllerTest.php`, no coverage | none | 1 | 68 s |
| same file | Xdebug | 1 | 190 s |
| same file | PCOV | 1 | 93 s |
| `tests/Unit`, 2,479 tests | Xdebug | 1 | 715 s |
| `tests/Unit` | PCOV | 4 | 334 s |
| whole suite, 8,938 tests | Xdebug | 1 | 3 h 45 min |
| whole suite, host load below 4 at start | PCOV | 4 | 28 min 36 s |

Line coverage moves less than 0.1 point between drivers: Xdebug measured 86.54% of 37,060
statements, PCOV 86.61% of 36,892. PCOV counts slightly fewer executable lines, so compare a new PCOV
figure against a PCOV baseline, and allow 0.5 point when switching drivers.

## Steps

| # | action | file | verification |
|---|---|---|---|
| 1 | Install the PCOV extension beside Xdebug in the image that runs PHPUnit (`php8.4-pcov` from `ppa:ondrej/php`). | the repo's PHP Dockerfile | `php -m` lists `pcov` |
| 2 | Add an ini that keeps PCOV off unless the environment turns it on: `pcov.enabled = ${PCOV_ENABLED}` and `pcov.directory = /app/app` (the covered source root). | `docker/<service>/pcov.ini`, copied into `conf.d/` | `PCOV_ENABLED=1 php -r 'echo ini_get("pcov.enabled");'` prints `1`; without the variable it prints nothing |
| 3 | Run the suite through paratest directly, not through `php artisan test --parallel`. | the whole-suite row of `quality/checks.tsv` and the repo's `test:coverage` script | the run writes clover, coverage-xml, html and junit |
| 4 | Run Infection with `XDEBUG_MODE=off`. With `--skip-initial-tests` and an existing `--coverage` folder, Infection collects no coverage, so a coverage driver only slows every mutant. | the `mutation` row and the `test:mutation` script | Infection starts and reads the merged coverage-xml and junit |

The row for a Laravel repo:

```
bin=env -- XDEBUG_MODE=off PCOV_ENABLED=1 LARAVEL_PARALLEL_TESTING=1 LARAVEL_PARALLEL_TESTING_RECREATE_DATABASES=1 php -d memory_limit=4G vendor/bin/paratest --processes=4 --runner=\Illuminate\Testing\ParallelRunner --coverage-html storage/coverage/html --coverage-clover storage/coverage/clover.xml --coverage-xml storage/coverage/coverage-xml --log-junit storage/coverage/junit.xml --coverage-text
```

A repo without Laravel drops the two `LARAVEL_PARALLEL_TESTING*` variables and the `--runner` option.

## Constraints

- **Cap the workers at half the cores** with `--processes=N`. paratest defaults to one worker per core,
  and the gate's runner container carries no `cpus:` limit. Keep the `nice -n 15` prefix.
- **Give each worker its own database.** Laravel's `ParallelRunner` creates `<db>_test_<N>` per worker
  when `LARAVEL_PARALLEL_TESTING=1` is set. A PgBouncer in front needs a `* = host=...` wildcard entry
  so those databases route.
- **Write shared logs with `FILE_APPEND | LOCK_EX`.** Four workers append to the same file at once.
- **Keep `XDEBUG_MODE=off` beside `PCOV_ENABLED=1`.** PHPUnit prefers PCOV when it is enabled, but
  Xdebug in coverage mode still instruments every call.

## Failure modes

- **`php -d memory_limit=… artisan test --parallel` leaves the merge at the ini default.** Artisan starts
  paratest as a new PHP process without the `-d` flag. The parent then dies merging the workers'
  coverage (`Allowed memory size … exhausted … CoverageMerger.php`), and no report is written. Call
  `vendor/bin/paratest` with the memory flag on its own command line.
- **A root-owned `/tmp/phpstan-tests` fails every PHPStan rule test** with `Unable to create file
  '/tmp/phpstan-tests/cache/…lock'`. It appears after a manual `docker compose exec` run as root in a
  long-lived container. Run as the app uid, or `chown` the folder. The gate's runner starts a fresh
  container and does not hit it.
- **`read -ra` keeps the backslashes in `--runner=\Illuminate\…` in a `checks.tsv` row.** In
  `composer.json` the same option needs single quotes and JSON-escaped backslashes:
  `'--runner=\\Illuminate\\Testing\\ParallelRunner'`.

## Rollback

Restore the Xdebug row: `bin=env -- XDEBUG_MODE=coverage vendor/bin/phpunit -d memory_limit=2G <same
report flags>`. The PCOV extension can stay installed, because it stays off without `PCOV_ENABLED=1`.
