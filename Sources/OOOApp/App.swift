import OOOStudio
import SwiftUI
import Updates

/// OOO: Obsess Over One. One slide, one camera, all the love.
@main
struct ObsessOverOne: App {
    @StateObject private var updates: AppUpdates

    init() {
        OOOLaunch.configure()
        _updates = StateObject(wrappedValue: AppUpdates(start: true))
    }

    var body: some Scene {
        DocumentGroup(newDocument: { OOODocument() }) { file in
            OOORoot(document: file.document)
                // Revert hands over a new document object; the window follows it.
                .id(ObjectIdentifier(file.document))
        }
        .commands {
            OOOMenuCommands()
            CheckForUpdatesCommand(updates: updates)
        }
        .defaultSize(width: 1440, height: 900)
    }
}
