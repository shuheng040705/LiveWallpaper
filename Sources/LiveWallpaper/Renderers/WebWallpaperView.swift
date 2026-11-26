import AppKit
import WebKit

/// Holds the input sequence for one local wallpaper document. Sending directly to
/// WKWebView's NSResponder methods lets WebKit own pointer capture and form controls
/// without activating a window or posting a mouse event to the desktop.
final class WebWallpaperView: WKWebView {
    typealias Receipt = (Any?, Error?) -> Void

    private struct Input {
        let phase: WallpaperPointerPhase
        let point: CGPoint
        let checkCanvasHit: Bool
        let completion: Receipt?
    }

    private var pending: [Input] = []
    private var inspecting = false
    private var revision = 0
    private var pressed = false
    private var eventNumber = 0

    private var hasLocalDocument: Bool { url?.scheme == WebRenderer.scheme && url?.host == "wp" }

    func send(_ phase: WallpaperPointerPhase, at point: CGPoint, checkCanvasHit: Bool = false, completion: Receipt? = nil) {
        guard hasLocalDocument, window != nil, !bounds.isEmpty, point.x.isFinite, point.y.isFinite,
              (0...1).contains(point.x), (0...1).contains(point.y) else { completion?(false, nil); return }
        // While the web process is checking a down, keep the latest intermediate
        // location. Preserve every down, release and caller waiting for a receipt.
        if inspecting, completion == nil, phase == .drag || phase == .hover,
           let last = pending.last, last.phase == phase, last.completion == nil {
            pending.removeLast()
        }
        pending.append(Input(phase: phase, point: point, checkCanvasHit: checkCanvasHit, completion: completion))
        drain()
    }

    func resetPointer(release: Bool) {
        revision &+= 1
        inspecting = false
        let abandoned = pending
        pending.removeAll()
        if release, hasLocalDocument, pressed { _ = deliver(.cancel, at: .zero) }
        pressed = false
        for input in abandoned { input.completion?(false, nil) }
    }

    private func drain() {
        while !inspecting && !pending.isEmpty {
            let input = pending.removeFirst()
            guard hasLocalDocument, window != nil else { input.completion?(false, nil); continue }
            if input.phase != .down && input.phase != .hover {
                let delivered = deliver(input.phase, at: input.point)
                input.completion?(delivered, nil)
                continue
            }
            if input.phase == .down && pressed { _ = deliver(.cancel, at: .zero) }
            // A quick release (or another click) may arrive before the asynchronous
            // hit test returns. Preserve the gesture's order across this boundary.
            inspecting = true
            let document = revision
            let address = url
            let script = """
                if (location.protocol !== 'lwwp:' || location.hostname !== 'wp') return false;
                const x = Math.min(innerWidth - 1, nx * innerWidth), y = Math.min(innerHeight - 1, ny * innerHeight);
                const hit = document.elementFromPoint(x, y);
                if (!hit || hit.closest(':disabled, [inert], [aria-disabled="true"], iframe, frame, object, embed, input[type=file]')) return false;
                if (checkCanvasHit) {
                    \(WebWallpaperHotspots.canvasProbe)
                    if (canvasHit(hit, x, y) === false) return false;
                }
                if (phase === 'down' && hit instanceof HTMLCanvasElement) {
                    // Keep an unhandled canvas drag inside this document. Author code
                    // can transfer or release capture in its own pointerdown handler.
                    hit.addEventListener('pointerdown', event => {
                        if (event.isTrusted && event.button === 0) hit.setPointerCapture(event.pointerId);
                    }, {capture:true, once:true});
                }
                return true;
                """
            callAsyncJavaScript(script, arguments: ["nx": input.point.x, "ny": input.point.y,
                                                    "checkCanvasHit": input.checkCanvasHit, "phase": input.phase.rawValue], in: nil, in: .page) { [weak self] result in
                guard let self, self.revision == document else { input.completion?(false, nil); return }
                self.inspecting = false
                switch result {
                case .success(let value):
                    let allowed = self.url == address && self.hasLocalDocument && value as? Bool == true
                    let delivered = allowed && self.deliver(input.phase, at: input.point)
                    input.completion?(delivered, nil)
                case .failure(let error):
                    input.completion?(false, error)
                }
                self.drain()
            }
        }
    }

    private func deliver(_ phase: WallpaperPointerPhase, at point: CGPoint) -> Bool {
        guard let window, hasLocalDocument, !bounds.isEmpty else { return false }
        let kind: NSEvent.EventType
        switch phase {
        case .down: kind = .leftMouseDown
        case .hover: kind = .mouseMoved
        case .drag, .up, .cancel:
            guard pressed else { return false }
            kind = phase == .drag ? .leftMouseDragged : .leftMouseUp
        }
        let local: CGPoint
        if phase == .cancel {
            // Release capture outside this document to avoid activating the control.
            local = CGPoint(x: bounds.minX - 1, y: bounds.minY - 1)
        } else {
            let x = min(bounds.width.nextDown, bounds.width * point.x)
            let y = min(bounds.height.nextDown, bounds.height * point.y)
            local = CGPoint(x: bounds.minX + x, y: isFlipped ? bounds.minY + y : bounds.maxY - y)
        }
        eventNumber &+= 1
        guard let event = NSEvent.mouseEvent(with: kind, location: convert(local, to: nil), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: eventNumber, clickCount: phase == .hover ? 0 : 1,
                pressure: phase == .down || phase == .drag ? 1 : 0) else { return false }
        switch phase {
        case .down:
            pressed = true
            mouseDown(with: event)
        case .drag:
            mouseDragged(with: event)
        case .up, .cancel:
            pressed = false
            mouseUp(with: event)
        case .hover:
            mouseMoved(with: event)
        }
        return true
    }
}
