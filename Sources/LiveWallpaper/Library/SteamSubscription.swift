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

    private init() {}

    func refresh(completion: ((Bool) -> Void)? = nil) {
        DispatchQueue.main.async {
            self.isChecking = true
            self.resolveAuthenticatedSession { auth in
                DispatchQueue.main.async {
                    let ok = auth != nil
                    self.isAuthenticated = ok
                    self.steamID64 = auth?.steamID64
                    self.isChecking = false
                    completion?(ok)
                }
            }
        }
    }

    /// 订阅/退订请求的统一认证入口。先读 WebKit；若 session cookie 被清掉，则从 Keychain
    /// 自动恢复并写回默认网站数据仓库，再返回可直接用于 HTTP 请求的完整会话。
    func authenticatedSession(completion: @escaping (SteamSubscription.AuthenticatedSession?) -> Void) {
        DispatchQueue.main.async {
            self.resolveAuthenticatedSession { auth in
                DispatchQueue.main.async {
                    self.isAuthenticated = auth != nil
                    self.steamID64 = auth?.steamID64
                    completion(auth)
                }
            }
        }
    }

    private func resolveAuthenticatedSession(
        completion: @escaping (SteamSubscription.AuthenticatedSession?) -> Void
    ) {
        let store = WKWebsiteDataStore.default().httpCookieStore
        store.getAllCookies { cookies in
            if let auth = SteamSubscription.authenticatedSession(from: cookies) {
                SteamWebCredentialVault.save(cookies: cookies)
                completion(auth)
                return
            }

            let restored = SteamWebCredentialVault.loadCookies()
            guard !restored.isEmpty else {
                completion(nil)
                return
            }
            // WebKit 常见状态是长期 steamLoginSecure 仍是新的，只丢了 sessionid。旧实现把
            // Keychain 整份旧快照写回，反而覆盖较新的登录令牌，几次启动后必然被 Steam 判失效。
            // 这里只补“同名+同域+同路径”缺失的 Cookie，绝不覆盖 WebKit 已有值。
            let existingKeys = Set(cookies.map(Self.cookieIdentity))
            let missing = restored.filter { !existingKeys.contains(Self.cookieIdentity($0)) }
            guard !missing.isEmpty else {
                // Keychain 可能只剩记住设备/browserid，用于之后的登录页，但不足以组成授权会话。
                completion(nil)
                return
            }
            let group = DispatchGroup()
            for cookie in missing {
                group.enter()
                store.setCookie(cookie) { group.leave() }
            }
            group.notify(queue: .global(qos: .utility)) {
                store.getAllCookies { merged in
                    let auth = SteamSubscription.authenticatedSession(from: merged)
                    if auth != nil { SteamWebCredentialVault.save(cookies: merged) }
                    Log.write("SteamWebSession: restored \(missing.count) missing cookie(s), authenticated=\(auth != nil)")
                    completion(auth)
                }
            }
        }
    }

    private static func cookieIdentity(_ cookie: HTTPCookie) -> String {
        let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return "\(domain)|\(cookie.path.isEmpty ? "/" : cookie.path)|\(cookie.name)"
    }

    /// 服务端判定 Cookie 已失效时删掉认证 Cookie，防止“本地看似已授权 → 重试 → 再失效”的循环。
    func clearAuthenticationCookies(completion: (() -> Void)? = nil) {
        DispatchQueue.main.async {
            let store = WKWebsiteDataStore.default().httpCookieStore
            store.getAllCookies { cookies in
                let targets = cookies.filter {
                    Self.isCommunityAuthenticationCookie($0)
                }
                // 只丢弃服务端已拒绝的认证对；browserid / RememberLogin / MachineAuth 继续加密
                // 保存在 Keychain，下一次官方登录页仍能识别设备。旧实现 Vault.clear() 把它们也全删了。
                let supporting = (SteamWebCredentialVault.loadCookies() + cookies).filter {
                    !$0.value.isEmpty
                        && $0.domain.lowercased().contains("steamcommunity.com")
                        && !Self.isCommunityAuthenticationCookie($0)
                }
                SteamWebCredentialVault.save(cookies: supporting)
                guard !targets.isEmpty else {
                    DispatchQueue.main.async {
                        self.isAuthenticated = false
                        self.steamID64 = nil
                        completion?()
                    }
                    return
                }
                let group = DispatchGroup()
                for cookie in targets {
                    group.enter()
                    store.delete(cookie) { group.leave() }
                }
                group.notify(queue: .main) {
                    self.isAuthenticated = false
                    self.steamID64 = nil
                    completion?()
                }
            }
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
        let loginCandidates = steam.filter { $0.name.hasPrefix("steamLoginSecure") && !$0.value.isEmpty }
        guard let session = preferredCookie(sessionCandidates),
              let login = preferredCookie(loginCandidates, preferredExactName: "steamLoginSecure") else {
            return nil
        }
        return AuthenticatedSession(
            sessionID: session.value,
            // 退订只需要这两个认证 Cookie。限制请求头也避免 browserid/偏好等无关 Cookie 泄漏到独立会话。
            cookies: [session, login],
            steamID64: steamID64(fromSecureCookieValue: login.value)
        )
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
