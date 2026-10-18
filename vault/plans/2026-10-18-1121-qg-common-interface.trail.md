---
type: trail
project: vault-quality-gates
plan: 2026-10-18-1121-qg-common-interface
tags: [trail, record]
---

# 2026-10-18-1121-qg-common-interface — process record

Record class. Its contract document is `2026-10-18-1121-qg-common-interface.md`.

## Decisions & trade-offs

| decision | alternative rejected | why it lost |
|---|---|---|
| Evolve `vault-quality-gates` | adopt hk 2.7.0 as runner | hk has no committed baseline, no up-front agent block, no drivers for phpstan, pint, phpmd, flutter, vitest, phpunit or jscpd; migrating 132 rows to Pkl buys a hook runner the repo already has. Operator chose evolve on 2026-10-18 |
| Evolve `vault-quality-gates` | new repo from scratch | discards 22 commits and 183 bats tests of bypass blocking, staged-tree measurement and baselines |
| Keep TSV config | YAML | engine is bash + awk; `qg list` gives the readable view |

## Findings & dispositions

### Round 1

| persona | id | severity | grounding | issue | disposition |
|---------|----|----------|-----------|-------|-------------|
| consumer | consumer-1 | BLOCKER | confirmed | driver contract too thin to write a phpstan driver (no runner, QG_ARGS shape, boot-error rule) | applied: W-1 expanded, W-9 phpstan reference driver |
| consumer | consumer-2 | MAJOR | confirmed | refusal for the 2026-10-17 case: blank why, tail repeated ×8, no environment cue | applied: W-3 why fallback, W-12 dedup tails |
| consumer | consumer-3 | MAJOR | confirmed | new refusal would drop file:line RULES.md lines | applied: guard-report-errors.sh sole printer (Decisions, W-12) |
| consumer | consumer-4 | MINOR | advisory | no lifecycle row for describe; exit 0 + error undefined | applied: lifecycle rows |
| harness-engineer | harness-1 | BLOCKER | confirmed | override token forgeable by shell redirect | applied: W-13 tree-bound token, W-17 NEEDLES + git-dir writes |
| harness-engineer | harness-2 | BLOCKER | confirmed | `qg hooks remove` passes the agent guard | applied: W-14 refusal, W-17 scan_qg |
| harness-engineer | harness-3 | BLOCKER | confirmed | repo driver shadows built-in and judges its own commit | applied: W-7 config-revision load, no shadowing, W-10, W-18 |
| harness-engineer | harness-4 | MAJOR | confirmed | token consumable from another worktree | applied: W-13 |
| harness-engineer | harness-5 | MAJOR | confirmed | refusal's `qg` lines unreachable for agents | applied: W-17 plugin path allowed for read-only, W-22 PATH link |
| harness-engineer | harness-6 | MAJOR | confirmed | Stop hook and protected paths read only VAULT.md | applied: W-6, W-18 |
| harness-engineer | harness-7 | MINOR | advisory | `run --json` shape and push reproduce `--ref` | applied: SC-4, W-12 |
| harness-engineer | harness-8 | MINOR | confirmed | tty rule restated differently | applied: SC-3, W-13 call guard_override_allowed unchanged |
| solution-architect | sa-1 | BLOCKER | confirmed | pre-push filters refs before the engine | applied: W-11 |
| solution-architect | sa-2 | BLOCKER | confirmed | positional readers misread v2 | applied: W-3, W-4 |
| solution-architect | sa-3 | MAJOR | confirmed | forged token | applied (cluster with harness-1) |
| solution-architect | sa-4 | MAJOR | confirmed | driver shadowing | applied (cluster with harness-3) |
| solution-architect | sa-5 | MAJOR | confirmed | second config reader | applied: W-6 |
| solution-architect | sa-6 | MAJOR | confirmed | two findings printers | applied: Decisions |
| solution-architect | sa-7 | MAJOR | confirmed | templates never reach repos | applied: W-25, W-16 hook-current check |
| solution-architect | sa-8 | MAJOR | confirmed | user-level edit guard blocks S2–S4 | applied: S6 depends on S2–S5 |
| solution-architect | sa-9 | MAJOR | advisory | public contract without ADR | applied: W-2 |
| solution-architect | sa-10 | MINOR | confirmed | SC-8 compares new with new; no priority order | applied: SC-8 reference 43d7082; priority line |
| skeptic | skeptic-1 | BLOCKER | confirmed | baseline diff reads threshold as direction | applied: W-4, SC-6 |
| skeptic | skeptic-2 | BLOCKER | confirmed | gate runs from main's working tree; half-edits go live | applied: W-0 worktree, W-24 cut-over, Rollback |
| skeptic | skeptic-3 | BLOCKER | confirmed | qg pass-through skips allowlist | applied (cluster with harness-2) |
| skeptic | skeptic-4 | MAJOR | confirmed | positional reads outside W-2 | applied: W-4 |
| skeptic | skeptic-5 | MAJOR | confirmed | SC-8 oracle empty | applied: SC-8 |
| skeptic | skeptic-6 | MAJOR | confirmed | migration can move baselines under same id | applied: Decisions, C-4 |
| skeptic | skeptic-7 | MAJOR | confirmed | pre-push + reinstall | applied: W-11, W-25 |
| skeptic | skeptic-8 | MAJOR | confirmed | repo driver shadowing | applied (cluster with harness-3) |
| skeptic | skeptic-9 | MAJOR | confirmed | revert unsafe after S2; staged config not validated | applied: Rollback roll-forward, W-10 |
| skeptic | skeptic-10 | MINOR | confirmed | token cross-worktree, tty wording | applied: W-13 |
| skeptic | skeptic-11 | MINOR | confirmed | factory keeps 4000 chars | applied: W-12 3500 cap |
| skeptic | skeptic-12 | MINOR | confirmed | shell driver must keep pipefail | applied: W-8 |
| skeptic | skeptic-13 | NIT | confirmed | 4 repos not 5; realse is an extra alternative | applied: Verified state |

### Round 2

| persona | id | severity | grounding | issue | disposition |
|---------|----|----------|-----------|-------|-------------|
| harness-engineer | harness-9 | BLOCKER | confirmed | live today: `GUARD_SKIP=. git push` skips every push row; `GUARD_CONFIG_REV=<old>` picks an older config | applied: W-1 ships alone first; W-9, W-17 unset; SC-9 |
| solution-architect | sa-11 | BLOCKER | confirmed | every-ref release runs the tree check and refuses ungated pushes in 3 repos | applied: W-8 select rows first, exit 0 when none |
| skeptic | skeptic-16 | MAJOR | confirmed | same as sa-11, plus refs without checks.tsv | applied: W-8, SC-5 |
| solution-architect | sa-12 | MAJOR | confirmed | native drivers never get the staged tree | applied: `needs_tree` in describe, W-11 |
| consumer | consumer-1 | MAJOR | confirmed | `runner=` argv, resolution and binary name undefined | applied: W-2 runner call form, `bin=`, config-revision load |
| consumer | consumer-3 | MAJOR | confirmed | file-less phpstan errors print a bare count | applied: W-14 `phpstan.fileless` findings |
| harness-engineer | harness-10 | MAJOR | confirmed | S2–S5 agents forbidden from migrate/init/config writes | applied: operator migration commits, Decisions |
| skeptic | skeptic-14 | MAJOR | confirmed | SC-8 on copies measures nothing in 3 repos | applied: SC-8 on live checkouts, exit 2 on unmeasurable reference |
| skeptic | skeptic-15 | MAJOR | confirmed | parity on clean commits proves nothing for 66 rows | applied: C-4 seeded-violation parity script |
| skeptic | skeptic-17 | MAJOR | confirmed | old hook copies call new engine before reinstall | applied: Decisions, W-8, SC-10, W-29 adds this repo |
| solution-architect | sa-13 | MINOR | confirmed | Python hook cannot call bash config reader | applied: `qg config get`, W-21 |
| solution-architect | sa-14 | MINOR | confirmed | push token scope unstated | applied: unrecorded-commit check only |
| solution-architect | sa-15 | MINOR | advisory | S1 too large for one cut-over | partly applied: W-1 ships alone; rest stays one cut-over because refusal text needs `qg` |
| consumer | consumer-2 | MINOR | confirmed | rules.tsv has no join to row ids; no environment cue | applied: fallback why only, W-16 first line |
| harness-engineer | harness-11 | MINOR | advisory | exact realpath match and git-dir scope | applied: W-21 |
| skeptic | skeptic-18 | MINOR | confirmed | S1 worktree unprotected before cut-over | applied: W-27 diff review |

## Metrics

Round 2: 4 critics; 2 new confirmed BLOCKERs (both applied), 8 MAJOR, 6 MINOR; round cap reached. All round-1 findings reported resolved.

Round 1: 4 critics; 10 BLOCKER (all confirmed), 18 MAJOR, 6 MINOR/NIT; clusters: token forgery (3 critics), driver shadowing (3), positional reads (2), qg allowlist (2), pre-push (2).

## Advisory test hints

## Rejected / deferred

- SARIF as the result format: deferred to an export converter; `qg.result/1` keeps SARIF-mappable names.
- Persona pack: the vault's `marketing` pack does not fit a dev-tooling change; the panel seats the planning group's solution-architect, harness-engineer, consumer and skeptic, cap raised to 4.
