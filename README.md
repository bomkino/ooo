# OOO · Obsess Over One

One slide. One camera. All the love.

OOO turns a single slide into a short film about it. The slide arrives, beautifully. Then a camera flies over it in 3D, landing on one detail after another, timed to your voice. You export a video, 1080 × 1920 by default, and post it.

It is for the slide you spent a week on: the chart whose curve you redrew eleven times, the footnote in 4-point type, the kerning nobody will notice. OOO is how you show them you noticed.

**Free and open source · Apple silicon · macOS 14 or later · unsigned**

---

## How it works

1. **Drop a slide, or paste one.** A PDF page or a picture, or a slide copied straight from Keynote, Figma or Preview (⇧⌘V). PDFs stay vector, so the camera can go as close as it likes and text stays razor sharp. Pictures are drawn at up to twice their size, resampled and sharpened, and the camera never goes closer than they hold.
2. **It arrives.** Rise, Unfold, Drop, Develop, Turn or Glide: an entrance with weight, light and focus. In a tall frame a wide slide stands turned towards you, over a soft reflection, with a title above it if you give it one.
3. **The camera tours it.** *Direct for Me* reads the slide on your Mac (the headline, the numbers, the figure, the small print) and plans a tour: the headline first, the details worth stopping on in reading order, the smallest print saved for last. Text is framed at a size that reads on a phone; a line too long for the frame is read along, the camera landing on its start and gliding to its end. Every framing sits in the part of a Reel that the profile and caption leave clear.
4. **Talk about it.** Record your voiceover first, in any app, and drop it in. OOO listens on your Mac for the words and when you say them, and lands each move just before you name what it shows.
5. **Export.** MP4, HEVC or ProRes, at 24, 30 or 60 fps, with real motion blur and your voice under it. Save Cover Frame (⌥⌘E) gives you the post's thumbnail.

Every move is yours to change. The slide map in the inspector shows every framing as a viewfinder the shape of your video: drag one to move it, drag a corner to go closer, Option-drag to turn the camera, draw on the slide to add one. On the timeline, drag a framing to change when the camera lands; it snaps to your words.

## The craft

The motion is the point, so it is built carefully.

- **Optimal camera paths.** Moves between details follow van Wijk and Nuij's optimal zoom-and-pan path, the curve that rises just enough to see where it is going, then sweeps in. Scale is always interpolated in log space, so a 10× zoom feels as even as a 2× one.
- **Eases that never stop dead.** Each ease is the integral of a bell-shaped speed curve: it lifts off with no jolt and still carries a little speed when it lands. The hold that follows takes in the last of that momentum and slows steadily to rest, then breathes, a slow push-in, so a held frame is never frozen.
- **Speed limits.** A move timed for you never outruns 2.6 e-folds of scale a second at its peak, and every interval keeps part of its time still, so each detail is seen, not just passed.
- **Composed for the canvas.** A framing seen at an angle is not the rectangle a flat view assumes, so the camera's distance and aim are solved against the framing's real outline on screen, and fitted into the part of the canvas no app interface covers.
- **Sharp at any zoom.** The whole slide lives in one texture; when the camera needs more, the part it sees is drawn again from the slide's vectors at the resolution that frame needs, snapped to a half-octave ladder so neighbouring frames share it, and drawn half a second before the frame needs it.
- **The slide as it is, while it is read.** When the camera holds, the surface's sheen steps back and the lens's glow stays in the room around the slide, so black type lands as dark as it is on the slide. The sheen comes back as the camera moves on.
- **A real lens.** Depth of field focuses on a plane through the framed point, as a lens does, and deepens as the camera goes in, so a close-up becomes a macro shot. Motion blur is a 180° film shutter, averaged from many moments a frame, and never smears across a cut. Each frame measures how far anything on screen moves while its shutter is open and takes only the moments that motion needs: one while the camera holds, the most in a fast move. On the review renders that saves about a third of the GPU's work at Good and over half at Best, and no frame falls below 49 dB PSNR against full sampling.
- **Made to loop.** A Reel plays on repeat, so the backdrop runs whole cycles over the video's length and, with the Leave ending, drifts back to where it began: the last frame leads into the first.
- **A director that reads.** Vision reads the text, then reads the slide again in close-ups so the 4-point footnote is found too; the ink that is not text shows where the figures are. The director groups lines into blocks, gives each a role and plans the tour. With a voiceover, each shot lands 150 ms before the words that name it.

Everything runs on your Mac. Nothing is uploaded. The only thing OOO fetches is its own updates.

## Install

Download the disk image (`OOO-x.y.z-macOS-arm64.dmg`) from the [latest release](https://github.com/bomkino/ooo/releases/latest), open it and drag OOO onto Applications. If macOS offers to install the app for you and then says "Could not install", click OK and drag it instead: macOS only installs that way for apps notarized by Apple. A ZIP of the app is on the release page too.

OOO is signed ad hoc and not notarized, so the first time you open it, macOS stops it. Open System Settings › Privacy & Security, scroll down and click **Open Anyway** (Control-click › Open no longer works from macOS Sequoia on). A copy downloaded from Terminal opens straight away, because nothing marks it as downloaded from the web:

```bash
gh release download -R bomkino/ooo -p 'OOO-*-macOS-arm64.zip' && ditto -x -k OOO-*-macOS-arm64.zip /Applications
```

## Updates

From 0.2.0, OOO checks this repository's releases once a day and offers new versions itself (**Check for Updates…** in the OOO menu checks now). An update installs and relaunches in a few seconds, with no second trip to Privacy & Security. Updates are signed with pitch.dog's own EdDSA key and OOO refuses anything not signed with it; no Apple developer account is involved. Install 0.2.0 by hand once, and every version after it arrives by itself. How releases are made and signed is in [`docs/UPDATES.md`](docs/UPDATES.md).

## Build

Needs Xcode or the Command Line Tools on an Apple silicon Mac with macOS 14 or later.

```bash
swift build -c release          # everything
swift test                      # the camera's maths, the director, documents and the renderer
swift run -c release OOO        # the app, unbundled
bash scripts/build-app.sh       # dist/OOO.app and dist/OOO.dmg
bash scripts/test-update.sh     # in-app updates: a signed one installs, a tampered one is refused
```

The first build fetches Sparkle 2.10.0 through Swift Package Manager. `bash scripts/make-release.sh <folder> [notes.md]` then makes a release's disk image, update ZIP, signed `appcast.xml` and checksums (see [`docs/UPDATES.md`](docs/UPDATES.md)).

## Headless checks

`ooo-lab` renders and checks without a window, for review and CI:

```bash
swift run -c release ooo-lab shaders                       # compile every shader and pipeline
swift run -c release ooo-lab still --t 6.6 --out still.png # one frame
swift run -c release ooo-lab sheet --out sheet.png         # twelve frames across the video
swift run -c release ooo-lab render --quality draft --scale 0.5 --out draft.mp4
swift run -c release ooo-lab analyze                       # what the director reads and plans
swift run -c release ooo-lab landings --out dir            # a still at the opening and at every landing
swift run -c release ooo-lab openings --out grid.png       # the opening at five angles and three floors
swift run -c release ooo-lab titles --title "…" --out t.png # the opening title in four faces, and in time
swift run -c release ooo-lab blurcheck --quality good      # adaptive motion blur against full sampling
swift run -c release ooo-lab inkcheck                      # how dark the type lands at every hold, against the slide
swift run -c release ooo-lab loopcheck --ending leave      # the step from the last frame back to the first
swift run -c release ooo-lab path --out path.csv           # the camera's path, sampled at 120 Hz
swift run -c release ooo-lab fixture --kind wide --out wide.png # a 2576 × 1080 test slide
```

Every command takes `--project file.ooo` (the sample by default) or `--slide file.pdf|png` (read and directed as the app does on a drop), `--format reel|portrait|square|landscape|uhd`, `--floor none|soft|mirror`, `--ending hold|pullBack|fade|leave` and `--title "…"`. `scripts/ci-renders.sh` renders the review set CI keeps for every change: pitch.dog's real case, wide slides as pictures and PDFs in a 1080 × 1920 reel.

## Layout

| Module | Job |
|---|---|
| `Sources/RenderCore` | Metal context, colour science, finishing (bloom, grade, vignette, grain, dither), readback and video writing |
| `Sources/BackdropKit` | 35 analytic, loopable background looks (Backdrop 2.0) |
| `Sources/StageKit` | The card renderer: bends, surfaces, depth of field, analytic shadows, motion blur |
| `Sources/OOOMotion` | The camera's maths, the arrivals, the choreography and the director, in plain Swift that tests anywhere |
| `Sources/OOOCore` | The slide (PDF, picture, sample), sharp detail at any zoom, the voiceover and its words, slide analysis, rendering and export |
| `Sources/OOOStudio` | The editor: live stage, slide map, timeline, inspector, export |
| `Sources/Updates` | In-app updates from this repository's releases (Sparkle), shared with Drift |
| `Sources/OOOApp` | The app |
| `Sources/OOOLab` | `ooo-lab`, headless renders and checks |

RenderCore, BackdropKit and StageKit are the pitch.dog Studio engine shared with [Drift and Galileo](https://github.com/bomkino/pitchdog-drift) and [Backdrop](https://github.com/bomkino/backdrop), extended here for OOO. See `NOTICES.md`.

## Rights

OOO is free software under the GNU Affero General Public License 3.0 (`LICENSE`). No fonts are bundled; the interface uses the system font and the sample slide uses faces that ship with macOS. Third-party notices are in `NOTICES.md`; the pitch.dog name and marks are covered by `TRADEMARKS.md`.

Made by [pitch.dog](https://pitch.dog), for everyone who cares about one slide more than is reasonable.
