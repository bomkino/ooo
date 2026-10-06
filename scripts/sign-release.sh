#!/bin/bash
# Turns on the in-app update to a release: signs its ZIP with pitch.dog's key
# and writes the signed appcast.xml. Nothing is rebuilt. The release workflow
# runs it on every release (--dir, before publishing) and for "Sign" (a
# release already out), with the key from its secret; it also runs on a Mac
# that holds the key, from this repository on main:
#
#   bash scripts/sign-release.sh v1.0.1 [--only]
#
#   1. downloads the release's ZIP and SHA256SUMS.txt, and checks one against the other
#   2. checks the app inside is that version and trusts pitch.dog's key
#   3. signs the ZIP (generate_appcast --ed-key-file) into appcast.xml, with
#      this version's section of CHANGELOG.md for the update window
#   4. checks the signature with the public key inside the app, as Sparkle will
#   5. uploads appcast.xml to the release, replacing the one it has
#   6. confirms releases/latest/download/appcast.xml now names this version
#   7. with --only, then deletes every other release, so this one is the only
#      version on the releases page (their tags stay). Nothing reads them once
#      the feed names this version: installed copies update from this release.
#
# Tests sign a local folder instead (no download, upload or feed check):
#
#   bash scripts/sign-release.sh --dir <folder>   # its ZIP and SHA256SUMS.txt; writes <folder>/appcast.xml
#
# Environment:
#   SPARKLE_BIN   Sparkle's tools (default ~/Library/Application Support/pitch.dog/Sparkle/2.10.0/bin)
#   SPARKLE_KEY   the private EdDSA key file (default …/pitch.dog/Release Keys/sparkle-ed25519-private.key)
#   DOWNLOAD_URL  where the ZIP is served (default: the GitHub release; --dir needs it)
#
# The key is only ever read by generate_appcast, from its file. Never commit
# it, paste it anywhere or print it (docs/UPDATES.md).
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="bomkino/ooo"
SUPPORT="$HOME/Library/Application Support/pitch.dog"
SPARKLE_BIN="${SPARKLE_BIN:-$SUPPORT/Sparkle/2.10.0/bin}"
SPARKLE_KEY="${SPARKLE_KEY:-$SUPPORT/Release Keys/sparkle-ed25519-private.key}"
fail() { echo "sign-release: $*" >&2; exit 1; }

case "${1:-}" in
  --dir) LOCAL="${2:?--dir needs a folder}"; TAG="" ;;
  v[0-9]*.[0-9]*.[0-9]*) LOCAL=""; TAG="$1" ;;
  *) sed -n '2,31p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
ONLY=""
for a in "$@"; do [ "$a" = --only ] && ONLY=1; done

[ -x "$SPARKLE_BIN/generate_appcast" ] || fail "Sparkle's tools aren't at $SPARKLE_BIN (see docs/UPDATES.md)"
[ -f "$SPARKLE_KEY" ] || fail "the signing key isn't at $SPARKLE_KEY"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

if [ -n "$TAG" ]; then
  command -v gh >/dev/null || fail "needs the GitHub CLI (brew install gh), signed in"
  gh auth status >/dev/null 2>&1 || fail "gh isn't signed in: run gh auth login"
  VERSION="${TAG#v}"
  ZIP="OOO-$VERSION-macOS-arm64.zip"
  echo "== 1. The $TAG release's ZIP"
  gh release download "$TAG" -R "$REPO" -p "$ZIP" -p SHA256SUMS.txt -D "$T" \
    || fail "couldn't download $ZIP and SHA256SUMS.txt from $TAG: has CI published it?"
  SRC="$T"
  DOWNLOAD_URL="${DOWNLOAD_URL:-https://github.com/$REPO/releases/download/$TAG/}"
else
  [ -d "$LOCAL" ] || fail "no folder $LOCAL"
  SRC="$(cd "$LOCAL" && pwd)"
  ZIP="$(cd "$SRC" && ls OOO-*-macOS-arm64.zip 2>/dev/null | head -1)"
  [ -n "$ZIP" ] || fail "no OOO-x.y.z-macOS-arm64.zip in $SRC"
  VERSION="${ZIP#OOO-}"; VERSION="${VERSION%-macOS-arm64.zip}"
  [ -n "${DOWNLOAD_URL:-}" ] || fail "--dir needs DOWNLOAD_URL, where the ZIP will be served"
  echo "== 1. $ZIP in $SRC"
fi
(cd "$SRC" && grep " $ZIP\$" SHA256SUMS.txt | shasum -a 256 -c -) || fail "$ZIP doesn't match SHA256SUMS.txt"

echo "== 2. The app inside"
ditto -x -k "$SRC/$ZIP" "$T/app"
APP="$(ls -d "$T"/app/*.app | head -1)"
PLIST="$APP/Contents/Info.plist"
SHORT="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")"
BUILD="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST")"
PUBLIC="$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$PLIST")"
[ "$SHORT" = "$VERSION" ] || fail "the ZIP holds $SHORT, not $VERSION"
echo "   $(basename "$APP") $SHORT (build $BUILD), trusting key $PUBLIC"

echo "== 3. Signing"
mkdir -p "$T/cast"
cp "$SRC/$ZIP" "$T/cast/"
# What's new, for the update window: this version's section of the changelog.
awk -v v="## $VERSION" 'index($0, v) == 1 { on = 1; next } /^## / { on = 0 } on' CHANGELOG.md > "$T/cast/${ZIP%.zip}.md"
[ -s "$T/cast/${ZIP%.zip}.md" ] || rm "$T/cast/${ZIP%.zip}.md"
"$SPARKLE_BIN/generate_appcast" --ed-key-file "$SPARKLE_KEY" --download-url-prefix "$DOWNLOAD_URL" \
  --link "https://github.com/$REPO/releases" --embed-release-notes --maximum-versions 1 -o "$T/appcast.xml" "$T/cast" >/dev/null
xmllint --noout "$T/appcast.xml"
grep -Eq "shortVersionString(>|=\")$VERSION[<\"]" "$T/appcast.xml" || fail "the appcast doesn't name $VERSION"
grep -q "url=\"$DOWNLOAD_URL$ZIP\"" "$T/appcast.xml" || fail "the appcast doesn't point at $DOWNLOAD_URL$ZIP"
SIG="$(grep -o 'sparkle:edSignature="[^"]*"' "$T/appcast.xml" | head -1 | cut -d'"' -f2)"
[ -n "$SIG" ] || fail "the appcast carries no signature"

echo "== 4. Checking the signature with the key inside the app"
cat > "$T/verify.swift" <<'SWIFT'
import CryptoKit
import Foundation
let a = CommandLine.arguments
guard let key = Data(base64Encoded: a[1]), let sig = Data(base64Encoded: a[2]),
      let file = FileManager.default.contents(atPath: a[3]),
      let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: key) else { exit(2) }
exit(pub.isValidSignature(sig, for: file) ? 0 : 1)
SWIFT
swift "$T/verify.swift" "$PUBLIC" "$SIG" "$SRC/$ZIP" || fail "the app wouldn't accept this signature: is SPARKLE_KEY the key whose public half is $PUBLIC?"
echo "   the app inside accepts it"

if [ -z "$TAG" ]; then
  cp "$T/appcast.xml" "$SRC/appcast.xml"
  echo "== Signed: $SRC/appcast.xml"
  exit 0
fi

echo "== 5. Uploading appcast.xml to $TAG"
LATEST="$(gh release list -R "$REPO" --json tagName,isLatest --jq '.[] | select(.isLatest) | .tagName')"
[ "$LATEST" = "$TAG" ] || echo "   note: the Latest release is $LATEST, not $TAG, so installed copies won't read this feed until $TAG is Latest"
gh release upload "$TAG" "$T/appcast.xml" -R "$REPO" --clobber

echo "== 6. The feed installed copies read"
for _ in $(seq 24); do
  if curl -fsSL "https://github.com/$REPO/releases/latest/download/appcast.xml" | grep -Eq "shortVersionString(>|=\")$VERSION[<\"]"; then
    echo "== Done: installed copies of OOO will offer $VERSION"
    if [ -n "$ONLY" ] && [ "$LATEST" = "$TAG" ]; then
      echo "== 7. $TAG as the only release"
      for old in $(gh release list -R "$REPO" --limit 100 --json tagName --jq '.[].tagName'); do
        [ "$old" = "$TAG" ] && continue
        gh release delete "$old" -R "$REPO" -y && echo "   deleted the $old release (its tag stays)"
      done
    fi
    [ -z "$ONLY" ] || [ "$LATEST" = "$TAG" ] || echo "   kept the other releases: $TAG isn't the Latest one"
    exit 0
  fi
  sleep 5
done
fail "releases/latest/download/appcast.xml doesn't name $VERSION yet; check that $TAG is the Latest release"
