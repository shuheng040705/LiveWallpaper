import AppKit

/// 省电:当有应用进入全屏(壁纸被完全遮挡)时自动暂停渲染,退出后恢复。
/// 通过监听活跃 Space 是否为全屏来判断——用窗口遮挡近似:某 App 窗口 frame 与任一块屏 frame
/// 基本重合(位置+尺寸)即视为该屏被全屏遮挡(审计修复 #6:支持多显示器,不再只看主屏/裸尺寸)。
final class PowerManager {
    private weak var desktop: DesktopController?
    /// 从偏好读初值(原来硬编码 true → 用户关掉后重启又自动打开)。
    private var enabled = PreferencesStore.shared.occlusionPauseEnabled
    private var pausedByPower = false
    private var pollTimer: Timer?   // 定时轮询遮挡覆盖率(窗口移动/缩放/台前调度无激活事件,需主动查)
    /// 暂停确认延迟用的 pending work item。台前调度「显示桌面/窗口收回」那一刻会先发 activeSpace 变化通知,
    /// 而此刻应用窗口尚未真正收回左侧栏 → 瞬间遮挡率仍达阈值 → 旧逻辑立刻 pause(CVDisplayLinkStop),
    /// 几百 ms 后窗口收回、下一次 evaluate 才 resume → 壁纸卡顿约 1 秒。修复:遮挡达阈值不立刻暂停,
    /// 而是延迟 settleDelay 复查仍遮挡才真正暂停(瞬时遮挡尖峰会在复查前消失 → 不暂停 → 不卡顿)。
    private var pausePending: DispatchWorkItem?
    private var pollTick = 0
    /// 暂停前的「持续遮挡」确认窗口。台前调度过场遮挡尖峰远短于此 → 永不误暂停;真正全屏 App / 大窗口
    /// 持续遮挡会跨过此窗口 → 仍会暂停省电。resume(取消遮挡)始终即时,不延迟。
    private let settleDelay: TimeInterval = 0.8

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
        // ⭐显示器睡眠 / 锁屏(审计 R5):原来只处理**系统**睡眠。显示器单独休眠或锁屏时系统仍醒着 →
        //   PowerManager 不暂停 → 壁纸不可见,但 SceneRenderer 的「备用计时器」(显示链停回调时接管)
        //   会一直以 ~33Hz 渲染到黑掉的屏幕上,纯烧 CPU/GPU 和电。这两类事件与系统睡眠同等对待。
        nc.addObserver(self, selector: #selector(displaysDidSleep),
                       name: NSWorkspace.screensDidSleepNotification, object: nil)
        nc.addObserver(self, selector: #selector(displaysDidWake),
                       name: NSWorkspace.screensDidWakeNotification, object: nil)
        // 锁屏没有 NSWorkspace 通知,只能听 distributed notification。
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(self, selector: #selector(displaysDidSleep),
                        name: NSNotification.Name("com.apple.screenIsLocked"), object: nil)
        dnc.addObserver(self, selector: #selector(displaysDidWake),
                        name: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil)
        // 遮挡覆盖率轮询(2.5s):窗口拖动/缩放不发激活通知,靠它捕捉「遮挡达阈值」的变化。开销很低
        //(一次 CGWindowList + 网格采样)。仅 enabled 时真正 evaluate。
        // ⭐自适应轮询(2026-06-26 修台前调度「显示桌面」恢复仍卡):**暂停期间每 0.5s 复查**(uncovered 即即时恢复,
        //   消除靠 2.5s 轮询才恢复的 ~1s 滞留卡顿——「显示桌面」可能不发 activeChanged,只能靠轮询检测);
        //   未暂停时每 2.5s 复查一次(省 CGWindowList 开销)。配合 SceneRenderer 旗标式暂停=恢复零冷启动。
        let t = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.pollTick &+= 1
            if self.pausedByPower || self.pollTick % 5 == 0 { self.evaluate() }
        }
        t.tolerance = 0.1
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
    }

    var isEnabled: Bool {
        get { enabled }
        set {
            enabled = newValue
            PreferencesStore.shared.occlusionPauseEnabled = newValue   // 落盘,重启后保持
            if !enabled {
                cancelPendingPause()
                if pausedByPower { desktop?.resume(); pausedByPower = false }
            } else { evaluate() }
        }
    }

    private func cancelPendingPause() {
        pausePending?.cancel()
        pausePending = nil
    }

    @objc private func activeChanged() {
        // ⭐偏向恢复(消除台前调度「显示桌面」恢复卡顿):Space/App 切换瞬间应用窗口可能还盖在屏上(过场),
        //   旧逻辑会把这瞬时遮挡当真、滞留暂停到下次 evaluate(最长 2.5s 轮询)才恢复 → 卡顿。改:切换先
        //   即时恢复(配合 SceneRenderer 旗标式暂停=零 CVDisplayLink 冷重启),再 evaluate 复查——真持续遮挡
        //   会在 settleDelay 后重新暂停;「显示桌面」过场遮挡尖峰会在复查前消失 → 保持恢复 → 不卡顿。
        if pausedByPower { desktop?.resume(); pausedByPower = false; Log.write("power: resumed (transition)") }
        evaluate()
    }

    // 审计修复 #5:willSleep 暂停时必须置 pausedByPower=true,标记“本次暂停由 PowerManager 负责恢复”,
    // 否则 didWake/evaluate 无人认领该暂停 → 唤醒后永不 resume(卡在暂停)。
    @objc private func willSleep() {
        cancelPendingPause()   // 睡眠是确定意图,立刻暂停;丢弃任何在途的遮挡暂停确认
        guard let desktop, !desktop.isPaused else { return }
        desktop.pause(); pausedByPower = true
        Log.write("power: paused (will sleep)")
    }

    /// 显示器休眠 / 锁屏:壁纸不可见,与系统睡眠同等处理(否则备用计时器会一直渲染黑屏)。
    /// ⚠ 这里**不看 isEnabled**:那个开关的语义是「被窗口遮挡时是否自动暂停」,而屏幕黑着/锁着时
    /// 渲染毫无意义,任何设置下都该停。
    @objc private func displaysDidSleep() {
        cancelPendingPause()
        guard let desktop, !desktop.isPaused else { return }
        desktop.pause(); pausedByPower = true
        Log.write("power: paused (显示器休眠 / 锁屏)")
    }

    @objc private func displaysDidWake() {
        cancelPendingPause()
        guard pausedByPower else { return }
        pausedByPower = false
        desktop?.resume()
        evaluate()   // 醒来后若仍被全屏遮挡,由 evaluate 重新暂停
        Log.write("power: resumed (显示器唤醒 / 解锁)")
    }

    // 审计修复 #5:谁暂停谁恢复 —— 只有当暂停是 PowerManager 造成的(pausedByPower)才恢复。
    // 唤醒后不直接 resume,而是走 evaluate():若此刻仍被全屏遮挡则保持暂停,不会误恢复到被遮挡状态。
    @objc private func didWake() {
        cancelPendingPause()
        guard pausedByPower else { return }
        pausedByPower = false
        desktop?.resume()   // 先恢复,再由 evaluate 决定是否因全屏遮挡重新暂停
        evaluate()
    }

    /// 据「窗口遮挡阈值」设置决定是否暂停:0=仅全屏(精确匹配);其余=遮挡覆盖率 ≥ 阈值% 即暂停。
    /// 适配台前调度/大窗口遮挡——不必全屏也能省电。
    private func evaluate() {
        guard enabled, let desktop else { return }
        // 多屏按屏暂停(审计 R21):检测本就是按屏算的,过去动作却是全局的 —— 副屏全屏看视频会把
        // 主屏可见的壁纸一起冻结。有 2 块以上屏时走按屏路径;单屏保持原有的整体暂停逻辑不变
        // (含 settleDelay 去抖,那是台前调度过场卡顿的既有修复,不能丢)。
        if desktop.screenCount > 1 {
            let covered = Self.coveredScreenFrames()
            if covered.count == 0 {
                cancelPendingPause()
                if pausedByPower { desktop.applyOcclusion(coveredScreenFrames: []); pausedByPower = false }
                return
            }
            guard pausePending == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.enabled, let desktop = self.desktop else { return }
                self.pausePending = nil
                let still = Self.coveredScreenFrames()   // settleDelay 后复查,过场尖峰已消失则不暂停
                guard still.count > 0 else { return }
                desktop.applyOcclusion(coveredScreenFrames: still)
                self.pausedByPower = true
                Log.write("power: 按屏暂停 \(still.count)/\(desktop.screenCount) 块屏(threshold=\(PreferencesStore.shared.occlusionThreshold))")
            }
            pausePending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay, execute: work)
            return
        }
        if Self.isCovered() {
            // 遮挡达阈值:不立刻暂停。台前调度「显示桌面」过场会让应用窗口短暂仍占满屏(几百 ms)再收回
            //   左侧栏,这种瞬时遮挡尖峰不应触发暂停(否则 CVDisplayLinkStop→几百 ms 后才 resume = 卡顿)。
            //   延迟 settleDelay 复查仍遮挡才真正暂停;尖峰会在复查前消失(下面 else 分支会撤销 pending)。
            guard !desktop.isPaused, pausePending == nil else { return }   // 已暂停/已有在途确认 → 不重复排
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.enabled, let desktop = self.desktop else { return }
                self.pausePending = nil
                // 复查:settleDelay 后仍持续遮挡才暂停(真全屏 App / 大窗口会跨过该窗口仍遮挡)。
                guard Self.isCovered(), !desktop.isPaused else { return }
                desktop.pause(); self.pausedByPower = true
                Log.write("power: paused (occlusion, threshold=\(PreferencesStore.shared.occlusionThreshold))")
            }
            pausePending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay, execute: work)
        } else {
            // 未遮挡:撤销任何在途暂停确认(瞬时遮挡尖峰到此已消失 → 永不误暂停),并即时恢复。
            cancelPendingPause()
            if pausedByPower {
                desktop.resume(); pausedByPower = false
                Log.write("power: resumed")
            }
        }
    }

    /// 当前是否达到「暂停遮挡阈值」:0=仅真正全屏(精确匹配);其余=最大屏遮挡覆盖率 ≥ 阈值%。
    private static func isCovered() -> Bool {
        let threshold = PreferencesStore.shared.occlusionThreshold
        if threshold <= 0 { return isMainScreenCoveredByFullscreen() }
        return maxScreenCoverageFraction() * 100 >= Double(threshold)
    }

    /// 按屏返回「是否被遮挡」(审计 R21):检测本来就是按屏算的,只是过去只取了最大值。
    /// 返回被遮挡屏幕的 frame(AppKit 坐标,与 NSScreen.frame 同系),供 DesktopController 按屏暂停。
    static func coveredScreenFrames() -> [CGRect] {
        let threshold = PreferencesStore.shared.occlusionThreshold
        let fracs = screenCoverageFractions()
        var out: [CGRect] = []
        for (frame, frac) in fracs {
            let covered = threshold <= 0
                ? isScreenCoveredByFullscreen(frame)
                : (frac * 100 >= Double(threshold))
            if covered { out.append(frame) }
        }
        return out
    }

    /// 主屏/各屏被其他应用普通窗口遮挡的**最大**覆盖率 [0,1](网格采样窗口并集占屏比)。
    /// 用于「遮挡达阈值即暂停」(台前调度场景)。排除本 app、桌面元素、菜单栏/Dock(layer≠0)、近透明窗口。
    static func maxScreenCoverageFraction() -> Double {
        screenCoverageFractions().values.max() ?? 0
    }

    /// 逐屏覆盖率:NSScreen.frame(AppKit 坐标)→ 覆盖率 [0,1]。
    static func screenCoverageFractions() -> [CGRect: Double] {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return [:] }
        let globalTop = screens.map { $0.frame.maxY }.max() ?? 0
        let screenRectsCG: [CGRect] = screens.map { s in
            let f = s.frame
            return CGRect(x: f.origin.x, y: globalTop - f.maxY, width: f.width, height: f.height)
        }
        guard let infoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [:] }
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
        guard !winRects.isEmpty else {
            var zeros: [CGRect: Double] = [:]
            for s in screens { zeros[s.frame] = 0.0 }
            return zeros
        }
        // 每块屏网格采样(48×30 格),格中心落在任一窗口内即算被遮 → 覆盖率 = 被遮格 / 总格(自动处理窗口重叠并集)。
        let cols = 48, rows = 30
        var out: [CGRect: Double] = [:]
        for (si, sr) in screenRectsCG.enumerated() where sr.width > 0 && sr.height > 0 {
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
            out[screens[si].frame] = Double(covered) / Double(cols * rows)
        }
        return out
    }

    /// 审计修复 #6:检测是否有窗口在“它实际所在的那块屏”上全屏遮挡(支持多显示器)。
    /// 旧实现只看主屏、且仅按裸尺寸 ≥ 主屏判定 → 多屏误暂停/漏暂停,且任意大窗口都会误判全屏。
    /// 新实现:把每块屏的 frame 换算到 CGWindowList 使用的“左上原点、Y 向下”全局坐标系,要求窗口
    /// frame 与某块屏的 frame 在位置和尺寸上都基本重合(而非仅尺寸 ≥),才算该屏被全屏遮挡。
    /// 函数名沿用历史命名,语义现为“任一屏被全屏窗口遮挡”。
    /// 单块屏是否被全屏窗口遮挡(按屏暂停用;下面的「任一屏」版本复用它)。
    /// - Parameter screenFrame: NSScreen.frame(AppKit 坐标,左下原点)。
    static func isScreenCoveredByFullscreen(_ screenFrame: CGRect) -> Bool {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return false }
        let globalTop = screens.map { $0.frame.maxY }.max() ?? 0
        let sr = CGRect(x: screenFrame.origin.x, y: globalTop - screenFrame.maxY,
                        width: screenFrame.width, height: screenFrame.height)
        guard let infoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        let tol: CGFloat = 4
        for info in infoList {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let b = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { continue }
            if abs(b.origin.x - sr.origin.x) <= tol, abs(b.origin.y - sr.origin.y) <= tol,
               abs(b.width - sr.width) <= tol, abs(b.height - sr.height) <= tol {
                return true
            }
        }
        return false
    }

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
