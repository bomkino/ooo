// Draws OOO's app icon: a slide on a dark table, one small detail on it
// held in the camera's warm viewfinder.
//
//   swift scripts/make-icon.swift Resources/Icons/OOO.png
//
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "OOO.png"
let S: CGFloat = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!
guard let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0, space: space,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fatalError("no context") }

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

// The body: Apple's grid puts an 824 pt squircle in a 1024 canvas.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.45))
ctx.addPath(bodyPath)
ctx.setFillColor(color(0x111113))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(bodyPath)
ctx.clip()
let ground = CGGradient(colorsSpace: space, colors: [color(0x2B2B30), color(0x0D0D0F)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(ground, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
// A pool of studio light behind the slide.
let pool = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF, 0.13), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(pool, startCenter: CGPoint(x: 470, y: 600), startRadius: 0, endCenter: CGPoint(x: 470, y: 600), endRadius: 430, options: [])

// The slide, turned a little, as the camera first sees it.
ctx.saveGState()
ctx.translateBy(x: 512, y: 520)
ctx.rotate(by: -0.12)
let slide = CGRect(x: -300, y: -169, width: 600, height: 338)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 10, height: -26), blur: 46, color: color(0x000000, 0.6))
ctx.addPath(CGPath(roundedRect: slide, cornerWidth: 14, cornerHeight: 14, transform: nil))
ctx.setFillColor(color(0xF6F1E7))
ctx.fillPath()
ctx.restoreGState()
// Its content: a headline, lines of text, a small chart.
ctx.setFillColor(color(0x1A1A1D))
ctx.fill(CGRect(x: -252, y: 70, width: 270, height: 34))
ctx.fill(CGRect(x: -252, y: 22, width: 200, height: 34))
ctx.setFillColor(color(0x1A1A1D, 0.28))
for i in 0..<4 { ctx.fill(CGRect(x: -252, y: -40 - CGFloat(i) * 26, width: i == 3 ? 150 : 230, height: 9)) }
ctx.setStrokeColor(color(0x1A1A1D, 0.75))
ctx.setLineWidth(7)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
ctx.move(to: CGPoint(x: 40, y: -110))
ctx.addCurve(to: CGPoint(x: 150, y: -40), control1: CGPoint(x: 90, y: -105), control2: CGPoint(x: 110, y: -60))
ctx.addCurve(to: CGPoint(x: 252, y: 60), control1: CGPoint(x: 190, y: -20), control2: CGPoint(x: 220, y: 40))
ctx.strokePath()
// The one detail: an ember dot at the top of the curve.
ctx.setFillColor(color(0xFF5C38))
ctx.fillEllipse(in: CGRect(x: 236, y: 44, width: 32, height: 32))
ctx.restoreGState()

// The viewfinder, held on the detail: four warm corner brackets.
ctx.saveGState()
ctx.translateBy(x: 512, y: 520)
ctx.rotate(by: -0.12)
let finder = CGRect(x: 176, y: -14, width: 152, height: 148)
ctx.setStrokeColor(color(0xFF6A45))
ctx.setLineWidth(16)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
let arm: CGFloat = 46
for (cx, cy, dx, dy) in [(finder.minX, finder.minY, 1.0, 1.0), (finder.maxX, finder.minY, -1.0, 1.0),
                         (finder.minX, finder.maxY, 1.0, -1.0), (finder.maxX, finder.maxY, -1.0, -1.0)] {
    ctx.move(to: CGPoint(x: cx + CGFloat(dx) * arm, y: cy))
    ctx.addLine(to: CGPoint(x: cx, y: cy))
    ctx.addLine(to: CGPoint(x: cx, y: cy + CGFloat(dy) * arm))
}
ctx.strokePath()
ctx.restoreGState()

// A hairline of light on the top edge of the body.
ctx.restoreGState()
ctx.addPath(bodyPath)
ctx.setStrokeColor(color(0xFFFFFF, 0.08))
ctx.setLineWidth(3)
ctx.strokePath()

let image = ctx.makeImage()!
let url = URL(fileURLWithPath: out)
try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { fatalError("can't write") }
CGImageDestinationAddImage(dest, image, nil)
CGImageDestinationFinalize(dest)
print("icon \(out)")
