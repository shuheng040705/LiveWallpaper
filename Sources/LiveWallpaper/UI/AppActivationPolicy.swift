import AppKit

/// 应用激活策略(Dock 图标 / Cmd-Tab 可见性)的统一管理。
///
/// 本 app 平时是 `.accessory` 菜单栏代理(不占 Dock);打开任一常规窗口时要升 `.regular`,
/// **全部常规窗口都关闭后**才降回 `.accessory`。
///
/// 2026-07-26 审计:原来四个窗口控制器(库/设置/下载/订阅)各自在 show() 里升 `.regular`,
/// 但只有 LibraryWindowController 在 windowWillClose 里降回 `.accessory`,且不检查兄弟窗口
/// 是否仍打开 —— 两个方向都出错:
///   ① 库窗和设置窗同时开着,先关库窗 → 立刻降 `.accessory` → 还在屏上的设置窗所属 app
///      从 Dock 和 Cmd-Tab 消失,用户切走后很难再切回来。
///   ② 关掉设置/下载/订阅窗不恢复策略 → 零窗口时仍停在 `.regular`,菜单栏代理却在 Dock 里
///      留着常驻图标(要再开一次库窗再关掉才自愈)。
/// 统一收到这里做引用计数,两个方向都不会再错。
enum AppActivationPolicy {
    private static var openWindows = Set<ObjectIdentifier>()

    /// 常规窗口显示时调用(可重复调用,同一窗口只计一次)。
    static func windowOpened(_ window: NSWindow) {
        openWindows.insert(ObjectIdentifier(window))
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
    }

    /// 常规窗口关闭时调用。仅当**再无**已登记窗口时才降回 `.accessory`。
    static func windowClosed(_ window: NSWindow) {
        openWindows.remove(ObjectIdentifier(window))
        // 关闭中的窗口此刻 isVisible 可能仍为 true,故以登记集合为准。
        if openWindows.isEmpty, NSApp.activationPolicy() != .accessory {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
