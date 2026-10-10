import Foundation
import OOOCore
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// An OOO document: a package holding project.json and the slides, voiceover and camera recording.
    public static let oooProject = UTType(exportedAs: ProjectPackage.typeIdentifier, conformingTo: .package)
}

/// Where a window keeps its slide and voiceover while editing. The package's
/// own copies are reused when saving, so this only ever holds what was added.
public final class MediaStore: @unchecked Sendable {
    public let directory: URL
    /// Held, locked, for as long as the window is open: a folder whose lock
    /// can be taken belongs to no one any more.
    private let owner: Int32

    /// Every window's own folder sits in here, apart for each copy of OOO:
    /// a review or test copy under another identifier never touches these.
    static let sessions = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(Bundle.main.bundleIdentifier ?? "dog.pitch.ooo.unbundled", isDirectory: true)
        .appendingPathComponent("Sessions", isDirectory: true)

    /// Where 1.2.3 and earlier kept them, shared by every copy and unlocked.
    static let earlier = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("OOO", isDirectory: true)
        .appendingPathComponent("Sessions", isDirectory: true)

    private static let lockName = ".owner"

    public init() {
        let base = Self.sessions.appendingPathComponent(UUID().uuidString, isDirectory: true)
        directory = base
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        owner = open(base.appendingPathComponent(Self.lockName).path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        if owner >= 0 { _ = flock(owner, LOCK_EX | LOCK_NB) }
    }

    /// Clears what earlier runs left behind: a window's folder goes when the
    /// window closes, but not when OOO quits or stops unexpectedly, and a
    /// camera recording can be big. Only folders no open window holds go,
    /// so another OOO open at the same time keeps its own. `earlierToo`
    /// clears the old shared place as well, for when no other OOO is open.
    static func sweep(earlierToo: Bool) {
        let fm = FileManager.default
        let mine = (try? fm.contentsOfDirectory(at: sessions, includingPropertiesForKeys: [.creationDateKey])) ?? []
        var gone = mine.filter(unheld)
        if earlierToo { gone += (try? fm.contentsOfDirectory(at: earlier, includingPropertiesForKeys: nil)) ?? [] }
        guard !gone.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async {
            for url in gone { try? FileManager.default.removeItem(at: url) }
        }
    }

    /// True when no window holds `folder`. One whose lock isn't there yet may
    /// be a window opening this instant, so it waits a minute.
    private static func unheld(_ folder: URL) -> Bool {
        let fd = open(folder.appendingPathComponent(lockName).path, O_RDWR | O_CLOEXEC)
        guard fd >= 0 else {
            let made = (try? folder.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            return made.timeIntervalSinceNow < -60
        }
        defer { close(fd) }
        return flock(fd, LOCK_EX | LOCK_NB) == 0
    }

    public func url(for file: String) -> URL { directory.appendingPathComponent(file) }

    public func contains(_ file: String) -> Bool { FileManager.default.fileExists(atPath: url(for: file).path) }

    /// Copies an original in; returns its stored name, which never changes its contents.
    public func importFile(_ source: URL) throws -> String {
        let ext = source.pathExtension.lowercased()
        let name = UUID().uuidString + (ext.isEmpty ? "" : ".\(ext)")
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        try FileManager.default.copyItem(at: source, to: url(for: name))
        return name
    }

    /// Takes in a file OOO made itself and no longer needs where it is (a
    /// recording just kept): moved, not copied, so even a long camera
    /// recording arrives at once. Returns its stored name.
    public func adopt(_ source: URL) throws -> String {
        let ext = source.pathExtension.lowercased()
        let name = UUID().uuidString + (ext.isEmpty ? "" : ".\(ext)")
        do {
            try FileManager.default.moveItem(at: source, to: url(for: name))
        } catch {
            // On another disk: copied instead, and the original left to its owner.
            try FileManager.default.copyItem(at: source, to: url(for: name))
        }
        return name
    }

    public func write(_ data: Data, as file: String) throws {
        try data.write(to: url(for: file), options: .atomic)
    }

    deinit {
        // The window is gone: so are its recordings on the stage.
        let folder = directory.standardizedFileURL.path + "/"
        OOOShared.stage?.releaseFaces { $0.standardizedFileURL.path.hasPrefix(folder) }
        try? FileManager.default.removeItem(at: directory)
        if owner >= 0 { close(owner) }
    }
}

/// An OOO document.
public final class OOODocument: ReferenceFileDocument, @unchecked Sendable {
    public typealias Snapshot = OOOProject

    public static var readableContentTypes: [UTType] { [.oooProject] }
    public static var writableContentTypes: [UTType] { [.oooProject] }

    @Published public var project: OOOProject
    public let media = MediaStore()
    /// True for a document made with File › New, until its window first opens.
    public var isNew = false

    /// A new document opens on the sample slide, already moving, so the first
    /// thing anyone sees is what OOO is for.
    public init() {
        project = .sample
        isNew = true
    }

    public init(project: OOOProject) {
        self.project = project
        isNew = true
    }

    public required init(configuration: ReadConfiguration) throws {
        let root = configuration.file
        guard let wrappers = root.fileWrappers,
              let json = wrappers[ProjectPackage.projectFile]?.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        project = try ProjectPackage.decode(json)
        if let mediaDir = wrappers[ProjectPackage.mediaFolder]?.fileWrappers {
            for (name, wrapper) in mediaDir {
                guard let data = wrapper.regularFileContents else { continue }
                do {
                    try media.write(data, as: name)
                } catch {
                    // Opened without its slide, voice or recording, it would only look whole.
                    throw CocoaError(.fileReadUnknown, userInfo: [
                        NSLocalizedDescriptionKey: "OOO couldn't make a working copy of this document's slides, voiceover or camera recording.",
                        NSLocalizedRecoverySuggestionErrorKey: "\(error.localizedDescription) The document itself is untouched. Free some space on the Mac, then open it again.",
                        NSUnderlyingErrorKey: error,
                    ])
                }
            }
        }
    }

    public func snapshot(contentType: UTType) throws -> OOOProject { project }

    public func fileWrapper(snapshot: OOOProject, configuration: WriteConfiguration) throws -> FileWrapper {
        let data = try ProjectPackage.encode(snapshot)
        var mediaWrappers: [String: FileWrapper] = [:]
        // Every slide's file, not just the first's, and the voiceover's and the camera's.
        let needed = Set(snapshot.mediaFiles)
        let saved = configuration.existingFile?.fileWrappers?[ProjectPackage.mediaFolder]?.fileWrappers
        for file in needed {
            if let existing = saved?[file] {
                mediaWrappers[file] = existing
            } else if media.contains(file), let w = try? FileWrapper(url: media.url(for: file), options: []) {
                w.preferredFilename = file
                mediaWrappers[file] = w
            } else {
                // Refuse to save rather than write a package that has lost its slide or voice.
                throw CocoaError(.fileWriteUnknown, userInfo: [
                    NSLocalizedDescriptionKey: "A slide, the voiceover or the camera recording is missing, so the document was not saved.",
                    NSLocalizedRecoverySuggestionErrorKey: "Add it again, then save.",
                ])
            }
        }
        let mediaDir = FileWrapper(directoryWithFileWrappers: mediaWrappers)
        mediaDir.preferredFilename = ProjectPackage.mediaFolder
        let projectWrapper = FileWrapper(regularFileWithContents: data)
        projectWrapper.preferredFilename = ProjectPackage.projectFile
        return FileWrapper(directoryWithFileWrappers: [
            ProjectPackage.projectFile: projectWrapper,
            ProjectPackage.mediaFolder: mediaDir,
        ])
    }
}
