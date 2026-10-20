#!/usr/bin/env bash
# S6 SC-3 — delivery: this branch's engine (sandboxed) and main's engine each run on a fresh scratch
# clone of recycling_mobile_app at release/1.17.0 and app.givore.com at release/1.19.0, with
# `qg run push` and `qg run baseline --only` the suite and mutation rows. Every row must give the
# same id, value and status, every compared row must be measured, and nothing under ~/.pub-cache or
# the Flutter SDK may change except the SDK's bin/cache stamps and lockfile. In the app.givore.com
# clones a staged one-line change runs `qg run commit --json` on both engines: the rows must match
# and `typecheck-new`, whose runner links node_modules into the staged tree, must be measured. The
# real checkouts are only read.
#
# Run by the operator: the agent hook refuses scripts that set QG_* names.
# Exit 0 pass, 1 fail, 2 could not run.
set -uo pipefail
exec < /dev/null
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAIN="${HOME}/workspace/vault-quality-gates"
[ -x "${MAIN}/bin/qg" ] || { printf 'no main engine at %s\n' "$MAIN"; exit 2; }
[ "$(git -C "$MAIN" rev-parse HEAD)" != "$(git -C "$ROOT" rev-parse HEAD)" ] || { printf 'main already holds this branch; nothing to compare\n'; exit 2; }
command -v jq > /dev/null || { printf 'jq is not on PATH\n'; exit 2; }
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
touch "${tmp}/mark"
bad=0

# clone <src> <ref> <dest>, plus node setup for nuxt repos
clone() {
    git clone -q --branch "$2" "$1" "$3" || return 2
    if [ -f "${3}/nuxt.config.ts" ]; then
        (cd "$3" && pnpm install --frozen-lockfile --ignore-scripts > /dev/null && pnpm exec nuxt prepare > /dev/null) || return 2
    fi
}

# measure <engine qg> <clone> <out prefix> <baseline rows>
measure() {
    (cd "$2" && "$1" run push --json > "${3}.push.json" 2> "${3}.push.err")
    (cd "$2" && "$1" run baseline --only "$4" --json > "${3}.base.json" 2> "${3}.base.err")
    jq -r '.rows[] | "\(.id)|\(.value)|\(.status)"' "${3}.push.json" "${3}.base.json" | sort
}

# measure_commit <engine qg> <clone> <out prefix> -> stages a one-line change to the first tracked
# .ts file under composables/ or utils/, runs the commit rows, prints id|value|status, and unstages.
measure_commit() {
    local f
    f="$(cd "$2" && git ls-files | grep -E '^(composables|utils)/.*\.ts$' | head -1)"
    [ -n "$f" ] || return 2
    (cd "$2" && printf '// qg-s6-SC-3\n' >> "$f" && git add "$f" \
        && "$1" run commit --json > "${3}.commit.json" 2> "${3}.commit.err"; git reset -q -- "$f"; git checkout -q -- "$f")
    jq -r '.rows[] | "\(.id)|\(.value)|\(.status)"' "${3}.commit.json" | sort
}

run_new() {   # <name> <src> <ref> <baseline rows>; this branch's engine first, before main touches the SDK
    clone "$2" "$3" "${tmp}/${1}-new" || { printf 'clone of %s failed\n' "$1"; exit 2; }
    measure "${ROOT}/bin/qg" "${tmp}/${1}-new" "${tmp}/${1}-new" "$4" > "${tmp}/${1}-new.rows"
    [ "$1" != app ] || measure_commit "${ROOT}/bin/qg" "${tmp}/${1}-new" "${tmp}/${1}-new" > "${tmp}/${1}-new.commit.rows"
}

compare() {   # <name> <src> <ref> <baseline rows>
    local name="$1" new old
    clone "$2" "$3" "${tmp}/${name}-old" || { printf 'clone of %s failed\n' "$name"; exit 2; }
    new="$(cat "${tmp}/${name}-new.rows")"
    old="$(measure "${MAIN}/bin/qg" "${tmp}/${name}-old" "${tmp}/${name}-old" "$4")"
    [ -n "$new" ] || { printf '%s: this engine printed no rows\n' "$name"; tail -20 "${tmp}/${name}-new.push.err"; exit 2; }
    if [ "$new" = "$old" ]; then printf '  ok       %s: same rows on both engines\n' "$name"
    else printf '  FAILING  %s: rows differ (< this branch, > main):\n' "$name"; diff <(printf '%s\n' "$new") <(printf '%s\n' "$old"); bad=1; fi
    if grep -v '|measured$' <<<"$new" | grep -q .; then
        printf '  FAILING  %s: rows not measured:\n' "$name"; grep -v '|measured$' <<<"$new"; bad=1
    fi
    if grep -rqs '^sandbox: armed' "${tmp}/${name}-new/.git/qg-last"; then printf '  ok       %s: rows ran inside qg-sandbox\n' "$name"
    else printf '  FAILING  %s: no row log records sandbox: armed\n' "$name"; bad=1; fi
    [ "$name" = app ] || return 0
    new="$(cat "${tmp}/${name}-new.commit.rows")"
    old="$(measure_commit "${MAIN}/bin/qg" "${tmp}/${name}-old" "${tmp}/${name}-old")"
    [ -n "$new" ] || { printf '%s: this engine printed no commit rows\n' "$name"; tail -20 "${tmp}/${name}-new.commit.err"; exit 2; }
    if [ "$new" = "$old" ]; then printf '  ok       %s: same commit rows on both engines\n' "$name"
    else printf '  FAILING  %s: commit rows differ (< this branch, > main):\n' "$name"; diff <(printf '%s\n' "$new") <(printf '%s\n' "$old"); bad=1; fi
    if grep -q '^typecheck-new|.*|measured$' <<<"$new"; then printf '  ok       %s: typecheck-new measured on a staged commit\n' "$name"
    else printf '  FAILING  %s: typecheck-new is not measured on a staged commit\n' "$name"; grep '^typecheck-new|' <<<"$new"; bad=1; fi
}

MOBILE="${HOME}/workspace/recycling_mobile_app"
APP="${HOME}/workspace/app.givore.com"
[ -d "${MOBILE}/.git" ] && [ -d "${APP}/.git" ] || { printf 'a source repo is missing\n'; exit 2; }
sdk="$(git -C "$MOBILE" show release/1.17.0:quality/config | sed -n 's/^guard_flutter_root:[[:space:]]*//p')"
[ -x "${sdk}/bin/cache/dart-sdk/bin/dart" ] || { printf 'no Flutter SDK at %s\n' "$sdk"; exit 2; }

run_new mobile "$MOBILE" release/1.17.0 mutation
run_new app "$APP" release/1.19.0 tests-suite-failed,mutation

changed="$(find "${HOME}/.pub-cache" "$sdk" -type f -newer "${tmp}/mark" ! -path "${sdk}/bin/cache/*.stamp" ! -path "${sdk}/bin/cache/lockfile" -print)"
if [ -z "$changed" ]; then printf '  ok       ~/.pub-cache and the SDK are unchanged by the sandboxed runs\n'
else printf '  FAILING  files changed under ~/.pub-cache or the SDK:\n%s\n' "$changed"; bad=1; fi

compare mobile "$MOBILE" release/1.17.0 mutation
compare app "$APP" release/1.19.0 tests-suite-failed,mutation
exit "$bad"
