#!/bin/bash
# Screenshots of the real editor, for review: the built OOO.app opened
# headlessly (see OOOSnapshot in Sources/OOOStudio/Snapshot.swift) on the
# sample slide and on the test slides, dark and light, on each inspector tab,
# with a shot selected, a title, the safe areas and the export sheet, three
# slides that turn and melt, marks drawn on the card, and the stage up with
# room for you.
#
#   bash scripts/ci-screens.sh [out-dir] [fixtures-dir]
#
# Run after `bash scripts/build-app.sh` and scripts/ci-renders.sh (which
# draws the test slides). Prints one line per screenshot; exits non-zero if
# any failed.
set -uo pipefail

cd "$(dirname "$0")/.."
OUT="${1:-renders/screens}"
FIX="${2:-renders/fixtures}"
APP="dist/OOO.app/Contents/MacOS/OOO"
[ -x "$APP" ] || { echo "build dist/OOO.app first"; exit 1; }
mkdir -p "$OUT"
WIDE="$FIX/wide-2576x1080.png"
STANDARD="$FIX/standard-1920x1080.png"
failures=0

shot() {
  local name="$1"; shift
  "$APP" --snapshot "$OUT/$name.png" "$@" > "$OUT/$name.log" 2>&1 &
  local pid=$!
  # The app gives up by itself after two minutes; this is the backstop. A
  # window that never gave up is sampled first, so its log says where it hung.
  ( sleep 135; sample "$pid" 3 -file "$OUT/$name.sample.txt" >/dev/null 2>&1; kill -9 "$pid" 2>/dev/null ) &
  local watchdog=$!
  wait "$pid"
  local rc=$?
  kill "$watchdog" 2>/dev/null
  wait "$watchdog" 2>/dev/null
  if [ "$rc" -eq 0 ] && [ -s "$OUT/$name.png" ]; then
    grep -h '^snapshot' "$OUT/$name.log" | sed "s|^snapshot $OUT/|  |"
    # The whole editor fits the window: the timeline is never off the bottom.
    if grep -q 'the editor needs' "$OUT/$name.log"; then
      grep -h 'the editor needs' "$OUT/$name.log" | sed "s|^layout: |  $name.png: |"
      failures=$((failures + 1))
    fi
  else
    echo "  $name.png FAILED (exit $rc)"
    tail -5 "$OUT/$name.log" | sed 's/^/    /'
    if [ -s "$OUT/$name.sample.txt" ]; then
      echo "    where its main thread was:"
      grep -m1 -A70 'main-thread' "$OUT/$name.sample.txt" | sed 's/^/    /' || true
    fi
    failures=$((failures + 1))
  fi
}

echo "== The editor"
shot editor-dark --shot 2
shot editor-light --scheme light --shot 2
shot arriving --time 1.0
shot look --tab look --size 1440x1500
shot look-light --scheme light --tab look --size 1440x1500
shot voice --tab voice
shot export --show-export
shot landscape --format landscape --shot 1
echo "== Test slides"
shot wide-opening --slide "$WIDE" --time 2.4
shot wide-shot --slide "$WIDE" --shot 3 --size 1440x1500
shot wide-safe-areas --slide "$WIDE" --shot 2 --safe-areas
shot standard-title --slide "$STANDARD" --title 'A $4.2B market nobody designs for.' --kicker 'pitch.dog' --time 2.6 --size 1440x1500
echo "== Slides, marks, and room for you"
shot slides --slide "$FIX/cover-2576x1080.png" --more "$WIDE,$FIX/wide-revised-2576x1080.png" --melt 2 --home --time 4.5 --size 1440x1500
shot marks --slide "$WIDE" --more "$STANDARD" --marks demo --time 6 --size 1440x1500
shot pen --slide "$WIDE" --marks demo --draw --time 6 --size 1440x900
shot room --slide "$WIDE" --lift whole --title 'How we grew 3.1× in nine months' --kicker 'pitch.dog' --time 9 --size 1440x1500
shot room-light --scheme light --slide "$WIDE" --lift 5-12,16- --time 8 --size 1440x900

echo "screens: $failures failed"
exit $((failures > 0 ? 1 : 0))
