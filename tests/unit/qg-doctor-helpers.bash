# Shared by suites that need `qg doctor` to pass: a plugin copy with its own git dir, a tool-path
# file, a temporary HOME holding the three user-level guard entries, and installed git hooks.

# healthy_setup — a setup `qg doctor` passes: a git-tracked copy of the plugin, so it has its own
# machine tool-path file, a HOME whose settings hold the three guard entries, and git hooks
# installed in the current repo. Sets PLUGIN and QG.
healthy_setup() {
    PLUGIN="$WORK/plugin"
    mkdir -p "$PLUGIN" "$WORK/tools" "$WORK/home/.claude"
    cp -a /code/bin /code/lib /code/templates /code/drivers /code/extend "$PLUGIN/"
    git -C "$PLUGIN" init -q
    printf '%s\n' "$WORK/tools" > "$PLUGIN/.git/qg-tool-path"
    export HOME="$WORK/home"
    user_settings "$HOME/.claude"
    ( export GUARD_LIB_DIR="$PLUGIN/lib"; . "$PLUGIN/lib/guard-metrics.sh"; . "$PLUGIN/lib/guard-install.sh"; guard_hooks_install >/dev/null )
    QG="$PLUGIN/bin/qg"
}

# user_settings <claude config dir> [<guard name> to leave out] — its settings.json with a foreign
# entry and the three guard entries, less the one named.
user_settings() {
    mkdir -p "$1"
    jq -n --arg p "$PLUGIN/templates/claude-hooks" --arg skip "${2:-}" '
        def e($m; $n): select($n != $skip) | {matcher: $m, hooks: [{type: "command", command: "\($p)/\($n)"}]};
        {hooks: {PreToolUse: [{matcher: "Read", hooks: [{type: "command", command: "/usr/bin/true"}]},
                              e("Bash"; "guard-bash.sh"), e("Edit|Write"; "guard-edit.sh")],
                 Stop: [e(null; "guard-stop.sh")]}}' > "$1/settings.json"
}
