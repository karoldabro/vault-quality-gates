#!/usr/bin/env bash
# SC-8 — on each gated Givore repo, the new engine gives every commit row the same id, value and
# status as the 43d7082 engine, for one staged change under guard_commit_paths.
#
#   checks/qg-SC-8.sh [--release] [<repo path>...]     default: the four gated Givore repos
#
# --release also compares the push gate: both engines run `release refs/heads/<checked-out branch>`
# on HEAD, as the pre-push hook would. It can take many minutes per repo; a repo that measures its
# working tree needs a clean tree under guard_commit_paths and HEAD on that branch.
#
# The change is staged in a copy of the repo's index (GIT_INDEX_FILE): the working tree and the
# real index are never touched. Both engines write quality-reports/status.json; the rows are
# compared. Exit 0 every row matches, 1 a row differs, 2 a reference row was unmeasurable or a
# repo could not be measured, so "could not measure" never reads as "same".
set -uo pipefail
NEW_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN_GIT="${QG_SC8_PLUGIN_GIT:-$HOME/workspace/vault-quality-gates}"
REF=43d7082
release=0
[ "${1:-}" = --release ] && { release=1; shift; }
repos=("$@")
[ "${#repos[@]}" -gt 0 ] || repos=("$HOME/workspace/recycling-api" "$HOME/workspace/recycling_mobile_app" \
    "$HOME/workspace/app.givore.com" "$HOME/workspace/dashboard.givore.com")

old="$(mktemp -d)"; trap 'rm -rf "$old" "${idx_dir:-}"' EXIT
git -C "$PLUGIN_GIT" archive "$REF" | tar -x -C "$old" || { echo "cannot extract ${REF} from ${PLUGIN_GIT}"; exit 2; }

rows_of() {  # rows_of <status.json> -> "<path to the row> <status> <value>" lines, sorted
    jq -r 'paths(objects) as $p | getpath($p) | select(has("status") and ((.status | type) == "string") and ($p | length) > 0)
           | [($p | map(tostring) | join(".")), .status, ((.value // "-") | tostring)] | join(" ")' "$1" 2>/dev/null | sort
}

worst=0
for repo in "${repos[@]}"; do
    name="$(basename "$repo")"
    cd "$repo" || { echo "$name: cannot enter"; worst=2; continue; }
    prefix="$(git show HEAD:quality/config 2>/dev/null)"
    prefix="$(sed -n 's/^guard_commit_paths:[[:space:]]*//p' <<<"$prefix" | awk '{ print $1 }')"
    file="$(git ls-files -- "${prefix:-.}" | grep -E '\.(php|dart|ts|vue)$' | head -1)"
    [ -n "$file" ] || { echo "$name: no source file under ${prefix:-the repo} to change"; worst=2; continue; }
    idx_dir="$(mktemp -d)"
    cp "$(git rev-parse --git-path index)" "$idx_dir/index"
    case "$file" in *.php|*.dart|*.ts|*.vue) note='// qg SC-8 probe line' ;; esac
    blob="$({ git show "HEAD:$file"; printf '%s\n' "$note"; } | git hash-object -w --stdin)"
    GIT_INDEX_FILE="$idx_dir/index" git update-index --cacheinfo "$(git ls-files -s -- "$file" | awk '{ print $1 }'),${blob},${file}"

    run() {  # run <guard.sh> <out file> -> exit
        local rc=0
        rm -f quality-reports/status.json
        GIT_INDEX_FILE="$idx_dir/index" GUARD_LOCK_WAIT=300 bash "$1" commit > "$2.log" 2>&1 || rc=$?
        [ -r quality-reports/status.json ] && rows_of quality-reports/status.json > "$2" || : > "$2"
        return "$rc"
    }
    rc_old=0; run "$old/bin/guard.sh" "$idx_dir/old" || rc_old=$?
    rc_new=0; run "$NEW_ROOT/bin/guard.sh" "$idx_dir/new" || rc_new=$?

    if grep -q ' unmeasurable ' "$idx_dir/old"; then
        echo "$name: CANNOT SAY — the reference engine could not measure:"; grep ' unmeasurable ' "$idx_dir/old" | sed 's/^/    /'
        [ "$worst" -lt 2 ] && worst=2
    elif [ "$rc_old" -ne "$rc_new" ] || ! cmp -s "$idx_dir/old" "$idx_dir/new"; then
        echo "$name: DIFFERS (exit ${rc_old} -> ${rc_new}, change to ${file})"
        diff "$idx_dir/old" "$idx_dir/new" | sed 's/^/    /'
        [ "$worst" -lt 1 ] && worst=1
    else
        echo "$name: same — $(wc -l < "$idx_dir/old") rows, exit ${rc_old}, change to ${file}"
    fi
    rm -rf "$idx_dir"; idx_dir=''

    if [ "$release" -eq 1 ]; then
        local_ref="refs/heads/$(git symbolic-ref --short -q HEAD || echo detached)"
        sha="$(git rev-parse HEAD)"
        rel_dir="$(mktemp -d)"
        rrun() {  # rrun <guard.sh> <out file> -> exit
            local rc=0
            rm -f quality-reports/status.json
            GUARD_SHA="$sha" GUARD_LOCK_WAIT=300 bash "$1" release "$local_ref" > "$2.log" 2>&1 || rc=$?
            [ -r quality-reports/status.json ] && rows_of quality-reports/status.json > "$2" || : > "$2"
            return "$rc"
        }
        rc_old=0; rrun "$old/bin/guard.sh" "$rel_dir/old" || rc_old=$?
        rc_new=0; rrun "$NEW_ROOT/bin/guard.sh" "$rel_dir/new" || rc_new=$?
        if [ ! -s "$rel_dir/old" ] && [ "$rc_old" -ne 0 ]; then
            echo "$name release: CANNOT SAY — the reference engine stopped before measuring (exit ${rc_old}):"
            tail -3 "$rel_dir/old.log" | sed 's/^/    /'; [ "$worst" -lt 2 ] && worst=2
        elif grep -q ' unmeasurable ' "$rel_dir/old"; then
            echo "$name release: CANNOT SAY — the reference engine could not measure:"; grep ' unmeasurable ' "$rel_dir/old" | sed 's/^/    /'
            [ "$worst" -lt 2 ] && worst=2
        elif [ "$rc_old" -ne "$rc_new" ] || ! cmp -s "$rel_dir/old" "$rel_dir/new"; then
            echo "$name release: DIFFERS (exit ${rc_old} -> ${rc_new}, ${local_ref})"
            diff "$rel_dir/old" "$rel_dir/new" | sed 's/^/    /'; [ "$worst" -lt 1 ] && worst=1
        else
            echo "$name release: same — $(wc -l < "$rel_dir/old") rows, exit ${rc_old}, ${local_ref}"
        fi
        rm -rf "$rel_dir"
    fi
done
exit "$worst"
