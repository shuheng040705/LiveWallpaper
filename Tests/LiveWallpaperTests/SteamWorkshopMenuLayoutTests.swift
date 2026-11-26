import WebKit
import XCTest
@testable import LiveWallpaper

@MainActor
final class SteamWorkshopMenuLayoutTests: XCTestCase {
    func testTopLayerMenuKeepsSteamPositionAndRespondsToNewPlacement() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        SteamWorkshopMenuLayout.install(in: configuration.userContentController)
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 1510, height: 800), configuration: configuration)
        web.loadHTMLString("""
            <style>[popover] { inset: 0; margin: auto; padding: 0; border: 0 }</style>
            <div role="combobox" aria-controls="ratings" style="position:fixed;left:34px;top:191px">Age Rating</div>
            <div role="listbox" id="ratings" popover="manual" style="position:fixed;left:0;top:0;
              width:280px;height:132px;transform:translate(34px,229px);will-change:transform">
              <div role="option">Everyone</div>
            </div>
            <div role="dialog" id="unrelated" popover="manual" style="position:fixed;left:0;top:0;
              width:80px;height:50px;transform:translate(1px,2px)"></div>
            """, baseURL: URL(string: "https://steamcommunity.com/app/431960/workshop/"))
        for _ in 0..<100 where web.isLoading { try await Task.sleep(nanoseconds: 30_000_000) }
        let supportsPopover = try await web.evaluateJavaScript("typeof document.documentElement.showPopover === 'function'") as? Bool
        try XCTSkipUnless(supportsPopover == true, "This WebKit has no HTML popover top layer")
        _ = try await web.evaluateJavaScript("document.getElementById('ratings').showPopover(); true")
        try await checkPosition(in: web, x: 34, y: 229)

        web.frame.size = CGSize(width: 920, height: 660)
        _ = try await web.evaluateJavaScript("document.getElementById('ratings').style.transform = 'translate(23.5px, 107px)'; true")
        try await checkPosition(in: web, x: 23.5, y: 107)
        let unrelatedPosition = try await web.evaluateJavaScript("""
            const another = document.getElementById('unrelated');
            another.showPopover(); const rect = another.getBoundingClientRect();
            [rect.left, rect.top]
            """) as? [Double]
        XCTAssertEqual(unrelatedPosition, [421, 307])
    }

    func testSteamCompatibilityPopoverStaysAtItsButtonWithoutNativeToggleEvent() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        SteamWorkshopMenuLayout.install(in: configuration.userContentController)
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 1510, height: 804), configuration: configuration)
        web.loadHTMLString("""
            <style>
              [role="listbox"] { inset:0; margin:auto; padding:0; border:0; }
              #ratings { display:none }
              #ratings[class~=":popover-open"] { display:block }
              [role="option"] { height:32px }
            </style>
            <div id="trigger" role="combobox" aria-controls="ratings" aria-expanded="false"
                 style="position:fixed;left:34px;top:191px;width:280px;height:36px">Age Rating</div>
            <div id="ratings" role="listbox"
                 style="position:fixed;left:0;top:0;width:280px;height:132px;transform:translate(34px,229px)">
                <div id="everyone" role="option">Everyone</div>
            </div>
            <div id="unrelated" role="listbox"
                 style="position:fixed;left:0;top:0;width:80px;height:50px;transform:translate(1px,2px)"></div>
            """, baseURL: URL(string: "https://steamcommunity.com/workshop/browse/?appid=431960"))
        for _ in 0..<100 where web.isLoading { try await Task.sleep(for: .milliseconds(30)) }
        // Steam's fallback opens through a literal class. It never calls the browser's showPopover().
        _ = try await web.evaluateJavaScript("""
            const anchor = document.getElementById('trigger'), menu = document.getElementById('ratings');
            function openFallback(node) { node.classList.add(':popover-open'); }
            anchor.setAttribute('aria-expanded', 'true');
            openFallback(menu); true
            """)
        try await checkFallbackPosition(in: web)
        _ = try await web.evaluateJavaScript("""
            anchor.style.left = '66px'; anchor.style.top = '301px';
            menu.style.transform = 'translate(66px,339px)'; true
            """)
        try await checkFallbackPosition(in: web)
        let unrelated = try await web.evaluateJavaScript("""
            (() => { const r = document.getElementById('unrelated').getBoundingClientRect();
                     return [r.left, r.top] })()
            """) as? [Double]
        XCTAssertEqual(unrelated, [716, 379])
    }

    private func checkFallbackPosition(in web: WKWebView) async throws {
        var measured: [Double] = []
        for _ in 0..<35 {
            let raw = try await web.evaluateJavaScript("""
                (() => {
                    const button = document.getElementById('trigger').getBoundingClientRect();
                    const list = document.getElementById('ratings').getBoundingClientRect();
                    const hit = document.elementFromPoint(button.left + 12, button.bottom + 12);
                    return [list.left - button.left, list.top - button.bottom, hit?.id === 'everyone' ? 1 : 0];
                })()
                """)
            measured = try XCTUnwrap(raw as? [Double])
            if measured == [0, 2, 1] { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(measured, [0, 2, 1], "The fallback option must be painted and hit-tested beside its own button")
    }

    private func checkPosition(in web: WKWebView, x: Double, y: Double) async throws {
        let snapshot = try await web.evaluateJavaScript("""
            (() => {
              const m = document.getElementById('ratings'), r = m.getBoundingClientRect();
              return [r.left, r.top, m.contains(document.elementFromPoint(r.left + 8, r.top + 8)) ? 1 : 0];
            })()
            """)
        let values = try XCTUnwrap(snapshot as? [Double])
        XCTAssertEqual(values.count, 3)
        guard values.count == 3 else { return }
        XCTAssertEqual(values[0], x, accuracy: 0.5)
        XCTAssertEqual(values[1], y, accuracy: 0.5)
        XCTAssertEqual(values[2], 1)
    }
}
