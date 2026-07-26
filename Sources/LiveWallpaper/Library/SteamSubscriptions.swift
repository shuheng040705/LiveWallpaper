import Foundation

/// 检测当前 Steam 账号订阅的全部创意工坊条目(读本地 Steam 客户端写的 `431960_subscriptions.vdf`)。
/// 不需要 Steam Web API key / 登录态——这文件就是 Steam 客户端同步的订阅真值。SteamID 从 userdata 目录名取。
/// 供「设置 → 我的 Steam 订阅」批量下载用。
struct SubscribedItem: Identifiable, Hashable {
    let id: String              // publishedfileid
    let timeSubscribed: Int     // 订阅时间戳(倒序展示)
}

enum SteamSubscriptions {
    static let appID = "431960"   // Wallpaper Engine

    /// 候选 Steam 根目录(原生 + CrossOver/Wine + 用户覆盖)。
    static func steamRoots() -> [URL] {
        var roots: [URL] = []
        if let override = PreferencesStore.shared.steamDataPath, !override.isEmpty {
            roots.append(URL(fileURLWithPath: override))
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        roots.append(home.appendingPathComponent("Library/Application Support/Steam"))
        // CrossOver/Wine 版 Steam(本机游戏走这条)。
        let cx = home.appendingPathComponent("Library/Application Support/CrossOver/Bottles/Steam/drive_c/Program Files (x86)/Steam")
        roots.append(cx)
        return roots.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// 从 loginusers.vdf 取「最近登录」用户的 SteamID64;无则 nil。
    private static func mostRecentSteamID64(root: URL) -> String? {
        let f = root.appendingPathComponent("config/loginusers.vdf")
        guard let txt = try? String(contentsOf: f, encoding: .utf8) else { return nil }
        // 结构:"<steamID64>" { ... "MostRecent" "1" ... }。取 MostRecent=1 的;否则第一个。
        let ns = txt as NSString
        let blockRe = try! NSRegularExpression(pattern: "\"(7656\\d{13})\"\\s*\\{([\\s\\S]*?)\\n\\t\\}", options: [])
        var first: String? = nil
        for m in blockRe.matches(in: txt, range: NSRange(location: 0, length: ns.length)) {
            let sid = ns.substring(with: m.range(at: 1))
            let body = ns.substring(with: m.range(at: 2))
            if first == nil { first = sid }
            if body.range(of: "\"MostRecent\"\\s*\"1\"", options: .regularExpression) != nil { return sid }
        }
        return first
    }

    /// SteamID64 → SteamID3(account id,= userdata 目录名)。
    private static func accountID(from steamID64: String) -> String? {
        guard let v = UInt64(steamID64), v >= 76561197960265728 else { return nil }
        return String(v - 76561197960265728)
    }

    /// 定位 431960_subscriptions.vdf:先按 loginusers 推导,失败则遍历 userdata/* 取存在的。
    static func subscriptionsVDFURL() -> URL? {
        for root in steamRoots() {
            // 1) 按最近登录用户推导
            if let sid = mostRecentSteamID64(root: root), let acc = accountID(from: sid) {
                let f = root.appendingPathComponent("userdata/\(acc)/ugc/\(appID)_subscriptions.vdf")
                if FileManager.default.fileExists(atPath: f.path) { return f }
            }
            // 2) 降级:遍历 userdata/*/ugc/<app>_subscriptions.vdf
            let userdata = root.appendingPathComponent("userdata")
            if let subs = try? FileManager.default.contentsOfDirectory(at: userdata, includingPropertiesForKeys: nil) {
                for u in subs {
                    let f = u.appendingPathComponent("ugc/\(appID)_subscriptions.vdf")
                    if FileManager.default.fileExists(atPath: f.path) { return f }
                }
            }
        }
        return nil
    }

    /// 解析 VDF → 订阅条目(跳过 disabled_locally=1),按订阅时间倒序。
    static func loadSubscriptions() -> [SubscribedItem] {
        guard let url = subscriptionsVDFURL(), let txt = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let ns = txt as NSString
        // 块内字段固定顺序:publishedfileid → time_subscribed → disabled_locally。
        let re = try! NSRegularExpression(
            pattern: "\"publishedfileid\"\\s*\"(\\d+)\"\\s*\"time_subscribed\"\\s*\"(\\d+)\"\\s*\"disabled_locally\"\\s*\"(\\d)\"",
            options: [])
        var out: [SubscribedItem] = []
        for m in re.matches(in: txt, range: NSRange(location: 0, length: ns.length)) {
            let id = ns.substring(with: m.range(at: 1))
            let t = Int(ns.substring(with: m.range(at: 2))) ?? 0
            let disabled = ns.substring(with: m.range(at: 3)) == "1"
            if disabled { continue }
            out.append(SubscribedItem(id: id, timeSubscribed: t))
        }
        return out.sorted { $0.timeSubscribed > $1.timeSubscribed }
    }

    /// 某 id 是否已在壁纸库(已下载)。
    static func isInstalled(_ id: String) -> Bool {
        FileManager.default.fileExists(atPath: PreferencesStore.shared.libraryRoot.appendingPathComponent(id).path)
    }

    /// 已装项从 project.json 读标题;读不到回退 nil。
    static func localTitle(_ id: String) -> String? {
        let pj = PreferencesStore.shared.libraryRoot.appendingPathComponent(id).appendingPathComponent("project.json")
        guard let data = try? Data(contentsOf: pj),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let title = obj["title"] as? String, !title.isEmpty else { return nil }
        return title
    }

    /// 已装项的本地预览图 URL(preview.gif/.jpg/.png)。
    static func localPreviewURL(_ id: String) -> URL? {
        let dir = PreferencesStore.shared.libraryRoot.appendingPathComponent(id)
        for name in ["preview.gif", "preview.jpg", "preview.png", "preview.jpeg"] {
            let f = dir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: f.path) { return f }
        }
        return nil
    }

    /// 未装项联网取标题 + 缩略图 URL(创意工坊详情页 og:title/og:image,best-effort,失败返回 nil)。仅按需(行可见时)调。
    static func fetchRemoteMeta(_ id: String) async -> (title: String?, thumb: URL?) {
        guard let url = URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=\(id)") else { return (nil, nil) }
        var req = URLRequest(url: url); req.timeoutInterval = 12
        req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let html = String(data: data, encoding: .utf8) else { return (nil, nil) }
        let ns = html as NSString
        func og(_ prop: String) -> String? {
            let re = try? NSRegularExpression(pattern: "<meta property=\"og:\(prop)\" content=\"([^\"]*)\"", options: [.caseInsensitive])
            guard let m = re?.firstMatch(in: html, range: NSRange(location: 0, length: ns.length)), m.numberOfRanges > 1 else { return nil }
            return ns.substring(with: m.range(at: 1)).replacingOccurrences(of: "&amp;", with: "&")
        }
        let title = og("title")
        let thumb = og("image").flatMap { URL(string: $0) }
        return (title == "Steam Community :: Error" ? nil : title, thumb)
    }

    /// 设置摘要行(后台解析):如「检测到 154 个订阅 · 12 个未下载」。
    static func summaryLine() async -> String {
        await Task.detached(priority: .utility) {
            let subs = loadSubscriptions()
            if subs.isEmpty { return "未检测到 Steam 订阅记录(需先在 Steam 客户端登录过)" }
            let notInstalled = subs.filter { !isInstalled($0.id) }.count
            return "检测到 \(subs.count) 个订阅 · \(notInstalled) 个未下载"
        }.value
    }
}
