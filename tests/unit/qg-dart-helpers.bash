# Shared by the Dart driver bats files. Loaded with `load qg-dart-helpers` after guard-helpers;
# bats runs only *.bats, so this file is never run on its own.
#
# dart_setup builds, under $WORK:
#   $SDK   a fake Flutter SDK: bin/flutter and bin/cache/dart-sdk/bin/dart. Each call appends
#          "flutter <argv>" or "dart <argv>" to $CALLS. $SDK/bin is first on PATH.
#   $REPO  a git repo whose committed quality/config names $SDK as guard_flutter_root;
#          QG_REPO is the repo and QG_CONFIG_REV that commit.
#   $TREE  the measured tree (QG_TREE), a folder outside the repo.
#
# The fake dart, per call:
#   pub get           writes its sorted env to $PUB_ENV and its cwd to $PUB_CWD, prints
#                     $FAKE_PUB_OUT, exits $FAKE_PUB_RC
#   pub global list   prints $FAKE_GLOBAL (default "layerlens 3.1.0")
#   anything else     writes its sorted env to $TOOL_ENV and its argv, one per line, to $ARGV; copies
#                     each "<cwd path>=<source>" word of $FAKE_WRITE; prints $FAKE_OUT; exits $FAKE_RC

fake_sdk() {  # fake_sdk <root>
    mkdir -p "$1/bin/cache/dart-sdk/bin"
    cat > "$1/bin/cache/dart-sdk/bin/dart" <<'EOF'
#!/usr/bin/env bash
own_env="$(env | sort)"
if [ -z "${CALLS:-}" ]; then
    # qg_sandbox_run starts a tool from an empty environment: take the test's names from the
    # nearest ancestor process that has them. Works only unsandboxed, as dart_setup runs.
    p=$PPID
    while [ "${p:-0}" -gt 1 ]; do
        if tr '\0' '\n' < "/proc/$p/environ" 2>/dev/null | grep -q '^CALLS='; then
            while IFS= read -r -d '' kv; do
                case "$kv" in CALLS=*|ARGV=*|PUB_ENV=*|PUB_CWD=*|TOOL_ENV=*|FAKE_*) export "${kv?}" ;; esac
            done < "/proc/$p/environ"
            break
        fi
        p="$(awk '{ print $4 }' "/proc/$p/stat" 2>/dev/null)"
    done
fi
printf 'dart %s\n' "$*" >> "${CALLS:-/dev/null}"
if [ "${1:-} ${2:-}" = 'pub get' ]; then
    env | sort > "${PUB_ENV:-/dev/null}"; pwd > "${PUB_CWD:-/dev/null}"
    [ -z "${FAKE_PUB_OUT:-}" ] || printf '%s\n' "$FAKE_PUB_OUT"
    exit "${FAKE_PUB_RC:-0}"
fi
if [ "${1:-} ${2:-} ${3:-}" = 'pub global list' ]; then printf '%s\n' "${FAKE_GLOBAL-layerlens 3.1.0}"; exit 0; fi
printf "%s\n" "$own_env" > "${TOOL_ENV:-/dev/null}"
printf '%s\n' "$@" > "${ARGV:-/dev/null}"
for w in ${FAKE_WRITE:-}; do mkdir -p "$(dirname "${w%%=*}")"; cp "${w#*=}" "${w%%=*}"; done
[ -z "${FAKE_OUT:-}" ] || cat "$FAKE_OUT"
exit "${FAKE_RC:-0}"
EOF
    printf '%s\n' '#!/usr/bin/env bash' 'printf "flutter %s\n" "$*" >> "${CALLS:-/dev/null}"' > "$1/bin/flutter"
    chmod +x "$1/bin/flutter" "$1/bin/cache/dart-sdk/bin/dart"
}

dart_setup() {
    export LC_ALL=C
    WORK="$(mktemp -d)"
    unset QG_RUNNER QG_ARGS QG_RUN_DIR QG_BASES QG_BASE CLAUDECODE AI_AGENT PUB_CACHE XDG_CACHE_HOME FLUTTER_ROOT \
        FAKE_OUT FAKE_RC FAKE_WRITE FAKE_PUB_OUT FAKE_PUB_RC FAKE_GLOBAL
    SDK="$WORK/sdk" REPO="$WORK/repo" TREE="$WORK/tree"
    mkdir -p "$TREE" "$WORK/out"
    fake_sdk "$SDK"
    (
        new_repo "$REPO"
        mkdir -p quality
        printf 'guard_flutter_root: %s\n' "$SDK" > quality/config
        commit_all config
    )
    export QG_REPO="$REPO" QG_CONFIG_REV QG_TREE="$TREE" QG_OUT="$WORK/out" QG_CACHE="$WORK/cache" \
        QG_ROW=dart-row QG_FILES=/dev/null QG_TARGET=:index
    QG_CONFIG_REV="$(git -C "$REPO" rev-parse HEAD)"
    # Driver cases run unsandboxed so the fakes can record; qg-dart.bats and the sandbox cases of the
    # driver suites run the sandbox itself.
    export QG_SANDBOX=0
    export CALLS="$WORK/calls" ARGV="$WORK/argv" PUB_ENV="$WORK/pub.env" PUB_CWD="$WORK/pub.cwd" TOOL_ENV="$WORK/tool.env"
    export PATH="$SDK/bin:$PATH"
}

dart_teardown() {
    [ -n "${WORK:-}" ] && [ -d "$WORK" ] && rm -rf "$WORK"
    return 0
}

result() { jq -r "$1" "$QG_OUT/result.json"; }

# calls_of <ERE> -> how many recorded calls match, 0 when none ran.
calls_of() {
    [ -e "$CALLS" ] || { printf '0'; return 0; }
    grep -cE -- "$1" "$CALLS" || true
}

# files_list <path>... -> $WORK/files, the NUL-separated changed-path list; QG_FILES names it.
files_list() {
    printf '%s\0' "$@" > "$WORK/files"
    export QG_FILES="$WORK/files"
}
