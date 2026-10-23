#!/usr/bin/env bash
# S2 SC-8 — recycling-api's in-server.sh pins the compose call, strips the caller's COMPOSE_* and
# DOCKER_* variables, runs past a local compose override, refuses a folder lacking vendor/ or .env,
# and measures a linked worktree itself.
# Exit 0 pass, 1 fail, 2 could not run. Cases: tests/unit/.
. "$(dirname "${BASH_SOURCE[0]}")/_qg-cases.sh"
qg_cases \
    qg-migration-recycling.bats \
    "in-server.sh pins the compose call and strips COMPOSE_*, DOCKER_HOST and DOCKER_CONTEXT" \
    "in-server.sh runs past a local compose override, which -f keeps out of the run" \
    "in-server.sh refuses a missing vendor/ or .env, and a vendor/ that differs from the lock" \
    "in-server.sh called on a linked worktree mounts that worktree, not the main checkout"
