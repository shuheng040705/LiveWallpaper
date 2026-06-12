import Foundation

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

    private(set) var title = ""
    private(set) var artist = ""
    /// 是否真从系统拿到过非空曲目(诊断:区分"没在播"与"API 被封")。
    private(set) var everReceived = false

    private typealias GetInfoFn = @convention(c) (DispatchQueue, @escaping ([String: Any]?) -> Void) -> Void
    private var getInfo: GetInfoFn?
    private var timer: Timer?

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
            if !t.isEmpty { self.everReceived = true }
            if t != self.title || a != self.artist {
                self.title = t; self.artist = a
                Log.write("NowPlaying 系统: title='\(t)' artist='\(a)'")
            }
        }
    }
}
