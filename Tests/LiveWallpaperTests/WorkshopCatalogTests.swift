import XCTest
@testable import LiveWallpaper

final class WorkshopCatalogTests: XCTestCase {
    func testParsesSteamResultsAndIgnoresCollectionsAndOtherApplications() throws {
        let data = Data(#"""
        {"eresult":1,"current_page":2,"total_pages":8,"total_count":221,"results":[{"publishedfileid":"1234567890","consumer_appid":431960,"file_type":0,"title":"Fixture","creator":"76561198000000001","preview_url":"https://images.steamusercontent.com/ugc/test/","file_size":"1048576","tags":[{"tag":"Scene"}],"subscriptions":42},{"publishedfileid":"1234567890","consumer_appid":431960,"title":"Duplicate"},{"publishedfileid":"1234567891","consumer_appid":123,"title":"Wrong app"},{"publishedfileid":"1234567892","consumer_appid":431960,"file_type":2,"title":"Collection"}],"creator_player_link_details":[{"public_data":{"steamid":"76561198000000001","persona_name":"Author"}}]}
        {"metrics":"ignored"}
        """#.utf8)
        let page = try WorkshopCatalogService.parsePage(data)
        XCTAssertEqual(page.items.count, 1)
        XCTAssertEqual(page.items.first?.author, "Author")
        XCTAssertEqual(page.items.first?.sizeBytes, 1_048_576)
        XCTAssertEqual(page.items.first?.tags, ["Scene"])
        XCTAssertEqual(page.page, 2)
        XCTAssertEqual(page.totalPages, 8)
        XCTAssertEqual(page.total, 221)
    }

    func testFailedServerResponseIsNotPresentedAsAnEmptyCatalog() {
        XCTAssertThrowsError(try WorkshopCatalogService.parsePage(Data(#"{"eresult":2,"results":[]}"#.utf8)))
        XCTAssertThrowsError(try WorkshopCatalogService.parsePage(Data("<html>Service unavailable</html>".utf8)))
    }

    func testDiscoversCurrentActionWithoutHardcodingBundleOrActionHash() {
        XCTAssertEqual(WorkshopCatalogService.discoverBrowseAction("Actions:{Browse:x(`current_route_123`,`Browse`)}"), "current_route_123")
        XCTAssertNil(WorkshopCatalogService.discoverBrowseAction("Actions:{Subscribe:x(`other`,`Subscribe`)}"))
        let urls = WorkshopCatalogService.scriptURLs("""
        <script src="https://cdn.fastly.steamstatic.com/steamcommunity/public/ssr/current.js"></script>
        <script src="https://evilsteamstatic.com/steamcommunity/public/ssr/evil.js"></script>
        <script src="http://cdn.fastly.steamstatic.com/steamcommunity/public/ssr/insecure.js"></script>
        """)
        XCTAssertEqual(urls.map(\.lastPathComponent), ["current.js"])
    }

    func testTagGroupsDecodeStringifiedSteamLoaderData() throws {
        let loader: [String: Any] = ["declaredTags": ["readytouse_tags": [["name": "Age Rating", "tags": [
            ["name": "Everyone", "display_name": "所有人", "admin_only": false],
            ["name": "Internal", "display_name": "Internal", "admin_only": true]]]]]]
        let text = String(decoding: try JSONSerialization.data(withJSONObject: loader), as: UTF8.self)
        let root = try JSONSerialization.data(withJSONObject: ["loaderData": [text]])
        let html = "<script id=\"valve-ssr-data\" type=\"application/json\">\(String(decoding: root, as: UTF8.self))</script>"
        let groups = WorkshopCatalogService.parseTagGroups(html)
        XCTAssertEqual(groups.first?.title, "内容分级")
        XCTAssertEqual(groups.first?.tags.map(\.id), ["Everyone"])
    }

    func testQueryRetainsSearchTagsAndPagination() {
        let query = WorkshopQuery(search: "ocean", sort: "trend", tags: ["Video", "Everyone"], page: 3)
        XCTAssertEqual(query.parameters["browse_sort"] as? String, "textsearch")
        XCTAssertEqual(query.parameters["required_tags"] as? [String], ["Video", "Everyone"])
        XCTAssertEqual(query.parameters["page"] as? Int, 3)
    }

    func testLegacyDetailRetainsNestedDescriptionAndChecksApplication() {
        let html = """
        <div class="workshopItemTitle">Ocean &amp; Sky</div>
        <img id="previewImageMain" src="https://images.steamusercontent.com/preview.jpg?a=1&amp;b=2">
        <div class="friendBlockContent">Author<br></div>
        <a onclick="SubscribeItem('1234567890', '431960');"></a>
        <div class="detailsStatRight">1.5 MB</div>
        <div class="workshopItemDescription" id="highlightContent">First<div>Nested</div><br>Last</div>
        """
        let item = WorkshopCatalogService.parseLegacyDetail(html, id: "1234567890")
        XCTAssertEqual(item?.title, "Ocean & Sky")
        XCTAssertTrue(item?.summary.contains("Last") == true)
        XCTAssertEqual(item?.sizeBytes, 1_500_000)
        XCTAssertEqual(item?.previewURL?.query, "a=1&b=2")
        XCTAssertNil(WorkshopCatalogService.parseLegacyDetail(html.replacingOccurrences(of: "431960", with: "123"), id: "1234567890"))
    }

    @MainActor
    func testDirectItemLinksRequireSteamOrigin() {
        XCTAssertEqual(WorkshopBrowserModel.itemID(from: "https://steamcommunity.com/sharedfiles/filedetails/?id=1234567890"), "1234567890")
        XCTAssertNil(WorkshopBrowserModel.itemID(from: "https://example.com/sharedfiles/filedetails/?id=1234567890"))
        XCTAssertNil(WorkshopBrowserModel.itemID(from: "https://steamcommunity.com.evil.test/sharedfiles/filedetails/?id=1234567890"))
    }

    func testLiveCatalogSearchAndPagination() async throws {
        guard ProcessInfo.processInfo.environment["LW_WORKSHOP_CATALOG_INTEGRATION"] == "1" else {
            throw XCTSkip("Optional public Steam catalog integration")
        }
        let service = WorkshopCatalogService()
        let tags = try await service.tagGroups()
        XCTAssertTrue(tags.contains { $0.id == "Age Rating" })
        let first = try await service.browse(WorkshopQuery(tags: ["Everyone"]))
        XCTAssertFalse(first.items.isEmpty)
        XCTAssertEqual(first.page, 1)
        let second = try await service.browse(WorkshopQuery(tags: ["Everyone"], page: 2))
        XCTAssertEqual(second.page, 2)
        XCTAssertNotEqual(first.items.map(\.id), second.items.map(\.id))
        let search = try await service.browse(WorkshopQuery(search: "ocean", tags: ["Everyone", "Scene"]))
        XCTAssertFalse(search.items.isEmpty)
        XCTAssertTrue(search.items.allSatisfy { $0.tags.contains("Scene") })
        if let item = first.items.first {
            let detail = try await service.detail(id: item.id)
            XCTAssertEqual(detail.id, item.id)
            XCTAssertFalse(detail.title.isEmpty)
        }
    }
}
