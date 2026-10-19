#!/usr/bin/env bash
# apply.sh <recycling_mobile_app checkout> — copies the prepared v2 gate files of this folder into the
# checkout and prints the steps that finish the migration. It commits nothing: the commit that changes
# the gate configuration is a human's, made with qg override.
#
# Copies: checks.tsv -> quality/checks.tsv, config -> quality/config, commit-lint.sh ->
# quality/bin/commit-lint.sh. The renamed repo rows that need a baseline line come from parity.tsv, the
# table the last run of checks/qg-parity-recycling_mobile_app.sh wrote; a row with no v1 id (kind new)
# is never offered to qg baseline.
#
# Refuses, copying nothing, when:
#   - CLAUDECODE or AI_AGENT is set (even empty) and the checkout lies outside the real path of /tmp:
#     an agent may rehearse the copy on a scratch clone, never apply it;
#   - the checkout is not the top of a recycling_mobile_app checkout whose quality/checks.tsv is v1;
#   - .git/hooks/pre-commit or pre-push has no GUARD= line, the two name different engines, or that
#     engine's drivers/ lacks a driver checks.tsv names: the first commit would then refuse every row;
#   - guard_flutter_root in config is not a Flutter SDK on this machine: every Dart row would refuse;
#   - parity.tsv is absent, or holds a row whose verdict is not SAME or NEW.
#
# Exit: 0 copied · 2 bad arguments or a refusal
set -euo pipefail

here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO=recycling_mobile_app
# v1 files that identify a recycling_mobile_app checkout.
V1_MARKERS='quality/bin/commit-lint.sh tool/lcov_summary.dart tool/givore_lints/bin/gate.dart'
V1_HEADER="$(printf 'id\tscope\tkind\tcommand\tparser\tartifact\tdirection\tthreshold\tgate')"

die() { printf 'apply.sh: %s\n' "$1" >&2; exit 2; }

[ "$#" -eq 1 ] && [ -d "$1" ] || die "usage: apply.sh <${REPO} checkout>"
target="$(cd "$1" && pwd -P)"

if [ -n "${CLAUDECODE+set}" ] || [ -n "${AI_AGENT+set}" ]; then
    tmp="$(cd /tmp && pwd -P)"
    case "$target/" in "$tmp"/*) ;; *) die "agents may not apply the migration to $target; a human runs it" ;; esac
fi

[ "$(git -C "$target" rev-parse --show-toplevel 2>/dev/null)" = "$target" ] || die "$target is not the top of a git checkout"
for f in $V1_MARKERS; do
    [ -f "$target/$f" ] || die "$target does not look like ${REPO} (no $f)"
done
[ "$(head -1 "$target/quality/checks.tsv" 2>/dev/null)" = "$V1_HEADER" ] \
    || die "$target/quality/checks.tsv is not the v1 file this migration replaces"

# The engine the hooks call must know every driver the new rows name.
hooks="$(git -C "$target" rev-parse --path-format=absolute --git-common-dir)/hooks"
engine=''
for h in pre-commit pre-push; do
    g="$(sed -n 's/^GUARD="\(.*\)"$/\1/p' "$hooks/$h" 2>/dev/null | head -1)"
    [ -n "$g" ] || die "$hooks/$h has no GUARD= line; run qg hooks install first"
    e="$(dirname "$(dirname "$g")")"
    [ -z "$engine" ] || [ "$engine" = "$e" ] || die "$hooks/pre-commit and pre-push call different engines ($engine, $e)"
    engine="$e"
done
for d in $(awk -F'\t' 'NR > 1 && $0 !~ /^#/ && $3 != "absent" && $4 != "shell" { print $4 }' "$here/checks.tsv" | sort -u); do
    [ -x "$engine/drivers/$d.sh" ] || die "the engine at $engine has no driver $d; update it to a release with the S4 Flutter drivers first"
done

root="$(sed -n 's/^guard_flutter_root:[[:space:]]*//p' "$here/config" | head -1 | sed 's/[[:space:]]*$//')"
[ -x "$root/bin/flutter" ] && [ -x "$root/bin/cache/dart-sdk/bin/dart" ] \
    || die "guard_flutter_root ${root:-(unset)} in $here/config is not a Flutter SDK on this machine; edit config first"

[ -r "$here/parity.tsv" ] || die "$here/parity.tsv is missing; run checks/qg-parity-${REPO}.sh first"
bad="$(awk -F'\t' 'NR == 1 { for (i = 1; i <= NF; i++) if ($i == "verdict") v = i; next }
    v && $v != "SAME" && $v != "NEW" { printf "%s%s=%s", sep, ($1 == "-" ? $2 : $1), $v; sep = " " }
    END { if (!v) print "no verdict column" }' "$here/parity.tsv")"
[ -z "$bad" ] || die "parity.tsv has rows that are not proven: $bad"
[ -d "$target/quality/bin" ] || die "$target/quality/bin does not exist; nothing was copied"

cp "$here/checks.tsv" "$target/quality/checks.tsv"
cp "$here/config" "$target/quality/config"
cp "$here/commit-lint.sh" "$target/quality/bin/commit-lint.sh"
chmod +x "$target/quality/bin/commit-lint.sh"

# Renamed repo rows have no baseline line yet; parity.tsv columns: id, new id, kind, verdict. A row with
# no v1 id carries kind new and is skipped here.
new_ids="$(awk -F'\t' 'NR > 1 && $1 != "-" && $2 != $1 && $3 == "repo" { printf "%s%s", sep, $2; sep = "," }' "$here/parity.tsv")"

cat <<EOF
apply.sh: copied the v2 gate files into $target/quality. Nothing is committed.

Finish the migration, in this order:
  1. cd $target && git diff -- quality/        (review the change)
  2. git add quality/checks.tsv quality/config quality/bin/commit-lint.sh
  3. qg override --reason "migrate the gate config to v2"
  4. git commit -m "chore(quality): gate config v2"      (within 10 minutes of step 3)
EOF
if [ -n "$new_ids" ]; then
    printf '  5. Once git status --short prints nothing: qg baseline --only %s\n' "$new_ids"
    printf '     then check each id is in quality/baseline.tsv, and commit quality/baseline.tsv the same way.\n'
else
    printf '  5. No repo row took a new id, so no baseline line needs adding.\n'
fi
cat <<EOF
  6. Before the first push: qg run push
     (it runs the whole Flutter suite with coverage; packages resolve offline, so run flutter pub get first).

A commit that changes the locked version of dart_code_linter, lakos, mutation_test, flutter_lints or
lints, or turns any package into a path or git package, is refused by dart-tools-changed until a human
runs qg override for it.
EOF
