import Foundation
import Combine

/// WE 侧栏“我的预设”的本地存储与 JSON 交换格式。
/// 预设同时覆盖通用显示参数和 project.json 自定义属性，因此加载后可以完整复现当前画面。
struct WallpaperPreset: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var wallpaperID: String
    var wallpaperTitle: String
    var createdAt: Date
    var general: GeneralWallpaperSettings.Snapshot
    var properties: [String: WallpaperPropertyStore.PresetValue]
}

struct WallpaperPresetDocument: Codable {
    var schemaVersion: Int = 1
    var preset: WallpaperPreset
}

@MainActor
final class WallpaperPresetStore: ObservableObject {
    static let shared = WallpaperPresetStore()

    enum PresetError: LocalizedError {
        case invalidDocument
        case unsupportedVersion(Int)
        case wrongWallpaper(expected: String, actual: String)

        var errorDescription: String? {
            switch self {
            case .invalidDocument: return "这不是有效的 LiveWallpaper 预设文件。"
            case .unsupportedVersion(let version): return "不支持这个预设版本（\(version)）。"
            case .wrongWallpaper(let expected, let actual):
                return "预设属于壁纸 \(actual)，不能加载到当前壁纸 \(expected)。"
            }
        }
    }

    private let defaults = UserDefaults.standard
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private func key(_ wallpaperID: String) -> String { "wpPresets.\(wallpaperID)" }

    func presets(for wallpaperID: String) -> [WallpaperPreset] {
        guard let data = defaults.data(forKey: key(wallpaperID)),
              let decoded = try? decoder.decode([WallpaperPreset].self, from: data) else { return [] }
        return decoded.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    @discardableResult
    func saveCurrent(name: String, item: WallpaperItem) -> WallpaperPreset {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = cleaned.isEmpty ? "我的预设" : String(cleaned.prefix(80))
        var list = presets(for: item.id)
        let preset = WallpaperPreset(
            id: list.first(where: { $0.name.localizedCaseInsensitiveCompare(finalName) == .orderedSame })?.id ?? UUID(),
            name: finalName,
            wallpaperID: item.id,
            wallpaperTitle: item.title,
            createdAt: Date(),
            general: GeneralWallpaperSettings.shared.snapshot(item.id),
            properties: WallpaperPropertyStore.shared.presetSnapshot(forID: item.id, folderURL: item.folderURL)
        )
        list.removeAll { $0.id == preset.id || $0.name.localizedCaseInsensitiveCompare(finalName) == .orderedSame }
        list.append(preset)
        persist(list, wallpaperID: item.id)
        return preset
    }

    func apply(_ preset: WallpaperPreset, to item: WallpaperItem) throws {
        guard preset.wallpaperID == item.id else {
            throw PresetError.wrongWallpaper(expected: item.id, actual: preset.wallpaperID)
        }
        GeneralWallpaperSettings.shared.apply(preset.general, to: item.id)
        WallpaperPropertyStore.shared.applyPreset(preset.properties, forID: item.id, folderURL: item.folderURL)
        objectWillChange.send()
    }

    func delete(_ preset: WallpaperPreset) {
        var list = presets(for: preset.wallpaperID)
        list.removeAll { $0.id == preset.id }
        persist(list, wallpaperID: preset.wallpaperID)
    }

    func exportData(_ preset: WallpaperPreset) throws -> Data {
        try encoder.encode(WallpaperPresetDocument(preset: preset))
    }

    @discardableResult
    func importData(_ data: Data, for item: WallpaperItem) throws -> WallpaperPreset {
        guard let doc = try? decoder.decode(WallpaperPresetDocument.self, from: data) else {
            throw PresetError.invalidDocument
        }
        guard doc.schemaVersion == 1 else { throw PresetError.unsupportedVersion(doc.schemaVersion) }
        guard doc.preset.wallpaperID == item.id else {
            throw PresetError.wrongWallpaper(expected: item.id, actual: doc.preset.wallpaperID)
        }
        var imported = doc.preset
        imported.id = UUID() // 导入副本，避免覆盖本机同 UUID 的预设。
        imported.createdAt = Date()
        var list = presets(for: item.id)
        list.append(imported)
        persist(list, wallpaperID: item.id)
        return imported
    }

    private func persist(_ list: [WallpaperPreset], wallpaperID: String) {
        if list.isEmpty {
            defaults.removeObject(forKey: key(wallpaperID))
        } else if let data = try? encoder.encode(list) {
            defaults.set(data, forKey: key(wallpaperID))
        }
        objectWillChange.send()
    }
}
