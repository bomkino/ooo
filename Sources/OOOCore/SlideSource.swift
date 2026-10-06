import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import Metal
import OOOMotion
import RenderCore
import StageKit
import UniformTypeIdentifiers

/// The slide's artwork, able to draw any part of itself at any size: PDFs and
/// the sample from their vectors, pictures from their own pixels.
public final class SlideSource: @unchecked Sendable {
    public let ref: SlideRef
    public let aspect: Float
    private let document: CGPDFDocument?
    private let page: CGPDFPage?
    private let image: CGImage?
    private let lock = NSLock()

    /// Longest side of the texture that holds the whole slide.
    public static let baseSide = 4096
    /// How far past its own pixels a picture is drawn: with a Lanczos
    /// resample and a light unsharp mask, text drawn at twice a picture's
    /// size stays crisp where the GPU's bilinear magnification goes soft.
    public static let pictureUpscale: Float = SlideRef.pictureUpscale

    public init(ref: SlideRef, media: URL?) throws {
        self.ref = ref
        switch ref.kind {
        case .sample:
            document = nil
            page = nil
            image = nil
            aspect = Float(SampleSlide.W / SampleSlide.H)
        case .pdf:
            guard let file = ref.file, let media, let doc = CGPDFDocument(media.appendingPathComponent(file) as CFURL),
                  let pg = doc.page(at: ref.page + 1) else {
                throw RenderError.io("Could not open the slide's PDF.")
            }
            document = doc
            page = pg
            image = nil
            let (w, h) = SlideSource.displaySize(pg)
            aspect = Float(w / max(h, 1))
        case .image:
            guard let file = ref.file, let media,
                  let src = CGImageSourceCreateWithURL(media.appendingPathComponent(file) as CFURL, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
                throw RenderError.io("Could not open the slide's picture.")
            }
            document = nil
            page = nil
            image = SlideSource.flattened(SlideSource.oriented(img, source: src))
            aspect = Float(image!.width) / Float(max(image!.height, 1))
        }
    }

    /// Reads a dropped file: a picture, or the first page of a PDF (or `page`).
    public static func inspect(_ url: URL, page: Int = 0) -> SlideRef? {
        let type = UTType(filenameExtension: url.pathExtension.lowercased())
        let name = url.deletingPathExtension().lastPathComponent
        if type?.conforms(to: .pdf) == true, let doc = CGPDFDocument(url as CFURL), doc.numberOfPages > 0,
           let pg = doc.page(at: min(page, doc.numberOfPages - 1) + 1) {
            let (w, h) = displaySize(pg)
            return SlideRef(kind: .pdf, page: min(page, doc.numberOfPages - 1), aspect: Float(w / max(h, 1)), name: name)
        }
        if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
           let pw = props[kCGImagePropertyPixelWidth] as? Int, let ph = props[kCGImagePropertyPixelHeight] as? Int, pw > 0, ph > 0 {
            let orientation = props[kCGImagePropertyOrientation] as? UInt32 ?? 1
            let swap = orientation >= 5
            let w = swap ? ph : pw, h = swap ? pw : ph
            return SlideRef(kind: .image, aspect: Float(w) / Float(h), name: name, pixelWidth: w, pixelHeight: h)
        }
        return nil
    }

    public static func pageCount(_ url: URL) -> Int {
        CGPDFDocument(url as CFURL)?.numberOfPages ?? 1
    }

    static func displaySize(_ page: CGPDFPage) -> (CGFloat, CGFloat) {
        let box = page.getBoxRect(.cropBox)
        let rotation = ((page.rotationAngle % 360) + 360) % 360
        return rotation % 180 != 0 ? (box.height, box.width) : (box.width, box.height)
    }

    /// Applies EXIF orientation so the picture stands the right way up.
    static func oriented(_ img: CGImage, source: CGImageSource) -> CGImage {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let o = props[kCGImagePropertyOrientation] as? UInt32, o != 1 else { return img }
        let thumb: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                      kCGImageSourceCreateThumbnailWithTransform: true,
                                      kCGImageSourceThumbnailMaxPixelSize: max(img.width, img.height)]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, thumb as CFDictionary) ?? img
    }

    /// A picture with transparency, laid on a sheet as a PDF page is: white,
    /// unless its artwork is light (a white logo), which goes on near-black.
    /// Left transparent, its clear parts would show dark fringes on the GPU
    /// and read as black ink to the slide's analysis.
    static func flattened(_ img: CGImage) -> CGImage {
        switch img.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return img
        default: break
        }
        let w = img.width, h = img.height
        // How light the artwork is, judged small, by coverage.
        let sw = min(w, 256), sh = max(1, Int((Double(h) * Double(sw) / Double(max(w, 1))).rounded()))
        var px = [UInt8](repeating: 0, count: sw * sh * 4)
        var light = false
        if let small = CGContext(data: &px, width: sw, height: sh, bitsPerComponent: 8, bytesPerRow: sw * 4,
                                 space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            small.draw(img, in: CGRect(x: 0, y: 0, width: sw, height: sh))
            var ink = 0.0, cover = 0.0, clear = 0.0
            for i in stride(from: 0, to: px.count, by: 4) {
                let a = Double(px[i + 3]) / 255
                // Premultiplied: luminance times coverage.
                ink += (0.2126 * Double(px[i]) + 0.7152 * Double(px[i + 1]) + 0.0722 * Double(px[i + 2])) / 255
                cover += a
                if a < 0.5 { clear += 1 }
            }
            // Only a picture that is mostly see-through counts as artwork on nothing.
            if clear < Double(sw * sh) * 0.02 { return img }
            light = cover > 0 && ink / cover > 0.72
        }
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return img }
        ctx.setFillColor(light ? CGColor(srgbRed: 0.07, green: 0.07, blue: 0.08, alpha: 1) : CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .none
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? img
    }

    /// A picture's own pixels per slide height; nil for vectors.
    public var nativeHeight: Int? { image?.height }

    /// The most pixels per slide height worth drawing: twice a picture's own
    /// (see `pictureUpscale`), or unlimited for vectors.
    public var densityLimit: Float? { image.map { Float($0.height) * Self.pictureUpscale } }

    /// Longest side of the whole-slide texture. A picture gets its sharpened
    /// double, so close-ups need no further drawing, up to a size that stays
    /// light on memory; vectors get `baseSide` and draw sharper detail as needed.
    public var wholeSide: Int {
        guard let image else { return Self.baseSide }
        let long = Float(max(image.width, image.height))
        return Int(min(long * Self.pictureUpscale, max(long, 6144)).rounded())
    }

    /// The region grown outwards to whole pixels of a picture, so a detail cut
    /// from it lines up exactly with the whole slide; vectors need no snapping.
    public func snapped(_ r: SIMD4<Float>) -> SIMD4<Float> {
        guard let image else { return r }
        let w = Float(image.width), h = Float(image.height)
        return SIMD4(floorf(r.x * w) / w, floorf(r.y * h) / h, ceilf(r.z * w) / w, ceilf(r.w * h) / h)
    }

    /// Draws the region (u0, v0, u1, v1) of the slide (v down) into a bitmap of
    /// `width` × `height` pixels.
    public func render(region r: SIMD4<Float>, width: Int, height: Int) -> CGImage? {
        switch ref.kind {
        case .sample:
            return SampleSlide.render(region: r, width: width, height: height)
        case .pdf:
            guard let page else { return nil }
            lock.lock(); defer { lock.unlock() }
            return Self.render(page: page, region: r, width: width, height: height)
        case .image:
            guard let image else { return nil }
            return Self.render(image: image, region: r, width: width, height: height)
        }
    }

    /// The whole slide, longest side `side` pixels (never more than twice
    /// what a picture has).
    public func renderWhole(side: Int? = nil) -> CGImage? {
        let side = side ?? wholeSide
        var w = aspect >= 1 ? side : Int((Float(side) * aspect).rounded())
        var h = aspect >= 1 ? Int((Float(side) / aspect).rounded()) : side
        if let image, let limit = densityLimit, Float(h) > limit {
            h = Int(limit)
            w = Int((Float(image.width) * Self.pictureUpscale).rounded())
        }
        return render(region: SIMD4(0, 0, 1, 1), width: max(w, 1), height: max(h, 1))
    }

    static func render(page: CGPDFPage, region r: SIMD4<Float>, width: Int, height: Int) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let box = page.getBoxRect(.cropBox)
        let rotation = ((page.rotationAngle % 360) + 360) % 360
        let (w, h) = displaySize(page)
        guard w > 0, h > 0 else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.interpolationQuality = .high
        ctx.setShouldAntialias(true)
        // The region of the page, in its display space (bottom-left origin).
        let u0 = CGFloat(r.x), v0 = CGFloat(r.y), u1 = CGFloat(r.z), v1 = CGFloat(r.w)
        ctx.scaleBy(x: CGFloat(width) / max((u1 - u0) * w, 1e-6), y: CGFloat(height) / max((v1 - v0) * h, 1e-6))
        ctx.translateBy(x: -u0 * w, y: -(1 - v1) * h)
        switch rotation {
        case 90:
            ctx.translateBy(x: 0, y: h)
            ctx.rotate(by: -.pi / 2)
        case 180:
            ctx.translateBy(x: w, y: h)
            ctx.rotate(by: .pi)
        case 270:
            ctx.translateBy(x: w, y: 0)
            ctx.rotate(by: .pi / 2)
        default:
            break
        }
        ctx.translateBy(x: -box.minX, y: -box.minY)
        ctx.clip(to: box)
        ctx.drawPDFPage(page)
        return ctx.makeImage()
    }

    static func render(image: CGImage, region r: SIMD4<Float>, width: Int, height: Int) -> CGImage? {
        let iw = CGFloat(image.width), ih = CGFloat(image.height)
        let x0 = (CGFloat(r.x) * iw).rounded(), y0 = (CGFloat(r.y) * ih).rounded()
        let crop = CGRect(x: x0, y: y0, width: max((CGFloat(r.z) * iw).rounded() - x0, 1), height: max((CGFloat(r.w) * ih).rounded() - y0, 1))
        guard let part = image.cropping(to: crop) else { return nil }
        // Past the picture's own pixels: a sharpened resample, up to twice
        // its size; the GPU magnifies the rest.
        let up = min(Float(width) / Float(part.width), Float(height) / Float(part.height), pictureUpscale)
        if up > 1.02 {
            return Upscaler.sharpened(part, width: Int((Float(part.width) * up).rounded()),
                                      height: Int((Float(part.height) * up).rounded()))
        }
        let w = min(width, part.width), h = min(height, part.height)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(part, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}

/// Draws a picture larger than its pixels the way a careful retoucher would:
/// a Lanczos resample, then a light unsharp mask scaled to the enlargement,
/// so text keeps its edges.
enum Upscaler {
    static let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             .cacheIntermediates: false])

    static func sharpened(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        let sx = Float(width) / Float(max(image.width, 1)), sy = Float(height) / Float(max(image.height, 1))
        let scale = CIFilter.lanczosScaleTransform()
        scale.inputImage = CIImage(cgImage: image).clampedToExtent()
        scale.scale = sy
        scale.aspectRatio = sx / max(sy, 1e-6)
        let sharpen = CIFilter.unsharpMask()
        sharpen.inputImage = scale.outputImage
        sharpen.radius = 0.9 * sy
        sharpen.intensity = 0.55
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        guard let out = sharpen.outputImage?.cropped(to: rect) else { return nil }
        return context.createCGImage(out, from: rect, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }
}
