---
type: trail
project: vault-quality-gates
plan: 2026-09-14-1251-quality-regression-gate
tags: [trail, record]
---

# 2026-09-14-1251-quality-regression-gate — process record

Record class, so chronology belongs here and nowhere else. Its contract document is
`plans/2026-09-14-1251-quality-regression-gate.md`, which carries the current truth only.

## Decisions & trade-offs

| decision | alternative rejected | why it lost |
|---|---|---|
| Raw git hooks written by `bin/guard.sh hooks install` | `lefthook` v2.1.12, a single dependency-free Go binary with `use_stdin: true` for `pre-push` | Adds a binary to five repos for staged-file filtering and a committed config this single-operator setup does not need. The framework already owns an idempotent marker-comment hook install pattern, copied from `graphify hook install`. |
| Per-repo config in `quality/checks.tsv` | New nested keys in each repo's `VAULT.md` | `bin/gate.sh:439` reads `VAULT.md` with `sed -n 's/^key:...//p'`. A YAML block list yields an empty value with no error, which already caused a routing defect. |
| Parser adapters keyed by tool output format | A per-repo emitter script, as `recycling-api/scripts/qa-status.php` does today | The per-repo emitter is what rotted: `qa-status.php` reported `mutation: pass` with `msi: null` for three months. A clover parser is the same everywhere; a repo emitter is bespoke everywhere. |
| Mutation scoped to changed lines via `--git-diff-lines` | Whole-repo mutation on release push | A whole-repo Infection run on `recycling-api` was estimated at 11 nights at 2 threads. |
| `quality/baseline.tsv` committed, report gitignored | Baseline in the vault beside `history.jsonl` | A baseline in the vault does not travel with a branch and is invisible in review. |
| Comment density measured with `cloc --json` | A framework-owned regex line counter | `cloc 1.98` is already on the host and is language-aware across all four stacks. |

## Findings & dispositions

### Round 1

| persona | id | severity | grounding | issue | disposition |
|---------|----|----------|-----------|-------|-------------|
| skeptic | 1 | BLOCKER | confirmed | pre-push exits without draining stdin, so git push dies with 141 while the hook reports success | applied — W-11, SC-3, T-15, T-17 |
| skeptic | 2 | BLOCKER | confirmed | the whole-repo suite takes 57m36s | applied differently — no hook runs a whole-repo suite; push-time is diff-scoped, `bin/guard.sh baseline` runs out of band |
| consumer | 1 | BLOCKER | confirmed | checks.tsv has no stated columns, so writer and parser can disagree silently | applied — `vault/architecture/guard-file-formats.md` |
| quality | 1 | BLOCKER | confirmed | gate.sh refused SC-6 because its failure condition sat in prose, not in the cells it reads | applied — both strings moved into the `check` cell |
| quality | 2 | BLOCKER | confirmed | no work item created the test fixtures | applied — W-14, W-15, W-16 |
| architect | 1 | BLOCKER | confirmed | baseline.tsv travels in-branch, so lowering it passes the gate it defines | applied — E-3, SC-4, `guard_baseline_diff` |
| skeptic | 3 | MAJOR | confirmed | the recycling-api stack has been down six weeks | applied — W-28 |
| skeptic | 4 | MAJOR | confirmed | that repo's suite fails and flakes, so no green baseline exists | applied — W-29 blocked until two runs agree |
| skeptic | 5 | MAJOR | confirmed | float comparison has no named tool | applied — `awk` named in W-1 |
| skeptic | 6 | MAJOR | confirmed | five sessions in a repo where no plan was ever multi-session | applied — four sessions, each ending on a criterion |
| skeptic | 7 | MAJOR | confirmed | accepted regressions accumulate with no counter | applied — E-4, T-13 |
| architect | 2 | MAJOR | confirmed | the exit-code parser turned "not installed" into the number 1 | applied — W-7 exits 2 outside {0,1} |
| architect | 3 | MAJOR | confirmed | the parser calling convention was undefined | applied — guard-file-formats.md |
| architect | 6 | MAJOR | confirmed | a diff-scoped score was compared against a baseline from a different population | applied — `kind: diff` gates against an absolute floor |
| quality | 4 | MAJOR | confirmed | the house check-script pattern collapses exit 2 into exit 1 | applied — W-19 constraint, and the six scripts return 2 when the suite cannot run |
| quality | 5 | MAJOR | confirmed | three check scripts graded the same bats file and could not fail independently | applied — each greps its own `@test` names |
| quality | 6 | MAJOR | confirmed | T-7 passed vacuously because the repo is mounted read-only | applied — every write assertion builds under `mktemp -d` |
| architect | 5 | MAJOR | confirmed | the existing aggregator parses JSON where the plan emitted markdown | applied — `guard_render_report` writes both |
| quality | 3 | MAJOR | confirmed | nothing planted a violation to prove the threshold is load-bearing | applied — SC-5, W-23, T-11 |
| architect | 11 | NIT | confirmed | git hooks were placed in the plugin manifest's directory | applied — `templates/git-hooks/` |
| skeptic | 9 | MINOR | confirmed | the .gitignore work item was already satisfied | applied — deleted |
| architect | 10 | MINOR | confirmed | the plan credited this framework with a marker-comment pattern it does not have | applied — corrected in Verified current state |

### Round 2

| persona | id | severity | grounding | issue | disposition |
|---------|----|----------|-----------|-------|-------------|
| consumer | 2-1 | BLOCKER | confirmed | newline-separated `{{files}}` splits one command into one per changed file | applied — NUL-separated, consumed by `xargs -0`, T-20 |
| consumer | 2-2 | BLOCKER | confirmed | the header was both a comment and the field-count reference, and a bare header parsed as a passing check | applied — line 1 is the literal uncommented header, refused if it differs; T-21, T-22 |
| consumer | 2-3 | BLOCKER | confirmed | the aggregator fixes six category keys, so a bare metric id renders as missing | applied — status.json writes unknown ids under `codeQuality.checks` |
| skeptic | 2-1 | BLOCKER | confirmed | two of this repo's three configured checks emit no number and write no artifact | applied — W-24 carries two rows with explicit parsers; `rule-count` dropped |
| skeptic | 2-3 | BLOCKER | confirmed | an all-zeroes remote sha on a first push breaks the baseline check, which is SC-6's own scenario | applied — E-3 skips and says so; T-23 |
| skeptic | 2-5 | MAJOR | confirmed | the gate measured the working tree, so uncommitted edits refuse a clean push | applied — SC-7, `GUARD_SHA`, detached worktree, T-24 |
| skeptic | 2-8 | MAJOR | confirmed | two contradictory session splits | applied — boundaries stated once |
| skeptic | 2-9 | MAJOR | confirmed | session A at 27 items exceeded any plan this repo has finished | applied — split at W-18 |
| skeptic | 2-7 | MAJOR | confirmed | the accept limit was hard-coded and accepted rows never expired | applied — `guard_accept_limit`, cleared by `baseline` |
| skeptic | 2-6 | MAJOR | confirmed | check-budget rows cannot be incremented for a refusal inside git push | applied — W-44 states they are machine-incremented |
| skeptic | 2-2 | MAJOR | confirmed | the exit-status parser could not receive an exit status | applied — second parser argument; `parser: -` defined |
| consumer | 2-5 | MAJOR | confirmed | no mapping from the `scope` column to a subcommand, and `diff` named both | applied — subcommand renamed `commit`; mapping written |
| consumer | 2-6 | MAJOR | confirmed | the refusal text was never written down | applied — literal template in guard-file-formats.md |
| consumer | 2-7 | MAJOR | confirmed | the session hook had to parse undefined markdown headings | applied — it reads status.json |
| consumer | 2-4 | MAJOR | confirmed | a `kind: absent` row had no legal value for four mandatory cells | applied — `-`, with a literal example; T-25 |
| skeptic | 2-10 | MINOR | confirmed | meeting SC-6 meant deleting comments from the real working checkout | applied — the pushing tree is a clone under `mktemp -d` |

## Metrics

Round 1: four reviewers, 35 findings, 34 confirmed, 6 confirmed blockers, all applied.
Round 2: two reviewers, 20 findings, 20 new, 5 confirmed blockers, all applied.
The loop stopped on the round cap, so the round-2 fixes were never reviewed.

## Advisory test hints

## Rejected / deferred

- **StrykerJS `--since`.** Several 2026 guides show `stryker run --since main`. The maintained
  configuration reference lists no such flag; diff scoping is `--incremental` plus a committed
  `incrementalFile`, or a `--mutate` line range. Any plan row citing `--since` would not run.
- **A dead-man's-switch ping to Healthchecks.io.** It detects a job that stopped running, which is
  the failure that killed the June build. It needs a network endpoint and an account, and the
  push-time gate already refuses when the report names another commit. Revisit if a scheduled
  whole-repo baseline refresh is added.
- **Re-pointing `~/vault/givore/quality/build-dashboard.mjs`** at the new report. The aggregator
  gives a real cross-repo view and should survive, but changing its input while the new format is
  unproven would leave neither working.
- **`phpcpd`.** `recycling-api` still calls `vendor/bin/phpcpd` in its `composer cpd` script. The
  original package is abandoned. `jscpd` replaces it and covers PHP, TypeScript and Dart at once.
