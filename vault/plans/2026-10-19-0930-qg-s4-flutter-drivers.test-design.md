---
type: plan
project: vault-quality-gates
slug: 2026-10-19-0930-qg-s4-flutter-drivers-test-design
repos: [vault-quality-gates, recycling_mobile_app]
status: proposed
tags: [plan, quality-gate, drivers, testing]
---

# qg S4 Flutter drivers — test design

The contract document is `2026-10-19-0930-qg-s4-flutter-drivers.md`. It carries the success criteria,
the work items and the pinned outcomes each backlog row cites. Every backlog row is advisory until the
testing loop confirms it against the written code.

## Test design dossier

**Harness.** Each driver test builds a fake SDK folder (`<fake>/bin/flutter`,
`<fake>/bin/cache/dart-sdk/bin/dart`), names it as `guard_flutter_root` in a fixture `quality/config`,
puts `<fake>/bin` first on `PATH`, and asserts the fake left a call marker. Fake outputs are recorded
from real runs on `884aad23`, including the 31 MB dcl JSON and a real `--coverage --machine` stream.

**Driver outcomes** (err = `status: error`, `metric: null`; 0/nocall = `measured 0`, tool never runs):

| driver | measured | err |
|---|---|---|
| dart-analyze | exits 0..3; `code=` lower-cased; `severity=` floor counts its level and above | exit ≥4; nested options under `paths` outside `options-allow=`; unknown `severity=` |
| dart-format | exits 0, 1; count of `Changed` lines, summary never counted | exit ≥2; exit 1 with no `Changed` line |
| dart-code-linter | exits 0, 1 with a report written this run | no report; other exit; malformed or unknown `metric=` |
| layerlens | exit 0 with `DEPS.md` written this run | none written; `version=` mismatch; no `package=` |
| lakos | exits 0, 5 with JSON | other exit; no JSON; unknown `metric=` |
| mutation-test | exits 0, 255 with the summary line | exit 1, 2; no summary line; 0 mutations |
| copydetect | python exit 0 | interpreter absent; python exit ≠0; `venv-root` holding `..` |
| checkstyle | runner exit 0 and report present | runner ≠0; report missing or tracked; `bin=`, argv, `runner=` or `report=` missing |
| dart-lock | max count over `QG_BASES` | empty `QG_BASES`; lock missing at a base or in the tree; no `packages=` |
| flutter-test | `done` and ≥1 non-hidden test; exit 0 or 1 consistent with failures | no `done`; 0 visible tests; exit 1 with 0 failures; exit ≥2; LF 0 for coverage |
| grep-count | files, lines, awk counts; `exclude=` in every mode | path missing or empty; grep exit 2; awk failure; no pattern in files or lines mode |

**`qg_dart_env` and `qg_dart_packages`:** key absent or not an SDK → err naming the key; `flutter` on
`PATH` resolves elsewhere → err, planted tool never runs; no `flutter` on `PATH` → runs the pinned SDK;
overrides file or tracked `.dart_tool/` → err before `pub get`; offline failure → err naming the step, its
last 5 lines and `run flutter pub get`; success → caller `PUB_CACHE`, `FLUTTER_ROOT`, `XDG_CACHE_HOME`
absent from the tool's env, checkout byte-identical. `commit-lint.sh` takes the SDK from `HEAD:quality/config`
and reads `QG_FILES` before stdin.

**`dart-lock`:** identical → 0; a named package's version, source or url → 1 each package; named and
turned into `path` → 1, not 2; unnamed hosted bump → 0; unnamed turned into `path` or `git` → 1; already
`path` at the base → 0; a named package added or removed → 1.

**Boundaries:** dcl `>N` at N-1, N, N+1; coverage 0/N `0.00`, N/N `100.00`, 2/3 `66.67`, 1/8 `12.50`;
mutation 0% → `100.00`, 100% → `0.00`, 33.333% → `66.67`; `files=changed` with 0, 1 and 500 names, a
space, a leading `-` and non-ASCII; `paths=` spelled `lib`, `lib/`, `./lib` give one count.

**Fault hypotheses:** a gate reads 0 having measured nothing (empty awk glob reading stdin, hidden-only
stream, LF 0, no mutation line, empty bases); a planted report read as fresh; a shared report reused for
a second ref; a caller environment or an earlier `PATH` entry choosing the tool; a commit loosening its
judge; a row reading another row's output; `\|` copied from markdown into the TSV; generated files
counted; an online `pub get`; a renamed row drifting on a clean tree.

**Invariants:** `metric` equals the v1 command on the same output; every err partition writes no number;
two runs write identical bytes; rows sharing a run call the tool once per target; a row alone equals the
full run; the caller checkout is byte-identical after any Dart driver.

**Metamorphic relations for parity:** (seed2 − clean) = 2 × (seed1 − clean) for count rows; adding one
hit per generated-file form leaves every filtered row at its seed value; shuffling the rows before the
first suite row changes no value; renaming a file inside `lib/generated/` changes nothing; measuring a
state twice gives the same table.

## Test backlog

| id | source | kind | target (exact path) | intent | priority | disposition |
|----|--------|------|---------------------|--------|----------|-------------|
| T-1 | W-1 SC-2 | unit | `tests/unit/qg-dart.bats` | every `qg_dart_env` and `qg_dart_packages` case of the dossier, with call markers and an env dump | must | change: commit-lint.sh cases moved to `tests/unit/qg-migration-mobile-lint.bats` |
| T-2 | W-2 SC-6 | unit | `tests/unit/qg-driver-dart-lock.bats` | every `dart-lock` case, two bases, missing locks | must | implement |
| T-3 | W-3 SC-1 | unit | `tests/unit/qg-driver-dart-analyze.bats` | exits, `code=`, severity floors, `\|` in a message, nested options, 487/32 on the recorded output | must | implement |
| T-4 | W-4 SC-1 | unit | `tests/unit/qg-driver-dart-format.bats` | `Changed` counts, exit 1 without lines, fixture and `.g.dart` read 0, odd names reach argv whole, `\|`-escaped exclude matches nothing | must | implement |
| T-5 | W-5 SC-1 SC-5 | unit | `tests/unit/qg-driver-dart-code-linter.bats` | `>N` boundaries, `.classes` for `number-of-methods`, `issue:`, planted report with no write → err, one call for six rows, `paths=` difference splits, 10/1/50/175/104/66 | must | change: asserts 1/3/0/1/1/2 on the six-record `dcl.json` excerpt, each checked against an independent jq select |
| T-6 | W-6 W-7 SC-1 | unit | `tests/unit/qg-driver-layerlens.bats`, `tests/unit/qg-driver-lakos.bats` | layerlens none written, stale deleted, version mismatch, 33; lakos exits 0/5, unknown metric | must | change: layerlens asserts 6 edges from the one recorded `DEPS.md` copied into 3 folders |
| T-7 | W-8 SC-1 | unit | `tests/unit/qg-driver-flutter-test.bats` | stream partitions, non-event and truncated lines, coverage boundaries and filter equal to `lcov_summary.dart`, LF 0, two refs give 0 then 1 | must | change: coverage checked on the recorded `lcov.info` (50/335 = 14.93); `lcov_summary.dart` is not in the test image |
| T-8 | W-9 SC-1 | unit | `tests/unit/qg-driver-mutation-test.bats` | percent boundaries, exits, no summary line, 0 mutations, `-b` | must | implement |
| T-9 | W-10 SC-1 | unit | `tests/unit/qg-driver-copydetect.bats` | similarity at the threshold, 0 pairs, stub python failure, `venv-root=../x` | should | change: the stub python runs the driver script against a fake `copydetect` module, so the thresholds are tested |
| T-10 | W-11 SC-1 | unit | `tests/unit/qg-driver-grep-count.bats` | modes, path spellings, missing or empty path, anchored exclude equals v1 `grep -vE "<re>:"`, exclude in awk mode, empty glob with stdin fed, pattern with spaces, `.g.dart` hit unchanged | must | implement |
| T-11 | W-12 SC-1 SC-6 | unit | `tests/unit/qg-driver-checkstyle.bats` | runner failures, tracked report → err, report not deleted, added vs unchanged line, two rows one runner call | must | change: two rows call the runner twice and the tool once, the runner reusing its report |
| T-12 | W-0..W-12 SC-1 | unit | checks/qg-s4-SC-1.sh | required keys, no number on error, `cmp`-equal results across all eleven drivers | must | change: checks/qg-s4-SC-1.sh requires every case of the eleven driver suites to pass |
| T-13 | W-1 W-15 SC-2 | unit | checks/qg-s4-SC-2.sh | checkout porcelain and checksum unchanged after each Dart driver and `commit-lint.sh`; caller env ignored | must | implement |
| T-14 | W-16 SC-3 | unit | checks/qg-s4-SC-3.sh | v1 ids, distinct whys, protected files, no `\|`, suite rows last | must | implement |
| T-15 | W-8 W-16 SC-5 | integration | checks/qg-s4-SC-5.sh | each row alone equals the full run; shuffled pre-suite rows; a fake flutter writing into `QG_RUN_DIR` and the tree leaves earlier rows unchanged | must | change: unit cases for the shared runs and isolation; each row alone on a real clone runs inside the parity script |
| T-16 | W-12 W-15 SC-6 | unit | checks/qg-s4-SC-6.sh | staged `commit-lint.sh` edit runs the parent copy and is refused; tool bumps and `path` packages refused | must | change: the engine case is `tests/unit/qg-checkstyle-engine.bats` |
| T-17 | W-19 SC-4 | integration | checks/qg-parity-recycling_mobile_app.sh | new clean state; 2× delta; generated-hit pass; per-state mutation shim; new side under `unshare -rn`; renamed-row clean drift exits 1; live checkout unchanged; repeat run identical | must | implement: written, not run; the operator runs it |
| T-18 | W-19 SC-4 | integration | checks/qg-parity-recycling_mobile_app.sh | rename inside `lib/generated/` changes nothing; moving a hit file there lowers filtered rows by its hits | should | implement: written, not run; the operator runs it |
