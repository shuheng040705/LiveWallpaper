import Foundation

/// 创意工坊「在线推荐」数据源:拉 Steam 社区创意工坊浏览页(appid 431960),
/// 解析出热门/最新壁纸的 id + 标题 + 预览图 URL,供**首页主内容**(hero + 多货架)展示。
///
/// 为什么解析网页而非 WebAPI:`IPublishedFileService/QueryFiles` 需要 Steam API key
/// (用户没有);社区 `/workshop/browse/` 端点匿名可访问、返回的 HTML 里每个条目是
/// `<a href="…filedetails/?id=ID"><img src="预览图" alt="标题"></a>`,稳定易解析,
/// 还能直接拿到现成的缩略图 CDN URL(无需登录、无需 SteamCMD)。
///
/// 纯展示/推荐:点击卡片跳到「创意工坊」tab 的详情页,订阅/下载仍走既有 WorkshopView 流程。
/// 失败(无网/超时/被限流)优雅降级:对应 section 的 items 为空 → 首页该货架隐藏 / 给重试入口。
@MainActor
final class WorkshopFeed: ObservableObject {
    static let shared = WorkshopFeed()
    private init() { loadCachedFromDisk() }

    // ⭐磁盘缓存:首页慢的主因=每次开都重新联网拉+解析 Steam 浏览页。改为「先秒显上次磁盘缓存的列表、
    //   后台再联网刷新」。缓存只存轻量 Item(id/title/previewURL),缩略图本身另由 ThumbnailCache 磁盘缓存。
    private var cacheURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.a55555.livewallpaper", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("workshop_feed.json")
    }

    /// 启动/首开:从磁盘读上次缓存的列表 → 首页秒显(loaded 保持 false,loadHome 仍会联网刷新)。
    func loadCachedFromDisk() {
        guard sections.values.allSatisfy({ $0.items.isEmpty }) else { return }   // 已有内容不覆盖
        guard let data = try? Data(contentsOf: cacheURL),
              let cached = try? JSONDecoder().decode([String: [Item]].self, from: data) else { return }
        for (key, items) in cached {
            guard let s = Sort(rawValue: key), !items.isEmpty else { continue }
            update(s) { $0.items = items }
        }
    }

    /// 联网刷新成功后写回磁盘,供下次秒显。
    private func saveToDisk() {
        var dict: [String: [Item]] = [:]
        for (s, sec) in sections where !sec.items.isEmpty { dict[s.rawValue] = sec.items }
        guard !dict.isEmpty, let data = try? JSONEncoder().encode(dict) else { return }
        try? data.write(to: cacheURL)
    }

    struct Item: Identifiable, Hashable, Codable {
        let id: String          // workshop id
        let title: String
        let previewURL: URL     // 缩略图 CDN 地址
        /// 详情页地址(点击卡片跳转用)。
        var detailURL: URL {
            URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=\(id)")!
        }
    }

    /// 排序方式(对应 Steam 浏览页参数),同时作为首页各「区段(section)」的标识。
    /// - weeklyhot:Steam 浏览「本周最热」= `browsesort=trend` + `days=7`。
    /// - toprated:Steam 浏览「评分最高」= `browsesort=toprated`(综合好评率)。
    /// - mostrecent:最新发布。
    enum Sort: String, CaseIterable {
        case weeklyhot   // 本周最热(trend + days=7)
        case toprated    // 评分最高
        case mostrecent  // 最新发布

        /// Steam `browsesort` 参数值。
        var browseValue: String {
            switch self {
            case .weeklyhot: return "trend"      // 趋势热门;配合 days=7 => 本周
            case .toprated:  return "toprated"   // 评分最高
            case .mostrecent: return "mostrecent"
            }
        }
        /// 「本周最热」需要额外的时间窗参数 `days`(7=本周);其它排序不带。
        var browseDays: Int? {
            switch self {
            case .weeklyhot: return 7
            default: return nil
            }
        }
        /// 首页货架标题。
        var shelfTitle: String {
            switch self {
            case .weeklyhot: return "本周最热"
            case .toprated:  return "评分最高"
            case .mostrecent: return "工坊最新"
            }
        }
        var shelfIcon: String {
            switch self {
            case .weeklyhot: return "flame.fill"
            case .toprated:  return "star.fill"
            case .mostrecent: return "sparkles"
            }
        }
    }

    /// 各区段独立持有自己的状态,首页可分别展示「热门」「最新」两条货架并各自加载/降级。
    struct Section {
        var items: [Item] = []
        var isLoading = false
        var failed = false      // true 且 items 空 → 隐藏该货架(或给重试)
        var loaded = false
    }

    /// 区段表:key = Sort。@Published 整体发布(SwiftUI 视图整体刷新即可)。
    @Published private(set) var sections: [Sort: Section] = [
        .weeklyhot: Section(),
        .toprated: Section(),
        .mostrecent: Section(),
    ]

    func section(_ s: Sort) -> Section { sections[s] ?? Section() }
    func items(_ s: Sort) -> [Item] { sections[s]?.items ?? [] }

    /// 首页 hero 用:本周最热第一条(没有则评分最高 / 最新第一条)。
    var heroItem: Item? { items(.weeklyhot).first ?? items(.toprated).first ?? items(.mostrecent).first }

    /// 首页 hero 精选 6 张:取「本周最热」前 6(不足则依次用评分最高 / 最新补满),去重。
    func heroItems(_ count: Int = 6) -> [Item] {
        var seen = Set<String>()
        var out: [Item] = []
        for s in [Sort.weeklyhot, .toprated, .mostrecent] {
            for it in items(s) where !seen.contains(it.id) {
                seen.insert(it.id)
                out.append(it)
                if out.count >= count { return out }
            }
        }
        return out
    }
    /// 任一区段成功加载到内容。
    var hasAnyContent: Bool { sections.values.contains { !$0.items.isEmpty } }
    /// 任一区段仍在加载。
    var isLoadingAny: Bool { sections.values.contains { $0.isLoading } }
    /// 所有区段都已尝试且都失败(且无任何内容)→ 首页主体走「失败降级」。
    var allFailed: Bool {
        let secs = sections.values
        return !secs.isEmpty
            && secs.allSatisfy { $0.failed && $0.items.isEmpty }
            && !secs.contains { $0.isLoading }
    }

    private let appID = "431960"
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 20
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg)
    }()

    /// 首页出现时拉取**所有区段**(已加载过则不重复;`force` 用于「重试」按钮)。
    /// limit:每个区段拉前 N 个做推荐货架。
    func loadHome(limit: Int = 18, force: Bool = false) {
        for s in Sort.allCases { loadIfNeeded(sort: s, limit: limit, force: force) }
    }

    /// 拉取单个区段(已加载过/正在加载则跳过;`force` 强制重拉)。
    func loadIfNeeded(sort: Sort = .weeklyhot, limit: Int = 18, force: Bool = false) {
        let cur = section(sort)
        guard force || (!cur.loaded && !cur.isLoading) else { return }
        Task { await load(sort: sort, limit: limit) }
    }

    func load(sort: Sort = .weeklyhot, limit: Int = 18) async {
        update(sort) { $0.isLoading = true; $0.failed = false }
        let fetched = await Self.fetch(appID: appID, sort: sort, limit: limit, session: session)
        update(sort) {
            $0.loaded = true
            $0.isLoading = false
            if let fetched, !fetched.isEmpty {
                $0.items = fetched
                $0.failed = false
            } else {
                $0.failed = true
                // 保留旧 items(若之前成功过);仅在从未成功时为空 → 隐藏 / 重试。
            }
        }
        if let fetched, !fetched.isEmpty { saveToDisk() }   // 刷新成功 → 写磁盘供下次秒显
    }

    private func update(_ sort: Sort, _ mutate: (inout Section) -> Void) {
        var s = sections[sort] ?? Section()
        mutate(&s)
        sections[sort] = s
    }

    /// 拉取并解析。网络/解析失败返回 nil(调用方据此降级)。在后台执行,不阻塞主线程。
    private static func fetch(appID: String, sort: Sort, limit: Int,
                             session: URLSession) async -> [Item]? {
        var comps = URLComponents(string: "https://steamcommunity.com/workshop/browse/")!
        var query: [URLQueryItem] = [
            .init(name: "appid", value: appID),
            .init(name: "browsesort", value: sort.browseValue),
            .init(name: "actualsort", value: sort.browseValue),
            .init(name: "section", value: "readytouseitems"),
            .init(name: "p", value: "1"),
            .init(name: "numperpage", value: "30"),
        ]
        // 「本周最热」额外带时间窗 days=7(Steam 浏览页 trend 排序需要 days 才是「本周」)。
        if let days = sort.browseDays {
            query.append(.init(name: "days", value: String(days)))
        }
        comps.queryItems = query
        guard let url = comps.url else { return nil }
        var req = URLRequest(url: url)
        // 真实浏览器 UA:Steam 对默认 URLSession UA 可能返回精简/空页。
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                     forHTTPHeaderField: "User-Agent")
        req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let html = String(data: data, encoding: .utf8) else { return nil }
            return parse(html, limit: limit)
        } catch {
            Log.write("WorkshopFeed: 拉取失败 \(error.localizedDescription)")
            return nil
        }
    }

    /// 从浏览页 HTML 解析条目。每条目结构:
    /// `…filedetails/?id=<ID>" …><img src="<预览图>" alt="<标题>"…>`。
    /// 顺序保留(=网站排序),去重取前 limit 个。
    static func parse(_ html: String, limit: Int) -> [Item] {
        let pattern = #"filedetails/\?id=(\d+)"[^>]*>\s*<img\s+src="([^"]+)"\s+alt="([^"]*)""#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let ns = html as NSString
        let matches = re.matches(in: html, range: NSRange(location: 0, length: ns.length))
        var seen = Set<String>()
        var out: [Item] = []
        for m in matches {
            let id = ns.substring(with: m.range(at: 1))
            guard !seen.contains(id) else { continue }
            let rawURL = ns.substring(with: m.range(at: 2))
            // HTML 实体:&amp; → &;预览 URL 里有 &amp;impolicy 等。
            let urlStr = rawURL.replacingOccurrences(of: "&amp;", with: "&")
            guard let url = URL(string: urlStr) else { continue }
            let title = decodeEntities(ns.substring(with: m.range(at: 3)))
            seen.insert(id)
            out.append(Item(id: id, title: title.isEmpty ? "创意工坊 #\(id)" : title, previewURL: url))
            if out.count >= limit { break }
        }
        return out
    }

    /// 解码 alt 文本里常见的 HTML 实体(标题可能含 &amp; &quot; 等)。
    private static func decodeEntities(_ s: String) -> String {
        var r = s
        for (e, c) in [("&amp;", "&"), ("&quot;", "\""), ("&#39;", "'"),
                       ("&apos;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " ")] {
            r = r.replacingOccurrences(of: e, with: c)
        }
        return r.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
