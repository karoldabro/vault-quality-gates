---
type: session
project: vault-quality-gates
date: 2026-10-18
topic: qg common interface — session 2 (PHP drivers, recycling-api migration)
continues: [[2026-10-18-1346-qg-common-interface-s1]]
files_touched: [lib/qg-row.sh, lib/qg-driver.sh, lib/qg-driver-kit.sh, lib/guard-metrics.sh, lib/guard-commit.sh, lib/qg-explain.sh, lib/guard-parsers/junit.sh, bin/guard.sh, bin/guard-report-errors.sh, drivers/*.sh, migrations/recycling-api/*, checks/qg-parity-recycling-api.sh, checks/qg-s2-SC-*.sh, templates/init/php.tsv, vault/architecture/qg-builtin-drivers.md, vault/architecture/qg-driver-contract.md]
decisions: []
tags: [session, quality-gate, qg, drivers, php, migration]
---

# qg common interface — session 2 (PHP drivers, recycling-api migration)

## Goal

Add nine built-in PHP drivers, move the driver runtime into its own library, route driver findings
through one printer, and prepare recycling-api's 32 gate rows in the v2 format with a row-parity proof.

## Did

- Built on branch `feat/qg-php-drivers` in worktree `~/workspace/vault-quality-gates-s2`; not pushed.
- Moved the runtime to `lib/qg-driver.sh` and the row helpers to `lib/qg-row.sh`; drivers share
  `lib/qg-driver-kit.sh`.
- Drivers: pint, phpcs, phpmd, phpinsights, composer-dependency-analyser, phpunit, infection,
  jscpd-added, cloc; catalogue in `vault/architecture/qg-builtin-drivers.md`.
- Push refusals and `qg explain` print driver findings through `bin/guard-report-errors.sh --limit 10`;
  `guard.sh baseline --only` rewrites only the named rows.
- Prepared `migrations/recycling-api/` (v2 rows, `config`, `in-tree.sh`, `in-server.sh`,
  `lock-check.sh`, a v2-aware `ParallelWorkersCappedCheck.php`, `apply.sh`); the operator applies it.
- `checks/qg-parity-recycling-api.sh` exited 0: every kept id reads the v1 value and status on both
  seeds; five rows take new ids (`migrations/recycling-api/parity.tsv`). Tests 274 → 421.

## Learned

- recycling-api's `ParallelWorkersCappedCheck` reads `checks.tsv` column 4 by position; under v2 that
  is the driver name, so every driver row read as an un-niced tool (21 vs 33 violations).
- `jq --argjson` with 1,000+ findings exceeds the per-argument exec limit (128 KB) and made a row
  unmeasurable; findings now travel through a file.
- `cloc` skips a file it cannot count within a load-scaled time limit, so the same tree read 0.337 or
  0.345; the driver passes `--timeout 0`.
- v1's `phpstan` parser counts file errors only, so a PHPStan internal error read as 0 (clean).
- busybox `diff` prints unified format; `comm` is the portable way to diff two sorted lists.
- `$(( ))` on a report attribute runs a command hidden in it; numbers are validated (≤9 digits) first.
- A check script run by `gate.sh verdict --run` must close stdin, or a tool inside it eats the
  remaining criterion rows.

## Behaviors & rules

- A driver report left from an earlier run → never read; the kit deletes it before the tool runs.
- `files=changed` with no matching file → `metric: 0`, the tool never runs.
- `lines=added` → only findings on added lines count; a line-less or file-less finding prints, never counts; edge: phpstan with a file-less error → status error.
- A migrated row whose value changes on a seeded commit → new id, old id `kind: absent` naming it.
- Push gate with `guard_measure_worktree: false` → refuses uncommitted changes under `guard_protected_paths` as well as `guard_commit_paths`.
- `in-tree.sh` → a commit may change application packages in `composer.lock`, never a dev tool or anything a dev tool requires.

## Next

- Operator: push `feat/qg-php-drivers` and fast-forward `main`; run `migrations/recycling-api/apply.sh ~/workspace/recycling-api` and its six printed steps; baseline the renamed repo rows.
- Operator decision: pin the `recycling-api-server` image ID in a protected file, or accept the open item.
- S3 (web drivers) and S4 (Flutter) can start; S6 owns the `vendor/` write guard and the Stop hook push nag.

## Refs

- [[2026-10-18-1346-qg-common-interface-s1]] — session 1, the core this builds on.
- `vault/plans/2026-10-18-1500-qg-s2-php-drivers.md` — the S2 plan, verdicts and open items.
- `vault/plans/2026-10-18-1500-qg-s2-php-drivers.trail.md` — review record.
- `vault/plans/2026-10-18-1121-qg-common-interface.md` — the master plan; S2 closed.
- `vault/architecture/qg-builtin-drivers.md`, `vault/architecture/qg-driver-contract.md` — the contracts.
