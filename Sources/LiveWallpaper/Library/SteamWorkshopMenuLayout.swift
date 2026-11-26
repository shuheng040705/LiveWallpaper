import WebKit

/// Keep Steam's floating filter list in the WebKit viewport coordinate system.
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
            [role="listbox"][popover], [role="listbox"][class~=":popover-open"] {
                margin: 0 !important;
                right: auto !important;
                bottom: auto !important;
            }
        `;
        if (document.documentElement) document.documentElement.appendChild(style);
        else document.addEventListener("DOMContentLoaded", () => document.head.appendChild(style), { once: true });
    })();
    """#
}
