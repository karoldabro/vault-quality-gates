#!/usr/bin/env bats
# templates/claude-hooks/* — the agent guards for the surfaces qg adds: the qg command, the
# override token, quality/drivers/ and quality/config, the git directory, and the Stop hook's
# test for a gated repo. 2 denies, 0 allows.

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
    mkdir -p "$real/plain"; cd "$real/plain" || return 1
    bash_case deny "printf 'a b' > $real/other/.git/info/grafts"
    bash_case deny "printf x > $real/other/.git/refs/heads/feat-x"
    bash_case deny "cd $real/other && printf 'a b' > .git/info/grafts"
    bash_case allow "printf x > $real/other/notes.txt"
    rm -rf "$real"
    no_bad
}

@test "git hash-object -w -t commit and git mktree are denied; a read-only hash-object is not" {
    bash_case deny 'git hash-object -t commit -w --stdin < /tmp/c'
    bash_case deny 'git hash-object -w -tcommit --stdin < /tmp/c'
    bash_case deny 'git mktree < /tmp/t'
    bash_case allow 'git hash-object README.md'
    bash_case allow 'git hash-object -w --stdin < /tmp/blob'
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

@test "the Stop hook treats a repo with committed quality/checks.tsv and rules.tsv as gated" {
    printf 'x\n' > quality/checks.tsv; printf 'x\n' > quality/rules.tsv
    git add -A; git commit -q -m gate
    run bash -c "jq -nc --arg d '$PWD' '{cwd:\$d}' | $HOOKS/guard-stop.sh"
    [ "$status" -eq 2 ]
    [[ "$output" == *'on no remote'* ]]
    [[ "$output" == *'quality/config, quality/drivers/'* ]]
}

@test "the Stop hook leaves a repo without the gate's files alone" {
    printf 'x\n' > quality/checks.tsv
    git add -A; git commit -q -m only-checks
    run bash -c "jq -nc --arg d '$PWD' '{cwd:\$d}' | $HOOKS/guard-stop.sh"
    [ "$status" -eq 0 ]
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

@test "hooks install --claude --user twice leaves three guard entries and keeps other entries" {
    user_setup
    printf '%s\n' "$FOREIGN" > "$HOME/.claude/settings.json"
    local before; before="$(foreign "$HOME/.claude/settings.json")"
    run "$QG" hooks install --claude --user
    [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
    local first; first="$(jq -S . "$HOME/.claude/settings.json")"
    run "$QG" hooks install --claude --user
    [ "$status" -eq 0 ]
    [ "$(jq -S . "$HOME/.claude/settings.json")" = "$first" ]
    [ "$(guard_entries "$HOME/.claude/settings.json" | wc -l)" -eq 3 ]
    [ "$(foreign "$HOME/.claude/settings.json")" = "$before" ]
}

@test "hooks install --claude --user writes the same entries into each --config-dir" {
    user_setup
    run "$QG" hooks install --claude --user --config-dir "$WORK/factory" --config-dir "$WORK/other/"
    [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
    local want; want="$(guard_entries "$HOME/.claude/settings.json")"
    [ "$(printf '%s\n' "$want" | wc -l)" -eq 3 ]
    [ "$(guard_entries "$WORK/factory/settings.json")" = "$want" ]
    [ "$(guard_entries "$WORK/other/settings.json")" = "$want" ]
}

@test "hooks install --claude --user writes commands under the main worktree" {
    user_setup
    ln -s "$WORK/plugin" "$WORK/plugin-link"
    run "$WORK/plugin-link/bin/qg" hooks install --claude --user
    [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
    [ "$(guard_entries "$HOME/.claude/settings.json")" = "$(printf '%s/templates/claude-hooks/%s\n' "$PLUGIN_REAL" guard-bash.sh "$PLUGIN_REAL" guard-edit.sh "$PLUGIN_REAL" guard-stop.sh)" ]
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

@test "hooks remove --claude --user removes exactly the three guard entries" {
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

@test "hooks install --claude --user replaces an older guard entry naming another folder" {
    user_setup
    printf '%s\n' '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"/old/vault-quality-gates/templates/claude-hooks/guard-bash.sh"}]},{"matcher":"Read","hooks":[{"type":"command","command":"/other.sh"}]}],"Stop":[{"hooks":[{"type":"command","command":"/old/vault-quality-gates/templates/claude-hooks/guard-stop.sh","timeout":30}]}]}}' \
        > "$HOME/.claude/settings.json"
    run "$QG" hooks install --claude --user
    [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
    [ "$(guard_entries "$HOME/.claude/settings.json" | wc -l)" -eq 3 ]
    run grep -c '/old/' "$HOME/.claude/settings.json"
    [ "$output" = 0 ]
    jq -e '.hooks.PreToolUse[] | select(.matcher == "Read")' "$HOME/.claude/settings.json" > /dev/null
}

@test "hooks remove --claude removes the three repo-level entries and keeps every other entry and the git hooks" {
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
    [ "$(grep -c '^absent guard-' <<<"$output")" -eq 6 ]
    [[ "$output" == *"absent guard-bash.sh $HOME/.claude/settings.json"* ]]
    [[ "$output" == *"absent guard-stop.sh $WORK/factory/settings.json"* ]]
    "$QG" hooks install --claude --user > /dev/null
    run "$QG" hooks status --user --config-dir "$WORK/factory"
    [ "$(grep -c '^installed guard-' <<<"$output")" -eq 3 ]
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
    [ "$(grep -c '^absent guard-' <<<"$output")" -eq 3 ]
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
