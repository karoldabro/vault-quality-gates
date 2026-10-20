#!/usr/bin/env bash
# Claude Code PreToolUse hook (matcher Edit|Write|MultiEdit|NotebookEdit): exits 2 with the reason
# on stderr when the target is inside a .git directory or the git common dir, a Claude settings
# file, a git config file, the main worktree of the plugin checkout (this file's grandparent
# directory), or a global write denial (write_denials.py). A linked worktree of the plugin is editable.
SELF="$(realpath "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"
HERE="$(dirname "$SELF")"
PLUGIN="$(cd "$HERE/../.." 2>/dev/null && pwd -P)"
command -v python3 >/dev/null 2>&1 || { echo "guard-edit: python3 is missing, so every edit is denied until it is installed" >&2; exit 2; }
IFS= read -r -d '' SRC <<'PY'
import fnmatch, json, os, subprocess, sys
sys.path.insert(0, sys.argv[2])
try:
    import write_denials
except Exception as e:
    sys.stderr.write(f'guard-edit: denied: cannot load write_denials.py ({type(e).__name__}: {e})\n')
    sys.exit(2)
PLUGIN = os.path.realpath(sys.argv[1])
INSTALLED = os.path.realpath(os.path.expanduser('~/.claude/plugins/cache'))

def main_worktree(plugin):
    try:
        out = subprocess.run(['git', '-C', plugin, 'rev-parse', '--path-format=absolute', '--git-common-dir'],
                             capture_output=True, text=True, timeout=5).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return plugin
    return os.path.realpath(os.path.dirname(out)) if os.path.basename(out) == '.git' else plugin

# The main worktree of the checkout these hooks run from; a linked worktree of the plugin stays editable.
ROOTS = {main_worktree(PLUGIN)}

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
        if '.husky' in parts or parts[-1] == '.huskyrc' or '/.config/husky/' in p + '/':
            return 'it is a husky hook file, which git runs as a commit hook'
        if any(p == r or p.startswith(r + '/') for r in ROOTS):
            return 'it is inside the vault-quality-gates plugin checkout'
        if p.startswith(INSTALLED + '/'):
            return 'it is installed Claude Code plugin code, which runs without being scanned'
    why = write_denials.denial(ab, PLUGIN)
    if why:
        return why
    real = os.path.realpath(ab)
    for d in set(git_dirs(cwd) + git_dirs(os.path.dirname(ab))):
        if real == d or real.startswith(d + '/'):
            return 'it is inside the git directory'
    top = git_top(os.path.dirname(ab))
    if top and real.startswith(top + '/'):
        rel = real[len(top) + 1:]
        if rel == 'quality/config' or rel == 'quality/drivers' or rel.startswith('quality/drivers/'):
            return 'it is gate configuration (quality/config or a repo driver) that judges the next commit; a human changes it'
    return None

def git_top(start):
    while start and not os.path.isdir(start):
        start = os.path.dirname(start)
    try:
        out = subprocess.run(['git', '-C', start or '/', 'rev-parse', '--show-toplevel'],
                             capture_output=True, text=True, timeout=5).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return None
    return os.path.realpath(out) if out else None

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
# -I: no PYTHON* variable, user site folder or planted module in the cwd changes the verdict.
exec python3 -I -c "$SRC" "$PLUGIN" "$HERE"
