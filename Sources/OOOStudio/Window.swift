import AppKit
import Combine
import OOOCore
import OOOMotion
import RenderCore
import StageKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Focused session for menu commands

public struct OOOSessionKey: FocusedValueKey {
    public typealias Value = OOOSession
}

extension FocusedValues {
    public var oooSession: OOOSession? {
        get { self[OOOSessionKey.self] }
        set { self[OOOSessionKey.self] = newValue }
    }
}

public enum OOOCommands {
    /// Chooses a new slide, or (`replacing`) a corrected version of slide
    /// `page` that keeps its tour.
    @MainActor
    public static func chooseSlide(_ session: OOOSession, replacing: Bool = false, page: Int = 0) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = OOOSession.slideTypes
        panel.message = replacing
            ? "Choose the corrected slide. The tour stays: each framing follows its words to where they are now."
            : "Choose the slide: a PDF (its first page) or a picture."
        panel.prompt = replacing ? "Replace" : "Choose"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { replacing ? session.replaceSlide(url, page: page) : session.importSlide(url) }
        }
    }

    @MainActor
    public static func chooseVoice(_ session: OOOSession) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = OOOSession.voiceTypes
        panel.message = "Choose your voiceover: any recording, M4A, MP3, WAV or AIFF."
        panel.prompt = "Choose"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { session.importVoice(url) }
        }
    }
}

extension OOOCommands {
    /// Saves the opening and every framing as full-size pictures in a new
    /// folder, for a carousel post or a deck.
    @MainActor
    public static func saveStills(_ session: OOOSession) {
        guard let scene = session.exportScene() else { session.message = session.notReady; return }
        let format = session.project.format
        session.clock.playing = false
        let panel = NSSavePanel()
        let name = session.project.slide.kind == .sample ? "OOO" : "OOO " + session.project.slide.name
        panel.nameFieldStringValue = name + " stills"
        panel.canCreateDirectories = true
        panel.message = String(format: "A folder of pictures, %d × %d: the opening, then each framing once the camera lands.",
                               format.width, format.height)
        panel.prompt = "Save Stills"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let job = MainActor.assumeIsolated { session.beginJob("Saving the stills") }
            Task.detached(priority: .userInitiated) {
                do {
                    let files = try Stills.write(scene, to: url, width: format.width, height: format.height)
                    await MainActor.run {
                        session.endJob(job)
                        NSWorkspace.shared.activateFileViewerSelecting(files.prefix(1).map { $0 })
                    }
                } catch {
                    await MainActor.run {
                        session.endJob(job)
                        session.message = "Couldn't save the stills: \(readable(error))"
                    }
                }
            }
        }
    }

    /// Saves the frame at the playhead as a full-size picture, for the
    /// post's cover or thumbnail.
    @MainActor
    public static func saveCoverFrame(_ session: OOOSession) {
        guard let scene = session.exportScene() else { session.message = session.notReady; return }
        let t = session.clock.time
        let format = session.project.format
        session.clock.playing = false
        let panel = NSSavePanel()
        let name = session.project.slide.kind == .sample ? "OOO" : "OOO " + session.project.slide.name
        panel.nameFieldStringValue = name + " cover.png"
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.message = String(format: "The frame at %.1f s, %d × %d, as the export draws it.", t, format.width, format.height)
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task.detached(priority: .userInitiated) {
                do {
                    // Its own renderer, so it never shares scratch space with the live stage.
                    let stage = try SlideStage()
                    let image = try stage.still(scene, at: t, width: format.width, height: format.height, samples: 16)
                    try ImageOutput.writePNG(image, to: url)
                } catch {
                    await MainActor.run { session.message = "Couldn't save the cover frame: \(readable(error))" }
                }
            }
        }
    }
}

public struct OOOMenuCommands: Commands {
    @FocusedValue(\.oooSession) private var session
    @AppStorage("appearance") private var appearance = AppearanceChoice.dark.rawValue
    @AppStorage("showSafeAreas") private var showSafeAreas = false
    @AppStorage("live.camera") private var liveCamera = true
    @AppStorage("showSlideMap") private var showSlideMap = true

    public init() {}

    /// A take under way: nothing may change the project under it.
    @MainActor private var taking: Bool { session?.isTaking ?? false }

    @MainActor private func canMoveShot(_ step: Int) -> Bool {
        guard let session, let id = session.selectedShot?.id else { return false }
        return session.canMoveShot(id, by: step)
    }

    public var body: some Commands {
        CommandGroup(after: .importExport) {
            Button("Choose Slide…") { if let session { OOOCommands.chooseSlide(session) } }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(session == nil || taking)
            Button("Choose Voiceover…") { if let session { OOOCommands.chooseVoice(session) } }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(session == nil || taking)
            Button((session?.recorder.isActive ?? false) ? "Stop Recording" : "Record Voiceover") { session?.toggleRecording() }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(session == nil || session?.hasSlide == false || session?.isLive == true)
            Divider()
            Button(session?.liveActionTitle ?? "Go Live") { session?.liveAction() }
                .keyboardShortcut("l", modifiers: [.command, .option])
                .disabled(session == nil || session?.hasSlide == false || session?.recorder.isActive == true)
            Button("Discard Take") { session?.discardTake() }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!taking || session?.liveKeeping == true)
            Toggle("Film Me in Live Takes", isOn: Binding(get: { liveCamera }, set: { on in
                if let session { session.setFilmMe(on) } else { liveCamera = on }
            }))
                .disabled(taking)
            Divider()
            Button("Add Slide…") { if let session { OOOCommands.addSlides(session) } }
                .keyboardShortcut("i", modifiers: [.command, .control])
                .disabled(session == nil || session?.hasSlide == false || taking)
            Button("Replace Slide…") { if let session { OOOCommands.chooseSlide(session, replacing: true) } }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(session == nil || session?.hasSlide == false || taking)
            Button("Paste Slide") { session?.pasteSlide() }
                .keyboardShortcut("v", modifiers: [.command, .shift])
                .disabled(session == nil || taking)
            Divider()
            Button("Export Video…") { session?.showExport = true }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(session == nil || taking)
            Button("Save Cover Frame…") { if let session { OOOCommands.saveCoverFrame(session) } }
                .keyboardShortcut("e", modifiers: [.command, .option])
                .disabled(session == nil || session?.hasSlide == false)
            Button("Save Stills…") { if let session { OOOCommands.saveStills(session) } }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(session == nil || session?.hasSlide == false)
        }
        CommandMenu("Camera") {
            Button((session?.pen.on ?? false) ? "Put the Pen Away" : "Draw on the Slide") { session?.togglePen() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(session == nil || session?.hasSlide == false)
            Divider()
            Button("Direct for Me") { session?.autoDirect() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(session == nil || session?.busy != nil || taking)
            Button("Cut Moves to Voice") { session?.cutToVoice() }
                .keyboardShortcut("v", modifiers: [.command, .option])
                .disabled(session?.project.voice?.words?.isEmpty ?? true || taking)
            Divider()
            Button("New Shot at Playhead") { session?.addShot() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(session == nil || taking)
            Button("New Framing From This View") { session?.addShotFromView() }
                .disabled(session == nil || session?.hasSlide == false || taking)
            Button("Duplicate Shot") { session?.duplicateSelectedShot() }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(session?.selectedShot == nil || taking)
            Button("Delete Shot") { session?.deleteSelectedShot() }
                .disabled(session?.selectedShot == nil || taking)
            Button("Move Shot Earlier") { if let id = session?.selectedShot?.id { session?.moveShot(id, by: -1) } }
                .disabled(!canMoveShot(-1) || taking)
            Button("Move Shot Later") { if let id = session?.selectedShot?.id { session?.moveShot(id, by: 1) } }
                .disabled(!canMoveShot(1) || taking)
            Divider()
            // Every drag on the map and the timeline has a key; a run of presses is one undo step.
            Button("Move Framing Left") { session?.nudgeFraming(-1, 0) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .disabled(session == nil)
            Button("Move Framing Right") { session?.nudgeFraming(1, 0) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled(session == nil)
            Button("Move Framing Up") { session?.nudgeFraming(0, -1) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(session == nil)
            Button("Move Framing Down") { session?.nudgeFraming(0, 1) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(session == nil)
            Button("Closer") { session?.nudgeZoom(closer: true) }
                .keyboardShortcut("=", modifiers: [.command, .option])
                .disabled(session == nil)
            Button("Wider") { session?.nudgeZoom(closer: false) }
                .keyboardShortcut("-", modifiers: [.command, .option])
                .disabled(session == nil)
            Button("Land Earlier") { session?.nudgeTime(-1) }
                .keyboardShortcut("[", modifiers: [.command, .option])
                .disabled(session?.selectedShot == nil)
            Button("Land Later") { session?.nudgeTime(1) }
                .keyboardShortcut("]", modifiers: [.command, .option])
                .disabled(session?.selectedShot == nil)
        }
        CommandMenu("Playback") {
            Button((session?.clock.playing ?? false) ? "Pause" : "Play") {
                session?.clock.playing.toggle()
                session?.touch()
            }
            .keyboardShortcut("p", modifiers: .command)
            Button("Go to Start") {
                session?.clock.time = 0
                session?.touch()
            }
            .keyboardShortcut(.leftArrow, modifiers: .command)
            // In a text field, ⌘← goes to the start of the line.
            .disabled(session?.clock.typing == true)
            Button("Previous Landing") { session?.jump(-1) }
                .keyboardShortcut("[", modifiers: .command)
            Button("Next Landing") { session?.jump(1) }
                .keyboardShortcut("]", modifiers: .command)
        }
        CommandGroup(before: .toolbar) {
            ForEach(EditorMode.allCases) { m in
                Toggle(m.title, isOn: Binding(get: { session?.mode == m }, set: { _ in session?.enter(m) }))
                    .keyboardShortcut(KeyEquivalent(m.key), modifiers: .command)
                    .disabled(!(session?.canEnter(m) ?? false))
            }
            Divider()
        }
        CommandGroup(after: .toolbar) {
            Button("Zoom In on the Timeline") { session?.zoomTimeline(by: 1.5) }
                .keyboardShortcut("=", modifiers: .command)
                .disabled(session == nil)
            Button("Zoom Out on the Timeline") { session?.zoomTimeline(by: 1 / 1.5) }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(session == nil || (session?.timelineZoom ?? 1) <= 1)
            Button("Fit the Timeline") { session?.timelineZoom = 1 }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(session == nil || (session?.timelineZoom ?? 1) <= 1)
            Divider()
            Picker("Appearance", selection: $appearance) {
                ForEach(AppearanceChoice.allCases) { c in Text(c.title).tag(c.rawValue) }
            }
            Toggle("Show Slide Map", isOn: $showSlideMap)
                .keyboardShortcut("m", modifiers: [.command, .shift])
            Toggle("Show Safe Areas", isOn: $showSafeAreas)
                .keyboardShortcut("g", modifiers: [.command, .shift])
        }
    }
}

// MARK: - Window

public struct OOORoot: View {
    @State private var session: OOOSession
    @Environment(\.undoManager) private var undoManager
    @AppStorage("appearance") private var appearance = AppearanceChoice.dark.rawValue

    public init(document: OOODocument) {
        _session = State(initialValue: OOOSession(document: document))
    }

    public var body: some View {
        OOOWindow(session: session)
            .onAppear {
                session.undoManager = undoManager
                session.start()
                if session.document.isNew {
                    session.document.isNew = false
                    session.clock.time = 0
                    session.clock.autoplay()
                }
            }
            .onDisappear { session.windowClosed() }
            .onChange(of: undoManager) { _, um in session.undoManager = um }
            .modifier(EditorKeys(session: session))
            .environment(session.clock)
            .modifier(SnapshotHost(session: session))
            .focusedSceneValue(\.oooSession, session)
            .preferredColorScheme(AppearanceChoice(rawValue: appearance)?.colorScheme)
    }
}

public struct OOOWindow: View {
    @Bindable var session: OOOSession
    @State private var showInspector = true
    @AppStorage("showSlideMap") private var showSlideMap = true

    public init(session: OOOSession) {
        self.session = session
    }

    public var body: some View {
        VStack(spacing: 0) {
            StageArea(session: session)
                .background(Theme.surround)
            TimelineView(session: session)
        }
        .inspector(isPresented: $showInspector) {
            InspectorPanel(session: session)
                .inspectorColumnWidth(min: 300, ideal: 330, max: 440)
        }
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { withAnimation(Theme.settle) { showSlideMap.toggle() } } label: {
                    Label("Slide Map", systemImage: "sidebar.left")
                }
                .help(showSlideMap ? "Keep the slide map in the inspector (⇧⌘M)" : "Show the slide map beside the video, when the window has room (⇧⌘M)")
            }
            ToolbarItem(placement: .navigation) {
                FormatPicker(current: session.project.format) { session.setFormat($0) }
                    .disabled(session.isTaking)
            }
            ToolbarItem(placement: .principal) {
                ModeSwitch(session: session)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                DirectButton(session: session)
                    .disabled(session.isTaking)
                Button { session.addShot() } label: {
                    Label("New Shot", systemImage: "plus.viewfinder")
                }
                .help("A new framing at the playhead (⇧⌘N)")
                .disabled(session.isTaking)
                Button { OOOCommands.chooseSlide(session) } label: {
                    Label("Slide", systemImage: "rectangle.on.rectangle.angled")
                }
                .help("Choose the slide: a PDF or a picture (⌘I). Or copy a slide in Keynote, Figma or Preview and paste it (⇧⌘V).")
                .disabled(session.isTaking)
                Button { OOOCommands.chooseVoice(session) } label: {
                    Label("Voiceover", systemImage: "waveform.badge.plus")
                }
                .help("Choose your voiceover (⌥⌘I)")
                .disabled(session.isTaking)
                Button { session.showExport = true } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "square.and.arrow.up").font(.system(size: 12, weight: .semibold))
                        Text("Export")
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .help("Export the video (⌘E)")
                .disabled(session.isTaking)
                Button { showInspector.toggle() } label: {
                    Label("Inspector", systemImage: "sidebar.right")
                }
                .help("Show or hide the inspector")
            }
        }
        .onDeleteCommand { if session.mode == .frame { session.deleteSelectedShot() } }
        .onAppear { if OOOSnapshot.hidesInspector { showInspector = false } }
        .sheet(isPresented: $session.showExport) {
            ExportSheet(session: session)
        }
        .alert("OOO", isPresented: Binding(get: { session.message != nil }, set: { if !$0 { session.message = nil } })) {
            Button("OK") { session.message = nil }
        } message: {
            Text(session.message ?? "")
        }
        .frame(minWidth: 960, minHeight: 640)
    }

    private var subtitle: String {
        let p = session.project
        return "\(p.format.width) × \(p.format.height) · \(p.fps) fps · \(secondsLabel(session.choreography.duration))"
    }
}

/// Keys that act mid-gesture or while held, which menus can't carry: Esc
/// cancels a drag, and holding \ shows the slide in the Original look.
/// Only this window's keys, while it is in front.
struct EditorKeys: ViewModifier {
    let session: OOOSession
    @State private var window = WindowBox()
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .background(WindowReader(box: window))
            .onAppear {
                guard monitor == nil else { return }
                let box = window, session = session
                monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
                    guard let w = box.window, event.window === w else { return event }
                    let used = MainActor.assumeIsolated { session.handleKey(event) }
                    return used ? nil : event
                }
            }
            .onDisappear {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
                session.stopComparing()
            }
    }
}

final class WindowBox {
    weak var window: NSWindow?
}

/// Notes which window a view is in.
struct WindowReader: NSViewRepresentable {
    let box: WindowBox
    func makeNSView(context: Context) -> NSView {
        let v = WindowTracker()
        v.box = box
        return v
    }
    func updateNSView(_ view: NSView, context: Context) {}

    final class WindowTracker: NSView {
        var box: WindowBox?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            box?.window = window
        }
    }
}

/// Plans a tour of the slide. It glows softly while the slide has no shots
/// (steadily, with Reduce Motion on).
struct DirectButton: View {
    @Bindable var session: OOOSession
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var glow: Bool { session.project.shots.isEmpty && session.hasSlide && session.busy == nil }

    var body: some View {
        Button { session.autoDirect() } label: {
            Label("Direct for Me", systemImage: "wand.and.stars")
                .labelStyle(.titleAndIcon)
        }
        .help("Read the slide and plan the camera's tour: the headline, the details worth a look, the small print last (⇧⌘D)")
        .disabled(session.busy != nil || !session.hasSlide)
        .shadow(color: Theme.camera.opacity(glow && pulse ? 0.8 : 0), radius: 6)
        // The pulse runs only while the glow shows; otherwise nothing animates.
        .onChange(of: glow, initial: true) { _, on in
            if on && reduceMotion {
                pulse = true
            } else if on {
                withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { pulse = true }
            } else {
                withTransaction(Transaction(animation: nil)) { pulse = false }
            }
        }
    }
}

/// The canvas shapes most videos go to, one click apart, with the rest in a menu.
public struct FormatPicker: View {
    let current: CanvasFormat
    let choose: (CanvasFormat) -> Void
    static let common: [CanvasFormat] = [.reel, .portrait, .square, .landscape]

    public init(current: CanvasFormat, choose: @escaping (CanvasFormat) -> Void) {
        self.current = current
        self.choose = choose
    }

    public var body: some View {
        HStack(spacing: 6) {
            Picker("Canvas", selection: Binding(
                get: { Self.common.contains(current) ? current.id : "" },
                set: { id in
                    if let f = Self.common.first(where: { $0.id == id }), f != current { choose(f) }
                })) {
                ForEach(Self.common) { f in
                    Text(f.ratioLabel).tag(f.id).help("\(f.name): \(f.detail)")
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Canvas shape")
            Menu {
                ForEach(CanvasFormat.presets) { f in
                    Button { if f != current { choose(f) } } label: {
                        Text("\(f.name)  \(f.ratioLabel)  ·  \(f.width) × \(f.height)  ·  \(f.detail)")
                    }
                }
            } label: {
                Image(systemName: "aspectratio")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help("All canvas shapes")
        }
    }
}

// MARK: - App bootstrap

public enum OOOLaunch {
    /// Call once from the app's `init()`.
    @MainActor
    public static func configure() {
        UserDefaults.standard.register(defaults: [
            "appearance": AppearanceChoice.dark.rawValue,
            // Open on a new window, already moving, rather than on the Open panel.
            "NSShowAppCentricOpenPanelInsteadOfUntitledFile": false,
        ])
        OOOSnapshot.configure()
        // Before 1.2.4 every copy shared one unlocked place: cleared only
        // when no other copy of OOO (a review or test copy too) is open.
        let others = NSWorkspace.shared.runningApplications.contains {
            $0.processIdentifier != getpid() && ($0.bundleIdentifier?.hasPrefix("dog.pitch.ooo") ?? false)
        }
        MediaStore.sweep(earlierToo: !others)
        DispatchQueue.global(qos: .utility).async {
            // Compile every shader before the first frame needs it.
            if let r = try? StageRenderer() { r.warmUp() }
        }
    }
}
