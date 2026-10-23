---
type: plan
project: vault-quality-gates
slug: qg-guards-commit-push-only
status: in-progress
---

# Agent guards act only on commit and push

The Claude Code guards in `templates/claude-hooks/` deny an agent only what skips or weakens the
commit gate or the push gate. The stop hook is deleted. The recycling-api runner `in-server.sh`
stops refusing a local compose override, which `-f` already keeps out of the run. The kept rules
are in `vault/architecture/guard-agent-hooks.md`.

## Open work

| id | action | verification | status |
|---|---|---|---|
| P-1 | Operator deletes `templates/claude-hooks/guard-stop.sh` and `tests/unit/guard-stop.bats` on `fix/guards-commit-push-only` in `~/workspace/vault-quality-gates-override`: `git rm templates/claude-hooks/guard-stop.sh tests/unit/guard-stop.bats`. The live guard refuses an agent any command naming the file | `ls templates/claude-hooks/` lists no `guard-stop.sh` | operator |
| P-2 | Operator merges `fix/guards-commit-push-only` into `main` in `~/workspace/vault-quality-gates`; the user-level hooks run from the main worktree, so the new rules take effect only then | an agent runs `git worktree add ../qg-probe -b probe/x` from `~/workspace/vault-quality-gates` and it is not refused | operator |
| P-3 | Operator runs `qg hooks install --claude --user` from a terminal outside Claude Code, which drops the `Stop` entry for `guard-stop.sh` from `~/.claude/settings.json` | `qg hooks status --user` prints two `installed` lines; `grep -c guard-stop ~/.claude/settings.json` prints 0 | operator |
| P-4 | Commit recycling-api `quality/bin/in-server.sh` on `release/1.19.0` with `qg override --reason "in-server.sh: drop the redundant compose-override refusal"`, then `qg run push --ref refs/heads/release/1.19.0` in the background, then `git push` | the 9 release rows (pint, phpinsights ×4, phpstan, indication-checks, deps ×2) report measured values | operator |
| P-5 | Operator decides where the 19 commits on `main` that are not on `origin/main` go; 2 of them (`bb56155`, `66ecb6d`) are on no remote. An agent never pushes `main` | `git -C ~/workspace/vault-quality-gates rev-list --count origin/main..main` prints 0 | operator |

## Retired criteria

These checks verified rules that no longer exist and are deleted: `checks/qg-s6-SC-6.sh` (global
write denials, plugin checkout protection), `checks/qg-scope-SC-1.sh` … `checks/qg-scope-SC-5.sh`
(ungated scope, integrity class, stop hook). `checks/qg-s6-SC-4.sh`, `checks/qg-s6-SC-5.sh`,
`checks/qg-pp-SC-2.sh`, `checks/qg-s2-SC-4.sh` and `checks/qg-s2-SC-8.sh` name the current cases.

## Verification

- `./tests/run.sh tests/unit/` exits 0 in `~/workspace/vault-quality-gates-override`.
- `tests/unit/guard-claude-hooks.bats` holds the allowed commands an older guard refused
  (`git worktree add`, `git branch -r --contains`, `bash -n`, `python3 -I <script>`, `rm -rf` in a
  scratch folder, `git -C "$tree"`) and every denial in `vault/architecture/guard-agent-hooks.md`.
- In `~/workspace/recycling-api` with `docker-compose.override.yml` present,
  `bash quality/bin/in-server.sh "$PWD" - php -v` prints the PHP version.

## Failure modes and rollback

- An agent can edit the plugin checkout and `~/.claude/settings.json`. The commit gate of
  vault-quality-gates judges every commit there, and the user-level hooks load from the main
  worktree, so an edit takes effect only after the operator merges it.
- A command the Bash guard cannot parse runs unchecked; the repo's git hooks still judge its commit
  or push.
- Rollback: `git -C ~/workspace/vault-quality-gates revert -m 1 <merge commit>`, then
  `qg hooks install --claude --user` to restore the stop hook entry.
