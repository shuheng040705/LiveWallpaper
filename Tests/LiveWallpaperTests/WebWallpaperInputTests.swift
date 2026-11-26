import WebKit
import XCTest
@testable import LiveWallpaper

final class WebWallpaperInputTests: XCTestCase {
    func testRevealedFinderDesktopAcceptsHotspotsWithOrWithoutAccessibility() {
        let display = CGRect(x: -1440, y: -120, width: 1440, height: 900)
        XCTAssertTrue(WebWallpaperInput.isDesktopBackdrop(frame: display, display: display, finderRole: nil))
        XCTAssertTrue(WebWallpaperInput.isDesktopBackdrop(frame: display, display: display, finderRole: kAXGroupRole))
        XCTAssertFalse(WebWallpaperInput.isDesktopBackdrop(frame: display, display: display, finderRole: kAXImageRole))

        let item = CGRect(x: -300, y: 0, width: 80, height: 80)
        XCTAssertFalse(WebWallpaperInput.isDesktopBackdrop(frame: item, display: display, finderRole: nil))
        let otherDisplay = display.offsetBy(dx: display.width, dy: 0)
        XCTAssertFalse(WebWallpaperInput.isDesktopBackdrop(frame: otherDisplay, display: display, finderRole: kAXGroupRole))
    }

    func testCoordinateConversionUsesViewBoundsAndOneVerticalFlip() {
        let bounds = CGRect(x: -80, y: 60, width: 320, height: 200)
        let point = CGPoint(x: 0, y: 110)
        XCTAssertEqual(WebWallpaperInput.normalizedPoint(point, in: bounds, flipped: true),
                       CGPoint(x: 0.25, y: 0.25))
        XCTAssertEqual(WebWallpaperInput.normalizedPoint(point, in: bounds, flipped: false),
                       CGPoint(x: 0.25, y: 0.75))
        XCTAssertNil(WebWallpaperInput.normalizedPoint(CGPoint(x: -81, y: 110), in: bounds, flipped: true))
        XCTAssertNil(WebWallpaperInput.normalizedPoint(.zero, in: .zero, flipped: false))
    }

    @MainActor
    func testPrimaryClickHitsCanvasUsingCSSViewportCoordinates() async throws {
        _ = NSApplication.shared
        let id = UUID().uuidString
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let renderer = WebRenderer()
        defer {
            renderer.stop()
            try? FileManager.default.removeItem(at: folder)
        }
        let html = """
        <!doctype html><style>body{margin:0} canvas{position:fixed;left:50%;top:0;width:50%;height:100%}</style>
        <canvas id="stage"></canvas><script>
        window.received = [];
        for (const name of ['pointerdown','mousedown','pointerup','mouseup','click','pointermove','mousemove','pointercancel']) {
          document.querySelector('canvas').addEventListener(name, event => received.push(
            [event.type,event.target.id,event.clientX,event.clientY,event.buttons].join(':')));
        }
        </script>
        """
        try Data(html.utf8).write(to: folder.appendingPathComponent("index.html"))
        let host = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        renderer.attach(to: host)
        let view = try XCTUnwrap(host.subviews.compactMap { $0 as? WKWebView }.first)
        renderer.load(WallpaperItem(id: id, folderURL: folder, title: "Input test", type: .web,
                                    fileName: "index.html", previewName: nil, tags: []))
        let deadline = Date().addingTimeInterval(8)
        while (try? await view.evaluateJavaScript("Array.isArray(window.received)") as? Bool) != true {
            guard Date() < deadline else { return XCTFail("Wallpaper canvas did not load") }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        let coordinate = CGPoint(x: 0.75, y: 0.25)
        let delivered: Bool = await withCheckedContinuation { continuation in
            WebWallpaperInput.dispatchClick(at: coordinate, in: view) { result, _ in
                continuation.resume(returning: result as? Bool == true)
            }
        }
        XCTAssertTrue(delivered)
        let events = try await view.evaluateJavaScript("window.received") as? [String]
        XCTAssertEqual(events, ["pointerdown:stage:300:50:1", "mousedown:stage:300:50:1",
                                "pointerup:stage:300:50:0", "mouseup:stage:300:50:0", "click:stage:300:50:0"])

        func send(_ phase: WallpaperPointerPhase, _ point: CGPoint) async -> Bool {
            await withCheckedContinuation { completion in
                WebWallpaperInput.dispatch(phase, at: point, in: view) { value, _ in
                    completion.resume(returning: value as? Bool == true)
                }
            }
        }
        _ = try await view.evaluateJavaScript("received.length = 0")
        // Keep the original canvas as the event recipient when the pointer leaves it.
        let outsideCanvas = CGPoint(x: 0.25, y: 0.25)
        for (phase, point) in [(WallpaperPointerPhase.down, coordinate), (.drag, outsideCanvas), (.up, outsideCanvas),
                               (.hover, coordinate), (.down, coordinate), (.cancel, coordinate)] {
            let delivered = await send(phase, point)
            XCTAssertTrue(delivered)
        }
        let drag = try await view.evaluateJavaScript("received") as? [String]
        XCTAssertEqual(drag, ["pointerdown:stage:300:50:1", "mousedown:stage:300:50:1",
                              "pointermove:stage:100:50:1", "mousemove:stage:100:50:1",
                              "pointerup:stage:100:50:0", "mouseup:stage:100:50:0",
                              "pointermove:stage:300:50:0", "mousemove:stage:300:50:0",
                              "pointerdown:stage:300:50:1", "mousedown:stage:300:50:1", "pointercancel:stage:300:50:0"])
    }
}
