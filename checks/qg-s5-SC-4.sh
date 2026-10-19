#!/usr/bin/env bash
# S5 SC-4 — delivery: a scratch clone of givore.com, gated with this checkout's hugo profile,
# passes `qg run push` at HEAD and fails it once a commit leaves an unclosed action in
# layouts/index.html. The real ~/workspace/givore.com is only read.
#
# Run by the operator: the agent hook refuses `qg init`.
# Exit 0 pass, 1 fail, 2 could not run.
set -uo pipefail
exec < /dev/null
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${HOME}/workspace/givore.com"
LAYOUT=layouts/index.html
[ -d "${SRC}/.git" ] || { printf 'no repo at %s\n' "$SRC"; exit 2; }
command -v hugo > /dev/null || { printf 'hugo is not on PATH\n'; exit 2; }
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
git clone -q "$SRC" "${tmp}/site" || { printf 'clone failed\n'; exit 2; }
cd "${tmp}/site" || exit 2
git config user.name 'qg check'; git config user.email 'qg-check@localhost'
"${ROOT}/bin/qg" init --profile hugo > "${tmp}/init.out" 2>&1 || { cat "${tmp}/init.out"; exit 2; }
"${ROOT}/bin/qg" hooks install > "${tmp}/hooks.out" 2>&1 || { cat "${tmp}/hooks.out"; exit 2; }
git add quality && git commit -qm 'gate the site build' > "${tmp}/c0.out" 2>&1 || { cat "${tmp}/c0.out"; exit 2; }
[ -f "$LAYOUT" ] || { printf '%s is missing in the clone\n' "$LAYOUT"; exit 2; }

bad=0
"${ROOT}/bin/qg" run push --only hugo-build > "${tmp}/p1.out" 2>&1; rc=$?
if [ "$rc" -eq 0 ]; then printf '  ok       qg run push passes at HEAD\n'
else printf '  FAILING  qg run push exited %s at HEAD:\n' "$rc"; tail -20 "${tmp}/p1.out"; bad=1; fi

printf '{{ if .Site.Title }}\n' >> "$LAYOUT"
git commit -qam 'unclosed action' > "${tmp}/c1.out" 2>&1 || { cat "${tmp}/c1.out"; exit 2; }
"${ROOT}/bin/qg" run push --only hugo-build > "${tmp}/p2.out" 2>&1; rc=$?
if [ "$rc" -eq 1 ]; then printf '  ok       qg run push refuses an unclosed action in %s\n' "$LAYOUT"
else printf '  FAILING  qg run push exited %s on a broken %s (want 1):\n' "$rc" "$LAYOUT"; tail -20 "${tmp}/p2.out"; bad=1; fi
exit "$bad"
