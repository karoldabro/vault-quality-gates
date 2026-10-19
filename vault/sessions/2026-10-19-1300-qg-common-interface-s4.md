---
type: session
project: vault-quality-gates
date: 2026-10-19
topic: qg common interface — session 4 (Flutter drivers, recycling_mobile_app migration)
continues: [[2026-10-18-1903-qg-common-interface-s2]]
files_touched: [lib/qg-dart.sh, lib/qg-driver.sh, lib/qg-migrate.sh, bin/guard.sh, drivers/dart-analyze.sh, drivers/dart-format.sh, drivers/dart-code-linter.sh, drivers/layerlens.sh, drivers/lakos.sh, drivers/flutter-test.sh, drivers/mutation-test.sh, drivers/copydetect.sh, drivers/grep-count.sh, drivers/checkstyle.sh, drivers/dart-lock.sh, migrations/recycling_mobile_app/*, checks/qg-parity-recycling_mobile_app.sh, checks/qg-s4-SC-*.sh, templates/init/flutter.tsv, vault/architecture/qg-dart-drivers.md, vault/architecture/qg-driver-contract.md]
decisions: []
tags: [session, quality-gate, qg, drivers, flutter, dart, migration]
---

# qg common interface — session 4 (Flutter drivers, recycling_mobile_app migration)

## Goal

Add built-in Dart and Flutter drivers and prepare recycling_mobile_app's 66 gate rows in the v2 format
with a row-parity proof.

## Did

- Built on branch `feat/qg-flutter-drivers` in worktree `~/workspace/vault-quality-gates-s4`, pushed to
  `origin` at `bff6b09`.
- Eleven drivers: dart-analyze, dart-format, dart-code-linter, layerlens, lakos, flutter-test,
  mutation-test, copydetect, grep-count, checkstyle, dart-lock; shared `lib/qg-dart.sh`; catalogue
  `vault/architecture/qg-dart-drivers.md`.
- The engine passes `QG_CONFIG_REV`; `guard.sh baseline` measures a detached worktree of `HEAD` when a
  tree-writing driver runs; `qg init --profile flutter` writes `guard_flutter_root`.
- Prepared `migrations/recycling_mobile_app/` (checks.tsv, config, commit-lint.sh, apply.sh) and
  `checks/qg-parity-recycling_mobile_app.sh`. Tests 421 → 658.
- Not run: the parity script and `gate.sh verdict --run`; the agent hook blocks an agent from running
  the S4 engine copy, so SC-1..SC-6 have no verdict and the master row stays `doing`.

## Learned

- `dart analyze --format=machine .` and `flutter analyze` both report 487 on mobile `884aad23`;
  `dart_code_linter` writes its 31 MB report to stdout as well as `--json-path`.
- `pub get --offline` follows a `pubspec.yaml` `dependency_overrides` entry the lock does not record;
  `--enforce-lockfile` refuses it (exit 65).
- `sed 's/x/\x01/'` writes the four characters `x01` under busybox and BSD sed; do byte escapes in awk.
- `awk -v re='\.'` keeps the backslash under mawk and drops it under gawk; pass EREs through `ENVIRON`.
- `grep -r` with one file operand prints no file name; `-H` is needed for findings.
- `xargs` exits 123 for both "no match" and "unreadable" from grep; call grep directly to tell them apart.
- bats ignores a false `[ a ]` on the left of `&&` on a non-final line; older driver suites carry it.
- `bwrap` fails on this host (`setting up uid map: Permission denied`), so the suite cannot be sandboxed.
- The repo's guard hook blocks running any script that sets `GUARD_*` or `QG_*` and any script it cannot
  read, including the S4 engine copy and `checks/*.sh` that source `_qg-cases.sh`.

## Behaviors & rules

- A Dart driver → runs the SDK `guard_flutter_root` names by absolute path; edge: a different `flutter` on `PATH` or a `runner=` → status error.
- A tree with `pubspec_overrides.yaml` or a tracked `.dart_tool/` → status error before `pub get`.
- A commit changing a named tool's version, source, url, git ref or path, turning any package into a path or git package, or changing `dependency_overrides` → `dart-tools-changed` counts it.
- A test stream with no `done` event or no visible test → status error, never 0 failed.
- `flutter-test` and `mutation-test` rows → last in `checks.tsv`, run through `qg_isolated`.
- A renamed v1 row → `kind: absent` naming its replacement; a renamed row of the same unit must read the same clean value.

## Next

- Operator: run `/home/kdabrow/.claude/plugins/cache/kdabro-vault/vault/1.13.0/bin/gate.sh verdict --run /home/kdabrow/workspace/vault-quality-gates-s4/vault/plans/2026-10-19-0930-qg-s4-flutter-drivers.md` from the S4 worktree; it runs the parity proof (up to hours) and writes SC-1..SC-6 verdicts.
- Operator: then close master row S4, merge `feat/qg-flutter-drivers`, and run `migrations/recycling_mobile_app/apply.sh ~/workspace/recycling_mobile_app` with the steps it prints.
- S6: sandbox the committed suite, and deny agent writes under the pub cache, the venv folder and the SDK.
- After S3 merges: move `qg_tracked`, the empty-argv `qg_tool` and one findings cap into `lib/qg-driver-kit.sh`.

## Refs

- [[2026-10-18-1903-qg-common-interface-s2]] — session 2, whose method this one follows.
- `vault/plans/2026-10-19-0930-qg-s4-flutter-drivers.md` — the S4 plan, decisions and open items.
- `vault/plans/2026-10-19-0930-qg-s4-flutter-drivers.trail.md` — review record.
- `vault/architecture/qg-dart-drivers.md` — the Dart driver catalogue.
- `vault/plans/2026-10-18-1121-qg-common-interface.md` — the master plan; S4 row.
