#!/usr/bin/env bats
# drivers/copydetect.sh — metric = file pairs whose two similarities are at or over min-similarity
# with at least min-tokens tokens, from the venv python the committed requirements file names.
#
# The test image has no copydetect. The stub venv python at
# $HOME/.cache/<venv-root>/copydetect-<12 hex of sha256(requirements at QG_CONFIG_REV)>/bin/python
# records its flags, argv, cwd and XDG_CACHE_HOME, then runs the driver's own script with the system
# python3 and a fake `copydetect` module from $WORK/mod. The fake CopyDetector records its keyword
# arguments and added files to $WORK/seen.json and returns one clone per line of $WORK/clones
# (`<sim a> <sim b> <file a> <file b> <tokens>`); a $WORK/raise file makes run() raise.

load guard-helpers

DRIVER=/code/drivers/copydetect.sh
REQ=quality/requirements-copydetect.txt

setup() {
    export LC_ALL=C
    WORK="$(mktemp -d)"
    unset QG_RUNNER QG_ARGS QG_RUN_DIR QG_BASES CLAUDECODE AI_AGENT XDG_CACHE_HOME
    export HOME="$WORK/home"
    fake_module "$WORK/mod"
    new_repo "$WORK/repo"
    mkdir -p quality lib/generated lib/ui
    printf 'copydetect==0.5.0 --hash=sha256:aaaa\n' > "$REQ"
    printf 'class A {}\n' > lib/a.dart; printf 'class B {}\n' > lib/ui/b.dart
    printf 'g\n' > lib/a.g.dart; printf 'f\n' > lib/a.freezed.dart; printf 'm\n' > lib/a.mocks.dart
    printf 'c\n' > lib/app.config.dart; printf 'x\n' > lib/generated/l10n.dart; printf 'n\n' > lib/notes.txt
    commit_all init
    mkdir -p "$WORK/out"
    export QG_REPO="$WORK/repo" QG_TREE="$WORK/repo" QG_TARGET=:index QG_CONFIG_REV="$(git rev-parse HEAD)"
    export QG_OUT="$WORK/out" QG_CACHE="$WORK/cache" QG_ROW=copy-row QG_FILES=/dev/null
    VENV="$HOME/.cache/qg-tools/copydetect-$(req_hash)"
    stub_python "$VENV/bin/python"
    : > "$WORK/clones"
}

teardown() {
    [ -n "${WORK:-}" ] && [ -d "$WORK" ] && rm -rf "$WORK"
    return 0
}

req_hash() { git -C "$WORK/repo" show "${QG_CONFIG_REV:-HEAD}:${REQ}" | sha256sum | cut -c1-12; }

fake_module() {
    mkdir -p "$1"
    cat > "$1/copydetect.py" <<'EOF'
import json, os
W = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
class CopyDetector:
    def __init__(self, **kw):
        self.kw = kw
        self.files = []
    def add_file(self, f):
        self.files.append(f)
    def run(self):
        if os.path.exists(os.path.join(W, "raise")):
            raise RuntimeError("boom")
    def get_copied_code_list(self):
        with open(os.path.join(W, "seen.json"), "w") as s:
            json.dump({"kw": self.kw, "files": self.files}, s)
        out = []
        with open(os.path.join(W, "clones")) as c:
            for line in c:
                p = line.split()
                if p:
                    out.append((float(p[0]), float(p[1]), p[2], p[3], "", "", int(p[4])))
        return out
EOF
}

stub_python() {
    mkdir -p "$(dirname "$1")"
    { printf '#!/usr/bin/env bash\nW=%q\n' "$WORK"; cat <<'EOF'
printf '%s %s\n' "$1" "$2" > "$W/py.flags"
pwd > "$W/py.pwd"
printf '%s\n' "${XDG_CACHE_HOME-unset}" > "$W/py.xdg"
script="$3"; shift 3
printf '%s\n' "$*" > "$W/py.args"
exec /usr/bin/python3 -I -c 'import sys; sys.path.insert(0, sys.argv.pop(1)); exec(sys.argv.pop(1))' "$W/mod" "$script" "$@"
EOF
    } > "$1"
    chmod +x "$1"
}

result() { jq -r "$1" "$QG_OUT/result.json"; }
measure() { QG_ARGS="requirements=${REQ}${1:+ $1}" "$DRIVER" run > /dev/null 2>&1; }

@test "describe is JSON naming copydetect with needs_tree true; explain names the keys" {
    run "$DRIVER" describe
    [ "$status" -eq 0 ]
    [ "$(jq -r '.name' <<<"$output")" = copydetect ]
    [ "$(jq -r '.needs_tree' <<<"$output")" = true ]
    run "$DRIVER" explain
    [[ "$output" == *'requirements (required)'* ]]
}

@test "a missing requirements= is status error and python is never called" {
    run "$DRIVER" run
    [ "$status" -eq 0 ]
    [ "$(result .status)" = error ]
    [[ "$(result .error)" == *'requirements='* ]]
    [ ! -e "$WORK/py.flags" ]
}

@test "a requirements file present in the tree but not committed at the config revision is status error" {
    printf 'x\n' > quality/other.txt
    QG_ARGS='requirements=quality/other.txt' "$DRIVER" run > /dev/null 2>&1
    [ "$(result .status)" = error ]
    [ "$(result .metric)" = null ]
    [[ "$(result .error)" == *'not committed at the config revision'* ]]
    [ ! -e "$WORK/py.flags" ]
}

@test "no venv for the committed requirements hash is status error naming the python path" {
    rm -rf "$VENV"
    measure
    [ "$(result .status)" = error ]
    [ "$(result .metric)" = null ]
    [[ "$(result .error)" == *"copydetect-$(req_hash)/bin/python"* ]]
}

@test "the venv follows the requirements at QG_CONFIG_REV: a tree edit or a later commit picks no other venv" {
    printf 'copydetect==9.9.9\n' > "$REQ"
    measure
    [ "$(result .status)" = measured ]
    [ -e "$WORK/py.flags" ]
    commit_all 'bump requirements'
    rm -f "$WORK/py.flags"
    measure
    [ "$(result .status)" = measured ]
    [ -e "$WORK/py.flags" ]
    QG_CONFIG_REV="$(git rev-parse HEAD)" measure
    [ "$(result .status)" = error ]
    [[ "$(result .error)" == *'no copydetect venv'* ]]
}

@test "venv-root=../x, a/b and .. are status error; venv-root=<plain name> picks that folder" {
    local r
    for r in ../x a/b .. 'x..y'; do
        rm -f "$QG_OUT/result.json"
        measure "venv-root=$r"
        [ "$(result .status)" = error ] || { echo "venv-root=$r accepted"; return 1; }
        [[ "$(result .error)" == *'one plain folder name'* ]]
    done
    [ ! -e "$WORK/py.flags" ]
    stub_python "$HOME/.cache/mobile-tools/copydetect-$(req_hash)/bin/python"
    measure venv-root=mobile-tools
    [ "$(result .status)" = measured ]
}

@test "python runs as -I -c from the tree with XDG_CACHE_HOME unset and the default thresholds" {
    export XDG_CACHE_HOME="$WORK/xdg"
    measure
    [ "$(cat "$WORK/py.flags")" = '-I -c' ]
    [ "$(cat "$WORK/py.pwd")" = "$QG_TREE" ]
    [ "$(cat "$WORK/py.xdg")" = unset ]
    [ "$(cat "$WORK/py.args")" = 'dart 0.8 600 25 25' ]
    [ "$(jq -c '.kw' "$WORK/seen.json")" = '{"extensions":["dart"],"noise_t":25,"guarantee_t":25,"display_t":0.8,"silent":true,"autoopen":false}' ]
}

@test "the default file list is the .dart files under lib, sorted, without the generated forms" {
    measure
    [ "$(jq -r '.files | join(",")' "$WORK/seen.json")" = 'lib/a.dart,lib/ui/b.dart' ]
}

@test "paths=, ext= and exclude= replace the defaults" {
    measure 'paths=lib/generated,lib/ui ext=dart exclude=^lib/ui/'
    [ "$(jq -r '.files | join(",")' "$WORK/seen.json")" = 'lib/generated/l10n.dart' ]
    measure 'ext=txt'
    [ "$(jq -r '.files | join(",")' "$WORK/seen.json")" = 'lib/notes.txt' ]
}

@test "zero clones measures 0 pairs with no finding" {
    measure
    [ "$(result .status)" = measured ]
    [ "$(result .metric)" = 0 ]
    [ "$(result .unit)" = pairs ]
    [ "$(result '.findings | length')" = 0 ]
}

@test "a pair is counted only when both similarities reach min-similarity and the tokens reach min-tokens" {
    cat > "$WORK/clones" <<'EOF'
0.80 0.80 lib/a.dart lib/ui/b.dart 600
0.92 0.88 lib/c.dart lib/d.dart 700
0.79 0.95 lib/e.dart lib/f.dart 900
0.95 0.79 lib/g.dart lib/h.dart 900
0.90 0.90 lib/i.dart lib/j.dart 599
EOF
    measure
    [ "$(result .status)" = measured ]
    [ "$(result .metric)" = 2 ]
    [ "$(result '[.findings[].file] | join(",")')" = 'lib/a.dart,lib/c.dart' ]
    [ "$(result '.findings[1].message')" = 'same code as lib/d.dart (similarity 0.92/0.88, 700 tokens)' ]
    [ "$(result '.findings[1].ruleId')" = copydetect.clone ]
}

@test "min-similarity=, min-tokens=, noise= and guarantee= reach the detector" {
    printf '0.85 0.85 lib/a.dart lib/ui/b.dart 100\n0.95 0.95 lib/c.dart lib/d.dart 99\n' > "$WORK/clones"
    measure 'min-similarity=0.9 min-tokens=50 noise=30 guarantee=40'
    [ "$(result .metric)" = 1 ]
    [ "$(result '.findings[0].file')" = lib/c.dart ]
    [ "$(jq -c '[.kw.noise_t, .kw.guarantee_t, .kw.display_t]' "$WORK/seen.json")" = '[30,40,0.9]' ]
}

@test "a python that fails is status error with metric null" {
    : > "$WORK/raise"
    measure
    [ "$(result .status)" = error ]
    [ "$(result .metric)" = null ]
    [[ "$(result .error)" == *'copydetect exited 1'* ]]
}

@test "no source file left to compare is status error, never a measured 0" {
    measure 'ext=kt'
    [ "$(result .status)" = error ]
    [ "$(result .metric)" = null ]
    [[ "$(result .error)" == *'copydetect exited 2'* ]]
}

@test "files reach the detector in sorted order whatever order the folder lists them in" {
    mkdir -p lib/z
    printf 'z\n' > lib/z/z.dart; printf 'y\n' > lib/y.dart; printf 'm\n' > lib/m.dart
    measure
    [ "$(jq -r '.files | join(",")' "$WORK/seen.json")" = 'lib/a.dart,lib/m.dart,lib/ui/b.dart,lib/y.dart,lib/z/z.dart' ]
}
