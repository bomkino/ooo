# Changelog

## 1.2.1 — 9 October 2026

- Going back to Frame after a live take no longer freezes OOO. The camera recording of you used to be decoded on the window's own thread, and started over from scratch at every step back while you scrubbed or scrolled the playhead, holding the whole window up and piling up memory until the Mac struggled too. It now decodes beside the window, a few frames ahead as the video plays, and after a jump starts over just once, for wherever you stopped. The window never waits for it.
- Choose your camera and microphone in the Live room: the camera menu beside Start lists every camera (the Mac's own, an iPhone, a USB camera) and every microphone, and switches at once. OOO remembers your choice.
- A green screen remover. Tick Green Screen Behind Me in that menu and the green goes from behind you, in the room as you film and in the video, so you stand in front of the backdrop itself, shadows on the screen included, with the green spill taken off your edges. A take already kept can switch it on or off afterwards, under Space for You or beside Play.
- The pen grows up. Draw's tray now has the pen and three shapes it draws for you, an arrow, a box and a circle: drag from where it starts to where it ends (⇧ for a square, a round circle or a straight arrow), and in the video it draws on as a hand would, never quite ruled. Four widths, from fine to bold. Six inks (green and blue join red, yellow, white and black) and a colour of your own.
- Say how long a mark stays. Marks that fade choose their stay, from half a second to eight, and on the timeline each one has a tail as long as it stays: drag its end to keep it longer or shorter, and its length is written on it.
- Right-click the stage while you draw, or during a live take with the pen out, for the same choices; right-click a mark for its colour, width and stay.
- Files that take out a green screen, or hold marks in the new inks, widths or stays, need OOO 1.2.1 to open.
- A retake lets go of the recording it replaces, instead of keeping both open.
- Once a take has put you in the space under the stage, the dashed outline of where you'll be stops drawing over you.
- CI now films a stand-in take, keeps it, plays it back in Live and in Frame, scrubs and scrolls it, and fails if the window stops answering or its memory runs away.

## 1.2.0 — 9 October 2026

OOO made for people: three modes you can always see, a timeline that says how long everything lasts and lets you stretch it, a slide map where drawing a new framing just works, and Live as a room you step into, check, start and close.

**Frame, Draw and Live**
- Three named modes sit in the middle of the toolbar: **Frame** (shape the tour), **Draw** (draw on the slide) and **Live** (talk it through while your Mac records you). ⌘1, ⌘2 and ⌘3 switch, Esc goes back to Frame, and you can always see which one you're in.
- Draw and Go Live were switched off in 1.1 by a bug, so neither could be used. Both work now.
- The line above the video coaches you in every mode: what the selected framing does and for how long, how to draw, what Live is waiting for.
- Right-click everywhere: the video, every clip on the timeline, every framing on the map, the slide itself and the voiceover each have a menu of what you'd do there.

**A timeline you can read and stretch**
- The tour is laid out as clips, edge to edge: the opening, each framing (its move, then its hold), the slide changes and the ending. Each part shows how long it lasts, and the video's length sits at the end of the ruler.
- Grab a clip's right edge to hold it longer or shorter, the line where it lands to make its move quicker or slower, or its middle to change when it lands. Everything after it slides along and keeps its own length, so nothing jumps. A bubble shows the new length as you drag; edges snap to tenths of a second and to the words of your voiceover (⌘ to move freely, ⌥ to let only the next clip give way).
- ⌘-drag a clip to put it before or after another, or right-click it for Move Earlier and Move Later. Double-click a clip to watch it.
- Pinch, or ⌘= and ⌘−, to zoom into the timeline; ⌘0 fits it again. Zoomed in, it follows the playhead.
- The inspector gains **Timing** for the selected shot: Move in and Hold, with Let OOO Choose.

**A slide map that draws**
- Each framing is one flat box of what the video shows there. Drag anywhere on the slide, even over other framings, to draw a new one, already in the video's shape. Click a framing to pick it.
- The picked framing has eight handles: corners go closer or wider from the opposite corner (⌥ from the middle), edges from the opposite side, and a readout shows how close it is. Drag inside it to move it, ⌥-drag to turn the camera, or drag any framing by its number tab. A turned camera says so on a small tag instead of drawing the box askew.
- The line under the map says what a press would do wherever the pointer is.

**Live, as a room**
- Live opens a room: the slide as the take will open, you in the space under it, your microphone level, and nothing recording until you press **Start**. Preview the opening and the closing, choose them in the inspector, and see every position the camera can go to in a strip under the video.
- While you talk, click a position in the strip or on the map, or press its number, to go straight there; → and Space go on, ← back, ↑ out to the whole slide, ↓ to the next slide.
- **Close** brings it to an end: the ending plays as the take finishes, and the recording runs to the last frame. Then Play, Retake or Done.

**Plainer words**
- Moves are Fly, Straight, Swing and Cut; their feel is Smooth, Even, Brisk or Lingering. Closer is Zoom, Focus falloff is Background blur, Breathe is Drift in, the Arrival is the Opening, and Room for You is Space for You.

## 1.1.0 — 9 October 2026

Go live: talk your video through and lead the camera yourself, filmed by your Mac into the room under the slide. And an editor that opens up, with the slide map beside the video and a pen that's easy to find.

**Go Live**
- **Go Live (⌥⌘L)**, or Go Live beside Draw under the video: OOO starts your Mac's own microphone and camera and shows you in the room under the slide, mirrored, so you can settle before the count of three. Then talk it through and lead the camera: → or Space to the next stop, ← back, ↑ out to the whole slide, or click a number, a line or the chart to look at it. At the last stop on a slide, the next press turns the card over or melts it to the next.
- Each move sets off the moment you press. Press while the camera is still on its way and it goes on as soon as it has landed; press again before then and it goes to the one after instead. A lit emphasis fades, and a line being read along is read to its end, before the camera leaves. While you talk, the camera holds still where you stopped it.
- Return (or Finish) keeps the take, one undo away: every move at the moment you made it, each hold given back its slow push-in and its read-along, your voice as the voiceover, its words heard for later, and you in the room until you finish, when you go as the stage settles and the ending plays. Draw with the pen during a take and the marks draw on in time.
- Your voice and your face are one recording from the Mac's camera and microphone, so they never drift apart. Turn off **Film Me in Live Takes** in the File menu for your voice only.
- OOO films with the camera macOS has chosen (the one picked under Video Effects in the menu bar, or your iPhone through Continuity Camera), never Desk View. The recording starts on a frame, and that frame's own moment is the take's 0, so your words, your lips and the moves line up. A camera that sends no picture (covered, or busy in another app) leaves a take of your voice rather than none, and a camera or microphone that goes away mid-take ends it there, keeping what was recorded.

**You in the room**
- You fill the room the stage leaves, edge to edge, your picture's top edge melting into the backdrop, with the same fine grain as the slide, so you and the slide are one picture. In export, **You: In the Room** draws you in; **Own File** leaves the room empty and saves the recording beside the video as "… – you.mov", for Premiere or Edits.

**The slide map, beside the video**
- For a tall video, the slide map leaves the inspector for its own pane on the left of the video, in the room the video never used. It grows with the window, and its numbers, corners and handles grow with it, so every framing is easy to see and to grab. A square video gets it too in a wide window; when there isn't room beside the video, the map stays at the top of the inspector.
- Drag the edge between the map and the video to give either more room; double-click it to let the video's shape decide again. ⇧⌘M, or the button at the left of the toolbar, keeps the map in the inspector.
- Over the map: which slide it shows and how many framings are on it. With none yet, it asks you to draw one or to let Direct for Me plan the tour.

**The pen, easy to find**
- **Draw** sits under the video, by name, with a dot of the ink it will draw in. Click it and the pen's tray takes the place of the play buttons: four inks, larger and easier to tell apart, Stays or Fades, and Done (or Return).
- While the pen is out, the stage is ringed in its ink, and over the card the pointer becomes a drop of that ink, as wide as the line it draws there. Where the card is moving it shows that you can't draw yet, and the line above the stage offers to take you to the next landing, where you can.
- Marks on the timeline are a little larger, so they're easier to see and to drag.

**Everywhere**
- Direct for Me says its name in the toolbar.
- Over a narrow video the line above it wraps instead of spilling, and the time under it keeps where you are.

**Fixed**
- Saving a video over several slides kept only the first slide's file: the others went missing when the document was opened again. Every slide is kept now, with the voiceover and the camera recording.

**Made and checked**
- `ooo-lab --live "4,8,12.5b,15@0.7:0.55"` plays a take from written presses, filmed by a stand-in recording of someone talking, since CI's Mac has no camera; `ooo-lab live` prints what each press did and when the video ends, and checks you're in the room exactly while you should be. CI renders a take over two slides.

## 1.0.2 — 6 October 2026

Marks that lie on the slide the way real ink does.

**Draw on the slide**
- The pen's ink is now a glaze, the way watercolour lies: the slide shows through it, so a word you underline still reads under the line, and yellow works like a highlighter. On a dark slide the ink lies thicker, so it still shows. White chalk stays solid.
- The ink gathers darker along the edges of the line and where the pen touched down. Just after the pen passes, a faint fringe creeps out a hair past the line. And it's never quite even.

**Made and checked**
- `ooo-lab marks --close` draws each mark up close at full size, as it's drawn, just drawn and settled, and `--ink flat` draws 1.0.1's ink, so CI shows the old and new ink side by side on light and dark slides.

## 1.0.1 — 6 October 2026

One card in your hand through several slides, marks drawn by hand, a scratch take recorded right in OOO, and room at the bottom of the frame for you on camera.

**Several slides, one card**
- **Add Slide… (⌃⌘I)**, or drop several slides at once: the video goes through them in order with the same card in your hand. Open on your deck's cover and turn it over to the slide you talk about, or follow a number from one slide to the next.
- **Turn or Melt**, slide by slide. A turn presses the card back a touch, lifts and bows it as it swings, and lands it with a little give. A melt washes the next slide in from wherever you're looking, along a soft, ragged edge, while whatever the two slides share holds still.
- **Turn back to the first slide** at the end, so the video ends where it began.
- Each slide gets its own tour and its own map in the inspector. Direct for Me plans across all of them, and with a voice each slide's moves land on its own words. Drag a change on the timeline to time it; the slides after it move along.

**Draw on the slide**
- **Draw on the Slide (⇧⌘P)**, or the pen under the stage: circle a number, underline a word. One fine marker, in red, yellow, white or black. In the video the mark draws on just as your hand drew it, at your pace.
- A mark **stays** until its slide changes, or **fades** a moment after it's drawn. Marks sit along the camera's lane in their own ink: drag one to time it, click to watch it, right-click to change or delete it.

**A scratch take**
- **Record Voiceover (⌥⌘R)**, or Record in the Voice tab: a count of three, then talk the video through as it plays. Stop, and OOO hears your words and cuts the moves to them. It's a quick way to find the beats before you record the real thing.

**Room for you**
- **Room for you** lifts the slide, its moves and its title into the top of the frame and leaves the bottom clear for your talking head, to lay over in Edits or Premiere. Choose **Whole Video**, or add stretches on the new lane under the camera's, where you talk: the stage rises and settles smoothly, and whatever the camera is doing carries on through it, every framing solved again for the space above you.
- The stage shows where you'll be, a quiet outline that comes up as the stage rises. It is never exported.

**Fixed**
- A dark slide no longer goes grey under Gloss as the camera comes in: the sheen holds back over dark artwork, as it does on Satin.

**Made and checked**
- `ooo-lab changes`, `ooo-lab marks` and `ooo-lab lifts` draw every turn, melt, mark and rise in CI, and `motioncheck` measures how fast the picture changes through them.
- Slide loading and the card shader come from Drift 2.5, so a slide is drawn sooner and its close-ups cost less.
- Files with several slides, marks or room for you need OOO 1.0.1; 1.0 says so and offers the update instead of opening them without.

## 1.0.0 — 6 October 2026

OOO 1.0: a slide you corrected keeps its tour, every drag has a key, and the camera takes its time.

**Keep the tour**
- **Replace Slide (⇧⌘I).** Swap in a corrected slide and keep the camera work: each framing follows its words to where they are now, and a shot named after its words takes the new ones. Framings about nothing that moved stay where they were.
- **Framings remember who made them.** Change the canvas and the framings Direct for Me planned are framed again for it; the ones you set stay where you put them.
- **A slide is read once.** Its reading is kept in the document, so directing it again, or changing the canvas, never reads it again.

**For the post**
- **Save Stills (⇧⌘E)**: the opening and every landing as full-size pictures in a folder, for a carousel, exactly as the export draws them.

**Every drag has a key**
- Esc cancels a drag halfway. Double-click any value in the inspector to type it. A run of arrow presses is one undo.
- ⌥⌘ arrows move the selected framing, ⌥⌘= and ⌥⌘− take it closer and wider, and ⌥⌘[ and ⌥⌘] land it a tenth of a second earlier or later.
- Hold `\` to see the slide exactly as supplied (the Original surface), and let go to see your look.
- With Reduce Motion on, the editor doesn't start playing by itself and Direct for Me's glow doesn't pulse. The films you export move as they always do.

**Fixed**
- **The whole editor fits a laptop's screen.** One line of help in the inspector made the editor at least 1177 points tall, so on a laptop the timeline sat below the bottom of the screen and the slide map under the toolbar. It now fits a 1024 × 768 screen, and CI fails any screenshot where it doesn't.
- **A number corrected where it stood** keeps its shot through Replace Slide, and the shot takes the new number ("$412k" becomes "$431k").

**Since 0.2.0, also** (the details are under 0.3.0)
- **Black type stays black**: on the wide test slide a headline lands at most 7 levels above the slide as supplied, down from 18.
- **A larger wide opening**: a wide slide stands 29% of a reel's height, up from 24%.
- **Motion that never rushes**: every move gets the time its distance and turn need, holds follow how much there is to read, and with a voice a move it leaves no time for becomes a cut on the word.
- **The room**: every backdrop's own dials and Shuffle, and From Slide, a room in the slide's own colours.
- **Weave**, a new arrival, and **Develop** rebuilt to come up like a print. The kicker can be set as typed.

**Made and checked**
- Releases are published from CI, and their updates signed on pitch.dog's release Mac (`scripts/sign-release.sh`); CI runs the same scripts end to end with a throwaway key before every release.
- `ooo-lab bench` and `ooo-lab colorcheck` measure export and preview times (with the machine) and how colour survives the encoder, in every CI run.
- The README is rewritten; building and the headless checks are in `docs/DEVELOPING.md`.

## 0.3.0 — 6 October 2026 (not released on its own)

A milestone on the way to 1.0: the fixes the 0.2.0 audit found, motion that never rushes, and the room and arrivals.

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

**Checked**
- The editor's window narrows to 960 points, so it fits a 1024-point-wide screen. "Busy" tracks every running job.
- CI now screenshots the real editor window (`OOO --snapshot`), fails on any `motioncheck` problem, measures ink like for like, and renders every look (`ooo-lab backdrops`) and every arrival (`ooo-lab arrivals`).

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
