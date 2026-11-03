---
type: session
project: vault-quality-gates
date: 2026-11-03
topic: qg-wsl-relay-human-check
files_touched: [lib/guard-override.sh, templates/claude-hooks/guard_bash.py, tests/unit/guard-override.bats, tests/unit/guard-claude-hooks.bats, vault/architecture/guard-commit-gate.md, vault/architecture/guard-agent-hooks.md, vault/plans/2026-11-03-1022-qg-human-proof.md]
decisions: []
tags: [session, guard, override, wsl]
---

# qg-wsl-relay-human-check

## Goal

Let a human on WSL pass `qg override`, `qg grant` and `QG_SKIP_REASON`, and stop an agent reaching that check through a wrapper that detaches it or fakes a terminal.

## Did

- `lib/guard-override.sh`: the parent walk moved into `_guard_override_walk <proc root> <pid>`. `_guard_override_wsl_relay` ends it clean at a `Relay(<digits>)` process with real uid 0. It also needs a Microsoft osrelease and `/proc/self/uid_map` reading `0 0 4294967295`.
- `templates/claude-hooks/guard_bash.py`: `scan_inner()` runs after a `WRAPPERS` or `CMD_WRAPPERS` command such as `script`, `systemd-run`, `tmux` or `wsl.exe`. It reads each argument holding a space. It also reads the trailing words from the first `qg`, `guard.sh`, `git`, shell, wrapper or assignment. More than 256 inner reads denies.
- Tests over a fake proc tree in `tests/unit/guard-override.bats`; wrapper, gated-repo and timing rows in `tests/unit/guard-claude-hooks.bats`. Suite 989/989.
- Contracts: `vault/architecture/guard-commit-gate.md` (`## The override`) and `vault/architecture/guard-agent-hooks.md`.
- Commit `3ef711e` on `main`, not pushed.

## Learned

- `setsid -f env -i script -qec "<cmd>" /dev/null` passed the old walk from inside Claude Code: the reparented `script` has tty 0 and a clean environ, so the orphan rule never fires.
- `guard_bash.py` did not read inside `script -c`, and `env -u X qg …` took `X` for the command.
- No local check stops a same-user agent: `.git/hooks/` and `.git/config` are user-writable. A sudo password or a root-owned engine was rejected for that reason; CI `qg verify <range>` is the binding gate.
- Re-scanning every trailing suffix after nested wrappers took 37 s on a 300-word command; scanning from the first qualifying word only takes under 0.1 s.
- On WSL with interop on, a session opened through `wsl.exe` also sits under a root `Relay(<n>)`, so the walk passes it; only `guard_bash.py` denies the plain form.
- Hooks in every gated repo source `lib/` from this checkout's working tree, so edits are live; work in a separate worktree.

## Behaviors & rules

- walk reaches root-owned `Relay(<n>)` on a Microsoft kernel in the initial user namespace → clean; edge: Relay real uid ≠ 0, non-WSL kernel, or a mapped user namespace → refused.
- the start pid is never taken for the Relay → its own environ is always read.
- agent Bash command with `qg override`/`qg grant` inside a listed wrapper → denied as if run directly; edge: `ssh host …` → not judged, its command runs elsewhere.
- wrapped command needing over 256 inner reads → denied, never waved through.

## Next

- Operator: run `qg override --reason test` in `digitally-admin-backend` from a plain WSL2 terminal (plan criterion C5).
- Unverified: whether WSL1 names the parent `Relay(<n>)`.
- Operator: push `main` (`qg run push --ref refs/heads/main`, then `git push`).

## Refs

- `vault/plans/2026-11-03-1022-qg-human-proof.md` — the plan and its criteria.
- `vault/plans/2026-11-03-1022-qg-human-proof.trail.md` — rejected designs and review findings.
- `vault/architecture/guard-commit-gate.md` — the override contract.
- `vault/architecture/guard-agent-hooks.md` — the bash guard contract.
