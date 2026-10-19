#!/usr/bin/env bash
# SC-6 — row parity of dashboard.givore.com's v2 gate rows with its v1 rows, and every v2 row
# measured on origin/master and origin/development merged with the migrated release branch.
#
#   checks/qg-parity-dashboard.givore.com.sh [<dashboard.givore.com checkout>]
#                                             default ~/workspace/dashboard.givore.com
#
# Builds two `git clone --shared` scratch clones of the checkout's HEAD with no hooks. `old` keeps
# the committed v1 quality/; `new` gets migrations/dashboard.givore.com/ and migrations/web/in-node.sh
# in one commit. Each clone runs its own `pnpm install --frozen-lockfile --offline`, which runs
# `nuxt prepare` there. Of the checkout this reads only its HEAD, its origin refs and its last
# quality-reports/junit.xml and coverage/clover.xml; it writes nothing into it.
#
# States, each measured on the commit rows (seeds staged), the push rows (seeds committed) and the
# baseline row (a vitest shim writes seeded reports instead of running the suite):
#
#   clean   a neutral staged file: the value a row reads with no violation
#   seed1   one violation per row; the suite has every test green but misses a coverage threshold
#   seed2   twice the violations; the suite has two failing tests
#
# Order: old clean, old seed1 — every v1 row must have moved, else exit 2 naming the rows — then old
# seed2, new clean, new seed1, new seed2.
#
# Writes migrations/dashboard.givore.com/parity.tsv (columns: id new-id kind verdict old-clean
# old-seed1 old-seed2 new-clean new-seed1 new-seed2; a cell is value/status) and prints it.
# Verdicts: SAME (a kept id reads the same value and status on both sides at seed1 and seed2), DIFF
# (a kept id that does not), NEW (a renamed or new row whose new seeds are numbers, differ from new
# clean and from each other), VACUOUS (a seed equal to its clean value or to the other seed, or an
# unmeasured side).
#
# Then merges the new clone's release commit into origin/master and origin/development, fetched from
# the checkout's own origin refs. A conflict outside quality/, VAULT.md and the protected paths
# resolves to the branch side; one inside them exits 2. Measures every v2 row on each merge and writes
# migrations/dashboard.givore.com/branches.tsv (columns: branch branch-sha release-sha merge-sha
# conflicts id value status release-baseline). tests-failing, coverage and coverage-age-days read the
# checkout's last suite reports there, and tests-suite-failed reads the shim's green report.
#
# Exit 0 every kept id SAME and every other row NEW, every branch row measured · 1 a kept id DIFF ·
# 2 a row VACUOUS or unmeasured, a step timed out (QG_PARITY_TIMEOUT, default 3600 s), a clone or
# install failed, a merge conflicted inside a gated path, or the run changed the live checkout.
set -uo pipefail
export LC_ALL=C
# No tool this script starts may read the caller's stdin: gate.sh feeds its remaining criteria there.
exec < /dev/null

NEW_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
OLD_ROOT="${QG_PARITY_OLD_ENGINE:-$HOME/workspace/vault-quality-gates}"
LIVE="$(cd "${1:-$HOME/workspace/dashboard.givore.com}" && pwd)" || { echo "parity: no checkout ${1:-}"; exit 2; }
MIG="${NEW_ROOT}/migrations/dashboard.givore.com"
REF=refs/heads/release/qg-parity
RENAMED='gate-config-touched=protected-paths-touched tests-suite=tests-suite-failed'
BRANCHES='master development'
STEP_TIMEOUT="${QG_PARITY_TIMEOUT:-3600}"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/qg-parity-dashboard.XXXXXX")" || exit 2
LOG="${WORK}/parity.log"
trap 'echo "parity: work dir ${WORK} (log ${LOG})" >&2' EXIT
say() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$LOG" >&2; }
die() { say "CANNOT RUN: $*"; exit 2; }
START="$(date +%s)"

# --- the clones --------------------------------------------------------------------------------

BASE="$(git -C "$LIVE" rev-parse HEAD)" || die "cannot read HEAD of ${LIVE}"
LIVE_STATUS="$(git -C "$LIVE" status --porcelain)" || die "cannot read the status of ${LIVE}"
for f in quality-reports/junit.xml coverage/clover.xml; do
    [ -s "$LIVE/$f" ] || die "${LIVE}/${f} is missing; the shim seeds from the checkout's last suite run"
done
say "base ${BASE:0:12} of ${LIVE}; work ${WORK}"
# Any file of the live node_modules or .nuxt newer than this marker at the end means the run wrote there.
touch "$WORK/live.marker"

# clone_install <clone> — the clone's own install; its postinstall runs `nuxt prepare` in the clone.
# Then the vitest and stryker bins become the shim, so no step runs the real suite.
clone_install() {
    ( cd "$1" && timeout "$STEP_TIMEOUT" pnpm install --frozen-lockfile --offline ) >> "$LOG" 2>&1 || die "pnpm install --frozen-lockfile --offline failed in $1"
    rm -f "$1/node_modules/.bin/vitest" "$1/node_modules/.bin/stryker"
    cp "$WORK/shim/vitest" "$1/node_modules/.bin/vitest" && cp "$WORK/shim/vitest" "$1/node_modules/.bin/stryker" \
        || die "cannot install the shim in $1"
}

# --- the vitest shim ---------------------------------------------------------------------------

# The base reports: the checkout's last whole-suite run, with zero failures.
sed '0,/failures="[0-9]*"/s//failures="0"/; 0,/errors="[0-9]*"/s//errors="0"/' "$LIVE/quality-reports/junit.xml" > "$WORK/junit.base.xml" \
    || die "${LIVE}/quality-reports/junit.xml is unreadable"
cp "$LIVE/coverage/clover.xml" "$WORK/clover.base.xml" || die "${LIVE}/coverage/clover.xml is unreadable"
mkdir -p "$WORK/shim"
# $WORK/suite holds "<failures> <exit code>" for the next suite run.
cat > "$WORK/shim/vitest" <<SHIM
#!/usr/bin/env bash
# qg parity shim: writes the seeded suite reports into the current folder instead of running vitest.
read -r failures code < "$WORK/suite" || exit 2
mkdir -p quality-reports coverage
sed "0,/failures=\"[0-9]*\"/s//failures=\"\$failures\"/" "$WORK/junit.base.xml" > quality-reports/junit.xml
cp "$WORK/clover.base.xml" coverage/clover.xml
exit "\$code"
SHIM
chmod +x "$WORK/shim/vitest"

for side in old new; do
    git clone -q --shared --no-checkout "$LIVE" "$WORK/$side" || die "cannot clone into $side"
    git -C "$WORK/$side" checkout -q --detach "$BASE" || die "cannot check out ${BASE} in $side"
    git -C "$WORK/$side" config user.email parity@example.invalid
    git -C "$WORK/$side" config user.name parity
    git -C "$WORK/$side" config core.hooksPath /dev/null
done

# old: HEAD's committed v1 rows.
# shellcheck disable=SC2034  # read through ${!fixture} in measure
FIXTURE_old="$BASE"

# new: the prepared v2 files.
for f in checks.tsv config jscpd.json README.md; do cp "$MIG/$f" "$WORK/new/quality/$f" || die "cannot copy $f"; done
cp "$NEW_ROOT/migrations/web/in-node.sh" "$WORK/new/quality/bin/in-node.sh" && chmod +x "$WORK/new/quality/bin/in-node.sh"
git -C "$WORK/new" add quality && git -C "$WORK/new" commit -qm 'parity: v2 rows' || die 'cannot commit the new fixture'
# shellcheck disable=SC2034  # read through ${!fixture} in measure
FIXTURE_new="$(git -C "$WORK/new" rev-parse HEAD)"

for side in old new; do say "$side: pnpm install"; clone_install "$WORK/$side"; done

# --- the seeds ---------------------------------------------------------------------------------

# Every seed is valid TypeScript under app/qgParity/, a folder Nuxt does not auto-import, so a seed
# moves only the rows its comment names. Count rows get one file per violation: seed2 doubles them.

# lint-new, lint-errors: one @typescript-eslint/no-explicit-any error (severity 2).
seed_lint() {
    printf '// qg parity: one no-explicit-any error\nexport function qgParityLint%s(value: any): string {\n  return String(value)\n}\n' "$2" > "$1/app/qgParity/lint$2.ts"
}
# typecheck-new, typecheck-errors: one TS2322 error.
seed_type() {
    printf "// qg parity: one TS2322 error\nexport const qgParityType%s: number = 'qg parity'\n" "$2" > "$1/app/qgParity/type$2.ts"
}
# suppressions-added: one eslint-disable comment, over a line it really silences.
seed_suppress() {
    printf '// qg parity: one suppression\n// eslint-disable-next-line @typescript-eslint/no-explicit-any\nexport const qgParitySuppress%s = (value: any) => value\n' "$2" > "$1/app/qgParity/suppress$2.ts"
}
# duplication-new, duplication, duplication-clones: a whole copy of a clean app/utils module.
seed_copy() {
    cp "$1/app/utils/featureRequestStatus.ts" "$1/app/qgParity/copy$2.ts"
}
# gate-config-touched, protected-paths-touched: seed1 touches vitest.config.ts, which both configs
# protect; seed2 also adds .npmrc, which only v2 protects. Both edits are comments.
seed_protected() {
    printf '// qg parity\n' >> "$1/vitest.config.ts"
    [ "$2" -lt 2 ] || printf '# qg parity\n' > "$1/.npmrc"
}
# tools-changed: seed1 moves happy-dom 20.9.0 -> 20.9.1 in package.json and in every place of
# pnpm-lock.yaml; seed2 also openapi-typescript 7.13.0 -> 7.13.1. The lock stays well formed. The
# commit rows judge it staged; measure() puts HEAD's lock back before the push rows, whose runner
# refuses a lock that differs from the installed one.
seed_tools() {
    sed -i -e 's/happy-dom@20\.9\.0/happy-dom@20.9.1/g' -e '/^      happy-dom:$/,+2 s/20\.9\.0/20.9.1/' "$1/pnpm-lock.yaml"
    sed -i 's/"happy-dom": "^20\.9\.0"/"happy-dom": "^20.9.1"/' "$1/package.json"
    [ "$2" -lt 2 ] && return 0
    sed -i -e 's/openapi-typescript@7\.13\.0/openapi-typescript@7.13.1/g' -e '/^      openapi-typescript:$/,+2 s/7\.13\.0/7.13.1/' "$1/pnpm-lock.yaml"
    sed -i 's/"openapi-typescript": "^7\.13\.0"/"openapi-typescript": "^7.13.1"/' "$1/package.json"
}

# seed <clone> <n> — n violations of every row, written into the clone's working tree.
seed() {
    local d="$1" n="$2" i
    mkdir -p "$d/app/qgParity"
    for i in $(seq 1 "$n"); do
        seed_lint "$d" "$i"; seed_type "$d" "$i"; seed_suppress "$d" "$i"; seed_copy "$d" "$i"
    done
    seed_protected "$d" "$n"
    seed_tools "$d" "$n"
}

# reports <clone> <n> — the suite reports the push rows read, n steps worse than the base:
# tests-failing n failures, coverage 100·n fewer covered statements, coverage-age-days 10·n days.
reports() {
    local d="$1" n="$2"
    mkdir -p "$d/quality-reports" "$d/coverage"
    sed "0,/failures=\"[0-9]*\"/s//failures=\"$n\"/" "$WORK/junit.base.xml" > "$d/quality-reports/junit.xml"
    # The project totals are the first <metrics> element, inside <project>.
    awk -v n="$n" '!done && /<metrics / { match($0, /coveredstatements="[0-9]+"/); v = substr($0, RSTART + 19, RLENGTH - 20) - 100 * n
               sub(/coveredstatements="[0-9]+"/, "coveredstatements=\"" v "\""); done = 1 } { print }' "$WORK/clover.base.xml" > "$d/coverage/clover.xml"
    if [ "$n" -gt 0 ]; then touch -d "-$((10 * n)) days" "$d/coverage/clover.xml"; else touch "$d/coverage/clover.xml"; fi
}

# --- the runs ----------------------------------------------------------------------------------

results_file() { printf '%s/qg-last/RESULTS.txt' "$(git -C "$1" rev-parse --path-format=absolute --git-common-dir)"; }
results() { cat "$(results_file "$1")" 2>/dev/null; }

# gate <clone> <engine> <label> <guard args...> — one engine run under the step timeout; GATE_SHA,
# when set, pins the measured commit (GUARD_SHA).
gate() {
    local d="$1" engine="$2" label="$3" rc=0
    shift 3
    say "$label"
    rm -f "$(results_file "$d")"
    ( cd "$d" && { [ -z "${GATE_SHA:-}" ] || export GUARD_SHA="$GATE_SHA"; } && PATH="$WORK/shim:$PATH" GUARD_LOCK_WAIT=600 timeout "$STEP_TIMEOUT" bash "$engine" "$@" ) >> "$LOG" 2>&1 || rc=$?
    [ "$rc" -eq 124 ] && die "$label: the run took longer than ${STEP_TIMEOUT}s"
    return 0
}

# baseline_args <side> -> the baseline arguments that run only the suite row.
baseline_args() {
    if [ "$1" = new ]; then printf -- '--only\ntests-suite-failed\n'
    else printf -- '--skip\n^(%s)$\n' "$(awk -F'\t' 'NR > 1 && $0 !~ /^#/ && $1 != "tests-suite" { printf "%s%s", s, $1; s = "|" }' "$WORK/old/quality/checks.tsv")"; fi
}

# measure <side> <state name> <n> — commit rows on the staged seeds, push rows on the committed
# seeds, the baseline row on the shim's report; appends "<state> <id> <value> <status>" to the
# side's results file.
measure() {
    local side="$1" state="$2" n="$3" d="$WORK/$1" engine out="$WORK/$1.results" fixture="FIXTURE_$1"
    local -a bargs
    if [ "$side" = old ]; then engine="$OLD_ROOT/bin/guard.sh"; else engine="$NEW_ROOT/bin/guard.sh"; fi
    git -C "$d" reset -q --hard "${!fixture}" && git -C "$d" clean -qfd || die "$side $state: cannot reset the clone"
    if [ "$n" -eq 0 ]; then printf 'qg parity\n' > "$d/scripts/qg-parity-clean.txt"; else seed "$d" "$n"; fi
    git -C "$d" add -A

    gate "$d" "$engine" "$side $state: commit rows" commit
    results "$d" | awk -F'|' -v s="$state" '{ print s " " $1 " " $2 " " $4 }' >> "$out"

    git -C "$d" checkout -q HEAD -- pnpm-lock.yaml package.json
    git -C "$d" commit -qm "parity: ${state}" || die "$side $state: cannot commit the seeds"
    reports "$d" "$n"
    GATE_SHA="$(git -C "$d" rev-parse HEAD)" gate "$d" "$engine" "$side $state: push rows" release "$REF"
    results "$d" | awk -F'|' -v s="$state" '{ print s " " $1 " " $2 " " $4 }' >> "$out"

    case "$n" in 0) echo '0 0' ;; 1) echo '0 1' ;; *) echo "$n 1" ;; esac > "$WORK/suite"
    mapfile -t bargs < <(baseline_args "$side")
    gate "$d" "$engine" "$side $state: baseline row" baseline "${bargs[@]}"
    results "$d" | awk -F'|' -v s="$state" '$1 ~ /^tests-suite(-failed)?$/ { print s " " $1 " " $2 " " $4 }' >> "$out"
    git -C "$d" checkout -q -- quality/baseline.tsv 2>/dev/null
}

value() { awk -v s="$2" -v id="$3" '$1 == s && $2 == id { v = $3 "/" $4 } END { print (v == "" ? "-" : v) }' "$WORK/$1.results" 2>/dev/null || echo -; }
num() { [[ "${1%%/*}" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; }
moved() { num "$1" && num "$2" && [ "${1%%/*}" != "${2%%/*}" ]; }
v1_ids() { awk -F'\t' 'NR > 1 && $0 !~ /^#/ { print $1 }' "$WORK/old/quality/checks.tsv"; }
v2_ids() { awk -F'\t' 'NR > 1 && $0 !~ /^#/ && $3 != "absent" { print $1 }' "$MIG/checks.tsv"; }
new_id() { local r; for r in $RENAMED; do [ "${r%%=*}" = "$1" ] && { echo "${r#*=}"; return; }; done; echo "$1"; }
count_kind() { awk -F'\t' -v id="$1" '$1 == id { print $3 }' "$MIG/checks.tsv"; }

measure old clean 0
measure old seed1 1
unmoved=''
for id in $(v1_ids); do moved "$(value old clean "$id")" "$(value old seed1 "$id")" || unmoved+=" ${id}=$(value old clean "$id")->$(value old seed1 "$id")"; done
[ -z "$unmoved" ] || die "seed1 did not move these v1 rows:${unmoved}"
say "every v1 row moved at seed1"
measure old seed2 2
measure new clean 0
measure new seed1 1
measure new seed2 2

# --- the table ---------------------------------------------------------------------------------

table="$MIG/parity.tsv"
printf 'id\tnew-id\tkind\tverdict\told-clean\told-seed1\told-seed2\tnew-clean\tnew-seed1\tnew-seed2\n' > "$table"
worst=0
mapped=' '
row() {  # row <id> <new id> — one table line; raises worst
    local id="$1" nid="$2" oc=- o1=- o2=- nc n1 n2 verdict
    if [ "$id" != - ]; then oc="$(value old clean "$id")" o1="$(value old seed1 "$id")" o2="$(value old seed2 "$id")"; fi
    nc="$(value new clean "$nid")" n1="$(value new seed1 "$nid")" n2="$(value new seed2 "$nid")"
    if [ "$nid" != "$id" ]; then
        if moved "$nc" "$n1" && moved "$n1" "$n2"; then verdict=NEW; else verdict=VACUOUS; fi
    elif ! moved "$oc" "$o1" || ! moved "$o1" "$o2" || ! moved "$nc" "$n1" || ! moved "$n1" "$n2"; then verdict=VACUOUS
    elif [ "$o1" = "$n1" ] && [ "$o2" = "$n2" ]; then verdict=SAME
    else verdict=DIFF; fi
    case "$verdict" in VACUOUS) worst=2 ;; DIFF) [ "$worst" -lt 1 ] && worst=1 ;; esac
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$nid" "$(count_kind "$nid")" "$verdict" "$oc" "$o1" "$o2" "$nc" "$n1" "$n2" >> "$table"
}
for id in $(v1_ids); do nid="$(new_id "$id")"; mapped+="${nid} "; row "$id" "$nid"; done
# v2 rows no v1 row maps to (tools-changed) have no old side.
for nid in $(v2_ids); do case "$mapped" in *" $nid "*) ;; *) row - "$nid" ;; esac; done
column -t -s $'\t' "$table" >&2 2>/dev/null || cat "$table" >&2
say "parity table: ${table}"

# --- the branch merges -------------------------------------------------------------------------

d="$WORK/new" engine="$NEW_ROOT/bin/guard.sh"
release_baseline() { git -C "$d" show "${FIXTURE_new}:quality/baseline.tsv" 2>/dev/null | awk -F'\t' -v id="$1" '$1 == id { v = $2 } END { print (v == "" ? "-" : v) }'; }
# gated <path> -> status 0 when the path lies in quality/, is VAULT.md, or is a v2 protected path.
gated() {
    local p
    case "$1" in quality/*|VAULT.md) return 0 ;; esac
    for p in $(sed -n 's/^guard_protected_paths:[[:space:]]*//p' "$MIG/config"); do
        [ "$1" = "$p" ] && return 0
        case "$1" in "${p%/}"/*) return 0 ;; esac
    done
    return 1
}

branches="$MIG/branches.tsv"
printf 'branch\tbranch-sha\trelease-sha\tmerge-sha\tconflicts\tid\tvalue\tstatus\trelease-baseline\n' > "$branches"
bworst=0
for b in $BRANCHES; do
    bsha="$(git -C "$LIVE" rev-parse --verify -q "refs/remotes/origin/${b}^{commit}")" || die "the checkout has no origin/${b}"
    git -C "$d" fetch -q "$LIVE" "+refs/remotes/origin/${b}:refs/remotes/origin/${b}" || die "cannot fetch origin/${b} from ${LIVE}"
    git -C "$d" reset -q --hard && git -C "$d" clean -qfd || die "$b: cannot reset the clone"
    git -C "$d" checkout -q -B "qg-parity-merge-${b}" "$bsha" || die "cannot check out origin/${b}"
    say "$b: merge release ${FIXTURE_new:0:12} into origin/${b} ${bsha:0:12}"
    git -C "$d" merge -q --no-ff --no-edit -m "parity: merge release into ${b}" "$FIXTURE_new" >> "$LOG" 2>&1
    conflicts=''
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        gated "$f" && die "$b: the merge conflicts in ${f}, a gated path; resolve it by hand"
        # The branch is the checked-out side.
        if git -C "$d" checkout -q --ours -- "$f" 2>/dev/null; then git -C "$d" add -- "$f"; else git -C "$d" rm -q -- "$f"; fi
        conflicts+="${conflicts:+,}${f}"
    done < <(git -C "$d" diff --name-only --diff-filter=U)
    if [ -n "$conflicts" ]; then git -C "$d" commit -q --no-edit >> "$LOG" 2>&1 || die "$b: cannot commit the resolved merge"; fi
    [ -z "$(git -C "$d" diff --name-only --diff-filter=U)" ] || die "$b: the merge left unresolved files"
    msha="$(git -C "$d" rev-parse HEAD)"
    [ "$msha" != "$bsha" ] || die "$b: the merge made no commit"
    git -C "$d" diff --quiet "$FIXTURE_new" "$msha" -- pnpm-lock.yaml || say "$b: the merged lock differs from the release lock"
    # Always: the operator's `pnpm install` after `git pull` runs nuxt prepare on the merged code too.
    say "$b: pnpm install"; clone_install "$d"

    out="$WORK/branch-${b}.results"; : > "$out"
    echo '0 0' > "$WORK/suite"
    reports "$d" 0
    printf 'qg parity\n' > "$d/scripts/qg-parity-clean.txt"; git -C "$d" add scripts/qg-parity-clean.txt
    gate "$d" "$engine" "$b: commit rows" commit
    results "$d" | awk -F'|' '{ print $1 " " $2 " " $4 }' >> "$out"
    git -C "$d" reset -q && rm -f "$d/scripts/qg-parity-clean.txt"
    GATE_SHA="$msha" gate "$d" "$engine" "$b: push rows" release "refs/heads/${b}"
    results "$d" | awk -F'|' '{ print $1 " " $2 " " $4 }' >> "$out"
    gate "$d" "$engine" "$b: baseline row" baseline --only tests-suite-failed
    results "$d" | awk -F'|' '$1 == "tests-suite-failed" { print $1 " " $2 " " $4 }' >> "$out"
    git -C "$d" checkout -q -- quality/baseline.tsv 2>/dev/null

    for id in $(v2_ids); do
        read -r v s < <(awk -v id="$id" '$1 == id { v = $2; s = $3 } END { print (v == "" ? "-" : v), (s == "" ? "-" : s) }' "$out")
        num "$v" || { bworst=2; say "$b: ${id} was not measured (${v}/${s})"; }
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$b" "$bsha" "$FIXTURE_new" "$msha" "${conflicts:--}" "$id" "$v" "$s" "$(release_baseline "$id")" >> "$branches"
    done
done
column -t -s $'\t' "$branches" >&2 2>/dev/null || cat "$branches" >&2
say "branch table: ${branches}"
[ "$bworst" -eq 0 ] || worst=2

# --- the live checkout -------------------------------------------------------------------------

[ "$(git -C "$LIVE" status --porcelain)" = "$LIVE_STATUS" ] || { say "the run changed the status of ${LIVE}"; worst=2; }
touched="$(find "$LIVE/node_modules" "$LIVE/.nuxt" -newer "$WORK/live.marker" -print -quit 2>/dev/null)"
[ -z "$touched" ] || { say "the run wrote into the live checkout: ${touched}"; worst=2; }
say "run time $(( ($(date +%s) - START) / 60 )) min"
case "$worst" in
    0) echo "parity: every kept id reads the same on both seeds; every branch row measured" ;;
    1) echo "parity: a kept id differs; see ${table}" ;;
    *) echo "parity: a row was vacuous or unmeasured; see ${table} and ${branches}" ;;
esac
exit "$worst"
