import AppKit
import OOOCore
import OOOMotion
import SwiftUI

// Adapted from pitch.dog Studio's StudioSnapshot (StudioKit/Snapshot.swift in
// bomkino/backdrop), AGPL-3.0. See NOTICES.md.

/// Headless screenshots of the real editor, for CI and for review:
///
///     OOO --snapshot out.png [--scheme dark|light] [--size 1440x900]
///         [--slide file] [--format reel|portrait|square|landscape|uhd]
///         [--tab camera|look|voice] [--shot n] [--time seconds]
///         [--title "words" [--kicker "line"]] [--safe-areas] [--show-export]
///         [--settle seconds]
///
/// It opens a new document window (on the sample slide unless `--slide` gives
/// one), waits until the slide is drawn and its tour planned, sets the window
/// up as asked, draws it into a PNG and quits. The live Metal stage doesn't
/// appear in a view's cached drawing, so in its place the window shows the
/// exact frame the export would write at that moment.
@MainActor
public enum OOOSnapshot {
    public static var isRequested: Bool { CommandLine.arguments.contains("--snapshot") }

    /// One run per process, however many windows come up.
    static var started = false

    public static func arg(_ name: String) -> String? {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: name), i + 1 < a.count else { return nil }
        return a[i + 1]
    }

    static func flag(_ name: String) -> Bool { CommandLine.arguments.contains(name) }

    static var size: CGSize {
        let parts = (arg("--size") ?? "1440x900").split(separator: "x").compactMap { Double($0) }
        return CGSize(width: parts.first ?? 1440, height: parts.last ?? 900)
    }

    /// Called from `OOOLaunch.configure()`: settings for this run only (the
    /// argument domain is never saved), no restored windows, and a deadline.
    static func configure() {
        guard isRequested else { return }
        var args = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        args["appearance"] = arg("--scheme") == "light" ? AppearanceChoice.light.rawValue : AppearanceChoice.dark.rawValue
        args["showSafeAreas"] = flag("--safe-areas")
        args["ApplePersistenceIgnoreState"] = true
        UserDefaults.standard.setVolatileDomain(args, forName: UserDefaults.argumentDomain)
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) {
            print("snapshot: timed out")
            exit(3)
        }
    }

    /// Sets a freshly opened window up as the flags ask, then captures it.
    static func prepare(_ session: OOOSession, still: @escaping (CGImage?) -> Void) {
        sizeWindows()
        if let path = arg("--slide") { session.importSlide(URL(fileURLWithPath: path)) }
        if let id = arg("--format"), let f = CanvasFormat.presets.first(where: { $0.id == id }), f != session.project.format {
            session.setFormat(f)
        }
        if let text = arg("--title") {
            session.update("Title") { $0.title = OpeningTitle(text: text, kicker: arg("--kicker") ?? "") }
        }
        let began = Date()
        func ready() -> Bool {
            // The slide drawn, its reading done, and (for a slide of your own) its tour planned.
            let planned = arg("--slide") == nil || !session.project.shots.isEmpty
            return session.hasSlide && session.busy == nil && planned && Date().timeIntervalSince(began) > 1
        }
        func poll() {
            if !ready() && Date().timeIntervalSince(began) < 60 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { poll() }
                return
            }
            stage(session, still: still)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { poll() }
    }

    private static func stage(_ session: OOOSession, still: @escaping (CGImage?) -> Void) {
        sizeWindows()
        switch arg("--tab") {
        case "look": session.tab = .look
        case "voice": session.tab = .voice
        default: session.tab = .shot
        }
        if let n = arg("--shot").flatMap(Int.init), n >= 1, n <= session.orderedShots.count {
            session.select(.shot(session.orderedShots[n - 1].id))
        } else {
            session.selection = .overview
        }
        session.clock.playing = false
        if let t = arg("--time").flatMap(Double.init) { session.clock.time = min(max(t, 0), session.clock.duration) }
        session.touch()
        let t = session.clock.time
        let format = session.project.format
        let h = 1400.0
        let w = (h * Double(format.aspect)).rounded()
        let scene = session.exportScene()
        Task.detached(priority: .userInitiated) {
            var image: CGImage?
            if let scene, let stage = try? SlideStage() {
                image = try? stage.still(scene, at: t, width: Int(w), height: Int(h), samples: 8)
            }
            await MainActor.run {
                still(image)
                if flag("--show-export") { session.showExport = true }
                let settle = arg("--settle").flatMap(Double.init) ?? 2.5
                DispatchQueue.main.asyncAfter(deadline: .now() + settle) { capture(session) }
            }
        }
    }

    static func sizeWindows() {
        for w in NSApp.windows where w.isVisible && w.frame.width > 400 && !w.isSheet {
            w.setContentSize(size)
            w.setFrameOrigin(NSPoint(x: 20, y: 20))
        }
    }

    private static func capture(_ session: OOOSession) {
        guard let path = arg("--snapshot") else { exit(1) }
        let candidates = NSApp.windows.filter { $0.isVisible && !$0.isSheet && $0.contentView != nil && $0.frame.width > 400 }
        guard let window = candidates.first else {
            print("snapshot: no window")
            exit(1)
        }
        func render(_ w: NSWindow) -> NSBitmapImageRep? {
            guard let view = w.contentView?.superview ?? w.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
            view.cacheDisplay(in: view.bounds, to: rep)
            return rep
        }
        guard let base = render(window) else { exit(1) }
        var output = base
        if let sheet = window.attachedSheet, let sheetRep = render(sheet) {
            // The sheet drawn where it sits over its window.
            let size = NSSize(width: base.pixelsWide, height: base.pixelsHigh)
            let scale = CGFloat(base.pixelsWide) / window.frame.width
            let image = NSImage(size: size)
            image.lockFocus()
            base.draw(in: NSRect(origin: .zero, size: size))
            let origin = NSPoint(x: (sheet.frame.minX - window.frame.minX) * scale, y: (sheet.frame.minY - window.frame.minY) * scale)
            sheetRep.draw(in: NSRect(x: origin.x, y: origin.y, width: sheet.frame.width * scale, height: sheet.frame.height * scale))
            image.unlockFocus()
            if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) { output = rep }
        }
        guard let data = output.representation(using: .png, properties: [:]) else { exit(1) }
        do {
            try data.write(to: URL(fileURLWithPath: path))
        } catch {
            print("snapshot: couldn't write \(path): \(error.localizedDescription)")
            exit(1)
        }
        let p = session.project
        print(String(format: "snapshot %@ %dx%d slide \"%@\" shots %d time %.2f of %.2f",
                     path, output.pixelsWide, output.pixelsHigh, p.slide.name, p.shots.count,
                     session.clock.time, session.clock.duration)
              + " message \(session.message.map { "\"\($0)\"" } ?? "none")")
        exit(0)
    }
}

/// The frame shown in place of the live stage during a snapshot.
struct SnapshotStillKey: EnvironmentKey {
    static let defaultValue: CGImage? = nil
}

extension EnvironmentValues {
    var snapshotStill: CGImage? {
        get { self[SnapshotStillKey.self] }
        set { self[SnapshotStillKey.self] = newValue }
    }
}

/// Starts a snapshot run when the first window appears.
struct SnapshotHost: ViewModifier {
    let session: OOOSession
    @State private var still: CGImage?

    func body(content: Content) -> some View {
        content
            .environment(\.snapshotStill, still)
            .onAppear {
                guard OOOSnapshot.isRequested, !OOOSnapshot.started else { return }
                OOOSnapshot.started = true
                OOOSnapshot.prepare(session) { still = $0 }
            }
    }
}
