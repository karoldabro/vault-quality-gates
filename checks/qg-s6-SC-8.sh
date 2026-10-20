#!/usr/bin/env bash
# S6 SC-8 — delivery: `qg doctor --all-branches` exits 0 in every gated repo, so no branch still
# carries a v1 gate config.
#
# Exit 0 pass, 1 fail, 2 could not run.
set -uo pipefail
exec < /dev/null
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bad=0
for repo in "${HOME}/workspace/recycling-api" "${HOME}/workspace/app.givore.com" \
            "${HOME}/workspace/dashboard.givore.com" "${HOME}/workspace/recycling_mobile_app" \
            "${HOME}/workspace/givore.com" "${HOME}/vault/givore" "${HOME}/workspace/vault-quality-gates"; do
    [ -d "${repo}/.git" ] || { printf 'no repo at %s\n' "$repo"; exit 2; }
    out="$(cd "$repo" && "${ROOT}/bin/qg" doctor --all-branches 2>&1)"; rc=$?
    case "$rc" in
        0) printf '  ok       %s\n' "$repo" ;;
        1) printf '  FAILING  %s:\n%s\n' "$repo" "$out"; bad=1 ;;
        *) printf '  could not run in %s (exit %s):\n%s\n' "$repo" "$rc" "$out"; exit 2 ;;
    esac
done
exit "$bad"
