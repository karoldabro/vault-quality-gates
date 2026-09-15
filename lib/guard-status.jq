# Builds quality-reports/status.json from one guard run.
#
# Inputs: $rows (the run's results), $commit, $surface, $accepted, $now.
#
# The six category keys ~/vault/givore/quality/build-dashboard.mjs fixes are kept.
# An id outside them lands under codeQuality.checks, which that aggregator already
# renders as an open map.

def num($s): if ($s | test("^-?[0-9]+([.][0-9]+)?$")) then ($s | tonumber) else null end;

# "recorded", "absent" and "skipped" become na: a number nothing was compared
# against is not a pass.
def verdict($s):
    {"ok": "pass", "warn": "warn", "worse": "fail", "unmeasurable": "unmeasurable"}[$s] // "na";

# Exact match, never a prefix. On a prefix, `coverage` and `coverage-age-days` both
# claim the `coverage` key and from_entries keeps whichever came last, so the real
# percentage disappears. Every other id belongs under codeQuality.checks, which the
# aggregator renders as an open map.
def category($id):
    ["coverage", "mutation", "tests", "e2e", "nightly"]
    | map(select(. == $id))
    | .[0];

def entry:
    {status: verdict(.status)}
    + (if num(.value)    != null then {value:  num(.value)}    else {} end)
    + (if num(.baseline) != null then {target: num(.baseline)} else {} end)
    + (if .detail != ""          then {detail: .detail}        else {} end);

def worst:
    map(.status) as $s
    | if   ($s | index("fail"))         then "fail"
      elif ($s | index("unmeasurable")) then "unmeasurable"
      elif ($s | index("warn"))         then "warn"
      elif (length > 0)                 then "pass"
      else "na" end;

($rows | map(select(category(.id) != null))) as $named
| ($rows | map(select(category(.id) == null))) as $cq
| ($named | map({key: category(.id), value: entry}) | from_entries) as $byname
| (if ($cq | length) > 0
   then {codeQuality: {status: ($cq | map(entry) | worst),
                       checks: ($cq | map({key: .id, value: entry}) | from_entries)}}
   else {} end) as $quality
| {
    schemaVersion: 1,
    surface: $surface,
    stack: "guard",
    generatedAt: $now,
    commit: (if $commit == "" then null else $commit end),
    acceptedRows: ($accepted | tonumber),
    categories: ($byname + $quality)
  }
