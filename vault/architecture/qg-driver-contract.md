---
type: architecture
project: vault-quality-gates
slug: qg-driver-contract
status: current
tags: [quality, gates, contract, drivers]
---

# The driver contract: how to write a driver the gate can run

A driver is one executable that wraps one tool. The engine (`bin/guard.sh`) calls it with three
subcommands and reads one file it writes, `result.json`. The driver measures; the engine judges.
The built-in drivers and their keys are listed in `vault/architecture/qg-builtin-drivers.md`; they
share `lib/qg-driver-kit.sh`. A repo driver cannot source that file: copy the `todo.sh` example below.
Decision: `vault/decisions/ADR-001-driver-contract.md`. Row format: `vault/architecture/guard-file-formats.md`.

## Where a driver lives

| kind | path | rule |
|---|---|---|
| built-in | `drivers/<name>.sh` in this plugin | must be executable |
| repo driver | `quality/drivers/<name>.sh` in the gated repo | the engine reads it from the config revision, never from the working tree |
| reserved | `shell` | the engine runs `shell` rows itself; `drivers/shell.sh` answers only `describe` and `explain` |

**Constraint: a repo driver may not shadow a built-in.** `guard_driver_resolvable` refuses a
`quality/drivers/<name>.sh` whose name matches a built-in, and `quality/checks.tsv` then fails to load.

**Constraint: a repo driver is committed.** The config revision is the commit whose configuration
judges the run (`lib/qg-config.sh`). The engine copies the committed driver into a temporary file
and makes it executable. An uncommitted or staged driver is never run.

**Constraint: only a human changes a repo driver.** A commit that changes a path under
`quality/drivers` fails the built-in check `gate-config-changed`. Only a human override passes it
(`vault/architecture/guard-commit-gate.md`). The agent guards deny an agent any write there.

## Subcommands

| call | prints | exit |
|---|---|---|
| `<driver> describe` | one JSON object: `{"name", "summary", "requires": [...], "needs_tree": true\|false}` | 0 |
| `<driver> explain [<ruleId>]` | plain text: what the driver measures, or what one rule means and how to fix it | 0 |
| `<driver> run` | the tool's own output; writes `$QG_OUT/result.json` | 0 when `result.json` was written |
| anything else | usage on stderr | 2 |

**`describe` fields.** `name` is the driver name. `summary` is one line for `qg drivers` and
`qg explain`. `requires` lists the commands the driver needs on `PATH`; `qg doctor` fails each one
that is missing. `needs_tree: true` makes the commit gate measure a copy of the staged tree. A
`describe` the engine cannot read counts as `needs_tree: true`.

`qg doctor` fails a driver whose `describe` is not JSON with a `name`, or whose `explain` prints
nothing.

## Environment the engine sets for `run`

| variable | holds |
|---|---|
| `QG_ARGS` | the row's `args` cell, after token substitution (`vault/architecture/guard-file-formats.md`) |
| `QG_OUT` | an empty directory; write `result.json` here, and any scratch files |
| `QG_ROW` | the row id |
| `QG_BASE` | the base ref: the first parent under `commit` and `verify`, the merge-base under push |
| `QG_FILES` | the path of a file listing the added, copied, modified and renamed paths, NUL-separated; read it with `read -d ''`. A type change and a deletion are not listed: a driver that must see them runs its own `--name-status` diff, as `drivers/doc-lint.sh` does |
| `QG_BASES` | every parent, space-separated, under `commit` and `verify`; `QG_BASE` otherwise |
| `QG_TARGET` | `:index` under `commit`, the commit sha under `verify`, the pushed sha under push |
| `QG_REPO` | the absolute repo root |
| `QG_TREE` | the directory to measure; see the next paragraph |
| `QG_CACHE` | `<git-common-dir>/guard-cache`, kept between runs for tool caches |
| `QG_RUNNER` | the path of a copy of the committed runner; set only when `args` holds `runner=` |
| `QG_RUN_DIR` | a directory the engine creates for one invocation and deletes at exit, for reports rows share |
| `QG_CONFIG_REV` | the commit whose configuration judges this run; read a config key there with `git show`, never from the working tree |

**`QG_TREE` is the only directory a driver measures.** Under `commit` it is
`<git-common-dir>/guard-tree` when the gate prepared the staged-tree copy. Otherwise it is the
directory the run works in: the repo root, or the detached worktree of the pushed commit.

## `QG_ARGS` grammar

```
QG_ARGS := [key=value ...] [-- <extra argv>]
```

Words before the first ` -- ` are `key=value` pairs, split on whitespace, so a value holds no
space. The text after the first ` -- ` is extra argv for the tool. An args cell of `-` carries no
key and no argv. A repo driver reads them with the `kv` function of the `todo.sh` example below.

| reserved key | meaning |
|---|---|
| `runner=<repo path>` | the engine copies that committed file from the config revision into `$QG_RUNNER`; a runner that is not committed makes the row unmeasurable |
| `bin=<path>` | the tool's executable, relative to `QG_TREE`; each driver states its default |

**Calling the runner.** A runner runs the tool inside the repo's toolchain, such as a container.
Call it as `$QG_RUNNER "$QG_TREE" "$QG_CACHE" <bin> <argv>`. Without `QG_RUNNER`, run the tool
from `QG_TREE` directly.

**Constraint:** a tool run through a runner sees only `QG_TREE` and `QG_CACHE`. Pass it paths
relative to `QG_TREE`, write its report inside `QG_TREE`, and copy what you need into `QG_OUT`
after the runner returns. A report path under `QG_OUT` does not exist inside a container.

## `result.json`: schema `qg.result/1`

| field | type | allowed values |
|---|---|---|
| `schema` | string | `qg.result/1` |
| `driver` | string | the driver name |
| `status` | string | `measured`, or `error` when the tool could not produce a number |
| `metric` | number or null | the one number the engine compares; `null` when `status` is `error` |
| `unit` | string | what `metric` counts, such as `findings`, `lines` or `count` |
| `findings` | array | each `{ruleId, file, line, level, message, doc}`; `file`, `line` and `doc` may be null |
| `error` | string or null | the reason the tool could not measure; `null` when `status` is `measured` |
| `reproduce` | string or null | a command that reruns this measurement, such as `qg run commit --only <id>` |

`bin/guard-report-errors.sh` prints each finding as `<id> <file>:<line> <ruleId> <message>`, at most
10 per row, in the commit refusal, the push refusal and `qg explain`. Write a finding with
`file: null` for an error the tool reports without a file, such as a boot failure.

## Who decides pass or fail

**The engine decides; the driver never does.** The engine reads `metric` and compares it in
`guard_compare`. A `kind: diff` row compares it with `threshold`. A `kind: repo` row compares it
with the `quality/baseline.tsv` value plus `threshold` of tolerance. The row's `gate` cell then
refuses, warns or records. A driver that finds 40 errors still exits 0 and writes `metric: 40`.

## What makes a row unmeasurable

An unmeasurable row refuses the commit or push and is never recorded as passing. Each shape below
makes the row unmeasurable:

| shape | reason the refusal prints |
|---|---|
| `run` exits non-zero | `driver <name> exited <n>` |
| no `result.json`, or an empty one | `driver <name> wrote no result.json` |
| `result.json` is not a JSON object | `... is not a JSON object` |
| `error` is set to anything but null or an empty string | the `error` text itself |
| `status` is anything but `measured` | `driver <name> reports status <status>` |
| `metric` is not a JSON number (`null`, `"3"`) | `driver <name> reports metric <value>, which is not a number` |
| `runner=` names a file not committed at the config revision | `runner <path> is not committed at the config revision` |
| the driver cannot be read at the config revision | `quality/drivers/<name>.sh could not be read at the config revision` |
| a `kind: repo` row's baseline value is not a number | `baseline row is not a number` |

**Load-time failure:** a row that names a driver that is neither built in nor committed stops
`quality/checks.tsv` from loading. Every row is then unmeasurable.

A measured `kind: repo` row with no baseline row is recorded and not judged.

## Exit codes

- `run` exits 0 whenever it wrote `result.json`, including a result with `status: error`.
- A non-zero exit from `run` makes the row unmeasurable, whatever `result.json` says.
- `describe` and `explain` exit 0. An unknown subcommand exits 2 and prints usage on stderr.

## Output the engine keeps

The engine captures `run`'s stdout and stderr in one file. It keeps the last 20 lines in
`<git-common-dir>/qg-last/<id>/output.txt` and copies `result.json` to
`<git-common-dir>/qg-last/<id>/result.json`. The refusal and `qg explain` print that tail.

**Constraint: print what a person needs to fix a failure.** Print the tool's own error lines on a
failure. Never print the JSON report on stdout: it fills the 20 kept lines.

## A minimal complete driver

`quality/drivers/todo.sh` counts lines containing `TODO` in the changed files of the measured tree:

```bash
#!/usr/bin/env bash
# args: [ext=<extension>]   default md
set -uo pipefail
export LC_ALL=C

kv() {  # kv <key> -> the value of key=value before ` -- ` in QG_ARGS
    local head="${QG_ARGS:-}" w
    case "$head" in '-- '*) return 1 ;; *' -- '*) head="${head%% -- *}" ;; esac
    for w in $head; do case "$w" in "$1="*) printf '%s' "${w#*=}"; return 0 ;; esac; done
    return 1
}

case "${1:-}" in
    describe)
        printf '{"name":"todo","summary":"counts TODO lines in changed files","requires":["jq","grep"],"needs_tree":true}\n' ;;
    explain)
        printf 'Counts lines that contain TODO in the changed files. Finish the work or remove the marker.\n' ;;
    run)
        : "${QG_OUT:?}" "${QG_TREE:?}" "${QG_FILES:?}"
        ext="$(kv ext)" || ext=md
        n=0
        while IFS= read -r -d '' f; do
            case "$f" in *."$ext") ;; *) continue ;; esac
            [ -f "${QG_TREE}/${f}" ] || continue
            c="$(grep -c 'TODO' "${QG_TREE}/${f}")"
            n=$((n + c))
            [ "$c" -eq 0 ] || printf '%s: %d TODO lines\n' "$f" "$c"
        done < "$QG_FILES"
        jq -n --argjson m "$n" --arg r "qg run commit --only ${QG_ROW:-<id>}" \
            '{schema: "qg.result/1", driver: "todo", status: "measured", metric: $m, unit: "lines",
              findings: [], error: null, reproduce: $r}' > "${QG_OUT}/result.json" ;;
    *)
        printf 'usage: todo.sh describe | explain [<ruleId>] | run\n' >&2; exit 2 ;;
esac
```

The row that runs it: `todo-new commit diff todo ext=md down 0 refuse <why>`; check it with `qg doctor`.
