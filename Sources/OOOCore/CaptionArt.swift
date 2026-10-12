import AppKit
import CoreGraphics
import CoreText
import Foundation
import Metal
import OOOMotion
import RenderCore
import StageKit

/// Sets captions and draws them over the finished frame. Each phrase is set
/// once, twice over: in its own ink, and in the light the word being said
/// takes. The frame shows the first, with each word lit from the second as
/// far as it is lit, so lighting a word changes its colour and nothing else.
public enum CaptionArt {
    /// One phrase, set.
    public struct Setting {
        /// The ink above, the lit words below, each `size` tall.
        public var image: CGImage
        public var size: CGSize
        /// Where the setting goes on the frame, in 0…1 (y down): min x, min y, max x, max y.
        public var rect: SIMD4<Float>
        /// Each word's box in the setting, in 0…1 (y down).
        public var words: [SIMD4<Float>]
    }

    struct Colours {
        var ink: CGColor
        var lit: CGColor
        var card: CGColor?
        var shadow: CGColor
    }

    static func colours(_ look: CaptionStyle.Look) -> Colours {
        switch look {
        case .clean:
            return Colours(ink: CGColor(srgbRed: 0.98, green: 0.97, blue: 0.95, alpha: 1),
                           lit: CGColor(srgbRed: 1.0, green: 0.56, blue: 0.40, alpha: 1), card: nil,
                           shadow: CGColor(gray: 0, alpha: 0.62))
        case .card:
            return Colours(ink: CGColor(srgbRed: 0.95, green: 0.94, blue: 0.93, alpha: 1),
                           lit: CGColor(srgbRed: 1.0, green: 0.50, blue: 0.34, alpha: 1),
                           card: CGColor(srgbRed: 0.043, green: 0.047, blue: 0.055, alpha: 0.86),
                           shadow: CGColor(gray: 0, alpha: 0.32))
        case .ink:
            return Colours(ink: CGColor(srgbRed: 0.043, green: 0.047, blue: 0.055, alpha: 1),
                           lit: CGColor(srgbRed: 0.85, green: 0.25, blue: 0.11, alpha: 1),
                           card: CGColor(srgbRed: 0.945, green: 0.941, blue: 0.929, alpha: 0.97),
                           shadow: CGColor(gray: 0, alpha: 0.28))
        }
    }

    /// The face for captions: the opening title's family, at a weight that
    /// reads at a glance on a phone.
    static func font(_ face: ReelTitle.Face, size: CGFloat) -> CTFont {
        switch face {
        case .editorial:
            let serif = NSFont.systemFont(ofSize: size, weight: .semibold).fontDescriptor.withDesign(.serif)
            if let d = serif, let f = NSFont(descriptor: d, size: size) { return f as CTFont }
            return NSFont.systemFont(ofSize: size, weight: .semibold) as CTFont
        case .poster:
            return NSFont.systemFont(ofSize: size * 1.02, weight: .heavy) as CTFont
        case .grotesk:
            return CTFontCreateWithName("HelveticaNeue-Bold" as CFString, size, nil)
        case .modern:
            return NSFont.systemFont(ofSize: size, weight: .semibold) as CTFont
        }
    }

    /// Sets `phrase` for a `width` × `height` frame, its last line's foot on
    /// the band captions keep above the platform's interface.
    public static func set(_ phrase: CaptionPhrase, style: CaptionStyle, face: ReelTitle.Face, width: Int, height: Int,
                           safe: SafeArea) -> Setting? {
        guard width > 8, height > 8, !phrase.words.isEmpty else { return nil }
        let W = CGFloat(width), H = CGFloat(height)
        let C = Float(W / H)
        let size = CGFloat(Captions.size(canvasAspect: C)) * H
        let colours = colours(style.look)
        let f = font(face, size: size)
        let clear = (1 - CGFloat(safe.left + safe.right)) * W
        let measure = min(clear * 0.88, W * 0.86)

        // The words, with each one's place in the string.
        var text = ""
        var ranges: [NSRange] = []
        for (i, w) in phrase.words.enumerated() {
            if i > 0 { text += " " }
            let start = (text as NSString).length
            text += w
            ranges.append(NSRange(location: start, length: (w as NSString).length))
        }
        func attributed(_ ink: CGColor) -> NSAttributedString {
            var align = CTTextAlignment.center
            var leading: CGFloat = -size * 0.08
            let style = withUnsafeBytes(of: &align) { a in
                withUnsafeBytes(of: &leading) { l in
                    CTParagraphStyleCreate([
                        CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: a.baseAddress!),
                        CTParagraphStyleSetting(spec: .lineSpacingAdjustment, valueSize: MemoryLayout<CGFloat>.size, value: l.baseAddress!),
                    ], 2)
                }
            }
            return NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): f,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): ink,
                NSAttributedString.Key(kCTParagraphStyleAttributeName as String): style,
                NSAttributedString.Key(kCTTrackingAttributeName as String): -size * 0.008,
            ])
        }
        let plain = attributed(colours.ink)
        // Two lines at most, balanced so the last is never a word or two.
        let lines = OpeningTitleArt.lineCount(plain, width: measure)
        let lineWidth = lines > 1 ? OpeningTitleArt.balanced(plain, width: measure) : measure
        let setter = CTFramesetterCreateWithAttributedString(plain)
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0),
                                             CGPath(rect: CGRect(x: 0, y: 0, width: lineWidth, height: 100_000), transform: nil), nil)
        let ctLines = (CTFrameGetLines(frame) as? [CTLine]) ?? []
        guard !ctLines.isEmpty else { return nil }
        // Each line's ink box, from the frame's top.
        struct Line { var line: CTLine; var range: CFRange; var width: CGFloat; var baseline: CGFloat }
        let ascent = CTFontGetAscent(f), descent = CTFontGetDescent(f)
        let lineHeight = size * 1.16
        var laid: [Line] = []
        for (k, l) in ctLines.enumerated() {
            let w = CGFloat(CTLineGetTypographicBounds(l, nil, nil, nil) - CTLineGetTrailingWhitespaceWidth(l))
            laid.append(Line(line: l, range: CTLineGetStringRange(l), width: w, baseline: ascent + CGFloat(k) * lineHeight))
        }
        let textWidth = laid.map(\.width).max() ?? 0
        let textHeight = ascent + descent + CGFloat(laid.count - 1) * lineHeight
        // The card around the words, and room around it for the shadow.
        let padX = colours.card != nil ? size * 0.56 : 0, padY = colours.card != nil ? size * 0.30 : 0
        let margin = size * 0.6
        let blockW = textWidth + 2 * padX, blockH = textHeight + 2 * padY
        let imgW = Int(ceil(blockW + 2 * margin)), half = Int(ceil(blockH + 2 * margin))
        guard let ctx = CGContext(data: nil, width: imgW, height: half * 2, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Draws one copy in the half whose top is `top` (from the image's top).
        func draw(ink: CGColor, top: CGFloat) {
            let flip = CGFloat(half * 2)
            let card = CGRect(x: margin, y: flip - top - margin - blockH, width: blockW, height: blockH)
            if let fill = colours.card {
                ctx.saveGState()
                ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.06), blur: size * 0.42, color: colours.shadow)
                ctx.addPath(CGPath(roundedRect: card, cornerWidth: size * 0.42, cornerHeight: size * 0.42, transform: nil))
                ctx.setFillColor(fill)
                ctx.fillPath()
                ctx.restoreGState()
            }
            let lit = attributed(ink)
            let litSetter = CTFramesetterCreateWithAttributedString(lit)
            ctx.saveGState()
            if colours.card == nil {
                // Over the picture itself: a wide soft shade and a close one.
                ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.03), blur: size * 0.34, color: colours.shadow)
            }
            for l in laid {
                let line = CTTypesetterCreateLine(CTFramesetterGetTypesetter(litSetter), l.range)
                let x = card.minX + padX + (textWidth - l.width) / 2
                let y = card.maxY - padY - l.baseline
                ctx.textPosition = CGPoint(x: x, y: y)
                CTLineDraw(line, ctx)
            }
            ctx.restoreGState()
        }
        draw(ink: colours.ink, top: 0)
        draw(ink: colours.lit, top: CGFloat(half))
        guard let image = ctx.makeImage() else { return nil }

        // Each word's box, in the top copy, as shares of its size.
        var boxes: [SIMD4<Float>] = []
        for r in ranges {
            guard let l = laid.first(where: { r.location >= $0.range.location && r.location < $0.range.location + $0.range.length }) else {
                boxes.append(.zero)
                continue
            }
            let x0 = CTLineGetOffsetForStringIndex(l.line, r.location, nil)
            let x1 = CTLineGetOffsetForStringIndex(l.line, r.location + r.length, nil)
            let left = margin + padX + (textWidth - l.width) / 2
            let top = margin + padY + l.baseline - ascent
            let pad = size * 0.06
            boxes.append(SIMD4(Float((left + x0 - pad) / CGFloat(imgW)), Float((top - pad) / CGFloat(half)),
                               Float((left + x1 + pad) / CGFloat(imgW)), Float((top + ascent + descent + pad) / CGFloat(half))))
        }
        // On the frame: centred, the block's foot on the captions' band.
        let band = Captions.band(canvasAspect: C, safe: safe)
        let foot = (1 - CGFloat(band.bottom)) * H + margin
        let midX = (CGFloat(safe.left) + (1 - CGFloat(safe.left + safe.right)) / 2) * W
        let x0 = midX - CGFloat(imgW) / 2, y0 = foot - CGFloat(half)
        let rect = SIMD4(Float(x0 / W), Float(y0 / H), Float((x0 + CGFloat(imgW)) / W), Float(foot / H))
        return Setting(image: image, size: CGSize(width: imgW, height: half), rect: rect, words: boxes)
    }
}

/// Draws the caption showing at a moment over the finished frame.
public final class CaptionCompositor {
    private let library: MTLLibrary
    private let lock = NSLock()
    private struct Kept {
        var key: Int
        var texture: MTLTexture
        var setting: CaptionArt.Setting
    }
    /// The phrases drawn lately, the latest last: a few, since a phrase is
    /// shown once and the next one comes along every second or two.
    private var kept: [Kept] = []
    private static let keep = 6
    static let maxWords = 16

    public init() throws {
        library = try GPU.shared.library(named: "captions", source: ShaderPrelude.source + Self.source)
    }

    struct Params {
        var rect: SIMD4<Float>
        /// alpha, how far down it sits (drop less rise), word count, unused.
        var misc: SIMD4<Float>
        var words: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>,
                    SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)
        var lit: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)
    }

    /// Draws `phrase` as it is at moment `m`, `rise` (a share of the frame
    /// height) above its band while the stage is up.
    func encode(_ cb: MTLCommandBuffer, phrase: CaptionPhrase, moment m: CaptionMoment, style: CaptionStyle, face: ReelTitle.Face,
                safe: SafeArea, rise: Float = 0, output: MTLTexture) throws {
        guard m.alpha > 0.002, let (texture, setting) = drawn(phrase, style: style, face: face, safe: safe,
                                                              width: output.width, height: output.height) else { return }
        let gpu = GPU.shared
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = output
        pass.colorAttachments[0].loadAction = .load
        pass.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.label = "captions"
        enc.setRenderPipelineState(try gpu.renderPipeline(.init(library: "captions", vertex: "fs_vertex", fragment: "caption_fragment",
                                                                color: output.pixelFormat, blend: .over), library: library))
        var boxes = [SIMD4<Float>](repeating: .zero, count: Self.maxWords)
        var lit = [Float](repeating: 0, count: Self.maxWords)
        let n = min(setting.words.count, m.lit.count, Self.maxWords)
        for i in 0..<n {
            boxes[i] = setting.words[i]
            lit[i] = m.lit[i]
        }
        let l4 = stride(from: 0, to: Self.maxWords, by: 4).map { SIMD4(lit[$0], lit[$0 + 1], lit[$0 + 2], lit[$0 + 3]) }
        var p = Params(rect: setting.rect, misc: SIMD4(m.alpha, m.drop - rise, Float(n), 0),
                       words: (boxes[0], boxes[1], boxes[2], boxes[3], boxes[4], boxes[5], boxes[6], boxes[7],
                               boxes[8], boxes[9], boxes[10], boxes[11], boxes[12], boxes[13], boxes[14], boxes[15]),
                       lit: (l4[0], l4[1], l4[2], l4[3]))
        enc.setFragmentBytes(&p, length: MemoryLayout<Params>.stride, index: 0)
        enc.setFragmentTexture(texture, index: 0)
        enc.setFragmentSamplerState(gpu.sampler(.linearClamp), index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }

    /// The phrase set and on the GPU for a frame this size, kept a while.
    private func drawn(_ phrase: CaptionPhrase, style: CaptionStyle, face: ReelTitle.Face, safe: SafeArea,
                       width: Int, height: Int) -> (MTLTexture, CaptionArt.Setting)? {
        var h = Hasher()
        h.combine(phrase.words)
        h.combine(style.look)
        h.combine(face)
        h.combine(width)
        h.combine(height)
        h.combine(safe)
        let key = h.finalize()
        lock.lock()
        defer { lock.unlock() }
        if let i = kept.firstIndex(where: { $0.key == key }) {
            let k = kept.remove(at: i)
            kept.append(k)
            return (k.texture, k.setting)
        }
        guard let setting = CaptionArt.set(phrase, style: style, face: face, width: width, height: height, safe: safe) else { return nil }
        let w = Int(setting.size.width), hh = Int(setting.size.height) * 2
        guard let ctx = CGContext(data: nil, width: w, height: hh, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(setting.image, in: CGRect(x: 0, y: 0, width: w, height: hh))
        guard let data = ctx.data else { return nil }
        let tex = GPU.shared.makeTexture(width: w, height: hh, format: .rgba8Unorm, usage: [.shaderRead], storage: .shared)
        tex.replace(region: MTLRegionMake2D(0, 0, w, hh), mipmapLevel: 0, withBytes: data, bytesPerRow: w * 4)
        kept.append(Kept(key: key, texture: tex, setting: setting))
        if kept.count > Self.keep { kept.removeFirst(kept.count - Self.keep) }
        return (tex, setting)
    }

    static let source = #"""
struct CaptionParams {
    float4 rect;
    float4 misc;
    float4 words[16];
    float4 lit[4];
};

// The phrase in its own ink, each word lit from the copy below as far as it is lit.
fragment float4 caption_fragment(FSOut in [[stage_in]], texture2d<float> art [[texture(0)]], sampler s [[sampler(0)]],
                                 constant CaptionParams &p [[buffer(0)]]) {
    float2 uv = in.uv - float2(0.0, p.misc.y);
    float2 q = (uv - p.rect.xy) / max(p.rect.zw - p.rect.xy, float2(1e-5));
    if (any(q < 0.0) || any(q > 1.0)) { return float4(0.0); }
    float lit = 0.0;
    int n = int(p.misc.z);
    for (int i = 0; i < 16; i++) {
        if (i >= n) { break; }
        float4 b = p.words[i];
        float2 inside = step(b.xy, q) * step(q, b.zw);
        lit = max(lit, inside.x * inside.y * p.lit[i / 4][i % 4]);
    }
    float4 ink = art.sample(s, float2(q.x, q.y * 0.5));
    float4 light = art.sample(s, float2(q.x, 0.5 + q.y * 0.5));
    return mix(ink, light, lit) * p.misc.x;
}
"""#
}
