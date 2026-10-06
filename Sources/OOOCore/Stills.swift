import Foundation
import RenderCore

/// The stills of a video, for a carousel post or a deck: the opening, then
/// each framing, as the export draws them.
public enum Stills {
    /// When each still is taken, and its file name: the opening once the
    /// slide (and its title) has settled, then each framing once the camera
    /// has landed and its emphasis has come in. A Pull Back's return to the
    /// whole slide would repeat the opening, so it is left out.
    public static func moments(_ scene: SlideScene) -> [(name: String, time: Double)] {
        var out: [(name: String, time: Double)] = []
        for (i, beat) in scene.choreography.beats.enumerated() where i == 0 || !beat.isOverview {
            let t = min(beat.land + min(1.0, beat.hold * 0.5), scene.duration - 0.02)
            let label = i == 0 ? "Opening" : (beat.shot.label ?? "Shot \(i)")
            out.append((String(format: "%02d %@", out.count + 1, fileName(label)), max(t, 0)))
        }
        return out
    }

    /// Draws every still at `width` × `height` into `folder` as PNGs, with
    /// a renderer of its own, and returns the files in order.
    public static func write(_ scene: SlideScene, to folder: URL, width: Int, height: Int, samples: Int = 16) throws -> [URL] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stage = try SlideStage()
        return try moments(scene).map { m in
            let url = folder.appendingPathComponent(m.name + ".png")
            try ImageOutput.writePNG(stage.still(scene, at: m.time, width: width, height: height, samples: samples), to: url)
            return url
        }
    }

    /// A label as a file name: no path separators or ellipsis, not too long.
    static func fileName(_ label: String) -> String {
        var s = label.replacingOccurrences(of: "…", with: "")
        for bad in ["/", ":", "\\", "\n"] { s = s.replacingOccurrences(of: bad, with: "-") }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        if s.count > 48 { s = String(s.prefix(48)).trimmingCharacters(in: .whitespaces) }
        return s.isEmpty ? "Shot" : s
    }
}
