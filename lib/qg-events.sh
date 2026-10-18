#!/usr/bin/env bash
# The `on` cell of a quality/checks.tsv v2 row: which events run the row. Sourced; defines
# functions only. Grammar, in vault/architecture/guard-file-formats.md:
#
#   on    := '-' | token (',' token)*
#   token := 'commit' | 'push' | 'push:' <ref-glob> | 'baseline'
#
# No spaces, no empty token, lower case only. A ref glob matches with bash [[ == ]]: `*`, `?`
# and `[...]` are glob characters and `|` is a literal character, never an alternation.

# qg_on_valid <on> -> 0 when the cell follows the grammar; 1 with the reason on stdout.
qg_on_valid() {
    local on="$1" token
    [ "$on" = '-' ] && return 0
    case "$on" in ''|,*|*,|*,,*|*' '*|*$'\t'*) printf 'an empty token or a space in "%s"' "$on"; return 1 ;; esac
    local -a tokens
    IFS=',' read -ra tokens <<<"$on"
    for token in "${tokens[@]}"; do
        case "$token" in
            commit|push|baseline) ;;
            push:?*) ;;
            *) printf 'unknown token "%s"' "$token"; return 1 ;;
        esac
    done
    return 0
}

# qg_row_runs_on <on> <event> [<ref>] -> 0 when the row runs on that event.
# event is commit, push or baseline. For push, a ref of '-' or none means "any pushed ref":
# every push token matches, as when a person runs `guard.sh release` with no ref.
qg_row_runs_on() {
    local on="$1" event="$2" ref="${3:--}" token glob
    [ "$on" = '-' ] && return 1
    local -a tokens
    IFS=',' read -ra tokens <<<"$on"
    for token in "${tokens[@]}"; do
        case "$event:$token" in
            commit:commit|baseline:baseline|push:push) return 0 ;;
            push:push:*)
                [ "$ref" = '-' ] && return 0
                glob="${token#push:}"
                # shellcheck disable=SC2053
                [[ "$ref" == $glob ]] && return 0 ;;
        esac
    done
    return 1
}

# qg_on_from_v1 <scope> <release pattern> -> the `on` cell a v1 scope means. The pattern is
# guard_release_pattern: `a|b` is two globs, and an empty pattern is the hook's default.
qg_on_from_v1() {
    local scope="$1" pattern="${2//\\/}" glob push=''
    [ -n "$pattern" ] || pattern='refs/heads/release/*'
    local -a globs
    IFS='|' read -ra globs <<<"$pattern"
    for glob in "${globs[@]}"; do
        [ -n "$glob" ] && push+="${push:+,}push:${glob}"
    done
    case "$scope" in
        commit)   printf 'commit' ;;
        release)  printf '%s' "$push" ;;
        both)     printf 'commit,%s' "$push" ;;
        baseline) printf 'baseline' ;;
        *)        printf -- '-' ;;
    esac
}
