#!/usr/bin/env bash
# Claude Code PreToolUse hook (matcher Edit|Write|MultiEdit|NotebookEdit): exits 2 with the reason
# on stderr when the target is inside a .git directory or the git common dir, a Claude settings
# file, a git config file, or the plugin checkout (this file's grandparent directory).
SELF="$(realpath "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"
PLUGIN="$(cd "$(dirname "$SELF")/../.." 2>/dev/null && pwd -P)"
command -v python3 >/dev/null 2>&1 || { echo "guard-edit: python3 is missing, so every edit is denied until it is installed" >&2; exit 2; }
IFS= read -r -d '' SRC <<'PY'
import fnmatch, json, os, subprocess, sys
PLUGIN = os.path.realpath(sys.argv[1])

def git_dirs(start):
    while start and not os.path.isdir(start):
        start = os.path.dirname(start)
    try:
        out = subprocess.run(['git', '-C', start or '/', 'rev-parse', '--path-format=absolute', '--git-dir', '--git-common-dir'],
                             capture_output=True, text=True, timeout=5).stdout
    except (OSError, subprocess.SubprocessError):
        return []
    return [os.path.realpath(d) for d in out.split('\n') if d]

def reason(path, cwd):
    ab = os.path.normpath(os.path.join(cwd, os.path.expanduser(path)))
    for p in (ab, os.path.realpath(ab)):
        parts = p.split('/')
        if '.git' in parts:
            return 'it is inside a .git directory'
        if len(parts) > 1 and parts[-2] == '.claude' and fnmatch.fnmatch(parts[-1], 'settings*.json'):
            return 'it is a Claude Code settings file that installs the guard hooks'
        if parts[-1] == '.gitconfig' or p.endswith('/.config/git/config'):
            return 'it is a git config file'
        if p == PLUGIN or p.startswith(PLUGIN + '/'):
            return 'it is inside the vault-quality-gates plugin checkout'
    real = os.path.realpath(ab)
    for d in set(git_dirs(cwd) + git_dirs(os.path.dirname(ab))):
        if real == d or real.startswith(d + '/'):
            return 'it is inside the git directory'
    return None

try:
    event = json.load(sys.stdin)
    tin = event.get('tool_input') or {}
    target = tin.get('file_path') or tin.get('notebook_path') or ''
    why = reason(target, event.get('cwd') or os.getcwd()) if target else None
except Exception as e:
    target, why = '?', f'the hook could not read its input ({type(e).__name__}: {e})'
if why:
    sys.stderr.write(f'guard-edit: denied editing {target}: {why}. The commit gate forbids agents from changing it.\n')
    sys.exit(2)
PY
exec python3 -c "$SRC" "$PLUGIN"
