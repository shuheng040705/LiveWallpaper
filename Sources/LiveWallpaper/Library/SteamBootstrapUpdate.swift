import Foundation

/// Watches only new bootstrap records from the process being launched. Valve installs updates
/// before processing +login. The normal login timeout measures idle time during that transfer.
struct SteamBootstrapUpdate {
    private var tail: SteamLogTail
    private let idleWindow: TimeInterval
    private let hardDeadline: Date
    private var highestKB: Int64 = 0
    private(set) var updating = false
    private(set) var completed = false
    private(set) var deadline: Date

    init(log: URL, start: Date, idleWindow: TimeInterval, maximumDuration: TimeInterval = 600) {
        tail = SteamLogTail(url: log)
        self.idleWindow = idleWindow
        deadline = start.addingTimeInterval(idleWindow)
        hardDeadline = start.addingTimeInterval(max(maximumDuration, idleWindow))
    }

    // Examples: "Downloading update (2,322 of 15,851 KB)..." and
    // "正在下载更新 (已下载 2,322，共 15,851 KB)...".
    private static let progress = try! NSRegularExpression(
        pattern: #"(?:Downloading update|正在下载更新)\s*[（(](?:已下载\s*)?([0-9][0-9,]*)\s*(?:of|，共)\s*([0-9][0-9,]*)\s*KB[）)]"#,
        options: .caseInsensitive
    )

    mutating func poll(now: Date) {
        for line in tail.readLines() { consume(line, now: now) }
    }

    private mutating func consume(_ line: String, now: Date) {
        if line.localizedCaseInsensitiveContains("Update complete, launching Steamcmd") ||
            line.contains("更新完成，正在启动 Steamcmd") {
            updating = true
            completed = true
            return
        }
        let text = line as NSString
        guard let match = Self.progress.firstMatch(in: line, range: NSRange(location: 0, length: text.length)),
              let current = Int64(text.substring(with: match.range(at: 1)).replacingOccurrences(of: ",", with: "")),
              let total = Int64(text.substring(with: match.range(at: 2)).replacingOccurrences(of: ",", with: "")),
              total > 0, current <= total else { return }
        updating = true
        guard current > highestKB else { return }
        highestKB = current
        deadline = min(hardDeadline, now.addingTimeInterval(idleWindow))
    }

    func needsRelaunch(afterExit code: Int32) -> Bool {
        // steamcmd.sh relaunches the updated executable on Valve's reserved exit status 42.
        code == 42 || (code == 0 && completed)
    }
}
