---
type: plan
project: vault-quality-gates
slug: quality-regression-gate-test-design
repos: [vault-quality-gates]
status: proposed
tags: [plan, quality, gates, testing]
---

# quality-regression-gate — test design

The contract document is `2026-09-14-1251-quality-regression-gate.md`. It carries the success
criteria, the work items and the file formats. This file carries only the test design they bind.

## Harness

Bats, in Docker, via `./tests/run.sh tests/unit`. That harness does not exist in this repo yet;
W-C0 copies `tests/run.sh` and `tests/Dockerfile` from the framework at `$VAULT_FRAMEWORK_PATH`.

`tests/unit/guard-metrics.bats` drives `lib/guard-metrics.sh` against `tests/fixtures/guard/`.
`tests/unit/guard-hooks.bats` feeds `templates/git-hooks/pre-push` real four-field stdin lines
through a pipe and asserts the writer's exit status.

Every test that asserts a write builds its tree under `mktemp -d`. The repo is mounted read-only,
so a write assertion against the mount passes vacuously.

## Decision table — `guard_compare`, one row

| kind | baseline row | measured | beyond threshold | outcome |
|---|---|---|---|---|
| repo | present | value | yes | exit 1, named in the brief |
| repo | present | value | no | exit 0 |
| repo | present | unmeasurable | — | exit 2 |
| repo | absent | value | — | exit 0, appended at `gate: record` |
| diff | ignored | value past the floor | — | exit 1 |
| absent | ignored | none | — | exit 0, rendered as absent, never executed |

## Fault hypotheses

A parser prints an empty string and the comparison reads it as zero, turning a missing measurement
into the worst score. A tool leaves a previous run's artifact in place and the parser reports a
stale number as current. A hook exits before draining stdin and `git push` dies with 141 while the
hook reports success. `awk` is compiled without float support in a minimal container. `awk` honours
`LC_NUMERIC` and prints `4,04` under a European locale, which no parser can read back.

## Boundary partitions

A delta exactly equal to `threshold` passes. A baseline of `0` with `direction: down` must not
divide by zero. A value of `100` against a baseline of `100` with `direction: up` is not a
regression. A `checks.tsv` with only comment lines yields no checks and exits 2 rather than
reporting a clean run.

## Test backlog

| id | source | kind | target (exact path) | intent | priority | disposition |
|----|--------|------|---------------------|--------|----------|-------------|
| T-1 | SC-1 | unit | `tests/unit/guard-metrics.bats` | a worse value exits 1 and the brief names the metric, both values and the tolerance | must | |
| T-2 | SC-2 | unit | `tests/unit/guard-metrics.bats` | a null `msi` exits 2 and is never rendered as a pass | must | |
| T-3 | SC-2 | unit | `tests/unit/guard-metrics.bats` | an absent artifact exits 2, not 0 | must | |
| T-4 | SC-2 | unit | `tests/unit/guard-metrics.bats` | an empty parser result exits 2 rather than comparing as zero | must | |
| T-5 | SC-2 | unit | `tests/unit/guard-metrics.bats` | a check command exiting 127 exits 2, never a recorded metric | must | |
| T-6 | consumer | unit | `tests/unit/guard-metrics.bats` | a row whose field count differs from the header exits 2 and runs no command | must | |
| T-7 | consumer | unit | `tests/unit/guard-metrics.bats` | the header `extend/init.sh` writes parses through `guard_load_checks` and lists exactly the fields the parser binds | must | |
| T-8 | consumer | unit | `tests/unit/guard-metrics.bats` | a `kind: absent` row is rendered in the report, never executed, never compared | must | |
| T-9 | dossier | unit | `tests/unit/guard-metrics.bats` | a delta exactly equal to `threshold` passes | must | |
| T-10 | dossier | unit | `tests/unit/guard-metrics.bats` | a baseline of `0` with `direction: down` does not divide by zero | should | |
| T-11 | SC-5 | unit | `tests/unit/guard-metrics.bats` | deleting the tolerance comparison from `guard_compare` turns the suite red | must | |
| T-12 | SC-4 | unit | `tests/unit/guard-metrics.bats` | a pushed tree lowering a baseline row with an empty `reason` exits 1, and a populated reason passes | must | |
| T-13 | E-4 | unit | `tests/unit/guard-metrics.bats` | a fourth baseline row carrying an accept reason exits 1 | should | |
| T-14 | skeptic | unit | `tests/unit/guard-metrics.bats` | `accept --reason` writes the row under `mktemp -d` while bare `accept` leaves the file byte-identical | must | |
| T-15 | SC-3 | unit | `tests/unit/guard-hooks.bats` | a skipped non-release push leaves the writer at exit 0, not 141 | must | |
| T-16 | SC-3 | unit | `tests/unit/guard-hooks.bats` | `refs/heads/release/1.17.0` on stdin runs the release suite | must | |
| T-17 | SC-3 | unit | `tests/unit/guard-hooks.bats` | a `(delete)` line runs no check and still drains stdin | should | |
| T-18 | quality | unit | `tests/unit/guard-hooks.bats` | a `VAULT.md` omitting `guard_release_pattern` still gates `refs/heads/release/*` and names the fallback | should | |
| T-19 | quality | unit | `tests/unit/guard-metrics.bats` | editing one source file between two runs changes the metric, catching a parser reading a stale artifact | must | |
| T-20 | consumer | unit | `tests/unit/guard-metrics.bats` | a `{{files}}` substitution for a two-file diff, one path containing a space, runs the tool exactly once | must | |
| T-21 | consumer | unit | `tests/unit/guard-metrics.bats` | a file whose line 1 is not the literal header exits 2, and a commented-out header is not accepted as one | must | |
| T-22 | consumer | unit | `tests/unit/guard-metrics.bats` | a `baseline.tsv` row whose `value` is not a number exits 2 and never scores as clean | must | |
| T-23 | skeptic | unit | `tests/unit/guard-hooks.bats` | an all-zeroes remote sha skips `guard_baseline_diff`, prints that it skipped, and returns 0 | must | |
| T-24 | SC-7 | unit | `tests/unit/guard-metrics.bats` | an uncommitted edit in the working tree does not change the metric measured for the pushed sha | must | |
| T-25 | consumer | unit | `tests/unit/guard-metrics.bats` | a `kind: absent` row carrying `-` in scope, direction, threshold and gate parses, renders, and runs nothing | should | |
| T-26 | B-2 | unit | `tests/unit/guard-metrics.bats` | under `LC_NUMERIC=es_ES.UTF-8` every parser still emits a dot decimal separator | must | |
| T-27 | B-6 | unit | `tests/unit/guard-metrics.bats` | with `guard_measure_worktree: false` the runner measures the working tree and never creates a detached worktree | must | |
