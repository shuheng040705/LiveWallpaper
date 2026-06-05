import SwiftUI

/// 单个下载任务的进度行:进度条 + 状态/大小/速度 + 取消按钮。
/// 工坊页内嵌栏与「下载管理」窗口共用。
///
/// 关于「实时进度」:steamcmd 的 `workshop_download_item` 不在 stdout 报进度,下载文件还是
/// 预分配+非稀疏的(看文件大小会瞬间跳满),所以真实进度从 Steam 的 content_log.txt 解析得到
/// (见 WorkshopDownloader.pollLog)。拿到采样后显示**真实**百分比/已下载-总大小/实时速度;
/// 还没采样时(连接中、或大文件预分配阶段、或小文件秒下)回退到不确定进度条(只表示「进行中」)。
/// 完成时显示 steamcmd 报的**真实**总大小与**真实**平均速度(总字节 ÷ 真实耗时)。
struct DownloadRow: View {
    let job: WorkshopDownloader.Job
    private let accent = Color(red: 0.92, green: 0.36, blue: 0.62)

    var body: some View {
        switch job.state {
        case .connecting, .downloading:
            // 进行中:用 ~16fps 的 TimelineView 驱动进度条动画 + 刷新已用时长/进度。
            TimelineView(.periodic(from: .now, by: 0.06)) { ctx in
                content(now: ctx.date)
            }
        default:
            content(now: Date())
        }
    }

    private func content(now: Date) -> some View {
        let elapsed = isActive ? (job.startTime.map { max(0, now.timeIntervalSince($0)) } ?? 0) : job.elapsed
        return VStack(spacing: 6) {
            HStack(spacing: 8) {
                statusIcon
                Text(job.title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                Spacer()
                Text(rightText(elapsed: elapsed))
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(textColor)
                if isActive {
                    Button { WorkshopDownloader.shared.requestCancel(id: job.id) } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14)).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain).help("取消下载")
                }
            }
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.12))
                    if !isActive {
                        // 终态:满条,用颜色表状态(完成绿 / 失败橙 / 取消灰)。
                        Capsule().fill(barColor).frame(width: w)
                    } else if let frac = displayedFraction(now: now) {
                        // 真实进度:按比例填充。
                        Capsule().fill(accent).frame(width: max(0, w * frac))
                    } else {
                        // 还没拿到真实采样:一段高亮来回滑动,只表示「进行中」。
                        let segW = max(40, w * 0.30)
                        let cycle = 1.3
                        let p = now.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: cycle) / cycle
                        let x = -segW + (w + segW) * p
                        Capsule().fill(accent).frame(width: segW)
                            .offset(x: min(w, max(-segW, x)))
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 5)
        }
    }

    /// 显示用的完成比例:在真实采样基础上用实时速度做轻微外推(让进度条在两次采样间隔里也动),
    /// 外推量封顶 +0.3 且整体 ≤0.99,避免下载停滞时假装跑到头。无真实采样时返回 nil → 不确定进度条。
    private func displayedFraction(now: Date) -> Double? {
        guard let f = job.fraction else { return nil }
        guard let st = job.lastSampleTime, job.liveSpeedMBps > 0.001, job.effectiveTotal > 0 else { return f }
        let dt = max(0, now.timeIntervalSince(st))
        let add = job.liveSpeedMBps * 1_048_576 * dt / Double(job.effectiveTotal)
        return min(f + min(add, 0.3), 0.99)
    }

    private func rightText(elapsed: TimeInterval) -> String {
        switch job.state {
        case .queued: return "排队中"
        case .connecting: return "连接 Steam…"
        case .downloading:
            // 有真实采样:百分比 + 已下载/总大小 + 实时速度(都是真实值,不编)。
            if let f = job.fraction {
                if job.liveSpeedMBps > 0.05 {
                    return String(format: "%d%% · %.0f/%.0f MB · %.1f MB/s",
                                  Int(f * 100), job.downloadedMB, job.sizeMB, job.liveSpeedMBps)
                }
                return String(format: "%d%% · %.0f/%.0f MB", Int(f * 100), job.downloadedMB, job.sizeMB)
            }
            // 还没采样(大文件预分配阶段 / 小文件秒下):显示已用时长 + 已知总大小。
            if job.sizeMB > 0.1 {
                return String(format: "下载中 %ds · %.0f MB", Int(elapsed), job.sizeMB)
            }
            return String(format: "下载中 %ds…", Int(elapsed))
        case .done:
            if job.sizeMB > 0.1 && job.avgSpeedMBps > 0.1 {
                return String(format: "完成 ✓ %.0f MB · %.1f MB/s", job.sizeMB, job.avgSpeedMBps)
            }
            return "完成 ✓ 已进库"
        case .cancelled: return "已取消"
        case .failed(let r): return "失败:\(r)"
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch job.state {
        case .queued:
            Image(systemName: "clock").font(.system(size: 12)).foregroundStyle(.secondary)
        case .connecting, .downloading:
            Image(systemName: "arrow.down.circle.fill").font(.system(size: 12)).foregroundStyle(accent)
        case .done:
            Image(systemName: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(.green)
        case .cancelled:
            Image(systemName: "stop.circle.fill").font(.system(size: 12)).foregroundStyle(.secondary)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(.orange)
        }
    }

    private var barColor: Color {
        switch job.state {
        case .done: return .green
        case .failed: return .orange
        case .cancelled: return .gray
        default: return accent
        }
    }

    private var textColor: Color {
        switch job.state {
        case .done: return .green
        case .failed: return .orange
        default: return .secondary
        }
    }

    private var isActive: Bool {
        switch job.state { case .queued, .connecting, .downloading: return true; default: return false }
    }
}
