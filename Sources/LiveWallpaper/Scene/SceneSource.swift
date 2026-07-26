import Foundation

/// 统一访问一个 scene 壁纸的内部文件。
/// 既支持已解包的文件夹(如样本 3504284734),也支持打包的 scene.pkg。
protocol SceneSource: AnyObject {
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
    /// 依赖项的**轻量**定位结果(只缓存「在哪/是否存在」,不持有 pkg 字节)。
    /// `.pkg(url)` = 打包依赖,需开 PackageSceneSource(把整包读进内存);`.folder(url)` = 松散目录;
    /// `.missing` = 找过但本地没订阅(避免每次重复 fileExists)。
    private enum Location { case pkg(URL); case folder(URL); case missing }
    // ⚠ 内存泄漏修复:此前缓存的是 `SceneSource?`,而 PackageSceneSource 会把**整包字节**(可达数百 MB)
    //   读进 RAM 并按 id 永久驻留 → 浏览/渲染含跨工坊依赖的壁纸越多,这个 static 字典越大(无上限、永不清)
    //   = 进程内存只涨不回收(实测 374MB→1.38GB 的主因之一)。改为只缓存「定位结果」(URL/枚举,几十字节),
    //   重的 PackageSceneSource 只在单次 textureData/textureSidecar 调用内**短暂**存在、函数返回即释放。
    private static var locationCache: [String: Location] = [:]
    private static let lock = NSLock()

    /// 重的 SceneSource 临时复用缓存:一次 load 内同一依赖常被取多张贴图,逐张重开整包浪费。
    /// 用 NSCache(系统内存吃紧时自动逐出,且有 count 上限)托管,既复用又不会无界驻留。
    private static let sourceCache: NSCache<NSString, AnyObject> = {
        let c = NSCache<NSString, AnyObject>()
        c.countLimit = 4   // 同时最多缓存 4 个依赖源;再多按 LRU 逐出(整包字节随之释放)
        return c
    }()

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

    private static func location(forWorkshopId id: String) -> Location {
        if let cached = locationCache[id] { return cached }
        let folder = PreferencesStore.shared.libraryRoot.appendingPathComponent(id)
        let fm = FileManager.default
        var loc: Location = .missing
        if fm.fileExists(atPath: folder.path) {
            let pkg = folder.appendingPathComponent("scene.pkg")
            loc = fm.fileExists(atPath: pkg.path) ? .pkg(pkg) : .folder(folder)
        }
        locationCache[id] = loc
        return loc
    }

    private static func source(forWorkshopId id: String) -> SceneSource? {
        lock.lock(); defer { lock.unlock() }
        // 临时复用缓存命中(NSCache,内存吃紧时已被系统逐出 → 重新开)。
        if let cached = sourceCache.object(forKey: id as NSString) as? SceneSource { return cached }
        let src: SceneSource?
        switch location(forWorkshopId: id) {
        case .pkg(let url):    src = PackageSceneSource(pkgURL: url)   // 整包字节:仅存活于 NSCache(可被逐出),不再永久驻留
        case .folder(let url): src = FolderSceneSource(root: url)     // 松散 materials/ 也能直接读(本就不持字节)
        case .missing:         src = nil
        }
        if let src { sourceCache.setObject(src as AnyObject, forKey: id as NSString) }
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
