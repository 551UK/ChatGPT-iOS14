#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
REYNARD_VERSION="0.12.0"
TROLLSTORE_VERSION="2.1.1"
REYNARD_URL="https://github.com/minh-ton/reynard-browser/releases/download/${REYNARD_VERSION}/Reynard-Jailbroken.ipa"
TROLLSTORE_URL="https://github.com/opa334/TrollStore/releases/download/${TROLLSTORE_VERSION}/TrollStore.tar"

BUILD="$ROOT/build"
WORK="$BUILD/work"
PKG="$BUILD/pkg"
TOOLS="$PKG/usr/libexec/com.551.chatgpt14"
TWEAK_DIR="$PKG/Library/MobileSubstrate/DynamicLibraries"
DOC_DIR="$PKG/usr/share/doc/com.551.chatgpt14"

rm -rf "$BUILD"
mkdir -p "$WORK" "$PKG/DEBIAN" "$TOOLS" "$TWEAK_DIR" "$DOC_DIR"

# Reynard 0.12.0 is the Gecko browser engine/shell. On jailbroken iOS 14 the
# upstream-supported install path is TrollStore rather than copying the .app into
# /Applications. Previous builds copied it there, which is why iOS never registered
# a Home Screen icon. This build installs it through TrollStore's root installer,
# but bundles that installer privately so the user does not need a separate app.
curl -L --fail --retry 3 --retry-delay 2 "$REYNARD_URL" -o "$WORK/Reynard-Jailbroken.ipa"
mkdir -p "$WORK/reynard-unpacked"
unzip -q "$WORK/Reynard-Jailbroken.ipa" -d "$WORK/reynard-unpacked"
REYNARD_APP="$(find "$WORK/reynard-unpacked/Payload" -maxdepth 1 -type d -name '*.app' | head -1)"
if [ -z "$REYNARD_APP" ] || [ ! -d "$REYNARD_APP" ]; then
    echo "Could not find Reynard.app in the upstream IPA" >&2
    exit 1
fi

# Keep Reynard's bundle identifier and extension identifiers intact because Gecko's
# multiprocess setup expects them. Rebrand only what the user sees. TrollStore will
# re-sign the modified bundle during installation.
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName ChatGPT" "$REYNARD_APP/Info.plist" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string ChatGPT" "$REYNARD_APP/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName ChatGPT" "$REYNARD_APP/Info.plist" 2>/dev/null || true
python3 "$ROOT/scripts/make_icon.py" "$REYNARD_APP"

CHATGPT_IPA="$TOOLS/ChatGPT-Gecko.ipa"
(
    cd "$WORK/reynard-unpacked"
    zip -qry "$CHATGPT_IPA" Payload
)

# Bundle TrollStore's root installer privately. It is not placed in /Applications,
# so it does not create a TrollStore icon or install the TrollStore UI. The helper is
# used only to register/install our bundled Gecko app correctly on iOS 14.
curl -L --fail --retry 3 --retry-delay 2 "$TROLLSTORE_URL" -o "$WORK/TrollStore.tar"
mkdir -p "$WORK/trollstore"
tar -xzf "$WORK/TrollStore.tar" -C "$WORK/trollstore"
TS_APP="$(find "$WORK/trollstore" -maxdepth 2 -type d -name 'TrollStore.app' | head -1)"
if [ -z "$TS_APP" ] || [ ! -x "$TS_APP/trollstorehelper" ]; then
    echo "Could not find TrollStore root helper" >&2
    exit 1
fi
ditto "$TS_APP" "$TOOLS/TrollStore.app"
chmod 0755 "$TOOLS/TrollStore.app/trollstorehelper"

# Tiny bootstrap injected only into the installed Reynard/ChatGPT process. It sets
# chatgpt.com as the first/new tab before the browser creates its first Gecko tab.
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
CLANG="$(xcrun --sdk iphoneos --find clang)"
"$CLANG" \
    -arch arm64 \
    -isysroot "$SDK" \
    -miphoneos-version-min=14.0 \
    -fobjc-arc -fblocks -O2 -dynamiclib \
    -framework Foundation -framework UIKit \
    "$ROOT/Tweak/ChatGPTGeckoBootstrap.m" \
    -o "$TWEAK_DIR/ChatGPTGeckoBootstrap.dylib"
cp "$ROOT/Tweak/ChatGPTGeckoBootstrap.plist" "$TWEAK_DIR/ChatGPTGeckoBootstrap.plist"
chmod 0755 "$TWEAK_DIR/ChatGPTGeckoBootstrap.dylib"
if command -v ldid >/dev/null 2>&1; then
    ldid -S "$TWEAK_DIR/ChatGPTGeckoBootstrap.dylib"
fi

# License/source notices for both bundled open-source projects.
curl -L --fail --retry 3 \
    "https://raw.githubusercontent.com/minh-ton/reynard-browser/${REYNARD_VERSION}/LICENSE" \
    -o "$DOC_DIR/REYNARD-LICENSE.txt"
curl -L --fail --retry 3 \
    "https://raw.githubusercontent.com/opa334/TrollStore/${TROLLSTORE_VERSION}/LICENSE" \
    -o "$DOC_DIR/TROLLSTORE-LICENSE.txt"
cat > "$DOC_DIR/SOURCES.txt" <<SOURCE
Reynard Browser ${REYNARD_VERSION}: https://github.com/minh-ton/reynard-browser/tree/${REYNARD_VERSION}
TrollStore ${TROLLSTORE_VERSION}: https://github.com/opa334/TrollStore/tree/${TROLLSTORE_VERSION}
ChatGPT iOS 14 bootstrap/package: https://github.com/551UK/ChatGPT-iOS14
SOURCE

cat > "$PKG/DEBIAN/control" <<CONTROL
Package: com.551.chatgpt14
Name: ChatGPT iOS 14
Version: $VERSION
Architecture: iphoneos-arm
Description: Self-contained Gecko-powered ChatGPT client for rootful iOS 14. Installs and registers its bundled Gecko app automatically; no separate Reynard app or OpenAI API key is required.
Maintainer: 551UK
Author: 551UK
Section: Applications
Depends: firmware (>= 14.0)
CONTROL

cat > "$PKG/DEBIAN/postinst" <<'POST'
#!/bin/sh
set -u
TOOLROOT="/usr/libexec/com.551.chatgpt14"
HELPER="$TOOLROOT/TrollStore.app/trollstorehelper"
IPA="$TOOLROOT/ChatGPT-Gecko.ipa"
LOG="/var/mobile/ChatGPT-iOS14-install.log"
BUNDLE_ID="com.minh-ton.Reynard"

{
    echo "=== ChatGPT iOS 14 install ==="
    date
    echo "Removing stale system-app copies from older builds..."
    rm -rf /Applications/Reynard.app /Applications/ChatGPT.app 2>/dev/null || true

    if [ ! -x "$HELPER" ]; then
        echo "ERROR: bundled TrollStore root helper is missing"
        exit 90
    fi
    if [ ! -f "$IPA" ]; then
        echo "ERROR: bundled ChatGPT Gecko IPA is missing"
        exit 91
    fi

    # Remove an earlier copy registered by a previous attempt, then install the
    # modified Reynard IPA as a real user/System registration through TrollStore.
    "$HELPER" uninstall custom "$BUNDLE_ID" >/dev/null 2>&1 || true
    echo "Installing bundled Gecko app through TrollStore root helper..."
    "$HELPER" install custom force "$IPA"
    RET=$?
    echo "Installer returned: $RET"

    if [ "$RET" -ne 0 ]; then
        echo "ERROR: Gecko app installation failed with code $RET"
        exit "$RET"
    fi

    killall cfprefsd >/dev/null 2>&1 || true
    if command -v uicache >/dev/null 2>&1; then
        uicache -a >/dev/null 2>&1 || true
    fi
    echo "Install completed successfully."
} >"$LOG" 2>&1
RET=$?
chown mobile:mobile "$LOG" >/dev/null 2>&1 || true
chmod 0644 "$LOG" >/dev/null 2>&1 || true
exit "$RET"
POST

cat > "$PKG/DEBIAN/prerm" <<'PRE'
#!/bin/sh
TOOLROOT="/usr/libexec/com.551.chatgpt14"
HELPER="$TOOLROOT/TrollStore.app/trollstorehelper"
if [ -x "$HELPER" ]; then
    "$HELPER" uninstall custom com.minh-ton.Reynard >/dev/null 2>&1 || true
fi
killall Reynard >/dev/null 2>&1 || true
exit 0
PRE

cat > "$PKG/DEBIAN/postrm" <<'POSTRM'
#!/bin/sh
rm -rf /Applications/Reynard.app /Applications/ChatGPT.app >/dev/null 2>&1 || true
if command -v uicache >/dev/null 2>&1; then
    uicache -a >/dev/null 2>&1 || true
fi
exit 0
POSTRM

chmod 0755 "$PKG/DEBIAN/postinst" "$PKG/DEBIAN/prerm" "$PKG/DEBIAN/postrm"

DEB="$BUILD/com.551.chatgpt14_${VERSION}_iphoneos-arm.deb"
dpkg-deb --root-owner-group -Zxz --build "$PKG" "$DEB"
echo "$DEB"
