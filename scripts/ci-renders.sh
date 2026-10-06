#!/bin/bash
# Renders OOO's review set on the macOS runner: test slides drawn at the sizes
# pitch.dog designs at (2576 × 1080 and 1920 × 1080, as pictures and as a
# PDF), each taken through the app's journey (read, Direct for Me, render) in
# a 1080 × 1920 reel, plus the vector sample. For each slide: the director's
# plan, a contact sheet, a still at the opening and at every landing, the
# opening at five angles and three floors, how dark its type lands against
# the slide as supplied, how its moves fly (motioncheck), and a draft video.
# Then the titles, every backdrop look, every arrival (Weave and Develop also
# as draft videos), export timings, and summary.txt with the numbers that
# matter. Fails when motioncheck finds a problem in any set.
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
"$LAB" fixture --kind standard --out "$OUT/fixtures/standard-1920x1080.png"
"$LAB" fixture --kind wide --out "$OUT/fixtures/wide.pdf"
"$LAB" fixture --kind wide --scale 2 --out "$OUT/fixtures/wide-5152x2160.png"

render_set() {
  local name="$1"; shift
  local dir="$OUT/$name"
  mkdir -p "$dir"
  echo "== $name"
  "$LAB" analyze "$@" | tee "$dir/plan.txt"
  "$LAB" readcheck "$@" | tee "$dir/read.txt"
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
render_set wide-png --slide "$OUT/fixtures/wide-2576x1080.png"
render_set standard-png --slide "$OUT/fixtures/standard-1920x1080.png"
render_set wide-pdf --slide "$OUT/fixtures/wide.pdf"
render_set wide-png-2x --slide "$OUT/fixtures/wide-5152x2160.png"

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
  for name in sample wide-png standard-png wide-pdf wide-png-2x; do
    dir="$OUT/$name"
    [ -d "$dir" ] || continue
    echo "$name:"
    grep -h 'read the slide in\|^opening:\|^picture' "$dir/plan.txt" | sed 's/^/  /'
    grep -h '^readcheck\|^tours differ\|only with close-ups' "$dir/read.txt" | sed 's/^/  /'
    sed -n '/one part left out/,$p' "$dir/ink.txt" | sed 's/^/  /'
    grep -q 'one part left out' "$dir/ink.txt" || grep -h '^inkcheck' "$dir/ink.txt" | sed 's/^/  /'
    grep -h -A20 '^motioncheck' "$dir/motion.txt" | sed 's/^/  /'
  done
  echo "export timings (Good):"; sed 's/^/  /' "$OUT/timings.txt"
  echo "adaptive blur:"; sed 's/^/  /' "$OUT/blur.txt"
  echo "loop:"; tail -1 "$OUT/loop.txt" | sed 's/^/  /'
} | tee "$OUT/summary.txt"

# No planned move may fly or turn past the limits, cut an emphasis short, or jump.
if grep -l 'problem(s)' "$OUT"/*/motion.txt; then
  echo "motioncheck found problems in the sets above"
  exit 1
fi
