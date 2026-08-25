import AppKit
import Foundation

/// 只读桥接当前壁纸库所属的 CrossOver Steam。
///
/// 这里不伪造 Steamworks AppID，也不修改 ACF/VDF；仅在网页已经确认订阅、对应 Steam
/// 客户端确实在线且账号一致时，观察 Steam 自己的 Workshop 下载。没有接管时由 SteamCMD 回退。
enum CrossOverSteamClient {
    struct Context: Equatable {
        let libraryRoot: URL
        let steamRoot: URL
        let bottleName: String
        let helperAppURL: URL
        let helperBundleIdentifier: String?
        let steamID64: String?

        var workshopManifestURL: URL {
            steamRoot.appendingPathComponent("steamapps/workshop/appworkshop_431960.acf")
        }
        var workshopLogURL: URL {
            steamRoot.appendingPathComponent("logs/workshop_log.txt")
        }
        func itemURL(_ id: String) -> URL { libraryRoot.appendingPathComponent(id, isDirectory: true) }
    }

    struct ActiveContext: Equatable {
        let context: Context
        let processIdentifier: pid_t
    }

    struct ManifestItemState: Equatable {
        var isKnown = false
        var isInstalledRecord = false
        var installedManifest: String?
        var latestManifest: String?
        var installedSize: Int64?

        var recordIsCurrent: Bool {
            guard isInstalledRecord, let installedManifest, !installedManifest.isEmpty else { return false }
            guard let latestManifest, !latestManifest.isEmpty else { return true }
            return installedManifest == latestManifest
        }
    }

    struct Observation: Equatable {
        var manifestState = ManifestItemState()
        var projectExists = false
        var contentSize: Int64?
        var workshopLogSize: UInt64 = 0
        var targetMentionedAfterBaseline = false
        var clientSuspendedAfterBaseline = false

        var isComplete: Bool {
            guard manifestState.recordIsCurrent, projectExists else { return false }
            guard let expected = manifestState.installedSize, expected > 0 else { return true }
            return contentSize == expected
        }
        var hasTakenOver: Bool {
            manifestState.isKnown || targetMentionedAfterBaseline
        }
    }

    /// 仅接受 `.../Steam/steamapps/workshop/content/431960` 这种 CrossOver 库。
    static func context(
        for libraryRoot: URL,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> Context? {
        let root = libraryRoot.standardizedFileURL
        let suffix = ["steamapps", "workshop", "content", "431960"]
        guard Array(root.pathComponents.suffix(suffix.count)) == suffix else { return nil }
        let components = root.pathComponents
        guard let bottles = components.lastIndex(of: "Bottles"), bottles + 1 < components.count else { return nil }
        let bottleName = components[bottles + 1]
        guard root.path.contains("/Library/Application Support/CrossOver/Bottles/") else { return nil }

        var steamRoot = root
        for _ in suffix { steamRoot.deleteLastPathComponent() }
        guard fileManager.fileExists(atPath: steamRoot.appendingPathComponent("steam.exe").path) else { return nil }

        let helperBase = homeDirectory.appendingPathComponent("Applications/CrossOver")
            .appendingPathComponent(bottleName)
        let helperCandidates = [
            helperBase.appendingPathComponent("Steam.app"),
            helperBase.appendingPathComponent("Steam/Steam.app")
        ]
        guard let helper = helperCandidates.first(where: {
            fileManager.fileExists(atPath: $0.appendingPathComponent("Contents/Info.plist").path)
        }) else { return nil }

        let info = NSDictionary(contentsOf: helper.appendingPathComponent("Contents/Info.plist"))
        if let declaredBottle = info?["CXHelperAppBottleName"] as? String,
           !declaredBottle.isEmpty, declaredBottle != bottleName {
            return nil
        }
        return Context(
            libraryRoot: root,
            steamRoot: steamRoot,
            bottleName: bottleName,
            helperAppURL: helper.standardizedFileURL,
            helperBundleIdentifier: info?["CFBundleIdentifier"] as? String,
            steamID64: mostRecentSteamID64(steamRoot: steamRoot)
        )
    }

    /// 必须在主线程调用：用对应 bottle 的 Steam mini-app 精确识别运行实例。
    static func activeContext(
        for libraryRoot: URL,
        expectedSteamID64: String? = nil,
        runningApplications: [NSRunningApplication] = NSWorkspace.shared.runningApplications
    ) -> ActiveContext? {
        precondition(Thread.isMainThread)
        guard let context = context(for: libraryRoot) else { return nil }
        if let expectedSteamID64, let actual = context.steamID64, expectedSteamID64 != actual {
            return nil
        }
        let app = runningApplications.first { app in
            if let bundleID = context.helperBundleIdentifier,
               app.bundleIdentifier == bundleID { return true }
            return app.bundleURL?.standardizedFileURL == context.helperAppURL
        }
        guard let app, !app.isTerminated else { return nil }
        return ActiveContext(context: context, processIdentifier: app.processIdentifier)
    }

    static func processIsRunning(_ pid: pid_t) -> Bool {
        pid > 0 && (kill(pid, 0) == 0 || errno == EPERM)
    }

    static func observe(_ context: Context, id: String, logBaseline: UInt64) -> Observation {
        let fm = FileManager.default
        let state = manifestItemState(context, id: id)
        let logSize = fileSize(context.workshopLogURL)
        var tail = ""
        if logSize > logBaseline,
           let handle = try? FileHandle(forReadingFrom: context.workshopLogURL) {
            defer { try? handle.close() }
            try? handle.seek(toOffset: min(logBaseline, logSize))
            let capped = min(logSize - min(logBaseline, logSize), 1_048_576)
            tail = String(data: (try? handle.read(upToCount: Int(capped))) ?? Data(), encoding: .utf8) ?? ""
        }
        let targetLines = tail.components(separatedBy: .newlines).filter { $0.contains(id) }
        let target = !targetLines.isEmpty
        let suspended = targetLines.contains {
            $0.localizedCaseInsensitiveContains("Suspended") ||
            $0.localizedCaseInsensitiveContains("Update canceled")
        }
        let itemURL = context.itemURL(id)
        return Observation(
            manifestState: state,
            projectExists: LocalWallpaperProbe.isReady(at: itemURL, fileManager: fm),
            contentSize: directoryContentSize(itemURL, fileManager: fm),
            workshopLogSize: logSize,
            targetMentionedAfterBaseline: target,
            clientSuspendedAfterBaseline: suspended
        )
    }

    static func fileSize(_ url: URL) -> UInt64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let value = attributes[.size] as? NSNumber else { return 0 }
        return value.uint64Value
    }

    static func manifestItemState(_ context: Context, id: String) -> ManifestItemState {
        guard let text = try? String(contentsOf: context.workshopManifestURL, encoding: .utf8) else {
            return ManifestItemState()
        }
        return parseManifestItemState(text, id: id)
    }

    static func parseManifestItemState(_ text: String, id: String) -> ManifestItemState {
        let installed = namedBlock("WorkshopItemsInstalled", in: text)
            .flatMap { namedBlock(id, in: $0) }
        let details = namedBlock("WorkshopItemDetails", in: text)
            .flatMap { namedBlock(id, in: $0) }
        return ManifestItemState(
            isKnown: details != nil || installed != nil,
            isInstalledRecord: installed != nil,
            installedManifest: installed.flatMap { quotedValue("manifest", in: $0) },
            latestManifest: details.flatMap { quotedValue("latest_manifest", in: $0) },
            installedSize: installed.flatMap { quotedValue("size", in: $0) }.flatMap(Int64.init)
        )
    }

    /// ACF 的 Installed.size 是该条目的文件总字节数。目录创建不等于 Steam 已提交完成，
    /// 因此只读取文件元数据求和，不读取文件内容。
    static func directoryContentSize(_ folder: URL, fileManager: FileManager = .default) -> Int64? {
        guard let enumerator = fileManager.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: []
        ) else { return nil }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            if url.lastPathComponent == ".DS_Store" { continue }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    /// 提取 Valve KeyValues 的一个命名对象块；只读解析，不依赖字段顺序。
    static func namedBlock(_ name: String, in text: String) -> String? {
        let token = "\"\(name)\""
        guard let nameRange = text.range(of: token),
              let open = text[nameRange.upperBound...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var cursor = open
        while cursor < text.endIndex {
            let c = text[cursor]
            if inString {
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
            } else if c == "\"" {
                inString = true
            } else if c == "{" {
                depth += 1
            } else if c == "}" {
                depth -= 1
                if depth == 0 {
                    return String(text[text.index(after: open)..<cursor])
                }
            }
            cursor = text.index(after: cursor)
        }
        return nil
    }

    static func quotedValue(_ key: String, in text: String) -> String? {
        let pattern = "\"\(NSRegularExpression.escapedPattern(for: key))\"\\s*\"([^\"]*)\""
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    static func mostRecentSteamID64(steamRoot: URL) -> String? {
        let url = steamRoot.appendingPathComponent("config/loginusers.vdf")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let users = namedBlock("users", in: text) ?? text
        let pattern = "\"(7656\\d{13})\"\\s*\\{"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        var first: String?
        for match in regex.matches(in: users, range: NSRange(users.startIndex..., in: users)) {
            guard let idRange = Range(match.range(at: 1), in: users) else { continue }
            let id = String(users[idRange])
            if first == nil { first = id }
            if let body = namedBlock(id, in: users),
               body.range(of: "\"MostRecent\"\\s*\"1\"", options: .regularExpression) != nil {
                return id
            }
        }
        return first
    }
}
