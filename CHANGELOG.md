# Changelog

## 0.3.0 — 6 October 2026 (not released on its own)

A milestone on the way to 1.0: every fix the 0.2.0 audit found, motion that never rushes, and the room and arrivals.

**The slide as it is**
- **Black type stays black.** What is left of a surface's light at rest stays off the ink, so on the wide test slide a headline lands at most 7 levels (of 255) above the slide as supplied, down from 18 in 0.2.0.
- **A larger wide opening.** A slide much wider than its canvas opens turned 44° with a 3% margin, so in a 1080 × 1920 reel it stands 29% of the frame's height (24% in 0.2.0). Documents from 0.2 keep following the canvas.
- **Close-ups keep their detail near the middle of the frame**, hanging past the slide's edge if they must, so the small print no longer lands low in the reel.
- **Lift's halo** follows a rounder outline, so its inner edge keeps round corners.
- **No ghost under the floor.** A reflection only mirrors what stands above the floor, so Glide and Rise no longer show an upside-down slide above them as they come up.

**Motion that never rushes**
- **Every move gets its time.** Turning counts towards the speed limit (no planned move turns faster than 40° a second at its peak), and no move outruns the zoom-and-pan limit at any pace. On every test slide, `motioncheck` now finds no problem; in 0.2.0 it found one or two on each.
- **Holds follow what there is to read**: about 0.3 s a word past the first four, more for numbers and figures, longest for the slide's point (its biggest number, else its figure, else its headline).
- **With a voice, a flight it leaves no time for becomes a cut on the word**, instead of a rush. A block is named by its own words, so "revenue grew" lands the headline and the row of numbers waits for "sixty-two".
- **Emphasis fits its hold**: quicker in a short one, never cut short, left out when there is no room. One emphasis peaks per tour, on the slide's point.
- **Glide arrives on a bow** and comes the last stretch straight on, squaring up as it settles. An opening title holds until the first move sets off.

**The room and the arrivals**
- **Every backdrop shows its own dials** (Horizon, Drift, Light, …) with that look's defaults, and **Shuffle** gives a new arrangement of the same look.
- **From Slide**: the room in the slide's own colours, at the room's own lightness, so the slide still stands out.
- **Weave**, a new arrival: the slide knits itself together from 24 threads that shoot across from alternate sides, the same way in every export.
- **Develop comes up like a print**: a blank sheet settles where it lies and the image comes up in it, the darks first.
- **The kicker** above an opening title can be set as typed, as well as in capitals.

**Faster, and checked**
- **Reading the slide is faster**: OOO reads the whole slide, then only its small print again, in close-ups drawn just around it, instead of every quarter of the slide.
- The editor fits a 1024-point-wide screen. "Busy" tracks every running job.
- CI now screenshots the real editor window (`OOO --snapshot`), fails on any `motioncheck` problem, measures ink like for like, and renders every look (`ooo-lab backdrops`), every arrival (`ooo-lab arrivals`) and the read against close-ups (`ooo-lab readcheck`).

## 0.2.0 — 6 October 2026

OOO's first public release, made for pitch.dog's everyday case: a wide slide (2576 × 1080 or 1920 × 1080) in a 1080 × 1920 reel.

**It updates itself**
- **In-app updates.** OOO checks this repository's releases once a day and offers new versions itself: read what's new, click **Install Update**, and it relaunches on the new version a few seconds later. **Check for Updates…** in the OOO menu checks now.
- **Safe without an Apple account.** Updates are signed with pitch.dog's own key, and the app refuses anything not signed with it.
- **Install this version by hand once.** Every version after it arrives by itself, with no second trip to Privacy & Security.

**The slide as it is**
- **Black type stays black while it is read.** Gloss's sheen and the lens's glow used to lift black ink to a mid-grey at every hold (a headline drawn at 20 of 255 landed at 97). Now the sheen steps back while the camera holds and the glow lights the room around the slide, not its face, so the same headline lands at 38.
- **Depth of field focuses on a plane**, as a lens does, rather than on a sphere around the camera.
- **The opening title's ink is chosen against the backdrop behind it**, so dark words never land on a dark top.
- Titles and the sample slide keep their fonts' own kerning.

**Safer**
- Exporting over an earlier video replaces it only once the new one is whole and checked. Cancelling, or a failure, leaves the old file as it was.
- A file from a newer OOO is refused with a message, rather than opened and exported without the settings this version can't read.
- Pictures with transparency are laid on a sheet, as PDFs are, so they show no dark fringes and Direct for Me reads dark artwork on them.

**Smoother**
- A dropped or pasted slide arrives once, when its tour is ready.
- The Leave ending no longer pops on its first frame, and with Leave a reel loops without a jump: the backdrop runs whole cycles and returns to where it began.
- The timeline holds its scale under the pointer while you drag a framing or the voice.
- Cut Moves to Voice no longer pins a framing you drew to a spoken number.
- Stills and Save Cover Frame match the exported frame exactly; error messages read as sentences; the stage stops drawing while it can't be seen.

**Made for the reel**
- **Composed for the canvas.** Framings are solved against their real outline at any angle and placed in the part of a Reel, Short or TikTok that the profile and caption leave clear. The opening turns a wide slide towards you in a tall frame, so it stands larger and with depth.
- **A floor.** None, Soft (new default) or Mirror: the empty half of a tall frame holds the slide's reflection.
- **An opening title.** Optional words above the slide, in four faces, that rise in as it lands and hold while they are read, clear as the camera goes in and come back for a Pull Back.
- **Read along.** Text is framed at a size that reads on a phone; a line too long for the frame is read by resting on its start, then gliding along it while the shot holds.
- **A better director.** Reading order, rows of numbers as one shot, captions kept with their numbers, a chart's title read with its chart, running headers and footers skipped, small print found as a sentence rather than a label, no second shot of a detail the last close-up already shows, and your voice deciding the order. Spoken numbers ("thirty-eight percent") match the digits on the slide.
- **Sharp pictures.** A picture is drawn at up to twice its size with a Lanczos resample and a light unsharp mask, Direct for Me never goes closer than that holds, and the status line says how close it stays sharp.
- **Softer emphasis.** Spotlight is a soft pool of light and the room dims with it; Lift raises the detail on a margin that fades into the slide.
- **Faster.** Adaptive motion blur (a third to a half less GPU work, no frame below 49 dB PSNR against full sampling), two frames in flight during export, close-ups drawn ahead in export and preview. On the same machine, Good exports take 29–47% less time than with full sampling. The stage stops redrawing when nothing changes.
- **Six new backdrops** from Backdrop 2.0: Solid, Linear, Radial, Conic, Caustics and Iridescence (35 in all).
- **The journey.** Paste a slide (⇧⌘V), Save Cover Frame (⌥⌘E), a dropped slide and its tour undo as one step, a new slide is always read afresh, the opening follows the canvas until you set it.
- **Fixes.** The Pull Back now lands and rests before the end. Speech recognition is on-device only, with a clear message when a language needs its dictation download.
- `ooo-lab`: `--slide`, test slide fixtures, `landings`, `openings`, `titles`, `blurcheck`, `inkcheck`, `loopcheck`, `--floor`, `--title`, `--ending`; CI renders the real case for every change and proves in-app updates. OOOCore tests run on the macOS runner.

## 0.1.0 (not released on its own)

The first OOO.

- One slide: a PDF page (redrawn from its vectors at every zoom) or a picture. New windows open on a sample slide, already moving.
- Six arrivals: Rise, Unfold, Drop, Develop, Turn and Glide.
- A 3D camera that lands on framings with optimal zoom-and-pan paths, four eases that settle instead of stopping, breathing holds, swing and a handheld drift; moves glide, push, arc or cut; details can be spotlit or lifted off the slide.
- Direct for Me: reads the slide on this Mac and plans a tour, headline first and small print last.
- Voiceover: on-device word timing, a waveform with words on the timeline, shots that snap to words, and Cut Moves to Voice.
- The slide map: every framing as a viewfinder you drag, resize, turn or draw.
- Export to MP4, HEVC or ProRes at 24, 30 or 60 fps with film motion blur, at half, full or double size.
- `ooo-lab` for headless stills, contact sheets, draft videos, analysis and camera paths.
