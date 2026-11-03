import SwiftUI

/// 原生创意工坊，目录、筛选、详情和订阅按钮使用同一窗口坐标系。
struct WorkshopView: View {
    @ObservedObject var library: WallpaperLibrary
    let actions: LibraryActions
    @ObservedObject private var browser = WorkshopBrowserModel.shared
    @ObservedObject private var subscriptions = WorkshopSubscriptions.shared
    @ObservedObject private var downloader = WorkshopDownloader.shared

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HStack(spacing: 0) {
                filters.frame(width: 174)
                Divider()
                catalog.frame(maxWidth: .infinity, maxHeight: .infinity)
                if let item = browser.selection {
                    Divider()
                    detail(item).frame(width: 316)
                }
            }
        }
        .task { browser.loadIfNeeded(); subscriptions.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .steamSubscriptionsDidChange)) { _ in subscriptions.refresh() }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索壁纸，或粘贴工坊链接", text: $browser.search)
                    .textFieldStyle(.plain).onSubmit { browser.searchSubmitted() }
                if !browser.search.isEmpty {
                    Button { browser.search = ""; browser.reload() } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("清除搜索")
                }
            }
            .padding(9).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            Button("搜索") { browser.searchSubmitted() }
            Picker("排序", selection: $browser.sort) {
                Text("本周最热").tag("trend")
                Text("评分最高").tag("toprated")
                Text("最新发布").tag("mostrecent")
                Text("最近更新").tag("lastupdated")
                Text("最多订阅").tag("totaluniquesubscribers")
            }
            .labelsHidden().frame(width: 122).onChange(of: browser.sort) { _ in browser.reload() }
            Button { browser.reload(); subscriptions.refresh() } label: { Image(systemName: "arrow.clockwise") }
                .help("刷新创意工坊")
            Button { NotificationCenter.default.post(name: .showDownloads, object: nil) } label: {
                Label(downloader.pendingCount > 0 ? "下载 \(downloader.pendingCount)" : "下载管理", systemImage: "arrow.down.circle")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var filters: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("筛选").font(.headline)
                    Spacer()
                    Button("重置") { browser.resetFilters() }.font(.caption).buttonStyle(.plain)
                }
                ForEach(browser.groups) { group in
                    VStack(alignment: .leading, spacing: 7) {
                        Text(group.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Picker(group.title, selection: Binding(
                            get: { browser.filters[group.id] ?? "" },
                            set: { browser.filters[group.id] = $0; browser.reload() }
                        )) {
                            Text("全部").tag("")
                            ForEach(group.tags) { tag in Text(tag.title).tag(tag.id) }
                        }.labelsHidden().frame(maxWidth: .infinity).accessibilityLabel(group.title)
                    }
                }
                Divider()
                Button {
                    SteamWebLoginWindowController.shared.authorize { _ in subscriptions.refresh() }
                } label: { Label("Steam 网页授权", systemImage: "person.crop.circle") }
                .font(.caption).buttonStyle(.plain)
                Button {
                    NSWorkspace.shared.open(URL(string: "https://steamcommunity.com/app/431960/workshop/")!)
                } label: { Label("在 Steam 中打开", systemImage: "arrow.up.right.square") }
                .font(.caption).buttonStyle(.plain)
            }.padding(14)
        }.background(.black.opacity(0.12))
    }

    private var catalog: some View {
        VStack(spacing: 0) {
            HStack {
                Text("创意工坊").font(.title3.weight(.semibold))
                Text(browser.total > 0 ? "\(browser.total.formatted()) 个结果" : "来自 Steam 创意工坊")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if browser.loading { ProgressView().controlSize(.small) }
            }.padding(16)
            if let error = browser.error {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text(error).font(.callout)
                    Spacer()
                    Button("重试") { browser.reload() }
                }.padding(12).background(.orange.opacity(0.08))
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 192, maximum: 300), spacing: 14)], spacing: 16) {
                    ForEach(browser.items) { item in
                        WorkshopCatalogCard(item: item, selected: browser.selection?.id == item.id,
                                     installed: library.item(id: item.id) != nil,
                                     onSelect: { browser.select(item) })
                    }
                }.padding(.horizontal, 16).padding(.bottom, 16)
                if !browser.loading && browser.items.isEmpty && browser.error == nil {
                    VStack(spacing: 10) {
                        Image(systemName: "magnifyingglass").font(.largeTitle).foregroundStyle(.secondary)
                        Text("没有找到匹配的壁纸")
                        Button("清除筛选") { browser.resetFilters() }
                    }.padding(40)
                }
                if browser.page < browser.totalPages && !browser.items.isEmpty {
                    Button(browser.loading ? "正在加载…" : "加载更多") { browser.loadMore() }
                        .disabled(browser.loading).padding(.bottom, 20)
                }
            }
        }
    }

    private func detail(_ item: WorkshopWallpaper) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("壁纸详情").font(.headline)
                Spacer()
                Button { browser.closeDetail() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).help("关闭详情")
            }.padding(16)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    WorkshopArtwork(url: item.previewURL).aspectRatio(16.0 / 10.0, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 9))
                    Text(item.title).font(.title3.weight(.semibold)).textSelection(.enabled)
                    if !item.author.isEmpty { Text("创作者：\(item.author)").font(.callout).foregroundStyle(.secondary) }
                    WorkshopSubscribeButton(item: item)
                    if let job = downloader.jobs.first(where: { $0.id == item.id }) {
                        DownloadRow(job: job)
                        if case .failed = job.state { Button("重试下载") { subscriptions.retryDownload(item) } }
                    }
                    if let installed = library.item(id: item.id) {
                        Button { actions.onSelect(installed) } label: {
                            Label("设为壁纸", systemImage: "play.fill").frame(maxWidth: .infinity)
                        }.buttonStyle(.bordered)
                    }
                    HStack {
                        Label(item.sizeBytes > 0 ? ByteCountFormatter.string(fromByteCount: item.sizeBytes, countStyle: .file) : "大小待确认",
                              systemImage: "internaldrive")
                        Spacer()
                        if item.subscribers > 0 { Label(item.subscribers.formatted(), systemImage: "person.2") }
                    }.font(.caption).foregroundStyle(.secondary)
                    if !item.tags.isEmpty { Text(item.tags.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }
                    Divider()
                    if browser.loadingDetail { ProgressView("加载完整说明…").controlSize(.small) }
                    if let error = browser.detailError { Text(error).font(.caption).foregroundStyle(.secondary) }
                    if !item.summary.isEmpty { Text(item.summary).font(.callout).textSelection(.enabled) }
                    Button { NSWorkspace.shared.open(item.detailURL) } label: {
                        Label("在 Steam 中打开原页", systemImage: "arrow.up.right.square")
                    }.buttonStyle(.link)
                }.padding(.horizontal, 16).padding(.bottom, 20)
            }
        }.background(.black.opacity(0.12))
    }
}

private struct WorkshopCatalogCard: View {
    let item: WorkshopWallpaper
    let selected: Bool
    let installed: Bool
    let onSelect: () -> Void
    @ObservedObject private var downloader = WorkshopDownloader.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Button(action: onSelect) {
                VStack(alignment: .leading, spacing: 9) {
                    WorkshopArtwork(url: item.previewURL).aspectRatio(16.0 / 10.0, contentMode: .fit).clipped()
                    Text(item.title).font(.system(size: 13, weight: .semibold)).lineLimit(2).frame(height: 34, alignment: .topLeading)
                    HStack {
                        Text(item.author.isEmpty ? "Steam 创意工坊" : item.author).lineLimit(1)
                        Spacer()
                        if installed { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                    }.font(.caption).foregroundStyle(.secondary)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("查看壁纸：\(item.title)")
            WorkshopSubscribeButton(item: item)
            if let job = downloader.jobs.first(where: { $0.id == item.id }), WorkshopDownloader.isActive(job.state) {
                HStack {
                    Text(job.compactStatus).font(.caption)
                    Spacer()
                    if let fraction = job.fraction { Text(fraction, format: .percent.precision(.fractionLength(0))).font(.caption) }
                }.foregroundStyle(.secondary)
                ProgressView(value: job.fraction).controlSize(.small)
            }
        }
        .padding(10).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? Color.accentColor : .white.opacity(0.07), lineWidth: selected ? 2 : 1))
    }
}

private struct WorkshopSubscribeButton: View {
    let item: WorkshopWallpaper
    @ObservedObject private var subscriptions = WorkshopSubscriptions.shared
    @State private var hovering = false
    private var subscribed: Bool { subscriptions.isSubscribed(item) }
    private var operation: WorkshopSubscriptions.Operation? { subscriptions.operations[item.id] }
    private var label: String {
        switch operation {
        case .subscribing: return "正在订阅…"
        case .unsubscribing: return "正在取消订阅…"
        case .removing: return "正在删除本地文件…"
        case nil: return subscribed ? (hovering ? "取消订阅并删除" : "已订阅") : "订阅并下载"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { subscriptions.toggle(item) } label: {
                HStack(spacing: 6) {
                    if operation != nil { ProgressView().controlSize(.small) }
                    else { Image(systemName: subscribed ? "checkmark" : "plus") }
                    Text(label).lineLimit(1)
                }.frame(maxWidth: .infinity, minHeight: 22)
            }
            .buttonStyle(.borderedProminent).tint(subscribed ? Color.green : Color.accentColor)
            .disabled(operation != nil).onHover { hovering = $0 }
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
    @State private var image: NSImage?
    @State private var requestedURL: URL?
    var body: some View {
        ZStack {
            Rectangle().fill(.black.opacity(0.25))
            if let image { Image(nsImage: image).resizable().scaledToFit() }
            else { Image(systemName: "photo").font(.largeTitle).foregroundStyle(.tertiary) }
        }.onAppear { load() }.onChange(of: url) { _ in load() }
    }
    private func load() {
        guard requestedURL != url else { return }
        requestedURL = url; image = nil
        guard let url else { return }
        ThumbnailCache.shared.remoteThumbnail(for: url) { result in
            if requestedURL == url { image = result }
        }
    }
}
