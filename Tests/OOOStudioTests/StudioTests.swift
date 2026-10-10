import Foundation
import XCTest
@testable import OOOStudio

/// The CI clap check can't pass with claps missing, and it reaches the end of a long take.
final class SyncCheckTests: XCTestCase {
    func testEveryClapMustBeFound() {
        let claps = SyncCheck.claps(within: 47.6)
        XCTAssertEqual(claps, [4, 11, 17.5, 26, 33, 40.5])
        let all = claps.map { Optional($0) }
        XCTAssertTrue(SyncCheck.verdict(claps: claps, fps: 30, kept: all, picture: all, sound: all).ok)
        let half = claps.enumerated().map { $0.offset < 3 ? Optional($0.element) : nil }
        XCTAssertFalse(SyncCheck.verdict(claps: claps, fps: 30, kept: half, picture: half, sound: half).ok)
        XCTAssertFalse(SyncCheck.verdict(claps: claps, fps: 30, kept: half, picture: all, sound: all).ok)
        XCTAssertFalse(SyncCheck.verdict(claps: claps, fps: 30, kept: all, picture: all, sound: half).ok)
    }

    func testClapsReachTheEndOfALongTake() throws {
        let claps = SyncCheck.claps(within: 180)
        XCTAssertGreaterThan(try XCTUnwrap(claps.last), 170)
        XCTAssertLessThan(try XCTUnwrap(claps.last), 180 - 1.5)
        // Whole frames at 30 fps.
        XCTAssertTrue(claps.allSatisfy { ($0 * 30).rounded() == $0 * 30 })
    }
}

/// A launch clears only folders no open window holds.
final class MediaStoreTests: XCTestCase {
    func testSweepKeepsWhatAnOpenWindowHolds() throws {
        let window = MediaStore()
        try window.write(Data([1, 2, 3]), as: "slide.png")
        // Left behind by a window that is gone: its lock is there, and no one holds it.
        let left = MediaStore.sessions.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: left, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: left.appendingPathComponent(".owner").path, contents: nil)
        FileManager.default.createFile(atPath: left.appendingPathComponent("take.mov").path, contents: Data([4]))

        MediaStore.sweep(earlierToo: false)
        let deadline = Date().addingTimeInterval(10)
        while FileManager.default.fileExists(atPath: left.path), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: left.path))
        XCTAssertTrue(window.contains("slide.png"))
    }

    func testAdoptMovesAFileIn() throws {
        let store = MediaStore()
        let made = FileManager.default.temporaryDirectory.appendingPathComponent("OOO adopt \(UUID().uuidString).m4a")
        try Data([9, 9, 9]).write(to: made)
        let name = try store.adopt(made)
        XCTAssertTrue(name.hasSuffix(".m4a"))
        XCTAssertTrue(store.contains(name))
        XCTAssertFalse(FileManager.default.fileExists(atPath: made.path))
    }
}
