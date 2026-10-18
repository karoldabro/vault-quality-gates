---
type: session
project: vault-quality-gates
date: 2026-10-18
topic: qg common interface — session 1 (core)
files_touched: [bin/qg, bin/guard.sh, bin/guard-report-errors.sh, lib/guard-metrics.sh, lib/guard-commit.sh, lib/guard-override.sh, lib/guard-hook.sh, lib/guard-pass.sh, lib/qg-events.sh, lib/qg-config.sh, lib/qg-refusal.sh, lib/qg-explain.sh, lib/qg-doctor.sh, lib/qg-migrate.sh, drivers/phpstan.sh, drivers/shell.sh, templates/git-hooks/pre-push, templates/claude-hooks/guard_bash.py, templates/claude-hooks/guard-edit.sh, templates/claude-hooks/guard-stop.sh, templates/init/*.tsv, checks/qg-SC-*.sh]
decisions: [ADR-001-driver-contract]
tags: [session, quality-gate, qg, drivers]
---

# qg common interface — session 1 (core)

## Goal

Give the gate one interface a human and an agent both operate (`qg`), a driver contract, a per-row
`on` event, and refusals that say why and how to pass, built in `vault-quality-gates`.

## Did

- Surveyed 21 existing tools; none blocks an agent's bypass up front or keeps a committed cross-tool
  baseline, so the runner stays here: `vault/research/2026-10-18-gate-tools-survey.md`.
- Shipped a live bypass fix alone first (`2526467`): an inherited `GUARD_SKIP` skipped every push row,
  and an agent-set `GUARD_CONFIG_REV` chose an older config.
- Built on branch `feat/qg-interface` in worktree `~/workspace/vault-quality-gates-qg`, then
  fast-forwarded `main` to `8244c84`: v1/v2 row loader with named fields, `on` grammar, one config
  reader (`quality/config` else `VAULT.md`), driver runner, `qg` CLI, refusal printer, tree-bound
  override token, agent guards for every new surface, five `qg init` profiles, `qg migrate`.
- Tests 183 → 274. SC-1..SC-10 MET via `gate.sh verdict --run`. `checks/qg-SC-8.sh` matched
  `43d7082` row for row on all four Givore repos' commit gates, and on dashboard, app and mobile push
  gates (84 rows).

## Learned

- The 2026-10-17 refusal in recycling-api had two causes: `in-tree.sh` compares `vendor/` with
  `HEAD:composer.lock`, so any `composer.lock` change is unmeasurable; and
  `QG_SKIP_REASON="x" && git commit` never exports the variable, so the hook saw no override.
- `IFS=$'\t' read` merges empty cells, because tab is IFS whitespace; an empty v2 cell shifted every
  later field and turned a refusing gate into a pass. Rows now split on `\037`.
- Installed hook bodies are copies; only `lib/` changes reach them live. The `43d7082` bodies are kept
  in `tests/fixtures/hooks-43d7082/` and tested against the new engine.
- `guard.sh release <ref>` now picks rows itself; before, only the hook filtered by
  `guard_release_pattern`, and a direct call measured every release row.

## Behaviors & rules

- A pushed ref no row's `on` names → exit 0 before any config or tree check; the baseline lock still runs.
- A v2 row with an empty cell, a blank or `TODO` why, or an unknown kind, direction or gate → does not load; staged → `gate-config-invalid`.
- A commit changing `quality/drivers/` or `quality/config` → refused (`gate-config-changed`) unless a human overrides.
- A repo driver is read only from the config revision; a repo driver named like a built-in → refused.
- `qg override` token → passes once, within 600 s, only the exact index tree or pushed sha it names. The hook process must be a human at a terminal; edge: a push token lifts only the unrecorded-commit check.
- A driver result with no `result.json`, `status` other than `measured`, `error` set, or a non-number `metric` → unmeasurable, never 0.
- A refusal → per row why, reproduce command and `qg explain`; each distinct tool output once; footer never cut; ≤3500 characters.

## Next

- Operator: `ln -s ~/workspace/vault-quality-gates/bin/qg ~/.local/bin/qg`; `qg hooks install --claude` then `qg doctor` in recycling-api, recycling_mobile_app, app.givore.com, dashboard.givore.com and vault-quality-gates.
- Re-run `checks/qg-SC-8.sh --release ~/workspace/recycling-api` on a clean api checkout.
- S2 (PHP drivers + api migration) starts from the plan's `## Sessions` row; it first moves the driver runtime into `lib/qg-driver.sh`.

## Refs

- `vault/plans/2026-10-18-1121-qg-common-interface.md` — the plan and the S2–S6 sessions.
- `vault/plans/2026-10-18-1121-qg-common-interface.trail.md` — review record.
- `vault/decisions/ADR-001-driver-contract.md` — driver contract and `qg.result/1`.
- `vault/architecture/qg-driver-contract.md`, `vault/architecture/qg-cli.md` — the contracts.
