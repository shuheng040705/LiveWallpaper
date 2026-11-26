import WebKit

/// A local document may receive desktop input even when the DOM doesn't expose a
/// discrete target, e.g. a WebGL scene. Only explicit UI signals claim a desktop click.
enum WebWallpaperHotspots {
    private struct Hit {
        var allowed = false
        var region: CGRect?
    }

    static func read(in webView: WKWebView, at point: CGPoint? = nil, completion: @escaping ([CGRect]) -> Void) {
        guard let point else { completion([]); return }
        inspect(in: webView, at: point) { hit in completion(hit.region.map { [$0] } ?? []) }
    }

    static func acceptsInput(in webView: WKWebView, at point: CGPoint, completion: @escaping (Bool) -> Void) {
        inspect(in: webView, at: point) { hit in completion(hit.allowed) }
    }

    private static func inspect(in webView: WKWebView, at point: CGPoint, completion: @escaping (Hit) -> Void) {
        guard let address = webView.url, address.scheme == WebRenderer.scheme, address.host == "wp",
              (0...1).contains(point.x), (0...1).contains(point.y) else { completion(Hit()); return }
        // Use WebKit's isolated world. No wallpaper globals, properties or
        // event handlers are consulted or called to discover a hotspot.
        webView.callAsyncJavaScript(script, arguments: ["nx": point.x, "ny": point.y],
                                    in: nil, in: .defaultClient) { [weak webView] result in
            guard webView?.url == address, case let .success(value) = result,
                  let row = value as? [Double], !row.isEmpty else { completion(Hit()); return }
            var hit = Hit(allowed: true)
            if row.count == 4, row.allSatisfy({ $0.isFinite && (0...1).contains($0) }) {
                hit.region = CGRect(x: row[0], y: row[1], width: row[2], height: row[3])
            }
            completion(hit)
        }
    }

    private static let script = #"""
    if (location.protocol !== 'lwwp:' || location.hostname !== 'wp' || !(innerWidth && innerHeight)) return [];
    const viewX = Math.min(nx * innerWidth, innerWidth - 1), viewY = Math.min(ny * innerHeight, innerHeight - 1);
    const controls = 'button,a[href],area[href],input,select,textarea,summary,audio[controls],video[controls]';
    const roles = new Set('button link checkbox radio switch slider scrollbar spinbutton combobox textbox searchbox tab option menuitem menuitemcheckbox menuitemradio treeitem'.split(' '));
    const cursors = new Set('pointer grab grabbing move crosshair ew-resize ns-resize nwse-resize nesw-resize col-resize row-resize'.split(' '));

    // A plain canvas can draw any shape, or implement only hover. Its bounds
    // don't tell us which pixels handle a click. A changing CSS cursor does.
    let x = viewX, y = viewY, priority = false, painted = true;
    let hit = document.elementFromPoint(x, y);
    for (let depth = 0; hit && depth < 32; depth++) {
        const win = hit.ownerDocument.defaultView;
        for (let node = hit; node; node = node.assignedSlot || node.parentElement || node.getRootNode().host) {
            if (node.matches(':disabled,[inert],[aria-disabled="true"],object,embed,input[type=file]')) return [];
            if (node.localName === 'label' && node.control?.matches(':disabled,input[type=file]')) return [];
            const style = win.getComputedStyle(node);
            if (style.opacity === '0') painted = false;
            if (style.visibility !== 'visible') continue;
            if (node.matches(controls) || node.isContentEditable ||
                (node.localName === 'label' && node.control) || node.getAttribute('role')?.split(/\s+/).some(role => roles.has(role))) priority = true;
            // Programmatic focus and event listeners on a full-screen background
            // alone do not distinguish its interactive pixels from empty space.
            if (node.matches('[tabindex],[onclick],[onpointerdown],[onmousedown],[draggable="true"]')) {
                const r = node.getBoundingClientRect();
                if (r.width * r.height < win.innerWidth * win.innerHeight * .95 &&
                    (node.tabIndex >= 0 || node.matches('[onclick],[onpointerdown],[onmousedown],[draggable="true"]'))) priority = true;
            }
        }
        const shadow = hit.shadowRoot;
        const inner = shadow?.elementFromPoint(x, y);
        if (inner && inner !== hit) { hit = inner; continue; }

        if (!hit.matches('iframe,frame')) {
            const style = win.getComputedStyle(hit);
            if (style.visibility === 'visible' && style.opacity !== '0' && cursors.has(style.cursor.split(',').pop().trim())) priority = true;
            if (!priority || !painted) return [1];
            // This single pointer-sized panel follows WebKit's hit test. It never
            // covers an entire canvas, a clipped box, or the corners of a rotated control.
            const l = Math.max(0, viewX - 1), t = Math.max(0, viewY - 1);
            return [l / innerWidth, t / innerHeight, (Math.min(innerWidth, viewX + 1) - l) / innerWidth,
                    (Math.min(innerHeight, viewY + 1) - t) / innerHeight];
        }

        const child = hit.contentDocument;
        if (!child) return [];  // Cross-origin and opaque sandbox frames.
        const address = new URL(child.URL);
        if (!(address.protocol === 'lwwp:' && address.host === 'wp') &&
            !['about:srcdoc','about:blank'].includes(address.href)) return [];
        const rect = hit.getBoundingClientRect();
        if (!(rect.width && rect.height && hit.offsetWidth && hit.offsetHeight)) return [];
        // Convert from parent viewport into the child viewport. WebKit's coordinate
        // conversion also accounts for transformed ancestors and the page scroll.
        let local;
        if (typeof win.webkitConvertPointFromPageToNode === 'function' && win.WebKitPoint) {
            local = win.webkitConvertPointFromPageToNode(hit, new win.WebKitPoint(x + win.scrollX, y + win.scrollY));
        } else {
            local = {x:(x - rect.left) * hit.offsetWidth / rect.width, y:(y - rect.top) * hit.offsetHeight / rect.height};
        }
        const boxStyle = win.getComputedStyle(hit);
        x = local.x - hit.clientLeft - parseFloat(boxStyle.paddingLeft);
        y = local.y - hit.clientTop - parseFloat(boxStyle.paddingTop);
        hit = child.elementFromPoint(x, y);
    }
    return [];
    """#
}
