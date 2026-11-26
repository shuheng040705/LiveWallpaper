import WebKit

/// Report candidate IDs from Steam's browse UI. Only the native authenticated
/// lookup can decide that a candidate is subscribed and missing from the library.
enum SteamWorkshopListSubscriptions {
    static func install(in controller: WKUserContentController, world: WKContentWorld, handler: String) {
        let script = #"""
        (() => {
            if (location.origin !== "https://steamcommunity.com") return;
            const destination = window.webkit.messageHandlers[\#(String(reflecting: handler))];
            const action = 'button[data-accent-color="green"], [role="button"][data-accent-color="green"]';
            const detail = 'a[href*="filedetails"]';
            let reported = new Set();
            let address = "";
            let timer = 0;

            function isListing() {
                const url = new URL(location.href);
                const path = url.pathname.replace(/\/$/, "");
                return path === "/app/431960/workshop" ||
                    (url.searchParams.get("appid") === "431960" &&
                     (path === "/workshop/browse" || path.endsWith("/myworkshopfiles")));
            }

            function itemID(link) {
                let url;
                try { url = new URL(link.href); } catch { return; }
                if (url.origin !== location.origin || !/^\/(sharedfiles|workshop)\/filedetails\/?$/.test(url.pathname)) return;
                const ids = url.searchParams.getAll("id");
                if (ids.length === 1 && /^\d{6,20}$/.test(ids[0])) return ids[0];
            }

            function cardID(mark) {
                // Steam's grid and compact rows both link their cover and their
                // title to the same item. Ignore controls elsewhere on the page.
                for (let card = mark.closest(".Panel"); card; card = card.parentElement?.closest(".Panel")) {
                    const links = Array.from(card.querySelectorAll(detail));
                    if (links.length < 2) continue;
                    const id = itemID(links[0]);
                    if (!id || !links.every(link => itemID(link) === id)) return;
                    if (links.some(link => link.querySelector("img")) && links.some(link => link.textContent.trim())) return id;
                }
            }

            function post(ids) {
                for (let start = 0; start < ids.length; start += 32) {
                    destination.postMessage({kind: "listSubscriptions", app: "431960", ids: ids.slice(start, start + 32)});
                }
            }

            function scan() {
                timer = 0;
                if (address !== location.href) { address = location.href; reported.clear(); }
                if (!isListing()) return;
                const found = new Set();
                for (const icon of document.querySelectorAll("svg.SVGIcon_Check, svg.SVGIcon_X")) {
                    const button = icon.closest("button, [role=button]");
                    // The persistent status badge is a check outside a button.
                    // The quick-action check can turn into an X on hover.
                    if (button ? !button.matches(action) : !icon.classList.contains("SVGIcon_Check")) continue;
                    const id = cardID(icon);
                    if (id) found.add(id);
                }
                post(Array.from(found).filter(id => !reported.has(id)));
                reported = found;
            }

            function schedule() {
                if (!timer) timer = setTimeout(scan, 80);
            }

            // A quick-action button can disappear entirely when the pointer
            // leaves. Remember an actual subscribe click before Steam rerenders.
            document.addEventListener("click", event => {
                if (!event.isTrusted || event.button !== 0 || !isListing()) return;
                const button = event.composedPath().find(node => node instanceof Element && node.matches(action));
                if (!button || button.matches(":disabled, [aria-disabled=true]") ||
                    !button.querySelector("svg.SVGIcon_Plus")) return;
                const id = cardID(button);
                if (id) post([id]);
            }, true);

            const changes = new MutationObserver(records => {
                // Steam lazily inserts badges, reuses result cards and replaces
                // complete rows. Coalesce those changes and ignore unrelated text.
                if (records.some(record => record.type === "attributes"
                    ? record.target.matches("svg, a, [data-accent-color]")
                    : [...record.addedNodes, ...record.removedNodes].some(node => node.nodeType === 1))) schedule();
            });
            changes.observe(document, {subtree: true, childList: true, attributes: true,
                attributeFilter: ["href", "class", "data-accent-color"]});
            function refresh() { reported.clear(); schedule(); }
            addEventListener("pageshow", refresh);
            addEventListener("popstate", refresh);
            addEventListener("online", refresh);
            document.addEventListener("visibilitychange", () => { if (!document.hidden) refresh(); });
            schedule();
        })();
        """#
        controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true, in: world))
    }
}
