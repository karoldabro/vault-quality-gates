# Shared by the commit-gate bats files. Loaded with `load guard-helpers`; bats runs only
# *.bats, so this file is never run on its own. Every repo lives under mktemp -d.

CHECKS_HEADER=$'id\tscope\tkind\tcommand\tparser\tartifact\tdirection\tthreshold\tgate'
RULES_HEADER=$'id\ttool\tenforced_by\temits'

# new_repo <dir> — an empty repository with an identity, cwd set to it.
new_repo() {
    mkdir -p "$1"
    cd "$1" || return 1
    git init -q .
    git config user.email 'test@example.invalid'
    git config user.name 'test'
    git config commit.gpgsign false
}

# write_checks <row>... — quality/checks.tsv with the header and the given tab-separated rows.
write_checks() {
    mkdir -p quality
    { printf '%s\n' "$CHECKS_HEADER"; printf '%s\n' "$@"; } > quality/checks.tsv
}

# write_rules [<row>...] — quality/rules.tsv with the header and the given rows.
write_rules() {
    mkdir -p quality
    { printf '%s\n' "$RULES_HEADER"; [ $# -eq 0 ] || printf '%s\n' "$@"; } > quality/rules.tsv
}

# commit_all <message> — stages everything and commits with no hook.
commit_all() {
    git add -A && git -c core.hooksPath=/dev/null commit -q --allow-empty -m "$1"
}

# A row that counts staged-tree files under app/ containing the word BAD. Ceiling 0.
BAD_ROW=$'bad-in-tree\tcommit\tdiff\tgrep -rl BAD {{tree}}/app 2>/dev/null | wc -l\t-\t-\tdown\t0\trefuse'
SUPPRESS_ROW=$'suppressions-added\tcommit\tdiff\t{{guard}}/guard-added-lines.sh --grep \'@phpstan-ignore\' --bases "{{bases}}" --target {{target}}\t-\t-\tdown\t0\trefuse'
PROTECT_ROW=$'gate-config-touched\tcommit\tdiff\t{{guard}}/guard-protected-paths.sh --bases "{{bases}}" --target {{target}}\t-\t-\tdown\t0\trefuse'
GROWTH_ROW=$'baseline-growth\tcommit\tdiff\t{{guard}}/guard-baseline-growth.sh --bases "{{bases}}" --target {{target}}\t-\t-\tdown\t0\trefuse'

# gate_repo <dir> — a repo whose HEAD carries the four rows above, an empty rules map, and
# VAULT.md gating app/ and protecting quality/ and phpstan.neon.
gate_repo() {
    new_repo "$1"
    write_checks "$BAD_ROW" "$SUPPRESS_ROW" "$PROTECT_ROW" "$GROWTH_ROW"
    write_rules
    printf 'guard_commit_paths: app\nguard_protected_paths: quality phpstan.neon VAULT.md\n' > VAULT.md
    mkdir -p app docs
    printf 'clean\n' > app/a.php
    commit_all init
}

# pass_key_of_commit <rev> / pass_record_of <rev> — the pass-record key and its content.
pass_key_of_commit() { ( . /code/lib/guard-pass.sh; guard_pass_key_of_commit "$1" ); }
pass_record_of() { cat "$(git rev-parse --path-format=absolute --git-common-dir)/guard-pass/$(pass_key_of_commit "$1")" 2>/dev/null; }
