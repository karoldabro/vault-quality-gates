# vault-quality-gates

A plugin for the [vault knowledge framework](https://github.com/karoldabro/vault). It measures a
repository's code quality and **refuses a push to a release branch when a metric is worse than its
committed baseline**.

Exit codes are the same everywhere: 0 measured and acceptable, 1 measured and worse, 2 could not
measure. A check that could not run is never recorded as passing.

## What it does

- A `pre-commit` hook measures the staged diff and records the result. It never blocks.
- A `pre-push` hook to a release branch measures the branch against its merge-base and **refuses**
  the push when a gated metric got worse. The refusal names the metric, both values, the tolerance,
  and the command that accepts the change deliberately.
- Metrics are per repo: coverage, mutation score, duplication, comment density, lint, and whatever
  else that repo's stack supports. Each is a row in `quality/checks.tsv`.
- The ratchet lives in `quality/baseline.tsv`, committed, so it travels with the branch and is
  visible in review.

## Status

Designed, not built. The plan is `vault/plans/2026-09-14-1251-quality-regression-gate.md`; the file
formats it commits to are `vault/architecture/guard-file-formats.md`. The six scripts under
`checks/` are the gate's own success-criteria checks and currently report `cannot say`, because the
test suite they grade is not written yet.

## Requires

The vault framework, at a version that ships the plugin extension points. This repo registers itself
with `vault-plugin.sh add`, and the framework then calls its `extend/` entry points during per-repo
init.
