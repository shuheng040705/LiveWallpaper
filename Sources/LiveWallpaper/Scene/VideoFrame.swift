import Foundation
import AVFoundation
import CoreGraphics

/// 从「视频纹理」(WE 把 MP4 嵌进 .tex 当动态贴图)里取一帧静态画面 → RGBA8。
/// 现阶段取首帧当静态纹理用,让角色/背景正确显示(完整逐帧播放是后续工作)。
enum VideoFrame {

    /// data 是一个完整的 MP4/MOV 容器字节。返回首帧的 RGBA8 像素 + 宽高。失败回 nil。
    static func firstFrameRGBA8(_ data: Data) -> (pixels: [UInt8], width: Int, height: Int)? {
        // AVFoundation 需要文件/URL;写临时文件后由 image generator 取帧。
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lw_vidtex_\(UUID().uuidString).mp4")
        guard (try? data.write(to: tmp)) != nil else { return nil }
        defer { try? FileManager.default.removeItem(at: tmp) }

        let asset = AVURLAsset(url: tmp)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true   // 尊重视频自带的旋转/镜像
        // 兜底帧**必须**取精确第 0 帧:`toleranceAfter = .positiveInfinity` 会返回最近可解的关键帧——
        // 某些视频(如 WuWa×Cyberpunk 3737365345)开头/中间有「glitch 打码」帧,+∞ 容差正好抓到那帧当
        // 静态底图 → 视频未稳定产帧时一直显示打码头(看似"人物头被东西挡住")。零容差取真正的首帧(清晰)。
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        guard let cg = try? gen.copyCGImage(at: .zero, actualTime: nil) else {
            Log.write("VideoFrame: copyCGImage failed (\(data.count) bytes)")
            return nil
        }
        return rgba8(from: cg)
    }

    /// CGImage → 紧密排布的 RGBA8(straight alpha,行距 = w*4)。
    static func rgba8(from cg: CGImage) -> (pixels: [UInt8], width: Int, height: Int)? {
        let w = cg.width, h = cg.height
        guard w > 0, h > 0 else { return nil }
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        // RGBA8、premultipliedLast:视频帧无 alpha(全 255),与 .rgba8Unorm 直传一致。
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: cs, bitmapInfo: info) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (px, w, h)
    }
}
