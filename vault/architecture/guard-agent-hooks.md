---
type: architecture
project: vault-quality-gates
slug: guard-agent-hooks
status: current
tags: [quality, gates, contract, agent-hooks]
---

# The Claude Code guards: the two entries, their install, and what they deny

Two hooks in `templates/claude-hooks/` deny an agent what skips or weakens the commit gate or the
push gate. Every other command and edit runs unchecked; the repo's own `pre-commit` and `pre-push`
hooks still judge each commit and push. The hooks run in place from the plugin checkout by absolute
path, never copied.

## The two entries

| entry | event and matcher | does |
|---|---|---|
| `guard-bash.sh` | `PreToolUse`, `Bash` | denies a command in `## What guard-bash denies`; rules in `guard_bash.py`, tokeniser in `shell_lexer.py` |
| `guard-edit.sh` | `PreToolUse`, `Edit\|Write\|MultiEdit\|NotebookEdit` | denies an edit in `## What guard-edit denies` |

An entry is one of the two when its command's file name is `guard-bash.sh` or `guard-edit.sh`.
Install replaces every such entry, whatever its folder, keeps every other entry, and drops a `Stop`
entry for `guard-stop.sh` that an older install wrote. Remove drops exactly those. A settings file
that is not valid JSON is left unchanged, and the command exits 2. With several targets, install and
remove check every target first. At user level an entry counts as installed only when its command is
exactly `<main worktree>/templates/claude-hooks/<name>` under `PreToolUse`, and that file is
executable. `qg doctor` fails naming that path. Its repo-level duplicate warning matches by file
name, in any folder.

| command | target |
|---|---|
| `qg hooks install --claude --user [--config-dir <dir>]...` | `~/.claude/settings.json` and each `<dir>/settings.json`, so every session in every repo runs the guards. The commands name the main worktree of the plugin. It also writes the machine tool-path file (`vault/architecture/guard-environment.md`). It refuses when the plugin checkout is a linked worktree |
| `qg hooks remove --claude --user [--config-dir <dir>]...` | the same files |
| `qg hooks status --user [--config-dir <dir>]...` | one line `installed\|absent <entry> <file>` per entry, for `~/.claude`, `~/.claude-factory` when it exists, and each `<dir>`; exit 0; allowed for an agent |
| `qg hooks install --claude`, `qg hooks remove --claude` | `<repo>/.claude/settings.json`; remove keeps the git hooks |

The `--user` forms run in `bin/qg` itself, because only `qg` holds the caller's `PATH`
(`QG_CALLER_PATH`). `guard.sh hooks install --claude --user` exits 2 naming the `qg` command.

## Scope

The git, gate-variable and gate-file rules bind only in a gated repo, except the two push rules
marked *every repo* below.
`templates/claude-hooks/gated.py` decides it from the filesystem alone. A repo is gated when
`<common dir>/hooks/pre-commit` or `pre-push` holds `# vault-guard-start`. It is also gated when its
`.git` file, git dir or hooks folder cannot be read, or its config sets `hookspath`. The folder a
rule checks is the cwd after each literal `cd`, a `git -C` target, or the folder of a write target.
A write target resolves against that cwd with `os.path.realpath`, so `cd .git && printf x > guard-pass/k`
is a write inside the git dir. The `qg` and `guard.sh` rules bind in every repo.

A deny names its next step. A push rule names the push to make instead, or the operator command it
needs; every other git rule tells the agent to fix what the commit gate reports.

A command the hook cannot parse runs unchecked (`guard-bash: not checked …` on stderr). A computed
`git -C "$x"`, a script file, and code run through an interpreter are not read; the repo's git hooks
judge what they commit or push. A GitHub API write from a script reaches no hook; only the
operator's merge flow catches it.

## What guard-bash denies

- `git commit -n`, `-n` inside a short-flag cluster, and `--no-verify`;
- `--no-verify` on `merge`, `push`, `am`, `rebase`, `cherry-pick`, `revert` and `pull`;
- `git push` with `--force*`, `-f`, a `+` refspec, `--mirror`, `--delete`, `-d`, `--prune`,
  `-o`/`--push-option`, `--receive-pack` or `--exec`;
- `git push` whose target branch is `master`, `main`, `develop` or `development`, because a push
  there deploys. A bare `git push` targets the branch `@{push}` names, else the current branch;
  `HEAD` targets the current branch;
- `git push` whose target is a `hotfix/*` branch while no live operator grant names `hotfix`. The
  deny names `qg grant --agent hotfix`. `pre-push` refuses the same push by its real remote ref
  (`vault/architecture/guard-push-pass.md` `## The hotfix refusal`), so a reroute this rule misses
  is still refused;
- `git push` that reroutes past the branch rules: `--all`, `--branches`, a refspec holding `*`, a
  bare `:` refspec, and a target ref outside `refs/heads/`;
- `git -c` or `--config-env` with `remote.*.push`, `remote.*.mirror`, `push.default` or
  `branch.*.merge`, and `git config` that sets one of them (reads with `--get`, `get` or `--list`
  pass);
- *every repo*: `git push` from a checkout whose `quality/checks.tsv` at `HEAD` holds a push row
  (a v2 `on` cell with a push token, a v1 `scope` of `release` or `both`) while the `pre-push` git
  runs (after `core.hooksPath`) lacks `# vault-guard-start`; the deny names
  `qg hooks install` for the operator. `push_unguarded` in `gated.py` decides it;
- `git config` that sets or unsets `core.hooksPath` or a `hook.*` key, and `git -c` with one;
- assigning, exporting or passing through `env` `HUSKY=0`, any `GUARD_*` or `QG_*` name, or
  `GIT_CONFIG_COUNT`, `GIT_CONFIG_KEY_*`, `GIT_CONFIG_VALUE_*`, `GIT_CONFIG_PARAMETERS`,
  `GIT_CONFIG_GLOBAL`, `GIT_CONFIG_SYSTEM` or `GIT_CONFIG_NOSYSTEM`;
- a redirect or a `rm`, `mv`, `cp`, `ln`, `chmod`, `touch`, `tee`, `truncate`, `install`, `mkdir`,
  `rsync` or `dd of=` target inside a `.git` folder or a git dir, naming `qg-override`, inside
  `.husky/`, or under `quality/config`, `quality/drivers`, `quality/baseline.tsv` or
  `quality/checks.tsv`, by its text or by its resolved path;
- *every repo*: `gh api` with `-X`/`--method` `POST`, `PUT`, `PATCH` or `DELETE`, or with
  `-f`/`-F`/`--field`/`--raw-field`/`--input` and no `-X GET`, on a path holding `git/refs`,
  `git/commits`, `contents`, `merges` or `pulls/<n>/merge`. The target repo on GitHub cannot be read
  from the cwd, so the rule binds everywhere. `gh api` reads pass;
- `qg` subcommands other than the reads in `vault/architecture/qg-cli.md`; `qg baseline` and
  `qg override` pass while the operator grant names them (`## The agent grant` there), and so does
  a `hotfix/*` push target;
- `guard.sh` subcommands other than `verify <range>`, `report` and `hooks status`.

`bash -c`, `sh -c`, `zsh -c` and `dash -c` text is read like the command. `env`, `command`, `nice`,
`nohup`, `time`, `timeout`, `sudo`, `exec`, `builtin`, `stdbuf`, `ionice` and `setsid` are skipped
with their options, and so are `export`, `declare`, `typeset`, `readonly` and `local`.

After any of those, and after `script`, `systemd-run`, `tmux`, `screen`, `su`, `runuser`, `wsl`,
`wsl.exe` and `flock`, each argument that holds a space is read as a command line, and so are the
trailing words from the first one that is `qg`, `guard.sh`, `git`, a shell, a wrapper or an
assignment. `qg override` inside `script -qec "…"`, `systemd-run --user qg …` or
`wsl.exe -e env QG_SKIP_REASON=x git commit` is therefore judged as if run directly. These wrappers
detach a command or give it a terminal, which is how an agent would reach the human check in
`lib/guard-override.sh`. `ssh` is not one of them: its command runs on another machine. A command
that needs more than 256 inner reads is denied.

## What guard-edit denies

In a gated repo, an edit to a path inside a `.git` folder or the git dir, `.husky/` or `.huskyrc`,
`quality/config`, `quality/drivers/`, `quality/baseline.tsv` or `quality/checks.tsv`. Every hook
runs `python3 -I`, so a module planted in the cwd or a `PYTHONPATH` never loads.
