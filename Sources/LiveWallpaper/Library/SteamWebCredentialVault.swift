import Foundation
import Security

/// Steam 社区网页授权的持久凭据库。
///
/// WKWebsiteDataStore.default() 会持久化普通 Cookie，但 Steam 的 `sessionid` 常是会话 Cookie；
/// WebKit 网站进程重建、系统清理网站数据或应用升级后，它可能先于 `steamLoginSecure` 消失。
/// 这里把最小认证 Cookie 集合加密保存到 macOS Keychain，并在需要订阅/退订时恢复。
///
/// 注意：延长的是本机 Cookie 的保留时间，不是 Steam 服务端令牌寿命。Steam 主动吊销令牌后，
/// 请求仍会返回 authenticationRequired，调用方会清掉 Keychain 并要求重新授权。
enum SteamWebCredentialVault {
    struct StoredCookie: Codable, Equatable {
        let name: String
        let value: String
        let domain: String
        let path: String
        let secure: Bool
        let httpOnly: Bool
        let expires: Date?
    }

    private static let service = "com.a55555.livewallpaper.steam-web-session"
    private static let account = "steamcommunity-cookies-v1"
    private static let retainedNames = [
        "sessionid", "steamLoginSecure", "steamRememberLogin", "steamMachineAuth", "browserid"
    ]

    static func save(cookies: [HTTPCookie]) {
        guard let data = encodeSnapshot(cookies: cookies) else {
            // 调用方要求保存空集合时，必须同时清除旧认证快照，不能让已被服务端拒绝的 token 留下来复活。
            clear()
            return
        }
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(identity as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = identity
            for (key, value) in attributes { item[key] = value }
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            if addStatus != errSecSuccess {
                Log.write("SteamWebCredentialVault: Keychain save failed (\(addStatus))")
            }
        } else if status != errSecSuccess {
            Log.write("SteamWebCredentialVault: Keychain update failed (\(status))")
        }
    }

    static func loadCookies(now: Date = Date()) -> [HTTPCookie] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return [] }
        return decodeSnapshot(data, now: now)
    }

    static func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess, status != errSecItemNotFound {
            Log.write("SteamWebCredentialVault: Keychain delete failed (\(status))")
        }
    }

    /// 纯函数入口供测试。仅保存 Steam Community 的最小认证 Cookie 集，不保存表单、密码或其它站点数据。
    static func encodeSnapshot(cookies: [HTTPCookie]) -> Data? {
        let stored = cookies.compactMap { cookie -> StoredCookie? in
            let domain = cookie.domain.lowercased()
            guard domain == "steamcommunity.com" || domain.hasSuffix(".steamcommunity.com"),
                  retainedNames.contains(where: { cookie.name == $0 || cookie.name.hasPrefix($0) }),
                  !cookie.value.isEmpty else { return nil }
            return StoredCookie(
                name: cookie.name,
                value: cookie.value,
                domain: cookie.domain,
                path: cookie.path.isEmpty ? "/" : cookie.path,
                secure: cookie.isSecure,
                httpOnly: cookie.isHTTPOnly,
                expires: cookie.expiresDate
            )
        }
        // 允许只保存 steamRememberLogin/steamMachineAuth/browserid。服务端明确拒绝旧认证令牌时，
        // 我们会删除 sessionid/steamLoginSecure，但保留“记住此设备”，让官方登录页尽量自动恢复账号。
        guard !stored.isEmpty else { return nil }
        return try? JSONEncoder().encode(stored)
    }

    /// 恢复时给 WebKit Cookie 一个滚动的一年保留期；真正的长期副本仍在 Keychain。
    /// 浏览器会限制单个 Cookie 的最长寿命，因此不能依赖一个“十年 Cookie”。每次使用时都会从
    /// Keychain 恢复并再次滚动续期。服务端令牌仍由 Steam 独立校验，不能借此绕过吊销。
    static func decodeSnapshot(_ data: Data, now: Date = Date()) -> [HTTPCookie] {
        guard let stored = try? JSONDecoder().decode([StoredCookie].self, from: data) else { return [] }
        let localRetention = now.addingTimeInterval(365 * 24 * 60 * 60)
        return stored.compactMap { item in
            var properties: [HTTPCookiePropertyKey: Any] = [
                .name: item.name,
                .value: item.value,
                .domain: item.domain,
                .path: item.path,
                .secure: item.secure ? "TRUE" : "FALSE",
                // 即使原本是 session cookie，也让 WebKit 在本机长期保存；Steam 仍可服务端判失效。
                .expires: max(item.expires ?? localRetention, localRetention),
            ]
            if item.httpOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
            return HTTPCookie(properties: properties)
        }
    }
}
