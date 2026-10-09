import AppKit
import AVFoundation
import CoreMedia
import OOOCore
import OOOMotion
import QuartzCore
import RenderCore

/// A live take, kept, then back to Frame, on the real editor with the live
/// stage running, watched the whole way for memory and a main thread that
/// stops answering:
///
///     OOO --snapshot out.png --soak 45 [--slide file]
///
/// No camera here, so a stand-in recording of `--soak` seconds (a picture
/// like the camera's and a voice) is kept exactly as a take's recording is.
/// It then plays in Live, goes back to Frame, sits, plays, scrubs, scrolls
/// the playhead back and forth as a trackpad over the stage does, and rests,
/// logging every half second; the main thread is sampled in each stretch
/// (and whenever it stalls) into files beside the screenshot. Fails when
/// the window would have frozen or swamped the Mac.
@MainActor
enum OOOSoak {
    static var isRequested: Bool { OOOSnapshot.arg("--soak") != nil }

    /// More memory than this, or a main thread silent for longer, fails the run.
    static let memoryLimit: Double = 3000
    static let stallLimit: Double = 2
    /// Memory gained after going back to Frame, beyond what Frame settled at,
    /// and how long the 240 scroll steps (four seconds at sixty a second) may take.
    static let growthLimit: Double = 400
    static let scrollLimit: Double = 8

    static func run(_ session: OOOSession, done: @escaping (Int32) -> Void) {
        let seconds = max(OOOSnapshot.arg("--soak").flatMap(Double.init) ?? 45, 12)
        let dir = URL(fileURLWithPath: OOOSnapshot.arg("--snapshot") ?? "soak.png").deletingLastPathComponent()
        let monitor = SoakMonitor(samples: dir)
        let beat = Timer(timeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated { monitor.beat(time: session.clock.time, duration: session.clock.duration) }
        }
        RunLoop.main.add(beat, forMode: .common)
        monitor.start()
        Task { @MainActor in
            func wait(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }
            monitor.enter("live room")
            session.enter(.live)
            await wait(2)

            monitor.enter("recording")
            let take = session.soakTake(end: seconds)
            let movie = FileManager.default.temporaryDirectory.appendingPathComponent("Live take soak \(UUID().uuidString).mov")
            let length = take.recorded + 0.2
            let wrote = await Task.detached(priority: .userInitiated) { () -> String? in
                do {
                    try StandInRecording.write(to: movie, seconds: length)
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value
            if let wrote {
                print("soak: couldn't write the stand-in recording: \(wrote)")
                monitor.stop()
                done(5)
                return
            }
            print(String(format: "soak: the take closes at %.1f s and records to %.1f s", seconds, take.recorded))

            monitor.enter("keeping")
            do {
                try await session.keep(take.run, movie: movie, end: seconds, recorded: take.recorded)
            } catch {
                print("soak: couldn't keep the take: \(error.localizedDescription)")
            }
            try? FileManager.default.removeItem(at: movie)
            guard session.liveStep == .kept, session.project.face != nil else {
                print("soak: the take wasn't kept (step \(session.liveStep), face \(session.project.face == nil ? "none" : "kept"))")
                monitor.stop()
                done(5)
                return
            }
            print(String(format: "soak: kept, %d framings, %.1f s long", session.project.shots.count, session.clock.duration))

            monitor.enter("live, kept")
            session.playKept()
            await wait(1)
            monitor.sample("live-kept")
            await wait(6)

            monitor.enter("frame")
            session.liveDone()
            await wait(1)
            monitor.sample("frame")
            await wait(5)

            monitor.enter("frame, playing")
            session.clock.playing = true
            session.touch()
            await wait(1)
            monitor.sample("frame-playing")
            await wait(9)

            monitor.enter("frame, scrubbing")
            var g = SystemRandomNumberGenerator()
            for i in 0..<40 {
                session.clock.time = Double.random(in: 0...max(session.clock.duration, 0.1), using: &g)
                session.touch()
                if i == 6 { monitor.sample("frame-scrubbing") }
                await wait(0.15)
            }

            // Two fingers on the trackpad over the stage: small steps back,
            // then forward, sixty a second, as scrolling scrubs.
            monitor.enter("frame, scrolling")
            session.clock.playing = false
            session.clock.time = session.clock.duration * 0.6
            let scrollBegan = CACurrentMediaTime(), framesBefore = SoakCounts.shared.stageFrames
            for i in 0..<240 {
                let step = i < 150 ? -0.04 : 0.03
                session.clock.time = min(max(session.clock.time + step, 0), session.clock.duration)
                if i == 20 { monitor.sample("frame-scrolling") }
                await wait(1.0 / 60)
            }
            let scrolled = CACurrentMediaTime() - scrollBegan
            print(String(format: "soak: 240 scroll steps took %.1f s (limit %.0f), the stage drew %.0f frames a second",
                         scrolled, scrollLimit, Double(SoakCounts.shared.stageFrames - framesBefore) / max(scrolled, 0.001)))

            monitor.enter("frame, still")
            session.clock.playing = false
            session.touch()
            await wait(3)

            beat.invalidate()
            monitor.stop()
            let verdict = monitor.verdict(memoryLimit: memoryLimit, stallLimit: stallLimit, growthLimit: growthLimit,
                                          scrolled: scrolled, scrollLimit: scrollLimit)
            print(verdict.line)
            done(verdict.ok ? 0 : 4)
        }
    }
}

extension OOOSession {
    /// A take for the soak test, led as you would: the route's stops a few
    /// seconds apart, closed at `end`, the closing recorded to its end. The
    /// recording is supplied afterwards, so this records nothing.
    func soakTake(end: Double) -> (run: LiveRun, recorded: Double) {
        settleEdits()
        let before = project
        let stage = before.liveStage(filming: true)
        let run = LiveRun(take: LiveTake(stage.choreographyInput), before: before, filming: true)
        staged = nil
        roomTake = nil
        liveKept = false
        keptBefore = nil
        previewUntil = nil
        selection = .overview
        take = run
        set(stage)
        var t = 2.5
        while t < end - 2, run.take.step(.next, at: t) { t += 3.5 }
        let length = project.closingLength(run.take, end: end, filming: true)
        run.end = end
        run.stopAt = length
        run.held = length
        liveKeeping = true
        clock.playing = false
        show(run.take.closing(at: end, length: length))
        return (run, length)
    }
}

/// Watches the app from a thread of its own: memory, the GPU's share, how
/// late the main thread answers, and how much the stage and the camera
/// recording are read. Prints a line every half second.
final class SoakMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private let samples: URL
    private var tick = CACurrentMediaTime()
    private var time = 0.0, duration = 0.0
    private var phase = "starting"
    private var running = false
    private var stallSampled = false
    private var worst: [(phase: String, memory: Double, late: Double)] = []
    private let began = CACurrentMediaTime()

    init(samples: URL) {
        self.samples = samples
    }

    func beat(time: Double, duration: Double) {
        lock.withLock {
            tick = CACurrentMediaTime()
            self.time = time
            self.duration = duration
        }
    }

    func enter(_ p: String) {
        lock.withLock {
            phase = p
            worst.append((phase: p, memory: 0, late: 0))
        }
        print("soak: \(p)")
        fflush(stdout)
    }

    func start() {
        lock.withLock { running = true }
        Thread.detachNewThread { [self] in watch() }
    }

    func stop() {
        lock.withLock { running = false }
    }

    /// Samples the main thread for two seconds into `soak-<name>.sample.txt`, without waiting.
    func sample(_ name: String) {
        let file = samples.appendingPathComponent("soak-\(name).sample.txt")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        p.arguments = [String(ProcessInfo.processInfo.processIdentifier), "2", "-file", file.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    private func watch() {
        var lastLine = CACurrentMediaTime()
        var late = 0.0
        while lock.withLock({ running }) {
            Thread.sleep(forTimeInterval: 0.1)
            let now = CACurrentMediaTime()
            let (tick, time, duration, phase) = lock.withLock { (self.tick, self.time, self.duration, self.phase) }
            let gap = now - tick
            late = max(late, gap)
            if gap > 3, !stallSampled {
                stallSampled = true
                print(String(format: "soak: the main thread hasn't answered for %.1f s (%@); sampling it", gap, phase))
                sample("stall")
            }
            guard now - lastLine >= 0.5 else { continue }
            lastLine = now
            let memory = Self.footprint()
            let gpu = Double(GPU.shared.device.currentAllocatedSize) / 1_048_576
            let face = FaceCounts.shared.now
            let named = phase.padding(toLength: 17, withPad: " ", startingAt: 0)
            print(String(format: "soak %6.1f s  %@ t %6.2f/%6.2f  memory %5.0f MB  gpu %5.0f MB  main late %5.2f s  stage frames %6d  face frames %6d  restarts %5d  sessions %d",
                         now - began, named, time, duration, memory, gpu, late, SoakCounts.shared.stageFrames,
                         face.frames, face.restarts, SoakCounts.shared.sessions))
            fflush(stdout)
            lock.withLock {
                if var w = worst.last {
                    w.memory = max(w.memory, memory)
                    w.late = max(w.late, late)
                    worst[worst.count - 1] = w
                }
            }
            late = 0
        }
    }

    func verdict(memoryLimit: Double, stallLimit: Double, growthLimit: Double,
                 scrolled: Double, scrollLimit: Double) -> (ok: Bool, line: String) {
        let w = lock.withLock { worst }
        var lines = w.map { String(format: "soak: worst in %@: memory %.0f MB, main thread late %.2f s", $0.phase, $0.memory, $0.late) }
        let memory = w.map(\.memory).max() ?? 0, late = w.map(\.late).max() ?? 0
        let settled = w.first { $0.phase == "frame" }?.memory ?? memory
        let after = w.drop(while: { $0.phase != "frame" }).map(\.memory).max() ?? settled
        let grew = after - settled
        let ok = memory <= memoryLimit && late <= stallLimit && grew <= growthLimit && scrolled <= scrollLimit
        lines.append(String(format: "soak: %@ (most memory %.0f MB, limit %.0f; grew %.0f MB after Frame settled, limit %.0f; "
                                + "longest the main thread was late %.2f s, limit %.1f; scrolling took %.1f s, limit %.0f)",
                            ok ? "passed" : "FAILED", memory, memoryLimit, grew, growthLimit, late, stallLimit, scrolled, scrollLimit))
        return (ok, lines.joined(separator: "\n"))
    }

    /// The memory macOS counts against the app (Activity Monitor's Memory column), in MB.
    static func footprint() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }
}

/// Frames the live stage has drawn, and editor sessions made (SwiftUI may
/// make and drop them as it rebuilds the window), since launch, for the soak test.
final class SoakCounts: @unchecked Sendable {
    static let shared = SoakCounts()
    private let lock = NSLock()
    private var frames = 0
    private var made = 0

    func stageFrame() { lock.withLock { frames += 1 } }
    func session() { lock.withLock { made += 1 } }
    var stageFrames: Int { lock.withLock { frames } }
    var sessions: Int { lock.withLock { made } }
}

/// A recording like a live take's: a picture of someone in a room, HEVC as
/// the camera writes it (H.264 where this Mac can't), and a voice-like
/// sound, `seconds` long.
enum StandInRecording {
    static func write(to url: URL, seconds: Double, width: Int = 1920, height: Int = 1080) throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        var settings: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: width, AVVideoHeightKey: height]
        if !writer.canApply(outputSettings: settings, forMediaType: .video) { settings[AVVideoCodecKey] = AVVideoCodecType.h264 }
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        video.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        let rate = 48_000.0
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 96_000,
        ])
        audio.expectsMediaDataInRealTime = false
        writer.add(video)
        writer.add(audio)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        let fps = 30
        let frames = Int((seconds * Double(fps)).rounded(.up)), sampleCount = Int((seconds * rate).rounded(.up))
        let state = WriteState()
        let group = DispatchGroup()
        group.enter()
        group.enter()
        video.requestMediaDataWhenReady(on: DispatchQueue(label: "dog.pitch.ooo.soak.video")) {
            while video.isReadyForMoreMediaData {
                guard let n = state.nextFrame(of: frames) else {
                    if state.finish(video: true) {
                        video.markAsFinished()
                        group.leave()
                    }
                    return
                }
                guard let pool = adaptor.pixelBufferPool else { continue }
                var buffer: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
                guard let pb = buffer else { continue }
                CVPixelBufferLockBaseAddress(pb, [])
                if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: width, height: height, bitsPerComponent: 8,
                                       bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                       bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
                    draw(ctx, width: CGFloat(width), height: CGFloat(height), t: Double(n) / Double(fps))
                }
                CVPixelBufferUnlockBaseAddress(pb, [])
                adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(n), timescale: CMTimeScale(fps)))
            }
        }
        audio.requestMediaDataWhenReady(on: DispatchQueue(label: "dog.pitch.ooo.soak.audio")) {
            while audio.isReadyForMoreMediaData {
                guard let start = state.nextSamples(1024, of: sampleCount) else {
                    if state.finish(video: false) {
                        audio.markAsFinished()
                        group.leave()
                    }
                    return
                }
                if let sb = voice(from: start, count: min(1024, sampleCount - start), rate: rate) { audio.append(sb) }
            }
        }
        group.wait()
        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        finished.wait()
        if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }

    final class WriteState: @unchecked Sendable {
        private let lock = NSLock()
        private var frame = 0, sample = 0
        private var videoDone = false, audioDone = false

        func nextFrame(of total: Int) -> Int? {
            lock.withLock {
                guard frame < total else { return nil }
                frame += 1
                return frame - 1
            }
        }

        func nextSamples(_ n: Int, of total: Int) -> Int? {
            lock.withLock {
                guard sample < total else { return nil }
                sample += n
                return sample - n
            }
        }

        /// True the first time each input finishes.
        func finish(video: Bool) -> Bool {
            lock.withLock {
                if video {
                    defer { videoDone = true }
                    return !videoDone
                }
                defer { audioDone = true }
                return !audioDone
            }
        }
    }

    /// A warm room and someone in it, swaying a little.
    private static func draw(_ ctx: CGContext, width w: CGFloat, height h: CGFloat, t: Double) {
        ctx.setFillColor(CGColor(srgbRed: 0.33, green: 0.28, blue: 0.25, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let cx = w / 2 + CGFloat(sin(t * 1.3) * 18 + sin(t * 0.47) * 10)
        ctx.setFillColor(CGColor(srgbRed: 0.13, green: 0.16, blue: 0.22, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: cx - w * 0.3, y: -h * 0.35, width: w * 0.6, height: h * 0.62))
        ctx.setFillColor(CGColor(srgbRed: 0.86, green: 0.67, blue: 0.55, alpha: 1))
        ctx.fill(CGRect(x: cx - w * 0.04, y: h * 0.2, width: w * 0.08, height: h * 0.15))
        ctx.fillEllipse(in: CGRect(x: cx - w * 0.095, y: h * 0.3, width: w * 0.19, height: h * 0.44))
    }

    /// A voice-like hum: a low tone in syllables, for `count` samples from `start`.
    private static func voice(from start: Int, count: Int, rate: Double) -> CMSampleBuffer? {
        var asbd = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
                                               mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                                               mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1,
                                               mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                       magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        let bytes = count * 2
        var block: CMBlockBuffer?
        guard let format,
              CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: bytes, flags: kCMBlockBufferAssureMemoryNowFlag,
                                                 blockBufferOut: &block) == kCMBlockBufferNoErr,
              let block else { return nil }
        var pcm = [Int16](repeating: 0, count: count)
        for i in 0..<count {
            let t = Double(start + i) / rate
            let syllables = max(0, sin(t * 2 * .pi * 3.1)) * (0.6 + 0.4 * sin(t * 0.7))
            let tone = sin(t * 2 * .pi * 180) * 0.6 + sin(t * 2 * .pi * 360) * 0.25
            pcm[i] = Int16(max(-1, min(1, tone * syllables * 0.5)) * 32767)
        }
        let copied = pcm.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes)
        }
        guard copied == kCMBlockBufferNoErr else { return nil }
        var sample: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
                                                            sampleCount: count,
                                                            presentationTimeStamp: CMTime(value: CMTimeValue(start), timescale: CMTimeScale(rate)),
                                                            packetDescriptions: nil, sampleBufferOut: &sample)
        return sample
    }
}
