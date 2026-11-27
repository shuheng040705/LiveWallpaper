import AppKit
import Metal
import QuartzCore
import XCTest
@testable import LiveWallpaper

final class DesktopScreenChangeTests: XCTestCase {
    @MainActor
    func testWebWallpaperKeepsItsOnePixelBackingWhenResizedOrReapplied() throws {
        _ = NSApplication.shared
        guard let screen = NSScreen.main, MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Requires a display and Metal")
        }
        let window = DesktopWindow(screen: screen)
        defer { window.close() }
        let webHost = window.hostView(for: .web)
        let backing = try XCTUnwrap(webHost.layer as? CAMetalLayer)
        window.setContentSize(CGSize(width: 480, height: 270))
        XCTAssertTrue(window.hostView(for: .web) === webHost)
        XCTAssertTrue(webHost.layer === backing)
        XCTAssertEqual(backing.drawableSize, CGSize(width: 1, height: 1))
        XCTAssertTrue(window.isOpaque)
        XCTAssertTrue(window.ignoresMouseEvents)

        let sceneHost = window.hostView(for: .scene)
        XCTAssertFalse(sceneHost.layer is CAMetalLayer)
        XCTAssertTrue(window.hostView(for: .video) === sceneHost)
        XCTAssertTrue(window.hostView(for: .web).layer is CAMetalLayer)
    }

    @MainActor
    func testUnsupportedWallpaperLeavesPlaybackAndRestoreStateAlone() {
        let desktop = DesktopController()
        let previousID = PreferencesStore.shared.lastWallpaperID
        defer { PreferencesStore.shared.lastWallpaperID = previousID }
        let item = WallpaperItem(id: "unsupported-fixture", folderURL: FileManager.default.temporaryDirectory,
                                 title: "Unsupported wallpaper", type: .unknown,
                                 fileName: nil, previewName: nil, tags: [])
        var completed = false
        let failure = desktop.apply(item) { completed = true }
        XCTAssertNotNil(failure)
        XCTAssertFalse(completed)
        XCTAssertNil(desktop.currentID)
        XCTAssertEqual(PreferencesStore.shared.lastWallpaperID, previousID)
    }

    @MainActor
    func testScreenNotificationWithSameRenderTargetsKeepsDesktopWindows() async throws {
        let app = NSApplication.shared
        guard !NSScreen.screens.isEmpty else { throw XCTSkip("Requires a display") }
        let existing = Set(app.windows.map(ObjectIdentifier.init))
        func testWindows() -> [DesktopWindow] {
            app.windows.compactMap { $0 as? DesktopWindow }.filter { !existing.contains(ObjectIdentifier($0)) }
        }

        let desktop = DesktopController()
        desktop.start()
        let original = testWindows()
        XCTAssertFalse(original.isEmpty)
        XCTAssertTrue(original.allSatisfy { !$0.isVisible }, "An empty host must leave the system wallpaper visible")
        defer {
            NotificationCenter.default.removeObserver(desktop)
            testWindows().forEach { $0.close() }
        }

        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: app)
        try await Task.sleep(nanoseconds: 600_000_000) // The controller coalesces notifications for 300 ms.
        XCTAssertEqual(Set(testWindows().map(ObjectIdentifier.init)), Set(original.map(ObjectIdentifier.init)))
    }
}
