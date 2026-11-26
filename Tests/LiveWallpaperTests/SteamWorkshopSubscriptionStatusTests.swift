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
        try await queryRows(rows: status.map { [$0] } ?? [], app: app, html: html, unavailable: unavailable,
                            signedIn: signedIn, switchAccount: switchAccount)?.first
    }

    private func queryRows(rows: [[String: Any]], batch: [String]? = nil, app: Int = 431960, html: String = "",
                           unavailable: Bool = false, signedIn: Bool = true,
                           switchAccount: Bool = false) async throws -> [WorkshopWallpaper]? {
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
                           baseURL: batch == nil ? URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=\(id)") :
                                                    URL(string: "https://steamcommunity.com/workshop/browse/?appid=431960"))
        for _ in 0..<100 where web.isLoading { try await Task.sleep(nanoseconds: 30_000_000) }

        let mocks: [String: Any] = ["app": app, "rows": rows,
                                    "html": html, "unavailable": unavailable, "hold": switchAccount]
        _ = try await web.callAsyncJavaScript("""
            window.fixtureCalls = [];
            const gate = hold ? new Promise(resolve => { window.releaseFixture = resolve; }) : Promise.resolve();
            window.fetch = async (address, options) => {
                const url = new URL(address);
                const method = options.method || 'GET';
                window.fixtureCalls.push([url.origin, method, url.searchParams.get('q') || url.pathname, url.searchParams.get('qp') || '']);
                await gate;
                if (url.pathname === '/sharedfiles/filedetails/')
                    return new Response(html, { status: html ? 200 : 503 });
                if (unavailable) return new Response('{"success":21}', {status:500});
                const params = JSON.parse(url.searchParams.get('qp'));
                const summary = url.searchParams.get('q') === 'GetUGCSummary'
                    ? params[0].map(i => ({publishedfileid:i, consumer_appid:app, file_type:0, title:'Summary fixture', file_size:'173'}))
                    : [];
                const data = url.searchParams.get('q') === 'GetUGCSummary' ? summary : rows;
                return new Response(JSON.stringify({data}));
            };
            return true;
            """, arguments: mocks, in: nil, contentWorld: .defaultClient)
        let lookup = Task { () -> [WorkshopWallpaper]? in
            if let batch { return await SteamWorkshopSubscriptionStatus.subscribedItems(ids: batch, in: web) }
            return await SteamWorkshopSubscriptionStatus.lookup(id: id, in: web).map { [$0] }
        }
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
        XCTAssertTrue(requests.allSatisfy { $0.prefix(2) == ["https://steamcommunity.com", "GET"] })
        if let batch, signedIn {
            let statusRequests = requests.filter { $0[2] == "GetUserListStatus" }
            let summaries = requests.filter { $0[2] == "GetUGCSummary" }
            XCTAssertEqual(statusRequests.count, 1)
            XCTAssertEqual(summaries.count, 1)
            let statusRequest = try XCTUnwrap(statusRequests.first)
            let parameters = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(statusRequest[3].utf8)) as? [Any])
            let sentIDs = try XCTUnwrap(parameters.last as? [String])
            XCTAssertEqual(Set(sentIDs), Set(batch))
            XCTAssertEqual(sentIDs.count, Set(batch).count)
            XCTAssertLessThanOrEqual(requests.filter { $0[2] == "/sharedfiles/filedetails/" }.count, 2)
        }
        return result
    }

    func testBatchDeliversConfirmedSubscribersEvenWhenOtherRowsAreMissing() async throws {
        let missing = "3844145761", unsubscribed = "3842432893", unrequested = "3843425147"
        let ids = [id, missing, unsubscribed, id]
        let rows: [[String: Any]] = [
            ["publishedfileid": unrequested, "inlist": true],
            ["publishedfileid": unsubscribed, "inlist": false],
            ["publishedfileid": id, "inlist": true]
        ]
        let items = try await queryRows(rows: rows, batch: ids)
        XCTAssertEqual(items?.map(\.id), [id])
        XCTAssertEqual(items?.first?.sizeBytes, 173)
        let switched = try await queryRows(rows: rows, batch: ids, switchAccount: true)
        XCTAssertNil(switched)
        let guest = try await queryRows(rows: rows, batch: ids, signedIn: false)
        XCTAssertNil(guest)
        let inconclusive = try await queryRows(rows: [], batch: ids, unavailable: true)
        XCTAssertNil(inconclusive)
        let recovered = try await queryRows(rows: [], batch: ids, html: serverDetail(accountID: account, subscribed: true),
                                            unavailable: true)
        XCTAssertEqual(recovered?.map(\.id), [id])
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
