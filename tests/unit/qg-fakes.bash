# Shared by the driver bats files whose fake tools read FAKE_* and other test variables. Loaded with
# `load qg-fakes`; bats runs only *.bats, so this file is never run on its own.
#
# qg_sandbox_run starts every tool from an empty environment, so a fake cannot read the test's
# variables from its own. Instead:
#   fakes_setup         after WORK and DRIVER are set: DRIVER becomes $WORK/driver, a wrapper that
#                       writes the caller's exported variables to $WORK/fake.env, sets QG_SANDBOX=0
#                       unless the caller set it, and runs the real driver. Unsandboxed, the fakes
#                       can also record into $WORK.
#   fake_bake <file>    makes the fake script <file> read $WORK/fake.env first; call it after
#                       writing the fake. The path is baked into the fake.
#   fake_env_save       writes $WORK/fake.env from the current shell, for a run that does not go
#                       through $DRIVER, such as bin/guard.sh.

# The names the sandbox child sets itself, or that belong to bash and bats, are never carried over.
FAKE_ENV_SKIP='^declare -x (PATH|HOME|PWD|OLDPWD|SHLVL|_|TMPDIR|LANG|LC_ALL|QG_[A-Za-z0-9_]*|BATS_[A-Za-z0-9_]*|BASH[A-Za-z0-9_]*)(=|$)'

fake_env_save() { export -p | grep -vE "$FAKE_ENV_SKIP" > "$WORK/fake.env"; }

fakes_setup() {
    { printf '#!/usr/bin/env bash\n'
      printf 'export -p | grep -vE %q > %q\n' "$FAKE_ENV_SKIP" "$WORK/fake.env"
      printf 'export QG_SANDBOX="${QG_SANDBOX-0}"\n'
      printf 'exec %q "$@"\n' "$DRIVER"
    } > "$WORK/driver"
    chmod +x "$WORK/driver"
    DRIVER="$WORK/driver"
}

fake_bake() {
    sed -i "1a [ ! -r $(printf '%q' "$WORK/fake.env") ] || . $(printf '%q' "$WORK/fake.env")" "$1"
}
