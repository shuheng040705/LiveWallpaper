import AppKit
import WebKit

/// Desktop clicks are observed in the normal desktop. Stage Manager requires a real
/// nonactivating event recipient over each hotspot before the mouse goes down.
final class WebWallpaperInput {
    private weak var webView: WKWebView?
    private let isEnabled: () -> Bool
    private var monitor: Any?
    private var localMovement: Any?
    private var press: CGPoint?
    private var timer: Timer?
    private var panels: [WebWallpaperHotspotPanel] = []
    private var generation = 0
    private var reading = false
    private var nextRead = 0.0
    private var nextHoverCheck = 0.0

    static var stageManagerEnabled: Bool {
        CFPreferencesGetAppBooleanValue("GloballyEnabled" as CFString, "com.apple.WindowManager" as CFString, nil)
    }

    init(webView: WKWebView, isEnabled: @escaping () -> Bool) {
        self.webView = webView
        self.isEnabled = isEnabled
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .leftMouseDragged, .mouseMoved]) { [weak self] event in
            if event.type == .mouseMoved { self?.hoverChanged(event) }
            else { self?.handle(event) }
        }
        localMovement = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .flagsChanged]) { [weak self] event in
            self?.hoverChanged(event)
            return event
        }
        let timer = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in self?.refresh() }
        timer.tolerance = 0.025
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let localMovement { NSEvent.removeMonitor(localMovement) }
        monitor = nil
        localMovement = nil
        press = nil
        timer?.invalidate()
        timer = nil
        invalidateHotspots()
    }

    deinit { stop() }

    func invalidateHotspots() {
        generation &+= 1
        reading = false
        nextRead = 0
        panels.forEach { $0.close() }
        panels.removeAll()
    }

    private var usesHotspots: Bool {
        guard Self.stageManagerEnabled, isEnabled(), let webView, let window = webView.window,
              window.isVisible, window.isOnActiveSpace,
              webView.url?.scheme == WebRenderer.scheme, webView.url?.host == "wp" else { return false }
        return true
    }

    private func refresh() {
        guard usesHotspots, let webView, let window = webView.window else {
            if reading || !panels.isEmpty { invalidateHotspots() }
            return
        }
        // A moving mesh must not move or replace the window between mouse down and up.
        guard NSEvent.pressedMouseButtons == 0 else { return }
        updatePanelVisibility()
        let now = ProcessInfo.processInfo.systemUptime
        guard !reading, now >= nextRead else { return }
        let revision = generation
        reading = true
        WebWallpaperHotspots.read(in: webView) { [weak self, weak webView, weak window] rects in
            guard let self, self.generation == revision else { return }
            self.reading = false
            guard self.usesHotspots, let webView, let window, let screen = window.screen else {
                self.invalidateHotspots()
                return
            }
            guard NSEvent.pressedMouseButtons == 0 else { return }
            let frames = rects.compactMap { normalized -> CGRect? in
                let bounds = webView.bounds
                let y = webView.isFlipped ? normalized.minY : 1 - normalized.maxY
                let rect = CGRect(x: bounds.minX + normalized.minX * bounds.width,
                                  y: bounds.minY + y * bounds.height,
                                  width: normalized.width * bounds.width, height: normalized.height * bounds.height)
                let frame = window.convertToScreen(webView.convert(rect, to: nil)).intersection(screen.visibleFrame)
                return frame.isEmpty ? nil : frame
            }
            self.nextRead = ProcessInfo.processInfo.systemUptime + (frames.isEmpty ? 0.75 : 0.12)
            while self.panels.count > frames.count { self.panels.removeLast().close() }
            for (index, frame) in frames.enumerated() {
                if index < self.panels.count {
                    self.panels[index].update(frame: frame)
                } else {
                    self.panels.append(WebWallpaperHotspotPanel(frame: frame) { [weak self] point in
                        guard let self, self.usesHotspots else { return }
                        self.click(at: point)
                    })
                }
            }
            self.updatePanelVisibility()
        }
    }

    private func updatePanelVisibility() {
        guard !panels.isEmpty else { return }
        let pointer = NSEvent.mouseLocation
        let overHotspot = panels.contains { $0.frame.contains(pointer) }
        let modifiers = NSEvent.modifierFlags.intersection([.shift, .option, .control, .command])
        let mayOrder = overHotspot && modifiers.isEmpty &&
            Self.canRoute(at: pointer, placingPanels: Set(panels.filter(\.isVisible).map(\.windowNumber)))
        for panel in panels {
            panel.setReceivingClicks(modifiers.isEmpty && (!panel.frame.contains(pointer) || mayOrder))
        }
    }

    private func hoverChanged(_ event: NSEvent) {
        guard !panels.isEmpty, NSEvent.pressedMouseButtons == 0 else { return }
        guard event.type == .flagsChanged || event.timestamp >= nextHoverCheck else { return }
        nextHoverCheck = event.timestamp + 0.025
        updatePanelVisibility()
    }

    private func handle(_ event: NSEvent) {
        if event.type == .leftMouseDragged {
            press = nil
            return
        }
        let start = press
        press = nil
        guard !Self.stageManagerEnabled, event.type == .leftMouseDown || start != nil,
              isEnabled(), let window = webView?.window as? DesktopWindow,
              window.isVisible, window.isOnActiveSpace, let screen = window.screen,
              event.modifierFlags.intersection([.control, .shift, .option, .command]).isEmpty,
              event.clickCount == 1, let cgEvent = event.cgEvent else { return }

        // Quartz uses the main display's top-left origin even with another display above it.
        let quartzPoint = cgEvent.location
        let point = CGPoint(x: quartzPoint.x, y: CGDisplayBounds(CGMainDisplayID()).height - quartzPoint.y)
        let target = pid_t(clamping: cgEvent.getIntegerValueField(.eventTargetUnixProcessID))
        guard screen.visibleFrame.contains(point), Self.canRoute(at: point, target: target) else { return }
        if event.type == .leftMouseDown {
            press = point
            return
        }

        guard let start, hypot(point.x - start.x, point.y - start.y) <= 4 else { return }
        click(at: point)
    }

    private func click(at point: CGPoint) {
        guard let webView, let window = webView.window else { return }
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

    private static func canRoute(at point: CGPoint, target: pid_t = 0, placingPanels panels: Set<Int>? = nil) -> Bool {
        // Use WindowServer's hit test rather than bounding boxes. A covered wallpaper or an
        // interactive desktop widget, menu, Dock or regular Finder window must not get clicks.
        var hit = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0)
        if let panels {
            var skipped = Set<Int>()
            while panels.contains(hit), skipped.insert(hit).inserted {
                hit = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: hit)
            }
        }
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
        // App windows, Dock and Stage Manager thumbnails already outrank our panels.
        // Keep the panels ready underneath them when the pointer returns to the desktop.
        if panels != nil && level > icons + 1 { return true }
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
        guard AXIsProcessTrusted() else { return panels == nil }
        var element: AXUIElement?
        let quartzY = CGDisplayBounds(CGMainDisplayID()).height - point.y
        let result = AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(),
                                                     Float(point.x), Float(quartzY), &element)
        guard result == .success, let element else { return panels == nil }
        var role: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
              let role = role as? String else { return panels == nil }
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
