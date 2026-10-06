#!/bin/bash
# Builds OOO.app (ad-hoc signed, Apple silicon) and a disk image in dist/.
#
#   bash scripts/build-app.sh [release|debug]
#
# Needs Xcode or the Command Line Tools on an Apple silicon Mac. The first build
# fetches Sparkle 2.10.0 (in-app updates) through Swift Package Manager.
#
# Update testing builds a copy under another name and identifier, at any
# version, so the real app and its settings are never touched (docs/UPDATES.md):
#   VERSION_OVERRIDE  BUNDLE_NAME_OVERRIDE  BUNDLE_ID_OVERRIDE
#   SPARKLE_PUBLIC_KEY_OVERRIDE  a throwaway key's public half, for CI's update test only
#   SKIP_DMG=1                   leave out the disk image
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
CONFIG="${1:-release}"
VERSION="${VERSION_OVERRIDE:-1.0.1}"
NAME="${BUNDLE_NAME_OVERRIDE:-OOO}"
BUNDLE_ID="${BUNDLE_ID_OVERRIDE:-dog.pitch.ooo}"
DIST="$ROOT/dist"
APPDIR="$DIST/$NAME.app"

# In-app updates (Sparkle): OOO trusts updates signed with pitch.dog's key, the
# same one Drift, Galileo and Backdrop use. Its private half never enters this
# repository (docs/UPDATES.md).
SPARKLE_PUBLIC_KEY="${SPARKLE_PUBLIC_KEY_OVERRIDE:-P43E8I+FgVyAW3QkS4J9bnDRRhAnsS4y3dT2WDce1lQ=}"
FEED="https://github.com/bomkino/ooo/releases/latest/download/appcast.xml"
# Sparkle compares CFBundleVersion, so it follows the version itself:
# 0.2.0 → 200, 1.4.2 → 10402. Versions only go up.
BUILD="$(echo "$VERSION" | awk -F. '{ printf "%d", $1 * 10000 + $2 * 100 + $3 }')"

echo "== Building OOO ($CONFIG, arm64)"
swift build -c "$CONFIG" --arch arm64 --product OOO
BIN="$(swift build -c "$CONFIG" --arch arm64 --show-bin-path)/OOO"
[ -x "$BIN" ] || { echo "missing binary $BIN"; exit 1; }

rm -rf "$APPDIR"
mkdir -p "$APPDIR/Contents/MacOS" "$APPDIR/Contents/Resources"
cp "$BIN" "$APPDIR/Contents/MacOS/OOO"
cp "$ROOT/NOTICES.md" "$ROOT/LICENSE" "$APPDIR/Contents/Resources/" 2>/dev/null || true
cp -R "$ROOT/Resources/Licenses" "$APPDIR/Contents/Resources/Licenses"
# Sparkle, as Swift Package Manager built it, keeping its own signature.
mkdir -p "$APPDIR/Contents/Frameworks"
ditto "$(dirname "$BIN")/Sparkle.framework" "$APPDIR/Contents/Frameworks/Sparkle.framework"

# The icon, drawn from code.
ICONS="$ROOT/.build/icon"
if [ ! -f "$ICONS/OOO.icns" ]; then
  mkdir -p "$ICONS/OOO.iconset"
  swift "$ROOT/scripts/make-icon.swift" "$ICONS/OOO.png"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$ICONS/OOO.png" --out "$ICONS/OOO.iconset/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) "$ICONS/OOO.png" --out "$ICONS/OOO.iconset/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONS/OOO.iconset" -o "$ICONS/OOO.icns"
fi
cp "$ICONS/OOO.icns" "$APPDIR/Contents/Resources/AppIcon.icns"

cat > "$APPDIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>OOO</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSArchitecturePriority</key><array><string>arm64</string></array>
  <key>LSApplicationCategoryType</key><string>public.app-category.video</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>SUFeedURL</key><string>$FEED</string>
  <key>SUPublicEDKey</key><string>$SPARKLE_PUBLIC_KEY</string>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>NSHumanReadableCopyright</key><string>© 2026 pitch.dog. Free software under the GNU AGPL 3.0.</string>
  <key>NSSpeechRecognitionUsageDescription</key>
  <string>OOO listens to your voiceover on this Mac to find when you say each word, so every move lands just before you name it.</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>OOO Project</string>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSHandlerRank</key><string>Owner</string>
      <key>LSItemContentTypes</key><array><string>dog.pitch.ooo.project</string></array>
      <key>LSTypeIsPackage</key><true/>
      <key>NSDocumentClass</key><string>NSDocument</string>
    </dict>
  </array>
  <key>UTExportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeIdentifier</key><string>dog.pitch.ooo.project</string>
      <key>UTTypeDescription</key><string>OOO Project</string>
      <key>UTTypeConformsTo</key><array><string>com.apple.package</string><string>public.composite-content</string></array>
      <key>UTTypeTagSpecification</key>
      <dict><key>public.filename-extension</key><array><string>ooo</string></array></dict>
    </dict>
  </array>
</dict>
</plist>
PLIST

# Ad hoc, and not --deep: Sparkle.framework keeps the signature its makers gave it
# (--deep would re-sign its helpers and strip their entitlements).
codesign --force --sign - "$APPDIR"
codesign --verify --verbose "$APPDIR"
echo "   → $APPDIR ($VERSION, build $BUILD)"

[ -n "${SKIP_DMG:-}" ] && exit 0
# A disk image with the app and a link to Applications, for CI's artifact.
# Releases are packed by scripts/make-release.sh.
STAGE="$DIST/dmg"
rm -rf "$STAGE" "$DIST/OOO.dmg"
mkdir -p "$STAGE"
cp -R "$APPDIR" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "OOO" -srcfolder "$STAGE" -ov -format UDZO "$DIST/OOO.dmg" >/dev/null
rm -rf "$STAGE"
echo "   → $DIST/OOO.dmg"
