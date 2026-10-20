---
type: architecture
project: vault-quality-gates
slug: guard-agent-hooks
status: current
tags: [quality, gates, contract, agent-hooks]
---

# The Claude Code guards: the three entries, their install, and what they deny

Three hooks in `templates/claude-hooks/` stop an agent from skipping, disabling or forging the
gate. They run in place from the plugin checkout by absolute path, never copied.

## The three entries

| entry | event and matcher | does |
|---|---|---|
| `guard-bash.sh` | `PreToolUse`, `Bash` | denies a command that skips, disables or forges the gate; rules in `guard_bash.py`, tokeniser in `shell_lexer.py` |
| `guard-edit.sh` | `PreToolUse`, `Edit\|Write\|MultiEdit\|NotebookEdit` | denies an edit to a git dir, a Claude settings file, a git config file, gate configuration, the plugin or a global write denial |
| `guard-stop.sh` | `Stop`, timeout 30 | blocks the end of a turn while a gated repo has commits on no remote |

An entry is one of the three when its command's file name is `guard-bash.sh`, `guard-edit.sh` or
`guard-stop.sh`. Install replaces every such entry, whatever its folder, and keeps every other
entry. Remove drops exactly those three. A settings file that is not valid JSON is left unchanged,
and the command exits 2. With several targets, install and remove check every target first.
At user level an entry counts as installed only when its command is exactly
`<main worktree>/templates/claude-hooks/<name>` under its event, and that file is executable.
`qg doctor` fails naming that path. Its repo-level duplicate warning matches by file name, in any folder.

| command | target |
|---|---|
| `qg hooks install --claude --user [--config-dir <dir>]...` | `~/.claude/settings.json` and each `<dir>/settings.json`, so every session in every repo runs the guards. The commands name the main worktree of the plugin. It also writes the machine tool-path file (`vault/architecture/guard-environment.md`). It refuses when the plugin checkout is a linked worktree |
| `qg hooks remove --claude --user [--config-dir <dir>]...` | the same files |
| `qg hooks status --user [--config-dir <dir>]...` | one line `installed\|absent <entry> <file>` per entry, for `~/.claude`, `~/.claude-factory` when it exists, and each `<dir>`; exit 0; allowed for an agent |
| `qg hooks install --claude`, `qg hooks remove --claude` | `<repo>/.claude/settings.json`; remove keeps the git hooks |

The `--user` forms run in `bin/qg` itself, because only `qg` holds the caller's `PATH`
(`QG_CALLER_PATH`). `guard.sh hooks install --claude --user` exits 2 naming the `qg` command.

## What the guards deny

**Plugin files.** Both hooks protect the main worktree of the checkout they run from. Any linked
worktree of the plugin stays editable, the one the hooks run from included. A git command other than
a read is denied when its work tree lies in the main worktree. The checked paths are the tracked cwd,
`-C`, `--work-tree`, `--git-dir`, an assigned or exported `GIT_WORK_TREE` or `GIT_DIR`,
`checkout-index --prefix` and the folder of `worktree add`, each resolved with `realpath`. The cwd
follows `cd`, `cd -` and the `pushd`/`popd` stack. A `GIT_DIR` or `GIT_WORK_TREE` value is checked
both against the cwd of its assignment and the cwd git runs in; `unset` drops it. After a `cd` to a
computed folder, a stack rotation or an unknown `OLDPWD`, a writing git command is denied.

**Launchers.** `script`, `exec -c`, `systemd-run`, `at`, `batch`, `screen`, `dbus-run-session`,
`busctl`, `systemctl` with `start`, `restart` or `run`, and the tmux subcommands that run a command
(`new-session`, `new-window`, `split-window`, `send-keys`, `respawn-*`, `run-shell`) are denied.
Each can start a command without the agent markers.

**The override's own check.** `lib/guard-override.sh` refuses when the hook or an ancestor holds
`CLAUDECODE` or `AI_AGENT` in `/proc/<pid>/environ`, or when one of those files cannot be read. The
walk stops at the user manager or init. It fails closed at a process on the hook's terminal whose
parent is init or the user manager, because that process was orphaned and lost the parent that may
have been the agent. The check covers only commands that stay in the agent's process tree; a command
a service manager starts falls outside it, which is why the launchers above are denied.

**Accepted, predates S6:** a git alias already set in a repo or global git config runs as git runs
it, unscanned. `guard-bash.sh` denies setting an alias, never one that already exists.

**Global write denials.** Both hooks deny a write or an edit under these paths, compared by the
spelled and the resolved path (`write_denials.py`):

- `~/.pub-cache`;
- any folder holding `bin/internal/engine.version` and `packages/flutter_tools`, a Flutter SDK;
- a direct child of `~/.cache` holding a `copydetect-*` folder;
- `~/.bashrc`, `~/.bash_profile`, `~/.bash_login`, `~/.profile`, `~/.zshrc`, `~/.zshenv`, `~/.zprofile`;
- every absolute `PATH` folder before `/usr/bin`, or every one when `PATH` has no `/usr/bin`;
- every folder in the machine tool-path file.

`guard-bash.sh` also matches these paths in interpreter code (`-c`, `-e`, heredocs, script files),
spelled with `~`, `$HOME`, `${HOME}` or absolutely, when the code writes a file or starts a program.
Code that only reads them passes, and a shebang line never counts. It also checks write targets: `tar -C`,
`--directory=`, `unzip -d`, `curl -o`, `--output`, `--output-dir`, `wget -O`, `--output-document`,
`-P`, `dd of=` and the folder of `git clone <url> <dir>`. A bare `cd` moves the checked cwd to `HOME`.

**Names always denied.** `guard-bash.sh` denies assigning, exporting, declaring or passing through
`env` any `BASH_FUNC_*` name and any name `env` sets that is no plain identifier. It denies `export -f`,
and `declare` or `typeset` with both `-f` and `-x`. It denies any change to `CLAUDECODE` or `AI_AGENT`.
`env` is checked for every word holding `=` before its program. `declare -f`, `declare -F` and
`declare +x -f` are allowed.

**Narrowed checks.** These deny only when the same input also names git, `.git`, a hook, `qg`,
`guard.sh` or the plugin; the input includes every script it runs or sources:

- assigning, exporting or declaring `BASH_ENV`, `SHELLOPTS`, `BASHOPTS`, `GIT_REPLACE_REF_BASE`,
  `GIT_NO_REPLACE_OBJECTS`, `GIT_ALTERNATE_OBJECT_DIRECTORIES`, `GIT_OBJECT_DIRECTORY`,
  `GIT_EXTERNAL_DIFF`, `LD_PRELOAD`, `LD_LIBRARY_PATH` or `LD_AUDIT`, or exporting a name that is
  no plain identifier, such as `export $(xargs < .env)`;
- interpreter code, inline or in a script file, matching `RISKY_CODE`;
- a word holding `claudecode` or `ai_agent`.

`RISKY_CODE` is advisory, because a script file the agent writes and runs later is never scanned.
Inline or heredoc code that starts a program (`exec*`, `subprocess`, `child_process`, `spawn`,
`os.system`, `popen`) and also changes the environment or opens a pty is always denied. It can
spell the program's name so that no text check sees it.

**Allowed.** `>&<digit>` and `>&-` duplicate or close a descriptor and are never write targets. An
installed program, whose real path is under `~/.claude/plugins/cache`, may name the plugin path; its
redirects and the commands chained to it are still checked.

## How the guards read scripts

`guard-bash.sh` reads every script a command runs or sources and scans it like the command. Two kinds
run unscanned: a committed, unmodified script under `guard_protected_paths`, and code installed under
`~/.claude/plugins/cache/`. Both hooks deny an agent any write or edit there, which is what makes
that code safe to run as installed. Every hook runs `python3 -I`, so a module planted in the cwd or
a `PYTHONPATH` never loads.

The `qg` subcommands `guard-bash.sh` lets an agent run are listed in `vault/architecture/qg-cli.md`.
