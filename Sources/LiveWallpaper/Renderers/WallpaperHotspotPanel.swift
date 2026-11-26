import AppKit

enum WallpaperPointerPhase: String {
    case down, drag, up, cancel, hover, leave
}

/// A nonactivating recipient at the desktop icon level, immediately below app windows.
/// AppKit keeps sending drags and the release to the surface that received mouseDown.
final class WallpaperHotspotPanel: NSPanel {
    private final class ClickSurface: NSView {
        let onPointer: (WallpaperPointerPhase, CGPoint, Int) -> Void
        private var lastPoint: CGPoint?
        private let modifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

        init(frame: CGRect, onPointer: @escaping (WallpaperPointerPhase, CGPoint, Int) -> Void) {
            self.onPointer = onPointer
            super.init(frame: frame)
        }

        required init?(coder: NSCoder) { nil }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            cancelPress()
            guard event.clickCount > 0, event.modifierFlags.intersection(modifiers).isEmpty,
                  let point = window?.convertPoint(toScreen: event.locationInWindow) else { return }
            lastPoint = point
            onPointer(.down, point, event.clickCount)
        }

        override func mouseDragged(with event: NSEvent) {
            guard lastPoint != nil, let point = window?.convertPoint(toScreen: event.locationInWindow) else { return }
            lastPoint = point
            onPointer(.drag, point, 0)
        }

        override func mouseUp(with event: NSEvent) {
            guard lastPoint != nil, let point = window?.convertPoint(toScreen: event.locationInWindow) else { return }
            lastPoint = nil
            onPointer(event.modifierFlags.intersection(modifiers).isEmpty ? .up : .cancel, point, event.clickCount)
        }

        func cancelPress() {
            if let point = lastPoint { onPointer(.cancel, point, 0) }
            lastPoint = nil
        }
    }

    init(frame: CGRect, onPointer: @escaping (WallpaperPointerPhase, CGPoint, Int) -> Void) {
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
        contentView = ClickSurface(frame: CGRect(origin: .zero, size: frame.size), onPointer: onPointer)
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

    override func close() {
        (contentView as? ClickSurface)?.cancelPress()
        super.close()
    }
}
