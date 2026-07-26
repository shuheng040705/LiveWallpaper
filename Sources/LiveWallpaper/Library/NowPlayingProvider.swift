import Foundation
import CoreGraphics
import ImageIO
import simd

/// 系统「正在播放」(now-playing)读取——让壁纸的 Now Playing widget 显示用户在**任意 app**
/// (Apple Music / Spotify / 浏览器 / 抖音…)正在播放的曲目,而不只是壁纸自带 BGM。
///
/// 数据源 = macOS 私有框架 MediaRemote 的 `MRMediaRemoteGetNowPlayingInfo`。
/// ⚠ 重要限制:Apple 在 **macOS 15.4 起移除了第三方进程对 MediaRemote now-playing 的访问**
///   (macOS 26 同样受限)。本机若被封,符号可能仍能 dlsym 到但回调 info 恒为 nil/空。
///   届时 title/artist 留空,SceneRenderEngine 回退到壁纸自带 BGM 文件名(不影响其它功能)。
///   另:app 需**非沙盒**(LiveWallpaper 是 .accessory 菜单栏 agent,无沙盒)才有机会读到。
final class NowPlayingProvider {
    static let shared = NowPlayingProvider()

    struct ThumbnailPalette: Equatable {
        var hasThumbnail: Bool
        var primaryColor: SIMD3<Float>
        var secondaryColor: SIMD3<Float>
        var tertiaryColor: SIMD3<Float>
        var textColor: SIMD3<Float>
        var highContrastColor: SIMD3<Float>

        static let missing = ThumbnailPalette(
            hasThumbnail: false,
            primaryColor: .zero,
            secondaryColor: .zero,
            tertiaryColor: .zero,
            textColor: SIMD3(repeating: 1),
            highContrastColor: SIMD3(repeating: 1)
        )
    }

    private(set) var title = ""
    private(set) var artist = ""
    /// WE MediaPlaybackEvent:0=stopped,1=playing,2=paused。
    private(set) var playbackState = 0
    private(set) var position: Double = 0
    private(set) var duration: Double = 0
    /// 封面内容变化序号 + 从真实封面像素提取的调色板。revision 只在 artwork data 变化时递增，
    /// 对齐 WE「同一封面跨曲目不重复触发 mediaThumbnailChanged」的事件语义。
    private(set) var thumbnailRevision = 0
    private(set) var thumbnailPalette = ThumbnailPalette.missing
    /// 是否真从系统拿到过非空曲目(诊断:区分"没在播"与"API 被封")。
    private(set) var everReceived = false

    private typealias GetInfoFn = @convention(c) (DispatchQueue, @escaping ([String: Any]?) -> Void) -> Void
    private var getInfo: GetInfoFn?
    private var timer: Timer?
    private var lastArtworkData: Data?

    /// 在主 runloop 启动轮询(实机 app 调;headless 渲染不调 → title 恒空 → 用自带 BGM)。
    func start() {
        guard timer == nil else { return }
        guard let h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW),
              let sym = dlsym(h, "MRMediaRemoteGetNowPlayingInfo") else {
            Log.write("NowPlaying: MediaRemote 符号不可用(macOS 私有 API 受限)→ 用壁纸自带 BGM")
            return
        }
        getInfo = unsafeBitCast(sym, to: GetInfoFn.self)
        poll()
        let t = Timer(timeInterval: 3, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        Log.write("NowPlaying: MediaRemote 已启动轮询(3s)")
    }

    private func poll() {
        getInfo?(DispatchQueue.main) { [weak self] info in
            guard let self else { return }
            let t = (info?["kMRMediaRemoteNowPlayingInfoTitle"] as? String) ?? ""
            let a = (info?["kMRMediaRemoteNowPlayingInfoArtist"] as? String) ?? ""
            let rate = (info?["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? NSNumber)?.doubleValue ?? 0
            let position = (info?["kMRMediaRemoteNowPlayingInfoElapsedTime"] as? NSNumber)?.doubleValue ?? 0
            let duration = (info?["kMRMediaRemoteNowPlayingInfoDuration"] as? NSNumber)?.doubleValue ?? 0
            let artwork = info?["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data
            let state = (t.isEmpty && a.isEmpty) ? 0 : (rate > 0 ? 1 : 2)
            if !t.isEmpty { self.everReceived = true }
            if t != self.title || a != self.artist || state != self.playbackState {
                Log.write("NowPlaying 系统: title='\(t)' artist='\(a)' state=\(state)")
            }
            self.title = t
            self.artist = a
            self.playbackState = state
            self.position = max(0, position)
            self.duration = max(0, duration)
            if artwork != self.lastArtworkData {
                self.lastArtworkData = artwork
                self.thumbnailRevision &+= 1
                self.thumbnailPalette = artwork.flatMap(Self.extractPalette) ?? .missing
                Log.write(
                    "NowPlaying 封面: available=\(self.thumbnailPalette.hasThumbnail) "
                    + "bytes=\(artwork?.count ?? 0) revision=\(self.thumbnailRevision)"
                )
            }
        }
    }

    /// 从 MediaRemote 返回的真实封面像素提取 3 个代表色，再按 WCAG 相对亮度挑文字/黑白高对比色。
    /// Wallpaper Engine 文档只规定字段语义，没有公开其聚类算法；因此这里不声称逐色一致，
    /// 但事件中的每个颜色都直接源自当前封面，而不是固定或随机占位。
    private static func extractPalette(_ data: Data) -> ThumbnailPalette? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let width = 64, height = 64, bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: &pixels,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue
              ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        struct Bucket {
            var count = 0
            var r = 0
            var g = 0
            var b = 0
        }
        var histogram: [Int: Bucket] = [:]
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Int(pixels[index + 3])
            guard alpha >= 128 else { continue }
            let r = Int(pixels[index]), g = Int(pixels[index + 1]), b = Int(pixels[index + 2])
            let key = (r >> 4) << 8 | (g >> 4) << 4 | (b >> 4)
            var bucket = histogram[key] ?? Bucket()
            bucket.count += 1
            bucket.r += r
            bucket.g += g
            bucket.b += b
            histogram[key] = bucket
        }
        guard !histogram.isEmpty else { return nil }

        let candidates: [(color: SIMD3<Float>, count: Int)] = histogram.values.map { bucket in
            let divisor = Float(max(1, bucket.count) * 255)
            return (
                SIMD3(Float(bucket.r) / divisor, Float(bucket.g) / divisor, Float(bucket.b) / divisor),
                bucket.count
            )
        }.sorted { $0.count > $1.count }

        func distance(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
            simd_length(a - b)
        }
        func chooseColor(excluding selected: [SIMD3<Float>]) -> SIMD3<Float> {
            var best = candidates[0].color
            var bestScore: Float = -.infinity
            for candidate in candidates {
                let separation = selected.map { distance(candidate.color, $0) }.min() ?? 1
                guard separation > 0.08 else { continue }
                let score = Float(candidate.count) * (0.2 + separation)
                if score > bestScore {
                    bestScore = score
                    best = candidate.color
                }
            }
            return best
        }
        let primary = candidates[0].color
        let secondary = chooseColor(excluding: [primary])
        let tertiary = chooseColor(excluding: [primary, secondary])

        func linear(_ value: Float) -> Float {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        func luminance(_ color: SIMD3<Float>) -> Float {
            0.2126 * linear(color.x) + 0.7152 * linear(color.y) + 0.0722 * linear(color.z)
        }
        func contrast(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
            let hi = max(luminance(a), luminance(b))
            let lo = min(luminance(a), luminance(b))
            return (hi + 0.05) / (lo + 0.05)
        }
        let black = SIMD3<Float>.zero
        let white = SIMD3<Float>(repeating: 1)
        let highContrast = contrast(primary, white) >= contrast(primary, black) ? white : black
        let paletteText = [secondary, tertiary].max { contrast(primary, $0) < contrast(primary, $1) }
        let text = paletteText.map { contrast(primary, $0) >= 4.5 ? $0 : highContrast } ?? highContrast

        return ThumbnailPalette(
            hasThumbnail: true,
            primaryColor: primary,
            secondaryColor: secondary,
            tertiaryColor: tertiary,
            textColor: text,
            highContrastColor: highContrast
        )
    }
}
