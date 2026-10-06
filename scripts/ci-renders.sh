#!/bin/bash
# Renders OOO's review set on the macOS runner: test slides drawn at the sizes
# pitch.dog designs at (2576 × 1080 and 1920 × 1080, as pictures and as a
# PDF), each taken through the app's journey (read, Direct for Me, render) in
# a 1080 × 1920 reel, plus the vector sample. For each slide: the director's
# plan, a contact sheet, a still at the opening and at every landing, the
# opening at five angles and three floors, and a draft video. Then export
# timings.
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
  "$LAB" sheet "$@" --out "$dir/sheet.png"
  "$LAB" landings "$@" --out "$dir/landings"
  "$LAB" openings "$@" --out "$dir/openings.png"
  "$LAB" render "$@" --quality draft --scale 0.5 --out "$dir/draft.mp4"
}

render_set sample
render_set wide-png --slide "$OUT/fixtures/wide-2576x1080.png"
render_set standard-png --slide "$OUT/fixtures/standard-1920x1080.png"
render_set wide-pdf --slide "$OUT/fixtures/wide.pdf"
render_set wide-png-2x --slide "$OUT/fixtures/wide-5152x2160.png"

echo "== Export timings (full size, Good)"
TMP="$(mktemp -d)"
{
  "$LAB" render --quality good --out "$TMP/sample.mp4" | tail -1 | sed "s|^|sample: |"
  "$LAB" render --slide "$OUT/fixtures/wide-2576x1080.png" --quality good --out "$OUT/wide-png/good.mp4" | tail -1 | sed "s|^|wide-png: |"
  "$LAB" render --slide "$OUT/fixtures/wide.pdf" --quality good --out "$TMP/wide-pdf.mp4" | tail -1 | sed "s|^|wide-pdf: |"
} | tee "$OUT/timings.txt"
