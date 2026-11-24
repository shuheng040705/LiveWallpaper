import Foundation
import Combine

@MainActor
final class WorkshopBrowserModel: ObservableObject {
    static let shared = WorkshopBrowserModel()
    @Published var search = ""
    @Published var sort = "trend"
    @Published var filters: [String: String] = ["Age Rating": "Everyone"]
    @Published private(set) var groups: [WorkshopTagGroup] = []
    @Published private(set) var items: [WorkshopWallpaper] = []
    @Published private(set) var selection: WorkshopWallpaper?
    @Published private(set) var loading = false
    @Published private(set) var loadingDetail = false
    @Published private(set) var usingCachedData = false
    @Published private(set) var updatedAt: Date?
    @Published private(set) var error: String?
    @Published private(set) var detailError: String?
    @Published private(set) var total = 0
    @Published private(set) var page = 0
    @Published private(set) var totalPages = 1
    private var loadTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    private var generation = UUID()
    private var lastRequest = WorkshopQuery(tags: ["Everyone"])
    private var didInitialLoad = false
    private let service: WorkshopCatalogService

    init(service: WorkshopCatalogService = .shared) {
        self.service = service
        groups = service.cache.groups() ?? WorkshopTagGroup.basic
        if let cached = service.cache.page(lastRequest) { showCached(cached) }
    }
    var isShowingSearchResults: Bool { !lastRequest.search.isEmpty }

    func loadIfNeeded() {
        if !loading, !didInitialLoad || error != nil { retryLastRequest() }
    }
    func retryLastRequest() { load(lastRequest) }
    private func showCached(_ entry: WorkshopCatalogCache.Entry<WorkshopPage>) {
        items = entry.value.items; page = entry.value.page; totalPages = entry.value.totalPages; total = entry.value.total
        usingCachedData = true; updatedAt = entry.savedAt
    }
    func searchSubmitted() {
        if let id = Self.itemID(from: search) { open(id: id) }
        else { reload() }
    }
    func reload() {
        load(WorkshopQuery(search: search.trimmingCharacters(in: .whitespacesAndNewlines),
                           sort: sort, tags: filters.values.filter { !$0.isEmpty }.sorted()))
    }
    func goToPage(_ target: Int) {
        guard target >= 1, target <= totalPages, target != page else { return }
        var query = lastRequest
        query.page = target
        load(query)
    }
    func resetFilters() {
        filters = ["Age Rating": "Everyone"]; search = ""; sort = "trend"; reload()
    }
    private func load(_ query: WorkshopQuery) {
        didInitialLoad = true
        loadTask?.cancel()
        let token = UUID(); generation = token
        var previous = lastRequest
        previous.page = query.page
        let scopeChanged = previous != query
        if scopeChanged || query.page != page {
            closeDetail()
            if let cached = service.cache.page(query) {
                showCached(cached)
            } else if scopeChanged {
                items = []; page = 0; total = 0; totalPages = 1; usingCachedData = false; updatedAt = nil
            }
        }
        lastRequest = query
        loading = true; error = nil
        loadTask = Task {
            do {
                let groups = try await service.tagGroups()
                guard !Task.isCancelled, generation == token else { return }
                self.groups = groups
                let result = try await service.browse(query)
                guard !Task.isCancelled, generation == token else { return }
                items = result.items
                page = result.page; totalPages = result.totalPages; total = result.total; loading = false
                usingCachedData = false; updatedAt = Date()
            } catch {
                guard !Task.isCancelled, generation == token else { return }
                if let groups = service.cache.groups() { self.groups = groups }
                usingCachedData = !items.isEmpty
                let reason = WorkshopCatalogService.userMessage(for: error)
                self.error = query.page != page && page > 0 ? "第 \(query.page) 页加载失败。\(reason)" : reason
                loading = false
            }
        }
    }
    func select(_ item: WorkshopWallpaper) {
        selection = item; detailError = nil; detailTask?.cancel(); loadingDetail = true
        detailTask = Task {
            defer { if selection?.id == item.id { loadingDetail = false } }
            do {
                var detail = try await service.detail(id: item.id)
                guard !Task.isCancelled, selection?.id == item.id else { return }
                if detail.author.isEmpty { detail.author = item.author }
                if detail.previewURL == nil { detail.previewURL = item.previewURL }
                if detail.tags.isEmpty { detail.tags = item.tags }
                if item.sizeBytes > 0 { detail.sizeBytes = item.sizeBytes }
                if detail.subscribers == 0 { detail.subscribers = item.subscribers }
                if detail.stars == 0 { detail.stars = item.stars }
                selection = detail
            } catch {
                guard !Task.isCancelled, selection?.id == item.id else { return }
                detailError = "暂时无法加载完整说明，仍可订阅或打开 Steam 原页"
            }
        }
    }
    func open(id: String) {
        if let item = items.first(where: { $0.id == id }) { select(item); return }
        detailTask?.cancel(); loadingDetail = true; detailError = nil
        detailTask = Task {
            do {
                let detail = try await service.detail(id: id)
                guard !Task.isCancelled else { return }
                selection = detail; loadingDetail = false
            } catch {
                guard !Task.isCancelled else { return }
                self.error = WorkshopCatalogService.userMessage(for: error); loadingDetail = false
            }
        }
    }
    func closeDetail() { detailTask?.cancel(); selection = nil; loadingDetail = false; detailError = nil }
    static func itemID(from text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if WallpaperUninstallPolicy.isSteamWorkshopID(value) { return value }
        guard let url = URL(string: value), url.scheme == "https", url.host == "steamcommunity.com",
              url.path.contains("filedetails"),
              let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "id" })?.value,
              WallpaperUninstallPolicy.isSteamWorkshopID(id) else { return nil }
        return id
    }
}
