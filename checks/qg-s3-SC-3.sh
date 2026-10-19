#!/usr/bin/env bash
# S3 SC-3 — qg_pnpm_prepare (lib/qg-driver-kit.sh) runs the host's pnpm with no configuration of the
# caller. With a hostile ~/.npmrc, $XDG_CONFIG_HOME/pnpm/rc, $XDG_CONFIG_HOME/pnpm/config.yaml, a
# .npmrc in the temp folder and in its parent, a hostile npm_config_userconfig, and the registry,
# proxy and CA variables exported, each alone and all together, the prepared pnpm resolves
# `registry` to https://registry.npmjs.org/, `@jscpd:registry` to no value, `store-dir`, `cache-dir`
# and `pnpm store path` under <git-common-dir>/guard-cache/pnpm, and no proxy or CA file; and no
# variable of the caller but PATH and LANG reaches pnpm.
#
# Everything lives in one mktemp folder. HOME, XDG_CONFIG_HOME and TMPDIR point into it, so the real
# ~/.npmrc and /tmp/.npmrc are never read or written: TMPDIR stands in for /tmp, and the work folder
# is made with mktemp -d below it, as qg_jscpd_report makes it. The all-sources case first asks plain
# pnpm, from a sibling folder, for the registry: a fixture plain pnpm does not obey proves nothing.
#
# Exit 0 pass, 1 fail, 2 could not run (no pnpm, git or mktemp).
exec < /dev/null
set -uo pipefail
export LC_ALL=C
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
PUBLIC=https://registry.npmjs.org/
EVIL=https://evil.invalid/

command -v pnpm >/dev/null || { echo 'pnpm is not on PATH'; exit 2; }
W="$(mktemp -d)" || exit 2
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/home" "$W/xdg/pnpm" "$W/parent/tmp/plain" "$W/repo" "$W/shim" || exit 2
export HOME="$W/home" XDG_CONFIG_HOME="$W/xdg" TMPDIR="$W/parent/tmp"
git -C "$W/repo" init -q || exit 2
QG_CACHE="$(git -C "$W/repo" rev-parse --path-format=absolute --git-common-dir)/guard-cache" || exit 2
CACHE="${QG_CACHE}/pnpm"
# shellcheck source=../lib/qg-driver-kit.sh
. "$ROOT/lib/qg-driver-kit.sh"

rc_text() {
    printf '%s\n' "registry=${EVIL}" "@jscpd:registry=${EVIL}" "store-dir=${W}/evil-store" "cache-dir=${W}/evil-cache" \
        'proxy=http://evil.invalid:1/' 'https-proxy=http://evil.invalid:1/' "cafile=${W}/evil-ca.pem" 'strict-ssl=false'
}
SOURCES='home-npmrc xdg-rc xdg-config-yaml tmp-npmrc parent-npmrc npm_config_userconfig npm_config_registry NPM_CONFIG_REGISTRY pnpm_config_registry PNPM_CONFIG_REGISTRY Pnpm_Config_Registry store-and-cache-env proxy-and-ca-env'
VARS='npm_config_userconfig npm_config_registry NPM_CONFIG_REGISTRY pnpm_config_registry PNPM_CONFIG_REGISTRY Pnpm_Config_Registry
npm_config_store_dir pnpm_config_store_dir npm_config_cache_dir pnpm_config_cache_dir NPM_CONFIG_STORE_DIR
HTTPS_PROXY https_proxy HTTP_PROXY http_proxy npm_config_https_proxy NODE_EXTRA_CA_CERTS npm_config_cafile NODE_OPTIONS'

disarm() {
    rm -f "$W/home/.npmrc" "$W/xdg/pnpm/rc" "$W/xdg/pnpm/config.yaml" "$W/parent/tmp/.npmrc" "$W/parent/.npmrc" "$W/evil-user.rc"
    # shellcheck disable=SC2086
    unset $VARS
}
arm() {
    case "$1" in
        home-npmrc) rc_text > "$W/home/.npmrc" ;;
        xdg-rc) rc_text > "$W/xdg/pnpm/rc" ;;
        xdg-config-yaml) printf '%s\n' "registry: ${EVIL}" "storeDir: ${W}/evil-store" "cacheDir: ${W}/evil-cache" \
                             'httpsProxy: http://evil.invalid:1/' > "$W/xdg/pnpm/config.yaml" ;;
        tmp-npmrc) rc_text > "$W/parent/tmp/.npmrc" ;;
        parent-npmrc) rc_text > "$W/parent/.npmrc" ;;
        npm_config_userconfig) rc_text > "$W/evil-user.rc"; export npm_config_userconfig="$W/evil-user.rc" ;;
        store-and-cache-env)
            export npm_config_store_dir="$W/evil-store" pnpm_config_store_dir="$W/evil-store" NPM_CONFIG_STORE_DIR="$W/evil-store"
            export npm_config_cache_dir="$W/evil-cache" pnpm_config_cache_dir="$W/evil-cache" ;;
        proxy-and-ca-env)
            export HTTPS_PROXY=http://evil.invalid:1/ https_proxy=http://evil.invalid:1/ HTTP_PROXY=http://evil.invalid:1/
            export http_proxy=http://evil.invalid:1/ npm_config_https_proxy=http://evil.invalid:1/
            export NODE_EXTRA_CA_CERTS="$W/evil-ca.pem" npm_config_cafile="$W/evil-ca.pem" NODE_OPTIONS="--require $W/evil.js" ;;
        all) for s in $SOURCES; do arm "$s"; done ;;
        *) export "$1=$EVIL" ;;
    esac
}

pass=0 total=0
fail() { printf '  FAILING  %s\n' "$*"; }
# check <case> -> prepares a work folder as qg_jscpd_report does and asks the prepared pnpm.
check() {
    local c="$1" work v bad=''
    work="$(mktemp -d)" || return 2
    qg_pnpm_prepare "$work" || { rm -rf "$work"; echo "qg_pnpm_prepare failed"; return 2; }
    q() { ( cd "$work" && "${QG_PNPM[@]}" "$@" 2>&1 ) | tail -1; }
    v="$(q config get registry)";        [ "$v" = "$PUBLIC" ] || bad+=" registry=${v}"
    v="$(q config get @jscpd:registry)"; case "$v" in ''|undefined) ;; *) bad+=" @jscpd:registry=${v}" ;; esac
    v="$(q config get store-dir)";       [[ "$v" == "$CACHE"/* ]] || bad+=" store-dir=${v}"
    v="$(q config get cache-dir)";       [[ "$v" == "$CACHE"/* ]] || bad+=" cache-dir=${v}"
    v="$(q store path)";                 [[ "$v" == "$CACHE"/* ]] || bad+=" store-path=${v}"
    for k in proxy https-proxy cafile; do
        v="$(q config get "$k")";        case "$v" in ''|undefined|null) ;; *) bad+=" ${k}=${v}" ;; esac
    done
    # The same command with a shim pnpm first on PATH prints the environment pnpm would get.
    printf '#!/bin/sh\nenv\n' > "$W/shim/pnpm" && chmod +x "$W/shim/pnpm"
    PATH="$W/shim:$PATH" qg_pnpm_prepare "$work" || return 2
    v="$( (cd "$work" && "${QG_PNPM[@]}") | cut -d= -f1 | grep -vxE 'PATH|LANG|HOME|XDG_CONFIG_HOME|npm_config_userconfig|npm_config_globalconfig|PWD|SHLVL|_|OLDPWD' | tr '\n' ' ')"
    [ -z "$v" ] || bad+=" variables reaching pnpm: ${v}"
    [ ! -e "$W/evil-ran" ] || bad+=" NODE_OPTIONS --require ran"
    rm -rf "$work"
    total=$((total + 1))
    if [ -z "$bad" ]; then pass=$((pass + 1)); else fail "${c}:${bad}"; fi
}

printf "require('fs').writeFileSync('%s', 'x')\n" "$W/evil-ran" > "$W/evil.js"
disarm
arm all
plain="$(cd "$W/parent/tmp/plain" && pnpm config get registry 2>&1 | tail -1)"
[ "$plain" = "$EVIL" ] || { echo "plain pnpm with every hostile source resolves registry to ${plain}, not ${EVIL}: the fixture proves nothing"; exit 1; }
rm -f "$W/evil-ran"
check all || exit 2
obeys=''
for s in $SOURCES; do
    disarm; arm "$s"
    v="$(cd "$W/parent/tmp/plain" && pnpm config get registry 2>&1 | tail -1)"
    [ "$v" != "$EVIL" ] || obeys+=" $s"
    rm -f "$W/evil-ran"
    check "$s" || exit 2
done
disarm

echo "pnpm $(pnpm --version) at $(command -v pnpm); without isolation its registry follows:${obeys:- nothing}"
if [ "$pass" -ne "$total" ]; then printf '%s of %s cases failing\n' "$((total - pass))" "$total"; exit 1; fi
printf '%s of %s cases passing\n' "$total" "$total"
