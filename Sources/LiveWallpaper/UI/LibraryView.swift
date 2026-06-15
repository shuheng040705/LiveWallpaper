import SwiftUI

/// 主界面(原生 macOS 风格):NavigationSplitView 左侧原生侧边栏 + 右侧内容区,
/// 选中壁纸时右侧再滑出壁纸设置检视面板。配色全部使用系统强调色(Color.accentColor),
/// 不再硬编码品牌渐变,以贴合 macOS 原生审美(随用户系统强调色变化)。
struct LibraryView: View {
    @ObservedObject var library: WallpaperLibrary
    var currentID: String?
    var actions: LibraryActions

    @State private var section: Section =
        ProcessInfo.processInfo.environment["WP_PREVIEW_SETTINGS"] != nil ? .settings : .all
    @State private var search = ""
    @State private var favVersion = 0   // 收藏变更后强制刷新
    @State private var settingsItem: WallpaperItem?   // 正在设置的壁纸(右侧检视面板)

    enum Section: Hashable {
        case all, favorites
        case type(WallpaperType)
        case workshop
        case settings

        var title: String {
            switch self {
            case .all: return "全部"
            case .favorites: return "收藏"
            case .type(let t): return t.displayName
            case .workshop: return "创意工坊"
            case .settings: return "设置"
            }
        }
        var icon: String {
            switch self {
            case .all: return "square.grid.2x2"
            case .favorites: return "heart"
            case .workshop: return "bag"
            case .settings: return "gearshape"
            case .type(let t):
                switch t {
                case .video: return "film"
                case .scene: return "sparkles"
                case .web: return "globe"
                default: return "questionmark"
                }
            }
        }
    }

    /// 年龄段图标(筛选菜单用)。
    private func ratingIcon(_ r: ContentRating) -> String {
        switch r {
        case .everyone: return "person"
        case .questionable: return "exclamationmark.shield"
        case .mature: return "18.circle"
        case .unknown: return "questionmark"
        }
    }

    /// 网格缩略图大小(小/中/大),改变 adaptive 列的最小宽度 → 每行卡片数与卡片尺寸。
    enum GridSize: String, CaseIterable {
        case small, medium, large
        var title: String { switch self { case .small: return "小"; case .medium: return "中"; case .large: return "大" } }
        var icon: String { switch self { case .small: return "square.grid.3x3"; case .medium: return "square.grid.2x2"; case .large: return "square" } }
        /// adaptive 列 (最小宽, 最大宽)。小→更密更小、大→更稀更大。
        var range: (min: CGFloat, max: CGFloat) { switch self { case .small: return (165, 220); case .medium: return (230, 320); case .large: return (320, 440) } }
    }
    @State private var gridSize = GridSize(rawValue: PreferencesStore.shared.gridSizeRaw) ?? .medium
    private var columns: [GridItem] {
        let r = gridSize.range
        return [GridItem(.adaptive(minimum: r.min, maximum: r.max), spacing: 20)]
    }

    /// 排序方式。
    enum SortKey: String, CaseIterable {
        case type, name, date, size
        var title: String {
            switch self {
            case .type: return "类型"
            case .name: return "名称"
            case .date: return "最近下载"
            case .size: return "文件大小"
            }
        }
        var icon: String {
            switch self {
            case .type: return "square.grid.2x2"
            case .name: return "textformat"
            case .date: return "clock"
            case .size: return "externaldrive"
            }
        }
    }
    @State private var sortKey = SortKey(rawValue: PreferencesStore.shared.sortKeyRaw) ?? .type
    @State private var sortDesc = PreferencesStore.shared.sortDescending

    /// 内容分级(年龄段)全局勾选集。改变后影响全部/收藏/各类型的数量与内容(与 WE 一致)。
    @State private var selectedRatings: Set<ContentRating> =
        Set(PreferencesStore.shared.selectedRatings.compactMap { ContentRating(rawValue: $0) })

    /// 某壁纸是否通过年龄段筛选(未分级 unknown 视作 everyone,不丢失无标签壁纸)。
    private func ratingOK(_ item: WallpaperItem) -> Bool {
        let r: ContentRating = item.contentRating == .unknown ? .everyone : item.contentRating
        return selectedRatings.contains(r)
    }

    /// 先经年龄段筛选的库(所有分区/类型的数量与内容都基于它)。
    private var ratingFilteredItems: [WallpaperItem] { library.items.filter(ratingOK) }

    private var filtered: [WallpaperItem] {
        let fav = PreferencesStore.shared.favorites
        let matched = ratingFilteredItems.filter { item in
            let sectionOK: Bool
            switch section {
            case .all: sectionOK = true
            case .favorites: sectionOK = fav.contains(item.id)
            case .type(let t): sectionOK = item.type == t
            case .settings, .workshop: sectionOK = false
            }
            return sectionOK && (search.isEmpty || item.title.localizedCaseInsensitiveContains(search))
        }
        return sorted(matched)
    }

    /// 切换某年龄段勾选(至少保留 1 个,避免全空看不到任何壁纸)+ 持久化。
    private func toggleRating(_ r: ContentRating) {
        var s = selectedRatings
        if s.contains(r) { if s.count > 1 { s.remove(r) } } else { s.insert(r) }
        selectedRatings = s
        PreferencesStore.shared.selectedRatings = Set(s.map { $0.rawValue })
    }

    private func sorted(_ items: [WallpaperItem]) -> [WallpaperItem] {
        let asc: (WallpaperItem, WallpaperItem) -> Bool
        switch sortKey {
        case .type:
            asc = { a, b in
                if a.type != b.type { return a.type.sortOrder < b.type.sortOrder }
                return a.title.localizedStandardCompare(b.title) == .orderedAscending
            }
        case .name:
            asc = { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .date:
            asc = { $0.modifiedDate < $1.modifiedDate }
        case .size:
            asc = { $0.fileSize < $1.fileSize }
        }
        let s = items.sorted(by: asc)
        return sortDesc ? s.reversed() : s
    }

    // MARK: - 布局

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 204, ideal: 220, max: 280)
        } detail: {
            detail
                .navigationSplitViewColumnWidth(min: 560, ideal: 760)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 1000, minHeight: 640)
        .onAppear {
            // 截图验证用:WP_PREVIEW_PANEL=1 直接展开第一张壁纸的检视面板(不触发应用壁纸)。
            if ProcessInfo.processInfo.environment["WP_PREVIEW_PANEL"] != nil, settingsItem == nil {
                settingsItem = filtered.first
            }
        }
    }

    /// 切换分区(切到工坊/设置时收起壁纸检视面板)。
    private func select(_ s: Section) {
        if s == .workshop || s == .settings {
            withAnimation(.easeOut(duration: 0.2)) { settingsItem = nil }
        }
        section = s
    }

    // MARK: - 侧边栏(原生 List,放大字号 + 品牌头部,营造高级感)

    /// 侧栏行:放大的图标 + 标题(15.5pt),比系统默认更醒目、更有质感。
    private func sidebarLabel(_ title: String, _ icon: String, accent: Bool = false) -> some View {
        Label {
            Text(title).font(.system(size: 15.5, weight: .regular))
        } icon: {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(accent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
        }
    }

    private var sidebar: some View {
        List(selection: Binding<Section?>(get: { section }, set: { if let v = $0 { select(v) } })) {
            sidebarLabel(Section.all.title, Section.all.icon, accent: true)
                .badge(ratingFilteredItems.count)
                .tag(Section.all)
            sidebarLabel(Section.favorites.title, Section.favorites.icon)
                .badge(filteredFavCount)
                .tag(Section.favorites)
            sidebarLabel(Section.workshop.title, Section.workshop.icon)
                .tag(Section.workshop)

            SwiftUI.Section {
                ForEach([WallpaperType.video, .scene, .web], id: \.self) { t in
                    sidebarLabel(t.displayName, Section.type(t).icon)
                        .badge(filteredTypeCount(t))
                        .tag(Section.type(t))
                }
            } header: {
                Text("类型").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.secondary)
            }
        }
        .listStyle(.sidebar)
        .environment(\.defaultMinListRowHeight, 36)   // 更舒展的行高 = 高级感
        .safeAreaInset(edge: .top) { brandHeader }
        .safeAreaInset(edge: .bottom) { sidebarFooter }
    }

    /// 侧栏顶部品牌区:应用图标 + 名称(留出红绿灯空间)。
    private var brandHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "photo.stack")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            Text("壁纸库").font(.system(size: 19, weight: .bold))
            Spacer()
        }
        .padding(.horizontal, 18).padding(.top, 32).padding(.bottom, 12)
    }

    /// 侧栏底部:设置 + 重新扫描。
    private var sidebarFooter: some View {
        VStack(spacing: 1) {
            Divider().padding(.bottom, 4)
            Button { select(.settings) } label: {
                Label {
                    Text("设置").font(.system(size: 14.5))
                } icon: {
                    Image(systemName: "gearshape").font(.system(size: 15, weight: .medium))
                        .foregroundStyle(section == .settings ? Color.accentColor : .secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(section == .settings ? Color.accentColor : .primary)
            .padding(.horizontal, 14).padding(.vertical, 7)

            Button { library.scan() } label: {
                HStack(spacing: 10) {
                    if library.isScanning {
                        ProgressView().controlSize(.small).scaleEffect(0.8).frame(width: 18)
                    } else {
                        Image(systemName: "arrow.clockwise").font(.system(size: 15, weight: .medium)).frame(width: 18)
                    }
                    Text(library.isScanning ? "扫描中…" : "重新扫描").font(.system(size: 14.5))
                    Spacer()
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(library.isScanning)
            .padding(.horizontal, 14).padding(.vertical, 7)
        }
        .padding(.bottom, 10)
        .background(.ultraThinMaterial)
    }

    private var filteredFavCount: Int {
        let fav = PreferencesStore.shared.favorites
        return ratingFilteredItems.filter { fav.contains($0.id) }.count
    }
    private func filteredTypeCount(_ t: WallpaperType) -> Int {
        ratingFilteredItems.filter { $0.type == t }.count
    }

    // MARK: - 详情区

    @ViewBuilder
    private var detail: some View {
        HStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .toolbar { toolbarContent }
            // 选中壁纸时右侧滑出壁纸检视面板。
            if let item = settingsItem {
                Divider()
                WallpaperSettingsPanel(
                    item: item,
                    onApply: { actions.onApplySettings(item) },
                    onClose: { withAnimation(.easeOut(duration: 0.22)) { settingsItem = nil } },
                    onUnsubscribe: item.id.allSatisfy(\.isNumber) ? {
                        actions.onUnsubscribe(item)
                        favVersion += 1
                        withAnimation(.easeOut(duration: 0.22)) { settingsItem = nil }
                    } : nil
                )
                .frame(width: 320)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch section {
        case .workshop:
            WorkshopView()
        case .settings:
            SettingsForm(actions: actions,
                         currentItem: currentID.flatMap { id in library.items.first { $0.id == id } })
        default:
            if library.items.isEmpty { emptyState }
            else if filtered.isEmpty { noResultsState }
            else { grid }
        }
    }

    // MARK: - 工具栏

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if section != .workshop && section != .settings {
            ToolbarItemGroup {
                // 内容分级筛选菜单(原生 Mail 式筛选)。
                Menu {
                    ForEach([ContentRating.everyone, .questionable, .mature], id: \.self) { r in
                        Toggle(isOn: Binding(get: { selectedRatings.contains(r) },
                                             set: { _ in toggleRating(r) })) {
                            Label("\(r.displayName) (\(library.ratingCounts[r] ?? 0))", systemImage: ratingIcon(r))
                        }
                    }
                } label: {
                    Label("筛选", systemImage: "line.3.horizontal.decrease.circle")
                }
                .help("内容分级筛选")

                // 排序菜单。
                Menu {
                    Picker("排序方式", selection: Binding(get: { sortKey }, set: {
                        sortKey = $0; PreferencesStore.shared.sortKeyRaw = $0.rawValue
                    })) {
                        ForEach(SortKey.allCases, id: \.self) { Label($0.title, systemImage: $0.icon).tag($0) }
                    }
                    Divider()
                    Picker("顺序", selection: Binding(get: { sortDesc }, set: {
                        sortDesc = $0; PreferencesStore.shared.sortDescending = $0
                    })) {
                        Label("升序", systemImage: "arrow.up").tag(false)
                        Label("降序", systemImage: "arrow.down").tag(true)
                    }
                } label: {
                    Label("排序", systemImage: "arrow.up.arrow.down")
                }
                .help("排序方式")

                // 网格大小切换。
                Picker("图标大小", selection: Binding(get: { gridSize }, set: { newSize in
                    withAnimation(.easeOut(duration: 0.18)) { gridSize = newSize }
                    PreferencesStore.shared.gridSizeRaw = newSize.rawValue
                })) {
                    ForEach(GridSize.allCases, id: \.self) { Image(systemName: $0.icon).tag($0) }
                }
                .pickerStyle(.segmented)
                .help("图标大小")
            }
        }
    }

    /// 删除前弹确认(移到废纸篓,可恢复)。
    private func confirmDelete(_ item: WallpaperItem) {
        let alert = NSAlert()
        alert.messageText = "删除壁纸「\(item.title)」?"
        alert.informativeText = "壁纸文件夹会被移到废纸篓,可在废纸篓里恢复。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            actions.onDelete(item)
            favVersion += 1
        }
    }

    /// 选中壁纸:应用它 + 滑出右侧设置检视面板。
    private func selectAndConfigure(_ item: WallpaperItem) {
        actions.onSelect(item)
        withAnimation(.easeOut(duration: 0.22)) { settingsItem = item }
    }

    /// 内容区大号分区标题(高级感:粗体大标题 + 数量)。
    private var gridHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(section.title).font(.system(size: 24, weight: .bold))
            Text("\(filtered.count)").font(.system(size: 15, weight: .medium)).foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, 24).padding(.top, 14).padding(.bottom, 2)
    }

    private var grid: some View {
        ScrollView {
            gridHeader
            LazyVGrid(columns: columns, spacing: 20) {
                ForEach(filtered) { item in
                    WallpaperCard(
                        item: item,
                        isCurrent: item.id == currentID,
                        isFavorite: PreferencesStore.shared.isFavorite(item.id),
                        onSelect: { selectAndConfigure(item) },
                        onToggleFavorite: {
                            PreferencesStore.shared.toggleFavorite(item.id)
                            favVersion += 1
                        }
                    )
                    .contextMenu {
                        Button { selectAndConfigure(item) } label: { Label("设为壁纸", systemImage: "play.fill") }
                        Button { withAnimation(.easeOut(duration: 0.22)) { settingsItem = item } } label: { Label("壁纸设置…", systemImage: "slider.horizontal.3") }
                        Button {
                            PreferencesStore.shared.toggleFavorite(item.id); favVersion += 1
                        } label: {
                            Label(PreferencesStore.shared.isFavorite(item.id) ? "取消收藏" : "收藏",
                                  systemImage: PreferencesStore.shared.isFavorite(item.id) ? "heart.slash" : "heart")
                        }
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([item.folderURL])
                        } label: { Label("在访达中显示", systemImage: "folder") }
                        Divider()
                        Button(role: .destructive) { confirmDelete(item) } label: {
                            Label("删除壁纸", systemImage: "trash")
                        }
                    }
                }
            }
            .padding(24)
            .id(favVersion)
        }
        .searchable(text: $search, placement: .toolbar, prompt: "搜索壁纸")
    }

    private var emptyState: some View {
        EmptyStateView(
            label: library.isScanning ? "正在扫描壁纸…" : "没找到壁纸",
            systemImage: library.isScanning ? "hourglass" : "tray",
            description: library.rootURL.path
        )
    }

    private var noResultsState: some View {
        EmptyStateView(
            label: section == .favorites ? "还没有收藏" : "没有匹配的壁纸",
            systemImage: section == .favorites ? "heart.slash" : "magnifyingglass",
            description: section == .favorites ? "把喜欢的壁纸点上 ♥,这里就会出现" : "试试别的搜索词"
        )
    }
}

/// 占位空态(macOS 13 没有系统 ContentUnavailableView,这里自绘一个对齐风格的版本)。
struct EmptyStateView: View {
    let label: String
    let systemImage: String
    var description: String? = nil
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 38, weight: .regular))
                .foregroundStyle(.tertiary)
            Text(label)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)
            if let description {
                Text(description)
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.horizontal, 40)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 单张壁纸卡片:16:9 预览 + 悬停放大/阴影 + 渐变标题 + 播放中角标 + 收藏心形。
/// 选中描边使用系统强调色(Color.accentColor)。
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
                if let thumb {
                    Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(.quaternary).overlay(ProgressView().controlSize(.small))
                }
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(16.0/9.0, contentMode: .fit)
            .clipped()

            VStack {
                Spacer()
                HStack {
                    Text(item.title)
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                        .lineLimit(2).shadow(color: .black.opacity(0.5), radius: 3, y: 1)
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.bottom, 10).padding(.top, 30)
                .background(LinearGradient(colors: [.clear, .black.opacity(0.35), .black.opacity(0.8)],
                                           startPoint: .top, endPoint: .bottom))
            }

            if hovering {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 40)).foregroundStyle(.white.opacity(0.95)).shadow(radius: 6)
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
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7).padding(.vertical, 3)
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
                isCurrent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.white.opacity(0.10)),
                lineWidth: isCurrent ? 3 : 1)
        )
        // 双层柔和投影 = 高级层次感(环境大柔影 + 贴近的暗影);选中时叠一层强调色辉光。
        .shadow(color: .black.opacity(hovering ? 0.32 : 0.16), radius: hovering ? 18 : 9, y: hovering ? 10 : 4)
        .shadow(color: .black.opacity(hovering ? 0.18 : 0.10), radius: hovering ? 5 : 2, y: 1)
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
        switch type {
        case .video: return "film.fill"
        case .scene: return "sparkles"
        case .web: return "globe"
        default: return "questionmark"
        }
    }
    private var color: Color {
        switch type {
        case .video: return .blue
        case .scene: return .purple
        case .web: return .green
        default: return .gray
        }
    }
}
