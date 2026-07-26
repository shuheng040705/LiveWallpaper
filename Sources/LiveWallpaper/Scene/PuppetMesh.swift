import Foundation
import simd

/// WE puppet 网格(`models/*_puppet.mdl`,MDLV0021/0023)+ 骨骼蒙皮动画(MDLS0004 骨骼 + MDLA0006 动画)。
/// 多部件角色部件(主体/长发/眼睛…)用非矩形带偏心的网格几何,当平面 quad 画会散架;静止姿态(bind pose)
/// 即正确摆位。**lwe CImage::loadPuppetMesh 只取 mesh(忽略 MDLS/MDLA),不做动画**;真 WE 有骨骼蒙皮动画
/// (头发/身体待机摇摆、眨眼等),我方在此实现(CPU 蒙皮:每帧求值动画→骨骼矩阵→顶点蒙皮→更新顶点)。
/// 格式经真实文件(3233141951 头_puppet.mdl)逐字节验证:
///  - 顶点 80 字节:pos.xy@[0:8]、骨索引 4×u32@[40:56]、骨权重 4×f32@[56:72]、uv@[72:80]。
///  - MDLS:u8 + u32(ptr) + u32 boneCount;每骨 = u8 flag + u32 id + i32 parent + u32(=64) + 16×f32 行主序局部 bind 矩阵 + JSON cstr。
///  - MDLA:u8 + u32(ptr) + u32 animCount;每动画 = u32 id + u32 + cstr name + cstr mode + f32 fps + u32 frameCount + u32 + u32 boneCount + u32;
///    然后 boneCount 条轨道,每条 = u32 size + (frameCount+1)×36字节(9 floats TRS:tx,ty,tz,rx,ry,rz,sx,sy,sz,旋转为弧度)+ u32 trailer。
struct PuppetMesh {
    /// MDLV 的真实绘制子网格。`startIndex/count` 是 `indices` 中的范围；WE 的 Puppet
    /// clipping 记录引用的是这里的“顺序下标”，不是骨骼 id。
    struct DrawGroup {
        let id: Int
        let startIndex: Int
        let indexCount: Int
    }

    /// Puppet 动态裁剪关系：先用 sourceGroups 画开口，再用该开口裁 targetGroups。
    /// 眨眼 rig 通常以眼白/眼睑为 source，以虹膜/高光为 target。
    struct ClippingMask {
        let texturePath: String
        let targetGroups: [Int]
        let sourceGroups: [Int]
    }

    let size: SIMD2<Float>
    let indices: [UInt16]
    let drawGroups: [DrawGroup]
    let clippingMasks: [ClippingMask]
    // 顶点(原始空间)+ 蒙皮数据:
    private let rawPos: [SIMD2<Float>]      // pos.xy(bind 姿态世界位置)
    private let uv: [SIMD2<Float>]
    // 贴图采样标记的「虹膜色」顶点(高饱和+亮+不透明=虹膜,区别于白眼白/暖肤色/深睫毛)。空=未采样
    // → eyeOcclude 退回旧「UV.v 带」判据。侧脸单眼(白泽夢)虹膜球面展开裂成上下两 V 块、固定 V 带漏下块,故改色判。
    var irisColorMask: [Bool] = []
    // 「亮」顶点(贴图 max(r,g,b)>0.4 且不透明)= 虹膜填充/高光/眼白等眼球亮内容;**深睫毛/眼线(暗)不在内**。
    //   闭眼塌缩后在虹膜跨度内丢弃这些亮顶点 → 去掉漏边的青蓝虹膜高光、保留深睫毛作闭眼弧。空=未采样。
    var eyeBrightMask: [Bool] = []
    private let boneIdx: [SIMD4<UInt32>]    // 每顶点 4 根骨索引
    private let boneWt: [SIMD4<Float>]      // 每顶点 4 个权重(和=1)
    // 骨骼:
    private let parent: [Int]
    private let localBind: [simd_float4x4]  // 每骨局部 bind(父相对)
    private let worldBind: [simd_float4x4]  // 累乘后的世界 bind
    private let invBind: [simd_float4x4]    // 预算:inverse(worldBind[b])
    // 动画(按 id 索引):
    struct Anim { let id: Int; let fps: Float; let frameCount: Int; let mode: String; let tracks: [[[Float]]]; let boneAlpha: [[Float]]? }  // tracks[bone][frame]=9 floats TRS;boneAlpha[bone][frame]=逐骨透明度(SKINNING_ALPHA,WE 眨眼/眉毛用 alpha 淡出眼睑/虹膜层;nil=无此通道,绝大多数 puppet)
    /// 该 animId 是否单次播放(mode=="single",如眨眼:.play() 触发后播一遍停 rest open)。
    func isSingleShot(animId: Int) -> Bool { anims.first(where: { $0.id == animId })?.mode == "single" }
    /// 该 anim 时长(秒)= frameCount/fps。供眨眼调度器算播放窗口。
    func animDuration(animId: Int) -> Double? {
        guard let a = anims.first(where: { $0.id == animId }), a.fps > 0 else { return nil }
        return Double(a.frameCount) / Double(a.fps)
    }
    private let anims: [Anim]
    // 部件间挂点(MDAT0001):父部件用具名 attachment(如「头部」「胸部」)暴露子部件可挂的世界变换。
    // 每条 = (名, 所挂骨索引, 该挂点相对该骨的局部行主序矩阵)。子部件 scene.json 的 attachment 串按名匹配此表。
    struct Attachment { let name: String; let bone: Int; let local: simd_float4x4 }  // local 已转成列主序
    let attachments: [Attachment]

    var hasSkin: Bool { !anims.isEmpty && !parent.isEmpty }
    func hasAnim(_ id: Int) -> Bool { anims.contains { $0.id == id } }   // NSL sway 消费时校验 anim 存在(避免引用编辑器层 id)
    var bindVerts: [Float] { unitVerts(rawPos) }   // 静态 bind 姿态 [x,y,u,v]×N(与旧行为一致)
    var hasBones: Bool { !parent.isEmpty }
    var boneCount: Int { parent.count }
    var vertexCount: Int { rawPos.count }
    /// animationlayers 名写“眨眼”但对象名只是 l/xd/bq/hx 时，只允许紧凑的独立部件
    /// 进入眼睛专用 3D 蒙皮。全身 Puppet（几十根骨、几千顶点）必须走自身 clipping，
    /// 不能把整个人物误当眼球折叠。
    var looksLikeStandaloneEyeRig: Bool {
        parent.count > 0 && parent.count <= 16 && rawPos.count <= 1_024
    }

    /// 采样眼睛贴图标记「虹膜色」顶点(高饱和+亮+不透明=虹膜,排除白眼白/暖肤色/深睫毛/透明)。供 eyeOcclude
    /// 取代「UV.v 带」判据——侧脸单眼(白泽夢)虹膜球面展开后 V 方向裂成上下两块,固定 V 带漏下块;按贴图色判则两块都中。
    /// 通用各角色虹膜色(蓝/绿/黄/红/紫均高饱和),非眼 puppet 也算但不被 eyeOcclude 使用(无害)。
    mutating func computeIrisColorMask(px: [UInt8], width w: Int, height h: Int) {
        guard w > 0, h > 0, px.count >= w * h * 4 else { irisColorMask = []; return }
        let flipV = WPEnv.vars["WP_IRIS_FLIP_V"] != nil   // PNG 行序翻转诊断
        var mask = [Bool](repeating: false, count: rawPos.count)
        var bright = [Bool](repeating: false, count: rawPos.count)
        var sumR = 0, sumB = 0, nHit = 0
        for i in 0..<min(uv.count, rawPos.count) {
            let u = min(max(uv[i].x, 0), 0.999), v0 = min(max(uv[i].y, 0), 0.999)
            let v = flipV ? (1.0 - v0) : v0
            let o = (min(h - 1, Int(v * Float(h))) * w + min(w - 1, Int(u * Float(w)))) * 4
            guard o + 3 < px.count else { continue }
            let r = Float(px[o]), g = Float(px[o + 1]), b = Float(px[o + 2]), a = Float(px[o + 3])
            guard a > 76 else { continue }                       // 不透明(>0.3)
            let mx = max(r, g, b), mn = min(r, g, b)
            guard mx > 102 else { continue }                     // 亮(>0.4)→ 排除深睫毛/眼线
            bright[i] = true                                      // 亮+不透明(虹膜/高光/眼白;深睫毛不在内)
            guard mx > 0, (mx - mn) / mx > 0.3 else { continue } // 高饱和 → 排除白眼白/低饱和肤色
            mask[i] = true; sumR += Int(r); sumB += Int(b); nHit += 1
        }
        // 1-环扩展:把「含虹膜色顶点的三角」的全部顶点纳入——否则三角跨「收/不收」顶点会被拉伸,残留可见虹膜
        //   边缘(色判据只命中高饱和中心,虹膜轮廓半透明/暗顶点漏)。扩展后整片虹膜三角一起收成点=干净消失。
        var expanded = mask
        for t in stride(from: 0, to: indices.count - 2, by: 3) {
            let a = Int(indices[t]), b = Int(indices[t + 1]), c = Int(indices[t + 2])
            if (a < mask.count && mask[a]) || (b < mask.count && mask[b]) || (c < mask.count && mask[c]) {
                if a < expanded.count { expanded[a] = true }
                if b < expanded.count { expanded[b] = true }
                if c < expanded.count { expanded[c] = true }
            }
        }
        irisColorMask = expanded
        eyeBrightMask = bright
        if WPEnv.vars["WP_EYE_OCCLUDE_DBG"] != nil, nHit > 0 {
            Log.write("IRIS-COLOR hit=\(nHit)→\(expanded.filter { $0 }.count) avgR=\(sumR / nHit) avgB=\(sumB / nHit) flipV=\(flipV)")
        }
    }

    /// 父部件具名挂点(如「头部」)的**世界变换**(列主序;平移在列 3)。无该名返回 nil。
    /// = attachLocal · worldBind[bone](行主序链:点 p_row·local·worldBindRow;列主序等价 worldBindCol·localCol·p_col,
    ///   见 parse 里转置约定)。供子部件做部件间 attachment。
    func attachmentWorld(_ name: String) -> simd_float4x4? {
        guard let a = attachments.first(where: { $0.name == name }), a.bone >= 0, a.bone < worldBind.count else { return nil }
        // 行主序语义:attachWorldRow = attachLocalRow · boneWorldRow。列主序矩阵存的是其转置,
        // 故列主序 attachWorldCol = boneWorldCol · attachLocalCol(乘序反转)。
        return worldBind[a.bone] * a.local
    }

    /// 父部件具名挂点在 animId/time 时刻的**动画后**世界变换(列主序;平移在列 3)。
    /// = worldAnim[bone](t) · attachLocal —— 与 attachmentWorld 同构,只是把静态 worldBind[bone] 换成
    /// 该帧动画求值得到的 worldAnim[bone](骨骼随动画移动/旋转/缩放)。这让挂在该骨上的子部件(眼/睑/耳)
    /// **逐帧跟随父的骨骼动画**(凯尔希主体 anim206 呼吸让头骨 bone5 移动 → 眼睛跟头一起动,不脱离脸)。
    /// 失败(无骨/无该挂点/无该动画)返回 nil → 调用方退回静态 attachmentWorld(t=0 退化兜底)。
    func animatedAttachmentWorld(_ name: String, time: Double, rate: Float, animId: Int) -> simd_float4x4? {
        guard let a = attachments.first(where: { $0.name == name }), a.bone >= 0, a.bone < parent.count else { return nil }
        guard let world = worldAnim(time: time, rate: rate, animId: animId), a.bone < world.count else { return nil }
        // 与 attachmentWorld 同乘序:列主序 attachWorldCol = boneWorldAnimCol · attachLocalCol。
        return world[a.bone] * a.local
    }

    /// 具名挂点所在**骨**在 animId/time 时刻的**蒙皮变换**(列主序;= worldAnim[bone]·invBind[bone])。
    /// 与 attach 的 `attachLocal` 无关——它把**任意** mesh-local 点(如子部件实际锚点 = 挂点平移 + 子局部 origin)
    /// 当作刚性绑在该骨上的点,变换到动画后的位置。
    /// 为何需要它(凯尔希眼睛偏离脸的真因,2026-06-07 引擎 parser 实测):
    ///   旧 `animatedAttachmentWorld` 只给挂点**枢轴**(头部 bone5 @ mesh-local(734,856))的运动,然后把这同一个
    ///   位移平移给挂在「头部」上的**所有**子部件。但呼吸 anim206 让 bone5 **旋转+平移**,离枢轴越远的点位移越不同:
    ///     · 眼睛组合锚点在 (1364,855)(枢轴右 630px)→ 实际应下沉 −91.5px,旧式只给 −59.1px → 偏离 24.4px(屏幕)。
    ///     · 左眼皮 (584,869) 应 −51.3 旧式 −59.1 → 偏 6px;右眼上眼睑 (845,937) 应 −64.4 → 偏 3.8px。
    ///   正解:把子的**实际锚点**(在父 mesh-local 空间)经该骨的蒙皮矩阵变换,捕获旋转放大的真实位移 →
    ///   眼睛随脸皮一起下沉/不脱位。这是 WE attachment 的真语义(子刚绑父骨的局部坐标系,按子的偏移点求值)。
    /// 失败(无骨/无该挂点/无该动画)返回 nil → 调用方退回旧枢轴增量(零回归兜底)。
    func attachBoneSkinMatrix(_ name: String, time: Double, rate: Float, animId: Int) -> simd_float4x4? {
        guard let a = attachments.first(where: { $0.name == name }), a.bone >= 0, a.bone < parent.count,
              a.bone < invBind.count else { return nil }
        guard let world = worldAnim(time: time, rate: rate, animId: animId), a.bone < world.count else { return nil }
        return world[a.bone] * invBind[a.bone]
    }

    /// 求 animId 在 time 时刻每根骨的**世界动画变换**(列主序;父链累乘的 worldAnim[b])。
    /// 与 skin() 内部的 world[] 计算逐式相同(共享逻辑)。失败/无骨/无该动画返回 nil。
    /// t=0(或 anim 首帧 == bind)时退化为 worldBind → 与静态结果一致(回归兜底)。
    private func worldAnim(time: Double, rate: Float, animId: Int, use3D: Bool = false) -> [simd_float4x4]? {
        guard hasSkin else { return nil }
        guard let anim = anims.first(where: { $0.id == animId }) ?? anims.first else { return nil }
        guard anim.frameCount > 0, anim.fps > 0 else { return nil }
        let nb = parent.count
        let tt = time * Double(anim.fps) * Double(max(0.0001, rate))
        let fc = Double(anim.frameCount)
        var ft = tt.truncatingRemainder(dividingBy: fc); if ft < 0 { ft += fc }
        let f0 = Int(ft), f1 = (f0 + 1) % anim.frameCount
        let a = Float(ft - Double(f0))
        var local = [simd_float4x4](repeating: matrix_identity_float4x4, count: nb)
        for b in 0..<nb {
            guard b < anim.tracks.count, f0 < anim.tracks[b].count, f1 < anim.tracks[b].count else { continue }
            let k0 = anim.tracks[b][f0], k1 = anim.tracks[b][f1]
            func lp(_ i: Int) -> Float { k0[i] + (k1[i] - k0[i]) * a }
            let t = SIMD3<Float>(lp(0), lp(1), lp(2))
            let s = SIMD3<Float>(lp(6), lp(7), lp(8))
            // use3D=眼睛层:完整 3D TRS(含 rx/ry 出平面旋转 + tz)→ 凯尔希眼 anim1405 bone2 rx→π/2+tz→−61
            //   把虹膜区顶点收缩成闭合眼线(隔离实测眼面积 1538→730 px,睁→闭干净过渡,无翻面色块,无需剔除)。
            // use3D=false(主 puppet 龙/刀/朱鹤/头发等):只构 rz 的平面 trs(丢 rx/ry)= 旧行为,零回归
            //   (朱鹤 anim458 bone2 也有 rx→π/2,在 2D 无深度无剔除下出平面旋转会把网格折叠成色块,故主 puppet 不上 3D)。
            local[b] = use3D ? Self.trs3D(t: t, rx: lp(3), ry: lp(4), rz: lp(5), s: s)
                             : Self.trs(t: t, rz: lp(5), s: s)
        }
        var world = [simd_float4x4](repeating: matrix_identity_float4x4, count: nb)
        for b in 0..<nb {
            let p = parent[b]
            world[b] = (p >= 0 && p < nb) ? world[p] * local[b] : local[b]
        }
        return world
    }

    /// 本(子)部件 bind 姿态下蒙皮后的局部顶点(SIMD2,**子部件 mesh 原始空间**),供做部件间 attachment 用。
    /// bind 姿态蒙皮 = Σ wᵢ·(worldBind[i]·invBind[i])·v = v(恒等),即等于 rawPos;此处显式走蒙皮路径以保持
    /// 与运行时蒙皮一致(若将来叠 eyeblink 动画可换成 skin())。
    var skinnedBindPositions: [SIMD2<Float>] { rawPos }

    /// 本(子)部件 root 骨(bone 0)的世界 bind 变换(列主序)。无骨返回单位阵。
    var rootBoneWorld: simd_float4x4 { worldBind.first ?? matrix_identity_float4x4 }

    /// 部件间 attachment:把本(子)部件蒙皮后的局部顶点搬到**父部件 mesh-local 空间**,输出单位空间 [x,y,u,v]
    /// (按 **父部件 size** 归一,以便用父部件的 origin/scale/angle 渲染)。
    ///   childInParent = inv(childRootBoneWorld) · parentAttachWorld  (把子 root 对齐到父挂点)
    /// 已离线验证(凯尔希:眼睛 root 对齐到主体「头部」挂点后落到光头脸上)。parentSize 为父部件 quad size。
    func attachedUnitVerts(parentAttachWorld: simd_float4x4, parentSize: SIMD2<Float>) -> [Float] {
        let m = parentAttachWorld * rootBoneWorld.inverse   // 列主序:childWorldInParent = parentAttach · inv(childRoot)
        let pts = skinnedBindPositions
        var out = [Float](); out.reserveCapacity(pts.count * 4)
        for i in 0..<pts.count {
            let v = m * SIMD4<Float>(pts[i].x, pts[i].y, 0, 1)
            // 归一到**父** size(渲染用父的 matModel:unitVert·parentSize = 父空间像素 = v.xy)
            out.append(v.x / parentSize.x); out.append(v.y / parentSize.y)
            out.append(uv[i].x); out.append(uv[i].y)
        }
        return out
    }

    // ---- 原始 → 单位空间 [x,y,u,v](x=rawX/size.x、y=+rawY/size.y、uv 直取)----
    // 注:不翻 Y 是对的——我方普通 quad 约定 pos.y=+0.5↔uv.v=0(贴图顶),而 puppet 网格拟合
    // pos.y=−size·(v−0.5) → unitVert.y=pos.y/size=0.5−v,正好等于普通 quad 的 vy=0.5−v,同向。
    // (曾按工作流诊断试加负号 → 部件上下倒置,已撤销。)
    private func unitVerts(_ pos: [SIMD2<Float>]) -> [Float] {
        var out = [Float](); out.reserveCapacity(pos.count * 4)
        for i in 0..<pos.count {
            out.append(pos[i].x / size.x); out.append(pos[i].y / size.y)
            out.append(uv[i].x); out.append(uv[i].y)
        }
        return out
    }

    /// unitVerts 的遮挡变体:被眼皮盖住的眼球顶点 uv.y 设 sentinel −10，片元阶段只做 discard。
    /// 不再用 −20 返回固定棕色：sentinel 会在三角形内插值，把整个三角染成色块。
    private func unitVertsOccluded(_ pos: [SIMD2<Float>], occluded: Set<Int>) -> [Float] {
        var out = [Float](); out.reserveCapacity(pos.count * 4)
        for i in 0..<pos.count {
            out.append(pos[i].x / size.x); out.append(pos[i].y / size.y)
            out.append(uv[i].x)
            out.append(occluded.contains(i) ? -10.0 : uv[i].y)
        }
        return out
    }

    /// 单个动画在 time 时刻的每骨**局部** TRS 矩阵(父链累乘前)。无该动画返回 nil。
    /// use3D=眼睛层用完整 trs3D(rx/ry/tz);false=主 puppet 平面 trs(只 rz,丢出平面,零回归)。
    private func localPose(time: Double, rate: Float, animId: Int, use3D: Bool = false) -> [simd_float4x4]? {
        guard let anim = anims.first(where: { $0.id == animId }) else { return nil }
        guard anim.frameCount > 0, anim.fps > 0 else { return nil }
        let nb = parent.count
        let tt = time * Double(anim.fps) * Double(max(0.0001, rate))
        let fc = Double(anim.frameCount)
        var ft = tt.truncatingRemainder(dividingBy: fc); if ft < 0 { ft += fc }
        let f0 = Int(ft), f1 = (f0 + 1) % anim.frameCount
        let a = Float(ft - Double(f0))
        var local = [simd_float4x4](repeating: matrix_identity_float4x4, count: nb)
        for b in 0..<nb {
            guard b < anim.tracks.count, f0 < anim.tracks[b].count, f1 < anim.tracks[b].count else { continue }
            let k0 = anim.tracks[b][f0], k1 = anim.tracks[b][f1]
            func lp(_ i: Int) -> Float { k0[i] + (k1[i] - k0[i]) * a }
            local[b] = use3D
                ? Self.trs3D(t: SIMD3(lp(0), lp(1), lp(2)), rx: lp(3), ry: lp(4), rz: lp(5), s: SIMD3(lp(6), lp(7), lp(8)))
                : Self.trs(t: SIMD3(lp(0), lp(1), lp(2)), rz: lp(5), s: SIMD3(lp(6), lp(7), lp(8)))
        }
        return local
    }

    /// **多 animationlayer 合成蒙皮**(WE 真义:对象的 animationlayers 全部叠加,additive 层在 base 姿势上
    /// 追加位移)。御剑龙 = 「动画 1」(546, base) + 「动画 2」(639, additive:含下压/飞行大位移)——
    /// 只播 base 会把 additive 的整体运动丢掉(龙恒停在 bind 高位 = 用户报「龙偏上」的真因)。
    /// 合成约定:local = L_base · Π(invLocalBind · L_add)。additive 轨道 entry== bind 时 invLB·L_add = I(零贡献),
    /// 已对照 pkg 数据验证(动画2 entry0 == localBind 逐骨全等 → t=0 合成 == 纯 base == 旧行为,天然回归兜底)。
    /// layers 为空/全不可用 → 返回 nil(调用方维持现状)。
    /// 该 anim 层的有效求值时间:hold!=nil(init 脚本 setFrame 的静态姿势)→ 冻结在 frameCount×fraction 帧
    /// (= 该时间使 localPose 的 frame = frameCount×fraction,不随 time 循环);否则用 time(正常播放/循环)。
    private func heldTime(_ hold: Float?, _ animId: Int, _ rate: Float, _ time: Double) -> Double {
        guard let frac = hold, let a = anims.first(where: { $0.id == animId }), a.fps > 0, rate != 0 else { return time }
        return Double(frac) * Double(a.frameCount) / (Double(a.fps) * Double(rate))
    }

    /// 是否有任一 anim 携带逐骨 alpha(SKINNING_ALPHA)——绝大多数 puppet 无。用于门控:无则每帧不求值、绑全 1.0。
    var hasBoneAlpha: Bool { anims.contains { $0.boneAlpha != nil } }

    /// 逐顶点透明度(SKINNING_ALPHA = WE genericimage4.vert 的 g_BonesAlpha):对每个动画层取其 anim 的
    /// boneAlpha,当前帧线性插值 → 逐骨 alpha;再按蒙皮权重加权到顶点 = saturate(Σ weight·boneAlpha[idx])。
    /// WE 眨眼/眉毛靠它把眼睑/虹膜层骨 alpha 淡出:xraypad-眠/泠泠泉心虹膜骨→0=眼睛闭;白泽夢 b22→0.27=
    /// 下眼睑半透;白影眉毛多骨 0.24~0.80=表情淡。无 boneAlpha 的层不贡献(留 1.0)。多层取最小(各层都得满足)。
    /// 返回 rawPos.count 个 [0,1],顺序同顶点;无任何 boneAlpha 层时全 1.0(渲染恒等=零回归)。
    func boneAlphaVerts(time: Double, layers: [(animId: Int, rate: Float, additive: Bool, hold: Float?)]) -> [Float] {
        let nb = parent.count
        var boneA = [Float](repeating: 1, count: nb)
        var any = false
        for l in layers {
            guard let anim = anims.first(where: { $0.id == l.animId }), let ba = anim.boneAlpha,
                  anim.frameCount > 0, anim.fps > 0 else { continue }
            any = true
            let tt = heldTime(l.hold, l.animId, l.rate, time) * Double(anim.fps) * Double(max(0.0001, l.rate))
            let fc = Double(anim.frameCount)
            var ft = tt.truncatingRemainder(dividingBy: fc); if ft < 0 { ft += fc }
            let f0 = Int(ft), f1 = (f0 + 1) % anim.frameCount
            let a = Float(ft - Double(f0))
            for b in 0..<min(nb, ba.count) {
                let v = ba[b]
                guard f0 < v.count, f1 < v.count else { continue }
                boneA[b] = min(boneA[b], v[f0] + (v[f1] - v[f0]) * a)
            }
        }
        var out = [Float](repeating: 1, count: rawPos.count)
        guard any else { return out }
        for i in 0..<rawPos.count {
            let bi = boneIdx[i], bw = boneWt[i]
            var acc: Float = 0, wsum: Float = 0
            for k in 0..<4 {
                let w = bw[k]; if w == 0 { continue }
                let b = Int(bi[k]); if b >= 0 && b < nb { acc += boneA[b] * w; wsum += w }
            }
            out[i] = wsum > 0.0001 ? max(0, min(1, acc / wsum)) : 1   // 归一化加权(权重和=1 时 == WE 原式)
        }
        return out
    }

    func skinLayers(time: Double, layers: [(animId: Int, rate: Float, additive: Bool, hold: Float?)], use3D: Bool = false) -> [Float]? {
        guard hasSkin, !layers.isEmpty else { return nil }
        let nb = parent.count
        var composed: [simd_float4x4]? = nil
        for l in layers {
            // 静态姿势层(白泽夢主身体「胳膊外腿/内腿/尾巴」)冻结在 init setFrame 帧、不随 time 循环 → 身体不再乱扭。
            guard let pose = localPose(time: heldTime(l.hold, l.animId, l.rate, time), rate: l.rate, animId: l.animId, use3D: use3D) else { continue }
            if composed == nil {
                composed = pose                      // 首个可用层 = base(additive 标志忽略,作 base 用)
            } else if l.additive {
                for b in 0..<nb { composed![b] = composed![b] * (localBind[b].inverse * pose[b]) }
            } else {
                composed = pose                      // 后续非 additive 层覆盖(WE blend=1 全量)
            }
        }
        guard let local = composed else { return nil }
        var world = [simd_float4x4](repeating: matrix_identity_float4x4, count: nb)
        for b in 0..<nb {
            let p = parent[b]
            world[b] = (p >= 0 && p < nb) ? world[p] * local[b] : local[b]
        }
        return skinVerts(world: world)
    }

    // ============================ 眼睛闭合:虹膜随眼白塌缩 ============================
    /// 该 puppet 是否含「眼白 sy→0 塌缩」骨(白影眼 anim502 的眼睑骨 bone1/2:sy 全程跌到 ~0)。
    /// 用于判定是否启用 eyeOcclude(只在真有塌缩眼白的眼 puppet 上做,其它 puppet/凯尔希 3D 眼 anim 不命中)。
    func hasCollapsingScleraBone(animId: Int) -> Bool {
        guard let anim = anims.first(where: { $0.id == animId }) else { return false }
        // ⛔WE 实渲铁证(2026-06-23 用户对照图 Image#8):白泽夢 WE 里眼睛**睁着、虹膜(蓝)正常显示**——眨眼极轻、
        //   眼球不消失。放宽阈值让白泽夢/思衡托走 eyeOcclude = 把虹膜挤成方块伪影(Image#7)= 错。**回到只白影类
        //   「眼白 sy→0」深塌缩(minSy<0.1)触发挤压;浅塌缩(0.12-0.18)不触发 = 纯蒙皮正常显示虹膜(忠实 WE)。**
        for b in 0..<min(parent.count, anim.tracks.count) {
            var minSy: Float = .greatestFiniteMagnitude, maxSy: Float = -.greatestFiniteMagnitude
            for fr in anim.tracks[b] where fr.count > 7 { minSy = min(minSy, fr[7]); maxSy = max(maxSy, fr[7]) }
            if minSy.isFinite, maxSy > 0.5, minSy < 0.1 { return true }   // 只白影深塌缩(眼白 sy→0)
        }
        return false
    }

    /// 该 puppet 是否含「浅塌缩眼睑骨」(白泽夢「眼睛」anim730 bone10 sy 1→0.116;思衡托 anim176 多骨 sy→0.18):
    /// 眼睑骨自身 sy 明显塌缩但不到白影那种全闭(minSy∈[0.1,0.5])、UV 质心在睫毛/眼睑带(v<0.33 或 v>0.62)、
    /// 不驱动虹膜带顶点;且场景存在虹膜带骨。用于触发**clip 式眼皮遮挡**(2026-06-24 用户授权的引擎增强:
    /// WE 这类 pkg 本身**无**眼皮盖虹膜数据——眨眼仅一条睫毛 sy 压扁、虹膜骨全程不动 → 虹膜一直露;按用户要的
    /// 「眨多少眼皮盖多少」用眼睑闭合度 clip 虹膜上半,露出部分不变形)。与 hasCollapsingScleraBone(白影深塌缩
    /// <0.1,骨级挤压)分流互斥:白影 minSy<0.1 不命中此判据 → 走原骨级路径(逐像素零回归)。WP_NO_SHALLOW_EYELID 退回。
    func hasShallowEyelidCollapse(animId: Int) -> Bool {
        if WPEnv.vars["WP_NO_SHALLOW_EYELID"] != nil { return false }
        guard let anim = anims.first(where: { $0.id == animId }) else { return false }
        let band = irisBandBoneSet()
        guard !band.isEmpty else { return false }   // 无虹膜带骨 = 非眼睛 puppet → 不触发(防误伤身体 puppet)
        for b in 0..<min(parent.count, anim.tracks.count) {
            var minSy: Float = .greatestFiniteMagnitude, maxSy: Float = -.greatestFiniteMagnitude
            for fr in anim.tracks[b] where fr.count > 7 { minSy = min(minSy, fr[7]); maxSy = max(maxSy, fr[7]) }
            guard minSy.isFinite, maxSy > 0.8, minSy >= 0.1, minSy < 0.5 else { continue }   // 浅塌缩(排除白影<0.1)
            if band.contains(b) { continue }                    // 虹膜骨自身不算眼睑塌缩源
            let v = boneUVCentroidV(b)
            if v >= 0 && (v < 0.33 || v > 0.62) { return true }  // 睫毛/眼睑带的浅塌缩骨 = 眨眼眼睑
        }
        return false
    }

    /// 该 puppet 是否含「虹膜出平面折叠闭眼」骨(凯尔希「眼睛」anim1405 bone2:rx 0→π/2 + tz→−61,自身驱动
    /// 虹膜带顶点)。这是与白影 sy 塌缩**等价但机制不同**的闭眼方式:WE 这类眼 rig 让虹膜骨绕 X 翻转后退 →
    /// 正交投影下 x/y 收缩把虹膜收成眼线。eyeOcclude 据此判定是否需要 3D-fold 路径的「虹膜藏进眼线」语义
    /// (用于 SceneRenderEngine 决定 occlude 兜底,**不**改变 3D fold 本身,仅在该 fold 被旁路/退平面时兜底)。
    /// 仅在真有「自身 rx→±π/2 折叠 + 驱动虹膜带顶点」的骨时返回 true(白影 anim502 rx 恒 0 → 不命中;
    /// 朱鹤主 puppet 走平面路径不调用此判定 → 不命中)。
    func hasOutOfPlaneFoldingIrisBone(animId: Int) -> Bool {
        guard let anim = anims.first(where: { $0.id == animId }) else { return false }
        let foldEps: Float = 1.2   // ≈69°:接近 π/2 的强出平面折叠才算闭眼(避免轻微 rx 抖动误判)
        for b in 0..<min(parent.count, anim.tracks.count) {
            var maxAbsRx: Float = 0
            for fr in anim.tracks[b] where fr.count > 3 { maxAbsRx = max(maxAbsRx, abs(fr[3])) }
            guard maxAbsRx >= foldEps else { continue }
            // 该骨须驱动虹膜带顶点(UV.v 0.33..0.62,权重>0.4),否则只是睫毛/眼睑出平面摆动非闭眼虹膜。
            if irisBandBoneSet().contains(b) { return true }
        }
        return false
    }

    /// 驱动虹膜带(UV.v 0.33..0.62,权重>0.4)顶点的骨索引集合(供 occlude/fold 判定共用,避免重复扫描)。
    private func irisBandBoneSet() -> Set<Int> {
        var s = Set<Int>()
        for vi in 0..<rawPos.count {
            let v = uv[vi].y; guard v >= 0.33, v <= 0.62 else { continue }
            let bi = boneIdx[vi], bw = boneWt[vi]
            for k in 0..<4 where bw[k] > 0.4 { s.insert(Int(bi[k])) }
        }
        return s
    }

    /// 每骨 UV 质心(权重加权 v;识别图集带:v<0.33 睫毛上、0.33..0.62 虹膜、>0.62 肤眼睑)。
    private func boneUVCentroidV(_ b: Int) -> Float {
        var wsum: Float = 0, vacc: Float = 0
        for vi in 0..<rawPos.count {
            let bi = boneIdx[vi], bw = boneWt[vi]
            for s in 0..<4 where Int(bi[s]) == b { wsum += bw[s]; vacc += uv[vi].y * bw[s] }
        }
        return wsum > 0 ? vacc / wsum : -1
    }

    /// 眼睛闭合占据:与 skinLayers 等同求每骨 world,但额外让**虹膜骨**(UV 在虹膜带、自身 sy 不塌缩)
    /// 竖向跟随其**配对眼白骨**(bind 位置最近的塌缩骨)当前帧的 sy → 闭眼时虹膜挤成线随眼白一起消失。
    /// 这是 WE 眼 rig 的真义(眼白 sy 驱动眼睛开合高度,虹膜被 clip 到该开口;我方无 clip 故用竖向挤压等效)。
    /// 睁眼(配对眼白 sy≈1)→ 竖向因子 1 → 与 skinLayers 逐元素相同(零回归)。无塌缩眼白/无虹膜骨 → 返回 nil。
    func skinLayersEyeOcclude(time: Double, layers: [(animId: Int, rate: Float, additive: Bool, hold: Float?)], use3D: Bool = false) -> [Float]? {
        guard hasSkin, !layers.isEmpty else { return nil }
        let nb = parent.count
        // 1) 合成各骨 local pose(与 skinLayers 同)。
        var composed: [simd_float4x4]? = nil
        for l in layers {
            guard let pose = localPose(time: heldTime(l.hold, l.animId, l.rate, time), rate: l.rate, animId: l.animId, use3D: use3D) else { continue }
            if composed == nil { composed = pose }
            else if l.additive { for b in 0..<nb { composed![b] = composed![b] * (localBind[b].inverse * pose[b]) } }
            else { composed = pose }
        }
        guard var local = composed else { return nil }

        // 2) 识别塌缩眼白骨(当前帧 sy 显著 <1)与虹膜骨(UV 虹膜带、当前帧不塌缩)。
        //    眼白当前帧 sy = local[b] 第 1 列长度 / bind 第 1 列长度(取相对 bind 的纵向缩放因子)。
        func bindSy(_ b: Int) -> Float { let s = simd_length(localBind[b].columns.1); return s == 0 ? 1 : s }
        func curSyFactor(_ b: Int) -> Float { simd_length(local[b].columns.1) / bindSy(b) }   // 相对 bind 的纵向缩放
        // 虹膜顶点判据:色掩码命中足够(≥20,侧脸单眼球面展开的上下两块都中)→ 用色(精确,不含 0.42-0.62 非虹膜);
        //   命中过少(白影虹膜色暗/低饱和→命中 0)→ 退回 UV.v 带[0.33,0.62](零回归,白影虹膜在带内)。
        let irisColorHits = irisColorMask.count == rawPos.count ? irisColorMask.filter { $0 }.count : 0
        let useColorIris = irisColorHits >= 20
        func isIrisVert(_ vi: Int) -> Bool {
            useColorIris ? irisColorMask[vi] : (uv[vi].y >= 0.33 && uv[vi].y <= 0.62)
        }
        // 骨是否驱动虹膜带顶点(UV.v[0.33,0.62],权重>0.4):区分虹膜骨与眼白骨——用**稳定 UV 带**而非色判据
        //   (色判据可能误标眼睑肤色顶点为虹膜→把塌缩眼睑骨当虹膜骨排除→sclera 空→完全不藏;思衡托踩此坑)。
        func drivesIrisVerts(_ b: Int) -> Bool {
            for vi in 0..<rawPos.count {
                let v = uv[vi].y; guard v >= 0.33, v <= 0.62 else { continue }
                let bi = boneIdx[vi], bw = boneWt[vi]
                for s in 0..<4 where Int(bi[s]) == b && bw[s] > 0.4 { return true }
            }
            return false
        }
        // 眼白骨:相对 bind 纵向**强塌缩**(k<0.5,白影闭眼 bone1/2 → 0)、UV 在肤眼睑带(v>0.62)、且**不驱动虹膜顶点**
        // (虹膜骨 bone25 自身 sy≈1 不塌缩,但其 UVc 偶落 0.67 skin 带 → 加 drivesIris 排除,避免被当眼白配对到自己 → k=1 不挤压)。
        // 收集塌缩眼睑骨作「眼白源」(虹膜挤向其眼线)。先下/肤眼睑带(白影/思衡托标准),空则上眼睑/睫毛带
        // (白泽夢=只上眼睑 bone10 下压型,无下眼睑塌缩)。白影/思衡托有下眼睑源 → 完全走原分支(零回归),
        // 仅白泽夢落到上眼睑分支。WP_NO_EYE_BLINK_CLOSE 时只收下眼睑(旧行为)。
        let upperOK = WPEnv.vars["WP_NO_EYE_BLINK_CLOSE"] == nil
        // 该眼睑骨 anim 全程最小 sy(相对 bind)= 它「完全闭眼」时的塌缩度。白影=0(眼睑塌到底);思衡托=0.18、
        // 白泽夢=0.116(浅塌缩 rig)。用来把虹膜挤压归一化到「该眼睑闭到底=虹膜全藏」(白影式消失效果)。
        func eyelidMinSy(_ b: Int) -> Float {
            let bs = bindSy(b); var mn: Float = 1.0
            for l in layers {
                guard let anim = anims.first(where: { $0.id == l.animId }), b < anim.tracks.count else { continue }
                for fr in anim.tracks[b] where fr.count > 7 { mn = min(mn, fr[7] / (bs == 0 ? 1 : bs)) }
            }
            return max(0, min(1, mn))
        }
        func collectSclera(upper: Bool) -> [(b: Int, pos: SIMD2<Float>, k: Float, minSyF: Float)] {
            var out: [(b: Int, pos: SIMD2<Float>, k: Float, minSyF: Float)] = []
            for b in 0..<nb {
                let k = curSyFactor(b)
                guard k.isFinite, k < 0.5 else { continue }          // 强塌缩(避免 0.998 边界泄漏)
                let v = boneUVCentroidV(b)
                if upper { guard v < 0.33 else { continue } } else { guard v > 0.62 else { continue } }
                if drivesIrisVerts(b) { continue }                   // 虹膜骨不作眼白配对源
                let wp = b < worldBind.count ? worldBind[b].columns.3 : SIMD4<Float>(0,0,0,1)
                out.append((b, SIMD2(wp.x, wp.y), max(0, k), eyelidMinSy(b)))
            }
            return out
        }
        // ⭐2026-06-25 连续虹膜裁剪(用户方案1=复现 WE「虹膜裁到上下眼睑开口」Live2D 机制):
        //   白泽夢/思衡托这类**浅塌缩眼睑** pkg 几何上盖不住虹膜(穷尽模拟:眼睑只移~10-36px、绘制序在虹膜之前),
        //   WE 靠引擎级 clip 连续收窄虹膜可见区。这里按眼睑骨当前闭合度 close 连续裁:上眼睑侧(高 y)先盖,
        //   close 0→1 把虹膜从上往下逐渐盖掉(眨多少盖多少),无突变、无残留(取代旧 markEye 的 close>0.55 全裁)。
        //   只对「无深塌缩骨(非白影)+ 有浅塌缩眼睑骨」的眼 puppet 生效;白影(深塌缩 minSy<0.1)走下方原骨级路径。
        //   WP_NO_EYE_OCCLUDE 退回(整段跳过 → 纯忠实蒙皮)。
        let clipOcclude = WPEnv.vars["WP_NO_EYE_OCCLUDE"] == nil
        let occDbgClip = WPEnv.vars["WP_EYE_OCCLUDE_DBG"] != nil
        if clipOcclude {
            // anim 级识别浅塌缩眼睑骨(不依赖当前帧 k<0.5,故 sy 1→minSy 全程连续=无突变):maxSy>0.8、minSy∈[0.1,0.5]、
            //   UV 在睫毛/眼睑带(v<0.33 或 v>0.62)、不驱动虹膜带。同时探测深塌缩骨(白影,minSy<0.1)以排除。
            var shallowLids: [(b: Int, minSyF: Float)] = []
            var hasDeepLid = false
            for b in 0..<nb {
                let bs = bindSy(b); var mn: Float = 1, mx: Float = 0
                for l in layers {
                    guard let anim = anims.first(where: { $0.id == l.animId }), b < anim.tracks.count else { continue }
                    for fr in anim.tracks[b] where fr.count > 7 { let sy = fr[7] / (bs == 0 ? 1 : bs); mn = min(mn, sy); mx = max(mx, sy) }
                }
                if mn.isFinite, mx > 0.5, mn < 0.1 { hasDeepLid = true }          // 白影深塌缩 → 不走连续裁
                guard mx > 0.8, mn >= 0.1, mn < 0.5, !drivesIrisVerts(b) else { continue }
                let v = boneUVCentroidV(b); guard v >= 0, (v < 0.33 || v > 0.62) else { continue }
                shallowLids.append((b, mn))
            }
            if !hasDeepLid, !shallowLids.isEmpty {
                // 父链累乘 world + 普通蒙皮(虹膜不变形,只标记被盖顶点 → unitVertsOccluded uv.y=−10 → 片元 discard)。
                var world = [simd_float4x4](repeating: matrix_identity_float4x4, count: nb)
                for b in 0..<nb { let p = parent[b]; world[b] = (p >= 0 && p < nb) ? world[p] * local[b] : local[b] }
                var skinned = [SIMD2<Float>](repeating: .zero, count: rawPos.count)
                for i in 0..<rawPos.count {
                    let p4 = SIMD4<Float>(rawPos[i].x, rawPos[i].y, 0, 1)
                    var acc = SIMD4<Float>(0, 0, 0, 0); let idx = boneIdx[i], wt = boneWt[i]
                    for k in 0..<4 {
                        let w = wt[k]; if w == 0 { continue }
                        let bi = Int(idx[k]); guard bi >= 0, bi < nb else { continue }
                        acc += (world[bi] * invBind[bi]) * p4 * w
                    }
                    skinned[i] = (wt[0] + wt[1] + wt[2] + wt[3] > 0) ? SIMD2(acc.x, acc.y) : rawPos[i]
                    if !skinned[i].x.isFinite || !skinned[i].y.isFinite { skinned[i] = rawPos[i] }
                }
                // 闭合度 close∈[0,1]:浅塌缩骨当前 sy 归一(sy=1→close 0 睁、sy=minSyF→close 1 闭)。取各浅骨最大。
                var close: Float = 0
                for sl in shallowLids {
                    let cur = curSyFactor(sl.b); guard cur.isFinite else { continue }
                    close = max(close, (1 - cur) / max(0.001, 1 - sl.minSyF))
                }
                close = max(0, min(1, close))
                var irisIdx: [Int] = []
                for i in 0..<rawPos.count where isIrisVert(i) { irisIdx.append(i) }
                if occDbgClip { Log.write("OCCLUDE(clip) close=\(String(format:"%.2f",close)) irisVerts=\(irisIdx.count) lids=\(shallowLids.map{$0.b})") }
                guard close > 0.01, !irisIdx.isEmpty else { return unitVerts(skinned) }   // 睁眼/无虹膜=全露(零回归)
                // 逐 x 桶(双眼基本 x 分离 → 天然分眼):用**虹膜**顶点定眼球开口的 x 范围 + 每桶上下沿(=眼球竖向跨度)。
                let xs = irisIdx.map { skinned[$0].x }
                let xmin = xs.min()!, xmax = xs.max()!, xr = max(1, xmax - xmin)
                let nBin = 28
                func binOf(_ x: Float) -> Int { min(nBin - 1, max(0, Int((x - xmin) / xr * Float(nBin)))) }
                var top = [Float](repeating: -.greatestFiniteMagnitude, count: nBin)
                var bot = [Float](repeating: .greatestFiniteMagnitude, count: nBin)
                for i in irisIdx { let bn = binOf(skinned[i].x); top[bn] = max(top[bn], skinned[i].y); bot[bn] = min(bot[bn], skinned[i].y) }
                // 空桶用最近非空桶填(避免分桶边界锯齿/漏裁)。
                for bn in 0..<nBin where top[bn] == -.greatestFiniteMagnitude {
                    for d in 1..<nBin {
                        if bn - d >= 0, top[bn - d] > -.greatestFiniteMagnitude { top[bn] = top[bn - d]; bot[bn] = bot[bn - d]; break }
                        if bn + d < nBin, top[bn + d] > -.greatestFiniteMagnitude { top[bn] = top[bn + d]; bot[bn] = bot[bn + d]; break }
                    }
                }
                // ⭐2026-06-25 Direction-A(诊断 agent 实证):只 discard 虹膜会露出后面的**白眼白+红下眼眶/泪线**(非肤色)
                //   = 看着像眼球被挖空露眼白血丝。修=遮挡集从「仅虹膜」扩到「整个眼球开口」:虹膜 + 落在眼球 x/y 跨度内、
                //   **非睫毛带(uv.v≥0.33,睫毛弧保留作闭眼线)** 的顶点(=眼白/下眼眶/泪线/开口内肤色)。把开口区一并 discard
                //   → 露出后面的脸部肤色底(agent 实证开口后方=淡肤色),接近 WE 干净闭眼。开口内的肤色顶点被 discard 也无害
                //   (后方还是肤色)。睁眼 close≈0 时裁线在最顶=几乎不遮=零回归。
                // 基本闭合后只裁眼球内容，不再把整片眼睑/眼白几何压向中线。后者会把真实肤色三角
                // 拉成连续色块，且与 MDLV 原生 clipping 重复。保留 pkg 蒙皮位置，原生 mask 负责动态
                // 开口，本兜底仅清掉仍漏出的虹膜/高光。
                // 色判虹膜(isIrisVert)+ **空间判据**——落在逐桶虹膜竖向跨度
                //   [bot,top] 内的顶点(catch 色判漏掉的虹膜高光/边缘=之前残留的青蓝漏边)。睫毛在跨度外(上沿之上/下沿之下)
                //   保留作闭眼弧。丢后露出后方淡肤色(Direction-A 实证)=WE 干净深弧无蓝。半闭(<0.5)保留虹膜(渐压自然)。
                let hasBright = eyeBrightMask.count == rawPos.count
                var occluded = Set<Int>()
                // ⭐2026-07-27 眉毛/睫毛误裁门(GBC SUBARU 安和昴 眼皮 puppet):暖棕睫毛/眉弧的反锯齿边被
                //   irisColorMask 误判「虹膜色」(实测 avgR≈150/avgB≈85 高饱和暖棕,raw hit 16-24 → 1 环扩展到
                //   82/105 顶点=整条睫毛线),close>0.5 时闭眼睫毛线被 discard 成碎块、眉弧被吃掉(实渲铁证:
                //   WP_NO_EYE_OCCLUDE=1 纯蒙皮闭眼完美——该 pkg 自带真眼皮数据+眼球独立层原生 clipping,根本
                //   不需要本兜底)。判别实据:**真·卡住的虹膜不随眨眼动**(白泽夢虹膜骨 b27-32/思衡托虹膜骨全程
                //   静止,眼睑降~10px 时虹膜位移≈0——这正是当初做 clip 兜底的原因);而眼皮自身画艺(睫毛/眉/
                //   卧蚕高光)**随眼睑一起下降**(位移≈眼睑位移)。故:被判「虹膜」的顶点中位下降 >3px 且
                //   >0.35×眼睑中位下降 = 眼皮画艺非卡住虹膜 → 跳过 discard(纯蒙皮已是 WE 正确闭眼)。
                //   白泽夢/思衡托虹膜不动 → 门不触发,discard 照旧(金标准零回归)。
                var lashLikeIris = false
                if close > 0.5 {
                    var irisDs = irisIdx.map { rawPos[$0].y - skinned[$0].y }   // 下降为正(y 减小=下降,同 lidPts 判据)
                    irisDs.sort()
                    let irisDesc = irisDs[irisDs.count / 2]                     // irisIdx 非空(上方 guard)
                    var lidDs: [Float] = []
                    for j in 0..<rawPos.count where !isIrisVert(j) {
                        let d = rawPos[j].y - skinned[j].y
                        if d > 1.5 { lidDs.append(d) }                          // 只统计真在下降的眼睑顶点
                    }
                    lidDs.sort()
                    let lidDesc = lidDs.isEmpty ? 0 : lidDs[lidDs.count / 2]
                    lashLikeIris = irisDesc > 3 && irisDesc > 0.35 * lidDesc
                    if occDbgClip { Log.write("OCCLUDE(gate) irisDesc=\(String(format:"%.1f",irisDesc)) lidDesc=\(String(format:"%.1f",lidDesc)) lashLikeIris=\(lashLikeIris)") }
                }
                if close > 0.5, !lashLikeIris {
                    let pad: Float = 2
                    for i in 0..<rawPos.count {
                        if isIrisVert(i) { occluded.insert(i); continue }
                        // 跨度内的**亮**顶点(虹膜填充/青蓝高光/眼白)→ 丢;深睫毛(不亮)→ 保留作弧线。
                        guard hasBright, eyeBrightMask[i] else { continue }
                        let x = skinned[i].x
                        guard x >= xmin, x <= xmax else { continue }
                        let bn = binOf(x)
                        if skinned[i].y >= bot[bn] - pad, skinned[i].y <= top[bn] + pad { occluded.insert(i) }
                    }
                }
                if occDbgClip { Log.write("OCCLUDE(discard) close=\(String(format:"%.2f",close)) irisHidden=\(occluded.count)") }
                return unitVertsOccluded(skinned, occluded: occluded)
            }
        }
        var sclera = collectSclera(upper: false)
        if sclera.isEmpty, upperOK { sclera = collectSclera(upper: true) }
        guard !sclera.isEmpty else { return nil }   // 无塌缩眼睑 → 不占据(零回归兜底)

        // 3) 父链累乘求 world(与 skinLayers 同)。
        var world = [simd_float4x4](repeating: matrix_identity_float4x4, count: nb)
        for b in 0..<nb {
            let p = parent[b]
            world[b] = (p >= 0 && p < nb) ? world[p] * local[b] : local[b]
        }
        // 4) eyeOcclude 分两路:白影类(深塌缩 minSyF≈0)走**骨级**竖向挤压(会话前 work,逐像素零回归);浅塌缩
        //    (白泽夢/思衡托 minSyF≥0.05)走**顶点级**——绕开「骨权重在虹膜边缘混合」造成的残留,按贴图色判(含
        //    侧脸单眼球面展开的上下两块)把虹膜顶点直接朝其所在眼的质心 y 竖向压扁、边缘也压干净。
        let irisOcclude = WPEnv.vars["WP_NO_EYE_OCCLUDE"] == nil
        let occDbg = WPEnv.vars["WP_EYE_OCCLUDE_DBG"] != nil
        let shallowType = sclera.contains { $0.minSyF >= 0.05 }
        if shallowType {
            // 普通蒙皮到 world 空间(挤压留到顶点级)。
            var skinned = [SIMD2<Float>](repeating: .zero, count: rawPos.count)
            for i in 0..<rawPos.count {
                let p4 = SIMD4<Float>(rawPos[i].x, rawPos[i].y, 0, 1)
                var acc = SIMD4<Float>(0, 0, 0, 0)
                let idx = boneIdx[i], wt = boneWt[i]
                for k in 0..<4 {
                    let w = wt[k]; if w == 0 { continue }
                    let bi = Int(idx[k]); guard bi >= 0, bi < nb else { continue }
                    acc += (world[bi] * invBind[bi]) * p4 * w
                }
                skinned[i] = (acc.w != 0 || wt[0] + wt[1] + wt[2] + wt[3] > 0) ? SIMD2(acc.x, acc.y) : rawPos[i]
                if !skinned[i].x.isFinite || !skinned[i].y.isFinite { skinned[i] = rawPos[i] }
            }
            guard irisOcclude else { return unitVerts(skinned) }
            // 全局闭合度:最闭塌缩眼睑归一化(塌到它自己最闭值 = 完全闭 → kIris→0)。
            let bestScl = sclera.min { $0.k < $1.k } ?? sclera[0]
            let kIris = max(0, min(1, (bestScl.k - bestScl.minSyF) / max(0.001, 1 - bestScl.minSyF)))
            var irisIdx: [Int] = []
            for i in 0..<rawPos.count where isIrisVert(i) { irisIdx.append(i) }
            if occDbg { Log.write("OCCLUDE(vert) kIris=\(String(format:"%.2f",kIris)) irisVerts=\(irisIdx.count) colorMask=\(useColorIris)") }
            guard kIris < 0.999, !irisIdx.isEmpty else { return unitVerts(skinned) }   // 睁眼/无虹膜不压
            // ⭐2026-06-24 用户授权的「眼皮遮挡」:虹膜几何**完全不动**(露出部分零变形),只把被上眼睑盖住的
            //   顶点**标记**出来 → 经 unitVertsOccluded 设 uv.y=−10 → scene_fragment 像素级 discard(无几何
            //   拉伸条纹)。眨多少(kIris)眼睑线降多少,盖多少。这才是真遮挡(对照之前向质心压扁/钳到点都有伪影)。
            // ⭐全局逐 x 桶遮挡(2026-06-24 修「左眼一点没盖」):侧脸两眼 x 重叠时旧 splitX 分眼失败→左眼整只漏。
            //   改成把整脸虹膜 x 范围分细桶,每桶独立判定——左眼 x 桶用左眼眼睑下缘、右眼桶用右眼,两眼自动各自遮挡。
            //   ①每桶虹膜 rest 上沿 ②上眼睑顶点=非虹膜+当前相对 rest 下降(眨眼,睁眼≈0→零回归)+rest 在该桶虹膜上沿之上
            //   ③每桶眼睑下缘=该桶上眼睑顶点 skinned.y 最小 ④虹膜顶点 skinned.y>其桶眼睑下缘=被眼睑盖→标记 discard。
            //   边界完全随真实眼睑几何(逐桶=弧形)→ 眼缝形状忠实 pkg;眨多少眼睑降多少盖多少。
            // **上眼睑识别用 rest x(排除虹膜下方眼白),覆盖判定用 skinned 渲染位置**:眼睑下降后渲在 skinned.x(偏移)、
            //   虹膜也按 skinned 渲染,故逐虹膜在 skinned.x 窗口内找眼睑下缘 = 与实际渲染对齐(rest x 分桶判定会与渲染错位
            //   →discard 错的虹膜留蓝残留)。两眼自动各自遮挡(左眼虹膜 skinned 附近只有左眼眼睑)。
            let xmin = irisIdx.map { rawPos[$0].x }.min()!, xmax = irisIdx.map { rawPos[$0].x }.max()!
            let xr = max(1, xmax - xmin)
            let nBin = 24
            func binR(_ rx: Float) -> Int { min(nBin - 1, max(0, Int((rx - xmin) / xr * Float(nBin)))) }
            var irisTopBin = [Float](repeating: -.greatestFiniteMagnitude, count: nBin)   // 每 rest-x 桶虹膜 rest 上沿
            for i in irisIdx { let b = binR(rawPos[i].x); irisTopBin[b] = max(irisTopBin[b], rawPos[i].y) }
            var lidPts: [SIMD2<Float>] = []                                                // 下降上眼睑顶点的 skinned 位置
            for j in 0..<rawPos.count where !isIrisVert(j) {
                guard skinned[j].y < rawPos[j].y - 1.5 else { continue }                   // 当前相对 rest 下降(睁眼≈0→零回归)
                let b = binR(rawPos[j].x)
                guard irisTopBin[b] > -.greatestFiniteMagnitude, rawPos[j].y > irisTopBin[b] - 8 else { continue }  // rest 在虹膜上沿之上=上眼睑
                lidPts.append(skinned[j])
            }
            var occluded = Set<Int>()
            let win: Float = 14
            let close = 1 - kIris   // 闭合度(0=睁,1=全闭)
            for i in irisIdx {
                // ⭐闭合较深(>0.55):虹膜**彻底消失**=WE 闭眼无虹膜的样子(逐 x 眼睑下缘会在虹膜边缘/眼睑 x 没覆盖处
                //   盖不全→残留蓝边;闭得深时直接全裁,干净)。半闭(<0.55):仍按真实眼睑下缘逐 x 渐盖(眨多少盖多少)。
                if close > 0.55 { occluded.insert(i); continue }
                let xi = skinned[i].x
                var low = Float.greatestFiniteMagnitude
                for p in lidPts where abs(p.x - xi) < win { low = min(low, p.y) }          // i 附近(skinned.x 窗口)的眼睑下缘
                if low.isFinite, skinned[i].y > low { occluded.insert(i) }                 // i 在眼睑下缘之上=被眼睑盖
            }
            if occDbg { Log.write("OCCLUDE(vert) clip-discard occluded=\(occluded.count)/\(irisIdx.count)") }
            return unitVertsOccluded(skinned, occluded: occluded)
        }
        // 白影类(深塌缩 minSyF≈0):骨级竖向挤压(归一化 minSyF=0 退化为 k=best.k → 逐像素零回归)。
        if irisOcclude {
            for b in 0..<nb {
                let csf = curSyFactor(b)
                guard csf > 0.9 else { continue }            // 自身不塌缩(真虹膜)
                guard drivesIrisVerts(b) else { continue }    // 驱动虹膜带顶点(UV.v 0.33..0.62)
                let wp = world[b].columns.3
                let ipos = SIMD2(wp.x, wp.y)
                var best = sclera[0]
                for s in sclera where simd_distance(s.pos, ipos) < simd_distance(best.pos, ipos) { best = s }
                let mn = best.minSyF
                let kIris = max(0, min(1, (best.k - mn) / max(0.001, 1 - mn)))
                if occDbg { Log.write("OCCLUDE apply b\(b)→pair b\(best.b) kIris=\(String(format:"%.2f",kIris))") }
                guard kIris < 0.999 else { continue }
                let scleraWp = best.b < world.count ? world[best.b].columns.3 : wp
                let cy = scleraWp.y
                var sq = matrix_identity_float4x4
                sq.columns.1.y = kIris
                sq.columns.3.y = cy * (1 - kIris)
                world[b] = sq * world[b]
            }
        }
        return skinVerts(world: world)
    }

    /// **3D-fold 眼的虹膜兜底遮挡**(凯尔希「眼睛」anim1405 真值):闭眼靠某骨 rx→π/2 翻转折叠虹膜
    /// (主折叠骨,自身把虹膜收成眼线),但**同带的静止虹膜骨**(rx=0、不随 anim 折叠的虹膜角/虹膜下沿)
    /// 不参与折叠 → 可能在闭眼瞬间从眼睑下露出一条虹膜(用户报「眼睑闭合但虹膜还露着」)。
    /// 此法在 3D 蒙皮(use3D=true)基础上,额外把那些**静止虹膜带骨**按主折叠骨的闭合度 k=cos(rx)
    /// 竖向收向折叠骨的眼线中心 → 睁眼(rx=0,k=1)逐元素==skinLayers(零回归),闭眼(rx→π/2,k→0)收成线。
    /// 与 skinLayersEyeOcclude(sy 驱动)互补:那条是「眼白 sy 塌缩」(白影),这条是「虹膜 rx 折叠」(凯尔希)。
    /// 无折叠虹膜骨 / 无静止虹膜带骨 → 返回 nil(调用方退普通 skinLayers,零回归)。
    func skinLayersEyeOccludeFold(time: Double, layers: [(animId: Int, rate: Float, additive: Bool, hold: Float?)], use3D: Bool = true) -> [Float]? {
        guard hasSkin, !layers.isEmpty else { return nil }
        let nb = parent.count
        // 1) 合成各骨 local pose(与 skinLayers 同,use3D 走 trs3D 保留 rx 折叠)。
        var composed: [simd_float4x4]? = nil
        var foldRx = [Float](repeating: 0, count: nb)   // 各骨当前帧 rx(用于识别折叠骨 + 算 k)
        for l in layers {
            // 取该层各骨当前 rx(从 localPose 反解代价高,改用与 localPose 同插值的轨道直读)。
            if let anim = anims.first(where: { $0.id == l.animId }), anim.frameCount > 0, anim.fps > 0 {
                let fc = Double(anim.frameCount)
                let tt = time * Double(anim.fps) * Double(max(0.0001, l.rate))
                var ft = tt.truncatingRemainder(dividingBy: fc); if ft < 0 { ft += fc }
                let f0 = Int(ft), f1 = (f0 + 1) % anim.frameCount, a = Float(ft - Double(f0))
                for b in 0..<min(nb, anim.tracks.count) where f0 < anim.tracks[b].count && f1 < anim.tracks[b].count {
                    let k0 = anim.tracks[b][f0], k1 = anim.tracks[b][f1]
                    if k0.count > 3 { foldRx[b] = k0[3] + (k1[3] - k0[3]) * a }   // 末层(base 覆盖)的 rx 生效,与 composed 同源
                }
            }
            guard let pose = localPose(time: heldTime(l.hold, l.animId, l.rate, time), rate: l.rate, animId: l.animId, use3D: use3D) else { continue }
            if composed == nil { composed = pose }
            else if l.additive { for b in 0..<nb { composed![b] = composed![b] * (localBind[b].inverse * pose[b]) } }
            else { composed = pose }
        }
        guard let local = composed else { return nil }

        // 2) 主折叠虹膜骨 = 自身 rx 强出平面(|rx|≥1.2)且驱动虹膜带顶点。无 → nil(非 fold 眼,零回归)。
        let band = irisBandBoneSet()
        var foldBones: [Int] = []
        for b in 0..<nb where band.contains(b) && abs(foldRx[b]) >= 1.2 { foldBones.append(b) }
        guard !foldBones.isEmpty else { return nil }
        // 闭合度 k(0..1):取主折叠骨 |rx| 最大者,k=cos(rx)(rx=0 睁 k=1,rx=π/2 闭 k=0)。
        let leadRx = foldBones.map { abs(foldRx[$0]) }.max() ?? 0
        let k = max(0, cos(min(leadRx, .pi / 2)))

        // 3) 父链累乘 world(与 skinLayers 同)。
        var world = [simd_float4x4](repeating: matrix_identity_float4x4, count: nb)
        for b in 0..<nb {
            let p = parent[b]
            world[b] = (p >= 0 && p < nb) ? world[p] * local[b] : local[b]
        }
        guard k < 0.999 else { return skinVerts(world: world) }   // 睁眼:逐元素 == skinLayers(零回归)

        // 4) 眼线中心 = 主折叠骨当前 world y(虹膜应收向闭合处)。
        var cyAcc: Float = 0; for b in foldBones { cyAcc += world[b].columns.3.y }
        let cy = cyAcc / Float(foldBones.count)
        let foldSet = Set(foldBones)
        // 5) ⭐**全虹膜带竖向收向眼线**(2026-06-21 凯尔西眨眼眼球还露着第5次报修):
        //    实测(WP_ONLY_IDS=863 隔离 + 真实 present 逐帧)trs3D 单独折叠**只把权重在主折叠骨 bone2 的虹膜
        //    顶点收成线**(隔离闭眼峰 600→284px,挂到角色身上后残更多),其余虹膜带顶点(权重在静止带骨
        //    {3,4,5} 或仍部分在 fold 骨)留着 → 用户**实机一直看到黄虹膜**(真实 present 帧 t≈8.33s 闭眼峰
        //    iris=3511 与睁眼无异,frame_500.png 肉眼睁着)。旧 step5 只收**静止带骨**(!foldSet && |rx|<0.5)
        //    仍漏一大片。
        //    修:闭眼时(k<1)把**所有**虹膜带骨(含 fold 骨自身)按 k 竖向压向眼线 cy → 整片虹膜收成水平
        //    眼线。纯竖向收缩(sq.columns.1.y=k,绕 cy)**只会把虹膜挤扁成线、不会横向位移到眼睑外**(消除
        //    旧 occludeFold「把静止带骨拖到眼睑外露一坨虹膜」的担忧——那是旧版只动部分骨产生的相对错位;
        //    全带同步收缩无此问题)。睁眼(k≈1)逐元素恒等(零回归,见 line 394 早返回)。
        //    fold 骨自身既由 trs3D 折叠又被竖向收缩 = 双重保险,k→0 时虹膜面积→0。
        //    WP_EYE_FOLD_PARTIAL=1 退回旧「只收静止带骨」行为(A/B 诊断)。
        let dbg = WPEnv.vars["WP_EYE_OCCLUDE_DBG"] != nil
        let partialOnly = WPEnv.vars["WP_EYE_FOLD_PARTIAL"] != nil
        if dbg { Log.write("OCCLUDE-FOLD lead|rx|=\(String(format:"%.2f",leadRx)) k=\(String(format:"%.2f",k)) foldBones=\(foldBones) cy=\(Int(cy)) allBand=\(!partialOnly)") }
        for b in 0..<nb where band.contains(b) {
            // 旧行为(WP_EYE_FOLD_PARTIAL):只收**静止**带骨,fold 骨留给 trs3D。
            if partialOnly && (foldSet.contains(b) || abs(foldRx[b]) >= 0.5) { continue }
            var sq = matrix_identity_float4x4
            sq.columns.1.y = k
            sq.columns.3.y = cy * (1 - k)
            world[b] = sq * world[b]
        }
        return skinVerts(world: world)
    }

    /// 求指定 animId 在 time 时刻的蒙皮顶点(单位空间 [x,y,u,v])。失败/无骨返回 nil(调用方回退 bind)。
    /// use3D=眼睛层用完整 3D TRS;false=主 puppet 平面 TRS(零回归)。
    func skin(time: Double, rate: Float, animId: Int, use3D: Bool = false) -> [Float]? {
        // worldAnim[b] = 父链累乘的该帧骨骼世界变换(与 animatedAttachmentWorld 共享同一求值)。
        guard let world = worldAnim(time: time, rate: rate, animId: animId, use3D: use3D) else { return nil }
        return skinVerts(world: world)
    }

    /// 该动画是否「平面内」(planar):所有关键帧的 rx(绕X)/ry(绕Y)旋转都近 0。
    /// 诊断用(2026-06-14c 起眼睛层用完整 3D trs3D 表示出平面旋转闭合眼球,主 puppet 仍用平面 trs;
    /// 不再据此门控蒙皮;保留供 A/B 分析与未来判定)。
    func isAnimationPlanar(_ animId: Int) -> Bool {
        guard let anim = anims.first(where: { $0.id == animId }) ?? anims.first else { return true }
        let eps: Float = 0.05   // ≈3°:超过即视为出平面旋转
        for track in anim.tracks {
            for k in track where k.count >= 5 {
                if abs(k[3]) > eps || abs(k[4]) > eps { return false }   // rx/ry 出平面 → 平面 skinner 无法表示
            }
        }
        return true
    }

    /// ⭐NSL「轻扬」摇摆蒙皮(白影草/飘带/头发/尾巴):多个摆动 anim 同时播、各自相位偏移+blend 强度,
    /// 在 **TRS 分量空间**累加相对 bind 的增量(角度·blend、平移·blend)再重建有效旋转 → 相邻骨相位错开=行波。
    /// (矩阵线性插值缩 blend 会产生不可逆剪切/直流偏置整株掰弯=踩坑,故按分量。)bind 静止帧→增量0→退 bind(零回归)。
    /// 用 animId(不依赖骨名;main stride-fix 已正确解析 22 动画)。NSL2DScriptHost.animLayerCommands 喂 (animId,rate,phase,blend)。
    func skinSway(time: Double, layers: [(animId: Int, rate: Float, phase: Float, blend: Float)]) -> [Float]? {
        guard hasSkin, !layers.isEmpty else { return nil }
        let nb = parent.count
        var dTx = [Float](repeating: 0, count: nb)
        var dTy = [Float](repeating: 0, count: nb)
        var dRz = [Float](repeating: 0, count: nb)
        var any = false
        func bindTRS(_ b: Int) -> (tx: Float, ty: Float, rz: Float) {
            let m = localBind[b]
            return (m.columns.3.x, m.columns.3.y, atan2(m.columns.0.y, m.columns.0.x))
        }
        for l in layers {
            guard let anim = anims.first(where: { $0.id == l.animId }) else { continue }
            guard anim.frameCount > 0, anim.fps > 0 else { continue }
            let fc = Double(anim.frameCount)
            let tt = time * Double(anim.fps) * Double(max(0.0001, l.rate)) + Double(l.phase) * fc
            var ft = tt.truncatingRemainder(dividingBy: fc); if ft < 0 { ft += fc }
            let f0 = Int(ft), f1 = (f0 + 1) % anim.frameCount
            let a = Float(ft - Double(f0))
            let w = l.blend
            for b in 0..<nb {
                guard b < anim.tracks.count, f0 < anim.tracks[b].count, f1 < anim.tracks[b].count else { continue }
                let k0 = anim.tracks[b][f0], k1 = anim.tracks[b][f1]
                func lp(_ i: Int) -> Float { k0[i] + (k1[i] - k0[i]) * a }
                let bt = bindTRS(b)
                dTx[b] += (lp(0) - bt.tx) * w
                dTy[b] += (lp(1) - bt.ty) * w
                dRz[b] += (lp(5) - bt.rz) * w
                any = true
            }
        }
        guard any else { return nil }
        var local = [simd_float4x4](repeating: matrix_identity_float4x4, count: nb)
        for b in 0..<nb {
            let bt = bindTRS(b)
            let sx = simd_length(localBind[b].columns.0)
            let sy = simd_length(localBind[b].columns.1)
            local[b] = Self.trs(t: SIMD3(bt.tx + dTx[b], bt.ty + dTy[b], localBind[b].columns.3.z),
                                rz: bt.rz + dRz[b],
                                s: SIMD3(sx == 0 ? 1 : sx, sy == 0 ? 1 : sy, 1))
        }
        var world = [simd_float4x4](repeating: matrix_identity_float4x4, count: nb)
        for b in 0..<nb {
            let p = parent[b]
            world[b] = (p >= 0 && p < nb) ? world[p] * local[b] : local[b]
        }
        return skinVerts(world: world)
    }

    /// 共享顶点蒙皮:skin[b] = world[b]·invBind[b],逐顶点 4 骨加权,输出单位空间 [x,y,u,v]。
    private func skinVerts(world: [simd_float4x4]) -> [Float] {
        let nb = world.count
        var skinned = [SIMD2<Float>](repeating: .zero, count: rawPos.count)
        for i in 0..<rawPos.count {
            let p4 = SIMD4<Float>(rawPos[i].x, rawPos[i].y, 0, 1)
            var acc = SIMD4<Float>(0, 0, 0, 0)
            let idx = boneIdx[i], wt = boneWt[i]
            for k in 0..<4 {
                let w = wt[k]; if w == 0 { continue }
                let bi = Int(idx[k]); guard bi >= 0, bi < nb else { continue }
                acc += (world[bi] * invBind[bi]) * p4 * w
            }
            // 若权重全 0(异常)→ 退原始位置。acc.x/acc.y 已含完整 3D 变换后的屏幕平面坐标(use3D 时 trs3D
            // 把 rx/ry 出平面旋转的 x/y 收缩算进 acc.xy);场景为正交投影,acc.z 不喂顶点(丢 z = 正交投影),
            // 出平面旋转对 x/y 的收缩(眼睛闭合成眼线)已忠实保留。
            skinned[i] = (acc.w != 0 || wt[0] + wt[1] + wt[2] + wt[3] > 0) ? SIMD2(acc.x, acc.y) : rawPos[i]
            if !skinned[i].x.isFinite || !skinned[i].y.isFinite { skinned[i] = rawPos[i] }
        }
        return unitVerts(skinned)
    }

    /// T·Rz·S 矩阵(列主序 simd;平面动画专用,只构 rz,丢 rx/ry)。
    /// 保留供 m眼睛 等平面挤眼路径与零回归 A/B。
    private static func trs(t: SIMD3<Float>, rz: Float, s: SIMD3<Float>) -> simd_float4x4 {
        let c = cos(rz), sn = sin(rz)
        // 列主序:列 = 基向量
        let c0 = SIMD4<Float>( c * s.x,  sn * s.x, 0, 0)
        let c1 = SIMD4<Float>(-sn * s.y,  c * s.y, 0, 0)
        let c2 = SIMD4<Float>(0, 0, s.z, 0)
        let c3 = SIMD4<Float>(t.x, t.y, t.z, 1)
        return simd_float4x4(columns: (c0, c1, c2, c3))
    }

    /// 完整 3D TRS 矩阵(列主序 simd):T · Rz·Ry·Rx · S。
    /// 加入 rx(绕X,lp3)/ry(绕Y,lp4)出平面旋转 —— 凯尔希「眼睛」anim1405 bone2 rx→π/2 让虹膜
    /// 顶点绕 X 翻转 + tz→−61 后退,正交投影下其 x/y 收缩把眼睛闭合成眼线(无需背面剔除,实测干净闭合)。
    /// 旋转约定与 simd 列主序一致:R = Rz·Ry·Rx(先绕 X 再 Y 再 Z),缩放最后乘进各列。
    /// rx=ry=0 时退化为 trs(只 rz)的结果(逐元素等价 → 平面动画零回归)。
    static func trs3D(t: SIMD3<Float>, rx: Float, ry: Float, rz: Float, s: SIMD3<Float>) -> simd_float4x4 {
        let cx = cos(rx), sx = sin(rx)
        let cy = cos(ry), sy = sin(ry)
        let cz = cos(rz), sz = sin(rz)
        // R = Rz * Ry * Rx(列主序 3x3 旋转,标准 ZYX 复合)
        let r00 = cz * cy
        let r01 = cz * sy * sx - sz * cx
        let r02 = cz * sy * cx + sz * sx
        let r10 = sz * cy
        let r11 = sz * sy * sx + cz * cx
        let r12 = sz * sy * cx - cz * sx
        let r20 = -sy
        let r21 = cy * sx
        let r22 = cy * cx
        // 列主序:列 i = R 的第 i 列 × s[i]
        let c0 = SIMD4<Float>(r00 * s.x, r10 * s.x, r20 * s.x, 0)
        let c1 = SIMD4<Float>(r01 * s.y, r11 * s.y, r21 * s.y, 0)
        let c2 = SIMD4<Float>(r02 * s.z, r12 * s.z, r22 * s.z, 0)
        let c3 = SIMD4<Float>(t.x, t.y, t.z, 1)
        return simd_float4x4(columns: (c0, c1, c2, c3))
    }

    // ============================ 解析 ============================
    static func parse(_ data: Data, size: SIMD2<Float>) -> PuppetMesh? {
        guard size.x > 0, size.y > 0 else { return nil }
        let b = [UInt8](data)
        let markerSize = 9
        guard b.count >= markerSize, let magic = String(bytes: b[0..<8], encoding: .ascii),
              magic == "MDLV0019" || magic == "MDLV0021" || magic == "MDLV0023" else { return nil }
        // MDLV0019(御剑 朱鹤/挂饰/刀 等):mesh 顶点布局与 0021/0023 相同(stride 80,pos@0/uv@72,扫描定位);
        // MDLS=0002 / MDLA=0005 经逐字节验证与 0004/0006 布局相同(2026-06-10),骨骼/动画一并解析。
        // 刀 anim673=沿刀身滑动+飞行(与龙配对)、挂饰 516=摆动、朱鹤=飞行——此前版本门禁跳过=静态 bind 是「刀偏上」的另一半真因。
        func u32(_ o: Int) -> UInt32 {
            guard o + 4 <= b.count else { return 0 }
            return UInt32(b[o]) | (UInt32(b[o+1]) << 8) | (UInt32(b[o+2]) << 16) | (UInt32(b[o+3]) << 24)
        }
        func i32(_ o: Int) -> Int32 { Int32(bitPattern: u32(o)) }
        func f32(_ o: Int) -> Float { Float(bitPattern: u32(o)) }
        // 按 ASCII tag 扫描定位各段
        func findTag(_ tag: [UInt8], from: Int) -> Int? {
            var s = from
            while s + tag.count <= b.count {
                var ok = true
                for k in 0..<tag.count where b[s+k] != tag[k] { ok = false; break }
                if ok { return s }
                s += 1
            }
            return nil
        }
        let mdlsRaw = findTag([0x4D,0x44,0x4C,0x53], from: markerSize)   // "MDLS"(原始位置,定 mesh 扫描上界)
        let mdlaRaw = findTag([0x4D,0x44,0x4C,0x41], from: markerSize)   // "MDLA"
        let meshUpper = mdlsRaw ?? mdlaRaw ?? b.count
        // 已逐字节验证的版本启用骨骼/动画解析:MDLS0004/0002、MDLA0006/0005(2026-06-10 御剑刀/挂饰逐字节
        // 验证 0002/0005 与 0004/0006 **布局完全相同**:MDLS u8+u32ptr+u32 boneCount+每骨同构;MDLA 解析出
        // 刀 anim id=673「动画 1」与 scene.json 精确匹配、track sz==36×(frames+1) 自洽、挂饰 516/150帧同验)。
        // 其他版本布局未知 → 跳过 → 静态 bind(安全)。
        func verOK(_ p: Int?, _ vers: [String]) -> Int? {
            guard let p = p, p + 8 <= b.count,
                  let v = String(bytes: b[(p+4)..<(p+8)], encoding: .ascii), vers.contains(v) else { return nil }
            return p
        }
        let mdlsRaw2 = mdlsRaw   // 供 MDAT 上界
        let mdls = verOK(mdlsRaw, ["0004", "0002"])
        let mdla = verOK(mdlaRaw, ["0006", "0005"])
        let mdatRaw = findTag([0x4D,0x44,0x41,0x54], from: markerSize)   // "MDAT"(部件间挂点)
        let mdat = verOK(mdatRaw, ["0001"])
        _ = mdlsRaw2

        // ---- MDLV mesh:[reserved u32][vertexBytes u32] + 顶点 + [indexBytes u32] + 索引 ----
        let vertexStride = 80, meshHeaderSize = 8
        var headerOffset = -1, vertexBytes = 0, indexBytes = 0
        var off = markerSize
        while off + meshHeaderSize + 4 < meshUpper {
            let cvb = Int(u32(off + 4))
            let verticesOff = off + meshHeaderSize
            let idxLenOff = verticesOff + cvb
            if cvb == 0 || cvb % vertexStride != 0 || idxLenOff + 4 > meshUpper { off += 1; continue }
            let cib = Int(u32(idxLenOff))
            let idxOff = idxLenOff + 4
            if cib == 0 || cib % 6 != 0 || idxOff + cib > meshUpper { off += 1; continue }
            headerOffset = off; vertexBytes = cvb; indexBytes = cib; break
        }
        guard headerOffset >= 0 else { return nil }
        let vertexCount = vertexBytes / vertexStride
        let verticesOffset = headerOffset + meshHeaderSize
        let indicesOffset = verticesOffset + vertexBytes + 4
        let indexCount = indexBytes / 2
        guard verticesOffset + vertexCount * vertexStride <= b.count,
              indicesOffset + indexCount * 2 <= b.count else { return nil }

        var rawPos = [SIMD2<Float>](); rawPos.reserveCapacity(vertexCount)
        var uv = [SIMD2<Float>](); uv.reserveCapacity(vertexCount)
        var bIdx = [SIMD4<UInt32>](); bIdx.reserveCapacity(vertexCount)
        var bWt = [SIMD4<Float>](); bWt.reserveCapacity(vertexCount)
        for vi in 0..<vertexCount {
            let vo = verticesOffset + vi * vertexStride
            rawPos.append(SIMD2(f32(vo), f32(vo + 4)))
            bIdx.append(SIMD4(u32(vo + 40), u32(vo + 44), u32(vo + 48), u32(vo + 52)))
            bWt.append(SIMD4(f32(vo + 56), f32(vo + 60), f32(vo + 64), f32(vo + 68)))
            uv.append(SIMD2(f32(vo + 72), f32(vo + 76)))
        }
        var indices = [UInt16](); indices.reserveCapacity(indexCount)
        for ii in 0..<indexCount {
            let io = indicesOffset + ii * 2
            let idx = UInt16(b[io]) | (UInt16(b[io+1]) << 8)
            if Int(idx) >= vertexCount { return nil }
            indices.append(idx)
        }

        // ---- MDLV 子网格 + Puppet clipping ----
        // mesh 索引之后、MDLS 之前的已验证布局（6 张真实含 clipping 的壁纸逐字节对齐）：
        //   u8 + u32(=1) + u32 morphBytes + morphData
        //   u8 + u32 groupBytes + N×{u32 id,u32 material,u32 start,u32 count}
        //   u32 clipCount
        //   clip = u32 flags + u32(0) + cstr texture + u32(0)
        //          + u32 targetCount + targetOrder[] + u32 sourceCount + sourceOrder[]
        // clipping 引用的是 group 的顺序下标。旧解析把整个索引缓冲一次画完，丢掉了这层关系，
        // 因而眼白骨闭合时虹膜仍完整可见。
        var drawGroups = [DrawGroup]()
        var clippingMasks = [ClippingMask]()
        let meshEnd = indicesOffset + indexBytes
        if let upper = mdlsRaw, meshEnd + 18 <= upper {
            var p = meshEnd
            let firstFlag = b[p]; p += 1
            let firstCount = Int(u32(p)); p += 4
            let morphBytes = Int(u32(p)); p += 4
            if firstFlag == 1, firstCount == 1, morphBytes >= 0, p + morphBytes + 5 <= upper {
                p += morphBytes
                let groupFlag = b[p]; p += 1
                let groupBytes = Int(u32(p)); p += 4
                if groupFlag == 1, groupBytes > 0, groupBytes % 16 == 0,
                   p + groupBytes + 4 <= upper {
                    let groupStart = p
                    let groupCount = groupBytes / 16
                    var parsedGroups = [DrawGroup](); parsedGroups.reserveCapacity(groupCount)
                    var groupsOK = true
                    for gi in 0..<groupCount {
                        let go = groupStart + gi * 16
                        let id = Int(u32(go))
                        let start = Int(u32(go + 8))
                        let count = Int(u32(go + 12))
                        if start < 0 || count <= 0 || start + count > indices.count {
                            groupsOK = false; break
                        }
                        parsedGroups.append(DrawGroup(id: id, startIndex: start, indexCount: count))
                    }
                    p += groupBytes
                    let clipCount = Int(u32(p)); p += 4
                    var parsedClips = [ClippingMask]()
                    var clipsOK = groupsOK && clipCount >= 0 && clipCount < 4096
                    if clipsOK {
                        for _ in 0..<clipCount {
                            guard p + 8 <= upper else { clipsOK = false; break }
                            _ = u32(p)       // flags（版本/组合位；渲染只需拓扑关系）
                            _ = u32(p + 4)   // reserved
                            p += 8
                            let pathStart = p
                            while p < upper && b[p] != 0 { p += 1 }
                            guard p < upper else { clipsOK = false; break }
                            let path = String(bytes: b[pathStart..<p], encoding: .utf8) ?? ""
                            p += 1
                            guard p + 8 <= upper else { clipsOK = false; break }
                            _ = u32(p)       // reserved
                            let targetCount = Int(u32(p + 4)); p += 8
                            guard targetCount > 0, targetCount <= groupCount, p + targetCount * 4 + 4 <= upper else {
                                clipsOK = false; break
                            }
                            var targets = [Int](); targets.reserveCapacity(targetCount)
                            for _ in 0..<targetCount { targets.append(Int(u32(p))); p += 4 }
                            let sourceCount = Int(u32(p)); p += 4
                            guard sourceCount > 0, sourceCount <= groupCount, p + sourceCount * 4 <= upper else {
                                clipsOK = false; break
                            }
                            var sources = [Int](); sources.reserveCapacity(sourceCount)
                            for _ in 0..<sourceCount { sources.append(Int(u32(p))); p += 4 }
                            guard path.hasPrefix("masks/clipping_mask_"),
                                  targets.allSatisfy({ $0 >= 0 && $0 < groupCount }),
                                  sources.allSatisfy({ $0 >= 0 && $0 < groupCount }) else {
                                clipsOK = false; break
                            }
                            parsedClips.append(ClippingMask(texturePath: path,
                                                            targetGroups: targets,
                                                            sourceGroups: sources))
                        }
                    }
                    // 精确吃到 MDLS 才采用；未知版本/布局一律保持旧的整网格安全路径。
                    if groupsOK, clipsOK, p == upper {
                        drawGroups = parsedGroups
                        clippingMasks = parsedClips
                    }
                }
            }
        }

        // ---- MDLS 骨骼:u8 + u32(ptr) + u32 boneCount;每骨 u8+u32 id+i32 parent+u32(matBytes)+16f 矩阵(行主序)+ JSON cstr ----
        var parent = [Int](); var localBind = [simd_float4x4]()
        if let m = mdls {
            let hdrEnd = m + 8 + 1 + 4     // 跳 magic(8) + u8 flag + u32 ptr
            let boneCount = Int(u32(hdrEnd))
            var o = hdrEnd + 4             // 默认:骨区紧跟头(旧假设,兜底)
            // 数据锚点定位 bone0(2026-06-15 修头发炸开真因):每骨 = flag1+id4+parent4+matBytes4(=64)+matrix64+cstr(NUL)+
            //   1字节名字后缀。bone0 是唯一 parent=-1 的根骨 → 字节模式 `FF FF FF FF 40 00 00 00`(parent=-1 + matBytes=64)
            //   全库唯一。旧解析硬设「骨区紧跟9字节头」,对某些 strand(刘海)/尾巴 puppet 的 bone0 前有 0~2 字节前缀 →
            //   从错位起 → desync。用锚点定位 bone0 flag(=anchor-5),限定头后小窗(前缀≤8)避免误命中,失败退旧。
            let strideFix = WPEnv.vars["WP_NO_MDLS_STRIDE_FIX"] == nil
            let mdlsEnd = mdlaRaw ?? b.count
            if strideFix, let anchor = findTag([0xFF,0xFF,0xFF,0xFF,0x40,0x00,0x00,0x00], from: hdrEnd + 4),
               anchor < mdlsEnd, anchor - 5 >= hdrEnd + 4, anchor - 5 <= hdrEnd + 4 + 8 {
                o = anchor - 5             // bone0 flag = parent锚点 - (flag1+id4)
            }
            if boneCount > 0 && boneCount < 4096 {
                for bi in 0..<boneCount {
                    guard o + 13 + 64 <= b.count else { break }
                    o += 1                 // u8 flag
                    o += 4                 // u32 id
                    let par = Int(i32(o)); o += 4
                    let matBytes = Int(u32(o)); o += 4   // 通常 64
                    // 16×f32 行主序行向量(平移在行3 [12][13][14])。simd 是列主序列向量(M×v,平移在列3)。
                    // 行向量矩阵 M_row 与列向量矩阵 M_col 同一变换满足 M_col = transpose(M_row)。
                    // `columns:` 把每 4 个 float(M_row 的一行)当 simd 的一列 → 得到的正是 transpose(M_row)=M_col。
                    // (之前用 `rows:` 直接当行装入 = M_row,被 simd 当列向量乘 → 平移/朝向全错 → 角色散架。)
                    var rm = [Float](repeating: 0, count: 16)
                    for k in 0..<16 { rm[k] = f32(o + k * 4) }
                    o += matBytes
                    let mat = simd_float4x4(columns: (
                        SIMD4(rm[0], rm[1], rm[2], rm[3]),
                        SIMD4(rm[4], rm[5], rm[6], rm[7]),
                        SIMD4(rm[8], rm[9], rm[10], rm[11]),
                        SIMD4(rm[12], rm[13], rm[14], rm[15])))
                    parent.append(par); localBind.append(mat)
                    // 跳过 JSON cstr(到 NUL)
                    while o < b.count && b[o] != 0 { o += 1 }
                    o += 1                 // 跳 NUL
                    // stride 自愈(2026-06-15):吃掉 cstr 后的 1 字节名字后缀。若非末根,下一根 matBytes(o+9)应==64,
                    // 否则逐字节前进(guard≤8)对齐。修「每骨 desync 1 字节 → 第2根 matBytes 读成 16384 → break →
                    // hasSkin=false → 刘海渲散开 bind 姿态(头顶炸尖刺)而非播 sway 动画 anim707(frame0=自然下垂)」。
                    // 对已正常解析的 puppet(凯尔希/御剑)下一根本就对齐(u32(o+9)==64)→ 不前进 → 零变化。
                    if strideFix, bi < boneCount - 1 {
                        var gd = 0
                        while o + 13 <= b.count && u32(o + 9) != 64 && gd < 8 { o += 1; gd += 1 }
                    }
                }
            }
        }
        // worldBind = 父链累乘;invBind = inverse(worldBind)
        var invBind = [simd_float4x4]()
        var worldBind = [simd_float4x4]()
        if !parent.isEmpty {
            worldBind = [simd_float4x4](repeating: matrix_identity_float4x4, count: parent.count)
            for bIdx2 in 0..<parent.count {
                let p = parent[bIdx2]
                worldBind[bIdx2] = (p >= 0 && p < parent.count) ? worldBind[p] * localBind[bIdx2] : localBind[bIdx2]
            }
            invBind = worldBind.map { $0.inverse }
        }

        // ---- MDAT 部件间挂点:u8 + u32(ptr) + u16 count;每条 = u16 boneIdx + cstr name + 16×f32 行主序矩阵 ----
        // (凯尔希主体_puppet.mdl 逐字节验证:头部→bone5、脖颈→bone3、胸部→bone1,各带局部偏移矩阵。)
        // 矩阵行主序(平移在 [12][13][14]),与骨骼 bind 同约定 → `columns:` 装入即得列主序(=转置)。
        var attachments = [Attachment]()
        if let m = mdat {
            var o = m + 8
            o += 1                         // u8 flag
            o += 4                         // u32 ptr
            guard o + 2 <= b.count else { return nil }
            let cnt = Int(UInt(b[o]) | (UInt(b[o+1]) << 8)); o += 2
            if cnt > 0 && cnt < 4096 {
                for _ in 0..<cnt {
                    guard o + 2 <= b.count else { break }
                    let bi = Int(UInt(b[o]) | (UInt(b[o+1]) << 8)); o += 2
                    let start = o
                    while o < b.count && b[o] != 0 { o += 1 }
                    let name = String(bytes: b[start..<o], encoding: .utf8) ?? ""
                    o += 1                 // 跳 NUL
                    guard o + 64 <= b.count else { break }
                    var rm = [Float](repeating: 0, count: 16)
                    for k in 0..<16 { rm[k] = f32(o + k * 4) }
                    o += 64
                    let mat = simd_float4x4(columns: (
                        SIMD4(rm[0], rm[1], rm[2], rm[3]),
                        SIMD4(rm[4], rm[5], rm[6], rm[7]),
                        SIMD4(rm[8], rm[9], rm[10], rm[11]),
                        SIMD4(rm[12], rm[13], rm[14], rm[15])))
                    attachments.append(Attachment(name: name, bone: bi, local: mat))
                }
            }
        }

        // ---- MDLA 动画:u8 + u32(ptr) + u32 animCount;每动画 头部 + boneCount 条轨道 ----
        // ⚠️ anim 之间存在**零填充 footer**(御剑龙 anim1「动画 1」→ anim2「动画 2」之间 31 字节 0x00,语义未知):
        //   旧顺序解析读完 anim1 轨道后直接读 anim2 头 → 读进 footer → guard 失败 break → **后续动画全部静默丢失**
        //  (御剑龙的 additive「动画 2」=下压/飞行整体运动被丢 = 龙偏上的真因之一)。
        //   修:probeAnimHeader 头部探测(不前进;boneCount≤骨数+fps/frameCount 合理 = 强校验),直接位置失败则
        //   跳过连续 0x00 重试一次(footer 全零;误同步概率极低,失败仍 break 保持旧行为)。
        var anims = [Anim]()
        if let m = mdla, !parent.isEmpty {
            var o = m + 8
            o += 1                         // u8 flag
            o += 4                         // u32 ptr
            let animCount = Int(u32(o)); o += 4
            // 头部探测:id+unk + name(cstr) + mode(cstr) + fps + frameCount + unk + boneCount + unk。
            // 合理则返回 (id,fps,frameCount,boneCount,轨道起点),否则 nil(不动 o)。
            func probeAnimHeader(_ start: Int) -> (id: Int, fps: Float, frameCount: Int, bc: Int, mode: String, tracksStart: Int)? {
                var p = start
                guard p + 8 <= b.count else { return nil }
                let id = Int(u32(p)); p += 8
                func skipCstr(_ p: inout Int, maxLen: Int = 96) -> Bool {
                    let s = p
                    while p < b.count && b[p] != 0 { p += 1; if p - s > maxLen { return false } }
                    guard p < b.count else { return false }
                    p += 1
                    return true
                }
                guard skipCstr(&p) else { return nil }      // 第1串=name(丢)
                let modeStart = p
                guard skipCstr(&p), p + 20 <= b.count else { return nil }   // 第2串=mode(播放模式)
                let mode = (modeStart < p - 1) ? (String(bytes: b[modeStart..<(p - 1)], encoding: .utf8) ?? "") : ""
                let fps = f32(p); p += 4
                let fc = Int(u32(p)); p += 4
                p += 4                     // u32 unk
                let bc = Int(u32(p)); p += 4
                p += 4                     // u32 unk
                guard id >= 0, id < 1_000_000, fps > 0, fps <= 480,
                      fc > 0, fc < 100_000, bc > 0, bc <= parent.count else { return nil }
                return (id, fps, fc, bc, mode, p)
            }
            if animCount > 0 && animCount < 256 {
                for animIdx in 0..<animCount {
                    var hdr = probeAnimHeader(o)
                    if hdr == nil, animIdx > 0 {            // 直接位置失败 → 跳零 footer 重试
                        var p = o
                        while p + 1 < b.count && b[p] == 0 { p += 1 }
                        if p != o, let h2 = probeAnimHeader(p) { hdr = h2; o = p }
                    }
                    guard let h = hdr else { break }
                    o = h.tracksStart
                    var tracks = [[[Float]]]()
                    var bad = false
                    for _ in 0..<h.bc {
                        guard o + 4 <= b.count else { bad = true; break }
                        let trackSize = Int(u32(o)); o += 4
                        let recCount = trackSize / 36
                        guard recCount > 0, o + trackSize <= b.count else { bad = true; break }
                        var frames = [[Float]](); frames.reserveCapacity(recCount)
                        for r in 0..<recCount {
                            let ro = o + r * 36
                            var f9 = [Float](repeating: 0, count: 9)
                            for k in 0..<9 { f9[k] = f32(ro + k * 4) }
                            frames.append(f9)
                        }
                        tracks.append(frames)
                        o += trackSize
                        o += 4             // u32 trailer
                    }
                    if bad { break }
                    // ⭐逐骨 alpha 块(SKINNING_ALPHA,2026-06-26):TRS 轨道之后若下一 u32==1(flag)→ 是 alpha 块
                    //   `[u32 flag=1][u8][bc 条轨道,每条 = u32 size(=4×(frameCount+1)) + (frameCount+1) f32 + u32 trailer]`;
                    //   flag!=1(御剑等绝大多数,下一 u32=0 是零填充)→ 无 alpha 块,**不动 o**(留给下面零填充跳过找下一动画)。
                    //   WE 眨眼数据(虹膜/眼睑层透明度淡出)藏在这通道,引擎此前从不解析 → xraypad-眠/泠泠泉心等眨眼渲不对的真因。
                    var boneAlpha: [[Float]]? = nil
                    if o + 4 <= b.count, u32(o) == 1 {
                        var ao = o + 4 + 1     // 跳 u32 flag + u8
                        var aTracks = [[Float]](); aTracks.reserveCapacity(h.bc)
                        var aok = true
                        let need = 4 * (h.frameCount + 1)
                        for _ in 0..<h.bc {
                            guard ao + 4 <= b.count else { aok = false; break }
                            let asz = Int(u32(ao)); ao += 4
                            guard asz == need, ao + asz <= b.count else { aok = false; break }
                            var vals = [Float](repeating: 1, count: h.frameCount + 1)
                            for k in 0...h.frameCount { vals[k] = f32(ao + k * 4) }
                            aTracks.append(vals)
                            ao += asz; ao += 4    // u32 trailer
                        }
                        if aok, aTracks.count == h.bc { boneAlpha = aTracks; o = ao }   // 全部成功才推进 o(否则不动,安全)
                    }
                    anims.append(Anim(id: h.id, fps: h.fps, frameCount: h.frameCount, mode: h.mode, tracks: tracks, boneAlpha: boneAlpha))
                }
            }
        }

        if WPEnv.vars["WP_PUPPET_LOG"] != nil {
            Log.write("PUPPETPARSE mdls=\(mdlsRaw.map(String.init) ?? "nil") mdla=\(mdlaRaw.map(String.init) ?? "nil") bones=\(parent.count) anims=\(anims.count)[\(anims.map { $0.id })] idx=\(indices.count) size=\(Int(size.x))x\(Int(size.y))")
            for a in anims where a.boneAlpha != nil {
                let mins = a.boneAlpha!.enumerated().compactMap { (bi, v) -> String? in let m = v.min() ?? 1; return m < 0.95 ? "b\(bi)→\(String(format: "%.2f", m))" : nil }
                Log.write("  ALPHA anim\(a.id): 淡出骨 \(mins.joined(separator: " "))")
            }
        }
        // 诊断:WP_ANIM_DUMP=<animId> 打印各骨 bind 世界位置 + 该 anim 逐骨 9-分量(tx,ty,tz,rx,ry,rz,sx,sy,sz)帧间范围。
        // 用于搞清眨眼:哪些骨是眼睑(平移/缩放盖)哪些是眼球/虹膜(应被盖)。仅诊断,生产不触发。
        if let want = WPEnv.vars["WP_ANIM_DUMP"], let wantId = Int(want),
           let anim = anims.first(where: { $0.id == wantId }) {
            Log.write("ANIMDUMP anim\(wantId) fps=\(anim.fps) frames=\(anim.frameCount) bones=\(parent.count)")
            for b in 0..<parent.count {
                let wb = worldBind[b]
                let pos = SIMD2(wb.columns.3.x, wb.columns.3.y)
                guard b < anim.tracks.count, !anim.tracks[b].isEmpty else {
                    Log.write("  bone\(b) parent=\(parent[b]) bind=(\(Int(pos.x)),\(Int(pos.y))) NO-TRACK"); continue
                }
                var lo = [Float](repeating: .greatestFiniteMagnitude, count: 9)
                var hi = [Float](repeating: -.greatestFiniteMagnitude, count: 9)
                for fr in anim.tracks[b] where fr.count >= 9 {
                    for k in 0..<9 { lo[k] = min(lo[k], fr[k]); hi[k] = max(hi[k], fr[k]) }
                }
                func rng(_ k: Int) -> String { abs(hi[k]-lo[k]) < 0.001 ? String(format:"%.2f", lo[k]) : String(format:"%.2f→%.2f", lo[k], hi[k]) }
                // 该骨主导影响的顶点 UV 质心(权重加权):识别它驱动图集哪区(v 小=睫毛上, v 中=虹膜, v 大=肤色眼睑)。
                var wsum: Float = 0, uacc: Float = 0, vacc: Float = 0, vlist: [Float] = []
                for vi in 0..<rawPos.count {
                    let bi = bIdx[vi], bw = bWt[vi]
                    for s in 0..<4 where Int(bi[s]) == b {
                        let w = bw[s]; wsum += w; uacc += uv[vi].x * w; vacc += uv[vi].y * w
                        if w > 0.4 { vlist.append(uv[vi].y) }
                    }
                }
                let uc = wsum > 0 ? uacc/wsum : -1, vc = wsum > 0 ? vacc/wsum : -1
                let region = vc < 0 ? "?" : (vc < 0.33 ? "睫毛上" : vc < 0.62 ? "虹膜中" : "肤眼睑下")
                Log.write("  bone\(b) parent=\(parent[b]) bind=(\(Int(pos.x)),\(Int(pos.y))) t=(\(rng(0)),\(rng(1)),\(rng(2))) r=(\(rng(3)),\(rng(4)),\(rng(5))) s=(\(rng(6)),\(rng(7)),\(rng(8))) UVc=(\(String(format:"%.2f",uc)),\(String(format:"%.2f",vc)))[\(region)] nv=\(vlist.count)")
            }
            // 逐帧 sclera/iris 骨 sy 轨迹(找闭眼帧 + 看塌缩方向)。WP_EYE_FRAMEDUMP=1。
            if WPEnv.vars["WP_EYE_FRAMEDUMP"] != nil {
                // 列出有 sy 塌缩的骨(sy 最小 < 0.5)+ 虹膜骨(sy≈1),逐帧 sy。
                func boneFrameSy(_ b: Int) -> [Float] { anim.tracks[b].map { $0.count > 7 ? $0[7] : 1 } }
                for b in 0..<min(parent.count, anim.tracks.count) {
                    let sys = boneFrameSy(b)
                    guard let mn = sys.min(), mn < 0.5 || (b >= 22) else { continue }
                    Log.write("FRAMEDUMP bone\(b) sy/frame: \(sys.map { String(format:"%.2f",$0) }.joined(separator:","))")
                }
            }
            // 逐顶点权重诊断(候选#1 验证):列出虹膜带(UV.v 0.33..0.62)顶点的 4 骨权重,
            // 看虹膜是否混了塌缩眼白骨(1/2/12/25)的权重。仅在 WP_EYE_VERTDUMP 设置时。
            if WPEnv.vars["WP_EYE_VERTDUMP"] != nil {
                Log.write("EYEVERTDUMP verts=\(rawPos.count) (iris band v∈[0.33,0.62])")
                for vi in 0..<rawPos.count {
                    let v = uv[vi].y
                    guard v >= 0.33, v <= 0.62 else { continue }
                    let bi = bIdx[vi], bw = bWt[vi]
                    let parts = (0..<4).map { "b\(bi[$0])=\(String(format:"%.2f",bw[$0]))" }.joined(separator:" ")
                    Log.write("  v\(vi) uv=(\(String(format:"%.2f",uv[vi].x)),\(String(format:"%.2f",v))) pos=(\(Int(rawPos[vi].x)),\(Int(rawPos[vi].y))) \(parts)")
                }
            }
        }
        return PuppetMesh(size: size, indices: indices,
                          drawGroups: drawGroups, clippingMasks: clippingMasks,
                          rawPos: rawPos, uv: uv,
                          boneIdx: bIdx, boneWt: bWt, parent: parent,
                          localBind: localBind, worldBind: worldBind, invBind: invBind,
                          anims: anims, attachments: attachments)
    }
}
