---
type: architecture
project: vault-quality-gates
slug: qg-sandbox
status: current
tags: [quality, gates, drivers, sandbox, landlock, seccomp]
---

# The driver sandbox: what a tool started by the gate can write and open

Every tool a built-in driver runs through `qg_tool` or `qg_isolated`, every repo driver's whole `run`,
every `shell` row's command, and every runner start through `qg_sandbox_run` in `lib/qg-sandbox.sh`.
Sandboxed, it runs `bin/qg-sandbox`, which needs no privilege: Landlock limits writes, and a seccomp
filter blocks Unix sockets, ownership and extended-attribute changes. Each driver's `describe` fields
`sandbox` and `writes` are defined in `vault/architecture/qg-driver-contract.md`.

## Who decides

| input | set by | rule |
|---|---|---|
| `QG_SANDBOX` | `guard_run_driver`, from `describe` | only JSON `"sandbox": false` gives `0`; any other value, or an unreadable `describe`, gives `1` |
| `QG_SANDBOX_WRITES` | `guard_run_driver`, from `describe.writes` | folders relative to `QG_TREE`, space-separated |
| `QG_SANDBOX_SDK` | `qg_dart_env` | the `guard_flutter_root` SDK |
| `QG_SANDBOX_LOG` | `guard_run_driver` | an engine-owned file beside `QG_OUT`, never inside it, that gets `sandbox: armed` |
| repo driver | `guard_run_driver` | always sandboxed with `QG_OUT` writable; its `describe` is never read for this |
| `shell` row, `checkstyle` runner, `doc-lint` linter | their callers | always `QG_SANDBOX=0` |

`qg_sandbox_run` reads these variables and never reads `describe`. `qg_sandbox_argv` turns them into
`QG_SANDBOX_MODE`, `sandboxed` or `open`, which every later step tests. `guard_run_driver` sets
`QG_SANDBOX` and `QG_SANDBOX_WRITES` for every driver it runs, so a caller's `QG_SANDBOX=0` never
reaches one.

## The child environment

This is the only list of the names a tool sees; the driver contract links here.

| name | sandboxed | open (`QG_SANDBOX=0`) |
|---|---|---|
| `HOME` | `QG_PRIVATE` | the real `HOME`, because pnpm and Docker need their caches |
| `TMPDIR`, `QG_PRIVATE` | a private 0700 folder, removed after the run | the same |
| `PATH` | the engine's `PATH` | the same |
| `LANG`, `LC_ALL` | the engine's, when set | the same |
| `PUB_CACHE` | `<real home>/.pub-cache` | the same |
| `FLUTTER_ROOT`, `FLUTTER_ALREADY_LOCKED=true` | only with `QG_SANDBOX_SDK` | the same |
| `QG_ARGS`, `QG_OUT`, `QG_ROW`, `QG_BASE`, `QG_FILES`, `QG_BASES`, `QG_TARGET`, `QG_REPO`, `QG_TREE`, `QG_CACHE`, `QG_RUNNER`, `QG_RUN_DIR`, `QG_CONFIG_REV` | each one the caller has set | the same |

Both modes give the command its own session, stdin from `/dev/null`, and a kill of its process group
after it exits. Sandboxed, it also holds no descriptor above 2, and `bin/qg-sandbox` stays as a child
subreaper: when the tool exits, it kills every descendant left, one that started its own session
included. The tool runs in a nested Landlock domain that holds only the signal and abstract-socket
scopes, so it cannot signal or ptrace that parent to escape the kill. That domain also grants
`REFER` on `/`, because Landlock refuses a move across folders in any domain that does not, and pub
moves its precompiled snapshots that way; the outer domain still decides every write.
Output leaves only through descriptors 1 and 2, which the caller opened on files in `QG_OUT`.

## What a sandboxed tool may write

| path | right |
|---|---|
| `QG_PRIVATE`, `/dev/null` | every write right |
| each `QG_SANDBOX_WRITES` folder, and the report folder `qg_tool` adds | every write right |
| `QG_OUT` | only for a repo driver's whole run |
| the existing `<sdk>/bin/cache/*.stamp` and `<sdk>/bin/cache/lockfile` | write and truncate, with `QG_SANDBOX_SDK` |

Everything else refuses writes: the rest of the tree, `.git` in a main or linked worktree, `.claude`,
`.mcp.json`, `QG_OUT`, `QG_RUN_DIR`, the gate cache, the pub cache and the rest of the SDK.

**Constraint: a declared path is a folder inside the tree.** `qg_sandbox_run` refuses an absolute
path, one that leaves the tree after normalising, one naming `.git`, the tree itself, and any path
under `node_modules` but `node_modules/.vite` and `node_modules/.cache`. Without a runner it creates
a missing folder one component at a time, and refuses a component that is a symlink and a path that
is not a folder. `bin/qg-sandbox` opens each grant with `O_PATH | O_NOFOLLOW`. It refuses one whose
real path differs from the given path, and a file grant with more than one hard link.

## What a sandboxed tool may not do

| call | result |
|---|---|
| `socket` with family `AF_UNIX`, high bits ignored | `EACCES` |
| `socketpair` of any type but `SOCK_STREAM`, after masking `SOCK_CLOEXEC` and `SOCK_NONBLOCK` | `EACCES`; a datagram pair could reach named sockets such as the journal |
| `chown`, `fchown`, `lchown`, `fchownat`; `file_setattr`; `setxattr`, `removexattr` and their `l`, `f` and `at` forms | `EPERM` |
| any call through a foreign architecture entry, such as the 32-bit `int 0x80` | the process is killed |
| a system call number at or above `0x40000000` (x32), `io_uring_setup` | `ENOSYS` |
| a signal to a process outside the sandbox, an abstract Unix socket outside it | refused by Landlock scoping |

## Runners

**Constraint: a runner runs outside the sandbox; only the tool it starts is confined.** A runner is
read from the config revision, so the commit under test cannot change it. `qg_tool` calls it under
the child environment, in its own session, as `<runner> <tree> <cache> <prefix> <argv>`. The prefix
is `/usr/bin/env -i <child environment> bin/qg-sandbox --tree <tree> --declared ... --armed <marker> --keep-session --`.
`qg_sandbox_argv` checks each declared path but creates none, because the runner prepares the tree.
When the sandbox arms, `bin/qg-sandbox` creates each missing component of a declared folder, one at
a time with `O_NOFOLLOW`, and grants it. It skips, with one stderr line, one reached through a
symlink or not a folder, such as `node_modules/.cache` under the `node_modules` link `in-node.sh` makes.
A missing armed marker afterwards is `status: error`, as for a direct tool. For a runner row,
`sandbox: armed` means a `qg-sandbox` armed under the runner: the runner is trusted config-revision
code and could write the marker itself. With `QG_SANDBOX=0` the
runner gets `<runner> <tree> <cache> <argv>`, so a container runner passes the argv on unchanged.

**Constraint: a runner's stdout carries only the tool's output.** `eslint` and `flutter-test` read
their report from stdout; a line the runner prints there corrupts it. Print progress on stderr.

**Constraint: a runner removes a granted folder before it copies into it.** A folder that exists when
the sandbox arms is writable with every right, symlink creation included. `in-node.sh` deletes the
tree's `.nuxt` before it copies the main checkout's.

## Launches outside `qg_sandbox_run`

| launch | where | reason |
|---|---|---|
| `dart pub get --offline --enforce-lockfile` | `qg_dart_packages` in `lib/qg-dart.sh` | it resolves packages into the pub cache and runs no code from the tree |
| the `git` calls of the tool-path reader | `lib/qg-toolpath.sh` | the engine's own read of the machine tool-path file, before any row runs |
| the Docker containers of recycling-api's in-tree runners | `quality/bin/in-tree.sh`, `in-server.sh` | the runner itself starts open; the container it starts mounts the tree read-write and needs the Docker socket |

## Failure modes

| case | result |
|---|---|
| a declared path refused | the row is `status: error` naming `qg-sandbox` and the path; the tool never runs |
| Landlock ABI below 6, an unsupported architecture, a refused grant | `bin/qg-sandbox` exits 125 without the armed marker; the row is `status: error` naming `qg-sandbox` |
| the tool exits with a code the driver does not accept | the error adds the first refused-write line of the tool's stderr |

A sandboxed run appends `sandbox: armed` as the last line of `<git-common-dir>/qg-last/<id>/output.txt`.
The engine reads it from `QG_SANDBOX_LOG` and never follows a symlink there.

**Rollback:** set one built-in driver's `describe` to `"sandbox": false`; its tools then run
unconfined under the same child environment.

## Dart and Flutter

`<sdk>/bin/flutter` writes SDK files on every call, so `qg_dart_env` writes a `flutter` shim in
`QG_RUN_DIR` (or `QG_CACHE` outside the engine) and puts its folder first on `PATH`. The shim runs
`<sdk>/bin/cache/dart-sdk/bin/dart --disable-dart-dev --packages=<sdk>/packages/flutter_tools/.dart_tool/package_config.json <sdk>/bin/cache/flutter_tools.snapshot`.
`QG_FLUTTER` names the shim.

## Accepted limits

- A tool can read every file the operator can, and can open TCP connections.
- A tool can `chmod` and `utime` any file it can reach, and set file flags with the
  `FS_IOC_SETFLAGS` and `FS_IOC_FSSETXATTR` ioctls: Landlock handles none of these rights.
- A suite may rewrite the SDK stamps; the next unsandboxed `flutter` command then downloads that
  artifact again.
- `shell` rows, runners and the drivers marked `"sandbox": false` run open under the child
  environment, because they need Docker or write the gate cache. `doc-lint` is one of them: its
  linter is the framework's own code.
