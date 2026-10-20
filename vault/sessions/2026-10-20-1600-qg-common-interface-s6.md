---
type: session
project: vault-quality-gates
date: 2026-10-20
topic: qg common interface — session 6 (agent hooks, sandbox, v1 removal)
continues: [[2026-10-19-2300-qg-common-interface-s5]]
files_touched: [bin/qg-sandbox, lib/qg-sandbox.sh, lib/qg-clean-env.sh, lib/qg-toolpath.sh, lib/qg-driver.sh, lib/qg-driver-kit.sh, lib/qg-dart.sh, lib/qg-doctor.sh, lib/guard-install.sh, lib/guard-override.sh, lib/guard-metrics.sh, bin/guard.sh, bin/qg, drivers/*.sh, templates/claude-hooks/*, templates/git-hooks/*, checks/qg-s6-SC-*.sh, checks/_qg-cases.sh, migrations/vault-quality-gates/*, tests/unit/*, vault/architecture/qg-sandbox.md, vault/architecture/guard-environment.md, vault/architecture/guard-agent-hooks.md]
decisions: []
tags: [session, quality-gate, qg, sandbox, landlock, agent-hooks]
---

# qg common interface — session 6 (agent hooks, sandbox, v1 removal)

## Goal

Install the agent guards at user level, close the caller-environment bypass, sandbox every driver
that runs committed code, add `qg doctor --all-branches`, and remove the v1 config reader.

## Did

- Built on `feat/qg-s6-agent-hooks` in `~/workspace/vault-quality-gates-s6` (pushed at `07b1475`) and
  `feat/qg-s6-v1-removal` stacked on it in `~/workspace/vault-quality-gates-s6-v1` (`92701bc`, needs a
  force push after rebases). Plan `vault/plans/2026-10-20-1022-qg-s6-agent-hooks.md`, exact values in
  its `.rules.md`, tests in its `.test-design.md`; handoff `vault/handoffs/2026-10-20-1556-qg-s6-agent-hooks.md`.
- Tests 716 → 1022 (`./tests/run.sh tests/unit`). SC-1, SC-2, SC-4..SC-6 met. SC-3 waits on the
  user-level install, SC-7 lives on the v1 branch, SC-8 on the operator's branch cleanup. Master row S6 stays `doing`.

## Learned

- `bwrap` and `unshare` fail here (`kernel.apparmor_restrict_unprivileged_userns=1`); Landlock ABI 8
  works unprivileged, on the host and in the bats image.
- Landlock leaves `/var/run/docker.sock` reachable, and a native-only seccomp filter is bypassed by a
  32-bit `int 0x80` socketcall; the filter must kill foreign architectures.
- `flutter test` runs with the SDK read-only only through the tool snapshot with
  `FLUTTER_ALREADY_LOCKED=true`; `bin/flutter` rewrites `bin/cache` on every call.
- A Landlock domain refuses cross-folder renames unless it grants the refer right; a nested
  scope-only domain broke pub's precompile until it granted refer on `/`.
- `bash -p` reads no `BASH_ENV` and imports no function, but still passes both to children; only an
  `env -i` restart cleans the environment.
- The old guard let `git -C ../vault-quality-gates …` rewrite the main checkout from a sibling worktree.
- `qg run baseline` is not a subcommand; `qg baseline --only` is.

## Behaviors & rules

- A built-in driver not marked `"sandbox": false` runs its tool in `bin/qg-sandbox` → writes outside the private folder and declared paths fail.
- A driver with a runner → the runner runs outside the sandbox and only the tool it starts is confined.
- A repo driver → always sandboxed, whatever its `describe` says.
- A git hook, `bin/guard.sh` or `bin/qg` started with a name outside the kept list → restarts once under `env -i`; edge: a forged `QG_CLEAN_ENV` with extra names exits 2.
- An agent's non-read git command whose work tree resolves into the main worktree → denied.
- A skip reason → refused when any ancestor process up to the user manager carries `CLAUDECODE` or `AI_AGENT`.
- `qg doctor --all-branches` → exit 1 for a v1 ref that is remote-tracking, has a live upstream or is checked out; stale local v1 branches only warn.

## Next

- The operator steps in `vault/handoffs/2026-10-20-1556-qg-s6-agent-hooks.md`: force push, merge,
  user-level install, hook reinstall, verdict reruns, branch cleanup, this repo's v2 config, the v1 merge, the S6 row.
- Open: rows on one tree see what earlier rows wrote (cloc counted layerlens's `DEPS.md` on `main`).

## Refs

- [[2026-10-19-2300-qg-common-interface-s5]]
- [[../plans/2026-10-18-1121-qg-common-interface]]
- [[../plans/2026-10-20-1022-qg-s6-agent-hooks]]
