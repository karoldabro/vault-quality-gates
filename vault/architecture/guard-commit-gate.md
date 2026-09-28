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
`quality/baseline.tsv` and the `VAULT.md` keys with `git show HEAD:<path>`, never from the working
tree, so an edit cannot loosen the gate that judges it. A `HEAD` without `quality/checks.tsv` or
`quality/rules.tsv` is exit 2 naming the file. A first commit, with no `HEAD`, reads them from the
index. A commit that changes the gate configuration is measured by the old configuration.

**Bases.** The parents of the commit being made: `HEAD`, every `MERGE_HEAD` line, and every
`GITHEAD_<sha>` variable `git merge` exports to `pre-merge-commit`, which runs before `MERGE_HEAD`
exists. A first commit has the empty tree. Diff-based helpers count a line or entry only when it is
new against every base, so a merge never re-judges what an upstream parent already committed.

**The measured tree.** A row whose `command` or `artifact` names `{{tree}}` or `{{cache}}` is a tree
row. When one runs, the gate takes an exclusive lock on `<git-common-dir>/guard-tree.lock`, waiting
`GUARD_LOCK_WAIT` seconds (default 120), then syncs `<git-common-dir>/guard-tree` to the target tree
with the private index `guard-tree.index` (`read-tree -u --reset`, then `clean -fdx`). A missing or
broken private index wipes the directory and rebuilds it, so a deleted file never survives. A held
lock or a failed sync makes every tree row unmeasurable. The lock is held until the refusal has read
the reports inside the tree, so a second commit cannot overwrite them first. Every path resolves through the git common
dir, so a linked worktree measures its own index into the shared directory, one commit at a time.

**`VAULT.md` keys**, flat `key: value` lines read from `HEAD`, each a space-separated list of path
prefixes that match a whole path or a directory boundary (`quality` matches `quality/x`, never
`quality-reports/x`):

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
| `bin/guard-added-lines.sh --grep <regex>` | added lines matching the extended regex, in `*.php` outside `tests/PHPStan/Rules/Fixtures/` |
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

`guard.sh commit` writes this to stderr: one summary line per worse or unmeasurable row, then the
lines of `bin/guard-report-errors.sh`, which start with the row id.

```
vault-guard: the staged commit refused

  phpstan-new          measured 1 (floor 0)
  suppressions-added   measured 1 (floor 0)

phpstan-new app/Support/Probe.php:12 givore.swallowedException Catch swallows the exception. → quality/RULES.md "### swallowed-exception"
suppressions-added app/Support/Probe.php:11 // @phpstan-ignore-next-line → remove the suppression and fix the code

Fix the code. Never bypass the hook; only a human at a terminal may override once, with QG_SKIP_REASON.
```

`guard-report-errors.sh --rows "<id>..." --tree <dir|-> --map <rules.tsv|-> [--checks <tsv>]
[--bases ...] [--target ...]` reads each row's artifact: PHPStan JSON including file-less `errors[]`,
PHPMD JSON, or checkstyle filtered to added lines. An error in a file the target's
`phpstan-baseline.neon` lists adds `baseline count exceeded; your added lines are <ranges>`; an
unmatched-ignore message adds `run composer stan:baseline`. Rows running
`guard-added-lines.sh --grep`, `guard-baseline-growth.sh` or `guard-protected-paths.sh` are re-run
with `GUARD_LIST=1` and print a fixed action. `-` for `--map` or a missing `--checks` reads the file
from `HEAD`. An identifier with no `quality/rules.tsv` row prints without a pointer.

## Hooks, pass records and the override

`bin/guard.sh hooks install` writes five hooks into `git rev-parse --git-path hooks`, which linked
worktrees share, and records every local commit not on any remote, so the existing history passes.

| hook | does |
|---|---|
| `pre-commit`, `pre-merge-commit`, `pre-applypatch` | run `guard.sh commit`; exit 1 on its exit 1 or 2, or when `guard.sh` is missing or not executable; write the pass record on a pass |
| `pre-push` | refuses a pushed commit that is on no remote and has no pass record, naming it and `guard.sh verify <sha> --not --remotes`; prints override log lines not printed before; then runs the release gate on a ref matching `guard_release_pattern` |
| `post-rewrite` | after `commit --amend`, runs `guard.sh verify <new>^!`, which measures the amended commit against its own parents and records it only when it passes; pre-commit measured the new tree against the old commit, which proves nothing about the new one. A rebase records nothing |

**Pass record.** `<git-common-dir>/guard-pass/<key>`, where `<key>` is the SHA-1 of the tree SHA
followed by the sorted parent SHAs, space-separated. It holds `ok`, or `override <reason>`. The
parents belong in the key: a revert that restores an old tree is a new commit that still needs its
own pass. `cherry-pick`, `revert`, `rebase` and scripted commits run no commit hook, so their commits
need `guard.sh verify` before they push. An amend made with `--no-verify` still runs `post-rewrite`,
so it is measured there.

**Override.** A commit hook or `pre-push` that would refuse passes once when
`lib/guard-override.sh` honours `QG_SKIP_REASON`: a non-blank reason, a `/dev/tty` that opens, and
neither `CLAUDECODE` nor `AI_AGENT` set, even to an empty string. The hook appends a line to
`<git-common-dir>/guard-bypass.log` and writes an `override <reason>` pass record. A reason on a
commit that passes writes no log line. A release ref still runs the release gate after an override.

**Claude Code hooks.** `bin/guard.sh hooks install --claude` also merges two `PreToolUse` entries into
`<repo>/.claude/settings.json` with `jq`: matcher `Bash` runs `templates/claude-hooks/guard-bash.sh`
and matcher `Edit|Write|MultiEdit|NotebookEdit` runs `templates/claude-hooks/guard-edit.sh`, both by
absolute path from the plugin checkout. An entry already naming the same command is kept, not
duplicated; foreign entries are never removed. `hooks status` reports the five git hooks and both
entries. `hooks remove` removes the git hooks only; delete the two entries by hand.
