import SwiftUI

/// 「下载管理」窗口内容:集中查看所有下载任务的进度,可取消、清除已完成。
struct DownloadsView: View {
    @ObservedObject private var downloader = WorkshopDownloader.shared
    private let accent = Color(red: 0.92, green: 0.36, blue: 0.62)

    @State private var showLogin = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
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
        .background(VisualEffectView(material: .underWindowBackground).ignoresSafeArea())
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
                Text("下载管理").font(.system(size: 15, weight: .bold))
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
            Text("在创意工坊页进入壁纸详情,点「下载」即可添加").font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 30)
    }

    private func isFinished(_ s: WorkshopDownloader.Job.State) -> Bool {
        switch s { case .done, .failed, .cancelled: return true; default: return false }
    }
}
