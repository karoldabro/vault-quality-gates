#!/usr/bin/env bats
# The prepared recycling-api migration under migrations/recycling-api/: the lock check both runners
# share, quality/bin/in-tree.sh and quality/bin/in-server.sh against a stub docker, the v2 rows and
# their protected config files, and apply.sh.

load guard-helpers

M=/code/migrations/recycling-api
V2_HEADER=$'id\ton\tkind\tdriver\targs\tdirection\tthreshold\tgate\twhy'
# The 32 ids of recycling-api's v1 quality/checks.tsv, which every v2 file must still name.
V1_IDS='format-staged phpstan-new phpmd-new phpmd-coupling-new phpcs-new suppressions-added baseline-growth
baseline-growth-coupling gate-config-touched duplication-new request-duplication-new phpstan8-new baseline-growth-strict
test-smells-new format insights-code insights-complexity insights-architecture insights-style duplication
duplication-clones phpstan-errors indication-checks deps-shadow deps-unused comment-density tests-failing coverage
coverage-age-days lazy-loads mutation tests-suite'

setup() {
    export LC_ALL=C
    WORK="$(mktemp -d)"
    unset CLAUDECODE AI_AGENT QG_SKIP_REASON COMPOSE_FILE COMPOSE_PROJECT_NAME COMPOSE_PROFILES COMPOSE_ENV_FILES DOCKER_HOST DOCKER_CONTEXT
    export GUARD_LOCK_WAIT=5
    mkdir -p "$WORK/bin"
    # A docker that records its argv, its cwd and any COMPOSE_/DOCKER_ variable it sees, then warns
    # the way compose does about an unset variable and prints one real error line.
    printf '%s\n' '#!/usr/bin/env bash' '[ "$1" = image ] && exit "${IMAGE_RC:-0}"' 'printf "%s\n" "$*" >> "$DOCKER_LOG"' 'pwd >> "$DOCKER_LOG"' \
        'env | grep -E "^(COMPOSE_|DOCKER_HOST|DOCKER_CONTEXT)" >> "$DOCKER_LOG" || true' \
        'echo "time=x level=warning msg=\"The \\\"SERVER_PORT\\\" variable is not set. Defaulting to a blank string.\"" >&2' \
        'echo "a real compose error line" >&2' 'exit "${DOCKER_RC:-0}"' > "$WORK/bin/docker"
    chmod +x "$WORK/bin/docker"
    export PATH="$WORK/bin:$PATH" DOCKER_LOG="$WORK/docker.log"
}

teardown() {
    [ -n "${WORK:-}" ] && [ -d "$WORK" ] && rm -rf "$WORK"
    return 0
}

# lock <file> <packages json> <packages-dev json> — a composer.lock with those entries.
lock() { jq -n --argjson p "$2" --argjson d "$3" '{packages: $p, "packages-dev": $d}' > "$1"; }
# installed <vendor dir> <lock> — vendor/composer/installed.json matching <lock>.
installed() { mkdir -p "$1/composer"; jq '{packages: (.packages + ."packages-dev")}' "$2" > "$1/composer/installed.json"; }

APP='{"name":"app/a","version":"1.0","require":{}}'
SHARED='{"name":"shared/parser","version":"1.0","require":{}}'
FRAMEWORK='{"name":"vendor/framework","version":"1.0","require":{"shared/parser":"*"}}'
TOOL='{"name":"tool/analyser","version":"1.0","require":{"vendor/framework":"*","php":"*"}}'
RULES='{"name":"tool/rules","version":"1.0","require":{"tool/analyser":"*"}}'
base_lock() { lock "$1" "[$APP,$SHARED,$FRAMEWORK]" "[$TOOL,$RULES]"; }
bump() { jq --arg n "$2" '(.packages[], ."packages-dev"[]) |= (if .name == $n then .version = "2.0" else . end)' "$1" > "$1.t" && mv "$1.t" "$1"; }
lockcheck() { bash -c ". $M/lock-check.sh; $1"; }

@test "lock check: vendor/ must match the lock exactly" {
    base_lock "$WORK/composer.lock"; installed "$WORK/vendor" "$WORK/composer.lock"
    run lockcheck "lock_check_vendor $WORK/composer.lock $WORK/vendor"
    [ "$status" -eq 0 ]
    bump "$WORK/composer.lock" app/a
    run lockcheck "lock_check_vendor $WORK/composer.lock $WORK/vendor"
    [ "$status" -eq 2 ] && [[ "$output" == *'does not match'* ]] && [[ "$output" == *'app/a'* ]]
}

@test "lock check: an application package may change; a tool, its rule extension or anything a tool requires may not" {
    base_lock "$WORK/head.lock"
    local name
    cp "$WORK/head.lock" "$WORK/tree.lock"; bump "$WORK/tree.lock" app/a
    run lockcheck "lock_check_tools $WORK/head.lock $WORK/tree.lock"
    [ "$status" -eq 0 ]
    for name in tool/analyser tool/rules vendor/framework shared/parser; do
        cp "$WORK/head.lock" "$WORK/tree.lock"; bump "$WORK/tree.lock" "$name"
        run lockcheck "lock_check_tools $WORK/head.lock $WORK/tree.lock"
        [ "$status" -eq 2 ] && [[ "$output" == *"$name"* ]] || { echo "not refused: $name"; return 1; }
    done
}

@test "lock check: a new application package passes, a new dev package is refused, at most 10 names print" {
    base_lock "$WORK/head.lock"
    lock "$WORK/tree.lock" "[$APP,$SHARED,$FRAMEWORK,{\"name\":\"app/new\",\"version\":\"1.0\"}]" "[$TOOL,$RULES]"
    run lockcheck "lock_check_tools $WORK/head.lock $WORK/tree.lock"
    [ "$status" -eq 0 ]
    lock "$WORK/tree.lock" "[$APP,$SHARED,$FRAMEWORK]" "[$TOOL,$RULES,{\"name\":\"tool/new\",\"version\":\"1.0\"}]"
    run lockcheck "lock_check_tools $WORK/head.lock $WORK/tree.lock"
    [ "$status" -eq 2 ] && [[ "$output" == *'tool/new'* ]]
    local dev='' i
    for i in $(seq 1 11); do dev+="{\"name\":\"tool/t$i\",\"version\":\"1.0\"},"; done
    lock "$WORK/h11.lock" '[]' "[${dev%,}]"; cp "$WORK/h11.lock" "$WORK/t11.lock"
    for i in $(seq 1 11); do bump "$WORK/t11.lock" "tool/t$i"; done
    run lockcheck "lock_check_tools $WORK/h11.lock $WORK/t11.lock"
    [ "$status" -eq 2 ] && [ "$(grep -c '^  tool/t' <<<"$output")" -eq 10 ]
}

# api_repo — a git repo laid out like recycling-api: committed lock, lock-check.sh and runners,
# with vendor/ and .env present and matching.
api_repo() {
    new_repo "$WORK/api"
    mkdir -p quality/bin
    cp "$M/lock-check.sh" "$M/in-tree.sh" "$M/in-server.sh" quality/bin/
    base_lock composer.lock
    printf 'services: {}\n' > docker-compose.yml
    printf 'vendor/\n.env\n' > .gitignore
    commit_all api
    installed vendor composer.lock
    printf 'DB_HOST=db\n' > .env
}

@test "in-tree.sh runs when the staged lock changes only an application package and vendor/ matches it" {
    api_repo
    mkdir -p "$WORK/tree"; cp composer.lock "$WORK/tree/"; bump "$WORK/tree/composer.lock" app/a
    installed vendor "$WORK/tree/composer.lock"
    run bash quality/bin/in-tree.sh "$WORK/tree" "$WORK/cache" vendor/bin/x
    [ "$status" -eq 0 ]
    grep -q 'recycling-api-server:latest nice -n 15 vendor/bin/x' "$DOCKER_LOG"
}

@test "in-tree.sh refuses a staged tool change, a vendor/ that differs from the staged lock, and the checkout itself" {
    api_repo
    mkdir -p "$WORK/tree"; cp composer.lock "$WORK/tree/"; bump "$WORK/tree/composer.lock" tool/rules
    installed vendor "$WORK/tree/composer.lock"
    run bash quality/bin/in-tree.sh "$WORK/tree" "$WORK/cache" vendor/bin/x
    [ "$status" -eq 2 ] && [[ "$output" == *'tool/rules'* ]]
    cp composer.lock "$WORK/tree/"; installed vendor composer.lock; bump "$WORK/tree/composer.lock" app/a
    run bash quality/bin/in-tree.sh "$WORK/tree" "$WORK/cache" vendor/bin/x
    [ "$status" -eq 2 ] && [[ "$output" == *'does not match'* ]]
    run bash quality/bin/in-tree.sh "$WORK/api" "$WORK/cache" vendor/bin/x
    [ "$status" -eq 2 ] && [[ "$output" == *'working checkout'* ]]
    [ ! -e "$DOCKER_LOG" ]
}

@test "in-server.sh pins the compose call and strips COMPOSE_*, DOCKER_HOST and DOCKER_CONTEXT" {
    api_repo
    COMPOSE_FILE=evil.yml COMPOSE_PROJECT_NAME=x COMPOSE_PROFILES=p COMPOSE_ENV_FILES=e DOCKER_HOST=tcp://x DOCKER_CONTEXT=c \
        run bash quality/bin/in-server.sh "$WORK/api" - vendor/bin/phpstan analyse
    [ "$status" -eq 0 ]
    [ "$(head -1 "$DOCKER_LOG")" = "compose -f $WORK/api/docker-compose.yml --project-directory $WORK/api --env-file /dev/null --progress quiet run --rm --no-deps --pull never -T --user $(id -u):$(id -g) -e XDEBUG_MODE=off server nice -n 15 vendor/bin/phpstan analyse" ]
    ! grep -qE '^(COMPOSE_|DOCKER_HOST|DOCKER_CONTEXT)' "$DOCKER_LOG"
    [[ "$output" == *'a real compose error line'* ]]
    [[ "$output" != *'variable is not set'* ]]
}

@test "in-server.sh refuses a merged compose file, a missing vendor/ or .env, and a vendor/ that differs from the lock" {
    api_repo
    local extra
    for extra in compose.yaml compose.yml docker-compose.override.yml docker-compose.override.yaml; do
        : > "$extra"
        run bash quality/bin/in-server.sh "$WORK/api" - x
        [ "$status" -eq 2 ] && [[ "$output" == *"$extra"* ]] || { echo "not refused: $extra"; return 1; }
        rm "$extra"
    done
    mv .env .env.off
    run bash quality/bin/in-server.sh "$WORK/api" - x
    [ "$status" -eq 2 ] && [[ "$output" == *'.env does not exist'* ]]
    mv .env.off .env; mv vendor vendor.off
    run bash quality/bin/in-server.sh "$WORK/api" - x
    [ "$status" -eq 2 ] && [[ "$output" == *'vendor does not exist'* ]]
    mv vendor.off vendor; bump composer.lock app/a
    run bash quality/bin/in-server.sh "$WORK/api" - x
    [ "$status" -eq 2 ] && [[ "$output" == *'does not match'* ]]
    [ ! -e "$DOCKER_LOG" ]
}

@test "in-server.sh runs when a committed tool package changed and vendor/ matches it: the commit gate judged that change" {
    api_repo
    bump composer.lock tool/rules; installed vendor composer.lock; commit_all bump
    run bash quality/bin/in-server.sh "$WORK/api" - x
    [ "$status" -eq 0 ] && [ -s "$DOCKER_LOG" ]
}

@test "in-server.sh refuses an uncommitted docker-compose.yml or docker/server change, and a missing image" {
    api_repo
    printf 'services: {x: {}}\n' > docker-compose.yml
    run bash quality/bin/in-server.sh "$WORK/api" - x
    [ "$status" -eq 2 ] && [[ "$output" == *'uncommitted changes'* ]]
    git checkout -q docker-compose.yml
    mkdir -p docker/server; printf 'FROM x\n' > docker/server/Dockerfile; commit_all image
    printf 'RUN evil\n' >> docker/server/Dockerfile
    run bash quality/bin/in-server.sh "$WORK/api" - x
    [ "$status" -eq 2 ] && [[ "$output" == *'uncommitted changes'* ]]
    git checkout -q docker/server/Dockerfile
    IMAGE_RC=1 run bash quality/bin/in-server.sh "$WORK/api" - x
    [ "$status" -eq 2 ] && [[ "$output" == *'image recycling-api-server:latest is missing'* ]]
    [ ! -e "$DOCKER_LOG" ]
}

@test "in-server.sh called on a linked worktree mounts that worktree, not the main checkout" {
    api_repo
    git worktree add -q --detach "$WORK/wt" HEAD
    installed "$WORK/wt/vendor" composer.lock; printf 'X=1\n' > "$WORK/wt/.env"
    run bash quality/bin/in-server.sh "$WORK/wt" - x
    [ "$status" -eq 0 ]
    [[ "$(head -1 "$DOCKER_LOG")" == "compose -f $WORK/wt/docker-compose.yml --project-directory $WORK/wt "* ]]
}

# v2_repo — a repo whose HEAD carries the prepared v2 checks.tsv and quality/config.
v2_repo() {
    new_repo "$WORK/v2"
    mkdir -p quality
    cp "$M/checks.tsv" quality/checks.tsv; cp "$M/config" quality/config
    printf 'id\ttool\tenforced_by\temits\n' > quality/rules.tsv
    commit_all v2
}

@test "the v2 file loads, names every v1 id, and every why is distinct and real" {
    v2_repo
    run bash -c '. /code/lib/guard-metrics.sh; . /code/lib/guard-pass.sh; guard_load_checks quality/checks.tsv && echo loaded'
    [ "$status" -eq 0 ] && [[ "$output" == *loaded* ]]
    local ids id
    ids="$(awk -F'\t' 'NR > 1 && $0 !~ /^#/ { print $1 }' quality/checks.tsv)"
    for id in $V1_IDS; do grep -qx "$id" <<<"$ids" || { echo "v1 id missing: $id"; return 1; }; done
    # An absent row names the row that replaces it, and that row exists.
    while IFS=$'\t' read -r id _ _ _ _ _ _ _ why; do
        local repl; repl="$(sed -n 's/^replaced by \([a-z0-9-]*\).*/\1/p' <<<"$why")"
        [ -n "$repl" ] && grep -qx "$repl" <<<"$ids" || { echo "absent row $id names no existing replacement: $why"; return 1; }
    done < <(awk -F'\t' '$3 == "absent"' quality/checks.tsv)
    [ -z "$(awk -F'\t' 'NR > 1 && $0 !~ /^#/ { print $9 }' quality/checks.tsv | sort | uniq -d)" ]
    ! awk -F'\t' 'NR > 1 && $0 !~ /^#/ { print $9 }' quality/checks.tsv | grep -qE '^(TODO|-$|\(no reason recorded)'
    [ "$(awk -F'\t' 'NR > 1 && $0 !~ /^#/ && $3 != "absent"' quality/checks.tsv | wc -l)" -eq 32 ]
}

# unprotected <checks.tsv> <config> -> each config file a driver row reads that no
# guard_protected_paths entry covers, one per line. A baseline= file is left out: it may shrink when
# findings are fixed, and the baseline-growth rows refuse any growth.
unprotected() {
    local prot; prot="$(sed -n 's/^guard_protected_paths:[[:space:]]*//p' "$2")"
    awk -F'\t' 'NR > 1 && $0 !~ /^#/ && $3 != "absent" && $4 != "shell" {
        n = split($5, w, " ")
        for (i = 1; i <= n; i++) {
            if (w[i] ~ /^(config|ruleset|standard|runner)=/) { sub(/^[a-z]+=/, "", w[i]); print w[i] }
            if (w[i] == "-c" && i < n) print w[i + 1]
        }
        if ($4 == "infection") print "infection.json5"
        if ($4 == "phpunit") print "phpunit.xml"
        if ($4 == "phpstan") print "phpstan.neon"
        if ($4 == "pint") print "pint.json"
        if ($4 == "jscpd-added") print ".jscpd.json"
        if ($5 ~ /in-server\.sh/) { print "docker-compose.yml"; print "docker-compose.override.yml"; print "compose.yaml"; print "compose.yml" }
    } END { print "quality/config"; print "quality/drivers"; print "quality/checks.tsv" }' "$1" | sort -u \
    | while IFS= read -r f; do
        local hit='' p
        for p in $prot; do p="${p%/}"; { [ "$f" = "$p" ] || [[ "$f" == "$p"/* ]]; } && hit=1; done
        [ -n "$hit" ] || printf '%s\n' "$f"
    done
}

@test "every config file a v2 row reads, every runner and every compose file is protected" {
    run unprotected "$M/checks.tsv" "$M/config"
    [ "$status" -eq 0 ] && [ -z "$output" ] || { echo "unprotected: $output"; return 1; }
    # The check itself catches an unprotected file.
    { cat "$M/checks.tsv"; printf 'x\tcommit\tdiff\tphpinsights\tconfig=quality/new.php\tup\t0\trefuse\ta row reading an unprotected config\n'; } > "$WORK/c.tsv"
    run unprotected "$WORK/c.tsv" "$M/config"
    [ "$output" = quality/new.php ]
}

# v1_api <dir> — a checkout shaped like recycling-api with its v1 checks.tsv.
v1_api() {
    new_repo "$1"
    mkdir -p quality/bin tests/Quality/IndicationChecks tests/Unit/Quality/IndicationChecks
    printf 'id\tscope\tkind\tcommand\tparser\tartifact\tdirection\tthreshold\tgate\n' > quality/checks.tsv
    : > quality/bin/in-tree.sh; : > quality/phpstan-strict.neon
    : > tests/Quality/IndicationChecks/ParallelWorkersCappedCheck.php
    commit_all v1
}

@test "apply.sh copies the five files, commits nothing, and prints the six steps with the new ids" {
    v1_api "$WORK/api"
    local before; before="$(git rev-parse HEAD)"
    mkdir -p "$WORK/m"; cp "$M"/* "$WORK/m/"
    printf 'id\tnew-id\tkind\tverdict\ninsights-code\tinsights-code-v2\trepo\tDIFF\nformat\tformat-files\tdiff\tDIFF\n' > "$WORK/m/parity.tsv"
    run bash "$WORK/m/apply.sh" "$WORK/api"
    [ "$status" -eq 0 ]
    cmp "$M/checks.tsv" quality/checks.tsv && cmp "$M/config" quality/config
    cmp "$M/ParallelWorkersCappedCheck.php" tests/Quality/IndicationChecks/ParallelWorkersCappedCheck.php
    [ -x quality/bin/in-server.sh ] && [ -x quality/bin/lock-check.sh ]
    [ "$(git rev-parse HEAD)" = "$before" ]
    [[ "$output" == *'qg baseline --only insights-code-v2'* ]]
    [[ "$output" == *'qg override --reason'* ]] && [[ "$output" == *'git add quality/checks.tsv quality/config'* ]]
}

@test "apply.sh refuses a checkout already on v2, and an agent applying it outside /tmp" {
    v1_api "$WORK/api"
    printf '%s\n' "$V2_HEADER" > quality/checks.tsv
    run bash "$M/apply.sh" "$WORK/api"
    [ "$status" -eq 2 ] && [[ "$output" == *'not the v1 file'* ]]
    [ -w /dev/shm ] || skip 'no writable folder outside /tmp in this container'
    v1_api /dev/shm/qg-apply-$$
    ln -s /dev/shm/qg-apply-$$ "$WORK/link"
    CLAUDECODE=1 TMPDIR=/dev/shm run bash "$M/apply.sh" "$WORK/link"
    [ "$status" -eq 2 ] && [[ "$output" == *'agents may not apply'* ]]
    rm -rf /dev/shm/qg-apply-$$
    # A rehearsal on a scratch clone under the real /tmp is allowed; without parity.tsv nothing is copied.
    v1_api "$WORK/scratch"
    mkdir -p "$WORK/m"; cp "$M"/* "$WORK/m/"; rm -f "$WORK/m/parity.tsv"
    CLAUDECODE=1 run bash "$WORK/m/apply.sh" "$WORK/scratch"
    [ "$status" -eq 2 ] && [[ "$output" == *'parity.tsv is missing'* ]]
    cmp -s "$M/checks.tsv" quality/checks.tsv && return 1
    printf 'id\tnew-id\tkind\tverdict\n' > "$WORK/m/parity.tsv"
    CLAUDECODE=1 run bash "$WORK/m/apply.sh" "$WORK/scratch"
    [ "$status" -eq 0 ] && [[ "$output" == *'No repo row took a new id'* ]]
}
