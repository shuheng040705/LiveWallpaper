import AppKit
import WebKit
import XCTest
@testable import LiveWallpaper

@MainActor
final class SteamWorkshopListSubscriptionsTests: XCTestCase {
    private let id = "3844145761"
    private let second = "3843425147"
    private let browse = URL(string: "https://steamcommunity.com/workshop/browse/?appid=431960")!

    private final class Hints: NSObject, WKScriptMessageHandler {
        var batches: [[String]] = []
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], body["kind"] as? String == "listSubscriptions",
                  body["app"] as? String == "431960", let ids = body["ids"] as? [String] else {
                XCTFail("Invalid candidate batch"); return
            }
            batches.append(ids)
        }
    }

    private func webView(for hints: Hints) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(hints, contentWorld: .defaultClient, name: "hints")
        SteamWorkshopListSubscriptions.install(in: config.userContentController, world: .defaultClient, handler: "hints")
        return WKWebView(frame: CGRect(x: 0, y: 0, width: 440, height: 220), configuration: config)
    }

    private func card(_ id: String, checked: Bool, titleID: String? = nil) -> String {
        let badge = checked ? "<svg class='SVGIcon_Button SVGIcon_Check'></svg>" : ""
        return """
        <div class="Panel" id="c\(id)">
            <div><a href="/sharedfiles/filedetails/?id=\(id)"><img alt="Preview"></a></div>
            <div><div class="badge">\(badge)</div>
                <a href="/sharedfiles/filedetails/?id=\(titleID ?? id)">Title \(id)</a>
                <div><a href="/profiles/123/myworkshopfiles/?appid=431960">Averic</a></div>
                <div><button data-accent-color="green"><svg class="SVGIcon_Plus" width="44" height="25"></svg></button></div>
            </div>
        </div>
        """
    }

    private func load(_ html: String, into web: WKWebView, at url: URL) async throws {
        web.loadHTMLString(html, baseURL: url)
        for _ in 0..<120 {
            if !web.isLoading && web.url == url { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        try await Task.sleep(for: .milliseconds(150))
    }

    private func expect(_ count: Int, of id: String, in hints: Hints) async throws {
        for _ in 0..<60 {
            if hints.batches.joined().filter({ $0 == id }).count >= count { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Missing candidate \(id) with occurrence \(count), got \(hints.batches)")
    }

    func testCheckedBadgesSurviveAbsentHoverButtonsCardReplacementAndHistory() async throws {
        let hints = Hints(), other = Hints()
        let web = webView(for: hints), wrongWorkshop = webView(for: other)
        let html = card(id, checked: true) + card(second, checked: false) +
            card("1234567890", checked: true, titleID: "9876543210") +
            "<aside class='Panel'><svg class='SVGIcon_Check'></svg></aside>"
        try await load(html, into: wrongWorkshop, at: URL(string: "https://steamcommunity.com/workshop/browse/?appid=123456")!)
        XCTAssertTrue(other.batches.isEmpty)
        try await load(html, into: web, at: browse)
        try await expect(1, of: id, in: hints)
        XCTAssertEqual(Set(hints.batches.joined()), [id])

        _ = try await web.evaluateJavaScript("""
            const card = document.getElementById("c\(second)"), replacement = card.cloneNode(true);
            replacement.querySelector("button").remove();
            replacement.querySelector(".badge").innerHTML = '<svg class="SVGIcon_Button SVGIcon_Check"></svg>';
            card.replaceWith(replacement); true
            """)
        try await expect(1, of: second, in: hints)
        _ = try await web.evaluateJavaScript("replacement.querySelector('.badge').replaceChildren(); true")
        try await Task.sleep(for: .milliseconds(150))
        _ = try await web.evaluateJavaScript("replacement.querySelector('.badge').innerHTML = '<svg class=\"SVGIcon_Check\"></svg>'; true")
        try await expect(2, of: second, in: hints)
        let before = hints.batches.count
        _ = try await web.evaluateJavaScript("window.dispatchEvent(new PageTransitionEvent('pageshow', {persisted:true})); true")
        try await expect(3, of: second, in: hints)
        XCTAssertEqual(Set(hints.batches.dropFirst(before).joined()), [id, second])
    }

    func testTrustedQuickSubscribePostsEvenWhenSteamUnmountsTheRowAndLeavesNoBadge() async throws {
        let hints = Hints(), web = webView(for: hints)
        let panel = NSPanel(contentRect: web.frame.offsetBy(dx: -6000, dy: -6000),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = web
        panel.orderBack(nil)
        defer { panel.close() }
        try await load(card(id, checked: false), into: web, at: browse)
        _ = try await web.evaluateJavaScript("""
            const button = document.querySelector('button');
            button.click();
            button.onclick = () => button.closest('.Panel').remove();
            true
            """)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(hints.batches.isEmpty, "Synthetic DOM clicks should never initiate a lookup")
        try await clickSubscribe(in: web, panel: panel)
        try await expect(1, of: id, in: hints)
        let removed = try await web.evaluateJavaScript("document.querySelector('.Panel') === null") as? Bool
        XCTAssertEqual(removed, true)
    }

    private func clickSubscribe(in web: WKWebView, panel: NSPanel) async throws {
        let raw = try await web.evaluateJavaScript("""
            (() => { const r = document.querySelector('button svg').getBoundingClientRect(); return [r.x+r.width/2, r.y+r.height/2] })()
            """)
        let point = try XCTUnwrap(raw as? [Double])
        let target = web.convert(NSPoint(x: point[0], y: web.isFlipped ? point[1] : web.bounds.height - point[1]), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: target, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil,
                eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
            panel.sendEvent(event)
        }
    }

    func testListClickStartsExactlyOneTransferAfterTheHoverCardDisappears() async throws {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let cookie = try XCTUnwrap(HTTPCookie(properties: [
            .name: "steamLoginSecure", .value: "76561198000000001%7C%7Cfixture", .secure: "TRUE",
            .domain: ".steamcommunity.com", .path: "/"
        ]))
        await config.websiteDataStore.httpCookieStore.setCookie(cookie)
        var lookups = 0
        var downloads = [String]()
        let bridge = SteamWorkshopSubscriptionBridge(lookup: { _, _ in nil }, listLookup: { ids, web in
            XCTAssertEqual(ids, [self.id])
            XCTAssertEqual(web.url, self.browse)
            lookups += 1
            if lookups == 1 { return [] } // The POST is still pending at Steam.
            var item = WorkshopWallpaper(id: self.id, title: "Confirmed on list")
            item.isSubscribed = true
            return [item]
        }, onListSubscription: { downloads.append($0.id) }) { item, subscribed in
            if subscribed { downloads.append(item.id) }
        }
        bridge.attach(to: config.userContentController)
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 440, height: 220), configuration: config)
        let panel = NSPanel(contentRect: web.frame.offsetBy(dx: -6000, dy: -6000),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = web
        panel.orderBack(nil)
        defer { panel.close() }
        try await load(card(id, checked: false), into: web, at: browse)
        _ = try await web.evaluateJavaScript("document.querySelector('button').onclick = e => e.currentTarget.closest('.Panel').remove(); true")
        try await clickSubscribe(in: web, panel: panel)
        for _ in 0..<180 where downloads.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(downloads, [id])
        XCTAssertEqual(lookups, 2)
        XCTAssertEqual(web.url, browse)
    }

    func testUnsubscribeDuringListLookupDiscardsThatResult() async throws {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let cookie = try XCTUnwrap(HTTPCookie(properties: [
            .name: "steamLoginSecure", .value: "76561198000000001%7C%7Cfixture", .secure: "TRUE",
            .domain: ".steamcommunity.com", .path: "/"
        ]))
        await config.websiteDataStore.httpCookieStore.setCookie(cookie)
        let web = WKWebView(frame: .zero, configuration: config)
        var pending: CheckedContinuation<[WorkshopWallpaper]?, Never>?
        var delivered: [String] = []
        let sync = SteamWorkshopListDownloadSync(lookup: { _, _ in
            await withCheckedContinuation { pending = $0 }
        }, deliver: { item, _ in delivered.append(item.id) })
        defer { sync.reset() }
        sync.offer([id, second], in: web)
        for _ in 0..<100 where pending == nil { try await Task.sleep(for: .milliseconds(15)) }
        let lookup = try XCTUnwrap(pending)
        sync.forget(id)
        let items = [id, second].map { id in
            var item = WorkshopWallpaper(id: id, title: id)
            item.isSubscribed = true
            return item
        }
        lookup.resume(returning: items)
        for _ in 0..<100 where delivered.isEmpty { try await Task.sleep(for: .milliseconds(15)) }
        XCTAssertEqual(delivered, [second])
    }
}
