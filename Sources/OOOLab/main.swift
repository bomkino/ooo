import BackdropKit
import CoreGraphics
import Foundation
import Metal
import OOOCore
import OOOMotion
import RenderCore
import StageKit

// ooo-lab: headless renders and checks, for review and CI.
//
//   ooo-lab shaders                         compile every shader and pipeline
//   ooo-lab still   [--t 6.6] --out f.png   one frame
//   ooo-lab sheet   --out sheet.png         a contact sheet across the video
//   ooo-lab render  --out v.mp4 [--quality draft|good|best] [--scale 0.5] [--codec h264|hevc]
//   ooo-lab analyze                         read the slide and plan a tour
//   ooo-lab plan                            the tour as it stands (after --replace, as it followed)
//   ooo-lab path    [--out path.csv]        the camera's path, sampled
//   ooo-lab landings --out dir              a still at the opening and at every landing
//   ooo-lab fixture --kind wide|wide-revised|standard --out f.png|f.pdf [--scale 2]
//                                           draw a test slide: 2576 × 1080 or 1920 × 1080
//                                           (wide-revised: the wide slide corrected)
//   ooo-lab stills --out dir                the stills Save Stills writes: the opening, then
//                                           each framing
//   ooo-lab openings --out grid.png         the opening at five turns, 28° to 52° (across), and
//                                           three floors (down: none, soft, mirror)
//   ooo-lab titles --out grid.png           the opening title in four faces, and in time
//   ooo-lab backdrops --out grid.png        every look behind the opening, as itself and From Slide
//   ooo-lab arrivals --out grid.png         each arrival at five moments of its entrance
//   ooo-lab blurcheck [--quality good]      adaptive motion blur against full samples:
//                                           samples taken, GPU time, PSNR
//   ooo-lab render --full-blur ...          every frame at the quality's full samples
//   ooo-lab inkcheck                        at every landing, how dark the type comes out
//                                           against the same pixels drawn as supplied
//   ooo-lab motioncheck [--strict]          each move's peak speed and turn, each emphasis,
//                                           any jump (--strict: exit 2 on a problem)
//   ooo-lab loopcheck [--ending leave]      the step from the last frame back to the
//                                           first against the steps either side of it
//   ooo-lab bench                           export and preview timings (p50, p95, p99), and the machine
//   ooo-lab colorcheck                      each landing as drawn against the same frame decoded
//                                           from the video: ΔE as written and as macOS shows it
//
// Every command takes --project <file.ooo> (default: the sample), or
// --slide <file> (a PDF or picture, read and directed as the app would on a
// drop) and --replace <file> (then Replace Slide with it: the tour follows
// its words onto the new slide), --format reel|portrait|square|landscape, --floor none|soft|mirror,
// --ending hold|pullBack|fade|leave, --arrive rise|unfold|drop|develop|turn|glide|weave|none and --title "words" [--kicker "line above"
// [--kicker-as-typed]] [--face modern|grotesk|editorial|poster].

let args = CommandLine.arguments
func value(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let command = args.count > 1 ? args[1] : "help"
var project = OOOProject.sample
var media: URL?
if let path = value("--project") {
    do {
        (project, media) = try ProjectPackage.read(URL(fileURLWithPath: path))
    } catch {
        fail("could not read \(path): \(error)")
    }
}
if let id = value("--format") {
    guard let f = CanvasFormat.presets.first(where: { $0.id == id }) else { fail("unknown format \(id)") }
    let (A, C) = (project.slideAspect, project.canvasAspect)
    project.format = f
    project.adaptOverview(fromSlideAspect: A, canvasAspect: C)
}
if let a = value("--arrive") {
    guard let kind = ArriveKind(rawValue: a) else { fail("unknown arrival \(a)") }
    project.arrive = Arrive(kind: kind)
}
if let text = value("--title") {
    var t = OpeningTitle(text: text, kicker: value("--kicker") ?? "", kickerCaps: !args.contains("--kicker-as-typed"))
    if let f = value("--face") {
        guard let face = ReelTitle.Face(rawValue: f) else { fail("unknown face \(f)") }
        t.face = face
    }
    project.title = t
    project.makeRoomForTitle()
}
if let f = value("--floor") {
    guard let floor = FloorKind(rawValue: f) else { fail("unknown floor \(f)") }
    project.floor = floor
}
if let e = value("--ending") {
    guard let ending = Ending(rawValue: e) else { fail("unknown ending \(e)") }
    project.ending = ending
}
if let path = value("--slide") {
    // The app's drop: copy the file in, read it, plan a tour.
    let url = URL(fileURLWithPath: path)
    guard var ref = SlideSource.inspect(url) else { fail("not a slide: \(path)") }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ooo-lab-\(UUID().uuidString)", isDirectory: true)
    let file = "slide." + url.pathExtension.lowercased()
    do {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: url, to: dir.appendingPathComponent(file))
    } catch {
        fail("could not copy \(path): \(error)")
    }
    ref.file = file
    let (format, floor, title, ending, arrive) = (project.format, project.floor, project.title, project.ending, project.arrive)
    project = OOOProject(slide: ref, format: format)
    project.arrive = arrive
    project.floor = floor
    project.title = title
    project.ending = ending
    media = dir
    do {
        let details = try SlideAnalysis.read(SlideSource(ref: ref, media: dir))
        project.shots = Director.shots(project.directorInput(details))
        project.reading = details
        project.makeRoomForTitle()
    } catch {
        fail("could not read \(path): \(error)")
    }
}
if let path = value("--replace") {
    // The app's Replace Slide: the new slide, and the tour following its words onto it.
    guard let dir = media, let old = project.reading else { fail("--replace needs --slide") }
    let url = URL(fileURLWithPath: path)
    guard var ref = SlideSource.inspect(url) else { fail("not a slide: \(path)") }
    let file = "replaced." + url.pathExtension.lowercased()
    do {
        try FileManager.default.copyItem(at: url, to: dir.appendingPathComponent(file))
        ref.file = file
        let new = try SlideAnalysis.read(SlideSource(ref: ref, media: dir))
        project.replaceSlide(with: ref, reading: new, from: old)
    } catch {
        fail("could not replace the slide with \(path): \(error)")
    }
}

func loadScene() -> SlideScene {
    do {
        return try SlideLoader.scene(for: project, media: media)
    } catch {
        fail("could not load the slide: \(error)")
    }
}

switch command {
case "shaders":
    do {
        let renderer = try StageRenderer()
        renderer.warmUp()
        let stage = try SlideStage(renderer: renderer)
        let scene = loadScene()
        _ = try stage.still(scene, at: scene.duration * 0.5, width: 270, height: 480, samples: 2)
        print("shaders ok: stage, backdrop (\(BackdropCatalogInfo.count) looks), finishing; device \(GPU.shared.device.name)")
    } catch {
        fail("shaders failed: \(error)")
    }

case "still":
    let scene = loadScene()
    let t = Double(value("--t") ?? "") ?? 6.6
    let out = URL(fileURLWithPath: value("--out") ?? "still.png")
    let samples = Int(value("--samples") ?? "") ?? 12
    do {
        let stage = try SlideStage()
        let img = try stage.still(scene, at: t, width: project.format.width, height: project.format.height, samples: samples)
        try ImageOutput.writePNG(img, to: out)
        print("still \(out.path) t \(t)")
    } catch {
        fail("still failed: \(error)")
    }

case "sheet":
    // Twelve frames in a grid, for looking at a whole video at a glance.
    let scene = loadScene()
    let out = URL(fileURLWithPath: value("--out") ?? "sheet.png")
    let cols = 6, rows = 2
    let cw = project.format.width / 4, ch = project.format.height / 4
    do {
        let stage = try SlideStage()
        guard let ctx = CGContext(data: nil, width: cw * cols, height: ch * rows, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fail("no context") }
        for k in 0..<(cols * rows) {
            let t = scene.duration * (Double(k) + 0.5) / Double(cols * rows)
            let img = try stage.still(scene, at: t, width: cw, height: ch, samples: 6)
            let x = (k % cols) * cw, y = (rows - 1 - k / cols) * ch
            ctx.draw(img, in: CGRect(x: x, y: y, width: cw, height: ch))
        }
        try ImageOutput.writePNG(ctx.makeImage()!, to: out)
        print("sheet \(out.path) \(cols * rows) frames over \(String(format: "%.1f", scene.duration)) s")
    } catch {
        fail("sheet failed: \(error)")
    }

case "render":
    let scene = loadScene()
    let out = URL(fileURLWithPath: value("--out") ?? "ooo.mp4")
    var options = ExportOptions()
    if let q = value("--quality"), let quality = ExportQuality(rawValue: q) { options.quality = quality }
    if let s = value("--scale"), let scale = Double(s) { options.scale = scale }
    if let c = value("--codec"), let codec = VideoCodec(rawValue: c) { options.codec = codec }
    if args.contains("--full-blur") { options.adaptiveBlur = false }
    var voice: AudioTrack?
    if let v = project.voice, let media {
        voice = try? VoiceLoader.decode(media.appendingPathComponent(v.file))
    }
    let started = Date()
    let done = DispatchSemaphore(value: 0)
    let box = ErrorBox()
    let job = Task.detached {
        do {
            let exporter = try OOOExporter()
            try await exporter.export(scene, voice: voice, options: options, to: out, progress: { p in
                if p.frame % 30 == 0 || p.frame == p.total { print("frame \(p.frame)/\(p.total)") }
            })
        } catch {
            box.error = error
        }
        done.signal()
    }
    _ = job
    done.wait()
    if let error = box.error { fail("render failed: \(error)") }
    print(String(format: "render %@ %.1f s of video in %.1f s", out.path, scene.duration, Date().timeIntervalSince(started)))

case "analyze":
    do {
        let started = Date()
        let details = try SlideAnalysis.read(SlideSource(ref: project.slide, media: media))
        print(String(format: "read the slide in %.2f s", Date().timeIntervalSince(started)))
        for d in details {
            print(d.kind.rawValue, String(format: "%.3f %.3f %.3f %.3f", d.frame.minU, d.frame.minV, d.frame.maxU, d.frame.maxV), d.text)
        }
        printPlan(Director.shots(project.directorInput(details)))
    } catch {
        fail("analyze failed: \(error)")
    }

case "plan":
    printPlan(project.shots)

case "landings":
    // The opening, then each framing a moment after the camera lands on it.
    let scene = loadScene()
    let dir = URL(fileURLWithPath: value("--out") ?? "landings", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let samples = Int(value("--samples") ?? "") ?? 12
    let beats = scene.choreography.beats
    var moments: [(String, Double)] = []
    if project.arrive.kind != .none { moments.append(("arrive", project.arrive.duration * 0.5)) }
    for (i, beat) in beats.enumerated() {
        let t = min(beat.land + min(0.7, beat.hold * 0.45), scene.duration - 0.02)
        let name = beat.isOverview ? (i == 0 ? "opening" : "ending") : String(format: "shot-%02d", i)
        moments.append((name, t))
    }
    do {
        let stage = try SlideStage()
        for (name, t) in moments {
            let img = try stage.still(scene, at: t, width: project.format.width, height: project.format.height, samples: samples)
            try ImageOutput.writeJPEG(img, to: dir.appendingPathComponent(name + ".jpg"), quality: 0.9)
            print(String(format: "landing %@ t %.2f", name, t))
        }
    } catch {
        fail("landings failed: \(error)")
    }

case "stills":
    // What Save Stills writes, at the canvas's size.
    let scene = loadScene()
    let dir = URL(fileURLWithPath: value("--out") ?? "stills", isDirectory: true)
    do {
        for url in try Stills.write(scene, to: dir, width: project.format.width, height: project.format.height) {
            print("still \(url.lastPathComponent)")
        }
    } catch {
        fail("stills failed: \(error)")
    }

case "openings":
    // The opening as the slide comes to rest, at five angles and three floors.
    let base = loadScene()
    let out = URL(fileURLWithPath: value("--out") ?? "openings.png")
    let yaws: [Float] = [-28, -34, -40, -46, -52]
    let floors: [FloorKind] = [.none, .soft, .mirror]
    let cw = project.format.width / 3, ch = project.format.height / 3
    do {
        let stage = try SlideStage()
        guard let ctx = CGContext(data: nil, width: cw * yaws.count, height: ch * floors.count, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fail("no context") }
        for (r, floor) in floors.enumerated() {
            for (c, yaw) in yaws.enumerated() {
                var p = project
                p.overview.yaw = yaw
                p.floor = floor
                p.shots = []
                p.length = p.arrive.end + 3
                let scene = SlideScene(project: p, base: base.base, details: base.details)
                let img = try stage.still(scene, at: p.arrive.end + 1.2, width: cw, height: ch, samples: 4)
                ctx.draw(img, in: CGRect(x: c * cw, y: (floors.count - 1 - r) * ch, width: cw, height: ch))
            }
        }
        try ImageOutput.writePNG(ctx.makeImage()!, to: out)
        print("openings \(out.path): yaw \(yaws) across, floors \(floors.map(\.rawValue)) down")
    } catch {
        fail("openings failed: \(error)")
    }

case "backdrops":
    // Every look behind the opening as it comes to rest, in pairs: its own
    // palette, then From Slide (the room in the slide's colours).
    let base = loadScene()
    let out = URL(fileURLWithPath: value("--out") ?? "backdrops.png")
    let looks = BackdropCatalog.styles
    let colours = (try? SlideSource(ref: project.slide, media: media))?.renderWhole(side: 512)
        .flatMap { Palette.extract(from: [$0], id: "slide", name: "Slide") }
    let pairs = 3
    let cw = project.format.width / 4, ch = project.format.height / 4
    let rows = (looks.count + pairs - 1) / pairs
    do {
        let stage = try SlideStage()
        guard let ctx = CGContext(data: nil, width: cw * pairs * 2, height: ch * rows, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fail("no context") }
        for (i, look) in looks.enumerated() {
            for side in 0..<2 {
                var p = project
                p.backdrop = look.defaults
                if side == 1, let colours { p.backdrop.palette = colours.atLightness(of: look.defaults.palette) }
                p.shots = []
                p.length = p.arrive.end + 3
                let scene = SlideScene(project: p, base: base.base, details: base.details)
                let img = try stage.still(scene, at: p.arrive.end + 1.2, width: cw, height: ch, samples: 4)
                let (r, c) = (i / pairs, (i % pairs) * 2 + side)
                ctx.draw(img, in: CGRect(x: c * cw, y: (rows - 1 - r) * ch, width: cw, height: ch))
            }
        }
        try ImageOutput.writePNG(ctx.makeImage()!, to: out)
        print("backdrops \(out.path): \(looks.map(\.name)) in reading order, each as itself then From Slide")
    } catch {
        fail("backdrops failed: \(error)")
    }

case "arrivals":
    // Each arrival (down) at five moments of its entrance (across), the last
    // just after it has come to rest.
    let base = loadScene()
    let out = URL(fileURLWithPath: value("--out") ?? "arrivals.png")
    let kinds = ArriveKind.allCases.filter { $0 != .none }
    let moments = [0.15, 0.35, 0.55, 0.75, 1.0]
    let cw = project.format.width / 4, ch = project.format.height / 4
    do {
        let stage = try SlideStage()
        guard let ctx = CGContext(data: nil, width: cw * moments.count, height: ch * kinds.count, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fail("no context") }
        for (r, kind) in kinds.enumerated() {
            var p = project
            p.arrive = Arrive(kind: kind)
            p.title = nil
            p.shots = []
            p.length = p.arrive.end + 3
            let scene = SlideScene(project: p, base: base.base, details: base.details)
            for (c, m) in moments.enumerated() {
                let t = m < 1 ? p.arrive.duration * m : p.arrive.end + 0.3
                let img = try stage.still(scene, at: t, width: cw, height: ch, samples: 6)
                ctx.draw(img, in: CGRect(x: c * cw, y: (kinds.count - 1 - r) * ch, width: cw, height: ch))
            }
        }
        try ImageOutput.writePNG(ctx.makeImage()!, to: out)
        print("arrivals \(out.path): \(kinds.map(\.title)) down, at \(moments.dropLast().map { "\(Int($0 * 100))%" }) and at rest across")
    } catch {
        fail("arrivals failed: \(error)")
    }

case "titles":
    // The opening title in each face (top row), and in time (bottom row:
    // rising in, held, clearing as the camera sets off, back for the Pull Back).
    let base = loadScene()
    let out = URL(fileURLWithPath: value("--out") ?? "titles.png")
    let cw = project.format.width / 3, ch = project.format.height / 3
    var words = project.title ?? OpeningTitle(text: "One slide, obsessed over.", kicker: "pitch.dog")
    if words.isEmpty { words = OpeningTitle(text: "One slide, obsessed over.", kicker: "pitch.dog") }
    do {
        let stage = try SlideStage()
        guard let ctx = CGContext(data: nil, width: cw * 4, height: ch * 2, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fail("no context") }
        for (c, face) in ReelTitle.Face.allCases.enumerated() {
            var p = project
            p.title = words
            p.title?.face = face
            p.makeRoomForTitle()
            let scene = SlideScene(project: p, base: base.base, details: base.details)
            let rest = (scene.choreography.beats.first?.land ?? 2) + 1.0
            let img = try stage.still(scene, at: rest, width: cw, height: ch, samples: 4)
            ctx.draw(img, in: CGRect(x: c * cw, y: ch, width: cw, height: ch))
        }
        var p = project
        p.title = words
        p.makeRoomForTitle()
        let scene = SlideScene(project: p, base: base.base, details: base.details)
        let beats = scene.choreography.beats
        let land = beats.first?.land ?? 2
        let leave = beats.count > 1 ? beats[1].depart + 0.2 : land + 2
        let back = (beats.count > 2 && beats.last?.isOverview == true) ? (beats.last?.land ?? scene.duration) + 0.3 : scene.duration - 0.2
        for (c, t) in [land - 0.2, land + 1.0, leave, back].enumerated() {
            let img = try stage.still(scene, at: t, width: cw, height: ch, samples: 4)
            ctx.draw(img, in: CGRect(x: c * cw, y: 0, width: cw, height: ch))
        }
        try ImageOutput.writePNG(ctx.makeImage()!, to: out)
        print("titles \(out.path): faces \(ReelTitle.Face.allCases.map(\.rawValue)) across the top; rising, held, clearing, back below")
    } catch {
        fail("titles failed: \(error)")
    }

case "blurcheck":
    // Adaptive motion blur against every frame at full samples: how many
    // samples each frame took, how long the GPU spent, and how far apart the
    // pictures are (PSNR; above 45 dB nobody can tell).
    let scene = loadScene()
    let quality = ExportQuality(rawValue: value("--quality") ?? "good") ?? .good
    let w = project.format.width, h = project.format.height
    let step = Double(value("--step") ?? "") ?? 0.2
    do {
        let stage = try SlideStage()
        let gpu = GPU.shared
        func frame(_ t: Double, adaptive: Bool) throws -> (pixels: [UInt8], samples: Int, ms: Double) {
            let out = gpu.makeTexture(width: w, height: h, format: .bgra8Unorm, usage: [.renderTarget, .shaderRead], storage: .shared)
            guard let cb = gpu.queue.makeCommandBuffer() else { throw RenderError.io("GPU unavailable.") }
            let n = try stage.encode(cb, scene: scene, at: t, output: out, samples: quality.samples,
                                     frameIndex: UInt32(t * Double(project.fps)), waitForDetail: true, adaptive: adaptive)
            cb.commit()
            cb.waitUntilCompleted()
            var px = [UInt8](repeating: 0, count: w * h * 4)
            out.getBytes(&px, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
            return (px, n, (cb.gpuEndTime - cb.gpuStartTime) * 1000)
        }
        // Warm the pipelines and the close-ups first, so timings compare like with like.
        _ = try frame(scene.duration / 2, adaptive: false)
        var rows: [String] = []
        var worst = Double.infinity, sum = 0.0, count = 0, ones = 0, taken = 0
        var msAdaptive = 0.0, msFull = 0.0
        for t in stride(from: 0, to: scene.duration, by: step) {
            let full = try frame(t, adaptive: false)
            let fast = try frame(t, adaptive: true)
            var se = 0.0
            for i in stride(from: 0, to: full.pixels.count, by: 4) {
                for c in 0..<3 {
                    let d = Double(full.pixels[i + c]) - Double(fast.pixels[i + c])
                    se += d * d
                }
            }
            let mse = se / Double(w * h * 3)
            let psnr = mse == 0 ? 99 : 10 * log10(255 * 255 / mse)
            worst = min(worst, psnr)
            sum += min(psnr, 99)
            count += 1
            taken += fast.samples
            if fast.samples == 1 { ones += 1 }
            msAdaptive += fast.ms
            msFull += full.ms
            rows.append(String(format: "%6.2f s  %2d samples  %5.1f dB  %5.1f ms vs %5.1f ms", t, fast.samples, psnr, fast.ms, full.ms))
        }
        rows.forEach { print($0) }
        print(String(format: "blur %@: %d frames, %.1f samples a frame on average (of %d), %d%% held at one; GPU %.0f ms vs %.0f ms (%.0f%% saved); PSNR worst %.1f dB, mean %.1f dB",
                     quality.rawValue, count, Double(taken) / Double(max(count, 1)), quality.samples, 100 * ones / max(count, 1),
                     msAdaptive, msFull, 100 * (1 - msAdaptive / max(msFull, 1e-6)), worst, sum / Double(max(count, 1))))
    } catch {
        fail("blurcheck failed: \(error)")
    }

case "inkcheck":
    // The slide must read as it is. At every landing the frame is drawn twice:
    // as the video draws it, and as supplied (the Original surface, no
    // bloom, grain or vignette, on a pale room so nothing but ink is dark).
    // The ink is the darkest pixels of the as-supplied frame inside the
    // canvas's clear area; the check compares the same pixels in both.
    let scene = loadScene()
    var plain = project
    plain.look.surface = .original
    plain.look.finish.bloom = 0
    plain.look.finish.grain = 0
    plain.look.finish.vignette = 0
    plain.backdrop = BackdropCatalog.style("solid").defaults
    plain.backdrop.palette = Palettes.named("Gallery")
    plain.floor = FloorKind.none
    let reference: SlideScene
    do {
        reference = try SlideLoader.scene(for: plain, media: media)
    } catch {
        fail("could not load the slide: \(error)")
    }
    let w = project.format.width, h = project.format.height
    func lumas(_ img: CGImage) -> [UInt8] {
        let iw = img.width, ih = img.height
        var px = [UInt8](repeating: 0, count: iw * ih * 4)
        guard let ctx = CGContext(data: &px, width: iw, height: ih, bitsPerComponent: 8, bytesPerRow: iw * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return [] }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: iw, height: ih))
        var out = [UInt8](repeating: 0, count: iw * ih)
        for i in 0..<(iw * ih) {
            let r = Double(px[4 * i]), g = Double(px[4 * i + 1]), b = Double(px[4 * i + 2])
            let l: Double = 0.2126 * r + 0.7152 * g + 0.0722 * b
            out[i] = UInt8(min(255.0, l.rounded()))
        }
        return out
    }
    func median(_ v: [UInt8]) -> Int { v.isEmpty ? 0 : Int(v.sorted()[v.count / 2]) }
    let safe = project.format.safeArea
    let x0 = Int(Float(w) * safe.left), x1 = Int(Float(w) * (1 - safe.right))
    let y0 = Int(Float(h) * safe.top), y1 = Int(Float(h) * (1 - safe.bottom))
    do {
        let stage = try SlideStage()
        var worst = 0, worstName = ""
        var worstAt = (t: 0.0, pixels: [Int](), supplied: 0)
        for (i, beat) in scene.choreography.beats.enumerated() where !beat.isOverview {
            let t = min(beat.land + min(0.7, beat.hold * 0.45), scene.duration - 0.02)
            let seen = lumas(try stage.still(scene, at: t, width: w, height: h, samples: 1))
            let supplied = lumas(try stage.still(reference, at: t, width: w, height: h, samples: 1))
            var box: [UInt8] = []
            for y in y0..<y1 { for x in x0..<x1 { box.append(supplied[y * w + x]) } }
            box.sort()
            let darkest = Int(box.isEmpty ? 255 : box[box.count / 100])
            var inkSeen: [UInt8] = [], inkSupplied: [UInt8] = [], pixels: [Int] = []
            if darkest < 90 {
                for y in y0..<y1 {
                    for x in x0..<x1 where Int(supplied[y * w + x]) <= darkest + 8 {
                        inkSupplied.append(supplied[y * w + x])
                        inkSeen.append(seen[y * w + x])
                        pixels.append(y * w + x)
                    }
                }
            }
            let name = String(format: "shot-%02d", i)
            guard inkSeen.count >= 200 else {
                print(String(format: "%@ t %.2f  no dark ink in view", name, t))
                continue
            }
            let (a, b) = (median(inkSeen), median(inkSupplied))
            if a - b > worst {
                worst = a - b
                worstName = name
                worstAt = (t, pixels, b)
            }
            print(String(format: "%@ t %.2f  ink %3d as seen, %3d as supplied (%+d) over %d px  surface %.2f", name, t, a, b, a - b,
                         inkSeen.count, scene.surfaceAmount(at: t)))
        }
        if worst > 0 {
            // Where the lift comes from: the worst landing again, one part of the finish left out at a time.
            let parts: [(String, (inout OOOProject) -> Void)] = [
                ("without bloom", { $0.look.finish.bloom = 0 }),
                ("with the Original surface", { $0.look.surface = .original }),
                ("without grain or vignette", { $0.look.finish.grain = 0; $0.look.finish.vignette = 0 }),
                ("in a plain room", { $0.backdrop = plain.backdrop; $0.floor = FloorKind.none }),
            ]
            print("\(worstName), one part left out at a time:")
            for (label, leaveOut) in parts {
                var p = project
                leaveOut(&p)
                let v = lumas(try stage.still(try SlideLoader.scene(for: p, media: media), at: worstAt.t, width: w, height: h, samples: 1))
                let m = median(worstAt.pixels.map { v[$0] })
                print(String(format: "  %@: ink %3d (%+d)", label, m, m - worstAt.supplied))
            }
        }
        print("inkcheck: ink lands at most \(worst) above the slide as supplied" + (worstName.isEmpty ? "" : " (\(worstName))"))
    } catch {
        fail("inkcheck failed: \(error)")
    }

case "motioncheck":
    // How fast each move flies and turns at its peak, whether each emphasis
    // comes all the way in, and whether the picture ever jumps.
    let check = MotionCheck(project.choreography())
    print(check.summary)
    if args.contains("--strict"), !check.problems.isEmpty { exit(2) }

case "bench":
    do {
        try bench(loadScene())
    } catch {
        fail("bench failed: \(error)")
    }

case "colorcheck":
    do {
        try colorcheck(loadScene())
    } catch {
        fail("colorcheck failed: \(error)")
    }

case "loopcheck":
    // A platform plays a reel on repeat: the step from the last frame back to
    // the first should be no bigger than the steps between neighbouring frames.
    project.look.finish.grain = 0
    let scene = loadScene()
    let w = project.format.width / 2, h = project.format.height / 2
    let fps = Double(max(project.fps, 1))
    let n = max(2, Int((scene.duration * fps).rounded()))
    do {
        let stage = try SlideStage()
        func pixels(_ i: Int) throws -> [UInt8] {
            let img = try stage.still(scene, at: Double(i) / fps, width: w, height: h, samples: 1)
            var px = [UInt8](repeating: 0, count: w * h * 4)
            guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return px }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return px
        }
        func psnr(_ a: [UInt8], _ b: [UInt8]) -> Double {
            var se = 0.0
            for i in stride(from: 0, to: a.count, by: 4) {
                for c in 0..<3 {
                    let d = Double(a[i + c]) - Double(b[i + c])
                    se += d * d
                }
            }
            let mse = se / Double(w * h * 3)
            return mse == 0 ? 99 : 10 * log10(255 * 255 / mse)
        }
        let frames = try [n - 2, n - 1, 0, 1].map(pixels)
        let before = psnr(frames[0], frames[1]), wrap = psnr(frames[1], frames[2]), after = psnr(frames[2], frames[3])
        print(String(format: "loop %@, %d frames: last two %.1f dB, last to first %.1f dB, first two %.1f dB",
                     project.ending.rawValue, n, before, wrap, after))
        print(wrap >= min(before, after) - 3 ? "loopcheck: closes" : "loopcheck: jumps")
    } catch {
        fail("loopcheck failed: \(error)")
    }

case "fixture":
    guard let kind = Fixture(rawValue: value("--kind") ?? "wide") else { fail("unknown fixture; use wide, wide-revised or standard") }
    let out = URL(fileURLWithPath: value("--out") ?? "\(kind.rawValue).png")
    let scale = CGFloat(Double(value("--scale") ?? "") ?? 1)
    do {
        try kind.write(to: out, scale: scale)
        print("fixture \(kind.rawValue) \(out.path)")
    } catch {
        fail("fixture failed: \(error)")
    }

case "path":
    let c = project.choreography()
    var csv = "t,x,y,height,yaw,pitch,roll\n"
    var t = 0.0
    while t <= c.duration {
        let p = c.pose(at: t)
        csv += String(format: "%.4f,%.5f,%.5f,%.5f,%.3f,%.3f,%.3f\n", t, p.target.x, p.target.y, p.height,
                      degrees(p.yaw), degrees(p.pitch), degrees(p.roll))
        t += 1.0 / 120
    }
    if let out = value("--out") {
        try? csv.write(toFile: out, atomically: true, encoding: .utf8)
        print("path \(out) \(c.beats.count) beats over \(String(format: "%.1f", c.duration)) s")
    } else {
        print(csv, terminator: "")
    }

default:
    print("""
    ooo-lab — headless renders and checks for OOO
      shaders | still | sheet | render | analyze | plan | path | landings | stills | openings | titles
      backdrops | arrivals | blurcheck | inkcheck | motioncheck | loopcheck | bench | colorcheck | fixture
      --project file.ooo | --slide file.pdf|png [--replace file]  --format reel|portrait|square|landscape  --floor none|soft|mirror  --out path
    """)
}

/// The tour, one line a shot: when it lands, how close it goes (times closer
/// than the opening, and how tall the slide's text stands on the canvas),
/// how it moves.
func printPlan(_ shots: [Shot]) {
    let A = project.slideAspect, C = project.canvasAspect, safe = project.format.safeArea
    let opening = CameraPose(shot: project.overview, slideAspect: A, canvasAspect: C, safe: safe)
    print(String(format: "opening: the slide stands %.0f%% of the frame's height", 100 / opening.height))
    if let h = project.slide.pixelHeight, let zoom = project.sharpZoom {
        print(String(format: "picture %d px tall: sharp to %.1f× closer than the opening", h, zoom))
    }
    for s in shots.sorted(by: { $0.time < $1.time }) {
        let pose = CameraPose(shot: s, slideAspect: A, canvasAspect: C, safe: safe)
        var line = String(format: "shot %6.2f s  %5.2f×  slide %4.0f%% of frame  centre %.3f %.3f  size %.3f %.3f  ", s.time,
                          opening.height / pose.height, 100 / pose.height, s.frame.center.x, s.frame.center.y, s.frame.size.x, s.frame.size.y)
        line += "\(s.move.rawValue) \(s.ease.rawValue) \(s.emphasis.rawValue)"
        if let sweep = s.sweep { line += String(format: " reads along %.3f over %.1f s", sweep.x, s.sweepTime ?? 0) }
        print(line + "  \(s.label ?? "")")
    }
}

final class ErrorBox: @unchecked Sendable {
    var error: Error?
}

enum BackdropCatalogInfo {
    static var count: Int { BackdropCatalog.styles.count }
}
