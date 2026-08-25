import Foundation

/// 下载入口共用的本地完整性检查。目录刚被 Steam 创建并不等于壁纸已经 commit 完成。
enum LocalWallpaperProbe {
    enum State: Equatable {
        case missing
        case incomplete
        case ready
    }

    static func state(at folder: URL, fileManager: FileManager = .default) -> State {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: folder.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return .missing }
        let project = folder.appendingPathComponent("project.json")
        guard let data = try? Data(contentsOf: project),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .incomplete
        }
        let type = WallpaperType(raw: json["type"] as? String)
        guard type != .unknown else { return .incomplete }

        if let file = json["file"] as? String, !file.isEmpty {
            let target = folder.appendingPathComponent(file).standardizedFileURL
            let root = folder.standardizedFileURL.path + "/"
            guard target.path.hasPrefix(root) else { return .incomplete }
            if fileManager.fileExists(atPath: target.path) { return .ready }
            // scene.json 偶尔只是描述名，真实主数据是同目录的 scene.pkg。
            if type == .scene,
               fileManager.fileExists(atPath: folder.appendingPathComponent("scene.pkg").path) {
                return .ready
            }
            return .incomplete
        }

        if type == .scene,
           fileManager.fileExists(atPath: folder.appendingPathComponent("scene.pkg").path) {
            return .ready
        }
        return .incomplete
    }

    static func isReady(at folder: URL, fileManager: FileManager = .default) -> Bool {
        state(at: folder, fileManager: fileManager) == .ready
    }
}
