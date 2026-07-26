import AppKit
import ImageIO

/// 预览图缩略图缓存:用 ImageIO 下采样,避免把上百张大图原尺寸读进内存。
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSURL, NSImage>()
    private let largeCache = NSCache<NSURL, NSImage>()   // 首页 hero 大图(独立缓存,避免与卡片 520px 版本撞键)
    private let queue = DispatchQueue(label: "thumbnail", qos: .utility, attributes: .concurrent)

    private init() {
        // 缩略图/大图缓存加 count 上限:整库(上百张)逐张浏览时,520px 缩略图与 2880px hero 大图(每张可达
        // 数十 MB)会在内存里越积越多。NSCache 本就会在内存吃紧时逐出,这里再加显式上限把常驻量压住。
        cache.countLimit = 300        // 卡片缩略图较小,留多些
        largeCache.countLimit = 12    // hero 大图很大,只留最近少量
    }

    func thumbnail(for url: URL, maxPixel: CGFloat = 520, completion: @escaping (NSImage?) -> Void) {
        if let cached = cache.object(forKey: url as NSURL) {
            completion(cached)
            return
        }
        queue.async {
            let image = Self.downsample(url: url, maxPixel: maxPixel)
            if let image { self.cache.setObject(image, forKey: url as NSURL) }
            DispatchQueue.main.async { completion(image) }
        }
    }

    /// 大图(首页 hero 用):下采样到 ~2880px(覆盖大屏 Retina hero,尽量清晰;低清源仍受源分辨率限制),独立缓存。
    func largeImage(for url: URL, completion: @escaping (NSImage?) -> Void) {
        if let cached = largeCache.object(forKey: url as NSURL) {
            completion(cached)
            return
        }
        queue.async {
            let image = Self.downsample(url: url, maxPixel: 2880)
            if let image { self.largeCache.setObject(image, forKey: url as NSURL) }
            DispatchQueue.main.async { completion(image) }
        }
    }

    /// 远程缩略图(创意工坊在线货架用):异步下载 → 解码 → 缓存。失败回 nil(UI 显示占位)。
    /// 复用 `cache`(键=远程 URL),与本地缩略图分开不会撞键(URL 不同)。
    private let remoteSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 15
        cfg.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: cfg)
    }()

    /// 远程缩略图磁盘缓存目录(重启后不重下,首页秒显)。
    private var remoteDiskDir: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.a55555.livewallpaper/RemoteThumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
    private func remoteDiskFile(for url: URL) -> URL {
        // 文件名 = URL 的稳定哈希(避免非法字符 / 过长)。
        var h: UInt64 = 1469598103934665603
        for b in url.absoluteString.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return remoteDiskDir.appendingPathComponent(String(h, radix: 16) + ".img")
    }

    func remoteThumbnail(for url: URL, completion: @escaping (NSImage?) -> Void) {
        if let cached = cache.object(forKey: url as NSURL) { completion(cached); return }
        // 磁盘缓存:重启后内存缓存空,从磁盘读(快),不再每次重新下载。
        let diskFile = remoteDiskFile(for: url)
        DispatchQueue.global(qos: .utility).async {
            if let data = try? Data(contentsOf: diskFile), let image = NSImage(data: data) {
                self.cache.setObject(image, forKey: url as NSURL)
                DispatchQueue.main.async { completion(image) }
                return
            }
            self.remoteSession.dataTask(with: url) { data, _, _ in
                let image = data.flatMap { NSImage(data: $0) }
                if let image, let data { self.cache.setObject(image, forKey: url as NSURL); try? data.write(to: diskFile) }
                DispatchQueue.main.async { completion(image) }
            }.resume()
        }
    }

    /// 轻量「图是否近全黑/极暗」判定:把 NSImage 缩到 ≤32² 算 RGB 平均亮度(0~255),低于阈值视为黑。
    /// 用于库网格判断本地 preview 首帧是否黑屏(开场动画类壁纸的 preview.gif 首帧常是黑幕)。
    /// 取不出位图(失败)→ 当作非黑(false),不误触发引擎渲染回退。
    func isNearBlack(_ image: NSImage, threshold: Double = 8) -> Bool {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return false }
        let w = min(cg.width, 32), h = min(cg.height, 32)
        guard w > 0, h > 0 else { return false }
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var total = 0.0
        var i = 0
        while i < buf.count {
            total += Double(buf[i]) + Double(buf[i + 1]) + Double(buf[i + 2])
            i += 4
        }
        let mean = total / Double(w * h * 3)
        return mean < threshold
    }

    private static func downsample(url: URL, maxPixel: CGFloat) -> NSImage? {
        let srcOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithURL(url as CFURL, srcOptions) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
