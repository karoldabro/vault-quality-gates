---
type: architecture
project: vault-quality-gates
slug: qg-builtin-drivers
status: current
tags: [quality, gates, drivers]
---

# Built-in drivers: what each one runs, reads and counts

Each built-in driver in `drivers/` wraps one tool and follows `vault/architecture/qg-driver-contract.md`.
This page lists the `args` keys each one reads, the tool exit codes it treats as measured, and the
number it writes as `metric`. A row names a driver in its `driver` cell and its keys in its `args` cell.

Every built-in sources `lib/qg-driver-kit.sh`. Every one declares `needs_tree: true`, so the commit gate
measures a copy of the staged tree and never the working tree.

Built-in drivers are catalogued per ecosystem, one page each. The Dart and Flutter drivers are in
`vault/architecture/qg-dart-drivers.md`. Helpers for one language live in `lib/qg-<lang>.sh`, such as
`lib/qg-dart.sh`.

## Keys every built-in reads the same way

| key | meaning |
|---|---|
| `runner=<repo path>` | run the tool through this committed runner, as `<runner> <tree> <cache> <bin> <argv>` |
| `bin=<path>` | the tool's executable, relative to the measured tree; each driver states its default |
| `files=changed` | measure only the changed files the driver handles; when none match, write `metric: 0` and run nothing |
| `paths=<dir,dir>` | the directories the tool scans, comma-separated, relative to the measured tree |
| `include=<ERE>`, `exclude=<ERE>` | keep only changed files, or added lines, whose path matches `include` and misses `exclude` |
| `lines=added` | count only findings on lines the commit adds; a finding with no line is printed and never counted |
| `-- <argv>` | extra arguments handed to the tool after the driver's own |

**Why `files=changed` and `paths=` are two keys:** a single `paths=changed` key would give one key two
meanings, a sentinel and a directory list, and a row could not scan two folders for changed files only.

**Constraint: a finding path must lie in the measured tree.** The kit maps `/app/<path>`,
`<QG_TREE>/<path>` and `./<path>` to `<path>`. Under `lines=added`, a finding whose path stays absolute
makes the row `status: error`, because it could never match an added line and would count 0.

**Constraint: a report left by an earlier run is never read.** `qg_tool` deletes a report file before
the tool runs; a tool that then writes none is `status: error`.

**Rows that share one tool run:** `phpinsights`, `composer-dependency-analyser`, `jscpd` and `eslint`
without `files=changed` keep their report in `QG_RUN_DIR` for the rest of the run. The key is the
target, the tree and the args without `metric=`, and for `eslint` also without `rules=`. Four insights
rows that differ only in `metric=` run PHP Insights once.

**A tool that reads a config file gets it explicitly** from a `config=` key with the repo's usual file as
default, so a committed or untracked sibling config never shadows the protected one.

**pnpm on the host:** `jscpd` and `jscpd-added` without `bin=` run `pnpm dlx jscpd@<version>` through
`qg_pnpm_prepare` in `lib/qg-driver-kit.sh`. It runs from an empty folder under `env -i`, keeping only
`PATH` and `LANG`, with an empty user and global rc and the public registry. No `.npmrc`, XDG config or
`npm_config_*`/`pnpm_config_*` variable of the caller or the commit reaches it. Its store and dlx cache
live under `<git-common-dir>/guard-cache/pnpm`, so a second run needs no network.

## Drivers

| driver | measured exits | `metric` | unit | equals v1 parser |
|---|---|---|---|---|
| `phpstan` | 0, 1 with a JSON report | `totals.errors + totals.file_errors`; under `lines=added`, errors on added lines | findings | `phpstan-all` |
| `pint` | 0, 1 with a JSON report | files Pint would change | files | `exitcode` on one failing file only |
| `phpcs` | 0, 1, 2 with a JSON report | errors plus warnings; under `lines=added`, those on added lines | findings | `guard-added-lines.sh --checkstyle` |
| `phpmd` | 0, 2 with a JSON report and empty `errors[]` | violations | findings | `phpmd` |
| `phpinsights` | 0, 1 with a JSON report | `summary.<metric>` | score | `insights` |
| `composer-dependency-analyser` | 0, 1 with a `Found` or `No composer issues found` line | packages under `Found <n> <metric>` | packages | `cda` |
| `phpunit` | 0, 1, 2 with the report | `failed`: failures plus errors of the first `<testsuite>`; `coverage`: covered over total statements, two decimals | tests, percent | `junit`, `clover` |
| `infection` | 0, 1 with the summary | `.stats.msi`, else `.msi` | percent | `infection` |
| `jscpd-added` | 0 with a report | clone sides in changed files that cover an added line, each once | clones | recycling-api `jscpd-added.sh` with `--checkstyle` |
| `cloc` | 0 | `comment-ratio`: comment over code lines, three places; or `code`, `comment` | ratio, lines | `cloc` |
| `eslint` | 0, 1 with a report | `errors` severity 2, `problems` every message, `rules` messages of the listed rules; under `lines=added`, those on added lines; a whole-repo run linting no file is an error | findings | app `quality-metric.mjs lint`, `mess`; `commit-check.sh`, `tree-report.sh`, `metric.sh` lint |
| `nuxt-typecheck` | 0; 1, 2 with at least one `error TS` | occurrences of `error TS<code>` over stdout and stderr; under `lines=added`, those on added lines | findings | app `quality-metric.mjs typecheck`, `commit-check.sh typecheck`; dashboard `metric.sh`, `tree-report.sh` |
| `knip` | 0, 1 with a JSON line | entries in every issue array but `file` | findings | app `quality-metric.mjs deadcode` |
| `depcruise` | any, with a JSON `summary`; nothing cruised is an error | `summary.violations` | findings | app `quality-metric.mjs architecture` |
| `fallow` | 0, 1 with JSON | `dupes`: `stats.duplicated_lines`; `boundaries`: `boundary_violations`; `complexity-excess`: sum of excess over both limits | lines, findings, points | app `scripts/fallow-parsers.mjs` |
| `vitest` | 0, 1 with the report | `failed`: failures plus errors of the `<testsuites>` root, plus 1 on a non-zero exit with none; `coverage`: covered over total statements, two decimals | tests, percent | app `quality-metric.mjs tests-failing`; `exitcode` where `failed` is 0 or 1; `clover` |
| `stryker` | any, with a fresh report | (Killed + Timeout) / (all − Ignored − CompileError) × 100, two decimals | percent | app `quality-metric.mjs mutation` |
| `jscpd` | 0 with a report | `percentage`: `statistics.total.percentage`, two decimals; `clones`: `statistics.total.clones` | percent, clones | `jscpd` |

Any other exit code, a missing report, or a report without the field the metric needs writes
`status: error`, and the engine makes the row unmeasurable.

## Keys per driver

| driver | keys beyond the shared ones | required | default |
|---|---|---|---|
| `phpstan` | — | — | `bin=vendor/bin/phpstan` |
| `pint` | — | — | `bin=vendor/bin/pint` |
| `phpcs` | `standard=<repo path>` | — | `bin=vendor/bin/phpcs` |
| `phpmd` | `ruleset=<repo path>`, `baseline=<repo path>`, `phpini=<directive=value>` | `ruleset`, and `files=changed` or `paths` | `bin=vendor/bin/phpmd` |
| `phpinsights` | `metric=code\|complexity\|architecture\|style`, `config=<repo path>` | — | `metric=code`, `paths=app` |
| `composer-dependency-analyser` | `metric=shadow\|unused\|dev-in-prod\|prod-only-in-dev`, `config=<repo path>` | — | `metric=shadow` |
| `phpunit` | `metric=failed\|coverage`, `junit=`, `clover=`, `run=no`, `reset=<path,path>` | `metric` | `junit=storage/coverage/junit.xml`, `clover=storage/coverage/clover.xml` |
| `infection` | `summary=<tree path>`, `log=<tree path>`, `run=no` | `summary` | `bin=vendor/bin/infection` |
| `jscpd-added` | `version=`, `bin=`, `config=`, `min-lines=`, `min-tokens=`, `format=`, `ignore=<glob>` | — | `version=5.3.2`, `paths=app` |
| `cloc` | `metric=comment-ratio\|code\|comment` | — | `bin=cloc`, `paths=.` |
| `eslint` | `metric=errors\|problems\|rules`, `rules=<id,id>`, `config=` | `rules=` with `metric=rules` | `metric=errors`, `config=eslint.config.mjs`, `paths=.`, `bin=node_modules/.bin/eslint` |
| `nuxt-typecheck` | — | — | `bin=node_modules/.bin/nuxt` with argv `typecheck`, which any `--` argv replaces |
| `knip` | `config=` | — | `config=knip.json`, `bin=node_modules/.bin/knip` |
| `depcruise` | `config=` | — | `config=.dependency-cruiser.cjs`, `paths=.`, `bin=node_modules/.bin/depcruise` |
| `fallow` | `metric=dupes\|boundaries\|complexity-excess`, `max-cyclomatic=`, `max-cognitive=`, `config=` | `metric`; both limits with `complexity-excess` | `config=.fallowrc.json`, `bin=node_modules/.bin/fallow` |
| `vitest` | `metric=failed\|coverage`, `junit=`, `clover=`, `config=`, `run=no` | `metric` | `junit=quality-reports/junit.xml`, `clover=coverage/clover.xml`, `config=vitest.config.ts`, `bin=node_modules/.bin/vitest` |
| `stryker` | `report=`, `config=`, `run=no` | — | `report=reports/mutation/mutation.json`, `config=stryker.config.json`, `bin=node_modules/.bin/stryker` |
| `jscpd` | `metric=percentage\|clones`, `version=`, `bin=`, `config=`, `min-lines=`, `min-tokens=`, `format=`, `ignore=` | — | `metric=percentage`, `version=5.3.2`, `paths=.` |

The web drivers run through a runner that supplies `node_modules`, such as `quality/bin/in-node.sh` in
app.givore.com and dashboard.givore.com; a staged tree has none of its own.

**`run=no`:** the driver reads the report a previous run left and runs nothing. Use it for a row that
reads a whole-suite report a `baseline` row wrote. Any process can write that report, so such a row
trusts its writer.

**`reset=`:** `phpunit` empties each listed file before the run, such as a log the suite appends to.

**Setting an environment variable inside a runner:** write `bin=env` and put the assignment first in
the argv, as `bin=env -- XDEBUG_MODE=coverage vendor/bin/phpunit --log-junit ...`.

## Config files each driver loads

A commit can loosen a gate by editing a config the tool reads. List each file below that a repo uses
in `guard_protected_paths` (`vault/architecture/guard-commit-gate.md`).

| driver | files it reads |
|---|---|
| `phpstan` | `phpstan.neon`, `phpstan.neon.dist`, any `-c` file, the baseline it includes |
| `pint` | `pint.json` |
| `phpcs` | the `standard=` file, `phpcs.xml`, `phpcs.xml.dist` |
| `phpmd` | the `ruleset=` and `baseline=` files |
| `phpinsights` | the `config=` file, `phpinsights.php` |
| `composer-dependency-analyser` | the `config=` file, `composer-dependency-analyser.php`, `composer.json` |
| `phpunit` | `phpunit.xml`, `phpunit.xml.dist` |
| `infection` | `infection.json5`, `infection.json`, `infection.json.dist` |
| `jscpd-added`, `jscpd` | the `config=` file; `.gitignore` files unless it sets `"gitignore": false` |
| `cloc` | none |
| `eslint` | the `config=` file and every module it imports, such as `.nuxt/eslint.config.mjs` and local rule folders |
| `nuxt-typecheck` | `tsconfig.json`, `.nuxt/tsconfig.*.json`; `nuxt typecheck` also loads `nuxt.config.ts` |
| `knip` | the `config=` file |
| `depcruise` | the `config=` file and any file it requires |
| `fallow` | the `config=` file |
| `vitest` | the `config=` file |
| `stryker` | the `config=` file |

A runner the row names is committed and read from the config revision; protect it too.
