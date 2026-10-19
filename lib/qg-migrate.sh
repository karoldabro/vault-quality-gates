#!/usr/bin/env bash
# `qg migrate` (v1 checks.tsv to v2) and `qg init` (gate a new repo). Sourced by bin/qg; defines
# functions only. Both write the working tree and never commit: the commit that changes the gate
# configuration is a human's, made with `qg override`, because the gate refuses it otherwise.

# The keys quality/config carries. guard_release_pattern is not one: a v2 row names its own globs.
QG_CONFIG_KEYS='guard_commit_paths guard_protected_paths guard_accept_limit guard_measure_worktree guard_flutter_root'
QG_WHY_TODO='TODO: state in one sentence why this gate exists'

qg_migrate() {
    local draft=0 line n=0 id scope kind command parser artifact direction threshold gate on args why pattern
    local tmp missing='' key value protected
    [ "${1:-}" = --draft ] && draft=1
    [ -r quality/checks.tsv ] || qg_die 'migrate: no quality/checks.tsv in the working tree'
    [ "$(head -1 quality/checks.tsv)" = "$GUARD_CHECKS_HEADER" ] || qg_die 'migrate: quality/checks.tsv is not v1; nothing to do'
    pattern="$(sed -n 's/^guard_release_pattern:[[:space:]]*//p' VAULT.md 2>/dev/null | head -1)"
    tmp="$(mktemp)"
    printf '%s\n' "$GUARD_CHECKS_HEADER_V2" > "$tmp"
    while IFS= read -r line || [ -n "$line" ]; do
        n=$((n + 1))
        [ "$n" -eq 1 ] && continue
        case "$line" in ''|'#'*) printf '%s\n' "$line" >> "$tmp"; continue ;; esac
        IFS=$'\t' read -r id scope kind command parser artifact direction threshold gate <<<"$line"
        on="$(qg_on_from_v1 "$scope" "$pattern")"
        if [ "$kind" = absent ]; then
            why="$artifact"
            if [[ ! "$why" =~ [^[:space:]] ]] || [ "$why" = '-' ]; then why="$QG_WHY_TODO"; missing+="  ${id}"$'\n'; fi
            printf '%s\t-\tabsent\t-\t-\t-\t-\t-\t%s\n' "$id" "$why" >> "$tmp"
            continue
        fi
        case "$artifact" in *' '*) rm -f "$tmp"; qg_die "migrate: row ${id}: the artifact \"${artifact}\" has a space; write this row by hand" ;; esac
        args=''
        [ "$parser" = '-' ] || args+="parser=${parser} "
        [ "$artifact" = '-' ] || args+="artifact=${artifact} "
        args+="-- ${command}"
        why="$QG_WHY_TODO"
        missing+="  ${id}"$'\n'
        printf '%s\t%s\t%s\tshell\t%s\t%s\t%s\t%s\t%s\n' "$id" "$on" "$kind" "$args" "$direction" "$threshold" "$gate" "$why" >> "$tmp"
    done < quality/checks.tsv

    if [ "$draft" -eq 0 ]; then
        rm -f "$tmp"
        printf 'qg migrate: every v2 row needs a why, and these rows have none yet:\n%s' "$missing"
        printf 'Run qg migrate --draft to write the v2 file with TODO whys, replace each TODO, then commit.\n'
        return 1
    fi
    cp quality/checks.tsv quality/checks.v1.tsv.bak
    mv "$tmp" quality/checks.tsv

    if [ ! -e quality/config ]; then
        {
            printf '# Gate keys for vault-quality-gates (lib/qg-config.sh). Written by qg migrate from VAULT.md.\n'
            for key in $QG_CONFIG_KEYS; do
                value="$(sed -n "s/^${key}:[[:space:]]*//p" VAULT.md 2>/dev/null | head -1)"
                if [ "$key" = guard_protected_paths ]; then
                    protected="$value"
                    case " $protected " in *' quality '*) ;; *) protected="${protected:+$protected }quality/drivers quality/config" ;; esac
                    value="$protected"
                fi
                [ -n "$value" ] && printf '%s: %s\n' "$key" "$value"
            done
        } > quality/config
    fi
    printf 'qg migrate: wrote quality/checks.tsv (v2; the v1 file is in quality/checks.v1.tsv.bak) and quality/config.\n'
    printf 'Next:\n  1. Replace every "%s" in quality/checks.tsv; the gate refuses a TODO why.\n' "$QG_WHY_TODO"
    printf '  2. qg doctor, then delete quality/checks.v1.tsv.bak.\n'
    printf '  3. qg override --reason "migrate the gate config to v2", then git add quality/ and commit.\n'
}

qg_init() {
    local profile='' force=0 tpl
    while [ $# -gt 0 ]; do
        case "$1" in
            --profile) [ $# -ge 2 ] || qg_die 'init: --profile needs a value (qg help init)'
                       profile="$2"; shift 2 ;;
            --force)   force=1; shift ;;
            *) qg_die "init: unknown option $1 (qg help init)" ;;
        esac
    done
    tpl="${GUARD_LIB_DIR}/../templates/init/${profile}.tsv"
    [ -n "$profile" ] && [ -r "$tpl" ] || qg_die "init: --profile is one of: $(cd "${GUARD_LIB_DIR}/../templates/init" && ls *.tsv | sed 's/\.tsv$//' | tr '\n' ' ')"
    [ "$force" -eq 1 ] || [ ! -e quality/checks.tsv ] || qg_die 'init: quality/checks.tsv exists; --force replaces it'
    mkdir -p quality
    cp "$tpl" quality/checks.tsv
    [ -e quality/rules.tsv ] || printf 'id\ttool\tenforced_by\temits\n' > quality/rules.tsv
    [ -e quality/baseline.tsv ] || printf 'id\tvalue\tcommit\treason\n' > quality/baseline.tsv
    if [ ! -e quality/config ]; then
        printf '%s\n' '# Gate keys for vault-quality-gates (lib/qg-config.sh).' \
            'guard_protected_paths: quality' 'guard_accept_limit: 3' > quality/config
        # The Dart drivers run only the SDK this key names; the human running init picks it.
        if [ "$profile" = flutter ]; then
            local flutter
            if flutter="$(command -v flutter)"; then
                printf 'guard_flutter_root: %s\n' "$(dirname "$(dirname "$(readlink -f "$flutter")")")" >> quality/config
            else
                printf 'qg init: no flutter on PATH; add guard_flutter_root: <Flutter SDK folder> to quality/config, or every Dart row refuses.\n' >&2
            fi
        fi
    fi
    printf 'qg init: wrote quality/checks.tsv (profile %s), rules.tsv, baseline.tsv and config.\n' "$profile"
    printf 'Next:\n  1. qg hooks install --claude\n  2. qg doctor\n  3. git add quality .claude/settings.json and commit.\n'
}
