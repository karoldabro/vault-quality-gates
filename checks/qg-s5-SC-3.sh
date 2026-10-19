#!/usr/bin/env bash
# S5 SC-3 — delivery: a scratch clone of ~/vault/givore, gated with this checkout's docs profile,
# accepts a commit appending a clean paragraph to support/support-kb.md and refuses one adding a
# sentence over 30 words. The real ~/vault/givore is only read.
#
# Run by the operator: the agent hook refuses `qg init`.
# Exit 0 pass, 1 fail, 2 could not run.
set -uo pipefail
exec < /dev/null
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${HOME}/vault/givore"
KB=support/support-kb.md
[ -d "${SRC}/.git" ] || { printf 'no repo at %s\n' "$SRC"; exit 2; }
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
git clone -q "$SRC" "${tmp}/v" || { printf 'clone failed\n'; exit 2; }
cd "${tmp}/v" || exit 2
git config user.name 'qg check'; git config user.email 'qg-check@localhost'
"${ROOT}/bin/qg" init --profile docs > "${tmp}/init.out" 2>&1 || { cat "${tmp}/init.out"; exit 2; }
"${ROOT}/bin/qg" hooks install > "${tmp}/hooks.out" 2>&1 || { cat "${tmp}/hooks.out"; exit 2; }
git add quality && git commit -qm 'gate documents' > "${tmp}/c0.out" 2>&1 || { cat "${tmp}/c0.out"; exit 2; }
[ -f "$KB" ] || { printf '%s is missing in the clone\n' "$KB"; exit 2; }

bad=0
printf '\nThe gate check adds this short line.\n' >> "$KB"
if git commit -qam 'clean paragraph' > "${tmp}/c1.out" 2>&1; then
    printf '  ok       a clean paragraph in %s is accepted\n' "$KB"
else
    printf '  FAILING  a clean paragraph in %s was refused:\n' "$KB"; tail -20 "${tmp}/c1.out"; bad=1
fi
long='This sentence exists only so that the gate check can prove the commit gate refuses a new sentence that runs well past the thirty word ceiling the document standard sets for every contract document in the vault.'
printf '\n%s\n' "$long" >> "$KB"
if git commit -qam 'long sentence' > "${tmp}/c2.out" 2>&1; then
    printf '  FAILING  a 37-word sentence in %s was accepted\n' "$KB"; bad=1
elif grep -q 'doc-lint' "${tmp}/c2.out"; then
    printf '  ok       a 37-word sentence in %s is refused by doc-lint\n' "$KB"
else
    printf '  FAILING  the commit failed without naming doc-lint:\n'; tail -20 "${tmp}/c2.out"; bad=1
fi
exit "$bad"
