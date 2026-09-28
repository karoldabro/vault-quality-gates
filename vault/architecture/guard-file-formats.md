---
type: architecture
project: vault
slug: guard-file-formats
status: current
tags: [quality, gates, contract]
---

# `/v-guard` file formats — the contract between the runner, the parsers and the comparison

Three tab-separated files per repo, one parser calling convention, the push refusal template, and
the files the commit gate keeps under the git common dir. Exit codes are the same everywhere: 0 measured
and acceptable, 1 measured and worse, 2 could not measure. A check that could not run is never
recorded as passing.

## Parsing rules, binding on both files

1. **Line 1 is the literal header**, uncommented, tab-separated, exactly the string given below.
   `guard_load_checks` and `guard_compare` refuse a file whose line 1 differs, and start reading at
   line 2. A commented-out header would be skipped, and the reader would then have nothing to count
   fields against.
2. A row whose field count differs from the header is **exit 2**, never a parse.
3. A line whose first character is `#` is a comment. A blank line is skipped.
4. No cell may contain a tab or a newline. An empty cell is written as `-`, never left blank.

Rule 4 exists because an empty trailing cell is invisible in every editor and collapses the field
count without any error.

## `quality/checks.tsv` — what to measure

Header, line 1:

```
id	scope	kind	command	parser	artifact	direction	threshold	gate
```

| column | values | meaning |
|---|---|---|
| `id` | `^[a-z][a-z0-9-]*$`, unique in the file | the metric name in the report and the baseline |
| `scope` | `commit` · `release` · `both` · `baseline` · `-` | which subcommand runs the row |
| `kind` | `repo` · `diff` · `absent` | `repo` compares against `quality/baseline.tsv`; `diff` compares against `threshold` as an absolute floor; `absent` runs nothing |
| `command` | shell, or `-` when `kind` is `absent` | see the substitution rules below |
| `parser` | a basename under `lib/guard-parsers/`, or `-` | `-` means the command's own stdout is the float |
| `artifact` | a path, `-`, or the reason text when `kind` is `absent` | what the parser reads |
| `direction` | `up` · `down` · `-` | `up` when a higher number is better |
| `threshold` | a number, or `-` | for `kind: repo` the worsening tolerated against the baseline; for `kind: diff` the floor (`up`) or ceiling (`down`) |
| `gate` | `refuse` · `warn` · `record` · `-` | `refuse` exits 1; `warn` records and exits 0; `record` stores the number only |

**Which subcommand runs which row.** `bin/guard.sh commit` and `bin/guard.sh verify` run `scope` of
`commit` or `both`; `vault/architecture/guard-commit-gate.md` defines what they measure. `bin/guard.sh release`
runs `release` or `both`, against the merge-base with the default branch, and reads
`quality/checks.tsv`, `quality/baseline.tsv` and the `VAULT.md` keys (`guard_accept_limit`,
`guard_measure_worktree`) from the pushed commit (`GUARD_SHA`, else `HEAD`); `pre-push` reads
`guard_release_pattern` from each pushed commit's `VAULT.md`. `bin/guard.sh baseline` runs
`baseline` rows and every `kind: repo` row, and no hook calls it. A `kind: absent` row carries
`scope: -` and is never run.

**Command substitution.** Every token below is replaced in the `command` cell and in the `artifact`
cell. A token whose value the subcommand does not set stays as written.

| token | becomes | set by |
|---|---|---|
| `{{base}}` | the base ref; under `commit` and `verify`, the first parent | every subcommand |
| `{{files}}` | `cat <file>` of the changed paths, **NUL-separated**; consume with `xargs -0` | every subcommand |
| `{{tree}}` | `<git-common-dir>/guard-tree`, a copy of the tree being committed | `commit`, `verify` |
| `{{cache}}` | `<git-common-dir>/guard-cache`, kept between runs for tool result caches | `commit`, `verify` |
| `{{bases}}` | every parent SHA, space-separated; the empty tree on a first commit | `commit`, `verify` |
| `{{target}}` | `:index` under `commit`; the commit SHA under `verify` | `commit`, `verify` |
| `{{guard}}` | the absolute path of this plugin's `bin/` | every subcommand |

A newline-separated `{{files}}` list terminates the command at the first path and executes the second
path as a command name; that is why the list is NUL-separated.

**Why `kind: diff` never compares against a baseline.** Each release push measures a different set of
changed lines, so two scores describe different populations. Comparing them reports a change in the
code under test as a change in quality.

**Three real rows.** Write them with `printf`, so the tabs are real:

```sh
printf 'coverage\trelease\tdiff\tdocker compose exec -T server composer test:diff-coverage {{base}}\tdiffcover\tquality-reports/diff-cover.json\tup\t80\trefuse\n'
printf 'comment-density\tboth\trepo\tcloc --json --quiet bin lib scripts > quality-reports/cloc.json\tcloc\tquality-reports/cloc.json\tdown\t0.02\trefuse\n'
printf 'mutation\t-\tabsent\t-\t-\tDart has no diff-scoped mutation tool\t-\t-\t-\n'
```

## `quality/rules.tsv` — identifier to catalog rule

Required by `bin/guard.sh commit` and `verify`. Header, line 1:

```
id	tool	enforced_by	emits
```

| column | meaning |
|---|---|
| `id` | the catalog rule id; the refusal points at the `### <id>` heading of the repo's rule catalog |
| `tool` | the tool that reports it, for example `custom`, `phpstan`, `phpmd`, `phpcs`, `phpat` |
| `enforced_by` | the class, dotted parameter path, rule name, sniff ref or method that enforces it |
| `emits` | the identifier the tool reports, or a sniff-code prefix; `-` when it reports none |

`bin/guard-report-errors.sh` matches a reported identifier against `emits` exactly first, then as a
prefix ending at a `.` boundary, longest prefix winning. A malformed file is exit 2 from the printer;
the commit's exit code still comes from its rows.

## `quality/baseline.tsv` — the ratchet

Header, line 1:

```
id	value	commit	reason
```

Only `kind: repo` ids appear. `value` must parse as a number; a non-numeric `value` is **exit 2**, not
zero — a row carrying no number must never score as clean. `reason` is `-` unless
`bin/guard.sh accept` wrote one. `checks.tsv` owns `direction`, `threshold` and `gate`; this file
never repeats them, and `guard_compare` joins the two by `id` using the **pushed** `checks.tsv`.

This file is committed, so the ratchet travels with the branch and is visible in review.

**`guard_baseline_diff`** fetches the remote ref's copy and refuses a row that moved in the worse
direction with `reason` still `-`. Without it a branch passes the gate its own file defines.

**When the remote ref does not yet exist** git supplies an all-zeroes remote sha. The function then
skips, prints `baseline check skipped: refs/heads/<name> does not exist on the remote`, and returns 0.
Treating a first push as a tampered baseline would refuse every new release branch.

**The accept limit.** `guard_accept_count` refuses when more than `guard_accept_limit` rows carry a
reason. That key is a flat scalar in the repo's `VAULT.md` and defaults to 3.
`bin/guard.sh baseline` clears every `reason` it rewrites, so accepted rows expire at the next
whole-repo measurement instead of accumulating until the limit makes `--no-verify` the normal path.

## Parser calling convention

`guard_parse_row` runs `lib/guard-parsers/<parser>.sh <artifact-path> <command-exit-status>`.

A parser prints **one float on stdout and exits 0**, or prints a reason on **stderr and exits 2**. It
never runs the measuring tool, never reads `checks.tsv`, and prints nothing else on stdout. Most
parsers ignore the second argument; `exitcode.sh` exists to read it.

`parser: -` means the command's own stdout is the float. `guard_parse_row` then applies the same
rule to that stdout: one float, or exit 2.

Two parsers exist for the commit gate. `phpstan-all` prints `totals.errors + totals.file_errors`: a
boot failure or an internal error carries no file, and `phpstan` alone would read it as 0. `phpmd`
counts `files[].violations[]` and is exit 2, naming the file, when `errors[]` is not empty.

**Failure mode this prevents:** a parser that prints an empty string on a missing artifact. The
comparison reads the empty string as zero, so a missing measurement becomes the worst possible score
— or, with `direction: down`, a perfect one.

## What a refused push prints

`guard_refusal` writes this to stderr. The developer reads it once and a Claude session reads it
pasted, so it carries the relief command and every path it names.

```
vault-guard: push refused to refs/heads/release/1.4.0

  comment-density   0.274 -> 0.249   worse by 0.025, tolerated 0.010
                    baseline: quality/baseline.tsv line 3, measured at 8009e1f

  mutation          could not measure
                    lib/guard-parsers/infection.sh read quality-reports/infection-log.json
                    and found msi = null

1 worse, 1 unmeasurable. quality/baseline.tsv carries 2 accepted rows; the limit is 3.

Fix it, or accept it:
  bin/guard.sh accept comment-density --reason "<why this is acceptable>"
  bin/guard.sh report
```

## The commit gate

`vault/architecture/guard-commit-gate.md` defines what `bin/guard.sh commit` and `verify` measure,
the commit refusal text, the five hooks, pass records, the override and the Claude Code hook install.

## Generated files

| path | written by | read by | tracked |
|---|---|---|---|
| `quality-reports/status.json` | `guard_render_report` | `~/vault/givore/quality/build-dashboard.mjs:57` | no |
| `quality-reports/REPORT.md` | `guard_render_report` | the operator | no |
| `quality/checks.tsv` | `/v-guard init`, or the operator | `guard_load_checks` | yes |
| `quality/baseline.tsv` | `bin/guard.sh baseline` and `bin/guard.sh accept` | `guard_compare`, `guard_baseline_diff` | yes |
| `quality/rules.tsv` | the operator | `bin/guard-report-errors.sh` | yes |
| `<git-common-dir>/guard-tree`, `guard-tree.index`, `guard-tree.lock` | `lib/guard-tree.sh`, `lib/guard-commit.sh` | tree rows | no |
| `<git-common-dir>/guard-cache` | `lib/guard-tree.sh`; the tools' caches | tree rows | no |
| `<git-common-dir>/guard-pass/<key>` | commit hooks, `post-rewrite`, `guard.sh verify`, `hooks install` | `pre-push` | no |
| `<git-common-dir>/guard-bypass.log` | `lib/guard-override.sh` | `pre-push`, which prints new lines | no |
| `<git-common-dir>/guard-bypass.printed` | `pre-push` | `pre-push`: how many log lines it already printed | no |

Nothing in this plugin reads `status.json` or `REPORT.md`. The gate reaches the agent through the
hooks' stderr, which the agent sees as the output of its own `git commit` or `git push`.

`REPORT.md` carries exactly four headings, in this order: `## Open regressions`, `## Unmeasurable`,
`## All metrics`, `## Absent`. The operator reads it; nothing parses it.

**`status.json` keeps the six category keys** `codeQuality`, `tests`, `coverage`, `e2e`, `nightly` and
`mutation` that `~/vault/givore/quality/build-dashboard.mjs:45` fixes. A `checks.tsv` id that is not
one of those six is written under `codeQuality.checks`, which that aggregator already renders as an
open map.
