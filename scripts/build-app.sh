#!/bin/bash
# Builds OOO.app (ad-hoc signed, Apple silicon) and a disk image in dist/.
#
#   bash scripts/build-app.sh [release|debug]
#
# Needs Xcode or the Command Line Tools on an Apple silicon Mac.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
CONFIG="${1:-release}"
VERSION="${OOO_VERSION:-0.1.0}"
DIST="$ROOT/dist"
APPDIR="$DIST/OOO.app"

echo "== Building OOO ($CONFIG, arm64)"
swift build -c "$CONFIG" --arch arm64 --product OOO
BIN="$(swift build -c "$CONFIG" --arch arm64 --show-bin-path)/OOO"
[ -x "$BIN" ] || { echo "missing binary $BIN"; exit 1; }

rm -rf "$APPDIR"
mkdir -p "$APPDIR/Contents/MacOS" "$APPDIR/Contents/Resources"
cp "$BIN" "$APPDIR/Contents/MacOS/OOO"
cp "$ROOT/NOTICES.md" "$ROOT/LICENSE" "$APPDIR/Contents/Resources/" 2>/dev/null || true

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

BUILD="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"
cat > "$APPDIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>OOO</string>
  <key>CFBundleDisplayName</key><string>OOO</string>
  <key>CFBundleIdentifier</key><string>dog.pitch.ooo</string>
  <key>CFBundleExecutable</key><string>OOO</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSArchitecturePriority</key><array><string>arm64</string></array>
  <key>LSApplicationCategoryType</key><string>public.app-category.video</string>
  <key>NSHighResolutionCapable</key><true/>
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

codesign --force --deep --sign - "$APPDIR"
codesign --verify --verbose "$APPDIR"
echo "   → $APPDIR"

# A disk image with the app and a link to Applications.
STAGE="$DIST/dmg"
rm -rf "$STAGE" "$DIST/OOO.dmg"
mkdir -p "$STAGE"
cp -R "$APPDIR" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "OOO" -srcfolder "$STAGE" -ov -format UDZO "$DIST/OOO.dmg" >/dev/null
rm -rf "$STAGE"
echo "   → $DIST/OOO.dmg"
