import AppKit
import simd

/// 一个渲染器负责把某种类型的壁纸画到一个桌面窗口的内容视图里。
/// 每块屏幕一个渲染器实例。
protocol WallpaperRenderer: AnyObject {
    /// 把自己的视图/图层挂到宿主内容视图(填满)。
    func attach(to host: NSView)
    /// 加载壁纸数据。
    func load(_ item: WallpaperItem)
    func start()
    func stop()
    func pause()
    func resume()
    /// 视频壁纸的静音/音量/填充控制;其它渲染器忽略。
    func setMuted(_ muted: Bool)
    func setVolume(_ v: Double)
    func setFillMode(_ fill: Bool)
    /// 属性改动后就地重载(不重建视图,无黑屏);仅 scene 实现,其它忽略。
    func reloadInPlace()
    /// 本次加载的渲染缺口(没能正确渲染的项,供 UI 弹窗指明)。仅 scene 实现;其它渲染器无缺口=空。
    var renderGaps: [String] { get }
    /// 互动 hit-test:屏幕归一化光标(mouseNorm [-1,1] y上)命中的可交互对象 pkg id(无→nil)。仅 scene 实现。
    /// 供台前调度穿透(光标在交互对象上→窗口吃点击)+ 反应动画判定。
    func interactiveHitTest(mouseNorm: SIMD2<Float>) -> Int?
}

extension WallpaperRenderer {
    func setMuted(_ muted: Bool) {}   // 默认空实现
    func setVolume(_ v: Double) {}
    func setFillMode(_ fill: Bool) {}
    func reloadInPlace() {}
    var renderGaps: [String] { [] }   // 默认无缺口(视频/web 渲染器)
    func interactiveHitTest(mouseNorm: SIMD2<Float>) -> Int? { nil }   // 默认无交互(视频/web)
}

/// 根据壁纸类型创建对应渲染器。
enum RendererFactory {
    static func make(for item: WallpaperItem) -> WallpaperRenderer? {
        switch item.type {
        case .video: return VideoRenderer()
        case .web:   return WebRenderer()
        case .scene: return SceneRenderer()   // 真实 Metal 渲染(内部无设备时自动降级)
        case .application, .unknown: return nil
        }
    }
}
