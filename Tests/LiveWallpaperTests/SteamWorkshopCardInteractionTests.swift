import AppKit
import WebKit
import XCTest
@testable import LiveWallpaper

@MainActor
final class SteamWorkshopCardInteractionTests: XCTestCase {
    private let id = "3842424536"
    private let browse = URL(string: "https://steamcommunity.com/workshop/browse/?appid=431960")!

    private final class State {
        var server: Bool?
        var reads: [String] = []
        var events: [Bool] = []
    }

    private func makeWindow(_ state: State) -> (NSPanel, WKWebView) {
        let bridge = SteamWorkshopSubscriptionBridge(lookup: { id, _ in
            state.reads.append(id)
            guard let result = state.server else { return nil }
            var item = WorkshopWallpaper(id: id, title: "Fixture")
            item.isSubscribed = result
            return item
        }, onChange: { _, subscribed in state.events.append(subscribed) })
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        bridge.attach(to: config.userContentController)
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 500, height: 260), configuration: config)
        let window = NSPanel(contentRect: CGRect(x: -6000, y: -6000, width: 500, height: 260),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = web
        window.orderBack(nil)
        return (window, web)
    }

    private func load(_ web: WKWebView, at url: URL, glyph: String = "Plus") async throws {
        let path = "/sharedfiles/filedetails/?id=\(id)"
        web.loadHTMLString("""
            <style>button { width: 80px; height: 50px }</style>
            <div><a href="\(path)">Preview</a><div><a href="\(path)">Name</a>
                <a href="/profiles/123/myworkshopfiles/?appid=431960">Averic</a></div>
                <div><button data-accent-color="green"><svg class="SVGIcon_\(glyph)"></svg></button></div>
            </div>
            <div><a href="/sharedfiles/filedetails/?id=3842432893">Second wallpaper</a></div>
            <script>document.querySelector('button').onclick = e => window.clicked = e.isTrusted</script>
            """, baseURL: url)
        for _ in 0..<120 {
            if !web.isLoading, web.url == url,
               (try? await web.evaluateJavaScript("typeof document.querySelector('button')?.onclick")) as? String == "function" { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("The test card did not load")
    }

    private func click(_ web: WKWebView, in window: NSPanel) async throws {
        let raw = try await web.evaluateJavaScript("""
            (() => { const b = document.querySelector('button').getBoundingClientRect();
                     return [b.x + b.width/2, b.y + b.height/2] })()
            """)
        let point = try XCTUnwrap(raw as? [Double])
        let target = web.convert(NSPoint(x: point[0], y: web.isFlipped ? point[1] : web.bounds.height - point[1]), to: nil)
        for kind in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: kind, location: target, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 42, clickCount: 1, pressure: kind == .leftMouseDown ? 1 : 0))
            window.sendEvent(event)
        }
        for _ in 0..<60 {
            if (try? await web.evaluateJavaScript("window.clicked === true")) as? Bool == true { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("WebKit did not receive a trusted click")
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<150 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("The expected verification never arrived")
    }

    func testConfirmedCardActionsSurviveNavigationAndUseTheClickedItem() async throws {
        let state = State()
        let (window, web) = makeWindow(state)
        defer { window.close() }
        try await load(web, at: browse)
        state.server = true
        try await click(web, in: window)
        let other = try XCTUnwrap(URL(string: "https://steamcommunity.com/app/431960/workshop/"))
        try await load(web, at: other, glyph: "X")
        try await waitFor { state.events == [true] }
        state.server = false
        try await click(web, in: window)
        try await waitFor { state.events == [true, false] }
        XCTAssertEqual(Set(state.reads), [id])
    }

    func testRejectedCardUnsubscribeKeepsFilesAndScriptClicksDoNotStartVerification() async throws {
        let state = State()
        let (window, web) = makeWindow(state)
        defer { window.close() }
        state.server = true
        try await load(web, at: browse, glyph: "Check")
        _ = try await web.evaluateJavaScript("document.querySelector('button').click(); true")
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(state.reads.isEmpty)
        try await click(web, in: window)
        try await waitFor { !state.reads.isEmpty }
        XCTAssertTrue(state.events.isEmpty)
        // A later scripted click can change Steam's state, but cannot inherit the rejected gesture.
        _ = try await web.evaluateJavaScript("document.querySelector('button').click(); true")
        state.server = false
        try await Task.sleep(for: .seconds(1))
        XCTAssertTrue(state.events.isEmpty)
    }

    func testRapidReversalOnlyFinishesLatestIntent() async throws {
        let state = State()
        let (window, web) = makeWindow(state)
        defer { window.close() }
        try await load(web, at: browse)
        try await click(web, in: window)
        try await waitFor { !state.reads.isEmpty }
        state.server = false
        _ = try await web.evaluateJavaScript("""
            window.clicked = false; document.querySelector('svg').setAttribute('class', 'SVGIcon_X'); true
            """)
        try await click(web, in: window)
        try await waitFor { state.events == [false] }
        state.server = true
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(state.events, [false])
    }
}
