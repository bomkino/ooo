#!/bin/bash
# Proves in-app updates work before a release, on this Mac or in CI, without
# pitch.dog's real key: a throwaway key signs a local feed, and test copies of
# the app (another name and bundle identifier) trust only that key.
#
#   bash scripts/test-update.sh
#
#   1. OOO 9.0.0 reads the feed, installs 9.0.1 and relaunches on it.
#   2. With one byte of the served ZIP changed, 9.0.0 refuses it and stays.
#
# Needs a logged-in session (the app opens a window). Downloads Sparkle's
# tools from its release if SPARKLE_BIN isn't set, and checks their checksum.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
T="$(mktemp -d)"
NAME="OOO Update Test"
PORT=8765
export BUNDLE_NAME_OVERRIDE="$NAME" BUNDLE_ID_OVERRIDE="dog.pitch.ooo.updatetest" SKIP_DMG=1

cleanup() {
  pkill -f "$NAME.app/Contents/MacOS/OOO" 2>/dev/null || true
  [ -n "${SERVER:-}" ] && kill "$SERVER" 2>/dev/null || true
  defaults delete dog.pitch.ooo.updatetest 2>/dev/null || true
}
trap cleanup EXIT

if [ -z "${SPARKLE_BIN:-}" ]; then
  echo "== Sparkle 2.10.0 tools"
  curl -fsSL -o "$T/sparkle.tar.xz" https://github.com/sparkle-project/Sparkle/releases/download/2.10.0/Sparkle-2.10.0.tar.xz
  echo "c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c  $T/sparkle.tar.xz" | shasum -a 256 -c -
  mkdir -p "$T/sparkle" && tar -xf "$T/sparkle.tar.xz" -C "$T/sparkle"
  SPARKLE_BIN="$T/sparkle/bin"
fi

echo "== A throwaway signing key"
cat > "$T/key.swift" <<'SWIFT'
import CryptoKit
import Foundation
let key = Curve25519.Signing.PrivateKey()
try! key.rawRepresentation.base64EncodedString().write(toFile: CommandLine.arguments[1], atomically: true, encoding: .utf8)
print(key.publicKey.rawRepresentation.base64EncodedString())
SWIFT
export SPARKLE_PUBLIC_KEY_OVERRIDE="$(swift "$T/key.swift" "$T/key")"

echo "== Test copies at 9.0.0 (installed) and 9.0.1 (on the feed)"
VERSION_OVERRIDE=9.0.0 bash scripts/build-app.sh release >/dev/null
mkdir -p "$T/install" "$T/feed"
ditto "dist/$NAME.app" "$T/old.app"
VERSION_OVERRIDE=9.0.1 bash scripts/build-app.sh release >/dev/null
SPARKLE_BIN="$SPARKLE_BIN" SPARKLE_KEY="$T/key" DOWNLOAD_URL="http://127.0.0.1:$PORT/" \
  bash scripts/make-release.sh "$T/feed"
rm -rf "dist/$NAME.app"
ZIP="$(cd "$T/feed" && ls *.zip)"

python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$T/feed" 2> "$T/server.log" &
SERVER=$!
sleep 1

version() { /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$T/install/$NAME.app/Contents/Info.plist"; }

# Installs a fresh 9.0.0, runs it against the feed for up to $1 seconds, and
# stops early once it reports 9.0.1.
run() {
  pkill -f "$NAME.app/Contents/MacOS/OOO" 2>/dev/null || true
  rm -rf "$T/install/$NAME.app" && ditto "$T/old.app" "$T/install/$NAME.app"
  : > "$T/server.log"
  STUDIO_UPDATE_TEST=1 STUDIO_UPDATE_FEED="http://127.0.0.1:$PORT/appcast.xml" \
    "$T/install/$NAME.app/Contents/MacOS/OOO" > "$T/app.log" 2>&1 &
  for _ in $(seq "$1"); do
    sleep 1
    [ "$(version)" = 9.0.1 ] && break
  done
  sleep 2
  pkill -f "$NAME.app/Contents/MacOS/OOO" 2>/dev/null || true
}

echo "== 1. A signed update installs"
run 90
grep -q "GET /$ZIP" "$T/server.log" || { echo "FAIL: the ZIP was never fetched"; cat "$T/server.log" "$T/app.log"; exit 1; }
[ "$(version)" = 9.0.1 ] || { echo "FAIL: still $(version) after the update"; cat "$T/server.log"; tail -40 "$T/app.log"; exit 1; }
echo "   9.0.0 fetched $ZIP and relaunched as $(version)"

echo "== 2. A ZIP with one byte changed is refused"
python3 - "$T/feed/$ZIP" <<'PY'
import sys
p = sys.argv[1]
b = bytearray(open(p, "rb").read())
b[len(b) // 2] ^= 0x01
open(p, "wb").write(b)
PY
run 30
grep -q "GET /$ZIP" "$T/server.log" || { echo "FAIL: the tampered ZIP was never fetched, so nothing was tested"; cat "$T/server.log"; exit 1; }
[ "$(version)" = 9.0.0 ] || { echo "FAIL: a tampered update was installed ($(version))"; exit 1; }
echo "   9.0.0 fetched the tampered $ZIP and stayed at $(version)"
echo "== In-app updates: OK"
