import AppKit

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
}

extension WallpaperRenderer {
    func setMuted(_ muted: Bool) {}   // 默认空实现
    func setVolume(_ v: Double) {}
    func setFillMode(_ fill: Bool) {}
    func reloadInPlace() {}
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
