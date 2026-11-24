import AppKit
import WebKit

/// Observe completed primary clicks on the exposed desktop. Finder still receives the
/// original events, and the wallpaper window never takes focus or handles system input.
final class WebWallpaperInput {
    private weak var webView: WKWebView?
    private let isEnabled: () -> Bool
    private var monitor: Any?
    private var press: CGPoint?

    init(webView: WKWebView, isEnabled: @escaping () -> Bool) {
        self.webView = webView
        self.isEnabled = isEnabled
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .leftMouseDragged]) { [weak self] in
            self?.handle($0)
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        press = nil
    }

    deinit { stop() }

    private func handle(_ event: NSEvent) {
        if event.type == .leftMouseDragged {
            press = nil
            return
        }
        let start = press
        press = nil
        guard event.type == .leftMouseDown || start != nil,
              isEnabled(), let webView, let window = webView.window as? DesktopWindow,
              window.isVisible, window.isOnActiveSpace, let screen = window.screen,
              event.modifierFlags.intersection([.control, .shift, .option, .command]).isEmpty,
              event.clickCount == 1, let cgEvent = event.cgEvent else { return }

        // Quartz uses the main display's top-left origin even with another display above it.
        let quartzPoint = cgEvent.location
        let point = CGPoint(x: quartzPoint.x, y: CGDisplayBounds(CGMainDisplayID()).height - quartzPoint.y)
        guard screen.visibleFrame.contains(point), Self.isDesktop(at: point, event: cgEvent) else { return }
        if event.type == .leftMouseDown {
            press = point
            return
        }

        guard let start, hypot(point.x - start.x, point.y - start.y) <= 4 else { return }
        let local = webView.convert(window.convertPoint(fromScreen: point), from: nil)
        if let location = Self.normalizedPoint(local, in: webView.bounds, flipped: webView.isFlipped) {
            Self.dispatchClick(at: location, in: webView)
        }
    }

    static func normalizedPoint(_ point: CGPoint, in bounds: CGRect, flipped: Bool) -> CGPoint? {
        guard bounds.width > 0, bounds.height > 0, bounds.contains(point) else { return nil }
        return CGPoint(x: (point.x - bounds.minX) / bounds.width,
                       y: (flipped ? point.y - bounds.minY : bounds.maxY - point.y) / bounds.height)
    }

    private static func isDesktop(at point: CGPoint, event: CGEvent) -> Bool {
        // Use WindowServer's hit test rather than bounding boxes. A covered wallpaper or an
        // interactive desktop widget, menu, Dock or regular Finder window must not get clicks.
        let hit = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0)
        let target = pid_t(clamping: event.getIntegerValueField(.eventTargetUnixProcessID))
        let desktopOwners = ["com.apple.finder", "com.apple.dock", "com.apple.WindowManager"]
        if hit == 0 {
            // Some versions report no window at all for background clicks.
            guard target > 0, let bundle = NSRunningApplication(processIdentifier: target)?.bundleIdentifier else { return false }
            return desktopOwners.contains(bundle)
        }
        guard hit > 0, let info = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(hit))
                as? [[String: Any]], let window = info.first,
              let level = window[kCGWindowLayer as String] as? Int,
              let owner = window[kCGWindowOwnerPID as String] as? pid_t,
              let bundle = NSRunningApplication(processIdentifier: owner)?.bundleIdentifier else { return false }

        if target > 0 && target != owner {
            guard let receiver = NSRunningApplication(processIdentifier: target)?.bundleIdentifier,
                  desktopOwners.contains(receiver) else { return false }
        }
        let icons = Int(CGWindowLevelForKey(.desktopIconWindow))
        let background = Int(CGWindowLevelForKey(.desktopWindow))
        if level <= background && ["com.apple.dock", "com.apple.WindowManager"].contains(bundle) { return true }
        guard level == icons else { return false }
        if bundle == "com.apple.WindowManager" {
            // The desktop's backdrop can cover Finder's icon hit regions. Ask for the
            // next actual event recipient under it as well; zero means empty backdrop.
            let below = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: hit)
            return below == 0
        }
        guard bundle == "com.apple.finder" else { return false }
        // Older Finder versions expose one window for both icons and empty space. Refine
        // that hit when Accessibility is already available; native icon clicks still work
        // without it since this monitor neither consumes events nor activates the wallpaper.
        guard AXIsProcessTrusted() else { return true }
        var element: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(),
                                                     Float(event.location.x), Float(event.location.y), &element)
        guard result == .success, let element else { return true }
        var role: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
              let role = role as? String else { return true }
        return [kAXScrollAreaRole, kAXListRole, kAXWindowRole].contains(role)
    }

    /// Use viewport CSS coordinates (including on Retina) and hit-test the actual canvas
    /// or DOM element. Only the local wallpaper receives the event, including if the page
    /// navigates between scheduling and evaluating the script.
    static func dispatchClick(at normalized: CGPoint, in webView: WKWebView,
                              completion: ((Any?, Error?) -> Void)? = nil) {
        guard normalized.x.isFinite, normalized.y.isFinite,
              (0...1).contains(normalized.x), (0...1).contains(normalized.y),
              webView.url?.scheme == WebRenderer.scheme, webView.url?.host == "wp" else {
            completion?(false, nil)
            return
        }
        let script = """
        (() => {
          if (location.protocol !== 'lwwp:' || location.hostname !== 'wp') return false;
          const x = Math.min(innerWidth - 1, \(normalized.x) * innerWidth);
          const y = Math.min(innerHeight - 1, \(normalized.y) * innerHeight);
          const target = document.elementFromPoint(x, y);
          if (!target) return false;
          const options = {clientX:x, clientY:y, button:0, bubbles:true, cancelable:true,
                           composed:true, view:window, detail:1};
          const pointer = (name, buttons) => target.dispatchEvent(new PointerEvent(name, {
            ...options, buttons, pointerId:1, pointerType:'mouse', isPrimary:true
          }));
          const mouse = (name, buttons) => target.dispatchEvent(new MouseEvent(name, {...options, buttons}));
          const compatible = pointer('pointerdown', 1);
          if (compatible) mouse('mousedown', 1);
          pointer('pointerup', 0);
          if (compatible) mouse('mouseup', 0);
          mouse('click', 0);
          return true;
        })()
        """
        webView.evaluateJavaScript(script, completionHandler: completion)
    }
}
