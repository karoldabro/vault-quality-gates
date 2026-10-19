# Quality gates — dashboard.givore.com

This repo is wired to **vault-quality-gates**, installed at `/home/kdabrow/workspace/vault-quality-gates`.
The commit gate refuses a commit that adds a finding on the lines it adds or changes a protected file;
the push gate refuses any push whose measured metric is worse than `quality/baseline.tsv`.

**Exit codes, everywhere:** 0 measured and acceptable · 1 measured and worse · 2 could not measure.
A check that could not run is never recorded as passing.

## Before you edit quality/checks.tsv

1. Read `/home/kdabrow/workspace/vault-quality-gates/vault/architecture/guard-file-formats.md`, the
   column contract, and `/home/kdabrow/workspace/vault-quality-gates/vault/architecture/qg-builtin-drivers.md`,
   every driver's keys, exit codes and default config file.
2. **Run the tool once before you write its row**, and read what it printed. A row whose tool was never
   run gates a push on a guess.
3. Prefer a built-in driver (`qg drivers`) over a `shell` row; write a `shell` row only for a number no
   driver measures.
4. Commit the change under `qg override`: `quality/checks.tsv` is a protected path.

The hooks are **git hooks** in `.git/hooks/`, not Claude Code hooks. A refusal reaches an agent
because it ran `git commit` or `git push` and read stderr.

## quality/checks.tsv — nine columns, tab separated

| column | holds |
|---|---|
| `id` | the metric name in the refusal, the report and `quality/baseline.tsv` |
| `on` | the events that run the row: `commit`, `push:refs/*` (every push), `baseline`, or a comma list of them |
| `kind` | `repo` compares with the baseline; `diff` compares with `threshold`; `absent` runs nothing |
| `driver` | the wrapper that runs the tool and turns its output into one number; `shell` runs a command |
| `args` | `key=value` words for the driver, then `-- <extra argv>`; a `shell` row's command follows `--` |
| `direction` | `up` when a higher number is better |
| `threshold` | for `repo` the worsening tolerated against the baseline; for `diff` the ceiling (`down`) or floor (`up`) |
| `gate` | `refuse` blocks; `warn` prints; `record` stores the number only |
| `why` | one sentence the refusal prints; required, distinct per row, never `TODO` |

A row with an unknown driver, an empty cell or no `why` stops the whole file from loading, and the
commit gate refuses that commit. `quality/baseline.tsv` has four columns, `id value commit reason`,
and holds only `kind: repo` ids.

## Commands

| command | does |
|---|---|
| `qg list` | every row: id, when it runs, driver, what refuses, and why |
| `qg explain <id>` | what one row checks, its last result and output, and how to reproduce it |
| `qg run push` | what `pre-push` runs, without pushing |
| `qg run commit` | what `pre-commit` runs on the staged tree, without committing |
| `/home/kdabrow/workspace/vault-quality-gates/bin/guard.sh baseline` | runs `tests-suite-failed` and every `kind: repo` row, rewrites `quality/baseline.tsv` |

## Rows

`<r>` below is `runner=quality/bin/in-node.sh`: eslint, nuxt typecheck and vitest run through it.

| id | driver and what it counts | on | gates against |
|---|---|---|---|
| `lint-new` | `eslint` `<r> metric=errors lines=added`: ESLint errors on added lines of `.ts .vue .js .mjs .cjs` | commit | ceiling 0 |
| `typecheck-new` | `nuxt-typecheck` `<r> lines=added`: `error TS` from `nuxt typecheck` on added lines | commit | ceiling 0 |
| `duplication-new` | `jscpd-added` with jscpd 5.3.2 and `quality/jscpd.json`: clone lines covering an added `.ts .vue .js` line in `app/` or `server/`, tests and `app/types/api.ts` excluded | commit | ceiling 0 |
| `suppressions-added` | `shell`: added `eslint-disable`, `/* eslint ... */`, `@ts-ignore`, `@ts-expect-error`, `@ts-nocheck` in `.ts .vue .js .mjs .cjs` | commit | ceiling 0 |
| `protected-paths-touched` | `shell`: staged changes under `guard_protected_paths` (`quality/config`) | commit | ceiling 0 |
| `tools-changed` | `shell`: `in-node.sh --tools-diff` counts packages in the dev-tool, `nuxt` and `@nuxt/cli` closure the staged lock changes | commit | ceiling 0 |
| `lint-errors` | `eslint` `<r> metric=errors`: ESLint errors, whole repo | push | baseline |
| `typecheck-errors` | `nuxt-typecheck` `<r>`: `error TS` occurrences from `nuxt typecheck` | push | baseline |
| `duplication` | `jscpd` `metric=percentage`: jscpd 5.3.2 duplicated-line percentage over `app` and `server` | push | baseline, 0.1 tolerance |
| `duplication-clones` | `jscpd` `metric=clones` from the same report | push | baseline |
| `tests-failing` | `vitest` `run=no metric=failed`: failures + errors on the `<testsuites>` root of `quality-reports/junit.xml` | push | ceiling 0 |
| `coverage` | `vitest` `run=no metric=coverage`: line coverage from `coverage/clover.xml` (`app/**/*.ts`, specs excluded) | push | baseline, 0.5 tolerance |
| `coverage-age-days` | `shell`: `bash quality/bin/metric.sh coverage-age-days`, the age of `coverage/clover.xml` | push | ceiling 7 days |
| `tests-suite-failed` | `vitest` `<r> metric=failed`: a full run with coverage writing the junit and clover reports | baseline only | ceiling 0 |

`gate-config-touched` and `tests-suite` stay as `kind: absent` rows naming the rows that replaced them.

## Failure modes

- **No hook runs the test suite.** `tests-failing`, `coverage` and `coverage-age-days` read what the
  last suite run left. After 7 days the push is refused until the suite runs again.
- **The commit rows borrow the main checkout's `node_modules` and `.nuxt`.** Under commit,
  `quality/bin/in-node.sh` links the first into the staged tree, copies the second over any `.nuxt`
  there and removes both afterwards. When either is missing it exits 2 naming `pnpm install`. It never
  runs `nuxt prepare`.
- **The installed tools must match the committed lock.** `in-node.sh` exits 2, naming up to 10 packages,
  when the dev-tool, `nuxt` or `@nuxt/cli` closure in `node_modules/.pnpm/lock.yaml` differs from
  `HEAD:pnpm-lock.yaml`. Run `pnpm install` in that checkout on a branch with this lock.
- **A commit that changes a tool version is refused.** `tools-changed` counts every package in that closure
  the staged lock bumps, adds or removes; a human passes it with `qg override`.
- **`typecheck-new` loads the staged `nuxt.config.ts`.** `nuxt typecheck` runs it as code in the staged
  tree. It costs about 40 seconds per commit and runs only when a staged path matches `guard_commit_paths`.
- **The push rows measure this checkout as it is** (`guard_measure_worktree: false`): `node_modules` and
  `.nuxt` must exist here, and a push is refused while tracked files are dirty or HEAD is not the pushed commit.
- **jscpd runs through an isolated `pnpm dlx jscpd@5.3.2`**: no user, environment or parent-folder pnpm
  config reaches it, and the first run downloads it into the gate cache.
- **An unmeasurable row refuses.** A crashed tool, a missing report or an empty report never scores
  as clean.

## Bypass

Only a human at a terminal overrides a refusal, once: `qg override --reason "<why>"`, then commit or
push within 10 minutes. The override is logged to `.git/guard-bypass.log` and printed at the next push.

## Configuration

| file | owns |
|---|---|
| `quality/checks.tsv` | every row: driver, args, threshold and why |
| `quality/config` | `guard_commit_paths`, `guard_protected_paths`, `guard_measure_worktree` |
| `quality/baseline.tsv` | the ratchet, written by `guard.sh baseline`, never by hand |
| `quality/bin/in-node.sh` | the node runner the eslint, typecheck and vitest rows name |
| `quality/bin/metric.sh` | `coverage-age-days` |
| `quality/jscpd.json` | clone size floor and ignored paths; `"gitignore": false` |
| `eslint.config.mjs`, `vitest.config.ts`, `tsconfig.json` | the config each driver's tool loads |
