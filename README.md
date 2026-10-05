# OOO · Obsess Over One

One slide. One camera. All the love.

OOO turns a single slide into a short film about it. The slide arrives, beautifully. Then a camera flies over it in 3D, landing on one detail after another, timed to your voice. You export a video, 1080 × 1920 by default, and post it.

It is for the slide you spent a week on: the chart whose curve you redrew eleven times, the footnote in 4-point type, the kerning nobody will notice. OOO is how you show them you noticed.

**Free and open source · Apple silicon · macOS 14 or later · unsigned**

---

## How it works

1. **Drop a slide.** A PDF page or a picture. PDFs stay vector, so the camera can go as close as it likes and text stays razor sharp.
2. **It arrives.** Rise, Unfold, Drop, Develop, Turn or Glide: an entrance with weight, light and focus.
3. **The camera tours it.** *Direct for Me* reads the slide on your Mac (the headline, the numbers, the figure, the small print) and plans a tour: the headline first, the details worth stopping on in reading order, the smallest print saved for last. Each framing is seen from the side that lets the rest of the slide fall softly out of focus.
4. **Talk about it.** Record your voiceover first, in any app, and drop it in. OOO listens on your Mac for the words and when you say them, and lands each move just before you name what it shows.
5. **Export.** MP4, HEVC or ProRes, at 24, 30 or 60 fps, with real motion blur and your voice under it.

Every move is yours to change. The slide map in the inspector shows every framing as a viewfinder the shape of your video: drag one to move it, drag a corner to go closer, Option-drag to turn the camera, draw on the slide to add one. On the timeline, drag a framing to change when the camera lands; it snaps to your words.

## The craft

The motion is the point, so it is built carefully.

- **Optimal camera paths.** Moves between details follow van Wijk and Nuij's optimal zoom-and-pan path, the curve that rises just enough to see where it is going, then sweeps in. Scale is always interpolated in log space, so a 10× zoom feels as even as a 2× one.
- **Eases that never stop dead.** Each ease is the integral of a bell-shaped speed curve: it lifts off with no jolt and still carries a little speed when it lands. The hold that follows takes in the last of that momentum and slows steadily to rest, then breathes, a slow push-in, so a held frame is never frozen.
- **Speed limits.** A move timed for you never outruns 2.6 e-folds of scale a second at its peak, and every interval keeps part of its time still, so each detail is seen, not just passed.
- **Sharp at any zoom.** The whole slide lives in one texture; when the camera needs more, the part it sees is drawn again from the slide's vectors at the resolution that frame needs, snapped to a half-octave ladder so neighbouring frames share it.
- **A real lens.** Depth of field follows the framed point and deepens as the camera goes in, so a close-up becomes a macro shot. Motion blur is a 180° film shutter, averaged from many moments a frame, and never smears across a cut.
- **A director that reads.** Vision finds the text and what draws the eye; the director groups lines into blocks, gives each a role and plans the tour. With a voiceover, each shot lands 150 ms before the words that name it.

Everything runs on your Mac. Nothing is uploaded.

## Install

Download `OOO.dmg` from the latest build or release, open it and drag OOO to Applications. OOO is ad-hoc signed and not notarized, so the first time, Control-click it and choose **Open** (or allow it under System Settings › Privacy & Security).

## Build

Needs Xcode or the Command Line Tools on an Apple silicon Mac with macOS 14 or later.

```bash
swift build -c release          # everything
swift test                      # the camera's maths and the director
swift run -c release OOO        # the app, unbundled
bash scripts/build-app.sh       # dist/OOO.app and dist/OOO.dmg
```

## Headless checks

`ooo-lab` renders and checks without a window, for review and CI:

```bash
swift run -c release ooo-lab shaders                       # compile every shader and pipeline
swift run -c release ooo-lab still --t 6.6 --out still.png # one frame
swift run -c release ooo-lab sheet --out sheet.png         # twelve frames across the video
swift run -c release ooo-lab render --quality draft --scale 0.5 --out draft.mp4
swift run -c release ooo-lab analyze                       # what the director reads and plans
swift run -c release ooo-lab path --out path.csv           # the camera's path, sampled at 120 Hz
```

Every command takes `--project file.ooo` (the sample by default) and `--format reel|portrait|square|landscape|uhd`.

## Layout

| Module | Job |
|---|---|
| `Sources/RenderCore` | Metal context, colour science, finishing (bloom, grade, vignette, grain, dither), readback and video writing |
| `Sources/BackdropKit` | 29 analytic, loopable background looks |
| `Sources/StageKit` | The card renderer: bends, surfaces, depth of field, analytic shadows, motion blur |
| `Sources/OOOMotion` | The camera's maths, the arrivals, the choreography and the director, in plain Swift that tests anywhere |
| `Sources/OOOCore` | The slide (PDF, picture, sample), sharp detail at any zoom, the voiceover and its words, slide analysis, rendering and export |
| `Sources/OOOStudio` | The editor: live stage, slide map, timeline, inspector, export |
| `Sources/OOOApp` | The app |
| `Sources/OOOLab` | `ooo-lab`, headless renders and checks |

RenderCore, BackdropKit and StageKit are the pitch.dog Studio engine shared with [Drift and Galileo](https://github.com/bomkino/pitchdog-drift) and [Backdrop](https://github.com/bomkino/backdrop), extended here for OOO. See `NOTICES.md`.

## Rights

OOO is free software under the GNU Affero General Public License 3.0 (`LICENSE`). No fonts are bundled; the interface uses the system font and the sample slide uses faces that ship with macOS. Third-party notices are in `NOTICES.md`; the pitch.dog name and marks are covered by `TRADEMARKS.md`.

Made by [pitch.dog](https://pitch.dog), for everyone who cares about one slide more than is reasonable.
