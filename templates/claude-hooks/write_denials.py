"""Global write denials for guard_bash.py and guard-edit.sh: folders an agent never writes, in any repo.

The Dart package cache and Flutter SDKs, which an unsandboxed suite would then run; copydetect's
virtualenv; shell startup files; every PATH folder before /usr/bin; every machine tool-path folder.
"""
import glob, os, re, subprocess

HOME = os.path.expanduser('~')
HOME_REAL = os.path.realpath(HOME)
STARTUP = ('.bashrc', '.bash_profile', '.bash_login', '.bash_logout', '.bash_aliases', '.profile',
           '.zshrc', '.zshenv', '.zprofile', '.zlogin', '.zlogout')
# Folders whose files every login or shell session sources: a line there can set GIT_CONFIG_* for every repo.
STARTUP_DIRS = ('.config/fish', '.config/environment.d')
# A path inside interpreter code: ~, $HOME or ${HOME} followed by /, or an absolute path.
TEXT_PATH = re.compile(r'''(?:~|\$\{HOME\}|\$HOME)(?=/)[^\s'"`;|&<>(){}\[\],]*|/[^\s'"`;|&<>(){}\[\],]+''')
# Code that writes a file or starts a program: a write mode passed as an argument, a write or file call,
# a shell redirect, or a process start.
WRITES = re.compile(r''',\s*['"][rbt]*[wax+][rwabt+]*['"]|write|append|>|unlink|remove|rmtree|rename|replace\(|mkdir|makedirs'''
                    r'''|copy|move|chmod|chown|symlink|link\(|truncate|touch|exec|system|spawn|popen|subprocess|child_process'''
                    r'''|shutil|fopen|file_put_contents|\bfs\.|File\.|pathlib|\bdd\b|\btee\b|\bcp\b|\bmv\b|\brm\b|\bln\b|install''', re.I)
_roots = {}


def under(p, root):
    return p == root or p.startswith(root.rstrip('/') + '/')


def path_roots():
    """Absolute PATH folders before /usr/bin, resolved; every absolute one when /usr/bin is absent."""
    entries = [e for e in os.environ.get('PATH', '').split(':') if e.startswith('/')]
    if '/usr/bin' in entries:
        entries = entries[:entries.index('/usr/bin')]
    return {os.path.realpath(e) for e in entries} - {'/'}


def tool_path_roots(plugin):
    """The folders in the machine tool-path file, in the git common dir of the plugin checkout."""
    try:
        common = subprocess.run(['git', '-C', plugin, 'rev-parse', '--path-format=absolute', '--git-common-dir'],
                                capture_output=True, text=True, timeout=5).stdout.strip()
        with open(os.path.join(common, 'qg-tool-path')) as f:
            lines = f.read().split('\n')
    except (OSError, subprocess.SubprocessError):
        return set()
    return {os.path.realpath(x) for x in lines if x.startswith('/')} - {'/'}


def roots(plugin):
    if plugin not in _roots:
        _roots[plugin] = path_roots() | tool_path_roots(plugin)
    return _roots[plugin]


def sdk_root(p):
    d = p
    while d and d != '/':
        if os.path.isfile(os.path.join(d, 'bin', 'internal', 'engine.version')) \
                and os.path.isdir(os.path.join(d, 'packages', 'flutter_tools')):
            return d
        d = os.path.dirname(d)
    return None


def denial(path, plugin):
    """The reason an agent may not write path (absolute), or None."""
    for p in {os.path.normpath(path), os.path.realpath(path)}:
        for home in {HOME, HOME_REAL}:
            if under(p, os.path.join(home, '.pub-cache')):
                return 'it is in the Dart package cache, which the gate runs unsandboxed'
            if p in {os.path.join(home, s) for s in STARTUP} or any(under(p, os.path.join(home, s)) for s in STARTUP_DIRS):
                return 'it is a shell startup file'
            cache = os.path.join(home, '.cache')
            if p.startswith(cache + '/'):
                child = os.path.join(cache, p[len(cache) + 1:].split('/')[0])
                if any(os.path.isdir(c) for c in glob.glob(os.path.join(child, 'copydetect-*'))):
                    return 'it is in the copydetect environment the gate runs'
        if sdk_root(p):
            return 'it is inside a Flutter SDK'
        hit = next((r for r in roots(plugin) if under(p, r)), None)
        if hit:
            return f'it is under {hit}, a folder of programs on PATH or in the machine tool-path file'
    return None


def text_denial(text, plugin):
    """The first denied path spelled inside code that writes or runs something, with its reason, or
    None. Code that only reads, and a shebang line, name paths harmlessly."""
    if text.startswith('#!'):
        text = text.partition('\n')[2]
    if not WRITES.search(text):
        return None
    for m in TEXT_PATH.finditer(text):
        t = re.sub(r'^(~|\$\{HOME\}|\$HOME)', lambda _: HOME, m.group(0))
        why = denial(t, plugin)
        if why:
            return m.group(0), why
    return None
