#!/usr/bin/env bash
# The normalised gate row and its args cell: the field names, the field reader, token substitution
# and the args grammar. Sourced by lib/guard-metrics.sh, lib/qg-driver.sh and
# lib/qg-driver-kit.sh; defines functions only and sources nothing.

# guard_load_checks reads each checks.tsv row into one shape: these fields, tab-separated, in this
# order. Every reader takes a field by name through guard_row_field, never by position.
GUARD_FIELDS=(id on kind driver args direction threshold gate why command parser artifact)
# -g: a caller may source this file inside a function, and a plain declare would be local there.
declare -gA GUARD_FIELD_AT=()
for _i in "${!GUARD_FIELDS[@]}"; do GUARD_FIELD_AT[${GUARD_FIELDS[$_i]}]=$_i; done
unset _i

guard_err() { printf '%s\n' "$*" >&2; }

# guard_row_field <row> <name> -> one field of a normalised row (GUARD_FIELDS).
guard_row_field() {
    # Split on US (\037), not tab: tab is IFS whitespace, so `read` would merge an empty cell
    # with its neighbour and shift every later field.
    local -a f
    IFS=$'\037' read -r -a f <<<"${1//$'\t'/$'\037'}"
    printf '%s' "${f[${GUARD_FIELD_AT[$2]}]-}"
}

# guard_args_kv <args> <key> -> the value of `key=value` before ` -- ` in a v2 args cell.
# guard_args_argv <args> -> the text after the first ` -- `, or nothing.
guard_args_kv() {
    # Word splitting only: a value such as ignore=**/Docs/** must never expand against the cwd.
    local - head="$1" w
    set -f
    case "$head" in '-- '*) return 1 ;; *' -- '*) head="${head%% -- *}" ;; esac
    for w in $head; do
        case "$w" in "$2="*) printf '%s' "${w#*=}"; return 0 ;; esac
    done
    return 1
}
guard_args_argv() {
    case "$1" in '-- '*) printf '%s' "${1#-- }" ;; *' -- '*) printf '%s' "${1#* -- }" ;; esac
}

# guard_substitute <command> <base ref> <files file>
#
# {{base}} becomes the base ref. {{files}} becomes the NUL-separated changed paths,
# which the command must consume with xargs -0: a newline-separated list terminates
# the command at the first path and executes the second path as a command name.
# {{tree}}, {{cache}}, {{bases}}, {{target}} and {{guard}} come from GUARD_TREE_DIR,
# GUARD_CACHE_DIR, GUARD_BASES, GUARD_TARGET and GUARD_BIN_DIR, which `guard.sh commit`
# and `verify` set; a token whose variable is unset stays as written.
guard_substitute() {
    local cmd="$1" base="$2" files="$3" token var
    cmd="${cmd//\{\{base\}\}/"$base"}"
    cmd="${cmd//\{\{files\}\}/"cat $files"}"
    for token in tree:GUARD_TREE_DIR cache:GUARD_CACHE_DIR bases:GUARD_BASES \
                 target:GUARD_TARGET guard:GUARD_BIN_DIR; do
        var="${token#*:}"
        [ -n "${!var:-}" ] || continue
        cmd="${cmd//\{\{${token%%:*}\}\}/"${!var}"}"
    done
    printf '%s' "$cmd"
}
