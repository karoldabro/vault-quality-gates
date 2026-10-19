---
type: trail
project: vault-quality-gates
plan: 2026-10-19-0930-qg-s4-flutter-drivers
tags: [trail, record]
---

# 2026-10-19-0930-qg-s4-flutter-drivers — process record

Record class. Its contract document is `2026-10-19-0930-qg-s4-flutter-drivers.md`.

## Pickup

- `pm-plan.sh order` refused the master plan: its `## Sessions` table has no `repo` column. S4 was
  claimed by hand with `pm-plan.sh set … S4 status=doing date=2026-10-19`, commit `5678529` on `main`.
- S3 (`feat/qg-web-drivers`) is mid-execution in `~/workspace/vault-quality-gates-s3` with uncommitted
  parity files; its master row still reads `todo`.
- Personas: planning → [solution-architect, harness-engineer, consumer, skeptic]; cap raised to 4
  because the change touches a coupled-repo gate contract (skeptic) and gate tooling (harness), as S2.
- Research gate skipped: every tool is already in a mobile v1 row; tool formats and exit codes were
  measured in a scratch clone instead (plan `## Verified current state`).

## Decisions & trade-offs

| decision | alternative rejected | why it lost |
|---|---|---|
| Base on `main` | base on S3's branch to reuse its `qg_shared_report` key list and `jscpd` driver | S4 cannot land before an unfinished S3 |
| One `dart-analyze` driver | separate `flutter-analyze` driver parsing text output | both give 487; text output wraps and is screen scraping |
| Repo runner plus generic `checkstyle` driver | built-in driver that compiles `tool/givore_lints` | the runner protocol, catalogue and tiers belong to mobile |
| `duplication-new` stays shell | `jscpd-added` driver | the driver makes the warn row refuse when jscpd cannot start |

## Findings & dispositions

### Round 1

| persona | id | severity | grounding | issue | disposition |
|---------|----|----------|-----------|-------|-------------|
| solution-architect, harness-engineer, consumer, skeptic | sa-1 he-5 co-1 sk-1 | BLOCKER | confirmed | nothing writes `coverage/lcov.cleaned.info`, so `coverage-age-days` refuses every push | applied: `kind: absent` naming `coverage` |
| solution-architect, consumer, skeptic | sa-4 co-2 sk-2 | MAJOR | confirmed | `duplication-clones` reads `duplication`'s report, so SC-5 fails | applied: it runs the same jscpd command |
| solution-architect, skeptic | sa-2 sk-6 | MAJOR | confirmed | share key differs between the two flutter-test rows, so the suite runs twice | applied: identical args stated in Row mapping |
| solution-architect, consumer, skeptic | sa-3 co-9 sk-7 | MAJOR | confirmed | `dart-format` without v1 filters counts lint fixtures | applied: `exclude=` in Row mapping |
| solution-architect, consumer, skeptic | sa-5 co-3 sk-10 | MAJOR | confirmed | unclear whether suite rows run or read a report | applied: both run; `run=no` removed |
| harness-engineer | he-1 | MAJOR | confirmed | `pubspec_overrides.yaml` swaps a tool for a repo stub | applied: refused in `qg_dart_packages`, protected |
| harness-engineer | he-2 | MAJOR | confirmed | copying the live `package_config.json` lets an edit choose tool code | applied: always `dart pub get --offline`, in `commit-lint.sh` too |
| harness-engineer | he-3 | MAJOR | confirmed | tool versions in `pubspec.lock` had no owner | applied: `bin/guard-dart-tools.sh`, row `dart-tools-changed` |
| harness-engineer | he-4 | MAJOR | confirmed | a run that measured nothing reads 0 failures | applied: `done` event and one test required; test config files protected |
| harness-engineer | he-6 | MAJOR | confirmed | caller `PUB_CACHE`, `XDG_CACHE_HOME`, `FLUTTER_ROOT` reach the tools | applied: `qg_dart_env` unsets them |
| harness-engineer | he-7 | MAJOR | confirmed | test code can rewrite the shared report or the tree | applied: `QG_*` unset, suite and mutation rows last |
| harness-engineer | he-8 | MINOR | confirmed | nested `analysis_options.yaml` loosens a directory | applied: `options-allow=` |
| harness-engineer | he-9 | MINOR | confirmed | `.npmrc`, `.jscpd.json` unprotected | applied |
| harness-engineer | he-10 | MINOR | advisory | layerlens writing no `DEPS.md` reads 0 | applied |
| harness-engineer | he-11 | MINOR | confirmed | no real `flutter test` run | applied: parity runs the real suite |
| harness-engineer | he-12 | NIT | confirmed | criteria gate needs checks first | applied: W-0 |
| solution-architect, consumer, skeptic | sa-6 co-4 sk-3 | MINOR | confirmed | row count 58 is wrong | applied: 66 rows, 56 baseline entries; ids from the file |
| solution-architect, consumer, skeptic | sa-7 co-7 sk-4 | MINOR | confirmed | deleting the report defeats the runner memo | applied: driver never deletes it |
| solution-architect | sa-8 | MINOR | confirmed | runner-as-tool not in the contract | applied: one contract line |
| solution-architect | sa-9 | MINOR | confirmed | no rule for language helper homes | applied: one contract line |
| solution-architect | sa-10 | NIT | confirmed | `lcov_summary.dart` protected but unused | applied: dropped |
| consumer | co-5 | MINOR | confirmed | `exclude=` path form unstated | applied |
| consumer | co-6 | MINOR | confirmed | `grep -v "re:"` post-filter translation | applied |
| consumer | co-8 | MINOR | advisory | SC-3 key list unclear | applied |
| skeptic | sk-5 | MINOR | confirmed | `commit-lint.sh` finds no repo from `QG_TREE` | applied: the copy branch is gone |
| skeptic | sk-8 | MINOR | confirmed | `unawaited-futures` path default | applied: `paths=.` |
| skeptic | sk-9 | NIT | advisory | offline resolution refuses where v1 fetched | applied: user-visible item, fix named in the error |

### Round 2

| persona | id | severity | grounding | issue | disposition |
|---------|----|----------|-----------|-------|-------------|
| harness-engineer | he2-1 | MAJOR | confirmed | a planted `flutter` earlier on `PATH` supplies the SDK | applied: `guard_flutter_root`, SDK by absolute path |
| harness-engineer | he2-2 | MAJOR | confirmed | agent writes under `~/.pub-cache`, the venv and the SDK are not denied | deferred to S6 (W-20 amends its row), as S2 deferred `vendor/`; minority flag |
| harness-engineer | he2-3 | MAJOR | confirmed | `flutter_lints`/`lints` bumps and `path`/`git` sources change the lint set | applied |
| harness-engineer | he2-4 | MINOR | confirmed | row order enforced by nothing | applied: SC-3 checks it |
| harness-engineer | he2-5 | MINOR | advisory | the suite can rewrite its own stream | applied: 0700 temp folder outside the tree; residual open item |
| skeptic | sk2-1 | MAJOR | confirmed | `comment-ratio` drops v1 cloc filters, 0.23 vs 0.132 | applied: filters as argv; SC-4 compares clean values of renamed same-unit rows |
| skeptic | sk2-2 | MINOR | confirmed | real `--coverage --machine` stream has non-event lines | applied |
| skeptic | sk2-3 | MINOR | confirmed | `flutter test` runs online `pub get` | applied: `--no-pub` |
| skeptic, consumer | sk2-4 c2-7 | MINOR | confirmed | two dcl metrics and `<tier>` not written literally | applied |
| skeptic | sk2-5 | MINOR | confirmed | SC-4 cannot hold for a row with no v1 id | applied |
| skeptic | sk2-6 | NIT | advisory | two unpinned jscpd runs | applied: `jscpd@5.3.2` in both |
| consumer | c2-1 | MAJOR | confirmed | dcl rows lack v1's generated-file exclude | applied: `ignore=`; v1 counts are equal either way today |
| solution-architect | c2-2 | MAJOR | confirmed | the contract is at its 200-line cap | applied: rules go to the catalogue pages |
| solution-architect | c2-3 | MAJOR | confirmed | a Dart-only script in `bin/` and a second lock mechanism | applied: `dart-lock` driver; why it diverges from S2 in Decisions |
| consumer | c2-4 | MINOR | confirmed | `commit-lint.sh` misses the environment hardening | applied |
| consumer | c2-5 | MINOR | confirmed | `\|` copied from the table breaks the ERE | applied: note and SC-3 check |
| consumer | c2-6 | MINOR | confirmed | one shared file, two outputs | applied: one JSON with both values |

Round 2 findings were applied without a third review.

## Advisory test hints

- sa-t1, co-t1, sk-t1, he-t3: every row alone in a fresh clone with no untracked files measures.
- sa-t2, sk-t2: one shared run per target for the flutter-test and dart-code-linter rows.
- sa-t3: `format-files` reads 0 on a changed fixture and a `.g.dart` file.
- he-t1: overrides file, tracked `.dart_tool`, caller `PUB_CACHE`, changed tool lock → `status: error`.
- he-t2, co-t2: stream without `done`, zero tests, missing `test/` → `status: error`.
- co-t3: anchored `exclude=` counts 1 of 3 hits.
- sk-t3: the two lint rows in one commit run the runner once.

## Metrics

| round | critics | confirmed BLOCKER/MAJOR | advisory | applied | deferred |
|---|---|---|---|---|---|
| 1 | 4 | 12 clusters | 3 | 27 clusters | 0 |
| 2 | 3 | 7 | 2 | 16 | 1 |

Convergence: capped at 2 rounds; one confirmed MAJOR (he2-2) deferred to S6.
