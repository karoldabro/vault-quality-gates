---
type: architecture
project: vault
slug: guard-file-formats
status: current
tags: [quality, gates, contract]
---

# Gate file formats: what the engine, the drivers and the parsers read and write

Each gated repo commits three tab-separated files and one key file under `quality/`. The engine
keeps its run results under the git common dir. Exit codes are the same everywhere: 0 measured and
acceptable, 1 measured and worse, 2 could not measure. A check that could not run is never recorded
as passing. Drivers follow `vault/architecture/qg-driver-contract.md`.

## Parsing rules for every `.tsv` file

1. **Line 1 is the literal header**, uncommented and tab-separated. `guard_load_checks` refuses a
   `checks.tsv` whose line 1 is neither header below.
2. A row whose field count differs from the header is **exit 2**, naming file and line.
3. A line whose first character is `#` is a comment. A blank line is skipped.
4. No cell holds a tab or a newline. An empty cell is written `-`, never left blank, because an
   empty trailing cell collapses the field count without any error.

## `quality/checks.tsv`: what to measure

The current header, line 1:

```
id	on	kind	driver	args	direction	threshold	gate	why
```

| column | values | meaning |
|---|---|---|
| `id` | `^[a-z][a-z0-9-]*$`, unique | the row name in the refusal, the report and the baseline |
| `on` | the grammar below | which events run the row |
| `kind` | `repo` · `diff` · `absent` | `repo` compares with `quality/baseline.tsv`; `diff` compares with `threshold`; `absent` runs nothing |
| `driver` | `shell`, a built-in in `drivers/`, or a committed `quality/drivers/<name>.sh` | the wrapper that measures; an unknown name stops the file from loading |
| `args` | `[key=value ...] [-- <extra argv>]`, or `-` | handed to the driver as `QG_ARGS` after token substitution |
| `direction` | `up` · `down` · `-` | `up` when a higher number is better |
| `threshold` | a number, or `-` | for `repo` the worsening tolerated against the baseline; for `diff` the floor (`up`) or ceiling (`down`) |
| `gate` | `refuse` · `warn` · `record` · `-` | `refuse` exits 1; `warn` prints and exits 0 (`vault/architecture/guard-commit-gate.md`); `record` stores the number only |
| `why` | one sentence | why the gate exists; the refusal prints it. For `kind: absent`, why the check does not apply |

**Constraint: `why` is required.** A row whose `why` is `-` or starts with `TODO` stops the file
from loading. The commit gate refuses such a file through the built-in check `gate-config-invalid`.

**The `on` grammar** (`lib/qg-events.sh`):

```
on    := '-' | token (',' token)*
token := 'commit' | 'push' | 'push:' <ref-glob> | 'baseline'
```

No spaces, no empty token, lower case only. A ref glob matches with bash `[[ == ]]`: `*`, `?` and
`[...]` are glob characters, and `|` is a literal character. A `kind: absent` row carries `on: -`.

| run | rows it measures |
|---|---|
| `guard.sh commit`, `guard.sh verify` | `on` holds `commit` |
| `guard.sh release <ref>` (the `pre-push` hook) | `on` holds `push`, or a `push:<glob>` that matches `<ref>` |
| `guard.sh release` with no ref, `qg run push` with no `--ref` | `on` holds any push token |
| `guard.sh baseline` | `on` holds `baseline`, and every `kind: repo` row |

**The `shell` driver's args** are `[parser=<name>] [artifact=<path>] -- <command>`. The engine runs
the command inside `guard.sh`. With no parser, the command's last output line is the number.
Otherwise `lib/guard-parsers/<parser>.sh` reads the artifact.

**Token substitution.** The engine replaces each token below in the `args` cell, and in a `shell`
row's command and artifact. A token whose value the run does not set stays as written.

| token | becomes | set by |
|---|---|---|
| `{{base}}` | the base ref; under `commit` and `verify`, the first parent | every run |
| `{{files}}` | `cat <file>` of the changed paths, **NUL-separated**; consume with `xargs -0` | every run |
| `{{tree}}` | `<git-common-dir>/guard-tree`, a copy of the tree being committed | `commit`, `verify` |
| `{{cache}}` | `<git-common-dir>/guard-cache`, kept between runs for tool caches | `commit`, `verify` |
| `{{bases}}` | every parent SHA, space-separated; the empty tree on a first commit | `commit`, `verify` |
| `{{target}}` | `:index` under `commit`; the commit SHA under `verify` | `commit`, `verify` |
| `{{guard}}` | the absolute path of this plugin's `bin/` | every run |

**Failure mode the NUL list prevents:** a newline-separated `{{files}}` list ends the command at
the first path and executes the second path as a command name.

**Three rows.** Write them with `printf`, so the tabs are real. `qg init` writes the starter rows of
`templates/init/<profile>.tsv`.

```sh
printf 'phpstan-new\tcommit\tdiff\tphpstan\t-- --memory-limit=1G\tdown\t0\trefuse\ta commit may not add a PHPStan error\n'
printf 'comment-density\tcommit,push:refs/heads/release/*\trepo\tshell\tparser=cloc artifact=quality-reports/cloc.json -- cloc --json --quiet bin lib > quality-reports/cloc.json\tdown\t0.02\trefuse\tcode keeps its comments as it grows\n'
printf 'mutation\t-\tabsent\t-\t-\t-\t-\t-\tDart has no diff-scoped mutation tool\n'
```

### The v1 header, which the loader still reads

```
id	scope	kind	command	parser	artifact	direction	threshold	gate
```

`guard_load_checks` turns each v1 row into a v2 row:

| v2 field | from v1 |
|---|---|
| `on` | `scope` `commit` → `commit`; `release` → `push:<glob>` per `\|`-separated glob of `guard_release_pattern`; `both` → both; `baseline` → `baseline`; `-` → `-` |
| `driver` | `shell` |
| `args` | `parser=<parser> artifact=<artifact> -- <command>` |
| `why` | `(no reason recorded; run qg migrate)`; for `kind: absent`, the `artifact` cell |

An empty `guard_release_pattern` means `refs/heads/release/*`. The key is read at the config
revision. `qg migrate` rewrites a v1 file as v2; a human makes that commit.

## `quality/rules.tsv`: identifier to catalog rule

Required by `bin/guard.sh commit` and `verify`. Header: `id	tool	enforced_by	emits`.

| column | meaning |
|---|---|
| `id` | the catalog rule id; the refusal points at the `### <id>` heading of the repo's rule catalog |
| `tool` | the tool that reports it, for example `custom`, `phpstan`, `phpmd`, `phpcs`, `phpat` |
| `enforced_by` | the class, dotted parameter path, rule name, sniff ref or method that enforces it |
| `emits` | the identifier the tool reports, or a sniff-code prefix; `-` when it reports none |

`bin/guard-report-errors.sh` matches a reported identifier against `emits` exactly first, then as a
prefix ending at a `.` boundary, longest prefix winning.

## `quality/baseline.tsv`: the ratchet

Header: `id	value	commit	reason`. Only `kind: repo` ids appear. A non-numeric `value` is
**exit 2**, because a row carrying no number must never score as clean. `reason` is `-` unless
`guard.sh accept` wrote one. `checks.tsv` owns `direction`, `threshold` and `gate`.

**The baseline only gets tighter.** `guard_baseline_diff` reports a row as loosened when its value
moved in the worse direction, whatever its reason. It also reports a row whose `reason` changed to
anything but `-`. A removed or non-numeric `kind: repo` row is loosened too. The commit gate compares
with the parent. The push gate compares with `GUARD_BASE`: the remote ref's old tip, else the fork
point of a new branch. A base without the file skips the check.

**The accept limit.** A push to a named ref exits 1 when more than `guard_accept_limit` rows carry a
reason (default 3). `guard.sh baseline` clears every reason it rewrites.

## `quality/config`: the gate keys

Flat `key: value` lines; `#` starts a comment. `lib/qg-config.sh` is the only reader.

**Constraint: one key file per repo.** When `quality/config` exists at the config revision, the
engine reads every key from it and never reads `VAULT.md`. Otherwise every key comes from `VAULT.md`.
The config revision is the commit whose configuration judges the run, so a staged edit changes no key.

| key | effect |
|---|---|
| `guard_commit_paths` | path prefixes whose change makes the commit gate run its tree rows; absent gates every path |
| `guard_protected_paths` | path prefixes `bin/guard-protected-paths.sh` counts |
| `guard_accept_limit` | the most baseline rows that may carry a reason; default 3 |
| `guard_measure_worktree` | `false` measures the working tree at push instead of a detached worktree |
| `guard_release_pattern` | v1 rows only: the push refs a `release` scope means |

`qg config get <key>` prints a key as committed. A commit that changes `quality/config` fails the
built-in check `gate-config-changed`.

## Parser calling convention

`guard_parse_row` runs `lib/guard-parsers/<parser>.sh <artifact-path> <command-exit-status>`. A
parser prints **one float on stdout and exits 0**, or a reason on **stderr and exits 2**. It never
runs the tool and prints nothing else on stdout. `exitcode.sh` reads the second argument.

**Failure mode this prevents:** a parser that prints an empty string on a missing artifact. The
comparison would read it as zero, so a missing measurement would score as perfect.

## What a refusal prints

`qg_print_refusal` in `lib/qg-refusal.sh` builds the commit and push refusal, in this order: one
line per worse or unmeasurable row; per row its `why`, a reproduce command and `qg explain <id>`;
the findings; each distinct output tail once; then `How to pass:`. The text is capped at 3500
characters; the `How to pass:` footer is never cut. The whole text is written to `REFUSAL.txt`.

## Generated files

| path | written by | read by | tracked |
|---|---|---|---|
| `quality/checks.tsv` | `qg init`, `qg migrate`, or a human | `guard_load_checks` | yes |
| `quality/baseline.tsv` | `guard.sh baseline` and `guard.sh accept` | `guard_compare`, `guard_baseline_diff` | yes |
| `quality/rules.tsv` | a human | `bin/guard-report-errors.sh` | yes |
| `quality/config` | `qg init`, `qg migrate`, or a human | `lib/qg-config.sh` | yes |
| `quality-reports/status.json`, `REPORT.md` | `guard_render_report` | the operator | no |
| `<git-common-dir>/qg-last/RESULTS.txt` | `guard_render_report`: one `id\|value\|reference\|status\|detail` line per row | `qg run --json`, `qg explain` | no |
| `<git-common-dir>/qg-last/REFUSAL.txt` | `qg_print_refusal` | `qg last` | no |
| `<git-common-dir>/qg-last/<id>/result.json` | `guard_save_last`: the driver's `qg.result/1`, or one built for a `shell` row | the refusal, `qg explain`, `qg run --json`, `bin/guard-report-errors.sh` | no |
| `<git-common-dir>/qg-last/<id>/output.txt` | `guard_save_last`: the last 20 lines of the row's output | the refusal, `qg explain` | no |
| `<git-common-dir>/guard-tree`, `guard-tree.index`, `guard-tree.lock` | `lib/guard-tree.sh`, `lib/guard-commit.sh` | tree rows | no |
| `<git-common-dir>/guard-cache` | the tools' caches | tree rows, drivers (`QG_CACHE`) | no |
| `<git-common-dir>/guard-pass/<key>` | commit hooks, `post-rewrite`, `guard.sh verify`, `hooks install` | `pre-push` | no |
| `<git-common-dir>/guard-pass/push/<key>` | `qg run push --ref` after a full pass (`vault/architecture/guard-push-pass.md`) | `pre-push` through `guard.sh release --use-pass` | no |
| `<git-common-dir>/qg-override` | `qg override` | the commit hooks and `pre-push`, which delete it on use | no |
| `<git-common-dir>/guard-bypass.log` | `lib/guard-override.sh` | `pre-push`, which prints new lines | no |
| `<git-common-dir>/guard-bypass.printed` | `pre-push` | `pre-push`: how many log lines it already printed | no |

`REPORT.md` carries four headings, in this order: `## Open regressions`, `## Unmeasurable`,
`## All metrics`, `## Absent`. **`status.json` keeps six category keys**: `codeQuality`, `tests`,
`coverage`, `e2e`, `nightly` and `mutation`. An id outside them is written under
`codeQuality.checks`. Nothing in this plugin reads either file.
