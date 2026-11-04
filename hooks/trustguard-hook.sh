#!/bin/sh
# Bootstrap for the TrustGuard Windsurf hooks (macOS/Linux).
#
# Cascade runs this script through bash on each hook event. It executes trustguard-windsurf
# from the PATH when present (manual/MDM installs win); otherwise it installs
# the pinned release for this OS/arch into ~/.trustguard/bin in the background,
# verifying its SHA-256 against the table below, and evaluates from the next
# event on. Every bootstrap failure fails open (Cascade must never brick) with a
# warning on stderr: exit 0 with no output lets the action proceed.
#
# The VERSION and SHA256_* table are updated per release.
set -u

VERSION="0.1.2"
BASE_URL="${TRUSTGUARD_WINDSURF_DOWNLOAD_BASE:-https://github.com/NeuralTrust/trustguard-windsurf-plugin/releases/download}"
BIN_DIR="${TRUSTGUARD_WINDSURF_BIN_DIR:-$HOME/.trustguard/bin}"

# Per-platform SHA-256 of the release binaries (filled per release).
SHA256_darwin_amd64="ea73a72363a5644c85620452bf2f17b0ee889ca466f73e3194e32fa8aebbaa05"
SHA256_darwin_arm64="2a23b154f9f35810da7e8172cfd43f8f71315391d1887362d26f01f7eccc3577"
SHA256_linux_amd64="b2f89355a523634d7564b71fb62f23bd404cbc23dadc1b14c180662cc293c633"
SHA256_linux_arm64="faa53f20a2dfe63abe74ce177133c4a2e5e75dd8abaeeaf3082939c4d381385f"
SHA256_windows_amd64="5f58bca69e613f6dddb1fe99d1f0e09d809bf928b5ffc4f457568615f2df7bbf"
SHA256_windows_arm64="ef78632621a728f3ed63837494f53338f1614c40ab6752cce013944147f80a84"

fail_open() {
    echo "trustguard-windsurf bootstrap: $1 — allowing without evaluation" >&2
    # Exit 0 is allow in the Cascade contract; stdout stays empty so nothing
    # is shown in the Cascade panel.
    exit 0
}

if command -v trustguard-windsurf >/dev/null 2>&1; then
    exec trustguard-windsurf hook
fi

EXT=""
case "$(uname -s)" in
    Darwin) OS="darwin" ;;
    Linux) OS="linux" ;;
    MINGW* | MSYS* | CYGWIN*) OS="windows" EXT=".exe" ;;
    *) OS="" ;;
esac

# Local and MDM installs use the stable, unversioned filename.
LOCAL_BIN="$BIN_DIR/trustguard-windsurf$EXT"
if [ -x "$LOCAL_BIN" ]; then
    exec "$LOCAL_BIN" hook
fi

BIN="$BIN_DIR/trustguard-windsurf-$VERSION$EXT"
if [ -x "$BIN" ]; then
    exec "$BIN" hook
fi

if [ -z "$OS" ]; then
    fail_open "unsupported OS $(uname -s); install trustguard-windsurf manually"
fi
case "$(uname -m)" in
    x86_64 | amd64) ARCH="amd64" ;;
    arm64 | aarch64) ARCH="arm64" ;;
    *) fail_open "unsupported arch $(uname -m); install trustguard-windsurf manually" ;;
esac

WANT_SHA=$(eval "printf '%s' \"\${SHA256_${OS}_${ARCH}:-}\"")
if [ -z "$WANT_SHA" ]; then
    fail_open "no pinned checksum for ${OS}/${ARCH} (release ${VERSION} not published yet?); install trustguard-windsurf manually"
fi

URL="$BASE_URL/v$VERSION/trustguard-windsurf_${VERSION}_${OS}_${ARCH}${EXT}"
mkdir -p "$BIN_DIR" 2>/dev/null || fail_open "cannot create $BIN_DIR"

install_binary() {
    TMP="$BIN.download.$$"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout 5 --max-time 300 -o "$TMP" "$URL" || { rm -f "$TMP"; return 1; }
    elif command -v wget >/dev/null 2>&1; then
        wget -q -T 300 -O "$TMP" "$URL" || { rm -f "$TMP"; return 1; }
    else
        return 1
    fi

    if command -v sha256sum >/dev/null 2>&1; then
        GOT_SHA=$(sha256sum "$TMP" | cut -d' ' -f1)
    elif command -v shasum >/dev/null 2>&1; then
        GOT_SHA=$(shasum -a 256 "$TMP" | cut -d' ' -f1)
    else
        rm -f "$TMP"
        return 1
    fi
    if [ "$GOT_SHA" != "$WANT_SHA" ]; then
        rm -f "$TMP"
        return 1
    fi

    chmod 0755 "$TMP" || { rm -f "$TMP"; return 1; }
    mv -f "$TMP" "$BIN" || { rm -f "$TMP"; return 1; }
}

LOCK="$BIN_DIR/install-windsurf-$VERSION.lock"
if [ -d "$LOCK" ] && [ -n "$(find "$LOCK" -maxdepth 0 -mmin +10 2>/dev/null)" ]; then
    rmdir "$LOCK" 2>/dev/null || :
fi
if mkdir "$LOCK" 2>/dev/null; then
    ( install_binary; rmdir "$LOCK" 2>/dev/null ) >/dev/null 2>&1 &
fi
fail_open "trustguard-windsurf $VERSION not installed yet; fetching it in the background"
