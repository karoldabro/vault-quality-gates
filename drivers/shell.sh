#!/usr/bin/env bash
# Shell driver: a command and, optionally, a parser that turns its artifact into one number.
# Every v1 row runs as this driver. The engine runs `shell` rows itself, inside guard.sh, so a
# command keeps the `set -uo pipefail` and LC_ALL=C it has always run under; this file answers
# describe and explain. Contract: vault/architecture/qg-driver-contract.md.
#
# args:  [parser=<lib/guard-parsers name>] [artifact=<path>] -- <command>
#   parser -   the command's last line of output is the number (the default)
#   parser p   lib/guard-parsers/p.sh reads the artifact and prints the number
set -uo pipefail

case "${1:-}" in
    describe)
        printf '{"name":"shell","summary":"any command; the number is its last output line or what a parser reads from its artifact","requires":[],"needs_tree":false}\n' ;;
    explain)
        printf 'Runs the row'"'"'s command. The number it compares is the command'"'"'s last output line, or what the\n'
        printf 'named parser reads from the artifact. Run the reproduce line to see the command'"'"'s own output.\n' ;;
    run)
        printf 'shell rows run inside guard.sh; run them with: qg run <commit|push> --only <id>\n' >&2; exit 2 ;;
    *)
        printf 'usage: shell.sh describe | explain [<ruleId>] | run\n' >&2; exit 2 ;;
esac
