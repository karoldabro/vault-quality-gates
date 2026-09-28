# Reads a PHPStan baseline (phpstan-baseline.neon) and prints one line per entry key:
# "path<US>identifier<US>message<TAB>count<TAB>score". Used by bin/guard-baseline-growth.sh.
#
# score is the highest cognitive-complexity score the message accepts, else -1. The message
# holds a number or the ratchet's regex `(?:[0-9]|1[0-1])`; a pattern that is not a plain
# digit range scores 100000, above any real score, so widening it to `.*` is growth.
#
# -v strict=1: every line must have the shape the generator writes: `parameters:`,
# `\tignoreErrors:`, `\t\t-`, then `\t\t\t` message (one string or a ''' block),
# identifier, count and path, each once; blank lines; `#` comments before the header. Any
# other line (a string entry, an inline map, another neon key) makes the file unmeasurable:
# exit 2 printing "<line number> <reason>: <line>".

function maxscore(s,   k, n, d) {
    gsub(/\\d/, "[0-9]", s)
    gsub(/\(\?:/, "(", s)
    while (match(s, /\[0-9\]\{[0-9]+\}/)) {
        n = substr(s, RSTART + 6, RLENGTH - 7) + 0; d = ""
        for (k = 0; k < n; k++) d = d "[0-9]"
        s = substr(s, 1, RSTART - 1) d substr(s, RSTART + RLENGTH)
    }
    if (s !~ /^[0-9()|\[\]-]+$/) return 100000
    for (k = 9999; k >= 0; k--) if (k ~ ("^(" s ")$")) return k
    return -1
}

function bad(line, why, text) {
    if (!strict) return
    printf "%d %s: %s\n", line, why, text
    failed = 1
    exit 2
}

function flush(   key, k) {
    if (!have) return
    if (m == "" || p == "" || n == "") bad(start, "entry lacks a message, count or path", "-")
    key = p "\037" id "\037" m
    c[key] += (n == "" ? 1 : n)
    if (!(key in sc) || score > sc[key]) sc[key] = score
    have = 0; p = id = m = n = ""; score = -1
    for (k in got) delete got[k]
}

function field(k,   v) {
    if (!have) bad(NR, "a key outside a list entry", $0)
    if (k in got) bad(NR, "a repeated key", $0)
    got[k] = 1
    v = $0; sub(/^[^:]*:[[:space:]]*/, "", v)
    return v
}

function setmsg(t,   at, len) {
    m = t
    if (match(m, / is .*, keep it under /)) {
        at = RSTART; len = RLENGTH
        score = maxscore(substr(m, at + 4, len - 20))
        m = substr(m, 1, at - 1) " is N, keep it under " substr(m, at + len)
    }
}

BEGIN { score = -1 }

block {
    if ($0 ~ /^[[:space:]]*'''[[:space:]]*$/) { block = 0; setmsg(body); next }
    t = $0; sub(/^[[:space:]]+/, "", t)
    body = body (body == "" ? "" : "\\n") t
    next
}

/^[[:space:]]*$/ { next }

strict && head < 2 {
    if (head == 0 && /^#/) next
    if (head == 0 && $0 == "parameters:") { head = 1; next }
    if (head == 1 && $0 == "\tignoreErrors:") { head = 2; next }
    # PHPStan writes an empty baseline as an inline empty list; any later line is then foreign.
    if (head == 1 && $0 == "\tignoreErrors: []") { head = 3; next }
    bad(NR, "not the parameters: / ignoreErrors: header", $0)
}

/^[[:space:]]*-[[:space:]]*$/ {
    if (strict && $0 != "\t\t-") bad(NR, "a misindented list entry", $0)
    flush(); have = 1; start = NR; score = -1
    next
}

/^[[:space:]]*(raw)?[Mm]essage:/ {
    if (strict && $0 !~ /^\t\t\t(rawMessage|message): /) bad(NR, "a misindented key", $0)
    v = field("message")
    if (v == "'''") { block = 1; body = ""; blockstart = NR; next }
    if (strict && v !~ /^'.*'$/ && v !~ /^".*"$/ && v ~ /^['"\[{]/) bad(NR, "a message that is not one string", $0)
    setmsg(v)
    next
}

/^[[:space:]]*identifier:/ {
    if (strict && $0 !~ /^\t\t\tidentifier: [A-Za-z0-9_.]+$/) bad(NR, "an identifier that is not one token", $0)
    id = field("identifier")
    next
}

/^[[:space:]]*count:/ {
    if (strict && $0 !~ /^\t\t\tcount: [0-9]+$/) bad(NR, "a count that is not a number", $0)
    n = field("count")
    next
}

/^[[:space:]]*path:/ {
    if (strict && ($0 !~ /^\t\t\tpath: [^[:space:]]/ || $0 ~ /^\t\t\tpath: [\[{]/)) bad(NR, "a path that is not one value", $0)
    p = field("path")
    next
}

{ bad(NR, "a line the PHPStan baseline generator never writes", $0) }

END {
    if (failed) exit 2
    if (block) bad(blockstart, "an unclosed multi-line message", "'''")
    if (NR > 0 && head < 2) bad(NR, "not the parameters: / ignoreErrors: header", "end of file")
    flush()
    for (k in c) printf "%s\t%d\t%d\n", k, c[k], sc[k]
}
