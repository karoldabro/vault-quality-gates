#!/usr/bin/env bash
# S5 SC-5 — the two Givore indications on the gate name the qg commands, carry none of the retired
# v1 ones, and pass doc-lint.
#
# Exit 0 pass, 1 fail, 2 could not run.
set -uo pipefail
exec < /dev/null
IND="${HOME}/vault/givore/indications"
FILES="${IND}/quality-gate-binds-every-push.md ${IND}/web/blocking-checks-live-in-checks-tsv.md"
LINT="${VAULT_FRAMEWORK_PATH:-${HOME}/workspace/vault}/bin/doc-lint.sh"
[ -x "$LINT" ] || { printf 'no doc-lint at %s\n' "$LINT"; exit 2; }
bad=0
for f in $FILES; do
    [ -r "$f" ] || { printf 'cannot read %s\n' "$f"; exit 2; }
done
# The commands must be named across the pair; the retired ones in neither.
for want in 'qg explain' 'qg run' 'qg override'; do
    # shellcheck disable=SC2086
    grep -qF -- "$want" $FILES || { printf '  FAILING  neither indication names %s\n' "$want"; bad=1; }
done
for gone in 'QG_SKIP_REASON' 'guard.sh baseline --skip' '.husky/pre-push-guard.bash'; do
    # shellcheck disable=SC2086
    if grep -nF -- "$gone" $FILES; then printf '  FAILING  %s is still named\n' "$gone"; bad=1; fi
done
# shellcheck disable=SC2086
"$LINT" --quiet $FILES || { printf '  FAILING  doc-lint refuses an indication\n'; bad=1; }
[ "$bad" -ne 0 ] || printf 'both indications name qg and pass doc-lint\n'
exit "$bad"
