# Reads a PHPMD baseline (quality/phpmd-baseline.xml) and prints one line per entry key:
# "file<US>rule<US>method<TAB>count<TAB>-1". Used by bin/guard-baseline-growth.sh.
#
# -v strict=1: every line must have the shape the generator writes: the XML declaration,
# <phpmd-baseline>, one <violation rule=".." file=".." [method=".."]/> per line,
# </phpmd-baseline>, blank lines. Any other line makes the file unmeasurable: exit 2
# printing "<line number> <reason>: <line>".

function attr(s, k) {
    return match(s, " " k "=\"[^\"]*\"") ? substr(s, RSTART + length(k) + 3, RLENGTH - length(k) - 4) : ""
}

function bad(why) {
    if (!strict) return
    printf "%d %s: %s\n", NR, why, $0
    failed = 1
    exit 2
}

/^[[:space:]]*<violation / {
    if ($0 !~ /^[[:space:]]*<violation rule="[^"]+" file="[^"]+"( method="[^"]+")?\/>[[:space:]]*$/)
        bad("a violation element the PHPMD generator never writes")
    c[attr($0, "file") "\037" attr($0, "rule") "\037" attr($0, "method")]++
    next
}

/^[[:space:]]*$/ || /^<\?xml [^>]*\?>[[:space:]]*$/ || /^<phpmd-baseline>[[:space:]]*$/ || /^<\/phpmd-baseline>[[:space:]]*$/ { next }

{ bad("a line the PHPMD baseline generator never writes") }

END {
    if (failed) exit 2
    for (k in c) printf "%s\t%d\t-1\n", k, c[k]
}
