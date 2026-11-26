import AppKit
import WebKit
import XCTest
@testable import LiveWallpaper

@MainActor
final class SteamWorkshopSubscriptionBridgeTests: XCTestCase {
    private let id = "3840929200"
    private let url = URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=3840929200")!

    /// Steam's legacy template flips all three classes only when the request succeeds.
    private func page() -> String {
        """
        <meta http-equiv="Content-Security-Policy" content="connect-src 'none'">
        <style>#SubscribeItemBtn { display: block; width: 180px; height: 40px; }</style>
        <div class="workshopItemDetailsHeader"><div class="workshopItemTitle">Fixture</div></div>
        <div id="profileBlock"><div class="detailBox"><div class="game_area_purchase_margin">
          <div class="game_area_purchase_game"><div>
            <a id="SubscribeItemBtn" onclick="SubscribeItem('\(id)', '431960');">
              <span id="SubscribeItemOptionAdd" class="selected">Subscribe</span>
              <span id="SubscribeItemOptionSubscribed">Subscribed</span>
            </a>
          </div></div>
        </div></div></div>
        <script>
          let success = true, clickCount = 0;
          function SubscribeItem() {
              clickCount++;
              if (!success) return;
              const subscribed = document.querySelector('#SubscribeItemBtn').classList.toggle('toggled');
              document.querySelector('#SubscribeItemOptionAdd').classList.toggle('selected', !subscribed);
              document.querySelector('#SubscribeItemOptionSubscribed').classList.toggle('selected', subscribed);
          }
        </script>
        """
    }

    private func waitFor(_ result: @escaping () -> Bool) async throws {
        for _ in 0..<120 {
            if result() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("WebKit did not publish the expected detail state")
    }

    func testDetailSnapshotsRequireATrustedClickAndSteamConfirmation() async throws {
        var changes: [Bool] = []
        var confirmedAfterNavigation = false
        let bridge = SteamWorkshopSubscriptionBridge(lookup: { id, web in
            guard confirmedAfterNavigation, web.url?.path == "/workshop/browse" else { return nil }
            var item = WorkshopWallpaper(id: id, title: "Verified after navigation")
            item.isSubscribed = true
            return item
        }, onChange: { item, subscribed in
            XCTAssertEqual(item.id, self.id)
            XCTAssertEqual(item.isSubscribed, subscribed)
            changes.append(subscribed)
        })
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        bridge.attach(to: config.userContentController)
        let rect = CGRect(x: 0, y: 0, width: 450, height: 250)
        let web = WKWebView(frame: rect, configuration: config)
        let win = NSPanel(contentRect: rect.offsetBy(dx: -6000, dy: -6000), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.contentView = web
        win.orderBack(nil)
        defer { win.close() }

        web.loadHTMLString(page(), baseURL: url)
        try await waitFor { bridge.detail(for: self.url)?.isSubscribed == false }
        XCTAssertEqual(bridge.detail(for: url)?.title, "Fixture")
        XCTAssertTrue(changes.isEmpty)

        func click() async throws {
            let raw = try await web.evaluateJavaScript("""
                (() => { const r = document.querySelector('#SubscribeItemBtn').getBoundingClientRect();
                    return [r.x + r.width / 2, r.y + r.height / 2]; })()
                """)
            let xy = try XCTUnwrap(raw as? [Double])
            let point = web.convert(NSPoint(x: xy[0], y: web.isFlipped ? xy[1] : web.bounds.height - xy[1]), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: win.windowNumber, context: nil,
                    eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
                win.sendEvent(event)
            }
        }

        try await click()
        try await waitFor { changes == [true] }
        _ = try await web.evaluateJavaScript("success = false")
        try await click()
        var count = 0
        for _ in 0..<120 {
            count = try await web.evaluateJavaScript("clickCount") as? Int ?? 0
            if count == 2 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(count, 2)
        XCTAssertEqual(bridge.detail(for: url)?.isSubscribed, true)
        XCTAssertEqual(changes, [true])

        _ = try await web.evaluateJavaScript("success = true; document.querySelector('#SubscribeItemBtn').click(); true")
        try await waitFor { bridge.detail(for: self.url)?.isSubscribed == false }
        XCTAssertEqual(changes, [true], "A script click must not inherit the previous rejected unsubscribe")
        try await click()
        try await waitFor { changes == [true, true] }
        try await click()
        try await waitFor { changes == [true, true, false] }
        _ = try await web.evaluateJavaScript("success = false; clickCount = 0")
        try await click()
        for _ in 0..<100 {
            if (try? await web.evaluateJavaScript("clickCount")) as? Int == 1 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        // The request was accepted on Steam, but its old document never got the success callback.
        confirmedAfterNavigation = true
        bridge.clearDetail()
        web.loadHTMLString("<p>Browse</p>", baseURL: URL(string: "https://steamcommunity.com/workshop/browse/?appid=431960"))
        try await waitFor { changes == [true, true, false, true] }
        XCTAssertNil(bridge.detail(for: url))
    }

    func testDetailIdentityRejectsUnrelatedPagesAndAmbiguousIDs() {
        XCTAssertEqual(SteamWorkshopSubscriptionBridge.itemID(in: url), id)
        for address in ["https://example.org/sharedfiles/filedetails/?id=3840929200",
                        "https://steamcommunity.com/workshop/browse/?id=3840929200",
                        "https://steamcommunity.com/sharedfiles/filedetails/?id=3840929200&id=3842432893"] {
            XCTAssertNil(SteamWorkshopSubscriptionBridge.itemID(in: URL(string: address)))
        }
    }
}
