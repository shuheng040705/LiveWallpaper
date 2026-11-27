import WebKit
import XCTest
@testable import LiveWallpaper

final class WebSharedPresetResourceTests: XCTestCase {
    func testWebKitMediaHeaderProbesAndSeekRanges() {
        XCTAssertEqual(WebRenderer.mediaRange("bytes=0-1", count: 100), 0..<2)
        XCTAssertEqual(WebRenderer.mediaRange("bytes=75-", count: 100), 75..<100)
        XCTAssertEqual(WebRenderer.mediaRange("bytes=75-150", count: 100), 75..<100)
        XCTAssertEqual(WebRenderer.mediaRange("bytes=-10", count: 100), 90..<100)
        XCTAssertEqual(WebRenderer.mediaRange("bytes=100-", count: 100), 100..<100)
        XCTAssertNil(WebRenderer.mediaRange("bytes=0-1,5-8", count: 100))
    }

    @MainActor
    func testTemplateCanReadItsAssetsAndThePresetFileSelectedByTheAuthor() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let template = root.appendingPathComponent("101", isDirectory: true)
        let preset = root.appendingPathComponent("202", isDirectory: true)
        let files = preset.appendingPathComponent("files", isDirectory: true)
        let renderer = WebRenderer()
        defer {
            renderer.stop()
            try? fm.removeItem(at: root)
        }
        try fm.createDirectory(at: template, withIntermediateDirectories: true)
        try fm.createDirectory(at: files, withIntermediateDirectories: true)
        let manifest = """
        {"type":"web","file":"index.html","general":{"properties":{
          "picture":{"type":"file","filetype":"image","text":"Picture","value":""}
        }}}
        """
        try Data(manifest.utf8).write(to: template.appendingPathComponent("project.json"))
        let child = #"{"dependency":"101","preset":{"picture":"files/a # %2f.png"}}"#
        try Data(child.utf8).write(to: preset.appendingPathComponent("project.json"))
        let png = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGMQD1j6HwADmgIMlwgRRQAAAABJRU5ErkJggg=="))
        try png.write(to: files.appendingPathComponent("a # %2f.png"))
        try Data("template asset".utf8).write(to: template.appendingPathComponent("label.txt"))
        try fm.createSymbolicLink(at: files.appendingPathComponent("outside.txt"),
                                  withDestinationURL: template.appendingPathComponent("label.txt"))
        let html = """
        <!doctype html><img id="picture"><script>
        wallpaperPropertyListener = {async applyUserProperties(props) {
          try {
            const picture = document.getElementById("picture");
            picture.src = "file:///" + props.picture.value;
            await picture.decode();
            const text = await (await fetch("./label.txt")).text();
            let blocked = false;
            try { await fetch(new URL("outside.txt", picture.src)); } catch { blocked = true; }
            window.result = [text, picture.naturalWidth, blocked];
          } catch (error) { window.result = [String(error)]; }
        }};
        </script>
        """
        try Data(html.utf8).write(to: template.appendingPathComponent("index.html"))
        let item = try XCTUnwrap(WallpaperLibrary.scanFolder(root).first { $0.id == "202" })
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 160, height: 90))
        renderer.attach(to: host)
        renderer.load(item)
        let web = try XCTUnwrap(host.subviews.compactMap { $0 as? WKWebView }.first)

        let deadline = Date().addingTimeInterval(10)
        repeat {
            if let result = try? await web.evaluateJavaScript("window.result") as? [Any] {
                XCTAssertEqual(result.first as? String, "template asset", String(describing: result))
                XCTAssertEqual(result.count, 3)
                if result.count == 3 {
                    XCTAssertEqual(result[1] as? Int, 1)
                    XCTAssertEqual(result[2] as? Bool, true)
                }
                return
            }
            try await Task.sleep(nanoseconds: 40_000_000)
        } while Date() < deadline
        XCTFail("The template did not receive its shared preset")
    }
}
