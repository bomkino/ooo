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
        /// Running, so you see and hear yourself, but not recording.
        case ready
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
                self.phase = .ready
                self.levels = []
                self.startMeter()
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

    /// Listens to the microphone for the level meter, from the moment it is ready.
    private func startMeter() {
        meter?.invalidate()
        meter = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.listen() }
        }
    }

    /// Counts you in, then records; `started` runs as the recording starts.
    func count(_ started: @escaping () -> Void) {
        guard phase == .ready else { return }
        elapsed = 0
        if meter == nil { startMeter() }
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
        if phase == .recording { elapsed = time }
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
    /// When you closed the take, once you have.
    var end: Double?
    /// When the closing ends, and with it the recording.
    var stopAt: Double?
    /// The path from the moment you closed: what you saw, then the closing.
    var closing: Choreography?
    /// Where the clock rests once the recording has stopped.
    var held: Double?

    init(take: LiveTake, before: OOOProject, filming: Bool) {
        self.take = take
        self.before = before
        self.filming = filming
    }
}

/// Where you are in Live.
public enum LiveStep: Equatable {
    /// The room: you check yourself and your positions; nothing records yet.
    case room
    /// 3, 2, 1.
    case counting
    /// Recording while you lead.
    case recording
    /// Closed: the closing plays, still recording, and stops by itself.
    case closing
    /// Stopped; the take is being kept.
    case keeping
    /// Kept: the take is the video.
    case kept
}

/// Live: a room you step into and check, then Start. It counts you in and
/// records you, the slide enters, you lead the camera from position to
/// position while you talk, and Close plays the closing while it still
/// records, so your sign-off is in the video.
extension OOOSession {
    /// Whether live takes film you; on unless switched off.
    public static var liveCamera: Bool {
        get { UserDefaults.standard.object(forKey: "live.camera") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "live.camera") }
    }

    /// In Live: the room, a take, or a take just kept.
    public var isLive: Bool { mode == .live }

    /// A take under way, from Start until it is kept or given up.
    public var isTaking: Bool { take != nil }

    public var liveStep: LiveStep {
        guard take != nil else { return liveKept ? .kept : .room }
        switch liveCapture.phase {
        case .recording: return liveClosingAt == nil ? .recording : .closing
        case .finishing: return .keeping
        case .idle: return liveKeeping ? .keeping : .counting
        case .preparing, .ready, .counting: return .counting
        }
    }

    /// The route a take follows: the one under way, or the one the room would start.
    var liveRoute: LiveTake? { take?.take ?? roomTake }

    /// A position's number in the route (1 is the first), for the strip, the map and the keys.
    public func positionNumber(_ id: UUID) -> Int? {
        liveRoute?.script.firstIndex { $0.id == id }.map { $0 + 1 }
    }

    // MARK: The room

    /// Steps into Live: the stage shows the slide as the take will open, you
    /// in the space under it, and nothing records until Start.
    func openRoom() {
        settleEdits()
        liveKept = false
        keptBefore = nil
        liveNote = nil
        previewUntil = nil
        roomFilming = Self.liveCamera
        restageRoom()
        selection = .overview
        clock.playing = false
        clock.time = openingRest
        touch()
        startCapture()
    }

    /// Shows the project as a take in the room would play it.
    func restageRoom() {
        staged = project
        set(project)
    }

    /// The moment the opening has landed: the slide whole, at rest.
    var openingRest: Double {
        guard let first = choreography.beats.first else { return 0 }
        return min(first.land + 0.2, max(first.leave - 0.05, first.land))
    }

    /// Starts the microphone (and camera) in the room, so you see and hear
    /// yourself before you start.
    func startCapture() {
        guard !OOOSnapshot.isRequested, liveCapture.phase == .idle else { return }
        liveNote = nil
        liveCapture.prepare(camera: Self.liveCamera, ready: { [weak self] filming, note in
            guard let self else { return }
            self.liveNote = note
            if self.take == nil, self.staged != nil, filming != self.roomFilming {
                // Wanted to film you, but the camera can't: the stage stays down.
                self.roomFilming = filming
                self.restageRoom()
            }
        }, failed: { [weak self] why in
            self?.liveNote = why
        }, lost: { [weak self] why in
            self?.captureLost(why)
        })
    }

    private func captureLost(_ why: String) {
        guard take != nil else {
            liveCapture.cancel()
            liveNote = why
            return
        }
        message = why
        if liveCapture.isRecording { stopTake() } else { discardTake() }
    }

    /// Steps out of Live: the camera and microphone stop, and the stage
    /// shows the project again.
    func leaveLive() {
        guard take == nil else { return }
        liveCapture.cancel()
        previewUntil = nil
        liveKept = false
        keptBefore = nil
        liveNote = nil
        if staged != nil {
            staged = nil
            roomTake = nil
            set(project)
        }
        clock.playing = false
    }

    /// Films you in live takes, or not; the room shows it at once.
    public func setFilmMe(_ on: Bool) {
        Self.liveCamera = on
        guard mode == .live, take == nil, !liveKept else { return }
        liveCapture.cancel()
        roomFilming = on
        restageRoom()
        startCapture()
    }

    /// Plays the opening in the room, as the take will start.
    public func previewOpening() {
        guard take == nil, staged != nil else { return }
        previewUntil = min(openingRest + 0.4, clock.duration - 0.12)
        clock.time = 0
        clock.playing = true
    }

    /// Plays the closing in the room, from a moment before it.
    public func previewClosing() {
        guard take == nil, staged != nil, let last = choreography.clips.last else { return }
        let from = last.kind == .ending ? last.start - 1 : last.land
        previewUntil = max(clock.duration - 0.12, 0)
        clock.time = min(max(from, 0), clock.duration)
        clock.playing = true
    }

    /// Shows position `j` of the route on the stage, in the room.
    public func previewPosition(_ j: Int) {
        guard take == nil, let route = roomTake, route.script.indices.contains(j) else { return }
        let id = route.script[j].id
        guard let beat = choreography.beats.first(where: { !$0.isOverview && $0.shot.id == id }) else { return }
        rest(at: beat)
    }

    /// Shows slide `k` whole on the stage, in the room.
    public func previewWhole(_ k: Int) {
        guard take == nil, let beat = choreography.beats.first(where: { $0.isOverview && $0.page == k }) else { return }
        rest(at: beat)
    }

    private func rest(at beat: Choreography.Beat) {
        previewUntil = nil
        clock.playing = false
        clock.time = min(beat.land + min(0.4, max(beat.leave - beat.land, 0) * 0.3), clock.duration)
        touch()
    }

    // MARK: The take

    /// Start: counts you in, then records while the slide enters and you lead.
    public func startTake() {
        guard mode == .live, take == nil, hasSlide, liveCapture.phase == .ready else { return }
        if pen.on { pen.on = false }
        settleEdits()
        previewUntil = nil
        let before = project
        let filming = liveCapture.filming
        let stage = before.liveStage(filming: filming)
        staged = nil
        roomTake = nil
        liveKept = false
        keptBefore = nil
        liveClosingAt = nil
        liveKeeping = false
        take = LiveRun(take: LiveTake(stage.choreographyInput), before: before, filming: filming)
        set(stage)
        selection = .overview
        clock.playing = false
        clock.time = 0
        liveCapture.count { [weak self] in
            guard let self else { return }
            self.clock.time = 0
            self.clock.playing = true
            self.touch()
        }
    }

    /// The take's time while it runs (held at 0 through the count, and where
    /// it stopped once it has); nil when there is no take. The recording
    /// stops itself as the closing ends.
    func liveClock() -> Double? {
        guard let run = take else { return nil }
        if let held = run.held { return held }
        guard liveCapture.isRecording else { return 0 }
        let t = liveCapture.time
        if let stop = run.stopAt, t >= stop {
            stopTake()
            return run.held ?? stop
        }
        if run.closing == nil, run.take.keepUp(at: t) { show(run.take.choreography) }
        return t
    }

    /// The take while you lead it: recording, not yet closed.
    private var leading: LiveRun? {
        guard let run = take, run.end == nil, liveCapture.isRecording else { return nil }
        return run
    }

    /// Next stop, back, or the whole slide, setting off now.
    public func lead(_ step: LiveTake.Step) {
        guard let run = leading else { return }
        if run.take.step(step, at: liveCapture.time) { show(run.take.choreography) }
    }

    /// Straight to position `j` of the route (0 is the first), if it is on the slide face up.
    public func liveGo(_ j: Int) {
        guard let run = leading else { return }
        if run.take.go(to: j, at: liveCapture.time) { show(run.take.choreography) }
    }

    /// Straight to the position that is shot `id`.
    public func liveGo(shot id: UUID) {
        guard let j = leading?.take.script.firstIndex(where: { $0.id == id }) else { return }
        liveGo(j)
    }

    /// On to the next slide: the card turns or melts.
    public func liveNextSlide() {
        guard let run = leading else { return }
        if run.take.nextSlide(at: liveCapture.time) { show(run.take.choreography) }
    }

    /// Looks at what is at the canvas point (x, y), in −1…1 with y up: the
    /// position or detail there, or closer.
    public func liveLook(_ x: Float, _ y: Float) {
        guard let run = leading, let scene else { return }
        let t = liveCapture.time, C = project.canvasAspect
        guard let hit = scene.touch(x, y, at: t, canvasAspect: C), hit.page == run.take.page else { return }
        let view = choreography.pose(at: t).frame(slideAspect: run.take.base.aspects[hit.page], canvasAspect: C)
        let target = project.liveTarget(run.take, at: Vec2(hit.x, hit.y), view: view)
        if run.take.look(target.shot, stop: target.stop, at: t) { show(run.take.choreography) }
    }

    /// Close: the closing plays on from where you are, still recording, so
    /// your sign-off is in it, and the recording stops by itself as it ends.
    /// Pressed again while it plays, it stops there.
    public func closeTake() {
        guard let run = take else { return }
        guard liveCapture.isRecording else {
            if liveStep == .counting { discardTake() }
            return
        }
        guard run.end == nil else {
            stopTake()
            return
        }
        if pen.on { pen.on = false }
        let end = liveCapture.time
        let length = project.closingLength(run.take, end: end, filming: run.filming)
        let closing = run.take.closing(at: end, length: length)
        run.end = end
        run.stopAt = length
        run.closing = closing
        liveClosingAt = end
        show(closing)
        clock.duration = length
    }

    /// Stops recording now and keeps the take: the moves at the moments you
    /// made them, your voice as the voiceover, you in the space under the
    /// stage. One undo takes it all back.
    func stopTake() {
        guard let run = take, run.held == nil, liveCapture.isRecording else { return }
        if pen.on { pen.on = false }
        let recorded = liveCapture.time
        let end = run.end ?? recorded
        run.end = end
        run.held = min(recorded, run.stopAt ?? recorded)
        liveKeeping = true
        clock.playing = false
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
                    try await self.keep(run, movie: movie, end: end, recorded: recorded)
                } catch {
                    self.message = "Couldn't keep the take: \(readable(error))"
                    self.giveUp(run)
                }
                try? FileManager.default.removeItem(at: movie)
            }
        }
    }

    private func keep(_ run: LiveRun, movie: URL, end: Double, recorded: Double) async throws {
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
        let kept = project.taken(run.take, end: end, voice: voice, face: face, recorded: recorded)
        take = nil
        liveKeeping = false
        liveClosingAt = nil
        set(kept)
        registerUndo(from: run.before, name: "Live Take")
        keptBefore = run.before
        liveKept = mode == .live
        selection = .overview
        clock.time = 0
        clock.autoplay()
        // Its words, for reading along and for later; the moves stay where you made them.
        transcribe(cut: false, undoable: false)
    }

    /// Gives the take under way up (⌘.): nothing is kept, and you are back
    /// in the room, ready to start again.
    public func discardTake() {
        guard let run = take else { return }
        liveCapture.cancel()
        giveUp(run)
    }

    private func giveUp(_ run: LiveRun) {
        guard take === run else { return }
        take = nil
        liveKeeping = false
        liveClosingAt = nil
        if pen.on { pen.on = false }
        set(run.before)
        if mode == .live {
            openRoom()
        } else {
            clock.time = 0
            clock.playing = false
        }
    }

    /// Back to the room with the take just kept undone, to try it again.
    public func retake() {
        guard take == nil else { return }
        if liveKept, let before = keptBefore { update("Retake") { $0 = before } }
        openRoom()
    }

    /// Plays the take just kept from the start.
    public func playKept() {
        previewUntil = nil
        clock.time = 0
        clock.playing = true
    }

    /// Done with Live, back to Frame.
    public func liveDone() {
        liveKept = false
        keptBefore = nil
        enter(.frame)
    }

    /// The one live action, on ⌥⌘L: Live, then Start, then Close.
    public func liveAction() {
        guard mode == .live else { enter(.live); return }
        switch liveStep {
        case .room: startTake()
        case .recording, .closing: closeTake()
        case .kept: retake()
        case .counting, .keeping: break
        }
    }

    /// What ⌥⌘L does now, for its menu item.
    public var liveActionTitle: String {
        guard mode == .live else { return "Go Live" }
        switch liveStep {
        case .room, .counting: return "Start Take"
        case .recording: return "Close Take"
        case .closing, .keeping: return "Stop Recording"
        case .kept: return "Retake"
        }
    }

    // MARK: Keys

    /// The keys in the room: Return starts, 1 to 9 show a position, 0 the
    /// whole slide, Space plays. Once a take is kept, Return is Done.
    func roomKey(_ event: NSEvent) -> Bool {
        guard take == nil, event.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return false }
        switch event.keyCode {
        case 36, 76:
            if !event.isARepeat {
                if liveKept { liveDone() } else { startTake() }
            }
            return true
        case 49:
            if !event.isARepeat {
                previewUntil = nil
                if !clock.playing && clock.time >= clock.duration - 0.01 { clock.time = 0 }
                clock.playing.toggle()
                touch()
            }
            return true
        default:
            break
        }
        guard !liveKept, let c = event.charactersIgnoringModifiers, let n = Int(c), (0...9).contains(n) else { return false }
        if !event.isARepeat {
            if n == 0 { previewWhole(mapPage(at: clock.time)) } else { previewPosition(n - 1) }
        }
        return true
    }

    /// The keys during a take: → or Space next, ← back, 1 to 9 a position,
    /// 0 or ↑ the whole slide, ↓ the next slide, D the pen, Return to close.
    /// Esc only puts the pen away, so no stray key ends a take; ⌘. gives it
    /// up and ⌘Q quits. Every other key waits.
    func liveKey(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .option, .control])
        if mods.contains(.command) {
            let c = event.charactersIgnoringModifiers?.lowercased()
            return !(c == "." || c == "q")
        }
        guard mods.isEmpty else { return true }
        guard !event.isARepeat else { return true }
        switch event.keyCode {
        case 53:
            if pen.on { pen.on = false }
        case 36, 76:
            closeTake()
        case 49, 124:
            lead(.next)
        case 123:
            lead(.back)
        case 126:
            lead(.whole)
        case 125, 121:
            liveNextSlide()
        default:
            guard let c = event.charactersIgnoringModifiers?.lowercased() else { return true }
            if c == "d" {
                if leading != nil { pen.on.toggle() }
            } else if let n = Int(c), (0...9).contains(n) {
                if n == 0 { lead(.whole) } else { liveGo(n - 1) }
            }
        }
        return true
    }
}

// MARK: - Views

/// Over the stage in Live: you, in the space the stage leaves; the count;
/// a small pill with the time and your voice; and, while you lead, the
/// slide, which a click looks closer at.
struct LiveOverlay: View {
    @Bindable var session: OOOSession
    let capture: LiveCapture

    var body: some View {
        let step = session.liveStep
        GeometryReader { g in
            let room = CGFloat(min(max(session.project.lift?.room ?? Lift.defaultRoom, Lift.roomRange.lowerBound), Lift.roomRange.upperBound))
            ZStack {
                if step != .kept, capture.filming, let s = capture.session {
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
                if step == .recording && !session.pen.on {
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
                if step != .room && step != .kept {
                    VStack {
                        LivePill(session: session, capture: capture)
                            .padding(.top, 12)
                        Spacer()
                    }
                    .allowsHitTesting(false)
                }
            }
            .frame(width: g.size.width, height: g.size.height)
        }
        .animation(.easeOut(duration: 0.3), value: capture.phase)
    }
}

/// A breathing red dot, the time and your voice as it comes in.
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
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Capsule().fill(.black.opacity(0.5)))
    }

    private var label: String {
        switch session.liveStep {
        case .counting: return "Get ready"
        case .closing: return "Closing · " + minutes(capture.elapsed)
        case .keeping: return "Keeping your take"
        default: return minutes(capture.elapsed)
        }
    }

    private func minutes(_ t: Double) -> String {
        String(format: "%d:%02d", Int(t) / 60, Int(t) % 60)
    }
}

/// Live, under the video: your camera positions in the order the camera
/// visits them, and the one button that matters now: Start, Close, or what
/// to do with the take you just made.
struct LiveBar: View {
    @Bindable var session: OOOSession
    let capture: LiveCapture
    let width: CGFloat

    var body: some View {
        let step = session.liveStep
        VStack(spacing: 6) {
            if step != .kept && step != .keeping {
                PositionStrip(session: session)
                    .frame(height: 40)
            }
            HStack(spacing: 10) { controls(step) }
                .frame(height: 30)
        }
    }

    @ViewBuilder
    private func controls(_ step: LiveStep) -> some View {
        switch step {
        case .room:
            let ready = capture.phase == .ready || OOOSnapshot.isRequested
            if ready || capture.phase == .preparing {
                if capture.phase == .preparing {
                    ProgressView().controlSize(.small)
                    Text("Getting your camera ready").textStyle(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    LevelBars(levels: capture.levels, count: 14, tint: .primary)
                        .frame(width: 34, height: 14)
                        .help("Your microphone")
                }
                Button { session.startTake() } label: {
                    HStack(spacing: 6) {
                        Circle().fill(.white).frame(width: 8, height: 8)
                        Text("Start")
                    }
                }
                .buttonStyle(RecordButtonStyle())
                .disabled(!ready)
                .help("Counts you in, then records you while the slide enters (Return)")
            } else {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.secondary)
                Text(session.liveNote ?? "The microphone isn't on.").textStyle(.caption).foregroundStyle(.secondary)
                    .lineLimit(2).layoutPriority(-1)
                Button("Try Again") { session.startCapture() }
                    .buttonStyle(QuietButtonStyle())
            }
        case .counting:
            Text("Get ready").textStyle(.label)
            Button("Discard") { session.discardTake() }
                .buttonStyle(QuietButtonStyle())
                .help("Give this take up (⌘.)")
        case .recording:
            RecordingDot()
            Text(minutes(capture.elapsed)).textStyle(.data)
            Button("Close") { session.closeTake() }
                .buttonStyle(RecordButtonStyle())
                .help("Plays the closing, still recording your sign-off; it stops by itself (Return)")
            if width >= 330 {
                Button("Discard") { session.discardTake() }
                    .buttonStyle(QuietButtonStyle())
                    .help("Give this take up and start again (⌘.)")
            }
        case .closing:
            RecordingDot()
            Text("Closing").textStyle(.label)
            Button("Stop Now") { session.closeTake() }
                .buttonStyle(QuietButtonStyle())
                .help("Stop recording here; the closing still plays in the video (Return)")
        case .keeping:
            ProgressView().controlSize(.small)
            Text("Keeping your take").textStyle(.label)
        case .kept:
            Button { session.playKept() } label: { Label("Play", systemImage: "play.fill") }
                .buttonStyle(QuietButtonStyle())
            Button("Retake") { session.retake() }
                .buttonStyle(QuietButtonStyle())
                .help("Back to the room to try again; this take is undone (⌥⌘L)")
            Button("Done") { session.liveDone() }
                .buttonStyle(PrimaryButtonStyle())
                .help("Keep this take and go back to Frame (Return)")
        }
    }

    private func minutes(_ t: Double) -> String {
        String(format: "%d:%02d", Int(t) / 60, Int(t) % 60)
    }
}

/// The red dot that says it is recording.
struct RecordingDot: View {
    @State private var breathe = false

    var body: some View {
        Circle().fill(Theme.camera)
            .frame(width: 8, height: 8)
            .opacity(breathe ? 1 : 0.45)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: breathe)
            .onAppear { breathe = true }
            .accessibilityLabel("Recording")
    }
}

/// Start and Close: the camera's red, the one button that records.
struct RecordButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(height: 28)
            .background(Capsule().fill(Theme.camera).opacity(configuration.isPressed ? 0.8 : (enabled ? 1 : 0.4)))
            .contentShape(Capsule())
    }
}

/// The positions the camera can go to, slide by slide, each with its number:
/// in the room a click shows it; during a take it flies there. The one the
/// camera is at is lit, and the next is outlined.
struct PositionStrip: View {
    @Bindable var session: OOOSession
    @State private var shown: Int?

    var body: some View {
        let _ = session.version
        let route = session.liveRoute
        ScrollViewReader { reader in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    if let route {
                        ForEach(0..<route.slideCount, id: \.self) { k in
                            if k > 0 {
                                Rectangle().fill(Theme.hairline).frame(width: 1, height: 26)
                            }
                            chip(whole: k, route: route)
                            ForEach(route.stops(on: k), id: \.self) { j in
                                chip(stop: j, route: route).id(j)
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .frame(minWidth: 0)
            }
            .onChange(of: route?.cursor) { _, j in
                guard let j, j >= 0 else { return }
                withAnimation(Theme.settle) { reader.scrollTo(j, anchor: .center) }
            }
        }
    }

    private func chip(whole k: Int, route: LiveTake) -> some View {
        let taking = session.isTaking
        let here = taking && route.page == k && route.current == nil
        let reachable = !taking || route.page == k || route.page + 1 == k
        return PositionChip(image: session.preview(k), number: nil, label: route.slideCount > 1 ? "\(k + 1)" : nil,
                            lit: here || (!taking && shown == -1 - k), next: false, enabled: reachable,
                            help: taking && route.page + 1 == k ? "On to slide \(k + 1) (↓)" : "The whole slide (0)") {
            if taking {
                if route.page == k { session.lead(.whole) } else { session.liveNextSlide() }
            } else {
                shown = -1 - k
                session.previewWhole(k)
            }
        }
    }

    private func chip(stop j: Int, route: LiveTake) -> some View {
        let taking = session.isTaking
        let shot = route.script[j]
        let k = route.base.page(of: shot)
        let lit = taking ? route.current == j : shown == j
        let next = taking && route.page == k && j == route.cursor + 1
        let name = Director.spokenLabel(shot.label) ?? "Position \(j + 1)"
        return PositionChip(image: session.thumbnail(shot.frame, page: k), number: j + 1, label: nil, lit: lit, next: next,
                            enabled: !taking || route.page == k, help: j < 9 ? "\(name) (\(j + 1))" : name) {
            if taking {
                session.liveGo(j)
            } else {
                shown = j
                session.previewPosition(j)
            }
        }
    }
}

/// One position: what the camera sees there, small, with its number.
struct PositionChip: View {
    let image: CGImage?
    let number: Int?
    let label: String?
    let lit: Bool
    let next: Bool
    let enabled: Bool
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topLeading) {
                Group {
                    if let image {
                        Image(decorative: image, scale: 1).resizable().interpolation(.medium).aspectRatio(contentMode: .fill)
                    } else {
                        Theme.well
                    }
                }
                .frame(width: 52, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                Text(number.map { "\($0)" } ?? (label.map { "Slide \($0)" } ?? "Whole"))
                    .font(.system(size: 9, weight: .bold).monospacedDigit())
                    .foregroundStyle(lit ? .white : .black)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 3, style: .continuous).fill(lit ? Theme.camera : Color.white.opacity(0.85)))
                    .padding(3)
            }
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(lit ? Theme.camera : (next ? Theme.camera.opacity(0.7) : Theme.hairline),
                              style: StrokeStyle(lineWidth: lit ? 2 : 1, dash: next ? [3, 2] : [])))
            .scaleEffect(hover && enabled ? 1.05 : 1)
            .opacity(enabled ? 1 : 0.35)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hover = $0 }
        .animation(Theme.quick, value: hover)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(lit ? .isSelected : [])
    }
}

/// The inspector in Live: the opening, your positions, the closing, and you.
struct LiveInspector: View {
    @Bindable var session: OOOSession
    @AppStorage("live.camera") private var filmMe = true

    var body: some View {
        let p = session.project
        let open = !session.isTaking
        VStack(alignment: .leading, spacing: 0) {
            InspectorSection("Opening", accessory: {
                Button("Preview") { session.previewOpening() }
                    .buttonStyle(QuietButtonStyle())
                    .disabled(!open || session.liveKept)
            }) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                    ForEach(ArriveKind.allCases) { kind in
                        ArriveTile(kind: kind, selected: p.arrive.kind == kind) {
                            session.update("Arrival") { $0.arrive = Arrive(kind: kind, intensity: $0.arrive.intensity) }
                            session.previewOpening()
                        }
                    }
                }
                .disabled(!open)
                Text("How the slide enters once you press Start. You are recording from the first moment, so you can talk over it.")
                    .textStyle(.caption).foregroundStyle(.secondary)
            }
            Hairline()
            InspectorSection("Your positions") {
                PositionList(session: session)
                Text("During the take, press a position's number or click it to fly there, → for the next and ← for the one before, 0 for the whole slide. Draw more framings on the slide map in Frame.")
                    .textStyle(.caption).foregroundStyle(.tertiary)
            }
            Hairline()
            InspectorSection("Closing", accessory: {
                Button("Preview") { session.previewClosing() }
                    .buttonStyle(QuietButtonStyle())
                    .disabled(!open || session.liveKept)
            }) {
                ChoiceRow(Ending.allCases.map { ($0, $0.title) }, selection: Binding(
                    get: { session.project.ending },
                    set: { e in
                        session.update("Ending") { $0.ending = e }
                        session.previewClosing()
                    }))
                    .disabled(!open)
                Text("Plays when you press Close, still recording, so your sign-off is in the video. The recording stops by itself as it ends.")
                    .textStyle(.caption).foregroundStyle(.secondary)
            }
            Hairline()
            InspectorSection("You") {
                Toggle("Film me", isOn: Binding(get: { filmMe }, set: { session.setFilmMe($0) }))
                    .toggleStyle(.checkbox)
                    .textStyle(.bodyCompact)
                    .disabled(!open)
                HStack(spacing: 8) {
                    Image(systemName: "mic.fill").font(.system(size: 11)).foregroundStyle(.secondary)
                    LevelBars(levels: session.liveCapture.levels, count: 40, tint: .primary)
                        .frame(height: 16)
                }
                if let note = session.liveNote {
                    Text(note).textStyle(.caption).foregroundStyle(.secondary)
                }
                Text("Your Mac records your voice and your face together, so they never drift apart. Nothing leaves your computer.")
                    .textStyle(.caption).foregroundStyle(.tertiary)
            }
            Hairline()
            InspectorSection("Keys") {
                KeyLine(key: "Return", what: "Start, then Close")
                KeyLine(key: "→  Space", what: "Next position")
                KeyLine(key: "←", what: "The one before")
                KeyLine(key: "1 – 9", what: "Straight to a position")
                KeyLine(key: "0  ↑", what: "The whole slide")
                KeyLine(key: "↓", what: "On to the next slide")
                KeyLine(key: "D", what: "Draw as you talk")
                KeyLine(key: "⌘.", what: "Give the take up")
            }
        }
    }
}

/// A key and what it does.
struct KeyLine: View {
    let key: String
    let what: String

    var body: some View {
        HStack(spacing: 10) {
            Text(key).textStyle(.data).foregroundStyle(.primary)
                .frame(width: 70, alignment: .leading)
            Text(what).textStyle(.bodyCompact).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }
}

/// The positions as a list, in the order the camera visits them: click one
/// to see it, right-click to move it earlier or later.
struct PositionList: View {
    @Bindable var session: OOOSession

    var body: some View {
        let _ = session.version
        let p = session.project
        let shots = session.liveRoute?.script ?? session.orderedShots
        VStack(spacing: 3) {
            if shots.isEmpty {
                Text("No positions yet: the take holds on the whole slide. Draw framings on the slide map in Frame, or let OOO plan them with Direct for Me.")
                    .textStyle(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(shots.enumerated()), id: \.element.id) { j, shot in
                let k = p.pageIndex(shot.page)
                HStack(spacing: 8) {
                    Text("\(j + 1)").textStyle(.badge).foregroundStyle(.secondary).frame(width: 16)
                    Group {
                        if let img = session.thumbnail(shot.frame, page: k) {
                            Image(decorative: img, scale: 1).resizable().interpolation(.medium).aspectRatio(contentMode: .fill)
                        } else {
                            Theme.well
                        }
                    }
                    .frame(width: 44, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    Text(Director.spokenLabel(shot.label) ?? "Position \(j + 1)")
                        .textStyle(.bodyCompact).lineLimit(1)
                    Spacer(minLength: 0)
                    if p.slideCount > 1 {
                        Text("Slide \(k + 1)").textStyle(.caption).foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 2)
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
                .onTapGesture {
                    if session.isTaking { session.liveGo(j) } else { session.previewPosition(j) }
                }
                .contextMenu {
                    Button("Show It") { session.previewPosition(j) }
                        .disabled(session.isTaking)
                    Divider()
                    Button("Move Earlier") { session.moveShot(shot.id, by: -1) }
                        .disabled(session.isTaking)
                    Button("Move Later") { session.moveShot(shot.id, by: 1) }
                        .disabled(session.isTaking)
                }
            }
        }
    }
}
