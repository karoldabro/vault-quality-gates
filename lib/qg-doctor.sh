#!/usr/bin/env bash
# `qg doctor`: is this repo's gate set up so it actually runs? Sourced by bin/qg; defines
# functions only. Exit 0 when nothing is broken (warnings allowed), 1 when something is.

qg_doctor() {
    local fails=0 warns=0 out='' plugin hooks name f r driver path tmp req glob refs src
    plugin="$(readlink -f "${GUARD_LIB_DIR}/..")"
    note() {  # note <ok|warn|fail> <text>
        case "$1" in warn) warns=$((warns + 1)) ;; fail) fails=$((fails + 1)) ;; esac
        out+="$1"$'\t'"$2"$'\n'
    }

    for f in jq python3 git flock; do
        command -v "$f" >/dev/null 2>&1 && note ok "$f is installed" || note fail "$f is missing; the gate needs it"
    done

    # Configuration, as committed.
    if guard_config_show quality/checks.tsv >/dev/null; then
        if ( qg_load_head ) 2>/dev/null; then note ok 'quality/checks.tsv loads'
        else note fail "quality/checks.tsv does not load: $( ( qg_load_head ) 2>&1 | head -1)"; fi
    else
        note fail 'HEAD has no quality/checks.tsv: nothing is gated (qg init --profile <p>)'
    fi
    guard_config_show quality/rules.tsv >/dev/null || note warn 'HEAD has no quality/rules.tsv: the commit gate treats this branch as predating the gate'
    src="$(qg_config_source)" && note ok "gate keys come from ${src}" || note warn 'neither quality/config nor VAULT.md is committed: every key takes its default'
    head -1 <(guard_config_show quality/checks.tsv 2>/dev/null) | grep -qF "$GUARD_CHECKS_HEADER" \
        && note warn 'quality/checks.tsv is v1: rows have no why (a human runs qg migrate)'

    # Git hooks: installed, and identical to the templates of this plugin. An installed hook is a
    # copy, so an outdated one keeps running the old body.
    hooks="$(git rev-parse --git-path hooks)"
    [ -z "$(git config core.hooksPath)" ] || note fail "core.hooksPath is set to $(git config core.hooksPath): git does not run .git/hooks"
    for name in $GUARD_DOCTOR_HOOKS; do
        if [ ! -x "${hooks}/${name}" ]; then note fail "${name} hook is not installed (a human runs qg hooks install)"
        elif sed "s|__GUARD_SH__|${plugin}/bin/guard.sh|g" "${plugin}/templates/git-hooks/${name}" | cmp -s - "${hooks}/${name}"; then
            note ok "${name} hook is current"
        else note fail "${name} hook differs from the template (a human runs qg hooks install)"; fi
    done

    # Claude Code hooks: the agent guards live at user level, for ~/.claude and, when it exists,
    # ~/.claude-factory. A per-repo entry duplicates them.
    qg_doctor_user_entries "${HOME}/.claude"
    [ ! -d "${HOME}/.claude-factory" ] || qg_doctor_user_entries "${HOME}/.claude-factory"
    if [ -r .claude/settings.json ]; then
        while IFS= read -r f; do
            [ -n "$f" ] && note warn "${REPO_ROOT}/.claude/settings.json lists the guard ${f}; the user-level entry covers it (a human runs qg hooks remove --claude)"
        done < <(jq -r "${QG_DOCTOR_GUARD_JQ}"' | .[] | .command' .claude/settings.json 2>/dev/null)
    fi

    # The machine tool-path file: the tool folders every gate entry puts after the system folders.
    qg_doctor_tool_path

    # Drivers and the tools they need; push globs that match no branch.
    if ( qg_load_head ) 2>/dev/null; then
        qg_load_head 2>/dev/null
        refs="$(git for-each-ref --format='%(refname)' refs/heads refs/remotes | sed 's#^refs/remotes/[^/]*/#refs/heads/#')"
        declare -A seen=()
        for r in "${GUARD_ROWS[@]:-}"; do
            [ -n "$r" ] || continue
            driver="$(guard_row_field "$r" driver)"
            if [ "$driver" != shell ] && [ "$(guard_row_field "$r" kind)" != absent ] && [ -z "${seen[$driver]:-}" ]; then
                seen[$driver]=1
                tmp="$(mktemp -d)"
                if path="$(guard_driver_path "$driver" "$tmp")"; then
                    if ! "$path" describe 2>/dev/null | jq -e '.name' >/dev/null 2>&1; then note fail "driver ${driver}: describe is not JSON"
                    else
                        for req in $("$path" describe | jq -r '(.requires // [])[]'); do
                            command -v "$req" >/dev/null 2>&1 || note fail "driver ${driver} needs ${req}, which is not installed"
                        done
                        note ok "driver ${driver} resolves"
                    fi
                    [ -n "$("$path" explain 2>/dev/null)" ] || note fail "driver ${driver}: explain prints nothing"
                else note fail "driver ${driver}: ${path}"; fi
                rm -rf "$tmp"
            fi
            local -a ts=(); IFS=',' read -ra ts <<<"$(guard_row_field "$r" on)"
            for glob in "${ts[@]}"; do
                case "$glob" in push:*) glob="${glob#push:}" ;; *) continue ;; esac
                [ -n "${seen["glob:$glob"]:-}" ] && continue
                seen["glob:$glob"]=1
                if qg_glob_hits "$glob" "$refs"; then note ok "push:${glob} matches a branch"
                else note warn "push:${glob} matches no local or remote branch; check it for a typo"; fi
            done
        done
    fi

    command -v qg >/dev/null 2>&1 && note ok "qg is on PATH" \
        || note warn "qg is not on PATH; link it: ln -s ${plugin}/bin/qg ~/.local/bin/qg"

    if [ "$JSON" = 1 ]; then
        printf '%s' "$out" | jq -R -s --argjson f "$fails" --argjson w "$warns" \
            '{fails:$f, warnings:$w, checks:[split("\n")[] | select(length > 0) | split("\t") | {level:.[0], text:.[1]}]}'
    else
        printf '%s' "$out" | awk -F'\t' '$1 != "ok" { printf "  %-5s %s\n", $1, $2 }'
        printf 'qg doctor: %d broken, %d warnings, %d fine\n' "$fails" "$warns" "$(printf '%s' "$out" | grep -c '^ok')"
    fi
    [ "$fails" -eq 0 ]
}

GUARD_DOCTOR_HOOKS='pre-commit pre-merge-commit pre-applypatch pre-push post-rewrite'
# Every hook entry of a settings.json whose command's file name is one of the three agent guards,
# as {event, name, command}.
QG_DOCTOR_GUARD_JQ='[(.hooks // {}) | to_entries[] | .key as $event | (.value | arrays)[]
    | (.hooks | arrays)[] | (.command | strings) as $c
    | ($c | sub("^\\s+"; "") | sub("\\s+$"; "") | split("/") | last) as $n
    | select($n == "guard-bash.sh" or $n == "guard-edit.sh" or $n == "guard-stop.sh")
    | {event: $event, name: $n, command: $c}]'

# qg_doctor_user_entries <claude config dir> -> a fail for each of the three guard entries its
# settings.json lacks: guard-bash.sh and guard-edit.sh under PreToolUse, guard-stop.sh under Stop.
# Called from qg_doctor, whose note() it uses.
qg_doctor_user_entries() {
    local file="${1}/settings.json" n ev have
    if ! have="$(jq -c "$QG_DOCTOR_GUARD_JQ" "$file" 2>/dev/null)"; then
        note fail "${file} is missing or not JSON: agents run without the guards (a human runs qg hooks install --claude --user)"
        return
    fi
    for n in guard-bash.sh guard-edit.sh guard-stop.sh; do
        ev=PreToolUse; [ "$n" != guard-stop.sh ] || ev=Stop
        if jq -e --arg n "$n" --arg ev "$ev" 'any(.[]; .name == $n and .event == $ev)' <<<"$have" >/dev/null; then
            note ok "${file} runs ${n}"
        else
            note fail "${file} lacks the ${ev} entry ${n} (a human runs qg hooks install --claude --user)"
        fi
    done
}

# qg_doctor_tool_path -> a fail when the machine tool-path file is absent, and one per entry the
# engine drops from PATH. qg_tool_path_file and qg_tool_path_bad come from lib/qg-toolpath.sh.
qg_doctor_tool_path() {
    local file bad entry n=0
    if ! declare -F qg_tool_path_file >/dev/null && [ -r "${GUARD_LIB_DIR}/qg-toolpath.sh" ]; then
        # shellcheck source=qg-toolpath.sh
        . "${GUARD_LIB_DIR}/qg-toolpath.sh"
    fi
    if ! declare -F qg_tool_path_file >/dev/null || ! declare -F qg_tool_path_bad >/dev/null; then
        note fail "${GUARD_LIB_DIR}/qg-toolpath.sh is missing, so the machine tool-path file cannot be checked"
        return
    fi
    if ! file="$(qg_tool_path_file)" || [ -z "$file" ]; then
        note fail "cannot locate the machine tool-path file: the plugin's main worktree has no readable git dir"
        return
    fi
    if [ ! -f "$file" ]; then
        note fail "the machine tool-path file ${file} is absent, so PATH holds the system folders only (a human runs qg hooks install --claude --user)"
        return
    fi
    # One `<entry>\t<reason>` line per bad entry; the entry may be empty, so the line is split by hand.
    while IFS= read -r bad; do
        n=$((n + 1))
        entry="${bad%%$'\t'*}"
        note fail "the machine tool-path file ${file} lists ${entry:-an empty line} (${bad#*$'\t'}), which the engine drops from PATH (a human runs qg hooks install --claude --user)"
    done < <(qg_tool_path_bad)
    [ "$n" -gt 0 ] || note ok "the machine tool-path file ${file} is valid"
}

# qg_glob_hits <glob> <refs, one per line> -> 0 when the glob matches one ref.
qg_glob_hits() {
    local ref
    while IFS= read -r ref; do
        # shellcheck disable=SC2053
        [[ "$ref" == $1 ]] && return 0
    done <<<"$2"
    return 1
}

# The v1 checks.tsv header. The loader no longer needs it once v1 is gone; this mode still has to
# recognise it on an old branch.
QG_DOCTOR_V1_HEADER=$'id\tscope\tkind\tcommand\tparser\tartifact\tdirection\tthreshold\tgate'
QG_DOCTOR_V2_HEADER=$'id\ton\tkind\tdriver\targs\tdirection\tthreshold\tgate\twhy'

# qg_doctor_branches -> `qg doctor --all-branches`: every local branch and remote-tracking ref whose
# quality/checks.tsv is v1, has an unrecognised header, or is v2 without quality/config. Each is
# labelled worktree (checked out in any worktree), upstream (remote-tracking, or a live upstream)
# or stale, in that precedence. Prints the source: the newest v2 ref with quality/config. Exit 1
# when a listed ref is not stale, else 0. Reads refs, config and objects only; never fetches.
qg_doctor_branches() {
    local ref sha symref date up name state version config i n=0 fail=0 stale=0
    local src_sha='' src_ref='' src_date=-1 out=''
    local -a refs=() shas=() dates=() ups=() verdicts=()
    local -A exists=() checked=()

    # Fields split on \x1f, which no refname holds: a tab is IFS whitespace, so an empty %(symref)
    # between two tabs would vanish and shift every later field.
    while IFS=$'\x1f' read -r ref sha symref date up; do
        [ -z "$symref" ] || continue
        case "$ref" in refs/heads/*) ;; refs/remotes/*/*) ;; *) continue ;; esac
        refs+=("$ref"); shas+=("$sha"); dates+=("${date:-0}"); ups+=("$up"); exists[$ref]=1
    done < <(git for-each-ref --format='%(refname)%1f%(objectname)%1f%(symref)%1f%(committerdate:unix)%1f%(upstream)' refs/heads refs/remotes)

    # The main worktree's branch counts too: `git worktree list` names it first.
    while IFS= read -r name; do
        case "$name" in 'branch '*) checked[${name#branch }]=1 ;; esac
    done < <(git worktree list --porcelain 2>/dev/null)

    # One cat-file for every ref: two answers per ref, the checks.tsv version then whether
    # quality/config exists. Each object is skipped by its byte size, so its content is never
    # mistaken for the next header.
    if [ "${#refs[@]}" -gt 0 ]; then
        mapfile -t verdicts < <(
            for sha in "${shas[@]}"; do printf '%s:quality/checks.tsv\n%s:quality/config\n' "$sha" "$sha"; done \
                | git cat-file --batch \
                | awk -v v1="$QG_DOCTOR_V1_HEADER" -v v2="$QG_DOCTOR_V2_HEADER" '
                    function answer(a) { print a; k++ }
                    rem > 0 {
                        if (first) { line1 = $0; first = 0 }
                        rem -= length($0) + 1
                        if (rem <= 0) {
                            if (k % 2 == 1) answer(type == "blob" ? "yes" : "no")
                            else if (type != "blob") answer("unknown")
                            else answer(line1 == v1 ? "v1" : line1 == v2 ? "v2" : "unknown")
                        }
                        next
                    }
                    $NF == "missing" || $NF == "ambiguous" { answer(k % 2 == 1 ? "no" : "none"); next }
                    { type = $2; rem = $3 + 1; first = 1; line1 = "" }')
    fi
    [ "${#verdicts[@]}" -eq $((2 * ${#refs[@]})) ] || { printf 'qg doctor: cannot read quality/ on every ref\n' >&2; return 2; }

    for i in "${!refs[@]}"; do
        ref="${refs[$i]}"; version="${verdicts[$((2 * i))]}"; config="${verdicts[$((2 * i + 1))]}"
        if [ "$version" = v2 ] && [ "$config" = yes ]; then
            if [ "${dates[$i]}" -gt "$src_date" ]; then src_date="${dates[$i]}"; src_sha="${shas[$i]}"; src_ref="$ref"; fi
            continue
        fi
        [ "$version" != none ] || continue
        up="${ups[$i]}"
        if [ -n "${checked[$ref]:-}" ]; then state=worktree
        elif [[ "$ref" == refs/remotes/* ]]; then state=upstream
        elif [ -n "$up" ] && [ -n "${exists[$up]:-}" ]; then state=upstream
        else state=stale; fi
        if [ "$state" = stale ]; then stale=$((stale + 1)); else fail=1; fi
        n=$((n + 1))
        out+="${state}"$'\t'"${ref}"$'\t'"${shas[$i]}"$'\t'"${version}"$'\t'"${config}"$'\n'
    done

    if [ "$JSON" = 1 ]; then
        printf '%s' "$out" | jq -R -s --arg src "$src_sha" '{source: (if $src == "" then null else $src end),
            refs: [split("\n")[] | select(length > 0) | split("\t")
                   | {ref: .[1], sha: .[2], state: .[0], version: .[3], config: (.[4] == "yes")}]}'
    else
        printf '%s' "$out" | awk -F'\t' '{ printf "  %-8s %s %s %s%s\n", $1, $2, $3, $4, ($4 == "v2" && $5 != "yes" ? " without quality/config" : "") }'
        if [ -n "$src_sha" ]; then printf 'source: %s %s\n' "$src_sha" "$src_ref"; else printf 'no v2 source\n'; fi
        printf 'qg doctor --all-branches: %d refs without a v2 gate config, %d of them stale\n' "$n" "$stale"
    fi
    [ "$fail" -eq 0 ]
}
