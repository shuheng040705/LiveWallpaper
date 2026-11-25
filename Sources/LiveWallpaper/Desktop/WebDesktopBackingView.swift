import AppKit
import Metal
import QuartzCore

/// 壁纸库打开时，台前调度过场会让普通背景上的 WebKit 画面短暂停住。
/// 在网页下面提交一次黑色 Metal 画面即可维持合成。放大一个像素，不启动渲染循环。
final class WebDesktopBackingView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        layerContentsRedrawPolicy = .never
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {} // 保留已提交的背景，网页在自己的图层绘制。

    override func makeBackingLayer() -> CALayer {
        if let surface = Self.makePresentedBackground() { return surface }
        let fallback = super.makeBackingLayer()
        fallback.backgroundColor = NSColor.black.cgColor
        return fallback
    }

    private static func makePresentedBackground() -> CAMetalLayer? {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let command = queue.makeCommandBuffer() else { return nil }
        let surface = CAMetalLayer()
        surface.device = device
        surface.pixelFormat = .bgra8Unorm
        surface.maximumDrawableCount = 2
        surface.drawableSize = CGSize(width: 1, height: 1)
        surface.contentsGravity = .resize
        surface.isOpaque = true
        surface.backgroundColor = NSColor.black.cgColor
        guard let drawable = surface.nextDrawable() else { return nil }
        let pass = MTLRenderPassDescriptor()
        let color: MTLRenderPassColorAttachmentDescriptor = pass.colorAttachments[0]
        color.texture = drawable.texture
        color.loadAction = .clear
        color.storeAction = .store
        color.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        encoder.endEncoding()
        command.present(drawable)
        command.commit()
        return surface
    }
}
