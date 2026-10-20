#!/usr/bin/env bash
# The one reader of a repo's gate keys. Sourced by lib/guard-pass.sh; defines functions only.
#
# Keys are flat `key: value` lines in quality/config. A key that file does not hold is unset, and
# takes its default. Key list: extend/dod-keys.tsv.
#
# The config revision is the commit whose configuration judges this run, so an uncommitted or
# staged edit cannot change a key: GUARD_CONFIG_REV under `guard.sh release`, else what
# guard_config_show reads (GUARD_CONFIG_AT, else HEAD, else the index on a first commit).

# guard_cfg_show <path> -> the file at the config revision; exit non-zero when it is absent.
guard_cfg_show() {
    if [ -n "${GUARD_CONFIG_REV:-}" ]; then git show "${GUARD_CONFIG_REV}:$1" 2>/dev/null
    else guard_config_show "$1"; fi
}

# qg_config_key <key> -> the value, trimmed, backslashes removed. Exit 1 when the key is absent.
qg_config_key() {
    local line
    line="$(guard_cfg_show quality/config | grep -m1 "^${1}:")" || return 1
    line="${line#*:}"
    printf '%s' "${line//\\/}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}
