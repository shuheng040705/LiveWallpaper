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

        func captures(_ point: CGPoint) async -> Bool {
            let frames: [CGRect] = await withCheckedContinuation { continuation in
                WebWallpaperHotspots.read(in: web, at: point) { continuation.resume(returning: $0) }
            }
            return frames.contains { $0.contains(point) }
        }
        let character = CGPoint(x: 0.6, y: 0.4)
        let blank = CGPoint(x: 0.12, y: 0.2)
        for runtime in [
            "window.__rt5 = {hitTest: (x, y) => x === 240 && y === 80 ? 0 : null}",
            "window.wallpaperInteraction = {candidates: (x,y) => x === 240 && y === 80 ? [{}] : []}",
            "window.inspectPointerHit = (x,y) => ({selectedCandidate: x === 240 && y === 80 ? {} : null})",
            "window.hitNameAt = (x,y) => x === 240 && y === 80 ? 'touch_head' : null"
        ] {
            _ = try await web.evaluateJavaScript("delete window.__rt5; delete window.wallpaperInteraction; delete window.inspectPointerHit; delete window.hitNameAt; " + runtime + "; true")
            let hit = await captures(character), miss = await captures(blank)
            XCTAssertTrue(hit, runtime)
            XCTAssertFalse(miss, runtime)
        }
        _ = try await web.evaluateJavaScript("delete window.hitNameAt; true")
        _ = try await web.evaluateJavaScript("""
            window.__rt5 = {
                touch: () => [{index:0, enabled:true},{index:1, enabled:true},{index:2, enabled:false}],
                quad: i => i === 0 ? [{x:110,y:60},{x:150,y:60},{x:150,y:84},{x:110,y:84}]
                                   : [{x:200,y:50},{x:250,y:80},{x:200,y:110},{x:150,y:80}],
                hitTest: () => 0
            }; true
            """)
        let declared = await rects()
        XCTAssertEqual(declared.map(pixels), [CGRect(x: 110, y: 60, width: 40, height: 24), button])
        _ = try await web.evaluateJavaScript("delete window.__rt5; true")
        _ = try await web.evaluateJavaScript("""
            const overlay = document.createElement('div');
            overlay.style.cssText='position:fixed;inset:0';
            document.body.append(overlay);
            window.inspectPointerHit = (x, y) => ({selectedCandidate: x===240 && y===80 ? {} : null}); true
            """)
        let documentCapture = await captures(character), coveredBlank = await captures(blank)
        XCTAssertTrue(documentCapture)
        XCTAssertFalse(coveredBlank)
        _ = try await web.evaluateJavaScript("delete window.inspectPointerHit; true")
        let fullCanvas = await captures(character)
        XCTAssertFalse(fullCanvas)
    }
}
