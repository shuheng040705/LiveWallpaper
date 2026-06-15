import AppKit
import ImageIO

/// 预览图缩略图缓存:用 ImageIO 下采样,避免把上百张大图原尺寸读进内存。
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSURL, NSImage>()
    private let largeCache = NSCache<NSURL, NSImage>()   // 首页 hero 大图(独立缓存,避免与卡片 520px 版本撞键)
    private let queue = DispatchQueue(label: "thumbnail", qos: .utility, attributes: .concurrent)

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
