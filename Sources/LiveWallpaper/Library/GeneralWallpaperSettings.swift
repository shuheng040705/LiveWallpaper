import Foundation
import Combine

/// WE「属性」通用区:每个壁纸顶部都有的 7 个标准通用控件(与 project.json 自定义属性无关)。
/// WE 实拍顺序:音频监听 / 主题配色 / 音量 / 播放速度 / 翻转 / 图片筛选器 / 显示颜色选项。
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

    // MARK: - 鼠标视差(Mouse parallax)— bool,默认开(WE 标准属性;关=强制不跟随鼠标视差。所有壁纸可控)
    func mouseParallax(_ id: String) -> Bool {
        hasValue(id, "mouseParallax") ? d.bool(forKey: key(id, "mouseParallax")) : true
    }
    func setMouseParallax(_ v: Bool, _ id: String) { d.set(v, forKey: key(id, "mouseParallax")); objectWillChange.send() }

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
        ["audioListen", "volume", "playbackSpeed", "flip", "filter", "showColorOptions"].contains { hasValue(id, $0) }
    }
    /// 重置该壁纸的通用区到默认。
    func reset(_ id: String) {
        for f in ["audioListen", "volume", "playbackSpeed", "flip", "filter", "showColorOptions"] {
            d.removeObject(forKey: key(id, f))
        }
        objectWillChange.send()
    }
}
