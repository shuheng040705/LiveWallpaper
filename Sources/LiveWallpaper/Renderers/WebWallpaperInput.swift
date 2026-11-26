import AppKit
import WebKit

/// Desktop clicks are observed in the normal desktop. Stage Manager requires a real
/// nonactivating event recipient over each hotspot before the mouse goes down.
final class WebWallpaperInput {
    private weak var view: NSView?
    private let readHotspots: (CGPoint?, @escaping ([CGRect]) -> Void) -> Void
    private let onPointer: (WallpaperPointerPhase, CGPoint) -> Void
    private let observesUnclaimedDesktop: Bool
    private var onObservedDown: ((CGPoint) -> Void)?
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

    convenience init(webView: WKWebView, isEnabled: @escaping () -> Bool) {
        self.init(view: webView, isEnabled: { [weak webView] in
            isEnabled() && webView?.url?.scheme == WebRenderer.scheme && webView?.url?.host == "wp"
        }, observesUnclaimedDesktop: true, readHotspots: { [weak webView] point, completion in
            guard let webView else { completion([]); return }
            WebWallpaperHotspots.read(in: webView, at: point, completion: completion)
        }, onPointer: { [weak webView] phase, point in
            if let webView { Self.dispatch(phase, at: point, in: webView) }
        })
        onObservedDown = { [weak webView] point in
            guard let webView else { return }
            Self.dispatch(phases: ["down"], at: point, in: webView, checkCanvasHit: true, completion: nil)
        }
    }

    init(view: NSView, isEnabled: @escaping () -> Bool, observesUnclaimedDesktop: Bool = false,
         readHotspots: @escaping (CGPoint?, @escaping ([CGRect]) -> Void) -> Void,
         onPointer: @escaping (WallpaperPointerPhase, CGPoint) -> Void) {
        self.view = view
        self.isEnabled = isEnabled
        self.observesUnclaimedDesktop = observesUnclaimedDesktop
        self.readHotspots = readHotspots
        self.onPointer = onPointer
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
        timer?.invalidate()
        timer = nil
        invalidateHotspots()
    }

    deinit { stop() }

    func invalidateHotspots() {
        if let press { onPointer(.cancel, press) }
        press = nil
        generation &+= 1
        reading = false
        nextRead = 0
        panels.forEach { $0.close() }
        panels.removeAll()
    }

    private var usesHotspots: Bool {
        guard Self.stageManagerEnabled, isEnabled(), let window = view?.window,
              window.isVisible, window.isOnActiveSpace else { return false }
        return true
    }

    private func refresh(exposedPoint: CGPoint? = nil) {
        guard usesHotspots, let view, let window = view.window else {
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
        readHotspots(exposedPoint ?? exposedLocation()) { [weak self, weak view, weak window] rects in
            guard let self, self.generation == revision else { return }
            self.reading = false
            guard self.usesHotspots, let view, let window, let screen = window.screen else {
                self.invalidateHotspots()
                return
            }
            guard NSEvent.pressedMouseButtons == 0 else { return }
            let frames = rects.compactMap { normalized -> CGRect? in
                let bounds = view.bounds
                let y = view.isFlipped ? normalized.minY : 1 - normalized.maxY
                let rect = CGRect(x: bounds.minX + normalized.minX * bounds.width,
                                  y: bounds.minY + y * bounds.height,
                                  width: normalized.width * bounds.width, height: normalized.height * bounds.height)
                let frame = window.convertToScreen(view.convert(rect, to: nil)).intersection(screen.visibleFrame)
                return frame.isEmpty ? nil : frame
            }
            self.nextRead = ProcessInfo.processInfo.systemUptime + (frames.isEmpty ? 0.75 : 0.12)
            while self.panels.count > frames.count { self.panels.removeLast().close() }
            for (index, frame) in frames.enumerated() {
                if index < self.panels.count {
                    self.panels[index].update(frame: frame)
                } else {
                    self.panels.append(WebWallpaperHotspotPanel(frame: frame) { [weak self] phase, point in
                        guard let self, phase == .cancel || self.usesHotspots,
                              let location = self.location(at: point, clamped: true) else { return }
                        self.onPointer(phase, location)
                    })
                }
            }
            self.updatePanelVisibility()
        }
    }

    private func updatePanelVisibility() {
        guard !panels.isEmpty, let screen = view?.window?.screen else { return }
        let pointer = NSEvent.mouseLocation
        let overHotspot = panels.contains { $0.frame.contains(pointer) }
        let modifiers = NSEvent.modifierFlags.intersection([.shift, .option, .control, .command])
        let mayOrder = overHotspot && modifiers.isEmpty &&
            Self.canRoute(at: pointer, on: screen, placingPanels: Set(panels.filter(\.isVisible).map(\.windowNumber)))
        for panel in panels {
            panel.setReceivingClicks(modifiers.isEmpty && (!panel.frame.contains(pointer) || mayOrder))
        }
    }

    private func hoverChanged(_ event: NSEvent) {
        guard NSEvent.pressedMouseButtons == 0,
              event.type == .flagsChanged || event.timestamp >= nextHoverCheck else { return }
        nextHoverCheck = event.timestamp + 0.035
        guard let window = view?.window, window.isVisible, window.isOnActiveSpace, isEnabled(),
              let screen = window.screen else { return }
        guard screen.visibleFrame.contains(NSEvent.mouseLocation), let pos = exposedLocation() else { return }
        if Self.stageManagerEnabled {
            // Re-evaluate the point under a moving cursor even if the last sample was blank.
            nextRead = 0
            refresh(exposedPoint: pos)
        }
        if observesUnclaimedDesktop && event.type == .mouseMoved { onPointer(.hover, pos) }
    }

    private func exposedLocation() -> CGPoint? {
        let point = NSEvent.mouseLocation
        guard let screen = view?.window?.screen, screen.visibleFrame.contains(point), let pos = location(at: point),
              Self.canRoute(at: point, on: screen, ignoring: Set(panels.filter(\.isVisible).map(\.windowNumber))) else { return nil }
        return pos
    }

    private func handle(_ event: NSEvent) {
        guard let cgEvent = event.cgEvent else { return }
        let quartz = cgEvent.location
        let point = CGPoint(x: quartz.x, y: CGDisplayBounds(CGMainDisplayID()).height - quartz.y)
        if event.type == .leftMouseDown {
            if let press { onPointer(.cancel, press) }
            press = nil
            guard (!Self.stageManagerEnabled || observesUnclaimedDesktop), isEnabled(),
                  let window = view?.window as? DesktopWindow, window.isVisible, window.isOnActiveSpace,
                  let screen = window.screen, screen.visibleFrame.contains(point),
                  event.clickCount == 1, event.modifierFlags.intersection([.control, .shift, .option, .command]).isEmpty,
                  let pos = location(at: point) else { return }
            let target = pid_t(clamping: cgEvent.getIntegerValueField(.eventTargetUnixProcessID))
            guard Self.canRoute(at: point, on: screen, target: target) else { return }
            // A global monitor observes Finder's click. It does not take it away from
            // Stage Manager on full-screen canvases without authored hit geometry.
            press = pos
            if Self.stageManagerEnabled, let onObservedDown { onObservedDown(pos) }
            else { onPointer(.down, pos) }
            return
        }
        guard let last = press else { return }
        let pos = location(at: point, clamped: true) ?? last
        if event.type == .leftMouseDragged {
            press = pos
            onPointer(.drag, pos)
        } else if event.type == .leftMouseUp {
            press = nil
            onPointer(event.modifierFlags.intersection([.control, .shift, .option, .command]).isEmpty ? .up : .cancel, pos)
        }
    }

    private func location(at point: CGPoint, clamped: Bool = false) -> CGPoint? {
        guard let view, let window = view.window else { return nil }
        let local = view.convert(window.convertPoint(fromScreen: point), from: nil)
        let bounds = view.bounds
        guard clamped, bounds.width > 0, bounds.height > 0 else {
            return Self.normalizedPoint(local, in: bounds, flipped: view.isFlipped)
        }
        return CGPoint(x: min(1, max(0, (local.x - bounds.minX) / bounds.width)),
                       y: min(1, max(0, (view.isFlipped ? local.y - bounds.minY : bounds.maxY - local.y) / bounds.height)))
    }

    static func normalizedPoint(_ point: CGPoint, in bounds: CGRect, flipped: Bool) -> CGPoint? {
        guard bounds.width > 0, bounds.height > 0, bounds.contains(point) else { return nil }
        return CGPoint(x: (point.x - bounds.minX) / bounds.width,
                       y: (flipped ? point.y - bounds.minY : bounds.maxY - point.y) / bounds.height)
    }

    static func canRoute(at point: CGPoint, on screen: NSScreen, target: pid_t = 0,
                                 placingPanels panels: Set<Int>? = nil, ignoring skipped: Set<Int> = []) -> Bool {
        let desktopOwners = ["com.apple.finder", "com.apple.dock", "com.apple.WindowManager"]
        let icons = Int(CGWindowLevelForKey(.desktopIconWindow))
        let background = Int(CGWindowLevelForKey(.desktopWindow))
        var hit = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0)
        var visited = Set<Int>()
        var foundBackdrop = false

        while hit > 0, visited.insert(hit).inserted {
            if panels?.contains(hit) == true || skipped.contains(hit) {
                hit = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: hit)
                continue
            }
            guard let info = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(hit))
                    as? [[String: Any]], let window = info.first,
                  let level = window[kCGWindowLayer as String] as? Int,
                  let owner = window[kCGWindowOwnerPID as String] as? pid_t,
                  let bundle = NSRunningApplication(processIdentifier: owner)?.bundleIdentifier else { return false }
            if target > 0 && target != owner {
                guard let receiver = NSRunningApplication(processIdentifier: target)?.bundleIdentifier,
                      desktopOwners.contains(receiver) else { return false }
            }

            // Ordinary windows and the Stage Manager strip already receive input above the panels.
            if level > icons + 1 { return panels != nil && !foundBackdrop }
            if level <= background { return bundle == "com.apple.dock" || bundle == "com.apple.WindowManager" }
            guard level == icons, bundle == "com.apple.finder" || bundle == "com.apple.WindowManager",
                  let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let rawBounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: rawBounds) else { return false }
            let display = CGDisplayBounds(id.uint32Value)
            let finderRole = bundle == "com.apple.finder" ? finderRole(at: point, owner: owner) : nil
            guard isDesktopBackdrop(frame: frame, display: display, finderRole: finderRole) else { return false }
            // Show Desktop can expose Finder directly or underneath WindowManager. Only skip
            // screen-sized desktop surfaces; a distinct icon or widget underneath still wins.
            foundBackdrop = true
            hit = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: hit)
        }
        guard hit == 0 else { return false }
        if foundBackdrop { return true }
        guard target > 0, let receiver = NSRunningApplication(processIdentifier: target)?.bundleIdentifier else { return false }
        return desktopOwners.contains(receiver)
    }

    static func isDesktopBackdrop(frame: CGRect, display: CGRect, finderRole: String?) -> Bool {
        let matchesDisplay = !display.isEmpty && abs(frame.minX - display.minX) <= 1
            && abs(frame.minY - display.minY) <= 1 && abs(frame.maxX - display.maxX) <= 1
            && abs(frame.maxY - display.maxY) <= 1
        guard matchesDisplay else { return false }
        // Finder exposes the blank desktop as an AXGroup, and individual icons as AXImage.
        // The WindowServer geometry remains available when Accessibility isn't authorized.
        guard let finderRole else { return true }
        return [kAXGroupRole, kAXScrollAreaRole, kAXListRole, kAXWindowRole].contains(finderRole)
    }

    private static func finderRole(at point: CGPoint, owner: pid_t) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let finder = AXUIElementCreateApplication(owner)
        let quartzY = CGDisplayBounds(CGMainDisplayID()).height - point.y
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(finder, Float(point.x), Float(quartzY), &element) == .success,
              let element else { return nil }
        var role: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success else { return nil }
        return role as? String
    }

    static func dispatch(_ phase: WallpaperPointerPhase, at point: CGPoint, in webView: WKWebView,
                         completion: ((Any?, Error?) -> Void)? = nil) {
        dispatch(phases: [phase.rawValue], at: point, in: webView, completion: completion)
    }

    static func dispatchClick(at point: CGPoint, in webView: WKWebView, completion: ((Any?, Error?) -> Void)? = nil) {
        dispatch(phases: ["down", "up"], at: point, in: webView, completion: completion)
    }

    private static func dispatch(phases: [String], at point: CGPoint, in webView: WKWebView,
                                 checkCanvasHit: Bool = false, completion: ((Any?, Error?) -> Void)?) {
        guard point.x.isFinite, point.y.isFinite, (0...1).contains(point.x), (0...1).contains(point.y),
              webView.url?.scheme == WebRenderer.scheme, webView.url?.host == "wp" else {
            completion?(false, nil)
            return
        }
        let script = """
        if (location.protocol !== 'lwwp:' || location.hostname !== 'wp') return false;
        const x = Math.min(innerWidth - 1, nx * innerWidth), y = Math.min(innerHeight - 1, ny * innerHeight);
        const hit = document.elementFromPoint(x, y);
        if (checkCanvasHit) {
            \(WebWallpaperHotspots.canvasProbe)
            // An exposed full-screen canvas without a hit map may react to every desktop click.
            // Known runtimes have an explicit empty-space result, which belongs to the system.
            if (canvasHit(hit, x, y) === false) return false;
        }
        for (const phase of phases) {
            let press = window.__lwDesktopPress;
            const target = (phase === 'down' || phase === 'hover') ? hit : press?.target;
            if (!target) return false;
            const options = {clientX:x, clientY:y, button:0, bubbles:true, cancelable:true,
                             composed:true, view:window, detail:1};
            const pointer = (name, buttons) => target.dispatchEvent(new PointerEvent(name, {
                ...options, button:name==='pointermove' ? -1 : 0, buttons, pointerId:1, pointerType:'mouse', isPrimary:true
            }));
            const mouse = (name, buttons) => target.dispatchEvent(new MouseEvent(name, {...options, buttons}));
            if (phase === 'down') {
                press = window.__lwDesktopPress = {target, x, y, clicked:true, compatible:true};
                press.compatible = pointer('pointerdown', 1);
                if (press.compatible) mouse('mousedown', 1);
            } else if (phase === 'hover' || phase === 'drag') {
                const buttons = phase === 'drag' ? 1 : 0;
                if (buttons && Math.hypot(x-press.x, y-press.y) > 4) press.clicked = false;
                pointer('pointermove', buttons);
                if (!buttons || press.compatible) mouse('mousemove', buttons);
            } else {
                delete window.__lwDesktopPress;
                if (phase === 'cancel') { pointer('pointercancel', 0); continue; }
                pointer('pointerup', 0);
                if (press.compatible) mouse('mouseup', 0);
                if (press.clicked && hit === target && Math.hypot(x-press.x, y-press.y) <= 4) mouse('click', 0);
            }
        }
        return true;
        """
        webView.callAsyncJavaScript(script, arguments: ["phases": phases, "nx": point.x, "ny": point.y, "checkCanvasHit": checkCanvasHit],
                                    in: nil, in: .page) { result in
            switch result {
            case .success(let value): completion?(value, nil)
            case .failure(let error): completion?(nil, error)
            }
        }
    }
}
