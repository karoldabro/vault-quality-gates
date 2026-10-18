#!/usr/bin/env bash
# S3 SC-2 — migrations/web/in-node.sh, copied alone as the engine copies it, runs the tool with
# NODE_OPTIONS and NODE_PATH unset, in the tree with the main checkout's node_modules and a fresh
# copy of its .nuxt, and removes what it made; exits 2 naming the package and the fix when the tool
# closure of the installed lock differs from HEAD's; never runs nuxt prepare. The runner cases run in
# tests/unit/qg-runner-in-node.bats.
#
# This script adds the engine end to end, on the host, in a fixture repo under mktemp: the app.givore.com
# v2 rows of migrations/app.givore.com/ with migrations/web/in-node.sh committed, and stub eslint,
# vue-tsc and jscpd that report a finding on each line holding BAD only while .nuxt/ in their cwd says
# "strict". `qg run commit --json` then measures:
#   clean      utils/a.ts with one BAD line, staged in the main checkout
#   hostile    the same file staged from a linked worktree, with a nuxt.config.ts turning strict off
#              and writing a marker, its .nuxt and a force-added .nuxt both "loose", NODE_OPTIONS
#              set to --require a marker script: every commit row reads as clean, no marker exists
#   control    main's own .nuxt "loose": lint-new and typecheck-new drop to 0, so the stubs react
#   tools      a staged lock changing only a package outside the tool closure reads tools-changed 0;
#              one bumping typescript and adding a devDependency reads 2
#
# Exit 0 pass, 1 fail, 2 could not run.
exec < /dev/null
set -uo pipefail
export LC_ALL=C
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
APP="$ROOT/migrations/app.givore.com"
COMMIT_ROWS="$(awk -F'\t' 'NR > 1 && $0 !~ /^#/ && $3 != "absent" && $2 ~ /(^|,)commit(,|$)/ { print $1 }' "$APP/checks.tsv")"

. "$ROOT/checks/_qg-cases.sh"
bats_out="$(qg_cases \
    qg-runner-in-node.bats \
    "commit: the tool runs in the tree with main's node_modules and a fresh copy of main's .nuxt" \
    "commit: everything the runner made is gone at exit, the tool's exit code comes back, main is intact" \
    "commit: a staged nuxt.config.ts and a loose tree .nuxt change nothing and write no marker" \
    "commit: from a linked worktree with a hook's GIT_DIR, the tree still takes the main checkout's install" \
    "either: an inherited NODE_OPTIONS or NODE_PATH never reaches the tool" \
    "either: a tool closure differing from HEAD exits 2 naming the package and the fix" \
    "either: the refusal lists the first 10 package names" \
    "either: a change only outside the closure runs" \
    "either: a used or HEAD lock missing or not v9 exits 2" \
    "push: in the main checkout the runner links, copies and deletes nothing" \
    "push: node_modules or .nuxt missing in the tree exits 2" \
    "closure: devDependencies, nuxt and @nuxt/cli with their transitive and optional packages, aliases resolved" \
    "tools-changed: 0 for identical locks and for changes outside the closure" \
    "tools-changed: one per package name bumped in the closure, scoped names and aliases included" \
    "tools-changed: a devDependency added or removed counts 1 in either direction" \
    "tools-changed: a peer-suffix-only change counts 0" \
    "tools-changed: a staged lock missing or not v9 is unmeasurable: exit 2, no number" \
    "tools-changed: the row's own call form, HEAD's runner through bash -c, counts the same")"
bats_rc=$?
[ "$bats_rc" -ne 2 ] || { printf '%s\n' "$bats_out"; exit 2; }
sed '$d' <<<"$bats_out"
read -r bats_bad _ bats_total _ <<<"$(tail -1 <<<"$bats_out")"
[ "$bats_rc" -eq 0 ] && bats_bad=0

W="$(mktemp -d)" || exit 2
trap 'rm -rf "$W"' EXIT
MAIN="$W/main" WT="$W/wt" MARK="$W/marker"
export GUARD_LOCK_WAIT=30
unset NODE_OPTIONS NODE_PATH GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE QG_SKIP_REASON

# lock <file> <prod-only version> <typescript version> [<extra devDependency> <version>] — a pnpm
# lockfile v9 whose tool closure is eslint, typescript, nuxt and @nuxt/cli; left-pad and prod-only
# sit outside it.
lock() {
    cat > "$1" <<EOF
lockfileVersion: '9.0'

settings:
  autoInstallPeers: true

importers:

  .:
    dependencies:
      left-pad:
        specifier: ^1.0.0
        version: 1.0.0
      nuxt:
        specifier: ^4.0.0
        version: 4.0.0(typescript@$3)
    devDependencies:
      eslint:
        specifier: ^10.0.0
        version: 10.0.0
      typescript:
        specifier: ^5.0.0
        version: $3
${4:+      $4:
        specifier: ^${5:-}
        version: ${5:-}}

packages:

snapshots:

  '@nuxt/cli@3.0.0': {}

  eslint@10.0.0: {}

  left-pad@1.0.0:
    dependencies:
      prod-only: $2

  nuxt@4.0.0(typescript@$3):
    dependencies:
      '@nuxt/cli': 3.0.0
      typescript: $3

  prod-only@$2: {}

  typescript@$3: {}
EOF
    [ -z "${4:-}" ] || printf '\n  %s@%s: {}\n' "$4" "$5" >> "$1"
}

# stub <file> — writes the bash script on stdin to <file>, after a line that leaves the marker when
# NODE_OPTIONS reaches it, as node would run a --require script.
stub() {
    { printf '#!/usr/bin/env bash\n[ -z "${NODE_OPTIONS:-}" ] || touch %q\n' "$MARK"; cat; } > "$1" && chmod +x "$1"
}

git_() { git -c user.email=check@example.invalid -c user.name=check -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"; }

# The main checkout: HEAD carries the v2 rows, the runner and the lock; node_modules and .nuxt are
# installed and strict.
setup_main() {
    mkdir -p "$MAIN/quality/bin" "$MAIN/utils" && cd "$MAIN" && git init -q . || return 1
    cp "$APP/checks.tsv" "$APP/config" "$APP/jscpd.json" quality/ && cp "$ROOT/migrations/web/in-node.sh" quality/bin/ \
        && chmod +x quality/bin/in-node.sh || return 1
    printf 'id\ttool\tenforced_by\temits\n' > quality/rules.tsv
    printf 'id\tvalue\tcommit\treason\nduplication\t5\t-\t-\n' > quality/baseline.tsv
    printf 'node_modules/\n.nuxt/\n' > .gitignore
    printf 'export default []\n' > eslint.config.mjs
    printf '{}\n' > tsconfig.json
    printf 'export default { typescript: { strict: true } }\n' > nuxt.config.ts
    printf 'export const old = 1\n' > utils/old.ts
    lock pnpm-lock.yaml 1.0.0 5.0.0
    git_ add -A && git_ commit -q -m base || return 1
    mkdir -p node_modules/.pnpm node_modules/.bin .nuxt
    cp pnpm-lock.yaml node_modules/.pnpm/lock.yaml
    echo strict > .nuxt/eslint.config.mjs
    echo strict > .nuxt/tsconfig.app.json
    # eslint -c <config> -f json -o <report> [--no-warn-ignored] -- <files>
    stub node_modules/.bin/eslint <<'EOF'
strict="$(cat .nuxt/eslint.config.mjs 2>/dev/null)" out='' after='' rc=0
files=()
while [ $# -gt 0 ]; do
    case "$1" in -o) out="$2"; shift 2; continue ;; --) after=1; shift; continue ;; esac
    [ -z "$after" ] || files+=("$1")
    shift
done
{
    printf '['; sep=''
    for f in "${files[@]}"; do
        printf '%s{"filePath":"%s","messages":[' "$sep" "$f"; sep=','
        if [ "$strict" = strict ]; then
            grep -n BAD "$f" | cut -d: -f1 \
                | awk '{ printf "%s{\"ruleId\":\"no-bad\",\"severity\":2,\"line\":%s,\"column\":1,\"message\":\"bad\"}", (NR > 1 ? "," : ""), $1 }'
            ! grep -q BAD "$f" || rc=1
        fi
        printf ']}'
    done
    printf ']'
} > "$out"
exit "$rc"
EOF
    # vue-tsc: error TS2322 on every BAD line of the project while .nuxt says strict.
    stub node_modules/.bin/vue-tsc <<'EOF'
[ "$(cat .nuxt/tsconfig.app.json 2>/dev/null)" = strict ] || exit 0
hits="$(find . \( -name node_modules -o -name .nuxt -o -name .git \) -prune -o -name '*.ts' -type f -print \
    | sed 's#^\./##' | sort | while IFS= read -r f; do
        grep -n BAD "$f" | cut -d: -f1 | sed "s#.*#${f}(&,1): error TS2322: Type BAD is not assignable.#"
    done)"
[ -n "$hits" ] || exit 0
printf '%s\n' "$hits"
exit 2
EOF
    # jscpd: one clone between utils/a.ts:1 and utils/old.ts:1, 5 percent of the lines.
    stub node_modules/.bin/jscpd <<'EOF'
out=''
while [ $# -gt 0 ]; do [ "$1" != --output ] || out="$2"; shift; done
mkdir -p "$out"
printf '%s' '{"duplicates":[{"format":"typescript","lines":1,"firstFile":{"name":"utils/a.ts","start":1,"end":1},"secondFile":{"name":"utils/old.ts","start":1,"end":1}}],"statistics":{"total":{"lines":20,"duplicatedLines":1,"percentage":5,"clones":1}}}' > "$out/jscpd-report.json"
EOF
    # nuxt and nuxi leave the marker, so a `nuxt prepare` shows.
    printf 'touch %q\n' "$MARK" | stub node_modules/.bin/nuxt
    cp node_modules/.bin/nuxt node_modules/.bin/nuxi
    printf "require('fs').writeFileSync('%s', 'x')\n" "$MARK" > "$W/evil.js"
}

# measure <name> [--only ids] -> $W/<name>.tsv holds "id value status" per row the gate measured.
measure() {
    local name="$1"
    shift
    "$ROOT/bin/qg" run commit "$@" --json > "$W/$name.json" 2> "$W/$name.err"
    jq -r '.rows[] | "\(.id)\t\(.value)\t\(.status)"' "$W/$name.json" 2>/dev/null | sort > "$W/$name.tsv"
}
value() { awk -F'\t' -v id="$2" '$1 == id { print $2 }' "$W/$1.tsv"; }

pass=0 total=0
case_() {  # case_ <name> <failure text or empty>
    total=$((total + 1))
    if [ -z "$2" ]; then pass=$((pass + 1)); else printf '  FAILING  %s: %s\n' "$1" "$2"; fi
}

setup_main || { echo 'could not build the fixture repo'; exit 2; }
printf "export const a: number = 'BAD'\n" > utils/a.ts
git_ add utils/a.ts
measure clean
miss=''
for id in $COMMIT_ROWS; do
    v="$(value clean "$id")"
    [[ "$v" =~ ^[0-9]+(\.[0-9]+)?$ ]] || miss+=" ${id}=${v:-none}"
done
[ -z "$miss" ] || { echo "the clean commit left rows unmeasured:${miss}"; sed -n '1,40p' "$W/clean.err"; exit 2; }
bad=''
[ "$(value clean lint-new)" = 1 ] && [ "$(value clean typecheck-new)" = 1 ] \
    || bad="lint-new $(value clean lint-new), typecheck-new $(value clean typecheck-new), expected 1 each"
case_ "clean: the strict main .nuxt finds the BAD line" "$bad"

# hostile: from a linked worktree, with a loosening config, loose .nuxt copies and NODE_OPTIONS.
git_ reset -q && rm -f utils/a.ts
git_ worktree add -q "$WT" HEAD || exit 2
cd "$WT" || exit 2
mkdir -p utils .nuxt
printf "export const a: number = 'BAD'\n" > utils/a.ts
printf '%s\n' "require('fs').writeFileSync('$MARK', 'x')" 'export default { typescript: { strict: false } }' > nuxt.config.ts
echo loose > .nuxt/eslint.config.mjs
echo loose > .nuxt/tsconfig.app.json
git_ add utils/a.ts nuxt.config.ts && git_ add -f .nuxt/eslint.config.mjs .nuxt/tsconfig.app.json
NODE_OPTIONS="--require $W/evil.js" measure hostile
miss=''
for id in $COMMIT_ROWS; do
    [ "$(value hostile "$id")" = "$(value clean "$id")" ] || miss+=" ${id} $(value clean "$id")->$(value hostile "$id")"
done
case_ "hostile: a staged nuxt.config.ts and loose worktree and tree .nuxt change no commit row value" "${miss:+changed:$miss}"
case_ "hostile: no marker is written" "$([ ! -e "$MARK" ] || echo "$MARK exists")"
tree="$(git -C "$MAIN" rev-parse --path-format=absolute --git-common-dir)/guard-tree"
bad=''
{ [ -L "$tree/node_modules" ] || [ -e "$tree/.nuxt" ]; } && bad="the runner left node_modules or .nuxt in ${tree}"
[ "$(cat "$MAIN/.nuxt/tsconfig.app.json")" = strict ] || bad+=" main's .nuxt changed"
case_ "hostile: the runner removed what it made and left main intact" "$bad"

# control: the stubs follow .nuxt, so a loose main .nuxt reads 0.
cd "$MAIN" || exit 2
git_ -C "$WT" reset -q
echo loose > .nuxt/eslint.config.mjs; echo loose > .nuxt/tsconfig.app.json
printf "export const a: number = 'BAD'\n" > utils/a.ts
git_ add utils/a.ts
measure control
case_ "control: a loose main .nuxt reads lint-new and typecheck-new 0" \
    "$([ "$(value control lint-new)" = 0 ] && [ "$(value control typecheck-new)" = 0 ] \
        || echo "lint-new $(value control lint-new), typecheck-new $(value control typecheck-new)")"
echo strict > .nuxt/eslint.config.mjs; echo strict > .nuxt/tsconfig.app.json
git_ reset -q && rm -f utils/a.ts

# tools: tools-changed through the engine, on staged locks.
lock pnpm-lock.yaml 1.1.0 5.0.0
git_ add pnpm-lock.yaml
measure prod --only tools-changed
case_ "tools: a staged lock changing only prod-only reads tools-changed 0" \
    "$([ "$(value prod tools-changed)" = 0 ] || echo "read $(value prod tools-changed)")"
lock pnpm-lock.yaml 1.0.0 5.1.0 vitest 1.0.0
git_ add pnpm-lock.yaml
measure tools --only tools-changed
case_ "tools: a staged lock bumping typescript and adding vitest reads tools-changed 2" \
    "$([ "$(value tools tools-changed)" = 2 ] || echo "read $(value tools tools-changed)")"

pass=$((pass + bats_total - bats_bad)) total=$((total + bats_total))
if [ "$pass" -ne "$total" ]; then printf '%s of %s cases failing\n' "$((total - pass))" "$total"; exit 1; fi
printf '%s of %s cases passing\n' "$total" "$total"
