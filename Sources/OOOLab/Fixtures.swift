import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Test slides drawn the way pitch.dog's slides arrive: as pictures at exactly
/// 2576 × 1080 (wide) or 1920 × 1080 (16:9), or as PDFs. Each has the things
/// Direct for Me looks for (a headline, a figure, numbers, body text and small
/// print), set in faces that ship with macOS, so nothing binary lives in the repo.
enum Fixture: String, CaseIterable {
    /// 2576 × 1080, light: traction, a bar chart, three numbers, a footnote.
    case wide
    /// 1920 × 1080, dark: a market slide with rings, a paragraph, wordmarks.
    case standard

    var size: CGSize {
        switch self {
        case .wide: return CGSize(width: 2576, height: 1080)
        case .standard: return CGSize(width: 1920, height: 1080)
        }
    }

    /// Writes the slide as a PNG `scale` times its size, or as a one-page PDF.
    func write(to url: URL, scale: CGFloat = 1) throws {
        if url.pathExtension.lowercased() == "pdf" {
            var box = CGRect(origin: .zero, size: size)
            guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { throw FixtureError.write(url) }
            ctx.beginPDFPage(nil)
            ctx.translateBy(x: 0, y: size.height)
            ctx.scaleBy(x: 1, y: -1)
            draw(ctx)
            ctx.endPDFPage()
            ctx.closePDF()
            return
        }
        let w = Int((size.width * scale).rounded()), h = Int((size.height * scale).rounded())
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw FixtureError.write(url) }
        ctx.interpolationQuality = .high
        ctx.setShouldAntialias(true)
        ctx.setShouldSmoothFonts(false)
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: scale, y: -scale)
        draw(ctx)
        guard let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw FixtureError.write(url)
        }
        CGImageDestinationAddImage(dest, image, nil)
        if !CGImageDestinationFinalize(dest) { throw FixtureError.write(url) }
    }

    /// Draws in top-left design coordinates, one unit a pixel of the 1× slide.
    func draw(_ ctx: CGContext) {
        switch self {
        case .wide: Self.drawWide(ctx)
        case .standard: Self.drawStandard(ctx)
        }
    }

    enum FixtureError: Error, CustomStringConvertible {
        case write(URL)
        var description: String {
            switch self { case .write(let url): return "could not write \(url.path)" }
        }
    }

    // MARK: - Wide: traction

    static func drawWide(_ ctx: CGContext) {
        let W: CGFloat = 2576, H: CGFloat = 1080
        let paper = rgb(0.980, 0.976, 0.965), ink = rgb(0.075, 0.078, 0.090)
        let soft = rgb(0.075, 0.078, 0.090, 0.58), faint = rgb(0.075, 0.078, 0.090, 0.12)
        let accent = rgb(0.18, 0.40, 1.0)
        ctx.setFillColor(paper)
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))

        text(ctx, "07", font: font("AvenirNext-DemiBold", 22), color: accent, at: CGPoint(x: 140, y: 140), tracking: 1)
        text(ctx, "TRACTION", font: font("AvenirNext-DemiBold", 22), color: soft, at: CGPoint(x: 186, y: 140), tracking: 4)
        text(ctx, "Revenue grew 3.1× this year.", font: font("AvenirNext-Bold", 88), color: ink,
             at: CGPoint(x: 134, y: 262), tracking: -2)
        text(ctx, "Teams that send one great slide instead of a deck hear back faster,",
             font: font("AvenirNext-Regular", 30), color: soft, at: CGPoint(x: 140, y: 340))
        text(ctx, "and they keep paying. Here is monthly recurring revenue since January.",
             font: font("AvenirNext-Regular", 30), color: soft, at: CGPoint(x: 140, y: 384))

        // Three numbers.
        let stats: [(String, String)] = [("3.1×", "revenue growth"), ("62", "new customers"), ("94%", "net revenue retention")]
        for (i, s) in stats.enumerated() {
            let x = 140 + CGFloat(i) * 400
            text(ctx, s.0, font: font("AvenirNext-DemiBold", 96), color: i == 0 ? accent : ink, at: CGPoint(x: x - 4, y: 760), tracking: -2)
            text(ctx, s.1, font: font("AvenirNext-Medium", 26), color: soft, at: CGPoint(x: x, y: 806))
        }

        // The chart: nine months of bars, the last one lit.
        let plot = CGRect(x: 1640, y: 300, width: 796, height: 520)
        text(ctx, "Monthly recurring revenue, $k", font: font("AvenirNext-DemiBold", 24), color: ink,
             at: CGPoint(x: plot.minX, y: 214))
        for k in 0...4 {
            let y = plot.maxY - plot.height * CGFloat(k) / 4
            ctx.setFillColor(k == 0 ? soft : faint)
            ctx.fill(CGRect(x: plot.minX, y: y, width: plot.width, height: k == 0 ? 1.5 : 1))
            if k > 0 {
                text(ctx, "\(k * 100)", font: font("AvenirNext-Regular", 18), color: soft, at: CGPoint(x: plot.maxX + 14, y: y + 6))
            }
        }
        let values: [CGFloat] = [132, 141, 158, 171, 196, 240, 291, 352, 412]
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep"]
        let step = plot.width / CGFloat(values.count), bar = step * 0.56
        for (i, v) in values.enumerated() {
            let x = plot.minX + step * (CGFloat(i) + 0.5) - bar / 2
            let h = plot.height * v / 400
            let r = CGRect(x: x, y: plot.maxY - h, width: bar, height: h)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: 8, cornerHeight: 8, transform: nil))
            ctx.setFillColor(i == values.count - 1 ? accent : rgb(0.075, 0.078, 0.090, 0.16))
            ctx.fillPath()
            let m = months[i]
            let mw = width(m, font: font("AvenirNext-Medium", 18))
            text(ctx, m, font: font("AvenirNext-Medium", 18), color: soft, at: CGPoint(x: x + bar / 2 - mw / 2, y: plot.maxY + 34))
        }
        let last = plot.minX + step * (CGFloat(values.count) - 0.5)
        let label = "$412k"
        let lw = width(label, font: font("AvenirNext-Bold", 40), tracking: -0.5)
        text(ctx, label, font: font("AvenirNext-Bold", 40), color: accent,
             at: CGPoint(x: last - lw / 2, y: plot.maxY - plot.height * 412 / 400 - 18), tracking: -0.5)

        // Footer and the footnote.
        ctx.setFillColor(faint)
        ctx.fill(CGRect(x: 140, y: 952, width: W - 280, height: 1))
        text(ctx, "pitch.dog", font: font("AvenirNext-DemiBold", 22), color: ink, at: CGPoint(x: 140, y: 1006))
        text(ctx, "Series A update  ·  Confidential", font: font("AvenirNext-Regular", 20), color: soft, at: CGPoint(x: 268, y: 1006))
        let note = "Source: billing export, 1 Jan – 30 Sep 2026. Excludes one-off services. Unaudited."
        let nw = width(note, font: font("AvenirNext-Regular", 13))
        text(ctx, note, font: font("AvenirNext-Regular", 13), color: soft, at: CGPoint(x: W - 140 - nw, y: 1004))
    }

    // MARK: - Standard: market

    static func drawStandard(_ ctx: CGContext) {
        let W: CGFloat = 1920, H: CGFloat = 1080
        let night = rgb(0.059, 0.090, 0.161), ink = rgb(0.953, 0.945, 0.925)
        let soft = rgb(0.953, 0.945, 0.925, 0.62), faint = rgb(0.953, 0.945, 0.925, 0.14)
        let accent = rgb(1.0, 0.71, 0.28)
        ctx.setFillColor(night)
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))

        text(ctx, "03", font: font("AvenirNext-DemiBold", 18), color: accent, at: CGPoint(x: 120, y: 128), tracking: 1)
        text(ctx, "MARKET", font: font("AvenirNext-DemiBold", 18), color: soft, at: CGPoint(x: 158, y: 128), tracking: 4)
        text(ctx, "A $4.2B market", font: font("Didot-Bold", 84), color: ink, at: CGPoint(x: 116, y: 250), tracking: -1)
        text(ctx, "nobody designs for.", font: font("Didot-Italic", 84), color: ink, at: CGPoint(x: 116, y: 342), tracking: -1)
        let body = ["Every startup pitches. Almost none can afford a designer for",
                    "every update. We sell the one-slide update to the 1.1 million",
                    "seed and Series A teams who send one every month."]
        for (i, line) in body.enumerated() {
            text(ctx, line, font: font("AvenirNext-Regular", 25), color: soft, at: CGPoint(x: 120, y: 430 + CGFloat(i) * 38))
        }

        // Three rings: total, serviceable, obtainable.
        let c = CGPoint(x: 1430, y: 560)
        let rings: [(CGFloat, String, String, CGFloat)] = [
            (340, "$4.2B", "design spend, US and EU", 0.10),
            (220, "$860M", "teams that pitch monthly", 0.18),
            (110, "$95M", "ours in three years", 1.0),
        ]
        for (r, value, what, a) in rings {
            let rect = CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
            if a >= 1 {
                ctx.setFillColor(accent)
                ctx.fillEllipse(in: rect)
            } else {
                ctx.setFillColor(rgb(0.953, 0.945, 0.925, a * 0.5))
                ctx.fillEllipse(in: rect)
                ctx.setStrokeColor(rgb(0.953, 0.945, 0.925, a + 0.12))
                ctx.setLineWidth(2)
                ctx.strokeEllipse(in: rect)
            }
            let vf = font("Didot-Bold", r > 300 ? 44 : (r > 200 ? 38 : 34))
            let wf = font("AvenirNext-Medium", 16)
            let vw = width(value, font: vf), ww = width(what, font: wf)
            let top = r > 150 ? c.y - r + 70 : c.y + 6
            let tint = a >= 1 ? night : ink
            text(ctx, value, font: vf, color: tint, at: CGPoint(x: c.x - vw / 2, y: top))
            text(ctx, what, font: wf, color: a >= 1 ? rgb(0.059, 0.090, 0.161, 0.75) : soft, at: CGPoint(x: c.x - ww / 2, y: top + 28))
        }

        // Who already pays.
        text(ctx, "TRUSTED BY", font: font("AvenirNext-DemiBold", 15), color: soft, at: CGPoint(x: 120, y: 820), tracking: 3)
        let marks: [(String, String)] = [("Northwind", "Futura-Bold"), ("Halcyon", "Didot-Italic"),
                                         ("Brightline", "GillSans-SemiBold"), ("OAKMONT", "AvenirNext-Heavy")]
        var x: CGFloat = 120
        for (name, face) in marks {
            let f = font(face, 30)
            text(ctx, name, font: f, color: soft, at: CGPoint(x: x, y: 880))
            x += width(name, font: f) + 64
        }

        ctx.setFillColor(faint)
        ctx.fill(CGRect(x: 120, y: 970, width: W - 240, height: 1))
        text(ctx, "Estimates: pitch.dog analysis of 2025 design-tool spend in the US and EU. TAM is the total addressable market; SAM what we can serve; SOM what we can win in three years.",
             font: font("AvenirNext-Regular", 12), color: soft, at: CGPoint(x: 120, y: 1012))
        let page = "03"
        text(ctx, page, font: font("AvenirNext-DemiBold", 16), color: soft,
             at: CGPoint(x: W - 120 - width(page, font: font("AvenirNext-DemiBold", 16)), y: 1012))
    }

    // MARK: - Type

    static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    static func font(_ name: String, _ size: CGFloat) -> CTFont {
        let f = CTFontCreateWithName(name as CFString, size, nil)
        if (CTFontCopyPostScriptName(f) as String) == name { return f }
        let fallback = name.contains("Didot") ? "Georgia" : "HelveticaNeue"
        return CTFontCreateWithName(fallback as CFString, size, nil)
    }

    static func attributed(_ s: String, font: CTFont, color: CGColor, tracking: CGFloat) -> NSAttributedString {
        var attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        // Tracking, not kern: a kern attribute switches the font's own kerning off.
        if tracking != 0 { attributes[NSAttributedString.Key(kCTTrackingAttributeName as String)] = tracking }
        return NSAttributedString(string: s, attributes: attributes)
    }

    static func width(_ s: String, font: CTFont, tracking: CGFloat = 0) -> CGFloat {
        let line = CTLineCreateWithAttributedString(attributed(s, font: font, color: CGColor(gray: 0, alpha: 1), tracking: tracking))
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    /// One line with its baseline at `p`, in top-left coordinates.
    static func text(_ ctx: CGContext, _ s: String, font: CTFont, color: CGColor, at p: CGPoint, tracking: CGFloat = 0) {
        let line = CTLineCreateWithAttributedString(attributed(s, font: font, color: color, tracking: tracking))
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = p
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
}
