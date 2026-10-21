#!/usr/bin/env bash
# Claude Code Stop hook. Claude Code fires Stop at the end of every turn, not only at the end of
# a session. When the turn ends in a gated repo (gated.py: its gate git hook is installed) and HEAD
# carries commits that are on no remote, this exits 2 and tells the agent to push, so the
# pre-push hook runs the full gate while the agent is still there to fix what it refuses.
#
# It blocks at most once per turn (stop_hook_active) and at most GUARD_STOP_LIMIT times (default
# 5) for the same unpushed HEAD; past that it lets the turn end and appends a line to
# <git-common-dir>/guard-bypass.log, which the next push prints. On the default branch,
# development, develop or a detached HEAD it asks for a new branch instead, because a push there
# deploys. Outside a gated repo it exits 0.
set -uo pipefail
command -v python3 >/dev/null 2>&1 || exit 0
HERE="$(dirname "$(realpath "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")")"

input="$(cat)"
# -I: a planted json.py in the cwd, or a PYTHONPATH, cannot answer for the json module.
mapfile -t fields < <(printf '%s' "$input" | python3 -I -c '
import json, sys
try: e = json.load(sys.stdin)
except Exception: e = {}
print("1" if e.get("stop_hook_active") else "0"); print(e.get("session_id") or "-"); print(e.get("cwd") or ".")
' 2>/dev/null)
active="${fields[0]:-0}" session="${fields[1]:--}" cwd="${fields[2]:-.}"

[ "${active:-0}" = 1 ] && exit 0
root="$(git -C "${cwd:-.}" rev-parse --show-toplevel 2>/dev/null)" || exit 0
cd "$root" || exit 0
# Exit 3 is the only "not gated"; a crash or any other code counts as gated, so the hook fails closed.
python3 -I "$HERE/gated.py" "$root" >/dev/null 2>&1
[ "$?" -eq 3 ] && exit 0

n="$(git rev-list --count HEAD --not --remotes 2>/dev/null)" || exit 0
[ "${n:-0}" -gt 0 ] || exit 0

head="$(git rev-parse HEAD)"
common="$(git rev-parse --path-format=absolute --git-common-dir)"
mkdir -p "${common}/guard-stop" 2>/dev/null
counter="${common}/guard-stop/${head}"
count="$(cat "$counter" 2>/dev/null || printf 0)"
case "$count" in ''|*[!0-9]*) count=0 ;; esac
count=$((count + 1))
printf '%s\n' "$count" > "$counter" 2>/dev/null
limit="${GUARD_STOP_LIMIT:-5}"
if [ "$count" -gt "$limit" ]; then
    printf '%s\t%s\t%s\t-\tsession %s ended with %s unpushed commits\tstop hook gave up after %s blocks\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${USER:-$(id -un)}" "$head" "$session" "$n" "$limit" >> "${common}/guard-bypass.log"
    exit 0
fi

branch="$(git symbolic-ref --short -q HEAD || true)"
default="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)"; default="${default#origin/}"
case "$branch" in
    ''|master|main|development|develop|"${default:-master}")
        cat >&2 <<EOF
vault-guard: ${n} commit(s) on ${branch:-a detached HEAD} are on no remote, and a push there deploys.
Move them to a branch, then push that branch:
  git switch -c <type>/<slug>
  qg run push --ref refs/heads/<type>/<slug>      (run with a 600000 ms timeout; the push gate takes up to 10 minutes)
  git push -u origin <type>/<slug>      (accepts the pass qg recorded, so the connection does not sit idle)
If the push is refused, fix the named rows in code, commit, and push again; qg explain <id> says how.
Never edit quality/baseline.tsv, quality/checks.tsv, quality/config, quality/drivers/ or VAULT.md to make it pass.
EOF
        ;;
    *)
        cat >&2 <<EOF
vault-guard: ${n} commit(s) on ${branch} are on no remote. Push before you finish:
  qg run push --ref refs/heads/${branch}      (run with a 600000 ms timeout; the push gate takes up to 10 minutes)
  git push -u origin ${branch}      (accepts the pass qg recorded, so the connection does not sit idle)
If the push is refused, fix the named rows in code, commit, and push again; qg explain <id> says how.
Never edit quality/baseline.tsv, quality/checks.tsv, quality/config, quality/drivers/ or VAULT.md to make it pass.
EOF
        ;;
esac
exit 2
