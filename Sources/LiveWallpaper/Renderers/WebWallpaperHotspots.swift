import WebKit

/// Visible interactive regions in viewport coordinates (top-left origin). A canvas
/// can contain a whole composition, so its bounds alone cannot identify a target.
enum WebWallpaperHotspots {
    private static let script = #"""
    (() => {
        if (location.protocol !== 'lwwp:' || location.hostname !== 'wp') return [];
        const w = innerWidth, h = innerHeight;
        if (!(w > 0 && h > 0)) return [];
        const result = [];
        const limit = 64;
        function add(rect, acceptsHit) {
            const left = Math.max(0, rect.left), top = Math.max(0, rect.top);
            const right = Math.min(w, rect.right), bottom = Math.min(h, rect.bottom);
            const width = (right - left) / w, height = (bottom - top) / h;
            // A backdrop or a canvas-sized fallback is a desktop click, not a specific target.
            if (!(width > 0 && height > 0 && width * height < 0.95)) return;
            const hit = document.elementFromPoint((left + right) / 2, (top + bottom) / 2);
            if (hit && acceptsHit(hit)) result.push([left / w, top / h, width, height]);
        }

        // Some Spine wallpapers expose their moving mesh bounds in a non-interactive
        // hint overlay. The canvas beneath those boxes handles the actual click.
        const overlay = document.getElementById('hotspots');
        const stage = document.querySelector('canvas#stage');
        if (overlay && stage && overlay.querySelector('.hotspot[data-hit]')) {
            const values = window.__lwUserPropertyState?.values;
            const bool = key => {
                if (!values?.[key]) return undefined;
                const [type, value] = JSON.parse(values[key]);
                if (type !== 'bool') return undefined;
                return [true, 1, 'true', '1'].includes(value);
            };
            const hints = bool('hints');
            const listener = window.wallpaperPropertyListener;
            const temporarilyShow = hints === false && overlay.hidden &&
                typeof listener?.applyUserProperties === 'function';
            if (bool('interaction') === true && (!overlay.hidden || temporarilyShow)) {
                try {
                    // The author computes the boxes only when hints are enabled. Sample and
                    // restore synchronously, before WebKit can paint a frame or handle input.
                    if (temporarilyShow) listener.applyUserProperties({ hints: { value: true } });
                    let visited = 0;
                    for (const box of overlay.querySelectorAll('.hotspot[data-hit]')) {
                        if (result.length >= limit || ++visited > 256) break;
                        if (box.hidden) continue;
                        add(box.getBoundingClientRect(), hit => hit === stage);
                    }
                } finally {
                    if (temporarilyShow) listener.applyUserProperties({ hints: { value: false } });
                }
            }
        }

        const selector = 'button, a[href], input, select, textarea, summary, [role="button"], [role="link"], [onclick]';
        let visited = 0;
        for (const control of document.querySelectorAll(selector)) {
            if (result.length >= limit || ++visited > 256) break;
            if (control.matches(':disabled') || control.closest('[inert], [aria-disabled="true"]')) continue;
            const style = getComputedStyle(control);
            if (style.pointerEvents === 'none' || style.visibility !== 'visible' || Number(style.opacity) === 0) continue;
            for (const rect of control.getClientRects()) {
                if (result.length >= limit) break;
                add(rect, hit => control.contains(hit));
            }
        }
        return result;
    })()
    """#

    static func read(in webView: WKWebView, completion: @escaping ([CGRect]) -> Void) {
        guard let url = webView.url, url.scheme == WebRenderer.scheme, url.host == "wp" else {
            completion([])
            return
        }
        webView.evaluateJavaScript(script) { [weak webView] value, _ in
            guard webView?.url == url, let rows = value as? [[Double]] else {
                completion([])
                return
            }
            let rects = rows.prefix(64).compactMap { row -> CGRect? in
                guard row.count == 4, row.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
                      row[2] > 0, row[3] > 0, row[2] * row[3] < 0.95 else { return nil }
                let rect = CGRect(x: row[0], y: row[1], width: row[2], height: row[3])
                    .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
                return rect.isEmpty ? nil : rect
            }
            completion(rects)
        }
    }
}
