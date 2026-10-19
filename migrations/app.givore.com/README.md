# Quality gates — app.givore.com

`quality/checks.tsv` holds one row per metric: which driver measures it, when it runs, what it must
beat and why it exists. The column contract is in
`/home/kdabrow/workspace/vault-quality-gates/vault/architecture/guard-file-formats.md`, and every
driver's keys, exit codes and default config file are in
`/home/kdabrow/workspace/vault-quality-gates/vault/architecture/qg-builtin-drivers.md`. Read both
before editing `quality/checks.tsv`.

The commit and push gates are the plugin's git hooks in `.git/hooks/`, which git never clones.
Install them once per clone, after `pnpm install`:

```
/home/kdabrow/workspace/vault-quality-gates/bin/guard.sh hooks install --claude
printf '#!/usr/bin/env bash\nexport PATH=$HOME/.local/share/pnpm/bin:$PATH; exec pnpm exec lint-staged\n' > .git/hooks/pre-commit.user
chmod +x .git/hooks/pre-commit.user
/home/kdabrow/workspace/vault-quality-gates/bin/guard.sh hooks status   # every line reads installed
```

`pre-commit` runs `.git/hooks/pre-commit.user` (lint-staged: eslint --fix + prettier) first, then
the `commit` rows. Rules a refusal points at: `quality/RULES.md`, mapped by `quality/rules.tsv`.

## Open work

| item                                                                                                                | file                                          | state |
| ------------------------------------------------------------------------------------------------------------------- | --------------------------------------------- | ----- |
| Measure `mutation` (Stryker, tens of minutes), then commit the baseline                                             | `quality/baseline.tsv` via `pnpm guard:suite` | TODO  |
| Fix the two circular imports through `api/types/auth.ts` and `api/services/locations.ts`, then lower `architecture` | `api/`                                        | TODO  |

## quality/checks.tsv — nine columns, tab separated

| column      | holds                                                                                                     |
| ----------- | --------------------------------------------------------------------------------------------------------- |
| `id`        | the metric name in the refusal, the report and `quality/baseline.tsv`                                     |
| `on`        | the events that run the row: `commit`, `push:refs/*` (every push), `baseline`, or a comma list of them    |
| `kind`      | `repo` compares with the baseline; `diff` compares with `threshold`; `absent` runs nothing                |
| `driver`    | the wrapper that runs the tool and turns its output into one number; `shell` runs a command               |
| `args`      | `key=value` words for the driver, then `-- <extra argv>`; a `shell` row's command follows `--`            |
| `direction` | `up` when a higher number is better                                                                       |
| `threshold` | for `repo` the worsening tolerated against the baseline; for `diff` the ceiling (`down`) or floor (`up`) |
| `gate`      | `refuse` blocks; `warn` prints; `record` stores the number only                                           |
| `why`       | one sentence the refusal prints; required, distinct per row, never `TODO`                                 |

A row with an unknown driver, an empty cell or no `why` stops the whole file from loading, and the
commit gate refuses that commit.

## Commands

| command               | does                                                                                            |
| --------------------- | ----------------------------------------------------------------------------------------------- |
| `qg list`             | every row: id, when it runs, driver, what refuses, and why                                      |
| `qg explain <id>`     | what one row checks, its last result and output, and how to reproduce it                        |
| `qg run push`         | what the push hook runs, without pushing                                                        |
| `qg run commit`       | what the commit hook runs on the staged tree, without committing                                |
| `pnpm guard:baseline` | re-measure every row except `mutation` and the suite, rewrite `quality/baseline.tsv`            |
| `pnpm guard:suite`    | the same, plus `tests-suite-failed` (a full test run with coverage) and Stryker                 |
| `pnpm guard:report`   | print `quality-reports/REPORT.md` from the last run                                             |
| `pnpm arch`           | list architecture violations                                                                    |
| `pnpm boundaries`     | list layer violations including Nuxt auto-imports (fallow)                                      |

`pnpm guard:baseline` skips rows by id with `--skip '^(mutation|tests-suite-failed)$'`.

## The rows

`<r>` below is `runner=quality/bin/in-node.sh`, which every node tool runs through.

| id                        | driver and what it counts                                                                                                       | on                 | gates against                             |
| ------------------------- | ------------------------------------------------------------------------------------------------------------------------------- | ------------------ | ----------------------------------------- |
| `lint-new`                | `eslint` `metric=problems lines=added`: ESLint errors and warnings on added lines of `.ts .tsx .mts .vue .js .mjs .cjs`         | commit             | ceiling 0                                 |
| `typecheck-new`           | `nuxt-typecheck` with `bin=node_modules/.bin/vue-tsc -- -b --noEmit --pretty false`: `error TS` on added lines (about 20 s)     | commit             | ceiling 0                                 |
| `duplication-new`         | `jscpd-added` with the installed jscpd and `quality/jscpd.json`: clone lines covering an added line                             | commit             | ceiling 0                                 |
| `suppressions-added`      | `shell`: added lines with `eslint-disable`, `@ts-ignore`, `@ts-expect-error`, `@ts-nocheck`                                      | commit             | ceiling 0                                 |
| `protected-paths-touched` | `shell`: paths in `guard_protected_paths` (`quality/config`) the commit changes                                                  | commit             | ceiling 0                                 |
| `tools-changed`           | `shell`: `in-node.sh --tools-diff` counts packages in the dev-tool, `nuxt` and `@nuxt/cli` closure the staged lock changes       | commit             | ceiling 0                                 |
| `lint-errors`             | `eslint` `metric=errors`: ESLint errors, whole repo                                                                             | push               | baseline                                  |
| `mess`                    | `eslint` `metric=rules`: `complexity`, `sonarjs/cognitive-complexity`, `max-depth`, `max-lines`, `max-lines-per-function`, `max-params` | push        | baseline                                  |
| `typecheck-errors`        | `nuxt-typecheck`: `error TS` occurrences from `nuxt typecheck`                                                                  | push               | baseline                                  |
| `architecture`            | `depcruise` with `.dependency-cruiser.cjs` (utils → api → composables → components → pages)                                      | push               | baseline                                  |
| `deadcode`                | `knip` with `knip.json`: the entries of every issue array knip reports                                                         | push               | baseline                                  |
| `repo-consistency`        | `shell`: `node scripts/quality-metric.mjs consistency`, the checks in `eslint-rules/lib/repo-checks.cjs`                         | push               | baseline                                  |
| `dupes-semantic`          | `fallow` `metric=dupes` (`.fallowrc.json`): duplicated lines, renamed copies included                                           | push               | baseline                                  |
| `boundaries`              | `fallow` `metric=boundaries`: the layer order of `architecture`, Nuxt auto-imported calls included                             | push               | baseline                                  |
| `complexity-excess`       | `fallow` `metric=complexity-excess`: how far each function and template is over cyclomatic 15 / cognitive 20, summed            | push               | baseline                                  |
| `duplication`             | `jscpd` `metric=percentage` with the installed jscpd and `quality/jscpd.json`                                                   | commit and push    | baseline, 0.1 tolerance on the percentage |
| `duplication-clones`      | `jscpd` `metric=clones` from the same report                                                                                    | push               | baseline                                  |
| `tests-failing`           | `vitest` `run=no metric=failed`: failures and errors on the root of `quality-reports/junit.xml`                                 | push               | ceiling 0                                 |
| `coverage`                | `vitest` `run=no metric=coverage`: line coverage from `coverage/clover.xml`                                                     | push               | baseline, 0.5 tolerance                   |
| `coverage-age-days`       | `shell`: `node scripts/quality-metric.mjs coverage-age-days`, the age of `coverage/clover.xml`                                  | push               | ceiling 7 days                            |
| `tests-suite-failed`      | `vitest` `metric=failed`: a full run with coverage writing the junit and clover reports                                         | baseline only      | ceiling 0                                 |
| `mutation`                | `stryker` with `stryker.config.json`: (Killed + Timeout) / valid mutants                                                        | baseline only      | baseline                                  |

`gate-config-touched` and `tests-suite` stay as `kind: absent` rows naming the rows that replaced them.

## Failure modes

- **No hook runs the test suite.** `tests-failing`, `coverage` and `coverage-age-days` read the reports
  the last `pnpm guard:suite` left behind. When they are older than 7 days the push is refused.
- **An unmeasurable row refuses.** A tool that crashed, an exit code its driver calls an error, a report
  left from an earlier run or an empty report never scores as clean.
- **The commit rows need the main checkout's `node_modules` and `.nuxt`.** Under commit,
  `quality/bin/in-node.sh` links the first into the staged tree and copies the second over any `.nuxt`
  there; when either is missing it exits 2 naming `pnpm install`. It never runs `nuxt prepare`.
- **The installed tools must match the committed lock.** `in-node.sh` exits 2, naming up to 10 packages,
  when the dev-tool, `nuxt` or `@nuxt/cli` closure in `node_modules/.pnpm/lock.yaml` differs from
  `HEAD:pnpm-lock.yaml`. Run `pnpm install` in that checkout on a branch with this lock.
- **A commit that changes a tool version is refused.** `tools-changed` counts every package in that closure
  the staged lock bumps, adds or removes; a human passes it with `qg override`.
- **The push rows measure this checkout as it is** (`guard_measure_worktree: false`): `node_modules` and
  `.nuxt` must exist here, and an uncommitted edit can move a metric.
- **The architecture rules see explicit imports only.** Nuxt auto-imports are invisible to
  dependency-cruiser; `boundaries` covers them. Keep the zones in `.fallowrc.json` in step with
  `.dependency-cruiser.cjs`.
- **`fallow` is pinned exactly**, because an upgrade can move all three fallow baselines.
- **Every driver passes its config file explicitly** (`eslint -c`, `knip --config`, `jscpd -c`, …), so an
  untracked `eslint.config.js` beside `eslint.config.mjs` changes nothing.
- **`.nuxt` types are copied, not regenerated.** A commit that adds a layout, a plugin or an
  auto-imported composable is typechecked against the main checkout's last `nuxt prepare`.
- **`quality/bin/in-node.sh` runs from `HEAD`.** An edit to it takes effect only once committed.

## Bypass

Only a human at a terminal overrides a refusal, once: `qg override --reason "<why>"`, then commit or
push within 10 minutes. The override is logged to `.git/guard-bypass.log` and printed at the next push.

## Configuration

| file                              | owns                                                                    |
| --------------------------------- | ----------------------------------------------------------------------- |
| `quality/checks.tsv`              | every row: driver, args, threshold and why                              |
| `quality/config`                  | `guard_commit_paths`, `guard_protected_paths`, `guard_measure_worktree` |
| `quality/baseline.tsv`            | the ratchet. Written by `pnpm guard:baseline`, never by hand            |
| `quality/bin/in-node.sh`          | the node runner every tool row names                                    |
| `quality/jscpd.json`              | clone size floor and ignored paths; `"gitignore": false`                |
| `.dependency-cruiser.cjs`         | the layer rules                                                         |
| `.dependency-cruiser.aliases.cjs` | the `~` and `@` aliases the resolver needs                              |
| `.fallowrc.json`                  | fallow's duplicate mode and layer zones                                 |
| `knip.json`, `stryker.config.json`, `vitest.config.ts`, `eslint.config.mjs` | the config each driver passes to its tool     |
| `scripts/quality-metric.mjs`      | `repo-consistency` and `coverage-age-days`                              |
| `.jscpd.json`, `.betterer.cjs`    | the older `pnpm dup` and `pnpm betterer:ci` ratchets, unchanged         |
