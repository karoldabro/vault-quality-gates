#!/usr/bin/env bats
# lib/qg-driver-kit.sh — the helpers every built-in driver shares: changed-file selection, the
# tool runner, the added-lines filter, the per-run shared report and result.json.

load guard-helpers

KIT=/code/lib/qg-driver-kit.sh

setup() {
    export LC_ALL=C
    WORK="$(mktemp -d)"
    unset QG_RUNNER QG_ARGS QG_RUN_DIR CLAUDECODE AI_AGENT
    export GUARD_LOCK_WAIT=5
    TREE="$WORK/tree"; mkdir -p "$TREE" "$WORK/out"
    export QG_TREE="$TREE" QG_OUT="$WORK/out" QG_CACHE="$WORK/cache" QG_ROW=row QG_FILES=/dev/null
}

teardown() {
    [ -n "${WORK:-}" ] && [ -d "$WORK" ] && rm -rf "$WORK"
    return 0
}

kit() { bash -c ". $KIT; $1"; }

@test "qg_tool deletes the report first, so a tool that writes none is an error, never the old report" {
    printf 'old report\n' > "$TREE/report.json"
    printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$TREE/tool"; chmod +x "$TREE/tool"
    run kit 'qg_tool report.json "0" ./tool || { echo "ERR: $QG_ERROR"; exit 3; }'
    [ "$status" -eq 3 ]
    [[ "$output" == *'wrote no report report.json'* ]]
    [ ! -e "$TREE/report.json" ]
}

@test "qg_tool refuses an exit code outside the ok set and an argv path under QG_OUT" {
    printf '%s\n' '#!/usr/bin/env bash' 'echo "boom" >&2; exit 3' > "$TREE/tool"; chmod +x "$TREE/tool"
    run kit 'qg_tool - "0 1 2" ./tool || { echo "ERR: $QG_ERROR"; exit 3; }'
    [ "$status" -eq 3 ] && [[ "$output" == *'boom'* ]] && [[ "$output" == *'tool exited 3'* ]]
    run kit "qg_tool - 0 ./tool --report=$WORK/out/r.json || { echo \"ERR: \$QG_ERROR\"; exit 3; }"
    [ "$status" -eq 3 ] && [[ "$output" == *'outside the measured tree'* ]]
}

@test "qg_tool calls a runner as <runner> <tree> <cache> <sandbox prefix> <argv>" {
    printf '%s\n' '#!/usr/bin/env bash' 'printf "%s|" "$@"; shift 2; exec "$@"' > "$WORK/runner"; chmod +x "$WORK/runner"
    QG_RUNNER="$WORK/runner" run kit 'qg_tool - 0 true a "b c"'
    [ "$status" -eq 0 ]
    [[ "$(cat "$QG_OUT/stdout")" == "${TREE}|${WORK}/cache|/usr/bin/env|-i|"*"|/code/bin/qg-sandbox|"*"|--|true|a|b c|" ]]
}

# runner_tool — a runner that writes the tree before it runs its argv, and a tool in the tree that
# writes the tree and a file outside it, then prints its count.
runner_tool() {
    { printf '#!/usr/bin/env bash\n'
      printf 'tree="$1"; shift 2\necho prepared > "$tree/prepared" && echo "runner wrote the tree"\nmkdir -p "$tree/coverage"\n'
      printf 'cd "$tree" && exec "$@"\n'
    } > "$WORK/runner"
    { printf '#!/usr/bin/env bash\n'
      printf 'echo x > tool-wrote.txt 2>/dev/null || echo "tool tree write refused"\n'
      printf 'echo x > %q 2>/dev/null || echo "tool outside write refused"\n' "$WORK/escaped"
      printf 'echo 7\n'
    } > "$TREE/tool"
    chmod +x "$WORK/runner" "$TREE/tool"
}

@test "qg_tool runs a sandboxed driver's runner outside the sandbox and the tool it starts inside" {
    runner_tool
    QG_RUNNER="$WORK/runner" run kit 'qg_tool - 0 ./tool || { echo "ERR: $QG_ERROR"; exit 3; }; echo "armed=$QG_SANDBOX_ARMED"'
    [ "$status" -eq 0 ]
    [ -e "$TREE/prepared" ]
    [ ! -e "$TREE/tool-wrote.txt" ] && [ ! -e "$WORK/escaped" ]
    [ "$(cat "$QG_OUT/stdout")" = $'runner wrote the tree\ntool tree write refused\ntool outside write refused\n7' ]
    [[ "$output" == *'armed=1'* ]]
    # The control: unsandboxed, the same tool writes both files, so the sandbox is what stopped it.
    QG_SANDBOX=0 QG_RUNNER="$WORK/runner" run kit 'qg_tool - 0 ./tool'
    [ "$status" -eq 0 ] && [ -e "$TREE/tool-wrote.txt" ] && [ -e "$WORK/escaped" ]
}

@test "a runner that writes the tree and then runs the tool still measures, and the tool cannot write outside its grants" {
    runner_tool
    QG_RUNNER="$WORK/runner" QG_SANDBOX_WRITES=coverage run kit 'qg_tool - 0 sh -c "./tool; echo c > coverage/c" \
        && qg_result probe measured "$(tail -1 "$QG_OUT/stdout")" count - - || qg_fail probe count "$QG_ERROR"'
    [ "$(jq -r .status "$QG_OUT/result.json")" = measured ]
    [ "$(jq -r .metric "$QG_OUT/result.json")" = 7 ]
    [ -e "$TREE/prepared" ] && [ -s "$TREE/coverage/c" ]
    [ ! -e "$TREE/tool-wrote.txt" ] && [ ! -e "$WORK/escaped" ]
}

@test "a runner whose sandbox never arms is status error and its tool never runs" {
    runner_tool
    printf '#!/bin/sh\nexec %q --max-abi 5 "$@"\n' /code/bin/qg-sandbox > "$WORK/weak"; chmod +x "$WORK/weak"
    QG_RUNNER="$WORK/runner" run kit "QG_SANDBOX_BIN=$WORK/weak; qg_tool - 0 sh -c 'echo ran > $WORK/sentinel' || { echo \"ERR: \$QG_ERROR\"; exit 3; }"
    [ "$status" -eq 3 ]
    [[ "$output" == *'ERR: qg-sandbox: the sandbox did not arm'* ]]
    [ ! -e "$WORK/sentinel" ]
}

@test "qg_tool refuses a shell function as the program" {
    run kit 'tool() { echo ran > "$QG_TREE/ran"; }; qg_tool - 0 tool || { echo "ERR: $QG_ERROR"; exit 3; }'
    [ "$status" -eq 3 ]
    [[ "$output" == *'ERR: qg_tool: tool is a shell function'* ]]
    [ ! -e "$TREE/ran" ]
}

@test "qg_tool adds its report folder to the declared writes and nothing else in the tree" {
    printf '%s\n' '#!/usr/bin/env bash' 'echo r > reports/r.json; echo x > other.txt' > "$TREE/tool"; chmod +x "$TREE/tool"
    run kit 'qg_tool reports/r.json "0 1" ./tool || { echo "ERR: $QG_ERROR"; exit 3; }'
    [ "$status" -eq 0 ]
    [ -s "$TREE/reports/r.json" ]
    [ ! -e "$TREE/other.txt" ]
}

@test "qg_files keeps changed files matching the ERE, include= and not exclude=, present in the tree" {
    mkdir -p "$TREE/app" "$TREE/tests/Fixtures"
    : > "$TREE/app/a b.php"; : > "$TREE/app/-x.php"; : > "$TREE/app/ü.php"; : > "$TREE/tests/Fixtures/f.php"; : > "$TREE/app/c.js"
    printf 'app/a b.php\0app/-x.php\0app/ü.php\0tests/Fixtures/f.php\0app/c.js\0app/gone.php\0' > "$WORK/files"
    QG_FILES="$WORK/files" QG_ARGS='exclude=^tests/Fixtures/' run kit 'qg_files "\.php$"; printf "<%s>" "${QG_FILE_LIST[@]}"'
    [ "$output" = '<app/a b.php><app/-x.php><app/ü.php>' ]
    QG_FILES="$WORK/files" QG_ARGS='include=^tests/' run kit 'qg_files "\.php$"; printf "<%s>" "${QG_FILE_LIST[@]}"'
    [ "$output" = '<tests/Fixtures/f.php>' ]
    QG_FILES=/dev/null run kit 'qg_files "\.php$"; echo "n=${#QG_FILE_LIST[@]}"'
    [ "$output" = 'n=0' ]
}

@test "qg_added_only counts findings on added lines in any path form, prints line-less ones uncounted" {
    gate_repo "$WORK/repo"
    printf 'one\ntwo\nthree\n' > app/a.php; git add app/a.php
    export QG_REPO="$WORK/repo" QG_TREE="$WORK/repo" QG_TARGET=:index QG_BASES="$(git rev-parse HEAD)"
    printf 'app/a.php\0' > "$WORK/files"; export QG_FILES="$WORK/files"
    jq -n --arg t "$WORK/repo" '[{file: "app/a.php", line: 1}, {file: "/app/app/a.php", line: 2}, {file: "./app/a.php", line: 3},
        {file: ($t + "/app/a.php"), line: 2}, {file: "app/a.php", line: null}, {file: "app/other.php", line: 1}]' > "$WORK/f.json"
    run kit "qg_added_only $WORK/f.json && echo count=\$QG_COUNT"
    [ "$status" -eq 0 ] && [ "$output" = 'count=4' ]
    [ "$(jq length "$WORK/f.json")" -eq 5 ]
    [ "$(jq -r '.[0].file' "$WORK/f.json")" = app/a.php ]
}

@test "qg_added_only refuses a finding path outside the tree, and a finding on an unchanged line adds 0" {
    gate_repo "$WORK/repo"
    printf 'clean\nadded\n' > app/a.php; git add app/a.php
    export QG_REPO="$WORK/repo" QG_TREE="$WORK/repo" QG_TARGET=:index QG_BASES="$(git rev-parse HEAD)"
    printf 'app/a.php\0' > "$WORK/files"; export QG_FILES="$WORK/files"
    printf '[{"file":"app/a.php","line":1},{"file":"app/a.php","line":2}]' > "$WORK/f.json"
    run kit "qg_added_only $WORK/f.json && echo count=\$QG_COUNT"
    [ "$output" = 'count=1' ]
    printf '[{"file":"/elsewhere/a.php","line":1}]' > "$WORK/f.json"
    run kit "qg_added_only $WORK/f.json || { echo \"ERR: \$QG_ERROR\"; exit 3; }"
    [ "$status" -eq 3 ] && [[ "$output" == *'/elsewhere/a.php is not inside the measured tree'* ]]
}

@test "qg_shared_report runs the tool once per target and args, and a new target runs it again" {
    export QG_RUN_DIR="$WORK/run"; mkdir -p "$QG_RUN_DIR"
    prog='produce() { echo x >> "$CALLS"; echo "report for $QG_TARGET" > "$QG_OUT/rep"; }; qg_shared_report rep produce; cat "$QG_OUT/rep"'
    CALLS="$WORK/calls" QG_TARGET=aaa QG_ARGS='metric=code paths=app' run kit "$prog"
    [ "$output" = 'report for aaa' ]
    CALLS="$WORK/calls" QG_TARGET=aaa QG_ARGS='metric=style paths=app' run kit "$prog"
    [ "$output" = 'report for aaa' ] && [ "$(wc -l < "$WORK/calls")" -eq 1 ]
    CALLS="$WORK/calls" QG_TARGET=bbb QG_ARGS='metric=code paths=app' run kit "$prog"
    [ "$output" = 'report for bbb' ] && [ "$(wc -l < "$WORK/calls")" -eq 2 ]
    CALLS="$WORK/calls" QG_TARGET=bbb QG_ARGS='metric=code paths=src' run kit "$prog"
    [ "$(wc -l < "$WORK/calls")" -eq 3 ]
    # A half-written temporary file is never read as the report.
    [ -z "$(find "$QG_RUN_DIR" -name '*.[0-9]*')" ]
}

@test "qg_shared_report without QG_RUN_DIR always runs the tool, and a failed producer is not kept" {
    prog='produce() { echo x >> "$CALLS"; echo r > "$QG_OUT/rep"; return "${FAIL:-0}"; }; qg_shared_report rep produce'
    CALLS="$WORK/calls" run kit "$prog"; CALLS="$WORK/calls" run kit "$prog"
    [ "$(wc -l < "$WORK/calls")" -eq 2 ]
    export QG_RUN_DIR="$WORK/run"; mkdir -p "$QG_RUN_DIR"
    FAIL=1 CALLS="$WORK/calls" run kit "$prog"
    [ "$status" -eq 1 ] && [ -z "$(ls "$QG_RUN_DIR")" ]
}

@test "every guard.sh invocation gets its own QG_RUN_DIR, removed at exit, whatever the caller exported" {
    gate_repo "$WORK/repo"
    mkdir -p quality/drivers
    printf '%s\n' '#!/usr/bin/env bash' 'case "$1" in describe) echo "{\"name\":\"rd\",\"requires\":[],\"needs_tree\":false}";;' \
        '  run) echo "run-dir $QG_RUN_DIR"; echo "{\"schema\":\"qg.result/1\",\"status\":\"measured\",\"metric\":0,\"findings\":[],\"error\":null}" > "$QG_OUT/result.json";;' \
        '  *) exit 2;; esac' > quality/drivers/rd.sh
    chmod +x quality/drivers/rd.sh
    { printf 'id\ton\tkind\tdriver\targs\tdirection\tthreshold\tgate\twhy\n'
      printf 'r\tpush\tdiff\trd\t-\tdown\t0\trefuse\ta row that logs its run dir\n'; } > quality/checks.tsv
    commit_all rd
    # The repo driver runs sandboxed, so it prints its run dir into the row log the engine keeps.
    local log
    log="$(git rev-parse --path-format=absolute --git-common-dir)/qg-last/r/output.txt"
    RUNLOG="$WORK/runlog"
    QG_RUN_DIR=/tmp/inherited GUARD_SHA="$(git rev-parse HEAD)" run bash /code/bin/guard.sh release refs/heads/x
    sed -n 's/^run-dir //p' "$log" > "$RUNLOG"
    GUARD_SHA="$(git rev-parse HEAD)" run bash /code/bin/guard.sh release refs/heads/x
    sed -n 's/^run-dir //p' "$log" >> "$RUNLOG"
    [ "$(sort -u "$RUNLOG" | wc -l)" -eq 2 ]
    ! grep -q '^/tmp/inherited$' "$RUNLOG"
    while read -r d; do [ ! -e "$d" ]; done < "$RUNLOG"
}

@test "the push worktree is removed even when a row leaves a folder git cannot delete" {
    gate_repo "$WORK/repo"
    # A shell row in the detached worktree prints its folder and leaves a read-only folder with a file.
    { printf 'id\ton\tkind\tdriver\targs\tdirection\tthreshold\tgate\twhy\n'
      printf 'ro\tpush\tdiff\tshell\t-- echo "tree $PWD" >&2; mkdir -p ro && : > ro/f && chmod 555 ro; echo 0\tdown\t0\trefuse\ta row that leaves a read-only folder\n'
    } > quality/checks.tsv
    commit_all ro
    GUARD_SHA="$(git rev-parse HEAD)" run bash /code/bin/guard.sh release refs/heads/x
    local log tree
    log="$(git rev-parse --path-format=absolute --git-common-dir)/qg-last/ro/output.txt"
    tree="$(sed -n 's/^tree //p' "$log")"
    [ -n "$tree" ] && [ "$tree" != "$WORK/repo" ]
    [ ! -e "$tree" ] || { chmod -R u+w "$tree"; echo "worktree $tree was left behind"; return 1; }
    [ "$(git worktree list | wc -l)" -eq 1 ]
}

@test "qg_result writes 5000 findings, more than one exec's argument limit holds" {
    jq -n '[range(5000) | {ruleId: "r", file: ("/app/app/F\(.).php"), line: 1, level: "error", message: ("a long message number \(.) " * 10), doc: null}]' > "$WORK/f.json"
    run kit "qg_result d measured 5000 findings $WORK/f.json -"
    [ "$status" -eq 0 ]
    [ "$(jq '.findings | length' "$QG_OUT/result.json")" -eq 5000 ]
    [ "$(jq -r '.findings[4999].file' "$QG_OUT/result.json")" = app/F4999.php ]
}

@test "qg_result maps finding paths into the tree and qg_need writes an error naming a missing key" {
    printf '[{"ruleId":"r","file":"/app/app/x.php","line":3,"level":"error","message":"m","doc":null}]' > "$WORK/f.json"
    run kit "qg_result d measured 1 findings $WORK/f.json -"
    [ "$(jq -r '.findings[0].file' "$QG_OUT/result.json")" = app/x.php ]
    [ "$(jq -r '.metric' "$QG_OUT/result.json")" = 1 ]
    QG_ARGS='paths=app' run kit 'v="$(qg_need d findings ruleset)" || exit 3'
    [ "$status" -eq 3 ]
    [ "$(jq -r '.status' "$QG_OUT/result.json")" = error ]
    [[ "$(jq -r '.error' "$QG_OUT/result.json")" == *'ruleset='* ]]
}

@test "qg_kit_config_key reads the key at QG_CONFIG_REV, never the working tree" {
    new_repo "$WORK/cfg"
    mkdir -p quality
    printf 'guard_doc_lint: /committed\n' > quality/config
    commit_all config
    rev="$(git rev-parse HEAD)"
    printf 'guard_doc_lint: /staged\n' > quality/config
    git add quality/config
    printf 'guard_doc_lint: /worktree\n' > quality/config
    QG_REPO="$WORK/cfg" QG_CONFIG_REV="$rev" run kit 'qg_kit_config_key guard_doc_lint'
    [ "$status" -eq 0 ]
    [ "$output" = /committed ]
    QG_REPO="$WORK/cfg" QG_CONFIG_REV="$rev" run kit 'qg_kit_config_key no_such_key'
    [ "$status" -ne 0 ]
}

@test "with a runner a missing declared folder is created when the sandbox arms, and a linked one is skipped" {
    mkdir -p "$WORK/elsewhere/.cache"
    { printf '#!/usr/bin/env bash\ntree="$1"; shift 2\n'
      printf 'ln -s %q "$tree/node_modules"\ncd "$tree" && exec "$@"\n' "$WORK/elsewhere"
    } > "$WORK/runner"
    printf '%s\n' '#!/usr/bin/env bash' 'echo r > reports/r 2>/dev/null || echo "reports refused"' \
        'echo c > node_modules/.cache/c 2>/dev/null || echo "cache refused"' > "$TREE/tool"
    chmod +x "$WORK/runner" "$TREE/tool"
    QG_RUNNER="$WORK/runner" QG_SANDBOX_WRITES='reports node_modules/.cache' run kit 'qg_tool - 0 ./tool || { echo "ERR: $QG_ERROR"; exit 3; }'
    [ "$status" -eq 0 ]
    [ "$(cat "$QG_OUT/stdout")" = 'cache refused' ]
    [ -s "$TREE/reports/r" ] && [ ! -L "$TREE/reports" ]
    [[ "$output" == *'/node_modules/.cache is reached through a symlink; not writable'* ]]
    [ ! -e "$WORK/elsewhere/.cache/c" ]
}
