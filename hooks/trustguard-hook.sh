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
SHA256_darwin_amd64="cebc52adfc7e151a130a0071b8765df402c0993f894423443f709adab89d927b"
SHA256_darwin_arm64="0f492345ffd58038b8fb87b79c3593fc7ad4ba57259a70578477e198549389f3"
SHA256_linux_amd64="b2fb370966513b75266997cc877071fe24545841601a875748fd517a9f92ed5a"
SHA256_linux_arm64="cae43cf97873e8cf852da4f8bd3dd341856cf5fd0761eed94d9294217cc3d8db"
SHA256_windows_amd64="c7bce7f45a925e7e53c429458bf4da192c9d9b3e7455fc54c63e2dbd3efd5367"
SHA256_windows_arm64="6fa991af0929ff52203836f6c42aa7465df9293acc5c48b6653985f3b5832762"

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
