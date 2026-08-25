import SwiftUI

/// 主界面 —— 仿 WaifuX 设计语言:深色玻璃拟态 + 顶部居中标签栏(首页 / 壁纸库 / 创意工坊)+ 右上设置齿轮,
/// 首页大图轮播 + 横向货架,壁纸库用问候语 + 大标题 + 胶囊筛选 chips + 卡片网格。强制深色外观。
struct LibraryView: View {
    @ObservedObject var library: WallpaperLibrary
    var currentID: String?
    var actions: LibraryActions

    init(library: WallpaperLibrary, currentID: String?, actions: LibraryActions) {
        self.library = library
        self.currentID = currentID
        self.actions = actions
        // libraryWindow 在扫描完成后才构造视图；预览模式可在第一帧直接带出侧栏，避免截图时序竞争。
        _settingsItem = State(initialValue: WPEnv.vars["WP_PREVIEW_PANEL"] != nil ? library.items.first : nil)
    }

    /// 首页「创意工坊热门」在线货架数据源(浏览/推荐 Steam 工坊壁纸)。
    @ObservedObject private var workshopFeed = WorkshopFeed.shared

    enum Tab: String, CaseIterable, Identifiable {
        case home, library, workshop
        var id: String { rawValue }
        var title: String {
            switch self {
            case .home: return "首页"
            case .library: return "壁纸库"
            case .workshop: return "创意工坊"
            }
        }
        var icon: String {
            switch self {
            case .home: return "house"
            case .library: return "square.grid.2x2"
            case .workshop: return "bag"
            }
        }
    }

    @State private var tab: Tab = {
        if let t = WPEnv.vars["WP_PREVIEW_TAB"], let tab = Tab(rawValue: t) { return tab }
        return .home
    }()
    @State private var search = ""
    @State private var favVersion = 0
    @State private var settingsItem: WallpaperItem?    // 选中壁纸的检视面板
    @State private var showSettings =
        WPEnv.vars["WP_PREVIEW_SETTINGS"] != nil   // 设置 sheet

    // 壁纸库筛选:类型(nil=全部)、仅收藏、搜索、分级、排序、网格大小。
    @State private var typeFilter: WallpaperType? = nil
    @State private var favOnly = false

    enum GridSize: String, CaseIterable {
        case small, medium, large
        var title: String { switch self { case .small: return "小"; case .medium: return "中"; case .large: return "大" } }
        var icon: String { switch self { case .small: return "square.grid.3x3"; case .medium: return "square.grid.2x2"; case .large: return "square" } }
        var range: (min: CGFloat, max: CGFloat) { switch self { case .small: return (165, 220); case .medium: return (230, 320); case .large: return (320, 440) } }
    }
    @State private var gridSize = GridSize(rawValue: PreferencesStore.shared.gridSizeRaw) ?? .medium
    private var columns: [GridItem] {
        let r = gridSize.range
        return [GridItem(.adaptive(minimum: r.min, maximum: r.max), spacing: 18)]
    }

    enum SortKey: String, CaseIterable {
        case date, name, type, size
        var title: String {
            switch self {
            case .date: return "最新"
            case .name: return "名称"
            case .type: return "类型"
            case .size: return "大小"
            }
        }
    }
    @State private var sortKey = SortKey(rawValue: PreferencesStore.shared.sortKeyRaw) ?? .date
    @State private var sortDesc = PreferencesStore.shared.sortDescending

    @State private var selectedRatings: Set<ContentRating> =
        Set(PreferencesStore.shared.selectedRatings.compactMap { ContentRating(rawValue: $0) })

    private func ratingOK(_ item: WallpaperItem) -> Bool {
        let r: ContentRating = item.contentRating == .unknown ? .everyone : item.contentRating
        return selectedRatings.contains(r)
    }
    private var ratingFilteredItems: [WallpaperItem] { library.items.filter(ratingOK) }

    private var filtered: [WallpaperItem] {
        let fav = PreferencesStore.shared.favorites
        let matched = ratingFilteredItems.filter { item in
            (typeFilter == nil || item.type == typeFilter)
            && (!favOnly || fav.contains(item.id))
            && (search.isEmpty || item.title.localizedCaseInsensitiveContains(search))
        }
        return sorted(matched)
    }

    private func sorted(_ items: [WallpaperItem]) -> [WallpaperItem] {
        let asc: (WallpaperItem, WallpaperItem) -> Bool
        switch sortKey {
        case .type:
            asc = { a, b in
                if a.type != b.type { return a.type.sortOrder < b.type.sortOrder }
                return a.title.localizedStandardCompare(b.title) == .orderedAscending
            }
        case .name: asc = { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .date: asc = { $0.modifiedDate < $1.modifiedDate }
        case .size: asc = { $0.fileSize < $1.fileSize }
        }
        let s = items.sorted(by: asc)
        return sortDesc ? s.reversed() : s
    }

    private func toggleRating(_ r: ContentRating) {
        var s = selectedRatings
        if s.contains(r) { if s.count > 1 { s.remove(r) } } else { s.insert(r) }
        selectedRatings = s
        PreferencesStore.shared.selectedRatings = Set(s.map { $0.rawValue })
    }

    // MARK: - 根布局

    var body: some View {
        ZStack {
            WaifuTheme.background.ignoresSafeArea()
            // 首页:hero 大图铺到窗口最顶部,顶部标签栏浮在其上(半透明玻璃)。
            // 其余 tab:标签栏在上、内容在下(常规堆叠)。
            if tab == .home {
                ZStack(alignment: .top) {
                    contentRow
                    topBar.background(topBarGlass)
                }
            } else {
                VStack(spacing: 0) {
                    topBar
                    contentRow
                }
            }
        }
        .frame(minWidth: 1000, minHeight: 660)
        .preferredColorScheme(.dark)
        .onAppear {
            if WPEnv.vars["WP_PREVIEW_PANEL"] != nil, settingsItem == nil {
                settingsItem = filtered.first
            }
            // 截图验证用:WP_PREVIEW_SETTINGS 时自动打开设置窗口。
            if showSettings { NotificationCenter.default.post(name: .showSettings, object: nil); showSettings = false }
        }
        // UI 截图模式下库扫描可能晚于 onAppear 完成；首项出现时再打开一次侧栏，避免预览图漏掉面板。
        .onChange(of: filtered.first?.id) { _ in
            if WPEnv.vars["WP_PREVIEW_PANEL"] != nil, settingsItem == nil {
                settingsItem = filtered.first
            }
        }
    }

    /// 内容 + 右侧壁纸检视面板**并排**(面板不覆盖内容;选中壁纸时内容区自动变窄、网格重排)。
    private var contentRow: some View {
        HStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let item = settingsItem {
                Divider().overlay(Color.white.opacity(0.06))
                WallpaperSettingsPanel(
                    item: item,
                    onApply: { actions.onApplySettings(item) },
                    onClose: { withAnimation(.easeOut(duration: 0.22)) { settingsItem = nil } },
                    onUnsubscribe: WallpaperUninstallPolicy.isSteamWorkshopID(item.id) ? {
                        actions.onUnsubscribe(item); favVersion += 1
                        withAnimation(.easeOut(duration: 0.22)) { settingsItem = nil }
                    } : nil
                )
                .frame(width: 382)
                .transition(.move(edge: .trailing))
            }
        }
    }

    /// 首页标签栏浮在 hero 之上时的玻璃背景:顶部更暗的渐变 + 模糊,保证亮/暗 hero 上文字都可读。
    private var topBarGlass: some View {
        ZStack {
            LinearGradient(colors: [.black.opacity(0.55), .black.opacity(0.22), .clear],
                           startPoint: .top, endPoint: .bottom)
            Rectangle().fill(.ultraThinMaterial).opacity(0.35)
        }
        .allowsHitTesting(false)
        .ignoresSafeArea(edges: .top)
    }

    // MARK: - 顶部标签栏

    private var topBar: some View {
        HStack(spacing: 0) {
            Spacer().frame(width: 76)   // 留出红绿灯
            Spacer()
            HStack(spacing: 4) {
                ForEach(Tab.allCases) { t in tabButton(t) }
            }
            .padding(4)
            // 浮在 hero 之上时给胶囊更实的背景(玻璃)+ 阴影,保证亮图上也清晰。
            .background(Capsule().fill(tab == .home ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(Color.white.opacity(0.06))))
            .overlay(Capsule().strokeBorder(.white.opacity(0.10)))
            .shadow(color: .black.opacity(tab == .home ? 0.35 : 0), radius: 8, y: 2)
            Spacer()
            Button { NotificationCenter.default.post(name: .showSettings, object: nil) } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 36, height: 32)
                    .background(Circle().fill(tab == .home ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(Color.white.opacity(0.06))))
                    .shadow(color: .black.opacity(tab == .home ? 0.35 : 0), radius: 8, y: 2)
            }
            .buttonStyle(.plain).help("设置")
            .padding(.trailing, 16)
        }
        .frame(height: 50)
        .padding(.top, 8)
    }

    private func tabButton(_ t: Tab) -> some View {
        let on = tab == t
        return Button {
            withAnimation(.easeOut(duration: 0.18)) {
                tab = t
                if t != .library { settingsItem = nil }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: t.icon).font(.system(size: 12, weight: .semibold))
                Text(t.title).font(.system(size: 13.5, weight: .semibold))
            }
            .foregroundStyle(on ? .white : WaifuTheme.secondary)
            .padding(.horizontal, 16).padding(.vertical, 7)
            .background(Capsule().fill(on ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.clear)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 内容

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .home: homeView
        case .library: libraryBrowse
        case .workshop: WorkshopView().background(WaifuTheme.background)
        }
    }

    // MARK: - 首页(工坊壁纸:hero + 工坊货架 + 库入口)

    /// 「我的壁纸库」入口货架用:本地壁纸按最近添加排序。
    private var recentItems: [WallpaperItem] {
        ratingFilteredItems.sorted { $0.modifiedDate > $1.modifiedDate }
    }

    /// 首页主体 = **创意工坊壁纸**(浏览 Steam 工坊,而非用户自己的壁纸库)。
    /// 布局:hero = 工坊精选 6 张(大图轮播 + 玻璃缩略选择条)→ **「我的壁纸」首排**(本地库)→
    ///       工坊「本周最热」「评分最高」「最新」货架。
    /// 加载中显示骨架占位;全部失败/无网时优雅降级(给重试 + 回退到本地库内容)。
    private var homeView: some View {
        GeometryReader { geo in
            // full-bleed hero 高度:16:9 占满窗口宽度,但 hero 不超过窗口高度的 ~62%(留出下方货架),
            // 也不低于 320(小窗仍有存在感)。hero 内用 .fit 显示整张壁纸,留白处由同图虚化补底。
            let heroH = min(geo.size.width * 9.0 / 16.0, max(320, geo.size.height * 0.62))
            let picks = workshopFeed.heroItems(6)
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    if !picks.isEmpty {
                        // full-bleed 16:9 工坊 hero「6 张精选」轮播,铺到窗口最顶部(标签栏浮在其上)。
                        WorkshopHeroCarousel(items: picks,
                                             height: heroH,
                                             inLibrary: { workshopInLibrary($0) },
                                             onDownload: { startWorkshopDownload($0) })
                    } else if workshopFeed.isLoadingAny {
                        workshopHeroPlaceholder(height: heroH)
                    } else if workshopFeed.allFailed {
                        workshopUnavailableBanner
                            .padding(.horizontal, 26).padding(.top, 70)
                    }

                    // 「我的壁纸」首排(本地库,最近添加在前)—— 排在所有工坊货架之前(hero 之下第一排)。
                    if !recentItems.isEmpty { myLibraryShelf }

                    // 工坊「本周最热」「评分最高」「最新」货架(主内容)。
                    ForEach(WorkshopFeed.Sort.allCases, id: \.self) { sort in
                        workshopShelf(sort)
                    }
                }
                .padding(.bottom, 30)
                .id(favVersion)
            }
            .scrollIndicators(.hidden)
            .ignoresSafeArea(edges: .top)   // 让 hero 铺到窗口最顶部(标签栏浮于其上)
        }
        .onAppear { workshopFeed.loadHome(limit: 18) }
    }

    /// 单条工坊货架(热门 / 最新):远程缩略卡片,可横向滚动;点击 → 跳工坊 tab 看详情/订阅。
    /// 加载中显示骨架;失败且无数据时给「重试」入口(不静默空白)。
    @ViewBuilder
    private func workshopShelf(_ sort: WorkshopFeed.Sort) -> some View {
        let sec = workshopFeed.section(sort)
        if !sec.items.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                shelfHeader(sort)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 16) {
                        ForEach(sec.items) { item in
                            WorkshopCard(item: item,
                                         inLibrary: workshopInLibrary(item.id),
                                         onDownload: { startWorkshopDownload(item) })
                                .frame(width: 248)
                        }
                    }
                    .padding(.horizontal, 26)
                }
            }
        } else if sec.isLoading {
            workshopShelfPlaceholder(sort)
        } else if sec.failed {
            workshopShelfRetry(sort)
        }
    }

    /// 工坊货架标题行(图标 + 标题 + 「浏览全部」跳工坊 tab)。「浏览全部」做成玻璃胶囊。
    private func shelfHeader(_ sort: WorkshopFeed.Sort) -> some View {
        HStack(spacing: 6) {
            Image(systemName: sort.shelfIcon).font(.system(size: 13)).foregroundStyle(.orange)
            Text(sort.shelfTitle).font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
                .shadow(color: .black.opacity(0.4), radius: 4, y: 1)
            Spacer()
            Button { tab = .workshop } label: {
                HStack(spacing: 3) {
                    Text("浏览全部").font(.system(size: 12, weight: .medium))
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                }
                .foregroundStyle(WaifuTheme.secondary)
                .padding(.horizontal, 11).padding(.vertical, 6)
                .glassCapsule()
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 26)
    }

    /// 工坊货架加载占位(骨架卡片)。
    private func workshopShelfPlaceholder(_ sort: WorkshopFeed.Sort) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: sort.shelfIcon).font(.system(size: 13)).foregroundStyle(.orange)
                Text(sort.shelfTitle).font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
                ProgressView().controlSize(.small).scaleEffect(0.7)
                Spacer()
            }
            .padding(.horizontal, 26)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(0..<5, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(.white.opacity(0.05))
                            .aspectRatio(16.0/9.0, contentMode: .fit)
                            .frame(width: 248)
                    }
                }
                .padding(.horizontal, 26)
            }
        }
    }

    /// 工坊单货架失败时的「重试」行(无网/限流降级,不静默空白)。
    private func workshopShelfRetry(_ sort: WorkshopFeed.Sort) -> some View {
        HStack(spacing: 10) {
            Image(systemName: sort.shelfIcon).font(.system(size: 13)).foregroundStyle(.orange)
            Text(sort.shelfTitle).font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
            Text("加载失败").font(.system(size: 12)).foregroundStyle(WaifuTheme.tertiary)
            Spacer()
            Button { workshopFeed.loadIfNeeded(sort: sort, limit: 18, force: true) } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold))
                    Text("重试").font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(WaifuTheme.secondary)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .glassCapsule()
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 26)
    }

    /// hero 区加载骨架(full-bleed 大图占位,与正式 hero 同高同铺满)。
    private func workshopHeroPlaceholder(height: CGFloat) -> some View {
        Rectangle().fill(.white.opacity(0.05))
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .overlay(ProgressView().controlSize(.large))
    }

    /// 工坊整体不可用(全部区段失败/无网)时的降级横幅:提示 + 重试,不空白崩。
    private var workshopUnavailableBanner: some View {
        VStack(spacing: 10) {
            Image(systemName: "wifi.exclamationmark").font(.system(size: 34)).foregroundStyle(WaifuTheme.tertiary)
            Text("暂时无法加载创意工坊").font(.system(size: 16, weight: .semibold)).foregroundStyle(WaifuTheme.secondary)
            Text("检查网络后重试,或浏览下方「我的壁纸库」").font(.system(size: 12)).foregroundStyle(WaifuTheme.tertiary)
            HStack(spacing: 10) {
                Button { workshopFeed.loadHome(limit: 18, force: true) } label: {
                    Label("重试", systemImage: "arrow.clockwise")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 16).padding(.vertical, 9)
                        .background(Capsule().fill(Color.accentColor))
                }.buttonStyle(.plain)
                Button { tab = .library } label: {
                    Label("打开壁纸库", systemImage: "square.grid.2x2")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 16).padding(.vertical, 9)
                        .glassCapsule()
                }.buttonStyle(.plain)
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
        .glassCard(cornerRadius: 18)
    }

    /// 首页 hero 下第一排「我的壁纸」货架:展示用户自己壁纸库(最近添加在前),点击进详情/设为壁纸。
    private var myLibraryShelf: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "square.grid.2x2").font(.system(size: 13)).foregroundStyle(WaifuTheme.secondary)
                Text("我的壁纸").font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.4), radius: 4, y: 1)
                Text("\(ratingFilteredItems.count)").font(.system(size: 13, weight: .medium)).foregroundStyle(WaifuTheme.tertiary)
                Spacer()
                Button { tab = .library } label: {
                    HStack(spacing: 3) {
                        Text("全部").font(.system(size: 12, weight: .medium))
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                    }
                    .foregroundStyle(WaifuTheme.secondary)
                    .padding(.horizontal, 11).padding(.vertical, 6)
                    .glassCapsule()
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 26)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(Array(recentItems.prefix(14))) { item in
                        WallpaperCard(item: item, isCurrent: item.id == currentID,
                                      isFavorite: PreferencesStore.shared.isFavorite(item.id),
                                      onSelect: { selectAndConfigure(item) },
                                      onToggleFavorite: { PreferencesStore.shared.toggleFavorite(item.id); favVersion += 1 })
                            .frame(width: 248)
                            .contextMenu { cardMenu(item) }
                    }
                }
                .padding(.horizontal, 26)
            }
        }
    }

    private func workshopInLibrary(_ id: String) -> Bool {
        library.items.contains { $0.id == id } || LocalWallpaperProbe.isReady(
            at: PreferencesStore.shared.libraryRoot.appendingPathComponent(id, isDirectory: true)
        )
    }

    /// 点击工坊推荐卡片/hero:**直接在 app 内订阅 + 下载**该壁纸到本地库(不再跳转创意工坊网页 tab)。
    /// 走既有 SteamCMD 下载机制(WorkshopDownloader):enqueue 后内部用已配置的 Steam 账号(没配则匿名)
    /// 登录下载 → 完成移入壁纸库 → FolderWatcher 自动入库刷新。进度/已在库/失败由卡片自身的下载状态展示。
    /// 失败(无 SteamCMD / 未登录 Steam / 限流等)由 WorkshopDownloader 给出明确文案:
    ///   - 没装 SteamCMD:这里直接弹窗提示安装(下载根本无法进行)。
    ///   - 新发布壁纸需登录 Steam 账号:下载会失败并把 reason 写进 job.state(卡片上显示),
    ///     同时 downloader.loginExpired 置位 → 工坊页/下载管理弹「重新登录」。匿名能下的老壁纸正常完成。
    private func startWorkshopDownload(_ item: WorkshopFeed.Item) {
        // 已在库:无需下载,点击不跳转(保持在首页)。
        if workshopInLibrary(item.id) { return }
        guard WorkshopDownloader.shared.isAnyDownloadBackendAvailable else {
            let alert = NSAlert()
            alert.messageText = "没有可用的 Steam 下载后端"
            alert.informativeText = "请先运行当前壁纸库对应的 CrossOver Steam，或在终端安装 SteamCMD：\nbrew install --cask steamcmd"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "好")
            alert.runModal()
            return
        }
        // 立即入队并开始下载(尺寸只用于进度估算,这里拿不到精确大小传 0,不影响下载与块进度)。
        WorkshopAcquisition.start(id: item.id, title: item.title)
    }

    // MARK: - 壁纸库(问候语 + 大标题 + 胶囊筛选 + 网格)

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        switch h {
        case 5..<12: return "早上好"
        case 12..<18: return "下午好"
        case 18..<23: return "晚上好"
        default: return "夜深了"
        }
    }

    private var libraryBrowse: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // 问候 + 大标题
                VStack(alignment: .leading, spacing: 4) {
                    Text(greeting).font(.system(size: 13, weight: .medium)).foregroundStyle(WaifuTheme.tertiary)
                    Text("探索壁纸库").font(.system(size: 28, weight: .bold)).foregroundStyle(.white)
                }
                searchBar
                // 类型筛选 chips
                filterGroup("类型") {
                    chip("全部", icon: "square.grid.2x2", on: typeFilter == nil) { typeFilter = nil }
                    ForEach([WallpaperType.scene, .video, .web], id: \.self) { t in
                        chip(t.displayName, icon: typeIcon(t), on: typeFilter == t) { typeFilter = (typeFilter == t ? nil : t) }
                    }
                    chip("收藏", icon: "heart.fill", on: favOnly) { favOnly.toggle() }
                }
                // 分级 chips
                filterGroup("内容分级") {
                    ForEach([ContentRating.everyone, .questionable, .mature], id: \.self) { r in
                        chip(r.displayName, icon: ratingIcon(r), on: selectedRatings.contains(r)) { toggleRating(r) }
                    }
                }
                // 数量 + 排序
                HStack {
                    Text("\(filtered.count) 张壁纸").font(.system(size: 13, weight: .medium)).foregroundStyle(WaifuTheme.secondary)
                    Spacer()
                    gridSizeControl
                    sortMenu
                }
                .padding(.top, 2)

                if library.items.isEmpty { emptyState }
                else if filtered.isEmpty { noResultsState }
                else {
                    LazyVGrid(columns: columns, spacing: 18) {
                        ForEach(filtered) { item in
                            WallpaperCard(item: item, isCurrent: item.id == currentID,
                                          isFavorite: PreferencesStore.shared.isFavorite(item.id),
                                          onSelect: { selectAndConfigure(item) },
                                          onToggleFavorite: { PreferencesStore.shared.toggleFavorite(item.id); favVersion += 1 })
                                .contextMenu { cardMenu(item) }
                        }
                    }
                    .id(favVersion)
                }
            }
            .padding(.horizontal, 26).padding(.top, 10).padding(.bottom, 30)
            .trackScrollOffset()
        }
        .scrollIndicators(.hidden)
        .floatingScrollIndicator()
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(WaifuTheme.tertiary)
            TextField("搜索壁纸…", text: $search)
                .textFieldStyle(.plain).font(.system(size: 13.5)).foregroundStyle(.white)
            if !search.isEmpty {
                Button { search = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 13)).foregroundStyle(WaifuTheme.tertiary)
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(.ultraThinMaterial))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(.white.opacity(0.10)))
        .frame(maxWidth: 520)
    }

    /// 筛选分组:小标题 + 一行 chips。
    @ViewBuilder
    private func filterGroup<C: View>(_ title: String, @ViewBuilder _ chips: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(WaifuTheme.tertiary)
            HStack(spacing: 8) { chips() }
        }
    }

    /// 胶囊筛选 chip(选中=强调色填充;未选=玻璃 material 托底)。
    private func chip(_ title: String, icon: String, on: Bool, _ act: @escaping () -> Void) -> some View {
        Button { withAnimation(.easeOut(duration: 0.15)) { act() } } label: {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                Text(title).font(.system(size: 12.5, weight: .medium))
            }
            .foregroundStyle(on ? .white : WaifuTheme.secondary)
            .padding(.horizontal, 13).padding(.vertical, 7)
            .background(Capsule().fill(on ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.ultraThinMaterial)))
            .overlay(Capsule().strokeBorder(.white.opacity(on ? 0 : 0.10)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var gridSizeControl: some View {
        HStack(spacing: 2) {
            ForEach(GridSize.allCases, id: \.self) { sz in
                let on = gridSize == sz
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { gridSize = sz }
                    PreferencesStore.shared.gridSizeRaw = sz.rawValue
                } label: {
                    Image(systemName: sz.icon).font(.system(size: 12, weight: on ? .semibold : .regular))
                        .frame(width: 28, height: 24)
                        .foregroundStyle(on ? .white : WaifuTheme.secondary)
                        .background(RoundedRectangle(cornerRadius: 7).fill(on ? Color.accentColor.opacity(0.9) : .clear))
                }
                .buttonStyle(.plain).help("\(sz.title)图标")
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 9).fill(.ultraThinMaterial))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.white.opacity(0.08)))
    }

    private var sortMenu: some View {
        Menu {
            Picker("排序", selection: Binding(get: { sortKey }, set: { sortKey = $0; PreferencesStore.shared.sortKeyRaw = $0.rawValue })) {
                ForEach(SortKey.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Divider()
            Picker("顺序", selection: Binding(get: { sortDesc }, set: { sortDesc = $0; PreferencesStore.shared.sortDescending = $0 })) {
                Text("降序").tag(true); Text("升序").tag(false)
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.up.arrow.down").font(.system(size: 11))
                Text(sortKey.title).font(.system(size: 12.5, weight: .medium))
            }
            .foregroundStyle(WaifuTheme.secondary)
            .padding(.horizontal, 11).padding(.vertical, 7)
            .background(Capsule().fill(.ultraThinMaterial))
            .overlay(Capsule().strokeBorder(.white.opacity(0.08)))
        }
        .menuStyle(.borderlessButton).fixedSize()
    }

    // MARK: - 辅助

    private func typeIcon(_ t: WallpaperType) -> String {
        switch t { case .video: return "film"; case .scene: return "sparkles"; case .web: return "globe"; default: return "questionmark" }
    }
    private func ratingIcon(_ r: ContentRating) -> String {
        switch r { case .everyone: return "person"; case .questionable: return "exclamationmark.shield"; case .mature: return "18.circle"; case .unknown: return "questionmark" }
    }

    private func selectAndConfigure(_ item: WallpaperItem) {
        actions.onSelect(item)
        withAnimation(.easeOut(duration: 0.22)) { settingsItem = item }
    }

    @ViewBuilder
    private func cardMenu(_ item: WallpaperItem) -> some View {
        Button { selectAndConfigure(item) } label: { Label("设为壁纸", systemImage: "play.fill") }
        Button { withAnimation(.easeOut(duration: 0.22)) { settingsItem = item } } label: { Label("壁纸设置…", systemImage: "slider.horizontal.3") }
        Button {
            PreferencesStore.shared.toggleFavorite(item.id); favVersion += 1
        } label: {
            Label(PreferencesStore.shared.isFavorite(item.id) ? "取消收藏" : "收藏",
                  systemImage: PreferencesStore.shared.isFavorite(item.id) ? "heart.slash" : "heart")
        }
        Button { NSWorkspace.shared.activateFileViewerSelecting([item.folderURL]) } label: { Label("在访达中显示", systemImage: "folder") }
        Divider()
        if WallpaperUninstallPolicy.isSteamWorkshopID(item.id) {
            Button(role: .destructive) {
                // 删除动作不再弹确认框；右键即执行。Steam 工坊项目仍由 onUnsubscribe
                // 先同步退订，成功后再清理本地文件，失败时保留本地壁纸。
                actions.onUnsubscribe(item)
                favVersion += 1
            } label: {
                Label("卸载（同时同步订阅）", systemImage: "trash")
            }
        } else {
            Button(role: .destructive) {
                // 本地壁纸右键直接移入废纸篓，不再打断操作询问。
                actions.onDelete(item)
                favVersion += 1
            } label: {
                Label("卸载本地壁纸", systemImage: "trash")
            }
        }
    }

    private var emptyState: some View {
        EmptyStateView(label: library.isScanning ? "正在扫描壁纸…" : "没找到壁纸",
                       systemImage: library.isScanning ? "hourglass" : "tray",
                       description: library.rootURL.path)
            .frame(height: 320)
    }
    private var noResultsState: some View {
        EmptyStateView(label: favOnly ? "还没有收藏" : "没有匹配的壁纸",
                       systemImage: favOnly ? "heart.slash" : "magnifyingglass",
                       description: favOnly ? "把喜欢的壁纸点上 ♥,这里就会出现" : "试试别的筛选或搜索词")
            .frame(height: 320)
    }
}

/// WaifuX 风深色玻璃配色 token。
enum WaifuTheme {
    static let background = LinearGradient(colors: [Color(white: 0.10), Color(white: 0.06)],
                                           startPoint: .top, endPoint: .bottom)
    static let secondary = Color.white.opacity(0.62)
    static let tertiary = Color.white.opacity(0.40)
    static let card = Color.white.opacity(0.06)
    /// 玻璃描边(白 ~10% 透明的细 hairline)。
    static let glassStroke = Color.white.opacity(0.10)
    static let glassStrokeStrong = Color.white.opacity(0.14)
}

// MARK: - 玻璃质感修饰符(frosted glass)
//
// 统一首页/货架的玻璃视觉:material 模糊托底 + 圆角 + 细描边(白 ~10%)+ 柔和阴影。
// 深色背景下文字另行提白加阴影(各处文字已 .foregroundStyle(.white) + shadow)。

extension View {
    /// 玻璃**卡片**:圆角矩形 material 托底 + hairline 描边 + 柔和阴影(用于 hero 标题卡、区块头等)。
    func glassCard(cornerRadius: CGFloat = 16,
                   material: Material = .ultraThinMaterial,
                   strong: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .background(shape.fill(material))
            .overlay(shape.strokeBorder(strong ? WaifuTheme.glassStrokeStrong : WaifuTheme.glassStroke, lineWidth: 1))
            .clipShape(shape)
            .shadow(color: .black.opacity(0.32), radius: 14, y: 6)
    }

    /// 玻璃**胶囊**:Capsule material 托底 + hairline 描边 + 阴影(用于角标、状态胶囊等)。
    func glassCapsule(material: Material = .ultraThinMaterial) -> some View {
        self
            .background(Capsule().fill(material))
            .overlay(Capsule().strokeBorder(WaifuTheme.glassStroke, lineWidth: 1))
            .clipShape(Capsule())
            .shadow(color: .black.opacity(0.28), radius: 8, y: 3)
    }
}

/// 首页 hero「6 张精选」轮播:full-bleed 大图区展示当前选中的精选(复用 `WorkshopHero` 的完整壁纸 +
/// 玻璃质感 + 直接下载),底部右侧浮一条**玻璃缩略选择条**(6 张精选),点选切换大图 / 自动每 6 秒轮播;
/// 下方一排玻璃圆点指示当前页。点击大图或「下载」按钮 → 直接下载当前精选(沿用 WorkshopHero 逻辑)。
struct WorkshopHeroCarousel: View {
    let items: [WorkshopFeed.Item]
    var height: CGFloat
    var inLibrary: (String) -> Bool
    var onDownload: (WorkshopFeed.Item) -> Void

    @State private var index = 0
    // 自动轮播:每 6 秒前进一张(用户点选缩略图会切到该张,计时继续)。
    private let autoAdvance = Timer.publish(every: 6, on: .main, in: .common).autoconnect()

    private var current: WorkshopFeed.Item { items[min(index, items.count - 1)] }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            // 大图区:当前精选(按 id 切换 → 干净换图 + 渐隐过渡)。完整 16:9 + 玻璃 + 直接下载全在 WorkshopHero。
            WorkshopHero(item: current,
                         inLibrary: inLibrary(current.id),
                         height: height,
                         onDownload: { onDownload(current) })
                .id(current.id)
                .transition(.opacity)

            // 底部右侧:玻璃缩略选择条 + 圆点指示(避开左下标题卡)。
            VStack(alignment: .trailing, spacing: 8) {
                heroThumbStrip
                heroDots
            }
            .padding(.trailing, 36).padding(.bottom, 30)
            .allowsHitTesting(true)
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .clipped()
        .onReceive(autoAdvance) { _ in
            guard items.count > 1 else { return }
            withAnimation(.easeInOut(duration: 0.45)) { index = (index + 1) % items.count }
        }
        .onChange(of: items.count) { _ in if index >= items.count { index = 0 } }
    }

    /// 玻璃缩略选择条:6 张精选小图,点选切换大图;当前张高亮描边。
    private var heroThumbStrip: some View {
        HStack(spacing: 8) {
            ForEach(Array(items.enumerated()), id: \.element.id) { i, it in
                HeroThumbChip(item: it, selected: i == index)
                    .onTapGesture { withAnimation(.easeInOut(duration: 0.4)) { index = i } }
            }
        }
        .padding(6)
        .glassCard(cornerRadius: 14)
    }

    /// 圆点页码指示(当前页强调色填充)。
    private var heroDots: some View {
        HStack(spacing: 6) {
            ForEach(items.indices, id: \.self) { i in
                Capsule()
                    .fill(i == index ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.white.opacity(0.35)))
                    .frame(width: i == index ? 16 : 6, height: 6)
                    .animation(.easeInOut(duration: 0.3), value: index)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .glassCapsule()
    }
}

/// 轮播缩略选择条里的单个小图(完整 16:9 缩略图 + 选中态描边/缩放)。远程缩略图异步加载。
struct HeroThumbChip: View {
    let item: WorkshopFeed.Item
    var selected: Bool
    @State private var thumb: NSImage?
    @State private var hovering = false

    var body: some View {
        CompleteThumb(image: thumb)
            .frame(width: 64, height: 36)   // 16:9
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(selected ? AnyShapeStyle(Color.accentColor)
                                           : AnyShapeStyle(Color.white.opacity(hovering ? 0.4 : 0.12)),
                                  lineWidth: selected ? 2 : 1)
            )
            .scaleEffect(selected ? 1.08 : (hovering ? 1.04 : 1.0))
            .shadow(color: .black.opacity(selected ? 0.4 : 0.2), radius: selected ? 8 : 4, y: 2)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: selected)
            .animation(.easeOut(duration: 0.15), value: hovering)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .help(item.title)
            .onAppear {
                guard thumb == nil else { return }
                ThumbnailCache.shared.remoteThumbnail(for: item.previewURL) { img in self.thumb = img }
            }
    }
}

/// 首页**工坊**大图 hero:工坊热门第一张做大预览 + 标题 + 「下载」按钮。
/// **full-bleed + 完整壁纸**:占满窗口宽度、铺到窗口最顶部(标签栏浮于其上);16:9 框内用 `.fit` 显示
/// **整张**壁纸(不裁人物/边缘),框内非 16:9 的留白处用同图虚化放大 + 玻璃暗化补底(无死黑边)。
/// 标题/下载按钮/来源角标用玻璃卡片浮在上面。远程缩略图(CDN)异步加载。
/// 点击整块或「下载」按钮 → **直接在 app 内订阅 + SteamCMD 下载**(不再跳转创意工坊网页 tab)。
struct WorkshopHero: View {
    let item: WorkshopFeed.Item
    var inLibrary: Bool
    var height: CGFloat
    var onDownload: () -> Void

    @ObservedObject private var downloader = WorkshopDownloader.shared
    @State private var thumb: NSImage?

    /// 该 hero 对应的下载任务(若正在下/排队/失败,卡片据此显示进度/失败)。
    private var job: WorkshopDownloader.Job? { downloader.jobs.first { $0.id == item.id } }

    var body: some View {
        ZStack {
            // ① 虚化放大的同图铺满做底(玻璃高级感,避免 fit 留死黑边)。
            if let thumb {
                Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity)
                    .frame(height: height)
                    .clipped()
                    .blur(radius: 40)
                    .opacity(0.55)
                    .overlay(Color.black.opacity(0.28))   // 玻璃暗化,统一压暗虚化底
            } else {
                Rectangle().fill(.white.opacity(0.06))
                    .frame(maxWidth: .infinity).frame(height: height)
            }

            // ② 完整壁纸(16:9 框内 .fit,整张图都在、不裁人物/边缘)。
            if let thumb {
                Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .frame(height: height)
            } else {
                ProgressView().controlSize(.large)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .clipped()
        .overlay {   // 暗化渐变(左 + 下),保证标题/标签栏文字可读
            ZStack {
                LinearGradient(colors: [.black.opacity(0.62), .black.opacity(0.10), .clear],
                               startPoint: .leading, endPoint: .trailing)
                LinearGradient(colors: [.clear, .black.opacity(0.18), .black.opacity(0.58)],
                               startPoint: .center, endPoint: .bottom)
            }
            .allowsHitTesting(false)
        }
        .overlay(alignment: .topLeading) {
            // 「创意工坊」来源角标 —— 玻璃胶囊托底(下移避开浮动标签栏)。
            HStack(spacing: 5) {
                Image(systemName: "flame.fill").font(.system(size: 10, weight: .bold)).foregroundStyle(.orange)
                Text("创意工坊热门").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
            }
            .padding(.horizontal, 11).padding(.vertical, 6)
            .glassCapsule()
            .padding(.leading, 28).padding(.top, 64)
        }
        .overlay(alignment: .bottomLeading) {
            // 标题 + 下载按钮 —— 玻璃卡片浮在完整壁纸上。
            VStack(alignment: .leading, spacing: 14) {
                Text(item.title).font(.system(size: 38, weight: .bold)).foregroundStyle(.white)
                    .lineLimit(2).shadow(color: .black.opacity(0.7), radius: 10, y: 2)
                heroActionButton
            }
            .padding(.horizontal, 22).padding(.vertical, 18)
            .glassCard(cornerRadius: 22)
            .padding(36)
        }
        .overlay(alignment: .top) {
            Rectangle().strokeBorder(.white.opacity(0.06), lineWidth: 1).allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .onTapGesture { if !inLibrary { onDownload() } }
        .onAppear {
            guard thumb == nil else { return }
            ThumbnailCache.shared.remoteThumbnail(for: item.previewURL) { img in self.thumb = img }
        }
    }

    /// hero 行动按钮:已在库=绿标;下载中=进度;失败=可重试;否则「下载」。
    @ViewBuilder
    private var heroActionButton: some View {
        if inLibrary {
            heroPill("已在库", icon: "checkmark.circle.fill", bg: AnyShapeStyle(.ultraThinMaterial))
        } else if let job, WorkshopDownloader.isActive(job.state) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).scaleEffect(0.8).tint(.white)
                Text(job.state == .downloading && job.phase != .installing
                     ? "下载 \(job.compactStatus)"
                     : job.compactStatus)
                    .font(.system(size: 13, weight: .semibold).monospacedDigit()).foregroundStyle(.white)
            }
            .padding(.horizontal, 18).padding(.vertical, 10)
            .glassCapsule()
        } else if let job, case .failed(let reason) = job.state {
            Button(action: onDownload) {
                heroPill(reason.count > 16 ? "下载失败 · 重试" : "重试", icon: "arrow.clockwise", bg: AnyShapeStyle(Color.red.opacity(0.75)))
            }.buttonStyle(.plain).help(reason)
        } else {
            Button(action: onDownload) {
                heroPill("下载", icon: "arrow.down.circle.fill", bg: AnyShapeStyle(Color.accentColor))
            }
            .buttonStyle(.plain)
            .disabled(!downloader.isAnyDownloadBackendAvailable)
            .help(downloader.isAnyDownloadBackendAvailable
                  ? "优先使用 Steam 客户端，必要时回退 SteamCMD"
                  : "未运行对应 Steam 客户端，且未安装 SteamCMD")
        }
    }

    private func heroPill(_ text: String, icon: String, bg: AnyShapeStyle) -> some View {
        Label(text, systemImage: icon)
            .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
            .padding(.horizontal, 18).padding(.vertical, 10)
            .background(Capsule().fill(bg))
            .overlay(Capsule().strokeBorder(.white.opacity(0.16)))
            .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
    }
}

func sizeText(_ bytes: Int64) -> String {
    if bytes <= 0 { return "—" }
    let mb = Double(bytes) / 1_048_576
    if mb >= 1024 { return String(format: "%.1f GB", mb / 1024) }
    if mb >= 1 { return String(format: "%.0f MB", mb) }
    return String(format: "%.0f KB", Double(bytes) / 1024)
}

/// 占位空态。
struct EmptyStateView: View {
    let label: String
    let systemImage: String
    var description: String? = nil
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage).font(.system(size: 38)).foregroundStyle(WaifuTheme.tertiary)
            Text(label).font(.title3.weight(.semibold)).foregroundStyle(WaifuTheme.secondary)
            if let description {
                Text(description).font(.callout).foregroundStyle(WaifuTheme.tertiary)
                    .multilineTextAlignment(.center).lineLimit(2).padding(.horizontal, 40)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 完整缩略图:在框内显示**整张**图(.fit,不裁人物/边缘),两侧/上下用同图虚化放大补底(玻璃暗化),
/// 无图时显示占位骨架 + 进度。用于货架卡片(WallpaperCard / WorkshopCard)。
struct CompleteThumb: View {
    let image: NSImage?
    var body: some View {
        ZStack {
            if let image {
                // 同图虚化放大铺满做底(避免 fit 留死黑边)。
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    .blur(radius: 18)
                    .overlay(Color.black.opacity(0.25))
                // 完整图(.fit,整张都在)。
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                Rectangle().fill(.white.opacity(0.05))
                ProgressView().controlSize(.small)
            }
        }
    }
}

/// 壁纸卡片(WaifuX 风:连续圆角 + 类型/大小角标 + 悬停放大 + 渐变标题)。
struct WallpaperCard: View {
    let item: WallpaperItem
    var isCurrent: Bool
    var isFavorite: Bool
    var onSelect: () -> Void
    var onToggleFavorite: () -> Void

    @State private var thumb: NSImage?
    @State private var hovering = false

    var body: some View {
        ZStack {
            // 16:9 卡框内显示**完整**缩略图(.fit),两侧/上下用同图虚化做底,避免死黑边。
            CompleteThumb(image: thumb)
                .frame(maxWidth: .infinity)
                .aspectRatio(16.0/9.0, contentMode: .fit)
                .clipped()

            VStack {
                Spacer()
                HStack {
                    Text(item.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                        .lineLimit(1).shadow(color: .black.opacity(0.5), radius: 3, y: 1)
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.bottom, 9).padding(.top, 30)
                .background(LinearGradient(colors: [.clear, .black.opacity(0.35), .black.opacity(0.82)],
                                           startPoint: .top, endPoint: .bottom))
            }

            if hovering {
                Image(systemName: "play.circle.fill").font(.system(size: 42))
                    .foregroundStyle(.white.opacity(0.95)).shadow(radius: 6)
                    .transition(.scale.combined(with: .opacity))
            }

            VStack {
                HStack(alignment: .top) {
                    TypeBadge(type: item.type)
                    Spacer()
                    if isFavorite || hovering {
                        Button(action: onToggleFavorite) {
                            Image(systemName: isFavorite ? "heart.fill" : "heart")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(isFavorite ? .pink : .white)
                                .padding(6).background(.black.opacity(0.4), in: Circle())
                        }.buttonStyle(.plain)
                    }
                }
                Spacer()
                HStack {
                    if isCurrent {
                        HStack(spacing: 4) {
                            Circle().fill(.green).frame(width: 6, height: 6)
                            Text("播放中").font(.system(size: 10, weight: .bold))
                        }
                        .foregroundStyle(.white).padding(.horizontal, 7).padding(.vertical, 3)
                        .background(.black.opacity(0.5), in: Capsule())
                    }
                    Spacer()
                }
            }
            .padding(8)
        }
        .frame(maxWidth: .infinity)
        .background(Color.black.opacity(0.001))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        // 悬停时上缘玻璃高光,呼应 frosted glass。
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(LinearGradient(colors: [.white.opacity(hovering ? 0.14 : 0), .clear],
                                     startPoint: .top, endPoint: .center))
                .allowsHitTesting(false)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(
                isCurrent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.white.opacity(hovering ? 0.16 : 0.08)),
                lineWidth: isCurrent ? 3 : 1)
        )
        .shadow(color: .black.opacity(hovering ? 0.38 : 0.20), radius: hovering ? 18 : 9, y: hovering ? 10 : 4)
        .shadow(color: isCurrent ? Color.accentColor.opacity(0.45) : .clear, radius: 10)
        .scaleEffect(hovering ? 1.03 : 1.0)
        .animation(.spring(response: 0.32, dampingFraction: 0.72), value: hovering)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
        .onAppear {
            guard thumb == nil, let url = item.previewURL else { return }
            // 先取本地 preview(快,绝大多数卡片到此为止)。
            ThumbnailCache.shared.thumbnail(for: url) { img in
                self.thumb = img
                // 仅当:scene 类型 + 取到的本地 preview 首帧近全黑(开场动画类壁纸的 preview.gif 首帧是黑幕)
                // → 回退用引擎离屏渲染图(惰性 + 磁盘缓存,且仅库窗口可见时才渲)。
                // 非黑卡片 / video / web 不触发,避免全量渲染拖慢、烧 GPU。
                guard item.type == .scene,
                      let img, ThumbnailCache.shared.isNearBlack(img) else { return }
                RenderedPreviewCache.shared.image(for: item) { rendered in
                    if let rendered { self.thumb = rendered }
                }
            }
        }
        // 卡片滚出视口(LazyVGrid 回收):撤销尚未开始的离屏渲染请求,
        // 避免快速滚动时把整库的近黑场景卡片都排进渲染队列烧 GPU。
        .onDisappear { RenderedPreviewCache.shared.cancel(item.id) }
    }
}

/// 创意工坊在线推荐卡片(首页货架用):远程缩略图 + 标题 + 「热门」/「在库」/「下载中」角标。
/// 点击 → **直接在 app 内订阅 + SteamCMD 下载**到壁纸库(不再跳转工坊网页)。视觉与 WallpaperCard 一致。
struct WorkshopCard: View {
    let item: WorkshopFeed.Item
    var inLibrary: Bool
    var onDownload: () -> Void

    @ObservedObject private var downloader = WorkshopDownloader.shared
    @State private var thumb: NSImage?
    @State private var hovering = false

    private var job: WorkshopDownloader.Job? { downloader.jobs.first { $0.id == item.id } }
    private var isDownloading: Bool { job.map { WorkshopDownloader.isActive($0.state) } ?? false }
    private var failedReason: String? {
        if let job, case .failed(let r) = job.state { return r }; return nil
    }

    var body: some View {
        ZStack {
            // 16:9 卡框内显示**完整**缩略图(.fit),两侧/上下用同图虚化做底,避免死黑边。
            CompleteThumb(image: thumb)
                .frame(maxWidth: .infinity)
                .aspectRatio(16.0/9.0, contentMode: .fit)
                .clipped()

            VStack {
                Spacer()
                HStack {
                    Text(item.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                        .lineLimit(1).shadow(color: .black.opacity(0.5), radius: 3, y: 1)
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.bottom, 9).padding(.top, 30)
                .background(LinearGradient(colors: [.clear, .black.opacity(0.35), .black.opacity(0.82)],
                                           startPoint: .top, endPoint: .bottom))
            }

            // 悬停时中心图标:已在库=√、下载中=进度、其余=下载箭头。
            if hovering || isDownloading {
                if isDownloading {
                    VStack(spacing: 4) {
                        ProgressView().controlSize(.small).tint(.white)
                        if let job {
                            Text(job.compactStatus)
                                .font(.system(size: 11, weight: .bold).monospacedDigit()).foregroundStyle(.white)
                        }
                    }
                    .padding(12).background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
                    .transition(.scale.combined(with: .opacity))
                } else {
                    Image(systemName: inLibrary ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                        .font(.system(size: 42))
                        .foregroundStyle(.white.opacity(0.95)).shadow(radius: 6)
                        .transition(.scale.combined(with: .opacity))
                }
            }

            VStack {
                HStack(alignment: .top) {
                    // 「热门工坊」角标
                    HStack(spacing: 3) {
                        Image(systemName: "flame.fill").font(.system(size: 8, weight: .bold))
                        Text("工坊").font(.system(size: 10, weight: .bold))
                    }
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Color.orange.opacity(0.92), in: Capsule())
                    .foregroundStyle(.white)
                    Spacer()
                    statusBadge
                }
                Spacer()
            }
            .padding(8)
        }
        .frame(maxWidth: .infinity)
        .background(Color.black.opacity(0.001))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        // 悬停时上缘玻璃高光,呼应 frosted glass。
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(LinearGradient(colors: [.white.opacity(hovering ? 0.14 : 0), .clear],
                                     startPoint: .top, endPoint: .center))
                .allowsHitTesting(false)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(hovering ? 0.16 : 0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(hovering ? 0.38 : 0.20), radius: hovering ? 18 : 9, y: hovering ? 10 : 4)
        .scaleEffect(hovering ? 1.03 : 1.0)
        .animation(.spring(response: 0.32, dampingFraction: 0.72), value: hovering)
        .contentShape(Rectangle())
        .onTapGesture { if !inLibrary && !isDownloading { onDownload() } }
        .onHover { hovering = $0 }
        .help(helpText)
        .onAppear {
            guard thumb == nil else { return }
            ThumbnailCache.shared.remoteThumbnail(for: item.previewURL) { img in self.thumb = img }
        }
    }

    /// 右上角状态角标:已在库 / 下载中 % / 失败。
    @ViewBuilder
    private var statusBadge: some View {
        if inLibrary {
            badge("已在库", icon: "checkmark", color: .green)
        } else if isDownloading {
            badge(job?.compactStatus ?? "下载中", icon: "arrow.down", color: .accentColor)
        } else if failedReason != nil {
            badge("失败", icon: "exclamationmark", color: .red)
        }
    }

    private func badge(_ text: String, icon: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 8, weight: .bold))
            Text(text).font(.system(size: 10, weight: .bold).monospacedDigit())
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(color.opacity(0.85), in: Capsule())
        .foregroundStyle(.white)
    }

    private var helpText: String {
        if inLibrary { return "已在壁纸库中" }
        if isDownloading { return job?.compactStatus ?? "下载中…" }
        if let r = failedReason { return "下载失败:\(r)(点击重试)" }
        return downloader.isAnyDownloadBackendAvailable
            ? "点击订阅并下载到壁纸库"
            : "未运行对应 Steam 客户端，且未安装 SteamCMD"
    }
}

struct TypeBadge: View {
    let type: WallpaperType
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 8, weight: .bold))
            Text(type.displayName).font(.system(size: 10, weight: .bold))
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(color.opacity(0.92), in: Capsule())
        .foregroundStyle(.white)
    }
    private var icon: String {
        switch type { case .video: return "film.fill"; case .scene: return "sparkles"; case .web: return "globe"; default: return "questionmark" }
    }
    private var color: Color {
        switch type { case .video: return .blue; case .scene: return .purple; case .web: return .green; default: return .gray }
    }
}
