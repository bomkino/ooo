# Changelog

## 0.2.0 — 6 October 2026

OOO's first public release, made for pitch.dog's everyday case: a wide slide (2576 × 1080 or 1920 × 1080) in a 1080 × 1920 reel.

**It updates itself**
- **In-app updates.** OOO checks this repository's releases once a day and offers new versions itself: read what's new, click **Install Update**, and it relaunches on the new version a few seconds later. **Check for Updates…** in the OOO menu checks now.
- **Safe without an Apple account.** Updates are signed with pitch.dog's own key, and the app refuses anything not signed with it.
- **Install this version by hand once.** Every version after it arrives by itself, with no second trip to Privacy & Security.

**The slide as it is**
- **Black type stays black while it is read.** Gloss's sheen and the lens's glow used to lift black ink to a mid-grey at every hold. Now the sheen steps back while the camera holds and the glow lights the room around the slide, not its face.
- **Close-ups are sharp to their corners:** depth of field focuses on a plane, as a lens does.
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
