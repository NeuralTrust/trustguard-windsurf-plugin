#!/bin/sh
set -eu

ROOT=$(cd -- "$(dirname "$0")/.." && pwd)
HOOK="$ROOT/hooks/trustguard-hook.sh"
POWERSHELL_HOOK="$ROOT/hooks/trustguard-hook.ps1"
FIXTURE="$ROOT/tests/fixtures/fake-trustguard-windsurf.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/trustguard-bootstrap.XXXXXX")
BIN_DIR="$TEST_ROOT/bin"
PAYLOAD='{"agent_action_name":"pre_run_command","tool_info":{"command_line":"ls"}}'

cleanup() {
    rm -rf "$TEST_ROOT"
}
trap cleanup EXIT HUP INT TERM

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

VERSION=$(sed -n 's/^VERSION="\([^"]*\)"/\1/p' "$HOOK")
[ -n "$VERSION" ] || fail 'bootstrap VERSION is missing'

run_case() {
    binary_name=$1
    mkdir -p "$BIN_DIR"
    cp "$FIXTURE" "$BIN_DIR/$binary_name"
    chmod 0755 "$BIN_DIR/$binary_name"

    actual=$(
        printf '%s\n' "$PAYLOAD" |
            env PATH=/usr/bin:/bin TRUSTGUARD_WINDSURF_BIN_DIR="$BIN_DIR" sh "$HOOK"
    )
    expected=$(printf 'binary=%s\nargs=hook\nstdin=%s' "$binary_name" "$PAYLOAD")

    [ "$actual" = "$expected" ] || fail "$binary_name was not executed with the hook payload"
    rm -f "$BIN_DIR/$binary_name"
}

run_case trustguard-windsurf
run_case "trustguard-windsurf-$VERSION"

if command -v pwsh >/dev/null 2>&1; then
    powershell=$(command -v pwsh)
    cp "$FIXTURE" "$BIN_DIR/trustguard-windsurf.exe"
    chmod 0755 "$BIN_DIR/trustguard-windsurf.exe"

    actual=$(
        printf '%s\n' "$PAYLOAD" |
            env PATH=/usr/bin:/bin TRUSTGUARD_WINDSURF_BIN_DIR="$BIN_DIR" \
                "$powershell" -NoProfile -File "$POWERSHELL_HOOK"
    )
    expected=$(printf 'binary=trustguard-windsurf.exe\nargs=hook\nstdin=%s' "$PAYLOAD")

    [ "$actual" = "$expected" ] || fail 'trustguard-windsurf.exe was not executed with the hook payload'
fi

# Nothing installed and no pinned checksum: the bootstrap must allow (exit 0)
# with empty stdout, so Cascade shows nothing and the action proceeds.
EMPTY_BIN="$TEST_ROOT/empty-bin"
mkdir -p "$EMPTY_BIN"
set +e
actual=$(printf '%s\n' "$PAYLOAD" | env PATH=/usr/bin:/bin TRUSTGUARD_WINDSURF_BIN_DIR="$EMPTY_BIN" sh "$HOOK" 2>/dev/null)
status=$?
set -e
[ "$status" -eq 0 ] || fail "bootstrap without a binary must exit 0, got $status"
[ -z "$actual" ] || fail "bootstrap without a binary must print nothing, got: $actual"

# The binary's exit code is the verdict: a block (2) must reach Cascade.
cat > "$BIN_DIR/trustguard-windsurf" <<'SH'
#!/bin/sh
cat >/dev/null
echo "blocked" >&2
exit 2
SH
chmod 0755 "$BIN_DIR/trustguard-windsurf"
set +e
printf '%s\n' "$PAYLOAD" | env PATH=/usr/bin:/bin TRUSTGUARD_WINDSURF_BIN_DIR="$BIN_DIR" sh "$HOOK" 2>/dev/null
status=$?
set -e
[ "$status" -eq 2 ] || fail "a blocking exit code must propagate, got $status"

printf 'bootstrap hook tests passed\n'
