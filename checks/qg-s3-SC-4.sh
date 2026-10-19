#!/usr/bin/env bash
# S3 SC-4 — migrations/<repo>/checks.tsv loads under this engine with migrations/<repo>/config for
# app.givore.com, dashboard.givore.com and recycling-api; names every id of the checkout's committed
# v1 file, an absent row naming an existing replacement; gives every row a distinct real why;
# protects every config= and runner= file, every default config a row's driver loads, every -c file
# in its argv and every script a shell row runs; every include= and exclude= matches a path the
# checkout tracks; no args cell holds `\|` or `…`; both web jscpd.json set "gitignore": false; and
# every tracked non-Markdown line of either web checkout that names checks.tsv is a comment.
#
#   checks/qg-s3-SC-4.sh [<workspace>]     default ~/workspace, holding the three checkouts
#
# Reads the checkouts with git only. Exit 0 pass, 1 fail, 2 could not run.
exec < /dev/null
set -uo pipefail
export LC_ALL=C
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
WS="${1:-$HOME/workspace}"
MIG="$ROOT/migrations"
REPOS='app.givore.com dashboard.givore.com recycling-api'
WEB='app.givore.com dashboard.givore.com'
FALLBACK='(no reason recorded'

WORK="$(mktemp -d)" || exit 2
trap 'rm -rf "$WORK"' EXIT

pass=0 total=0
case_() {  # case_ <name> <failure text or empty>
    total=$((total + 1))
    if [ -z "$2" ]; then pass=$((pass + 1)); else printf '  FAILING  %s: %s\n' "$1" "$2"; fi
}
rows() { awk -F'\t' 'NR > 1 && $0 !~ /^#/ && NF' "$1"; }

for repo in $REPOS; do
    git -C "$WS/$repo" rev-parse --verify -q HEAD >/dev/null || { echo "cannot read the checkout ${WS}/${repo}"; exit 2; }
    git -C "$WS/$repo" ls-files > "$WORK/$repo.tracked" || exit 2
done

for repo in $REPOS; do
    f="$MIG/$repo/checks.tsv" cfg="$MIG/$repo/config"

    # The engine loads the file as a commit would read it: committed beside its config.
    r="$WORK/load-$repo"
    mkdir -p "$r/quality" && cp "$f" "$r/quality/checks.tsv" && cp "$cfg" "$r/quality/config" \
        && printf 'id\ttool\tenforced_by\temits\n' > "$r/quality/rules.tsv" || exit 2
    ( cd "$r" && git init -q . && git add -A \
        && git -c user.email=check@example.invalid -c user.name=check -c commit.gpgsign=false \
               -c core.hooksPath=/dev/null commit -q -m v2 ) || exit 2
    out="$(cd "$r" && bash -c '. "$1/lib/guard-metrics.sh" && . "$1/lib/guard-pass.sh" && guard_load_checks quality/checks.tsv && echo loaded' _ "$ROOT" 2>&1)"
    [ "${out##*$'\n'}" = loaded ] && miss='' || miss="$out"
    case_ "$repo: loads under this engine with its config" "$miss"

    ids="$(rows "$f" | cut -f1)"
    miss=''
    v1="$(git -C "$WS/$repo" show HEAD:quality/checks.tsv 2>/dev/null)"
    if [ "$(head -1 <<<"$v1")" = "$(printf 'id\tscope\tkind\tcommand\tparser\tartifact\tdirection\tthreshold\tgate')" ]; then
        for id in $(awk -F'\t' 'NR > 1 && $0 !~ /^#/ && NF { print $1 }' <<<"$v1"); do
            grep -qx -- "$id" <<<"$ids" || miss+=" ${id}"
        done
        case_ "$repo: names every v1 id of HEAD:quality/checks.tsv" "${miss:+missing:$miss}"
    else
        case_ "$repo: names every v1 id of HEAD:quality/checks.tsv" "HEAD:quality/checks.tsv of ${WS}/${repo} is not a v1 file"
    fi

    miss=''
    while IFS=$'\t' read -r id _ _ _ _ _ _ _ why; do
        repl="$(sed -n 's/^replaced by \([a-z0-9-]*\).*/\1/p' <<<"$why")"
        [ -n "$repl" ] && [ -n "$(rows "$f" | awk -F'\t' -v r="$repl" '$1 == r && $3 != "absent"')" ] || miss+=" ${id}"
    done < <(rows "$f" | awk -F'\t' '$3 == "absent"')
    case_ "$repo: every absent row names an existing replacement" "${miss:+absent rows:$miss}"

    dup="$(rows "$f" | cut -f9 | sort | uniq -d)"
    bad="$(rows "$f" | awk -F'\t' -v fb="$FALLBACK" '$9 == "-" || $9 ~ /^TODO/ || index($9, fb) == 1 { print $1 }')"
    case_ "$repo: every why is distinct and neither the fallback nor TODO" "${dup:+repeated: ${dup}}${bad:+ no real why: ${bad//$'\n'/ }}"

    bad="$(rows "$f" | awk -F'\t' 'index($5, "\\|") || index($5, "…") { print $1 }')"
    case_ "$repo: no args cell holds \\| or …" "${bad:+rows: ${bad//$'\n'/ }}"

    # Every file a row makes a tool or a shell read, then each one no protected entry covers.
    prot="$(sed -n 's/^guard_protected_paths:[[:space:]]*//p' "$cfg")"
    rows "$f" | awk -F'\t' '$3 != "absent"' | while IFS=$'\t' read -r id _ _ driver args _; do
        bash -c '
            . "$1/lib/qg-row.sh"; args="$2" driver="$3"
            for k in config runner standard ruleset; do guard_args_kv "$args" "$k" && echo; done
            guard_args_kv "$args" config >/dev/null || case "$driver" in
                eslint) echo eslint.config.mjs ;; nuxt-typecheck) echo tsconfig.json ;; knip) echo knip.json ;;
                depcruise) echo .dependency-cruiser.cjs ;; fallow) echo .fallowrc.json ;; vitest) echo vitest.config.ts ;;
                stryker) echo stryker.config.json ;; phpinsights) echo phpinsights.php ;;
                composer-dependency-analyser) echo composer-dependency-analyser.php ;;
            esac
            case "$driver" in
                phpstan) echo phpstan.neon ;; pint) echo pint.json ;; phpunit) echo phpunit.xml ;; infection) echo infection.json5 ;;
                phpcs) guard_args_kv "$args" standard >/dev/null || echo phpcs.xml ;;
                jscpd|jscpd-added) echo .npmrc ;;
            esac
            argv="$(guard_args_argv "$args")"
            if [ "$driver" != shell ]; then
                grep -oE -- "(^| )(-c|--config) [^ ]+" <<<"$argv" | sed -E "s/^ ?(-c|--config) //"
            else
                # A repo path to a script: a word holding a slash, not one of the engine scripts.
                sed -E "s#\{\{guard\}\}/[A-Za-z0-9_.-]*##g" <<<"$argv" \
                    | grep -oE "(^|[^A-Za-z0-9_./-])[A-Za-z0-9_.][A-Za-z0-9_.-]*/[A-Za-z0-9_./-]*" \
                    | sed -E "s#^[^A-Za-z0-9_.]##" | grep -E "\.(sh|mjs|cjs|js|php|py)$"
            fi' _ "$ROOT" "$args" "$driver" | sed '/^$/d' | sed "s#^#${id}\t#"
    done > "$WORK/$repo.reads"
    miss=''
    while IFS=$'\t' read -r id path; do
        hit=''
        for p in $prot; do p="${p%/}"; { [ "$path" = "$p" ] || [[ "$path" == "$p"/* ]]; } && hit=1; done
        [ -n "$hit" ] || miss+=" ${id}:${path}"
    done < "$WORK/$repo.reads"
    [ -s "$WORK/$repo.reads" ] || miss=' (no file found to check; the extraction is broken)'
    case_ "$repo: every config, runner, default config, -c file and shell script a row reads is protected" "${miss:+unprotected:$miss}"

    miss=''
    while IFS=$'\t' read -r id args; do
        for k in include exclude; do
            ere="$(bash -c '. "$1/lib/qg-row.sh"; guard_args_kv "$2" "$3"' _ "$ROOT" "$args" "$k")" || continue
            grep -Eq -- "$ere" "$WORK/$repo.tracked" || miss+=" ${id}:${k}=${ere}"
        done
    done < <(rows "$f" | cut -f1,5)
    case_ "$repo: every include= and exclude= matches a path ${repo} tracks" "${miss:+matching nothing:$miss}"
done

for repo in $WEB; do
    v="$(jq -r '.gitignore' "$MIG/$repo/jscpd.json" 2>/dev/null)"
    case_ "$repo: quality/jscpd.json sets \"gitignore\": false" "$([ "$v" = false ] || printf 'gitignore is %s' "${v:-unreadable}")"

    comment='^[[:space:]]*(#|//|/\*|\*|<!--)'
    bad="$(git -C "$WS/$repo" grep -n -I -F 'checks.tsv' -- ':!*.md' \
        | awk -v re="$comment" '{ line = $0; sub(/^[^:]*:[0-9]+:/, "", line); if (line !~ re) print $0 }')"
    case_ "$repo: every tracked non-Markdown line naming checks.tsv is a comment" "${bad:+not a comment: ${bad//$'\n'/ | }}"
done

if [ "$pass" -ne "$total" ]; then printf '%s of %s cases failing\n' "$((total - pass))" "$total"; exit 1; fi
printf '%s of %s cases passing\n' "$total" "$total"
