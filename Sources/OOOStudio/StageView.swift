import AppKit
import Metal
import MetalKit
import OOOCore
import OOOMotion
import QuartzCore
import RenderCore
import StageKit
import SwiftUI
import UniformTypeIdentifiers

// The live stage is adapted from pitch.dog Studio (StudioKit/Stage.swift in
// bomkino/pitchdog-drift), AGPL-3.0. See NOTICES.md.

/// Draws the video live. While playing it renders a few shutter samples a
/// frame, as many as the Mac has room for; paused, it renders the frame as the
/// export will, motion blur and sharp detail included.
final class StageCoordinator: NSObject, MTKViewDelegate {
    weak var session: OOOSession?
    private var lastTime = CACurrentMediaTime()
    private var lastVersion = -1
    private var lastDrawn: Double = -1
    private var lastSize: CGSize = .zero
    private var liveSamples = 4
    private var gpuMs: Double = 0
    /// Display refreshes in a row with nothing new to draw.
    private var idle = 0

    init(session: OOOSession) {
        self.session = session
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        lastVersion = -1
    }

    func draw(in view: MTKView) {
        MainActor.assumeIsolated { drawFrame(view) }
    }

    @MainActor
    private func drawFrame(_ view: MTKView) {
        guard let session else { return }
        let clock = session.clock
        let now = CACurrentMediaTime()
        let dt = min(now - lastTime, 0.1)
        lastTime = now
        // While the voice plays it keeps the time; otherwise the display does.
        if let heard = session.soundClock(playing: clock.playing, time: clock.time) {
            clock.time = heard
        } else if clock.playing {
            let t = clock.time + dt
            clock.time = t >= clock.duration ? 0 : t
        }
        // A stage nobody can see (minimised, behind other windows, on another
        // Space) keeps time but draws nothing.
        if let window = view.window, !window.occlusionState.contains(.visible) {
            lastVersion = -1
            return
        }
        let version = session.version
        let needs = clock.playing || version != lastVersion || clock.time != lastDrawn || view.drawableSize != lastSize
        if !needs {
            // Half a second with nothing to draw: stop waking the display
            // until something the stage shows changes.
            idle += 1
            if idle > 30 { sleep(view, session: session) }
            return
        }
        idle = 0
        guard let drawable = view.currentDrawable, let cb = GPU.shared.queue.makeCommandBuffer() else { return }
        if let scene = session.scene, let stage = OOOShared.stage {
            let samples = clock.playing ? liveSamples : 8
            let frameIndex = UInt32(max(0, clock.time * Double(scene.project.fps)))
            // Heavy backdrops render smaller while playing; paused frames are exact.
            let cost = scene.project.backdrop.styleInfo.cost
            let scale: Float = clock.playing ? (cost >= 3 ? 0.5 : (cost == 2 ? 0.75 : 1)) : 1
            let used = (try? stage.encode(cb, scene: scene, at: clock.time, output: drawable.texture, samples: samples,
                                          frameIndex: frameIndex, waitForDetail: false, backdropScale: scale)) ?? 1
            if clock.playing {
                // The close-up the tour needs a moment from now, drawn before it gets there.
                let size = drawable.texture
                stage.drawAhead(scene, at: clock.time + 0.6, width: size.width, height: size.height)
                // Only frames in motion, which take every sample they may, tell
                // what a sample costs; a held frame takes one.
                if used == samples {
                    cb.addCompletedHandler { [weak self] buffer in
                        let ms = (buffer.gpuEndTime - buffer.gpuStartTime) * 1000
                        DispatchQueue.main.async { self?.adapt(gpuMs: ms, samples: used) }
                    }
                }
            }
        } else {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = drawable.texture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0.043, green: 0.043, blue: 0.047, alpha: 1)
            pass.colorAttachments[0].storeAction = .store
            cb.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
        }
        cb.present(drawable)
        cb.commit()
        lastVersion = version
        lastDrawn = clock.time
        lastSize = view.drawableSize
    }

    @MainActor
    private func sleep(_ view: MTKView, session: OOOSession) {
        guard !view.isPaused else { return }
        view.isPaused = true
        idle = 0
        withObservationTracking {
            _ = session.version
            _ = session.clock.playing
            _ = session.clock.time
        } onChange: { [weak view, weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // Time asleep is not time played.
                    self?.lastTime = CACurrentMediaTime()
                    view?.isPaused = false
                }
            }
        }
    }

    /// Four samples read as blur; two show as double edges, so it is four,
    /// three or one, whichever keeps a frame near 10 ms of GPU time.
    private func adapt(gpuMs ms: Double, samples: Int) {
        guard ms > 0, ms < 200 else { return }
        gpuMs = gpuMs == 0 ? ms : gpuMs * 0.9 + ms * 0.1
        let perSample = gpuMs / Double(max(samples, 1))
        let want = perSample * 4 <= 10 ? 4 : (perSample * 3 <= 10 ? 3 : 1)
        if want != liveSamples { liveSamples = want; gpuMs = 0 }
    }

    // MARK: Scrolling scrubs

    private var resumeAfterScroll: Bool?
    private var resume: DispatchWorkItem?

    /// Two fingers over the stage move through the video, with the trackpad's
    /// own momentum. Playback holds while the stage is scrolled and carries on after.
    @MainActor
    func scrub(_ e: NSEvent, in view: NSView) {
        guard let session else { return }
        let clock = session.clock
        let dx = e.scrollingDeltaX, dy = e.scrollingDeltaY
        let delta = abs(dx) > abs(dy) ? dx : dy
        if resumeAfterScroll == nil {
            guard delta != 0 else { return }
            resumeAfterScroll = clock.playing
            clock.playing = false
        }
        resume?.cancel()
        let perPoint = clock.duration / 6 / Double(max(view.bounds.height, 100)) * (e.hasPreciseScrollingDeltas ? 1 : 8)
        clock.time = min(max(clock.time - Double(delta) * perPoint, 0), clock.duration)
        let fingersLifted = e.phase == .ended || e.phase == .cancelled
        let coasted = e.momentumPhase == .ended || e.momentumPhase == .cancelled
        let wheel = e.phase.isEmpty && e.momentumPhase.isEmpty
        guard fingersLifted || coasted || wheel else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let playing = self.resumeAfterScroll else { return }
                self.session?.clock.playing = playing
                self.resumeAfterScroll = nil
            }
        }
        resume = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (wheel ? 0.45 : 0.2), execute: work)
    }
}

/// The live stage's view: hands scrolling to the coordinator.
final class StageMTKView: MTKView {
    var onScroll: ((NSEvent, NSView) -> Void)?

    override func scrollWheel(with event: NSEvent) {
        if let onScroll { onScroll(event, self) } else { super.scrollWheel(with: event) }
    }
}

struct StagePreview: NSViewRepresentable {
    let session: OOOSession
    let pixelSize: CGSize

    func makeCoordinator() -> StageCoordinator {
        StageCoordinator(session: session)
    }

    func makeNSView(context: Context) -> MTKView {
        let v = StageMTKView(frame: .zero, device: GPU.shared.device)
        let coordinator = context.coordinator
        v.onScroll = { [weak coordinator] event, view in
            MainActor.assumeIsolated { coordinator?.scrub(event, in: view) }
        }
        v.colorPixelFormat = .bgra8Unorm
        v.framebufferOnly = true
        v.autoResizeDrawable = false
        v.preferredFramesPerSecond = 60
        v.delegate = coordinator
        v.layer?.isOpaque = true
        (v.layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        v.drawableSize = pixelSize
        return v
    }

    func updateNSView(_ v: MTKView, context: Context) {
        context.coordinator.session = session
        if v.drawableSize != pixelSize, pixelSize.width > 1, pixelSize.height > 1 {
            v.drawableSize = pixelSize
            v.isPaused = false
        }
    }
}

/// Reads the URLs out of dropped items.
func loadDropped(_ providers: [NSItemProvider], _ done: @escaping @MainActor ([URL]) -> Void) {
    let group = DispatchGroup()
    var urls: [URL] = []
    let lock = NSLock()
    for p in providers {
        group.enter()
        _ = p.loadObject(ofClass: URL.self) { url, _ in
            if let url { lock.lock(); urls.append(url); lock.unlock() }
            group.leave()
        }
    }
    group.notify(queue: .main) { MainActor.assumeIsolated { done(urls) } }
}

extension OOOSession {
    /// A dropped recording becomes the voiceover; anything else, the slide.
    func importDropped(_ urls: [URL]) {
        for url in urls {
            let type = UTType(filenameExtension: url.pathExtension.lowercased())
            if type?.conforms(to: .audio) == true {
                importVoice(url)
            } else {
                importSlide(url)
            }
        }
    }
}

/// The output frame on its neutral surround, with the transport below.
struct StageArea: View {
    @Bindable var session: OOOSession
    @AppStorage("showSafeAreas") private var showSafeAreas = false
    @Environment(\.colorScheme) private var scheme
    @State private var dropTargeted = false
    @Environment(\.snapshotStill) private var snapshotStill

    /// The live stage, or during a snapshot the exported frame in its place.
    @ViewBuilder
    private func stage(_ px: CGSize) -> some View {
        if let still = snapshotStill {
            Image(decorative: still, scale: 1).resizable().interpolation(.high)
        } else {
            StagePreview(session: session, pixelSize: px)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                let side: CGFloat = 28, top: CGFloat = 40, bottom: CGFloat = 12
                let avail = CGSize(width: max(40, geo.size.width - side * 2), height: max(40, geo.size.height - top - bottom))
                let aspect = CGFloat(session.project.format.aspect)
                let fitted = avail.width / avail.height > aspect
                    ? CGSize(width: avail.height * aspect, height: avail.height)
                    : CGSize(width: avail.width, height: avail.width / aspect)
                let scale = NSScreen.main?.backingScaleFactor ?? 2
                let longSide = max(fitted.width, fitted.height) * scale
                let cap: CGFloat = 2400
                let k = longSide > cap ? cap / longSide : 1
                let px = CGSize(width: (fitted.width * scale * k).rounded(), height: (fitted.height * scale * k).rounded())
                ZStack {
                    Theme.surround
                    VStack(spacing: 0) {
                        StageStatus(session: session).frame(height: top)
                        stage(px)
                            .frame(width: fitted.width, height: fitted.height)
                            .overlay { if showSafeAreas { SafeAreaGuides(format: session.project.format) } }
                            .overlay {
                                if !session.hasSlide {
                                    ProgressView().controlSize(.small)
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.stage, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.stage, style: .continuous)
                                .strokeBorder(dropTargeted ? Theme.camera : Theme.hairline, lineWidth: dropTargeted ? 2 : 1))
                            .shadow(color: .black.opacity(scheme == .dark ? 0.55 : 0.18), radius: scheme == .dark ? 28 : 14, y: 4)
                            .onTapGesture(count: 2) { session.clock.playing.toggle() }
                        Spacer(minLength: 0)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
            .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                loadDropped(providers) { session.importDropped($0) }
                return true
            }
            TransportBar(session: session, clock: session.clock)
        }
    }
}

/// One quiet line above the stage: what OOO is doing, or what to try next.
struct StageStatus: View {
    @Bindable var session: OOOSession

    var body: some View {
        HStack(spacing: 8) {
            if session.comparing {
                Text("Original").textStyle(.label).foregroundStyle(.primary)
                Text("The slide exactly as supplied. Let go of \\ to see your look.").textStyle(.caption).foregroundStyle(.secondary)
            } else if let busy = session.busy {
                ProgressView().controlSize(.mini)
                Text(busy).textStyle(.label).foregroundStyle(.primary)
            } else if session.project.slide.kind == .sample {
                Text("Sample slide").textStyle(.label).foregroundStyle(.primary)
                Text("Drop your own slide and voiceover anywhere").textStyle(.caption).foregroundStyle(.secondary)
                Button("Choose Slide…") { OOOCommands.chooseSlide(session) }
                    .buttonStyle(QuietButtonStyle())
            } else {
                Text(session.project.slide.name).textStyle(.label).foregroundStyle(.primary).lineLimit(1)
                if let zoom = session.project.sharpZoom, let h = session.project.slide.pixelHeight {
                    Text(String(format: "Sharp to %.1f× closer", zoom))
                        .textStyle(.caption).foregroundStyle(.secondary)
                        .help("This picture is \(h) pixels tall. OOO draws it at up to twice that, sharpened, and Direct for Me "
                            + "stays within it. For closer looks, export the slide as a PDF, or as a picture at 2× or 3×.")
                }
                if session.pageCount > 1 {
                    HStack(spacing: 2) {
                        IconButton("chevron.left", label: "Previous Page", size: 10) { session.showPage(session.project.slide.page - 1) }
                            .disabled(session.project.slide.page == 0)
                        Text("Page \(session.project.slide.page + 1) of \(session.pageCount)")
                            .textStyle(.data).foregroundStyle(.secondary)
                        IconButton("chevron.right", label: "Next Page", size: 10) { session.showPage(session.project.slide.page + 1) }
                            .disabled(session.project.slide.page >= session.pageCount - 1)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .animation(Theme.quick, value: session.busy)
    }
}

// MARK: - Transport

struct TransportBar: View {
    let session: OOOSession
    @Bindable var clock: PlaybackClock

    var body: some View {
        HStack(spacing: 10) {
            IconButton("backward.end.fill", label: "Previous Landing") { session.jump(-1) }
            IconButton(clock.playing ? "pause.fill" : "play.fill", label: clock.playing ? "Pause" : "Play", size: 15) {
                if !clock.playing && clock.time >= clock.duration - 0.01 { clock.time = 0 }
                clock.playing.toggle()
                session.touch()
            }
            .keyboardShortcut(clock.typing ? nil : KeyboardShortcut(.space, modifiers: []))
            IconButton("forward.end.fill", label: "Next Landing") { session.jump(1) }
            HStack(spacing: 4) {
                Text(timecode(clock.time)).textStyle(.data).foregroundStyle(.primary)
                Text("/").textStyle(.data).foregroundStyle(.tertiary)
                Text(timecode(clock.duration)).textStyle(.data).foregroundStyle(.secondary)
            }
            .fixedSize()
            .padding(.leading, 6)
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .frame(maxWidth: .infinity)
        .background(Theme.surround)
    }

    private func timecode(_ t: Double) -> String {
        let fps = max(session.project.fps, 1)
        let total = Int((t * Double(fps)).rounded())
        let f = total % fps
        let s = (total / fps) % 60
        let m = total / fps / 60
        return String(format: "%d:%02d.%02d", m, s, f)
    }
}

/// Where platform interface covers a vertical video. Shown on the stage only;
/// never exported. Insets as recorded by Drift's platform guides.
struct SafeAreaGuides: View {
    let format: CanvasFormat

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            if format.id == "reel" || format.id == "portrait" {
                let reel = format.id == "reel"
                let top = h * (reel ? 0.10 : 0.06)
                let bottom = h * (reel ? 0.22 : 0.12)
                let right = reel ? w * 0.18 : 0
                ZStack(alignment: .topLeading) {
                    band(label: "Profile and header", rect: CGRect(x: 0, y: 0, width: w, height: top))
                    band(label: "Caption and buttons", rect: CGRect(x: 0, y: h - bottom, width: w, height: bottom))
                    if right > 0 {
                        band(label: "", rect: CGRect(x: w - right, y: top, width: right, height: h - top - bottom))
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func band(label: String, rect: CGRect) -> some View {
        ZStack(alignment: .center) {
            Rectangle().fill(Color.black.opacity(0.28))
            Rectangle().strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3])).foregroundStyle(Color.white.opacity(0.5))
            if !label.isEmpty { Text(label).textStyle(.caption).foregroundStyle(.white.opacity(0.85)) }
        }
        .frame(width: rect.width, height: rect.height)
        .offset(x: rect.minX, y: rect.minY)
    }
}
