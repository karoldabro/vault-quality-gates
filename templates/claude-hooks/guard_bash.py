"""Rules for guard-bash.sh: denies a command that skips or weakens the commit gate or the push gate.

The git and HUSKY rules bind only when the command acts on a gated repo (gated.py). The qg and
guard.sh rules bind in every repo, and so do two push rules: a push from a checkout with
quality/checks.tsv at HEAD and no vault-guard pre-push, and a `gh api` write that moves a ref or merges
on GitHub. Every other command runs unchecked; the repo's own pre-commit and pre-push hooks still
judge each commit and push."""
import json, os, re, shlex, stat, subprocess, sys, time

# python3 -I leaves the script's folder off sys.path; the modules beside this file are put back.
sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
try:
    from shell_lexer import Lexer
    from gated import is_gated, is_git_dir, push_unguarded
except Exception as e:  # exit 1 would let the command run; a hook that cannot load denies
    sys.stderr.write(f'guard-bash: denied: cannot load the rules ({type(e).__name__}: {e})\n')
    sys.exit(2)

PLUGIN = os.path.realpath(sys.argv[1].rstrip('/') or '/')
# What an agent may run through qg: reads, and the gate itself. Everything else changes the gate.
QG_READS = {'help', '-h', '--help', 'list', 'explain', 'last', 'drivers', 'doctor', 'run', 'report', 'verify', 'config'}
# What the operator's grant may name, and its longest life: QG_GRANT_ACTIONS and QG_GRANT_MAX in lib/qg-grant.sh.
GRANT_ACTIONS = {'baseline', 'override', 'push', 'hotfix'}
GRANT_MAX = 28800
# A push to one of these deploys.
DEPLOY_BRANCHES = {'master', 'main', 'develop', 'development'}
NO_VERIFY_SUBS = {'commit', 'merge', 'push', 'am', 'rebase', 'cherry-pick', 'revert', 'pull'}
PUSH_DENIED = {'--no-verify', '--force', '-f', '--force-with-lease', '--force-if-includes', '--mirror', '--delete', '-d',
               '--push-option', '-o', '--prune'}
SHELLS = {'bash', 'sh', 'zsh', 'dash'}
# Programs that run the command after their own options.
WRAPPERS = {'env', 'command', 'nice', 'nohup', 'time', 'timeout', 'sudo', 'exec', 'builtin', 'stdbuf', 'ionice', 'setsid'}
# Programs that run a command given as a string, or after options this file does not parse; some also
# detach it or give it a terminal of its own. Each argument, and each run of trailing words, is
# judged as a command of its own, so qg inside them meets the same rules as qg run directly.
# The commands scan() judges; a run of trailing words is read only when it starts with one.
JUDGED = {'qg', 'guard.sh', 'git'}
CMD_WRAPPERS = {'script', 'systemd-run', 'tmux', 'screen', 'su', 'runuser', 'wsl', 'wsl.exe', 'flock'}
# At most this many inner reads per command; past it the command is denied, never waved through.
INNER_BUDGET = 256
DECLARE = {'export', 'declare', 'typeset', 'readonly', 'local'}
ASSIGN = re.compile(r'[A-Za-z_]\w*=')
# The gate reads these from its environment; a value an agent sets would steer which rows run.
GATE_VAR = re.compile(r'(GUARD|QG)_\w*=')
# Repo files that judge the next commit or push; guard-edit.sh denies the same list.
GATE_FILES = ('quality/config', 'quality/drivers', 'quality/baseline.tsv', 'quality/checks.tsv')
WRITERS = {'rm', 'mv', 'cp', 'ln', 'chmod', 'touch', 'tee', 'truncate', 'install', 'mkdir', 'rsync'}
HOOK_KEY = re.compile(r'(core\.hookspath|hook\..*)\Z', re.I)
# Configuration that changes which remote ref a push writes.
PUSH_KEY = re.compile(r'(remote\..*\.(push|mirror)|push\.default|branch\..*\.merge)\Z', re.I)
# Environment that sets git configuration for every git command it reaches.
GIT_CONFIG_VAR = re.compile(r'GIT_CONFIG_(COUNT|KEY_\w*|VALUE_\w*|PARAMETERS|GLOBAL|SYSTEM|NOSYSTEM)=')
# GitHub API paths whose write moves a ref, makes a commit or a file, or merges.
GH_WRITE_PATH = re.compile(r'(^|/)(git/(refs|commits)|contents|merges|pulls/[^/]+/merge)(/|$)')
GH_VALUE_OPTS = {'-X', '--method', '-f', '-F', '--field', '--raw-field', '-H', '--header', '--input', '-q', '--jq',
                 '-t', '--template', '--hostname', '--cache', '-p', '--preview'}
REROUTE = 'Push one branch by name, as git push origin <branch>, so the push gate measures the ref it sends'
HOTFIX = ('Ask the operator to run `qg grant --agent hotfix` in a separate terminal, or push it as a feature branch '
          'and let the push gate measure it')


class Deny(Exception):
    """A git or HUSKY rule; main() denies with it when the command acts on a gated repo."""


class Integrity(Deny):
    """A qg or guard.sh rule; it binds in every repo."""


class PushDeny(Deny):
    """A push rule; main() names its next step instead of the commit-gate sentence."""
    everywhere = False

    def __init__(self, rule, step):
        super().__init__(rule)
        self.step = step


class Unguarded(PushDeny):
    """A push rule that binds outside a gated repo too."""
    everywhere = True


def base(w):
    return os.path.basename(w)


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


def check_qg(args):
    words = [a for a in args if a != '--json']
    sub = words[0] if words else 'help'
    if sub in QG_READS or words[:2] == ['hooks', 'status'] or words == ['hooks'] or words == ['grant', '--status']:
        return
    if sub == 'grant':
        raise Integrity('qg grant issues or ends the operator grant; only a human at a separate terminal runs it')
    action = {'baseline': 'baseline', 'override': 'push' if '--push' in words else 'override'}.get(sub)
    if action and action in granted():
        return
    raise Integrity(f'qg {sub} changes the gate; an agent may run only {", ".join(sorted(QG_READS))}, hooks status and grant --status'
                    + (f', or qg {sub} while the operator grants {action}' if action else ''))


def check_guard_sh(args):
    if not ((args[:1] == ['verify'] and len(args) == 2) or args == ['report'] or args[:2] == ['hooks', 'status']):
        raise Integrity('guard.sh ' + ' '.join(args) + ' changes the gate; an agent may run only verify <range>, report and hooks status')


def current_branch(repo):
    try:
        return subprocess.run(['git', '-C', repo, 'symbolic-ref', '--short', '-q', 'HEAD'],
                              capture_output=True, text=True, timeout=5).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return ''


def push_branch(repo):
    """The branch a bare `git push` writes on the remote, after upstream and push.default; else the current branch."""
    try:
        full = subprocess.run(['git', '-C', repo, 'rev-parse', '--symbolic-full-name', '@{push}'],
                              capture_output=True, text=True, timeout=5).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        full = ''
    if full.startswith('refs/remotes/') and full.count('/') >= 3:
        return full.split('/', 3)[3]
    return current_branch(repo)


def check_push(rest, repo):
    if push_unguarded(repo):
        raise Unguarded(f'{os.path.realpath(repo)} has quality/checks.tsv at HEAD but no vault-guard pre-push hook, '
                        'so nothing would measure this push', 'Ask the operator to run `qg hooks install` in that checkout')
    for t in rest:
        if t in PUSH_DENIED or t.startswith(('--force', '--push-option=', '--receive-pack', '--exec')):
            raise PushDeny(f'git push {t} is refused for an agent (force, delete, mirror, push options, no-verify)',
                           'Push without it; a refused push is fixed in the code')
        if t in ('--all', '--branches'):
            raise PushDeny(f'git push {t} pushes every local branch, whatever its name', REROUTE)
    positional = [t for t in rest if not t.startswith('-')]
    refspecs = positional[1:] or [None]
    for spec in refspecs:
        if spec is None:
            dst = push_branch(repo)
        else:
            if spec.startswith('+'):
                raise PushDeny(f'git push {spec} forces the update', 'Push without the +; a refused push is fixed in the code')
            if spec == ':' or '*' in spec:
                raise PushDeny(f'git push {spec} pushes every branch it matches', REROUTE)
            dst = spec.split(':', 1)[-1]
            if dst.startswith('refs/') and not dst.startswith('refs/heads/'):
                raise PushDeny(f'git push to {dst} writes a ref outside refs/heads/', REROUTE)
            dst = dst.removeprefix('refs/heads/')
            if dst == 'HEAD':
                dst = current_branch(repo)
        if dst in DEPLOY_BRANCHES:
            raise PushDeny(f'git push to {dst} deploys', 'Push a branch and let the operator merge it')
        if dst.startswith('hotfix/') and 'hotfix' not in granted():
            raise PushDeny(f'git push to {dst} skips the push rows, and no operator grant names hotfix', HOTFIX)


def check_config(rest):
    for t in rest:
        key = t.split('=', 1)[0]
        if (HOOK_KEY.match(key) or PUSH_KEY.match(key)) and not t.startswith('-'):
            if any(r in ('--get', '--get-all', '--get-regexp', '--list', '-l', 'get', 'list') for r in rest):
                return
            if PUSH_KEY.match(key):
                raise PushDeny(f'git config {key} changes which remote ref a push writes', REROUTE)
            raise Deny(f'git config {key} can disable or reroute the hooks')


def check_git(args, cwd):
    """The rule a git command breaks (a Deny), or None, and the folder it acts on."""
    try:
        return None, git_rules(args, cwd)
    except Deny as d:
        return d, git_folder(args, cwd)


def git_folder(args, cwd):
    """The folder after git -C, or cwd."""
    for j, t in enumerate(args[:-1]):
        if t == '-C':
            cwd = os.path.join(cwd, os.path.expanduser(args[j + 1]))
    return cwd


def config_option(kv):
    """Raises Deny for a `git -c` or `--config-env` setting that reroutes the hooks or the push."""
    key = kv.split('=', 1)[0]
    if HOOK_KEY.match(key):
        raise Deny('git -c core.hooksPath or hook.* reroutes the hooks')
    if PUSH_KEY.match(key):
        raise PushDeny(f'git -c {key} changes which remote ref a push writes', REROUTE)


def git_rules(args, cwd):
    """Raises Deny for a commit or push rule; returns the folder git acts on."""
    i = 0
    while i < len(args) and args[i].startswith('-'):
        t = args[i]
        if t in ('-C', '-c', '--config-env') and i + 1 < len(args):
            if t == '-C':
                cwd = os.path.join(cwd, os.path.expanduser(args[i + 1]))
            else:
                config_option(args[i + 1])
            i += 2
            continue
        if t.startswith('--config-env='):
            config_option(t.split('=', 1)[1])
        i += 1
    if i >= len(args):
        return cwd
    sub, rest = args[i], args[i + 1:]
    if sub in NO_VERIFY_SUBS and '--no-verify' in rest:
        raise Deny(f'git {sub} --no-verify skips the gate')
    if sub == 'commit' and any(re.fullmatch(r'-[a-zA-Z]*n[a-zA-Z]*', t) for t in rest):
        raise Deny('git commit -n skips the commit gate')
    if sub == 'push':
        check_push(rest, cwd)
    if sub == 'config':
        check_config(rest)
    return cwd


def check_assign(word):
    """The rule an assignment breaks (a Deny), or None."""
    if word == 'HUSKY=0':
        return Deny('HUSKY=0 switches the hooks off')
    if GATE_VAR.match(word):
        return Deny(f'{word.split("=", 1)[0]} is read by the gate; an agent may not set it')
    if GIT_CONFIG_VAR.match(word):
        return PushDeny(f'{word.split("=", 1)[0]} sets git configuration for every git command, which can reroute a push '
                        'or switch off the hooks', REROUTE)
    return None


def in_git_dir(full):
    """True when the absolute path lies inside a git directory: a .git folder or a bare or separate git dir."""
    if '.git' in full.split('/'):
        return True
    d = os.path.dirname(full)
    while d != '/':
        if is_git_dir(d):
            return True
        d = os.path.dirname(d)
    return False


def gate_path(path, full):
    """Why a write to path, which resolves to full against the tracked cwd, changes what judges the
    next commit or push, or None. The same files guard-edit.sh denies."""
    parts = path.split('/')
    if '.git' in parts or path.startswith('.git/') or 'qg-override' in path or in_git_dir(full):
        return f'{path} is inside a .git directory'
    if '.husky' in parts or '.husky' in full.split('/'):
        return f'{path} is a husky hook file'
    if any(g in path or g in full for g in GATE_FILES):
        return f'{path} judges the next commit or push; a human changes it'
    return None


def check_gh(args):
    """A PushDeny when `gh api` writes a ref, a commit, a file or a merge on GitHub; reads pass."""
    if args[:1] != ['api']:
        return None
    method, body, path, i = None, False, None, 1
    while i < len(args):
        t = args[i]
        opt, eq, val = t.partition('=') if t.startswith('--') else (t, '', '')
        if opt in GH_VALUE_OPTS:
            if not eq:
                val = args[i + 1] if i + 1 < len(args) else ''
                i += 1
            if opt in ('-X', '--method'):
                method = val.upper()
            elif opt in ('-f', '-F', '--field', '--raw-field', '--input'):
                body = True
        elif t.startswith('-X') and len(t) > 2:
            method = t[2:].upper()
        elif not t.startswith('-') and path is None:
            path = t
        i += 1
    method = method or ('POST' if body else 'GET')
    if path and method in ('POST', 'PUT', 'PATCH', 'DELETE') and GH_WRITE_PATH.search(path.split('?', 1)[0].strip('/')):
        return Unguarded(f'gh api {method} {path} writes on GitHub past the push gate',
                         'Push a branch with git push, so pre-push measures it, and open a pull request; the operator merges it')
    return None


def write_targets(cmd, args, redirs):
    targets = [t for o, t in redirs if o not in ('<', '<<', '<<-', '<<<', '<&') and not (o == '>&' and re.fullmatch(r'\d+|-', t))]
    if cmd in WRITERS:
        targets += [a for a in args if not a.startswith('-')]
    if cmd == 'dd':
        targets += [a[3:] for a in args if a.startswith('of=')]
    return targets


def scan(text, cwd, depth=0):
    """Every (rule, folder) a git, gate-variable or gate-file rule finds; qg and guard.sh raise."""
    hits = []
    if depth > 4:
        return hits
    lx = Lexer(text)
    for seg in lx.parse() + lx.subs:
        words = [str(w) for w in seg['words']]
        if words and base(words[0]) in WRAPPERS | CMD_WRAPPERS:
            hits += scan_inner(words[1:], cwd, depth + 1)
        while words and (ASSIGN.match(words[0]) or base(words[0]) in WRAPPERS | DECLARE):
            if not ASSIGN.match(words[0]):
                words = words[1:]
                while words and (words[0].startswith('-') or words[0].isdigit()):
                    words = words[1:]
                continue
            rule = check_assign(words[0])
            if rule:
                hits.append((rule, cwd))
            words = words[1:]
        for t in write_targets(base(words[0]) if words else '', words[1:], seg['redirs']):
            full = os.path.realpath(os.path.join(cwd, os.path.expanduser(str(t))))
            rule = gate_path(str(t), full)
            if rule:
                hits.append((Deny(rule), os.path.dirname(full)))
        if not words:
            continue
        cmd = base(words[0])
        if cmd == 'cd' and len(words) > 1:
            cwd = os.path.join(cwd, os.path.expanduser(words[1]))
        elif cmd == 'qg':
            check_qg(words[1:])
        elif cmd == 'guard.sh':
            check_guard_sh(words[1:])
        elif cmd in SHELLS and len(words) > 2 and words[1] == '-c':
            hits += scan(words[2], cwd, depth + 1)
        elif cmd == 'gh':
            rule = check_gh(words[1:])
            if rule:
                hits.append((rule, cwd))
        elif cmd == 'git':
            rule, folder = check_git(words[1:], cwd)
            if rule:
                hits.append((rule, folder))
    return hits


class Budget:
    left = INNER_BUDGET


def scan_inner(words, cwd, depth):
    """The hits of each word that holds a command line, and of the trailing words from the first
    one that is a command these rules judge, a wrapper, or an assignment; later runs are its own
    arguments, which scan() already reads."""
    hits = []
    first = next((i for i, w in enumerate(words)
                  if base(w) in JUDGED | SHELLS | WRAPPERS | CMD_WRAPPERS | DECLARE or ASSIGN.match(w)), None)
    texts = [w for w in words if ' ' in w.strip()]
    if first is not None:
        texts.append(' '.join(shlex.quote(t) for t in words[first:]))
    for text in texts:
        Budget.left -= 1
        if Budget.left < 0:
            raise Integrity('the command nests too many wrappers to judge; run the parts separately')
        hits += scan(text, cwd, depth)
    return hits


def main():
    try:
        event = json.load(sys.stdin)
        if event.get('tool_name', 'Bash') != 'Bash':
            return
        command = (event.get('tool_input') or {}).get('command') or ''
        hits = scan(command, event.get('cwd') or os.getcwd())
        hit = next((d for d, folder in hits if getattr(d, 'everywhere', False) or is_gated(folder)), None)
        if isinstance(hit, PushDeny):
            sys.stderr.write(f'guard-bash: denied: {hit}. {hit.step}.\n')
            sys.exit(2)
        if hit:
            sys.stderr.write(f'guard-bash: denied: {hit}. Fix what the commit gate reports instead; only the human at a terminal may override it.\n')
            sys.exit(2)
    except Integrity as d:
        sys.stderr.write(f'guard-bash: denied: {d}. Ask the human to run it from a separate terminal.\n')
        sys.exit(2)
    except Exception as e:  # a command the hook cannot parse is not a commit or push it can judge
        sys.stderr.write(f'guard-bash: not checked ({type(e).__name__}: {e})\n')


main()
