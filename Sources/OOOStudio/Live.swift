import AppKit
@preconcurrency import AVFoundation
import Observation
import OOOCore
import OOOMotion
import QuartzCore
import SwiftUI

// MARK: - Capture

// What open-source recorders taught this capture (ideas, written here in our
// own code; see NOTICES.md): start the camera and microphone before the count
// so they have warmed up (snapcap, Cap); take time 0 from a sample's own clock,
// not from when a callback arrives (snapcap, Cap); give up on a camera that
// sends no picture within 4 s (Cap, CueRecord); leave Desk View out of the
// cameras (Cap, snapcap and OBS list it); record unmirrored and mirror only
// what you see (snapcap, Cap); HEVC for the camera (QuickRecorder, snapcap);
// warn about Reactions (OBS).

/// The Mac's own microphone and camera during a live take: one recording of
/// both, so your voice and your lips stay together, and a mirror to see
/// yourself in while you talk.
@Observable
@MainActor
public final class LiveCapture {
    public enum Phase: Equatable {
        case idle
        /// Asking for the microphone and camera, and starting them.
        case preparing
        /// 3, 2, 1.
        case counting(Int)
        case recording
        /// Stopped; the take is being kept.
        case finishing
    }

    public private(set) var phase: Phase = .idle
    /// Whether the camera films this take.
    public private(set) var filming = false
    /// How loud the last few seconds were, 0…1, newest last.
    public private(set) var levels: [Float] = []
    /// Seconds recorded so far, for the pill.
    public private(set) var elapsed: Double = 0
    /// The running capture, for the mirror.
    public private(set) var session: AVCaptureSession?

    @ObservationIgnored private var output: AVCaptureMovieFileOutput?
    @ObservationIgnored private let queue = DispatchQueue(label: "dog.pitch.ooo.live-capture")
    @ObservationIgnored private var feed: Feed?
    @ObservationIgnored private var meter: Timer?
    @ObservationIgnored private var countIn: Task<Void, Never>?
    @ObservationIgnored private var delegate: RecordingDelegate?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var lost: ((String) -> Void)?

    public var isActive: Bool { phase != .idle }
    public var isRecording: Bool { phase == .recording }
    public var isCounting: Bool { if case .counting = phase { return true } else { return false } }

    /// Seconds since the recording's first moment, on the clock the camera
    /// and microphone stamp their samples with; 0 before.
    public var time: Double {
        guard let zero = feed?.zero else { return 0 }
        return max(CACurrentMediaTime() - zero, 0)
    }

    static let shownLevels = 64

    public init() {}

    static let micDenied = "OOO can't hear the microphone. Allow it in System Settings › Privacy & Security › Microphone, then try again."
    static let cameraDenied = "OOO can't see the camera, so this take is your voice only. Allow it in System Settings › Privacy & Security › Camera."
    static let cameraMissing = "No camera found, so this take is your voice only."
    static let cameraSilent = "No picture came from the camera (it may be closed, covered or in use by another app), so this take is your voice only."
    static let reactions = "Reactions are on: a thumbs up during the take can fill it with fireworks. Turn them off under Video Effects in the menu bar."

    /// Asks for the microphone (and camera, with `camera`) if it must and
    /// starts them, so you see yourself before the count. `ready` gets
    /// whether the camera films, and a note when it was wanted but can't.
    func prepare(camera: Bool, ready: @escaping (_ filming: Bool, _ note: String?) -> Void,
                 failed: @escaping (String) -> Void, lost: @escaping (String) -> Void) {
        guard phase == .idle else { return }
        phase = .preparing
        self.lost = lost
        Task {
            guard await Self.allowed(.audio) else {
                self.phase = .idle
                failed(Self.micDenied)
                return
            }
            var notes: [String] = []
            var film = camera
            if camera, !(await Self.allowed(.video)) {
                film = false
                notes.append(Self.cameraDenied)
            }
            var made = await self.start(filming: film)
            if case .success(let c) = made, film {
                if !c.filming {
                    notes.append(Self.cameraMissing)
                } else if !(await c.feed.waitForPicture(seconds: 4)) {
                    // A camera that sends nothing: your voice, rather than no take.
                    self.queue.async { c.stop() }
                    notes.append(Self.cameraSilent)
                    made = await self.start(filming: false)
                } else if AVCaptureDevice.reactionEffectGesturesEnabled {
                    notes.append(Self.reactions)
                }
            }
            guard self.phase == .preparing else {
                // Given up while it was starting.
                if case .success(let c) = made { self.queue.async { c.stop() } }
                return
            }
            switch made {
            case .success(let c):
                self.session = c.session
                self.output = c.output
                self.feed = c.feed
                self.filming = c.filming
                self.watch(c.session)
                ready(c.filming, notes.isEmpty ? nil : notes.joined(separator: " "))
            case .failure(let error):
                self.phase = .idle
                failed("Couldn't start the microphone: \(readable(error))")
            }
        }
    }

    private func start(filming: Bool) async -> Result<Capture, Error> {
        await withCheckedContinuation { done in
            self.queue.async { done.resume(returning: Result { try Capture(filming: filming) }) }
        }
    }

    private static func allowed(_ type: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: type) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: type)
        default: return false
        }
    }

    /// The camera you face: the one macOS prefers (it follows your choice in
    /// the menu bar and Continuity Camera), never Desk View, which looks down
    /// at the desk.
    nonisolated static func camera() -> AVCaptureDevice? {
        let found = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .continuityCamera, .external],
                                                     mediaType: .video, position: .unspecified).devices
        if let preferred = AVCaptureDevice.systemPreferredCamera, preferred.deviceType != .deskViewCamera { return preferred }
        return found.first { $0.deviceType == .builtInWideAngleCamera } ?? found.first
    }

    /// The capture: the Mac's microphone (the input chosen in Sound settings)
    /// and, filming, its camera, into one movie.
    private struct Capture: @unchecked Sendable {
        let session: AVCaptureSession
        let output: AVCaptureMovieFileOutput
        let feed: Feed
        let filming: Bool

        init(filming wanted: Bool) throws {
            let s = AVCaptureSession()
            s.beginConfiguration()
            guard let mic = AVCaptureDevice.default(for: .audio) else {
                throw CocoaError(.featureUnsupported, userInfo: [NSLocalizedDescriptionKey: "No microphone found."])
            }
            let micIn = try AVCaptureDeviceInput(device: mic)
            guard s.canAddInput(micIn) else { throw CocoaError(.featureUnsupported) }
            s.addInput(micIn)
            var film = false
            if wanted, let cam = LiveCapture.camera(), let camIn = try? AVCaptureDeviceInput(device: cam), s.canAddInput(camIn) {
                s.addInput(camIn)
                film = true
            }
            s.sessionPreset = film && s.canSetSessionPreset(.hd1920x1080) ? .hd1920x1080 : .high
            let out = AVCaptureMovieFileOutput()
            guard s.canAddOutput(out) else { throw CocoaError(.featureUnsupported) }
            s.addOutput(out)
            if film, let video = out.connection(with: .video) {
                // HEVC keeps a long take small; every Apple silicon Mac encodes it in hardware.
                out.setOutputSettings([AVVideoCodecKey: AVVideoCodecType.hevc], for: video)
            }
            let feed = Feed(clock: s.synchronizationClock, filming: film)
            out.delegate = feed
            s.commitConfiguration()
            s.startRunning()
            session = s
            output = out
            self.feed = feed
            filming = film
        }

        /// Stops the camera and microphone, on the capture's queue.
        func stop() {
            session.stopRunning()
            output.delegate = nil
            withExtendedLifetime(feed) {}
        }
    }

    /// A camera or microphone that goes away mid-take (unplugged, taken by
    /// another app, the lid closed) ends the take there, keeping what was recorded.
    private func watch(_ s: AVCaptureSession) {
        let centre = NotificationCenter.default
        let gone: @Sendable (Notification) -> Void = { [weak self] note in
            let device = note.object as? AVCaptureDevice
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.isActive else { return }
                    if let device {
                        let used = (self.session?.inputs ?? []).contains { ($0 as? AVCaptureDeviceInput)?.device == device }
                        guard used else { return }
                    }
                    self.lost?("The camera or microphone went away, so the take ended there.")
                }
            }
        }
        observers = [
            centre.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: nil, using: gone),
            centre.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: s, queue: nil, using: gone),
            centre.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: s, queue: nil, using: gone),
        ]
    }

    /// Counts you in, then records; `started` runs as the recording starts.
    func count(_ started: @escaping () -> Void) {
        guard phase == .preparing else { return }
        levels = []
        elapsed = 0
        meter = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.listen() }
        }
        countIn = Task { [weak self] in
            for n in [3, 2, 1] {
                self?.phase = .counting(n)
                try? await Task.sleep(nanoseconds: 800_000_000)
                if Task.isCancelled { return }
            }
            self?.record(started)
        }
    }

    private func record(_ started: @escaping () -> Void) {
        guard let feed else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Live take \(Int(Date().timeIntervalSince1970)).mov")
        try? FileManager.default.removeItem(at: url)
        let d = RecordingDelegate()
        d.started = { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.isCounting else { return }
                    self.phase = .recording
                    started()
                }
            }
        }
        delegate = d
        // The recording starts on the next sample to arrive, and that sample's moment is time 0.
        feed.arm(url, delegate: d)
    }

    private func listen() {
        // Loudness the way it sounds: -50 dB is silence, 0 dB as loud as it gets.
        let db = output?.connection(with: .audio)?.audioChannels.map(\.averagePowerLevel).max() ?? -160
        let level = powf(max(0, min(1, (db + 50) / 50)), 1.6)
        levels.append(level)
        if levels.count > Self.shownLevels { levels.removeFirst(levels.count - Self.shownLevels) }
        elapsed = time
    }

    /// Stops recording; `done` gets the movie (nil if nothing was recorded).
    func finish(_ done: @escaping (URL?) -> Void) {
        countIn?.cancel()
        countIn = nil
        guard phase == .recording, let output, let delegate else {
            stop()
            done(nil)
            return
        }
        phase = .finishing
        meter?.invalidate()
        meter = nil
        delegate.finished = { [weak self] url, error in
            // A recording that stops with an error (a camera unplugged) may still be whole up to there.
            let whole = (error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool ?? (error == nil)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.stop()
                    done(whole ? url : nil)
                }
            }
        }
        output.stopRecording()
    }

    /// Gives up: stops everything and throws away whatever was recorded.
    func cancel() {
        countIn?.cancel()
        countIn = nil
        if phase == .recording || phase == .finishing, let output, let delegate {
            delegate.finished = { url, _ in try? FileManager.default.removeItem(at: url) }
            output.stopRecording()
        } else {
            feed?.disarm()
        }
        stop()
    }

    private func stop() {
        meter?.invalidate()
        meter = nil
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers = []
        if let s = session, let out = output, let f = feed {
            queue.async {
                s.stopRunning()
                // The output doesn't keep its delegate: let go of it only once the samples have stopped.
                out.delegate = nil
                withExtendedLifetime(f) {}
            }
        }
        session = nil
        output = nil
        feed = nil
        lost = nil
        phase = .idle
    }
}

/// Every sample the movie output receives, before and while it records: the
/// first picture (so a silent camera is found out), and the sample the
/// recording starts on, exactly, whose moment on the host clock is time 0.
final class Feed: NSObject, AVCaptureFileOutputDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let clock: CMClock?
    private let filming: Bool
    private var pictured = false
    private var armed: (url: URL, delegate: RecordingDelegate)?
    private var zeroTime: Double?

    init(clock: CMClock?, filming: Bool) {
        self.clock = clock
        self.filming = filming
    }

    /// The recording's first moment, in host seconds (`CACurrentMediaTime`).
    var zero: Double? { lock.withLock { zeroTime } }

    var hasPicture: Bool { lock.withLock { pictured } }

    /// Waits up to `seconds` for the camera's first picture.
    func waitForPicture(seconds: Double) async -> Bool {
        let until = CACurrentMediaTime() + seconds
        while CACurrentMediaTime() < until {
            if hasPicture { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return hasPicture
    }

    /// Starts recording to `url` on the next sample that comes (a picture, when filming).
    func arm(_ url: URL, delegate: RecordingDelegate) {
        lock.withLock { armed = (url, delegate) }
    }

    func disarm() {
        lock.withLock { armed = nil }
    }

    func fileOutputShouldProvideSampleAccurateRecordingStart(_ output: AVCaptureFileOutput) -> Bool { true }

    func fileOutput(_ output: AVCaptureFileOutput, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let isPicture = connection.inputPorts.contains { $0.mediaType == .video }
        lock.lock()
        if isPicture { pictured = true }
        guard let start = armed, !filming || isPicture else {
            lock.unlock()
            return
        }
        armed = nil
        // The sample's moment, from the capture's clock to the host's: time 0.
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let host = clock.map { CMSyncConvertTime(pts, from: $0, to: CMClockGetHostTimeClock()) } ?? pts
        zeroTime = host.isNumeric ? host.seconds : CACurrentMediaTime()
        lock.unlock()
        // Started from here, the recording begins with this very sample.
        (output as? AVCaptureMovieFileOutput)?.startRecording(to: start.url, recordingDelegate: start.delegate)
    }
}

/// Hears when recording starts and stops, on whatever queue AVFoundation uses.
final class RecordingDelegate: NSObject, AVCaptureFileOutputRecordingDelegate, @unchecked Sendable {
    var started: (() -> Void)?
    var finished: ((URL, Error?) -> Void)?

    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        started?()
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection],
                    error: Error?) {
        finished?(outputFileURL, error)
    }
}

/// What a take's movie holds, once recorded: your voice as its own sound
/// file, and how the picture plays.
enum LiveTakeFile {
    /// The voice, as a sound file beside the movie.
    static func voice(from movie: URL) async throws -> (url: URL, duration: Double) {
        let asset = AVURLAsset(url: movie)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "Couldn't take the voice from the recording."])
        }
        let out = movie.deletingPathExtension().appendingPathExtension("m4a")
        try? FileManager.default.removeItem(at: out)
        export.outputURL = out
        export.outputFileType = .m4a
        await export.export()
        guard export.status == .completed else {
            throw export.error ?? CocoaError(.fileWriteUnknown)
        }
        let duration = try await AVURLAsset(url: out).load(.duration).seconds
        return (out, duration.isFinite ? duration : 0)
    }

    /// How long the picture plays and its shape as it plays (width / height); nil without one.
    static func picture(_ movie: URL) async throws -> (duration: Double, aspect: Float)? {
        let asset = AVURLAsset(url: movie)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return nil }
        let (size, transform) = try await track.load(.naturalSize, .preferredTransform)
        let shown = size.applying(transform)
        let duration = try await asset.load(.duration).seconds
        guard abs(shown.height) > 0, duration.isFinite else { return nil }
        return (duration, Float(abs(shown.width) / abs(shown.height)))
    }
}

// MARK: - The take

/// A take under way: the route you lead, and the project as it was before.
final class LiveRun {
    var take: LiveTake
    let before: OOOProject
    let filming: Bool
    /// When you finished, once you have.
    var end: Double?

    init(take: LiveTake, before: OOOProject, filming: Bool) {
        self.take = take
        self.before = before
        self.filming = filming
    }
}

/// Live mode: you lead the camera over the slides while you talk, the Mac
/// records your voice and, if you like, your face, and the take becomes
/// the video, timed to you.
extension OOOSession {
    /// Whether live takes film you; on unless switched off.
    public static var liveCamera: Bool {
        get { UserDefaults.standard.object(forKey: "live.camera") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "live.camera") }
    }

    public var isLive: Bool { liveCapture.isActive }

    /// Starts the microphone (and camera), counts you in, then records while
    /// you lead the camera.
    public func goLive() {
        guard take == nil, hasSlide, !recorder.isActive, !liveCapture.isActive else { return }
        if pen.on { finishDrawing(replay: false) }
        settleEdits()
        clock.playing = false
        clock.time = 0
        liveCapture.prepare(camera: Self.liveCamera, ready: { [weak self] filming, note in
            guard let self else { return }
            if let note { self.message = note }
            self.beginTake(filming: filming)
        }, failed: { [weak self] why in
            self?.message = why
        }, lost: { [weak self] why in
            self?.message = why
            self?.finishTake()
        })
    }

    private func beginTake(filming: Bool) {
        let before = project
        let stage = before.liveStage(filming: filming)
        take = LiveRun(take: LiveTake(stage.choreographyInput), before: before, filming: filming)
        set(stage)
        selection = .overview
        clock.time = 0
        clock.playing = false
        liveCapture.count { [weak self] in
            guard let self else { return }
            self.clock.time = 0
            self.clock.playing = true
            self.touch()
        }
    }

    /// The take's time while it runs (held at 0 through the count, and at
    /// the end once you finish); nil when there is no take.
    func liveClock() -> Double? {
        guard let run = take else { return nil }
        if let end = run.end { return end }
        guard liveCapture.isRecording else { return 0 }
        let t = liveCapture.time
        if run.take.keepUp(at: t) { show(run.take.choreography) }
        return t
    }

    /// Next stop, back, or the whole slide, setting off now.
    public func liveStep(_ step: LiveTake.Step) {
        guard let run = take, run.end == nil, liveCapture.isRecording else { return }
        if run.take.step(step, at: liveCapture.time) { show(run.take.choreography) }
    }

    /// Looks at what is at the canvas point (x, y), in −1…1 with y up: the
    /// stop or detail there, or closer.
    public func liveLook(_ x: Float, _ y: Float) {
        guard let run = take, run.end == nil, liveCapture.isRecording, let scene else { return }
        let t = liveCapture.time, C = project.canvasAspect
        guard let hit = scene.touch(x, y, at: t, canvasAspect: C), hit.page == run.take.page else { return }
        let view = choreography.pose(at: t).frame(slideAspect: run.take.base.aspects[hit.page], canvasAspect: C)
        let target = project.liveTarget(run.take, at: Vec2(hit.x, hit.y), view: view)
        if run.take.look(target.shot, stop: target.stop, at: t) { show(run.take.choreography) }
    }

    /// Ends the take and keeps it: the moves at the moments you made them,
    /// your voice as the voiceover, you in the room. One undo takes it all back.
    public func finishTake() {
        guard let run = take, run.end == nil else { return }
        guard liveCapture.isRecording else {
            cancelTake()
            return
        }
        if pen.on { finishDrawing(replay: false) }
        let end = liveCapture.time
        run.end = end
        let job = beginJob("Keeping the take")
        liveCapture.finish { [weak self] movie in
            guard let self else { return }
            guard let movie else {
                self.endJob(job)
                self.message = "The take couldn't be recorded."
                self.giveUp(run)
                return
            }
            Task { @MainActor in
                defer { self.endJob(job) }
                do {
                    try await self.keep(run, movie: movie, end: end)
                } catch {
                    self.message = "Couldn't keep the take: \(readable(error))"
                    self.giveUp(run)
                }
                try? FileManager.default.removeItem(at: movie)
            }
        }
    }

    private func keep(_ run: LiveRun, movie: URL, end: Double) async throws {
        let sound = try await LiveTakeFile.voice(from: movie)
        defer { try? FileManager.default.removeItem(at: sound.url) }
        var picture: (duration: Double, aspect: Float)?
        if run.filming { picture = try await LiveTakeFile.picture(movie) }
        let store = document.media
        let voiceFile = try store.importFile(sound.url)
        var face: FaceClip?
        if let picture {
            // Mirrored, as you saw yourself while you talked.
            face = FaceClip(file: try store.importFile(movie), offset: 0, duration: picture.duration, aspect: picture.aspect,
                            mirrored: true)
        }
        guard take === run else { return }
        let when = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)
        let voice = Voiceover(file: voiceFile, name: "Live take, \(when)", offset: 0, duration: sound.duration)
        let kept = project.taken(run.take, end: end, voice: voice, face: face)
        take = nil
        set(kept)
        registerUndo(from: run.before, name: "Live Take")
        selection = .overview
        clock.time = 0
        clock.autoplay()
        // Its words, for reading along and for later; the moves stay where you made them.
        transcribe(cut: false)
    }

    /// Gives up the take before it records anything worth keeping: everything goes back as it was.
    public func cancelTake() {
        liveCapture.cancel()
        guard let run = take else { return }
        giveUp(run)
    }

    private func giveUp(_ run: LiveRun) {
        guard take === run else { return }
        take = nil
        if pen.on { finishDrawing(replay: false) }
        set(run.before)
        clock.time = 0
        clock.playing = false
    }

    public func toggleLive() {
        if take != nil { finishTake() } else { goLive() }
    }

    /// The keys during a take: → or Space next, ← back, ↑ the whole slide,
    /// Return or Esc to finish. Every other key waits.
    func liveKey(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return false }
        switch event.keyCode {
        case 53, 36, 76:
            // Esc, Return, Enter: the pen away if it's out, else the take is done.
            if !event.isARepeat {
                if pen.on { finishDrawing(replay: false) } else { finishTake() }
            }
            return true
        case 49, 124:
            if !event.isARepeat { liveStep(.next) }
            return true
        case 123:
            if !event.isARepeat { liveStep(.back) }
            return true
        case 126:
            if !event.isARepeat { liveStep(.whole) }
            return true
        default:
            return false
        }
    }
}

// MARK: - Views

/// Over the stage during a take: you, in the room the stage leaves; the
/// count; a small pill with the time, your voice and the keys; and the
/// slide, which a click looks closer at.
struct LiveOverlay: View {
    @Bindable var session: OOOSession
    let capture: LiveCapture

    var body: some View {
        GeometryReader { g in
            let room = CGFloat(min(max(session.project.lift?.room ?? Lift.defaultRoom, Lift.roomRange.lowerBound), Lift.roomRange.upperBound))
            ZStack {
                if capture.filming, let s = capture.session {
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        LivePreview(session: s)
                            .frame(width: g.size.width, height: g.size.height * room)
                            // The top edge melts into the backdrop, as it does in the video.
                            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.12)],
                                                 startPoint: .top, endPoint: .bottom))
                    }
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }
                if capture.isRecording && !session.pen.on {
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(SpatialTapGesture().onEnded { v in
                            let x = Float(v.location.x / max(g.size.width, 1)) * 2 - 1
                            let y = 1 - Float(v.location.y / max(g.size.height, 1)) * 2
                            session.liveLook(x, y)
                        })
                }
                if case .counting(let n) = capture.phase {
                    Text("\(n)")
                        .font(.system(size: 60, weight: .light, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(width: 112, height: 112)
                        .background(Circle().fill(.black.opacity(0.32)))
                        .id(n)
                        .transition(.asymmetric(insertion: .scale(scale: 1.25).combined(with: .opacity),
                                                removal: .scale(scale: 0.85).combined(with: .opacity)))
                        .allowsHitTesting(false)
                }
                VStack {
                    LivePill(session: session, capture: capture)
                        .padding(.top, 12)
                    Spacer()
                }
            }
            .frame(width: g.size.width, height: g.size.height)
        }
        .animation(.easeOut(duration: 0.3), value: capture.phase)
    }
}

/// A breathing red dot, the time, your voice as it comes in, the keys, and Finish.
struct LivePill: View {
    let session: OOOSession
    let capture: LiveCapture
    @State private var breathe = false

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(Color(.sRGB, red: 0.92, green: 0.22, blue: 0.18))
                .frame(width: 8, height: 8)
                .opacity(capture.isRecording ? (breathe ? 1 : 0.45) : 0.3)
                .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: breathe)
                .onAppear { breathe = true }
            Text(label)
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.white)
            LevelBars(levels: capture.levels, count: 32)
                .frame(width: 76, height: 16)
            if capture.isRecording {
                Text("→ next  ← back  ↑ whole  click to look")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(1)
                    .layoutPriority(-1)
            }
            Button(capture.isRecording ? "Finish" : "Cancel") {
                if capture.isRecording { session.finishTake() } else { session.cancelTake() }
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(Capsule().fill(.white.opacity(0.18)))
            .disabled(capture.phase == .finishing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Capsule().fill(.black.opacity(0.5)))
    }

    private var label: String {
        switch capture.phase {
        case .preparing: return "Getting ready"
        case .counting: return "Live in…"
        case .finishing: return "Keeping your take"
        default: return String(format: "%d:%02d", Int(capture.elapsed) / 60, Int(capture.elapsed) % 60)
        }
    }
}

/// You, as the camera sees you, mirrored the way you know yourself.
struct LivePreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        if let c = layer.connection, c.isVideoMirroringSupported {
            c.automaticallyAdjustsVideoMirroring = false
            c.isVideoMirrored = true
        }
        view.layer = layer
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard let layer = view.layer as? AVCaptureVideoPreviewLayer, layer.session !== session else { return }
        layer.session = session
    }
}
