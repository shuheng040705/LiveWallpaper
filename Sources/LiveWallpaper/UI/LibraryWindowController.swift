import AppKit
import SwiftUI

/// 用 NSWindow 托管 SwiftUI 的壁纸库界面。
///
/// 激活策略动态切换:本 app 平时是 .accessory(菜单栏代理,不占 Dock)。但 .accessory
/// 的窗口在台前调度(Stage Manager)里不被当作常规 app,点桌面空白处不会退后。
/// 因此壁纸库窗口显示时临时升为 .regular(让系统正常调度),窗口关闭时再降回 .accessory。
final class LibraryWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let library: WallpaperLibrary
    private let actions: LibraryActions
    private var currentID: String?

    /// 窗口是否当前可见(供菜单栏决定是开还是切前台)。
    var isVisible: Bool { window?.isVisible ?? false }

    init(library: WallpaperLibrary, actions: LibraryActions) {
        self.library = library
        self.actions = actions
        super.init()
    }

    func show(currentID: String?) {
        self.currentID = currentID

        // 升为常规 app,使窗口受台前调度/常规激活管理。
        NSApp.setActivationPolicy(.regular)

        if let window {
            rebuildContent()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(rootView: makeRoot())
        let w = NSWindow(contentViewController: hosting)
        // 不设静态标题:让 SwiftUI navigationTitle(当前分区名)驱动工具栏标题(静态 title 会压过它)。
        w.title = ""
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        // 透明标题栏 + 全尺寸内容:侧边栏毛玻璃延伸到顶部(原生 NavigationSplitView 统一工具栏外观)。
        // 标题/副标题由 SwiftUI navigationTitle 驱动,显示在详情区工具栏(Finder 式)。
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .visible
        w.isReleasedWhenClosed = false
        w.delegate = self
        // 首次打开用默认大小并居中;有保存值时由 frameAutosave 立即覆盖恢复。
        w.setContentSize(NSSize(width: 1000, height: 660))
        w.center()
        window = w
        // 系统自动把窗口 frame(大小+位置)存进 UserDefaults,下次打开恢复。
        w.setFrameAutosaveName("LibraryWindow")
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 窗口关闭:降回菜单栏代理(不占 Dock、不在台前调度里逗留)。
    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func updateCurrent(_ id: String?) {
        currentID = id
        rebuildContent()
    }

    private func rebuildContent() {
        guard let hosting = window?.contentViewController as? NSHostingController<LibraryView> else { return }
        hosting.rootView = makeRoot()
    }

    private func makeRoot() -> LibraryView {
        LibraryView(library: library, currentID: currentID, actions: actions)
    }
}
