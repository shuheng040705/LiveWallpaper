import SwiftUI

private enum WorkshopStyle {
    static let accent = Color(red: 0.35, green: 0.82, blue: 0.91)
    static let background = Color(red: 0.055, green: 0.065, blue: 0.085)
    static let panel = Color(red: 0.085, green: 0.10, blue: 0.125)
    static let border = Color.white.opacity(0.075)
}

/// 原生坐标与命中区域；远程页面只提供数据，不参与布局或点击。
struct WorkshopView: View {
    @ObservedObject var library: WallpaperLibrary
    let actions: LibraryActions
    @ObservedObject private var browser = WorkshopBrowserModel.shared
    @ObservedObject private var subscriptions = WorkshopSubscriptions.shared
    @ObservedObject private var downloader = WorkshopDownloader.shared
    @State private var showFilters = true
    @State private var showTransfers = false

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                header
                HStack(spacing: 0) {
                    if showFilters && (browser.selection == nil || geometry.size.width > 1120) {
                        filters.frame(width: 188)
                        Divider().overlay(WorkshopStyle.border)
                    }
                    VStack(spacing: 0) {
                        sortBar
                        if let error = browser.error {
                            HStack(spacing: 10) {
                                Image(systemName: "wifi.exclamationmark").foregroundStyle(.orange)
                                Text(error).font(.callout)
                                Spacer()
                                Button("重试") { browser.retryLastRequest() }
                            }.padding(12).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                                .padding(.horizontal, 22).padding(.bottom, 8)
                        }
                        catalog.id(browser.page)
                        if browser.page > 0 && browser.totalPages > 1 {
                            WorkshopPageNavigator(page: browser.page, totalPages: browser.totalPages,
                                                  select: browser.goToPage)
                                .disabled(browser.loading)
                        }
                        if downloader.pendingCount > 0 { transferShelf }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    if let item = browser.selection {
                        Divider().overlay(WorkshopStyle.border)
                        detail(item).frame(width: geometry.size.width < 1000 ? 300 : 340)
                    }
                }
            }
            .background(WorkshopStyle.background)
            .tint(WorkshopStyle.accent)
            .sheet(isPresented: $showTransfers) { DownloadsView(embedded: true).frame(width: 620, height: 540) }
        }
        .task { browser.loadIfNeeded(); subscriptions.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .steamSubscriptionsDidChange)) { _ in subscriptions.refresh() }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 5) {
                Text("发现你的下一张壁纸").font(.system(size: 24, weight: .bold, design: .rounded))
                Text("STEAM WORKSHOP").font(.system(size: 9, weight: .semibold)).tracking(2.4)
                    .foregroundStyle(WorkshopStyle.accent.opacity(0.8))
            }.layoutPriority(1)
            Spacer(minLength: 0)
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索壁纸或粘贴工坊链接", text: $browser.search)
                    .textFieldStyle(.plain).onSubmit { browser.searchSubmitted() }
                if !browser.search.isEmpty {
                    Button { browser.search = ""; browser.reload() } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("清除搜索")
                }
                Button { browser.searchSubmitted() } label: { Image(systemName: "arrow.turn.down.left").font(.caption) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("搜索")
            }
            .padding(.horizontal, 13).frame(height: 38).frame(maxWidth: 350)
            .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(WorkshopStyle.border))
            Button { showTransfers = true } label: {
                HStack(spacing: 7) {
                    Image(systemName: "arrow.down.circle")
                    Text("下载")
                    if downloader.pendingCount > 0 {
                        Text("\(downloader.pendingCount)").font(.system(size: 10, weight: .bold)).monospacedDigit()
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(WorkshopStyle.accent.opacity(0.18), in: Capsule())
                    }
                }.font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 14).frame(height: 38)
                    .background(WorkshopStyle.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 11))
            }.buttonStyle(.plain).foregroundStyle(WorkshopStyle.accent).help("管理并行下载")
        }.padding(.horizontal, 26).padding(.top, 18).padding(.bottom, 22)
    }

    private let sorts: [(String, String, String)] = [
        ("trend", "本周热门", "flame"), ("mostrecent", "最新发布", "sparkles"),
        ("toprated", "高分佳作", "star"), ("totaluniquesubscribers", "最多订阅", "person.2")
    ]
    private var sortBar: some View {
        HStack(spacing: 5) {
            ForEach(sorts, id: \.0) { sort in
                Button { browser.sort = sort.0; browser.reload() } label: {
                    Label(sort.1, systemImage: sort.2).font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 11).padding(.vertical, 8)
                        .foregroundStyle(browser.sort == sort.0 ? WorkshopStyle.accent : Color.secondary)
                        .background(browser.sort == sort.0 ? WorkshopStyle.accent.opacity(0.10) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain)
            }
            Spacer(minLength: 4)
            if browser.loading { ProgressView().controlSize(.mini) }
            Button { showFilters.toggle() } label: { Image(systemName: "line.3.horizontal.decrease") }
                .buttonStyle(.plain).foregroundStyle(showFilters ? WorkshopStyle.accent : .secondary).help("显示或隐藏筛选")
                .padding(.horizontal, 5)
            Button { browser.retryLastRequest(); subscriptions.refresh() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("刷新创意工坊")
        }.padding(.horizontal, 22).padding(.bottom, 16)
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("筛选", systemImage: "slider.horizontal.3").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button("重置") { browser.resetFilters() }.font(.system(size: 10)).buttonStyle(.plain).foregroundStyle(.secondary)
            }.padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 20)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    ForEach(browser.groups) { group in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(group.title).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                            if group.id == "Type" {
                                VStack(spacing: 4) {
                                    typeFilter("全部类型", value: "", group: group.id, icon: "square.grid.2x2")
                                    ForEach(group.tags) { tag in
                                        typeFilter(localizedTag(tag.title), value: tag.id, group: group.id, icon: typeIcon(tag.id))
                                    }
                                }
                            } else {
                                Picker(group.title, selection: Binding(
                                    get: { browser.filters[group.id] ?? "" },
                                    set: { browser.filters[group.id] = $0; browser.reload() }
                                )) {
                                    Text("全部").tag("")
                                    ForEach(group.tags) { tag in Text(localizedTag(tag.title)).tag(tag.id) }
                                }.labelsHidden().controlSize(.small).accessibilityLabel(group.title)
                            }
                        }
                    }
                }.padding(.horizontal, 18).padding(.bottom, 20)
            }
            VStack(alignment: .leading, spacing: 13) {
                Divider()
                Button { SteamWebLoginWindowController.shared.authorize { _ in subscriptions.refresh() } } label: {
                    Label("Steam 账户", systemImage: "person.crop.circle")
                }
                Button { NSWorkspace.shared.open(URL(string: "https://steamcommunity.com/app/431960/workshop/")!) } label: {
                    Label("打开 Steam 创意工坊", systemImage: "arrow.up.right.square")
                }
            }.font(.system(size: 10)).buttonStyle(.plain).foregroundStyle(.secondary)
                .padding(.horizontal, 18).padding(.bottom, 20)
        }.background(WorkshopStyle.panel.opacity(0.35))
    }
    private func typeFilter(_ title: String, value: String, group: String, icon: String) -> some View {
        let selected = (browser.filters[group] ?? "") == value
        return Button { browser.filters[group] = value; browser.reload() } label: {
            HStack(spacing: 9) {
                Image(systemName: icon).frame(width: 14)
                Text(title)
                Spacer()
                if selected { Circle().fill(WorkshopStyle.accent).frame(width: 4, height: 4) }
            }.font(.system(size: 11, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? WorkshopStyle.accent : Color.secondary)
                .padding(.horizontal, 10).padding(.vertical, 9)
                .background(selected ? WorkshopStyle.accent.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
    private func localizedTag(_ value: String) -> String {
        ["Scene": "场景", "Video": "视频", "Web": "网页", "Application": "应用",
         "Everyone": "适合所有人", "Questionable": "待商榷", "Mature": "成人内容"][value] ?? value
    }
    private func typeIcon(_ type: String) -> String {
        switch type { case "Scene": return "mountain.2"; case "Video": return "play.rectangle"; case "Web": return "globe"; default: return "app.dashed" }
    }

    private var catalog: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if browser.usingCachedData {
                    HStack(spacing: 7) {
                        Image(systemName: "clock.arrow.circlepath")
                        Text("当前显示上次成功加载的壁纸")
                        if let date = browser.updatedAt { Text(date, style: .relative); Text("前更新") }
                        Spacer()
                        if browser.loading { Text("正在重新连接 Steam…") }
                    }.font(.system(size: 10)).foregroundStyle(.secondary)
                }
                if let first = browser.items.first, !browser.isShowingSearchResults, browser.selection == nil {
                    featured(first)
                }
                HStack(alignment: .firstTextBaseline) {
                    Text(browser.isShowingSearchResults ? "搜索结果" : "探索壁纸").font(.system(size: 16, weight: .bold))
                    Text(browser.total > 0 ? browser.total.formatted() + " 个作品" : "来自全球创作者")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer()
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 195, maximum: 340), spacing: 16)], spacing: 18) {
                    ForEach(browser.items) { item in
                        WorkshopCatalogCard(item: item, selected: browser.selection?.id == item.id,
                                             installed: library.item(id: item.id) != nil,
                                             onSelect: { browser.select(item) })
                    }
                }
                if !browser.loading && browser.items.isEmpty && browser.error == nil {
                    VStack(spacing: 12) {
                        Image(systemName: "sparkle.magnifyingglass").font(.system(size: 32)).foregroundStyle(WorkshopStyle.accent)
                        Text("还没有找到合适的壁纸").font(.headline)
                        Text("换个关键词，或试试其他筛选条件").font(.caption).foregroundStyle(.secondary)
                        Button("清除筛选") { browser.resetFilters() }
                    }.frame(maxWidth: .infinity).padding(.vertical, 65)
                }
            }.padding(.horizontal, 24).padding(.bottom, 24)
        }
    }
    private func featured(_ item: WorkshopWallpaper) -> some View {
        Button { browser.select(item) } label: {
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 12) {
                    Label(sorts.first(where: { $0.0 == browser.sort })?.1 ?? "发现壁纸", systemImage: "sparkles")
                        .font(.system(size: 9, weight: .bold)).foregroundStyle(WorkshopStyle.accent)
                        .padding(.horizontal, 9).padding(.vertical, 5).background(WorkshopStyle.accent.opacity(0.08), in: Capsule())
                    Text(item.title).font(.system(size: 23, weight: .bold, design: .rounded)).lineLimit(2)
                    Text(item.author).font(.system(size: 11)).foregroundStyle(.secondary)
                    Label("查看壁纸", systemImage: "arrow.up.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(WorkshopStyle.accent)
                }.padding(.leading, 26).padding(.vertical, 20).frame(maxWidth: .infinity, alignment: .leading)
                WorkshopArtwork(url: item.previewURL).frame(width: 280, height: 196)
                    .mask(LinearGradient(colors: [.clear, .white, .white], startPoint: .leading, endPoint: .trailing))
            }.frame(height: 196)
                .background(LinearGradient(colors: [WorkshopStyle.panel, Color(red: 0.07, green: 0.16, blue: 0.19)], startPoint: .leading, endPoint: .trailing))
                .clipShape(RoundedRectangle(cornerRadius: 17))
                .overlay(RoundedRectangle(cornerRadius: 17).strokeBorder(WorkshopStyle.accent.opacity(0.12)))
                .contentShape(RoundedRectangle(cornerRadius: 17))
        }.buttonStyle(.plain).accessibilityLabel("查看推荐壁纸：\(item.title)")
    }

    private var transferShelf: some View {
        Button { showTransfers = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.circle.fill").font(.system(size: 23)).foregroundStyle(WorkshopStyle.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(downloader.transferringCount) 项正在下载 · \(downloader.queuedCount + downloader.preparingCount) 项等待 / 准备").font(.system(size: 11, weight: .semibold))
                    Text("下载完成后自动加入壁纸库").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                Text("查看下载").font(.system(size: 11)).foregroundStyle(WorkshopStyle.accent)
                Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.secondary)
            }.padding(.horizontal, 24).padding(.vertical, 13).background(WorkshopStyle.panel)
        }.buttonStyle(.plain)
    }

    private func detail(_ item: WorkshopWallpaper) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("壁纸详情").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Button { browser.closeDetail() } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).frame(width: 26, height: 26)
                        .background(.white.opacity(0.06), in: Circle())
                }.buttonStyle(.plain).help("关闭详情")
            }.padding(18)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    WorkshopArtwork(url: item.previewURL).aspectRatio(16.0 / 10.0, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 8) {
                        Text(item.title).font(.system(size: 20, weight: .bold, design: .rounded)).textSelection(.enabled)
                        Label(item.author.isEmpty ? "Steam 创作者" : item.author, systemImage: "person.crop.circle")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    WorkshopSubscribeButton(item: item)
                    if let job = downloader.jobs.first(where: { $0.id == item.id }) { DownloadRow(job: job) }
                    if let installed = library.item(id: item.id) {
                        Button { actions.onSelect(installed) } label: {
                            Label("设为桌面壁纸", systemImage: "play.fill").font(.system(size: 12, weight: .semibold))
                                .frame(maxWidth: .infinity).padding(.vertical, 11)
                                .background(WorkshopStyle.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                        }.buttonStyle(.plain).foregroundStyle(WorkshopStyle.accent)
                    }
                    HStack {
                        stat("文件大小", value: item.sizeBytes > 0 ? ByteCountFormatter.string(fromByteCount: item.sizeBytes, countStyle: .file) : "待确认")
                        Spacer()
                        stat("订阅人数", value: item.subscribers > 0 ? item.subscribers.formatted() : "—")
                    }.padding(13).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 11))
                    if !item.tags.isEmpty {
                        Text(item.tags.joined(separator: "  ·  ")).font(.system(size: 10)).foregroundStyle(WorkshopStyle.accent.opacity(0.8))
                            .lineSpacing(5)
                    }
                    Divider().opacity(0.5)
                    Text("关于这张壁纸").font(.system(size: 12, weight: .semibold))
                    if browser.loadingDetail { ProgressView("加载说明…").controlSize(.small) }
                    if let error = browser.detailError { Text(error).font(.caption).foregroundStyle(.secondary) }
                    if !item.summary.isEmpty { Text(item.summary).font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(5).textSelection(.enabled) }
                    Button { NSWorkspace.shared.open(item.detailURL) } label: { Label("在 Steam 中查看", systemImage: "arrow.up.right.square") }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(WorkshopStyle.accent)
                }.padding(.horizontal, 18).padding(.bottom, 24)
            }
        }.background(WorkshopStyle.panel.opacity(0.6))
    }
    private func stat(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 9)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 12, weight: .semibold)).monospacedDigit()
        }
    }
}

private struct WorkshopPageNavigator: View {
    let page: Int
    let totalPages: Int
    let select: (Int) -> Void
    @State private var draft = ""

    private var target: Int? {
        guard let number = Int(draft.trimmingCharacters(in: .whitespacesAndNewlines)),
              (1...totalPages).contains(number), number != page else { return nil }
        return number
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 10) {
                Button { select(page - 1) } label: { Image(systemName: "chevron.left") }
                    .disabled(page <= 1).help("上一页").accessibilityLabel("上一页")
                Text("第 \(page.formatted()) / \(totalPages.formatted()) 页")
                    .monospacedDigit().fixedSize()
                Button { select(page + 1) } label: { Image(systemName: "chevron.right") }
                    .disabled(page >= totalPages).help("下一页").accessibilityLabel("下一页")
                Spacer(minLength: 8)
                TextField("页码", text: $draft)
                    .textFieldStyle(.roundedBorder).frame(width: 55)
                    .accessibilityLabel("跳转到页码").help("输入 1 至 \(totalPages) 的页码，按回车跳转")
                    .onSubmit { submit() }
                Button("跳转", action: submit).disabled(target == nil)
            }
            .controlSize(.small).font(.caption)
            .padding(.horizontal, 16).padding(.vertical, 9)
        }.onChange(of: page) { _ in draft = "" }
    }
    private func submit() {
        if let target { select(target) }
    }
}

private struct WorkshopCatalogCard: View {
    let item: WorkshopWallpaper
    let selected: Bool
    let installed: Bool
    let onSelect: () -> Void
    @ObservedObject private var downloader = WorkshopDownloader.shared
    @State private var hovered = false
    private var kind: String { item.tags.first(where: { ["Scene", "Video", "Web", "Application"].contains($0) }) ?? "Wallpaper" }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onSelect) {
                VStack(alignment: .leading, spacing: 0) {
                    WorkshopArtwork(url: item.previewURL, fill: true).aspectRatio(16.0 / 10.0, contentMode: .fit)
                        .overlay(alignment: .topLeading) {
                            Text(kind).font(.system(size: 8, weight: .semibold)).padding(.horizontal, 7).padding(.vertical, 4)
                                .background(.black.opacity(0.5), in: Capsule()).padding(10)
                        }
                        .overlay(alignment: .bottomTrailing) {
                            if installed {
                                Label("已入库", systemImage: "checkmark.circle.fill").font(.system(size: 9, weight: .medium))
                                    .padding(.horizontal, 7).padding(.vertical, 4).background(.black.opacity(0.6), in: Capsule()).padding(9)
                            }
                        }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.title).font(.system(size: 12, weight: .semibold)).lineLimit(2).frame(height: 32, alignment: .topLeading)
                        Text(item.author.isEmpty ? "Steam 创意工坊" : item.author).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }.padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 10)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("查看壁纸：\(item.title)")
            HStack(spacing: 7) {
                Label(item.subscribers > 0 ? item.subscribers.formatted(.number.notation(.compactName)) : "创意工坊", systemImage: "person.2")
                    .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
                WorkshopSubscribeButton(item: item, compact: true)
            }.padding(.horizontal, 12).padding(.bottom, 12)
            if let job = downloader.jobs.first(where: { $0.id == item.id }), WorkshopDownloader.isActive(job.state) {
                HStack {
                    Text(job.compactStatus)
                    Spacer()
                    Text(job.attempt > 1 ? "第 \(job.attempt) 次尝试" : "正在获取壁纸")
                }.font(.system(size: 9)).foregroundStyle(WorkshopStyle.accent).padding(.horizontal, 12).padding(.bottom, 7)
                ProgressView(value: job.fraction).controlSize(.mini).tint(WorkshopStyle.accent).padding(.horizontal, 12).padding(.bottom, 12)
            }
        }
        .background(WorkshopStyle.panel, in: RoundedRectangle(cornerRadius: 13))
        .clipShape(RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(selected ? WorkshopStyle.accent : .white.opacity(hovered ? 0.22 : 0.065), lineWidth: selected ? 1.5 : 1))
        .shadow(color: .black.opacity(hovered ? 0.22 : 0), radius: 12, y: 5)
        .onHover { hovered = $0 }
    }
}

private struct WorkshopSubscribeButton: View {
    let item: WorkshopWallpaper
    var compact = false
    @ObservedObject private var subscriptions = WorkshopSubscriptions.shared
    @State private var hovering = false
    private var subscribed: Bool { subscriptions.isSubscribed(item) }
    private var operation: WorkshopSubscriptions.Operation? { subscriptions.operations[item.id] }
    private var label: String {
        switch operation {
        case .subscribing: return "正在订阅…"
        case .unsubscribing: return "正在退订…"
        case .removing: return "正在删除…"
        case nil: return subscribed ? (hovering ? (compact ? "退订" : "取消订阅并删除") : "已订阅") : (compact ? "订阅" : "订阅并下载")
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { subscriptions.toggle(item) } label: {
                HStack(spacing: 5) {
                    if operation != nil { ProgressView().controlSize(.mini) }
                    else { Image(systemName: subscribed ? (hovering ? "minus" : "checkmark") : "plus") }
                    Text(label).lineLimit(1)
                }.font(.system(size: compact ? 10 : 12, weight: .semibold))
                    .frame(maxWidth: compact ? nil : .infinity)
                    .padding(.horizontal, compact ? 10 : 14).padding(.vertical, compact ? 7 : 12)
                    .foregroundStyle(subscribed ? Color.green.opacity(0.9) : (compact ? WorkshopStyle.accent : WorkshopStyle.background))
                    .background(subscribed ? Color.green.opacity(0.09) : (compact ? WorkshopStyle.accent.opacity(0.10) : WorkshopStyle.accent),
                                in: RoundedRectangle(cornerRadius: compact ? 7 : 10))
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(operation != nil).onHover { hovering = $0 }
                .help(subscribed ? "再次点击：取消 Steam 订阅并将本地壁纸移到废纸篓" : "订阅到 Steam 并立即加入下载队列")
                .accessibilityLabel(subscribed ? "取消订阅并删除：\(item.title)" : "订阅并下载：\(item.title)")
            if let error = subscriptions.errors[item.id] {
                Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                if error.hasPrefix("已取消订阅，本地卸载失败") {
                    Button("重试删除本地文件") { subscriptions.retryRemoval(item) }.font(.caption)
                }
            }
        }
    }
}

private struct WorkshopArtwork: View {
    let url: URL?
    var fill = false
    @State private var image: NSImage?
    @State private var requestedURL: URL?
    var body: some View {
        GeometryReader { geo in
            ZStack {
                Rectangle().fill(LinearGradient(colors: [WorkshopStyle.panel, .black.opacity(0.45)], startPoint: .topLeading, endPoint: .bottomTrailing))
                if let image {
                    if fill { Image(nsImage: image).resizable().scaledToFill() }
                    else { Image(nsImage: image).resizable().scaledToFit() }
                } else { Image(systemName: "photo").font(.system(size: 25)).foregroundStyle(.white.opacity(0.12)) }
            }.frame(width: geo.size.width, height: geo.size.height).clipped()
        }.onAppear { load() }.onChange(of: url) { _ in load() }
    }
    private func load() {
        guard requestedURL != url else { return }
        requestedURL = url; image = nil
        guard let url else { return }
        ThumbnailCache.shared.remoteThumbnail(for: url) { result in if requestedURL == url { image = result } }
    }
}
