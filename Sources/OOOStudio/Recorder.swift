import AppKit
import AVFoundation
import Observation
import OOOCore
import SwiftUI

/// A scratch voiceover recorded in OOO: a count of three, then you talk the
/// video through as it plays from the start, and the moves are cut to what
/// you said. Good enough to find the beats; record the real one later.
@Observable
@MainActor
public final class VoiceRecorder {
    /// 3, 2, 1 before it records; nil otherwise.
    public private(set) var counting: Int?
    public private(set) var isRecording = false
    /// Seconds recorded so far.
    public private(set) var elapsed: Double = 0
    /// How loud the last few seconds were, 0…1, newest last.
    public private(set) var levels: [Float] = []

    /// Counting in or recording.
    public var isActive: Bool { counting != nil || isRecording }

    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var meter: Timer?
    @ObservationIgnored private var countIn: Task<Void, Never>?
    @ObservationIgnored private var file: URL?

    static let shownLevels = 64

    public init() {}

    /// Asks for the microphone if it must, counts in, then records;
    /// `started` runs as the recording starts.
    func start(started: @escaping () -> Void, failed: @escaping (String) -> Void) {
        guard !isActive else { return }
        let denied = "OOO can't hear the microphone. Allow it in System Settings › Privacy & Security › Microphone, then try again."
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            count(started: started, failed: failed)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        if ok { self.count(started: started, failed: failed) } else { failed(denied) }
                    }
                }
            }
        default:
            failed(denied)
        }
    }

    private func count(started: @escaping () -> Void, failed: @escaping (String) -> Void) {
        levels = []
        elapsed = 0
        countIn = Task { [weak self] in
            for n in [3, 2, 1] {
                self?.counting = n
                try? await Task.sleep(nanoseconds: 750_000_000)
                if Task.isCancelled { return }
            }
            guard let self else { return }
            self.counting = nil
            do {
                try self.record()
                started()
            } catch {
                failed("Couldn't start recording: \(readable(error))")
            }
        }
    }

    private func record() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Scratch take \(Int(Date().timeIntervalSince1970)).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 128_000,
        ]
        let r = try AVAudioRecorder(url: url, settings: settings)
        r.isMeteringEnabled = true
        guard r.record() else { throw CocoaError(.fileWriteUnknown) }
        recorder = r
        file = url
        isRecording = true
        meter = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.listen() }
        }
    }

    private func listen() {
        guard let r = recorder else { return }
        r.updateMeters()
        // Loudness the way it sounds: -50 dB is silence, 0 dB as loud as it gets.
        let db = r.averagePower(forChannel: 0)
        let level = powf(max(0, min(1, (db + 50) / 50)), 1.6)
        levels.append(level)
        if levels.count > Self.shownLevels { levels.removeFirst(levels.count - Self.shownLevels) }
        elapsed = r.currentTime
    }

    /// Stops; returns the take, or nil if there is nothing worth keeping
    /// (stopped during the count, or under half a second).
    func stop() -> URL? {
        countIn?.cancel()
        countIn = nil
        counting = nil
        meter?.invalidate()
        meter = nil
        guard let r = recorder else { return nil }
        let length = r.currentTime
        r.stop()
        recorder = nil
        isRecording = false
        defer { file = nil }
        guard length > 0.5 else {
            if let file { try? FileManager.default.removeItem(at: file) }
            return nil
        }
        return file
    }
}

extension OOOSession {
    /// Counts you in, then records while the video plays from the start.
    public func startRecording() {
        guard !recorder.isActive, !isLive else { return }
        if pen.on { finishDrawing(replay: false) }
        clock.playing = false
        tab = .voice
        recorder.start(started: { [weak self] in
            guard let self else { return }
            self.clock.time = 0
            self.clock.playing = true
        }, failed: { [weak self] why in
            self?.message = why
        })
    }

    /// Stops recording: the take becomes the voiceover, its words are heard,
    /// and the moves are cut to them.
    public func stopRecording() {
        let take = recorder.stop()
        clock.playing = false
        guard let take else { return }
        let when = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)
        importVoice(take, name: "Scratch take, \(when)", offset: 0)
    }

    public func toggleRecording() {
        if recorder.isActive { stopRecording() } else { startRecording() }
    }
}

// MARK: - Views

/// Over the stage while recording: the count, then a small live meter.
struct RecordingOverlay: View {
    let recorder: VoiceRecorder

    var body: some View {
        ZStack {
            if let n = recorder.counting {
                Text("\(n)")
                    .font(.system(size: 60, weight: .light, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 112, height: 112)
                    .background(Circle().fill(.black.opacity(0.32)))
                    .id(n)
                    .transition(.asymmetric(insertion: .scale(scale: 1.25).combined(with: .opacity),
                                            removal: .scale(scale: 0.85).combined(with: .opacity)))
            }
            if recorder.isRecording {
                VStack {
                    Spacer()
                    RecordingPill(recorder: recorder)
                        .padding(.bottom, 14)
                }
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.3), value: recorder.counting)
        .animation(.easeOut(duration: 0.3), value: recorder.isRecording)
        .allowsHitTesting(false)
    }
}

/// A breathing red dot, the time, and your voice as it comes in.
struct RecordingPill: View {
    let recorder: VoiceRecorder
    @State private var breathe = false

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(Color(.sRGB, red: 0.92, green: 0.22, blue: 0.18))
                .frame(width: 8, height: 8)
                .opacity(breathe ? 1 : 0.45)
                .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: breathe)
                .onAppear { breathe = true }
            Text(String(format: "%d:%02d", Int(recorder.elapsed) / 60, Int(recorder.elapsed) % 60))
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.white)
            LevelBars(levels: recorder.levels, count: 40)
                .frame(width: 96, height: 16)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(.black.opacity(0.45)))
    }
}

/// The last moments of a voice, as soft bars, newest on the right.
struct LevelBars: View {
    let levels: [Float]
    let count: Int
    var tint: Color = .white

    var body: some View {
        Canvas { ctx, size in
            let shown = Array(levels.suffix(count))
            let step = size.width / CGFloat(count)
            let w = max(step * 0.55, 1)
            for (i, l) in shown.enumerated() {
                let h = max(CGFloat(l) * size.height, 1.5)
                let x = size.width - CGFloat(shown.count - i) * step
                let r = CGRect(x: x, y: (size.height - h) / 2, width: w, height: h)
                ctx.fill(Path(roundedRect: r, cornerRadius: w / 2), with: .color(tint.opacity(0.35 + 0.65 * Double(l))))
            }
        }
    }
}
