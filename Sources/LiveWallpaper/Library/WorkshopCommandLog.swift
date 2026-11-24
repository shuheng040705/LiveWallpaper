import Foundation

/// SteamCMD can return to the prompt while the requested SteamPipe transfer continues.
/// Follow only records written for this invocation in the worker's own workshop log.
struct WorkshopCommandLog {
    enum Outcome: Equatable { case installed, failed(String) }
    private var tail: SteamLogTail
    private let prefix: String
    private let item: String
    private var missingSource = false
    private(set) var requested = false
    private(set) var outcome: Outcome?

    init(url: URL, app: String, item: String) {
        self.tail = SteamLogTail(url: url)
        self.prefix = "[AppID \(app)] "
        self.item = item
    }

    mutating func poll() {
        guard outcome == nil else { return }
        for line in tail.readLines() {
            consume(line)
            if outcome != nil { break }
        }
    }

    private mutating func consume(_ line: String) {
        guard let range = line.range(of: prefix) else { return }
        let message = line[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        if message == "Download item \(item) requested by app" {
            requested = true
            missingSource = false
        }
        guard requested else { return }
        if message.hasPrefix("Update canceled:"), message.contains("(Missing game files)") {
            missingSource = true
        }
        let resultPrefix = "Download item \(item) result : "
        guard message.hasPrefix(resultPrefix) else { return }
        let result = String(message.dropFirst(resultPrefix.count))
        outcome = result == "OK" ? .installed : .failed(missingSource ? "Missing game files" : result)
    }
}
