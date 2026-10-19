#!/usr/bin/env bash
# commit-lint.sh <tree> <cache> — the lint-refuse-new and lint-warn-new commit rows. Staged paths
# arrive NUL-separated in the file $QG_FILES (the checkstyle driver), else on stdin. Writes <tree>/quality-reports/commit-lint-refuse.xml and
# commit-lint-warn.xml (checkstyle, paths relative to <tree>) from `dart analyze` (core lints) and the
# tool/givore_lints runner (many_lints and givore_* rules); gate.dart report splits them by tier.
#
# <tree>   the plugin's copy of the staged tree ({{tree}}); every file analysed is <tree>/<path>.
# <cache>  the plugin's cache dir ({{cache}}); holds the current givore-gate-<key> and its analyzer byte
#          store analysis-<key>/ — the store does not key on rule code, so a rule change starts fresh.
# The SDK is guard_flutter_root of quality/config at the config revision ($QG_CONFIG_REV, else HEAD);
# a flutter on PATH that is another file refuses the run. The caller's PUB_CACHE and XDG_CACHE_HOME
# are ignored, a tree holding pubspec_overrides.yaml is refused, and packages always resolve offline
# inside the tree.
# The row pipes a report through guard-added-lines.sh --checkstyle, which judges only added lines.
# Exit: 0 both reports written · 2 a step failed (named on stderr; no report left behind)
set -uo pipefail

if [ "$#" -ne 2 ] || [ ! -d "$1" ]; then
    echo "usage: commit-lint.sh <tree> <cache>  (staged paths NUL-separated on stdin)" >&2
    exit 2
fi
tree="$(cd "$1" && pwd -P)"
mkdir -p "$2" || { echo "commit-lint.sh: cannot create cache $2" >&2; exit 2; }
cache="$(cd "$2" && pwd -P)"
unset PUB_CACHE XDG_CACHE_HOME FLUTTER_ROOT
out="$tree/quality-reports"
refuse="$out/commit-lint-refuse.xml" warn="$out/commit-lint-warn.xml" memo="$out/commit-lint.key"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fail() {  # fail <step> <detail...> — removes every report so a failed run never leaves a stale one
    rm -f "$refuse" "$warn" "$memo"
    echo "commit-lint.sh: $1 failed${2:+: $2}" >&2
    exit 2
}
empty_reports() {
    local f
    for f in "$refuse" "$warn"; do
        printf '<?xml version="1.0" encoding="UTF-8"?>\n<checkstyle version="3.13.6">\n</checkstyle>\n' > "$f"
    done
}
hash_files() {  # hash_files <dir> <relative path...> -> one SHA-1 over each path and its content
    local dir="$1" p; shift
    for p in "$@"; do
        printf '%s\0' "$p"
        if [ -f "$dir/$p" ]; then sha1sum < "$dir/$p"; else echo missing; fi
    done | sha1sum | cut -d' ' -f1
}
mkdir -p "$out" || fail "step 1 (reports dir)" "$out"

# (1) Staged Dart sources under lib/, test/ and integration_test/; generated code never counts.
src=/dev/stdin
[ -z "${QG_FILES:-}" ] || src="$QG_FILES"
mapfile -d '' files < <(grep -zE '^(lib|test|integration_test)/.*\.dart$' "$src" \
    | grep -zvE '\.(g|freezed|mocks|config)\.dart$' | grep -zv '^lib/generated/')
if [ "${#files[@]}" -eq 0 ]; then
    rm -f "$memo"; empty_reports
    exit 0
fi

# (2) SDK and runner key: the Flutter-bundled Dart SDK, and a key over the runner source, its lock
# file and the SDK version.
flutter_root="$(git show "${QG_CONFIG_REV:-HEAD}:quality/config" 2>/dev/null \
    | sed -n 's/^guard_flutter_root:[[:space:]]*//p' | head -1 | sed 's/[[:space:]]*$//')"
[ -n "$flutter_root" ] || fail "step 2 (sdk)" "guard_flutter_root is not set in quality/config at ${QG_CONFIG_REV:-HEAD}"
[ -x "$flutter_root/bin/flutter" ] || fail "step 2 (sdk)" "guard_flutter_root $flutter_root has no bin/flutter"
if flutter_bin="$(command -v flutter)" && [ "$(readlink -f "$flutter_bin")" != "$(readlink -f "$flutter_root/bin/flutter")" ]; then
    fail "step 2 (sdk)" "flutter on PATH is $flutter_bin, not $flutter_root/bin/flutter from guard_flutter_root"
fi
[ ! -e "$tree/pubspec_overrides.yaml" ] || fail "step 2 (sdk)" "pubspec_overrides.yaml is in the tree; it would replace the lint packages"
sdk="$flutter_root/bin/cache/dart-sdk"
dart="$sdk/bin/dart"
[ -x "$dart" ] || fail "step 2 (sdk)" "no dart at $dart"
pkg="$tree/tool/givore_lints"
[ -f "$pkg/bin/gate.dart" ] || fail "step 2 (runner key)" "the tree has no tool/givore_lints/bin/gate.dart"
mapfile -d '' src < <(cd "$pkg" && find . \( -name .dart_tool -o -name build \) -prune -o -type f -print0 | sort -z)
runner_key="$( { hash_files "$pkg" "${src[@]}"; "$dart" --version 2>&1; } | sha1sum | cut -d' ' -f1)"

# (3) Memo: the second row of the same commit reuses the reports the first row wrote. Step 5 renames
# analysis_options.yaml to analysis_options.base.yaml, so the key reads whichever holds the original.
base_options=analysis_options.yaml
[ -f "$tree/analysis_options.base.yaml" ] && base_options=analysis_options.base.yaml
key="$( { hash_files "$tree" "${files[@]}" analysis_options.commit.yaml many_lints.yaml quality/rules.tsv pubspec.lock
          hash_files "$tree" "$base_options"; echo "$runner_key"; } | sha1sum | cut -d' ' -f1)"
if [ -f "$memo" ] && [ "$(cat "$memo")" = "$key" ] && [ -f "$refuse" ] && [ -f "$warn" ]; then
    exit 0
fi
rm -f "$refuse" "$warn" "$memo"

# (4) Packages: always resolve in the tree with the SDK's pub, offline, which leaves lib/generated as
# staged (`flutter pub get` regenerates l10n there). The live checkout's resolution is never copied:
# an edit there would choose the lint code.
# --enforce-lockfile: a pubspec.yaml dependency_overrides entry the lock does not record is refused,
# so a commit cannot point a lint package at code in the repo.
(cd "$tree" && FLUTTER_ROOT="$flutter_root" nice -n 15 "$dart" pub get --offline --enforce-lockfile) > "$work/pub" 2>&1 \
    || fail "step 4 (dart pub get --offline --enforce-lockfile)" "$(tail -n 5 "$work/pub") - run flutter pub get, then retry"

# (5) Options: the tree analyses with the commit catalog; the original becomes its include. A nested
# options file would apply its own rules to its directory, so every one below the source roots goes.
[ -f "$tree/analysis_options.commit.yaml" ] || fail "step 5 (options)" "the tree has no analysis_options.commit.yaml"
# analysis_options.base.yaml is this script's own rename; a committed one would replace the rules.
if [ "${QG_TARGET:-:index}" = ':index' ]; then tracked="$(git -C "${QG_REPO:-.}" ls-files -- analysis_options.base.yaml)"
else tracked="$(git -C "${QG_REPO:-.}" ls-tree --name-only "$QG_TARGET" -- analysis_options.base.yaml)"; fi
[ -z "$tracked" ] || fail "step 5 (options)" "analysis_options.base.yaml is committed; it is the name this script gives the original options"
if [ ! -f "$tree/analysis_options.base.yaml" ]; then
    mv "$tree/analysis_options.yaml" "$tree/analysis_options.base.yaml" || fail "step 5 (rename analysis_options.yaml)"
fi
cp "$tree/analysis_options.commit.yaml" "$tree/analysis_options.yaml" || fail "step 5 (copy analysis_options.commit.yaml)"
options="$tree/analysis_options.yaml"
roots=()
for d in lib test integration_test; do [ -d "$tree/$d" ] && roots+=("$tree/$d"); done
if [ "${#roots[@]}" -gt 0 ]; then
    while IFS= read -r -d '' nested; do
        rm -f "$nested" || fail "step 5 (remove nested options)" "$nested"
        echo "commit-lint.sh: removed ${nested#"$tree"/} from the tree; only the root options apply" >&2
    done < <(find "${roots[@]}" \( -name analysis_options.yaml -o -name many_lints.yaml \) \( -type f -o -type l \) -print0)
fi

# (6) Runner: an AOT binary per runner key, compiled beside its final name so the install is one
# rename; installing a new one removes every other runner and byte store in the cache.
gate="$cache/givore-gate-$runner_key"
# The checksum written beside the runner at compile time; a runner that no longer matches it (code
# a test run left in the cache) is compiled again.
if [ ! -x "$gate" ] || ! (cd "$cache" && sha256sum --status -c "givore-gate-$runner_key.sha256" 2>/dev/null); then
    partial="$cache/.givore-gate-$runner_key.$$"
    (cd "$pkg" && "$dart" pub get --offline --enforce-lockfile) > "$work/pub" 2>&1 \
        || fail "step 6 (dart pub get --offline in tool/givore_lints)" "$(tail -n 5 "$work/pub")"
    (cd "$pkg" && nice -n 15 "$dart" compile exe bin/gate.dart -o "$partial") > "$work/compile" 2>&1 \
        || { rm -f "$partial"; fail "step 6 (dart compile exe)" "$(tail -n 10 "$work/compile")"; }
    mv -f "$partial" "$gate" || { rm -f "$partial"; fail "step 6 (install runner)" "$gate"; }
    (cd "$cache" && sha256sum "givore-gate-$runner_key" > "givore-gate-$runner_key.sha256") \
        || fail "step 6 (record runner checksum)" "$gate"
    find "$cache" -mindepth 1 -maxdepth 1 \( -name 'givore-gate-*' -o -name '.givore-gate-*' -o -name 'analysis-*' \) \
        ! -name "givore-gate-$runner_key" ! -name "givore-gate-$runner_key.sha256" ! -name "analysis-$runner_key" -exec rm -rf {} + \
        || fail "step 6 (remove old runners)" "$cache"
fi

# (7) Both engines on the tree copies, never on the caller's working tree.
abs=()
for f in "${files[@]}"; do abs+=("$tree/$f"); done
cd "$tree" || fail "step 7 (cd tree)"
rc=0
nice -n 15 "$dart" analyze --no-plugins --format=machine "${abs[@]}" > "$work/core" 2> "$work/core.err" || rc=$?
[ "$rc" -le 3 ] || fail "step 7 (dart analyze exited $rc)" "$(tail -n 5 "$work/core.err")"
nice -n 15 "$gate" analyze --tree "$tree" --cache "$cache/analysis-$runner_key" --sdk "$sdk" --options "$options" "${abs[@]}" \
    > "$work/runner" 2> "$work/runner.err" \
    || fail "step 7 (givore-gate analyze)" "$(tail -n 5 "$work/runner.err")"
[ ! -s "$work/runner.err" ] || cat "$work/runner.err" >&2
mkdir -p "$work/out"
cat "$work/core" "$work/runner" \
    | "$gate" report --tree "$tree" --options "$options" --rules "$tree/quality/rules.tsv" --out "$work/out" \
        2> "$work/report.err" \
    || fail "step 7 (givore-gate report)" "$(tail -n 5 "$work/report.err")"
[ -f "$work/out/commit-lint-refuse.xml" ] && [ -f "$work/out/commit-lint-warn.xml" ] \
    || fail "step 7 (givore-gate report)" "it wrote no commit-lint-refuse.xml or commit-lint-warn.xml"
mv "$work/out/commit-lint-refuse.xml" "$refuse" && mv "$work/out/commit-lint-warn.xml" "$warn" \
    || fail "step 7 (install reports)"
printf '%s\n' "$key" > "$memo"
