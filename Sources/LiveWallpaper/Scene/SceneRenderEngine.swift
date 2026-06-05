import Metal
import MetalKit
import MetalFX
import simd
import CoreGraphics
import Foundation

// MARK: - 矩阵工具

private func matOrtho(width: Float, height: Float) -> simd_float4x4 {
    // WE 场景空间 y 向上(相机 up=+y),原点在画布中心附近,坐标≈像素。
    // x:[0,W]→[-1,1]   y:[0,H]→[-1,1](y 向上)
    return simd_float4x4(columns: (
        SIMD4(2 / width, 0, 0, 0),
        SIMD4(0, 2 / height, 0, 0),
        SIMD4(0, 0, 1, 0),
        SIMD4(-1, -1, 0, 1)
    ))
}

private func matModel(centerPx: SIMD2<Float>, sizePx: SIMD2<Float>, angleDegZ: Float) -> simd_float4x4 {
    // ⚠ angleDegZ 名字是历史误称——WE 的 angles 单位其实是**弧度**(lwe CImage.cpp:1083
    // "already in radians from scene.json";glm::rotate 取弧度),不是角度!之前 ×π/180 当成
    // 角度 → 旋转几乎为 0(时钟 0.111rad=6.4° 被当 0.11° 几乎不转 → 时钟没斜)。
    // **符号:直接用弧度正值**(我们 matModel 是标准 CCW +a,与 WE 一致)。曾照搬 lwe 的
    // glm::rotate(-angle) 取负 → 方向反了(用户实测);lwe 的负号是它自身坐标系的补偿,不适用我们。
    let a = angleDegZ
    let c = cos(a), s = sin(a)
    // translate * rotateZ * scale(size)   —— 单位 quad 顶点范围 [-0.5,0.5]
    let sx = sizePx.x, sy = sizePx.y
    return simd_float4x4(columns: (
        SIMD4( c * sx,  s * sx, 0, 0),
        SIMD4(-s * sy,  c * sy, 0, 0),
        SIMD4( 0,       0,      1, 0),
        SIMD4(centerPx.x, centerPx.y, 0, 1)
    ))
}

/// 2D 向量绕 z 角(弧度)旋转。与 SceneModel.resolveTransform 的 rotateVec2 / CImage.cpp:28-32 逐式相同,
/// 也与 matModel 旋转(标准 CCW:x'=c·x−s·y, y'=s·x+c·y)同向。angle=0 → 恒等(父角=0 时 origin 脚本零变化)。
private func rotateVec2(_ v: SIMD2<Float>, _ angle: Float) -> SIMD2<Float> {
    let c = cos(angle), s = sin(angle)
    return SIMD2(v.x * c - v.y * s, v.x * s + v.y * c)
}

/// 文本图层盒子适配:WE 文本层有显式 size(画布单位),屏上尺寸 = box = size×scale。
/// 文本纹理(texW×texH 像素)按其字形纵横比适配进 box(以高度为主,过宽则改以宽度为主,不拉伸),
/// 得到屏上 quad 尺寸 (quadW×quadH);quad 可能小于 box,据 horizontalalign/verticalalign 在 box 内放置,
/// 返回相对 origin(box 中心)的中心偏移。WE 场景空间 y 向上:vertical top = box 上半(+y)。
private func textQuad(texW: Float, texH: Float, box: SIMD2<Float>,
                      hAlign: String, vAlign: String)
    -> (size: SIMD2<Float>, centerOffset: SIMD2<Float>) {
    guard texW > 0, texH > 0, box.x > 0, box.y > 0 else { return (box, .zero) }
    let texAspect = texW / texH
    // 按**高度**适配(quadH = box.y),宽度随字形纵横比、可溢出盒子 —— 照 lwe:文字尺寸由 pointSize×scale
    // (高度)决定,盒子 size 只用于对齐/换行参考,**不缩字号**。曾用"过宽改按宽度适配"(我方自创)→ 对
    // 极扁宽的日期盒子(如 1679×162×0.252)把行高坍缩成 ~27px 细线 → 看不清。去掉宽度坍缩、让宽度自然溢出。
    let quadH = box.y
    let quadW = quadH * texAspect
    // box 内对齐:多余空间按 align 推到一侧(center→0)。
    var ox: Float = 0, oy: Float = 0
    switch hAlign.lowercased() {
    case "left":  ox = -(box.x - quadW) * 0.5
    case "right": ox =  (box.x - quadW) * 0.5
    default: break    // center
    }
    switch vAlign.lowercased() {
    case "top":    oy =  (box.y - quadH) * 0.5    // y 向上:顶 = +y
    case "bottom": oy = -(box.y - quadH) * 0.5
    default: break    // center
    }
    return (SIMD2(quadW, quadH), SIMD2(ox, oy))
}

// MARK: - 每图层 GPU 资源

private struct GPULayer {
    var id: Int = 0   // pkg 对象 id(诊断:WP_HIDE_IDS 按 id 隐藏图层,定位遮挡者)
    var texture: MTLTexture
    var baseModel: simd_float4x4 // 世界变换(不含投影、不含视差)
    var mvp: simd_float4x4       // 每帧 = proj * translate(视差) * baseModel
    var color: SIMD4<Float>
    var blend: BlendMode
    var colorBlendMode: Int = 0   // 对象级 colorBlendMode(>0 → framebuffer-fetch 方程混合,见 scene_fragment_blend)
    var origin: SIMD2<Float>
    var parallax: SIMD2<Float>   // parallaxDepth:视差响应强度
    var sizePx: SIMD2<Float>
    var video: VideoTexture? = nil   // 视频纹理(动态贴图);非 nil 时每帧刷新 texture
    var effects: [LayerEffect] = []  // 图层后处理效果链
    var text: TextLayerState? = nil  // 文本图层(时钟/日期);非 nil 时按秒刷新纹理
    var textBox: SIMD2<Float>? = nil // 文本盒子(已乘 scale,画布单位):非 nil → 屏上尺寸按字形纵横比
                                     // 适配进此盒子(WE size×scale 行为);nil → autosize×scale(旧)。
    var textCenterOffset: SIMD2<Float> = .zero  // 盒子内对齐产生的中心偏移(相对 origin)。
    var audioBars: AudioBarsDesc? = nil   // 音频频谱条;非 nil 时每帧按音频重画纹理
    var effectMask: MTLTexture? = nil   // 主层水面遮罩(cursorripple 折射限定用,取首个遮罩)
    var effectMasks: [MTLTexture?] = []  // **逐特效**遮罩(与 effects 对齐);各 effect 用自己的 opacitymask
    var effectAux: [[Int: MTLTexture]] = []  // **逐特效**全部辅助贴图(与 effects 对齐):slot→纹理。
                                             // 喂给 WEEffectChain 的 g_Texture<slot>(opacitymask/法线/相位/流向等)。
    var texFlags: TexFlags? = nil            // 图层贴图的真实 WE flags(主 pass + 特效 g_Texture0 采样器)
    var effectMaskFlags: [TexFlags?] = []    // **逐特效**遮罩贴图 flags(与 effects 对齐)
    var effectAuxFlags: [[Int: TexFlags]] = []  // **逐特效**辅助贴图 flags(slot→flags,与 effects 对齐)
    var useWE = false                   // 该层有任一可跑的真 WE 特效 → 跑 WEEffectChain 产出 effectedTexture
    var frameBufferInput = false        // composelayer/_rt_FullFrameBuffer:特效链输入=下方已合成整帧场景(打雷等)
    var regionFit = false               // 区域性 composelayer(非 pulse):特效在该层 region [0,1] 跑(裁场景+遮罩到 region);encode 用普通 UV 贴回。pulse=false 走全屏画布 UV(不动)。
    var effectedTexture: MTLTexture? = nil   // 每帧由 WEEffectChain 产出的特效后纹理
    var materialShader: String? = nil        // 基础材质 shader(genericimage2/3/4),供转译材质渲染路径
    var materialCombos: [String: String] = [:]  // 材质 pass0 combos(有意义者走转译路径)
    var materialConstants: [String: [Float]] = [:]  // 材质 constantshadervalues(PBR 量,喂转译 shader)
    // puppet 网格(多部件角色部件):非矩形 bind-pose 几何替代平面 quad。非 nil 时按索引三角网格画。
    // 顶点是**单位空间** [x,y,u,v]×N(rawX/size, −rawY/size),用 layer.mvp(proj×matModel) 直渲场景(照 lwe)。
    var puppetVB: MTLBuffer? = nil
    var puppetIB: MTLBuffer? = nil          // u16 索引
    var puppetIndexCount: Int = 0
    // puppet 骨骼蒙皮动画(MDLS 骨骼 + MDLA 动画):非 nil 且 hasSkin 时,update() 每帧求值动画→蒙皮→更新 puppetVB。
    var puppetMesh: PuppetMesh? = nil
    var puppetAnimId: Int = 0               // animationlayers[].animation(对应 MDLA 动画 id)
    var puppetAnimRate: Float = 1           // animationlayers[].rate(播放速率)
    // scale 字段挂的 WE JS 脚本(如 "Second" 秒进度条):每帧跑脚本得新 scale → 重建 baseModel。
    var scaleScript: WEScript? = nil
    var baseSize: SIMD2<Float> = .zero       // 未乘 scale 的尺寸(autosize 后的纹理像素尺寸 / 显式 size)
    var baseScale: SIMD3<Float> = SIMD3(1, 1, 1)  // 脚本 update(value) 的输入基准
    var baseAngleZ: Float = 0
    // origin 字段挂的 WE JS 脚本(挂件容器/时钟/日期/鼠标指针):每帧跑脚本得新**局部** origin →
    //   绝对 origin = parentAbsOrigin + parentAbsScale × 局部 origin → 重建 baseModel/mvp。
    // nil 时 origin 恒为初始值(绝大多数图层零变化)。
    var originScript: WEScript? = nil
    var baseLocalOrigin: SIMD3<Float> = .zero      // 脚本 update(value) 的 value 初值(裸 .value)
    var parentAbsOrigin: SIMD3<Float> = .zero      // 父链(不含自身)累积绝对 origin
    var parentAbsScale: SIMD3<Float> = SIMD3(1, 1, 1)  // 父链(不含自身)累积绝对缩放
    var parentAbsAngle: Float = 0                  // 父链(不含自身)累积 z 角(弧度,#2)。父角=0 → rotateVec2 恒等。
    // angles 字段挂的 WE JS 脚本(#3:zRotation 等):每帧得新**局部** z 角 → baseAngleZ = parentAbsAngle + 局部 z → 重建 baseModel。
    var angleScript: WEScript? = nil
    var baseLocalAngles: SIMD3<Float> = .zero      // 脚本 update(value) 的 value 初值(裸 .value)
    // 对象 origin/angles 字段的 WE 关键帧动画(头发/发饰随头摆动)。每帧求值 → 局部值 → 父链变换 → origin/baseAngleZ → 重建 baseModel。
    var originKeyAnim: WEKeyframeAnimation? = nil
    var angleKeyAnim: WEKeyframeAnimation? = nil
    // 缺口B/D:visible/alpha/color 字段挂的 WE JS 脚本(每帧 reevaluate;无脚本则 nil)。
    var visibleScript: WEScript? = nil
    var alphaScript: WEScript? = nil
    var colorScript: WEScript? = nil
    // 每帧由 visibleScript 更新的显隐(无脚本恒 = 静态初值,绝大多数为 true)。绘制门控用。
    var visible: Bool = true
}

/// 文本图层运行态:描述 + 上次渲染的字符串(变了才重渲染,省开销)。
private final class TextLayerState {
    let desc: TextLayerDesc
    var lastString: String
    init(desc: TextLayerDesc, lastString: String) { self.desc = desc; self.lastString = lastString }
}

/// 传给 fragment shader 的合成数据(主 pass)。特效本身已由真 WE shader 链(WEEffectChain)
/// 跑进 effectedTexture;这里只负责把结果贴上 + 可选的鼠标水波折射 combine(cursorripple)。
private struct EffectUniforms {
    var time: Float = 0
    var hasMask: Int32 = 0                      // 是否有水面遮罩(cursorripple 折射仅作用于遮罩白区)
    var cursorRipple: Int32 = 0                 // 是否对本图层应用鼠标水波折射(combine)
    var rippleStrength: Float = 1               // cursorripple combine 折射强度(material ripplestrength)
}
// 单层最多跑这么多真 WE 特效(逐个全屏 pass 链;实测最深图层 ~8 个,留余量)。
private let kMaxLayerEffects = 12

private func matTranslate(_ x: Float, _ y: Float) -> simd_float4x4 {
    simd_float4x4(columns: (
        SIMD4(1, 0, 0, 0),
        SIMD4(0, 1, 0, 0),
        SIMD4(0, 0, 1, 0),
        SIMD4(x, y, 0, 1)
    ))
}

private struct VertexUniforms { var mvp: simd_float4x4; var color: SIMD4<Float>; var fb: SIMD4<Int32> = SIMD4(0, 0, 0, 0) }

/// 一组粒子(一个发射器):模拟器 + 纹理 + 实例缓冲。
private final class ParticleGroup {
    let sim: ParticleSimulator
    let texture: MTLTexture
    let additive: Bool
    let isRefract: Bool             // 折射粒子(玻璃雨滴):照 WE 采样场景底图,单独 pass 绘制
    let isRope: Bool                // rope/ropetrail:连成 Catmull-Rom 带状网格(非散点精灵)
    let normalTexture: MTLTexture?  // 法线贴图(textures[1]),折射偏移用
    let aboveBloom: Bool            // 排在后处理层之上 → 在 bloom 之后叠加(不被 bloom),照 WE 图层序
    // 审计修复#2:每组持 3 套实例/rope 缓冲轮换(原来跨帧复用同一块、每帧 copyMemory 覆写 → GPU 可能仍在
    //   读上一帧)。配合 render() 的 DispatchSemaphore(value:3) 限流,CPU 改写第 N 套时 GPU 已读完它。
    var instanceBuffers: [MTLBuffer?] = [nil, nil, nil, nil]
    var instanceCount: Int = 0
    var ropeBuffers: [MTLBuffer?] = [nil, nil, nil, nil]   // rope 带状三角形顶点(每帧重建,4 套轮换)
    var ropeVertexCount: Int = 0
    init(sim: ParticleSimulator, texture: MTLTexture, additive: Bool,
         isRefract: Bool = false, isRope: Bool = false, normalTexture: MTLTexture? = nil, aboveBloom: Bool = false) {
        self.sim = sim; self.texture = texture; self.additive = additive
        self.isRefract = isRefract; self.isRope = isRope
        self.normalTexture = normalTexture; self.aboveBloom = aboveBloom
    }
}

/// 粒子组的渲染分类信息(供 encode 的过滤闭包用,避免暴露内部 ParticleGroup)。
struct ParticleGroupInfo { let aboveBloom: Bool }

/// 把一个 SceneDocument 编译成 GPU 资源,并能渲染到任意 drawable 或离屏纹理。
final class SceneRenderEngine {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private var pipelineNormal: MTLRenderPipelineState!
    private var pipelineTranslucent: MTLRenderPipelineState!
    private var pipelineAdditive: MTLRenderPipelineState!
    private var pipelineColorBlend: MTLRenderPipelineState?        // colorBlendMode 层:framebuffer-fetch 方程混合
    private var pipelineParticleAdd: MTLRenderPipelineState?
    private var pipelineParticleAlpha: MTLRenderPipelineState?
    private var pipelineParticleRefract: MTLRenderPipelineState?      // 折射粒子(采样场景底图,translucent 混合)
    private var pipelineParticleRefractAdd: MTLRenderPipelineState?   // 折射粒子 additive 混合(如水花 halo,材质 blending:additive)
    private var pipelineRopeAdd: MTLRenderPipelineState?           // rope 带状网格(加性)
    private var pipelineRopeAlpha: MTLRenderPipelineState?         // rope 带状网格(透明)
    private var pipelineBlit: MTLRenderPipelineState?              // 全屏拷贝(折射 pass 先铺底图)
    private var pipelineBlitFXAA: MTLRenderPipelineState?          // FXAA 呈现(画质设置开时用)
    private var renderScaleTex: MTLTexture?                        // render-scale/MetalFX 的低分辨率编码目标
    private var mfxScaler: (any MTLFXSpatialScaler)?               // MetalFX 空间放大器(按输入/输出尺寸缓存)
    private var mfxKey: String = ""                               // scaler 的尺寸键(变了就重建)
    private var refractSceneTex: MTLTexture?                       // 折射用:层+非折射粒子的离屏底图
    private var sceneBelowForEffects: MTLTexture?                  // frame_builder 等整帧底图特效用:该层之下已合成场景
    private var ndcScale = SIMD2<Float>(1, 1)                      // 画布↔屏幕宽高比适配(cover:填满+裁切,不拉伸)
    private var weEffects: WEEffectChain?                          // 转译特效引擎(真 WE shader)
    // in-engine 路径已调通。默认:manifest 里有的 effect 都走真 WE shader,除 denylist:
    //  - cursorripple:已有专门的 3-pass 流体模拟(CursorRippleSim),走 projectlayer 路径,不用这条。
    // godrays/depthparallax/xray 曾在此 denylist(均「洗白」),现已修真因并移除:
    //  - godrays:pass[0] downsample 的 vert/frag 因 NOISE [COMBO] 默认只声明在 frag、vert 未取 →
    //    顶点输出缺 v_NoiseTexCoord、片元却要 → makeRenderPipelineState 抛错、整 pass 被跳过 →
    //    阈值/遮罩 pass 不写 → cast 读未初始化 buffer 糊白。修:transpiler 并 vert+frag 的 [COMBO] 默认
    //    (we_build_effects.build_effect_passes),pass 两 stage 用同一套 combo。
    //  - depthparallax/xray:WEEffectChain 未喂交互 pointer + EffectTextureProjection 矩阵 →
    //    vert 里 normalize(vec2(0)) 出 NaN / 揭示作用于整图。修:buildUniforms 补 g_PointerPosition/
    //    g_ParallaxPosition(=真实光标 UV,静止 0.5 中性)+ g_EffectTextureProjectionMatrix(Inverse)=identity
    //    (平面层真值,非兜底)+ g_Screen;sprite 默认贴图(particle/halo_6)按 builtin ref 加载(不止 util/)。
    //  - 另修关键 pipeline 缓存 bug:原按 p.shader 缓存,同 shader 不同 combo 变体(depthparallax 的
    //    QUALITY-1 vs MASK-1_QUALITY-1)采样器布局不同却复用首个 → g_Texture0 取到白兜底槽 → 洗白。
    //    改按变体 MSL 文件名缓存。
    // frame_builder 已解禁(2026-06-01):曾因「跑在满画布图层上整层冲白」denylist;真因不是缺 frame
    // 尺寸/颜色 uniform,而是 vert 的 g_LayerModelMatrix / g_EffectModelViewProjectionMatrix 未绑(留 0)
    // → scale=length(0)=0 → v_Size 塌成「整面都是边框」+ g_Texture3(_rt_FullFrameBuffer 背景)退白。
    // 修:buildUniforms 给这两个矩阵喂 identity(满画布轴对齐层真值),并新增整帧底图通道——runLayerEffects
    // 把「该层之下已合成场景」composite 进 sceneBelowForEffects 喂 g_Texture3。3713659808/3713073223 均
    // 无冲白、忠实(边框逻辑用真 scene-below 背景)。详见 buildUniforms / compositeSceneBelow。
    static var weDenied: Set<String> {
        // WP_ALLOW_FX(逗号分隔 weName)可临时解禁;WP_DENY_FX 可临时再禁(回归对比用)。未设时仅 cursorripple。
        var base: Set<String> = ["cursorripple"]
        base.formUnion((ProcessInfo.processInfo.environment["WP_DENY_FX"] ?? "").split(separator: ",").map(String.init))
        let allow = Set((ProcessInfo.processInfo.environment["WP_ALLOW_FX"] ?? "").split(separator: ",").map(String.init))
        return base.subtracting(allow)
    }
    // 诊断:WP_SKIP_FX=blur,godrays,... 跳过指定 weName 特效,用于二分定位是哪个特效产生了画面瑕疵
    // (与 --warmrender / WP_TEST_BANDS 同类调试钩子;未设环境变量时为空集、零开销)。
    static let fxSkip: Set<String> = Set((ProcessInfo.processInfo.environment["WP_SKIP_FX"] ?? "").split(separator: ",").map(String.init))
    private let sampler: MTLSamplerState               // clamp + linear(默认/通用)
    private var samplerRepeat: MTLSamplerState!         // repeat + linear:WE 默认 wrap(无 ClampUVs flag)
    private var samplerNearest: MTLSamplerState!        // clamp  + nearest(NoInterpolation + ClampUVs)
    private var samplerRepeatNearest: MTLSamplerState!  // repeat + nearest(NoInterpolation,无 ClampUVs)
    private let quadBuffer: MTLBuffer

    /// 按图层贴图真实 flags 选主 pass 采样器。flags=nil(纯色/文本/视频/音频条等无 .tex flags)→
    /// clamp+linear(改动前的全局默认),不破坏现有渲染。
    private func samplerFor(_ flags: TexFlags?) -> MTLSamplerState {
        guard let f = flags else { return sampler }
        switch (f.clamp, f.nearest) {
        case (true, false):  return sampler
        case (false, false): return samplerRepeat
        case (true, true):   return samplerNearest
        case (false, true):  return samplerRepeatNearest
        }
    }

    private(set) var canvas: SIMD2<Float> = SIMD2(1920, 1080)
    private(set) var clearColor: MTLClearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
    private var ambientColor: SIMD3<Float> = .zero   // general.ambientcolor(lwe 默认 vec3(0));喂 LIGHTING 材质 g_LightAmbientColor
    private var layers: [GPULayer] = []
    private var particleGroups: [ParticleGroup] = []
    private var lastUpdateTime: Double = -1

    // 单位 quad: position(float2) + uv(float2),两个三角形。
    private static let quadVerts: [Float] = [
        // x      y     u    v
        -0.5, -0.5,  0,   1,
         0.5, -0.5,  1,   1,
        -0.5,  0.5,  0,   0,
         0.5,  0.5,  1,   0,
    ]

    init?() {
        guard let dev = MTLCreateSystemDefaultDevice(),
              let q = dev.makeCommandQueue() else { return nil }
        self.device = dev
        self.queue = q

        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear; sd.magFilter = .linear; sd.mipFilter = .linear
        sd.sAddressMode = .clampToEdge; sd.tAddressMode = .clampToEdge
        guard let smp = dev.makeSamplerState(descriptor: sd) else { return nil }
        self.sampler = smp
        // 另 3 个采样器:{repeat×linear, clamp×nearest, repeat×nearest},由图层贴图真实 flags 选(samplerFor)。
        func mkSampler(_ wrap: MTLSamplerAddressMode, _ filter: MTLSamplerMinMagFilter) -> MTLSamplerState? {
            let d = MTLSamplerDescriptor()
            d.minFilter = filter; d.magFilter = filter; d.mipFilter = .linear
            d.sAddressMode = wrap; d.tAddressMode = wrap
            return dev.makeSamplerState(descriptor: d)
        }
        guard let smpR = mkSampler(.repeat, .linear),
              let smpN = mkSampler(.clampToEdge, .nearest),
              let smpRN = mkSampler(.repeat, .nearest) else { return nil }
        self.samplerRepeat = smpR; self.samplerNearest = smpN; self.samplerRepeatNearest = smpRN

        // 审计修复#7:不再强解包——显存耗尽时 makeBuffer 返回 nil,失败则让 init? 优雅返回 nil(不崩)。
        guard let qb = dev.makeBuffer(bytes: Self.quadVerts,
                                      length: MemoryLayout<Float>.stride * Self.quadVerts.count,
                                      options: .storageModeShared) else { return nil }
        self.quadBuffer = qb

        do {
            try buildPipelines()
        } catch {
            Log.write("SceneRenderEngine: pipeline build failed: \(error)")
            return nil
        }
        weEffects = WEEffectChain(device: dev)   // 转译特效引擎(manifest 缺失则为 nil,回退内联)
    }

    private func buildPipelines() throws {
        let lib = try device.makeLibrary(source: Self.shaderSource, options: nil)
        let vfn = lib.makeFunction(name: "scene_vertex")
        let ffn = lib.makeFunction(name: "scene_fragment")
        let pvfn = lib.makeFunction(name: "particle_vertex")
        let rvfn = lib.makeFunction(name: "particle_refract_vertex")
        let rffn = lib.makeFunction(name: "particle_refract_fragment")

        func make(vertex: MTLFunction?, _ configure: (MTLRenderPipelineColorAttachmentDescriptor) -> Void) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = vertex
            d.fragmentFunction = ffn
            let att = d.colorAttachments[0]!
            att.pixelFormat = .bgra8Unorm
            configure(att)
            return try device.makeRenderPipelineState(descriptor: d)
        }
        // 严格对齐 lwe CPass.cpp:124(Translucent)/128(Additive):alpha 通道 src 因子是 **GL_SRC_ALPHA**,
        // 不是 ONE。之前写成 .one 是自加偏离 → FBO 累积的 alpha 与 lwe 不同,影响「结果被再采样且用到 alpha」
        // 的链路(打雷 composelayer 读 _rt_FullFrameBuffer.w、blur BLURALPHA、音频条 TRANSPARENCY)。RGB 不受影响。
        func alphaBlend(_ att: MTLRenderPipelineColorAttachmentDescriptor) {
            att.isBlendingEnabled = true
            att.rgbBlendOperation = .add; att.alphaBlendOperation = .add
            att.sourceRGBBlendFactor = .sourceAlpha
            att.destinationRGBBlendFactor = .oneMinusSourceAlpha
            att.sourceAlphaBlendFactor = .sourceAlpha   // lwe: GL_SRC_ALPHA(原 .one 是自加偏离)
            att.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }
        func addBlend(_ att: MTLRenderPipelineColorAttachmentDescriptor) {
            att.isBlendingEnabled = true
            att.rgbBlendOperation = .add; att.alphaBlendOperation = .add
            att.sourceRGBBlendFactor = .sourceAlpha
            att.destinationRGBBlendFactor = .one
            att.sourceAlphaBlendFactor = .sourceAlpha   // lwe: GL_SRC_ALPHA(原 .one 是自加偏离)
            att.destinationAlphaBlendFactor = .one
        }

        pipelineNormal = try make(vertex: vfn) { $0.isBlendingEnabled = false }
        pipelineTranslucent = try make(vertex: vfn, alphaBlend)
        pipelineAdditive = try make(vertex: vfn, addBlend)
        // colorBlendMode 层:scene_fragment_blend 用 framebuffer fetch 读背景、着色器内按方程混合,
        // 故管线自身 blend 关闭(直接写混合结果)。manifest 缺该函数时为 nil → 该层回退普通绘制。
        if let bfn = lib.makeFunction(name: "scene_fragment_blend") {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = vfn
            d.fragmentFunction = bfn
            let att = d.colorAttachments[0]!
            att.pixelFormat = .bgra8Unorm
            att.isBlendingEnabled = false
            pipelineColorBlend = try? device.makeRenderPipelineState(descriptor: d)
        }
        if let pvfn {
            pipelineParticleAlpha = try make(vertex: pvfn, alphaBlend)
            pipelineParticleAdd = try make(vertex: pvfn, addBlend)
        } else {
            Log.write("buildPipelines: particle_vertex NOT FOUND")
        }
        // rope 带状网格:专属 vertex(读 RopeVertex 顶点缓冲)+ scene_fragment(tex×color),同粒子两种混合。
        if let rope = lib.makeFunction(name: "rope_vertex") {
            pipelineRopeAlpha = try make(vertex: rope, alphaBlend)
            pipelineRopeAdd = try make(vertex: rope, addBlend)
        } else {
            Log.write("buildPipelines: rope_vertex NOT FOUND")
        }
        // 折射粒子专用管线:自定义 vertex(带屏幕坐标)+ fragment(采样场景底图)。
        // 按材质真实 blending 备两条:translucent(普通折射雨滴)与 additive(水花 halo 等 blending:additive)。
        if let rvfn, let rffn {
            func makeRefract(_ configure: (MTLRenderPipelineColorAttachmentDescriptor) -> Void) throws -> MTLRenderPipelineState {
                let d = MTLRenderPipelineDescriptor()
                d.vertexFunction = rvfn
                d.fragmentFunction = rffn
                let att = d.colorAttachments[0]!
                att.pixelFormat = .bgra8Unorm
                configure(att)
                return try device.makeRenderPipelineState(descriptor: d)
            }
            pipelineParticleRefract = try makeRefract(alphaBlend)
            pipelineParticleRefractAdd = try makeRefract(addBlend)
        }
        // 全屏拷贝管线(折射 pass 先把场景底图铺到合成目标)。
        if let fsv = lib.makeFunction(name: "fullscreen_vertex"),
           let fsf = lib.makeFunction(name: "fullscreen_copy") {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = fsv; d.fragmentFunction = fsf
            d.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipelineBlit = try device.makeRenderPipelineState(descriptor: d)
            // FXAA 呈现管线(同顶点,FXAA 片元)。
            if let fxaa = lib.makeFunction(name: "fullscreen_fxaa") {
                let df = MTLRenderPipelineDescriptor()
                df.vertexFunction = fsv; df.fragmentFunction = fxaa
                df.colorAttachments[0].pixelFormat = .bgra8Unorm
                pipelineBlitFXAA = try? device.makeRenderPipelineState(descriptor: df)
            }
        }
        Log.write("buildPipelines: particleAlpha=\(pipelineParticleAlpha != nil) particleAdd=\(pipelineParticleAdd != nil) refract=\(pipelineParticleRefract != nil) refractAdd=\(pipelineParticleRefractAdd != nil)")
    }

    // MARK: - 加载场景

    func load(document: SceneDocument, source: SceneSource) {
        // 释放上一个场景占用的音频捕获(若有),再按新场景重新 acquire。
        if usesAudio { AudioCapture.shared.release(); usesAudio = false }
        // 壁纸自带音频(sound 对象,BGM/雨声):停旧的、按新场景加载。默认随全局 isMuted(默认静音)不出声。
        audioPlayback.stop()
        if !document.sounds.isEmpty {
            audioPlayback.load(sounds: document.sounds, source: source,
                               muted: PreferencesStore.shared.isMuted, volume: Float(PreferencesStore.shared.volume))
        }
        canvas = SIMD2(document.canvasWidth, document.canvasHeight)
        // 审计修复#6:canvas 任一维 ≤0 时 matOrtho 的 2/width 产生 inf/NaN → mvp 全坏(空屏/崩)。
        // 守卫:非正尺寸回退到安全默认 1920×1080。proj 与 ndcScale/像素坐标据此一致计算。
        if !(canvas.x > 0 && canvas.y > 0) {
            Log.write("scene: invalid canvas \(canvas.x)x\(canvas.y) → fallback 1920x1080")
            canvas = SIMD2(1920, 1080)
        }
        clearColor = MTLClearColor(red: Double(document.clearColor.x),
                                   green: Double(document.clearColor.y),
                                   blue: Double(document.clearColor.z),
                                   alpha: 1)
        ambientColor = document.ambientColor   // 环境光读 pkg general.ambientcolor(lwe 默认 vec3(0)),非硬编码
        // 相机 eye:正确做法就是「不应用」——纯 ortho 已等于 lwe 的净结果(已数值验证全库)。
        // lwe 对正交相机里 eye 出现两处且**精确抵消**:Camera.cpp:49-50 `ortho` 后 `translate(+eye)`,
        // Camera.cpp:13 `lookAt(eye,center,up)` 含 `−eye`,MVP=proj·lookAt·model 里 (+eye)(−eye) 相消
        // (lwe 自己 Camera.cpp:11-12 注释:lookAt 对正交相机 "throws off points",translate(eye) 正是去抵消它)。
        // 故 matOrtho(无 eye、无 lookAt)与 lwe 的 proj·lookAt 在 XY 上逐位相同。**单独 translate(eye) 会双重偏移
        // = 引入 bug**(实测 3679853952 灰条)。全库 57 张 scene 的 eye.xy 要么为 0、要么经抵消后框取与纯 ortho 一致。
        let proj = matOrtho(width: canvas.x, height: canvas.y)
        let loader = MTKTextureLoader(device: device)

        var result: [GPULayer] = []
        for layer in document.layers {
            // 缺口B:有 visibleScript 的层即使静态 visible=false 也要建(否则脚本永远点不亮);
            // 其每帧由脚本决定显隐(绘制门控 layers[i].visible)。无脚本的静态隐藏层仍跳过(零变化)。
            guard layer.visible || layer.visibleScript != nil else { continue }

            let tex: MTLTexture
            var texFlags: TexFlags? = nil   // 图层贴图的真实 WE flags(驱动主 pass + 特效 g_Texture0 采样器)
            var videoTex: VideoTexture? = nil
            var textState: TextLayerState? = nil
            if layer.audioBars != nil {
                // 音频频谱条:用**透明**底纹理作画布,真 WE Simple_Audio_Bars shader(在 effects 链里)
                // 据系统音频频谱把条画上去(TRANSPARENCY=REPLACE → alpha=bar*opacity),再由 perspective
                // 把条贴到场景梯形。底纹理分辨率决定条的采样精度(512×256,与旧 CPU 条一致)。需音频捕获。
                guard let t = transparentTexture(width: 512, height: 256) else { continue }
                tex = t
                AudioCapture.shared.acquire()
                usesAudio = true
            } else if let textDesc = layer.text {
                // 文本图层(时钟/日期):Core Text 渲染成纹理,每秒刷新。
                var td = textDesc
                // 壁纸自带字体(font 字段是 pkg 路径,如 "fonts/Atami-Regular.otf"):注册进 CoreText 后
                // 用其 PostScript 名,否则 resolveFont 取不到 → 落系统字体 → 时钟/文字「不是原版」。
                let fn = td.fontName.lowercased()
                if fn.hasSuffix(".otf") || fn.hasSuffix(".ttf") || fn.contains("/") {
                    if let ps = FontRegistry.shared.register(path: td.fontName, source: source) { td.fontName = ps }
                }
                guard let t = makeTextTexture(td, loader: loader) else {
                    Log.write("scene: text layer render failed \(layer.name)"); continue
                }
                tex = t.0
                textState = TextLayerState(desc: td, lastString: TextLayerRenderer.currentString(td))
            } else if layer.isSolid, layer.effects.contains(where: { weEffects?.usesAudioSpectrum($0.weName) == true }) {
                // 音频可视化 solidlayer(如 audioline,非标准 Simple_Audio_Bars):用**透明**底,真 WE shader 据
                // 系统频谱在其上画曲线(无曲线处透明),叠在场景上(用白底会变白块)。需音频捕获。
                guard let t = transparentTexture(width: 1024, height: 512) else { continue }
                tex = t
                AudioCapture.shared.acquire()
                usesAudio = true
            } else if layer.isSolid || layer.frameBufferInput {
                // 纯色填充层:用 1×1 白纹理,颜色由 layer.color 提供。
                // frameBufferInput(composelayer/_rt_FullFrameBuffer):无自有贴图,用白纹理占位——真正输入在
                // runLayerEffects 里由 compositeSceneBelow(下方场景)喂入、跑特效链后存 effectedTexture,encode 画它。
                // 审计修复#7:whiteTexture 现为可选(显存耗尽返回 nil)→ 跳过该层而非崩溃。
                guard let t = whiteTexture() else {
                    Log.write("scene: white texture alloc failed for solid layer \(layer.name)"); continue
                }
                tex = t
            } else {
                guard let texPath = layer.texturePath,
                      let blob = source.data(for: texPath),
                      let decodedWF = TexDecoder.decodeFirstMipWithFlags(blob) else {
                    Log.write("scene: tex decode failed for \(layer.texturePath ?? "nil")")
                    continue
                }
                let decoded = decodedWF.tex
                texFlags = decodedWF.flags
                if case .video(let mp4) = decoded {
                    // 视频纹理:先用首帧建静态兜底,再尝试建逐帧播放器。
                    guard let frame = VideoFrame.firstFrameRGBA8(mp4),
                          let fallback = makeTexture(.rgba8(pixels: frame.pixels, width: frame.width, height: frame.height), loader: loader) else {
                        Log.write("scene: video first-frame failed for \(texPath)")
                        continue
                    }
                    tex = fallback
                    videoTex = VideoTexture(data: mp4, device: device, fallback: fallback)
                    if videoTex == nil { Log.write("scene: video playback init failed, static first-frame for \(texPath)") }
                } else if let t = makeTexture(decoded, loader: loader) {
                    tex = t
                } else {
                    Log.write("scene: tex upload failed for \(texPath)")
                    continue
                }
            }

            // 逐特效遮罩:每个 effect 用**自己的** opacitymask(WE 里同层不同 effect 的遮罩常不同,
            // 如 opacity 用 opacity_mask、waterwaves 用 waterwave_mask)。喂错遮罩会让该 effect 作用错区域
            // (例:opacity 拿到别的遮罩 → 该透明的区域不透明,叠层后糊成一片白)。缓存解码结果避免重复。
            var maskCache: [String: MTLTexture] = [:]
            var maskFlagsCache: [String: TexFlags?] = [:]   // 遮罩贴图真实 flags(喂特效 MASK 槽采样器)
            func maskTex(_ path: String?) -> MTLTexture? {
                guard let p = path else { return nil }
                if let t = maskCache[p] { return t }
                guard let blob = source.data(for: p), let dec = TexDecoder.decodeFirstMipWithFlags(blob),
                      let t = makeTexture(dec.tex, loader: loader) else { return nil }
                maskCache[p] = t; maskFlagsCache[p] = dec.flags; return t
            }
            let effectMasks: [MTLTexture?] = layer.effects.map { maskTex($0.maskPath) }
            let effectMaskFlags: [TexFlags?] = layer.effects.map { $0.maskPath.flatMap { maskFlagsCache[$0] ?? nil } }
            // 主层水面遮罩(cursorripple 折射限定用):取首个非空遮罩。
            let effectMask: MTLTexture? = effectMasks.compactMap { $0 }.first

            // 逐特效辅助贴图(weAux:slot→ref)解码。引用解析三级(只认真实文件):
            //   1) pkg 内 materials/<ref>.tex  2) pkg 内 <ref>.tex  3) WE 内置 assets(同名)。
            // 解码后存 slot→MTLTexture,runLayerEffects 据此绑定到 g_Texture<slot>。
            var auxCache: [String: MTLTexture] = [:]
            var auxFlagsCache: [String: TexFlags?] = [:]   // 辅助贴图真实 flags(喂特效 g_Texture<slot> 采样器)
            func auxTex(_ ref: String) -> MTLTexture? {
                if let t = auxCache[ref] { return t }
                let blob = source.data(for: "materials/\(ref).tex")
                    ?? source.data(for: ref.hasSuffix(".tex") ? ref : "\(ref).tex")
                    ?? BuiltinAssets.shared.textureData(forReference: ref)
                // dataTexture:辅助槽是流向场/法线/相位等**数据贴图**,RG88 须保留双通道 (R,G),
                // 不能当「亮度+alpha」(否则 waterflow 的垂直 G 分量被丢 → 屋檐水流不流不下落)。
                guard let b = blob, let dec = TexDecoder.decodeFirstMipWithFlags(b, dataTexture: true),
                      let t = makeTexture(dec.tex, loader: loader) else {
                    Log.write("scene: aux texture unresolved ref=\(ref) (blob=\(blob != nil))")
                    return nil
                }
                auxCache[ref] = t; auxFlagsCache[ref] = dec.flags; return t
            }
            let effectAux: [[Int: MTLTexture]] = layer.effects.map { eff in
                var m: [Int: MTLTexture] = [:]
                for (slot, ref) in eff.weAux { if let t = auxTex(ref) { m[slot] = t } }
                return m
            }
            let effectAuxFlags: [[Int: TexFlags]] = layer.effects.map { eff in
                var m: [Int: TexFlags] = [:]
                for (slot, ref) in eff.weAux { if let f = auxFlagsCache[ref] ?? nil { m[slot] = f } }
                return m
            }

            // 尺寸:文本层若有显式盒子(WE size×scale),屏上大小 = 字形纵横比适配进盒子;
            // 否则(普通图层 / 无 size 的 autosize 文本)= sizePx(或纹理像素)× scale。
            var size: SIMD2<Float>
            var effSize: SIMD2<Float>
            var textBox: SIMD2<Float>? = nil
            var textCenterOffset: SIMD2<Float> = .zero
            if let box = layer.text?.boxSizePx {
                // 盒子 = size×scale(画布单位)。文本按字形纵横比适配进盒子(见 textQuad)。
                let scaledBox = SIMD2(box.x * layer.scale.x, box.y * layer.scale.y)
                let q = textQuad(texW: Float(tex.width), texH: Float(tex.height), box: scaledBox,
                                 hAlign: layer.text?.align ?? "center",
                                 vAlign: layer.text?.verticalAlign ?? "center")
                size = scaledBox          // baseSize 记盒子(scaleScript 不作用于文本,无碍)
                effSize = q.size
                textBox = scaledBox
                textCenterOffset = q.centerOffset
            } else {
                // autosize:没有显式 size 时取纹理像素尺寸。
                size = layer.sizePx ?? SIMD2(Float(tex.width), Float(tex.height))
                effSize = SIMD2(size.x * layer.scale.x, size.y * layer.scale.y)
            }
            let layerCenter = SIMD2(layer.originPx.x + textCenterOffset.x,
                                    layer.originPx.y + textCenterOffset.y)
            let model = matModel(centerPx: layerCenter,
                                 sizePx: effSize, angleDegZ: layer.anglesDeg.z)
            // 所有图层特效都按**真 WE 转译 shader 逐个**跑(runLayerEffects),不再有「全覆盖才用 WE
            // 否则回退手写近似」的 all-or-nothing。manifest 里有且非 denylist 的 effect 跑真 shader,
            // 其余(如未转译的自定义)在链里被跳过(passthrough)。useWE = 该层有任一可跑的真特效。
            let effs = Array(layer.effects.prefix(kMaxLayerEffects))
            let effMasks = Array(effectMasks.prefix(kMaxLayerEffects))
            let effAux = Array(effectAux.prefix(kMaxLayerEffects))
            let effMaskFlags = Array(effectMaskFlags.prefix(kMaxLayerEffects))
            let effAuxFlags = Array(effectAuxFlags.prefix(kMaxLayerEffects))
            let hasRunnableWE = effs.contains {
                !Self.weDenied.contains($0.weName) && (weEffects?.has($0.weName) ?? false)
            }
            // 对象级 brightness(WE g_Brightness,ObjectParser.cpp:293,默认 1)。WE 在材质 pass 里
            // 用 g_Brightness 乘 albedo.rgb;我们所有层最终都走 scene_fragment 的 tex×in.color,
            // 故把 brightness 折进 color.rgb(只乘 rgb 不动 alpha)即等价施加一次。
            let br = layer.brightness
            let litColor = br == 1 ? layer.color
                : SIMD4(layer.color.x * br, layer.color.y * br, layer.color.z * br, layer.color.w)
            // 缺口E(已撤销,2026-06):曾试「音频可视化 solidlayer 贴回 alpha 强制 1」(让 alpha=0 的 audioline
            // 频谱可见)。**实测把凯尔希 Esperanta(id391)整屏糊成噪点**(meanDiff 106 vs 基线)——该 audioline 的
            // effectedTexture 强制不透明后覆盖/污染场景,说明其 alpha=0 是有意隐藏/该层不干净渲染,审计前提不成立。
            // 仅涉 2 张却破坏 1 张 → 撤销,保留 baseline(audioline 维持不可见,比糊屏好)。详见 [[audio-bars-detection]]。
            // puppet 网格(多部件角色部件,如凯尔希主体/长发/眼睛):非矩形、偏心的 bind-pose 网格。
            // 正解(照 lwe CImage.cpp:514+780-834):把局部 puppet 顶点(单位空间,PuppetMesh.parse 输出)
            // **直接用本层的场景投影 layer.mvp(proj×matModel) 渲三角网格**(替代平面 quad),偏心/出界顶点不裁
            // —— 它们落到该层框外但场景内的相邻位置,正是眼睛(rawX 全负)拼到脸中央、头发披到背后的机制。
            // (旧的「每层 size×size 局部 ortho FBO + 裁剪 + 当 albedo 铺」是我方自创、偏离 lwe:把眼睛偏心顶点
            //  整片裁光 → 光头、头发夹偏。已弃。)WP_NOPUPPET=1 可临时退回 baseline(无 puppet)对比。
            var puppetVB: MTLBuffer? = nil, puppetIB: MTLBuffer? = nil, puppetCount = 0
            var puppetMesh: PuppetMesh? = nil, puppetAnimId = 0, puppetAnimRate: Float = 1
            if ProcessInfo.processInfo.environment["WP_NOPUPPET"] == nil,
               let pup = layer.puppet, let blob = source.data(for: pup),
               let mesh = PuppetMesh.parse(blob, size: size), mesh.indices.count >= 3,
               size.x >= 1, size.y >= 1 {
                let bind = mesh.bindVerts
                // shared 存储:hasSkin 时 update() 每帧就地写入蒙皮后顶点(摇摆相邻帧近一致,单缓冲竞态不可见)。
                puppetVB = device.makeBuffer(bytes: bind, length: MemoryLayout<Float>.stride * bind.count, options: .storageModeShared)
                puppetIB = device.makeBuffer(bytes: mesh.indices, length: MemoryLayout<UInt16>.stride * mesh.indices.count)
                puppetCount = mesh.indices.count
                // 骨骼动画:取首个 visible 的 animationlayer 的 animation id + rate(对应 MDLA 动画 id)。
                if mesh.hasSkin, let al = layer.animationLayers.first(where: { $0.visible }) ?? layer.animationLayers.first {
                    puppetMesh = mesh; puppetAnimId = al.animation; puppetAnimRate = al.rate
                }
                Log.write("puppet: \(layer.name) mesh \(bind.count/4) verts, \(puppetCount) idx, skin=\(puppetMesh != nil ? "anim\(puppetAnimId)" : "static")")
            }
            result.append(GPULayer(
                texture: tex,
                baseModel: model,
                mvp: proj * model,
                color: litColor,
                blend: layer.blend,
                colorBlendMode: layer.colorBlendMode,
                origin: SIMD2(layer.originPx.x, layer.originPx.y),
                parallax: layer.parallax,
                sizePx: effSize,
                video: videoTex,
                effects: effs,
                text: textState,
                textBox: textBox,
                textCenterOffset: textCenterOffset,
                audioBars: layer.audioBars,
                effectMask: effectMask,
                effectMasks: effMasks,
                effectAux: effAux,
                texFlags: texFlags,
                effectMaskFlags: effMaskFlags,
                effectAuxFlags: effAuxFlags,
                useWE: hasRunnableWE,
                frameBufferInput: layer.frameBufferInput,
                regionFit: layer.regionFit,
                materialShader: layer.materialShader,
                materialCombos: layer.materialCombos,
                materialConstants: layer.materialConstants,
                puppetVB: puppetVB,
                puppetIB: puppetIB,
                puppetIndexCount: puppetCount,
                puppetMesh: puppetMesh,
                puppetAnimId: puppetAnimId,
                puppetAnimRate: puppetAnimRate,
                scaleScript: layer.scaleScript,
                baseSize: size,
                baseScale: layer.baseScale,
                baseAngleZ: layer.anglesDeg.z
            ))
            result[result.count - 1].id = layer.id   // 诊断用:按 pkg id 隐藏图层(WP_HIDE_IDS)
            // 缺口B/D:visible/alpha/color 脚本 + 初始显隐(静态值作脚本失败回退)。
            result[result.count - 1].visible = layer.visible
            result[result.count - 1].visibleScript = layer.visibleScript
            result[result.count - 1].alphaScript = layer.alphaScript
            result[result.count - 1].colorScript = layer.colorScript
            // origin 脚本(挂件容器/时钟/鼠标指针):记下脚本 + 父链变换,供 update 每帧重算绝对 origin。
            // 重算时叠加 layers[i].textCenterOffset(盒子对齐量,文本层每秒刷新时更新;图层恒为 0)。
            if layer.originScript != nil {
                let last = result.count - 1
                result[last].originScript = layer.originScript
                result[last].baseLocalOrigin = layer.baseLocalOrigin
                result[last].parentAbsOrigin = layer.parentAbsOrigin
                result[last].parentAbsScale = layer.parentAbsScale
                result[last].parentAbsAngle = layer.parentAbsAngle
            }
            // angles 脚本(#3:zRotation 等):记下脚本 + 父链累积角,供 update 每帧重算渲染角度。
            if layer.angleScript != nil {
                let last = result.count - 1
                result[last].angleScript = layer.angleScript
                result[last].baseLocalAngles = layer.baseLocalAngles
                result[last].parentAbsAngle = layer.parentAbsAngle
            }
            // 对象 origin/angles 关键帧动画(头发/发饰随头摆;无父链层 parentAbs* 为默认 0/1/0 → 关键帧值即绝对值)。
            if layer.originKeyAnim != nil || layer.angleKeyAnim != nil {
                let last = result.count - 1
                result[last].originKeyAnim = layer.originKeyAnim
                result[last].angleKeyAnim = layer.angleKeyAnim
                result[last].parentAbsOrigin = layer.parentAbsOrigin
                result[last].parentAbsScale = layer.parentAbsScale
                result[last].parentAbsAngle = layer.parentAbsAngle
            }
        }
        layers = result
        compositeFramesRendered = 0   // 新场景:合成层帧计数归零(重新渲满 compositeMaxFrames 帧)
        self.proj = proj
        // lwe 视差含 (depth+amount) 项 → amount≠0 时连 depth=0 的层也随相机平移(CImage.cpp:1104)。
        // 故相机视差开启即视为「有动画」(否则纯背景视差场景被当静态图、鼠标移动不重绘)。
        hasParallax = (document.cameraParallax && document.cameraParallaxAmount != 0)
            || result.contains { $0.parallax.x != 0 || $0.parallax.y != 0 }
        hasVideo = result.contains { $0.video != nil }
        hasEffects = result.contains { !$0.effects.isEmpty }
        hasText = result.contains { $0.text != nil }
        hasScaleScript = result.contains { $0.scaleScript != nil }
        hasOriginScript = result.contains { $0.originScript != nil }
        hasAngleScript = result.contains { $0.angleScript != nil }
        hasAudioBars = result.contains { $0.audioBars != nil }
        cameraParallax = document.cameraParallax
        cameraParallaxAmount = document.cameraParallaxAmount
        cameraParallaxMouseInfluence = document.cameraParallaxMouseInfluence
        cameraParallaxDelay = document.cameraParallaxDelay
        cameraShake = document.cameraShake
        cameraShakeAmplitude = document.cameraShakeAmplitude
        cameraShakeRoughness = document.cameraShakeRoughness
        cameraShakeSpeed = document.cameraShakeSpeed
        // 后处理:优先跑该壁纸 fullscreenlayer 上的**真** WE 特效链(bloom+filmgrain+localcontrast 等,
        // 转译 shader 多 pass),只保留转译引擎(weEffects)已覆盖的可见 effect,按 scene 顺序。
        postChain = document.postChain.filter { !$0.weName.isEmpty && (weEffects?.has($0.weName) ?? false) }
        Log.write("scene: postChain = [\(postChain.map { $0.weName }.joined(separator: ", "))] (from \(document.postChain.count) declared)")

        // 音频反应特效(如 pulse 的 AUDIOPROCESSING):图层或后处理链里任一特效的 combos 请求了
        // 非 0 的 AUDIOPROCESSING → 需要系统音频频谱(g_AudioSpectrum16Left/Right)。与 audio-bars
        // 共用一份捕获;无音频反应特效且无 bars 时不抓(省电、不弹录屏授权)。
        func effectUsesAudio(_ e: LayerEffect) -> Bool {
            // ① AUDIOPROCESSING combo 非 0;② 或 effect 直接声明 g_AudioSpectrum*(如 audioline,无此 combo)。
            if let v = e.weCombos["AUDIOPROCESSING"], (Int(v) ?? 0) != 0 { return true }
            return weEffects?.usesAudioSpectrum(e.weName) ?? false
        }
        // 基础材质(genericimage)自身可带 AUDIOPROCESSING combo(频谱可视化直接做在 material pass,
        // 而非 effect)。此前只看 LayerEffect.weCombos,漏判这类壁纸 → currentAudio16 空 → 材质频谱恒 0、不出条。
        func materialUsesAudio(_ l: GPULayer) -> Bool {
            if let v = l.materialCombos["AUDIOPROCESSING"], (Int(v) ?? 0) != 0 { return true }
            // 与 effect 路径同口径:基础材质 shader 自身若声明 g_AudioSpectrum*(频谱可视化做在 material pass,
            // 无 AUDIOPROCESSING combo)也要采集音频,否则 buildMaterialUniforms 写全 0、条恒静止。
            if let sh = l.materialShader, weEffects?.usesAudioSpectrum("material/\(sh)") == true { return true }
            return false
        }
        hasAudioReactiveFX = result.contains { $0.effects.contains(where: effectUsesAudio) }
            || postChain.contains(where: effectUsesAudio)
            || result.contains(where: materialUsesAudio)
        if ProcessInfo.processInfo.environment["WP_DBG_AUDIO"] != nil {
            for (li, l) in result.enumerated() {
                for e in l.effects where !e.weName.isEmpty {
                    Log.write("DBGAUDIO layer#\(li) eff=\(e.weName) usesAudio=\(weEffects?.usesAudioSpectrum(e.weName) ?? false) AP=\(e.weCombos["AUDIOPROCESSING"] ?? "nil")")
                }
            }
            Log.write("DBGAUDIO hasAudioReactiveFX=\(hasAudioReactiveFX) hasAudioBars=\(hasAudioBars) layers=\(result.count)")
        }
        // 音频反应脚本(调 registerAudioBuffers/读 __audio):origin/scale/angle 脚本任一用音频 → 也要采集 + 每帧喂频谱。
        hasAudioReactiveScript = result.contains {
            ($0.scaleScript?.usesAudio ?? false) || ($0.originScript?.usesAudio ?? false) || ($0.angleScript?.usesAudio ?? false)
            || ($0.visibleScript?.usesAudio ?? false) || ($0.alphaScript?.usesAudio ?? false) || ($0.colorScript?.usesAudio ?? false)
        }
        if (hasAudioReactiveFX || hasAudioReactiveScript), !usesAudio {
            AudioCapture.shared.acquire(); usesAudio = true
            Log.write("scene: audio-reactive FX/脚本 present → acquired audio capture")
        }
        // 相机级 bloom(general.bloom):WE 相机内建,无 effects/bloom 文件夹故进不了 manifest/postChain。
        // 用 PostProcess 跑 lwe 真 bloom 4-pass(downsample¼→⅛模糊→combine,真 WE shader)。
        // postChain 已覆盖 bloom(如某工坊壁纸自带 bloom 特效在 manifest)时不重复跑。
        if postChain.isEmpty, document.postBloom {
            if postProcess == nil { postProcess = PostProcess(device: device, sampler: sampler, quad: quadBuffer) }
            postProcess?.params = PostProcess.Params(
                bloom: document.postBloom, bloomThreshold: document.postBloomThreshold,
                bloomStrength: document.postBloomStrength, bloomTint: document.postBloomTint)
        } else {
            postProcess = nil
        }
        hasCursorRipple = document.hasCursorRipple
        cursorRippleCutoff = document.cursorRippleLayerCutoff
        if hasCursorRipple {
            if rippleSim == nil { rippleSim = CursorRippleSim(device: device, sampler: sampler, quad: quadBuffer) }
            Log.write("cursorripple: 折射作用于 projectlayer 下方 \(cursorRippleCutoff) 层(layers[0..<\(cursorRippleCutoff)]),上方层不折射")
            rippleSim?.rippleStrength = document.rippleParams.x
            rippleSim?.rippleScale = document.rippleParams.y
            rippleSim?.rippleSpeed = document.rippleParams.z
            rippleSim?.rippleDecay = document.rippleParams.w
            // 碰撞遮罩(限定力场在水面):从壁纸源解码绑到 sim。无则力场全屏 → 鼠标划过草地也起波。
            if let mp = document.rippleMaskPath, let blob = source.data(for: mp),
               let dec = TexDecoder.decodeFirstMip(blob) {
                rippleSim?.collisionMask = makeTexture(dec, loader: loader)
                Log.write("cursorripple: collision mask \(mp) loaded")
            } else {
                rippleSim?.collisionMask = nil
                if document.rippleMaskPath != nil { Log.write("cursorripple: mask \(document.rippleMaskPath!) decode FAILED") }
            }
        } else {
            rippleSim = nil
        }

        // 粒子发射器。纹理解析只认**真实文件**,3 级来源都是 pkg/磁盘上的真东西:
        //   1) 本壁纸 pkg 内  2) WE 本体内置 assets  3) 跨工坊依赖项(workshop/<id>/…)。
        // 全找不到 → 跳过该发射器,绝不自造一张假贴图糊弄(那样换壁纸就废,且画面错)。
        particleGroups.removeAll()
        var seed: UInt64 = 0x9E3779B97F4A7C15
        for (idx, em) in document.emitters.enumerated() {
            var tex: MTLTexture?
            var texBlob: Data? = nil    // 保留原始 .tex 字节,用于解析内嵌 TEXS 精灵表
            // 1) pkg 内真实贴图(workshop 自带,如 birds/流星)
            if let texPath = em.texturePath, let blob = source.data(for: texPath),
               let decoded = TexDecoder.decodeFirstMip(blob) {
                tex = makeTexture(decoded, loader: loader); texBlob = blob
            }
            // 2) WE 内置共享贴图(fog/rain/snow/drop/spark 等)
            if tex == nil, let ref = em.textureName,
               let blob = BuiltinAssets.shared.textureData(forReference: ref),
               let decoded = TexDecoder.decodeFirstMip(blob) {
                tex = makeTexture(decoded, loader: loader); texBlob = blob
            }
            // 3) 跨工坊依赖项的贴图(作者引用了另一个订阅项的资源包)
            if tex == nil, let ref = em.textureName,
               let blob = CrossWorkshopAssets.textureData(forReference: ref),
               let decoded = TexDecoder.decodeFirstMip(blob) {
                tex = makeTexture(decoded, loader: loader); texBlob = blob
            }
            // 找不到真实贴图:跳过(可能是未安装的依赖项)。不画假图。
            guard let tex else {
                Log.write("scene: 跳过发射器[\(idx)] tex=\(em.textureName ?? "?") — 无真实贴图(依赖未安装?)")
                continue
            }
            seed = seed &* 6364136223846793005 &+ UInt64(idx + 1)

            // 精灵表:优先用 .tex 内嵌 TEXS 段(WE 把帧 UV 矩形存这儿,如 bird 24帧);
            // 没有再退回 .tex-json 边车(均匀网格)。
            var frames = 1, cols = 1
            var uvScale = SIMD2<Float>(1, 1)
            var frameRects: [SIMD4<Float>] = []   // 显式帧 UV 矩形 (u0,v0,uw,vh),非空则按它播放
            var frameDuration: Float = 1.0 / 24
            if tex.width > 0, tex.height > 0 {
                if let blob = texBlob, let sheet = TexDecoder.spriteSheet(blob), sheet.frameCount > 1 {
                    // TEXS:用真实帧宽算每行列数,x 超 tex 宽换行,生成每帧 UV 矩形。
                    let tw = Float(tex.width), th = Float(tex.height)
                    let fw = sheet.frames[0].w, fh = sheet.frames[0].h
                    // 用 round 而非 Int 截断:tw/fw 因浮点常略小于整数(如 512/102.5=4.995),
                    // Int() 砍成 4 → 列数少一列 → 帧采到越界/空 padding(樱花/落叶约 1/5 隐形)。
                    // 与下方兜底分支(:671)的 .rounded() 一致。真实贴图布局(rosepetals 5/行、leaves 6×5)逐帧吻合。
                    let perRow = max(1, Int((tw / fw).rounded()))
                    for (i, _) in sheet.frames.enumerated() {
                        let col = i % perRow, row = i / perRow
                        let u0 = Float(col) * fw / tw, v0 = Float(row) * fh / th
                        frameRects.append(SIMD4(u0, v0, fw / tw, fh / th))
                    }
                    frames = sheet.frameCount
                    frameDuration = sheet.frameDuration
                } else if em.sheetFrames > 1, em.frameWidthPx > 0, em.frameHeightPx > 0 {
                    frames = em.sheetFrames
                    cols = max(1, Int((Float(tex.width) / em.frameWidthPx).rounded()))
                    uvScale = SIMD2(min(em.frameWidthPx / Float(tex.width), 1), min(em.frameHeightPx / Float(tex.height), 1))
                    frameDuration = em.sheetDuration / Float(frames)   // 侧车真实每帧秒数(否则留默认 1/24 → 翻飞速度错)
                }
            }
            // 折射粒子的法线贴图(textures[1]):同样只认真实文件,3 级来源。
            var normalTex: MTLTexture? = nil
            if em.isRefract {
                if let p = em.normalTexturePath, let blob = source.data(for: p),
                   let dec = TexDecoder.decodeFirstMip(blob) {
                    normalTex = makeTexture(dec, loader: loader)
                } else if let ref = em.normalTextureName,
                          let blob = BuiltinAssets.shared.textureData(forReference: ref)
                                  ?? CrossWorkshopAssets.textureData(forReference: ref),
                          let dec = TexDecoder.decodeFirstMip(blob) {
                    normalTex = makeTexture(dec, loader: loader)
                }
            }
            let sim = ParticleSimulator(desc: em, seed: seed,
                                        sheetFrames: frames, sheetCols: cols, sheetUVScale: uvScale,
                                        frameRects: frameRects, frameDuration: frameDuration)
            sim.randomFrameMode = em.randomFrame
            // 贴图原始高宽比 texH/texW(CParticle.cpp:1948)。**所有 sprite 粒子都要**(不只 trail):普通
            // sprite 的每帧像素高宽比 = 帧UV比 × 此值,用于把非方形精灵表/非方形贴图按真实比例渲(否则花瓣
            // 被压成竖条 = 御剑樱花的真因)。trail 的拖尾长度也用它。建组时才知道真实贴图尺寸。
            if tex.width > 0 {
                sim.desc.trailTextureRatio = Float(tex.height) / Float(tex.width)
            }
            sim.warmup(seconds: max(2, em.lifetimeMax))   // 预热到稳态,避免开场空屏
            particleGroups.append(ParticleGroup(sim: sim, texture: tex, additive: em.blend == .additive,
                                                isRefract: em.isRefract, isRope: em.isRope, normalTexture: normalTex,
                                                aboveBloom: em.aboveBloom))
        }
        lastUpdateTime = -1
        let cbmLayers = layers.filter { $0.colorBlendMode > 0 }
        let cbmInfo = cbmLayers.isEmpty ? "" : " colorBlendMode=\(cbmLayers.map { $0.colorBlendMode })(pipe=\(pipelineColorBlend != nil ? "Y" : "N"))"
        Log.write("scene: loaded \(layers.count)/\(document.layers.count) layers, \(particleGroups.count)/\(document.emitters.count) particle groups, canvas \(canvas.x)x\(canvas.y), parallax=\(hasParallax)\(cbmInfo)")
    }

    /// 是否需要持续动画(有视差、粒子、视频纹理、effect、文本时钟、scale 脚本、音频条或鼠标水波)。
    var isAnimated: Bool { hasParallax || !particleGroups.isEmpty || hasVideo || hasEffects || hasText || hasScaleScript || hasOriginScript || hasAngleScript || hasAudioBars || hasCursorRipple }
    private var hasScaleScript = false
    /// 是否含 origin 脚本图层(鼠标指针等动态 origin → 需每帧重算)。容器/时钟的 origin 脚本虽静态,
    /// 设此标志也无妨:每帧重算得同值,baseModel 不变,代价极小。
    private var hasOriginScript = false
    /// 是否含 angles 脚本图层(#3:zRotation 等动态角度 → 需每帧重算)。静态脚本每帧得同值,无妨。
    private var hasAngleScript = false
    /// 是否含视频纹理图层(决定要不要起动画循环)。
    private var hasVideo = false
    /// 当前动画时间(秒),供 effect shader 使用。
    private var currentTime: Float = 0
    /// 当前光标位置,归一化 [0,1](x 右,y **向上**=屏幕底为 0)。喂 WE 交互特效的
    /// g_PointerPosition / g_ParallaxPosition(xray 透视揭示、depthparallax 视差)。
    /// 静止(鼠标居中)= (0.5,0.5);WE 约定 0.5 为中性(无偏移)。
    private var cursorUV = SIMD2<Float>(0.5, 0.5)
    /// 相机视差总开关(场景 general.cameraparallax)。关时不做视差/漂移。
    private var cameraParallax = true
    // WE 相机真实参数:视差幅度/鼠标影响/平滑延迟(照 lwe CScene.cpp:394-406 + CImage.cpp:1097-1106)。
    private var cameraParallaxAmount: Float = 1
    private var cameraParallaxMouseInfluence: Float = 1
    private var cameraParallaxDelay: Float = 0
    /// lwe m_parallaxDisplacement:每帧朝目标 (mouseUV-0.5)×amount×influence 平滑逼近的位移状态(归一化空间)。
    private var parallaxDisplacement = SIMD2<Float>(0, 0)
    /// 上一帧时间(秒),算视差平滑的真实 dt。粒子用的 lastUpdateTime 只在有粒子时更新,故另开一个。
    private var lastFrameTime: Double = -1
    // camerashake:lwe 只解析不渲染(grep 全库无渲染代码),无真实公式可移植 → 不渲染(对齐 lwe)。
    // 字段仍解析存下(下面赋值),仅备查/未来;绝不自造噪声抖动。
    private var cameraShake = false
    private var cameraShakeAmplitude: Float = 0
    private var cameraShakeRoughness: Float = 1
    private var cameraShakeSpeed: Float = 1
    /// 全屏后处理(bloom/localcontrast)。enabled 时场景先渲离屏再后处理输出。
    /// 仅作 postChain 为空时的安全回退(转译引擎缺失);正常走 postChain 真 WE 特效。
    private var postProcess: PostProcess?
    /// 真 WE 后处理链(fullscreenlayer 上的 bloom+filmgrain+localcontrast 等转译特效),按 scene 顺序。
    private var postChain: [LayerEffect] = []
    /// 后处理输入:整帧先合成到这张全分辨率离屏纹理,再依次跑 postChain,末帧 blit 到 drawable。
    private var postSceneTex: MTLTexture?
    private func postSceneTarget(width: Int, height: Int) -> MTLTexture? {
        if postSceneTex?.width != width || postSceneTex?.height != height {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                             width: width, height: height, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]; d.storageMode = .private
            postSceneTex = device.makeTexture(descriptor: d)
        }
        return postSceneTex
    }
    // 持久可采样场景 FBO(= lwe `_rt_FullFrameBuffer`)。图层按 z 序交错合成进它;
    // composelayer 采样它的累积态作特效输入(忠实移植 lwe CScene 主 FBO + CImage 读 _rt_FullFrameBuffer)。
    /// lwe per-Image FBO 合成管线(**默认开**,忠实于 lwe):图层按 z 序交错合成进持久 lweSceneFBO,
    /// composelayer 采样它的累积态作特效输入(取代自创 compositeSceneBelow 透明 clear 近似)。
    /// 全库 57 张 A/B 源码级验证:53 张 0 diff、2 张是「读 clearcolor 清屏的真场景 FBO」的忠实改善(对齐
    /// lwe CScene.cpp:432-447 用 clearcolor 清场景 FBO);Task 4(per-Image ping-pong/blend 末移)经源码分析
    /// 与本实现像素等价、跳过。逃生开关 WP_NO_LWE_COMPOSITE=1 退回旧 compositeSceneBelow 路径(保险)。
    private var useLweComposite: Bool { ProcessInfo.processInfo.environment["WP_NO_LWE_COMPOSITE"] == nil }
    private var lweSceneTex: MTLTexture?
    private func lweSceneTarget(width: Int, height: Int) -> MTLTexture? {
        if lweSceneTex?.width != width || lweSceneTex?.height != height {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                             width: width, height: height, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]; d.storageMode = .private
            lweSceneTex = device.makeTexture(descriptor: d)
        }
        return lweSceneTex
    }
    /// 是否有任何图层带 effect(决定 isAnimated)。
    private var hasEffects = false
    /// 是否含文本图层(时钟/日期,需按秒刷新)。
    private var hasText = false
    private var lastTextRefresh: Double = -1
    /// 鼠标划过水波(cursorripple,照 WE 源码移植的 GPU 流体模拟)。
    private var hasCursorRipple = false
    /// cursorripple 只折射其 projectlayer **下方**的层(layers[0..<cutoff]);之上的草地/前景不折射。
    /// 取代旧的「任意有遮罩的层都折射」(那会让上方草地也起波,因为草层也带遮罩)。
    private var cursorRippleCutoff = 0
    private var rippleSim: CursorRippleSim?
    private var lastSimTime: Double = -1
    /// 是否在用系统音频捕获(音频条层)。
    private var usesAudio = false
    private var hasAudioBars = false
    private var hasAudioReactiveFX = false   // 任一图层/后处理特效请求 AUDIOPROCESSING(pulse 等)
    private var hasAudioReactiveScript = false  // 任一 origin/scale/angle 脚本用音频(registerAudioBuffers)
    private var currentAudio16: [Float] = []  // 本帧 16 段频谱(供 WEEffectChain 的音频 uniform)
    /// 壁纸自带音频播放(BGM/雨声);与系统声采集(usesAudio,音频条用)无关。默认随 isMuted 静音。
    private let audioPlayback = AudioPlayback()

    /// 暂停/恢复所有视频纹理 + 壁纸音频(省电:窗口隐藏、电池模式等)。
    func pauseVideos() { for l in layers { l.video?.pause() }; audioPlayback.pause() }
    func resumeVideos() { for l in layers { l.video?.resume() }; audioPlayback.resume() }
    func setAudioVolume(_ v: Double) { audioPlayback.setVolume(v) }
    func setAudioMuted(_ m: Bool) { audioPlayback.setMuted(m) }

    /// 释放音频捕获 + 停壁纸音频(场景停止/切换时调用,避免泄漏/串声)。
    func releaseAudio() { if usesAudio { AudioCapture.shared.release(); usesAudio = false }; audioPlayback.stop() }

    deinit { if usesAudio { AudioCapture.shared.release() }; audioPlayback.stop() }

    /// 诊断:当前所有粒子组的实例总数 + pipeline 是否就绪 + 首组样例。
    var particleDiagnostics: String {
        let total = particleGroups.reduce(0) { $0 + $1.instanceCount }
        var first = ""
        if let g = particleGroups.first, let inst = g.sim.instances().first {
            first = String(format: "  first: count=%d center=(%.0f,%.0f) size=%.1f alpha=%.2f canvas=%.0fx%.0f",
                           g.instanceCount, inst.center.x, inst.center.y, inst.size, inst.color.w, canvas.x, canvas.y)
        }
        var perGroup = ""
        for (i, g) in particleGroups.enumerated() {
            let ins = g.sim.instances()
            let sMin = ins.map { $0.size }.min() ?? 0, sMax = ins.map { $0.size }.max() ?? 0
            let aMax = ins.map { $0.color.w }.max() ?? 0
            // 拖尾自检:aspect=短轴/长轴,<1 即被速度拉长;elong=长/宽=1/aspect。
            let trail = g.sim.desc.isSpriteTrail
            let aspects = ins.map { $0.aspect }.filter { $0 > 0 }
            let arMin = aspects.min() ?? 0, arMax = aspects.max() ?? 0
            let c0 = ins.first?.center ?? SIMD2<Float>(0, 0)
            let ropeInfo = g.isRope ? String(format: " ROPE verts=%d sub=%d cursor=%@", g.ropeVertexCount, g.sim.desc.ropeSubdivision, g.sim.desc.followsCursor ? "Y" : "n") : ""
            perGroup += String(format: "\n  g%d: n=%d center=(%.0f,%.0f) lOrig=(%.0f,%.0f) eOrig=(%.0f,%.0f) size=%.0f..%.0f aMax=%.2f add=%@ refr=%@ scale=%.2f%@%@",
                               i, ins.count, c0.x, c0.y,
                               g.sim.desc.layerOrigin.x, g.sim.desc.layerOrigin.y,
                               g.sim.desc.emitterOrigin.x, g.sim.desc.emitterOrigin.y,
                               sMin, sMax, aMax,
                               g.additive ? "Y" : "n", g.isRefract ? "Y" : "n", g.sim.desc.layerScale.x,
                               trail ? String(format: " TRAIL aspect=%.2f..%.2f elong≈%.1f×", arMin, arMax, arMin > 0 ? 1/arMin : 0) : "",
                               ropeInfo)
        }
        return "groups=\(particleGroups.count) instances=\(total) pipeAlpha=\(pipelineParticleAlpha != nil) pipeAdd=\(pipelineParticleAdd != nil)\n\(first)\(perGroup)"
    }

    /// 逐层视差像素位移,照 lwe CImage.cpp:1104-1105:off = (parallaxDepth + amount) × displacement × sceneWidth。
    /// displacement 是 update() 每帧平滑出的归一化位移(lwe m_parallaxDisplacement);x/y **都乘 sceneWidth**
    /// (lwe referenceSize = scene width,非各轴自身)。amount 在此再出现一次(故 depth=0 层也随相机平移)。
    /// 方向:沿用本引擎既有的负号约定 —— lwe 自身坐标系的符号不适用我们(同 matModel 注释里 rotate 取负的教训)。
    private func parallaxOffset(depth: SIMD2<Float>) -> SIMD2<Float> {
        guard cameraParallax else { return .zero }
        let refW = canvas.x
        let ax = (depth.x + cameraParallaxAmount) * parallaxDisplacement.x * refW
        let ay = (depth.y + cameraParallaxAmount) * parallaxDisplacement.y * refW
        return SIMD2(-ax, -ay)
    }

    /// 每帧更新视差。time 秒,mouseNorm 为鼠标相对屏幕中心的归一化坐标 [-1,1](y 向上)。
    /// 视差位移 = 鼠标影响 × 每层 parallaxDepth(WE 鼠标驱动、静止归中,无自动漂移)。camerashake 不渲染(对齐 lwe)。
    func update(time: Double, mouseNorm: SIMD2<Float>) {
        guard !layers.isEmpty || !particleGroups.isEmpty else { return }
        // 审计修复#2:在 update 起点推进缓冲轮换索引,保证本帧的写(update 末尾)与读(随后 encode)
        // 用同一套 frameIndex。update 总在 encodeFrame 之前调用(实时与离屏皆然)。
        // 直接在环内自增(始终落在 0..<kBufferRing),避免 Int 溢出后负余数索引越界。
        frameIndex = (frameIndex + 1) % Self.kBufferRing
        let t = Float(time)
        currentTime = t
        // puppet 骨骼蒙皮动画(MDLS/MDLA):每帧求值动画 → 蒙皮顶点 → 就地更新该层 puppetVB(真 WE 角色待机
        // 摇摆/形变;lwe 无此功能)。skin() 失败/无骨返回 nil → 不更新 → 维持静态 bind 姿态(零回归)。
        // 默认启用(转置修复后 rest=I 已验证;版本保护只对 MDLS0004/MDLA0006 蒙皮)。WP_NO_PUPPET_ANIM 可临时关。
        if ProcessInfo.processInfo.environment["WP_NO_PUPPET_ANIM"] == nil {
            for i in layers.indices {
                guard let mesh = layers[i].puppetMesh, let vb = layers[i].puppetVB,
                      let skinned = mesh.skin(time: time, rate: layers[i].puppetAnimRate, animId: layers[i].puppetAnimId) else { continue }
                let bytes = MemoryLayout<Float>.stride * skinned.count
                if vb.length >= bytes { skinned.withUnsafeBytes { vb.contents().copyMemory(from: $0.baseAddress!, byteCount: bytes) } }
            }
        }
        // 本帧音频频谱。供 runLayerEffects/runPostChain 喂给 WE 的 g_AudioSpectrum16/32/64Left/Right
        // (WEEffectChain 按各数组声明的段数重采样)。喂**完整 64 段**(AudioCapture.bands),让
        // Simple_Audio_Bars 的 RESOLUTION=32 与 pulse 的 16 段都从同一高分辨率源取真值,不丢细节。
        // 音频条层(hasAudioBars)和音频反应特效(hasAudioReactiveFX,如 pulse)都要;两者皆无则不取(省锁)。
        currentAudio16 = (hasAudioReactiveFX || hasAudioBars) ? AudioCapture.shared.bands : []
        // WE 相机视差(照 lwe CScene.cpp:394-406):每帧朝目标 (mouseUV-0.5)×amount×influence 平滑逼近。
        // mouseNorm∈[-1,1](y 上) → mouseUV∈[0,1] → centered = mouseUV-0.5 = mouseNorm×0.5。
        // 平滑系数 k = clamp(cameraparallaxdelay × dt秒, 0, 1),displacement += (target-displacement)×k。
        // 用户滑块 parallaxStrength 作整体强度乘子(默认 1 = 纯 lwe 行为);静止时 target=0 → 归中。
        // 不再用旧的 0.03 像素换算魔法系数 / 瞬时跟随;逐层换算在 parallaxOffset()。
        let dt = lastFrameTime < 0 ? (1.0 / 60) : max(0, time - lastFrameTime)
        lastFrameTime = time
        let dispBefore = parallaxDisplacement   // 按需渲染:记下视差更新前位移,末尾判定本帧是否变化
        if cameraParallax {
            let userStrength = Float(PreferencesStore.shared.parallaxStrength)
            let centered = SIMD2(mouseNorm.x * 0.5, mouseNorm.y * 0.5)
            let target = centered * cameraParallaxAmount * cameraParallaxMouseInfluence * userStrength
            let k = max(0, min(1, cameraParallaxDelay * Float(dt)))
            parallaxDisplacement += (target - parallaxDisplacement) * k
        }
        // camerashake:lwe 只解析不渲染 → 不产生任何抖动(无真实公式可移植,绝不自造)。
        // 音频反应脚本:本帧频谱(仅当有音频脚本时取,省锁)。下面循环喂进各用音频的脚本(setAudioSpectrum)。
        let scrA16 = hasAudioReactiveScript ? AudioCapture.shared.spectrum16 : []
        let scrA32 = hasAudioReactiveScript ? AudioCapture.shared.spectrum32 : []
        let scrA64 = hasAudioReactiveScript ? AudioCapture.shared.bands : []
        for i in layers.indices {
            // 关键帧属性动画(WEKeyframeAnimation):求值器已实现并解析了 {animation} 包络,但**逐帧应用暂停用**——
            // 实测对打雷 composelayer 的 opacity.alpha 应用后会过曝吹白(pulse×alpha 链与 WE 不一致,需进一步校准
            // 贝塞尔手柄/与 pulse 的合成顺序)。打雷用 pulse 单独已正确,故先不应用关键帧 alpha,避免回归。
            // TODO: 校准后(对照 WE 的 opacity×pulse 链)再启用:对 weAnim 逐帧 evaluate 写回 weParams。
            if hasAudioReactiveScript {
                if layers[i].angleScript?.usesAudio == true { layers[i].angleScript?.setAudioSpectrum(s16: scrA16, s32: scrA32, s64: scrA64) }
                if layers[i].originScript?.usesAudio == true { layers[i].originScript?.setAudioSpectrum(s16: scrA16, s32: scrA32, s64: scrA64) }
                if layers[i].scaleScript?.usesAudio == true { layers[i].scaleScript?.setAudioSpectrum(s16: scrA16, s32: scrA32, s64: scrA64) }
                if layers[i].visibleScript?.usesAudio == true { layers[i].visibleScript?.setAudioSpectrum(s16: scrA16, s32: scrA32, s64: scrA64) }
                if layers[i].alphaScript?.usesAudio == true { layers[i].alphaScript?.setAudioSpectrum(s16: scrA16, s32: scrA32, s64: scrA64) }
                if layers[i].colorScript?.usesAudio == true { layers[i].colorScript?.setAudioSpectrum(s16: scrA16, s32: scrA32, s64: scrA64) }
            }
            // 缺口B/D:visible/alpha/color 脚本(lwe 每帧 reevaluate)。失败/不可用(nil)→ 保留上帧值(回退静态)。
            // visible:按 timeOfDay/Date/Math.random/音频 决定显隐(昼夜切换图层)。alpha/color:色温/淡入淡出。
            if let vs = layers[i].visibleScript,
               let b = vs.runBool(current: layers[i].visible, simTime: time, frametime: dt) {
                layers[i].visible = b
            }
            if let alScript = layers[i].alphaScript,
               let a = alScript.runScalar(current: layers[i].color.w, simTime: time, frametime: dt) {
                layers[i].color.w = a
            }
            if let cs = layers[i].colorScript,
               case .vec3(let c) = cs.runVec3(current: SIMD3(layers[i].color.x, layers[i].color.y, layers[i].color.z), simTime: time, frametime: dt) {
                layers[i].color = SIMD4(c.x, c.y, c.z, layers[i].color.w)
            }
            // angles 脚本(#3:zRotation 等):每帧跑真 WE JS 得新**局部** z 角 →
            //   渲染角 baseAngleZ = parentAbsAngle + 局部 z(弧度)→ 重建 baseModel。放最前:下面 origin/scale 块重建 baseModel 时用本帧角。
            // 父角=0 + 静态脚本时每帧得同值 → 与原结果一致。
            if let asx = layers[i].angleScript {
                // 审计修复(#1):把引擎 sim time/本帧 dt 透传给脚本,让 engine.runtime/frametime 反映真实 sim 推进
                //   (而非脚本实例内部墙钟),保证脚本动画/平滑与引擎同步、无头渲染确定。
                if case .vec3(let la) = asx.runVec3(current: layers[i].baseLocalAngles, simTime: time, frametime: dt) {
                    // 脚本 z 是度数(zRotation 滑块)→ 转弧度;父链累积角已是弧度。matModel 吃弧度。
                    layers[i].baseAngleZ = layers[i].parentAbsAngle + SceneDocument.scriptAngleZToRadians(la.z)
                    layers[i].baseModel = matModel(centerPx: layers[i].origin,
                                                   sizePx: layers[i].sizePx, angleDegZ: layers[i].baseAngleZ)
                }
            }
            // origin 脚本(挂件容器/时钟/日期/鼠标指针):每帧跑真 WE JS 得新**局部** origin →
            //   绝对 origin = parentAbsOrigin + rotateVec2(parentAbsScale × 局部 origin, parentAbsAngle)(WE 层级变换,CImage.cpp:163)
            //   → 更新 origin + 重建 baseModel。父角=0 → rotateVec2 恒等 → 与原 `pa + ps×local` 逐位相同(零变化)。
            // 放在 scale 脚本之前:scale 块重建 baseModel 时要用本帧更新后的 origin。无 origin 脚本的层不进此分支(零变化)。
            if let os = layers[i].originScript {
                if case .vec3(let local) = os.runVec3(current: layers[i].baseLocalOrigin, simTime: time, frametime: dt) {
                    let pa = layers[i].parentAbsOrigin, ps = layers[i].parentAbsScale
                    let rotated = rotateVec2(SIMD2(ps.x * local.x, ps.y * local.y), layers[i].parentAbsAngle)
                    let abs3 = SIMD3(pa.x + rotated.x, pa.y + rotated.y, pa.z + ps.z * local.z)
                    layers[i].origin = SIMD2(abs3.x, abs3.y)
                    let center = SIMD2(layers[i].origin.x + layers[i].textCenterOffset.x,
                                       layers[i].origin.y + layers[i].textCenterOffset.y)
                    layers[i].baseModel = matModel(centerPx: center,
                                                   sizePx: layers[i].sizePx, angleDegZ: layers[i].baseAngleZ)
                }
            }
            // scale 脚本(如 "Second" 秒进度条 value.x=second/60):每帧跑真 WE JS 得新 scale → 重建 baseModel。
            // 用本帧 origin(若也有 origin 脚本,上面已更新;否则恒为初值)。scale 脚本层均为图层 → textCenterOffset=0。
            if let ss = layers[i].scaleScript {
                if case .vec3(let s) = ss.runVec3(current: layers[i].baseScale, simTime: time, frametime: dt) {
                    let eff = SIMD2(layers[i].baseSize.x * s.x, layers[i].baseSize.y * s.y)
                    layers[i].sizePx = eff
                    layers[i].baseModel = matModel(centerPx: layers[i].origin,
                                                   sizePx: eff, angleDegZ: layers[i].baseAngleZ)
                }
            }
            // 对象 origin 关键帧动画(头发/发饰随头摆动:WE 贝塞尔关键帧,relative 偏移已在 evaluate 里 +base)。
            // 头/眼 puppet 待机摆头时,头发缝隙靠这条同步摆动 → 眼稳定从刘海缝隙露出(否则头发钉死、眼被盖)。
            // 无父链层(头发0202/发饰 parent=None)→ parentAbs* 默认 → origin = 求值的绝对动画值。与打雷 alpha 无关,安全。
            if let oka = layers[i].originKeyAnim {
                let v = oka.evaluate(time: t)
                let local = SIMD3<Float>(v.count > 0 ? v[0] : 0, v.count > 1 ? v[1] : 0, v.count > 2 ? v[2] : 0)
                let pa = layers[i].parentAbsOrigin, ps = layers[i].parentAbsScale
                let rotated = rotateVec2(SIMD2(ps.x * local.x, ps.y * local.y), layers[i].parentAbsAngle)
                layers[i].origin = SIMD2(pa.x + rotated.x, pa.y + rotated.y)
                layers[i].baseModel = matModel(centerPx: layers[i].origin, sizePx: layers[i].sizePx, angleDegZ: layers[i].baseAngleZ)
            }
            // 音频条 opacity 关键帧(剑音条 id=510/654 静态回退 opacity=0 → 全透明不可见的真因):把 weAnim 逐帧
            // 求值写回 weParams。放行 audioBars 层 **+ 非 pulse 的 region composelayer**(frameBufferInput &&
            // regionFit:御剑的剑音条/下音条/中音条都是 composelayer,audioBars==nil,但 opacity 是关键帧动画)。
            // **regionFit 天然排除打雷 pulse**(pulse 是 frameBufferInput && !regionFit)→ 不会触发 opacity×pulse
            // 过曝回归(与 1026 注释一致)。修缺口:任何带 opacity 关键帧的音频 composelayer 此前都不显示。
            if layers[i].audioBars != nil || (layers[i].frameBufferInput && layers[i].regionFit) {
                for j in layers[i].effects.indices {
                    for (key, anim) in layers[i].effects[j].weAnim {
                        let vals = anim.evaluate(time: t)
                        if vals.count == 1 { layers[i].effects[j].weParams[key] = String(vals[0]) }
                        else if vals.count >= 3 { layers[i].effects[j].weParams[key] = "\(vals[0]) \(vals[1]) \(vals[2])" }
                    }
                }
            }
            let off = parallaxOffset(depth: layers[i].parallax)
            layers[i].mvp = proj * matTranslate(off.x, off.y) * layers[i].baseModel
            // 视频纹理:每帧拉取当前帧替换图层纹理。
            if let vt = layers[i].video {
                layers[i].texture = vt.currentTexture()
            }
        }

        // 音频频谱条:不再在 CPU 重画纹理 —— 底纹理恒为透明画布,真 WE Simple_Audio_Bars shader
        // 每帧在 runLayerEffects 里据 currentAudio16(64 段)把条画上(+ perspective 透视),见下。

        // 文本图层(时钟/日期):每秒检查一次,字符串变了才重渲染纹理。
        if hasText, lastTextRefresh < 0 || time - lastTextRefresh >= 1.0 {
            lastTextRefresh = time
            let loader = MTKTextureLoader(device: device)
            for i in layers.indices {
                guard let ts = layers[i].text else { continue }
                // 审计修复(#1):透传引擎 sim time 给脚本驱动的文本(engine.runtime 同步;时钟/日期仍走 JSC 原生 Date())。
                let now = TextLayerRenderer.currentString(ts.desc, simTime: time)
                if now != ts.lastString || lastTextRefresh == time {
                    ts.lastString = now
                    if let t = makeTextTexture(ts.desc, loader: loader, simTime: time) {
                        layers[i].texture = t.0
                        // 盒子型文本:新字符串纹理纵横比可能变(如日期长短),按盒子重新适配 + 重建变换。
                        if let box = layers[i].textBox {
                            let q = textQuad(texW: Float(t.1), texH: Float(t.2), box: box,
                                             hAlign: ts.desc.align, vAlign: ts.desc.verticalAlign)
                            layers[i].sizePx = q.size
                            layers[i].textCenterOffset = q.centerOffset
                            let center = SIMD2(layers[i].origin.x + q.centerOffset.x,
                                               layers[i].origin.y + q.centerOffset.y)
                            layers[i].baseModel = matModel(centerPx: center, sizePx: q.size,
                                                           angleDegZ: layers[i].baseAngleZ)
                            let off = parallaxOffset(depth: layers[i].parallax)
                            layers[i].mvp = proj * matTranslate(off.x, off.y) * layers[i].baseModel
                        }
                    }
                }
            }
        }

        // 鼠标在画布像素中的位置。matOrtho 把 [0,W]→[-1,1],故场景坐标是 0..W(原点在角)。
        // mouseNorm [-1,1] y向上 → 画布 [0,W]/[0,H]:  c = (norm+1)/2 * size。
        let cursorCanvas = SIMD2((mouseNorm.x + 1) * 0.5 * canvas.x,
                                 (mouseNorm.y + 1) * 0.5 * canvas.y)
        // 光标归一化 UV [0,1](y 向上)。喂 WE 交互特效(xray/depthparallax)的 pointer 量。
        cursorUV = SIMD2((mouseNorm.x + 1) * 0.5, (mouseNorm.y + 1) * 0.5)

        // 鼠标划过水波:把光标 UV [0,1](y 向上=屏幕)喂给流体模拟。模拟步进在 render() 里做。
        if hasCursorRipple, let sim = rippleSim {
            let uv = SIMD2((mouseNorm.x + 1) * 0.5, (mouseNorm.y + 1) * 0.5)
            sim.setPointer(uv)
        }

        // 粒子:按真实 dt 推进。关键(修「粒子太快」):
        //  ① clamp dt——卡顿/掉帧瞬间 dt 飙大,单步 pos+=vel*dt 会让粒子暴冲;封顶防爆。
        //  ② 子步进——把 dt 拆成 ≤1/60 的固定小步多次推进。带重力/加速的雪雨用大步 Euler 积分会
        //     过冲(走得比真实远 → 比 WE 的 60fps 快);拆成小步后积分精度与 WE 一致,速度才对。
        if !particleGroups.isEmpty {
            let realDt = lastUpdateTime < 0 ? (1.0 / 60) : max(0, time - lastUpdateTime)
            lastUpdateTime = time
            let dt = min(realDt, 1.0 / 20)                 // 封顶 50ms,防卡顿暴冲
            let sub = 1.0 / 60.0
            let nSub = max(1, Int((dt / sub).rounded(.up)))
            let sdt = Float(dt / Double(nSub))
            for g in particleGroups {
                if g.sim.desc.followsCursor { g.sim.cursorOrigin = cursorCanvas }   // 拖尾跟随光标
                for _ in 0..<nSub { g.sim.step(dt: sdt, time: t) }
                // rope/ropetrail:每帧用当前粒子链重建带状网格(三角形列表),走专属管线。
                // 审计修复#2:写入本帧选用的缓冲套(frameIndex % 3),不再每帧覆写同一块。
                let ring = frameIndex % Self.kBufferRing
                if g.isRope {
                    let verts = g.sim.ropeVertices()
                    g.ropeVertexCount = verts.count
                    if !verts.isEmpty {
                        let needed = verts.count * MemoryLayout<RopeVertex>.stride
                        if g.ropeBuffers[ring] == nil || g.ropeBuffers[ring]!.length < needed {
                            g.ropeBuffers[ring] = device.makeBuffer(length: max(needed, 4096), options: .storageModeShared)
                        }
                        if let buf = g.ropeBuffers[ring] {
                            verts.withUnsafeBytes { raw in
                                buf.contents().copyMemory(from: raw.baseAddress!, byteCount: needed)
                            }
                        }
                    }
                    continue
                }
                let insts = g.sim.instances()
                g.instanceCount = insts.count
                guard !insts.isEmpty else { continue }
                let needed = insts.count * MemoryLayout<ParticleInstance>.stride
                if g.instanceBuffers[ring] == nil || g.instanceBuffers[ring]!.length < needed {
                    g.instanceBuffers[ring] = device.makeBuffer(length: max(needed, 4096), options: .storageModeShared)
                }
                if let buf = g.instanceBuffers[ring] {
                    insts.withUnsafeBytes { raw in
                        buf.contents().copyMemory(from: raw.baseAddress!, byteCount: needed)
                    }
                }
            }
        }

        // 按需渲染判定:连续动画内容(粒子/视频/特效/文本/各脚本/音频条/水波)→ 帧帧在变,必画;
        // 否则仅视差驱动 → 仅当视差位移本帧移动了 或 鼠标移动了 才需重画。两者皆无 → 画面与上帧一致,跳过渲染。
        let alwaysAnimating = !particleGroups.isEmpty || hasVideo || hasEffects || hasText
            || hasScaleScript || hasOriginScript || hasAngleScript || hasAudioBars || hasCursorRipple
        let parallaxMoved = cameraParallax
            && (simd_distance(parallaxDisplacement, dispBefore) > 1e-5 || mouseNorm != lastMouseForChange)
        frameDidChange = alwaysAnimating || parallaxMoved
        lastMouseForChange = mouseNorm
    }

    /// 是否有任何图层带视差(决定要不要起动画循环)。
    private(set) var hasParallax = false
    /// 按需渲染:本帧画面相对上帧是否有变化。无连续动画内容(粒子/视频/特效/文本/脚本/音频条/水波)、
    /// 且视差已收敛+鼠标未动时为 false → SceneRenderer 跳过本帧渲染(空闲 CPU 趋近 0)。默认 true(首帧必画)。
    private(set) var frameDidChange = true
    private var lastMouseForChange = SIMD2<Float>(-999, -999)   // 上帧鼠标(变化检测;初值异常 → 首帧必变)
    /// 正交投影矩阵(load 时算好,每帧视差更新复用)。
    private var proj = matrix_identity_float4x4

    /// 主 pass 的合成 uniform。特效已在 effectedTexture 里;这里只配鼠标水波折射 combine。
    private func makeEffectUniforms(hasMask: Bool, cursorRipple: Bool) -> EffectUniforms {
        var u = EffectUniforms()
        u.time = currentTime
        u.hasMask = hasMask ? 1 : 0
        u.cursorRipple = cursorRipple ? 1 : 0
        u.rippleStrength = rippleSim?.rippleStrength ?? 1
        return u
    }

    private var _whiteTex: MTLTexture?
    /// 1×1 白色纹理,供纯色填充层复用。
    /// 审计修复#7:返回可选——显存耗尽时 makeTexture 返回 nil,原 `!` 会崩;改为返回 nil,调用方跳过该层。
    private func whiteTexture() -> MTLTexture? {
        if let t = _whiteTex { return t }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        desc.usage = .shaderRead
        guard let t = device.makeTexture(descriptor: desc) else { return nil }   // 审计修复#7:不再强解包
        var px: [UInt8] = [255, 255, 255, 255]
        t.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &px, bytesPerRow: 4)
        _whiteTex = t
        return t
    }

    /// 透明画布纹理(音频条层底图)。真 WE Simple_Audio_Bars shader 在其上据音频频谱画条
    /// (TRANSPARENCY=REPLACE:输出 alpha=bar*opacity),再由 perspective 透视贴到场景。
    private func transparentTexture(width: Int, height: Int) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        desc.usage = [.shaderRead]; desc.storageMode = .shared
        guard let t = device.makeTexture(descriptor: desc) else { return nil }
        let px = [UInt8](repeating: 0, count: width * height * 4)   // 全 0 = 透明黑
        px.withUnsafeBytes {
            t.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                      withBytes: $0.baseAddress!, bytesPerRow: width * 4)
        }
        return t
    }

    /// 文本图层 → 纹理。返回 (纹理, 像素宽, 像素高)。
    private func makeTextTexture(_ desc: TextLayerDesc, loader: MTKTextureLoader, simTime: Double? = nil) -> (MTLTexture, Int, Int)? {
        guard let r = TextLayerRenderer.render(desc, simTime: simTime),
              let tex = makeTexture(.rgba8(pixels: r.pixels, width: r.width, height: r.height), loader: loader)
        else { return nil }
        return (tex, r.width, r.height)
    }

    /// RGBA8 双线性下采样到最长边 ≤ maxDim(纹理质量设置用)。
    private static func downsampleRGBA(_ src: [UInt8], _ w: Int, _ h: Int, maxDim: Int) -> ([UInt8], Int, Int) {
        let scale = Double(maxDim) / Double(max(w, h))
        let nw = max(1, Int((Double(w) * scale).rounded()))
        let nh = max(1, Int((Double(h) * scale).rounded()))
        var out = [UInt8](repeating: 0, count: nw * nh * 4)
        let sx = Double(w) / Double(nw), sy = Double(h) / Double(nh)
        src.withUnsafeBufferPointer { sp in
            out.withUnsafeMutableBufferPointer { dp in
                for y in 0..<nh {
                    let fy = (Double(y) + 0.5) * sy - 0.5
                    let y0 = max(0, min(h - 1, Int(fy.rounded(.down))))
                    let y1 = min(h - 1, y0 + 1)
                    let wy = fy - Double(y0)
                    for x in 0..<nw {
                        let fx = (Double(x) + 0.5) * sx - 0.5
                        let x0 = max(0, min(w - 1, Int(fx.rounded(.down))))
                        let x1 = min(w - 1, x0 + 1)
                        let wx = fx - Double(x0)
                        let i00 = (y0 * w + x0) * 4, i01 = (y0 * w + x1) * 4
                        let i10 = (y1 * w + x0) * 4, i11 = (y1 * w + x1) * 4
                        let o = (y * nw + x) * 4
                        for c in 0..<4 {
                            let top = Double(sp[i00 + c]) * (1 - wx) + Double(sp[i01 + c]) * wx
                            let bot = Double(sp[i10 + c]) * (1 - wx) + Double(sp[i11 + c]) * wx
                            dp[o + c] = UInt8(max(0, min(255, (top * (1 - wy) + bot * wy).rounded())))
                        }
                    }
                }
            }
        }
        return (out, nw, nh)
    }

    private func makeTexture(_ decoded: DecodedTex, loader: MTKTextureLoader) -> MTLTexture? {
        switch decoded {
        case .encoded(let data):
            let opts: [MTKTextureLoader.Option: Any] = [
                .SRGB: false,
                .generateMipmaps: true,
                .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue)
            ]
            return try? loader.newTexture(data: data, options: opts)
        case .rgba8(let pixels, let w, let h):
            // 纹理质量:超过上限的大纹理在上传前下采样,省显存/带宽(小纹理不变)。
            var px = pixels, tw = w, th = h
            let maxDim = PreferencesStore.shared.textureMaxDimension
            if maxDim > 0, max(w, h) > maxDim {
                (px, tw, th) = Self.downsampleRGBA(pixels, w, h, maxDim: maxDim)
            }
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: tw, height: th, mipmapped: false)
            desc.usage = .shaderRead
            guard let tex = device.makeTexture(descriptor: desc) else { return nil }
            px.withUnsafeBytes { raw in
                tex.replace(region: MTLRegionMake2D(0, 0, tw, th), mipmapLevel: 0,
                            withBytes: raw.baseAddress!, bytesPerRow: tw * 4)
            }
            return tex
        case .video:
            // 视频纹理不走这里(load 时单独建 VideoTexture + 首帧兜底)。
            return nil
        }
    }

    // MARK: - 渲染

    /// 渲染图层 + 非折射粒子。drawLayers=false 时只画粒子(后处理之后叠 aboveBloom 粒子用)。
    /// particleFilter 决定画哪些非折射粒子组(nil=全部;用于按 bloom 上下分批)。
    func encode(into encoder: MTLRenderCommandEncoder, drawLayers: Bool = true,
                particleFilter: ((ParticleGroupInfo) -> Bool)? = nil,
                layerRange: Range<Int>? = nil, drawParticles: Bool = true) {
        encoder.setFragmentSamplerState(sampler, index: 0)
        // 宽高比适配(图层与粒子顶点共用,buffer 3)。
        var ndc = ndcScale
        encoder.setVertexBytes(&ndc, length: MemoryLayout<SIMD2<Float>>.stride, index: 3)

        // 图层(底图)。WP_HIDE_IDS=482,216,... 诊断:按 pkg id 隐藏指定图层(定位遮挡者)。
        // layerRange:A 交错路径下只画区间内图层(逐段累积进 sceneFBO);nil=全画(旧路径)。
        for (li, layer) in layers.enumerated() where drawLayers && layer.visible && (layerRange?.contains(li) ?? true) && !Self.hideLayerIds.contains(layer.id) {
            // puppet 层:用单位空间 mesh 顶点 + 该层 mvp(proj×matModel)**直渲索引三角网格**(替代平面 quad),
            // 偏心/出界顶点不裁——照 lwe 把局部 puppet 顶点直接用场景投影渲(setupPuppetGeometryCallback)。
            // 非 puppet 层走原 quad 逻辑。
            let isPup = layer.puppetVB != nil && layer.puppetIB != nil
            // 每层重绑几何@0(材质路径会覆盖 index0/1,故不能只在循环外绑一次)。
            encoder.setVertexBuffer(isPup ? layer.puppetVB : quadBuffer, offset: 0, index: 0)
            func drawGeom() {
                if isPup, let ib = layer.puppetIB {
                    encoder.drawIndexedPrimitives(type: .triangle, indexCount: layer.puppetIndexCount,
                                                  indexType: .uint16, indexBuffer: ib, indexBufferOffset: 0)
                } else {
                    encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                }
            }
            var u = VertexUniforms(mvp: layer.mvp, color: layer.color,
                                   fb: SIMD4((layer.frameBufferInput && !layer.regionFit) ? 1 : 0, 0, 0, 0))
            encoder.setVertexBytes(&u, length: MemoryLayout<VertexUniforms>.stride, index: 1)
            let baseTex = layer.effectedTexture ?? layer.texture
            // 基础材质 combo 路径:有意义 combo(NORMALMAP/REFLECTION/LIGHTING/EMISSIVE/PBR/...)的图层
            // 用转译的真 WE genericimage 变体渲染;plain 层走下面轻量 scene_fragment(零回归)。
            // base 变体 = albedo×color,与 scene_fragment 等价(WP_MATERIAL_ALL 强制走此路验证)。
            // puppet 层 albedo 已是渲好的 FBO,不走材质转译路径。
            if !isPup, let sh = layer.materialShader, let we = weEffects,
               we.materialNeedsTranspiledPath(shader: sh, combos: layer.materialCombos) {
                if we.encodeMaterialLayer(encoder, shader: sh, combos: layer.materialCombos,
                                          mvp: layer.mvp, model: layer.baseModel, color: layer.color,
                                          albedo: baseTex, albedoFlags: layer.texFlags, aux: [:],
                                          ambient: ambientColor,
                                          constants: layer.materialConstants, sceneFB: nil,
                                          audio16: currentAudio16) {   // 基础材质 AUDIOPROCESSING combo 频谱
                    continue
                }
            }
            // 采样器按图层贴图真实 flags 选(NoInterpolation→nearest;ClampUVs→clamp 否则 repeat)。
            // 仅当直接贴**原始**贴图(无特效输出)时用其 flags;effectedTexture 是引擎渲出的全屏纹理
            // (UV∈[0,1])→ 用默认 clamp+linear。图层 quad UV∈[0,1],故 wrap 对非平铺层无影响(安全)。
            let layerSampler = (layer.effectedTexture == nil) ? samplerFor(layer.texFlags) : sampler
            encoder.setFragmentSamplerState(layerSampler, index: 0)
            encoder.setFragmentTexture(baseTex, index: 0)
            // 对象级 colorBlendMode>0:framebuffer-fetch 按方程把本层与背景混合(等价 WE 的
            // effectpassthrough+BLENDMODE 额外 pass)。仅这些层走此路径,其余层逻辑不变。
            if layer.colorBlendMode > 0, let pcb = pipelineColorBlend {
                encoder.setRenderPipelineState(pcb)
                var mode = Int32(layer.colorBlendMode)
                encoder.setFragmentBytes(&mode, length: MemoryLayout<Int32>.stride, index: 0)
                drawGeom()
                continue
            }
            switch layer.blend {
            case .normal:      encoder.setRenderPipelineState(pipelineNormal)
            case .translucent: encoder.setRenderPipelineState(pipelineTranslucent)
            case .additive:    encoder.setRenderPipelineState(pipelineAdditive)
            }
            // 所有图层特效都已由真 WE shader 链(runLayerEffects)应用到 effectedTexture,直接贴。
            // 主 pass 唯一额外做的事:鼠标水波折射 combine(cursorripple,denylist 在 CursorRippleSim
            // 产出力场,这里照 WE cursorripple_combine.frag 折射底图;仅水面遮罩层 + 有力场时启用)。
            // 仅对 cursorripple projectlayer **下方**的层折射(li < cutoff);上方草地/前景不折射
            // —— 取代旧的「任意有遮罩层都折射」(草层也带遮罩 → 草地起波)。照 WE 层序语义。
            let applyRipple = rippleSim != nil && li < cursorRippleCutoff
            var fx = makeEffectUniforms(hasMask: layer.effectMask != nil, cursorRipple: applyRipple)
            encoder.setFragmentBytes(&fx, length: MemoryLayout<EffectUniforms>.stride, index: 0)
            encoder.setFragmentTexture(layer.effectMask ?? baseTex, index: 1)  // 槽1=水面遮罩(无则占位)
            encoder.setFragmentTexture(rippleSim?.fieldTexture ?? baseTex, index: 2)  // 槽2=力场(无则占位)
            drawGeom()
        }
        encoder.setFragmentSamplerState(sampler, index: 0)   // 还原默认采样器(粒子等后续绘制用)

        // 粒子(覆盖在图层之上,实例化绘制)。任一前置条件缺失则安全跳过,绝不崩溃。
        // drawParticles=false:A 交错路径逐段画图层时不画粒子,留到整帧末统一画(粒子覆盖全部图层之上)。
        if drawParticles, !particleGroups.isEmpty, pipelineParticleAdd != nil, pipelineParticleAlpha != nil {
            encoder.setVertexBuffer(quadBuffer, offset: 0, index: 0)
            var projVar = proj
            encoder.setVertexBytes(&projVar, length: MemoryLayout<simd_float4x4>.stride, index: 1)
            // 粒子也走 scene_fragment:给一份「无效果」的 uniform,避免读脏数据。
            var blankFx = EffectUniforms()
            encoder.setFragmentBytes(&blankFx, length: MemoryLayout<EffectUniforms>.stride, index: 0)
            let ring = frameIndex % Self.kBufferRing   // 审计修复#2:读本帧写入的那套缓冲(与 update 写入一致)
            for g in particleGroups where g.instanceCount > 0 && !g.isRefract && !g.isRope {
                if let f = particleFilter, !f(ParticleGroupInfo(aboveBloom: g.aboveBloom)) { continue }
                guard let buf = g.instanceBuffers[ring],
                      let pipeline = g.additive ? pipelineParticleAdd : pipelineParticleAlpha else { continue }
                encoder.setRenderPipelineState(pipeline)
                encoder.setVertexBuffer(buf, offset: 0, index: 2)
                encoder.setFragmentTexture(g.texture, index: 0)
                encoder.setFragmentTexture(g.texture, index: 1)   // 槽1 占位(粒子 hasMask=0 不会采)
                encoder.setFragmentTexture(g.texture, index: 2)   // 槽2 占位(粒子 cursorRipple=0 不会采)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: g.instanceCount)
            }
            // rope 带状网格:三角形列表(每子段 6 顶点),proj@1/ndcScale@3 已绑定,顶点缓冲@2。
            // WP_NO_ROPE 环境钩子:置位时跳过 rope 绘制(无头验证用,正常运行零影响)。
            let skipRope = ProcessInfo.processInfo.environment["WP_NO_ROPE"] != nil
            for g in particleGroups where !skipRope && g.isRope && g.ropeVertexCount >= 3 {
                if let f = particleFilter, !f(ParticleGroupInfo(aboveBloom: g.aboveBloom)) { continue }
                guard let buf = g.ropeBuffers[ring],   // 审计修复#2:读本帧写入的那套 rope 缓冲
                      let pipeline = g.additive ? pipelineRopeAdd : pipelineRopeAlpha else { continue }
                encoder.setRenderPipelineState(pipeline)
                encoder.setVertexBuffer(buf, offset: 0, index: 2)
                encoder.setFragmentTexture(g.texture, index: 0)
                encoder.setFragmentTexture(g.texture, index: 1)   // 槽1 占位(rope hasMask=0 不会采)
                encoder.setFragmentTexture(g.texture, index: 2)   // 槽2 占位(rope cursorRipple=0 不会采)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: g.ropeVertexCount)
            }
        }
    }

    var hasRefractParticles: Bool {
        pipelineParticleRefract != nil && particleGroups.contains { $0.isRefract }
    }
    /// 是否有「后处理之下」的折射粒子(在 bloom 前的场景 pass 里绘制)。
    private var hasBelowBloomRefract: Bool {
        pipelineParticleRefract != nil && particleGroups.contains { $0.isRefract && !$0.aboveBloom }
    }
    /// 是否有「后处理之上」的折射粒子(在 bloom 后叠加,采样已后处理的画面)。
    private var hasAboveBloomRefract: Bool {
        pipelineParticleRefract != nil && particleGroups.contains { $0.isRefract && $0.aboveBloom }
    }

    /// 折射粒子单独绘制:采样已渲好的场景底图 sceneFB(对应 WE _rt_FullFrameBuffer)。
    /// aboveBloom 决定画哪一批(nil=全部)。
    private func encodeRefract(into encoder: MTLRenderCommandEncoder, sceneFB: MTLTexture, aboveBloom: Bool? = nil) {
        guard let alphaPipe = pipelineParticleRefract else { return }
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.setVertexBuffer(quadBuffer, offset: 0, index: 0)
        var projVar = proj
        encoder.setVertexBytes(&projVar, length: MemoryLayout<simd_float4x4>.stride, index: 1)
        var ndc = ndcScale
        encoder.setVertexBytes(&ndc, length: MemoryLayout<SIMD2<Float>>.stride, index: 3)
        let ring = frameIndex % Self.kBufferRing   // 审计修复#2:读本帧写入的那套实例缓冲
        for g in particleGroups where g.instanceCount > 0 && g.isRefract && (aboveBloom == nil || g.aboveBloom == aboveBloom!) {
            guard let buf = g.instanceBuffers[ring] else { continue }
            // 按材质真实 blending 选折射管线:additive(水花 halo,blending:additive)用加性,暗色 albedo×底图 ≈ 不加,
            // 不再像旧实现那样硬套 alpha 把暗色不透明地画成黑块;其余折射(雨滴)走 translucent。
            encoder.setRenderPipelineState(g.additive ? (pipelineParticleRefractAdd ?? alphaPipe) : alphaPipe)
            encoder.setVertexBuffer(buf, offset: 0, index: 2)
            var refractAmount = g.sim.desc.refractAmount   // 材质真实 g_RefractAmount(替代硬编码 0.05)
            encoder.setVertexBytes(&refractAmount, length: MemoryLayout<Float>.stride, index: 4)
            encoder.setFragmentTexture(g.texture, index: 0)                       // 反照率(雨滴贴图)
            encoder.setFragmentTexture(g.normalTexture ?? g.texture, index: 1)    // 法线贴图
            encoder.setFragmentTexture(sceneFB, index: 2)                         // 场景底图
            var hasNormal: Int32 = g.normalTexture != nil ? 1 : 0
            encoder.setFragmentBytes(&hasNormal, length: MemoryLayout<Int32>.stride, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: g.instanceCount)
        }
    }

    /// 折射用离屏底图(与目标同尺寸)。
    private func refractSceneTarget(width: Int, height: Int) -> MTLTexture? {
        if refractSceneTex?.width != width || refractSceneTex?.height != height {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                             width: width, height: height, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]; d.storageMode = .private
            refractSceneTex = device.makeTexture(descriptor: d)
        }
        return refractSceneTex
    }

    private var sceneBelowTex: MTLTexture?
    /// frame_builder 等整帧底图特效的 _rt_FullFrameBuffer:把 layers[0..<upTo](该层之下、按序已合成、
    /// 含各自 effectedTexture)画进画布尺寸离屏纹理。无 ndcScale(画布空间,特效按 [0,1] 屏幕UV采样)。
    /// 只画普通/透明/加性混合;colorBlendMode 层按其基础混合近似(底图仅用于边框外区域,影响极小)。
    private func compositeSceneBelow(upTo: Int, commandBuffer cmd: MTLCommandBuffer) -> MTLTexture? {
        let w = Int(canvas.x), h = Int(canvas.y)
        guard w > 0, h > 0, upTo > 0 else { return nil }
        if sceneBelowTex?.width != w || sceneBelowTex?.height != h {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                             width: w, height: h, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]; d.storageMode = .private
            sceneBelowTex = device.makeTexture(descriptor: d)
        }
        guard let target = sceneBelowTex else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        // 缺口F:用场景 clearColor(alpha=1)清屏,而非透明黑——对齐 lwe `_rt_FullFrameBuffer`
        // (CScene.cpp:121 glClearColor(rgb,1.0f))与主路径 encodeLweScene。bloom/折射壁纸退此兜底时,
        // composelayer 音频条 shader 用 `scene.w` 调制,透明底(α=0)会把频谱乘没 → α=1 背景使其可见。
        // (实测 Esperanta 回归是 manifest 重生成所致,非本改动;F 经全库回归确认安全。)
        pass.colorAttachments[0].clearColor = clearColor
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        enc.label = "sceneBelow"
        enc.setFragmentSamplerState(sampler, index: 0)
        var ndc = SIMD2<Float>(1, 1)   // 画布空间,无宽高比 cover
        enc.setVertexBytes(&ndc, length: MemoryLayout<SIMD2<Float>>.stride, index: 3)
        enc.setVertexBuffer(quadBuffer, offset: 0, index: 0)
        var blankFx = EffectUniforms()
        enc.setFragmentBytes(&blankFx, length: MemoryLayout<EffectUniforms>.stride, index: 0)
        for j in 0..<min(upTo, layers.count) where layers[j].visible {
            let layer = layers[j]
            var u = VertexUniforms(mvp: layer.mvp, color: layer.color,
                                   fb: SIMD4((layer.frameBufferInput && !layer.regionFit) ? 1 : 0, 0, 0, 0))
            enc.setVertexBytes(&u, length: MemoryLayout<VertexUniforms>.stride, index: 1)
            let tex = layer.effectedTexture ?? layer.texture
            switch layer.blend {
            case .normal:      enc.setRenderPipelineState(pipelineNormal)
            case .translucent: enc.setRenderPipelineState(pipelineTranslucent)
            case .additive:    enc.setRenderPipelineState(pipelineAdditive)
            }
            enc.setFragmentTexture(tex, index: 0)
            enc.setFragmentTexture(tex, index: 1)   // 槽1 占位(blankFx hasMask=0 不采)
            enc.setFragmentTexture(tex, index: 2)   // 槽2 占位
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        enc.endEncoding()
        return target
    }

    // 区域性 composelayer 的 region 裁剪纹理池(按尺寸+用途键复用)。
    private var regionTexPool: [String: MTLTexture] = [:]
    /// 该层 quad 在画布纹理里的像素矩形(mvp 投 unit quad 四角取包围盒;画布纹理 v 向下)。
    /// 用于区域性 composelayer:把整画布场景底图 + 全画布遮罩(影子)裁到该层 region → 特效在 region [0,1] 跑。
    private func regionPixelRect(_ layer: GPULayer) -> (x: Int, y: Int, w: Int, h: Int)? {
        let W = Int(canvas.x), H = Int(canvas.y)
        guard W > 0, H > 0 else { return nil }
        let corners = [SIMD4<Float>(-0.5,-0.5,0,1), SIMD4(0.5,-0.5,0,1), SIMD4(-0.5,0.5,0,1), SIMD4(0.5,0.5,0,1)]
        var u0: Float = 1, v0: Float = 1, u1: Float = 0, v1: Float = 0
        for c in corners {
            let p = layer.mvp * c
            guard abs(p.w) > 1e-6 else { return nil }
            let u = (p.x / p.w) * 0.5 + 0.5
            let v = (-(p.y / p.w)) * 0.5 + 0.5
            u0 = min(u0, u); u1 = max(u1, u); v0 = min(v0, v); v1 = max(v1, v)
        }
        // 注:曾试「不钳裁、region 覆盖完整 quad」修中音条「只有左边」(超界条),但实测**弄坏 Postscript 云层**
        // (它也是 regionFit、quad 略超画布,unclamp 后云扭曲读到透明边 → 整片变暗,meanDiff 60)→ 已撤回钳裁。
        // 中音条超界错位待更安全的针对性方案(只对音频条而非所有 regionFit composelayer)。
        let px0 = max(0, min(W - 1, Int(u0 * Float(W))))
        let py0 = max(0, min(H - 1, Int(v0 * Float(H))))
        let rw = max(8, min(W - px0, Int((u1 - u0) * Float(W))))
        let rh = max(8, min(H - py0, Int((v1 - v0) * Float(H))))
        return (px0, py0, rw, rh)
    }
    /// blit 把画布尺寸纹理裁到 region 矩形(场景底图、全画布遮罩用同一 rect → 对齐)。
    private func cropToRegion(_ src: MTLTexture, rect r: (x: Int, y: Int, w: Int, h: Int), key: String, commandBuffer cmd: MTLCommandBuffer) -> MTLTexture? {
        guard r.x + r.w <= src.width, r.y + r.h <= src.height else { return nil }
        let k = "\(key)@\(r.w)x\(r.h)@\(src.pixelFormat.rawValue)"
        var t = regionTexPool[k]
        if t == nil || t!.width != r.w || t!.height != r.h {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: src.pixelFormat, width: r.w, height: r.h, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]; d.storageMode = .private
            t = device.makeTexture(descriptor: d); regionTexPool[k] = t
        }
        guard let dst = t, let blit = cmd.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: src, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: r.x, y: r.y, z: 0),
                  sourceSize: MTLSize(width: r.w, height: r.h, depth: 1),
                  to: dst, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        return dst
    }

    private var postedSceneTex: MTLTexture?
    /// 后处理输出的中间画面(供 aboveBloom 粒子在其上叠加 + 折射采样);独立于 refractSceneTex 避免别名冲突。
    private func postedSceneTarget(width: Int, height: Int) -> MTLTexture? {
        if postedSceneTex?.width != width || postedSceneTex?.height != height {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                             width: width, height: height, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]; d.storageMode = .private
            postedSceneTex = device.makeTexture(descriptor: d)
        }
        return postedSceneTex
    }

    /// 每帧:逐图层、逐特效跑真 WE 转译 shader 链(顺序叠加),产出 effectedTexture 供 encode 绑定。
    /// 不再 all-or-nothing:manifest 里有且非 denylist 的 effect 跑真 shader,其余在链里跳过(passthrough)。
    private var compositeFramesRendered = 0
    private func runLayerEffects(commandBuffer cmd: MTLCommandBuffer, skipFrameBufferInput: Bool = false) {
        guard weEffects != nil else { return }
        // 合成层最大帧数(性能):渲满 N 帧后冻结特效输出(保留上次 effectedTexture),不再每帧重算。
        // 0=∞ 不限(默认,安全;音频/水波等持续动画需要不限)。仅在用户调低时省 GPU。
        let maxF = PreferencesStore.shared.compositeMaxFrames
        if maxF > 0 && compositeFramesRendered >= maxF { return }
        compositeFramesRendered += 1
        // 任一带特效的图层(含音频条层)。skipFrameBufferInput(A 交错路径会跑时):frameBufferInput composelayer
        // 的特效改在 encodeLweScene 里按 z 序、采样累积的 lweSceneFBO 算(取代 compositeSceneBelow 重渲);
        // 此处跳过它们。否则(默认 / 折射+postProcess 等 encodeLweScene 不跑的路径)仍用 compositeSceneBelow 兜底。
        for i in layers.indices where layers[i].useWE || layers[i].audioBars != nil {
            if skipFrameBufferInput && layers[i].frameBufferInput { continue }
            computeLayerEffect(i, sceneInput: nil, commandBuffer: cmd)
        }
    }

    /// 算单个图层的 effectedTexture(供 runLayerEffects 旧路径 与 A 的 encodeLweScene 交错路径共用)。
    /// sceneInput:frameBufferInput 层的「下方场景」输入——nil → compositeSceneBelow(旧路径重渲);
    /// A 路径传入累积到该层之下的持久 lweSceneFBO(忠实对齐 lwe 读 _rt_FullFrameBuffer)。
    private func computeLayerEffect(_ i: Int, sceneInput: MTLTexture?, commandBuffer cmd: MTLCommandBuffer) {
        guard let we = weEffects else { return }
            var current = layers[i].texture
            // composelayer/_rt_FullFrameBuffer:特效链输入 = 该层之下已合成的整帧场景(照 WE FBOProvider 取场景主 FBO)。
            // 之上跑 pulse(据 mask 在云带周期增亮=打雷)/opacity/调色等,结果存 effectedTexture 由 encode 按其 mvp 贴回。
            // regionFit(非 pulse 的区域性 composelayer,如音频条):把场景裁到该层 region → 特效在 region [0,1] 跑
            // (32 条等正好铺满该层,而非整画布切片);下方 aux(全画布遮罩如影子)用同一 region 裁 → 对齐。
            // pulse(打雷,regionFit=false)走原全屏路径不变。
            var regionRect: (x: Int, y: Int, w: Int, h: Int)? = nil
            if layers[i].frameBufferInput {
                let scene = sceneInput ?? compositeSceneBelow(upTo: i, commandBuffer: cmd) ?? current
                if layers[i].regionFit, let r = regionPixelRect(layers[i]),
                   let cropped = cropToRegion(scene, rect: r, key: "scene", commandBuffer: cmd) {
                    current = cropped
                    regionRect = r
                } else {
                    current = scene
                }
            }
            let auxes = layers[i].effectAux
            let auxFlags = layers[i].effectAuxFlags
            // 整帧底图特效(frame_builder 的 _rt_FullFrameBuffer):若本层有此类特效,先把该层之下
            // 已合成场景画进 sceneBelowForEffects,供 g_Texture3=backgroundTexture 采样(否则退白→冲白)。
            sceneBelowForEffects = nil
            if layers[i].effects.contains(where: { we.needsFrameBuffer($0.weName) && !Self.weDenied.contains($0.weName) }) {
                sceneBelowForEffects = compositeSceneBelow(upTo: i, commandBuffer: cmd)
            }
            // g_Texture0 的 flags:仅**第一个**跑的特效拿图层贴图的真实 flags;之后 current 是上一特效
            // 渲出的全屏 FBO(UV∈[0,1]),保持 nil(clamp+linear)。
            var primaryFlags: TexFlags? = layers[i].texFlags
            for (ei, eff) in layers[i].effects.enumerated() {
                // 跳过未被转译覆盖 / denylist 的特效(如 cursorripple 走 CursorRippleSim)。
                // 音频条层:Simple_Audio_Bars(据 currentAudio16 画条)+ perspective(透视)都在此跑。
                guard we.has(eff.weName), !Self.weDenied.contains(eff.weName) else { continue }
                if Self.fxSkip.contains(eff.weName) { continue }   // 诊断:WP_SKIP_FX 跳过
                // 逐特效辅助贴图:weAux 的 slot → g_Texture<slot>(WE pass.textures[N] → 采样器 g_TextureN)。
                // 这统一了 opacitymask/法线/相位/流向等所有辅助槽,取代旧的单一 maskTexture 机制。
                var auxTextures: [String: MTLTexture] = [:]
                if ei < auxes.count {
                    for (slot, tex) in auxes[ei] {
                        var t = tex
                        // regionFit:全画布尺寸的 aux(如 opacity 的影子遮罩 4096×2296)用与场景同一 region 裁,
                        // 使其在 region [0,1] 与裁后场景对齐(影子=身体剪影,裁出 region 内那块身体形状)。
                        if let r = regionRect, tex.width == Int(canvas.x), tex.height == Int(canvas.y),
                           let cropped = cropToRegion(tex, rect: r, key: "aux\(slot)", commandBuffer: cmd) {
                            t = cropped
                        }
                        auxTextures["g_Texture\(slot)"] = t
                    }
                }
                // 真实 flags → 采样器:g_Texture0 = 图层贴图(仅首个特效跑时);辅助槽 = 各自 .tex 的 flags。
                // (遮罩在图层路径走 auxTextures 同一通道,故其 flags 已包含在 auxFlags 里;无独立 maskTexture。)
                var flagsMap: [String: TexFlags] = [:]
                if let pf = primaryFlags { flagsMap["g_Texture0"] = pf }
                if ei < auxFlags.count { for (slot, f) in auxFlags[ei] { flagsMap["g_Texture\(slot)"] = f } }
                // 需要整帧底图的特效(frame_builder 的 g_Texture3=_rt_FullFrameBuffer):喂「该层之下
                // 已合成场景」底图。暂用 sceneBelowTex(下方),空则退该层输入(仍非白,不会冲白)。
                let fb: MTLTexture? = we.needsFrameBuffer(eff.weName) ? (sceneBelowForEffects ?? layers[i].texture) : nil
                let runOut = we.run(effect: eff.weName, input: current,
                                    pkgParams: eff.weParams as [String: Any],
                                    combos: eff.weCombos as [String: Any],
                                    auxTextures: auxTextures,
                                    texFlags: flagsMap,
                                    paramsPerPass: eff.weParamsPerPass.map { $0 as [String: Any] },
                                    time: currentTime, cursor: cursorUV,
                                    audio16: currentAudio16, frameBuffer: fb, commandBuffer: cmd)
                if let out = runOut {
                    current = out
                    primaryFlags = nil   // 后续特效的输入是上一特效的全屏输出 → clamp+linear
                }
            }
            layers[i].effectedTexture = (current !== layers[i].texture) ? current : nil
    }

    /// 把整帧(图层 + 非折射粒子 → [折射粒子] → [后处理])渲染进 finalTarget。
    /// 实时与离屏共用,保证两条路一致。
    private func encodeFrame(commandBuffer cmd: MTLCommandBuffer, finalTarget: MTLTexture) {
        if let sim = rippleSim {
            let dt = lastUpdateTime > 0 ? Float(min(0.05, max(0, currentTime - Float(lastSimTime)))) : 1.0/60
            lastSimTime = Double(currentTime)
            sim.step(commandBuffer: cmd, frametime: dt)
        }
        let w = finalTarget.width, h = finalTarget.height
        // 后处理路线:① postChain 非空 → 真 WE 特效链(整帧先合成到全分辨率 postScene,跑链,blit 回);
        //            ② 否则 postProcess(旧手写假 bloom)启用 → 走它的离屏 sceneTex 路径;③ 都无 → 直出。
        let postChainOn = !postChain.isEmpty && weEffects != nil
        let postOn = !postChainOn && postProcess?.enabled == true
        // 画布宽高比 vs 目标(屏幕)宽高比 → cover 适配:等比放大铺满,裁掉溢出的一边,不拉伸。
        // 宽高比一致(如 16:9 画布在 16:9 屏)时为单位,完全不影响。
        if canvas.x > 0, canvas.y > 0, w > 0, h > 0 {
            let k = (canvas.x / canvas.y) / (Float(w) / Float(h))
            ndcScale = k >= 1 ? SIMD2(k, 1) : SIMD2(1, 1 / k)
        } else { ndcScale = SIMD2(1, 1) }

        let postActive = postChainOn || postOn
        // A(WP_LWE_COMPOSITE,默认关):场景渲进可采样的持久 lweSceneFBO(composelayer 采样累积态作特效输入)。
        // postOn(旧手写 bloom 读自有 sceneTarget)不重定向、保持原路;其余(无后处理 / postChain)走 lweSceneFBO。
        // 整帧的最终合成目标:开 postChain/postProcess 时先渲到全分辨率离屏,再后处理输出到 finalTarget。
        let compositeTarget: MTLTexture =
            (useLweComposite && !postOn) ? (lweSceneTarget(width: w, height: h) ?? finalTarget)
          : postChainOn ? (postSceneTarget(width: w, height: h) ?? finalTarget)
          : postOn ? (postProcess?.sceneTarget(width: w, height: h) ?? finalTarget)
          : finalTarget

        // 照 WE 图层序:排在后处理(fullscreenlayer:bloom/...)之上的粒子(此雨屋的雨丝/水花)
        // 不参与 bloom —— 它们在后处理之后叠加。只有当后处理实际启用时才分批;否则全部正常画。
        // 审计修复#4:恢复真实分批条件(去掉永久关闭的 `false &&`)。原"两条黑线"伪影是 #1(多 pass
        // 直写 framebufferOnly drawable 泄漏平铺显存)/#2(粒子缓冲跨帧覆写无在途限流)/#3(.dontCare 无
        // 全屏覆盖兜底)的表象,本次已一并修:实时路径渲到中间 presentTex 再单次 clear+blit、3 套缓冲+
        // semaphore(3) 限流、.dontCare 仅在确有 blit 覆盖时用。若伪影仍复现 → 把本行改回 `false && …` 并查实时路径。
        let splitBloom = postActive && particleGroups.contains { $0.aboveBloom }
        // 场景 pass 要画的非折射粒子过滤:分批时只画 belowBloom,否则全部。
        let scenePartFilter: ((ParticleGroupInfo) -> Bool)? = splitBloom ? { !$0.aboveBloom } : nil
        // 场景 pass 是否需要折射子 pass(belowBloom 折射;不分批时含全部折射)。
        let scenePassRefract = splitBloom ? hasBelowBloomRefract : hasRefractParticles

        // A 交错路径只接管「无折射」场景 pass(折射两 pass 结构复杂,保持原路)。lweInterleave 为真时:
        // runLayerEffects 跳过 frameBufferInput composelayer(其特效改由 encodeLweScene 读累积 sceneFBO 算);
        // 否则(默认 / 折射 / postProcess 路径)runLayerEffects 用 compositeSceneBelow 兜底,行为同旧路径。
        let lweInterleave = useLweComposite && !postOn && !scenePassRefract
        runLayerEffects(commandBuffer: cmd, skipFrameBufferInput: lweInterleave)   // 真 WE 特效链(产出 effectedTexture)

        if scenePassRefract, let sceneA = refractSceneTarget(width: w, height: h) {
            // Pass 1:图层 + (belowBloom)非折射粒子 → 离屏 sceneA。
            let p1 = MTLRenderPassDescriptor()
            p1.colorAttachments[0].texture = sceneA
            p1.colorAttachments[0].loadAction = .clear
            p1.colorAttachments[0].storeAction = .store
            p1.colorAttachments[0].clearColor = clearColor
            if let e1 = cmd.makeRenderCommandEncoder(descriptor: p1) {
                e1.label = "scene"; encode(into: e1, particleFilter: scenePartFilter); e1.endEncoding()
            }
            // Pass 2:全屏拷 sceneA + 叠(belowBloom)折射粒子(采样 sceneA)→ compositeTarget。
            let p2 = MTLRenderPassDescriptor()
            p2.colorAttachments[0].texture = compositeTarget
            // 审计修复#3:.dontCare 仅在确有全屏 blit 覆盖时安全;pipelineBlit==nil 时全屏拷不执行 →
            // 目标会留未定义平铺显存。无 blit 时改 .clear(黑)兜底,保证目标被定义。
            p2.colorAttachments[0].loadAction = pipelineBlit != nil ? .dontCare : .clear
            p2.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            p2.colorAttachments[0].storeAction = .store
            if let e2 = cmd.makeRenderCommandEncoder(descriptor: p2) {
                e2.label = "refract"
                if let blit = pipelineBlit {
                    e2.setRenderPipelineState(blit)
                    e2.setFragmentSamplerState(sampler, index: 0)
                    e2.setFragmentTexture(sceneA, index: 0)
                    e2.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                }
                encodeRefract(into: e2, sceneFB: sceneA, aboveBloom: splitBloom ? false : nil)
                e2.endEncoding()
            }
            for l in layers { l.video?.attachRetention(to: cmd) }
        } else if lweInterleave {
            // A 交错路径(无折射、无 postProcess):逐段把图层按 z 序累积进 compositeTarget(=持久 lweSceneFBO),
            // 每个 frameBufferInput composelayer 读累积到该层之下的真场景 FBO 作特效输入(对齐 lwe 读
            // _rt_FullFrameBuffer),再画该层;(belowBloom)非折射粒子留到末段统一画(覆盖全部图层之上)。
            encodeLweScene(commandBuffer: cmd, target: compositeTarget, particleFilter: scenePartFilter)
            for l in layers { l.video?.attachRetention(to: cmd) }
        } else {
            // 无(场景 pass)折射:单 pass 渲图层 + (belowBloom)非折射粒子 → 合成目标。
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = compositeTarget
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = clearColor
            if let enc = cmd.makeRenderCommandEncoder(descriptor: pass) {
                enc.label = "scene"; encode(into: enc, particleFilter: scenePartFilter); enc.endEncoding()
            }
            for l in layers { l.video?.attachRetention(to: cmd) }
        }

        // 后处理:bloom/filmgrain/localcontrast 等。分批时输出到中间纹理 postedScene(供其上粒子叠加),
        // 否则直接到 finalTarget。
        let postOut: MTLTexture = splitBloom ? (postedSceneTarget(width: w, height: h) ?? finalTarget) : finalTarget
        if postChainOn {
            runPostChain(commandBuffer: cmd, scene: compositeTarget, finalTarget: postOut)
        } else if postOn {
            postProcess?.run(commandBuffer: cmd, output: postOut)
        }

        // 照 WE:在后处理之后叠加 aboveBloom 粒子(雨丝=非折射,水花=折射,采样已后处理画面 postOut)。
        if splitBloom {
            let pf = MTLRenderPassDescriptor()
            pf.colorAttachments[0].texture = finalTarget
            // 审计修复#3:仅当确有全屏 blit 覆盖(postOut≠finalTarget 且 pipelineBlit 存在),或 postOut 本就
            // 是 finalTarget(已含已存内容)时,.dontCare 才安全。当需要 blit 却无 pipelineBlit → 改 .clear 兜底。
            let willBlitCover = (postOut !== finalTarget) && (pipelineBlit != nil)
            let alreadyDefined = (postOut === finalTarget)
            pf.colorAttachments[0].loadAction = (willBlitCover || alreadyDefined) ? .dontCare : .clear
            pf.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            pf.colorAttachments[0].storeAction = .store
            if let ef = cmd.makeRenderCommandEncoder(descriptor: pf) {
                ef.label = "aboveBloom"
                // 先把已后处理画面铺到 finalTarget(若 postOut 与 finalTarget 不同)。
                if postOut !== finalTarget, let blit = pipelineBlit {
                    ef.setRenderPipelineState(blit)
                    ef.setFragmentSamplerState(sampler, index: 0)
                    ef.setFragmentTexture(postOut, index: 0)
                    ef.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                }
                // aboveBloom 非折射粒子(雨丝):不画图层、只画 aboveBloom 组。
                encode(into: ef, drawLayers: false, particleFilter: { $0.aboveBloom })
                // aboveBloom 折射粒子(水花):采样已后处理画面。
                if hasAboveBloomRefract { encodeRefract(into: ef, sceneFB: postOut, aboveBloom: true) }
                ef.endEncoding()
            }
        }
        // A(WP_LWE_COMPOSITE)无后处理路径:场景渲在 lweSceneFBO,需 blit 到 finalTarget
        // (postChain/postProcess 路径已自带输出到 finalTarget;splitBloom 由上面 aboveBloom pass 输出)。
        if useLweComposite && !postActive && !splitBloom, compositeTarget !== finalTarget, let blit = pipelineBlit {
            let bp = MTLRenderPassDescriptor()
            bp.colorAttachments[0].texture = finalTarget
            bp.colorAttachments[0].loadAction = .dontCare
            bp.colorAttachments[0].storeAction = .store
            if let be = cmd.makeRenderCommandEncoder(descriptor: bp) {
                be.setRenderPipelineState(blit); be.setFragmentSamplerState(sampler, index: 0)
                be.setFragmentTexture(compositeTarget, index: 0)
                be.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                be.endEncoding()
            }
        }
    }

    /// A(WP_LWE_COMPOSITE):忠实对齐 lwe —— 图层按 z 序累积进持久场景 FBO(target = _rt_FullFrameBuffer),
    /// 每个 frameBufferInput composelayer 读「累积到它之下的真场景」作特效输入(取代 compositeSceneBelow 临场重渲),
    /// 跑特效链产出 effectedTexture,再画该层。非折射、非 postProcess 路径专用;(belowBloom)粒子在末段统一画。
    private func encodeLweScene(commandBuffer cmd: MTLCommandBuffer, target sceneFBO: MTLTexture,
                               particleFilter: ((ParticleGroupInfo) -> Bool)?) {
        var cleared = false
        // 把图层区间 [range) 画进 sceneFBO(首次 .clear 建基底,之后 .load 续累积);末段附带画粒子。
        func segment(_ range: Range<Int>, withParticles: Bool) {
            if range.isEmpty && !withParticles && cleared { return }   // 无内容可画(基底已建)→ 跳过空段
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = sceneFBO
            pass.colorAttachments[0].loadAction = cleared ? .load : .clear
            pass.colorAttachments[0].clearColor = clearColor
            pass.colorAttachments[0].storeAction = .store
            cleared = true
            if let enc = cmd.makeRenderCommandEncoder(descriptor: pass) {
                enc.label = "lwe-seg"
                encode(into: enc, particleFilter: withParticles ? particleFilter : nil,
                       layerRange: range, drawParticles: withParticles)
                enc.endEncoding()
            }
        }
        segment(0..<0, withParticles: false)   // 初始清屏:首个 composelayer 即便在最底也读到已清屏基底
        var cursor = 0
        for i in layers.indices where layers[i].frameBufferInput {
            segment(cursor..<i, withParticles: false)                       // 累积 [cursor, i) 进 sceneFBO
            computeLayerEffect(i, sceneInput: sceneFBO, commandBuffer: cmd) // 该层读真累积场景跑特效链
            cursor = i                                                      // 该层自身留到下段画(effectedTexture 已就绪)
        }
        segment(cursor..<layers.count, withParticles: true)   // 余下图层 + (belowBloom)非折射粒子
    }

    /// 跑该壁纸 fullscreenlayer 的真 WE 后处理链:整帧 scene 依次过 bloom/filmgrain/localcontrast 等
    /// 转译特效(每个 effect 一条多 pass 链,输出接下一个输入),末帧 blit 到 finalTarget(drawable)。
    private func runPostChain(commandBuffer cmd: MTLCommandBuffer, scene: MTLTexture, finalTarget: MTLTexture) {
        guard let we = weEffects else { return }
        var current = scene
        for eff in postChain {
            if let out = we.run(effect: eff.weName, input: current,
                                pkgParams: eff.weParams as [String: Any],
                                combos: eff.weCombos as [String: Any],
                                paramsPerPass: eff.weParamsPerPass.map { $0 as [String: Any] },
                                time: currentTime, cursor: cursorUV,
                                audio16: currentAudio16, commandBuffer: cmd) {
                current = out
            }
        }
        // 把后处理结果拷到 finalTarget(渲染方式,兼容 framebufferOnly 的 drawable)。
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = finalTarget
        // 审计修复#3:.dontCare 仅在确有全屏 blit 覆盖时安全;pipelineBlit==nil 时不拷 → finalTarget 留未定义
        // 平铺显存。无 blit 时改 .clear(黑)兜底,仍创建并结束该 pass 以保证 finalTarget 被定义。
        pass.colorAttachments[0].loadAction = pipelineBlit != nil ? .dontCare : .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        if let enc = cmd.makeRenderCommandEncoder(descriptor: pass) {
            enc.label = "postchain-blit"
            if let blit = pipelineBlit {
                enc.setRenderPipelineState(blit)
                enc.setFragmentSamplerState(sampler, index: 0)
                enc.setFragmentTexture(current, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            }
            enc.endEncoding()
        }
    }

    private var liveFrameCount = 0
    // 在途帧限流 + 粒子缓冲轮换环。**关键:ring(4) 必须 > 在途帧数(3)**,否则 CPU 在 update() 里(semaphore.wait
    // 之前)改写 buffers[N%ring] 时,GPU 可能仍在读第 N-ring 帧的同一块 shared 缓冲(semaphore 允许 N-1/N-2/N-3
    // 三帧在飞)→ ParticleInstance(center/size/color)数据撕裂 → 粒子画到错位置/错颜色 = 实时桌面**彩色斑点**
    //(离屏 waitUntilCompleted 无竞态,故只实时出现)。ring=4 > inflight=3:N%4 上次用是 N-4 帧,必已完成,安全。
    // 诊断:WP_HIDE_IDS=482,216 按 pkg 对象 id 隐藏图层(定位是谁遮挡了某元素)。空=不隐藏。
    static let hideLayerIds: Set<Int> = {
        guard let s = ProcessInfo.processInfo.environment["WP_HIDE_IDS"] else { return [] }
        return Set(s.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) })
    }()
    static let kBufferRing = 4
    private static let kInflightFrames = 3
    private let inflightSemaphore = DispatchSemaphore(value: SceneRenderEngine.kInflightFrames)
    private var frameIndex: Int = 0
    private lazy var captureEnabled: Bool = FileManager.default.fileExists(atPath: "/tmp/wp_capture")
    private var presentTex: MTLTexture?
    private var drawStaging: MTLTexture?

    /// 实时呈现纹理(与离屏 renderToPNG 同款可读纹理;也作 MetalFX 升采样输出 → 需 shaderWrite)。
    private func ensurePresentTex(_ w: Int, _ h: Int) -> MTLTexture? {
        if let t = presentTex, t.width == w, t.height == h { return t }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead, .shaderWrite]   // shaderWrite:MetalFX scaler 输出
        d.storageMode = captureEnabled ? .shared : .private   // 捕获时需 CPU 可读
        presentTex = device.makeTexture(descriptor: d)
        return presentTex
    }

    /// render-scale 的低分辨率编码目标(场景先渲到它,再双线性/MetalFX 升采样到全分辨率)。
    private func ensureRenderScaleTex(_ w: Int, _ h: Int) -> MTLTexture? {
        if let t = renderScaleTex, t.width == w, t.height == h { return t }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        renderScaleTex = device.makeTexture(descriptor: d)
        return renderScaleTex
    }

    /// puppet 层的 size×size 离屏 FBO(.renderTarget+.shaderRead)。
    private func makePuppetFBO(width: Int, height: Int) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                         width: max(1, width), height: max(1, height), mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]; d.storageMode = .private
        return device.makeTexture(descriptor: d)
    }

    /// 一次性把 puppet mesh 渲进该层 FBO:局部 ortho(0,size)、顶点已是 [0,size] 像素、UV 直取、采样图层源贴图。
    /// 复用 scene_vertex/scene_fragment(translucent)。局部 ortho 会裁掉 mesh 出界(偏心)的顶点 —— 正解关键。
    /// 静止 bind pose,只需渲一次(不实现骨骼动画)。
    private func renderPuppetIntoFBO(target: MTLTexture, vb: MTLBuffer, ib: MTLBuffer,
                                     indexCount: Int, sourceTex: MTLTexture,
                                     size: SIMD2<Float>, srcFlags: TexFlags?) {
        guard let cmd = queue.makeCommandBuffer() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)  // lwe 清透明
        pass.colorAttachments[0].storeAction = .store
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.setRenderPipelineState(pipelineTranslucent)
        enc.setVertexBuffer(vb, offset: 0, index: 0)
        // ⚠ Y 翻转 ortho:lwe 的 puppet 顶点公式(posY=size/2−rawY)假设 OpenGL FBO 朝向(v 向上、左下原点),
        // 但 Metal 渲染目标纹理是 v 向下、左上原点 → 直接套用会使 FBO 内容垂直翻转(角色身体倒置)。
        // 故 FBO 渲染用 y 向下的 ortho(py=0→NDC+1 顶、py=size→NDC−1 底),抵消 Metal/OpenGL 的 V 朝向差,
        // 让 FBO 当普通贴图被场景 quad(v=0=顶)采样时正立。非 puppet 层用普通贴图不受影响。
        let orthoYDown = simd_float4x4(columns: (
            SIMD4<Float>(2 / size.x, 0, 0, 0),
            SIMD4<Float>(0, -2 / size.y, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(-1, 1, 0, 1)
        ))
        var u = VertexUniforms(mvp: orthoYDown, color: SIMD4<Float>(1, 1, 1, 1))
        enc.setVertexBytes(&u, length: MemoryLayout<VertexUniforms>.stride, index: 1)
        var ndc1 = SIMD2<Float>(1, 1)
        enc.setVertexBytes(&ndc1, length: MemoryLayout<SIMD2<Float>>.stride, index: 3)
        enc.setFragmentSamplerState(samplerFor(srcFlags), index: 0)
        enc.setFragmentTexture(sourceTex, index: 0)
        var fx = makeEffectUniforms(hasMask: false, cursorRipple: false)
        enc.setFragmentBytes(&fx, length: MemoryLayout<EffectUniforms>.stride, index: 0)
        enc.setFragmentTexture(sourceTex, index: 1)   // 槽1/2 占位(不采)
        enc.setFragmentTexture(sourceTex, index: 2)
        enc.drawIndexedPrimitives(type: .triangle, indexCount: indexCount,
                                  indexType: .uint16, indexBuffer: ib, indexBufferOffset: 0)
        enc.endEncoding()
        cmd.commit()
    }

    /// MetalFX 空间放大器(输入 inW×inH → 输出 outW×outH)。尺寸变化时重建,否则复用。
    private func ensureScaler(inW: Int, inH: Int, outW: Int, outH: Int) -> (any MTLFXSpatialScaler)? {
        let key = "\(inW)x\(inH)>\(outW)x\(outH)"
        if key == mfxKey, let s = mfxScaler { return s }
        guard MTLFXSpatialScalerDescriptor.supportsDevice(device) else { return nil }
        let desc = MTLFXSpatialScalerDescriptor()
        desc.inputWidth = inW; desc.inputHeight = inH
        desc.outputWidth = outW; desc.outputHeight = outH
        desc.colorTextureFormat = .bgra8Unorm
        desc.outputTextureFormat = .bgra8Unorm
        desc.colorProcessingMode = .perceptual
        let s = desc.makeSpatialScaler(device: device)
        mfxScaler = s; mfxKey = key
        return s
    }

    /// 抓真实 drawable 用的 CPU 可读暂存纹理。
    private func ensureDrawStaging(_ w: Int, _ h: Int) -> MTLTexture? {
        if let t = drawStaging, t.width == w, t.height == h { return t }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        d.usage = [.shaderRead]; d.storageMode = .shared
        drawStaging = device.makeTexture(descriptor: d)
        return drawStaging
    }

    /// 渲染一帧到 drawable(桌面实时)。
    /// **关键**:绝不让 encodeFrame 的多 pass(含 .dontCare 加载/折射采样/混合读目标)直接写
    /// `framebufferOnly` 的 drawable —— 平铺 GPU 上其未定义/平铺显存会在桌面合成时泄漏成彩色噪点/
    /// 黑线(只在实时出现,离屏 .shared 纹理正常,已实测确认)。改为:先渲到可读中间纹理(= 已验证
    /// 干净的离屏路径),再用**单次 clear+全屏 blit** 呈现到 drawable(整张被清空+100% 覆盖,无残留)。
    func render(to drawable: CAMetalDrawable, viewportSize: CGSize) {
        guard let cmd = queue.makeCommandBuffer() else { return }
        let w = drawable.texture.width, h = drawable.texture.height
        // 画质/性能设置:render-scale 把场景渲到低分辨率,再双线性或 MetalFX 升采样到全分辨率。
        let prefs = PreferencesStore.shared
        // MetalFX 与渲染分辨率独立(同截图):滑块定输入分辨率,MetalFX 决定升采样算法(优于双线性)。
        // renderScale=100% 时不降分辨率 → MetalFX 空转跳过(全分辨率直出)。
        let useMFX = prefs.metalFXEnabled
        let scale = prefs.renderScale
        let downscaled = scale < 0.999
        let lowW = max(2, Int((Double(w) * scale).rounded())), lowH = max(2, Int((Double(h) * scale).rounded()))
        // 编码目标:降分辨率时渲到低分纹理,否则直接渲到全分呈现纹理。
        let encodeTex = downscaled ? ensureRenderScaleTex(lowW, lowH) : ensurePresentTex(w, h)
        guard let encodeTex else {
            // 审计修复#1:分配失败绝不把 encodeFrame 多 pass 直写 framebufferOnly drawable(顶部注释明令禁止,
            // 会泄漏平铺显存成黑线/噪点)。改为只 clear 该 drawable(整张定义为黑)并 present,跳过该帧渲染。
            let clearPass = MTLRenderPassDescriptor()
            clearPass.colorAttachments[0].texture = drawable.texture
            clearPass.colorAttachments[0].loadAction = .clear
            clearPass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            clearPass.colorAttachments[0].storeAction = .store
            cmd.makeRenderCommandEncoder(descriptor: clearPass)?.endEncoding()
            cmd.present(drawable); cmd.commit(); return
        }
        // 审计修复#2:限制在途帧到 3(三重缓冲),编码前 wait、完成时 signal。静态场景(只画一帧)也不死锁:
        // value=3 留足余量,且每帧都成对 wait/signal。
        inflightSemaphore.wait()
        cmd.addCompletedHandler { [inflightSemaphore] _ in inflightSemaphore.signal() }
        encodeFrame(commandBuffer: cmd, finalTarget: encodeTex)
        // 升采样:MetalFX(画质优)→ presentTex;否则呈现 pass 的采样器直接双线性放大 encodeTex。
        var srcTex = encodeTex
        if downscaled, useMFX, let scaler = ensureScaler(inW: lowW, inH: lowH, outW: w, outH: h),
           let presentT = ensurePresentTex(w, h) {
            scaler.colorTexture = encodeTex
            scaler.outputTexture = presentT
            scaler.encode(commandBuffer: cmd)
            srcTex = presentT
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        // 呈现:FXAA(画质设置开)或普通拷贝;采样器对 srcTex<drawable 自动双线性升采样。
        let fxaa = prefs.fxaaEnabled ? pipelineBlitFXAA : nil
        if let enc = cmd.makeRenderCommandEncoder(descriptor: pass) {
            if let fx = fxaa {
                enc.setRenderPipelineState(fx)
                var rcp = SIMD2<Float>(1.0 / Float(srcTex.width), 1.0 / Float(srcTex.height))
                enc.setFragmentBytes(&rcp, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
            } else if let blit = pipelineBlit {
                enc.setRenderPipelineState(blit)
            }
            enc.setFragmentSamplerState(sampler, index: 0)
            enc.setFragmentTexture(srcTex, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3); enc.endEncoding()
        }
        let tex = srcTex   // 下方抓帧/保存沿用最终呈现源
        let save = captureEnabled && (liveFrameCount % 120 == 0) && liveFrameCount <= 720
        let n = liveFrameCount; if captureEnabled { liveFrameCount += 1 }
        // 抓**真实 drawable**(present 前):blit drawable → staging,看屏幕实际拿到的内容。
        if save, let stg = ensureDrawStaging(w, h), let be = cmd.makeBlitCommandEncoder() {
            be.copy(from: drawable.texture, sourceSlice: 0, sourceLevel: 0,
                    sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0), sourceSize: MTLSize(width: w, height: h, depth: 1),
                    to: stg, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            be.endEncoding()
        }
        cmd.present(drawable)
        cmd.commit()
        if save {
            cmd.waitUntilCompleted()
            saveTexture(tex, to: "/tmp/live_\(n).png")
            if let stg = drawStaging { saveTexture(stg, to: "/tmp/draw_\(n).png") }
        }
    }

    private func saveTexture(_ tex: MTLTexture, to path: String) {
        let width = tex.width, height = tex.height, rowBytes = width * 4
        var raw = [UInt8](repeating: 0, count: rowBytes * height)
        tex.getBytes(&raw, bytesPerRow: rowBytes, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let ctx = CGContext(data: &raw, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: rowBytes, space: cs, bitmapInfo: info.rawValue),
              let cg = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, cg, nil); _ = CGImageDestinationFinalize(dest)
    }

    /// 离屏渲染到 PNG(用于无界面验证)。走与实时完全相同的 encodeFrame。
    func renderToPNG(width: Int, height: Int, outURL: URL) -> Bool {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                            width: width, height: height, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .shared
        guard let target = device.makeTexture(descriptor: desc) else { return false }
        guard let cmd = queue.makeCommandBuffer() else { return false }
        // 审计修复#2:此离屏单帧路径不调 update()(故 frameIndex 不前进),且 waitUntilCompleted 保证 GPU
        // 读完才返回,缓冲轮换无并发风险;直接用当前 ring 写读即可。
        encodeFrame(commandBuffer: cmd, finalTarget: target)
        cmd.commit()
        cmd.waitUntilCompleted()

        // 读回 BGRA8 → CGImage → PNG
        let rowBytes = width * 4
        var raw = [UInt8](repeating: 0, count: rowBytes * height)
        target.getBytes(&raw, bytesPerRow: rowBytes, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)

        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let ctx = CGContext(data: &raw, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: rowBytes, space: cs, bitmapInfo: info.rawValue),
              let cg = ctx.makeImage() else { return false }
        guard let dest = CGImageDestinationCreateWithURL(outURL as CFURL, "public.png" as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(dest, cg, nil)
        return CGImageDestinationFinalize(dest)
    }

    /// 多帧渲染到**同一复用 target**(模拟实时:复用 drawable + 复用纹理池跨帧累积),只回读最后一帧。
    /// 用于复现"实时才出现、单帧离屏正常"的 GPU 残留/累积类 bug(彩色噪点/黑线/糊)。
    func renderFramesToPNG(width: Int, height: Int, frames: Int, dt: Double, outURL: URL) -> Bool {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                            width: width, height: height, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .shared
        guard let target = device.makeTexture(descriptor: desc) else { return false }
        var warmRopePeakN: [Int: Int] = [:]
        var warmRopePeakV: [Int: Int] = [:]
        // WP_CURSOR_ORBIT(仅验证用):让光标绕画布中心做圆周运动,驱动「鼠标拖尾」rope 喷射(否则静止光标永不发射)。
        // 正常运行(桌面/--render)不设此变量 → 行为零变化。
        let orbit = ProcessInfo.processInfo.environment["WP_CURSOR_ORBIT"] != nil
        for i in 0..<max(1, frames) {
            let m: SIMD2<Float>
            if orbit {
                let a = Float(i) * 0.12
                m = SIMD2(cos(a) * 0.5, sin(a) * 0.5)   // [-0.5,0.5] 归一化绕中心
            } else { m = SIMD2<Float>(0, 0) }
            update(time: Double(i) * dt, mouseNorm: m)   // 审计修复#2:update 已推进 frameIndex 轮换缓冲
            guard let cmd = queue.makeCommandBuffer() else { return false }
            encodeFrame(commandBuffer: cmd, finalTarget: target)
            cmd.commit(); cmd.waitUntilCompleted()
            if orbit {
                for (gi, g) in particleGroups.enumerated() where g.isRope {
                    let n = g.sim.liveCount, v = g.ropeVertexCount
                    if n > warmRopePeakN[gi, default: 0] { warmRopePeakN[gi] = n }
                    if v > warmRopePeakV[gi, default: 0] { warmRopePeakV[gi] = v }
                    if i == frames - 1 {
                        Log.write(String(format: "WARMROPE g%d: nNow=%d vNow=%d peakN=%d peakV=%d cursor=%@ trail=%@",
                                         gi, n, v, warmRopePeakN[gi, default: 0], warmRopePeakV[gi, default: 0],
                                         g.sim.desc.followsCursor ? "Y" : "n", g.sim.desc.isRopeTrail ? "Y" : "n"))
                    }
                }
            }
        }
        let rowBytes = width * 4
        var raw = [UInt8](repeating: 0, count: rowBytes * height)
        target.getBytes(&raw, bytesPerRow: rowBytes, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let ctx = CGContext(data: &raw, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: rowBytes, space: cs, bitmapInfo: info.rawValue),
              let cg = ctx.makeImage() else { return false }
        guard let dest = CGImageDestinationCreateWithURL(outURL as CFURL, "public.png" as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(dest, cg, nil)
        return CGImageDestinationFinalize(dest)
    }

    var layerCount: Int { layers.count }

    // MARK: - Shader

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VIn  { float2 pos [[attribute(0)]]; float2 uv [[attribute(1)]]; };
    struct VOut { float4 position [[position]]; float2 uv; float4 color; };
    struct Uniforms { float4x4 mvp; float4 color; int4 fb; };

    vertex VOut scene_vertex(uint vid [[vertex_id]],
                             const device float4* verts [[buffer(0)]],
                             constant Uniforms& u [[buffer(1)]],
                             constant float2& ndcScale [[buffer(3)]]) {
        float4 v = verts[vid];            // xy = pos, zw = uv
        VOut o;
        o.position = u.mvp * float4(v.xy, 0.0, 1.0);
        // frameBufferInput(composelayer/_rt_FullFrameBuffer,如打雷):effectedTexture 是**整帧画布空间**底图,
        // 必须按**画布 UV**(ndcScale 之前的 NDC→[0,1])采样,而非 quad 局部 UV——这样区域 quad(打雷的上部
        // 3840×1400)只覆盖其屏幕区域、且 1:1 不压扁/不接缝。canvas UV 取自未乘 ndcScale 的 NDC(与 compositeSceneBelow
        // 的 ndc=(1,1) 画布空间一致)。
        if (u.fb.x != 0) {
            float2 cndc = o.position.xy / o.position.w;
            o.uv = cndc * float2(0.5, -0.5) + 0.5;
        } else {
            o.uv = v.zw;
        }
        o.position.xy *= ndcScale;        // 宽高比 cover 适配
        o.color = u.color;
        return o;
    }

    // ---- 主合成 pass ----
    // 图层特效(shake/waterwaves/foliagesway/waterripple/waterflow/scroll/tint/opacity/pulse 及
    // godrays/iris/shimmer/... 等)全部由**真 WE 转译 shader**(WEEffectChain)跑进 effectedTexture,
    // 这里只做:贴图 + 图层 color/alpha + 鼠标水波折射 combine(cursorripple)。无任何手写近似特效。
    struct EffectU {
        float time; int hasMask; int cursorRipple; float rippleStrength;
    };

    fragment float4 scene_fragment(VOut in [[stage_in]],
                                   texture2d<float> tex [[texture(0)]],
                                   sampler smp [[sampler(0)]],
                                   constant EffectU& fx [[buffer(0)]],
                                   texture2d<float> maskTex [[texture(1)]],
                                   texture2d<float> rippleField [[texture(2)]]) {
        float2 off = 0;
        // 鼠标划过水波折射 combine —— **逐行照搬 WE cursorripple_combine.frag(已对照真 WE 安装源核对)**:
        //   albedo = field; albedo *= albedo; dir = (x-z, y-w); offset = dir * -0.1 * g_RippleStrength
        // -0.1 是 WE 原始折射系数。真 shader 里 opacitymask 采样器(g_Texture2)是**注释掉的**,
        // 不参与折射;rippleMask 只在 #if PERSPECTIVE==1 时用视锥 step 裁剪(本库 cursorripple 无 gizmo
        // point0-3 → 非透视 → 恒 1.0)。**删掉之前臆造的 `* effectMask.r`**:effectMask=图层首个遮罩,
        // 草地/猫层(id16)的首个遮罩是 foliagesway_mask(白=叶簇散点)→ 折射被限到叶簇白点 →
        // 鼠标划过草地时草地起波(根因)。力场的水面门控本就在 simulate 的碰撞遮罩里做(CursorRippleSim)。
        if (fx.cursorRipple != 0) {
            float4 f = rippleField.sample(smp, in.uv);
            f *= f;
            float2 dir = float2(f.x - f.z, f.y - f.w);
            // 审计修复#8(TODO,已跳过):-0.1 是 WE cursorripple_combine.frag 的原始折射系数(真值常量,非臆造)。
            //   若要严格据材质参数化(部分壁纸可能覆写),需把该系数从 material 经 EffectU uniform 传入。
            //   风险与改动面大于收益(-0.1 已是 WE 默认且实测正确),暂保留硬编码。
            off += dir * (-0.1 * fx.rippleStrength);
        }
        float4 c = tex.sample(smp, in.uv + off) * in.color;
        return c;
    }

    // ===== colorBlendMode:逐行移植 common_blending.h 的 ApplyBlending(32 种混合方程)=====
    // WE 在对象级 colorBlendMode>0 时加一 pass(materials/util/effectpassthrough + BLENDMODE 组合),
    // 把图层与背景按方程混合:out.rgb = ApplyBlending(mode, A=背景, B=图层albedo, opacity=图层alpha),
    // out.a = 背景.a(passthroughblend.frag)。Apple TBDR 用 framebuffer fetch([[color(0)]])读背景,
    // 单 pass 内完成,无需离屏 blend pass(只有 colorBlendMode 层走此着色器,不影响其它层)。
    static inline float bcBurn(float b, float s){ return s==0.0 ? 0.0 : max(1.0-(1.0-b)/s, 0.0); }
    static inline float bcDodge(float b, float s){ return s==1.0 ? 1.0 : min(b/(1.0-s), 1.0); }
    static inline float bOver(float b, float s){ return b<0.5 ? (2.0*b*s) : (1.0-2.0*(1.0-b)*(1.0-s)); }
    static inline float bSoft(float b, float s){ return s<0.5 ? (2.0*b*s+b*b*(1.0-2.0*s)) : (sqrt(b)*(2.0*s-1.0)+2.0*b*(1.0-s)); }
    static inline float bVivid(float b, float s){ return s<0.5 ? bcBurn(b,2.0*s) : bcDodge(b,2.0*(s-0.5)); }
    static inline float bPin(float b, float s){ return s<0.5 ? min(b,2.0*s) : max(b,2.0*(s-0.5)); }
    static inline float bLin(float b, float s){ return s<0.5 ? max(b+2.0*s-1.0,0.0) : min(b+2.0*(s-0.5),1.0); }
    static inline float bRefl(float b, float s){ return s==1.0 ? 1.0 : min(b*b/(1.0-s),1.0); }
    #define V3(va,vb,fn) float3(fn((va).r,(vb).r), fn((va).g,(vb).g), fn((va).b,(vb).b))
    static inline float3 rgb2hsl(float3 c){
        float mn=min(min(c.r,c.g),c.b), mx=max(max(c.r,c.g),c.b), d=mx-mn;
        float3 h; h.z=(mx+mn)*0.5;
        if(d==0.0){ h.x=0.0; h.y=0.0; }
        else{
            h.y = h.z<0.5 ? d/(mx+mn) : d/(2.0-mx-mn);
            float dR=(((mx-c.r)/6.0)+(d*0.5))/d, dG=(((mx-c.g)/6.0)+(d*0.5))/d, dB=(((mx-c.b)/6.0)+(d*0.5))/d;
            if(c.r==mx) h.x=dB-dG; else if(c.g==mx) h.x=(1.0/3.0)+dR-dB; else h.x=(2.0/3.0)+dG-dR;
            if(h.x<0.0) h.x+=1.0; else if(h.x>1.0) h.x-=1.0;
        }
        return h;
    }
    static inline float hue2rgb(float f1,float f2,float h){
        if(h<0.0) h+=1.0; else if(h>1.0) h-=1.0;
        if(6.0*h<1.0) return f1+(f2-f1)*6.0*h;
        if(2.0*h<1.0) return f2;
        if(3.0*h<2.0) return f1+(f2-f1)*((2.0/3.0)-h)*6.0;
        return f1;
    }
    static inline float3 hsl2rgb(float3 hsl){
        if(hsl.y==0.0) return float3(hsl.z);
        float f2 = hsl.z<0.5 ? hsl.z*(1.0+hsl.y) : (hsl.z+hsl.y)-(hsl.y*hsl.z);
        float f1 = 2.0*hsl.z-f2;
        return float3(hue2rgb(f1,f2,hsl.x+1.0/3.0), hue2rgb(f1,f2,hsl.x), hue2rgb(f1,f2,hsl.x-1.0/3.0));
    }
    static float3 applyBlending(int mode, float3 A, float3 B, float o){
        switch(mode){
            case 1:  return mix(A, min(A,B), o);                       // Darken
            case 2:  return mix(A, A*B, o);                            // Multiply
            case 3:  return mix(A, V3(A,B,bcBurn), o);                 // ColorBurn
            case 4:  return mix(A, max(A+B-1.0,0.0), o);               // Substract
            case 5:  return min(A,B);
            case 6:  return mix(A, max(A,B), o);                       // Lighten
            case 7:  return mix(A, 1.0-(1.0-A)*(1.0-B), o);            // Screen
            case 8:  return mix(A, V3(A,B,bcDodge), o);                // ColorDodge
            case 9:  return mix(A, min(A+B,1.0), o);                   // Add
            case 10: return max(A,B);
            case 11: return mix(A, V3(A,B,bOver), o);                  // Overlay
            case 12: return mix(A, V3(A,B,bSoft), o);                  // SoftLight
            case 13: return mix(A, V3(B,A,bOver), o);                  // HardLight = Overlay(blend,base)
            case 14: return mix(A, V3(A,B,bVivid), o);                 // VividLight
            case 15: return mix(A, V3(A,B,bLin), o);                   // LinearLight
            case 16: return mix(A, V3(A,B,bPin), o);                   // PinLight
            case 17: return mix(A, float3(bVivid(A.r,B.r)<0.5?0.0:1.0, bVivid(A.g,B.g)<0.5?0.0:1.0, bVivid(A.b,B.b)<0.5?0.0:1.0), o); // HardMix
            case 18: return mix(A, abs(A-B), o);                       // Difference
            case 19: return mix(A, A+B-2.0*A*B, o);                    // Exclusion
            case 20: return mix(A, max(A+B-1.0,0.0), o);               // Substract
            case 21: return mix(A, V3(A,B,bRefl), o);                  // Reflect
            case 22: return mix(A, V3(B,A,bRefl), o);                  // Glow = Reflect(blend,base)
            case 23: return mix(A, min(A,B)-max(A,B)+1.0, o);          // Phoenix
            case 24: return mix(A, (A+B)*0.5, o);                      // Average
            case 25: return mix(A, 1.0-abs(1.0-A-B), o);              // Negation
            case 26: return mix(A, hsl2rgb(float3(rgb2hsl(B).r, rgb2hsl(A).g, rgb2hsl(A).b)), o); // Hue
            case 27: return mix(A, hsl2rgb(float3(rgb2hsl(A).r, rgb2hsl(B).g, rgb2hsl(A).b)), o); // Saturation
            case 28: return mix(A, hsl2rgb(float3(rgb2hsl(B).r, rgb2hsl(B).g, rgb2hsl(A).b)), o); // Color
            case 29: return mix(A, hsl2rgb(float3(rgb2hsl(A).r, rgb2hsl(A).g, rgb2hsl(B).b)), o); // Luminosity
            case 30: return mix(A, float3(max(A.r,max(A.g,A.b)))*B, o); // Tint
            case 31: return A + B*o;                                   // A+B*opacity
            case 32: return mix(A, A+A*B, o);
            default: return mix(A, B, o);                              // Normal
        }
    }

    // colorBlendMode 层专用片元:framebuffer fetch 读背景,按方程混合。混合在着色器内完成 → 管线 blend 关闭。
    fragment float4 scene_fragment_blend(VOut in [[stage_in]],
                                         texture2d<float> tex [[texture(0)]],
                                         sampler smp [[sampler(0)]],
                                         constant int& mode [[buffer(0)]],
                                         float4 bg [[color(0)]]) {
        float4 B = tex.sample(smp, in.uv) * in.color;   // 图层 albedo(含 color×brightness)
        return float4(applyBlending(mode, bg.rgb, B.rgb, B.a), bg.a);
    }

    // ---- 粒子:实例化绘制(支持精灵表子矩形 UV)----
    struct ParticleInst {
        float2 center; float size; float rotation; float4 color;
        float2 uvOffset; float2 uvScale; float aspect;
    };

    vertex VOut particle_vertex(uint vid [[vertex_id]],
                                uint iid [[instance_id]],
                                const device float4* quad [[buffer(0)]],
                                constant float4x4& proj [[buffer(1)]],
                                const device ParticleInst* insts [[buffer(2)]],
                                constant float2& ndcScale [[buffer(3)]]) {
        ParticleInst p = insts[iid];
        float4 v = quad[vid];                 // xy in [-0.5,0.5], zw uv in [0,1]
        // 按帧宽高比修正 quad 的 x,避免非方形帧被拉变形。
        float2  local = float2(v.x * p.size * p.aspect, v.y * p.size);
        float cc = cos(p.rotation), ss = sin(p.rotation);
        float2 rotated = float2(local.x * cc - local.y * ss, local.x * ss + local.y * cc);
        float2 world = p.center + rotated;
        VOut o;
        o.position = proj * float4(world, 0.0, 1.0);
        o.position.xy *= ndcScale;            // 宽高比 cover 适配
        // 把 [0,1] 的 quad UV 映射到精灵表该帧的子矩形。
        o.uv = p.uvOffset + v.zw * p.uvScale;
        o.color = p.color;
        return o;
    }

    // ---- rope 带状网格:顶点位置已在画布像素世界系(CPU 端 ropeVertices() 算好 Catmull-Rom 带),
    // 这里只过 proj×ndcScale,透传 uv/color;片元复用 scene_fragment(tex×color)。----
    struct RopeVtx { float2 pos; float2 uv; float4 color; };
    vertex VOut rope_vertex(uint vid [[vertex_id]],
                            const device RopeVtx* verts [[buffer(2)]],
                            constant float4x4& proj [[buffer(1)]],
                            constant float2& ndcScale [[buffer(3)]]) {
        RopeVtx v = verts[vid];
        VOut o;
        o.position = proj * float4(v.pos, 0.0, 1.0);
        o.position.xy *= ndcScale;
        o.uv = v.uv;
        o.color = v.color;
        return o;
    }

    // ---- 折射粒子(玻璃雨滴):照 WE genericparticle.frag REFRACT 分支 ----
    // color = v_Color * albedo; color.rgb *= 场景底图(屏幕UV + 法线偏移)。
    // 即雨滴显示的是它背后被法线扭曲的场景,而不是一坨白斑。
    struct VOutRefract {
        float4 position [[position]];
        float2 uv;
        float4 color;
        float2 screenUV;        // 该片元在屏幕的归一化坐标(采样场景底图用)
        float4 refractTangent;  // WE v_ScreenTangents 2x2 切基:xy=right投影, zw=up投影(已乘 g_RefractAmount)
    };

    vertex VOutRefract particle_refract_vertex(uint vid [[vertex_id]],
                                               uint iid [[instance_id]],
                                               const device float4* quad [[buffer(0)]],
                                               constant float4x4& proj [[buffer(1)]],
                                               const device ParticleInst* insts [[buffer(2)]],
                                               constant float2& ndcScale [[buffer(3)]],
                                               constant float& g_RefractAmount [[buffer(4)]]) {
        ParticleInst p = insts[iid];
        float4 v = quad[vid];
        float2 local = float2(v.x * p.size * p.aspect, v.y * p.size);
        float cc = cos(p.rotation), ss = sin(p.rotation);
        float2 rotated = float2(local.x * cc - local.y * ss, local.x * ss + local.y * cc);
        float2 world = p.center + rotated;
        VOutRefract o;
        o.position = proj * float4(world, 0.0, 1.0);
        o.position.xy *= ndcScale;            // 宽高比 cover 适配(与 sceneFB 一致)
        o.uv = p.uvOffset + v.zw * p.uvScale;
        o.color = p.color;
        // NDC → 屏幕UV(y 翻转:纹理 v=0 在顶)。用适配后的位置,才能正确采样场景底图。
        // 审计修复#5:此处用**已乘 ndcScale** 的 NDC 是正确的——sceneFB(refractSceneTarget)正是经
        //   encode() 同样乘 ndcScale 渲到目标全分辨率(屏幕空间、cover 裁切),且 Pass2 把它 1:1 blit。
        //   故折射片元在屏幕上的 NDC 直接对应 sceneFB 的采样位置;两侧 ndcScale 一致 → 非 16:9 屏不偏移。
        //   (推导:layer 与折射粒子同世界点 W → 同 clip = proj*W → 同乘 ndcScale → 同屏幕像素。)
        //   若改成 ndc/ndcScale 反而会在非 16:9 屏引入偏移。ndcScale=1 时本式恒等,行为与原先一致。
        float2 ndc = o.position.xy / o.position.w;
        o.screenUV = ndc * float2(0.5, -0.5) + 0.5;
        // WE ComputeScreenRefractionTangents(common_particles.h:88-104):
        // 用「单位化」sprite right/up 投到视图轴得 2x2 切基(数量级~1,与粒子尺寸无关),再 *= g_RefractAmount。
        // 2D 屏对齐场景下 right/up 经 sprite 自旋(p.rotation)即旋转矩阵的列。
        // g_RefractAmount 由 encodeRefract 从材质 ui_editor_properties_refract_amount per-group 喂入(buffer4,
        // 替代旧硬编码 0.05)。实库雨幕 -0.05~-0.44(负=反向折射)、magic_pulse 1;缺省退 WE 默认 0.05。
        float2 spriteRight = float2(cc, ss);   // 单位 right 经自旋
        float2 spriteUp    = float2(-ss, cc);  // 单位 up 经自旋
        o.refractTangent = float4(spriteRight, spriteUp) * g_RefractAmount;
        return o;
    }

    fragment float4 particle_refract_fragment(VOutRefract in [[stage_in]],
                                              texture2d<float> albedoTex [[texture(0)]],
                                              texture2d<float> normalTex [[texture(1)]],
                                              texture2d<float> sceneFB [[texture(2)]],
                                              sampler smp [[sampler(0)]],
                                              constant int& hasNormal [[buffer(0)]]) {
        float4 albedo = albedoTex.sample(smp, in.uv);
        float4 color = in.color * albedo;
        float2 offset = float2(0);
        if (hasNormal != 0) {
            float4 nrm = normalTex.sample(smp, in.uv);
            // WE DecompressNormalWithMask(common_fragment.h:34-49):DXT5/BC 法线先 normal.xw=normal.wx,
            // 取 .wy 作法线 xy、.x(红) 作 mask。splash 法线一般是 DXT5。
            // 法线解包按贴图格式自适配(WE DecompressNormalWithMask,common_fragment.h:34-49):
            //   • DXT5/BC 法线("DXT5nm"):X 存 alpha、Y 存 green、mask(蓝通道未用≈0) → n=(.w,.y)、mask=.x。
            //   • 未压缩 RGBA8888n 法线(如 halo 的 normal_pinch_rotate,.tex-json format=rgba8888n):
            //     X 存 red、Y 存 green、Z 存 blue、mask=alpha → n=(.x,.y)、mask=.a。
            // 之前硬编码 DXT5(.w,.y):对 RGBA8888n 法线读到 .w=alpha=1 → n.x=1(最大)→ 折射偏移爆炸 →
            // 采样到远处场景 → 实时桌面出现彩色光斑(halo 折射粒子,refract_amount=1)。按 blue 通道区分两种格式
            //(DXT5nm 蓝≈0;RGB 法线蓝=Z 分量有值)自适配,无需贯穿格式 flags。
            float2 n; float mask;
            if (nrm.z > 0.25) {                          // 未压缩 RGBA 法线(Z 在蓝通道)
                n = nrm.xy * 2.0 - 1.0; mask = nrm.w;
            } else {                                     // DXT5/BC 法线(X 在 alpha)
                n = float2(nrm.w, nrm.y) * 2.0 - 1.0; mask = nrm.x;
            }
            // WE genericparticle.frag:107: offset = tangent.xy*n.x + tangent.zw*n.y
            offset = in.refractTangent.xy * n.x + in.refractTangent.zw * n.y;
            offset.y = -offset.y;
            offset *= mask * in.color.a;           // 法线 mask × 粒子 alpha(恢复:去掉后雨折射变差)
        }
        float3 bg = sceneFB.sample(smp, in.screenUV + offset).rgb;
        color.rgb *= bg;                           // 关键:乘场景底图 → 雨滴透出背景
        return color;                              // translucent 混合,alpha = color.a*albedo.a
    }

    // ---- 全屏拷贝(无顶点缓冲,用大三角覆盖屏幕)----
    vertex VOut fullscreen_vertex(uint vid [[vertex_id]]) {
        float2 p[3] = { float2(-1,-1), float2(3,-1), float2(-1,3) };
        VOut o;
        o.position = float4(p[vid], 0, 1);
        o.uv = p[vid] * float2(0.5, -0.5) + 0.5;   // NDC→UV(y 翻转)
        o.color = float4(1);
        return o;
    }
    fragment float4 fullscreen_copy(VOut in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]]) {
        return t.sample(s, in.uv);
    }
    // FXAA(快速近似抗锯齿,FXAA3 简化版)。rcp = 1/源纹理尺寸。呈现时按 luma 边缘做一次平滑。
    fragment float4 fullscreen_fxaa(VOut in [[stage_in]], texture2d<float> t [[texture(0)]],
                                    sampler s [[sampler(0)]], constant float2& rcp [[buffer(0)]]) {
        const float3 luma = float3(0.299, 0.587, 0.114);
        float2 uv = in.uv;
        float3 nw = t.sample(s, uv + float2(-1,-1)*rcp).rgb;
        float3 ne = t.sample(s, uv + float2( 1,-1)*rcp).rgb;
        float3 sw = t.sample(s, uv + float2(-1, 1)*rcp).rgb;
        float3 se = t.sample(s, uv + float2( 1, 1)*rcp).rgb;
        float4 mC = t.sample(s, uv);
        float lNW = dot(nw,luma), lNE = dot(ne,luma), lSW = dot(sw,luma), lSE = dot(se,luma), lM = dot(mC.rgb,luma);
        float lMin = min(lM, min(min(lNW,lNE), min(lSW,lSE)));
        float lMax = max(lM, max(max(lNW,lNE), max(lSW,lSE)));
        if (lMax - lMin < lMax * 0.0625 + 0.0078) return mC;   // 对比太低 → 不处理
        float2 dir = float2(-((lNW+lNE)-(lSW+lSE)), ((lNW+lSW)-(lNE+lSE)));
        float reduce = max((lNW+lNE+lSW+lSE)*0.25*0.125, 1.0/128.0);
        float rcpMin = 1.0/(min(abs(dir.x),abs(dir.y))+reduce);
        dir = clamp(dir*rcpMin, -8.0, 8.0) * rcp;
        float3 rgbA = 0.5*(t.sample(s, uv+dir*(1.0/3.0-0.5)).rgb + t.sample(s, uv+dir*(2.0/3.0-0.5)).rgb);
        float3 rgbB = rgbA*0.5 + 0.25*(t.sample(s, uv+dir*-0.5).rgb + t.sample(s, uv+dir*0.5).rgb);
        float lB = dot(rgbB, luma);
        return float4((lB < lMin || lB > lMax) ? rgbA : rgbB, mC.a);
    }
    """
}
