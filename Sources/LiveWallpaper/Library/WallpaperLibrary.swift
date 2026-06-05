import Foundation
import Combine

/// 扫描工坊根目录,解析每个 project.json,产出 WallpaperItem 列表。
final class WallpaperLibrary: ObservableObject {
    @Published private(set) var items: [WallpaperItem] = []
    @Published private(set) var isScanning = false

    var rootURL: URL { PreferencesStore.shared.libraryRoot }

    func scan(completion: (() -> Void)? = nil) {
        isScanning = true
        let root = rootURL
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Self.scanFolder(root)
            DispatchQueue.main.async {
                self.items = result
                self.isScanning = false
                completion?()
            }
        }
    }

    private static func scanFolder(_ root: URL) -> [WallpaperItem] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var result: [WallpaperItem] = []
        for entry in entries {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: entry.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let projectURL = entry.appendingPathComponent("project.json")
            guard let data = try? Data(contentsOf: projectURL),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            let type = WallpaperType(raw: json["type"] as? String)
            let title = (json["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            // contentrating 可能是普通字符串,也可能被包成 {"value": "..."}(WE 偶有此格式)。
            let ratingRaw: String?
            if let s = json["contentrating"] as? String {
                ratingRaw = s
            } else if let wrapped = json["contentrating"] as? [String: Any] {
                ratingRaw = wrapped["value"] as? String
            } else {
                ratingRaw = nil
            }
            let contentRating = ContentRating(raw: ratingRaw)
            let file = json["file"] as? String
            let preview = json["preview"] as? String
            let tags = (json["tags"] as? [String]) ?? []

            // 文件夹修改时间(近似下载/更新时间)+ 主文件大小(用于排序)。
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            var size: Int64 = 0
            if let file, let attr = try? fm.attributesOfItem(atPath: entry.appendingPathComponent(file).path),
               let s = attr[.size] as? Int64 { size = s }

            result.append(WallpaperItem(
                id: entry.lastPathComponent,
                folderURL: entry,
                title: (title?.isEmpty == false ? title! : entry.lastPathComponent),
                type: type,
                contentRating: contentRating,
                fileName: file,
                previewName: preview,
                tags: tags,
                modifiedDate: modified,
                fileSize: size
            ))
        }

        // 默认按类型分组 + 标题(UI 层会按用户选择重新排序)。
        result.sort { a, b in
            if a.type != b.type { return a.type.sortOrder < b.type.sortOrder }
            return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
        return result
    }

    func item(id: String) -> WallpaperItem? { items.first { $0.id == id } }

    var counts: [WallpaperType: Int] {
        Dictionary(grouping: items, by: { $0.type }).mapValues { $0.count }
    }

    var ratingCounts: [ContentRating: Int] {
        Dictionary(grouping: items, by: { $0.contentRating }).mapValues { $0.count }
    }
}

extension WallpaperType {
    /// 类型分组排序权重(供库默认排序与 UI 排序复用)。
    var sortOrder: Int {
        switch self {
        case .video: return 0
        case .scene: return 1
        case .web: return 2
        case .application: return 3
        case .unknown: return 4
        }
    }
}
