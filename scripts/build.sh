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

# Use Reynard only as the Gecko runtime underneath our ChatGPT UI. The visible
# browser chrome is hidden at runtime by ChatGPTShell.dylib.
curl -L --fail --retry 3 --retry-delay 2 "$REYNARD_URL" -o "$WORK/Reynard-Jailbroken.ipa"
mkdir -p "$WORK/reynard-unpacked"
unzip -q "$WORK/Reynard-Jailbroken.ipa" -d "$WORK/reynard-unpacked"
REYNARD_APP="$(find "$WORK/reynard-unpacked/Payload" -maxdepth 1 -type d -name '*.app' | head -1)"
if [ -z "$REYNARD_APP" ] || [ ! -d "$REYNARD_APP" ]; then
    echo "Could not find the Gecko host app" >&2
    exit 1
fi

# Give the ChatGPT client its own identity so a normal Reynard installation can
# remain installed and untouched.
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $APP_BUNDLE_ID" "$REYNARD_APP/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName ChatGPT" "$REYNARD_APP/Info.plist" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string ChatGPT" "$REYNARD_APP/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName ChatGPT" "$REYNARD_APP/Info.plist" 2>/dev/null || true

# Web Voice and the optional native section can use microphone access.
set_plist_string() {
    local key="$1"
    local value="$2"
    /usr/libexec/PlistBuddy -c "Set :$key $value" "$REYNARD_APP/Info.plist" 2>/dev/null || \
        /usr/libexec/PlistBuddy -c "Add :$key string $value" "$REYNARD_APP/Info.plist"
}
set_plist_string NSCameraUsageDescription "Attach a photo to Native Chat."
set_plist_string NSPhotoLibraryUsageDescription "Choose a photo for Native Chat."
set_plist_string NSMicrophoneUsageDescription "Use your microphone for ChatGPT Voice and voice input."
set_plist_string NSSpeechRecognitionUsageDescription "Turn speech into text in Native Chat."

# Do not claim Reynard's URL schemes. The ChatGPT shell does not need them.
/usr/libexec/PlistBuddy -c "Delete :CFBundleURLTypes" "$REYNARD_APP/Info.plist" 2>/dev/null || true
rm -rf "$REYNARD_APP/PlugIns/OpenIn.appex" 2>/dev/null || true

HELPER_APPEX="$REYNARD_APP/PlugIns/Reynard Helper.appex"
if [ ! -d "$HELPER_APPEX" ]; then
    echo "Could not find Gecko helper extension" >&2
    exit 1
fi
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $HELPER_BUNDLE_ID" "$HELPER_APPEX/Info.plist"

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

# Install a dedicated ChatGPT-style icon. iOS 14 can otherwise keep taking the
# upstream asset-catalog icon through CFBundleIconName.
python3 "$ROOT/scripts/make_icon.py" "$REYNARD_APP"
/usr/libexec/PlistBuddy -c "Delete :CFBundleIcons:CFBundlePrimaryIcon:CFBundleIconName" "$REYNARD_APP/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Delete :CFBundleIcons~ipad:CFBundlePrimaryIcon:CFBundleIconName" "$REYNARD_APP/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Delete :CFBundleIconFiles" "$REYNARD_APP/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :CFBundleIconFiles array" "$REYNARD_APP/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleIconFiles:0 string AppIcon60x60" "$REYNARD_APP/Info.plist"
/usr/libexec/PlistBuddy -c "Delete :CFBundleIcons:CFBundlePrimaryIcon:CFBundleIconFiles" "$REYNARD_APP/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :CFBundleIcons:CFBundlePrimaryIcon:CFBundleIconFiles array" "$REYNARD_APP/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :CFBundleIcons:CFBundlePrimaryIcon:CFBundleIconFiles:0 string AppIcon60x60" "$REYNARD_APP/Info.plist" 2>/dev/null || true

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

# Bundle only the root installer helper needed to register the contained app.
curl -L --fail --retry 3 --retry-delay 2 "$TROLLSTORE_URL" -o "$WORK/TrollStore.tar"
mkdir -p "$WORK/trollstore"
tar -xzf "$WORK/TrollStore.tar" -C "$WORK/trollstore"
TS_APP="$(find "$WORK/trollstore" -maxdepth 2 -type d -name 'TrollStore.app' | head -1)"
if [ -z "$TS_APP" ] || [ ! -x "$TS_APP/trollstorehelper" ]; then
    echo "Could not find app registration helper" >&2
    exit 1
fi
ditto "$TS_APP" "$TOOLS/TrollStore.app"
chmod 0755 "$TOOLS/TrollStore.app/trollstorehelper"

# Build the ChatGPT shell. The old v1 ChatGPT UI is linked back in only for the
# selectable Native Chat section. The default Web section is the real chatgpt.com
# page rendered by Gecko; browser chrome, address bars and tab UI are hidden.
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
CLANG="$(xcrun --sdk iphoneos --find clang)"
"$CLANG" \
    -arch arm64 \
    -isysroot "$SDK" \
    -miphoneos-version-min=14.0 \
    -fobjc-arc -fblocks -O2 -dynamiclib \
    -Wno-deprecated-declarations \
    -framework Foundation \
    -framework UIKit \
    -framework CoreGraphics \
    -framework QuartzCore \
    -framework Security \
    -framework Speech \
    -framework AVFoundation \
    -framework WebKit \
    -lsqlite3 \
    "$ROOT/Tweak/ChatGPTGeckoBootstrap.m" \
    "$ROOT/Tweak/NativeChatSupport.m" \
    "$ROOT/Tweak/ChatGPTShellCore.m" \
    "$ROOT/Tweak/ChatGPTShellMenu.m" \
    "$ROOT/Tweak/ChatGPTWebHistory.m" \
    "$ROOT/Tweak/ChatGPTSettingsPatch.m" \
    -o "$TWEAK_DIR/ChatGPTShell.dylib"
cp "$ROOT/Tweak/ChatGPTGeckoBootstrap.plist" "$TWEAK_DIR/ChatGPTShell.plist"
chmod 0755 "$TWEAK_DIR/ChatGPTShell.dylib"
if command -v ldid >/dev/null 2>&1; then
    ldid -S "$TWEAK_DIR/ChatGPTShell.dylib"
fi

curl -L --fail --retry 3 \
    "https://raw.githubusercontent.com/minh-ton/reynard-browser/${REYNARD_VERSION}/LICENSE" \
    -o "$DOC_DIR/REYNARD-LICENSE.txt"
curl -L --fail --retry 3 \
    "https://raw.githubusercontent.com/opa334/TrollStore/${TROLLSTORE_VERSION}/LICENSE" \
    -o "$DOC_DIR/TROLLSTORE-LICENSE.txt"
cat > "$DOC_DIR/SOURCES.txt" <<SOURCE
Gecko runtime derived from Reynard Browser ${REYNARD_VERSION}: https://github.com/minh-ton/reynard-browser/tree/${REYNARD_VERSION}
Registration helper from TrollStore ${TROLLSTORE_VERSION}: https://github.com/opa334/TrollStore/tree/${TROLLSTORE_VERSION}
ChatGPT shell/native UI source: https://github.com/551UK/ChatGPT-iOS14
SOURCE

cat > "$PKG/DEBIAN/control" <<CONTROL
Package: com.551.chatgpt14
Name: ChatGPT iOS 14
Version: $VERSION
Architecture: iphoneos-arm
Description: ChatGPT for jailbroken iOS 14, powered by bundled Gecko.
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
    rm -rf /Applications/ChatGPT.app >/dev/null 2>&1 || true

    if [ ! -x "$HELPER" ]; then
        echo "ERROR: bundled registration helper is missing"
        exit 90
    fi
    if [ ! -f "$IPA" ]; then
        echo "ERROR: bundled ChatGPT app is missing"
        exit 91
    fi

    "$HELPER" uninstall custom "$BUNDLE_ID" >/dev/null 2>&1 || true
    echo "Installing ChatGPT app with bundled Gecko engine..."
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
    echo "Install completed successfully. Existing Reynard installation was left untouched."
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
