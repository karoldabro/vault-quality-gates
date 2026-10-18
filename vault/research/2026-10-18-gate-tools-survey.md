# Repo-independent quality-gate tool: does one exist?

Research date: 2026-10-18. Versions and dates come from the GitHub releases API, npm and PyPI on that day unless flagged.

## Answer

No single tool meets all 7 requirements. **hk (jdx/hk) v2.7.0** comes closest. It has global plus per-repo config, conditions on branch and hook, normalized diagnostics with JSON and SARIF output, custom steps, and a built-in Claude Code Stop hook. It lacks three things: a committed-baseline ratchet, a "how to fix" field, and PreToolUse anti-bypass guards. Those three, plus parsers for tools whose output hk cannot read (phpunit, vitest, flutter test, jscpd), are the custom layer.

## Unverified items

| Item | Status |
|---|---|
| Trunk CLI 1.25.0 release date | Not verified. `https://trunk.io/releases/latest` reports `version: 1.25.0` but publishes no date, and no changelog page exists for 1.25.0. |
| Trunk CLI license | Proprietary/closed source, stated from memory. Only the launcher (`@trunkio/launcher` 1.3.4, npm 2025-08-15) and `trunk-io/plugins` (MIT, v1.11.0, 2026-08-01) are public. |
| hk builtins for phpstan, pint, dart, flutter, vue-tsc, vitest, phpunit, jscpd | A text search of `https://hk.jdx.dev/builtins.html` found none of them. Found: eslint, tsc, php_cs/phpcs, markdownlint, rumdl, vale, lychee. Each missing tool needs a custom step. |
| Native baselines in the underlying tools | Stated from memory and not re-checked: PHPStan `--generate-baseline`, PHPMD `--generate-baseline`, ESLint bulk suppressions (`--suppress-all`, since v9.24), and no native baseline in `dart analyze` / `flutter analyze`. |
| `takahirom/claude-code-quality-gate` | Listed on agentskill.sh. The GitHub API returns 404, so the version, license and date are unknown. |
| MegaLinter git-hook use | Its docs describe CI and the `mega-linter-runner` Docker runner. No native hook-trigger config was found. |

## Requirement key

1 any repo incl. markdown · 2 per-repo gates by event and branch · 3 normalizing drivers · 4 user-added gates and drivers · 5 forces an AI agent, blocks bypass · 6 human+AI CLI with explanations · 7 ratchet vs committed baseline

## Tool matrix

### Hook managers / orchestrators

| Tool | Latest (date) | License | Maintenance | 1 | 2 | 3 | 4 | 5 | 6 | 7 |
|---|---|---|---|---|---|---|---|---|---|---|
| **hk** (jdx/hk) | v2.7.0 (2026-10-16) | MIT | Active (push 2026-10-17) | yes: any command; global `~/.config/hk/config.pkl` | yes: all git hooks incl. pre-push; `condition` expr-lang with `exec('git branch --show-current')` | partial: `diagnostic_format` = gcc / sarif / eslint-json / cargo-json parses to file, position, severity, message, rule; no fix-hint field; most builtins do not set it | yes: custom Pkl steps, shared steps | partial: `hk agent stop-hook` blocks Claude Code Stop until `hk check` passes; `hk agent hooks --target claude-code`; MCP server; no PreToolUse anti-bypass | yes: `hk check --plan`, `--format json/jsonl`, `--sarif` | no: only diff/changed-file scoping; `hk util sarif-diff` turns SARIF fixes into a patch and is not a baseline |
| **lefthook** | v2.2.2 (2026-10-13) | MIT | Active | yes | yes: `only`/`skip` with `ref: release/*` (glob on the current branch, not the push target), `rebase`, `merge`; `remotes` share config from a git repo | no: raw output only | yes: any `run`/`script` | no: `LEFTHOOK=0` and `--no-verify` bypass it | partial: `fail_text`, `output` control; no structured output | no |
| **pre-commit** | v4.7.0 (2026-10-13, PyPI 4.7.0) | MIT | Active | yes | partial: `stages` incl. pre-push; branch only through `PRE_COMMIT_REMOTE_BRANCH` read inside the hook script | no | yes: local/repo hooks | no: `SKIP=`, `--no-verify` | partial | no |
| **prek** (j178/prek) | v0.5.5 (2026-10-05) | MIT | Very active (push 2026-10-18) | yes: single binary, workspace/monorepo mode | partial: same model as pre-commit plus `prek.toml`, hook groups | no | yes | no (ships an agent *skill*, not an enforcement hook) | partial | no |
| **husky** | v9.1.7 (2024-11-18) | MIT | Low: no release for 23 months, last push 2026-03-19 | partial: needs Node | partial: shell scripts in `.husky/` | no | yes: shell | no: `HUSKY=0` | no | no |
| **lint-staged** | v17.6.0 (2026-09-26) | MIT | Active | partial: Node | no: staged-file runner only | no | yes | no | no | no |
| **CaptainHook** | 5.29.2 (2026-03-25) | MIT | Moderate | partial: PHP runtime | yes: all hooks; conditions `Branch\On`, `Branch\OnMatching`, `FileStaged\OfType`, `Logic\LogicAnd`/`LogicOr` | no | yes: shell or PHP actions | no | partial | no |
| **GrumPHP** | v2.26.0 (2026-10-16) | MIT | Active | partial: PHP/Composer | partial: `git:pre-commit` and `git:commit-msg` only; testsuites; no pre-push | partial: ~70 PHP tasks (phpstan, phpmd, phpunit, pest, eslint, shell) with a uniform pass/fail but no finding schema | yes: shell task, extensions | no | partial | no |
| **mise tasks** | v2026.10.13 (2026-10-17) | MIT | Very active | yes | partial: tasks, plus a generated git pre-commit hook (from memory) | no | yes | no | yes | no |
| **Task** (go-task) | v3.54.0 (2026-10-01) | MIT | Active | yes | no: no git-hook integration | no | yes | no | yes | no |

### Linter meta-runners

| Tool | Latest (date) | License | Maintenance | 1 | 2 | 3 | 4 | 5 | 6 | 7 |
|---|---|---|---|---|---|---|---|---|---|---|
| **qlty CLI** | v0.657.0 (2026-10-16) | Business Source License 1.1 ("Fair Source", converts to OSS later) | Very active | yes | partial: `qlty githooks install`; `triggers = [pre-commit, pre-push, agent, ...]` per plugin; no branch condition | yes: plugins parse to one issue model, `--sarif` output | partial: plugin *definitions* from custom `sources`; vendor docs say new parsers are added by Qlty ("contact us"); custom rules through ast-grep/semgrep | no: the docs say `git push --no-verify` skips it; has an `agent` trigger only | yes | partial: `--upstream <ref>` / `--upstream-from-pre-push` checks the diff vs a ref (new-in-diff), no committed baseline file. No phpunit, vue-tsc or flutter analyze plugins. |
| **Trunk Check / Code Quality** | CLI 1.25.0 (date **unverified**) | Proprietary CLI (unverified); plugins MIT | Reduced: web issue browser shut down 2025-05-09; nightly/PR web workflows deprecated with shutdown 2025-07-27; CLI kept | yes | partial: `trunk git-hooks`; actions | yes: unified issue model, SARIF parser | yes: custom linters in `trunk.yaml` with parsers | no | yes | yes (diff-based): "hold the line" reruns linters on upstream and the work tree and reports new issues only; this is not a committed baseline |
| **MegaLinter** | v10.1.0 (2026-09-05) | AGPL-3.0 | Active | yes: includes markdownlint, jscpd, phpstan, dartanalyzer | no: CI/Docker-oriented | yes: SARIF reporter | yes: plugin descriptors | no | partial: verbose reports | partial: `VALIDATE_ALL_CODEBASE=false` lints only new or edited *files* |

### Normalization, ratchet and review layers

| Tool | Latest (date) | License | Maintenance | 1 | 2 | 3 | 4 | 5 | 6 | 7 |
|---|---|---|---|---|---|---|---|---|---|---|
| **reviewdog** | v0.21.2 (2026-09-18) | MIT | Active | yes | no: a filter, not an orchestrator | yes: input errorformat (hundreds of presets), checkstyle, SARIF, rdjson/rdjsonl, diff; the rdjson schema has severity, code with URL, and suggestions | yes: errorformat strings for any tool | no | partial: `-reporter=local`, `-fail-level` | partial: `-filter-mode=added` / `diff_context` reports only findings on changed lines vs `-diff="git diff <ref>"` |
| **SARIF 2.1.0** (OASIS standard) + **sarif-multitool** | sarif-sdk v5.8.0 (2026-10-14); npm `@microsoft/sarif-multitool` 5.8.0 (2026-10-14) | Format: OASIS; SDK MIT (from memory) | Active | n/a | n/a | yes: the schema has `result.ruleId`, `locations`, `message`, `fixes` (§3.27.30), `partialFingerprints` (§3.27.17) | n/a | n/a | n/a | yes in the format: `result.baselineState` = `new`/`unchanged`/`updated`/`absent` (§3.27.24); multitool `match-results-forward` computes it from a previous run (from memory) |
| **Betterer** | stable v5.4.0 (npm 2022-08-09); v6.0.0-alpha.1 (2024-12-01) | MIT | Stale: no stable release since 2022, repo push 2026-07-11 | partial: Node; tests are JS functions | no | partial: own result snapshot | yes: custom tests | no | partial | yes: a committed `.betterer.results` file; fails if a metric gets worse and records it when it improves |
| **Danger** (danger-js / danger ruby) | danger-js 14.0.6 (2026-08-27); danger 9.6.1 (2026-07-29) | MIT | Active | partial | no: PR/CI time (`danger local` exists) | no | yes: Dangerfile | no | partial | no |

### AI-agent gating (Claude Code)

| Item | Latest (date) | License | What it does |
|---|---|---|---|
| **Claude Code hooks** (official) | n/a | n/a | `PreToolUse` blocks a tool call with exit 2 or `hookSpecificOutput.permissionDecision: "deny"` plus `permissionDecisionReason`. `Stop` returns `{"decision":"block","reason":...}` so the agent cannot finish. Managed settings: `allowManagedHooksOnly`; a user, project or local `disableAllHooks` cannot disable managed hooks; hooks merge across levels, so lower levels cannot remove managed hooks. Source: https://code.claude.com/docs/en/hooks |
| **hk agent stop-hook** | hk v2.7.0 (2026-10-16) | MIT | Runs `hk run check --safe` as a Stop hook and prints `{"decision":"block","reason":...}` on failure. Passes in repos without hk config, so it is safe in user-level settings. |
| **block-no-verify** (tupe12334) | 1.3.0 (npm 2026-06-18) | MIT | PreToolUse guard that blocks `--no-verify`/`-n` on git commit, push, merge, cherry-pick, rebase and am. Only 7 stars. |
| **nizos/tdd-guard** | v1.7.0 (2026-06-23) | MIT | Hook-based TDD enforcement for Claude Code; enforces TDD only, not general gates. |
| **affaan-m/everything-claude-code** (`delivery-gate`) | v2.2.3 (2026-10-01) | MIT | A Stop hook that blocks completion until deterministic checks pass. Part of a large harness. |
| **takahirom/claude-code-quality-gate** | **unverified** (repo 404) | unknown | Stop hook loops a reviewer subagent; a PreToolUse hook blocks commits without approval. |

Guide that documents the layered approach (PreToolUse deny, `permissions.deny`, PATH-shim git wrapper, CI backstop) and cites claude-code issue #40117 (agent bypassed deny rules; closed "not planned"): https://pydevtools.com/handbook/how-to/how-to-stop-ai-agents-from-bypassing-pre-commit-hooks/

## Conclusions

### (a) Does any tool meet all 7?

None does. Requirement 5 (agent cannot bypass) and requirement 7 (committed baseline across heterogeneous tools) are missing everywhere:

- Only Betterer has a committed baseline, and it is JavaScript-only and stale.
- Trunk, qlty, reviewdog and MegaLinter only offer diff-based new-only checks.
- Only hk ships agent integration, and only as a Stop hook. Nothing ships PreToolUse anti-bypass beyond tiny single-purpose guards.

### (b) Best-fit combination

1. **Orchestration and triggers: hk v2.7.0.**
   - Global `~/.config/hk/config.pkl` holds shared step definitions ("drivers"). Each repo's `hk.pkl` declares which gates run on `pre-commit` and `pre-push`.
   - A `condition` decides branch-specific gates. For push to `release/*`, the condition must read the pushed remote ref, not the current branch.
   - hk works the same in markdown-only vault repos (markdownlint, rumdl, vale, lychee, shell steps).
   - The fallback is lefthook v2.2.2: more mature `only: ref`, no normalization.
2. **Normalized format: SARIF 2.1.0.**
   - Findings carry `ruleId`, location, message, `fixes`, `partialFingerprints`.
   - Ratchet state goes in `baselineState`.
   - hk already emits `--sarif`. reviewdog's errorformat presets are a source of parsers for tools hk cannot read.
3. **Ratchet: use the underlying tool's native baseline where it exists.**
   - Native baselines (from memory): PHPStan baseline, PHPMD baseline, ESLint `eslint-suppressions.json`.
   - Everything else (dart/flutter analyze, vue-tsc, jscpd, custom scripts): a thin SARIF-fingerprint diff against a committed `.gates/baseline.sarif`.
4. **Agent enforcement: Claude Code hooks in user-level or managed settings.**
   - `hk agent stop-hook` as the Stop hook.
   - A PreToolUse Bash guard (own, or block-no-verify as a starting point).
   - `permissions.deny` on edits to `.git/hooks/**`, `hk.pkl`, `.gates/baseline.*`.
   - Optional `allowManagedHooksOnly` in managed settings.
5. **Backstop: CI and branch protection.** Run the same `hk check --all` in CI with required status checks on `release/*`. Every client-side hook can be bypassed by a human with `--no-verify`, so only server-side checks are binding.

### (c) What has to be custom-built

1. **Driver adapters** for tools that print no gcc/SARIF/eslint-json output:
   - phpunit and pest: JUnit XML to SARIF.
   - vitest and dart/flutter test: JSON reporters to SARIF.
   - flutter/dart analyze: `--format=machine` to gcc or SARIF.
   - jscpd: its JSON or SARIF reporter (MegaLinter marks jscpd as SARIF-capable).
   - pint: `--format=json`.
   - Custom shell scripts: a contract to print gcc lines or SARIF.
   - Each adapter is a step definition in the global Pkl config.
2. **Ratchet engine.** A small CLI does three jobs:
   - Fingerprint each SARIF result by rule, file, and a normalized snippet or `partialFingerprints`.
   - Diff the results against the committed baseline and set `baselineState`.
   - Fail on `new` only, and offer `baseline update`, which rejects growth unless forced.
3. **"How to fix" layer.** No tool carries a fix hint per finding.
   - Map `ruleId` to a remediation text file, with the rule doc URL from SARIF `helpUri`.
   - Print a plain-language summary for humans and AI: what failed, why, the exact rerun command, and how to pass.
4. **Anti-bypass guard.** One PreToolUse script must block all of these:
   - `--no-verify`/`-n` and `git -c core.hooksPath=`.
   - `HK_SKIP*`, `LEFTHOOK=0`, `HUSKY=0`, `SKIP=`.
   - `git commit` through MCP tools.
   - Writes to hook, config and baseline files.
   - Install it once at user level so it covers every repo, including repos without the tool.
5. **Push-target branch condition.** Expose the pre-push remote ref (stdin of the git pre-push hook) to hk conditions, unless hk's pre-push context already provides it. That was not verified.

## Sources

- GitHub releases API: evilmartians/lefthook, pre-commit/pre-commit, j178/prek, typicode/husky, lint-staged/lint-staged, captainhook-git/captainhook, phpro/grumphp, oxsecurity/megalinter, qltysh/qlty, reviewdog/reviewdog, danger/danger-js, danger/danger, jdx/mise, go-task/task, jdx/hk, microsoft/sarif-sdk, nizos/tdd-guard, affaan-m/everything-claude-code, trunk-io/plugins
- npm: @betterer/cli, @trunkio/launcher, block-no-verify, @microsoft/sarif-multitool, eslint; PyPI: pre-commit
- hk: https://hk.jdx.dev/configuration.html, https://hk.jdx.dev/cli/agent/stop-hook.html, https://hk.jdx.dev/cli/agent/hooks.html, https://hk.jdx.dev/builtins.html
- lefthook: https://github.com/evilmartians/lefthook/blob/master/docs/configuration/only.md
- pre-commit: https://pre-commit.com/ (pre-push environment variables)
- prek: https://github.com/j178/prek
- qlty: https://docs.qlty.sh/cli/git-hooks.md, https://docs.qlty.sh/cli/commands/check.md, https://docs.qlty.sh/cli/developing-plugins.md, https://docs.qlty.sh/cli/qlty-toml.md, https://github.com/qltysh/qlty (LICENSE.md)
- Trunk: https://docs.trunk.io/changelog/2025-05-09-sunsetting-ci-analytics-and-code-quality-web-issue-browser, https://docs.trunk.io/check/configuration/hold-the-line
- MegaLinter: https://github.com/oxsecurity/megalinter (README)
- reviewdog: https://github.com/reviewdog/reviewdog (README)
- SARIF 2.1.0: https://docs.oasis-open.org/sarif/sarif/v2.1.0/errata01/os/sarif-v2.1.0-errata01-os-complete.html §3.27.24, §3.14.5
- GrumPHP: https://github.com/phpro/grumphp/tree/v2.x/doc
- CaptainHook: https://github.com/captainhook-git/captainhook/tree/main/src/Hook/Condition
- Claude Code hooks: https://code.claude.com/docs/en/hooks
- Agent bypass guide: https://pydevtools.com/handbook/how-to/how-to-stop-ai-agents-from-bypassing-pre-commit-hooks/
