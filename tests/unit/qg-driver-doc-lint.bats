#!/usr/bin/env bats
# drivers/doc-lint.sh — document-standard findings a commit adds. Counting rules:
# vault/plans/2026-10-19-1930-qg-s5-docs-repos.test-design.md (DT-1..DT-3).
#
# The linter is the fixture tests/fixtures/drivers/doc-lint, copied to $WORK/fw so its control
# files can be written: a line holding LINT:<CODE> is a finding on that line, FILELINT:<CODE> a
# file-level one, DUPLINT a DUP1 x3, SCOPE:<v> an INDEX3 unless VAULT.md declares <v>. It honours
# the nearest .doc-lint and VAULT.md, DOC_LINT=off and DOC_LINT_SKIP, as the framework linter does.
# `measure` builds <git-common-dir>/guard-tree from the index, as the commit gate does, and runs the
# driver with the engine's environment.

load guard-helpers

DRIVER=/code/drivers/doc-lint.sh
FIXTURE=/code/tests/fixtures/drivers/doc-lint

setup() {
    export LC_ALL=C
    WORK="$(mktemp -d)"
    unset QG_RUNNER QG_ARGS QG_RUN_DIR CLAUDECODE AI_AGENT DOC_LINT DOC_LINT_SKIP DOC_LINT_PATTERNS VAULT_FRAMEWORK_PATH
    cp -r "$FIXTURE" "$WORK/fw"
    LINTER="$WORK/fw/bin/doc-lint.sh"
    new_repo "$WORK/repo"
    mkdir -p quality plans support
    printf 'guard_doc_lint: %s\n' "$LINTER" > quality/config
    printf -- '---\ntype: guide\n---\n# Guide\n\nclean line\n' > support/guide.md
    printf -- '---\ntype: plan\n---\n# Plan\n\nclean line\n' > plans/p.md
    commit_all base
    export QG_REPO="$WORK/repo"
    TREE="$WORK/repo/.git/guard-tree"
}

teardown() {
    [ -n "${WORK:-}" ] && [ -d "$WORK" ] && rm -rf "$WORK"
    return 0
}

# measure [<base sha>...] — runs the driver on the index against HEAD (or the given parents).
measure() {
    local bases="${*:-$(git -C "$QG_REPO" rev-parse HEAD)}" first
    first="${bases%% *}"
    rm -rf "$TREE" && mkdir -p "$TREE"
    git -C "$QG_REPO" checkout-index -a -f --prefix="$TREE/"
    rm -rf "$WORK/out" && mkdir -p "$WORK/out"
    ( cd "$QG_REPO" && git diff --cached --name-only -z --diff-filter=ACMR -M30% "$first" ) > "$WORK/files"
    QG_OUT="$WORK/out" QG_TREE="$TREE" QG_FILES="$WORK/files" QG_BASE="$first" QG_BASES="$bases" \
        QG_TARGET=:index QG_CONFIG_REV="$(git -C "$QG_REPO" rev-parse HEAD)" QG_ROW=doc-lint \
        run "$DRIVER" run
}

result() { jq -r "$1" "$WORK/out/result.json"; }
metric() { result '.metric'; }
rules() { result '[.findings[].ruleId] | sort | join(",")'; }

@test "describe is JSON naming doc-lint with needs_tree true; explain prints text for each code" {
    run "$DRIVER" describe
    [ "$status" -eq 0 ]
    [ "$(jq -r '.name' <<<"$output")" = doc-lint ]
    [ "$(jq -r '.needs_tree' <<<"$output")" = true ]
    for r in '' doc-lint.SKIPFILE doc-lint.TYPE doc-lint.LONG1; do
        run "$DRIVER" explain $r
        [ "$status" -eq 0 ] && [ -n "$output" ]
    done
}

@test "a finding on an added line counts 1" {
    printf 'LINT:LONG1 too long\n' >> support/guide.md
    git add support/guide.md
    measure
    [ "$(result .status)" = measured ]
    [ "$(metric)" = 1 ]
    [ "$(rules)" = doc-lint.LONG1 ]
    [ "$(result '.findings[0].file')" = support/guide.md ]
    [ "$(result '.findings[0].line')" = 7 ]
}

@test "a finding on an unchanged line of a changed file is not counted" {
    printf 'LINT:LONG1 old\n' >> support/guide.md
    commit_all old
    printf 'clean addition\n' >> support/guide.md
    git add support/guide.md
    measure
    [ "$(metric)" = 0 ]
    [ "$(result '.findings | length')" = 0 ]
}

@test "a file-level finding on a file the commit creates counts 1" {
    printf -- '---\ntype: guide\n---\nFILELINT:SIZE1\n' > support/new.md
    git add support/new.md
    measure
    [ "$(metric)" = 1 ]
    [ "$(rules)" = doc-lint.SIZE1 ]
    [ "$(result '.findings[0].line')" = null ]
}

@test "a file-level code the parent's version already has is not counted" {
    printf 'FILELINT:SIZE1\n' >> support/guide.md
    commit_all big
    printf 'clean addition\n' >> support/guide.md
    git add support/guide.md
    measure
    [ "$(metric)" = 0 ]
}

@test "a file-level code the parent's version lacks counts 1" {
    printf 'FILELINT:PLAN2\n' >> plans/p.md
    git add plans/p.md
    measure
    [ "$(metric)" = 1 ]
    [ "$(rules)" = doc-lint.PLAN2 ]
}

@test "a merge does not count a file-level code that any parent already has" {
    base="$(git rev-parse HEAD)"
    git checkout -q -b side
    printf 'FILELINT:SIZE1\n' >> support/guide.md
    commit_all side
    side="$(git rev-parse HEAD)"
    git checkout -q master 2>/dev/null || git checkout -q main
    printf 'unrelated\n' > support/other.md
    commit_all main-side
    main="$(git rev-parse HEAD)"
    git -c core.hooksPath=/dev/null merge -q --no-commit "$side" >/dev/null 2>&1 || true
    git add -A
    measure "$main" "$side"
    [ "$(metric)" = 0 ]
    [ -n "$base" ]
}

@test "a DUP1 x<n> finding parses as a line-null finding, not an error" {
    printf -- '---\ntype: guide\n---\nDUPLINT\n' > support/dup.md
    git add support/dup.md
    measure
    [ "$(result .status)" = measured ]
    [ "$(rules)" = doc-lint.DUP1 ]
    [ "$(result '.findings[0].line')" = null ]
}

@test "a file with no type: in a top-level document folder is linted" {
    printf '# Untyped plan\nLINT:LONG1 long\n' > plans/untyped.md
    git add plans/untyped.md
    measure
    [ "$(metric)" = 1 ]
    [ "$(rules)" = doc-lint.LONG1 ]
}

@test "an untracked .doc-lint at the working-tree root or in .git does not change the metric" {
    printf 'LONG1\n' > .doc-lint
    printf 'LONG1\n' > .git/.doc-lint
    printf 'LINT:LONG1 long\n' >> support/guide.md
    git add support/guide.md
    measure
    [ "$(metric)" = 1 ]
}

@test "a .doc-lint the commit adds in a subfolder is ignored and counts 1 as doc-lint.SKIPFILE" {
    printf 'LONG1\n' > support/.doc-lint
    printf 'LINT:LONG1 long\n' >> support/guide.md
    git add support/.doc-lint support/guide.md
    measure
    [ "$(metric)" = 2 ]
    [ "$(rules)" = doc-lint.LONG1,doc-lint.SKIPFILE ]
}

@test "a .doc-lint the commit adds at the root is ignored and counts 1 as doc-lint.SKIPFILE" {
    printf 'LONG1\n' > .doc-lint
    printf 'LINT:LONG1 long\n' >> support/guide.md
    git add .doc-lint support/guide.md
    measure
    [ "$(metric)" = 2 ]
    [ "$(rules)" = doc-lint.LONG1,doc-lint.SKIPFILE ]
}

@test "a commit that edits a tracked .doc-lint is linted with the config revision's copy and counts 1 as doc-lint.SKIPFILE" {
    printf '# nothing skipped\n' > plans/.doc-lint
    commit_all skipfile
    printf 'LONG1\n' >> plans/.doc-lint
    printf 'LINT:LONG1 long\n' >> plans/p.md
    git add plans/.doc-lint plans/p.md
    measure
    [ "$(metric)" = 2 ]
    [ "$(rules)" = doc-lint.LONG1,doc-lint.SKIPFILE ]
}

@test "a committed .doc-lint at the config revision still applies" {
    printf 'LONG1\n' > plans/.doc-lint
    commit_all skipfile
    printf 'LINT:LONG1 long\n' >> plans/p.md
    git add plans/p.md
    measure
    [ "$(metric)" = 0 ]
}

@test "a VAULT.md the commit edits or adds, at the root or in a subfolder, does not change INDEX3 and counts 1 as doc-lint.SKIPFILE" {
    mkdir -p indications
    printf 'indication_scopes: [a, b]\n' > VAULT.md
    printf -- '---\ntype: index\n---\nSCOPE:a\n' > indications/_index.md
    commit_all vault
    printf 'SCOPE:zzz\n' >> indications/_index.md
    printf 'indication_scopes: [a, b, zzz]\n' > VAULT.md
    git add VAULT.md indications/_index.md
    measure
    [ "$(rules)" = doc-lint.INDEX3,doc-lint.SKIPFILE ]
    git checkout -q HEAD -- VAULT.md
    printf 'indication_scopes: [zzz]\n' > indications/VAULT.md
    git add indications/VAULT.md indications/_index.md
    measure
    [ "$(rules)" = doc-lint.INDEX3,doc-lint.SKIPFILE ]
}

@test "changing or removing an existing file's type: counts 1 as doc-lint.TYPE" {
    sed -i 's/^type: guide$/type: skill/' support/guide.md
    printf 'LINT:LONG1 long\n' >> support/guide.md
    git add support/guide.md
    measure
    [ "$(rules)" = doc-lint.TYPE ]
    printf -- '---\ntitle: x\n---\nLINT:LONG1 long\n' > support/guide.md
    git add support/guide.md
    measure
    [ "$(rules)" = doc-lint.TYPE ]
}

@test "type:guide with no space, and a blank line before the frontmatter, count 1 as doc-lint.TYPE" {
    sed -i 's/^type: guide$/type:guide/' support/guide.md
    git add support/guide.md
    measure
    [ "$(rules)" = doc-lint.TYPE ]
    git checkout -q HEAD -- support/guide.md
    { printf '\n'; cat support/guide.md; } > "$WORK/g" && cp "$WORK/g" support/guide.md
    git add support/guide.md
    measure
    [ "$(rules)" = doc-lint.TYPE ]
}

@test "a renamed file whose type changes counts 1 as doc-lint.TYPE" {
    git mv support/guide.md support/kb.md
    sed -i 's/^type: guide$/type: persona/' support/kb.md
    git add support/kb.md
    measure
    [ "$(rules)" = doc-lint.TYPE ]
}

@test "a new file with an instruction type counts 1 as doc-lint.TYPE" {
    printf -- '---\ntype: skill\n---\nLINT:LONG1 long\n' > support/s.md
    git add support/s.md
    measure
    [ "$(metric)" = 1 ]
    [ "$(rules)" = doc-lint.TYPE ]
}

@test "a plain rename of a file with an old file-level finding counts 0" {
    printf 'FILELINT:SIZE1\n' >> support/guide.md
    commit_all big
    git mv support/guide.md support/kb.md
    measure
    [ "$(metric)" = 0 ]
}

@test "DOC_LINT, DOC_LINT_SKIP, DOC_LINT_PATTERNS, VAULT_FRAMEWORK_PATH, BASH_ENV, ENV and an exported function from the caller do not reach the linter" {
    printf 'LINT:LONG1 long\n' >> support/guide.md
    git add support/guide.md
    printf ':\n' > "$WORK/bashenv"
    # A caller's exported function reaches every gate script, as BASH_ENV does (an accepted gap for
    # S6); what this driver guarantees is that neither reaches the linter.
    qg_probe_fn() { :; }
    export -f qg_probe_fn
    DOC_LINT=off DOC_LINT_SKIP=LONG1 DOC_LINT_PATTERNS=/dev/null VAULT_FRAMEWORK_PATH=/nowhere \
        BASH_ENV="$WORK/bashenv" ENV="$WORK/bashenv" measure
    unset -f qg_probe_fn
    [ "$(metric)" = 1 ]
    run cat "$WORK/fw/env.out"
    [[ "$output" != *DOC_LINT* ]] && [[ "$output" != *BASH_ENV* ]] && [[ "$output" != *BASH_FUNC* ]]
    [[ "$output" != *VAULT_FRAMEWORK_PATH* ]]
}

@test "guard_doc_lint unset, relative or not executable is status error naming the key" {
    for value in '' 'bin/doc-lint.sh' "$WORK/fw/lib/prose-match.sh" "$WORK/nowhere/doc-lint.sh"; do
        if [ -n "$value" ]; then printf 'guard_doc_lint: %s\n' "$value" > quality/config
        else printf 'other: x\n' > quality/config; fi
        commit_all "config $RANDOM"
        printf 'x %s\n' "$RANDOM" >> support/guide.md
        git add support/guide.md
        measure
        [ "$status" -eq 0 ]
        [ "$(result .status)" = error ]
        [[ "$(result .error)" == *guard_doc_lint* ]]
        [ "$(result .metric)" = null ]
    done
}

@test "a missing linter library in ../lib of the linter's folder is status error naming it" {
    for lib in sentence-count.sh prose-match.sh doc-lint-patterns.tsv; do
        mv "$WORK/fw/lib/$lib" "$WORK/fw/$lib.off"
        printf 'x\n' >> support/guide.md
        git add support/guide.md
        measure
        [ "$(result .status)" = error ]
        [[ "$(result .error)" == *"../lib/$lib"* ]]
        mv "$WORK/fw/$lib.off" "$WORK/fw/lib/$lib"
    done
}

@test "guard_doc_lint is read at the config revision, not from the working tree" {
    printf 'guard_doc_lint: /nowhere/doc-lint.sh\n' > quality/config
    printf 'LINT:LONG1 long\n' >> support/guide.md
    git add support/guide.md
    measure
    [ "$(result .status)" = measured ]
    [ "$(metric)" = 1 ]
}

@test "a measured tree that is the repo itself is status error and writes nothing" {
    printf 'LONG1\n' > plans/.doc-lint
    commit_all skipfile
    printf 'x\n' >> plans/p.md
    git add plans/p.md
    mkdir -p "$WORK/out"
    printf 'plans/p.md\0' > "$WORK/files"
    QG_OUT="$WORK/out" QG_TREE="$QG_REPO" QG_FILES="$WORK/files" QG_BASE=HEAD QG_BASES=HEAD \
        QG_TARGET=:index QG_CONFIG_REV=HEAD run "$DRIVER" run
    [ "$(result .status)" = error ]
    [ -f plans/.doc-lint ] && [ ! -e .doc-lint ] && [ ! -e VAULT.md ]
}

@test "no changed markdown, .doc-lint or VAULT.md is metric 0 and the linter never runs" {
    printf 'data\n' > support/data.txt
    git add support/data.txt
    measure
    [ "$(result .status)" = measured ]
    [ "$(metric)" = 0 ]
    [ ! -e "$WORK/fw/env.out" ]
}

@test "a linter exit above 1, or exit 1 with no parsed finding, is status error" {
    printf 'clean addition\n' >> support/guide.md
    git add support/guide.md
    printf '3' > "$WORK/fw/exit-code"
    measure
    [ "$(result .status)" = error ]
    [[ "$(result .error)" == *'exited 3'* ]]
    printf '1' > "$WORK/fw/exit-code"
    measure
    [ "$(result .status)" = error ]
    [[ "$(result .error)" == *'exited 1 with 0 parsed findings'* ]]
}

@test "a linter exit 0 with a finding, an exit of 126, 127 or 143, and a parent lint above 1 are status error with output kept" {
    printf 'clean addition\n' >> support/guide.md
    git add support/guide.md
    touch "$WORK/fw/print-on-zero"
    measure
    [ "$(result .status)" = error ]
    rm "$WORK/fw/print-on-zero"
    for code in 126 127 143; do
        printf '%s' "$code" > "$WORK/fw/exit-code"
        measure
        [ "$(result .status)" = error ]
        [[ "$(result .error)" == *"exited ${code}"* ]]
    done
}

@test "a plain rename of a file with an old line finding counts 0" {
    printf 'LINT:LONG1 old\n' >> support/guide.md
    commit_all old
    git mv support/guide.md support/kb.md
    measure
    [ "$(metric)" = 0 ]
}

@test "a .doc-lint or VAULT.md the commit deletes counts 0 and the config revision's copy applies" {
    printf 'LONG1\n' > plans/.doc-lint
    commit_all skipfile
    git rm -q plans/.doc-lint
    printf 'LINT:LONG1 long\n' >> plans/p.md
    git add plans/p.md
    measure
    [ "$(metric)" = 0 ]
}

@test "adding a type: to an existing file with none counts 1 as doc-lint.TYPE" {
    printf '# Untyped\n' > plans/u.md
    commit_all untyped
    printf -- '---\ntype: plan\n---\n# Untyped\n' > plans/u.md
    git add plans/u.md
    measure
    [ "$(rules)" = doc-lint.TYPE ]
}

@test "a new file with another type or none, and a frontmatter edit that keeps the type, count 0 as doc-lint.TYPE" {
    printf -- '---\ntype: guide\n---\nclean\n' > support/n.md
    printf 'no frontmatter\n' > support/m.md
    sed -i 's/^type: guide$/type: guide\ntitle: Guide/' support/guide.md
    git add support/n.md support/m.md support/guide.md
    measure
    [ "$(metric)" = 0 ]
}

@test "a changed path with a space, a leading - and depth 5 is linted as ./<path> and counted" {
    mkdir -p "plans/a b" plans/1/2/3/4
    printf 'LINT:LONG1 x\n' > "plans/a b/s p.md"
    printf 'LINT:LONG1 x\n' > plans/-dash.md
    printf 'LINT:LONG1 x\n' > plans/1/2/3/4/deep.md
    git add -- "plans/a b/s p.md" plans/-dash.md plans/1/2/3/4/deep.md
    measure
    [ "$(result .status)" = measured ]
    [ "$(metric)" = 3 ]
}

@test "a commit changing 300 markdown files measures every file" {
    for i in $(seq 1 300); do printf 'LINT:LONG1 x\n' > "plans/f$i.md"; done
    git add plans
    measure
    [ "$(result .status)" = measured ]
    [ "$(metric)" = 300 ]
}

@test "two runs on the same staged tree write a byte-identical result.json" {
    printf 'LINT:LONG1 long\n' >> support/guide.md
    printf 'LONG1\n' > support/.doc-lint
    git add support/guide.md support/.doc-lint
    measure
    cp "$WORK/out/result.json" "$WORK/first.json"
    measure
    cmp "$WORK/first.json" "$WORK/out/result.json"
}

@test "with the real framework doc-lint, an added 31-word sentence counts LONG1 and a 30-word one counts 0" {
    real=''
    for c in /code/../vault/bin/doc-lint.sh "${HOME}/workspace/vault/bin/doc-lint.sh"; do [ -x "$c" ] && real="$c" && break; done
    [ -n "$real" ] || skip 'the framework doc-lint is not mounted in this image'
    printf 'guard_doc_lint: %s\n' "$real" > quality/config
    commit_all real
    words() { local i s=''; for ((i = 1; i <= $1; i++)); do s="$s word$i"; done; printf '%s.\n' "${s# }"; }
    words 30 >> plans/p.md
    git add plans/p.md
    measure
    [ "$(metric)" = 0 ]
    words 31 >> plans/p.md
    git add plans/p.md
    measure
    [ "$(rules)" = doc-lint.LONG1 ]
}
