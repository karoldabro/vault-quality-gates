#!/usr/bin/env bash
# Build the test image if needed and run the bats suite inside Docker.
#
# The repo mounts read-only at /code, so a test that asserts "this writes nothing"
# cannot pass by accident against a tree it was never able to write to. Every test
# that does assert a write builds its tree under mktemp -d on the exec tmpfs.
#
# Exit 2, never 1, when Docker is missing: the checks in checks/ read 2 as "could
# not run the suite" and 1 as "the suite failed".
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
IMAGE="vault-guard-tests:local"

if ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: docker not found in PATH. Tests require Docker." >&2
    exit 2
fi

docker build --quiet -t "${IMAGE}" "${SCRIPT_DIR}" >/dev/null

target="${1:-tests/}"

exec docker run --rm \
    --volume "${REPO_ROOT}:/code:ro" \
    --workdir /code \
    --user "$(id -u):$(id -g)" \
    --tmpfs /tmp:exec \
    --env HOME=/tmp/home \
    "${IMAGE}" \
    --recursive "${target}"
