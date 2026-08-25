import Foundation

/// 卸载策略中的安全不变量。Steam 工坊项目必须先确认退订成功，才能自动删除本地文件；
/// 否则 Steam 会把仍处于订阅状态的项目再次下载回来。
enum WallpaperUninstallPolicy {
    static func isSteamWorkshopID(_ id: String) -> Bool {
        id.count >= 6 && id.allSatisfy(\.isNumber)
    }

    static func requiresSteamUnsubscribe(
        itemID: String,
        requested: Bool,
        knownSubscribed: Bool
    ) -> Bool {
        requested && isSteamWorkshopID(itemID) && knownSubscribed
    }

    static func mayRemoveLocalFiles(
        requiresSteamUnsubscribe: Bool,
        unsubscribeSucceeded: Bool?
    ) -> Bool {
        !requiresSteamUnsubscribe || unsubscribeSucceeded == true
    }

    /// 只允许卸载当前库目录的直接子目录，避免损坏的模型或过期 UI 把库根目录/其它路径送进废纸篓。
    static func isSafeLibraryChild(folderURL: URL, libraryRoot: URL) -> Bool {
        let folder = folderURL.standardizedFileURL
        let root = libraryRoot.standardizedFileURL
        return folder != root && folder.deletingLastPathComponent() == root
    }
}
