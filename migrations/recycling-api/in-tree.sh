#!/usr/bin/env bash
# in-tree.sh <tree> <cache> <cmd...> — runs <cmd> in the recycling-api-server image against a copy
# of the staged tree, never the working tree. The commit rows of quality/checks.tsv call it.
#
# <tree>   absolute path of the materialised tree, mounted at /app (the plugin's {{tree}}).
# <cache>  absolute path mounted at /tmp/phpstan, PHPStan's result cache (the plugin's {{cache}}).
# vendor/ and .env come read-only from the main checkout, found through `git rev-parse
# --git-common-dir`, so a linked worktree uses the same vendor/. No compose file is read.
#
# Before the run it deletes <tree>/bootstrap/cache/*.php (a cached provider manifest names packages
# the tree may not have). It keeps <tree>/quality-reports: several commit rows write there and the
# refusal printer reads them all after the last row, so each row deletes only its own artifact.
# It creates the mount points <tree>/vendor and <tree>/.env as the caller, so Docker never creates
# them as root. The container runs as the caller's uid with no network.
#
# The rule code judging the commit comes from HEAD: HEAD's tests/PHPStan/Rules and tests/Architecture
# are extracted over <tree>, so a staged edit to a rule takes effect from the next commit. Files the
# commit adds there stay.
#
# vendor/ must hold exactly the name and version set of <tree>/composer.lock, the staged lock under
# the commit gate. That lock may differ from HEAD:composer.lock only in application packages; a
# package any dev tool is built from keeps HEAD's version (quality/bin/lock-check.sh, read from HEAD).
# A commit that changes a tool package therefore needs a human's qg override.
#
# Exit: the command's own exit code · 2 bad arguments, <tree> missing or the working checkout,
# vendor/ or .env missing, vendor/ not matching <tree>/composer.lock, or a tool package changed
set -euo pipefail

if [ "$#" -lt 3 ]; then
    echo "usage: in-tree.sh <tree> <cache> <cmd...>" >&2
    exit 2
fi

tree="$1"
cache="$2"
shift 2

if [ ! -d "$tree" ]; then
    echo "in-tree.sh: tree $tree does not exist" >&2
    exit 2
fi
tree="$(cd "$tree" && pwd -P)"

common_dir="$(git rev-parse --path-format=absolute --git-common-dir)"
repo="$(dirname "$common_dir")"

# Rule code from HEAD is extracted over <tree>; on a checkout that would overwrite uncommitted edits.
top="$(git rev-parse --show-toplevel 2>/dev/null)" || top=''
if [ "$tree" = "$(cd "$repo" && pwd -P)" ] || { [ -n "$top" ] && [ "$tree" = "$(cd "$top" && pwd -P)" ]; }; then
    echo "in-tree.sh: $tree is a working checkout; in-tree.sh measures a copy of the staged tree only" >&2
    exit 2
fi

for required in "$repo/vendor" "$repo/.env"; do
    if [ ! -e "$required" ]; then
        echo "in-tree.sh: $required does not exist; the tree cannot boot without it" >&2
        exit 2
    fi
done

lock_lib="$(git show HEAD:quality/bin/lock-check.sh 2>/dev/null)" \
    || { echo "in-tree.sh: HEAD has no quality/bin/lock-check.sh" >&2; exit 2; }
# shellcheck source=lock-check.sh
. <(printf '%s\n' "$lock_lib")
head_lock="$(mktemp)"
trap 'rm -f "$head_lock"' EXIT
git show HEAD:composer.lock > "$head_lock" 2>/dev/null || { echo "in-tree.sh: HEAD has no composer.lock" >&2; exit 2; }
lock_check_vendor "$tree/composer.lock" "$repo/vendor" || exit 2
lock_check_tools "$head_lock" "$tree/composer.lock" || exit 2

rule_dirs="$(git ls-tree -d --name-only HEAD -- tests/PHPStan/Rules tests/Architecture 2>/dev/null)" || rule_dirs=''
if [ -n "$rule_dirs" ]; then
    # shellcheck disable=SC2086  # one directory per word, none holds a space
    git archive --format=tar HEAD -- $rule_dirs | tar -x -C "$tree"
fi

mkdir -p "$cache"
cache="$(cd "$cache" && pwd -P)"

rm -f "$tree"/bootstrap/cache/*.php
mkdir -p "$tree/quality-reports" "$tree/vendor"
[ -e "$tree/.env" ] || : > "$tree/.env"

# With --network none every *_HOST in .env stalls Laravel's boot on a DNS timeout (~80 s); point them at loopback.
host_env=()
while IFS= read -r key; do host_env+=(-e "${key}=127.0.0.1"); done \
    < <(sed -n 's/^\([A-Z0-9_]*_HOST\)=.*/\1/p' "$repo/.env" 2>/dev/null)

# exec replaces this shell, so the EXIT trap would never remove the copy of HEAD's lock.
rm -f "$head_lock"
exec docker run --rm --network none \
    --user "$(id -u):$(id -g)" \
    -e HOME=/tmp \
    "${host_env[@]}" \
    -v "$tree:/app" \
    -v "$repo/vendor:/app/vendor:ro" \
    -v "$repo/.env:/app/.env:ro" \
    -v "$cache:/tmp/phpstan" \
    -w /app \
    recycling-api-server:latest \
    nice -n 15 "$@"
