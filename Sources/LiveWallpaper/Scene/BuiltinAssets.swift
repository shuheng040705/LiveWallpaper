import Foundation

/// Wallpaper Engine 本体自带的共享资源(粒子贴图、内置着色器),不随用户下载的壁纸分发,
/// 而是放在 WE 安装目录的 assets/ 下、且是**已解包**的普通文件树。
/// 用作纹理/着色器解析的回退源:壁纸 pkg 里找不到时来这里找。
///
/// 关键路径规律(实测):粒子贴图引用 "particle/fog/fog1" → assets/materials/particle/fog/fog1.tex
/// (即 ref 解析为 materials/<ref>.tex)。assets 下无 textures/ 目录,所有 .tex 都在 materials/ 里。
final class BuiltinAssets {
    static let shared = BuiltinAssets()

    private(set) var root: URL?    // assets/ 根
    private var texIndex: [String: String] = [:]   // basename "fog1.tex" -> 相对 assets/ 的路径
    private var indexed = false

    private init() { resolveRoot() }

    /// (重新)确定 assets 根目录。设置页改了路径后调用。
    func resolveRoot() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // 0) app 包内打包的 assets(无需任何系统权限,优先,避免「文稿」TCC 弹窗);
        // 1) 设置里指定的;2) ~/Documents/assets;3) CrossOver bottle 里的 WE 本体。
        var candidates: [String] = []
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("assets").path {
            candidates.append(bundled)
        }
        candidates.append(contentsOf: [
            PreferencesStore.shared.weAssetsPath,
            "\(home)/Documents/assets",
            "\(home)/Library/Application Support/CrossOver/Bottles/Steam/drive_c/Program Files (x86)/Steam/steamapps/common/wallpaper_engine/assets"
        ].compactMap { $0 })
        root = candidates.first { FileManager.default.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) }
        texIndex.removeAll()
        indexed = false
        Log.write("BuiltinAssets: root = \(root?.path ?? "NOT FOUND")")
    }

    /// 当前根是否有效(供设置页显示状态)。
    var isAvailable: Bool { root != nil }

    /// 解析一个纹理引用(如 "particle/fog/fog1" 或基名 "snowflake")到 .tex 字节。
    func textureData(forReference ref: String) -> Data? {
        guard let root else { return nil }
        let cleaned = ref.replacingOccurrences(of: "\\", with: "/")
        // 1) materials/<ref>.tex(主要规律)
        if let d = try? Data(contentsOf: root.appendingPathComponent("materials/\(cleaned).tex")) { return d }
        // 2) <ref>.tex(以防个别引用已含前缀)
        if let d = try? Data(contentsOf: root.appendingPathComponent("\(cleaned).tex")) { return d }
        // 3) 按基名在索引里找(覆盖 nature/rain1 写成 rain1 之类)
        buildIndexIfNeeded()
        let base = (cleaned as NSString).lastPathComponent + ".tex"
        if let rel = texIndex[base] {
            return try? Data(contentsOf: root.appendingPathComponent(rel))
        }
        return nil
    }

    /// 读取一个内置字体(WE assets/fonts/ 下;文本层 font 引用如 "fonts/Atami-Regular.otf"——
    /// 这些字体不在壁纸 pkg 里,而在 WE 本体 assets/fonts/,是时钟/文字显示原版字体的来源)。
    func fontData(forReference ref: String) -> Data? {
        let cleaned = ref.replacingOccurrences(of: "\\", with: "/")
        let base = (cleaned as NSString).lastPathComponent
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // 字体常不在打包 assets(只打包了 materials/shaders),故搜全部候选根:
        // 选定 root + 打包 + 设置指定 + ~/Documents/assets + CrossOver WE 本体。
        var roots: [String] = []
        if let r = root?.path { roots.append(r) }
        if let b = Bundle.main.resourceURL?.appendingPathComponent("assets").path { roots.append(b) }
        roots.append(contentsOf: [
            PreferencesStore.shared.weAssetsPath,
            "\(home)/Documents/assets",
            "\(home)/Library/Application Support/CrossOver/Bottles/Steam/drive_c/Program Files (x86)/Steam/steamapps/common/wallpaper_engine/assets"
        ].compactMap { $0 })
        for r in roots {
            let ru = URL(fileURLWithPath: r)
            if let d = try? Data(contentsOf: ru.appendingPathComponent(cleaned)) { return d }       // <ref>(含 fonts/ 前缀)
            if let d = try? Data(contentsOf: ru.appendingPathComponent("fonts/\(base)")) { return d } // fonts/<基名>
        }
        return nil
    }

    /// 读取一个内置着色器源码(相对 shaders/,如 "effects/waterflow.frag" 或 "genericimage4.frag")。
    func shaderSource(_ relativePath: String) -> String? {
        guard let root else { return nil }
        return try? String(contentsOf: root.appendingPathComponent("shaders").appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// 读取纹理的精灵表边车(<ref>.tex-json)字节。
    func textureSidecar(forReference ref: String) -> Data? {
        guard let root else { return nil }
        let cleaned = ref.replacingOccurrences(of: "\\", with: "/")
        if let d = try? Data(contentsOf: root.appendingPathComponent("materials/\(cleaned).tex-json")) { return d }
        if let d = try? Data(contentsOf: root.appendingPathComponent("\(cleaned).tex-json")) { return d }
        buildIndexIfNeeded()
        let base = (cleaned as NSString).lastPathComponent + ".tex"
        if let rel = texIndex[base] {
            return try? Data(contentsOf: root.appendingPathComponent(rel + "-json"))
        }
        return nil
    }

    private func buildIndexIfNeeded() {
        guard !indexed, let root else { return }
        indexed = true
        let baseLen = root.path.count + 1
        // 扫 materials/(主)+ effects/(内置特效自带的相位/法线/流向贴图,如 waterflow 的 g_Texture2=
        // "effects/waterflowphase"、waterripple 的法线图等。它们引用名是 "effects/<x>",但真实文件埋在
        // effects/<fx>/materials/effects/<x>.tex —— materials/ 下找不到 → 必须把 effects/ 也纳入基名索引,
        // 否则相位/法线槽退白 → 屋檐水流不流、涟漪/晃动等位移类特效在打包后全失效)。materials 先扫,同名以其为准。
        for sub in ["materials", "effects"] {
            let dir = root.appendingPathComponent(sub)
            guard let en = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { continue }
            for case let u as URL in en where u.pathExtension == "tex" {
                let name = u.lastPathComponent
                if texIndex[name] == nil, u.path.count > baseLen {
                    texIndex[name] = String(u.path.dropFirst(baseLen))
                }
            }
        }
        Log.write("BuiltinAssets: indexed \(texIndex.count) builtin textures")
    }
}
