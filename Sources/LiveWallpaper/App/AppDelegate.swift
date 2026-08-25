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
    private lazy var settingsWindow = SettingsWindowController(
        actions: makeActions(),
        currentItem: { [weak self] in
            guard let self, let id = self.desktop.current?.id else { return nil }
            return self.library.item(id: id)
        }
    )
    // 强引用持有,避免可缩放的订阅窗口被释放(同 settingsWindow)。
    private lazy var subscriptionsWindow = SubscriptionsWindowController()
    private var cancellables = Set<AnyCancellable>()
    private var cancelAlertShowing = Set<String>()   // 正在弹取消询问的 job id(去重)
    private var uninstallingIDs = Set<String>()      // 防止菜单/卡片连点触发重复退订和删除

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
        setupMainMenu()
        // 启动即迁移/恢复 Steam Community 网页授权，不能等到用户下一次打开设置或执行退订：
        // 这样升级前仍有效的 WebKit session cookie 会立刻进入 Keychain，避免迁移窗口内丢失。
        SteamWebSession.shared.refresh()
        // 首页预览每次重启重新渲染一遍(清磁盘缓存),反映引擎最新改动(用户要求)。
        RenderedPreviewCache.shared.invalidateAllOnLaunch()
        // UI 预览模式(WP_UI_PREVIEW=1,截图验证用):不启动桌面渲染/电源/轮换,
        // 只扫描库并打开主窗口 → 可对新 UI 截图,而不干扰正在运行的壁纸实例。
        if WPEnv.vars["WP_UI_PREVIEW"] != nil {
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

    func applicationWillTerminate(_ notification: Notification) {
        WorkshopDownloader.shared.shutdown()
    }

    /// 监听「打开下载窗口」请求,以及取消下载后的「保留/删除」询问。
    private func observeDownloads() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(openDownloads), name: .showDownloads, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(openSettings), name: .showSettings, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(openSubscriptions), name: .showSubscriptions, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(onUnsubscribeWallpaper(_:)), name: .unsubscribeWallpaper, object: nil)
        WorkshopDownloader.shared.$jobs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] jobs in
                self?.handleCancelledJobs(jobs)
                self?.updateStatusItemAppearance()
            }
            .store(in: &cancellables)
    }

    @objc private func openDownloads() { downloadsWindow.show() }

    /// 打开「设置」窗口(独立可拖拽改大小的 NSWindow,取代原 SwiftUI sheet)。
    @objc private func openSettings() { settingsWindow.show() }

    /// 打开「我的 Steam 订阅」窗口(独立可拖拽改大小的 NSWindow,取代原 SwiftUI sheet)。
    @objc private func openSubscriptions() { subscriptionsWindow.show() }

    /// Steam 网页已经取消订阅 → 只做本地卸载。此通知的前置条件是 Steam 操作已经成功，
    /// 所以不能再走一次网页退订，也不能误报成“无论成功都删”。
    @objc private func onUnsubscribeWallpaper(_ note: Notification) {
        guard let id = note.userInfo?["id"] as? String else { return }
        guard !uninstallingIDs.contains(id) else { return }
        uninstallingIDs.insert(id)
        if let item = library.item(id: id) {
            removeLocalWallpaper(item, subscriptionWasCancelled: true)
        } else {
            // project.json 损坏或扫描尚未完成时，订阅面板仍应能卸载这个实际存在的目录。
            let folder = PreferencesStore.shared.libraryRoot.appendingPathComponent(id, isDirectory: true)
            guard FileManager.default.fileExists(atPath: folder.path) else {
                uninstallingIDs.remove(id)
                return
            }
            removeLocalWallpaper(
                id: id,
                title: "创意工坊 #\(id)",
                folderURL: folder,
                restoreItem: nil,
                subscriptionWasCancelled: true
            )
        }
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

    /// Dock/台前调度中的 app 缩略图被再次点中时，桌面壁纸窗口本身也算“可见窗口”，系统传入的
    /// flag 因而不能代表库窗口是否可见。统一走 show()，由控制器恢复或重建真正的主窗口。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openLibrary()
        return false
    }

    /// 主窗口的所有回调:把 UI 操作接到运行中的渲染器/轮换器/系统。
    private func makeActions() -> LibraryActions {
        LibraryActions(
            onSelect: { [weak self] item in self?.apply(item, interactive: true) },
            onMuteChanged: { [weak self] m in
                self?.desktop.setMuted(m)
                self?.updateStatusItemAppearance()
            },
            onVolumeChanged: { [weak self] v in self?.desktop.setVolume(v) },
            onRotationChanged: { [weak self] in
                self?.rotation.reschedule()
                self?.updateStatusItemAppearance()
            },
            onLoginChanged: { LoginItem.setEnabled($0) },
            onPowerChanged: { [weak self] on in self?.power.isEnabled = on },
            onAssetsPathChanged: { [weak self] in self?.desktop.reloadCurrent() },
            onLibraryRootChanged: { [weak self] in self?.library.scan(); self?.startWatchingLibrary() },
            onNext: { [weak self] in self?.rotation.advance() },
            onTogglePause: { [weak self] in self?.togglePause() },
            onClear: { [weak self] in self?.clearCurrentWallpaper() },
            onQuit: { NSApp.terminate(nil) },
            isPaused: { [weak self] in self?.desktop.isPaused ?? false },
            onVideoFillChanged: { [weak self] f in self?.desktop.setVideoFill(f) },
            onMainScreenOnlyChanged: { [weak self] on in self?.desktop.setMainScreenOnly(on) },
            onDesktopIconsChanged: { on in DesktopIcons.setVisible(on) },
            onDelete: { [weak self] item in self?.requestUninstall(item, cancelSteamSubscription: false) },
            onApplySettings: { [weak self] item in self?.scheduleSettingsReload(item) },
            onUnsubscribe: { [weak self] item in
                self?.requestUninstall(item, cancelSteamSubscription: true)
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

    /// 统一卸载入口。Steam 工坊项目先退订，只有服务端确认成功后才自动移除本地文件。
    /// 本地导入的壁纸没有 Steam 订阅，直接走可恢复的“移到废纸篓”。
    private func requestUninstall(_ item: WallpaperItem, cancelSteamSubscription: Bool) {
        guard !uninstallingIDs.contains(item.id) else {
            Log.write("uninstall: \(item.id) already in progress, ignored duplicate request")
            return
        }
        uninstallingIDs.insert(item.id)

        let knownSubscribed = SteamSubscriptionRegistry.isKnownSubscribed(item.id)
        let requiresSteam = WallpaperUninstallPolicy.requiresSteamUnsubscribe(
            itemID: item.id,
            requested: cancelSteamSubscription,
            knownSubscribed: knownSubscribed
        )
        guard requiresSteam else {
            if cancelSteamSubscription, WallpaperUninstallPolicy.isSteamWorkshopID(item.id), !knownSubscribed {
                Log.write("uninstall: \(item.id) has no subscription evidence → local uninstall without web authorization")
            }
            removeLocalWallpaper(item, subscriptionWasCancelled: false)
            return
        }

        Log.write("uninstall: unsubscribe Steam workshop \(item.id) before local removal")
        unsubscribeAndRemove(item)
    }

    /// SteamCMD 下载登录与网页退订授权是两套会话。缺网页 Cookie 时直接打开 Steam 官方授权页，
    /// 授权成功自动重试，不再把设置页里已登录的下载账号误报成“未登录 Steam”。
    private func unsubscribeAndRemove(_ item: WallpaperItem) {
        SteamSubscription.unsubscribe(id: item.id) { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .success(let message):
                Log.write("uninstall: unsubscribe \(item.id): OK — \(message)")
                guard WallpaperUninstallPolicy.mayRemoveLocalFiles(
                    requiresSteamUnsubscribe: true,
                    unsubscribeSucceeded: true
                ) else {
                    self.uninstallingIDs.remove(item.id)
                    return
                }
                self.removeLocalWallpaper(item, subscriptionWasCancelled: true)

            case .authenticationRequired:
                Log.write("uninstall: \(item.id) needs Steam web authorization; opening official login")
                SteamWebSession.shared.clearAuthenticationCookies {
                    SteamWebLoginWindowController.shared.authorize(workshopID: item.id) { [weak self] authorized in
                        guard let self else { return }
                        if authorized {
                            self.unsubscribeAndRemove(item)
                        } else {
                            self.uninstallingIDs.remove(item.id)
                            self.showWebAuthorizationCancelled(item)
                        }
                    }
                }

            case .failure(let message):
                Log.write("uninstall: unsubscribe \(item.id): fail — \(message)")
                self.uninstallingIDs.remove(item.id)
                self.showUnsubscribeFailure(item, message: message)
            }
        }
    }

    /// 真正的本地卸载：停止关联下载/预览，安全停止正在使用的壁纸，移到废纸篓后重扫库。
    /// 若移动失败，会恢复刚才正在使用的壁纸，避免一次失败操作把桌面留空。
    private func removeLocalWallpaper(_ item: WallpaperItem, subscriptionWasCancelled: Bool) {
        removeLocalWallpaper(
            id: item.id,
            title: item.title,
            folderURL: item.folderURL,
            restoreItem: item,
            subscriptionWasCancelled: subscriptionWasCancelled
        )
    }

    private func removeLocalWallpaper(
        id: String,
        title: String,
        folderURL: URL,
        restoreItem: WallpaperItem?,
        subscriptionWasCancelled: Bool
    ) {
        guard WallpaperUninstallPolicy.isSafeLibraryChild(
            folderURL: folderURL,
            libraryRoot: PreferencesStore.shared.libraryRoot
        ) else {
            uninstallingIDs.remove(id)
            Log.write("uninstall: refused unsafe path \(folderURL.path)")
            showLocalRemovalFailure(
                title: title,
                subscriptionWasCancelled: subscriptionWasCancelled,
                error: WallpaperUninstallError.unsafePath
            )
            return
        }

        WorkshopDownloader.shared.remove(id: id)
        RenderedPreviewCache.shared.cancel(id)

        let wasCurrent = desktop.currentID == id
        let wasLastWallpaper = PreferencesStore.shared.lastWallpaperID == id
        if wasCurrent {
            clearCurrentWallpaper()
        } else if wasLastWallpaper {
            PreferencesStore.shared.lastWallpaperID = nil
        }

        do {
            try FileManager.default.trashItem(at: folderURL, resultingItemURL: nil)
            Log.write("uninstall: trashed \(id), steamCancelled=\(subscriptionWasCancelled)")
            uninstallingIDs.remove(id)
            library.scan()
        } catch {
            Log.write("uninstall: trash failed \(id): \(error)")
            uninstallingIDs.remove(id)
            if wasCurrent, let restoreItem {
                apply(restoreItem)
            } else if wasLastWallpaper {
                PreferencesStore.shared.lastWallpaperID = id
            }
            showLocalRemovalFailure(
                title: title,
                subscriptionWasCancelled: subscriptionWasCancelled,
                error: error
            )
        }
    }

    /// Steam 退订失败时默认保留本地文件；用户仍可明确选择“仅卸载本地”。
    private func showUnsubscribeFailure(_ item: WallpaperItem, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "未能取消 Steam 订阅"
        alert.informativeText = "\(message)\n\n为防止 Steam 自动重新下载，本地壁纸尚未删除。"
        alert.addButton(withTitle: "保留壁纸")
        alert.addButton(withTitle: "仅卸载本地")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn {
            requestUninstall(item, cancelSteamSubscription: false)
        }
    }

    private func showWebAuthorizationCancelled(_ item: WallpaperItem) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "未完成 Steam 网页授权"
        alert.informativeText =
            "设置中的 SteamCMD 下载账号仍然有效；订阅管理需要单独的 Steam 社区网页授权。\n\n授权窗口已关闭，因此没有取消订阅，也没有删除本地壁纸。"
        alert.addButton(withTitle: "保留壁纸")
        alert.addButton(withTitle: "仅卸载本地")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn {
            requestUninstall(item, cancelSteamSubscription: false)
        }
    }

    private func showLocalRemovalFailure(
        title: String,
        subscriptionWasCancelled: Bool,
        error: Error
    ) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "无法卸载「\(title)」"
        let prefix = subscriptionWasCancelled
            ? "Steam 订阅已取消，但本地文件夹没有移入废纸篓。"
            : "本地文件夹没有移入废纸篓。"
        alert.informativeText = "\(prefix)\n\n\(error.localizedDescription)"
        alert.addButton(withTitle: "知道了")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private enum WallpaperUninstallError: LocalizedError {
        case unsafePath

        var errorDescription: String? {
            switch self {
            case .unsafePath:
                return "目标不在当前壁纸库的直接子目录中，已为安全起见拒绝操作。请重新扫描壁纸库后再试。"
            }
        }
    }

    private func clearCurrentWallpaper() {
        desktop.clear()
        PreferencesStore.shared.lastWallpaperID = nil
        libraryWindow.updateCurrent(nil)
        updateStatusItemAppearance()
    }

    private func togglePause() {
        guard desktop.current != nil else { return }
        desktop.togglePause()
        updateStatusItemAppearance()
    }

    // MARK: - WE 风格状态栏菜单

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "photo.on.rectangle.angled",
            accessibilityDescription: "Live Wallpaper"
        )
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        updateStatusItemAppearance()
    }

    @objc private func statusItemClicked() {
        if let event = NSApp.currentEvent, event.type == .rightMouseUp,
           let button = statusItem.button {
            // 与 WE 一样：左键进入库，右键提供运行时快捷控制和程序入口。
            let menu = makeStatusMenu()
            // 直接用当前右键事件弹上下文菜单。旧实现“临时绑定 statusItem.menu → performClick
            // → 立刻解绑”在部分 macOS 版本会一闪即关；上下文菜单会自行完成事件跟踪，
            // 且不改变左键仍然打开主窗口的行为。
            NSMenu.popUpContextMenu(menu, with: event, for: button)
        } else {
            // 左键:直接打开主窗口
            openLibrary()
        }
    }

    private func makeStatusMenu() -> NSMenu {
        let state = TrayMenuPresentation(
            currentTitle: desktop.current?.title,
            isPaused: desktop.isPaused,
            isMuted: PreferencesStore.shared.isMuted,
            rotationEnabled: rotation.isEnabled,
            pendingDownloads: WorkshopDownloader.shared.pendingCount
        )
        let hasCurrent = desktop.current != nil
        let hasPlayableItems = library.items.contains { $0.type.isPlayable }
        let menu = NSMenu()

        let current = NSMenuItem(title: state.currentSummary, action: nil, keyEquivalent: "")
        current.isEnabled = false
        current.image = menuImage("photo.fill")
        menu.addItem(current)
        menu.addItem(.separator())

        menu.addItem(statusMenuItem("打开壁纸库与创意工坊…", symbol: "rectangle.grid.2x2",
                                    action: #selector(openLibrary)))
        menu.addItem(statusMenuItem("壁纸与应用设置…", symbol: "gearshape",
                                    action: #selector(openSettings)))
        menu.addItem(.separator())

        menu.addItem(statusMenuItem("下一张壁纸", symbol: "forward.end.fill",
                                    action: #selector(nextWallpaper), enabled: hasPlayableItems))
        menu.addItem(statusMenuItem(state.pauseTitle, symbol: state.pauseSymbol,
                                    action: #selector(togglePauseFromMenu), enabled: hasCurrent))
        menu.addItem(statusMenuItem(state.muteTitle, symbol: state.muteSymbol,
                                    action: #selector(toggleMuteFromMenu), enabled: hasCurrent))
        menu.addItem(statusMenuItem("停止壁纸", symbol: "stop.fill",
                                    action: #selector(stopWallpaperFromMenu), enabled: hasCurrent))

        menu.addItem(.separator())
        menu.addItem(statusMenuItem(state.rotationTitle, symbol: "repeat",
                                    action: #selector(toggleRotationFromMenu),
                                    state: state.rotationEnabled ? .on : .off))
        menu.addItem(statusMenuItem(state.downloadsTitle, symbol: "arrow.down.circle",
                                    action: #selector(openDownloads)))
        menu.addItem(statusMenuItem("我的 Steam 订阅…", symbol: "shippingbox",
                                    action: #selector(openSubscriptions)))

        menu.addItem(.separator())
        menu.addItem(statusMenuItem("开机启动", symbol: "power",
                                    action: #selector(toggleLoginItemFromMenu),
                                    state: LoginItem.isEnabled ? .on : .off))
        menu.addItem(.separator())
        menu.addItem(statusMenuItem("退出 Live Wallpaper", symbol: "xmark.circle",
                                    action: #selector(quit)))
        return menu
    }

    private func statusMenuItem(
        _ title: String,
        symbol: String,
        action: Selector,
        enabled: Bool = true,
        state: NSControl.StateValue = .off
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = enabled
        item.state = state
        item.image = menuImage(symbol)
        return item
    }

    private func menuImage(_ symbol: String) -> NSImage? {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        image?.size = NSSize(width: 15, height: 15)
        return image
    }

    private func updateStatusItemAppearance() {
        guard statusItem != nil else { return }
        let hasCurrent = desktop.current != nil
        let symbol = desktop.isPaused && hasCurrent
            ? "pause.circle"
            : (hasCurrent ? "photo.on.rectangle.angled" : "photo")
        statusItem.button?.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: "Live Wallpaper"
        )
        let stateText: String
        if let title = desktop.current?.title {
            stateText = desktop.isPaused ? "\(title)（已暂停）" : title
        } else {
            stateText = "未选择壁纸"
        }
        statusItem.button?.toolTip = "Live Wallpaper · \(stateText)"
    }

    @objc private func nextWallpaper() {
        rotation.advance()
        updateStatusItemAppearance()
    }

    @objc private func togglePauseFromMenu() {
        togglePause()
    }

    @objc private func toggleMuteFromMenu() {
        desktop.setMuted(!PreferencesStore.shared.isMuted)
        updateStatusItemAppearance()
    }

    @objc private func stopWallpaperFromMenu() {
        clearCurrentWallpaper()
    }

    @objc private func toggleRotationFromMenu() {
        rotation.setEnabled(!rotation.isEnabled)
        updateStatusItemAppearance()
    }

    @objc private func toggleLoginItemFromMenu() {
        _ = LoginItem.setEnabled(!LoginItem.isEnabled)
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

    private func apply(_ item: WallpaperItem, interactive: Bool = false) {
        // ⭐用户政策(2026-06-19):渲染壁纸时,pkg 能渲的全渲、**不能渲的弹窗指明**,方便纠错。
        //   受「设置 → 渲染缺口报错」开关控制(默认关,普通使用不打扰);**开启后每次交互切壁纸都弹**。
        // ⚠ 加载已改异步 → 必须等 onLoaded 回调再读缺口,否则 apply 返回时引擎还没加载完,
        //   currentRenderGaps() 恒为空 = 弹窗永远不出现(功能被静默废掉)。
        desktop.apply(item) { [weak self] in
            guard let self else { return }
            if interactive && PreferencesStore.shared.reportRenderGaps { self.showRenderGapsIfAny(item) }
        }
        libraryWindow.updateCurrent(item.id)
        updateStatusItemAppearance()
    }

    /// 加载后若有渲染缺口(没渲成功的项),弹窗列出。空=全渲成功,不弹。
    private func showRenderGapsIfAny(_ item: WallpaperItem) {
        let gaps = desktop.currentRenderGaps()
        guard !gaps.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "「\(item.title)」有 \(gaps.count) 项未能完全渲染"
        alert.informativeText = "其余内容已全部渲染。以下项目没有渲染成功(用于纠错,不影响其余画面):\n\n• "
            + gaps.joined(separator: "\n\n• ")
        alert.alertStyle = .warning
        alert.addButton(withTitle: "知道了")
        alert.addButton(withTitle: "复制清单")
        if alert.runModal() == .alertSecondButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("\(item.title) (\(item.id)) 渲染缺口:\n" + gaps.joined(separator: "\n"), forType: .string)
        }
    }

    @objc private func openLibrary() {
        libraryWindow.show(currentID: desktop.current?.id)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
