#!/usr/bin/env bash
# in-server.sh <tree> <cache> <cmd...> — runs <cmd> in a fresh `server` container of recycling-api
# with <tree> mounted at /app. The release rows of quality/checks.tsv call it through `runner=`.
#
# <tree>   the folder the push gate measures: the checkout or linked worktree being pushed, whose own
#          vendor/ and .env the container uses.
# <cache>  unused; the runner contract passes it.
#
# The compose call is pinned: -f <tree>/docker-compose.yml, --project-directory <tree>,
# --env-file /dev/null, and no COMPOSE_* or DOCKER_HOST/DOCKER_CONTEXT from the caller, so neither
# the environment nor an uncommitted file can swap the image, the volumes or the command. Because of
# -f, compose reads no compose.yaml, compose.yml or docker-compose.override.y*ml from <tree>, so a
# local override (recycling-api keeps a CPU cap there) stays out of the run. An uncommitted change to
# docker-compose.yml or docker/server is refused. The image must already exist; compose never pulls or builds it here. vendor/ must match <tree>/composer.lock by
# package name and version (quality/bin/lock-check.sh, read from HEAD); file contents are not checked.
#
# Exit: the command's own exit code · 2 bad arguments, vendor/ or .env missing, an uncommitted
# docker-compose.yml or docker/server change, a missing image, or vendor/ not matching <tree>/composer.lock
set -euo pipefail

if [ "$#" -lt 3 ]; then
    echo "usage: in-server.sh <tree> <cache> <cmd...>" >&2
    exit 2
fi
tree="$1"
shift 2

[ -d "$tree" ] || { echo "in-server.sh: tree $tree does not exist" >&2; exit 2; }
tree="$(cd "$tree" && pwd -P)"
[ -f "$tree/docker-compose.yml" ] || { echo "in-server.sh: $tree has no docker-compose.yml" >&2; exit 2; }
for required in vendor .env; do
    [ -e "$tree/$required" ] || { echo "in-server.sh: $tree/$required does not exist; the container cannot boot without it" >&2; exit 2; }
done
# The compose file and the image's build files must be the committed ones, and the image must exist
# already: compose would otherwise build it from whatever the working tree holds.
if [ -n "$(git -C "$tree" status --porcelain -- docker-compose.yml docker/server 2>/dev/null)" ]; then
    echo "in-server.sh: docker-compose.yml or docker/server has uncommitted changes in $tree; commit or revert them" >&2
    exit 2
fi
docker image inspect recycling-api-server:latest >/dev/null 2>&1 \
    || { echo "in-server.sh: image recycling-api-server:latest is missing; build it with docker compose build server" >&2; exit 2; }

lock_lib="$(git -C "$tree" show HEAD:quality/bin/lock-check.sh 2>/dev/null)" \
    || { echo "in-server.sh: HEAD has no quality/bin/lock-check.sh" >&2; exit 2; }
# shellcheck source=lock-check.sh
. <(printf '%s\n' "$lock_lib")
lock_check_vendor "$tree/composer.lock" "$tree/vendor" || exit 2

# --env-file /dev/null leaves the compose file's ${...} unset; compose warns about each one.
unset COMPOSE_FILE COMPOSE_PROJECT_NAME COMPOSE_PROFILES COMPOSE_ENV_FILES DOCKER_HOST DOCKER_CONTEXT
docker compose -f "$tree/docker-compose.yml" --project-directory "$tree" --env-file /dev/null --progress quiet \
    run --rm --no-deps --pull never -T --user "$(id -u):$(id -g)" -e XDEBUG_MODE=off server nice -n 15 "$@" \
    2> >(grep -v 'level=warning msg="The \\"[A-Z0-9_]*\\" variable is not set' >&2)
