#!/usr/bin/env bash
# S2 SC-4 — recycling-api's in-tree.sh lets a commit change an application package but not a tool,
# a rule extension or a package a tool requires; both runners refuse a vendor/ that differs from the
# tree's composer.lock; in-tree.sh refuses the working checkout.
# Exit 0 pass, 1 fail, 2 could not run. Cases: tests/unit/.
. "$(dirname "${BASH_SOURCE[0]}")/_qg-cases.sh"
qg_cases \
    qg-migration-recycling.bats \
    "lock check: vendor/ must match the lock exactly" \
    "lock check: an application package may change; a tool, its rule extension or anything a tool requires may not" \
    "lock check: a new application package passes, a new dev package is refused, at most 10 names print" \
    "in-tree.sh runs when the staged lock changes only an application package and vendor/ matches it" \
    "in-tree.sh refuses a staged tool change, a vendor/ that differs from the staged lock, and the checkout itself" \
    "in-server.sh refuses a merged compose file, a missing vendor/ or .env, and a vendor/ that differs from the lock"
