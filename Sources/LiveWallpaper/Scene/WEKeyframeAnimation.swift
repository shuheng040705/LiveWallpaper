import Foundation

/// WE 对象/特效属性的**关键帧动画**(`{animation:{c0/c1/c2 keyframes, options}, value:base}`)。
/// 用于 opacity 的 alpha 包络(打雷淡入淡出)、color/brightness 周期变化、对象 origin/angles
/// 摆动(头发/发饰/火)等。
///
/// === lwe 是否实现关键帧动画 ===
/// **否(穷尽确认)**。在 `/Users/a55555/Developer/reference/linux-wallpaperengine/src`(排除 External 第三方)中:
///   · `keyframe`、`bezier`、`hermite` 命中数均为 0;
///   · 没有任何代码解析关键帧的 `c0/c1/c2` 通道、`frame`/`value` 对、`front`/`back` 手柄、
///     `lockangle`/`locklength`/`wraploop`;
///   · 仅有的 `animation` 字段是 `ObjectParser.cpp:307` 的 `ImageAnimationLayer.animation`
///     ——那是 puppet warp 图层的**整数 id**(`it.user("animation", properties, 0)`),不是曲线;
///   · `TextureParser::parseAnimations`(TextureParser.cpp:207)解析的是**精灵表帧网格**,不是属性曲线;
///   · 唯一的样条求值是 `CParticle.cpp:2123` 的 Catmull-Rom,用于粒子绳(rope)几何,与属性关键帧无关;
///   · `Maths.cpp:19` 只有一个线性 lerp 辅助。
/// 因此本类型照**真 WE 的关键帧数据/语义**自实现(用户授权:"lwe 没有就扣数据")。
///
/// === 插值曲线(本次改动)===
/// 旧实现:两关键帧间**线性 lerp**(手柄被丢弃),摇摆缓动机械、拐点硬。
/// 新实现:**图形编辑器三次贝塞尔**(graph-editor cubic Bezier,与 AE / Unity AnimationCurve 同族)。
/// WE 关键帧数据每帧带:`frame`(X=时间轴/帧)、`value`(Y=值)、`front:{enabled,magic,x,y}`(出切线手柄,
/// 指向下一帧)、`back:{enabled,magic,x,y}`(入切线手柄,来自上一帧)、`lockangle`、`locklength`。
/// 对相邻两帧 A→B,曲线为以 (frame,value) 为平面坐标的二维三次贝塞尔:
///     P0 = (A.frame, A.value)
///     P1 = P0 + A.front.(x,y)      // A 的出手柄(front)
///     P2 = P3 + B.back.(x,y)       // B 的入手柄(back)
///     P3 = (B.frame, B.value)
/// 曲线按 **X(时间)参数化**:给定当前帧 t,在 X(t) 上解贝塞尔参数 s∈[0,1](牛顿+二分),再取该 s 的 Y。
///
/// === 手柄 x/y 语义的假设(⚠️ 需用户裁决)===
/// 真 WE 编辑器把 front/back 手柄存为**相对该关键帧的偏移向量**,x 在时间(帧)轴、y 在值轴。
/// 本实现按此约定:`P1 = (A.frame + A.front.x, A.value + A.front.y)`,
///               `P2 = (B.frame + B.back.x,  B.value + B.back.y)`。
/// 我**无法在磁盘上找到已解包的御剑 scene.json**(pkg 为二进制打包、temp 下载已清),故未能对御剑 482/52/45 的
/// 实测手柄数值做数值复核。以下两点为显式假设,**若与实测不符请裁决**:
///   (A) front.x/back.x 的**符号/方向**:本实现取 front.x 为正向(指向 B,即 +时间),back.x 为负向偏移
///       (从 B 指回 A,即 back.x 实测应为负值时直接相加即得 P2 落在 A 一侧)。若 WE 实测 back.x 存的是
///       正幅值(需取负),改 `b.frame + bk.x` 为 `b.frame - bk.x`(已在代码处标注)。
///   (B) 手柄分量的**单位**:假设 x 以"帧"为单位、y 以"值"为单位(与 frame/value 同单位,即绝对偏移)。
///       若 WE 实际把 x 存为"占本段时长的比例"(0..1),需乘以段长 (B.frame-A.frame);此分支已写好但默认关闭
///       (`handleXIsFraction = false`),如实测为比例制把它设 true。
/// `magic`:WE 编辑器内部的手柄类型/版本标记,对求值无影响,忽略(标注)。
/// `enabled`:手柄是否启用。`enabled=false` → 该侧无切线,退化为**该端点处水平**(贝塞尔控制点落在端点本身,
///       即手柄长度 0),与 AE/编辑器"无手柄=直线段端"一致;若两端手柄都 disabled 则整段退化为线性(标注)。
/// `lockangle`/`locklength`:WE 编辑器 UID 约束(锁定手柄角度/长度,使前后手柄共线/等长)——那是**编辑期**
///       约束,数据落盘后 front/back 的 x/y 已是约束后的最终值,**求值期无需再处理**,忽略(标注)。
struct WEKeyframeAnimation {
    /// 单侧切线手柄(front=出 / back=入)。x=时间(帧)轴分量,y=值轴分量,均为相对本关键帧的偏移。
    struct Handle { var enabled: Bool; var x: Float; var y: Float }
    struct Key { var frame: Float; var value: Float; var front: Handle?; var back: Handle? }
    enum Mode { case single, loop, mirror }
    var channels: [[Key]]          // c0[, c1, c2];标量 1 条,vec3 3 条(已按 frame 升序)
    var fps: Float = 30
    var length: Float = 1          // 一个 cycle 的总帧数
    var mode: Mode = .single
    var relative: Bool = false
    var base: [Float] = []         // {value:...} 静态基值(relative 时作基;也是 fallback)

    /// ⚠️ 假设(B):手柄 x 是否为"占本段时长比例"(true)还是"绝对帧偏移"(false)。默认绝对偏移。
    static let handleXIsFraction = false

    /// 从属性字典(如 constantshadervalues 的某项 `{animation:{...}, value:...}`)解析。无 animation → nil。
    static func parse(_ any: Any?) -> WEKeyframeAnimation? {
        guard let dict = any as? [String: Any], let anim = dict["animation"] as? [String: Any] else { return nil }
        func floats(_ v: Any?) -> [Float] {
            if let n = v as? NSNumber { return [n.floatValue] }
            if let s = v as? String { return s.split(separator: " ").compactMap { Float($0) } }
            if let a = v as? [Any] { return a.compactMap { ($0 as? NSNumber)?.floatValue } }
            return []
        }
        // 解析一侧手柄;缺失或 enabled=false → 退化(返回 nil 表示该侧无切线,段端水平)。
        func handle(_ v: Any?) -> Handle? {
            guard let h = v as? [String: Any] else { return nil }
            // enabled 默认 true(WE 数据里手柄一般显式给 enabled;缺省按启用处理,符合"有手柄即用")。
            let enabled = (h["enabled"] as? NSNumber)?.boolValue ?? true
            guard enabled else { return Handle(enabled: false, x: 0, y: 0) }
            let x = (h["x"] as? NSNumber)?.floatValue ?? 0
            let y = (h["y"] as? NSNumber)?.floatValue ?? 0
            return Handle(enabled: true, x: x, y: y)
        }
        var channels: [[Key]] = []
        for ck in ["c0", "c1", "c2"] {
            guard let arr = anim[ck] as? [[String: Any]] else { continue }
            var keys: [Key] = []
            for kf in arr {
                let f = (kf["frame"] as? NSNumber)?.floatValue ?? 0
                let v = (kf["value"] as? NSNumber)?.floatValue ?? 0
                keys.append(Key(frame: f, value: v, front: handle(kf["front"]), back: handle(kf["back"])))
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

    /// 定位 t 落在 keys[i]..keys[i+1] 段,用两端 front/back 手柄做三次贝塞尔求值;手柄缺失退化线性。
    private func sample(_ keys: [Key], atFrame t: Float) -> Float {
        guard let first = keys.first else { return 0 }
        if t <= first.frame { return first.value }
        if let last = keys.last, t >= last.frame { return last.value }
        for i in 0..<(keys.count - 1) {
            let a = keys[i], b = keys[i + 1]
            if t >= a.frame && t <= b.frame {
                return bezierSegment(a, b, atFrame: t)
            }
        }
        return keys.last!.value
    }

    /// 段 A→B 的图形编辑器三次贝塞尔:P0=(A.frame,A.value),P3=(B.frame,B.value),
    /// P1=P0+A.front,P2=P3+B.back。曲线按 X(帧)参数化:先在 X 上解贝塞尔参数 s,再取 Y(s)。
    private func bezierSegment(_ a: Key, _ b: Key, atFrame t: Float) -> Float {
        let span = b.frame - a.frame
        if span <= 0.0001 { return b.value }

        // 两端手柄是否有效切线(enabled 且存在)。任一缺失 → 该侧手柄落在端点(长度 0)。
        let fEnabled = a.front?.enabled ?? false
        let bkEnabled = b.back?.enabled ?? false
        // 两端都无手柄 → 整段线性(与旧行为一致,数值连续)。
        if !fEnabled && !bkEnabled {
            let u = (t - a.frame) / span
            return a.value + (b.value - a.value) * u
        }

        // 手柄 x 单位换算(假设 B:绝对帧偏移 vs 占段比例)。
        func hx(_ x: Float) -> Float { Self.handleXIsFraction ? x * span : x }

        // 控制点(平面坐标:X=帧,Y=值)。
        let p0x = a.frame,            p0y = a.value
        let p3x = b.frame,            p3y = b.value
        // P1 = A + front。front 指向 B(+时间方向);front.x 预期为正。
        let f = a.front ?? Handle(enabled: false, x: 0, y: 0)
        let p1x = fEnabled ? p0x + hx(f.x) : p0x
        let p1y = fEnabled ? p0y + f.y      : p0y
        // P2 = B + back。back 指回 A(-时间方向);WE 数据中 back.x 预期为负(直接相加即落在 A 一侧)。
        // ⚠️ 假设(A):若实测 back.x 存的是正幅值,把下一行改成 `p3x - hx(bk.x)`。
        let bk = b.back ?? Handle(enabled: false, x: 0, y: 0)
        let p2x = bkEnabled ? p3x + hx(bk.x) : p3x
        let p2y = bkEnabled ? p3y + bk.y     : p3y

        // 解参数 s,使贝塞尔 X(s) == t。X 在 [p0x..p3x] 单调(graph editor 约束),牛顿迭代 + 二分兜底。
        let s = solveBezierX(target: t, x0: p0x, x1: p1x, x2: p2x, x3: p3x, lo: a.frame, hi: b.frame)
        // 取该 s 的 Y。
        return bezier1D(s, p0y, p1y, p2y, p3y)
    }

    /// 一维三次贝塞尔 B(s) = (1-s)^3 P0 + 3(1-s)^2 s P1 + 3(1-s) s^2 P2 + s^3 P3。
    private func bezier1D(_ s: Float, _ p0: Float, _ p1: Float, _ p2: Float, _ p3: Float) -> Float {
        let mt = 1 - s
        let mt2 = mt * mt, s2 = s * s
        return mt2 * mt * p0 + 3 * mt2 * s * p1 + 3 * mt * s2 * p2 + s2 * s * p3
    }

    /// 一维三次贝塞尔对 s 的导数,用于牛顿步。
    private func bezier1DDeriv(_ s: Float, _ p0: Float, _ p1: Float, _ p2: Float, _ p3: Float) -> Float {
        let mt = 1 - s
        return 3 * mt * mt * (p1 - p0) + 6 * mt * s * (p2 - p1) + 3 * s * s * (p3 - p2)
    }

    /// 求 s∈[0,1] 使 X(s)=target(target 在 [lo,hi]=[p0x,p3x] 内)。牛顿迭代,失败回退二分。
    private func solveBezierX(target: Float, x0: Float, x1: Float, x2: Float, x3: Float,
                              lo: Float, hi: Float) -> Float {
        let span = hi - lo
        if span <= 0.0001 { return 0 }
        // 初值:用线性比例(X 近似单调)。
        var s = (target - lo) / span
        s = min(max(s, 0), 1)
        // 牛顿迭代(最多 8 步,收敛快)。
        for _ in 0..<8 {
            let x = bezier1D(s, x0, x1, x2, x3) - target
            if abs(x) < 0.0005 { return s }
            let dx = bezier1DDeriv(s, x0, x1, x2, x3)
            if abs(dx) < 1e-6 { break }                 // 导数太小,转二分
            s -= x / dx
            if s < 0 || s > 1 { break }                 // 跑出范围,转二分
        }
        // 二分兜底(X 单调假设下保证收敛)。
        var a: Float = 0, b: Float = 1
        s = min(max(s, 0), 1)
        for _ in 0..<24 {
            let x = bezier1D(s, x0, x1, x2, x3)
            if abs(x - target) < 0.0005 { break }
            if x < target { a = s } else { b = s }
            s = 0.5 * (a + b)
        }
        return s
    }
}
