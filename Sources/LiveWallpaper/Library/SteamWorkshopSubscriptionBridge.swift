import Combine
import Foundation
import WebKit

/// Finish Steam's confirmed website actions in the local download queue.
@MainActor
final class SteamWorkshopSubscriptionBridge: NSObject, ObservableObject, WKScriptMessageHandler {
    static let shared = SteamWorkshopSubscriptionBridge { item, subscribed in
        WorkshopSubscriptions.shared.confirmedWebsiteChange(item, subscribed: subscribed)
    }
    private static let handler = "workshopSubscription"
    private static let world = WKContentWorld.world(name: "LiveWallpaper.SteamWorkshop")
    @Published private var current: WorkshopWallpaper?
    private var documentID: String?
    private let onChange: (WorkshopWallpaper, Bool) -> Void
    private let lookup: (String, WKWebView) async -> WorkshopWallpaper?
    private var pending: [String: Task<Void, Never>] = [:]
    private var observers: [String: AnyCancellable] = [:]
    private var cardGestures: [String: (token: String, subscribing: Bool, account: Task<String?, Never>)] = [:]

    init(lookup: @escaping (String, WKWebView) async -> WorkshopWallpaper? = SteamWorkshopSubscriptionStatus.lookup,
         onChange: @escaping (WorkshopWallpaper, Bool) -> Void) {
        self.onChange = onChange
        self.lookup = lookup
    }

    static func install(in controller: WKUserContentController) {
        shared.attach(to: controller)
    }

    func attach(to controller: WKUserContentController) {
        controller.add(self, contentWorld: Self.world, name: Self.handler)
        controller.addUserScript(WKUserScript(source: Self.cardScript, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true, in: Self.world))
        controller.addUserScript(WKUserScript(source: Self.script, injectionTime: .atDocumentEnd,
                                              forMainFrameOnly: true, in: Self.world))
    }

    static func itemID(in url: URL?) -> String? {
        guard let url, url.scheme?.lowercased() == "https", url.host?.lowercased() == "steamcommunity.com",
              url.port == nil || url.port == 443, url.user == nil, url.password == nil,
              ["/sharedfiles/filedetails", "/sharedfiles/filedetails/", "/workshop/filedetails", "/workshop/filedetails/"].contains(url.path),
              let parameters = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.filter({ $0.name == "id" }),
              parameters.count == 1, let id = parameters.first?.value,
              (6...20).contains(id.utf8.count), id.utf8.allSatisfy({ (48...57).contains($0) }),
              let number = UInt64(id), number > 0 else { return nil }
        return id
    }

    func detail(for url: URL?) -> WorkshopWallpaper? {
        guard let current, Self.itemID(in: url) == current.id else { return nil }
        return current
    }

    func clearDetail() {
        documentID = nil
        current = nil
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        let frame = message.frameInfo
        let origin = frame.securityOrigin
        guard frame.isMainFrame, origin.protocol == "https", origin.host.lowercased() == "steamcommunity.com",
              origin.port == 0 || origin.port == 443,
              let webView = message.webView, let sourceURL = frame.request.url, SteamWorkshopBrowser.isSteamPage(sourceURL),
              let body = message.body as? [String: Any], let id = body["id"] as? String,
              body["app"] as? String == "431960", let kind = body["kind"] as? String else { return }
        if kind == "cardSubscribed", let token = body["gesture"] as? String,
           let title = body["title"] as? String, let gesture = cardGestures[id], gesture.subscribing, gesture.token == token {
            let store = webView.configuration.websiteDataStore.httpCookieStore
            Task { [weak self] in
                guard let account = await gesture.account.value,
                      await SteamWorkshopSubscriptionStatus.accountID(in: store) == account,
                      let self, self.cardGestures[id]?.token == token else { return }
                self.cancelCheck(id)
                var item = WorkshopWallpaper(id: id, title: title.isEmpty ? id : title)
                item.isSubscribed = true
                Log.write("Steam 工坊：卡片确认订阅 \(id)，同步到下载中心")
                self.onChange(item, true)
            }
            return
        }
        if kind == "cancelCardIntent" {
            cancelCheck(id)
            return
        }
        guard let subscribed = body["subscribed"] as? Bool else { return }

        if kind == "cardIntent" {
            guard WorkshopWebAddress.detailURL(id) != nil else { return }
            verifyCardAction(id: id, subscribed: subscribed, gesture: body["gesture"] as? String, webView: webView)
            return
        }
        guard Self.itemID(in: webView.url) == id, Self.itemID(in: sourceURL) == id,
              let token = body["document"] as? String else { return }
        let changed = kind == "change"
        if changed {
            guard token == documentID, current?.id == id, current?.isSubscribed == !subscribed else { return }
        } else if kind != "snapshot" { return }

        var item = WorkshopWallpaper(id: id, title: (body["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id)
        item.isSubscribed = subscribed
        item.sizeBytes = (body["bytes"] as? NSNumber)?.int64Value ?? 0
        documentID = token
        if current != item { current = item }
        if changed {
            cancelCheck(id)
            onChange(item, subscribed)
        }
    }

    private func cancelCheck(_ id: String) {
        pending.removeValue(forKey: id)?.cancel()
        observers[id] = nil
        cardGestures.removeValue(forKey: id)?.account.cancel()
    }

    /// A card can disappear or be replaced as soon as Steam accepts a click. Keep
    /// the check on the native side and follow the last gesture for each item.
    private func verifyCardAction(id: String, subscribed: Bool, gesture: String?, webView: WKWebView) {
        cancelCheck(id)
        if let gesture {
            let store = webView.configuration.websiteDataStore.httpCookieStore
            cardGestures[id] = (gesture, subscribed, Task { await SteamWorkshopSubscriptionStatus.accountID(in: store) })
        }
        // Never apply an outstanding gesture to the next account in this browser.
        observers[id] = SteamWebSession.shared.$steamID64.removeDuplicates().dropFirst().sink { [weak self] _ in
            self?.cancelCheck(id)
        }
        let cardGesture = cardGestures[id]
        pending[id] = Task { [weak self, weak webView] in
            guard let self, let webView else { return }
            let deadline = ContinuousClock.now + .seconds(60)
            var delay = Duration.milliseconds(350)
            var lastResponse: Bool?
            while ContinuousClock.now < deadline {
                do { try await Task.sleep(for: delay) } catch { return }
                if let item = await self.lookup(id, webView), !Task.isCancelled {
                    lastResponse = item.isSubscribed
                    if item.isSubscribed == subscribed {
                        if let gesture = cardGesture {
                            let account = await gesture.account.value
                            let active = await SteamWorkshopSubscriptionStatus.accountID(in: webView.configuration.websiteDataStore.httpCookieStore)
                            guard !Task.isCancelled, self.cardGestures[id]?.token == gesture.token else { return }
                            guard let account, active == account else { self.cancelCheck(id); return }
                        }
                        self.cancelCheck(id)
                        if Self.itemID(in: webView.url) == id { self.current = item }
                        Log.write("Steam 工坊：服务器确认作品 \(id) \(subscribed ? "已订阅" : "已退订")")
                        self.onChange(item, subscribed)
                        return
                    }
                }
                if Task.isCancelled { return }
                delay = min(delay * 2, .seconds(5))
            }
            self.cancelCheck(id)
            if lastResponse == nil { Log.write("Steam 工坊：无法确认作品 \(id) 的订阅状态") }
        }
    }

    // Current Steam cards render a green icon button. The glyph changes from a
    // check to an X when hovered. Use the enclosing item's Steam links, never its
    // title, to identify the transfer. Steam continues handling the click itself.
    private static let cardScript = #"""
    (() => {
        if (location.origin !== "https://steamcommunity.com") return;
        function itemID(url) {
            if (url.origin !== location.origin || !/^\/(?:sharedfiles|workshop)\/filedetails\/?$/.test(url.pathname)) return;
            const ids = url.searchParams.getAll("id");
            if (ids.length === 1 && /^\d{6,20}$/.test(ids[0])) return ids[0];
        }
        const actionSelector = 'button[data-accent-color="green"], [role="button"][data-accent-color="green"]';
        const watching = new Map();
        function cardFor(button) {
            for (let node = button.parentElement; node && node !== document.body; node = node.parentElement) {
                const links = Array.from(node.querySelectorAll('a[href*="filedetails"]'));
                const ids = new Set(links.map(link => itemID(new URL(link.href))).filter(Boolean));
                if (ids.size > 1) return;
                if (ids.size === 1 && (links.length > 1 || node.querySelector('a[href*="/myworkshopfiles"]') ||
                    links.some(link => link.querySelector("img")))) {
                    const id = ids.values().next().value;
                    const title = links.find(link => itemID(new URL(link.href)) === id && link.textContent.trim());
                    return {node, id, title: title?.textContent.trim() || id};
                }
            }
        }
        function subscribed(button) {
            const plus = !!button.querySelector("svg.SVGIcon_Plus");
            const checked = !!button.querySelector("svg.SVGIcon_Check, svg.SVGIcon_X");
            return plus === checked ? undefined : checked;
        }
        function post(payload) {
            window.webkit.messageHandlers.workshopSubscription.postMessage({app: "431960", ...payload});
        }
        // Steam's React mutation updates both the card action and its tick after the
        // server acknowledges Subscribe. Follow only the card whose Plus was clicked.
        function watchSubscription(card, gesture) {
            const observer = new MutationObserver(() => {
                if (!card.node.isConnected) { stop(); return; }
                for (const button of card.node.querySelectorAll(actionSelector)) {
                    if (subscribed(button) !== true || cardFor(button)?.id !== card.id) continue;
                    stop();
                    post({kind: "cardSubscribed", id: card.id, title: card.title, gesture});
                    break;
                }
            });
            const timer = setTimeout(stop, 60000);
            function stop() {
                observer.disconnect();
                clearTimeout(timer);
                watching.delete(card.id);
            }
            watching.set(card.id, stop);
            observer.observe(card.node, {subtree: true, childList: true, attributes: true, attributeFilter: ["class"]});
        }
        addEventListener("pagehide", () => { for (const stop of watching.values()) stop(); });
        document.addEventListener("click", event => {
            if (event.button !== 0 || !(event.target instanceof Element)) return;
            const button = event.target.closest(actionSelector);
            if (!button || button.matches(':disabled, [aria-disabled="true"]') ||
                button.closest('#highlightContent, .commentthread_area, #SubscribeItemBtn')) return;
            const previous = subscribed(button);
            if (previous === undefined) return;
            const page = new URL(location.href);
            const detail = itemID(page);
            const path = page.pathname.replace(/\/$/, "");
            if (!detail && !(path === "/app/431960/workshop" ||
                ((path === "/workshop/browse" || path.endsWith("/myworkshopfiles")) &&
                 page.searchParams.get("appid") === "431960"))) return;
            // A detail page may also contain cards linking to other items.
            const card = detail && button.textContent.trim() ? undefined : cardFor(button);
            const id = card?.id || detail;
            if (!id || (!card && !button.textContent.trim())) return;
            watching.get(id)?.();
            const gesture = event.isTrusted ? crypto.randomUUID() : null;
            if (card && !detail && !previous && gesture) watchSubscription(card, gesture);
            post({kind: event.isTrusted ? "cardIntent" : "cancelCardIntent", id, subscribed: !previous, gesture});
        }, true);
    })();
    """#

    // This isolated world can observe Steam's DOM but exposes no native message
    // handler to page scripts or frames. Steam updates these three CSS classes
    // together only in the success callback of its own subscription request.
    private static let script = #"""
    (() => {
        if (location.origin !== "https://steamcommunity.com" ||
            !/^\/(?:sharedfiles|workshop)\/filedetails\/?$/.test(location.pathname)) return;
        const ids = new URL(location.href).searchParams.getAll("id");
        if (ids.length !== 1 || !/^\d{6,20}$/.test(ids[0])) return;
        const id = ids[0];
        const block = document.getElementById("profileBlock");
        const button = block?.querySelector(":scope > .detailBox > .game_area_purchase_margin > .game_area_purchase_game > div > a#SubscribeItemBtn");
        const action = /^\s*SubscribeItem\(\s*['"](\d+)['"]\s*,\s*['"](\d+)['"]\s*\)\s*;?\s*$/.exec(button?.getAttribute("onclick") || "");
        if (!action || action[1] !== id || action[2] !== "431960") return;
        const add = button.querySelector("#SubscribeItemOptionAdd");
        const existing = button.querySelector("#SubscribeItemOptionSubscribed");
        if (!add || !existing) return;

        const title = document.querySelector(".workshopItemDetailsHeader .workshopItemTitle")?.textContent.trim() || id;
        const size = document.querySelector(".detailsStatsContainerRight .detailsStatRight")?.textContent.trim() || "";
        const unit = /^([\d]+(?:[.,]\d+)?)\s*(B|KB|MB|GB)$/i.exec(size);
        const bytes = unit ? Math.round(Number(unit[1].replace(",", ".")) * (1024 ** ["B","KB","MB","GB"].indexOf(unit[2].toUpperCase()))) : 0;
        const token = crypto.randomUUID();
        let previous;
        let intent;
        let timer;

        function read() {
            if (!button.isConnected || !button.contains(add) || !button.contains(existing)) return;
            const value = button.classList.contains("toggled");
            if (value === existing.classList.contains("selected") && value !== add.classList.contains("selected")) return value;
        }

        function publish(force = false) {
            const value = read();
            if (value === undefined || (!force && value === previous)) return;
            const changed = !force && intent === value && previous === !value;
            clearTimeout(timer);
            intent = undefined;
            previous = value;
            window.webkit.messageHandlers.workshopSubscription.postMessage({
                kind: changed ? "change" : "snapshot", document: token, id, app: action[2], subscribed: value, title, bytes
            });
        }

        button.addEventListener("click", event => {
            clearTimeout(timer);
            intent = undefined;
            if (event.button !== 0) return;
            const value = read();
            if (value === undefined) return;
            window.webkit.messageHandlers.workshopSubscription.postMessage({
                kind: event.isTrusted ? "cardIntent" : "cancelCardIntent", app: action[2], id, subscribed: !value
            });
            if (!event.isTrusted) return;
            intent = !value;
            timer = setTimeout(() => { intent = undefined; }, 120000);
        }, true);
        new MutationObserver(() => publish()).observe(button, {
            attributes: true, subtree: true, attributeFilter: ["class"]
        });
        addEventListener("pagehide", () => { clearTimeout(timer); intent = undefined; });
        addEventListener("pageshow", () => publish(true));
        publish(true);
    })();
    """#
}
