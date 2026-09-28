#!/usr/bin/env bats
# templates/claude-hooks/guard-bash.sh and guard-edit.sh — the PreToolUse hooks that stop an agent
# from skipping, disabling or forging the commit gate.
#
# Each case feeds the JSON Claude Code sends on stdin and asserts the exit status: 2 denies
# (stderr goes back to the agent), 0 allows. The plugin checkout is /code, derived by the hooks
# from their own location, so /code/bin/guard.sh is the protected plugin file here.

HOOKS=/code/templates/claude-hooks

setup() {
    export LC_ALL=C
    WORK="$(mktemp -d)"
    mkdir -p "$WORK/repo" "$HOME"
    cd "$WORK/repo" || return 1
    git init -q .
    git config user.email 'test@example.invalid'
    git config user.name 'test'
    git commit -q --allow-empty -m init
    BAD=''
}

teardown() {
    [ -n "${WORK:-}" ] && [ -d "$WORK" ] && rm -rf "$WORK"
    return 0
}

# bash_case <deny|allow> <command> — appends the command to $BAD when the hook disagrees.
bash_case() {
    local want="$1" cmd="$2" rc=0
    jq -nc --arg c "$cmd" --arg d "$PWD" \
        '{hook_event_name:"PreToolUse",tool_name:"Bash",cwd:$d,tool_input:{command:$c}}' \
        | "$HOOKS/guard-bash.sh" > /dev/null 2>&1 || rc=$?
    [ "$want" = deny ] && [ "$rc" -ne 2 ] && BAD+=$'\n'"not denied (exit $rc): $cmd"
    [ "$want" = allow ] && [ "$rc" -ne 0 ] && BAD+=$'\n'"not allowed (exit $rc): $cmd"
    return 0
}

# edit_case <deny|allow> <path> [tool] — the same for guard-edit.sh.
edit_case() {
    local want="$1" path="$2" tool="${3:-Edit}" key=file_path rc=0
    [ "$tool" = NotebookEdit ] && key=notebook_path
    jq -nc --arg p "$path" --arg d "$PWD" --arg t "$tool" --arg k "$key" \
        '{hook_event_name:"PreToolUse",tool_name:$t,cwd:$d,tool_input:{($k):$p}}' \
        | "$HOOKS/guard-edit.sh" > /dev/null 2>&1 || rc=$?
    [ "$want" = deny ] && [ "$rc" -ne 2 ] && BAD+=$'\n'"edit not denied (exit $rc): $path"
    [ "$want" = allow ] && [ "$rc" -ne 0 ] && BAD+=$'\n'"edit not allowed (exit $rc): $path"
    return 0
}

no_bad() {
    [ -z "$BAD" ] || { printf '%s\n' "$BAD" >&2; return 1; }
}

@test "a denial exits 2 and names the reason on stderr" {
    run bash -c "jq -nc '{tool_name:\"Bash\",tool_input:{command:\"git commit -n -m x\"}}' | $HOOKS/guard-bash.sh"
    [ "$status" -eq 2 ]
    [[ "$output" == *'-n (--no-verify)'* ]]
    run bash -c "jq -nc '{tool_name:\"Edit\",tool_input:{file_path:\"/r/.git/config\"}}' | $HOOKS/guard-edit.sh"
    [ "$status" -eq 2 ]
    [[ "$output" == *'.git directory'* ]]
}

@test "unreadable stdin fails closed" {
    run bash -c "echo not-json | $HOOKS/guard-bash.sh"
    [ "$status" -eq 2 ]
    run bash -c "echo not-json | $HOOKS/guard-edit.sh"
    [ "$status" -eq 2 ]
}

@test "python3 missing fails closed" {
    mkdir -p "$WORK/bin"
    for t in bash env realpath dirname; do ln -s "$(command -v "$t")" "$WORK/bin/$t"; done
    run env PATH="$WORK/bin" bash "$HOOKS/guard-bash.sh" < /dev/null
    [ "$status" -eq 2 ]
    [[ "$output" == *'python3 is missing'* ]]
}

@test "commit -n in any short-flag cluster is denied; -n elsewhere is not" {
    bash_case deny  'git commit -n -m x'
    bash_case deny  'git commit -anm x'
    bash_case deny  'git commit -qn -m x'
    bash_case deny  'git commit -m x -n'
    bash_case deny  'git commit -m"msg" -n'
    bash_case deny  'git commit --message=x -n'
    bash_case allow 'git commit -m -n'
    bash_case allow 'git commit -m x -- -n'
    bash_case allow 'git revert -n abc'
    bash_case allow 'git cherry-pick -n abc'
    bash_case allow 'git merge -n feature'
    bash_case allow 'git pull -n'
    bash_case allow 'git rebase -n main'
    no_bad
}

@test "--no-verify is denied from the --no-ver prefix on every commit-creating command" {
    local sub
    for sub in commit merge am rebase cherry-pick revert push pull; do
        bash_case deny "git $sub --no-verify x"
        bash_case deny "git $sub --no-ver x"
        bash_case allow "git $sub --no-ve x"
    done
    bash_case deny  'git push --no-verif origin main'
    bash_case deny  'git commit --no-verify= -m x'
    bash_case allow 'git merge --no-verify-signatures feature'
    bash_case allow 'git pull --no-verify-signatures'
    bash_case allow 'git merge -m "--no-verify" feature'
    no_bad
}

@test "global options before the subcommand are skipped, and -c keys are checked" {
    bash_case deny  'git -C /tmp -c user.name=a commit -n -m x'
    bash_case deny  'git --git-dir=.git --no-pager commit --no-verify'
    bash_case deny  'git -c core.hooksPath=/dev/null commit -m x'
    bash_case deny  'git -c core.hookspath=/dev/null commit -m x'
    bash_case deny  'git -c alias.ci=commit ci'
    bash_case deny  'git -c include.path=/tmp/x commit -m x'
    bash_case deny  'git --config-env=core.hooksPath=X commit -m x'
    bash_case deny  'git --config-env core.hooksPath=X commit -m x'
    bash_case allow 'git -C /tmp -c user.name=a commit -m x'
    bash_case allow 'git -c color.ui=never log -1'
    no_bad
}

@test "git config writes to core.hooksPath, alias.* or include are denied; reads pass" {
    bash_case deny  'git config core.hooksPath /tmp/none'
    bash_case deny  'git config --global core.hooksPath /tmp/none'
    bash_case deny  'git config set core.hooksPath x'
    bash_case deny  'git config alias.ci "commit --no-verify"'
    bash_case deny  'git config --add include.path /tmp/x'
    bash_case deny  'git config --edit'
    bash_case allow 'git config core.hooksPath'
    bash_case allow 'git config --get core.hooksPath'
    bash_case allow 'git config --get-regexp alias'
    bash_case allow 'git config --list'
    bash_case allow 'git config user.name bob'
    no_bad
}

@test "config-redirecting and override variables are denied; look-alike names pass" {
    bash_case deny  'GIT_CONFIG_PARAMETERS="core.hooksPath=/x" git commit -m x'
    bash_case deny  'GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath git commit -m x'
    bash_case deny  'GIT_CONFIG_GLOBAL=/tmp/g git commit -m x'
    bash_case deny  'GIT_CONFIG_SYSTEM=/tmp/g git commit -m x'
    bash_case deny  'HOME=/tmp git commit -m x'
    bash_case deny  'XDG_CONFIG_HOME=/tmp git push'
    bash_case deny  'QG_SKIP_REASON=because git commit -m x'
    bash_case deny  'HUSKY=0 git commit -m x'
    bash_case deny  'export GIT_CONFIG_GLOBAL=/tmp/g'
    bash_case deny  'GIT_CONFIG_GLOBAL=/tmp/g'
    bash_case allow 'MY_HOME=/tmp git commit -m x'
    bash_case allow 'HOMEDIR=/tmp git status'
    bash_case allow 'HUSKY=1 git commit -m x'
    bash_case allow 'echo HOME=/tmp'
    no_bad
}

@test "plumbing, gh api writes and agent-marker removal are denied" {
    bash_case deny  'git commit-tree HEAD^{tree} -m x'
    bash_case deny  'git update-ref refs/heads/x HEAD'
    bash_case deny  'gh api -X PUT repos/o/r/contents/a.txt -f message=x'
    bash_case deny  'gh api repos/o/r/git/refs -f ref=refs/heads/x -f sha=abc'
    bash_case deny  'gh api --method=PATCH repos/o/r/git/refs/heads/main'
    bash_case allow 'gh api repos/o/r/contents/a.txt'
    bash_case allow 'gh api repos/o/r/git/refs/heads/main'
    bash_case allow 'gh pr list'
    bash_case deny  'unset CLAUDECODE; git commit -m x'
    bash_case deny  'unset AI_AGENT'
    bash_case deny  'export -n CLAUDECODE'
    bash_case deny  'env -u CLAUDECODE git commit -m x'
    bash_case deny  'env --unset=AI_AGENT git commit -m x'
    bash_case deny  'env -i PATH=/usr/bin git commit -m x'
    bash_case deny  'script -qc "git commit -m x" /dev/null'
    bash_case allow 'env FOO=1 git status'
    no_bad
}

@test "file writers and redirects naming gate state or the plugin are denied" {
    bash_case deny  'rm .git/hooks/pre-commit'
    bash_case deny  'rm -rf .git'
    bash_case deny  'touch .git/guard-pass/abc'
    bash_case deny  'echo ok > .git/guard-pass/abc'
    bash_case deny  'echo ok >.git/hooks/pre-commit'
    bash_case deny  'echo ok 2>.git/hooks/pre-commit'
    bash_case deny  'cat x >> ~/.gitconfig'
    bash_case deny  'printf x | tee .claude/settings.json'
    bash_case deny  'printf x | tee -a ~/.claude/settings.local.json'
    bash_case deny  'sed -i s/a/b/ .git/config'
    bash_case deny  'cp /tmp/x ~/.config/git/config'
    bash_case deny  'ln -sf /tmp/x .git/hooks/pre-push'
    bash_case deny  'mv .git/guard-bypass.log /tmp/'
    bash_case deny  'rm -rf .git/guard-tree'
    bash_case deny  'dd if=/tmp/x of=.git/hooks/pre-commit'
    bash_case deny  'chmod -x /code/bin/guard.sh'
    bash_case deny  'rm -rf /code'
    bash_case deny  'cd /code && chmod -x bin/guard.sh'
    bash_case deny  'cd .git && rm hooks/pre-commit'
    bash_case allow 'rm -rf /tmp/foo && mkdir /tmp/foo'
    bash_case allow 'echo ok > /tmp/out.txt'
    no_bad
}

@test "bash -c, sh -c, eval, substitutions and every chained segment are re-scanned" {
    bash_case deny  'bash -c "git commit -n -m x"'
    bash_case deny  "sh -c 'git commit --no-verify'"
    bash_case deny  'bash -lc "git commit -n"'
    bash_case deny  'eval "git commit -n"'
    bash_case deny  'git status && git commit -n -m x'
    bash_case deny  'git status; git commit -n -m x'
    bash_case deny  'git status || git commit -n -m x'
    bash_case deny  $'git status\ngit commit -n -m x'
    bash_case deny  'echo $(git commit -n -m x)'
    bash_case deny  'echo `git commit -n -m x`'
    bash_case deny  'git commit -m "$(git config core.hooksPath /x)"'
    bash_case deny  '(git commit -n)'
    bash_case deny  '{ git commit -n; }'
    bash_case deny  'if true; then git commit -n; fi'
    bash_case deny  'for f in a; do git commit -n; done'
    bash_case deny  'echo x | xargs git commit -n -m'
    bash_case deny  'nice -n 15 git commit -n -m x'
    bash_case deny  'timeout 10 git commit -n'
    bash_case deny  'sudo -E git commit --no-verify'
    bash_case deny  '"git" commit -n'
    bash_case deny  '/usr/bin/git commit -n'
    bash_case deny  $'bash <<\'EOT\'\ngit commit -n -m x\nEOT'
    bash_case allow 'bash -c "git status"'
    bash_case allow 'nice -n 15 git commit -m x'
    no_bad
}

@test "quoted -m text and heredoc message bodies are never scanned" {
    bash_case allow 'git commit -am "fix -n and --no-verify in message"'
    bash_case allow "git commit -m 'rm .git/hooks/pre-commit; git commit -n'"
    bash_case allow $'git commit -m "$(cat <<\'EOT\'\nfix: rm .git/hooks and git commit -n (x)\nEOT\n)"'
    bash_case allow $'cat > /tmp/notes.txt <<\'EOT\'\ngit commit -n\nEOT'
    bash_case allow "echo '--no-verify'"
    bash_case allow 'git log --grep=--no-verify'
    bash_case allow 'echo "a # b" && git status # comment -n'
    no_bad
}

@test "read-only commands always pass" {
    local c
    for c in 'git status' 'git log --oneline -5' 'git diff --cached' 'git show HEAD:VAULT.md' \
        'ls -la .git/hooks' 'cat .git/config' 'cat ~/.claude/settings.json' 'grep -r guard-pass .git' \
        'sed -n 1,10p .git/config' "git log --format='%H %s' | head -3 2>/dev/null" \
        'git rev-parse --git-common-dir' 'stat /code/bin/guard.sh' 'git stash push -m wip' \
        'git fetch origin && git rebase origin/main' 'git commit -m "feat: x"' 'git commit -F msg.txt' \
        'git commit --amend --no-edit' 'git push origin release/1.18.0'; do
        bash_case allow "$c"
    done
    no_bad
}

@test "gate-state names deny every command that is not a read; guard.sh runs only verify, report and hooks status" {
    bash_case deny  "C='. /code/lib/guard-pass.sh; guard_pass_write \"\$(guard_pass_key_of_commit HEAD)\" ok'; eval \"\$C\""
    bash_case deny  'guard_pass_write abc ok'
    bash_case deny  'x=guard-tree; echo $x'
    bash_case deny  '/code/bin/guard.sh baseline'
    bash_case deny  '/code/bin/guard.sh accept'
    bash_case deny  '/code/bin/guard.sh hooks install'
    bash_case deny  '/code/bin/guard.sh hooks remove'
    bash_case deny  'git send-pack origin HEAD:refs/heads/main'
    bash_case deny  'git fast-import < stream.txt'
    bash_case deny  'declare +x CLAUDECODE; git commit -m x'
    bash_case deny  'typeset +x AI_AGENT'
    bash_case deny  'read QG_SKIP_REASON <<< because'
    bash_case deny  'printf -v QG_SKIP_REASON x'
    bash_case deny  'git hook run pre-commit'
    bash_case allow '/code/bin/guard.sh verify HEAD~1..HEAD'
    bash_case allow '/code/bin/guard.sh report'
    bash_case allow '/code/bin/guard.sh hooks status'
    bash_case allow 'grep -rn guard-pass /code/lib'
    bash_case allow 'cat /code/lib/guard-hook.sh'
    bash_case allow 'git grep -n guard-pass'
    bash_case allow 'git config core.hooksPath'
    bash_case allow 'echo $CLAUDECODE'
    bash_case allow 'git commit -m "fix: guard-pass and --no-verify handling"'
    no_bad
}

@test "push is denied when its flags are computed, forced or mirrored, or when it runs outside this repository" {
    bash_case deny  'x=--no-verify; git push $x origin main'
    bash_case deny  'git push $FLAGS origin main'
    bash_case deny  'git clone . ../c && (cd ../c && git push origin main)'
    bash_case deny  'cd /tmp && git push origin main'
    bash_case deny  'git -C /tmp push origin main'
    bash_case deny  'git push --mirror'
    bash_case deny  'git push --force-with-lease'
    bash_case deny  'git push -f origin main'
    bash_case deny  'git push origin +main'
    bash_case deny  'git push -o skip-ci'
    bash_case deny  'git notes add -m x'
    bash_case deny  'git stash store abc'
    bash_case deny  'git tag -f v1'
    bash_case deny  'git commit --allow-empty -m x'
    bash_case allow 'git push origin main'
    bash_case allow 'git push -u origin feature/x'
    bash_case allow 'git stash push -m wip'
    bash_case allow 'git tag v1'
    bash_case allow 'git notes list'
    bash_case allow 'git cherry-pick abc'
    no_bad
}

@test "interpreters, find, awk, piped shells and executed script files are scanned or denied" {
    printf 'git commit -n -m x\n' > "$WORK/bad.sh"
    printf '#!/bin/sh\nrm .git/hooks/pre-push\n' > "$WORK/bad-exec"
    printf 'echo ok\n' > "$WORK/ok.sh"
    chmod +x "$WORK/bad-exec"
    mkdir -p app
    bash_case deny  "python3 -c \"open('.git/hooks/pre-commit','w').write('')\""
    bash_case deny  "python3 -c 'import pty; pty.spawn([\"git\",\"push\"])'"
    bash_case deny  "perl -e 'unlink \".git/hooks/pre-push\"'"
    bash_case deny  "php -r 'unlink(\".git/hooks/pre-push\");'"
    bash_case deny  "node -e 'require(\"child_process\").execSync(\"git push\")'"
    bash_case deny  'H=.git/hooks; rm $H/pre-commit'
    bash_case deny  'rm $(echo .git)/hooks/pre-commit'
    bash_case deny  'pushd .git/hooks && rm pre-commit'
    bash_case deny  'find .git/hooks -name pre-push -delete'
    bash_case deny  'find . -name pre-push -delete'
    bash_case deny  "awk -i inplace '{}' .git/hooks/pre-push"
    bash_case deny  "awk 'BEGIN{system(\"git commit -n\")}'"
    bash_case deny  "echo 'git commit -n' | bash"
    bash_case deny  "bash <<< 'git commit -n'"
    bash_case deny  'echo x > run.sh; bash run.sh'
    bash_case deny  "bash $WORK/bad.sh"
    bash_case deny  "source $WORK/bad.sh"
    bash_case deny  ". $WORK/bad.sh"
    bash_case deny  "$WORK/bad-exec"
    bash_case deny  'bash /nonexistent/x.sh'
    bash_case deny  "git rebase -x 'make' HEAD~1"
    bash_case deny  'git config core.fsmonitor x'
    bash_case deny  'git config core.sshCommand x'
    bash_case deny  'git config remote.origin.receivepack x'
    bash_case deny  'PATH=/tmp/bin git commit -m x'
    bash_case deny  'export PATH=/tmp/bin:$PATH; git commit -m x'
    bash_case deny  'GIT_EXEC_PATH=/tmp git commit -m x'
    bash_case allow "bash $WORK/ok.sh"
    bash_case allow 'python3 -m json.tool composer.json'
    bash_case allow "python3 -c 'print(1)'"
    bash_case allow 'python3 --version'
    bash_case allow "find app -name '*.tmp' -delete"
    bash_case allow "find . -name '*.php' -exec grep -l x {} +"
    bash_case allow 'export PATH=$HOME/bin:$PATH'
    no_bad
}

@test "wrappers, computed command words and \$'..' quoting cannot hide git" {
    bash_case deny  '$(which git) commit -m x'
    bash_case deny  'G=git; $G commit -m x'
    bash_case deny  'echo -n | xargs git commit -m x'
    bash_case deny  'find . -maxdepth 0 -exec git commit -n -m x \;'
    bash_case deny  'timeout -s KILL 5 git commit -n -m x'
    bash_case deny  'ionice -c3 git commit -n -m x'
    bash_case deny  'chrt -i 0 git commit -n -m x'
    bash_case deny  'setsid git commit -n -m x'
    bash_case deny  'flock /tmp/l git commit -n -m x'
    bash_case deny  'sudo -u root git commit -n -m x'
    bash_case deny  "env -S 'git commit -m x'"
    bash_case deny  'env -C /tmp git commit -n -m x'
    bash_case deny  'env A=1 git commit -n -m x'
    bash_case deny  'coproc git commit -n -m x'
    bash_case deny  'watch -n1 git commit -n -m x'
    bash_case deny  'parallel git commit -m ::: x'
    bash_case deny  "git commit \$'-n' -m x"
    bash_case deny  "git commit -m y \$'\\x2d-no-verify'"
    bash_case deny  'git commit -m y "$(echo -n)"'
    bash_case deny  'eval "$(echo git status)"'
    bash_case deny  'sh -c "$(printf x)"'
    bash_case deny  'docker compose exec server git commit -n -m x'
    bash_case deny  'echo git push | script -q /dev/null'
    bash_case deny  'git commit -m x#--no-verify'
    bash_case deny  'git commit -m "unterminated'
    bash_case deny  'git commit -m x \'
    bash_case allow 'docker compose exec -T server nice -n 15 vendor/bin/phpunit tests/Unit/Foo.php'
    bash_case allow "docker compose exec server sh -c 'pkill -f paratest; pkill -f phpunit-wrapper'"
    bash_case allow 'timeout 5 git status'
    bash_case allow 'sudo -u www-data ls'
    no_bad
}

@test "reads, copies from the plugin, sed scripts and repositories under /tmp are not false denials" {
    mkdir -p "$WORK/other/.git"
    bash_case allow 'HOME=/tmp composer install'
    bash_case allow 'cp /code/templates/git-hooks/pre-push /tmp/pp'
    bash_case allow "sed -i 's|.git/hooks|x|' README.md"
    bash_case allow "rm -rf $WORK/other/.git"
    bash_case allow 'jq . .claude/settings.json'
    bash_case allow 'cat ~/.gitconfig'
    bash_case allow "git log --format='%H %s' -- .git/hooks"
    bash_case allow 'sort -u -o out.txt in.txt'
    bash_case allow 'diff <(git show HEAD:a) a'
    bash_case allow 'git -c core.editor=true rebase --continue'
    bash_case deny  'HOME=/tmp git status'
    bash_case deny  'cp /tmp/x /code/bin/guard.sh'
    bash_case deny  'sort -o .git/config in.txt'
    no_bad
}

@test "guard-edit denies .git paths, settings, git config and the plugin; source edits pass" {
    edit_case deny  "$PWD/.git/hooks/pre-commit"
    edit_case deny  "$PWD/.git/config"
    edit_case deny  '.git/info/exclude'
    edit_case deny  "$PWD/app/../.git/config"
    edit_case deny  "$PWD/app/../../repo/.git/hooks/pre-push"
    edit_case deny  "$PWD/.claude/settings.json"
    edit_case deny  "$PWD/.claude/settings.local.json"
    edit_case deny  '~/.claude/settings.json'
    edit_case deny  "$HOME/.claude/settings.local.json"
    edit_case deny  '~/.gitconfig'
    edit_case deny  "$HOME/.config/git/config"
    edit_case deny  '/code/bin/guard.sh'
    edit_case deny  '/code/templates/claude-hooks/guard-edit.sh'
    edit_case deny  "$PWD/.git/x.ipynb" NotebookEdit
    edit_case deny  "$PWD/.git/COMMIT_EDITMSG" Write
    edit_case allow "$PWD/app/Services/ReferralService.php"
    edit_case allow "$PWD/.claude/agents/reviewer.md"
    edit_case allow "$PWD/quality/RULES.md"
    edit_case allow 'app/Models/Post.php'
    edit_case allow "$PWD/notebooks/a.ipynb" NotebookEdit
    no_bad
}

@test "guard-edit denies a linked worktree's .git file" {
    git worktree add -q "$WORK/wt" -b side
    cd "$WORK/wt" || return 1
    [ -f .git ]
    edit_case deny  "$WORK/wt/.git"
    edit_case allow "$WORK/wt/app/x.php"
    no_bad
}

@test "guard-edit denies the git common dir reached through a symlink" {
    mv .git "$WORK/gitstore"
    ln -s "$WORK/gitstore" .git
    git rev-parse --git-common-dir > /dev/null
    edit_case deny  "$WORK/gitstore/hooks/pre-commit"
    edit_case deny  "$WORK/gitstore/config"
    edit_case allow "$WORK/elsewhere/config"
    no_bad
}
