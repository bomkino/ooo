import BackdropKit
import CoreGraphics
import Foundation
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
//   ooo-lab path    [--out path.csv]        the camera's path, sampled
//   ooo-lab landings --out dir              a still at the opening and at every landing
//   ooo-lab fixture --kind wide|standard --out f.png|f.pdf [--scale 2]
//                                           draw a test slide: 2576 × 1080 or 1920 × 1080
//   ooo-lab openings --out grid.png         the opening at five angles (across) and
//                                           three floors (down: none, soft, mirror)
//
// Every command takes --project <file.ooo> (default: the sample), or
// --slide <file> (a PDF or picture, read and directed as the app would on a
// drop), --format reel|portrait|square|landscape and --floor none|soft|mirror.

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
if let f = value("--floor") {
    guard let floor = FloorKind(rawValue: f) else { fail("unknown floor \(f)") }
    project.floor = floor
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
    let (format, floor) = (project.format, project.floor)
    project = OOOProject(slide: ref, format: format)
    project.floor = floor
    media = dir
    do {
        let details = try SlideAnalysis.read(SlideSource(ref: ref, media: dir))
        project.shots = Director.shots(project.directorInput(details))
    } catch {
        fail("could not read \(path): \(error)")
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

case "openings":
    // The opening as the slide comes to rest, at five angles and three floors.
    let base = loadScene()
    let out = URL(fileURLWithPath: value("--out") ?? "openings.png")
    let yaws: [Float] = [-9, -20, -28, -34, -40]
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

case "fixture":
    guard let kind = Fixture(rawValue: value("--kind") ?? "wide") else { fail("unknown fixture; use wide or standard") }
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
      shaders | still | sheet | render | analyze | path | landings | openings | fixture
      --project file.ooo | --slide file.pdf|png  --format reel|portrait|square|landscape  --floor none|soft|mirror  --out path
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
