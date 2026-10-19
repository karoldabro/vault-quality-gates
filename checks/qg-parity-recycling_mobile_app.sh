#!/usr/bin/env bash
# S4 SC-4 (contract C-4) — row parity of recycling_mobile_app's v2 gate rows with its v1 rows.
#
#   checks/qg-parity-recycling_mobile_app.sh [<recycling_mobile_app checkout>]
#       default ~/workspace/recycling_mobile_app; QG_PARITY_BRANCH (default release/1.17.0) names the
#       branch whose head is measured; QG_PARITY_TIMEOUT (default 3600) caps each engine step in seconds
#
# Builds two `git clone --shared` scratch clones of that branch head with no hooks: `old` keeps the
# committed v1 quality/, `new` carries migrations/recycling_mobile_app/ (checks.tsv and config in
# quality/, commit-lint.sh in quality/bin/), committed in the clone. In each clone
# refs/remotes/origin/HEAD names the fixture commit, so every diff row measures the seeds alone. The
# live checkout is only cloned from and read with `git status`; this script fails with exit 2 when its
# `git status --porcelain` changed during the run.
#
# Each clone is measured in three states, each with that engine's commit gate (the staged seeds),
# release gate (`guard.sh release`, the committed seeds) and `baseline --only mutation`:
#
#   clean   a neutral staged file, test/qg-parity-clean.txt
#   seed1   one violation per v1 row (seed_<id> below), and one hit per generated-file form for every
#           row whose v2 args carry exclude=, ignore= or cloc filters (gen_<id> below)
#   seed2   the same with two violations per row and the same generated hits
#
# Metamorphic relations: for a count row, seed2 - clean = 2 x (seed1 - clean). The generated hits are
# the same in seed1 and seed2, so a filtered row that counted them breaks that relation; ratio and
# exit-code rows (NONLINEAR) are compared side to side instead. The suite rows run the real Flutter
# suite once per state, with one seeded failing test file per violation. mutation_test never runs:
# the old side's `dart` on PATH and the new side's guard_flutter_root SDK print the state's recorded
# summary for `dart run mutation_test` and pass every other call to the real SDK.
#
# The new engine runs under `unshare -rn` (no network) when the kernel allows it, else with a warning.
# The old engine is QG_PARITY_OLD_ENGINE (default ~/workspace/vault-quality-gates), the new one this repo.
#
# Writes migrations/recycling_mobile_app/parity.tsv, columns: id, new-id, kind, verdict, old-clean,
# old-seed1, old-seed2, new-seed1, new-seed2; each value is <value>/<status>. Verdicts:
#   SAME     a kept id reads the same value and status on both sides in both seeded states
#   DIFF     a kept id differs, or a renamed row of the same unit reads another clean value
#   NEW      a renamed id, or a v2 row with no v1 id (id -, kind new), measured and moved by its seed
#   VACUOUS  a value is missing, a seed did not move the old (or new-only) value, or a count row
#            broke seed2 - clean = 2 x (seed1 - clean)
# v1 rows of kind absent, and v1 rows the v2 file drops (kind absent, no new id), are skipped.
# Exit 0 every kept id is SAME · 1 a kept id or a renamed clean value is DIFF · 2 a row is VACUOUS, a
# step timed out, the clones could not be built, or the live checkout changed.
set -uo pipefail
export LC_ALL=C
# No tool this script starts may read the caller's stdin: gate.sh feeds its remaining criteria there.
exec < /dev/null

NEW_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OLD_ROOT="${QG_PARITY_OLD_ENGINE:-$HOME/workspace/vault-quality-gates}"
LIVE="$(cd "${1:-$HOME/workspace/recycling_mobile_app}" && pwd)" || { echo "parity: no checkout ${1:-}"; exit 2; }
BRANCH="${QG_PARITY_BRANCH:-release/1.17.0}"
MIG="${NEW_ROOT}/migrations/recycling_mobile_app"
REF=refs/heads/release/qg-parity
STEP_TIMEOUT="${QG_PARITY_TIMEOUT:-3600}"
# v1 id = v2 id of every renamed row, and how its clean values compare: zero = both 0 or both not 0
# (an exit code against a count), equal = the same number.
RENAMED='format=format-files tests-failing=tests-failed comment-density=comment-ratio gate-config-touched=protected-paths-touched'
CLEAN_RULE='format=zero tests-failing=zero comment-density=equal gate-config-touched=equal'
# Ratio, percentage and exit-code rows, by v1 and by v2 id: no seed2 = 2 x seed1 relation holds.
NONLINEAR=' format tests-failing comment-density comment-ratio coverage duplication architecture-nccd '
# Rows whose seeds run in the push phase only: the failing tests import the generated hits.
ROWS_B=' tests-failing coverage '

WORK="$(mktemp -d "${TMPDIR:-/tmp}/qg-parity-mobile.XXXXXX")" || exit 2
LOG="${WORK}/parity.log"
trap 'echo "parity: work dir ${WORK} (log ${LOG})" >&2' EXIT
say() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$LOG" >&2; }
die() { say "CANNOT RUN: $*"; exit 2; }
put() { mkdir -p "$(dirname "$1")" && cat > "$1"; }

for t in git jq awk timeout pnpm; do command -v "$t" > /dev/null || die "${t} is not on PATH"; done
[ -f "$OLD_ROOT/bin/guard.sh" ] || die "no old engine at ${OLD_ROOT}"
FLUTTER_SDK="$(sed -n 's/^guard_flutter_root:[[:space:]]*//p' "$MIG/config" | head -1 | sed 's/[[:space:]]*$//')"
[ -x "$FLUTTER_SDK/bin/flutter" ] && [ -x "$FLUTTER_SDK/bin/cache/dart-sdk/bin/dart" ] \
    || die "guard_flutter_root ${FLUTTER_SDK:-(unset)} in ${MIG}/config is not a Flutter SDK"
LIVE_STATUS="$(git -C "$LIVE" --no-optional-locks status --porcelain)" || die "cannot read git status of ${LIVE}"

NS=()
if unshare -rn true > /dev/null 2>&1; then NS=(unshare -rn)
else say "WARNING: unshare -rn is not available; the new side runs with network access"; fi

# --- the rows ----------------------------------------------------------------------------------

v1_rows() { git -C "$LIVE" show "${BASE}:quality/checks.tsv" | awk -F'\t' 'NR > 1 && $0 !~ /^#/ && NF > 1'; }
v2_cell() { awk -F'\t' -v id="$1" -v c="$2" 'NR > 1 && $0 !~ /^#/ && $1 == id { print $c; exit }' "$MIG/checks.tsv"; }
renamed_to() { local r; for r in $RENAMED; do [ "${r%%=*}" = "$1" ] && { printf '%s' "${r#*=}"; return; }; done; printf '%s' "$1"; }
renamed_from() { local r; for r in $RENAMED; do [ "${r#*=}" = "$1" ] && { printf '%s' "${r%%=*}"; return; }; done; printf '%s' "$1"; }

BASE="$(git -C "$LIVE" rev-parse -q --verify "refs/heads/${BRANCH}^{commit}")" || die "${LIVE} has no branch ${BRANCH}"
# V1_IDS: the v1 rows measured. A v1 row of kind absent, or one the v2 file marks absent without a new
# id (coverage-age-days: every push measures coverage fresh), has nothing to compare.
V1_IDS='' SKIPPED=''
while IFS=$'\t' read -r id _ kind _; do
    [ "$kind" = absent ] && continue
    if [ "$(renamed_to "$id")" = "$id" ] && [ "$(v2_cell "$id" 3)" = absent ]; then SKIPPED+="$id "; continue; fi
    V1_IDS+="$id "
done < <(v1_rows)
[ -n "$V1_IDS" ] || die "${BRANCH} has no v1 quality/checks.tsv rows"
[ -z "$SKIPPED" ] || say "skipped, absent in v2 with no new id: ${SKIPPED% }"
# GEN_IDS: v1 ids whose v2 row filters generated files.
GEN_IDS="$(awk -F'\t' 'NR > 1 && $0 !~ /^#/ && $3 != "absent" && ($5 ~ /(^| )(exclude|ignore)=/ || $4 == "cloc") { print $1 }' "$MIG/checks.tsv" \
    | while read -r nid; do renamed_from "$nid"; echo; done | tr '\n' ' ')"

# --- the seeds ---------------------------------------------------------------------------------
# Each template prints one Dart file; $1 is the tag spliced into every identifier (a violation's
# number, or Gen<Form> for a generated hit), never into a numeric literal. Every per-violation file
# is the same text apart from the tag, so each row's count grows by the same amount per violation;
# identifiers carry the tag on every few tokens, so no jscpd clone spans two violations, and every
# file but the semantic-clones pair stays under copydetect's 600-token pair floor.

t_format() { printf 'int  qgParityFormat%s() => 0;\n' "$1"; }
t_analyze() { printf "void qgParityAnalyze%s() {\n  print('qg parity');\n}\n" "$1"; }
t_complexity() {  # 21 if blocks: cyclomatic complexity 22, 66 source lines
    local k; printf 'int qgParityComplex%s(int qgC%s) {\n' "$1" "$1"
    for k in $(seq 1 21); do printf '  if (qgC%s == %d) {\n    return %d;\n  }\n' "$1" "$k" "$k"; done
    printf '  return 0;\n}\n'
}
t_dup() {  # 13 lines, about 70 tokens: one jscpd clone between the a and b copy
    cat <<EOF
int qgParityDup$1(List<int> qgD$1) {
  var qgS$1 = 0;
  for (final qgV$1 in qgD$1) {
    if (qgV$1 > 10) {
      qgS$1 += qgV$1 * 2;
    } else if (qgV$1 > 5) {
      qgS$1 += qgV$1 * 3;
    } else {
      qgS$1 -= qgV$1;
    }
  }
  return qgS$1;
}
EOF
}
t_comment_density() { local k; for k in $(seq 1 200); do printf '/// qg parity doc line %d\n' "$k"; done; printf 'int qgParityDocumented%s() => 0;\n' "$1"; }
t_coverage() {  # 24 instrumented lines, 3 of them run by the failing test
    local k; printf 'int qgParityCoverage%s(int v) {\n  if (v > 0) {\n    return v;\n  }\n  var qgU%s = v;\n' "$1" "$1"
    for k in $(seq 1 20); do printf '  qgU%s = qgU%s + %d;\n' "$1" "$1" "$((k + 2))"; done
    printf '  return qgU%s;\n}\n' "$1"
}
t_gen_coverage() { printf 'int qgParityCoverage%s(int v) {\n  if (v > 1000) {\n    return v - 1000;\n  }\n  return v;\n}\n' "$1"; }
t_fail_test() {
    cat <<EOF
import 'package:flutter_test/flutter_test.dart';
import 'package:givore/generated/qg_parity_coverage.dart';
import 'package:givore/qg_parity/coverage_$1.dart';
import 'package:givore/qg_parity/qg_parity_gen_coverage.config.dart';
import 'package:givore/qg_parity/qg_parity_gen_coverage.freezed.dart';
import 'package:givore/qg_parity/qg_parity_gen_coverage.g.dart';
import 'package:givore/qg_parity/qg_parity_gen_coverage.gr.dart';
import 'package:givore/qg_parity/qg_parity_gen_coverage.mocks.dart';

void main() {
  test('qg parity seeded failure $1', () {
    final generated = qgParityCoverageGenDir(1) + qgParityCoverageGenConfig(1) + qgParityCoverageGenFreezed(1);
    final suffixed = qgParityCoverageGenG(1) + qgParityCoverageGenGr(1) + qgParityCoverageGenMocks(1);
    expect(generated + suffixed, 6);
    expect(qgParityCoverage$1(1), -1);
  });
}
EOF
}
t_material() { printf "import 'package:flutter/material.dart';\n\nconst qgParityMaterial%s = 0;\n" "$1"; }
t_reuse() { printf '%s\n\nconst qgParityReuse%s = 0;\n' "$2" "$1"; }  # t_reuse <tag> <import line>
t_color() { printf "import 'package:flutter/painting.dart';\n\nconst qgParityColor%s = Color(0xFF000000);\n" "$1"; }
t_god() { printf 'const qgParityGod%s = 0;\n' "$1"; printf '\n%.0s' $(seq 1 405); }  # 406 lines, one token line
t_share() { printf "class Share {\n  static void share(String text) {}\n}\n\nvoid qgParityShare%s() {\n  Share.share('qg parity');\n}\n" "$1"; }
t_unawaited() { printf 'Future<void> qgParityLater%s() async {}\n\nFuture<void> qgParityCaller%s() async {\n  qgParityLater%s();\n}\n' "$1" "$1" "$1"; }
t_notifier() {
    cat <<EOF
import 'package:flutter/foundation.dart';

class QgParityNotifier$1 extends ChangeNotifier {
  Future<void> load() async {
    await Future<void>.delayed(Duration.zero);
    notifyListeners();
  }
}
EOF
}
t_compact() {
    cat <<EOF
import 'package:flutter/material.dart';

Widget qgParityCompact$1() {
  return IconButton(
    onPressed: null,
    visualDensity: VisualDensity.compact,
    icon: const Icon(Icons.add),
  );
}
EOF
}
t_singleton() { printf 'class QgParitySingleton%s {\n  QgParitySingleton%s._();\n\n  static final instance = QgParitySingleton%s._();\n}\n' "$1" "$1" "$1"; }
t_spacing() { printf "import 'package:flutter/widgets.dart';\n\nconst qgParitySpacing%s = SizedBox(height: 8);\n" "$1"; }
t_expandable() { printf "const qgParityExpandable%s = 'ExpandablePageView';\n" "$1"; }
t_typeerror() {
    cat <<EOF
import 'dart:convert';

Object? qgParityDecode$1(String s) {
  try {
    return jsonDecode(s);
  } on FormatException {
    return null;
  }
}
EOF
}
t_elevated() {
    cat <<EOF
import 'package:flutter/material.dart';

Widget qgParityElevated$1() {
  return ElevatedButton(
    onPressed: null,
    style: ElevatedButton.styleFrom(),
    child: const SizedBox(),
  );
}
EOF
}
t_copywith() {
    cat <<EOF
class QgParityCopy$1 {
  const QgParityCopy$1({this.name});

  final String? name;

  QgParityCopy$1 copyWith({String? name}) => QgParityCopy$1(name: name);

  QgParityCopy$1 merge(QgParityCopy$1 other) {
    return other.copyWith(
      name: other.name,
    );
  }
}
EOF
}
t_blocks() { printf '// qg parity block line one\n// qg parity block line two\n// qg parity block line three\nconst qgParityBlocks%s = 0;\n' "$1"; }
t_strings() { printf "import 'package:flutter/widgets.dart';\n\nconst qgParityText%s = Text('Qg parity');\n" "$1"; }
t_detail_sheet() {
    cat <<EOF
class DetailBottomSheet {
  const DetailBottomSheet({this.isLoading = false});

  final bool isLoading;
}

DetailBottomSheet qgParityDetailSheet$1(bool busy) {
  return DetailBottomSheet(
    isLoading: busy,
  );
}
EOF
}
t_polymorphic() { printf "// qg parity: column: 'owner_type'\nconst qgParityPolymorphic%s = 0;\n" "$1"; }
t_lakos() { printf 'const qgParityLakos%s = 0;\n' "$1"; }
t_nest() {  # maximum nesting level 7
    cat <<EOF
int qgParityNest$1(int qgN$1) {
  if (qgN$1 > 1) {
    if (qgN$1 > 2) {
      if (qgN$1 > 3) {
        if (qgN$1 > 4) {
          if (qgN$1 > 5) {
            if (qgN$1 > 6) {
              return qgN$1;
            }
          }
        }
      }
    }
  }
  return 0;
}
EOF
}
t_params() { printf 'int qgParityParams%s(int a, int b, int c, int d, int e) => a + b + c + d + e;\n' "$1"; }
t_long() {  # 54 source lines, about 330 tokens
    local k; printf 'int qgParityLong%s(int v) {\n  var qgL%s = v;\n' "$1" "$1"
    for k in $(seq 1 52); do printf '  qgL%s = qgL%s + %d;\n' "$1" "$1" "$((k + 2))"; done
    printf '  return qgL%s;\n}\n' "$1"
}
t_large() { local k; printf 'class QgParityLarge%s {\n' "$1"; for k in $(seq 1 11); do printf '  int qgM%sx%d() => %d;\n' "$1" "$k" "$k"; done; printf '}\n'; }
t_clone() {  # t_clone <tag> <a|b> <op1> <op2>: 10 functions of 12 statements, about 900 tokens
    local f s up; up="$(printf '%s' "$2" | tr '[:lower:]' '[:upper:]')"
    for f in $(seq 1 10); do
        printf 'int qgParityClone%s%s%d(int v) {\n  var qg%s%s = v;\n' "$1" "$2" "$f" "$up" "$1"
        for s in $(seq 1 12); do printf '  qg%s%s = qg%s%s %s %d %s %d;\n' "$up" "$1" "$up" "$1" "$3" "$((f * 100 + s + 2))" "$4" "$((s + 3))"; done
        printf '  return qg%s%s;\n}\n\n' "$up" "$1"
    done
}

# gen_forms <clone> <dir> <base> <forms> <template> [<extra template arg>] — one generated hit per form:
# g freezed mocks config gr -> <dir>/qg_parity_gen_<base>.<form>.dart, dir -> lib/generated/qg_parity_<base>.dart.
gen_forms() {
    local d="$1" dir="$2" base="$3" forms="$4" tpl="$5" extra="${6:-}" f tag
    for f in $forms; do
        tag="Gen$(printf '%s' "${f:0:1}" | tr '[:lower:]' '[:upper:]')${f:1}"
        if [ "$f" = dir ]; then "$tpl" "$tag" "$extra" | put "$d/lib/generated/qg_parity_${base}.dart"
        else "$tpl" "$tag" "$extra" | put "$d/$dir/qg_parity_gen_${base}.${f}.dart"; fi
    done
}
ALL_FORMS='g freezed mocks config dir'

# domain_import <clone> <ERE> [<ERE the line must not match>] -> "<dir><TAB><line>": the first
# lib/domain import line matching the ERE, with the clone-relative folder of its file, so a seed
# beside it adds no new folder edge for layerlens. Files this script wrote (qg_parity_*) never count.
domain_import() {
    local f line skip="${3:-^$}"
    while IFS= read -r f; do
        line="$(grep -E "$2" "$1/$f" | grep -vE "$skip" | head -1)"
        [ -z "$line" ] || { printf '%s\t%s' "$(dirname "$f")" "$line"; return 0; }
    done < <(cd "$1" && grep -rlE "$2" lib/domain --include='*.dart' | grep -v '/qg_parity_' | sort)
    return 1
}
seed_reuse() {  # seed_reuse <clone> <i> <name> <ERE>
    local found
    found="$(domain_import "$1" "$4")" || die "no lib/domain import line matches ${4}; the ${3} seed needs one"
    t_reuse "$2" "${found#*$'\t'}" | put "$1/${found%%$'\t'*}/qg_parity_${3}_${2}.dart"
}
# arb_add <clone> <key> <value for en> <value for es> <value for pt> <value elsewhere> — the key goes
# into every locale, so test/l10n/arb_key_parity_test.dart keeps passing.
arb_add() {
    local d="$1" key="$2" f v
    for f in "$d"/lib/l10n/app_*.arb; do
        case "${f##*/}" in app_en.arb) v="$3" ;; app_es.arb) v="$4" ;; app_pt.arb) v="$5" ;; *) v="$6" ;; esac
        jq --indent 2 --arg k "$key" --arg v "$v" '. + {($k): $v}' "$f" > "$f.qg" && mv "$f.qg" "$f" || die "cannot add ${key} to ${f}"
    done
}
append_line() {  # append_line <file> <line> — after a final newline
    [ -s "$1" ] || die "$1 is missing or empty"
    [ -z "$(tail -c1 "$1")" ] || printf '\n' >> "$1"
    printf '%s\n' "$2" >> "$1"
}

# One seed_<id> per v1 row: seed_<id> <clone> <i> writes violation i. The comment gives what one
# violation adds to that row.
seed_format() { t_format "$2" | put "$1/lib/qg_parity/format_$2.dart"; }   # +1 changed unformatted file; every seed .dart counts too
seed_analyze_issues() { t_analyze "$2" | put "$1/lib/qg_parity/analyze_$2.dart"; }   # +1 avoid_print
seed_complexity() { t_complexity "$2" | put "$1/lib/qg_parity/complexity_$2.dart"; }   # +1 function over cyclomatic 20
seed_architecture_cycles() {   # +1 folder cycle (a <-> b) in its own lib/ folder
    printf "import '../b/b.dart';\n\nint qgParityCycleA%s(int v) => v > 0 ? qgParityCycleB%s(v - 1) : 0;\n" "$2" "$2" | put "$1/lib/qg_parity_cycle_$2/a/a.dart"
    printf "import '../a/a.dart';\n\nint qgParityCycleB%s(int v) => v > 0 ? qgParityCycleA%s(v - 1) : 1;\n" "$2" "$2" | put "$1/lib/qg_parity_cycle_$2/b/b.dart"
}
seed_duplication() { t_dup "$2" | put "$1/lib/qg_parity/dup_$2_a.dart"; t_dup "$2" | put "$1/lib/qg_parity/dup_$2_b.dart"; }   # +1 jscpd clone of 13 lines
seed_duplication_clones() { :; }   # the duplication seed's clone pair: +1 clone
seed_comment_density() { t_comment_density "$2" | put "$1/lib/qg_parity/comment_density_$2.dart"; }   # +200 comment lines, +1 code line
seed_tests_failing() { t_fail_test "$2" | put "$1/test/qg_parity/qg_parity_fail_$2_test.dart"; }   # +1 failing test (push phase)
seed_coverage() { t_coverage "$2" | put "$1/lib/qg_parity/coverage_$2.dart"; }   # +24 instrumented lines, 3 hit (push phase)
seed_mutation() { :; }   # +1 undetected mutation of 100: the recorded summary of the state
seed_domain_material_imports() { t_material "$2" | put "$1/lib/domain/qg_parity_material_$2.dart"; }   # +1 file
seed_domain_api_model_imports() { seed_reuse "$1" "$2" api_model "^import '.*api_model"; }   # +1 file
seed_raw_color_literals() { t_color "$2" | put "$1/lib/qg_parity/color_$2.dart"; }   # +1 file
seed_god_files() { t_god "$2" | put "$1/lib/qg_parity/god_$2.dart"; }   # +1 file over 400 lines
seed_share_position_origin() { t_share "$2" | put "$1/lib/qg_parity/share_$2.dart"; }   # +1 call
seed_unawaited_futures() { t_unawaited "$2" | put "$1/lib/qg_parity/unawaited_$2.dart"; }   # +1 unawaited_futures
seed_domain_ui_imports() { seed_reuse "$1" "$2" ui "^import '(package:givore/ui/|(\.\./)+ui/)"; }   # +1 file
seed_cdn_host_pinned_classifier() {   # +2 lines: one per entry point
    append_line "$1/lib/main_production.dart" "// qg parity $2: contains('cdn$2.givore.com/')"
    append_line "$1/lib/main_development.dart" "// qg parity $2: contains('cdn$2.givore.com/')"
}
seed_notifier_unguarded_notify() { t_notifier "$2" | put "$1/lib/qg_parity/notifier_$2.dart"; }   # +1 file
seed_compact_density_iconbutton() { t_compact "$2" | put "$1/lib/ui/qg_parity/compact_$2.dart"; }   # +1 line
seed_static_singletons() { t_singleton "$2" | put "$1/lib/qg_parity/singleton_$2.dart"; }   # +1 file
seed_magic_spacing_literals() { t_spacing "$2" | put "$1/lib/ui/qg_parity/spacing_$2.dart"; }   # +1 line
seed_expandable_page_view() { t_expandable "$2" | put "$1/lib/qg_parity/expandable_$2.dart"; }   # +1 file
seed_typeerror_escaping_guards() { t_typeerror "$2" | put "$1/lib/qg_parity/typeerror_$2.dart"; }   # +1 line
seed_styled_elevated_button() { t_elevated "$2" | put "$1/lib/ui/qg_parity/elevated_$2.dart"; }   # +1 call
seed_svg_style_blocks() {   # +1 file
    printf '<svg xmlns="http://www.w3.org/2000/svg"><style>.qg%s{fill:#000}</style></svg>\n' "$2" | put "$1/assets/qg_parity/qg_parity_$2.svg"
}
seed_copywith_unguarded_merge() { t_copywith "$2" | put "$1/lib/data/qg_parity/copywith_$2.dart"; }   # +1 line
seed_critical_init_actions() {   # +1 action file with no isCritical
    [ -d "$1/lib/data/services/initialization/actions" ] || die 'lib/data/services/initialization/actions is missing'
    printf 'const qgParityAction%s = 0;\n' "$2" | put "$1/lib/data/services/initialization/actions/qg_parity_action_$2.dart"
}
seed_media_capture_ceilings() { printf '// qg parity %s: ResolutionPreset.high\n' "$2" | put "$1/lib/qg_parity/media_$2.dart"; }   # +1 line
seed_comment_blocks_over_two() { t_blocks "$2" | put "$1/lib/qg_parity/comment_blocks_$2.dart"; }   # +1 run of 3
seed_hardcoded_ui_strings() { t_strings "$2" | put "$1/lib/ui/qg_parity/strings_$2.dart"; }   # +1 line
seed_arb_banned_brand_words() { arb_add "$1" "qgParityBrand$2" "Donate qg parity $2" "qg paridad $2" "qg parity $2" "qg parity $2"; }   # +1 en value
seed_arb_pt_brazilian_forms() { arb_add "$1" "qgParityPt$2" "qg parity pt $2" "qg paridad pt $2" "celular qg $2" "qg parity pt $2"; }   # +1 pt value
seed_full_user_model_save() { printf '// qg parity %s: repo.updateCurrent(user)\n' "$2" | put "$1/lib/ui/qg_parity/user_save_$2.dart"; }   # +1 line
seed_committed_conflict_markers() {   # +1 file; the marker is built so this script carries none
    printf '%s qg parity %s\n' "$(printf '<%.0s' 1 2 3 4 5 6 7)" "$2" | put "$1/test/qg_parity/conflict_$2.txt"
}
seed_test_tail_dispose() {   # +1 dispose as a test's last statement
    cat <<EOF | put "$1/test/qg_parity/qg_parity_dispose_$2_test.dart"
import 'package:flutter_test/flutter_test.dart';

class QgParityVm$2 {
  void dispose() {}
}

void main() {
  test('qg parity dispose $2', () {
    final vm = QgParityVm$2();
    vm.dispose();
  });
}
EOF
}
seed_test_hardcoded_en_text() {   # +1 line naming the en value the arb-banned-brand-words seed adds
    cat <<EOF | put "$1/test/qg_parity/qg_parity_en_text_$2_test.dart"
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('qg parity en text $2', () {
    // find.text('Donate qg parity $2')
    expect(1, 1);
  });
}
EOF
}
seed_golden_seam_not_reset() {   # +1 file that sets a clock seam and never resets it
    cat <<EOF | put "$1/test/qg_parity/qg_parity_seam_$2_test.dart"
import 'package:flutter_test/flutter_test.dart';

void debugSetClockNow(DateTime? now) {}

void main() {
  test('qg parity clock seam $2', () {
    debugSetClockNow(DateTime(2020));
    expect(1, 1);
  });
}
EOF
}
seed_analytics_raw_error_field() { printf '// qg parity %s: trackError(e.toString())\n' "$2" | put "$1/lib/qg_parity/analytics_$2.dart"; }   # +1 line
seed_premium_hand_formatted_money() {   # +1 line
    [ -d "$1/lib/ui/premium" ] || die 'lib/ui/premium is missing'
    printf 'String qgParityMoney%s(double v) => v.toStringAsFixed(2);\n' "$2" | put "$1/lib/ui/premium/qg_parity_money_$2.dart"
}
seed_delete_flow_awaited_analytics() { printf '// qg parity %s: await analytics.track();\n' "$2" | put "$1/lib/ui/qg_parity/delete_qg_parity_$2.dart"; }   # +1 line
seed_detail_sheet_dynamic_state() { t_detail_sheet "$2" | put "$1/lib/qg_parity/detail_sheet_$2.dart"; }   # +1 line
seed_detail_screen_feed_widgets() {   # +1 line
    printf 'class PostTile {}\n\nObject qgParityScreen%s() => PostTile();\n' "$2" | put "$1/lib/ui/qg_parity/widgets/single_qg_parity_$2_screen.dart"
}
seed_paging_controller_cancel() { printf '// qg parity %s: pagingController.cancel()\n' "$2" | put "$1/lib/qg_parity/paging_$2.dart"; }   # +1 line
seed_polymorphic_type_filter() { t_polymorphic "$2" | put "$1/lib/qg_parity/polymorphic_$2.dart"; }   # +1 line
seed_e2e_screen_wake() { append_line "$1/tool/nightly_cron.sh" "# qg parity $2: KEYCODE_WAKEUP"; }   # +1 line
seed_e2e_boot_drain_teardown() {   # +1 line inside bootAndReachShell, indented as the line it follows
    local f="$1/integration_test/_support/e2e.dart"
    awk -v i="$2" '/^Future<void> bootAndReachShell/ { inb = 1 }
        { print }
        inb && !done && /addTearDown\(\(\) => drainAndQuiesce\(tester\)\)/ {
            match($0, /^[ \t]*/); printf "%s// qg parity %s: addTearDown(() => drainAndQuiesce(tester))\n", substr($0, 1, RLENGTH), i; done = 1 }
        inb && /^}/ { inb = 0 }' "$f" > "$f.qg" && mv "$f.qg" "$f" || die "cannot edit ${f}"
    grep -q "qg parity $2: addTearDown" "$f" || die "bootAndReachShell in ${f} has no addTearDown(() => drainAndQuiesce(tester)) line"
}
seed_e2e_whole_dir_run() { printf '#!/bin/sh\n# qg parity %s: flutter test integration_test/\n' "$2" | put "$1/tool/qg_parity_$2.sh"; }   # +1 line
seed_e2e_first_feed_tile() { printf '// qg parity %s: find.byType(PostTile).first\n' "$2" | put "$1/integration_test/qg_parity/first_tile_$2.dart"; }   # +1 line
seed_e2e_undrained_boot() { printf 'void bootApp() {}\n\nvoid main() {\n  bootApp();\n}\n' | put "$1/integration_test/qg_parity_boot_$2_test.dart"; }   # +1 file
seed_e2e_bytype_async_screen() { printf '// qg parity %s: find.byType(SingleQgParityScreen)\n' "$2" | put "$1/integration_test/qg_parity/bytype_$2.dart"; }   # +1 line
seed_semantic_clones() {   # +1 pair; each violation uses its own operators, so violations never pair
    local ops
    case "$2" in 1) ops='% ^' ;; 2) ops='<< |' ;; *) die "semantic-clones has shapes for violations 1 and 2 only" ;; esac
    # shellcheck disable=SC2086  # two operators
    t_clone "$2" a $ops | put "$1/lib/qg_parity/clone_$2_a.dart"
    # shellcheck disable=SC2086
    t_clone "$2" b $ops | put "$1/lib/qg_parity/clone_$2_b.dart"
}
seed_architecture_nccd() {   # +2 nodes and 1 edge
    printf "import 'lakos_%s_b.dart';\n\nint qgParityLakosA%s() => qgParityLakosB%s;\n" "$2" "$2" "$2" | put "$1/lib/qg_parity/lakos_$2_a.dart"
    t_lakos "B$2" | put "$1/lib/qg_parity/lakos_$2_b.dart"
}
seed_layer_inversions() { seed_reuse "$1" "$2" layer "^import '(package:givore/(data|ui|routing)/|(\.\./)+(data|ui|routing)/)"; }   # +1 banned import
seed_deep_nesting() { t_nest "$2" | put "$1/lib/qg_parity/nest_$2.dart"; }   # +1 function nested over 5
seed_many_parameters() { t_params "$2" | put "$1/lib/qg_parity/params_$2.dart"; }   # +1 function over 4 parameters
seed_long_functions() { t_long "$2" | put "$1/lib/qg_parity/long_$2.dart"; }   # +1 function over 50 source lines
seed_large_classes() { t_large "$2" | put "$1/lib/qg_parity/large_$2.dart"; }   # +1 class over 10 methods
seed_lint_refuse_new() { printf 'void qgParityVoidAsync%s() async {}\n' "$2" | put "$1/lib/qg_parity/lint_refuse_$2.dart"; }   # +1 avoid_void_async (error tier)
seed_lint_warn_new() { printf 'int qgParityFinalLocal%s() {\n  var qgW%s = 0;\n  return qgW%s;\n}\n' "$2" "$2" "$2" | put "$1/lib/qg_parity/lint_warn_$2.dart"; }   # +1 prefer_final_locals (warning tier)
seed_duplication_new() { :; }   # the duplication seed's clone pair: +13 added cloned lines
seed_suppressions_added() { printf '// ignore: avoid_print\nconst qgParitySuppress%s = 0;\n' "$2" | put "$1/lib/qg_parity/suppress_$2.dart"; }   # +1 ignore comment
seed_gate_config_touched() { printf 'qg parity %s\n' "$2" | put "$1/tool/checks/qg_parity_$2.txt"; }   # +1 protected path in both lists

# One gen_<id> per v1 row whose v2 row filters generated files: gen_<id> <clone> writes a hit of that
# row in every generated-file form it filters. The hits are the same in seed1 and seed2.
gen_format() {
    gen_forms "$1" lib/qg_parity format "$ALL_FORMS" t_format
    t_format GenFixture | put "$1/tool/givore_lints/test/fixtures/qg_parity_format.dart"
}
gen_complexity() { gen_forms "$1" lib/qg_parity complexity "$ALL_FORMS" t_complexity; }
gen_deep_nesting() { gen_forms "$1" lib/qg_parity nest "$ALL_FORMS" t_nest; }
gen_many_parameters() { gen_forms "$1" lib/qg_parity params "$ALL_FORMS" t_params; }
gen_long_functions() { gen_forms "$1" lib/qg_parity long "$ALL_FORMS" t_long; }
gen_large_classes() { gen_forms "$1" lib/qg_parity large "$ALL_FORMS" t_large; }
gen_layer_inversions() {
    # Beside a data or routing import that is neither an api_model nor a ui import, so the
    # domain-api-model-imports and domain-ui-imports rows, which filter nothing, never see it. No
    # lib/generated form: its relative import would add a folder edge outside lib/domain.
    local found
    if ! found="$(domain_import "$1" "^import '(package:givore/(data|routing)/|(\.\./)+(data|routing)/)" api_model)"; then
        say "layer-inversions: no lib/domain data or routing import outside api_model; its generated hits are not seeded"
        return 0
    fi
    gen_forms "$1" "${found%%$'\t'*}" layer 'g freezed mocks config' t_reuse "${found#*$'\t'}"
}
gen_architecture_nccd() { gen_forms "$1" lib/qg_parity lakos 'g freezed dir' t_lakos; }
gen_comment_density() { gen_forms "$1" lib/qg_parity comment_density "$ALL_FORMS" t_comment_density; }
gen_compact_density_iconbutton() { gen_forms "$1" lib/ui/qg_parity compact "$ALL_FORMS" t_compact; }
gen_static_singletons() { gen_forms "$1" lib/qg_parity singleton 'g freezed' t_singleton; }
gen_magic_spacing_literals() { gen_forms "$1" lib/ui/qg_parity spacing "$ALL_FORMS" t_spacing; }
gen_typeerror_escaping_guards() { gen_forms "$1" lib/qg_parity typeerror "$ALL_FORMS" t_typeerror; }
gen_styled_elevated_button() { gen_forms "$1" lib/ui/qg_parity elevated "$ALL_FORMS" t_elevated; }
gen_copywith_unguarded_merge() { gen_forms "$1" lib/data/qg_parity copywith "$ALL_FORMS" t_copywith; }
gen_comment_blocks_over_two() { gen_forms "$1" lib/qg_parity blocks "$ALL_FORMS" t_blocks; }
gen_detail_sheet_dynamic_state() { gen_forms "$1" lib/qg_parity detail_sheet "$ALL_FORMS" t_detail_sheet; }
gen_polymorphic_type_filter() { gen_forms "$1" lib/qg_parity polymorphic 'g freezed mocks' t_polymorphic; }
gen_coverage() { gen_forms "$1" lib/qg_parity coverage 'g freezed mocks config gr dir' t_gen_coverage; }   # every failing test runs each once
gen_tests_failing() { :; }   # its exclude= reads only in metric=coverage; gen_coverage seeds the run both rows share

for id in $V1_IDS; do declare -F "seed_${id//-/_}" > /dev/null || die "no seed_${id//-/_} for v1 row ${id}"; done
for id in $GEN_IDS; do declare -F "gen_${id//-/_}" > /dev/null || die "no gen_${id//-/_} for ${id}, whose v2 row filters generated files"; done

# seed <clone> <n> <a|b> — phase a: every row's violations 1..n except ROWS_B; phase b: ROWS_B's
# violations and every generated hit, written after the commit gate so it judges phase a alone.
seed() {
    local d="$1" n="$2" phase="$3" id i
    for id in $V1_IDS; do
        case "$ROWS_B" in *" $id "*) [ "$phase" = b ] || continue ;; *) [ "$phase" = a ] || continue ;; esac
        for i in $(seq 1 "$n"); do "seed_${id//-/_}" "$d" "$i"; done
    done
    if [ "$phase" = b ]; then for id in $GEN_IDS; do "gen_${id//-/_}" "$d"; done; fi
}

# lock_seed <clone> <n> — the first n Dart tool packages dart-tools-changed names get a version the
# base lock does not hold.
lock_seed() {
    local d="$1" names='' p
    for p in $(v2_cell dart-tools-changed 5 | sed -n 's/.*packages=\([^ ]*\).*/\1/p' | tr ',' ' '); do
        grep -qx "  ${p}:" "$d/pubspec.lock" && names+="$p "
    done
    names="$(printf '%s' "$names" | tr ' ' '\n' | head -"$2" | tr '\n' ' ')"
    [ "$(wc -w <<<"$names")" -eq "$2" ] || die "pubspec.lock holds fewer than $2 of the packages dart-tools-changed names"
    awk -v names=" ${names}" '/^  [^ ].*:$/ { cur = $1; sub(/:$/, "", cur) } /^[^ ]/ { cur = "" }
        cur != "" && index(names, " " cur " ") && /^    version: / { print "    version: \"0.0.0-qgparity\""; next } { print }' \
        "$d/pubspec.lock" > "$d/pubspec.lock.qg" && mv "$d/pubspec.lock.qg" "$d/pubspec.lock" || die 'cannot edit pubspec.lock'
}

# --- the clones --------------------------------------------------------------------------------

say "base ${BASE:0:12} (${BRANCH}) of ${LIVE}; work ${WORK}"
for side in old new; do
    git clone -q --shared --no-checkout "$LIVE" "$WORK/$side" || die "cannot clone into $side"
    git -C "$WORK/$side" checkout -q --detach "$BASE" || die "cannot check out ${BASE} in $side"
    git -C "$WORK/$side" config user.email parity@example.invalid
    git -C "$WORK/$side" config user.name parity
    git -C "$WORK/$side" config core.hooksPath /dev/null
done

# The new side's SDK: a mirror of guard_flutter_root whose bin/flutter and dart-sdk/bin/dart are
# scripts. Its path is the clone's guard_flutter_root and its bin/ is first on the new side's PATH, so
# the drivers' flutter-on-PATH check passes.
mirror() {  # mirror <real dir> <mirror dir> <entry not linked>...
    local real="$1" dst="$2" e name; shift 2
    mkdir -p "$dst" || die "cannot create ${dst}"
    for e in "$real"/* "$real"/.[!.]*; do
        [ -e "$e" ] || [ -L "$e" ] || continue
        name="${e##*/}"
        case " $* " in *" $name "*) continue ;; esac
        ln -s "$e" "$dst/$name" || die "cannot link ${e}"
    done
}
SDK="$WORK/sdk"
mirror "$FLUTTER_SDK" "$SDK" bin
mirror "$FLUTTER_SDK/bin" "$SDK/bin" cache flutter
mirror "$FLUTTER_SDK/bin/cache" "$SDK/bin/cache" dart-sdk
mirror "$FLUTTER_SDK/bin/cache/dart-sdk" "$SDK/bin/cache/dart-sdk" bin
mirror "$FLUTTER_SDK/bin/cache/dart-sdk/bin" "$SDK/bin/cache/dart-sdk/bin" dart
printf '#!/bin/bash\nexec "%s/bin/flutter" "$@"\n' "$FLUTTER_SDK" > "$SDK/bin/flutter"
# mutation_test's summary per state: 20, 21 and 22 undetected of 100, so the v1 value reads 80.00,
# 79.00 and 78.00.
mkdir -p "$WORK/mutation" "$WORK/oldshim"
for k in 0 1 2; do printf 'Total tests: 100\nUndetected Mutations: %d (%d.00%%)\n' "$((20 + k))" "$((20 + k))" > "$WORK/mutation/$k.txt"; done
dart_shim() {  # dart_shim <file> <real dart>
    cat > "$1" <<SHIM
#!/bin/bash
# The recorded mutation_test summary of the state being measured; every other call is the real dart.
if [ "\${1:-}" = run ] && [ "\${2:-}" = mutation_test ]; then
    cat "$WORK/mutation/\$(cat "$WORK/state" 2>/dev/null || echo 0).txt"
    exit 255
fi
exec "$2" "\$@"
SHIM
    chmod +x "$1"
}
dart_shim "$SDK/bin/cache/dart-sdk/bin/dart" "$FLUTTER_SDK/bin/cache/dart-sdk/bin/dart"
chmod +x "$SDK/bin/flutter"
# The old side runs v1's `dart run mutation_test` from PATH.
dart_shim "$WORK/oldshim/dart" "$FLUTTER_SDK/bin/dart"

# new: the prepared v2 files, with guard_flutter_root naming the mirror.
mkdir -p "$WORK/new/quality/bin"
cp "$MIG/checks.tsv" "$WORK/new/quality/checks.tsv"
sed "s#^guard_flutter_root:.*#guard_flutter_root: ${SDK}#" "$MIG/config" > "$WORK/new/quality/config"
grep -qx "guard_flutter_root: ${SDK}" "$WORK/new/quality/config" || die "cannot point guard_flutter_root at ${SDK}"
cp "$MIG/commit-lint.sh" "$WORK/new/quality/bin/commit-lint.sh" && chmod +x "$WORK/new/quality/bin/commit-lint.sh"
git -C "$WORK/new" add quality && git -C "$WORK/new" commit -qm 'parity: v2 rows' || die 'cannot commit the new fixture'
# shellcheck disable=SC2034  # read through ${!fixture}
FIXTURE_new="$(git -C "$WORK/new" rev-parse HEAD)"
# shellcheck disable=SC2034
FIXTURE_old="$BASE"
for side in old new; do
    fixture="FIXTURE_$side"
    git -C "$WORK/$side" update-ref refs/remotes/origin/qg-parity-base "${!fixture}" \
        && git -C "$WORK/$side" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/qg-parity-base \
        || die "cannot point origin/HEAD of $side at its fixture"
    say "$side: flutter pub get --offline"
    ( cd "$WORK/$side" && timeout "$STEP_TIMEOUT" "$FLUTTER_SDK/bin/flutter" pub get --offline ) >> "$LOG" 2>&1 \
        || die "flutter pub get --offline failed in the $side clone; run flutter pub get in ${LIVE} first"
done
# The new side has no network; pnpm dlx then needs jscpd in its cache.
for spec in $(grep -o 'jscpd@[0-9.]*' "$MIG/checks.tsv" | sort -u); do
    ( cd "$WORK" && timeout 600 pnpm dlx "$spec" --version ) >> "$LOG" 2>&1 || say "WARNING: cannot fetch ${spec} into the pnpm cache"
done

# --- the runs ----------------------------------------------------------------------------------

results_file() { printf '%s/qg-last/RESULTS.txt' "$(git -C "$1" rev-parse --path-format=absolute --git-common-dir)"; }

# engine <side> <GUARD_SHA or -> <guard.sh argv...> — that side's engine in its clone, output to the
# log. The new side runs under NS with the mirror SDK first on PATH.
engine() {
    local side="$1" sha="$2" eng rc=0; shift 2
    local -a env=(GUARD_LOCK_WAIT=600) ns=()
    if [ "$side" = old ]; then eng="$OLD_ROOT/bin/guard.sh"; env+=(PATH="$WORK/oldshim:$FLUTTER_SDK/bin:$PATH")
    else eng="$NEW_ROOT/bin/guard.sh"; env+=(PATH="$SDK/bin:$PATH"); ns=("${NS[@]}"); fi
    [ "$sha" = - ] || env+=(GUARD_SHA="$sha")
    rm -f "$(results_file "$WORK/$side")"
    ( cd "$WORK/$side" && env "${env[@]}" timeout "$STEP_TIMEOUT" "${ns[@]}" bash "$eng" "$@" ) >> "$LOG" 2>&1 || rc=$?
    [ "$rc" -ne 124 ] || die "$side: guard.sh $1 ran longer than ${STEP_TIMEOUT}s"
}
# collect <side> <state> <id ERE> — appends "<state> <id> <value> <status>" for each measured row.
collect() {
    cat "$(results_file "$WORK/$1")" 2>/dev/null \
        | awk -F'|' -v s="$2" -v re="$3" '$1 ~ re && $4 != "skipped" && $4 != "absent" { print s " " $1 " " $2 " " $4 }' >> "$WORK/$1.results"
}

measure() {  # measure <side> <state> <n>
    local side="$1" state="$2" n="$3" d="$WORK/$1" fixture="FIXTURE_$1"
    git -C "$d" reset -q --hard "${!fixture}" && git -C "$d" clean -qfd || die "$side $state: cannot reset the clone"
    printf '%s\n' "$n" > "$WORK/state"
    if [ "$n" -eq 0 ]; then printf 'parity\n' | put "$d/test/qg-parity-clean.txt"; else seed "$d" "$n" a; fi
    git -C "$d" add -A || die "$side $state: cannot stage the seeds"

    say "$side $state: commit rows"
    engine "$side" - commit
    collect "$side" "$state" '.'
    if [ "$side" = new ] && [ "$n" -gt 0 ]; then
        say "$side $state: dart-tools-changed on a seeded pubspec.lock"
        lock_seed "$d" "$n"
        git -C "$d" add pubspec.lock || die "$side $state: cannot stage pubspec.lock"
        engine "$side" - commit --only dart-tools-changed
        collect "$side" "$state" '^dart-tools-changed$'
        git -C "$d" reset -q -- pubspec.lock && git -C "$d" checkout -q -- pubspec.lock || die "$side $state: cannot restore pubspec.lock"
    fi

    [ "$n" -eq 0 ] || seed "$d" "$n" b
    git -C "$d" add -A && git -C "$d" commit -qm "parity: ${state}" || die "$side $state: cannot commit the seeds"
    say "$side $state: push rows"
    engine "$side" "$(git -C "$d" rev-parse HEAD)" release "$REF"
    collect "$side" "$state" '.'

    say "$side $state: baseline rows"
    engine "$side" - baseline --only mutation
    collect "$side" "$state" '^mutation$'
    git -C "$d" checkout -q -- quality/baseline.tsv 2> /dev/null
}

for side in old new; do
    measure "$side" clean 0
    measure "$side" seed1 1
    measure "$side" seed2 2
done

# --- the table ---------------------------------------------------------------------------------

value() { awk -v s="$2" -v id="$3" '$1 == s && $2 == id { v = $3 "/" $4 } END { print (v == "" ? "-" : v) }' "$WORK/$1.results"; }
num() { [[ "${1%%/*}" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; }
nums() { local v; for v in "$@"; do num "$v" || return 1; done; }
moved() { awk -v a="${1%%/*}" -v b="${2%%/*}" 'BEGIN { exit !(a + 0 != b + 0) }'; }
# linear <id> <clean> <seed1> <seed2> -> 0 when the row is NONLINEAR or seed2 - clean = 2 x (seed1 - clean).
linear() {
    case "$NONLINEAR" in *" $1 "*) return 0 ;; esac
    awk -v c="${2%%/*}" -v a="${3%%/*}" -v b="${4%%/*}" 'BEGIN { d = (b - c) - 2 * (a - c); exit !(d < 1e-6 && d > -1e-6) }'
}
clean_same() {  # clean_same <v1 id> <old clean> <new clean>
    local r rule=''
    for r in $CLEAN_RULE; do [ "${r%%=*}" = "$1" ] && rule="${r#*=}"; done
    case "$rule" in
        zero)  awk -v o="${2%%/*}" -v n="${3%%/*}" 'BEGIN { exit !((o + 0 == 0) == (n + 0 == 0)) }' ;;
        equal) awk -v o="${2%%/*}" -v n="${3%%/*}" 'BEGIN { exit !(o + 0 == n + 0) }' ;;
        *)     return 0 ;;
    esac
}

table="$MIG/parity.tsv"
printf 'id\tnew-id\tkind\tverdict\told-clean\told-seed1\told-seed2\tnew-seed1\tnew-seed2\n' > "$table"
worst=0
for id in $V1_IDS; do
    nid="$(renamed_to "$id")"
    oc="$(value old clean "$id")" o1="$(value old seed1 "$id")" o2="$(value old seed2 "$id")"
    nc="$(value new clean "$nid")" n1="$(value new seed1 "$nid")" n2="$(value new seed2 "$nid")"
    if ! nums "$oc" "$o1" "$o2" "$nc" "$n1" "$n2" || ! moved "$oc" "$o1"; then verdict=VACUOUS
    elif [ "$nid" != "$id" ]; then
        if ! moved "$nc" "$n1" || ! linear "$nid" "$nc" "$n1" "$n2"; then verdict=VACUOUS
        elif ! clean_same "$id" "$oc" "$nc"; then verdict=DIFF; say "${id} -> ${nid}: clean ${oc} on v1, ${nc} on v2"
        else verdict=NEW; fi
    elif ! linear "$id" "$oc" "$o1" "$o2"; then verdict=VACUOUS
    elif [ "$o1" = "$n1" ] && [ "$o2" = "$n2" ]; then verdict=SAME
    else verdict=DIFF; fi
    [ "$verdict" != VACUOUS ] || say "${id}: vacuous (old ${oc} ${o1} ${o2}, new ${nc} ${n1} ${n2})"
    case "$verdict" in VACUOUS) worst=2 ;; DIFF) [ "$worst" -lt 1 ] && worst=1 ;; esac
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$nid" "$(v2_cell "$nid" 3)" "$verdict" "$oc" "$o1" "$o2" "$n1" "$n2" >> "$table"
done
# v2 rows with no v1 id: measured on the new side only, against its own clean value.
for nid in $(awk -F'\t' 'NR > 1 && $0 !~ /^#/ && $3 != "absent" { print $1 }' "$MIG/checks.tsv"); do
    [ "$(renamed_from "$nid")" = "$nid" ] || continue
    case " $V1_IDS " in *" $nid "*) continue ;; esac
    nc="$(value new clean "$nid")" n1="$(value new seed1 "$nid")" n2="$(value new seed2 "$nid")"
    if nums "$nc" "$n1" "$n2" && moved "$nc" "$n1" && linear "$nid" "$nc" "$n1" "$n2"; then verdict=NEW
    else verdict=VACUOUS; worst=2; say "${nid}: vacuous (new ${nc} ${n1} ${n2})"; fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' - "$nid" new "$verdict" - - - "$n1" "$n2" >> "$table"
done
column -t -s $'\t' "$table" >&2 2> /dev/null || cat "$table" >&2

if [ "$(git -C "$LIVE" --no-optional-locks status --porcelain)" != "$LIVE_STATUS" ]; then
    say "git status --porcelain of ${LIVE} changed during the run"; worst=2
fi
say "parity table: ${table}"
case "$worst" in
    0) echo "parity: every kept id reads the same value and status on both seeds" ;;
    1) echo "parity: a kept id or a renamed clean value differs; see ${table}" ;;
    *) echo "parity: a row was vacuous or unmeasured, or the live checkout changed; see ${table} and ${LOG}" ;;
esac
exit "$worst"
