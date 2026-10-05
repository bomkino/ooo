import CoreGraphics
import CoreText
import Foundation
import OOOMotion

/// The slide every new window opens on. It is drawn from vectors, so the
/// camera can go as close as it likes and it stays sharp; and it is made to be
/// looked at closely: a headline set in Didot, a chart with one moment worth
/// stopping on, three numbers, printer's marks, and a note in the corner set
/// so small that only someone who zooms in will ever read it.
public enum SampleSlide {
    /// Design units: the slide is 1600 × 900.
    static let W: CGFloat = 1600
    static let H: CGFloat = 900

    static let paper = CGColor(srgbRed: 0.965, green: 0.945, blue: 0.906, alpha: 1)
    static let ink = CGColor(srgbRed: 0.10, green: 0.10, blue: 0.115, alpha: 1)
    static let soft = CGColor(srgbRed: 0.10, green: 0.10, blue: 0.115, alpha: 0.55)
    static let faint = CGColor(srgbRed: 0.10, green: 0.10, blue: 0.115, alpha: 0.14)
    static let accent = CGColor(srgbRed: 1.0, green: 0.36, blue: 0.22, alpha: 1)
    static let accentSoft = CGColor(srgbRed: 1.0, green: 0.36, blue: 0.22, alpha: 0.16)

    /// The moves the sample opens with: the headline, the moment in the chart,
    /// the numbers, then the note in the corner.
    public static var shots: [Shot] {
        [
            Shot(time: 3.7, frame: ShotFrame(center: Vec2(0.285, 0.33), size: Vec2(0.5, 0.36)),
                 yaw: -7, pitch: 4, lens: 28, aperture: 0.45, move: .glide, ease: .glide, breathe: 0.55,
                 label: "The headline"),
            Shot(time: 6.6, frame: ShotFrame(center: Vec2(0.755, 0.33), size: Vec2(0.17, 0.2)),
                 yaw: 11, pitch: -3, lens: 26, aperture: 0.6, move: .arc, ease: .breathe, breathe: 0.6,
                 emphasis: .spotlight, label: "The moment it turned"),
            Shot(time: 9.6, frame: ShotFrame(center: Vec2(0.29, 0.785), size: Vec2(0.47, 0.19)),
                 yaw: -5, pitch: 7, lens: 28, aperture: 0.45, move: .push, ease: .glide, breathe: 0.5,
                 emphasis: .lift, label: "The numbers"),
            Shot(time: 12.6, frame: ShotFrame(center: Vec2(0.912, 0.934), size: Vec2(0.07, 0.045)),
                 yaw: 15, pitch: 9, lens: 24, aperture: 0.75, move: .glide, ease: .linger, breathe: 0.7,
                 label: "A note for whoever looks closely"),
        ]
    }

    /// Draws the region (u0, v0, u1, v1) of the slide (v down) into a bitmap.
    public static func render(region r: SIMD4<Float>, width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let u0 = CGFloat(r.x), v0 = CGFloat(r.y), u1 = CGFloat(r.z), v1 = CGFloat(r.w)
        ctx.interpolationQuality = .high
        ctx.setShouldAntialias(true)
        ctx.setAllowsFontSmoothing(false)
        ctx.setShouldSubpixelPositionFonts(true)
        // Top-left design coordinates mapped onto the region.
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.scaleBy(x: CGFloat(width) / max((u1 - u0) * W, 1e-6), y: CGFloat(height) / max((v1 - v0) * H, 1e-6))
        ctx.translateBy(x: -u0 * W, y: -v0 * H)
        draw(ctx)
        return ctx.makeImage()
    }

    // MARK: - Drawing

    static func draw(_ ctx: CGContext) {
        ctx.setFillColor(paper)
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        paperTooth(ctx)
        cropMarks(ctx)

        // Kicker and headline.
        text(ctx, "04", font: font("AvenirNext-DemiBold", 15), color: accent, at: CGPoint(x: 120, y: 132), tracking: 1.5)
        text(ctx, "THE DETAIL", font: font("AvenirNext-DemiBold", 15), color: soft, at: CGPoint(x: 154, y: 132), tracking: 3.2)
        ctx.setFillColor(faint)
        ctx.fill(CGRect(x: 120, y: 150, width: 300, height: 1))
        text(ctx, "Every pixel,", font: font("Didot", 92), color: ink, at: CGPoint(x: 112, y: 258), tracking: -1.5)
        text(ctx, "on purpose.", font: font("Didot-Italic", 92), color: ink, at: CGPoint(x: 112, y: 356), tracking: -1.5)
        ctx.setFillColor(accent)
        ctx.fillEllipse(in: CGRect(x: 560, y: 336, width: 18, height: 18))
        text(ctx, "We spent a week on one chart, so the moment it turned would",
             font: font("AvenirNext-Regular", 21), color: soft, at: CGPoint(x: 120, y: 430))
        text(ctx, "read in a second. This is what that week looks like up close.",
             font: font("AvenirNext-Regular", 21), color: soft, at: CGPoint(x: 120, y: 460))

        chart(ctx, in: CGRect(x: 900, y: 120, width: 590, height: 400))
        stats(ctx)

        // Footer: a hairline, the page, and the note.
        ctx.setFillColor(faint)
        ctx.fill(CGRect(x: 120, y: 820, width: 1360, height: 1))
        text(ctx, "pitch.dog", font: font("AvenirNext-DemiBold", 14), color: ink, at: CGPoint(x: 120, y: 848), tracking: 0.4)
        text(ctx, "Obsess Over One  ·  04 / 12", font: font("AvenirNext-Regular", 14), color: soft, at: CGPoint(x: 208, y: 848))
        note(ctx, at: CGPoint(x: 1418, y: 836))
    }

    /// A faint tooth across the paper, from a fixed hash: it gives close-ups a
    /// surface without showing at a distance.
    static func paperTooth(_ ctx: CGContext) {
        ctx.saveGState()
        for i in 0..<5200 {
            let x = CGFloat((hashSigned(i, 3) * 0.5 + 0.5)) * W
            let y = CGFloat((hashSigned(i, 4) * 0.5 + 0.5)) * H
            let a = 0.018 + 0.03 * CGFloat(hashSigned(i, 5) * 0.5 + 0.5)
            let r = 0.35 + 0.7 * CGFloat(hashSigned(i, 6) * 0.5 + 0.5)
            ctx.setFillColor(CGColor(srgbRed: 0.35, green: 0.3, blue: 0.24, alpha: a))
            ctx.fillEllipse(in: CGRect(x: x, y: y, width: r, height: r))
        }
        ctx.restoreGState()
    }

    static func cropMarks(_ ctx: CGContext) {
        ctx.saveGState()
        ctx.setStrokeColor(faint)
        ctx.setLineWidth(0.8)
        let inset: CGFloat = 46, len: CGFloat = 22
        for (x, y, sx, sy) in [(inset, inset, 1.0, 1.0), (W - inset, inset, -1.0, 1.0),
                               (inset, H - inset, 1.0, -1.0), (W - inset, H - inset, -1.0, -1.0)] as [(CGFloat, CGFloat, CGFloat, CGFloat)] {
            ctx.move(to: CGPoint(x: x - 10 * sx, y: y)); ctx.addLine(to: CGPoint(x: x + len * sx, y: y))
            ctx.move(to: CGPoint(x: x, y: y - 10 * sy)); ctx.addLine(to: CGPoint(x: x, y: y + len * sy))
        }
        ctx.strokePath()
        // A registration target, top right.
        let c = CGPoint(x: W - 82, y: 82)
        ctx.strokeEllipse(in: CGRect(x: c.x - 7, y: c.y - 7, width: 14, height: 14))
        ctx.move(to: CGPoint(x: c.x - 11, y: c.y)); ctx.addLine(to: CGPoint(x: c.x + 11, y: c.y))
        ctx.move(to: CGPoint(x: c.x, y: c.y - 11)); ctx.addLine(to: CGPoint(x: c.x, y: c.y + 11))
        ctx.strokePath()
        ctx.restoreGState()
    }

    static let series: [CGFloat] = [0.18, 0.21, 0.19, 0.24, 0.23, 0.27, 0.26, 0.31, 0.47, 0.58, 0.63, 0.71]

    static func chart(_ ctx: CGContext, in rect: CGRect) {
        let plot = CGRect(x: rect.minX + 36, y: rect.minY + 40, width: rect.width - 50, height: rect.height - 92)
        text(ctx, "Replies per hundred pitches", font: font("AvenirNext-DemiBold", 15), color: ink,
             at: CGPoint(x: rect.minX + 36, y: rect.minY + 14))

        // Grid: four quiet rules and their values.
        ctx.saveGState()
        for k in 0...4 {
            let y = plot.maxY - plot.height * CGFloat(k) / 4
            ctx.setFillColor(k == 0 ? CGColor(srgbRed: 0.1, green: 0.1, blue: 0.115, alpha: 0.35) : faint)
            ctx.fill(CGRect(x: plot.minX, y: y, width: plot.width, height: k == 0 ? 1 : 0.6))
            text(ctx, "\(k * 20)", font: font("AvenirNext-Regular", 11), color: soft, at: CGPoint(x: rect.minX + 6, y: y + 4))
        }
        ctx.restoreGState()

        let n = series.count
        let pts: [CGPoint] = series.enumerated().map { i, v in
            CGPoint(x: plot.minX + plot.width * CGFloat(i) / CGFloat(n - 1), y: plot.maxY - plot.height * v / 0.8)
        }
        let curve = smoothPath(pts)

        // Area under the line, fading down.
        let area = curve.mutableCopy()!
        area.addLine(to: CGPoint(x: pts.last!.x, y: plot.maxY))
        area.addLine(to: CGPoint(x: pts.first!.x, y: plot.maxY))
        area.closeSubpath()
        ctx.saveGState()
        ctx.addPath(area)
        ctx.clip()
        let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                              colors: [CGColor(srgbRed: 1, green: 0.36, blue: 0.22, alpha: 0.28),
                                       CGColor(srgbRed: 1, green: 0.36, blue: 0.22, alpha: 0.0)] as CFArray,
                              locations: [0, 1])!
        ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: plot.minY), end: CGPoint(x: 0, y: plot.maxY), options: [])
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(curve)
        ctx.setStrokeColor(accent)
        ctx.setLineWidth(3)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.strokePath()
        ctx.restoreGState()

        // Months.
        let months = ["J", "F", "M", "A", "M", "J", "J", "A", "S", "O", "N", "D"]
        for (i, m) in months.enumerated() {
            text(ctx, m, font: font("AvenirNext-Medium", 11), color: soft,
                 at: CGPoint(x: pts[i].x - 3, y: plot.maxY + 20))
        }

        // The moment it turned: August to September.
        let p = pts[8]
        ctx.saveGState()
        ctx.setStrokeColor(CGColor(srgbRed: 1, green: 0.36, blue: 0.22, alpha: 0.5))
        ctx.setLineWidth(1)
        ctx.setLineDash(phase: 0, lengths: [3, 4])
        ctx.move(to: CGPoint(x: p.x, y: p.y + 10)); ctx.addLine(to: CGPoint(x: p.x, y: plot.maxY))
        ctx.strokePath()
        ctx.restoreGState()
        ctx.setFillColor(accentSoft)
        ctx.fillEllipse(in: CGRect(x: p.x - 17, y: p.y - 17, width: 34, height: 34))
        ctx.setFillColor(paper)
        ctx.fillEllipse(in: CGRect(x: p.x - 7.5, y: p.y - 7.5, width: 15, height: 15))
        ctx.setStrokeColor(accent)
        ctx.setLineWidth(3)
        ctx.strokeEllipse(in: CGRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12))

        // Its callout.
        let box = CGRect(x: p.x - 150, y: p.y - 118, width: 132, height: 74)
        let path = CGPath(roundedRect: box, cornerWidth: 10, cornerHeight: 10, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 3), blur: 10, color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.14))
        ctx.addPath(path)
        ctx.setFillColor(ink)
        ctx.fillPath()
        ctx.restoreGState()
        text(ctx, "+38%", font: font("Didot-Bold", 34), color: paper, at: CGPoint(x: box.minX + 14, y: box.minY + 40), tracking: -0.5)
        text(ctx, "after one slide changed", font: font("AvenirNext-Medium", 10.5),
             color: CGColor(srgbRed: 0.965, green: 0.945, blue: 0.906, alpha: 0.7), at: CGPoint(x: box.minX + 15, y: box.minY + 60))
        ctx.saveGState()
        ctx.setStrokeColor(ink)
        ctx.setLineWidth(1.2)
        ctx.move(to: CGPoint(x: box.maxX - 22, y: box.maxY)); ctx.addLine(to: CGPoint(x: p.x - 9, y: p.y - 9))
        ctx.strokePath()
        ctx.restoreGState()
    }

    static func stats(_ ctx: CGContext) {
        let items: [(String, String, String)] = [
            ("1", "slide", "talked about for a minute"),
            ("118", "hours", "spent on it, give or take"),
            ("∞", "care", "in every last pixel"),
        ]
        for (i, item) in items.enumerated() {
            let x = 120 + CGFloat(i) * 250
            text(ctx, item.0, font: font(i == 2 ? "Didot" : "Didot-Bold", 66), color: i == 2 ? accent : ink,
                 at: CGPoint(x: x, y: 712), tracking: -1)
            let numberWidth = width(item.0, font: font(i == 2 ? "Didot" : "Didot-Bold", 66), tracking: -1)
            text(ctx, item.1, font: font("AvenirNext-DemiBold", 17), color: ink, at: CGPoint(x: x + numberWidth + 8, y: 712))
            text(ctx, item.2, font: font("AvenirNext-Regular", 15), color: soft, at: CGPoint(x: x + 2, y: 748))
        }
    }

    /// The note in the corner, set at about 4 pt on a full-size slide.
    static func note(_ ctx: CGContext, at origin: CGPoint) {
        text(ctx, "If you can read this,", font: font("AvenirNext-Medium", 4.2), color: soft, at: CGPoint(x: origin.x, y: origin.y))
        text(ctx, "you looked closer than anyone.", font: font("AvenirNext-Medium", 4.2), color: soft, at: CGPoint(x: origin.x, y: origin.y + 5.4))
        text(ctx, "Thank you. We made it for you.", font: font("AvenirNext-DemiBold", 4.2), color: ink, at: CGPoint(x: origin.x, y: origin.y + 10.8))
        // A small heart in the accent, drawn as two arcs and a point.
        let c = CGPoint(x: origin.x + 74, y: origin.y + 8.2)
        let s: CGFloat = 2.4
        let heart = CGMutablePath()
        heart.move(to: CGPoint(x: c.x, y: c.y + 1.6 * s))
        heart.addCurve(to: CGPoint(x: c.x - 1.6 * s, y: c.y - 0.4 * s), control1: CGPoint(x: c.x - 0.9 * s, y: c.y + 0.9 * s),
                       control2: CGPoint(x: c.x - 1.6 * s, y: c.y + 0.3 * s))
        heart.addArc(center: CGPoint(x: c.x - 0.8 * s, y: c.y - 0.5 * s), radius: 0.8 * s, startAngle: .pi, endAngle: 0, clockwise: false)
        heart.addArc(center: CGPoint(x: c.x + 0.8 * s, y: c.y - 0.5 * s), radius: 0.8 * s, startAngle: .pi, endAngle: 0, clockwise: false)
        heart.addCurve(to: CGPoint(x: c.x, y: c.y + 1.6 * s), control1: CGPoint(x: c.x + 1.6 * s, y: c.y + 0.3 * s),
                       control2: CGPoint(x: c.x + 0.9 * s, y: c.y + 0.9 * s))
        heart.closeSubpath()
        ctx.addPath(heart)
        ctx.setFillColor(accent)
        ctx.fillPath()
    }

    // MARK: - Helpers

    static func font(_ name: String, _ size: CGFloat) -> CTFont {
        let f = CTFontCreateWithName(name as CFString, size, nil)
        if (CTFontCopyPostScriptName(f) as String) == name { return f }
        let fallback = name.contains("Didot") ? "Georgia" : "HelveticaNeue"
        return CTFontCreateWithName(fallback as CFString, size, nil)
    }

    static func attributed(_ s: String, font: CTFont, color: CGColor, tracking: CGFloat) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            NSAttributedString.Key(kCTKernAttributeName as String): tracking,
        ])
    }

    static func width(_ s: String, font: CTFont, tracking: CGFloat = 0) -> CGFloat {
        let line = CTLineCreateWithAttributedString(attributed(s, font: font, color: ink, tracking: tracking))
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    /// Sets one line with its baseline at `at` (top-left design coordinates).
    static func text(_ ctx: CGContext, _ s: String, font: CTFont, color: CGColor, at p: CGPoint, tracking: CGFloat = 0) {
        let line = CTLineCreateWithAttributedString(attributed(s, font: font, color: color, tracking: tracking))
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = p
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    /// A Catmull-Rom curve through the points, as Béziers.
    static func smoothPath(_ p: [CGPoint]) -> CGMutablePath {
        let path = CGMutablePath()
        guard let first = p.first else { return path }
        path.move(to: first)
        for i in 0..<(p.count - 1) {
            let p0 = p[max(i - 1, 0)], p1 = p[i], p2 = p[i + 1], p3 = p[min(i + 2, p.count - 1)]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        return path
    }
}
