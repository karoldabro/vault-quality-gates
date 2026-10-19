#!/usr/bin/env bash
# S3 SC-1 — each of the eight web drivers and jscpd-added equals its v1 computation on a recorded
# report and exit code; writes status error with metric null on a crash, an error exit, a stale
# report, or a whole-repo eslint run linting no file; measures 0 without running the tool when
# files=changed matches nothing; passes a runner no path outside QG_TREE; and writes the same bytes
# twice and for permuted findings.
# Exit 0 pass, 1 fail, 2 could not run. Cases: tests/unit/.
exec < /dev/null
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/_qg-cases.sh"
qg_cases \
    qg-driver-kit.bats \
    "qg_tool deletes the report first, so a tool that writes none is an error, never the old report" \
    "qg_tool refuses an exit code outside the ok set and an argv path under QG_OUT" \
    "qg_tool calls a runner as <runner> <tree> <cache> <argv>" \
    "qg_shared_report runs the tool once per target and args, and a new target runs it again" \
    -- qg-driver-eslint.bats \
    "errors, problems and rules on the recorded app report equal the v1 numbers" \
    "lines=added equals commit-check.sh lint (problems, 7) and tree-report.sh lint (errors, 2)" \
    "exit 1 without a report, exit 2 and exit 137 are status error with metric null" \
    "a report left in the tree by an earlier run is deleted first, never read" \
    "a whole-repo run that lints no file is status error" \
    "files=changed with no file matching include= measures 0 and never calls eslint" \
    "through a runner, no argv word names a path outside the tree" \
    "with QG_RUN_DIR, lint-errors and mess rows run eslint once" \
    "two runs write the same bytes; permuted messages give the same metric" \
    -- qg-driver-nuxt-typecheck.bats \
    "the recorded nuxt typecheck output reads 45, as quality-metric.mjs and metric.sh typecheck" \
    "lines=added on recorded vue-tsc output equals commit-check.sh typecheck (3)" \
    "lines=added on recorded nuxt typecheck output equals tree-report.sh typecheck (3)" \
    "a non-zero exit with no error TS is status error, never 0" \
    "exit 137 is status error even with error TS lines" \
    "files=changed with no file matching include= measures 0 and runs nothing" \
    "through a runner, no argv word names a path outside the tree" \
    "two runs write the same bytes; permuted output lines give the same metric" \
    -- qg-driver-knip.bats \
    "the recorded app report, Nuxt logs first, at exit 1 equals v1 deadcode: 248" \
    "stdout with no line starting with { is status error with metric null" \
    "exit 2 is status error even with a JSON report" \
    "two runs write the same bytes, and permuted issues give the same metric and findings" \
    -- qg-driver-depcruise.bats \
    "the recorded app report at exit 0 equals v1 architecture: 2, warn-severity violations included" \
    "totalCruised 0 is status error with metric null, never 0" \
    "no JSON, empty stdout, or JSON without a summary is status error" \
    "two runs write the same bytes, and permuted violations give the same metric and findings" \
    -- qg-driver-fallow.bats \
    "metric=dupes on the recorded app report equals fallow-parsers.mjs: 11160" \
    "metric=boundaries on the recorded app report equals fallow-parsers.mjs: 0" \
    "metric=complexity-excess on the recorded app report equals fallow-parsers.mjs: 665" \
    "a report without the key its metric reads is status error, never 0" \
    "exit 1 with JSON is measured; exit 2 with JSON, and exit 0 or 1 without JSON, are status error" \
    "two runs write the same bytes, and permuted findings give the same metric and findings" \
    -- qg-driver-vitest.bats \
    "metric=failed is failures + errors of the <testsuites> root, not of a suite: 0, 1, 3" \
    "the real app.givore.com junit root reads 0, as v1 tests-failing does" \
    "metric=coverage equals the v1 clover parser on the real app.givore.com report: 44.22" \
    "zero tests, no <testsuites> root, or a root without errors is status error" \
    "a run that writes no junit, or exits 2, is status error; the old junit is never read" \
    "two runs on the same report write the same bytes" \
    -- qg-driver-stryker.bats \
    "the metric equals v1 mutation on the same reports, compared as numbers" \
    "a missing, empty or malformed report is status error" \
    "a run that writes no report is status error; the old report is never read" \
    "permuted mutants give the same metric, and two runs write the same bytes" \
    -- qg-driver-jscpd.bats \
    "metric=percentage and metric=clones equal the v1 jscpd parser on the real app.givore.com report" \
    "a non-zero exit, no report, or a report without the statistic is status error" \
    "two rows of one run that differ only in metric= make one jscpd call" \
    "bin= with a runner runs the installed jscpd through it, calls no pnpm dlx, and passes config= as -c" \
    "two runs on the same report write the same bytes" \
    -- qg-driver-jscpd-added.bats \
    "both sides of a clone on added lines count 2" \
    "no added line under paths= measures 0 and never calls pnpm" \
    "a jscpd that writes no report is status error, and the output dir is still removed" \
    "a non-zero jscpd exit is status error" \
    -- qg-driver-phpunit.bats \
    "metric=coverage equals the v1 clover parser for 0/N, N/N and 2/3"
