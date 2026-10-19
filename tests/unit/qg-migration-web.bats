#!/usr/bin/env bats
# The prepared app.givore.com and dashboard.givore.com migrations under migrations/<repo>/: the v2
# rows load under this engine and name every v1 id, every file a row reads is protected, and
# apply.sh copies or refuses, and prints the branch steps from branches.tsv.

bats_require_minimum_version 1.5.0
load guard-helpers

MIG=/code/migrations
REPOS='app.givore.com dashboard.givore.com'
V1_HEADER=$'id\tscope\tkind\tcommand\tparser\tartifact\tdirection\tthreshold\tgate'
V2_HEADER=$'id\ton\tkind\tdriver\targs\tdirection\tthreshold\tgate\twhy'
# The ids of each repo's v1 quality/checks.tsv on release/1.19.0, which the v2 file must still name.
V1_IDS_app='lint-errors mess typecheck-errors architecture deadcode repo-consistency dupes-semantic boundaries
complexity-excess duplication duplication-clones tests-failing coverage coverage-age-days mutation tests-suite lint-new
typecheck-new duplication-new suppressions-added gate-config-touched'
V1_IDS_dashboard='lint-new typecheck-new duplication-new suppressions-added gate-config-touched lint-errors
typecheck-errors duplication duplication-clones tests-suite tests-failing coverage coverage-age-days'
# The files each repo's apply.sh copies, as <source in migrations/<repo>> <target in the checkout>.
COPIES='checks.tsv:quality/checks.tsv config:quality/config jscpd.json:quality/jscpd.json README.md:quality/README.md'

setup() {
    export LC_ALL=C
    WORK="$(mktemp -d)"
    unset CLAUDECODE AI_AGENT QG_SKIP_REASON
}

teardown() {
    [ -n "${WORK:-}" ] && [ -d "$WORK" ] && rm -rf "$WORK"
    return 0
}

v1_ids() { local v="V1_IDS_${1%%.*}"; printf '%s\n' ${!v}; }
# drivers_of <checks.tsv> -> every non-shell driver its rows name, one per line.
drivers_of() { awk -F'\t' 'NR > 1 && $0 !~ /^#/ && $3 != "absent" && $4 != "shell" { print $4 }' "$1" | sort -u; }

@test "each web v2 file and recycling-api's load under this engine with their config" {
    local repo missing='' d
    for repo in $REPOS recycling-api; do
        for d in $(drivers_of "$MIG/$repo/checks.tsv"); do
            [ -x "/code/drivers/$d.sh" ] || missing+=" $d"
        done
    done
    [ -z "$missing" ] || skip "built-in drivers not written yet:$missing"
    for repo in $REPOS recycling-api; do
        new_repo "$WORK/$repo"
        mkdir -p quality
        cp "$MIG/$repo/checks.tsv" quality/checks.tsv; cp "$MIG/$repo/config" quality/config
        printf 'id\ttool\tenforced_by\temits\n' > quality/rules.tsv
        commit_all v2
        run bash -c '. /code/lib/guard-metrics.sh; . /code/lib/guard-pass.sh; guard_load_checks quality/checks.tsv && echo loaded'
        [ "$status" -eq 0 ] && [[ "$output" == *loaded* ]] || { echo "$repo: $output"; return 1; }
    done
}

@test "each web v2 file names every v1 id, its absent rows name an existing replacement, and its whys are distinct" {
    local repo ids id why repl
    for repo in $REPOS; do
        local f="$MIG/$repo/checks.tsv"
        [ "$(head -1 "$f")" = "$V2_HEADER" ]
        ids="$(awk -F'\t' 'NR > 1 && $0 !~ /^#/ { print $1 }' "$f")"
        for id in $(v1_ids "$repo"); do grep -qx "$id" <<<"$ids" || { echo "$repo: v1 id missing: $id"; return 1; }; done
        while IFS=$'\t' read -r id _ _ _ _ _ _ _ why; do
            repl="$(sed -n 's/^replaced by \([a-z0-9-]*\).*/\1/p' <<<"$why")"
            [ -n "$repl" ] && grep -qx "$repl" <<<"$ids" || { echo "$repo: absent row $id names no existing replacement"; return 1; }
        done < <(awk -F'\t' '$3 == "absent"' "$f")
        [ -z "$(awk -F'\t' 'NR > 1 && $0 !~ /^#/ { print $9 }' "$f" | sort | uniq -d)" ]
        ! awk -F'\t' 'NR > 1 && $0 !~ /^#/ { print $9 }' "$f" | grep -qE '^(TODO|-$|\(no reason recorded)'
        ! awk -F'\t' 'NR > 1 && $0 !~ /^#/ { print $5 }' "$f" | grep -qF -e '\|' -e '…'
        grep -qx tools-changed <<<"$ids"
        [ "$(awk -F'\t' '$1 == "tools-changed" { print $3, $6, $7, $8 }' "$f")" = 'diff down 0 refuse' ]
        jq -e '.gitignore == false' "$MIG/$repo/jscpd.json" >/dev/null
    done
    [ "$(awk -F'\t' 'NR > 1 && $0 !~ /^#/ && $3 != "absent"' "$MIG/app.givore.com/checks.tsv" | wc -l)" -eq 22 ]
    [ "$(awk -F'\t' 'NR > 1 && $0 !~ /^#/ && $3 != "absent"' "$MIG/dashboard.givore.com/checks.tsv" | wc -l)" -eq 14 ]
}

# unprotected <checks.tsv> <config> -> each file a row reads that no guard_protected_paths entry
# covers: config= and runner= values, the default config each driver's tool loads, and the scripts
# the shell rows run from the repo.
unprotected() {
    local prot; prot="$(sed -n 's/^guard_protected_paths:[[:space:]]*//p' "$2")"
    awk -F'\t' 'NR > 1 && $0 !~ /^#/ && $3 != "absent" {
        n = split($5, w, " ")
        for (i = 1; i <= n; i++) {
            if (w[i] ~ /^(config|runner)=/) { sub(/^[a-z]+=/, "", w[i]); print w[i] }
            if (w[i] ~ /^(scripts|quality)\/[^ ]*\.(mjs|sh)$/) print w[i]
            if (w[i] ~ /^HEAD:quality\//) { sub(/^HEAD:/, "", w[i]); sub(/\)"$/, "", w[i]); print w[i] }
        }
        if ($4 == "eslint") print "eslint.config.mjs"
        if ($4 == "nuxt-typecheck") print "tsconfig.json"
        if ($4 == "knip") print "knip.json"
        if ($4 == "depcruise") print ".dependency-cruiser.cjs"
        if ($4 == "fallow") print ".fallowrc.json"
        if ($4 == "vitest") print "vitest.config.ts"
        if ($4 == "stryker") print "stryker.config.json"
        if ($4 == "jscpd" || $4 == "jscpd-added") print ".npmrc"
    } END { print "quality/config"; print "quality/drivers"; print "quality/checks.tsv" }' "$1" | sort -u \
    | while IFS= read -r f; do
        local hit='' p
        for p in $prot; do p="${p%/}"; { [ "$f" = "$p" ] || [[ "$f" == "$p"/* ]]; } && hit=1; done
        [ -n "$hit" ] || printf '%s\n' "$f"
    done
}

@test "every config file, runner and script a web v2 row reads is protected; nuxt.config.ts is not" {
    local repo
    for repo in $REPOS; do
        run unprotected "$MIG/$repo/checks.tsv" "$MIG/$repo/config"
        [ "$status" -eq 0 ] && [ -z "$output" ] || { echo "$repo unprotected: $output"; return 1; }
        ! sed -n 's/^guard_protected_paths://p' "$MIG/$repo/config" | grep -qw 'nuxt.config.ts'
        grep -qx 'guard_measure_worktree: false' "$MIG/$repo/config"
    done
    sed -n 's/^guard_protected_paths://p' "$MIG/app.givore.com/config" | grep -qw -- '.jscpd.json'
    # The check itself catches an unprotected file.
    { cat "$MIG/app.givore.com/checks.tsv"; printf 'x\tcommit\tdiff\tknip\tconfig=quality/new.json\tdown\t0\trefuse\ta row reading an unprotected config\n'; } > "$WORK/c.tsv"
    run unprotected "$WORK/c.tsv" "$MIG/app.givore.com/config"
    [ "$output" = quality/new.json ]
}

# engine <dir> [<driver to leave out>] — a fake engine: bin/guard.sh and an executable drivers/<d>.sh
# for every driver either web file names.
engine() {
    local d
    mkdir -p "$1/bin" "$1/drivers"
    : > "$1/bin/guard.sh"
    for d in $(cat <(drivers_of "$MIG/app.givore.com/checks.tsv") <(drivers_of "$MIG/dashboard.givore.com/checks.tsv") | sort -u); do
        [ "$d" = "${2:-}" ] && continue
        printf '#!/bin/sh\n' > "$1/drivers/$d.sh"; chmod +x "$1/drivers/$d.sh"
    done
}

# hook <checkout> <name> <GUARD path or -> — a hook whose GUARD= line names that engine (- for none).
hook() {
    local h; h="$(git -C "$1" rev-parse --path-format=absolute --git-common-dir)/hooks/$2"
    mkdir -p "$(dirname "$h")"
    if [ "$3" = - ]; then printf '#!/usr/bin/env bash\nexit 0\n' > "$h"
    else printf '#!/usr/bin/env bash\nset -uo pipefail\nGUARD="%s"\n' "$3" > "$h"; fi
}

# v1_web <dir> <repo> — a checkout shaped like that repo on release/1.19.0, with hooks calling
# the fake engine at $WORK/engine.
v1_web() {
    new_repo "$1"
    mkdir -p quality/bin scripts
    printf '%s\n' "$V1_HEADER" > quality/checks.tsv
    printf '{"gitignore": true}\n' > quality/jscpd.json
    case "$2" in
        app.givore.com) : > quality/bin/commit-check.sh; : > scripts/quality-metric.mjs ;;
        *)              : > quality/bin/tree-report.sh; : > quality/bin/metric.sh ;;
    esac
    commit_all v1
    [ -d "$WORK/engine" ] || engine "$WORK/engine"
    hook "$1" pre-commit "$WORK/engine/bin/guard.sh"
    hook "$1" pre-push "$WORK/engine/bin/guard.sh"
}

# mig <repo> — a writable copy of migrations/<repo> and migrations/web with a proven parity.tsv;
# prints the path of its apply.sh.
mig() {
    mkdir -p "$WORK/m/$1" "$WORK/m/web"
    cp "$MIG/$1"/* "$WORK/m/$1/"
    if [ -r "$MIG/web/in-node.sh" ]; then cp "$MIG/web/in-node.sh" "$WORK/m/web/"
    else printf '#!/usr/bin/env bash\n' > "$WORK/m/web/in-node.sh"; fi
    printf '%s\n' $'id\tnew-id\tkind\tverdict\told-clean\told-seed1\told-seed2\tnew-clean\tnew-seed1\tnew-seed2' \
        $'lint-errors\tlint-errors\trepo\tSAME\t0/ok\t1/worse\t2/worse\t-\t1/worse\t2/worse' \
        $'tests-suite\ttests-suite-failed\tdiff\tNEW\t0/ok\t1/worse\t1/worse\t0/ok\t1/worse\t2/worse' > "$WORK/m/$1/parity.tsv"
    printf '%s' "$WORK/m/$1/apply.sh"
}

# untouched <checkout> — nothing was copied: quality/ holds only the v1 files.
untouched() {
    [ "$(head -1 "$1/quality/checks.tsv")" = "$V1_HEADER" ] && [ ! -e "$1/quality/config" ] \
        && [ ! -e "$1/quality/bin/in-node.sh" ] && [ ! -e "$1/quality/README.md" ] \
        && [ -z "$(git -C "$1" status --porcelain)" ]
}

@test "apply.sh copies its five files, leaves HEAD and the index unchanged, and prints no baseline step" {
    local repo apply pair head index
    for repo in $REPOS; do
        v1_web "$WORK/$repo" "$repo"
        apply="$(mig "$repo")"
        head="$(git rev-parse HEAD)" index="$(git ls-files -s | sha1sum)"
        run bash "$apply" "$WORK/$repo"
        [ "$status" -eq 0 ] || { echo "$repo: $output"; return 1; }
        for pair in $COPIES; do cmp "$WORK/m/$repo/${pair%%:*}" "$WORK/$repo/${pair#*:}"; done
        cmp "$WORK/m/web/in-node.sh" quality/bin/in-node.sh && [ -x quality/bin/in-node.sh ]
        [ "$(git rev-parse HEAD)" = "$head" ] && [ "$(git ls-files -s | sha1sum)" = "$index" ]
        [[ "$output" == *'No repo row took a new id'* ]] && [[ "$output" != *'qg baseline --only'* ]]
        [[ "$output" == *'qg override --reason "migrate the gate config to v2"'* ]]
        [[ "$output" == *'git add quality/checks.tsv quality/config quality/jscpd.json quality/README.md quality/bin/in-node.sh'* ]]
        [[ "$output" == *'apply.sh --branch-steps'* ]] && [[ "$output" == *'tools-changed'* ]]
    done
    [[ "$(bash "$WORK/m/app.givore.com/apply.sh" "$WORK/app.givore.com" 2>&1 || true)" == *'not the v1 file'* ]]
}

@test "apply.sh lists the v1 scripts no row runs any more" {
    v1_web "$WORK/app" app.givore.com
    run bash "$(mig app.givore.com)" "$WORK/app"
    [ "$status" -eq 0 ] && [[ "$output" == *'quality/bin/commit-check.sh'* ]] && [[ "$output" == *'tests-suite-failed'* ]]
    v1_web "$WORK/dash" dashboard.givore.com
    run bash "$(mig dashboard.givore.com)" "$WORK/dash"
    [ "$status" -eq 0 ] && [[ "$output" == *'quality/bin/tree-report.sh'* ]]
}

@test "apply.sh refuses a checkout with no v1 header, or of the other repo, and copies nothing" {
    local repo apply
    for repo in $REPOS; do
        v1_web "$WORK/$repo" "$repo"
        apply="$(mig "$repo")"
        printf '%s\n' "$V2_HEADER" > quality/checks.tsv; commit_all v2
        run bash "$apply" "$WORK/$repo"
        [ "$status" -eq 2 ] && [[ "$output" == *'not the v1 file'* ]] && [ ! -e quality/config ]
    done
    v1_web "$WORK/other" dashboard.givore.com
    run bash "$WORK/m/app.givore.com/apply.sh" "$WORK/other"
    [ "$status" -eq 2 ] && [[ "$output" == *'does not look like app.givore.com'* ]] && untouched "$WORK/other"
}

@test "apply.sh refuses an agent outside the real /tmp, even with an empty variable, a symlink or TMPDIR under HOME" {
    [ -w /dev/shm ] || skip 'no writable folder outside /tmp in this container'
    local repo apply out="/dev/shm/qg-web-$$"
    for repo in $REPOS; do
        apply="$(mig "$repo")"
        v1_web "$out-$repo" "$repo"
        ln -s "$out-$repo" "$WORK/link-$repo"
        CLAUDECODE='' run bash "$apply" "$out-$repo"
        [ "$status" -eq 2 ] && [[ "$output" == *'agents may not apply'* ]]
        AI_AGENT='' run bash "$apply" "$WORK/link-$repo"
        [ "$status" -eq 2 ] && [[ "$output" == *'agents may not apply'* ]]
        CLAUDECODE=1 HOME="$out-$repo" TMPDIR="$out-$repo/tmp" run bash "$apply" "$WORK/link-$repo"
        [ "$status" -eq 2 ] && [[ "$output" == *'agents may not apply'* ]]
        untouched "$out-$repo" || { rm -rf "$out-$repo"; return 1; }
        rm -rf "$out-$repo"
        # A rehearsal on a scratch checkout under the real /tmp is allowed.
        v1_web "$WORK/$repo" "$repo"
        CLAUDECODE=1 run bash "$apply" "$WORK/$repo"
        [ "$status" -eq 0 ] || { echo "$repo rehearsal: $output"; return 1; }
    done
}

@test "apply.sh refuses a hook with no GUARD=, hooks naming different engines, and an engine lacking a named driver" {
    local repo apply d
    for repo in $REPOS; do
        apply="$(mig "$repo")"
        v1_web "$WORK/$repo" "$repo"
        hook "$WORK/$repo" pre-push -
        run bash "$apply" "$WORK/$repo"
        [ "$status" -eq 2 ] && [[ "$output" == *'pre-push has no GUARD= line'* ]] && untouched "$WORK/$repo"
        engine "$WORK/engine2"
        hook "$WORK/$repo" pre-push "$WORK/engine2/bin/guard.sh"
        run bash "$apply" "$WORK/$repo"
        [ "$status" -eq 2 ] && [[ "$output" == *'different engines'* ]] && untouched "$WORK/$repo"
        for d in $(drivers_of "$MIG/$repo/checks.tsv"); do
            rm -rf "$WORK/engine3"; engine "$WORK/engine3" "$d"
            hook "$WORK/$repo" pre-commit "$WORK/engine3/bin/guard.sh"
            hook "$WORK/$repo" pre-push "$WORK/engine3/bin/guard.sh"
            run bash "$apply" "$WORK/$repo"
            [ "$status" -eq 2 ] && [[ "$output" == *"no driver $d"* ]] && untouched "$WORK/$repo" \
                || { echo "$repo: not refused without driver $d: $output"; return 1; }
        done
        rm -rf "$WORK/engine2" "$WORK/engine3"
    done
}

@test "apply.sh refuses a parity.tsv that is absent or holds a DIFF, VACUOUS or unmeasured row" {
    local repo apply line
    for repo in $REPOS; do
        apply="$(mig "$repo")"
        v1_web "$WORK/$repo" "$repo"
        cp "$WORK/m/$repo/parity.tsv" "$WORK/parity.good"
        rm "$WORK/m/$repo/parity.tsv"
        run bash "$apply" "$WORK/$repo"
        [ "$status" -eq 2 ] && [[ "$output" == *'parity.tsv is missing'* ]] && untouched "$WORK/$repo"
        for line in $'mess\tmess\trepo\tDIFF\t0/ok\t1/worse\t2/worse\t-\t1/worse\t3/worse' \
                    $'deadcode\tdeadcode\trepo\tVACUOUS\t0/ok\t0/ok\t0/ok\t-\t0/ok\t0/ok' \
                    $'coverage\tcoverage\trepo\tSAME\t50/ok\t40/worse\t30/worse\t-\t-/unmeasurable\t30/worse'; do
            { cat "$WORK/parity.good"; printf '%s\n' "$line"; } > "$WORK/m/$repo/parity.tsv"
            run bash "$apply" "$WORK/$repo"
            [ "$status" -eq 2 ] && [[ "$output" == *'not proven'* ]] && untouched "$WORK/$repo" \
                || { echo "$repo: not refused: $line"; return 1; }
        done
    done
}

# branches <repo> <row>... — branches.tsv beside that repo's apply.sh, header plus the rows.
branches() {
    local repo="$1"; shift
    { printf 'branch\tbranch-sha\trelease-sha\tmerge-sha\tconflicts\tid\tvalue\tstatus\trelease-baseline\n'
      printf '%s\n' "$@"; } > "$WORK/m/$repo/branches.tsv"
}

@test "--branch-steps lists for qg baseline --only exactly the repo rows worse than the release baseline" {
    local apply; apply="$(mig app.givore.com)"
    branches app.givore.com \
        $'master\taaa\tbbb\tccc\t-\tlint-errors\t10\tworse\t9' \
        $'master\taaa\tbbb\tccc\t-\tcoverage\t50.1\tworse\t53.43' \
        $'master\taaa\tbbb\tccc\t-\tduplication\t2.33\tok\t2.33' \
        $'master\taaa\tbbb\tccc\t-\tmutation\t80\tok\t74.33' \
        $'master\taaa\tbbb\tccc\t-\ttypecheck-errors\t40\tok\t42' \
        $'master\taaa\tbbb\tccc\t-\ttests-failing\t3\tworse\t-' \
        $'development\tddd\tbbb\teee\t.serena/x\tlint-errors\t9\tok\t9' \
        $'development\tddd\tbbb\teee\t.serena/x\tcoverage\t60\tok\t53.43'
    # It copies nothing, so it runs in an agent environment too.
    CLAUDECODE=1 run --separate-stderr bash "$apply" --branch-steps
    [ "$status" -eq 0 ] || { echo "$output $stderr"; return 1; }
    [ "$(grep -c 'qg baseline --only' <<<"$output")" -eq 1 ]
    grep -qx '  2. qg baseline --only lint-errors,coverage' <<<"$output"
    [[ "$output" == *'On master (merge ccc)'* ]] && [[ "$output" == *'On development (merge eee)'* ]]
    [[ "$output" == *'no repo row on development is worse'* ]]
    [ -z "$(ls "$WORK/m/app.givore.com" | grep -vxE 'apply.sh|checks.tsv|config|jscpd.json|README.md|parity.tsv|branches.tsv')" ]
    # dashboard development reruns the suite before reading its reports.
    apply="$(mig dashboard.givore.com)"
    branches dashboard.givore.com $'master\taaa\tbbb\tccc\t-\tlint-errors\t6\tok\t6' $'development\tddd\tbbb\teee\t-\tlint-errors\t6\tok\t6'
    run --separate-stderr bash "$apply" --branch-steps
    [ "$status" -eq 0 ] && [[ "$output" == *'qg run push --only tests-failing,coverage'* ]]
}

@test "--branch-steps exits 2 with no output on an absent branches.tsv, a missing branch or an unmeasured row" {
    local repo apply rows
    for repo in $REPOS; do
        apply="$(mig "$repo")"
        run --separate-stderr bash "$apply" --branch-steps
        [ "$status" -eq 2 ] && [ -z "$output" ] && [[ "$stderr" == *'branches.tsv is missing'* ]]
        branches "$repo" $'master\taaa\tbbb\tccc\t-\tlint-errors\t10\tworse\t6'
        run --separate-stderr bash "$apply" --branch-steps
        [ "$status" -eq 2 ] && [ -z "$output" ] && [[ "$stderr" == *'no row for development'* ]]
        for rows in $'development\tddd\tbbb\teee\t-\tlint-errors\t-\tunmeasurable\t6' \
                    $'development\tddd\tbbb\teee\t-\tlint-errors\t7\tunmeasurable\t6'; do
            branches "$repo" $'master\taaa\tbbb\tccc\t-\tlint-errors\t10\tworse\t6' "$rows"
            run --separate-stderr bash "$apply" --branch-steps
            [ "$status" -eq 2 ] && [ -z "$output" ] && [[ "$stderr" == *'not measured'* ]] \
                || { echo "$repo: not refused: $rows"; return 1; }
        done
    done
}
