#!/usr/bin/env bats
# The operator's agent grant (lib/qg-grant.sh, `qg grant`): only a human at a terminal issues or
# revokes it; while it is live and names an action, an agent runs that action through qg and the
# installed hooks; expired, revoked, malformed or loosely owned, it is no grant. The plugin is a
# writable copy, because the grant file lives in the plugin checkout's git dir.

load guard-helpers

setup() {
    export LC_ALL=C
    WORK="$(mktemp -d)"
    export GUARD_LOCK_WAIT=5
    unset QG_SKIP_REASON CLAUDECODE AI_AGENT
    PLUGIN="$WORK/plugin"
    mkdir -p "$PLUGIN"
    cp -r /code/bin /code/lib /code/templates /code/drivers /code/extend "$PLUGIN/"
    git -C "$PLUGIN" init -q .
    git -C "$PLUGIN" -c user.email=t@e -c user.name=t add -A
    git -C "$PLUGIN" -c user.email=t@e -c user.name=t commit -q -m plugin
    QG="$PLUGIN/bin/qg"
    GRANT="$PLUGIN/.git/qg-grant"
    gate_repo "$WORK/repo"
    ( export GUARD_LIB_DIR="$PLUGIN/lib"; . "$PLUGIN/lib/guard-metrics.sh"; . "$PLUGIN/lib/guard-install.sh"; guard_hooks_install >/dev/null )
    printf 'BAD\n' > app/a.php
    git add app/a.php
}

teardown() {
    [ -n "${WORK:-}" ] && [ -d "$WORK" ] && rm -rf "$WORK"
    return 0
}

# at_tty <command> — runs it under a pseudo-terminal with the agent markers removed.
at_tty() { script -qec "env -u CLAUDECODE -u AI_AGENT -u QG_SKIP_REASON bash -c $(printf '%q' "$1")" /dev/null; }
# grant <actions> [<issued offset s>] [<life s>] — writes a grant file as `qg grant` would.
grant() {
    local now; now="$(date +%s)"
    printf 'v1\t%s\t%s\t%s\tt\n' "$((now + ${2:-0}))" "$((now + ${2:-0} + ${3:-3600}))" "$1" > "$GRANT"
    chmod 600 "$GRANT"
}
token() { printf '%s/qg-override' "$(git rev-parse --path-format=absolute --git-common-dir)"; }
agent_commit() { CLAUDECODE=1 git commit -q -m agent-commit 2>&1; echo "rc=$?"; }

@test "a human at a terminal issues a grant; an agent, a ! command and a run without a terminal are refused" {
    run at_tty "$QG grant --agent 2h baseline,override"
    [[ "$output" == *'agents may run baseline,override until'* ]]
    [ "$(stat -c %a "$GRANT")" = 600 ]
    run "$QG" grant --status
    [[ "$output" == 'grant: baseline,override until '*'(120 minutes left)' ]]
    rm -f "$GRANT"
    run at_tty "CLAUDECODE=1 $QG grant --agent 1h baseline"
    [[ "$output" == *'refused for an agent'* ]]
    [ ! -e "$GRANT" ]
    run at_tty "export CLAUDECODE=; $QG grant --agent 1h baseline"
    [ ! -e "$GRANT" ]
    run "$QG" grant --agent 1h baseline
    [ "$status" -eq 2 ]
    [[ "$output" == *'needs a human at a terminal'* ]]
    [ ! -e "$GRANT" ]
}

@test "a grant names known actions and lasts at most 8 hours; the default is 1 hour" {
    run at_tty "$QG grant --agent baseline"
    run "$QG" grant --status
    [[ "$output" == *'(60 minutes left)' ]]
    rm -f "$GRANT"
    for bad in '9h baseline' '0m baseline' '2h accept' '2h baseline,init' '2h' '2x baseline' '2h baseline override'; do
        run at_tty "$QG grant --agent $bad"
        [ ! -e "$GRANT" ] || { echo "issued for: $bad"; return 1; }
    done
}

@test "an expired, future, over-long, malformed, unknown-action or loosely owned grant is no grant" {
    run "$QG" grant --status
    [ "$output" = 'no grant' ]
    grant baseline -7200 3600;   run "$QG" grant --status; [ "$output" = 'no grant' ]
    grant baseline 600;          run "$QG" grant --status; [ "$output" = 'no grant' ]
    grant baseline 0 30000;      run "$QG" grant --status; [ "$output" = 'no grant' ]
    grant baseline,accept;       run "$QG" grant --status; [ "$output" = 'no grant' ]
    grant baseline; chmod 620 "$GRANT"; run "$QG" grant --status; [ "$output" = 'no grant' ]
    grant baseline; chmod 602 "$GRANT"; run "$QG" grant --status; [ "$output" = 'no grant' ]
    grant baseline; printf 'extra\n' >> "$GRANT"; sed -i '1s/$/\tx/' "$GRANT"; run "$QG" grant --status; [ "$output" = 'no grant' ]
    grant baseline; mv "$GRANT" "$WORK/real"; ln -s "$WORK/real" "$GRANT"
    run "$QG" grant --status; [ "$output" = 'no grant' ]
}

@test "an agent runs qg baseline only while a grant names baseline, and the use is logged" {
    CLAUDECODE=1 run "$QG" baseline
    [ "$status" -eq 2 ]
    [[ "$output" == *'refused for an agent'*'grants baseline'* ]]
    grant override
    CLAUDECODE=1 run "$QG" baseline
    [ "$status" -eq 2 ]
    grant baseline
    CLAUDECODE=1 run "$QG" baseline
    [[ "$output" != *'refused for an agent'* ]]
    [[ "$output" == *'qg baseline allowed for an agent by the operator grant (baseline)'* ]]
    grep -q 'agent grant (baseline' "$(git rev-parse --git-common-dir)/guard-bypass.log"
}

@test "an agent overrides a refused commit while a grant names override, and not once it is revoked" {
    run agent_commit
    [[ "$output" == *'rc=1'* ]]
    CLAUDECODE=1 run "$QG" override --reason 'v2 gate config'
    [ "$status" -eq 2 ]
    [ ! -e "$(token)" ]
    grant override
    CLAUDECODE=1 run "$QG" override --reason 'v2 gate config'
    [ "$status" -eq 0 ]
    [ -s "$(token)" ]
    run agent_commit
    [[ "$output" == *'rc=0'* && "$output" == *'override honoured and logged: v2 gate config'* ]]
    grep -q 'agent grant (override' "$(git rev-parse --git-common-dir)/guard-bypass.log"
    printf 'BAD again\n' > app/c.php; git add app/c.php
    CLAUDECODE=1 run "$QG" override --reason 'second'
    [ -s "$(token)" ]
    CLAUDECODE=1 run "$QG" grant --revoke
    [ "$status" -eq 2 ]
    [ -e "$GRANT" ]
    run at_tty "$QG grant --revoke"
    [ ! -e "$GRANT" ]
    run agent_commit
    [[ "$output" == *'rc=1'* && "$output" == *'no grant names it'* ]]
}

@test "an expired grant stops the agent's commit from consuming a token it wrote" {
    grant override
    CLAUDECODE=1 run "$QG" override --reason 'in time'
    [ -s "$(token)" ]
    grant override -7200 3600
    run agent_commit
    [[ "$output" == *'rc=1'* ]]
    [ -s "$(token)" ]
}

@test "a push token needs a grant naming push; override alone does not cover it" {
    grant override
    CLAUDECODE=1 run "$QG" override --reason 'unrecorded' --push HEAD
    [ "$status" -eq 2 ]
    [ ! -e "$(token)" ]
    grant push
    CLAUDECODE=1 run "$QG" override --reason 'unrecorded' --push HEAD
    [ "$status" -eq 0 ]
    [ -s "$(token)" ]
    run env CLAUDECODE=1 bash -c ". $PLUGIN/lib/guard-override.sh; qg_override_take push \$(git rev-parse HEAD); echo rc=\$?"
    [[ "$output" == *'rc=0'* ]]
}

@test "a full grant never lets an agent issue a grant, install the user guards, accept, init or migrate" {
    grant baseline,override,push
    local c
    for c in 'grant --agent 1h baseline' 'hooks install --claude --user' 'hooks remove --claude' 'accept x --reason y' \
             'init --profile docs' 'migrate'; do
        CLAUDECODE=1 run "$QG" $c
        [ "$status" -eq 2 ] && [[ "$output" == *'refused for an agent'* ]] || { echo "not refused: qg $c ($status) $output"; return 1; }
    done
    run "$QG" grant --status
    [[ "$output" == 'grant: baseline,override,push until'* ]]
}
