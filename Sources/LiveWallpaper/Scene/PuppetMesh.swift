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
    let size: SIMD2<Float>
    let indices: [UInt16]
    // 顶点(原始空间)+ 蒙皮数据:
    private let rawPos: [SIMD2<Float>]      // pos.xy(bind 姿态世界位置)
    private let uv: [SIMD2<Float>]
    private let boneIdx: [SIMD4<UInt32>]    // 每顶点 4 根骨索引
    private let boneWt: [SIMD4<Float>]      // 每顶点 4 个权重(和=1)
    // 骨骼:
    private let parent: [Int]
    private let localBind: [simd_float4x4]  // 每骨局部 bind(父相对)
    private let worldBind: [simd_float4x4]  // 累乘后的世界 bind
    private let invBind: [simd_float4x4]    // 预算:inverse(worldBind[b])
    // 动画(按 id 索引):
    struct Anim { let id: Int; let fps: Float; let frameCount: Int; let tracks: [[[Float]]] }  // tracks[bone][frame] = 9 floats TRS
    private let anims: [Anim]
    // 部件间挂点(MDAT0001):父部件用具名 attachment(如「头部」「胸部」)暴露子部件可挂的世界变换。
    // 每条 = (名, 所挂骨索引, 该挂点相对该骨的局部行主序矩阵)。子部件 scene.json 的 attachment 串按名匹配此表。
    struct Attachment { let name: String; let bone: Int; let local: simd_float4x4 }  // local 已转成列主序
    let attachments: [Attachment]

    var hasSkin: Bool { !anims.isEmpty && !parent.isEmpty }
    var bindVerts: [Float] { unitVerts(rawPos) }   // 静态 bind 姿态 [x,y,u,v]×N(与旧行为一致)
    var hasBones: Bool { !parent.isEmpty }

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
    func skinLayers(time: Double, layers: [(animId: Int, rate: Float, additive: Bool)], use3D: Bool = false) -> [Float]? {
        guard hasSkin, !layers.isEmpty else { return nil }
        let nb = parent.count
        var composed: [simd_float4x4]? = nil
        for l in layers {
            guard let pose = localPose(time: time, rate: l.rate, animId: l.animId, use3D: use3D) else { continue }
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

        // ---- MDLS 骨骼:u8 + u32(ptr) + u32 boneCount;每骨 u8+u32 id+i32 parent+u32(matBytes)+16f 矩阵(行主序)+ JSON cstr ----
        var parent = [Int](); var localBind = [simd_float4x4]()
        if let m = mdls {
            var o = m + 8
            o += 1                         // u8 flag
            o += 4                         // u32 ptr
            let boneCount = Int(u32(o)); o += 4
            if boneCount > 0 && boneCount < 4096 {
                for _ in 0..<boneCount {
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
            func probeAnimHeader(_ start: Int) -> (id: Int, fps: Float, frameCount: Int, bc: Int, tracksStart: Int)? {
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
                guard skipCstr(&p), skipCstr(&p), p + 20 <= b.count else { return nil }
                let fps = f32(p); p += 4
                let fc = Int(u32(p)); p += 4
                p += 4                     // u32 unk
                let bc = Int(u32(p)); p += 4
                p += 4                     // u32 unk
                guard id >= 0, id < 1_000_000, fps > 0, fps <= 480,
                      fc > 0, fc < 100_000, bc > 0, bc <= parent.count else { return nil }
                return (id, fps, fc, bc, p)
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
                    anims.append(Anim(id: h.id, fps: h.fps, frameCount: h.frameCount, tracks: tracks))
                }
            }
        }

        return PuppetMesh(size: size, indices: indices, rawPos: rawPos, uv: uv,
                          boneIdx: bIdx, boneWt: bWt, parent: parent,
                          localBind: localBind, worldBind: worldBind, invBind: invBind,
                          anims: anims, attachments: attachments)
    }
}
