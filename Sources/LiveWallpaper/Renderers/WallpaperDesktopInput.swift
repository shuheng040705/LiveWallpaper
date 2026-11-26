import AppKit

/// Desktop clicks are observed in the normal desktop. Stage Manager requires a real
/// nonactivating event recipient over each hotspot before the mouse goes down.
final class WallpaperDesktopInput {
    private weak var view: NSView?
    private let readHotspots: (CGPoint?, @escaping ([CGRect]) -> Void) -> Void
    private let onPointer: (WallpaperPointerPhase, CGPoint, Int) -> Void
    private let isEnabled: () -> Bool
    private var monitor: Any?
    private var localMovement: Any?
    private var press: CGPoint?
    private var lastDesktopPoint: CGPoint?
    private var nextOcclusionCheck = 0.0
    private var timer: Timer?
    private var panels: [WallpaperHotspotPanel] = []
    private var generation = 0
    private var reading = false
    private var nextRead = 0.0
    private var nextHoverCheck = 0.0

    static var stageManagerEnabled: Bool {
        CFPreferencesGetAppBooleanValue("GloballyEnabled" as CFString, "com.apple.WindowManager" as CFString, nil)
    }

    init(view: NSView, isEnabled: @escaping () -> Bool,
         readHotspots: @escaping (CGPoint?, @escaping ([CGRect]) -> Void) -> Void,
         onPointer: @escaping (WallpaperPointerPhase, CGPoint, Int) -> Void) {
        self.view = view
        self.isEnabled = isEnabled
        self.readHotspots = readHotspots
        self.onPointer = onPointer
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .leftMouseDragged, .mouseMoved, .flagsChanged]) { [weak self] event in
            if event.type == .mouseMoved || event.type == .flagsChanged { self?.hoverChanged(event) }
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
        if let press { onPointer(.cancel, press, 0) }
        press = nil
        generation &+= 1
        reading = false
        nextRead = 0
        panels.forEach { $0.close() }
        panels.removeAll()
        leaveDesktop()
    }

    private func forward(_ phase: WallpaperPointerPhase, at point: CGPoint, clickCount: Int = 1) {
        if phase != .cancel { lastDesktopPoint = point }
        onPointer(phase, point, clickCount)
    }

    private func leaveDesktop() {
        guard let point = lastDesktopPoint else { return }
        lastDesktopPoint = nil
        onPointer(.leave, point, 0)
    }

    private var usesHotspots: Bool {
        guard Self.stageManagerEnabled, isEnabled(), let window = view?.window,
              window.isVisible, window.isOnActiveSpace else { return false }
        return true
    }

    private func refresh(exposedPoint: CGPoint? = nil) {
        guard usesHotspots, let view, let window = view.window else {
            if reading || !panels.isEmpty { invalidateHotspots() }
            // An app can cover a stationary pointer without generating mouseMoved.
            // Only check occlusion while a desktop hover actually needs clearing.
            let now = ProcessInfo.processInfo.systemUptime
            if lastDesktopPoint != nil, NSEvent.pressedMouseButtons == 0, now >= nextOcclusionCheck {
                nextOcclusionCheck = now + 0.5
                if !isEnabled() || view?.window?.isVisible != true || view?.window?.isOnActiveSpace != true || exposedLocation() == nil {
                    leaveDesktop()
                }
            }
            return
        }
        // A moving mesh must not move or replace the window between mouse down and up.
        guard NSEvent.pressedMouseButtons == 0 else { return }
        updatePanelVisibility()
        let now = ProcessInfo.processInfo.systemUptime
        guard !reading, now >= nextRead else { return }
        let revision = generation
        let point = exposedPoint ?? exposedLocation()
        if point == nil { leaveDesktop() }
        reading = true
        let apply: ([CGRect]) -> Void = { [weak self, weak view, weak window] rects in
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
            self.nextRead = ProcessInfo.processInfo.systemUptime + (frames.isEmpty && point == nil ? 0.75 : 0.12)
            while self.panels.count > frames.count { self.panels.removeLast().close() }
            for (index, frame) in frames.enumerated() {
                if index < self.panels.count {
                    self.panels[index].update(frame: frame)
                } else {
                    self.panels.append(WallpaperHotspotPanel(frame: frame) { [weak self] phase, point, count in
                        guard let self, phase == .cancel || self.usesHotspots,
                              let location = self.location(at: point, clamped: true) else { return }
                        self.forward(phase, at: location, clickCount: count)
                    })
                }
            }
            self.updatePanelVisibility()
        }
        if UserDefaults.standard.bool(forKey: "wallpaperInputPriority") {
            // Reserve just the exposed cursor position. AppKit keeps delivering the full
            // gesture after a press even if the cursor leaves this small panel.
            apply(point.map { [Self.pointerRegion(around: $0, viewSize: view.bounds.size)] } ?? [])
        } else {
            readHotspots(point, apply)
        }
    }

    static func pointerRegion(around point: CGPoint, viewSize: CGSize) -> CGRect {
        guard viewSize.width > 0, viewSize.height > 0 else { return .zero }
        let radiusX = 6 / viewSize.width, radiusY = 6 / viewSize.height
        return CGRect(x: point.x - radiusX, y: point.y - radiusY,
                      width: 2 * radiusX, height: 2 * radiusY)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
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
              let pos = exposedLocation() else {
            leaveDesktop()
            return
        }
        if event.type == .mouseMoved { forward(.hover, at: pos) }
        if Self.stageManagerEnabled {
            // Re-evaluate the point under a moving cursor even if the last sample was blank.
            nextRead = 0
            refresh(exposedPoint: pos)
        }
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
            if let press { onPointer(.cancel, press, 0) }
            press = nil
            guard isEnabled(),
                  let window = view?.window as? DesktopWindow, window.isVisible, window.isOnActiveSpace,
                  let screen = window.screen, screen.visibleFrame.contains(point),
                  event.clickCount > 0, event.modifierFlags.intersection([.control, .shift, .option, .command]).isEmpty,
                  let pos = location(at: point) else { return }
            let target = pid_t(clamping: cgEvent.getIntegerValueField(.eventTargetUnixProcessID))
            guard Self.canRoute(at: point, on: screen, target: target) else { return }
            // A global monitor observes Finder's click. It does not take it away from
            // Stage Manager on full-screen canvases without authored hit geometry.
            press = pos
            forward(.down, at: pos, clickCount: event.clickCount)
            return
        }
        guard let last = press else { return }
        let pos = location(at: point, clamped: true) ?? last
        if event.type == .leftMouseDragged {
            press = pos
            forward(.drag, at: pos)
        } else if event.type == .leftMouseUp {
            press = nil
            forward(event.modifierFlags.intersection([.control, .shift, .option, .command]).isEmpty ? .up : .cancel, at: pos, clickCount: event.clickCount)
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
}
