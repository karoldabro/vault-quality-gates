---
type: architecture
project: vault-quality-gates
slug: guard-environment
status: current
tags: [quality, gates, contract, environment]
---

# The clean environment every gate entry starts from, and the machine tool-path file

No caller variable, exported function or planted program changes a gate verdict. Every file in
`templates/git-hooks/`, `bin/guard.sh` and `bin/qg` starts `#!/bin/bash -p` and calls
`qg_clean_env` from `lib/qg-clean-env.sh` first. The gate runs on Linux only: the check reads
`/proc/self/environ`, and an entry exits 2 when that file is unreadable.

## The restart

`bash -p` reads no `BASH_ENV` and imports no function, but it passes both on to its children.
`qg_clean_env` therefore reads every name in `/proc/self/environ`, which also lists names that are
no plain identifier, such as `BASH_FUNC_git%%`. When one name is outside the kept list below, the
entry re-executes itself as `/usr/bin/env -i <kept names> PATH=<clean PATH> QG_CLEAN_ENV=1 /bin/bash -p <script>`.
Stdin, the working directory and the arguments pass through, so `pre-push` still reads every ref line.

| kept name | entry |
|---|---|
| `HOME`, `USER`, `LOGNAME`, `LANG`, `LC_ALL`, `LC_CTYPE`, `TERM`, `SSH_AUTH_SOCK`, `XDG_RUNTIME_DIR`, `DISPLAY` | every entry |
| `GIT_DIR`, `GIT_INDEX_FILE`, `GIT_WORK_TREE`, `GIT_PREFIX`, `GIT_AUTHOR_*`, `GIT_COMMITTER_*` (name, email, date), `GIT_REFLOG_ACTION`, `GIT_PUSH_OPTION_COUNT`, `GIT_PUSH_OPTION_<n>`, `GITHEAD_<sha>` (the merged heads `pre-merge-commit` reads) | every entry |
| `CLAUDECODE`, `AI_AGENT` | every entry |
| `HTTP_PROXY`, `HTTPS_PROXY`, `NO_PROXY` and their lowercase forms, `SSL_CERT_FILE`, `SSL_CERT_DIR`, `NODE_EXTRA_CA_CERTS` | every entry |
| `QG_SKIP_REASON` | the git hook templates |
| `GUARD_CONFIG_REV` (the agent factory's config pin), `GUARD_SHA`, `GUARD_BASE` (the commit `pre-push` and `qg` name), `GIT_NO_REPLACE_OBJECTS` | `bin/guard.sh` |
| `VAULT_FRAMEWORK_PATH` (the doc-lint `qg init` names) | `bin/qg` |

`PWD`, `OLDPWD`, `SHLVL` and `_` never trigger the restart, nor does a `PATH` equal to the clean
`PATH`. An entry restarts at most once: a process that carries `QG_CLEAN_ENV` and still holds another
name exits 2 naming it, so a forged `QG_CLEAN_ENV` can only stop the entry.

`bin/qg` keeps the caller's `PATH` in the unexported variable `QG_CALLER_PATH`, which only
`hooks install --claude --user` reads. The restart passes it as the argument `--qg-caller-path=<PATH>`,
read only when `QG_CLEAN_ENV` is set. An exported `QG_CALLER_PATH` is an unkept name, so it never
reaches `qg`.

After the start, `bin/guard.sh` and `bin/qg` export `GIT_NO_REPLACE_OBJECTS=1` before they read any
config revision, so a replace ref cannot swap the commit whose configuration judges the run.

**Dropped names.** Every other name is dropped, among them `NODE_OPTIONS`, `PYTHONPATH`,
`LD_PRELOAD`, `BASH_ENV`, `GIT_CONFIG_*`, `GIT_EXEC_PATH`, `GIT_EDITOR`, `XDG_CONFIG_HOME`,
`PNPM_HOME`, `COMPOSER_HOME`, `FLUTTER_ROOT`, `PUB_CACHE`, `JAVA_HOME` and every `GUARD_*` and `QG_*`
name the list above does not keep.

**Failure mode:** a tool a row needs that lives outside the system folders and the tool-path file
is not found, and the row reports unmeasurable. A variable a row or a repo runner needs that is
not kept, such as `COMPOSER_HOME`, does not reach it either.

## The machine tool-path file

The clean `PATH` is `/usr/local/bin:/usr/bin:/bin` followed by the valid entries of
`<git-common-dir of the plugin checkout>/qg-tool-path`. That is the main worktree's `.git`, which
both agent guards deny writing. `lib/qg-toolpath.sh` reads it before the restart, calling only
builtins and git under `env -i`.

| rule | value |
|---|---|
| writer | `qg hooks install --claude --user`, from `QG_CALLER_PATH`: the folder of the first `pnpm`, `node`, `php`, `composer`, `docker` and `hugo` found, in that order, without duplicates |
| format | one absolute folder per line; symlinks resolved; a trailing `/` dropped; a duplicate counts once |
| a bad entry | relative, empty, missing, not a folder, or inside a git work tree (`git -C <dir> rev-parse --show-toplevel` succeeds): dropped from `PATH` |
| absent | `PATH` is the system folders only |
| readers | `qg_tool_path_entries` prints the valid folders; `qg_tool_path_bad` prints `<entry>\t<reason>` per bad one; `qg_tool_path_file` prints the path. `qg doctor` fails on an absent file or a bad entry |
