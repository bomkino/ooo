import AppKit
import OOOCore
import OOOMotion
import ScreenCaptureKit
import SwiftUI

// Adapted from pitch.dog Studio's StudioSnapshot (StudioKit/Snapshot.swift in
// bomkino/backdrop), AGPL-3.0. See NOTICES.md.

/// Headless screenshots of the real editor, for CI and for review:
///
///     OOO --snapshot out.png [--scheme dark|light] [--size 1440x900]
///         [--slide file] [--format reel|portrait|square|landscape|uhd]
///         [--tab camera|look|voice] [--shot n] [--time seconds]
///         [--title "words" [--kicker "line"]] [--safe-areas] [--show-export]
///         [--more file,file [--melt 1,2|all] [--home]] [--marks demo] [--draw]
///         [--mode frame|draw|live] [--zoom 2] [--lift whole|4-10,14-]
///         [--no-map] [--no-inspector] [--settle seconds]
///
/// It opens a new document window (on the sample slide unless `--slide` gives
/// one), waits until the slide is drawn and its tour planned, sets the window
/// up as asked, captures it into a PNG and quits. It takes the window as the
/// screen shows it where this Mac allows screen capture, and otherwise draws
/// its views, which leaves out glass and the inspector's column. Neither sees
/// the live Metal stage reliably, so in its place the window shows the exact
/// frame the export would write at that moment.
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

    /// The window opens with its inspector closed.
    static var hidesInspector: Bool { isRequested && flag("--no-inspector") }

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
        // The slide map in its own pane, shared as it is on a first launch, unless asked to keep it in the inspector.
        args["showSlideMap"] = !flag("--no-map")
        args["slideMapShare"] = 0.0
        args["ApplePersistenceIgnoreState"] = true
        // A value after a flag that takes none (`--draw --time 6`) is not a
        // document to open: AppKit would say it can't open "6" and wait for OK.
        args["NSTreatUnknownArgumentsAsOpen"] = false
        UserDefaults.standard.setVolatileDomain(args, forName: UserDefaults.argumentDomain)
        // A soak runs a take and minutes of playback; anything else is a still.
        let deadline: Double = OOOSoak.isRequested ? 300 : 120
        DispatchQueue.main.asyncAfter(deadline: .now() + deadline) {
            print("snapshot: timed out")
            fflush(stdout)
            _exit(3)
        }
        // Only a main thread that never comes back misses the deadline above:
        // say so, with everything printed so far, before the script samples it.
        DispatchQueue.global().asyncAfter(deadline: .now() + deadline + 5) {
            print("snapshot: the main thread has not answered for at least five seconds")
            fflush(stdout)
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
        if let list = arg("--more") {
            session.addSlides(list.split(separator: ",").map { URL(fileURLWithPath: String($0)) })
        }
        if let spec = arg("--lift"), let lift = Lift(spec: spec) {
            session.update("Space for You") { $0.lift = lift }
        }
        let began = Date()
        func ready() -> Bool {
            // The slide drawn, its reading done, and (for a slide of your own) its tour planned.
            let planned = (arg("--slide") == nil && arg("--more") == nil) || !session.project.shots.isEmpty
            return session.hasSlide && session.pagesReady && session.busy == nil && planned && Date().timeIntervalSince(began) > 1
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
        if OOOSoak.isRequested {
            // The live stage stays on screen: the soak watches it run.
            OOOSoak.run(session) { code in
                exitCode = code
                capture(session)
            }
            return
        }
        // How the card changes to each added slide, then a mark or two, now the tour is planned.
        let melts = arg("--melt") ?? ""
        for k in 1..<max(session.project.slideCount, 1) where melts == "all" || melts.split(separator: ",").contains(where: { Int($0) == k }) {
            session.setChange(k, .melt)
        }
        if flag("--home") { session.setHome(true) }
        if arg("--marks") == "demo" {
            session.update("Draw") { p in
                p.marks = (0..<p.slideCount).compactMap { k in
                    guard let shot = p.shots.filter({ p.pageIndex($0.page) == k && $0.focus != nil }).min(by: { $0.time < $1.time }),
                          let focus = shot.focus else { return nil }
                    return Mark(page: p.pageID(k), time: shot.time + 0.25, strokes: [Mark.loop(around: focus, slideAspect: p.slide(k).aspect, seed: k)],
                                color: k % 2 == 0 ? .red : .yellow, fades: k > 0)
                }
            }
        }
        if flag("--draw") || arg("--mode") == "draw" {
            session.enter(.draw)
            session.previewUntil = nil
        }
        if let tool = arg("--pen").flatMap(PenTool.init(rawValue:)) { session.pen.tool = tool }
        if flag("--pen-fades") { session.pen.fades = true }
        if arg("--mode") == "live" { session.enter(.live) }
        if let z = arg("--zoom").flatMap(Double.init) { session.timelineZoom = max(z, 1) }
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

    /// The window at the size asked for, as far as the screen allows, with
    /// the Dock and menu bar out of the way.
    static func sizeWindows() {
        NSApp.activate(ignoringOtherApps: true)
        if NSApp.isActive { NSApp.presentationOptions = [.autoHideDock, .autoHideMenuBar] }
        for w in NSApp.windows where w.isVisible && w.frame.width > 400 && !w.isSheet {
            let visible = (w.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(origin: .zero, size: size)
            let width = min(size.width, visible.width), height = min(size.height, visible.height)
            w.setFrame(NSRect(x: visible.minX, y: visible.maxY - height, width: width, height: height), display: true)
        }
    }

    /// The window and its sheet as the screen shows them, or nil where this
    /// Mac doesn't allow screen capture.
    private static func screenImage(of window: NSWindow) async -> CGImage? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            let ids = Set([window.windowNumber] + (window.attachedSheet.map { [$0.windowNumber] } ?? []))
            let mine = content.windows.filter { ids.contains(Int($0.windowID)) }
            guard let main = mine.first(where: { Int($0.windowID) == window.windowNumber }),
                  let display = content.displays.first(where: { $0.frame.intersects(main.frame) }) ?? content.displays.first
            else { return nil }
            let config = SCStreamConfiguration()
            config.sourceRect = main.frame.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
            config.width = Int(main.frame.width * window.backingScaleFactor)
            config.height = Int(main.frame.height * window.backingScaleFactor)
            config.showsCursor = false
            return try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: display, including: mine),
                                                              configuration: config)
        } catch {
            print("snapshot: no screen capture here (\(error.localizedDescription)), so the window's views are drawn instead")
            return nil
        }
    }

    /// How the window and its views are sized, in the log, and a warning
    /// when the editor needs more height than the window has (which leaves
    /// the timeline off the bottom of a small screen).
    private static func describeLayout(_ window: NSWindow) {
        func s(_ r: NSRect) -> String { String(format: "%.0f,%.0f %.0f×%.0f", r.minX, r.minY, r.width, r.height) }
        func s(_ z: NSSize) -> String { String(format: "%.0f×%.0f", z.width, z.height) }
        let screen = window.screen ?? NSScreen.main
        print("layout: window \(s(window.frame)), content \(s(window.contentLayoutRect)), min \(s(window.minSize)),"
              + " screen \(s(screen?.frame ?? .zero)), visible \(s(screen?.visibleFrame ?? .zero))")
        guard let content = window.contentView else { return }
        for view in content.subviews {
            print("layout:   \(type(of: view)) \(s(view.frame)) fitting \(s(view.fittingSize))")
        }
        let needed = content.subviews.map(\.fittingSize.height).max() ?? 0
        if needed > window.contentLayoutRect.height + 1 {
            print(String(format: "layout: the editor needs %.0f points of height and the window has %.0f",
                         needed, window.contentLayoutRect.height))
        }
    }

    private static func capture(_ session: OOOSession) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && !$0.isSheet && $0.contentView != nil && $0.frame.width > 400 })
        else {
            print("snapshot: no window")
            exit(1)
        }
        describeLayout(window)
        // A Mac that would ask about screen capture waits for an answer no
        // one gives: after a few seconds the views are drawn instead.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            guard !written else { return }
            print("snapshot: screen capture didn't answer, so the window's views are drawn instead")
            write(drawn(window), session: session, via: "views")
        }
        Task { @MainActor in
            let image = await screenImage(of: window)
            guard !written else { return }
            if let image {
                write(NSBitmapImageRep(cgImage: image), session: session, via: "screen")
            } else {
                write(drawn(window), session: session, via: "views")
            }
        }
    }

    /// Set once the PNG is written, so a late capture doesn't write it again.
    static var written = false
    /// What the run exits with once the PNG is written: a soak that failed says so.
    static var exitCode: Int32 = 0

    /// The window drawn from its views, its sheet over it.
    private static func drawn(_ window: NSWindow) -> NSBitmapImageRep? {
        func render(_ w: NSWindow) -> NSBitmapImageRep? {
            guard let view = w.contentView?.superview ?? w.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
            view.cacheDisplay(in: view.bounds, to: rep)
            return rep
        }
        guard let base = render(window) else { return nil }
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
        return output
    }

    private static func write(_ output: NSBitmapImageRep?, session: OOOSession, via method: String) {
        written = true
        guard let path = arg("--snapshot"), let output, let data = output.representation(using: .png, properties: [:]) else { exit(1) }
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
              + " message \(session.message.map { "\"\($0)\"" } ?? "none") via \(method)")
        exit(exitCode)
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
