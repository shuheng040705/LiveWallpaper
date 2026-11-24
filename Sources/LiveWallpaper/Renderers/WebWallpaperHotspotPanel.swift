import AppKit

/// Owns the original mouse click over one interactive wallpaper region. The panel is
/// below ordinary application windows and never changes the active app or key window.
final class WebWallpaperHotspotPanel: NSPanel {
    private final class ClickSurface: NSView {
        let onClick: (CGPoint) -> Void
        private var press: CGPoint?
        private let modifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

        init(frame: CGRect, onClick: @escaping (CGPoint) -> Void) {
            self.onClick = onClick
            super.init(frame: frame)
        }

        required init?(coder: NSCoder) { nil }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            press = nil
            guard event.clickCount == 1, event.modifierFlags.intersection(modifiers).isEmpty else { return }
            press = window?.convertPoint(toScreen: event.locationInWindow)
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start = press, let point = window?.convertPoint(toScreen: event.locationInWindow) else { return }
            if hypot(point.x - start.x, point.y - start.y) > 4 { press = nil }
        }

        override func mouseUp(with event: NSEvent) {
            defer { press = nil }
            guard let start = press, let window, event.modifierFlags.intersection(modifiers).isEmpty else { return }
            let point = window.convertPoint(toScreen: event.locationInWindow)
            guard window.frame.contains(point), hypot(point.x - start.x, point.y - start.y) <= 4 else { return }
            onClick(point)
        }

        func cancelPress() { press = nil }
    }

    init(frame: CGRect, onClick: @escaping (CGPoint) -> Void) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .init(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .stationary, .ignoresCycle, .fullScreenNone]
        isOpaque = false
        // WindowServer excludes fully transparent pixels from its mouse hit region.
        backgroundColor = NSColor.black.withAlphaComponent(1.0 / 255)
        hasShadow = false
        hidesOnDeactivate = false
        canHide = false
        becomesKeyOnlyIfNeeded = true
        isMovable = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        contentView = ClickSurface(frame: CGRect(origin: .zero, size: frame.size), onClick: onClick)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func update(frame: CGRect) {
        if self.frame != frame { setFrame(frame, display: false) }
    }

    func setReceivingClicks(_ enabled: Bool) {
        if enabled {
            if !isVisible { orderFrontRegardless() }
        } else {
            (contentView as? ClickSurface)?.cancelPress()
            if isVisible { orderOut(nil) }
        }
    }
}
