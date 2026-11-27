import WebKit

/// Exposed desktops can forward input to a local document. With app windows in front,
/// only a control, cursor hint or author-defined model hit also receives the click.
enum WebWallpaperHotspots {
    static func contains(in webView: WKWebView, at point: CGPoint, completion: @escaping (Bool) -> Void) {
        inspect(in: webView, at: point, requiresHotspot: true, completion: completion)
    }

    static func acceptsInput(in webView: WKWebView, at point: CGPoint, completion: @escaping (Bool) -> Void) {
        inspect(in: webView, at: point, requiresHotspot: false, completion: completion)
    }

    private static func inspect(in webView: WKWebView, at point: CGPoint, requiresHotspot: Bool,
                                completion: @escaping (Bool) -> Void) {
        guard let address = webView.url, address.scheme == WebRenderer.scheme, address.host == "wp",
              (0...1).contains(point.x), (0...1).contains(point.y) else { completion(false); return }
        webView.callAsyncJavaScript(script, arguments: ["nx": point.x, "ny": point.y, "requiresHotspot": requiresHotspot],
                                    in: nil, in: .defaultClient) { [weak webView] result in
            guard let webView, webView.url == address, case let .success(value) = result,
                  let row = value as? [Double], !row.isEmpty else { completion(false); return }
            // A one-value result is an allowed local DOM point. The bit records whether
            // a foreground click at this point should also go to the wallpaper.
            guard row.count == 3 else { completion(!requiresHotspot || row == [1]); return }
            webView.callAsyncJavaScript("return window.__lwCanvasHit?.(nx, ny, u, v, cursorHint) === true;",
                arguments: ["nx": point.x, "ny": point.y, "u": row[0], "v": row[1], "cursorHint": row[2] != 0],
                in: nil, in: .page) { [weak webView] answer in
                guard webView?.url == address, case let .success(hit) = answer else { completion(false); return }
                completion(hit as? Bool == true)
            }
        }
    }

    /// Register with Pixi while its script loads so module-local applications are found
    /// without inspecting the wallpaper's controllers or invoking its tap handlers.
    static func install(in controller: WKUserContentController) {
        controller.addUserScript(WKUserScript(source: WebCardTouchHotspots.script, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true))
        controller.addUserScript(WKUserScript(source: canvasHitScript, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true))
    }

    private static let canvasHitScript = #"""
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
        function namedHit(canvas, u, v) {
            const pixi = own(window, 'PIXI'), Model = own(own(pixi, 'live2d'), 'Live2DModel');
            const modelPrototype = own(Model, 'prototype'), hitTest = own(modelPrototype, 'hitTest');
            if (typeof hitTest !== 'function') return null;
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
            if (!app || canvasFor(app) !== canvas) return null;
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
        // Some authors project their model's interactive regions into a transparent
        // sibling overlay. Its markers can move every frame and may only be laid out
        // on request through the wallpaper's own hints property.
        function projectedHit(canvas, x, y) {
            const state = window.__lwUserPropertyState;
            if (!state?.values?.interaction || !state.values.hints) return null;
            const overlay = canvas.nextElementSibling;
            if (!overlay || !overlay.querySelector('[data-hit]') ||
                getComputedStyle(overlay).pointerEvents !== 'none') return null;
            const [kind, enabled] = JSON.parse(state.values.interaction);
            const [hintKind, hints] = JSON.parse(state.values.hints);
            const on = value => [true, 1, 'true', '1'].includes(value);
            const off = value => [false, 0, 'false', '0'].includes(value);
            if (kind !== 'bool' || hintKind !== 'bool' || (!on(hints) && !off(hints))) return null;
            if (!on(enabled)) return false;
            const listener = state.listener;
            if (listener !== window.wallpaperPropertyListener || typeof listener?.applyUserProperties !== 'function') return null;
            const requestLayout = off(hints) && overlay.hidden;
            const previous = overlay.style.getPropertyValue('pointer-events');
            const priority = overlay.style.getPropertyPriority('pointer-events');
            try {
                if (requestLayout) listener.applyUserProperties({hints:{type:'bool', value:true}});
                overlay.style.setProperty('pointer-events', 'auto', 'important');
                for (const node of document.elementsFromPoint(x, y)) {
                    if (node === canvas) break;
                    const marker = node.closest('[data-hit]');
                    if (!marker || !overlay.contains(marker)) continue;
                    const r = marker.getBoundingClientRect();
                    const width = Math.min(innerWidth, r.right) - Math.max(0, r.left);
                    const height = Math.min(innerHeight, r.bottom) - Math.max(0, r.top);
                    if (width > 0 && height > 0 && width * height < innerWidth * innerHeight * .95) return true;
                }
                return false;
            } finally {
                overlay.style.setProperty('pointer-events', previous, priority);
                if (requestLayout) listener.applyUserProperties({hints:{type:'bool', value:hints}});
            }
        }
        Object.defineProperty(window, '__lwCanvasHit', {value(nx, ny, u, v, cursorHint) {
            const x = Math.min(nx * innerWidth, innerWidth - 1), y = Math.min(ny * innerHeight, innerHeight - 1);
            const canvas = document.elementFromPoint(x, y);
            if (!(canvas instanceof HTMLCanvasElement)) return false;
            const card = window.__lwCardTouchHit?.(x, y, canvas);
            if (typeof card === 'boolean') return card;
            const marker = projectedHit(canvas, x, y);
            return marker ?? namedHit(canvas, u, v) ?? cursorHint;
        }});
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
            const cursorHint = cursors.has(style.cursor.split(',').pop().trim());
            if (!painted || style.visibility !== 'visible') return [0];
            const canvas = hit.getRootNode() === document && hit instanceof HTMLCanvasElement;
            if (priority || (cursorHint && !canvas)) return [1];
            if (!requiresHotspot || !canvas) return [0];
            // Convert into the CSS content box before scaling to Pixi's logical screen.
            // This accounts for scroll, transformed ancestors, Retina and render resolution.
            const box = win.webkitConvertPointFromPageToNode(hit, new win.WebKitPoint(x + win.scrollX, y + win.scrollY));
            const px = parseFloat(style.paddingLeft), py = parseFloat(style.paddingTop);
            const u = (box.x - hit.clientLeft - px) / (hit.clientWidth - px - parseFloat(style.paddingRight));
            const v = (box.y - hit.clientTop - py) / (hit.clientHeight - py - parseFloat(style.paddingBottom));
            return u >= 0 && u < 1 && v >= 0 && v < 1 ? [u, v, Number(cursorHint)] : [0];
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
