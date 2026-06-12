import Foundation
import WebKit

/// 通过 Steam 社区网页会话取消订阅某个创意工坊条目。
/// 复用与创意工坊 WKWebView 共享的 cookie(WKWebsiteDataStore.default()),POST 到网页自身用的
/// /sharedfiles/unsubscribe AJAX 接口。需用户已在创意工坊页登录 Steam;未登录则返回失败提示。
enum SteamSubscription {
    static let appID = "431960"

    /// 取消订阅。completion(成功?, 提示文案) 在主线程回调。失败不抛错(本地删除仍照常进行)。
    static func unsubscribe(id: String, completion: @escaping (Bool, String) -> Void) {
        guard let url = URL(string: "https://steamcommunity.com/sharedfiles/unsubscribe") else {
            DispatchQueue.main.async { completion(false, "URL 构造失败") }; return
        }
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
            let steam = cookies.filter { $0.domain.contains("steamcommunity.com") }
            guard let sessionid = steam.first(where: { $0.name == "sessionid" })?.value,
                  steam.contains(where: { $0.name.hasPrefix("steamLoginSecure") }) else {
                DispatchQueue.main.async { completion(false, "未登录 Steam(请先在创意工坊页登录账号)") }
                return
            }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue(HTTPCookie.requestHeaderFields(with: steam)["Cookie"] ?? "", forHTTPHeaderField: "Cookie")
            req.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
            req.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
            req.setValue("https://steamcommunity.com/sharedfiles/filedetails/?id=\(id)", forHTTPHeaderField: "Referer")
            req.httpBody = "id=\(id)&appid=\(appID)&sessionid=\(sessionid)".data(using: .utf8)
            URLSession.shared.dataTask(with: req) { data, resp, err in
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                let bodyOK = data.flatMap { String(data: $0, encoding: .utf8) }?.contains("\"success\":1") ?? false
                let ok = err == nil && (200..<300).contains(code) && (bodyOK || data?.isEmpty != false)
                DispatchQueue.main.async {
                    completion(ok, ok ? "已取消订阅" : "取消订阅失败(HTTP \(code));壁纸仍会从本地删除")
                }
            }.resume()
        }
    }
}
