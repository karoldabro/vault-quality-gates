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

    # Git hooks: installed, and identical to the templates of this plugin.
    hooks="$(git rev-parse --git-path hooks)"
    [ -z "$(git config core.hooksPath)" ] || note fail "core.hooksPath is set to $(git config core.hooksPath): git does not run .git/hooks"
    for name in $GUARD_DOCTOR_HOOKS; do
        if [ ! -x "${hooks}/${name}" ]; then note fail "${name} hook is not installed (qg hooks install --claude)"
        elif sed "s|__GUARD_SH__|${plugin}/bin/guard.sh|g" "${plugin}/templates/git-hooks/${name}" | cmp -s - "${hooks}/${name}"; then
            note ok "${name} hook is current"
        else note warn "${name} hook differs from the template (a human runs qg hooks install --claude)"; fi
    done

    # Claude Code hooks: the agent guards.
    if [ -r .claude/settings.json ]; then
        for f in guard-bash.sh guard-edit.sh guard-stop.sh; do
            grep -qF "$f" .claude/settings.json && note ok "Claude Code hook ${f} is listed" \
                || note warn "Claude Code hook ${f} is not listed in .claude/settings.json"
        done
    else
        note warn 'no .claude/settings.json: agents in this repo are not stopped from skipping the gate'
    fi

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

# qg_glob_hits <glob> <refs, one per line> -> 0 when the glob matches one ref.
qg_glob_hits() {
    local ref
    while IFS= read -r ref; do
        # shellcheck disable=SC2053
        [[ "$ref" == $1 ]] && return 0
    done <<<"$2"
    return 1
}
