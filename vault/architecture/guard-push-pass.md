---
type: architecture
project: vault-quality-gates
tags: [architecture, quality-gate, pre-push]
---

# Push pass record

`qg run push --ref <ref>` measures the push gate ahead of `git push` and records a full pass, and
`pre-push` accepts that record instead of measuring again. git opens the connection to the remote
before `pre-push` runs, and a host drops a connection that sits idle while a long gate measures.

## The record

`<git-common-dir>/guard-pass/push/<key>` holds `ok <epoch>`. `<key>` is the SHA-1 of
`push <ref> <sha> <row base> <baseline base> <engine digest>`:

| input | why it is in the key |
|---|---|
| `<ref>` | the rows a push runs are chosen by the ref |
| `<sha>` | the commit measured; its `quality/` files are the config and baseline that judge it |
| `<row base>` | the merge-base with the default branch, which `diff` rows compare against |
| `<baseline base>` | the remote tip, or the fork point of a new branch, which `quality/baseline.tsv` may not loosen against |
| `<engine digest>` | SHA-1 over `<path> <x\|-> <blob>` of every file under the engine's `bin/`, `lib/` and `drivers/` |

`qg run push --ref` takes the baseline base from `refs/remotes/<remote>/<branch>`, where `<remote>` is
`branch.<branch>.remote`, else `origin`. `pre-push` takes it from the remote. A remote tip that moved
since the last fetch gives a different key, and the push measures.

Code: `lib/guard-pass.sh` (`guard_push_pass_key`, `guard_push_pass_write`, `guard_push_pass_valid`,
`guard_engine_digest`, `guard_baseline_base`), `bin/guard.sh` `cmd_release`, `bin/qg` `cmd_run`.

## When it is written and accepted

| condition | effect |
|---|---|
| `--only`, ref `-`, a config pin, exit 1 or 2 | no record is written |
| a working tree that moved during the run (`guard_measure_worktree: false`) | no record is written |
| the write fails | `vault-guard: pass record not written; git push will measure again`; `qg` still exits 0 |
| same key, epoch not in the future, at most 3600 s old, no config pin | `pre-push` prints `passed qg run push <N> min ago; not measured again` and accepts the ref |
| record absent, malformed, expired, or any key input changed | `pre-push` measures as without a record |

Records are not consumed on use, so a push that drops after the check can retry. The writer deletes
records older than 3600 s and writes through a temp file, so a half-written record reads as malformed.

## The hotfix refusal

`guard.sh release --use-pass` refuses, with exit 1 and before any row is chosen, a ref matching
`refs/heads/hotfix/*` pushed by an agent, unless `qg_grant_use hotfix "<ref> <sha>"` passes. The
ref is the real remote ref `pre-push` reads, so a refspec glob, `--all`, an upstream or
`remote.*.push` cannot hide it. A hotfix branch runs no push row once the repo's `on` cells read
`push:!(refs/heads/hotfix/*)`, so the grant is what lets an agent's hotfix through.

| pusher | `hotfix` grant | outcome |
|---|---|---|
| agent | none or expired | refused: `vault-guard: push refused to <ref>: …`, naming `qg grant --agent hotfix` or a feature-branch push; the text goes to `qg last` |
| agent | live | judged by the rows; `agent grant (hotfix, until <time>): <ref> <sha>` goes to `guard-bypass.log` |
| person, at a terminal or in a GUI client | any | judged by the rows |

Any other ref is judged by the rows whoever pushes it. `guard_pusher_is_agent` in
`lib/guard-override.sh` decides the pusher: `CLAUDECODE` or `AI_AGENT` in the environment, or a
failed `guard_override_ancestors_clean` walk (one in an ancestor's `/proc/<pid>/environ`, or an
unreadable one). It runs no `/dev/tty` test. A terminal started from inside a Claude Code session
counts as an agent.

## The measured record

`<git-common-dir>/guard-pass/measured/<sha>` holds `ok <epoch> <ref>` or `unmeasured <epoch> <ref>`
for each pushed commit `pre-push` accepted. The operator's merge flow reads it to tell a measured
head from an unmeasured one.

| `guard.sh release --use-pass` accepts the ref | state |
|---|---|
| after measuring its rows | `ok` |
| from a valid push pass record | `ok` |
| with no row running on it (a hotfix branch, a ref outside every glob) | `unmeasured` |
| when its commit has no `quality/checks.tsv` | `unmeasured` |

- **Never downgraded:** `unmeasured` never replaces an existing `ok`, so a hotfix push of a
  measured commit keeps `ok`.
- **A refused ref writes nothing.** In a push of several refs, each accepted ref still writes.
- **Writes** go through a temp file and a rename. A failed write prints
  `vault-guard: measured record not written` and never changes the exit status.
- **Writers:** `guard_measured_write` in `lib/guard-pass.sh`, called from `bin/guard.sh`
  `cmd_release` under `--use-pass` only; and the agent factory's delivery
  (`agent_control/delivery.py` in agent-control), which pushes with no hook and writes the same
  format.
- **A hint, not proof:** an agent's script can write the file, so the merge flow treats an `ok` as a
  claim it may re-measure.

## Limits

- A record does not cover the machine's tool installs (`node_modules`, the pub cache, the SDK). A tool
  change within 3600 s of the pass is not measured.
- A forged record skips every push row. The agent hooks deny a write that names `guard-pass` or lands
  in the git dir, and deny `PATH`, `HOME` and `XDG_CONFIG_HOME` set for `qg`
  (`templates/claude-hooks/guard_bash.py`). A script that builds the path at run time is not seen;
  only server-side branch protection closes that.
- `guard.sh release` refuses an unknown flag with exit 2. An engine that predates `--use-pass`
  therefore refuses the push rather than reading the flag as the ref. An installed `pre-push` that
  predates the flag measures every push until `qg hooks install` replaces it.
