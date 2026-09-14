# vault-quality-gates

A plugin for the [vault knowledge framework](https://github.com/karoldabro/vault). It **refuses a
push to a release branch when a measured metric is worse than its committed baseline**.

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

- A `pre-commit` hook measures the staged diff and records the result. It never blocks.
- A `pre-push` hook to a release branch measures the branch against its merge-base and **refuses**
  the push when a gated metric got worse. The refusal names the metric, both values, the tolerance,
  and the command that accepts the change deliberately.
- Metrics are per repo: coverage, mutation score, duplication, comment density, lint, static
  analysis. Each is one row in that repo's `quality/checks.tsv`.
- The ratchet lives in `quality/baseline.tsv`, committed, so it travels with the branch and is
  visible in review.

**Nothing whole-repo runs at push time.** A suite that takes an hour makes the gate unusable and it
gets bypassed. Slow measurements carry `scope: baseline` and run out of band.

## What ships

| path | holds |
|---|---|
| `bin/guard.sh` | subcommands `commit release baseline report accept hooks` |
| `lib/guard-metrics.sh` | `guard_load_checks` `guard_parse_row` `guard_compare` `guard_baseline_diff` `guard_accept_count` `guard_refusal` |
| `lib/guard-report.sh`, `lib/guard-status.jq` | `status.json` under six fixed category keys, `REPORT.md` under four headings |
| `lib/guard-install.sh` | `hooks install remove status`, marker-guarded |
| `lib/guard-parsers/*.sh` | clover, junit, infection, jscpd, insights, phpstan, cda, cloc, diffcover, exitcode |
| `templates/git-hooks/pre-push` | drains stdin, matches `guard_release_pattern`, exports `GUARD_SHA` |
| `templates/git-hooks/pre-commit` | runs `guard.sh commit`, always exits 0 |
| `extend/` | the framework extension points — `init` scaffolds a repo, `dod-keys` declares its `VAULT.md` keys |

**The hooks are git hooks**, written into `.git/hooks/`. They are not Claude Code hooks. An agent
sees a refusal because it ran `git push` and read stderr.

## Installing

```
/v-plugin vault-quality-gates          # register with the framework
```

Then `/v-init` in a target repo runs this plugin's `init` point, which scaffolds `quality/` and
writes that repo's own brief.

## Known limits

- **A repo whose toolchain is bound to its checkout path cannot be measured from a detached
  worktree.** `GUARD_SHA` checks the pushed commit out under `/tmp`, which has no `vendor/`, no
  `node_modules` and no container bind-mount. Set `guard_measure_worktree: false` in that repo's
  `VAULT.md` to measure the working tree instead, and accept that uncommitted edits then count.
- `/v-guard`, the onboarding command that would fill `checks.tsv` interactively, does not exist.
  Filling it is a session's job, following the four steps above.

## Process record

`vault/reviews/2026-09-14-session-postmortem.md` — what the first real wiring session got wrong,
and the framework defects it found. The only file here that reports its own process.
