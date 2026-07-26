import Foundation
import Combine

/// WE「属性」通用区:每个壁纸顶部都有的 8 个标准通用控件(与 project.json 自定义属性无关)。
/// WE 实拍顺序:音频监听 / 主题配色 / 音量 / 播放速度 / 鼠标视差 / 翻转 / 图片筛选器 / 显示颜色选项。
///
/// 持久化:per-wallpaper 存 UserDefaults，key = "wpg.<id>.<field>"(与 WallpaperPropertyStore 的
/// "wp.<id>.<propKey>" 命名空间分开,互不污染)。**默认值 = 现状行为**(音频监听开、速度 100、不翻转、
/// 滤镜无、显示颜色选项关),只有用户改了才生效 → 零回归。
///
/// 主题配色(scheme color)沿用既有 schemecolor 机制:若 project.json 有 schemecolor 属性,UI 直接复用
/// 那条 WallpaperProperty(走 WallpaperPropertyStore);没有则本 store 提供一个默认白色占位值。
final class GeneralWallpaperSettings: ObservableObject {
    static let shared = GeneralWallpaperSettings()
    private let d = UserDefaults.standard

    /// 图片筛选器选项(对齐 WE「图片筛选器」常见集:无/灰度/棕褐/反相/暖/冷)。
    /// rawValue 即 shader 用的整数索引(0=无),持久化也存这个整数。
    enum ImageFilter: Int, CaseIterable, Identifiable {
        case none = 0, grayscale, sepia, invert, warm, cool
        var id: Int { rawValue }
        var label: String {
            switch self {
            case .none: return "无"
            case .grayscale: return "灰度"
            case .sepia: return "棕褐"
            case .invert: return "反相"
            case .warm: return "暖色"
            case .cool: return "冷色"
            }
        }
    }

    // MARK: - 默认值(= 现状行为,零回归)
    static let defaultAudioListen = true
    static let defaultVolume = 100.0          // 0–100
    static let defaultPlaybackSpeed = 100.0   // 0–100,100=正常速度(WE 默认)
    static let defaultFlip = false
    static let defaultFilter = 0              // ImageFilter.none
    static let defaultShowColorOptions = false
    // 鼠标视差无固定默认常量:默认值 = 该壁纸 pkg 的 cameraparallax(见 pkgCameraParallax(_:)),不再无条件默认开。

    private func key(_ id: String, _ field: String) -> String { "wpg.\(id).\(field)" }
    private func hasValue(_ id: String, _ field: String) -> Bool { d.object(forKey: key(id, field)) != nil }

    // MARK: - 1) 音频监听(Audio responsive)— bool,默认开
    func audioListen(_ id: String) -> Bool {
        hasValue(id, "audioListen") ? d.bool(forKey: key(id, "audioListen")) : Self.defaultAudioListen
    }
    func setAudioListen(_ v: Bool, _ id: String) { d.set(v, forKey: key(id, "audioListen")); objectWillChange.send() }

    // MARK: - 3) 音量(Volume)— 0–100,默认 100
    func volume(_ id: String) -> Double {
        hasValue(id, "volume") ? d.double(forKey: key(id, "volume")) : Self.defaultVolume
    }
    func setVolume(_ v: Double, _ id: String) { d.set(min(100, max(0, v)), forKey: key(id, "volume")); objectWillChange.send() }

    // MARK: - 4) 播放速度(Playback speed)— 0–100,默认 100(=正常速度)
    func playbackSpeed(_ id: String) -> Double {
        hasValue(id, "playbackSpeed") ? d.double(forKey: key(id, "playbackSpeed")) : Self.defaultPlaybackSpeed
    }
    func setPlaybackSpeed(_ v: Double, _ id: String) { d.set(min(100, max(0, v)), forKey: key(id, "playbackSpeed")); objectWillChange.send() }
    /// 速度倍率(0–2,100 滑块=1.0×)。WE 把「播放速度」滑块 0–100 映射成 0–2× 倍速(50=正常之半,100=……
    /// 实际 WE 默认 100 = 1.0×,范围扩到 200 才是 2×;为兼容我们用 0–100 且 100=1.0×、可降速到 0)。
    func speedMultiplier(_ id: String) -> Double { max(0, playbackSpeed(id) / 100.0) }

    // MARK: - 鼠标视差总闸(Mouse parallax)— bool,默认 = pkg 的 cameraparallax 值
    // 真实 WE 的鼠标视差属性栏控件**只在该壁纸 pkg 开启相机视差时出现**(scene.json
    // general.cameraparallax==true,= 引擎 hasParallax 判据);pkg 无视差(false/缺失)的壁纸 WE 根本
    // 不显示此控件,故引擎也不应无条件加。它是**总闸**:开=视差照 pkg(cameraparallax + 层 parallaxDepth +
    // 全局强度滑块)正常生效;关=该壁纸不做任何鼠标驱动视差。
    // 默认值 = pkg 的 cameraparallax(不再无条件默认开):有视差壁纸默认随 pkg(通常 true);用户改了才覆盖。
    // 生效点:SceneRenderer.frameTick 在本开关关时把喂给引擎的 mouseNorm 归零(鼠标驱动视差/交互归中)。
    func mouseParallax(_ id: String) -> Bool {
        hasValue(id, "mouseParallax") ? d.bool(forKey: key(id, "mouseParallax")) : Self.pkgCameraParallax(id)
    }
    func setMouseParallax(_ v: Bool, _ id: String) { d.set(v, forKey: key(id, "mouseParallax")); objectWillChange.send() }

    // MARK: - pkg 视差信息(scene.json general.cameraparallax)
    // 供属性面板判定「是否显示鼠标视差开关」与默认值用。判据与引擎 SceneRenderEngine.hasParallax 一致:
    //   有视差 = cameraparallax==true。即使 amount=0，材质的 g_ParallaxPosition 仍可读取鼠标位置，
    //   所以不能拿 amount 作为关闭整个鼠标输入的条件。pkg 无视差则面板不显示此开关。
    // 直接从 scene 源读 general 节(轻量,无需建整套渲染场景),按 id 缓存(每壁纸只解一次)。
    private struct ParallaxInfo { let cameraParallax: Bool }
    private static var parallaxCache: [String: ParallaxInfo] = [:]
    // mouseParallax(无用户覆盖时)会被渲染线程 60fps 调用 → 缓存读写须加锁(主线程面板也读)。
    private static let parallaxCacheLock = NSLock()

    private static func parallaxInfo(_ id: String) -> ParallaxInfo {
        parallaxCacheLock.lock()
        if let c = parallaxCache[id] { parallaxCacheLock.unlock(); return c }
        parallaxCacheLock.unlock()
        // WE:未声明 cameraparallax 就是关闭，绝不能让普通场景默认跟随鼠标。
        var info = ParallaxInfo(cameraParallax: false)
        let folder = PreferencesStore.shared.libraryRoot.appendingPathComponent(id)
        let fm = FileManager.default
        var source: SceneSource? = nil
        if fm.fileExists(atPath: folder.appendingPathComponent("scene/scene.json").path) ||
           fm.fileExists(atPath: folder.appendingPathComponent("scene.json").path) {
            source = FolderSceneSource(root: folder)
        } else {
            let pkg = folder.appendingPathComponent("scene.pkg")
            if fm.fileExists(atPath: pkg.path) { source = PackageSceneSource(pkgURL: pkg) }
        }
        if let scene = source?.json(for: "scene.json") ?? source?.json(for: "scene/scene.json"),
           let general = scene["general"] as? [String: Any] {
            let cp = (VecParse.unwrap(general["cameraparallax"]) as? Bool) ?? false
            info = ParallaxInfo(cameraParallax: cp)
        }
        parallaxCacheLock.lock()
        parallaxCache[id] = info
        parallaxCacheLock.unlock()
        return info
    }

    /// 该壁纸 pkg 是否确有视差(= 引擎 hasParallax 判据)。属性面板据此决定是否显示「鼠标视差」开关。
    static func hasParallax(_ id: String) -> Bool {
        parallaxInfo(id).cameraParallax
    }
    /// pkg 的 cameraparallax 值(= 鼠标视差开关在无用户覆盖时的默认勾选状态)。
    static func pkgCameraParallax(_ id: String) -> Bool { parallaxInfo(id).cameraParallax }

    // MARK: - 5) 翻转(Flip horizontal)— bool,默认关
    func flip(_ id: String) -> Bool {
        hasValue(id, "flip") ? d.bool(forKey: key(id, "flip")) : Self.defaultFlip
    }
    func setFlip(_ v: Bool, _ id: String) { d.set(v, forKey: key(id, "flip")); objectWillChange.send() }

    // MARK: - 6) 图片筛选器(Color/Image filter)— combo,默认无
    func filter(_ id: String) -> ImageFilter {
        let raw = hasValue(id, "filter") ? d.integer(forKey: key(id, "filter")) : Self.defaultFilter
        return ImageFilter(rawValue: raw) ?? .none
    }
    func setFilter(_ v: ImageFilter, _ id: String) { d.set(v.rawValue, forKey: key(id, "filter")); objectWillChange.send() }

    // MARK: - 7) 显示颜色选项(Show color options)— bool,默认关
    func showColorOptions(_ id: String) -> Bool {
        hasValue(id, "showColorOptions") ? d.bool(forKey: key(id, "showColorOptions")) : Self.defaultShowColorOptions
    }
    func setShowColorOptions(_ v: Bool, _ id: String) { d.set(v, forKey: key(id, "showColorOptions")); objectWillChange.send() }

    /// 是否有任何通用区覆盖(用于「恢复默认」判定 / 调试)。
    func hasOverrides(_ id: String) -> Bool {
        ["audioListen", "volume", "playbackSpeed", "mouseParallax", "flip", "filter", "showColorOptions"].contains { hasValue(id, $0) }
    }
    /// 重置该壁纸的通用区到默认。
    func reset(_ id: String) {
        for f in ["audioListen", "volume", "playbackSpeed", "mouseParallax", "flip", "filter", "showColorOptions"] {
            d.removeObject(forKey: key(id, f))
        }
        objectWillChange.send()
    }
}
