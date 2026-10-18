#!/usr/bin/env bash
# S2 SC-8 — recycling-api's in-server.sh pins the compose call, strips the caller's COMPOSE_* and
# DOCKER_* variables, refuses a folder holding a compose file compose would merge or lacking
# vendor/ or .env, and measures a linked worktree itself.
# Exit 0 pass, 1 fail, 2 could not run. Cases: tests/unit/.
. "$(dirname "${BASH_SOURCE[0]}")/_qg-cases.sh"
qg_cases \
    qg-migration-recycling.bats \
    "in-server.sh pins the compose call and strips COMPOSE_*, DOCKER_HOST and DOCKER_CONTEXT" \
    "in-server.sh refuses a merged compose file, a missing vendor/ or .env, and a vendor/ that differs from the lock" \
    "in-server.sh called on a linked worktree mounts that worktree, not the main checkout"
