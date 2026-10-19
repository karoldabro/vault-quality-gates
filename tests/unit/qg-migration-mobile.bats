#!/usr/bin/env bats
# The prepared recycling_mobile_app migration under migrations/recycling_mobile_app/: the v2 rows load,
# keep every v1 id, protect every file a row reads, hold no table-escaped `\|`, run the suite rows last;
# and apply.sh copies three files, commits nothing, and refuses what it must.

load guard-helpers

M=/code/migrations/recycling_mobile_app
# The 66 ids of recycling_mobile_app's v1 quality/checks.tsv at 884aad23, which the v2 file must name.
V1_IDS='format analyze-issues complexity architecture-cycles duplication duplication-clones comment-density
tests-failing coverage coverage-age-days mutation insights deps-shadow domain-material-imports
domain-api-model-imports raw-color-literals god-files share-position-origin unawaited-futures
domain-ui-imports cdn-host-pinned-classifier notifier-unguarded-notify compact-density-iconbutton
static-singletons magic-spacing-literals expandable-page-view typeerror-escaping-guards
styled-elevated-button svg-style-blocks copywith-unguarded-merge critical-init-actions
media-capture-ceilings comment-blocks-over-two hardcoded-ui-strings arb-banned-brand-words
arb-pt-brazilian-forms full-user-model-save committed-conflict-markers test-tail-dispose
test-hardcoded-en-text golden-seam-not-reset analytics-raw-error-field premium-hand-formatted-money
delete-flow-awaited-analytics detail-sheet-dynamic-state detail-screen-feed-widgets
paging-controller-cancel polymorphic-type-filter e2e-screen-wake e2e-boot-drain-teardown
e2e-whole-dir-run e2e-first-feed-tile e2e-undrained-boot e2e-bytype-async-screen semantic-clones
architecture-nccd layer-inversions deep-nesting many-parameters long-functions large-classes
lint-refuse-new lint-warn-new duplication-new suppressions-added gate-config-touched'
# v1 rows that were already kind absent: they name no replacement.
V1_ABSENT='insights deps-shadow'

setup() {
    export LC_ALL=C
    WORK="$(mktemp -d)"
    unset CLAUDECODE AI_AGENT
}

teardown() {
    [ -n "${WORK:-}" ] && [ -d "$WORK" ] && rm -rf "$WORK"
    return 0
}

rows() { awk -F'\t' 'NR > 1 && $0 !~ /^#/' "$1"; }

@test "the v2 file loads, names every v1 id, and every why is distinct and real" {
    new_repo "$WORK/v2"
    mkdir -p quality
    cp "$M/checks.tsv" quality/checks.tsv; cp "$M/config" quality/config
    printf 'id\ttool\tenforced_by\temits\n' > quality/rules.tsv
    commit_all v2
    run bash -c '. /code/lib/guard-metrics.sh; . /code/lib/guard-pass.sh; guard_load_checks quality/checks.tsv && echo loaded'
    [ "$status" -eq 0 ]
    [[ "$output" == *loaded* ]]
    local ids id why repl
    ids="$(rows quality/checks.tsv | cut -f1)"
    for id in $V1_IDS; do grep -qx "$id" <<<"$ids" || { echo "v1 id missing: $id"; return 1; }; done
    [ "$(wc -w <<<"$V1_IDS")" -eq 66 ]
    # An absent row that was live in v1 names the row that replaces it, and that row exists.
    while IFS=$'\t' read -r id _ _ _ _ _ _ _ why; do
        [[ " $V1_ABSENT " == *" $id "* ]] && continue
        repl="$(sed -n 's/^replaced by \([a-z0-9-]*\).*/\1/p' <<<"$why")"
        [ -n "$repl" ] && grep -qx "$repl" <<<"$ids" || { echo "absent row $id names no existing replacement: $why"; return 1; }
    done < <(rows quality/checks.tsv | awk -F'\t' '$3 == "absent"')
    [ -z "$(rows quality/checks.tsv | cut -f9 | sort | uniq -d)" ]
    ! rows quality/checks.tsv | cut -f9 | grep -qE '^(TODO|-$|\(no reason recorded)'
}

# unprotected <checks.tsv> <config> -> each file a driver row reads that no guard_protected_paths
# entry covers, one per line: every awk=, runner=, rules=, requirements= and options-allow= value, and
# each Dart driver's default config files (vault/architecture/qg-dart-drivers.md).
unprotected() {
    local prot; prot="$(sed -n 's/^guard_protected_paths:[[:space:]]*//p' "$2")"
    awk -F'\t' 'NR > 1 && $0 !~ /^#/ && $3 != "absent" && $4 != "shell" {
        n = split($5, w, " ")
        for (i = 1; i <= n; i++) {
            if (w[i] == "--") break
            if (w[i] ~ /^(awk|runner|rules|requirements)=/) { sub(/^[a-z]+=/, "", w[i]); print w[i] }
            if (w[i] ~ /^options-allow=/) { sub(/^options-allow=/, "", w[i]); m = split(w[i], o, ","); for (j = 1; j <= m; j++) print o[j] }
        }
        if ($4 ~ /^dart-(analyze|format|code-linter)$/) print "analysis_options.yaml"
        if ($4 == "flutter-test" || $4 == "mutation-test") { print "dart_test.yaml"; print "test/flutter_test_config.dart" }
        if ($4 ~ /^(dart-|flutter-|layerlens|lakos|mutation-test)/ && $4 != "dart-lock") { print "pubspec_overrides.yaml"; print ".dart_tool" }
    } END { print "quality/config"; print "quality/drivers"; print "quality/checks.tsv"; print "analysis_options.base.yaml" }' "$1" | sort -u \
    | while IFS= read -r f; do
        local hit='' p
        for p in $prot; do p="${p%/}"; { [ "$f" = "$p" ] || [[ "$f" == "$p"/* ]]; } && hit=1; done
        [ -n "$hit" ] || printf '%s\n' "$f"
    done
}

@test "every file a v2 row reads, every Dart default config and every package override is protected" {
    run unprotected "$M/checks.tsv" "$M/config"
    [ "$status" -eq 0 ] && [ -z "$output" ] || { echo "unprotected: $output"; return 1; }
    # The check itself catches an unprotected file.
    { cat "$M/checks.tsv"; printf 'x\tpush\trepo\tgrep-count\tpaths=lib awk=tool/new.awk\tdown\t0\trefuse\ta row reading an unprotected script\n'; } > "$WORK/c.tsv"
    run unprotected "$WORK/c.tsv" "$M/config"
    [ "$output" = tool/new.awk ]
}

@test "no driver row holds a table-escaped \\| and the suite rows run after every other push or baseline row" {
    ! rows "$M/checks.tsv" | awk -F'\t' '$4 != "shell" && $5 ~ /\\\|/ { print $1; bad = 1 } END { exit !bad }'
    run awk -F'\t' 'NR > 1 && $0 !~ /^#/ && $3 != "absent" && $2 ~ /push|baseline/ {
            if ($4 == "flutter-test" || $4 == "mutation-test") suite = 1
            else if (suite) { print $1; late = 1 }
        } END { exit late }' "$M/checks.tsv"
    [ "$status" -eq 0 ] || { echo "rows after the suite rows: $output"; return 1; }
    # The order check catches a row placed after a suite row.
    { cat "$M/checks.tsv"; printf 'late\tpush\trepo\tgrep-count\tpaths=lib -- x\tdown\t0\trefuse\ta row after the suite\n'; } > "$WORK/c.tsv"
    run awk -F'\t' 'NR > 1 && $0 !~ /^#/ && $3 != "absent" && $2 ~ /push|baseline/ {
            if ($4 == "flutter-test" || $4 == "mutation-test") suite = 1
            else if (suite) { print $1; late = 1 }
        } END { exit late }' "$WORK/c.tsv"
    [ "$status" -eq 1 ]
    [ "$output" = late ]
}

# v1_mobile <dir> — a checkout shaped like recycling_mobile_app with its v1 checks.tsv and hooks that
# call /code/bin/guard.sh.
v1_mobile() {
    new_repo "$1"
    mkdir -p quality/bin tool/givore_lints/bin
    printf 'id\tscope\tkind\tcommand\tparser\tartifact\tdirection\tthreshold\tgate\n' > quality/checks.tsv
    : > quality/bin/commit-lint.sh; : > tool/lcov_summary.dart; : > tool/givore_lints/bin/gate.dart
    commit_all v1
    local h; for h in pre-commit pre-push; do printf '#!/usr/bin/env bash\nGUARD="/code/bin/guard.sh"\n' > ".git/hooks/$h"; done
}

# migration <dir> <parity rows> — a copy of the migration folder whose config names a fake SDK.
migration() {
    mkdir -p "$1" "$WORK/sdk/bin/cache/dart-sdk/bin"
    cp "$M"/* "$1/"
    : > "$WORK/sdk/bin/flutter"; : > "$WORK/sdk/bin/cache/dart-sdk/bin/dart"
    chmod +x "$WORK/sdk/bin/flutter" "$WORK/sdk/bin/cache/dart-sdk/bin/dart"
    sed -i "s#^guard_flutter_root:.*#guard_flutter_root: $WORK/sdk#" "$1/config"
    printf 'id\tnew-id\tkind\tverdict\n%s' "$2" > "$1/parity.tsv"
}

@test "apply.sh copies three files, commits nothing, and offers only renamed repo rows to qg baseline" {
    v1_mobile "$WORK/app"
    local before; before="$(git rev-parse HEAD)"
    migration "$WORK/m" $'comment-density\tcomment-ratio\trepo\tNEW\nformat\tformat-files\tdiff\tNEW\n-\tdart-tools-changed\tnew\tNEW\ncomplexity\tcomplexity\trepo\tSAME\n'
    run bash "$WORK/m/apply.sh" "$WORK/app"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    cmp "$WORK/m/checks.tsv" quality/checks.tsv && cmp "$WORK/m/config" quality/config
    cmp "$M/commit-lint.sh" quality/bin/commit-lint.sh && [ -x quality/bin/commit-lint.sh ]
    [ "$(git rev-parse HEAD)" = "$before" ]
    [[ "$output" == *'qg baseline --only comment-ratio'$'\n'* ]]
    [[ "$output" != *'dart-tools-changed'*'qg baseline'* ]]
    [[ "$output" != *'baseline --only'*'format-files'* ]]
    [[ "$output" == *'qg override --reason'* ]]
}

@test "apply.sh refuses an agent outside /tmp, a missing or unproven parity table, and an SDK that is not there" {
    v1_mobile "$WORK/app"
    migration "$WORK/m" $'complexity\tcomplexity\trepo\tDIFF\n'
    run bash "$WORK/m/apply.sh" "$WORK/app"
    [ "$status" -eq 2 ]
    [[ "$output" == *'not proven: complexity=DIFF'* ]]
    rm "$WORK/m/parity.tsv"
    run bash "$WORK/m/apply.sh" "$WORK/app"
    [ "$status" -eq 2 ]
    [[ "$output" == *'parity.tsv is missing'* ]]
    migration "$WORK/m" $'complexity\tcomplexity\trepo\tSAME\n'
    sed -i 's#^guard_flutter_root:.*#guard_flutter_root: /nonexistent/sdk#' "$WORK/m/config"
    run bash "$WORK/m/apply.sh" "$WORK/app"
    [ "$status" -eq 2 ]
    [[ "$output" == *'not a Flutter SDK'* ]]
    [ "$(git status --porcelain)" = '' ]
    [ -w /dev/shm ] || skip 'no writable folder outside /tmp in this container'
    v1_mobile /dev/shm/qg-apply-$$
    migration "$WORK/m2" $'complexity\tcomplexity\trepo\tSAME\n'
    CLAUDECODE=1 run bash "$WORK/m2/apply.sh" /dev/shm/qg-apply-$$
    rm -rf /dev/shm/qg-apply-$$
    [ "$status" -eq 2 ]
    [[ "$output" == *'agents may not apply'* ]]
}
