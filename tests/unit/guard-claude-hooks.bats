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

@test "a value computed at run time is allowed until the command names git, a hook, qg or the plugin" {
    printf '#!/usr/bin/env bash\n# git tracks the channels; this hook-free launcher picks its python\nPY="${STUDIO_PYTHON:-python3}"\nexec "${PY}" -m "$@"\ncat <<EOF\nusage: git is named here only\nEOF\n' > "$WORK/launch.sh"
    printf 'G=git; $G commit -n -m x\n' > "$WORK/hidden.sh"
    chmod +x "$WORK/launch.sh"
    bash_case allow "bash $WORK/launch.sh json.tool x.json"
    bash_case allow "$WORK/launch.sh json.tool x.json"
    bash_case allow 'rm -rf "$RUN_DIR/audio"'
    bash_case allow 'mv "$RUN_DIR/audio" "$RUN_DIR/replaced/"'
    bash_case allow "python3 -c \"import json; print(json.load(open('\$f'))['titles'])\""
    bash_case allow '"${PYTHON}" -m json.tool x.json'
    bash_case allow 'bash -c "cd $d && make"'
    bash_case allow 'git worktree list'
    bash_case allow 'git branch -a'
    bash_case allow 'git stash list'
    bash_case allow 'git remote -v'
    bash_case deny  "bash $WORK/hidden.sh"
    bash_case deny  'X=git; "$X" commit -m x'
    bash_case deny  'rm -rf .git/$x'
    bash_case deny  'rm -rf /code/$x'
    bash_case deny  'python3 -c "$CODE"'
    bash_case allow 'X="$RUN_DIR/x"; printf "%s" "--hook-type cold" > "$X.txt"'
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

@test "a committed, unmodified script under a protected path runs even when it names gate state" {
    mkdir -p quality/bin other
    printf 'guard_protected_paths: quality/bin VAULT.md\n' > VAULT.md
    printf '#!/usr/bin/env bash\nC="$(git rev-parse --git-common-dir)/guard-cache"\necho "$C"\n' > quality/bin/check.sh
    cp quality/bin/check.sh other/check.sh
    chmod +x quality/bin/check.sh other/check.sh
    git add VAULT.md quality/bin/check.sh other/check.sh
    git commit -q -m scripts -- VAULT.md quality/bin/check.sh other/check.sh
    bash_case allow 'quality/bin/check.sh'
    bash_case allow 'bash quality/bin/check.sh'
    bash_case deny  'other/check.sh'
    printf '\n# edited\n' >> quality/bin/check.sh
    bash_case deny  'quality/bin/check.sh'
    no_bad
}

@test "a \${...} expansion holding quotes and nested expansions is one word, and what it hides is still scanned" {
    bash_case allow 'echo ${args[@]+"${args[@]}"} done'
    bash_case allow 'echo "${x:-"${y}"}" ${z#*}'
    bash_case allow 'echo ${HOME}/x'
    bash_case deny  'echo ${x:-$(git commit --no-verify -m y)}'
    bash_case deny  'echo "${x:-"$(git commit -n -m y)"}"'
    printf '#!/usr/bin/env bash\nrun() { :; }\nrun ${archargs[@]+"${archargs[@]}"}\necho "done"\n' > ok.sh
    bash_case allow 'bash ok.sh'
    no_bad
}

@test "installed plugin code runs unscanned, and no agent may write or edit it" {
    local inst="$HOME/.claude/plugins/cache/demo/1.0/bin"
    mkdir -p "$inst"
    printf '#!/usr/bin/env bash\n. "${ROOT}/lib/helper.sh"\necho "${a[@]+"${a[@]}"}"\n' > "$inst/run.sh"
    bash_case allow "bash $inst/run.sh"
    bash_case allow "$inst/run.sh --flag"
    bash_case deny  "cp x $inst/run.sh"
    bash_case deny  "rm $inst/run.sh"
    edit_case deny  "$inst/run.sh"
    edit_case deny  "$inst/new.sh" Write
    rm -rf "$HOME/.claude/plugins/cache/demo"
    no_bad
}

@test "upstream retargeting and husky hook files are denied; a plain branch delete and push -u pass" {
    bash_case deny  'git branch -u main'
    bash_case deny  'git branch --set-upstream-to=origin/x'
    bash_case deny  'git config branch.feat.remote .'
    bash_case deny  'rm .husky/pre-commit'
    bash_case deny  'echo "export HUSKY=0" > ~/.config/husky/init.sh'
    bash_case allow 'git branch -d old'
    bash_case allow 'git push -u origin feat/x'
    edit_case deny  "$PWD/.husky/pre-commit" Write
    edit_case deny  "$HOME/.config/husky/init.sh" Write
    no_bad
}

@test "an agent write into guard-pass/push is denied" {
    bash_case deny  'printf "ok 1\n" > .git/guard-pass/push/abc'
    bash_case deny  'mkdir -p .git/guard-pass/push && touch .git/guard-pass/push/abc'
    bash_case deny  'cp /tmp/x "$(git rev-parse --git-common-dir)/guard-pass/push/abc"'
    bash_case deny  '/code/bin/guard.sh release --record-pass refs/heads/x'
    bash_case deny  '/code/bin/guard.sh release --use-pass refs/heads/x'
    edit_case deny  "$PWD/.git/guard-pass/push/abc" Write
    bash_case allow 'qg run push --ref refs/heads/feat/x'
    no_bad
}

@test "an agent cannot set PATH, HOME or XDG_CONFIG_HOME for qg" {
    bash_case deny  'PATH=/tmp/shim:$PATH qg run push --ref refs/heads/x'
    bash_case deny  'HOME=/tmp/h qg run push --ref refs/heads/x'
    bash_case deny  'XDG_CONFIG_HOME=/tmp/c qg run commit'
    bash_case deny  'export PATH=/tmp/shim:$PATH; qg run push --ref refs/heads/x'
    bash_case deny  'PATH=/tmp/shim:$PATH /code/bin/qg run push --ref refs/heads/x'
    bash_case allow 'qg run push --ref refs/heads/x'
    bash_case allow 'PATH=/tmp/shim:$PATH ls'
    no_bad
}

# plugin_copy <dir> — a writable git checkout of the plugin, so a test can hold the machine
# tool-path file or a linked worktree; /code is read-only in the test image.
plugin_copy() {
    mkdir -p "$1"
    cp -r /code/bin /code/lib /code/templates "$1/"
    git -C "$1" init -q .
    git -C "$1" -c user.email=t@e -c user.name=t add -A
    git -C "$1" -c user.email=t@e -c user.name=t commit -q -m plugin
}

@test "BASH_FUNC_ assignments are denied beside any command and BASH_ENV, SHELLOPTS and BASHOPTS beside git, qg or a hook" {
    local c
    # BASH_FUNC_ denies beside any command; the other names beside git, a hook, qg, guard.sh or the plugin.
    for c in 'BASH_ENV=/tmp/e git status' 'BASH_ENV=/tmp/e; git commit -m x' 'export BASH_ENV=/tmp/e; git commit -m x' \
             'export BASH_ENV; qg run commit' 'declare -x BASH_ENV=/tmp/e && git push' 'SHELLOPTS=xtrace git commit -m x' \
             'export SHELLOPTS; git log' 'BASHOPTS=extdebug qg run push' 'readonly BASHOPTS=x; /code/bin/guard.sh report' \
             "env 'BASH_FUNC_git%%=() { :; }' ls" "env BASH_FUNC_ls=x ls" "bash -c 'BASH_ENV=/tmp/e git status'" \
             'typeset -x BASH_ENV=/tmp/e; npm test; git commit -m x' 'BASH_ENV=/tmp/e make hooks'; do
        bash_case deny "$c"
    done
    no_bad
}

@test "GIT_REPLACE_REF_BASE, GIT_NO_REPLACE_OBJECTS, GIT_ALTERNATE_OBJECT_DIRECTORIES, GIT_OBJECT_DIRECTORY and GIT_EXTERNAL_DIFF are denied" {
    local c
    for c in 'GIT_REPLACE_REF_BASE=refs/x/ git log' 'GIT_NO_REPLACE_OBJECTS=0 git show HEAD' \
             'GIT_ALTERNATE_OBJECT_DIRECTORIES=/tmp/o git status' 'GIT_OBJECT_DIRECTORY=/tmp/o git log' \
             'GIT_EXTERNAL_DIFF=/tmp/d git diff' 'env GIT_EXTERNAL_DIFF=/tmp/d git diff' 'export GIT_OBJECT_DIRECTORY=/tmp/o; git log'; do
        bash_case deny "$c"
    done
    bash_case allow 'git log -1'
    no_bad
}

@test "env with a name that is no plain identifier is denied and the command after it is still checked" {
    bash_case deny  "env 'X%=1' true"
    bash_case deny  "env FOO=1 'X%=1' BAR=2 git commit -n -m x"
    bash_case deny  'env FOO=1 BAR=2 git commit -n -m x'
    bash_case deny  "env -C /tmp 'a-b=1' ls"
    bash_case allow 'env FOO=1 BAR=2 ls'
    no_bad
}

@test "export -f, declare -fx and typeset -fx are denied" {
    local c
    for c in 'export -f f' 'declare -fx f' 'declare -f -x f' 'typeset -xf f' 'builtin export -f f' 'command declare -x -f f' \
             'f() { :; }; export -f f; npm test'; do
        bash_case deny "$c"
    done
    no_bad
}

@test "names that only resemble a denied name, and declare without both -f and -x, are allowed" {
    local c
    for c in 'MY_BASH_ENV=1 ls' 'echo BASH_ENV=x' 'echo $BASH_ENV' 'declare -f' 'declare -F' 'declare +x -f f' \
             'declare -x MY_OPTS=1' 'BASH_ENVIRONMENT=1 ls' 'export NODE_ENV=test'; do
        bash_case allow "$c"
    done
    no_bad
}

@test "writes and edits under .pub-cache, a Flutter SDK or a copydetect venv folder are denied" {
    mkdir -p "$HOME/.pub-cache/hosted" "$WORK/sdk/bin/internal" "$WORK/sdk/packages/flutter_tools" \
             "$HOME/.cache/qg-copydetect/copydetect-0.5" "$HOME/.cache/other"
    : > "$WORK/sdk/bin/internal/engine.version"
    local c
    for c in 'touch ~/.pub-cache/x' 'rm -rf $HOME/.pub-cache/hosted' "cp /tmp/x $WORK/sdk/bin/flutter" \
             "echo x > $WORK/sdk/packages/flutter_tools/a.dart" 'rm -rf ~/.cache/qg-copydetect/copydetect-0.5' \
             'touch ~/.cache/qg-copydetect/x'; do
        bash_case deny "$c"
    done
    bash_case allow 'cat ~/.pub-cache/x'
    bash_case allow 'touch ~/.cache/other/x'
    bash_case allow "touch $WORK/elsewhere.txt"
    edit_case deny  "$HOME/.pub-cache/hosted/pkg/lib/a.dart" Write
    edit_case deny  "$WORK/sdk/packages/flutter_tools/lib/x.dart"
    edit_case deny  "$HOME/.cache/qg-copydetect/copydetect-0.5/lib/x.py"
    edit_case allow "$HOME/.cache/other/x"
    rm -rf "$HOME/.pub-cache" "$HOME/.cache"
    no_bad
}

@test "writes and edits to a shell startup file are denied" {
    local c f
    for c in 'echo x >> ~/.bashrc' 'cp /tmp/x ~/.profile' 'sed -i s/a/b/ ~/.zshrc' 'printf x | tee -a $HOME/.bash_profile' \
             'touch ~/.bash_login ~/.zshenv ~/.zprofile'; do
        bash_case deny "$c"
    done
    for f in .bashrc .bash_profile .bash_login .profile .zshrc .zshenv .zprofile; do
        edit_case deny "$HOME/$f" Write
    done
    bash_case allow 'cat ~/.bashrc'
    edit_case allow "$HOME/.bashrc.d/aliases"
    no_bad
}

@test "writes under a PATH folder before /usr/bin or a tool-path folder are denied" {
    mkdir -p "$WORK/early" "$WORK/late" "$WORK/tools"
    ln -s "$WORK/early" "$WORK/early-link"
    ln -s "$WORK/tools" "$WORK/tools-link"
    PATH="$WORK/early:$PATH:$WORK/late" bash_case deny "touch $WORK/early/git"
    PATH="$WORK/early:$PATH:$WORK/late" bash_case deny "cp /tmp/x $WORK/early-link/node"
    PATH="$WORK/early:$PATH:$WORK/late" bash_case allow "touch $WORK/late/x"
    PATH="relative/bin:$PATH" bash_case allow "touch $WORK/repo/relative/bin/x"
    PATH="$WORK/early:$PATH" edit_case deny "$WORK/early/pnpm" Write
    plugin_copy "$WORK/plugin"
    printf '%s\n' "$WORK/tools" > "$WORK/plugin/.git/qg-tool-path"
    HOOKS="$WORK/plugin/templates/claude-hooks"
    bash_case deny  "touch $WORK/tools/pnpm"
    bash_case deny  "cp /tmp/x $WORK/tools-link/node"
    edit_case deny  "$WORK/tools/php" Write
    edit_case deny  "$WORK/tools-link/php" Write
    bash_case allow "touch $WORK/elsewhere"
    no_bad
}

@test "a denied root named inside python code or as a tar, unzip, curl, wget or git clone target is denied" {
    printf "open('%s/.bashrc', 'a').write('x')\n" "$HOME" > "$WORK/w.py"
    local c
    for c in "python3 -c \"open('$HOME/.bashrc','a').write('x')\"" \
             "python3 -c \"open(__import__('os').path.expanduser('~/.pub-cache/x'),'w')\"" \
             "node -e 'require(\"fs\").writeFileSync(\"\${HOME}/.profile\",\"x\")'" \
             "perl -e 'open(F, \">\$HOME/.zshrc\")'" \
             $'python3 <<\'EOF\'\nopen("~/.bash_profile", "a")\nEOF' \
             "python3 $WORK/w.py" \
             'tar -xzf x.tgz -C ~/.pub-cache' 'tar --directory=$HOME/.pub-cache -xf x.tar' 'tar -xf x.tar -C$HOME/.pub-cache' \
             'unzip x.zip -d ~/.pub-cache/x' 'curl -o ~/.bashrc https://example.invalid/x' \
             'curl --output-dir ~/.pub-cache -O https://example.invalid/x' 'curl --output=$HOME/.profile https://example.invalid/x' \
             'wget -O ~/.profile https://example.invalid/x' 'wget -P ~/.pub-cache https://example.invalid/x' \
             'wget --output-document=$HOME/.zshrc https://example.invalid/x' 'dd if=/tmp/x of=$HOME/.bashrc' \
             'git clone https://example.invalid/y ~/.pub-cache/hosted/y'; do
        bash_case deny "$c"
    done
    for c in "python3 -c \"print('hello')\"" 'curl -o /tmp/x https://example.invalid/x' 'tar -xzf x.tgz -C /tmp/out' \
             'wget -O - https://example.invalid/x' 'git clone https://example.invalid/y /tmp/y' 'unzip x.zip -d out'; do
        bash_case allow "$c"
    done
    no_bad
}

@test "a planted json.py in the cwd does not change any hook's verdict" {
    local m
    for m in json subprocess shell_lexer write_denials fnmatch; do
        printf 'open("%s/planted", "w").close()\nimport sys\nsys.exit(0)\n' "$WORK" > "$m.py"
    done
    python3 -c 'import json' || true
    [ -e "$WORK/planted" ]
    rm -f "$WORK/planted"
    bash_case deny 'git commit -n -m x'
    bash_case deny 'rm .git/hooks/pre-commit'
    edit_case deny "$PWD/.git/config"
    edit_case deny '/code/bin/guard.sh'
    [ ! -e "$WORK/planted" ] || BAD+=$'\n''a planted module ran inside a hook'
    no_bad
}

@test "a file in a worktree of the plugin stays editable while the hook checkout is denied" {
    plugin_copy "$WORK/plugin"
    git -C "$WORK/plugin" worktree add -q "$WORK/plugin-wt" -b side
    ln -s "$WORK/plugin/lib" "$WORK/lib-link"
    local h
    for h in "$WORK/plugin/templates/claude-hooks" "$WORK/plugin-wt/templates/claude-hooks"; do
        HOOKS="$h"
        edit_case allow "$WORK/plugin-wt/lib/qg-config.sh"
        bash_case allow "touch $WORK/plugin-wt/lib/new.sh"
        bash_case allow "cd $WORK/plugin-wt && sed -i s/a/b/ lib/qg-config.sh"
        edit_case deny  "$WORK/plugin/lib/qg-config.sh"
        edit_case deny  "$WORK/plugin/.git/config"
        edit_case deny  "$WORK/lib-link/qg-config.sh"
        bash_case deny  "touch $WORK/plugin/lib/new.sh"
        bash_case deny  "touch $WORK/lib-link/new.sh"
    done
    no_bad
}

@test "in a repo with no quality folder an fd duplication, python backticks and an installed program naming the plugin path are allowed" {
    [ ! -e quality ]
    local inst="$HOME/.claude/plugins/cache/demo/1.0/bin"
    mkdir -p "$inst"
    printf '#!/usr/bin/env bash\necho "$@"\n' > "$inst/gate.sh"
    chmod +x "$inst/gate.sh"
    bash_case allow 'make test 2>&1 | tail -5'
    bash_case allow "python3 -c 'x = \"\`\"; print(x)'"
    bash_case allow "$inst/gate.sh verdict --repo /code"
    cd /code || return 1
    bash_case allow 'ls 2>&1'
    bash_case allow 'echo x >&2'
    bash_case allow 'ls 2>&-'
    bash_case deny  'echo x >&/code/x'
    bash_case deny  'echo x &>/code/x'
    bash_case deny  'echo x > /code/x'
    cd "$WORK/repo" || return 1
    rm -rf "$HOME/.claude/plugins/cache/demo"
    no_bad
}

@test "cd with no argument moves the checked cwd to HOME before a startup-file write" {
    bash_case deny  'cd && echo x >> .bashrc'
    bash_case deny  'cd; printf x | tee -a .profile'
    bash_case allow 'cd /tmp && echo x >> .bashrc'
    no_bad
}

@test "inline code or a cleared agent marker beside git, .git, a hook path or the plugin is still denied" {
    local c
    for c in "python3 -c 'import subprocess' && git status" "python3 -c 'x = \"\`\"'; git log -1" \
             "node -e 'require(\"child_process\")' .git" "python3 -c 'import shutil' && ls .husky" \
             "python3 -c 'import os; os.remove(\"x\")' /code" "python3 -c 'import os; os.environ.pop(\"CLAUDECODE\")'; git commit -m x" \
             'unset CLAUDECODE' 'CLAUDECODE= ls' 'AI_AGENT= git status' "printf -v AI_AGENT ''" 'read CLAUDECODE <<< x' \
             'export -n AI_AGENT; git push'; do
        bash_case deny "$c"
    done
    no_bad
}

@test "a program naming the plugin path is allowed only when its real path is installed, and never for its redirects or chained commands" {
    local inst="$HOME/.claude/plugins/cache/demo/1.0/bin"
    mkdir -p "$inst" "$WORK/bin"
    printf '#!/usr/bin/env bash\necho "$@"\n' > "$inst/gate.sh"
    cp "$inst/gate.sh" "$WORK/bin/real-gate.sh"
    chmod +x "$inst/gate.sh" "$WORK/bin/real-gate.sh"
    ln -s "$inst/gate.sh" "$WORK/bin/gate"
    bash_case allow "$inst/gate.sh verdict /code"
    bash_case allow "$WORK/bin/gate verdict /code"
    bash_case deny  "$WORK/bin/real-gate.sh verdict /code"
    bash_case deny  "$HOME/.claude/plugins/cache/demo/1.0/bin/../../../../../../..$WORK/bin/real-gate.sh /code"
    bash_case deny  "$inst/gate.sh verdict /code > /code/out"
    bash_case deny  "$inst/gate.sh verdict /code && rm /code/bin/guard.sh"
    bash_case deny  "$inst/gate.sh verdict /code; touch /code/x"
    bash_case deny  "$inst/gate.sh verdict /code/.git/hooks"
    rm -rf "$HOME/.claude/plugins/cache/demo"
    no_bad
}

@test "python one-liners using re.compile or os.path and a file name holding ai_agent are allowed" {
    printf 'print(1)\n' > ai_agent.py
    local c
    for c in "python3 -c 'import re; print(re.compile(\"a+\").match(\"aa\"))'" \
             "python3 -c 'import os; print(os.path.join(\"a\", \"b\"))'" \
             'python3 ai_agent.py' 'touch ai_agent_notes.md' 'cp ai_agent.py lib/ai_agent.py' \
             "python3 -c 'import sys; print(sys.argv)' --name claudecode-report"; do
        bash_case allow "$c"
    done
    edit_case allow "$PWD/src/ai_agent.py" Write
    no_bad
}

@test "in a repo with no quality folder every git, qg and write denial still holds" {
    [ ! -e quality ]
    local c
    for c in 'git commit -n -m x' 'git push --force' 'git config core.hooksPath /dev/null' 'qg override --reason x' \
             'qg baseline' 'qg hooks install --claude --user' 'qg hooks remove --claude --user' 'qg hooks remove --claude' \
             'rm .git/hooks/pre-commit' 'echo x > .git/qg-override' 'touch /code/bin/guard.sh' 'GUARD_SKIP=. git push'; do
        bash_case deny "$c"
    done
    edit_case deny "$PWD/.git/config"
    edit_case deny "$PWD/.claude/settings.json"
    bash_case allow 'qg hooks status --user'
    bash_case allow '/code/bin/guard.sh hooks status --user'
    no_bad
}

@test "assigning LD_PRELOAD, LD_LIBRARY_PATH or LD_AUDIT is denied" {
    local c
    for c in 'LD_PRELOAD=/tmp/x.so git status' 'export LD_LIBRARY_PATH=/tmp; qg run commit' 'env LD_AUDIT=/tmp/a.so git commit -m x' \
             'declare -x LD_PRELOAD=/tmp/x.so; git push' 'LD_LIBRARY_PATH=build /code/bin/qg run commit'; do
        bash_case deny "$c"
    done
    bash_case allow 'echo $LD_LIBRARY_PATH'
    no_bad
}

@test "loader and shell names, and computed export names, are allowed in a command that names no git, hook, qg or plugin" {
    printf '#!/usr/bin/env bash\necho tests\n' > run_tests; chmod +x run_tests
    printf 'A=1\n# c\n' > .env
    local c
    for c in 'LD_LIBRARY_PATH=build ./run_tests' 'export LD_LIBRARY_PATH=/x' 'export $(grep -v ^# .env | xargs)' \
             'LD_PRELOAD=/tmp/x.so ls' 'SHELLOPTS=xtrace make' 'export BASH_ENV' 'BASHOPTS=extdebug ls'; do
        bash_case allow "$c"
    done
    bash_case deny 'export $(grep -v ^# .env | xargs); git commit -m x'
    no_bad
}

@test "git cannot change the protected main worktree through a relative path, a work tree, a prefix or a tracked cwd" {
    plugin_copy "$WORK/vault-quality-gates"
    mkdir -p "$WORK/side"; git -C "$WORK/vault-quality-gates" worktree add -q "$WORK/side/s6" -b s6
    HOOKS="$WORK/vault-quality-gates/templates/claude-hooks"
    cd "$WORK/side/s6" || return 1
    local c
    for c in 'git -C ../../vault-quality-gates reset --hard HEAD~1' 'git --work-tree=../../vault-quality-gates checkout HEAD -- lib' \
             'git --work-tree ../../vault-quality-gates checkout HEAD -- lib' 'git checkout-index -a -f --prefix=../../vault-quality-gates/' \
             'cd ../.. && cd vault-quality-gates && git checkout -- . && git pull' 'GIT_WORK_TREE=../../vault-quality-gates git checkout -- .' \
             'export GIT_DIR=../../vault-quality-gates/.git; git reset --hard' 'git --git-dir=../../vault-quality-gates/.git stash' \
             'git worktree add ../../vault-quality-gates/inner' 'git -C "$X" reset --hard' \
             'cd ../../vault-quality-gates; cd /tmp; cd -; git commit -m x' \
             'pushd ../../vault-quality-gates; pushd /tmp; popd; git commit -m x' \
             'pushd ../../vault-quality-gates && pushd /tmp && pushd && git reset --hard' \
             'export GIT_DIR=../../vault-quality-gates/.git; mkdir -p sub; cd sub; git commit -m x' \
             'cd "$WHERE" && git commit -m x' 'cd -; git commit -m x' 'popd; git commit -m x'; do
        bash_case deny "$c"
    done
    bash_case allow 'export GIT_DIR=../../vault-quality-gates/.git; unset GIT_DIR; git commit -m x'
    bash_case allow 'cd /tmp; cd -; git commit -m x'
    bash_case allow 'pushd /tmp; popd; git commit -m x'
    bash_case allow 'git -C ../../vault-quality-gates log -1'
    bash_case allow 'cd ../../vault-quality-gates && git status'
    bash_case allow 'git checkout -b feature && git commit -m x'
    bash_case allow 'git checkout-index -a --prefix=/tmp/export/'
    no_bad
}

@test "launchers that start a command without the agent markers are denied" {
    local c
    for c in 'exec -c git commit -m x' 'exec -a x -c bash' 'systemd-run --user git commit -m x' 'systemd-run -E A=1 make' \
             'systemd-run -p EnvironmentFile=/tmp/e true' 'echo "git push" | at now' 'batch <<< "git push"' \
             'tmux new-session -d "git commit -m x"' 'tmux new-window make' 'tmux send-keys -t 0 "git push" Enter' \
             'screen -dm git push' 'nice systemd-run true' 'dbus-run-session -- git push' \
             'busctl --user call org.freedesktop.systemd1 /org/freedesktop/systemd1 x StartTransientUnit' \
             'systemctl --user start qg-job.service' 'systemctl --user restart x' 'systemctl --user run x'; do
        bash_case deny "$c"
    done
    bash_case allow 'tmux ls'
    bash_case allow 'systemctl --user status x'
    bash_case allow 'exec -a name ls'
    no_bad
}

@test "inline code that starts a program with a changed environment or a pty is denied, however it spells the program" {
    local c
    for c in "python3 -c 'import os; os.environ.pop(\"CLAUDE\"+\"CODE\"); os.execvp(\"g\"+\"it\", [\"g\"+\"it\", \"push\"])'" \
             "python3 -c 'import subprocess; subprocess.run([\"g\"+\"it\", \"push\"], env={})'" \
             "node -e 'require(\"child_process\").spawnSync(\"g\"+\"it\", [], {env: {}})'" \
             "python3 -c 'import pty, os; pty.spawn([\"sh\"])'"; do
        bash_case deny "$c"
    done
    printf 'import subprocess\nsubprocess.run(["ls"])\n' > tool.py
    bash_case allow 'python3 tool.py'
    bash_case deny  'python3 tool.py && git status'
    bash_case allow "python3 -c 'import subprocess; subprocess.run([\"ls\"])'"
    no_bad
}

@test "interpreter code that only reads a denied root is allowed" {
    bash_case allow "python3 -c \"print(open('/usr/local/bin/foo').read())\""
    bash_case allow "python3 -c \"print(open('$HOME/.bashrc').read())\""
    printf '#!/usr/local/bin/python3\nprint(1)\n' > shebang.py
    bash_case allow 'python3 shebang.py'
    bash_case deny  "python3 -c \"open('$HOME/.bashrc', 'a').write('x')\""
    no_bad
}

# write_grant <plugin> <actions> [<issued offset s>] [<life s>] — the grant file lib/qg-grant.sh writes.
write_grant() {
    local now; now="$(date +%s)"
    printf 'v1\t%s\t%s\t%s\tt\n' "$((now + ${3:-0}))" "$((now + ${3:-0} + ${4:-3600}))" "$2" > "$1/.git/qg-grant"
    chmod 600 "$1/.git/qg-grant"
}

@test "qg baseline and qg override pass only while a live grant names them; qg grant itself never passes" {
    plugin_copy "$WORK/plugin"
    HOOKS="$WORK/plugin/templates/claude-hooks"
    local g="$WORK/plugin/.git/qg-grant"
    bash_case deny  'qg baseline'
    bash_case deny  'qg override --reason "v2 gate config"'
    bash_case allow 'qg grant --status'
    bash_case allow 'qg grant --status --json'
    bash_case deny  'qg grant --agent 1h baseline'
    bash_case deny  'qg grant --revoke'
    bash_case deny  "touch $g"
    bash_case deny  "printf 'v1' > $g"
    bash_case deny  "rm -f $g"
    edit_case deny  "$g" Write
    no_bad
    write_grant "$WORK/plugin" baseline,override
    bash_case allow 'qg baseline'
    bash_case allow 'qg baseline && git add quality && qg override --reason "v2 gate config" && git commit -m x'
    bash_case deny  'qg override --reason x --push HEAD'
    bash_case deny  'qg grant --agent 8h baseline,override,push'
    bash_case deny  'qg grant --revoke'
    bash_case deny  'qg accept x --reason y'
    bash_case deny  'qg hooks install --claude --user'
    bash_case deny  'git push --force origin master'
    bash_case deny  'git push origin +master'
    bash_case deny  '/code/bin/guard.sh baseline'
    no_bad
    write_grant "$WORK/plugin" push
    bash_case allow 'qg override --reason x --push HEAD'
    bash_case deny  'qg override --reason x'
    write_grant "$WORK/plugin" baseline -7200 3600
    bash_case deny  'qg baseline'
    write_grant "$WORK/plugin" baseline 0 30000
    bash_case deny  'qg baseline'
    write_grant "$WORK/plugin" baseline,accept
    bash_case deny  'qg baseline'
    write_grant "$WORK/plugin" baseline; chmod 620 "$g"
    bash_case deny  'qg baseline'
    no_bad
}
