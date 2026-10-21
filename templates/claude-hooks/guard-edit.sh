#!/usr/bin/env bash
# Claude Code PreToolUse hook (matcher Edit|Write|MultiEdit|NotebookEdit): exits 2 with the reason
# on stderr. In every repo it denies a Claude settings file, a global git config file, the main
# worktree of the plugin checkout (this file's grandparent directory), installed plugin code and a
# global write denial (write_denials.py). In a gated repo (gated.py) it also denies a .git directory,
# the git common dir, husky files and gate configuration. A linked worktree of the plugin is editable.
SELF="$(realpath "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"
HERE="$(dirname "$SELF")"
PLUGIN="$(cd "$HERE/../.." 2>/dev/null && pwd -P)"
command -v python3 >/dev/null 2>&1 || { echo "guard-edit: python3 is missing, so every edit is denied until it is installed" >&2; exit 2; }
IFS= read -r -d '' SRC <<'PY'
import fnmatch, json, os, subprocess, sys
sys.path.insert(0, sys.argv[2])
try:
    import write_denials
    from gated import is_gated
except Exception as e:
    sys.stderr.write(f'guard-edit: denied: cannot load write_denials.py or gated.py ({type(e).__name__}: {e})\n')
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

def integrity_reason(ab):
    """Why no agent may edit ab in any repo, or None."""
    for p in (ab, os.path.realpath(ab)):
        parts = p.split('/')
        if len(parts) > 1 and (parts[-2] == '.claude' or parts[-2].startswith('.claude-')) and fnmatch.fnmatch(parts[-1], 'settings*.json'):
            return 'it is a Claude Code settings file, which can install or switch off the guard hooks'
        if parts[-1] == '.gitconfig' or p.endswith('/.config/git/config'):
            return 'it is a global git config file, which reaches the hooks of every repo'
        if '/.config/husky/' in p + '/':
            return "it is husky's user config, which runs before every repo's hooks"
        if any(p == r or p.startswith(r + '/') for r in ROOTS):
            return 'it is inside the vault-quality-gates plugin checkout'
        if p.startswith(INSTALLED + '/'):
            return 'it is installed Claude Code plugin code, which runs without being scanned'
    return write_denials.denial(ab, PLUGIN)

def gate_reason(ab, cwd):
    """Why no agent may edit ab in a gated repo, or None."""
    for p in (ab, os.path.realpath(ab)):
        parts = p.split('/')
        if '.git' in parts:
            return 'it is inside a .git directory'
        if '.husky' in parts or parts[-1] == '.huskyrc':
            return 'it is a husky hook file, which git runs as a commit hook'
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

def reason(path, cwd):
    """(why, suffix) for a denied edit, or (None, None)."""
    ab = os.path.normpath(os.path.join(cwd, os.path.expanduser(path)))
    why = integrity_reason(ab)
    if why:
        return why, "This protects the agent guards and the gate's tools in every repo; ask the human to make this change."
    why = gate_reason(ab, cwd)
    if why and (is_gated(ab) or is_gated(cwd)):
        return why, 'Fix what the commit gate reports instead; only the human at a terminal may override it.'
    return None, None

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
    why, suffix = reason(target, event.get('cwd') or os.getcwd()) if target else (None, None)
except Exception as e:
    target, why, suffix = '?', f'the hook could not read its input ({type(e).__name__}: {e})', 'Nothing was edited.'
if why:
    sys.stderr.write(f'guard-edit: denied editing {target}: {why}. {suffix}\n')
    sys.exit(2)
PY
# -I: no PYTHON* variable, user site folder or planted module in the cwd changes the verdict.
exec python3 -I -c "$SRC" "$PLUGIN" "$HERE"
