---
type: architecture
project: vault-quality-gates
slug: qg-cli
status: current
tags: [quality, gates, contract, cli]
---

# The `qg` command: every subcommand, its exit codes and its `--json` shape

`bin/qg` is the command a person or an agent types. `bin/guard.sh` stays the engine the git hooks
call; `qg` reads the same committed configuration and explains it. File formats are in
`vault/architecture/guard-file-formats.md`. Drivers are in `vault/architecture/qg-driver-contract.md`.

## How a person or an agent reaches `qg`

- Type bare `qg` when it is on `PATH`. `qg doctor` warns when it is not and prints the link command:
  `ln -s <plugin>/bin/qg ~/.local/bin/qg`.
- Otherwise call `<plugin>/bin/qg` by absolute path. Every refusal ends with `(qg is <path>)`.

**Constraint: an agent may run only the read subcommands.** `templates/claude-hooks/guard_bash.py`
checks a bare `qg`, or a path whose real path is the plugin's `bin/qg`. It allows the subcommands in
`QG_READS` and `hooks status`, `--user` included, and denies every other one before it runs:

```
help -h --help list explain last drivers doctor run report verify config   + hooks status
```

`bin/qg` refuses `override`, `init`, `baseline`, `accept`, `hooks install` and
`hooks remove` with exit 2 when `CLAUDECODE` or `AI_AGENT` is set. The two checks are independent:
an agent outside a guarded Claude Code session still meets the second.

## Rules every subcommand follows

- `--json` may appear anywhere on the line. `last`, `config` and `override` ignore it.
- Every subcommand except `help` and the `hooks` forms with `--user` runs from inside a git
  repository and exits 2 otherwise.
- `qg` starts from the clean environment in `vault/architecture/guard-environment.md`, so no
  inherited variable, function or `PATH` entry steers it or the engine. Linux only.
- `list`, `explain` and `drivers` read the configuration committed at `HEAD`, never the working tree.
- An unknown subcommand prints the help on stderr and exits 2.

## Subcommands

| subcommand | purpose | exit codes | agent |
|---|---|---|---|
| `qg help [<command>]` | the overview, or one subcommand's options | 0 | yes |
| `qg list [--on commit\|push\|baseline]` | every row: id, driver, gate, when it runs, why | 0; 2 when `HEAD` has no loadable `quality/checks.tsv` | yes |
| `qg run commit [--only id,id]` | the commit gate on what is staged now, without committing | 0 pass, 1 a row is worse, 2 a row could not be measured | yes |
| `qg run push [--ref refs/heads/<b>] [--only id,id]` | the push gate on `HEAD` for that ref, without pushing; no `--ref` runs every push row; with `--ref` and no `--only`, a pass is recorded for `git push` (`vault/architecture/guard-push-pass.md`) | 0, 1, 2 as above | yes |
| `qg explain <id>` | one row: why, when, driver, limit, last result and output, how to reproduce and pass | 0; 2 for no id or an unknown id | yes |
| `qg last` | the last refusal, in full, from `<git-common-dir>/qg-last/REFUSAL.txt` | 0, also when none is recorded | yes |
| `qg drivers [<name>]` | the drivers this repo can use, or one driver's `describe` and `explain` | 0; 2 for an unknown name | yes |
| `qg doctor` | checks the setup | 0 healthy (warnings allowed), 1 something is broken | yes |
| `qg config get <key>` | a gate key as committed in `quality/config`; a key only in `VAULT.md` is unset | 0 and the value; 1 when unset; 2 on bad usage | yes |
| `qg override --reason "<why>" [--push <sha>]` | lets the next commit of what is staged now, or the push of `<sha>`, through once within 10 minutes | 0 token written; 1 no terminal or a bad `--push` sha; 2 no reason or an agent | no |
| `qg init --profile docs\|php\|nuxt\|flutter\|hugo [--force]` | writes `quality/checks.tsv`, `rules.tsv`, `baseline.tsv` and `config` from `templates/init/<profile>.tsv`. `config` protects the five gate files by exact path, plus every tracked `.doc-lint` for docs, which also gets `guard_doc_lint`. An existing `config` is kept, with a warning naming what it lacks. Next: `qg hooks install`, commit, `qg doctor` | 0; 2 on a bad profile or an existing `checks.tsv` without `--force` | no |
| `qg hooks`, `qg hooks status [--user [--config-dir <dir>]...]` | what is installed (`vault/architecture/guard-agent-hooks.md`) | 0 | yes |
| `qg hooks install [--claude [--user [--config-dir <dir>]...]]`, `qg hooks remove [--claude [--user ...]]` | installs or removes the git hooks or the guard entries (`vault/architecture/guard-agent-hooks.md`) | 0; 2 from a linked worktree (`--user`) or on invalid settings JSON | no |
| `qg report`, `qg verify <range>` | pass through to `guard.sh report` and `guard.sh verify` | from `guard.sh` | yes |
| `qg baseline`, `qg accept <id> --reason "<why>"` | pass through to `guard.sh baseline` and `guard.sh accept` | from `guard.sh` | no |

**`qg run push` with no `--ref`** prints the refusal under the heading `the push gate failed (run by
hand, every push row)` and skips the accept-limit check, which binds a named ref only. `qg run
commit` writes no pass record, so a later `git commit` runs the gate again.

**`qg override` details** (token binding, lifetime, the `QG_SKIP_REASON` alternative) are in
`vault/architecture/guard-commit-gate.md`.

**`qg init` never commits.** The commit that changes the gate configuration is a human's, made after
`qg override`.

## `--json` shapes

**`qg list --json`**

```json
{"rows": [{"id": "", "on": "", "kind": "", "driver": "", "gate": "", "direction": "", "threshold": "", "why": ""}]}
```

**`qg run commit|push --json`**

```json
{"verdict": "pass|fail|error", "exit": 0, "rows": [{"id": "", "status": "", "value": "", "reference": "", "detail": "", "result": {}}]}
```

`verdict` follows `exit`: 0 `pass`, 1 `fail`, anything else `error`. `status` is one of `ok`,
`worse`, `warn`, `recorded`, `unmeasurable`, `skipped` or `absent`. `value` and `reference` are `-`
when there is none. `result` is the row's `qg.result/1` from `qg-last/<id>/result.json`, or `null`.

`rows` is read from `<git-common-dir>/qg-last/RESULTS.txt`, which `qg run` empties before the engine
starts. When the engine exits before it measures, such as a `checks.tsv` that does not load or a ref
no row runs on, `rows` is empty and `exit` carries the outcome.

**`qg explain <id> --json`**

| field | holds |
|---|---|
| `id`, `why`, `on`, `driver`, `gate` | the row's cells |
| `runs_on` | `on` in words, such as `every commit; pushes to refs/heads/release/*` |
| `driver_summary` | the driver's `describe` summary |
| `limit` | the limit in words, with the baseline value for a `kind: repo` row |
| `command` | the command of a `shell` row; `null` for any other driver |
| `last_result` | the last `qg.result/1`, or `null` |
| `last_status_line` | the row's last `id\|value\|reference\|status\|detail` line, or an empty string |
| `last_output` | the last 20 lines of the row's output |
| `reproduce` | `qg run commit --only <id>`, or `qg run push --only <id>` for a row with no `commit` token |
| `driver_explain` | the driver's `explain` text |

For a built-in check id, such as `gate-config-changed`, `qg explain` prints the id and its why;
under `--json` it prints `{"id", "why", "builtin": true}`.

**`qg drivers --json`**

```json
{"drivers": [{"name": "", "summary": "", "requires": [], "needs_tree": true, "source": "built-in"}]}
```

A repo driver is listed from `HEAD:quality/drivers/` as `{"name", "summary", "source": "repo"}`.
`qg drivers <name> --json` prints that driver's `describe` object.

**`qg doctor --json`**

```json
{"fails": 0, "warnings": 0, "checks": [{"level": "ok|warn|fail", "text": ""}]}
```

`qg doctor` checks `jq`, `python3`, `git` and `flock`; that `HEAD:quality/checks.tsv` loads; the
key source; and that `qg` is on `PATH`. It fails when an installed git hook differs from its
template or `core.hooksPath` is set, naming `qg hooks install`. It fails when
`$HOME/.claude/settings.json` lacks the three guard entries, or `~/.claude-factory` exists and its
settings lack them. It also fails when the machine tool-path file is absent or holds a bad entry.
Both name `qg hooks install --claude --user`. It warns once per guard entry left in the repo's own
`.claude/settings.json`. It also checks each driver's `describe`, `explain` and `requires`, and
that each `push:<glob>` matches a branch.

**`qg doctor --all-branches [--json]`** finds the branches that still carry an old gate config. It
reads every `refs/heads/*` and `refs/remotes/*/*` ref except symbolic ones, through one
`git cat-file --batch`. It lists each ref whose `quality/checks.tsv` is v1, has an unrecognised
header, or is v2 without `quality/config`. It never fetches and never writes.

| label | when | exit |
|---|---|---|
| `worktree` | the branch is checked out in any worktree, the main one included | 1 |
| `upstream` | a remote-tracking ref, or a branch whose upstream ref exists locally (for `remote = .`, the local branch) | 1 |
| `stale` | any other listed branch | 0 when every listed ref is stale |

Labels apply in that order, so a ref gets one line. The source is the v2 ref holding
`quality/config` with the newest tip committer date; with none, the doctor prints `no v2 source`.
Under `--json` it prints this object, with the same exit code:

```json
{"source": "<sha>|null", "refs": [{"ref": "", "sha": "", "state": "worktree|upstream|stale", "version": "v1|v2|unknown", "config": false}]}
```
