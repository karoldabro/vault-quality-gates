---
type: plan
project: vault-quality-gates
slug: quality-regression-gate
repos: [vault-quality-gates, recycling-api]
status: proposed
process_record: 2026-09-14-1251-quality-regression-gate.trail.md
session:
tags: [plan, quality, gates, hooks]
---

# quality-regression-gate — plan

## Task

Build `/v-guard`: a per-repo code-quality runner that refuses a push to a release branch when a
measured metric is worse than its committed baseline. Keywords: `guard`, `baseline`, `regression`,
`pre-push`, `mutation`, `coverage`, `duplication`.

## Open & deferred

| item | state |
|---|---|
| The whole runner — `bin/` `lib/` `templates/` — is untracked in this repo, and `recycling-api/.git/hooks/pre-push` calls it by absolute path. A `git clean -fd` here refuses every release push there. | open — W-48, do first |
| `recycling-api`'s Docker stack is down; `docker compose ps` returns nothing. Ten of its sixteen rows run through `docker compose exec -T server`, so they measure nothing and the push is refused. Bring the stack up before any release push. | open — operational precondition |
| The mail cause of the 1392 errors is fixed, but the 40 recorded failures were never diagnosed; the run that measures them is W-51. | open — blocks W-51 |
| The framework fix to `scripts/completion-hook.sh` lives in `~/workspace/vault` and is copied into the plugin cache at `~/.claude/plugins/cache/kdabro-vault/vault/1.8.0/`. A plugin re-release overwrites the cache copy, so the source change must ship before the next `/v-plugin` update. | open — outside this repo |
| A whole-repo coverage run on `recycling-api` takes 57m36s. No hook runs it. `bin/guard.sh baseline` does, out of band, and the operator schedules it. Push-time checks are diff-scoped only. | open — needs the operator's agreement |
| Dart has no diff-scoped mutation tool. Flutter repos carry `mutation` as a `kind: absent` row. | open — no fix exists |
| `~/vault/givore/quality/build-dashboard.mjs` parses `quality-reports/status.json`. W-9 keeps writing that file so the aggregator is untouched. Retiring it is a later decision. | deferred |

## Open questions

| id | question | blocks | searched | status | answer |
|----|----------|--------|----------|--------|--------|
| Q-1 | How does a worse metric reach the AI | yes | `~/vault/givore/quality/`, `hooks/hooks.json` | answered | A `pre-push` git hook refuses the push and prints the remediation brief |
| Q-2 | What mutation scope fits a push | yes | claude-mem #62963, infection CLI docs | answered | Changed lines only, via `--git-diff-lines --git-diff-base` |
| Q-3 | How many repos in the first delivery | yes | `~/vault/_global/coupled-groups.md` | answered | This framework repo, then `recycling-api` |
| Q-4 | Does a 58-minute suite belong at push time | yes | `recycling-api/storage/coverage/run.log` | defaulted | No. Push-time is diff-scoped; whole-repo metrics refresh via `bin/guard.sh baseline` |
| Q-5 | Hook manager or raw git hooks | no | lefthook docs, `install.sh:84-101` | defaulted | Raw git hooks written by `bin/guard.sh hooks install` |

## File formats

`vault/architecture/guard-file-formats.md` carries the nine columns of `quality/checks.tsv`, the four
of `quality/baseline.tsv`, and the parser calling convention. Every work item below is written
against it.

## Success criteria

| id | criterion | kind | how | check | expect | verdict | evidence |
|----|-----------|------|-----|-------|--------|---------|----------|
| SC-1 | WHEN a `kind: repo` metric is worse than its baseline beyond `threshold` THE SYSTEM SHALL exit 1 naming the metric, both values and the tolerance | unit | command | `checks/guard-SC-1.sh` | exit 0 | | |
| SC-2 | WHEN a check command fails, its artifact is absent, or its parser prints nothing THE SYSTEM SHALL exit 2 and record no value | unit | command | `checks/guard-SC-2.sh` | exit 0 | | |
| SC-3 | WHEN `pre-push` runs THE SYSTEM SHALL consume every stdin line before exiting, on the skip path as well as the gated path | unit | command | `checks/guard-SC-3.sh` | exit 0 | | |
| SC-4 | WHEN the pushed tree lowers a `quality/baseline.tsv` row against the remote's copy with an empty `reason` THE SYSTEM SHALL exit 1 | unit | command | `checks/guard-SC-4.sh` | exit 0 | | |
| SC-5 | WHEN the tolerance comparison is deleted from `guard_compare` THE SYSTEM SHALL turn `tests/unit/guard-metrics.bats` red | unit | command | `checks/guard-SC-5.sh` | exit 0 | | |
| SC-7 | WHEN the hook runs with uncommitted edits in the working tree THE SYSTEM SHALL measure the commit being pushed and ignore those edits | unit | command | `checks/guard-SC-7.sh` | exit 0 | | |
| SC-6 | WHEN a release branch of this repo is pushed with a metric made worse THE SYSTEM SHALL refuse the push and name the metric | delivery | observed | clone this repo to `mktemp -d`, install the hooks there, worsen `comment-density`, `git push --dry-run` to a bare clone; fails when the push succeeds, or when the refusal names no metric and no file path; `no-command: the refusal must come from git invoking the installed hook, which no in-process fixture reproduces` | push refused, stderr names the metric and `quality/baseline.tsv` | | |

## Definition of done

| id | line | state | evidence |
|----|------|-------|----------|
| D-1 | `test_command` passes: `./tests/run.sh tests/unit` | | |
| D-2 | `lint_command` passes: `./bin/doc-lint.sh --changed` | | |
| D-3 | `delivery_command` passes: `./bin/gate.sh all <plan> --phase close --run` | | |

## Enforcement states

| id | ruling | state | mechanism |
|----|--------|-------|-----------|
| E-1 | A metric worse than baseline refuses the push | OPEN | `guard_compare` in `lib/guard-metrics.sh`, called by `templates/git-hooks/pre-push` |
| E-2 | An unmeasurable check is a refusal, not a pass | OPEN | `guard_parse_row` returns 2; `bin/guard.sh` maps 2 to refusal |
| E-3 | A lowered baseline refuses unless it carries a reason; an all-zeroes remote sha skips the check and says so | OPEN | `guard_baseline_diff` compares the pushed file against the remote ref |
| E-4 | Accepted regressions above `guard_accept_limit` refuse the push, and `baseline` clears them | OPEN | `guard_accept_count` in `lib/guard-metrics.sh`; the limit is a `VAULT.md` scalar defaulting to 3 |
| E-5 | A git hook may refuse its host; a Claude Code hook may not | OPEN | `vault/indications/git-hooks-may-refuse.md` and the scope edit at W-40 |

## Verified current state

- A `pre-push` hook that exits without draining stdin kills `git push` with 141 while reporting
  success. Reproduced: 20000 ref lines into a hook doing one `read`, then
  `echo ${PIPESTATUS[0]}` → `writer=141 hook=0`. 2026-09-14.
- `git push --dry-run` runs the `pre-push` hook. Reproduced against a bare repo under `/tmp`,
  hook stderr printed, branch not created. 2026-09-14.
- `recycling-api/storage/coverage/run.log` records `Time: 57:36.820`, so a whole-repo suite there
  costs 57 minutes. `grep -aoE 'Time: [0-9:.]+'`, 2026-09-14.
- `recycling-api/storage/coverage/junit.xml`, written 2026-09-14 23:13, carries
  `tests="6513" errors="1392" failures="40"` on its root `<testsuite>`. All 1392 errors share one
  type, `Symfony\Component\Mailer\Exception\TransportException`, reaching for `mailpit:1025`:
  `grep -o '<error type="[^"]*"' … | sort | uniq -c` returns exactly one line. 2026-09-15.
- PHPUnit's `<env name="X" value="Y" force="true"/>` writes `getenv()` and `$_ENV` but never
  `$_SERVER`. Probed under `--bootstrap`: `getenv='array' _ENV='array' _SERVER='smtp'`. Laravel's
  Env repository reads `$_SERVER`, so an `<env>` line alone cannot override a variable Docker
  Compose sets. A `<server>` line beside it can. 2026-09-15.
- `phpunit.xml` and `docker-compose.yml` both set `DB_PORT`, `DB_SSLMODE` and `MAIL_MAILER`. The
  first two carry identical values, so only `MAIL_MAILER` ever diverged. `comm -12` over the two
  name lists, 2026-09-15.
- `docker compose ps` in `recycling-api` returns nothing, so every row carrying
  `docker compose exec -T server` is unmeasurable while the stack is down. 2026-09-15.
- `~/vault/givore/quality/history.jsonl` holds 4 rows, all stamped `2026-06-22T13:11`.
  `/home/kdabrow/.givore-qa-nightly.log` holds 24 lines of `pnpm: not found`. A cron that never ran
  read as green for three months.
- `recycling-api/quality-reports/status.json` is written by `guard_render_report` and last read
  `phpstan-errors` at 240 against a baseline of 245, so the comparison discriminates on real data.
- `recycling-api/.gitignore:52` already carries `/quality-reports`.
- `bin/gate.sh` runs a check with zero arguments, cwd at the repo root, and keeps only its last
  stdout line (`bin/gate.sh:642`). `VAULT.md` keys are read as flat scalars (`bin/gate.sh:439`).
- `tests/run.sh:24` reads only `$1`; a second argument is discarded. The repo is mounted read-only,
  so any test asserting "writes nothing" passes vacuously unless it builds a tree under `mktemp -d`.
- `cloc 1.98` emits `SUM.comment` and `SUM.code` in `--json`. On `recycling-api` the ratio is 0.274
  over `app` and 0.425 including `vendor`, so the scanned path must be pinned.
- Infection supports `--git-diff-lines` and `--git-diff-base=<ref>` since 0.26.0. StrykerJS has no
  `--since`; it uses `--incremental` with `incrementalFile`. `phpcpd` is abandoned.
- `recycling-api/.git/hooks/pre-push` and `pre-commit` carry the `# vault-guard-start` block and
  name `bin/guard.sh` by absolute path, so the gate breaks if this repo moves.
- `extend/init.sh:54-64` writes the nine-column `quality/checks.tsv` header, with no rows, into the
  repo being wired. A row is added only after its command has been run once.

## Decisions

| decision | reason | record |
|----------|--------|--------|
| A `pre-push` git hook refuses the push | A rule needing a count holds at 92% with a hook and 64% without | local |
| No hook runs a whole-repo test suite | The measured suite takes 57m36s | local |
| A `kind: diff` metric gates against an absolute floor, never a stored baseline | Two runs measure different changed lines, so their scores are not comparable | local |
| Float comparison uses `awk`, never `bc` | `bc` is absent from `tests/Dockerfile`'s package list | local |
| Per-repo config is a TSV read by bash | The `VAULT.md` reader takes flat scalars and silently empties a list | local |
| Parser adapters are per-tool, not per-repo | The per-repo emitter `qa-status.php` reported `msi: null` as `pass` for three months | local |
| An unmeasurable check exits 2 and refuses | Same defect | [[indications/unreadable-is-not-no]] |
| Raw git hooks, not `lefthook` | Adding a Go binary to five repos buys staged-file filtering this single-operator setup does not need | local |
| `guard_render_report` also writes `quality-reports/status.json` under the six category keys that aggregator fixes | `build-dashboard.mjs:45` reads a closed list of six categories, so a bare metric id would render as missing | local |

## Scope & non-goals

Covers: the runner, the comparison, the report, the git hooks, this framework repo gated end to end,
then `recycling-api`, then the `/v-guard` onboarding command.

Does not cover: the other four Givore surfaces, CI integration, remote monitoring of whether the hook
ran, and fixing `recycling-api`'s failing tests.

## Artifact lifecycles

| artifact | what requires it | who writes it | who reads it | missing or wrong |
|---|---|---|---|---|
| `quality/checks.tsv` | `guard_load_checks` in `lib/guard-metrics.sh`, which has no check list without it | `/v-guard init` step `commands/v-guard/steps/03-prove-and-write.md`, or the operator | `bin/guard.sh commit` and `bin/guard.sh release` | `bin/guard.sh` exits 2 naming the path; the hook refuses the push. A row with the wrong field count exits 2 and runs nothing |
| `quality/baseline.tsv` | `guard_compare`, which has nothing to compare a `kind: repo` metric against | `bin/guard.sh baseline` and `bin/guard.sh accept` | `guard_compare`, and `guard_baseline_diff` against the remote copy | A `kind: repo` id with no row is recorded at `gate: record`; a malformed row exits 2; a row lowered without a reason exits 1 |
| `quality-reports/status.json` | `~/vault/givore/quality/build-dashboard.mjs:57`, which renders nothing without it | `guard_render_report` | that dashboard only | The dashboard loses this surface; no gate and no hook depends on it |
| `quality-reports/REPORT.md` | the operator reading why a push was refused | `guard_render_report` | the operator only; no script parses it | The operator loses the detail; no gate and no hook depends on it |
| `templates/git-hooks/pre-push` installed into a repo | `git push` to a ref matching `guard_release_pattern` | `guard_hooks_install` in `lib/guard-install.sh` | `git` | No gate at all; `bin/guard.sh hooks status` reports it absent |
| `guard_release_pattern` in a repo's `VAULT.md` | `templates/git-hooks/pre-push`, which cannot tell a release push from any other | `/v-guard init`, or the operator | the installed `pre-push` | Falls back to `refs/heads/release/*` and names the fallback in the report |

## Work items

Stage boundaries are stated once, in `## Sequencing & dependencies`. Execute stage 1 now.

| id | file (exact path) | action | tool | constraint | covers | verification | status |
|----|-------------------|--------|------|------------|--------|--------------|--------|
| W-1 | `lib/guard-metrics.sh` | create | Write | defines `guard_load_checks` `guard_parse_row` `guard_compare` `guard_baseline_diff` `guard_accept_count` `guard_render_report` `guard_refusal`; float comparison uses `awk`; a row whose field count differs from the header exits 2 | SC-1 SC-2 SC-4 | `tests/unit/guard-metrics.bats` | WRITTEN — untracked, unproven |
| W-2 | `lib/guard-parsers/clover.sh` | create | Write | one artifact argument, one float on stdout; exit 2 on absent file or zero statements | SC-2 | `tests/unit/guard-metrics.bats` | WRITTEN — untracked, unproven |
| W-3 | `lib/guard-parsers/infection.sh` | create | Write | reads `infection-log.json`; exit 2 when `msi` is null or absent | SC-2 | `tests/unit/guard-metrics.bats` | WRITTEN — untracked, unproven |
| W-4 | `lib/guard-parsers/jscpd.sh` | create | Write | reads `jscpd-report.json`; exit 2 on absent file | SC-2 | `tests/unit/guard-metrics.bats` | WRITTEN — untracked, unproven |
| W-5 | `lib/guard-parsers/lcov.sh` | create | Write | reads `lcov.info`; exit 2 on zero found lines | SC-2 | `tests/unit/guard-metrics.bats` | TODO — needed only when a Dart or JS repo is wired |
| W-6 | `lib/guard-parsers/cloc.sh` | create | Write | reads `cloc --json`; prints `SUM.comment / SUM.code`; exit 2 when `SUM.code` is zero | SC-2 | `tests/unit/guard-metrics.bats` | WRITTEN — untracked, unproven |
| W-7 | `lib/guard-parsers/exitcode.sh` | create | Write | prints `0` on status 0, `1` on status 1, exit 2 on any other status including 127 | SC-2 | `tests/unit/guard-metrics.bats` | WRITTEN — untracked, unproven |
| W-8 | `lib/guard-parsers/diffcover.sh` | create | Write | reads `diff-cover --json-report`; exit 2 when no lines changed | SC-2 | `tests/unit/guard-metrics.bats` | WRITTEN — untracked, unproven |
| W-8a | `lib/guard-parsers/insights.sh` `phpstan.sh` `cda.sh` `junit.sh` `_lib.sh` | create | Write | four parsers the PHP stack needs, plus the shared helper every parser sources; each exports `LC_ALL=C` | SC-2 | `tests/unit/guard-metrics.bats` | WRITTEN — untracked, unproven |
| W-9 | `bin/guard.sh` | create | Write | subcommands `commit release baseline report accept hooks`; measures the sha given in `GUARD_SHA` via a detached worktree when set, the working tree otherwise; exit 0 clean, 1 regression, 2 unmeasurable; writes `status.json` and `REPORT.md` | SC-1 SC-2 SC-7 | `tests/unit/guard-metrics.bats` | WRITTEN — untracked, unproven |
| W-9a | `lib/guard-report.sh` `lib/guard-status.jq` | create | Write | the jq program lives in its own file; category matching is exact, never `startswith` | — | `tests/unit/guard-metrics.bats` | WRITTEN — untracked, unproven |
| W-10 | `lib/guard-install.sh` | create | Write | `guard_hooks_install remove status`; marker lines `# vault-guard-start` and `# vault-guard-end`; refuses to overwrite a non-marker hook body, reusing `install.sh:84-101` | SC-6 | `tests/unit/guard-hooks.bats` | WRITTEN — untracked, unproven |
| W-11 | `templates/git-hooks/pre-push` | create | Write | consumes every stdin line before any exit; matches `<remote ref>`; skips a `(delete)` line; exports the local sha so W-9 measures a `git worktree add --detach` of it rather than the working directory | SC-3 SC-6 SC-7 | `tests/unit/guard-hooks.bats` | WRITTEN — untracked, unproven |
| W-12 | `templates/git-hooks/pre-commit` | create | Write | runs `bin/guard.sh commit`; always exits 0 | SC-3 | `tests/unit/guard-hooks.bats` | WRITTEN — untracked, unproven |
| W-14 | `tests/fixtures/guard/clover.xml` | create | Write | a two-file clover report with known covered and total statements | SC-2 | `tests/unit/guard-metrics.bats` | TODO |
| W-15 | `tests/fixtures/guard/infection-log.json` | create | Write | `msi` is `null`, mirroring the live defect | SC-2 | `tests/unit/guard-metrics.bats` | TODO |
| W-16 | `tests/fixtures/guard/jscpd-report.json` | create | Write | one clone, a known duplication percentage | SC-2 | `tests/unit/guard-metrics.bats` | TODO |
| W-17 | `tests/unit/guard-metrics.bats` | create | Write | every absence assertion uses `run` then a status check, never `! grep`; every write assertion builds its tree under `mktemp -d` | SC-1 SC-2 SC-4 SC-5 | `./tests/run.sh tests/unit` | TODO |
| W-18 | `tests/unit/guard-hooks.bats` | create | Write | feeds real four-field stdin lines and asserts the writer's status is 0 on the skip path | SC-3 | `./tests/run.sh tests/unit` | TODO |
| W-19 | `checks/guard-SC-1.sh` | create | Write | greps the bats output for the `@test` names it owns; exit 1 when they fail, exit 2 when the suite could not run | SC-1 | `./bin/gate.sh verdict <plan> --run` | DONE |
| W-20 | `checks/guard-SC-2.sh` | create | Write | same shape as W-19, own `@test` names | SC-2 | `./bin/gate.sh verdict <plan> --run` | DONE |
| W-21 | `checks/guard-SC-3.sh` | create | Write | same shape as W-19, own `@test` names | SC-3 | `./bin/gate.sh verdict <plan> --run` | DONE |
| W-22 | `checks/guard-SC-4.sh` | create | Write | same shape as W-19, own `@test` names | SC-4 | `./bin/gate.sh verdict <plan> --run` | DONE |
| W-23a | `checks/guard-SC-7.sh` | create | Write | same shape as W-19, own `@test` names | SC-7 | `./bin/gate.sh verdict <plan> --run` | DONE |
| W-23 | `checks/guard-SC-5.sh` | create | Write | deletes the tolerance comparison from a copy of `lib/guard-metrics.sh`, runs the suite against it, and fails when it stays green | SC-5 | `./bin/gate.sh verdict <plan> --run` | DONE |
| W-24 | `quality/checks.tsv` | create | Write | exactly two rows, both host-only: `comment-density` at `scope: both  kind: repo  parser: cloc  direction: down  threshold: 0.02  gate: refuse` over `bin lib scripts`, and `doc-lint` at `scope: both  kind: diff  parser: exitcode  threshold: 0  gate: refuse`. `rule-count` is excluded; it already exits 1 on `main` | SC-6 | `./bin/guard.sh release` | TODO |
| W-25 | `quality/baseline.tsv` | create | Write | values come from one real `bin/guard.sh baseline` run, never typed | SC-6 | `./bin/guard.sh release` | TODO |
| W-26 | `VAULT.md` | edit | Edit | add `guard_release_pattern: refs/heads/release/*` as a flat scalar | SC-6 | `grep` | TODO |
| W-27 | `.gitignore` | edit | Edit | add `quality-reports/` | SC-6 | `git check-ignore quality-reports/REPORT.md` | DONE |
| W-28 | `/home/kdabrow/workspace/recycling-api/quality/checks.tsv` | create | Write | every command carries `docker compose exec -T server` and is run once before it is written; `cloc` scans `app` only; no row runs the whole suite | SC-6 | `bin/guard.sh release` in that repo | DONE — 16 rows |
| W-29 | `/home/kdabrow/workspace/recycling-api/quality/baseline.tsv` | create | Write | written only after two consecutive `bin/guard.sh baseline` runs agree on every value | SC-6 | two runs compared | PARTIAL — 11 rows stand; `coverage` and `tests-failing` wait on W-50 |
| W-30 | `/home/kdabrow/workspace/recycling-api/VAULT.md` | edit | Edit | add `guard_release_pattern: refs/heads/release/*`, and `guard_measure_worktree: false` because that repo's toolchain is bound to the bind-mounted checkout path | SC-6 | `grep` | DONE |
| W-31 | `commands/v-guard.md` | create | Write | dispatcher only; binds `_shared/communication.md` rather than restating it | — | `./bin/doc-lint.sh --changed` | TODO |
| W-32 | `commands/v-guard/steps/01-detect.md` | create | Write | names the marker files it reads | — | `./bin/doc-lint.sh --changed` | TODO |
| W-33 | `commands/v-guard/steps/02-research-propose.md` | create | Write | one tool question per check category, each option carrying its consequence | — | `./bin/doc-lint.sh --changed` | TODO |
| W-34 | `commands/v-guard/steps/03-prove-and-write.md` | create | Write | a command that does not run is written as a `kind: absent` row with its reason, never as a live check | SC-2 | `./bin/doc-lint.sh --changed` | TODO |
| W-35 | `commands/v-guard/steps/04-hooks.md` | create | Write | asks before installing; prints the exact hook paths it will write; gates the prompt on `[ -t 0 ]` | — | `./bin/doc-lint.sh --changed` | TODO |
| W-36 | `scripts/guard-report-hook.sh` | delete | Bash | the operator asked for git hooks, not Claude Code hooks; the `pre-push` stderr already reaches the agent, which reads the output of its own `git push` | — | `git status` shows the path gone | DONE |
| W-37 | `hooks/hooks.json` | — | — | not created; W-36 removes the only hook it would register | — | — | DROPPED with W-36 |
| W-38 | `install.sh` | — | — | not created; W-36 removes the only `HOOK_ROWS` row it would carry | — | — | DROPPED with W-36 |
| W-39 | `vault/indications/git-hooks-may-refuse.md` | create | Write | states the git-hook rule, including the stdin-drain requirement, and references its Claude Code sibling in one line | E-5 | `./bin/doc-lint.sh --changed` | TODO |
| W-40 | `vault/indications/hooks-never-fail-their-host.md` | edit | Edit | scope the title rule to Claude Code hooks; record the two exit-2 paths the shipped scripts already take | E-5 | `./bin/doc-lint.sh --changed` | TODO |
| W-41 | `vault/indications/_index.md` | edit | Edit | one row for `git-hooks-may-refuse` | E-5 | `./bin/doc-lint.sh --changed` | TODO |
| W-42 | `vault/decisions/ADR-030-quality-regression-gate.md` | create | Write | records the refusal choice, the diff-scoped-at-push choice, and the rejected `lefthook` option | — | `./bin/doc-lint.sh --changed` | TODO |
| W-43 | `vault/features/v-guard.md` | create | Write | names every contract file, the nine columns, and all three exit codes | — | `./bin/doc-lint.sh --changed` | TODO |
| W-44 | `vault/check-budget.md` | edit | Edit | one row per new refusing check, plus a line stating that guard rows are incremented by `guard_refusal` rather than by the operator, because a refusal happens inside `git push` where no session observes it | — | `./bin/gate.sh budget` | TODO |
| W-45 | `templates/VAULT.md` | edit | Edit | document `guard_release_pattern` as a flat scalar | — | `./bin/doc-lint.sh --changed` | TODO |
| W-46 | `README.md` | edit | Edit | one row for `/v-guard` in the command table | — | `./bin/doc-lint.sh --changed` | TODO |
| W-47 | `.claude-plugin/plugin.json` | edit | Edit | bump `version` | — | `./bin/release-check.sh` | TODO |
| W-48 | `bin/` `lib/` `templates/` in this repo | commit | Bash | every one is untracked today, and `recycling-api/.git/hooks/pre-push` calls `bin/guard.sh` by absolute path; a `git clean -fd` here disarms the gate there | — | `git status --short` reports no `??` under those paths | DONE — `7b57b2c` on `feat/guard-runner` |
| W-49 | `/home/kdabrow/workspace/recycling-api/quality/` `VAULT.md` `CLAUDE.md` `composer.json` `infection.json5` | commit | Bash | review the `composer.json` diff first; its `qa:nightly` called `composer quality:all`, which no script defines | — | `git status --short` clean in that repo | DONE — `6240c1b6` on `release/1.17.0` |
| W-53 | `/home/kdabrow/workspace/recycling-api/scripts/qa-status.php` | revert | Bash | it carries a second baseline comparison beside `guard_compare`, and reads ids `duplication-lines-pct` and `shadow-dependencies` that `quality/baseline.tsv` does not define, so both lookups return null. A per-repo emitter is the thing that reported `msi: null` as a pass for three months | — | `git diff scripts/qa-status.php` is empty and `composer qa:status` still runs | BLOCKED — 161 uncommitted lines; needs the operator's word before reverting |
| W-50 | `/home/kdabrow/workspace/recycling-api/phpunit.xml:36-41` | edit | Edit | both an `<env … force="true"/>` and a `<server … force="true"/>` line for `MAIL_MAILER`; `<env force>` reaches `getenv()` and `$_ENV` but never `$_SERVER`, which keeps the container's `MAIL_MAILER: smtp` from `docker-compose.yml:26`, and Laravel's Env repository reads `$_SERVER` | — | one mailing test passes with the mailpit container stopped | DONE — `4da799ff`; `AdEligibilityTest` 8 errors to 12 green, 46s to 7.7s |
| W-51 | `/home/kdabrow/workspace/recycling-api/storage/coverage/` then `quality/baseline.tsv` | measure | Bash | re-run `composer test:coverage` after W-50 with the stack up, then re-capture only the `coverage` and `tests-failing` rows; the run takes 57m36s, so the operator schedules it | SC-6 | `tests-failing` measures 0 and `coverage` comes from a clover file under 7 days old | TODO |
| W-52 | `tests/run.sh` `tests/Dockerfile` | create | Write | copied from `$VAULT_FRAMEWORK_PATH/tests/`; mounts this repo read-only at `/code`; W-17 and W-18 have no harness to run in without it | SC-1 SC-2 SC-3 | `./tests/run.sh tests/unit` exits 0 on an empty suite | TODO |

## Sequencing & dependencies

Stage 1 — W-48, W-49. Commit what already runs, in both repos. No behaviour changes. It ends when
`git status --short` reports no untracked runner path here and no staged quality path there.

Stage 2 — W-50, W-51. Unblock the release gate in `recycling-api`. W-50 is a one-line edit; W-51 is
a 57-minute measured run the operator schedules. It ends when `bin/guard.sh release` there exits 0
with the stack up. Stage 2 is independent of stage 3 and can run in either order.

Stage 3 — W-52, W-14 to W-18, then the SC verdicts. Prove the runner. Until it lands, SC-1 to SC-5
and SC-7 are claimed and unverified: `checks/guard-SC-*.sh` grep a bats suite that does not exist,
so each exits 2. It ends with `./bin/gate.sh verdict <plan> --run` green.

Stage 4 — W-24, W-25, W-26. This repo gates itself, the two host-only rows only. It needs stage 1
and stage 3. It ends with SC-6 met: a push to a release branch of a clone of this repo, refused.

Stage 5 — W-31 to W-35 and W-39 to W-47, the `/v-guard` onboarding command and the documents. It
needs stage 4. W-5 joins this stage only when a Dart or JS repo is wired.

No plan in this repo has completed more than 23 work items. Stage 3 is 7, stage 5 is 14 and splits
again if it runs long.

## Rollback

`bin/guard.sh hooks remove` deletes the block between `# vault-guard-start` and `# vault-guard-end`
from each installed git hook and leaves any other body intact. Deleting `quality/` and
`quality-reports/` returns a repo to its current state. Nothing changes application code.

## Test plan

The harness, the decision table, the fault hypotheses, the boundary partitions and the 27-row test
backlog are in the sibling `2026-09-14-1251-quality-regression-gate.test-design.md`.

## Refs

Four rules from the vault framework bind this plan. The framework is installed at
`$VAULT_FRAMEWORK_PATH`; each rule is stated here so nothing depends on reaching that copy.

- **An unmeasurable check exits 2, never 0.** Exit 1 means "the answer is no"; exit 2 means "I could
  not read the question". A check that collapses the two reports a tool it could not run as a pass.
- **A stated threshold names the function computing it and ships a test proven to fail without it.**
  Plant the violation and watch the test go red before trusting it green. Assert absence with `run`
  then a status check, never `! grep`, which is exempt from `set -e` and passes decoratively.
- **Every artifact answers four questions before the plan is approved:** what requires it, who writes
  it, who reads it, and what happens when it is missing or wrong.
- **A rule needing a count needs a hook.** Rules a model can decide from the text it is writing hold
  at 92%; rules needing a count hold at 64%. That gap is why this is a git hook and not a guideline.

Process record for this plan: `vault/plans/2026-09-14-1251-quality-regression-gate.trail.md`.
Framework extension contract this plugin targets:
`$VAULT_FRAMEWORK_PATH/vault/plans/2026-09-14-1327-framework-extension-points.md`.
