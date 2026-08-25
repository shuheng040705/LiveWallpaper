import Foundation

/// 状态栏菜单的纯展示状态。把动态文案从 AppKit 菜单构建中抽离，便于回归测试，
/// 同时保证设置页、快捷菜单和运行中的 DesktopController 使用同一套状态语义。
struct TrayMenuPresentation: Equatable {
    let currentTitle: String?
    let isPaused: Bool
    let isMuted: Bool
    let rotationEnabled: Bool
    let pendingDownloads: Int

    var currentSummary: String {
        guard let currentTitle, !currentTitle.isEmpty else { return "当前：未选择壁纸" }
        return "当前：\(currentTitle)"
    }

    var pauseTitle: String { isPaused ? "继续壁纸" : "暂停壁纸" }
    var pauseSymbol: String { isPaused ? "play.fill" : "pause.fill" }
    var muteTitle: String { isMuted ? "取消静音" : "静音" }
    var muteSymbol: String { isMuted ? "speaker.wave.2.fill" : "speaker.slash.fill" }
    var rotationTitle: String { "自动轮换" }

    var downloadsTitle: String {
        pendingDownloads > 0 ? "下载管理（\(pendingDownloads)）…" : "下载管理…"
    }
}
