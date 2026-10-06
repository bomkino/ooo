#!/bin/bash
# Packs a built OOO.app into a release's files: a disk image for people, a ZIP
# for the in-app updater, and checksums. Needs no key: the update feed that
# offers the ZIP is signed separately, by scripts/sign-release.sh (in the
# release workflow, with the key from its secret; docs/UPDATES.md).
#
#   bash scripts/make-release.sh <out-dir>
#
# Run after `bash scripts/build-app.sh release`. CI's release.yml runs it to
# publish a release; scripts/test-update.sh runs it on test copies.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$1"
BUNDLE="${BUNDLE_NAME_OVERRIDE:-OOO}"
SRC="dist/$BUNDLE.app"
[ -d "$SRC" ] || { echo "build $SRC first"; exit 1; }
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$SRC/Contents/Info.plist")"
DMG="OOO-$VERSION-macOS-arm64.dmg"
ZIP="OOO-$VERSION-macOS-arm64.zip"

mkdir -p "$OUT"
rm -f "$OUT/$DMG" "$OUT/$ZIP" "$OUT/SHA256SUMS.txt"
stage="$(mktemp -d)"
ditto "$SRC" "$stage/$BUNDLE.app"
ln -s /Applications "$stage/Applications"
hdiutil create -quiet -volname "$BUNDLE" -srcfolder "$stage" -ov -format UDZO -fs HFS+ "$OUT/$DMG"
rm -rf "$stage"
# The updater takes a ZIP: nothing is mounted, so macOS never offers to
# "install" a disk image in the middle of an update.
ditto -c -k --sequesterRsrc --keepParent "$SRC" "$OUT/$ZIP"
(cd "$OUT" && shasum -a 256 "$DMG" "$ZIP" > SHA256SUMS.txt)
echo "$OUT/$DMG"
echo "$OUT/$ZIP"
echo "$OUT/SHA256SUMS.txt"
