#!/usr/bin/env bash
# in-node.sh — the runner of the node rows of app.givore.com and dashboard.givore.com, installed as
# quality/bin/in-node.sh. The engine copies it alone into a temporary folder, so it reads nothing
# beside itself.
#
#   in-node.sh <tree> <cache> <cmd...>   runs <cmd> in <tree> as `env -u NODE_OPTIONS -u NODE_PATH <cmd>`
#   in-node.sh --tools-diff <tree>       prints the tools-changed count for <tree>/pnpm-lock.yaml
#   in-node.sh --closure <lock>          prints the tool closure of <lock>, "name version" per line
#
# The caller's cwd is the repo root or a linked worktree; HEAD is that checkout's HEAD and the main
# checkout is the parent of `git rev-parse --git-common-dir`. <cache> is accepted for the engine's
# runner call and not used.
#
# Event. <tree> is a push tree when it is the top level of a git worktree (the pushed checkout), and
# a commit tree when git finds no worktree there (<git-common-dir>/guard-tree). A <tree> inside a
# worktree but not its top level exits 2.
#   commit: links the main checkout's node_modules into <tree>, deletes <tree>/.nuxt and copies the
#           main checkout's .nuxt, and deletes <tree>'s *.tsbuildinfo. At exit it removes the link
#           and the .nuxt copy. A staged nuxt.config.ts or a tree's own .nuxt never shapes the rules.
#   push:   links, copies and deletes nothing; <tree>/node_modules and <tree>/.nuxt must exist.
# It never runs `nuxt prepare`, and runs <cmd> without nice.
#
# Tool closure: the snapshots reachable from importer `.` devDependencies and from every `nuxt` and
# `@nuxt/cli` in importers or snapshots, through snapshot `dependencies` and `optionalDependencies`
# (pnpm lockfile v9). Each member is "name version" with the peer suffix dropped, so a change in a
# peer suffix alone changes nothing. Before <cmd> runs, the closure of the used
# node_modules/.pnpm/lock.yaml must equal the closure of HEAD:pnpm-lock.yaml. --tools-diff counts
# the package names whose version set differs between the closures of <tree>/pnpm-lock.yaml and
# HEAD:pnpm-lock.yaml; a package outside both closures never counts.
#
# Exit: <cmd>'s own exit code · 2 bad arguments, <tree> missing, node_modules or .nuxt missing, the
# main .nuxt lacking eslint.config.mjs or tsconfig.app.json, a lock missing or not v9, or the tool
# closure differing from HEAD's
set -uo pipefail

err() { echo "in-node.sh: $*" >&2; }

# lock_v9 <lock> -> status 0 when <lock> is a pnpm lockfile v9.
lock_v9() { [ -r "$1" ] && grep -Eq "^lockfileVersion: '?9\." <<< "$(head -n 1 "$1")"; }

# closure <lock> -> the tool closure, "name version" per line, sorted and unique.
closure() {
    awk '
        function unq(s) { if (s ~ /^\047.*\047$/ || s ~ /^".*"$/) s = substr(s, 2, length(s) - 2); return s }
        # kv <line> -> sets K and V; a quoted key may hold ":".
        function kv(s,   i) {
            sub(/^ +/, "", s)
            if (substr(s, 1, 1) == "\047") { i = index(substr(s, 2), "\047"); K = substr(s, 2, i - 1); s = substr(s, i + 2) }
            else { i = index(s, ":"); K = substr(s, 1, i - 1); s = substr(s, i) }
            sub(/^:[ ]*/, "", s); V = unq(s)
        }
        function pname(k,   i) { i = index(substr(k, 2), "@"); return i ? substr(k, 1, i) : k }
        function pver(k,   v, i) { v = substr(k, length(pname(k)) + 2); i = index(v, "("); return i ? substr(v, 1, i - 1) : v }
        # An alias value ("string-width@4.2.3") is a snapshot key itself.
        function resolve(n, v) { if ((n "@" v) in snap) return n "@" v; if (v in snap) return v; return n "@" v }
        function root(k) { if (!(k in seen)) { seen[k] = 1; queue[++qn] = k } }
        /^[^ ]/ { sect = $0; sub(/:.*/, "", sect); next }
        sect == "importers" && /^  [^ ]/ { kv($0); imp = K; next }
        sect == "importers" && /^    [^ ]/ { kv($0); dsect = K; next }
        sect == "importers" && /^      [^ ]/ { kv($0); dname = K; next }
        sect == "importers" && /^        version:/ {
            kv($0)
            if ((imp == "." && dsect == "devDependencies") || dname == "nuxt" || dname == "@nuxt/cli") { rn++; rname[rn] = dname; rval[rn] = V }
            next
        }
        sect == "snapshots" && /^  [^ ]/ { kv($0); cur = K; snap[cur] = 1; sk[++sn] = cur; edges = 0; next }
        sect == "snapshots" && /^    [^ ]/ { kv($0); edges = (K == "dependencies" || K == "optionalDependencies"); next }
        sect == "snapshots" && edges && /^      [^ -]/ { kv($0); en++; efrom[en] = cur; ename[en] = K; evl[en] = V; next }
        END {
            for (i = 1; i <= en; i++) adj[efrom[i]] = adj[efrom[i]] "\034" resolve(ename[i], evl[i])
            for (i = 1; i <= rn; i++) root(resolve(rname[i], rval[i]))
            for (i = 1; i <= sn; i++) if (pname(sk[i]) == "nuxt" || pname(sk[i]) == "@nuxt/cli") root(sk[i])
            for (q = 1; q <= qn; q++) {
                n = split(adj[queue[q]], to, "\034")
                for (j = 2; j <= n; j++) root(to[j])
            }
            for (k in seen) print pname(k) " " pver(k)
        }' "$1" | LC_ALL=C sort -u
}

# tools_changed <lock a> <lock b> -> the package names whose closure versions differ, one per line.
tools_changed() {
    LC_ALL=C comm -3 <(closure "$1") <(closure "$2") | tr -d '\t' | cut -d' ' -f1 | LC_ALL=C sort -u
}

# head_lock <file> -> writes HEAD:pnpm-lock.yaml to <file>; status 2 when HEAD has none or not v9.
head_lock() {
    git show HEAD:pnpm-lock.yaml > "$1" 2>/dev/null || { err "HEAD has no pnpm-lock.yaml"; return 2; }
    lock_v9 "$1" || { err "HEAD:pnpm-lock.yaml is not a pnpm lockfile v9"; return 2; }
}

made_link=''
made_nuxt=''
tmp_lock=''
cleanup() {
    [ -n "$made_link" ] && rm -f "$made_link"
    [ -n "$made_nuxt" ] && rm -rf "$made_nuxt"
    [ -n "$tmp_lock" ] && rm -f "$tmp_lock"
    return 0
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

case "${1:-}" in
    --closure)
        [ "$#" -eq 2 ] || { echo "usage: in-node.sh --closure <lock>" >&2; exit 2; }
        lock_v9 "$2" || { err "$2 is missing or not a pnpm lockfile v9"; exit 2; }
        closure "$2"
        exit 0 ;;
    --tools-diff)
        [ "$#" -eq 2 ] || { echo "usage: in-node.sh --tools-diff <tree>" >&2; exit 2; }
        lock_v9 "$2/pnpm-lock.yaml" || { err "$2/pnpm-lock.yaml is missing or not a pnpm lockfile v9"; exit 2; }
        tmp_lock="$(mktemp)"
        head_lock "$tmp_lock" || exit 2
        changed="$(tools_changed "$tmp_lock" "$2/pnpm-lock.yaml")" || exit 2
        if [ -z "$changed" ]; then echo 0; else printf '%s\n' "$changed" | wc -l | tr -d ' '; fi
        exit 0 ;;
esac

if [ "$#" -lt 3 ]; then
    echo "usage: in-node.sh <tree> <cache> <cmd...> | --tools-diff <tree> | --closure <lock>" >&2
    exit 2
fi
tree="$1"
shift 2
[ -d "$tree" ] || { err "tree $tree does not exist"; exit 2; }
tree="$(cd "$tree" && pwd -P)"

common_dir="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" \
    || { err "$PWD is not inside a git repository"; exit 2; }
main="$(cd "$(dirname "$common_dir")" && pwd -P)"

# A hook exports GIT_DIR and GIT_INDEX_FILE; drop them so git looks at <tree> itself.
if top="$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE git -C "$tree" rev-parse --show-toplevel 2>/dev/null)"; then
    [ "$(cd "$top" && pwd -P)" = "$tree" ] || { err "$tree is inside the checkout $top but not its top level"; exit 2; }
    event=push
    home="$tree"
else
    event=commit
    home="$main"
fi

[ -d "$home/node_modules" ] || { err "$home/node_modules does not exist; run pnpm install in $home"; exit 2; }
[ -d "$home/.nuxt" ] || { err "$home/.nuxt does not exist; run pnpm install in $home"; exit 2; }
if [ "$event" = commit ]; then
    for f in eslint.config.mjs tsconfig.app.json; do
        [ -f "$main/.nuxt/$f" ] || { err "$main/.nuxt/$f does not exist; run pnpm install in $main"; exit 2; }
    done
    if [ -e "$tree/node_modules" ] && [ ! -L "$tree/node_modules" ]; then
        err "$tree/node_modules is a folder in the tree, not a link this runner made"; exit 2
    fi
fi

used="$home/node_modules/.pnpm/lock.yaml"
lock_v9 "$used" || { err "$used is missing or not a pnpm lockfile v9; run pnpm install in $home"; exit 2; }
tmp_lock="$(mktemp)"
head_lock "$tmp_lock" || exit 2
changed="$(tools_changed "$tmp_lock" "$used")" || exit 2
if [ -n "$changed" ]; then
    err "the tools installed in $home/node_modules differ from HEAD:pnpm-lock.yaml in:"
    printf '%s\n' "$changed" | head -n 10 | sed 's/^/  /' >&2
    err "fix: run pnpm install in $home on a branch with this lock"
    exit 2
fi
rm -f "$tmp_lock"
tmp_lock=''

if [ "$event" = commit ]; then
    find "$tree" -name node_modules -prune -o -name '*.tsbuildinfo' -type f -exec rm -f {} +
    [ -L "$tree/node_modules" ] && rm -f "$tree/node_modules"
    made_link="$tree/node_modules"
    ln -s "$main/node_modules" "$made_link" || { err "cannot link $made_link"; exit 2; }
    rm -rf "$tree/.nuxt"
    made_nuxt="$tree/.nuxt"
    cp -R "$main/.nuxt" "$made_nuxt" || { err "cannot copy $main/.nuxt to $made_nuxt"; exit 2; }
fi

rc=0
(cd "$tree" && exec env -u NODE_OPTIONS -u NODE_PATH "$@") || rc=$?
exit "$rc"
