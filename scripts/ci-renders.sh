#!/bin/bash
# Renders OOO's review set on the macOS runner: test slides drawn at the sizes
# pitch.dog designs at (2576 × 1080 and 1920 × 1080, as pictures and as a
# PDF), each taken through the app's journey (read, Direct for Me, render) in
# a 1080 × 1920 reel, plus the vector sample. For each slide: the director's
# plan, a contact sheet, a still at the opening and at every landing, the
# opening at five angles and three floors, how dark its type lands against
# the slide as supplied, how its moves fly (motioncheck), and a draft video.
# Then the titles, every backdrop look, every arrival (Weave and Develop also
# as draft videos), three slides (a cover turning over to the wide slide,
# melting into its corrected version, turning back home), marks drawn on
# the card (on a dark slide and two light ones, up close, and in 1.0.1's ink
# beside them), a live take (each press, and a stand-in for you in the room), the stage
# rising to leave room for a talking head (both also as full sets and a
# Good video), the wide tour moved onto a corrected slide (Replace
# Slide), the stills Save Stills writes, export timings, a bench (with the
# machine it ran on), how colour survives the encoder, and summary.txt with
# the numbers that matter. Fails when motioncheck finds a problem in any set.
#
#   bash scripts/ci-renders.sh [out-dir]
set -eo pipefail

cd "$(dirname "$0")/.."
OUT="${1:-renders}"
LAB="$(swift build -c release --show-bin-path)/ooo-lab"
[ -x "$LAB" ] || swift build -c release --product ooo-lab
mkdir -p "$OUT/fixtures"

echo "== Test slides"
"$LAB" fixture --kind wide --out "$OUT/fixtures/wide-2576x1080.png"
"$LAB" fixture --kind wide-revised --out "$OUT/fixtures/wide-revised-2576x1080.png"
"$LAB" fixture --kind standard --out "$OUT/fixtures/standard-1920x1080.png"
"$LAB" fixture --kind wide --out "$OUT/fixtures/wide.pdf"
"$LAB" fixture --kind wide --scale 2 --out "$OUT/fixtures/wide-5152x2160.png"
"$LAB" fixture --kind cover --out "$OUT/fixtures/cover-2576x1080.png"

render_set() {
  local name="$1"; shift
  local dir="$OUT/$name"
  mkdir -p "$dir"
  echo "== $name"
  "$LAB" analyze "$@" | tee "$dir/plan.txt"
  "$LAB" sheet "$@" --out "$dir/sheet.png"
  "$LAB" landings "$@" --out "$dir/landings"
  "$LAB" openings "$@" --out "$dir/openings.png"
  "$LAB" inkcheck "$@" | tee "$dir/ink.txt"
  "$LAB" motioncheck "$@" | tee "$dir/motion.txt"
  "$LAB" render "$@" --quality draft --scale 0.5 --out "$dir/draft.mp4"
}

render_set sample
mkdir -p "$OUT/titles"
"$LAB" titles --slide "$OUT/fixtures/wide-2576x1080.png" --title "How we grew 3.1× in nine months" --kicker "pitch.dog · Series A" --out "$OUT/titles/wide.png"
"$LAB" titles --slide "$OUT/fixtures/standard-1920x1080.png" --title "A \$4.2B market nobody designs for." --kicker "pitch.dog" --out "$OUT/titles/standard.png"
"$LAB" titles --slide "$OUT/fixtures/standard-1920x1080.png" --title "A \$4.2B market nobody designs for." --kicker "pitch.dog · Seed round" --kicker-as-typed --out "$OUT/titles/standard-as-typed.png"
mkdir -p "$OUT/looks"
"$LAB" backdrops --slide "$OUT/fixtures/wide-2576x1080.png" --out "$OUT/looks/backdrops.png"
"$LAB" arrivals --slide "$OUT/fixtures/wide-2576x1080.png" --out "$OUT/looks/arrivals.png"
"$LAB" render --slide "$OUT/fixtures/wide-2576x1080.png" --arrive weave --quality draft --scale 0.5 --out "$OUT/looks/weave-draft.mp4"
"$LAB" render --slide "$OUT/fixtures/wide-2576x1080.png" --arrive develop --quality draft --scale 0.5 --out "$OUT/looks/develop-draft.mp4"
echo "== Slides that turn and melt, marks on the card, and room for you"
WIDE="$OUT/fixtures/wide-2576x1080.png"
COVER="$OUT/fixtures/cover-2576x1080.png"
REVISED="$OUT/fixtures/wide-revised-2576x1080.png"
TITLE="How we grew 3.1× in nine months"
mkdir -p "$OUT/slides" "$OUT/room"
"$LAB" changes --slide "$COVER" --more "$WIDE,$REVISED" --melt 2 --home --out "$OUT/slides/changes.png"
"$LAB" changes --slide "$COVER" --more "$OUT/fixtures/standard-1920x1080.png" --out "$OUT/slides/changes-standard.png"
MARKED=("$COVER" --more "$WIDE,$OUT/fixtures/standard-1920x1080.png" --marks demo)
"$LAB" marks --slide "${MARKED[@]}" --close "$OUT/slides/marks-close.png" --out "$OUT/slides/marks.png"
"$LAB" marks --slide "${MARKED[@]}" --ink flat --close "$OUT/slides/marks-close-1.0.1.png" --out "$OUT/slides/marks-1.0.1.png"
"$LAB" lifts --slide "$WIDE" --lift 5-12,16- --title "$TITLE" --kicker "pitch.dog · Series A" --out "$OUT/room/lifts.png"
"$LAB" landings --slide "$WIDE" --lift whole --title "$TITLE" --kicker "pitch.dog · Series A" --out "$OUT/room/whole"
"$LAB" render --slide "$COVER" --more "$WIDE,$REVISED" --melt 2 --home --marks demo --lift 9-16 --quality good \
  --out "$OUT/slides/slides-marks-and-room-good.mp4"
render_set wide-slides --slide "$COVER" --more "$WIDE,$REVISED" --melt 2 --home
render_set wide-room --slide "$WIDE" --lift 5-12,16- --title "$TITLE" --kicker "pitch.dog · Series A"
render_set wide-png --slide "$OUT/fixtures/wide-2576x1080.png"
render_set standard-png --slide "$OUT/fixtures/standard-1920x1080.png"
render_set wide-pdf --slide "$OUT/fixtures/wide.pdf"
render_set wide-png-2x --slide "$OUT/fixtures/wide-5152x2160.png"

echo "== A live take: presses at the moments a presenter makes them, and you in the room"
mkdir -p "$OUT/live"
LIVE=(--slide "$COVER" --more "$WIDE" --live "3.2,7,10.5,14,18@0.72:0.5,21.5,25b,28.5,32,35.5" --live-end 39)
"$LAB" live "${LIVE[@]}" --out "$OUT/live" | tee "$OUT/live/live.txt"
"$LAB" sheet "${LIVE[@]}" --out "$OUT/live/sheet.png"
"$LAB" motioncheck "${LIVE[@]}" | tee "$OUT/live/motion.txt"
"$LAB" render "${LIVE[@]}" --quality draft --scale 0.5 --out "$OUT/live/draft.mp4"
"$LAB" live --slide "$WIDE" --live "4,9,13w,17" --live-end 21 --voice-only | tee "$OUT/live/voice-only.txt"
"$LAB" live --slide "$WIDE" --live "4,9,13" --live-end 17 --green-screen --out "$OUT/live/green-screen" | tee "$OUT/live/green-screen.txt"

echo "== Replace Slide: the wide tour, moved onto the corrected slide"
mkdir -p "$OUT/replace"
"$LAB" plan --slide "$OUT/fixtures/wide-2576x1080.png" | tee "$OUT/replace/before.txt"
"$LAB" plan --slide "$OUT/fixtures/wide-2576x1080.png" --replace "$OUT/fixtures/wide-revised-2576x1080.png" | tee "$OUT/replace/after.txt"
"$LAB" landings --slide "$OUT/fixtures/wide-2576x1080.png" --replace "$OUT/fixtures/wide-revised-2576x1080.png" --out "$OUT/replace/landings"

echo "== Save Stills"
"$LAB" stills --slide "$OUT/fixtures/wide-2576x1080.png" --out "$OUT/wide-png/stills"

echo "== The loop back to the first frame (Leave ending)"
"$LAB" loopcheck --slide "$OUT/fixtures/wide-2576x1080.png" --ending leave | tee "$OUT/loop.txt"
"$LAB" render --slide "$OUT/fixtures/wide-2576x1080.png" --ending leave --quality draft --scale 0.5 --out "$OUT/wide-png/leave-draft.mp4"

echo "== Export timings (full size, Good)"
TMP="$(mktemp -d)"
{
  "$LAB" render --quality good --out "$TMP/sample.mp4" | tail -1 | sed "s|^|sample: |"
  "$LAB" render --slide "$OUT/fixtures/wide-2576x1080.png" --quality good --out "$OUT/wide-png/good.mp4" | tail -1 | sed "s|^|wide-png: |"
  "$LAB" render --slide "$OUT/fixtures/wide.pdf" --quality good --out "$TMP/wide-pdf.mp4" | tail -1 | sed "s|^|wide-pdf: |"
} | tee "$OUT/timings.txt"

echo "== Bench and colour, on the wide picture"
"$LAB" bench --slide "$OUT/fixtures/wide-2576x1080.png" | tee "$OUT/bench.txt"
"$LAB" colorcheck --slide "$OUT/fixtures/wide-2576x1080.png" | tee "$OUT/color.txt"

echo "== Adaptive motion blur against full samples"
"$LAB" blurcheck --quality good > "$OUT/sample/blur-good.txt"
"$LAB" blurcheck --slide "$OUT/fixtures/wide-2576x1080.png" --quality good > "$OUT/wide-png/blur-good.txt"
"$LAB" blurcheck --slide "$OUT/fixtures/wide-2576x1080.png" --quality best > "$OUT/wide-png/blur-best.txt"
for f in "$OUT/sample/blur-good.txt" "$OUT/wide-png/blur-good.txt" "$OUT/wide-png/blur-best.txt"; do
  tail -1 "$f" | sed "s|^|$(basename "$(dirname "$f")"): |"
done | tee "$OUT/blur.txt"

echo "== Export timings with every frame at full samples (for comparison)"
{
  "$LAB" render --quality good --full-blur --out "$TMP/sample-full.mp4" | tail -1 | sed "s|^|sample: |"
  "$LAB" render --slide "$OUT/fixtures/wide-2576x1080.png" --quality good --full-blur --out "$TMP/wide-full.mp4" | tail -1 | sed "s|^|wide-png: |"
} | tee "$OUT/timings-full-blur.txt"

echo "== Summary"
{
  for name in sample wide-png standard-png wide-pdf wide-png-2x wide-slides wide-room; do
    dir="$OUT/$name"
    [ -d "$dir" ] || continue
    echo "$name:"
    grep -h 'read the slide in\|^opening:\|^picture' "$dir/plan.txt" | sed 's/^/  /'
    sed -n '/one part left out/,$p' "$dir/ink.txt" | sed 's/^/  /'
    grep -q 'one part left out' "$dir/ink.txt" || grep -h '^inkcheck' "$dir/ink.txt" | sed 's/^/  /'
    grep -h -A20 '^motioncheck' "$dir/motion.txt" | sed 's/^/  /'
  done
  echo "export timings (Good):"; sed 's/^/  /' "$OUT/timings.txt"
  echo "adaptive blur:"; sed 's/^/  /' "$OUT/blur.txt"
  echo "loop:"; tail -1 "$OUT/loop.txt" | sed 's/^/  /'
  echo "live:"; grep -h '^the video runs\|^live ok\|problem\|green screen' "$OUT/live/live.txt" "$OUT/live/voice-only.txt" "$OUT/live/green-screen.txt" | sed 's/^/  /'
  echo "bench:"; grep -v '^bench:' "$OUT/bench.txt" | sed 's/^/  /'
  echo "colour:"; grep -v '^colorcheck:' "$OUT/color.txt" | sed 's/^/  /'
} | tee "$OUT/summary.txt"

# No planned move may fly or turn past the limits, cut an emphasis short, or jump.
if grep -l 'problem(s)' "$OUT"/*/motion.txt; then
  echo "motioncheck found problems in the sets above"
  exit 1
fi
