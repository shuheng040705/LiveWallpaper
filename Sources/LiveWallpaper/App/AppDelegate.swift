import AppKit
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!

    private let library = WallpaperLibrary()
    private let desktop = DesktopController()
    private lazy var power = PowerManager(desktop: desktop)
    private lazy var rotation = RotationManager(
        library: library,
        currentID: { [weak self] in self?.desktop.current?.id },
        apply: { [weak self] item in self?.apply(item) }
    )
    private lazy var libraryWindow = LibraryWindowController(
        library: library,
        actions: makeActions()
    )
    private var folderWatcher: FolderWatcher?
    private lazy var downloadsWindow = DownloadsWindowController()
    private var cancellables = Set<AnyCancellable>()
    private var cancelAlertShowing = Set<String>()   // 正在弹取消询问的 job id(去重)

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
        setupMainMenu()
        // UI 预览模式(WP_UI_PREVIEW=1,截图验证用):不启动桌面渲染/电源/轮换,
        // 只扫描库并打开主窗口 → 可对新 UI 截图,而不干扰正在运行的壁纸实例。
        if ProcessInfo.processInfo.environment["WP_UI_PREVIEW"] != nil {
            library.scan { [weak self] in self?.openLibrary() }
            return
        }
        desktop.start()
        power.start()
        NowPlayingProvider.shared.start()   // 系统正在播放的音乐(喂 Now Playing widget 歌名/艺术家)
        WorkshopDownloader.shared.prewarm()   // 后台预热 steamcmd → 首次下载跳过冷启动等待
        library.scan { [weak self] in
            self?.restoreOrOpenLibrary()
            self?.rotation.reschedule()
        }
        startWatchingLibrary()
        observeDownloads()
    }

    /// 监听「打开下载窗口」请求,以及取消下载后的「保留/删除」询问。
    private func observeDownloads() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(openDownloads), name: .showDownloads, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(onUnsubscribeWallpaper(_:)), name: .unsubscribeWallpaper, object: nil)
        WorkshopDownloader.shared.$jobs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] jobs in self?.handleCancelledJobs(jobs) }
            .store(in: &cancellables)
    }

    @objc private func openDownloads() { downloadsWindow.show() }

    /// 网页里取消订阅 → 删除对应本地壁纸(移到废纸篓,与右键删除同一路径,处理正在播放/库刷新)。
    @objc private func onUnsubscribeWallpaper(_ note: Notification) {
        guard let id = note.userInfo?["id"] as? String, let item = library.item(id: id) else { return }
        deleteWallpaper(item)
    }

    /// 出现「已取消」的下载 → 弹应用级询问:保留已下内容还是删除。
    private func handleCancelledJobs(_ jobs: [WorkshopDownloader.Job]) {
        // 清掉已从列表消失任务的标记(弹窗期间该任务仍在,不会被清)
        cancelAlertShowing = cancelAlertShowing.filter { id in jobs.contains { $0.id == id } }
        for job in jobs {
            guard case .cancelled = job.state, !cancelAlertShowing.contains(job.id) else { continue }
            cancelAlertShowing.insert(job.id)
            let alert = NSAlert()
            alert.messageText = "已取消下载「\(job.title)」"
            alert.informativeText = "SteamCMD 未完成的下载通常没有可保留的部分文件;若已接近完成会尝试入库。是否保留已下载的内容?"
            alert.addButton(withTitle: "删除")            // 第一个=默认(回车)
            alert.addButton(withTitle: "保留已下内容")
            NSApp.activate(ignoringOtherApps: true)
            let keep = alert.runModal() == .alertSecondButtonReturn
            WorkshopDownloader.shared.resolveCancelled(id: job.id, keep: keep)
        }
    }

    /// 监视壁纸库目录:Steam 下完新工坊壁纸 → 自动重新扫描进库。
    private func startWatchingLibrary() {
        folderWatcher?.stop()
        let w = FolderWatcher(url: PreferencesStore.shared.libraryRoot) { [weak self] in
            self?.library.scan()
        }
        w.start()
        folderWatcher = w
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// 主窗口的所有回调:把 UI 操作接到运行中的渲染器/轮换器/系统。
    private func makeActions() -> LibraryActions {
        LibraryActions(
            onSelect: { [weak self] item in self?.apply(item) },
            onMuteChanged: { [weak self] m in self?.desktop.setMuted(m) },
            onVolumeChanged: { [weak self] v in self?.desktop.setVolume(v) },
            onRotationChanged: { [weak self] in self?.rotation.reschedule() },
            onLoginChanged: { LoginItem.setEnabled($0) },
            onPowerChanged: { [weak self] on in self?.power.isEnabled = on },
            onAssetsPathChanged: { [weak self] in self?.desktop.reloadCurrent() },
            onLibraryRootChanged: { [weak self] in self?.library.scan(); self?.startWatchingLibrary() },
            onNext: { [weak self] in self?.rotation.advance() },
            onTogglePause: { [weak self] in self?.desktop.togglePause() },
            onClear: { [weak self] in self?.desktop.clear(); self?.libraryWindow.updateCurrent(nil) },
            onQuit: { NSApp.terminate(nil) },
            isPaused: { [weak self] in self?.desktop.isPaused ?? false },
            onVideoFillChanged: { [weak self] f in self?.desktop.setVideoFill(f) },
            onMainScreenOnlyChanged: { [weak self] on in self?.desktop.setMainScreenOnly(on) },
            onDesktopIconsChanged: { on in DesktopIcons.setVisible(on) },
            onDelete: { [weak self] item in self?.deleteWallpaper(item) },
            onApplySettings: { [weak self] item in self?.scheduleSettingsReload(item) },
            onUnsubscribe: { [weak self] item in
                // 先取消 Steam 订阅(网页会话),无论成功与否都删除本地壁纸。
                SteamSubscription.unsubscribe(id: item.id) { ok, msg in
                    Log.write("Unsubscribe \(item.id): \(ok ? "OK" : "fail") — \(msg)")
                }
                self?.deleteWallpaper(item)
            }
        )
    }

    /// 壁纸属性改动后的重载:防抖(拖滑块会高频触发),合并成 0.25s 后一次重载。
    private var settingsReloadWork: DispatchWorkItem?
    private func scheduleSettingsReload(_ item: WallpaperItem) {
        guard desktop.currentID == item.id else { return }   // 只重载正在播放的
        settingsReloadWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.desktop.reloadCurrentInPlace() }
        settingsReloadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    /// 删除壁纸:若是当前正在播放的先关掉,把文件夹移到废纸篓(可恢复),再重新扫描。
    private func deleteWallpaper(_ item: WallpaperItem) {
        if desktop.current?.id == item.id {
            desktop.clear()
            libraryWindow.updateCurrent(nil)
        }
        do {
            try FileManager.default.trashItem(at: item.folderURL, resultingItemURL: nil)
            Log.write("deleteWallpaper: trashed \(item.id)")
        } catch {
            Log.write("deleteWallpaper: trash failed \(item.id): \(error)")
        }
        library.scan()
    }

    // MARK: - 菜单栏图标:左键直接开主窗口,右键给个"退出"兜底

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "photo.on.rectangle.angled",
            accessibilityDescription: "Live Wallpaper"
        )
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            // 右键:弹一个只有"退出"的极简菜单
            let menu = NSMenu()
            let quit = NSMenuItem(title: "退出 Live Wallpaper", action: #selector(quit), keyEquivalent: "q")
            quit.target = self
            menu.addItem(quit)
            statusItem.menu = menu
            statusItem.button?.performClick(nil)   // 弹出
            statusItem.menu = nil                   // 立即解绑,保持左键=直接打开
        } else {
            // 左键:直接打开主窗口
            openLibrary()
        }
    }

    /// 主菜单:.regular 模式下顶部菜单栏 + 标准快捷键(搜索框复制粘贴、⌘W、⌘Q)。
    private func setupMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "隐藏 Live Wallpaper", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 Live Wallpaper", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem(); main.addItem(editItem)
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        let winItem = NSMenuItem(); main.addItem(winItem)
        let winMenu = NSMenu(title: "窗口")
        winMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        winMenu.addItem(withTitle: "关闭", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        winItem.submenu = winMenu
        NSApp.windowsMenu = winMenu

        NSApp.mainMenu = main
    }

    private func restoreOrOpenLibrary() {
        Log.write("scan done: \(library.items.count) items; lastID=\(PreferencesStore.shared.lastWallpaperID ?? "nil")")
        // 启动时恢复上次壁纸(若有),但不自动弹窗——保持安静后台。
        if let lastID = PreferencesStore.shared.lastWallpaperID,
           let item = library.item(id: lastID) {
            apply(item)
        } else {
            openLibrary()   // 首次使用没有壁纸,弹窗引导
        }
    }

    // MARK: - Actions

    private func apply(_ item: WallpaperItem) {
        desktop.apply(item)
        libraryWindow.updateCurrent(item.id)
    }

    @objc private func openLibrary() {
        libraryWindow.show(currentID: desktop.current?.id)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
