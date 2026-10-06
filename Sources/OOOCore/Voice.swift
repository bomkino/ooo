import AVFoundation
import Foundation
import OOOMotion
import RenderCore
import Speech
import UniformTypeIdentifiers

/// The voiceover: decoding, a waveform for the timeline, and the words in it.
public enum VoiceLoader {
    public static let types: [UTType] = [.audio, .mpeg4Audio, .mp3, .wav, .aiff]

    /// Decodes any audio file AVFoundation reads into 48 kHz stereo.
    public static func decode(_ url: URL) throws -> AudioTrack {
        let file = try AVAudioFile(forReading: url)
        let inFormat = file.processingFormat
        let channels = max(Int(inFormat.channelCount), 1)
        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(AudioTrack.sampleRate),
                                            channels: AVAudioChannelCount(channels), interleaved: false),
              let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw RenderError.io("This recording's format can't be read.")
        }
        let inCapacity: AVAudioFrameCount = 16_384
        guard let inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: inCapacity) else {
            throw RenderError.io("Out of memory reading the recording.")
        }
        let ratio = Double(AudioTrack.sampleRate) / inFormat.sampleRate
        let outCapacity = AVAudioFrameCount(Double(inCapacity) * ratio) + 2048
        var samples: [Float] = []
        samples.reserveCapacity(Int(Double(file.length) * ratio * 2) + 8192)
        let state = DecodeState()
        while true {
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCapacity) else { break }
            var error: NSError?
            let status = converter.convert(to: outBuffer, error: &error) { _, outStatus in
                if state.ended {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    try file.read(into: inBuffer)
                } catch {
                    state.ended = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                if inBuffer.frameLength == 0 {
                    state.ended = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                outStatus.pointee = .haveData
                return inBuffer
            }
            if let error { throw error }
            let n = Int(outBuffer.frameLength)
            if n > 0, let data = outBuffer.floatChannelData {
                let left = data[0], right = data[min(1, channels - 1)]
                for i in 0..<n {
                    samples.append(left[i])
                    samples.append(right[i])
                }
            }
            if status == .endOfStream || status == .error || (n == 0 && state.ended) { break }
        }
        return AudioTrack(samples: samples)
    }

    final class DecodeState: @unchecked Sendable {
        var ended = false
    }

    /// The voice placed on the video's timeline: shifted by its offset, scaled
    /// by its gain, cut or padded to `duration`.
    public static func placed(_ track: AudioTrack, offset: Double, gain: Float, duration: Double) -> AudioTrack {
        let rate = Double(AudioTrack.sampleRate)
        let total = max(Int((duration * rate).rounded()), 0)
        var out = [Float](repeating: 0, count: total * 2)
        let shift = Int((offset * rate).rounded())
        track.samples.withUnsafeBufferPointer { src in
            for i in 0..<total {
                let j = i - shift
                guard j >= 0, j < track.frames else { continue }
                out[2 * i] = src[2 * j] * gain
                out[2 * i + 1] = src[2 * j + 1] * gain
            }
        }
        // A few milliseconds of fade at a cut keep the edge from clicking.
        let fade = min(Int(rate * 0.006), total)
        for k in 0..<fade {
            let g = Float(k) / Float(max(fade, 1))
            let i = total - 1 - k
            out[2 * i] *= g
            out[2 * i + 1] *= g
        }
        return AudioTrack(samples: out)
    }
}

/// Peaks of the voice, for drawing it on the timeline.
public struct Waveform: Sendable {
    /// 0…1, one per bucket.
    public let peaks: [Float]
    public let bucketSeconds: Double

    public init(_ track: AudioTrack, bucketsPerSecond: Double = 120) {
        let per = max(Int(Double(AudioTrack.sampleRate) / bucketsPerSecond), 1)
        let count = (track.frames + per - 1) / per
        var peaks = [Float](repeating: 0, count: count)
        track.samples.withUnsafeBufferPointer { s in
            for b in 0..<count {
                var m: Float = 0
                let start = b * per, end = min(start + per, track.frames)
                var i = start
                while i < end {
                    m = max(m, abs(s[2 * i]), abs(s[2 * i + 1]))
                    i += 1
                }
                peaks[b] = m
            }
        }
        // Normalised to the loudest moment, with a gentle curve so quiet
        // speech still shows.
        let top = max(peaks.max() ?? 1, 1e-4)
        self.peaks = peaks.map { powf($0 / top, 0.7) }
        bucketSeconds = Double(per) / Double(AudioTrack.sampleRate)
    }

    public var duration: Double { Double(peaks.count) * bucketSeconds }

    /// The loudest peak between two times (seconds into the recording).
    public func peak(from a: Double, to b: Double) -> Float {
        guard !peaks.isEmpty else { return 0 }
        let i0 = max(0, min(peaks.count - 1, Int(a / bucketSeconds)))
        let i1 = max(i0, min(peaks.count - 1, Int(b / bucketSeconds)))
        return peaks[i0...i1].max() ?? 0
    }
}

/// Finds the words in the voiceover, with their times, on this Mac.
public enum Transcriber {
    public enum Failure: Error, CustomStringConvertible {
        case notAllowed
        case unavailable
        /// This Mac can't recognise the language without sending the
        /// recording to Apple, which OOO never does.
        case notOnDevice(String)
        case nothingHeard

        public var description: String {
            switch self {
            case .notAllowed: return "OOO isn't allowed to recognise speech. Turn it on in System Settings › Privacy & Security › Speech Recognition."
            case .unavailable: return "Speech recognition isn't available for this language on this Mac."
            case .notOnDevice(let language):
                return "This Mac can't recognise \(language) speech by itself, and OOO never sends your recording away. "
                    + "Add the language for dictation in System Settings › Keyboard › Dictation, then choose Transcribe again."
            case .nothingHeard: return "No words were heard in the recording."
            }
        }
    }

    public static func authorize() async -> Bool {
        if SFSpeechRecognizer.authorizationStatus() == .authorized { return true }
        return await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in cont.resume(returning: status == .authorized) }
        }
    }

    /// The words in `url`, times relative to the recording.
    public static func words(in url: URL, locale: Locale = .current) async throws -> [SpokenWord] {
        guard await authorize() else { throw Failure.notAllowed }
        guard let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer(), recognizer.isAvailable else {
            throw Failure.unavailable
        }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        request.taskHint = .dictation
        // Only ever on this Mac: the Voice panel promises nothing leaves it.
        guard recognizer.supportsOnDeviceRecognition else {
            let name = Locale.current.localizedString(forIdentifier: recognizer.locale.identifier) ?? recognizer.locale.identifier
            throw Failure.notOnDevice(name)
        }
        request.requiresOnDeviceRecognition = true
        request.addsPunctuation = true
        let once = Once()
        let words: [SpokenWord] = try await withCheckedThrowingContinuation { cont in
            let task = recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    if once.claim() { cont.resume(throwing: error) }
                    return
                }
                guard let result, result.isFinal else { return }
                let words = result.bestTranscription.segments.map {
                    SpokenWord(text: $0.substring, start: $0.timestamp, end: $0.timestamp + $0.duration, confidence: $0.confidence)
                }
                if once.claim() { cont.resume(returning: words) }
            }
            once.task = task
        }
        if words.isEmpty { throw Failure.nothingHeard }
        return words
    }

    final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        var task: SFSpeechRecognitionTask?

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }
}
