#!/usr/bin/env bash
# The one reader of a repo's gate keys. Sourced by lib/guard-pass.sh; defines functions only.
#
# Keys are flat `key: value` lines. They live in quality/config; a repo without that file keeps
# them in VAULT.md. The two files never mix: when quality/config exists at the config revision,
# VAULT.md is not read. Key list: extend/dod-keys.tsv.
#
# The config revision is the commit whose configuration judges this run, so an uncommitted or
# staged edit cannot change a key: GUARD_CONFIG_REV under `guard.sh release`, else what
# guard_config_show reads (GUARD_CONFIG_AT, else HEAD, else the index on a first commit).

# guard_cfg_show <path> -> the file at the config revision; exit non-zero when it is absent.
guard_cfg_show() {
    if [ -n "${GUARD_CONFIG_REV:-}" ]; then git show "${GUARD_CONFIG_REV}:$1" 2>/dev/null
    else guard_config_show "$1"; fi
}

# qg_config_source -> prints `quality/config` or `VAULT.md`, whichever holds the keys; exit 1
# when neither exists at the config revision.
qg_config_source() {
    if guard_cfg_show quality/config >/dev/null; then printf 'quality/config'
    elif guard_cfg_show VAULT.md >/dev/null; then printf 'VAULT.md'
    else return 1; fi
}

# qg_config_key <key> -> the value, trimmed. Exit 1 when the key is absent. Prettier escapes `*`
# as `\*` in VAULT.md; the backslashes are removed.
qg_config_key() {
    local src line
    src="$(qg_config_source)" || return 1
    line="$(guard_cfg_show "$src" | grep -m1 "^${1}:")" || return 1
    line="${line#*:}"
    printf '%s' "${line//\\/}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}
