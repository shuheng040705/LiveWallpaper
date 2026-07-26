import Foundation
import AVFoundation
import Accelerate
import CoreAudio
@preconcurrency import ScreenCaptureKit

/// 捕获系统输出音频 → FFT → N 段频谱能量。供音频条/pulse 可视化用。
/// ⭐默认且唯一路径 = Core Audio 进程 tap(macOS 14.4+):纯抓系统音频输出,**不录屏、无「正在共享」指示、不压
///   WindowServer**。首次启动时系统按 TCC「系统音频录制」弹授权;被拒/无回调 → 拆掉重试 tap,**绝不**回退
///   ScreenCaptureKit(=录屏)。仅当显式 export WP_ALLOW_SCREENCAP_AUDIO=1 时,才允许极端情况退 SCStream(默认关)。
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
        switch WPEnv.vars["WP_TEST_BANDS"]?.lowercased() {
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

    // ⭐Core Audio 进程 tap(macOS 14.4+):纯抓系统音频输出,**无屏幕捕获、无「正在共享」指示、不压 WindowServer**。
    //   这是**唯一默认路径**。tap 死(权限/系统)→ 拆掉重试 tap 本身,**绝不**回退 ScreenCaptureKit(=录屏,
    //   用户已拒、坚决不要)。只有显式设 WP_ALLOW_SCREENCAP_AUDIO=1 才允许在 tap 彻底不可用时退 SCStream(默认关)。
    private var usingTap = false
    private var tapObjectID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var tapIOProcID: AudioDeviceIOProcID?
    private let tapQueue = DispatchQueue(label: "lw.audio.tap")
    private var useProcessTap: Bool { WPEnv.vars["WP_NO_AUDIO_TAP"] == nil }
    /// ⭐默认 false:**绝不**启动 ScreenCaptureKit/录屏。仅当用户显式 export WP_ALLOW_SCREENCAP_AUDIO=1 时,
    ///   才允许在 tap 完全建不起来(创建失败,非"无回调")的极端情况下退回 SCStream。普通运行恒为 false。
    private var allowScreenCapFallback: Bool {
        WPEnv.vars["WP_ALLOW_SCREENCAP_AUDIO"] == "1"
    }
    private var tapRetryScheduled = false   // tap 死后已排了一次延时重试 → 不重复排
    private var tapRetryCount = 0           // tap 连续重试次数(超上限静默无音频,提示去授权)
    private var permissionHintShown = false // 已写过一次"去系统设置授权"提示 → 不刷屏
    private var setupInFlight = false       // 正在建流,避免并发重复 setup

    // ⭐零样本/死流看门狗(修「重新部署后音频条收不到数据」):app 被 killall+重启后,ScreenCaptureKit 守护
    //   (replayd)有时进入坏态 → 新流 startCapture 成功但 didOutputSampleBuffer 永不触发(零样本=音频条平线),
    //   旧码无自愈、只能切壁纸 re-acquire 或重启 Mac。看门狗用**任意回调(audio/screen 保活帧)时间戳**判流是否
    //   存活:screen 保活帧 ~8fps 持续下发(静音也发,不会误判静音为死流),若 N 秒无任何帧 = 流真死 → 拆流重建自愈。
    private var lastFrameCallback: TimeInterval = 0   // 最后一次任意 SCStream 回调(audio/screen)的 systemUptime
    private var streamStartedAt: TimeInterval = 0     // 当前流 setupStream 成功的时刻(判「建了但从未泵帧」)
    private var watchdog: DispatchSourceTimer?        // 看门狗定时器
    private var recoveryCount = 0                     // 已重建次数(超上限暂停自愈,提示需重启 Mac)
    private var lastRecovery: TimeInterval = 0

    // FFT
    private let fftLength = 1024
    private var fftSetup: FFTSetup?
    private let log2n: vDSP_Length

    private override init() {
        log2n = vDSP_Length(log2(Float(fftLength)))
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
        super.init()
    }

    /// 申请使用(引用计数)。第一个使用者触发启动。
    /// ⚠ 不变式:**每个场景/引擎实例最多 acquire 一次**(release 只按 usesAudio 布尔减一次)。
    ///   引擎侧唯一入口是 SceneRenderEngine.acquireAudioOnce;这里记 refCount 便于发现失衡
    ///   ——正常切壁纸应看到 1 →(切走)0;若 refCount 越切越大即为泄漏(2026-07-26 修复过一次)。
    func acquire() {
        lock.lock(); refCount += 1; let n = refCount; let first = refCount == 1; lock.unlock()
        Log.write("AudioCapture: acquire → refCount=\(n)")
        if first { start() }
    }
    /// 释放使用。归零则停止捕获。
    func release() {
        lock.lock(); refCount = max(0, refCount - 1); let n = refCount; let last = refCount == 0; lock.unlock()
        Log.write("AudioCapture: release → refCount=\(n)\(last ? "(归零,停止捕获)" : "")")
        if last { stop() }
    }

    private func start() {
        // #5:running/setupInFlight 跨线程读写都在 lock 内。
        lock.lock()
        if running || setupInFlight { lock.unlock(); return }
        running = true
        setupInFlight = true
        lock.unlock()
        startWatchdog()
        // ⭐唯一默认路径 = Core Audio 进程 tap(无屏幕共享、不压 WindowServer、无「正在共享」指示)。
        //   同步建好即返回;tap 创建失败时**不**自动录屏——只有显式开 WP_ALLOW_SCREENCAP_AUDIO=1 才退 SCStream。
        if useProcessTap, #available(macOS 14.4, *) {
            if setupProcessTap() {
                lock.withLock { setupInFlight = false }
                return
            }
            // tap **创建**失败(API 返回错误,不是"无回调")。默认:静默无音频 + 提示去授权,绝不录屏。
            if !allowScreenCapFallback {
                lock.withLock { running = false; setupInFlight = false }
                showPermissionHintOnce()
                Log.write("AudioCapture: process tap 创建失败且未开 WP_ALLOW_SCREENCAP_AUDIO → 静默无音频(绝不录屏)")
                return
            }
            Log.write("AudioCapture: ⚠WP_ALLOW_SCREENCAP_AUDIO=1 且 tap 创建失败 → 显式允许回退 ScreenCaptureKit(会触发录屏指示)")
        } else if useProcessTap {
            // 系统 <14.4 没有 process tap。默认不录屏。
            if !allowScreenCapFallback {
                lock.withLock { running = false; setupInFlight = false }
                Log.write("AudioCapture: 系统 < macOS 14.4 无 process tap,且未开 WP_ALLOW_SCREENCAP_AUDIO → 无音频(绝不录屏)")
                return
            }
        } else if !allowScreenCapFallback {
            // WP_NO_AUDIO_TAP 显式关了 tap,但未开 WP_ALLOW_SCREENCAP_AUDIO → 仍**绝不录屏**,静默无音频。
            lock.withLock { running = false; setupInFlight = false }
            Log.write("AudioCapture: WP_NO_AUDIO_TAP 关闭 tap 且未开 WP_ALLOW_SCREENCAP_AUDIO → 无音频(绝不录屏)")
            return
        }
        // ↓↓↓ 仅在显式 WP_ALLOW_SCREENCAP_AUDIO=1 时可达。普通运行**永不**进入此分支。↓↓↓
        if !CGPreflightScreenCaptureAccess() {
            lock.withLock { running = false; setupInFlight = false }
            Log.write("AudioCapture: (显式开关)请求屏幕录制授权;系统设置>隐私>屏幕录制,勾选后切壁纸生效")
            CGRequestScreenCaptureAccess()
            return
        }
        Task { [weak self] in await self?.setupStream() }
    }

    /// 写一次"去系统设置授权系统音频录制"的提示(不刷屏)。Core Audio 进程 tap 走 TCC「音频/系统录音」类授权,
    /// 公共 API 无法预检/主动弹窗——首次 AudioDeviceStart 时由系统弹;若曾被拒,这里提示用户手动去设置开启。
    private func showPermissionHintOnce() {
        let first = lock.withLock { () -> Bool in
            let f = !permissionHintShown; permissionHintShown = true; return f
        }
        guard first else { return }
        Log.write("AudioCapture: 若音频条无反应,请到「系统设置 > 隐私与安全性 > 麦克风(或系统音频录制)」为 LiveWallpaper 开启授权(我们仅取声音,不录屏)")
    }

    private func stop() {
        // #5:在锁内置标志、取出本地 stream 引用并清空成员,再在锁外调用可能阻塞/回调重入的 stopCapture
        //      (避免持锁调用 SCStream API 死锁)。
        lock.lock()
        running = false
        let s = stream
        stream = nil
        let wasTap = usingTap
        _bands = [Float](repeating: 0, count: Self.bandCount)
        _bands16 = [Float](repeating: 0, count: 16)
        _bands32 = [Float](repeating: 0, count: 32)
        _level = 0
        lock.unlock()
        stopWatchdog()
        if wasTap { teardownTap() }
        s?.stopCapture { _ in }
    }

    // 看门狗:每 3s 检查流是否还活着(有无任意回调)。死流(N 秒无帧)→ 拆流重建自愈。
    private func startWatchdog() {
        lock.lock()
        if watchdog != nil { lock.unlock(); return }
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "lw.audio.watchdog"))
        t.schedule(deadline: .now() + 4, repeating: 3)
        t.setEventHandler { [weak self] in self?.watchdogTick() }
        watchdog = t
        lock.unlock()
        t.resume()
    }
    private func stopWatchdog() {
        lock.lock(); let t = watchdog; watchdog = nil; lock.unlock()
        t?.cancel()
    }
    private func watchdogTick() {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let isRunning = running, inFlight = setupInFlight, refs = refCount
        let reference = max(streamStartedAt, lastFrameCallback)   // 流启动 or 最后回调,取较晚
        let sinceRecovery = now - lastRecovery
        let onTap = usingTap
        lock.unlock()
        // 仅在「应在跑、未在建流、有使用者」且流/设备启动满 5s 后仍 >5s 无任何帧 = 真死。
        // sinceRecovery>6 退避避免重建风暴;reference>0 确保流/设备已尝试启动。
        guard isRunning, !inFlight, refs > 0, reference > 0 else { return }
        guard now - reference > 5.0, sinceRecovery > 6.0 else { return }
        if onTap {
            // ⭐tap 模式:中途变死(本来活着、突然停回调,如设备切换/全零长会话)→ 拆 tap **重建 tap**,绝不录屏。
            //   计数上限防 flapping(拿几帧又死)无限 churn:超 6 次停看门狗、静默无音频 + 提示授权(绝不录屏)。
            let attempts = lock.withLock { () -> Int in lastRecovery = now; recoveryCount += 1; return recoveryCount }
            teardownTap()
            lock.withLock { running = false; setupInFlight = false }
            if attempts > 6 {
                Log.write("AudioCapture: tap 已重建 \(attempts) 次仍死(flapping),停止重建(静默无音频,绝不录屏)")
                showPermissionHintOnce()
                stopWatchdog()
                return
            }
            Log.write("AudioCapture: 看门狗检测 tap 死流(\(Int(now - reference))s 无 IOProc 回调)→ 拆 tap 重建 tap 第 \(attempts) 次(绝不录屏)")
            start()   // 重走 setupProcessTap;创建失败默认静默无音频(不录屏)
            return
        }
        // SCStream 模式(仅 WP_ALLOW_SCREENCAP_AUDIO=1 才可能在跑)→ 死流自愈重建 SCStream。
        Log.write("AudioCapture: 看门狗检测死流(\(Int(now - reference))s 无任何 SCStream 回调)→ 拆流重建自愈")
        recoverStream()
    }
    private func recoverStream() {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        // 守卫:没人用了不恢复;6s 退避避免重建风暴(看门狗与 didStopWithError 可能同时触发)。
        guard refCount > 0, now - lastRecovery > 6.0 else { lock.unlock(); return }
        lastRecovery = now
        recoveryCount += 1
        let attempts = recoveryCount
        let s = stream
        stream = nil
        running = false
        setupInFlight = false
        lock.unlock()
        s?.stopCapture { _ in }
        if attempts > 6 {   // CPU 修:上限 12→6,死流更快放弃(少烧 ~1 分钟 replayd/coreaudiod);
            Log.write("AudioCapture: 已重建 \(attempts) 次仍死流,守护进程(replayd)可能需重启 Mac 恢复;暂停自愈")
            stopWatchdog()
            return
        }
        start()   // 重新建流(start 会重置 running/setupInFlight 并跑 setupStream)
    }

    // ====================== Core Audio 进程 tap(无屏幕共享) ======================
    /// OSStatus → 可读字符串。Core Audio 错误码多是 FourCharCode('!pri'/'nope'/'who?'等),纯数字看不懂;
    /// 同时给出十进制,便于日志逐步定位到底哪一步失败。
    private static func osStatusDesc(_ s: OSStatus) -> String {
        if s == noErr { return "ok" }
        let u = UInt32(bitPattern: s)
        let bytes = [UInt8(u >> 24 & 0xff), UInt8(u >> 16 & 0xff), UInt8(u >> 8 & 0xff), UInt8(u & 0xff)]
        // 仅当四个字节都是可打印 ASCII 时,展示 FourCC;否则只给数字。
        if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7f }) {
            let fourcc = String(bytes: bytes, encoding: .ascii) ?? ""
            return "\(s) '\(fourcc)'"
        }
        return "\(s)"
    }

    /// 当前系统默认输出设备的 UID(把它作为聚合设备的主子设备,IOProc 更可靠地按输出时钟回调,
    /// 避免"仅 tap、无主设备"时某些机器 IOProc 静默不泵)。取不到返回 nil(退化为纯 tap)。
    private func defaultOutputDeviceUID() -> String? {
        var devID = AudioObjectID(kAudioObjectUnknown)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var err = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &devID)
        guard err == noErr, devID != kAudioObjectUnknown else {
            Log.write("AudioCapture(tap): 取默认输出设备失败 err=\(Self.osStatusDesc(err))(退化为纯 tap 聚合)")
            return nil
        }
        var uidCF: CFString? = nil
        var uidAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        size = UInt32(MemoryLayout<CFString?>.size)
        err = withUnsafeMutablePointer(to: &uidCF) {
            AudioObjectGetPropertyData(devID, &uidAddr, 0, nil, &size, $0)
        }
        guard err == noErr, let uid = uidCF as String? else {
            Log.write("AudioCapture(tap): 取输出设备 UID 失败 err=\(Self.osStatusDesc(err))(退化为纯 tap 聚合)")
            return nil
        }
        return uid
    }

    /// 建全局系统音频 tap + 聚合设备 + IOProc 并启动。成功返回 true(running 维持),失败清理并返回 false。
    /// ⚠每步 OSStatus 都记日志,精确定位到底哪一步失败(创建 tap / 聚合设备 / IOProc / 启动)。
    @available(macOS 14.4, *)
    private func setupProcessTap() -> Bool {
        // 1) 全局 tap:抓所有进程的音频输出混音(空排除列表=tap 全部)。私有(不被别人看到)、不静音(不影响正常出声)。
        let tapDesc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        tapDesc.isPrivate = true
        tapDesc.muteBehavior = .unmuted
        var tapID = AudioObjectID(kAudioObjectUnknown)
        var err = AudioHardwareCreateProcessTap(tapDesc, &tapID)
        Log.write("AudioCapture(tap): step1 AudioHardwareCreateProcessTap err=\(Self.osStatusDesc(err)) tapID=\(tapID)")
        guard err == noErr, tapID != kAudioObjectUnknown else {
            Log.write("AudioCapture(tap): 创建 tap 失败(可能 TCC「系统音频录制」未授权/被拒)")
            return false
        }
        // 2) 建聚合设备:**主子设备 = 系统默认输出** + 把 tap 挂进 tap 列表。
        //   (AudioCap 参考实现亦如此:聚合 = 输出设备 + tap,IOProc 按输出设备时钟稳定回调;纯 tap 在部分机器静默不泵。)
        //   ⚠UID 必须**每进程唯一**(带 PID):上个进程被 killall 时来不及 teardown→旧聚合设备残留在 Core Audio,
        //   新进程建同名 UID 会冲突失败(err 'nope')。带 PID 唯一化避免与残留设备撞名。
        let aggUID = "com.a55555.livewallpaper.audiotap.\(getpid())"
        var desc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "LiveWallpaper Audio Tap",
            kAudioAggregateDeviceUIDKey: aggUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapDesc.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ],
            ],
        ]
        if let outUID = defaultOutputDeviceUID() {
            desc[kAudioAggregateDeviceMainSubDeviceKey] = outUID
            desc[kAudioAggregateDeviceSubDeviceListKey] = [
                [kAudioSubDeviceUIDKey: outUID],
            ]
            Log.write("AudioCapture(tap): step2 聚合主子设备=默认输出 UID=\(outUID)")
        } else {
            Log.write("AudioCapture(tap): step2 无默认输出 UID → 纯 tap 聚合(autostart)")
        }
        var aggID = AudioObjectID(kAudioObjectUnknown)
        err = AudioHardwareCreateAggregateDevice(desc as CFDictionary, &aggID)
        Log.write("AudioCapture(tap): step2 AudioHardwareCreateAggregateDevice err=\(Self.osStatusDesc(err)) aggID=\(aggID)")
        guard err == noErr, aggID != kAudioObjectUnknown else {
            Log.write("AudioCapture(tap): 建聚合设备失败 → 清理 tap")
            AudioHardwareDestroyProcessTap(tapID)
            return false
        }
        // 3) IOProc:每次系统音频回调 → 读 tap 输入 → mono → process()。
        var procID: AudioDeviceIOProcID?
        err = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, tapQueue) { [weak self] (_, inInputData, _, _, _) in
            self?.handleTapInput(inInputData)
        }
        Log.write("AudioCapture(tap): step3 AudioDeviceCreateIOProcIDWithBlock err=\(Self.osStatusDesc(err))")
        guard err == noErr, let proc = procID else {
            Log.write("AudioCapture(tap): 建 IOProc 失败 → 清理聚合设备+tap")
            AudioHardwareDestroyAggregateDevice(aggID)
            AudioHardwareDestroyProcessTap(tapID)
            return false
        }
        // 4) 启动:首次 AudioDeviceStart 时系统按 TCC 弹「音频录制」授权(公共 API 无法预检/主动触发,
        //    全靠这一步)。被拒则 IOProc 静默不回调或全零 → 由 checkTapAlive 兜底提示去授权(绝不录屏)。
        err = AudioDeviceStart(aggID, proc)
        Log.write("AudioCapture(tap): step4 AudioDeviceStart err=\(Self.osStatusDesc(err))")
        guard err == noErr else {
            Log.write("AudioCapture(tap): AudioDeviceStart 失败 → 清理 IOProc+聚合设备+tap")
            AudioDeviceDestroyIOProcID(aggID, proc)
            AudioHardwareDestroyAggregateDevice(aggID)
            AudioHardwareDestroyProcessTap(tapID)
            return false
        }
        // ⚠ 注册前必须复查 running(与 SCStream 路径的 stillWanted 同理,原来这里漏了)。
        //   建 tap / 聚合设备 / IOProc 是 Core Audio 调用,耗时可达数百毫秒;这期间用户若切走壁纸,
        //   release()→stop() 会在锁内读 usingTap(此刻仍为 false)→ teardownTap 无物可拆。随后本函数
        //   才把 tap 注册上去 → 成为**孤儿**:running 已 false,handleTapInput 丢弃所有样本,
        //   checkTapAlive 因 stillUsing=false 直接返回不拆,但 IOProc 仍在持续回调烧 CPU,
        //   一直到进程退出;下次再 start() 还会直接覆写这几个 ID → 旧 tap/聚合设备彻底泄漏。
        let stillWanted = lock.withLock { () -> Bool in
            guard running else { return false }
            tapObjectID = tapID
            aggregateID = aggID
            tapIOProcID = proc
            usingTap = true
            streamStartedAt = ProcessInfo.processInfo.systemUptime   // 存活基准:若 N 秒无样本(权限静默拒绝)→ 拆掉重试 tap
            lastFrameCallback = 0
            return true
        }
        guard stillWanted else {
            Log.write("AudioCapture(tap): 建好时已不再需要(期间切走壁纸)→ 就地拆除,避免孤儿 tap 常驻")
            AudioDeviceStop(aggID, proc)
            AudioDeviceDestroyIOProcID(aggID, proc)
            AudioHardwareDestroyAggregateDevice(aggID)
            AudioHardwareDestroyProcessTap(tapID)
            return false
        }
        Log.write("AudioCapture: started via Core Audio process tap(无屏幕共享、不压 WindowServer)")
        // 一次性存活检查:设备启动后 IOProc 应立即(即便静音也)持续回调;2.5s 内一次都没回调 = tap 死
        //   (多半 macOS 系统音频录制权限静默拒绝)→ 拆 tap 后**重试 tap 本身**(绝不回退录屏)。
        //   静音不会误判(静音设备 IOProc 仍回调静音帧)。
        tapQueue.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.checkTapAlive() }
        return true
    }

    /// tap 一次性存活检查:2.5s 内 IOProc 从未回调 → tap 死(多半 TCC「系统音频录制」权限被拒/未授权)。
    /// ⭐**绝不回退 ScreenCaptureKit**(=录屏,用户坚决不要):拆掉死 tap → 延时重试 tap 本身(给系统/权限弹窗
    ///   生效的时间);连续多次仍死 = 静默无音频 + 写一次去系统设置授权的提示。
    private func checkTapAlive() {
        lock.lock()
        let everCalled = lastFrameCallback > 0
        let stillUsing = usingTap && running && refCount > 0
        lock.unlock()
        guard stillUsing, !everCalled else { return }   // 已回调过(活)或已不用 → 不动
        Log.write("AudioCapture: process tap 2.5s 内 IOProc 一次未回调(疑 TCC「系统音频录制」未授权/被拒)")
        teardownTap()
        scheduleTapRetry()
    }

    /// 拆掉死 tap 后排一次延时重试(重试 tap 本身,绝不录屏)。退避:逐次拉长间隔;超上限则静默无音频 + 提示去授权。
    private func scheduleTapRetry() {
        let info = lock.withLock { () -> (running: Bool, refs: Int, already: Bool, n: Int) in
            running = false
            setupInFlight = false
            let r = (running: running, refs: refCount, already: tapRetryScheduled, n: tapRetryCount)
            return r
        }
        guard info.refs > 0 else { return }            // 没人用了 → 不重试
        guard !info.already else { return }            // 已排过一次 → 不叠
        // 上限:连续 4 次重试 IOProc 仍不回调,基本确定权限被拒/系统不放行 → 停手,静默无音频 + 一次性提示。
        if info.n >= 4 {
            showPermissionHintOnce()
            Log.write("AudioCapture: process tap 连续 \(info.n) 次无回调,停止重试(静默无音频,绝不录屏)。授权后切壁纸重新生效")
            return
        }
        lock.withLock { tapRetryScheduled = true; tapRetryCount += 1 }
        let delay = 3.0 + Double(info.n) * 2.0          // 3s,5s,7s,9s 退避
        Log.write("AudioCapture: \(String(format: "%.0f", delay))s 后重试 process tap(第 \(info.n + 1) 次;绝不回退录屏)")
        tapQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self else { return }
            let go = self.lock.withLock { () -> Bool in
                self.tapRetryScheduled = false
                return self.refCount > 0 && !self.running && !self.setupInFlight
            }
            guard go else { return }
            self.start()   // 重新走 start → setupProcessTap(绝不进 SCStream 分支,除非显式 env)
        }
    }

    /// IOProc 回调(tapQueue 上):读 tap 输入的 Float PCM → 左右混 mono → process()。
    private func handleTapInput(_ inInputData: UnsafePointer<AudioBufferList>) {
        let now = ProcessInfo.processInfo.systemUptime
        // IOProc 真回调到了 = tap 活 → 重置重试计数(下次若再死,退避从头来)。
        // 且若已稳定健康 ≥20s(=非 flapping),重置看门狗重建计数(单次长健康后的偶发死亡不计入 6 次上限)。
        lock.lock()
        lastFrameCallback = now
        let isRunning = running
        tapRetryCount = 0
        if recoveryCount != 0, streamStartedAt > 0, now - streamStartedAt > 20 { recoveryCount = 0 }
        lock.unlock()
        guard isRunning else { return }
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
        guard let first = abl.first, let data0 = first.mData else { return }
        let chInBuf = max(1, Int(first.mNumberChannels))
        let count = Int(first.mDataByteSize) / MemoryLayout<Float>.size
        guard count > 0 else { return }
        let ptr0 = data0.bindMemory(to: Float.self, capacity: count)
        var mono = [Float](); mono.reserveCapacity(min(count, 4096))
        if chInBuf == 1 {
            // planar:声道分在多个 buffer。左=buffers[0],右=buffers[1](若有)。取均值。
            let rightPtr: UnsafePointer<Float>? = {
                guard abl.count > 1, let d1 = abl[1].mData else { return nil }
                let c1 = Int(abl[1].mDataByteSize) / MemoryLayout<Float>.size
                return c1 >= count ? UnsafePointer(d1.bindMemory(to: Float.self, capacity: c1)) : nil
            }()
            var i = 0
            while i < count && mono.count < 4096 {
                let l = ptr0[i]
                mono.append(rightPtr.map { (l + $0[i]) * 0.5 } ?? l); i += 1
            }
        } else {
            // interleaved:单 buffer [L,R,L,R,...]。
            var i = 0
            while i + chInBuf <= count && mono.count < 4096 {
                let l = ptr0[i]; let r = chInBuf >= 2 ? ptr0[i + 1] : l
                mono.append((l + r) * 0.5); i += chInBuf
            }
        }
        if sampleLogCount < 3 {
            let peak = mono.map { abs($0) }.max() ?? 0
            Log.write("AudioCapture(tap): got \(mono.count) samples, peak=\(peak)"); sampleLogCount += 1
        }
        if !mono.isEmpty { process(mono) }
    }

    /// 拆掉 tap 链(停 IOProc → 销毁 IOProc/聚合设备/tap)。锁外调用(Core Audio API 可能阻塞)。
    private func teardownTap() {
        lock.lock()
        let agg = aggregateID, proc = tapIOProcID, tap = tapObjectID
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapIOProcID = nil
        tapObjectID = AudioObjectID(kAudioObjectUnknown)
        usingTap = false
        lock.unlock()
        if agg != kAudioObjectUnknown, let p = proc {
            AudioDeviceStop(agg, p)
            AudioDeviceDestroyIOProcID(agg, p)
        }
        if agg != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(agg) }
        if tap != kAudioObjectUnknown, #available(macOS 14.2, *) { AudioHardwareDestroyProcessTap(tap) }
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
            // ⚠ CPU 修(replayd 占用):视频流只为保活、不看内容 → 压到最小,降 replayd 每帧合成/缩放/拷贝成本。
            //   16×16(实测仍能让音频帧下发,非 2×2 退化尺寸)+ 2fps(每 0.5s 一帧,远高于看门狗 5s 死流阈值)+
            //   关光标/阴影合成。filter 仍用整显示器(改单窗口无效且会丢系统声音,Apple 模型 WindowServer 照常合成)。
            cfg.width = 16; cfg.height = 16
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: 2)   // ~2fps 保活(>看门狗5s阈值,不误判死流)
            cfg.queueDepth = 3                                          // 最小队列深度,省内存
            cfg.showsCursor = false                                     // 不预渲光标进保活帧
            if #available(macOS 14.0, *) { cfg.ignoreShadowsDisplay = true }   // 跳过阴影合成

            let s = SCStream(filter: filter, configuration: cfg, delegate: self)
            try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: DispatchQueue(label: "lw.audio"))
            try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "lw.audio.vid"))
            try await s.startCapture()
            // #5:建流期间可能已被 stop()(running 置 false)→ 别留住孤儿流,锁外停掉它。
            // withLock(同步、async-safe)避免在 async 上下文裸用 NSLock.lock()(Swift 6 会报错)。
            let stillWanted = lock.withLock { () -> Bool in
                setupInFlight = false
                let wanted = running
                if wanted {
                    stream = s
                    streamStartedAt = ProcessInfo.processInfo.systemUptime   // 看门狗基准:从此刻起若 5s 无帧=死流
                    lastFrameCallback = 0
                }
                return wanted
            }
            if stillWanted {
                Log.write("AudioCapture: started (system audio)")
            } else {
                try? await s.stopCapture()
                Log.write("AudioCapture: started but already stopped, tearing down")
            }
        } catch {
            // #5:running/setupInFlight 写在锁内(withLock 同步、async-safe)。(此分支仅 WP_ALLOW_SCREENCAP_AUDIO=1 可达。)
            lock.withLock {
                running = false
                setupInFlight = false
            }
            Log.write("AudioCapture: (显式开关)SCStream setup failed: \(error.localizedDescription)")
        }
    }

    private var sampleLogCount = 0
    private var callbackLogCount = 0

    // SCStreamOutput:音频样本回调。
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // #5:running 跨线程读放锁内。看门狗:任意回调(audio/screen 保活帧)都更新「流存活」时间戳。
        // ⚠CPU 修(replayd/coreaudiod 飙到 256%/160%):**死流 flapping** 模式=「重建→新流吐 1 个保活帧→立刻
        //   死→5s 后又重建」,旧码「任意一帧就 recoveryCount=0」让 12 次上限**永远到不了**=看门狗每 ~12s 无限
        //   重建、把 replayd/coreaudiod 拖爆。修:**只有流持续存活 ≥20s(=真健康、非 flapping)才重置计数**;
        //   flapping 死流(单帧后即死,存活 <20s)计数照常累加到 12 → recoverStream 停看门狗、不再 churn。
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let isRunning = running
        lastFrameCallback = now
        if recoveryCount != 0, streamStartedAt > 0, now - streamStartedAt > 20 { recoveryCount = 0 }
        lock.unlock()
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
        let stillWanted = refCount > 0
        lock.unlock()
        // ⭐流被系统中途停掉(如重新部署/守护重启)且仍有壁纸在用 → 自动重建(退避在 recoverStream 内)。
        if stillWanted {
            Log.write("AudioCapture: 流异常停止但仍有使用者 → 自动重建")
            recoverStream()
        }
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
        // 无窗:lwe(PulseAudioPlaybackRecorder.cpp:236-242)把 (x-128)/128 归一样本**直接**喂 kiss_fftr,
        // 不加任何窗。我方曾在当前会话误加 Hann 窗——Hann 会削平宽带(音乐)频谱峰值 → 条普遍变矮变弱,
        // 这正是用户报的「强度变弱」真因。两天前(6-2)的版本也无窗。删窗 = 对齐 lwe + 恢复强度正确版本。
        // samples 直接当 FFT 输入(vDSP_ctoz 把实样本拆成偶/奇 split complex)。
        var real = [Float](repeating: 0, count: fftLength / 2)
        var imag = [Float](repeating: 0, count: fftLength / 2)
        var mags = [Float](repeating: 0, count: fftLength / 2)
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                samples.withUnsafeBytes { raw in
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
            // 直接用 vDSP 的 re²+im²(原始版本,用户确认强度正确)。2026-06 曾加 ×0.25「校正到 kiss_fftr 尺度」,
            // 但那改变了 0.35*log10(mag) 的绝对强度 → 用户反馈不对 → 撤回。强度尺度回到原始已验证良好状态。
            let mag = index < bins ? mags[index] : 0

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
        // 诊断:周期性记录频谱范围(验证真实音乐下是否出现【负】频谱 = oscilloscope powr(负)=NaN 根因)。
        // 负频谱来自 f1=0.35*log10(mag),mag<1 时 f1<0(lwe 亦如此,不钳);已在 shader 消费端 max(0) 修。低频。
        Self.specLogCounter += 1
        if Self.specLogCounter % 90 == 0 {
            let mn = dest32.min() ?? 0, mx = dest32.max() ?? 0, neg = dest32.filter { $0 < 0 }.count
            Log.write(String(format: "AUDIOSPEC dest32 min=%.3f max=%.3f neg=%d/32 level=%.3f", mn, mx, neg, overall))
        }
    }
    private static var specLogCounter = 0

    /// WE 的线性逼近(PulseAudioPlaybackRecorder.cpp movetowards):每步最多移动 maxDelta,
    /// 距离 ≤ maxDelta 时直接落到 target。
    private static func movetowards(_ current: Float, _ target: Float, _ maxDelta: Float) -> Float {
        if abs(target - current) <= maxDelta { return target }
        return current + (target > current ? maxDelta : -maxDelta)
    }
}
