#!/usr/bin/env bash
# `qg init` (gate a new repo). Sourced by bin/qg; defines functions only. It writes the working
# tree and never commits: the commit that changes the gate configuration is a human's, made with
# `qg override`, because the gate refuses it otherwise.

# The gate files `qg init` protects, by exact path.
QG_INIT_PROTECTED='quality/checks.tsv quality/baseline.tsv quality/rules.tsv quality/config quality/drivers'

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
    # The gate files by exact path: a repo's quality/ may hold other files a commit may change. The
    # docs profile adds every .doc-lint, since each one turns doc-lint checks off.
    local protected="$QG_INIT_PROTECTED" lint='' f
    if [ "$profile" = docs ]; then
        protected="${protected} .doc-lint"
        while IFS= read -r -d '' f; do
            case "$f" in
                *[[:space:]]*) printf 'qg init: %s holds a space, so guard_protected_paths cannot list it; protect it by hand or rename it.\n' "$f" >&2 ;;
                .doc-lint) ;;
                *) protected="${protected} ${f}" ;;
            esac
        done < <(git ls-files -z -- ':(glob)**/.doc-lint' 2>/dev/null)
        # The linter that judges every commit; the human running init picks it.
        if [ -n "${VAULT_FRAMEWORK_PATH:-}" ]; then lint="$(realpath -m "${VAULT_FRAMEWORK_PATH}/bin/doc-lint.sh")"
        else lint="${HOME}/workspace/vault/bin/doc-lint.sh"; fi
        [ -x "$lint" ] || printf 'qg init: %s is not executable; set guard_doc_lint in quality/config to the vault framework bin/doc-lint.sh, or every doc-lint measurement refuses.\n' "$lint" >&2
    fi
    if [ ! -e quality/config ]; then
        printf '%s\n' '# Gate keys for vault-quality-gates (lib/qg-config.sh).' \
            "guard_protected_paths: ${protected}" 'guard_accept_limit: 3' > quality/config
        [ -z "$lint" ] || printf 'guard_doc_lint: %s\n' "$lint" >> quality/config
        # The Dart drivers run only the SDK this key names; the human running init picks it.
        if [ "$profile" = flutter ]; then
            local flutter
            if flutter="$(command -v flutter)"; then
                printf 'guard_flutter_root: %s\n' "$(dirname "$(dirname "$(readlink -f "$flutter")")")" >> quality/config
            else
                printf 'qg init: no flutter on PATH; add guard_flutter_root: <Flutter SDK folder> to quality/config, or every Dart row refuses.\n' >&2
            fi
        fi
    else
        local have p missing=''
        have=" $(sed -n 's/^guard_protected_paths:[[:space:]]*//p' quality/config | head -1) "
        for p in $protected; do [[ "$have" == *" ${p} "* ]] || missing="${missing} ${p}"; done
        [ -z "$missing" ] || printf 'qg init: quality/config exists and is left as it is; add to guard_protected_paths:%s\n' "$missing" >&2
        [ -z "$lint" ] || grep -q '^guard_doc_lint:' quality/config \
            || printf 'qg init: quality/config has no guard_doc_lint; add guard_doc_lint: %s, or every doc-lint measurement refuses.\n' "$lint" >&2
    fi
    printf 'qg init: wrote quality/checks.tsv (profile %s), rules.tsv, baseline.tsv and config.\n' "$profile"
    printf 'Next:\n  1. qg hooks install [--claude]\n  2. git add quality (and .claude/settings.json after --claude), then commit\n  3. qg doctor\n'
}
