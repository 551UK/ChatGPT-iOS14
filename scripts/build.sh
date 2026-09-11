#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
REYNARD_VERSION="0.12.0"
TROLLSTORE_VERSION="2.1.1"
REYNARD_URL="https://github.com/minh-ton/reynard-browser/releases/download/${REYNARD_VERSION}/Reynard-Jailbroken.ipa"
TROLLSTORE_URL="https://github.com/opa334/TrollStore/releases/download/${TROLLSTORE_VERSION}/TrollStore.tar"

APP_BUNDLE_ID="com.551.chatgpt14"
HELPER_BUNDLE_ID="com.551.chatgpt14.Helper"

BUILD="$ROOT/build"
WORK="$BUILD/work"
PKG="$BUILD/pkg"
TOOLS="$PKG/usr/libexec/com.551.chatgpt14"
TWEAK_DIR="$PKG/Library/MobileSubstrate/DynamicLibraries"
DOC_DIR="$PKG/usr/share/doc/com.551.chatgpt14"

rm -rf "$BUILD"
mkdir -p "$WORK" "$PKG/DEBIAN" "$TOOLS" "$TWEAK_DIR" "$DOC_DIR"

curl -L --fail --retry 3 --retry-delay 2 "$REYNARD_URL" -o "$WORK/Reynard-Jailbroken.ipa"
mkdir -p "$WORK/reynard-unpacked"
unzip -q "$WORK/Reynard-Jailbroken.ipa" -d "$WORK/reynard-unpacked"
REYNARD_APP="$(find "$WORK/reynard-unpacked/Payload" -maxdepth 1 -type d -name '*.app' | head -1)"
if [ -z "$REYNARD_APP" ] || [ ! -d "$REYNARD_APP" ]; then
    echo "Could not find Reynard.app in the upstream IPA" >&2
    exit 1
fi

# Make the bundled Gecko client a genuinely separate app from a normal Reynard
# installation. This avoids LaunchServices treating them as the same application.
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $APP_BUNDLE_ID" "$REYNARD_APP/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName ChatGPT" "$REYNARD_APP/Info.plist" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string ChatGPT" "$REYNARD_APP/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName ChatGPT" "$REYNARD_APP/Info.plist" 2>/dev/null || true

# Do not claim Reynard's URL schemes. The ChatGPT wrapper does not need them and
# leaving them in would create a second collision with the user's Reynard install.
/usr/libexec/PlistBuddy -c "Delete :CFBundleURLTypes" "$REYNARD_APP/Info.plist" 2>/dev/null || true

# The Open In share extension depends on Reynard's custom URL scheme. It is not
# needed for this single-site ChatGPT client, so remove it instead of letting it
# compete with the real Reynard app.
rm -rf "$REYNARD_APP/PlugIns/OpenIn.appex" 2>/dev/null || true

HELPER_APPEX="$REYNARD_APP/PlugIns/Reynard Helper.appex"
if [ ! -d "$HELPER_APPEX" ]; then
    echo "Could not find Reynard Gecko helper extension" >&2
    exit 1
fi
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $HELPER_BUNDLE_ID" "$HELPER_APPEX/Info.plist"

# Update the application-identifier entitlements to match the new bundle IDs before
# TrollStore signs the IPA. This keeps Gecko's main process and helper process valid
# while allowing the original Reynard bundle to remain installed alongside ChatGPT.
resign_bundle() {
    local bundle="$1"
    local app_id="$2"
    local executable
    local binary
    local entitlements

    executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$bundle/Info.plist")"
    binary="$bundle/$executable"
    if [ ! -f "$binary" ]; then
        echo "Missing executable in $bundle" >&2
        exit 1
    fi

    rm -rf "$bundle/_CodeSignature" 2>/dev/null || true
    rm -f "$bundle/embedded.mobileprovision" 2>/dev/null || true

    if command -v ldid >/dev/null 2>&1; then
        entitlements="$WORK/$(basename "$bundle" | tr ' /' '__').entitlements.plist"
        ldid -e "$binary" > "$entitlements" 2>/dev/null || true
        if grep -q '<plist' "$entitlements" 2>/dev/null; then
            /usr/libexec/PlistBuddy -c "Set :application-identifier $app_id" "$entitlements" 2>/dev/null || \
                /usr/libexec/PlistBuddy -c "Add :application-identifier string $app_id" "$entitlements"
            ldid -S"$entitlements" "$binary"
        else
            ldid -S "$binary"
        fi
    fi
}

resign_bundle "$HELPER_APPEX" "$HELPER_BUNDLE_ID"
resign_bundle "$REYNARD_APP" "$APP_BUNDLE_ID"
python3 "$ROOT/scripts/make_icon.py" "$REYNARD_APP"

# Rename the payload folder too. The executable can remain named Reynard internally;
# the bundle and Home Screen identity are ChatGPT.
CHATGPT_APP="$WORK/reynard-unpacked/Payload/ChatGPT.app"
if [ "$REYNARD_APP" != "$CHATGPT_APP" ]; then
    rm -rf "$CHATGPT_APP"
    mv "$REYNARD_APP" "$CHATGPT_APP"
fi

CHATGPT_IPA="$TOOLS/ChatGPT-Gecko.ipa"
(
    cd "$WORK/reynard-unpacked"
    zip -qry "$CHATGPT_IPA" Payload
)

# Bundle TrollStore's root installer privately. It is used only to install/register
# the embedded IPA correctly; no separate TrollStore or Reynard app is required.
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

# Bootstrap only our ChatGPT bundle. The user's normal Reynard process is no longer
# touched by this tweak.
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
Description: Self-contained Gecko-powered ChatGPT client for rootful iOS 14. Uses its own app identity, so ChatGPT and Reynard can be installed together. No OpenAI API key is required.
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
BUNDLE_ID="com.551.chatgpt14"

{
    echo "=== ChatGPT iOS 14 install ==="
    date

    # Clean only obsolete ChatGPT system-app copies. Never remove Reynard: it is a
    # separate application and may already be installed by the user.
    rm -rf /Applications/ChatGPT.app >/dev/null 2>&1 || true

    if [ ! -x "$HELPER" ]; then
        echo "ERROR: bundled installer helper is missing"
        exit 90
    fi
    if [ ! -f "$IPA" ]; then
        echo "ERROR: bundled ChatGPT Gecko IPA is missing"
        exit 91
    fi

    "$HELPER" uninstall custom "$BUNDLE_ID" >/dev/null 2>&1 || true
    echo "Installing separate ChatGPT Gecko app..."
    "$HELPER" install custom force "$IPA"
    RET=$?
    echo "Installer returned: $RET"

    if [ "$RET" -ne 0 ]; then
        echo "ERROR: ChatGPT app installation failed with code $RET"
        exit "$RET"
    fi

    killall cfprefsd >/dev/null 2>&1 || true
    if command -v uicache >/dev/null 2>&1; then
        uicache -a >/dev/null 2>&1 || true
    fi
    echo "Install completed successfully. Reynard was left untouched."
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
    "$HELPER" uninstall custom com.551.chatgpt14 >/dev/null 2>&1 || true
fi
exit 0
PRE

cat > "$PKG/DEBIAN/postrm" <<'POSTRM'
#!/bin/sh
rm -rf /Applications/ChatGPT.app >/dev/null 2>&1 || true
if command -v uicache >/dev/null 2>&1; then
    uicache -a >/dev/null 2>&1 || true
fi
exit 0
POSTRM

chmod 0755 "$PKG/DEBIAN/postinst" "$PKG/DEBIAN/prerm" "$PKG/DEBIAN/postrm"

DEB="$BUILD/com.551.chatgpt14_${VERSION}_iphoneos-arm.deb"
dpkg-deb --root-owner-group -Zxz --build "$PKG" "$DEB"
echo "$DEB"
