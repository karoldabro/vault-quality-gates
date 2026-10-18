# vault-quality-gates

A plugin for the [vault knowledge framework](https://github.com/karoldabro/vault). It **refuses a
commit that adds a violation**, measured on exactly the tree being committed, and **refuses a push
when a measured metric is worse than its limit or its committed baseline**.

Exit codes are the same everywhere: 0 measured and acceptable, 1 measured and worse, 2 could not
measure. A check that could not run is never recorded as passing.

## If a gate refused you

Run these three commands, in order:

```
qg last              # the whole refusal again, with every failing row
qg explain <id>      # what that row checks, why, its last output, and how to pass
qg run commit        # run the commit gate on what is staged now, without committing
```

Fix the code, `git add` it, and commit again. `qg run push --ref refs/heads/<branch>` runs the push
gate the same way.

**Only a human at a terminal may override a refusal**, once, when the gate itself is wrong:

```
qg override --reason "<why>"             # then commit again within 10 minutes
QG_SKIP_REASON="<why>" git commit        # the same, in one line
```

**Failure mode:** `QG_SKIP_REASON="<why>" && git commit` never reaches the hook. The variable is not
exported, so the hook refuses the commit. Write the variable on the same command as `git commit`,
or use `qg override`. An agent may not override; it stops and tells the operator.

## `qg`, the command for people and agents

A gate is one row of `quality/checks.tsv`. Each row runs a driver, which wraps one tool and yields
one number. The engine compares that number with the row's limit or with `quality/baseline.tsv`.
The row's `on` cell says which events run it: `commit`, `push`, `push:<ref-glob>` or `baseline`.

`qg list` shows every row and why it exists. `qg doctor` checks the setup. `qg help` lists every
subcommand. Every subcommand takes `--json`. An agent may run only the read subcommands and
`qg run`.

- Every subcommand, its exit codes and its `--json` shape: `vault/architecture/qg-cli.md`.
- How to write a driver: `vault/architecture/qg-driver-contract.md`.

## If you are an agent wiring this into a repo, read this section first

**The engine, the hooks and the report generator are here.** Wiring a repo means writing rows into
its `quality/checks.tsv` and values into its `quality/baseline.tsv`. Write a repo driver only when
no built-in driver fits; a human commits it.

Four steps, in order:

1. **Read `vault/plans/2026-10-18-1121-qg-common-interface.md`.** It is the build order for the
   `qg` interface and the per-repo migration.
2. **Read `vault/architecture/guard-file-formats.md`.** It defines the v2 columns, the `on` grammar,
   the tokens and the key file. Treat it as a contract to satisfy.
3. **Read the target repo's own `quality/README.md`**, written by `extend/init.sh` during `/v-init`.
4. **Run each command once before you write its row.** A row whose command never ran gates a push on
   a guess.

Before proposing any tool, check it exists and is maintained. A recommendation carries a version and
a release date or it is not made.

## What it does

- The `pre-commit`, `pre-merge-commit` and `pre-applypatch` hooks run `guard.sh commit` and
  **refuse** the commit when a row whose `on` holds `commit` is worse or unmeasurable. The refusal
  prints each row's `why`, its findings, its output and how to pass. A pass writes a pass record. A
  `warn` row's findings print under `vault-guard: warnings` and never refuse the commit.
- The `pre-push` hook refuses any pushed commit that never passed the commit gate, such as a
  cherry-pick or a revert; `qg verify <range>` measures and records those. It then hands every pushed
  ref to `guard.sh release`. The engine runs the rows whose `on` matches that ref, and exits 0 when
  none does.
- **A baseline only gets tighter.** No `checks.tsv` row can drop this check. A `quality/baseline.tsv`
  row with a worse value, a changed reason, or a removed `kind: repo` row is refused. So is deleting
  `quality/checks.tsv` or `quality/rules.tsv`.
- **Gate configuration is a human's change.** A commit that changes `quality/drivers/` or
  `quality/config`, or stages a `checks.tsv` that does not load, is refused until a human overrides.
- The configuration that judges a commit is its parent's. `GUARD_CONFIG_REV=<sha>` pins it outside
  an agent session; the agent factory uses the pin so a build cannot loosen its own gate.
- Every override is logged to `<git-common-dir>/guard-bypass.log` and printed at the next push.
- `qg hooks install --claude` adds two Claude Code `PreToolUse` hooks that deny an agent the
  commands and edits that would skip, disable or loosen the gate. It also adds a `Stop` hook
  (`guard-stop.sh`) that blocks the end of a turn once while HEAD carries commits on no remote, so
  the push gate runs while the agent can still fix the result. On the default branch, `development`,
  `develop` or a detached HEAD it asks for a new branch instead. It gives up after 5 blocks on the
  same commit and logs that to `guard-bypass.log`.
- A repo's own pre-commit step, such as `lint-staged`, goes in `.git/hooks/pre-commit.user`. The
  installed `pre-commit` runs it first, and a reinstall never touches it.
- The Claude Code hooks need `python3` on `PATH`: the Bash guard tokenises the command with real
  shell quoting (`$'..'`, heredocs, `$(...)`). Without `python3` each hook denies every call.

**Nothing whole-repo runs at commit time.** A suite that takes an hour makes the gate unusable, and
people bypass it. Slow rows carry `on: push:<glob>` or `on: baseline`.

## What ships

| path | holds |
|---|---|
| `bin/qg` | the command for people and agents: `list run explain last drivers doctor config override init migrate hooks` |
| `bin/guard.sh` | the engine: `commit verify release baseline report accept hooks` |
| `bin/guard-added-lines.sh`, `bin/guard-baseline-growth.sh`, `bin/guard-protected-paths.sh` | the counts commit rows compare: findings on added lines, baseline growth, protected paths touched |
| `bin/guard-report-errors.sh` | the finding lines a refusal and a `warn` row print |
| `drivers/phpstan.sh`, `drivers/shell.sh` | the built-in drivers; `phpstan.sh` is the worked example of the driver contract |
| `lib/guard-metrics.sh` | `guard_load_checks` (v1 and v2), `guard_run_driver`, `guard_run_shell`, `guard_compare`, `guard_baseline_diff` |
| `lib/qg-events.sh` | the `on` grammar and which rows an event runs |
| `lib/qg-config.sh` | the one reader of gate keys: `quality/config`, else `VAULT.md` |
| `lib/qg-refusal.sh` | the refusal text and `qg-last/REFUSAL.txt` |
| `lib/qg-explain.sh`, `lib/qg-doctor.sh`, `lib/qg-migrate.sh` | `qg explain`; `qg doctor`; `qg migrate` and `qg init` |
| `lib/guard-commit.sh`, `lib/guard-tree.sh`, `lib/guard-diff.sh`, `lib/guard-pass.sh` | the commit gate and its built-in checks, the measured tree copy, added-line diffs, parents and pass records |
| `lib/guard-baseline-neon.awk`, `lib/guard-baseline-phpmd.awk` | baseline entry keys, and the generator-shape check that makes a hand-edited baseline unmeasurable |
| `lib/guard-hook.sh`, `lib/guard-override.sh` | the hook bodies; the human-only override, its token and its log |
| `lib/guard-report.sh`, `lib/guard-status.jq` | `status.json` under six fixed category keys, `REPORT.md` under four headings |
| `lib/guard-install.sh` | `hooks install [--claude] remove status`, marker-guarded |
| `lib/guard-parsers/*.sh` | the `shell` driver's parsers: clover, junit, infection, jscpd, insights, phpstan, phpstan-all, phpmd, cda, cloc, diffcover, exitcode |
| `templates/init/*.tsv` | starter `checks.tsv` rows per profile: `docs`, `php`, `nuxt`, `flutter`, `hugo` |
| `templates/git-hooks/*` | `pre-commit`, `pre-merge-commit`, `pre-applypatch`, `pre-push`, `post-rewrite` |
| `templates/claude-hooks/*` | the `PreToolUse` guards `guard-bash.sh` and `guard-edit.sh`, the `Stop` hook `guard-stop.sh` |
| `extend/` | the framework extension points: `init` scaffolds a repo, `dod-keys` declares its keys |

**The git hooks are written into `.git/hooks/`.** An agent sees a refusal because it ran
`git commit` or `git push` and read stderr. The Claude Code hooks run from this checkout, by
absolute path, and are listed in the target repo's `.claude/settings.json`.

Contracts: `vault/architecture/guard-file-formats.md` (files, tokens, keys, generated files),
`vault/architecture/guard-commit-gate.md` (the commit gate, hooks, built-in checks, override),
`vault/architecture/qg-cli.md` and `vault/architecture/qg-driver-contract.md`.
The decision record is `vault/decisions/ADR-001-driver-contract.md`.

## Installing

```
/v-plugin vault-quality-gates          # register with the framework
```

Then `/v-init` in a target repo runs this plugin's `init` point, which scaffolds `quality/` and
writes that repo's own brief. A repo outside the framework runs `qg init --profile <p>`, then
`qg hooks install --claude`, then `qg doctor`.

## Known limits

- **A commit made without the commit hooks has no pass record**: `cherry-pick`, `revert`, `rebase`,
  `am` without `pre-applypatch`, and scripted commits. `pre-push` refuses it until
  `qg verify <range>` measures and records it. `post-rewrite` measures an amend again with
  `guard.sh verify`, so every amend costs a second gate run.
- **The gate is client-side.** An agent that runs a script file which commits with hooks disabled and
  pushes without hooks passes it, including through `make`, `pnpm run` or an interpreter script.
  The Claude Code hooks deny the forms typed directly, and only in a session whose project is the
  gated repo. Only a server-side required check closes the rest.
- **A repo whose toolchain is bound to its checkout path cannot be measured from a detached
  worktree.** The push gate checks the pushed commit out under `/tmp`, which has no `vendor/`, no
  `node_modules` and no container bind-mount. Set `guard_measure_worktree: false` in that repo's
  `quality/config` (or `VAULT.md`) to measure the working tree instead. A push is then refused while
  tracked files are dirty or HEAD is not the pushed commit, so the tree measured is the tree pushed.
  A row with `runner=` runs its tool inside the toolchain instead (`vault/architecture/qg-driver-contract.md`).

## Process record

`vault/reviews/2026-09-14-session-postmortem.md` is the only file here that reports its own process.
