import Foundation
import AVFoundation
import Metal
import CoreVideo

/// 视频纹理(WE 把 MP4 嵌进 .tex 当动态贴图)的逐帧实时播放。
/// AVPlayer 无限循环 + 静音播放 → AVPlayerItemVideoOutput 取 CVPixelBuffer
/// → CVMetalTextureCache 零拷贝转 MTLTexture,每帧由渲染循环调 currentTexture() 拉取。
///
/// 失败兜底:取不到帧时返回上一帧;从未成功则返回首帧静态纹理(decode 阶段已备好)。
final class VideoTexture {
    private let player: AVPlayer
    private let output: AVPlayerItemVideoOutput
    private var loopObserver: NSObjectProtocol?   // 播到结尾 → seek 回 0 重播(手动循环)
    private var textureCache: CVMetalTextureCache?
    private let device: MTLDevice

    private var lastTexture: MTLTexture       // 至少有首帧静态兜底
    let width: Int
    let height: Int

    // 审计修复 #2:pause/resume/deinit(主线程)与 currentTexture(后台渲染线程)并发访问
    // 同一组 AVFoundation 对象(player/output)。用此锁串行化跨线程访问点,消除数据竞争。
    private let avLock = NSLock()

    /// data: 完整 MP4 字节。fallbackFrame: decode 阶段提的首帧(RGBA8)作初值/兜底。
    init?(data: Data, device: MTLDevice, fallback: MTLTexture) {
        self.device = device
        self.lastTexture = fallback
        self.width = fallback.width
        self.height = fallback.height

        // AVPlayer 需要 URL:写临时文件(VideoTexture 生命周期内保留)。
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lw_vidtex_\(UUID().uuidString).mp4")
        guard (try? data.write(to: tmp)) != nil else { return nil }
        self.tmpURL = tmp

        let item = AVPlayerItem(url: tmp)
        // BGRA 输出,直接喂 Metal(bgra8Unorm)。
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        output = AVPlayerItemVideoOutput(pixelBufferAttributes: attrs)
        item.add(output)   // output 绑在**真正播放的** item 上(见下:不再用 AVPlayerLooper)

        // ⚠ 修复「视频卡在兜底帧/打码帧不动」真因:AVPlayerLooper 会**复制** templateItem 生成内部副本来
        //   循环播放,实际播的是副本、而 output 绑在原模板 item 上 → output 永远收不到 pixelBuffer →
        //   hasNewPixelBuffer 恒 false → currentTexture 一直返回静态兜底帧(某些视频首帧是 glitch 打码帧,
        //   就一直显示打码头)。改用普通 AVPlayer + 手动循环(播到结尾 seek 回 0),output 绑在该 item 上能正常收帧。
        let p = AVPlayer(playerItem: item)
        p.isMuted = true                  // 壁纸静音
        p.actionAtItemEnd = .none
        player = p
        loopObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak p] _ in
            p?.seek(to: .zero); p?.play()
        }

        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
        if textureCache == nil { Log.write("VideoTexture: CVMetalTextureCache create failed"); return nil }

        p.play()
        Log.write("VideoTexture: playing \(width)x\(height) (\(data.count) bytes)")
    }

    private let tmpURL: URL

    deinit {
        // 审计修复 #2:清理也走同一锁,与可能在途的 currentTexture 互斥。
        avLock.lock()
        player.pause()
        avLock.unlock()
        if let ob = loopObserver { NotificationCenter.default.removeObserver(ob) }
        try? FileManager.default.removeItem(at: tmpURL)
    }

    // 关键:必须持有 CVMetalTexture 父对象 + 其 CVPixelBuffer,直到 GPU 真正读完该帧。
    // MTLTexture 不 retain 这两者;一旦释放,CVMetalTextureCache 回收底层 IOSurface、
    // AVPlayerItemVideoOutput 的缓冲池复用同一块 surface 写入下一帧 → GPU 正读着旧帧
    // → 几何连续但颜色撕裂(竖直接缝)。
    // 正解:把本帧的 (cvTex, pb) 挂到渲染命令缓冲的 completion handler,GPU 读完才释放。
    private var pending: [(CVMetalTexture, CVPixelBuffer)] = []   // 本帧产出,待 attach

    /// 拉取当前时刻的视频帧 → MTLTexture。无新帧时返回上一帧。线程:渲染循环(后台)。
    func currentTexture() -> MTLTexture {
        // 审计修复 #2:整段持锁,保护对 output 的访问及 lastTexture/pending 的读写,
        // 与主线程 pause/resume/deinit 互斥。
        avLock.lock()
        defer { avLock.unlock() }
        let host = output.itemTime(forHostTime: CACurrentMediaTime())
        guard output.hasNewPixelBuffer(forItemTime: host),
              let pb = output.copyPixelBuffer(forItemTime: host, itemTimeForDisplay: nil) else {
            return lastTexture
        }
        guard let cache = textureCache else { return lastTexture }

        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        var cvTexOut: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, pb, nil,
            .bgra8Unorm, w, h, 0, &cvTexOut)
        guard status == kCVReturnSuccess, let cvTex = cvTexOut,
              let tex = CVMetalTextureGetTexture(cvTex) else {
            return lastTexture
        }
        pending.append((cvTex, pb))
        if pending.count > 4 { pending.removeFirst() }   // 兜底:attach 没被调到时不无限涨
        lastTexture = tex
        return tex
    }

    /// 把本帧产出的视频缓冲挂到命令缓冲的完成回调,GPU 读完才释放(消除撕裂)。
    /// 渲染引擎在 commit 前对每个视频图层调用。
    func attachRetention(to cmd: MTLCommandBuffer) {
        // 与 currentTexture() 对 pending 的 append 使用同一把锁。只在锁内完成原子「交换」,
        // completion handler 的注册放在锁外,避免 Metal 驱动调用进入锁区。
        avLock.lock()
        let hold = pending
        pending.removeAll(keepingCapacity: true)
        avLock.unlock()
        guard !hold.isEmpty else { return }
        cmd.addCompletedHandler { _ in _ = hold }   // 闭包持有到 GPU 完成,之后释放
    }

    /// 暂停/恢复(省电)。
    // 审计修复 #2:主线程调用,与后台 currentTexture 共用 player/output → 持锁。
    func pause() { avLock.lock(); player.pause(); avLock.unlock() }
    func resume() { avLock.lock(); player.play(); avLock.unlock() }
}
