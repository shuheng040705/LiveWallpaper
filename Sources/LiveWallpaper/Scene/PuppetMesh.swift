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
    private let invBind: [simd_float4x4]    // 预算:inverse(worldBind[b])
    // 动画(按 id 索引):
    struct Anim { let id: Int; let fps: Float; let frameCount: Int; let tracks: [[[Float]]] }  // tracks[bone][frame] = 9 floats TRS
    private let anims: [Anim]

    var hasSkin: Bool { !anims.isEmpty && !parent.isEmpty }
    var bindVerts: [Float] { unitVerts(rawPos) }   // 静态 bind 姿态 [x,y,u,v]×N(与旧行为一致)

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

    /// 求指定 animId 在 time 时刻的蒙皮顶点(单位空间 [x,y,u,v])。失败/无骨返回 nil(调用方回退 bind)。
    func skin(time: Double, rate: Float, animId: Int) -> [Float]? {
        guard hasSkin else { return nil }
        guard let anim = anims.first(where: { $0.id == animId }) ?? anims.first else { return nil }
        guard anim.frameCount > 0, anim.fps > 0 else { return nil }
        let nb = parent.count
        // 时间 → 帧(loop):t = time·fps·rate mod frameCount
        let tt = time * Double(anim.fps) * Double(max(0.0001, rate))
        let fc = Double(anim.frameCount)
        var ft = tt.truncatingRemainder(dividingBy: fc); if ft < 0 { ft += fc }
        let f0 = Int(ft), f1 = (f0 + 1) % anim.frameCount
        let a = Float(ft - Double(f0))
        // 每骨局部动画矩阵 = T·Rz·S(2D puppet 只 Rz 有效;线性插值 TRS)
        var local = [simd_float4x4](repeating: matrix_identity_float4x4, count: nb)
        for b in 0..<nb {
            guard b < anim.tracks.count, f0 < anim.tracks[b].count, f1 < anim.tracks[b].count else { continue }
            let k0 = anim.tracks[b][f0], k1 = anim.tracks[b][f1]
            func lp(_ i: Int) -> Float { k0[i] + (k1[i] - k0[i]) * a }
            let t = SIMD3<Float>(lp(0), lp(1), lp(2))
            let rz = lp(5)
            let s = SIMD3<Float>(lp(6), lp(7), lp(8))
            local[b] = Self.trs(t: t, rz: rz, s: s)
        }
        // worldAnim[b] = worldAnim[parent]·local[b];skin[b] = worldAnim[b]·invBind[b]
        var world = [simd_float4x4](repeating: matrix_identity_float4x4, count: nb)
        for b in 0..<nb {
            let p = parent[b]
            world[b] = (p >= 0 && p < nb) ? world[p] * local[b] : local[b]
        }
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
            // 若权重全 0(异常)→ 退原始位置
            skinned[i] = (acc.w != 0 || wt[0] + wt[1] + wt[2] + wt[3] > 0) ? SIMD2(acc.x, acc.y) : rawPos[i]
            if !skinned[i].x.isFinite || !skinned[i].y.isFinite { skinned[i] = rawPos[i] }
        }
        return unitVerts(skinned)
    }

    /// T·Rz·S 矩阵(列主序 simd)。
    private static func trs(t: SIMD3<Float>, rz: Float, s: SIMD3<Float>) -> simd_float4x4 {
        let c = cos(rz), sn = sin(rz)
        // 列主序:列 = 基向量
        let c0 = SIMD4<Float>( c * s.x,  sn * s.x, 0, 0)
        let c1 = SIMD4<Float>(-sn * s.y,  c * s.y, 0, 0)
        let c2 = SIMD4<Float>(0, 0, s.z, 0)
        let c3 = SIMD4<Float>(t.x, t.y, t.z, 1)
        return simd_float4x4(columns: (c0, c1, c2, c3))
    }

    // ============================ 解析 ============================
    static func parse(_ data: Data, size: SIMD2<Float>) -> PuppetMesh? {
        guard size.x > 0, size.y > 0 else { return nil }
        let b = [UInt8](data)
        let markerSize = 9
        guard b.count >= markerSize, let magic = String(bytes: b[0..<8], encoding: .ascii),
              magic == "MDLV0021" || magic == "MDLV0023" else { return nil }
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
        // 仅对已逐字节验证的版本启用骨骼/动画解析(MDLS0004 / MDLA0006);其他版本布局未知 → 跳过 → 静态 bind(安全)。
        func verOK(_ p: Int?, _ ver: String) -> Int? {
            guard let p = p, p + 8 <= b.count,
                  String(bytes: b[(p+4)..<(p+8)], encoding: .ascii) == ver else { return nil }
            return p
        }
        let mdls = verOK(mdlsRaw, "0004")
        let mdla = verOK(mdlaRaw, "0006")

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
        if !parent.isEmpty {
            var worldBind = [simd_float4x4](repeating: matrix_identity_float4x4, count: parent.count)
            for bIdx2 in 0..<parent.count {
                let p = parent[bIdx2]
                worldBind[bIdx2] = (p >= 0 && p < parent.count) ? worldBind[p] * localBind[bIdx2] : localBind[bIdx2]
            }
            invBind = worldBind.map { $0.inverse }
        }

        // ---- MDLA 动画:u8 + u32(ptr) + u32 animCount;每动画 头部 + boneCount 条轨道 ----
        var anims = [Anim]()
        if let m = mdla, !parent.isEmpty {
            var o = m + 8
            o += 1                         // u8 flag
            o += 4                         // u32 ptr
            let animCount = Int(u32(o)); o += 4
            func cstr() -> String {        // 读 NUL 结尾字符串(并推进 o)
                let start = o
                while o < b.count && b[o] != 0 { o += 1 }
                let s = String(bytes: b[start..<o], encoding: .utf8) ?? ""
                o += 1
                return s
            }
            if animCount > 0 && animCount < 256 {
                for _ in 0..<animCount {
                    guard o + 8 <= b.count else { break }
                    let id = Int(u32(o)); o += 4
                    o += 4                 // u32 unk
                    _ = cstr()             // name
                    _ = cstr()             // mode
                    let fps = f32(o); o += 4
                    let frameCount = Int(u32(o)); o += 4
                    o += 4                 // u32 unk
                    let bc = Int(u32(o)); o += 4
                    o += 4                 // u32 unk
                    guard frameCount > 0, frameCount < 100000, bc > 0, bc < 4096 else { break }
                    var tracks = [[[Float]]]()
                    var bad = false
                    for _ in 0..<bc {
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
                    if !bad { anims.append(Anim(id: id, fps: fps, frameCount: frameCount, tracks: tracks)) }
                }
            }
        }

        return PuppetMesh(size: size, indices: indices, rawPos: rawPos, uv: uv,
                          boneIdx: bIdx, boneWt: bWt, parent: parent, invBind: invBind, anims: anims)
    }
}
