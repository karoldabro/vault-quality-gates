#!/usr/bin/env bash
# S2 SC-3 — each of the nine drivers equals its v1 parser on a recorded report, writes status error
# on a crash, an error exit or a stale report, measures 0 without running the tool on an empty
# changed-file set, passes a runner no path outside QG_TREE, and shares no report across targets.
# Exit 0 pass, 1 fail, 2 could not run. Cases: tests/unit/.
. "$(dirname "${BASH_SOURCE[0]}")/_qg-cases.sh"
qg_cases \
    qg-driver-kit.bats \
    "qg_tool deletes the report first, so a tool that writes none is an error, never the old report" \
    "qg_tool refuses an exit code outside the ok set and an argv path under QG_OUT" \
    "qg_shared_report runs the tool once per target and args, and a new target runs it again" \
    "qg_added_only refuses a finding path outside the tree, and a finding on an unchanged line adds 0" \
    -- qg-driver-pint.bats \
    "pint-bad.json at exit 1 is measured with metric 1, the failing file count" \
    "exit 1 with no JSON (pint-crash.txt) is status error with metric null" \
    "files=changed with no matching .php measures 0 and never calls pint" \
    -- qg-driver-phpcs.bats \
    "lines=added counts only messages on added lines, equal to guard-added-lines.sh --checkstyle" \
    "exit 3 (phpcs-crash.txt) is status error with metric null" \
    "files=changed with no matching .php measures 0 and never calls phpcs" \
    -- qg-driver-phpmd.bats \
    "several files and violations, in either order, equal the v1 parser" \
    "exit 1 (phpmd-crash.txt) and exit 3 are status error with metric null" \
    "files=changed with an empty file set measures 0 and never calls phpmd" \
    -- qg-driver-phpinsights.bats \
    "metric code, complexity, architecture and style each equal the v1 insights parser with that selector" \
    "a crash (exit 1, phpinsights-crash.txt, no JSON) is status error" \
    "with QG_RUN_DIR, four rows differing only in metric= on one target call the tool once" \
    -- qg-driver-composer-dependency-analyser.bats \
    "cda-shadow.txt with metric=shadow is 26 and equals the v1 cda parser" \
    "cda-badconfig.txt (exit 1, no result line) is status error with metric null" \
    -- qg-driver-phpunit.bats \
    "metric=failed equals the v1 junit parser: failures + errors of the first testsuite" \
    "metric=coverage equals the v1 clover parser for 0/N, N/N and 2/3" \
    "without run=no the old report is deleted first, so a phpunit that writes none is status error" \
    -- qg-driver-infection.bats \
    "msi from .stats.msi equals the v1 parser" \
    "a null msi, or none at all, is status error with metric null, as v1 refuses it" \
    -- qg-driver-jscpd-added.bats \
    "both sides of a clone on added lines count 2" \
    "no added line under paths= measures 0 and never calls pnpm" \
    "a jscpd that writes no report is status error, and the output dir is still removed" \
    -- qg-driver-cloc.bats \
    "metric=comment-ratio on the real cloc.json equals the v1 cloc parser" \
    "SUM.code 0 is status error with metric null, as v1 refuses it" \
    -- qg-driver-phpstan.bats \
    "metric equals the phpstan-all parser for 0, N, file-less only, files only and both" \
    "files=changed analyses only changed .php files, and measures 0 without calling phpstan when none"
