"""Rules for guard-bash.sh: raises Deny for every form that skips, disables or forges the commit gate."""
import glob, json, os, re, subprocess, sys

from shell_lexer import Lexer

RAW_PLUGIN = sys.argv[1].rstrip('/') or '/'
PLUGIN = os.path.realpath(RAW_PLUGIN)
HOME = os.path.expanduser('~')
GUARD_SH = os.path.join(PLUGIN, 'bin', 'guard.sh')
# Any of these in a word of a command that is not a read denies it (compared lower-case, // collapsed).
NEEDLES = ('.git/hooks', '.git/config', 'guard-pass', 'guard_pass', 'guard-bypass', 'guard_bypass', 'guard-tree', 'guard_tree',
           'guard-cache', 'guard_cache', 'hookspath', 'send-pack', 'http-push', 'receive-pack', 'receivepack', 'fast-import',
           'fsmonitor', 'sshcommand', 'git_exec_path', 'git_config', 'qg_skip_reason', 'claudecode', 'ai_agent', '--no-veri',
           '.claude/settings', '.gitconfig', '.config/git/config', 'includeif', 'include.path')
PLUGIN_RE = re.compile('(%s)(/|\\Z)' % '|'.join(re.escape(p.lower()) for p in {PLUGIN, RAW_PLUGIN}))
ENV_REDIRECT = {'HOME', 'XDG_CONFIG_HOME', 'PATH'}
WRITERS = {'rm', 'mv', 'cp', 'ln', 'chmod', 'chown', 'chgrp', 'touch', 'tee', 'truncate', 'unlink', 'rmdir', 'install', 'rsync', 'shred', 'dd', 'mkdir', 'mkfifo', 'setfacl', 'chattr'}
DEST_ONLY = {'cp', 'ln', 'install'}
SHELLS = {'bash', 'sh', 'zsh', 'dash', 'ksh', 'mksh', 'fish', 'busybox'}
INTERP = re.compile(r'(python[\d.]*|pypy3?|perl|php[\d.]*|node|nodejs|ruby|deno|bun|lua[\d.]*|tclsh|Rscript|osascript)\Z')
CODE_FLAG = re.compile(r'-[a-zA-Z]*[ceErp]\Z|--(eval|print|command)\Z')
RISKY_CODE = re.compile(r'\bgit\b|\.git|\bpty\b|subprocess|system|\bexec\b|exec[lvS_F(]|spawn|popen|passthru|proc_open|fork|hooks'
                        r'|unlink|remove|rmtree|rename|chmod|symlink|`|\\x[0-9a-f]|\bchr\s*\(|base64|\beval\b|__import__|getattr'
                        r'|compile|child_process|writefile|file_put_contents|fopen|\bqx\b|shutil|\bos\.', re.I)
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
JOINED_SCRIPT = {'watch', 'ssh', 'su', 'runuser'}
REMOTE = {'docker', 'podman', 'kubectl', 'nerdctl', 'lxc', 'vagrant'}


class Deny(Exception):
    pass


class Ctx:
    def __init__(self, cwd):
        self.cwd, self.origin, self.written, self.flags, self.repo = cwd, cwd, set(), set(), repo_root(cwd)
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


def needle(word):
    t = re.sub(r'/+', '/', word.lower()).replace('/./', '/').replace('--no-verify-signatures', '')
    hit = next((n for n in NEEDLES if n in t), None)
    return hit or (m.group(1) if (m := PLUGIN_RE.search(t)) else None)


def check_needles(words, what):
    for w in words:
        hit = needle(w)
        if hit:
            raise Deny(f'{what} names {hit}, which only a read may mention')


def in_tmp_elsewhere(p, ctx):
    tmp = os.path.realpath(os.environ.get('TMPDIR') or '/tmp')
    inside_repo = ctx.repo and (p == ctx.repo or p.startswith(ctx.repo + '/'))
    return (p.startswith('/tmp/') or p.startswith(tmp + '/')) and not inside_repo


def protected(tok, ctx):
    if tok.dynamic:
        raise Deny(f'the target {tok} is computed at run time, so the hook cannot see what it touches')
    if needle(tok):
        return True
    for c in glob.glob(os.path.join(ctx.cwd, tok)) if re.search(r'[*?[]', tok) else [tok]:
        p = os.path.realpath(os.path.join(ctx.cwd, c))
        if needle(p) or p == PLUGIN or p.startswith(PLUGIN + '/'):
            return True
        if os.path.basename(p) == '.git' and not in_tmp_elsewhere(p, ctx):
            return True
    return False


def check_var(name, value, ctx):
    if name == 'HUSKY' and value == '0':
        raise Deny('HUSKY=0 switches the hooks off')
    if name in ENV_REDIRECT:
        ctx.flags.add('env-redirect')


def check_git(a, ctx, cwd):
    i = 0
    while i < len(a) and a[i].startswith('-'):
        t = a[i]
        if t.startswith('--config-env'):
            raise Deny('git --config-env can point core.hooksPath elsewhere')
        if t.startswith('-c'):
            kv = t[2:] or (a[i + 1] if i + 1 < len(a) else '')
            i += t == '-c'
            check_git_key(kv.split('=', 1)[0])
        elif t == '-C' and i + 1 < len(a):
            cwd = os.path.join(cwd, a[i + 1])
            i += 1
        elif t in ('--git-dir', '--work-tree', '--namespace', '--exec-path', '--super-prefix'):
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
    if sub == 'config':
        check_git_config(rest)
    if sub in VERIFY_SUBS:
        check_no_verify(sub, rest)
    check_ref_writers(sub, rest, ctx, cwd)


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
    if sub in GIT_READ or (sub == 'config' and git_config_is_read(rest)) or (sub == 'branch' and not rest) \
            or (sub == 'notes' and rest[:1] in ([], ['list'], ['show'])):
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
    try:
        vault = subprocess.run(['git', '-C', repo, 'show', 'HEAD:VAULT.md'], capture_output=True, text=True, timeout=5).stdout
    except (OSError, subprocess.SubprocessError):
        return []
    m = re.search(r'^guard_protected_paths:[ \t]*(.*)$', vault, re.M)
    return m.group(1).split() if m else []


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


def run_file(path, ctx, depth, shell):
    if trusted_script(path, ctx):
        return
    text = read_script(path, ctx)
    if shell or re.match(r'#!.*\b(ba|z|da|k)?sh\b', text):
        scan_script(text, ctx, depth + 1)
    else:
        check_needles([text], f'the script {path}')


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
    if cmd == 'flock' and any(t in ('-c', '--command') for t in w):
        raise Deny('flock -c runs a shell string the hook cannot see')
    while i < len(w) and w[i].startswith('-') and w[i] != '--':
        if w[i] in vals and i + 1 < len(w):
            if w[i] in ('-C', '--chdir'):
                cwd = os.path.join(cwd, w[i + 1])
            i += 1
        i += 1
    i += w[i:i + 1] == ['--']
    if cmd in FIRST_POSITIONAL and i < len(w):
        i += 1
    return w[i:], cwd


def scan_words(w, ctx, depth, remote=False):
    i = 0
    while i < len(w) and (m := re.match(r'([A-Za-z_]\w*)=(.*)\Z', w[i], re.S)):
        check_needles([w[i]], 'the assignment')
        check_var(m.group(1), m.group(2), ctx)
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
        raise Deny(f'the command word {w[0]} is computed at run time, so the hook cannot tell which program runs')
    if cmd == 'script' or cmd == 'eval' and any(t.dynamic for t in args):
        raise Deny(f'{cmd} runs text the hook cannot see before it runs')
    if cmd in WRAPPERS or cmd in REMOTE:
        return scan_wrapper(cmd, w, ctx, depth, remote)
    if cmd in JOINED_SCRIPT:
        return scan_joined(cmd, w, ctx, depth)
    if os.path.realpath(os.path.join(ctx.cwd, w[0])) == GUARD_SH and '/' in w[0]:
        return scan_guard(args)
    if cmd in ('cd', 'pushd'):
        ctx.cwd = os.path.join(ctx.cwd, args[0]) if args and not args[0].startswith(('-', '+')) else ctx.cwd
        return
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
    check_needles([t for j, t in enumerate(w) if j not in exempt], cmd)
    scan_command(cmd, w, args, ctx, depth, remote)


def scan_command(cmd, w, args, ctx, depth, remote):
    if cmd == 'git':
        check_git(args, ctx, ctx.cwd)
    elif cmd == 'gh':
        check_gh(args)
    elif cmd in ('unset', 'export', 'declare', 'typeset', 'readonly', 'local'):
        for t in args:
            m = re.match(r'([A-Za-z_]\w*)=(.*)\Z', t, re.S)
            if m:
                check_var(m.group(1), m.group(2), ctx)
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
    if cmd in WRITERS or (cmd in ('sed', 'perl') and any(re.match(r'(-[a-zA-Z]*i|--in-place)', t) for t in args)):
        drop = source_operands(args) if cmd in DEST_ONLY else script_operand(cmd, args)
        check_targets(cmd, [t for j, t in enumerate(args) if not t.startswith('-') and j not in drop], ctx)


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
    ok = (args[:1] == ['verify'] and len(args) == 2) or args == ['report'] or args == ['hooks', 'status']
    if not ok:
        raise Deny('guard.sh ' + ' '.join(args) + ' changes the gate; an agent may run only verify <range>, report and hooks status')


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
                raise Deny(f'{base(w[0])} -c runs text computed at run time')
            return scan_script(args[j], ctx, depth + 1)
        if not remote:
            run_file(args[j], ctx, depth, True)
        return
    stdin_script(base(w[0]), ctx, depth, True)


def stdin_script(cmd, ctx, depth, shell):
    seg = ctx.seg
    here = seg['heredoc'] or next((t for o, t in seg['redirs'] if o == '<<<'), None)
    src = next((t for o, t in seg['redirs'] if o == '<'), None)
    if here is not None:
        return scan_script(here, ctx, depth + 1) if shell else check_code(cmd, here)
    if src is not None:
        return run_file(src, ctx, depth, shell)
    raise Deny(f'{cmd} reads its program from a pipe the hook cannot see')


def check_code(cmd, code):
    check_needles([code], f'{cmd} code')
    m = RISKY_CODE.search(code)
    if m:
        raise Deny(f'{cmd} inline code uses {m.group(0)}, which can run git or rewrite files')


def scan_interpreter(cmd, args, w, ctx, depth, remote):
    j = 0
    while j < len(args) and args[j].startswith('-') and args[j] != '-':
        t = args[j]
        if CODE_FLAG.match(t) and not (cmd.startswith('python') and t in ('-E',)) and j + 1 < len(args):
            if args[j + 1].dynamic:
                raise Deny(f'{cmd} {t} runs code computed at run time')
            return check_code(cmd, args[j + 1])
        if t == '-m' and j + 1 < len(args):
            if RISKY_CODE.search(args[j + 1]):
                raise Deny(f'{cmd} -m {args[j + 1]} can run git or rewrite files')
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
        if protected(s, ctx) or os.path.lexists(os.path.join(p, '.git')) or PLUGIN.startswith(p + '/'):
            raise Deny(f'find {s} with -delete or -exec reaches the git directory or the plugin; start it in a subdirectory')


def scan_seg(seg, ctx, depth):
    for o, t in seg['redirs']:
        if o not in ('<', '<<', '<<-', '<<<', '<&') and t:
            check_targets('a redirect', [t], ctx)
    ctx.seg = seg
    scan_words(seg['words'], ctx, depth)


def scan_script(text, ctx, depth=0):
    if depth > 8:
        raise Deny('shell nesting deeper than 8 levels')
    lx = Lexer(text)
    segs = lx.parse()
    if lx.error:
        raise Deny(f'the command is incomplete: {lx.error}')
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
            if {'clone', 'push'} <= ctx.flags:
                raise Deny('git clone and git push in one command push from a copy that has no hooks')
    except Deny as d:
        sys.stderr.write(f'guard-bash: denied: {d}. Fix what the commit gate reports instead; only the human at a terminal may override it.\n')
        sys.exit(2)
    except Exception as e:
        sys.stderr.write(f'guard-bash: denied: could not check this command ({type(e).__name__}: {e})\n')
        sys.exit(2)


main()
