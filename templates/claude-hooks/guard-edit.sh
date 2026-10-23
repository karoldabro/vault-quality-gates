#!/usr/bin/env bash
# Claude Code PreToolUse hook (matcher Edit|Write|MultiEdit|NotebookEdit): exits 2 with the reason
# on stderr when an edit in a gated repo (gated.py) would change what judges the next commit or push:
# the git directory (its hooks and config), husky files, quality/config, quality/drivers/,
# quality/baseline.tsv or quality/checks.tsv. Every other edit passes.
SELF="$(realpath "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"
HERE="$(dirname "$SELF")"
command -v python3 >/dev/null 2>&1 || { echo "guard-edit: python3 is missing, so every edit is denied until it is installed" >&2; exit 2; }
IFS= read -r -d '' SRC <<'PY'
import json, os, subprocess, sys
sys.path.insert(0, sys.argv[1])
try:
    from gated import is_gated
except Exception as e:
    sys.stderr.write(f'guard-edit: denied: cannot load gated.py ({type(e).__name__}: {e})\n')
    sys.exit(2)

GATE_FILES = ('quality/config', 'quality/drivers', 'quality/baseline.tsv', 'quality/checks.tsv')

def git_out(start, *args):
    while start and not os.path.isdir(start):
        start = os.path.dirname(start)
    try:
        return subprocess.run(['git', '-C', start or '/', 'rev-parse', '--path-format=absolute', *args],
                              capture_output=True, text=True, timeout=5).stdout.split('\n')
    except (OSError, subprocess.SubprocessError):
        return []

def reason(ab):
    """Why an agent may not edit ab, or None."""
    real = os.path.realpath(ab)
    parts = real.split('/')
    if '.git' in parts:
        return 'it is inside a .git directory'
    if '.husky' in parts or parts[-1] == '.huskyrc':
        return 'it is a husky hook file, which git runs as a commit hook'
    out = git_out(os.path.dirname(ab), '--git-dir', '--git-common-dir', '--show-toplevel')
    dirs, top = [os.path.realpath(d) for d in out[:2] if d], out[2] if len(out) > 2 and out[2] else None
    if any(real == d or real.startswith(d + '/') for d in dirs):
        return 'it is inside the git directory'
    if top and real.startswith(os.path.realpath(top) + '/'):
        rel = real[len(os.path.realpath(top)) + 1:]
        if any(rel == g or rel.startswith(g + '/') for g in GATE_FILES):
            return f'{rel} judges the next commit or push; a human changes it'
    return None

try:
    event = json.load(sys.stdin)
    tin = event.get('tool_input') or {}
    target = tin.get('file_path') or tin.get('notebook_path') or ''
    cwd = event.get('cwd') or os.getcwd()
    ab = os.path.normpath(os.path.join(cwd, os.path.expanduser(target))) if target else ''
    why = reason(ab) if ab and is_gated(ab) else None
except Exception as e:
    target, why = '?', f'the hook could not read its input ({type(e).__name__}: {e})'
if why:
    sys.stderr.write(f'guard-edit: denied editing {target}: {why}. Fix what the commit gate reports instead; only the human at a terminal may override it.\n')
    sys.exit(2)
PY
# -I: no PYTHON* variable, user site folder or planted module in the cwd changes the verdict.
exec python3 -I -c "$SRC" "$HERE"
