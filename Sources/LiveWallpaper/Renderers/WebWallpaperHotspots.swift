import WebKit

/// Visible interactive regions in viewport coordinates (top-left origin). A canvas
/// can contain a whole composition, so its bounds alone cannot identify a target.
enum WebWallpaperHotspots {
    // null means that the author supplies no point hit test. Such wallpapers can
    // observe clicks while leaving the desktop as the system event recipient.
    static let canvasProbe = #"""
    function canvasHit(target, x, y) {
        try {
            // BD2 routes in a document capture listener, even when artwork or a
            // loading overlay, rather than the Spine canvas, is the DOM event target.
            if (typeof window.inspectPointerHit === 'function') return window.inspectPointerHit(x, y)?.selectedCandidate != null;
            if (!(target instanceof HTMLCanvasElement)) return null;
            const spine = window.__rt5, live2d = window.wallpaperInteraction;
            if (typeof spine?.hitTest === 'function') return spine.hitTest(x, y) != null;
            if (typeof live2d?.candidates === 'function') {
                if (live2d.isBusy?.() || (typeof settings !== 'undefined' && settings.interactive === false)) return false;
                if (live2d.candidates(x, y).length) return true;
                return live2d.idle === 0 && !!live2d.hits?.(x, y).some(name =>
                    /^(touch_head|touch_body|touch_special)$/.test(name) && live2d.manager?.definitions?.[name]);
            }
            if (typeof window.hitNameAt === 'function') return window.hitNameAt(x, y) != null;
            if (document.getElementById('hotspots')?.querySelector('.hotspot[data-hit]')) return false;
        } catch { return false; } // Models can disappear while the next skin is loading.
        return null;
    }
    """#

    private static let script = #"""
    return (() => {
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

        // CardTouch exports expose projected quads as well as point hit testing.
        // Pre-position stable rectangular targets so a click immediately after a
        // fast mouse move is caught before the first mouseMoved callback returns.
        const spine = window.__rt5;
        if (typeof spine?.touch === 'function' && typeof spine.quad === 'function' && typeof spine.hitTest === 'function') {
            try {
                for (const region of spine.touch().slice(0, limit)) {
                    if (!region.enabled || result.length >= limit) continue;
                    const q = spine.quad(region.index);
                    if (!Array.isArray(q) || q.length !== 4) continue;
                    const xs = q.map(p => p.x), ys = q.map(p => p.y);
                    const left = Math.min(...xs), top = Math.min(...ys), right = Math.max(...xs), bottom = Math.max(...ys);
                    // Rotated quads use the cursor hit test below. Their bounding box
                    // includes corners belonging to the desktop.
                    if (!q.every(p => Math.min(Math.abs(p.x-left), Math.abs(p.x-right)) < .01 &&
                                      Math.min(Math.abs(p.y-top), Math.abs(p.y-bottom)) < .01)) continue;
                    const x = (left + right) / 2, y = (top + bottom) / 2;
                    if (spine.hitTest(x, y) != null) add({left, top, right, bottom}, hit => hit instanceof HTMLCanvasElement);
                }
            } catch { /* Some versions publish the runtime before its meshes are ready. */ }
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
        // A canvas usually fills the screen. Ask the author's active hit test at the
        // pointer rather than making its entire bounding box consume desktop clicks.
        if (Number.isFinite(mouseX) && Number.isFinite(mouseY)) {
            const x = mouseX * w, y = mouseY * h;
            const target = document.elementFromPoint(x, y);
            \#(canvasProbe)
            let hit = canvasHit(target, x, y) === true;
            if (!hit && target && !(target instanceof HTMLCanvasElement) && getComputedStyle(target).cursor === 'pointer') {
                // Widget frameworks often register delegated events on ordinary divs.
                // Exclude inherited pointer cursors on entire-page wrappers.
                const box = target.getBoundingClientRect();
                hit = box.width * box.height > 0 && box.width * box.height < w * h * .95;
            }
            if (hit && !result.some(([l,t,width,height]) => mouseX >= l && mouseX < l+width && mouseY >= t && mouseY < t+height))
                add({left:x-1, top:y-1, right:x+1, bottom:y+1}, el => el === target);
        }
        return result;
    })()
    """#

    static func read(in webView: WKWebView, at point: CGPoint? = nil, completion: @escaping ([CGRect]) -> Void) {
        guard let url = webView.url, url.scheme == WebRenderer.scheme, url.host == "wp" else {
            completion([])
            return
        }
        let arguments: [String: Any] = ["mouseX": point.map { $0.x as Any } ?? NSNull(),
                                        "mouseY": point.map { $0.y as Any } ?? NSNull()]
        webView.callAsyncJavaScript(script, arguments: arguments, in: nil, in: .page) { [weak webView] result in
            guard webView?.url == url, case let .success(value) = result, let rows = value as? [[Double]] else {
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
