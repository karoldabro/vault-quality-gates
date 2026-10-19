---
type: architecture
project: vault-quality-gates
slug: qg-dart-drivers
status: current
tags: [quality, gates, drivers, dart, flutter]
---

# Dart and Flutter drivers: what each one runs, reads and counts

Each driver below lives in `drivers/`, follows `vault/architecture/qg-driver-contract.md` and sources
`lib/qg-driver-kit.sh`. Every one but `dart-lock` declares `needs_tree: true`. The shared keys `files=changed`,
`paths=`, `include=`, `exclude=` and `lines=added` mean what `vault/architecture/qg-builtin-drivers.md`
says, unless a section below states otherwise.

## What the Dart-tool drivers share: `lib/qg-dart.sh`

`dart-analyze`, `dart-format`, `dart-code-linter`, `layerlens`, `lakos`, `flutter-test` and
`mutation-test` source `lib/qg-dart.sh`. `copydetect`, `grep-count`, `checkstyle` and `dart-lock` run no
Dart tool and do not source it.

| step | function | what it does | `status: error` when |
|---|---|---|---|
| read the SDK path | `qg_dart_config_key guard_flutter_root` | calls the kit's `qg_kit_config_key`, which reads the key through `lib/qg-config.sh` at `QG_CONFIG_REV`; an empty `QG_CONFIG_REV` is a first commit and reads the index | the key is absent or empty |
| refuse a runner | `qg_dart_env` | a Dart row runs the pinned SDK itself | the row sets `runner=` |
| pin the SDK | `qg_dart_env` | sets `QG_FLUTTER=<root>/bin/flutter` and `QG_DART=<root>/bin/cache/dart-sdk/bin/dart`; every tool runs by that absolute path | either file is missing or not executable |
| check `PATH` | `qg_dart_env` | resolves `command -v flutter` with `readlink -f`; no `flutter` on `PATH` is allowed | `flutter` on `PATH` is another file |
| drop the caller's environment | `qg_dart_env` | unsets `PUB_CACHE`, `XDG_CACHE_HOME` and `FLUTTER_ROOT`, then exports `FLUTTER_ROOT=<root>` | — |
| refuse repo-chosen packages | `qg_dart_packages` | checks `QG_TREE/pubspec_overrides.yaml`, and `.dart_tool` with `git ls-files` (`:index`) or `git ls-tree` (`QG_TARGET`) | the overrides file exists, or any `.dart_tool` path is tracked |
| resolve packages | `qg_dart_packages` | runs `dart pub get --offline --enforce-lockfile` inside `QG_TREE`, so a `pubspec.yaml` `dependency_overrides` entry the lock does not record is refused | resolution fails; the error carries its last 5 lines and the fix |
| isolate commit code | `qg_isolated <dir>` | runs the tool in its own session with only `HOME`, `PATH`, `LANG`, `FLUTTER_ROOT` and `TMPDIR=<dir>`, then kills its process group; a process that starts its own session is not reached | — |

`qg_dart_prepare <driver> <unit>` runs `qg_dart_env`, then `qg_dart_packages`, and writes the error.
Every driver in the list above runs both. `flutter-test` and `mutation-test` run the suite through
`qg_isolated`.

**Constraint: `qg baseline` never measures the caller's checkout with these drivers.** In a repo that
measures commits (no `guard_measure_worktree: false`), `bin/guard.sh baseline` measures a detached
worktree of `HEAD` whenever a selected row's driver needs a tree.

**Failure mode:** a pushed `pubspec.lock` that names a package missing from the pub cache makes every
Dart row `status: error`. Run `flutter pub get` in the checkout, then push again.

**Constraint: `guard_flutter_root` comes from the config revision.** An edit to the working-tree
`quality/config` changes nothing until a human commits it under `qg override`.

## Drivers

| driver | measured exits | `metric` | unit |
|---|---|---|---|
| `dart-analyze` | 0, 1, 2, 3 | diagnostics at or above `severity=`, kept by `code=`; under `lines=added`, those on added lines | findings |
| `dart-format` | 0, and 1 with at least one `Changed <path>` line | `Changed` lines; the summary line is never counted | files |
| `dart-code-linter` | 0, 1 with the report written this run | `<id>><N>`: entries of `.functions` (`.classes` for `number-of-methods`) whose metric `<id>` is over N; `issue:<rule>`: issues of that rule | findings |
| `layerlens` | 0 with at least one `DEPS.md` written under `paths=` | `--!--` lines in those `DEPS.md` files | edges |
| `lakos` | 0, 5 with a numeric `.metrics.<metric>` | `.metrics.<metric>` | ratio |
| `flutter-test` | 0, 1; a `done` event and one `testDone` neither hidden nor skipped; exit 1 needs a failure | `failed`: tests with a `testDone` result `failure` or `error`, or an `error` event; `coverage`: kept LH over kept LF times 100, two decimals | tests, percent |
| `mutation-test` | 0, 255 with an `Undetected Mutations: <n> (<p>%)` line and `Total tests:` over 0 | 100 minus `<p>`, two decimals | percent |
| `copydetect` | python exit 0 | pairs with both similarities at or over `min-similarity` and at least `min-tokens` tokens | pairs |
| `grep-count` | grep 0, 1; awk 0 | files with a match, matching lines, or lines the awk script prints, after `exclude=` | files, lines |
| `checkstyle` | runner 0 with a well-formed `report=` | `<error>` elements; under `lines=added`, those on added lines | findings |
| `dart-lock` | no tool runs | the highest count over `QG_BASES` of the changes listed under `dart-lock` below | packages |

Any other exit, a missing report, or a report without the field the metric needs writes
`status: error`. A driver with `files=changed` that matches no file writes `metric: 0` and runs
nothing. The findings list holds at most 200 entries, 50 for `flutter-test`; `metric` counts all.

## Keys per driver

| driver | keys beyond the shared ones | required | default |
|---|---|---|---|
| `dart-analyze` | `code=<code,code>`, `severity=info\|warning\|error`, `options-allow=<repo path,repo path>` | — | `paths=.`, `severity=info` |
| `dart-format` | `files=changed`, `include=`, `exclude=`, `-- <argv>` | `files=changed` | — |
| `dart-code-linter` | `metric=<metricsId>><N>\|issue:<ruleId>`, `paths=`, `ignore=<glob>` | `metric` | `paths=lib` |
| `layerlens` | `package=<name>`, `only=<glob>`, `paths=`, `version=<x.y.z>` | `package` | `only=lib/**`, `paths=lib`, `version=3.1.0` |
| `lakos` | `metric=nccd\|ccd\|acd`, `paths=<one folder>`, `ignore=<glob>` | — | `metric=nccd`, `paths=lib` |
| `flutter-test` | `metric=failed\|coverage`, `concurrency=<n>`, `include=`, `exclude=` | `metric` | the tool's own concurrency |
| `mutation-test` | `rules=<repo path>`, `builtin=yes`, `paths=` | `rules` | `paths=lib` |
| `copydetect` | `requirements=<repo path>`, `venv-root=<name>`, `paths=`, `ext=`, `exclude=`, `min-similarity=`, `min-tokens=`, `noise=`, `guarantee=` | `requirements` | `venv-root=qg-tools`, `paths=lib`, `ext=dart`, `exclude=\.(g\|freezed\|mocks\|config)\.dart$\|/generated/`, `min-similarity=0.8`, `min-tokens=600`, `noise=25`, `guarantee=25` |
| `grep-count` | `paths=`, `count=files\|lines`, `name=<glob>`, `exclude=`, `awk=<repo path>`, `-- <ERE>` | `paths`; the pattern unless `awk=` is set | `count=files` |
| `checkstyle` | `runner=<repo path>`, `report=<tree path>`, `lines=added` | `runner`, `report` | — |
| `dart-lock` | `packages=<name,name>`, `lock=<repo path>` | `packages` | `lock=pubspec.lock` |

**`dart-analyze` nested options:** the driver lists every `analysis_options.yaml` in the tree except
the root one, skipping `.dart_tool`, `build` and `.git`. Each one missing from `options-allow=` is
`status: error`, because it would apply looser rules to its folder. Name it tree-relative, such as
`tool/givore_lints/analysis_options.yaml`.

**`dart-analyze` `code=`:** codes compare lower-cased, and each finding's `ruleId` is the lower-cased code.

**`dart-code-linter` shares one run:** rows whose args differ only in `metric=` read one report from
`QG_RUN_DIR`. The tool writes `quality-reports/dcl.json` inside the tree, and the driver drops its stdout.

**`layerlens` is a global install:** the driver compares `version=` with `dart pub global list` and is
`status: error` on a mismatch. It deletes every `DEPS.md` under `paths=` before the run.

**`flutter-test` runs once per run and target:** both rows read one shared summary from `QG_RUN_DIR`.
The command is `<root>/bin/flutter test --no-pub --coverage --coverage-path <dir>/lcov.info --machine`.
A `concurrency=<n>` key adds `--concurrency=<n>`. `<dir>` is a `mktemp -d` folder of mode 0700 outside
`QG_TREE`, deleted after the parse. The parser reads only lines that start with `{`. Coverage counts
only the libraries some test loads, as the v1 row did: a new file no test imports leaves it unchanged.

**`flutter-test` coverage filter:** `include=` and `exclude=` match each `SF:` path after the driver
strips the `QG_TREE/` prefix and a leading `./`. No `lcov.info`, or LF 0 after the filter, is `status: error`.

**`copydetect` interpreter:** the driver runs
`$HOME/.cache/<venv-root>/copydetect-<first 12 hex of sha256(requirements)>/bin/python -I` with
`XDG_CACHE_HOME` unset. The requirements file is read at `QG_CONFIG_REV`. It never takes python from `PATH`. A `venv-root` other than one plain folder
name is `status: error`.

**`dart-lock` counts, per base:** it reads the lock and the `pubspec.yaml` beside it from git at
`QG_TARGET` (the index under commit), never from the tree, which an earlier row's `pub get` may rewrite.

| change in the measured lock against `git show <base>:<lock>` | counts |
|---|---|
| a named package's version, source, url, git ref or path differs | 1 |
| a named package is added or removed | 1 |
| an unnamed package becomes a `path` or `git` package it was not at the base | 1 |
| the `dependency_overrides:` section of `pubspec.yaml` differs | 1 |
| an unnamed hosted package changes version | 0 |

A lock missing at a base or the target, a lock line in any form but pub's block form, or an empty
`QG_BASES`, is `status: error`. Name every tool
package in `packages=`, and every package an `include:` in `analysis_options.yaml` loads. A hosted
transitive bump of an unnamed package is not seen; `pubspec.lock` holds no dependency graph.

## Row order: suite rows last

**Constraint: put every `flutter-test` and `mutation-test` row after every other push and baseline
row in `quality/checks.tsv`.** `guard_run` runs rows in file order, and these two drivers run code the
commit wrote. That code can write into `QG_RUN_DIR` or the tree and change what a later row reads.

**Failure mode left open:** the suite runs as the operator's user. While it runs it can forge its own
`flutter-test` and `mutation-test` values, and it can write files later runs reuse: the pub cache, the
Flutter SDK, `<git-common-dir>/guard-cache` (a commit-lint runner and its checksum). That plants code
every later commit and push gate runs. Only an OS sandbox closes it; `bwrap` needs unprivileged user
namespaces, which this host refuses. Owner: S6.

## `checkstyle`: a runner that is the tool

`runner=` names a committed script; the engine copies it from the config revision into `$QG_RUNNER`.
The driver calls `$QG_RUNNER <tree> <cache>` with stdin from `/dev/null`. It passes no `bin` and no argv.
The runner reads the changed paths from `$QG_FILES` and writes `report=` inside the tree.

| case | result |
|---|---|
| `bin=` or `-- <argv>` in the row | `status: error` |
| `report=` is tracked in the index (`:index`) or at `QG_TARGET` | `status: error` |
| the runner exits non-zero | `status: error` |
| `report=` is missing, empty or not well-formed XML | `status: error` |

**The driver never deletes `report=`.** The runner owns it: it may reuse a report an earlier row of
the same commit wrote, and it deletes both reports when it fails.

## `grep-count`: paths and `exclude=`

- Each `paths=` entry must exist and be non-empty in the tree. The driver strips a leading `./` and a
  trailing `/`, so `./lib`, `lib/` and `lib` give one count.
- `exclude=` matches the path relative to `QG_TREE` with any leading `./` removed, such as
  `lib/generated/a.dart`.
- `exclude=` applies in every mode: `count=files`, `count=lines` and `awk=`.
- Convert a v1 post-filter `grep -vE "<re>:"` on `grep -n` output to `exclude=<re>$`. The v1 filter
  matched `path:line:`; the driver matches the path alone.
- The pattern is the argv after ` -- `, taken whole, spaces included.
- `awk=` runs `find <paths> -type f [-name <glob>]`, then `xargs -0 -r awk -f <file>`. The script is
  read at `QG_CONFIG_REV`, never from the tree. With no file left, awk never runs and the count is 0.

**Constraint: a TSV args cell holds `|`, never `\|`.** A `\|` in a markdown table on this page is table
escaping. Copied into an ERE, `\|` matches a literal pipe and changes the count.

## Config files each driver loads

A commit can loosen a gate by editing a config the tool reads. List each file below that a repo uses
in `guard_protected_paths` (`vault/architecture/guard-commit-gate.md`).

| driver | files it reads |
|---|---|
| `dart-analyze` | `analysis_options.yaml`, each `options-allow=` file |
| `dart-format` | `analysis_options.yaml` (its `formatter:` section) |
| `dart-code-linter` | `analysis_options.yaml` (its `dart_code_linter:` section) |
| `layerlens` | none in the tree |
| `lakos` | none |
| `flutter-test` | `dart_test.yaml`, `test/flutter_test_config.dart` |
| `mutation-test` | the `rules=` file, `dart_test.yaml`, `test/flutter_test_config.dart` |
| `copydetect` | the `requirements=` file |
| `grep-count` | the `awk=` file |
| `checkstyle` | the `runner=` file and every file the runner reads |
| `dart-lock` | none |

Every driver that resolves packages also depends on `pubspec_overrides.yaml` and `.dart_tool`; protect
both. `quality/config` holds `guard_flutter_root`. A `dart-lock` row guards `pubspec.lock`.
