#!/usr/bin/env bash
# S6 SC-7 — a v1 checks.tsv exits 2 naming the file and `qg doctor --all-branches`; a gate key only
# in VAULT.md reads as unset; `qg migrate` is unknown; no v1 reader code remains.
#
# Exit 0 pass, 1 fail, 2 could not run.
set -uo pipefail
exec < /dev/null
. "$(dirname "${BASH_SOURCE[0]}")/_qg-cases.sh"
qg_cases \
    guard-metrics.bats \
    "a v1 checks.tsv header exits 2 naming the file and qg doctor --all-branches" \
    -- qg-cli.bats \
    "a gate key only in VAULT.md reads as unset" \
    "qg migrate is an unknown subcommand"
rc=$?
[ "$rc" -eq 0 ] || exit "$rc"
left="$(cd "$QG_CHECKS_ROOT" && grep -rnE 'qg_on_from_v1|GUARD_CHECKS_HEADER([^_]|$)|GUARD_WHY_FALLBACK|qg_migrate' bin lib templates extend drivers)"
if [ -n "$left" ]; then printf 'v1 reader code remains:\n%s\n' "$left"; exit 1; fi
printf 'no v1 reader code remains\n'
