#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
REYNARD_VERSION="0.12.0"
REYNARD_URL="https://github.com/minh-ton/reynard-browser/releases/download/${REYNARD_VERSION}/Reynard-Jailbroken.ipa"

BUILD="$ROOT/build"
WORK="$BUILD/reynard"
PKG="$BUILD/pkg"
APP="$PKG/Applications/ChatGPT.app"
TWEAK_DIR="$PKG/Library/MobileSubstrate/DynamicLibraries"
PREF_DIR="$PKG/var/mobile/Library/Preferences"
DOC_DIR="$PKG/usr/share/doc/com.551.chatgpt14"

rm -rf "$BUILD"
mkdir -p "$WORK" "$PKG/Applications" "$PKG/DEBIAN" "$TWEAK_DIR" "$PREF_DIR" "$DOC_DIR"

printf 'Downloading Reynard %s jailbroken build...\n' "$REYNARD_VERSION"
curl -L --fail --retry 3 --retry-delay 2 "$REYNARD_URL" -o "$WORK/Reynard-Jailbroken.ipa"
unzip -q "$WORK/Reynard-Jailbroken.ipa" -d "$WORK/unpacked"

UPSTREAM_APP="$(find "$WORK/unpacked/Payload" -maxdepth 1 -type d -name '*.app' | head -1)"
if [ -z "$UPSTREAM_APP" ] || [ ! -d "$UPSTREAM_APP" ]; then
    echo "Could not find Reynard.app in upstream IPA" >&2
    exit 1
fi

ditto "$UPSTREAM_APP" "$APP"

# Keep Reynard's internal bundle identifiers and helper extension identifiers intact.
# They are part of how its Gecko multiprocess/JIT setup works. Only rebrand the app
# that appears on the Home Screen.
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName ChatGPT" "$APP/Info.plist" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string ChatGPT" "$APP/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName ChatGPT" "$APP/Info.plist" 2>/dev/null || true

MAIN_EXEC="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Info.plist")"
if [ -z "$MAIN_EXEC" ] || [ ! -f "$APP/$MAIN_EXEC" ]; then
    echo "Could not locate Reynard executable" >&2
    exit 1
fi

# Preserve the private entitlements from the official jailbroken build. They are
# required for Reynard's Gecko child processes and ptrace-based JIT on jailbroken iOS.
ENTITLEMENTS="$WORK/Reynard.entitlements.plist"
if command -v ldid >/dev/null 2>&1; then
    ldid -e "$APP/$MAIN_EXEC" > "$ENTITLEMENTS" 2>/dev/null || true
    rm -rf "$APP/_CodeSignature"
    if grep -q '<plist' "$ENTITLEMENTS" 2>/dev/null; then
        ldid -S"$ENTITLEMENTS" "$APP/$MAIN_EXEC"
    else
        ldid -S "$APP/$MAIN_EXEC"
    fi
fi

# Compile a tiny rootful injection helper. It runs inside this bundled Reynard app
# before the first tab is created and makes chatgpt.com the permanent new-tab target.
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

# Seed the same preferences as a fallback even on jailbreak setups whose injector
# is disabled for apps. The bootstrap dylib also reapplies them at launch.
cat > "$PREF_DIR/com.minh-ton.Reynard.plist" <<'PREFS'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>default.NewTabSettings.newTabDisplayOption</key>
    <string>customURL</string>
    <key>default.NewTabSettings.customNewTabURL</key>
    <string>https://chatgpt.com/</string>
    <key>default.HomepageSettings.showsRecommendations</key>
    <false/>
    <key>default.HomepageSettings.showsNewUpdates</key>
    <false/>
</dict>
</plist>
PREFS

# Reynard is GPLv3. Keep attribution/source information beside the installed package.
curl -L --fail --retry 3 \
    "https://raw.githubusercontent.com/minh-ton/reynard-browser/${REYNARD_VERSION}/LICENSE" \
    -o "$DOC_DIR/REYNARD-LICENSE.txt"
cat > "$DOC_DIR/REYNARD-SOURCE.txt" <<SOURCE
This package embeds the official Reynard Browser ${REYNARD_VERSION} jailbroken build as its Gecko engine/browser shell.
Upstream source: https://github.com/minh-ton/reynard-browser/tree/${REYNARD_VERSION}
Upstream release: https://github.com/minh-ton/reynard-browser/releases/tag/${REYNARD_VERSION}
The ChatGPT-specific bootstrap source is in https://github.com/551UK/ChatGPT-iOS14
SOURCE

cat > "$PKG/DEBIAN/control" <<CONTROL
Package: com.551.chatgpt14
Name: ChatGPT iOS 14
Version: $VERSION
Architecture: iphoneos-arm
Description: Self-contained Gecko-powered ChatGPT web client for rootful iOS 14. Bundles the browser engine inside the package, opens chatgpt.com by default and uses your normal ChatGPT account without an API key.
Maintainer: 551UK
Author: 551UK
Section: Applications
Depends: firmware (>= 14.0)
CONTROL

cat > "$PKG/DEBIAN/postinst" <<'POST'
#!/bin/sh
PREF="/var/mobile/Library/Preferences/com.minh-ton.Reynard.plist"
if [ -f "$PREF" ]; then
    chown mobile:mobile "$PREF" >/dev/null 2>&1 || true
    chmod 0600 "$PREF" >/dev/null 2>&1 || true
fi
killall cfprefsd >/dev/null 2>&1 || true
if command -v uicache >/dev/null 2>&1; then
    uicache -p /Applications/ChatGPT.app >/dev/null 2>&1 || true
fi
exit 0
POST

cat > "$PKG/DEBIAN/prerm" <<'PRE'
#!/bin/sh
killall Reynard >/dev/null 2>&1 || true
exit 0
PRE

cat > "$PKG/DEBIAN/postrm" <<'POSTRM'
#!/bin/sh
if command -v uicache >/dev/null 2>&1; then
    uicache -a >/dev/null 2>&1 || true
fi
exit 0
POSTRM

chmod 0755 "$PKG/DEBIAN/postinst" "$PKG/DEBIAN/prerm" "$PKG/DEBIAN/postrm"

DEB="$BUILD/com.551.chatgpt14_${VERSION}_iphoneos-arm.deb"
dpkg-deb --root-owner-group -Zxz --build "$PKG" "$DEB"
echo "$DEB"
