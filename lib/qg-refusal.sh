#!/usr/bin/env bash
# The refusal a person or an agent reads when a commit or push is refused. Sourced by
# lib/guard-metrics.sh; defines functions only.
#
# Order: one summary line per failing row; a first line saying nothing in the code was measured
# when no failing row was measured; per row its `why`, the reproduce command and `qg explain`;
# the findings; each distinct output tail once, naming its rows; how to pass. The text is capped
# at QG_REFUSAL_MAX characters (the agent factory keeps the last 4000) and written whole to
# <git-common-dir>/qg-last/REFUSAL.txt, which `qg last` prints.

QG_REFUSAL_MAX=3500

# Gate rows the engine adds itself; they have no checks.tsv row to take a why from.
declare -gA QG_BUILTIN_WHY=(
    [baseline-loosened]='quality/baseline.tsv only gets tighter; a looser value hides a regression'
    [gate-config-deleted]='the gate configuration may not be deleted'
    [gate-config-changed]='a repo driver or quality/config judges the next commit, so a human decides each change'
    [gate-config-invalid]='a checks.tsv that does not load would leave every later commit unmeasured'
)

qg_agent() { [ -n "${CLAUDECODE+set}" ] || [ -n "${AI_AGENT+set}" ]; }

# qg_refusal_why <id> -> the row's why, from the loaded rows or the built-in list.
qg_refusal_why() {
    local r
    [ -n "${QG_BUILTIN_WHY[$1]:-}" ] && { printf '%s' "${QG_BUILTIN_WHY[$1]}"; return; }
    for r in "${GUARD_ROWS[@]:-}"; do
        [ "$(guard_row_field "$r" id)" = "$1" ] && { guard_row_field "$r" why; return; }
    done
    printf '%s' "$GUARD_WHY_FALLBACK"
}

qg_refusal_driver() {
    local r
    for r in "${GUARD_ROWS[@]:-}"; do
        [ "$(guard_row_field "$r" id)" = "$1" ] && { guard_row_field "$r" driver; return; }
    done
    printf 'gate'
}

# qg_print_refusal <commit|push> <ref or -> <findings text> -> the refusal on stderr; exit 0.
qg_print_refusal() {
    local event="$1" ref="$2" findings="$3" line id value base status detail out='' n=0 measured=0
    local common last tails='' refopt='' qg
    common="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
    last="${common}/qg-last"
    qg="$(readlink -f "${GUARD_LIB_DIR}/../bin")/qg"
    [ "$event" = push ] && [ "$ref" != '-' ] && refopt=" --ref ${ref}"
    local -a ids=()
    for line in "${GUARD_RESULTS[@]:-}"; do
        IFS='|' read -r id value base status detail <<<"$line"
        case "$status" in
            worse)        ids+=("$id"); measured=1
                          out+="$(printf '  %-24s worse: measured %s (%s)' "$id" "$value" "$detail")"$'\n' ;;
            unmeasurable) ids+=("$id")
                          out+="$(printf '  %-24s could not run: %s' "$id" "$detail")"$'\n' ;;
        esac
    done
    [ "${#ids[@]}" -gt 0 ] || return 0
    local head
    if [ "$event" = push ]; then head="vault-guard: push refused to ${ref}"; else head='vault-guard: the staged commit was refused'; fi
    out="${head}"$'\n\n'"${out}"
    [ "$measured" -eq 1 ] || out+=$'\n''Nothing in your code was measured: every failing row could not run. The cause is the'$'\n''environment or a tool, not your change; the output below says what failed.'$'\n'

    for id in "${ids[@]}"; do
        out+=$'\n'"${id} ($(qg_refusal_driver "$id"))"$'\n'
        out+="  why:       $(qg_refusal_why "$id")"$'\n'
        [ -n "${QG_BUILTIN_WHY[$id]:-}" ] || {
            out+="  reproduce: qg run ${event}${refopt} --only ${id}"$'\n'
            out+="  details:   qg explain ${id}"$'\n'
        }
    done
    case " ${ids[*]} " in *' baseline-loosened '*|*' gate-config-deleted '*)
        out+=$'\n''Restore them: git checkout HEAD -- quality/baseline.tsv quality/checks.tsv quality/rules.tsv. A tighter baseline value is allowed; a looser one never.'$'\n' ;;
    esac
    [ -z "$findings" ] || out+=$'\n''Findings:'$'\n'"${findings}"$'\n'

    # Each distinct output tail once, naming every row that printed it.
    local -A tail_rows=() tail_text=()
    local key t
    for id in "${ids[@]}"; do
        [ -s "${last}/${id}/output.txt" ] || continue
        t="$(cat "${last}/${id}/output.txt")"
        key="$(printf '%s' "$t" | cksum | cut -d' ' -f1)"
        tail_text[$key]="$t"
        tail_rows[$key]+="${tail_rows[$key]:+, }${id}"
    done
    for key in "${!tail_rows[@]}"; do
        tails+=$'\n'"Output of ${tail_rows[$key]} (last lines):"$'\n'"$(printf '%s\n' "${tail_text[$key]}" | sed 's/^/  | /')"$'\n'
    done
    out+="$tails"

    # The footer is never cut: a reader who sees nothing else must still learn how to pass.
    local foot again='commit again'
    [ "$event" = push ] && again='commit, and push again'
    foot=$'\n''How to pass:'$'\n'
    if [ "$measured" -eq 1 ]; then foot+="  1. Fix what is listed above in the code, git add it, and ${again}."$'\n'
    else foot+="  1. Fix what the output above names (a tool, a service, the environment), then ${again}."$'\n'; fi
    foot+="  2. qg explain <id> says what a gate checks and why; qg last prints this refusal again."$'\n'
    if qg_agent; then
        foot+='  3. Agents may not override a gate. If you cannot fix it, stop and tell the operator.'$'\n'
    elif [ "$event" = commit ]; then
        foot+='  3. Only a human at a terminal, when the gate itself is wrong:'$'\n''     qg override --reason "<why>"   then commit again (once, for exactly this staged content).'$'\n'
    else
        foot+='  3. Only a human at a terminal, for commits that never passed the commit gate:'$'\n''     qg override --reason "<why>" --push <sha>   then push again. A worse metric is fixed in code.'$'\n'
    fi
    foot+="(qg is ${qg})"$'\n'

    mkdir -p "$last" 2>/dev/null && printf '%s%s' "$out" "$foot" > "${last}/REFUSAL.txt"
    local cut=$'\n''... cut here; run `qg last` for the whole refusal.'$'\n' room
    # Two characters for the blank lines printed around the text.
    room=$((QG_REFUSAL_MAX - ${#foot} - ${#cut} - 2))
    [ $(( ${#out} + ${#foot} + 2 )) -le "$QG_REFUSAL_MAX" ] || out="${out:0:$room}${cut}"
    printf '\n%s%s\n' "$out" "$foot" >&2
}
