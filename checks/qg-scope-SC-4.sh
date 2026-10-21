#!/usr/bin/env bash
# qg-guard-scope SC-4 — in a gated repo every guard case that existed before the scope change still
# passes, including the cases the run-time value rule turned into allows.
#
# Exit 0 pass, 1 fail, 2 could not run.
set -uo pipefail
exec < /dev/null
. "$(dirname "${BASH_SOURCE[0]}")/_qg-cases.sh"
qg_cases \
    guard-claude-hooks.bats \
    "a denial exits 2 and names the reason on stderr" \
    "unreadable stdin fails closed" \
    "python3 missing fails closed" \
    "commit -n in any short-flag cluster is denied; -n elsewhere is not" \
    "--no-verify is denied from the --no-ver prefix on every commit-creating command" \
    "global options before the subcommand are skipped, and -c keys are checked" \
    "git config writes to core.hooksPath, alias.* or include are denied; reads pass" \
    "config-redirecting and override variables are denied; look-alike names pass" \
    "plumbing, gh api writes and agent-marker removal are denied" \
    "file writers and redirects naming gate state or the plugin are denied" \
    "bash -c, sh -c, eval, substitutions and every chained segment are re-scanned" \
    "quoted -m text and heredoc message bodies are never scanned" \
    "read-only commands always pass" \
    "gate-state names deny every command that is not a read; guard.sh runs only verify, report and hooks status" \
    "push is denied when its flags are computed, forced or mirrored, or when it runs outside this repository" \
    "interpreters, find, awk, piped shells and executed script files are scanned or denied" \
    "wrappers, computed command words and" \
    "a value computed at run time is allowed until the command names git, a hook, qg or the plugin" \
    "reads, copies from the plugin, sed scripts and repositories under /tmp are not false denials" \
    "guard-edit denies .git paths, settings, git config and the plugin; source edits pass" \
    "guard-edit denies a linked worktree's .git file" \
    "guard-edit denies the git common dir reached through a symlink" \
    "a committed, unmodified script under a protected path runs even when it names gate state" \
    "expansion holding quotes and nested expansions is one word, and what it hides is still scanned" \
    "installed plugin code runs unscanned, and no agent may write or edit it" \
    "upstream retargeting and husky hook files are denied; a plain branch delete and push -u pass" \
    "an agent write into guard-pass/push is denied" \
    "an agent cannot set PATH, HOME or XDG_CONFIG_HOME for qg" \
    "BASH_FUNC_ assignments are denied beside any command and BASH_ENV, SHELLOPTS and BASHOPTS beside git, qg or a hook" \
    "GIT_REPLACE_REF_BASE, GIT_NO_REPLACE_OBJECTS, GIT_ALTERNATE_OBJECT_DIRECTORIES, GIT_OBJECT_DIRECTORY and GIT_EXTERNAL_DIFF are denied" \
    "env with a name that is no plain identifier is denied and the command after it is still checked" \
    "export -f, declare -fx and typeset -fx are denied" \
    "names that only resemble a denied name, and declare without both -f and -x, are allowed" \
    "writes and edits under .pub-cache, a Flutter SDK or a copydetect venv folder are denied" \
    "writes and edits to a shell startup file are denied" \
    "writes under a PATH folder before /usr/bin or a tool-path folder are denied" \
    "a denied root named inside python code or as a tar, unzip, curl, wget or git clone target is denied" \
    "a planted json.py in the cwd does not change any hook's verdict" \
    "a file in a worktree of the plugin stays editable while the hook checkout is denied" \
    "in a gated repo with no quality folder an fd duplication, python backticks and an installed program naming the plugin path are allowed" \
    "cd with no argument moves the checked cwd to HOME before a startup-file write" \
    "inline code or a cleared agent marker beside git, .git, a hook path or the plugin is still denied" \
    "a program naming the plugin path is allowed only when its real path is installed, and never for its redirects or chained commands" \
    "python one-liners using re.compile or os.path and a file name holding ai_agent are allowed" \
    "in a gated repo with no quality folder every git, qg and write denial still holds" \
    "assigning LD_PRELOAD, LD_LIBRARY_PATH or LD_AUDIT is denied" \
    "loader and shell names, and computed export names, are allowed in a command that names no git, hook, qg or plugin" \
    "git cannot change the protected main worktree through a relative path, a work tree, a prefix or a tracked cwd" \
    "launchers that start a command without the agent markers are denied" \
    "inline code that starts a program with a changed environment or a pty is denied, however it spells the program" \
    "interpreter code that only reads a denied root is allowed" \
    "qg baseline and qg override pass only while a live grant names them; qg grant itself never passes"
