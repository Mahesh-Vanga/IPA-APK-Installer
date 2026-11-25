#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
[[ "$(uname -s)" == Darwin ]] || { echo 'Run this script on macOS with Xcode installed.' >&2; exit 1; }
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Info.plist")"
/usr/bin/xcrun --find devicectl >/dev/null 2>&1 || echo "Note: full Xcode is required for IPA installation, but APK installation works with ADB."
SDK="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
SWIFT="$(/usr/bin/xcrun --sdk macosx --find swiftc)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ipa-installer.XXXXXXXX")"
trap 'rm -rf "$WORK"' EXIT
STAGE="$WORK/stage"
APP="$STAGE/IPA & APK Installer.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$ROOT/dist"
ARCHS="$(uname -m)"
if [[ "${BUILD_UNIVERSAL:-0}" == 1 ]]; then ARCHS="arm64 x86_64"; fi
for ARCH in $ARCHS; do
  "$SWIFT" -swift-version 5 -Osize -Xlinker -dead_strip -file-prefix-map "$ROOT=." -file-prefix-map "$WORK=.build" -parse-as-library -module-cache-path "$WORK/modules" -sdk "$SDK" -target "${ARCH}-apple-macosx14.0" -framework SwiftUI -framework AppKit -framework UniformTypeIdentifiers "$ROOT"/Sources/*.swift -o "$WORK/$ARCH"
done
if [[ "${BUILD_UNIVERSAL:-0}" == 1 ]]; then
  /usr/bin/lipo -create "$WORK/arm64" "$WORK/x86_64" -output "$APP/Contents/MacOS/IPAInstaller"
else
  cp "$WORK/$(uname -m)" "$APP/Contents/MacOS/IPAInstaller"
fi
/bin/cp -X "$ROOT/Info.plist" "$APP/Contents/Info.plist"
if [[ -n "${UPDATE_REPOSITORY:-}" ]]; then
  [[ "$UPDATE_REPOSITORY" =~ ^[A-Za-z0-9-]+/[A-Za-z0-9_.-]+$ ]] || { echo "UPDATE_REPOSITORY must be owner/repository." >&2; exit 1; }
  /usr/libexec/PlistBuddy -c "Add :UpdateRepository string $UPDATE_REPOSITORY" "$APP/Contents/Info.plist"
fi
if [[ -f "$ROOT/AppIcon.icns" ]]; then /bin/cp -X "$ROOT/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"; /usr/libexec/PlistBuddy -c 'Add :CFBundleIconFile string AppIcon' "$APP/Contents/Info.plist"; fi
if [[ "${SIGN_IDENTITY:--}" == "-" ]]; then
  /usr/bin/codesign --force --sign - "$APP"
else
  /usr/bin/codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
fi
/usr/bin/codesign --verify --strict "$APP"
ln -s /Applications "$STAGE/Applications"
DMG="$ROOT/dist/IPA-APK-Installer-$VERSION.dmg"
[[ ! -e "$DMG" ]] || { echo "DMG already exists: $DMG. Move it elsewhere before rebuilding." >&2; exit 1; }
/usr/bin/hdiutil create -volname "IPA & APK Installer" -srcfolder "$STAGE" -format UDZO "$DMG"
if [[ "${SIGN_IDENTITY:--}" != "-" ]]; then
  /usr/bin/codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
fi
/usr/bin/hdiutil verify "$DMG"
if [[ "${BUILD_PKG:-0}" == 1 ]]; then
  PKG="$ROOT/dist/IPA-APK-Installer-$VERSION.pkg"
  [[ ! -e "$PKG" ]] || { echo "PKG already exists: $PKG" >&2; exit 1; }
  if [[ -n "${INSTALLER_SIGN_IDENTITY:-}" ]]; then
    /usr/bin/productbuild --component "$APP" /Applications --sign "$INSTALLER_SIGN_IDENTITY" "$PKG"
    /usr/sbin/pkgutil --check-signature "$PKG"
  else
    /usr/bin/productbuild --component "$APP" /Applications "$PKG"
  fi
  echo "Created: $PKG"
fi
echo "Created: $DMG"
