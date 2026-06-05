import AppKit

/// 控制 Finder 桌面图标的显示/隐藏(通过 Finder 的 CreateDesktop 偏好)。
enum DesktopIcons {
    static var isVisible: Bool {
        // Finder 默认显示图标;CreateDesktop=false 表示隐藏。
        let v = UserDefaults(suiteName: "com.apple.finder")?.object(forKey: "CreateDesktop")
        if let b = v as? Bool { return b }
        return true
    }

    static func setVisible(_ visible: Bool) {
        let task = Process()
        task.launchPath = "/usr/bin/defaults"
        task.arguments = ["write", "com.apple.finder", "CreateDesktop", "-bool", visible ? "true" : "false"]
        try? task.run()
        task.waitUntilExit()
        // 重启 Finder 使其生效。
        let killer = Process()
        killer.launchPath = "/usr/bin/killall"
        killer.arguments = ["Finder"]
        try? killer.run()
        Log.write("DesktopIcons: setVisible(\(visible))")
    }
}
