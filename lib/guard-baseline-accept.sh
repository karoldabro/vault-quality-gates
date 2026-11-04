#!/usr/bin/env bash
# The operator's acceptance of a looser quality/baseline.tsv, and the built-in baseline lock that
# reads it. Sourced by bin/guard.sh after guard-metrics.sh and guard-pass.sh; defines functions only.
#
# `qg baseline`, run by a human at a terminal, appends one tab-separated line to
# <git-common-dir>/qg-baseline-accept:
#   <blob> <user> <epoch> <reason>
# <blob> is `git hash-object --no-filters` of the quality/baseline.tsv it wrote. The commit gate and
# the push gate pass a baseline that loosens its base when its blob has a line here. A hand edit of
# the file, or a baseline an agent wrote under a grant, has no line and stays refused.

# shellcheck source=guard-override.sh
. "${GUARD_LIB_DIR}/guard-override.sh"

guard_baseline_accept_file() { printf '%s/qg-baseline-accept' "$(guard_common_dir)"; }

# guard_baseline_accept_write <baseline path> <reason> -> 0 and the record written and logged when a
# human at a terminal runs this; 1 and nothing written otherwise. No grant writes a record.
guard_baseline_accept_write() {
    local path="$1" reason="$2" blob
    guard_override_allowed "$reason" || return 1
    blob="$(git hash-object --no-filters -- "$path" 2>/dev/null)" || return 1
    printf '%s\t%s\t%s\t%s\n' "$blob" "$(_guard_override_field "${USER:-$(id -un 2>/dev/null)}")" \
        "$(date +%s)" "$(_guard_override_field "$reason")" >> "$(guard_baseline_accept_file)" || return 1
    QG_OVERRIDE_REASON="$reason" guard_override_log "qg baseline accepted quality/baseline.tsv ${blob:0:12} as the new floor"
}

# guard_baseline_accepted <baseline path> -> 0 and prints `<user>, <UTC date>: <reason>` when the
# file's blob has a record; 1 otherwise. A record file that is not a regular file counts as none.
guard_baseline_accepted() {
    local file blob b user epoch reason found=''
    file="$(guard_baseline_accept_file)"
    [ -f "$file" ] && [ ! -L "$file" ] || return 1
    blob="$(git hash-object --no-filters -- "$1" 2>/dev/null)" || return 1
    while IFS=$'\t' read -r b user epoch reason; do
        [ "$b" = "$blob" ] && [[ "$epoch" =~ ^[0-9]+$ ]] && found="${user}, $(date -u -d "@${epoch}" +%Y-%m-%d 2>/dev/null): ${reason}"
    done < "$file"
    [ -n "$found" ] || return 1
    printf '%s' "${found//|/ }"
}

# guard_baseline_lock <old> <new> <checks> -> 0 when <new> does not loosen <old>, or loosens it
# with a record from guard_baseline_accept_write (an `ok` result names who accepted it); 1 with a
# `worse` baseline-loosened result otherwise. A checks.tsv that does not load is never accepted.
guard_baseline_lock() {
    local old="$1" new="$2" checks="$3" lines summary who
    lines="$(guard_baseline_diff "$old" "$new" "$checks")" && return 0
    summary="$(awk -F'\t' '{ printf "%s%s %s -> %s (%s)", (NR > 1 ? "; " : ""), $1, $2, $3, $4 }' <<<"$lines" | tr '|' ' ')"
    if ! grep -q $'^quality/checks.tsv\t' <<<"$lines" && who="$(guard_baseline_accepted "$new")"; then
        GUARD_RESULTS+=("baseline-loosened|$(wc -l <<<"$lines")|0|ok|accepted by qg baseline (${who}): ${summary}")
        return 0
    fi
    GUARD_RESULTS+=("baseline-loosened|$(wc -l <<<"$lines")|0|worse|${summary}")
    return 1
}

# guard_baseline_accept_note <reason> -> records the baseline cmd_baseline just wrote, and says
# whether a looser value in it will pass the gates.
guard_baseline_accept_note() {
    if guard_baseline_accept_write "$BASELINE" "$1"; then
        printf 'accepted as the new floor: commit quality/baseline.tsv and push; both gates pass this exact file.\n'
    else
        printf 'not accepted as a new floor: only qg baseline run by a human at a terminal records one, so a looser value in this file is refused at commit and push.\n'
    fi
}
