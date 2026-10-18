#!/usr/bin/env bash
# apply.sh <recycling-api checkout> — copies the prepared v2 gate files of this folder into the
# checkout's quality/ and prints the steps that finish the migration. It commits nothing: the commit
# that changes the gate configuration is a human's, made with qg override.
#
# Copies: checks.tsv -> quality/checks.tsv, config -> quality/config, in-tree.sh, in-server.sh and
# lock-check.sh -> quality/bin/. The rows that need a fresh baseline come from parity.tsv, the table
# the last run of checks/qg-parity-recycling-api.sh wrote.
#
# Under CLAUDECODE or AI_AGENT it refuses any checkout outside the real path of /tmp: an agent may
# rehearse the copy on a scratch clone, never apply it.
#
# Exit: 0 copied · 2 bad arguments, a refused checkout, or a checkout that is not a v1 recycling-api
set -euo pipefail

here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
[ "$#" -eq 1 ] && [ -d "$1" ] || { echo "usage: apply.sh <recycling-api checkout>" >&2; exit 2; }
target="$(cd "$1" && pwd -P)"

if [ -n "${CLAUDECODE+set}" ] || [ -n "${AI_AGENT+set}" ]; then
    tmp="$(cd /tmp && pwd -P)"
    case "$target/" in "$tmp"/*) ;; *)
        echo "apply.sh: agents may not apply the migration to $target; a human runs it" >&2; exit 2 ;;
    esac
fi

[ "$(git -C "$target" rev-parse --show-toplevel 2>/dev/null)" = "$target" ] \
    || { echo "apply.sh: $target is not the top of a git checkout" >&2; exit 2; }
[ -f "$target/quality/bin/in-tree.sh" ] && [ -f "$target/quality/phpstan-strict.neon" ] \
    || { echo "apply.sh: $target does not look like recycling-api (no quality/bin/in-tree.sh)" >&2; exit 2; }
[ "$(head -1 "$target/quality/checks.tsv" 2>/dev/null)" = "$(printf 'id\tscope\tkind\tcommand\tparser\tartifact\tdirection\tthreshold\tgate')" ] \
    || { echo "apply.sh: $target/quality/checks.tsv is not the v1 file this migration replaces" >&2; exit 2; }

[ -r "$here/parity.tsv" ] \
    || { echo "apply.sh: $here/parity.tsv is missing; run checks/qg-parity-recycling-api.sh first" >&2; exit 2; }

cp "$here/checks.tsv" "$target/quality/checks.tsv"
cp "$here/config" "$target/quality/config"
for f in in-tree.sh in-server.sh lock-check.sh; do
    cp "$here/$f" "$target/quality/bin/$f"
    chmod +x "$target/quality/bin/$f"
done

# Repo rows that took a new id have no baseline line yet; parity.tsv columns: id, new id, kind, verdict.
new_ids="$(awk -F'\t' 'NR > 1 && $2 != $1 && $2 != "-" && $3 == "repo" { printf "%s%s", sep, $2; sep = "," }' "$here/parity.tsv")"
container="format-files,insights-code,insights-complexity,insights-architecture,insights-style,phpstan-errors-all,indication-checks,deps-shadow,deps-unused"

cat <<EOF
apply.sh: copied the v2 gate files into $target/quality. Nothing is committed.

Finish the migration, in this order:
  1. cd $target && git diff -- quality/        (review the change)
  2. git add quality/checks.tsv quality/config quality/bin/in-tree.sh quality/bin/in-server.sh quality/bin/lock-check.sh
  3. qg override --reason "migrate the gate config to v2"
  4. git commit -m "chore(quality): gate config v2"      (within 10 minutes of step 3)
EOF
if [ -n "$new_ids" ]; then
    cat <<EOF
  5. Once git status --short prints nothing: qg baseline --only $new_ids
     then check each id is in quality/baseline.tsv, and commit quality/baseline.tsv the same way.
EOF
else
    echo "  5. No repo row took a new id, so no baseline line needs adding."
fi
cat <<EOF
  6. Before the first push: qg run push --only $container
     (each release row starts a fresh server container on this folder; the database must be up for mutation and tests-suite).
Then merge the branch into master, and delete branch quality/release-rows-in-container: its rows are replaced.
EOF
