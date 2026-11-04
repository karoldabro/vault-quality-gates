---
type: architecture
project: vault-quality-gates
slug: guard-baseline-accept
status: current
tags: [architecture, quality-gate, baseline]
---

# The acceptance record: how a looser `quality/baseline.tsv` passes commit and push

**Only `qg baseline` run by a human at a terminal accepts a looser baseline.** The commit gate and
the push gate refuse every other loosening (`vault/architecture/guard-file-formats.md`, the ratchet).
No override and no grant passes one.

## The record

`qg baseline [--reason "<why>"]` writes `quality/baseline.tsv`, then appends one tab-separated line
to `<git-common-dir>/qg-baseline-accept`:

```
<blob>	<user>	<epoch>	<reason>
```

- `<blob>` is `git hash-object --no-filters` of the file it wrote. `--reason` defaults to `qg baseline`.
- The human check is the one `QG_SKIP_REASON` passes (`vault/architecture/guard-commit-gate.md`,
  `## The override`). When it fails, the file is written, no line is added, and `qg baseline` prints
  `not accepted as a new floor`.
- Each record is logged to `<git-common-dir>/guard-bypass.log`, which the next `pre-push` prints.
- Records never expire and are never consumed: the commit and every push retry read the same line.

Code: `lib/guard-baseline-accept.sh` (`guard_baseline_accept_write`, `guard_baseline_accepted`,
`guard_baseline_lock`), called by `cmd_baseline` and `guard_release_locked` in `bin/guard.sh` and
by `guard_gate_locked` in `lib/guard-commit.sh`.

## What passes

| case | result |
|---|---|
| the committed file is byte for byte one `qg baseline` wrote at a terminal | passes commit and push; the result line reads `ok` and names who accepted it |
| a hand edit, or any edit after `qg baseline` | refused: another blob |
| `qg baseline` with no terminal, with `CLAUDECODE` or `AI_AGENT` set, or under an agent grant | refused: no record |
| a deleted baseline, or a `checks.tsv` that does not load | refused whatever the record says |
| the record file is a symlink or not a regular file | read as absent |

## The operator path

1. Run `qg baseline --reason "<why>"` at a terminal, outside Claude Code.
2. Run `git add quality/baseline.tsv`, then `git commit`.
3. Run `git push`, or `qg run push --ref <ref>` and then `git push`.

`tests/unit/qg-baseline-accept.bats` runs this path through the installed hooks to a bare remote.

## Limits

- The record is local to this clone. `qg verify` in CI or on another machine refuses the same commit.
- A same-user process can write the record file. The agent guards deny writes into a `.git` folder
  (`vault/architecture/guard-agent-hooks.md`); a script that builds the path at run time is not seen.
