---
type: session
project: vault-quality-gates
date: 2026-11-04
topic: qg-baseline-acceptance-record
files_touched: [lib/guard-baseline-accept.sh, bin/guard.sh, bin/qg, lib/guard-commit.sh, lib/guard-metrics.sh, lib/guard-override.sh, lib/qg-refusal.sh, tests/unit/qg-baseline-accept.bats, tests/unit/qg-override.bats, tests/unit/qg-refusal.bats, vault/architecture/guard-baseline-accept.md, vault/architecture/guard-commit-gate.md, vault/architecture/guard-file-formats.md, vault/architecture/qg-cli.md, .claude-plugin/plugin.json]
decisions: []
tags: [session, guard, baseline, override]
---

# qg-baseline-acceptance-record

## Goal

Let an operator push a lowered `quality/baseline.tsv` that `qg baseline` wrote, closing
`vault/reports/2026-11-04-1626-lowered-baseline-cannot-be-pushed.md`.

## Did

- `lib/guard-baseline-accept.sh`: `qg baseline` at a terminal appends `<blob> <user> <epoch> <reason>`
  to `<git-common-dir>/qg-baseline-accept`. `guard_baseline_lock` replaces the two copies of the
  baseline-loosened check in `bin/guard.sh` (`guard_release_locked`) and `lib/guard-commit.sh`
  (`guard_gate_locked`), and passes a loosening whose blob has a record.
- `bin/guard.sh baseline` takes `--reason "<why>"` (default `qg baseline`) and parses options in a loop.
- `lib/qg-refusal.sh`: the footer names `qg baseline --reason` for `baseline-loosened` and no longer offers
  `--push <sha>` for a worse push row.
- `lib/guard-override.sh`: `qg override` refuses a commit token when nothing is staged.
- Tests: `tests/unit/qg-baseline-accept.bats` (operator path through installed hooks to a bare remote),
  one case in `tests/unit/qg-override.bats`, one assertion changed in `tests/unit/qg-refusal.bats`.
  Suite 998 tests; the two failures it showed were fixed and their files re-run green.
- Contract: `vault/architecture/guard-baseline-accept.md`. Plugin 0.1.2. Commit `ddb7e90` on `main`, not pushed.

## Learned

- `vault/architecture/guard-file-formats.md` and `guard-commit-gate.md` sit at the 200-line doc-lint cap;
  any addition there needs a split or a matching cut.
- `tests/unit/guard-baseline-locked.bats` asserts a push refusal never contains the word `accept`, so
  footer text must avoid it.
- api.mistflare.studio's hooks run `/home/kdabrow/workspace/vault-quality-gates/bin/guard.sh` directly,
  so this fix reached it without a plugin update.

## Behaviors & rules

- `qg baseline` by a human at a terminal → record written; the committed file passes commit and push.
- hand edit, or any edit after `qg baseline` → another blob → refused.
- `qg baseline` with no terminal, `CLAUDECODE`/`AI_AGENT` set, or under an agent grant → file written, no record.
- deleted baseline, or a `checks.tsv` that does not load → refused whatever the record says.
- `qg override` with an empty index → refused, no token written.

## Next

- The operator pushes api.mistflare.studio `main` (`d84b5e0`): `qg baseline --reason "<why>"` at a terminal, commit if the file changed, `git push`.
- The record is clone-local; CI `qg verify` still refuses a lowered baseline. Deciding a committed form is open.
- The operator pushes `ddb7e90`.

## Refs

- [[../reports/2026-11-04-1626-lowered-baseline-cannot-be-pushed]]
- [[../architecture/guard-baseline-accept]]
