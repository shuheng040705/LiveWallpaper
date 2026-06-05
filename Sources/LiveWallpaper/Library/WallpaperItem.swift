import Foundation

/// Wallpaper Engine 壁纸类型。project.json 的 "type" 字段大小写不一(video/Video/scene/Scene/web/Web)。
enum WallpaperType: String, Codable {
    case video
    case scene
    case web
    case application
    case unknown

    init(raw: String?) {
        switch raw?.lowercased() {
        case "video": self = .video
        case "scene": self = .scene
        case "web": self = .web
        case "application": self = .application
        default: self = .unknown
        }
    }

    var displayName: String {
        switch self {
        case .video: return "视频"
        case .scene: return "场景"
        case .web: return "网页"
        case .application: return "程序"
        case .unknown: return "未知"
        }
    }

    /// 当前版本是否能真正在桌面渲染(scene 暂以预览图占位)。
    var isPlayable: Bool {
        switch self {
        case .video, .web, .scene: return true
        case .application, .unknown: return false
        }
    }
}

/// Wallpaper Engine 内容分级。project.json 的 "contentrating" 字段:Everyone / Questionable / Mature(少数缺失)。
enum ContentRating: String, Codable, CaseIterable, Hashable {
    case everyone
    case questionable
    case mature
    case unknown

    init(raw: String?) {
        switch raw?.lowercased() {
        case "everyone": self = .everyone
        case "questionable": self = .questionable
        case "mature": self = .mature
        default: self = .unknown
        }
    }

    var displayName: String {
        switch self {
        case .everyone: return "适合所有人"
        case .questionable: return "待商榷"
        case .mature: return "成人内容"
        case .unknown: return "未分级"
        }
    }
}

/// 一个壁纸 = 工坊目录里的一个子文件夹 + 它的 project.json。
struct WallpaperItem: Identifiable, Hashable {
    let id: String          // 工坊文件夹名(workshop id)
    let folderURL: URL
    let title: String
    let type: WallpaperType
    var contentRating: ContentRating = .unknown
    let fileName: String?   // 主文件:mp4 / scene.pkg / index.html
    let previewName: String?
    let tags: [String]
    var modifiedDate: Date = .distantPast   // 文件夹修改时间(近似下载/更新时间)
    var fileSize: Int64 = 0                 // 主文件字节数(用于按大小排序)

    var fileURL: URL? { fileName.map { folderURL.appendingPathComponent($0) } }
    var previewURL: URL? { previewName.map { folderURL.appendingPathComponent($0) } }

    /// scene 壁纸即便 file 写的是 scene.json,实际数据多在 scene.pkg 里。
    var scenePackageURL: URL? {
        let pkg = folderURL.appendingPathComponent("scene.pkg")
        return FileManager.default.fileExists(atPath: pkg.path) ? pkg : nil
    }
}
