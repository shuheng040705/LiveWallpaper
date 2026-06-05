import AppKit

/// 桌面层窗口:覆盖一块屏幕,置于"桌面图标之后、系统壁纸之上",鼠标点击穿透。
/// 这是所有壁纸渲染器的承载基础。
final class DesktopWindow: NSWindow {

    init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        // 关键:窗口层级 = 桌面图标层 - 1 → 位于图标之后、系统壁纸之上。
        // 若某些 macOS 版本上图标被遮挡或本窗口不显示,可改为 .desktopWindow 试。
        self.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) - 1)

        // 所有 Space 都显示、不随 Space 切换移动、不参与 Cmd+` 循环。
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]

        self.isOpaque = true
        self.backgroundColor = .black
        self.hasShadow = false
        self.ignoresMouseEvents = true        // 点击穿透到 Finder 图标
        self.isReleasedWhenClosed = false
        self.canHide = false
        self.displaysWhenScreenProfileChanges = true

        let content = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.black.cgColor
        content.autoresizesSubviews = true
        self.contentView = content

        self.setFrame(screen.frame, display: true)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
