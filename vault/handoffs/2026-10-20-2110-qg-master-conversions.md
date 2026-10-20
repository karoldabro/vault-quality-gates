---
type: handoff
project: vault-quality-gates
slug: qg-master-conversions
date: 2026-10-20
status: open
session:
plan: vault/plans/2026-10-20-1022-qg-s6-agent-hooks.md
continues: qg-agent-grant
tags: [handoff]
---

# qg-master-conversions — handoff

The agent grant (`qg grant`) and the vitest sandbox fix are on local `main` of
`~/workspace/vault-quality-gates`. The v2 gate config is committed, not pushed, on `master` in
recycling-api and app.givore.com. Each waits for a code fix of the rows its baseline measured worse.
recycling_mobile_app `master` and the S6 close wait for SC-3.

## Left to do

| # | action | file (exact path) | done when |
|---|--------|-------------------|-----------|
| 1 | wait for the recycling-api fix session; it pushes `fix/quality-master-regressions` from `~/workspace/recycling-api-master`. When it reports a v1/v2 counting difference instead, file it with `/v-report` against vault-quality-gates and stop this row | `~/workspace/recycling-api-master` | the branch is on origin and the report gives each row equal to or better than: indication-checks 21, duplication-clones 392, insights-complexity 83.5 |
| 2 | wait for the app.givore.com fix session; it pushes `fix/quality-master-typecheck` from `~/workspace/app.givore.com-master`. A driver counting bug goes to `/v-report` as in row 1 | `~/workspace/app.givore.com-master` | the branch is on origin and the report gives typecheck-errors 42 or less |
| 3 | per repo, once its row above is done: `git merge --ff-only <fix branch>` on `master` in the worktree; `qg baseline --skip '^(mutation\|tests-suite\|coverage)$'` (app: `tests-suite-failed` instead of `tests-suite`); review `git diff quality/baseline.tsv` (no row worse than the committed value); commit `quality/baseline.tsv`; `git log --oneline origin/master..master` lists only `chore(quality)` and the fix commits; `qg run push --ref refs/heads/master`; `git push origin master` | `~/workspace/recycling-api-master/quality/baseline.tsv`, `~/workspace/app.givore.com-master/quality/baseline.tsv` | `git -C ~/workspace/<repo> show origin/master:quality/config` succeeds |
| 4 | remove the worktrees: `git -C ~/workspace/recycling-api worktree remove --force ~/workspace/recycling-api-master`, `git -C ~/workspace/app.givore.com worktree remove --force ~/workspace/app.givore.com-master` | both worktrees | `git worktree list` in each repo no longer lists them |
| 5 | set `"priority": "master"` for recycling-api and app.givore.com | `~/agent-factory/nightly-baselines.json` | `./agentctl check-config` in `~/workspace/agent-control` passes |
| 6 | find why last night's recycling-api run failed: `qg-suite exited 2: tests-suite: env exited 255` | `~/agent-factory/nightly/recycling-api/20261020-003745/logs/` | the next night's `result.json` reads `green` or `red`, not `error` |
| 7 | after the SC-3 run ends: merge `main` into `feat/qg-s6-agent-hooks` (it lacks the grant and `6b6b772`, the vitest fix); move SC-3, SC-7 and SC-8 to S7 | `~/sc3-verdict.log`, `vault/plans/2026-10-20-1022-qg-s6-agent-hooks.md` | the S6 plan lists SC-1, SC-2 and SC-4..SC-6 only |
| 8 | recycling_mobile_app `master`, after row 7: rows 9 and 3 of `vault/handoffs/2026-10-20-1906-qg-agent-grant.md` and row 3 here: copy `quality/` from `de4663d`, then commit the config before the baseline | `~/workspace/recycling_mobile_app-master/quality/` | `git -C ~/workspace/recycling_mobile_app show origin/master:quality/config` succeeds |
| 9 | split S6 and close it: rows 10 and 11 of `vault/handoffs/2026-10-20-1906-qg-agent-grant.md` | `vault/plans/2026-10-20-1022-qg-s6-agent-hooks.md`, `vault/plans/2026-10-18-1121-qg-common-interface.md` | the close gate exits 0 and the S6 row reads `done` |
| 10 | operator: push `main` of `~/workspace/vault-quality-gates` (`origin/main` is `2978d66`, without S6, the grant or the vitest fix) | `~/workspace/vault-quality-gates` | `git -C ~/workspace/vault-quality-gates status -sb` shows no `ahead` |

## Do not touch

- `vault/plans/2026-10-20-1022-qg-s6-agent-hooks.md` while `~/sc3-verdict.log` lacks its final `gate:` line: the background `gate.sh verdict --run` writes into it.
- `qg baseline` or `qg run` in `~/workspace/recycling_mobile_app` until row 7: both write `~/.pub-cache`, and SC-3 fails when that cache changes during its run.
- `quality/baseline.tsv` in both `-master` worktrees: the fix sessions measure there and restore it. Never commit it before row 3.
- `graphify-out/` in `~/workspace/app.givore.com-master`: a background graph rebuild changed it. Never stage it.
- Every branch except `master` and the newest release branch in each repo. Never merge a release branch into `master`; copy files with `git checkout <sha> -- quality`.
- `feat/qg-s6-v1-removal`: it belongs to S7.
- recycling-api `release/1.19.0`: 36 local commits not on any remote; pushing them is the operator's call.

## Unverified

- The refusal footer in `lib/qg-refusal.sh` tells an agent "Agents may not override" while a grant is live. Read `qg_print_refusal` and decide whether it should name the grant.
- `qg doctor` warns `qg is not on PATH` although `~/.local/bin/qg` links to `bin/qg`. Reading `lib/qg-doctor.sh` and `lib/qg-clean-env.sh` settles it.
- The skipped rows (mutation, test suite, coverage) keep master's committed values; nothing measured them on the v2 config. The first `green` or `red` nightly run on `master` after row 5 settles it.

## Goal

recycling-api, app.givore.com and recycling_mobile_app carry v2 gate config on `origin/master`, and S6 is closed with SC-7 and SC-8 moved to S7.

## Task

The operator asked for a time-limited permission that lets an agent run the gate-changing steps itself, then to finish converting `master` in recycling-api, app.givore.com and recycling_mobile_app, and nothing more.

## Requirements

- A baseline commit never loosens a row against master's committed value; the pre-push check refuses that even after an override (`templates/git-hooks/pre-push`).
- Pushing `master` is allowed; merging a release branch into `master` is never allowed.
- Never edit `quality/baseline.tsv`, `quality/checks.tsv`, `quality/config` or `quality/drivers/` to make a gate pass (`templates/claude-hooks/guard-stop.sh`).
- Agent steps that run `qg baseline` or `qg override` need a live grant: the operator runs `qg grant --agent <duration> baseline,override,push` in a separate terminal (`vault/architecture/qg-cli.md`, `## The agent grant`).

## Next command

```
qg grant --status && tail -5 ~/sc3-verdict.log
```

## Blockers

- Rows 1 and 2: the two fix sessions the operator started.
- Rows 3 and 8 need a live grant; the one issued at 19:32 expired at 21:32.
- Row 10: pushing `main` is human-only.

## Done

- `a62e811` `feat(qg)` agent grant: `lib/qg-grant.sh`, `qg grant --agent/--status/--revoke`, the grant read by `bin/qg`, `lib/guard-override.sh` and `templates/claude-hooks/guard_bash.py`. The full suite passes, 1031 of 1031 (`./tests/run.sh tests/unit`).
- `6b6b772` `fix(qg)` vitest driver passes `--configLoader runner`; the default loader writes `vitest.config.ts.timestamp-*.mjs`, which the sandbox refuses.
- The operator merged both into `main`.
- recycling-api `558d8c6d` and app.givore.com `25ae22a`: the v2 config, committed under the grant with `qg override`. app.givore.com `master` was fast-forwarded to `origin/master` first (37 commits behind), and `25ae22a` adds `"precommit": "lint-staged"` to `package.json`, which the repo's `pre-commit.user` hook runs.
- `~/workspace/recycling-api-master` holds `vendor/` (`composer install --ignore-platform-reqs`; the host PHP is 8.3, the container's 8.4) and a `.env` copied from `~/workspace/recycling-api`.

## Direction

- Commit the gate config first and baseline second: a runner script must be committed before the gate runs it (`runner quality/bin/in-server.sh is not committed at the config revision`).
- Baseline with `--skip` for mutation, the test suite and coverage: a full `qg baseline` drops every row it cannot measure, and a dropped `repo` row counts as loosening. The nightly run measures the suite and coverage.
- Code debt never blocks the migration. A row still worse after the fix sessions is reset: commit the measured baseline under the grant's override, and the operator pushes `master` with `git push --no-verify origin master`. The push gate refuses a looser baseline with no override (`guard_release_locked` in `bin/guard.sh`).
- SC-3 is no condition for closing S6. It moves to S7 with SC-7 and SC-8, and runs there as a nightly job.
- The operator batches human steps: one grant and one push round per day.
