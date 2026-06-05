import Foundation
import AVFoundation

/// 播放壁纸自带的 sound 对象(BGM / 雨声等)。WE sound 对象:sounds[] 路径数组、
/// playbackmode(loop/random)、volume、mintime/maxtime(random 曲间静默)。
/// 与"音频条用的系统声音采集"(AudioCapture)无关——那是抓系统声;这里是放壁纸自己的声。
///
/// 行为(对齐 WE,改掉 lwe"同时放全部曲"的缺陷):
///   - 单曲 / playbackmode!="random":循环单曲(或循环播放列表)。
///   - "random":随机挑曲依次放,曲间静默 random(mintime, maxtime) 秒,循环不息。
/// 全局静音/音量来自 PreferencesStore(与 VideoRenderer 一致,默认 isMuted=true → 不出声);
/// sound 对象自身 volume 作为乘数。音频字节从 SceneSource 取、写临时文件(参考 VideoTexture),
/// 扩展名保留以便 AVAudioPlayer 选对解码器。mp3/wav/m4a/flac 原生支持;ogg 跳过(本库 0 个)。
final class AudioPlayback: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {

    /// 一个 sound 对象的播放组。
    private final class Group {
        var players: [AVAudioPlayer] = []   // 每个音频文件一个 player
        var tempURLs: [URL] = []            // 解包出的临时文件(stop/deinit 删除)
        var desc: SoundDesc
        var current = 0
        init(desc: SoundDesc) { self.desc = desc }
    }

    private let lock = NSLock()
    private var groups: [Group] = []
    private var globalVolume: Float = 1
    private var muted: Bool = true          // 默认静音(与 PreferencesStore.isMuted 默认一致)
    private var paused = false
    private var gapTimers: [Timer] = []

    // MARK: - 生命周期

    /// 加载并(按 startSilent/muted)开始播放一组 sound。会先 stop() 清旧的。
    func load(sounds: [SoundDesc], source: SceneSource, muted: Bool, volume: Float) {
        stop()
        lock.lock(); self.muted = muted; self.globalVolume = volume; lock.unlock()
        for desc in sounds {
            let g = Group(desc: desc)
            for path in desc.sounds {
                let ext = (path as NSString).pathExtension.lowercased()
                if ext == "ogg" { Log.write("AudioPlayback: skip ogg(\(path)) — 不支持"); continue }
                guard let data = source.data(for: path) ?? source.data(for: (path as NSString).lastPathComponent) else {
                    Log.write("AudioPlayback: no data for \(path)"); continue
                }
                let url = URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("wp_audio_\(UUID().uuidString).\(ext.isEmpty ? "mp3" : ext)")
                guard (try? data.write(to: url)) != nil,
                      let player = try? AVAudioPlayer(contentsOf: url) else {
                    Log.write("AudioPlayback: AVAudioPlayer fail \(path)"); try? FileManager.default.removeItem(at: url); continue
                }
                player.delegate = self
                player.prepareToPlay()
                g.players.append(player); g.tempURLs.append(url)
            }
            guard !g.players.isEmpty else { continue }
            lock.lock(); groups.append(g); lock.unlock()
            applyVolume(g)
            if !desc.startSilent { startGroup(g) }
        }
        Log.write("AudioPlayback: loaded \(groups.count) sound group(s), muted=\(muted)")
    }

    /// 停止并释放所有 player + 删临时文件 + 取消计时器。
    func stop() {
        lock.lock()
        let gs = groups; groups = []
        gapTimers.forEach { $0.invalidate() }; gapTimers = []
        lock.unlock()
        for g in gs {
            for p in g.players { p.stop() }
            for u in g.tempURLs { try? FileManager.default.removeItem(at: u) }
        }
    }

    func pause() {
        lock.lock(); paused = true; let gs = groups; lock.unlock()
        for g in gs { for p in g.players where p.isPlaying { p.pause() } }
    }

    func resume() {
        lock.lock(); paused = false; let gs = groups; let m = muted; lock.unlock()
        guard !m else { return }
        // 单曲循环组:恢复在放的;random 组:若没有在放的(曲间静默)则不强行启动,等计时器。
        for g in gs {
            if g.players.count == 1 { g.players[0].play() }
            else if !g.players.contains(where: { $0.isPlaying }) { startGroup(g) }
        }
    }

    func setVolume(_ v: Double) {
        lock.lock(); globalVolume = Float(max(0, min(1, v))); let gs = groups; lock.unlock()
        for g in gs { applyVolume(g) }
    }

    func setMuted(_ m: Bool) {
        lock.lock(); muted = m; let gs = groups; let wasPaused = paused; lock.unlock()
        for g in gs { applyVolume(g) }
        // 取消静音时若之前没在放(初始静音 / random 静默),重新起播。
        if !m, !wasPaused {
            for g in gs where !g.players.contains(where: { $0.isPlaying }) { startGroup(g) }
        }
    }

    // MARK: - 内部

    /// 最终音量 = muted ? 0 : globalVolume × desc.volume。
    private func applyVolume(_ g: Group) {
        lock.lock(); let m = muted; let gv = globalVolume; lock.unlock()
        let v = m ? 0 : gv * max(0, min(1, g.desc.volume))
        for p in g.players { p.volume = v }
    }

    /// 起播一个组:单曲 → 无限循环;多曲 → 当前曲播一次(结束后 delegate 续下一首)。
    private func startGroup(_ g: Group) {
        lock.lock(); let m = muted; let p = paused; lock.unlock()
        guard !m, !p, !g.players.isEmpty else { return }
        if g.players.count == 1 {
            g.players[0].numberOfLoops = -1   // gapless 无限循环
            g.players[0].play()
        } else {
            g.current = min(g.current, g.players.count - 1)
            let pl = g.players[g.current]
            pl.numberOfLoops = 0
            pl.currentTime = 0
            pl.play()
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        // 多曲组的一曲放完:按 playbackmode 挑下一首,random 模式插入 mintime..maxtime 静默。
        lock.lock()
        guard let g = groups.first(where: { $0.players.contains(where: { $0 === player }) }),
              g.players.count > 1 else { lock.unlock(); return }
        let random = (g.desc.playbackmode?.lowercased() == "random")
        let lo = g.desc.minTime, hi = max(g.desc.minTime, g.desc.maxTime)
        // 选下一曲:random 随机(避免立刻重复),否则顺序。
        if random && g.players.count > 1 {
            var n = g.current; while n == g.current { n = Int.random(in: 0..<g.players.count) }
            g.current = n
        } else {
            g.current = (g.current + 1) % g.players.count
        }
        let gap = (random && hi > 0) ? Double(Float.random(in: lo...hi)) : 0
        lock.unlock()
        let fire = { [weak self, weak g] in guard let self, let g else { return }; self.startGroup(g) }
        if gap > 0 {
            DispatchQueue.main.async {
                let t = Timer.scheduledTimer(withTimeInterval: gap, repeats: false) { _ in fire() }
                self.lock.lock(); self.gapTimers.append(t); self.lock.unlock()
            }
        } else {
            DispatchQueue.main.async { fire() }
        }
    }

    deinit { stop() }
}
