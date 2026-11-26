import Foundation
import WebKit
import Combine

/// Steam 社区网页授权状态。它与 SteamCMD 的下载令牌是两套不同会话：
/// - SteamCMD 登录：用于下载工坊文件；
/// - Web Cookie：用于调用社区站点的订阅/退订接口。
///
/// UI 必须分别展示，不能再把“保存了 SteamCMD 账号名”误报成“所有 Steam 功能都已登录”。
final class SteamWebSession: ObservableObject {
    static let shared = SteamWebSession()

    @Published private(set) var isAuthenticated = false
    @Published private(set) var isChecking = false
    @Published private(set) var steamID64: String?

    private let cookieStore: () -> WKHTTPCookieStore
    private let defaults: UserDefaults
    private let loadSnapshot: () -> [HTTPCookie]?
    private let saveSnapshot: ([HTTPCookie]) -> Bool
    private let vaultQueue = DispatchQueue(label: "LiveWallpaper.steam-web-vault", qos: .userInitiated)
    private let invalidSnapshot = "steamWebCredentialSnapshotInvalidated"
    private let lastAccount = "steamWebLastAuthenticatedAccount"
    private var revision = 0
    private var checks = 0
    private var rejectedLogins = Set<String>()
    private var clearing: [() -> Void] = []
    private var maySaveLogin = true

    init(cookieStore: @escaping () -> WKHTTPCookieStore = { WKWebsiteDataStore.default().httpCookieStore },
         defaults: UserDefaults = .standard,
         loadSnapshot: @escaping () -> [HTTPCookie]? = SteamWebCredentialVault.loadCookies,
         saveSnapshot: @escaping ([HTTPCookie]) -> Bool = SteamWebCredentialVault.save) {
        self.cookieStore = cookieStore
        self.defaults = defaults
        self.loadSnapshot = loadSnapshot
        self.saveSnapshot = saveSnapshot
    }

    // The legacy login keychain may present an ACL dialog even for background queries.
    // Startup, page navigation and login polling therefore use only the WebKit cookie store.
    func refresh(completion: ((Bool) -> Void)? = nil) {
        authenticatedSession { completion?($0 != nil) }
    }

    func authenticatedSession(completion: @escaping (SteamSubscription.AuthenticatedSession?) -> Void) {
        DispatchQueue.main.async {
            self.checks += 1
            self.isChecking = true
            let generation = self.revision
            self.cookieStore().getAllCookies { cookies in
                let auth: SteamSubscription.AuthenticatedSession?
                if generation == self.revision && self.clearing.isEmpty {
                    auth = self.observe(cookies)
                } else {
                    auth = nil
                }
                self.checks -= 1
                self.isChecking = self.checks > 0
                completion(auth)
            }
        }
    }

    @MainActor
    func updateFromWebsite(cookies: [HTTPCookie], afterLogout: Bool) {
        if afterLogout && SteamSubscription.authenticatedSession(from: cookies) == nil {
            invalidateSnapshot()
            isAuthenticated = false
            steamID64 = nil
        } else if clearing.isEmpty, SteamSubscription.authenticatedSession(from: cookies) != nil {
            _ = observe(cookies)
        }
    }

    @discardableResult
    private func observe(_ cookies: [HTTPCookie]) -> SteamSubscription.AuthenticatedSession? {
        let auth = SteamSubscription.authenticatedSession(from: cookies)
        if let account = auth?.steamID64 {
            if let previous = defaults.string(forKey: lastAccount), previous != account { invalidateSnapshot() }
            defaults.set(account, forKey: lastAccount)
        }
        isAuthenticated = auth != nil
        steamID64 = auth?.steamID64
        // Steam often issues a session-only CSRF cookie. Persist that cookie in the
        // same WebKit store so a normal application relaunch keeps the usable pair.
        if let auth {
            for cookie in auth.cookies where cookie.expiresDate == nil {
                guard var properties = cookie.properties else { continue }
                properties.removeValue(forKey: .discard)
                properties[.expires] = Date().addingTimeInterval(365 * 24 * 60 * 60)
                if let persistent = HTTPCookie(properties: properties) { cookieStore().setCookie(persistent) }
            }
        }
        return auth
    }

    /// Only the explicit Steam login window calls this. Existing installations can
    /// grant a newly signed build access to their legacy item without blocking AppKit.
    @MainActor
    func restoreForLogin() async -> Bool {
        maySaveLogin = true
        let generation = revision
        let store = cookieStore()
        let current = await store.allCookies()
        guard generation == revision else { return false }
        if observe(current) != nil { return true }

        let snapshot: [HTTPCookie]? = await withCheckedContinuation { result in
            vaultQueue.async { result.resume(returning: self.loadSnapshot()) }
        }
        guard generation == revision else { return false }
        guard let snapshot else {
            // User denied or cancelled access. Continue with web login without a
            // second prompt to overwrite the same protected item after login.
            maySaveLogin = false
            return false
        }
        // The website can sign in or change accounts while the ACL dialog is open.
        let latest = await store.allCookies()
        guard generation == revision else { return false }
        if observe(latest) != nil { return true }

        let savedAccount = Self.accountID(in: snapshot)
        let expected = Self.accountID(in: latest) ?? defaults.string(forKey: lastAccount)
        let stale = defaults.bool(forKey: invalidSnapshot)
            || (expected != nil && savedAccount != nil && expected != savedAccount)
        let usable = stale ? snapshot.filter { !Self.isCommunityAuthenticationCookie($0) } : snapshot
        if stale && usable.count != snapshot.count {
            // The explicit login was allowed to open this item. Purge its rejected
            // pair, keeping remembered-device cookies, without holding up the UI.
            vaultQueue.async { _ = self.saveSnapshot(usable) }
        }
        let keys = Set(latest.map(Self.cookieIdentity))
        for cookie in usable where !keys.contains(Self.cookieIdentity(cookie)) {
            guard generation == revision else { return false }
            await store.setCookie(cookie)
        }
        let merged = await store.allCookies()
        guard generation == revision else { return false }
        return observe(merged) != nil
    }

    /// Back up the current session after the user explicitly authorized Steam.
    func rememberLogin() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard maySaveLogin else { return }
        let generation = revision
        cookieStore().getAllCookies { cookies in
            guard generation == self.revision, SteamSubscription.authenticatedSession(from: cookies) != nil else { return }
            self.vaultQueue.async {
                let saved = self.saveSnapshot(cookies)
                DispatchQueue.main.async {
                    if generation == self.revision && saved { self.defaults.removeObject(forKey: self.invalidSnapshot) }
                }
            }
        }
    }

    private static func accountID(in cookies: [HTTPCookie]) -> String? {
        SteamSubscription.communityLoginCookie(in: cookies).flatMap { SteamSubscription.steamID64(fromSecureCookieValue: $0.value) }
    }

    private static func cookieIdentity(_ cookie: HTTPCookie) -> String {
        let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return "\(domain)|\(cookie.path.isEmpty ? "/" : cookie.path)|\(cookie.name)"
    }

    private func invalidateSnapshot() {
        revision &+= 1
        defaults.set(true, forKey: invalidSnapshot)
    }

    func noteRejected(_ session: SteamSubscription.AuthenticatedSession) {
        if let login = SteamSubscription.communityLoginCookie(in: session.cookies) {
            rejectedLogins.insert(login.value)
        }
    }

    func clearAuthenticationCookies(completion: (() -> Void)? = nil) {
        DispatchQueue.main.async {
            self.clearing.append(completion ?? {})
            if self.clearing.count == 1 { self.purgeRejectedCookies() }
        }
    }

    private func purgeRejectedCookies() {
        // A missing WebKit pair can also lead callers here. Its keychain backup
        // remains eligible for explicit restore until the server actually rejects it.
        guard !rejectedLogins.isEmpty else {
            let callbacks = clearing
            clearing.removeAll()
            callbacks.forEach { $0() }
            return
        }
        let rejected = rejectedLogins
        rejectedLogins.removeAll()
        let store = cookieStore()
        store.getAllCookies { cookies in
            let login = SteamSubscription.communityLoginCookie(in: cookies)
            let group = DispatchGroup()
            if login.map({ rejected.contains($0.value) }) ?? true {
                self.invalidateSnapshot()
                self.isAuthenticated = false
                self.steamID64 = nil
                for cookie in cookies.filter(Self.isCommunityAuthenticationCookie) {
                    group.enter()
                    store.delete(cookie) { group.leave() }
                }
            }
            // Requests for multiple wallpapers can fail before the purge completes.
            group.notify(queue: .main) { self.purgeRejectedCookies() }
        }
    }

    private static func isCommunityAuthenticationCookie(_ cookie: HTTPCookie) -> Bool {
        let domain = cookie.domain.lowercased()
        return (domain == "steamcommunity.com" || domain.hasSuffix(".steamcommunity.com"))
            && (cookie.name == "sessionid" || cookie.name.hasPrefix("steamLoginSecure"))
    }
}

/// 通过 Steam 社区网页会话取消订阅某个创意工坊条目。
/// 复用创意工坊 WKWebView 的持久 Cookie，并明确区分“需要网页授权”与普通网络失败。
enum SteamSubscription {
    static let appID = "431960"

    struct AuthenticatedSession {
        let sessionID: String
        let cookies: [HTTPCookie]
        let steamID64: String?
    }

    enum Outcome: Equatable {
        case success(String)
        case authenticationRequired
        case failure(String)
    }

    /// 只接受 Steam 社区域的 sessionid + steamLoginSecure，避免其它域同名 Cookie 被误认为已登录。
    static func authenticatedSession(from cookies: [HTTPCookie]) -> AuthenticatedSession? {
        let steam = cookies.filter {
            let domain = $0.domain.lowercased()
            return domain == "steamcommunity.com" || domain.hasSuffix(".steamcommunity.com")
        }
        // 同名旧 Cookie 不能同时进请求头。sessionid 必须与 POST body 完全一致；若 header 里出现
        // 两份不同值，Steam 会返回未登录/CSRF 失败，看起来像“Cookie 过一会儿失效”。
        let sessionCandidates = steam.filter { $0.name == "sessionid" && !$0.value.isEmpty }
        guard let session = preferredCookie(sessionCandidates),
              let login = communityLoginCookie(in: cookies) else {
            return nil
        }
        return AuthenticatedSession(
            sessionID: session.value,
            // 退订只需要这两个认证 Cookie。限制请求头也避免 browserid/偏好等无关 Cookie 泄漏到独立会话。
            cookies: [session, login],
            steamID64: steamID64(fromSecureCookieValue: login.value)
        )
    }

    // Authenticated reads only need the login cookie. A missing CSRF sessionid
    // prevents a native POST, but Steam can still confirm a subscription in its page.
    static func communityLoginCookie(in cookies: [HTTPCookie]) -> HTTPCookie? {
        let candidates = cookies.filter {
            $0.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased() == "steamcommunity.com"
                && $0.name.hasPrefix("steamLoginSecure") && !$0.value.isEmpty
        }
        return preferredCookie(candidates, preferredExactName: "steamLoginSecure")
    }

    private static func preferredCookie(
        _ cookies: [HTTPCookie],
        preferredExactName: String? = nil
    ) -> HTTPCookie? {
        cookies.sorted { lhs, rhs in
            func score(_ cookie: HTTPCookie) -> (Int, Int, TimeInterval) {
                let exact = preferredExactName.map { cookie.name == $0 ? 1 : 0 } ?? 0
                let rootPath = cookie.path == "/" ? 1 : 0
                return (exact, rootPath, cookie.expiresDate?.timeIntervalSince1970 ?? .greatestFiniteMagnitude)
            }
            let a = score(lhs), b = score(rhs)
            if a.0 != b.0 { return a.0 > b.0 }
            if a.1 != b.1 { return a.1 > b.1 }
            return a.2 > b.2
        }.first
    }

    /// steamLoginSecure 的值是 URL 编码后的 `<SteamID64>||<token>`；只取 ID，绝不记录 token。
    static func steamID64(fromSecureCookieValue value: String) -> String? {
        let decoded = value.removingPercentEncoding ?? value
        let prefix = decoded.components(separatedBy: "||").first ?? ""
        guard prefix.count == 17, prefix.hasPrefix("7656"), prefix.allSatisfy(\.isNumber) else { return nil }
        return prefix
    }

    /// 订阅某个条目。它是首页“下载”接入真实 Steam Client 的前置事务。
    static func subscribe(id: String, completion: @escaping (Outcome) -> Void) {
        perform(id: id, endpoint: "subscribe", completion: completion) { code, data, error in
            classifySubscribeResponse(statusCode: code, data: data, error: error)
        }
    }

    /// 取消订阅。completion 始终在主线程回调。
    /// authenticationRequired 由调用方打开官方 Steam 网页授权窗口并在成功后自动重试。
    static func unsubscribe(id: String, completion: @escaping (Outcome) -> Void) {
        perform(id: id, endpoint: "unsubscribe", completion: completion) { code, data, error in
            classifyResponse(statusCode: code, data: data, error: error)
        }
    }

    private static func perform(
        id: String,
        endpoint: String,
        completion: @escaping (Outcome) -> Void,
        classifier: @escaping (Int, Data?, Error?) -> Outcome
    ) {
        guard let url = URL(string: "https://steamcommunity.com/sharedfiles/\(endpoint)") else {
            DispatchQueue.main.async { completion(.failure("Steam 订阅地址无效")) }
            return
        }
        SteamWebSession.shared.authenticatedSession { auth in
            guard let auth else {
                DispatchQueue.main.async {
                    completion(.authenticationRequired)
                }
                return
            }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue(HTTPCookie.requestHeaderFields(with: auth.cookies)["Cookie"] ?? "",
                         forHTTPHeaderField: "Cookie")
            req.setValue("application/x-www-form-urlencoded; charset=UTF-8",
                         forHTTPHeaderField: "Content-Type")
            req.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
            req.setValue("https://steamcommunity.com/sharedfiles/filedetails/?id=\(id)",
                         forHTTPHeaderField: "Referer")
            var form = URLComponents()
            form.queryItems = [
                URLQueryItem(name: "id", value: id),
                URLQueryItem(name: "appid", value: appID),
                URLQueryItem(name: "sessionid", value: auth.sessionID)
            ]
            req.httpBody = form.percentEncodedQuery?.data(using: .utf8)

            // 独立 ephemeral session 不落磁盘缓存/系统 Cookie；请求只使用上面从 Keychain/WebKit
            // 取得的显式 Cookie header，避免 URLSession 自己保存另一套过期身份。
            URLSession(configuration: .ephemeral).dataTask(with: req) { data, response, error in
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                let outcome = classifier(code, data, error)
                DispatchQueue.main.async {
                    switch outcome {
                    case .success:
                        if endpoint == "subscribe" {
                            SteamSubscriptionRegistry.markSubscribed(id)
                        } else if endpoint == "unsubscribe" {
                            SteamSubscriptionRegistry.markUnsubscribed(id)
                        }
                        SteamWebSession.shared.refresh()
                    case .authenticationRequired:
                        SteamWebSession.shared.noteRejected(auth)
                        Log.write("SteamSubscription: \(endpoint) \(id) → authentication required (HTTP \(code), bytes=\(data?.count ?? 0))")
                    case .failure(let message):
                        Log.write("SteamSubscription: \(endpoint) \(id) → HTTP \(code), \(message)")
                    }
                    completion(outcome)
                }
            }.resume()
        }
    }

    static func classifySubscribeResponse(statusCode: Int, data: Data?, error: Error?) -> Outcome {
        classifyOperationResponse(
            statusCode: statusCode,
            data: data,
            error: error,
            successMessage: "已订阅",
            operationName: "订阅",
            failureSuffix: ""
        )
    }

    /// 把 Steam 返回统一映射成可测试的三态。401/403/登录页明确表示网页授权失效；
    /// 其它 HTTP/网络错误不能伪装成登录问题。
    static func classifyResponse(statusCode: Int, data: Data?, error: Error?) -> Outcome {
        classifyOperationResponse(
            statusCode: statusCode,
            data: data,
            error: error,
            successMessage: "已取消订阅",
            operationName: "取消订阅",
            failureSuffix: "，本地文件未删除"
        )
    }

    private static func classifyOperationResponse(
        statusCode: Int,
        data: Data?,
        error: Error?,
        successMessage: String,
        operationName: String,
        failureSuffix: String
    ) -> Outcome {
        if let error {
            return .failure("\(operationName)失败（\(error.localizedDescription)）\(failureSuffix)")
        }
        let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let lower = body.lowercased()
        if statusCode == 401
            || lower.contains("steamauthentication")
            || (lower.contains("<html") && lower.contains("login")) {
            return .authenticationRequired
        }
        if let data, !data.isEmpty,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let success = (json["success"] as? NSNumber)?.intValue {
            if success == 1 { return .success(successMessage) }
            // Steam EResult:21=NotLoggedOn；15=AccessDenied，不能把“未订阅/无权操作”误报成登录过期。
            if success == 21 { return .authenticationRequired }
            return .failure("Steam 拒绝\(operationName)（错误码 \(success)）\(failureSuffix)")
        }
        if (200..<300).contains(statusCode), data?.isEmpty != false {
            return .success(successMessage)
        }
        return .failure("\(operationName)失败（HTTP \(statusCode)）\(failureSuffix)")
    }
}
