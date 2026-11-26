import Foundation
import WebKit

/// Read the same item metadata and subscription list that Steam uses for its browse cards.
@MainActor
enum SteamWorkshopSubscriptionStatus {
    static func lookup(id: String, in webView: WKWebView) async -> WorkshopWallpaper? {
        await lookup(ids: [id], in: webView)?.first
    }

    /// Only positive results may start a transfer. An absent item can be unconfirmed or unsubscribed.
    static func subscribedItems(ids: [String], in webView: WKWebView) async -> [WorkshopWallpaper]? {
        await lookup(ids: ids, in: webView)?.filter { $0.isSubscribed == true }
    }

    private static func lookup(ids: [String], in webView: WKWebView) async -> [WorkshopWallpaper]? {
        // Steam's own DataLoader accepts at most 100 file IDs per request.
        guard !ids.isEmpty, ids.count <= 100, ids.allSatisfy({ WorkshopWebAddress.detailURL($0) != nil }),
              let page = webView.url, SteamWorkshopBrowser.isSteamPage(page),
              page.host?.lowercased() == "steamcommunity.com" else { return nil }
        let store = webView.configuration.websiteDataStore.httpCookieStore
        guard let account = await accountID(in: store), !Task.isCancelled else { return nil }
        var requested = Set<String>()
        let uniqueIDs = ids.filter { requested.insert($0).inserted }
        do {
            let value = try await webView.callAsyncJavaScript(query, arguments: ["ids": uniqueIDs, "account": account],
                                                             in: nil, contentWorld: .defaultClient)
            guard let rows = value as? [[String: Any]], await accountID(in: store) == account,
                  !Task.isCancelled else { return nil }
            return rows.compactMap { info in
                guard let id = info["id"] as? String, requested.contains(id),
                      let title = info["title"] as? String, let subscribed = info["subscribed"] as? Bool else { return nil }
                var item = WorkshopWallpaper(id: id, title: title)
                item.isSubscribed = subscribed
                item.sizeBytes = Int64(info["bytes"] as? String ?? "") ?? 0
                return item
            }
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
        return Array.isArray(payload.data) ? payload.data : [];
    }
    async function readDetail(id) {
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
    const [items, statuses] = await Promise.all([
        read("GetUGCSummary", [ids]).catch(() => null),
        read("GetUserListStatus", [431960, 1, 0, ids]).catch(() => null)
    ]);
    const results = [], missing = [];
    for (const id of ids) {
        const item = items?.find(row => row?.publishedfileid === id);
        if (item && (item.consumer_appid !== 431960 || item.file_type !== 0)) continue;
        const status = statuses?.find(row => row?.publishedfileid === id);
        if (typeof item?.title === "string" && typeof status?.inlist === "boolean") {
            results.push({id, title: item.title, bytes: String(item.file_size || 0), subscribed: status.inlist});
        } else {
            missing.push(id);
        }
    }
    // Keep partial batch successes. Limit isolated compatibility reads when the list service is unavailable.
    const details = await Promise.all(missing.slice(0, 2).map(id => readDetail(id).catch(() => null)));
    results.push(...details.filter(Boolean));
    return results.length || !missing.length ? results : null;
    """#
}
