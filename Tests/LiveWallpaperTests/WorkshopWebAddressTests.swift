import XCTest
@testable import LiveWallpaper

final class WorkshopWebAddressTests: XCTestCase {
    @MainActor
    func testAddressFieldAcceptsItemIDsAndSteamLinksOrSearchesForText() throws {
        let detail = try XCTUnwrap(WorkshopWebAddress.destination(for: " 3840929200 "))
        XCTAssertEqual(detail.host, "steamcommunity.com")
        XCTAssertEqual(detail.pathComponents.last, "filedetails")
        XCTAssertEqual(WorkshopWebAddress.destination(for: detail.absoluteString), detail)
        XCTAssertEqual(WorkshopWebAddress.destination(for: String(detail.absoluteString.dropFirst("https://".count))), detail)
        XCTAssertNil(WorkshopWebAddress.destination(for: "https://steamcommunity.com.example.org/"))
        XCTAssertNil(WorkshopWebAddress.destination(for: "   "))
        XCTAssertNil(WorkshopWebAddress.detailURL("１２３４５６"))

        let search = try XCTUnwrap(WorkshopWebAddress.destination(for: " Re:Zero C++ & 海 "))
        let items = try XCTUnwrap(URLComponents(url: search, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertTrue(items.contains(URLQueryItem(name: "searchtext", value: "Re:Zero C++ & 海")))
        XCTAssertTrue(search.absoluteString.contains("C%2B%2B"))
        XCTAssertEqual(WorkshopWebAddress.currentPage(at: search), 1)
    }

    @MainActor
    func testPageJumpPreservesSteamFiltersSortAndSearchEncoding() throws {
        let original = try XCTUnwrap(URL(string: "https://steamcommunity.com/workshop/browse/?appid=431960&requiredtags%5B%5D=Anime&requiredtags%5B%5D=Everyone&searchtext=hi+there%2B&browsesort=trend&p=2"))
        let page = try XCTUnwrap(WorkshopWebAddress.pageURL(" 17 ", from: original))
        XCTAssertEqual(WorkshopWebAddress.currentPage(at: page), 17)
        XCTAssertEqual(page.absoluteString, original.absoluteString.replacingOccurrences(of: "&p=2", with: "&p=17"))
        for input in ["0", "-1", "1.5", "abc"] {
            XCTAssertNil(WorkshopWebAddress.pageURL(input, from: original))
        }
        XCTAssertNil(WorkshopWebAddress.pageURL("2", from: try XCTUnwrap(WorkshopWebAddress.detailURL("3840929200"))))
        XCTAssertNil(WorkshopWebAddress.pageURL("2", from: try XCTUnwrap(URL(string: "https://steamcommunity.com/workshop/browse/?appid=440"))))
    }

    @MainActor
    func testHomeShelfOpensMatchingSortAndRating() throws {
        for sort in WorkshopFeed.Sort.allCases {
            let url = WorkshopWebAddress.browseURL(for: sort)
            let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
            XCTAssertTrue(items.contains(URLQueryItem(name: "requiredtags[]", value: "Everyone")))
            XCTAssertTrue(items.contains(URLQueryItem(name: "browsesort", value: sort.browseValue)))
            XCTAssertEqual(items.first { $0.name == "days" }?.value, sort.browseDays.map(String.init))
        }
    }
}
