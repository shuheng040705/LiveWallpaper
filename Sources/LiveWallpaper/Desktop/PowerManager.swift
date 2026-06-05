import AppKit

/// 省电:当有应用进入全屏(壁纸被完全遮挡)时自动暂停渲染,退出后恢复。
/// 通过监听活跃 Space 是否为全屏来判断——用窗口遮挡近似:某 App 窗口 frame 与任一块屏 frame
/// 基本重合(位置+尺寸)即视为该屏被全屏遮挡(审计修复 #6:支持多显示器,不再只看主屏/裸尺寸)。
final class PowerManager {
    private weak var desktop: DesktopController?
    private var enabled = true
    private var pausedByPower = false
    private var pollTimer: Timer?   // 定时轮询遮挡覆盖率(窗口移动/缩放/台前调度无激活事件,需主动查)

    init(desktop: DesktopController) {
        self.desktop = desktop
    }

    func start() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(activeChanged),
                       name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        nc.addObserver(self, selector: #selector(activeChanged),
                       name: NSWorkspace.didActivateApplicationNotification, object: nil)
        // 系统睡眠/唤醒
        nc.addObserver(self, selector: #selector(willSleep),
                       name: NSWorkspace.willSleepNotification, object: nil)
        nc.addObserver(self, selector: #selector(didWake),
                       name: NSWorkspace.didWakeNotification, object: nil)
        // 遮挡覆盖率轮询(2.5s):窗口拖动/缩放不发激活通知,靠它捕捉「遮挡达阈值」的变化。开销很低
        //(一次 CGWindowList + 网格采样)。仅 enabled 时真正 evaluate。
        let t = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in self?.evaluate() }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
    }

    var isEnabled: Bool {
        get { enabled }
        set {
            enabled = newValue
            if !enabled, pausedByPower { desktop?.resume(); pausedByPower = false }
            else { evaluate() }
        }
    }

    @objc private func activeChanged() { evaluate() }

    // 审计修复 #5:willSleep 暂停时必须置 pausedByPower=true,标记“本次暂停由 PowerManager 负责恢复”,
    // 否则 didWake/evaluate 无人认领该暂停 → 唤醒后永不 resume(卡在暂停)。
    @objc private func willSleep() {
        guard let desktop, !desktop.isPaused else { return }
        desktop.pause(); pausedByPower = true
        Log.write("power: paused (will sleep)")
    }

    // 审计修复 #5:谁暂停谁恢复 —— 只有当暂停是 PowerManager 造成的(pausedByPower)才恢复。
    // 唤醒后不直接 resume,而是走 evaluate():若此刻仍被全屏遮挡则保持暂停,不会误恢复到被遮挡状态。
    @objc private func didWake() {
        guard pausedByPower else { return }
        pausedByPower = false
        desktop?.resume()   // 先恢复,再由 evaluate 决定是否因全屏遮挡重新暂停
        evaluate()
    }

    /// 据「窗口遮挡阈值」设置决定是否暂停:0=仅全屏(精确匹配);其余=遮挡覆盖率 ≥ 阈值% 即暂停。
    /// 适配台前调度/大窗口遮挡——不必全屏也能省电。
    private func evaluate() {
        guard enabled, let desktop else { return }
        let threshold = PreferencesStore.shared.occlusionThreshold
        let covered: Bool
        if threshold <= 0 {
            covered = Self.isMainScreenCoveredByFullscreen()
        } else {
            covered = Self.maxScreenCoverageFraction() * 100 >= Double(threshold)
        }
        if covered, !desktop.isPaused {
            desktop.pause(); pausedByPower = true
            Log.write("power: paused (occlusion, threshold=\(threshold))")
        } else if !covered, pausedByPower {
            desktop.resume(); pausedByPower = false
            Log.write("power: resumed")
        }
    }

    /// 主屏/各屏被其他应用普通窗口遮挡的**最大**覆盖率 [0,1](网格采样窗口并集占屏比)。
    /// 用于「遮挡达阈值即暂停」(台前调度场景)。排除本 app、桌面元素、菜单栏/Dock(layer≠0)、近透明窗口。
    static func maxScreenCoverageFraction() -> Double {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return 0 }
        let globalTop = screens.map { $0.frame.maxY }.max() ?? 0
        let screenRectsCG: [CGRect] = screens.map { s in
            let f = s.frame
            return CGRect(x: f.origin.x, y: globalTop - f.maxY, width: f.width, height: f.height)
        }
        guard let infoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return 0 }
        let myPID = Int(ProcessInfo.processInfo.processIdentifier)
        var winRects: [CGRect] = []
        for info in infoList {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,   // 普通应用窗口层
                  let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let b = CGRect(dictionaryRepresentation: boundsDict as CFDictionary), b.width >= 1, b.height >= 1
            else { continue }
            if let pid = info[kCGWindowOwnerPID as String] as? Int, pid == myPID { continue }   // 不算本 app(壁纸窗)
            if let alpha = info[kCGWindowAlpha as String] as? Double, alpha < 0.1 { continue }   // 近透明窗不算遮挡
            winRects.append(b)
        }
        guard !winRects.isEmpty else { return 0 }
        // 每块屏网格采样(48×30 格),格中心落在任一窗口内即算被遮 → 覆盖率 = 被遮格 / 总格(自动处理窗口重叠并集)。
        let cols = 48, rows = 30
        var maxFrac = 0.0
        for sr in screenRectsCG where sr.width > 0 && sr.height > 0 {
            let cw = sr.width / CGFloat(cols), ch = sr.height / CGFloat(rows)
            var covered = 0
            for gy in 0..<rows {
                let cy = sr.minY + (CGFloat(gy) + 0.5) * ch
                for gx in 0..<cols {
                    let cx = sr.minX + (CGFloat(gx) + 0.5) * cw
                    let p = CGPoint(x: cx, y: cy)
                    if winRects.contains(where: { $0.contains(p) }) { covered += 1 }
                }
            }
            maxFrac = max(maxFrac, Double(covered) / Double(cols * rows))
        }
        return maxFrac
    }

    /// 审计修复 #6:检测是否有窗口在“它实际所在的那块屏”上全屏遮挡(支持多显示器)。
    /// 旧实现只看主屏、且仅按裸尺寸 ≥ 主屏判定 → 多屏误暂停/漏暂停,且任意大窗口都会误判全屏。
    /// 新实现:把每块屏的 frame 换算到 CGWindowList 使用的“左上原点、Y 向下”全局坐标系,要求窗口
    /// frame 与某块屏的 frame 在位置和尺寸上都基本重合(而非仅尺寸 ≥),才算该屏被全屏遮挡。
    /// 函数名沿用历史命名,语义现为“任一屏被全屏窗口遮挡”。
    static func isMainScreenCoveredByFullscreen() -> Bool {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return false }
        // CGWindowList 的 bounds 原点在“全局最高屏的左上角、Y 向下”;NSScreen.frame 原点在左下、Y 向上。
        // 取所有屏中最大的 maxY 作为翻转基准,把每块屏 frame 转成 CG 坐标系下的矩形。
        let globalTop = screens.map { $0.frame.maxY }.max() ?? 0
        let screenRectsCG: [CGRect] = screens.map { s in
            let f = s.frame
            return CGRect(x: f.origin.x, y: globalTop - f.maxY, width: f.width, height: f.height)
        }
        guard let infoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        let tol: CGFloat = 4   // 像素容差(标题栏隐藏/缩放取整带来的细微偏差)
        for info in infoList {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,  // 普通应用窗口层
                  let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let b = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { continue }
            // 窗口 frame 需与某块屏 frame 在原点与尺寸上都基本重合,才算该屏被全屏遮挡。
            for sr in screenRectsCG {
                if abs(b.origin.x - sr.origin.x) <= tol,
                   abs(b.origin.y - sr.origin.y) <= tol,
                   abs(b.width - sr.width) <= tol,
                   abs(b.height - sr.height) <= tol {
                    return true
                }
            }
        }
        return false
    }
}
