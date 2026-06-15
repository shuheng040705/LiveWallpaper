import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import simd

/// 首页 hero 高清图:渲染壁纸**实际画面**(场景=引擎离屏渲染一帧、视频=抽帧),磁盘 + 内存缓存。
/// 比 pkg 自带的低清 preview.gif 清晰得多(用户要求「放实际渲染图」)。
/// 失败 / web 类型 / 关闭(WP_NO_RENDERED_HERO)时回退到 ThumbnailCache.largeImage(preview.gif)。
final class RenderedPreviewCache {
    static let shared = RenderedPreviewCache()

    private let mem = NSCache<NSString, NSImage>()
    // 串行后台队列:一次只渲一张,避免多张场景同时占 GPU 影响正在播放的桌面壁纸。
    private let queue = DispatchQueue(label: "rendered-preview", qos: .utility)
    private var inFlight = Set<String>()
    private let lock = NSLock()

    private var cacheDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.a55555.livewallpaper/RenderedPreviews", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// 异步取壁纸实际画面高清图。命中内存/磁盘即时返回;否则后台渲染后回主线程回调。
    /// 关闭(WP_NO_RENDERED_HERO)或不支持(web)→ 回调 nil(调用方回退 gif)。
    func image(for item: WallpaperItem, completion: @escaping (NSImage?) -> Void) {
        if ProcessInfo.processInfo.environment["WP_NO_RENDERED_HERO"] != nil { completion(nil); return }
        let key = item.id as NSString
        if let c = mem.object(forKey: key) { completion(c); return }
        let file = cacheDir.appendingPathComponent("\(item.id).png")
        if let img = NSImage(contentsOf: file) { mem.setObject(img, forKey: key); completion(img); return }

        lock.lock()
        if inFlight.contains(item.id) { lock.unlock(); completion(nil); return }
        inFlight.insert(item.id); lock.unlock()

        queue.async {
            let img = Self.render(item: item, to: file)
            if let img { self.mem.setObject(img, forKey: key) }
            self.lock.lock(); self.inFlight.remove(item.id); self.lock.unlock()
            DispatchQueue.main.async { completion(img) }
        }
    }

    private static func render(item: WallpaperItem, to file: URL) -> NSImage? {
        switch item.type {
        case .scene:
            return renderScene(item: item, to: file)
        case .video:
            return renderVideo(item: item, to: file)
        default:
            return nil   // web 等暂回退 gif
        }
    }

    /// 场景:用 SceneRenderEngine 离屏渲染一帧(暖机若干帧让粒子/动画/3D 就位),写 PNG 缓存。
    private static func renderScene(item: WallpaperItem, to file: URL) -> NSImage? {
        guard let source = SceneSourceFactory.make(for: item),
              let doc = SceneDocument.build(from: source, item: item),
              let engine = SceneRenderEngine() else { return nil }
        engine.load(document: doc, source: source)
        let warm = Int(ProcessInfo.processInfo.environment["WP_HERO_WARM"] ?? "90") ?? 90
        let dt = 1.0 / 60.0
        for i in 0..<max(1, warm) { engine.update(time: Double(i) * dt, mouseNorm: .zero) }
        // 目标尺寸:画布比例,长边封顶 1600(够清晰、控显存)。
        let cw = max(1, Int(doc.canvasWidth)), ch = max(1, Int(doc.canvasHeight))
        var w = cw, h = ch
        let longSide = 1600
        if max(cw, ch) > longSide {
            let s = Double(longSide) / Double(max(cw, ch))
            w = max(1, Int(Double(cw) * s)); h = max(1, Int(Double(ch) * s))
        }
        guard engine.renderToPNG(width: w, height: h, outURL: file) else { return nil }
        return NSImage(contentsOf: file)
    }

    /// 视频:抽 ~1s 处一帧。
    private static func renderVideo(item: WallpaperItem, to file: URL) -> NSImage? {
        guard let url = item.fileURL else { return nil }
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 1600, height: 1600)
        let dur = CMTimeGetSeconds(asset.duration)
        let t = CMTime(seconds: dur > 2 ? 1.0 : max(0, dur / 3), preferredTimescale: 600)
        guard let cg = (try? gen.copyCGImage(at: t, actualTime: nil))
                ?? (try? gen.copyCGImage(at: .zero, actualTime: nil)) else { return nil }
        if let dest = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, cg, nil)
            CGImageDestinationFinalize(dest)
        }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
