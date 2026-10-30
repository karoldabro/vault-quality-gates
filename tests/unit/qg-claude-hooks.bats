#!/usr/bin/env bats
# templates/claude-hooks/* — the agent guards for the surfaces qg adds: the qg command, the
# override token, quality/drivers/ and quality/config, and the git directory. 2 denies, 0 allows.

load guard-helpers

HOOKS=/code/templates/claude-hooks

setup() {
    export LC_ALL=C
    WORK="$(mktemp -d)"
    mkdir -p "$WORK/repo/quality" "$HOME"
    cd "$WORK/repo" || return 1
    git init -q .
    git config user.email 'test@example.invalid'
    git config user.name 'test'
    git commit -q --allow-empty -m init
    mark_gated .
    BAD=''
}

teardown() {
    [ -n "${WORK:-}" ] && [ -d "$WORK" ] && rm -rf "$WORK"
    return 0
}

bash_case() {
    local want="$1" cmd="$2" rc=0
    jq -nc --arg c "$cmd" --arg d "$PWD" '{tool_name:"Bash",cwd:$d,tool_input:{command:$c}}' \
        | "$HOOKS/guard-bash.sh" > /dev/null 2>&1 || rc=$?
    [ "$want" = deny ] && [ "$rc" -ne 2 ] && BAD+=$'\n'"not denied (exit $rc): $cmd"
    [ "$want" = allow ] && [ "$rc" -ne 0 ] && BAD+=$'\n'"not allowed (exit $rc): $cmd"
    return 0
}

edit_case() {
    local want="$1" path="$2" rc=0
    jq -nc --arg p "$path" --arg d "$PWD" '{tool_name:"Write",cwd:$d,tool_input:{file_path:$p}}' \
        | "$HOOKS/guard-edit.sh" > /dev/null 2>&1 || rc=$?
    [ "$want" = deny ] && [ "$rc" -ne 2 ] && BAD+=$'\n'"edit not denied (exit $rc): $path"
    [ "$want" = allow ] && [ "$rc" -ne 0 ] && BAD+=$'\n'"edit not allowed (exit $rc): $path"
    return 0
}

no_bad() { [ -z "$BAD" ] || { printf '%s\n' "$BAD" >&2; return 1; }; }

@test "qg: reads and runs are allowed; every command that changes the gate is denied, by any path and option order" {
    local c
    for c in 'qg' 'qg help' 'qg list --json' 'qg explain phpstan-new' 'qg last' 'qg drivers' 'qg doctor' \
             'qg run commit' 'qg --json run push --ref refs/heads/x' 'qg config get guard_commit_paths' 'qg hooks status' \
             '/code/bin/qg explain x' 'qg verify HEAD~1..HEAD'; do
        bash_case allow "$c"
    done
    for c in 'qg override --reason x' 'qg --json override --reason x' 'qg hooks install --claude' 'qg hooks remove' \
             'qg baseline' 'qg accept cov --reason x' 'qg migrate --draft' 'qg init --profile docs' \
             '/code/bin/qg override --reason x' 'nice -n 5 qg hooks remove' 'bash -c "qg baseline"' 'cd /tmp && qg accept x'; do
        bash_case deny "$c"
    done
    no_bad
}

@test "the override token and the run records cannot be written by any writer" {
    local c
    for c in 'printf x > .git/qg-override' 'tee .git/qg-override <<< x' 'cp /tmp/t .git/qg-override' \
             'echo x >> "$(git rev-parse --git-common-dir)/qg-override"' 'rm -rf .git/qg-last' 'touch .git/anything-new' \
             'mkdir .git/x'; do
        bash_case deny "$c"
    done
    bash_case allow 'cat .git/qg-last/REFUSAL.txt'
    no_bad
}

@test "a linked worktree's git dir and the common dir are both protected" {
    git worktree add -q "$WORK/wt" -b wt
    cd "$WORK/wt" || return 1
    bash_case deny "printf x > $WORK/repo/.git/worktrees/wt/x"
    bash_case deny "printf x > $WORK/repo/.git/qg-override"
    no_bad
}

@test "another repo's git directory is protected too, by absolute path or after cd" {
    # The hook exempts scratch repos under /tmp; real repos live elsewhere, so build these under /var/tmp.
    [ -w /var/tmp ] || skip '/var/tmp is not writable in this image'
    local real; real="$(mktemp -d -p /var/tmp)"
    mkdir -p "$real/other" && git -C "$real/other" init -q . \
        && git -C "$real/other" -c user.email=t@e -c user.name=t commit -q --allow-empty -m init
    mark_gated "$real/other"
    mkdir -p "$real/plain"; cd "$real/plain" || return 1
    bash_case deny "printf 'a b' > $real/other/.git/info/grafts"
    bash_case deny "printf x > $real/other/.git/refs/heads/feat-x"
    bash_case deny "cd $real/other && printf 'a b' > .git/info/grafts"
    bash_case allow "printf x > $real/other/notes.txt"
    rm -rf "$real"
    no_bad
}

@test "quality/drivers/ and quality/config cannot be written by Bash or the edit tools; the rest of quality/ can" {
    local c
    for c in 'printf x > quality/config' 'mkdir -p quality/drivers && cp /tmp/x quality/drivers/phpstan.sh' \
             'echo x > quality/drivers/mine.sh' 'mv /tmp/c quality/config'; do
        bash_case deny "$c"
    done
    bash_case allow 'printf x > quality/notes.md'
    bash_case allow 'printf x > /tmp/elsewhere/quality/config'
    edit_case deny "$WORK/repo/quality/config"
    edit_case deny "$WORK/repo/quality/drivers/mine.sh"
    edit_case allow "$WORK/repo/quality/README.md"
    edit_case allow "$WORK/repo/quality/configuration.md"
    no_bad
}

# --- user-level install: qg hooks install|remove|status --claude --user ------------------------
#
# Each case copies the plugin into a writable git checkout ($WORK/plugin, its main worktree) and
# points HOME at a temp folder, so ~/.claude/settings.json is the test's own.

FOREIGN='{"model":"x","hooks":{"PreToolUse":[{"matcher":"Read","hooks":[{"type":"command","command":"/other.sh"}]}],"Stop":[{"hooks":[{"type":"command","command":"/stop-other.sh"}]}]}}'

user_setup() {
    export HOME="$WORK/home"
    mkdir -p "$HOME/.claude" "$WORK/plugin"
    cp -r /code/bin /code/lib /code/templates /code/drivers /code/extend "$WORK/plugin/"
    git -C "$WORK/plugin" init -q .
    git -C "$WORK/plugin" -c user.email=t@e -c user.name=t add -A
    git -C "$WORK/plugin" -c user.email=t@e -c user.name=t commit -q -m plugin
    PLUGIN_REAL="$(cd -P "$WORK/plugin" && pwd)"
    QG="$WORK/plugin/bin/qg"
}

# guard_entries <file> -> the commands of every guard entry, one per line.
guard_entries() {
    jq -r '[(.hooks.PreToolUse[]?, .hooks.Stop[]?) | .hooks[]? | .command | select(test("guard-(bash|edit|stop)\\.sh"))] | .[]' "$1"
}

# foreign <file> -> every entry that is not a guard, sorted, as JSON.
foreign() {
    jq -cS '[(.hooks.PreToolUse[]?, .hooks.Stop[]?) | select(any(.hooks[]?; .command | test("guard-(bash|edit|stop)\\.sh") | not))], del(.hooks)' "$1"
}

@test "hooks install --claude --user twice leaves two guard entries and keeps other entries" {
    user_setup
    printf '%s\n' "$FOREIGN" > "$HOME/.claude/settings.json"
    local before; before="$(foreign "$HOME/.claude/settings.json")"
    run "$QG" hooks install --claude --user
    [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
    local first; first="$(jq -S . "$HOME/.claude/settings.json")"
    run "$QG" hooks install --claude --user
    [ "$status" -eq 0 ]
    [ "$(jq -S . "$HOME/.claude/settings.json")" = "$first" ]
    [ "$(guard_entries "$HOME/.claude/settings.json" | wc -l)" -eq 2 ]
    [ "$(foreign "$HOME/.claude/settings.json")" = "$before" ]
}

@test "hooks install --claude --user writes the same entries into each --config-dir" {
    user_setup
    run "$QG" hooks install --claude --user --config-dir "$WORK/factory" --config-dir "$WORK/other/"
    [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
    local want; want="$(guard_entries "$HOME/.claude/settings.json")"
    [ "$(printf '%s\n' "$want" | wc -l)" -eq 2 ]
    [ "$(guard_entries "$WORK/factory/settings.json")" = "$want" ]
    [ "$(guard_entries "$WORK/other/settings.json")" = "$want" ]
}

@test "hooks install --claude --user writes commands under the main worktree" {
    user_setup
    ln -s "$WORK/plugin" "$WORK/plugin-link"
    run "$WORK/plugin-link/bin/qg" hooks install --claude --user
    [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
    [ "$(guard_entries "$HOME/.claude/settings.json")" = "$(printf '%s/templates/claude-hooks/%s\n' "$PLUGIN_REAL" guard-bash.sh "$PLUGIN_REAL" guard-edit.sh)" ]
}

@test "hooks install --claude --user writes the machine tool-path file from the caller's PATH" {
    user_setup
    mkdir -p "$WORK/t1" "$WORK/t2" "$WORK/t3"
    local t
    for t in t1/pnpm t1/php t2/node t2/pnpm t3/composer; do printf '#!/bin/sh\n' > "$WORK/$t"; chmod +x "$WORK/$t"; done
    PATH="$WORK/t1:$WORK/t2:$WORK/t3:$PATH" run "$QG" hooks install --claude --user
    [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
    [ "$(cat "$WORK/plugin/.git/qg-tool-path")" = "$(printf '%s\n' "$WORK/t1" "$WORK/t2" "$WORK/t3")" ]
}

@test "hooks install --claude --user refuses when its own checkout is a linked worktree" {
    user_setup
    git -C "$WORK/plugin" worktree add -q "$WORK/plugin-wt" -b side
    run "$WORK/plugin-wt/bin/qg" hooks install --claude --user
    [ "$status" -eq 2 ]
    [[ "$output" == *'linked worktree'* ]]
    [ ! -e "$HOME/.claude/settings.json" ]
    [ ! -e "$WORK/plugin/.git/qg-tool-path" ]
}

@test "hooks remove --claude --user removes exactly the two guard entries" {
    user_setup
    printf '%s\n' "$FOREIGN" > "$HOME/.claude/settings.json"
    mkdir -p "$WORK/factory"
    printf '{"env":{"A":"1"}}\n' > "$WORK/factory/settings.json"
    "$QG" hooks install --claude --user --config-dir "$WORK/factory" > /dev/null
    run "$QG" hooks remove --claude --user --config-dir "$WORK/factory"
    [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
    [ "$(jq -S . "$HOME/.claude/settings.json")" = "$(jq -S . <<<"$FOREIGN")" ]
    [ "$(jq -cS . "$WORK/factory/settings.json")" = '{"env":{"A":"1"}}' ]
}

@test "hooks remove --claude --user twice leaves settings byte-identical to the first remove" {
    user_setup
    printf '%s\n' "$FOREIGN" > "$HOME/.claude/settings.json"
    "$QG" hooks install --claude --user > /dev/null
    "$QG" hooks remove --claude --user > /dev/null
    cp "$HOME/.claude/settings.json" "$WORK/first"
    run "$QG" hooks remove --claude --user
    [ "$status" -eq 0 ]
    cmp "$WORK/first" "$HOME/.claude/settings.json"
}

@test "hooks install --claude --user leaves an invalid settings.json unchanged and exits 2" {
    user_setup
    printf '{"hooks": [not json\n' > "$HOME/.claude/settings.json"
    cp "$HOME/.claude/settings.json" "$WORK/before"
    run "$QG" hooks install --claude --user --config-dir "$WORK/factory"
    [ "$status" -eq 2 ]
    cmp "$WORK/before" "$HOME/.claude/settings.json"
    [ ! -e "$WORK/factory/settings.json" ]
    run "$QG" hooks remove --claude --user
    [ "$status" -eq 2 ]
    cmp "$WORK/before" "$HOME/.claude/settings.json"
}

@test "hooks install --claude --user replaces an older guard entry naming another folder and drops the retired Stop entry" {
    user_setup
    printf '%s\n' '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"/old/vault-quality-gates/templates/claude-hooks/guard-bash.sh"}]},{"matcher":"Read","hooks":[{"type":"command","command":"/other.sh"}]}],"Stop":[{"hooks":[{"type":"command","command":"/old/vault-quality-gates/templates/claude-hooks/guard-stop.sh","timeout":30}]}]}}' \
        > "$HOME/.claude/settings.json"
    run "$QG" hooks install --claude --user
    [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
    [ "$(guard_entries "$HOME/.claude/settings.json" | wc -l)" -eq 2 ]
    run grep -c '/old/' "$HOME/.claude/settings.json"
    [ "$output" = 0 ]
    jq -e '.hooks.PreToolUse[] | select(.matcher == "Read")' "$HOME/.claude/settings.json" > /dev/null
}

@test "hooks remove --claude removes the two repo-level entries and keeps every other entry and the git hooks" {
    run /code/bin/qg hooks install --claude
    [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
    jq '.hooks.PreToolUse += [{"matcher":"Read","hooks":[{"type":"command","command":"/other.sh"}]}] | .model = "x"' \
        .claude/settings.json > "$WORK/s" && cat "$WORK/s" > .claude/settings.json
    run /code/bin/qg hooks remove --claude
    [ "$status" -eq 0 ]
    [ -z "$(guard_entries .claude/settings.json)" ]
    [ "$(jq -cS . .claude/settings.json)" = '{"hooks":{"PreToolUse":[{"hooks":[{"command":"/other.sh","type":"command"}],"matcher":"Read"}]},"model":"x"}' ]
    grep -q vault-guard-start .git/hooks/pre-commit
    grep -q vault-guard-start .git/hooks/pre-push
}

@test "hooks install writes the tool-path from the caller's PATH, never a forged QG_CALLER_PATH" {
    user_setup
    mkdir -p "$WORK/real" "$WORK/forged"
    printf '#!/bin/sh\n' > "$WORK/real/pnpm"; cp "$WORK/real/pnpm" "$WORK/forged/pnpm"
    chmod +x "$WORK/real/pnpm" "$WORK/forged/pnpm"
    QG_CALLER_PATH="$WORK/forged" PATH="$WORK/real:$PATH" run "$QG" hooks install --claude --user
    [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
    [ "$(cat "$WORK/plugin/.git/qg-tool-path")" = "$WORK/real" ]
}

@test "hooks status --user reports each guard entry installed or absent per target file" {
    user_setup
    run "$QG" hooks status --user --config-dir "$WORK/factory"
    [ "$status" -eq 0 ]
    [ "$(grep -c '^absent guard-' <<<"$output")" -eq 4 ]
    [[ "$output" == *"absent guard-bash.sh $HOME/.claude/settings.json"* ]]
    [[ "$output" == *"absent guard-edit.sh $WORK/factory/settings.json"* ]]
    "$QG" hooks install --claude --user > /dev/null
    run "$QG" hooks status --user --config-dir "$WORK/factory"
    [ "$(grep -c '^installed guard-' <<<"$output")" -eq 2 ]
    [[ "$output" == *"installed guard-edit.sh $HOME/.claude/settings.json"* ]]
    [[ "$output" == *"absent guard-edit.sh $WORK/factory/settings.json"* ]]
    mkdir -p "$HOME/.claude-factory"
    run "$QG" hooks status --user
    [[ "$output" == *"absent guard-bash.sh $HOME/.claude-factory/settings.json"* ]]
}

@test "hooks status --user is allowed for an agent" {
    user_setup
    CLAUDECODE=1 run "$QG" hooks status --user
    [ "$status" -eq 0 ]
    [ "$(grep -c '^absent guard-' <<<"$output")" -eq 2 ]
    AI_AGENT=1 run "$QG" hooks install --claude --user
    [ "$status" -eq 2 ]
    [ ! -e "$HOME/.claude/settings.json" ]
    BAD=''
    bash_case allow 'qg hooks status --user'
    bash_case allow "/code/bin/qg hooks status --user --config-dir $WORK/factory"
    bash_case deny  'qg hooks install --claude --user'
    no_bad
}

@test "hooks install --claude --user writes no target and no tool-path file when one target is invalid" {
    user_setup
    printf '%s\n' "$FOREIGN" > "$HOME/.claude/settings.json"
    cp "$HOME/.claude/settings.json" "$WORK/before"
    mkdir -p "$WORK/factory"
    printf '[1, 2\n' > "$WORK/factory/settings.json"
    run "$QG" hooks install --claude --user --config-dir "$WORK/factory"
    [ "$status" -eq 2 ]
    cmp "$WORK/before" "$HOME/.claude/settings.json"
    [ ! -e "$WORK/plugin/.git/qg-tool-path" ]
}

@test "hooks install --claude --user skips a tool folder the engine would drop" {
    user_setup
    mkdir -p "$WORK/repo/tools" "$WORK/good"
    printf '#!/bin/sh\n' > "$WORK/repo/tools/pnpm"; cp "$WORK/repo/tools/pnpm" "$WORK/good/pnpm"; cp "$WORK/repo/tools/pnpm" "$WORK/good/node"
    chmod +x "$WORK/repo/tools/pnpm" "$WORK/good/pnpm" "$WORK/good/node"
    PATH="$WORK/repo/tools:/usr/bin:$WORK/good:$PATH" run "$QG" hooks install --claude --user
    [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
    [ "$(cat "$WORK/plugin/.git/qg-tool-path")" = "$WORK/good" ]
}

@test "a preset QG_CLEAN_ENV never lets an exported QG_CALLER_PATH name the tool folders" {
    user_setup
    mkdir -p "$WORK/real" "$WORK/forged"
    printf '#!/bin/sh\n' > "$WORK/real/pnpm"; cp "$WORK/real/pnpm" "$WORK/forged/pnpm"
    chmod +x "$WORK/real/pnpm" "$WORK/forged/pnpm"
    QG_CLEAN_ENV=1 QG_CALLER_PATH="$WORK/forged" PATH="$WORK/real:$PATH" run "$QG" hooks install --claude --user
    [ "$status" -eq 2 ]
    [ ! -e "$WORK/plugin/.git/qg-tool-path" ]
    run env -i HOME="$HOME" PATH=/usr/local/bin:/usr/bin:/bin QG_CLEAN_ENV=1 "$QG" hooks install --claude --user
    [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
    [ ! -s "$WORK/plugin/.git/qg-tool-path" ]
}

@test "bare qg hooks is allowed for an agent" {
    CLAUDECODE=1 run /code/bin/qg hooks
    [ "$status" -eq 0 ]
    [[ "$output" == *'pre-commit'* ]]
    BAD=''
    bash_case allow 'qg hooks'
    no_bad
}

# --- push reroutes, the hotfix grant, unhooked checkouts and GitHub API writes ------------------

# bash_err <command> -> guard-bash's stderr for the command, run in $PWD.
bash_err() {
    jq -nc --arg c "$1" --arg d "$PWD" '{tool_name:"Bash",cwd:$d,tool_input:{command:$c}}' | "$HOOKS/guard-bash.sh" 2>&1 >/dev/null
}

@test "every push reroute is denied, toward a hotfix branch and toward master alike" {
    local c t
    for t in refs/heads/hotfix/x refs/heads/master; do
        for c in "git -c remote.origin.push=HEAD:$t push" "git -c branch.feature.merge=$t push" \
                 "git --config-env=remote.origin.push=SPEC push" "git --config-env remote.origin.push=SPEC push" \
                 "git config remote.origin.push HEAD:$t" "git config set branch.feature.merge $t" \
                 "git config --local branch.feature.merge $t" "git -c remote.origin.mirror=true push" \
                 "GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=remote.origin.push GIT_CONFIG_VALUE_0=HEAD:$t git push" \
                 "env GIT_CONFIG_PARAMETERS=\"'remote.origin.push'='HEAD:$t'\" git push" \
                 "export GIT_CONFIG_KEY_0=remote.origin.push" "export GIT_CONFIG_VALUE_0=HEAD:$t"; do
            bash_case deny "$c"
        done
    done
    for c in 'git push --all' 'git push origin --all' 'git push --branches origin' "git push origin 'refs/heads/*:refs/heads/*'" \
             "git push origin 'hot*'" 'git push origin :' 'git push origin HEAD:refs/tags/v1' 'git push origin HEAD:refs/for/master' \
             'git push origin refs/tags/v1' 'git -c push.default=upstream push' 'git config push.default upstream' \
             'GIT_CONFIG_GLOBAL=/tmp/g git push' 'GIT_CONFIG_SYSTEM=/tmp/s git push' 'export GIT_CONFIG_NOSYSTEM=1' \
             'git -c core.hooksPath=/dev/null push origin feature'; do
        bash_case deny "$c"
    done
    for c in 'git push origin feature' 'git push -u origin HEAD:refs/heads/feature/x' 'git push origin HEAD:feature/x' \
             'git config --get remote.origin.push' 'git config get push.default' 'git config user.name x' \
             'git push --follow-tags origin feature'; do
        bash_case allow "$c"
    done
    no_bad
    [[ "$(bash_err 'git push --all')" == *'Push one branch by name'* ]]
    [[ "$(bash_err 'git push --all')" != *'commit gate'* ]]
}

@test "a literal hotfix/* target is denied without a hotfix grant, naming qg grant --agent hotfix" {
    local want='guard-bash: denied: git push to hotfix/x skips the push rows, and no operator grant names hotfix. Ask the operator to run `qg grant --agent hotfix` in a separate terminal, or push it as a feature branch and let the push gate measure it.'
    local c
    for c in 'git push origin hotfix/x' 'git push origin HEAD:hotfix/x' 'git push -u origin HEAD:refs/heads/hotfix/x' \
             'git push origin feature:refs/heads/hotfix/x'; do
        [ "$(bash_err "$c")" = "$want" ] || { echo "$c: $(bash_err "$c")"; return 1; }
    done
    git checkout -q -b hotfix/x
    [ "$(bash_err 'git push origin HEAD')" = "$want" ]
    [ "$(bash_err 'git push')" = "$want" ]
    git checkout -q -
    bash_case allow 'git push origin hotfix-x'
    bash_case allow 'git push origin HEAD:refs/heads/feature/hotfix/x'
    no_bad
}

@test "a grant file naming hotfix, alone or with push, lets the literal hotfix push through; push alone does not" {
    user_setup
    HOOKS="$WORK/plugin/templates/claude-hooks"
    cd "$WORK/repo" || return 1
    local now; now="$(date +%s)"
    grant_file() { printf 'v1\t%s\t%s\t%s\tt\n' "$now" "$((now + ${2:-1800}))" "$1" > "$WORK/plugin/.git/qg-grant"; chmod 600 "$WORK/plugin/.git/qg-grant"; }
    bash_case deny 'git push origin HEAD:hotfix/x'
    grant_file push
    bash_case deny 'git push origin HEAD:hotfix/x'
    grant_file hotfix
    bash_case allow 'git push origin HEAD:hotfix/x'
    grant_file push,hotfix
    bash_case allow 'git push origin HEAD:hotfix/x'
    bash_case deny 'git push --all'
    grant_file hotfix -60
    bash_case deny 'git push origin HEAD:hotfix/x'
    no_bad
}

@test "a push from a checkout with quality/checks.tsv at HEAD and no vault-guard pre-push is denied, in any repo" {
    [ -w /var/tmp ] || skip '/var/tmp is not writable in this image'
    local real; real="$(mktemp -d -p /var/tmp)"
    for r in gated unhooked plain; do
        git init -q "$real/$r" && git -C "$real/$r" -c user.email=t@e -c user.name=t commit -q --allow-empty -m init
    done
    for r in gated unhooked; do
        mkdir -p "$real/$r/quality" && printf 'x\n' > "$real/$r/quality/checks.tsv"
        git -C "$real/$r" add quality && git -C "$real/$r" -c user.email=t@e -c user.name=t commit -q -m gate
    done
    printf '#!/bin/sh\n# vault-guard-start\n' > "$real/gated/.git/hooks/pre-push"
    cd "$real/unhooked" || return 1
    bash_case deny 'git push origin feature'
    [[ "$(bash_err 'git push origin feature')" == *'no vault-guard pre-push hook'*'Ask the operator to run `qg hooks install` in that checkout.' ]]
    cd "$real/plain" || return 1
    bash_case allow 'git push origin feature'
    bash_case deny "git -C $real/unhooked push origin feature"
    cd "$real/gated" || return 1
    bash_case allow 'git push origin feature'
    cd "$real/unhooked" || return 1
    mark_gated .
    bash_case deny 'git push origin feature'
    git config core.hooksPath "$real/elsewhere"
    mkdir -p "$real/elsewhere" && printf '#!/bin/sh\n' > "$real/elsewhere/pre-push"
    bash_case deny 'git push origin feature'
    printf '#!/bin/sh\n# vault-guard-start\n' > "$real/elsewhere/pre-push"
    bash_case allow 'git push origin feature'
    rm -rf "$real"
    no_bad
}

@test "a write that resolves into a git dir or a gate file after cd is denied" {
    local c
    for c in 'cd .git && printf ok > guard-pass/x' 'cd .git/refs && echo x > heads/feat' 'cd .git; touch qg-grant' \
             'cd quality && printf x > config' 'cd quality && cp /tmp/x checks.tsv' 'cd app/.. && printf x > .git/HEAD'; do
        bash_case deny "$c"
    done
    mkdir -p app
    bash_case allow 'cd app && printf x > notes.txt'
    bash_case allow 'cd .git && cat HEAD'
    no_bad
}

@test "gh api writes to refs, commits, contents, merges and pull merges are denied in any repo; reads are allowed" {
    local c
    for c in 'gh api -X PUT repos/o/r/pulls/5/merge' 'gh api repos/o/r/git/refs -f ref=refs/heads/x -f sha=abc' \
             'gh api --method PATCH repos/o/r/git/refs/heads/master -f sha=x -F force=true' 'gh api -XDELETE repos/o/r/git/refs/heads/x' \
             'gh api repos/o/r/contents/a.txt -X PUT --input body.json' 'gh api repos/o/r/merges -F base=master -F head=x' \
             'gh api /repos/{owner}/{repo}/git/commits --raw-field message=x' 'gh api --method=POST repos/o/r/git/refs --input b.json' \
             'cd /tmp && gh api -X PUT repos/o/r/pulls/7/merge'; do
        bash_case deny "$c"
    done
    for c in 'gh api repos/o/r/git/refs/heads/master' 'gh api repos/o/r/contents/README.md' 'gh api -X GET repos/o/r/pulls/5/merge' \
             'gh api repos/o/r/pulls -f title=x -f head=feature -f base=master' 'gh api -X GET search/code -f q=x' \
             'gh api repos/o/r/pulls/5/comments -f body=x' 'gh pr view 5' 'gh api --jq .sha repos/o/r/commits/master'; do
        bash_case allow "$c"
    done
    no_bad
}
