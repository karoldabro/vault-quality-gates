---
type: report
project: vault-quality-gates
slug: lowered-baseline-cannot-be-pushed
date: 2026-11-04
status: closed
severity: blocking
found_by: the operator, pushing api.mistflare.studio after its session S1b
found_in: pushing the first real feature onto a repo whose baseline was measured on an empty skeleton
files: [bin/guard.sh, templates/git-hooks/pre-push, lib/guard-commit.sh, lib/qg-refusal.sh, bin/qg, lib/guard-override.sh]
tags: [report]
---

# lowered-baseline-cannot-be-pushed — report

## What is wrong

A `quality/baseline.tsv` that `qg baseline` writes with any value lower than the committed one can be committed only through an override, and no override, flag or grant lets it be pushed.

## Files

| file (exact path) | what is wrong in it |
|-------------------|---------------------|
| /home/kdabrow/workspace/vault-quality-gates/bin/guard.sh | `guard_release_locked` (lines 263-276) refuses `baseline-loosened` on every `release` run. `cmd_measure` (lines 289-292) runs it after the rows, with no override check |
| /home/kdabrow/workspace/vault-quality-gates/templates/git-hooks/pre-push | `guard_override_used ... push` (line 64) is consulted only for commits that never passed the commit gate. The `release --use-pass` call (line 94) has no override path |
| /home/kdabrow/workspace/vault-quality-gates/lib/guard-commit.sh | lines 165-174 refuse the same loosened baseline at commit time, so the operator's own `qg baseline` output needs a commit override |
| /home/kdabrow/workspace/vault-quality-gates/lib/qg-refusal.sh | line 130 prints `qg override --reason "<why>" --push <sha>` as the way past a push refusal, including `baseline-loosened`, which that override never reaches |
| /home/kdabrow/workspace/vault-quality-gates/bin/qg | line 80 says the push override is for commits that never passed the commit gate, and line 268 builds only that token |
| /home/kdabrow/workspace/vault-quality-gates/lib/guard-override.sh | `qg_override_write` (line 113) binds a commit token to the tree staged when it runs, so `qg override && git commit <path>` names the wrong tree |

## Consequence

The gate blocks the operator's own decision with no way out. This has already happened: on 2026-11-04 api.mistflare.studio could not push `main` at `d84b5e0`, although all 14 push rows measured `ok`.

The operator tried 6 command sequences, each following the printed advice:
1. `qg run push`;
2. `qg baseline`;
3. commit;
4. `qg override` then `git commit <path>`;
5. `git add`, `qg override`, `git commit`;
6. `qg override --push`.

The only remaining route is `git push --no-verify`, which skips every push row.

Every repo onboarded with a fresh baseline on an empty or small codebase hits this on its first real feature. Its PHP Insights scores start at 100, and any real class lowers them.

## Cause

The design treats every looser baseline as a regression hidden by an agent: `qg help override` says "A worse push metric is fixed in code, never overridden". Three facts break that design:
- `qg baseline` is the operator-only command for accepting a new floor, yet its output is refused at commit and at push like an agent's edit.
- The commit gate accepts an override for it, and the push gate accepts none. So a commit can land locally that can never leave the machine.
- The push refusal footer (`lib/qg-refusal.sh:130`) offers `--push <sha>` for every push refusal, though that token covers only unrecorded commits.

A smaller trap adds to it. `qg override` binds the commit token to the tree staged at that moment (`lib/guard-override.sh`). When the operator runs `git commit <path>`, the path is staged only after the token was written, so the token names a different tree and is ignored.

## How to see it

In any gated repo:
1. Make the code score drop, for example by adding a class with an `empty()` call.
2. Run `qg baseline`, then `git add quality/baseline.tsv && qg override --reason x && git commit -m b`.
3. Run `qg override --reason x --push $(git rev-parse HEAD) && qg run push --ref refs/heads/main`.

The push refuses with `baseline-loosened worse`. The same happens through `git push`, because the pre-push hook calls `guard.sh release --use-pass` (line 94) after the override check.

Recorded run: api.mistflare.studio, commit `d84b5e0`, 2026-11-04. Its `qg last` shows `baseline-loosened worse: measured 5 (insights-code 96.8 -> 89.4 ...)`.

## Repair

Run `/v-work`; it touches `bin/guard.sh`, `templates/git-hooks/pre-push`, `lib/guard-commit.sh`, `lib/qg-refusal.sh`, `lib/guard-override.sh`, `bin/qg` and their bats tests.

1. Make `qg baseline` the accepted route. It writes, next to `quality/baseline.tsv`, an acceptance record bound to the new file's blob hash and the reason. `guard_release_locked` and the commit-side check accept a loosened baseline whose blob matches a record written at a terminal. An agent's edit to the file still has no record and stays refused.
2. Alternatively, let `qg override --push <sha>` also cover `baseline-loosened` for exactly that sha, and pass the token into the `release` step.
3. Make the refusal footer name the route that actually works for each refusal id, and never offer `--push` where it cannot pass.
4. Have `qg override` refuse when nothing is staged, and print that `git commit <path>` stages after the token is written.
5. Add a bats test for the whole operator path: lower a score, run `qg baseline`, commit and push. It must succeed with at most one confirmation and without `--no-verify`.

## Not now because

The finding session was building api.mistflare.studio, and this repo is outside its scope. The engine change needs its own session and tests.

## Closes when

The bats test in Repair step 5 passes. It lowers a score, runs `qg baseline`, then commits and pushes `main` to a local bare remote with the pre-push hook installed, without `--no-verify`.
