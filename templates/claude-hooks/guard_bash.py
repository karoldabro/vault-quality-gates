"""Rules for guard-bash.sh: denies a command that skips or weakens the commit gate or the push gate.

The git and HUSKY rules bind only when the command acts on a gated repo (gated.py). The qg and
guard.sh rules bind in every repo. Every other command runs unchecked; the repo's own pre-commit
and pre-push hooks still judge each commit and push."""
import json, os, re, stat, subprocess, sys, time

# python3 -I leaves the script's folder off sys.path; the modules beside this file are put back.
sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
try:
    from shell_lexer import Lexer
    from gated import is_gated
except Exception as e:  # exit 1 would let the command run; a hook that cannot load denies
    sys.stderr.write(f'guard-bash: denied: cannot load the rules ({type(e).__name__}: {e})\n')
    sys.exit(2)

PLUGIN = os.path.realpath(sys.argv[1].rstrip('/') or '/')
# What an agent may run through qg: reads, and the gate itself. Everything else changes the gate.
QG_READS = {'help', '-h', '--help', 'list', 'explain', 'last', 'drivers', 'doctor', 'run', 'report', 'verify', 'config'}
# What the operator's grant may name, and its longest life: QG_GRANT_ACTIONS and QG_GRANT_MAX in lib/qg-grant.sh.
GRANT_ACTIONS = {'baseline', 'override', 'push'}
GRANT_MAX = 28800
# A push to one of these deploys.
DEPLOY_BRANCHES = {'master', 'main', 'develop', 'development'}
NO_VERIFY_SUBS = {'commit', 'merge', 'push', 'am', 'rebase', 'cherry-pick', 'revert', 'pull'}
PUSH_DENIED = {'--no-verify', '--force', '-f', '--force-with-lease', '--force-if-includes', '--mirror', '--delete', '-d',
               '--push-option', '-o', '--prune'}
SHELLS = {'bash', 'sh', 'zsh', 'dash'}
# Programs that run the command after their own options.
WRAPPERS = {'env', 'command', 'nice', 'nohup', 'time', 'timeout', 'sudo', 'exec', 'builtin', 'stdbuf', 'ionice', 'setsid'}
DECLARE = {'export', 'declare', 'typeset', 'readonly', 'local'}
ASSIGN = re.compile(r'[A-Za-z_]\w*=')
# The gate reads these from its environment; a value an agent sets would steer which rows run.
GATE_VAR = re.compile(r'(GUARD|QG)_\w*=')
# Repo files that judge the next commit or push; guard-edit.sh denies the same list.
GATE_FILES = ('quality/config', 'quality/drivers', 'quality/baseline.tsv', 'quality/checks.tsv')
WRITERS = {'rm', 'mv', 'cp', 'ln', 'chmod', 'touch', 'tee', 'truncate', 'install', 'mkdir', 'rsync'}
HOOK_KEY = re.compile(r'(core\.hookspath|hook\..*)\Z', re.I)


class Deny(Exception):
    """A git or HUSKY rule; main() denies with it when the command acts on a gated repo."""


class Integrity(Deny):
    """A qg or guard.sh rule; it binds in every repo."""


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


def check_push(rest, repo):
    for t in rest:
        if t in PUSH_DENIED or t.startswith(('--force', '--push-option=', '--receive-pack', '--exec')):
            raise Deny(f'git push {t} is refused for an agent (force, delete, mirror, push options, no-verify)')
    positional = [t for t in rest if not t.startswith('-')]
    refspecs = positional[1:]
    if not refspecs:
        refspecs = [current_branch(repo)]
    for spec in refspecs:
        if spec.startswith('+'):
            raise Deny(f'git push {spec} forces the update')
        dst = spec.split(':', 1)[-1].removeprefix('refs/heads/')
        if dst == 'HEAD':
            dst = current_branch(repo)
        if dst in DEPLOY_BRANCHES:
            raise Deny(f'git push to {dst} deploys; push a branch and let the operator merge it')


def check_config(rest):
    for t in rest:
        key = t.split('=', 1)[0]
        if HOOK_KEY.match(key) and not t.startswith('-'):
            if any(r in ('--get', '--get-all', '--get-regexp', '--list', '-l', 'get', 'list') for r in rest):
                return
            raise Deny(f'git config {key} can disable or reroute the hooks')


def check_git(args, cwd):
    """The rule a git command breaks, or None, and the folder it acts on."""
    try:
        return None, git_rules(args, cwd)
    except Deny as d:
        return str(d), git_folder(args, cwd)


def git_folder(args, cwd):
    """The folder after git -C, or cwd."""
    for j, t in enumerate(args[:-1]):
        if t == '-C':
            cwd = os.path.join(cwd, os.path.expanduser(args[j + 1]))
    return cwd


def git_rules(args, cwd):
    """Raises Deny for a commit or push rule; returns the folder git acts on."""
    i = 0
    while i < len(args) and args[i].startswith('-'):
        t = args[i]
        if t in ('-C', '-c') and i + 1 < len(args):
            if t == '-C':
                cwd = os.path.join(cwd, os.path.expanduser(args[i + 1]))
            elif HOOK_KEY.match(args[i + 1].split('=', 1)[0]):
                raise Deny('git -c core.hooksPath or hook.* reroutes the hooks')
            i += 2
            continue
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
    """The rule an assignment breaks, or None."""
    if word == 'HUSKY=0':
        return 'HUSKY=0 switches the hooks off'
    if GATE_VAR.match(word):
        return f'{word.split("=", 1)[0]} is read by the gate; an agent may not set it'
    return None


def gate_path(path):
    """Why a write to path changes what judges the next commit or push, or None. The same files
    guard-edit.sh denies."""
    parts = path.split('/')
    if '.git' in parts or path.startswith('.git/') or 'qg-override' in path:
        return f'{path} is inside a .git directory'
    if '.husky' in parts:
        return f'{path} is a husky hook file'
    if any(g in path for g in GATE_FILES):
        return f'{path} judges the next commit or push; a human changes it'
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
            rule = gate_path(str(t))
            if rule:
                hits.append((rule, os.path.dirname(os.path.join(cwd, os.path.expanduser(str(t))))))
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
        elif cmd == 'git':
            rule, folder = check_git(words[1:], cwd)
            if rule:
                hits.append((rule, folder))
    return hits


def main():
    try:
        event = json.load(sys.stdin)
        if event.get('tool_name', 'Bash') != 'Bash':
            return
        command = (event.get('tool_input') or {}).get('command') or ''
        hit = next((h for h in scan(command, event.get('cwd') or os.getcwd()) if is_gated(h[1])), None)
        if hit:
            sys.stderr.write(f'guard-bash: denied: {hit[0]}. Fix what the commit gate reports instead; only the human at a terminal may override it.\n')
            sys.exit(2)
    except Integrity as d:
        sys.stderr.write(f'guard-bash: denied: {d}. Ask the human to run it from a separate terminal.\n')
        sys.exit(2)
    except Exception as e:  # a command the hook cannot parse is not a commit or push it can judge
        sys.stderr.write(f'guard-bash: not checked ({type(e).__name__}: {e})\n')


main()
