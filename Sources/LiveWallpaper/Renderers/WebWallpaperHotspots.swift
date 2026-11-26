import WebKit

/// A local document may receive desktop input even when the DOM doesn't expose a
/// discrete target. Only DOM controls, cursor hints or named model hit areas claim a click.
enum WebWallpaperHotspots {
    private struct Hit {
        var allowed = false
        var region: CGRect?
    }

    static func read(in webView: WKWebView, at point: CGPoint? = nil, completion: @escaping ([CGRect]) -> Void) {
        guard let point else { completion([]); return }
        inspect(in: webView, at: point, needsRegion: true) { hit in completion(hit.region.map { [$0] } ?? []) }
    }

    static func acceptsInput(in webView: WKWebView, at point: CGPoint, completion: @escaping (Bool) -> Void) {
        inspect(in: webView, at: point, needsRegion: false) { hit in completion(hit.allowed) }
    }

    private static func inspect(in webView: WKWebView, at point: CGPoint, needsRegion: Bool, completion: @escaping (Hit) -> Void) {
        guard let address = webView.url, address.scheme == WebRenderer.scheme, address.host == "wp",
              (0...1).contains(point.x), (0...1).contains(point.y) else { completion(Hit()); return }
        // DOM eligibility and the maximum panel size are decided in the isolated world.
        webView.callAsyncJavaScript(script, arguments: ["nx": point.x, "ny": point.y, "needsRegion": needsRegion],
                                    in: nil, in: .defaultClient) { [weak webView] result in
            guard webView?.url == address, case let .success(value) = result,
                  let row = value as? [Double], !row.isEmpty else { completion(Hit()); return }
            var hit = Hit(allowed: true)
            if row.count == 4, row.allSatisfy({ $0.isFinite && (0...1).contains($0) }) {
                hit.region = CGRect(x: row[0], y: row[1], width: row[2], height: row[3])
            }
            // Only an unobstructed canvas in the main document can request the model test.
            if row.count == 6 {
                let region = CGRect(x: row[0], y: row[1], width: row[2], height: row[3])
                webView?.callAsyncJavaScript("""
                    return window.__lwLive2DNamedHit?.(nx, ny, u, v) === true;
                    """, arguments: ["nx": point.x, "ny": point.y, "u": row[4], "v": row[5]],
                    in: nil, in: .page) { [weak webView] result in
                    guard webView?.url == address else { completion(Hit()); return }
                    if case let .success(answer) = result, (answer as? Bool) == true { hit.region = region }
                    completion(hit)
                }
                return
            }
            completion(hit)
        }
    }

    /// Register with Pixi while its script loads so module-local applications are found
    /// without inspecting the wallpaper's controllers or invoking its tap handlers.
    static func install(in controller: WKUserContentController) {
        controller.addUserScript(WKUserScript(source: live2DScript, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true))
    }

    private static let live2DScript = #"""
    (() => {
        if (location.protocol !== 'lwwp:' || location.host !== 'wp') return;
        const own = (object, key) => object == null ? undefined : Object.getOwnPropertyDescriptor(object, key)?.value;
        const apps = new WeakMap(), registered = new WeakSet();
        const canvasFor = app => own(own(app, 'renderer'), 'view');
        function remember(app) {
            const canvas = canvasFor(app);
            if (canvas instanceof HTMLCanvasElement) apps.set(canvas, app);
        }
        function register() {
            const Application = own(own(window, 'PIXI'), 'Application');
            const add = own(Application, 'registerPlugin');
            if (typeof add !== 'function' || registered.has(Application)) return;
            registered.add(Application);
            add.call(Application, {
                init() { remember(this); },
                destroy() {
                    const canvas = canvasFor(this);
                    if (apps.get(canvas) === this) apps.delete(canvas);
                }
            });
        }
        document.addEventListener('load', e => { if (e.target instanceof HTMLScriptElement) register(); }, true);
        document.addEventListener('DOMContentLoaded', register, {once:true});
        let lastDiscovery = -Infinity;
        function namedHit(nx, ny, u, v) {
            const canvas = document.elementFromPoint(nx * innerWidth, ny * innerHeight);
            if (!(canvas instanceof HTMLCanvasElement)) return false;
            const pixi = own(window, 'PIXI'), Model = own(own(pixi, 'live2d'), 'Live2DModel');
            const modelPrototype = own(Model, 'prototype'), hitTest = own(modelPrototype, 'hitTest');
            if (typeof hitTest !== 'function') return false;
            // A single bundle can construct its app before the script's load event.
            // Discover already published Pixi instances using data descriptors only.
            if (!apps.has(canvas) && performance.now() - lastDiscovery >= 1000) {
                lastDiscovery = performance.now();
                const prototype = own(own(pixi, 'Application'), 'prototype');
                if (prototype) for (const key of Object.keys(window)) {
                    const value = own(window, key);
                    if (value && typeof value === 'object' && own(value, 'stage') && own(value, 'renderer')
                        && Object.prototype.isPrototypeOf.call(prototype, value)) remember(value);
                }
            }
            const app = apps.get(canvas);
            if (!app || canvasFor(app) !== canvas) return false;
            const screen = own(own(app, 'renderer'), 'screen');
            const x = u * own(screen, 'width'), y = v * own(screen, 'height');
            if (!Number.isFinite(x) || !Number.isFinite(y)) return false;
            const stack = [own(app, 'stage')];
            for (let visited = 0; stack.length && visited < 2048; visited++) {
                const object = stack.pop();
                if (!object || own(object, 'visible') === false || own(object, 'renderable') === false
                    || own(object, 'alpha') === 0 || own(object, 'worldAlpha') === 0) continue;
                if (Object.prototype.isPrototypeOf.call(modelPrototype, object)) {
                    const names = hitTest.call(object, x, y);
                    if (Array.isArray(names) && names.some(name => typeof name === 'string' && name.length)) return true;
                }
                const children = own(object, 'children');
                if (Array.isArray(children)) {
                    const remaining = 2048 - visited - stack.length;
                    for (let i = Math.max(0, children.length - remaining); i < children.length; i++)
                        stack.push(own(children, i));
                }
            }
            return false;
        }
        Object.defineProperty(window, '__lwLive2DNamedHit', {value: namedHit});
    })();
    """#

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
            if (!painted || style.visibility !== 'visible') return [1];
            // This single pointer-sized panel follows WebKit's hit test. It never
            // covers an entire canvas, a clipped box, or the corners of a rotated control.
            const l = Math.max(0, viewX - 1), t = Math.max(0, viewY - 1);
            const panel = [l / innerWidth, t / innerHeight, (Math.min(innerWidth, viewX + 1) - l) / innerWidth,
                           (Math.min(innerHeight, viewY + 1) - t) / innerHeight];
            if (priority) return panel;
            if (!needsRegion || hit.getRootNode() !== document || !(hit instanceof HTMLCanvasElement)) return [1];
            // Convert into the CSS content box before scaling to Pixi's logical screen.
            // This accounts for scroll, transformed ancestors, Retina and render resolution.
            const box = win.webkitConvertPointFromPageToNode(hit, new win.WebKitPoint(x + win.scrollX, y + win.scrollY));
            const px = parseFloat(style.paddingLeft), py = parseFloat(style.paddingTop);
            const u = (box.x - hit.clientLeft - px) / (hit.clientWidth - px - parseFloat(style.paddingRight));
            const v = (box.y - hit.clientTop - py) / (hit.clientHeight - py - parseFloat(style.paddingBottom));
            return u >= 0 && u < 1 && v >= 0 && v < 1 ? [...panel, u, v] : [1];
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
