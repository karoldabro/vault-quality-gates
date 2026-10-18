#!/usr/bin/env bash
# lock-check.sh — sourced by quality/bin/in-tree.sh and quality/bin/in-server.sh. Defines two checks
# a runner makes before it starts the container; both print the cause on stderr and return 2.
#
# lock_check_vendor <composer.lock> <vendor dir>
#   vendor/composer/installed.json must list exactly the name and version set of <composer.lock>,
#   packages and packages-dev alike. The files under vendor/ are not hashed.
#
# lock_check_tools <reference composer.lock> <tree composer.lock>
#   A commit may update its own dependencies, never the tools that judge it. Every package must keep
#   the reference version except a `packages` entry outside the dependency closure of every
#   `packages-dev` entry in either lock. A package present in only one lock differs in its class.
#   The closure follows `require` through every package of the lock, so a rule extension, a tool's
#   engine (pdepend/pdepend) and a shared parser (nikic/php-parser) are all tool packages.

# lock_names <composer.lock> -> "name version" per package, sorted.
lock_names() { jq -r '((.packages // []) + (."packages-dev" // []))[] | "\(.name) \(.version)"' "$1" 2>/dev/null | sort; }

lock_check_vendor() {
    local lock="$1" vendor="$2" installed locked
    [ -r "$lock" ] || { echo "lock-check: ${lock} does not exist" >&2; return 2; }
    installed="$(jq -r '(.packages // .)[] | "\(.name) \(.version)"' "${vendor}/composer/installed.json" 2>/dev/null | sort)" || installed=''
    locked="$(lock_names "$lock")"
    if [ -z "$installed" ] || [ "$installed" != "$locked" ]; then
        echo "lock-check: ${vendor} does not match ${lock}; run composer install" >&2
        # comm, not diff: busybox diff prints a unified diff, GNU diff a normal one.
        comm -3 <(printf '%s\n' "$locked") <(printf '%s\n' "$installed") \
            | awk -F'\t' '{ print ($1 != "" ? "  lock:   " $1 : "  vendor: " $2) }' | head -n 10 >&2
        return 2
    fi
}

# lock_tool_closure <composer.lock> -> the names reachable from every packages-dev entry, one per line.
lock_tool_closure() {
    jq -r '
        def grow($req): . as $s
            | ($s + [$s[] | ($req[.] // [])[] | select($req[.] != null)] | unique) as $n
            | if ($n | length) == ($s | length) then $s else ($n | grow($req)) end;
        ((.packages // []) + (."packages-dev" // [])) as $all
        | ($all | map({key: .name, value: ((.require // {}) | keys)}) | from_entries) as $req
        | [(."packages-dev" // [])[].name] | grow($req)[]' "$1" 2>/dev/null
}

lock_check_tools() {
    local ref="$1" tree="$2" changed tools bad
    [ -r "$ref" ] && [ -r "$tree" ] || { echo "lock-check: cannot read ${ref} or ${tree}" >&2; return 2; }
    changed="$(comm -3 <(lock_names "$ref") <(lock_names "$tree") | tr -d '\t' | cut -d' ' -f1 | sort -u)"
    [ -n "$changed" ] || return 0
    tools="$( { lock_tool_closure "$ref"; lock_tool_closure "$tree"; } | sort -u)"
    bad="$(comm -12 <(printf '%s\n' "$changed") <(printf '%s\n' "$tools"))"
    [ -z "$bad" ] && return 0
    echo "lock-check: this commit changes packages the gate's tools are built from; a human commits that with qg override:" >&2
    printf '%s\n' "$bad" | head -n 10 | sed 's/^/  /' >&2
    return 2
}
