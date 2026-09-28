#!/usr/bin/env bash
# Claude Code PreToolUse hook (matcher Bash): exits 2 with the reason on stderr when a command
# would skip, disable or forge the commit gate; exits 0 otherwise. Read-only commands always pass.
# The plugin checkout is this file's grandparent directory, so the guard protects its own files.
# The rules live in guard_bash.py; the tokeniser in shell_lexer.py.
SELF="$(realpath "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"
HERE="$(dirname "$SELF")"
PLUGIN="$(cd "$HERE/../.." 2>/dev/null && pwd -P)"
command -v python3 >/dev/null 2>&1 || { echo "guard-bash: python3 is missing, so every Bash call is denied until it is installed" >&2; exit 2; }
exec python3 -B "$HERE/guard_bash.py" "$PLUGIN"
