#!/usr/bin/env bash
# S6 SC-3 — delivery: recycling_mobile_app's tests-failed row, run with this checkout's engine on a
# scratch clone at release/1.17.0, is measured inside the sandbox, and no file under ~/.pub-cache or
# the Flutter SDK changes except the SDK's bin/cache stamps and lockfile.
# The real ~/workspace/recycling_mobile_app is only read.
#
# Run by the operator: the agent hook refuses scripts that set QG_* names.
# Exit 0 pass, 1 fail, 2 could not run.
set -uo pipefail
exec < /dev/null
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${HOME}/workspace/recycling_mobile_app"
REF=release/1.17.0
[ -d "${SRC}/.git" ] || { printf 'no repo at %s\n' "$SRC"; exit 2; }
sdk="$(git -C "$SRC" show "${REF}:quality/config" | sed -n 's/^guard_flutter_root:[[:space:]]*//p')"
[ -x "${sdk}/bin/cache/dart-sdk/bin/dart" ] || { printf 'no Flutter SDK at %s\n' "$sdk"; exit 2; }
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
git clone -q --branch "$REF" "$SRC" "${tmp}/app" || { printf 'clone failed\n'; exit 2; }
snap() { find "${HOME}/.pub-cache" "$sdk" -type f ! -path "${sdk}/bin/cache/*.stamp" ! -path "${sdk}/bin/cache/lockfile" -newer "${tmp}/mark" -print; }
touch "${tmp}/mark"
cd "${tmp}/app" || exit 2
"${ROOT}/bin/qg" run push --only tests-failed --json > "${tmp}/run.json" 2> "${tmp}/run.err"; rc=$?
bad=0
if jq -e '.rows[] | select(.id == "tests-failed") | .status == "measured"' "${tmp}/run.json" > /dev/null; then
    printf '  ok       tests-failed is measured (qg exit %s)\n' "$rc"
else
    printf '  FAILING  tests-failed is not measured (qg exit %s):\n' "$rc"; tail -20 "${tmp}/run.err"; bad=1
fi
if grep -q 'qg-sandbox' "${tmp}/run.err" "${tmp}/run.json" || [ -f "${tmp}/app/.git/qg-last/tests-failed/sandbox" ]; then
    printf '  ok       the row ran inside qg-sandbox\n'
else
    printf '  FAILING  no record that the row ran inside qg-sandbox\n'; bad=1
fi
changed="$(snap)"
if [ -z "$changed" ]; then printf '  ok       ~/.pub-cache and the SDK are unchanged\n'
else printf '  FAILING  files changed under ~/.pub-cache or the SDK:\n%s\n' "$changed"; bad=1; fi
exit "$bad"
