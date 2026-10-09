import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import OOOCore
import OOOMotion

/// A stand-in for a camera recording, since CI's Mac has no camera: someone
/// at a desk, swaying a little and talking, with a clock along the bottom
/// so a frame shows when it was taken, and a badge on their right shoulder so
/// a mirror shows. 1280 × 720 at 30 fps, as a Mac's camera records.
func writeStandIn(to url: URL, seconds: Double, width: Int = 1280, height: Int = 720) throws {
    try? FileManager.default.removeItem(at: url)
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
    ])
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
    ])
    writer.add(input)
    guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    writer.startSession(atSourceTime: .zero)
    let fps = 30
    let frames = Int((seconds * Double(fps)).rounded(.up))
    for n in 0..<frames {
        while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
        guard let pool = adaptor.pixelBufferPool else { throw CocoaError(.fileWriteUnknown) }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let pb = buffer else { throw CocoaError(.fileWriteUnknown) }
        CVPixelBufferLockBaseAddress(pb, [])
        let t = Double(n) / Double(fps)
        if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: width, height: height, bitsPerComponent: 8,
                               bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                               bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
            drawStandIn(ctx, width: CGFloat(width), height: CGFloat(height), t: t, length: seconds)
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(n), timescale: CMTimeScale(fps)))
    }
    input.markAsFinished()
    let done = DispatchSemaphore(value: 0)
    writer.finishWriting { done.signal() }
    done.wait()
    if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
}

private func drawStandIn(_ ctx: CGContext, width w: CGFloat, height h: CGFloat, t: Double, length: Double) {
    let rgb = CGColorSpace(name: CGColorSpace.sRGB)!
    // A warm room behind.
    let wall = CGGradient(colorsSpace: rgb, colors: [CGColor(srgbRed: 0.42, green: 0.36, blue: 0.31, alpha: 1),
                                                     CGColor(srgbRed: 0.2, green: 0.17, blue: 0.16, alpha: 1)] as CFArray,
                          locations: [0, 1])!
    ctx.drawLinearGradient(wall, start: CGPoint(x: 0, y: h), end: CGPoint(x: 0, y: 0), options: [])
    let sway = CGFloat(sin(t * 1.3) * 10 + sin(t * 0.47) * 6)
    let cx = w / 2 + sway
    // Shoulders, and a badge on their right (the left of the picture).
    ctx.setFillColor(CGColor(srgbRed: 0.13, green: 0.16, blue: 0.22, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: cx - w * 0.3, y: -h * 0.35, width: w * 0.6, height: h * 0.62))
    ctx.setFillColor(CGColor(srgbRed: 0.95, green: 0.62, blue: 0.13, alpha: 1))
    ctx.fill(CGRect(x: cx - w * 0.17, y: h * 0.12, width: w * 0.035, height: w * 0.035))
    // Neck and head.
    let skin = CGColor(srgbRed: 0.86, green: 0.67, blue: 0.55, alpha: 1)
    ctx.setFillColor(skin)
    ctx.fill(CGRect(x: cx - w * 0.04, y: h * 0.2, width: w * 0.08, height: h * 0.15))
    let head = CGRect(x: cx - w * 0.095, y: h * 0.3, width: w * 0.19, height: h * 0.44)
    ctx.fillEllipse(in: head)
    ctx.setFillColor(CGColor(srgbRed: 0.18, green: 0.12, blue: 0.09, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: head.minX - 4, y: head.midY + head.height * 0.18, width: head.width + 8, height: head.height * 0.38))
    // Eyes that blink now and then, and a mouth that talks.
    let blink = (t.truncatingRemainder(dividingBy: 3.7)) < 0.12
    ctx.setFillColor(CGColor(srgbRed: 0.1, green: 0.08, blue: 0.08, alpha: 1))
    for side: CGFloat in [-1, 1] {
        ctx.fillEllipse(in: CGRect(x: head.midX + side * head.width * 0.2 - 7, y: head.midY + 6, width: 14, height: blink ? 2 : 12))
    }
    let open = CGFloat(max(0, sin(t * 11) * sin(t * 2.3))) * 16 + 3
    ctx.setFillColor(CGColor(srgbRed: 0.45, green: 0.18, blue: 0.18, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: head.midX - 22, y: head.midY - head.height * 0.24 - open / 2, width: 44, height: open))
    // A clock along the bottom: how far into the recording this frame is.
    ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.25))
    ctx.fill(CGRect(x: w * 0.1, y: h * 0.04, width: w * 0.8, height: 4))
    ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.9))
    ctx.fillEllipse(in: CGRect(x: w * 0.1 + w * 0.8 * CGFloat(t / max(length, 0.1)) - 7, y: h * 0.04 - 5, width: 14, height: 14))
}

/// A live take as the app records one, from presses written out: times in
/// seconds, each a step to the next stop unless it ends in b (back) or w
/// (the whole slide), or a click at a place on the slide (`@0.3:0.6`).
/// "4,8,12.5b,15@0.7:0.55".
struct LabTake {
    enum Press {
        case step(LiveTake.Step)
        case look(Vec2)
    }

    var presses: [(at: Double, press: Press)]

    init?(_ spec: String) {
        presses = []
        for part in spec.split(separator: ",").map(String.init) {
            var text = part
            var press = Press.step(.next)
            if let at = text.firstIndex(of: "@") {
                let place = text[text.index(after: at)...].split(separator: ":").compactMap { Float($0) }
                guard place.count == 2 else { return nil }
                press = .look(Vec2(place[0], place[1]))
                text = String(text[..<at])
            } else if text.hasSuffix("b") {
                press = .step(.back)
                text.removeLast()
            } else if text.hasSuffix("w") {
                press = .step(.whole)
                text.removeLast()
            }
            guard let t = Double(text) else { return nil }
            presses.append((t, press))
        }
        presses.sort { $0.at < $1.at }
    }

    /// Plays the presses on `project` as it plays during a take, ending at
    /// `end`; returns the take and, for each press, what it did.
    func play(on stage: OOOProject, end: Double) -> (take: LiveTake, lines: [String], waits: [Double]) {
        var take = LiveTake(stage.choreographyInput)
        var lines: [String] = []
        var waits: [Double] = []
        for (t, press) in presses where t < end {
            let did: Bool
            let what: String
            switch press {
            case .step(let s):
                did = take.step(s, at: t)
                what = "\(s)"
            case .look(let p):
                let view = take.choreography.pose(at: t).frame(slideAspect: take.base.aspects[take.page], canvasAspect: stage.canvasAspect)
                let target = stage.liveTarget(take, at: p, view: view)
                did = take.look(target.shot, stop: target.stop, at: t)
                what = String(format: "click %.2f, %.2f", p.x, p.y)
            }
            guard did, let d = take.departures.last else {
                lines.append(String(format: "%6.2f s  %@: nowhere to go", t, what))
                continue
            }
            let label = take.visits.last(where: { $0.id == d.id })?.label ?? (d.id == nil ? "the next slide" : "?")
            let land = take.choreography.beats.first { $0.shot.id == d.id }?.land
            waits.append(d.at - t)
            lines.append(String(format: "%6.2f s  %@ → %@: sets off %.2f s (%@), lands %@", t, what, label, d.at,
                                d.at - t < 1e-3 ? "as pressed" : String(format: "waited %.2f s", d.at - t),
                                land.map { String(format: "%.2f s", $0) } ?? "with the card"))
        }
        return (take, lines, waits)
    }
}

/// How different two frames are in the room at the bottom (`room` of the
/// height): the mean change per channel, 0…1.
func roomDifference(_ a: CGImage, _ b: CGImage, room: Float) -> Double {
    func pixels(_ img: CGImage) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: img.width * img.height * 4)
        data.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: img.width, height: img.height, bitsPerComponent: 8,
                                      bytesPerRow: img.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        }
        return data
    }
    guard a.width == b.width, a.height == b.height else { return 1 }
    let pa = pixels(a), pb = pixels(b)
    // Rows run from the top in memory: the room is the last rows.
    let first = Int(Float(a.height) * (1 - room)), w = a.width
    var sum = 0.0, count = 0
    for y in first..<a.height {
        for x in 0..<w {
            let i = (y * w + x) * 4
            for c in 0..<3 { sum += Double(abs(Int(pa[i + c]) - Int(pb[i + c]))) }
            count += 3
        }
    }
    return count > 0 ? sum / Double(count) / 255 : 0
}
