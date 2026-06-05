import Metal
import simd

/// 鼠标涟漪的 GPU 流体模拟,**照 WE 本体 effects/cursorripple 源码移植**。
/// 力场用 RGBA8 四通道打包(R=右 G=下 B=左 A=上 的力分量),在两张 512×512 纹理上 ping-pong:
///  1) apply_force:沿光标「上一帧→这一帧」的运动射线注入力。
///  2) simulate_force:每格从邻居取最大力并传播,带衰减 + 边界/遮罩反射(忠实照 WE:12 项跨通道
///     耦合 + ×1/3;过强时用 rippleStrength 乘子压回,默认 1 = 忠实 WE,见 ripple_sim 注释)。
/// combine(按力场方向折射底图)在主着色器里做——本类只产出力场纹理给主着色器采样。
final class CursorRippleSim {
    private let device: MTLDevice
    private let size = 512
    private var bufA: MTLTexture     // ping
    private var bufB: MTLTexture     // pong
    private var applyPipeline: MTLRenderPipelineState!
    private var simPipeline: MTLRenderPipelineState!
    private let sampler: MTLSamplerState
    private let quad: MTLBuffer
    // 审计修复 #3:清屏复用的命令队列(避免每次新建,且便于 waitUntilCompleted 与首次 step 排序)。
    private let clearQueue: MTLCommandQueue

    /// 当前可供 combine 采样的力场纹理(最近一次 simulate 的输出)。
    private(set) var fieldTexture: MTLTexture

    // 光标状态(UV [0,1],y 同屏幕向上)。
    private var pointer = SIMD2<Float>(0.5, 0.5)
    private var pointerLast = SIMD2<Float>(0.5, 0.5)
    /// 折射强度(combine 用),来自材质 ripplestrength。
    var rippleStrength: Float = 1.0
    var rippleScale: Float = 1.0
    var rippleSpeed: Float = 1.0
    var rippleDecay: Float = 1.0
    /// 碰撞遮罩(cursorripple 的 simulate_force pass 的 textures[1],如 cursorripple_simulate_force_mask):
    /// 白=陆地(力场归零)、黑=水面(涟漪传播)。缺它则力场全屏传播 → 鼠标划过草地也起波(3680422061)。
    /// 照 WE simulate_force.frag #if MASK:`force *= 1-step(0.5, mask.r)`。
    var collisionMask: MTLTexture?

    init?(device: MTLDevice, sampler: MTLSamplerState, quad: MTLBuffer) {
        self.device = device
        self.sampler = sampler
        self.quad = quad
        guard let q = device.makeCommandQueue() else { return nil }
        self.clearQueue = q
        let sz = 512
        func makeRT() -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: sz, height: sz, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            return device.makeTexture(descriptor: d)
        }
        guard let a = makeRT(), let b = makeRT() else { return nil }
        bufA = a; bufB = b; fieldTexture = a
        do { try buildPipelines() } catch { Log.write("CursorRippleSim: pipeline fail \(error)"); return nil }
        // 清空两张缓冲(初始无力)。
        // 审计修复 #3:用一个命令缓冲清两张图并 waitUntilCompleted,确保清屏在 init 返回前完成 →
        // 必然先于首次 step()(step 由渲染循环在 init 之后才提交),消除开场竞态/残留。
        clear(a, b)
    }

    /// 喂当前光标位置(UV [0,1])。每帧调。
    func setPointer(_ uv: SIMD2<Float>) {
        pointerLast = pointer
        pointer = uv
    }

    /// 跑一帧模拟:apply_force(bufA←bufB) → simulate_force(bufB←bufA)。fieldTexture=bufB。
    func step(commandBuffer cmd: MTLCommandBuffer, frametime: Float) {
        // pass1: apply force,读 bufB 写 bufA
        encodeApply(cmd, src: bufB, dst: bufA, frametime: frametime)
        // pass2: simulate,读 bufA 写 bufB
        encodeSim(cmd, src: bufA, dst: bufB, frametime: frametime)
        fieldTexture = bufB
    }

    // MARK: - passes

    private func encodeApply(_ cmd: MTLCommandBuffer, src: MTLTexture, dst: MTLTexture, frametime: Float) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = dst
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.setRenderPipelineState(applyPipeline)
        enc.setVertexBuffer(quad, offset: 0, index: 0)
        var u = ApplyU(pointer: pointer, pointerLast: pointerLast,
                       frametime: frametime, rippleScale: rippleScale, texW: Float(size), texH: Float(size))
        enc.setVertexBytes(&u, length: MemoryLayout<ApplyU>.stride, index: 1)
        enc.setFragmentBytes(&u, length: MemoryLayout<ApplyU>.stride, index: 0)
        enc.setFragmentTexture(src, index: 0)
        enc.setFragmentSamplerState(sampler, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
    }

    private func encodeSim(_ cmd: MTLCommandBuffer, src: MTLTexture, dst: MTLTexture, frametime: Float) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = dst
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.setRenderPipelineState(simPipeline)
        enc.setVertexBuffer(quad, offset: 0, index: 0)
        var u = SimU(frametime: frametime, rippleSpeed: rippleSpeed, rippleDecay: rippleDecay,
                     texW: Float(size), texH: Float(size), hasMask: collisionMask != nil ? 1 : 0,
                     rippleStrength: rippleStrength)
        enc.setFragmentBytes(&u, length: MemoryLayout<SimU>.stride, index: 0)
        enc.setFragmentTexture(src, index: 0)
        enc.setFragmentTexture(collisionMask ?? src, index: 1)   // 碰撞遮罩(无则占位 src,hasMask=0 时不采)
        enc.setFragmentSamplerState(sampler, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
    }

    // 审计修复 #3:在同一个命令缓冲里清掉两张缓冲,并 waitUntilCompleted —— 保证清屏在
    // init 返回(即首次 step 提交)之前就已对 GPU 生效,不再用一次性新建的游离队列异步提交。
    private func clear(_ textures: MTLTexture...) {
        guard let cmd = clearQueue.makeCommandBuffer() else { return }
        for tex in textures {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = tex
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            pass.colorAttachments[0].storeAction = .store
            guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { continue }
            enc.endEncoding()
        }
        cmd.commit()
        cmd.waitUntilCompleted()   // 清屏先于首次 step 生效
    }

    private struct ApplyU {
        var pointer: SIMD2<Float>; var pointerLast: SIMD2<Float>
        var frametime: Float; var rippleScale: Float; var texW: Float; var texH: Float
    }
    private struct SimU {
        var frametime: Float; var rippleSpeed: Float; var rippleDecay: Float
        var texW: Float; var texH: Float; var hasMask: Int32 = 0
        // 修复 #3:把 WE 真值的 12 项跨通道组合改回后,作用在最终 force 上的可调强度系数。
        // 复用材质 ripplestrength(combine 折射强度同源)——默认 1 即忠实 WE,过强时调小压回。
        var rippleStrength: Float = 1.0
    }

    private func buildPipelines() throws {
        let lib = try device.makeLibrary(source: Self.shaderSource, options: nil)
        func make(_ vfn: String, _ ffn: String) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: vfn)
            d.fragmentFunction = lib.makeFunction(name: ffn)
            d.colorAttachments[0].pixelFormat = .rgba8Unorm
            return try device.makeRenderPipelineState(descriptor: d)
        }
        applyPipeline = try make("ripple_quad_vertex", "ripple_apply")
        simPipeline = try make("ripple_quad_vertex", "ripple_sim")
    }

    // 移植自 WE cursorripple_apply_force / simulate_force。力场 RGBA = (右,下,左,上) 力分量。
    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VOut { float4 position [[position]]; float2 uv; };
    struct ApplyU {
        float2 pointer; float2 pointerLast;
        float frametime; float rippleScale; float texW; float texH;
    };
    struct SimU { float frametime; float rippleSpeed; float rippleDecay; float texW; float texH; int hasMask; float rippleStrength; };

    vertex VOut ripple_quad_vertex(uint vid [[vertex_id]],
                                   const device float4* verts [[buffer(0)]]) {
        float4 v = verts[vid];
        VOut o;
        o.position = float4(v.xy * 2.0, 0, 1);   // 单位 quad [-0.5,0.5]→NDC[-1,1]
        o.uv = v.zw;
        return o;
    }

    // pass1: 沿光标运动射线注入力(移植 apply_force.frag 的核心)。
    fragment float4 ripple_apply(VOut in [[stage_in]],
                                 texture2d<float> src [[texture(0)]],
                                 sampler smp [[sampler(0)]],
                                 constant ApplyU& u [[buffer(0)]]) {
        float2 texSource = in.uv;
        float4 albedo = src.sample(smp, texSource);

        // 光标 UV(y 翻转到纹理空间)。
        float2 p = float2(u.pointer.x, 1.0 - u.pointer.y);
        float2 pLast = float2(u.pointerLast.x, 1.0 - u.pointerLast.y);

        // 点到「上一帧→这一帧」线段的投影,求最近点 posOnLine + 射线掩码。
        float2 lDelta = p - pLast;
        float2 texDelta = texSource - pLast;
        float distLDelta = length(lDelta) + 0.0001;
        lDelta /= distLDelta;
        float distOnLine = dot(lDelta, texDelta);
        float rayMask = max(step(0.0, distOnLine) * step(distOnLine, distLDelta), step(distLDelta, 0.1));
        distOnLine = saturate(distOnLine / distLDelta) * distLDelta;
        float2 posOnLine = pLast + lDelta * distOnLine;

        // 到射线的距离 → 半径内注入。WE 用 v_PointDelta.y=60/scale 作半径系数。
        float radiusCoef = 60.0 / max(0.0001, u.rippleScale);
        float aspect = u.texH / u.texW;
        float2 d = (texSource - posOnLine) * float2(radiusCoef * aspect, radiusCoef);
        float pointerDist = saturate(1.0 - length(d));
        pointerDist *= rayMask;

        float timeAmt = min(1.0/30.0, u.frametime) / 0.02;
        float moveAmt = length(u.pointer - u.pointerLast) * 100.0;
        float inputStrength = pointerDist * timeAmt * moveAmt;

        float2 impulse = clamp(d, -1.0, 1.0);
        float4 add = float4(
            step(0.0, impulse.x) * impulse.x * inputStrength,
            step(0.0, impulse.y) * impulse.y * inputStrength,
            step(impulse.x, 0.0) * -impulse.x * inputStrength,
            step(impulse.y, 0.0) * -impulse.y * inputStrength
        );
        return albedo + add;
    }

    // pass2: 力场传播 + 衰减(移植 simulate_force.frag,REFLECTION 简化为边界反射)。
    static inline float4 sampleF(float4 a, float4 b, float4 c) { return max(a, max(b, c)); }

    fragment float4 ripple_sim(VOut in [[stage_in]],
                               texture2d<float> src [[texture(0)]],
                               texture2d<float> collisionMask [[texture(1)]],
                               sampler smp [[sampler(0)]],
                               constant SimU& u [[buffer(0)]]) {
        float2 coords = in.uv;
        float2 simTexel = 1.0 / float2(u.texW, u.texH);
        float2 rippleOffset = simTexel * 100.0 * u.rippleSpeed * min(1.0/30.0, u.frametime);
        float2 inside = rippleOffset * 1.61;
        float2 outside = rippleOffset;

        // 边界反射(REFLECTION 默认开)。
        float reflectUp = step(1.0 - simTexel.y, coords.y);
        float reflectDown = step(coords.y, simTexel.y);
        float reflectLeft = step(1.0 - simTexel.x, coords.x);
        float reflectRight = step(coords.x, simTexel.x);

        float4 uc = src.sample(smp, coords + float2(0, -inside.y));
        float4 u00 = src.sample(smp, coords + float2(-outside.x, -outside.y));
        float4 u10 = src.sample(smp, coords + float2(outside.x, -outside.y));
        float4 dc = src.sample(smp, coords + float2(0, inside.y));
        float4 d01 = src.sample(smp, coords + float2(-outside.x, outside.y));
        float4 d11 = src.sample(smp, coords + float2(outside.x, outside.y));
        float4 lc = src.sample(smp, coords + float2(-inside.x, 0));
        float4 l00 = src.sample(smp, coords + float2(-outside.x, -outside.y));
        float4 l01 = src.sample(smp, coords + float2(-outside.x, outside.y));
        float4 rc = src.sample(smp, coords + float2(inside.x, 0));
        float4 r10 = src.sample(smp, coords + float2(outside.x, -outside.y));
        float4 r11 = src.sample(smp, coords + float2(outside.x, outside.y));

        float4 up = sampleF(uc, u00, u10);
        float4 down = sampleF(dc, d01, d11);
        float4 left = sampleF(lc, l00, l01);
        float4 right = sampleF(rc, r10, r11);

        // 修复 #3:改回 WE simulate_force 真值——12 项跨通道耦合 + 整体 ×1/3。
        // 逐行照 effects__cursorripple_simulate_force__MASK-1...frag.metal(:93-115):
        //   force.xzy += up.xzy;    // up   贡献 .x .z .y(独缺 .w)
        //   force.xzw += down.xzw;  // down 贡献 .x .z .w(独缺 .y)
        //   force.xyw += left.xyw;  // left 贡献 .x .y .w(独缺 .z)
        //   force.zyw += right.zyw; // right贡献 .z .y .w(独缺 .x)
        //   force *= 1/3;           // 四方向累加后整体缩放(在反射块之前)
        // 每方向各吸三个通道,四方向叠加后每通道恰被三方向写入,故 ×1/3 = 均值。
        float4 force = float4(0,0,0,0);
        force.xzy += up.xzy;
        force.xzw += down.xzw;
        force.xyw += left.xyw;
        force.zyw += right.zyw;
        force *= 0.33333334;
        // ⚠ 绝不在此乘 rippleStrength:力场是逐帧 ping-pong 反馈的持久量,任何 <1 的常数乘子
        // 会**每帧复合**(第 N 帧 ∝ k^N)→ 几帧内力场归零(表现为"完全不涟漪");>1 则爆。
        // WE 里 g_RippleStrength **只用在 combine 折射**(scene_fragment 的 off=dir×-0.1×ripplestrength),
        // sim 力场保持忠实 WE。强度调节归 combine,不归 sim。

        // 碰撞遮罩门控(照 WE simulate_force.frag #if MASK):mask 白处(陆地/草地)力场归零、
        // 黑处(水面)保留 → 涟漪只在水里传播,鼠标划过草地不起波。无 mask 时 hasMask=0 跳过。
        if (u.hasMask != 0) {
            float invMaskCenter = 1.0 - step(0.5, collisionMask.sample(smp, coords).r);
            force *= invMaskCenter;
        }

        // 反射:边界处把对向分量翻折。
        float4 fc = force;
        force.y = mix(force.y, fc.w, reflectDown);
        force.w = mix(force.w, fc.y, reflectUp);
        force.x = mix(force.x, fc.z, reflectRight);
        force.z = mix(force.z, fc.x, reflectLeft);

        float decay = 1.5;
        float drop = max(1.001/255.0, decay/255.0 * (u.frametime/0.02) * u.rippleDecay);
        force -= drop;
        return max(force, float4(0,0,0,0));
    }
    """
}
