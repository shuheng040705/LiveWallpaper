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

        // 库窗口打开 → 允许渲染壁纸预览回退图(近全黑首帧的场景卡片);窗口关/最小化时停。
        // 后台壁纸进程平时(无库窗口)不渲库预览,避免与正在播放的桌面壁纸抢 GPU/CPU。
        RenderedPreviewCache.shared.setWindowVisible(true)

        // 升为常规 app,使窗口受台前调度/常规激活管理。

        if let window {
            // 关闭过的 NSWindow 因 isReleasedWhenClosed=false 仍可能被控制器持有；它此前已从
            // AppActivationPolicy 注销。再次 show() 必须重新登记，否则 app 仍是 .accessory，
            // 台前调度不会把这个窗口当成可回到左侧栏的常规窗口。
            AppActivationPolicy.windowOpened(window)
            rebuildContent()
            if window.isMiniaturized { window.deminiaturize(nil) }
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
        w.titleVisibility = .hidden          // 自定义顶部标签栏托管导航,系统标题隐藏
        w.isReleasedWhenClosed = false
        w.isRestorable = false               // 不做窗口/状态恢复(避免重启残留旧 tab/面板状态)
        // 明确加入系统窗口管理。通常 titled window 默认即 managed，但显式设置可避免应用从
        // .accessory 切到 .regular 后仍沿用非管理窗口语义，保证 Mission Control/台前调度接管。
        w.collectionBehavior.insert(.managed)
        w.appearance = NSAppearance(named: .darkAqua)   // 仿 WaifuX:整窗深色玻璃
        w.delegate = self
        AppActivationPolicy.windowOpened(w)   // 统一管理 Dock/Cmd-Tab 可见性
        // 首次打开用默认大小并居中;有保存值时由 frameAutosave 立即覆盖恢复。
        w.setContentSize(NSSize(width: 1000, height: 660))
        w.center()
        window = w
        // 系统自动把窗口 frame(大小+位置)存进 UserDefaults,下次打开恢复。
        w.setFrameAutosaveName("LibraryWindow")
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        captureIfRequested()
    }

    /// 截图验证用:WP_UI_SHOT=<png路径> 时,延迟后把窗口内容渲染成 PNG 再退出。
    /// 用 cacheDisplay 直接渲染视图层(不依赖窗口前台/窗口ID/录屏权限),彻底避开截图抓错窗口的问题。
    /// WP_UI_SHOT_DELAY 调延迟(默认 4s,等缩略图加载)。生产不设这些 env 时无任何影响。
    private func captureIfRequested() {
        guard let path = WPEnv.vars["WP_UI_SHOT"], let w = window else { return }
        let delay = Double(WPEnv.vars["WP_UI_SHOT_DELAY"] ?? "4") ?? 4
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            if let cv = w.contentView,
               let rep = cv.bitmapImageRepForCachingDisplay(in: cv.bounds) {
                cv.cacheDisplay(in: cv.bounds, to: rep)
                if let data = rep.representation(using: .png, properties: [:]) {
                    try? data.write(to: URL(fileURLWithPath: path))
                }
            }
            NSApp.terminate(nil)
        }
    }

    /// 窗口关闭:降回菜单栏代理(不占 Dock、不在台前调度里逗留),并停掉壁纸预览渲染。
    func windowWillClose(_ notification: Notification) {
        RenderedPreviewCache.shared.setWindowVisible(false)
        // 仅当再无其它常规窗口(设置/下载/订阅)时才降回菜单栏代理,见 AppActivationPolicy。
        if let w = notification.object as? NSWindow { AppActivationPolicy.windowClosed(w) }
        // 下次打开创建全新的受管理窗口，杜绝已关闭窗口以 .accessory 身份“复活”。
        window = nil
    }

    /// 窗口被系统/台前调度重新激活时自愈登记状态。windowOpened 是幂等的，不会重复计数。
    func windowDidBecomeKey(_ notification: Notification) {
        if let w = notification.object as? NSWindow { AppActivationPolicy.windowOpened(w) }
        RenderedPreviewCache.shared.setWindowVisible(true)
    }

    /// 最小化:库不可见 → 停壁纸预览渲染(还原时再开)。
    func windowDidMiniaturize(_ notification: Notification) {
        RenderedPreviewCache.shared.setWindowVisible(false)
    }
    func windowDidDeminiaturize(_ notification: Notification) {
        RenderedPreviewCache.shared.setWindowVisible(true)
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
