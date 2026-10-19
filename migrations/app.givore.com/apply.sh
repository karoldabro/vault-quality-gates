#!/usr/bin/env bash
# apply.sh <app.givore.com checkout> — copies the prepared v2 gate files of this folder into the
# checkout's quality/ and prints the steps that finish the migration. It commits nothing: the commit
# that changes the gate configuration is a human's, made with qg override.
# apply.sh --branch-steps — prints, per branch, the steps that bring master and development onto the
# v2 config after the release pull request merges into them, from branches.tsv. It copies nothing.
#
# Copies: checks.tsv -> quality/checks.tsv, config -> quality/config, jscpd.json -> quality/jscpd.json,
# README.md -> quality/README.md, and ../web/in-node.sh -> quality/bin/in-node.sh.
#
# Refuses, copying nothing, when:
#   - CLAUDECODE or AI_AGENT is set (even empty) and the checkout lies outside the real path of /tmp:
#     an agent may rehearse the copy on a scratch clone, never apply it;
#   - the checkout is not the top of an app.givore.com checkout whose quality/checks.tsv is v1;
#   - .git/hooks/pre-commit or pre-push has no GUARD= line, the two name different engines, or that
#     engine's drivers/ lacks a driver checks.tsv names: the first commit would then refuse every row;
#   - parity.tsv, which checks/qg-parity-app.givore.com.sh writes, is absent or holds a row whose
#     verdict is not SAME or NEW, or a value that was not measured.
#
# branches.tsv columns: branch branch-sha release-sha merge-sha conflicts id value status release-baseline
#
# Exit: 0 copied or printed · 2 bad arguments or a refusal
set -euo pipefail

here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO=app.givore.com
BRANCHES='master development'
# v1 scripts that identify an app.givore.com checkout.
V1_MARKERS='quality/bin/commit-check.sh scripts/quality-metric.mjs'
V1_HEADER="$(printf 'id\tscope\tkind\tcommand\tparser\tartifact\tdirection\tthreshold\tgate')"

die() { printf 'apply.sh: %s\n' "$1" >&2; exit 2; }

# cell <id> <column number> -> that cell of the row in this folder's checks.tsv.
cell() { awk -F'\t' -v id="$1" -v c="$2" 'NR > 1 && $0 !~ /^#/ && $1 == id { print $c; exit }' "$here/checks.tsv"; }

branch_steps() {
    local tsv="$here/branches.tsv" out='' branch ids rows
    [ -r "$tsv" ] || die "$tsv is missing; run checks/qg-parity-${REPO}.sh first"
    for branch in $BRANCHES; do
        rows="$(awk -F'\t' -v b="$branch" 'NR > 1 && $1 == b' "$tsv")"
        [ -n "$rows" ] || die "branches.tsv has no row for $branch"
        # A row whose value is not a number, or whose status says so, was not measured on that merge.
        if awk -F'\t' '$7 !~ /^-?[0-9]+(\.[0-9]+)?$/ || $8 == "unmeasurable" { bad = 1 } END { exit !bad }' <<<"$rows"; then
            die "branches.tsv: a row on $branch was not measured; rerun checks/qg-parity-${REPO}.sh"
        fi
        ids=''
        while IFS=$'\t' read -r _ _ _ _ _ id value _ base; do
            [ "$(cell "$id" 3)" = repo ] || continue
            [[ "$base" =~ ^-?[0-9]+(\.[0-9]+)?$ ]] || continue
            if awk -v v="$value" -v b="$base" -v d="$(cell "$id" 6)" 'BEGIN { exit !((d == "down" && v > b) || (d == "up" && v < b)) }'; then
                ids+="${ids:+,}$id"
            fi
        done <<<"$rows"
        out+="On ${branch} (merge $(cut -f4 <<<"${rows%%$'\n'*}")), after the release pull request merges into it on GitHub:"$'\n'
        out+="  1. git checkout ${branch} && git pull && pnpm install"$'\n'
        if [ -n "$ids" ]; then
            out+="  2. qg baseline --only ${ids}"$'\n'
            out+="  3. qg override --reason \"baseline ${branch} after the v2 merge\", then commit quality/baseline.tsv within 10 minutes"$'\n'
            out+="  4. only then push ${branch} from this machine"$'\n'
        else
            out+="  2. no repo row on ${branch} is worse than the release baseline; no baseline step"$'\n'
        fi
    done
    printf '%s' "$out"
}

if [ "${1:-}" = --branch-steps ]; then
    [ "$#" -eq 1 ] || die 'usage: apply.sh --branch-steps'
    branch_steps
    exit 0
fi

[ "$#" -eq 1 ] && [ -d "$1" ] || die "usage: apply.sh <${REPO} checkout> | --branch-steps"
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
    [ -x "$engine/drivers/$d.sh" ] || die "the engine at $engine has no driver $d; update it to a release with the S3 drivers first"
done

[ -r "$here/../web/in-node.sh" ] || die "$here/../web/in-node.sh is missing"
[ -r "$here/parity.tsv" ] || die "$here/parity.tsv is missing; run checks/qg-parity-${REPO}.sh first"
bad="$(awk -F'\t' 'NR == 1 { for (i = 1; i <= NF; i++) if ($i == "verdict") v = i; next }
    v && ($v != "SAME" && $v != "NEW" || $0 ~ /unmeasurable/) { printf "%s%s=%s", sep, $1, $v; sep = " " }
    END { if (!v) print "no verdict column" }' "$here/parity.tsv")"
[ -z "$bad" ] || die "parity.tsv has rows that are not proven: $bad"

mkdir -p "$target/quality/bin"
cp "$here/checks.tsv" "$target/quality/checks.tsv"
cp "$here/config" "$target/quality/config"
cp "$here/jscpd.json" "$target/quality/jscpd.json"
cp "$here/README.md" "$target/quality/README.md"
cp "$here/../web/in-node.sh" "$target/quality/bin/in-node.sh"
chmod +x "$target/quality/bin/in-node.sh"

# Repo rows that took a new id have no baseline line yet; parity.tsv columns: id, new id, kind, verdict.
new_ids="$(awk -F'\t' 'NR > 1 && $2 != $1 && $2 != "-" && $3 == "repo" { printf "%s%s", sep, $2; sep = "," }' "$here/parity.tsv")"

cat <<EOF
apply.sh: copied the v2 gate files into $target/quality. Nothing is committed.

Finish the migration, in this order:
  1. cd $target && git diff -- quality/        (review the change)
  2. git add quality/checks.tsv quality/config quality/jscpd.json quality/README.md quality/bin/in-node.sh
  3. qg override --reason "migrate the gate config to v2"
  4. git commit -m "chore(quality): gate config v2"      (within 10 minutes of step 3)
EOF
if [ -n "$new_ids" ]; then
    printf '  5. qg baseline --only %s, then commit quality/baseline.tsv the same way.\n' "$new_ids"
else
    printf '  5. No repo row took a new id, so no baseline line needs adding.\n'
fi
cat <<EOF
  6. In package.json, change guard:baseline's --skip to '^(mutation|tests-suite-failed)\$' and commit it:
     tests-suite took the id tests-suite-failed.
  7. Before the first push: qg run push
  8. After the release pull request merges into master and development: apply.sh --branch-steps

A commit that changes a dev tool, an eslint plugin, nuxt or @nuxt/cli in pnpm-lock.yaml is refused
by tools-changed until a human runs qg override for it.

No row runs these v1 scripts any more; delete them in a later commit under qg override:
  quality/bin/commit-check.sh
  scripts/quality-metric.mjs modes lint, mess, typecheck, architecture, deadcode, dupes-semantic,
    boundaries, complexity-excess, tests-failing, mutation (repo-consistency and coverage-age-days
    still call consistency and coverage-age-days)
EOF
