---
type: plan
project: vault-quality-gates
slug: 2026-10-18-1121-qg-common-interface
repos: [vault-quality-gates, recycling-api, app.givore.com, dashboard.givore.com, recycling_mobile_app, givore.com, vault.givore.com]
status: approved
process_record: 2026-10-18-1121-qg-common-interface.trail.md
arch_spec:
human_plan:
session_of:
session:
tags: [plan, quality-gate, cli, drivers]
---

# One gate interface for every repo, usable by a human and an agent — plan

## Task

Turn `vault-quality-gates` into a repo-independent gate tool. It gets a `qg` command a human and an
agent both operate, a driver contract that wraps each tool and normalises its result, a per-repo
config that says on which event and branch each gate runs, and refusals that say what ran, why it
failed and how to pass. Session S1 (this plan's work items) builds the core. Sessions S2–S6 write
the drivers for every Givore check, migrate each repo and close the agent gaps.

Keywords: `qg`, `guard.sh`, `checks.tsv`, `guard_row_field`, `qg_config_key`, `driver`,
`qg.result/1`, `on`, `why`, `qg explain`, `qg override`, `qg doctor`, `guard_bash.py`, `pre-push`,
`GUARD_SKIP`, `GUARD_CONFIG_REV`.

**Priority when two qualities conflict:** no hidden bypass first, then unchanged verdicts for v1
configs, then usability.

## Open & deferred

- open: the live gate can be skipped today. `GUARD_SKIP=. git push` skips every push row, and
  `GUARD_CONFIG_REV=<old sha>` makes a commit or push judged by an older config. Neither the hooks
  nor `guard_bash.py` stop it. W-1 fixes this and ships alone, before any other S1 work.
- needs the operator: recycling-api has 8 staged files on `release/1.18.6` that the gate refused on
  2026-10-17. Commit them with `QG_SKIP_REASON="add laravel-health" git commit -m "…"` (no `&&`), or
  wait for S2, which makes `quality/bin/in-tree.sh` read the staged `composer.lock`. SC-8 runs on the
  live checkouts and needs these committed first.
- needs the operator: W-26 links `~/.local/bin/qg`; W-29 reinstalls the git hooks in the four gated
  repos and in this repo. Both write outside the S1 worktree.
- needs the operator: S2–S5 each end with a migration commit the operator makes. Agents may not run
  `qg migrate` or `qg init`, nor commit a change under `quality/drivers/` or to `quality/config`.
- needs the operator: S6 installs the agent-blocking Claude Code hooks into `~/.claude/settings.json`.
- open: the push gate of recycling-api is not yet compared with `43d7082`. `checks/qg-SC-8.sh --release` matched dashboard (8 rows), app (15) and mobile (61) on 2026-10-18; api stopped at the clean-tree check because `config/sentry.php` and `config/telescope.php` were uncommitted. Re-run `checks/qg-SC-8.sh --release ~/workspace/recycling-api` on a clean api checkout.
- open: the gate stays client-side. GitHub branch protection needs GitHub Pro on these private repos,
  so a script an agent writes can still commit with hooks off.
- deferred to S2: move the driver runtime (`guard_driver_*`, `guard_cfg_copy`, `guard_run_driver`, `guard_number_line`, `guard_save_last`) from `lib/guard-metrics.sh` into `lib/qg-driver.sh` before new drivers land.
- deferred to S2: a push refusal lists no driver findings, and `lib/qg-explain.sh` formats findings itself; route both through `bin/guard-report-errors.sh` once the first driver push row exists.
- deferred: SARIF export. `qg.result/1` keeps names SARIF maps (`ruleId`, `level`, file, line).

## Open questions

| id | question | blocks | searched | status | answer |
|----|----------|--------|----------|--------|--------|
| Q2 | Config format: keep TSV or move to YAML? | no | `vault/architecture/guard-file-formats.md`; 183 bats tests read TSV | defaulted | Keep TSV; `qg list` is the readable view |
| Q3 | CLI name? | no | the framework ships `bin/gate.sh` for plan gates | defaulted | `qg` |

## Success criteria

| id | criterion | kind | how | check | expect | verdict | evidence |
|----|-----------|------|-----|-------|--------|---------|----------|
| SC-1 | WHEN a gate row cannot run THE SYSTEM SHALL print the tool's own last output lines in the refusal, once per distinct output, and when no row was measured SHALL say first that nothing in the code was measured | unit | command | `checks/qg-SC-1.sh` | 0 | MET | `checks/qg-SC-1.sh` exited 0 · 3 of 3 cases passing |
| SC-2 | WHEN a commit or push is refused THE SYSTEM SHALL print, per failing row, its `why`, every finding including file-less ones, the reproduce command, `qg explain <id>`, and how a human passes, within 3500 characters | unit | command | `checks/qg-SC-2.sh` | 0 | MET | `checks/qg-SC-2.sh` exited 0 · 5 of 5 cases passing |
| SC-3 | WHEN a human for whom `/dev/tty` opens and neither `CLAUDECODE` nor `AI_AGENT` is set runs `qg override --reason <why>` THE SYSTEM SHALL let through once the commit of that exact index tree, or the unrecorded commits of that exact pushed sha, and log it; a hand-written token, an agent's commit, a different tree, a `baseline-loosened` row or a worse release metric SHALL still be refused | unit | command | `checks/qg-SC-3.sh` | 0 | MET | `checks/qg-SC-3.sh` exited 0 · 7 of 7 cases passing |
| SC-4 | WHEN `qg`, `qg help <cmd>`, `qg list`, `qg explain <id>`, `qg drivers` or `qg doctor` run in a gated repo THE SYSTEM SHALL exit 0; `qg run --json` SHALL print `{verdict, rows[]}` and exit 0, 1 or 2 like `guard.sh` | unit | command | `checks/qg-SC-4.sh` | 0 | MET | `checks/qg-SC-4.sh` exited 0 · 7 of 7 cases passing |
| SC-5 | WHEN a pushed ref matches a row's `on` cell THE SYSTEM SHALL run that row on that ref; WHEN no row matches, including a ref with no `quality/checks.tsv` or a branch not checked out, THE SYSTEM SHALL accept the push without any tree check | unit | command | `checks/qg-SC-5.sh` | 0 | MET | `checks/qg-SC-5.sh` exited 0 · 7 of 7 cases passing |
| SC-6 | WHEN a v2 `kind: repo, direction: up` row's baseline value is lowered THE SYSTEM SHALL refuse it as `baseline-loosened` | unit | command | `checks/qg-SC-6.sh` | 0 | MET | `checks/qg-SC-6.sh` exited 0 · 2 of 2 cases passing |
| SC-7 | WHEN a target repo commits `quality/drivers/<name>.sh` or changes its runner THE SYSTEM SHALL run only the parent commit's copy, and the commit adding it SHALL be refused unless a human overrides | unit | command | `checks/qg-SC-7.sh` | 0 | MET | `checks/qg-SC-7.sh` exited 0 · 5 of 5 cases passing |
| SC-8 | WHEN the commit gate runs on each of the four gated repos with a change staged under `guard_commit_paths` THE SYSTEM SHALL give every row the same id, value and status as `43d7082`; a row unmeasurable on the reference side makes the check exit 2 | delivery | command | `checks/qg-SC-8.sh` | 0 | MET | `checks/qg-SC-8.sh` exited 0 · dashboard.givore.com: same — 6 rows, exit 0, change to app/api/config/endpoints.ts |
| SC-9 | WHEN an agent (`CLAUDECODE=1`) issues `qg hooks remove`, `qg baseline`, `qg accept`, `qg override`, `qg migrate`, `qg init`, a `GUARD_*` or `QG_*` assignment beside git, guard.sh or qg, a write to `.git/qg-override`, or a write under `quality/drivers/` or to `quality/config` THE SYSTEM SHALL deny it, and SHALL allow `qg explain`, `qg run`, `qg list`, `qg doctor` | unit | command | `checks/qg-SC-9.sh` | 0 | MET | `checks/qg-SC-9.sh` exited 0 · 5 of 5 cases passing |
| SC-10 | WHEN the `43d7082` hook bodies call the new engine THE SYSTEM SHALL reach the same verdicts as the new hook bodies | unit | command | `checks/qg-SC-10.sh` | 0 | MET | `checks/qg-SC-10.sh` exited 0 · 2 of 2 cases passing |

## Definition of done

| id | line | state | evidence |
|----|------|-------|----------|
| DOD-1 | bats suite passes: `./tests/run.sh tests/unit` | met | 274 ok, 0 not ok (was 183 on `43d7082`) |
| DOD-2 | `shellcheck` passes on every new and changed `.sh`; `python3 -m py_compile` on changed `.py` | met | `koalaman/shellcheck -S warning` on 20 changed scripts: one SC2155 at `bin/guard-report-errors.sh:52`, a line unchanged since `43d7082`; library-constant SC2034 and SC1091 as before; `py_compile templates/claude-hooks/guard_bash.py` ok |
| DOD-3 | `vault/architecture/*.md` and `vault/decisions/*.md` pass `bin/doc-lint.sh` | met | no findings on `qg-cli.md`, `qg-driver-contract.md`, `guard-file-formats.md`, `guard-commit-gate.md`, `ADR-001-driver-contract.md`, `README.md` |
| DOD-4 | each commit goes through this repo's own commit gate, with no override | failed | this repo's installed `.git/hooks/pre-commit` is an older body that runs `guard.sh commit` and never refuses, so the gate measured but could not block; W-29 reinstalls it |

## Enforcement states

| id | ruling | state | mechanism |
|----|--------|-------|-----------|
| R-1 | A refusal says what ran, why it failed, how to reproduce and how to pass | HALF-BUILT | `lib/qg-refusal.sh`; SC-1 SC-2 MET. Live only after W-28; v1 rows print the fallback why until S2–S4 |
| R-2 | A tool's own error is never hidden behind a parser message | HALF-BUILT | `guard_save_last` keeps the last 20 lines; SC-1 MET. Live only after W-28 |
| R-3 | Only a human at a terminal overrides, once, for one named tree or sha | HALF-BUILT | `qg_override_take`; `guard_bash.py` denies writing it; SC-3 SC-9 MET. Live only after W-28 and W-29 |
| R-4 | Every v2 gate row states why it exists | ENFORCED | `guard_load_checks` refuses a blank, `-` or TODO why; `gate-config-invalid` refuses it staged; `qg-regressions.bats` |
| R-5 | A commit cannot loosen the gate that judges it through a driver, runner, config file or environment variable | HALF-BUILT | the environment half is live on `main` (`2526467`, `guard-env.bats`); drivers, runners and config are live after W-28; SC-7 SC-9 MET |

## Verified current state

- The gate runs from the working tree of `~/workspace/vault-quality-gates` on branch `main` at `43d7082`. All four repos' `.git/hooks/*` call `bin/guard.sh` there by absolute path, as does the agent factory. `recycling_mobile_app-arch` is a worktree of mobile and shares its hooks · `grep GUARD= .git/hooks/pre-push` · 2026-10-18
- `GUARD_SKIP` is honoured from the caller's environment by every subcommand (`bin/guard.sh:128`); only `baseline --skip` sets it on purpose (`bin/guard.sh:321`). `GUARD_CONFIG_REV` is honoured likewise (`bin/guard.sh:63`); only `~/workspace/agent-control/agent_control/quality_gate.py:53` sets it on purpose · grep · 2026-10-18
- Hook bodies are copied at install (`lib/guard-install.sh:36`); a template edit reaches no repo until `guard.sh hooks install` reruns · read · 2026-10-18
- `pre-push` picks refs from `<sha>:VAULT.md` `guard_release_pattern` and exits 0 before the engine when none match (`templates/git-hooks/pre-push:58-112`). `guard.sh release` exits 2 without `quality/checks.tsv` (`:90-91`) and, under `guard_measure_worktree: false`, when HEAD is not the pushed sha or a gated path is dirty (`:186-207`, `:317`) · read · 2026-10-18
- recycling-api, app.givore.com and dashboard.givore.com set `guard_measure_worktree: false`; api release rows run `docker compose exec -T server` · `grep` · 2026-10-18
- A commit row runs in the staged-tree copy only when its text names `{{tree}}` or `{{cache}}` (`lib/guard-commit.sh:84-95`) · read · 2026-10-18
- Positional checks.tsv reads: `lib/guard-metrics.sh:114`, `lib/guard-commit.sh:85` and `:93`, `bin/guard.sh:127` and `:138-141`, `bin/guard-report-errors.sh:126` · grep · 2026-10-18
- `VAULT.md` keys are read at `bin/guard.sh:67-82` and `:196`, `lib/guard-pass.sh:86`, `templates/git-hooks/pre-push:65`, `templates/claude-hooks/guard-stop.sh:27`, `templates/claude-hooks/guard_bash.py:304` · grep · 2026-10-18
- `guard_bash.py` routes to `scan_guard` only for the exact realpath of `bin/guard.sh` (`:405`). `scan_guard` lets an agent run `verify`, `report` and `hooks status` (`:533-536`). `NEEDLES` (`:14-17`) lacks `qg-override` · ran the hook on fixtures · 2026-10-18
- recycling-api `quality/bin/in-tree.sh` takes `<tree> <cache> <cmd...>` and compares `vendor/` with `HEAD:composer.lock` (`:2`, `:51`) · read · 2026-10-18
- recycling-api `quality/rules.tsv` is keyed by catalog rule id, not by `checks.tsv` row id · read · 2026-10-18
- `QG_SKIP_REASON="x" && git commit` never reaches the hook, which prints nothing · `~/.zsh_history` 1792248821, 1792248877 · 2026-10-18
- Rows: api 32, mobile 66, app 21, dashboard 13. 23 baseline rows hold 0 and 43 rows are `kind: diff` · `awk` over each `quality/checks.tsv` and `baseline.tsv` · 2026-10-18
- Mobile `master` `VAULT.md`: `refs/heads/release/*|refs/heads/realse/*`; dashboard `master` and `development` carry no gate; givore.com and `~/vault/givore` carry none · `git show <branch>:VAULT.md` · 2026-10-18
- The agent factory keeps the last 4000 characters of a refusal (`~/workspace/agent-control/agent_control/quality_gate.py:13`) · read · 2026-10-18
- No surveyed tool blocks an agent's bypass before it runs, and none keeps a committed baseline across tools · `vault/research/2026-10-18-gate-tools-survey.md` · 2026-10-18

## Decisions

| decision | reason | record |
|----------|--------|--------|
| `guard.sh` stays the engine; `bin/qg` is the front a person or agent types | keeps 183 bats tests and every installed hook path | local |
| The engine ignores an inherited `GUARD_SKIP`; it honours `GUARD_CONFIG_REV` only when neither `CLAUDECODE` nor `AI_AGENT` is set | the factory sets the pin outside an agent; nothing else may | local |
| Driver contract and `qg.result/1` as specified in `vault/architecture/qg-driver-contract.md` | custom drivers in other repos depend on it | `vault/decisions/ADR-001-driver-contract.md` |
| One row reader: `guard_load_checks` normalises v1 and v2; callers use `guard_row_field <row> <name>` | a positional read misreads v2 columns | local |
| `checks.tsv` v2 header: `id on kind driver args direction threshold gate why` | `on` replaces `scope` + `guard_release_pattern` per row; `why` explains every refusal | `vault/decisions/ADR-001-driver-contract.md` |
| v1 rows load as driver `shell`; v1 `release` = `push:<guard_release_pattern>`; v1 `why` = `(no reason recorded; run qg migrate)` | the parent commit's config judges a commit, so old branches keep running | local |
| One config reader `qg_config_key`, exposed to Python as `qg config get <key>` | a repo without the vault framework must be gateable | local |
| `pre-push` hands every pushed ref to `guard.sh release`; the engine selects rows by `on` first and exits 0 when none apply, before the config and tree checks | a hook-level filter skips v2 rows; an unconditional tree check refuses ungated pushes | local |
| The engine keeps accepting the `43d7082` hook call forms | installed hooks are copies until W-29 reinstalls them | local |
| Repo drivers and runners load from the config revision; a repo driver may not shadow a built-in name | a commit cannot install what judges it | local |
| Override token holds reason, user, epoch and the index tree hash (commit) or sha (push); consumed only when `guard_override_allowed` passes in the hook; a push token lifts only the unrecorded-commit check | a forged or reused token never passes; a release metric is passed with `accept`, as today | local |
| `guard-report-errors.sh` is the only findings printer; it reads `qg-last/<id>/result.json` `findings[]`, else the row's artifact | one printer, one format | local |
| S1 is built in worktree `~/workspace/vault-quality-gates-qg`, branch `feat/qg-interface`; W-1 ships by its own fast-forward of `main`, the rest by one fast-forward at W-28 | the live gate runs from `main`'s working tree | local |
| Agents write drivers in a `vault-quality-gates` worktree; the operator runs `qg migrate` or `qg init` and makes each repo's migration commit | the agent guards forbid an agent those writes | local |
| A migrated row keeps its id only when old and new give the same value on a commit seeded with one violation of that row; otherwise a new id, a fresh baseline row, and the old id becomes `kind: absent` | a clean commit reads 0 under any driver and proves nothing | local |

## Scope & non-goals

S1 covers the bypass fix, the engine, the `qg` CLI, the driver contract with drivers `shell` and
`phpstan`, the refusal text, the agent guards for the new surfaces, and the docs. S2–S6 are in
`## Sessions`.

Not in scope: server-side enforcement; a YAML config; parallel row execution.

## Artifact lifecycles

| artifact | what requires it | who writes it | who reads it | missing or wrong |
|---|---|---|---|---|
| `$QG_OUT/result.json` (`qg.result/1`) | `guard_run_row` compares `metric`; `guard-report-errors.sh` prints `findings[]` | each driver's `run` | `lib/guard-metrics.sh`, `bin/guard-report-errors.sh`, `lib/qg-explain.sh` | absent, unparsable, `status: error`, `error` set, or `metric` not a number → `unmeasurable`; never 0 |
| driver `describe` JSON `{name, summary, requires[], needs_tree}` | `qg doctor` checks `requires`; the engine builds the staged-tree copy when `needs_tree` is true | each driver | `lib/qg-doctor.sh`, `lib/guard-commit.sh` | malformed → `qg doctor` fails naming the driver, and the row is `unmeasurable` |
| driver `explain [<ruleId>]` text | `qg explain`, the refusal fix hint | each driver | `lib/qg-explain.sh` | empty → refusal prints `no fix hint for driver <name>`; `qg doctor` fails it |
| `checks.tsv` v2 row | `guard_load_checks` | the operator, through `qg migrate` or by hand | every `guard_row_field` caller, `qg list` | wrong field count, unknown driver, `why` = `-`, bad `on` → exit 2 naming file and line; a staged copy that fails is refused by W-13 |
| `quality/config` | gate keys | the operator, through `qg init` or `qg migrate` | `qg_config_key`, `qg config get` | absent → `VAULT.md`; both absent → defaults and `qg doctor` warns |
| `<git-common-dir>/qg-override` | hooks honour it once | `qg override` | `lib/guard-override.sh` | older than 10 minutes, tree or sha mismatch, or agent environment in the hook → ignored, and the refusal says which |
| `<git-common-dir>/qg-last/<id>/` | `qg explain`, `qg last` | `guard_run_row` | `lib/qg-explain.sh` | absent → `qg explain` says the row has not run and prints `qg run commit --only <id>` |

## Work items

| id | file (exact path) | action | tool | constraint | covers | verification | status |
|----|-------------------|--------|------|------------|--------|--------------|--------|
| W-0 | `~/workspace/vault-quality-gates-qg` | `git worktree add -b feat/qg-interface ../vault-quality-gates-qg main` | Bash | never edit `~/workspace/vault-quality-gates` directly | — | `git worktree list` | DONE |
| W-1 | `bin/guard.sh`, `templates/claude-hooks/guard_bash.py`, `tests/unit/guard-env.bats` | engine: `unset GUARD_SKIP` at entry; `baseline --skip` sets it after; ignore `GUARD_CONFIG_REV` when `CLAUDECODE` or `AI_AGENT` is present; hook: deny any `GUARD_*` or `QG_*` assignment or export, and any word naming `GUARD_SKIP` or `GUARD_CONFIG_*`, in a command that is not a read; then fast-forward `main` to this commit alone | Edit, Bash | factory gate env carries neither marker (`agent_control/runner.py` `SAFE_ENV`) | SC-9 R-5 | `tests/unit/guard-env.bats`; tests 2, 4, 5 fail on `43d7082` | DONE |
| W-2 | `vault/architecture/qg-driver-contract.md` | define `run`, `explain [<ruleId>]`, `describe` (`{name, summary, requires[], needs_tree}`); `QG_ARGS` = `key=value … [-- <extra argv>]`; reserved keys `runner=<repo path>` (read from the config revision, called as `<runner> "$QG_TREE" "$QG_CACHE" <bin> <argv>`) and `bin=<tool>` (driver default); `QG_FILES` = path of a NUL list; `QG_BASES` space-separated; `QG_TREE QG_BASE QG_CACHE QG_TARGET QG_OUT QG_REPO`; `qg.result/1` = `schema driver status(measured\|error) metric unit(findings\|percent\|count\|ratio) findings[]{ruleId file line level(error\|warning\|note) message doc} error reproduce`; the engine alone decides pass or fail; the engine keeps the last 20 output lines in `qg-last/<id>/output.txt`; `error` only when the tool produced no readable output | Write | ≤200 lines | SC-7 | doc-lint | DONE |
| W-3 | `vault/decisions/ADR-001-driver-contract.md` | record the contract, `qg.result/1` and v2 header; rejected: parsers only, hk or lefthook as runner | Write | ADR shape | — | doc-lint | DONE |
| W-4 | `lib/qg-events.sh` | `qg_row_runs_on <on> <event> [<ref>]`; grammar: comma list of `commit`, `push`, `push:<ref-glob>`, `baseline`, `-` | Write | glob by bash `[[ == ]]` | SC-5 | `tests/unit/qg-events.bats` | DONE |
| W-5 | `lib/guard-metrics.sh` (`guard_load_checks`, new `guard_row_field`) | read v1 and v2 headers into one named row shape, per the v1 mapping in Decisions | Edit | v1 values unchanged | SC-6 SC-8 R-4 | `tests/unit/guard-metrics.bats` | DONE |
| W-6 | `lib/guard-metrics.sh:114`, `lib/guard-commit.sh:85` and `:93`, `bin/guard.sh:127` and `:138-141`, `bin/guard-report-errors.sh:126` | replace every positional read with `guard_row_field` | Edit | bats asserts no `read -r id scope kind command` remains | SC-6 | grep in `tests/unit/guard-metrics.bats` | DONE |
| W-7 | `lib/qg-config.sh`; `bin/guard.sh:67-82`, `:196`; `lib/guard-pass.sh:86` | `qg_config_key <key>` reads `quality/config` at the config revision, else `VAULT.md`; `guard_vault_md` and `guard_vault_key` call it | Write, Edit | same keys as `extend/dod-keys.tsv` | — | bats | DONE |
| W-8 | `bin/guard.sh` (`cmd_measure`, `guard_release_config`, `guard_release_tree_matches`) | for `release <ref>`: select rows by `on` first; exit 0 with `no gate row runs on <ref>` when none apply, before the config-presence and tree checks; keep the `43d7082` call form `GUARD_SHA=… GUARD_BASE=… guard.sh release <ref>` | Edit | — | SC-5 SC-10 | `tests/unit/guard-hooks.bats` | DONE |
| W-9 | `templates/git-hooks/pre-push` | unset `GUARD_SKIP GUARD_CONFIG_REV GUARD_CONFIG_AT` on entry; call `guard.sh release` for every pushed ref; first refusal line names `qg help` | Edit | — | SC-5 | `tests/unit/guard-hooks.bats` | DONE |
| W-10 | `lib/guard-metrics.sh` (`guard_run_row`) | resolve driver: `drivers/<name>.sh`, else `quality/drivers/<name>.sh` via `guard_config_show` into the temp config dir; refuse a repo driver named like a built-in; resolve `runner=` the same way; run with W-2 env; read `result.json`; keep the last 20 output lines in `qg-last/<id>/output.txt`; write `<git-common-dir>/qg-last/<id>/` | Edit | never execute a working-tree driver or runner | SC-1 SC-7 R-2 R-5 | bats | DONE |
| W-11 | `lib/guard-commit.sh:84-95` | build the staged-tree copy when a row names `{{tree}}`/`{{cache}}` or its driver's `describe` says `needs_tree: true` | Edit | an unstaged edit never changes a v2 value | SC-8 | `tests/unit/guard-commit-tree.bats` | DONE |
| W-12 | `drivers/shell.sh`, `lib/guard-metrics.sh` (`guard_run_shell`) | shell rows run inside guard.sh in their own subshell, under its `set -uo pipefail` and `LC_ALL=C`, then the named parser; `drivers/shell.sh` answers `describe` and `explain` | Write | identical value to `guard_parse_row` on `43d7082` | SC-8 | `tests/unit/qg-regressions.bats`, `checks/qg-SC-8.sh` | DONE |
| W-13 | `lib/guard-commit.sh` (`guard_gate_locked`) | refuse a staged `quality/checks.tsv` that does not load or names a driver that does not resolve; treat `quality/drivers/` and `quality/config` like `checks.tsv` | Edit | — | R-4 R-5 | bats | DONE |
| W-14 | `drivers/phpstan.sh` | `needs_tree: true`; `<runner> … phpstan analyse --no-progress --error-format=json`; `metric` = `totals.errors + totals.file_errors`; findings from `files[].messages[]` and each `errors[]` entry as `{ruleId: phpstan.fileless, file: null}`; `error` only when no JSON or exit above 1 | Write | equals the `phpstan-all` parser value on the same output | SC-2 SC-7 | `tests/unit/qg-driver-phpstan.bats`: fixture runner with `<tree> <cache> <cmd...>` argv; a file-less-only fixture prints its message | DONE |
| W-15 | `lib/guard-override.sh` | `qg override` calls `guard_override_allowed` unchanged, writes `<git-common-dir>/qg-override` with reason, user, epoch, and `git write-tree` of the index or `--push <sha>`; the hook consumes it only when `guard_override_allowed` passes in the hook and the tree or sha matches | Edit | `QG_SKIP_REASON` path unchanged | SC-3 R-3 | `tests/unit/guard-override.bats` | DONE |
| W-16 | `lib/guard-commit.sh` (`guard_commit_refusal`), `lib/guard-metrics.sh` (`guard_refusal`), `bin/guard-report-errors.sh` | refusal: when no row was measured, first line `nothing in your code was measured; a human may pass with qg override`; one summary line per failing row; per row `why`, findings (≤10, `+N more`), output tail once per distinct tail listing its rows, `reproduce: qg run <event> --only <id> [--ref <ref>]`, `details: qg explain <id>`; footer: fix and recommit · `qg explain` · human only `qg override --reason "<why>"`; under `CLAUDECODE`/`AI_AGENT`: `agents may not override; ask the operator`; ≤3500 characters, then `… run qg last` | Edit | `guard-report-errors.sh` reads `qg-last/<id>/result.json` first | SC-1 SC-2 R-1 | `tests/unit/guard-commit-tree.bats` | DONE |
| W-17 | `bin/qg` | dispatcher: `help [cmd]`, `list [--on <event>]`, `run <commit\|push> [--only ids] [--ref ref]`, `explain <id>`, `last`, `drivers [name]`, `doctor`, `config get <key>`, `override --reason`, `init [--profile]`, `migrate`, pass-through `baseline accept hooks report verify`; `--json` everywhere; `run` prints `[i/n] <id> <driver> <s>s <pass\|fail\|error\|skipped>`; unsets `GUARD_SKIP GUARD_CONFIG_REV GUARD_CONFIG_AT` on entry; refuses `override hooks baseline accept migrate init` under `CLAUDECODE`/`AI_AGENT` | Write | no argument → help, exit 0; unknown → exit 2 | SC-4 SC-9 | `tests/unit/qg-cli.bats` | DONE |
| W-18 | `lib/qg-explain.sh` | `qg explain <id>` and `qg last` | Write | works with no prior run | SC-4 | `tests/unit/qg-cli.bats` | DONE |
| W-19 | `lib/qg-doctor.sh` | check hooks installed and identical to templates; Claude hooks listed; config loads; each driver resolves and its `requires` exist; each `push:<glob>` matches a branch, else warn naming it; `qg` on `PATH` | Write | exit 0 with warnings, 1 on a failure | SC-4 | `tests/unit/qg-cli.bats` | DONE |
| W-20 | `lib/qg-migrate.sh` | `qg migrate`: v1 → v2 rows as `shell`; without `--draft` refuses while any `why` is the fallback; writes `quality/config` from `VAULT.md`, adding `quality/drivers quality/config` to `guard_protected_paths` | Write | never commits | — | `tests/unit/qg-migrate.bats` | DONE |
| W-21 | `templates/claude-hooks/guard_bash.py` | add `qg-override`, `qg-last` to `NEEDLES`; deny writes whose real path is inside the git dir or common dir of the cwd or target repo, keeping the `/tmp` exemption; add `scan_qg` for `qg` and for `bin/qg` matched by exact realpath, allowing `help list explain last drivers doctor run report verify config` and `hooks status`; protected prefixes via `qg config get` | Edit | existing `scan_guard` unchanged | SC-9 | `tests/unit/guard-claude-hooks.bats` | DONE |
| W-22 | `templates/claude-hooks/guard-edit.sh`, `templates/claude-hooks/guard-stop.sh:27` | deny edits to `quality/drivers/` and `quality/config`; Stop detects a gated repo by a committed `quality/checks.tsv` and names `quality/config` and `quality/drivers` among files never to edit | Edit | — | SC-9 | `tests/unit/guard-claude-hooks.bats`, `tests/unit/guard-stop.bats` | DONE |
| W-23 | `templates/init/docs.tsv`, `php.tsv`, `nuxt.tsv`, `flutter.tsv`, `hugo.tsv` | starter rows for `qg init --profile`, each with `why` | Write | — | — | `qg init` then `qg doctor` in a temp repo | DONE |
| W-24 | `vault/architecture/guard-file-formats.md`, `vault/architecture/guard-commit-gate.md`, `vault/architecture/qg-cli.md`, `README.md` | v2 header, `on`, `why`, `quality/config`, token; `qg` subcommands with options, exit codes, `--json`; README leads with "If a gate refused you" | Edit, Write | each ≤200 lines | R-1 | doc-lint | DONE |
| W-25 | `checks/qg-SC-1.sh` … `checks/qg-SC-10.sh` | one script per criterion; SC-8 runs on the live checkouts with `43d7082` from a detached worktree as reference, diffs per-row `id|value|status`, exits 2 on a reference row that is unmeasurable; SC-10 installs the `43d7082` hook bodies against the new lib | Write | exit 0 pass, 1 fail, 2 could not run | SC-1..SC-10 | `gate.sh verdict --run` | DONE |
| W-26 | `~/.local/bin/qg` | symlink to `~/workspace/vault-quality-gates/bin/qg` | Bash | needs the operator | — | `command -v qg` | BLOCKED: operator |
| W-27 | `git log main..feat/qg-interface` | list every commit and review its diff before cut-over | Bash | only commits from S1 sessions | — | diff reviewed | DONE |
| W-28 | `~/workspace/vault-quality-gates` branch `main` | fast-forward to `feat/qg-interface` once DOD-1..3 and SC-1..SC-10 pass | Bash | — | — | `git log -1` | TODO |
| W-29 | `.git/hooks/` of recycling-api, recycling_mobile_app, app.givore.com, dashboard.givore.com, vault-quality-gates | `guard.sh hooks install --claude` from `main` after W-28 | Bash | needs the operator | — | `qg doctor` in each | BLOCKED: operator |

## Sequencing & dependencies

W-0, then W-1 and its own fast-forward of `main`. Then W-2, W-3, W-4, W-7; then W-5, W-6, W-8, W-10,
W-11, W-12, W-13, W-14 (engine); then W-9, W-15, W-16 (hooks, override, refusal); then W-17..W-23 (CLI
and guards); then W-24, W-25. W-27, W-28 and W-29 run last, together. SC-8 waits on the operator's
recycling-api commit. S2–S5 start after S1 is `done`; S6 after S2–S5.

## Sessions

| id | scope | command | status | depends | date | evidence |
|----|-------|---------|--------|---------|------|----------|
| S1 | bypass fix; contract, `shell` and `phpstan` drivers, v2 config, `qg` CLI, refusal, override token, agent guards | this plan | todo | | | |
| S2 | PHP drivers (phpmd, phpcs, pint, phpinsights, composer-dependency-analyser, phpunit, infection, jscpd-added, cloc) + recycling-api rows with a hand-written `why` each + `quality/bin/in-tree.sh` reads the staged `composer.lock`; operator makes the migration commit | `/v-team ~/workspace/vault-quality-gates/vault/plans/2026-10-18-1121-qg-common-interface.md#S2` | todo | S1 | | |
| S3 | web drivers (eslint, nuxt typecheck, knip, depcruise, fallow, vitest, stryker) + app.givore.com and dashboard.givore.com rows; one `jscpd-added` and one `eslint` driver replace the copies; gate dashboard `master` and `development`; operator makes the migration commits | `/v-team …#S3` | todo | S1 | | |
| S4 | Flutter drivers (dart analyze + givore lint runner, flutter analyze, dart format, dart_code_linter, layerlens, lakos, flutter test + lcov, mutation_test, copydetect, `grep-count`) + recycling_mobile_app rows; drop the `realse` alternative; operator makes the migration commit | `/v-team …#S4` | todo | S1 | | |
| S5 | non-code repos: `~/vault/givore` (doc-lint) and givore.com (hugo build) via `qg init --profile`, run by the operator; update `~/vault/givore/indications/web/blocking-checks-live-in-checks-tsv.md` and `~/vault/givore/indications/cross-repo/quality-gate-binds-every-push.md` to name `qg` | `/v-team …#S5` | todo | S1 | | |
| S6 | remove the v1 reader and `VAULT.md` fallback once `qg doctor --all-branches` finds no v1 config; install the Claude hooks at user level; the only exemption is editing this plugin's own files, and every git, qg and write rule stays active for every other repo a session touches | `/v-team …#S6` | todo | S2, S3, S4, S5 | | |

## Cross-session contracts

| id | contract | produced by | consumed by | shape |
|----|----------|-------------|-------------|-------|
| C-1 | driver contract | S1 | S2, S3, S4, S5 | `drivers/<name>.sh run\|explain [<ruleId>]\|describe`; env, `QG_ARGS` grammar, `runner=`, `bin=`, `needs_tree` and `qg.result/1` in `vault/architecture/qg-driver-contract.md`; worked example `drivers/phpstan.sh` |
| C-2 | `checks.tsv` v2 | S1 | S2, S3, S4, S5, S6 | header `id on kind driver args direction threshold gate why`; `on` grammar in `vault/architecture/guard-file-formats.md` |
| C-3 | `qg migrate`, `qg init --profile` | S1 | S2, S3, S4, S5 | `bin/qg migrate [--draft]`, `bin/qg init --profile docs\|php\|nuxt\|flutter\|hugo`; operator-run |
| C-4 | row parity on migration | S2, S3, S4 | S6 | `checks/qg-parity-<repo>.sh` in `~/workspace/vault-quality-gates`: per row, a commit seeded with one violation; old and new id and value must match, else the row takes a new id |
| C-5 | every gated repo on v2 | S2, S3, S4, S5 | S6 | `quality/checks.tsv` v2 header committed on every branch with an upstream in recycling-api, app.givore.com, dashboard.givore.com, recycling_mobile_app, `~/vault/givore`, givore.com; checked by `qg doctor --all-branches` |

## Rollback

During S1 nothing live changes except W-1, which `git revert` on `main` undoes at once. After W-28,
`git reset --hard <W-1 commit>` on `main` and `guard.sh hooks install --claude` in each repo restore
the gate, as long as no repo has committed a v2 `checks.tsv`. After S2 starts, roll forward only: a
v2 config under the old engine makes every commit exit 2.

## Test plan

Bats unit tests in `tests/unit/` with temporary repos and bare remotes, run by `./tests/run.sh
tests/unit` (Docker image `tests/Dockerfile`). Hook guards: fixtures through
`templates/claude-hooks/guard_bash.py`. End to end: `checks/qg-SC-*.sh`; SC-8 on the live checkouts
with `43d7082` as reference.

## Test design dossier

**Rules the tests pin:**

| rule | value |
|---|---|
| agent environment | `CLAUDECODE` or `AI_AGENT` present in the environment, even empty, means an agent (`lib/guard-override.sh:17-18`) |
| token age | valid at 600 seconds or less; refused at 601 and for a future or non-numeric epoch |
| v1 `release`/`both` with no `guard_release_pattern` | maps to `push:refs/heads/release/*`, the hook's default today |
| `metric` absent, null, `""`, `NaN`, comma decimal, string, boolean | `unmeasurable`; a finite number with `status: measured` and no `error` is the only value |
| row status | absent or unparsable `result.json`, `status: error`, `error` set, or a non-number `metric` → `unmeasurable`, never 0 |
| push row selection | no `on` match → exit 0 before the config and tree checks; a match with no `checks.tsv`, HEAD ≠ sha or a dirty gated path under `guard_measure_worktree: false` → exit 2 |
| driver resolution | built-in, then the repo driver at the config revision; a shadow name is refused; a working-tree-only driver or runner never runs |

**Invariants:** a v1 row and its v2 `shell` form give the same `id|value|status`. An unstaged edit never
changes a commit-gate value. No subcommand reports pass for an unmeasurable row. An inherited
`GUARD_*` or `QG_*` variable never changes a verdict, except `GUARD_CONFIG_REV` outside an agent.
A refusal printed twice from the same results is byte-identical.

## Test backlog

| id | source | kind | target (exact path) | intent | priority | disposition |
|----|--------|------|---------------------|--------|----------|-------------|
| T-1 | W-1 | unit | `tests/unit/guard-override.bats` | an inherited `GUARD_SKIP` (`.`, a row id, a glob) changes no commit or push verdict; `baseline --skip` still skips | must | |
| T-2 | W-1 | unit | `tests/unit/guard-override.bats` | `GUARD_CONFIG_REV=<older sha>` is ignored with `CLAUDECODE` or `AI_AGENT` present, even empty, and honoured otherwise | must | |
| T-3 | W-1 W-21 | unit | `tests/unit/guard-claude-hooks.bats` | denied: `GUARD_SKIP=. git push`, `export GUARD_SKIP=.; git push`, `export QG_X=1; git commit`, `env GUARD_X=1 git push`, `GUARD_CONFIG_REV=x qg verify HEAD~1..HEAD`; the same commands without the assignment pass | must | |
| T-4 | W-21 | unit | `tests/unit/guard-claude-hooks.bats` | denied under every option order and wrapper: `qg hooks remove`, `qg override`, `qg baseline`, `qg migrate`, `qg init`, `bin/qg accept` by realpath, a redirect into `.git/qg-override`; allowed: `qg explain`, `run`, `list`, `doctor`, `config get` | must | |
| T-5 | W-15 | unit | `tests/unit/guard-override.bats` | `qg override` writes a token only with a non-blank reason, an openable `/dev/tty`, and no agent variable present | must | |
| T-6 | W-15 | unit | `tests/unit/guard-override.bats` | a token is refused, with its cause named, when hand-written, aged 601 s or future-dated, bound to another tree (one extra staged file), reused, consumed in another worktree, or consumed under an agent variable; malformed field counts and a tab or newline in the reason are refused | must | |
| T-7 | W-15 | unit | `tests/unit/guard-override.bats` | a push token lifts only the unrecorded-commit check for its exact sha (not a prefix); `baseline-loosened` and a worse release metric stay refused, alone and combined; a commit token never lifts a push check and the reverse | must | |
| T-8 | W-4 | unit | `tests/unit/qg-events.bats` | `qg_row_runs_on` truth table: each token against commit, push+ref and baseline; `-` never runs; empty, whitespace, `,commit`, `commit,`, `commit,,push`, `COMMIT`, `push:` and unknown tokens exit 2 naming file and line; `|`, `?`, `[` follow `[[ == ]]` | must | |
| T-9 | W-8 W-9 | unit | `tests/unit/guard-hooks.bats` | `release <ref>` exits 0 with `no gate row runs on <ref>` before any config or tree check: ref with no `checks.tsv`, branch not checked out, `guard_measure_worktree: false` with HEAD ≠ sha and a dirty path, rows `on` commit or baseline only | must | |
| T-10 | W-8 | unit | `tests/unit/guard-hooks.bats` | when a row matches: missing `checks.tsv` exits 2; `guard_measure_worktree: false` with HEAD ≠ sha or dirty exits 2, with HEAD = sha and clean measures the working tree; `true` measures the pushed tree; `push:refs/heads/release/*` runs only its rows | must | |
| T-11 | W-10 | unit | `tests/unit/qg-driver-resolution.bats` | built-in first, then the repo driver at the config revision; a shadow name is refused; a working-tree-only driver or runner never runs (sentinel file absent); a commit that modifies a driver runs the parent copy; a commit adding one is refused without an override | must | |
| T-12 | W-10 W-2 | unit | `tests/unit/qg-row-status.bats` | each metric and result partition from the dossier gives `unmeasurable` and exit 2, never 0; metric 0 is measured; a crash keeps the last 20 output lines; a malformed `describe` makes the row unmeasurable; an id or driver name with `/`, `..` or a newline writes nothing outside `qg-last/` | must | |
| T-13 | W-5 W-6 | unit | `tests/unit/guard-metrics.bats` | v1 → v2 mapping for scope `commit`, `release`, `both`, `baseline`, `-` with set, alternated and empty patterns; per-row `id|value|status` equals the v1 reader; permuted v2 columns change nothing; grep asserts no `read -r id scope kind command` remains | must | |
| T-14 | W-5 W-13 | unit | `tests/unit/guard-metrics.bats` | v2 rows of 8 and 10 fields, duplicate column, CRLF, `why` = `-`, unknown driver, bad `on` exit 2 naming file and line; a staged `checks.tsv` that fails to load is refused at commit | must | |
| T-15 | W-6 | unit | `tests/unit/guard-baseline-growth.bats` | v2 `direction: up` row: lowering the baseline is `baseline-loosened`, raising or equal passes; `direction: down` the reverse; `threshold` is never read as direction | must | |
| T-16 | W-12 | unit | `tests/unit/qg-driver-shell.bats` | 20 v1 fixture rows, including a piped `exitcode` row and empty or non-numeric output, give the same value through `shell` as through `guard_parse_row` | must | |
| T-17 | W-11 | unit | `tests/unit/guard-commit-tree.bats` | an unstaged edit never changes the value of a row naming `{{tree}}` or a driver with `needs_tree: true`; `QG_FILES` with spaces, newlines, leading `-`, tabs, 0 and 5000 names delivers each name once | must | |
| T-18 | W-16 | unit | `tests/unit/guard-commit-tree.bats` | refusal at 3499, 3500, 3501 characters: `… run qg last` only above 3500; findings 0, 1, 10, 11 give `+N more` only above 10; tails of 0, 19, 20, 21 lines keep the last 20; identical tails print once listing every row id; same results print identical bytes | must | |
| T-19 | W-16 | unit | `tests/unit/guard-commit-tree.bats` | eight v1 rows all exiting 2 with one stderr line: first line says nothing in the code was measured, each row shows the fallback `why`, the tail prints once, total under 3500 characters | must | |
| T-20 | W-14 | unit | `tests/unit/qg-driver-phpstan.bats` | phpstan value equals `phpstan-all` for 0, 1, N errors, file-less only, files only and both; a file-less-only fixture prints its message as `phpstan.fileless`; the fixture runner takes `<tree> <cache> <cmd...>`; a working-tree edit to the runner changes nothing | must | |
| T-21 | W-8 | unit | `tests/unit/guard-hooks.bats` | the `43d7082` hook bodies against the new lib: `release/1.0.0` is measured, `feature/x` exits 0, a refused commit stays refused | must | |
| T-22 | W-7 W-17 | unit | `tests/unit/qg-cli.bats` | `qg config get <key>` reads `quality/config`, else `VAULT.md`, at the config revision and ignores an unstaged edit | should | |
| T-23 | W-17 W-18 W-19 | unit | `tests/unit/qg-cli.bats` | `qg` with no argument prints help and exits 0; unknown subcommand exits 2; `qg run --json` gives `{verdict, rows[]}` and the `guard.sh` exit code; `qg explain` works before any run; `qg doctor` warns on a `push:` glob matching no branch | should | |
| T-24 | W-17 | unit | `tests/unit/qg-cli.bats` | adding arbitrary `GUARD_*` and `QG_*` variables to the caller leaves `qg run commit --json` unchanged | nice | |

## Refs

- `vault/plans/2026-09-14-1251-quality-regression-gate.md` — the original gate specification this extends.
- `vault/architecture/guard-file-formats.md`, `vault/architecture/guard-commit-gate.md` — the contracts S1 edits.
- `vault/research/2026-10-18-gate-tools-survey.md` — why the runner is built here and not on hk or lefthook.
- `2026-10-18-1121-qg-common-interface.trail.md` — how this plan was reached.
