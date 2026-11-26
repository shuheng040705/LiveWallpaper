import Foundation
import WebKit

/// Read the same item metadata and subscription list that Steam uses for its browse cards.
@MainActor
enum SteamWorkshopSubscriptionStatus {
    static func lookup(id: String, in webView: WKWebView) async -> WorkshopWallpaper? {
        guard WorkshopWebAddress.detailURL(id) != nil,
              let page = webView.url, SteamWorkshopBrowser.isSteamPage(page),
              page.host?.lowercased() == "steamcommunity.com" else { return nil }
        let store = webView.configuration.websiteDataStore.httpCookieStore
        guard let account = await accountID(in: store) else { return nil }
        do {
            let value = try await webView.callAsyncJavaScript(query, arguments: ["id": id, "account": account],
                                                             in: nil, contentWorld: .defaultClient)
            guard let info = value as? [String: Any], info["id"] as? String == id,
                  let title = info["title"] as? String, let subscribed = info["subscribed"] as? Bool,
                  await accountID(in: store) == account else { return nil }
            var item = WorkshopWallpaper(id: id, title: title)
            item.isSubscribed = subscribed
            item.sizeBytes = Int64(info["bytes"] as? String ?? "") ?? 0
            return item
        } catch {
            return nil
        }
    }

    static func accountID(in store: WKHTTPCookieStore) async -> String? {
        let cookies = await store.allCookies()
        guard let cookie = SteamSubscription.communityLoginCookie(in: cookies) else { return nil }
        return SteamSubscription.steamID64(fromSecureCookieValue: cookie.value)
    }

    static let query = #"""
    if (location.origin !== "https://steamcommunity.com") return null;
    // Give the independent detail fallback its own time budget if a status request timed out.
    async function request(url, headers) {
        const abort = new AbortController();
        const timer = setTimeout(() => abort.abort(), 8000);
        try {
            const response = await fetch(url, {credentials: "same-origin", redirect: "error", cache: "no-store",
                signal: abort.signal, headers});
            return response.ok ? await response.text() : null;
        } finally { clearTimeout(timer); }
    }
    async function read(name, parameters) {
        const url = new URL("/sharedfiles/actions", location.origin);
        url.searchParams.set("q", name);
        url.searchParams.set("qp", JSON.stringify(parameters));
        const text = await request(url, {"x-valve-request-type": "queryAction"});
        if (!text) return null;
        const payload = JSON.parse(text);
        return Array.isArray(payload.data) ? payload.data.find(row => row?.publishedfileid === id) : null;
    }
    async function readDetail() {
        const url = new URL("/sharedfiles/filedetails/", location.origin);
        url.searchParams.set("id", id);
        const html = await request(url);
        if (!html) return null;
        const doc = new DOMParser().parseFromString(html, "text/html");
        if (!Array.from(doc.scripts).some(script =>
            /\bg_steamID\s*=\s*['"](\d+)['"]/.exec(script.textContent)?.[1] === account)) return null;
        const button = doc.querySelector("#profileBlock .game_area_purchase_game #SubscribeItemBtn");
        const action = /^\s*SubscribeItem\(\s*['"](\d+)['"]\s*,\s*['"]431960['"]\s*\)\s*;?\s*$/.exec(button?.getAttribute("onclick") || "");
        if (action?.[1] !== id) return null;
        const subscribed = button.classList.contains("toggled");
        const add = button.querySelector("#SubscribeItemOptionAdd");
        const existing = button.querySelector("#SubscribeItemOptionSubscribed");
        if (!add || !existing || existing.classList.contains("selected") !== subscribed ||
            add.classList.contains("selected") === subscribed) return null;
        return {id, title: doc.querySelector(".workshopItemTitle")?.textContent.trim() || id, subscribed};
    }
    const [item, status] = await Promise.all([
        read("GetUGCSummary", [[id]]), read("GetUserListStatus", [431960, 1, 0, [id]])
    ]).catch(() => [null, null]);
    if (!item || !status || typeof status.inlist !== "boolean") return await readDetail();
    if (item?.consumer_appid !== 431960 || item?.file_type !== 0 || typeof item.title !== "string" ||
        item.publishedfileid !== id) return null;
    return {id, title: item.title, bytes: String(item.file_size || 0), subscribed: status.inlist};
    """#
}
