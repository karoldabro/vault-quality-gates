#!/usr/bin/env bash
# S4 SC-2 — the Dart drivers and mobile's commit-lint.sh run the SDK pinned by guard_flutter_root by
# absolute path, resolve packages offline inside the measured tree only, run flutter test with
# --no-pub, ignore the caller's PUB_CACHE, FLUTTER_ROOT and XDG_CACHE_HOME, and refuse a planted
# flutter, pubspec_overrides.yaml, a tracked .dart_tool/ and a failed resolution.
#
# Exit 0 pass, 1 fail, 2 could not run.
set -uo pipefail
exec < /dev/null
. "$(dirname "${BASH_SOURCE[0]}")/_qg-cases.sh"
qg_cases \
    qg-dart.bats \
    "qg_dart_env pins QG_FLUTTER and QG_DART by absolute path, exports FLUTTER_ROOT and drops PUB_CACHE and XDG_CACHE_HOME" \
    "qg_dart_env refuses a flutter on PATH that is another file, naming both" \
    "a planted earlier flutter on PATH makes a Dart driver status error, and neither it nor the pinned dart runs" \
    "qg_dart_packages refuses a pubspec_overrides.yaml in the tree before pub get runs" \
    "qg_dart_packages under :index refuses a .dart_tool path staged in the index, before pub get" \
    "qg_dart_prepare runs dart pub get --offline --enforce-lockfile inside QG_TREE without the caller's PUB_CACHE, XDG_CACHE_HOME or FLUTTER_ROOT" \
    "an offline pub get failure is an error naming the step, its last 5 lines and the fix" \
    "qg_dart_config_key reads guard_flutter_root at QG_CONFIG_REV, never the working tree or the index" \
    -- qg-driver-flutter-test.bats \
    "flutter gets test --no-pub --coverage --coverage-path <private dir>/lcov.info --machine, in the tree, after an offline pub get" \
    -- qg-migration-mobile-lint.bats \
    "without guard_flutter_root at the config revision it fails at step 2 and no SDK runs" \
    "a flutter on PATH that is not the pinned SDK fails at step 2, naming both" \
    "a pubspec_overrides.yaml in the tree fails at step 2 before pub get" \
    "both pub gets run offline with --enforce-lockfile inside the tree, without the caller's PUB_CACHE or XDG_CACHE_HOME"
