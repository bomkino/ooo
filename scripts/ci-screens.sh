#!/bin/bash
# Screenshots of the real editor, for review: the built OOO.app opened
# headlessly (see OOOSnapshot in Sources/OOOStudio/Snapshot.swift) on the
# sample slide and on the test slides, dark and light, on each inspector tab,
# with a shot selected, a title, the safe areas and the export sheet, three
# slides that turn and melt, marks drawn on the card with the pen out, the
# slide map beside the video (with the inspector closed, and kept in the
# inspector instead), and the stage up with room for you. Last, a soak: a
# live take kept and played back in Frame on the running stage, failed if
# it would freeze the window or swamp the Mac's memory.
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
  # The app gives up by itself after two minutes (five for a soak); this is
  # the backstop. A window that never gave up is sampled first, so its log
  # says where it hung.
  local backstop=135
  case " $* " in *" --soak "*) backstop=315 ;; esac
  ( sleep "$backstop"; sample "$pid" 3 -file "$OUT/$name.sample.txt" >/dev/null 2>&1; kill -9 "$pid" 2>/dev/null ) &
  local watchdog=$!
  wait "$pid"
  local rc=$?
  kill "$watchdog" 2>/dev/null
  wait "$watchdog" 2>/dev/null
  # A soak's verdict, whichever way it went.
  grep -h '^soak: \(worst\|passed\|FAILED\|kept\|the main\|couldn\|240 scroll\)' "$OUT/$name.log" | sed 's/^/  /'
  # And whether the voice and the picture stayed together, clap by clap.
  grep -h '^sync: ' "$OUT/$name.log" | sed 's/^/  /'
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
shot map-wide --slide "$WIDE" --shot 2 --no-inspector
shot map-in-inspector --slide "$WIDE" --shot 2 --no-map
echo "== Test slides"
shot wide-opening --slide "$WIDE" --time 2.4
shot wide-shot --slide "$WIDE" --shot 3 --size 1440x1500
shot wide-safe-areas --slide "$WIDE" --shot 2 --safe-areas
shot standard-title --slide "$STANDARD" --title 'A $4.2B market nobody designs for.' --kicker 'pitch.dog' --time 2.6 --size 1440x1500
echo "== Slides, marks, and room for you"
shot slides --slide "$FIX/cover-2576x1080.png" --more "$WIDE,$FIX/wide-revised-2576x1080.png" --melt 2 --home --time 4.5 --size 1440x1500
shot marks --slide "$WIDE" --more "$STANDARD" --marks demo --time 6 --size 1440x1500
shot pen --slide "$WIDE" --marks demo --time 6 --size 1440x900 --draw
shot pen-shapes --slide "$WIDE" --more "$STANDARD" --marks demo --time 6 --size 1100x800 --draw --pen arrow --pen-fades
shot room --slide "$WIDE" --lift whole --title 'How we grew 3.1× in nine months' --kicker 'pitch.dog' --time 9 --size 1440x1500
shot room-light --scheme light --slide "$WIDE" --lift 5-12,16- --time 8 --size 1440x900

echo "== Modes and timing"
shot mode-draw --slide "$WIDE" --mode draw --time 6
shot mode-live --slide "$WIDE" --mode live
shot mode-live-light --scheme light --slide "$WIDE" --mode live --size 1440x1500
shot live-take --slide "$WIDE" --live-take 6
shot live-take-pen --slide "$WIDE" --live-take 6 --pen-out --pen circle
shot live-take-pen-narrow --slide "$WIDE" --live-take 6 --pen-out --size 1100x800
shot timeline-zoomed --slide "$WIDE" --shot 3 --zoom 2.5
shot map-picked-light --scheme light --slide "$WIDE" --shot 2 --no-inspector

echo "== A live take, kept, then back to Frame (memory and a main thread that answers)"
shot soak-take --slide "$WIDE" --soak 45 --size 1440x900

echo "screens: $failures failed"
exit $((failures > 0 ? 1 : 0))
