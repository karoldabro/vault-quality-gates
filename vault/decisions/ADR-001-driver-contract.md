---
type: decision
project: vault-quality-gates
id: ADR-001
status: accepted
scope: cross-repo
tags: [adr, quality, gates, drivers]
---

# ADR-001: drivers, `qg.result/1` and the v2 `checks.tsv` header

## Context

Each gated repo runs different tools: PHPStan, Pint, PHPMD, PHPUnit, Vitest, Flutter, jscpd and
custom scripts. The gate needs one number per row and the findings behind it, from every tool.

A v1 row is a shell command plus a parser under `lib/guard-parsers/`. A parser returns only a
number. A refusal built from a parser cannot list findings, explain a rule, or name a reproduce
command. Adding a tool means adding a parser to this plugin.

A v1 row also cannot state when it runs on a given branch. One `guard_release_pattern` key in
`VAULT.md` chose the push refs for every row. A v1 row carries no reason, so a refusal cannot say
why the gate exists.

The configuration is read by `bin/guard.sh` and its libraries, written in bash and awk. The agent
guards in `templates/claude-hooks/guard_bash.py` parse the same files.

## Decision

1. **A driver wraps one tool.** It answers `run`, `explain [<ruleId>]` and `describe`. It reads
   its inputs from `QG_*` environment variables and writes one `result.json`. Built-in drivers live
   in `drivers/`; a repo adds its own in `quality/drivers/`. The full contract is
   `vault/architecture/qg-driver-contract.md`.
2. **Every driver writes `qg.result/1`.** The fields are `schema`, `driver`, `status`, `metric`,
   `unit`, `findings[]`, `error` and `reproduce`. The engine compares `metric`; the driver never
   decides pass or fail.
3. **`quality/checks.tsv` v2 has this header:**
   `id on kind driver args direction threshold gate why`.
   `on` names the events and push-ref globs per row. `driver` and `args` replace `command`, `parser`
   and `artifact`. `why` is required, so every refusal states why the gate exists.
4. **The loader still reads v1.** A v1 row runs as driver `shell`. Its `on` comes from `scope` and
   `guard_release_pattern`. `vault/architecture/guard-file-formats.md` states the mapping.

## Consequences

- A repo adds a tool by committing a driver. The plugin needs no new parser.
- The refusal, `qg explain` and `bin/guard-report-errors.sh` read one findings format from
  `<git-common-dir>/qg-last/<id>/result.json`.
- A repo driver judges the next commit. Changing one therefore needs a human override
  (`gate-config-changed`, `vault/architecture/guard-commit-gate.md`).
- Repo drivers in other repos depend on `qg.result/1`, so a change to its fields breaks them.
- v1 rows keep running with a fallback `why` until a human runs `qg migrate`.

## Rejected options

| option | why it does not fit |
|---|---|
| Keep parsers only, with no drivers | a parser returns a number and nothing else, so the refusal cannot list findings, explain a rule or reproduce the run |
| hk 2.7.0 as the runner | no committed baseline across tools; no block of an agent's bypass before it runs; no built-in step for phpstan, pint, phpmd, flutter, vitest, phpunit or jscpd |
| lefthook 2.2.2 as the runner | the same three gaps; in addition it prints raw tool output with no normalized findings |
| A YAML configuration | the engine is bash and awk, which read TSV with no parser dependency; `qg list` is the readable view |

The tool comparison is `vault/research/2026-10-18-gate-tools-survey.md`.
