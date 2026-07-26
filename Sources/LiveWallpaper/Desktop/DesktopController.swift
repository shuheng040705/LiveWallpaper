import AppKit

/// 管理每块屏幕的桌面窗口,以及当前壁纸的渲染器集合。
final class DesktopController {
    private var windows: [DesktopWindow] = []
    private var renderers: [WallpaperRenderer] = []
    private(set) var current: WallpaperItem?
    private(set) var isPaused = false
    /// 审计修复(#6):屏幕参数变更防抖用的 pending work item。插拔屏/分辨率切换瞬间系统会连发多条
    ///   didChangeScreenParameters 通知,逐条全量 rebuild 既浪费又会黑闪多次;这里合并到 0.3s 后跑一次。
    private var screenChangeWork: DispatchWorkItem?

    func start() {
        rebuildWindows()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    @objc private func screensChanged() {
        // 审计修复(#6):防抖——取消上一次 pending,延迟 0.3s 合并连发的通知,只在最后真正 rebuild 一次。
        screenChangeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.rebuildWindows()
            if let c = self.current { self.apply(c) }   // 屏幕变化后在新窗口上重建渲染
        }
        screenChangeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func rebuildWindows() {
        renderers.forEach { $0.stop() }
        renderers.removeAll()
        windows.forEach { $0.orderOut(nil) }
        // 显示器范围:仅主屏 or 所有屏。
        let screens: [NSScreen]
        if PreferencesStore.shared.mainScreenOnly, let main = NSScreen.main {
            screens = [main]
        } else {
            screens = NSScreen.screens
        }
        windows = screens.map { DesktopWindow(screen: $0) }
        windows.forEach { $0.orderFrontRegardless() }
        Log.write("rebuildWindows: \(windows.count) screen(s)")
        for (i, w) in windows.enumerated() {
            Log.write("  window[\(i)] level=\(w.level.rawValue) frame=\(NSStringFromRect(w.frame)) visible=\(w.isVisible)")
        }
    }

    /// 应用一张壁纸到所有屏幕。
    func apply(_ item: WallpaperItem) {
        renderers.forEach { $0.stop() }
        renderers.removeAll()
        current = item
        PreferencesStore.shared.lastWallpaperID = item.id
        isPaused = false

        Log.write("apply: \(item.title) [\(item.type.rawValue)] file=\(item.fileURL?.path ?? "nil") on \(windows.count) window(s)")
        for window in windows {
            guard let host = window.contentView else { continue }
            host.subviews.forEach { $0.removeFromSuperview() }
            guard let renderer = RendererFactory.make(for: item) else {
                Log.write("apply: no renderer for type \(item.type.rawValue)")
                continue
            }
            renderer.attach(to: host)
            renderer.load(item)
            renderer.start()
            renderers.append(renderer)
        }
        Log.write("apply: \(renderers.count) renderer(s) active")
    }

    /// 当前壁纸的渲染缺口(供 UI 弹窗指明没能渲染成功的项)。
    func currentRenderGaps() -> [String] { renderers.first?.renderGaps ?? [] }

    func clear() {
        renderers.forEach { $0.stop() }
        renderers.removeAll()
        windows.forEach { $0.contentView?.subviews.forEach { $0.removeFromSuperview() } }
        current = nil
    }

    func pause() {
        isPaused = true
        renderers.forEach { $0.pause() }
    }

    func resume() {
        isPaused = false
        renderers.forEach { $0.resume() }
    }

    func togglePause() {
        isPaused ? resume() : pause()
    }

    /// 切换静音并即时应用到正在播放的视频。
    func setMuted(_ muted: Bool) {
        PreferencesStore.shared.isMuted = muted
        renderers.forEach { $0.setMuted(muted) }
    }

    /// 设置音量并即时应用。
    func setVolume(_ v: Double) {
        PreferencesStore.shared.volume = v
        renderers.forEach { $0.setVolume(v) }
    }

    /// 当前壁纸 id(供轮换/重载用)。
    var currentID: String? { current?.id }

    /// 重新加载当前壁纸(资源目录变更后让 scene 重新解析)。完全重建,会黑闪一下。
    func reloadCurrent() {
        if let c = current { apply(c) }
    }

    /// 就地重载当前壁纸(属性改动后)——不重建窗口/视图,无黑屏。
    func reloadCurrentInPlace() {
        renderers.forEach { $0.reloadInPlace() }
    }

    /// 视频填充模式即时应用。
    func setVideoFill(_ fill: Bool) {
        PreferencesStore.shared.videoFill = fill
        renderers.forEach { $0.setFillMode(fill) }
    }

    /// 显示器范围变更:重建窗口并重放当前壁纸。
    func setMainScreenOnly(_ on: Bool) {
        PreferencesStore.shared.mainScreenOnly = on
        rebuildWindows()
        if let c = current { apply(c) }
    }
}
