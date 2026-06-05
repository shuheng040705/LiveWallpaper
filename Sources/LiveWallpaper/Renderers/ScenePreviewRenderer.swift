import AppKit

/// Scene 壁纸的临时占位渲染器:显示预览图(铺满)。
/// 阶段 6-9 会用真正的 Metal 场景渲染器替换它。
final class ScenePreviewRenderer: WallpaperRenderer {
    private var imageView: NSImageView?

    func attach(to host: NSView) {
        let iv = NSImageView(frame: host.bounds)
        iv.autoresizingMask = [.width, .height]
        iv.imageScaling = .scaleAxesIndependently   // 拉伸铺满(占位够用)
        iv.imageAlignment = .alignCenter
        iv.wantsLayer = true
        host.addSubview(iv)
        imageView = iv
    }

    func load(_ item: WallpaperItem) {
        guard let url = item.previewURL, let img = NSImage(contentsOf: url) else { return }
        imageView?.image = img
    }

    func start() {}

    func stop() {
        imageView?.removeFromSuperview()
        imageView = nil
    }

    func pause() {}
    func resume() {}
}
