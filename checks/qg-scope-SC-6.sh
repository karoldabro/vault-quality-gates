#!/usr/bin/env bash
# qg-guard-scope SC-6 — this checkout's guard-bash.sh, fed the refused commands with the real cwds on
# this machine, returns the expected exit code for each. Reads only: the hook judges, nothing runs.
#
# Exit 0 pass, 1 fail, 2 could not run (a cwd is missing).
set -uo pipefail
exec < /dev/null
HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/templates/claude-hooks/guard-bash.sh"
W="$HOME/workspace"
fail=0
row() {  # row <cwd> <expected exit> <command>
    local cwd="$1" want="$2" cmd="$3" rc=0
    [ -d "$cwd" ] || { printf 'missing cwd: %s\n' "$cwd"; exit 2; }
    jq -nc --arg c "$cmd" --arg d "$cwd" '{tool_name:"Bash",cwd:$d,tool_input:{command:$c}}' \
        | "$HOOK" >/dev/null 2>&1 || rc=$?
    if [ "$rc" -ne "$want" ]; then
        printf '  WRONG  exit %s, want %s: (%s) %s\n' "$rc" "$want" "$cwd" "$cmd"; fail=1
    fi
}
row "$W/agent-control" 0 'systemctl --user restart agent-dashboard.service'
row "$W/agent-control" 0 'bin/test-safe.sh'
row "$W/agent-control" 0 "python3 -c \"import json; print(json.load(open('\$f')))\""
row "$W/agent-control" 0 'git worktree list'
row "$W/animation-studio" 0 '"${PYTHON}" -m json.tool x.json'
row "$W/animation-studio" 0 'rm -rf "$RUN_DIR/audio"'
row "$W/animation-studio" 2 "git -C $W/recycling-api commit -n -m x"
row "$W/animation-studio" 2 'touch ~/.claude/settings.json'
row "$W/recycling-api" 2 'git commit -n -m x'
row "$W/recycling-api" 0 'git worktree list'
exit "$fail"
