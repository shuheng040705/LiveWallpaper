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
        let clickCount: Int
        let completion: Receipt?
    }

    private var pending: [Input] = []
    private var inspecting = false
    private var revision = 0
    private var pressed = false
    private var eventNumber = 0

    private var hasLocalDocument: Bool { url?.scheme == WebRenderer.scheme && url?.host == "wp" }

    func send(_ phase: WallpaperPointerPhase, at point: CGPoint, clickCount: Int = 1, completion: Receipt? = nil) {
        guard hasLocalDocument, window != nil, !bounds.isEmpty, point.x.isFinite, point.y.isFinite,
              (0...1).contains(point.x), (0...1).contains(point.y) else { completion?(false, nil); return }
        // While the web process is checking a down, keep the latest intermediate
        // location. Preserve every down, release and caller waiting for a receipt.
        if inspecting, completion == nil, phase == .drag || phase == .hover,
           let last = pending.last, last.phase == phase, last.completion == nil {
            pending.removeLast()
        }
        pending.append(Input(phase: phase, point: point, clickCount: clickCount, completion: completion))
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
                let delivered = deliver(input.phase, at: input.point, clickCount: input.clickCount)
                input.completion?(delivered, nil)
                continue
            }
            if input.phase == .down && pressed { _ = deliver(.cancel, at: .zero) }
            // A quick release (or another click) may arrive before the asynchronous
            // hit test returns. Preserve the gesture's order across this boundary.
            inspecting = true
            let document = revision
            let address = url
            WebWallpaperHotspots.acceptsInput(in: self, at: input.point) { [weak self] allowed in
                guard let self, self.revision == document else { input.completion?(false, nil); return }
                self.inspecting = false
                let current = self.url == address && self.hasLocalDocument
                let delivered = current && allowed && self.deliver(input.phase, at: input.point, clickCount: input.clickCount)
                input.completion?(delivered, nil)
                self.drain()
            }
        }
    }

    private func deliver(_ phase: WallpaperPointerPhase, at point: CGPoint, clickCount: Int = 1) -> Bool {
        guard let window, hasLocalDocument, !bounds.isEmpty else { return false }
        let kind: NSEvent.EventType
        switch phase {
        case .down: kind = .leftMouseDown
        case .hover, .leave:
            // An inactive WKWebView routes ordinary movement only to scrollbars.
            // This AppKit movement subtype takes WebKit's normal DOM hit-test path.
            // No down is issued and WebKit reads buttons from the physical mouse.
            kind = .leftMouseDragged
        case .drag, .up, .cancel:
            guard pressed else { return false }
            kind = phase == .drag ? .leftMouseDragged : .leftMouseUp
        }
        let local: CGPoint
        if phase == .cancel || phase == .leave {
            // WebKit hit-tests a native move outside the viewport as pointerout/leave.
            // A cancelled release there also avoids activating the last hovered control.
            local = CGPoint(x: bounds.minX - 1, y: bounds.minY - 1)
        } else {
            let x = min(bounds.width.nextDown, bounds.width * point.x)
            let y = min(bounds.height.nextDown, bounds.height * point.y)
            local = CGPoint(x: bounds.minX + x, y: isFlipped ? bounds.minY + y : bounds.maxY - y)
        }
        eventNumber &+= 1
        guard let event = NSEvent.mouseEvent(with: kind, location: convert(local, to: nil), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: eventNumber, clickCount: phase == .down || phase == .up ? max(1, clickCount) : 0,
                pressure: phase == .down || phase == .drag ? 1 : 0) else { return false }
        switch phase {
        case .down:
            pressed = true
            mouseDown(with: event)
        case .hover, .leave, .drag:
            mouseDragged(with: event)
        case .up, .cancel:
            pressed = false
            mouseUp(with: event)
        }
        return true
    }
}
