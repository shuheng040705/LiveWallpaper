import WebKit
import XCTest
@testable import LiveWallpaper

final class WebWallpaperHotspotsTests: XCTestCase {
    @MainActor
    func testAuthorGeometryWithHiddenHintsAndOrdinaryHTMLControls() async throws {
        _ = NSApplication.shared
        let id = UUID().uuidString
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let item = WallpaperItem(id: id, folderURL: folder, title: "Hotspots", type: .web,
                                 fileName: "index.html", previewName: nil, tags: [])
        let store = WallpaperPropertyStore.shared
        let renderer = WebRenderer()
        defer {
            renderer.stop()
            store.reset(forID: id, folderURL: folder)
            try? FileManager.default.removeItem(at: folder)
        }
        let project = #"{"general":{"properties":{"hints":{"type":"bool","value":false},"interaction":{"type":"bool","value":true}}}}"#
        let html = """
        <!doctype html><style>
        body{margin:0} #stage,#hotspots,.hotspot,button{position:fixed}
        #stage,#hotspots{inset:0;width:100%;height:100%} #hotspots{pointer-events:none}
        [data-hit=fallback]{inset:0} button{top:0;right:0;width:40px;height:20px}
        </style><canvas id="stage"></canvas>
        <div id="hotspots" hidden><div class="hotspot" data-hit="head"></div>
        <div class="hotspot" data-hit="fallback"></div></div><button>Play</button>
        <script>
        const box = document.querySelector('[data-hit=head]'); window.left = 20;
        window.wallpaperPropertyListener = { applyUserProperties(p) {
            if (p.hints) {
                hotspots.hidden = !p.hints.value;
                if (!hotspots.hidden) box.style.cssText = 'left:'+window.left+'px;top:60px;width:40px;height:20px';
            }
        }};
        </script>
        """
        try Data(project.utf8).write(to: folder.appendingPathComponent("project.json"))
        try Data(html.utf8).write(to: folder.appendingPathComponent("index.html"))
        let host = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        renderer.attach(to: host)
        renderer.load(item)
        let web = try XCTUnwrap(host.subviews.compactMap { $0 as? WKWebView }.first)
        func rects() async -> [CGRect] {
            await withCheckedContinuation { continuation in
                WebWallpaperHotspots.read(in: web) { continuation.resume(returning: $0) }
            }
        }
        func pixels(_ rect: CGRect) -> CGRect {
            CGRect(x: (rect.minX * 400).rounded(), y: (rect.minY * 200).rounded(),
                   width: (rect.width * 400).rounded(), height: (rect.height * 200).rounded())
        }
        let deadline = Date().addingTimeInterval(6)
        while (try? await web.evaluateJavaScript("!!window.__lwUserPropertyState?.values") as? Bool) != true {
            guard Date() < deadline else { return XCTFail("Wallpaper did not receive initial properties") }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        let normal = await rects()
        let button = CGRect(x: 360, y: 0, width: 40, height: 20)
        XCTAssertEqual(normal.map(pixels), [CGRect(x: 20, y: 60, width: 40, height: 20), button])
        let stillHidden = try await web.evaluateJavaScript("hotspots.hidden") as? Bool
        XCTAssertEqual(stillHidden, true)
        _ = try await web.evaluateJavaScript("window.left = 160")
        let moved = await rects()
        XCTAssertEqual(moved.first?.minX, 0.4)
        _ = try await web.evaluateJavaScript("document.querySelector('[data-hit=fallback]').style.inset = '8%'")
        let boundedFallback = await rects()
        XCTAssertEqual(boundedFallback.map(pixels), [CGRect(x: 160, y: 60, width: 40, height: 20),
                                                      CGRect(x: 32, y: 16, width: 336, height: 168), button])
        store.setValue(.bool(false), forID: id, propertyKey: "interaction")
        renderer.reloadInPlace()
        let disabled = await rects()
        XCTAssertEqual(disabled.map(pixels), [button])
    }
}
