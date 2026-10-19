---
type: plan
project: vault-quality-gates
slug: 2026-10-19-1940-qg-push-pass-record
repos: [vault-quality-gates]
status: proposed
process_record:
arch_spec:
human_plan:
session_of:
session:
tags: [plan, quality-gate, pre-push]
---

# Push pass record — plan

## Task

Let `pre-push` accept a pass that `qg run push --ref <ref>` recorded for the same commit, ref, bases
and engine, so `git push` sends at once instead of measuring while GitHub holds the connection open.
All code lands in worktree `~/workspace/vault-quality-gates-pushpass`, branch `feat/qg-push-pass`,
cut from `main` `3f43b43`.

Keywords: `templates/git-hooks/pre-push`, `cmd_release`, `cmd_run`, `guard_push_pass_key`,
`guard_baseline_base`, `guard_engine_digest`, `guard-pass/push/`.

**Priority when two qualities conflict:** no new bypass first, then the push verdict unchanged, then less code.

## Open & deferred

- needs the operator: merge `feat/qg-push-pass` into `main` of `~/workspace/vault-quality-gates` (the
  live gate runs from `main`'s working tree), then run `qg hooks install` in each gated repo. An
  installed `pre-push` is a copy; until it is reinstalled it measures on every push as today.
- needs the operator: SC-4, the push of recycling_mobile_app `release/1.17.0` over SSH.
- accepted: a forged record skips every push row, where a forged commit record skips only the
  unrecorded-commit check. Both are files in the git dir of the same user. The agent hooks deny a
  write whose text names `guard-pass` and any write inside the git dir; a deliberately obfuscated
  script that builds the path at run time still gets through, as it does for commit records today.
  The 60-minute lifetime bounds it. GitHub branch protection would close it and needs GitHub Pro.
- accepted: the record does not cover the machine's tool installs (`node_modules`, the pub cache, the
  Flutter SDK). A tool change within the 60 minutes after `qg run push` is not measured.

## Success criteria

| id | criterion | kind | how | check | expect | verdict | evidence |
|----|-----------|------|-----|-------|--------|---------|----------|
| SC-1 | WHEN `qg run push --ref <ref>` passes every row and `git push` then pushes that commit to that ref with the same bases and engine within 60 minutes THE SYSTEM SHALL accept the push without measuring; WHEN the sha, ref, row base, baseline base, engine files or age differ, or the run used `--only`, failed, or ran without `--ref`, THE SYSTEM SHALL measure as today | behaviour | command | `checks/qg-pp-SC-1.sh` | 0 | | |
| SC-2 | WHEN an agent command or edit writes under `<git-common-dir>/guard-pass/push/` THE SYSTEM SHALL deny it | behaviour | command | `checks/qg-pp-SC-2.sh` | 0 | | |
| SC-3 | WHEN the unit suite runs, the `43d7082` hook bodies included THE SYSTEM SHALL pass every test | regression | command | `checks/qg-pp-SC-3.sh` | 0 | | |
| SC-4 | WHEN the operator runs `qg run push --ref refs/heads/release/1.17.0` and then `git push -u origin release/1.17.0` in `~/workspace/recycling_mobile_app` THE SYSTEM SHALL print that the commit already passed and land the branch on `origin` | delivery | observed | operator procedure: after the merge and `qg hooks install`, run both commands; fails when `pre-push` prints `measuring 57 rows` again or the connection closes; no-command: the push goes to the real GitHub remote, which the operator pushes | branch on `origin` | | |

## Definition of done

| id | line | state | evidence |
|----|------|-------|----------|
| DOD-tests | `./tests/run.sh tests/unit` exits 0 | | |
| DOD-lint | `bin/doc-lint.sh` on the three architecture docs and this plan exits 0 | | |
| DOD-shellcheck | `shellcheck` on every changed script exits 0 | | |

## Verified current state

- `templates/git-hooks/pre-push` calls `guard.sh release <remote ref>` with `GUARD_SHA` and `GUARD_BASE` after git has opened the connection; nothing caches a pass · read · 2026-10-19
- `cmd_run push` (`bin/qg:146`) runs `GUARD_SHA=HEAD guard.sh release <ref>`, ref `-` by default, without `GUARD_BASE`, so its baseline check uses the merge-base where `pre-push` uses the remote tip · read · 2026-10-19
- recycling_mobile_app push of `de4663d7`: 55 of 57 rows printed `ok`, then `Connection to github.com closed by remote host`; `release/1.17.0` is not on `origin` · `git ls-remote` · 2026-10-19
- `guard_bash.py` `NEEDLES` contains `guard-pass` (`templates/claude-hooks/guard_bash.py:14`) · read · 2026-10-19
- An installed hook older than the template keeps working and `qg doctor` reports it not current (`tests/unit/qg-old-hooks.bats`, `lib/qg-doctor.sh:35`) · read · 2026-10-19

## Decisions

| decision | reason | record |
|----------|--------|--------|
| The record key is SHA-1 of `push <remote ref> <sha> <row base> <baseline base> <engine digest>` | each input changes which rows run or what they compare against | local |
| Engine digest = SHA-1 over the contents of every file under the engine's `bin/`, `lib/`, `drivers/` | the engine runs from a working tree that may hold uncommitted edits | local |
| A record lives under `<git-common-dir>/guard-pass/push/<key>`, holds `ok <epoch>`, and is valid 60 minutes, not consumed on use | a push that drops after the check can retry; the window bounds tool drift | local |
| Only `qg run push --ref <ref>` with no `--only`, no config pin, and exit 0 writes a record | ref `-` skips the accept-limit check and `--only` is partial | local |
| `qg run push --ref` computes the baseline base the way `pre-push` does, from `refs/remotes/<upstream remote>/<branch>` | the keys must match; a remote tip that moved gives a different key and a fresh measurement | local |
| `pre-push` reads records through a `--use-pass` flag; `qg run push` never reads one | a human who runs `qg run push` wants a fresh measurement | local |

## Scope & non-goals

Covers the record, its writer (`qg run push --ref`), its reader (`pre-push`), the agent-hook denial,
the stop-hook text and the docs. Not covered: SSH keep-alive settings, a `qg push` wrapper, records
for the commit gate, and server-side enforcement.

## Artifact lifecycles

| artifact | what requires it | who writes it | who reads it | missing or wrong |
|---|---|---|---|---|
| `<git-common-dir>/guard-pass/push/<key>` | `cmd_release --use-pass` in `bin/guard.sh`, called by `templates/git-hooks/pre-push` | `cmd_release --record-pass`, called by `cmd_run` in `bin/qg` | `guard_push_pass_valid` in `lib/guard-pass.sh` | absent, unparsable, a non-numeric or future epoch, or older than 3600 s → the push measures every row as today |
| `--use-pass` / `--record-pass` flags of `guard.sh release` | `templates/git-hooks/pre-push`, `bin/qg` `cmd_run` | `templates/git-hooks/pre-push`, `bin/qg` | `bin/guard.sh` argument parser | an old installed `pre-push` passes neither → measures as today; after W-1a an unknown flag → `guard.sh` exits 2 with usage and the push is refused |
| the stop-hook push instruction | an agent session ending with unpushed commits | `templates/claude-hooks/guard-stop.sh` | the agent | an agent that skips `qg run push` pushes and measures as today |

## Work items

| id | file (exact path) | action | tool | constraint | covers | verification | status |
|----|-------------------|--------|------|------------|--------|--------------|--------|
| W-0 | `checks/qg-pp-SC-1.sh`, `checks/qg-pp-SC-2.sh`, `checks/qg-pp-SC-3.sh` | committed checks naming the test cases | Write | through `checks/_qg-cases.sh` | SC-1 SC-2 SC-3 | `gate.sh verdict --run` | DONE |
| W-1a | `bin/guard.sh` | the `release` parser refuses any unknown `-*` argument with usage and exit 2, in its own commit before W-2 | Edit | a revert of the feature keeps this commit | SC-1 | `tests/unit/qg-push-pass.bats` T-12 | TODO |
| W-1 | `lib/guard-pass.sh` | add `guard_baseline_base <local sha> <remote sha>` (moved from `pre-push`); `guard_engine_digest` = SHA-1 over `<path> <mode> <blob hash>` of every file under the engine's `bin/`, `lib/`, `drivers/`, recursive, `LC_ALL=C` sorted; `guard_push_pass_key`; `guard_push_pass_write` (temp file then `mv`, deletes records older than 3600 s); `guard_push_pass_valid` | Edit | key and lifetime as in Decisions | SC-1 | `tests/unit/qg-push-pass.bats` | TODO |
| W-2 | `bin/guard.sh` | `release` takes `--use-pass` and `--record-pass`; `cmd_release` computes the key after choosing rows and the base; `--use-pass` with a valid record and an empty `GUARD_CONFIG_PIN` prints `vault-guard: <ref> at <sha12> passed qg run push <N> min ago; not measured again` and exits 0; `--record-pass` re-runs `guard_release_tree_matches`, then writes the record after a full pass when ref is not `-`, `GUARD_ONLY` is empty and `GUARD_CONFIG_PIN` is empty; a failed write prints `vault-guard: pass record not written; git push will measure again` and keeps exit 0 | Edit | no flag → behaviour unchanged | SC-1 SC-3 | `tests/unit/qg-push-pass.bats`, `tests/unit/guard-hooks.bats` | TODO |
| W-3 | `templates/git-hooks/pre-push` | call `guard_baseline_base` from the lib; call `guard.sh release --use-pass "$gated_ref"`, flag before the ref, so an engine without the flag still reads the real ref | Edit | stdin still drained before any exit | SC-1 SC-4 | `tests/unit/guard-hooks.bats` | TODO |
| W-4 | `bin/qg` | `cmd_run push` with `--ref` and no `--only`: unset `GUARD_SKIP GUARD_CONFIG_REV GUARD_CONFIG_AT GUARD_CONFIG_PIN`, set `GUARD_BASE` with `guard_baseline_base` from `refs/remotes/<remote>/<branch>`, where `<remote>` is `branch.<branch>.remote`, else `origin`; pass `--record-pass`; print `qg: recorded; git push of <sha12> to <ref> within 60 minutes skips the measurement`; without `--ref`, print the `--ref refs/heads/<branch>` hint after a pass; update `qg help run` | Edit | ref `-` behaviour unchanged | SC-1 SC-4 | `tests/unit/qg-push-pass.bats`, `tests/unit/qg-cli.bats` | TODO |
| W-11 | `templates/claude-hooks/guard_bash.py` | `scan_program` sets a `qg` flag for `qg` and `bin/qg`; deny any `ENV_REDIRECT` name (`PATH`, `HOME`, `XDG_CONFIG_HOME`) set for it, as a prefix or through `export` | Edit | existing git and `guard.sh` denials unchanged | SC-2 | `tests/unit/guard-claude-hooks.bats` T-11 | TODO |
| W-5 | `templates/claude-hooks/guard-stop.sh` | both push instructions run `qg run push --ref refs/heads/<branch>` first, then `git push -u origin <branch>` | Edit | wording only | SC-3 | `tests/unit/qg-claude-hooks.bats` | TODO |
| W-6 | `tests/unit/qg-push-pass.bats` | one test per Test-backlog row T-1..T-9 | Write | fixtures from `tests/unit/guard-helpers.bash` | SC-1 | `./tests/run.sh tests/unit/qg-push-pass.bats` | TODO |
| W-7 | `tests/unit/guard-claude-hooks.bats` | T-10: a Bash redirect and a `Write` into `.git/guard-pass/push/<key>` are denied | Edit | | SC-2 | `./tests/run.sh tests/unit/guard-claude-hooks.bats` | TODO |
| W-8 | `vault/architecture/guard-commit-gate.md` | `pre-push` row and a `Push pass record` paragraph: key, lifetime, writer, reader | Edit | state once | SC-1 | `bin/doc-lint.sh` | TODO |
| W-9 | `vault/architecture/guard-file-formats.md` | add the `guard-pass/push/<key>` row to the git-dir file table | Edit | | SC-1 | `bin/doc-lint.sh` | TODO |
| W-10 | `vault/architecture/qg-cli.md` | `qg run push --ref` records a pass | Edit | | SC-1 | `bin/doc-lint.sh` | TODO |

## Rollback

`git revert` the feature commits on `main` of `~/workspace/vault-quality-gates`, keeping the W-1a
commit. A reinstalled `pre-push` then passes `--use-pass` to an engine that refuses it with exit 2,
so every push is refused until the operator runs `qg hooks install` again in each gated repo. Leftover record files are ignored and harmless; delete
`<git-common-dir>/guard-pass/push/` to clear them.

## Test plan

Bats in Docker through `./tests/run.sh`. Each test builds a repo with `guard-helpers` fixtures, a
bare remote, a stub row that counts its runs in a file, and installs the hooks. "Measured" means the
counter moved.

## Test design dossier

| input differs from the record | row base | baseline base | engine | expected |
|---|---|---|---|---|
| nothing, age < 60 min | same | same | same | accepted, counter unchanged |
| sha (amended commit) | — | — | — | measured |
| remote ref name | same | same | same | measured |
| remote tip moved | same | differs | same | measured |
| a file under `lib/` edited | same | same | differs | measured |
| age 61 min, or epoch in the future | same | same | same | measured |

Writer partitions: `--only` · exit 1 · exit 2 · ref `-` · `GUARD_CONFIG_PIN` set → no record.

## Test backlog

| id | source | kind | target (exact path) | intent | priority | disposition |
|----|--------|------|---------------------|--------|----------|-------------|
| T-1 | W-2 W-4 | unit | `tests/unit/qg-push-pass.bats` | `qg run push --ref` then `git push`: counter moves once, push lands, pre-push prints the not-measured line | must | |
| T-2 | W-2 | unit | `tests/unit/qg-push-pass.bats` | amended commit after the record → measured | must | |
| T-3 | W-2 | unit | `tests/unit/qg-push-pass.bats` | push to another ref name → measured | must | |
| T-4 | W-1 | unit | `tests/unit/qg-push-pass.bats` | remote tip moved after the record → measured | must | |
| T-5 | W-1 | unit | `tests/unit/qg-push-pass.bats` | an engine `lib/` file changed after the record → measured | must | |
| T-6 | W-1 | unit | `tests/unit/qg-push-pass.bats` | record older than 3600 s, dated in the future, or holding junk → measured | must | |
| T-7 | W-4 | unit | `tests/unit/qg-push-pass.bats` | `--only`, a worse row, an unmeasurable row, and no `--ref` write no record | must | |
| T-8 | W-2 | unit | `tests/unit/qg-push-pass.bats` | a recorded pass with a worse baseline against the remote tip is never written: the writer's baseline check uses the remote tip | must | |
| T-9 | W-3 | unit | `tests/unit/qg-push-pass.bats` | an old installed `pre-push` (no flag) measures even with a valid record | should | |
| T-10 | W-7 | unit | `tests/unit/guard-claude-hooks.bats` | agent writes into `guard-pass/push/` are denied | must | |
| T-11 | W-11 | unit | `tests/unit/guard-claude-hooks.bats` | `PATH=… qg run push --ref`, `HOME=… qg …` and `export PATH=…; qg …` are denied for an agent | must | |
| T-12 | W-1a W-3 | unit | `tests/unit/qg-push-pass.bats` | `guard.sh release --bogus <ref>` exits 2; an engine without `--use-pass` given `release --use-pass <ref>` refuses rather than passing | must | |

## Refs

- `vault/architecture/guard-commit-gate.md` — the hooks and the commit pass record this mirrors.
- `vault/architecture/guard-file-formats.md` — the git-dir file table the record joins.
- `vault/plans/2026-10-18-1121-qg-common-interface.md` — master plan; S6 owns the server-side gap.
