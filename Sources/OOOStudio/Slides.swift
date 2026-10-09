import AppKit
import Foundation
import OOOCore
import OOOMotion
import SwiftUI
import UniformTypeIdentifiers

/// A video over several slides: one card in your hand, turning over to the
/// next slide or letting it melt in where you are looking.
extension OOOSession {
    /// Copies slide files in the way a drop or a panel gives them (a PDF's first page).
    private func slideRefs(_ urls: [URL]) -> [SlideRef] {
        var refs: [SlideRef] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard var ref = SlideSource.inspect(url) else {
                message = "OOO can't read \(url.lastPathComponent) as a slide. Use a PDF or a picture: PNG, JPEG, HEIC or TIFF."
                continue
            }
            do {
                ref.file = try document.media.importFile(url)
            } catch {
                message = "Couldn't copy \(url.lastPathComponent): \(error.localizedDescription)"
                continue
            }
            refs.append(ref)
        }
        return refs
    }

    /// Slides after the last, in name order, each with a tour of its own.
    public func addSlides(_ urls: [URL]) {
        let sorted = urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        let pages = slideRefs(sorted).map { Page(slide: $0) }
        guard !pages.isEmpty else { return }
        drop(pages.count > 1 ? "Add Slides" : "Add Slide") { p in p.pages = p.morePages + pages }
        autoDirect(adding: Set(pages.map(\.id)))
    }

    /// Several slides dropped at once: the first opens the video and the
    /// rest follow it, in name order, and the whole video gets a new tour.
    public func importSlides(_ urls: [URL]) {
        let sorted = urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        let refs = slideRefs(sorted)
        guard let first = refs.first else { return }
        drop("New Slides") { p in
            let (A, C) = (p.slideAspect, p.canvasAspect)
            p.slide = first
            p.reading = nil
            p.pages = refs.count > 1 ? refs.dropFirst().map { Page(slide: $0) } : nil
            p.shots = []
            p.marks = nil
            p.adaptOverview(fromSlideAspect: A, canvasAspect: C)
        }
        selection = .overview
        clock.time = 0
        clock.playing = false
        autoDirect()
    }

    /// The next page of the last slide's PDF, as the next slide.
    public func addNextPage() {
        let last = project.slide(project.slideCount - 1)
        guard last.kind == .pdf, let file = last.file else { return }
        let url = document.media.url(for: file)
        guard last.page + 1 < SlideSource.pageCount(url), var ref = SlideSource.inspect(url, page: last.page + 1) else {
            message = "That was the last page of \(last.name)."
            return
        }
        ref.file = file
        ref.name = last.name
        let page = Page(slide: ref)
        drop("Add Next Page") { p in p.pages = p.morePages + [page] }
        autoDirect(adding: [page.id])
    }

    /// Takes slide `k` out of the video, with its framings and marks.
    public func removeSlide(_ k: Int) {
        guard project.slideCount > 1, k < project.slideCount else { return }
        update("Remove Slide") { p in
            // The first slide goes by stepping aside for the second first.
            if k == 0 { p.moveSlide(0, to: 1) }
            guard let id = p.pageID(k == 0 ? 1 : k) else { return }
            p.pages?.removeAll { $0.id == id }
            p.shots.removeAll { $0.page == id }
            p.marks?.removeAll { $0.page == id }
            if p.pages?.isEmpty == true { p.pages = nil }
            if p.marks?.isEmpty == true { p.marks = nil }
        }
    }

    /// Moves slide `k` to place `j` (0 is the first); each keeps its tour.
    public func moveSlide(_ k: Int, to j: Int) {
        update("Move Slide") { $0.moveSlide(k, to: j) }
    }

    /// How the card changes to slide `k`. A melt holds still on whatever
    /// the two slides share, so the tour is planned again around it unless
    /// you have set framings of your own.
    public func setChange(_ k: Int, _ change: PageChange) {
        guard k > 0, k <= project.morePages.count, project.morePages[k - 1].change != change else { return }
        update(change == .melt ? "Melt" : "Turn Over") { p in
            guard var pages = p.pages else { return }
            pages[k - 1].change = change
            p.pages = pages
        }
        autoDirect(adding: [])
    }

    /// Turns back to the first slide before the end, or stays on the last.
    public func setHome(_ on: Bool) {
        update(on ? "Turn Back" : "Don't Turn Back") { $0.home = on ? HomeTiming() : nil }
    }

    /// When a change starts, during a drag on the timeline, from where it
    /// was at the last step of the drag; returns where it is now. A slide
    /// coming in later takes everything after it along.
    public func liveChange(_ change: SlideChange, from was: Double, to t: Double) -> Double {
        var now = was
        live { p in
            if change.back {
                now = max(t, p.arrive.end + 1)
                p.home = HomeTiming(at: now)
            } else if let id = p.pageID(change.to) {
                now = p.moveChange(id, to: t, from: was)
            }
        }
        return now
    }

    /// Plays from a moment before slide `k` comes in.
    public func watchSlide(_ k: Int) {
        clock.playing = false
        if k == 0 {
            clock.time = 0
        } else if let c = choreography.changes.first(where: { $0.to == k && !$0.back }) {
            clock.time = max(c.start - 1.2, 0)
        }
        clock.playing = true
    }
}

extension OOOCommands {
    /// Chooses slides to go on to after the last.
    @MainActor
    public static func addSlides(_ session: OOOSession) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = OOOSession.slideTypes
        panel.message = "Choose the slides to go on to: PDFs (their first page) or pictures, in the order of their names."
        panel.prompt = "Add"
        panel.begin { response in
            guard response == .OK, !panel.urls.isEmpty else { return }
            let urls = panel.urls
            MainActor.assumeIsolated { session.addSlides(urls) }
        }
    }
}

// MARK: - Inspector

/// The slides the video goes through, in order: add, reorder, choose how
/// the card changes to each, and whether it turns back at the end.
struct SlidesSection: View {
    @Bindable var session: OOOSession

    var body: some View {
        let p = session.project
        InspectorSection("Slides", accessory: {
            if p.slideCount > 1 {
                Button("Watch") { session.watchSlide(1) }
                    .buttonStyle(QuietButtonStyle())
                    .help("Play from a moment before the first change")
            }
        }) {
            VStack(spacing: 4) {
                ForEach(0..<p.slideCount, id: \.self) { k in
                    SlideRow(session: session, k: k)
                }
            }
            HStack(spacing: 4) {
                Button("Add Slide…") { OOOCommands.addSlides(session) }
                    .help("Go on to more slides after this one: the card turns over to each")
                if p.slide(p.slideCount - 1).kind == .pdf {
                    Button("Add Next Page") { session.addNextPage() }
                        .help("The next page of the last slide's PDF")
                }
                Spacer(minLength: 0)
            }
            .buttonStyle(QuietButtonStyle())
            if p.slideCount > 1 {
                Toggle("Turn back to the first slide at the end", isOn: Binding(
                    get: { session.project.home != nil },
                    set: { session.setHome($0) }))
                    .toggleStyle(.checkbox)
                    .textStyle(.bodyCompact)
                Text("The card turns over in your hand to the next slide, or the next melts in where you're looking and whatever both slides share holds still. Drag a change on the timeline to time it to your words.")
                    .textStyle(.caption).foregroundStyle(.secondary)
            } else {
                Text("Go on to more slides with the same card in your hand: open on your deck's cover and turn it over to this one, or follow a number from one slide to the next.")
                    .textStyle(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// One slide in the list: its picture, its name, and how the card changes to it.
struct SlideRow: View {
    @Bindable var session: OOOSession
    let k: Int
    @State private var hover = false

    var body: some View {
        let p = session.project
        let ref = p.slide(k)
        HStack(spacing: 8) {
            Text("\(k + 1)").textStyle(.badge).foregroundStyle(.secondary).frame(width: 14)
            Group {
                if let img = session.preview(k) {
                    Image(decorative: img, scale: 1).resizable().interpolation(.medium).aspectRatio(contentMode: .fit)
                } else {
                    ProgressView().controlSize(.mini)
                }
            }
            .frame(width: 58, height: 34)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Theme.well.opacity(0.6)))
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(ref.kind == .pdf ? "\(ref.name), page \(ref.page + 1)" : ref.name)
                    .textStyle(.bodyCompact).lineLimit(1).truncationMode(.middle)
                if k > 0 {
                    Picker("Change", selection: Binding(
                        get: { session.project.morePages[min(k, session.project.morePages.count) - 1].change },
                        set: { session.setChange(k, $0) })) {
                        ForEach(PageChange.allCases) { c in Text(c.title).tag(c) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.mini)
                    .fixedSize()
                    .help("Turn: \(PageChange.turn.summary) Melt: \(PageChange.melt.summary)")
                } else {
                    Text(p.slideCount > 1 ? "Opens the video" : "The slide").textStyle(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Menu {
                Button("Watch") { session.watchSlide(k) }
                Divider()
                Button("Move Up") { session.moveSlide(k, to: k - 1) }.disabled(k == 0)
                Button("Move Down") { session.moveSlide(k, to: k + 1) }.disabled(k >= p.slideCount - 1)
                Button("Replace…") { OOOCommands.chooseSlide(session, replacing: true, page: k) }
                Divider()
                Button("Remove", role: .destructive) { session.removeSlide(k) }.disabled(p.slideCount < 2)
            } label: {
                Image(systemName: "ellipsis.circle").foregroundStyle(hover ? .primary : .tertiary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Watch, move, replace or remove this slide")
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hover ? Theme.raised.opacity(0.6) : Color.clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(count: 2) { session.watchSlide(k) }
    }
}

// MARK: - Timeline

/// The card changing slide on the camera lane: drag it to time it, click to watch it.
struct ChangeMarker: View {
    @Bindable var session: OOOSession
    let change: SlideChange
    let scale: TimeScale
    @State private var dragStart: Double?
    @State private var last: Double?
    @State private var hover = false

    var body: some View {
        let w = max(scale.x(change.end) - scale.x(change.start), 14)
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 9, weight: .bold))
            if w > 58 { Text(label).textStyle(.badge) }
        }
        .foregroundStyle(Theme.onAccent)
        .frame(width: w, height: 16)
        .background(Capsule().fill(Theme.camera.opacity(hover || dragStart != nil ? 1 : 0.85)))
        .contentShape(Capsule())
        .onHover { hover = $0 }
        .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { g in
                if dragStart == nil {
                    dragStart = change.start
                    last = change.start
                    session.holdTimeline(true)
                    session.beginEdit("Move Change")
                }
                let t = (dragStart ?? change.start) + Double(g.translation.width / scale.pointsPerSecond)
                last = session.liveChange(change, from: last ?? change.start, to: t)
            }
            .onEnded { _ in
                dragStart = nil
                last = nil
                session.commitEdit("Move Change")
                session.holdTimeline(false)
            })
        .simultaneousGesture(TapGesture().onEnded {
            session.clock.playing = false
            session.clock.time = max(change.start - 1.2, 0)
            session.clock.playing = true
        })
        .help(help)
    }

    private var icon: String {
        change.kind == .melt ? "drop.fill" : (change.back ? "arrow.uturn.left" : "arrow.uturn.right")
    }

    private var label: String {
        change.kind == .melt ? "Melt" : (change.back ? "Back" : "Turn")
    }

    private var help: String {
        if change.back { return "The card turns back to the first slide. Drag to time it; click to watch." }
        let what = change.kind == .melt ? "Slide \(change.to + 1) melts in" : "The card turns over to slide \(change.to + 1)"
        return what + ". Drag to time it (the slides after it move along); click to watch."
    }
}
