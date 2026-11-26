import WebKit
import XCTest
@testable import LiveWallpaper

@MainActor
final class SteamWorkshopSubscriptionStatusTests: XCTestCase {
    private let id = "3842424536"
    private let account = "76561198000000001"

    private func serverDetail(accountID: String?, subscribed: Bool) -> String {
        """
        <script>var g_steamID = \(accountID.map { "'\($0)'" } ?? "false");</script>
        <div class="workshopItemTitle">Detail fixture</div>
        <div id="profileBlock"><div class="game_area_purchase_game">
        <a id="SubscribeItemBtn" onclick="SubscribeItem('\(id)', '431960');" class="\(subscribed ? "toggled" : "")">
          <span id="SubscribeItemOptionAdd" class="\(subscribed ? "" : "selected")"></span>
          <span id="SubscribeItemOptionSubscribed" class="\(subscribed ? "selected" : "")"></span>
        </a></div></div>
        """
    }

    private func query(status: [String: Any]?, app: Int = 431960, html: String = "",
                       unavailable: Bool = false, signedIn: Bool = true, switchAccount: Bool = false) async throws -> WorkshopWallpaper? {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        if signedIn {
            let store = config.websiteDataStore.httpCookieStore
            for (name, value) in [("sessionid", "fixture-session"), ("steamLoginSecure", account + "%7C%7Ctest-cookie")] {
                let cookie = try XCTUnwrap(HTTPCookie(properties: [.name: name, .value: value, .domain: ".steamcommunity.com",
                                                                   .path: "/", .secure: "TRUE"]))
                await store.setCookie(cookie)
            }
        }
        let web = WKWebView(frame: .zero, configuration: config)
        web.loadHTMLString("<html><meta http-equiv='Content-Security-Policy' content=\"connect-src 'none'\"></html>",
                           baseURL: URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=\(id)"))
        for _ in 0..<100 where web.isLoading { try await Task.sleep(nanoseconds: 30_000_000) }

        let mocks: [String: Any] = ["id": id, "app": app, "rows": status.map { [$0] } ?? [],
                                    "html": html, "unavailable": unavailable, "hold": switchAccount]
        _ = try await web.callAsyncJavaScript("""
            window.fixtureCalls = [];
            const gate = hold ? new Promise(resolve => { window.releaseFixture = resolve; }) : Promise.resolve();
            window.fetch = async (address, options) => {
                const url = new URL(address);
                const method = options.method || 'GET';
                window.fixtureCalls.push([url.origin, method]);
                await gate;
                if (url.pathname === '/sharedfiles/filedetails/')
                    return new Response(html, { status: html ? 200 : 503 });
                if (unavailable) return new Response('{"success":21}', {status:500});
                const summary = [{publishedfileid:id, consumer_appid:app, file_type:0, title:'Summary fixture', file_size:'173'}];
                const data = url.searchParams.get('q') === 'GetUGCSummary' ? summary : rows;
                return new Response(JSON.stringify({data}));
            };
            return true;
            """, arguments: mocks, in: nil, contentWorld: .defaultClient)
        let lookup = Task { await SteamWorkshopSubscriptionStatus.lookup(id: id, in: web) }
        if switchAccount {
            for _ in 0..<100 {
                let count = try await web.callAsyncJavaScript("return window.fixtureCalls.length", arguments: [:],
                                                              in: nil, contentWorld: .defaultClient)
                if (count as? Int) == 2 { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            let replacement = try XCTUnwrap(HTTPCookie(properties: [.name: "steamLoginSecure",
                .value: "76561198000000002%7C%7Cother-test-cookie", .domain: ".steamcommunity.com", .path: "/", .secure: "TRUE"]))
            await config.websiteDataStore.httpCookieStore.setCookie(replacement)
            _ = try await web.callAsyncJavaScript("window.releaseFixture(); return true", arguments: [:],
                                                 in: nil, contentWorld: .defaultClient)
        }
        let result = await lookup.value
        let calls = try await web.callAsyncJavaScript("return window.fixtureCalls", arguments: [:], in: nil, contentWorld: .defaultClient)
        let requests = try XCTUnwrap(calls as? [[String]])
        if signedIn { XCTAssertGreaterThanOrEqual(requests.count, 2) } else { XCTAssertTrue(requests.isEmpty) }
        XCTAssertTrue(requests.allSatisfy { $0 == ["https://steamcommunity.com", "GET"] })
        return result
    }

    func testExplicitStatusMatchesRequestedWallpaperAndApp() async throws {
        for subscribed in [true, false] {
            let result = try await query(status: ["publishedfileid": id, "inlist": subscribed])
            XCTAssertEqual(result?.isSubscribed, subscribed)
            XCTAssertEqual(result?.title, "Summary fixture")
            XCTAssertEqual(result?.sizeBytes, 173)
        }
        let otherApp = try await query(status: ["publishedfileid": id, "inlist": true], app: 480)
        XCTAssertNil(otherApp)
        let otherItem = try await query(status: ["publishedfileid": "3842432893", "inlist": true])
        XCTAssertNil(otherItem)
        let switched = try await query(status: ["publishedfileid": id, "inlist": true], switchAccount: true)
        XCTAssertNil(switched)
    }

    func testMissingFieldRequiresDetailForCurrentAccount() async throws {
        for subscribed in [true, false] {
            let result = try await query(status: ["publishedfileid": id],
                                         html: serverDetail(accountID: account, subscribed: subscribed))
            XCTAssertEqual(result?.isSubscribed, subscribed)
            XCTAssertEqual(result?.title, "Detail fixture")
        }
        let signedOut = try await query(status: nil, html: serverDetail(accountID: nil, subscribed: false), unavailable: true)
        XCTAssertNil(signedOut)
        let differentAccount = try await query(status: nil, html: serverDetail(accountID: "76561198000000002", subscribed: false))
        XCTAssertNil(differentAccount)
        let guest = try await query(status: ["publishedfileid": id, "inlist": true], signedIn: false)
        XCTAssertNil(guest)
        let unavailable = try await query(status: nil, unavailable: true)
        XCTAssertNil(unavailable)
    }
}
