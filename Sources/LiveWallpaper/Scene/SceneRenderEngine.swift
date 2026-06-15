import Metal
import MetalKit
import MetalFX
import simd
import CoreGraphics
import Foundation
import QuartzCore   // CATransaction(presentsWithTransaction 同步呈现的事务包裹)

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

/// 缺口2:透视投影矩阵。移植 lwe 唯一的 perspective 用法 CParticle.cpp:1892
/// `glm::perspective(fov_radians, aspect, nearz, farz)`(场景透视相机 lwe 自身不支持,见 SceneModel
/// CameraDesc.isPerspective;此处按真 WE 语义用 lwe 已备好的 fov/nearz/farz 建)。
/// glm::perspective 是右手系、列主序、深度映射到 [-1,1](OpenGL 风格,与本工程现有 matOrtho 一致:
/// 列主序、CImage 顶点 z=0)。fov 传**弧度**(CParticle.cpp:1891 glm::radians(getFov()))。
private func matPerspective(fovRadians: Float, aspect: Float, nearZ: Float, farZ: Float) -> simd_float4x4 {
    let f = 1 / tan(fovRadians / 2)
    let nf = 1 / (nearZ - farZ)
    // ⚠ Metal 深度约定:裁剪空间 z/w ∈ **[0,1]**(非 OpenGL 的 [-1,1])。用 OpenGL 矩阵会把近半
    //   (z/w∈[-1,0])整段裁掉(土星近半球消失 = 半个行星)。这里用 Metal/D3D 右手系 [0,1] 映射:
    //   near→0, far→1。z' = farZ/(nearZ-farZ)·z + farZ·nearZ/(nearZ-farZ),w' = -z。
    return simd_float4x4(columns: (
        SIMD4(f / aspect, 0, 0,  0),
        SIMD4(0,          f, 0,  0),
        SIMD4(0, 0, farZ * nf, -1),
        SIMD4(0, 0, farZ * nearZ * nf, 0)
    ))
}

/// 缺口2:视图矩阵。移植 lwe Camera.cpp:13 `glm::lookAt(eye, center, up)`(右手系、列主序)。
/// 仅在透视场景使用;正交场景照旧不用 lookAt(见 load() 中等价性证明:ortho 下 (+eye)(−eye) 相消)。
/// 正交投影(右手系,列主序,Metal 深度 [0,1]):阴影相机用。x∈[-halfW,halfW]→[-1,1],
/// y∈[-halfH,halfH]→[-1,1],z(视空间,看向 -z)∈[-near,-far]→[0,1]。
private func matOrthoRH(halfW: Float, halfH: Float, nearZ: Float, farZ: Float) -> simd_float4x4 {
    let nf = 1 / (nearZ - farZ)
    return simd_float4x4(columns: (
        SIMD4(1 / halfW, 0, 0, 0),
        SIMD4(0, 1 / halfH, 0, 0),
        SIMD4(0, 0, nf, 0),                  // z' = (z·1 + ...)·nf ; RH 看 -z → near 处 z=-near
        SIMD4(0, 0, nearZ * nf, 1)
    ))
}
/// RH lookAt(同 matLookAt;此别名供阴影相机语义清晰)。
private func matLookAtRH(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
    matLookAt(eye: eye, center: center, up: up)
}

private func matLookAt(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
    let zf = simd_normalize(eye - center)   // glm lookAt: f = normalize(center-eye); 这里 z = -f = normalize(eye-center)
    let xf = simd_normalize(simd_cross(up, zf))
    let yf = simd_cross(zf, xf)
    return simd_float4x4(columns: (
        SIMD4(xf.x, yf.x, zf.x, 0),
        SIMD4(xf.y, yf.y, zf.y, 0),
        SIMD4(xf.z, yf.z, zf.z, 0),
        SIMD4(-simd_dot(xf, eye), -simd_dot(yf, eye), -simd_dot(zf, eye), 1)
    ))
}

/// 世界法线矩阵:world 上 3×3 的逆转置(非均匀缩放下法线不被拉歪),封装进 float4x4 的左上 3×3,
/// 其余行/列零(w=1),供 frag 取 (normalMat*float4(n,0)).xyz。退化(不可逆)时回退原 3×3。
private func normalMatrix(_ world: simd_float4x4) -> simd_float4x4 {
    let m3 = simd_float3x3(columns: (
        SIMD3(world.columns.0.x, world.columns.0.y, world.columns.0.z),
        SIMD3(world.columns.1.x, world.columns.1.y, world.columns.1.z),
        SIMD3(world.columns.2.x, world.columns.2.y, world.columns.2.z)
    ))
    let det = simd_determinant(m3)
    let inv3 = abs(det) > 1e-8 ? m3.inverse.transpose : m3
    return simd_float4x4(columns: (
        SIMD4(inv3.columns.0, 0),
        SIMD4(inv3.columns.1, 0),
        SIMD4(inv3.columns.2, 0),
        SIMD4(0, 0, 0, 1)
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

/// 从列主序 2D 仿射矩阵(TRS,列 0 = (c·sx, s·sx, ..))提取 z 旋转角(弧度)。供动态挂点取头骨呼吸时的微转。
private func zAngle(_ m: simd_float4x4) -> Float {
    return atan2(m.columns.0.y, m.columns.0.x)
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
    var name: String = ""   // pkg 对象 name(跨层写回:控制器脚本 getLayer(name) 按名命中目标层,如 Dock 图标 r1/o/l1)
    var sceneObjIndex: Int = .max   // scene.json objects 数组下标(粒子按场景序插画的锚点用)
    var texture: MTLTexture
    var baseModel: simd_float4x4 // 世界变换(不含投影、不含视差)
    var mvp: simd_float4x4       // 每帧 = proj * translate(视差) * baseModel
    var color: SIMD4<Float>
    var blend: BlendMode
    var colorBlendMode: Int = 0   // 对象级 colorBlendMode(>0 → framebuffer-fetch 方程混合,见 scene_fragment_blend)
    var origin: SIMD2<Float>
    var parallax: SIMD2<Float>   // parallaxDepth:视差响应强度
    var sizePx: SIMD2<Float>
    var rawSizePx: SIMD2<Float> = SIMD2(1, 1)   // **未缩放**原始 size(lwe CImage.cpp:239 m_size);composelayer 自有 FBO 用它(:278-283),scale 只作用于 quad 几何。sizePx=size×scale 仅用于 quad/mvp。
    var opaqueRect: SIMD4<Float> = SIMD4(0, 0, 1, 1)  // 贴图不透明内容包围盒(uv [u0,v0,u1,v1]);自适应判大图层真实内容是否探进 cover 裁切区
    var opaqueSolid: Float = 1                         // 包围盒内实心占比(alpha>200);区分密实主体(角色)vs 稀薄大气层(云/雾)
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
    // 逐特效辅助贴图的 g_TextureNResolution 覆写(slot→(容器w,h,内容w,h))。仅 freeimage 且容器≠内容的 .tex 需要
    // (真 WE 对这类纹理按头部喂分辨率、GPU 纹理却是内容尺寸 → UV 被压到内容上半部;lwe 特判修正=1 ≠ 真 WE)。
    var effectAuxRes: [[Int: SIMD4<Float>]] = []
                                             // 喂给 WEEffectChain 的 g_Texture<slot>(opacitymask/法线/相位/流向等)。
    var texFlags: TexFlags? = nil            // 图层贴图的真实 WE flags(主 pass + 特效 g_Texture0 采样器)
    var effectMaskFlags: [TexFlags?] = []    // **逐特效**遮罩贴图 flags(与 effects 对齐)
    var effectAuxFlags: [[Int: TexFlags]] = []  // **逐特效**辅助贴图 flags(slot→flags,与 effects 对齐)
    var useWE = false                   // 该层有任一可跑的真 WE 特效 → 跑 WEEffectChain 产出 effectedTexture
    var frameBufferInput = false        // composelayer/_rt_FullFrameBuffer:特效链输入=下方已合成整帧场景(打雷等)
    // 以本 composelayer 为 parent 的粒子组下标(scene `parent` 指向本层 id 且本层 frameBufferInput)。
    // 非空 → encodeLweScene 在跑本层特效前,把这些粒子组画进一张**透明全画布 child FBO**,
    // 用它(而非累积场景 sceneFBO)当 computeLayerEffect 的 sceneInput → 特效(tint/opacity-mask)只作用于
    // 「只含粒子」的 FBO,不染下方场景的角色/龙身(凯尔希×Mon3tr Matrix spawner 机制,真 WE,lwe 未实现)。
    var childParticleGroupIndices: [Int] = []
    var abovePost = false               // 排在最后一个 postChain fullscreenlayer 之上 → postChain 跑完后再叠(不被后处理染暗,WE 语义)
    var regionFit = false               // 区域性 composelayer(非 pulse):特效在该层 region [0,1] 跑(裁场景+遮罩到 region);encode 用普通 UV 贴回。pulse=false 走全屏画布 UV(不动)。
    var effectedTexture: MTLTexture? = nil   // 每帧由 WEEffectChain 产出的特效后纹理
    // 音频可视化 solidlayer(audioline 等):基底透明,effectedTexture 自带逐像素 alpha(除曲线外透明)。
    // 对象 alpha(常=0,只是基底填充透明)不应在最终合成再乘进来(会把曲线抹没)——lwe 只把 g_Alpha 喂给
    // 声明它的 shader,audioline 没声明 → 对象 alpha 对曲线无效。故这类层合成用 color.w=1.0 保留逐像素 alpha。
    var audioVizSelfAlpha = false
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
    // 全部可见 animationlayers(WE 真义:多层叠加合成,additive 层在 base 上追加位移)。
    // 御剑龙 = 「动画 1」base + 「动画 2」additive(含下压/飞行整体运动)——只播第一层会把龙整体运动丢掉(恒停高位)。
    var puppetAnimLayers: [(animId: Int, rate: Float, additive: Bool)] = []
    // 眼睛部件剔除朝向:默认 .none(3D 蒙皮自身把眼睛收缩闭合,实测不需剔除)。WP_EYE_CULL=front/back
    // 仅作 A/B 诊断(实测凯尔希眼三角绕序恒单朝向、眨眼不翻面 → .back 全程剔光眼、.front 不剔任何)。
    // 主 puppet(龙/刀/朱鹤/头发/衣物)恒 .none。
    var puppetCull: MTLCullMode = .none
    // 眼睛层:蒙皮用完整 3D TRS(含 rx/ry/tz 出平面)→ 眨眼闭合。主 puppet=false 用平面 TRS(丢 rx/ry,零回归;
    // 朱鹤 anim458 bone2 rx→π/2 在无深度的 2D 下会折叠成色块)。
    var puppetUse3D: Bool = false
    // 部件间 attachment 层(凯尔希眼睛/眼睑/耳朵→主体「头部」):baseModel/mvp 已按**父**变换搭好,
    // 子顶点已搬进父 mesh-local 空间。update() 的 origin/angle/scale 脚本及 origin 关键帧重建会用**子自身**
    // origin/size 覆写 baseModel → 破坏 attachment,故对这些层跳过那些重建(只保留视差,视差作用于 baseModel 安全)。
    var isAttached: Bool = false
    // —— 动态挂点跟随(2026-06-07):attach 部件每帧跟随**父 puppet 的逐帧骨骼动画**(主体 anim206 呼吸让头骨
    //    bone5 移动 → 眼/睑/耳跟头一起动,不脱离脸)。下列字段供 update() 每帧用 animatedAttachmentWorld 重算锚点。
    //    锚点用**增量**:modelCenter(t) = staticModelCenter + R(parentAngle)·((animAttachPos(t) − animAttachPos(0))·parentScale)
    //    → t=0 增量为 0,严格退化到 build 阶段的静态 baseModel(回归兜底);t>0 锚点按头骨实际位移量平移。
    //    旋转同理:attachAngle(t) = staticAttachAngle + (animAttachAngle(t) − animAttachAngle(0))(头骨呼吸时的微转)。
    var attachParentMesh: PuppetMesh? = nil      // 父 puppet mesh(解析其动画后挂点)
    var attachName: String = ""                  // 具名挂点(如「头部」)
    var attachParentAnimId: Int = 0              // 父骨骼动画 id(MDLA;主体 anim206)
    var attachParentAnimRate: Float = 1
    var attachParentScale: SIMD2<Float> = SIMD2(1, 1)   // 父世界 scale(静态)
    var attachParentAngle: Float = 0             // 父世界 z 角(弧度,静态)
    var attachStaticCenter: SIMD2<Float> = .zero // build 阶段算定的静态锚点(t=0 基线)
    var attachStaticAngle: Float = 0             // build 阶段算定的静态渲染角(t=0 基线)
    var attachBindPos: SIMD2<Float> = .zero      // 动画挂点 t=0 的 mesh-local 平移(增量基准)
    var attachBindAngle: Float = 0               // 动画挂点 t=0 的 mesh-local z 角(增量基准)
    var attachEffSize: SIMD2<Float> = SIMD2(1, 1) // 子自身 size×scale(几何大小,静态)
    // 子部件**实际锚点**在父 mesh-local 空间(= 挂点平移 + 子局部 origin)。眼睛偏离脸的真因(见 PuppetMesh.
    // attachBoneSkinMatrix 注释):呼吸让头骨**旋转**,离挂点枢轴越远的点位移越不同;眼睛组合锚点在枢轴右 630px,
    // 旧式只平移枢轴位移 → 偏离 24px。update 用该骨蒙皮矩阵变换**此点**(而非枢轴),捕获旋转放大的真实下沉。
    var attachAnchorLocal: SIMD2<Float> = .zero  // 子锚点(父 mesh-local;t=0)
    var attachAnchorBind: SIMD2<Float> = .zero   // 该锚点经骨蒙皮(t=0)后的位置(增量基准,通常≈anchorLocal)
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
    var alphaKeyAnim: WEKeyframeAnimation? = nil   // 对象 alpha 时间线关键帧(开场动画黑层淡出)
    var cropShiftPx: SIMD2<Float> = .zero          // 实际应用的 cropoffset 世界位移;origin 关键帧每帧重算后需再加上(否则关键帧冲掉 crop)
    // 缺口B/D:visible/alpha/color 字段挂的 WE JS 脚本(每帧 reevaluate;无脚本则 nil)。
    var visibleScript: WEScript? = nil
    var alphaScript: WEScript? = nil
    var colorScript: WEScript? = nil
    // 每帧由 visibleScript 更新的显隐(无脚本恒 = 静态初值,绝大多数为 true)。绘制门控用。
    var visible: Bool = true
    // 运行时动态建层脚本(音频条:init 建 NUM_BARS 根 bar,update 按音频写各 bar 的 origin/scale/alignment)。
    // 非 nil 时本层是「bar 模板」:不直接渲染本层 quad,而是用本层贴图多实例渲染脚本每帧读回的每根 bar
    // (barMVPs)。属性回灌即「读回 bar 对象的 origin/scale/alignment → 算 mvp」(脚本→引擎单向回灌)。
    var instancedBarsScript: WEScript? = nil
    var instancedBarBaseSize: SIMD2<Float> = SIMD2(4, 4)  // 单根 bar 基准像素尺寸(bar.json autosize)
    var barMVPs: [simd_float4x4] = []   // 每帧算出的每根 bar 的 mvp(proj×视差×matModel);空=本帧不画条
}

/// 文本图层运行态:描述 + 上次渲染的字符串(变了才重渲染,省开销)。
private final class TextLayerState {
    var desc: TextLayerDesc   // 3D 场景:每帧可改 kind=.staticText(宿主算的文字)
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

/// 2D 等比缩放矩阵(绕原点)。
private func matScale2(_ s: Float) -> simd_float4x4 {
    simd_float4x4(columns: (
        SIMD4(s, 0, 0, 0),
        SIMD4(0, s, 0, 0),
        SIMD4(0, 0, 1, 0),
        SIMD4(0, 0, 0, 1)
    ))
}

/// 2D 场景相机**运镜**仿射矩阵(在静态正交 proj **之前**乘进 mvp,即 mvp = proj · cameraAnim · model)。
/// 工作在画布像素空间:
///   · zoom:绕取景中心 c 缩放 zoom 倍 → content 放大 zoom 倍(zoom=1 → 恒等;>1 = 推近)。
///   · pan:相机眼位 origin.xy 相对帧0 移动 dp → content 反向平移 −dp(相机右移=画面左移),并随 zoom 同步缩放
///     (相机移动量在放大后的画面里也放大,WE 编辑器约定)。
/// 组合:M = T(c) · S(zoom) · T(−c) · T(−dp·zoom) = T(c) · S(zoom) · T(−c − dp)。
/// 当 zoom=1 且 dp=0(静止态 / 无运镜)→ M = T(c)·I·T(−c) = identity → proj 逐位不变(零回归)。
/// 枢轴 center = 画布中心;pan 相对静止态(末关键帧)= establishing shot,intro 飞入后落到它。
private func cameraAnimMatrix(center c: SIMD2<Float>, zoom: Float, pan dp: SIMD2<Float>) -> simd_float4x4 {
    let z = max(0.0001, zoom)
    // T(c) · S(z) · T(−c − dp)
    return matTranslate(c.x, c.y) * matScale2(z) * matTranslate(-c.x - dp.x, -c.y - dp.y)
}

private struct VertexUniforms { var mvp: simd_float4x4; var color: SIMD4<Float> }

/// 一组粒子(一个发射器):模拟器 + 纹理 + 实例缓冲。
private final class ParticleGroup {
    let sim: ParticleSimulator
    let texture: MTLTexture
    let additive: Bool
    let isRefract: Bool             // 折射粒子(玻璃雨滴):照 WE 采样场景底图,单独 pass 绘制
    let isRope: Bool                // rope/ropetrail:连成 Catmull-Rom 带状网格(非散点精灵)
    let normalTexture: MTLTexture?  // 法线贴图(textures[1]),折射偏移用
    let aboveBloom: Bool            // 排在后处理层之上 → 在 bloom 之后叠加(不被 bloom),照 WE 图层序
    let parallaxDepth: SIMD2<Float> // 该粒子层 parallaxDepth(鼠标视差);照图像层同公式在 encode 平移投影,缺省(1,1)
    // 审计修复#2:每组持 3 套实例/rope 缓冲轮换(原来跨帧复用同一块、每帧 copyMemory 覆写 → GPU 可能仍在
    //   读上一帧)。配合 render() 的 DispatchSemaphore(value:3) 限流,CPU 改写第 N 套时 GPU 已读完它。
    var instanceBuffers: [MTLBuffer?] = [nil, nil, nil, nil]
    var instanceCount: Int = 0
    var ropeBuffers: [MTLBuffer?] = [nil, nil, nil, nil]   // rope 带状三角形顶点(每帧重建,4 套轮换)
    var ropeVertexCount: Int = 0
    // 场景序插画锚点(WE 按 objects 顺序绘制一切,粒子可在图层**之间**):
    // = 首个场景序排在本粒子之后的图层下标;encode 在画 layers[anchor] 之前冲刷本组。
    // layers.count = 在所有图层之上(顶层粒子)。Postscript 鸟(对象序[1])锚到人物层之前 → 被人物盖住。
    var anchorLayerIndex: Int = .max
    // scene `parent` id(从 ParticleEmitterDesc.parentObjId 透传)。
    var parentObjId: Int? = nil
    // parent 解析到的 composelayer(frameBufferInput)图层下标。非 nil → 本组**不进主场景**,
    // 而是渲进该 composelayer 的 child FBO(见 GPULayer.childParticleGroupIndices)。
    var parentComposeLayerIndex: Int? = nil
    init(sim: ParticleSimulator, texture: MTLTexture, additive: Bool,
         isRefract: Bool = false, isRope: Bool = false, normalTexture: MTLTexture? = nil, aboveBloom: Bool = false,
         parallaxDepth: SIMD2<Float> = SIMD2(1, 1)) {
        self.sim = sim; self.texture = texture; self.additive = additive
        self.isRefract = isRefract; self.isRope = isRope
        self.normalTexture = normalTexture; self.aboveBloom = aboveBloom
        self.parallaxDepth = parallaxDepth
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
    private var pipelineBlitMix: MTLRenderPipelineState?          // 常量-alpha 混合:把后处理层结果按 opacity 叠回前一画面
    private var pipelineBlitFXAA: MTLRenderPipelineState?          // FXAA 呈现(画质设置开时用)
    private var pipelineBlitAspect: MTLRenderPipelineState?        // 屏幕适配呈现(uvScale 居中裁切/留黑边,= lwe updateTextureUVs)
    private var pipelineCursorMark: MTLRenderPipelineState?        // 诊断(WP_CURSOR_MARK):在引擎认为的 cursorUV 处画十字+环,核对 vs 物理光标
    private var pipelineBlitPresent: MTLRenderPipelineState?       // 通用区呈现:翻转 + 图片筛选器(仅启用时用)
    // MARK: 3D 透视场景(太阳系3662790108/土星3589454154 等;.mdl 几何模型 + 透视相机 + 深度缓冲)
    private struct Material3DGPU { let tex: MTLTexture?; let color: SIMD3<Float>; let brightness: Float; let alpha: Float; let translucent: Bool; let lighting: Bool }
    private struct Submesh3DGPU { let mat: Material3DGPU; let start: Int; let count: Int }
    // lit=接收方向光 N·L + 阴影(仅行星);castsShadow=作为环影 caster(土星环/陨石)。
    private struct Model3DGPU { let id: Int; let vb: MTLBuffer; let ib: MTLBuffer; var world: simd_float4x4; let submeshes: [Submesh3DGPU]; var lit: Bool = false; var castsShadow: Bool = false }
    // 方向光阴影(土星)运行参数:由 build3DModels 从 Scene3DRuntime 算出。
    private var scene3DLightDir = SIMD3<Float>(-1, 0, 0)   // 指向太阳(世界)
    private var scene3DLightVP = matrix_identity_float4x4  // 阴影正交相机 view·proj
    private var scene3DHasShadow = false                   // 该场景有方向光阴影(土星)→ 跑阴影 pass
    private var models3D: [Model3DGPU] = []
    private var scene3DRuntime: Scene3DRuntime?      // 脚本+变换运行时(逐帧 live 或烘焙)
    private var scene3DPerFrame = false              // 脚本数少(土星)→ 逐帧 tick 宿主(HUD 文字 live);多(太阳系)→ 烘焙冻结
    private var scene3DLastTime: Double = 0
    private var scene3DBakeTime: Double = 20         // 模型烘焙时刻;逐帧 tick 从 bakeTime+elapsed 续(HUD 续跑,模型保持烘焙)
    private let scene3DLiveModels = ProcessInfo.processInfo.environment["WP_3D_LIVE_MODELS"] != nil  // 调试:让模型也逐帧(取景会漂)
    private var scene3DSolarOrbit = false                                                            // 日心太阳系(currentFocus):逐帧公转(R4)
    private let noSolarOrbit = ProcessInfo.processInfo.environment["WP_NO_SOLAR_ORBIT"] != nil       // 退回烘焙冻结
    private var scene3DIntroModels = false   // 入场动画(土星):从 t0 逐帧驱动模型(从下升起+倾入,>settled 后脚本本就 hold)
    private let noIntro = ProcessInfo.processInfo.environment["WP_NO_3D_INTRO"] != nil   // 退回烘焙冻结(土星卡半升起)
    private var scene3DIntroSettle: Double = 0   // 入场结束时刻(脚本最末关键帧 t);此后停刷模型省 GPU
    // 持续自转(土星行星/环/陨石绕 Y 轴恒转,settle 后仍转):入场结束后**仍逐帧 recompute**模型世界矩阵。
    // 相机静态(运行时相机对象 id=243)→ 转模型不漂。WP_NO_RING_ANIM=1 退回 settle 后冻结(旧行为,环静止)。
    private var scene3DContinuousSpin = false
    private let noRingAnim = ProcessInfo.processInfo.environment["WP_NO_RING_ANIM"] != nil
    private var logged3DHud = false   // WP_3D_HUD_LOG 诊断:只打一次 HUD 层位置
    private var viewProj3D = matrix_identity_float4x4
    private var light3D: Scene3DRuntime.ResolvedLight?   // 3D 场景方向光(N·L 漫反射昼夜终止线);nil/WP_NO_3D_LIGHTING=平涂
    private var depthTex3D: MTLTexture?
    private var pipeline3DOpaque: MTLRenderPipelineState?
    private var pipeline3DBlend: MTLRenderPipelineState?
    private var orbitPipeline: MTLRenderPipelineState?      // 内行星轨道(WE guidao P1-P4)
    private var orbit2Pipeline: MTLRenderPipelineState?     // 外行星轨道(WE guidao2 P5-P9)
    private var sunPipeline: MTLRenderPipelineState?        // 太阳辉光屏幕精灵(加色)
    private var godrayPipeline: MTLRenderPipelineState?     // 体积光 god rays(太阳放射光shaft)
    private var sunSpriteTex: [Int: MTLTexture] = [:]       // 太阳精灵 id → 纹理
    private struct GodUGPU { var sunUV: SIMD2<Float>; var weight: Float; var decay: Float; var density: Float; var exposure: Float }
    private struct SunUGPU { var centerUV: SIMD2<Float>; var sizeUV: SIMD2<Float>; var brightness: Float; var pad: Float = 0; var tint: SIMD3<Float> }
    private var scene3DHidden: Set<Int> = []               // visible 脚本判为隐藏的节点(灵动岛/通知等条件UI)
    private var scene3DSceneTex: MTLTexture?                // render3D 中间纹理(轨道后处理读它)
    private var scene3DSceneTex2: MTLTexture?               // 内→外 轨道链式第二中间纹理
    // 与 Metal `struct OrbitU` 布局一致(float×4 + float3 + float×3 + float3×8 + float4;SIMD3 16字节对齐)。
    private struct OrbitUGPU {
        var lineOpacity: Float = 0; var globalScale: Float = 1; var trailEnable: Float = 0; var maxAB: Float = 160
        var rotation: SIMD3<Float> = .zero
        var originX: Float = 0; var originY: Float = 0; var originZ: Float = 0
        var p1A: SIMD3<Float> = .zero; var p1B: SIMD3<Float> = .zero
        var p2A: SIMD3<Float> = .zero; var p2B: SIMD3<Float> = .zero
        var p3A: SIMD3<Float> = .zero; var p3B: SIMD3<Float> = .zero
        var p4A: SIMD3<Float> = .zero; var p4B: SIMD3<Float> = .zero
        var texRes: SIMD4<Float> = .zero
    }
    private struct OrbitU2GPU {   // 外行星(P5-P9)
        var lineOpacity: Float = 0; var globalScale: Float = 1; var trailEnable: Float = 0; var maxAB: Float = 160
        var rotation: SIMD3<Float> = .zero
        var originX: Float = 0; var originY: Float = 0; var originZ: Float = 0
        var p5A: SIMD3<Float> = .zero; var p5B: SIMD3<Float> = .zero
        var p6A: SIMD3<Float> = .zero; var p6B: SIMD3<Float> = .zero
        var p7A: SIMD3<Float> = .zero; var p7B: SIMD3<Float> = .zero
        var p8A: SIMD3<Float> = .zero; var p8B: SIMD3<Float> = .zero
        var p9A: SIMD3<Float> = .zero; var p9B: SIMD3<Float> = .zero
        var texRes: SIMD4<Float> = .zero
    }
    private var depthState3DWrite: MTLDepthStencilState?     // depth test+write(不透明)
    private var depthState3DNoWrite: MTLDepthStencilState?   // depth test 只读(透明,后画)
    private var pipeline3DShadow: MTLRenderPipelineState?    // 方向光阴影投影(土星环影):caster 几何深度-only
    private var shadowMapTex: MTLTexture?                    // 方向光阴影深度图(2048²)
    private static let shadowMapSize = 2048
    private var whiteTex3D: MTLTexture?                       // baseColor 缺失兜底(1×1 白)
    var has3DScene: Bool { !models3D.isEmpty }
    private var renderScaleTex: MTLTexture?                        // render-scale/MetalFX 的低分辨率编码目标
    private var mfxScaler: (any MTLFXSpatialScaler)?               // MetalFX 空间放大器(按输入/输出尺寸缓存)
    private var mfxKey: String = ""                               // scaler 的尺寸键(变了就重建)
    private var refractSceneTex: MTLTexture?                       // 折射用:层+非折射粒子的离屏底图
    private var sceneBelowForEffects: MTLTexture?                  // frame_builder 等整帧底图特效用:该层之下已合成场景
    private var ndcScale = SIMD2<Float>(1, 1)                      // 顶点宽高比缩放:新机制下渲到画布长宽比纹理→恒(1,1)(不缩放=无分带)
    private var aspectMouse = SIMD2<Float>(1, 1)                   // 鼠标/视差用的「旧 cover/fit ndc」(从屏幕长宽比算;blitUVScale=1/它)
    private var blitUVScale = SIMD2<Float>(1, 1)                   // 最终呈现 blit 的 uvScale(lwe updateTextureUVs:<1 裁切、>1 留黑边)
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
            // 屏幕适配呈现管线(uvScale 居中裁切/留黑边):场景渲到画布长宽比纹理后,最终一次性 blit 到屏幕。
            if let fsa = lib.makeFunction(name: "fullscreen_copy_aspect") {
                let da = MTLRenderPipelineDescriptor()
                da.vertexFunction = fsv; da.fragmentFunction = fsa
                da.colorAttachments[0].pixelFormat = .bgra8Unorm
                pipelineBlitAspect = try? device.makeRenderPipelineState(descriptor: da)
            }
            // 常量-alpha 混合管线(同顶点/片元,开 blend):src*constAlpha + dst*(1-constAlpha) = mix(dst, src, α)。
            // 供后处理层 opacity 把"加特效的画面"按 α 叠回下方干净画面(真 WE 的 fullscreenlayer 图层 opacity 语义)。
            let dm = MTLRenderPipelineDescriptor()
            dm.vertexFunction = fsv; dm.fragmentFunction = fsf
            let am = dm.colorAttachments[0]!
            am.pixelFormat = .bgra8Unorm
            am.isBlendingEnabled = true
            am.rgbBlendOperation = .add; am.alphaBlendOperation = .add
            am.sourceRGBBlendFactor = .blendAlpha;   am.destinationRGBBlendFactor = .oneMinusBlendAlpha
            am.sourceAlphaBlendFactor = .blendAlpha; am.destinationAlphaBlendFactor = .oneMinusBlendAlpha
            pipelineBlitMix = try? device.makeRenderPipelineState(descriptor: dm)
            // FXAA 呈现管线(同顶点,FXAA 片元)。
            if let fxaa = lib.makeFunction(name: "fullscreen_fxaa") {
                let df = MTLRenderPipelineDescriptor()
                df.vertexFunction = fsv; df.fragmentFunction = fxaa
                df.colorAttachments[0].pixelFormat = .bgra8Unorm
                pipelineBlitFXAA = try? device.makeRenderPipelineState(descriptor: df)
            }
            // 光标标记诊断管线(blend 叠在呈现画面上)。
            if let cm = lib.makeFunction(name: "cursor_marker") {
                let dc = MTLRenderPipelineDescriptor()
                dc.vertexFunction = fsv; dc.fragmentFunction = cm
                let a = dc.colorAttachments[0]!
                a.pixelFormat = .bgra8Unorm
                a.isBlendingEnabled = true
                a.rgbBlendOperation = .add; a.alphaBlendOperation = .add
                a.sourceRGBBlendFactor = .sourceAlpha; a.destinationRGBBlendFactor = .oneMinusSourceAlpha
                a.sourceAlphaBlendFactor = .one; a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
                pipelineCursorMark = try? device.makeRenderPipelineState(descriptor: dc)
            }
            // 通用区呈现管线(翻转 + 图片筛选器)。仅在 flip/filter 启用时用,默认走 pipelineBlit 不变。
            if let pf = lib.makeFunction(name: "fullscreen_present") {
                let dp = MTLRenderPipelineDescriptor()
                dp.vertexFunction = fsv; dp.fragmentFunction = pf
                dp.colorAttachments[0].pixelFormat = .bgra8Unorm
                pipelineBlitPresent = try? device.makeRenderPipelineState(descriptor: dp)
            }
        }
        // 3D 透视场景模型管线(深度测试 + 透视 MVP);不透明(写深度)+ 透明(alpha 混合、只读深度)两条。
        if let v3 = lib.makeFunction(name: "model3d_vertex"), let f3 = lib.makeFunction(name: "model3d_fragment") {
            func make3D(_ blend: Bool) -> MTLRenderPipelineState? {
                let d = MTLRenderPipelineDescriptor()
                d.vertexFunction = v3; d.fragmentFunction = f3
                d.colorAttachments[0].pixelFormat = .bgra8Unorm
                d.depthAttachmentPixelFormat = .depth32Float
                if blend {
                    let att = d.colorAttachments[0]!
                    att.isBlendingEnabled = true
                    att.rgbBlendOperation = .add; att.alphaBlendOperation = .add
                    att.sourceRGBBlendFactor = .sourceAlpha; att.destinationRGBBlendFactor = .oneMinusSourceAlpha
                    att.sourceAlphaBlendFactor = .one;        att.destinationAlphaBlendFactor = .oneMinusSourceAlpha
                }
                return try? device.makeRenderPipelineState(descriptor: d)
            }
            pipeline3DOpaque = make3D(false)
            pipeline3DBlend  = make3D(true)
            let dw = MTLDepthStencilDescriptor(); dw.depthCompareFunction = .less; dw.isDepthWriteEnabled = true
            depthState3DWrite = device.makeDepthStencilState(descriptor: dw)
            let dn = MTLDepthStencilDescriptor(); dn.depthCompareFunction = .less; dn.isDepthWriteEnabled = false
            depthState3DNoWrite = device.makeDepthStencilState(descriptor: dn)
            // 方向光阴影投影管线(深度-only,无 color attachment):caster→光源正交相机。
            if let sv = lib.makeFunction(name: "model3d_shadow_vertex") {
                let sd = MTLRenderPipelineDescriptor()
                sd.vertexFunction = sv; sd.fragmentFunction = nil
                sd.depthAttachmentPixelFormat = .depth32Float
                sd.colorAttachments[0].pixelFormat = .invalid
                pipeline3DShadow = try? device.makeRenderPipelineState(descriptor: sd)
            }
        }
        // 轨道椭圆 shader(WE guidao.frag/guidao2.frag 转译,独立库):全屏后处理画 P1-P4(内)/P5-P9(外)椭圆。
        if let olib = try? device.makeLibrary(source: orbitShaderSource, options: nil),
           let ov = olib.makeFunction(name: "orbit_vertex"), let of = olib.makeFunction(name: "orbit_fragment") {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = ov; d.fragmentFunction = of
            d.colorAttachments[0].pixelFormat = .bgra8Unorm
            orbitPipeline = try? device.makeRenderPipelineState(descriptor: d)
        }
        if let olib = try? device.makeLibrary(source: orbit2ShaderSource, options: nil),
           let ov = olib.makeFunction(name: "orbit_vertex2"), let of = olib.makeFunction(name: "orbit_fragment2") {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = ov; d.fragmentFunction = of
            d.colorAttachments[0].pixelFormat = .bgra8Unorm
            orbit2Pipeline = try? device.makeRenderPipelineState(descriptor: d)
        }
        Log.write("buildPipelines: orbit=\(orbitPipeline != nil) orbit2=\(orbit2Pipeline != nil)")
        // 太阳辉光精灵(加色混合:src + dst,辉光叠加)
        if let slib = try? device.makeLibrary(source: sunSpriteShaderSource, options: nil),
           let sv = slib.makeFunction(name: "sun_vertex"), let sf = slib.makeFunction(name: "sun_fragment") {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = sv; d.fragmentFunction = sf
            let att = d.colorAttachments[0]!
            att.pixelFormat = .bgra8Unorm
            att.isBlendingEnabled = true
            att.rgbBlendOperation = .add; att.alphaBlendOperation = .add
            att.sourceRGBBlendFactor = .sourceAlpha; att.destinationRGBBlendFactor = .one  // 按辉光alpha形状加色(圆)
            att.sourceAlphaBlendFactor = .zero; att.destinationAlphaBlendFactor = .one
            sunPipeline = try? device.makeRenderPipelineState(descriptor: d)
            if let gf = slib.makeFunction(name: "godrays_fragment"), let gv = slib.makeFunction(name: "god_vertex") {
                let gd = MTLRenderPipelineDescriptor()
                gd.vertexFunction = gv; gd.fragmentFunction = gf
                gd.colorAttachments[0].pixelFormat = .bgra8Unorm   // 全屏覆盖输出 base+shaft
                godrayPipeline = try? device.makeRenderPipelineState(descriptor: gd)
            }
            Log.write("buildPipelines: sun=\(sunPipeline != nil) godray=\(godrayPipeline != nil)")
        }
        Log.write("buildPipelines: particleAlpha=\(pipelineParticleAlpha != nil) particleAdd=\(pipelineParticleAdd != nil) refract=\(pipelineParticleRefract != nil) refractAdd=\(pipelineParticleRefractAdd != nil) model3d=\(pipeline3DOpaque != nil)")
    }

    // MARK: - 加载场景

    func load(document: SceneDocument, source: SceneSource) {
        auditLines.removeAll()   // 渲染审计:新场景重新收集加载期事件/警告
        // 释放上一个场景占用的音频捕获(若有),再按新场景重新 acquire。
        if usesAudio { AudioCapture.shared.release(); usesAudio = false }
        // 壁纸自带音频(sound 对象,BGM/雨声):停旧的、按新场景加载。默认随全局 isMuted(默认静音)不出声。
        audioPlayback.stop()
        if !document.sounds.isEmpty {
            audioPlayback.load(sounds: document.sounds, source: source,
                               muted: PreferencesStore.shared.isMuted, volume: Float(PreferencesStore.shared.volume))
        }
        // Now Playing widget(歌名/艺术家文本由 mediaPropertiesChanged 驱动):数据源 = 壁纸自带 BGM
        // 文件名,引擎正在播它。WE 在 Windows 上把壁纸音频注册进系统媒体会话所以歌名自然显示;mac 无此
        // 机制,故直接解析文件名(`artist_-_title_<hash>` 格式)喂回脚本,等价"正在播这首歌"。
        let np = Self.parseNowPlaying(from: document.sounds)
        nowPlayingTitle = np.title; nowPlayingArtist = np.artist
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
        //
        // 缺口2:透视(3D)场景相机。判别见 SceneModel CameraDesc.isPerspective(general.orthogonalprojection
        // 为 null/缺失 → 透视)。**正交保持上面的等价做法不动**;仅当 isPerspective 时才走透视分支。
        // lwe 自身不支持透视场景相机(Camera 类只有 setOrthogonalProjection),无可直接移植的 Camera 透视分支;
        // 这里按真 WE 语义、用 lwe Camera 已备好的 fov/nearz/farz(Camera.cpp:36-40)与 lookAt(Camera.cpp:13)、
        // 以及 lwe 唯一 perspective 构建用法(CParticle.cpp:1892 glm::perspective)建:proj = perspective · lookAt。
        // ⚠ 不确定/留作裁决:本工程其余几何(matModel 像素 quad、matOrtho 像素→NDC、CImage Y 翻转、视差/footprint)
        //   全部围绕**像素空间正交**搭建。WE 透视场景的对象坐标是 3D 世界单位(非画布像素),完整正确渲染需要
        //   把对象 origin/size 当世界单位、模型用 puppet/model mesh 真 3D 顶点喂进 perspective·lookAt——这是更大的
        //   3D 管线工程,本任务范围只补**相机投影矩阵**本身(机制就位、可独立编译),供 3D 场景接入时使用。
        //   现有 2D 像素管线在透视 proj 下取景**不会自动正确**(像素当世界单位会缩到极小)。故透视分支默认**关**
        //   (opt-in WP_PERSPECTIVE_CAMERA=1),避免把当前按 2D 处理的场景显示弄坏;开关打开则用真透视 proj。
        let proj: simd_float4x4
        if document.camera.isPerspective,
           ProcessInfo.processInfo.environment["WP_PERSPECTIVE_CAMERA"] != nil {
            let cam = document.camera
            let aspect = canvas.x / canvas.y
            let p = matPerspective(fovRadians: cam.fov * Float.pi / 180,   // CParticle.cpp:1891 glm::radians(fov)
                                   aspect: aspect, nearZ: cam.nearZ, farZ: cam.farZ)
            let v = matLookAt(eye: cam.eye, center: cam.center, up: cam.up) // Camera.cpp:13
            proj = p * v                                                    // CImage.cpp:389 getProjection()*getLookAt()
            Log.write("scene: perspective camera fov=\(cam.fov) eye=\(cam.eye) near=\(cam.nearZ) far=\(cam.farZ)")
        } else {
            proj = matOrtho(width: canvas.x, height: canvas.y)
        }
        let loader = MTKTextureLoader(device: device)

        // ── 3D 透视场景(.mdl 模型 + 透视相机 + 深度):太阳系 3662790108 / 土星 3589454154 等 ──
        // orthogonalprojection=null → isPerspective。加载 .mdl 几何 + 材质 + 世界矩阵,建 viewProj。
        // 成功则**只渲 3D 模型**(2D UI 叠加后续再做),早返回跳过 2D 图层/粒子/特效装配(零回归:仅 3D 场景命中)。
        models3D = []
        if document.camera.isPerspective {
            let cam = document.camera
            let aspect = canvas.x / canvas.y
            build3DModels(source: source, loader: loader)
            // 相机:**日心太阳系模拟**(Main 写 shared.currentFocus、经 getLayer 把内容定位在 sim 原点)的内容脚本
            // (sun origin、guidao 轨道 effect)按**固定相机**做投影:eye=(0,0,4.54)看 -Z(原点)、fov=66(实测
            // 轨道 effect csv「Camera Distance=4.54 / Camera Dir Z=-1 / FOV=66」+ sun 脚本 FIXED_CAM_DIST=4.54)。
            // 授权 scene.camera(eye dist 2.68/center偏47°/fov50)=编辑器残留视角,运行时不用。内容倾斜由 rotScreenX/Y。
            // 土星等无此模拟 → 用授权 scene.camera(精确零回归)。
            let helioSim = scene3DRuntime?.sharedHas("currentFocus") ?? false
            let forceOrigin = ProcessInfo.processInfo.environment["WP_3D_LOOKORIGIN"] != nil
            let eye: SIMD3<Float>; let center: SIMD3<Float>; let up: SIMD3<Float>; let fovDeg: Float
            if helioSim || forceOrigin {
                let camDist = Float(ProcessInfo.processInfo.environment["WP_3D_CAMDIST"] ?? "") ?? 4.54
                eye = SIMD3(0, 0, camDist); center = .zero; up = SIMD3(0, 1, 0)
                fovDeg = Float(ProcessInfo.processInfo.environment["WP_3D_FOV"] ?? "") ?? 66
            } else if let objEye = cam.objEye {
                // ⭐运行时相机对象(camera:"default" 静态 origin=eye)看 -z:替代顶层编辑器残留 scene.camera。
                // 实测土星 3589454154:顶层 scene.camera eye=(3.66,..) 看 (3.30,..) → 土星(x=0)渲到左偏 0.36 不居中;
                // 相机对象 id=243 origin=(0,0,2.3) 看 -z → 土星 x=0 居中(用户:土星应在中间)。与太阳系(0,0,4.54)同理。
                eye = objEye; center = SIMD3(objEye.x, objEye.y, objEye.z - 1); up = SIMD3(0, 1, 0)
                fovDeg = cam.objFov ?? cam.fov
            } else {
                eye = cam.eye; center = cam.center; up = cam.up; fovDeg = cam.fov
            }
            let p = matPerspective(fovRadians: fovDeg * Float.pi / 180,
                                   aspect: aspect, nearZ: max(0.01, cam.nearZ), farZ: max(cam.farZ, 1))
            let v = matLookAt(eye: eye, center: center, up: up)
            viewProj3D = p * v
            if !models3D.isEmpty {
                Log.write("3D scene: \(models3D.count) models, fov=\(cam.fov) eye=\(cam.eye) near=\(cam.nearZ) far=\(cam.farZ)")
                // 默认:继续构建 2D 层 → 宿主驱动的 HUD(dock/时钟/距离/角度文字,按 chainTop 判据分流:
                // 屏幕族正交 / 3D 族透视)。WP_NO_3D_HUD=1 退回只渲 3D 模型(早返回)。
                if ProcessInfo.processInfo.environment["WP_NO_3D_HUD"] != nil {
                    layers = []; particleGroups = []; postChain = []
                    return
                }
            }
        }

        var result: [GPULayer] = []
        for layer in document.layers {
            // 缺口B:有 visibleScript 的层即使静态 visible=false 也要建(否则脚本永远点不亮);
            // 其每帧由脚本决定显隐(绘制门控 layers[i].visible)。无脚本的静态隐藏层仍跳过(零变化)。
            guard layer.visible || layer.visibleScript != nil else { continue }

            let tex: MTLTexture
            var texFlags: TexFlags? = nil   // 图层贴图的真实 WE flags(驱动主 pass + 特效 g_Texture0 采样器)
            var videoTex: VideoTexture? = nil
            var textState: TextLayerState? = nil
            // 带空间特效的 solidlayer 已把 color 烘进层尺寸纹理(见 solidColorTexture)→ 合成时不再二次乘 color。
            var solidColorBaked = false
            // 音频可视化 solidlayer(audioline 等):透明底 + effectedTexture 自带逐像素 alpha,对象 alpha=0 不应再乘。
            var audioVizSelfAlpha = false
            var opaqueR = SIMD4<Float>(0, 0, 1, 1)   // 贴图不透明内容包围盒(自适应判大图截断用)
            var opaqueSolidR: Float = 1              // 包围盒内实心占比(角色 vs 云雾)
            if layer.audioBars != nil {
                // 音频频谱条:用**透明**底纹理作画布,真 WE Simple_Audio_Bars shader(在 effects 链里)
                // 据系统音频频谱把条画上去(TRANSPARENCY=REPLACE → alpha=bar*opacity),再由 perspective
                // 把条贴到场景梯形。底纹理分辨率决定条的采样精度(512×256,与旧 CPU 条一致)。需音频捕获。
                guard let t = transparentTexture(width: 512, height: 256) else { continue }
                tex = t
                AudioCapture.shared.acquire()
                usesAudio = true
            } else if layer.selfDrawFullscreen {
                // 自绘满画布特效层(lightshafts 阳光/光束):shape="quad" + 无 image + DIRECTDRAW 自绘特效。
                //   用**透明全画布底**作 g_Texture0(DIRECTDRAW 分支 `albedo=CAST4(0)` 忽略它),真 WE
                //   lightshafts shader 据 point0..3 透视 UV 把光束自绘上去(alpha=光束强度);additive 合成。
                //   底分辨率取画布最长边 ≤ 1920(省显存,光束是平滑渐变、不需全分辨率)。
                let cw = max(2, Int((layer.sizePx?.x ?? 1920).rounded()))
                let ch = max(2, Int((layer.sizePx?.y ?? 1080).rounded()))
                let longest = max(cw, ch)
                let cap = 1920
                let bw = longest > cap ? Int((Float(cw) * Float(cap) / Float(longest)).rounded()) : cw
                let bh = longest > cap ? Int((Float(ch) * Float(cap) / Float(longest)).rounded()) : ch
                guard let t = transparentTexture(width: max(2, bw), height: max(2, bh)) else {
                    Log.write("scene: lightshafts transparent texture alloc failed for \(layer.name)"); continue
                }
                tex = t
                // 保留 effectedTexture 逐像素 alpha(光束强度),合成不乘对象色(对象色 = 白 (1,1,1,1))。
                audioVizSelfAlpha = true
            } else if let textDesc = layer.text {
                // 文本图层(时钟/日期):Core Text 渲染成纹理,每秒刷新。
                var td = textDesc
                // 壁纸自带字体(font 字段是 pkg 路径,如 "fonts/Atami-Regular.otf"):注册进 CoreText 后
                // 用其 PostScript 名,否则 resolveFont 取不到 → 落系统字体 → 时钟/文字「不是原版」。
                let fn = td.fontName.lowercased()
                if fn.hasSuffix(".otf") || fn.hasSuffix(".ttf") || fn.contains("/") {
                    if let ps = FontRegistry.shared.register(path: td.fontName, source: source) { td.fontName = ps }
                }
                // Now Playing 文本(歌名/艺术家):建层前先派发当前曲目,否则首帧文本为空 → makeTextTexture
                // 返回 nil → 整层被 continue 丢掉(就是 audit 里这些层"建了 LayerDesc 却无 GPULayer"的原因)。
                if case .script(let s) = td.kind, s.isMediaDriven {
                    let np = effectiveNowPlaying
                    s.dispatchMediaState(title: np.title, artist: np.artist, positionSec: nil, lengthSec: nil)
                }
                guard let t = makeTextTexture(td, loader: loader) else {
                    Log.write("scene: text layer render failed \(layer.name)"); continue
                }
                tex = t.0
                textState = TextLayerState(desc: td, lastString: TextLayerRenderer.currentString(td))
            } else if layer.isSolid, layer.effects.contains(where: { weEffects?.usesAudioSpectrum($0.weName) == true }) {
                // 音频可视化 solidlayer(如 audioline,非标准 Simple_Audio_Bars):用**透明**底,真 WE shader 据
                // 系统频谱在其上画曲线(无曲线处透明),叠在场景上(用白底会变白块)。需音频捕获。
                // 底纹理分辨率 = **层实际尺寸**(非旧的固定 1024×512):① audioline 曲线粗细按归一化设(如 0.001),
                // 在 512 高的底上只有 0.5px=亚像素→落像素缝里渲不出(玛奇玛/凯尔希音频线全不可见的真因);用层尺寸
                // (常 1000×1000)→ 0.001×1000=1px 可见。② 固定 2:1 还把方形 audioline 层的曲线横向压扁
                //(shader 用 g_Texture0Resolution.x/y 算宽高比),用层真实宽高比修正。下限保证细线≥1px,上限省显存。
                let asz = layer.sizePx ?? SIMD2(1024, 1024)
                let aw = min(2048, max(768, Int(asz.x.rounded())))
                let ah = min(2048, max(768, Int(asz.y.rounded())))
                guard let t = transparentTexture(width: aw, height: ah) else { continue }
                tex = t
                AudioCapture.shared.acquire()
                usesAudio = true
                audioVizSelfAlpha = true   // 合成保留 effectedTexture 逐像素 alpha,不乘对象 alpha(常=0,会抹没曲线)
            } else if layer.isSolid,
                      ProcessInfo.processInfo.environment["WP_NO_SOLIDFX"] == nil,   // 退回旧 1×1 白(A/B 诊断)
                      let solidFXSize = Self.solidEffectCanvasSize(layer, weEffects: weEffects) {
                // **带空间特效的纯色 solidlayer**(如 Misty Valley 时钟竖线 Stick V = solidlayer + shimmer 流光):
                // 1×1 白底会把整层塌成单像素 → shimmer 等空间特效(沿层位置移动的流光带)无空间可施展 → 流光不动/不出。
                // 改用**层尺寸**的纯色画布(rgb=color、a=1)当 g_Texture0,特效在其上跑;合成色置白避免二次乘 color 变暗。
                // 对齐 lwe:solidlayer 先把 color 渲到自有 FBO,特效链在该 FBO 内跑。无空间特效的普通 solidlayer 仍走下面 1×1 白快路。
                guard let t = solidColorTexture(width: solidFXSize.0, height: solidFXSize.1,
                                                color: SIMD3(layer.color.x, layer.color.y, layer.color.z)) else {
                    Log.write("scene: solid-fx texture alloc failed for \(layer.name)"); continue
                }
                tex = t
                solidColorBaked = true
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
                let ob = Self.opaqueBounds(decoded); opaqueR = ob.rect; opaqueSolidR = ob.solidFrac  // 不透明内容范围+实心占比
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
                // dataTexture:遮罩是数据贴图(shader 采 .r/.rg 当遮罩值,不走 ConvertTexture0Format)。
                // R8 遮罩(godrays/foliagesway/waterripple_mask)须保留 R 在 R 通道(否则 .r 恒 1 → 特效全屏)。
                guard let blob = source.data(for: p), let dec = TexDecoder.decodeFirstMipWithFlags(blob, dataTexture: true),
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
            var auxResCache: [String: SIMD4<Float>] = [:]  // freeimage 容器≠内容:g_TextureNResolution 头部四元组覆写
            func auxTex(_ ref: String) -> MTLTexture? {
                if let t = auxCache[ref] { return t }
                let blob = source.data(for: "materials/\(ref).tex")
                    ?? source.data(for: ref.hasSuffix(".tex") ? ref : "\(ref).tex")
                    ?? BuiltinAssets.shared.textureData(forReference: ref)
                // dataTexture:辅助槽是流向场/法线/相位等**数据贴图**,RG88 须保留双通道 (R,G),
                // 不能当「亮度+alpha」(否则 waterflow 的垂直 G 分量被丢 → 屋檐水流不流不下落)。
                guard let b = blob, let dec0 = TexDecoder.decodeFirstMipWithFlags(b, dataTexture: true) else {
                    Log.write("scene: aux texture unresolved ref=\(ref) (blob=\(blob != nil))")
                    auditLines.append("⚠️ 层id=\(layer.id) 辅助贴图未解析 ref=\(ref) blob=\(blob != nil)")
                    return nil
                }
                // WP_MASK_INVERT=1 实验:把内嵌图片(enc)辅助遮罩**反相**(M3 假说:WE 条带可见区=剪影之外)。
                var decTex = dec0.tex
                if ProcessInfo.processInfo.environment["WP_MASK_INVERT"] != nil,
                   case .encoded(let edata) = dec0.tex,
                   let inv = Self.invertEncodedRGBA(edata) {
                    decTex = inv
                }
                // 视频辅助贴图(如 x-ray 的 reveal 是 .tex 内嵌 MP4):取首帧作静态采样源。
                // 否则 makeTexture(.video) 退 nil → 该辅助槽落 util/white → x-ray 揭示出白雾(实测 3605892961)。
                // 镜像图层路径(line 892-901)的首帧兜底;全帧 reveal 用首帧即可,1.0 UV 缩放正确。
                if case .video(let mp4) = decTex {
                    guard let frame = VideoFrame.firstFrameRGBA8(mp4) else {
                        Log.write("scene: aux video first-frame failed ref=\(ref)")
                        return nil
                    }
                    decTex = .rgba8(pixels: frame.pixels, width: frame.width, height: frame.height)
                }
                guard let t = makeTexture(decTex, loader: loader) else {
                    Log.write("scene: aux texture upload failed ref=\(ref)")
                    return nil
                }
                let dec = dec0
                auxCache[ref] = t; auxFlagsCache[ref] = dec.flags
                // ⭐freeimage 容器≠内容 → 喂 g_TextureNResolution=(容器,内容):这是 **WE 真机制**(opacity.vert
                // 用 `zw=(u·imgW/texW, v·imgH/texH)` 采样遮罩,见源码)。御剑「影子」遮罩=4096²容器/4096×2296内容,
                // 喂对后 shader 自己把整张遮罩映射到层 region(横向全宽、纵向 v×0.56),条带淡且落角色躯干=对齐 WE 实图。
                // (此前误判:画布对位裁切+反相是非 WE 的猜测,已撤;那套基于错误的"反相"跨端结论。)WP_NO_FIF_RES=1 退回作 A/B。
                if ProcessInfo.processInfo.environment["WP_NO_FIF_RES"] == nil,
                   let info = TexDecoder.headerInfo(b), info.freeImage,
                   (info.texW != info.imgW || info.texH != info.imgH) {
                    auxResCache[ref] = SIMD4(Float(info.texW), Float(info.texH), Float(info.imgW), Float(info.imgH))
                }
                return t
            }
            // ⭐真 WE 实测语义(2026-06-11,跨端帧采集 toggle A/B 逐像素验证):**regionFit composelayer 上的
            // 画布尺寸特效遮罩,WE 按【画布对位 + 反相】采样**——条带可见区 = 角色剪影**之外**(「从身后冒出/
            // 被角色挡住」,用户假设获证)。直采(剪影内)与 freeimage-Resolution quirk 模型均被真值推翻
            // (WE 纯条带段 10/10 落在反相窗口、0/10 在剪影内窗口)。lwe 无此路径(lwe≠真WE 第 4 处)。
            // 实现:解码画布遮罩 → 按层 region 裁剪(=画布对位)→ 反相 → 作为层 [0,1] 遮罩。
            // 作用域极窄:frameBufferInput+regionFit(打雷 pulse=非 regionFit 不动)且遮罩尺寸==画布(±4px)。
            // WP_NO_FBMASK_FIX=1 退回旧直采。
            func composeMaskTex(_ ref: String) -> MTLTexture? {
                // 【默认关】画布对位裁切是非 WE 的猜测(把整张影子裁到 region 当层遮罩)——已被 WE opacity.vert 真机制
                // (freeimage 分辨率喂 g_TextureNResolution 让 shader 算 zw)取代,见上方 auxResCache。WP_FBMASK_CROP=1 才用作 A/B。
                guard ProcessInfo.processInfo.environment["WP_FBMASK_CROP"] != nil,
                      layer.frameBufferInput, layer.regionFit,
                      let sz = layer.sizePx else { return nil }
                let key = "\(ref)#fbinv#\(layer.id)"
                if let t = auxCache[key] { return t }
                let blob = source.data(for: "materials/\(ref).tex")
                    ?? source.data(for: ref.hasSuffix(".tex") ? ref : "\(ref).tex")
                    ?? BuiltinAssets.shared.textureData(forReference: ref)
                guard let b = blob, let dec = TexDecoder.decodeFirstMipWithFlags(b, dataTexture: true) else { return nil }
                var px: [UInt8]; var w = 0; var h = 0
                switch dec.tex {
                case .encoded(let data):
                    guard let r = Self.decodeEncodedRGBA(data) else { return nil }
                    px = r.px; w = r.w; h = r.h
                case .rgba8(let p, let pw, let ph):
                    px = p; w = pw; h = ph
                default: return nil
                }
                guard abs(Float(w) - canvas.x) < 4, abs(Float(h) - canvas.y) < 4 else { return nil }
                // region 矩形(mask 行 0 = 画布顶;layer.originPx 是 y-up)
                let x0 = max(0, Int((layer.originPx.x - sz.x / 2) / canvas.x * Float(w)))
                let x1 = min(w, Int((layer.originPx.x + sz.x / 2) / canvas.x * Float(w)))
                let yTop = canvas.y - (layer.originPx.y + sz.y / 2)
                let y0 = max(0, Int(yTop / canvas.y * Float(h)))
                let y1 = min(h, Int((yTop + sz.y) / canvas.y * Float(h)))
                guard x1 > x0 + 8, y1 > y0 + 8 else { return nil }
                let cw = x1 - x0, chh = y1 - y0
                var out = [UInt8](repeating: 0, count: cw * chh * 4)
                // WE opacity.frag 铁证:`albedo.a *= mask.r`(纯乘、**不反相**)→ 条带显示在遮罩**白处**。
                // 御剑「影子」白在角色 → 条带上身(WE对比图实证:条带在角色躯干、不在龙)。旧硬编码反相=偏离 WE
                // (把条带推到剪影外/龙身上),已撤。WP_FBMASK_INVERT=1 恢复旧反相作 A/B。
                let doInv = ProcessInfo.processInfo.environment["WP_FBMASK_INVERT"] != nil
                for y in 0..<chh {
                    let srcRow = (y0 + y) * w
                    for x in 0..<cw {
                        let s = (srcRow + x0 + x) * 4, d = (y * cw + x) * 4
                        if doInv { out[d] = 255 &- px[s]; out[d+1] = 255 &- px[s+1]; out[d+2] = 255 &- px[s+2] }
                        else { out[d]=px[s]; out[d+1]=px[s+1]; out[d+2]=px[s+2] }
                        out[d+3] = 255
                    }
                }
                // 诊断:WP_DUMP_MASK=1 把裁出的遮罩(反相后)+ 原始裁块(反相前)存 PNG,核对剪影对位/极性。
                if ProcessInfo.processInfo.environment["WP_DUMP_MASK"] != nil {
                    // 全画布遮罩(未裁),看剪影在画布哪
                    saveTexture(makeTexture(.rgba8(pixels: px, width: w, height: h), loader: loader)!, to: "/tmp/mask_\(layer.id)_full.png")
                    var raw = [UInt8](repeating: 0, count: cw * chh * 4)
                    for y in 0..<chh { let sr=(y0+y)*w; for x in 0..<cw { let s=(sr+x0+x)*4, d=(y*cw+x)*4
                        raw[d]=px[s]; raw[d+1]=px[s+1]; raw[d+2]=px[s+2]; raw[d+3]=255 } }
                    saveTexture(makeTexture(.rgba8(pixels: raw, width: cw, height: chh), loader: loader)!, to: "/tmp/mask_\(layer.id)_raw.png")
                    saveTexture(makeTexture(.rgba8(pixels: out, width: cw, height: chh), loader: loader)!, to: "/tmp/mask_\(layer.id)_inv.png")
                    Log.write("WP_DUMP_MASK: layer=\(layer.id) region origin=(\(layer.originPx.x),\(layer.originPx.y)) size=(\(sz.x),\(sz.y)) crop x[\(x0),\(x1)] y[\(y0),\(y1)]")
                }
                guard let t = makeTexture(.rgba8(pixels: out, width: cw, height: chh), loader: loader) else { return nil }
                auxCache[key] = t
                Log.write("scene: composeMask canvas-aligned ref=\(ref) layer=\(layer.id) crop=\(cw)x\(chh) inv=\(doInv)")
                auditLines.append("ℹ️ 层id=\(layer.id) 遮罩\(ref) → 画布对位(WE alpha*=mask 不反相\(doInv ? "/已反相" : "")) 裁\(cw)x\(chh)")
                return t
            }
            let effectAux: [[Int: MTLTexture]] = layer.effects.map { eff in
                var m: [Int: MTLTexture] = [:]
                for (slot, ref) in eff.weAux {
                    if let ct = composeMaskTex(ref) { m[slot] = ct }
                    else if let t = auxTex(ref) { m[slot] = t }
                }
                return m
            }
            let effectAuxFlags: [[Int: TexFlags]] = layer.effects.map { eff in
                var m: [Int: TexFlags] = [:]
                for (slot, ref) in eff.weAux { if let f = auxFlagsCache[ref] ?? nil { m[slot] = f } }
                return m
            }
            let effectAuxRes: [[Int: SIMD4<Float>]] = layer.effects.map { eff in
                var m: [Int: SIMD4<Float>] = [:]
                for (slot, ref) in eff.weAux { if let r = auxResCache[ref] { m[slot] = r } }
                return m
            }

            // 尺寸:文本层若有显式盒子(WE size×scale),屏上大小 = 字形纵横比适配进盒子;
            // 否则(普通图层 / 无 size 的 autosize 文本)= sizePx(或纹理像素)× scale。
            var size: SIMD2<Float>
            var effSize: SIMD2<Float>
            var textBox: SIMD2<Float>? = nil
            var textCenterOffset: SIMD2<Float> = .zero
            // WE 文本 size 字段语义:size 远大于 pointsize = 真文本框(文字适配进盒子);size 远小于
            // pointsize(如歌名 size="2 2" + pointsize=10 + scale=8)= **锚点占位**,WE 忽略它、按 pointsize×scale
            // 渲染(lwe CText 实证 size 不参与渲染、字号=pointsize×scale)。判据:boxSize.y < srcPointSize。
            let srcPt = Float(layer.text?.srcPointSize ?? 32)
            if layer.text?.useScreenPointSize == true {
                // 锚点 size / media 文本(歌名/艺术家):屏上字高 = srcPointSize×scale(WE 真义);宽按纹理纵横比。
                // 纹理按 renderPt(=desc.pointSize,高分辨率)渲染,故屏上比例 = srcPointSize/renderPt。
                let renderPt = Float(layer.text?.pointSize ?? 32)
                let scaleY = renderPt > 0 ? srcPt / renderPt : 1
                size = SIMD2(Float(tex.width), Float(tex.height))
                effSize = SIMD2(Float(tex.width) * scaleY * layer.scale.x,
                                Float(tex.height) * scaleY * layer.scale.y)
            } else if let box = layer.text?.boxSizePx {
                // 真文本框 = size×scale(画布单位)。文本按字形纵横比适配进盒子(见 textQuad)。
                let scaledBox = SIMD2(box.x * layer.scale.x, box.y * layer.scale.y)
                let q = textQuad(texW: Float(tex.width), texH: Float(tex.height), box: scaledBox,
                                 hAlign: layer.text?.align ?? "center",
                                 vAlign: layer.text?.verticalAlign ?? "center")
                size = scaledBox          // baseSize 记盒子(scaleScript 不作用于文本,无碍)
                effSize = q.size
                textBox = scaledBox
                textCenterOffset = q.centerOffset
            } else {
                // 无显式 size:autosize 取纹理像素 × scale(旧行为;无 size 的静态文本/问候/非文本层)。
                size = layer.sizePx ?? SIMD2(Float(tex.width), Float(tex.height))
                effSize = SIMD2(size.x * layer.scale.x, size.y * layer.scale.y)
            }
            // composelayer region(音频条):WE 常给负 scale.x 做水平翻转(镜像)。但 frameBufferInput 的 region
            // footprint 是「在场景里采样哪块」的采样区,负宽 → footprint quad 翻转/绕序反 → 采样越界,整层渲成
            // **白方块**(黑猫 Bar2/Bar3 让 composelayer 都建成后暴露)。翻转对 region 采样无意义,取 abs 让
            // footprint/mvp 几何为正。WP_NO_COMPOSE_ABS=1 退回(A/B)。
            if layer.frameBufferInput, (effSize.x < 0 || effSize.y < 0),
               ProcessInfo.processInfo.environment["WP_NO_COMPOSE_ABS"] == nil {
                effSize = SIMD2(abs(effSize.x), abs(effSize.y))
            }
            let layerCenter = SIMD2(layer.originPx.x + textCenterOffset.x,
                                    layer.originPx.y + textCenterOffset.y)
            // 部件间 attachment(凯尔希:眼睛/眼睑/耳朵/刘海/长发/衣袖等 ~19 部件 → 挂主体/长发3 的具名挂点)。
            // **通用化(2026-06,本次)**:凡「有 attachment 串 + 父对象有 puppet + 父 puppet 有该具名挂点」都处理,
            //   不再要求子部件**自己**有 puppet。两条统一规则,走同一套挂点世界变换(attachmentWorld)+ 父渲染变换:
            //   ① 子有自身 puppet(眼睛/眼睑):走蒙皮路径——把子蒙皮顶点搬进**父 mesh-local 空间**(按父 size 归一),
            //      用父的 origin/scale/angle/size 渲(顶点几何由 mesh 决定其在挂点骨上的相对位置)。【保持不变,正确锚点】
            //   ② 子是纯 image quad(刘海/长发/耳朵/衣物,占 17/19):无 mesh 几何可定位,故用 scene **局部 origin**
            //      作「相对挂点的偏移」(父 mesh-local 像素)。通用刚性 quad 公式(离线 + dome 一致性验证):
            //        attachPos      = 父 puppet 挂点的 mesh-local 平移(attachmentWorld 第 4 列 .xy)
            //        ploc           = attachPos + attachLocalOrigin          (父 mesh-local 像素)
            //        quadCenterWorld= parentOrigin + R(parentAngle)·(ploc · parentScale)
            //      quad 用**自身** size×scale 几何,角度 = parentAngle + 自身角(随父转)。
            //   lwe 完全不读 object attachment / 不读 MDAT(grep 0 命中,ObjectParser/ModelParser/CImage 均无)→ lwe 散架;
            //   本特性是补真 WE 语义,已授权超出 lwe。WP_NO_ATTACH=1 全退基线;父 puppet 不可解/无该挂点 → 也退基线。
            let attachEnabled = ProcessInfo.processInfo.environment["WP_NO_ATTACH"] == nil
            var attachWorld: simd_float4x4? = nil       // 父挂点世界变换(父 mesh-local 空间;平移=挂点)
            var attachParentMesh: PuppetMesh? = nil     // 父 puppet mesh(供 update() 每帧解析动画后挂点)
            if attachEnabled, ProcessInfo.processInfo.environment["WP_NOPUPPET"] == nil,
               let attName = layer.attachment, let pPup = layer.parentPuppet,
               let pSize = layer.parentPuppetSize,
               let pBlob = source.data(for: pPup),
               let pMesh = PuppetMesh.parse(pBlob, size: pSize),
               let aw = pMesh.attachmentWorld(attName) {
                attachWorld = aw
                attachParentMesh = pMesh
            }
            var attachEffSize = effSize, attachAngle = layer.anglesDeg.z, modelCenter = layerCenter
            if let aw = attachWorld {
                // **统一锚点(2026-06-07 修复)**:quad 子部件(头发/衣物/耳朵)与 puppet 子部件(眼睛/眼睑)
                // 走**同一个挂点公式**,只是几何源不同(quad=平面单位 quad;puppet=自身 mesh 三角网格)。
                //   离线复核(凯尔希,/tmp/diag_kalsey.py):头部挂点 attachWorld 是父 mesh-local 纯平移(734,856);
                //   子的渲染中心 = 父 origin + R(父角)·((attachPos + 子局部 origin)·父 scale)。
                //   子用**自身** size×父 scale 作几何大小(不是父 size)。puppet 子的 mesh 顶点在**自身**单位空间
                //   (pos/childSize,偏心 UV 岛=眼睛在 box 外的偏移)自带把眼形拉到脸上的相对位移 —— 形状由 mesh 定,
                //   位置(box 中心)由此挂点公式定。**旧 puppet 路径**用 parentRenderOrigin + 父 size + 根骨对齐挂点
                //   (attachedUnitVerts),与 quad 路径锚点不一致 → 眼睛/眼睑偏出脸(离线落点偏差 ~0.15 画布宽);
                //   头发/衣服(quad)用挂点公式本就对,故统一到挂点公式后两者都对、头发不动。
                let attachPos = SIMD2(aw.columns.3.x, aw.columns.3.y)        // 挂点 mesh-local 平移
                let ploc = SIMD2(attachPos.x + layer.attachLocalOrigin.x,
                                 attachPos.y + layer.attachLocalOrigin.y)    // 父 mesh-local 像素
                let ps = layer.parentRenderScale
                let scaled = SIMD2(ploc.x * ps.x, ploc.y * ps.y)
                let rotated = rotateVec2(scaled, layer.parentRenderAngle)
                modelCenter = SIMD2(layer.parentRenderOrigin.x + rotated.x,
                                    layer.parentRenderOrigin.y + rotated.y)
                attachEffSize = effSize                                       // 子自身 size×scale(quad 与 puppet 同)
                attachAngle = layer.parentRenderAngle + layer.anglesDeg.z     // 随父转 + 自身角
            }
            let model = matModel(centerPx: modelCenter,
                                 sizePx: attachEffSize, angleDegZ: attachAngle)
            // 所有图层特效都按**真 WE 转译 shader 逐个**跑(runLayerEffects),不再有「全覆盖才用 WE
            // 否则回退手写近似」的 all-or-nothing。manifest 里有且非 denylist 的 effect 跑真 shader,
            // 其余(如未转译的自定义)在链里被跳过(passthrough)。useWE = 该层有任一可跑的真特效。
            let effs = Array(layer.effects.prefix(kMaxLayerEffects))
            let effMasks = Array(effectMasks.prefix(kMaxLayerEffects))
            let effAux = Array(effectAux.prefix(kMaxLayerEffects))
            let effMaskFlags = Array(effectMaskFlags.prefix(kMaxLayerEffects))
            let effAuxFlags = Array(effectAuxFlags.prefix(kMaxLayerEffects))
            let effAuxRes = Array(effectAuxRes.prefix(kMaxLayerEffects))
            let hasRunnableWE = effs.contains {
                !Self.weDenied.contains($0.weName) && (weEffects?.has($0.weName) ?? false)
            }
            // 构建期特效诊断:带特效的层各打一行(场景加载只走一次,无刷屏)。没出现在这里的 pkg 特效宿主
            // = LayerDesc 没建成 GPULayer(父链隐藏/贴图失败等),与 FXDIAG(运行期)互补成完整链路日志。
            if !layer.effects.isEmpty {
                let detail = layer.effects.map { "\($0.weName):\((weEffects?.has($0.weName) ?? false) ? "有" : "无manifest")" }
                Log.write("FXBUILD layer=\(layer.id)(\(layer.name)) effs=\(layer.effects.count)→GPU\(effs.count) runnable=\(hasRunnableWE) [\(detail.joined(separator: ", "))]")
            }
            // 对象级 brightness(WE g_Brightness,ObjectParser.cpp:293,默认 1)。WE 在材质 pass 里
            // 用 g_Brightness 乘 albedo.rgb;我们所有层最终都走 scene_fragment 的 tex×in.color,
            // 故把 brightness 折进 color.rgb(只乘 rgb 不动 alpha)即等价施加一次。
            let br = layer.brightness
            // 带空间特效的 solidlayer:color 已烘进纹理 rgb → 合成色 rgb 置白(只保留 alpha + brightness),
            // 否则会与纹理里的 color 二次相乘 → 变暗(0.655² ≈ 0.43)。
            let litColor = solidColorBaked
                ? SIMD4(br, br, br, layer.color.w)
                : (br == 1 ? layer.color
                   : SIMD4(layer.color.x * br, layer.color.y * br, layer.color.z * br, layer.color.w))
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
            var puppetAnimLayers: [(animId: Int, rate: Float, additive: Bool)] = []
            var eyeCull: MTLCullMode = .none   // 眼睛层背面剔除朝向(非眼=.none 保持零回归)
            var eyeUse3D = false               // 眼睛层用完整 3D 蒙皮(主 puppet=false 平面蒙皮零回归)
            if ProcessInfo.processInfo.environment["WP_NOPUPPET"] == nil,
               let pup = layer.puppet, let blob = source.data(for: pup),
               let mesh = PuppetMesh.parse(blob, size: size), mesh.indices.count >= 3,
               size.x >= 1, size.y >= 1 {
                // 部件间 attachment(2026-06-07 统一锚点修复):**始终用自身 bindVerts(pos/childSize 单位空间)**。
                //   位置由上方统一挂点公式定(modelCenter/attachEffSize/attachAngle 已切到「挂点 + 子局部 origin」、
                //   用子自身 size×父 scale);mesh 顶点只负责**形状 + 自身偏心**(眼睛 UV 岛 rawPos 在 box 外的位移,
                //   把眼形从 box 中心拉到脸上的正确点)。
                //   ⚠ 旧做法 attachedUnitVerts(根骨对齐挂点 + 按父 size 归一)把锚点改成「子 root 骨对齐挂点」,
                //   与 quad 子部件(头发/衣物)的挂点不一致 → 眼睛/眼睑偏出脸。已弃(离线 /tmp/diag_kalsey.py 验证:
                //   统一公式下眼中心落到 screen-norm(0.61, top0.32)=脸上,眼睑(0.67,0.27)贴眼上沿)。
                let bind = mesh.bindVerts
                if attachWorld != nil {
                    Log.write("puppet-attach(unified-anchor): \(layer.name) -> \(layer.parentPuppet ?? "?") @\(layer.attachment ?? "?") (\(bind.count/4) verts, own-unit-space)")
                }
                // shared 存储:hasSkin 时 update() 每帧就地写入蒙皮后顶点(摇摆相邻帧近一致,单缓冲竞态不可见)。
                puppetVB = device.makeBuffer(bytes: bind, length: MemoryLayout<Float>.stride * bind.count, options: .storageModeShared)
                puppetIB = device.makeBuffer(bytes: mesh.indices, length: MemoryLayout<UInt16>.stride * mesh.indices.count)
                puppetCount = mesh.indices.count
                // 骨骼动画:取首个 visible 的 animationlayer 的 animation id + rate(对应 MDLA 动画 id)。
                // ② 眨眼/动耳(2026-06-07b):attach 层**也启用**自身每帧蒙皮。安全前提(已验证):skin() 与
                //   bindVerts 走**同一个** unitVerts(pos/childSize)归一,t=0 时 skinned==rawPos → skin()==bindVerts;
                //   blink/动耳 anim 只在该统一空间内**就地形变** mesh 顶点(眼睛组合 anim176:bones5-12 链下移,
                //   335/372 顶点动 ≤70px=眼睑闭合;左耳朵1 anim472:耳尖摆 H 568→407)。锚点(box 中心)由①的挂点
                //   公式独立决定(matModel center),不受 mesh 顶点形变影响 → 自身形变(②)与锚点跟随(①)正交,
                //   不会把眼睛拉散/脱位。旧关闭原因(attachedUnitVerts 按父 size 归一)随①统一锚点废弃已不存在。
                //   WP_NO_ATTACH_BLINK=1 可临时退回静态 bind(A/B 对比眨眼)。
                let blinkOn = ProcessInfo.processInfo.environment["WP_NO_ATTACH_BLINK"] == nil
                if mesh.hasSkin,
                   let al = layer.animationLayers.first(where: { $0.visible }) ?? layer.animationLayers.first {
                    // ⭐**眼睛眨眼/眼球转动 = 完整 3D 蒙皮**(2026-06-14c,替代旧「眼睛一律静态 bind」绕过):
                    //   眼睛是「离体 UV 岛」(眼白顶点在 mesh box 外、拉到脸上)。蒙皮数学本身正确(invBind/权重/
                    //   归一已验证 frame0 偏差=0)。旧「眼睛一律静态 bind」绕过让眼睛恒睁(不眨)。
                    //   真因 = 平面 skinner 的 trs 只构 rz、丢 rx/ry/tz,而凯尔希「眼睛」anim1405 bone2 的眨眼是
                    //   **出平面**变换:rx→π/2(虹膜绕 X 翻 90°)+ tz→−61(后退)。丢掉 rx → 顶点 x/y 根本不动 →
                    //   眼睛永远睁着。补完整 3D trs3D 后,虹膜区顶点随 rx/tz 把眼睛**收缩成一条闭合的眼线**
                    //   (隔离渲染像素实测:眨眼峰值眼面积 1538→730 px,睁→闭→睁干净过渡,无翻面色块)。
                    //   ⚠ 背面剔除经实测**不需要也不该用**:凯尔希眼三角屏幕绕序恒为单朝向、眨眼时不翻面 →
                    //     .back 会把睁眼整片剔掉(全程无眼)、.front 不剔任何(=.none);3D 蒙皮自身已闭合眼睛,
                    //     故默认 cull=.none。WP_EYE_CULL=front/back 仅留作 A/B 诊断。
                    //   m眼睛 anim1038 是平面挤眼(sy→0.77,rx=ry=0)→ trs3D 退化为 trs,同样正确。
                    //   主 puppet(龙/刀/朱鹤/头发/衣物,非眼)走平面蒙皮(use3D=false,丢 rx/ry)=旧行为零回归
                    //   (朱鹤 anim458 bone2 rx→π/2 在 2D 无深度下出平面旋转会折叠成色块,故主 puppet 不上 3D)。
                    //   WP_NO_EYE_SKIN=1 退回旧静态 bind 绕过(A/B 对比)。
                    //
                    // ⭐**use3D 改按动画实际是否出平面判定(2026-06-14d,逐部件 pkg 数据驱动,替代旧「眼名即 3D」)**:
                    //   逐部件扒 pkg(/tmp/anim_tracks.py)实证两类眼部动画:
                    //     ① 出平面折叠(需 trs3D):凯尔希×Mon3tr 3462491575「眼睛」anim1405 bone2 rx→π/2 + tz→−61
                    //        —— 虹膜绕 X 翻转后退,正交下 x/y 收缩闭眼。平面 trs 丢 rx/tz → 眼恒睁。
                    //     ② 平面眨眼(只 tx/ty/rz/scale,rx=ry=0):凯尔希×Mon3tr「m眼睛」anim1038(sy→0.77);
                    //        Esperanta 3719111841「右眼上眼睑」anim164(ty 平移盖)/「眼睛组合」anim176(14 骨 sy→0.18 挤眼)。
                    //        这些**眼睑/挤眼是平面动画**,该走 flat trs;trs3D 在 rx=ry=0 时逐元素退化==trs(隔离渲染
                    //        像素 diff=0 实证),故走 isAnimationPlanar 门控:平面 → use3D=false(明确表达「眼睑不是 3D 折叠」)。
                    //   旧「眼名即 use3D=true」对平面眼睑虽数学等价(无回归),但语义错误(把眼睑当 3D 折叠对待);
                    //   现按 anim 真实轨道判定,只有真出平面(rx/ry≠0)才上 trs3D,与各部件 pkg 数据一一对应。
                    //   WP_EYE_FLAT=1 强制全眼部平面(诊断);WP_EYE_3D=1 强制全眼部 3D(诊断)。
                    let nm = layer.name.lowercased()
                    let isEye = layer.name.contains("眼") || nm.contains("eye")
                    let eyeSkinOn = ProcessInfo.processInfo.environment["WP_NO_EYE_SKIN"] == nil
                    let attachOK = blinkOn && (isEye ? eyeSkinOn : true)
                    if attachOK {
                        puppetMesh = mesh; puppetAnimId = al.animation; puppetAnimRate = al.rate
                        if isEye {
                            // 数据驱动:动画含出平面 rx/ry → trs3D 闭合;纯平面眨眼/挤眼 → flat trs(眼睑)。
                            let outOfPlane = !mesh.isAnimationPlanar(al.animation)
                            let env = ProcessInfo.processInfo.environment
                            if env["WP_EYE_FLAT"] != nil { eyeUse3D = false }
                            else if env["WP_EYE_3D"] != nil { eyeUse3D = true }
                            else { eyeUse3D = outOfPlane }
                            switch env["WP_EYE_CULL"] {
                            case "back":  eyeCull = .back
                            case "front": eyeCull = .front
                            default:      eyeCull = .none   // 默认不剔除;3D 蒙皮自身闭合眼睛(平面眼睑亦无翻面)
                            }
                            Log.write("puppet: \(layer.name) 眼睛部件 → \(eyeUse3D ? "3D 蒙皮(出平面 rx/ry)" : "平面蒙皮(眼睑/挤眼)") anim\(al.animation)(cull=\(eyeCull == .back ? "back" : eyeCull == .front ? "front" : "none"))")
                        }
                    } else if isEye {
                        Log.write("puppet: \(layer.name) 眼睛部件 → WP_NO_EYE_SKIN 退回静态 bind")
                    }
                }
                // WE 真义:对象的**全部可见** animationlayers 叠加合成(additive 层追加位移)。
                // 御剑龙「动画 2」(additive,含下压/飞行)曾被只取首层的旧逻辑丢掉 → 龙恒停 bind 高位(偏上真因)。
                // 单层对象走 skinLayers 与旧 skin() 数学完全一致(合成=纯 base),零回归。
                if puppetMesh != nil {
                    var ls = layer.animationLayers.filter { $0.visible }
                    if ls.isEmpty, let al = layer.animationLayers.first { ls = [al] }
                    puppetAnimLayers = ls.map { (animId: $0.animation, rate: $0.rate, additive: $0.additive) }
                }
                Log.write("puppet: \(layer.name) mesh \(bind.count/4) verts, \(puppetCount) idx, skin=\(puppetMesh != nil ? "anim\(puppetAnimId)+\(puppetAnimLayers.count)layers" : "static")")
                auditLines.append("ℹ️ 层id=\(layer.id) \(layer.name) puppet \(bind.count/4)顶点 skin=\(puppetMesh != nil ? "anim\(puppetAnimId)+\(puppetAnimLayers.count)层" : "static(版本不符或无动画)")")
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
                rawSizePx: size,   // 未缩放(lwe m_size);composelayer footprint FBO 用它,不用 effSize(=size×scale)
                opaqueRect: opaqueR,
                opaqueSolid: opaqueSolidR,
                video: videoTex,
                effects: effs,
                text: textState,
                textBox: textBox,
                textCenterOffset: textCenterOffset,
                audioBars: layer.audioBars,
                effectMask: effectMask,
                effectMasks: effMasks,
                effectAux: effAux,
                effectAuxRes: effAuxRes,
                texFlags: texFlags,
                effectMaskFlags: effMaskFlags,
                effectAuxFlags: effAuxFlags,
                useWE: hasRunnableWE,
                frameBufferInput: layer.frameBufferInput,
                abovePost: layer.abovePost,
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
            result[result.count - 1].name = layer.name   // 跨层写回:控制器脚本 getLayer(name) 命中目标层
            result[result.count - 1].sceneObjIndex = layer.sceneObjIndex   // 场景对象序(粒子插画锚点)
            result[result.count - 1].puppetAnimLayers = puppetAnimLayers   // 全部可见 animationlayers(additive 叠加)
            result[result.count - 1].puppetCull = eyeCull   // 眼睛层背面剔除(转背虹膜剔掉=闭眼);非眼=.none
            result[result.count - 1].puppetUse3D = eyeUse3D  // 眼睛层完整 3D 蒙皮;主 puppet 平面(零回归)
            result[result.count - 1].audioVizSelfAlpha = audioVizSelfAlpha   // 音频可视化层:合成保留 effectedTexture 逐像素 alpha
            result[result.count - 1].isAttached = (attachWorld != nil)   // attach 成功(蒙皮或刚性 quad 均含):baseModel 已按挂点搭好,update 跳过 origin/scale/angle 覆写
            // 动态挂点跟随:父 puppet 有骨骼动画(主体 anim206 呼吸)时,记下重算所需数据,update() 每帧把
            //   attach 部件锚点从 bind 挂点更新到**动画后**挂点(增量),让眼/睑/耳跟父头骨一起动、不脱离脸。
            //   退化兜底:动画首帧未必 == bind,故 update() 用「animAttachPos(t) − animAttachPos(0)」的增量
            //   叠加到静态 baseModel 锚点 → t=0 增量=0 → 严格等于 build 的静态结果(零回归)。
            //   WP_NO_ATTACH_ANIM=1 关闭动态跟随(退回静态挂点,A/B 对比用)。
            if attachWorld != nil, let pMesh = attachParentMesh, let pAnim = layer.parentAnimId,
               pMesh.hasSkin, ProcessInfo.processInfo.environment["WP_NO_ATTACH_ANIM"] == nil,
               let aw0 = pMesh.animatedAttachmentWorld(layer.attachment ?? "", time: 0, rate: layer.parentAnimRate, animId: pAnim) {
                let last = result.count - 1
                result[last].attachParentMesh = pMesh
                result[last].attachName = layer.attachment ?? ""
                result[last].attachParentAnimId = pAnim
                result[last].attachParentAnimRate = layer.parentAnimRate
                result[last].attachParentScale = layer.parentRenderScale
                result[last].attachParentAngle = layer.parentRenderAngle
                result[last].attachStaticCenter = modelCenter
                result[last].attachStaticAngle = attachAngle
                result[last].attachEffSize = attachEffSize
                result[last].attachBindPos = SIMD2(aw0.columns.3.x, aw0.columns.3.y)   // 旧枢轴式 t=0 平移(回退用)
                // 子实际锚点(父 mesh-local)= 挂点枢轴平移 + 子局部 origin(与上方渲染公式 ploc 同)。
                let anchorLocal = SIMD2(aw0.columns.3.x + layer.attachLocalOrigin.x,
                                        aw0.columns.3.y + layer.attachLocalOrigin.y)
                result[last].attachAnchorLocal = anchorLocal
                // 该锚点经骨蒙皮(t=0)后的位置 + 该骨蒙皮 t=0 的 z 角作增量基准(严格归零;与每帧 skinT 同矩阵)。
                if let skin0 = pMesh.attachBoneSkinMatrix(layer.attachment ?? "", time: 0, rate: layer.parentAnimRate, animId: pAnim) {
                    let a0 = skin0 * SIMD4<Float>(anchorLocal.x, anchorLocal.y, 0, 1)
                    result[last].attachAnchorBind = SIMD2(a0.x, a0.y)
                    result[last].attachBindAngle = zAngle(skin0)
                } else {
                    result[last].attachAnchorBind = anchorLocal
                    result[last].attachBindAngle = zAngle(aw0)
                }
                Log.write("attach-anim-follow: \(layer.name) @\(layer.attachment ?? "?") parentAnim=\(pAnim) rate=\(layer.parentAnimRate) anchorLocal=(\(Int(anchorLocal.x)),\(Int(anchorLocal.y)))")
            }
            // 缺口B/D:visible/alpha/color 脚本 + 初始显隐(静态值作脚本失败回退)。
            result[result.count - 1].visible = layer.visible
            result[result.count - 1].visibleScript = layer.visibleScript
            result[result.count - 1].alphaScript = layer.alphaScript
            result[result.count - 1].colorScript = layer.colorScript
            // 运行时动态建层脚本(音频条 bar 模板):记下脚本 + 单根 bar 基准尺寸。引擎每帧 runDynamicBars
            // 读回各 bar 变换 → 多实例渲染本层贴图(见 update/encode 的 instancedBars 路径)。需音频捕获。
            if let ibs = layer.instancedBarsScript {
                let last = result.count - 1
                result[last].instancedBarsScript = ibs
                result[last].instancedBarBaseSize = layer.instancedBarBaseSize
                if ibs.usesAudio { AudioCapture.shared.acquire(); usesAudio = true }
            }
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
                result[last].cropShiftPx = layer.cropShiftPx   // 关键帧 origin 重算后要再加 cropoffset 位移
            }
            // 对象 alpha 关键帧(开场动画黑层淡出):独立拷贝(可与 origin/angle 关键帧无关,如纯 alpha 淡出层)。
            result[result.count - 1].alphaKeyAnim = layer.alphaKeyAnim
        }
        layers = result
        // 3D 场景:per-layer 2D 脚本各自独立 context、没有 shared(读 shared.sun_D_real/dock 坐标会抛错→文字空/位置堆原点)。
        // 把**宿主**(单-context 跑了全部脚本+Main模拟,shared 含324键)算出的 shared 快照注入每层全部脚本 →
        // update() 每帧跑这些脚本时就能算出正确文字 + 位置(dock 屏幕坐标 / 标签 3D 坐标)。
        if has3DScene, let rt = scene3DRuntime {
            let snap = rt.sharedJSON()
            if ProcessInfo.processInfo.environment["WP_3D_HUD_LOG"] != nil {
                Log.write("3D inject: snapJSON=\(snap.count) chars; textLayers=\(layers.filter { if case .script = $0.text?.desc.kind { return true }; return false }.count)")
            }
            for i in layers.indices {
                layers[i].scaleScript?.injectShared(snap)
                layers[i].originScript?.injectShared(snap)
                layers[i].angleScript?.injectShared(snap)
                layers[i].visibleScript?.injectShared(snap)
                layers[i].alphaScript?.injectShared(snap)
                layers[i].colorScript?.injectShared(snap)
                if let t = layers[i].text, case .script(let s) = t.desc.kind { s.injectShared(snap) }
            }
        }
        compositeFramesRendered = 0   // 新场景:合成层帧计数归零(重新渲满 compositeMaxFrames 帧)
        fxDiagLogged.removeAll()      // 新场景:特效链诊断重打一遍
        self.proj = proj
        // 相机运镜:存基投影 + 运镜数据。无运镜对象(绝大多数)→ cameraAnim=nil → proj 恒 = baseProj(零回归)。
        self.baseProj = proj
        self.cameraAnim = document.cameraAnim
        self.hasCameraAnim = (document.cameraAnim?.hasAnimation ?? false)
            && ProcessInfo.processInfo.environment["WP_NO_CAMERA_ANIM"] == nil
        if hasCameraAnim, let ca = document.cameraAnim {
            Log.write("scene: camera-path anim ENABLED (origin=\(ca.origin != nil) zoom=\(ca.zoom != nil) " +
                      "len=\(ca.lengthFrames)f originRest=\(ca.originAtRest) zoomRest=\(ca.zoomAtRest))")
        }
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
        hasInstancedBars = result.contains { $0.instancedBarsScript != nil }
        // 关键帧时间线动画(开场动画黑层 alpha 1→0 淡出 / 对象 origin/angle 摆动):是「持续动画内容」,
        // 否则纯关键帧场景被当静态图 → drawOnce 只画 t=0 一帧 → 开场永远卡 frame0(黑层不淡出)。
        hasKeyframeAnim = result.contains { $0.alphaKeyAnim != nil || $0.originKeyAnim != nil || $0.angleKeyAnim != nil }
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
        // 后处理之上的图层(时钟/日期/UI 文本等):postChain 跑完后再叠,不被后处理染暗(WE 语义)。
        //   SceneModel 已按 layers[] 末尾连续区间打了 abovePost 标记(跳过解码失败层后引擎序仍保连续)→ 取首个 abovePost 层
        //   作起点。仅当后处理链真有效(postChain 非空)才启用;逃生开关 WP_NO_ABOVEPOST=1 退回旧整帧后处理。
        let abovePostEnabled = ProcessInfo.processInfo.environment["WP_NO_ABOVEPOST"] == nil && !postChain.isEmpty
        abovePostStart = (abovePostEnabled ? layers.firstIndex(where: { $0.abovePost }) : nil) ?? Int.max
        Log.write("scene: postChain = [\(postChain.map { $0.weName }.joined(separator: ", "))] (from \(document.postChain.count) declared), abovePostStart=\(abovePostStart == Int.max ? -1 : abovePostStart)/\(layers.count)")

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
        // 音频反应脚本(调 registerAudioBuffers/读 __audio):origin/scale/angle 脚本任一用音频 → 也要采集 + 每帧喂频谱。
        hasAudioReactiveScript = result.contains {
            ($0.scaleScript?.usesAudio ?? false) || ($0.originScript?.usesAudio ?? false) || ($0.angleScript?.usesAudio ?? false)
            || ($0.visibleScript?.usesAudio ?? false) || ($0.alphaScript?.usesAudio ?? false) || ($0.colorScript?.usesAudio ?? false)
            || ($0.instancedBarsScript?.usesAudio ?? false)   // 音频条 bar 模板脚本读 __audio
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
            if rippleSim == nil { rippleSim = CursorRippleSim(device: device, sampler: sampler, quad: quadBuffer, aspect: canvas.y > 0 ? canvas.x / canvas.y : 1) }
            Log.write("cursorripple: 折射作用于 projectlayer 下方 \(cursorRippleCutoff) 层(layers[0..<\(cursorRippleCutoff)]),上方层不折射")
            rippleSim?.rippleStrength = document.rippleParams.x
            rippleSim?.rippleScale = document.rippleParams.y
            rippleSim?.rippleSpeed = document.rippleParams.z
            rippleSim?.rippleDecay = document.rippleParams.w
            // 碰撞遮罩(限定力场在水面):从壁纸源解码绑到 sim。无则力场全屏 → 鼠标划过草地也起波。
            // dataTexture:碰撞遮罩是数据贴图(sim 采 .r 当掩码),R8 须保留 R 在 R 通道(否则全屏起波)。
            if let mp = document.rippleMaskPath, let blob = source.data(for: mp),
               let dec = TexDecoder.decodeFirstMipWithFlags(blob, dataTexture: true)?.tex {
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
            sim.desc.canvasSize = canvas   // flags&4 透视粒子换算屏幕居中坐标用(见 ParticleSystem.instances)
            // 严格按 pkg:只有 starttime>0 才「跳进模拟」(雪15/雾2/雨1);starttime==0 的系统 WE 就是从空
            // 开始发射(Postscript 候鸟流开屏第一波从右侧飞入)。曾自创「全员预热 max(2,lifetimeMax) 到稳态
            // 避免开场空屏」→ 开屏时鸟第一波已飞完/将死,十几秒没鸟,被用户指出"飞行不对";WE 的开场
            // 建立过程本就是真实行为。WP_BLANKET_WARMUP=1 退回旧全员预热(A/B)。
            if ProcessInfo.processInfo.environment["WP_BLANKET_WARMUP"] != nil {
                sim.warmup(seconds: max(max(2, em.lifetimeMax), em.startTime))
            } else {
                sim.warmup(seconds: em.startTime)
            }
            particleGroups.append(ParticleGroup(sim: sim, texture: tex, additive: em.blend == .additive,
                                                isRefract: em.isRefract, isRope: em.isRope, normalTexture: normalTex,
                                                aboveBloom: em.aboveBloom, parallaxDepth: em.parallaxDepth))
            // 场景序插画锚点 = 首个场景序排在该粒子之后的图层下标(layers 保持 objects 升序;
            // dependencies 拓扑重排的 2 张壁纸亦无实际位移)。无 → layers.count(全场顶层)。
            particleGroups[particleGroups.count - 1].anchorLayerIndex =
                layers.firstIndex(where: { $0.sceneObjIndex > em.sceneObjIndex }) ?? layers.count
            particleGroups[particleGroups.count - 1].parentObjId = em.parentObjId   // scene parent id(child→FBO 判定用)
        }
        // parent→child composelayer FBO 关联(真 WE,lwe 未实现;见 useComposeChildFBO 注释):
        // 若某粒子组的 scene parent 指向一个 frameBufferInput composelayer,则把它绑到该层 → 渲进该层的
        // child FBO(透明底)而非主场景。作用域极窄:只对「有 child 粒子对象的 composelayer」启用,
        // 其他 composelayer 壁纸(打雷 pulse / 音频条 regionFit,无 child 粒子)完全不受影响、零回归。
        if useComposeChildFBO {
            for (gi, g) in particleGroups.enumerated() {
                guard let pid = g.parentObjId,
                      let L = layers.firstIndex(where: { $0.id == pid && $0.frameBufferInput }) else { continue }
                g.parentComposeLayerIndex = L
                layers[L].childParticleGroupIndices.append(gi)
                hasComposeChildFBO = true
                // 矩阵渲进 1322 的 child FBO,**只用 opacity 的 MASK 把它裁到龙翅区(限制范围),不应用 tint**:
                // 1322 的 tint(青 0.584/0.921/1.0 加法)在真 WE 里作用于「下方场景」产生青色辉光,**不染矩阵**;
                // 误把 tint 加在矩阵上 → 绿矩阵被染青(被用户指出「没达到 WE 效果」,WE 矩阵是纯绿)。故剔除该层
                // 色调 tint,保留 opacity(MASK 限制)→ 矩阵=绿色 + 限制在龙翅区 = WE 真效果。WP_MATRIX_KEEP_TINT 退回。
                // ⭐**默认保留 tint**(2026-06-14 订正):WE 矩阵的「淡」正来自 1322 tint(BLENDMODE31 加法青色
                //   0.584/0.921/1.0)给纯绿矩阵加一层青 → 淡青绿(用户「WE 更淡」)。上轮误删 tint → 饱和深绿。
                //   child FBO 只含矩阵(透明底),tint 只染矩阵字形像素、空像素 alpha=0 经 opacity-mask 仍透明 →
                //   **不会染龙身/角色**(头身分离顾虑在 child-FBO 架构下不成立)。WP_MATRIX_REMOVE_TINT=1 才删(A/B)。
                if ProcessInfo.processInfo.environment["WP_MATRIX_REMOVE_TINT"] != nil,
                   let ti = layers[L].effects.firstIndex(where: { $0.weName == "tint" }) {
                    // 必须同步移除**所有与 effects 对齐的并行数组**同下标项(effectMasks/effectAux/effectAuxRes/
                    // effectMaskFlags/effectAuxFlags),否则 opacity 会错位拿到 tint 的遮罩槽 → MASK 限制失效(全宽)。
                    layers[L].effects.remove(at: ti)
                    if ti < layers[L].effectMasks.count { layers[L].effectMasks.remove(at: ti) }
                    if ti < layers[L].effectAux.count { layers[L].effectAux.remove(at: ti) }
                    if ti < layers[L].effectAuxRes.count { layers[L].effectAuxRes.remove(at: ti) }
                    if ti < layers[L].effectMaskFlags.count { layers[L].effectMaskFlags.remove(at: ti) }
                    if ti < layers[L].effectAuxFlags.count { layers[L].effectAuxFlags.remove(at: ti) }
                    Log.write("composeChildFBO: 剔除 composelayer \(pid) 的 tint[idx\(ti)]+对齐遮罩(矩阵保持绿色,只留 opacity-MASK 限制)")
                }
                Log.write("composeChildFBO: particle group \(gi) (parent=\(pid)) → composelayer id=\(pid) layerIndex=\(L) (child FBO, 不进主场景)")
            }
        }
        // 跨层写回(applyUserProperties / Dock 显隐):把含 getLayer 的**对象级 visibleScript**(控制器脚本)
        //   收集起来,给每个安装真实层注册表(setSceneLayers),令其 `thisScene.getLayer(name).visible/alpha=…`
        //   命中记脏层;每帧 runBool 跑完后 readLayerWrites 回灌目标层(见 update())。土星 Dock 主控脚本据
        //   scriptProperties.enableDock(已链接用户属性 'dock')每帧写各图标层 alpha/visible —— 用户关任务栏
        //   (dock=0)→ enableDock=false → 图标 alpha→0、visible=false。配套**首帧**派发 applyUserProperties:
        //   把**与 pkg 默认不同**的用户属性名告知脚本,触发其 reinitializeCurrentIcons/hideInactiveIcons 立即重置。
        //   仅含 getLayer token 的 visibleScript 才安装 → 普通自层脚本(时钟/秒/now-playing/音频条)零影响。
        //   WP_NO_APPLY_USERPROPS=1 整体关闭(退回旧行为)。3D 场景同样启用(Dock 是 2D 覆盖层,在 layers[] 上)。
        crossLayerScripts.removeAll(keepingCapacity: true)
        logicScripts.removeAll(keepingCapacity: true)
        layerIndexById.removeAll(keepingCapacity: true)
        if ProcessInfo.processInfo.environment["WP_NO_APPLY_USERPROPS"] == nil {
            for i in layers.indices { layerIndexById[layers[i].id] = i }
            var seen = Set<ObjectIdentifier>()
            func collect(_ s: WEScript?) {
                guard let s = s, s.usesLayerAPI else { return }
                if seen.insert(ObjectIdentifier(s)).inserted { crossLayerScripts.append(s) }
            }
            // ① 无 image 容器上的逻辑控制器(土星 Dock 主控:据 enableDock 写各图标层显隐)。不在 layers[],
            //    引擎每帧主动跑其 update()(见 update() 跨层读回段)。
            logicScripts = document.logicScripts
            for s in logicScripts { collect(s) }
            // ② 普通图层 visible 字段上的 getLayer 控制器(伊蕾娜昼夜切换等:挂在自身渲染层上)。
            for i in layers.indices { collect(layers[i].visibleScript) }
            if !crossLayerScripts.isEmpty {
                let defs = layers.map { (name: $0.name, id: $0.id) }
                let changed = document.changedUserPropertyNames   // 用户改过(≠pkg默认)的属性名(如 dock/newproperty10)
                for s in crossLayerScripts {
                    s.setSceneLayers(defs)
                    s.applyUserProperties(changed)   // 首帧派发变更(无导出此函数 → no-op)
                }
                Log.write("xlayer: \(crossLayerScripts.count) controller(s) (\(logicScripts.count) logic-layer); \(layerIndexById.count) targets; changed=\(changed)")
            }
        }
        lastUpdateTime = -1
        let cbmLayers = layers.filter { $0.colorBlendMode > 0 }
        let cbmInfo = cbmLayers.isEmpty ? "" : " colorBlendMode=\(cbmLayers.map { $0.colorBlendMode })(pipe=\(pipelineColorBlend != nil ? "Y" : "N"))"
        Log.write("scene: loaded \(layers.count)/\(document.layers.count) layers, \(particleGroups.count)/\(document.emitters.count) particle groups, canvas \(canvas.x)x\(canvas.y), parallax=\(hasParallax)\(cbmInfo)")
        precomputeLargeLayers()   // 自适应「大图被切→拉伸」:算定大图像层不透明内容包围盒
        writeRenderAudit(document: document, source: source)
    }

    /// 渲染审计日志:每次 load 把逐层「pkg 数据 → 引擎决策」写到 /tmp/wp_render_audit.log,
    /// 供从日志直接定位渲染错误(用户工作流:渲染一个壁纸 → 看日志找错)。⚠️/❌ 前缀可 grep。
    private func writeRenderAudit(document: SceneDocument, source: SceneSource) {
        var L: [String] = []
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        L.append("================ WP RENDER AUDIT \(df.string(from: Date())) \(auditTag) ================")
        L.append("canvas \(Int(canvas.x))x\(Int(canvas.y)) clear=\(document.clearColor) postChain=[\(postChain.map { $0.weName }.joined(separator: ","))] abovePostStart=\(abovePostStart == Int.max ? -1 : abovePostStart)")
        L.append("layers \(layers.count)/\(document.layers.count)(文档)  particles \(particleGroups.count)/\(document.emitters.count)  audioBars=\(hasAudioBars) audioFX=\(hasAudioReactiveFX)")
        for (i, l) in layers.enumerated() {
            var t = "img"
            if l.frameBufferInput { t = l.regionFit ? "compose(region)" : "compose(fb)" }
            else if l.text != nil { t = "text" }
            else if l.video != nil { t = "video" }
            let o3 = l.baseModel.columns.3
            var head = "[\(i)] id=\(l.id) \(t) vis=\(l.visible ? "Y" : "n") origin=(\(Int(o3.x)),\(Int(o3.y)))"
            head += " size=\(Int(l.sizePx.x))x\(Int(l.sizePx.y))"
            if l.cropShiftPx != .zero { head += " cropShift=(\(Int(l.cropShiftPx.x)),\(Int(l.cropShiftPx.y)))" }
            if l.parallax != .zero { head += " par=(\(l.parallax.x),\(l.parallax.y))" }
            if l.puppetMesh != nil { head += " puppet[anims:\(l.puppetAnimLayers.map { "\($0.animId)\($0.additive ? "+" : "")" }.joined(separator: ","))]" }
            else if l.puppetVB != nil { head += " puppet[static]" }
            L.append(head)
            for (ei, e) in l.effects.enumerated() {
                var line = "    eff[\(ei)] \(e.weName.isEmpty ? "❌未映射" : e.weName)"
                if !e.weName.isEmpty {
                    if Self.weDenied.contains(e.weName) { line += " ❌denied" }
                    else if !(weEffects?.has(e.weName) ?? false) { line += " ❌manifest缺失(未转译)" }
                }
                if !e.weCombos.isEmpty { line += " combos=\(e.weCombos.sorted(by: { $0.key < $1.key }).map { "\($0)=\($1)" }.joined(separator: ","))" }
                if !e.weAux.isEmpty { line += " aux=\(e.weAux.sorted(by: { $0.key < $1.key }).map { "g_Texture\($0.key)←\($0.value)" }.joined(separator: ","))" }
                L.append(line)
            }
        }
        if !auditLines.isEmpty {
            L.append("---- 加载期事件/警告 ----")
            L.append(contentsOf: auditLines)
        }
        let txt = L.joined(separator: "\n") + "\n"
        try? txt.write(toFile: "/tmp/wp_render_audit.log", atomically: true, encoding: .utf8)
        Log.write("scene: render audit → /tmp/wp_render_audit.log (\(L.count) 行)")
    }

    /// 是否需要持续动画(有视差、粒子、视频纹理、effect、文本时钟、scale 脚本、音频条或鼠标水波)。
    var isAnimated: Bool { hasParallax || !particleGroups.isEmpty || hasVideo || hasEffects || hasText || hasScaleScript || hasOriginScript || hasAngleScript || hasAudioBars || hasInstancedBars || hasCursorRipple || has3DScene || hasKeyframeAnim || hasCameraAnim }
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
    /// 视差模型:默认 WGPU(wallpaper-wgpu)—— off=amount×parallaxDepth×smoothed、depth 默认(1,1)、(0,0)退出、
    /// amount 不进平滑状态。WP_PARALLAX_LWE=1 退回 lwe —— off=(depth+amount)×displacement、depth 默认(0,0)、amount 进状态。
    private let parallaxWGPU = ProcessInfo.processInfo.environment["WP_PARALLAX_LWE"] == nil
    /// 视差平滑状态(归一化空间)。WGPU:centered×influence;lwe:centered×amount×influence。
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
    /// 后处理边界:layers[abovePostStart...] 排在最后一个 postChain fullscreenlayer **之上**,不被后处理染色/模糊。
    ///   场景 pass 只画 [0, abovePostStart) 进 postChain 输入;postChain 跑完后再把这些上方图层叠到已后处理画面上
    ///   (WE/lwe 语义:fullscreenlayer 只作用其下方;时钟/日期等 UI 文本叠在已调色场景之上 → 保持亮白,不被 darkambient tint 压暗)。
    ///   仅在 postChain 非空且 0<abovePostStart<layers.count 时生效;否则恒画全部(行为同旧)。
    private var abovePostStart: Int = Int.max
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
    // 后处理层 opacity 叠回用的临时纹理(2 张 ping-pong,避免读写同一张)。
    private var postMixTex: [MTLTexture?] = [nil, nil]
    private var postMixIdx = 0
    /// mix(base, top, alpha):把 top 按常量 alpha 叠到 base 上,返回新纹理(= base*(1-α)+top*α)。
    /// 供 postChain 的 opacity 特效实现"后处理层按图层 opacity 叠回下方画面"(真 WE 语义)。
    private func mixTextures(base: MTLTexture, top: MTLTexture, alpha: Float, cmd: MTLCommandBuffer) -> MTLTexture? {
        guard let blit = pipelineBlit, let mix = pipelineBlitMix else { return nil }
        let w = base.width, h = base.height
        // 选一张 != base/top 的临时纹理(ping-pong)。
        for _ in 0..<2 {
            postMixIdx = (postMixIdx + 1) % 2
            if postMixTex[postMixIdx]?.width != w || postMixTex[postMixIdx]?.height != h {
                let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
                d.usage = [.renderTarget, .shaderRead]; d.storageMode = .private
                postMixTex[postMixIdx] = device.makeTexture(descriptor: d)
            }
            guard let t = postMixTex[postMixIdx], t !== base, t !== top else { continue }
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = t
            pass.colorAttachments[0].loadAction = .dontCare
            pass.colorAttachments[0].storeAction = .store
            guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return nil }
            enc.label = "postchain-opacity-mix"
            enc.setFragmentSamplerState(sampler, index: 0)
            enc.setRenderPipelineState(blit)                       // 先铺 base(不透明)
            enc.setFragmentTexture(base, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.setRenderPipelineState(mix)                        // 再按 α 叠 top
            enc.setBlendColor(red: 0, green: 0, blue: 0, alpha: alpha)
            enc.setFragmentTexture(top, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
            return t
        }
        return nil
    }
    // 持久可采样场景 FBO(= lwe `_rt_FullFrameBuffer`)。图层按 z 序交错合成进它;
    // composelayer 采样它的累积态作特效输入(忠实移植 lwe CScene 主 FBO + CImage 读 _rt_FullFrameBuffer)。
    /// lwe per-Image FBO 合成管线(**默认开**,忠实于 lwe):图层按 z 序交错合成进持久 lweSceneFBO,
    /// composelayer 采样它的累积态作特效输入(取代自创 compositeSceneBelow 透明 clear 近似)。
    /// 全库 57 张 A/B 源码级验证:53 张 0 diff、2 张是「读 clearcolor 清屏的真场景 FBO」的忠实改善(对齐
    /// lwe CScene.cpp:432-447 用 clearcolor 清场景 FBO);Task 4(per-Image ping-pong/blend 末移)经源码分析
    /// 与本实现像素等价、跳过。逃生开关 WP_NO_LWE_COMPOSITE=1 退回旧 compositeSceneBelow 路径(保险)。
    private var useLweComposite: Bool { ProcessInfo.processInfo.environment["WP_NO_LWE_COMPOSITE"] == nil }
    // parent→child composelayer FBO 机制(**默认开**,真 WE,lwe 未实现):parent 指向 composelayer 的粒子组
    // 渲进该 composelayer 的透明 child FBO(见 GPULayer.childParticleGroupIndices),由 composelayer 对「只含
    // 粒子」的 FBO 跑 tint/opacity-mask 后合成回场景(矩阵被染色+裁到遮罩区,角色/龙身不被染色)。
    // WP_NO_COMPOSE_CHILD_FBO=1 退回旧:粒子当独立世界粒子全屏画 + composelayer 把下方场景染色。
    private var useComposeChildFBO: Bool { ProcessInfo.processInfo.environment["WP_NO_COMPOSE_CHILD_FBO"] == nil }
    // 仅当确实建立了 parent→child 关联(load() 设)才启用 child FBO 路径,其他 composelayer 壁纸完全不受影响。
    private var hasComposeChildFBO = false
    // child FBO(透明全画布,放父 composelayer 的子粒子组);按场景分辨率(=sceneFBO 尺寸)建,复用。
    private var composeChildTex: MTLTexture?
    private func composeChildTarget(width: Int, height: Int) -> MTLTexture? {
        if composeChildTex?.width != width || composeChildTex?.height != height {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                             width: width, height: height, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]; d.storageMode = .private
            composeChildTex = device.makeTexture(descriptor: d)
        }
        return composeChildTex
    }
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
    /// now-playing(歌名/艺术家):喂给 mediaPropertiesChanged 文本层(Now Playing widget)。
    /// 数据源:① 系统正在播放的音乐(NowPlayingProvider,任意 app);② 回退壁纸自带 BGM 文件名。
    private var nowPlayingTitle = ""   // 壁纸自带 BGM(回退)
    private var nowPlayingArtist = ""
    /// 当前应显示的曲目:系统 now-playing 优先(非空),否则壁纸自带 BGM。
    private var effectiveNowPlaying: (title: String, artist: String) {
        let st = NowPlayingProvider.shared.title, sa = NowPlayingProvider.shared.artist
        return (st.isEmpty ? nowPlayingTitle : st, sa.isEmpty ? nowPlayingArtist : sa)
    }

    /// 从壁纸自带 sound(BGM)文件名解析 now-playing 标题/艺术家。
    /// WE 上传 mp3 命名 `Artist_-_Title_<assetid>.mp3`(下划线代空格,`_-_` 分隔,尾随数字 hash)。
    /// 例:`imase_-_NIGHT_DANCER_74967598.mp3` → artist="imase" title="NIGHT DANCER"。
    /// 无 `_-_` 分隔时整体作标题、艺术家空。startSilent 的 sound 也解析(WE 仍认它为当前曲目元数据)。
    static func parseNowPlaying(from sounds: [SoundDesc]) -> (title: String, artist: String) {
        guard let s = sounds.first(where: { !$0.sounds.isEmpty }),
              let path = s.sounds.first else { return ("", "") }
        var base = (path as NSString).lastPathComponent
        base = (base as NSString).deletingPathExtension
        // 去掉 WE 资产 hash 尾缀:`_<6+位数字>`(避免误删真歌名里的短数字)。
        if let r = base.range(of: "_[0-9]{6,}$", options: .regularExpression) {
            base.removeSubrange(r)
        }
        func clean(_ s: String) -> String {
            s.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces)
        }
        if let r = base.range(of: "_-_") {
            return (clean(String(base[r.upperBound...])), clean(String(base[..<r.lowerBound])))
        }
        return (clean(base), "")
    }
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
    /// 是否含运行时动态建层脚本(音频条 bar 模板:每帧 runDynamicBars 重算 N 根 bar → 需持续动画)。
    private var hasInstancedBars = false
    /// 是否含关键帧时间线动画(开场 alpha 淡出 / origin/angle 摆动)→ 需起动画循环并逐帧重绘。
    private var hasKeyframeAnim = false
    private var hasAudioReactiveFX = false   // 任一图层/后处理特效请求 AUDIOPROCESSING(pulse 等)
    private var hasAudioReactiveScript = false  // 任一 origin/scale/angle 脚本用音频(registerAudioBuffers)
    // 跨层写回(applyUserProperties / Dock 显隐):含 getLayer 的控制器脚本(土星壁纸 Dock 主控:据
    //   scriptProperties.enableDock 写各图标层 visible/alpha)安装了真实层注册表;每帧 runBool 跑完后
    //   readLayerWrites → 按 id 把 visible/alpha 应用到目标层。空集(无此类脚本)→ 零开销零影响。
    //   WP_NO_APPLY_USERPROPS=1 整体关闭(退回旧行为:控制器脚本的跨层写丢弃,Dock 恒显)。
    private var crossLayerScripts: [WEScript] = []      // 已安装记脏层的控制器脚本(每帧读回其写入)
    private var logicScripts: [WEScript] = []           // 无 image 容器上的控制器(Dock 主控):不在 layers[],每帧主动跑 update
    private var layerIndexById: [Int: Int] = [:]        // 目标层 id → layers 下标
    private var currentAudio = WEEffectChain.AudioSpectrum()  // 本帧三套原生频谱(16/32/64),供 WEEffectChain 的音频 uniform
    /// 壁纸自带音频播放(BGM/雨声);与系统声采集(usesAudio,音频条用)无关。默认随 isMuted 静音。
    private let audioPlayback = AudioPlayback()

    // MARK: - WE「属性」通用区(每壁纸固定 7 控件中由引擎实现的几项)。默认值 = 现状行为(零回归)。
    /// 音频监听(audio responsive)。关时不喂系统音频频谱(音频条/oscilloscope 静默)。默认开。
    private var generalAudioListen = true
    /// 翻转(flip horizontal):最终呈现把 uv.x 镜像。默认关。
    private var generalFlip = false
    /// 图片筛选器:0=无、1=灰度、2=棕褐、3=反相、4=暖、5=冷。最终画面过一个轻量后处理滤镜。默认 0=无。
    private var generalFilter = 0
    /// SceneRenderer 据 loadedItem 推入这 4 项(load/reloadInPlace 时调一次)。播放速度/音量在外层(时钟累积/audioPlayback)处理。
    /// WP_NO_GENERAL_PROPS 总退路:置 1 时引擎忽略这些通用项,完全走旧行为。
    func setGeneralProps(audioListen: Bool, flip: Bool, filter: Int) {
        if ProcessInfo.processInfo.environment["WP_NO_GENERAL_PROPS"] != nil {
            generalAudioListen = true; generalFlip = false; generalFilter = 0; return
        }
        generalAudioListen = audioListen
        generalFlip = flip
        generalFilter = max(0, filter)
    }

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
        let ax: Float, ay: Float
        if parallaxWGPU {
            // WGPU(wallpaper-wgpu)模型:off = amount × parallaxDepth × smoothed × sceneWidth。
            // amount 只在此出现一次(不在平滑状态里);depth 默认 (1,1)、显式 (0,0) → off=0(不参与)。
            // ⚠ 暂未含 reference 的 root_position 项(shift=amount×depth×(root−smoothed)):描述未定 root_position
            //   坐标空间,任何字面解读都会在静止态产生位移、且 magnitude 对不上 → 待 renderer.rs:444 源码精确补。
            //   现为「鼠标驱动分量」(root 略去),静止态归 0。
            ax = cameraParallaxAmount * depth.x * parallaxDisplacement.x * refW
            ay = cameraParallaxAmount * depth.y * parallaxDisplacement.y * refW
        } else {
            // lwe(WP_PARALLAX_LWE 退回):off = (depth + amount) × displacement × sceneWidth(CImage.cpp:1118)。
            ax = (depth.x + cameraParallaxAmount) * parallaxDisplacement.x * refW
            ay = (depth.y + cameraParallaxAmount) * parallaxDisplacement.y * refW
        }
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
        // 2D 场景相机**运镜**(开场推近再回弹等):每帧按 camera-path 对象的 zoom/origin 关键帧求值,在静态基投影
        // 之前乘运镜矩阵 → 本帧 proj。下方所有用 proj 的地方(图层 mvp/粒子 proj/主 pass)自动随相机推拉/平移。
        // 无运镜对象(hasCameraAnim=false,绝大多数壁纸)→ proj 恒 = baseProj(此分支不进,逐位不变,零回归)。
        if hasCameraAnim, let ca = cameraAnim {
            // 求值 zoom(标量,非 relative)与 origin.xy(已含 base 偏移)。
            let zoom = ca.zoom?.evaluate(time: t).first ?? ca.zoomAtRest
            var dp = SIMD2<Float>(0, 0)
            if let oa = ca.origin {
                let ov = oa.evaluate(time: t)
                let ox = ov.count > 0 ? ov[0] : ca.originAtRest.x
                let oy = ov.count > 1 ? ov[1] : ca.originAtRest.y
                // pan = 相机眼位相对**静止态(末关键帧)**的移动量(画布像素)。稳态 → dp=0(内容居中)。
                dp = SIMD2(ox - ca.originAtRest.x, oy - ca.originAtRest.y)
                // WP_NO_CAMERA_PAN=1:只做 zoom 推近(不平移),A/B 诊断(zoom 是已验证的主运镜分量)。
                if ProcessInfo.processInfo.environment["WP_NO_CAMERA_PAN"] != nil { dp = .zero }
            }
            // 缩放枢轴 = **画布中心**(WE 相机看向画布中心;base 眼位 1920 1080 即画布中心)。运镜围绕画面中心
            // 推拉,而非围绕帧0 眼位(=(0,0) 画布角落,会把内容钉在角上放大 → 错)。pan 仍取眼位相对帧0 的移动量。
            let pivot = SIMD2<Float>(canvas.x * 0.5, canvas.y * 0.5)
            let camMat = cameraAnimMatrix(center: pivot, zoom: zoom, pan: dp)
            self.proj = baseProj * camMat
            if ProcessInfo.processInfo.environment["WP_DBG_CAMERA"] != nil {
                let fr = t * ca.fps
                FileHandle.standardError.write("WP_DBG_CAMERA t=\(String(format:"%.2f",t))s f\(String(format:"%.0f",fr)) zoom=\(String(format:"%.3f",zoom)) pan=(\(String(format:"%.1f",dp.x)),\(String(format:"%.1f",dp.y))) pivot=(\(Int(pivot.x)),\(Int(pivot.y)))\n".data(using: .utf8)!)
            }
        }
        // puppet 骨骼蒙皮动画(MDLS/MDLA):每帧求值动画 → 蒙皮顶点 → 就地更新该层 puppetVB(真 WE 角色待机
        // 摇摆/形变;lwe 无此功能)。skin() 失败/无骨返回 nil → 不更新 → 维持静态 bind 姿态(零回归)。
        // 默认启用(转置修复后 rest=I 已验证;版本保护只对 MDLS0004/MDLA0006 蒙皮)。WP_NO_PUPPET_ANIM 可临时关。
        if ProcessInfo.processInfo.environment["WP_NO_PUPPET_ANIM"] == nil {
            for i in layers.indices {
                guard let mesh = layers[i].puppetMesh, let vb = layers[i].puppetVB else { continue }
                // 多 animationlayer 叠加合成(WE 真义;御剑龙 base+additive)。skinLayers 要求精确 anim id 命中,
                // 失败(id 不在 MDLA,如部分壁纸引用编辑器层 id)→ 回退旧单层 skin()(带 anims.first 兜底),零回归。
                // 眼睛层用完整 3D 蒙皮(rx/ry/tz)配背面剔除;主 puppet 用平面蒙皮(丢 rx/ry,零回归)。
                let use3D = layers[i].puppetUse3D
                let skinned = mesh.skinLayers(time: time, layers: layers[i].puppetAnimLayers, use3D: use3D)
                    ?? mesh.skin(time: time, rate: layers[i].puppetAnimRate, animId: layers[i].puppetAnimId, use3D: use3D)
                guard let sk = skinned else { continue }
                let bytes = MemoryLayout<Float>.stride * sk.count
                if vb.length >= bytes { sk.withUnsafeBytes { vb.contents().copyMemory(from: $0.baseAddress!, byteCount: bytes) } }
            }
        }
        // 本帧音频频谱。供 runLayerEffects/runPostChain 喂给 WE 的 g_AudioSpectrum16/32/64Left/Right。
        // lwe(CPass.cpp:785-790)绑三套**原生**频谱 audio16/32/64(各分辨率在 AudioCapture 里独立分桶,
        // 非由 64 段重采样);shader 按 RESOLUTION combo 声明的段数取对应那套。
        // 音频条层(hasAudioBars)和音频反应特效(hasAudioReactiveFX,如 pulse)都要;两者皆无则不取(省锁)。
        // 通用区「音频监听」关 → 喂空频谱(音频条/oscilloscope 归零静默),即便壁纸用音频也不响应。
        // WP_FORCE_AUDIO_OFF=1:验证用(headless 不走 setGeneralProps),强制关闭音频监听。
        let audioListen = generalAudioListen && ProcessInfo.processInfo.environment["WP_FORCE_AUDIO_OFF"] == nil
        currentAudio = (audioListen && (hasAudioReactiveFX || hasAudioBars))
            ? WEEffectChain.AudioSpectrum(s16: AudioCapture.shared.spectrum16,
                                          s32: AudioCapture.shared.spectrum32,
                                          s64: AudioCapture.shared.bands)
            : WEEffectChain.AudioSpectrum()
        // 诊断:WP_TEST_AUDIO=<0..1> 注入合成频谱(无头渲染没有系统音频,用于复现/验证音频条)。生产默认空=零影响。
        // **变化**频谱(每段高低不同)而非恒定——恒定会让 SHAPE 类音频条(如黑猫 Simple_Audio_Bars SHAPE=1
        // 填充区域)把所有等高 bar 连成实心块=假白方块,误判 bug。变化谱更接近真实音频、暴露真实形状。
        // WP_TEST_AUDIO_FLAT=1 退回恒定(对比)。
        if let s = ProcessInfo.processInfo.environment["WP_TEST_AUDIO"], let v = Float(s) {
            let flat = ProcessInfo.processInfo.environment["WP_TEST_AUDIO_FLAT"] != nil
            let neg = ProcessInfo.processInfo.environment["WP_TEST_AUDIO_NEG"] != nil  // 诊断:注入含负频谱(模拟真实音乐 mag<1 → 0.35*log10<0)
            func gen(_ n: Int) -> [Float] {
                if neg { return (0..<n).map { v * sin(Float($0) * 0.9 + 0.3) - 0.3 } }  // 约半数为负,验证 oscilloscope powr(负) NaN 修复
                return flat ? [Float](repeating: v, count: n)
                            : (0..<n).map { v * (0.15 + 0.85 * abs(sin(Float($0) * 0.7 + 0.3))) }
            }
            currentAudio = WEEffectChain.AudioSpectrum(s16: gen(16), s32: gen(32), s64: gen(64))
        }
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
            // centeredMouse = 画布 UV - 0.5。同 cursor:屏幕 NDC 要先 /ndcScale 扣 cover 裁切,
            // 否则非同比例屏上视差量也随距离偏。mouseUV = (mouseNorm/ndcScale + 1)/2 → centered = mouseUV - 0.5。
            let centered = SIMD2(mouseNorm.x / aspectMouse.x * 0.5, mouseNorm.y / aspectMouse.y * 0.5)
            // WGPU:amount **不进**平滑状态(amount 在 parallaxOffset 逐对象施加);平滑态只存 centered×influence。
            // lwe(退回):amount 进平滑状态(CScene.cpp:315 mix 到 centeredMouse×amount×influence)。
            let target = parallaxWGPU
                ? centered * cameraParallaxMouseInfluence * userStrength
                : centered * cameraParallaxAmount * cameraParallaxMouseInfluence * userStrength
            let k = max(0, min(1, cameraParallaxDelay * Float(dt)))
            parallaxDisplacement += (target - parallaxDisplacement) * k
        }
        // camerashake:lwe 只解析不渲染 → 不产生任何抖动(无真实公式可移植,绝不自造)。
        // 音频反应脚本:本帧频谱(仅当有音频脚本时取,省锁)。下面循环喂进各用音频的脚本(setAudioSpectrum)。
        // 通用区「音频监听」关 → 脚本也读空频谱(音频条 bar 模板等归零)。
        let scriptAudioOn = hasAudioReactiveScript && generalAudioListen
            && ProcessInfo.processInfo.environment["WP_FORCE_AUDIO_OFF"] == nil
        var scrA16 = scriptAudioOn ? AudioCapture.shared.spectrum16 : []
        var scrA32 = scriptAudioOn ? AudioCapture.shared.spectrum32 : []
        var scrA64 = scriptAudioOn ? AudioCapture.shared.bands : []
        // WP_TEST_AUDIO 注入的合成频谱(currentAudio,见上)也喂给音频反应脚本(音频条 bar 模板等),
        // 否则无头渲染下脚本读到的还是空捕获、条恒静止 → 无法验证。生产无此 env 时零影响。
        if hasAudioReactiveScript, ProcessInfo.processInfo.environment["WP_TEST_AUDIO"] != nil {
            scrA16 = currentAudio.s16; scrA32 = currentAudio.s32; scrA64 = currentAudio.s64
        }
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
                if layers[i].instancedBarsScript?.usesAudio == true { layers[i].instancedBarsScript?.setAudioSpectrum(s16: scrA16, s32: scrA32, s64: scrA64) }
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
            // 对象级 alpha 关键帧动画(WE 时间线 = **开场动画**:全屏黑层 alpha frame0=1→末帧=0 淡出,mode=single 播完保持末值)。
            // 门控 `!frameBufferInput`:打雷 pulse(frameBufferInput && !regionFit)/ region 音频 composelayer 的 opacity
            //   关键帧由下方 effects.weAnim 路径单独处理并与 pulse 合成,此处只管普通图层/solidlayer 的对象 alpha,
            //   避免当年 opacity×pulse 过曝吹白回归(见 L1547 历史注释)。这条让黑层 3.5s 后淡出 → 壁纸不再永久黑屏进不去。
            if let aka = layers[i].alphaKeyAnim, !layers[i].frameBufferInput {
                let v = aka.evaluate(time: t)
                if let a = v.first { layers[i].color.w = a }
            }
            if let cs = layers[i].colorScript,
               case .vec3(let c) = cs.runVec3(current: SIMD3(layers[i].color.x, layers[i].color.y, layers[i].color.z), simTime: time, frametime: dt) {
                layers[i].color = SIMD4(c.x, c.y, c.z, layers[i].color.w)
            }
            // 部件间 attachment 层:baseModel 已按父变换搭好(子顶点搬进父空间),下方 origin/angle/scale 脚本
            // 及 origin 关键帧重建会用子自身 origin/size 覆写 baseModel → 破坏 attachment。故跳过这些重建
            // (kalsey 眼睛/眼睑/耳朵均无这些脚本,实际零差;此 guard 是通用安全网)。视差仍照常作用于 baseModel。
            if !layers[i].isAttached {
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
                // + cropShiftPx:关键帧覆盖了 SceneModel 在 absOrigin 上加的 cropoffset 位移,这里补回(发饰挡眼真因)。
                // cropoffset 全量(忠实 pkg):发饰与火1 的 model.json 结构完全相同,pkg 无任何字段可区分二者 →
                // 必须同样应用全量 cropoffset(刀/火1 实测对)。发饰全量"看着多"的偏差源自**动画**(发饰小摆动 vs
                // 火1 大幅+animated scale),那是唯一真实数据差异,从动画侧查,不靠缩 cropoffset 治标。
                // WP_KF_SCALE 仅作 A/B 诊断(默认1=全量)。
                let kfScale = Float(ProcessInfo.processInfo.environment["WP_KF_SCALE"] ?? "1") ?? 1
                let cs = SIMD2<Float>(layers[i].cropShiftPx.x * kfScale, layers[i].cropShiftPx.y * kfScale)
                layers[i].origin = SIMD2(pa.x + rotated.x + cs.x, pa.y + rotated.y + cs.y)
                layers[i].baseModel = matModel(centerPx: layers[i].origin, sizePx: layers[i].sizePx, angleDegZ: layers[i].baseAngleZ)
            }
            } // end !isAttached(脚本/origin关键帧重建跳过)
            // —— 动态挂点跟随(2026-06-07 起;眼睛绑脸皮修复 2026-06-07b):attach 部件(眼/睑/耳)逐帧跟随
            //    **父 puppet 骨骼动画**(主体 anim206 呼吸让头骨 bone5 旋转+平移)。
            //    旧式只取挂点**枢轴**(头部@mesh-local(734,856))的位移,平移给所有子部件 → 但 bone5 **旋转**,离
            //    枢轴 630px 的眼睛组合应下沉 −91.5px 而枢轴只 −59.1px → 偏离脸 24px(引擎 parser 实测,见
            //    PuppetMesh.attachBoneSkinMatrix 注释)。正解:用该骨的**蒙皮矩阵**变换子的**实际锚点**(枢轴 +
            //    子局部 origin),捕获旋转放大的真实下沉 → 眼睛随脸皮一起沉、不脱位。
            //      anchor(t)      = boneSkin(t)·anchorLocal                       (父 mesh-local)
            //      modelCenter(t) = staticCenter + R(parentAngle)·((anchor(t) − anchor(0))·parentScale)
            //      attachAngle(t) = staticAngle  + (zAngle(boneSkin(t)) − zAngle(boneSkin(0)))   ← 头骨微转,部件随转
            //    t=0 增量恒为 0 → 严格退化到 build 的静态 baseModel(回归兜底)。WP_NO_ATTACH_SKIN=1 退回旧枢轴式
            //    (A/B 对比)。父对象自身 layer transform 静态(主体无 origin/angle 脚本,已核)。
            if ProcessInfo.processInfo.environment["WP_NO_ATTACH_SKIN"] == nil,
               let pMesh = layers[i].attachParentMesh,
               let skinT = pMesh.attachBoneSkinMatrix(layers[i].attachName, time: time,
                                                       rate: layers[i].attachParentAnimRate,
                                                       animId: layers[i].attachParentAnimId) {
                let al = layers[i].attachAnchorLocal
                let p4 = skinT * SIMD4<Float>(al.x, al.y, 0, 1)
                let animAnchor = SIMD2(p4.x, p4.y)
                let dPos = SIMD2(animAnchor.x - layers[i].attachAnchorBind.x,
                                 animAnchor.y - layers[i].attachAnchorBind.y)   // 锚点 mesh-local 位移(t 相对 0)
                let ps = layers[i].attachParentScale
                let scaled = SIMD2(dPos.x * ps.x, dPos.y * ps.y)
                let rotated = rotateVec2(scaled, layers[i].attachParentAngle)
                let center = SIMD2(layers[i].attachStaticCenter.x + rotated.x,
                                   layers[i].attachStaticCenter.y + rotated.y)
                let dAngle = zAngle(skinT) - layers[i].attachBindAngle     // 头骨微转(t 相对 0;bind∠用同骨蒙皮基准)
                let ang = layers[i].attachStaticAngle + dAngle
                layers[i].baseModel = matModel(centerPx: center, sizePx: layers[i].attachEffSize, angleDegZ: ang)
            } else if let pMesh = layers[i].attachParentMesh,
               let awt = pMesh.animatedAttachmentWorld(layers[i].attachName, time: time,
                                                        rate: layers[i].attachParentAnimRate,
                                                        animId: layers[i].attachParentAnimId) {
                // 旧枢轴式回退(WP_NO_ATTACH_SKIN=1 时):平移挂点枢轴位移给整子部件(无旋转放大补偿)。
                let animPos = SIMD2(awt.columns.3.x, awt.columns.3.y)
                let dPos = SIMD2(animPos.x - layers[i].attachBindPos.x,
                                 animPos.y - layers[i].attachBindPos.y)
                let ps = layers[i].attachParentScale
                let scaled = SIMD2(dPos.x * ps.x, dPos.y * ps.y)
                let rotated = rotateVec2(scaled, layers[i].attachParentAngle)
                let center = SIMD2(layers[i].attachStaticCenter.x + rotated.x,
                                   layers[i].attachStaticCenter.y + rotated.y)
                let dAngle = zAngle(awt) - layers[i].attachBindAngle
                let ang = layers[i].attachStaticAngle + dAngle
                layers[i].baseModel = matModel(centerPx: center, sizePx: layers[i].attachEffSize, angleDegZ: ang)
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
                        let sv: String?
                        if vals.count == 1 { sv = String(vals[0]) }
                        else if vals.count >= 3 { sv = "\(vals[0]) \(vals[1]) \(vals[2])" }
                        else { sv = nil }
                        guard let sval = sv else { continue }
                        layers[i].effects[j].weParams[key] = sval
                        // 关键:buildUniforms 对单/多 pass 都优先用 **weParamsPerPass[pass]**(见 WEEffectChain.run
                        // 的 `params = (pi < paramsPerPass.count) ? paramsPerPass[pi] : pkgParams`),只更新合并版
                        // weParams 不会被 pass0 读到 → 关键帧值丢失、退静态 value(phantomtransitionfx 的 A_BlendAmount
                        // 退 preview value≈0.958 → 圆形转场恒满、不展开)。故同步写回**所有含该 key 的 per-pass 字典**。
                        // 仅作用于本就有该 key 的 per-pass 槽(不新建),全库回归:黑猫 0 差、伊蕾娜 14px(关键帧本应露的
                        // 内容,是修非回归)。WP_NO_PERPASS_ANIM=1 退回(仅更新合并版,A/B 用)。
                        if ProcessInfo.processInfo.environment["WP_NO_PERPASS_ANIM"] == nil {
                            for pp in layers[i].effects[j].weParamsPerPass.indices
                            where layers[i].effects[j].weParamsPerPass[pp][key] != nil {
                                layers[i].effects[j].weParamsPerPass[pp][key] = sval
                            }
                        }
                    }
                }
            }
            let off = parallaxOffset(depth: layers[i].parallax)
            layers[i].mvp = proj * matTranslate(off.x, off.y) * layers[i].baseModel
            // 运行时动态建层(音频条 bar 模板):每帧 runDynamicBars 跑脚本(首帧 init 建 NUM_BARS 根 bar,
            //   每帧 update 按音频写各 bar 的 origin/scale/alignment),读回每根 bar 的变换 → 算其 mvp。
            //   属性回灌 = 读回脚本写的 origin/scale/angles/alignment(脚本→引擎单向),encode 多实例渲染。
            //   坐标:bar.origin 与本层 originPx 同空间(已注入 thisLayer.origin=absOrigin);sizePx=基准×bar.scale;
            //   angles.z(度)→弧度;alignment 把中心沿本地 y 轴(随角旋转)平移 ±sizePx.y/2(bottom 上移/top 下移)。
            if let ibs = layers[i].instancedBarsScript {
                if let bars = ibs.runDynamicBars(simTime: time, frametime: dt) {
                    if ProcessInfo.processInfo.environment["WP_DBG_BARS"] != nil {
                        let sample = bars.prefix(4).map { "o=(\(Int($0.origin.x)),\(Int($0.origin.y))) s=(\(String(format:"%.2f",$0.scale.x)),\(String(format:"%.2f",$0.scale.y))) al=\($0.alignment)" }.joined(separator: " | ")
                        FileHandle.standardError.write("WP_DBG_BARS count=\(bars.count) base=\(layers[i].instancedBarBaseSize) | \(sample)\n".data(using: .utf8)!)
                    }
                    var mvps: [simd_float4x4] = []
                    mvps.reserveCapacity(bars.count)
                    for bar in bars {
                        let sz = SIMD2(layers[i].instancedBarBaseSize.x * bar.scale.x,
                                       layers[i].instancedBarBaseSize.y * bar.scale.y)
                        if !(sz.x > 0) || !sz.y.isFinite { continue }   // 退化 bar(scale=0/非有限)跳过
                        let ang = SceneDocument.scriptAngleZToRadians(bar.angles.z)
                        var center = SIMD2(bar.origin.x, bar.origin.y)
                        switch bar.alignment.lowercased() {
                        case "bottom": center += rotateVec2(SIMD2(0,  sz.y * 0.5), ang)  // 底边对齐:origin=底,条向上长
                        case "top":    center += rotateVec2(SIMD2(0, -sz.y * 0.5), ang)  // 顶部对齐:origin=顶,条向下长
                        default: break                                                    // centre:origin=中心
                        }
                        let m = matModel(centerPx: center, sizePx: sz, angleDegZ: ang)
                        mvps.append(proj * matTranslate(off.x, off.y) * m)
                    }
                    layers[i].barMVPs = mvps
                } else {
                    layers[i].barMVPs = []   // 脚本失败/异常 → 本帧不画条(回退,不崩)
                }
            }
            // 视频纹理:每帧拉取当前帧替换图层纹理。
            if let vt = layers[i].video {
                layers[i].texture = vt.currentTexture()
            }
        }

        // 跨层写回(applyUserProperties / Dock 显隐):上面的 per-layer 循环已跑过所有 visibleScript(含 Dock
        //   主控脚本的 update() 副作用 —— 经 thisScene.getLayer(name).visible/alpha = … 写了**别的**层的记脏 stub)。
        //   此处读回脚本写过的字段,按 id 应用到目标层。默认只回灌 **visible / alpha**(显隐信号:Dock 关时把图标
        //   alpha→0、visible=false,这是用户要的「图标隐藏」),不回灌 origin/scale/angles/color —— 后者是脚本在
        //   3840×2160 假想屏空间算的布局坐标,与 pkg 1920×1080 画布静态布局口径不同,贸然回灌会移位(回归)。
        //   开 WP_XLAYER_TRANSFORM=1 才额外回灌变换(诊断/激进)。无控制器脚本 → crossLayerScripts 空 → 整段跳过(零影响)。
        if !crossLayerScripts.isEmpty {
            // 默认回灌**变换**(origin/scale/angles):Dock 主控脚本把图标排成一行需要这些坐标 —— 只回灌
            //   visible/alpha 会让图标停在 pkg 静态原点(挤在画布原点几乎不可见)。脚本算的是 3840×2160 屏空间
            //   坐标,直接作为目标层 origin 落进画布(渲染器再统一缩放到屏幕),实测 Dock 正确排在底部一行。
            //   WP_NO_XLAYER_TRANSFORM=1 退回「只 visible/alpha」(诊断:控制器写的变换坐标若与某壁纸口径不符可关)。
            let applyTransform = ProcessInfo.processInfo.environment["WP_NO_XLAYER_TRANSFORM"] == nil
            let dbg = ProcessInfo.processInfo.environment["WP_DBG_XLAYER"] != nil
            // 无 image 容器上的逻辑控制器(Dock 主控)不在 layers[] → 此处主动跑其 update()(void;触发
            //   thisScene.getLayer(name).visible/alpha=… 副作用)。runBool 兼跑首帧 init + intervals。
            for s in logicScripts { _ = s.runBool(current: true, simTime: time, frametime: dt) }
            for s in crossLayerScripts {
                let writes = s.readLayerWrites()
                if dbg, !writes.isEmpty {
                    let desc = writes.compactMap { (id, w) -> String? in
                        guard let ti = layerIndexById[id] else { return nil }
                        var f: [String] = []
                        if let v = w.visible { f.append("vis=\(v)") }
                        if let a = w.alpha { f.append(String(format: "a=%.2f", a)) }
                        return "\(layers[ti].name)[\(f.joined(separator: ","))]"
                    }.joined(separator: " ")
                    if !desc.isEmpty { Log.write("xlayer writes: \(desc)") }
                }
                for (id, w) in writes {
                    guard let ti = layerIndexById[id] else { continue }
                    if let v = w.visible { layers[ti].visible = v }
                    if let a = w.alpha, a.isFinite { layers[ti].color.w = a }   // Dock 图标透明度淡入淡出
                    if applyTransform {
                        if let c = w.color { layers[ti].color = SIMD4(c.x, c.y, c.z, layers[ti].color.w) }
                        if w.origin != nil || w.scale != nil || w.angles != nil {
                            if let o = w.origin { layers[ti].origin = SIMD2(o.x, o.y) }
                            if let an = w.angles { layers[ti].baseAngleZ = SceneDocument.scriptAngleZToRadians(an.z) }
                            var sz = layers[ti].sizePx
                            if let sc = w.scale, layers[ti].baseSize != .zero {
                                sz = SIMD2(layers[ti].baseSize.x * sc.x, layers[ti].baseSize.y * sc.y); layers[ti].sizePx = sz
                            }
                            let off = parallaxOffset(depth: layers[ti].parallax)
                            layers[ti].baseModel = matModel(centerPx: layers[ti].origin, sizePx: sz, angleDegZ: layers[ti].baseAngleZ)
                            layers[ti].mvp = proj * matTranslate(off.x, off.y) * layers[ti].baseModel
                        }
                    }
                }
            }
            if dbg {
                let dockState = layers.enumerated().filter { ["r1","o","l1","l8","do","dl1","dr1"].contains($1.name) }
                    .map { "\($1.name):\($1.visible ? "V" : "h")a\(String(format: "%.2f", $1.color.w))" }.joined(separator: " ")
                if !dockState.isEmpty { Log.write("xlayer APPLIED: \(dockState)") }
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
                // 3D 场景:文字内容来自**宿主**(单-context+shared,能算出 dis/ang/clock;per-layer 脚本无 shared 算不出)。
                // 把该层 kind 换成宿主算的字符串的静态文本 → currentString/render 直接出该串。
                if has3DScene, let rt = scene3DRuntime, let ht = rt.textValue(id: layers[i].id), !ht.isEmpty {
                    ts.desc.kind = .staticText(ht)
                }
                // Now Playing:把当前曲目元数据派发给 media 文本脚本(mediaPropertiesChanged 写 thisLayer.text)。
                // 去重在 runtime 内(签名变才触发),每帧调安全;currentString 随后读回 thisLayer.text。
                if case .script(let s) = ts.desc.kind, s.isMediaDriven {
                    let np = effectiveNowPlaying
                    s.dispatchMediaState(title: np.title, artist: np.artist, positionSec: nil, lengthSec: nil)
                }
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

        // 鼠标 → 画布 UV。**关键(修光标特效随距离偏移)**:画面是 cover/aspect-fill 裁切显示
        // (顶点 `position.xy *= ndcScale`),屏幕 NDC `s` 对应的画布点是 `p = s / ndcScale`(裁掉的边
        // 在屏幕上不可达)。此前直接 `(mouseNorm+1)/2` 把屏幕归一化当画布 UV,漏了 /ndcScale →
        // 光标特效在屏幕上落到 `s×ndcScale`,离中心越远偏得越外(用户实测:鼠标越往右、樱花特效越偏右)。
        // lwe(CScene.cpp:371-383)同样把鼠标先到 viewport [0,1] 再按可见 UV 范围(=扣裁切)映射到场景 UV。
        // ndcScale 由上一帧 render() 算(只随 resize 变);单 NDC 校正同时用于 pointer / 粒子 followsCursor / 水波。
        let mouseUVc = SIMD2(min(1, max(0, (mouseNorm.x / aspectMouse.x + 1) * 0.5)),
                             min(1, max(0, (mouseNorm.y / aspectMouse.y + 1) * 0.5)))
        let cursorCanvas = SIMD2(mouseUVc.x * canvas.x, mouseUVc.y * canvas.y)
        // 光标归一化 UV [0,1](y 向上)。喂 WE 交互特效(xray/depthparallax/樱花轨迹)的 pointer 量。
        cursorUV = mouseUVc

        // 鼠标划过水波:把光标 UV [0,1](y 向上=屏幕)喂给流体模拟。模拟步进在 render() 里做。
        if hasCursorRipple, let sim = rippleSim {
            sim.setPointer(mouseUVc)
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
            // ── eventdeath 中继(本轮唯一的 SceneRenderEngine 改动区域,Fix 3)─────────────────────────
            // 各 sim 互不通信(逐组独立 step)。eventdeath 烟花需把**父**死亡末位置中继给同
            // eventDeathGroupTag 的 **eventdeath child** sim,后者在该位置 burst(spawnEventDeathBurst)。
            // particleGroups 保持 document.emitters 顺序(父 desc 先于其 eventdeath child desc,见 ParticleParser),
            // 故按数组序:步进每组后若是父(tag>=0 且非 child)则 drainDeaths() 入 map;步进每组前若是 child 则
            // 从 map 取本帧父死亡位置 burst → 零延迟(burst 粒子在本组本帧 step 中即被积分)。tag<0 的普通粒子零开销。
            var deathMap: [Int: [SIMD2<Float>]] = [:]
            for g in particleGroups {
                if g.sim.desc.followsCursor { g.sim.cursorOrigin = cursorCanvas }   // 拖尾跟随光标
                // eventdeath child:先吃下本帧父死亡位置,各 anchor burst 一次(在 step 前,使爆发粒子本帧被积分)。
                if g.sim.desc.isEventDeath, g.sim.desc.eventDeathGroupTag >= 0,
                   let anchors = deathMap[g.sim.desc.eventDeathGroupTag] {
                    for a in anchors { g.sim.spawnEventDeathBurst(at: a) }
                }
                for _ in 0..<nSub { g.sim.step(dt: sdt, time: t) }
                // eventdeath 父:步进后取走本帧死亡末位置,累积给后续同 tag 的 child 组消费。
                if g.sim.desc.eventDeathGroupTag >= 0, !g.sim.desc.isEventDeath {
                    let deaths = g.sim.drainDeaths()
                    if !deaths.isEmpty { deathMap[g.sim.desc.eventDeathGroupTag, default: []].append(contentsOf: deaths) }
                }
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
            || hasKeyframeAnim
            || hasCameraAnim   // 相机运镜:proj 每帧在变 → 必须帧帧重渲(否则只画首帧静止)
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
    /// 诊断用(WP_CURSOR_LOG):实时 aspectMouse(ndc 校正)/ cursorUV(喂 xray/视差的 pointer)/ canvas。
    var debugCursorInfo: (aspect: SIMD2<Float>, cursorUV: SIMD2<Float>, canvas: SIMD2<Float>) {
        (aspectMouse, cursorUV, canvas)
    }
    /// 正交投影矩阵(load 时算好)。无相机运镜时 proj 恒 = baseProj(每帧复用);有运镜时 proj 每帧 = camAnim·baseProj。
    private var proj = matrix_identity_float4x4
    /// 静态基投影(load 时的 ortho/perspective)。相机运镜每帧在它之前乘运镜矩阵得本帧 proj。
    private var baseProj = matrix_identity_float4x4
    /// 2D 场景相机运镜(camera:"default" 路径对象的 origin/zoom 关键帧);nil = 静态相机(绝大多数壁纸)。
    private var cameraAnim: CameraPathAnim? = nil
    /// 是否有相机运镜(开场推近等)→ 每帧重算 proj + 视为「有动画」每帧重渲。
    private(set) var hasCameraAnim = false

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

    /// 该 solidlayer 是否需要「层尺寸纯色画布」跑空间特效?是→返回画布像素尺寸 (w,h);否→nil(走 1×1 白快路)。
    /// 触发条件(全满足):① 纯色层(isSolid 且非 frameBufferInput/composelayer——后者输入是场景 FBO,另有路径);
    ///   ② 不是音频频谱层(已由 transparent 底图路径处理);③ 至少有一个**可跑的真 WE 空间特效**。
    /// 「空间特效」= 用 v_TexCoord 产生沿层位置变化的图案/位移(shimmer 流光带、scroll/waterwaves/waterflow/
    ///   waterripple/foliagesway/shake 位移)。tint/opacity/pulse 是逐像素一致的颜色运算,1×1 输入即可,不触发。
    private static func solidEffectCanvasSize(_ layer: LayerDesc, weEffects: WEEffectChain?) -> (Int, Int)? {
        guard layer.isSolid, !layer.frameBufferInput else { return nil }
        // 音频频谱 solidlayer 已由透明底图路径处理(见上)。
        if layer.effects.contains(where: { weEffects?.usesAudioSpectrum($0.weName) == true }) { return nil }
        // 非空间(逐像素一致)的纯颜色特效名:这些在 1×1 上即可,不需层尺寸画布。
        let uniformOnly: Set<String> = ["tint", "opacity", "pulse"]
        let hasSpatialFX = layer.effects.contains { eff in
            guard !eff.weName.isEmpty, weEffects?.has(eff.weName) == true else { return false }
            // opacity/tint 这类"逐像素一致"特效一旦绑了 opacitymask(MASK combo,如背景白 solidlayer 的
            //   opacity_mask 左透明右白)就变成**空间渐变** → 需层尺寸画布让 mask 逐像素生效;1×1 底会把 mask
            //   采样塌成单点 → 渐变丢失、整层均匀白(玛奇玛 3725148661 背景该是左暗右亮渐变露出黑 clearcolor、
            //   白时钟才在左侧深色上可见;1×1 时整层白 → 白字白底看不见)。无 mask 的 opacity/tint/pulse 仍 1×1。
            if eff.maskPath != nil { return true }
            return !uniformOnly.contains(eff.weName)
        }
        guard hasSpatialFX else { return nil }
        // 画布尺寸 = 层未缩放 size(lwe m_size);太薄/太小给个下限,保证流光带平滑(条 5×200 → 用 200 高足够,
        // 但宽 5px 经横向旋转方向特效时偏粗 → 给最小 64×256 的画布,不改 quad 几何/层位置,仅给特效更细的采样网格)。
        let sz = layer.sizePx ?? SIMD2(64, 256)
        let w = max(64, Int(sz.x.rounded()))
        let h = max(64, Int(sz.y.rounded()))
        // 上限防御:避免异常巨大的纯色层吃满显存(纯色画布本身无信息,大也无益)。
        return (min(2048, w), min(2048, h))
    }

    /// 纯色填充纹理(给**带空间特效的 solidlayer** 当 g_Texture0 用)。
    /// 普通无特效 solidlayer 用 1×1 白 + layer.color 即可;但 shimmer/scroll/waterwaves 等
    /// **空间特效**(用 v_TexCoord 产生沿层位置变化的图案,如 shimmer 沿条移动的流光带)需要一块
    /// **真实层尺寸**的画布才能产生空间变化——1×1 输入会把整层塌成单像素、特效无空间可施展(流光不动/不出)。
    /// 故这类层把纯色(rgb=color、a=1)烘进层尺寸纹理,特效在其上跑;合成色改用白(避免二次乘 color 变暗)。
    /// 对齐 lwe:solidlayer 渲染其 color 到自有 FBO 后再跑特效链(非把 color 留到末次合成)。
    private func solidColorTexture(width: Int, height: Int, color: SIMD3<Float>) -> MTLTexture? {
        let w = max(1, width), h = max(1, height)
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
        desc.usage = [.shaderRead]; desc.storageMode = .shared
        guard let t = device.makeTexture(descriptor: desc) else { return nil }
        let r = UInt8(max(0, min(255, Int((color.x * 255).rounded()))))
        let g = UInt8(max(0, min(255, Int((color.y * 255).rounded()))))
        let b = UInt8(max(0, min(255, Int((color.z * 255).rounded()))))
        var px = [UInt8](repeating: 0, count: w * h * 4)
        var i = 0
        while i < px.count { px[i] = r; px[i+1] = g; px[i+2] = b; px[i+3] = 255; i += 4 }
        px.withUnsafeBytes {
            t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0,
                      withBytes: $0.baseAddress!, bytesPerRow: w * 4)
        }
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
    /// ⚠ 文字纹理**不走** makeTexture 的 textureMaxDimension 质量下采样:那个上限是给大资源图省显存的,
    ///   文字纹理小且程序化生成,按屏上字高精确建分辨率(见 parseTextLayer renderPt);若被下采样到
    ///   512/1024(中/低画质)会把刚做清晰的字又压糊(=用户报的模糊在非默认画质下复现)。故文字直接上传原分辨率。
    ///   WP_TEXT_QUALITY_CAP=1 退回旧的「文字也吃画质下采样」(A/B 诊断)。
    private func makeTextTexture(_ desc: TextLayerDesc, loader: MTKTextureLoader, simTime: Double? = nil) -> (MTLTexture, Int, Int)? {
        guard let r = TextLayerRenderer.render(desc, simTime: simTime) else { return nil }
        if ProcessInfo.processInfo.environment["WP_TEXT_QUALITY_CAP"] != nil {
            guard let tex = makeTexture(.rgba8(pixels: r.pixels, width: r.width, height: r.height), loader: loader)
            else { return nil }
            return (tex, r.width, r.height)
        }
        // 直接按文字真实分辨率建纹理(绕过质量下采样),保住清晰度。
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                                                          width: r.width, height: r.height, mipmapped: false)
        td.usage = .shaderRead
        guard let tex = device.makeTexture(descriptor: td) else { return nil }
        r.pixels.withUnsafeBytes { raw in
            tex.replace(region: MTLRegionMake2D(0, 0, r.width, r.height), mipmapLevel: 0,
                        withBytes: raw.baseAddress!, bytesPerRow: r.width * 4)
        }
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

    /// 把编码图片(PNG/JPG)解成 RGBA8 像素。失败返回 nil。
    static func decodeEncodedRGBA(_ data: Data) -> (px: [UInt8], w: Int, h: Int)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let w = img.width, h = img.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (px, w, h)
    }

    /// WP_MASK_INVERT 实验用:把编码图片(PNG/JPG)解成 RGBA8 并反相(255−v,alpha 保留)。失败返回 nil。
    static func invertEncodedRGBA(_ data: Data) -> DecodedTex? {
        guard var r = Self.decodeEncodedRGBA(data) else { return nil }
        for i in stride(from: 0, to: r.px.count, by: 4) {
            r.px[i] = 255 &- r.px[i]; r.px[i+1] = 255 &- r.px[i+1]; r.px[i+2] = 255 &- r.px[i+2]
        }
        return .rgba8(pixels: r.px, width: r.w, height: r.h)
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

        // —— 粒子与图层按场景对象序交错(WE 按 scene.json objects 顺序绘制一切,粒子可在图层**之间**;
        //    旧「图层全画完再画全部粒子」让底层粒子浮顶,如 Postscript 鸟对象序[1]本应被人物盖住却飞人前)。
        //    anchorLayerIndex = 首个场景序在其后的图层下标:画 layers[a] **之前**冲刷锚 a 的组。
        //    分段所有权(encodeLweScene 分段 / bloom 上下两相位各调一次):本次调用冲刷锚∈(lo,hi],
        //    lo==0 时另含锚 0(垫底);空区间不冲刷。锚==hi 在段尾(=下一段首层之前)→ 段间不重不漏;
        //    particleFilter(bloom 上/下)互斥,两相位不会重画。WP_PARTICLES_ON_TOP=1 退回旧行为。
        let ring = frameIndex % Self.kBufferRing   // 审计修复#2:读本帧写入的那套缓冲(与 update 写入一致)
        let skipRope = ProcessInfo.processInfo.environment["WP_NO_ROPE"] != nil
        // 每组按自己的 parallaxDepth 平移投影(WE 鼠标视差,lwe CParticle::applyParallaxToModelMatrix)。
        // minimumParticleDepth=0.65(lwe CParticle.cpp:1864-1870):**仅粒子层** |depth| 不足 0.65 提到
        // ±0.65(保号);不钳则粒子鼠标视差比 WE 弱数倍(鸟 0.1→0.65、雪 -0.19→-0.65)。
        func particleProj(_ g: ParticleGroup) -> simd_float4x4 {
            var pd = g.parallaxDepth
            if abs(pd.x) < 0.65 { pd.x = pd.x < 0 ? -0.65 : 0.65 }
            if abs(pd.y) < 0.65 { pd.y = pd.y < 0 ? -0.65 : 0.65 }
            let off = parallaxOffset(depth: pd)
            return proj * matTranslate(off.x, off.y)
        }
        // anchor=nil → 画全部过滤后组(旧行为);否则只画锚在该下标的组。任一前置缺失安全跳过,绝不崩溃。
        func drawGroups(anchor: Int?) {
            guard drawParticles, !particleGroups.isEmpty,
                  pipelineParticleAdd != nil, pipelineParticleAlpha != nil else { return }
            var bound = false
            for g in particleGroups {
                if let a = anchor, g.anchorLayerIndex != a { continue }
                // parent 指向 composelayer 的粒子组**不进主场景**:它们渲进该 composelayer 的 child FBO
                // (encodeLweScene 在跑该层特效前单独画;见 GPULayer.childParticleGroupIndices)。
                if g.parentComposeLayerIndex != nil { continue }
                if g.isRefract { continue }   // 折射粒子采样整帧场景,单独 pass(encodeRefract)
                if let f = particleFilter, !f(ParticleGroupInfo(aboveBloom: g.aboveBloom)) { continue }
                if !bound {
                    // 状态自洽:图层循环每层改绑 @0/采样器/fragmentBytes,插画前重置粒子所需状态。
                    encoder.setFragmentSamplerState(sampler, index: 0)
                    encoder.setVertexBuffer(quadBuffer, offset: 0, index: 0)
                    var blankFx = EffectUniforms()   // 粒子走 scene_fragment:无效果 uniform,避免读脏数据
                    encoder.setFragmentBytes(&blankFx, length: MemoryLayout<EffectUniforms>.stride, index: 0)
                    bound = true
                }
                if g.isRope {
                    // rope 带状网格:三角形列表(每子段 6 顶点),顶点缓冲@2。WP_NO_ROPE:无头验证钩子。
                    guard !skipRope, g.ropeVertexCount >= 3, let buf = g.ropeBuffers[ring],
                          let pipeline = g.additive ? pipelineRopeAdd : pipelineRopeAlpha else { continue }
                    encoder.setRenderPipelineState(pipeline)
                    var projVar = particleProj(g)
                    encoder.setVertexBytes(&projVar, length: MemoryLayout<simd_float4x4>.stride, index: 1)
                    encoder.setVertexBuffer(buf, offset: 0, index: 2)
                    encoder.setFragmentTexture(g.texture, index: 0)
                    encoder.setFragmentTexture(g.texture, index: 1)   // 槽1 占位(rope hasMask=0 不会采)
                    encoder.setFragmentTexture(g.texture, index: 2)   // 槽2 占位(rope cursorRipple=0 不会采)
                    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: g.ropeVertexCount)
                } else {
                    guard g.instanceCount > 0, let buf = g.instanceBuffers[ring],
                          let pipeline = g.additive ? pipelineParticleAdd : pipelineParticleAlpha else { continue }
                    encoder.setRenderPipelineState(pipeline)
                    var projVar = particleProj(g)
                    encoder.setVertexBytes(&projVar, length: MemoryLayout<simd_float4x4>.stride, index: 1)
                    encoder.setVertexBuffer(buf, offset: 0, index: 2)
                    encoder.setFragmentTexture(g.texture, index: 0)
                    encoder.setFragmentTexture(g.texture, index: 1)   // 槽1 占位(粒子 hasMask=0 不会采)
                    encoder.setFragmentTexture(g.texture, index: 2)   // 槽2 占位(粒子 cursorRipple=0 不会采)
                    encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: g.instanceCount)
                }
            }
        }
        let liLo = layerRange?.lowerBound ?? 0
        let liHi = layerRange?.upperBound ?? layers.count

        // 图层(底图)。WP_HIDE_IDS=482,216,... 诊断:按 pkg id 隐藏指定图层(定位遮挡者)。
        // layerRange:A 交错路径下只画区间内图层(逐段累积进 sceneFBO);nil=全画(旧路径)。
        // 垫底粒子(首层之下)。layers 为空(纯粒子壁纸/WP_ONLY_IDS 隔离粒子:全部图层被父链隐藏
        // 不建 GPULayer)时所有组锚==layers.count==0,全靠这里画(曾因要求 liHi>0 → 隔离渲染全空)。
        // liHi>0 限制仅对非空 layers 保留:lweScene 首层即 composelayer 时段序 [0,0)+[0,j) 都以 liLo==0
        // 开头,无此限制锚 0 会被两段重画。
        if !Self.particlesOnTop, liLo == 0, liHi > 0 || layers.isEmpty { drawGroups(anchor: 0) }
        for li in liLo..<liHi {
            if !Self.particlesOnTop, li > liLo { drawGroups(anchor: li) }   // 序在 layers[li] 之前的粒子
            let layer = layers[li]
            guard drawLayers, layer.visible, !Self.hideLayerIds.contains(layer.id),
                  Self.onlyLayerIds.isEmpty || Self.onlyLayerIds.contains(layer.id) else { continue }
            // puppet 层:用单位空间 mesh 顶点 + 该层 mvp(proj×matModel)**直渲索引三角网格**(替代平面 quad),
            // 偏心/出界顶点不裁——照 lwe 把局部 puppet 顶点直接用场景投影渲(setupPuppetGeometryCallback)。
            // 非 puppet 层走原 quad 逻辑。
            let isPup = layer.puppetVB != nil && layer.puppetIB != nil
            // 每层重绑几何@0(材质路径会覆盖 index0/1,故不能只在循环外绑一次)。
            encoder.setVertexBuffer(isPup ? layer.puppetVB : quadBuffer, offset: 0, index: 0)
            func drawGeom() {
                if isPup, let ib = layer.puppetIB {
                    // puppet 剔除:眼睛闭合靠 3D 蒙皮(trs3D),默认不剔除(puppetCull=.none)。仅 WP_EYE_CULL
                    // 诊断时该层可能 .front/.back;画完立刻还原 .none(编码器状态共享,绝不能漏到后续主 puppet 龙/刀/头发)。
                    if layer.puppetCull != .none { encoder.setCullMode(layer.puppetCull) }
                    encoder.drawIndexedPrimitives(type: .triangle, indexCount: layer.puppetIndexCount,
                                                  indexType: .uint16, indexBuffer: ib, indexBufferOffset: 0)
                    if layer.puppetCull != .none { encoder.setCullMode(.none) }
                } else {
                    encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                }
            }
            // ⭐运行时动态建层(音频条 bar 模板):本层不画单 quad,而用同一贴图**多实例**渲染脚本每帧读回的
            //   每根 bar(barMVPs,update 里算好,含 alignment/origin/scale/angle)。颜色用本层 color(bar 材质
            //   tint = color × 白贴图);blend 走本层 colorBlendMode/blend(bar colorBlendMode=11 → framebuffer-fetch)。
            //   逐根设 VertexUniforms(各自 mvp)再 drawGeom。barMVPs 空(脚本失败/退化)→ 本帧不画(回退,不崩)。
            if layer.instancedBarsScript != nil {
                encoder.setFragmentSamplerState(samplerFor(layer.texFlags), index: 0)
                encoder.setFragmentTexture(layer.texture, index: 0)
                if layer.colorBlendMode > 0, let pcb = pipelineColorBlend {
                    encoder.setRenderPipelineState(pcb)
                    var mode = Int32(layer.colorBlendMode)
                    encoder.setFragmentBytes(&mode, length: MemoryLayout<Int32>.stride, index: 0)
                } else {
                    switch layer.blend {
                    case .normal:      encoder.setRenderPipelineState(pipelineNormal)
                    case .translucent: encoder.setRenderPipelineState(pipelineTranslucent)
                    case .additive:    encoder.setRenderPipelineState(pipelineAdditive)
                    }
                    var fx = makeEffectUniforms(hasMask: false, cursorRipple: false)
                    encoder.setFragmentBytes(&fx, length: MemoryLayout<EffectUniforms>.stride, index: 0)
                    encoder.setFragmentTexture(layer.texture, index: 1)
                    encoder.setFragmentTexture(layer.texture, index: 2)
                }
                for barMVP in layer.barMVPs {
                    var bu = VertexUniforms(mvp: barMVP, color: layer.color)
                    encoder.setVertexBytes(&bu, length: MemoryLayout<VertexUniforms>.stride, index: 1)
                    drawGeom()
                }
                continue
            }
            // fb 恒 0:frameBufferInput 层的 effectedTexture 现在已是**层 [0,1] 空间**结果(WEEffectChain.run 的
            // composelayer copy pass 把场景按 footprint 采进层 FBO,= lwe 首 copy pass),故按普通 quad UV(v.zw)
            // 渲层 quad 采样贴回 = lwe 末 pass(screen mvp 渲层 quad 采样特效结果)。不再有「整帧画布底图 + 画布 UV」自创路径。
            // 音频可视化 solidlayer:effectedTexture 自带逐像素 alpha(除曲线外透明),对象 alpha(常=0,基底填充
            //   透明)不应再乘进来——否则把曲线一并抹没。lwe 只把 g_Alpha 喂给声明它的 shader(audioline 没声明)
            //   → 对象 alpha 对曲线无效。故这类层合成用 color.w=1.0 保留逐像素 alpha(非强制输出不透明:透明区仍透明)。
            //   ⚠ RGB 也必须置白(非对象色):effectedTexture 已是 WE 特效自身着色的曲线(u_color×u_brightness),
            //   对象 color 是 solidlayer **基底填充色**(凯尔希×Mon3tr id=704 = 黑 "0 0 0"),特效链不消费它。
            //   若用对象黑色乘进合成(scene_fragment_blend 的 B = tex×in.color)→ 黑×曲线 = 全黑 → 整条波形被抹没
            //   (此层 colorBlendMode=31「A+B×o」叠加,B.rgb=0 时输出=背景=看不见,正是音频条完全不显示的真因)。
            let compositeColor = (layer.audioVizSelfAlpha && layer.effectedTexture != nil)
                ? SIMD4<Float>(1.0, 1.0, 1.0, 1.0)
                : layer.color
            var u = VertexUniforms(mvp: layer.mvp, color: compositeColor)
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
                                          audio: currentAudio) {   // 基础材质 AUDIOPROCESSING combo 频谱
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

        // 收尾粒子:
        // - 旧行为(WP_PARTICLES_ON_TOP):本相位全部过滤后组一次画完(覆盖图层之上)。
        // - 场景序插画(默认):只冲刷锚==liHi 的组(序在 layers[liHi-1] 之后、下一段首层之前;
        //   liHi==layers.count 时即全场顶层粒子)。空区间(liLo==liHi)不冲刷,避免与相邻段重画。
        if Self.particlesOnTop {
            drawGroups(anchor: nil)
        } else if liHi > liLo {
            drawGroups(anchor: liHi)
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
            // fb 恒 0:effectedTexture 现为层 [0,1] 空间,普通 quad UV 贴(见 encode 处说明)。
            var u = VertexUniforms(mvp: layer.mvp, color: layer.color)
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
            // puppet 层(多部件角色,如 556_puppet/凯尔希):必须用**单位空间 mesh 顶点 + 索引三角网格**
            // 直渲(同主 encode 路径 isPup 分支),否则把 puppet 的散布图集当平面 quad 画 → 头/身/手按图集
            // UV 散开。此前 compositeSceneBelow 只画平面 quad,导致「postProcess(bloom)壁纸 + frameBufferInput
            // composelayer + puppet 角色」(如 WLOP Chapter4 海报封面)的 composelayer 读到散架场景 → 叠出错位
            // 副本(头身分离)。与 encode 的 isPup 分支对齐。
            if layer.puppetVB != nil, let ib = layer.puppetIB {
                enc.setVertexBuffer(layer.puppetVB, offset: 0, index: 0)
                enc.drawIndexedPrimitives(type: .triangle, indexCount: layer.puppetIndexCount,
                                          indexType: .uint16, indexBuffer: ib, indexBufferOffset: 0)
                enc.setVertexBuffer(quadBuffer, offset: 0, index: 0)   // 还原 quad 供后续平面层
            } else {
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }
        }
        enc.endEncoding()
        return target
    }

    // (已删除自创 region-fit:regionTexPool / regionPixelRect / cropToRegion。
    //  composelayer 特效现忠实走 lwe composelayer copy pass(WEEffectChain.run sceneFootprint),
    //  在层自有 [0,1] FBO 内跑,不再裁场景/遮罩到 region。)

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
    private var fxDiagLogged = Set<String>()   // 特效链诊断:每层×特效只打一行日志
    /// 渲染审计日志(用户要求:每渲一个壁纸出一份日志,从日志定位错误)。
    /// load() 收尾把逐层结构化信息 + 加载期警告写到 /tmp/wp_render_audit.log(覆盖式,含 auditTag)。
    var auditTag = ""                          // 调用方可设(workshop id / 名称),空也能用
    private var auditLines: [String] = []      // 加载期各决策点追加的警告/说明(⚠️/ℹ️ 前缀,grep 友好)
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
            // **忠实移植 lwe(CImage.cpp:785-853 + composelayer.vert/.frag,逐行核对)**:composelayer 的材质贴图
            // 槽 0 = _rt_FullFrameBuffer(完整场景主 FBO),其首 copy pass(passthrough 几何,m_modelViewProjectionCopy
            // = screen mvp)按**该层屏幕投影位置**把场景采样进**该层尺寸**的自有 [0,1] FBO,之后各 effect pass 在该 FBO
            // 内全屏跑,末 pass 用 screen mvp 把结果渲回场景 FBO。我方 encode 已等价末 pass(按 layer.mvp 渲层 quad
            // 采样 effectedTexture),故这里只需把**完整场景 FBO + footprint(layer.mvp)+ 层尺寸**喂给 run,由 run 的
            // composelayer copy pass(WEEffectChain.run sceneFootprint)产出层 [0,1] 空间的特效结果。
            // 位移特效(cloudmotion/shake)由此读到的是该层 region 内的场景邻域(与 lwe 一致),不再裁场景小图→无接缝/暗带。
            var footprint: (mvp: simd_float4x4, outW: Int, outH: Int)? = nil
            if layers[i].frameBufferInput {
                let scene = sceneInput ?? compositeSceneBelow(upTo: i, commandBuffer: cmd) ?? current
                current = scene
                // 层自有 FBO 尺寸 = **未缩放原始 size**(lwe CImage.cpp:239 m_size + :278-283 FBO={size.x,size.y})。
                // scale 只作用于 quad/mvp 几何(把 FBO 拉伸贴到屏幕),**不进 FBO 像素尺寸**。此前误用 sizePx(=size×scale)
                // → 各向异性 scale 把 FBO 拉扁 → g_Texture0Resolution 错 → Simple_Audio_Bars 的 i_DCorrectingFactor 错
                // → 条宽被压扁(下音条 scale=3.91 → 条挤成细栅栏)。改用 rawSizePx 严格对齐 lwe。
                let sp = layers[i].rawSizePx
                footprint = (mvp: layers[i].mvp, outW: max(1, Int(sp.x.rounded())), outH: max(1, Int(sp.y.rounded())))
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
                // 特效链一次性诊断日志(每层×特效只打一行,不刷屏):处置结果落 /tmp/livewallpaper.log,
                // 供「用日志判断特效有没有跑」(用户方针:日志优先,截图兜底)。
                let diagKey = "\(layers[i].id)#\(ei)#\(eff.weName)"
                func fxDiag(_ status: String) {
                    if fxDiagLogged.insert(diagKey).inserted {
                        Log.write("FXDIAG layer=\(layers[i].id) fx[\(ei)]=\(eff.weName) -> \(status)")
                    }
                }
                // 跳过未被转译覆盖 / denylist 的特效(如 cursorripple 走 CursorRippleSim)。
                // 音频条层:Simple_Audio_Bars(据 currentAudio16 画条)+ perspective(透视)都在此跑。
                guard we.has(eff.weName), !Self.weDenied.contains(eff.weName) else {
                    fxDiag(we.has(eff.weName) ? "SKIP-denylist" : "SKIP-no-manifest")
                    continue
                }
                if Self.fxSkip.contains(eff.weName) { fxDiag("SKIP-env"); continue }   // 诊断:WP_SKIP_FX 跳过
                // 逐特效辅助贴图:weAux 的 slot → g_Texture<slot>(WE pass.textures[N] → 采样器 g_TextureN)。
                // 这统一了 opacitymask/法线/相位/流向等所有辅助槽,取代旧的单一 maskTexture 机制。
                // 辅助贴图(opacitymask/法线/流向等)按其 [0,1] UV 直接绑 g_Texture<slot> —— lwe 里 effect frag
                // 用与 g_Texture0 同一 v_TexCoord(层 [0,1])采样它们(CPass setupUniforms 无区域裁剪),故不裁。
                // (此前 regionFit 把全画布遮罩裁到 region = 配合自创裁场景路径,lwe 无此步,已随 region-fit 一并删。)
                var auxTextures: [String: MTLTexture] = [:]
                if ei < auxes.count {
                    for (slot, tex) in auxes[ei] {
                        auxTextures["g_Texture\(slot)"] = tex
                    }
                }
                // freeimage 容器≠内容的辅助贴图:g_Texture<slot>Resolution 按 .tex 头喂(容器,内容)= 真 WE 采样行为。
                var auxResolutions: [String: SIMD4<Float>] = [:]
                if ei < layers[i].effectAuxRes.count {
                    for (slot, r) in layers[i].effectAuxRes[ei] { auxResolutions["g_Texture\(slot)Resolution"] = r }
                }
                // 真实 flags → 采样器:g_Texture0 = 图层贴图(仅首个特效跑时);辅助槽 = 各自 .tex 的 flags。
                // (遮罩在图层路径走 auxTextures 同一通道,故其 flags 已包含在 auxFlags 里;无独立 maskTexture。)
                var flagsMap: [String: TexFlags] = [:]
                if let pf = primaryFlags { flagsMap["g_Texture0"] = pf }
                if ei < auxFlags.count { for (slot, f) in auxFlags[ei] { flagsMap["g_Texture\(slot)"] = f } }
                // 需要整帧底图的特效(frame_builder 的 g_Texture3=_rt_FullFrameBuffer):喂「该层之下
                // 已合成场景」底图。暂用 sceneBelowTex(下方),空则退该层输入(仍非白,不会冲白)。
                let fb: MTLTexture? = we.needsFrameBuffer(eff.weName) ? (sceneBelowForEffects ?? layers[i].texture) : nil
                // footprint 只用于**链中第一个跑的特效**:其 input 是完整场景 FBO,由 run 的 composelayer copy
                // pass 转成层 [0,1] 空间(lwe 首 copy pass);之后 current 已是层空间输出 → footprint=nil(后续特效
                // 在层 FBO 内全屏跑,对齐 lwe effect 各 pass)。
                let runOut = we.run(effect: eff.weName, input: current,
                                    pkgParams: eff.weParams as [String: Any],
                                    combos: eff.weCombos as [String: Any],
                                    auxTextures: auxTextures,
                                    auxResolutions: auxResolutions,
                                    texFlags: flagsMap,
                                    paramsPerPass: eff.weParamsPerPass.map { $0 as [String: Any] },
                                    time: currentTime, cursor: cursorUV,
                                    audio: currentAudio, frameBuffer: fb,
                                    sceneFootprint: footprint,
                                    pointerXform: pointerXform(forLayer: i),
                                    commandBuffer: cmd)
                if let out = runOut {
                    fxDiag("RAN combos=\(eff.weCombos)")
                    current = out
                    primaryFlags = nil   // 后续特效的输入是上一特效的全屏输出 → clamp+linear
                    footprint = nil      // copy 已发生,后续特效用层空间输入(全 [0,1])
                } else {
                    fxDiag("FAIL-run-nil(无变体命中?) combos=\(eff.weCombos)")
                }
            }
            layers[i].effectedTexture = (current !== layers[i].texture) ? current : nil
    }

    /// 把屏幕 UV pointer(cursorUV,y 向上)变换到该层 effect 的 texcoord 空间的仿射系数 (ax,bx,ay,by):
    ///   feed.x = ax·cursor.x+bx,feed.y = ay·cursor.y+by。effect 跑在该层的缩放 quad 上(texcoord 0-1 = 缩放
    ///   quad ≠ 画布);层 scale≠1 或 origin 偏心时不校正,xray 揭示框 / depthparallax 会按未缩放定位 → 随距
    ///   中心放大偏移(实测 3605892961 层 scale=1.3 → 揭示框偏 1.3×)。全画布层 = (1,0,-1,1) → 退回
    ///   [cursor.x,1-cursor.y] 零回归。WP_NO_POINTER_SCALE_FIX=1 退回。
    private func pointerXform(forLayer i: Int) -> SIMD4<Float> {
        guard ProcessInfo.processInfo.environment["WP_NO_POINTER_SCALE_FIX"] == nil,
              i >= 0, i < layers.count else { return SIMD4(1, 0, -1, 1) }
        let sp = layers[i].sizePx, og = layers[i].origin
        guard sp.x > 0, sp.y > 0, canvas.x > 0, canvas.y > 0 else { return SIMD4(1, 0, -1, 1) }
        // feed.x = (cursor.x·canvas.x − og.x)/sp.x + 0.5(光标在 quad 内的 texcoord u);
        // feed.y = 0.5 − (cursor.y·canvas.y − og.y)/sp.y(y 向上→texcoord v 翻)。og=originPx(y 向上),sp=size×scale。
        return SIMD4(canvas.x / sp.x, 0.5 - og.x / sp.x,
                     -canvas.y / sp.y, 0.5 + og.y / sp.y)
    }

    /// 把整帧(图层 + 非折射粒子 → [折射粒子] → [后处理])渲染进 finalTarget。
    /// 实时与离屏共用,保证两条路一致。
    // MARK: - 3D 透视场景渲染(.mdl 模型)

    // 与 Metal shader `struct U3` 内存布局一致:
    //  mvp(64) + model(64) + lightVP(64) + color(float3=16含pad,brightness填pad) + alpha
    //  + lightDir(float3=16含pad,lit填pad) + ambient + shadowStrength + pad0 + pad1。
    private struct U3GPU {
        var mvp: simd_float4x4 = matrix_identity_float4x4
        var model: simd_float4x4 = matrix_identity_float4x4
        var lightVP: simd_float4x4 = matrix_identity_float4x4
        var color: SIMD3<Float> = SIMD3(1, 1, 1); var brightness: Float = 1; var alpha: Float = 1
        var lightDir: SIMD3<Float> = SIMD3(-1, 0, 0); var lit: Float = 0
        var ambient: Float = 0.18; var shadowStrength: Float = 0.7; var pad0: Float = 0; var pad1: Float = 0
    }

    /// 解析并上传 3D 模型(几何 GPU 缓冲 + baseColor 纹理 + 世界矩阵)。
    private func build3DModels(source: SceneSource, loader: MTKTextureLoader) {
        guard let rt = Scene3DRuntime(source: source) else { models3D = []; return }
        // 脚本 sim 用 stub thisScene/thisLayer 非完全保真,逐帧 live 的相机取景反而更差(土星跑到角落);
        // 而**烘焙到 settled 时刻**(顺序跑脚本到 t≈20s)取景最佳(土星居中、环倾斜、太阳反光)。
        // 土星本就近静态(自转 10.5h/圈),定格 settled 视图是最佳折中。WP_3D_TIME 调时刻;WP_3D_LIVE=1 试逐帧。
        // 模型烘焙到 settled 时刻(居中好构图;土星自转 10.5h/圈,逐帧模型无可见运动反而相机漂移)。
        // 但**宿主逐帧 tick**(脚本≤200=土星)→ HUD 文字(时钟/距离/角度)live 更新;模型世界保持烘焙(render3D 不重算模型)。
        // WP_NO_3D_LIVE=1 退回全冻结。WP_3D_LIVE_MODELS=1 让模型也逐帧(取景会漂,调试用)。
        scene3DPerFrame = ProcessInfo.processInfo.environment["WP_NO_3D_LIVE"] == nil && rt.scriptCount <= 200
        // 入场动画(土星):脚本数少(非日心太阳系公转)且模型祖先链含 origin/angles 关键帧脚本(从下升起+倾入再 hold)
        //   → 从 t=0 起逐帧驱动模型(相机静态,动模型不漂);脚本在末关键帧后 hold=settled。WP_NO_3D_INTRO 退回烘焙冻结。
        // 排除:日心太阳系(脚本>200=scene3DPerFrame 已 false,且其行星 origin 无脚本走 getLayer 公转)、纯静态 3D(无关键帧脚本)。
        scene3DIntroModels = !noIntro && scene3DPerFrame && rt.hasModelKeyframeAnim
        // 烘焙时刻:入场动画从 t=0 起算(模型逐帧从底部升起);否则旧路径烘焙到 settled(默认 20s,WP_3D_TIME 调)。
        let bakeT: Double = scene3DIntroModels ? 0.0 : (ProcessInfo.processInfo.environment["WP_3D_TIME"].flatMap { Double($0) } ?? 20.0)
        scene3DBakeTime = bakeT
        // settled 时刻(末关键帧 t,如土星=30);此后停刷模型省 CPU(脚本本就 hold)。算不出(0)→ 给个保险上限永不停。
        let settle = rt.modelAnimEndTime
        scene3DIntroSettle = settle > 0 ? settle : .greatestFiniteMagnitude
        if scene3DIntroModels { Log.write("3D intro animation: 模型从 t=0 升起, settle=\(settle)s (scripts=\(rt.scriptCount))") }
        // 持续自转(土星行星/环/陨石绕 Y 轴恒转;祖先链 angles 脚本用 engine.frametime 累积无终点):
        //   入场 settle 后**仍逐帧 recompute** → 环不冻结(相机静态不漂)。WP_NO_RING_ANIM 退回旧冻结行为对照。
        scene3DContinuousSpin = !noRingAnim && scene3DPerFrame && rt.hasContinuousModelRotation
        if scene3DContinuousSpin { Log.write("3D continuous spin: 模型持续自转(settle 后仍逐帧 recompute)") }
        rt.bake(toTime: bakeT)
        rt.recompute()
        // 日心太阳系模拟(VSOP87D Main 写 shared.currentFocus)→ 逐帧 tick+recompute+刷新模型世界矩阵 → 行星绕太阳公转
        // (R4 缺口修复)。相机固定看原点、内容随时间公转故不漂(与土星不同)。⚠ 只认 currentFocus 精确区分:土星
        // (3589454154)也有 getLayer 脚本但其相机授权漂移,必须排除。**bake/recompute 后判**(脚本已跑、shared 已写
        // currentFocus;放 bake 前 shared 还空判不出)。WP_NO_SOLAR_ORBIT=1 退回烘焙冻结(零回归对照)。
        scene3DSolarOrbit = !noSolarOrbit && rt.sharedHas("currentFocus")
        if scene3DSolarOrbit {
            scene3DPerFrame = ProcessInfo.processInfo.environment["WP_NO_3D_LIVE"] == nil   // 覆盖脚本>200 的冻结
            Log.write("3D solar-orbit: 逐帧公转开启 (scripts=\(rt.scriptCount))")
        }
        // 条件 UI(灵动岛/通知/媒体面板)靠 visible 脚本显隐;静态壁纸无交互→脚本判隐藏→其子层(边框等)随之隐。
        scene3DHidden = rt.hiddenNodeIds()
        if !scene3DHidden.isEmpty { Log.write("3D hidden nodes(visible脚本判false): \(scene3DHidden.count)个") }
        if ProcessInfo.processInfo.environment["WP_3D_DUMP"] != nil {
            // 诊断:写 shared 全量 JSON + 每个模型 world 的平移/缩放(判行星是 scale=0 还是位置在屏外)
            try? rt.sharedJSON().write(toFile: "/tmp/solar_shared.json", atomically: true, encoding: .utf8)
            for m in rt.models {
                guard let w = rt.worldsById[m.id] else { continue }
                let t = w.columns.3
                let sx = simd_length(SIMD3(w.columns.0.x, w.columns.0.y, w.columns.0.z))
                let sy = simd_length(SIMD3(w.columns.1.x, w.columns.1.y, w.columns.1.z))
                let sz = simd_length(SIMD3(w.columns.2.x, w.columns.2.y, w.columns.2.z))
                Log.write("MODEL id=\(m.id) \(m.name) pos=(\(t.x),\(t.y),\(t.z)) scale=(\(sx),\(sy),\(sz))")
            }
        }
        if ProcessInfo.processInfo.environment["WP_3D_HUD_LOG"] != nil {
            Log.write("3D host shared: \(rt.sharedDump)")
            Log.write("3D uiRoots=\(rt.uiRoots)")
            for (lid, lname) in [(597,"clock"),(586,"Volume"),(697,"DATE"),(749,"dis"),(757,"ang"),(605,"26.73"),(466,"dock_r1"),(713,"Voyager")] {
                let scr = rt.isScreenLayer(lid)
                let pos = scr ? rt.canvasOrigin(lid) : SIMD2(rt.worldsById[lid]?.columns.3.x ?? 0, rt.worldsById[lid]?.columns.3.y ?? 0)
                Log.write("3D layer id=\(lid) \(lname): screen=\(scr) pos=(\(pos.x),\(pos.y)) text='\(rt.textValue(id: lid) ?? "")'")
            }
        }
        scene3DRuntime = rt
        scene3DLastTime = 0
        let objs = rt.models
        var texCache: [String: MTLTexture] = [:]
        func loadTex(_ path: String?) -> MTLTexture? {
            guard let path = path else { return nil }
            if let t = texCache[path] { return t }
            guard let blob = source.data(for: path), let dec = TexDecoder.decodeFirstMipWithFlags(blob),
                  let t = makeTexture(dec.tex, loader: loader) else {
                if ProcessInfo.processInfo.environment["WP_3D_DUMP"] != nil { Log.write("TEX FAIL: \(path)") }
                return nil
            }
            if ProcessInfo.processInfo.environment["WP_3D_DUMP"] != nil {
                if case let .rgba8(px, w, h) = dec.tex, !px.isEmpty {
                    var aMin = 255, aMax = 0, rgbMax = 0
                    var i = 0; while i < px.count { aMin = min(aMin, Int(px[i+3])); aMax = max(aMax, Int(px[i+3]))
                        rgbMax = max(rgbMax, Int(px[i]), Int(px[i+1]), Int(px[i+2])); i += 4 * 97 }
                    Log.write("TEX \(path): \(w)x\(h) rgba8 alpha[\(aMin)-\(aMax)] rgbMax=\(rgbMax)")
                } else { Log.write("TEX \(path): encoded(PNG/JPG)") }
            }
            texCache[path] = t; return t
        }
        let solo = ProcessInfo.processInfo.environment["WP_3D_SOLO"]
        var out: [Model3DGPU] = []
        for o in objs {
            if let solo = solo, !solo.isEmpty, !o.name.contains(solo) { continue }   // 诊断:只渲名字含 solo 的模型
            let inter = o.geometry.interleaved()
            guard !inter.isEmpty, !o.geometry.indices.isEmpty,
                  let vb = device.makeBuffer(bytes: inter, length: inter.count * 4, options: .storageModeShared),
                  let ib = device.makeBuffer(bytes: o.geometry.indices, length: o.geometry.indices.count * 4, options: .storageModeShared)
            else { continue }
            var subs: [Submesh3DGPU] = []
            for (i, sm) in o.geometry.submeshes.enumerated() {
                let mat = i < o.materials.count ? o.materials[i] : (o.materials.first ?? Model3DMaterial())
                subs.append(Submesh3DGPU(mat: Material3DGPU(tex: loadTex(mat.baseColorTex), color: mat.color,
                                          brightness: mat.brightness, alpha: mat.alpha, translucent: mat.translucent,
                                          lighting: mat.lighting),
                                          start: sm.indexStart, count: sm.indexCount))
            }
            // 行星(球体01)= 受光体(N·L + 接收环影);环/陨石 = caster。
            let lit = (rt.planetModelId == o.id)
            let caster = (rt.ringModelId == o.id) || (o.meshPath.contains("陨石"))
            out.append(Model3DGPU(id: o.id, vb: vb, ib: ib, world: o.world, submeshes: subs, lit: lit, castsShadow: caster))
            if ProcessInfo.processInfo.environment["WP_3D_DUMP"] != nil {
                for (i, sm) in o.geometry.submeshes.enumerated() {
                    let mat = i < o.materials.count ? o.materials[i] : Model3DMaterial()
                    Log.write("MAT id=\(o.id) \(o.name) sm[\(i)] matPath=\(sm.material) tex=\(mat.baseColorTex ?? "nil") texLoaded=\(loadTex(mat.baseColorTex) != nil) color=\(mat.color) bright=\(mat.brightness) alpha=\(mat.alpha) translucent=\(mat.translucent) lighting=\(mat.lighting)")
                }
            }
        }
        models3D = out
        // 方向光阴影(土星 directionalshadow=1):光源朝向 + 正交阴影相机 view·proj。
        // 太阳系等无行星/环或被 WP_NO_RING_SHADOW 关闭 → scene3DHasShadow=false,零影响。
        scene3DHasShadow = false
        if ProcessInfo.processInfo.environment["WP_NO_RING_SHADOW"] == nil,
           pipeline3DShadow != nil, rt.directionalLightId != nil, rt.planetModelId != nil,
           out.contains(where: { $0.lit }), out.contains(where: { $0.castsShadow }) {
            let dir = rt.sunWorldDirection()              // 指向太阳
            let center = rt.planetCenterWorld()
            let radius = max(0.5, rt.planetWorldRadius())
            scene3DLightDir = dir
            // 正交阴影相机:从行星沿 +dir(太阳侧)退到 eye,看向中心;盒半径覆盖行星+环范围。
            let ortho = max(radius * 4.0, 4.0)
            let eye = center + dir * (ortho * 1.5)
            var up = SIMD3<Float>(0, 1, 0)
            if abs(simd_dot(simd_normalize(dir), up)) > 0.95 { up = SIMD3(0, 0, 1) }
            let lv = matLookAtRH(eye: eye, center: center, up: up)
            let lp = matOrthoRH(halfW: ortho, halfH: ortho, nearZ: 0.01, farZ: ortho * 3.0)
            scene3DLightVP = lp * lv
            scene3DHasShadow = true
            if shadowMapTex == nil {
                let sd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float,
                          width: Self.shadowMapSize, height: Self.shadowMapSize, mipmapped: false)
                sd.usage = [.renderTarget, .shaderRead]; sd.storageMode = .private
                shadowMapTex = device.makeTexture(descriptor: sd)
            }
            Log.write("3D shadow: dir=\(dir) center=\(center) r=\(radius) ortho=\(ortho) casters=\(out.filter{$0.castsShadow}.map{$0.id}) lit=\(out.filter{$0.lit}.map{$0.id}) point433visible=\(rt.pointLightVisible)")
        }
        // 太阳辉光精灵纹理(image 是材质 json → textures[0] → .tex)
        sunSpriteTex.removeAll()
        for sp in rt.sunSprites where !sp.image.isEmpty {
            // image 是 model 包装({material:"materials/..."}) → 取真材质路径再 resolveMaterial。
            var matPath = sp.image
            if let d = source.data(for: sp.image),
               let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
               let m = j["material"] as? String { matPath = m }
            let mat = Scene3DRuntime.resolveMaterial(path: matPath, source: source)
            if let t = loadTex(mat.baseColorTex) { sunSpriteTex[sp.id] = t }
        }
        if whiteTex3D == nil {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
            whiteTex3D = device.makeTexture(descriptor: d)
            var px: [UInt8] = [255, 255, 255, 255]
            whiteTex3D?.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &px, bytesPerRow: 4)
        }
    }

    /// 渲染 3D 模型:透视相机 + 深度缓冲。两遍:不透明(写深度)→ 透明(只读深度、alpha 混合)。
    private func render3D(commandBuffer cmd: MTLCommandBuffer, finalTarget: MTLTexture) {
        // 逐帧 live(土星):从 bakeTime+elapsed 续 tick 宿主 → HUD 文字(时钟/距离/角度)live 跳。
        // 模型世界**保持烘焙**(取景稳定;土星自转 10.5h/圈逐帧无可见变化、相机 smoothing 逐帧反而漂)——
        // 除非 WP_3D_LIVE_MODELS 调试。太阳系(脚本>200)烘焙冻结跳过。
        if scene3DPerFrame, let rt = scene3DRuntime {
            let t = scene3DBakeTime + Double(currentTime)
            let dt = max(0.0, min(0.1, t - scene3DLastTime)); scene3DLastTime = t
            rt.tick(time: t, dt: dt)
            // 逐帧 recompute + 刷新模型世界矩阵的三类场景:
            //   ①日心太阳系(R4,scene3DSolarOrbit):行星按 Main 写回的 origin/scale 绕太阳公转(相机固定看原点不漂)。
            //   ②入场动画(土星,introActive):模型从底部升起+倾入到 settled(相机静态不漂);settled(currentTime>末
            //     关键帧 t)后停刷。WP_3D_LIVE_MODELS 调试时对任何 3D 场景逐帧刷新。
            //   ③持续自转(土星行星/环/陨石,scene3DContinuousSpin):祖先链 angles 脚本 frametime 累积绕 Y 恒转,
            //     **settle 后仍逐帧 recompute**(相机静态不漂)→ 环不冻结。稳态环约 0.76°/s。WP_NO_RING_ANIM 退回冻结。
            let introActive = scene3DIntroModels && Double(currentTime) <= scene3DIntroSettle + 0.5
            if scene3DSolarOrbit || introActive || scene3DContinuousSpin || scene3DLiveModels {
                rt.recompute()
                for i in models3D.indices { if let wm = rt.worldsById[models3D[i].id] { models3D[i].world = wm } }
            }
        }
        let w = finalTarget.width, h = finalTarget.height
        if canvas.x > 0, canvas.y > 0, w > 0, h > 0 {
            let k = (canvas.x / canvas.y) / (Float(w) / Float(h))
            // cover(默认):填满屏幕+裁切(画布比屏宽→裁掉左右)。fit:整张壁纸缩进屏幕+留黑边
            //   (画布比屏宽→上下留黑边)。内屏长宽比(如 16:10)≠ 壁纸(16:9)时,cover 会裁掉壁纸
            //   边缘的特效(右上角鸟群/文字);fit 让它们在内屏也全可见,代价是黑边。WE 默认是 cover。
            switch PreferencesStore.shared.wallpaperScaleMode {
            case 1: ndcScale = k >= 1 ? SIMD2(1, 1 / k) : SIMD2(k, 1)
            case 2: ndcScale = SIMD2(1, 1)
            default: ndcScale = k >= 1 ? SIMD2(k, 1) : SIMD2(1, 1 / k)
            }
        } else { ndcScale = SIMD2(1, 1) }
        if depthTex3D == nil || depthTex3D!.width != w || depthTex3D!.height != h {
            let dd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: w, height: h, mipmapped: false)
            dd.usage = .renderTarget; dd.storageMode = .private
            depthTex3D = device.makeTexture(descriptor: dd)
        }
        // ── 阴影投影 pass(土星方向光环影):caster(环/陨石)深度→光源正交相机 ──
        if scene3DHasShadow, let shadowPL = pipeline3DShadow, let smap = shadowMapTex {
            let sp = MTLRenderPassDescriptor()
            sp.depthAttachment.texture = smap
            sp.depthAttachment.loadAction = .clear
            sp.depthAttachment.clearDepth = 1.0
            sp.depthAttachment.storeAction = .store
            if let senc = cmd.makeRenderCommandEncoder(descriptor: sp) {
                senc.label = "scene3d-shadow"
                senc.setRenderPipelineState(shadowPL)
                senc.setDepthStencilState(depthState3DWrite)
                for m in models3D where m.castsShadow {
                    var su = U3GPU(); su.model = m.world; su.lightVP = scene3DLightVP
                    senc.setVertexBuffer(m.vb, offset: 0, index: 0)
                    senc.setVertexBytes(&su, length: MemoryLayout<U3GPU>.stride, index: 1)
                    for s in m.submeshes {
                        senc.drawIndexedPrimitives(type: .triangle, indexCount: s.count, indexType: .uint32,
                                                   indexBuffer: m.ib, indexBufferOffset: s.start * 4)
                    }
                }
                senc.endEncoding()
            }
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = finalTarget
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = clearColor
        pass.depthAttachment.texture = depthTex3D
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = 1.0
        pass.depthAttachment.storeAction = .dontCare
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass),
              let opaque = pipeline3DOpaque, let blend = pipeline3DBlend else { return }
        enc.label = "scene3d"
        var ndc = ndcScale
        let shadowTex = scene3DHasShadow ? shadowMapTex : nil
        for translucentPass in [false, true] {
            enc.setRenderPipelineState(translucentPass ? blend : opaque)
            enc.setDepthStencilState(translucentPass ? depthState3DNoWrite : depthState3DWrite)
            enc.setVertexBytes(&ndc, length: 8, index: 3)
            enc.setFragmentSamplerState(sampler, index: 0)
            for m in models3D {
                let mvp = viewProj3D * m.world
                enc.setVertexBuffer(m.vb, offset: 0, index: 0)
                // 阴影贴图槽(texture 1):受光行星才绑(否则绑兜底白阴影图避免未绑采样)。
                enc.setFragmentTexture(shadowTex, index: 1)
                for s in m.submeshes where s.mat.translucent == translucentPass {
                    var u = U3GPU(mvp: mvp, model: m.world, color: s.mat.color,
                                  brightness: s.mat.brightness, alpha: s.mat.alpha)
                    if m.lit && scene3DHasShadow {
                        u.lit = 1; u.lightDir = scene3DLightDir; u.lightVP = scene3DLightVP
                        // 可调(诊断/微调):WP_3D_AMBIENT 暗面底光、WP_3D_SHADOW_STR 环影暗度;
                        // WP_3D_SHADOW_ONLY=1 把 N·L 关掉(ambient=1)只看环影带落点。
                        let env = ProcessInfo.processInfo.environment
                        if let a = env["WP_3D_AMBIENT"].flatMap({ Float($0) }) { u.ambient = a }
                        if let s2 = env["WP_3D_SHADOW_STR"].flatMap({ Float($0) }) { u.shadowStrength = s2 }
                        if env["WP_3D_SHADOW_ONLY"] != nil { u.ambient = 1 }
                    }
                    enc.setVertexBytes(&u, length: MemoryLayout<U3GPU>.stride, index: 1)
                    enc.setFragmentBytes(&u, length: MemoryLayout<U3GPU>.stride, index: 1)
                    enc.setFragmentTexture(s.mat.tex ?? whiteTex3D, index: 0)
                    enc.drawIndexedPrimitives(type: .triangle, indexCount: s.count, indexType: .uint32,
                                              indexBuffer: m.ib, indexBufferOffset: s.start * 4)
                }
            }
        }
        enc.endEncoding()
    }

    private func renderOrbits(cmd: MTLCommandBuffer, sceneTex: MTLTexture, finalTarget: MTLTexture, rt: Scene3DRuntime, pipeline: MTLRenderPipelineState) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = finalTarget
        pass.colorAttachments[0].loadAction = .dontCare    // 全屏三角形覆盖,内部读 sceneTex 合成
        pass.colorAttachments[0].storeAction = .store
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.label = "orbit"
        enc.setRenderPipelineState(pipeline)
        guard let inner = rt.orbitLayers.first(where: { $0.inner }) else { enc.endEncoding(); return }
        let id = inner.id
        func u1(_ m: String) -> Float { rt.orbitUniform(id, m, comps: 1).first ?? 0 }
        func u3(_ m: String) -> SIMD3<Float> { let v = rt.orbitUniform(id, m, comps: 3); return SIMD3(v[0], v.count > 1 ? v[1] : 0, v.count > 2 ? v[2] : 0) }
        var u = OrbitUGPU()
        u.lineOpacity = u1("Line Opacity"); u.globalScale = u1("Global Scale")
        u.trailEnable = u1("Trail Enable"); u.maxAB = u1("Max AB")
        u.rotation = u3("Rotation")
        u.originX = u1("Origin X"); u.originY = u1("Origin Y"); u.originZ = u1("Origin Z")
        u.p1A = u3("[P1] OrbitA"); u.p1B = u3("[P1] OrbitB")
        u.p2A = u3("[P2] OrbitA"); u.p2B = u3("[P2] OrbitB")
        u.p3A = u3("[P3] OrbitA"); u.p3B = u3("[P3] OrbitB")
        u.p4A = u3("[P4] OrbitA"); u.p4B = u3("[P4] OrbitB")
        let w = Float(finalTarget.width), h = Float(finalTarget.height)
        u.texRes = SIMD4(w, h, 1 / w, 1 / h)
        if ProcessInfo.processInfo.environment["WP_ORBIT_LOG"] != nil {
            Log.write("orbit id=\(id) lineOp=\(u.lineOpacity) maxAB=\(u.maxAB) gScale=\(u.globalScale) rot=\(u.rotation) p3A=\(u.p3A) p3B=\(u.p3B)")
        }
        enc.setFragmentBytes(&u, length: MemoryLayout<OrbitUGPU>.stride, index: 0)
        enc.setFragmentTexture(sceneTex, index: 0)
        enc.setFragmentSamplerState(sampler, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }

    private func renderOrbits2(cmd: MTLCommandBuffer, sceneTex: MTLTexture, finalTarget: MTLTexture, rt: Scene3DRuntime, pipeline: MTLRenderPipelineState) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = finalTarget
        pass.colorAttachments[0].loadAction = .dontCare; pass.colorAttachments[0].storeAction = .store
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.label = "orbit2"; enc.setRenderPipelineState(pipeline)
        guard let outer = rt.orbitLayers.first(where: { !$0.inner }) else { enc.endEncoding(); return }
        let id = outer.id
        func u1(_ m: String) -> Float { rt.orbitUniform(id, m, comps: 1).first ?? 0 }
        func u3(_ m: String) -> SIMD3<Float> { let v = rt.orbitUniform(id, m, comps: 3); return SIMD3(v[0], v.count > 1 ? v[1] : 0, v.count > 2 ? v[2] : 0) }
        var u = OrbitU2GPU()
        u.lineOpacity = u1("Line Opacity"); u.globalScale = u1("Global Scale")
        u.trailEnable = u1("Trail Enable"); u.maxAB = u1("Max AB")
        u.rotation = u3("Rotation")
        u.originX = u1("Origin X"); u.originY = u1("Origin Y"); u.originZ = u1("Origin Z")
        u.p5A = u3("[P5] OrbitA"); u.p5B = u3("[P5] OrbitB")
        u.p6A = u3("[P6] OrbitA"); u.p6B = u3("[P6] OrbitB")
        u.p7A = u3("[P7] OrbitA"); u.p7B = u3("[P7] OrbitB")
        u.p8A = u3("[P8] OrbitA"); u.p8B = u3("[P8] OrbitB")
        u.p9A = u3("[P9] OrbitA"); u.p9B = u3("[P9] OrbitB")
        let w = Float(finalTarget.width), h = Float(finalTarget.height)
        u.texRes = SIMD4(w, h, 1 / w, 1 / h)
        if ProcessInfo.processInfo.environment["WP_ORBIT_LOG"] != nil {
            Log.write("orbit2 id=\(id) lineOp=\(u.lineOpacity) maxAB=\(u.maxAB) p5A=\(u.p5A) p6A=\(u.p6A) p7A=\(u.p7A)")
        }
        enc.setFragmentBytes(&u, length: MemoryLayout<OrbitU2GPU>.stride, index: 0)
        enc.setFragmentTexture(sceneTex, index: 0)
        enc.setFragmentSamplerState(sampler, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }

    private func renderSunSprites(cmd: MTLCommandBuffer, target: MTLTexture, rt: Scene3DRuntime) {
        guard let pipeline = sunPipeline, !rt.sunSprites.isEmpty,
              ProcessInfo.processInfo.environment["WP_NO_SUN"] == nil else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .load; pass.colorAttachments[0].storeAction = .store
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.label = "sun"; enc.setRenderPipelineState(pipeline)
        let sizeMul = Float(ProcessInfo.processInfo.environment["WP_SUN_SIZE"] ?? "") ?? 0.24
        let bright = Float(ProcessInfo.processInfo.environment["WP_SUN_BRIGHT"] ?? "") ?? 1.8
        let aspect = Float(target.width) / Float(target.height)
        let flareMul = Float(ProcessInfo.processInfo.environment["WP_FLARE_SIZE"] ?? "") ?? 0.5
        let sunUV = rt.sunScreenUV()   // lens flare 定位在太阳屏幕处
        for sp in rt.sunSprites {
            guard let tex = sunSpriteTex[sp.id] else { continue }
            let uv = sp.isFlare ? sunUV : rt.spriteScreenUV(sp.id)
            var halfW: Float, halfH: Float
            if sp.isFlare {
                halfW = (sp.sizePx.x / 3840.0) * flareMul
                halfH = (sp.sizePx.y / 3840.0) * flareMul * aspect
                if sp.horizontal { halfW *= 8.0; halfH *= 0.6 }   // anamorphic 水平 streak:拉宽压扁
            } else {
                halfW = (sp.sizePx.x / 3840.0) * sizeMul
                halfH = halfW * aspect
            }
            var u = SunUGPU(centerUV: uv, sizeUV: SIMD2(halfW, halfH), brightness: bright, tint: SIMD3(1, 1, 1))
            if ProcessInfo.processInfo.environment["WP_ORBIT_LOG"] != nil {
                Log.write("sun id=\(sp.id) \(sp.name) flare=\(sp.isFlare) uv=\(uv) halfW=\(halfW)")
            }
            enc.setVertexBytes(&u, length: MemoryLayout<SunUGPU>.stride, index: 0)
            enc.setFragmentBytes(&u, length: MemoryLayout<SunUGPU>.stride, index: 0)
            enc.setFragmentTexture(tex, index: 0)
            enc.setFragmentSamplerState(sampler, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        enc.endEncoding()
    }

    private func renderGodrays(cmd: MTLCommandBuffer, sceneTex: MTLTexture, finalTarget: MTLTexture, rt: Scene3DRuntime) {
        guard let pipeline = godrayPipeline else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = finalTarget
        pass.colorAttachments[0].loadAction = .dontCare; pass.colorAttachments[0].storeAction = .store
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.label = "godray"; enc.setRenderPipelineState(pipeline)
        let on = ProcessInfo.processInfo.environment["WP_NO_GODRAY"] == nil
        let w = on ? (Float(ProcessInfo.processInfo.environment["WP_GODRAY_W"] ?? "") ?? 0.1) : 0
        let dens = Float(ProcessInfo.processInfo.environment["WP_GODRAY_DENSITY"] ?? "") ?? 0.85
        var g = GodUGPU(sunUV: rt.sunScreenUV(), weight: w, decay: 0.96, density: dens, exposure: 1.0)
        enc.setFragmentBytes(&g, length: MemoryLayout<GodUGPU>.stride, index: 0)
        enc.setFragmentTexture(sceneTex, index: 0)
        enc.setFragmentSamplerState(sampler, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }

    private func encodeFrame(commandBuffer cmd: MTLCommandBuffer, finalTarget: MTLTexture) {
        if has3DScene {
            // 有轨道显示层(太阳系 guidao):render3D → 中间纹理,轨道 shader 读它画椭圆 → finalTarget。
            if let rt = scene3DRuntime, !rt.orbitLayers.isEmpty, let orbitP = orbitPipeline,
               ProcessInfo.processInfo.environment["WP_NO_ORBIT"] == nil {
                let w = finalTarget.width, h = finalTarget.height
                if scene3DSceneTex == nil || scene3DSceneTex!.width != w || scene3DSceneTex!.height != h {
                    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: finalTarget.pixelFormat, width: w, height: h, mipmapped: false)
                    d.usage = [.renderTarget, .shaderRead]; d.storageMode = .private
                    scene3DSceneTex = device.makeTexture(descriptor: d)
                }
                if scene3DSceneTex2 == nil || scene3DSceneTex2!.width != w || scene3DSceneTex2!.height != h {
                    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: finalTarget.pixelFormat, width: w, height: h, mipmapped: false)
                    d.usage = [.renderTarget, .shaderRead]; d.storageMode = .private
                    scene3DSceneTex2 = device.makeTexture(descriptor: d)
                }
                if let sceneTex = scene3DSceneTex, let mid = scene3DSceneTex2 {
                    // 全程在中间纹理合成(避免读 drawable):render3D→sceneTex,内轨道→mid,外轨道→sceneTex,
                    // 太阳叠 composite,godrays 读 composite 写 finalTarget(最后一步;无 godray=weight 0 直通)。
                    render3D(commandBuffer: cmd, finalTarget: sceneTex)
                    var composite = sceneTex
                    if let outerP = orbit2Pipeline, rt.orbitLayers.contains(where: { !$0.inner }) {
                        renderOrbits(cmd: cmd, sceneTex: sceneTex, finalTarget: mid, rt: rt, pipeline: orbitP)
                        renderOrbits2(cmd: cmd, sceneTex: mid, finalTarget: sceneTex, rt: rt, pipeline: outerP)
                        composite = sceneTex
                    } else {
                        renderOrbits(cmd: cmd, sceneTex: sceneTex, finalTarget: mid, rt: rt, pipeline: orbitP)
                        composite = mid
                    }
                    renderSunSprites(cmd: cmd, target: composite, rt: rt)   // 太阳辉光叠加(加色)
                    renderGodrays(cmd: cmd, sceneTex: composite, finalTarget: finalTarget, rt: rt)  // 体积光+合成到final
                } else { render3D(commandBuffer: cmd, finalTarget: finalTarget) }
            } else {
                render3D(commandBuffer: cmd, finalTarget: finalTarget)   // 清屏 + 3D 模型(深度)
            }
            // 2D HUD 叠加(时钟/SATURN/Volume/日期文字 + 尘埃粒子,经 2D 正交)over 3D,.load 不清屏。
            // 这些层的文字脚本/粒子由 update() 每帧推进 → 时钟跳动、尘埃飘 = live 感。
            if !layers.isEmpty || !particleGroups.isEmpty {
                // 按 Phase1 判据分流设 mvp(此处覆盖 update 算的 mvp):
                //   屏幕族(clock/Volume/dis/dock,chainTop=UI根)→ matOrtho(3840×2160) × matModel(画布坐标)。
                //   3D 族(SYKM/Voyager/26.73,3D世界坐标)→ viewProj3D × 宿主世界 × 文本盒小尺寸(WP_3D_LABEL_K)。
                if let rt = scene3DRuntime {
                    let uiOrtho = matOrtho(width: 3840, height: 2160)
                    let k = Float(ProcessInfo.processInfo.environment["WP_3D_LABEL_K"] ?? "0.0012") ?? 0.0012
                    let dbg = ProcessInfo.processInfo.environment["WP_3D_HUD_LOG"] != nil && !logged3DHud
                    if dbg { Log.write("3D overlay: layers=\(layers.count) particleGroups=\(particleGroups.count)"); logged3DHud = true }
                    for i in layers.indices {
                        let id = layers[i].id
                        // 被祖先(灵动岛等条件UI容器)的 visible 脚本判隐藏 → 不渲。
                        if !scene3DHidden.isEmpty, rt.isHiddenByAncestor(id, hidden: scene3DHidden) { layers[i].visible = false; continue }
                        // 纯色底(tex≤4)+ 有 effect 但没跑(geodraw 几何绘图等不在 manifest)→ effect 才是内容,
                        // 渲黑色 solidlayer 底会盖住场景(灵动岛边框黑块、轨道 1px 残渣)。跳过(geodraw 内容暂缺,胜于黑块)。
                        if layers[i].texture.width <= 4, layers[i].texture.height <= 4, !layers[i].effects.isEmpty, !layers[i].useWE {
                            layers[i].visible = false; continue
                        }
                        if rt.isScreenLayer(id) {
                            // 画布盒 = size × 局部scale(排除 3D 父缩放)。文字**适配进盒**(纵横比保持+按 align 放置,
                            // 否则用纹理自然像素会过大重叠);图片(dock)直接用盒尺寸。
                            let box = rt.canvasBoxSize(id) ?? layers[i].rawSizePx
                            var center = rt.canvasOrigin(id)
                            var sz = box
                            if let ts = layers[i].text {
                                let q = textQuad(texW: Float(layers[i].texture.width), texH: Float(layers[i].texture.height),
                                                 box: box, hAlign: ts.desc.align, vAlign: ts.desc.verticalAlign)
                                sz = q.size; center.x += q.centerOffset.x; center.y += q.centerOffset.y
                            }
                            layers[i].mvp = uiOrtho * matModel(centerPx: center, sizePx: sz, angleDegZ: 0)
                            if ProcessInfo.processInfo.environment["WP_TEXT_LOG"] != nil, layers[i].text != nil {
                                Log.write("TXT id=\(id) center=\(center) box=\(box) tex=\(layers[i].texture.width)x\(layers[i].texture.height) vis=\(layers[i].visible)")
                            }
                        } else if let w = rt.worldsById[id] {
                            // 3D 浮空标签(Voyager/Cassini/26.73):画布盒尺寸(文字适配)× 世界系数 k → 透视下可读。
                            let box = rt.canvasBoxSize(id) ?? SIMD2(Float(layers[i].texture.width), Float(layers[i].texture.height))
                            var sz = box
                            if let ts = layers[i].text {
                                sz = textQuad(texW: Float(layers[i].texture.width), texH: Float(layers[i].texture.height),
                                              box: box, hAlign: ts.desc.align, vAlign: ts.desc.verticalAlign).size
                            }
                            layers[i].mvp = viewProj3D * w * simd_float4x4(diagonal: SIMD4(sz.x * k, sz.y * k, 1, 1))
                            if ProcessInfo.processInfo.environment["WP_BOX_LOG"] != nil {
                                let t = w.columns.3
                                Log.write("FLOAT id=\(id) worldPos=(\(t.x),\(t.y),\(t.z)) box=\(box) tex=\(layers[i].texture.width)x\(layers[i].texture.height)")
                            }
                        } else if ProcessInfo.processInfo.environment["WP_BOX_LOG"] != nil {
                            Log.write("OTHER id=\(id) box=\(rt.canvasBoxSize(id) ?? layers[i].rawSizePx) tex=\(layers[i].texture.width)x\(layers[i].texture.height)")
                        }
                    }
                }
                runLayerEffects(commandBuffer: cmd, skipFrameBufferInput: true)
                let pass = MTLRenderPassDescriptor()
                pass.colorAttachments[0].texture = finalTarget
                pass.colorAttachments[0].loadAction = .load
                pass.colorAttachments[0].storeAction = .store
                if let enc = cmd.makeRenderCommandEncoder(descriptor: pass) {
                    enc.label = "hud3d"; encode(into: enc); enc.endEncoding()
                }
            }
            return
        }
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
        // letterboxFit(适应屏幕):反过来等比缩小整张铺进屏幕、留黑边——内屏 16:10 看 16:9 壁纸时
        //   右上角被 cover 裁掉的特效全可见(代价:上下黑边)。默认 cover(=WE)。
        if canvas.x > 0, canvas.y > 0, w > 0, h > 0 {
            let k = (canvas.x / canvas.y) / (Float(w) / Float(h))
            switch PreferencesStore.shared.wallpaperScaleMode {
            case 1: ndcScale = k >= 1 ? SIMD2(1, 1 / k) : SIMD2(k, 1)   // fit:留黑边、全可见
            case 2: ndcScale = SIMD2(1, 1)                              // stretch:拉伸填满(画布直接铺满,变形)
            default: ndcScale = k >= 1 ? SIMD2(k, 1) : SIMD2(1, 1 / k)  // cover:填满+裁切(WE 默认)
            }
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

        // above-post 拆分:postChain 之上的图层(时钟/日期/UI 文本)不进后处理输入,留到 postChain 跑完后再叠
        //   (WE 语义:fullscreenlayer 后处理只作用其下方场景)。abovePostStart==Int.max 时 belowPostRange 覆盖全部(行为同旧)。
        let abovePostActive = postChainOn && abovePostStart != Int.max && abovePostStart < layers.count
        let belowPostRange: Range<Int>? = abovePostActive ? 0..<abovePostStart : nil

        if scenePassRefract, let sceneA = refractSceneTarget(width: w, height: h) {
            // Pass 1:图层 + (belowBloom)非折射粒子 → 离屏 sceneA。
            let p1 = MTLRenderPassDescriptor()
            p1.colorAttachments[0].texture = sceneA
            p1.colorAttachments[0].loadAction = .clear
            p1.colorAttachments[0].storeAction = .store
            p1.colorAttachments[0].clearColor = clearColor
            if let e1 = cmd.makeRenderCommandEncoder(descriptor: p1) {
                e1.label = "scene"; encode(into: e1, particleFilter: scenePartFilter, layerRange: belowPostRange); e1.endEncoding()
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
            encodeLweScene(commandBuffer: cmd, target: compositeTarget, particleFilter: scenePartFilter,
                           layerRange: belowPostRange)
            for l in layers { l.video?.attachRetention(to: cmd) }
        } else {
            // 无(场景 pass)折射:单 pass 渲图层 + (belowBloom)非折射粒子 → 合成目标。
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = compositeTarget
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = clearColor
            if let enc = cmd.makeRenderCommandEncoder(descriptor: pass) {
                enc.label = "scene"; encode(into: enc, particleFilter: scenePartFilter, layerRange: belowPostRange); enc.endEncoding()
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

        // above-post 图层(时钟/日期/UI 文本):在 postChain **之后**叠到已后处理画面 postOut 上(WE 语义:
        //   fullscreenlayer 后处理只染下方场景,其上 UI 直接叠 → 白字保持亮白,不被 darkambient tint 压到 ~177 灰)。
        //   .load 续画(postOut 已含后处理结果)。这些层无 frameBufferInput composelayer(纯文本/贴图/纯色),
        //   故直接 encode 普通 quad/文本即可,不必走 lwe 累积。
        if abovePostActive {
            let ap = MTLRenderPassDescriptor()
            ap.colorAttachments[0].texture = postOut
            ap.colorAttachments[0].loadAction = .load
            ap.colorAttachments[0].storeAction = .store
            if let ae = cmd.makeRenderCommandEncoder(descriptor: ap) {
                ae.label = "abovePost"
                encode(into: ae, layerRange: abovePostStart..<layers.count, drawParticles: false)
                ae.endEncoding()
            }
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
        // WE「属性」通用区:翻转 + 图片筛选器。整帧已合成进 finalTarget;若任一启用,把 finalTarget 拷到临时纹理
        //   再用 fullscreen_present 翻转/染色回写 finalTarget(实时与离屏 renderToPNG 共用 encodeFrame → 一处生效)。
        //   默认(不翻转、滤镜无)整段不执行 → finalTarget 原样 → 零回归。
        applyGeneralPresentFilter(commandBuffer: cmd, finalTarget: finalTarget)
    }

    /// 翻转 + 图片筛选器的最终回写(见 encodeFrame 末)。需把 finalTarget 拷到 tmp(同尺寸)再采样回写。
    private func applyGeneralPresentFilter(commandBuffer cmd: MTLCommandBuffer, finalTarget: MTLTexture) {
        // 验证用 env 覆盖(headless --render 不走 setGeneralProps):WP_FORCE_FLIP=1 / WP_FORCE_FILTER=<0..5>。
        // 生产无此 env 时零影响(仍按 setGeneralProps 推入的用户值)。
        var flip = generalFlip, filter = generalFilter
        let env = ProcessInfo.processInfo.environment
        if env["WP_FORCE_FLIP"] == "1" { flip = true }
        if let f = env["WP_FORCE_FILTER"], let v = Int(f) { filter = v }
        guard flip || filter > 0, let pf = pipelineBlitPresent else { return }
        let savedFlip = generalFlip, savedFilter = generalFilter
        generalFlip = flip; generalFilter = filter
        defer { generalFlip = savedFlip; generalFilter = savedFilter }
        let w = finalTarget.width, h = finalTarget.height
        guard let tmp = ensurePresentFilterTex(w, h) else { return }
        // finalTarget → tmp(全屏拷贝)。
        guard let blit = pipelineBlit else { return }
        let cp = MTLRenderPassDescriptor()
        cp.colorAttachments[0].texture = tmp
        cp.colorAttachments[0].loadAction = .dontCare
        cp.colorAttachments[0].storeAction = .store
        if let ce = cmd.makeRenderCommandEncoder(descriptor: cp) {
            ce.setRenderPipelineState(blit); ce.setFragmentSamplerState(sampler, index: 0)
            ce.setFragmentTexture(finalTarget, index: 0)
            ce.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3); ce.endEncoding()
        }
        // tmp →(翻转/滤镜)→ finalTarget。
        let pp = MTLRenderPassDescriptor()
        pp.colorAttachments[0].texture = finalTarget
        pp.colorAttachments[0].loadAction = .dontCare
        pp.colorAttachments[0].storeAction = .store
        if let pe = cmd.makeRenderCommandEncoder(descriptor: pp) {
            pe.setRenderPipelineState(pf); pe.setFragmentSamplerState(sampler, index: 0)
            pe.setFragmentTexture(tmp, index: 0)
            var gp = SIMD2<Float>(generalFlip ? 1 : 0, Float(generalFilter))
            pe.setFragmentBytes(&gp, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
            pe.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3); pe.endEncoding()
        }
    }

    private var presentFilterTex: MTLTexture?
    private func ensurePresentFilterTex(_ w: Int, _ h: Int) -> MTLTexture? {
        if let t = presentFilterTex, t.width == w, t.height == h { return t }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]; d.storageMode = .private
        presentFilterTex = device.makeTexture(descriptor: d)
        return presentFilterTex
    }

    /// 把指定粒子组(parent 指向某 composelayer)画进一张**透明全画布 child FBO**(clearColor=透明黑)。
    /// 该 FBO 替代累积场景 sceneFBO 当 composelayer 特效链(computeLayerEffect)的 sceneInput → tint/opacity-mask
    /// 只作用于「只含粒子」的内容(矩阵被染色 + 裁到遮罩区),不染下方场景的角色/龙身(真 WE parent→child FBO)。
    /// 用与主场景一致的 ndcScale/proj/视差画粒子(与 sceneFBO 同坐标空间),故 composelayer footprint(layer.mvp)
    /// 在 child FBO 上采样到的位置与在 sceneFBO 上一致。返回画好的 child FBO(失败/无粒子则 nil → 调用方退回旧路径)。
    private func encodeChildParticleFBO(groupIndices: [Int], width w: Int, height h: Int,
                                        commandBuffer cmd: MTLCommandBuffer) -> MTLTexture? {
        guard w > 0, h > 0, !groupIndices.isEmpty,
              pipelineParticleAdd != nil, pipelineParticleAlpha != nil,
              let target = composeChildTarget(width: w, height: h) else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)   // 透明底:只留粒子
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        enc.label = "composeChildFBO"
        enc.setFragmentSamplerState(sampler, index: 0)
        var ndc = ndcScale   // 与主场景同宽高比缩放(child FBO 与 sceneFBO 同尺寸/同坐标空间)
        enc.setVertexBytes(&ndc, length: MemoryLayout<SIMD2<Float>>.stride, index: 3)
        enc.setVertexBuffer(quadBuffer, offset: 0, index: 0)
        var blankFx = EffectUniforms()
        enc.setFragmentBytes(&blankFx, length: MemoryLayout<EffectUniforms>.stride, index: 0)
        let ring = frameIndex % Self.kBufferRing
        let skipRope = ProcessInfo.processInfo.environment["WP_NO_ROPE"] != nil
        func childProj(_ g: ParticleGroup) -> simd_float4x4 {
            var pd = g.parallaxDepth   // 同 encode.particleProj 的 minimumParticleDepth=0.65 钳制
            if abs(pd.x) < 0.65 { pd.x = pd.x < 0 ? -0.65 : 0.65 }
            if abs(pd.y) < 0.65 { pd.y = pd.y < 0 ? -0.65 : 0.65 }
            let off = parallaxOffset(depth: pd)
            return proj * matTranslate(off.x, off.y)
        }
        for gi in groupIndices {
            guard gi >= 0, gi < particleGroups.count else { continue }
            let g = particleGroups[gi]
            if g.isRefract { continue }   // 折射粒子需采场景底图,不进透明 child FBO(矩阵粒子非折射)
            if g.isRope {
                guard !skipRope, g.ropeVertexCount >= 3, let buf = g.ropeBuffers[ring],
                      let pipeline = g.additive ? pipelineRopeAdd : pipelineRopeAlpha else { continue }
                enc.setRenderPipelineState(pipeline)
                var projVar = childProj(g)
                enc.setVertexBytes(&projVar, length: MemoryLayout<simd_float4x4>.stride, index: 1)
                enc.setVertexBuffer(buf, offset: 0, index: 2)
                enc.setFragmentTexture(g.texture, index: 0)
                enc.setFragmentTexture(g.texture, index: 1)
                enc.setFragmentTexture(g.texture, index: 2)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: g.ropeVertexCount)
            } else {
                guard g.instanceCount > 0, let buf = g.instanceBuffers[ring],
                      let pipeline = g.additive ? pipelineParticleAdd : pipelineParticleAlpha else { continue }
                enc.setRenderPipelineState(pipeline)
                var projVar = childProj(g)
                enc.setVertexBytes(&projVar, length: MemoryLayout<simd_float4x4>.stride, index: 1)
                enc.setVertexBuffer(buf, offset: 0, index: 2)
                enc.setFragmentTexture(g.texture, index: 0)
                enc.setFragmentTexture(g.texture, index: 1)
                enc.setFragmentTexture(g.texture, index: 2)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: g.instanceCount)
            }
        }
        enc.endEncoding()
        return target
    }

    /// A(WP_LWE_COMPOSITE):忠实对齐 lwe —— 图层按 z 序累积进持久场景 FBO(target = _rt_FullFrameBuffer),
    /// 每个 frameBufferInput composelayer 读「累积到它之下的真场景」作特效输入(取代 compositeSceneBelow 临场重渲),
    /// 跑特效链产出 effectedTexture,再画该层。非折射、非 postProcess 路径专用;(belowBloom)粒子在末段统一画。
    private func encodeLweScene(commandBuffer cmd: MTLCommandBuffer, target sceneFBO: MTLTexture,
                               particleFilter: ((ParticleGroupInfo) -> Bool)?,
                               layerRange: Range<Int>? = nil) {
        // above-post 拆分:只把 [lo, hi) 段图层累积进后处理输入;其上的图层(UI 文本)由调用方在 postChain 后另叠。
        let lo = layerRange?.lowerBound ?? 0
        let hi = layerRange?.upperBound ?? layers.count
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
        segment(lo..<lo, withParticles: false)   // 初始清屏:首个 composelayer 即便在最底也读到已清屏基底
        var cursor = lo
        for i in lo..<hi where layers[i].frameBufferInput {
            // 场景序插画(默认):中段也画各自锚定的粒子 → composelayer 读到的累积场景**含下方粒子**
            //   (= WE _rt_FullFrameBuffer 语义:此前粒子被整体延后,composelayer 永远看不到它们)。
            //   WP_PARTICLES_ON_TOP 旧行为:中段不画,粒子统一在末段之后(encode 收尾 anchor:nil)。
            segment(cursor..<i, withParticles: !Self.particlesOnTop)        // 累积 [cursor, i) 进 sceneFBO
            // parent→child composelayer FBO(真 WE):本 composelayer 若有 child 粒子组(parent 指向它),
            // 把这些粒子画进透明 child FBO,用它当特效输入 → tint/opacity-mask 只染粒子、裁到遮罩区,
            // 不染下方场景(角色/龙身)。无 child 粒子的 composelayer(绝大多数)仍喂累积场景 sceneFBO(旧行为)。
            let childIdx = layers[i].childParticleGroupIndices
            var fxInput = sceneFBO
            if useComposeChildFBO, !childIdx.isEmpty,
               let childFBO = encodeChildParticleFBO(groupIndices: childIdx,
                                                     width: sceneFBO.width, height: sceneFBO.height,
                                                     commandBuffer: cmd) {
                fxInput = childFBO
            }
            computeLayerEffect(i, sceneInput: fxInput, commandBuffer: cmd) // 该层读累积场景(或 child FBO)跑特效链
            cursor = i                                                      // 该层自身留到下段画(effectedTexture 已就绪)
        }
        segment(cursor..<hi, withParticles: true)   // 余下图层 + 本段锚定粒子(旧行为:全部 belowBloom 粒子)
    }

    /// 跑该壁纸 fullscreenlayer 的真 WE 后处理链:整帧 scene 依次过 bloom/filmgrain/localcontrast 等
    /// 转译特效(每个 effect 一条多 pass 链,输出接下一个输入),末帧 blit 到 finalTarget(drawable)。
    private func runPostChain(commandBuffer cmd: MTLCommandBuffer, scene: MTLTexture, finalTarget: MTLTexture) {
        guard let we = weEffects else { return }
        var current = scene
        // preLayer = 当前后处理"层"开始前的画面;opacity 特效按其 alpha 把本层结果叠回 preLayer
        //   = 真 WE 的 fullscreenlayer 图层 opacity 语义(如 raindrop_on_glass 层 opacity=0.43:水珠淡叠)。
        //   opacity shader 本身只把 alpha *= α(blit 会忽略 alpha),故必须在这里做真正的"按 α 混合叠回"。
        //   WP_NO_POST_OPACITY=1 退回旧行为(opacity 当普通 pass 跑、不叠回)。
        var preLayer = scene
        let applyPostOpacity = ProcessInfo.processInfo.environment["WP_NO_POST_OPACITY"] == nil
        for eff in postChain {
            if applyPostOpacity, eff.weName == "opacity" {
                let a = Float(eff.weParams["alpha"] ?? "1") ?? 1
                if a < 0.999, let mixed = mixTextures(base: preLayer, top: current, alpha: a, cmd: cmd) {
                    current = mixed
                }
                preLayer = current   // 下一后处理层从这里叠
                continue
            }
            if let out = we.run(effect: eff.weName, input: current,
                                pkgParams: eff.weParams as [String: Any],
                                combos: eff.weCombos as [String: Any],
                                paramsPerPass: eff.weParamsPerPass.map { $0 as [String: Any] },
                                time: currentTime, cursor: cursorUV,
                                audio: currentAudio, commandBuffer: cmd) {
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
    // 诊断:WP_ONLY_IDS=863 只画这些 id 的图层(其余跳过),用于隔离单个 puppet 层观察蒙皮/剔除。空=全画。
    static let onlyLayerIds: Set<Int> = {
        guard let s = ProcessInfo.processInfo.environment["WP_ONLY_IDS"] else { return [] }
        return Set(s.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) })
    }()
    // 旧行为退路:WP_PARTICLES_ON_TOP=1 → 粒子恒画在(本相位)所有图层之上,不按场景对象序插画。
    static let particlesOnTop = ProcessInfo.processInfo.environment["WP_PARTICLES_ON_TOP"] != nil
    static let kBufferRing = 4
    private static let kInflightFrames = 3
    private let inflightSemaphore = DispatchSemaphore(value: SceneRenderEngine.kInflightFrames)
    private var frameIndex: Int = 0
    private lazy var captureEnabled: Bool = FileManager.default.fileExists(atPath: "/tmp/wp_capture")
    // 诊断抓帧步进/上限(默认 120/720;WP_CAP_STEP/WP_CAP_MAX 可改,用于密集采样动画相位峰值)。
    private lazy var captureStep: Int = Int(ProcessInfo.processInfo.environment["WP_CAP_STEP"] ?? "") ?? 120
    private lazy var captureMax: Int = Int(ProcessInfo.processInfo.environment["WP_CAP_MAX"] ?? "") ?? 720
    private var presentTex: MTLTexture?
    private var drawStaging: MTLTexture?
    private var aspectTex: MTLTexture?       // 画布长宽比编码/呈现纹理(场景渲它,ndcScale=1 不分带)
    private var aspectAuxTex: MTLTexture?     // 屏幕适配下 FXAA 输出(画布长宽比)
    // 自适应「大图被切→拉伸」:解析期算定的「大图像层不透明内容包围盒」(画布像素,x0,y0,x1,y1)。
    // aspectMap 用它判 cover 裁切区是否切到大图(切到→stretch)。粒子天然不在 layers、隐藏层建层时已跳过。
    private var largeOpaqueAABBs: [SIMD4<Float>] = []

    /// 扫贴图 alpha 求不透明内容包围盒(uv [u0,v0,u1,v1])+ 实心占比(包围盒内 alpha>200 的比例)。
    /// 实心占比区分「密实主体(角色)」与「稀薄大气层(云/雾/光)」。全不透明/无 alpha → ((0,0,1,1), 1)。
    private static func opaqueBounds(_ dec: DecodedTex) -> (rect: SIMD4<Float>, solidFrac: Float) {
        guard case let .rgba8(pixels, w, h) = dec, w > 0, h > 0, pixels.count >= w * h * 4 else { return (SIMD4(0, 0, 1, 1), 1) }
        let step = max(1, max(w, h) / 512)
        var minX = w, minY = h, maxX = -1, maxY = -1
        var sampled = 0, solid = 0
        var y = 0
        while y < h {
            let row = y * w * 4
            var x = 0
            while x < w {
                let a = pixels[row + x * 4 + 3]
                sampled += 1
                if a > 200 { solid += 1 }
                if a > 16 {
                    if x < minX { minX = x }; if x > maxX { maxX = x }
                    if y < minY { minY = y }; if y > maxY { maxY = y }
                }
                x += step
            }
            y += step
        }
        if maxX < 0 { return (SIMD4(0, 0, 1, 1), 0) }
        // 实心占比按**包围盒内**采样估(整图占比会被透明边距稀释)
        let bxN = max(1, (maxX - minX) / step + 1) * max(1, (maxY - minY) / step + 1)
        return (SIMD4(Float(minX) / Float(w), Float(minY) / Float(h),
                      Float(min(w, maxX + step)) / Float(w), Float(min(h, maxY + step)) / Float(h)),
                Float(solid) / Float(bxN))
    }

    /// 解析期算定「大图像层不透明内容包围盒」(画布像素)。判据:可见图像层(非文本)、内容尺寸足够大、
    /// 非满铺背景。供自适应判 cover 是否会切到大图。
    private func precomputeLargeLayers() {
        largeOpaqueAABBs.removeAll()
        guard canvas.x > 0, canvas.y > 0 else { return }
        let cw = canvas.x, ch = canvas.y, area = cw * ch
        for l in layers {
            if l.text != nil { continue }                       // 文本层不算(尺寸/定位另说)
            if l.audioBars != nil || l.instancedBarsScript != nil { continue }  // 音频条不算
            let sx = l.sizePx.x, sy = l.sizePx.y
            if sx >= 0.80 * cw && sy >= 0.80 * ch { continue }  // 满铺背景 → 跳过
            let r = l.opaqueRect                                 // uv 不透明子矩形
            // 不透明内容在画布像素的包围盒(quad = origin ± sizePx/2,贴图 uv[0,1]→quad)
            let x0 = l.origin.x - sx / 2 + r.x * sx, x1 = l.origin.x - sx / 2 + r.z * sx
            let y0 = l.origin.y - sy / 2 + r.y * sy, y1 = l.origin.y - sy / 2 + r.w * sy
            // 裁进画布内(画布外的内容本就不显示)
            let cx0 = max(0, x0), cx1 = min(cw, x1), cy0 = max(0, y0), cy1 = min(ch, y1)
            let ow = cx1 - cx0, oh = cy1 - cy0
            if ow <= 0 || oh <= 0 { continue }
            // 「比较大」:内容某一维 ≥ 22% 画布 且 面积 ≥ 5% 画布
            if max(ow / cw, oh / ch) < 0.22 || (ow * oh) < 0.05 * area { continue }
            if l.opaqueSolid < 0.35 { continue }                // 稀薄大气层(云/雾/光,实心占比低)不算
            let asp = ow / oh
            if asp > 3 || asp < 1.0 / 3 { continue }            // 细长横/竖带(背景天空带/分隔条)不算
            Log.write(String(format: "  大图候选 id=%d size=%.2fx%.2f 实心=%.2f 比=%.1f AABB=[%.0f,%.0f,%.0f,%.0f]",
                             l.id, sx / cw, sy / ch, l.opaqueSolid, asp, cx0, cy0, cx1, cy1))
            largeOpaqueAABBs.append(SIMD4(cx0, cy0, cx1, cy1))
        }
        Log.write("自适应大图层: \(largeOpaqueAABBs.count) 个(共 \(layers.count) 层)")
    }

    /// 给定输出尺寸,判 cover 裁切区是否切到任一大图像层(切到→自适应该 stretch)。
    private func coverTruncatesLargeLayer(outW: Int, outH: Int) -> Bool {
        guard !largeOpaqueAABBs.isEmpty, canvas.x > 0, canvas.y > 0, outW > 0, outH > 0 else { return false }
        let cw = canvas.x, ch = canvas.y
        let ac = cw / ch, ao = Float(outW) / Float(outH)
        // cover 可见区(画布像素):画布更宽→裁左右,更高→裁上下。超裁切线要够深(>5% 画布维)才算
        // 「真被切」——避免主体帽角/发梢擦边就触发拉伸(那点擦边不值得整张变形)。
        if ac >= ao {
            let visW = cw * ao / ac, cropL = (cw - visW) / 2, cropR = cw - cropL, m = 0.05 * cw
            for b in largeOpaqueAABBs where b.x < cropL - m || b.z > cropR + m { return true }
        } else {
            let visH = ch * ac / ao, cropT = (ch - visH) / 2, cropB = ch - cropT, m = 0.05 * ch
            for b in largeOpaqueAABBs where b.y < cropT - m || b.w > cropB + m { return true }
        }
        return false
    }

    /// 屏幕适配(lwe updateTextureUVs 机制):算画布长宽比中间纹理尺寸 + 鼠标用 ndc(旧 cover/fit 值)+ blit uvScale。
    /// 场景渲到画布长宽比纹理(ndcScale 自动=1,顶点不缩放=无内屏分带),长宽比裁切全挪到最终一次 blit。
    private func aspectMap(outW: Int, outH: Int) -> (encW: Int, encH: Int, mouseNdc: SIMD2<Float>, uvScale: SIMD2<Float>) {
        guard canvas.x > 0, canvas.y > 0, outW > 0, outH > 0 else {
            return (max(1, outW), max(1, outH), SIMD2(1, 1), SIMD2(1, 1))
        }
        let ac = canvas.x / canvas.y
        // 画布长宽比中间纹理,尺寸 ≥ 输出对应维度(cover 裁切的那维放大,避免欠采样糊)。
        let encH = max(outH, Int((Float(outW) / ac).rounded()))
        let encW = max(1, Int((Float(encH) * ac).rounded()))
        let k = ac / (Float(outW) / Float(outH))
        var nd = SIMD2<Float>(1, 1)
        switch PreferencesStore.shared.wallpaperScaleMode {
        case 1: nd = k >= 1 ? SIMD2(1, 1 / k) : SIMD2(k, 1)   // fit:留黑边、全可见
        case 2: nd = SIMD2(1, 1)                              // stretch:画布长宽比纹理铺满输出 → 拉伸
        case 3:                                               // 自适应(我方新增,非 WE 原生):默认 cover 零变形;
            // 但若 cover 会切到大图像层的真实内容 → 改 stretch 拉伸填满(保大图完整,代价是变形);
            // 比例已接近屏幕(差 <6%)也直接 stretch(形变可忽略、无裁切)。粒子/小装饰/满铺背景不算。
            let mm = k >= 1 ? k - 1 : 1 / k - 1
            if mm < 0.06 || coverTruncatesLargeLayer(outW: outW, outH: outH) {
                nd = SIMD2(1, 1)                              // 近似匹配 或 cover 会切大图 → 拉伸填满
            } else {
                nd = k >= 1 ? SIMD2(k, 1) : SIMD2(1, 1 / k)  // 比例差大且不切大图 → cover 零变形
            }
        default: nd = k >= 1 ? SIMD2(k, 1) : SIMD2(1, 1 / k)  // cover:填满+裁切(WE 默认)
        }
        return (encW, max(1, encH), nd, SIMD2(1 / nd.x, 1 / nd.y))
    }

    private func ensureAspectTex(_ w: Int, _ h: Int) -> MTLTexture? {
        if let t = aspectTex, t.width == w, t.height == h { return t }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead, .shaderWrite]   // shaderWrite:MetalFX scaler 输出
        d.storageMode = captureEnabled ? .shared : .private
        aspectTex = device.makeTexture(descriptor: d)
        return aspectTex
    }

    private func ensureAspectAux(_ w: Int, _ h: Int) -> MTLTexture? {
        if let t = aspectAuxTex, t.width == w, t.height == h { return t }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]; d.storageMode = .private
        aspectAuxTex = device.makeTexture(descriptor: d)
        return aspectAuxTex
    }

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
        let useMFX = prefs.metalFXEnabled
        let scale = prefs.renderScale
        let downscaled = scale < 0.999
        // 屏幕适配(lwe 机制):场景渲到**画布长宽比**中间纹理(ndcScale 自动=1,顶点不缩放=无内屏分带),
        // 长宽比裁切/留黑边全挪到最终一次 blit(blitUVScale)。aspectMouse 给下一帧鼠标/视差用。
        let (encW, encH, mNdc, uvS) = aspectMap(outW: w, outH: h)
        aspectMouse = mNdc; blitUVScale = uvS
        let lowW = max(2, Int((Double(encW) * scale).rounded())), lowH = max(2, Int((Double(encH) * scale).rounded()))
        // 编码目标:降分辨率时渲到低分纹理(画布长宽比),否则直接渲到画布长宽比呈现纹理。
        let encodeTex = downscaled ? ensureRenderScaleTex(lowW, lowH) : ensureAspectTex(encW, encH)
        guard let encodeTex else {
            // 审计修复#1:分配失败绝不把 encodeFrame 多 pass 直写 framebufferOnly drawable(顶部注释明令禁止,
            // 会泄漏平铺显存成黑线/噪点)。改为只 clear 该 drawable(整张定义为黑)并 present,跳过该帧渲染。
            let clearPass = MTLRenderPassDescriptor()
            clearPass.colorAttachments[0].texture = drawable.texture
            clearPass.colorAttachments[0].loadAction = .clear
            clearPass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            clearPass.colorAttachments[0].storeAction = .store
            cmd.makeRenderCommandEncoder(descriptor: clearPass)?.endEncoding()
            if drawable.layer.presentsWithTransaction {
                cmd.commit(); cmd.waitUntilScheduled(); CATransaction.begin(); drawable.present(); CATransaction.commit()
            } else {
                cmd.present(drawable); cmd.commit()
            }
            return
        }
        // 审计修复#2:限制在途帧到 3(三重缓冲),编码前 wait、完成时 signal。静态场景(只画一帧)也不死锁:
        // value=3 留足余量,且每帧都成对 wait/signal。
        inflightSemaphore.wait()
        cmd.addCompletedHandler { [inflightSemaphore] _ in inflightSemaphore.signal() }
        encodeFrame(commandBuffer: cmd, finalTarget: encodeTex)
        // 升采样:MetalFX(画质优)→ 画布长宽比全分纹理;否则最终 blit 的采样器直接双线性放大。
        var srcTex = encodeTex
        if downscaled, useMFX, let scaler = ensureScaler(inW: lowW, inH: lowH, outW: encW, outH: encH),
           let fullT = ensureAspectTex(encW, encH) {
            scaler.colorTexture = encodeTex
            scaler.outputTexture = fullT
            scaler.encode(commandBuffer: cmd)
            srcTex = fullT
        }
        // FXAA(画质设置开):先把场景按 1:1 抗锯齿到画布长宽比辅助纹理,再交给最终适配 blit。
        if prefs.fxaaEnabled, let fx = pipelineBlitFXAA, let fxTex = ensureAspectAux(srcTex.width, srcTex.height) {
            let fp = MTLRenderPassDescriptor()
            fp.colorAttachments[0].texture = fxTex
            fp.colorAttachments[0].loadAction = .dontCare
            fp.colorAttachments[0].storeAction = .store
            if let fe = cmd.makeRenderCommandEncoder(descriptor: fp) {
                fe.setRenderPipelineState(fx)
                var rcp = SIMD2<Float>(1.0 / Float(srcTex.width), 1.0 / Float(srcTex.height))
                fe.setFragmentBytes(&rcp, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
                fe.setFragmentSamplerState(sampler, index: 0)
                fe.setFragmentTexture(srcTex, index: 0)
                fe.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3); fe.endEncoding()
            }
            srcTex = fxTex
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        // 最终呈现:屏幕适配 blit(uvScale 居中裁切/留黑边);采样器对 srcTex 自动双线性升采样到 drawable。
        if let enc = cmd.makeRenderCommandEncoder(descriptor: pass) {
            var uvx = blitUVScale
            if let blitA = pipelineBlitAspect {
                enc.setRenderPipelineState(blitA)
                enc.setFragmentBytes(&uvx, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
            } else if let blit = pipelineBlit {
                enc.setRenderPipelineState(blit)
            }
            enc.setFragmentSamplerState(sampler, index: 0)
            enc.setFragmentTexture(srcTex, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3); enc.endEncoding()
        }
        // 诊断:WP_CURSOR_MARK=1 在引擎 cursorUV 对应的屏幕位置叠画十字+环(走与 halo 一致的 nd 映射:
        // 屏幕 uv = 0.5+(canvasUV-0.5)*nd;cursorUV.y 是 y 向上,屏幕 y 向下 → 取 1-cursorUV.y 再过 nd)。
        if ProcessInfo.processInfo.environment["WP_CURSOR_MARK"] != nil, let cmPipe = pipelineCursorMark {
            let mp = MTLRenderPassDescriptor()
            mp.colorAttachments[0].texture = drawable.texture
            mp.colorAttachments[0].loadAction = .load
            mp.colorAttachments[0].storeAction = .store
            if let me = cmd.makeRenderCommandEncoder(descriptor: mp) {
                me.setRenderPipelineState(cmPipe)
                var info = SIMD4<Float>(0.5 + (cursorUV.x - 0.5) * aspectMouse.x,
                                        0.5 + ((1.0 - cursorUV.y) - 0.5) * aspectMouse.y,
                                        Float(w) / Float(max(1, h)), 0)
                me.setFragmentBytes(&info, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
                me.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3); me.endEncoding()
            }
        }
        let tex = srcTex   // 下方抓帧/保存沿用最终呈现源
        let save = captureEnabled && (liveFrameCount % captureStep == 0) && liveFrameCount <= captureMax
        let n = liveFrameCount; if captureEnabled { liveFrameCount += 1 }
        // 抓**真实 drawable**(present 前):blit drawable → staging,看屏幕实际拿到的内容。
        if save, let stg = ensureDrawStaging(w, h), let be = cmd.makeBlitCommandEncoder() {
            be.copy(from: drawable.texture, sourceSlice: 0, sourceLevel: 0,
                    sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0), sourceSize: MTLSize(width: w, height: h, depth: 1),
                    to: stg, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            be.endEncoding()
        }
        // presentsWithTransaction(WP_SYNC_PRESENT 时 SceneRenderer 设)= 同步呈现消除内屏 120Hz 撕裂。
        //   **必须** commit→waitUntilScheduled→**CATransaction 包裹** drawable.present()——后台线程无隐式
        //   transaction 刷新,缺包裹则 present 永不提交=黑屏(上次的坑)。非 transaction 层走旧异步路。
        if drawable.layer.presentsWithTransaction {
            cmd.commit()
            cmd.waitUntilCompleted()   // 比 waitUntilScheduled 更强:等 GPU **完全画完** drawable 再呈现,
                                       //   杜绝 WindowServer 在 GPU 还没写完时合成抓到半成品=横向分带。
            CATransaction.begin()
            drawable.present()
            CATransaction.commit()
        } else {
            cmd.present(drawable)
            cmd.commit()
        }
        if save {
            cmd.waitUntilCompleted()
            saveTexture(tex, to: "/tmp/live_\(n).png")
            if let stg = drawStaging { saveTexture(stg, to: "/tmp/draw_\(n).png") }
        }
    }

    private func saveTexture(_ tex: MTLTexture, to path: String) {
        let width = tex.width, height = tex.height, rowBytes = width * 4
        // ⚠ 渲染目标纹理(.renderTarget/.shaderWrite)在 Apple GPU 上可能是无损压缩布局,直接 getBytes 会进
        //   AGX processCompressedRegion2D 崩溃(EXC_BAD_ACCESS,抓帧诊断时踩到)。统一先 blit 到线性 .shared
        //   暂存纹理(GPU 解压)再读,任何来源都安全。
        let readDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: tex.pixelFormat, width: width, height: height, mipmapped: false)
        readDesc.usage = [.shaderRead]; readDesc.storageMode = .shared
        guard let stg = device.makeTexture(descriptor: readDesc),
              let cb = queue.makeCommandBuffer(), let be = cb.makeBlitCommandEncoder() else { return }
        be.copy(from: tex, sourceSlice: 0, sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0), sourceSize: MTLSize(width: width, height: height, depth: 1),
                to: stg, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        be.endEncoding(); cb.commit(); cb.waitUntilCompleted()
        var raw = [UInt8](repeating: 0, count: rowBytes * height)
        stg.getBytes(&raw, bytesPerRow: rowBytes, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
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
        // 屏幕适配(与实时同机制):场景渲到画布长宽比中间纹理(ndcScale=1),再按 uvScale 适配 blit 到目标尺寸。
        let (encW, encH, mNdc, uvS) = aspectMap(outW: width, outH: height)
        aspectMouse = mNdc; blitUVScale = uvS
        let interDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: encW, height: encH, mipmapped: false)
        interDesc.usage = [.renderTarget, .shaderRead]; interDesc.storageMode = .private
        guard let inter = device.makeTexture(descriptor: interDesc) else { return false }
        encodeFrame(commandBuffer: cmd, finalTarget: inter)
        let bp = MTLRenderPassDescriptor()
        bp.colorAttachments[0].texture = target
        bp.colorAttachments[0].loadAction = .clear
        bp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        bp.colorAttachments[0].storeAction = .store
        if let enc = cmd.makeRenderCommandEncoder(descriptor: bp) {
            var uvx = blitUVScale
            if let blitA = pipelineBlitAspect {
                enc.setRenderPipelineState(blitA)
                enc.setFragmentBytes(&uvx, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
            } else if let blit = pipelineBlit { enc.setRenderPipelineState(blit) }
            enc.setFragmentSamplerState(sampler, index: 0)
            enc.setFragmentTexture(inter, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3); enc.endEncoding()
        }
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
        // 屏幕适配(与实时同机制):场景渲到画布长宽比中间纹理,再 uvScale 适配 blit 到 target。
        let (encW, encH, mNdc, uvS) = aspectMap(outW: width, outH: height)
        aspectMouse = mNdc; blitUVScale = uvS
        let interDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: encW, height: encH, mipmapped: false)
        interDesc.usage = [.renderTarget, .shaderRead]; interDesc.storageMode = .private
        guard let inter = device.makeTexture(descriptor: interDesc) else { return false }
        var warmRopePeakN: [Int: Int] = [:]
        var warmRopePeakV: [Int: Int] = [:]
        // WP_CURSOR_ORBIT(仅验证用):让光标绕画布中心做圆周运动,驱动「鼠标拖尾」rope 喷射(否则静止光标永不发射)。
        // 正常运行(桌面/--render)不设此变量 → 行为零变化。
        let orbit = ProcessInfo.processInfo.environment["WP_CURSOR_ORBIT"] != nil
        for i in 0..<max(1, frames) {
            let m: SIMD2<Float>
            if orbit {
                let spd = Float(ProcessInfo.processInfo.environment["WP_ORBIT_SPEED"] ?? "0.12") ?? 0.12
                let a = Float(i) * spd
                m = SIMD2(cos(a) * 0.5, sin(a) * 0.5)   // [-0.5,0.5] 归一化绕中心
            } else { m = SIMD2<Float>(0, 0) }
            update(time: Double(i) * dt, mouseNorm: m)   // 审计修复#2:update 已推进 frameIndex 轮换缓冲
            guard let cmd = queue.makeCommandBuffer() else { return false }
            encodeFrame(commandBuffer: cmd, finalTarget: inter)
            let bp = MTLRenderPassDescriptor()
            bp.colorAttachments[0].texture = target
            bp.colorAttachments[0].loadAction = .clear
            bp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            bp.colorAttachments[0].storeAction = .store
            if let enc = cmd.makeRenderCommandEncoder(descriptor: bp) {
                var uvx = blitUVScale
                if let blitA = pipelineBlitAspect {
                    enc.setRenderPipelineState(blitA)
                    enc.setFragmentBytes(&uvx, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
                } else if let blit = pipelineBlit { enc.setRenderPipelineState(blit) }
                enc.setFragmentSamplerState(sampler, index: 0)
                enc.setFragmentTexture(inter, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3); enc.endEncoding()
            }
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
    struct Uniforms { float4x4 mvp; float4 color; };

    vertex VOut scene_vertex(uint vid [[vertex_id]],
                             const device float4* verts [[buffer(0)]],
                             constant Uniforms& u [[buffer(1)]],
                             constant float2& ndcScale [[buffer(3)]]) {
        float4 v = verts[vid];            // xy = pos, zw = uv
        VOut o;
        o.position = u.mvp * float4(v.xy, 0.0, 1.0);
        // 所有图层(含 frameBufferInput composelayer)都按普通 quad UV(v.zw)采样 effectedTexture:
        // 它现为**层 [0,1] 空间**结果(WEEffectChain.run 的 composelayer copy pass 已把场景按 footprint 采进
        // 层 FBO,= lwe 首 copy pass)→ 渲层 quad 采样贴回即 lwe 末 pass。已删除旧的「整帧画布底图 + 画布 UV」分支。
        o.uv = v.zw;
        o.position.xy *= ndcScale;        // 宽高比 cover 适配
        o.color = u.color;
        return o;
    }

    // ---- 3D 透视场景:模型 pass(太阳系/土星)----
    // 顶点缓冲交错:每顶点 8 float = pos.xyz, uv.xy, normal.xyz(32 字节)。
    // U3:mvp + model(世界矩阵,算世界法线/世界位置) + 颜色/亮度/alpha + 方向光 + 阴影矩阵 + 标志。
    //  土星 scene.general.lightconfig = {directional:1, directionalshadow:1, point:1, pointshadow:1}:
    //  方向光(259)对行星做 N·L 漫反射(昼夜终止线);土星环(462)/陨石(479)做 shadow caster,
    //  经方向光阴影贴图投在行星表面 → 经典「土星环影」暗带。这条暗带正好落在 HUD 时钟/信息所在赤道
    //  → 白字得以读出。原 shader 零光照(只 albedo×color×brightness)→ 行星均匀亮、字被冲掉。
    struct V3Out { float4 position [[position]]; float2 uv; float3 normal; float3 wpos; };
    struct U3 {
        float4x4 mvp; float4x4 model; float4x4 lightVP;
        float3 color; float brightness; float alpha;
        float3 lightDir;      // 指向太阳的单位方向(世界)
        float lit;            // 1=做 N·L 漫反射 + 接收阴影(仅行星);0=原样(天空盒/太阳/环)
        float ambient;        // 暗部地面光(防止背光面纯黑);N·L 下限
        float shadowStrength; // 阴影暗度(0..1,1=全黑)
        float pad0; float pad1;
    };
    vertex V3Out model3d_vertex(uint vid [[vertex_id]],
                                const device float* v [[buffer(0)]],
                                constant U3& u [[buffer(1)]],
                                constant float2& ndcScale [[buffer(3)]]) {
        uint b = vid * 8;
        float3 pos = float3(v[b], v[b+1], v[b+2]);
        V3Out o;
        o.position = u.mvp * float4(pos, 1.0);
        o.position.xy *= ndcScale;          // 宽高比 cover 适配(与 2D 一致)
        o.uv = float2(v[b+3], v[b+4]);
        // 世界法线(用 model 的旋转/缩放;土星近似均匀缩放,直接乘上三阶足够)。
        float3x3 m3 = float3x3(u.model[0].xyz, u.model[1].xyz, u.model[2].xyz);
        o.normal = normalize(m3 * float3(v[b+5], v[b+6], v[b+7]));
        o.wpos = (u.model * float4(pos, 1.0)).xyz;
        return o;
    }
    // 阴影投影 pass:只把 caster 几何投到方向光的正交相机,写深度。
    vertex float4 model3d_shadow_vertex(uint vid [[vertex_id]],
                                        const device float* v [[buffer(0)]],
                                        constant U3& u [[buffer(1)]]) {
        uint b = vid * 8;
        float3 pos = float3(v[b], v[b+1], v[b+2]);
        return u.lightVP * (u.model * float4(pos, 1.0));   // lightVP·world·pos
    }
    fragment float4 model3d_fragment(V3Out in [[stage_in]],
                                     texture2d<float> tex [[texture(0)]],
                                     depth2d<float> shadowMap [[texture(1)]],
                                     sampler smp [[sampler(0)]],
                                     constant U3& u [[buffer(1)]]) {
        float4 albedo = tex.sample(smp, in.uv);
        float3 rgb = albedo.rgb * u.color * u.brightness;
        float a = albedo.a * u.alpha;
        if (u.lit > 0.5) {
            float3 N = normalize(in.normal);
            float3 L = normalize(u.lightDir);
            // 双面:法线朝向相机半球(避免行星背面三角法线翻转造成的脏点)。
            // 方向光 N·L 漫反射;ambient 作为暗面底光(土星 ambientcolor=0 但实景暗面非纯黑,
            // 给一点底光保留材质细节、且让字在暗带上仍可读)。
            float ndl = max(dot(N, L), 0.0);
            float diffuse = u.ambient + (1.0 - u.ambient) * ndl;
            // 方向光阴影贴图(土星环/陨石投影):正交相机,深度比较。
            float shadow = 1.0;
            float4 lp = u.lightVP * float4(in.wpos, 1.0);
            float3 ndc = lp.xyz / lp.w;
            float2 suv = ndc.xy * 0.5 + 0.5;
            suv.y = 1.0 - suv.y;                 // Metal 纹理坐标 y 向下
            if (all(suv > float2(0.0)) && all(suv < float2(1.0)) && ndc.z >= 0.0 && ndc.z <= 1.0) {
                constexpr sampler ss(coord::normalized, address::clamp_to_edge, filter::linear, compare_func::greater);
                // PCF 3×3:caster 比片元更靠光源(深度更小)→ 在阴影里。bias 防自阴影摩尔纹。
                float bias = 0.0015;
                float sum = 0.0; float texel = 1.0 / 2048.0;
                for (int dy = -1; dy <= 1; dy++)
                  for (int dx = -1; dx <= 1; dx++)
                    sum += shadowMap.sample_compare(ss, suv + float2(dx, dy) * texel, ndc.z - bias);
                shadow = 1.0 - (u.shadowStrength * (sum / 9.0));
            }
            rgb *= diffuse * shadow;
        }
        return float4(rgb, a);
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
    // 屏幕适配呈现:把画布长宽比中间纹理按 uvScale 居中缩放采样(= lwe updateTextureUVs):
    //   uvScale<1 在该轴 = cover 裁切(采更窄范围放大填满);uvScale>1 = fit 留黑边(采超 [0,1] 部分取黑);
    //   (1,1) = stretch(画布长宽比纹理直接铺满输出 → 拉伸)。顶点已不乘 ndcScale,长宽比全在此一次性处理。
    fragment float4 fullscreen_copy_aspect(VOut in [[stage_in]], texture2d<float> t [[texture(0)]],
                                           sampler s [[sampler(0)]], constant float2& uvScale [[buffer(1)]]) {
        float2 uv = 0.5 + (in.uv - 0.5) * uvScale;
        if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) return float4(0.0, 0.0, 0.0, 1.0);
        return t.sample(s, uv);
    }
    // WE「属性」通用区:翻转(uv.x 镜像)+ 图片筛选器(0=无/1=灰度/2=棕褐/3=反相/4=暖/5=冷)。
    // gp.x=flip(0/1),gp.y=filter 索引。仅在 flip 或 filter 启用时走本 pipeline,默认走 fullscreen_copy 不变。
    fragment float4 fullscreen_present(VOut in [[stage_in]], texture2d<float> t [[texture(0)]],
                                       sampler s [[sampler(0)]], constant float2& gp [[buffer(0)]]) {
        float2 uv = in.uv;
        if (gp.x > 0.5) uv.x = 1.0 - uv.x;   // 水平翻转整个壁纸
        float4 c = t.sample(s, uv);
        int f = int(gp.y + 0.5);
        if (f == 1) {                         // 灰度(luma)
            float l = dot(c.rgb, float3(0.299, 0.587, 0.114));
            c.rgb = float3(l);
        } else if (f == 2) {                  // 棕褐(sepia 矩阵)
            float3 o = c.rgb;
            c.r = dot(o, float3(0.393, 0.769, 0.189));
            c.g = dot(o, float3(0.349, 0.686, 0.168));
            c.b = dot(o, float3(0.272, 0.534, 0.131));
            c.rgb = clamp(c.rgb, 0.0, 1.0);
        } else if (f == 3) {                  // 反相
            c.rgb = 1.0 - c.rgb;
        } else if (f == 4) {                  // 暖色(抬红/降蓝)
            c.rgb = clamp(c.rgb * float3(1.10, 1.02, 0.88), 0.0, 1.0);
        } else if (f == 5) {                  // 冷色(降红/抬蓝)
            c.rgb = clamp(c.rgb * float3(0.88, 1.00, 1.12), 0.0, 1.0);
        }
        return c;
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
    // 诊断:在 info.xy(屏幕 UV,y 向下)处画绿十字 + 红环;info.z=屏幕宽高比(环做圆形校正)。
    // 标记 = 引擎认为的光标位置;与物理鼠标对比即知 cursor 链路是否准。WP_CURSOR_MARK 启用。
    fragment float4 cursor_marker(VOut in [[stage_in]], constant float4& info [[buffer(0)]]) {
        float2 d = (in.uv - info.xy) * float2(info.z, 1.0);
        float r = length(d);
        if (r < 0.006) return float4(0,1,0,1);                       // 绿心
        if (abs(r - 0.028) < 0.0035) return float4(1,0,0,1);         // 红环
        if (abs(d.x) < 0.0012 && r < 0.07) return float4(0,1,0,1);   // 竖线
        if (abs(d.y) < 0.0012 && r < 0.07) return float4(0,1,0,1);   // 横线
        discard_fragment();
    }
    """
}
