#!/usr/bin/env bats
# Which driver a v2 row runs: a built-in under drivers/, else the repo's own
# quality/drivers/<name>.sh as committed at the config revision — never the working tree, never
# a repo driver named like a built-in. A commit that adds or changes a repo driver is refused
# (gate-config-changed) until a human overrides.

load guard-helpers

V2_HEADER=$'id\ton\tkind\tdriver\targs\tdirection\tthreshold\tgate\twhy'

setup() {
    export LC_ALL=C
    WORK="$(mktemp -d)"
    export GUARD_LOCK_WAIT=5 SENTINEL="$WORK/sentinel"
    unset QG_SKIP_REASON CLAUDECODE AI_AGENT GUARD_CONFIG_REV
    gate_repo "$WORK/repo"
}

teardown() {
    [ -n "${WORK:-}" ] && [ -d "$WORK" ] && rm -rf "$WORK"
    return 0
}

# repo_driver <name> <metric> [<touch sentinel>] — quality/drivers/<name>.sh reporting <metric>
repo_driver() {
    mkdir -p quality/drivers
    { printf '#!/usr/bin/env bash\n'
      printf 'case "$1" in describe) echo "{\\"name\\":\\"%s\\",\\"requires\\":[],\\"needs_tree\\":false}";;\n' "$1"
      printf '  run) %s echo "{\\"schema\\":\\"qg.result/1\\",\\"status\\":\\"measured\\",\\"metric\\":%s,\\"findings\\":[],\\"error\\":null}" > "$QG_OUT/result.json";;\n' "${3:+touch \"\$SENTINEL\";}" "$2"
      printf '  *) exit 2;; esac\n'
    } > "quality/drivers/$1.sh"
    chmod +x "quality/drivers/$1.sh"
}

v2_checks() {  # v2_checks <driver>
    { printf '%s\n' "$V2_HEADER"
      printf 'custom\tcommit\tdiff\t%s\t-\tdown\t0\trefuse\ta custom gate\n' "$1"
    } > quality/checks.tsv
}

@test "a committed repo driver runs; its value is compared" {
    repo_driver mine 1
    v2_checks mine
    commit_all custom
    printf 'x\n' > app/b.php; git add app/b.php
    run bash /code/bin/guard.sh commit
    [ "$status" -eq 1 ]
    [[ "$output" == *'custom'* ]]
}

@test "a working-tree edit to a committed repo driver never runs" {
    repo_driver mine 0
    v2_checks mine
    commit_all custom
    repo_driver mine 0 touch
    printf 'x\n' > app/b.php; git add app/b.php
    run bash /code/bin/guard.sh commit
    [ "$status" -eq 0 ]
    [ ! -e "$SENTINEL" ]
}

@test "a driver that exists only in the working tree never runs, and the row is refused as unknown" {
    write_checks "$BAD_ROW"
    commit_all v1
    v2_checks ghost
    repo_driver ghost 0 touch
    git add quality/checks.tsv
    run bash /code/bin/guard.sh commit
    [ "$status" -eq 1 ]
    [[ "$output" == *'gate-config-invalid'*'no driver "ghost"'* ]]
    [ ! -e "$SENTINEL" ]
}

@test "a repo driver named like a built-in is refused; it never replaces the built-in" {
    repo_driver phpstan 0 touch
    v2_checks phpstan
    run bash -c 'git add -A && git -c core.hooksPath=/dev/null commit -q -m shadow && bash /code/bin/guard.sh verify HEAD~1..HEAD'
    printf 'x\n' > app/b.php; git add app/b.php
    run bash /code/bin/guard.sh commit
    [ "$status" -eq 2 ]
    [[ "$output" == *'has the name of a built-in driver'* ]]
    [ ! -e "$SENTINEL" ]
}

@test "a commit that adds or changes a repo driver or quality/config is refused" {
    repo_driver mine 0
    git add quality/drivers/mine.sh
    run bash /code/bin/guard.sh commit
    [ "$status" -eq 1 ]
    [[ "$output" == *'gate-config-changed'*'quality/drivers/mine.sh'* ]]
    git reset -q
    printf 'guard_commit_paths: app\n' > quality/config
    git add quality/config
    run bash /code/bin/guard.sh commit
    [ "$status" -eq 1 ]
    [[ "$output" == *'gate-config-changed'*'quality/config'* ]]
}

@test "a staged v2 checks.tsv with why = - or a bad on cell is refused before it can judge anything" {
    { printf '%s\n' "$V2_HEADER"; printf 'x\tcommit\tdiff\tshell\t-- echo 0\tdown\t0\trefuse\t-\n'; } > quality/checks.tsv
    git add quality/checks.tsv
    run bash /code/bin/guard.sh commit
    [ "$status" -eq 1 ]
    [[ "$output" == *'gate-config-invalid'*'no why'* ]]
    { printf '%s\n' "$V2_HEADER"; printf 'x\tcommit,\tdiff\tshell\t-- echo 0\tdown\t0\trefuse\tbecause\n'; } > quality/checks.tsv
    git add quality/checks.tsv
    run bash /code/bin/guard.sh commit
    [ "$status" -eq 1 ]
    [[ "$output" == *'gate-config-invalid'*'empty token'* ]]
}

# probe_plugin <describe json> — a copy of the plugin under $WORK/plugin whose built-in driver
# `probe` has that describe and prints the QG_SANDBOX and QG_SANDBOX_WRITES it was started with.
probe_plugin() {
    mkdir -p "$WORK/plugin/drivers"
    cp -R /code/lib /code/bin "$WORK/plugin/"
    { printf '#!/usr/bin/env bash\n'
      printf 'case "$1" in describe) printf "%%s\\n" %q;;\n' "$1"
      printf '  run) echo "sandbox=${QG_SANDBOX-unset} writes=${QG_SANDBOX_WRITES-unset}"\n'
      printf '       echo "{\\"schema\\":\\"qg.result/1\\",\\"status\\":\\"measured\\",\\"metric\\":0,\\"findings\\":[],\\"error\\":null}" > "$QG_OUT/result.json";;\n'
      printf '  *) exit 2;; esac\n'
    } > "$WORK/plugin/drivers/probe.sh"
    chmod +x "$WORK/plugin/drivers/probe.sh"
}

# run_probe — guard_run_driver on one probe row; prints the driver's output.
run_probe() {
    local row tmp
    row="$(printf '%s\t' r commit diff probe - down 0 refuse why - - -)"
    tmp="$(mktemp -d)"
    bash -c '. "$1/lib/qg-driver.sh"; REPO_ROOT="$PWD"; guard_run_driver "$2" HEAD /dev/null "$3" >/dev/null && cat "$3/output"' \
        _ "$WORK/plugin" "$row" "$tmp"
}

@test "guard_run_driver exports QG_SANDBOX and QG_SANDBOX_WRITES from describe" {
    export QG_SANDBOX=0 QG_SANDBOX_WRITES=.git
    probe_plugin '{"name":"probe","needs_tree":false,"sandbox":false,"writes":["coverage","node_modules/.vite"]}'
    [ "$(run_probe)" = 'sandbox=0 writes=coverage node_modules/.vite' ]
    probe_plugin '{"name":"probe","needs_tree":false}'
    [ "$(run_probe)" = 'sandbox=1 writes=' ]
    probe_plugin '{"name":"probe","needs_tree":false,"sandbox":"no","writes":"coverage"}'
    [ "$(run_probe)" = 'sandbox=1 writes=' ]
    probe_plugin 'not json'
    [ "$(run_probe)" = 'sandbox=1 writes=' ]
}

@test "a repo driver's run executes inside the sandbox with QG_OUT writable" {
    mkdir -p quality/drivers
    { printf '#!/usr/bin/env bash\n'
      printf 'case "$1" in describe) echo "{\\"name\\":\\"mine\\",\\"requires\\":[],\\"needs_tree\\":false}";;\n'
      printf '  run) echo x > "$QG_TREE/escaped" || echo "tree write refused"\n'
      printf '       echo "{\\"schema\\":\\"qg.result/1\\",\\"status\\":\\"measured\\",\\"metric\\":0,\\"findings\\":[],\\"error\\":null}" > "$QG_OUT/result.json";;\n'
      printf '  *) exit 2;; esac\n'
    } > quality/drivers/mine.sh
    chmod +x quality/drivers/mine.sh
    v2_checks mine
    commit_all custom
    printf 'x\n' > app/b.php; git add app/b.php
    run bash /code/bin/guard.sh commit
    [ "$status" -eq 0 ]
    [ ! -e escaped ]
    log="$(git rev-parse --path-format=absolute --git-common-dir)/qg-last/custom/output.txt"
    grep -q 'tree write refused' "$log"
    grep -qx 'sandbox: armed' "$log"
}

@test "a repo driver declaring sandbox false still runs sandboxed" {
    mkdir -p quality/drivers
    { printf '#!/usr/bin/env bash\n'
      printf 'case "$1" in describe) echo "{\\"name\\":\\"mine\\",\\"requires\\":[],\\"needs_tree\\":false,\\"sandbox\\":false}";;\n'
      printf '  run) echo x > "$QG_TREE/escaped"\n'
      printf '       echo "{\\"schema\\":\\"qg.result/1\\",\\"status\\":\\"measured\\",\\"metric\\":0,\\"findings\\":[],\\"error\\":null}" > "$QG_OUT/result.json";;\n'
      printf '  *) exit 2;; esac\n'
    } > quality/drivers/mine.sh
    chmod +x quality/drivers/mine.sh
    v2_checks mine
    commit_all custom
    printf 'x\n' > app/b.php; git add app/b.php
    run bash /code/bin/guard.sh commit
    [ "$status" -eq 0 ]
    [ ! -e escaped ]
}

@test "every built-in describe's sandbox and writes match the rules table" {
    local d name want got
    declare -A table=(
        [shell]='false|' [checkstyle]='false|' [phpstan]='false|' [phpmd]='false|' [phpcs]='false|' [pint]='false|'
        [phpinsights]='false|' [composer-dependency-analyser]='false|' [phpunit]='false|' [infection]='false|'
        [jscpd]='false|' [jscpd-added]='false|' [doc-lint]='false|'
        [vitest]='true|coverage quality-reports .nuxt node_modules/.vite node_modules/.cache'
        [stryker]='true|.stryker-tmp reports .nuxt node_modules/.vite node_modules/.cache'
        [nuxt-typecheck]='true|.nuxt node_modules/.cache' [eslint]='true|'
        [flutter-test]='true|.dart_tool build' [mutation-test]='true|lib test .dart_tool build reports'
        [dart-analyze]='true|.dart_tool' [dart-format]='true|.dart_tool' [dart-code-linter]='true|.dart_tool'
        [lakos]='true|.dart_tool' [layerlens]='true|.dart_tool'
    )
    for d in /code/drivers/*.sh; do
        name="$(basename "$d" .sh)"
        want="${table[$name]:-true|}"
        got="$("$d" describe | jq -r '"\(.sandbox)|\(.writes | join(" "))"')"
        [ "$got" = "$want" ] || { echo "$name: $got, want $want"; return 1; }
    done
}
