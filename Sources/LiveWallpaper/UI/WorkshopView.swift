import SwiftUI

struct WorkshopView: View {
    @ObservedObject var library: WallpaperLibrary
    let actions: LibraryActions
    @ObservedObject private var browser = SteamWorkshopBrowser.shared
    @ObservedObject private var bridge = SteamWorkshopSubscriptionBridge.shared
    @ObservedObject private var subscriptions = WorkshopSubscriptions.shared
    @ObservedObject private var downloader = WorkshopDownloader.shared
    @State private var address = ""
    @State private var invalidAddress = false
    @State private var showTransfers = false
    @State private var showPagePicker = false
    @State private var pageDraft = ""
    @State private var serverDetail: WorkshopWallpaper?
    @FocusState private var editingAddress: Bool

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if invalidAddress {
                message("请输入 Steam 官方网址、工坊编号或搜索词") {
                    Button("关闭") { invalidAddress = false }
                }
            }
            if let error = browser.loadingError {
                message("Steam 网页加载失败：\(error)") { Button("重试") { browser.reload() } }
            }
            if let item = detailItem, let error = subscriptions.errors[item.id] {
                message(error) {
                    if item.isSubscribed == false, error.hasPrefix("已取消订阅，本地卸载失败") {
                        Button("重试删除") { subscriptions.retryRemoval(item) }
                    }
                }
            }
            Divider()
            SteamWorkshopWebView(browser: browser)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(WaifuTheme.background)
        .onAppear { subscriptions.refresh() }
        .task(id: browser.isLoading ? nil : SteamWorkshopSubscriptionBridge.itemID(in: browser.url)) {
            serverDetail = nil
            guard !browser.isLoading, let id = SteamWorkshopSubscriptionBridge.itemID(in: browser.url),
                  bridge.detail(for: browser.url) == nil else { return }
            let item = await SteamWorkshopSubscriptionStatus.lookup(id: id, in: browser.webView)
            if !Task.isCancelled { serverDetail = item }
        }
        .onReceive(NotificationCenter.default.publisher(for: .steamSubscriptionsDidChange)) { _ in subscriptions.refresh() }
        .sheet(isPresented: $showTransfers) { DownloadsView(embedded: true).frame(width: 620, height: 540) }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            toolButton("后退", icon: "chevron.left", action: browser.goBack).disabled(!browser.canGoBack)
            toolButton("前进", icon: "chevron.right", action: browser.goForward).disabled(!browser.canGoForward)
            toolButton("工坊首页", icon: "house", action: browser.goHome)
            toolButton("重新加载", icon: "arrow.clockwise", action: browser.reload)
            HStack(spacing: 8) {
                if browser.isLoading {
                    ProgressView().controlSize(.small).frame(width: 16)
                } else {
                    Image(systemName: editingAddress ? "magnifyingglass" : "lock.fill")
                        .font(.caption).foregroundStyle(.secondary)
                }
                TextField(editingAddress ? "搜索壁纸或粘贴 Steam 链接" : (browser.url?.host ?? "steamcommunity.com"),
                          text: $address)
                    .textFieldStyle(.plain)
                    .accessibilityLabel("搜索壁纸或粘贴 Steam 链接")
                    .focused($editingAddress)
                    .onSubmit { submitAddress() }
            }
            .padding(.horizontal, 10).frame(height: 30)
            .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
            .onChange(of: editingAddress) { focused in if !focused { address = "" } }

            if let url = browser.url, let page = WorkshopWebAddress.currentPage(at: url) {
                Button("第 \(page) 页") {
                    pageDraft = ""
                    showPagePicker = true
                }
                .help("跳转到指定页")
                .popover(isPresented: $showPagePicker) {
                    HStack {
                        TextField("输入页码", text: $pageDraft).frame(width: 85)
                            .onSubmit { goToPage(at: url) }
                        Button("跳转") { goToPage(at: url) }
                            .disabled(WorkshopWebAddress.pageURL(pageDraft, from: url) == nil)
                    }.padding(12)
                }
            }
            if let item = detailItem {
                if let installed = library.item(id: item.id) {
                    Button("设为桌面") { actions.onSelect(installed) }
                } else if item.isSubscribed == true,
                          subscriptions.operations[item.id] == nil,
                          !downloader.jobs.contains(where: { $0.id == item.id && WorkshopDownloader.isActive($0.state) }) {
                    Button("补下载") { subscriptions.retryDownload(item) }
                        .help("下载已订阅的壁纸到本机")
                }
            }
            Button { showTransfers = true } label: {
                Label(downloader.pendingCount > 0 ? "下载中心 (\(downloader.pendingCount))" : "下载中心",
                      systemImage: "arrow.down.circle")
            }
            if let url = browser.url, SteamWorkshopBrowser.isSteamPage(url) {
                Link(destination: url) { Image(systemName: "safari").frame(width: 22, height: 24) }
                    .accessibilityLabel("在浏览器中打开").help("在浏览器中打开当前 Steam 页面")
            }
        }
        .buttonStyle(.borderless).lineLimit(1)
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    private var detailItem: WorkshopWallpaper? {
        if let item = bridge.detail(for: browser.url) { return item }
        guard let serverDetail, SteamWorkshopSubscriptionBridge.itemID(in: browser.url) == serverDetail.id else { return nil }
        return serverDetail
    }

    private func toolButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).frame(width: 22, height: 24) }
            .accessibilityLabel(title).help(title)
    }

    private func message<Controls: View>(_ text: String, @ViewBuilder controls: () -> Controls) -> some View {
        HStack {
            Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
            Text(text).font(.callout)
            Spacer()
            controls()
        }.padding(.horizontal, 16).padding(.vertical, 6)
    }

    private func submitAddress() {
        guard !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard let url = WorkshopWebAddress.destination(for: address) else { invalidAddress = true; return }
        invalidAddress = false
        editingAddress = false
        address = ""
        browser.open(url)
    }

    private func goToPage(at url: URL) {
        guard browser.url == url, let destination = WorkshopWebAddress.pageURL(pageDraft, from: url) else { return }
        showPagePicker = false
        browser.open(destination)
    }
}

@MainActor
enum WorkshopWebAddress {
    static func detailURL(_ id: String) -> URL? {
        guard WallpaperUninstallPolicy.isSteamWorkshopID(id), UInt64(id) != nil else { return nil }
        return URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=\(id)&l=schinese")
    }

    static func browseURL(for sort: WorkshopFeed.Sort) -> URL {
        var items = [URLQueryItem(name: "browsesort", value: sort.browseValue),
                     URLQueryItem(name: "requiredtags[]", value: "Everyone")]
        if let days = sort.browseDays { items.append(URLQueryItem(name: "days", value: String(days))) }
        return browseURL(queryItems: items)
    }

    private static func browseURL(queryItems: [URLQueryItem]) -> URL {
        var components = URLComponents(string: "https://steamcommunity.com/workshop/browse/")!
        components.queryItems = [URLQueryItem(name: "appid", value: "431960"),
                                 URLQueryItem(name: "l", value: "schinese")] + queryItems
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }

    static func destination(for input: String) -> URL? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if let detail = detailURL(value) { return detail }
        if value.contains("://") {
            guard let url = URL(string: value), SteamWorkshopBrowser.isSteamPage(url) else { return nil }
            return url
        }
        if let url = URL(string: "https://\(value)"), SteamWorkshopBrowser.isSteamPage(url) { return url }
        return browseURL(queryItems: [URLQueryItem(name: "searchtext", value: value)])
    }

    static func currentPage(at url: URL) -> Int? {
        guard SteamWorkshopBrowser.isSteamPage(url), url.host?.lowercased() == "steamcommunity.com",
              ["/workshop/browse", "/workshop/browse/"].contains(url.path),
              let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              query.contains(URLQueryItem(name: "appid", value: "431960")) else { return nil }
        return max(1, Int(query.first(where: { $0.name == "p" })?.value ?? "") ?? 1)
    }

    static func pageURL(_ input: String, from url: URL) -> URL? {
        guard currentPage(at: url) != nil, let page = Int(input.trimmingCharacters(in: .whitespacesAndNewlines)),
              page > 0, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        var items = (components.percentEncodedQueryItems ?? []).filter { $0.name != "p" }
        items.append(URLQueryItem(name: "p", value: String(page)))
        components.percentEncodedQueryItems = items
        return components.url
    }
}
