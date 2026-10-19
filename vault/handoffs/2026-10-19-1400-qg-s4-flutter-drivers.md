---
type: handoff
project: vault-quality-gates
slug: qg-s4-flutter-drivers
date: 2026-10-19
status: open
session: vault/sessions/2026-10-19-1300-qg-common-interface-s4.md
plan: vault/plans/2026-10-19-0930-qg-s4-flutter-drivers.md
continues:
tags: [handoff]
---

# qg-s4-flutter-drivers — handoff

S4 is built and pushed on `feat/qg-flutter-drivers`, but recycling_mobile_app cannot use it yet: the
parity proof never ran, the branch is not on `main`, and `apply.sh` refuses without a proven
`parity.tsv`.

## Left to do

| # | action | file (exact path) | done when |
|---|--------|-------------------|-----------|
| 1 | operator runs the verdict gate from `~/workspace/vault-quality-gates-s4`; it runs SC-1..SC-6, the parity proof included, and writes each verdict into the plan | `vault/plans/2026-10-19-0930-qg-s4-flutter-drivers.md` | every `## Success criteria` row reads `MET`, and `migrations/recycling_mobile_app/parity.tsv` exists with only SAME or NEW verdicts |
| 2 | fix what the first parity run breaks: seed files, the stand-in SDK the script builds, or jscpd without network; rerun item 1 | `checks/qg-parity-recycling_mobile_app.sh` | item 1 passes; a kept row that reads DIFF takes a new id in `migrations/recycling_mobile_app/checks.tsv`, never a looser parity rule |
| 3 | commit `parity.tsv` and the plan verdicts, then close master row S4 | `vault/plans/2026-10-18-1121-qg-common-interface.md` | `pm-plan.sh set … S4 status=done date=<day> evidence=<sha>`; `gate.sh all <S4 plan> --phase close` exits 0 |
| 4 | operator merges `feat/qg-flutter-drivers` into `main` of `~/workspace/vault-quality-gates` (the live gate runs from `main`'s working tree) | `~/workspace/vault-quality-gates` | `ls ~/workspace/vault-quality-gates/drivers/dart-analyze.sh` succeeds |
| 5 | operator runs `migrations/recycling_mobile_app/apply.sh ~/workspace/recycling_mobile_app` and the six steps it prints, on `release/1.17.0` | `~/workspace/recycling_mobile_app/quality/` | the migration commit lands under `qg override`, `qg baseline --only <new ids>` is committed, and `qg run push` passes |

## Do not touch

- `~/workspace/vault-quality-gates-s3` and branch `feat/qg-web-drivers`: session S3 is mid-execution there with uncommitted parity files (`git -C ~/workspace/vault-quality-gates-s3 status --short`).
- `~/workspace/recycling_mobile_app` `quality/`, `VAULT.md`, `analysis_options*.yaml`: the agent guards forbid an agent these edits; only `apply.sh` run by the operator changes them.
- `migrations/recycling_mobile_app/config` `guard_flutter_root`: it names this machine's SDK, `/home/kdabrow/workspace/flutter/flutter`; another value makes every Dart row refuse.

## Unverified

- `checks/qg-parity-recycling_mobile_app.sh` (739 lines) has never run; the agent hook blocks an agent from running the S4 engine. Item 1 settles it.
- The SC-1..SC-6 verdicts are empty. Their unit cases pass (658 tests, `./tests/run.sh tests/unit`), but `gate.sh verdict --run` has not recorded them. Item 1 settles it.
- No v2 row has measured the live mobile repo through the real engine; only the drivers' tool commands ran on a scratch clone at `884aad23`. Item 1 settles it.
- `pnpm dlx jscpd@5.3.2` under `unshare -rn`: `unshare -rn` fails on this host, so the parity run warns and keeps network. Item 1 shows it.

## Goal

recycling_mobile_app's gate runs on v2 rows and the Flutter drivers, with every kept row proven to give its v1 value.

## Task

"Continue the quality gates plan S4". Master plan row S4 asks for Flutter drivers and recycling_mobile_app rows.
The drivers: dart analyze with the givore lint runner, flutter analyze, dart format, dart_code_linter, layerlens, lakos, flutter test with lcov, mutation_test, copydetect, grep-count.
It drops the realse alternative, and the operator makes the migration commit.

## Requirements

- No new bypass, then a row's verdict unchanged by the migration, then less code (`vault/plans/2026-10-19-0930-qg-s4-flutter-drivers.md`).
- A kept id must read the same value as v1 on a seeded commit, else it takes a new id (`vault/plans/2026-10-18-1121-qg-common-interface.md`, Decisions).
- Agents never run `qg migrate`, `qg init`, `apply.sh` on a real checkout, or commit under `quality/drivers/` or `quality/config` (master plan, Open & deferred).
- Driver behaviour per `vault/architecture/qg-dart-drivers.md` and `vault/architecture/qg-driver-contract.md`.

## Next command

```
cd ~/workspace/vault-quality-gates-s4 && /home/kdabrow/.claude/plugins/cache/kdabro-vault/vault/1.13.0/bin/gate.sh verdict vault/plans/2026-10-19-0930-qg-s4-flutter-drivers.md --run
```

## Blockers

- Items 1, 4 and 5 need the operator: the repo's agent hook refuses any script that sets `GUARD_*` or `QG_*`, which covers the engine and every `checks/*.sh`.

## Done

- Eleven drivers in `drivers/`, `lib/qg-dart.sh`, engine `QG_CONFIG_REV`, baseline in a detached worktree, `qg init --profile flutter` writing `guard_flutter_root`; migration files in `migrations/recycling_mobile_app/`. Built in the S4 worktree, committed through the repo's own commit gate, pushed to `origin/feat/qg-flutter-drivers` at `a967441`.
- Tests: bats in Docker through `./tests/run.sh tests/unit`; driver fixtures recorded from real tool runs in `tests/fixtures/drivers/dart/`.

## Direction

- The pushed suite can plant code in the pub cache, the SDK and `guard-cache`; v1 has the same reach. `bwrap` fails here, so S6 owns the sandbox (master plan S6 row). Do not reopen it in S4.
- `duplication-new` stays shell, so a jscpd that cannot start still passes the warn row as v1 does.
- S3 edits the same catalogue, contract and `templates/init/` lines; the second branch to merge resolves them by hand.
