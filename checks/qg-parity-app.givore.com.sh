#!/usr/bin/env bash
# SC-5 — row parity of app.givore.com's v2 gate rows with its v1 rows, then every v2 row measured on
# origin/master and origin/development merged with the migrated release branch.
#
#   checks/qg-parity-app.givore.com.sh [<app.givore.com checkout>]   default ~/workspace/app.givore.com
#
# Builds two `git clone --shared` scratch clones of the checkout's HEAD with no hooks: `old` keeps the
# committed v1 quality/, `new` carries migrations/app.givore.com/ and migrations/web/in-node.sh,
# committed. Each clone runs its own `pnpm install --frozen-lockfile --offline` (nuxt prepare runs as
# postinstall); the checkout's node_modules and .nuxt are never copied or linked. Each clone's
# node_modules/.bin/vitest and stryker are replaced by shims that write seeded reports instead of
# running the suite. Each clone is measured in three states:
#
#   clean   a neutral staged file: the value a row reads with no violation
#   seed1   one violation set per row: the commit rows judge it staged, the push rows judge it
#           committed, the baseline rows judge the shims' seeded reports
#   seed2   the same with two violation sets, so a count is told from a 0/1 reading
#
# Order: old clean, old seed1 (exit 2 naming every row the seed did not move), old seed2, new clean,
# new seed1, new seed2. The old engine is ~/workspace/vault-quality-gates (QG_PARITY_OLD_ENGINE), the
# new one this repo. Each engine run times out after QG_PARITY_TIMEOUT seconds (default 3600).
#
# Writes migrations/app.givore.com/parity.tsv (columns: id, new-id, kind, verdict, old-clean,
# old-seed1, old-seed2, new-clean, new-seed1, new-seed2; each value is `value/status`). Verdicts: SAME
# (a kept id reading the same value and status on both sides at seed1 and seed2), DIFF (a kept id
# that does not), NEW (a renamed or added row whose new seeds are numbers, seed1 differs from clean
# and seed2 from seed1), VACUOUS (a seed that did not move its value, or a side that did not measure).
#
# Then, in the new clone, fetches the checkout's origin/master and origin/development, merges the new
# side's release commit into each on a scratch branch (a conflict outside quality/, VAULT.md and the
# protected paths takes the branch's side; one inside them exits 2), reinstalls when the merged
# pnpm-lock.yaml differs, measures every v2 row and writes migrations/app.givore.com/branches.tsv
# (columns: branch branch-sha release-sha merge-sha conflicts id value status release-baseline).
#
# Exit 0 every kept id SAME and every renamed or added row NEW, every branch row measured · 1 a kept
# id is DIFF · 2 a row is VACUOUS or unmeasured, a run timed out, a merge conflicted in a gate path,
# the clones could not be built, or the run changed the live checkout.
set -uo pipefail
export LC_ALL=C
# No tool this script starts may read the caller's stdin: gate.sh feeds its remaining criteria there.
exec < /dev/null

NEW_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
OLD_ROOT="${QG_PARITY_OLD_ENGINE:-$HOME/workspace/vault-quality-gates}"
LIVE="$(cd "${1:-$HOME/workspace/app.givore.com}" && pwd)" || { echo "parity: no checkout ${1:-}"; exit 2; }
REPO=app.givore.com
MIG="${NEW_ROOT}/migrations/${REPO}"
REF=refs/heads/release/qg-parity
RENAMED='gate-config-touched=protected-paths-touched tests-suite=tests-suite-failed duplication-new=duplication-added'
ADDED='tools-changed'
BRANCHES='master development'
STEP_TIMEOUT="${QG_PARITY_TIMEOUT:-3600}"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/qg-parity-app.XXXXXX")" || exit 2
LOG="${WORK}/parity.log"
say() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$LOG" >&2; }

# --- the live checkout stays untouched ---------------------------------------------------------

live_status() { git -C "$LIVE" --no-optional-locks status --porcelain 2>&1; }
live_status > "$WORK/live.before"
# A file of the live node_modules or .nuxt newer than this marker at the end means the run wrote into it.
touch "$WORK/live.marker"
live_changed() {
    live_status > "$WORK/live.after"
    cmp -s "$WORK/live.before" "$WORK/live.after" || { say "the live checkout's git status changed: $(diff "$WORK/live.before" "$WORK/live.after" | head -5 | tr '\n' ' ')"; return 0; }
    local touched; touched="$(find "$LIVE/node_modules" "$LIVE/.nuxt" -newer "$WORK/live.marker" -print -quit 2>/dev/null)"
    [ -z "$touched" ] || { say "the run wrote into the live checkout: ${touched}"; return 0; }
    return 1
}
die() { say "CANNOT RUN: $*"; live_changed; echo "parity: cannot run: $* (log ${LOG})"; exit 2; }

# --- the clones --------------------------------------------------------------------------------

BASE="$(git -C "$LIVE" rev-parse HEAD)" || die "cannot read HEAD of ${LIVE}"
for f in quality-reports/junit.xml coverage/clover.xml reports/mutation/mutation.json; do
    [ -s "$LIVE/$f" ] || die "${LIVE}/$f is missing: the shims are seeded from the checkout's last suite and mutation reports"
done
say "base ${BASE:0:12} of ${LIVE}; work ${WORK}"

# install <clone> — the clone's own node_modules and .nuxt, then the suite shims.
install() {
    local d="$1"
    say "$(basename "$d"): pnpm install --frozen-lockfile --offline"
    ( cd "$d" && timeout "$STEP_TIMEOUT" pnpm install --frozen-lockfile --offline ) >> "$LOG" 2>&1 \
        || die "pnpm install --frozen-lockfile --offline failed in ${d}"
    for f in eslint.config.mjs tsconfig.app.json; do
        [ -f "$d/.nuxt/$f" ] || die "nuxt prepare left no .nuxt/$f in ${d}"
    done
    rm -f "$d/node_modules/.bin/vitest" "$d/node_modules/.bin/stryker"
    cp "$WORK/shim/vitest" "$WORK/shim/stryker" "$d/node_modules/.bin/" || die "cannot install the shims in ${d}"
}

for side in old new; do
    git clone -q --shared --no-checkout "$LIVE" "$WORK/$side" || die "cannot clone into $side"
    git -C "$WORK/$side" checkout -q --detach "$BASE" || die "cannot check out ${BASE} in $side"
    git -C "$WORK/$side" config user.email parity@example.invalid
    git -C "$WORK/$side" config user.name parity
    git -C "$WORK/$side" config core.hooksPath /dev/null
done

# old: the committed v1 quality/ as it is.
# shellcheck disable=SC2034  # read through ${!fixture} in measure
FIXTURE_old="$BASE"

# new: the prepared v2 files.
for f in checks.tsv config jscpd.json README.md; do cp "$MIG/$f" "$WORK/new/quality/$f" || die "cannot copy $f"; done
# The table reads the files this run measured, even if migrations/ changes while it runs.
cp "$MIG/checks.tsv" "$WORK/v2.tsv" && cp "$MIG/config" "$WORK/v2.config" || die "cannot copy the v2 files"
cp "$NEW_ROOT/migrations/web/in-node.sh" "$WORK/new/quality/bin/in-node.sh" && chmod +x "$WORK/new/quality/bin/in-node.sh"
git -C "$WORK/new" add quality && git -C "$WORK/new" commit -qm 'parity: v2 rows' || die 'cannot commit the new fixture'
FIXTURE_new="$(git -C "$WORK/new" rev-parse HEAD)"

# --- the suite shims ---------------------------------------------------------------------------

# The base reports: the checkout's last whole-suite and mutation runs, with zero failures.
sed '0,/failures="[0-9]*"/s//failures="0"/; 0,/errors="[0-9]*"/s//errors="0"/' "$LIVE/quality-reports/junit.xml" > "$WORK/junit.base.xml" \
    || die "${LIVE}/quality-reports/junit.xml is unreadable"
cp "$LIVE/coverage/clover.xml" "$WORK/clover.base.xml" || die "${LIVE}/coverage/clover.xml is unreadable"
# mutation.<n>.json: 20 x n killed mutants survive.
for n in 0 1 2; do
    jq --argjson k "$((20 * n))" '
        . as $r
        | [$r.files | to_entries[] | .key as $f | .value.mutants | to_entries[] | select(.value.status == "Killed") | [$f, .key]][:$k] as $flip
        | reduce $flip[] as $x ($r; .files[$x[0]].mutants[$x[1]].status = "Survived")' \
        "$LIVE/reports/mutation/mutation.json" > "$WORK/mutation.$n.json" || die 'cannot seed the mutation report'
done

mkdir -p "$WORK/shim"
# State 0: every test passes. State 1: every test passes and a coverage threshold is missed, so
# vitest exits 1 with zero failures. State n > 1: n tests fail.
cat > "$WORK/shim/vitest" <<SHIM
#!/usr/bin/env bash
# Parity shim: writes the seeded whole-suite reports instead of running vitest.
n="\$(cat "$WORK/state" 2>/dev/null || echo 0)"
junit=quality-reports/junit.xml
for a in "\$@"; do case "\$a" in --outputFile.junit=*) junit="\${a#*=}" ;; esac; done
mkdir -p "\$(dirname "\$junit")" coverage
case "\$n" in 0) f=0 rc=0 ;; 1) f=0 rc=1 ;; *) f="\$n" rc=1 ;; esac
sed "0,/failures=\"[0-9]*\"/s//failures=\"\$f\"/" "$WORK/junit.base.xml" > "\$junit"
cp "$WORK/clover.base.xml" coverage/clover.xml
[ "\$n" != 1 ] || echo 'ERROR: Coverage for lines (35.8%) does not meet global threshold (90%)' >&2
exit "\$rc"
SHIM
cat > "$WORK/shim/stryker" <<SHIM
#!/usr/bin/env bash
# Parity shim: writes the seeded mutation report instead of running stryker.
n="\$(cat "$WORK/state" 2>/dev/null || echo 0)"
mkdir -p reports/mutation
cp "$WORK/mutation.\$n.json" reports/mutation/mutation.json
SHIM
chmod +x "$WORK/shim/vitest" "$WORK/shim/stryker"

install "$WORK/old"
install "$WORK/new"

# --- the seeds ---------------------------------------------------------------------------------
# Each seed_<row> writes violation <k> into the clone $d; seed calls each for k = 1..n.

# lint-new: one no-explicit-any warning on an added line.
seed_lint_new() {
    printf 'export function qgParityLint%s(value: any): unknown {\n  return value;\n}\n' "$k" > "$d/utils/qgParityLint$k.ts"
}
# lint-errors: one prefer-const error.
seed_lint_errors() {
    printf 'export function qgParityConst%s(): number {\n  let total = %s;\n  return total;\n}\n' "$k" "$k" > "$d/utils/qgParityConst$k.ts"
}
# mess, complexity-excess: one function over the complexity, cognitive-complexity and max-depth limits.
seed_mess() {
    {
        printf 'export function qgParityBranchy%s(a: number, b: number, c: number): number {\n  let total = 0;\n' "$k"
        printf '  if (a > 1) {\n    if (b > 1) {\n      if (c > 1) {\n        if (a > b) {\n          if (b > c) {\n            total += 1;\n          }\n        }\n      }\n    }\n  }\n'
        for i in $(seq 1 20); do printf '  if (a === %s || b === %s) {\n    total += %s;\n  }\n' "$i" "$i" "$i"; done
        printf '  return total;\n}\n'
    } > "$d/utils/qgParityBranchy$k.ts"
}
# typecheck-new, typecheck-errors: one TS2322 in a layout.
seed_typecheck() {
    printf '<template>\n  <div>{{ count }}</div>\n</template>\n\n<script setup lang="ts">\nconst count: number = %s;\n</script>\n' "\"qg parity $k\"" > "$d/layouts/qg-parity-$k.vue"
}
# duplication-added (v1 duplication-new), duplication, duplication-clones, dupes-semantic: a renamed copy of a composable.
seed_duplication() {
    sed "s/useReport\b/useQgParityCopy$k/" "$d/composables/useReport.ts" > "$d/composables/useQgParityCopy$k.ts"
}
# suppressions-added: one eslint-disable comment.
seed_suppressions() {
    printf '// eslint-disable-next-line @typescript-eslint/no-explicit-any\nexport type QgParityLoose%s = any;\n' "$k" > "$d/utils/qgParitySuppress$k.ts"
}
# architecture, boundaries: utils/ imports a composable (depcruise utils-are-leaf, fallow zone utils).
seed_architecture() {
    printf "import { useToast } from '../composables/useToast';\n\nexport function qgParityArch%s(): unknown {\n  return useToast();\n}\n" "$k" > "$d/utils/qgParityArch$k.ts"
}
# boundaries: utils/ calls an auto-imported composable.
seed_boundaries() {
    printf 'export function qgParityZone%s(): unknown {\n  return useToast();\n}\n' "$k" > "$d/utils/qgParityZone$k.ts"
}
# deadcode: one file nothing imports.
seed_deadcode() {
    mkdir -p "$d/api/qgParity"
    printf 'export function qgParityDead%s(): number {\n  return %s;\n}\n' "$k" "$k" > "$d/api/qgParity/dead$k.ts"
}
# repo-consistency: one *_ENABLED flag nuxt.config.ts reads and .env.example does not declare.
seed_consistency() {
    printf '\n// process.env.QG_PARITY_%s_ENABLED is declared nowhere.\n' "$k" >> "$d/nuxt.config.ts"
}
# gate-config-touched, protected-paths-touched: a file both configs protect; the second violation is a
# file only v2 protects.
seed_protected() {
    if [ "$k" -eq 1 ]; then printf '// qg parity\n' >> "$d/.dependency-cruiser.cjs"; else printf '// qg parity\n' >> "$d/vitest.config.ts"; fi
}
# tools-changed: one devDependency's locked version bumped, staged only (unseed_tools takes it back
# before the push commit, so the push rows run on the installed tools).
seed_tools() {
    case "$k" in
        1) sed -i -e 's/fast-check@4\.9\.0/fast-check@4.9.1/g' -e '/^      fast-check:$/,+2 s/4\.9\.0/4.9.1/' "$d/pnpm-lock.yaml" ;;
        *) sed -i -e 's/prettier@3\.8\.4/prettier@3.8.5/g' -e '/^      prettier:$/,+2 s/3\.8\.4/3.8.5/' "$d/pnpm-lock.yaml" ;;
    esac
}
unseed_tools() { git -C "$d" checkout -q "$1" -- pnpm-lock.yaml; }
# tests-failing, coverage, coverage-age-days: the reports the push rows read (reports below);
# tests-suite, tests-suite-failed, mutation: the shims, through $WORK/state.

# seed <clone> <n> — n violations of every row, written into the clone's working tree.
seed() {
    local d="$1" n="$2" k
    for k in $(seq 1 "$n"); do
        seed_lint_new; seed_lint_errors; seed_mess; seed_typecheck; seed_duplication; seed_suppressions
        seed_architecture; seed_boundaries; seed_deadcode; seed_consistency; seed_protected; seed_tools
    done
}

# reports <clone> <n> — the whole-suite reports the push rows read, n steps worse than the base.
reports() {
    local d="$1" n="$2"
    mkdir -p "$d/quality-reports" "$d/coverage"
    sed "0,/failures=\"[0-9]*\"/s//failures=\"$n\"/" "$WORK/junit.base.xml" > "$d/quality-reports/junit.xml"
    # The project totals are the first <metrics> element, before every file's own.
    awk -v n="$n" '!done && /<metrics / { match($0, /coveredstatements="[0-9]+"/); v = substr($0, RSTART + 19, RLENGTH - 20) - 100 * n
               sub(/coveredstatements="[0-9]+"/, "coveredstatements=\"" v "\""); done = 1 } { print }' "$WORK/clover.base.xml" > "$d/coverage/clover.xml"
    if [ "$n" -gt 0 ]; then touch -d "-$((10 * n)) days" "$d/coverage/clover.xml"; else touch "$d/coverage/clover.xml"; fi
}

# --- the runs ----------------------------------------------------------------------------------

results_file() { printf '%s/qg-last/RESULTS.txt' "$(git -C "$1" rev-parse --path-format=absolute --git-common-dir)"; }
# results <clone> <label> [<id regex>] -> "<label> <id> <value> <status>" per measured row.
results() {
    awk -F'|' -v s="$2" -v only="${3:-.}" '$4 != "skipped" && $1 ~ only { print s " " $1 " " $2 " " $4 }' "$(results_file "$1")" 2>/dev/null
}
engine_of() { if [ "$1" = old ]; then printf '%s/bin/guard.sh' "$OLD_ROOT"; else printf '%s/bin/guard.sh' "$NEW_ROOT"; fi; }

# run_commit <side> <label> <out> — the commit rows on what is staged.
run_commit() {
    local d="$WORK/$1" rc=0
    say "$1 $2: commit rows"
    rm -f "$(results_file "$d")"
    ( cd "$d" && GUARD_LOCK_WAIT=600 timeout "$STEP_TIMEOUT" bash "$(engine_of "$1")" commit ) >> "$LOG" 2>&1 || rc=$?
    [ "$rc" -eq 124 ] && die "$1 $2: the commit gate ran longer than ${STEP_TIMEOUT}s"
    results "$d" "$2" >> "$3"
}
# run_push <side> <label> <out> — the push rows on HEAD.
run_push() {
    local d="$WORK/$1" rc=0
    say "$1 $2: push rows"
    rm -f "$(results_file "$d")"
    ( cd "$d" && GUARD_SHA="$(git rev-parse HEAD)" timeout "$STEP_TIMEOUT" bash "$(engine_of "$1")" release "$REF" ) >> "$LOG" 2>&1 || rc=$?
    [ "$rc" -eq 124 ] && die "$1 $2: the push gate ran longer than ${STEP_TIMEOUT}s"
    results "$d" "$2" >> "$3"
}
# run_baseline <side> <label> <out> — the whole-suite rows through the shims.
run_baseline() {
    local d="$WORK/$1" rc=0 only
    say "$1 $2: baseline rows"
    rm -f "$(results_file "$d")"
    # shellcheck disable=SC2054  # one comma-separated id list
    if [ "$1" = new ]; then only=(--only mutation,tests-suite-failed)
    else only=(--skip "^($(awk -F'\t' 'NR > 1 && $0 !~ /^#/ && $1 !~ /^(mutation|tests-suite)$/ { printf "%s%s", s, $1; s = "|" }' "$d/quality/checks.tsv"))\$"); fi
    ( cd "$d" && timeout "$STEP_TIMEOUT" bash "$(engine_of "$1")" baseline "${only[@]}" ) >> "$LOG" 2>&1 || rc=$?
    [ "$rc" -eq 124 ] && die "$1 $2: the baseline run took longer than ${STEP_TIMEOUT}s"
    results "$d" "$2" '^(mutation|tests-suite|tests-suite-failed)$' >> "$3"
    git -C "$d" checkout -q -- quality/baseline.tsv 2>/dev/null
}

# measure <side> <state name> <n> — appends "<state> <id> <value> <status>" to $WORK/<side>.results.
measure() {
    local side="$1" state="$2" n="$3" d="$WORK/$1" out="$WORK/$1.results"
    local fixture="FIXTURE_$side"
    git -C "$d" reset -q --hard "${!fixture}" && git -C "$d" clean -qfd
    printf '%s\n' "$n" > "$WORK/state"
    if [ "$n" -eq 0 ]; then printf 'parity\n' > "$d/test/qg-parity-clean.txt"; else seed "$d" "$n"; fi
    git -C "$d" add -A
    run_commit "$side" "$state" "$out"
    unseed_tools "${!fixture}"
    git -C "$d" add -A
    git -C "$d" commit -qm "parity: ${state}" || die "$side $state: cannot commit the seeds"
    reports "$d" "$n"
    run_push "$side" "$state" "$out"
    run_baseline "$side" "$state" "$out"
}

value() { awk -v s="$2" -v id="$3" '$1 == s && $2 == id { v = $3 "/" $4 } END { print (v == "" ? "-" : v) }' "$WORK/$1.results"; }
num() { [[ "${1%%/*}" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; }
# same <a> <b> -> status 0 when both values are equal numbers with the same status.
same() { [ "${1#*/}" = "${2#*/}" ] && awk -v a="${1%%/*}" -v b="${2%%/*}" 'BEGIN { exit !(a + 0 == b + 0) }'; }
v1_ids() { awk -F'\t' 'NR > 1 && $0 !~ /^#/ { print $1 }' "$WORK/old/quality/checks.tsv"; }
new_id() { local r; for r in $RENAMED; do [ "${r%%=*}" = "$1" ] && { printf '%s' "${r#*=}"; return; }; done; printf '%s' "$1"; }

measure old clean 0
measure old seed1 1
unmoved=''
for id in $(v1_ids); do
    # A renamed row is proven on the new side: v1 duplication-new reads 0 on every commit.
    [ "$(new_id "$id")" = "$id" ] || continue
    oc="$(value old clean "$id")" o1="$(value old seed1 "$id")"
    if ! num "$oc" || ! num "$o1" || same "$oc" "$o1"; then unmoved+=" ${id}(${oc} -> ${o1})"; fi
done
[ -z "$unmoved" ] || die "old seed1 did not move or measure:${unmoved}"
measure old seed2 2
measure new clean 0
measure new seed1 1
measure new seed2 2

# --- the parity table --------------------------------------------------------------------------

count_kind() { awk -F'\t' -v id="$1" 'NR > 1 && $1 == id { print $3 }' "$WORK/v2.tsv"; }
table="$MIG/parity.tsv"
printf 'id\tnew-id\tkind\tverdict\told-clean\told-seed1\told-seed2\tnew-clean\tnew-seed1\tnew-seed2\n' > "$table"
worst=0
for id in $(v1_ids) $ADDED; do
    nid="$(new_id "$id")"
    if [[ " $ADDED " == *" $id "* ]]; then oid='-' oc='-' o1='-' o2='-'
    else oid="$id" oc="$(value old clean "$id")" o1="$(value old seed1 "$id")" o2="$(value old seed2 "$id")"; fi
    nc="$(value new clean "$nid")" n1="$(value new seed1 "$nid")" n2="$(value new seed2 "$nid")"
    moved=1
    { num "$nc" && num "$n1" && num "$n2" && ! same "$nc" "$n1" && ! same "$n1" "$n2"; } || moved=0
    if [ "$nid" != "$oid" ]; then
        if [ "$moved" -eq 1 ]; then verdict=NEW; else verdict=VACUOUS; fi
    elif [ "$moved" -eq 0 ] || ! num "$oc" || ! num "$o1" || ! num "$o2" || same "$oc" "$o1" || same "$o1" "$o2"; then verdict=VACUOUS
    elif same "$o1" "$n1" && same "$o2" "$n2"; then verdict=SAME
    else verdict=DIFF; fi
    case "$verdict" in VACUOUS) worst=2 ;; DIFF) [ "$worst" -lt 1 ] && worst=1 ;; esac
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$oid" "$nid" "$(count_kind "$nid")" "$verdict" "$oc" "$o1" "$o2" "$nc" "$n1" "$n2" >> "$table"
done
column -t -s $'\t' "$table" >> "$LOG" 2>/dev/null || cat "$table" >> "$LOG"
say "parity table: ${table}"

# --- the branch merges -------------------------------------------------------------------------

d="$WORK/new"
protected="$(sed -n 's/^guard_protected_paths:[[:space:]]*//p' "$WORK/v2.config" | head -1)"
# gate_path <path> -> status 0 when a conflict there must not be resolved by a side.
gate_path() {
    local p
    case "$1" in quality/*|VAULT.md) return 0 ;; esac
    for p in $protected; do [ "$1" = "$p" ] || [[ "$1" == "$p"/* ]] && return 0; done
    return 1
}
git -C "$d" show "$FIXTURE_new:quality/baseline.tsv" > "$WORK/release-baseline.tsv" 2>/dev/null || : > "$WORK/release-baseline.tsv"
bout="$WORK/branches.results"
: > "$bout"
declare -A BRANCH_SHA MERGE_SHA CONFLICTS
for branch in $BRANCHES; do
    bsha="$(git -C "$LIVE" rev-parse --verify -q "refs/remotes/origin/$branch")" || die "${LIVE} has no origin/${branch}"
    git -C "$d" fetch -q "$LIVE" "+refs/remotes/origin/$branch:refs/remotes/live/$branch" || die "cannot fetch origin/${branch} from ${LIVE}"
    git -C "$d" reset -q --hard && git -C "$d" clean -qfd
    git -C "$d" checkout -q -B "qg-parity-$branch" "$bsha" || die "cannot check out origin/${branch}"
    conflicts=''
    if ! git -C "$d" merge -q --no-ff --no-edit -m "parity: merge the v2 release into ${branch}" "$FIXTURE_new" >> "$LOG" 2>&1; then
        mapfile -t paths < <(git -C "$d" diff --name-only --diff-filter=U)
        [ "${#paths[@]}" -gt 0 ] || die "merging the release into ${branch} failed without a conflict"
        for p in "${paths[@]}"; do
            gate_path "$p" && die "merging the release into ${branch} conflicts in the gate path ${p}"
            # The branch's own side; a path the branch deleted stays deleted.
            if git -C "$d" cat-file -e "HEAD:$p" 2>/dev/null; then git -C "$d" checkout -q --ours -- "$p" && git -C "$d" add -- "$p"
            else git -C "$d" rm -q -- "$p"; fi || die "cannot resolve ${p} on ${branch}"
            conflicts+="${conflicts:+,}$p"
        done
        git -C "$d" commit -q --no-edit || die "cannot commit the merge into ${branch}"
    fi
    BRANCH_SHA[$branch]="$bsha" MERGE_SHA[$branch]="$(git -C "$d" rev-parse HEAD)" CONFLICTS[$branch]="${conflicts:--}"
    say "merge ${branch}: ${bsha:0:12} + ${FIXTURE_new:0:12} -> ${MERGE_SHA[$branch]:0:12}, conflicts ${CONFLICTS[$branch]}"
    if ! git -C "$d" diff --quiet "$FIXTURE_new" HEAD -- pnpm-lock.yaml; then install "$d"; fi

    printf '0\n' > "$WORK/state"
    printf 'parity\n' > "$d/test/qg-parity-clean.txt"
    git -C "$d" add -A
    run_commit new "$branch" "$bout"
    git -C "$d" reset -q && rm -f "$d/test/qg-parity-clean.txt"
    reports "$d" 0
    run_push new "$branch" "$bout"
    run_baseline new "$branch" "$bout"
done

btable="$MIG/branches.tsv"
printf 'branch\tbranch-sha\trelease-sha\tmerge-sha\tconflicts\tid\tvalue\tstatus\trelease-baseline\n' > "$btable"
for branch in $BRANCHES; do
    for id in $(awk -F'\t' 'NR > 1 && $0 !~ /^#/ && $3 != "absent" { print $1 }' "$WORK/v2.tsv"); do
        v="$(awk -v s="$branch" -v id="$id" '$1 == s && $2 == id { v = $3; st = $4 } END { print (v == "" ? "-" : v) "\t" (st == "" ? "-" : st) }' "$bout")"
        base="$(awk -F'\t' -v id="$id" '$1 == id { b = $2 } END { print (b == "" ? "-" : b) }' "$WORK/release-baseline.tsv")"
        num "${v%%$'\t'*}" || { say "${branch}: ${id} was not measured (${v//$'\t'/ })"; worst=2; }
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$branch" "${BRANCH_SHA[$branch]}" "$FIXTURE_new" "${MERGE_SHA[$branch]}" "${CONFLICTS[$branch]}" "$id" "$v" "$base" >> "$btable"
    done
done
column -t -s $'\t' "$btable" >> "$LOG" 2>/dev/null || cat "$btable" >> "$LOG"
say "branch table: ${btable}"

if live_changed; then worst=2; fi
case "$worst" in
    0) echo "parity: every kept id SAME, every renamed or added row NEW, every v2 row measured on ${BRANCHES// /, } (log ${LOG})" ;;
    1) echo "parity: a kept id differs; see ${table} (log ${LOG})" ;;
    *) echo "parity: a row was vacuous or unmeasured, or the live checkout changed; see ${table} and ${btable} (log ${LOG})" ;;
esac
exit "$worst"
