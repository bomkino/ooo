# Developing OOO

## Build

Needs Xcode or the Command Line Tools on an Apple silicon Mac with macOS 14 or later.

```bash
swift build -c release          # everything
swift test                      # the camera's maths, the director, documents and the renderer
swift run -c release OOO        # the app, unbundled
bash scripts/build-app.sh       # dist/OOO.app and dist/OOO.dmg
bash scripts/test-update.sh     # in-app updates: a signed one installs, a tampered one is refused
```

The first build fetches Sparkle 2.10.0 through Swift Package Manager. `OOOMotion` (the camera, the arrivals, the choreography and the director) is plain Swift, so its tests also run on Linux.

## Headless checks

`ooo-lab` renders and checks without a window, for review and CI:

```bash
swift run -c release ooo-lab shaders                       # compile every shader and pipeline
swift run -c release ooo-lab still --t 6.6 --out still.png # one frame
swift run -c release ooo-lab sheet --out sheet.png         # twelve frames across the video
swift run -c release ooo-lab render --quality draft --scale 0.5 --out draft.mp4
swift run -c release ooo-lab analyze                       # what the director reads and plans
swift run -c release ooo-lab plan                          # the tour as it stands
swift run -c release ooo-lab landings --out dir            # a still at the opening and at every landing
swift run -c release ooo-lab stills --out dir              # what Save Stills writes
swift run -c release ooo-lab openings --out grid.png       # the opening at five angles and three floors
swift run -c release ooo-lab titles --title "…" --out t.png # the opening title in four faces, and in time
swift run -c release ooo-lab backdrops --out grid.png      # every look behind the opening, as itself and From Slide
swift run -c release ooo-lab arrivals --out grid.png       # each arrival at five moments of its entrance
swift run -c release ooo-lab motioncheck                   # each move's speed and turn, each emphasis, any jump
swift run -c release ooo-lab blurcheck --quality good      # adaptive motion blur against full sampling
swift run -c release ooo-lab inkcheck                      # how dark the type lands at every hold, against the slide
swift run -c release ooo-lab loopcheck --ending leave      # the step from the last frame back to the first
swift run -c release ooo-lab bench                         # export and preview timings (p50, p95, p99), with the machine
swift run -c release ooo-lab colorcheck                    # how the slide's colour survives the encoder
swift run -c release ooo-lab path --out path.csv           # the camera's path, sampled at 120 Hz
swift run -c release ooo-lab fixture --kind wide --out wide.png # a 2576 × 1080 test slide (also standard, wide-revised)
swift run -c release ooo-lab live --live "4,8,12.5b" --out dir # a live take: each press, the end, and a stand-in for you in the room
```

Every command takes `--project file.ooo` (the sample by default) or `--slide file.pdf|png` (read and directed as the app does on a drop) with `--replace file` (then Replace Slide with it), `--format reel|portrait|square|landscape|uhd`, `--floor none|soft|mirror`, `--ending hold|pullBack|fade|leave`, `--arrive rise|unfold|drop|develop|turn|glide|weave|none` and `--title "…"` (with `--kicker "…"`, `--kicker-as-typed` and `--face`). `--live "4,8,12.5b,15w,17@0.7:0.55"` (with `--live-end` and `--voice-only`) plays a live take on any of them first: each time a press to the next stop, `b` back, `w` the whole slide, `@u:v` a click on the slide, filmed by a stand-in recording, since CI's Mac has no camera.

The app has a headless mode too, for screenshots of the real window: `OOO --snapshot out.png [--scheme light] [--slide file] [--tab look] [--shot 2] [--show-export]` (all the flags are in `Sources/OOOStudio/Snapshot.swift`).

## CI

`.github/workflows/build.yml` runs on every push and pull request, on GitHub's macOS 26 runner:

1. builds, runs the tests and compiles every shader;
2. `scripts/ci-renders.sh`: the review set, which is pitch.dog's real case (wide slides as pictures and PDFs in a 1080 × 1920 reel) taken through the app's journey: the director's plan, the read against close-ups, a contact sheet, every landing, the openings, the ink check, the motion check (which fails the build on a problem), draft videos, every look and arrival, Replace Slide on a corrected slide, Save Stills, export timings and `summary.txt`;
3. packages the app, screenshots the editor with `scripts/ci-screens.sh`, and runs `scripts/test-update.sh`.

`scripts/ci-screens.sh` also runs the soak test (`OOO --snapshot … --soak 45`, in `Sources/OOOStudio/Soak.swift`): it films a stand-in take, keeps it, then plays, scrubs and scrolls it in Live and Frame, and fails if the window stops answering or its memory runs away. The stand-in take claps now and then (a white frame and a click at the same moment), and once it is kept, `Sources/OOOStudio/SyncCheck.swift` finds each clap in the voice OOO kept and in an exported video's picture and sound; any more than a frame off fails it. The screenshot step doesn't fail the build, so read the `soak:` and `sync:` lines in its log.

The renders, screens and app are kept as the run's artifacts.

## Releasing

`.github/workflows/release.yml` publishes a release from CI, its update signed by `scripts/sign-release.sh` with the key from the `release` environment. Both are described in [`UPDATES.md`](UPDATES.md).

## Layout

| Module | Job |
|---|---|
| `Sources/RenderCore` | Metal context, colour science, finishing (bloom, grade, vignette, grain, dither), readback and video writing |
| `Sources/BackdropKit` | 35 analytic, loopable background looks (Backdrop 2.0) |
| `Sources/StageKit` | The card renderer: bends, surfaces, depth of field, analytic shadows, motion blur |
| `Sources/OOOMotion` | The camera's maths, the arrivals, the choreography and the director, in plain Swift that tests anywhere |
| `Sources/OOOCore` | The slide (PDF, picture, sample), sharp detail at any zoom, the voiceover and its words, slide analysis, rendering, stills and export |
| `Sources/OOOStudio` | The editor: live stage, slide map, timeline, inspector, export, snapshots |
| `Sources/Updates` | In-app updates from this repository's releases (Sparkle), shared with Drift |
| `Sources/OOOApp` | The app |
| `Sources/OOOLab` | `ooo-lab`, headless renders and checks |

RenderCore, BackdropKit and StageKit are the pitch.dog Studio engine shared with [Drift and Galileo](https://github.com/bomkino/pitchdog-drift) and [Backdrop](https://github.com/bomkino/backdrop), extended here for OOO. See `NOTICES.md`.
