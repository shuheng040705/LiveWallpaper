import AppKit
import WebKit
import XCTest
@testable import LiveWallpaper

final class WebWallpaperGeneralSettingsTests: XCTestCase {
    @MainActor
    func testFrameRateIsDeliveredAtLoadAndWhenSettingsChange() async throws {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: "frameRateCap")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let renderer = WebRenderer()
        defer {
            renderer.stop()
            if let previous { defaults.set(previous, forKey: "frameRateCap") }
            else { defaults.removeObject(forKey: "frameRateCap") }
            try? FileManager.default.removeItem(at: folder)
        }
        // A web project can implement the FPS callback without any authored user properties.
        let html = """
        <!doctype html><script>
        window.frameRates = [];
        setTimeout(() => {
            window.wallpaperPropertyListener = {
                applyGeneralProperties(settings) { frameRates.push(settings.fps); }
            };
        }, 100);
        </script>
        """
        try Data(html.utf8).write(to: folder.appendingPathComponent("index.html"))
        let item = WallpaperItem(id: folder.lastPathComponent, folderURL: folder, title: "Frame rate",
                                 type: .web, fileName: "index.html", previewName: nil, tags: [])
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 160))
        let refreshRate = NSScreen.main?.maximumFramesPerSecond ?? 60
        let unlimited = refreshRate > 0 ? refreshRate : 60
        let edited = unlimited == 15 ? 30 : 15
        PreferencesStore.shared.frameRateCap = 60
        renderer.attach(to: host)
        renderer.load(item)
        let web = try XCTUnwrap(host.subviews.compactMap { $0 as? WKWebView }.first)
        try await expect([60], in: web)

        renderer.reloadInPlace()
        PreferencesStore.shared.frameRateCap = 60
        PreferencesStore.shared.frameRateCap = edited
        try await expect([60, edited], in: web)
        PreferencesStore.shared.frameRateCap = 0
        try await expect([60, edited, unlimited], in: web)

        renderer.load(item)
        try await expect([unlimited], in: web)
    }

    @MainActor
    private func expect(_ values: [Int], in web: WKWebView) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        var observed: [Int]?
        repeat {
            observed = try? await web.evaluateJavaScript("window.frameRates") as? [Int]
            if observed == values { return }
            try await Task.sleep(for: .milliseconds(25))
        } while ContinuousClock.now < deadline
        XCTAssertEqual(observed, values)
    }
}
