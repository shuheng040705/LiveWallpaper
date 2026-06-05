import Foundation

/// 统一访问一个 scene 壁纸的内部文件。
/// 既支持已解包的文件夹(如样本 3504284734),也支持打包的 scene.pkg。
protocol SceneSource {
    func data(for relativePath: String) -> Data?
    var allPaths: [String] { get }
}

extension SceneSource {
    /// 读取并解析某个内部 JSON 文件。
    func json(for relativePath: String) -> [String: Any]? {
        guard let d = data(for: relativePath),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
        else { return nil }
        return obj
    }
}

/// 已解包的壁纸文件夹。
final class FolderSceneSource: SceneSource {
    let root: URL
    init(root: URL) { self.root = root }

    func data(for relativePath: String) -> Data? {
        let normalized = relativePath.replacingOccurrences(of: "\\", with: "/")
        return try? Data(contentsOf: root.appendingPathComponent(normalized))
    }

    var allPaths: [String] {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var paths: [String] = []
        let baseLen = root.path.count + 1
        for case let u as URL in en {
            if (try? u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true, u.path.count > baseLen {
                paths.append(String(u.path.dropFirst(baseLen)))
            }
        }
        return paths
    }
}

/// scene.pkg 解包。
/// WE PKG 格式(小端):int32 magicLen + magic("PKGV00xx") + int32 count
///   + count × ( int32 nameLen + name + int32 offset + int32 size )
///   + data blob(每个文件数据 = blob[offset ..< offset+size],offset 相对 blob 起点 = 头部结束处)。
/// 注:offset 基准 / 字节序由后台逆向 agent 二次确认,如有出入此处微调。
final class PackageSceneSource: SceneSource {
    private let bytes: [UInt8]
    private var entries: [String: (offset: Int, size: Int)] = [:]

    init?(pkgURL: URL) {
        guard let d = try? Data(contentsOf: pkgURL) else { return nil }
        self.bytes = [UInt8](d)
        guard parse() else { return nil }
    }

    private func u32(_ i: Int) -> UInt32 {
        UInt32(bytes[i]) | (UInt32(bytes[i + 1]) << 8) | (UInt32(bytes[i + 2]) << 16) | (UInt32(bytes[i + 3]) << 24)
    }

    private func parse() -> Bool {
        var off = 0
        func need(_ n: Int) -> Bool { n >= 0 && off + n <= bytes.count }
        func readI32() -> Int? {
            guard need(4) else { return nil }
            let v = Int(Int32(bitPattern: u32(off))); off += 4; return v
        }
        func readStr() -> String? {
            guard let len = readI32(), need(len) else { return nil }
            let s = String(bytes: bytes[off..<off + len], encoding: .utf8); off += len; return s
        }

        guard let magic = readStr(), magic.hasPrefix("PKGV") else { return false }
        guard let count = readI32(), count >= 0, count < 1_000_000 else { return false }

        var temp: [(String, Int, Int)] = []
        for _ in 0..<count {
            guard let name = readStr(), let o = readI32(), let s = readI32() else { return false }
            temp.append((name, o, s))
        }
        let blobBase = off
        for (name, o, s) in temp {
            entries[normalize(name)] = (blobBase + o, s)
        }
        return !entries.isEmpty
    }

    private func normalize(_ p: String) -> String {
        p.replacingOccurrences(of: "\\", with: "/")
    }

    func data(for relativePath: String) -> Data? {
        guard let e = entries[normalize(relativePath)] else { return nil }
        guard e.offset >= 0, e.size >= 0, e.offset + e.size <= bytes.count else { return nil }
        return Data(bytes[e.offset..<e.offset + e.size])
    }

    var allPaths: [String] { Array(entries.keys) }
}

/// 跨创意工坊依赖贴图解析。粒子材质的纹理引用可能形如 "workshop/<id>/particle/xxx",
/// 表示该贴图属于**另一个订阅项** <id>(WE 的依赖机制,作者复用了别人的资源包)。
/// 到兄弟工坊目录 <libraryRoot>/<id>/ 里取真实文件,而不是自造一张糊弄。
/// 未订阅该依赖(本地没有 <id>/)时返回 nil —— 上层据此跳过该发射器,宁可不画也不画假的。
enum CrossWorkshopAssets {
    private static var cache: [String: SceneSource?] = [:]

    /// ref 形如 "workshop/<id>/<rest>";到兄弟项目里取 <rest> 对应的 .tex 字节。
    static func textureData(forReference ref: String) -> Data? {
        let cleaned = ref.replacingOccurrences(of: "\\", with: "/")
        let parts = cleaned.split(separator: "/").map(String.init)
        guard parts.count >= 3, parts[0].lowercased() == "workshop" else { return nil }
        let id = parts[1]
        let rest = parts[2...].joined(separator: "/")
        guard let src = source(forWorkshopId: id) else { return nil }
        // 与 pkg 内材质纹理同规律:materials/<rest>.tex,退 <rest>.tex。
        return src.data(for: "materials/\(rest).tex") ?? src.data(for: "\(rest).tex")
    }

    /// 边车(精灵表)同理,跨项目取 <rest>.tex-json。
    static func textureSidecar(forReference ref: String) -> Data? {
        let cleaned = ref.replacingOccurrences(of: "\\", with: "/")
        let parts = cleaned.split(separator: "/").map(String.init)
        guard parts.count >= 3, parts[0].lowercased() == "workshop" else { return nil }
        guard let src = source(forWorkshopId: parts[1]) else { return nil }
        let rest = parts[2...].joined(separator: "/")
        return src.data(for: "materials/\(rest).tex-json") ?? src.data(for: "\(rest).tex-json")
    }

    private static func source(forWorkshopId id: String) -> SceneSource? {
        if let cached = cache[id] { return cached }   // 含「找过但没有」(.some(nil))
        let folder = PreferencesStore.shared.libraryRoot.appendingPathComponent(id)
        let fm = FileManager.default
        var src: SceneSource? = nil
        if fm.fileExists(atPath: folder.path) {
            let pkg = folder.appendingPathComponent("scene.pkg")
            if fm.fileExists(atPath: pkg.path) {
                src = PackageSceneSource(pkgURL: pkg)
            } else {
                src = FolderSceneSource(root: folder)   // 松散 materials/ 也能直接读
            }
        }
        cache[id] = src
        return src
    }
}

/// 为一个 scene 壁纸创建合适的 SceneSource:优先用已解包文件夹,否则解包 scene.pkg。
enum SceneSourceFactory {
    static func make(for item: WallpaperItem) -> SceneSource? {
        // 已解包:存在 scene/scene.json 或顶层 scene.json
        let fm = FileManager.default
        if fm.fileExists(atPath: item.folderURL.appendingPathComponent("scene/scene.json").path) ||
           fm.fileExists(atPath: item.folderURL.appendingPathComponent("scene.json").path) {
            return FolderSceneSource(root: item.folderURL)
        }
        if let pkg = item.scenePackageURL {
            return PackageSceneSource(pkgURL: pkg)
        }
        return nil
    }
}
