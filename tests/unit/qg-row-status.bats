#!/usr/bin/env bats
# How the engine reads a driver's result.json. Only `status: measured`, no `error`, and a numeric
# `metric` give a value; every other shape is `unmeasurable` (exit 2), never a value of 0. The
# row's own last output lines are kept in <git-common-dir>/qg-last/<id>/ for the refusal.

load guard-helpers

V2_HEADER=$'id\ton\tkind\tdriver\targs\tdirection\tthreshold\tgate\twhy'

setup() {
    export LC_ALL=C
    WORK="$(mktemp -d)"
    export GUARD_LOCK_WAIT=5
    unset QG_SKIP_REASON CLAUDECODE AI_AGENT
    gate_repo "$WORK/repo"
    mkdir -p quality/drivers
    # The driver prints 30 numbered lines, writes $RESULT verbatim (when set) and exits $RC.
    { printf '#!/usr/bin/env bash\n'
      printf 'case "$1" in describe) printf "%%s\\n" "${DESCRIBE:-{\\"name\\":\\"probe\\",\\"requires\\":[],\\"needs_tree\\":false}}";;\n'
      printf '  run) seq 1 30; [ -n "${RESULT+set}" ] && printf "%%s" "$RESULT" > "$QG_OUT/result.json"; exit "${RC:-0}";;\n'
      printf '  *) exit 2;; esac\n'
    } > quality/drivers/probe.sh
    chmod +x quality/drivers/probe.sh
    { printf '%s\n' "$V2_HEADER"
      printf 'probe-row\tcommit\tdiff\tprobe\t-\tdown\t5\trefuse\tthe probe must stay at or under 5\n'
    } > quality/checks.tsv
    commit_all probe
    printf 'x\n' > app/b.php; git add app/b.php
}

teardown() {
    [ -n "${WORK:-}" ] && [ -d "$WORK" ] && rm -rf "$WORK"
    return 0
}

last() { printf '%s/qg-last/probe-row' "$(git rev-parse --path-format=absolute --git-common-dir)"; }
ok_json() { printf '{"schema":"qg.result/1","status":"measured","metric":%s,"findings":[],"error":null}' "$1"; }

@test "a numeric metric is a value: 0, 1.5 and 1e0 pass the ceiling, 6 is refused" {
    local m
    for m in 0 1.5 1e0 5; do
        RESULT="$(ok_json "$m")" run bash /code/bin/guard.sh commit
        [ "$status" -eq 0 ] || { echo "metric $m: $output"; return 1; }
    done
    RESULT="$(ok_json 6)" run bash /code/bin/guard.sh commit
    [ "$status" -eq 1 ]
}

@test "every malformed result is unmeasurable, never 0" {
    local r bad=''
    for r in '' 'not json' '[]' '{"status":"measured","metric":null,"error":null}' \
             '{"status":"measured","metric":"3","error":null}' '{"status":"measured","metric":true,"error":null}' \
             '{"status":"measured","error":null}' '{"status":"error","metric":0,"error":null}' \
             '{"status":"measured","metric":0,"error":"the tool crashed"}' '{"status":"done","metric":0,"error":null}'; do
        RESULT="$r" run bash /code/bin/guard.sh commit
        [ "$status" -eq 2 ] && [[ "$output" == *'probe-row'*'could not'* ]] || bad+=$'\n'"[$r] -> $status"
    done
    unset RESULT
    run bash /code/bin/guard.sh commit
    [[ "$output" == *'wrote no result.json'* ]] || bad+=$'\n'"absent result: $output"
    RESULT="$(ok_json 0)" RC=3 run bash /code/bin/guard.sh commit
    [[ "$output" == *'exited 3'* ]] || bad+=$'\n'"exit 3: $output"
    [ -z "$bad" ] || { printf '%s\n' "$bad"; return 1; }
}

@test "the error text a driver reports reaches the refusal" {
    RESULT='{"status":"error","metric":null,"error":"vendor/ does not match composer.lock"}' run bash /code/bin/guard.sh commit
    [[ "$output" == *'vendor/ does not match composer.lock'* ]]
}

@test "the last 20 output lines and the result are kept in qg-last/<id>" {
    RESULT='{"status":"error","metric":null,"error":"boom"}' run bash /code/bin/guard.sh commit
    [ "$(wc -l < "$(last)/output.txt")" -eq 20 ]
    [ "$(head -1 "$(last)/output.txt")" = 11 ]
    [ "$(tail -1 "$(last)/output.txt")" = 30 ]
    [ "$(jq -r '.error' "$(last)/result.json")" = boom ]
}

@test "a shell row gets a result.json too: its value, or its reason" {
    { printf '%s\n' "$V2_HEADER"
      printf 'num\tcommit\tdiff\tshell\t-- echo 3\tdown\t5\trefuse\tthe number stays small\n'
      printf 'bad\tcommit\tdiff\tshell\t-- echo oops\tdown\t5\trefuse\tthe number stays small\n'
    } > quality/checks.tsv
    commit_all shell-rows
    printf 'y\n' > app/c.php; git add app/c.php
    run bash /code/bin/guard.sh commit
    d="$(git rev-parse --path-format=absolute --git-common-dir)/qg-last"
    [ "$(jq -r '.metric' "$d/num/result.json")" = 3 ]
    [ "$(jq -r '.status' "$d/bad/result.json")" = error ]
    [[ "$(jq -r '.error' "$d/bad/result.json")" == *'not a number'* ]]
}

@test "a driver whose describe is unreadable is measured on the staged tree, never the working tree" {
    printf 'BAD\n' > app/a.php
    DESCRIBE='not json' RESULT="$(ok_json 0)" run bash /code/bin/guard.sh commit
    [ "$status" -eq 0 ]
    [ -d "$(git rev-parse --path-format=absolute --git-common-dir)/guard-tree/app" ]
}

@test "a v1 row id with a slash or .. writes nothing outside qg-last" {
    write_checks $'../escape\tcommit\tdiff\techo 0\t-\t-\tdown\t0\trefuse'
    commit_all v1
    printf 'z\n' > app/d.php; git add app/d.php
    run bash /code/bin/guard.sh commit
    common="$(git rev-parse --path-format=absolute --git-common-dir)"
    [ ! -e "$common/escape" ]
    [ ! -e "$common/qg-last/../escape" ]
}
