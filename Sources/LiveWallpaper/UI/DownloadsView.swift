import SwiftUI

/// 「下载管理」窗口内容:集中查看所有下载任务的进度,可取消、清除已完成。
struct DownloadsView: View {
    var embedded = false
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var downloader = WorkshopDownloader.shared
    private let accent = Color(red: 0.35, green: 0.82, blue: 0.91)

    @State private var showLogin = false

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(spacing: 10) {
                metric("并行下载", value: "\(downloader.transferringCount)")
                metric("等待 / 准备", value: "\(downloader.queuedCount + downloader.preparingCount)")
                metric("同时下载", value: "最多 \(downloader.maximumConcurrentDownloads) 项")
            }.padding(.horizontal, 18).padding(.bottom, 18)
            Divider().opacity(0.3)
            if downloader.loginExpired { loginExpiredBanner }
            if downloader.jobs.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(downloader.jobs) { DownloadRow(job: $0) }
                    }
                    .padding(16)
                }
            }
        }
        .frame(minWidth: 480, minHeight: 440)
        .background(Color(red: 0.055, green: 0.065, blue: 0.085).ignoresSafeArea())
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showLogin) {
            SteamLoginSheet(onDone: { downloader.loginExpired = false })
        }
    }

    /// 账号登录失效提醒:点「重新登录」弹 Steam 登录,登录后即可重试下载。
    private var loginExpiredBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.crop.circle.badge.exclamationmark.fill")
                .font(.system(size: 16)).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("Steam 账号登录已失效").font(.system(size: 12.5, weight: .semibold))
                Text("缓存的登录令牌过期了,重新登录后即可继续下载").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Button { showLogin = true } label: {
                Text("重新登录").font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().fill(accent))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .background(Color.orange.opacity(0.12))
    }

    private var header: some View {
        HStack(spacing: 11) {
            Image(systemName: "arrow.down.circle.fill").font(.system(size: 19)).foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 1) {
                Text("下载中心").font(.system(size: 21, weight: .bold, design: .rounded))
                Text(statusLine).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            if downloader.jobs.contains(where: { isFinished($0.state) }) {
                Button { downloader.clearFinished() } label: {
                    Label("清除已完成", systemImage: "trash")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(0.07)))
            }
            if embedded {
                Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 11)).frame(width: 26, height: 26)
                        .background(.white.opacity(0.06), in: Circle()) }
                    .buttonStyle(.plain).help("关闭下载中心").accessibilityLabel("关闭下载中心")
            }
        }
        .padding(.horizontal, 18).padding(.top, 18).padding(.bottom, 14)
    }

    private var statusLine: String {
        let pending = downloader.pendingCount
        let done = downloader.jobs.filter { if case .done = $0.state { return true }; return false }.count
        if pending > 0 {
            return "\(pending) 个进行中" + (done > 0 ? " · \(done) 个已完成" : "")
        }
        return done > 0 ? "\(done) 个已完成" : "共 \(downloader.jobs.count) 个任务"
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray.and.arrow.down").font(.system(size: 40)).foregroundStyle(.tertiary)
            Text("暂无下载任务").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
            Text("在创意工坊点击「订阅」，即可开始并行下载").font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 30)
    }

    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 17, weight: .semibold, design: .rounded)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading).padding(13)
            .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 11))
    }

    private func isFinished(_ s: WorkshopDownloader.Job.State) -> Bool {
        switch s { case .done, .failed, .cancelled: return true; default: return false }
    }
}
