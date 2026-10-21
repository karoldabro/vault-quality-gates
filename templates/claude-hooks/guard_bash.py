"""Rules for guard-bash.sh: raises Deny for every form that skips, disables or forges the commit gate."""
import glob, json, os, re, stat, subprocess, sys, time

# python3 -I leaves the script's folder off sys.path, so a planted module in the cwd never loads;
# the tokeniser beside this file is put back explicitly, after the standard library is imported.
sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
try:
    from shell_lexer import Lexer, Word
    import write_denials
except Exception as e:  # exit 1 would let the command run; a hook that cannot load denies
    sys.stderr.write(f'guard-bash: denied: cannot load the rules ({type(e).__name__}: {e})\n')
    sys.exit(2)

RAW_PLUGIN = sys.argv[1].rstrip('/') or '/'
PLUGIN = os.path.realpath(RAW_PLUGIN)
HOME = os.path.expanduser('~')


def main_worktree(plugin):
    """The main worktree of the checkout the hooks run from; the checkout itself when git cannot say."""
    try:
        out = subprocess.run(['git', '-C', plugin, 'rev-parse', '--path-format=absolute', '--git-common-dir'],
                             capture_output=True, text=True, timeout=5).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return plugin
    return os.path.realpath(os.path.dirname(out)) if os.path.basename(out) == '.git' else plugin


# The hooks protect the main worktree of the checkout they run from, which the user-level install
# names; any linked worktree of the plugin stays editable, the one the hooks run from included.
MAIN = main_worktree(PLUGIN)
PLUGIN_ROOTS = {MAIN}
PLUGIN_SPELLINGS = PLUGIN_ROOTS | ({RAW_PLUGIN} if PLUGIN == MAIN else set())
# Code Claude Code installed as plugins. guard-edit and the write checks below deny agents every write
# there, so a script under it runs as installed and is not scanned.
INSTALLED = os.path.realpath(os.path.join(HOME, '.claude', 'plugins', 'cache'))
GUARD_SH = os.path.join(PLUGIN, 'bin', 'guard.sh')
# Any of these in a word of a command that is not a read denies it (compared lower-case, // collapsed).
NEEDLES = ('.git/hooks', '.git/config', 'guard-pass', 'guard_pass', 'guard-bypass', 'guard_bypass', 'guard-tree', 'guard_tree',
           'guard-cache', 'guard_cache', 'hookspath', 'send-pack', 'http-push', 'receive-pack', 'receivepack', 'fast-import',
           'fsmonitor', 'sshcommand', 'git_exec_path', 'git_config', 'qg_skip_reason', 'claudecode', 'ai_agent', '--no-veri',
           '.claude/settings', '.gitconfig', '.husky', '.huskyrc', 'config/husky', 'guard-stop', '.config/git/config', 'includeif', 'include.path',
           'guard_skip', 'guard_config_rev', 'guard_config_pin', 'guard_config_at', 'guard_only',
           'qg-override', 'qg_override', 'qg-last', 'qg_last', 'qg-grant', 'qg_grant')
QG_SH = os.path.join(PLUGIN, 'bin', 'qg')
# What an agent may run through qg: reads, and the gate itself. Everything else changes the gate.
QG_READS = {'help', '-h', '--help', 'list', 'explain', 'last', 'drivers', 'doctor', 'run', 'report', 'verify', 'config'}
# What the operator's grant may name, and its longest life: QG_GRANT_ACTIONS and QG_GRANT_MAX in lib/qg-grant.sh.
GRANT_ACTIONS = {'baseline', 'override', 'push'}
GRANT_MAX = 28800
# Repo paths that judge the next commit: a write to them is the human's, through the override.
GATE_FILES = ('quality/drivers', 'quality/config')
# The gate reads these from its environment; a value an agent sets would steer which rows run or which config judges.
GATE_VAR = re.compile(r'(GUARD|QG)_\w*\Z')
PLUGIN_RE = re.compile('(%s)(/|\\Z)' % '|'.join(re.escape(p.lower()) for p in PLUGIN_SPELLINGS))
# Needles that only count when the same command also names git, .git, a hook or the plugin: a file
# called ai_agent.py is ordinary, an agent marker cleared beside a commit is not.
SOFT_NEEDLES = ('claudecode', 'ai_agent')
NAMES_GIT = re.compile(r'\bgit\b|\.git|\bhooks?\b(?![-.])|husky|\bqg\b|guard\.sh|' + '|'.join(re.escape(p) for p in PLUGIN_SPELLINGS if len(p) > 1), re.I)
# What a command scanned so far: every text read (the input, scripts, inline code) and the soft
# findings that turn into a denial once that text names git.
SEEN, DEFERRED = [], []
SUBST = re.compile(r'\$\([^)]*\)?|`[^`]*`?|\$\{[^}]*\}?|\$(\w+|[0-9@*#?$!-])')


def literal_text(word):
    """What a word shows before it runs: its text with every $var, ${..}, $(..) and `..` taken out."""
    return SUBST.sub('', str(word)).strip()


def defer_dynamic(what):
    DEFERRED.append(f'{what} is computed at run time, in a command that names git, a hook, qg or the plugin')
MARKERS = {'CLAUDECODE', 'AI_AGENT'}
# Names that change what bash, git or the loader runs, whatever the command beside them.
DENIED_NAMES = {'BASH_ENV', 'SHELLOPTS', 'BASHOPTS', 'GIT_REPLACE_REF_BASE', 'GIT_NO_REPLACE_OBJECTS',
                'GIT_ALTERNATE_OBJECT_DIRECTORIES', 'GIT_OBJECT_DIRECTORY', 'GIT_EXTERNAL_DIFF',
                'LD_PRELOAD', 'LD_LIBRARY_PATH', 'LD_AUDIT'}
IDENT = re.compile(r'[A-Za-z_]\w*\Z')
DECLARE = {'export', 'declare', 'typeset', 'readonly', 'local'}
ENV_REDIRECT = {'HOME', 'XDG_CONFIG_HOME', 'PATH'}
WRITERS = {'rm', 'mv', 'cp', 'ln', 'chmod', 'chown', 'chgrp', 'touch', 'tee', 'truncate', 'unlink', 'rmdir', 'install', 'rsync', 'shred', 'dd', 'mkdir', 'mkfifo', 'setfacl', 'chattr'}
DEST_ONLY = {'cp', 'ln', 'install'}
SHELLS = {'bash', 'sh', 'zsh', 'dash', 'ksh', 'mksh', 'fish', 'busybox'}
INTERP = re.compile(r'(python[\d.]*|pypy3?|perl|php[\d.]*|node|nodejs|ruby|deno|bun|lua[\d.]*|tclsh|Rscript|osascript)\Z')
CODE_FLAG = re.compile(r'-[a-zA-Z]*[ceErp]\Z|--(eval|print|command)\Z')
RISKY_CODE = re.compile(r'\bgit\b|\.git|\bpty\b|subprocess|system|\bexec\b|exec[lvS_F(]|spawn|popen|passthru|proc_open|fork|hooks'
                        r'|unlink|remove|rmtree|rename|chmod|symlink|`|\\x[0-9a-f]|\bchr\s*\(|base64|\beval\b|__import__|getattr'
                        r'|compile|child_process|writefile|file_put_contents|fopen|\bqx\b|shutil|\bos\.', re.I)
# A program start, and a changed environment or pseudo-terminal for it: together they can run git
# without the agent markers, whatever the code spells the program's name with.
EXEC_PRIM = re.compile(r'exec[lv]p?e?\b|os\.exec|subprocess|child_process|\bspawn|os\.system|\bsystem\s*\(|popen|proc_open|passthru', re.I)
STRIP_ENV = re.compile(r'environ|\benv\s*[=:\[]|putenv|unsetenv|clearenv|process\.env|%ENV|\$ENV\b|\bpty\b|\bscript\b', re.I)
READ_ONLY = {'cat', 'less', 'more', 'head', 'tail', 'grep', 'egrep', 'fgrep', 'rg', 'ag', 'ls', 'stat', 'file', 'wc', 'jq', 'yq',
             'diff', 'cmp', 'sort', 'uniq', 'cut', 'tr', 'echo', 'printf', 'true', 'false', 'pwd', 'realpath', 'readlink', 'dirname',
             'basename', 'test', '[', 'which', 'type', 'du', 'df', 'tree', 'column', 'nl', 'od', 'hexdump', 'xxd', 'md5sum',
             'sha1sum', 'sha256sum', 'date', 'whoami', 'id', 'sed', 'find', 'popd', 'dirs', 'comm', 'fold', 'rev', 'strings'}
GIT_READ = {'status', 'log', 'show', 'diff', 'rev-parse', 'grep', 'ls-files', 'ls-tree', 'cat-file', 'blame', 'describe', 'shortlog',
            'rev-list', 'merge-base', 'name-rev', 'whatchanged', 'show-ref', 'for-each-ref', 'help', 'version', 'var', 'check-ignore',
            'count-objects', 'diff-tree', 'diff-index', 'diff-files', 'range-diff', 'annotate', 'cherry'}
GIT_NO_HOOK = {'commit-tree', 'update-ref', 'send-pack', 'http-push', 'fast-import', 'receive-pack', 'hook', 'replace', 'filter-branch', 'filter-repo'}
VERIFY_SUBS = {'commit', 'merge', 'am', 'rebase', 'cherry-pick', 'revert', 'push', 'pull'}
MESSAGE_SUBS = {'commit', 'merge', 'tag', 'stash', 'revert', 'pull'}
VALUE_OPTS = {'-m', '-F', '-C', '-c', '-t', '-o', '--message', '--file', '--reuse-message', '--reedit-message', '--fixup', '--squash', '--author', '--date', '--template', '--cleanup', '--trailer', '--push-option', '--pathspec-from-file'}
# Wrappers run the command after their own options; the value-taking options are listed so the value is not taken for the command.
WRAPPERS = {'sudo': {'-u', '-g', '-C', '-D', '-h', '-p', '-r', '-t', '-U', '-T', '--user', '--group', '--chdir', '--host', '--prompt', '--role', '--type', '--other-user', '--close-from', '--command-timeout'},
            'doas': {'-u', '-C'}, 'nice': {'-n', '--adjustment'}, 'ionice': {'-c', '-n', '-p', '-P', '-u', '--class', '--classdata', '--pid', '--pgid', '--uid'},
            'timeout': {'-s', '-k', '--signal', '--kill-after'}, 'stdbuf': {'-i', '-o', '-e', '--input', '--output', '--error'},
            'flock': {'-w', '-E', '--timeout', '--conflict-exit-code'}, 'chrt': set(), 'taskset': set(), 'setsid': set(), 'nohup': set(),
            'time': {'-f', '-o', '--format', '--output'}, 'env': {'-C', '--chdir'}, 'coproc': set(), 'command': set(), 'exec': {'-a'},
            'builtin': set(), 'unbuffer': set(), 'caffeinate': set(), 'nocache': set(), 'chronic': set(), 'torsocks': set(), 'strace': {'-o', '-e', '-p'},
            'ltrace': {'-o', '-e'}, 'valgrind': set(), 'firejail': set(), 'unshare': set(), 'nsenter': {'-t'}, 'xargs': {'-n', '-L', '-I', '-d', '-E', '-P', '-s', '-a', '--arg-file', '--delimiter', '--max-args', '--max-procs', '--replace'},
            'parallel': {'-j', '-S', '--jobs'}, '!': set(), '{': set(), '}': set(), 'then': set(), 'do': set(), 'else': set(),
            'elif': set(), 'if': set(), 'while': set(), 'until': set(), 'function': set()}
FIRST_POSITIONAL = {'flock', 'chrt', 'taskset', 'timeout'}
BLIND_ARGS = {'xargs', 'parallel'}
# Programs that start a command in a fresh environment or outside this process tree, so the agent
# markers the override checks never reach it; tmux only through the subcommands that run one.
LAUNCHERS = {'systemd-run', 'at', 'batch', 'screen', 'dbus-run-session', 'busctl'}
# systemctl starts a unit the user manager runs, outside this process tree.
SYSTEMCTL_RUN = {'start', 'restart', 'try-restart', 'reload-or-restart', 'try-reload-or-restart', 'run'}
TMUX_RUN = {'new-session', 'new', 'new-window', 'neww', 'send-keys', 'send', 'split-window', 'splitw', 'respawn-pane', 'respawn-window', 'run-shell', 'run'}
JOINED_SCRIPT = {'watch', 'ssh', 'su', 'runuser'}
REMOTE = {'docker', 'podman', 'kubectl', 'nerdctl', 'lxc', 'vagrant'}


class Deny(Exception):
    pass


class Ctx:
    def __init__(self, cwd):
        self.cwd, self.origin, self.written, self.flags, self.repo = cwd, cwd, set(), set(), repo_root(cwd)
        self.gitdirs = None
        # GIT_DIR and GIT_WORK_TREE assigned or exported so far, each as the value and its absolute
        # form at the assignment; None for a value computed at run time.
        self.gitenv = {}
        # cd - and popd return to these; cwd_known is False once a cd target is computed at run time.
        self.oldpwd, self.dirstack, self.cwd_known = None, [], True
        self.seg, self.remote = {'words': [], 'redirs': [], 'heredoc': ''}, False


def repo_root(start):
    d = os.path.realpath(start)
    while d != '/':
        if os.path.lexists(os.path.join(d, '.git')):
            return d
        d = os.path.dirname(d)
    return None


def base(w):
    return os.path.basename(w)


def needle(word, plugin=True):
    """The first needle in word other than a soft one, then the plugin path when plugin."""
    t = re.sub(r'/+', '/', word.lower()).replace('/./', '/').replace('--no-verify-signatures', '')
    hit = next((n for n in NEEDLES if n in t and n not in SOFT_NEEDLES), None)
    return hit or (m.group(1) if plugin and (m := PLUGIN_RE.search(t)) else None)


def check_needles(words, what, plugin=True):
    for w in words:
        hit = needle(w, plugin=plugin)
        if hit:
            raise Deny(f'{what} names {hit}, which only a read may mention')
        soft = next((n for n in SOFT_NEEDLES if n in w.lower()), None)
        if soft:
            DEFERRED.append(f'{what} names {soft} in a command that also names git, a hook or the plugin')


def in_plugin(p):
    return any(p == r or p.startswith(r + '/') for r in PLUGIN_ROOTS)


def in_tmp_elsewhere(p, ctx):
    tmp = os.path.realpath(os.environ.get('TMPDIR') or '/tmp')
    inside_repo = ctx.repo and (p == ctx.repo or p.startswith(ctx.repo + '/'))
    return (p.startswith('/tmp/') or p.startswith(tmp + '/')) and not inside_repo


def protected(tok, ctx):
    if needle(tok):
        return True
    if tok.dynamic:
        # The part spelled before the first expansion still names where the write lands.
        prefix = re.split(r'[$`]', str(tok), maxsplit=1)[0]
        p = os.path.realpath(os.path.join(ctx.cwd, prefix)) if prefix else None
        if p and (in_plugin(p) or p.startswith(INSTALLED + '/') or '.git' in prefix.split('/')
                  or write_denials.denial(os.path.normpath(os.path.join(ctx.cwd, prefix)), PLUGIN)):
            return True
        defer_dynamic(f'the target {tok}')
        return False
    for c in glob.glob(os.path.join(ctx.cwd, tok)) if re.search(r'[*?[]', tok) else [tok]:
        p = os.path.realpath(os.path.join(ctx.cwd, c))
        if needle(p) or in_plugin(p) or p.startswith(INSTALLED + '/'):
            return True
        if write_denials.denial(os.path.normpath(os.path.join(ctx.cwd, c)), PLUGIN):
            return True
        # The git dir and common dir of the current repo and of the repo the target sits in, wherever
        # they live; then any path through a .git directory, except a scratch repo under the temp dir.
        if any(p == d or p.startswith(d + '/') for d in git_dirs(ctx) | target_git_dirs(p, ctx)):
            return True
        if in_tmp_elsewhere(p, ctx):
            continue
        if '.git' in p.split('/'):
            return True
        root = repo_root(os.path.dirname(p))
        if root and p.startswith(root + '/') and any(p[len(root) + 1:] == g or p[len(root) + 1:].startswith(g + '/') for g in GATE_FILES):
            return True
    return False


def target_git_dirs(p, ctx):
    """The git dir and common dir of the repo that holds path p, so a write into another repo's git
    directory by absolute path is denied too. In a temp-dir scratch repo outside the current one, none."""
    if in_tmp_elsewhere(p, ctx):
        return set()
    d = os.path.dirname(p)
    while d and d != '/' and not os.path.isdir(d):
        d = os.path.dirname(d)
    try:
        out = subprocess.run(['git', '-C', d or '/', 'rev-parse', '--path-format=absolute', '--git-dir', '--git-common-dir'],
                             capture_output=True, text=True, timeout=5).stdout
    except (OSError, subprocess.SubprocessError):
        return set()
    return {os.path.realpath(x) for x in out.split('\n') if x}


def git_dirs(ctx):
    """The git dir and common dir of the cwd's repo, resolved once: a write anywhere inside them is denied."""
    if ctx.gitdirs is None:
        try:
            out = subprocess.run(['git', '-C', ctx.origin, 'rev-parse', '--path-format=absolute', '--git-dir', '--git-common-dir'],
                                 capture_output=True, text=True, timeout=5).stdout
        except (OSError, subprocess.SubprocessError):
            out = ''
        ctx.gitdirs = {os.path.realpath(d) for d in out.split('\n') if d}
    return ctx.gitdirs


def check_name(name, via_env=False):
    """A name an agent may not assign, export or pass through env. BASH_FUNC_*, a non-identifier
    passed through env and the agent markers always deny; the other names that change what bash,
    git or the loader runs deny only in a command that also names git, a hook, qg or the plugin."""
    if name.startswith('BASH_FUNC_'):
        raise Deny(f'{name} exports a shell function to every bash the commit gate starts')
    if not IDENT.match(name):
        if via_env:
            raise Deny(f'{name} is no plain identifier; only env can set it, and bash would import it')
        DEFERRED.append(f'{name} is no plain identifier, in a command that names git, a hook, qg or the plugin')
        return
    if name in MARKERS:
        raise Deny(f'{name} is the agent marker the commit gate reads; an agent may not change or clear it')
    if name in DENIED_NAMES:
        DEFERRED.append(f'{name} changes what bash, git or the loader runs, in a command that names git, a hook, qg or the plugin')


def check_var(name, value, ctx, dynamic=False):
    check_name(name)
    if name in ('GIT_DIR', 'GIT_WORK_TREE'):
        ctx.gitenv[name] = None if dynamic else (value, os.path.join(ctx.cwd, value))
    if GATE_VAR.match(name):
        raise Deny(f'{name} is read by the commit gate; an agent may not set it')
    if name == 'HUSKY' and value == '0':
        raise Deny('HUSKY=0 switches the hooks off')
    if name in ENV_REDIRECT:
        ctx.flags.add('env-redirect')


def check_git(a, ctx, cwd):
    i, where = 0, []
    while i < len(a) and a[i].startswith('-'):
        t = a[i]
        if t.startswith('--config-env'):
            raise Deny('git --config-env can point core.hooksPath elsewhere')
        if t.startswith('-c'):
            kv = t[2:] or (a[i + 1] if i + 1 < len(a) else '')
            i += t == '-c'
            check_git_key(kv.split('=', 1)[0])
        elif t == '-C' and i + 1 < len(a):
            if a[i + 1].dynamic:
                raise Deny(f'git -C {a[i + 1]} is computed at run time, so the hook cannot see which repository it changes')
            cwd = os.path.join(cwd, a[i + 1])
            i += 1
        elif t in ('--git-dir', '--work-tree') and i + 1 < len(a):
            where.append(a[i + 1])
            i += 1
        elif t.startswith(('--git-dir=', '--work-tree=')):
            where.append(t.split('=', 1)[1] if not t.dynamic else t)
        elif t in ('--namespace', '--exec-path', '--super-prefix'):
            i += 1
        elif t.startswith('--exec-path'):
            raise Deny('git --exec-path swaps the git programs that run the hooks')
        i += 1
    sub, rest = (a[i], a[i + 1:]) if i < len(a) else ('', [])
    ctx.flags.update(('git', 'git-here'))
    msg = message_indices(sub, rest)
    for j, t in enumerate(rest):
        if t.dynamic and j not in msg:
            raise Deny(f'git {sub} argument {t} is computed at run time, so the hook cannot read it')
    if sub in GIT_NO_HOOK:
        raise Deny(f'git {sub} writes objects or refs, or runs hooks, outside the commit path the gate checks')
    if sub == 'mktree' or (sub == 'hash-object' and '-w' in rest and any(
            t == 'commit' and j > 0 and rest[j - 1] == '-t' or str(t) == '-tcommit' or str(t) == '--type=commit' for j, t in enumerate(rest))):
        raise Deny(f'git {sub} writes a tree or commit object outside the commit path the gate checks')
    if sub == 'config':
        check_git_config(rest)
    if sub == 'branch' and any(t in ('-u', '--set-upstream-to') or str(t).startswith('--set-upstream-to=') or str(t).startswith('-u') and len(str(t)) > 2 and not str(t).startswith('--') for t in rest):
        raise Deny('git branch -u retargets the upstream the stop hook reads; push with git push -u instead')
    if sub in VERIFY_SUBS:
        check_no_verify(sub, rest)
    if not git_is_read(sub, rest):
        check_git_tree(sub, rest, ctx, cwd, where)
    check_ref_writers(sub, rest, ctx, cwd)


BRANCH_LIST = {'-a', '-r', '-v', '-vv', '-l', '--all', '--remotes', '--verbose', '--list', '--show-current', '--no-color', '--color'}
BRANCH_LIST_VALUE = ('--contains', '--merged', '--no-merged', '--format', '--sort', '--points-at')


def git_is_read(sub, rest):
    return sub in GIT_READ or (sub == 'config' and git_config_is_read(rest)) \
        or (sub == 'branch' and all(t in BRANCH_LIST or t.startswith(BRANCH_LIST_VALUE) for t in rest)) \
        or (sub == 'notes' and rest[:1] in ([], ['list'], ['show'])) \
        or (sub == 'worktree' and rest[:1] == ['list']) or (sub == 'stash' and rest[:1] in (['list'], ['show'])) \
        or (sub == 'remote' and rest[:1] in ([], ['-v'], ['--verbose'], ['get-url'], ['show']))


def check_git_tree(sub, rest, ctx, cwd, where):
    """A git command that writes may not have its work tree, git dir or output prefix inside the
    protected main worktree: the cwd after -C, --work-tree, --git-dir, GIT_WORK_TREE, GIT_DIR,
    checkout-index --prefix and the folder of worktree add, each resolved with realpath."""
    if not ctx.cwd_known:
        raise Deny(f'git {sub} runs in a folder a cd computed at run time, so the hook cannot see which repository it changes')
    paths = [cwd] + where
    for k in ('GIT_DIR', 'GIT_WORK_TREE'):
        # The value as git reads it from the cwd now, and as it pointed when it was assigned.
        if k in ctx.gitenv:
            paths += list(ctx.gitenv[k]) if ctx.gitenv[k] else [None]
    if sub == 'checkout-index':
        paths += [rest[j + 1] for j, t in enumerate(rest[:-1]) if t == '--prefix'] + [t[9:] for t in rest if t.startswith('--prefix=')]
    if sub == 'worktree' and rest[:1] == ['add']:
        skip = False
        for t in rest[1:]:
            if skip:
                skip = False
            elif t.startswith('-'):
                skip = t in ('-b', '-B', '--reason')
            else:
                paths.append(t)
                break
    for p in paths:
        if p is None or getattr(p, 'dynamic', False) or '$' in p:
            raise Deny(f'git {sub} works on a repository the hook cannot see before it runs')
        real = os.path.realpath(os.path.join(ctx.cwd, cwd, p))
        if in_plugin(real):
            raise Deny(f'git {sub} changes {real}, inside the plugin main worktree {MAIN}, which only a human changes')


def check_ref_writers(sub, rest, ctx, cwd):
    if sub == 'notes' and rest and rest[0] not in ('list', 'show', '--help'):
        raise Deny('git notes writes commits on refs/notes without any hook')
    if sub == 'stash' and rest[:1] == ['store']:
        raise Deny('git stash store moves a ref to an arbitrary commit')
    if sub == 'tag' and any(t == '--force' or re.match(r'-[a-zA-Z]*f', t) for t in rest):
        raise Deny('git tag -f moves an existing tag')
    if sub == 'rebase' and any(re.match(r'(-[a-zA-Z]*x|--exec)', t) for t in rest):
        raise Deny('git rebase --exec runs commands the hook cannot see')
    if sub == 'commit' and '--allow-empty' in rest:
        raise Deny('git commit --allow-empty is not an agent task')
    if sub == 'clone':
        ctx.flags.add('clone')
        vals = {'-b', '--branch', '-o', '--origin', '--depth', '--reference', '--reference-if-able', '-c', '--config',
                '--template', '-u', '--upload-pack', '-j', '--jobs', '--filter', '--separate-git-dir',
                '--shallow-since', '--shallow-exclude', '--server-option', '--bundle-uri', '--ref-format'}
        pos, skip = [], False
        for t in rest:
            if skip or t == '--':
                skip = False
            elif t.startswith('-'):
                skip = t in vals
            else:
                pos.append(t)
        check_targets('git clone', pos[1:2], ctx)
    if sub == 'push':
        ctx.flags.add('push')
        for t in rest:
            if t in ('--mirror', '--force', '--force-with-lease', '--force-if-includes', '--push-option', '--receive-pack', '--exec') \
                    or t.startswith(('--force-with-lease=', '--push-option=', '--receive-pack=', '--exec=')) \
                    or re.match(r'-[a-zA-Z]*[fo]', t) or (t.startswith('+') and len(t) > 1):
                raise Deny(f'git push {t} is refused for an agent (force, mirror and push options)')
        check_push_dir(cwd, ctx)


def check_push_dir(cwd, ctx):
    here = os.path.realpath(cwd)
    try:
        out = subprocess.run(['git', '-C', ctx.origin, 'worktree', 'list', '--porcelain'], capture_output=True, text=True, timeout=5).stdout
    except (OSError, subprocess.SubprocessError):
        out = ''
    trees = [os.path.realpath(l[9:]) for l in out.split('\n') if l.startswith('worktree ')]
    if not any(here == t or here.startswith(t + '/') for t in trees):
        raise Deny(f'git push from {here} leaves the worktrees of the repository this session works in')


def message_indices(sub, rest):
    """Indices in rest that hold a QUOTED message value; only those are exempt from the word checks."""
    out, take = set(), False
    if sub not in MESSAGE_SUBS:
        return out
    for j, t in enumerate(rest):
        if take:
            take = False
            if t.quoted:
                out.add(j)
            continue
        if t == '--':
            break
        if t in ('-m', '--message'):
            take = True
        elif (t.startswith('--message=') or re.match(r'-[a-zA-Z]*m.', t)) and t.quoted:
            out.add(j)
        elif sub == 'commit' and re.match(r'-[a-zA-Z]*m\Z', t):
            take = True
    return out


def check_git_key(key):
    k = key.lower()
    if k in ('core.hookspath', 'include.path', 'core.fsmonitor', 'core.sshcommand') or k.startswith(('alias.', 'includeif.')) or k.endswith('receivepack'):
        raise Deny(f'git config key {key} can disable or reroute the hooks')
    if k.startswith('branch.') and k.endswith(('.remote', '.merge', '.pushremote')):
        raise Deny(f'git config key {key} retargets a branch upstream, which the stop hook reads; push with git push -u instead')


def git_config_is_read(rest):
    if any(t in ('--get', '--get-all', '--get-regexp', '--get-urlmatch', '--list', '-l', 'get', 'list') for t in rest):
        return True
    pos = [t for t in rest if not t.startswith('-')]
    return len(pos) == 1 and re.match(r'[\w.-]+\Z', pos[0]) is not None and not any(t.startswith(('--unset', '--add', '--replace-all', '--rename-section', '--remove-section', '--edit', '-e')) for t in rest)


def check_git_config(rest):
    if git_config_is_read(rest):
        return
    if any(t in ('--edit', '-e') for t in rest):
        raise Deny('git config --edit can rewrite core.hooksPath')
    pos, skip = [], False
    for t in rest:
        if skip or t.startswith('-'):
            skip = not skip and t in ('--file', '-f', '--blob', '--type', '--default', '--comment', '--value')
        else:
            pos.append(t)
    verb = pos[0] in ('set', 'unset') if pos else False
    for key in pos[1:2] if verb else pos[:1]:
        check_git_key(key)


def check_no_verify(sub, rest):
    skip = False
    for t in rest:
        if skip or t == '--':
            skip = False
            if t == '--':
                break
            continue
        name = t.split('=', 1)[0]
        if len(name) >= 8 and '--no-verify'.startswith(name):
            raise Deny(f'git {sub} {t} skips the commit gate')
        if sub == 'commit' and re.match(r'-[^-]', t):
            skip = commit_cluster(t)
        else:
            skip = t in VALUE_OPTS


def commit_cluster(t):
    """Walks a short-flag cluster of git commit; returns True when the next token is its value."""
    for k, ch in enumerate(t[1:]):
        if ch == 'n':
            raise Deny(f'git commit {t} carries -n (--no-verify)')
        if ch in 'mFcCt':
            return len(t) == k + 2
        if ch in 'Su':
            return False
    return False


def git_exempt(args):
    """Word indices of a git call exempt from the needle check: all of a read, else the quoted messages."""
    i = 0
    while i < len(args) and args[i].startswith('-'):
        i += 2 if args[i] in ('-c', '-C', '--git-dir', '--work-tree', '--namespace') else 1
    sub, rest = (args[i], args[i + 1:]) if i < len(args) else ('', [])
    if git_is_read(sub, rest):
        return set(range(len(args)))
    return {i + 1 + j for j in message_indices(sub, rest)}


def check_gh(a):
    if a[:1] != ['api'] or not any('git/refs' in t or re.search(r'(^|/)contents(/|\?|\Z)', t) for t in a):
        return
    method = next((a[j + 1] for j, t in enumerate(a[:-1]) if t in ('-X', '--method')), None)
    method = method or next((t.split('=', 1)[1] if '=' in t else t[2:] for t in a if t.startswith(('--method=', '-X')) and t != '-X'), None)
    fields = any(re.match(r'(-[fF]|--field|--raw-field|--input)', t) for t in a)
    if (method or '').upper() in ('POST', 'PUT', 'PATCH', 'DELETE') or (method is None and fields):
        raise Deny('gh api writes refs or file contents without any hook')


def read_script(path, ctx):
    p = os.path.realpath(os.path.join(ctx.cwd, path))
    if p in ctx.written:
        raise Deny(f'{path} is written and then run in one command, so the hook cannot read what runs')
    try:
        with open(p, 'rb') as f:
            return f.read(2_000_000).decode('utf-8', 'replace')
    except OSError:
        raise Deny(f'{path} runs as a script but the hook cannot read it')


def protected_prefixes(repo):
    # The gate's own rule (lib/qg-config.sh): quality/config when committed, else VAULT.md; never both.
    for src in ('quality/config', 'VAULT.md'):
        try:
            r = subprocess.run(['git', '-C', repo, 'show', f'HEAD:{src}'], capture_output=True, text=True, timeout=5)
        except (OSError, subprocess.SubprocessError):
            return []
        if r.returncode == 0:
            m = re.search(r'^guard_protected_paths:[ \t]*(.*)$', r.stdout, re.M)
            return m.group(1).split() if m else []
    return []


def trusted_script(path, ctx):
    # A committed, unmodified script under a protected path was reviewed; changing it needs the human override.
    p = os.path.realpath(os.path.join(ctx.cwd, path))
    if not ctx.repo or p in ctx.written or not p.startswith(ctx.repo + '/'):
        return False
    rel = p[len(ctx.repo) + 1:]
    if not any(rel == pre or rel.startswith(pre.rstrip('/') + '/') for pre in protected_prefixes(ctx.repo)):
        return False
    try:
        tracked = subprocess.run(['git', '-C', ctx.repo, 'ls-files', '--error-unmatch', '--', rel], capture_output=True, timeout=5).returncode == 0
        clean = subprocess.run(['git', '-C', ctx.repo, 'diff', '--quiet', 'HEAD', '--', rel], capture_output=True, timeout=5).returncode == 0
    except (OSError, subprocess.SubprocessError):
        return False
    return tracked and clean


def installed_script(path, ctx):
    p = os.path.realpath(os.path.join(ctx.cwd, path))
    return p.startswith(INSTALLED + '/') and p not in ctx.written


def run_file(path, ctx, depth, shell):
    if trusted_script(path, ctx) or installed_script(path, ctx):
        return
    text = read_script(path, ctx)
    if shell or re.match(r'#!.*\b(ba|z|da|k)?sh\b', text):
        scan_script(text, ctx, depth + 1, from_file=True)
    else:
        check_code(f'the script {path}', text, inline=False)


def is_read_only(cmd, args):
    if cmd not in READ_ONLY:
        return False
    if cmd == 'sed':
        return not any(re.match(r'(-[a-zA-Z]*i|--in-place)', t) for t in args)
    if cmd == 'find':
        return not any(re.match(r'-(delete|exec|execdir|ok|okdir|fprint|fprint0|fprintf|fls)\Z', t) for t in args)
    if cmd == 'printf':
        return '-v' not in args
    return True


def unwrap(cmd, w, ctx):
    """Returns (inner words, cwd for them) after a wrapper's own options."""
    vals, i, cwd = WRAPPERS[cmd], 1, ctx.cwd
    if cmd == 'env':
        for t in w[1:]:
            if not t.startswith('-'):
                break
            if t in ('-', '--ignore-environment') or t.startswith('--unset') or (t[1:2] != '-' and re.search('[iu]', t)):
                raise Deny('env -i / env -u strips the agent markers')
            if t.startswith(('-S', '--split-string')) or (t[1:2] != '-' and 'S' in t):
                raise Deny('env -S runs a string the hook would have to re-parse')
    k = 1
    while cmd == 'exec' and k < len(w) and w[k].startswith('-') and w[k] != '--':
        if 'c' in w[k][1:]:
            raise Deny('exec -c runs the command with an empty environment, without the agent markers')
        k += 2 if w[k] == '-a' else 1
    if cmd == 'flock' and any(t in ('-c', '--command') for t in w):
        raise Deny('flock -c runs a shell string the hook cannot see')
    while i < len(w) and w[i].startswith('-') and w[i] != '--':
        if w[i] in vals and i + 1 < len(w):
            if w[i] in ('-C', '--chdir'):
                cwd = os.path.join(cwd, w[i + 1])
            i += 1
        i += 1
    i += w[i:i + 1] == ['--']
    if cmd == 'env':
        # env sets every word holding = before the program, identifier or not; each is checked here,
        # and the identifiers again as assignments of the command they precede.
        j = i
        while j < len(w) and '=' in w[j]:
            check_name(w[j].split("=", 1)[0], via_env=True)
            j += 1
    if cmd in FIRST_POSITIONAL and i < len(w):
        i += 1
    return w[i:], cwd


def scan_words(w, ctx, depth, remote=False):
    i = 0
    while i < len(w) and (m := re.match(r'([A-Za-z_]\w*)=(.*)\Z', w[i], re.S)):
        check_needles([w[i]], 'the assignment')
        check_var(m.group(1), m.group(2), ctx, w[i].dynamic)
        i += 1
    names, w = {re.match(r'\w+', t).group(0) for t in w[:i]}, w[i:]
    if not w:
        return
    remote = remote or ctx.remote
    ctx.flags.discard('git-here')
    scan_program(w, ctx, depth, remote)
    if names & ENV_REDIRECT and ('git-here' in ctx.flags or os.path.realpath(os.path.join(ctx.cwd, w[0])) == GUARD_SH):
        raise Deny('HOME, XDG_CONFIG_HOME or PATH set for git changes which config and which git run')


def scan_program(w, ctx, depth, remote):
    cmd, args = base(w[0]), w[1:]
    if w[0].dynamic:
        defer_dynamic(f'the command word {w[0]}')
    if cmd == 'script' or cmd == 'eval' and any(t.dynamic for t in args):
        raise Deny(f'{cmd} runs text the hook cannot see before it runs')
    if cmd in LAUNCHERS or (cmd == 'tmux' and any(t in TMUX_RUN for t in args)) \
            or (cmd == 'systemctl' and any(t in SYSTEMCTL_RUN for t in args)):
        raise Deny(f'{cmd} starts a command outside this process tree, without the agent markers the gate reads')
    if cmd in WRAPPERS or cmd in REMOTE:
        return scan_wrapper(cmd, w, ctx, depth, remote)
    if cmd in JOINED_SCRIPT:
        return scan_joined(cmd, w, ctx, depth)
    if os.path.realpath(os.path.join(ctx.cwd, w[0])) == GUARD_SH and '/' in w[0]:
        return scan_guard(args)
    if w[0] == 'qg' or ('/' in w[0] and os.path.realpath(os.path.join(ctx.cwd, w[0])) == QG_SH):
        ctx.flags.add('qg')
        return scan_qg(args)
    if cmd in ('cd', 'pushd', 'popd'):
        return track_cwd(cmd, args, ctx)
    # An installed plugin program may take the plugin path as an argument (a vault command naming
    # this repo); its redirects and the commands chained to it are still checked.
    installed = '/' in w[0] and installed_script(w[0], ctx)
    if is_read_only(cmd, args):
        exempt = set(range(len(w)))
    elif cmd == 'git':
        exempt = {j + 1 for j in git_exempt(args)}
    elif cmd in DEST_ONLY:
        exempt = {j + 1 for j in source_operands(args)}
    elif cmd == 'sed':
        exempt = {j + 1 for j, t in enumerate(args) if not t.startswith('-')}
        exempt -= {len(w) - 1} if len(w) > 2 else set()
    else:
        exempt = set()
    check_needles([t for j, t in enumerate(w) if j not in exempt], cmd, plugin=not installed)
    scan_command(cmd, w, args, ctx, depth, remote)


def track_cwd(cmd, args, ctx):
    """cd, pushd and popd move the checked cwd as bash would: a bare cd goes HOME, cd - to OLDPWD,
    pushd and popd through a directory stack. A target computed at run time, a stack rotation or an
    empty stack makes the cwd unknown, and a writing git command after it is denied."""
    ops = [t for t in args if t not in ('-L', '-P', '-e', '-n', '--')]
    here = ctx.cwd
    if any(t.dynamic for t in ops) or (cmd != 'cd' and any(re.match(r'[+-]\d+\Z', t) for t in ops)):
        ctx.cwd_known = False
        return
    if cmd == 'popd':
        if not ctx.dirstack:
            ctx.cwd_known = False
            return
        ctx.cwd = ctx.dirstack.pop()
    elif cmd == 'cd' and ops[:1] == ['-']:
        if ctx.oldpwd is None:
            ctx.cwd_known = False
            return
        ctx.cwd = ctx.oldpwd
    elif cmd == 'pushd' and not ops:
        if not ctx.dirstack:
            ctx.cwd_known = False
            return
        ctx.cwd, ctx.dirstack[-1] = ctx.dirstack[-1], here
        ctx.oldpwd = here
        return
    else:
        ctx.cwd = os.path.join(ctx.cwd, ops[0]) if ops else HOME
        if cmd == 'pushd':
            ctx.dirstack.append(here)
    ctx.oldpwd = here


def scan_command(cmd, w, args, ctx, depth, remote):
    if cmd == 'git':
        check_git(args, ctx, ctx.cwd)
    elif cmd == 'gh':
        check_gh(args)
    elif cmd in DECLARE or cmd in ('unset', 'read') or (cmd == 'printf' and '-v' in args):
        check_declare(cmd, args, ctx)
    elif cmd == 'eval':
        scan_script(' '.join(args), ctx, depth + 1)
    elif cmd in SHELLS:
        scan_shell(args, w, ctx, depth, remote)
    elif cmd in ('source', '.') and args:
        run_file(args[0], ctx, depth, True)
    elif INTERP.match(cmd):
        scan_interpreter(cmd, args, w, ctx, depth, remote)
    elif cmd in ('awk', 'gawk', 'mawk', 'nawk') and any(re.search(r'system\s*\(|\|\s*"|"\s*\|', t) for t in args):
        raise Deny(f'{cmd} runs a command through system() or a pipe')
    elif cmd == 'find':
        scan_find(args, ctx, depth)
    elif cmd == 'sort':
        targets = [args[j + 1] for j, t in enumerate(args[:-1]) if t == '-o'] + [t[2:] for t in args if t.startswith('-o') and len(t) > 2]
        check_targets('sort', targets, ctx)
    elif '/' in w[0] and not remote and cmd != 'git' and script_header(w[0], ctx) == b'#!':
        run_file(w[0], ctx, depth, False)
    check_targets(cmd, write_form_targets(cmd, args), ctx)
    if cmd in WRITERS or (cmd in ('sed', 'perl') and any(re.match(r'(-[a-zA-Z]*i|--in-place)', t) for t in args)):
        drop = source_operands(args) if cmd in DEST_ONLY else script_operand(cmd, args)
        check_targets(cmd, [t for j, t in enumerate(args) if not t.startswith('-') and j not in drop], ctx)


def write_form_targets(cmd, args):
    """The folders and files tar, unzip, curl, wget and dd write into, from their options."""
    opts = {'tar': ('-C', '--directory'), 'bsdtar': ('-C', '--directory'), 'unzip': ('-d',),
            'curl': ('-o', '--output', '--output-dir'), 'wget': ('-O', '--output-document', '-P', '--directory-prefix')}.get(cmd, ())
    out = [(t, t[3:]) for t in args if cmd == 'dd' and t.startswith('of=')]
    for j, t in enumerate(args):
        if t in opts and j + 1 < len(args):
            out.append((args[j + 1], args[j + 1]))
        elif t.startswith('--') and t.split('=', 1)[0] in opts and '=' in t:
            out.append((t, t.split('=', 1)[1]))
        elif not t.startswith('--') and t[:2] in opts and len(t) > 2:
            out.append((t, t[2:]))
    words = []
    for src, value in out:
        if value and value != '-':
            w = Word(value)
            w.quoted, w.dynamic = src.quoted, src.dynamic
            words.append(w)
    return words


def check_declare(cmd, args, ctx):
    """export, declare, typeset, readonly, local, unset, read and printf -v: the names they set."""
    minus = ''.join(t[1:] for t in args if re.match(r'-[A-Za-z]', t))
    if cmd == 'export' and 'f' in minus:
        raise Deny('export -f hands a shell function to every bash the commit gate starts')
    if cmd in ('declare', 'typeset') and 'f' in minus and 'x' in minus:
        raise Deny(f'{cmd} -f -x hands a shell function to every bash the commit gate starts')
    if cmd in ('unset', 'read', 'printf'):
        names = [args[j + 1] for j, t in enumerate(args[:-1]) if t == '-v'] if cmd == 'printf' else args
        hit = next((t for t in names if t in MARKERS), None)
        if hit:
            raise Deny(f'{cmd} {hit} clears the agent marker the commit gate reads')
        for t in names:
            if cmd == 'unset':
                ctx.gitenv.pop(t, None)
            elif t in ('GIT_DIR', 'GIT_WORK_TREE'):
                ctx.gitenv[t] = None  # read and printf -v set a value the hook cannot see
        return
    for t in args:
        if not t.startswith(('-', '+')):
            name, eq, value = t.partition('=')
            name = name[:-1] if eq and name.endswith('+') else name
            if eq:
                check_var(name, value, ctx, t.dynamic)
            else:
                check_name(name)


def script_operand(cmd, args):
    """sed and perl -i: the index of the program text when no -e/-f carries it, so it is not taken for a file."""
    if cmd not in ('sed', 'perl') or any(re.match(r'(-[a-zA-Z]*[ef]|--expression|--file)', t) for t in args):
        return set()
    return set([j for j, t in enumerate(args) if not t.startswith('-')][:1])


def script_header(path, ctx):
    try:
        with open(os.path.join(ctx.cwd, path), 'rb') as f:
            return f.read(2)
    except OSError:
        return b''


def scan_joined(cmd, w, ctx, depth):
    """watch, ssh, su and runuser hand their arguments to a shell as one string."""
    check_needles(w, cmd)
    if cmd in ('su', 'runuser'):
        code = next((w[j + 1] for j, t in enumerate(w[:-1]) if t in ('-c', '--command')), None)
        return scan_script(code, ctx, depth + 1) if code is not None else None
    vals = {'-n', '-d', '--interval', '-q'} if cmd == 'watch' else {'-p', '-i', '-o', '-l', '-F', '-J', '-b', '-c', '-D', '-E', '-e', '-L', '-m', '-O', '-Q', '-R', '-S', '-W', '-w', '-B', '-I'}
    i = 1
    while i < len(w) and w[i].startswith('-'):
        i += 2 if w[i] in vals else 1
    i += cmd == 'ssh'
    ctx.remote, saved = cmd == 'ssh' or ctx.remote, ctx.remote
    scan_script(' '.join(w[i:]), ctx, depth + 1)
    ctx.remote = saved


def check_targets(cmd, targets, ctx):
    for t in targets:
        if protected(t, ctx):
            raise Deny(f'{cmd} touches {t}')
        ctx.written.add(os.path.realpath(os.path.join(ctx.cwd, t)))


def source_operands(args):
    """cp/ln/install: indices of the source operands (every operand but the destination)."""
    if any(t in ('-t', '--target-directory') or t.startswith('--target-directory=') for t in args):
        skip, out = False, set()
        for j, t in enumerate(args):
            if skip:
                skip = False
            elif t in ('-t', '--target-directory'):
                skip = True
            elif not t.startswith('-'):
                out.add(j)
        return out
    ops = [j for j, t in enumerate(args) if not t.startswith('-')]
    return set(ops[:-1])


def scan_wrapper(cmd, w, ctx, depth, remote):
    if cmd in REMOTE:
        check_needles(w, cmd)
        for j in range(1, len(w)):
            b = base(w[j])
            if b == 'git' or b in SHELLS or b in WRAPPERS or b in ('eval', 'script', 'env') or INTERP.match(b):
                ctx.remote, saved = True, ctx.remote
                scan_words(w[j:], ctx, depth, remote=True)
                ctx.remote = saved
        return
    inner, cwd = unwrap(cmd, w, ctx)
    check_needles(w[:len(w) - len(inner)], cmd)
    if cmd in BLIND_ARGS and inner:
        b = base(inner[0])
        if (b == 'git' and not git_exempt(inner[1:]) == set(range(len(inner) - 1))) or b in WRITERS or b in SHELLS \
                or b in WRAPPERS or b in ('eval', 'env', 'find', 'source', '.') or INTERP.match(b):
            raise Deny(f'{cmd} {b} adds arguments the hook cannot see')
    saved, ctx.cwd = ctx.cwd, cwd
    scan_words(inner, ctx, depth, remote)
    ctx.cwd = saved if cmd not in ('{', '}', 'then', 'do', 'else', 'elif', 'if', 'while', 'until', '!', 'function') else ctx.cwd


def scan_guard(args):
    ok = (args[:1] == ['verify'] and len(args) == 2) or args == ['report'] or args[:2] == ['hooks', 'status']
    if not ok:
        raise Deny('guard.sh ' + ' '.join(args) + ' changes the gate; an agent may run only verify <range>, report and hooks status')


def granted():
    """The actions of the operator's live grant (lib/qg-grant.sh holds the rules), or an empty set."""
    try:
        common = subprocess.run(['git', '-C', PLUGIN, 'rev-parse', '--path-format=absolute', '--git-common-dir'],
                                capture_output=True, text=True, timeout=5).stdout.strip()
        path = os.path.join(common, 'qg-grant')
        st = os.lstat(path)
        with open(path) as f:
            line = f.read()
    except (OSError, subprocess.SubprocessError):
        return set()
    if not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid() or st.st_mode & 0o022:
        return set()
    fields = line.rstrip('\n').split('\t')
    if '\n' in line.rstrip('\n') or len(fields) != 5 or fields[0] != 'v1' or not fields[4] \
            or not fields[1].isdigit() or not fields[2].isdigit() or not re.fullmatch(r'[a-z]+(,[a-z]+)*', fields[3]):
        return set()
    issued, expires, now = int(fields[1]), int(fields[2]), int(time.time())
    actions = set(fields[3].split(','))
    if not (issued <= now < expires and expires - issued <= GRANT_MAX) or not actions <= GRANT_ACTIONS:
        return set()
    return actions


def scan_qg(args):
    words = [a for a in args if a != '--json']
    sub = words[0] if words else 'help'
    if sub in QG_READS or words[:2] == ['hooks', 'status'] or words == ['hooks'] or words == ['grant', '--status']:
        return
    if sub == 'grant':
        raise Deny('qg grant issues or ends the operator grant; only a human at a separate terminal runs it')
    action = {'baseline': 'baseline', 'override': 'push' if '--push' in words else 'override'}.get(sub)
    if action and action in granted():
        return
    raise Deny(f'qg {sub} changes the gate; an agent may run only {", ".join(sorted(QG_READS))}, hooks status and grant --status'
               + (f', or qg {sub} while the operator grants {action}' if action else ''))


def scan_shell(args, w, ctx, depth, remote):
    j, has_c = 0, False
    while j < len(args) and re.match(r'[-+]', args[j]) and args[j] != '--':
        has_c = has_c or re.match(r'-[a-zA-Z]*c', args[j]) is not None
        j += 2 if args[j] in ('-O', '+O', '-o', '+o', '--rcfile', '--init-file') else 1
    j += args[j:j + 1] == ['--']
    if j >= len(args) and args and all(t in ('--version', '--help') for t in args) and not ctx.seg['heredoc']:
        return
    if j < len(args):
        if has_c:
            if args[j].dynamic:
                if not literal_text(args[j]):
                    raise Deny(f'{base(w[0])} -c runs text computed at run time')
                defer_dynamic(f'part of the {base(w[0])} -c text')
            return scan_script(str(args[j]), ctx, depth + 1)
        if not remote:
            run_file(args[j], ctx, depth, True)
        return
    stdin_script(base(w[0]), ctx, depth, True)


def stdin_script(cmd, ctx, depth, shell):
    seg = ctx.seg
    here = seg['heredoc'] or next((t for o, t in seg['redirs'] if o == '<<<'), None)
    src = next((t for o, t in seg['redirs'] if o == '<'), None)
    if here is not None:
        return scan_script(here, ctx, depth + 1) if shell else check_code(f'{cmd} code', here)
    if src is not None:
        return run_file(src, ctx, depth, shell)
    raise Deny(f'{cmd} reads its program from a pipe the hook cannot see')


def check_code(what, code, inline=True):
    """Interpreter code: needles and denied roots always. Inline or heredoc code that starts a
    program with a changed environment or a pseudo-terminal always, since it can spell the program's
    name to avoid every check. RISKY_CODE, script files included, once the input names git."""
    SEEN.append(code)
    check_needles([code], what)
    check_text_roots(code, what)
    if inline and EXEC_PRIM.search(code) and STRIP_ENV.search(code):
        raise Deny(f'{what} starts a program with a changed environment or a pseudo-terminal, which can drop the agent markers')
    m = RISKY_CODE.search(code)
    if m:
        DEFERRED.append(f'{what} uses {m.group(0)}, which can run git or rewrite files, in a command that names git, a hook or the plugin')


def check_text_roots(text, what):
    hit = write_denials.text_denial(text, PLUGIN)
    if hit:
        raise Deny(f'{what} names {hit[0]}: {hit[1]}')


def scan_interpreter(cmd, args, w, ctx, depth, remote):
    j = 0
    while j < len(args) and args[j].startswith('-') and args[j] != '-':
        t = args[j]
        if CODE_FLAG.match(t) and not (cmd.startswith('python') and t in ('-E',)) and j + 1 < len(args):
            if args[j + 1].dynamic:
                if not literal_text(args[j + 1]):
                    raise Deny(f'{cmd} {t} runs code computed at run time')
                defer_dynamic(f'part of the {cmd} {t} code')
            return check_code(f'{cmd} code', args[j + 1])
        if t == '-m' and j + 1 < len(args):
            if RISKY_CODE.search(args[j + 1]):
                DEFERRED.append(f'{cmd} -m {args[j + 1]} can run git or rewrite files, in a command that names git, a hook or the plugin')
            return
        if t == '-f' and cmd.startswith('php') and j + 1 < len(args):
            return None if remote else run_file(args[j + 1], ctx, depth, False)
        j += 1
    if j < len(args) and args[j] != '-':
        return None if remote else run_file(args[j], ctx, depth, False)
    reads_stdin = not args or args[j:j + 1] == ['-'] or ctx.seg['heredoc'] or any(o in ('<', '<<<') for o, _ in ctx.seg['redirs'])
    if reads_stdin and not remote:
        stdin_script(cmd, ctx, depth, False)


def scan_find(args, ctx, depth):
    k = next((j for j, t in enumerate(args) if t.startswith(('-', '(', '!'))), len(args))
    starts = args[:k] or ['.']
    destructive = '-delete' in args
    for j, t in enumerate(args):
        if t in ('-exec', '-execdir', '-ok', '-okdir'):
            end = next((e for e in range(j + 1, len(args)) if args[e] in (';', '+')), len(args))
            inner = args[j + 1:end]
            if inner and not is_read_only(base(inner[0]), inner[1:]):
                destructive = True
                scan_words(inner, ctx, depth)
        elif re.match(r'-f(print0?|printf|ls)\Z', t) and j + 1 < len(args):
            check_targets('find', [args[j + 1]], ctx)
    if not destructive:
        return
    for s in starts:
        p = os.path.realpath(os.path.join(ctx.cwd, s))
        if protected(s, ctx) or os.path.lexists(os.path.join(p, '.git')) or any(r.startswith(p + '/') for r in PLUGIN_ROOTS):
            raise Deny(f'find {s} with -delete or -exec reaches the git directory or the plugin; start it in a subdirectory')


def scan_seg(seg, ctx, depth):
    for o, t in seg['redirs']:
        # >&2 and >&- duplicate or close a descriptor; >&<file> writes a file like &> does.
        if o == '>&' and re.match(r'(\d+|-)\Z', t) and not t.dynamic:
            continue
        if o not in ('<', '<<', '<<-', '<<<', '<&') and t:
            check_targets('a redirect', [t], ctx)
    ctx.seg = seg
    scan_words(seg['words'], ctx, depth)


def scan_script(text, ctx, depth=0, from_file=False):
    """A shell script file adds only its words to SEEN, so its comments and usage text never turn a
    deferred finding into a denial; a command or code string the agent wrote adds all of its text."""
    if depth > 8:
        raise Deny('shell nesting deeper than 8 levels')
    lx = Lexer(text)
    segs = lx.parse()
    if lx.error:
        raise Deny(f'the command is incomplete: {lx.error}')
    SEEN.append(' '.join(str(w) for seg in segs + lx.subs for w in seg['words'] + [t for _, t in seg['redirs']])
                if from_file else text)
    for seg in segs + lx.subs:
        scan_seg(seg, ctx, depth)


def main():
    try:
        event = json.load(sys.stdin)
        command = (event.get('tool_input') or {}).get('command') or ''
        if event.get('tool_name', 'Bash') == 'Bash':
            ctx = Ctx(event.get('cwd') or os.getcwd())
            scan_script(command, ctx)
            if 'git' in ctx.flags and 'env-redirect' in ctx.flags:
                raise Deny('HOME, XDG_CONFIG_HOME or PATH changed in a command that runs git')
            # qg run push --ref records a pass that git push accepts unmeasured; shimmed tools must not write it.
            if 'qg' in ctx.flags and 'env-redirect' in ctx.flags:
                raise Deny('HOME, XDG_CONFIG_HOME or PATH changed in a command that runs qg')
            if {'clone', 'push'} <= ctx.flags:
                raise Deny('git clone and git push in one command push from a copy that has no hooks')
            if DEFERRED and any(NAMES_GIT.search(t) for t in SEEN):
                raise Deny(DEFERRED[0])
    except Deny as d:
        sys.stderr.write(f'guard-bash: denied: {d}. Fix what the commit gate reports instead; only the human at a terminal may override it.\n')
        sys.exit(2)
    except Exception as e:
        sys.stderr.write(f'guard-bash: denied: could not check this command ({type(e).__name__}: {e})\n')
        sys.exit(2)


main()
