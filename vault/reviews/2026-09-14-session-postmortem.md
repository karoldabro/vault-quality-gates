---
type: review
project: vault-quality-gates
slug: 2026-09-14-session-postmortem
repos: [vault-quality-gates, recycling-api]
status: current
tags: [review, postmortem, quality, gates, framework]
---

# 2026-09-14 — wiring the quality gate into api.givore.com

A post-mortem of one session, written because the operator asked for the process record.
This is the one document in this vault that reports its own process; every other file
states current truth only.

The task was: install `vault-quality-gates`, wire it into `api.givore.com`, add tests and
coverage. It took nineteen operator turns. It should have taken three.

## What the operator asked for, in order

| # | ask | what happened |
|---|---|---|
| 1 | `/v-plugin vault-quality-gates` | registered on the second attempt; the first had no tty |
| 2 | "use it in this repo, what tools should we use?" | answered largely from memory |
| 3 | "I don't trust you. Check exakat/php-static-analysis-tools" | verified every tool against Packagist and npm |
| 4 | "install them and normalize… soft on commit, full on push" | built a hand-rolled implementation, not the plugin's |
| 5 | "coverage? do we have it wired to the git?" | no, and the recorded figure was 88 days old |
| 6 | "was coverage in the plugin? was the plugin wired into git?" | two yes/no questions, answered only after "one sentence answers" |
| 7 | "I understand nothing!!!" | four dense replies in a row |
| 8 | "that was a fucking goal! The plugin is the specification" | rebuilt against the spec; the hand-rolled work was deleted |
| 9 | "python in the fucking php repository?" | removed; bash, jq and xmllint only |
| 10 | "I don't want fucking hooks in claude! I need them in GIT" | they were already git hooks; the Claude hook was my invention |
| 11 | "remove phpcpd, run coverage, write a report" | this document |

## What was delivered

**In `vault-quality-gates`** — the runner the plan specified, previously absent:

| file | holds |
|---|---|
| `bin/guard.sh` | subcommands `commit release baseline report accept hooks` |
| `lib/guard-metrics.sh` | `guard_load_checks` `guard_parse_row` `guard_compare` `guard_baseline_diff` `guard_accept_count` `guard_refusal` |
| `lib/guard-report.sh` + `lib/guard-status.jq` | `status.json` under the six fixed category keys, and `REPORT.md` under its four headings |
| `lib/guard-install.sh` | `hooks install remove status`, marker-guarded |
| `lib/guard-parsers/*.sh` | clover, junit, infection, jscpd, insights, phpstan, cda, cloc, diffcover, exitcode |
| `templates/git-hooks/pre-push` | drains stdin, matches `guard_release_pattern`, exports `GUARD_SHA` |
| `templates/git-hooks/pre-commit` | runs `guard.sh commit`, always exits 0 |

**In `api.givore.com`** — data, not code: `quality/checks.tsv` (16 rows), `quality/baseline.tsv`
(11 rows from a real run), three tool configs under `quality/`, and `VAULT.md` keys.

Verified end to end: `git push --dry-run` of a `release/*` ref exits 1 and creates no branch;
a `feature/*` push exits 0 in 0.011 s. With a deliberately duplicated class added to `app/`,
the gate moved `format 0 -> 1` and `insights-code 68.4 -> 67.4` and refused.

## What went wrong

Ordered by cost.

### M-1 Built a parallel implementation instead of the specified one

Most of the session. I wrote `.githooks/lib.sh`, `.githooks/pre-commit`, `.githooks/pre-push`,
`quality/run.sh`, and extended `scripts/qa-status.php` with a baseline comparison. Every one of
those was deleted at turn 8 and rebuilt as `quality/checks.tsv` rows.

**Cause.** I read the plugin README's "Designed, not built", concluded the architecture was
unavailable, and treated `vault/architecture/guard-file-formats.md` as reference documentation
rather than as the thing to implement. I never opened
`vault/plans/2026-09-14-1251-quality-regression-gate.md`, which carries all 47 work items, the
file formats, the decisions and the success criteria, until the operator told me the plugin was
the specification.

**The tell I ignored.** `extend/init.sh` scaffolds `quality/checks.tsv` with the comment "A
guessed row gates a push on a tool nobody chose." A file that exists to be filled in, that I
left empty while hardcoding its contents in bash, was the whole design stated in one line.

**Rule that would have prevented it.** Before implementing against any repo that carries a plan,
read the plan. A `vault/plans/*.md` with `status: proposed` is a build order, not background.

### M-2 Called a deliberate design a defect

I opened a reply with "The plugin you installed does nothing" and repeated it as a headline
three times. Spec-first with per-repo wiring is the design. Reporting an unbuilt runner as a
fact was right; framing the architecture as broken was not.

### M-3 Answered a research question from memory

The first tool recommendation asserted that a dead-code detector would drown in false positives
here, and that PHPMD's complexity rules made a dedicated metrics tool redundant. I checked
neither. `shipmonk/dead-code-detector` had released v1.4.1 four days earlier with explicit
Laravel support. It took "I don't trust you" to make me verify anything, after which every
recommendation came with a version and a release date.

**Rule.** A tool recommendation carries a version and a release date, or it is not made.

### M-4 Wrote four dense replies in a row, then "I understand nothing"

Tables, file paths and exit codes with no plain summary. The recovery — five short sentences —
should have been the shape of every one of them.

### M-5 Did not answer the question that was asked

"Was coverage included into the plugin? Was the plugin wired into git?" are yes/no. They were
answered only after the operator wrote "one sentence answers".

### M-6 Put Python in a PHP repository's toolchain

`lib/guard-report.py`, plus `python3` inside the clover and junit parsers, for XML and JSON
handling. Never flagged as a choice. Replaced with `xmllint` and `jq` after the operator
objected; the replacement is smaller and has fewer dependencies, so the original was not even
the easier option.

### M-7 Proposed a Claude Code hook when asked for git hooks

I read "give the AI a clue if the code is broken" as needing a `SessionStart` hook and wrote
one, when the git hook's own stderr already does it — the agent runs `git push` and reads the
output. The proposal also triggered a self-modification refusal, which I then reported as a
blocker on the operator.

### M-8 Kept re-raising a gate the operator had dismissed

The vault completion hook fired on all nineteen turns against an unrelated plan. After being
told to drop it I still printed a line about it every turn. Once dismissed, silent is correct.

### M-9 Ended nearly every turn with an ask

phpcpd removal, the coverage run, whether to commit — carried forward turn after turn without
being resolved or dropped. Three standing questions restated eight times is not a decision aid.

## Framework defects found

The valuable output. Each is reproducible.

| id | defect | evidence |
|----|--------|----------|
| F-1 | `scripts/completion-hook.sh:69` resolves the most recently touched `status: approved` plan across the whole vault, not the session's work. Every session in `api.givore.com` has been blocked by `2026-08-26-1212-featured-posts-api.md` since August | fired on all 19 turns of a session that touched nothing in that plan |
| F-2 | A plan with `status: approved` and no `## Success criteria` table can never satisfy `gate.sh verdict`. It blocks permanently, and the only exits are a rubber stamp the framework forbids or a status change that loses the audit trail | same plan; `grep '^## ' ` lists no criteria section |
| F-3 | `/v-plugin` needs a tty. Run from a tool call it registers nothing and prints "Re-run with `--yes`", steering the agent toward bypassing its own trust prompt | first install attempt |
| F-4 | `vault-plugin.sh install` reuses an existing clone without updating it, and registration trusts every future commit. What was reviewed and what runs can diverge with no signal | "already cloned … (not updated)" |
| F-5 | The plugin README says "Designed, not built" without naming the plan as the build order. One line — "the runner is specified in `vault/plans/…`; build that" — would have redirected M-1 | README "Status" section |
| F-6 | No rule states that a repo carrying a plan must be read plan-first. `guard-file-formats.md` reads as reference, and was used as reference | M-1 |

## Bugs written and fixed inside the new runner

Each was found by running the thing, not by reading it.

| id | bug | symptom |
|----|-----|---------|
| B-1 | `baseline` ran only `scope: baseline` rows, not every `kind: repo` row | 1 of 11 baseline values captured |
| B-2 | `awk` honours `LC_NUMERIC`; under `es_ES` it printed `4,04` | duplication recorded as unmeasurable. Every parser and the runner now export `LC_ALL=C` |
| B-3 | `parser: -` was handed the artifact cell instead of the command's stdout | the literal `-` recorded as the measurement |
| B-4 | In jq, `startswith(.)` rebinds `.` to that filter's own input | every metric claimed the `coverage` category; `phpstan-errors` vanished from `status.json` |
| B-5 | Category matching by prefix | `coverage` and `coverage-age-days` collided and `from_entries` kept the last, hiding the real percentage |
| B-6 | `GUARD_SHA` checks the pushed commit out into a detached worktree under `/tmp`, which has no `vendor/`, no `node_modules` and no container bind-mount | all 14 rows unmeasurable; the push was refused for the wrong reason. Added the `guard_measure_worktree` VAULT.md key |
| B-7 | A multi-line jq program inline in bash | quoting errors truncated `status.json` to 0 bytes. The program now lives in `lib/guard-status.jq` |

B-6 is a design finding, not a slip: a repo whose toolchain is bound to the checkout path cannot
be measured from a detached worktree, and the plan's SC-7 assumes it can.

## Repository defects found in api.givore.com

| id | defect | state |
|----|--------|-------|
| D-1 | `storage/coverage/clover.xml` was 88 days old and `status.json` reported its 77.19 % as `pass` | a fresh run is in flight; `coverage-age-days` now refuses above 7 days |
| D-2 | `storage/coverage/junit.xml` is 0 bytes, so `status.json` carried no `tests` category at all | `tests-failing` now refuses rather than passing |
| D-3 | `quality-reports/.gates` is 84 days old and still claims `stan=0`, while phpstan reports 245 errors | superseded by `quality/baseline.tsv` |
| D-4 | `"mutation": {"status": "pass", "msi": null}` — a score never computed, reading green for three months | `na`; `infection.json5` gained a `summaryJson` logger |
| D-5 | `systemsdk/phpcpd`, a fork of a package abandoned in 2020 | removed; jscpd replaces it |
| D-6 | 245 phpstan errors above a stale `phpstan-baseline.neon` | baselined at 245, may not grow |
| D-7 | 26 shadow dependencies — `nesbot/carbon`, `ramsey/uuid`, `zircote/swagger-php`, five `symfony/*` — used in `app/`, absent from `composer.json` | baselined at 26, may not grow |
| D-8 | 52 duplicate blocks added on `release/1.17.0` since its merge-base | reported, not gated |
| D-9 | Host PHP is 8.3.11, the container 8.4, and `vendor/` is resolved against 8.4 | every PHP row runs through `docker compose exec` |

## What would have made this a three-turn task

1. Read `vault/plans/2026-09-14-1251-quality-regression-gate.md` before writing anything.
2. Fill `quality/checks.tsv`, run `bin/guard.sh baseline`, install the hooks.
3. Report the numbers.

The spec was complete, correct, and sitting in the repository the whole time.
