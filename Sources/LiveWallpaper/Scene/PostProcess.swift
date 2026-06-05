import Metal
import simd

/// 相机级 bloom(general.bloom)的后处理。**照 linux-wallpaperengine 的真 bloom 链逐 pass 移植**:
/// lwe 把 WE 相机 bloom 实现为一个跑 4 个 WE util 材质的合成对象(WallpaperApplication.cpp:106-132
/// 的 vfs `effects/wpenginelinux/bloomeffect.json` + CScene.cpp:135-151 的 _rt_4/_rt_8/_rt_Bloom FBO)。
/// 这 4 个材质/着色器全是 WE 自带真文件($WE/materials/util + $WE/shaders),非自造:
///   ① downsample_quarter_bloom : _rt_FullFrameBuffer(全分辨率)→ _rt_4FrameBuffer(¼)
///        2×2 box 降采样 + 亮度阈值(saturate(maxc-threshold))+ 饱和度提升 + ×strength×tint。
///   ② downsample_eighth_blur_v : ¼ → _rt_8FrameBuffer(⅛),沿 X 13-tap 高斯(步长 g_TexelSize.x×8)。
///   ③ blur_h_bloom            : ⅛ → _rt_Bloom(⅛),沿 Y 13-tap 高斯(步长 g_TexelSize.y×8)。
///   ④ combine                 : 原场景 + _rt_Bloom → 输出(albedo += bloom)。
/// g_TexelSize = 1/源纹理尺寸(与 WEEffectChain 一致)。FBO 格式 8-bit(对应 lwe ARGB8888,LDR clamp)。
/// 仅当 postChain 为空(相机级 bloom 进不了 manifest/postChain)时由 SceneRenderEngine 启用。
final class PostProcess {
    struct Params {
        var bloom = false
        var bloomThreshold: Float = 0.65   // downsample_quarter_bloom.frag 注解默认
        var bloomStrength: Float = 2.0     // 同上
        var bloomTint: SIMD3<Float> = SIMD3(1, 1, 1)
    }
    var params = Params()
    var enabled: Bool { params.bloom }

    private let device: MTLDevice
    private let sampler: MTLSamplerState
    private let quad: MTLBuffer
    private var w = 0, h = 0
    private var sceneTex: MTLTexture?      // 全分辨率场景(= _rt_FullFrameBuffer)
    private var rt4: MTLTexture?           // ¼ 分辨率(_rt_4FrameBuffer)
    private var rt8: MTLTexture?           // ⅛(_rt_8FrameBuffer)
    private var rtBloom: MTLTexture?       // ⅛(_rt_Bloom)
    private var quarterPipe: MTLRenderPipelineState!
    private var blurPipe: MTLRenderPipelineState!
    private var combinePipe: MTLRenderPipelineState!

    init?(device: MTLDevice, sampler: MTLSamplerState, quad: MTLBuffer) {
        self.device = device; self.sampler = sampler; self.quad = quad
        do { try buildPipelines() } catch { Log.write("PostProcess: pipeline fail \(error)"); return nil }
    }

    /// 提供/重建与 drawable 同尺寸的离屏场景纹理(主 pass 渲染目标),并按需重建 ¼/⅛ 中间 FBO。
    func sceneTarget(width: Int, height: Int) -> MTLTexture? {
        if w != width || h != height || sceneTex == nil {
            w = width; h = height
            sceneTex = makeRT(width, height)
            rt4 = makeRT(max(1, width / 4), max(1, height / 4))
            let ew = max(1, width / 8), eh = max(1, height / 8)
            rt8 = makeRT(ew, eh)
            rtBloom = makeRT(ew, eh)
        }
        return sceneTex
    }

    /// sceneTex 已渲染好后调用:跑 lwe 真 bloom 4-pass,最终输出到 output(drawable)。
    func run(commandBuffer cmd: MTLCommandBuffer, output: MTLTexture) {
        guard params.bloom, let scene = sceneTex, let q = rt4, let e8 = rt8, let bloom = rtBloom else { return }

        // ① downsample_quarter_bloom:全分辨率场景 → ¼。g_TexelSize = 1/源(全分辨率)。
        drawPass(cmd, into: q, pipeline: quarterPipe, src: scene) { enc in
            var u = SIMD4<Float>(1.0 / Float(max(1, self.w)), 1.0 / Float(max(1, self.h)),
                                 self.params.bloomThreshold, self.params.bloomStrength)
            enc.setFragmentBytes(&u, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            var tint = SIMD4<Float>(self.params.bloomTint.x, self.params.bloomTint.y, self.params.bloomTint.z, 0)
            enc.setFragmentBytes(&tint, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
        }
        // ② downsample_eighth_blur_v:¼ → ⅛,沿 X。localTexel = (1/源¼).x × 8。
        drawPass(cmd, into: e8, pipeline: blurPipe, src: q) { enc in
            var dir = SIMD2<Float>((1.0 / Float(max(1, q.width))) * 8.0, 0)
            enc.setFragmentBytes(&dir, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
        }
        // ③ blur_h_bloom:⅛ → _rt_Bloom,沿 Y。localTexel = (1/源⅛).y × 8。
        drawPass(cmd, into: bloom, pipeline: blurPipe, src: e8) { enc in
            var dir = SIMD2<Float>(0, (1.0 / Float(max(1, e8.height))) * 8.0)
            enc.setFragmentBytes(&dir, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
        }
        // ④ combine:原场景 + _rt_Bloom → output(bloom ⅛ 由线性采样上采样,同 WE)。
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = output
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.setRenderPipelineState(combinePipe)
        enc.setVertexBuffer(quad, offset: 0, index: 0)
        enc.setFragmentTexture(scene, index: 0)
        enc.setFragmentTexture(bloom, index: 1)
        enc.setFragmentSamplerState(sampler, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
    }

    private func drawPass(_ cmd: MTLCommandBuffer, into dst: MTLTexture,
                          pipeline: MTLRenderPipelineState, src: MTLTexture,
                          _ setUniforms: (MTLRenderCommandEncoder) -> Void) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = dst
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.setRenderPipelineState(pipeline)
        enc.setVertexBuffer(quad, offset: 0, index: 0)
        enc.setFragmentTexture(src, index: 0)
        enc.setFragmentSamplerState(sampler, index: 0)
        setUniforms(enc)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
    }

    private func makeRT(_ w: Int, _ h: Int) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]; d.storageMode = .private
        return device.makeTexture(descriptor: d)
    }

    private func buildPipelines() throws {
        let lib = try device.makeLibrary(source: Self.shaderSource, options: nil)
        func make(_ ffn: String) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: "pp_vertex")
            d.fragmentFunction = lib.makeFunction(name: ffn)
            d.colorAttachments[0].pixelFormat = .bgra8Unorm
            return try device.makeRenderPipelineState(descriptor: d)
        }
        quarterPipe = try make("pp_bloom_quarter")
        blurPipe    = try make("pp_bloom_blur")
        combinePipe = try make("pp_bloom_combine")
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;
    struct VOut { float4 position [[position]]; float2 uv; };
    vertex VOut pp_vertex(uint vid [[vertex_id]], const device float4* v [[buffer(0)]]) {
        VOut o; float4 q = v[vid];
        o.position = float4(q.xy * 2.0, 0, 1);   // 单位 quad([-0.5,0.5]) → 全屏
        o.uv = q.zw;
        return o;
    }

    // ① downsample_quarter_bloom.frag(逐行照搬):4-tap box 平均 + 亮度阈值 + 饱和度提升 + ×strength×tint。
    // u = (texelSize.x, texelSize.y, threshold, strength);tint.xyz。texelSize = 1/源(全分辨率)。
    fragment float4 pp_bloom_quarter(VOut in [[stage_in]], texture2d<float> t [[texture(0)]],
                                     sampler s [[sampler(0)]],
                                     constant float4& u [[buffer(0)]], constant float4& tint [[buffer(1)]]) {
        float2 ts = u.xy;
        float3 albedo = t.sample(s, in.uv - ts).rgb
                      + t.sample(s, in.uv + ts).rgb
                      + t.sample(s, in.uv + float2(-ts.x, ts.y)).rgb
                      + t.sample(s, in.uv + float2(ts.x, -ts.y)).rgb;
        albedo *= 0.25;
        float scale = max(max(albedo.x, albedo.y), albedo.z);
        albedo *= saturate(scale - u.z);                 // u.z = threshold
        float grayscale = dot(float3(0.2989, 0.5870, 0.1140), albedo);
        float sat = 1.0;
        albedo = -grayscale * sat + albedo * (1.0 + sat);
        return float4(max(float3(0.0), albedo * u.w * tint.xyz), 1.0);   // u.w = strength
    }

    // ②③ 13-tap 高斯(downsample_eighth_blur_v / blur_h_bloom 同权重,仅方向不同)。
    // dir = 单步偏移向量(= g_TexelSize.{x|y}×8 沿对应轴);第 n tap 偏移 (n-6)×dir。
    fragment float4 pp_bloom_blur(VOut in [[stage_in]], texture2d<float> t [[texture(0)]],
                                  sampler s [[sampler(0)]], constant float2& dir [[buffer(0)]]) {
        const float w[13] = { 0.006299, 0.017298, 0.039533, 0.075189, 0.119007, 0.156756,
                              0.171834, 0.156756, 0.119007, 0.075189, 0.039533, 0.017298, 0.006299 };
        float3 albedo = float3(0.0);
        for (int i = 0; i < 13; i++) {
            albedo += t.sample(s, in.uv + dir * float(i - 6)).rgb * w[i];
        }
        return float4(albedo, 1.0);
    }

    // ④ combine.frag:原场景 + bloom。
    fragment float4 pp_bloom_combine(VOut in [[stage_in]],
                                     texture2d<float> scene [[texture(0)]],
                                     texture2d<float> bloom [[texture(1)]],
                                     sampler s [[sampler(0)]]) {
        float3 albedo = scene.sample(s, in.uv).rgb;
        albedo += bloom.sample(s, in.uv).rgb;
        return float4(albedo, 1.0);
    }
    """
}
