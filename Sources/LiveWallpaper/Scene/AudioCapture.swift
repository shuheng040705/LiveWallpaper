import Foundation
import AVFoundation
import Accelerate
@preconcurrency import ScreenCaptureKit

/// 捕获系统输出音频 → FFT → N 段频谱能量。供音频条/pulse 可视化用。
/// 用 ScreenCaptureKit 的 audio-only SCStream(不录屏,只取声音)。首次需「屏幕与系统音频录制」授权。
/// 全局单例:多个场景共享一份捕获,按需启停(无可视化场景时不抓)。
final class AudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    static let shared = AudioCapture()

    /// 频段数(取够用的上限;实际渲染按需取前 N 段)。
    static let bandCount = 64

    private let lock = NSLock()
    private var _bands = [Float](repeating: 0, count: bandCount)
    // WE 同一 FFT pass 各自用各自 N 算出的 16/32 档(见 process();不是从 64 段重采样)。
    private var _bands16 = [Float](repeating: 0, count: 16)
    private var _bands32 = [Float](repeating: 0, count: 32)
    /// 当前各频段能量 [0,1](已平滑)。线程安全读。
    /// 测试钩子:环境变量 WP_TEST_BANDS=loud → 全 1;=silent → 全 0(确定性渲染音频反应态,
    /// 因为静态 headless 帧看不出实时音频。仅 env 设置时生效,正常运行不受影响)。
    var bands: [Float] {
        if let forced = Self.testBands { return forced }
        lock.lock(); defer { lock.unlock() }; return _bands
    }
    /// 整体响度 [0,1](所有频段均值,供 pulse 用)。
    var level: Float {
        if let f = Self.testBands { return f.first ?? 0 }
        lock.lock(); defer { lock.unlock() }; return _level
    }
    private var _level: Float = 0

    /// WE 的 g_AudioSpectrum16Left/Right 期望 16 段。把内部 bandCount 段重采样成 16 段
    /// (对数 bin 已在 process() 里做过,这里是线性子采样,与 audio-bars 的 bi 映射一致)。
    /// WE 区分左右声道;本捕获是单声道混合,左右喂同一份(对单声道系统音频忠实)。
    static let spectrumBands = 16
    /// WE 的 16 段:在 process() 里与 64/32 同一 FFT pass、用 N=16 的倾斜权重各自算出
    /// (不再从 64 段重采样)。测试钩子同 bands:loud→全 1,silent→全 0。
    var spectrum16: [Float] {
        if let forced = Self.testBands { return Array(forced.prefix(Self.spectrumBands)) }
        lock.lock(); defer { lock.unlock() }; return _bands16
    }
    /// WE 的 32 段(同上,N=32)。供 Simple_Audio_Bars RESOLUTION=32 等取真值。
    var spectrum32: [Float] {
        if let forced = Self.testBands { return Array(forced.prefix(32)) }
        lock.lock(); defer { lock.unlock() }; return _bands32
    }

    /// 解析 WP_TEST_BANDS(只读一次):loud→16×1.0,silent→16×0.0,其余→nil(不强制)。
    private static let testBands: [Float]? = {
        switch ProcessInfo.processInfo.environment["WP_TEST_BANDS"]?.lowercased() {
        case "loud":   return [Float](repeating: 1.0, count: bandCount)
        case "silent": return [Float](repeating: 0.0, count: bandCount)
        case "ramp":
            // 频谱测试图案:相邻段在「高」与「近零」间交替(梳齿),供肉眼验证「每条独立高度 + 条间空隙」
            // 的可视化形状(loud 全 1 时相邻条等高会糊成实心带,看不出条/形)。仅 env 设置时生效。
            return (0..<bandCount).map { i in
                // 每 4 段一组:组内第 0 段高、其余近零 → 出现明显的条与缝。整体再叠一个低频高、高频低的包络。
                let t = Float(i) / Float(bandCount - 1)
                let env = 0.4 + 0.6 * (1.0 - t)                // 0.4..1.0 包络
                return (i % 4 == 0) ? env : 0.02
            }
        default:       return nil
        }
    }()

    private var stream: SCStream?
    private var running = false
    private var refCount = 0          // 有多少壁纸在用;归零则停
    private var permissionRequested = false   // 本会话已弹过一次屏幕录制授权请求 → 不再重复弹(但授权后会经 preflight 自动恢复)
    private var setupInFlight = false       // 正在建流,避免并发重复 setup

    // FFT
    private let fftLength = 1024
    private var fftSetup: FFTSetup?
    private let log2n: vDSP_Length
    private var window: [Float]

    private override init() {
        log2n = vDSP_Length(log2(Float(fftLength)))
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
        window = [Float](repeating: 0, count: fftLength)
        vDSP_hann_window(&window, vDSP_Length(fftLength), Int32(vDSP_HANN_NORM))
        super.init()
    }

    /// 申请使用(引用计数)。第一个使用者触发启动。
    func acquire() {
        lock.lock(); refCount += 1; let first = refCount == 1; lock.unlock()
        if first { start() }
    }
    /// 释放使用。归零则停止捕获。
    func release() {
        lock.lock(); refCount = max(0, refCount - 1); let last = refCount == 0; lock.unlock()
        if last { stop() }
    }

    private func start() {
        // #5:running/setupInFlight 跨线程读写都在 lock 内。
        lock.lock()
        if running || setupInFlight { lock.unlock(); return }
        lock.unlock()
        // 预检屏幕录制权限。没授权:**只弹一次**系统请求(permissionRequested 去重,避免每次切场景反复弹),
        // 但**不**永久放弃 —— 授权后下次 acquire(切/重载壁纸)的 preflight 会通过,自动恢复,无需重启 app。
        // (macOS 重置权限后 preflight 会诚实返回 false;授权后返回 true。)
        if !CGPreflightScreenCaptureAccess() {
            let firstAsk = lock.withLock { () -> Bool in
                let first = !permissionRequested; permissionRequested = true; return first
            }
            if firstAsk {
                Log.write("AudioCapture: 请求屏幕录制授权(系统设置>隐私>屏幕录制,勾选后切一下壁纸即可生效)")
                CGRequestScreenCaptureAccess()
            } else {
                Log.write("AudioCapture: 仍无屏幕录制权限,等待授权(已请求过,不再重复弹窗)")
            }
            return
        }
        lock.lock()
        running = true
        setupInFlight = true
        lock.unlock()
        Task { [weak self] in await self?.setupStream() }
    }

    private func stop() {
        // #5:在锁内置标志、取出本地 stream 引用并清空成员,再在锁外调用可能阻塞/回调重入的 stopCapture
        //      (避免持锁调用 SCStream API 死锁)。
        lock.lock()
        running = false
        let s = stream
        stream = nil
        _bands = [Float](repeating: 0, count: Self.bandCount)
        _bands16 = [Float](repeating: 0, count: 16)
        _bands32 = [Float](repeating: 0, count: 32)
        _level = 0
        lock.unlock()
        s?.stopCapture { _ in }
    }

    private func setupStream() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let display = content.displays.first else { Log.write("AudioCapture: no display"); return }
            // 用一个最小的内容过滤器(必须有,但我们只取音频)。
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let cfg = SCStreamConfiguration()
            cfg.capturesAudio = true
            cfg.excludesCurrentProcessAudio = true   // 不抓本 app 自己的声音
            cfg.sampleRate = 44100
            cfg.channelCount = 2
            // macOS 26 上 audio-only SCStream(只挂 audio 输出 + 2×2 退化视频)实测**不泵音频帧**:
            // startCapture 成功但 didOutputSampleBuffer 永不被调。修法:用非退化视频尺寸 + **也注册并消费
            // .screen 输出**(帧丢弃,只为让流活跃)。视频路径有帧到 → 说明捕获放行;音频帧随之下发。
            cfg.width = 128; cfg.height = 72
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: 8)   // ~8fps 保活,开销极小
            cfg.queueDepth = 5

            let s = SCStream(filter: filter, configuration: cfg, delegate: self)
            try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: DispatchQueue(label: "lw.audio"))
            try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "lw.audio.vid"))
            try await s.startCapture()
            // #5:建流期间可能已被 stop()(running 置 false)→ 别留住孤儿流,锁外停掉它。
            // withLock(同步、async-safe)避免在 async 上下文裸用 NSLock.lock()(Swift 6 会报错)。
            let stillWanted = lock.withLock { () -> Bool in
                setupInFlight = false
                let wanted = running
                if wanted { stream = s }
                return wanted
            }
            if stillWanted {
                Log.write("AudioCapture: started (system audio)")
            } else {
                try? await s.stopCapture()
                Log.write("AudioCapture: started but already stopped, tearing down")
            }
        } catch {
            // #5:running/setupInFlight/permissionRequested 写在锁内(withLock 同步、async-safe)。
            lock.withLock {
                running = false
                setupInFlight = false
                permissionRequested = true   // 建流失败(多半权限)→ 标记已请求,不反复弹;授权后下次 acquire 仍会重试
            }
            Log.write("AudioCapture: setup failed: \(error.localizedDescription)")
        }
    }

    private var sampleLogCount = 0
    private var callbackLogCount = 0

    // SCStreamOutput:音频样本回调。
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // #5:running 跨线程读放锁内。
        lock.lock(); let isRunning = running; lock.unlock()
        // 诊断:确认回调到底有没有被调用、收到什么类型(audio/screen)。前几次各记一条。
        if callbackLogCount < 6 {
            Log.write("AudioCapture: callback type=\(type == .audio ? "audio" : "screen") running=\(isRunning)")
            callbackLogCount += 1
        }
        guard type == .audio, isRunning else { return }   // .screen 帧仅用于保活,丢弃
        // 审计修复(#4c):读 buffer 实际采样率(ASBD.mSampleRate)做频率映射。拿不到则维持上一次值(默认 44100)。
        if let fmt = CMSampleBufferGetFormatDescription(sampleBuffer),
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)?.pointee,
           asbd.mSampleRate > 0 {
            actualSampleRate = asbd.mSampleRate
        }
        guard let samples = Self.pcmFloats(from: sampleBuffer) else {
            if sampleLogCount < 3 { Log.write("AudioCapture: pcmFloats nil"); sampleLogCount += 1 }
            return
        }
        if sampleLogCount < 3 {
            let peak = samples.map { abs($0) }.max() ?? 0
            Log.write("AudioCapture: got \(samples.count) samples, peak=\(peak)")
            sampleLogCount += 1
        }
        process(samples)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.write("AudioCapture: stopped with error: \(error.localizedDescription)")
        // #5:running/stream 写在锁内;清掉成员引用(流已停)。
        lock.lock()
        running = false
        if self.stream === stream { self.stream = nil }
        lock.unlock()
    }

    /// CMSampleBuffer → 单声道 Float PCM(左右**混合**,取均值)。ScreenCaptureKit 音频通常是
    /// **非交错**(planar):AudioBufferList 里每声道一个 mBuffer;也兼容交错(单 buffer 多声道)。
    /// 审计修复(#4a):旧实现 planar 时只取第一个 buffer(声道0)→ 丢右声道;现改为左右取平均。
    private static func pcmFloats(from sb: CMSampleBuffer) -> [Float]? {
        let n = Int(CMSampleBufferGetNumSamples(sb))
        guard n > 0 else { return nil }
        // 用 AudioBufferList 变体取全部声道 buffer。
        var blockBuffer: CMBlockBuffer?
        var ablSize = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sb, bufferListSizeNeededOut: &ablSize, bufferListOut: nil,
            bufferListSize: 0, blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
        guard ablSize > 0 else { return nil }
        let ablPtr = UnsafeMutableRawPointer.allocate(byteCount: ablSize, alignment: 16)
        defer { ablPtr.deallocate() }
        let abl = ablPtr.assumingMemoryBound(to: AudioBufferList.self)
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sb, bufferListSizeNeededOut: nil, bufferListOut: abl,
            bufferListSize: ablSize, blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &blockBuffer)
        guard status == noErr else { return nil }

        let buffers = UnsafeMutableAudioBufferListPointer(abl)
        guard let first = buffers.first, let data0 = first.mData else { return nil }
        let chInBuffer = max(1, Int(first.mNumberChannels))   // 1=planar(每声道独立buffer),>1=交错
        let count = Int(first.mDataByteSize) / MemoryLayout<Float>.size
        let ptr0 = data0.bindMemory(to: Float.self, capacity: count)
        var mono = [Float](); mono.reserveCapacity(min(count, 4096))

        if chInBuffer == 1 {
            // 审计修复(#4a):planar——声道0在 buffers[0],声道1(右)在 buffers[1](若存在)。左右取均值。
            let rightPtr: UnsafePointer<Float>? = {
                guard buffers.count > 1, let d1 = buffers[1].mData else { return nil }
                let c1 = Int(buffers[1].mDataByteSize) / MemoryLayout<Float>.size
                return c1 >= count ? UnsafePointer(d1.bindMemory(to: Float.self, capacity: c1)) : nil
            }()
            var i = 0
            while i < count && mono.count < 4096 {
                let l = ptr0[i]
                let v = rightPtr.map { (l + $0[i]) * 0.5 } ?? l
                mono.append(v); i += 1
            }
        } else {
            // 审计修复(#4a):交错——单 buffer 内 [L,R,L,R,...]。取相邻两声道均值(>2 声道时取前两声道)。
            var i = 0
            while i + chInBuffer <= count && mono.count < 4096 {
                let l = ptr0[i]
                let r = chInBuffer >= 2 ? ptr0[i + 1] : l
                mono.append((l + r) * 0.5)
                i += chInBuffer
            }
        }
        return mono
    }

    /// 审计修复(#4c):实际采样率(Hz)。从最近一帧音频 buffer 的 ASBD mSampleRate 读;读不到回退 cfg 设的 44100。
    /// 用 nonisolated(unsafe) 简单存储:仅 process()/sample 回调串行写读(同一 sampleHandlerQueue),无竞态压力。
    private var actualSampleRate: Double = 44100

    private var sampleAccum = [Float]()   // 累积样本到够 fftLength 再做 FFT(单回调可能不足 1024)

    private func process(_ newSamples: [Float]) {
        guard let setup = fftSetup else { return }
        sampleAccum.append(contentsOf: newSamples)
        guard sampleAccum.count >= fftLength else { return }
        // 取最后 fftLength 个样本,清掉旧的。
        let samples = Array(sampleAccum.suffix(fftLength))
        sampleAccum.removeAll(keepingCapacity: true)
        // **严格对齐 lwe**:lwe(PulseAudioPlaybackRecorder.cpp:238-242)把归一化样本**直接**喂 kiss_fftr,
        // **无任何窗函数**。我们之前自加了 Hann 窗(=偏离 lwe 的自调行为,削峰)→ 去掉,喂裸样本。
        // (注:WE 的「录音音量」全局增益 pkg/lwe 都没有,故不实现——音频条强度全由 pkg 的 u_BarBounds 等决定。)
        var input = samples

        var real = [Float](repeating: 0, count: fftLength / 2)
        var imag = [Float](repeating: 0, count: fftLength / 2)
        var mags = [Float](repeating: 0, count: fftLength / 2)
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                input.withUnsafeBytes { raw in
                    raw.bindMemory(to: DSPComplex.self).baseAddress.map {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(fftLength / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(fftLength / 2))
            }
        }
        // WE 忠实分桶(PulseAudioPlaybackRecorder.cpp:246-263):同一 64-band 循环里直接取第 band*2 个 FFT bin
        //   的幅度(线性、单 bin、不跳 DC——band=0 → bin 0 = DC 也取),压缩 0.35*log10(mag) × 频率倾斜权重
        //   2 - e^((1 - band/(N-1)) - 0.5),clamp 到 1。16/32 在同一循环里用 band>>2 / band>>1 移位写入
        //   (后写覆盖),不再各自对数分桶。
        //   注:本项目是 Float PCM,mags 由 vDSP_zvmags 出(= re²+im²,与 WE 的 f2 = f1*f1+f2*f2 同口径),
        //   故直接用 mags[index],不另开方。actualSampleRate/对数频带映射已废弃(WE 是线性 bin)。
        let bins = fftLength / 2

        var dest64 = [Float](repeating: 0, count: 64)
        var dest32 = [Float](repeating: 0, count: 32)
        var dest16 = [Float](repeating: 0, count: 16)

        for band in 0..<64 {
            let index = band * 2                          // 线性单 bin(含 DC);band=63 → index=126 < bins(512)
            // **严格对齐 lwe**:vDSP_fft_zrip 的 re²+im² 实测 = 标准 DFT 的 **4 倍**(2× 打包,平方→4×;
            //   /tmp/vdsptest 测得 vDSP/标准=4.0)。lwe 用 kiss_fftr=标准未归一 DFT,其 f2=re²+im²。故 ×0.25
            //   把 vDSP 幅度校正到与 kiss_fftr 数值相同 → 同一 0.35*log10(f2) 公式产出与 lwe 完全一致的值。
            let mag = (index < bins ? mags[index] : 0) * 0.25

            var f1: Float = 0
            if mag > 0 { f1 = 0.35 * log10(mag) }
            // 频率倾斜(WE 写法,各 N 用各自 N-1):2 - e^((1 - band/(N-1)) - 0.5)。
            dest64[band]        = min(1, f1 * (2 - exp((1 - Float(band) / 63) - 0.5)))
            dest32[band >> 1]   = min(1, f1 * (2 - exp((1 - Float(band) / 31) - 0.5)))
            dest16[band >> 2]   = min(1, f1 * (2 - exp((1 - Float(band) / 15) - 0.5)))
        }
        // 整体响度:64 段倾斜后的均值(已在 [0,1],不再 ×系数)。
        let overall = min(1, dest64.reduce(0, +) / 64)

        // WE 帧间平滑:movetowards(cur, target, 0.3)——线性逼近,每帧最多走 0.3(不是指数平滑)。
        // 注:WE 在 update() 每个渲染 tick 调用 movetowards、仅在新音频帧到时重算 target;我们的 process()
        // 是音频回调驱动(≈每积满 1024 样本一次),故此处按音频帧节奏走 0.3 步进(见返回说明)。
        lock.lock()
        for i in 0..<64 { _bands[i] = Self.movetowards(_bands[i], dest64[i], 0.3) }
        for i in 0..<32 { _bands32[i] = Self.movetowards(_bands32[i], dest32[i], 0.3) }
        for i in 0..<16 { _bands16[i] = Self.movetowards(_bands16[i], dest16[i], 0.3) }
        _level = Self.movetowards(_level, overall, 0.3)
        lock.unlock()
    }

    /// WE 的线性逼近(PulseAudioPlaybackRecorder.cpp movetowards):每步最多移动 maxDelta,
    /// 距离 ≤ maxDelta 时直接落到 target。
    private static func movetowards(_ current: Float, _ target: Float, _ maxDelta: Float) -> Float {
        if abs(target - current) <= maxDelta { return target }
        return current + (target > current ? maxDelta : -maxDelta)
    }
}
