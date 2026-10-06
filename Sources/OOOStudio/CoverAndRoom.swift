import AppKit
import Foundation
import OOOCore
import OOOMotion
import SwiftUI
import UniformTypeIdentifiers

/// The cover the video opens on, and the room left for you below the stage.
extension OOOSession {
    // MARK: Cover

    /// Takes a picture or the first page of a PDF as the cover the video
    /// opens on before it turns over to the slide.
    public func chooseCover(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard var ref = SlideSource.inspect(url) else {
            message = "OOO can't read that file as a cover. Use a PDF or a picture: PNG, JPEG, HEIC or TIFF."
            return
        }
        do {
            ref.file = try document.media.importFile(url)
        } catch {
            message = "Couldn't copy the cover: \(error.localizedDescription)"
            return
        }
        setCover(ref)
    }

    /// A page of the slide's own PDF as the cover: usually the deck's first.
    public func useSlidePageAsCover(_ page: Int = 0) {
        guard project.slide.kind == .pdf, let file = project.slide.file,
              var ref = SlideSource.inspect(document.media.url(for: file), page: page) else { return }
        ref.file = file
        ref.name = "Page \(page + 1) of \(project.slide.name)"
        setCover(ref)
    }

    /// Whether the slide's PDF has a first page to use as its cover.
    public var canUseFirstPageAsCover: Bool {
        project.slide.kind == .pdf && project.slide.page > 0 && project.cover?.slide.file != project.slide.file
    }

    private func setCover(_ ref: SlideRef) {
        update(project.cover == nil ? "Add Cover" : "Change Cover") { p in
            if var c = p.cover {
                c.slide = ref
                p.cover = c
            } else {
                p.cover = Cover(slide: ref, turn: p.defaultCoverTurn)
            }
            p.makeRoomForOpening()
        }
        select(.overview, show: false)
        watchTheTurn()
    }

    public func removeCover() {
        update("Remove Cover") { $0.cover = nil }
    }

    /// Plays from a moment before the cover turns over.
    public func watchTheTurn() {
        guard let turn = choreography.turns.first else { return }
        clock.playing = false
        clock.time = max(turn.start - 1.2, 0)
        clock.playing = true
    }

    /// When the cover turns over, or (`back`) starts to turn back, during a
    /// drag on the timeline. Turning over later moves the tour along with it.
    public func liveTurn(back: Bool, to t: Double) {
        live { p in
            guard var c = p.cover else { return }
            if back {
                c.backAt = max(t, p.arrive.end + 1)
            } else {
                c.turn = max(t, p.arrive.end + 0.3)
            }
            p.cover = c
            if !back { p.makeRoomForOpening() }
        }
    }

    // MARK: Room for you

    /// Lifts the stage for a stretch from `t` (the playhead), or for the
    /// whole video, leaving the bottom of the frame clear for you.
    public func addRoom(at t: Double? = nil, whole: Bool = false) {
        let d = choreography.duration
        let span: LiftSpan
        if whole {
            span = LiftSpan(start: 0, end: nil)
        } else {
            let start = min(max(t ?? clock.time, 0), max(d - Lift.shortest, 0))
            // A stretch of about six seconds, or to the end when that is near.
            span = LiftSpan(start: start, end: start + 6 >= d - 1.5 ? nil : start + 6)
        }
        update(whole ? "Room for You" : "Add Room for You") { p in
            var lift = p.lift ?? Lift()
            if whole { lift.spans = [span] } else { lift.spans.append(span) }
            p.lift = lift
        }
        showRoom = true
    }

    /// Changes one stretch during a drag on the timeline.
    public func liveRoom(_ id: UUID, _ change: (inout LiftSpan) -> Void) {
        live { p in
            guard var lift = p.lift, let i = lift.spans.firstIndex(where: { $0.id == id }) else { return }
            change(&lift.spans[i])
            p.lift = lift
        }
    }

    public func removeRoom(_ id: UUID) {
        update("Remove Room for You") { p in p.lift?.spans.removeAll { $0.id == id } }
    }

    public func removeAllRoom() {
        update("Remove Room for You") { p in p.lift?.spans.removeAll() }
    }

    /// The share of the frame left clear for you.
    public var roomBinding: Binding<Float> {
        Binding(get: { self.project.lift?.room ?? Lift.defaultRoom },
                set: { v in self.live { p in
                    var lift = p.lift ?? Lift()
                    lift.room = v
                    p.lift = lift
                } })
    }
}

extension OOOCommands {
    /// Chooses the cover the video opens on.
    @MainActor
    public static func chooseCover(_ session: OOOSession) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = OOOSession.slideTypes
        panel.message = "Choose the cover: a PDF (its first page) or a picture. The video opens on it, then turns it over to your slide."
        panel.prompt = "Choose"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { session.chooseCover(url) }
        }
    }
}
