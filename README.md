# OOO · Obsess Over One

One slide. One camera. All the love.

OOO turns a single slide into a short film about it. The slide arrives, beautifully. Then a camera flies over it in 3D, landing on one detail after another, timed to your voice. You export a video, 1080 × 1920 by default, and post it.

It is for the slide you spent a week on: the chart whose curve you redrew eleven times, the footnote in 4-point type, the kerning nobody will notice. OOO is how you show them you noticed.

**Free and open source · Apple silicon · macOS 14 or later · unsigned**

---

## How it works

1. **Drop a slide, or paste one.** A PDF page or a picture, or a slide copied straight from Keynote, Figma or Preview (⇧⌘V). PDFs stay vector, so the camera can go as close as it likes and text stays razor sharp. Pictures are drawn at up to twice their size, resampled and sharpened, and the camera never goes closer than they hold.
2. **It arrives.** Rise, Unfold, Drop, Develop, Turn, Glide or Weave: an entrance with weight, light and focus. Develop comes up like a print in the tray, darks first; Weave knits the slide together from threads, the same way in every export. In a tall frame a wide slide stands turned towards you, over a soft reflection, with a title above it if you give it one.
3. **The camera tours it.** *Direct for Me* reads the slide on your Mac (the headline, the numbers, the figure, the small print) and plans a tour: the headline first, the details worth stopping on in reading order, the smallest print saved for last. Each hold lasts as long as its words take to read, and the slide's point holds longest. Text is framed at a size that reads on a phone; a line too long for the frame is read along, the camera landing on its start and gliding to its end. Every framing sits in the part of a Reel that the profile and caption leave clear.
4. **Talk about it.** Record a scratch take right in OOO (⌥⌘R), talking along as the video plays, or record your voiceover in any app and drop it in. OOO listens on your Mac for the words and when you say them, and lands each move just before you name what it shows. When your words come faster than a move can fly, the camera cuts on the word rather than rushing.
5. **Set the room.** 35 looks from Backdrop, each with its own dials and a Shuffle, or the room in the slide's own colours (From Slide), kept at the room's lightness so the slide still stands out. The slide's surface can be Original, Print, Gloss, Satin or Foil; hold `\` to compare with the slide exactly as supplied.
6. **Export.** MP4, HEVC or ProRes, at 24, 30 or 60 fps, with real motion blur and your voice under it. Save Cover Frame (⌥⌘E) gives you the post's thumbnail, and Save Stills (⇧⌘E) the opening and every landing as pictures, for a carousel.

**More than one slide?** Add Slide (⌃⌘I), or drop several at once, and the same card in your hand goes through them: it turns over to the next slide, or the next melts in where you're looking while whatever the two share holds still. Open on your deck's cover, follow a number from one slide to the next, and turn back to the first at the end.

**Point at something.** Click Draw under the video (⇧⌘P) and circle a number or underline a word with one fine pen. Its ink lies like watercolour: the slide shows through it, and it gathers at the edges and feathers a hair as it dries. In the video the mark draws on just as your hand drew it, then stays until the slide changes or fades a moment later.

**Leave room for you.** Room for You lifts the stage into the top of the frame for as long as you choose, leaving the bottom clear for your talking head in Edits or Premiere.

**Fixed a typo after the tour was made?** Replace Slide (⇧⌘I) swaps in the corrected slide and keeps the camera work: each framing follows its words to where they are now, and a shot named after its words takes the new ones. Change the canvas and the framings Direct for Me planned are framed again for it; the ones you set stay where you put them.

## Every move is yours

The slide map shows every framing as a viewfinder the shape of your video: drag one to move it, drag a corner to go closer, Option-drag to turn the camera, draw a box on the slide to add one. Whenever the window has room beside the video (always for a tall video, and for a square one in a wide window), the map sits there, as big as the room allows; otherwise it sits at the top of the inspector. Drag the edge between the map and the video to give either more room, or press ⇧⌘M to keep the map in the inspector. On the timeline, drag a framing to change when the camera lands; it snaps to your words. Esc cancels a drag halfway. In the inspector, double-click any value to type it, and a run of arrow presses is one undo.

| Keys | |
|---|---|
| ⌘I, ⇧⌘I, ⇧⌘V | Choose a slide, replace it keeping the tour, paste one |
| ⌥⌘I, ⌥⌘R | Choose a voiceover, record a scratch take |
| ⌃⌘I | Add slides after the last |
| ⇧⌘P, Return | Draw on the slide, and put the pen away |
| ⇧⌘D | Direct for Me |
| ⌥⌘V | Cut moves to the voice |
| ⇧⌘N, ⌘D, Delete | New shot at the playhead, duplicate it, delete it |
| ⌥⌘ arrows | Move the selected framing |
| ⌥⌘= and ⌥⌘− | Closer and wider |
| ⌥⌘[ and ⌥⌘] | Land a tenth of a second earlier or later |
| Space or ⌘P | Play and pause |
| ⌘[ and ⌘] | Previous and next landing; ⌘← goes to the start |
| hold `\` | The slide exactly as supplied (the Original surface) |
| ⇧⌘M | The slide map beside the video, or in the inspector |
| ⇧⌘G | Show the safe areas |
| ⌘E, ⌥⌘E, ⇧⌘E | Export, Save Cover Frame, Save Stills |

With Reduce Motion on, the editor doesn't start playing by itself, and Direct for Me's button glows without pulsing. The films you export move as they always do.

## The craft

The motion is the point, so it is built carefully.

- **Optimal camera paths.** Moves between details follow van Wijk and Nuij's optimal zoom-and-pan path, the curve that rises just enough to see where it is going, then sweeps in. Scale is always interpolated in log space, so a 10× zoom feels as even as a 2× one.
- **Eases that never stop dead.** Each ease is the integral of a bell-shaped speed curve: it lifts off with no jolt and still carries a little speed when it lands. The hold that follows takes in the last of that momentum and slows steadily to rest, then breathes, a slow push-in, so a held frame is never frozen.
- **Speed limits.** A move timed for you never outruns 2.6 e-folds of scale a second at its peak, and every interval keeps part of its time still, so each detail is seen, not just passed.
- **Composed for the canvas.** A framing seen at an angle is not the rectangle a flat view assumes, so the camera's distance and aim are solved against the framing's real outline on screen, and fitted into the part of the canvas no app interface covers.
- **Sharp at any zoom.** The whole slide lives in one texture; when the camera needs more, the part it sees is drawn again from the slide's vectors at the resolution that frame needs, snapped to a half-octave ladder so neighbouring frames share it, and drawn half a second before the frame needs it.
- **The slide as it is, while it is read.** When the camera holds, the surface's sheen steps back and the lens's glow stays in the room around the slide, so black type lands nearly as dark as it is on the slide. The sheen comes back as the camera moves on.
- **A real lens.** Depth of field focuses on a plane through the framed point, as a lens does, and deepens as the camera goes in, so a close-up becomes a macro shot. Motion blur is a 180° film shutter, averaged from many moments a frame, and never smears across a cut. Each frame measures how far anything on screen moves while its shutter is open and takes only the moments that motion needs: one while the camera holds, the most in a fast move. On the review renders that saves a third or more of the GPU's work at Good and over half at Best, and no frame falls below 48 dB PSNR against full sampling.
- **Made to loop.** A Reel plays on repeat, so the backdrop runs whole cycles over the video's length and, with the Leave ending, drifts back to where it began: the last frame leads into the first.
- **Time to look.** Every move gets the time its distance needs, and a turn counts towards its speed as much as a pan does. Without a voice, the holds follow how much there is to read; with one, a move that can't make it in time becomes a cut on the word. Each emphasis fits its hold, and only one detail gets the strongest.
- **A director that reads.** Vision reads the slide in one pass, drawn tall enough that the 4-point footnote is found too; the ink that is not text shows where the figures are. The director groups lines into blocks, gives each a role and plans the tour. With a voiceover, each shot lands 150 ms before the words that name it. The reading is kept in the document, so it is never repeated.

## Private

Everything runs on your Mac: reading the slide, listening to your voice (on-device speech recognition only), rendering and export. Nothing is uploaded. The only thing OOO fetches is its own updates.

## Install

Download the disk image (`OOO-x.y.z-macOS-arm64.dmg`) from the [latest release](https://github.com/bomkino/ooo/releases/latest), open it and drag OOO onto Applications. If macOS offers to install the app for you and then says "Could not install", click OK and drag it instead: macOS only installs that way for apps notarized by Apple. A ZIP of the app is on the release page too.

OOO is signed ad hoc and not notarized, so the first time you open it, macOS stops it. Open System Settings › Privacy & Security, scroll down and click **Open Anyway** (Control-click › Open no longer works from macOS Sequoia on). A copy downloaded from Terminal opens straight away, because nothing marks it as downloaded from the web:

```bash
gh release download -R bomkino/ooo -p 'OOO-*-macOS-arm64.zip' && ditto -x -k OOO-*-macOS-arm64.zip /Applications
```

## Updates

OOO checks this repository's releases once a day and offers new versions itself (**Check for Updates…** in the OOO menu checks now). An update installs and relaunches in a few seconds, with no second trip to Privacy & Security. Updates are signed with pitch.dog's own EdDSA key and OOO refuses anything not signed with it; no Apple developer account is involved. Install OOO by hand once (0.2.0 or later), and every version after it arrives by itself. How releases are made and signed is in [`docs/UPDATES.md`](docs/UPDATES.md).

## Build it yourself

```bash
swift build -c release && swift run -c release OOO
```

Needs Xcode or the Command Line Tools on an Apple silicon Mac with macOS 14 or later. Tests, the headless renders and checks (`ooo-lab`), CI and the source layout are in [`docs/DEVELOPING.md`](docs/DEVELOPING.md).

## Rights

OOO is free software under the GNU Affero General Public License 3.0 (`LICENSE`). No fonts are bundled; the interface uses the system font and the sample slide uses faces that ship with macOS. Third-party notices are in `NOTICES.md`; the pitch.dog name and marks are covered by `TRADEMARKS.md`.

Made by [pitch.dog](https://pitch.dog), for everyone who cares about one slide more than is reasonable.
