---
type: session
project: vault-quality-gates
date: 2026-10-19
topic: qg common interface — session 5 (non-code repos, doc-lint driver)
continues: [[2026-10-19-1300-qg-common-interface-s4]]
files_touched: [drivers/doc-lint.sh, lib/qg-driver-kit.sh, lib/qg-dart.sh, lib/qg-migrate.sh, bin/qg, templates/init/docs.tsv, extend/dod-keys.tsv, tests/unit/qg-driver-doc-lint.bats, tests/unit/qg-migrate.bats, tests/unit/qg-driver-kit.bats, tests/unit/qg-cli.bats, tests/fixtures/drivers/doc-lint/*, checks/qg-s5-SC-*.sh, vault/architecture/qg-builtin-drivers.md, vault/architecture/qg-cli.md, vault/architecture/qg-dart-drivers.md, ~/vault/givore/indications/quality-gate-binds-every-push.md, ~/vault/givore/indications/web/blocking-checks-live-in-checks-tsv.md]
decisions: []
tags: [session, quality-gate, qg, drivers, doc-lint, hugo]
---

# qg common interface — session 5 (non-code repos, doc-lint driver)

## Goal

Prepare `~/vault/givore` (doc-lint commit gate) and givore.com (hugo push gate) for `qg init`, and
make the two Givore gate indications name `qg`.

## Did

- Built on `feat/qg-docs-repos` in `~/workspace/vault-quality-gates-s5`, pushed at `108e9fb`. Plan
  `vault/plans/2026-10-19-1930-qg-s5-docs-repos.md`; handoff `vault/handoffs/2026-10-19-2300-qg-s5-docs-repos.md`.
- New built-in `drivers/doc-lint.sh`; `qg_kit_config_key` moved into the kit; `qg init` protects the
  five gate files by exact path, plus every tracked `.doc-lint` and `guard_doc_lint` for docs, and its
  `Next:` order is install, commit, doctor.
- Indications rewritten and committed in `~/vault/givore` at `42664b7`; one of them had never been
  committed before.
- Tests 705 → 716 (`./tests/run.sh tests/unit`). SC-1, SC-2, SC-5 met; SC-3 and SC-4 could not run,
  because `qg init` refuses an agent. The master row S5 stays `doing`.

## Learned

- The starter whole-file doc-lint row would have refused 82 of 103 recent vault commits: five shared
  files carry old findings, and `support/support-kb.md` (2431 lines, cap 400) grows by design.
- doc-lint walks up for `.doc-lint` and `VAULT.md` until a folder holding `.git`; `guard-tree` has
  none, so an untracked working-tree `.doc-lint` silenced the staged-tree lint.
- doc-lint treats a bare `plans/x.md` with no `type:` as outside the document folders; `./plans/x.md`
  is linted.
- `QG_FILES` holds A, C, M, R paths only; a type change (link to file) and a deletion never reach a
  driver that reads it.
- A caller's `BASH_ENV` runs before any gate script, so it can end a driver before it writes a result.
- The agent hook denies running `~/workspace/vault/bin/doc-lint.sh` (it cannot resolve
  `${SCRIPT_DIR}` in a `source` line) and allows the plugin-cache copy.

## Behaviors & rules

- A finding on an unchanged line, or a file-level code a parent already has → not counted.
- A commit's own `.doc-lint` or `VAULT.md`, at any depth, in any form (file, link, folder, deletion) → ignored by the lint and counted as `doc-lint.SKIPFILE`.
- A changed type as doc-lint reads it (`type:guide`, a blank line before `---`, a rename) → `doc-lint.TYPE`; edge: a merge keeping the second parent's type counts 0.
- A config path under a folder linked out of the measured tree → the row refuses and nothing is written there.
- `qg doctor` reads the committed config → it exits 1 until the init files are committed.

## Next

- Operator: `gate.sh verdict … --run` for SC-3 and SC-4, merge after `feat/qg-push-pass`, then both
  `qg init`s and close S5 (handoff items 1–6).
- Open: this repo's own v1 doc-lint row honours `DOC_LINT=off`; no session owns it.

## Refs

- `vault/plans/2026-10-19-1930-qg-s5-docs-repos.md` — the session plan.
- `vault/plans/2026-10-18-1121-qg-common-interface.md` — the master plan, row S5.
- `vault/architecture/qg-builtin-drivers.md` — the doc-lint counting rules.
