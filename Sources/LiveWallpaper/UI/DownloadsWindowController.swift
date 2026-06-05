import AppKit
import SwiftUI

extension Notification.Name {
    /// 请求打开「下载管理」窗口(由 UI 发出,AppDelegate 监听)。
    static let showDownloads = Notification.Name("LiveWallpaper.showDownloads")
}

/// 用 NSWindow 托管「下载管理」SwiftUI 界面。独立小窗,可与主窗口同时存在。
final class DownloadsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func show() {
        // 保证有 Dock/常规激活(通常主窗口已是 .regular,这里兜底)。
        NSApp.setActivationPolicy(.regular)

        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(rootView: DownloadsView())
        let w = NSWindow(contentViewController: hosting)
        w.title = "下载管理"
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.setContentSize(NSSize(width: 520, height: 480))
        w.center()
        window = w
        w.setFrameAutosaveName("DownloadsWindow")
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    var isVisible: Bool { window?.isVisible ?? false }
}
