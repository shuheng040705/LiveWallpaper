import XCTest
import Combine
@testable import LiveWallpaper

private actor CatalogTestServer {
    var disconnectedScripts = 0
    var failQueries = false
    var failPageTwo = false
    var calls: [String: Int] = [:]
    func configure(disconnectedScripts: Int = 0, failQueries: Bool = false, failPageTwo: Bool = false) {
        self.disconnectedScripts = disconnectedScripts; self.failQueries = failQueries; self.failPageTwo = failPageTwo
    }
    func count(_ key: String) -> Int { calls[key, default: 0] }
    func respond(_ request: URLRequest) throws -> (Data, URLResponse) {
        let url = request.url!
        let key = request.httpMethod == "POST" ? "query" : (url.pathExtension == "js" ? "script" : "bootstrap")
        calls[key, default: 0] += 1
        func result(_ text: String, status: Int = 200) -> (Data, URLResponse) {
            (Data(text.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!)
        }
        if key == "bootstrap" {
            let loader: [String: Any] = ["declaredTags": ["readytouse_tags": [["name": "Age Rating", "tags": [["name": "Everyone"]]]]]]
            let root = try JSONSerialization.data(withJSONObject: ["loaderData": [loader]])
            return result("<script id=\"valve-ssr-data\">\(String(decoding: root, as: UTF8.self))</script><script src=\"https://cdn.fastly.steamstatic.com/steamcommunity/public/ssr/recovery.js\"></script>")
        }
        if key == "script" {
            if disconnectedScripts > 0 { disconnectedScripts -= 1; throw URLError(.networkConnectionLost) }
            return result("Actions:{Browse:x(`current_action_123`,`Browse`)}")
        }
        if request.value(forHTTPHeaderField: "x-valve-action-type") == "expired_action:Browse" { return result("expired", status: 404) }
        let json = try JSONSerialization.jsonObject(with: request.httpBody!) as! [[String: Any]]
        let page = json[0]["page"] as? Int ?? 1
        if failQueries || (failPageTwo && page == 2) { throw URLError(.networkConnectionLost) }
        return result("{\"eresult\":1,\"current_page\":\(page),\"total_pages\":2,\"total_count\":2,\"results\":[{\"publishedfileid\":\"123456789\(page)\",\"consumer_appid\":431960,\"title\":\"Page \(page)\"}]}")
    }
}

final class WorkshopCatalogRecoveryTests: XCTestCase {
    private func makeCache() -> WorkshopCatalogCache {
        WorkshopCatalogCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent("catalog-test-" + UUID().uuidString))
    }
    private let routeURL = URL(string: "https://cdn.fastly.steamstatic.com/steamcommunity/public/ssr/recovery.js")!
    private func service(_ cache: WorkshopCatalogCache, _ server: CatalogTestServer) -> WorkshopCatalogService {
        WorkshopCatalogService(cache: cache, retryDelayNanoseconds: 0, transport: { try await server.respond($0) })
    }
    private func page(_ title: String) -> WorkshopPage {
        WorkshopPage(items: [.init(id: "1234567890", title: title, isSubscribed: true)], page: 1, totalPages: 2, total: 2)
    }

    func testDroppedScriptConnectionRetriesAndCachesWorkingBootstrap() async throws {
        let cache = makeCache(); defer { try? FileManager.default.removeItem(at: cache.directory) }
        let server = CatalogTestServer(); await server.configure(disconnectedScripts: 2)
        let client = service(cache, server)
        let result = try await client.browse(WorkshopQuery(tags: ["Everyone"]))
        XCTAssertEqual(result.items.first?.title, "Page 1")
        let scriptCalls = await server.count("script")
        XCTAssertEqual(scriptCalls, 3)
        XCTAssertEqual(cache.route()?.action, "current_action_123")
        XCTAssertFalse(cache.groups()?.isEmpty ?? true)
        let nextServer = CatalogTestServer()
        let nextClient = service(cache, nextServer)
        _ = try await nextClient.browse(WorkshopQuery(tags: ["Everyone"]))
        let nextScripts = await nextServer.count("script"), nextBootstrap = await nextServer.count("bootstrap")
        XCTAssertEqual(nextScripts, 0, "App relaunch should not depend on downloading the same script again")
        XCTAssertEqual(nextBootstrap, 0)
    }

    func testExpiredCachedActionRefreshesOnceInsteadOfLoopingOrReturningAnEmptyPage() async throws {
        let cache = makeCache(); defer { try? FileManager.default.removeItem(at: cache.directory) }
        cache.saveRoute(action: "expired_action", sourceURL: routeURL)
        let server = CatalogTestServer()
        let result = try await service(cache, server).browse(WorkshopQuery())
        XCTAssertFalse(result.items.isEmpty)
        let queries = await server.count("query"), bootstraps = await server.count("bootstrap")
        XCTAssertEqual(queries, 2); XCTAssertEqual(bootstraps, 1)
        XCTAssertEqual(cache.route()?.action, "current_action_123")
    }

    func testCacheSeparatesRatingsSearchAndPagesAndDoesNotPersistSubscriptionState() throws {
        let cache = makeCache(); defer { try? FileManager.default.removeItem(at: cache.directory) }
        let query = WorkshopQuery(tags: ["Everyone", "Scene"])
        cache.save(page("General"), query: query)
        XCTAssertEqual(cache.page(WorkshopQuery(tags: ["Scene", "Everyone"]))?.value.items.first?.title, "General")
        XCTAssertNil(cache.page(query)?.value.items.first?.isSubscribed)
        XCTAssertNil(cache.page(WorkshopQuery(tags: ["Mature", "Scene"])))
        XCTAssertNil(cache.page(WorkshopQuery(search: "other", tags: query.tags)))
        XCTAssertNil(cache.page(WorkshopQuery(tags: query.tags, page: 2)))
        cache.saveRoute(action: "untrusted", sourceURL: URL(string: "https://steamstatic.com.evil.test/steamcommunity/public/ssr/route.js")!)
        XCTAssertNil(cache.route())
    }

    func testCancelledRetryDoesNotSendAnotherQuery() async throws {
        let cache = makeCache(); defer { try? FileManager.default.removeItem(at: cache.directory) }
        cache.saveRoute(action: "current_action_123", sourceURL: routeURL)
        let server = CatalogTestServer(); await server.configure(failQueries: true)
        let client = WorkshopCatalogService(cache: cache, retryDelayNanoseconds: 5_000_000_000, transport: { try await server.respond($0) })
        let request = Task { try await client.browse(WorkshopQuery()) }
        for _ in 0..<100 { if await server.count("query") > 0 { break }; await Task.yield() }
        request.cancel()
        do { _ = try await request.value; XCTFail("Cancelled request should throw") }
        catch { XCTAssertTrue(error is CancellationError || (error as NSError).code == URLError.cancelled.rawValue) }
        let calls = await server.count("query")
        XCTAssertLessThanOrEqual(calls, 1)
        XCTAssertNil(cache.page(WorkshopQuery()))
    }

    @MainActor
    private func load(_ model: WorkshopBrowserModel, action: () -> Void) async {
        let completed = expectation(description: "Model finishes its network attempt")
        let observer = model.$loading.dropFirst().filter { !$0 }.prefix(1).sink { _ in completed.fulfill() }
        action()
        await fulfillment(of: [completed], timeout: 3)
        observer.cancel()
    }

    @MainActor
    func testOfflineReloadKeepsMatchingCachedCatalogAndNeverShowsAnotherRatingsItems() async {
        let cache = makeCache(); defer { try? FileManager.default.removeItem(at: cache.directory) }
        cache.save(page("General cached"), query: WorkshopQuery(tags: ["Everyone"]))
        cache.saveRoute(action: "current_action_123", sourceURL: routeURL)
        let server = CatalogTestServer(); await server.configure(failQueries: true)
        let model = WorkshopBrowserModel(service: service(cache, server))
        XCTAssertEqual(model.items.first?.title, "General cached")
        XCTAssertFalse(model.groups.isEmpty)
        await load(model) { model.loadIfNeeded() }
        XCTAssertEqual(model.items.first?.title, "General cached")
        XCTAssertTrue(model.usingCachedData)
        XCTAssertTrue(model.error?.contains("Steam 连接暂时中断") == true)
        model.filters = ["Age Rating": "Mature"]
        await load(model) { model.reload() }
        XCTAssertTrue(model.items.isEmpty, "A different rating must never reuse the previous query's cached list")
    }

    @MainActor
    func testRetryAfterPaginationDisconnectRequestsTheFailedPageAndPreservesExistingItems() async {
        let cache = makeCache(); defer { try? FileManager.default.removeItem(at: cache.directory) }
        cache.saveRoute(action: "current_action_123", sourceURL: routeURL)
        let server = CatalogTestServer()
        let model = WorkshopBrowserModel(service: service(cache, server))
        await load(model) { model.reload() }
        await server.configure(failPageTwo: true)
        await load(model) { model.loadMore() }
        XCTAssertEqual(model.page, 1); XCTAssertEqual(model.items.count, 1)
        await server.configure()
        await load(model) { model.retryLastRequest() }
        XCTAssertEqual(model.page, 2)
        XCTAssertEqual(model.items.map(\.title), ["Page 1", "Page 2"])
        XCTAssertFalse(model.usingCachedData); XCTAssertNil(model.error)
    }
}
