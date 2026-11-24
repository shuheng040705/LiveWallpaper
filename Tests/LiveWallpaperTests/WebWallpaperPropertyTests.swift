import WebKit
import XCTest
@testable import LiveWallpaper

final class WebWallpaperPropertyTests: XCTestCase {
    @MainActor
    func testSavedPropertiesReachLateListenerAndEditsApplyWithoutReload() async throws {
        let id = "test-\(UUID().uuidString)"
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let project = """
        {"type":"web", "general":{"properties":{
            "voice":{"type":"bool","value":true,"text":"播放语音"},
            "zoom":{"type":"slider","value":109,"min":50,"max":200},
            "mode":{"type":"combo","value":0,"options":[{"value":0},{"value":1}]},
            "title":{"type":"textinput","value":"hello"}
        }}}
        """
        let html = """
        <!doctype html><script>
        window.batches = [];
        window.addEventListener('load', () => setTimeout(() => {
            window.wallpaperPropertyListener = { applyUserProperties(changes) { window.batches.push(changes); } };
        }, 200));
        </script>
        """
        try Data(project.utf8).write(to: folder.appendingPathComponent("project.json"))
        try Data(html.utf8).write(to: folder.appendingPathComponent("index.html"))
        let item = WallpaperItem(id: id, folderURL: folder, title: "Test", type: .web,
                                 fileName: "index.html", previewName: nil, tags: [])
        let store = WallpaperPropertyStore.shared
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 180))
        let renderer = WebRenderer()
        defer {
            renderer.stop()
            store.reset(forID: id, folderURL: folder)
            try? FileManager.default.removeItem(at: folder)
        }
        let controls = store.properties(forID: id, folderURL: folder, wallpaperType: .web)
        XCTAssertTrue(try XCTUnwrap(controls.first { $0.id == "voice" }).supported)
        XCTAssertTrue(try XCTUnwrap(controls.first { $0.id == "title" }).supported)
        store.setValue(.bool(false), forID: id, propertyKey: "voice")
        store.setValue(.string("1"), forID: id, propertyKey: "mode")
        renderer.attach(to: host)
        renderer.load(item)
        let web = try XCTUnwrap(host.subviews.compactMap { $0 as? WKWebView }.first)
        let first = try await batch(1, in: web)
        XCTAssertEqual(first["voice"]?["value"] as? Bool, false)
        XCTAssertEqual(first["zoom"]?["value"] as? Int, 109)
        XCTAssertEqual(first["mode"]?["value"] as? Int, 1)
        XCTAssertEqual(first["title"]?["value"] as? String, "hello")

        store.setValue(.number(143), forID: id, propertyKey: "zoom")
        renderer.reloadInPlace()
        let changed = try await batch(2, in: web)
        XCTAssertEqual(Set(changed.keys), ["zoom"])
        XCTAssertEqual(changed["zoom"]?["value"] as? Int, 143)

        store.reset(forID: id, folderURL: folder)
        renderer.reloadInPlace()
        let reset = try await batch(3, in: web)
        XCTAssertEqual(reset["voice"]?["value"] as? Bool, true)
        XCTAssertEqual(reset["zoom"]?["value"] as? Int, 109)
        XCTAssertEqual(reset["mode"]?["value"] as? Int, 0)
    }

    @MainActor
    private func batch(_ count: Int, in web: WKWebView) async throws -> [String: [String: Any]] {
        let deadline = Date().addingTimeInterval(10)
        repeat {
            if let batches = try? await web.evaluateJavaScript("window.batches || []") as? [[String: [String: Any]]],
               batches.count >= count {
                return batches[count - 1]
            }
            try await Task.sleep(nanoseconds: 40_000_000)
        } while Date() < deadline
        throw WaitError.missingPropertyBatch(count)
    }

    private enum WaitError: Error {
        case missingPropertyBatch(Int)
    }
}
