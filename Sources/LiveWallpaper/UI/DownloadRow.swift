import SwiftUI

/// 单项真实进度；错误保持可见，取消、重试只作用于这一项。
struct DownloadRow: View {
    let job: WorkshopDownloader.Job
    private let accent = Color(red: 0.35, green: 0.82, blue: 0.91)
    private var active: Bool { WorkshopDownloader.isActive(job.state) }
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: icon).font(.system(size: 17)).foregroundStyle(color)
                        .frame(width: 32, height: 32).background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))
                    VStack(alignment: .leading, spacing: 5) {
                        Text(job.title).font(.system(size: 12, weight: .semibold)).lineLimit(2)
                        Text(status(now: context.date)).font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
                    }
                    Spacer(minLength: 0)
                    if active {
                        action("xmark", help: "取消下载", label: "取消下载：" + job.title) { WorkshopDownloader.shared.requestCancel(id: job.id) }
                    } else if case .done = job.state {
                        Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(.green)
                    } else {
                        action("arrow.clockwise", help: "继续下载", label: "重试下载：" + job.title) { WorkshopDownloader.shared.retry(id: job.id) }
                        action("trash", help: "移除任务及暂存文件", label: "移除下载：" + job.title) { WorkshopDownloader.shared.remove(id: job.id) }
                    }
                }
                if active {
                    if job.state == .queued { Capsule().fill(.white.opacity(0.08)).frame(height: 4) }
                    else { ProgressView(value: job.fraction).controlSize(.small).tint(accent) }
                    HStack {
                        Text(job.fraction.map { String(format: "%d%%", Int($0 * 100)) } ?? job.compactStatus)
                        Spacer()
                        if job.liveSpeedMBps > 0.01 { Text(String(format: "%.1f MB/s", job.liveSpeedMBps)) }
                        else if job.effectiveTotal > 0 { Text(ByteCountFormatter.string(fromByteCount: job.effectiveTotal, countStyle: .file)) }
                    }.font(.system(size: 9)).monospacedDigit().foregroundStyle(.secondary)
                }
                if case .failed(let error) = job.state {
                    Text(error).font(.system(size: 10)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }.padding(14).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.065)))
        }
    }
    private func action(_ icon: String, help: String, label: String, run: @escaping () -> Void) -> some View {
        Button(action: run) { Image(systemName: icon).font(.system(size: 11)).frame(width: 25, height: 25)
                .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 7)) }
            .buttonStyle(.plain).foregroundStyle(.secondary).help(help).accessibilityLabel(label)
    }
    private func status(now: Date) -> String {
        switch job.state {
        case .queued: return job.phase == .subscribing ? "正在同步订阅" : "等待空闲下载通道"
        case .connecting:
            let elapsed = Int((job.phaseStartedAt ?? job.startTime).map { max(0, now.timeIntervalSince($0)) } ?? 0)
            return job.compactStatus + " · \(elapsed) 秒" + (job.attempt > 1 ? " · 第 \(job.attempt) 次尝试" : "")
        case .downloading:
            if job.phase == .installing { return "下载完成，正在加入壁纸库" }
            if job.effectiveDownloadedBytes > 0 {
                return ByteCountFormatter.string(fromByteCount: job.effectiveDownloadedBytes, countStyle: .file) + " / " + ByteCountFormatter.string(fromByteCount: job.effectiveTotal, countStyle: .file)
            }
            return "正在接收壁纸文件"
        case .done: return "已加入壁纸库 · " + ByteCountFormatter.string(fromByteCount: job.effectiveTotal, countStyle: .file)
        case .cancelled: return "已取消"
        case .failed: return "下载未完成 · 可继续重试"
        }
    }
    private var icon: String {
        switch job.state {
        case .queued: return "clock"
        case .connecting, .downloading: return "arrow.down"
        case .done: return "checkmark.circle"
        case .cancelled: return "stop.circle"
        case .failed: return "exclamationmark.triangle"
        }
    }
    private var color: Color {
        switch job.state {
        case .done: return .green
        case .failed: return .orange
        case .cancelled, .queued: return .secondary
        default: return accent
        }
    }
}
