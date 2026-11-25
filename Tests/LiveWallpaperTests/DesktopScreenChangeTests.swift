import AppKit
import XCTest
@testable import LiveWallpaper

final class DesktopScreenChangeTests: XCTestCase {
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
        original.forEach { $0.orderOut(nil) }
        defer {
            NotificationCenter.default.removeObserver(desktop)
            testWindows().forEach { $0.close() }
        }

        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: app)
        try await Task.sleep(nanoseconds: 600_000_000) // The controller coalesces notifications for 300 ms.
        XCTAssertEqual(Set(testWindows().map(ObjectIdentifier.init)), Set(original.map(ObjectIdentifier.init)))
    }
}
