import OOOStudio
import SwiftUI

/// OOO: Obsess Over One. One slide, one camera, all the love.
@main
struct ObsessOverOne: App {
    init() {
        OOOLaunch.configure()
    }

    var body: some Scene {
        DocumentGroup(newDocument: { OOODocument() }) { file in
            OOORoot(document: file.document)
                // Revert hands over a new document object; the window follows it.
                .id(ObjectIdentifier(file.document))
        }
        .commands { OOOMenuCommands() }
        .defaultSize(width: 1440, height: 900)
    }
}
