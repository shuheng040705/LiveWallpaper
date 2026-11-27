import Foundation
import Security
import LocalAuthentication

/// Steam 社区网页授权的持久凭据库。
///
/// WKWebsiteDataStore.default() 会持久化普通 Cookie，但 Steam 的 `sessionid` 常是会话 Cookie；
/// WebKit 网站进程重建、系统清理网站数据或应用升级后，它可能先于 `steamLoginSecure` 消失。
/// 用户明确完成网页授权后把最小认证 Cookie 集合保存到钥匙串。后台恢复仅使用无需交互的钥匙串权限。
///
/// 注意：延长的是本机 Cookie 的保留时间，不是 Steam 服务端令牌寿命。Steam 主动吊销令牌后，
/// 请求仍会返回 authenticationRequired，已拒绝的快照随即停止使用，下次显式授权时清理。
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

    static func save(cookies: [HTTPCookie], interactive: Bool) -> Bool {
        dispatchPrecondition(condition: .notOnQueue(.main))
        guard let data = encodeSnapshot(cookies: cookies) else {
            // 调用方要求保存空集合时，必须同时清除旧认证快照，不能让已被服务端拒绝的 token 留下来复活。
            return clear(interactive: interactive)
        }
        var identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        configureAccess(&identity, interactive: interactive)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(identity as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = identity
            for (key, value) in attributes { item[key] = value }
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            if interactive && addStatus != errSecSuccess {
                Log.write("SteamWebCredentialVault: Keychain save failed (\(addStatus))")
            }
            return addStatus == errSecSuccess
        } else if interactive && status != errSecSuccess {
            Log.write("SteamWebCredentialVault: Keychain update failed (\(status))")
        }
        return status == errSecSuccess
    }

    static func loadCookies(interactive: Bool) -> [HTTPCookie]? {
        dispatchPrecondition(condition: .notOnQueue(.main))
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        configureAccess(&query, interactive: interactive)
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return decodeSnapshot(data)
    }

    private static func clear(interactive: Bool) -> Bool {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        configureAccess(&query, interactive: interactive)
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess, status != errSecItemNotFound {
            Log.write("SteamWebCredentialVault: Keychain delete failed (\(status))")
            return false
        }
        return true
    }

    private static func configureAccess(_ query: inout [String: Any], interactive: Bool) {
        guard !interactive else { return }
        let context = LAContext()
        context.interactionNotAllowed = true
        // The legacy file-based keychain has a process-wide ACL prompt policy.
        // Keep automatic access in the data protection keychain, where this
        // no-interaction policy is scoped to the individual request.
        query[kSecUseDataProtectionKeychain as String] = true
        query[kSecUseAuthenticationContext as String] = context
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

    /// 恢复会话 Cookie 时给其本地保留期，Steam 已设置的到期时间仍然生效。
    static func decodeSnapshot(_ data: Data, now: Date = Date()) -> [HTTPCookie] {
        guard let stored = try? JSONDecoder().decode([StoredCookie].self, from: data) else { return [] }
        let localRetention = now.addingTimeInterval(365 * 24 * 60 * 60)
        return stored.compactMap { item in
            if let expiry = item.expires, expiry <= now { return nil }
            var properties: [HTTPCookiePropertyKey: Any] = [
                .name: item.name,
                .value: item.value,
                .domain: item.domain,
                .path: item.path,
                .secure: item.secure ? "TRUE" : "FALSE",
                // 只为原本没有到期时间的会话 Cookie 设置本机保留期。
                .expires: item.expires ?? localRetention,
            ]
            if item.httpOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
            return HTTPCookie(properties: properties)
        }
    }
}
