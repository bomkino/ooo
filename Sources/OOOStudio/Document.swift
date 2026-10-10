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

    /// Every window's own folder sits in here.
    static let sessions = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("OOO", isDirectory: true)
        .appendingPathComponent("Sessions", isDirectory: true)

    public init() {
        let base = Self.sessions.appendingPathComponent(UUID().uuidString, isDirectory: true)
        directory = base
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    /// Clears what earlier runs left behind: a window's folder goes when the
    /// window closes, but not when OOO quits or stops unexpectedly, and a
    /// camera recording can be big. Call before any document opens.
    static func sweep() {
        let old = (try? FileManager.default.contentsOfDirectory(at: sessions, includingPropertiesForKeys: nil)) ?? []
        guard !old.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async {
            for url in old { try? FileManager.default.removeItem(at: url) }
        }
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

    public func write(_ data: Data, as file: String) throws {
        try data.write(to: url(for: file), options: .atomic)
    }

    deinit {
        // The window is gone: so are its recordings on the stage.
        let folder = directory.standardizedFileURL.path + "/"
        OOOShared.stage?.releaseFaces { $0.standardizedFileURL.path.hasPrefix(folder) }
        try? FileManager.default.removeItem(at: directory)
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
                if let data = wrapper.regularFileContents {
                    try? media.write(data, as: name)
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
