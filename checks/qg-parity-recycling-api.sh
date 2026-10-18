#!/usr/bin/env bash
# SC-6 (contract C-4) — row parity of recycling-api's v2 gate rows with its v1 rows.
#
#   checks/qg-parity-recycling-api.sh [<recycling-api checkout>]     default ~/workspace/recycling-api
#
# Builds two scratch clones of the checkout's HEAD with no hooks: `old` carries the committed v1
# quality/checks.tsv with the five release rows of commit 7add7c29 (docker compose run on the
# folder), `new` carries migrations/recycling-api/. vendor/ and .env are copied from the checkout;
# nothing else of it is read or written. Each clone is measured in up to three states:
#
#   clean   a neutral staged file (old clone only): the value a row reads with no violation
#   seed1   one violation set per row, in one commit: the commit rows judge it staged, the push
#           rows judge it committed, the baseline rows judge seeded whole-suite reports
#   seed2   the same with twice the violations, so a count is told from a 0/1 reading
#
# The old engine is ~/workspace/vault-quality-gates (QG_PARITY_OLD_ENGINE), the new one this repo.
# `docker compose exec -T server composer test:*` (old) and `vendor/bin/phpunit` or
# `vendor/bin/infection` inside `docker compose run` (new) never start the suite: a docker shim
# writes the seeded reports instead, because the live suite takes an hour.
#
# Writes migrations/recycling-api/parity.tsv (columns: id, new id, kind, verdict, old clean,
# old seed1, old seed2, new seed1, new seed2) and prints it. Verdicts: SAME, DIFF (a kept id whose
# value or status differs), NEW (a renamed row; its values are shown), VACUOUS (the seed did not
# move the old value, or a side could not measure).
# Exit 0 every kept id is SAME · 1 a kept id is DIFF · 2 a row is VACUOUS, a run timed out, or the
# clones could not be built. A row that could not be measured is never reported as SAME.
set -uo pipefail
export LC_ALL=C

NEW_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OLD_ROOT="${QG_PARITY_OLD_ENGINE:-$HOME/workspace/vault-quality-gates}"
LIVE="$(cd "${1:-$HOME/workspace/recycling-api}" && pwd)" || { echo "parity: no checkout ${1:-}"; exit 2; }
MIG="${NEW_ROOT}/migrations/recycling-api"
REF=refs/heads/release/qg-parity
RENAMED='format=format-files format-staged=format-staged-files gate-config-touched=protected-paths-touched'
STEP_TIMEOUT="${QG_PARITY_TIMEOUT:-3600}"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/qg-parity.XXXXXX")" || exit 2
LOG="${WORK}/parity.log"
trap 'echo "parity: work dir ${WORK} (log ${LOG})" >&2' EXIT
say() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$LOG" >&2; }
die() { say "CANNOT RUN: $*"; exit 2; }

# --- the clones --------------------------------------------------------------------------------

BASE="$(git -C "$LIVE" rev-parse HEAD)" || die "cannot read HEAD of ${LIVE}"
REAL_DOCKER="$(command -v docker)" || die 'docker is not on PATH'
[ -d "$LIVE/vendor" ] && [ -f "$LIVE/.env" ] || die "${LIVE} has no vendor/ or .env to copy"

say "base ${BASE:0:12} of ${LIVE}; work ${WORK}"
cp -a "$LIVE/vendor" "$WORK/vendor.copy" || die 'cannot copy vendor/'
for side in old new; do
    git clone -q --shared --no-checkout "$LIVE" "$WORK/$side" || die "cannot clone into $side"
    git -C "$WORK/$side" checkout -q --detach "$BASE" || die "cannot check out ${BASE} in $side"
    git -C "$WORK/$side" config user.email parity@example.invalid
    git -C "$WORK/$side" config user.name parity
    git -C "$WORK/$side" config core.hooksPath /dev/null
    cp -al "$WORK/vendor.copy" "$WORK/$side/vendor" || die "cannot link vendor/ into $side"
    cp "$LIVE/.env" "$WORK/$side/.env"
done

# old: HEAD's v1 rows, with the release rows 7add7c29 moved to docker compose run.
git -C "$LIVE" show 7add7c29:quality/checks.tsv > "$WORK/7add7c29.tsv" 2>/dev/null || die 'commit 7add7c29 is not in the checkout'
awk -F'\t' 'NR == FNR { if ($1 ~ /^(format|insights-code|phpstan-errors|indication-checks|deps-shadow)$/) row[$1] = $0; next }
            ($1 in row) { print row[$1]; next } { print }' "$WORK/7add7c29.tsv" "$WORK/old/quality/checks.tsv" > "$WORK/old.tsv"
cp "$WORK/old.tsv" "$WORK/old/quality/checks.tsv"
git -C "$WORK/old" commit -qam 'parity: v1 rows with 7add7c29 release rows' || die 'cannot commit the old fixture'
# shellcheck disable=SC2034  # read through ${!fixture} in measure
FIXTURE_old="$(git -C "$WORK/old" rev-parse HEAD)"

# new: the prepared v2 files.
cp "$MIG/checks.tsv" "$WORK/new/quality/checks.tsv"
cp "$MIG/config" "$WORK/new/quality/config"
for f in in-tree.sh in-server.sh lock-check.sh; do cp "$MIG/$f" "$WORK/new/quality/bin/$f"; chmod +x "$WORK/new/quality/bin/$f"; done
git -C "$WORK/new" add quality && git -C "$WORK/new" commit -qm 'parity: v2 rows' || die 'cannot commit the new fixture'
# shellcheck disable=SC2034  # read through ${!fixture} in measure
FIXTURE_new="$(git -C "$WORK/new" rev-parse HEAD)"

# --- the docker shim for the whole-suite rows --------------------------------------------------

mkdir -p "$WORK/shim"
cat > "$WORK/shim/docker" <<SHIM
#!/usr/bin/env bash
# Writes seeded whole-suite reports instead of running the suite; every other call is real docker.
args=" \$* "
dir="\$PWD"
case "\$args" in *' --project-directory '*) dir="\${args#* --project-directory }"; dir="\${dir%% *}" ;; esac
n="\$(cat "$WORK/state" 2>/dev/null || echo 0)"
case "\$args" in
    *' compose exec -T server composer test:coverage '*|*' compose '*' run '*' vendor/bin/phpunit '*)
        mkdir -p "\$dir/storage/coverage" "\$dir/storage/logs"; : > "\$dir/storage/logs/lazy-loading.log"
        sed "0,/failures=\"[0-9]*\"/s//failures=\"\$n\"/" "$WORK/junit.base.xml" > "\$dir/storage/coverage/junit.xml"
        exit \$(( n > 0 )) ;;
    *' compose exec -T server composer test:mutation '*|*' compose '*' run '*' vendor/bin/infection '*)
        mkdir -p "\$dir/storage/infection"
        printf '{"stats":{"msi":%s}}\n' "\$(( 80 - n ))" > "\$dir/storage/infection/summary.json"
        exit 0 ;;
esac
exec "$REAL_DOCKER" "\$@"
SHIM
chmod +x "$WORK/shim/docker"
# The base reports: the checkout's last whole-suite run, with zero failures.
sed '0,/failures="[0-9]*"/s//failures="0"/; 0,/errors="[0-9]*"/s//errors="0"/' "$LIVE/storage/coverage/junit.xml" > "$WORK/junit.base.xml" \
    || die "${LIVE}/storage/coverage/junit.xml is unreadable"
cp "$LIVE/storage/coverage/clover.xml" "$WORK/clover.base.xml" || die "${LIVE}/storage/coverage/clover.xml is unreadable"

# --- the seeds ---------------------------------------------------------------------------------

php_file() {  # php_file <path> <class> <body> — a PHP class file
    mkdir -p "$(dirname "$1")"
    local ns; ns="$(dirname "$1" | sed 's#^app#App#; s#^tests#Tests#; s#/#\\#g')"
    printf '<?php\n\ndeclare(strict_types=1);\n\nnamespace %s;\n\n%s\n' "$ns" "$3" > "$1"
}

# seed <clone> <n> — n violations of every row, written into the clone's working tree.
seed() {
    local d="$1" n="$2" i k
    for i in $(seq 1 "$n"); do
        # pint, phpcs (unused variable), phpstan (a type error), phpmd (short method name)
        mkdir -p "$d/app/QgParity"
        printf '<?php\nnamespace App\\QgParity;\nclass Format%s {\n    public function f($a,$b){ $unused = 1;\n    if($a){return $b;}\n  return   1; }\n}\n' "$i" > "$d/app/QgParity/Format$i.php"
        php_file "$d/app/QgParity/Type$i.php" "Type$i" "final class Type$i
{
    public function count(): int
    {
        return 'not a number';
    }
}"
        # phpmd coupling: 17 distinct dependencies against a maximum of 15
        local deps=''; for k in $(seq 1 17); do deps+="        new \\App\\QgParity\\Dep$k();"$'\n'; done
        php_file "$d/app/QgParity/Coupled$i.php" "Coupled$i" "final class Coupled$i
{
    public function build(): void
    {
${deps}    }
}"
        # phpstan level 8 under app/Support: a nullable passed where a string is required
        php_file "$d/app/Support/QgParityStrict$i.php" "QgParityStrict$i" "final class QgParityStrict$i
{
    public function length(?string \$text): int
    {
        return strlen(\$text);
    }
}"
        # suppressions-added
        php_file "$d/app/QgParity/Suppress$i.php" "Suppress$i" "/** @SuppressWarnings(PHPMD) */
final class Suppress$i
{
}"
        # a test smell: an assertion that passes whatever the code does
        php_file "$d/tests/Feature/QgParity/Smell${i}Test.php" "Smell${i}Test" "use Tests\\TestCase;

final class Smell${i}Test extends TestCase
{
    public function test_nothing(): void
    {
        \$this->assertTrue(true);
    }
}"
        # duplication: a copy of an existing service
        sed "s/class KnowledgeRetriever/class QgParityCopy$i/; s/^namespace .*/namespace App\\\\QgParity;/" \
            "$d/app/Services/Ai/KnowledgeRetriever.php" > "$d/app/QgParity/Copy$i.php"
        # baseline growth: one new entry per baseline
        printf '\n\t\t-\n\t\t\tmessage: '"'"'#^QG parity seed %s\\.$#'"'"'\n\t\t\tidentifier: qg.parity\n\t\t\tcount: 1\n\t\t\tpath: app/QgParity/Type%s.php\n' "$i" "$i" >> "$d/phpstan-baseline.neon"
        printf '\n\t\t-\n\t\t\tmessage: '"'"'#^QG parity seed %s\\.$#'"'"'\n\t\t\tidentifier: qg.parity\n\t\t\tcount: 1\n\t\t\tpath: ../app/QgParity/Type%s.php\n' "$i" "$i" >> "$d/quality/phpstan-strict-baseline.neon"
        # The entries name a file that does not exist, so they never hide a seeded violation.
        sed -i "s#</phpmd-baseline>#  <violation rule=\"PHPMD\\\\Rule\\\\Naming\\\\ShortMethodName\" file=\"app/QgParity/Ghost$i.php\" method=\"g\"/>\n</phpmd-baseline>#" "$d/quality/phpmd-baseline.xml"
        sed -i "s#</phpmd-baseline>#  <violation rule=\"PHPMD\\\\Rule\\\\Design\\\\CouplingBetweenObjects\" file=\"app/QgParity/Ghost$i.php\"/>\n</phpmd-baseline>#" "$d/quality/phpmd-coupling-baseline.xml"
        # request duplication: one rule entry both siblings carry
        for f in Create Update; do
            awk -v e="            'qg_parity_$i' => ['nullable', 'string']," \
                '/function rules/ { inrules = 1 } inrules && /return \[/ { print; print e; inrules = 0; next } { print }' \
                "$d/app/Http/Requests/Admin/${f}FaqCategoryRequest.php" > "$d/req.tmp" && mv "$d/req.tmp" "$d/app/Http/Requests/Admin/${f}FaqCategoryRequest.php"
        done
        # PHP Insights: ten complex methods, ten superfluously named interfaces, ten public properties
        for k in $(seq 1 10); do
            php_file "$d/app/QgParity/Insights/Complex${i}x$k.php" "Complex${i}x$k" "final class Complex${i}x$k
{
    public \$state = 0;

    public function decide(int \$a, int \$b, int \$c): int
    {
        if (\$a > 1) { if (\$b > 1) { if (\$c > 1) { return 1; } elseif (\$c < 0) { return 2; } } elseif (\$b < 0) { return 3; } }
        if (\$a < 0) { if (\$b > 2) { return 4; } elseif (\$b < -2) { return 5; } }
        if (\$c === 7 || \$c === 8 || \$c === 9 || \$c === 10) { return 6; }
        return \$a && \$b ? 7 : (\$c ? 8 : 9);
    }
}"
            php_file "$d/app/QgParity/Insights/Thing${i}x${k}Interface.php" "Thing${i}x${k}Interface" "interface Thing${i}x${k}Interface
{
}"
        done
        # comment density: 400 comment lines over one line of code
        { printf '<?php\n\nnamespace App\\QgParity;\n\n'; for k in $(seq 1 400); do printf '// qg parity comment %s\n' "$k"; done; printf 'final class Comments%s {}\n' "$i"; } > "$d/app/QgParity/Comments$i.php"
        # indication checks: a tracked file under quality-reports/
        mkdir -p "$d/quality-reports"; printf 'qg parity\n' > "$d/quality-reports/qg-parity-$i.txt"
    done
    # protected paths: one file protected by both configs; with two, also one only v2 protects
    printf '<!-- qg parity -->\n' >> "$d/quality/phpcs.xml"
    [ "$n" -lt 2 ] || printf '// qg parity\n' >> "$d/quality/phpinsights.php"
    # composer-dependency-analyser: a used package nobody requires, and a required package nobody uses
    php_file "$d/app/QgParity/Shadow1.php" Shadow1 'final class Shadow1
{
    public function make(): object
    {
        return \Doctrine\Inflector\InflectorFactory::create()->build();
    }
}'
    [ "$n" -lt 2 ] || php_file "$d/app/QgParity/Shadow2.php" Shadow2 'final class Shadow2
{
    public function make(): object
    {
        return \Brick\Math\BigInteger::of(1);
    }
}'
    local req='.require["psr/clock"] = "^1.0"'
    [ "$n" -lt 2 ] || req+=' | .require["dflydev/dot-access-data"] = "*"'
    jq --indent 4 "$req" "$d/composer.json" > "$d/composer.tmp" && mv "$d/composer.tmp" "$d/composer.json"
}

# reports <clone> <n> — the whole-suite reports the push rows read, n steps worse than the base.
reports() {
    local d="$1" n="$2" k
    mkdir -p "$d/storage/coverage" "$d/storage/logs"
    sed "0,/failures=\"[0-9]*\"/s//failures=\"$n\"/" "$WORK/junit.base.xml" > "$d/storage/coverage/junit.xml"
    awk -v n="$n" '/<project / { p = 1 } p && /<metrics / { match($0, /coveredstatements="[0-9]+"/); v = substr($0, RSTART + 19, RLENGTH - 20) - 100 * n
               sub(/coveredstatements="[0-9]+"/, "coveredstatements=\"" v "\""); p = 0 } { print }' "$WORK/clover.base.xml" > "$d/storage/coverage/clover.xml"
    : > "$d/storage/logs/lazy-loading.log"
    for k in $(seq 1 "$n"); do printf 'App\\Models\\QgParity%s::relation\n' "$k" >> "$d/storage/logs/lazy-loading.log"; done
    if [ "$n" -gt 0 ]; then touch -d "-$((10 * n)) days" "$d/storage/coverage/clover.xml"; else touch "$d/storage/coverage/clover.xml"; fi
}

# --- the runs ----------------------------------------------------------------------------------

results_file() { printf '%s/qg-last/RESULTS.txt' "$(git -C "$1" rev-parse --path-format=absolute --git-common-dir)"; }
results() { cat "$(results_file "$1")" 2>/dev/null; }

# measure <side> <state name> <n> — commit rows on the staged seeds, push rows on the committed
# seeds, baseline rows on seeded suite reports; appends "<state> <id> <value> <status>" to the
# side's results file.
measure() {
    local side="$1" state="$2" n="$3" d="$WORK/$1" engine rc out="$WORK/$1.results"
    if [ "$side" = old ]; then engine="$OLD_ROOT/bin/guard.sh"; else engine="$NEW_ROOT/bin/guard.sh"; fi
    local fixture="FIXTURE_$side"
    git -C "$d" reset -q --hard "${!fixture}" && git -C "$d" clean -qfd -e vendor -e .env
    printf '%s\n' "$n" > "$WORK/state"
    if [ "$n" -eq 0 ]; then mkdir -p "$d/tests"; printf 'parity\n' > "$d/tests/qg-parity-clean.txt"; else seed "$d" "$n"; fi
    git -C "$d" add -A
    [ "$n" -eq 0 ] || git -C "$d" add -f quality-reports/qg-parity-*.txt

    say "$side $state: commit rows"
    rm -f "$(results_file "$d")"
    rc=0; ( cd "$d" && GUARD_LOCK_WAIT=600 timeout "$STEP_TIMEOUT" bash "$engine" commit ) >> "$LOG" 2>&1 || rc=$?
    [ "$rc" -eq 124 ] && die "$side $state: the commit gate ran longer than ${STEP_TIMEOUT}s"
    results "$d" | awk -F'|' -v s="$state" '{ print s " " $1 " " $2 " " $4 }' >> "$out"

    git -C "$d" commit -qm "parity: ${state}" || die "$side $state: cannot commit the seeds"
    reports "$d" "$n"
    say "$side $state: push rows"
    rm -f "$(results_file "$d")"
    rc=0; ( cd "$d" && PATH="$WORK/shim:$PATH" GUARD_SHA="$(git rev-parse HEAD)" timeout "$STEP_TIMEOUT" bash "$engine" release "$REF" ) >> "$LOG" 2>&1 || rc=$?
    [ "$rc" -eq 124 ] && die "$side $state: the push gate ran longer than ${STEP_TIMEOUT}s"
    results "$d" | awk -F'|' -v s="$state" '{ print s " " $1 " " $2 " " $4 }' >> "$out"

    say "$side $state: baseline rows"
    rm -f "$(results_file "$d")"
    local only
    # shellcheck disable=SC2054  # one comma-separated id list
    if [ "$side" = new ]; then only=(--only mutation,tests-suite)
    else only=(--skip "^($(awk -F'\t' 'NR > 1 && $0 !~ /^#/ && $1 !~ /^(mutation|tests-suite)$/ { printf "%s%s", s, $1; s = "|" }' "$d/quality/checks.tsv"))\$"); fi
    rc=0; ( cd "$d" && PATH="$WORK/shim:$PATH" timeout "$STEP_TIMEOUT" bash "$engine" baseline "${only[@]}" ) >> "$LOG" 2>&1 || rc=$?
    [ "$rc" -eq 124 ] && die "$side $state: the baseline run took longer than ${STEP_TIMEOUT}s"
    results "$d" | awk -F'|' -v s="$state" '$1 ~ /^(mutation|tests-suite)$/ { print s " " $1 " " $2 " " $4 }' >> "$out"
    git -C "$d" checkout -q -- quality/baseline.tsv 2>/dev/null
}

measure old clean 0
measure old seed1 1
measure old seed2 2
measure new seed1 1
measure new seed2 2

# --- the table ---------------------------------------------------------------------------------

value() { awk -v s="$2" -v id="$3" '$1 == s && $2 == id { v = $3 "/" $4 } END { print (v == "" ? "-" : v) }' "$WORK/$1.results"; }
num() { [[ "${1%%/*}" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; }
count_kind() { awk -F'\t' -v id="$1" '$1 == id { print $3 }' "$MIG/checks.tsv"; }

table="$MIG/parity.tsv"
printf 'id\tnew-id\tkind\tverdict\told-clean\told-seed1\told-seed2\tnew-seed1\tnew-seed2\n' > "$table"
worst=0
for id in $(awk -F'\t' 'NR > 1 && $0 !~ /^#/ { print $1 }' "$WORK/old/quality/checks.tsv"); do
    nid="$id"
    for r in $RENAMED; do [ "${r%%=*}" = "$id" ] && nid="${r#*=}"; done
    oc="$(value old clean "$id")" o1="$(value old seed1 "$id")" o2="$(value old seed2 "$id")"
    n1="$(value new seed1 "$nid")" n2="$(value new seed2 "$nid")"
    if ! num "$o1" || ! num "$n1" || [ "${oc%%/*}" = "${o1%%/*}" ]; then verdict=VACUOUS
    elif [ "$nid" != "$id" ]; then verdict=NEW
    elif [ "$o1" = "$n1" ] && [ "$o2" = "$n2" ]; then verdict=SAME
    else verdict=DIFF; fi
    case "$verdict" in VACUOUS) worst=2 ;; DIFF) [ "$worst" -lt 1 ] && worst=1 ;; esac
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$nid" "$(count_kind "$nid")" "$verdict" "$oc" "$o1" "$o2" "$n1" "$n2" >> "$table"
done
column -t -s $'\t' "$table" >&2 2>/dev/null || cat "$table" >&2
say "parity table: ${table}"
case "$worst" in
    0) echo "parity: every kept id reads the same value and status on both seeds" ;;
    1) echo "parity: a kept id differs; see ${table}" ;;
    *) echo "parity: a row was vacuous or unmeasured; see ${table}" ;;
esac
exit "$worst"
