"""Whether a path lies in a gated repo: one whose gate git hook is installed.

A repo is gated when <common dir>/hooks/pre-commit or pre-push holds the line `# vault-guard-start`,
which every template in templates/git-hooks/ carries. It also counts as gated when its .git file,
git dir or hooks folder cannot be read, or <common dir>/config sets hookspath, so anything unclear
fails closed. Only the filesystem is read; no git process starts.

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


if __name__ == '__main__':
    try:
        sys.exit(0 if is_gated(sys.argv[1] if len(sys.argv) > 1 else '.') else 3)
    except SystemExit:
        raise
    except BaseException:
        sys.exit(0)
