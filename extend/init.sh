#!/usr/bin/env bash
# vault-quality-gates — the `init` extension point.
#
# The vault framework runs this during bin/vault-init.sh, after VAULT.md exists, through this
# shebang in a child process with stdin closed. Arguments: <code-repo> <vault-dir> <slug>.
#
# It scaffolds `quality/checks.tsv` and records the keys extend/dod-keys.tsv declares. Adding the
# plugin's name to `plugins:` is what makes those keys required, so both happen in one pass or the
# repo this just onboarded would fail `bin/gate.sh config`.
#
# Exit 0 on every path. Running twice changes nothing the second time.

set -u

PLUGIN_NAME="vault-quality-gates"
RELEASE_PATTERN_DEFAULT="refs/heads/release/*"

code_repo=${1:-}
[ -n "${code_repo}" ] || exit 0

vault_md="${code_repo}/VAULT.md"
# The framework skips this point when VAULT.md is absent. Re-checking costs nothing and makes the
# script safe to run by hand.
[ -f "${vault_md}" ] || exit 0

# --- quality/checks.tsv -------------------------------------------------------------------
#
# Header only. The rows are per stack and per repo, and a guessed row would gate a push on a tool
# nobody chose. `/v-guard init` fills them after it has run each command once.

mkdir -p "${code_repo}/quality" || exit 1

checks="${code_repo}/quality/checks.tsv"
if [ ! -f "${checks}" ]; then
    {
        printf 'id\tscope\tkind\tcommand\tparser\tartifact\tdirection\tthreshold\tgate\n'
        printf '# One row per metric. Columns and legal values: vault/architecture/guard-file-formats.md\n'
        printf '# in the vault-quality-gates repo. Empty cells are written `-`, never left blank.\n'
        printf '# No rows yet: run `/v-guard init` to detect this stack and prove each command runs\n'
        printf '# before it is recorded. A guessed row gates a push on a tool nobody chose.\n'
    } > "${checks}" || exit 1
fi

# --- merge into the plugins scalar --------------------------------------------------------

# A VAULT.md with no trailing newline would fuse the first key below onto its last line.
[ -n "$(tail -c1 "${vault_md}")" ] && printf '\n' >> "${vault_md}"

if [ "$(grep -c '^plugins:' "${vault_md}")" -gt 1 ]; then
    printf '  %s: VAULT.md has more than one plugins: line — writing nothing\n' "${PLUGIN_NAME}" >&2
    exit 1
fi

current=$(sed -n 's/^plugins:[[:space:]]*//p' "${vault_md}" | head -1 | tr -d '\r')

if ! grep -q '^plugins:' "${vault_md}"; then
    printf 'plugins: %s\n' "${PLUGIN_NAME}" >> "${vault_md}"
elif [ -z "${current}" ]; then
    sed -i "s|^plugins:.*|plugins: ${PLUGIN_NAME}|" "${vault_md}"
elif printf '%s' "${current}" | tr ',' '\n' | tr -d '[:space:]' | grep -qx "${PLUGIN_NAME}"; then
    :   # already listed
else
    sed -i "s|^\(plugins:.*\)$|\1, ${PLUGIN_NAME}|" "${vault_md}"
fi

# --- every key extend/dod-keys.tsv declares -----------------------------------------------

grep -q '^guard_release_pattern:' "${vault_md}" \
    || printf 'guard_release_pattern: %s\n' "${RELEASE_PATTERN_DEFAULT}" >> "${vault_md}"

printf '  %s: scaffolded %s\n' "${PLUGIN_NAME}" "${checks}"
exit 0
