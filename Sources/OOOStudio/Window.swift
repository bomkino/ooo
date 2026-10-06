import AppKit
import OOOCore
import OOOMotion
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
    @MainActor
    public static func chooseSlide(_ session: OOOSession) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = OOOSession.slideTypes
        panel.message = "Choose the slide: a PDF (its first page) or a picture."
        panel.prompt = "Choose"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { session.importSlide(url) }
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

public struct OOOMenuCommands: Commands {
    @FocusedValue(\.oooSession) private var session
    @AppStorage("appearance") private var appearance = AppearanceChoice.dark.rawValue
    @AppStorage("showSafeAreas") private var showSafeAreas = false

    public init() {}

    public var body: some Commands {
        CommandGroup(after: .importExport) {
            Button("Choose Slide…") { if let session { OOOCommands.chooseSlide(session) } }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(session == nil)
            Button("Choose Voiceover…") { if let session { OOOCommands.chooseVoice(session) } }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(session == nil)
            Divider()
            Button("Export Video…") { session?.showExport = true }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(session == nil)
        }
        CommandMenu("Camera") {
            Button("Direct for Me") { session?.autoDirect() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(session == nil || session?.busy != nil)
            Button("Cut Moves to Voice") { session?.cutToVoice() }
                .keyboardShortcut("v", modifiers: [.command, .option])
                .disabled(session?.project.voice?.words?.isEmpty ?? true)
            Divider()
            Button("New Shot at Playhead") { session?.addShot() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(session == nil)
            Button("Duplicate Shot") { session?.duplicateSelectedShot() }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(session?.selectedShot == nil)
            Button("Delete Shot") { session?.deleteSelectedShot() }
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
            Button("Previous Landing") { session?.jump(-1) }
                .keyboardShortcut("[", modifiers: .command)
            Button("Next Landing") { session?.jump(1) }
                .keyboardShortcut("]", modifiers: .command)
        }
        CommandGroup(after: .toolbar) {
            Picker("Appearance", selection: $appearance) {
                ForEach(AppearanceChoice.allCases) { c in Text(c.title).tag(c.rawValue) }
            }
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
                    session.clock.playing = true
                }
            }
            .onChange(of: undoManager) { _, um in session.undoManager = um }
            .focusedSceneValue(\.oooSession, session)
            .preferredColorScheme(AppearanceChoice(rawValue: appearance)?.colorScheme)
    }
}

public struct OOOWindow: View {
    @Bindable var session: OOOSession
    @State private var showInspector = true

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
                FormatPicker(current: session.project.format) { session.setFormat($0) }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                DirectButton(session: session)
                Button { session.addShot() } label: {
                    Label("New Shot", systemImage: "plus.viewfinder")
                }
                .help("A new framing at the playhead (⇧⌘N)")
                Button { OOOCommands.chooseSlide(session) } label: {
                    Label("Slide", systemImage: "rectangle.on.rectangle.angled")
                }
                .help("Choose the slide: a PDF or a picture (⌘I)")
                Button { OOOCommands.chooseVoice(session) } label: {
                    Label("Voiceover", systemImage: "waveform.badge.plus")
                }
                .help("Choose your voiceover (⌥⌘I)")
                Button { session.showExport = true } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "square.and.arrow.up").font(.system(size: 12, weight: .semibold))
                        Text("Export")
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .help("Export the video (⌘E)")
                Button { showInspector.toggle() } label: {
                    Label("Inspector", systemImage: "sidebar.right")
                }
                .help("Show or hide the inspector")
            }
        }
        .onDeleteCommand { session.deleteSelectedShot() }
        .sheet(isPresented: $session.showExport) {
            ExportSheet(session: session)
        }
        .alert("OOO", isPresented: Binding(get: { session.message != nil }, set: { if !$0 { session.message = nil } })) {
            Button("OK") { session.message = nil }
        } message: {
            Text(session.message ?? "")
        }
        .frame(minWidth: 1080, minHeight: 700)
    }

    private var subtitle: String {
        let p = session.project
        return "\(p.format.width) × \(p.format.height) · \(p.fps) fps · \(secondsLabel(session.choreography.duration))"
    }
}

/// Plans a tour of the slide. It glows softly while the slide has no shots.
struct DirectButton: View {
    @Bindable var session: OOOSession
    @State private var pulse = false

    private var glow: Bool { session.project.shots.isEmpty && session.hasSlide && session.busy == nil }

    var body: some View {
        Button { session.autoDirect() } label: {
            Label("Direct for Me", systemImage: "wand.and.stars")
        }
        .help("Read the slide and plan the camera's tour: the headline, the details worth a look, the small print last (⇧⌘D)")
        .disabled(session.busy != nil || !session.hasSlide)
        .shadow(color: Theme.camera.opacity(glow && pulse ? 0.8 : 0), radius: 6)
        // The pulse runs only while the glow shows; otherwise nothing animates.
        .onChange(of: glow, initial: true) { _, on in
            if on {
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
        DispatchQueue.global(qos: .utility).async {
            // Compile every shader before the first frame needs it.
            if let r = try? StageRenderer() { r.warmUp() }
        }
    }
}
