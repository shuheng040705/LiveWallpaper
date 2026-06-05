import Foundation

/// 极简文件日志,写到 /tmp/livewallpaper.log,方便无界面调试。
enum Log {
    private static let url = URL(fileURLWithPath: "/tmp/livewallpaper.log")
    private static let queue = DispatchQueue(label: "log")

    static func reset() {
        queue.async { try? "".write(to: url, atomically: true, encoding: .utf8) }
    }

    static func write(_ message: String) {
        queue.async {
            let line = "[\(Self.timestamp())] \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            if let fh = try? FileHandle(forWritingTo: url) {
                fh.seekToEndOfFile()
                fh.write(data)
                try? fh.close()
            } else {
                try? data.write(to: url)
            }
        }
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: Date())
    }
}
