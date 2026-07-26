import AppKit
import SwiftUI

extension Notification.Name {
    /// 请求打开「设置」窗口(由主界面齿轮按钮发出,AppDelegate 监听)。
    static let showSettings = Notification.Name("LiveWallpaper.showSettings")
}

/// 用 NSWindow 托管「设置」SwiftUI 界面(SettingsForm)。
///
/// 之前设置页是用 SwiftUI `.sheet` 弹出的,sheet 在 macOS 上用户无法拖边改大小
/// (无论内容用什么 frame)。改成独立的标准 NSWindow 后,styleMask 含 `.resizable`,
/// 用户可以正常拖拽窗口边缘缩放;尺寸还会被系统自动记忆(frameAutosave)。
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let actions: LibraryActions
    /// 取当前正在播放的壁纸(用于「正在播放」卡片);每次打开/刷新时重新取最新值。
    private let currentItem: () -> WallpaperItem?

    init(actions: LibraryActions, currentItem: @escaping () -> WallpaperItem?) {
        self.actions = actions
        self.currentItem = currentItem
        super.init()
    }

    func show() {
        // 兜底:保证有常规激活(通常主窗口已是 .regular)。
        NSApp.setActivationPolicy(.regular)

        if let window {
            // 已存在则刷新内容(当前壁纸可能已变)并前置。
            rebuildContent()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(rootView: makeRootView())
        let w = NSWindow(contentViewController: hosting)
        w.title = "设置"
        // 关键:含 .resizable → 用户可拖边改大小。
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.appearance = NSAppearance(named: .darkAqua)
        w.delegate = self
        // 合理的最小尺寸,避免拖到太小内容塌掉(与 SettingsForm 内容 frame 的下限一致)。
        w.minSize = NSSize(width: 480, height: 420)
        // 首开默认尺寸(沿用原 sheet 的 720×620),之后由 frameAutosave 恢复。
        w.setContentSize(NSSize(width: 720, height: 620))
        w.center()
        window = w
        w.setFrameAutosaveName("SettingsWindow")
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    var isVisible: Bool { window?.isVisible ?? false }

    private func rebuildContent() {
        guard let hosting = window?.contentViewController as? NSHostingController<SettingsWindowRoot> else { return }
        hosting.rootView = makeRootView()
    }

    private func makeRootView() -> SettingsWindowRoot {
        SettingsWindowRoot(actions: actions, currentItem: currentItem())
    }
}

/// 设置窗口的根视图:复用 SettingsForm,并补上之前 sheet 容器提供的深色玻璃外观
/// (SettingsForm 本身不带背景/配色)。窗口标题/关闭交给系统标题栏。
struct SettingsWindowRoot: View {
    let actions: LibraryActions
    var currentItem: WallpaperItem?

    var body: some View {
        SettingsForm(actions: actions, currentItem: currentItem)
            .frame(minWidth: 480, minHeight: 420)
            .background(WaifuTheme.background.ignoresSafeArea())
            .preferredColorScheme(.dark)
    }
}
