import Foundation
import Combine

/// WE「属性」通用区。只有渲染器真正支持的项目才由 UI 显示；不存在的主题色等能力不造占位控件。
///
/// 持久化:per-wallpaper 存 UserDefaults，key = "wpg.<id>.<field>"(与 WallpaperPropertyStore 的
/// "wp.<id>.<propKey>" 命名空间分开,互不污染)。音频监听采用隐私优先默认值:新壁纸默认关闭，
/// 只有用户在侧边栏为该壁纸明确开启后才会采集系统输出音频。其它默认值保持 WE 通用行为。
///
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

    /// 每壁纸的画面适配。global 表示跟随“设置 > 屏幕适配”，其它值与渲染器的 0...3 模式一致。
    enum Alignment: Int, CaseIterable, Identifiable, Codable {
        case global = -1
        case cover = 0
        case fit = 1
        case stretch = 2
        case balanced = 3

        var id: Int { rawValue }
        var label: String {
            switch self {
            case .global: return "跟随全局"
            case .cover: return "填充"
            case .fit: return "适应"
            case .stretch: return "拉伸"
            case .balanced: return "自适应"
            }
        }
    }

    /// 预设文件使用的稳定快照格式。字段保持基础类型，便于向后兼容与 JSON 导入导出。
    struct Snapshot: Codable, Equatable {
        var audioListen: Bool
        var volume: Double
        var playbackSpeed: Double
        var mouseParallax: Bool
        var alignment: Int
        var position: Double
        var flip: Bool
        var filter: Int
        var showColorOptions: Bool
        var brightness: Double
        var contrast: Double
        var saturation: Double
    }

    // MARK: - 默认值
    // 系统音频采集属于媒体捕获能力。不能仅因为打开 App/切到含音频条的壁纸就自动启动；
    // 用户在侧边栏明确开启“音频响应”后，才为该壁纸持久化 true。
    static let defaultAudioListen = false
    static let defaultVolume = 100.0          // 0–100
    static let defaultPlaybackSpeed = 100.0   // 0–100,100=正常速度(WE 默认)
    static let defaultPosition = 50.0         // 0–100,裁切区域左/上 → 右/下
    static let defaultFlip = false
    static let defaultFilter = 0              // ImageFilter.none
    static let defaultShowColorOptions = false
    static let defaultBrightness = 100.0
    static let defaultContrast = 100.0
    static let defaultSaturation = 100.0
    // 鼠标视差无固定默认常量:默认值 = 该壁纸 pkg 的 cameraparallax(见 pkgCameraParallax(_:)),不再无条件默认开。

    private func key(_ id: String, _ field: String) -> String { "wpg.\(id).\(field)" }
    private func hasValue(_ id: String, _ field: String) -> Bool { d.object(forKey: key(id, field)) != nil }

    // MARK: - 1) 音频监听(Audio responsive)— bool,默认关(需用户明确开启)
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

    // MARK: - 对齐 / 位置
    func alignment(_ id: String) -> Alignment {
        guard hasValue(id, "alignment") else { return .global }
        return Alignment(rawValue: d.integer(forKey: key(id, "alignment"))) ?? .global
    }
    func setAlignment(_ v: Alignment, _ id: String) {
        if v == .global {
            d.removeObject(forKey: key(id, "alignment"))
        } else {
            d.set(v.rawValue, forKey: key(id, "alignment"))
        }
        objectWillChange.send()
    }
    /// 传给 Scene/Video renderer 的最终模式；未覆盖时沿用应用全局选择。
    func effectiveScaleMode(_ id: String) -> Int {
        let v = alignment(id)
        return v == .global ? PreferencesStore.shared.wallpaperScaleMode : v.rawValue
    }
    func position(_ id: String) -> Double {
        hasValue(id, "position") ? d.double(forKey: key(id, "position")) : Self.defaultPosition
    }
    func setPosition(_ v: Double, _ id: String) {
        d.set(min(100, max(0, v)), forKey: key(id, "position"))
        objectWillChange.send()
    }

    // MARK: - 鼠标视差总闸(Mouse parallax)— bool,默认 = pkg 的 cameraparallax 值
    // 真实 WE 的鼠标视差属性栏控件**只在该壁纸 pkg 开启相机视差时出现**(scene.json
    // general.cameraparallax==true,= 引擎 hasParallax 判据);pkg 无视差(false/缺失)的壁纸 WE 根本
    // 不显示此控件,故引擎也不应无条件加。它只控制**相机视差通道**:开=视差照 pkg
    // (cameraparallax + 层 parallaxDepth + 全局强度滑块)正常生效;关=相机视差平滑归中。
    // X-Ray/cursorripple/鼠标粒子等材质交互独立读取真实 g_PointerPosition，不受此开关影响。
    // 默认值 = pkg 的 cameraparallax(不再无条件默认开):有视差壁纸默认随 pkg(通常 true);用户改了才覆盖。
    // 生效点:SceneRenderer.frameTick 作为 cameraParallaxEnabled 单独传给引擎，不再清零交互光标。
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

    // 展开的三个颜色调节项，100 为恒等。Scene 与 Video 均有真实渲染实现。
    func brightness(_ id: String) -> Double {
        hasValue(id, "brightness") ? d.double(forKey: key(id, "brightness")) : Self.defaultBrightness
    }
    func setBrightness(_ v: Double, _ id: String) {
        d.set(min(200, max(0, v)), forKey: key(id, "brightness")); objectWillChange.send()
    }
    func contrast(_ id: String) -> Double {
        hasValue(id, "contrast") ? d.double(forKey: key(id, "contrast")) : Self.defaultContrast
    }
    func setContrast(_ v: Double, _ id: String) {
        d.set(min(200, max(0, v)), forKey: key(id, "contrast")); objectWillChange.send()
    }
    func saturation(_ id: String) -> Double {
        hasValue(id, "saturation") ? d.double(forKey: key(id, "saturation")) : Self.defaultSaturation
    }
    func setSaturation(_ v: Double, _ id: String) {
        d.set(min(200, max(0, v)), forKey: key(id, "saturation")); objectWillChange.send()
    }

    func snapshot(_ id: String) -> Snapshot {
        Snapshot(audioListen: audioListen(id),
                 volume: volume(id),
                 playbackSpeed: playbackSpeed(id),
                 mouseParallax: mouseParallax(id),
                 alignment: alignment(id).rawValue,
                 position: position(id),
                 flip: flip(id),
                 filter: filter(id).rawValue,
                 showColorOptions: showColorOptions(id),
                 brightness: brightness(id),
                 contrast: contrast(id),
                 saturation: saturation(id))
    }

    func apply(_ s: Snapshot, to id: String) {
        d.set(s.audioListen, forKey: key(id, "audioListen"))
        d.set(min(100, max(0, s.volume)), forKey: key(id, "volume"))
        d.set(min(100, max(0, s.playbackSpeed)), forKey: key(id, "playbackSpeed"))
        d.set(s.mouseParallax, forKey: key(id, "mouseParallax"))
        if s.alignment == Alignment.global.rawValue {
            d.removeObject(forKey: key(id, "alignment"))
        } else {
            d.set(Alignment(rawValue: s.alignment)?.rawValue ?? Alignment.cover.rawValue,
                  forKey: key(id, "alignment"))
        }
        d.set(min(100, max(0, s.position)), forKey: key(id, "position"))
        d.set(s.flip, forKey: key(id, "flip"))
        d.set(ImageFilter(rawValue: s.filter)?.rawValue ?? ImageFilter.none.rawValue,
              forKey: key(id, "filter"))
        d.set(s.showColorOptions, forKey: key(id, "showColorOptions"))
        d.set(min(200, max(0, s.brightness)), forKey: key(id, "brightness"))
        d.set(min(200, max(0, s.contrast)), forKey: key(id, "contrast"))
        d.set(min(200, max(0, s.saturation)), forKey: key(id, "saturation"))
        objectWillChange.send()
    }

    /// 是否有任何通用区覆盖(用于「恢复默认」判定 / 调试)。
    func hasOverrides(_ id: String) -> Bool {
        ["audioListen", "volume", "playbackSpeed", "mouseParallax", "alignment", "position",
         "flip", "filter", "showColorOptions", "brightness", "contrast", "saturation"]
            .contains { hasValue(id, $0) }
    }
    /// 重置该壁纸的通用区到默认。
    func reset(_ id: String) {
        for f in ["audioListen", "volume", "playbackSpeed", "mouseParallax", "alignment", "position",
                  "flip", "filter", "showColorOptions", "brightness", "contrast", "saturation"] {
            d.removeObject(forKey: key(id, f))
        }
        objectWillChange.send()
    }
}
