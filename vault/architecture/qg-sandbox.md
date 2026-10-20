---
type: architecture
project: vault-quality-gates
slug: qg-sandbox
status: current
tags: [quality, gates, drivers, sandbox, landlock, seccomp]
---

# The driver sandbox: what a tool started by the gate can write and open

Every tool a built-in driver runs through `qg_tool` or `qg_isolated`, and every repo driver's whole
`run`, starts through `qg_sandbox_run` in `lib/qg-sandbox.sh`. A `shell` row's command goes
through it too, with `QG_SANDBOX=0`. It runs `bin/qg-sandbox`, which needs no
privilege: Landlock limits writes, and a seccomp filter blocks Unix sockets. Reads and TCP stay open.
Each driver's `describe` fields `sandbox` and `writes` are defined in
`vault/architecture/qg-driver-contract.md`.

## Who decides

| input | set by | rule |
|---|---|---|
| `QG_SANDBOX` | `guard_run_driver`, from `describe` | only JSON `"sandbox": false` gives `0`; any other value, or an unreadable `describe`, gives `1` |
| `QG_SANDBOX_WRITES` | `guard_run_driver`, from `describe.writes` | folders relative to `QG_TREE`, space-separated |
| `QG_SANDBOX_SDK` | `qg_dart_env` | the `guard_flutter_root` SDK |
| repo driver | `guard_run_driver` | always sandboxed with `QG_OUT` writable; its `describe` is never read for this |

`qg_sandbox_run` reads these variables and never reads `describe`. `QG_SANDBOX` exactly `0` runs the
command unconfined; unset or any other value runs it sandboxed. `guard_run_driver` sets both names
for every driver it runs, so a caller's `QG_SANDBOX=0` never reaches one.

## The child process

| property | value |
|---|---|
| environment | only `HOME`, `TMPDIR` and `QG_PRIVATE` (one private 0700 folder), the engine's `PATH`, `LANG`, `LC_ALL`, `PUB_CACHE=<real home>/.pub-cache`, the contract's `QG_*` names; with `QG_SANDBOX_SDK`, also `FLUTTER_ROOT` and `FLUTTER_ALREADY_LOCKED=true` |
| session | its own, via `setsid`; its process group is killed after it exits |
| stdin | `/dev/null` |
| descriptors | none above 2 when sandboxed |
| output | descriptors 1 and 2 only, which the caller opened on files in `QG_OUT` |

The private folder is removed after every run. An unsandboxed run gets the same environment, session
and stdin.

## What a sandboxed tool may write

| path | right |
|---|---|
| `QG_PRIVATE`, `/dev/null` | every write right |
| each `QG_SANDBOX_WRITES` folder, and the report folder `qg_tool` adds | every write right |
| `QG_OUT` | only for a repo driver's whole run |
| the existing `<sdk>/bin/cache/*.stamp` and `<sdk>/bin/cache/lockfile` | write and truncate, with `QG_SANDBOX_SDK` |

Everything else refuses writes: the rest of the tree, `.git` in a main or linked worktree, `.claude`,
`.mcp.json`, `QG_OUT`, `QG_RUN_DIR`, the gate cache, the pub cache and the rest of the SDK.

**Constraint: a declared path stays inside the tree.** `qg_sandbox_run` refuses an absolute path, one
that leaves the tree after normalising, one naming `.git`, the tree itself, and any path under
`node_modules` but `node_modules/.vite` and `node_modules/.cache`. It creates a missing folder one
component at a time and refuses a component that is a symlink. `bin/qg-sandbox` opens each grant with
`O_PATH | O_NOFOLLOW` and refuses one whose real path differs from the given path.

## What a sandboxed tool may not open

| call | result |
|---|---|
| `socket` with family `AF_UNIX`, high bits ignored | `EACCES`; `socketpair` still works |
| any call through a foreign architecture entry, such as the 32-bit `int 0x80` | the process is killed |
| a system call number at or above `0x40000000` (x32), `io_uring_setup` | `ENOSYS` |
| a signal to a process outside the sandbox, an abstract Unix socket outside it | refused by Landlock scoping |

## Failure modes

| case | result |
|---|---|
| a declared path refused | the row is `status: error` naming `qg-sandbox` and the path; the tool never runs |
| Landlock ABI below 6, an unsupported architecture, a refused grant | `bin/qg-sandbox` exits 125 without the armed marker; the row is `status: error` naming `qg-sandbox` |
| the tool exits with a code the driver does not accept | the error adds the first refused-write line of the tool's stderr |

A sandboxed run appends `sandbox: armed` as the last line of `<git-common-dir>/qg-last/<id>/output.txt`.

**Rollback:** set one built-in driver's `describe` to `"sandbox": false`; its tools then run
unconfined under the same child environment.

## Dart and Flutter

`<sdk>/bin/flutter` writes SDK files on every call, so `qg_dart_env` writes a `flutter` shim in
`QG_RUN_DIR` (or `QG_CACHE` outside the engine) and puts its folder first on `PATH`. The shim runs
`<sdk>/bin/cache/dart-sdk/bin/dart --disable-dart-dev --packages=<sdk>/packages/flutter_tools/.dart_tool/package_config.json <sdk>/bin/cache/flutter_tools.snapshot`.
`QG_FLUTTER` names the shim.

## Accepted limits

- A tool can read every file the operator can, and can open TCP connections.
- A suite may rewrite the SDK stamps; the next unsandboxed `flutter` command then downloads that
  artifact again.
- `shell` rows and the drivers marked `"sandbox": false` run unconfined under the child environment,
  because they need Docker or write the gate cache. `doc-lint` is one of them: it launches the
  framework's own linter itself.

## Runners

**Constraint: a runner runs outside the sandbox; only the tool it starts is confined.** A runner is
read from the config revision, so the commit under test cannot change it. `qg_tool` calls it under
the child environment, in its own session, as `<runner> <tree> <cache> <prefix> <argv>`. The prefix
is `/usr/bin/env -i <child environment> bin/qg-sandbox --write ... --armed <marker> --keep-session --`,
which `qg_sandbox_argv` builds after the declared-path checks. The runner may write the tree first,
as `quality/bin/in-node.sh` links `node_modules` and copies `.nuxt` in commit mode, then runs the
prefix and argv. A missing armed marker afterwards is `status: error`, as for a direct tool. With
`QG_SANDBOX=0` the runner gets `<runner> <tree> <cache> <argv>`, so a container runner passes the
argv on unchanged.
