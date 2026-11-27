import AppKit

/// Stage Manager owns the press that reveals the desktop. Once Finder presents
/// the desktop, a nonactivating surface keeps subsequent presses on the wallpaper.
final class WallpaperDesktopInput {
    private weak var view: NSView?
    private let hitTest: ((CGPoint, @escaping (Bool) -> Void) -> Void)?
    private let onPointer: ((WallpaperPointerPhase, CGPoint, Int) -> Void)?
    private let isEnabled: () -> Bool
    private lazy var gestures = WallpaperDesktopGestures { [weak self] phase, point, count in
        self?.forward(phase, at: point, clickCount: count)
    }
    private var monitor: Any?
    private var localMovement: Any?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var timer: Timer?
    private var panels: [WallpaperHotspotPanel] = []
    private var lastDesktopPoint: CGPoint?
    private var nextHoverCheck = 0.0
    private var nextIconRead = 0.0
    private var iconFrames: [CGRect] = []
    private static let systemModifiers: NSEvent.ModifierFlags = [.shift, .option, .control, .command]

    static var stageManagerEnabled: Bool {
        CFPreferencesGetAppBooleanValue("GloballyEnabled" as CFString, "com.apple.WindowManager" as CFString, nil)
    }

    init(view: NSView, isEnabled: @escaping () -> Bool,
         hitTest: ((CGPoint, @escaping (Bool) -> Void) -> Void)? = nil,
         onPointer: ((WallpaperPointerPhase, CGPoint, Int) -> Void)? = nil) {
        self.view = view
        self.isEnabled = isEnabled
        self.hitTest = hitTest
        self.onPointer = onPointer
        // Passive wallpapers only follow desktop state and modifier changes.
        // They do not need cursor motion, drag tracking or a content hit test.
        let movement: NSEvent.EventTypeMask = onPointer == nil ? [.flagsChanged] : [.mouseMoved, .flagsChanged]
        let observed: NSEvent.EventTypeMask = onPointer == nil ? [.leftMouseUp] : [.leftMouseDown, .leftMouseUp, .leftMouseDragged]
        monitor = NSEvent.addGlobalMonitorForEvents(matching: observed.union(movement)) { [weak self] event in
            if event.type == .mouseMoved || event.type == .flagsChanged { self?.hoverChanged(event) }
            else { self?.handle(event) }
        }
        localMovement = NSEvent.addLocalMonitorForEvents(matching: movement) { [weak self] event in
            self?.hoverChanged(event)
            return event
        }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refresh()
            })
        }
        let timer = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in self?.refresh() }
        timer.tolerance = 0.02
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let localMovement { NSEvent.removeMonitor(localMovement) }
        monitor = nil
        localMovement = nil
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceObservers.removeAll()
        timer?.invalidate()
        timer = nil
        invalidateHotspots()
    }

    deinit { stop() }

    func invalidateHotspots() {
        gestures.reset()
        nextIconRead = 0
        iconFrames.removeAll()
        setPanels([])
        leaveDesktop()
    }

    private func forward(_ phase: WallpaperPointerPhase, at point: CGPoint, clickCount: Int = 1) {
        guard let onPointer else { return }
        if phase != .cancel { lastDesktopPoint = point }
        onPointer(phase, point, clickCount)
    }

    private func leaveDesktop() {
        guard let point = lastDesktopPoint else { return }
        lastDesktopPoint = nil
        onPointer?(.leave, point, 0)
    }

    private var activeScreen: NSScreen? {
        guard isEnabled(), let window = view?.window, window.isVisible, window.isOnActiveSpace else { return nil }
        return window.screen
    }

    private var panelNumbers: Set<Int> { Set(panels.filter(\.isVisible).map(\.windowNumber)) }

    private func refresh() {
        guard let screen = activeScreen else { invalidateHotspots(); return }
        // A local press owns its drags and release even across a window change.
        guard !gestures.isTrackingPanel else { return }
        guard Self.stageManagerEnabled, NSEvent.modifierFlags.intersection(Self.systemModifiers).isEmpty,
              let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]],
              let display = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              Self.desktopIsRevealed(windows: windows, display: CGDisplayBounds(display.uint32Value)) else {
            setPanels([])
            clearCoveredHover(on: screen)
            return
        }
        let protected = desktopItemFrames(on: screen, windows: windows)
        setPanels(Self.uncoveredRegions([screen.visibleFrame], excluding: protected))
        clearCoveredHover(on: screen)
    }

    private func clearCoveredHover(on screen: NSScreen) {
        if lastDesktopPoint != nil, NSEvent.pressedMouseButtons == 0, !Self.canRoute(at: NSEvent.mouseLocation, on: screen, ignoring: panelNumbers) {
            leaveDesktop()
        }
    }

    static func desktopIsRevealed(windows: [[String: Any]], display: CGRect) -> Bool {
        let icons = Int(CGWindowLevelForKey(.desktopIconWindow))
        // WindowServer lists front to back. The desktop icon layer switches from
        // WindowManager to Finder when Stage Manager shelves the application group,
        // including when Finder itself owns the previously visible browsing window.
        for window in windows {
            guard window[kCGWindowLayer as String] as? Int == icons,
                  (window[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let owner = window[kCGWindowOwnerPID as String] as? pid_t,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds),
                  isDesktopBackdrop(frame: frame, display: display, finderRole: nil) else { continue }
            switch NSRunningApplication(processIdentifier: owner)?.bundleIdentifier {
            case "com.apple.finder": return true
            case "com.apple.WindowManager": return false
            default: continue
            }
        }
        return false
    }

    private func setPanels(_ frames: [CGRect]) {
        while panels.count > frames.count { panels.removeLast().close() }
        for (index, frame) in frames.enumerated() {
            if index < panels.count {
                panels[index].update(frame: frame)
            } else {
                panels.append(WallpaperHotspotPanel(frame: frame, canStart: { [weak self] point in
                    guard let self, let screen = self.activeScreen else { return false }
                    return Self.canRoute(at: point, on: screen, ignoring: self.panelNumbers)
                }) { [weak self] phase, point, count in
                    guard let self, let location = self.location(at: point, clamped: true) else { return }
                    self.gestures.receive(phase, at: location, count: count, from: .panel)
                })
            }
            panels[index].setReceivingClicks(true)
        }
    }

    static func uncoveredRegions(_ hotspots: [CGRect], excluding items: [CGRect]) -> [CGRect] {
        var regions = hotspots
        for item in items {
            regions = regions.flatMap { rect -> [CGRect] in
                let overlap = rect.intersection(item)
                guard !overlap.isEmpty else { return [rect] }
                return [
                    CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: overlap.minY - rect.minY),
                    CGRect(x: rect.minX, y: overlap.maxY, width: rect.width, height: rect.maxY - overlap.maxY),
                    CGRect(x: rect.minX, y: overlap.minY, width: overlap.minX - rect.minX, height: overlap.height),
                    CGRect(x: overlap.maxX, y: overlap.minY, width: rect.maxX - overlap.maxX, height: overlap.height)
                ].filter { !$0.isEmpty }
            }
        }
        return regions
    }

    private func desktopItemFrames(on screen: NSScreen, windows: [[String: Any]]) -> [CGRect] {
        let iconLevel = Int(CGWindowLevelForKey(.desktopIconWindow))
        let mainHeight = CGDisplayBounds(CGMainDisplayID()).height
        var protected: [CGRect] = []
        for window in windows {
            guard let level = window[kCGWindowLayer as String] as? Int, (iconLevel...iconLevel + 1).contains(level),
                  let owner = window[kCGWindowOwnerPID as String] as? pid_t, owner != getpid(),
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  var frame = CGRect(dictionaryRepresentation: bounds) else { continue }
            frame.origin.y = mainHeight - frame.maxY
            guard frame.intersects(screen.frame) else { continue }
            let bundle = NSRunningApplication(processIdentifier: owner)?.bundleIdentifier
            if level == iconLevel, bundle == "com.apple.finder" || bundle == "com.apple.WindowManager",
               Self.isDesktopBackdrop(frame: frame, display: screen.frame, finderRole: nil) { continue }
            protected.append(frame)
        }
        // Finder draws its icons in one desktop window. Their individual frames
        // are available through Accessibility when the user has granted access.
        let now = ProcessInfo.processInfo.systemUptime
        if now >= nextIconRead {
            nextIconRead = now + 1
            iconFrames = Self.finderIconFrames(mainHeight: mainHeight)
        }
        return protected + iconFrames
    }

    private static func finderIconFrames(mainHeight: CGFloat) -> [CGRect] {
        guard AXIsProcessTrusted(),
              let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first
        else { return [] }
        func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            var result: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
            return result
        }
        let app = AXUIElementCreateApplication(finder.processIdentifier)
        var frames: [CGRect] = []
        for desktop in value(app, kAXWindowsAttribute) as? [AXUIElement] ?? [] {
            guard value(desktop, kAXRoleAttribute) as? String == kAXScrollAreaRole else { continue }
            for group in value(desktop, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
                guard value(group, kAXRoleAttribute) as? String == kAXGroupRole else { continue }
                for item in value(group, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
                    var origin = CGPoint.zero
                    var size = CGSize.zero
                    guard let position = value(item, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
                          let dimensions = value(item, kAXSizeAttribute), CFGetTypeID(dimensions) == AXValueGetTypeID(),
                          AXValueGetValue(position as! AXValue, .cgPoint, &origin),
                          AXValueGetValue(dimensions as! AXValue, .cgSize, &size) else { continue }
                    frames.append(CGRect(x: origin.x, y: mainHeight - origin.y - size.height,
                                         width: size.width, height: size.height))
                }
            }
        }
        return frames
    }

    private func hoverChanged(_ event: NSEvent) {
        guard NSEvent.pressedMouseButtons == 0 else { return }
        if event.type == .flagsChanged { refresh(); return }
        guard event.timestamp >= nextHoverCheck else { return }
        nextHoverCheck = event.timestamp + 0.035
        let point = NSEvent.mouseLocation
        guard let screen = activeScreen, screen.visibleFrame.contains(point), let location = location(at: point),
              Self.canRoute(at: point, on: screen, ignoring: panelNumbers) else { leaveDesktop(); return }
        forward(.hover, at: location)
    }

    private func handle(_ event: NSEvent) {
        guard let cgEvent = event.cgEvent else { return }
        let quartz = cgEvent.location
        let point = CGPoint(x: quartz.x, y: CGDisplayBounds(CGMainDisplayID()).height - quartz.y)
        if event.type == .leftMouseDown {
            guard event.clickCount > 0, event.modifierFlags.intersection(Self.systemModifiers).isEmpty,
                  let screen = activeScreen, screen.visibleFrame.contains(point), let pos = location(at: point),
                  Self.canRoute(at: point, on: screen, target: Self.globalEventTarget(cgEvent), ignoring: panelNumbers)
            else { return }
            if Self.stageManagerEnabled {
                guard let hitTest else { return }
                // This press already reached the system. Verify its original coordinates
                // while the gesture queue holds any drag/release that arrives first.
                gestures.receive(.down, at: pos, count: event.clickCount, from: .monitor) { [hitTest] complete in
                    hitTest(pos, complete)
                }
                refresh()
            } else {
                gestures.receive(.down, at: pos, count: event.clickCount, from: .monitor)
            }
        } else if let pos = location(at: point, clamped: true) {
            let phase: WallpaperPointerPhase = event.type == .leftMouseDragged ? .drag :
                (event.modifierFlags.intersection(Self.systemModifiers).isEmpty ? .up : .cancel)
            gestures.receive(phase, at: pos, count: event.clickCount, from: .monitor)
            if event.type == .leftMouseUp { refresh() }
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

    static func globalEventTarget(_ event: CGEvent) -> pid_t {
        let target = pid_t(clamping: event.getIntegerValueField(.eventTargetUnixProcessID))
        // AppKit may address the monitor's copy to this process. In that case the
        // window stack at the original click identifies the recipient.
        return target == getpid() ? 0 : target
    }

    static func canRoute(at point: CGPoint, on screen: NSScreen, target: pid_t = 0,
                         ignoring skipped: Set<Int> = []) -> Bool {
        let desktopOwners = ["com.apple.finder", "com.apple.dock", "com.apple.WindowManager"]
        let icons = Int(CGWindowLevelForKey(.desktopIconWindow))
        let background = Int(CGWindowLevelForKey(.desktopWindow))
        var hit = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0)
        var visited = Set<Int>()
        var foundBackdrop = false

        while hit > 0, visited.insert(hit).inserted {
            if skipped.contains(hit) {
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

            // An ordinary window or the Stage Manager strip owns its click.
            if level > icons + 1 { return false }
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
