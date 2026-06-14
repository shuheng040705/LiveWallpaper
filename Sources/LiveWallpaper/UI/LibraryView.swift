import SwiftUI

/// 主界面:左侧毛玻璃侧边栏(分类导航 + 设置)+ 右侧内容区(卡片网格 或 设置表单)。
struct LibraryView: View {
    @ObservedObject var library: WallpaperLibrary
    var currentID: String?
    var actions: LibraryActions

    @State private var section: Section = .all
    @State private var search = ""
    @State private var favVersion = 0   // 收藏变更后强制刷新
    @State private var settingsItem: WallpaperItem?   // 正在设置的壁纸(弹 sheet)
    @State private var ratingsExpanded = false   // 「全部」是否展开年龄段子项

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
            case .all: return "square.grid.2x2.fill"
            case .favorites: return "heart.fill"
            case .workshop: return "cart.fill"
            case .settings: return "gearshape.fill"
            case .type(let t):
                switch t {
                case .video: return "film.fill"
                case .scene: return "sparkles"
                case .web: return "globe"
                default: return "questionmark"
                }
            }
        }
    }

    /// 年龄段图标(复选框行用)。
    private func ratingIcon(_ r: ContentRating) -> String {
        switch r {
        case .everyone: return "person.fill"
        case .questionable: return "exclamationmark.shield.fill"
        case .mature: return "18.circle.fill"
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
        return [GridItem(.adaptive(minimum: r.min, maximum: r.max), spacing: 18)]
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

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 248)
            mainArea
            // 选中壁纸时右侧滑出设置边栏。
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
        .frame(minWidth: 980, minHeight: 640)
        .background(VisualEffectView(material: .underWindowBackground).ignoresSafeArea())
    }

    // MARK: - 侧边栏(放大版)

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                Image(systemName: "photo.stack.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(LinearGradient(colors: [.pink, .purple],
                                                    startPoint: .topLeading, endPoint: .bottomTrailing))
                Text("壁纸库").font(.system(size: 20, weight: .bold))
            }
            .padding(.leading, 20).padding(.top, 40).padding(.bottom, 22)

            VStack(spacing: 4) {
                allRow
                if ratingsExpanded {
                    ForEach([ContentRating.everyone, .questionable, .mature], id: \.self) { r in
                        ratingRow(r)
                    }
                }
                navRow(.favorites, count: filteredFavCount)
                navRow(.workshop, count: nil)

                Text("类型")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 16).padding(.top, 18).padding(.bottom, 6)

                ForEach([WallpaperType.video, .scene, .web], id: \.self) { t in
                    navRow(.type(t), count: filteredTypeCount(t))
                }
            }
            .padding(.horizontal, 12)

            Spacer()

            // 设置 + 重新扫描
            VStack(spacing: 4) {
                navRow(.settings, count: nil)
                Button { library.scan() } label: {
                    HStack(spacing: 12) {
                        if library.isScanning {
                            ProgressView().controlSize(.small).scaleEffect(0.8).frame(width: 24)
                        } else {
                            Image(systemName: "arrow.clockwise").font(.system(size: 15)).frame(width: 24)
                        }
                        Text(library.isScanning ? "扫描中…" : "重新扫描").font(.system(size: 14))
                        Spacer()
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(library.isScanning)
            }
            .padding(.horizontal, 12).padding(.bottom, 14)
        }
        .frame(maxHeight: .infinity)
        .background(VisualEffectView(material: .sidebar).ignoresSafeArea())
    }

    private func navRow(_ s: Section, count: Int?) -> some View {
        let selected = section == s
        return Button {
            withAnimation(.easeOut(duration: 0.15)) {
                section = s
                // 切到创意工坊/设置时关闭右侧壁纸属性栏(避免「全部」里选的壁纸属性栏残留)。
                if s == .workshop || s == .settings { settingsItem = nil }
            }
        } label: {
            HStack(spacing: 13) {
                Image(systemName: s.icon)
                    .font(.system(size: 16)).frame(width: 26)
                    .foregroundStyle(selected ? .white : (s == .favorites ? .pink : Color.secondary))
                Text(s.title)
                    .font(.system(size: 15, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? .white : .primary)
                Spacer()
                if let count {
                    Text("\(count)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(selected ? .white.opacity(0.9) : .secondary)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(selected ? Color.white.opacity(0.18) : Color.secondary.opacity(0.12)))
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10).fill(
                    selected ? AnyShapeStyle(LinearGradient(colors: [.pink, .purple],
                                                            startPoint: .leading, endPoint: .trailing))
                             : AnyShapeStyle(Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 「全部」行:点击主体显示全部;右侧 chevron 切换展开三个年龄段子项。
    private var allRow: some View {
        let selected = section == .all
        return HStack(spacing: 13) {
            Image(systemName: Section.all.icon)
                .font(.system(size: 16)).frame(width: 26)
                .foregroundStyle(selected ? .white : Color.secondary)
            Text(Section.all.title)
                .font(.system(size: 15, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? .white : .primary)
            Spacer()
            Text("\(ratingFilteredItems.count)")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(selected ? .white.opacity(0.9) : .secondary)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Capsule().fill(selected ? Color.white.opacity(0.18) : Color.secondary.opacity(0.12)))
            Button {
                withAnimation(.easeOut(duration: 0.15)) { ratingsExpanded.toggle() }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(selected ? .white.opacity(0.9) : .secondary)
                    .rotationEffect(.degrees(ratingsExpanded ? 90 : 0))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10).fill(
                selected ? AnyShapeStyle(LinearGradient(colors: [.pink, .purple],
                                                        startPoint: .leading, endPoint: .trailing))
                         : AnyShapeStyle(Color.clear))
        )
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { section = .all } }
    }

    private var filteredFavCount: Int {
        let fav = PreferencesStore.shared.favorites
        return ratingFilteredItems.filter { fav.contains($0.id) }.count
    }
    private func filteredTypeCount(_ t: WallpaperType) -> Int {
        ratingFilteredItems.filter { $0.type == t }.count
    }

    /// 年龄段复选行:勾选框控制全局筛选(多选);徽章=该档**总**数量。点击切换勾选。
    private func ratingRow(_ r: ContentRating) -> some View {
        let on = selectedRatings.contains(r)
        let count = library.ratingCounts[r] ?? 0
        return Button {
            withAnimation(.easeOut(duration: 0.15)) { toggleRating(r) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: on ? "checkmark.square.fill" : "square")
                    .font(.system(size: 15)).frame(width: 20)
                    .foregroundStyle(on ? AnyShapeStyle(LinearGradient(colors: [.pink, .purple],
                                                                       startPoint: .top, endPoint: .bottom))
                                        : AnyShapeStyle(Color.secondary))
                Image(systemName: ratingIcon(r))
                    .font(.system(size: 12)).frame(width: 18)
                    .foregroundStyle(on ? .primary : .secondary)
                Text(r.displayName)
                    .font(.system(size: 13, weight: on ? .medium : .regular))
                    .foregroundStyle(on ? .primary : .secondary)
                Spacer()
                Text("\(count)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(Color.secondary.opacity(0.12)))
            }
            .padding(.leading, 26).padding(.trailing, 12).padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 主区

    private var mainArea: some View {
        VStack(spacing: 0) {
            if section != .workshop {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(section.title).font(.system(size: 20, weight: .bold))
                        Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if section != .settings {
                        gridSizeControl
                        sortControl
                        searchField
                    }
                }
                .padding(.horizontal, 24).padding(.top, 30).padding(.bottom, 16)
            }

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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var subtitle: String {
        switch section {
        case .settings: return "偏好与控制"
        default: return "\(filtered.count) 张壁纸"
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

    /// 选中壁纸:应用它 + 滑出右侧设置边栏(切换到该壁纸的设置)。
    private func selectAndConfigure(_ item: WallpaperItem) {
        actions.onSelect(item)
        withAnimation(.easeOut(duration: 0.22)) { settingsItem = item }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 18) {
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
            .padding(.horizontal, 24).padding(.bottom, 24)
            .id(favVersion)
        }
    }

    /// 排序控件:菜单选排序字段 + 一个升/降序切换按钮。
    private var sortControl: some View {
        HStack(spacing: 6) {
            Menu {
                ForEach(SortKey.allCases, id: \.self) { key in
                    Button {
                        sortKey = key
                        PreferencesStore.shared.sortKeyRaw = key.rawValue
                    } label: {
                        Label(key.title, systemImage: sortKey == key ? "checkmark" : key.icon)
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.up.arrow.down").font(.system(size: 11))
                    Text(sortKey.title).font(.system(size: 12))
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Button {
                sortDesc.toggle()
                PreferencesStore.shared.sortDescending = sortDesc
            } label: {
                Image(systemName: sortDesc ? "chevron.down" : "chevron.up")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .background(RoundedRectangle(cornerRadius: 7).fill(.quaternary.opacity(0.6)))
            }
            .buttonStyle(.plain)
            .help(sortDesc ? "降序" : "升序")
        }
    }

    /// 网格大小切换:小/中/大三段(改 adaptive 列最小宽 → 卡片尺寸)。持久化到 PreferencesStore。
    private var gridSizeControl: some View {
        HStack(spacing: 2) {
            ForEach(GridSize.allCases, id: \.self) { sz in
                let on = gridSize == sz
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { gridSize = sz }
                    PreferencesStore.shared.gridSizeRaw = sz.rawValue
                } label: {
                    Image(systemName: sz.icon)
                        .font(.system(size: 12, weight: on ? .semibold : .regular))
                        .frame(width: 28, height: 24)
                        .foregroundStyle(on ? AnyShapeStyle(LinearGradient(colors: [.pink, .purple], startPoint: .top, endPoint: .bottom)) : AnyShapeStyle(Color.secondary))
                        .background(RoundedRectangle(cornerRadius: 6).fill(on ? Color.pink.opacity(0.14) : .clear))
                }
                .buttonStyle(.plain)
                .help("\(sz.title)图标")
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.6)))
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.secondary)
            TextField("搜索…", text: $search)
                .textFieldStyle(.plain).font(.system(size: 13)).frame(width: 160)
            if !search.isEmpty {
                Button { search = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(.tertiary)
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.6)))
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: library.isScanning ? "hourglass" : "tray")
                .font(.system(size: 44)).foregroundStyle(.secondary)
            Text(library.isScanning ? "正在扫描壁纸…" : "没找到壁纸")
                .font(.system(size: 15, weight: .medium)).foregroundStyle(.secondary)
            Text(library.rootURL.path)
                .font(.caption).foregroundStyle(.tertiary)
                .lineLimit(2).multilineTextAlignment(.center).padding(.horizontal, 40)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noResultsState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: section == .favorites ? "heart.slash" : "magnifyingglass")
                .font(.system(size: 40)).foregroundStyle(.tertiary)
            Text(section == .favorites ? "还没有收藏" : "没有匹配的壁纸")
                .font(.system(size: 14)).foregroundStyle(.secondary)
            if section == .favorites {
                Text("把喜欢的壁纸点上 ♥,这里就会出现")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 单张壁纸卡片:16:9 预览 + 悬停放大/阴影 + 渐变标题 + 播放中角标 + 收藏心形。
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
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                        .lineLimit(2).shadow(radius: 2)
                    Spacer()
                }
                .padding(.horizontal, 10).padding(.bottom, 8).padding(.top, 24)
                .background(LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom))
            }

            if hovering {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 40)).foregroundStyle(.white.opacity(0.9)).shadow(radius: 6)
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
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12).strokeBorder(
                isCurrent ? AnyShapeStyle(LinearGradient(colors: [.pink, .purple],
                                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                          : AnyShapeStyle(Color.white.opacity(0.08)),
                lineWidth: isCurrent ? 2.5 : 1)
        )
        .shadow(color: .black.opacity(hovering ? 0.35 : 0.15), radius: hovering ? 14 : 6, y: hovering ? 8 : 3)
        .scaleEffect(hovering ? 1.025 : 1.0)
        .animation(.easeOut(duration: 0.18), value: hovering)
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
