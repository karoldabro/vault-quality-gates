#!/usr/bin/env bats
# A checkstyle row through the commit gate: the runner the row names runs as committed at the config
# revision, so a commit that edits its own lint runner is judged by the parent's copy and refused by
# the protected-paths row.

load guard-helpers

V2_HEADER=$'id\ton\tkind\tdriver\targs\tdirection\tthreshold\tgate\twhy'

setup() {
    export LC_ALL=C
    WORK="$(mktemp -d)"
    export GUARD_LOCK_WAIT=5 SENTINEL="$WORK/sentinel"
    unset QG_SKIP_REASON CLAUDECODE AI_AGENT GUARD_CONFIG_REV
    gate_repo "$WORK/repo"
}

teardown() {
    [ -n "${WORK:-}" ] && [ -d "$WORK" ] && rm -rf "$WORK"
    return 0
}

# lint_runner <errors> [touch] — quality/bin/lint.sh writing <tree>/lint.xml with <errors> errors.
lint_runner() {
    mkdir -p quality/bin
    { printf '#!/usr/bin/env bash\n'
      [ -z "${2:-}" ] || printf 'touch "%s"\n' "$SENTINEL"
      printf 'printf "<?xml version=\\"1.0\\"?>\\n<checkstyle><file name=\\"app/a.php\\">" > "$1/lint.xml"\n'
      printf 'for i in $(seq 1 %s); do printf "<error line=\\"1\\" severity=\\"error\\" message=\\"m\\" source=\\"r\\"/>" >> "$1/lint.xml"; done\n' "$1"
      printf 'printf "</file></checkstyle>\\n" >> "$1/lint.xml"\n'
    } > quality/bin/lint.sh
    chmod +x quality/bin/lint.sh
}

@test "a staged edit to the lint runner never runs: the parent's runner judges, and protected-paths-touched refuses" {
    lint_runner 0
    { printf '%s\n' "$V2_HEADER"
      printf 'lint\tcommit\tdiff\tcheckstyle\trunner=quality/bin/lint.sh report=lint.xml\tdown\t0\trefuse\tlint errors stay at zero\n'
      printf 'protected\tcommit\tdiff\tshell\t-- "{{guard}}/guard-protected-paths.sh" --bases "{{bases}}" --target "{{target}}"\tdown\t0\trefuse\tthe gate is changed by a human only\n'
    } > quality/checks.tsv
    printf 'guard_protected_paths: quality\n' > quality/config
    commit_all lint
    lint_runner 5 touch
    printf 'x\n' > app/b.php
    git add quality/bin/lint.sh app/b.php
    run bash /code/bin/guard.sh commit
    [ "$status" -eq 1 ]
    [[ "$output" == *protected* ]]
    [ ! -e "$SENTINEL" ]
    [ "$(jq -r .metric "$(git rev-parse --git-common-dir)/qg-last/lint/result.json")" = 0 ]
}
