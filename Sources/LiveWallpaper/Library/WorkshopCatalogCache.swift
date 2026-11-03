import Foundation
import CryptoKit

/// 只缓存公开目录元数据；查询（含分级、标签、页码）独立，Steam 订阅状态不落盘。
struct WorkshopCatalogCache: Sendable {
    static let standard = WorkshopCatalogCache(directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        .appendingPathComponent("com.a55555.livewallpaper/WorkshopCatalog"))
    let directory: URL
    struct Entry<Value: Codable>: Codable {
        let savedAt: Date
        let value: Value
    }
    struct Route: Codable { let action: String; let sourceURL: URL }

    private func read<Value: Codable>(_ name: String, maxAge: TimeInterval) -> Entry<Value>? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)),
              let entry = try? JSONDecoder().decode(Entry<Value>.self, from: data),
              Date().timeIntervalSince(entry.savedAt) <= maxAge else { return nil }
        return entry
    }
    private func write<Value: Codable>(_ value: Value, name: String) {
        guard let data = try? JSONEncoder().encode(Entry(savedAt: Date(), value: value)) else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent(name), options: .atomic)
        } catch { Log.write("WorkshopCatalogCache: 无法保存目录缓存：\(error.localizedDescription)") }
    }
    private func pageName(_ query: WorkshopQuery) -> String {
        var canonical = query; canonical.tags.sort()
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let bytes = (try? encoder.encode(canonical)) ?? Data()
        return "page-" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() + ".json"
    }
    func page(_ query: WorkshopQuery) -> Entry<WorkshopPage>? { read(pageName(query), maxAge: 7 * 86400) }
    func save(_ page: WorkshopPage, query: WorkshopQuery) {
        var publicPage = page
        publicPage.items = page.items.map { item in var value = item; value.isSubscribed = nil; return value }
        write(publicPage, name: pageName(query))
        // 最多保留 32 个查询页面，避免搜索历史无限积累。
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let pages = files.filter { $0.lastPathComponent.hasPrefix("page-") }.sorted {
            ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) >
            ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }
        for old in pages.dropFirst(32) { try? FileManager.default.removeItem(at: old) }
    }
    func groups() -> [WorkshopTagGroup]? {
        let result: Entry<[WorkshopTagGroup]>? = read("groups.json", maxAge: 30 * 86400)
        return result?.value
    }
    func saveGroups(_ groups: [WorkshopTagGroup]) { if !groups.isEmpty { write(groups, name: "groups.json") } }
    func route() -> Route? {
        let result: Entry<Route>? = read("route.json", maxAge: 86400)
        guard let route = result?.value,
              WorkshopCatalogService.scriptURLs("<script src=\"\(route.sourceURL.absoluteString)\"></script>").contains(route.sourceURL) else { return nil }
        return route
    }
    func saveRoute(action: String, sourceURL: URL) { write(Route(action: action, sourceURL: sourceURL), name: "route.json") }
    func invalidateRoute() { try? FileManager.default.removeItem(at: directory.appendingPathComponent("route.json")) }
}
