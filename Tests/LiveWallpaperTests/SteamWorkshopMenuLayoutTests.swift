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

    func testScrollingFilteredBrowseKeepsSidebarMenuAttachedInBothDirections() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        SteamWorkshopMenuLayout.install(in: configuration.userContentController)
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 900, height: 580), configuration: configuration)
        web.loadHTMLString("""
            <style>
              body { margin:0; height:2600px }
              .Panel { margin:200px 0 0 24px; width:300px; height:1500px;
                       backdrop-filter:blur(2px); -webkit-backdrop-filter:blur(2px) }
              .filter { padding:560px 10px 0 }
              #trigger { width:280px; height:36px }
              #menu { display:none; position:fixed; top:0; left:0; width:280px; height:132px }
              #menu[class~=":popover-open"] { display:block }
              [role="option"] { height:33px }
            </style>
            <div class="Panel"><div class="filter">
              <div role="combobox" id="trigger" aria-controls="menu">Age Rating</div>
              <div role="listbox" id="menu"><div role="option" id="everyone">Everyone</div></div>
            </div></div>
            <script>
              const trigger = document.getElementById('trigger'), menu = document.getElementById('menu');
              function place() {
                const r = trigger.getBoundingClientRect();
                const y = r.bottom + 2 + menu.offsetHeight <= innerHeight ? r.bottom + 2 : r.top - 2 - menu.offsetHeight;
                menu.style.transform = 'translate(' + r.left + 'px,' + y + 'px)';
              }
              window.addEventListener('scroll', place);
            </script>
            """, baseURL: URL(string: "https://steamcommunity.com/workshop/browse/?appid=431960&requiredtags%5B%5D=Questionable"))
        for _ in 0..<100 where web.isLoading { try await Task.sleep(for: .milliseconds(30)) }
        _ = try await web.evaluateJavaScript("menu.classList.add(':popover-open'); true")
        for scroll in [440, 540, 280, 500] {
            let values = try await web.evaluateJavaScript("""
                (() => {
                    window.scrollTo(0, \(scroll)); place();
                    const b = trigger.getBoundingClientRect(), m = menu.getBoundingClientRect();
                    const hit = document.elementFromPoint(m.left + 10, m.top + 10);
                    return [scrollY, m.left - b.left, m.top - b.bottom, b.top - m.bottom,
                            hit?.id === 'everyone' ? 1 : 0];
                })()
                """)
            let position = try XCTUnwrap(values as? [Double])
            XCTAssertEqual(position[0], Double(scroll), accuracy: 0.5)
            XCTAssertEqual(position[1], 0, accuracy: 0.5)
            XCTAssertEqual(scroll == 280 ? position[3] : position[2], 2, accuracy: 0.5)
            XCTAssertEqual(position[4], 1)
        }
        let restored = try await web.evaluateJavaScript("""
            menu.classList.remove(':popover-open');
            getComputedStyle(menu.closest('.Panel')).getPropertyValue('-webkit-backdrop-filter') === 'blur(2px)' ||
                getComputedStyle(menu.closest('.Panel')).backdropFilter === 'blur(2px)'
            """)
        XCTAssertEqual(restored as? Bool, true)
    }

    func testBrowseSortAndSearchScopeMenusUseTheirSteamAnchors() async throws {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        SteamWorkshopMenuLayout.install(in: config.userContentController)
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 920, height: 640), configuration: config)
        web.loadHTMLString("""
            <style>
              body { margin:0; height:1800px }
              #bar { margin-top:400px; display:flex; justify-content:space-between; padding:0 30px }
              [role=button] { height:36px; width:150px }
              .positioner { inset:0; margin:auto; border:0; padding:0; width:250px; height:150px }
              .positioner:not([popover]):not([class~=":popover-open"]) { display:none }
              [role=radio] { height:30px }
            </style>
            <div id="bar">
              <div><form><input name="SearchInput"></form>
                <div class="Panel" id="scope" role="button" tabindex="0">⚙</div>
                <div class="positioner" data-floating-ui-focusable style="position:fixed;left:0;top:0"><div>
                  <div role="radiogroup" data-param="search_text_target">
                    <div role="radio" data-radio-id="0">标题与描述</div>
                    <div role="radio" data-radio-id="1">仅限标题</div>
                    <div role="radio" data-radio-id="2">仅限描述</div>
                  </div>
                </div></div>
              </div>
              <div><div class="Panel" id="sort" role="button" tabindex="0">最热门（1 周）</div>
                <div class="positioner" data-floating-ui-focusable style="position:fixed;left:0;top:0"><div><div class="Panel">
                  <div role="radiogroup" data-param="browsesort">
                    <div role="radio" data-radio-id="trend">最热门</div>
                    <div role="radio" data-radio-id="mostrecent">最新</div>
                  </div>
                  <div role="radiogroup" data-param="days"><div role="radio" data-radio-id="7">1 周</div></div>
                </div></div></div>
              </div>
            </div>
            <div id="modal" popover="manual" style="position:fixed;width:80px;height:40px;
              margin:auto;inset:0;border:0;padding:0" role="dialog"><div role="radiogroup">
              <div role="radio" data-radio-id="other">Other</div></div></div>
            <script>
              document.addEventListener('click', event => {
                const radio = event.target.closest('[role=radio]');
                if (radio) {
                  const u = new URL(location.href);
                  u.searchParams.set(radio.parentElement.dataset.param, radio.dataset.radioId);
                  history.replaceState(null, '', u);
                }
              });
            </script>
            """, baseURL: URL(string: "https://steamcommunity.com/workshop/browse/?appid=431960&searchtext=test"))
        for _ in 0..<100 where web.isLoading { try await Task.sleep(for: .milliseconds(30)) }
        let nativePopover = try await web.evaluateJavaScript("typeof HTMLElement.prototype.showPopover === 'function'") as? Bool
        for native in (nativePopover == true ? [false, true] : [false]) {
            for (id, parameter, value) in [("sort", "browsesort", "mostrecent"), ("scope", "search_text_target", "1")] {
                let result = try await web.callAsyncJavaScript("""
                    const button = document.getElementById(id), menu = button.nextElementSibling;
                    if (native) { menu.setAttribute('popover', 'manual'); menu.showPopover(); }
                    else menu.classList.add(':popover-open');
                    const index = Array.from(menu.querySelectorAll('[role=radio]')).findIndex(r => r.dataset.radioId === value);
                    const selected = [];
                    for (const scroll of [250, 350]) {
                      window.scrollTo(0, scroll);
                      const rect = button.getBoundingClientRect();
                      const left = id === 'sort' ? rect.right - menu.offsetWidth : rect.left;
                      menu.style.transform = 'translate(' + left + 'px,' + rect.bottom + 'px)';
                      const hit = document.elementFromPoint(left + 12, rect.bottom + index * 30 + 12);
                      selected.push(hit?.closest('[role=radio]')?.dataset.radioId ?? '');
                      hit?.click();
                    }
                    if (native) { menu.hidePopover(); menu.removeAttribute('popover'); }
                    else menu.classList.remove(':popover-open');
                    const query = new URL(location.href).searchParams;
                    return [...selected, query.get(parameter) ?? '', query.get('searchtext') ?? ''];
                    """, arguments: ["id": id, "parameter": parameter, "value": value, "native": native],
                    in: nil, contentWorld: .page)
                XCTAssertEqual(result as? [String], [value, value, value, "test"], "\(id), native popover: \(native)")
            }
        }
        if nativePopover == true {
            let centered = try await web.evaluateJavaScript("""
                modal.showPopover();
                const r = modal.getBoundingClientRect();
                [r.left, r.top]
                """) as? [Double]
            XCTAssertEqual(centered, [420, 300], "A centered modal with radio controls keeps its own placement")
        }
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
