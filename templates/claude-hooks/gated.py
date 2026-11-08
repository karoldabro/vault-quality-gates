"""Whether a path lies in a gated repo: one whose gate git hook is installed.

A repo is gated when <common dir>/hooks/pre-commit or pre-push holds the line `# vault-guard-start`,
which every template in templates/git-hooks/ carries. It also counts as gated when its .git file,
git dir or hooks folder cannot be read, or <common dir>/config sets hookspath, so anything unclear
fails closed. is_gated reads only the filesystem; no git process starts.

push_unguarded is the one rule that binds outside a gated repo: a checkout whose quality/checks.tsv at
HEAD holds a push row but whose pre-push (the one git runs, after core.hooksPath) lacks that line pushes
with no push gate at all. It runs git.

`python3 -I gated.py <path>` exits 0 when gated and 3 when not.
"""
import os, re, sys

MARKER = '# vault-guard-start'
HOOKS_PATH = re.compile(r'^\s*hookspath\s*=', re.I | re.M)
_cache = {}


def is_git_dir(d):
    """A bare repo or a separate git dir: the folder itself holds HEAD, objects/ and refs/."""
    return os.path.isfile(os.path.join(d, 'HEAD')) and os.path.isdir(os.path.join(d, 'objects')) \
        and os.path.isdir(os.path.join(d, 'refs'))


def repo_root(start):
    """The nearest folder at or above start that holds a .git entry or is itself a git dir, or None."""
    d = os.path.realpath(start)
    while d != '/':
        if os.path.lexists(os.path.join(d, '.git')) or is_git_dir(d):
            return d
        d = os.path.dirname(d)
    return None


def common_dir(root):
    """The git common dir of the repo at root, or None when its .git entry cannot be read."""
    dot = os.path.join(root, '.git')
    if not os.path.lexists(dot) and is_git_dir(root):
        try:
            with open(os.path.join(root, 'commondir')) as f:
                return os.path.normpath(os.path.join(root, f.read(4096).strip()))
        except FileNotFoundError:
            return root
        except OSError:
            return None
    if os.path.isdir(dot):
        return dot
    try:
        with open(dot) as f:
            line = f.read(4096).strip()
    except OSError:
        return None
    if not line.startswith('gitdir:'):
        return None
    gitdir = os.path.normpath(os.path.join(root, line[7:].strip()))
    try:
        with open(os.path.join(gitdir, 'commondir')) as f:
            return os.path.normpath(os.path.join(gitdir, f.read(4096).strip()))
    except FileNotFoundError:
        return gitdir if os.path.isdir(gitdir) else None
    except OSError:
        return None


def _gated_root(root):
    common = common_dir(root)
    if common is None:
        return True
    try:
        with open(os.path.join(common, 'config'), errors='replace') as f:
            if HOOKS_PATH.search(f.read()):
                return True
    except FileNotFoundError:
        pass
    except OSError:
        return True
    hooks = os.path.join(common, 'hooks')
    if os.path.lexists(hooks) and not os.access(hooks, os.R_OK | os.X_OK):
        return True
    for name in ('pre-commit', 'pre-push'):
        try:
            with open(os.path.join(hooks, name), errors='replace') as f:
                if MARKER in f.read(65536):
                    return True
        except FileNotFoundError:
            continue
        except OSError:
            return True
    return False


def is_gated(path):
    """True when path lies in a gated repo; a path in no repo is not gated."""
    root = repo_root(path)
    if root is None:
        return False
    if root not in _cache:
        _cache[root] = _gated_root(root)
    return _cache[root]


def has_push_row(checks):
    """True when a checks.tsv text holds a row that runs on a push: a v2 `on` cell with a push token, or a
    v1 `scope` of release or both (lib/qg-events.sh holds the grammar)."""
    lines = [l for l in checks.splitlines() if l.strip() and not l.startswith('#')]
    if not lines:
        return False
    header = lines[0].split('\t')
    col = 'on' if 'on' in header else 'scope'
    if col not in header:
        return False
    i = header.index(col)
    for line in lines[1:]:
        cells = line.split('\t')
        if len(cells) <= i:
            continue
        cell = cells[i]
        if col == 'scope' and cell in ('release', 'both'):
            return True
        if col == 'on' and any(t == 'push' or t.startswith('push:') for t in cell.split(',')):
            return True
    return False


def push_unguarded(path):
    """True when the repo at path has quality/checks.tsv at HEAD with a push row and git would run no
    vault-guard pre-push."""
    import subprocess
    def git(*a):
        return subprocess.run(['git', '-C', path, *a], capture_output=True, text=True, timeout=5)
    try:
        checks = git('show', 'HEAD:quality/checks.tsv')
        if checks.returncode != 0 or not has_push_row(checks.stdout):
            return False
        hook = git('rev-parse', '--path-format=absolute', '--git-path', 'hooks/pre-push').stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return False
    try:
        with open(hook, errors='replace') as f:
            return MARKER not in f.read(65536)
    except OSError:
        return True


if __name__ == '__main__':
    try:
        sys.exit(0 if is_gated(sys.argv[1] if len(sys.argv) > 1 else '.') else 3)
    except SystemExit:
        raise
    except BaseException:
        sys.exit(0)
