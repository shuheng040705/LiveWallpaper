import Combine
import XCTest
@testable import LiveWallpaper

final class PresetPlaybackSelectionTests: XCTestCase {
    @MainActor
    func testRestoreUsesNewestScanAndOnlyUpgradesTheSelectedPreset() async throws {
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: temporary) }
        let previous = temporary.appendingPathComponent("previous", isDirectory: true)
        let current = temporary.appendingPathComponent("current", isDirectory: true)
        let savedID = "100001"
        let otherID = "100002"
        let dependency = "201"
        func writeProject(_ json: [String: Any], folder: URL) throws {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: json).write(to: folder.appendingPathComponent("project.json"))
        }
        try writeProject(["title": "Unrecognized entry"], folder: previous.appendingPathComponent(savedID))
        XCTAssertEqual(WallpaperLibrary.scanFolder(previous).first?.type, .unknown)
        for id in [savedID, otherID] {
            let folder = current.appendingPathComponent(id, isDirectory: true)
            try writeProject(["dependency": dependency, "preset": ["background": "files/animation.webm"]], folder: folder)
            let files = folder.appendingPathComponent("files")
            try fm.createDirectory(at: files, withIntermediateDirectories: true)
            try Data([1]).write(to: files.appendingPathComponent("animation.webm"))
        }

        var root = previous
        let library = WallpaperLibrary(configuredRoot: { root })
        var snapshots: [[String]] = []
        let observation = library.$items.dropFirst().sink { snapshots.append($0.map(\.id).sorted()) }
        defer { observation.cancel() }
        let completions = expectation(description: "Both scan callbacks see the current library")
        completions.expectedFulfillmentCount = 2
        func restored() {
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(library.item(id: savedID)?.type, .web)
            completions.fulfill()
        }
        library.scan(completion: restored)
        root = current
        library.scan(completion: restored)
        await fulfillment(of: [completions], timeout: 5)
        XCTAssertEqual(snapshots, [[savedID, otherID]])
        let fallback = try XCTUnwrap(library.item(id: savedID))
        XCTAssertNil(fallback.playbackUnavailableReason)
        XCTAssertEqual(fallback.presetVideoURL?.lastPathComponent, "animation.webm")
        let first = try XCTUnwrap(AppDelegate.PendingPreset(fallback, libraryRoot: current))
        let other = try XCTUnwrap(library.item(id: otherID))
        let selection = try XCTUnwrap(AppDelegate.PendingPreset(other, libraryRoot: current))
        XCTAssertNil(selection.resolvedItem(in: library.items))

        let template = current.appendingPathComponent(dependency, isDirectory: true)
        try writeProject(["type": "web", "file": "index.html"], folder: template)
        try Data("<html></html>".utf8).write(to: template.appendingPathComponent("index.html"))
        let installed = WallpaperLibrary.scanFolder(current)
        XCTAssertEqual(first.resolvedItem(in: installed)?.id, savedID)
        XCTAssertNil(selection.resolvedItem(in: installed.filter { $0.id == savedID }))
        let upgraded = try XCTUnwrap(selection.resolvedItem(in: installed))
        XCTAssertEqual(upgraded.id, otherID)
        XCTAssertEqual(upgraded.fileURL?.lastPathComponent, "index.html")
        XCTAssertNil(AppDelegate.PendingPreset(upgraded, libraryRoot: current))
    }
}
