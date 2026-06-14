import Foundation

/// 轻量偏好存储。基于 UserDefaults。
final class PreferencesStore {
    static let shared = PreferencesStore()
    private let d = UserDefaults.standard

    /// 默认指向用户经 CrossOver 运行的 Wallpaper Engine 工坊目录。
    private let defaultRoot = "/Users/a55555/Library/Application Support/CrossOver/Bottles/Steam/drive_c/Program Files (x86)/Steam/steamapps/workshop/content/431960"

    var libraryRoot: URL {
        get {
            if let s = d.string(forKey: "libraryRoot"), !s.isEmpty {
                return URL(fileURLWithPath: s)
            }
            return URL(fileURLWithPath: defaultRoot)
        }
        set { d.set(newValue.path, forKey: "libraryRoot") }
    }

    var lastWallpaperID: String? {
        get { d.string(forKey: "lastWallpaperID") }
        set { d.set(newValue, forKey: "lastWallpaperID") }
    }

    /// 视频壁纸默认静音。
    var isMuted: Bool {
        get { d.object(forKey: "isMuted") == nil ? true : d.bool(forKey: "isMuted") }
        set { d.set(newValue, forKey: "isMuted") }
    }

    /// 视频音量 0…1(仅在未静音时生效)。默认 1。
    var volume: Double {
        get { d.object(forKey: "volume") == nil ? 1.0 : d.double(forKey: "volume") }
        set { d.set(min(1, max(0, newValue)), forKey: "volume") }
    }

    /// WE 内置资源(粒子贴图/着色器)目录。空=自动探测(~/Documents/assets 等)。
    var weAssetsPath: String? {
        get { let s = d.string(forKey: "weAssetsPath"); return (s?.isEmpty == false) ? s : nil }
        set { d.set(newValue, forKey: "weAssetsPath") }
    }

    /// 创意工坊下载用的 Steam 账号名(可选)。匿名下不了的新内容用它登录下载。
    /// 仅存账号名;密码不存(steamcmd 首次登录会缓存到自己的 config,后续免密)。
    var steamAccount: String? {
        get { let s = d.string(forKey: "steamAccount"); return (s?.isEmpty == false) ? s : nil }
        set { d.set(newValue, forKey: "steamAccount") }
    }

    // MARK: - 壁纸库排序

    /// 排序方式。默认按类型分组。
    var sortKeyRaw: String {
        get { d.string(forKey: "sortKey") ?? "type" }
        set { d.set(newValue, forKey: "sortKey") }
    }
    /// 是否倒序(降序)。
    var sortDescending: Bool {
        get { d.bool(forKey: "sortDescending") }
        set { d.set(newValue, forKey: "sortDescending") }
    }
    /// 壁纸库网格缩略图大小:small/medium/large(默认 medium)。
    var gridSizeRaw: String {
        get { d.string(forKey: "gridSize") ?? "medium" }
        set { d.set(newValue, forKey: "gridSize") }
    }

    /// 上一次下载的平均速度(MB/s)。steamcmd 不汇报实时进度,用历史速度估算进度条。默认 6。
    var lastDownloadSpeedMBps: Double {
        get { let v = d.double(forKey: "lastDownloadSpeedMBps"); return v > 0.1 ? v : 6.0 }
        set { d.set(newValue, forKey: "lastDownloadSpeedMBps") }
    }

    // MARK: - 显示 / 渲染

    /// 视频填充模式:true=铺满裁切(默认),false=完整适应(留黑边)。
    var videoFill: Bool {
        get { d.object(forKey: "videoFill") == nil ? true : d.bool(forKey: "videoFill") }
        set { d.set(newValue, forKey: "videoFill") }
    }

    /// 仅主显示器渲染壁纸。默认 false(所有屏)。
    var mainScreenOnly: Bool {
        get { d.bool(forKey: "mainScreenOnly") }
        set { d.set(newValue, forKey: "mainScreenOnly") }
    }

    /// 场景视差/动效强度。0=静止,1=标准(默认),1.6=强。
    var parallaxStrength: Double {
        get { d.object(forKey: "parallaxStrength") == nil ? 1.0 : d.double(forKey: "parallaxStrength") }
        set { d.set(newValue, forKey: "parallaxStrength") }
    }


    /// 场景动画帧率上限(fps)。壁纸是后台动效,30 足够流畅且 CPU 约减半;0=不限(随显示器刷新率,最费电)。
    /// 默认 30(性能/流畅平衡)。可选 15(省电)/30(平衡)/60(流畅)/0(不限)。
    var frameRateCap: Int {
        get { d.object(forKey: "frameRateCap") == nil ? 30 : d.integer(forKey: "frameRateCap") }
        set { d.set(newValue, forKey: "frameRateCap") }
    }

    // MARK: - 画质 / 性能(渲染管线)

    /// MetalFX 空间放大:场景按 renderScale 渲到低分辨率,再用 MetalFX 升采样到全分辨率(省 GPU、画质优于双线性)。
    /// 默认关(全分辨率渲染)。关时 renderScale<1 走双线性升采样。
    var metalFXEnabled: Bool {
        get { d.bool(forKey: "metalFXEnabled") }
        set { d.set(newValue, forKey: "metalFXEnabled") }
    }
    /// 渲染分辨率比例 [0.5,1.0]:1=原生,0.75=渲 75% 再升采样(省 GPU)。默认 1。
    var renderScale: Double {
        get { let v = d.object(forKey: "renderScale") == nil ? 1.0 : d.double(forKey: "renderScale"); return min(1.0, max(0.5, v)) }
        set { d.set(min(1.0, max(0.5, newValue)), forKey: "renderScale") }
    }
    /// FXAA 抗锯齿:呈现时做一次快速近似抗锯齿(低开销,边缘更平滑)。默认关。
    var fxaaEnabled: Bool {
        get { d.bool(forKey: "fxaaEnabled") }
        set { d.set(newValue, forKey: "fxaaEnabled") }
    }
    /// 壁纸缩放模式(屏幕长宽比 ≠ 壁纸时):0=cover 填满+裁切(WE 默认)、1=fit 适应+黑边(全可见有黑边)、
    /// 2=stretch 拉伸填满(全屏无黑边全可见,但画面被拉伸变形)、3=自适应(比例差大如 16:9→cover 零变形裁空边;
    /// 比例接近屏幕<6%→拉伸填满、形变可忽略;追求人物比例永远正常、无黑边)。默认 0。
    var wallpaperScaleMode: Int {
        get {
            if ProcessInfo.processInfo.environment["WP_FIT"] == "1" { return 1 }
            if ProcessInfo.processInfo.environment["WP_STRETCH"] == "1" { return 2 }
            if ProcessInfo.processInfo.environment["WP_BALANCED"] == "1" { return 3 }
            return d.integer(forKey: "wallpaperScaleMode")
        }
        set { d.set(newValue, forKey: "wallpaperScaleMode") }
    }
    /// 同步呈现:presentsWithTransaction + 主动同步 present,修 Mac 内屏(120Hz ProMotion)上连续动画
    /// 壁纸的横向撕裂/分带(后台线程异步 present 与合成不同步)。默认关。开启需重选壁纸(重建图层)。
    var syncPresent: Bool {
        get { d.bool(forKey: "syncPresent") }
        set { d.set(newValue, forKey: "syncPresent") }
    }
    /// 合成层(带特效/composite 的图层)最多渲染多少帧后冻结(完成)。0=∞ 不限(每帧都渲)。
    /// 用于给「不需要持续动画的特效层」省 GPU(如静态滤镜)。默认 0(不限,安全)。
    var compositeMaxFrames: Int {
        get { d.integer(forKey: "compositeMaxFrames") }   // 默认 0=∞
        set { d.set(newValue, forKey: "compositeMaxFrames") }
    }
    /// 纹理质量上限:0=Low(最大 512px)、1=Medium(1024px)、2=High(原始,默认)。
    /// 超限的大纹理在加载时下采样,省显存/带宽;小纹理不受影响。
    var textureQuality: Int {
        get { d.object(forKey: "textureQuality") == nil ? 2 : d.integer(forKey: "textureQuality") }
        set { d.set(newValue, forKey: "textureQuality") }
    }
    /// textureQuality → 最大边像素(0=无限)。
    var textureMaxDimension: Int {
        switch textureQuality { case 0: return 512; case 1: return 1024; default: return 0 }
    }

    /// 窗口遮挡暂停阈值(%):桌面被其他应用窗口遮挡达此比例即停渲染省电(适配台前调度,不必全屏)。
    /// 0=仅全屏(精确匹配,旧行为);50/75/90=遮挡达该百分比即暂停。默认 90(几乎全遮才停,保守)。
    /// 受「全屏/遮挡时自动暂停」总开关(power)控制。
    var occlusionThreshold: Int {
        get { d.object(forKey: "occlusionThreshold") == nil ? 90 : d.integer(forKey: "occlusionThreshold") }
        set { d.set(newValue, forKey: "occlusionThreshold") }
    }

    /// 内容分级(年龄段)全局筛选:勾选的档(raw:everyone/questionable/mature)。默认全选(显示全部)。
    /// 影响整个库(全部/收藏/各类型的数量与内容都只算勾选档),与 WE 一致。
    var selectedRatings: Set<String> {
        get {
            if let arr = d.array(forKey: "selectedRatings") as? [String] { return Set(arr) }
            return ["everyone", "questionable", "mature"]   // 首次=全选
        }
        set { d.set(Array(newValue), forKey: "selectedRatings") }
    }

    // MARK: - 自动轮换

    /// 是否开启定时自动轮换。
    var rotationEnabled: Bool {
        get { d.bool(forKey: "rotationEnabled") }
        set { d.set(newValue, forKey: "rotationEnabled") }
    }

    /// 轮换间隔(分钟)。默认 30。
    var rotationIntervalMinutes: Int {
        get { let v = d.integer(forKey: "rotationIntervalMinutes"); return v > 0 ? v : 30 }
        set { d.set(newValue, forKey: "rotationIntervalMinutes") }
    }

    /// 轮换时随机(true)还是按列表顺序(false)。默认随机。
    var rotationShuffle: Bool {
        get { d.object(forKey: "rotationShuffle") == nil ? true : d.bool(forKey: "rotationShuffle") }
        set { d.set(newValue, forKey: "rotationShuffle") }
    }

    /// 轮换范围:nil=全部可播放;否则限定某类型(video/scene/web)。
    var rotationScopeRaw: String? {
        get { d.string(forKey: "rotationScope") }
        set { d.set(newValue, forKey: "rotationScope") }
    }

    /// 轮换是否仅限收藏。开启后忽略类型范围,只在收藏里轮。
    var rotationFavoritesOnly: Bool {
        get { d.bool(forKey: "rotationFavoritesOnly") }
        set { d.set(newValue, forKey: "rotationFavoritesOnly") }
    }

    // MARK: - 收藏

    /// 收藏的壁纸 id 集合。
    var favorites: Set<String> {
        get { Set(d.stringArray(forKey: "favorites") ?? []) }
        set { d.set(Array(newValue), forKey: "favorites") }
    }

    func isFavorite(_ id: String) -> Bool { favorites.contains(id) }

    func toggleFavorite(_ id: String) {
        var f = favorites
        if f.contains(id) { f.remove(id) } else { f.insert(id) }
        favorites = f
    }
}
