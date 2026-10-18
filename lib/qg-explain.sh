#!/usr/bin/env bash
# `qg explain <id>`: one gate row in full — what it checks, why, when it runs, its limit, its last
# result and output, how to reproduce it and how to pass. Sourced by bin/qg after it loaded the
# libraries; defines functions only. Works before the row ever ran.

# qg_limit_words <row> -> the limit in words.
qg_limit_words() {
    local kind dir thr base_val word
    kind="$(guard_row_field "$1" kind)" dir="$(guard_row_field "$1" direction)" thr="$(guard_row_field "$1" threshold)"
    if [ "$dir" = up ]; then word='at least'; else word='at most'; fi
    case "$kind" in
        diff)   printf 'the number must be %s %s on every run' "$word" "$thr" ;;
        repo)   base_val="$(guard_config_show quality/baseline.tsv | awk -F'\t' -v id="$(guard_row_field "$1" id)" 'NR > 1 && $1 == id { print $2; exit }')"
                printf 'the number may not get worse than quality/baseline.tsv (%s), tolerance %s; %s is better' \
                    "${base_val:-no baseline row yet}" "$thr" "$([ "$dir" = up ] && echo higher || echo lower)" ;;
        absent) printf 'none: this check does not exist for this repo' ;;
    esac
}

qg_gate_words() {
    case "$1" in
        refuse) printf 'refuse: a worse number refuses the commit or push' ;;
        warn)   printf 'warn: a worse number is printed; the commit goes through' ;;
        record) printf 'record: the number is stored, never judged' ;;
        *)      printf '%s' "$1" ;;
    esac
}

qg_explain() {
    local id="$1" r row='' on event driver path tmp last results res line
    [ -n "$id" ] || qg_die 'usage: qg explain <id>   (qg list shows the ids)'
    qg_load_head
    for r in "${GUARD_ROWS[@]:-}"; do [ "$(guard_row_field "$r" id)" = "$id" ] && row="$r"; done
    if [ -z "$row" ] && [ -n "${QG_BUILTIN_WHY[$id]:-}" ]; then
        if [ "$JSON" = 1 ]; then
            jq -n --arg id "$id" --arg why "${QG_BUILTIN_WHY[$id]}" '{id:$id, why:$why, builtin:true}'
        else
            printf '%s — a check the engine always runs.\n  why: %s\n' "$id" "${QG_BUILTIN_WHY[$id]}"
        fi
        return 0
    fi
    [ -n "$row" ] || qg_die "no row \"$id\" in the committed quality/checks.tsv (qg list shows the ids)"

    on="$(guard_row_field "$row" on)" driver="$(guard_row_field "$row" driver)"
    event=commit; qg_row_runs_on "$on" commit || event=push
    last="$(guard_common_dir)/qg-last/${id}"
    tmp="$(mktemp -d)"
    local summary='' dexplain=''
    if path="$(guard_driver_path "$driver" "$tmp")"; then
        summary="$("$path" describe 2>/dev/null | jq -r '.summary // empty' 2>/dev/null)"
        dexplain="$("$path" explain 2>/dev/null)"
    fi
    rm -rf "$tmp"
    results="$(grep -m1 "^${id}|" "$(guard_common_dir)/qg-last/RESULTS.txt" 2>/dev/null)"
    res='null'
    [ -r "${last}/result.json" ] && res="$(jq -c . "${last}/result.json" 2>/dev/null || echo null)"

    if [ "$JSON" = 1 ]; then
        jq -n --arg id "$id" --arg why "$(guard_row_field "$row" why)" --arg on "$on" --arg runs "$(qg_on_words "$on")" \
            --arg driver "$driver" --arg summary "$summary" --arg limit "$(qg_limit_words "$row")" \
            --arg gate "$(guard_row_field "$row" gate)" --arg command "$(guard_row_field "$row" command)" \
            --arg last_line "$results" --argjson result "$res" \
            --arg output "$(cat "${last}/output.txt" 2>/dev/null)" --arg reproduce "qg run ${event} --only ${id}" \
            --arg explain "$dexplain" \
            '{id:$id, why:$why, on:$on, runs_on:$runs, driver:$driver, driver_summary:$summary, limit:$limit, gate:$gate,
              command:(if $command == "-" then null else $command end), last_result:$result, last_status_line:$last_line,
              last_output:$output, reproduce:$reproduce, driver_explain:$explain}'
        return 0
    fi

    printf '%s\n\n' "$id"
    printf '  why:        %s\n' "$(guard_row_field "$row" why)"
    printf '  runs on:    %s\n' "$(qg_on_words "$on")"
    printf '  driver:     %s%s\n' "$driver" "${summary:+ — $summary}"
    [ "$driver" = shell ] && printf '  command:    %s\n' "$(guard_row_field "$row" command)"
    printf '  limit:      %s\n' "$(qg_limit_words "$row")"
    printf '  gate:       %s\n' "$(qg_gate_words "$(guard_row_field "$row" gate)")"
    printf '  reproduce:  qg run %s --only %s\n\n' "$event" "$id"

    if [ -n "$results" ]; then
        IFS='|' read -r _ value ref status detail <<<"$results"
        printf 'Last run here: %s, measured %s (%s)\n' "$status" "$value" "$detail"
    else
        printf 'Last run here: not run in this repo yet.\n'
    fi
    if [ "$res" != null ]; then
        jq -r '(.findings // [])[:10][] | "  \(.file // "(no file)")\(if .line then ":\(.line)" else "" end) \(.ruleId // "") \(.message // "")"' <<<"$res"
        jq -r 'if (.findings // [] | length) > 10 then "  +\((.findings | length) - 10) more" else empty end' <<<"$res"
    fi
    if [ -s "${last}/output.txt" ]; then
        printf '\nIts own output (last lines):\n'
        sed 's/^/  | /' "${last}/output.txt"
    fi
    [ -z "$dexplain" ] || printf '\nWhat the driver says:\n%s\n' "$(sed 's/^/  /' <<<"$dexplain")"

    printf '\nHow to pass:\n'
    printf '  1. Fix the findings in the code, git add, and %s again. qg run %s --only %s checks without committing.\n' \
        "$event" "$event" "$id"
    if qg_agent; then
        printf '  2. Agents may not override, accept or edit a gate. If the gate is wrong, stop and tell the operator.\n'
    else
        printf '  2. Human only, when the gate itself is wrong: qg override --reason "<why>", then commit again.\n'
        [ "$(guard_row_field "$row" kind)" = repo ] \
            && printf '  3. Human only, to accept a worse number for now: qg accept %s --reason "<why>" (limit: guard_accept_limit).\n' "$id"
    fi
    printf '  Never edit quality/checks.tsv, baseline.tsv, config or drivers to pass: the gate refuses it.\n'
}
