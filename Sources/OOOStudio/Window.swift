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
                .disabled(session == nil || session?.hasSlide == false || taking)
            Button("Save Stills…") { if let session { OOOCommands.saveStills(session) } }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(session == nil || session?.hasSlide == false || taking)
        }
        CommandGroup(replacing: .appInfo) {
            Button("About Obsess Over One") { OOOAbout.show() }
        }
        CommandMenu("Camera") {
            Button((session?.pen.on ?? false) ? "Put the Pen Away" : "Draw on the Slide") { session?.togglePen() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(session == nil || session?.hasSlide == false)
            Divider()
            Button("Direct for Me") { session?.autoDirect() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(session == nil || session?.busy != nil || taking)
            Button("Time Moves to My Voice") { session?.cutToVoice() }
                .keyboardShortcut("v", modifiers: [.command, .option])
                .disabled(session?.project.voice?.words?.isEmpty ?? true || taking)
            Divider()
            Button("New Framing at Playhead") { session?.addShot() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(session == nil || taking)
            Button("New Framing From This View") { session?.addShotFromView() }
                .disabled(session == nil || session?.hasSlide == false || taking)
            Button("Duplicate Framing") { session?.duplicateSelectedShot() }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(session?.selectedShot == nil || taking)
            Button("Delete Framing") { session?.deleteSelectedShot() }
                .disabled(session?.selectedShot == nil || taking)
            Button("Move Framing Earlier") { if let id = session?.selectedShot?.id { session?.moveShot(id, by: -1) } }
                .disabled(!canMoveShot(-1) || taking)
            Button("Move Framing Later") { if let id = session?.selectedShot?.id { session?.moveShot(id, by: 1) } }
                .disabled(!canMoveShot(1) || taking)
            Divider()
            // Every drag on the map and the timeline has a key; a run of presses is one undo step.
            Button("Move Framing Left") { session?.nudgeFraming(-1, 0) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .disabled(session == nil || taking)
            Button("Move Framing Right") { session?.nudgeFraming(1, 0) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled(session == nil || taking)
            Button("Move Framing Up") { session?.nudgeFraming(0, -1) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(session == nil || taking)
            Button("Move Framing Down") { session?.nudgeFraming(0, 1) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(session == nil || taking)
            Button("Closer") { session?.nudgeZoom(closer: true) }
                .keyboardShortcut("=", modifiers: [.command, .option])
                .disabled(session == nil || taking)
            Button("Wider") { session?.nudgeZoom(closer: false) }
                .keyboardShortcut("-", modifiers: [.command, .option])
                .disabled(session == nil || taking)
            Button("Land Earlier") { session?.nudgeTime(-1) }
                .keyboardShortcut("[", modifiers: [.command, .option])
                .disabled(session?.selectedShot == nil || taking)
            Button("Land Later") { session?.nudgeTime(1) }
                .keyboardShortcut("]", modifiers: [.command, .option])
                .disabled(session?.selectedShot == nil || taking)
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
    /// What a drag over the window would do, in words, while one is over it.
    @State private var dropping: String?

    public init(session: OOOSession) {
        self.session = session
    }

    public var body: some View {
        VStack(spacing: 0) {
            StageArea(session: session)
                .background(Theme.surround)
            TimelineView(session: session)
        }
        // A slide or a recording dropped anywhere in the window.
        .onDrop(of: [.fileURL], delegate: WindowDrop(session: session, words: $dropping))
        .overlay { if let dropping { DropLabel(words: dropping) } }
        .inspector(isPresented: $showInspector) {
            InspectorPanel(session: session)
                .inspectorColumnWidth(min: 300, ideal: 330, max: 440)
        }
        .navigationSubtitle(subtitle)
        // Few enough to fit the narrowest window: the shape, the modes, and
        // the way out (Export) always in view. The rest is in the menus and
        // right where you work.
        .toolbar {
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
                ExportButton(session: session)
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
        .alert(alert.title, isPresented: Binding(get: { session.message != nil }, set: { if !$0 { session.message = nil } })) {
            Button("OK") { session.message = nil }
        } message: {
            Text(alert.body)
        }
        .frame(minWidth: 960, minHeight: 640)
    }

    /// The video's shape and length, as people say them.
    private var subtitle: String {
        "\(session.project.format.name) · \(secondsLabel(session.choreography.duration))"
    }

    /// A notice titled by what happened: "Couldn't read the recording", then why.
    private var alert: (title: String, body: String) {
        let m = session.message ?? ""
        if m.hasPrefix("Couldn't "), let colon = m.range(of: ": ") {
            return (String(m[..<colon.lowerBound]), String(m[colon.upperBound...]))
        }
        return ("OOO", m)
    }
}

/// Takes a slide or a recording dropped anywhere in the window, and says
/// what it will do while it is held over it.
struct WindowDrop: DropDelegate {
    let session: OOOSession
    @Binding var words: String?

    func validateDrop(info: DropInfo) -> Bool {
        !session.isTaking && info.hasItemsConforming(to: [.fileURL])
    }

    func dropEntered(info: DropInfo) {
        guard validateDrop(info: info) else { return }
        withAnimation(Theme.quick) { words = Self.words(info.itemProviders(for: [.fileURL]), sample: session.project.slide.kind == .sample) }
    }

    func dropExited(info: DropInfo) {
        withAnimation(Theme.quick) { words = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        words = nil
        guard !session.isTaking else { return false }
        let session = session
        loadDropped(info.itemProviders(for: [.fileURL])) { session.importDropped($0) }
        return true
    }

    /// What the drop will do, from what is held: a recording, a slide, or several.
    static func words(_ items: [NSItemProvider], sample: Bool) -> String {
        let sounds = items.filter { $0.hasItemConformingToTypeIdentifier(UTType.audio.identifier) }.count
        let slides = items.count - sounds
        if slides == 0 && sounds > 0 { return "Drop to make it your voiceover" }
        if slides > 1 { return "Drop \(slides) slides to make one video of them" }
        return sample ? "Drop to make it your slide" : "Drop to make it the slide"
    }
}

/// Over the window while a file is held over it: what letting go will do.
struct DropLabel: View {
    let words: String

    var body: some View {
        ZStack {
            Color.black.opacity(0.32)
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Theme.camera, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .padding(14)
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill").font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.camera)
                Text(words).textStyle(.title).foregroundStyle(.primary)
            }
            .padding(.horizontal, 22)
            .frame(height: 52)
            .background(Capsule().fill(Theme.raised))
            .shadow(color: .black.opacity(0.3), radius: 18, y: 6)
        }
        .allowsHitTesting(false)
        .transition(.opacity)
    }
}

/// Export, in the toolbar, always in view. It glows softly once the video
/// is ready to post and hasn't been exported as it is.
struct ExportButton: View {
    @Bindable var session: OOOSession

    var body: some View {
        Button { session.showExport = true } label: {
            HStack(spacing: 6) {
                Image(systemName: "square.and.arrow.up").font(.system(size: 12, weight: .semibold))
                Text("Export")
            }
        }
        .buttonStyle(PrimaryButtonStyle())
        .help("Export the video (⌘E)")
        .disabled(session.isTaking)
        .modifier(Glow(on: session.readyToPost && !session.isTaking))
    }
}

/// A soft ember glow that breathes while `on` (steadily, with Reduce Motion
/// on); nothing animates while it is off.
struct Glow: ViewModifier {
    let on: Bool
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .shadow(color: Theme.camera.opacity(on && pulse ? 0.8 : 0), radius: 6)
            .onChange(of: on, initial: true) { _, on in
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

/// Plans a tour of the slide. It glows softly while the slide has no shots.
/// Once you have set a shot yourself it plans again only when you say so.
struct DirectButton: View {
    @Bindable var session: OOOSession
    @State private var asking = false

    private var glow: Bool { session.project.shots.isEmpty && session.hasSlide && session.busy == nil }
    /// Shots you set by hand, which a new plan would replace.
    private var yours: Int { session.project.shots.filter { !$0.isPlanned }.count }

    var body: some View {
        Button { if yours > 0 { asking = true } else { session.autoDirect() } } label: {
            Label(yours > 0 ? "Plan Again" : "Direct for Me", systemImage: "wand.and.stars")
                .labelStyle(.titleAndIcon)
        }
        .help("Read the slide and plan the camera's tour: the headline, the details worth a look, the small print last (⇧⌘D)")
        .disabled(session.busy != nil || !session.hasSlide)
        .modifier(Glow(on: glow))
        .confirmationDialog("Plan the tour again?", isPresented: $asking) {
            Button("Plan Again") { session.autoDirect() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("OOO plans every framing afresh, and the \(yours == 1 ? "framing" : "\(yours) framings") you set yourself \(yours == 1 ? "is" : "are") replaced. ⌘Z brings \(yours == 1 ? "it" : "them") back.")
        }
    }
}

/// The video's shape, named, in one menu: the four most posts go to, then 4K.
public struct FormatPicker: View {
    let current: CanvasFormat
    let choose: (CanvasFormat) -> Void
    static let common: [CanvasFormat] = [.reel, .portrait, .square, .landscape]

    public init(current: CanvasFormat, choose: @escaping (CanvasFormat) -> Void) {
        self.current = current
        self.choose = choose
    }

    public var body: some View {
        Menu {
            Picker("Shape", selection: Binding(
                get: { current.id },
                set: { id in
                    if let f = CanvasFormat.presets.first(where: { $0.id == id }), f != current { choose(f) }
                })) {
                ForEach(CanvasFormat.presets) { f in
                    Text("\(f.ratioLabel)  \(f.name)  ·  \(f.detail)").tag(f.id)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "aspectratio").font(.system(size: 11.5, weight: .semibold))
                Text("\(current.ratioLabel) \(current.name)").font(.system(size: 12.5, weight: .semibold))
            }
        }
        .menuIndicator(.visible)
        .fixedSize()
        .help("The video's shape: \(current.name), \(current.width) × \(current.height), for \(current.detail)")
    }
}

// MARK: - App bootstrap

/// The About panel: the name, what it means, and where it comes from.
@MainActor
enum OOOAbout {
    static func show() {
        let body = NSMutableAttributedString()
        let centred = NSMutableParagraphStyle()
        centred.alignment = .center
        centred.paragraphSpacing = 4
        func line(_ s: String, _ font: NSFont, _ colour: NSColor = .labelColor, link: URL? = nil) {
            var a: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: colour, .paragraphStyle: centred]
            if let link { a[.link] = link }
            body.append(NSAttributedString(string: s + "\n", attributes: a))
        }
        line("Every slide. Every detail.", .systemFont(ofSize: 12, weight: .semibold))
        line("Made with love by pitch.dog.", .systemFont(ofSize: 11), .secondaryLabelColor)
        line("Free and open source, under the AGPL 3.0.", .systemFont(ofSize: 11), .secondaryLabelColor)
        line("github.com/bomkino/ooo", .systemFont(ofSize: 11), .linkColor, link: URL(string: "https://github.com/bomkino/ooo"))
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Obsess Over One",
            .credits: body,
        ])
    }
}

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
        DispatchQueue.global(qos: .userInitiated).async {
            // The shared stage, built off main before the first frame asks for it;
            // then every shader, what the first frame needs before every look's.
            _ = OOOShared.stage
            if let r = try? StageRenderer() { r.warmUp() }
        }
    }
}
