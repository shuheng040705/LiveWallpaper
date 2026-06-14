import Metal
import MetalKit
import simd
import Foundation

/// 多 pass 特效合成器:消费 Tools/we_build_effects.py 生成的 WEEffects.json manifest +
/// 转译出的 MSL,把 WE 的**真实**特效着色器跑在 Metal 上,替代手写近似。
///
/// 每个 effect 一条 pass 链(照 effect.json):图层先渲到纹理,逐 pass 跑转译 shader,
/// uniform 喂 pkg 真实参数(g_Speed←"speed" 等)+ 引擎值(g_Time/MVP/分辨率),
/// 命名 FBO(previous / _rt_*)做 ping-pong,最后输出。
final class WEEffectChain {

    // MARK: - Manifest 模型(对应 WEEffects.json)
    // array/arrayStride:数组 uniform(如 g_AudioSpectrum16Left[16])。std140 下每个 float 元素
    // 占一个 vec4 槽(16B),spirv-cross MSL 用 float4[N] 表示、值落在每元素的 .x。Swift 侧按
    // offset + i*arrayStride 写第 i 个元素的 .x。非数组时为 nil。
    struct UniformVar: Codable { let name: String; let offset: Int; let type: String; let array: Int?; let arrayStride: Int? }
    // texIndex/sampIndex = MSL 真实 [[texture(N)]]/[[sampler(N)]] 索引(spirv-cross 自排,≠SPIR-V binding)。
    struct SamplerVar: Codable { let name: String; let texIndex: Int; let sampIndex: Int }
    struct StageDef: Codable { let metal: String; let entry: String; let uniforms: [UniformVar]; let samplers: [SamplerVar]; let ubuf: Int }
    // 审计修复 #2:解码 manifest bind 项的 conditions(如 {'index':2,'conditions':[{'LIGHTING':1}]})。
    // conditions 是「条件组」列表,每组为 combo名→期望值(整数)的字典;**全部组都满足**(AND)
    // 才绑该纹理。值用 Int 解码(manifest 里 LIGHTING:1 / RENDERING:3 都是整数),与 run() 的 combo
    // 归一化字符串比较时按整数语义对齐。decodeIfPresent 容错:无 conditions 的 bind(全库绝大多数)→ nil,
    // 行为与改动前完全一致。
    struct Bind: Codable {
        let name: String
        let index: Int
        let conditions: [[String: Int]]?
        enum CodingKeys: String, CodingKey { case name, index, conditions }
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            index = try c.decode(Int.self, forKey: .index)
            conditions = try c.decodeIfPresent([[String: Int]].self, forKey: .conditions)
        }
    }
    struct UniformMeta: Codable { let material: String?; let `default`: AnyCodable?; let combo: String? }
    struct PassDef: Codable {
        let shader: String?      // 命令 pass(copy/swap)无 shader → 可选,容错解码(否则整 manifest 解码崩)
        let target: String?
        let bind: [Bind]
        let uniformMeta: [String: UniformMeta]
        let vert: StageDef?
        let frag: StageDef?
        let targetScale: Int?    // 目标 FBO 降采样分母(来自 effect.json fbos[].scale;无则 1)
        let command: String?     // 命令 pass:copy(motionblur 帧间拷贝)/swap(fluidsim 乒乓)等,无 vert/frag
        let copy: Bool?
        let source: String?
        // R5:目标 FBO 的像素格式字符串(effect.json fbos[].format;无 = 默认 → .bgra8Unorm)与跨帧持久标记
        // (fbos[].unique;true = 累积缓冲,引擎不逐帧 clear)。fluidsimulation 速度/压力场需 rg1616f/r16f 浮点
        // 精度(8-bit 量化出色带);motionblur 累积缓冲 unique(逐帧重建会丢累积)。绝大多数 pass 二者皆 nil(现状)。
        let targetFormat: String?
        let targetUnique: Bool?
        // 自定义解码:命令 pass 缺 shader/uniformMeta/bind,用 decodeIfPresent + 默认值容错,
        // 否则 JSONDecoder 对整个 manifest 抛错 → 所有特效全丢(连 bloom/filmgrain 都没了)。
        // 命令 pass 解出后无 vert/frag,run() 的 `guard let vstage=p.vert...` 会安全跳过。
        enum CodingKeys: String, CodingKey {
            case shader, target, bind, uniformMeta, vert, frag, targetScale, command, copy, source, targetFormat, targetUnique
        }
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            shader      = try c.decodeIfPresent(String.self, forKey: .shader)
            target      = try c.decodeIfPresent(String.self, forKey: .target)
            bind        = try c.decodeIfPresent([Bind].self, forKey: .bind) ?? []
            uniformMeta = try c.decodeIfPresent([String: UniformMeta].self, forKey: .uniformMeta) ?? [:]
            vert        = try c.decodeIfPresent(StageDef.self, forKey: .vert)
            frag        = try c.decodeIfPresent(StageDef.self, forKey: .frag)
            targetScale = try c.decodeIfPresent(Int.self, forKey: .targetScale)
            command     = try c.decodeIfPresent(String.self, forKey: .command)
            copy        = try c.decodeIfPresent(Bool.self, forKey: .copy)
            source      = try c.decodeIfPresent(String.self, forKey: .source)
            targetFormat = try c.decodeIfPresent(String.self, forKey: .targetFormat)
            targetUnique = try c.decodeIfPresent(Bool.self, forKey: .targetUnique)
        }
    }
    struct Variant: Codable { let combos: [String: String]; let passes: [PassDef] }
    struct EffectDef: Codable { let variants: [Variant] }

    private let device: MTLDevice
    // material-key 查找大小写不敏感开关(缓存避免热路径每帧查 env)。修「bloom 过曝整人」类 bug:
    //   部分转译特效 uniformMeta.material 用大写(bloom 2822917890 的 "Threshold"),pkg constantshadervalues
    //   小写("threshold")→ 精确查找 miss → 回退 WE 注解默认(threshold 0.1)→ bright-pass 把整个角色纳入泛光。
    //   全库验证 0 例仅大小写不同的 key 碰撞,且仅精确 miss 时才走小写兜底=原本命中零变化。WP_NO_CASE_INSENSITIVE_PARAM 退。
    private let caseInsensitiveParams = ProcessInfo.processInfo.environment["WP_NO_CASE_INSENSITIVE_PARAM"] == nil
    private let sampler: MTLSamplerState          // clamp + linear(默认/兜底)
    private let samplerRepeat: MTLSamplerState    // repeat + linear:WE 默认 wrap(无 ClampUVs flag);平铺噪声等
    private let samplerNearest: MTLSamplerState        // clamp  + nearest(NoInterpolation + ClampUVs)
    private let samplerRepeatNearest: MTLSamplerState  // repeat + nearest(NoInterpolation,无 ClampUVs)
    private let manifest: [String: EffectDef]
    /// basename(最后一段) → manifest 实际 key。用于 workshop 副本特效回退:WE 上传时把特效复制到
    /// `workshop/<id>/…/<name>` 路径,manifest 里同名特效的 key 各带不同 workshop 前缀(甚至双层嵌套,
    /// 如 audio_bars 的 `workshop/3299008209/workshop/2084198056/Simple_Audio_Bars`)。同 basename = 同一
    /// 特效副本(shader 相同),按 basename 索引到任意已转译的同名 key → 一次性识别全库所有副本(尤其音频条)。
    /// 取最短路径 key(最接近"通用"),排除 material/ 前缀(材质另走路径)。
    private let basenameIndex: [String: String]

    /// 按 WE 纹理 flags 选采样器:ClampUVs→clamp 否则 repeat;NoInterpolation→nearest 否则 linear。
    /// flags=nil(无真实 flags 可用)→ 保守用 clamp+linear(改动前默认),不破坏现有渲染。
    private func samplerFor(_ flags: TexFlags?) -> MTLSamplerState {
        guard let f = flags else { return sampler }
        switch (f.clamp, f.nearest) {
        case (true, false):  return sampler
        case (false, false): return samplerRepeat
        case (true, true):   return samplerNearest
        case (false, true):  return samplerRepeatNearest
        }
    }
    private let mslDir: URL

    private var libCache: [String: MTLLibrary] = [:]          // metal 文件 → library
    private var pipeCache: [String: MTLRenderPipelineState] = [:]
    private var pipeFailed: Set<String> = []                 // 建管线失败的 key:负缓存,避免每帧重试+刷日志
    private var diagLogged: Set<String> = []                 // 诊断:无变体/无manifest 每组合只打一行
    private var comboKeyFallbackLogged: Set<String> = []     // 诊断:combo 感知 key 回退(副本缺 MASK 变体→通用)每次只打一行
    private var rtPool: [String: MTLTexture] = [:]            // 命名 FBO
    private let quadBuf: MTLBuffer                            // 全屏 quad: pos.xyz + uv.xy
    private let whiteTex: MTLTexture                          // 1x1 白:兜底
    private var utilCache: [String: (tex: MTLTexture, flags: TexFlags?)] = [:]   // WE util/* 默认贴图(noise/white/black)+ 真实 flags
    private lazy var loader = MTKTextureLoader(device: device)

    /// 全屏 quad(triangle strip):NDC 位置 + uv(v 翻转,纹理 v=0 在顶)。
    private static let quadVerts: [Float] = [
        -1, -1, 0,  0, 1,
         1, -1, 0,  1, 1,
        -1,  1, 0,  0, 0,
         1,  1, 0,  1, 0,
    ]

    // composelayer 复制 pass(忠实移植 assets/shaders/composelayer.vert+.frag):把场景主 FBO
    // (_rt_FullFrameBuffer)按**该层屏幕投影位置**采样进该层自有 [0,1] FBO,等价 lwe CImage 的首 copy pass
    // (CImage.cpp:330-348 passthrough 几何 + 391-392 m_modelViewProjectionCopy=screen mvp;
    //  composelayer.frag:texCoord=v_ScreenCoord.xy/v_ScreenCoord.z*0.5+0.5 采样 g_Texture0)。
    // 几何:gl_Position 用单位 quad 顶点(a_TexCoord*2-1,填满 FBO),采样 UV = 该层 quad 顶点经 layer mvp
    // 投到屏幕的归一化坐标(下方 makeFootprintVerts 预算好,作 a_TexCoord 传入)。
    private static let copyShaderSrc = """
    #include <metal_stdlib>
    using namespace metal;
    struct VIn  { float3 pos [[attribute(0)]]; float2 uv [[attribute(1)]]; };
    struct VOut { float4 position [[position]]; float2 uv; };
    vertex VOut copy_vertex(VIn in [[stage_in]]) {
        VOut o; o.position = float4(in.pos, 1.0); o.uv = in.uv; return o;
    }
    fragment float4 copy_fragment(VOut in [[stage_in]],
                                  texture2d<float> g_Texture0 [[texture(0)]],
                                  sampler smp [[sampler(0)]]) {
        return g_Texture0.sample(smp, in.uv);
    }
    """
    private lazy var copyPipeline: MTLRenderPipelineState? = {
        guard let lib = try? device.makeLibrary(source: Self.copyShaderSrc, options: nil),
              let vfn = lib.makeFunction(name: "copy_vertex"),
              let ffn = lib.makeFunction(name: "copy_fragment") else { return nil }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = vfn; d.fragmentFunction = ffn
        d.colorAttachments[0].pixelFormat = .bgra8Unorm
        let vd = MTLVertexDescriptor()
        vd.attributes[0].format = .float3; vd.attributes[0].offset = 0;  vd.attributes[0].bufferIndex = 1
        vd.attributes[1].format = .float2; vd.attributes[1].offset = 12; vd.attributes[1].bufferIndex = 1
        vd.layouts[1].stride = 20
        d.vertexDescriptor = vd
        return try? device.makeRenderPipelineState(descriptor: d)
    }()

    // ───────────────────────────────────────────────────────────────────────────
    // 忠实 bloom(workshop/2822917890,WE 内建 "Bloom" 特效)——修「开 bloom 冲白皮肤」。
    //
    // 根因(从 pkg shader 逐 pass + 转译 .metal 对照):tools/generated 里 2822917890 的 4 个转译
    //   .metal(light_map/blur_gaussian/apply)是从**另一(更早)版本**的 bloom shader 转译来的,
    //   与本壁纸 pkg 内 shaders/workshop/2822917890/effects/*.frag **算法不同**,且四处放大:
    //   ① light_map(转译版):luma=dot(pow(color,gamma),1) 二值阈值后把**整块亮色原样**纳入(无
    //      `saturate(avg-threshold)` 的「只取超出阈值的部分」),且**漏乘** `strength*radius*0.25`,
    //      改成乘 weight(=4 tap 通道和,数值很大)再 /4 → 亮皮肤全幅能量都进辉光。
    //   ② blur_gaussian(转译版):`albedo = albedo * u_strength / divisor`——**多乘了一次 strength**
    //      (1.48);真 pkg blur 只做归一化均值 `albedo /= 2*iter+1`,不放大。两道 blur → 1.48² 再放大。
    //   ③ apply(转译版):只取 **1 tap**、且**漏乘 0.4** 衰减;真 pkg apply 取 5 tap 求和 `* 0.4 * tint`。
    //   合计:辉光被放大到远超 WE → additive blend 把亮皮肤区叠成泛白。仅调 threshold/gamma 治标不治本。
    //
    // 修法:用本内联 MSL **忠实重写** pkg 的 light_map / blur_gaussian / apply 三 shader(算法/缩放
    //   逐行对齐 pkg .frag),按单尺度 /4 近似 pyramid(与原 4-pass manifest 同结构,只是数学正确):
    //     light_map → blurH → blurV → apply。参数取 pkg constantshadervalues 真值(threshold/gamma/
    //     strength/radius/Tint/opacity),缺则 WE 注解默认。不自创降强度。
    //   WP_NO_BLOOM_FIX=1 退回原转译 .metal 链(A/B 对照)。
    private static let bloomShaderSrc = """
    #include <metal_stdlib>
    using namespace metal;
    struct VIn  { float3 pos [[attribute(0)]]; float2 uv [[attribute(1)]]; };
    struct VOut { float4 position [[position]]; float2 uv; };
    vertex VOut bloom_vertex(VIn in [[stage_in]]) {
        VOut o; o.position = float4(in.pos, 1.0); o.uv = in.uv; return o;
    }
    // light_map(对应 pkg light_map.frag,MODE=0 Brightness):4 个邻域 tap 求(带 alpha 权重的)均值,
    //   saturate(avg - threshold) 只保留超出阈值的部分,pow(·, gamma) 陡峭衰减,× strength*radius*0.25。
    //   texel = 1/分辨率(对齐 pkg light_map.vert 的 offsets=1/g_Texture0Resolution)。
    struct LMArgs { float strength; float gamma; float threshold; float radius; float texelX; float texelY; };
    fragment float4 bloom_lightmap(VOut in [[stage_in]],
                                   constant LMArgs& a [[buffer(0)]],
                                   texture2d<float> g_Texture0 [[texture(0)]],
                                   sampler smp [[sampler(0)]]) {
        float2 off = float2(a.texelX, a.texelY);
        float3 lightMap = float3(0.0);
        float weight = 0.0;
        // 与 pkg 一致:strength 太小则不产生辉光。
        if (a.strength > 0.001) {
            float2 taps[4] = {
                in.uv - off,
                in.uv + float2(off.x, -off.y),
                in.uv + float2(-off.x, off.y),
                in.uv + off,
            };
            for (int i = 0; i < 4; ++i) {
                float4 s = g_Texture0.sample(smp, taps[i]);
                lightMap += s.rgb * s.a;
                weight   += s.a;
            }
            float3 avg = (weight > 0.0001) ? (lightMap / weight) : float3(0.0);
            lightMap = pow(saturate(avg - float3(a.threshold)), float3(a.gamma));
        }
        return float4(lightMap * a.strength * a.radius * 0.25, 1.0);
    }
    // 可分离高斯模糊(对应 pkg blur_gaussian.frag,LOW quality iterations=2):±2 tap 求**算术均值**,
    //   绝不乘 strength。step = (radius*2)*1.5*texel(对齐 pkg blur_gaussian.vert v_SizeMultiplier,
    //   ANAMORPHIC=0 → aRatio=1)。vertical=0 横向、=1 纵向。
    struct BlurArgs { float radius; float texelX; float texelY; float vertical; };
    fragment float4 bloom_blur(VOut in [[stage_in]],
                               constant BlurArgs& a [[buffer(0)]],
                               texture2d<float> g_Texture0 [[texture(0)]],
                               sampler smp [[sampler(0)]]) {
        const int iters = 2;
        float2 sm = (a.vertical > 0.5)
            ? float2(0.0, (a.radius + a.radius) * 1.5 * a.texelY)
            : float2((a.radius + a.radius) * 1.5 * a.texelX, 0.0);
        float3 acc = float3(0.0);
        for (int i = -iters; i <= iters; ++i) {
            acc += g_Texture0.sample(smp, in.uv + sm * float(i)).rgb;
        }
        acc /= float(iters + iters) + 1.0;
        return float4(acc, 1.0);
    }
    // apply(对应 pkg apply.frag,BLENDMODE=31 additive bloom):5 tap 求和 × 0.4 × tint,
    //   结果 = base + bloom*(alpha)。stepSize = 1/分辨率(对齐 pkg apply.vert v_StepSize)。
    struct ApplyArgs { float alpha; float3 tint; float stepX; float stepY; };
    fragment float4 bloom_apply(VOut in [[stage_in]],
                                constant ApplyArgs& a [[buffer(0)]],
                                texture2d<float> g_Bloom [[texture(0)]],
                                texture2d<float> g_Base  [[texture(1)]],
                                sampler smp [[sampler(0)]]) {
        float4 base = g_Base.sample(smp, in.uv);
        float3 outc = base.rgb;
        if (a.alpha > 0.001) {
            float4 ss = float4(-a.stepX, -a.stepY, a.stepX, a.stepY);
            float3 b = g_Bloom.sample(smp, in.uv).rgb;
            b += g_Bloom.sample(smp, in.uv + ss.xy).rgb;
            b += g_Bloom.sample(smp, in.uv + ss.zy).rgb;
            b += g_Bloom.sample(smp, in.uv + ss.xw).rgb;
            b += g_Bloom.sample(smp, in.uv + ss.zw).rgb;
            b *= 0.4 * a.tint;
            outc = base.rgb + b * a.alpha;   // ApplyBlending(31) = A + B*opacity(additive)
        }
        return float4(outc, base.a);
    }
    """
    private lazy var bloomPipelines: (lightmap: MTLRenderPipelineState,
                                      blur: MTLRenderPipelineState,
                                      apply: MTLRenderPipelineState)? = {
        guard let lib = try? device.makeLibrary(source: Self.bloomShaderSrc, options: nil),
              let vfn = lib.makeFunction(name: "bloom_vertex") else { return nil }
        func make(_ frag: String) -> MTLRenderPipelineState? {
            guard let ffn = lib.makeFunction(name: frag) else { return nil }
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = vfn; d.fragmentFunction = ffn
            d.colorAttachments[0].pixelFormat = .bgra8Unorm
            let vd = MTLVertexDescriptor()
            vd.attributes[0].format = .float3; vd.attributes[0].offset = 0;  vd.attributes[0].bufferIndex = 1
            vd.attributes[1].format = .float2; vd.attributes[1].offset = 12; vd.attributes[1].bufferIndex = 1
            vd.layouts[1].stride = 20
            d.vertexDescriptor = vd
            return try? device.makeRenderPipelineState(descriptor: d)
        }
        guard let lm = make("bloom_lightmap"), let bl = make("bloom_blur"), let ap = make("bloom_apply") else { return nil }
        return (lm, bl, ap)
    }()

    /// 忠实 bloom 链(单尺度 /4 近似)。input = 该层(已 composelayer copy 进层空间的)纹理;返回叠加辉光后的层纹理。
    /// 参数取 pkg 合并版 pkgParams(threshold/gamma/strength/radius/Tint/opacity,大小写不敏感),缺则 WE 默认。
    private func runFaithfulBloom(input: MTLTexture, pkgParams: [String: Any], commandBuffer cmd: MTLCommandBuffer) -> MTLTexture? {
        guard let pl = bloomPipelines else { return nil }
        // 大小写不敏感取参(pkg "Threshold"/"Gamma"/"Tint" 等);缺则 WE shader 注解默认。
        func p(_ key: String, _ def: Float) -> Float {
            for (k, v) in pkgParams where k.lowercased() == key.lowercased() {
                let f = Self.parseFloats(v); if let first = f.first { return first }
            }
            return def
        }
        func tint() -> SIMD3<Float> {
            for (k, v) in pkgParams where k.lowercased() == "tint" {
                let f = Self.parseFloats(v); if f.count >= 3 { return SIMD3(f[0], f[1], f[2]) }
            }
            return SIMD3(1, 1, 1)
        }
        let strength = p("strength", 1.0)   // pkg light_map default 注解 = 1
        let gamma    = p("gamma", 2.4)
        let threshold = p("threshold", 0.1)
        let radius   = p("radius", 4.0)
        let alpha    = p("opacity", 1.0)
        let tnt = tint()
        let fullW = input.width, fullH = input.height
        // /4 尺度的辉光缓冲(对齐 manifest targetScale=4,= pyramid 中间尺度的代表)。
        let bw = max(1, fullW / 4), bh = max(1, fullH / 4)
        guard let buf1 = renderTarget("_bloomfix_b1", width: bw, height: bh),
              let buf2 = renderTarget("_bloomfix_b2", width: bw, height: bh),
              let outTex = makeTarget(width: fullW, height: fullH) else { return nil }

        func encode(_ ps: MTLRenderPipelineState, target: MTLTexture,
                    tex0: MTLTexture, tex1: MTLTexture? = nil,
                    args: UnsafeRawPointer, argLen: Int) {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
            enc.setRenderPipelineState(ps)
            enc.setVertexBuffer(quadBuf, offset: 0, index: 1)
            enc.setFragmentBytes(args, length: argLen, index: 0)
            enc.setFragmentTexture(tex0, index: 0)
            enc.setFragmentSamplerState(sampler, index: 0)
            if let t1 = tex1 { enc.setFragmentTexture(t1, index: 1); enc.setFragmentSamplerState(sampler, index: 1) }
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            enc.endEncoding()
        }

        // pass0 light_map:input(全尺寸)→ buf1(/4)。texel 用 buf1 的尺寸(采样输入时邻域偏移按目标格点)。
        var lm = (Float(strength), Float(gamma), Float(threshold), Float(radius),
                  Float(1.0 / Float(max(1, bw))), Float(1.0 / Float(max(1, bh))))
        withUnsafeBytes(of: &lm) { encode(pl.lightmap, target: buf1, tex0: input, args: $0.baseAddress!, argLen: $0.count) }
        // pass1 blurH:buf1 → buf2。pass2 blurV:buf2 → buf1。texel = /4 缓冲尺寸。
        let texX = Float(1.0 / Float(max(1, bw))), texY = Float(1.0 / Float(max(1, bh)))
        var bH = (Float(radius), texX, texY, Float(0.0))
        withUnsafeBytes(of: &bH) { encode(pl.blur, target: buf2, tex0: buf1, args: $0.baseAddress!, argLen: $0.count) }
        var bV = (Float(radius), texX, texY, Float(1.0))
        withUnsafeBytes(of: &bV) { encode(pl.blur, target: buf1, tex0: buf2, args: $0.baseAddress!, argLen: $0.count) }
        // pass3 apply:buf1(辉光)+ input(底)→ outTex(全尺寸)。stepSize = 1/辉光缓冲尺寸(5-tap 邻域)。
        // ApplyArgs std140:float alpha; float3 tint(16B 对齐)→ tint 在 offset 16;stepX/Y 在 28/32。
        var ap = (Float(alpha), Float(0), Float(0), Float(0),   // alpha + 3 pad(对齐 float3)
                  tnt.x, tnt.y, tnt.z,                          // tint(offset 16)
                  texX, texY)                                   // stepX/Y(offset 28/32)
        withUnsafeBytes(of: &ap) { encode(pl.apply, target: outTex, tex0: buf1, tex1: input, args: $0.baseAddress!, argLen: $0.count) }
        return outTex
    }

    /// 该层屏幕投影 footprint 的复制 quad 顶点(pos.xyz 单位 NDC[-1,1] 填满 FBO + uv=屏幕投影 UV)。
    /// 顶点序/UV 与 quadVerts 一致(triangle strip 4 顶点),pos 不变;uv 由单位 quad 角点经 mvp 投到屏幕得到。
    /// 单位 quad 角点取自 quadVerts 的 uv:uv(u,v) ↔ 单位 quad 位置 (u-0.5, 0.5-v),与 encode 末 pass
    /// (SceneRenderEngine quadBuffer 同样 uv(0,0)↔pos(-0.5,0.5))1:1 对齐 → 复制区与贴回区精确重合。
    /// 屏幕 UV:ndc=clip.xy/clip.w;u=ndc.x*0.5+0.5,v=ndc.y*(-0.5)+0.5(场景 FBO 纹理 v=0 在顶,与 lwe
    /// composelayer.frag 的 *vec2(0.5,0.5)+0.5 在 y 翻转后等价)。
    private func makeFootprintVerts(mvp: simd_float4x4) -> [Float] {
        // (pos.x, pos.y, fboUV.u, fboUV.v) 四角,顺序同 quadVerts。
        let corners: [(Float, Float, Float, Float)] = [
            (-1, -1, 0, 1),   // 单位 quad (-0.5,-0.5)
            ( 1, -1, 1, 1),   // (0.5,-0.5)
            (-1,  1, 0, 0),   // (-0.5,0.5)
            ( 1,  1, 1, 0),   // (0.5,0.5)
        ]
        var out: [Float] = []
        out.reserveCapacity(20)
        for (px, py, u, v) in corners {
            let qx = u - 0.5, qy = 0.5 - v
            let clip = mvp * SIMD4<Float>(qx, qy, 0, 1)
            let ndcX = clip.x / clip.w, ndcY = clip.y / clip.w
            let su = ndcX * 0.5 + 0.5
            let sv = ndcY * (-0.5) + 0.5
            out.append(contentsOf: [px, py, 0, su, sv])
        }
        return out
    }

    init?(device: MTLDevice) {
        self.device = device
        // 4 个采样器:{clamp,repeat} × {linear,nearest},由纹理真实 flags 选(见 samplerFor）。
        func makeSampler(_ wrap: MTLSamplerAddressMode, _ filter: MTLSamplerMinMagFilter) -> MTLSamplerState? {
            let d = MTLSamplerDescriptor()
            d.minFilter = filter; d.magFilter = filter
            d.sAddressMode = wrap; d.tAddressMode = wrap
            return device.makeSamplerState(descriptor: d)
        }
        guard let smp = makeSampler(.clampToEdge, .linear),
              let smpR = makeSampler(.repeat, .linear),
              let smpN = makeSampler(.clampToEdge, .nearest),
              let smpRN = makeSampler(.repeat, .nearest),
              let qb = device.makeBuffer(bytes: Self.quadVerts,
                                         length: MemoryLayout<Float>.stride * Self.quadVerts.count,
                                         options: .storageModeShared) else { return nil }
        self.sampler = smp; self.samplerRepeat = smpR
        self.samplerNearest = smpN; self.samplerRepeatNearest = smpRN; self.quadBuf = qb
        let wd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 1, height: 1, mipmapped: false)
        wd.usage = [.shaderRead]; wd.storageMode = .shared
        guard let wt = device.makeTexture(descriptor: wd) else { return nil }
        var wpx: [UInt8] = [255, 255, 255, 255]
        wt.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &wpx, bytesPerRow: 4)
        self.whiteTex = wt

        // manifest:优先 app bundle,回退到开发目录 Tools/generated。
        // 诊断钩子 WP_MANIFEST_DIR=<dir>:强制从指定目录读 WEEffects.json + we_effects/(隔离 worktree 验证,
        // 绕过 Bundle.main 落到 /Applications 的部署版)。未设=正常行为。
        let envDir = ProcessInfo.processInfo.environment["WP_MANIFEST_DIR"]
        let candidates = [
            envDir.map { URL(fileURLWithPath: $0).appendingPathComponent("WEEffects.json") },
            Bundle.main.resourceURL?.appendingPathComponent("WEEffects.json"),   // bundle: 与 we_effects/ 同级
            URL(fileURLWithPath: NSString(string: "~/Developer/LiveWallpaper/Tools/generated/WEEffects.json").expandingTildeInPath)
        ].compactMap { $0 }
        guard let mfURL = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
              let data = try? Data(contentsOf: mfURL),
              let m = try? JSONDecoder().decode([String: EffectDef].self, from: data) else {
            Log.write("WEEffectChain: manifest 未找到/解析失败"); return nil
        }
        self.manifest = m
        // basename → combo 覆盖最全的 key(排除 material/)。同 basename 多个 workshop 副本(WE 复制),
        // 各自转译的变体集不同(某 Simple_Audio_Bars 副本含 TRANSPARENCY=4 变体、另一个全空)。选**变体里
        // distinct combo 赋值最多**的,才能匹配壁纸 combo;否则退化默认 shader → 音频条白方块。平局取最短。
        func comboCoverage(_ key: String) -> Int {
            guard let d = m[key] else { return 0 }
            var s = Set<String>()
            for v in d.variants { for (ck, cv) in v.combos { s.insert("\(ck)=\(cv)") } }
            return s.count
        }
        var idx: [String: String] = [:]
        for k in m.keys where !k.hasPrefix("material/") {
            let base = k.components(separatedBy: "/").last ?? k
            if let cur = idx[base] {
                let cc = comboCoverage(cur), kc = comboCoverage(k)
                if cc > kc || (cc == kc && cur.count <= k.count) { continue }
            }
            idx[base] = k
        }
        self.basenameIndex = idx
        self.mslDir = mfURL.deletingLastPathComponent().appendingPathComponent("we_effects")
        // bundle 布局:WEEffects.json 与 we_effects/ 同级 or 内部?生成时 .metal 在 we_effects/ 子目录,
        // json 在 generated/ 根。开发路径:
        Log.write("WEEffectChain: loaded \(m.count) effects from \(mfURL.path)")
    }

    var availableEffects: Set<String> { Set(manifest.keys) }

    /// 解析 effect 名到实际 manifest key。WE 把内置特效(tint/spin/blurprecise/opacity/blend…)上传时
    /// **复制**到 `workshop/<id>/<name>` 路径(shader 与内置完全相同)。该副本若没单独转译进 manifest
    /// (如山田 3741334342 的 workshop/2978738836/tint 红框/唱片特效全缺),回退到通用 `<name>` 转译。
    /// **原 key 优先**(已转译的 workshop 副本不受影响)→ 零回归,只补缺失的内置副本。
    /// 仅对 `workshop/<id>/<basename>` 形式回退;真自定义特效(basename 不在 manifest)仍判缺失。
    func resolvedKey(_ effect: String) -> String? {
        if manifest[effect] != nil { return effect }
        if ProcessInfo.processInfo.environment["WP_NO_FX_FALLBACK"] != nil { return nil }   // A/B 诊断:关 basename 回退
        // workshop 副本(含双层嵌套 wrapper)→ 按 basename 索引到已转译的同名特效。
        // 仅对带路径的(workshop/… 或 effects 子路径)回退;裸名已在上面查过 manifest[effect]。
        guard effect.contains("/") else { return nil }
        let base = effect.components(separatedBy: "/").last ?? effect
        return basenameIndex[base]
    }

    /// combo 感知的 key 解析(修黑猫 3299228616 护猫遮罩失效):resolvedKey 的「原 key 优先」会命中
    /// workshop 副本(如 workshop/2655151285/opacity)——但 WE 上传时该副本**只转译了 base 变体**
    /// (we_build_effects.py scene_combos 把 `effects/workshop/<id>/opacity` 的 combos 错记到 key="workshop"
    ///  而非该副本名 → 副本漏掉 MASK-1 变体)。于是 pkg 请求 combos=[MASK:1] 时 selectVariant 退回 base
    /// (frag `mask=1.0`,**遮罩不采样** → 护猫洞完全失效、加色涟漪盖满整只猫)。
    /// 修法:若**原 key 的任何变体都没声明**某个被请求的 combo(如 MASK),而 basename 索引到的通用特效
    /// (shader 与副本同源,见 workshop-effect-basename-index)**有**声明该 combo 的变体 → 改用通用 key。
    /// 作用域极窄:仅当 ①请求的 effect 本身是 **workshop 副本路径**(workshop/<id>/<name>)且原 key 命中
    /// 该副本 ②原 key 缺失某请求 combo 的全部变体 且 ③该缺失 combo 是**遮罩类**(MASK/OPACITYMASK——只有
    /// 这类是「shader 不采样遮罩 = 静默失效」的可见 bug;其它 combo 如 waterflow 的 flowmask 槽不带 MASK、
    /// audio 的 SHAPE 几何在 build 期烘进各变体,不走这条回退)且 ④通用 key 有该 combo 变体。
    /// ⚠ 关键约束:**只对 workshop 副本→通用 回退,绝不反向**(pkg 显式引用裸名 `waterflow` 时 basenameIndex
    ///   可能指向某 workshop 副本——那是另一份 shader,不能改;waterflow 的 g_Texture1 是流向场非 opacity 遮罩,
    ///   引擎对它的隐式 MASK 注入是 no-op,回退会误换 shader → 3174556087 屋檐水流变样)。
    /// 已正确转译副本(自带全变体)不受影响 → 零回归。WP_NO_COMBO_KEY_FALLBACK=1 退回纯 resolvedKey(A/B)。
    func comboAwareKey(_ effect: String, combos: [String: Any]) -> String? {
        let base = resolvedKey(effect)
        guard let base, let edef = manifest[base] else { return base }
        if ProcessInfo.processInfo.environment["WP_NO_COMBO_KEY_FALLBACK"] != nil { return base }
        // 约束①:仅当请求的是 workshop 副本路径、且 resolvedKey 命中该副本本身(base == effect)。
        //   裸名(waterflow)或 resolvedKey 已回退到 basename 的情形不动 —— 那是 pkg 显式选定的 shader。
        guard effect.hasPrefix("workshop/"), base == effect else { return base }
        // 原 key 各变体声明过的 combo 名集合(只看「键」:base 缺整个遮罩维度才需回退)。
        var declared = Set<String>()
        for v in edef.variants { for k in v.combos.keys { declared.insert(k) } }
        // 约束③:只看遮罩类 combo(opacity 遮罩才会「shader 不采样 = 加色层盖住被护对象」)。
        let maskCombos: Set<String> = ["MASK", "OPACITYMASK"]
        let wantKeys = Set(combos.keys).intersection(maskCombos)
        let missing = wantKeys.subtracting(declared)
        guard !missing.isEmpty else { return base }
        // 约束④:通用(basename)特效有该缺失遮罩 combo 的变体 → 改用通用 key。
        let bn = effect.components(separatedBy: "/").last ?? effect
        guard let generic = basenameIndex[bn], generic != base, let gdef = manifest[generic] else { return base }
        var gdeclared = Set<String>()
        for v in gdef.variants { for k in v.combos.keys { gdeclared.insert(k) } }
        if missing.contains(where: { gdeclared.contains($0) }) {
            if comboKeyFallbackLogged.insert("\(base)→\(generic)|\(missing.sorted())").inserted {
                Log.write("WEFX combo-key-fallback \(effect): \(base)(缺\(missing.sorted()))→\(generic)")
            }
            return generic
        }
        return base
    }
    func has(_ effect: String) -> Bool { resolvedKey(effect) != nil }

    /// 该 effect 是否有采样器默认绑定 WE 渲染目标(_rt_*,如 frame_builder 的 _rt_FullFrameBuffer)。
    /// 命中则引擎需提供「该层之下已合成场景」底图喂 run(frameBuffer:),否则该槽退白 → 冲白。
    func needsFrameBuffer(_ effect: String) -> Bool {
        guard let key = resolvedKey(effect), let e = manifest[key] else { return false }
        for v in e.variants {
            for p in v.passes {
                for (_, m) in p.uniformMeta {
                    if let d = m.default?.value as? String, d.hasPrefix("_rt_") { return true }
                }
            }
        }
        return false
    }

    /// 该 effect 是否声明了 g_AudioSpectrum* 数组(直接用系统音频频谱画可视化,如 audioline / 简单的音频响应)。
    /// 这类特效无 AUDIOPROCESSING combo 也要触发音频采集——否则频谱 uniform 恒 0、曲线/条静止(条高 0 = 完全不绘制 = 看似没识别出音频条)。
    /// ⚠ 真值在 frag/vert 的 **StageDef.uniforms**(g_AudioSpectrum32Left/Right 在那里),**不在 uniformMeta**
    /// (uniformMeta 只含有 material/combo 标注的常量)。旧版只扫 uniformMeta → 对全库 g_AudioSpectrum 系
    /// shader(2846660316 SHAPE 系、audioline、各 Simple_Audio_Bars)恒返回 false → 不采集音频 → 条恒 0 不绘制。
    /// 这是「很多壁纸音频条根本不出现」的系统性真因(对照 lwe:CPass 对每个 pass 无条件绑 g_AudioSpectrum)。
    func usesAudioSpectrum(_ effect: String) -> Bool {
        guard let key = resolvedKey(effect), let e = manifest[key] else { return false }
        for v in e.variants {
            for p in v.passes {
                for (name, _) in p.uniformMeta where name.hasPrefix("g_AudioSpectrum") { return true }
                if let fu = p.frag?.uniforms, fu.contains(where: { $0.name.hasPrefix("g_AudioSpectrum") }) { return true }
                if let vu = p.vert?.uniforms, vu.contains(where: { $0.name.hasPrefix("g_AudioSpectrum") }) { return true }
            }
        }
        return false
    }

    // MARK: - 基础材质渲染路径(genericimage2/3/4 的 combo 变体)

    // 单位 quad(layer 空间 [-0.5,0.5]),由 g_ModelViewProjectionMatrix=layer.mvp 变换到屏幕。
    // 布局同 pipeline() 的顶点描述符:pos.xyz(@0)+ uv.xy(@12),stride 20,index 1。
    private static let materialQuadVerts: [Float] = [
        -0.5, -0.5, 0,  0, 1,
         0.5, -0.5, 0,  1, 1,
        -0.5,  0.5, 0,  0, 0,
         0.5,  0.5, 0,  1, 0,
    ]
    private lazy var materialQuadBuf: MTLBuffer = device.makeBuffer(
        bytes: Self.materialQuadVerts,
        length: MemoryLayout<Float>.stride * Self.materialQuadVerts.count, options: [])!

    // 「有意义」的材质 combo(任一开启即需走转译材质路径;否则 plain 层走轻量 scene_fragment,零回归)。
    static let meaningfulMaterialCombos = ["NORMALMAP", "REFLECTION", "REFLECTION_MAP", "LIGHTING",
                                           "EMISSIVE_MAP", "METALLIC_MAP", "ROUGHNESS_MAP", "PBRMASKS", "FOG"]

    /// 该图层是否需要用转译的 material/<shader> 变体渲染(有意义 combo);WP_MATERIAL_ALL 强制所有
    /// 有材质 shader 的层都走此路径(供 base 变体自验证:base = tex×color,应与 scene_fragment 一致)。
    func materialNeedsTranspiledPath(shader: String?, combos: [String: String]) -> Bool {
        guard let sh = shader, manifest["material/\(sh)"] != nil else { return false }
        if ProcessInfo.processInfo.environment["WP_MATERIAL_ALL"] != nil { return true }
        return Self.meaningfulMaterialCombos.contains { (Int(combos[$0] ?? "0") ?? 0) != 0 }
    }

    private static func mat4Floats(_ m: simd_float4x4) -> [Float] {
        let c = m.columns
        return [c.0.x, c.0.y, c.0.z, c.0.w, c.1.x, c.1.y, c.1.z, c.1.w,
                c.2.x, c.2.y, c.2.z, c.2.w, c.3.x, c.3.y, c.3.z, c.3.w]
    }

    /// 选 combos 最匹配的变体(variant.combos 必须是 layer combos 的子集,取最具体者;退 base)。
    private func bestMaterialVariant(_ eff: EffectDef, _ combos: [String: String]) -> Variant? {
        var best: Variant? = nil; var bestN = -1
        for v in eff.variants where v.combos.allSatisfy({ combos[$0.key] == $0.value }) {
            if v.combos.count > bestN { best = v; bestN = v.combos.count }
        }
        return best ?? eff.variants.first
    }

    /// 三套原生音频频谱(对齐 lwe recorder.audio16/32/64,CPass.cpp:785-790;各分辨率在 AudioCapture 里独立分桶,
    /// 非由 64 段重采样)。shader 按 RESOLUTION combo 声明 16/32/64 段数组,按声明 count 选对应原生那套。
    struct AudioSpectrum {
        var s16: [Float] = []
        var s32: [Float] = []
        var s64: [Float] = []
        /// 按 shader 声明的数组段数选原生频谱。lwe 只绑 16/32/64;其它段数 lwe 无对应 uniform → 空(=静默 0)。
        func pick(_ count: Int) -> [Float] {
            switch count {
            case 16: return s16
            case 32: return s32
            case 64: return s64
            default: return []
            }
        }
    }

    /// 为 genericimage stage 构造 _Globals(base 用 mvp/model/color;combo 的 PBR 量暂用 WE 默认,
    /// 环境光给真实 ambient——后续接 material constants/光源)。
    private func buildMaterialUniforms(_ stage: StageDef, meta: [String: UniformMeta],
                                       mvp: simd_float4x4, model: simd_float4x4,
                                       color: SIMD4<Float>, ambient: SIMD3<Float>,
                                       constants: [String: [Float]], audio: AudioSpectrum = AudioSpectrum()) -> [UInt8] {
        // 数组 uniform(如 g_AudioSpectrum16/32/64Left/Right)要把 offset+元素数×步长 算进上界,否则越界。
        var size = 16
        for u in stage.uniforms {
            let span = (u.array != nil) ? u.array! * (u.arrayStride ?? 16) : 64
            size = max(size, u.offset + span)
        }
        var bytes = [UInt8](repeating: 0, count: (size + 15) / 16 * 16)
        let mvpF = Self.mat4Floats(mvp), modelF = Self.mat4Floats(model)
        bytes.withUnsafeMutableBytes { raw in
            let base = raw.baseAddress!
            for u in stage.uniforms {
                // 音频频谱数组:基础材质 shader(genericimage 带 AUDIOPROCESSING combo)也会声明
                // g_AudioSpectrum16/32/64Left/Right。此前材质路径漏喂 → 这类音频可视化壁纸恒静止(无条)。
                // lwe(CPass.cpp:785-790):按声明段数绑对应原生频谱 audio16/32/64,左右同源(单声道镜像)。
                if let count = u.array, count > 0 {
                    if u.name.hasPrefix("g_AudioSpectrum"), u.name.hasSuffix("Left") || u.name.hasSuffix("Right") {
                        Self.writeArray(audio.pick(count), count: count, stride: u.arrayStride ?? 16, into: base, offset: u.offset)
                    }
                    continue
                }
                var vals: [Float] = []
                switch u.name {
                case "g_ModelViewProjectionMatrix", "g_EffectModelViewProjectionMatrix": vals = mvpF
                case "g_ModelMatrix", "g_LayerModelMatrix": vals = modelF
                case "g_ViewProjectionMatrix": vals = mvpF
                case "g_Color4", "g_Color", "g_CompositeColor": vals = [color.x, color.y, color.z, color.w]
                case "g_Texture0Rotation": vals = [1, 0, 0, 1]
                case "g_Texture0Translation": vals = [0, 0]
                case "g_EyePosition": vals = [0, 0, 0]
                case "g_Brightness", "g_Alpha", "g_UserAlpha": vals = [1]
                case "g_LightAmbientColor": vals = [ambient.x, ambient.y, ambient.z]
                default:
                    // 材质常量驱动(g_Roughness/Metallic/SpecularTint/EmissiveColor/g_Overbright/...):
                    // meta.material → 材质 constantshadervalues 真值,缺则退 WE shader 注解默认,再缺留 0。
                    if let mk = meta[u.name]?.material,
                       let cv = constants[mk] ?? (caseInsensitiveParams ? constants.first(where: { $0.key.lowercased() == mk.lowercased() })?.value : nil) { vals = cv }
                    else if let def = meta[u.name]?.default?.value { vals = Self.parseFloats(def) }
                    else { vals = [] }
                }
                if !vals.isEmpty { Self.write(vals, type: u.type, into: base, offset: u.offset) }
            }
        }
        return bytes
    }

    /// 用转译的 material/<shader> 变体渲染一个图层 quad。base 变体 = albedo×color(同 scene_fragment);
    /// combo 变体(NORMALMAP/REFLECTION/LIGHTING/...)按真 WE genericimage shader 计算。成功返回 true。
    func encodeMaterialLayer(_ enc: MTLRenderCommandEncoder, shader: String, combos: [String: String],
                             mvp: simd_float4x4, model: simd_float4x4, color: SIMD4<Float>,
                             albedo: MTLTexture, albedoFlags: TexFlags?, aux: [Int: MTLTexture],
                             ambient: SIMD3<Float>, constants: [String: [Float]], sceneFB: MTLTexture?,
                             audio: AudioSpectrum = AudioSpectrum()) -> Bool {
        guard let eff = manifest["material/\(shader)"],
              let variant = bestMaterialVariant(eff, combos),
              let p = variant.passes.first, let ps = pipeline(p) else { return false }
        enc.setRenderPipelineState(ps)
        enc.setVertexBuffer(materialQuadBuf, offset: 0, index: 1)
        if let v = p.vert {
            var vb = buildMaterialUniforms(v, meta: p.uniformMeta, mvp: mvp, model: model,
                                           color: color, ambient: ambient, constants: constants, audio: audio)
            enc.setVertexBytes(&vb, length: vb.count, index: v.ubuf)
        }
        guard let f = p.frag else { return false }
        var fb = buildMaterialUniforms(f, meta: p.uniformMeta, mvp: mvp, model: model,
                                       color: color, ambient: ambient, constants: constants, audio: audio)
        enc.setFragmentBytes(&fb, length: fb.count, index: f.ubuf)
        for s in f.samplers {
            let tex: MTLTexture
            switch s.name {
            case "g_Texture0": tex = albedo
            case "g_Texture1": tex = aux[1] ?? whiteTex
            case "g_Texture2": tex = aux[2] ?? whiteTex
            case "g_Texture3": tex = aux[3] ?? whiteTex
            default:
                tex = (s.name.contains("FullFrameBuffer") || s.name.lowercased().contains("reflect"))
                    ? (sceneFB ?? whiteTex) : whiteTex
            }
            enc.setFragmentTexture(tex, index: s.texIndex)
            enc.setFragmentSamplerState(s.name == "g_Texture0" ? samplerFor(albedoFlags) : samplerFor(nil),
                                        index: s.sampIndex)
        }
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        return true
    }

    // MARK: - Library / pipeline

    private func library(_ metalFile: String) -> MTLLibrary? {
        if let l = libCache[metalFile] { return l }
        let url = mslDir.appendingPathComponent(metalFile)
        guard let src = try? String(contentsOf: url, encoding: .utf8),
              let lib = try? device.makeLibrary(source: src, options: nil) else {
            Log.write("WEEffectChain: compile fail \(metalFile)"); return nil
        }
        libCache[metalFile] = lib; return lib
    }

    private func pipeline(_ p: PassDef, colorFormat: MTLPixelFormat = .bgra8Unorm) -> MTLRenderPipelineState? {
        // 关键:按**变体的 MSL 文件名**缓存,不能只按 p.shader。同一 shader 的不同 combo 变体
        // (如 depthparallax 的 QUALITY-1 vs MASK-1_QUALITY-1)采样器布局/数量不同 → MSL 不同;
        // 若只按 shader 名缓存,先编译的变体会被另一变体复用 → 贴图索引错位(g_Texture0 取到白色
        // 兜底槽)→ 整层洗白(实测 3440483127 的 ripple720p 水层)。
        // R5:管线的 colorAttachment pixelFormat **必须**匹配渲染目标 FBO 的格式(浮点目标用浮点管线),
        // 否则 setRenderPipelineState 时该 pass 校验失败。format 入缓存键(默认 bgra8 不改键 = 现有行为不变)。
        let fmtSuffix = colorFormat == .bgra8Unorm ? "" : "#\(colorFormat.rawValue)"
        let key = "\(p.vert?.metal ?? "?")|\(p.frag?.metal ?? "?")\(fmtSuffix)"
        if let ps = pipeCache[key] { return ps }
        if pipeFailed.contains(key) { return nil }   // 已知建不成:别每帧重试/刷屏
        guard let v = p.vert, let f = p.frag,
              let vlib = library(v.metal), let flib = library(f.metal),
              let vfn = vlib.makeFunction(name: v.entry), let ffn = flib.makeFunction(name: f.entry)
        else { pipeFailed.insert(key); return nil }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = vfn; d.fragmentFunction = ffn
        d.colorAttachments[0].pixelFormat = colorFormat
        // 顶点布局:a_Position(float3 @0)+ a_TexCoord(float2 @12),stride 20,buffer index 1。
        let vd = MTLVertexDescriptor()
        vd.attributes[0].format = .float3; vd.attributes[0].offset = 0;  vd.attributes[0].bufferIndex = 1
        vd.attributes[1].format = .float2; vd.attributes[1].offset = 12; vd.attributes[1].bufferIndex = 1
        vd.layouts[1].stride = 20
        d.vertexDescriptor = vd
        let ps: MTLRenderPipelineState
        do {
            ps = try device.makeRenderPipelineState(descriptor: d)
        } catch {
            pipeFailed.insert(key)   // 负缓存:只记一次,不再每帧重试/刷日志
            Log.write("WEEffectChain: pipeline fail \(key) ERROR: \(error)"); return nil
        }
        pipeCache[key] = ps; return ps
    }

    /// R5:WE effect.json fbos[].format 字符串 → MTLPixelFormat。
    /// 映射依据 WE 的 TextureFormat 枚举(见 lwe Data/Assets/Texture.h):
    ///   rg1616f→RG1616f(10)、r16f→R16f(11)、rgba16161616f/rgba16f→RGBA16161616f(14)、
    ///   r8→R8(9)、rg88→RG88(8)、rgb161616f→RGB(Metal 无 rgb16f,退 RGBA16Float)。
    ///   rgba8888 / rgba_backbuffer(= 标准 8-bit backbuffer)/ 缺省 → .bgra8Unorm(现状)。
    /// ⚠lwe 自身把所有 FBO 硬编码成 GL_RGBA8(FBOProvider.cpp 注释 "TODO: PROPERLY DETERMINE FBO FORMAT")——
    ///   即 lwe 在此为未完成移植;按真 WE 语义补上(fluidsimulation/motionblur 才正确)。
    /// WP_NO_FBO_FORMAT=1 → 全部退回 .bgra8Unorm(A/B 守门,回归排查)。
    private static func pixelFormat(for fmt: String?) -> MTLPixelFormat {
        guard let f = fmt?.lowercased(),
              ProcessInfo.processInfo.environment["WP_NO_FBO_FORMAT"] == nil else { return .bgra8Unorm }
        switch f {
        case "rg1616f":                          return .rg16Float
        case "r16f":                             return .r16Float
        case "rgba16161616f", "rgba16f":         return .rgba16Float
        case "rgb161616f", "rgb16f":             return .rgba16Float   // Metal 无三通道 16f,用 RGBA16Float
        case "r8":                               return .r8Unorm
        case "rg88":                             return .rg8Unorm
        case "rgba8888", "rgba_backbuffer", "":  return .bgra8Unorm
        default:                                 return .bgra8Unorm    // 未知格式保守退默认
        }
    }

    private func makeTarget(width: Int, height: Int, format: MTLPixelFormat = .bgra8Unorm) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format,
                                                            width: width, height: height, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]; desc.storageMode = .private
        return device.makeTexture(descriptor: desc)
    }
    // 命名中间 FBO(_rt_*):跨链/跨图层复用(同 cmd buffer 内按序执行,消费完才被覆盖)。

    /// 加载 WE 内置默认贴图(如 "util/noise"/"util/white"/"util/black")+ 其真实纹理 flags。缺失退白。
    /// flags 决定采样器:可平铺噪声(util/noise 等)在 .tex 头本就无 ClampUVs flag → repeat 环绕;
    /// 精灵/white/black 带 ClampUVs → clamp。取代旧的按名字猜 isTilingRef。
    private func utilTexture(_ ref: String) -> (tex: MTLTexture, flags: TexFlags?) {
        if let t = utilCache[ref] { return t }
        var result = whiteTex
        var flags: TexFlags? = nil
        if let blob = BuiltinAssets.shared.textureData(forReference: ref),
           let decoded = TexDecoder.decodeFirstMipWithFlags(blob) {
            flags = decoded.flags
            switch decoded.tex {
            case .encoded(let data):
                if let t = try? loader.newTexture(data: data, options: [.SRGB: false]) { result = t }
            case .rgba8(let px, let w, let h):
                let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
                d.usage = [.shaderRead]
                if let t = device.makeTexture(descriptor: d) {
                    px.withUnsafeBytes { t.replace(region: MTLRegionMake2D(0,0,w,h), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: w*4) }
                    result = t
                }
            case .video: break
            }
        }
        let entry = (tex: result, flags: flags)
        utilCache[ref] = entry; return entry
    }

    private func renderTarget(_ name: String, width: Int, height: Int, format: MTLPixelFormat = .bgra8Unorm) -> MTLTexture? {
        // 键含格式:同名 FBO 在不同 format 间不复用(实际同名恒同 format,format 入键只为防呆 + 让浮点块与默认块分桶)。
        let key = format == .bgra8Unorm ? "\(name)@\(width)x\(height)" : "\(name)@\(width)x\(height)#\(format.rawValue)"
        if let t = rtPool[key] { return t }
        let t = makeTarget(width: width, height: height, format: format); rtPool[key] = t; return t
    }

    // MARK: - Uniform 装填

    /// 把一个值(标量 / "x y z" 字符串 / 数组)写进 buffer 的 offset,按类型决定写几个 float。
    private static func write(_ value: [Float], type: String, into buf: UnsafeMutableRawPointer, offset: Int) {
        let p = buf.advanced(by: offset).assumingMemoryBound(to: Float.self)
        // mat3:std140 下 3 列、每列 vec3 但各占一个 vec4 槽(16B),列数据落在字节 0/16/32(=float 下标 0/4/8),
        // 共 48B。value 是 9 个 float(列主序 3×3)。逐列写 vec3、跨 4-float 步长,padding 留 0。
        // (此前连续写 12 个 float 会把第 2、3 列各错位 4B/8B → 法线矩阵散架。对照 lwe glUniformMatrix3fv 由
        //  驱动按 std140 自动列对齐。)
        if type == "mat3" {
            for col in 0..<3 {
                for row in 0..<3 {
                    let idx = col * 3 + row
                    p[col * 4 + row] = idx < value.count ? value[idx] : 0
                }
            }
            return
        }
        let n: Int
        switch type {
        case "float": n = 1
        case "vec2": n = 2
        case "vec3": n = 3
        case "vec4": n = 4
        case "mat4": n = 16
        default: n = min(value.count, 4)
        }
        for i in 0..<n { p[i] = i < value.count ? value[i] : 0 }
    }

    /// 写 std140 数组 uniform:N 个标量,每个落在 offset + i*stride 处的第一个 float(.x);
    /// 步长之间的 padding 保持 0(spirv-cross 把 float[N] 表示成 float4[N],只用 .x)。
    private static func writeArray(_ value: [Float], count: Int, stride: Int,
                                   into buf: UnsafeMutableRawPointer, offset: Int) {
        for i in 0..<count {
            let p = buf.advanced(by: offset + i * stride).assumingMemoryBound(to: Float.self)
            p[0] = i < value.count ? value[i] : 0
        }
    }

    /// lightshafts gradient 模式的 colorastart→colorend 1D 渐变图(64×1 RGBA8,线性插值,clamp)。
    /// 按颜色键缓存,避免逐帧重建。替代静态 gradient_iridescent 彩虹图 → 光束按 pkg 着色(白→青等)。
    private var lightshaftRampCache: [String: MTLTexture] = [:]
    private func lightshaftRamp(start: [Float], end: [Float]) -> MTLTexture? {
        func c(_ a: [Float], _ i: Int) -> Float { i < a.count ? max(0, min(1, a[i])) : (i == 3 ? 1 : 0) }
        let s = SIMD3<Float>(c(start,0), c(start,1), c(start,2))
        let e = SIMD3<Float>(c(end,0), c(end,1), c(end,2))
        let key = String(format: "%.3f_%.3f_%.3f__%.3f_%.3f_%.3f", s.x,s.y,s.z, e.x,e.y,e.z)
        if let t = lightshaftRampCache[key] { return t }
        let n = 64
        var px = [UInt8](repeating: 0, count: n * 4)
        for i in 0..<n {
            let t = Float(i) / Float(n - 1)
            let col = s + (e - s) * t
            px[i*4+0] = UInt8(col.x * 255); px[i*4+1] = UInt8(col.y * 255)
            px[i*4+2] = UInt8(col.z * 255); px[i*4+3] = 255
        }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: n, height: 1, mipmapped: false)
        d.usage = .shaderRead
        guard let t = device.makeTexture(descriptor: d) else { return nil }
        t.replace(region: MTLRegionMake2D(0, 0, n, 1), mipmapLevel: 0, withBytes: px, bytesPerRow: n * 4)
        lightshaftRampCache[key] = t
        return t
    }

    private static func parseFloats(_ any: Any?) -> [Float] {
        if let n = any as? NSNumber { return [n.floatValue] }
        if let s = any as? String {
            // WE 向量常量用「空格」或「逗号」分隔(如 u_BarBounds="0.0, 1.0"、u_AASmoothness="0.02, 0.02")。
            // 只按空格分会把 "0.0," 解析失败丢掉 → vec2 只剩一个分量、错位(实测:身体音频条 barHeight 反转)。
            return s.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\t" }).compactMap { Float($0) }
        }
        if let a = any as? [Any] { return a.compactMap { ($0 as? NSNumber)?.floatValue } }
        return []
    }

    /// 为某 stage 构造 _Globals 字节。pkgParams = pkg 的 constantshadervalues(material-key→值)。
    /// cursor = 光标归一化位置 [0,1](y 向上);WE 交互特效(xray/depthparallax)的 pointer 量。
    /// audio16 = 16 段频谱 [0,1](AudioCapture.shared.spectrum16);喂 pulse 等音频特效的
    /// g_AudioSpectrum16Left/Right 数组。空数组 → 音频 uniform 退 0(无声)。
    /// texW/texH = 该 pass 实际绑定的主纹理尺寸(可能被 targetScale 降采样)→ g_TextureNResolution/g_Screen 用它。
    /// sceneW/sceneH = 全帧(场景)尺寸 → g_TexelSize/g_TexelSizeHalf 用它(对齐 lwe CPass.cpp:783,恒定全场景 texel)。
    private func buildUniforms(_ stage: StageDef, meta: [String: UniformMeta],
                               pkgParams: [String: Any], time: Float, cursor: SIMD2<Float>,
                               texW: Int, texH: Int, sceneW: Int, sceneH: Int,
                               audio: AudioSpectrum,
                               auxResolutions: [String: SIMD4<Float>] = [:],
                               pointerXform: SIMD4<Float> = SIMD4(1, 0, -1, 1)) -> [UInt8] {
        // 数组 uniform 要把 offset+元素数×步长 都算进上界(否则数组尾巴越界)。
        var size = 16
        for u in stage.uniforms {
            let span = (u.array != nil) ? u.array! * (u.arrayStride ?? 16) : 64
            size = max(size, u.offset + span)
        }
        var bytes = [UInt8](repeating: 0, count: (size + 15) / 16 * 16)
        bytes.withUnsafeMutableBytes { raw in
            let base = raw.baseAddress!
            for u in stage.uniforms {
                // 数组 uniform:WE 的音频频谱(L/R),按 std140 16B 步长写每元素的 .x。
                // WE 的可视化 shader 按 RESOLUTION combo 选 16/32/64 段数组(Simple_Audio_Bars 默认 32;pulse 用 16)。
                // lwe(CPass.cpp:785-790):按声明段数绑对应**原生**频谱 recorder.audio16/32/64(各分辨率在
                // AudioCapture 里独立分桶,非重采样),左右声道同源(单声道镜像)。漏填某分辨率 → 频谱全 0 → 条恒为 0。
                if let count = u.array, count > 0 {
                    if u.name.hasPrefix("g_AudioSpectrum"), u.name.hasSuffix("Left") || u.name.hasSuffix("Right") {
                        Self.writeArray(audio.pick(count), count: count, stride: u.arrayStride ?? 16, into: base, offset: u.offset)
                    }
                    // 其它数组 uniform 暂无来源 → 留 0(归零已是默认)。
                    continue
                }
                var vals: [Float] = []
                if u.name == "g_ModelViewProjectionMatrix"
                    || u.name == "g_EffectTextureProjectionMatrix"
                    || u.name == "g_EffectTextureProjectionMatrixInverse"
                    || u.name == "g_LayerModelMatrix"
                    || u.name == "g_EffectModelViewProjectionMatrix" {
                    // 全屏轴对齐 quad:MVP / 纹理投影 / 图层模型 / 特效 MVP 皆为 identity。
                    // 关键:depthparallax/xray vert 用 g_EffectTextureProjectionMatrixInverse 做
                    // CAST3X3 旋转 + normalize;若留 0 → normalize(vec2(0))=NaN → 整层采样炸成白。
                    // frame_builder vert 用 g_LayerModelMatrix 取 scale(length(row))、g_EffectModelViewProjectionMatrix
                    // 算 v_ScreenCoord;留 0 → scale=0 → v_Size 塌成「整面都是边框」→ 整层冲白。
                    // 平面满画布层的正确值就是 identity(无投影倾斜/单位缩放),非兜底。
                    vals = [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1]
                } else if u.name == "g_PointerPosition" || u.name == "g_ParallaxPosition" {
                    // WE 交互 pointer / 视差位置,归一化 [0,1]。静止居中 = (0.5,0.5)(中性,无偏移)。
                    // ⚠ Y 轴约定:lwe(CScene.cpp:387 `mouseY = 1.0 - normalizedMouseY`)把 g_PointerPosition.y 存成
                    //   **y 向下**(屏幕顶=0);xray.vert 也假设 y 向下(自带 `pointer.y = 1.0 - pointer.y`)。本引擎
                    //   cursor.y 是 y 向上 → 这里翻 Y 对齐 lwe,否则揭示框竖直镜像(鼠标往上→揭示往下)。居中仍 0.5。
                    // ⭐pointerXform=(ax,bx,ay,by):把屏幕 UV pointer 变换到**层 texcoord 空间**。层 scale≠1 或
                    //   origin 偏心时,effect 跑在缩放后的 quad 上(texcoord 0-1 = 缩放 quad ≠ 画布),不校正则
                    //   xray 揭示框/视差按未缩放定位 → 随距中心放大偏移(实测 3605892961 层 scale=1.3,揭示框偏 1.3×)。
                    //   引擎按层 origin/sizePx/canvas 算 xform;全画布层=(1,0,-1,1)→退回 [cursor.x,1-cursor.y] 零回归。
                    vals = [pointerXform.x * cursor.x + pointerXform.y,
                            pointerXform.z * cursor.y + pointerXform.w]
                } else if u.name == "g_Time" {
                    vals = [time]
                } else if u.name == "g_TexelSize" {
                    // lwe(CPass.cpp:783):g_TexelSize = 1/**场景**尺寸(恒定全帧 texel,所有 pass 一致),
                    // 不是该 pass 降采样纹理的 texel —— per-pass 纹理尺寸由 g_TextureNResolution 另行暴露。
                    vals = [1.0 / Float(max(1, sceneW)), 1.0 / Float(max(1, sceneH))]
                } else if u.name == "g_TexelSizeHalf" {
                    vals = [0.5 / Float(max(1, sceneW)), 0.5 / Float(max(1, sceneH))]
                } else if u.name.hasSuffix("Resolution") {
                    // freeimage(内嵌 PNG)且容器≠内容的辅助贴图:按 .tex 头喂(容器w,h,内容w,h)= 真 WE 行为
                    // (WE 的 GPU 纹理是 FreeImage 解的内容尺寸,但分辨率仍报头部 → 修正系数 内容/容器 把 UV
                    //  压到内容上半部;lwe CTexture.cpp:127 对 FIF 特判修正=1 ≠ 真 WE。御剑「影子」遮罩
                    //  4096×4096容器/4096×2296内容 → 遮罩只采上 56%(发顶)→ 身体音频条从发缘起、不上脸)。
                    if let r = auxResolutions[u.name] {
                        vals = [r.x, r.y, r.z, r.w]
                    } else {
                        vals = [Float(texW), Float(texH), Float(texW), Float(texH)]
                    }
                } else if u.name == "g_Screen" {
                    // 屏幕尺寸 vec3(w,h,aspect);depthparallax vert 声明但未用,给真实值无害。
                    vals = [Float(texW), Float(texH), Float(texW) / Float(max(1, texH))]
                } else if let mk = meta[u.name]?.material,
                          let pv = pkgParams[mk] ?? (caseInsensitiveParams ? pkgParams.first(where: { $0.key.lowercased() == mk.lowercased() })?.value : nil) {
                    vals = Self.parseFloats(pv)                       // pkg 用户设的真实值(大小写不敏感兜底)
                } else if let def = meta[u.name]?.default?.value {
                    vals = Self.parseFloats(def)                      // WE 默认值
                } else if u.name == "g_Brightness" || u.name == "g_Alpha" || u.name == "g_UserAlpha" {
                    vals = [1]   // 引擎提供的亮度/透明,默认全开;留 0 会让引用它的 workshop shader 全黑/全透明
                } else if u.name == "g_Color" || u.name == "g_CompositeColor" {
                    vals = [1, 1, 1]
                } else if u.name == "g_Color4" {
                    vals = [1, 1, 1, 1]
                } else if u.name == "g_Daytime" {
                    // 严格对齐 lwe(WallpaperApplication.cpp:866):g_Daytime = (hour*60+min)/(24*60),
                    // 真实本地时钟(0=午夜、0.5=正午)。原硬编码 0.5 = 恒正午 = 自加偏离,昼夜染色壁纸不随时间变。
                    let c = Calendar.current.dateComponents([.hour, .minute], from: Date())
                    vals = [Float((c.hour ?? 12) * 60 + (c.minute ?? 0)) / 1440.0]
                }
                Self.write(vals, type: u.type, into: base, offset: u.offset)
            }
        }
        return bytes
    }

    // MARK: - 运行一条 effect 链

    /// 选与场景 combos 最匹配的变体(精确匹配优先,否则 base)。
    private func selectVariant(_ def: EffectDef, combos: [String: Any]) -> Variant? {
        let want = combos.mapValues { v -> String in
            if let n = v as? NSNumber { return n.intValue == Int(n.doubleValue) ? "\(n.intValue)" : "\(n.floatValue)" }
            return "\(v)"
        }
        // 精确匹配(变体每个 combo 都被请求满足)优先,命中数越多越好。空变体作 score 0 兜底。
        var best: Variant? = nil; var bestScore = -1
        for v in def.variants {
            if v.combos.isEmpty { if bestScore < 0 { best = v; bestScore = 0 }; continue }
            let ok = v.combos.allSatisfy { want[$0.key] == $0.value }
            if ok && v.combos.count > bestScore { best = v; bestScore = v.combos.count }
        }
        // 部分匹配兜底:精确匹配只剩空变体(bestScore==0,丢掉所有 combo 逻辑)时,与其退化到默认 shader
        // (常使关键 combo 如 TRANSPARENCY 失效 → 音频条 composelayer 渲成**不透明白方块**盖住场景,黑猫 Bar2:
        // SHAPE=1/TRANSPARENCY=4/无ANTIALIAS,而所有 TRANSPARENCY=4 变体都带 ANTIALIAS=1 → 精确不命中),
        // 不如选「满足请求的 combo 数 − 违反的 combo 数」最高的变体:多余的次要 combo(ANTIALIAS)被忽略,
        // 但关键 combo(TRANSPARENCY/BLENDMODE)保住 → 透明合成,白方块消失。WP_NO_PARTIAL_VARIANT=1 退回。
        if bestScore <= 0, ProcessInfo.processInfo.environment["WP_NO_PARTIAL_VARIANT"] == nil {
            var partial: Variant? = nil; var ps = 0
            for v in def.variants where !v.combos.isEmpty {
                let sat = v.combos.filter { want[$0.key] == $0.value }.count
                let score = sat - (v.combos.count - sat)   // 满足 − 违反
                if sat > 0 && score > ps { partial = v; ps = score }
            }
            if let p = partial { return p }
        }
        return best ?? def.variants.first
    }

    // 审计修复 #2:把 run() 的 combos([String:Any])归一成「combo名→整数值」,供 bind.conditions 判定。
    // combos 值可能是 NSNumber/String;按 selectVariant 同样的整数语义取值(LIGHTING/RENDERING 都是整数 combo)。
    private static func comboInts(_ combos: [String: Any]) -> [String: Int] {
        var out: [String: Int] = [:]
        for (k, v) in combos {
            if let n = v as? NSNumber { out[k] = n.intValue }
            else if let s = v as? String, let i = Int(s) ?? Float(s).map({ Int($0) }) { out[k] = i }
        }
        return out
    }

    // 审计修复 #2:判定一个 bind 的 conditions 是否被当前 combos 满足。
    // conditions 为「条件组」列表,**所有组**都需满足(AND);组内 combo名→期望值全部相等才算该组满足。
    // 缺失的 combo 视为 0(WE 未定义 combo 即 0);conditions 为 nil/空 → 恒为 true(无条件绑定,旧行为)。
    private static func conditionsMet(_ conditions: [[String: Int]]?, comboInts: [String: Int]) -> Bool {
        guard let conds = conditions, !conds.isEmpty else { return true }
        for group in conds {
            for (name, want) in group {
                if (comboInts[name] ?? 0) != want { return false }
            }
        }
        return true
    }

    /// 在 input 上跑 effect 的全部 pass,返回结果纹理。combos/pkgParams 来自 pkg 图层 effect pass。
    /// paramsPerPass(可选)= 逐 pass 的真实参数;多 pass effect(如 bloom 各 pass strength/Tint 不同)
    /// 时按 pass 索引取;为空或越界则回退合并版 pkgParams。
    /// maskTexture(可选)= 该 effect 的不透明遮罩(WE opacitymask)。绑定到 uniformMeta 里
    /// combo=="MASK" 的那个采样器(shake 是 g_Texture3,waterwaves/foliagesway/tint/opacity 等是
    /// g_Texture1)——按 manifest 自动定位,不硬编码槽名。
    /// texFlags(可选)= 按采样器名(g_TextureN)给出的真实 WE 纹理 flags,选采样器(repeat/clamp、linear/nearest）。
    ///   "g_Texture0" = 主输入(图层贴图)的 flags;其余键对应 auxTextures 同名槽。缺省 → clamp+linear(保守,不破坏现有渲染)。
    ///   中间 FBO(命名 bind / previous)始终用 clamp+linear:它们是引擎渲出的全屏纹理、UV∈[0,1],非 WE 资源 flags 适用对象。
    /// sceneFootprint(可选)= frameBufferInput composelayer 专用。非 nil 时:`input` 视为**完整场景主 FBO**
    /// (_rt_FullFrameBuffer),先按 lwe composelayer 首 copy pass(makeFootprintVerts + copyPipeline)把场景
    /// 按该层屏幕投影位置采样进**该层尺寸**(outW×outH)的 [0,1] FBO,再以它为输入跑特效链(对齐 CImage.cpp:
    /// 785-853:copy 首 pass → effect 各 pass 在层自有乒乓 FBO 全屏跑)。位移特效(cloudmotion/shake 的
    /// uvs+=offset)由此读到的是「该层 region 内的场景」邻域(与 lwe 一致;层边界外不存在,非裁场景小图)。
    /// 末 pass 渲层 quad 采样结果由 SceneRenderEngine.encode 按 layer.mvp 完成(= lwe 末 pass)。
    /// nil(普通特效层 / 后处理链)→ 行为与改动前完全一致(input 即特效输入,FBO=input 尺寸,首 pass 全 [0,1])。
    func run(effect: String, input: MTLTexture, pkgParams: [String: Any],
             combos: [String: Any] = [:], auxTextures: [String: MTLTexture] = [:],
             auxResolutions: [String: SIMD4<Float>] = [:],
             maskTexture: MTLTexture? = nil,
             texFlags: [String: TexFlags] = [:],
             paramsPerPass: [[String: Any]] = [], time: Float,
             cursor: SIMD2<Float> = SIMD2(0.5, 0.5),
             audio: AudioSpectrum = AudioSpectrum(),
             frameBuffer: MTLTexture? = nil,
             sceneFootprint: (mvp: simd_float4x4, outW: Int, outH: Int)? = nil,
             pointerXform: SIMD4<Float> = SIMD4(1, 0, -1, 1),
             commandBuffer cmd: MTLCommandBuffer) -> MTLTexture? {
        guard let key = comboAwareKey(effect, combos: combos), let edef = manifest[key], let def = selectVariant(edef, combos: combos) else {
            // 一次性诊断:manifest 缺失或变体不命中(静默失败的头号嫌疑),打出请求 combos vs 可用变体。
            let dk = "\(effect)|\(Self.comboInts(combos))"
            if diagLogged.insert(dk).inserted {
                if let edef = manifest[effect] {
                    let avail = edef.variants.map { $0.combos }.prefix(8)
                    Log.write("WEFX-DIAG no-variant effect=\(effect) 请求combos=\(combos) 可用=\(Array(avail))")
                } else {
                    Log.write("WEFX-DIAG no-manifest effect=\(effect)")
                }
            }
            return nil
        }
        // 特效链的工作输入 + 尺寸。frameBufferInput composelayer:先跑 composelayer copy pass(忠实 lwe 首
        // copy pass),把完整场景按该层 footprint 采样进层尺寸 FBO,作为后续特效链输入(named["previous"] 即它)。
        var input = input
        // g_TexelSize 恒用**完整场景**尺寸(lwe CPass.cpp:783 = 1/scene.getWidth);copy 后 input 变层尺寸,
        // 故先记下场景原始尺寸供 buildUniforms 的 sceneW/sceneH。footprint=nil 时 = input 尺寸(行为不变)。
        let sceneW = input.width, sceneH = input.height
        if let fp = sceneFootprint, let cp = copyPipeline,
           let layerTex = makeTarget(width: max(1, fp.outW), height: max(1, fp.outH)) {
            let verts = makeFootprintVerts(mvp: fp.mvp)
            let vbuf = device.makeBuffer(bytes: verts, length: MemoryLayout<Float>.stride * verts.count, options: [])
            let cpass = MTLRenderPassDescriptor()
            cpass.colorAttachments[0].texture = layerTex
            cpass.colorAttachments[0].loadAction = .clear
            cpass.colorAttachments[0].storeAction = .store
            cpass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            if let v = vbuf, let cenc = cmd.makeRenderCommandEncoder(descriptor: cpass) {
                cenc.setRenderPipelineState(cp)
                cenc.setVertexBuffer(v, offset: 0, index: 1)
                cenc.setFragmentTexture(input, index: 0)
                cenc.setFragmentSamplerState(sampler, index: 0)   // 场景 FBO 全屏纹理,clamp+linear(UV∈[0,1])
                cenc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                cenc.endEncoding()
                input = layerTex
            }
        }
        // 忠实 bloom 短路(workshop/2822917890):该 effect 的转译 .metal 链是另一(更早)版本、四处放大 →
        // 开 bloom 把亮皮肤冲白。改跑 runFaithfulBloom(逐行对齐 pkg shader,见上方 bloomShaderSrc 注释),
        // 用合并版 pkgParams 取真值参数(threshold/gamma/strength/radius/Tint/opacity)。WP_NO_BLOOM_FIX=1 退回原链。
        if key == "workshop/2822917890/bloom",
           ProcessInfo.processInfo.environment["WP_NO_BLOOM_FIX"] == nil,
           let out = runFaithfulBloom(input: input, pkgParams: pkgParams, commandBuffer: cmd) {
            return out
        }
        let w = input.width, h = input.height
        // 审计修复 #2:把本次 run 的 combos 归一成整数,供 bind.conditions 判定(在 pass 循环外算一次)。
        let comboInts = Self.comboInts(combos)
        // 审计修复 #3:同名 FBO 在「一次 run 内」必须用**一致**的尺寸键,否则跨帧反馈(乒乓/swap)断链。
        // 此前预填与 renderTarget 各自按所在 pass 的 targetScale 重算 "name@WxH":若同名 FBO 在不同 scale
        // 的 pass 间出现(或预填用 A 的 scale、渲染用 B 的 scale),会取到不同的纹理块,反馈数据丢失。
        // 修法:为每个 FBO 名预解析一个**唯一**尺寸 —— 取该名**首次**作为 target 出现时的 targetScale 算出的
        // 尺寸,后续所有引用(预填 / 渲染 / swap)都用它。单 scale 特效里每个名只一种尺寸 → 与旧行为完全一致。
        var nameSize: [String: (w: Int, h: Int)] = [:]
        // R5:每个命名 FBO 的像素格式(取该名**首次**作为渲染 target 出现时的 targetFormat;无 = 默认 bgra8)
        // 与跨帧持久标记 unique。同名 FBO 恒同 format/unique(WE 按 fbos[] 名定义)→ 取首次即可。
        var nameFormat: [String: MTLPixelFormat] = [:]
        var nameUnique: Set<String> = []
        for p in def.passes {
            guard let tname = p.target, nameSize[tname] == nil else { continue }
            let s = max(1, p.targetScale ?? 1)
            nameSize[tname] = (max(1, w / s), max(1, h / s))
            nameFormat[tname] = Self.pixelFormat(for: p.targetFormat)
            if p.targetUnique == true { nameUnique.insert(tname) }
        }
        func fmtFor(_ name: String) -> MTLPixelFormat { nameFormat[name] ?? .bgra8Unorm }
        // 跨帧持久键:format 入键(与 renderTarget 完全一致)。供预填 / swap / copy 对齐,避免浮点块与默认块串桶。
        func rtKey(_ name: String, _ sz: (w: Int, h: Int), _ fmt: MTLPixelFormat) -> String {
            fmt == .bgra8Unorm ? "\(name)@\(sz.w)x\(sz.h)" : "\(name)@\(sz.w)x\(sz.h)#\(fmt.rawValue)"
        }
        // 本 run 内按 FBO 名拿目标纹理(用一致尺寸键 + 格式),供 swap / 渲染共用,避免重算 scale 取错块。
        func targetForName(_ name: String) -> MTLTexture? {
            let sz = nameSize[name] ?? (w, h)
            return renderTarget(name, width: sz.w, height: sz.h, format: fmtFor(name))
        }
        // "previous" = 特效的**输入图**(恒定;如 godrays/bloom apply 要把光束/辉光叠回原图),不是滚动的上一 pass 输出。
        var named: [String: MTLTexture] = ["previous": input]
        // 跨帧累积预填(motionblur 等):named 每次 run() 重置,但持久(unique)FBO 的内容已留在跨帧
        // 存活的 rtPool 里。把本 effect 各 pass 的命名 target 从 rtPool 预填进 named(尺寸/格式用上面解析的
        // 一致键),让首 pass 读到上一帧累积。仅预填已存在(跑过≥1帧)的;首帧没有 → pass0 的历史槽退白,1~2 帧收敛。
        for (tname, sz) in nameSize {
            if let t = rtPool[rtKey(tname, sz, fmtFor(tname))] { named[tname] = t }
        }
        var lastOut: MTLTexture = input

        for (pi, p) in def.passes.enumerated() {
            // 命令 pass(无 vert/frag):copy = 把累积结果拷进持久缓冲供下一帧(motionblur pass1)。
            // 必须在 pipeline guard 之前处理,否则会被 `guard let vstage` 跳过、命令永不执行。
            if p.command != nil || p.copy == true {
                if (p.command == "copy" || p.copy == true),
                   let srcName = p.source, let dstName = p.target, let src = named[srcName],
                   let dst = renderTarget(dstName, width: src.width, height: src.height, format: src.pixelFormat),
                   let blit = cmd.makeBlitCommandEncoder() {
                    blit.copy(from: src, sourceSlice: 0, sourceLevel: 0,
                              sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                              sourceSize: MTLSize(width: src.width, height: src.height, depth: 1),
                              to: dst, destinationSlice: 0, destinationLevel: 0,
                              destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
                    blit.endEncoding()
                    named[dstName] = dst
                }
                // 审计修复 #1:实现 swap 命令(此前被静默跳过)。fluidsimulation 末尾用
                // {"command":"swap","source":"_rt_SmokeVelocity1","target":"_rt_SmokeVelocity2"} 交换两个
                // 乒乓 FBO,使下一帧的「读/写角色」对调(本帧写 2,swap 后 1↔2,下帧再写、上帧结果在另一块)。
                // 命令参数来源:manifest 的 swap pass 带 source/target 两个 FBO 名(见 we_build_effects.py 的
                // command pass 记录)。交换 = 把两个命名块在 named 与持久 rtPool 里的引用对调,这样:
                //   ① 同一 run 内后续 pass 经 named 取到对调后的块;
                //   ② 跨帧靠 rtPool 持久,下一帧的预填(按一致尺寸键)取到对调后的内容,反馈链不断。
                // 用一致尺寸键(targetForName,审计修复 #3)取/建两块,绝不重算 scale 取错块。
                else if p.command == "swap",
                        let aName = p.source, let bName = p.target {
                    // 乒乓对的两块尺寸恒相同。但 swap 的 source(如 _rt_SmokeDye1)可能只作 swap 源、从不作渲染
                    // target → 不在 nameSize 里;此时用对端(target,如 _rt_SmokeDye2,有渲染 pass 记过尺寸)的
                    // 尺寸推断,避免源退成全分辨率与对端(半分辨率)错配。两端都缺则退输入全分辨率。
                    let bSz = nameSize[bName] ?? nameSize[aName] ?? (w, h)
                    let aSz = nameSize[aName] ?? bSz
                    // R5:乒乓两端格式相同(WE 同名定义);swap 源若只作 swap、不作渲染 target(不在 nameFormat)
                    // 则用对端格式推断,确保浮点速度/压力场不退成 bgra8。
                    let bFmt = nameFormat[bName] ?? nameFormat[aName] ?? .bgra8Unorm
                    let aFmt = nameFormat[aName] ?? bFmt
                    if let aTex = named[aName] ?? renderTarget(aName, width: aSz.w, height: aSz.h, format: aFmt),
                       let bTex = named[bName] ?? renderTarget(bName, width: bSz.w, height: bSz.h, format: bFmt) {
                        // named 引用对调(同 run 内后续 pass 取到对调后的块)。
                        named[aName] = bTex
                        named[bName] = aTex
                        // 持久 rtPool 引用对调(用与 renderTarget 完全一致的尺寸/格式键,保证跨帧预填命中)。
                        rtPool[rtKey(aName, aSz, aFmt)] = bTex
                        rtPool[rtKey(bName, bSz, bFmt)] = aTex
                    }
                }
                continue
            }
            // R5:管线 colorAttachment 格式必须匹配目标 FBO 格式(浮点目标用浮点管线)。无 target 的最终输出
            // 恒 bgra8。targetForName/makeTarget 已按格式分配,这里把同一格式喂给 pipeline。
            let outFmt: MTLPixelFormat = (p.target != nil) ? fmtFor(p.target!) : .bgra8Unorm
            guard let ps = pipeline(p, colorFormat: outFmt), let vstage = p.vert, let fstage = p.frag else { continue }
            // 有 target → 命名 FBO(按**本 run 内一致**的尺寸键复用,审计修复 #3:用 targetForName 取该名
            // 首次出现时解析的尺寸,而非每 pass 重算 scale,避免同名 FBO 在不同 scale 间取错块、断反馈链);
            // 无 target(最终输出)→ 每次新建,避免多图层共享被覆盖。
            let out: MTLTexture
            // R5:unique 累积缓冲若已在 rtPool(跑过≥1帧,本 run 预填进 named)→ loadAction=.load 保留上一帧累积,
            // 不 clear(motionblur 的 _rt_FullCompoBuffer / fluidsim 速度·压力·dye 场跨帧累积)。首帧未初始化 → 仍 clear。
            var loadAction: MTLLoadAction = .clear
            if let target = p.target {
                guard let t = targetForName(target) else { continue }
                out = t
                if nameUnique.contains(target), named[target] != nil { loadAction = .load }
            } else {
                guard let t = makeTarget(width: w, height: h) else { continue }   // 最终输出恒全分辨率
                out = t
            }

            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = out
            pass.colorAttachments[0].loadAction = loadAction
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { continue }
            enc.setRenderPipelineState(ps)
            enc.setVertexBuffer(quadBuf, offset: 0, index: 1)

            // 该 pass 的主输入(g_Texture0 绑定的纹理)。分辨率 uniform(g_TexelSize/g_Texture0Resolution)
            // 必须反映**实际绑定的**纹理尺寸,而非恒定的输入尺寸 —— blur 采样 1/4 图,步长才对。
            let primaryName = p.bind.first(where: { $0.index == 0 })?.name ?? "previous"
            let primary = named[primaryName] ?? input
            let resW = primary.width, resH = primary.height

            // 逐 pass 参数优先(bloom 各 pass strength 可不同);否则合并版。
            let params: [String: Any] = (pi < paramsPerPass.count) ? paramsPerPass[pi] : pkgParams
            var vu = buildUniforms(vstage, meta: p.uniformMeta, pkgParams: params, time: time, cursor: cursor, texW: resW, texH: resH, sceneW: sceneW, sceneH: sceneH, audio: audio, auxResolutions: auxResolutions, pointerXform: pointerXform)
            var fu = buildUniforms(fstage, meta: p.uniformMeta, pkgParams: params, time: time, cursor: cursor, texW: resW, texH: resH, sceneW: sceneW, sceneH: sceneH, audio: audio, auxResolutions: auxResolutions, pointerXform: pointerXform)
            // 大 UBO 走 MTLBuffer:setVertex/FragmentBytes 适合小块常量数据,实测本机对 ~3.6KB 的 UBO 上传会丢数据
            //   (audio_base 的 g_AudioSpectrum16/32/64 Left/Right 全段 → frag UBO 3664 字节,用 setFragmentBytes 后
            //    shader 读到的频谱恒 0、音频线完全不动;改 makeBuffer+setBuffer 后正常响应)。audioline(2112 字节)
            //   仍 OK,但统一以 2048 字节为界:超过即用 MTLBuffer(Metal 持有到命令缓冲完成,安全),小块仍走 setBytes 省分配。
            if vu.count > 2048, let vb = device.makeBuffer(bytes: &vu, length: vu.count, options: .storageModeShared) {
                enc.setVertexBuffer(vb, offset: 0, index: vstage.ubuf)
            } else {
                enc.setVertexBytes(&vu, length: vu.count, index: vstage.ubuf)
            }
            if fu.count > 2048, let fbuf = device.makeBuffer(bytes: &fu, length: fu.count, options: .storageModeShared) {
                enc.setFragmentBuffer(fbuf, offset: 0, index: fstage.ubuf)
            } else {
                enc.setFragmentBytes(&fu, length: fu.count, index: fstage.ubuf)
            }

            // 输入纹理:g_Texture0 = 主输入;g_TextureN(N>0)= 命名 bind(如 apply 的 g_Texture2=previous)
            // 或 auxTextures(mask 等);缺省 util 默认贴图,再缺省退白(效果全开)。
            for s in fstage.samplers {
                let tex: MTLTexture
                var flags: TexFlags? = nil    // 真实 WE 纹理 flags → samplerFor 选采样器;nil = clamp+linear(保守)
                let isMaskSampler = (p.uniformMeta[s.name]?.combo == "MASK")
                if s.name == "g_Texture0" { tex = primary; flags = texFlags[s.name] }
                // 审计修复 #2:绑定命名 FBO 前先校验该 bind 的 conditions(如 fluidsimulation 的
                // {'index':2,'conditions':[{'LIGHTING':1}]} / {'index':4,'conditions':[{'RENDERING':3}]})。
                // 仅当当前 combo 满足 conditions 才绑该块;否则跳过此 bind,让槽落到后续兜底(util/白)分支
                // —— 与 WE 一致(条件不满足时该采样源不参与,而非绑错块导致 lighting/rendering 分支取脏数据)。
                else if let b = p.bind.first(where: { "g_Texture\($0.index)" == s.name
                        && Self.conditionsMet($0.conditions, comboInts: comboInts) }),
                        let t = named[b.name] { tex = t }
                    // 命名 FBO / previous:引擎渲出的全屏纹理,UV∈[0,1],flags 保持 nil(clamp+linear)。
                else if isMaskSampler, let mask = maskTexture { tex = mask; flags = texFlags[s.name] }   // opacitymask → 据 manifest 定位的 MASK 槽
                else if let aux = auxTextures[s.name] { tex = aux; flags = texFlags[s.name] }
                else if let def = p.uniformMeta[s.name]?.default?.value as? String, def.hasPrefix("_rt_"), let fb = frameBuffer {
                    // WE 渲染目标(如 frame_builder 的 g_Texture3 = backgroundTexture 默认 _rt_FullFrameBuffer
                    // = 整帧合成缓冲)。喂引擎合成好的「该层之下场景」底图(屏幕UV采样),否则退白 → 边框外全白。
                    tex = fb
                }
                else if s.name == "g_Texture2", comboInts["RENDERING"] == 1,
                        ProcessInfo.processInfo.environment["WP_NO_LIGHTSHAFT_COLOR"] == nil,
                        !p.bind.contains(where: { "g_Texture\($0.index)" == s.name }),
                        let ceStr = params["colorend"] as? String {
                    // ⭐lightshafts RENDERING=1(gradient 模式)颜色取自 g_Texture2 渐变图。真 WE 编辑器把作者设的
                    //   colorastart→colorend **烘进**这张渐变图;lwe(及我们)却绑死静态 `gradient_iridescent`(彩虹)
                    //   → 丢了 pkg 的 colorastart"1 1 1"→colorend(凯尔希"0.435 0.886 1"=青)→ 光束渲成彩虹紫青而非白→青。
                    //   仅当作者**显式设了 colorend**(params 含)时,合成 colorastart→colorend 的 1D 渐变图喂 g_Texture2
                    //   (作用域:g_Texture2 + RENDERING=1 + 无自定义绑定 → 不影响其他特效/未自定义颜色的 lightshafts)。
                    //   WP_NO_LIGHTSHAFT_COLOR=1 退回静态彩虹图(A/B)。
                    let cs = Self.parseFloats((params["colorastart"] as? String) ?? "1 1 1")
                    let ce = Self.parseFloats(ceStr)
                    tex = lightshaftRamp(start: cs, end: ce) ?? whiteTex
                    flags = nil
                }
                else if let def = p.uniformMeta[s.name]?.default?.value as? String, def.contains("/") {
                    // 采样器默认贴图:WE 内置 ref(util/noise|white|black、particle/halo_6 等)。
                    // 关键:不限 util/——xray 的 sprite 默认是 particle/halo_6,缺它则 g_Texture2 退白
                    //   → blend 不再被 halo 限定 → 揭示作用于整图(而非光标处一圈)。
                    //   utilTexture 经 BuiltinAssets 解析 materials/<ref>.tex,缺失自身退白,安全。
                    let u = utilTexture(def)
                    tex = u.tex
                    // 采样器按贴图**真实 flags** 选(取代旧 isTilingRef 名字猜):可平铺噪声(util/noise 等)
                    // 的 .tex 头本就无 ClampUVs → repeat 环绕(filmgrain 按 g_NoiseScale 放大采样不出网格黑线);
                    // 精灵/white/black 带 ClampUVs → clamp。
                    flags = u.flags
                }
                else { tex = whiteTex }           // 兜底(缺省 mask)→ 白(效果全开)
                enc.setFragmentTexture(tex, index: s.texIndex)
                enc.setFragmentSamplerState(samplerFor(flags), index: s.sampIndex)
            }
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            enc.endEncoding()

            if let target = p.target { named[target] = out }   // 命名 FBO 供后续 pass bind;"previous" 恒=输入图
            lastOut = out
        }
        return lastOut
    }
}

/// 极简 AnyCodable(只为读 manifest 里的 default 值:数字或字符串)。
struct AnyCodable: Codable {
    let value: Any?
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let d = try? c.decode(Double.self) { value = d }
        else if let s = try? c.decode(String.self) { value = s }
        else if let b = try? c.decode(Bool.self) { value = b }
        else { value = nil }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        if let d = value as? Double { try c.encode(d) }
        else if let s = value as? String { try c.encode(s) }
        else { try c.encodeNil() }
    }
}
