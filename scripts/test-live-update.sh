#!/bin/bash
# Proves the live update feed with a real copy of the app, as the release
# workflow runs it after publishing: downloads the newest release before the
# Latest one, opens it against the real feed with STUDIO_UPDATE_TEST=1 (check
# at once, install as soon as ready), waits for its files to become the Latest
# version, then for the Latest version to start as a new process and say it is
# running. This is what every installed copy will do within a day.
#
#   bash scripts/test-live-update.sh
#
# Needs the GitHub CLI (GH_TOKEN in CI). A release before the first one with
# the updater has no ZIP and can't update itself, so it is skipped.
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="bomkino/ooo"
STEM="OOO"
BUNDLE="OOO"
EXE="OOO"
WORK="$(mktemp -d)"
APP_PID=""
ID="dog.pitch.ooo"
cleanup() {
  [ -n "$APP_PID" ] && kill "$APP_PID" 2>/dev/null || true
  pkill -f "$WORK/install/$BUNDLE.app/Contents/MacOS/$EXE" 2>/dev/null || true
  defaults delete "$ID" UpdateTestReadyFile 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

LATEST="$(gh release list -R "$REPO" --exclude-drafts --exclude-pre-releases --json tagName,isLatest --jq '.[] | select(.isLatest) | .tagName')"
WANT="${LATEST#v}"
[ -n "$WANT" ] || { echo "live update: no Latest release"; exit 1; }
offers() { grep -Eq "shortVersionString(>|=\")${WANT}[<\"]" <<< "$(curl -fsSL "https://github.com/$REPO/releases/latest/download/appcast.xml" || true)"; }
for _ in $(seq 24); do
  offers && break
  sleep 5
done
offers || { echo "live update: the feed doesn't offer $WANT"; exit 1; }
echo "live update: the feed offers $WANT"

FROM=""
for tag in $(gh release list -R "$REPO" --exclude-drafts --exclude-pre-releases --limit 10 --json tagName --jq '.[].tagName'); do
  [ "$tag" = "$LATEST" ] && continue
  FROM="$tag"; break
done
[ -n "$FROM" ] || { echo "live update: skipped, $LATEST is the only release"; exit 0; }
ZIP="$STEM-${FROM#v}-macOS-arm64.zip"
if ! gh release download "$FROM" -R "$REPO" -p "$ZIP" -D "$WORK" 2>/dev/null; then
  echo "live update: skipped, $FROM has no $ZIP (it came before the updater)"; exit 0
fi
mkdir -p "$WORK/install" && ditto -x -k "$WORK/$ZIP" "$WORK/install"
APP="$WORK/install/$BUNDLE.app"
version() { /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist"; }
echo "live update: opening $BUNDLE $(version) against the live feed"
# The new version writes "version process" here once it is up (read from its
# defaults, which a relaunch keeps).
READY="$WORK/ready"
defaults write "$ID" UpdateTestReadyFile "$READY"
STUDIO_UPDATE_TEST=1 "$APP/Contents/MacOS/$EXE" > "$WORK/app.log" 2>&1 &
APP_PID=$!
for _ in $(seq 1 180); do
  [ "$(version)" = "$WANT" ] && break
  sleep 1
done
got="$(version)"
if [ "$got" != "$WANT" ]; then
  echo "live update: FAILED, $FROM is still $got"; cat "$WORK/app.log"; exit 1
fi
codesign -v --strict "$APP"
NEW=""
for _ in $(seq 60); do
  if read -r v pid < "$READY" 2>/dev/null && [ "$v" = "$WANT" ] && [ "$pid" != "$APP_PID" ]; then NEW="$pid"; break; fi
  sleep 1
done
[ -n "$NEW" ] || { echo "live update: FAILED, $WANT is on disk but never said it was running"; cat "$WORK/app.log"; exit 1; }
sleep 3
kill -0 "$NEW" 2>/dev/null || { echo "live update: FAILED, $WANT started (process $NEW) but stopped within three seconds"; exit 1; }
kill "$NEW" 2>/dev/null || true
echo "live update: $FROM updated itself to $WANT from the live feed, and $WANT relaunched (process $NEW) and is running"
