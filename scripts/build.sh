#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(cat "$ROOT/VERSION" | tr -d '[:space:]')"
BUILD="$ROOT/build"
APP="$BUILD/ChatGPT.app"
PKG="$BUILD/pkg"
rm -rf "$BUILD"
mkdir -p "$APP" "$PKG/Applications" "$PKG/DEBIAN"

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
CLANG="$(xcrun --sdk iphoneos --find clang)"
SOURCES=("$ROOT/App/ChatGPT14.m")
"$CLANG" -arch arm64 -isysroot "$SDK" -miphoneos-version-min=14.0 -fobjc-arc -fblocks -fmodules -O2 \
  -framework UIKit -framework Foundation -framework Security -framework Speech -framework AVFoundation -framework WebKit \
  "${SOURCES[@]}" -o "$APP/ChatGPT14"

cp "$ROOT/App/Info.plist" "$APP/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Info.plist"
BUILDNUM="$(echo "$VERSION" | tr -d '.')"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILDNUM" "$APP/Info.plist"
python3 "$ROOT/scripts/make_icon.py" "$APP"
chmod 0755 "$APP/ChatGPT14"

if command -v ldid >/dev/null 2>&1; then
  ldid -S "$APP/ChatGPT14"
else
  codesign --force --sign - "$APP/ChatGPT14"
fi

cp -R "$APP" "$PKG/Applications/ChatGPT.app"
cat > "$PKG/DEBIAN/control" <<CONTROL
Package: com.551.chatgpt14
Name: ChatGPT iOS 14
Version: $VERSION
Architecture: iphoneos-arm
Description: Native ChatGPT-style client for rootful iOS 14 with streaming chat, web search, images, files, tools, dictation, live voice and local chat history.
Maintainer: 551UK
Author: 551UK
Section: Applications
Depends: firmware (>= 14.0)
CONTROL
cat > "$PKG/DEBIAN/postinst" <<'POST'
#!/bin/sh
if command -v uicache >/dev/null 2>&1; then uicache -p /Applications/ChatGPT.app >/dev/null 2>&1 || true; fi
exit 0
POST
cat > "$PKG/DEBIAN/prerm" <<'PRE'
#!/bin/sh
exit 0
PRE
cat > "$PKG/DEBIAN/postrm" <<'POSTRM'
#!/bin/sh
if command -v uicache >/dev/null 2>&1; then uicache -a >/dev/null 2>&1 || true; fi
exit 0
POSTRM
chmod 0755 "$PKG/DEBIAN/postinst" "$PKG/DEBIAN/prerm" "$PKG/DEBIAN/postrm"

DEB="$BUILD/com.551.chatgpt14_${VERSION}_iphoneos-arm.deb"
dpkg-deb --root-owner-group -Zxz --build "$PKG" "$DEB"
echo "$DEB"
