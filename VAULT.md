---
type: vault-config
tags: [config]
---

# VAULT.md — per-repo vault configuration

## config
vault_path: ./vault
slug: vault-quality-gates

## structure
add_folders: [plans]

## behaviour
capture_indications: true

## definition of done
dod_profile: code
test_command: ./tests/run.sh tests/unit
lint_command: absent: no linter yet — the framework's bin/doc-lint.sh runs against this repo's markdown
delivery_command: absent: no delivery gate yet — added by the plan in vault/plans/

## hooks

## tools
