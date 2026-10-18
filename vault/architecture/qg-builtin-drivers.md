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

**Rows that share one tool run:** `phpinsights` and `composer-dependency-analyser` keep their report in
`QG_RUN_DIR` for the rest of the run, keyed by the target, the tree and the args without `metric=`. Four
insights rows that differ only in `metric=` run PHP Insights once.

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
| `jscpd-added` | `version=`, `min-lines=`, `min-tokens=`, `format=`, `ignore=<glob>` | — | `version=5.3.2`, `paths=app` |
| `cloc` | `metric=comment-ratio\|code\|comment` | — | `bin=cloc`, `paths=.` |

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
| `jscpd-added` | `.jscpd.json` |
| `cloc` | none |

A runner the row names is committed and read from the config revision; protect it too.
