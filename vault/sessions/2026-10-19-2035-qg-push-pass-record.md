---
type: session
project: vault-quality-gates
date: 2026-10-19
topic: qg push pass record
files_touched: [bin/guard.sh, bin/qg, lib/guard-pass.sh, templates/git-hooks/pre-push, templates/claude-hooks/guard_bash.py, templates/claude-hooks/guard-stop.sh, tests/unit/qg-push-pass.bats, tests/unit/guard-claude-hooks.bats, tests/unit/guard-hooks.bats, vault/architecture/guard-push-pass.md, vault/architecture/guard-commit-gate.md, vault/architecture/guard-file-formats.md, vault/architecture/qg-cli.md, checks/qg-pp-SC-1.sh, checks/qg-pp-SC-2.sh, checks/qg-pp-SC-3.sh]
decisions: []
tags: [session, quality-gate, pre-push]
---

# qg push pass record

## Goal

Stop a slow push gate from losing the GitHub connection: `qg run push --ref` records a pass that `pre-push` accepts.

## Did

- Built the push pass record on branch `feat/qg-push-pass` (`fbbc3dc`, pushed), worktree `~/workspace/vault-quality-gates-pushpass`, cut from `main` `3f43b43`. Contract: `vault/architecture/guard-push-pass.md`. Plan: `vault/plans/2026-10-19-1940-qg-push-pass-record.md`.
- `guard.sh release` refuses an unknown flag with exit 2 (`2d77c9d`, its own commit).
- `templates/claude-hooks/guard_bash.py` denies `PATH`, `HOME`, `XDG_CONFIG_HOME` set for `qg`.
- `templates/claude-hooks/guard-stop.sh` tells an agent to run `qg run push --ref refs/heads/<branch>` before `git push`.
- SC-1..SC-3 MET through `gate.sh verdict --run`; unit suite 670 ok.

## Learned

- recycling_mobile_app `release/1.17.0` (`de4663d7`) never reached `origin`: 55 of 57 push rows passed, then `Connection to github.com closed by remote host` during the Flutter test rows. git opens the connection before `pre-push` runs, so any gate longer than the host's idle limit loses the push.
- Before this change, `qg run push` measured with `GUARD_BASE` unset (merge-base) while `pre-push` uses the remote tip, so the two could disagree on `baseline-loosened`.
- Before this change, `guard.sh release` read any unknown argument as the ref; an unknown flag named a ref no row runs on and passed the push unmeasured.
- Before this change, `PATH=/shim qg run push` was allowed for an agent; harmless only while `git push` measured again.
- The agent hook denies an agent any git, `shellcheck` or `docker` command that names `lib/guard-pass.sh` or `templates/claude-hooks/guard-stop.sh` (needles `guard-pass`, `guard-stop`). The operator commits changes to those files.

## Behaviors & rules

- `qg run push --ref <ref>` passes every row → record `guard-pass/push/<key>` written; edge: `--only`, ref `-`, exit 1 or 2, config pin → no record.
- `git push` of the recorded sha to the recorded ref within 3600 s, remote tip and engine unchanged → `pre-push` prints `not measured again` and exits 0.
- A changed input, or an expired, future-dated or malformed record → `pre-push` measures.
- `guard.sh release --<unknown>` → exit 2, push refused.
- An installed `pre-push` that predates `--use-pass` → measures every push until `qg hooks install`.

## Next

- Operator: merge `feat/qg-push-pass` into `main` of `~/workspace/vault-quality-gates`, run `qg hooks install` in each gated repo.
- Operator: SC-4 — in `~/workspace/recycling_mobile_app`, `qg run push --ref refs/heads/release/1.17.0`, then `git push -u origin release/1.17.0`; record the verdict in the plan.
- Master plan `vault/plans/2026-10-18-1121-qg-common-interface.md`: S3 mid-build in `~/workspace/vault-quality-gates-s3`; S5 claimed on `main` `3f43b43`; recycling-api, app.givore.com, dashboard.givore.com still on v1 config.

## Refs

- `vault/architecture/guard-push-pass.md` — the record contract.
- `vault/plans/2026-10-19-1940-qg-push-pass-record.md` — the plan and its verdicts.
- `vault/architecture/guard-commit-gate.md` — the hooks and commit pass record this mirrors.
- `vault/sessions/2026-10-19-1300-qg-common-interface-s4.md` — S4, which produced the mobile migration this push carries.
