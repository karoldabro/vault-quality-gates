# vault-quality-gates

A plugin for the [vault knowledge framework](https://github.com/karoldabro/vault). It **refuses a
commit that adds a violation**, measured on exactly the tree being committed, and **refuses a push to
a release branch when a measured metric is worse than its committed baseline**.

Exit codes are the same everywhere: 0 measured and acceptable, 1 measured and worse, 2 could not
measure. A check that could not run is never recorded as passing.

## If you are an agent wiring this into a repo, read this section first

**The runner is here. Your job in a target repo is data, not code.**

Wiring a repo means writing rows into its `quality/checks.tsv` and values into its
`quality/baseline.tsv`. It does not mean writing shell scripts, git hooks, or a report generator.
Those exist. A parallel implementation in the target repo cost one session most of its length and
was deleted whole.

Four steps, in order:

1. **Read `vault/plans/2026-09-14-1251-quality-regression-gate.md`.** It is the specification: the
   work items, the file formats, the decisions and the success criteria. A `vault/plans/*.md` in a
   repo you are about to change is a build order, not background reading.
2. **Read `vault/architecture/guard-file-formats.md`.** Nine columns, four columns, the parser
   calling convention, the refusal text. This is a contract to satisfy, not reference material.
3. **Read the target repo's own `quality/README.md`**, written by `extend/init.sh` during
   `/v-init`. It carries the columns, the parsers that ship, and the plugin's absolute path.
4. **Run each command once before you write its row.** A row whose command was never run gates a
   push on a guess.

Before proposing any tool, check it exists and is maintained. A recommendation carries a version and
a release date or it is not made.

## What it does

- The `pre-commit`, `pre-merge-commit` and `pre-applypatch` hooks run `guard.sh commit` on a copy of
  the index and **refuse** the commit when a `commit` row is worse or unmeasurable. The refusal lists
  each new finding with its row id and, through `quality/rules.tsv`, the catalog rule to read. A pass
  writes a pass record.
- A `pre-push` hook refuses any pushed commit that never passed the commit gate, such as a
  cherry-pick or a revert; `guard.sh verify <range>` measures and records those. On a release branch
  it also measures the branch against its merge-base and **refuses** the push when a gated metric got
  worse, naming the metric, both values, the tolerance, and the command that accepts the change.
- Only a human at a terminal can override a refusal, once, with `QG_SKIP_REASON="<why>"`. Every
  override is logged to `<git-common-dir>/guard-bypass.log` and printed at the next push.
- `hooks install --claude` adds two Claude Code `PreToolUse` hooks that deny an agent the commands
  and edits that would skip or disable the git hooks. Both need `python3` on `PATH`: the Bash guard
  tokenises the command with real shell quoting (`$'..'`, heredocs, `$(...)`), which a shell
  pattern match cannot do. Without `python3` each hook denies every call.
- Metrics are per repo: coverage, mutation score, duplication, comment density, lint, static
  analysis. Each is one row in that repo's `quality/checks.tsv`.
- The ratchet lives in `quality/baseline.tsv`, committed, so it travels with the branch and is
  visible in review.

**Nothing whole-repo runs at push time.** A suite that takes an hour makes the gate unusable and it
gets bypassed. Slow measurements carry `scope: baseline` and run out of band.

## What ships

| path | holds |
|---|---|
| `bin/guard.sh` | subcommands `commit verify release baseline report accept hooks` |
| `bin/guard-added-lines.sh`, `bin/guard-baseline-growth.sh`, `bin/guard-protected-paths.sh` | the counts commit rows compare: findings on added lines, baseline growth, protected paths touched |
| `bin/guard-report-errors.sh` | the refusal lines a refused commit prints |
| `lib/guard-metrics.sh` | `guard_load_checks` `guard_parse_row` `guard_compare` `guard_baseline_diff` `guard_accept_count` `guard_substitute` |
| `lib/guard-commit.sh`, `lib/guard-tree.sh`, `lib/guard-diff.sh`, `lib/guard-pass.sh` | the commit gate, the measured tree copy, added-line diffs, parents and pass records |
| `lib/guard-baseline-neon.awk`, `lib/guard-baseline-phpmd.awk` | baseline entry keys, and the generator-shape check that makes a hand-edited baseline unmeasurable |
| `lib/guard-hook.sh`, `lib/guard-override.sh` | the hook bodies (commit hooks, `pre-push` record check, `post-rewrite` verify); the human-only override and its log |
| `lib/guard-report.sh`, `lib/guard-status.jq` | `status.json` under six fixed category keys, `REPORT.md` under four headings |
| `lib/guard-install.sh` | `hooks install [--claude] remove status`, marker-guarded |
| `lib/guard-parsers/*.sh` | clover, junit, infection, jscpd, insights, phpstan, phpstan-all, phpmd, cda, cloc, diffcover, exitcode |
| `templates/git-hooks/*` | `pre-commit`, `pre-merge-commit`, `pre-applypatch`, `pre-push`, `post-rewrite` |
| `templates/claude-hooks/*` | the `PreToolUse` guards `guard-bash.sh` and `guard-edit.sh` |
| `extend/` | the framework extension points — `init` scaffolds a repo, `dod-keys` declares its `VAULT.md` keys |

**The git hooks are written into `.git/hooks/`.** An agent sees a refusal because it ran
`git commit` or `git push` and read stderr. The Claude Code hooks run from this checkout, by
absolute path, and are listed in the target repo's `.claude/settings.json`.

Contracts: `vault/architecture/guard-file-formats.md` (files, tokens, parsers) and
`vault/architecture/guard-commit-gate.md` (the commit gate, hooks, pass records, override).

## Installing

```
/v-plugin vault-quality-gates          # register with the framework
```

Then `/v-init` in a target repo runs this plugin's `init` point, which scaffolds `quality/` and
writes that repo's own brief.

## Known limits

- **A commit made without the commit hooks has no pass record**: `cherry-pick`, `revert`, `rebase`,
  `am` without `pre-applypatch`, and scripted commits. `pre-push` refuses it until
  `bin/guard.sh verify <range>` measures and records it. An amend is measured again by `post-rewrite`,
  which runs `guard.sh verify` on the new commit, so every amend costs a second gate run.
- **The gate is client-side.** An agent that runs a script file which commits with hooks disabled and
  pushes without hooks passes it. The Claude Code hooks deny the forms typed directly; only a
  server-side required check closes the rest.

- **A repo whose toolchain is bound to its checkout path cannot be measured from a detached
  worktree.** `GUARD_SHA` checks the pushed commit out under `/tmp`, which has no `vendor/`, no
  `node_modules` and no container bind-mount. Set `guard_measure_worktree: false` in that repo's
  `VAULT.md` to measure the working tree instead, and accept that uncommitted edits then count.
- `/v-guard`, the onboarding command that would fill `checks.tsv` interactively, does not exist.
  Filling it is a session's job, following the four steps above.

## Process record

`vault/reviews/2026-09-14-session-postmortem.md` — what the first real wiring session got wrong,
and the framework defects it found. The only file here that reports its own process.
