import WebKit

/// Keep Steam's floating Workshop menus aligned with their controls.
enum SteamWorkshopMenuLayout {
    static func install(in controller: WKUserContentController) {
        controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true, in: .defaultClient))
    }

    private static let script = #"""
    (() => {
        if (location.origin !== "https://steamcommunity.com") return;
        const path = location.pathname.replace(/\/$/, "");
        const workshopBrowse = path === "/workshop/browse" || path.endsWith("/myworkshopfiles");
        if (path !== "/app/431960/workshop" &&
            !(workshopBrowse && new URL(location.href).searchParams.get("appid") === "431960")) return;
        // Steam positions these menus with Floating UI. Both WebKit's native popover
        // and Steam's compatibility stylesheet can center the box a second time.
        const style = document.createElement("style");
        style.textContent = `
            /* Filters are listboxes. Sort and search options are radio groups
               inside a separate Floating UI positioner. */
            [role="listbox"]:is([popover], [class~=":popover-open"]),
            [data-floating-ui-focusable]:is([popover="manual"], [class~=":popover-open"]):has([role="radiogroup"]) {
                margin: 0 !important;
                right: auto !important;
                bottom: auto !important;
            }
            /* Steam's browse sidebar blurs the backdrop, creating a fixed-position
               containing block for its in-page popover fallback. Its translate()
               is already relative to the viewport. Release the containing block
               while the list is open so scrolling only moves it once. */
            .Panel:has([role="listbox"][class~=":popover-open"]) {
                -webkit-backdrop-filter: none !important;
                backdrop-filter: none !important;
            }
        `;
        if (document.documentElement) document.documentElement.appendChild(style);
        else document.addEventListener("DOMContentLoaded", () => document.head.appendChild(style), { once: true });
    })();
    """#
}
