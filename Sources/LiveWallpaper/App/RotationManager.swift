import AppKit

/// 定时自动轮换壁纸。从壁纸库里按"随机/顺序"挑下一张可播放的壁纸应用。
final class RotationManager {
    private let library: WallpaperLibrary
    private let apply: (WallpaperItem) -> Void
    private let currentID: () -> String?

    private var timer: Timer?
    private var rngState: UInt64 = 0x2545F4914F6CDD1D

    init(library: WallpaperLibrary,
         currentID: @escaping () -> String?,
         apply: @escaping (WallpaperItem) -> Void) {
        self.library = library
        self.currentID = currentID
        self.apply = apply
    }

    var isEnabled: Bool { PreferencesStore.shared.rotationEnabled }

    /// 按当前偏好(重新)启动或停止定时器。
    func reschedule() {
        timer?.invalidate(); timer = nil
        guard PreferencesStore.shared.rotationEnabled else {
            Log.write("rotation: disabled")
            return
        }
        let interval = TimeInterval(max(1, PreferencesStore.shared.rotationIntervalMinutes) * 60)
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.advance() }
        t.tolerance = interval * 0.1
        RunLoop.main.add(t, forMode: .common)
        timer = t
        Log.write("rotation: enabled, every \(PreferencesStore.shared.rotationIntervalMinutes) min, shuffle=\(PreferencesStore.shared.rotationShuffle)")
    }

    func setEnabled(_ on: Bool) {
        PreferencesStore.shared.rotationEnabled = on
        reschedule()
    }

    /// 立即切到下一张(菜单"立即换一张"也用它)。
    func advance() {
        let pool = candidates()
        guard !pool.isEmpty else { Log.write("rotation: empty pool"); return }
        let cur = currentID()
        let next: WallpaperItem
        if PreferencesStore.shared.rotationShuffle {
            // 随机挑一张,尽量不与当前相同。
            var pick = pool[Int(rnd() % UInt64(pool.count))]
            if pool.count > 1, pick.id == cur {
                pick = pool[Int(rnd() % UInt64(pool.count))]
            }
            next = pick
        } else {
            // 顺序:当前的下一张。
            if let cur, let idx = pool.firstIndex(where: { $0.id == cur }) {
                next = pool[(idx + 1) % pool.count]
            } else {
                next = pool[0]
            }
        }
        Log.write("rotation: advance -> \(next.title)")
        apply(next)
    }

    /// 候选池:可播放 + 符合范围限定。"仅收藏"优先级最高。
    private func candidates() -> [WallpaperItem] {
        let p = PreferencesStore.shared
        if p.rotationFavoritesOnly {
            let fav = p.favorites
            let pool = library.items.filter { $0.type.isPlayable && fav.contains($0.id) }
            if !pool.isEmpty { return pool }
            // 收藏为空时不至于卡死,回退到全部可播放。
            Log.write("rotation: favoritesOnly but none favorited → fall back to all")
        }
        let scope = p.rotationScopeRaw.flatMap { WallpaperType(raw: $0) }
        return library.items.filter { item in
            item.type.isPlayable && (scope == nil || item.type == scope)
        }
    }

    // xorshift64(确定性,避免依赖被禁的随机源)。
    private func rnd() -> UInt64 {
        rngState ^= rngState << 13
        rngState ^= rngState >> 7
        rngState ^= rngState << 17
        return rngState
    }
}
