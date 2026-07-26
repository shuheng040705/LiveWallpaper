import AppKit
import SwiftUI

extension Notification.Name {
    /// 请求打开「我的 Steam 订阅」窗口(由设置页「查看…」按钮发出,AppDelegate 监听)。
    static let showSubscriptions = Notification.Name("LiveWallpaper.showSubscriptions")
}

/// 用 NSWindow 托管「我的 Steam 订阅」SwiftUI 界面(SubscriptionsSheet)。
///
/// 之前该面板是用 SwiftUI `.sheet` 弹出的,sheet 在 macOS 上用户无法拖边改大小
/// (无论内容用什么弹性 frame)。改成独立的标准 NSWindow 后,styleMask 含 `.resizable`,
/// 用户可以正常拖拽窗口边缘缩放;尺寸还会被系统自动记忆(frameAutosave)。
/// 模式完全照 `SettingsWindowController`。
final class SubscriptionsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func show() {
        // 兜底:保证有常规激活(通常主窗口已是 .regular)。

        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(rootView: makeRootView())
        let w = NSWindow(contentViewController: hosting)
        w.title = "我的 Steam 订阅"
        // 关键:含 .resizable → 用户可拖边改大小。
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.appearance = NSAppearance(named: .darkAqua)
        w.delegate = self
        AppActivationPolicy.windowOpened(w)   // 统一管理 Dock/Cmd-Tab 可见性
        // 合理的最小尺寸,避免拖到太小内容塌掉(与 SubscriptionsSheet 内容 frame 的下限一致)。
        w.minSize = NSSize(width: 420, height: 400)
        // 首开默认尺寸(沿用原 sheet 的 idealWidth/idealHeight 460×560),之后由 frameAutosave 恢复。
        w.setContentSize(NSSize(width: 460, height: 560))
        w.center()
        window = w
        w.setFrameAutosaveName("SubscriptionsWindow")
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    var isVisible: Bool { window?.isVisible ?? false }

    /// 关闭本订阅窗口(供 SubscriptionsSheet 的 onClose 回调使用:窗口里 `dismiss()` 不会关窗)。
    private func close() { window?.close() }

    private func makeRootView() -> SubscriptionsWindowRoot {
        // 用 [weak self] 避免根视图闭包强引用控制器形成环。
        SubscriptionsWindowRoot(onClose: { [weak self] in self?.close() })
    }

    /// 窗口关闭:交由 AppActivationPolicy 决定是否降回菜单栏代理(仍有兄弟窗口时不降)。
    func windowWillClose(_ notification: Notification) {
        if let w = notification.object as? NSWindow { AppActivationPolicy.windowClosed(w) }
        window = nil
    }
}

/// 订阅窗口的根视图:复用 SubscriptionsSheet,并补上之前 sheet 容器提供的深色玻璃外观
/// (SubscriptionsSheet 本身不带背景/配色)。窗口标题/关闭交给系统标题栏。
/// 照 `SettingsWindowRoot`。
struct SubscriptionsWindowRoot: View {
    var onClose: () -> Void

    var body: some View {
        SubscriptionsSheet(onClose: onClose)
            .frame(minWidth: 420, minHeight: 400)
            .background(WaifuTheme.background.ignoresSafeArea())
            .preferredColorScheme(.dark)
    }

}
