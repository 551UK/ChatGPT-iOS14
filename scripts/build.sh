#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
REYNARD_VERSION="0.12.0"
REYNARD_URL="https://github.com/minh-ton/reynard-browser/releases/download/${REYNARD_VERSION}/Reynard-Jailbroken.ipa"

BUILD="$ROOT/build"
WORK="$BUILD/reynard"
PKG="$BUILD/pkg"
APP="$PKG/Applications/Reynard.app"
PREF_DIR="$PKG/var/mobile/Library/Preferences"
DOC_DIR="$PKG/usr/share/doc/com.551.chatgpt14"

rm -rf "$BUILD"
mkdir -p "$WORK" "$PKG/Applications" "$PKG/DEBIAN" "$PREF_DIR" "$DOC_DIR"

curl -L --fail --retry 3 --retry-delay 2 "$REYNARD_URL" -o "$WORK/Reynard-Jailbroken.ipa"
unzip -q "$WORK/Reynard-Jailbroken.ipa" -d "$WORK/unpacked"

UPSTREAM_APP="$(find "$WORK/unpacked/Payload" -maxdepth 1 -type d -name '*.app' | head -1)"
if [ -z "$UPSTREAM_APP" ] || [ ! -d "$UPSTREAM_APP" ]; then
    echo "Could not find the bundled Gecko app" >&2
    exit 1
fi

# Keep the known-good jailbroken bundle completely untouched. The previous build
# changed the signed bundle after extraction, which can stop iOS 14 from registering
# it as a Home Screen application.
ditto "$UPSTREAM_APP" "$APP"

BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")"
MAIN_EXEC="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Info.plist")"
if [ "$BUNDLE_ID" != "com.minh-ton.Reynard" ] || [ ! -f "$APP/$MAIN_EXEC" ]; then
    echo "Unexpected bundled Gecko app layout" >&2
    exit 1
fi

# Configure the bundled Gecko app to open ChatGPT instead of its normal homepage.
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

curl -L --fail --retry 3 \
    "https://raw.githubusercontent.com/minh-ton/reynard-browser/${REYNARD_VERSION}/LICENSE" \
    -o "$DOC_DIR/REYNARD-LICENSE.txt"
cat > "$DOC_DIR/REYNARD-SOURCE.txt" <<SOURCE
This package embeds the official Reynard Browser ${REYNARD_VERSION} jailbroken build as its Gecko engine/browser shell.
Upstream source: https://github.com/minh-ton/reynard-browser/tree/${REYNARD_VERSION}
Upstream release: https://github.com/minh-ton/reynard-browser/releases/tag/${REYNARD_VERSION}
SOURCE

cat > "$PKG/DEBIAN/control" <<CONTROL
Package: com.551.chatgpt14
Name: ChatGPT iOS 14
Version: $VERSION
Architecture: iphoneos-arm
Description: Self-contained Gecko-powered ChatGPT web client for rootful iOS 14. No separate browser install or OpenAI API key is required.
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
rm -rf /Applications/ChatGPT.app >/dev/null 2>&1 || true
if command -v uicache >/dev/null 2>&1; then
    uicache -p /Applications/Reynard.app >/dev/null 2>&1 || uicache -a >/dev/null 2>&1 || true
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
