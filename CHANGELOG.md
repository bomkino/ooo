# Changelog

## 0.2.0 (unreleased)

Made for pitch.dog's everyday case: a wide slide (2576 × 1080 or 1920 × 1080) in a 1080 × 1920 reel.

- **Composed for the canvas.** Framings are solved against their real outline at any angle and placed in the part of a Reel, Short or TikTok that the profile and caption leave clear. The opening turns a wide slide towards you in a tall frame, so it stands larger and with depth.
- **A floor.** None, Soft (new default) or Mirror: the empty half of a tall frame holds the slide's reflection.
- **An opening title.** Optional words above the slide, in four faces, that rise in as it lands and hold while they are read, clear as the camera goes in and come back for a Pull Back.
- **Read along.** Text is framed at a size that reads on a phone; a line too long for the frame is read by gliding along it while the shot holds.
- **A better director.** Reading order, rows of numbers as one shot, captions kept with their numbers, a chart's title read with its chart, running headers and footers skipped, small print found as a sentence rather than a label, and your voice deciding the order. Spoken numbers ("thirty-eight percent") match the digits on the slide.
- **Sharp pictures.** A picture is drawn at up to twice its size with a Lanczos resample and a light unsharp mask, Direct for Me never goes closer than that holds, and the status line says how close it stays sharp.
- **Softer emphasis.** Spotlight is a soft pool of light and the room dims with it; Lift raises the detail on a margin that fades into the slide.
- **Faster.** Adaptive motion blur (a third to a half less GPU work, no frame below 49 dB PSNR against full sampling), two frames in flight during export, close-ups drawn ahead in export and preview. Good exports are 21–34% faster per second of video than 0.1. The stage stops redrawing when nothing changes.
- **Six new backdrops** from Backdrop 2.0: Solid, Linear, Radial, Conic, Caustics and Iridescence (35 in all).
- **The journey.** Paste a slide (⇧⌘V), Save Cover Frame (⌥⌘E), a dropped slide and its tour undo as one step, a new slide is always read afresh, the opening follows the canvas until you set it.
- **Fixes.** The Pull Back now lands and rests before the end. Speech recognition is on-device only, with a clear message when a language needs its dictation download.
- `ooo-lab`: `--slide`, test slide fixtures, `landings`, `openings`, `titles`, `blurcheck`, `--floor`, `--title`; CI renders the real case for every change. OOOCore tests run on the macOS runner.

## 0.1.0 (unreleased)

The first OOO.

- One slide: a PDF page (redrawn from its vectors at every zoom) or a picture. New windows open on a sample slide, already moving.
- Six arrivals: Rise, Unfold, Drop, Develop, Turn and Glide.
- A 3D camera that lands on framings with optimal zoom-and-pan paths, four eases that settle instead of stopping, breathing holds, swing and a handheld drift; moves glide, push, arc or cut; details can be spotlit or lifted off the slide.
- Direct for Me: reads the slide on this Mac and plans a tour, headline first and small print last.
- Voiceover: on-device word timing, a waveform with words on the timeline, shots that snap to words, and Cut Moves to Voice.
- The slide map: every framing as a viewfinder you drag, resize, turn or draw.
- Export to MP4, HEVC or ProRes at 24, 30 or 60 fps with film motion blur, at half, full or double size.
- `ooo-lab` for headless stills, contact sheets, draft videos, analysis and camera paths.
