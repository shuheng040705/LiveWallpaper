import Foundation

/// Reads complete lines appended after a command starts. Handles log rotation and bounds
/// both disk reads and retained partial lines, including malformed records with no newline.
struct SteamLogTail {
    private static let limit = 65_536
    private let url: URL
    private var offset: UInt64 = 0
    private var inode: UInt64?
    private var fragment = Data()
    private var skipRemainder = false

    init(url: URL) {
        self.url = url
        guard let file = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? file.close() }
        var info = stat()
        guard fstat(file.fileDescriptor, &info) == 0 else { return }
        inode = UInt64(info.st_ino)
        offset = UInt64(info.st_size)
        if offset > 0 {
            do {
                try file.seek(toOffset: offset - 1)
                skipRemainder = try file.read(upToCount: 1)?.first != 10
            } catch { skipRemainder = true }
        }
    }

    mutating func readLines() -> [String] {
        guard let file = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? file.close() }
        var info = stat()
        guard fstat(file.fileDescriptor, &info) == 0 else { return [] }
        let end = UInt64(info.st_size)
        if inode != UInt64(info.st_ino) || end < offset {
            offset = 0
            fragment.removeAll()
            skipRemainder = false
        }
        inode = UInt64(info.st_ino)
        guard end > offset else { return [] }
        do {
            try file.seek(toOffset: offset)
            guard let bytes = try file.read(upToCount: Self.limit) else { return [] }
            offset += UInt64(bytes.count)
            var lines: [String] = []
            var start = bytes.startIndex
            while start < bytes.endIndex {
                let newline = bytes[start...].firstIndex(of: 10)
                let part = bytes[start..<(newline ?? bytes.endIndex)]
                if !skipRemainder {
                    if fragment.count + part.count > Self.limit {
                        skipRemainder = true
                        fragment.removeAll()
                    } else {
                        fragment.append(contentsOf: part)
                    }
                }
                guard let newline else { break }
                if !skipRemainder { lines.append(String(decoding: fragment, as: UTF8.self)) }
                fragment.removeAll(keepingCapacity: true)
                skipRemainder = false
                start = bytes.index(after: newline)
            }
            return lines
        } catch { return [] }
    }
}
