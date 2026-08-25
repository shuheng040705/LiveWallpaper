import SwiftUI
import AppKit

/// 「设置 → 我的 Steam 订阅」点击后弹出的选择面板:列出账号订阅的全部工坊壁纸,
/// 标记已下载/未下载,可全选/批量勾选,一键批量下载未下载项(走现成 WorkshopDownloader 队列)。
@MainActor
final class SubscriptionsModel: ObservableObject {
    struct Row: Identifiable {
        let id: String
        var title: String
        var isInstalled: Bool
        var selected: Bool
        var thumb: NSImage? = nil
        var metaFetched = false
    }
    @Published var rows: [Row] = []
    @Published var loading = true
    @Published var noData = false
    @Published var isUnsubscribing = false
    @Published var unsubscribeError: String?
    private var pendingUnsubscribeCount = 0
    private var unsubscribeFailures: [String] = []

    var selectedCount: Int { rows.filter { $0.selected }.count }
    var notInstalledCount: Int { rows.filter { !$0.isInstalled }.count }

    func load() {
        loading = true; noData = false
        Task.detached(priority: .userInitiated) {
            let subs = SteamSubscriptions.loadSubscriptions()
            let rows: [Row] = subs.map { s in
                let installed = SteamSubscriptions.isInstalled(s.id)
                let title = installed ? (SteamSubscriptions.localTitle(s.id) ?? "创意工坊 #\(s.id)") : "创意工坊 #\(s.id)"
                return Row(id: s.id, title: title, isInstalled: installed, selected: !installed)
            }
            await MainActor.run {
                self.rows = rows
                self.loading = false
                self.noData = rows.isEmpty
            }
            // 已装项:加载本地预览缩略图
            for r in rows where r.isInstalled {
                if let purl = SteamSubscriptions.localPreviewURL(r.id) {
                    ThumbnailCache.shared.thumbnail(for: purl, maxPixel: 110) { img in
                        Task { @MainActor in self.setThumb(r.id, img) }
                    }
                }
            }
        }
    }

    private func setThumb(_ id: String, _ img: NSImage?) {
        guard let img, let i = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[i].thumb = img
    }

    /// 行可见时按需联网取未装项的标题+缩略图(best-effort)。
    func fetchMetaIfNeeded(_ id: String) {
        guard let idx = rows.firstIndex(where: { $0.id == id }), !rows[idx].metaFetched, !rows[idx].isInstalled else { return }
        rows[idx].metaFetched = true
        Task {
            let meta = await SteamSubscriptions.fetchRemoteMeta(id)
            await MainActor.run {
                if let t = meta.title, !t.isEmpty, let i = self.rows.firstIndex(where: { $0.id == id }) { self.rows[i].title = t }
            }
            if let thumb = meta.thumb {
                ThumbnailCache.shared.remoteThumbnail(for: thumb) { img in
                    Task { @MainActor in self.setThumb(id, img) }
                }
            }
        }
    }

    // 勾选不再限制已安装项:下载只作用于未安装项,取消订阅/删除则需要能勾选已安装项。
    func toggle(_ id: String) {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[i].selected.toggle()
    }
    func selectAll() { for i in rows.indices { rows[i].selected = true } }
    func selectNotInstalled() { for i in rows.indices { rows[i].selected = !rows[i].isInstalled } }
    func selectNone() { for i in rows.indices { rows[i].selected = false } }

    /// 批量下载选中且未安装的:逐个入队现成下载器(内部并发3/去重/进度/重试),然后打开下载管理窗。
    func downloadSelected() {
        let todo = rows.filter { $0.selected && !$0.isInstalled }
        for r in todo {
            WorkshopDownloader.shared.enqueue(id: r.id, title: r.title)
        }
        if !todo.isEmpty {
            NotificationCenter.default.post(name: .showDownloads, object: nil)
        }
    }

    /// 批量取消订阅 + 卸载本地壁纸(危险操作,调用方须先二次确认)。
    /// 每一项都必须先收到 Steam 退订成功，再通知 AppDelegate 移除本地文件并从列表删行；
    /// 失败项保持原样，防止仍处于订阅状态的壁纸被 Steam 自动下载回来。
    func unsubscribeSelected() {
        let todo = rows.filter { $0.selected }
        guard !todo.isEmpty, !isUnsubscribing else { return }
        isUnsubscribing = true
        pendingUnsubscribeCount = todo.count
        unsubscribeFailures.removeAll()

        SteamWebSession.shared.refresh { [weak self] authenticated in
            guard let self else { return }
            if authenticated {
                self.performUnsubscribe(todo)
            } else {
                SteamWebLoginWindowController.shared.authorize { [weak self] authorized in
                    guard let self else { return }
                    if authorized {
                        self.performUnsubscribe(todo)
                    } else {
                        self.unsubscribeFailures = ["未完成 Steam 网页订阅授权，未取消任何订阅。"]
                        self.pendingUnsubscribeCount = 0
                        self.isUnsubscribing = false
                        self.unsubscribeError = self.unsubscribeFailures[0]
                    }
                }
            }
        }
    }

    private func performUnsubscribe(_ todo: [Row]) {
        for r in todo {
            SteamSubscription.unsubscribe(id: r.id) { [weak self] outcome in
                guard let self else { return }
                switch outcome {
                case .success(let message):
                    Log.write("Unsubscribe \(r.id): OK — \(message)")
                    // 订阅已经在 Steam 侧取消，此通知只负责安全停止与本地卸载。
                    if r.isInstalled {
                        NotificationCenter.default.post(
                            name: .unsubscribeWallpaper,
                            object: nil,
                            userInfo: ["id": r.id]
                        )
                    }
                    self.rows.removeAll { $0.id == r.id }
                    self.noData = self.rows.isEmpty
                case .authenticationRequired:
                    Log.write("Unsubscribe \(r.id): Steam web authorization expired")
                    self.unsubscribeFailures.append("\(r.title)：Steam 网页授权已失效，请重新授权后重试")
                    SteamWebSession.shared.clearAuthenticationCookies()
                case .failure(let message):
                    Log.write("Unsubscribe \(r.id): fail — \(message)")
                    self.unsubscribeFailures.append("\(r.title)：\(message)")
                }

                self.pendingUnsubscribeCount -= 1
                if self.pendingUnsubscribeCount == 0 {
                    self.isUnsubscribing = false
                    if !self.unsubscribeFailures.isEmpty {
                        self.unsubscribeError = self.unsubscribeFailures.joined(separator: "\n")
                    }
                }
            }
        }
    }
}

struct SubscriptionsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = SubscriptionsModel()

    /// 在独立 NSWindow 里承载时,`dismiss()` 不会关窗;由窗口控制器注入此回调来真正关闭窗口。
    /// 仍以 sheet 呈现时为 nil,关闭按钮回退到 `dismiss()`。
    var onClose: (() -> Void)? = nil

    /// 关闭面板:优先用注入的 onClose(窗口模式),否则 dismiss(sheet 模式)。
    private func closePanel() {
        if let onClose { onClose() } else { dismiss() }
    }

    var body: some View {
        VStack(spacing: 0) {
            // 头部
            HStack {
                Text("我的 Steam 订阅").font(.headline)
                if !model.rows.isEmpty { Text("(\(model.rows.count))").foregroundStyle(.secondary) }
                Spacer()
                Button { closePanel() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
            }
            .padding(12)
            Divider()

            if model.loading {
                Spacer(); ProgressView("正在读取订阅…"); Spacer()
            } else if model.noData {
                Spacer()
                VStack(spacing: 10) {
                    Image(systemName: "tray").font(.largeTitle).foregroundStyle(.secondary)
                    Text("未检测到 Steam 订阅记录").foregroundStyle(.secondary)
                    Text("需先在 Steam 客户端登录过、且订阅过创意工坊壁纸").font(.caption).foregroundStyle(.secondary)
                    Button("选择 Steam 数据目录…") { chooseSteamFolder() }
                }
                Spacer()
            } else {
                // 工具条
                HStack(spacing: 8) {
                    Button("仅选未下载") { model.selectNotInstalled() }
                    Button("全选") { model.selectAll() }
                    Button("取消全选") { model.selectNone() }
                    Spacer()
                    Text("\(model.notInstalledCount) 个未下载").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                Divider()

                // 列表
                List {
                    ForEach(model.rows) { row in
                        HStack(spacing: 10) {
                            Image(systemName: row.selected ? "checkmark.square.fill" : "square")
                                .foregroundStyle(row.selected ? Color.accentColor : Color.secondary)
                                .onTapGesture { model.toggle(row.id) }
                            thumbView(row)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.title).lineLimit(1)
                                Text(row.id).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if row.isInstalled {
                                Label("已下载", systemImage: "checkmark.circle.fill")
                                    .labelStyle(.titleAndIcon).font(.caption).foregroundStyle(.green)
                            } else {
                                Text("未下载").font(.caption).foregroundStyle(.orange)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { model.toggle(row.id) }
                        .onAppear { model.fetchMetaIfNeeded(row.id) }
                    }
                }
                .listStyle(.inset)

                Divider()
                HStack {
                    Button(role: .destructive) {
                        // 批量删除也遵循“点击即执行”。每个条目仍由模型逐项先退订，
                        // 只有 Steam 确认成功的项目才会清理本地文件。
                        model.unsubscribeSelected()
                    } label: {
                        if model.isUnsubscribing {
                            HStack {
                                ProgressView().controlSize(.small)
                                Text("正在取消订阅…")
                            }
                        } else {
                            Label("取消订阅并卸载选中 (\(model.selectedCount))", systemImage: "trash")
                        }
                    }
                    .disabled(model.selectedCount == 0 || model.isUnsubscribing)
                    Spacer()
                    Button {
                        model.downloadSelected()
                        closePanel()
                    } label: {
                        Text("下载选中 (\(model.selectedCount))")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.selectedCount == 0 || model.isUnsubscribing)
                }
                .padding(12)
            }
        }
        .frame(minWidth: 420, idealWidth: 460, maxWidth: 1000,
               minHeight: 400, idealHeight: 560, maxHeight: .infinity)
        .task { if model.rows.isEmpty { model.load() } }
        .alert(
            "部分壁纸未能取消订阅",
            isPresented: Binding(
                get: { model.unsubscribeError != nil },
                set: { if !$0 { model.unsubscribeError = nil } }
            )
        ) {
            Button("知道了") { model.unsubscribeError = nil }
        } message: {
            Text((model.unsubscribeError ?? "") + "\n\n失败项目的本地文件均未删除。")
        }
    }

    @ViewBuilder
    private func thumbView(_ row: SubscriptionsModel.Row) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.12))
            if let t = row.thumb {
                Image(nsImage: t).resizable().scaledToFill()
            } else {
                Image(systemName: "photo").foregroundStyle(.secondary.opacity(0.5))
            }
        }
        .frame(width: 56, height: 32)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func chooseSteamFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "选择 Steam 数据目录(含 userdata 子目录)"
        if panel.runModal() == .OK, let url = panel.url {
            PreferencesStore.shared.steamDataPath = url.path
            model.load()
        }
    }
}
