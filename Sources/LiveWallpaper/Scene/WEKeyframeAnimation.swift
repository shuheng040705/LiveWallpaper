import Foundation

/// WE 对象/特效属性的**关键帧动画**(`{animation:{c0/c1/c2 keyframes, options}, value:base}`)。
/// 用于 opacity 的 alpha 包络(打雷淡入淡出)、color/brightness 周期变化等。
/// lwe 不实现此特性(UserSettingParser 只读 value/user/script),故为照真 WE 语义自实现。
/// 插值用**线性**(贝塞尔 front/back 手柄是平滑度,暂不做——mode 的周期才是视觉关键);mode 支持 single/loop/mirror。
struct WEKeyframeAnimation {
    struct Key { var frame: Float; var value: Float }
    enum Mode { case single, loop, mirror }
    var channels: [[Key]]          // c0[, c1, c2];标量 1 条,vec3 3 条(已按 frame 升序)
    var fps: Float = 30
    var length: Float = 1          // 一个 cycle 的总帧数
    var mode: Mode = .single
    var relative: Bool = false
    var base: [Float] = []         // {value:...} 静态基值(relative 时作基;也是 fallback)

    /// 从属性字典(如 constantshadervalues 的某项 `{animation:{...}, value:...}`)解析。无 animation → nil。
    static func parse(_ any: Any?) -> WEKeyframeAnimation? {
        guard let dict = any as? [String: Any], let anim = dict["animation"] as? [String: Any] else { return nil }
        func floats(_ v: Any?) -> [Float] {
            if let n = v as? NSNumber { return [n.floatValue] }
            if let s = v as? String { return s.split(separator: " ").compactMap { Float($0) } }
            if let a = v as? [Any] { return a.compactMap { ($0 as? NSNumber)?.floatValue } }
            return []
        }
        var channels: [[Key]] = []
        for ck in ["c0", "c1", "c2"] {
            guard let arr = anim[ck] as? [[String: Any]] else { continue }
            var keys: [Key] = []
            for kf in arr {
                let f = (kf["frame"] as? NSNumber)?.floatValue ?? 0
                let v = (kf["value"] as? NSNumber)?.floatValue ?? 0
                keys.append(Key(frame: f, value: v))
            }
            keys.sort { $0.frame < $1.frame }
            if !keys.isEmpty { channels.append(keys) }
        }
        guard !channels.isEmpty else { return nil }
        var a = WEKeyframeAnimation(channels: channels)
        if let opts = anim["options"] as? [String: Any] {
            a.fps = (opts["fps"] as? NSNumber)?.floatValue ?? 30
            a.length = max(1, (opts["length"] as? NSNumber)?.floatValue ?? 1)
            switch (opts["mode"] as? String)?.lowercased() {
            case "loop", "wraploop": a.mode = .loop
            case "mirror", "pingpong": a.mode = .mirror
            default: a.mode = .single
            }
        }
        a.relative = (anim["relative"] as? NSNumber)?.boolValue ?? false
        a.base = floats(dict["value"])
        return a
    }

    /// 按当前秒求值,返回各通道值(标量 1 个,vec3 3 个)。
    func evaluate(time: Float) -> [Float] {
        let frame = time * fps
        // 按 mode 折算相位帧到 [0, length]。
        let t: Float
        switch mode {
        case .single: t = min(max(frame, 0), length)
        case .loop:   t = length > 0 ? frame.truncatingRemainder(dividingBy: length) : 0
        case .mirror:                                   // 三角波:0→length→0
            let p = length > 0 ? frame.truncatingRemainder(dividingBy: 2 * length) : 0
            t = p <= length ? p : (2 * length - p)
        }
        var out: [Float] = []
        for (i, keys) in channels.enumerated() {
            var v = sample(keys, atFrame: t)
            if relative, i < base.count { v += base[i] }
            out.append(v)
        }
        return out
    }

    /// 线性插值定位 t 落在 keys[i]..keys[i+1] 之间。
    private func sample(_ keys: [Key], atFrame t: Float) -> Float {
        guard let first = keys.first else { return 0 }
        if t <= first.frame { return first.value }
        if let last = keys.last, t >= last.frame { return last.value }
        for i in 0..<(keys.count - 1) {
            let a = keys[i], b = keys[i + 1]
            if t >= a.frame && t <= b.frame {
                let span = b.frame - a.frame
                let u = span > 0.0001 ? (t - a.frame) / span : 0
                return a.value + (b.value - a.value) * u
            }
        }
        return keys.last!.value
    }
}
