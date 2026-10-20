---
type: architecture
project: vault
slug: guard-commit-gate
status: current
tags: [quality, gates, contract]
---

# The commit gate — what `guard.sh commit` and `verify` measure, and the hooks around them

The commit gate refuses a commit that adds a violation, measured on exactly the tree being committed.
The file formats, the substitution tokens and the parsers it uses are in
`vault/architecture/guard-file-formats.md`.

## What the gate measures

`bin/guard.sh commit` measures the index git is about to commit, honouring `GIT_INDEX_FILE`, so
`git commit -a` and `git commit <path>` are measured on the index git builds for them.
`bin/guard.sh verify <range>` measures each commit `git rev-list <range>` lists against its own
parents, and writes its pass record when it passes.

**Configuration comes from `HEAD`.** Both subcommands read `quality/checks.tsv`, `quality/rules.tsv`,
`quality/baseline.tsv`, the gate keys and any repo driver with `git show HEAD:<path>`, never from the working
tree, so an edit cannot loosen the gate that judges it. A commit whose first parent has no
`quality/rules.tsv` sits on a branch that predates the gate: it is not gated, exits 0 and says so on
stderr. The decision reads the judged commit's parent, never `HEAD`, so `verify` run from an old
checkout cannot pass a commit whose parent carries the gate; a first commit is always gated. A `HEAD` that
has `quality/rules.tsv` but no `quality/checks.tsv` is exit 2 naming the file. A first commit, with no `HEAD`, reads them from the
index. A commit that changes the gate configuration is measured by the old configuration.

**Bases.** The parents of the commit being made: `HEAD`, every `MERGE_HEAD` line, and every
`GITHEAD_<sha>` variable `git merge` exports to `pre-merge-commit`, which runs before `MERGE_HEAD`
exists. A first commit has the empty tree. Diff-based helpers count a line or entry only when it is
new against every base, so a merge never re-judges what an upstream parent already committed.

**The measured tree.** A tree row names `{{tree}}` or `{{cache}}` in its `args`, command or artifact,
or runs a driver whose `describe` says `needs_tree: true`. When one runs, the gate takes an exclusive lock on `<git-common-dir>/guard-tree.lock`, waiting
`GUARD_LOCK_WAIT` seconds (default 120), then syncs `<git-common-dir>/guard-tree` to the target tree
with the private index `guard-tree.index` (`read-tree -u --reset`, then `clean -fdx`). A missing or
broken private index wipes the directory and rebuilds it, so a deleted file never survives. A held
lock or a failed sync makes every tree row unmeasurable. The lock is held until the refusal has read
the reports inside the tree, so a second commit cannot overwrite them first. Every path resolves through the git common
dir, so a linked worktree measures its own index into the shared directory, one commit at a time.

**Gate keys** come from `quality/config`, else from `VAULT.md`, never both
(`vault/architecture/guard-file-formats.md`). Two keys hold space-separated path prefixes. A prefix
matches a whole path or a directory boundary: `quality` matches `quality/x`, never `quality-reports/x`.

| key | effect |
|---|---|
| `guard_commit_paths` | tree rows run only when a changed path matches; otherwise they report `skipped`. Absent or empty gates every path |
| `guard_protected_paths` | the paths `bin/guard-protected-paths.sh` counts |

**Helpers for commit rows.** Each prints one integer, takes `--bases "<sha>..."` (default: the bases
above) and `--target <commit>|:index` (default `:index`), prints the counted items instead under
`GUARD_LIST=1`, and is exit 2 on bad usage or an unreadable input. Rename detection runs at 30%
similarity, so a moved and rewritten file keeps its unchanged lines and entries out of the count.

| helper | counts |
|---|---|
| `bin/guard-added-lines.sh --checkstyle <file>` | checkstyle errors on added lines; a leading `/app/` is stripped from report paths |
| `bin/guard-added-lines.sh [--ext <ext>] [--exclude <regex>]... --grep <regex>` | added lines matching the extended regex, in files ending `.<ext>` (default `php`) whose path matches no `--exclude` extended regex; with `php`, also outside `tests/PHPStan/Rules/Fixtures/`. It runs under gawk and mawk, so write classes as POSIX brackets (`[[:space:]]`), never `\s` |
| `bin/guard-baseline-growth.sh [--phpstan <neon>] [--phpmd <xml>]` | baseline entries that grew: new, a higher count, or a higher accepted cognitive-complexity score |
| `bin/guard-protected-paths.sh` | paths under `guard_protected_paths` that differ from every base |

A line is added when it is new against every base; a moved line is added; a line that only gains the
missing final newline is not. A PHPStan baseline entry is (path, identifier, message) with the
complexity score removed from the message; a PHPMD entry is (file, rule, method). A removed or
lowered entry counts 0 and never offsets a new one. A base without the baseline file counts 0.
A `'''` multi-line message is keyed by its whole text. A complexity message holds a number or
the ratchet's regex (`(?:[0-9]|1[0-1])`, `[0-9]{2}` included); any other pattern scores above every
real score, so widening it is growth. The target baseline must have the generator's shape, checked
line by line in `lib/guard-baseline-neon.awk` and `lib/guard-baseline-phpmd.awk`: a string entry, an
inline map, an entry without message, count or path, another neon key, or a hand-written XML element
makes the helper exit 2 naming the line, and the row reports unmeasurable.

Paths git would C-quote (a quote, a backslash, a control character) are unquoted before matching; a
tab or newline inside a path prints as a space.

## What a refused commit prints

`guard.sh commit` prints the refusal that `vault/architecture/guard-file-formats.md` describes, on
stderr. Its findings are the lines of `bin/guard-report-errors.sh`, each starting with the row id:

```
phpstan-new app/Support/Probe.php:12 givore.swallowedException Catch swallows the exception. → quality/RULES.md "### swallowed-exception"
```

A row with a driver other than `shell` prints the `findings[]` of `<git-common-dir>/qg-last/<id>/result.json`.
For a `shell` row, `guard-report-errors.sh --rows "<id>..." --tree <dir|-> --map <rules.tsv|-> [--checks <tsv>]
[--bases ...] [--target ...]` reads each row's artifact: PHPStan JSON including file-less `errors[]`,
PHPMD JSON, or checkstyle filtered to added lines. An error in a file the target's
`phpstan-baseline.neon` lists adds `baseline count exceeded; your added lines are <ranges>`; an
unmatched-ignore message adds `run composer stan:baseline`. Rows running
`guard-added-lines.sh --grep`, `guard-baseline-growth.sh` or `guard-protected-paths.sh` are re-run
with `GUARD_LIST=1` and print a fixed action. `-` for `--map` or a missing `--checks` reads the file
from `HEAD`. An identifier with no `quality/rules.tsv` row prints without a pointer. `--heading <text>`
prints `<text>` and a blank line before the first line, and nothing when no line prints.

## What a warning prints

After the rows run, `guard.sh commit` passes every row whose `gate` is `warn` and whose value is above
0 to `guard-report-errors.sh --heading`, on stderr. The exit status stays the one the rows set. The
heading is `vault-guard: warnings (the commit goes through)` when no row refuses, and
`vault-guard: warnings (these alone would not refuse the commit)` when the refusal follows:

```
vault-guard: warnings (the commit goes through)

lint-warn-new lib/a.dart:2 avoid_print Avoid print. → quality/RULES.md "### debug-print"
```

A `quality/rules.tsv` that cannot be read prints `vault-guard: quality/rules.tsv is unreadable;
warnings from <ids> are not printed` instead.

## Hooks, pass records and the override

`bin/guard.sh hooks install` writes five hooks into `git rev-parse --git-path hooks`, which linked
worktrees share, and records every local commit not on any remote, so the existing history passes.
Each hook, `bin/guard.sh` and `bin/qg` starts from a clean environment:
`vault/architecture/guard-environment.md`.

| hook | does |
|---|---|
| `pre-commit`, `pre-merge-commit`, `pre-applypatch` | run `guard.sh commit`; exit 1 on its exit 1 or 2, or when `guard.sh` is missing or not executable; write the pass record on a pass |
| `pre-push` | refuses a pushed commit that is on no remote and has no pass record, naming it and `guard.sh verify <sha> --not --remotes`; prints override log lines not printed before; then hands every pushed ref to `guard.sh release --use-pass`, which accepts a valid push pass record for that ref, else runs the rows whose `on` matches that ref, and exits 0 when none does |
| `post-rewrite` | after `commit --amend`, runs `guard.sh verify <new>^!`, which measures the amended commit against its own parents and records it only when it passes; pre-commit measured the new tree against the old commit, which proves nothing about the new one. A rebase records nothing |

**Pass record.** `<git-common-dir>/guard-pass/<key>`, where `<key>` is the SHA-1 of the tree SHA
followed by the sorted parent SHAs, space-separated. It holds `ok`, or `override <reason>`. The
parents belong in the key: a revert that restores an old tree is a new commit that still needs its
own pass. `cherry-pick`, `revert`, `rebase` and scripted commits run no commit hook, so their commits
need `guard.sh verify` before they push. An amend made with `--no-verify` still runs `post-rewrite`,
so it is measured there.

**Push pass record.** `qg run push --ref` records a full push pass that `pre-push` accepts instead of
measuring again: `vault/architecture/guard-push-pass.md`.

## Built-in checks

`guard_gate_locked` in `lib/guard-commit.sh` adds these rows to every commit gate run. No
`checks.tsv` row can drop them, and a first commit skips them. Each one refuses with `worse`.

| id | refuses a commit that |
|---|---|
| `gate-config-changed` | changes a path under `quality/drivers` or `quality/config` |
| `gate-config-invalid` | stages a `quality/checks.tsv` that does not load |
| `gate-config-deleted` | deletes `quality/checks.tsv` or `quality/rules.tsv` |
| `baseline-loosened` | loosens or deletes `quality/baseline.tsv` against the parent |

## The override

**Only a human at a terminal overrides a refusal, and only once.** Two forms pass a commit hook:

| form | how a human uses it |
|---|---|
| `QG_SKIP_REASON` | `QG_SKIP_REASON="<why>" git commit`; the variable must reach the hook's environment |
| the token | `qg override --reason "<why>"`, then `git commit` within 10 minutes |

**Failure mode:** `QG_SKIP_REASON="<why>" && git commit` sets an unexported shell variable. The
hook never sees it, and the commit is refused.

**`QG_SKIP_REASON` conditions.** `lib/guard-override.sh` honours it when the reason has a non-blank
character, `/dev/tty` opens, and neither `CLAUDECODE` nor `AI_AGENT` is set, even to an empty string.

**The token.** `qg override` checks the same conditions, then writes `<git-common-dir>/qg-override`.
The file holds the reason, the user, the time, `commit` or `push`, and a binding:

- A commit token binds to `git write-tree` of the index when `qg override` ran. It passes only a
  commit of exactly that staged content.
- `qg override --reason "<why>" --push <sha>` binds to that full sha. It lifts only the `pre-push`
  check for commits with no pass record. The push gate rows still run.

`qg_override_take` re-checks the human conditions in the hook's own process. A token is therefore
never consumed by a commit an agent runs. The hook deletes the token when it uses it. It also
deletes a token that is malformed, older than 10 minutes, or dated in the future. A token for the
other event or another binding is ignored and kept.

**What an override leaves.** The hook appends a line to `<git-common-dir>/guard-bypass.log`, and a
commit hook writes an `override <reason>` pass record. A reason on a commit that passes writes no
log line. The next `pre-push` prints the log lines it has not printed before.

## Claude Code hooks

The agent guards, their user-level install and their write denials are in
`vault/architecture/guard-agent-hooks.md`.
