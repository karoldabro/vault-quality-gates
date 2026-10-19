---
type: plan
project: vault-quality-gates
slug: 2026-10-19-0930-qg-s4-flutter-drivers
repos: [vault-quality-gates, recycling_mobile_app]
status: proposed
process_record: 2026-10-19-0930-qg-s4-flutter-drivers.trail.md
arch_spec:
human_plan:
session_of: /home/kdabrow/workspace/vault-quality-gates/vault/plans/2026-10-18-1121-qg-common-interface.md#S4
session:
tags: [plan, quality-gate, drivers, flutter, migration]
---

# Flutter drivers and the recycling_mobile_app v2 migration — plan

## Task

Give the gate eleven built-in drivers for Dart and Flutter tools and a shared Dart helper library.
Prepare recycling_mobile_app's 66 gate rows in the v2 format with a row-parity proof. All code lands
in worktree `~/workspace/vault-quality-gates-s4`, branch `feat/qg-flutter-drivers`, cut from `main`
`5678529`. Mobile files are prepared under `migrations/recycling_mobile_app/`; the operator copies
them and commits.

Keywords: `drivers/dart-analyze.sh`, `drivers/dart-format.sh`, `drivers/dart-code-linter.sh`,
`drivers/layerlens.sh`, `drivers/lakos.sh`, `drivers/flutter-test.sh`, `drivers/mutation-test.sh`,
`drivers/copydetect.sh`, `drivers/grep-count.sh`, `drivers/checkstyle.sh`, `drivers/dart-lock.sh`,
`lib/qg-dart.sh`, `guard_flutter_root`, `commit-lint.sh`, `qg-parity-recycling_mobile_app.sh`.

**Priority when two qualities conflict:** no new bypass first, then a row's verdict unchanged by the
migration, then less code.

## Open & deferred

- needs the operator: once `feat/qg-flutter-drivers` reaches `main`, migrate `release/1.17.0` of
  recycling_mobile_app: `migrations/recycling_mobile_app/apply.sh ~/workspace/recycling_mobile_app`,
  then the steps it prints (`git add` the listed files, `qg override --reason "migrate the gate config
  to v2"`, commit within 10 minutes, `qg baseline --only <new repo ids>`, commit, `qg run push` before
  the first push). `master` receives the v2 config when the release branch merges into it.
- needs the operator: `develop` and the other local branches keep v1 until S6 lists them with
  `qg doctor --all-branches`.
- needs the operator: `guard_flutter_root` in mobile's `quality/config` holds this machine's SDK path,
  `/home/kdabrow/workspace/flutter/flutter`. A Flutter upgrade in place keeps it; a move needs a
  config commit under `qg override`.
- user-visible: every push runs the whole Flutter suite with coverage, as v1 `tests-failing` does. A
  push whose `pubspec.lock` names a package missing from the pub cache is refused until
  `flutter pub get` has run, because the gate resolves packages offline.
- user-visible: a commit that changes the locked version of `dart_code_linter`, `lakos`,
  `mutation_test`, `flutter_lints` or `lints`, or turns any package into a `path` or `git` package, is
  refused by `dart-tools-changed` until a human runs `qg override`.
- open: an agent can still write under `~/.pub-cache`, `~/.cache/givore-quality-tools` and the Flutter
  SDK, which hold the code of every Dart tool. W-20 adds this to S6's scope, beside S2's `vendor/` gap.
- open: the pushed test suite runs as the operator's user, so it can write the same folders and
  `<git-common-dir>/guard-cache`, planting code every later gate run executes; v1 `tests-failing` has
  the same reach. Only an OS sandbox closes it, and `bwrap` fails here (`setting up uid map:
  Permission denied`). Owner: S6, added to its row by W-20.
- open: code running as the same user, such as the committed test suite, can still rewrite its own
  stream or coverage report after the suite exits and before the driver reads it. That forges
  `tests-failed` and `coverage` only; every other row runs before it.
- open: S3 (`feat/qg-web-drivers`, unmerged) also edits `vault/architecture/qg-builtin-drivers.md`,
  `vault/architecture/qg-driver-contract.md` and `templates/init/`. The second branch to merge resolves
  those lines by hand; S4 does not edit `lib/qg-driver-kit.sh`.
- open: after S3 merges, move into `lib/qg-driver-kit.sh`: a `qg_tracked <path>` helper (now inline in
  `lib/qg-dart.sh` and `drivers/checkstyle.sh`), `qg_tool` accepting an empty argv so
  `drivers/checkstyle.sh` stops repeating its runner branch, and one findings cap in `qg_result` in
  place of the `head -200` in `drivers/grep-count.sh`, `layerlens.sh`, `copydetect.sh` and
  `dart-code-linter.sh`.
- open: `flutter-test` coverage counts only libraries some test loads, as v1 does; a new file no test
  imports leaves `coverage` unchanged.
- open: `dart-tools-changed` does not see a version bump of a hosted transitive dependency;
  `pubspec.lock` holds no dependency graph.
- open: `layerlens` is a global `dart pub global activate` install; the driver refuses a version other
  than `version=` (default 3.1.0), so an upgrade needs a row edit.

## Open questions

| id | question | blocks | searched | status | answer |
|----|----------|--------|----------|--------|--------|
| Q1 | Base S4 on `main` or on S3's unmerged `feat/qg-web-drivers`? | no | `git log main..feat/qg-web-drivers` (11 commits, plan `status: proposed`) | defaulted | `main`; S4 needs nothing S3 adds |
| Q2 | Push rows run on every ref (`refs/*` on `release/1.17.0`) or on `release/*` (`master`)? | no | `git show release/1.17.0:VAULT.md`, `git show master:VAULT.md`, commit `884aad23` | defaulted | every ref: `on` = `push`, the operator's latest choice |

## Success criteria

| id | criterion | kind | how | check | expect | verdict | evidence |
|----|-----------|------|-----|-------|--------|---------|----------|
| SC-1 | WHEN each of the eleven drivers runs on a tool output recorded from a real run THE SYSTEM SHALL write `metric` equal to the v1 command on the same output; SHALL write `status: error`, never a number, on a crash, an exit code its table calls an error, a missing report, a test stream with no `done` event or no test, a layerlens run that writes no `DEPS.md`, or a nested `analysis_options.yaml` not in `options-allow=`; and SHALL write `measured 0` without running the tool when `files=changed` matches nothing | unit | command | `checks/qg-s4-SC-1.sh` | 0 | MET | `checks/qg-s4-SC-1.sh` exited 0 · 201 cases passing across 11 driver suites |
| SC-2 | WHEN a Dart driver or mobile's `commit-lint.sh` measures a tree THE SYSTEM SHALL run the SDK under `guard_flutter_root` by absolute path, resolve packages with `pub get --offline` inside `QG_TREE` only, run `flutter test` with `--no-pub`, ignore a caller's `PUB_CACHE`, `FLUTTER_ROOT` and `XDG_CACHE_HOME`, and leave the caller's checkout byte-identical; it SHALL write `status: error` naming the step when `flutter` on `PATH` is not that SDK, the tree holds `pubspec_overrides.yaml` or a tracked `.dart_tool/`, or resolution fails | unit | command | `checks/qg-s4-SC-2.sh` | 0 | MET | `checks/qg-s4-SC-2.sh` exited 0 · 13 of 13 cases passing |
| SC-3 | WHEN `migrations/recycling_mobile_app/checks.tsv` loads under the new engine with `migrations/recycling_mobile_app/config` THE SYSTEM SHALL load every id of the v1 file, as a v2 row or as `kind: absent` naming its replacement, each with a distinct `why` that is neither the fallback nor `TODO`; every file named by an `awk=`, `runner=`, `rules=`, `requirements=` or `options-allow=` key, and every default config file of `vault/architecture/qg-dart-drivers.md`, SHALL be in `guard_protected_paths`; no args cell SHALL hold `\|`; and every `flutter-test` or `mutation-test` row SHALL follow every other push or baseline row | unit | command | `checks/qg-s4-SC-3.sh` | 0 | MET | `checks/qg-s4-SC-3.sh` exited 0 · 3 of 3 cases passing |
| SC-4 | WHEN `checks/qg-parity-recycling_mobile_app.sh` seeds violations per v1 row in scratch clones of recycling_mobile_app and runs the old and the new config THE SYSTEM SHALL show, for every v1 id, an old seeded value different from the old clean value; for a kept id, the same seeded value and status on both sides; for a renamed id with an unchanged unit, the same clean value on both sides; the suite rows run the real suite with one seeded failing test | delivery | command | `checks/qg-parity-recycling_mobile_app.sh` | 0 | MET | `checks/qg-parity-recycling_mobile_app.sh` exited 0 · parity: work dir /tmp/qg-parity-mobile.ltaeRF (log /tmp/qg-parity-mobile.ltaeRF/parity.log) |
| SC-5 | WHEN any v2 row runs alone through `qg run push --only <id>` in a fresh clone with no untracked files THE SYSTEM SHALL give the value it gives in a full push run; and WHEN the suite under test writes into `QG_RUN_DIR` or the measured tree THE SYSTEM SHALL leave every row before it unchanged | unit | command | `checks/qg-s4-SC-5.sh` | 0 | MET | `checks/qg-s4-SC-5.sh` exited 0 · 7 of 7 cases passing |
| SC-6 | WHEN a commit stages an edit to `quality/bin/commit-lint.sh`, changes the locked version of a package `dart-tools-changed` names, or turns any package into a `path` or `git` package, THE SYSTEM SHALL run the parent commit's `commit-lint.sh` for the lint rows and refuse the commit through `protected-paths-touched` or `dart-tools-changed` | unit | command | `checks/qg-s4-SC-6.sh` | 0 | MET | `checks/qg-s4-SC-6.sh` exited 0 · 11 of 11 cases passing |

## Definition of done

| id | line | state | evidence |
|----|------|-------|----------|
| DOD-1 | bats suite passes: `./tests/run.sh tests/unit` | met | 658 ok, 0 not ok on `69b0f5b` (421 at the start of S4) |
| DOD-2 | `shellcheck -S warning` (image `koalaman/shellcheck`) passes on every new and changed `.sh` | met | 23 scripts from `git diff --name-only --diff-filter=AM 6479a22..HEAD -- '*.sh'`: no finding (`koalaman/shellcheck:stable`) |
| DOD-3 | `bin/doc-lint.sh` passes on every new and changed `vault/**/*.md` | met | no findings on the plan, test design, trail, `qg-dart-drivers.md`, `qg-builtin-drivers.md`, `qg-driver-contract.md` and the master plan |
| DOD-4 | each commit goes through this repo's own commit gate, with no override | met | every S4 commit printed its `comment-density` and `doc-lint` rows; none used `qg override` |

## Verified current state

- Mobile `release/1.17.0` `VAULT.md`: `guard_release_pattern: refs/*`; `master`: `refs/heads/release/*|refs/heads/realse/*`; no `guard_measure_worktree`, so a push is measured in a detached worktree of the pushed commit · `git show <branch>:VAULT.md` · 2026-10-19
- Mobile has 66 v1 rows: 58 `release`, 5 `commit`, 1 `baseline`, 2 `absent`; 56 baseline entries · `awk -F'\t' 'NR>1 && $0!~/^#/ && NF>1' quality/checks.tsv` · 2026-10-19
- v1 `coverage-age-days` reads `coverage/lcov.cleaned.info`, which only `tests-failing` writes; `duplication-clones` runs `true` and reads the report `duplication` writes; `/coverage/` is gitignored · read · 2026-10-19
- `dart analyze --format=machine .` gives 487 lines, 17 under `test/`, and `flutter analyze --no-pub` reports `487 issues found` on `884aad23`; both list 32 `unawaited_futures`. Exits: dart 2, flutter 1 · ran in a scratch clone · 2026-10-19
- The only nested analysis options file is `tool/givore_lints/analysis_options.yaml` · `find lib test integration_test tool -name analysis_options.yaml` · 2026-10-19
- `dart format --output=none --set-exit-if-changed` prints `Changed <path>` per file and exits 1 when one changes; 5 of 42 files under `tool/givore_lints/test/fixtures` would change · ran · 2026-10-19
- `dart_code_linter` writes 31 MB of JSON to `--json-path` and the same to stdout, and exits 1 when it reports issues. On `884aad23` the v1 selects give 10, 1, 50, 175, 104 and 66 with or without `--exclude` · ran · 2026-10-19
- dcl JSON carries both `lines-of-code` (251 functions over 50) and `source-lines-of-code` (175); v1 `long-functions` reads the second · ran · 2026-10-19
- v1 `comment-density` gives 0.132 with its cloc filters and 0.23 without, because `lib/generated/l10n` holds a `///` line per string · ran · 2026-10-19
- `flutter test --coverage --machine` prints a blank line and a `[{"event":"test.startedProcess",…}]` line per suite besides event objects; without `--no-pub` it runs an online `pub get` · ran · 2026-10-19
- `dart run lakos --format json --metrics` exits 5 when a cycle exists and still prints the JSON; `.metrics.nccd` 4.51 · ran; `lakos-2.0.7/bin/lakos.dart:137` · 2026-10-19
- `dart pub global run layerlens --path . --package givore --only "lib/**"` exits 0 and writes 156 `DEPS.md` holding 33 `--!--` lines; layerlens 3.1.0 is a global install · ran · 2026-10-19
- `mutation_test` 1.8.0 exits 0 when every mutation is caught, 255 when some survive, 1 or 2 on an error; it prints `Undetected Mutations: <n> (<p>%)` · `mutation_test-1.8.0/bin/mutation_test.dart:150-185` · 2026-10-19
- `tool/lcov_summary.dart` keeps `lcov.info` blocks whose path is under `lib/`, drops `/lib/generated/` and `.g .freezed .mocks .config .gr` Dart files · read · 2026-10-19
- `test/flutter_test_config.dart` wraps every test file's `testMain`; `dart_test.yaml` sets suite options; neither is protected today · read `VAULT.md:55` · 2026-10-19
- A committed `pubspec_overrides.yaml` makes `dart run <tool>` resolve the tool to a path inside the repo · ran in a scratch package · 2026-10-19
- `pubspec.lock` holds 285 `hosted` and 8 `sdk` packages, none `path` or `git`; `analysis_options.yaml` includes `package:flutter_lints/flutter.yaml` · `grep 'source:' pubspec.lock \| sort \| uniq -c` · 2026-10-19
- Four user-writable folders precede the Flutter SDK on `PATH`; `templates/claude-hooks/guard_bash.py:28` denies an agent's `HOME`, `XDG_CONFIG_HOME` and `PATH` assignments only · `echo $PATH`, read · 2026-10-19
- `bin/guard.sh` `guard_run` runs rows one at a time in file order · read · 2026-10-19
- `vault/architecture/qg-driver-contract.md` is at its 200-line cap · `wc -l` · 2026-10-19
- `commit-lint.sh` takes `<tree> <cache>` and staged paths on stdin. It copies the live checkout's `package_config.json` when the locks match, and reuses its two reports only when both exist and its memo key matches · read · 2026-10-19
- `qg_shared_report` keys on every arg except `metric=` and shares one file (`lib/qg-driver-kit.sh:79-93`) · read · 2026-10-19
- An unmeasurable row refuses whatever its `gate` cell says (`lib/guard-metrics.sh` `_guard_run_row` returns 2) · read · 2026-10-19

## Decisions

| decision | reason | record |
|----------|--------|--------|
| Branch from `main`; `lib/qg-driver-kit.sh` is not edited | S3 is unmerged and edits the kit | local |
| The engine passes `QG_CONFIG_REV` (`lib/qg-driver.sh` `guard_run_driver`), the judging commit; empty on a first commit. `qg-driver-contract.md` gains its row and stays at 200 lines; a rebase on S3 keeps both edits | a driver must read a config key at the judging commit, and `bin/qg` clears the revision variables | local |
| `bin/guard.sh baseline` measures a detached worktree of `HEAD` when the repo measures commits and a selected row's driver needs a tree | the Dart drivers write packages, reports and mutations into the tree they measure | local |
| `qg init --profile flutter` writes `guard_flutter_root` from the `flutter` on the operator's `PATH`; `qg migrate` copies the key; `extend/dod-keys.tsv` lists it | a new Flutter repo's Dart rows would otherwise all refuse | local |
| Helpers for one language live in `lib/qg-<lang>.sh`; built-in drivers are catalogued per ecosystem; `qg-builtin-drivers.md` states both | the PHP kit and the Dart helpers need one rule for where code goes | local |
| `qg_dart_env` in `lib/qg-dart.sh` reads `guard_flutter_root` through `lib/qg-config.sh` at `QG_CONFIG_REV`, unsets `PUB_CACHE`, `FLUTTER_ROOT` and `XDG_CACHE_HOME`, exports `FLUTTER_ROOT=<root>`, and runs `<root>/bin/flutter` and `<root>/bin/cache/dart-sdk/bin/dart` by absolute path. It is `status: error` when the key is absent, `flutter` on `PATH` resolves elsewhere, or the row sets `runner=` | neither a caller's environment nor a planted file on `PATH` may choose the tool that judges | local |
| `qg_dart_packages` refuses `pubspec_overrides.yaml` or a tracked `.dart_tool/` in `QG_TREE`, then runs `dart pub get --offline --enforce-lockfile` there; its error names `flutter pub get` as the fix | a commit must never point a tool at code in the repo, through an overrides file or a `pubspec.yaml` override the lock does not record | local |
| `dart-lock` driver reads `pubspec.lock` and `pubspec.yaml` from git at `QG_TARGET` and at each of `QG_BASES`. `metric` = the most, over the bases, of: named packages (`packages=`) whose version, source, url, git ref or path differ; every package whose source becomes `path` or `git`; 1 when `dependency_overrides:` differs. A lock line outside pub's block form is `status: error` | mobile runs its tools on push, so the commit is the only point that can refuse a tool change; S2's runner check compares at commit for the same reason | local |
| `flutter-test` and `mutation-test` run commit code through `qg_isolated`: its own session, an environment of `HOME PATH LANG FLUTTER_ROOT TMPDIR` only, its process group killed after | the suite inherits no gate variable and leaves no process running in its group | local |
| `grep-count` reads its `awk=` script, and `copydetect` its `requirements=` file, at `QG_CONFIG_REV` | a commit cannot change the rule or the venv that judges it | local |
| One `dart-analyze` driver covers `dart analyze` and `flutter analyze`: `dart analyze --format=machine`; keys `paths` (default `.`) `files=changed include exclude lines=added code severity options-allow`. A nested `analysis_options.yaml` below `paths` outside `options-allow=` is `status: error` | both give 487; a nested options file would loosen a directory | local |
| The givore lint runner stays repo code. The `checkstyle` driver calls the committed runner as `<runner> <tree> <cache>` with no `bin` or argv, never deletes `report=`, and is `status: error` when the runner exits non-zero or the report is missing. Its catalogue entry states that a runner may be the tool itself | the runner owns its memo and deletes both reports on failure | local |
| `commit-lint.sh` reads changed paths from `$QG_FILES` when set, else stdin. It takes the SDK from `HEAD:quality/config` `guard_flutter_root`, unsets `PUB_CACHE` and `XDG_CACHE_HOME`, refuses `pubspec_overrides.yaml`, and always runs `dart pub get --offline` in the tree | the lint rows get the same protection as the drivers | local |
| `dart-code-linter` shares one report per run through `qg_shared_report`. `metric=<metricsId>>N` counts entries over N in `.functions`, or in `.classes` for `number-of-methods`; `metric=issue:<ruleId>` counts issues; `ignore=<glob>` is passed to `--exclude`; the six rows carry identical args apart from `metric=` | one run serves six rows | local |
| `flutter-test` runs `<root>/bin/flutter test --no-pub --coverage --coverage-path <dir>/lcov.info --machine --concurrency=<n>` once per run, every `QG_*` variable unset; `<dir>` is a `mktemp -d` of mode 0700 outside `QG_TREE`. The shared file holds `{"failed","tests","done","lh","lf"}` | both rows read one run; test code cannot reach a later row | local |
| The stream parser reads only lines starting with `{`. `failed` counts `testDone` with `result` `failure` or `error`, a file that fails to load included; `status: error` unless a `done` event and one non-hidden `testDone` exist; ok exits 0, 1 | the real `--coverage` stream carries non-event lines | local |
| `metric=coverage` sums `LH` over `LF` of `lcov.info` blocks kept by `include=` and `exclude=` on the tree-relative path, two decimals | the filter equals `tool/lcov_summary.dart` | local |
| The `flutter-test` and `mutation-test` rows come last in `checks.tsv`; `vault/architecture/qg-dart-drivers.md` states the rule and SC-3 checks it | `guard_run` runs rows in file order | local |
| `coverage-age-days` becomes `kind: absent` naming `coverage` | every push now measures coverage fresh | local |
| `duplication` and `duplication-clones` each run `pnpm dlx jscpd@5.3.2 lib -c quality/jscpd.json --reporters json --no-colors` | each row then measures alone with one tool version | local |
| `grep-count`: `count=files` (`grep -rlE`) or `count=lines` (`grep -rnE`) over `paths=` (each must exist and be non-empty), `name=<glob>`, `exclude=<ERE>`. `exclude=` matches the path relative to `QG_TREE` as `paths=` spells it. The pattern is the argv after ` -- `, taken whole | the argv holds spaces a key value cannot | local |
| `grep-count awk=<repo path>` runs `find <paths> -name <glob> -print0 \| xargs -0 awk -f` and counts printed lines | the v1 rows run exactly that | local |
| A v1 post-filter `grep -vE "<re>:"` on `grep -n` output becomes `exclude=<re>$` | the driver matches the path, not `path:line:` | local |
| A row converts to `grep-count` only when its v1 command is one `grep -r`, or one `find … \| xargs -0 awk -f`, over fixed paths; every other custom row stays `shell` | a translation that changes a count changes a verdict | local |
| `layerlens` deletes every `DEPS.md` under `paths=` first, counts `--!--` lines in the ones the run wrote, and is `status: error` when it wrote none; `version=` must match `dart pub global list` | an empty run must not read as no cycle | local |
| `lakos` measures on exits 0 and 5; `metric=nccd` default | exit 5 means a cycle exists | local |
| `mutation-test` measures on exits 0 and 255, every `QG_*` variable unset; `metric` = 100 minus the undetected percent, two decimals | the v1 row computes the same number | local |
| `dart-format` counts files it would change; `format` takes the new id `format-files` with v1's filters as `exclude=` | v1 reads 0 or 1; both are `kind: diff` threshold 0 | local |
| `tests-failing` → `tests-failed`; `gate-config-touched` → `protected-paths-touched`; `comment-density` → `comment-ratio` with v1's cloc filters as argv | a count replaces the exit code; the protected list grows; cloc runs with `--timeout 0`, as S2 | local |
| `duplication-new` stays `shell` | the `jscpd-added` driver would make the warn row refuse when jscpd cannot start | local |
| Push rows take `on` = `push`; commit rows `commit`; `mutation` `baseline` | the operator gates every pushed ref since `884aad23` | local |
| Prepared mobile files live in `migrations/recycling_mobile_app/`; `apply.sh` copies them and commits nothing, refusing under `CLAUDECODE` or `AI_AGENT` outside the real `/tmp` | the agent guards forbid an agent `quality/config` in any repo | local |

## Scope & non-goals

Covers: eleven drivers with bats tests, `lib/qg-dart.sh`, the Dart catalogue page, the `flutter` init
profile, mobile's v2 rows, config and adapted `commit-lint.sh`, the parity proof, and S6's added scope.

Not in scope: committing in recycling_mobile_app; branches other than `release/1.17.0`; the shell rows
that stay shell; the S3, S5 and S6 work; agent write guards for tool caches.

## Artifact lifecycles

| artifact | what requires it | who writes it | who reads it | missing or wrong |
|---|---|---|---|---|
| `$QG_OUT/result.json` from each new driver | `guard_run_driver` in `lib/qg-driver.sh` reads `metric` | `drivers/<name>.sh run` via `qg_result` | `lib/qg-driver.sh`, `bin/guard-report-errors.sh` | absent, `status: error` or non-number `metric` → `unmeasurable`, never 0 |
| `QG_ARGS` keys of each new driver | the row's `args` cell | the operator in `quality/checks.tsv` | `qg_kv` in each driver | a missing required key (`runner=` and `report=` for checkstyle, `package=` for layerlens, `rules=` for mutation-test, `paths=` for grep-count, `metric=` for flutter-test, `packages=` for dart-lock) → `status: error` naming it |
| `guard_flutter_root` in `quality/config` | `qg_dart_env`, `commit-lint.sh` | the operator, through `apply.sh` | `qg config get` at the config revision | absent or not an SDK → `status: error` naming the key |
| `QG_TREE/.dart_tool/package_config.json` | every Dart driver before its tool runs | `qg_dart_packages` | `dart analyze`, `dart run`, `flutter test` | resolution fails → `status: error` naming `dart pub get --offline`, its last 5 lines and `run flutter pub get` |
| `$QG_RUN_DIR/dart-code-linter-<key>`, `$QG_RUN_DIR/flutter-test-<key>` | `qg_shared_report` | the first row of a run that needs it | later rows of the same run and target | absent → that row runs the tool itself |
| flutter-test stream and `lcov.info` in a 0700 temp folder | `drivers/flutter-test.sh` | `flutter test --machine --coverage` | `drivers/flutter-test.sh` | absent, no `done` event or no test → `status: error` |
| `quality-reports/commit-lint-{refuse,warn}.xml` in `QG_TREE` | the `checkstyle` driver | mobile `quality/bin/commit-lint.sh` from the config revision | `drivers/checkstyle.sh` | absent after the runner → `status: error` |
| `migrations/recycling_mobile_app/checks.tsv`, `config`, `commit-lint.sh` | `apply.sh`, the parity script, `checks/qg-s4-SC-3.sh` | this session | the operator | does not load → SC-3 exits 1 naming file and line |
| `migrations/recycling_mobile_app/parity.tsv`: `id new-id kind verdict old-clean old-seed1 old-seed2 new-seed1 new-seed2`; rows with no v1 id carry kind `new` | `apply.sh` prints the new repo ids to baseline | `checks/qg-parity-recycling_mobile_app.sh` | the operator | absent → `apply.sh` exits 2 and copies nothing; `new` rows are never offered to `qg baseline` |

## Work items

| id | file (exact path) | action | tool | constraint | covers | verification | status |
|----|-------------------|--------|------|------------|--------|--------------|--------|
| W-0 | `checks/qg-s4-SC-1.sh`, `qg-s4-SC-2.sh`, `qg-s4-SC-3.sh`, `qg-s4-SC-5.sh`, `qg-s4-SC-6.sh`, `checks/qg-parity-recycling_mobile_app.sh` (skeleton exiting 2) | one script per criterion, committed first | Write | exit 0 pass, 1 fail, 2 could not run | SC-1..SC-6 | `gate.sh criteria` passes | DONE |
| W-1 | `lib/qg-dart.sh` | `qg_dart_env`, `qg_dart_packages` per Decisions | Write | writes only under `QG_TREE`; offline | SC-2 | `tests/unit/qg-dart.bats` | DONE |
| W-2 | `drivers/dart-lock.sh` | per Decisions; reads each base lock with `git show` | Write | — | SC-6 | `tests/unit/qg-driver-dart-lock.bats` | DONE |
| W-3 | `drivers/dart-analyze.sh` | per Decisions; ok exits 0..3; level ERROR→error, WARNING→warning, INFO→note; ruleId = code lower-cased | Write | — | SC-1 | `tests/unit/qg-driver-dart-analyze.bats` | DONE |
| W-4 | `drivers/dart-format.sh` | `dart format --output=none --set-exit-if-changed` on changed `.dart` files kept by `include=`, `exclude=`; ok exits 0, 1; `metric` = `Changed` lines | Write | — | SC-1 | `tests/unit/qg-driver-dart-format.bats` | DONE |
| W-5 | `drivers/dart-code-linter.sh` | `dart run dart_code_linter:metrics analyze <paths> --reporter=json --json-path=quality-reports/dcl.json [--exclude=<ignore>]`, stdout to a file; ok exits 0, 1 with the report | Write | stdout never printed | SC-1 SC-5 | `tests/unit/qg-driver-dart-code-linter.bats` | DONE |
| W-6 | `drivers/layerlens.sh` | per Decisions; keys `package` (required) `only paths version` | Write | — | SC-1 | `tests/unit/qg-driver-layerlens.bats` | DONE |
| W-7 | `drivers/lakos.sh` | `dart run lakos --format json --metrics [--ignore <ignore>] <path>`; `metric` one of `nccd`, `ccd`, `acd` | Write | — | SC-1 | `tests/unit/qg-driver-lakos.bats` | DONE |
| W-8 | `drivers/flutter-test.sh` | per Decisions; keys `metric` (required) `concurrency include exclude` | Write | fixture recorded from a real `--coverage --machine` run | SC-1 SC-2 SC-5 | `tests/unit/qg-driver-flutter-test.bats` | DONE |
| W-9 | `drivers/mutation-test.sh` | `dart run mutation_test --rules <rules> [-b] <paths>`; keys `rules` (required) `builtin=yes paths` | Write | — | SC-1 | `tests/unit/qg-driver-mutation-test.bats` | DONE |
| W-10 | `drivers/copydetect.sh` | the detection of `tool/checks/semantic_clones.py` inside the driver; keys `paths ext exclude min-similarity min-tokens noise guarantee requirements venv-root`; interpreter `$HOME/.cache/<venv-root>/copydetect-<sha256 of requirements, 12 chars>/bin/python` | Write | prints the pairs `semantic_clones.py` prints | SC-1 | `tests/unit/qg-driver-copydetect.bats` (stub python) | DONE |
| W-11 | `drivers/grep-count.sh` | per Decisions; `grep` exit 2 or an `awk` failure → `status: error` | Write | — | SC-1 | `tests/unit/qg-driver-grep-count.bats` | DONE |
| W-12 | `drivers/checkstyle.sh` | per Decisions; `lines=added` through `qg_added_only` | Write | refuses `bin=` and argv | SC-1 SC-6 | `tests/unit/qg-driver-checkstyle.bats` | DONE |
| W-13 | `vault/architecture/qg-dart-drivers.md`, `vault/architecture/qg-builtin-drivers.md` | Dart catalogue: keys, measured exits, metric, unit, default config files, the row-order rule, the runner-as-tool case; the general page links it and states the helper and catalogue rule | Write, Edit | each ≤200 lines (`wc -l`) | SC-3 | doc-lint | DONE |
| W-14 | `templates/init/flutter.tsv` | `format-changed` uses `dart-format`, `analyze` uses `dart-analyze`, `tests` uses `flutter-test` | Edit | — | — | `tests/unit/qg-migrate.bats` init case | DONE |
| W-15 | `migrations/recycling_mobile_app/commit-lint.sh` | mobile `quality/bin/commit-lint.sh` per Decisions | Write | everything else byte-identical | SC-2 SC-6 | `checks/qg-s4-SC-6.sh`, a caller `PUB_CACHE` case | DONE |
| W-16 | `migrations/recycling_mobile_app/checks.tsv` | v2 header; rows per `## Row mapping`, ids taken from the v1 file; each with its own `why` | Write | `kind`, direction, threshold, gate unchanged except `coverage-age-days` | SC-3 SC-4 | `checks/qg-s4-SC-3.sh` | DONE |
| W-17 | `migrations/recycling_mobile_app/config` | mobile `VAULT.md` gate keys plus `guard_flutter_root: /home/kdabrow/workspace/flutter/flutter`; `guard_protected_paths` adds `quality/drivers quality/config quality/jscpd.json mutation_test.xml dart_test.yaml test/flutter_test_config.dart pubspec_overrides.yaml .dart_tool .npmrc .jscpd.json` | Write | — | SC-3 | SC-3 | DONE |
| W-18 | `migrations/recycling_mobile_app/apply.sh` | copy `checks.tsv`, `config` into `quality/` and `commit-lint.sh` into `quality/bin/`; print the operator steps with the new repo ids from `parity.tsv` | Write | commits nothing; refuses a checkout without a v1 `quality/checks.tsv` | — | `tests/unit/qg-migration-mobile.bats` | DONE |
| W-19 | `checks/qg-parity-recycling_mobile_app.sh` | S2's method: two `git clone --shared` scratch clones, clean, seed1 and seed2 states; a generated-file hit seeded for every row with `exclude=` or `ignore=`; the suite rows run the real suite with one seeded failing test; `mutation` reads a recorded report | Write | reads the live checkout only to copy the recorded mutation output | SC-4 | runs to exit 0 | DONE |
| W-20 | `vault/plans/2026-10-18-1121-qg-common-interface.md` | S6 row: deny agent writes under `~/.pub-cache`, `~/.cache/<venv-root>` and `guard_flutter_root` | Edit | — | — | doc-lint | DONE |

## Row mapping

Ids not listed keep their v1 command as a v2 `shell` row with the same id. Rows sharing a driver run
carry identical args apart from `metric=`. A `\|` below is table escaping; the TSV cell holds `|`.

| driver | v1 ids → args |
|---|---|
| `dart-analyze` | `analyze-issues` `paths=. options-allow=tool/givore_lints/analysis_options.yaml`; `unawaited-futures` the same plus `code=unawaited_futures` |
| `dart-format` | `format` → `format-files` `files=changed exclude=\.(g\|freezed\|mocks\|config)\.dart$\|^lib/generated/\|^tool/givore_lints/test/fixtures/` |
| `dart-code-linter` | all six `paths=lib ignore={/**.g.dart,/**.freezed.dart,/**.mocks.dart,/**.config.dart,/**/generated/**}`; `complexity` `metric=cyclomatic-complexity>20`; `deep-nesting` `metric=maximum-nesting-level>5`; `many-parameters` `metric=number-of-parameters>4`; `long-functions` `metric=source-lines-of-code>50`; `large-classes` `metric=number-of-methods>10`; `layer-inversions` `metric=issue:avoid-banned-imports` |
| `layerlens` | `architecture-cycles` `package=givore only=lib/** paths=lib` |
| `lakos` | `architecture-nccd` `metric=nccd ignore={**.g.dart,**.freezed.dart,generated/**} paths=lib` |
| `flutter-test` | `tests-failing` → `tests-failed` `metric=failed`, `coverage` `metric=coverage`; both `concurrency=4 include=^lib/ exclude=\.(g\|freezed\|mocks\|config\|gr)\.dart$\|^lib/generated/` |
| `mutation-test` | `mutation` `rules=mutation_test.xml builtin=yes paths=lib` |
| `copydetect` | `semantic-clones` `requirements=tool/checks/copydetect-requirements.txt venv-root=givore-quality-tools` |
| `cloc` | `comment-density` → `comment-ratio` `paths=lib -- --not-match-f=\.(g\|freezed\|mocks\|config)\.dart$ --fullpath --not-match-d=/generated/` |
| `checkstyle` | `lint-refuse-new` `runner=quality/bin/commit-lint.sh report=quality-reports/commit-lint-refuse.xml lines=added`; `lint-warn-new` the same with `report=quality-reports/commit-lint-warn.xml` |
| `dart-lock` | new row `dart-tools-changed` (commit, diff, down, 0, refuse) `packages=dart_code_linter,lakos,mutation_test,flutter_lints,lints` |
| `grep-count` files | `domain-material-imports`, `domain-api-model-imports`, `domain-ui-imports`, `svg-style-blocks`, `expandable-page-view`, `static-singletons` |
| `grep-count` lines | `cdn-host-pinned-classifier`, `full-user-model-save`, `paging-controller-cancel`, `analytics-raw-error-field`, `polymorphic-type-filter`, `e2e-first-feed-tile`, `e2e-bytype-async-screen`, `e2e-screen-wake` |
| `grep-count` awk | `compact-density-iconbutton`, `magic-spacing-literals`, `typeerror-escaping-guards`, `styled-elevated-button`, `copywith-unguarded-merge`, `comment-blocks-over-two`, `detail-sheet-dynamic-state`, `test-tail-dispose` |
| `shell` | `gate-config-touched` → `protected-paths-touched`; `duplication` and `duplication-clones` per Decisions |
| `absent` | `coverage-age-days`, naming `coverage` |

## Sequencing & dependencies

W-0 first, so `gate.sh criteria` passes before any code. Then W-1, then W-2..W-12 in any order, then
W-13 and W-14. W-15..W-18, then W-19; W-16 is final only after W-19 has run. W-20 alongside. The
operator's migration comes after this branch reaches `main`.

## Rollback

Every change to this repo reverts with `git revert` on `main` while mobile has not committed its v2
config. After the migration commit, the operator first reverts that commit in mobile under
`qg override`, then reverts S4: the S1 engine refuses the new driver names as unknown.

## Test plan

Bats unit tests in `tests/unit/`, run by `./tests/run.sh tests/unit` (image `tests/Dockerfile`). Each
driver test runs a fake SDK folder named as `guard_flutter_root` and placed first on `PATH`, fed a tool
output recorded from a real run. It compares `metric` with the v1 command on the same output. End to
end: `checks/qg-parity-recycling_mobile_app.sh` on scratch clones with the real Flutter toolchain, the
new side without network. The dossier, the outcome of every edge case, and the backlog are in
`2026-10-19-0930-qg-s4-flutter-drivers.test-design.md`; its driver table binds the implementation.

## Refs

- `vault/plans/2026-10-18-1121-qg-common-interface.md` — the master plan; this is session S4.
- `vault/plans/2026-10-18-1500-qg-s2-php-drivers.md` — S2, whose method this session follows.
- `vault/architecture/qg-driver-contract.md` — the contract every driver here follows.
- `2026-10-19-0930-qg-s4-flutter-drivers.test-design.md` — edge-case outcomes and the test backlog.
- `2026-10-19-0930-qg-s4-flutter-drivers.trail.md` — how this plan was reached.
