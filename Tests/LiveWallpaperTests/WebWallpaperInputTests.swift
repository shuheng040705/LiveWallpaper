import WebKit
import XCTest
@testable import LiveWallpaper

final class WebWallpaperInputTests: XCTestCase {
    func testRevealedFinderDesktopAcceptsHotspotsWithOrWithoutAccessibility() {
        let display = CGRect(x: -1440, y: -120, width: 1440, height: 900)
        XCTAssertTrue(WallpaperDesktopInput.isDesktopBackdrop(frame: display, display: display, finderRole: nil))
        XCTAssertTrue(WallpaperDesktopInput.isDesktopBackdrop(frame: display, display: display, finderRole: kAXGroupRole))
        XCTAssertFalse(WallpaperDesktopInput.isDesktopBackdrop(frame: display, display: display, finderRole: kAXImageRole))

        let item = CGRect(x: -300, y: 0, width: 80, height: 80)
        XCTAssertFalse(WallpaperDesktopInput.isDesktopBackdrop(frame: item, display: display, finderRole: nil))
        let otherDisplay = display.offsetBy(dx: display.width, dy: 0)
        XCTAssertFalse(WallpaperDesktopInput.isDesktopBackdrop(frame: otherDisplay, display: display, finderRole: kAXGroupRole))
    }

    func testCoordinateConversionUsesViewBoundsAndOneVerticalFlip() {
        let bounds = CGRect(x: -80, y: 60, width: 320, height: 200)
        let point = CGPoint(x: 0, y: 110)
        XCTAssertEqual(WallpaperDesktopInput.normalizedPoint(point, in: bounds, flipped: true),
                       CGPoint(x: 0.25, y: 0.25))
        XCTAssertEqual(WallpaperDesktopInput.normalizedPoint(point, in: bounds, flipped: false),
                       CGPoint(x: 0.25, y: 0.75))
        XCTAssertNil(WallpaperDesktopInput.normalizedPoint(CGPoint(x: -81, y: 110), in: bounds, flipped: true))
        XCTAssertNil(WallpaperDesktopInput.normalizedPoint(.zero, in: .zero, flipped: false))
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
        <!doctype html><style>body{margin:0} canvas{position:fixed;left:50%;top:0;width:50%;height:100%}
        input{position:absolute;left:10px;top:8px;width:160px} button{position:absolute;top:70px}</style>
        <canvas id="stage"></canvas><input type="range" id="volume" value="50"><button disabled>Disabled</button>
        <script>
        window.received = []; window.trusted = true; window.changes = []; window.disabledClicks = 0; window.hoverButtons = [];
        const stage = document.querySelector('canvas');
        stage.addEventListener('pointerdown', event => {
            stage.setPointerCapture(event.pointerId);
            window.captured = stage.hasPointerCapture(event.pointerId);
        });
        for (const name of ['pointerdown','pointerup','pointermove','pointerout','pointerleave','lostpointercapture','click']) {
            stage.addEventListener(name, event => {
                if (name === 'pointermove') hoverButtons.push(event.buttons);
                trusted = trusted && event.isTrusted;
                received.push([event.type,event.clientX,event.clientY].join(':'));
            });
        }
        volume.addEventListener('input', () => changes.push('input'));
        stage.ondblclick = event => window.doubleClickCount = event.detail;
        volume.addEventListener('change', () => changes.push('change'));
        document.querySelector('button').onclick = () => disabledClicks++;
        </script>
        """
        try Data(html.utf8).write(to: folder.appendingPathComponent("index.html"))
        let panel = NSPanel(contentRect: CGRect(x: -4000, y: -4000, width: 400, height: 200),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        let host = try XCTUnwrap(panel.contentView)
        panel.orderBack(nil)
        defer { panel.close() }
        renderer.attach(to: host)
        let web = try XCTUnwrap(host.subviews.compactMap { $0 as? WebWallpaperView }.first)
        renderer.load(WallpaperItem(id: id, folderURL: folder, title: "Input test", type: .web,
                                    fileName: "index.html", previewName: nil, tags: []))
        let deadline = Date().addingTimeInterval(8)
        while (try? await web.evaluateJavaScript("Array.isArray(window.received)") as? Bool) != true {
            guard Date() < deadline else { return XCTFail("Wallpaper canvas did not load") }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        let key = NSApp.keyWindow, active = NSWorkspace.shared.frontmostApplication?.processIdentifier
        func send(_ phase: WallpaperPointerPhase, _ x: Double, _ y: Double, count: Int = 1) async -> Bool {
            await withCheckedContinuation { continuation in
                web.send(phase, at: CGPoint(x: x / 400, y: y / 200), clickCount: count) { value, _ in
                    continuation.resume(returning: value as? Bool == true)
                }
            }
        }
        func waitFor(_ expression: String) async throws {
            let deadline = Date().addingTimeInterval(3)
            while (try? await web.evaluateJavaScript(expression) as? Bool) != true {
                guard Date() < deadline else {
                    let value = try? await web.evaluateJavaScript("JSON.stringify({received, captured:window.captured, value:volume.value, changes})")
                    return XCTFail("\(expression) – \(String(describing: value))")
                }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        }

        let moved = await send(.hover, 300, 50)
        XCTAssertTrue(moved)
        try await waitFor("stage.matches(':hover')")
        _ = await send(.leave, 300, 50)
        try await waitFor("!stage.matches(':hover') && received.some(e => e.startsWith('pointerout:')) && received.some(e => e.startsWith('pointerleave:'))")

        let passive = try await web.evaluateJavaScript("trusted && hoverButtons.includes(0) && !received.some(e => /^(pointerdown|pointerup|click):/.test(e))") as? Bool
        XCTAssertEqual(passive, true)

        // Queue the entire gesture while the document hit test is still in flight.
        // WebKit must keep the original canvas captured across its left edge.
        web.send(.down, at: CGPoint(x: 0.75, y: 0.25))
        web.send(.drag, at: CGPoint(x: 0.25, y: 0.25))
        web.send(.up, at: CGPoint(x: 0.25, y: 0.25))
        try await waitFor("window.captured && trusted && received.includes('pointerdown:300:50') && received.includes('pointermove:100:50') && received.includes('pointerup:100:50')")

        // The browser updates the slider and emits change when the user releases it.
        _ = await send(.down, 90, 17)
        _ = await send(.drag, 155, 17)
        _ = await send(.up, 155, 17)
        try await waitFor("+volume.value > 85 && changes.includes('input') && changes.at(-1) === 'change'")

        let disabled = await send(.down, 20, 78)
        XCTAssertFalse(disabled)
        let strayRelease = await send(.up, 20, 78)
        XCTAssertFalse(strayRelease)
        let count = try await web.evaluateJavaScript("disabledClicks") as? Int
        XCTAssertEqual(count, 0)
        _ = await send(.down, 300, 50)
        _ = await send(.cancel, 300, 50)
        try await waitFor("received.filter(e => e.startsWith('lostpointercapture:')).length === 2")
        for count in 1...2 {
            _ = await send(.down, 280, 90, count: count)
            _ = await send(.up, 280, 90, count: count)
        }
        try await waitFor("window.doubleClickCount === 2")
        XCTAssertTrue(NSApp.keyWindow === key)
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, active)
    }
}
