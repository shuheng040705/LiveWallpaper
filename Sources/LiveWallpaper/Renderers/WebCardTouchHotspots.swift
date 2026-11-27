/// CardTouch exposes the same point test used by its pointer handler. Its full-screen
/// fallback is eligible when the desktop is exposed, but is not a distinct foreground hotspot.
enum WebCardTouchHotspots {
    static let script = #"""
    (() => {
        if (location.protocol !== 'lwwp:' || location.host !== 'wp') return;
        function coversViewport(quad) {
            return [[0,0],[innerWidth,0],[innerWidth,innerHeight],[0,innerHeight]].every(([x,y]) => {
                const sides = quad.map((a, i) => {
                    const b = quad[(i + 1) % 4];
                    return (b.x - a.x) * (y - a.y) - (b.y - a.y) * (x - a.x);
                });
                return sides.every(s => s >= 0) || sides.every(s => s <= 0);
            });
        }
        Object.defineProperty(window, '__lwCardTouchHit', {value(x, y, canvas) {
            const rt = window.__rt5;
            if (typeof rt?.touch !== 'function' || typeof rt.quad !== 'function' ||
                typeof rt.hitTest !== 'function') return null;
            const receivers = [...document.querySelectorAll('canvas')].filter(c => {
                const css = getComputedStyle(c);
                return css.pointerEvents !== 'none' && css.visibility === 'visible' && c.getClientRects().length;
            });
            if (receivers.length !== 1 || receivers[0] !== canvas) return null;
            const id = rt.hitTest(x, y);
            if (!Number.isSafeInteger(id)) return false;
            const active = rt.touch();
            if (!Array.isArray(active) || !active.some(e => e?.enabled === true && e.index === id)) return false;
            const quad = rt.quad(id);
            return Array.isArray(quad) && quad.length === 4 &&
                quad.every(p => Number.isFinite(p?.x) && Number.isFinite(p?.y)) && !coversViewport(quad);
        }});
    })();
    """#
}
