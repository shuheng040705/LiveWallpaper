import SwiftUI

/// 主界面 —— 仿 WaifuX 设计语言:深色玻璃拟态 + 顶部居中标签栏(首页 / 壁纸库 / 创意工坊)+ 右上设置齿轮,
/// 首页大图轮播 + 横向货架,壁纸库用问候语 + 大标题 + 胶囊筛选 chips + 卡片网格。强制深色外观。
struct LibraryView: View {
    @ObservedObject var library: WallpaperLibrary
    var currentID: String?
    var actions: LibraryActions

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
        if let t = ProcessInfo.processInfo.environment["WP_PREVIEW_TAB"], let tab = Tab(rawValue: t) { return tab }
        return .home
    }()
    @State private var search = ""
    @State private var favVersion = 0
    @State private var settingsItem: WallpaperItem?    // 选中壁纸的检视面板
    @State private var showSettings =
        ProcessInfo.processInfo.environment["WP_PREVIEW_SETTINGS"] != nil   // 设置 sheet
    @State private var heroIndex = 0

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
            VStack(spacing: 0) {
                topBar
                // 内容 + 右侧壁纸检视面板**并排**(面板不覆盖内容;选中壁纸时内容区自动变窄、网格重排)。
                HStack(spacing: 0) {
                    content
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if let item = settingsItem {
                        Divider().overlay(Color.white.opacity(0.06))
                        WallpaperSettingsPanel(
                            item: item,
                            onApply: { actions.onApplySettings(item) },
                            onClose: { withAnimation(.easeOut(duration: 0.22)) { settingsItem = nil } },
                            onUnsubscribe: item.id.allSatisfy(\.isNumber) ? {
                                actions.onUnsubscribe(item); favVersion += 1
                                withAnimation(.easeOut(duration: 0.22)) { settingsItem = nil }
                            } : nil
                        )
                        .frame(width: 340)
                        .transition(.move(edge: .trailing))
                    }
                }
            }
        }
        .frame(minWidth: 1000, minHeight: 660)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showSettings) {
            SettingsSheet(actions: actions,
                          currentItem: currentID.flatMap { id in library.items.first { $0.id == id } },
                          onClose: { showSettings = false })
        }
        .onAppear {
            if ProcessInfo.processInfo.environment["WP_PREVIEW_PANEL"] != nil, settingsItem == nil {
                settingsItem = filtered.first
            }
        }
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
            .background(Capsule().fill(.white.opacity(0.06)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.06)))
            Spacer()
            Button { showSettings = true } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(WaifuTheme.secondary)
                    .frame(width: 36, height: 32)
                    .background(Circle().fill(.white.opacity(0.06)))
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

    // MARK: - 首页(大图 hero + 横向货架)

    private var recentItems: [WallpaperItem] {
        ratingFilteredItems.sorted { $0.modifiedDate > $1.modifiedDate }
    }
    private var favoriteItems: [WallpaperItem] {
        let fav = PreferencesStore.shared.favorites
        return ratingFilteredItems.filter { fav.contains($0.id) }
    }
    /// 精选(hero):当前壁纸优先,其后最近添加,去重取前 8。
    private var featuredItems: [WallpaperItem] {
        var seen = Set<String>(); var out: [WallpaperItem] = []
        if let cur = currentID, let c = library.items.first(where: { $0.id == cur }) { out.append(c); seen.insert(c.id) }
        for it in recentItems where !seen.contains(it.id) { out.append(it); seen.insert(it.id); if out.count >= 8 { break } }
        return out
    }

    private var homeView: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    if !featuredItems.isEmpty {
                        // 大图 hero 占满视口高度(仿 WaifuX 沉浸式),只露出下方货架标题一角。
                        HeroCarousel(items: featuredItems, index: $heroIndex, currentID: currentID,
                                     height: max(360, geo.size.height - 86),
                                     onSet: { selectAndConfigure($0) },
                                     onToggleFav: { PreferencesStore.shared.toggleFavorite($0.id); favVersion += 1 })
                            .padding(.horizontal, 26).padding(.top, 10)
                    }
                    shelf("最近添加", Array(recentItems.prefix(14)))
                    if !favoriteItems.isEmpty { shelf("我的收藏", Array(favoriteItems.prefix(14))) }
                    ForEach([WallpaperType.scene, .video, .web], id: \.self) { t in
                        let items = ratingFilteredItems.filter { $0.type == t }
                        if !items.isEmpty { shelf(t.displayName, Array(items.prefix(14))) }
                    }
                }
                .padding(.bottom, 30)
                .id(favVersion)
            }
            .scrollIndicators(.hidden)
        }
    }

    /// 横向货架:标题 + 一行可横向滚动的卡片。
    private func shelf(_ title: String, _ items: [WallpaperItem]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
                Text("\(items.count)").font(.system(size: 13, weight: .medium)).foregroundStyle(WaifuTheme.tertiary)
                Spacer()
            }
            .padding(.horizontal, 26)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(items) { item in
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
        }
        .scrollIndicators(.hidden)
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
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(.white.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(.white.opacity(0.07)))
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

    /// 胶囊筛选 chip(选中=强调色填充)。
    private func chip(_ title: String, icon: String, on: Bool, _ act: @escaping () -> Void) -> some View {
        Button { withAnimation(.easeOut(duration: 0.15)) { act() } } label: {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                Text(title).font(.system(size: 12.5, weight: .medium))
            }
            .foregroundStyle(on ? .white : WaifuTheme.secondary)
            .padding(.horizontal, 13).padding(.vertical, 7)
            .background(Capsule().fill(on ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.white.opacity(0.06))))
            .overlay(Capsule().strokeBorder(.white.opacity(on ? 0 : 0.07)))
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
        .background(RoundedRectangle(cornerRadius: 9).fill(.white.opacity(0.06)))
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
            .background(Capsule().fill(.white.opacity(0.06)))
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
        Button(role: .destructive) { confirmDelete(item) } label: { Label("删除壁纸", systemImage: "trash") }
    }

    private func confirmDelete(_ item: WallpaperItem) {
        let alert = NSAlert()
        alert.messageText = "删除壁纸「\(item.title)」?"
        alert.informativeText = "壁纸文件夹会被移到废纸篓,可在废纸篓里恢复。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "删除"); alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn { actions.onDelete(item); favVersion += 1 }
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
}

/// 首页大图 hero 轮播:大预览 + 标题/元信息 + 设为壁纸/收藏 + 左右切换 + 圆点。
struct HeroCarousel: View {
    let items: [WallpaperItem]
    @Binding var index: Int
    var currentID: String?
    var height: CGFloat = 320
    var onSet: (WallpaperItem) -> Void
    var onToggleFav: (WallpaperItem) -> Void

    @State private var thumb: NSImage?

    private var item: WallpaperItem { items[min(index, items.count - 1)] }

    // 图片为基底 + 所有装饰用 .overlay 钉在基底 320 高的框上(避免 .aspectRatio(.fill) 把 ZStack 撑大
    // 导致底部信息被裁掉看不见 —— 这是之前标题不显示的根因)。
    var body: some View {
        Group {
            if let thumb { Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fill) }
            else { Rectangle().fill(.white.opacity(0.06)) }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .clipped()
        .overlay {   // 暗化渐变(左 + 下),保证标题可读
            ZStack {
                LinearGradient(colors: [.black.opacity(0.72), .black.opacity(0.15), .clear],
                               startPoint: .leading, endPoint: .trailing)
                LinearGradient(colors: [.clear, .black.opacity(0.2), .black.opacity(0.62)],
                               startPoint: .center, endPoint: .bottom)
            }
            .allowsHitTesting(false)
        }
        .overlay(alignment: .bottomLeading) {
            VStack(alignment: .leading, spacing: 12) {
                TypeBadge(type: item.type)
                Text(item.title).font(.system(size: 42, weight: .bold)).foregroundStyle(.white)
                    .lineLimit(2).shadow(color: .black.opacity(0.65), radius: 8)
                HStack(spacing: 8) {
                    Text(item.type.displayName)
                    Text("·"); Text(sizeText(item.fileSize))
                }.font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.88))
                HStack(spacing: 10) {
                    Button { onSet(item) } label: {
                        Label(item.id == currentID ? "正在播放" : "设为壁纸",
                              systemImage: item.id == currentID ? "checkmark.circle.fill" : "play.fill")
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 18).padding(.vertical, 10)
                            .background(Capsule().fill(item.id == currentID ? AnyShapeStyle(.white.opacity(0.22)) : AnyShapeStyle(Color.accentColor)))
                    }.buttonStyle(.plain)
                    Button { onToggleFav(item) } label: {
                        Image(systemName: PreferencesStore.shared.isFavorite(item.id) ? "heart.fill" : "heart")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(PreferencesStore.shared.isFavorite(item.id) ? .pink : .white)
                            .frame(width: 38, height: 38).background(Circle().fill(.white.opacity(0.18)))
                    }.buttonStyle(.plain)
                }
                .padding(.top, 4)
            }
            .padding(36)
        }
        .overlay(alignment: .leading) {
            heroArrow("chevron.left") { index = (index - 1 + items.count) % items.count }.padding(.leading, 12)
        }
        .overlay(alignment: .trailing) {
            heroArrow("chevron.right") { index = (index + 1) % items.count }.padding(.trailing, 12)
        }
        .overlay(alignment: .bottom) {
            HStack(spacing: 6) {
                ForEach(items.indices, id: \.self) { i in
                    Circle().fill(.white.opacity(i == index ? 0.95 : 0.35)).frame(width: 6, height: 6)
                }
            }
            .padding(.bottom, 12)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.10)))
        .shadow(color: .black.opacity(0.4), radius: 18, y: 8)
        .onChange(of: index) { _ in loadThumb() }
        .onChange(of: item.id) { _ in loadThumb() }
        .onAppear { loadThumb() }
    }

    private func heroArrow(_ icon: String, _ act: @escaping () -> Void) -> some View {
        Button(action: { withAnimation(.easeOut(duration: 0.2)) { act() } }) {
            Image(systemName: icon).font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                .frame(width: 36, height: 36).background(Circle().fill(.black.opacity(0.4)))
        }.buttonStyle(.plain).opacity(items.count > 1 ? 1 : 0)
    }

    private func loadThumb() {
        guard items.indices.contains(index), let url = item.previewURL else { thumb = nil; return }
        ThumbnailCache.shared.largeImage(for: url) { img in self.thumb = img }
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
            Group {
                if let thumb { Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fill) }
                else { Rectangle().fill(.white.opacity(0.05)).overlay(ProgressView().controlSize(.small)) }
            }
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
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(
                isCurrent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.white.opacity(0.08)),
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
            ThumbnailCache.shared.thumbnail(for: url) { img in self.thumb = img }
        }
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

/// 设置 sheet(WaifuX 风:深色,复用分组设置表单 + 关闭按钮)。
struct SettingsSheet: View {
    let actions: LibraryActions
    var currentItem: WallpaperItem?
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("设置").font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 18)).foregroundStyle(WaifuTheme.secondary)
                }.buttonStyle(.plain).keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            Divider().opacity(0.3)
            SettingsForm(actions: actions, currentItem: currentItem)
        }
        .frame(width: 720, height: 620)
        .background(WaifuTheme.background.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }
}
