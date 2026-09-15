#!/usr/bin/env bash
# Shared by every parser. A parser prints ONE float on stdout and exits 0, or prints
# a reason on stderr and exits 2. It never runs the measuring tool and never reads
# quality/checks.tsv.
#
# An empty string is the failure this guards against: the comparison reads it as
# zero, so a missing measurement becomes the worst possible score — or, with
# direction `down`, a perfect one.

# A comma decimal separator is not a number to guard_is_number. Under es_ES awk
# formatted 4.04 as "4,04" and the measurement was recorded as unmeasurable.
export LC_ALL=C

guard_p_die() { printf '%s\n' "$*" >&2; exit 2; }

# The artifact cell may carry `path#selector`; a parser that wants a selector splits here.
guard_p_path()     { printf '%s' "${1%%#*}"; }
guard_p_selector() { case "$1" in *#*) printf '%s' "${1#*#}" ;; *) printf '' ;; esac; }

guard_p_readable() {
    [ -n "$1" ] || guard_p_die "no artifact path given"
    [ -r "$1" ] || guard_p_die "artifact not readable: $1"
}

guard_p_emit() {
    case "$1" in
        ''|null|None) guard_p_die "${2:-parser produced no number}" ;;
    esac
    printf '%s\n' "$1"
}
