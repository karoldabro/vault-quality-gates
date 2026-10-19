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
