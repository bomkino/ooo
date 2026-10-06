import CoreGraphics
import CoreText
import Foundation
import OOOMotion
import StageKit

/// Sets an opening title and places it in time and on the frame.
public enum OpeningTitleArt {
    /// Where the words go, as fractions of the frame height from the top: the
    /// clear band above the slide as it rests at the opening, inside the
    /// platform's safe area; below the slide when there is more room there.
    public static func band(opening: CameraPose, slideAspect A: Float, canvasAspect C: Float, safe: SafeArea) -> (top: Float, bottom: Float) {
        let corners = [Vec2(0, 0), Vec2(1, 0), Vec2(0, 1), Vec2(1, 1)].map { Vec3(($0.x - 0.5) * A, 0.5 - $0.y, 0) }
        guard let box = opening.bounds(of: corners, canvasAspect: C) else { return (safe.top + 0.02, 0.3) }
        let slideTop = (1 - box.w) / 2, slideBottom = (1 - box.y) / 2
        let above = (top: safe.top + 0.015, bottom: slideTop - 0.035)
        let below = (top: slideBottom + 0.035, bottom: 1 - safe.bottom - 0.015)
        let roomAbove = above.bottom - above.top, roomBelow = below.bottom - below.top
        if roomAbove >= 0.07 || roomAbove >= roomBelow { return (above.top, max(above.bottom, above.top + 0.04)) }
        return (below.top, below.bottom)
    }

    /// Opacity and how far below its place the title sits (a share of the
    /// frame height) at `t`: it rises in as the slide comes to rest, clears
    /// as the camera sets off for the first detail, and comes back as the
    /// camera pulls back to the whole slide.
    public static func presence(_ c: Choreography, at t: Double) -> (alpha: Float, drop: Float) {
        guard let first = c.beats.first else { return (0, 0) }
        let fadeIn = 0.8, fadeOut = 0.45
        let start = max(first.land - 0.45, 0.15)
        var shown = clamp01(Float((t - start) / fadeIn))
        var rise = shown
        if c.beats.count > 1, !c.beats[1].isOverview {
            shown *= 1 - clamp01(Float((t - c.beats[1].depart) / fadeOut))
            if let last = c.beats.last, last.isOverview, c.beats.count > 2, t > c.beats[1].depart {
                let back = clamp01(Float((t - (last.land - 0.5)) / fadeIn))
                if back > shown {
                    shown = back
                    rise = back
                }
            }
        }
        let settle = 1 - rise
        return (smoothstep(shown), 0.016 * settle * settle * settle)
    }

    /// The words drawn over a transparent `width` × `height` frame,
    /// premultiplied, centred in the band `top`…`bottom` (fractions of the
    /// height from the top). Light ink for a dark backdrop, dark for a light one.
    public static func draw(_ title: OpeningTitle, width: Int, height: Int, band: (top: Float, bottom: Float), lightInk: Bool) -> CGImage? {
        guard !title.isEmpty, width > 0, height > 0,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let W = CGFloat(width), H = CGFloat(height)
        let bandTop = CGFloat(band.top) * H, bandHeight = max(CGFloat(band.bottom - band.top) * H, H * 0.04)
        let maxWidth = W * 0.84
        let ink = lightInk ? CGColor(srgbRed: 0.97, green: 0.96, blue: 0.94, alpha: 1) : CGColor(srgbRed: 0.08, green: 0.08, blue: 0.09, alpha: 1)
        let text = title.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let kicker = title.kicker.trimmingCharacters(in: .whitespacesAndNewlines)

        // The largest setting that fits the band in at most three lines.
        var size = min(H * 0.052, W * 0.085, bandHeight * 0.62)
        var block: (kicker: NSAttributedString?, kickerSize: CGSize, title: NSAttributedString?, titleSize: CGSize, gap: CGFloat)
        repeat {
            let k = kicker.isEmpty ? nil : setting(kicker, kicker: true, face: title.face, size: size, ink: ink)
            let t = text.isEmpty ? nil : setting(text, kicker: false, face: title.face, size: size, ink: ink)
            let ks = k.map { measure($0, width: maxWidth) } ?? .zero
            let ts = t.map { measure($0, width: maxWidth) } ?? .zero
            block = (k, ks, t, ts, k != nil && t != nil ? size * 0.42 : 0)
            let lines = t.map { lineCount($0, width: maxWidth) } ?? 0
            if ks.height + block.gap + ts.height <= bandHeight && lines <= 3 { break }
            size *= 0.92
        } while size > H * 0.012

        // Balanced lines: the narrowest measure that keeps the same number of
        // lines, so a last line is never left with a word or two.
        let titleWidth = block.title.map { balanced($0, width: maxWidth) } ?? maxWidth
        if let t = block.title { block.titleSize = measure(t, width: titleWidth) }
        let total = block.kickerSize.height + block.gap + block.titleSize.height
        // CoreGraphics counts up from the bottom.
        var y = H - (bandTop + (bandHeight - total) / 2)
        if lightInk { ctx.setShadow(offset: CGSize(width: 0, height: -H * 0.001), blur: H * 0.008, color: CGColor(gray: 0, alpha: 0.45)) }
        if let k = block.kicker {
            y -= block.kickerSize.height
            frame(k, in: CGRect(x: (W - maxWidth) / 2, y: y, width: maxWidth, height: block.kickerSize.height + 2), ctx)
            y -= block.gap
        }
        if let t = block.title {
            y -= block.titleSize.height
            frame(t, in: CGRect(x: (W - titleWidth) / 2, y: y, width: titleWidth, height: block.titleSize.height + 2), ctx)
        }
        return ctx.makeImage()
    }

    /// The type for each face: the title, and the small tracked line above it.
    static func font(_ face: ReelTitle.Face, kicker: Bool, size: CGFloat) -> CTFont {
        if kicker {
            switch face {
            case .editorial: return CTFontCreateWithName("Didot" as CFString, size * 0.36, nil)
            case .poster: return CTFontCreateWithName("Futura-Medium" as CFString, size * 0.3, nil)
            case .grotesk: return CTFontCreateWithName("HelveticaNeue-Medium" as CFString, size * 0.32, nil)
            case .modern: return CTFontCreateUIFontForLanguage(.emphasizedSystem, size * 0.32, nil)
                ?? CTFontCreateWithName("HelveticaNeue-Medium" as CFString, size * 0.32, nil)
            }
        }
        switch face {
        case .modern: return CTFontCreateUIFontForLanguage(.emphasizedSystem, size, nil)
            ?? CTFontCreateWithName("HelveticaNeue-Bold" as CFString, size, nil)
        case .grotesk: return CTFontCreateWithName("HelveticaNeue-Medium" as CFString, size * 1.04, nil)
        case .editorial: return CTFontCreateWithName("Didot" as CFString, size * 1.12, nil)
        case .poster: return CTFontCreateWithName("Futura-CondensedExtraBold" as CFString, size * 1.25, nil)
        }
    }

    static func setting(_ s: String, kicker: Bool, face: ReelTitle.Face, size: CGFloat, ink: CGColor) -> NSAttributedString {
        let f = font(face, kicker: kicker, size: size)
        let points = CTFontGetSize(f)
        var align = CTTextAlignment.center
        var spacing: CGFloat = kicker ? 0 : -points * 0.06
        let style = withUnsafeBytes(of: &align) { a in
            withUnsafeBytes(of: &spacing) { l in
                CTParagraphStyleCreate([
                    CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: a.baseAddress!),
                    CTParagraphStyleSetting(spec: .lineSpacingAdjustment, valueSize: MemoryLayout<CGFloat>.size, value: l.baseAddress!),
                ], 2)
            }
        }
        let color = kicker ? ink.copy(alpha: 0.62) ?? ink : ink
        let tracking: CGFloat
        switch (kicker, face) {
        case (true, _): tracking = points * 0.16
        case (false, .modern), (false, .grotesk): tracking = -points * 0.015
        case (false, .poster): tracking = points * 0.01
        case (false, .editorial): tracking = 0
        }
        let shown = kicker || face == .poster ? s.uppercased() : s
        var attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): f,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): style,
        ]
        // Tracking, not kern: a kern attribute switches the font's own kerning off.
        if tracking != 0 { attributes[NSAttributedString.Key(kCTTrackingAttributeName as String)] = tracking }
        return NSAttributedString(string: shown, attributes: attributes)
    }

    static func measure(_ s: NSAttributedString, width: CGFloat) -> CGSize {
        let setter = CTFramesetterCreateWithAttributedString(s)
        let fit = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(location: 0, length: 0), nil,
                                                               CGSize(width: width, height: .greatestFiniteMagnitude), nil)
        return CGSize(width: ceil(fit.width), height: ceil(fit.height))
    }

    /// The narrowest width that sets `s` in no more lines than `width` does.
    static func balanced(_ s: NSAttributedString, width: CGFloat) -> CGFloat {
        let lines = lineCount(s, width: width)
        guard lines > 1 else { return width }
        var lo = width / CGFloat(lines) * 0.8, hi = width
        for _ in 0..<12 {
            let mid = (lo + hi) / 2
            if lineCount(s, width: mid) <= lines { hi = mid } else { lo = mid }
        }
        return min(ceil(hi) + 2, width)
    }

    static func lineCount(_ s: NSAttributedString, width: CGFloat) -> Int {
        let setter = CTFramesetterCreateWithAttributedString(s)
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: width, height: 100_000), transform: nil)
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil)
        return CFArrayGetCount(CTFrameGetLines(frame))
    }

    static func frame(_ s: NSAttributedString, in rect: CGRect, _ ctx: CGContext) {
        let setter = CTFramesetterCreateWithAttributedString(s)
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), CGPath(rect: rect, transform: nil), nil)
        CTFrameDraw(frame, ctx)
    }
}
