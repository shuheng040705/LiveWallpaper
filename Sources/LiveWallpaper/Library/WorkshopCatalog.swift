import Foundation

struct WorkshopWallpaper: Identifiable, Equatable {
    let id: String
    var title: String
    var previewURL: URL?
    var author = ""
    var summary = ""
    var tags: [String] = []
    var sizeBytes: Int64 = 0
    var subscribers = 0
    var stars = 0
    var isSubscribed: Bool?
    var detailURL: URL { URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=\(id)")! }
}

struct WorkshopTagGroup: Identifiable, Equatable {
    struct Tag: Identifiable, Equatable {
        let id: String
        let title: String
    }
    let id: String
    let title: String
    let tags: [Tag]
}

struct WorkshopQuery: Equatable {
    var search = ""
    var sort = "trend"
    var tags: [String] = []
    var page = 1
    var days = 7

    var parameters: [String: Any] {
        ["appid": 431960, "browse_sort": search.isEmpty ? sort : "textsearch",
         "section": "readytouseitems", "page": page, "num_per_page": 30,
         "trend_days": days, "search_text": search, "search_text_target": 0,
         "required_tags": tags, "required_apps_preset": 0, "admin_view": false]
    }
}

struct WorkshopPage {
    let items: [WorkshopWallpaper]
    let page: Int
    let totalPages: Int
    let total: Int
}

enum WorkshopCatalogError: LocalizedError {
    case http(Int), invalidResponse, unsupportedPage, unavailableItem
    var errorDescription: String? {
        switch self {
        case .http(let code): return "Steam 请求失败（HTTP \(code)），请稍后重试"
        case .invalidResponse: return "Steam 返回了无法识别的数据，请刷新重试"
        case .unsupportedPage: return "Steam 工坊接口已变更，请暂时使用“在 Steam 中打开”"
        case .unavailableItem: return "这张壁纸不存在、已下架或无法公开访问"
        }
    }
}

/// 从 Steam 官方社区读取目录数据，原生 UI 不执行或嵌入工坊页面的布局脚本。
/// 新版 Steam 浏览页通过公开的 routeAction 提供列表；动作标识从当前官方脚本发现。
actor WorkshopCatalogService {
    static let shared = WorkshopCatalogService()
    private let browseURL = URL(string: "https://steamcommunity.com/workshop/browse/?appid=431960&l=schinese")!
    private var actionID: String?
    private var bootstrapTask: Task<(String, [WorkshopTagGroup]), Error>?
    private var groups: [WorkshopTagGroup] = []
    private let session: URLSession

    init(session: URLSession? = nil) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 25
        config.timeoutIntervalForResource = 40
        self.session = session ?? URLSession(configuration: config)
    }

    func tagGroups() async throws -> [WorkshopTagGroup] {
        try await prepare()
        return groups
    }

    func browse(_ query: WorkshopQuery) async throws -> WorkshopPage {
        try await prepare()
        do { return try await requestPage(query) }
        catch WorkshopCatalogError.http(let status) where status == 400 || status == 404 {
            actionID = nil
            try await prepare()
            return try await requestPage(query)
        }
    }

    private func requestPage(_ query: WorkshopQuery) async throws -> WorkshopPage {
        guard let actionID else { throw WorkshopCatalogError.unsupportedPage }
        var request = URLRequest(url: browseURL)
        request.httpMethod = "POST"
        request.setValue("routeAction", forHTTPHeaderField: "x-valve-request-type")
        request.setValue("\(actionID):Browse", forHTTPHeaderField: "x-valve-action-type")
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(browseURL.absoluteString, forHTTPHeaderField: "Referer")
        request.httpBody = try JSONSerialization.data(withJSONObject: [query.parameters])
        let result = try Self.parsePage(await fetch(request))
        Log.write("WorkshopCatalog: page \(result.page), \(result.items.count) items, total \(result.total)")
        return result
    }

    func detail(id: String) async throws -> WorkshopWallpaper {
        guard WallpaperUninstallPolicy.isSteamWorkshopID(id) else { throw WorkshopCatalogError.unavailableItem }
        let url = URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=\(id)&l=schinese")!
        let data = try await fetch(URLRequest(url: url))
        let html = String(decoding: data, as: UTF8.self)
        let records = Self.loaderRecords(html)
        var found: WorkshopWallpaper?
        func visit(_ value: Any) {
            if let object = value as? [String: Any] {
                if Self.string(object["publishedfileid"]) == id, let item = Self.item(object, authors: [:]) {
                    found = item
                }
                for child in object.values where child is [String: Any] || child is [Any] { visit(child) }
            } else if let array = value as? [Any] { array.forEach(visit) }
        }
        records.forEach(visit)
        if found == nil { found = Self.parseLegacyDetail(html, id: id) }
        guard let found else { throw WorkshopCatalogError.unavailableItem }
        return found
    }

    private func fetch(_ original: URLRequest) async throws -> Data {
        var request = original
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Version/18.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        request.setValue("zh-CN,zh;q=0.9,en;q=0.5", forHTTPHeaderField: "Accept-Language")
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw WorkshopCatalogError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw WorkshopCatalogError.http(http.statusCode) }
        return data
    }

    private func prepare() async throws {
        guard actionID == nil else { return }
        let task: Task<(String, [WorkshopTagGroup]), Error>
        if let existing = bootstrapTask { task = existing }
        else {
            task = Task {
                let html = String(decoding: try await fetch(URLRequest(url: browseURL)), as: UTF8.self)
                let groups = Self.parseTagGroups(html)
                // Route bundle is last. Only official Steam script assets are eligible.
                for url in Self.scriptURLs(html).reversed() {
                    let script = String(decoding: try await fetch(URLRequest(url: url)), as: UTF8.self)
                    if let action = Self.discoverBrowseAction(script) { return (action, groups) }
                }
                throw WorkshopCatalogError.unsupportedPage
            }
            bootstrapTask = task
        }
        do {
            let (action, groups) = try await task.value
            actionID = action; self.groups = groups; bootstrapTask = nil
        } catch {
            bootstrapTask = nil
            throw error
        }
    }

    static func discoverBrowseAction(_ script: String) -> String? {
        captures(#"\bBrowse:\w+\([`"']([A-Za-z0-9_-]+)[`"'],\s*[`"']Browse[`"']\)"#, in: script).first?.first
    }

    static func scriptURLs(_ html: String) -> [URL] {
        captures(#"<script\b[^>]*\bsrc="([^"]+)""#, in: html).compactMap { row in
            guard let value = row.first, let url = URL(string: value), url.scheme == "https",
                  let host = url.host, host == "steamstatic.com" || host.hasSuffix(".steamstatic.com"),
                  url.path.hasPrefix("/steamcommunity/public/ssr/"), url.pathExtension == "js" else { return nil }
            return url
        }
    }

    static func loaderRecords(_ html: String) -> [[String: Any]] {
        guard let json = captures(#"<script\b[^>]*\bid="valve-ssr-data"[^>]*>([\s\S]*?)</script>"#, in: html).first?.first,
              let root = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let loaders = root["loaderData"] as? [Any] else { return [] }
        return loaders.compactMap { value in
            if let object = value as? [String: Any] { return object }
            if let json = value as? String {
                return try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
            }
            return nil
        }
    }

    static func parseTagGroups(_ html: String) -> [WorkshopTagGroup] {
        for record in loaderRecords(html) {
            guard let declared = record["declaredTags"] as? [String: Any],
                  let rawGroups = declared["readytouse_tags"] as? [[String: Any]] else { continue }
            let translated = ["Type": "壁纸类型", "Age Rating": "内容分级", "Genre": "题材", "Miscellaneous": "特性", "Asset Genre": "资源题材", "Script Type": "脚本类型",
                              "Resolution": "分辨率", "Category": "分类", "Asset Type": "资源类型"]
            return rawGroups.compactMap { group in
                guard let name = group["name"] as? String, let raw = group["tags"] as? [[String: Any]] else { return nil }
                let tags = raw.compactMap { tag -> WorkshopTagGroup.Tag? in
                    guard tag["admin_only"] as? Bool != true, let value = tag["name"] as? String else { return nil }
                    return .init(id: value, title: tag["display_name"] as? String ?? value)
                }
                return .init(id: name, title: translated[name] ?? name, tags: tags)
            }
        }
        return []
    }

    static func parsePage(_ data: Data) throws -> WorkshopPage {
        // Steam appends a second newline-delimited metrics object after the result.
        guard let line = String(decoding: data, as: UTF8.self).split(separator: "\n").first,
              let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              (object["eresult"] as? NSNumber)?.intValue == 1,
              let raw = object["results"] as? [[String: Any]] else { throw WorkshopCatalogError.invalidResponse }
        var authors: [String: String] = [:]
        for row in object["creator_player_link_details"] as? [[String: Any]] ?? [] {
            if let info = row["public_data"] as? [String: Any], let id = info["steamid"] as? String {
                authors[id] = info["persona_name"] as? String
            }
        }
        var seen = Set<String>()
        let items = raw.compactMap { item($0, authors: authors) }.filter { seen.insert($0.id).inserted }
        return WorkshopPage(items: items, page: (object["current_page"] as? Int) ?? 1,
                            totalPages: (object["total_pages"] as? Int) ?? 1,
                            total: (object["total_count"] as? Int) ?? items.count)
    }

    /// Steam 的详情页仍可能使用旧模板，与新版目录的 JSON loader 并存。
    static func parseLegacyDetail(_ html: String, id: String) -> WorkshopWallpaper? {
        guard WallpaperUninstallPolicy.isSteamWorkshopID(id),
              !captures("SubscribeItem\\(\\s*['\"]\(id)['\"]\\s*,\\s*['\"]431960['\"]", in: html).isEmpty,
              let title = captures(#"<div\b[^>]*class="[^"]*\bworkshopItemTitle\b[^"]*"[^>]*>([\s\S]*?)</div>"#, in: html).first?.first else { return nil }
        let preview = captures(#"<img\b[^>]*\bid="previewImageMain"[^>]*\bsrc="([^"]+)""#, in: html).first?.first
        let author = captures(#"<div\b[^>]*class="friendBlockContent"[^>]*>([\s\S]*?)<br"#, in: html).first?.first ?? ""
        var size: Int64 = 0
        if let row = captures(#"class="detailsStatRight"[^>]*>\s*([\d.,]+)\s*(GB|MB|KB|B)"#, in: html).first,
           let value = Double(row[0].replacingOccurrences(of: ",", with: "")) {
            let factor: Double = ["GB": 1_000_000_000, "MB": 1_000_000, "KB": 1_000][row[1].uppercased()] ?? 1
            size = Int64(value * factor)
        }
        return WorkshopWallpaper(id: id, title: plainText(title),
                                 previewURL: preview.flatMap { URL(string: plainText($0)) },
                                 author: plainText(author), summary: plainText(descriptionHTML(html)), sizeBytes: size)
    }

    private static func descriptionHTML(_ html: String) -> String {
        guard let start = html.range(of: #"<div\b[^>]*\bid="highlightContent"[^>]*>"#, options: .regularExpression),
              let regex = try? NSRegularExpression(pattern: #"</?div\b[^>]*>"#, options: [.caseInsensitive]) else { return "" }
        let tail = String(html[start.upperBound...])
        let source = tail as NSString
        var depth = 1
        for match in regex.matches(in: tail, range: NSRange(location: 0, length: source.length)) {
            depth += source.substring(with: match.range).hasPrefix("</") ? -1 : 1
            if depth == 0 { return source.substring(to: match.range.location) }
        }
        return ""
    }

    private static func plainText(_ html: String) -> String {
        var value = html.replacingOccurrences(of: #"<br\s*/?>|</p>|</li>|</div>"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        for (entity, text) in [("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " "), ("&amp;", "&")] {
            value = value.replacingOccurrences(of: entity, with: text)
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func item(_ object: [String: Any], authors: [String: String]) -> WorkshopWallpaper? {
        guard let id = string(object["publishedfileid"]), WallpaperUninstallPolicy.isSteamWorkshopID(id),
              let title = object["title"] as? String, !title.isEmpty,
              (object["consumer_appid"] as? Int) == 431960,
              (object["file_type"] as? Int ?? 0) == 0 else { return nil }
        let tags = (object["tags"] as? [[String: Any]] ?? []).compactMap { $0["tag"] as? String }
        return WorkshopWallpaper(id: id, title: title,
            previewURL: (object["preview_url"] as? String).flatMap(URL.init(string:)),
            author: authors[string(object["creator"]) ?? ""] ?? "",
            summary: object["description"] as? String ?? object["short_description"] as? String ?? "",
            tags: tags, sizeBytes: Int64(string(object["file_size"]) ?? "0") ?? 0,
            subscribers: object["subscriptions"] as? Int ?? 0, stars: object["star_rating"] as? Int ?? 0,
            isSubscribed: object["user_subscribed"] as? Bool)
    }

    private static func string(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        return (value as? NSNumber)?.stringValue
    }

    private static func captures(_ pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let source = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: source.length)).map { match in
            (1..<match.numberOfRanges).map { source.substring(with: match.range(at: $0)) }
        }
    }
}
