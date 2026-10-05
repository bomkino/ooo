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
//
// Every command takes --project <file.ooo> (default: the sample) and
// --format reel|portrait|square|landscape.

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
    project.format = f
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
        let source = try SlideSource(ref: project.slide, media: media)
        guard let image = source.renderWhole(side: 3200) else { fail("could not draw the slide") }
        let details = try SlideAnalysis.details(of: image)
        for d in details {
            print(d.kind.rawValue, String(format: "%.3f %.3f %.3f %.3f", d.frame.minU, d.frame.minV, d.frame.maxU, d.frame.maxV), d.text)
        }
        let shots = Director.shots(DirectorInput(details: details, slideAspect: project.slideAspect,
                                                 canvasAspect: project.canvasAspect, start: project.arrive.end))
        for s in shots {
            print(String(format: "shot %.2f s", s.time), s.label ?? "", s.move.rawValue, s.ease.rawValue, s.emphasis.rawValue)
        }
    } catch {
        fail("analyze failed: \(error)")
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
      shaders | still | sheet | render | analyze | path
      --project file.ooo  --format reel|portrait|square|landscape  --out path
    """)
}

final class ErrorBox: @unchecked Sendable {
    var error: Error?
}

enum BackdropCatalogInfo {
    static var count: Int { BackdropCatalog.styles.count }
}
