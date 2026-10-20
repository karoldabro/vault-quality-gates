#!/usr/bin/env bats
# bin/qg — the command a person or an agent types. Every read command exits 0 in a gated repo and
# prints one JSON document under --json; run follows guard.sh's exit codes; the commands that
# change the gate refuse an agent.

load guard-helpers
load qg-doctor-helpers

QG=/code/bin/qg
V2_HEADER=$'id\ton\tkind\tdriver\targs\tdirection\tthreshold\tgate\twhy'

setup() {
    export LC_ALL=C
    WORK="$(mktemp -d)"
    export GUARD_LOCK_WAIT=5
    unset QG_SKIP_REASON CLAUDECODE AI_AGENT GUARD_SKIP GUARD_CONFIG_REV
    new_repo "$WORK/repo"
    write_rules
    mkdir -p app
    { printf '%s\n' "$V2_HEADER"
      printf 'todo-count\tcommit\tdiff\tshell\t-- grep -rc TODO app | awk -F: '"'"'{ s += $2 } END { print s + 0 }'"'"'\tdown\t0\trefuse\tnew TODO markers hide unfinished work\n'
      printf 'rel-tests\tpush:refs/heads/release/*\tdiff\tshell\t-- echo 0\tdown\t0\trefuse\trelease pushes pass the tests\n'
    } > quality/checks.tsv
    printf 'clean\n' > app/a.php
    commit_all init
}

teardown() {
    [ -n "${WORK:-}" ] && [ -d "$WORK" ] && rm -rf "$WORK"
    return 0
}

@test "no argument and help print the overview and exit 0; an unknown command exits 2 with help" {
    run "$QG"
    [ "$status" -eq 0 ] && [[ "$output" == *'qg explain <id>'* ]]
    run "$QG" help run
    [ "$status" -eq 0 ] && [[ "$output" == *'--only'* ]]
    run "$QG" frobnicate
    [ "$status" -eq 2 ] && [[ "$output" == *'unknown command'*'Commands:'* ]]
}

@test "list shows every row with when it runs and why; --on filters; --json is one document" {
    run "$QG" list
    [ "$status" -eq 0 ]
    [[ "$output" == *'todo-count'*'every commit'*'new TODO markers hide unfinished work'* ]]
    [[ "$output" == *'rel-tests'*'pushes to refs/heads/release/*'* ]]
    run "$QG" list --on push --json
    [ "$(jq -r '.rows | map(.id) | join(",")' <<<"$output")" = rel-tests ]
}

@test "run commit passes and fails like the hook would, and --json gives verdict and rows" {
    run "$QG" run commit
    [ "$status" -eq 0 ]
    printf 'TODO later\n' > app/b.php; git add app/b.php
    run "$QG" run commit
    [ "$status" -eq 1 ]
    [[ "$output" == *'todo-count'*'worse'* ]]
    run "$QG" run commit --json
    json="$(sed -n '/^{/,$p' <<<"$output")"
    [ "$(jq -r '.verdict' <<<"$json")" = fail ]
    [ "$(jq -r '.exit' <<<"$json")" = 1 ]
    [ "$(jq -r '.rows[] | select(.id == "todo-count") | .status' <<<"$json")" = worse ]
}

@test "run push --ref picks rows by branch; --only narrows a commit run" {
    run "$QG" run push --ref refs/heads/feature/x
    [ "$status" -eq 0 ] && [[ "$output" == *'no gate row runs on refs/heads/feature/x'* ]]
    run "$QG" run push --ref refs/heads/release/1.0
    [ "$status" -eq 0 ] && [[ "$output" == *'rel-tests'* ]]
    printf 'TODO\n' > app/b.php; git add app/b.php
    run "$QG" run commit --only nothing-here
    [ "$status" -eq 0 ]
    [[ "$output" == *'passed for nothing-here only; the real commit runs every row'* ]]
    run "$QG" run commit --only nothing-here --json
    json="$(sed -n '/^{/,$p' <<<"$output")"
    [ "$(jq -r '.partial' <<<"$json")" = true ]
    [ "$(jq -r '.only[0]' <<<"$json")" = nothing-here ]
}

@test "explain works before any run, and after a run shows the last result and output" {
    run "$QG" explain todo-count
    [ "$status" -eq 0 ]
    [[ "$output" == *'why:        new TODO markers hide unfinished work'* ]]
    [[ "$output" == *'not run in this repo yet'* ]]
    [[ "$output" == *'reproduce:  qg run commit --only todo-count'* ]]
    printf 'TODO\n' > app/b.php; git add app/b.php
    "$QG" run commit 2>/dev/null || true
    run "$QG" explain todo-count
    [[ "$output" == *'Last run here: worse, measured 1'* ]]
    run "$QG" explain todo-count --json
    [ "$(jq -r '.last_result.metric' <<<"$output")" = 1 ]
    run "$QG" explain no-such-row
    [ "$status" -eq 2 ]
}

@test "explain tells an agent it may not override and offers a human the override and accept" {
    run "$QG" explain todo-count
    [[ "$output" == *'qg override --reason'* ]]
    CLAUDECODE=1 run "$QG" explain todo-count
    [[ "$output" == *'Agents may not override'* ]]
    [[ "$output" != *'qg override --reason'* ]]
}

@test "last prints the whole last refusal" {
    printf 'TODO\n' > app/b.php; git add app/b.php
    "$QG" run commit 2>/dev/null || true
    run "$QG" last
    [[ "$output" == *'the staged commit was refused'*'How to pass:'* ]]
}

@test "drivers lists the built-ins; drivers <name> describes one; config get reads quality/config" {
    run "$QG" drivers --json
    [ "$(jq -r '.drivers | map(.name) | sort | join(",")' <<<"$output")" = checkstyle,cloc,composer-dependency-analyser,copydetect,dart-analyze,dart-code-linter,dart-format,dart-lock,depcruise,doc-lint,eslint,fallow,flutter-test,grep-count,infection,jscpd,jscpd-added,knip,lakos,layerlens,mutation-test,nuxt-typecheck,phpcs,phpinsights,phpmd,phpstan,phpunit,pint,shell,stryker,vitest ]
    run "$QG" drivers phpstan
    [[ "$output" == *'phpstan: PHPStan static analysis'* ]]
    printf 'guard_commit_paths: app\n' > quality/config
    commit_all config
    run "$QG" config get guard_commit_paths
    [ "$status" -eq 0 ] && [ "$output" = app ]
    run "$QG" config get no_such_key
    [ "$status" -eq 1 ]
}

@test "doctor reports missing hooks as broken, a push glob matching no branch as a warning, and --json counts them" {
    run "$QG" doctor
    [ "$status" -eq 1 ]
    [[ "$output" == *'pre-commit hook is not installed'* ]]
    [[ "$output" == *'push:refs/heads/release/* matches no local or remote branch'* ]]
    healthy_setup
    git branch release/1.0
    run "$QG" doctor --json
    [ "$(jq -r '.fails' <<<"$output")" = 0 ]
    [ "$(jq -r '[.checks[] | select(.text | test("matches a branch"))] | length' <<<"$output")" = 1 ]
}


@test "doctor fails naming qg hooks install --claude --user when ~/.claude/settings.json lacks the three entries" {
    healthy_setup
    run "$QG" doctor
    [ "$status" -eq 0 ]
    user_settings "$HOME/.claude" guard-stop.sh
    run "$QG" doctor
    [ "$status" -eq 1 ]
    [[ "$output" == *"fail  ${HOME}/.claude/settings.json lacks the Stop entry guard-stop.sh (a human runs qg hooks install --claude --user)"* ]]
    rm "$HOME/.claude/settings.json"
    run "$QG" doctor
    [ "$status" -eq 1 ]
    [[ "$output" == *"fail  ${HOME}/.claude/settings.json is missing or not JSON"*'qg hooks install --claude --user'* ]]
}

@test "doctor fails on ~/.claude-factory settings lacking the entries only when that folder exists" {
    healthy_setup
    run "$QG" doctor
    [ "$status" -eq 0 ]
    [[ "$output" != *'.claude-factory'* ]]
    mkdir -p "$HOME/.claude-factory"
    run "$QG" doctor
    [ "$status" -eq 1 ]
    [[ "$output" == *"fail  ${HOME}/.claude-factory/settings.json is missing or not JSON"* ]]
    user_settings "$HOME/.claude-factory" guard-bash.sh
    run "$QG" doctor
    [ "$status" -eq 1 ]
    [[ "$output" == *"fail  ${HOME}/.claude-factory/settings.json lacks the PreToolUse entry guard-bash.sh"* ]]
    user_settings "$HOME/.claude-factory"
    run "$QG" doctor
    [ "$status" -eq 0 ]
}

@test "doctor fails naming qg hooks install when a git hook copy differs from its template" {
    healthy_setup
    printf '# a local edit\n' >> .git/hooks/pre-push
    run "$QG" doctor
    [ "$status" -eq 1 ]
    [[ "$output" == *'fail  pre-push hook differs from the template (a human runs qg hooks install)'* ]]
}

@test "doctor fails naming qg hooks install --claude --user when the tool-path file is absent" {
    healthy_setup
    rm "$PLUGIN/.git/qg-tool-path"
    run "$QG" doctor
    [ "$status" -eq 1 ]
    [[ "$output" == *"fail  the machine tool-path file ${PLUGIN}/.git/qg-tool-path is absent"*'(a human runs qg hooks install --claude --user)'* ]]
}

@test "doctor fails when core.hooksPath is set" {
    healthy_setup
    git config core.hooksPath "$WORK/elsewhere"
    run "$QG" doctor
    [ "$status" -eq 1 ]
    [[ "$output" == *"fail  core.hooksPath is set to ${WORK}/elsewhere"* ]]
}

@test "doctor warns once per per-repo guard entry and still exits 0" {
    healthy_setup
    mkdir -p .claude
    jq -n --arg p "$PLUGIN/templates/claude-hooks" '{hooks: {PreToolUse: [{matcher: "Bash", hooks: [{type: "command", command: "\($p)/guard-bash.sh"}]},
                                 {matcher: "Edit", hooks: [{type: "command", command: "\($p)/guard-edit.sh"},
                                                           {type: "command", command: "/usr/bin/true"}]}]}}' > .claude/settings.json
    run "$QG" doctor
    [ "$status" -eq 0 ]
    [ "$(grep -c 'warn  .*/.claude/settings.json lists the guard ' <<<"$output")" = 2 ]
    [[ "$output" == *"lists the guard ${PLUGIN}/templates/claude-hooks/guard-bash.sh"*'qg hooks remove --claude'* ]]
    [[ "$output" == *"lists the guard ${PLUGIN}/templates/claude-hooks/guard-edit.sh"* ]]
}

@test "doctor exits 0 on a fully installed setup and --json counts match the text" {
    healthy_setup
    run "$QG" doctor
    [ "$status" -eq 0 ]
    summary="$(grep '^qg doctor: ' <<<"$output")"
    run "$QG" doctor --json
    [ "$status" -eq 0 ]
    [ "$summary" = "$(jq -r '"qg doctor: \(.fails) broken, \(.warnings) warnings, \([.checks[] | select(.level == "ok")] | length) fine"' <<<"$output")" ]
    [ "$(jq -r '.fails' <<<"$output")" = 0 ]
    [ "$(jq -r '[.checks[] | select(.level == "warn")] | length' <<<"$output")" = "$(jq -r '.warnings' <<<"$output")" ]
}

@test "qg doctor fails naming each bad tool-path entry" {
    healthy_setup
    : > "$WORK/afile"
    mkdir -p "$WORK/repo/sub"
    printf '%s\n' "$WORK/tools" relative/bin '' "$WORK/missing" "$WORK/afile" "$WORK/repo/sub" > "$PLUGIN/.git/qg-tool-path"
    run "$QG" doctor
    [ "$status" -eq 1 ]
    local e
    for e in relative/bin "$WORK/missing" "$WORK/afile" "$WORK/repo/sub" 'an empty line'; do
        [[ "$output" == *"fail  the machine tool-path file ${PLUGIN}/.git/qg-tool-path lists ${e} ("*"), which the engine drops from PATH"* ]] \
            || { echo "not named: $e"; return 1; }
    done
    [[ "$output" != *"lists ${WORK}/tools ("* ]]
}

@test "the commands that change the gate refuse an agent; read commands do not" {
    local c
    for c in 'override --reason x' 'hooks install' 'hooks remove' 'baseline' 'accept todo-count --reason x' 'migrate' 'init --profile docs'; do
        # shellcheck disable=SC2086
        CLAUDECODE=1 run "$QG" $c
        [ "$status" -eq 2 ] && [[ "$output" == *'refused for an agent'* ]] || { echo "not refused: qg $c"; return 1; }
    done
    for c in 'list' 'explain todo-count' 'drivers' 'hooks status' 'help'; do
        # shellcheck disable=SC2086
        AI_AGENT=1 run "$QG" $c
        [[ "$output" != *'refused for an agent'* ]] || { echo "refused: qg $c"; return 1; }
    done
}

@test "inherited gate variables change nothing a qg run reports" {
    printf 'TODO\n' > app/b.php; git add app/b.php
    run "$QG" run commit --json
    a="$(sed -n '/^{/,$p' <<<"$output" | jq -c '[.verdict, (.rows | map([.id, .status, .value]))]')"
    GUARD_SKIP=. GUARD_ONLY=nothing GUARD_CONFIG_REV=HEAD QG_X=1 run "$QG" run commit --json
    b="$(sed -n '/^{/,$p' <<<"$output" | jq -c '[.verdict, (.rows | map([.id, .status, .value]))]')"
    [ "$a" = "$b" ]
}
