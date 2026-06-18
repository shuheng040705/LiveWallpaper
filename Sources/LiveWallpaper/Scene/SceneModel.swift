import Foundation
import simd

/// 混合模式(来自 material pass 的 "blending")。
enum BlendMode: String {
    case normal       // 不透明/覆盖
    case translucent  // 标准 alpha-over
    case additive     // 相加

    init(raw: String?) {
        switch raw?.lowercased() {
        case "additive": self = .additive
        case "translucent": self = .translucent
        default: self = .normal
        }
    }
}

/// 把 "x y z" / "x y" 这类空格分隔字符串解析成浮点数组。
enum VecParse {
    /// 用户在「壁纸设置」里设的覆盖值(user-key → 值)。解析 scene.json 期间临时设置。
    /// 字段形如 {"user": "<key>", "value": <默认>} 时,若 overrides 有该 key 就用覆盖值。
    static var overrides: [String: WallpaperProperty.Value] = [:]

    /// WE 的字段可能是裸值,也可能被「脚本属性/用户可控属性」包成 {"value": ..., "user"/"script": ...}。
    /// 统一拆包:有 user 覆盖优先用覆盖;否则取 "value";裸值原样返回。
    static func unwrap(_ v: Any?) -> Any? {
        guard let dict = v as? [String: Any] else { return v }
        // 长形「条件属性」:{"user":{"name":<属性key>,"condition":<串>}, "value":default}。
        // WE 语义(UserSettingParser.cpp:24-47 解析 attachCondition + connect;
        //          DynamicValue.cpp:203-225 update(other) / :166-188 update(string) 求值):
        //   condition 触发是**类型相关**的,不是无条件字符串比较。连接属性把当前值传给字段时走
        //   update(const DynamicValue& other)(DynamicValue.cpp:203);其中条件分支只在
        //   `other.getType() == UnderlyingType::String` 时才执行(DynamicValue.cpp:213):
        //       boolValue = (m_condition.condition == other.getString())。
        //   对 **非 String 类型**(Boolean / Float / Int / Vec / Color),update(other) 直接逐字段拷贝
        //   原始值(DynamicValue.cpp:204-211),**condition 被完全忽略** —— 字段 = 属性的原始 bool/数值。
        //   而属性的底层类型由 PropertyParser.cpp 决定:combo→String(:65/:78 std::to_string(int) 或串)、
        //   text/textinput→String、bool→Boolean(:98)、slider→Float(:113)、color→Vec4。
        //   因此:condition 字符串相等**只对 combo/text(String 类型)属性生效**;bool 属性返回其原始
        //   bool(等价 getBool,DynamicValue.cpp:209),slider/number 属性返回其原始数值(condition 不参与)。
        //   这让 visible/alpha 等字段对 combo 走条件相等(天气/时段开关,行为零变化),对 bool/slider
        //   返回真实值,修掉「把 bool/数字转串再 == condition」的伪缺口(R2:背景污染/残留覆盖残留面)。
        if let userObj = dict["user"] as? [String: Any],
           let name = userObj["name"] as? String,
           let condition = userObj["condition"] as? String {
            // 取该属性的当前(覆盖)值;无覆盖时落到 "value" 默认(见下方 fallthrough 处理)。
            if let ov = overrides[name] {
                switch ov {
                // String 类型(combo/text):走条件字符串相等(DynamicValue.cpp:213-221)。
                // combo 选项值本就是串(WallpaperProperties 存 "\(v)"),此分支与改前完全一致 → combo 零变化。
                case .string(let s): return (s == condition)
                // Boolean 类型:condition 被忽略,返回原始 bool(getBool,DynamicValue.cpp:209)。
                case .bool(let b): return b
                // Float/Int 类型(slider):condition 被忽略,返回原始数值(≠0 即真;DynamicValue.cpp:206-209)。
                case .number(let n): return NSNumber(value: n)
                // Vec4(color):combo 不会是 color;按 lwe 非 String,condition 不参与,返回原始色串(与短形一致)。
                case .color(let c): return String(format: "%.6f %.6f %.6f", c.x, c.y, c.z)
                }
            }
            // 无覆盖回退:用字段自身 "value" 字面默认,按其**原始字面类型**返回(对齐 DynamicValueParser.cpp:26-64
            // 仅按 value 字面类型初始化、无连接时 condition 不参与)。String 默认仍走 condition 相等(让未被
            // 用户改动的 combo/text 条件属性正确求值);bool→bool、数字→数值,不再转串与 condition 比。
            if let dv = dict["value"] {
                if let b = dv as? Bool { return b }                        // bool 字面:原始 bool
                if let n = dv as? NSNumber { return n }                    // 数字字面:原始数值(≠0 即真)
                if let s = dv as? String { return (s == condition) }       // 串字面:走 condition 相等(combo/text)
                return false
            }
            return false   // 既无覆盖也无默认:WE 下属性未连接→条件不成立(DynamicValue.cpp:227-237 Null→false)。
        }
        // 用户可控属性(短形):{"user":"key","value":default}。查覆盖。
        if let userKey = dict["user"] as? String, let ov = overrides[userKey] {
            switch ov {
            case .bool(let b): return b
            case .number(let n): return NSNumber(value: n)
            case .string(let s): return s
            case .color(let c): return String(format: "%.6f %.6f %.6f", c.x, c.y, c.z)
            }
        }
        return dict["value"] ?? v
    }

    static func floats(_ s: Any?) -> [Float] {
        let u = unwrap(s)
        // 审计修复(#1):override 是滑块({user:"key"} 且覆盖为 .number)时 unwrap 返回 NSNumber,
        // 旧 `as? String` 会失败 → 向量(scale/origin/size)静默退默认,滑块驱动失效。
        // 数字结果按单元素向量处理(滑块通常驱动单值,如统一缩放),让其生效。
        // 排除 Bool(它也桥接为 NSNumber):向量字段的 bool override 仍按旧行为退默认(返回 [])。
        if let n = u as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { return [n.floatValue] }
        guard let str = u as? String else { return [] }
        return str.split(whereSeparator: { $0 == " " || $0 == "\t" }).compactMap { Float($0) }
    }

    /// visible 字段(可能被脚本属性包成 {"value":Bool})。缺省 true。
    static func parseVisibleBool(_ v: Any?) -> Bool {
        if let b = unwrap(v) as? Bool { return b }
        return true
    }
    static func f2(_ s: Any?, default d: SIMD2<Float> = .zero) -> SIMD2<Float> {
        let a = floats(s)
        // 标量滑块绑到 vec 字段(WE 行为):单值广播到各分量。depth 滑块拖动 → 有效值化为单标量 →
        // floats 返回 [v] → 旧 `count>=2` 失败退默认 → 视差深度永不随滑块变。广播成 (v,v)。
        if a.count == 1 { return SIMD2(a[0], a[0]) }
        guard a.count >= 2 else { return d }
        return SIMD2(a[0], a[1])
    }
    /// parallaxDepth 取值:WGPU/真 WE 约定 —— **字段缺省 = (1,1)**(没写 parallaxDepth 的层默认满视差),
    /// 只有显式写了才用其值(显式 (0,0) = 不参与视差)。WP_PARALLAX_LWE 退回 lwe 默认 (0,0)(ObjectParser.cpp:159)。
    static func parallaxDepth(_ obj: [String: Any]) -> SIMD2<Float> {
        guard obj["parallaxDepth"] != nil else {
            return ProcessInfo.processInfo.environment["WP_PARALLAX_LWE"] != nil ? .zero : SIMD2(1, 1)
        }
        return f2(obj["parallaxDepth"])
    }
    static func f3(_ s: Any?, default d: SIMD3<Float> = .zero) -> SIMD3<Float> {
        let a = floats(s)
        // 标量滑块绑到 vec3 字段(WE 行为):单值广播(统一缩放)。chracter_size 滑块有效值化为单标量
        // 0.58 → floats 返回 [0.58] → 旧 `count>=3` 失败退默认(1,1,1)→ 人物恒满尺寸 1.0、滑块无效。
        // 广播成 (0.58,0.58,0.58)=按 pkg 正确缩放,滑块实时生效。全库性:凡滑块绑 scale/depth 的都受益。
        if a.count == 1 { return SIMD3(a[0], a[0], a[0]) }
        guard a.count >= 3 else { return d }
        return SIMD3(a[0], a[1], a[2])
    }
    static func f4(_ s: Any?, default d: SIMD4<Float>) -> SIMD4<Float> {
        let a = floats(s)
        if a.count >= 4 { return SIMD4(a[0], a[1], a[2], a[3]) }
        if a.count >= 3 { return SIMD4(a[0], a[1], a[2], 1) }
        return d
    }
}

/// 图层后处理效果(WE 的 layer effect)。按语义重新实现(原始 GLSL 不在本地)。
/// 分三个实现域:vertex(顶点位移)、uv(采样坐标扰动)、color(输出色操作)。
enum LayerEffectKind: Int, CustomStringConvertible {
    var description: String {
        switch self {
        case .none: return "none"; case .shake: return "shake"; case .waterwaves: return "waterwaves"
        case .foliagesway: return "foliagesway"; case .waterripple: return "waterripple"
        case .waterflow: return "waterflow"; case .scroll: return "scroll"; case .tint: return "tint"
        case .opacity: return "opacity"; case .pulse: return "pulse"
        }
    }
    case none = 0
    case shake = 1          // 顶点:整体正弦抖动
    case waterwaves = 2     // uv:方向性正弦波位移
    case foliagesway = 3    // uv:按高度加权的横向摆动
    case waterripple = 4    // uv:径向涟漪扰动
    case waterflow = 5      // uv:方向滚动 + 相位
    case scroll = 6         // uv:线性平移滚动
    case tint = 7           // color:染色混合
    case opacity = 8        // color:整体透明度
    case pulse = 9          // color:亮度脉动(无音频时退化为正弦呼吸)

    /// 从 effect.json 的 file 路径(如 "effects/waterwaves/effect.json")识别类型。
    init(file: String) {
        let lower = file.lowercased()
        if lower.contains("shake") { self = .shake }
        else if lower.contains("waterwaves") { self = .waterwaves }
        else if lower.contains("foliagesway") { self = .foliagesway }
        else if lower.contains("waterripple") { self = .waterripple }
        else if lower.contains("waterflow") { self = .waterflow }
        else if lower.contains("scroll") { self = .scroll }
        else if lower.contains("tint") { self = .tint }
        else if lower.contains("opacity") { self = .opacity }
        else if lower.contains("pulse") { self = .pulse }
        else { self = .none }
    }
}

/// 解析后的单个图层效果:类型 + 4 个打包参数(含义随类型,见 SceneRenderEngine 的 shader)。
struct LayerEffect {
    var kind: LayerEffectKind
    var p: SIMD4<Float>     // 参数槽(旧内联手写路径用);各 effect 自定义含义
    var maskPath: String?   // 遮罩纹理(pkg 内路径);非 nil 时效果只作用于遮罩白色区域
    // 转译特效引擎用:WE effect 名 + pkg 真实参数(material-key→值)+ combos。
    var weName: String = ""
    var weParams: [String: String] = [:]               // 合并全 pass 的 csv(同名后写覆盖)
    var weParamsPerPass: [[String: String]] = []        // 逐 pass 的 csv(多 pass effect 如 bloom:
                                                        // 各 pass 的 strength/Tint 可不同 → 按 pass 取真值)
    var weCombos: [String: String] = [:]
    // 逐特效的**全部**辅助贴图(WE 约定:pass.textures[N] → shader 采样器 g_TextureN)。
    // slot(≥1)→ 纹理引用。槽 0 恒是 framebuffer(上一 pass 输出),不在此。
    // 例:waterripple 的 [null, "masks/..._mask", "effects/waterripplenormal"]
    //     → {1: "masks/..._mask"(g_Texture1=opacitymask), 2: "effects/waterripplenormal"(g_Texture2=法线)}。
    // 引用可能是 pkg-local(masks/.../effects/...,解析为 materials/<ref>.tex)或 WE 内置(同名在 assets)。
    // 注:shake/waterflow 的 g_Texture1 是 flowmask(非 opacitymask),其 "*_mask" 命名的槽其实是
    //     流向贴图;按 slot 字面绑定即正确(localization 来自流向偏离中性灰,而非 MASK combo)。
    var weAux: [Int: String] = [:]
    // 属性关键帧动画(material-key → 动画):constantshadervalues 里 `{animation:{...},value:..}` 的项。
    // 每帧由 SceneRenderEngine.update 求值后写回 weParams[key],驱动 opacity 淡入淡出(打雷)等。
    var weAnim: [String: WEKeyframeAnimation] = [:]
}

/// 一个待渲染图层的描述(尚未解码纹理)。
struct LayerDesc {
    var id: Int
    var name: String
    var sceneObjIndex: Int = .max // scene.json objects 数组下标(WE 按对象序绘制一切;粒子插画锚点用)
    var originPx: SIMD3<Float>    // 图层中心(场景像素坐标,y 向下)
    var sizePx: SIMD2<Float>?     // 显式 size;nil=autosize(取纹理像素尺寸)
    var cropOffset: SIMD2<Float> = .zero   // model.json cropoffset(裁剪重定位,纹理像素;多部件角色用)
    var cropShiftPx: SIMD2<Float> = .zero  // 实际应用的 cropoffset 世界位移(POT 命中才非零);origin 关键帧层每帧需再加上它(否则关键帧覆盖掉 origin 上的 crop)
    var scale: SIMD3<Float>
    var anglesDeg: SIMD3<Float>
    var parallax: SIMD2<Float>
    var visible: Bool
    var texturePath: String?     // pkg 内部路径,如 "materials/Foo.tex"
    var color: SIMD4<Float>
    var blend: BlendMode
    // WE 对象级整数混合模式(ObjectParser.cpp:292,字段 "colorBlendMode")。区别于 material pass 的
    // "blending" 字符串(→ `blend`)。0=normal,其余为 WE 内部枚举(见 WE 渲染器)。
    // TODO: 目前仅解析存下;真正按此混合需改 SceneRenderEngine(不在本任务范围)。
    var colorBlendMode: Int = 0
    // WE 对象级亮度乘子(ObjectParser.cpp:293,字段 "brightness")。默认 1。
    // TODO: 目前仅解析存下;真正按此调亮度需改 SceneRenderEngine(不在本任务范围)。
    var brightness: Float = 1
    var isSolid: Bool = false    // solidlayer:无纹理纯色填充(用 color 画满 quad)
    // model.json 的真布尔(ModelParser.cpp:24-31)。替掉旧的「image 路径字符串猜测」:
    //   isSolid 仍由路径含 "solidlayer" 决定(WE 也认这条),但若 model.json 有真 solidlayer 字段则以其为准;
    //   fullscreen/passthrough/autosize 此前靠路径含 "fullscreenlayer" 猜,现读真字段。
    var isFullscreen: Bool = false   // model.json "fullscreen":全屏后处理层
    var isPassthrough: Bool = false  // model.json "passthrough":透传层(不自渲染,作组合中转)
    // 主纹理槽是 `_rt_FullFrameBuffer`(场景主 FBO 名):本层无自有贴图,输入=渲染序中其下方已合成的整帧场景。
    // 渲染时 SceneRenderEngine 用 compositeSceneBelow(upTo: 本层) 当 g_Texture0,跑特效链(pulse/调色)再写回场景。
    var frameBufferInput: Bool = false
    // 渲进哪个 composelayer 的 child FBO(2026-06-19 阴影软化):本 image 层若是某带特效 composelayer(如「星_阴影」
    //   opacity 0.6)的后代,应渲进该 composelayer 的 FBO 走它的特效链软化(opacity/blendgradient)+ 在该 composelayer
    //   的 z 位合成(身后),而非展平后与真实部件交错硬渲(盖脸=阴影块)。nil=正常主场景渲染。
    var renderIntoComposeId: Int? = nil
    // 排在最后一个 postChain fullscreenlayer **之上**(渲染序在后)→ 不被该后处理染色/模糊(WE 语义)。
    //   引擎把这些层留到 postChain 跑完后再叠到已后处理画面上(时钟/日期文本保持亮白,不被 darkambient tint 压暗)。
    var abovePost: Bool = false
    var regionFit: Bool = false      // 区域性 composelayer(非 pulse):特效在该层 region [0,1] 空间跑(裁场景+遮罩到 region)。pulse/打雷=false(走全屏画布 UV,不动)。
    // 自绘满画布特效层(shape="quad" + image=nil + DIRECTDRAW 自绘特效,如 lightshafts 阳光/光束):
    //   WE 真义 = 该 effect 是 group="colorize" 的全屏后处理,DIRECTDRAW=1 时 frag `albedo=CAST4(0)` 忽略
    //   g_Texture0,自绘光束到透明全屏 quad 上(`albedo.a=max(a, fx)`),光束足迹由 shader 的 point0..3 透视
    //   UV(EffectPerspectiveUV gizmo)决定、不靠 quad 尺寸/对象 origin。故建成**满画布透明底 + additive 合成**层
    //   (effectedTexture 自带逐像素 alpha=光束强度,合成保留 alpha、不乘对象色)。lwe 把 shape 当 VolumeLight
    //   直接报错丢弃(ObjectParser.cpp:78),此为补真 WE 行为。WP_NO_LIGHTSHAFTS=1 退回旧跳过(A/B)。
    var selfDrawFullscreen: Bool = false
    var autosize: Bool = false       // model.json "autosize":尺寸取纹理像素(无显式 size 时)
    var noPadding: Bool = false      // model.json "nopadding"
    var modelWidth: Int? = nil       // model.json "width"(可选)
    var modelHeight: Int? = nil      // model.json "height"(可选)
    var puppet: String? = nil        // model.json "puppet":puppet warp 的模型文件
    // 部件间 attachment(scene.json 对象级 "attachment" 字符串,如「头部」):本(子)部件应挂到
    // **父对象 puppet** 的同名 MDAT 挂点上(凯尔希:眼睛/眼睑/耳朵挂到主体「头部」→ 拼回光头脸)。
    // 渲染时(SceneRenderEngine)解析父 puppet mesh 的 attachmentWorld(name),把子蒙皮顶点搬到父 mesh-local
    // 空间、用父的 origin/scale/angle/size 渲染。lwe 不做此事(故 lwe 散);已离线验证 + 用户授权超出 lwe。
    var attachment: String? = nil    // 本对象挂到父的具名挂点
    var parentPuppet: String? = nil  // 父对象 model.json 的 puppet 路径(供解析父挂点)
    var parentPuppetSize: SIMD2<Float>? = nil   // 父对象 scene size(渲染用父 quad size 归一)
    var parentRenderOrigin: SIMD2<Float> = .zero // 父对象世界 origin(渲染子挂件用)
    var parentRenderScale: SIMD2<Float> = SIMD2(1, 1) // 父对象世界 scale
    var parentRenderAngle: Float = 0             // 父对象世界 z 角(弧度)
    // 父 puppet 的骨骼动画(供动态挂点跟随:每帧用父动画后的具名挂点世界变换重算子部件锚点,
    // 修「人物动时眼/睑/耳被头发带走、露秃脸」)。取父对象 animationlayers 首个 visible(否则首个)的
    // animation id / rate;无动画时为 nil → 子部件退回静态 bind 挂点(t=0 退化兜底)。
    var parentAnimId: Int? = nil
    var parentAnimRate: Float = 1
    // 纯 image quad 子部件(无自身 puppet)做 attachment 用:本对象的**局部** origin(scene.json 裸 origin 字段,
    // 未经父链解析),= 该 quad 相对父挂点(attach 点)的偏移,单位=父 mesh-local 像素。
    // 通用 quad attach 公式:quadCenterWorld = parentOrigin + R(parentAngle)·((attachPos + attachLocalOrigin)·parentScale)
    // (attachPos = 父 puppet 该挂点的 mesh-local 平移)。有自身 puppet 的部件走蒙皮路径,不用此字段。
    var attachLocalOrigin: SIMD2<Float> = .zero
    // 挂点骨所属的父 puppet 对象 id(嵌套挂点每帧位移传播用):本层挂到此对象的具名骨。若该对象**自身**也挂着上层骨
    //   (如知更鸟头挂身体锁骨、五官又挂头),其每帧动画位移要传给本层,否则人物晃动时本层(五官)不跟随=分离。
    //   = attach 公式里的 cpid(嵌套)/pid(直挂)。非嵌套时该父不挂骨 → 每帧位移为 0 → 零回归。
    var attachParentObjId: Int = -1
    // 基础材质(genericimage2/3/4)的 shader + combos + 常量。供 SceneRenderEngine 对带特性的图层
    // (NORMALMAP/REFLECTION/LIGHTING/EMISSIVE/PBR 等)用转译的 material/<shader> 变体渲染;plain 层不用。
    var materialShader: String? = nil          // "genericimage2"/"genericimage3"/"genericimage4"
    var materialCombos: [String: String] = [:] // pass0 combos
    var materialConstants: [String: [Float]] = [:]  // pass0 constantshadervalues(标量/向量)
    var animationLayers: [AnimationLayerDesc] = []  // puppet warp 动画层(解析存下,渲染未实现)
    // 对象 origin/angles 字段挂的 WE 关键帧动画(如头发/发饰随头摆动:origin+angles 贝塞尔关键帧)。
    // 真 WE 特性;过去整个关键帧通道停用(为防打雷 opacity 过曝),但 origin/angles 与过曝无关,单独放行。
    var originKeyAnim: WEKeyframeAnimation? = nil
    var angleKeyAnim: WEKeyframeAnimation? = nil
    // 对象 alpha 字段挂的 WE 关键帧动画(**开场动画**:全屏黑层 alpha frame0=1→末帧=0 淡出露出内容,mode=single 播一次)。
    // 过去整个关键帧 alpha 通道停用(为防打雷 composelayer 的 opacity×pulse 过曝),但**普通图层/solidlayer**
    // 的对象 alpha 与过曝无关:应用点用 `!frameBufferInput` 门控天然排除打雷 pulse / region 音频 composelayer,单独放行。
    var alphaKeyAnim: WEKeyframeAnimation? = nil
    var effectPassOverrides: [[EffectPassOverrideDesc]] = []  // 与 effects 一一对应:每特效的 pass override 列表
    var effects: [LayerEffect] = []   // 图层后处理效果链
    var text: TextLayerDesc? = nil    // 文本图层(时钟/日期);非 nil 时纹理由 TextLayerRenderer 动态生成
    var audioBars: AudioBarsDesc? = nil  // 音频频谱条层(由系统音频驱动)
    var scaleScript: WEScript? = nil  // scale 字段挂的 WE JS 脚本(如 "Second" 秒进度条);每帧驱动该层 scale
    var baseScale: SIMD3<Float> = SIMD3(1, 1, 1)  // scaleScript 的输入基准(脚本 update(value) 的初值)
    // origin 字段挂的 WE JS 脚本(挂件容器/时钟/日期/鼠标指针):value.x = scriptProperties.x * engine.canvasSize.x
    // 之类。本层**局部** origin 每帧由它驱动(WE 行为)。nil 时 origin 走静态 originPx(绝大多数图层)。
    var originScript: WEScript? = nil
    var baseLocalOrigin: SIMD3<Float> = .zero   // originScript 的输入基准(脚本 update(value) 的 value 初值 = 裸 .value)
    // 父链(到根)的累积绝对 origin / 缩放(解析期算定)。本层每帧只重算**自己**的局部 origin 脚本,
    // 再用 parentAbsOrigin + parentAbsScale × 局部 origin 还原绝对 origin。WE 时钟/挂件包里有脚本的父
    // 容器其 origin 脚本恒为 canvasSize×slider(静态),故父链解析期值每帧有效;纯静态父也对。
    var parentAbsOrigin: SIMD3<Float> = .zero
    var parentAbsScale: SIMD3<Float> = SIMD3(1, 1, 1)
    // 父链累积 z 角度(#2):有 origin 脚本的层每帧把局部 origin 用 rotateVec2 绕此角旋到世界。父角=0 → 恒等。
    var parentAbsAngle: Float = 0
    // angles 字段挂的 WE JS 脚本(#3:如 3470764447 容器的 zRotation):每帧驱动本层**局部** z 角度。
    // 渲染角度 = parentAbsAngle + 脚本局部 z(弧度)。nil 时角度走静态 anglesDeg.z(已含累计父角,绝大多数图层)。
    var angleScript: WEScript? = nil
    var baseLocalAngles: SIMD3<Float> = .zero   // angleScript 的输入基准(脚本 update(value) 的 value 初值 = 裸 .value)
    // 缺口B/D:visible/alpha/color 字段挂的 WE JS 脚本(lwe 每帧 reevaluate,CScene.cpp:351-384)。按
    // engine.timeOfDay/Date/Math.random/音频 决定显隐与色彩(昼夜切换图层、色温、淡入淡出)。
    // nil = 静态值(走 visible / color,绝大多数图层)。失败回退静态。基准值即 visible / color。
    var visibleScript: WEScript? = nil
    var alphaScript: WEScript? = nil
    var colorScript: WEScript? = nil
    // 运行时动态建层脚本(thisScene.createLayer:Haimiya Mio 等的环形/直排音频条,init 里建 NUM_BARS 根 bar、
    // update 里按音频写每根 bar 的 origin/scale/alignment)。非 nil 时该层是「bar 模板」:引擎用同一贴图
    // 多实例渲染脚本读回的每根 bar(SceneRenderEngine.runDynamicBars)。
    // 取代旧的「把这种 init/update 脚本误当 visibleScript → getLayerIndex 未定义 → JS 异常 → 音频条不显示」。
    var instancedBarsScript: WEScript? = nil
    var instancedBarBaseSize: SIMD2<Float> = SIMD2(4, 4)   // 单根 bar 的基准像素尺寸(bar.json autosize → 纹理 wh)
}

/// 音频频谱条标记(solidlayer 挂了 Simple_Audio_Bars effect)。仅作「这是音频条层」的标记 +
/// 记录条数/颜色/间距;真实绘制参数与 perspective 透视由该层的 effects 链(Simple_Audio_Bars +
/// perspective,经 parseEffects → WEEffectChain)用 WE 真实 shader 完成。
struct AudioBarsDesc {
    var barCount: Int = 32
    var color: SIMD3<Float> = SIMD3(1, 1, 1)
    var spacing: Float = 0.17    // 条间距占比
}

/// 声音对象(ObjectParser.cpp:206-221, SoundData)。即便暂不播放也解析存下,不静默丢。
/// playbackmode 是可选串(loop 等);sounds 是音频文件路径数组。
struct SoundDesc {
    var id: Int
    var name: String
    var playbackmode: String?     // "loop"=循环;"random"=随机挑曲、曲间静默 min..maxtime;其它/单曲=循环
    var sounds: [String]          // 音频文件路径(pkg 内或 sounds/ 下)
    var volume: Float = 1         // 对象级音量 0..1(WE 有,lwe 忽略;我们乘进最终音量)
    var minTime: Float = 0        // random 模式曲间静默下限(秒)
    var maxTime: Float = 0        // random 模式曲间静默上限(秒)
    var startSilent: Bool = false // 初始静音(载入但不自动播)
}

/// 动画图层(puppet warp,ObjectParser.cpp:453-463 / ImageAnimationLayer)。
/// 挂在 image 对象的 "animationlayers" 下;每条驱动一个 puppet 骨骼/网格动画。
/// 仅解析存下(puppet warp 渲染未实现);各字段可被 user/脚本属性包装,故解析后取最终值。
struct AnimationLayerDesc {
    var id: Int
    var rate: Float = 1          // 播放速率
    var visible: Bool = false    // WE 默认 false(ObjectParser.cpp:459)
    var blend: Float = 1         // 混合权重
    var animation: Int = 0       // 动画索引
    var additive: Bool = false   // additive 叠加层(御剑龙「动画 2」=true:在 base 姿势上叠加位移)
    var name: String = ""        // 动画层名(待机动画/互动/特殊cg…):供 init 脚本 .stop("名") 默认停掉事件动画
}

/// effect pass override 的单个常量绑定(ObjectParser.cpp:381-394 / ImageEffectPassOverride)。
/// WE 里每个 constant 是个 UserSetting(可挂 property/condition/script)。这里至少保留原始
/// 求值后的字符串值 + 是否有 property/script/condition 连接的标记;真正的逐帧 property/script
/// 求值绑定(bindScriptContext)未实现 —— 见 parseEffects 处的 TODO。
struct EffectConstantBinding {
    var value: String            // 求值/unwrap 后的字符串(给 WEEffectChain 当 csv 用)
    var property: String?        // 连接的用户属性 key(短形 {user:"key"} 或条件形 name)
    var condition: String?       // 条件串(条件形 {user:{name,condition}})
    var hasScript: Bool = false  // 该常量挂了 JS 脚本({script:...})
}

/// effect pass override(ObjectParser.cpp:381-394)。覆盖某 effect 某 pass 的 combos/textures/constants。
/// id<0 表示未指定。textures: slot→引用(parseTextureMap,index→name)。
struct EffectPassOverrideDesc {
    var id: Int = -1
    var combos: [String: String] = [:]
    var textures: [Int: String] = [:]          // slot → 纹理引用(覆盖 material pass 的对应槽)
    var constants: [String: EffectConstantBinding] = [:]  // 常量名 → 绑定(保留 property/condition/script)
    var shaderOverride: String? = nil           // 覆盖 MaterialPass.shader(Object.h:61)
}

/// effect 内嵌的 FBO 声明(EffectParser.cpp:98-114 / Effect.h FBO)。组合层/中间渲染目标用。
/// 渲染由 SceneRenderEngine 负责;这里仅解析建模。
struct EffectFBODesc {
    var name: String
    var format: String = "rgba8888"
    var scale: Float = 1
    var unique: Bool = false
}

/// effect 内单个 pass 的 command(EffectParser.cpp:47-79 / EffectPass)。
/// command="copy"→copy,"swap"→swap;source/target 是 FBO 名(command 存在时必填)。
struct EffectCommandDesc {
    var command: String          // "copy" / "swap"
    var source: String?          // 渲染来源 FBO
    var target: String?          // 渲染目标 FBO
    var binds: [Int: String] = [:]  // texture bind:slot → FBO 名
}

/// projectlayer / FBO 组合层的解析建模(给 SceneRenderEngine 用,渲染不在本任务)。
/// 一个挂了 effect 的图层,其 effect.json 里可声明 fbos[] + passes[] 的 command/source/target/bind。
/// 这里把这些「组合层指令」抽出来存进 doc,供引擎搭 FBO 链。
struct ProjectLayerDesc {
    var id: Int
    var name: String
    var imageRef: String                 // 原始 image 引用(含 "projectlayer")
    var originPx: SIMD3<Float> = .zero
    var sizePx: SIMD2<Float>? = nil
    var visible: Bool = true
    var fbos: [EffectFBODesc] = []        // effect.json 声明的 FBO
    var commands: [EffectCommandDesc] = []  // effect pass 的 copy/swap + source/target/bind
    var effects: [LayerEffect] = []       // 该层的转译特效链(若有真 shader 内容)
}

/// 完整相机参数(WallpaperParser.cpp:46-78)。orthographic projection 的 auto 标记决定画布尺寸是否
/// 由窗口自动定;center/eye/up 定相机基,nearz/farz/fov 是透视参数,fade 是相机淡入。
/// 现有渲染只用 ortho w/h 当画布;其余字段解析存下供未来 3D/透视相机用。
struct CameraDesc {
    var center: SIMD3<Float> = .zero
    var eye: SIMD3<Float> = SIMD3(0, 0, 1)
    var up: SIMD3<Float> = SIMD3(0, 1, 0)
    var nearZ: Float = 0
    var farZ: Float = 1000
    var fov: Float = 50
    var fade: Bool = false                // camerafade
    var preview: Bool = false             // camerapreview
    // orthogonalprojection.auto:画布尺寸自动(随窗口)。
    // 审计修复(#4)契约:为 true 时,上层渲染**应用窗口尺寸**覆盖 SceneDocument.canvasWidth/Height,
    // orthoWidth/orthoHeight(= 存储的 width/height)仅作窗口尺寸不可用时的回退。
    var orthoAuto: Bool = false
    var orthoWidth: Float = 1920
    var orthoHeight: Float = 1080
    // 缺口2:透视 vs 正交相机判别。
    // 依据:lwe Camera 类**只**支持正交场景相机——CScene.cpp:34-74 无条件 setOrthogonalProjection,
    // 且 WallpaperParser.cpp:28-29 对 "orthogonalprojection" 用 require(缺失即抛)。即 lwe 不支持透视场景,
    // 没有 setPerspectiveProjection 可移植(穷尽 grep:Camera.cpp 仅 ortho;唯一 perspective 构建在
    // CParticle.cpp:1884-1896,是粒子级、eye 硬编码 (0,0,1000),非场景相机)。
    // 真 WE 语义(授权扣数据):scene.json 的 general.orthogonalprojection 为 **null/缺失** 时该场景是 3D/透视
    // 场景(实测 assets/scenes/modeleditor:orthogonalprojection=null 且 general 顶层带 fov/nearz/farz/zoom;
    // 对照 particleeditor:orthogonalprojection={width,height} 且无 fov=正交)。透视 proj 照 lwe Camera 已备好的
    // 接口语义建:perspective(radians(fov), aspect, nearz, farz) · lookAt(eye,center,up)(Camera.cpp:13 lookAt、
    // :36-40 getFov/getNearZ/getFarZ;CParticle.cpp:1892 glm::perspective(fov,aspect,nearz,farz) 用法移植)。
    var isPerspective: Bool = false
    // 3D 透视场景的**运行时相机对象**(objects 里 camera:"default"、静态 origin=eye)。顶层 scene["camera"]
    // 的 eye/center 常是**编辑器残留视角**(实测土星 3589454154:顶层 eye=(3.66,1.39,2.30) 看 (3.30,1.17,1.39)
    // → 土星 x=0 渲到左偏 0.36 不居中;而相机对象 id=243 camera:"default" origin=(0,0,2.3) 看 -z → 土星正中)。
    // 与太阳系(运行时相机 eye=(0,0,4.54))同理。非 nil 时引擎用它(eye=objEye 看 -z)替代顶层 scene.camera。
    var objEye: SIMD3<Float>? = nil
    var objFov: Float? = nil
}

/// 2D 场景**相机运镜**(per-object camera path 的 origin/zoom 关键帧动画)。
/// === 来源与机制(WE 真义,lwe 未实现)===
/// 部分壁纸的 scene.json objects 里有一个特殊对象带 `camera:"default"` 字段(无 image/text/sound/light/shape),
/// 它是**相机路径对象**(WE 编辑器的 camera track):
///   · `origin`:相机眼位(canvas 像素空间),`{animation:{c0,c1,c2}, value:base}` 三通道(x/y/z),`relative:true`
///     → 关键帧值是相对 base 的偏移(已在 WEKeyframeAnimation.evaluate 里 +base)。base 通常 = 画布中心 z=500。
///   · `zoom`:标量缩放因子,`{animation:{c0}, value:1}`,**非 relative**。1=原始取景,>1=推近(content 放大)。
///   · `path`:指向 scripts/camera_paths_*.json(实测多为 `{"paths":[]}` 空 → 仅靠 origin/zoom 关键帧驱动)。
/// === lwe 是否实现 ===
/// **否**(穷尽确认):lwe Camera 只 setOrthogonalProjection(eye/center/up 静态),CScene.cpp:34/74 读的是
/// scene 顶层 `camera` 子节(center/eye/up),从不读 objects 里的 camera-path 对象,没有 origin/zoom 关键帧求值,
/// `zoom` 在 lwe 仅指**纹理 UV 填充模式**(ZoomFit/ZoomFill,与运镜无关)。故照真 WE 数据语义自实现。
/// === 投影映射(正交场景)===
/// 静态正交 proj 把画布像素映到 NDC。相机运镜 = 在 proj **之前**对世界(画布像素)做仿射:
///   1) zoom:绕**取景中心**(base.xy=画布中心)缩放 zoom 倍(zoom=3 → content 3× 放大 = 推近);
///   2) pan:相机眼位 origin.xy 相对**帧0值**移动 → content 反向平移(相机右移=画面左移)。
///      用帧0(非 base)作中性参考:frame0 的 origin/zoom = establishing shot(本壁纸 origin(0)=(0,0)、zoom=1)。
/// origin.z 在正交投影下不改变取景尺寸(ortho 无透视),推近完全由 zoom 表达(WE 正交场景的运镜约定)。
/// 引擎据此每帧重算等效 proj(无相机动画的壁纸 = identity 运镜矩阵 → proj 逐位不变,零回归)。
struct CameraPathAnim {
    var origin: WEKeyframeAnimation?   // 相机眼位 xyz 关键帧(canvas 像素;relative→已含 base)
    var zoom: WEKeyframeAnimation?     // 缩放因子标量关键帧(非 relative)
    var lengthFrames: Float = 180      // 一个 cycle 总帧数(origin.options.length;@30fps)
    var fps: Float = 30
    // 静止态(末关键帧 = establishing/resting shot)取景值,作 pan/zoom 的参考基准。
    // 运镜矩阵在稳态时 = identity → 内容居中;intro 从帧0(俯冲/拉远)飞入、落到此静止态。
    // ⚠ 必须取静止态而非帧0:Lucy 这类 intro 从帧0 落到 (0,0),取帧0 作基准会让稳态永久偏
    //   (末关键帧 − 帧0)之差(Lucy = -1470px 竖偏 → 内容顶到上方、下方露灰底)。
    var originAtRest: SIMD2<Float> = .zero   // origin.xy(末关键帧/静止)
    var zoomAtRest: Float = 1                // zoom(末关键帧/静止)
    /// 该相机对象是否真带可驱动运镜的关键帧(origin 或 zoom 任一有动画且非恒定)。无 → 不启用(零回归)。
    var hasAnimation: Bool { origin != nil || zoom != nil }
}

/// 解析后的场景文档:画布尺寸 + 背景色 + 图层列表(按绘制顺序,后画的在上)。
struct SceneDocument {
    var canvasWidth: Float
    var canvasHeight: Float
    var clearColor: SIMD4<Float>
    // 环境光(general.ambientcolor;lwe WallpaperParser.cpp:42 默认 vec3(0))。喂 LIGHTING 材质的 g_LightAmbientColor。
    // 全库 0 张用 LIGHTING combo → 当前零视觉影响,但读 pkg 真值(非硬编码 1,1,1)以合规+未来正确。
    var ambientColor: SIMD3<Float> = .zero
    var layers: [LayerDesc]
    var emitters: [ParticleEmitterDesc] = []
    // 声音对象(ObjectParser.cpp:206-221)。解析存下;播放未实现(见返回说明)。
    var sounds: [SoundDesc] = []
    // 完整相机(WallpaperParser.cpp:46-78)。渲染仍只用 ortho w/h(=画布);其余存下供未来透视相机。
    var camera = CameraDesc()
    // 2D 场景相机**运镜**(objects 里 camera:"default" 路径对象的 origin/zoom 关键帧):开场推近再回弹等。
    // nil(绝大多数壁纸无此对象)→ 相机完全静态(零回归)。非 nil → 引擎每帧按求值的 zoom/pan 重算等效投影。
    var cameraAnim: CameraPathAnim? = nil
    // projectlayer / FBO 组合层(ObjectParser 的 projectlayer + EffectParser 的 fbos/command)。
    // 解析建模存下,FBO 链的实际搭建/渲染由 SceneRenderEngine 负责(本任务不渲染)。
    var projectLayers: [ProjectLayerDesc] = []
    var hasCursorRipple: Bool = false   // 场景含 cursorripple 效果 → 鼠标划过激起水波
    // cursorripple 在 projectlayer 上,WE 只折射该 projectlayer **下方**的层(其余层在其上、不被折射)。
    // = 该 projectlayer 出现时已解析的渲染层数。layers[0..<cutoff] 套 cursorripple,之上的(草地/前景)不套。
    var cursorRippleLayerCutoff: Int = 0
    var rippleParams: SIMD4<Float> = SIMD4(1, 1, 1, 1)   // (strength, scale, speed, decay)
    var rippleMaskPath: String? = nil   // cursorripple 碰撞遮罩(限定力场在水面;无则全屏起波=草地也波)
    var cameraParallax: Bool = true     // general.cameraparallax:关时整个场景无视差/漂移
    // WE 相机真实参数:视差是鼠标驱动、静止归中(无自动漂移);camerashake 由 pkg 控制的噪声抖动。
    // 都按 general 真值,不再自造正弦"呼吸"漂移(那不是 WE)。
    var cameraParallaxAmount: Float = 1
    var cameraParallaxMouseInfluence: Float = 1
    // general.cameraparallaxdelay:平滑速率(lwe CScene.cpp:399 delay=clamp(delay×dt,0,1) 的 mix 系数)。
    // lwe 缺省 0(=冻结),但实库 41/47 取 0.1;按 general 真值读,无字段时退 0。
    var cameraParallaxDelay: Float = 0
    var cameraShake: Bool = false
    var cameraShakeAmplitude: Float = 0
    var cameraShakeRoughness: Float = 0   // lwe WallpaperParser.cpp:63 缺省 0
    var cameraShakeSpeed: Float = 0       // lwe WallpaperParser.cpp:64 缺省 0
    // 用户在「壁纸设置」里改过(覆盖值 ≠ project.json 默认)的属性名集合(project.json key)。
    //   跨层写回的控制器脚本(土星 Dock)在首帧据此派发 applyUserProperties,触发其重置派生状态
    //   (隐藏图标);无改动 = 空集 → 脚本走默认值、行为同 pkg(零回归)。
    var changedUserPropertyNames: [String] = []
    // 跨层逻辑控制器脚本(applyUserProperties / Dock 显隐):挂在无 image 容器对象 visible 字段、用 getLayer
    //   写其它层显隐的脚本(土星 Dock 主控)。引擎每帧跑 update + readLayerWrites 回灌目标层。空集 → 零影响。
    var logicScripts: [WEScript] = []
    // 后处理(fullscreenlayer 上的 bloom/filmgrain/localcontrast 等):真 WE 转译特效链,
    // 按 scene 顺序、仅可见者。在最终合成帧上依次跑 WEEffectChain(替代旧的手写假 bloom)。
    var postChain: [LayerEffect] = []
    // 后处理边界:layers[postChainLayerCutoff...] 排在最后一个 postChain fullscreenlayer **之上**(渲染序在后),
    //   不应被该后处理染色/模糊(WE/lwe 语义:fullscreenlayer 只作用于其下方场景)。引擎据此把这些上方图层
    //   留到 postChain 跑完后再叠到已后处理画面上。0 或 ≥layers.count = 无上方图层(行为同旧:全部参与后处理)。
    var postChainLayerCutoff = 0
    // —— 后处理回退字段(postChain 非空时不用):bloom 已是 lwe 真 4-pass 移植(见 PostProcess)。——
    // 触发条件:相机级 general.bloom=true(WE 相机内建,无 effects/bloom 文件夹故进不了 manifest/postChain),
    // 或 fullscreenlayer 上 file 含 "bloom" 的特效未被转译覆盖。lwe(WallpaperParser.cpp:51-52)缺省 strength/threshold 全 0。
    var postBloom = false
    var postBloomThreshold: Float = 0   // lwe WallpaperParser.cpp:52 缺省 0
    var postBloomStrength: Float = 0    // lwe WallpaperParser.cpp:51 缺省 0
    var postBloomTint: SIMD3<Float> = SIMD3(1, 1, 1)
    // 含「时间滤镜」脚本(按 getHours 切昼夜主题,如白影轻扬 3497488774)→ 引擎施加时段色彩分级。
    var hasTimeFilter = false
    var postLocalContrast = false
    var postLocalContrastStrength: Float = 0.2

    /// 从 SceneSource 解析 scene.json 并解析图层→纹理引用链。
    /// item 提供时,载入用户在「壁纸设置」里的覆盖值,使可调属性生效。
    static func build(from source: SceneSource, item: WallpaperItem? = nil) -> SceneDocument? {
        // 载入该壁纸的属性覆盖(user-key → 值),供 VecParse.unwrap 在解析时套用。
        VecParse.overrides = Self.loadOverrides(item)
        defer { VecParse.overrides = [:] }   // 解析完清掉,避免影响下一个场景
        // 用户改过(覆盖值 ≠ project.json 默认)的属性名 —— 供跨层控制器脚本(Dock)首帧派发 applyUserProperties。
        let changedUserPropertyNames = Self.changedUserProperties(item)

        // scene.json 可能在根或 scene/ 下。
        let sceneJSON = source.json(for: "scene.json") ?? source.json(for: "scene/scene.json")
        guard let scene = sceneJSON else { return nil }

        let general = scene["general"] as? [String: Any] ?? [:]
        // 完整相机(WallpaperParser.cpp:42-78)。ortho w/h 仍当画布尺寸(渲染照旧);
        // 其余字段(center/eye/up/nearz/farz/fov/fade/preview/auto)解析进 CameraDesc 存下。
        var camera = CameraDesc()
        var cw: Float = 1920, ch: Float = 1080
        if let op = general["orthogonalprojection"] as? [String: Any] {
            // WallpaperParser.cpp:72-74:auto 为真时 width/height 记 0(由窗口定);否则读真值。
            camera.orthoAuto = (op["auto"] as? NSNumber)?.boolValue ?? false
            cw = (op["width"] as? NSNumber)?.floatValue ?? cw
            ch = (op["height"] as? NSNumber)?.floatValue ?? ch
            // 审计修复(#4):orthoAuto 此前读了没用。WE 在 auto 时用**窗口**尺寸而非存储 width/height 当画布。
            // 本文件拿不到窗口尺寸(画布尺寸最终进 SceneDocument.canvasWidth/Height,由上层渲染消费),
            // 故无法在此直接驱动 —— 已在 CameraDesc.orthoAuto 标注契约:为 true 时上层应用窗口尺寸覆盖
            // doc.canvasWidth/Height(camera.orthoWidth/Height 仅作回退)。此处保守保留存储值当回退画布,
            // 不强行写 0(避免下游按 0 尺寸分母出错)。TODO(上层渲染):auto 时以窗口尺寸为准。
            camera.orthoWidth = cw
            camera.orthoHeight = ch
        } else {
            // 缺口2:orthogonalprojection 为 null/缺失 → 透视(3D)场景(见 CameraDesc.isPerspective 依据)。
            // 此时画布尺寸无 ortho w/h 可取,沿用默认 1920×1080(orthoAuto 契约外的回退;cw/ch 已是默认)。
            // 透视场景把 fov/nearz/farz 放在 general 顶层(实测 modeleditor:general.fov/nearz/farz),
            // camera 子节通常只有 center/eye/up。先用 general 顶层值作为相机投影参数的默认,
            // 下方 camera 子节若另带 nearz/farz/fov 仍按 WallpaperParser.cpp:75-77 覆盖(camera 子节优先)。
            camera.isPerspective = true
            if let n = (VecParse.unwrap(general["nearz"]) as? NSNumber)?.floatValue { camera.nearZ = n }
            if let f = (VecParse.unwrap(general["farz"])  as? NSNumber)?.floatValue { camera.farZ  = f }
            if let v = (VecParse.unwrap(general["fov"])   as? NSNumber)?.floatValue { camera.fov   = v }
        }
        // camera 子节(scene.json 顶层的 "camera",WallpaperParser.cpp:26/67-77)。可缺失。
        if let cam = scene["camera"] as? [String: Any] {
            camera.center = VecParse.f3(cam["center"], default: camera.center)
            camera.eye    = VecParse.f3(cam["eye"], default: camera.eye)
            camera.up     = VecParse.f3(cam["up"], default: camera.up)
            if let n = (cam["nearz"] as? NSNumber)?.floatValue { camera.nearZ = n }
            if let f = (cam["farz"]  as? NSNumber)?.floatValue { camera.farZ = f }
            if let v = (cam["fov"]   as? NSNumber)?.floatValue { camera.fov = v }
        }
        camera.fade    = (VecParse.unwrap(general["camerafade"]) as? Bool) ?? false
        // 审计修复(#7):camerapreview 与相邻 camerafade 一致走 unwrap(可能被 user/脚本属性包装)。
        camera.preview = (VecParse.unwrap(general["camerapreview"]) as? Bool) ?? false
        // lwe(WallpaperParser.cpp:44):clearcolor 缺省 = 白 vec3(1.0);CScene.cpp:91 glClearColor 永远 alpha=1.0,只用 RGB。
        var clear = VecParse.f4(general["clearcolor"], default: SIMD4(1, 1, 1, 1))
        clear.w = 1
        // 相机视差总开关(general.cameraparallax,可被脚本属性包装)。关时全场景无视差/漂移。
        let cameraParallax = (VecParse.unwrap(general["cameraparallax"]) as? Bool) ?? true
        func gf(_ k: String, _ d: Float) -> Float { (VecParse.unwrap(general[k]) as? NSNumber)?.floatValue ?? d }
        let cameraParallaxAmount = gf("cameraparallaxamount", 1)
        let cameraParallaxMouseInfluence = gf("cameraparallaxmouseinfluence", 1)
        let cameraParallaxDelay = gf("cameraparallaxdelay", 0)
        let cameraShake = (VecParse.unwrap(general["camerashake"]) as? Bool) ?? false
        let cameraShakeAmplitude = gf("camerashakeamplitude", 0)
        let cameraShakeRoughness = gf("camerashakeroughness", 0)  // lwe WallpaperParser.cpp:63 缺省 0
        let cameraShakeSpeed = gf("camerashakespeed", 0)          // lwe WallpaperParser.cpp:64 缺省 0

        let objects = scene["objects"] as? [[String: Any]] ?? []

        // 2D 场景相机运镜(camera:"default" 路径对象的 origin/zoom 关键帧);在主对象循环里检测填充,末尾写回 doc。
        var cameraAnim: CameraPathAnim? = nil

        // 父子图层:child 的 origin 是相对 parent 的偏移。先建 id→局部origin / id→parent 表,
        // 再算每个图层的累积绝对 origin(沿 parent 链相加)。11/43 场景用到(如咕咕嘎嘎企鹅各部件)。
        var localOrigin: [Int: SIMD3<Float>] = [:]
        var localScale: [Int: SIMD3<Float>] = [:]
        // 每对象的**局部** z 旋转角(WE angles 单位是弧度,见 SceneRenderEngine.matModel 注释)。
        // 父层旋转传递(CImage.cpp:163/168):子的世界 origin 要把「父缩放后的子偏移」绕**累计父角度**旋转,
        // 子的渲染角度要叠加累计父角度。父角度=0 时 rotateVec2 退化为恒等、叠加 0 不变 → 与旧结果逐像素相同。
        var localAngleZ: [Int: Float] = [:]
        var parentOf: [Int: Int] = [:]
        var dependsOn: [Int: [Int]] = [:]   // 对象 dependencies:须先于本对象渲染的对象 id 列表(lwe CScene 拓扑排序用)
        // origin 脚本(挂件容器/时钟/日期/鼠标指针):id → (脚本实例, 裸 .value 初值)。
        // 关键修复(飘字根因 A):WE 的 origin 是**脚本字段**,本引擎此前永远只取裸 .value(作者在别画布
        // 存的旧快照,如容器 cached=(1315,1419) 实际应为 canvasSize×slider)。这里给 origin 接脚本,
        // 首帧用 runVec3 求真实局部 origin 写回 localOrigin,使 absoluteOrigin 拿到真值(不再散落飘顶)。
        let canvas = SIMD2(cw, ch)
        var originScriptOf: [Int: WEScript] = [:]
        var originBaseOf: [Int: SIMD3<Float>] = [:]
        // angles 脚本(#3:如 3470764447 容器 4995 的 zRotation 默认 90°):id → (脚本实例, 裸 .value 初值)。
        // 仿照 origin/scale:angles 字段也可能挂 WE JS 脚本,此前只在 origin/scale 解析脚本,angles 被当裸值 → 0。
        var angleScriptOf: [Int: WEScript] = [:]
        var angleBaseOf: [Int: SIMD3<Float>] = [:]
        for obj in objects {
            guard let id = (obj["id"] as? NSNumber)?.intValue else { continue }
            let bareOrigin = VecParse.f3(obj["origin"])   // 裸 .value(脚本失败时的回退 + 脚本 update(value) 的输入)
            localScale[id] = VecParse.f3(obj["scale"], default: SIMD3(1, 1, 1))
            if let pid = (obj["parent"] as? NSNumber)?.intValue { parentOf[id] = pid }
            // dependencies(ObjectParser.cpp:190-204):另一组 id,须先创建/渲染。区别于 parent(变换层级)。
            if let deps = obj["dependencies"] as? [Any] {
                let ids = deps.compactMap { ($0 as? NSNumber)?.intValue }
                if !ids.isEmpty { dependsOn[id] = ids }
            }
            // 仿照 scale:origin 也可能挂 WE JS 脚本。成功解析则首帧求真实局部 origin 写回。
            if let os = Self.parseVectorScript(obj["origin"], tag: (obj["name"] as? String ?? "origin"), canvas: canvas) {
                originScriptOf[id] = os
                originBaseOf[id] = bareOrigin
                // 审计修复(#1):首帧求值用 sim t=0/dt=0(保持确定);后续逐帧由 SceneRenderEngine.update 传真实 sim time/dt。
                if case .vec3(let v) = os.runVec3(current: bareOrigin, simTime: 0, frametime: 0) {
                    localOrigin[id] = v          // 脚本真值(canvasSize×slider 等)
                } else {
                    localOrigin[id] = bareOrigin // 脚本失败 → 退裸 .value(旧行为)
                }
            } else {
                localOrigin[id] = bareOrigin
            }
            // #3:angles 也可能挂脚本(zRotation 等)。成功解析则首帧求真实局部角度;否则用裸 .value。
            // 单位约定:scene.json 的**静态** angles 已是弧度(matModel 直接用);而 angles **脚本**的
            //   zRotation 滑块是**度数**(实测 3470764447 容器 4995:slider "Z 轴旋转角度" min=-90 max=90,
            //   update() 直接 return value.z=zRotation=90)。故脚本结果 z 走度→弧转换(SceneModel.scriptAngleZ)。
            //   父角=0 不变量不受影响:无 angles 脚本的层 localAngleZ 仍取静态弧度,完全不变。
            let bareAngles = VecParse.f3(obj["angles"])
            if let asx = Self.parseVectorScript(obj["angles"], tag: (obj["name"] as? String ?? "angles"), canvas: canvas) {
                angleScriptOf[id] = asx
                angleBaseOf[id] = bareAngles
                // 审计修复(#1):首帧求值用 sim t=0/dt=0(保持确定);后续逐帧由 SceneRenderEngine.update 传真实 sim time/dt。
                if case .vec3(let v) = asx.runVec3(current: bareAngles, simTime: 0, frametime: 0) {
                    localAngleZ[id] = Self.scriptAngleZToRadians(v.z)   // 脚本 z(度)→ 弧度
                } else {
                    localAngleZ[id] = bareAngles.z   // 脚本失败 → 退裸 .value(已是弧度)
                }
            } else {
                localAngleZ[id] = bareAngles.z
            }
        }
        // 2D 向量绕 z 角(弧度)旋转。**与 CImage.cpp:28-32 的 rotateVec2 逐式相同**,也与
        // SceneRenderEngine.matModel 的旋转(标准 CCW:x'=c·x−s·y, y'=s·x+c·y)同向 —— 沿用现有角度符号,
        // 不翻 Y、不翻角度符号。angle=0 时 cos=1/sin=0 → 返回 (x,y) 恒等 → 父角度=0 时下方变换零变化。
        func rotateVec2(_ v: SIMD2<Float>, _ angle: Float) -> SIMD2<Float> {
            let c = cos(angle), s = sin(angle)
            return SIMD2(v.x * c - v.y * s, v.x * s + v.y * c)
        }
        // 解析父链层级变换(CImage.cpp:129-171 resolveTransform 的逐式移植):返回该 id 的
        //   (世界 origin, 累积 scale, 累积 z 角度)。递归:先解析父的完整变换 pt,再
        //   local = rotateVec2(childOrigin×pt.scale, pt.angle);world = pt.origin + local;
        //   scale ×= pt.scale;angle += pt.angle。无父则直接返回自身局部值。
        // **父角度=0 不变量**:pt.angle=0 → rotateVec2 退化恒等 → world = pt.origin + pt.scale×childOrigin
        //   (与旧 absoluteOrigin 的「乘父缩放+加父原点」逐位相同);angle 叠加 0 不变 → 逐像素一致。
        func resolveTransform(_ id: Int, _ depth: Int) -> (origin: SIMD3<Float>, scale: SIMD3<Float>, angle: Float) {
            let origin = localOrigin[id] ?? .zero
            let scale = localScale[id] ?? SIMD3(1, 1, 1)
            let angle = localAngleZ[id] ?? 0
            guard depth < 32, let pid = parentOf[id] else { return (origin, scale, angle) }
            let pt = resolveTransform(pid, depth + 1)
            // 父缩放后的子偏移绕**累计父角度**旋转(z 偏移只乘 z 缩放,与参考一致)。
            let local = rotateVec2(SIMD2(origin.x * pt.scale.x, origin.y * pt.scale.y), pt.angle)
            let world = SIMD3(pt.origin.x + local.x,
                              pt.origin.y + local.y,
                              pt.origin.z + origin.z * pt.scale.z)
            return (world, scale * pt.scale, angle + pt.angle)
        }
        // 子 id 在祖先 stopAt 的**局部坐标系**(stopAt 自身贡献=0/单位)里的相对偏移,中间链每级 scale/angle 都复合
        //   (与 resolveTransform 同构,只是把 stopAt 当根)。挂点用:attachLocalOrigin 必须是子相对挂点骨所在父
        //   (cpid)的 mesh-local 偏移,**要含中间容器的 scale**——麻匪 xraypad-眠 的头发/头容器 scale=2.02249(故意
        //   反消身体 0.49444 让子按原图分辨率渲),旧分支裸加 origin 漏乘 → 五官被拉散 ~176px=「两组脸」。
        func relOriginUnder(_ id: Int, _ stopAt: Int, _ depth: Int) -> (origin: SIMD3<Float>, scale: SIMD3<Float>, angle: Float) {
            if id == stopAt { return (.zero, SIMD3(1, 1, 1), 0) }
            let origin = localOrigin[id] ?? .zero
            let scale = localScale[id] ?? SIMD3(1, 1, 1)
            let angle = localAngleZ[id] ?? 0
            guard depth < 32, let pid = parentOf[id] else { return (origin, scale, angle) }
            let pt = relOriginUnder(pid, stopAt, depth + 1)
            let local = rotateVec2(SIMD2(origin.x * pt.scale.x, origin.y * pt.scale.y), pt.angle)
            let world = SIMD3(pt.origin.x + local.x, pt.origin.y + local.y, pt.origin.z + origin.z * pt.scale.z)
            return (world, scale * pt.scale, angle + pt.angle)
        }
        // 子图层 origin 在父的局部空间:换算到世界要逐级「乘父缩放、绕累计父角旋转、再加父原点」(WE 层级变换)。
        func absoluteOrigin(_ id: Int) -> SIMD3<Float> { resolveTransform(id, 0).origin }
        // 子图层有效缩放 = 自身 × 所有祖先缩放(决定渲染大小)。
        func absoluteScale(_ id: Int) -> SIMD3<Float> { resolveTransform(id, 0).scale }
        // #2(b):子图层渲染角度 = 自身 z 角 + 所有祖先 z 角累加(CImage.cpp:168)。喂给 matModel 的 angleDegZ。
        func absoluteAngle(_ id: Int) -> Float { resolveTransform(id, 0).angle }
        // 仅**父链**(不含自身)的累积绝对 origin / 缩放 / 角度。供有 origin/angle 脚本的层每帧还原:
        //   absOrigin(本帧) = parentAbsOrigin + rotateVec2(parentAbsScale × 局部origin脚本结果, parentAbsAngle)。
        func parentAbsoluteOrigin(_ id: Int) -> SIMD3<Float> {
            guard let p0 = parentOf[id] else { return .zero }
            return resolveTransform(p0, 0).origin
        }
        func parentAbsoluteScale(_ id: Int) -> SIMD3<Float> {
            guard let p0 = parentOf[id] else { return SIMD3(1, 1, 1) }
            return resolveTransform(p0, 0).scale
        }
        // 父链(不含自身)累积 z 角度。供有 origin 脚本的层每帧把局部 origin 旋到世界(matModel 角度另由 absoluteAngle 给)。
        func parentAbsoluteAngle(_ id: Int) -> Float {
            guard let p0 = parentOf[id] else { return 0 }
            return resolveTransform(p0, 0).angle
        }
        // 有效可见性 = 自身 visible AND 所有祖先 visible(WE 父组继承)。缺这个的话:挂在父组上的
        // 开关控制不了子对象——如 3174556087 雨:Rain Effects 组 > Rain downpour(raineffect 开关)
        // + Rain Puddles 组(dynamicrainpuddles 开关)> 7 个溅水(自身 visible=null 永远开)。
        // 旧代码逐对象只看自身 visible → 7 溅水永远在、raineffect 只控 1/9 发射器 → "雨开关切了没反应"。
        // selfVisible 用 parseVisible(走 VecParse.overrides,即用户开关的当前值);粒子与图层都用 effectiveVisible。
        // 调试:WP_SHOW_IDS=228,464 强制指定图层可见(对称 WP_HIDE_IDS),用于验证默认隐藏(用户开关 false)
        // 的图层(如 3233141951 的音频可视化开关层)是否正确渲染。生产默认空 → 零影响。
        let forceShow: Set<Int> = Set((ProcessInfo.processInfo.environment["WP_SHOW_IDS"] ?? "")
            .split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) })
        var selfVisible: [Int: Bool] = [:]
        // ⭐默认停掉的动画层(2026-06-19,从 pkg init 脚本提取):很多角色的 init 控制脚本调
        //   getLayer("层名").getAnimationLayer("动画名").stop() 把 `互动`/`特殊cg` 这类**事件/交互触发**动画默认停掉
        //   (只在鼠标互动/特殊事件时才 play)。我方没实现 .stop() → 把这些 additive 事件层当常驻一直叠 → `特殊cg`
        //   把眼睛压成闭着(知更鸟该睁眼却闭)。此处正则扫所有 visible 脚本的 .stop() 调用,建 [层名→停掉的动画名集],
        //   建图层时排除被停的动画层 = 忠实 WE 默认 idle 状态。WP_NO_ANIM_STOP=1 退回(全播)。
        var stoppedAnims: [String: Set<String>] = [:]
        if ProcessInfo.processInfo.environment["WP_NO_ANIM_STOP"] == nil,
           let re = try? NSRegularExpression(pattern: #"getLayer\(\s*["']([^"']+)["']\s*\)\s*\.getAnimationLayer\(\s*["']([^"']+)["']\s*\)\s*\.stop\(\)"#) {
            for ob in objects {
                guard let vis = ob["visible"] as? [String: Any], let s = vis["script"] as? String,
                      s.contains("getAnimationLayer") else { continue }
                let ns = s as NSString
                for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
                    let ln = ns.substring(with: m.range(at: 1)), an = ns.substring(with: m.range(at: 2))
                    stoppedAnims[ln, default: []].insert(an)
                }
            }
        }
        for obj in objects {
            guard let id = (obj["id"] as? NSNumber)?.intValue else { continue }
            selfVisible[id] = forceShow.contains(id) ? true : Self.parseVisible(obj["visible"])
        }
        // 调试:WP_ONLY_IDS=593,363 → 只渲列出的 id,其余全隐(用于隔离单层看形状/方向,排除随机粒子噪声)
        let onlyIds: Set<Int> = Set((ProcessInfo.processInfo.environment["WP_ONLY_IDS"] ?? "")
            .split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) })
        func effectiveVisible(_ id: Int) -> Bool {
            if !onlyIds.isEmpty { return onlyIds.contains(id) }
            if forceShow.contains(id) { return true }
            var v = selfVisible[id] ?? true
            var pid = parentOf[id], n = 0
            while let p = pid, n < 16 { v = v && (selfVisible[p] ?? true); pid = parentOf[p]; n += 1 }
            return v
        }

        // 部件间 attachment 解析支持:id→对象,供查父对象的 puppet/size。
        var objById: [Int: [String: Any]] = [:]
        for obj in objects { if let id = (obj["id"] as? NSNumber)?.intValue { objById[id] = obj } }
        // ⭐视差深度沿父链继承(绑定关系):子层没写 parallaxDepth → 用最近祖先设了的值(真 WE:时钟/日期
        //   文字 parent=木板组、自身 parallaxDepth=None → 继承「视差定位点」根的深度 → 整组木板+文字一起晃、
        //   文字始终在木板上)。旧逻辑对 None 一律默认 (1,1) 满视差 → 子文字与父木板视差幅度不同 → 鼠标视差时
        //   文字飘离木板(用户实测)。都没设才退 (1,1)(独立层零变化)。WP_NO_PARALLAX_INHERIT=1 退回旧。
        func effectiveParallaxDepth(_ id: Int) -> SIMD2<Float> {
            if ProcessInfo.processInfo.environment["WP_NO_PARALLAX_INHERIT"] != nil,
               let o = objById[id] { return VecParse.parallaxDepth(o) }
            var cur: Int? = id, depth = 0
            while let c = cur, depth < 32 {
                if let o = objById[c], o["parallaxDepth"] != nil { return VecParse.f2(o["parallaxDepth"]) }
                cur = parentOf[c]; depth += 1
            }
            return ProcessInfo.processInfo.environment["WP_PARALLAX_LWE"] != nil ? .zero : SIMD2(1, 1)
        }
        // 给定父 id,返回 (父 puppet 路径, 父 scene size, 父骨骼动画 id?, rate)。父对象须有 image→model.json→puppet。
        // animId/rate 来自父对象 animationlayers 首个 visible(否则首个)条目(对应 MDLA 动画 id):
        //   凯尔希主体 = anim206「呼吸」,让头骨 bone5 逐帧移动 → 供子部件动态跟随挂点。无动画时 animId=nil。
        func parentPuppetInfo(_ pid: Int) -> (puppet: String, size: SIMD2<Float>, animId: Int?, animRate: Float)? {
            guard let pobj = objById[pid],
                  let pimg = pobj["image"] as? String,
                  let pmodel = source.json(for: pimg),
                  let pup = pmodel["puppet"] as? String else { return nil }
            let ps = VecParse.floats(pobj["size"])
            guard ps.count >= 2 else { return nil }
            let pAnims = Self.parseAnimationLayers(pobj["animationlayers"])
            let chosen = pAnims.first(where: { $0.visible }) ?? pAnims.first
            return (pup, SIMD2(ps[0], ps[1]), chosen.map { $0.animation }, chosen?.rate ?? 1)
        }
        // ⭐嵌套挂点位移传播(2026-06-18,知更鸟「白蛋脸」根因修复)。
        //   pkg 语义(由**已知正确**的凯尔希思衡托反推证实):挂点子对象的 origin 是**相对挂点骨**的——
        //   子渲染中心 = 父origin + R(父角)·((attachPos骨位 + 子origin)·父scale)。当**父 puppet 对象自身也挂在
        //   更上层的骨上**(知更鸟:头`头+脖子`挂身体「锁骨」→ 头渲染在挂点位移后的高位;五官又挂这个头的「头」骨),
        //   子用的 parentRenderOrigin 必须含父的挂点位移,否则子拿父的**静态**origin 定位 → 头移子不移 = 头脸分离
        //   (头基底裸皮肤=白蛋)。本函数累积 id **自身+祖先链**上每一层 attachment 的挂点位移(= R(祖父角)·(骨位·祖父scale))。
        //   非嵌套(凯尔希思衡托:父=主体不挂任何骨)→ 返回 0,零回归。WP_NO_ATTACH_PROPAGATE=1 退回旧行为(A/B)。
        var _attachMeshCache: [String: PuppetMesh?] = [:]
        func attachShiftOf(_ id: Int) -> SIMD2<Float> {
            if ProcessInfo.processInfo.environment["WP_NO_ATTACH_PROPAGATE"] != nil { return .zero }
            var shift = SIMD2<Float>.zero
            var cur: Int? = id; var hops = 0
            while let c = cur, hops < 32 {
                hops += 1
                if let cobj = objById[c], let att = cobj["attachment"] as? String, !att.isEmpty,
                   let gp = parentOf[c], let pinfo = parentPuppetInfo(gp) {
                    let mesh: PuppetMesh?
                    if let cached = _attachMeshCache[pinfo.puppet] { mesh = cached }
                    else { mesh = source.data(for: pinfo.puppet).flatMap { PuppetMesh.parse($0, size: pinfo.size) }; _attachMeshCache[pinfo.puppet] = mesh }
                    if let m = mesh, let aw = m.attachmentWorld(att) {
                        let attachPos = SIMD2(aw.columns.3.x, aw.columns.3.y)
                        let pT = resolveTransform(gp, 0)
                        shift += rotateVec2(SIMD2(attachPos.x * pT.scale.x, attachPos.y * pT.scale.y), pT.angle)
                    }
                }
                cur = parentOf[c]
            }
            return shift
        }

        var layers: [LayerDesc] = []
        var sounds: [SoundDesc] = []
        // 跨层逻辑控制器脚本(applyUserProperties / Dock 显隐):挂在**无 image 的容器对象** visible 字段、
        //   用 getLayer 写其它层显隐的脚本(土星 Dock 主控 id=425「Sykm dock」就是这种——无美术内容,纯
        //   据 scriptProperties.enableDock 每帧写各图标层 alpha/visible)。这类对象会被下方 image guard 丢弃,
        //   故此处单独收集;引擎安装真实层注册表 + 每帧跑其 update + readLayerWrites 回灌目标层。
        var logicScripts: [WEScript] = []
        var projectLayers: [ProjectLayerDesc] = []
        var hasCursorRipple = false
        var cursorRippleCutoff = 0
        var rippleParams = SIMD4<Float>(1, 1, 1, 1)
        var rippleMaskPath: String? = nil
        var postChain: [LayerEffect] = []
        // 后处理边界:最后一个贡献 postChain 的 fullscreenlayer 之上(渲染序在后)的图层不应被该后处理影响
        //   (WE/lwe:fullscreenlayer 后处理只作用于其**下方**已合成的场景,其上的图层/UI 直接叠在已后处理画面之上)。
        //   记下「该后处理层解析时已入 layers 的数量」= 上方图层在 layers[] 数组的起始下标。
        //   典型:时钟/日期/星期文本(Misty Valley id322/329/337/364)排在 darkambient tint(id330)之上 →
        //   旧实现把 tint 当整帧 postChain 跑、连文本一起染暗(白字被 Tint(0.694)压到 ~177 灰)→ 文字偏暗 bug。
        var postChainLayerCutoff = 0
        var postBloom = false, postLC = false
        // 辉光参数取 pkg 真实 general(bloomstrength/threshold/tint)。lwe(WallpaperParser.cpp:51-52)缺省全 0
        // (bloom:true 但未写 strength/threshold 时 → 无辉光,与 lwe 一致;不再用自创注解默认 0.65/2.0)。
        var postBloomTh: Float = (VecParse.unwrap(general["bloomthreshold"]) as? NSNumber)?.floatValue ?? 0
        var postBloomStr: Float = (VecParse.unwrap(general["bloomstrength"]) as? NSNumber)?.floatValue ?? 0
        let postBloomTint = VecParse.f3(general["bloomtint"], default: SIMD3(1, 1, 1))
        // 相机级 bloom:WE 的 general.bloom 是相机内建后处理(无 effects/bloom 文件夹 → 不进 manifest/postChain),
        // 之前只看 fullscreenlayer 的 bloom 特效 → 相机级 bloom 被静默丢弃。这里直接据 general.bloom 触发回退真 bloom。
        if (VecParse.unwrap(general["bloom"]) as? Bool) == true { postBloom = true }
        // HDR bloom(2026-06-11):bloom 绑 hdr 开关(bloom={user:"hdr"})时,WE 用一套**独立的 bloomhdr* 参数**——
        //   黑猫 bloomhdrstrength=1.0/threshold=1.0,远比 legacy bloomstrength=2.0/threshold=0.65 温和(后者把 HDR
        //   壁纸普遍过曝泛白,如黑猫小型版方块被吹纯白、各 HDR 壁纸偏白)。引擎此前只读 legacy → 偏白。据 hdr 切到
        //   bloomhdr*(若存在);算法仍 legacy 4-pass(先把强度/阈值对上减轻过曝;multi-iteration HDR bloom 路径
        //   是更大工程,留后续)。WP_NO_HDR_BLOOM=1 退回 legacy。相关 [xdr-colorspace-washout]。
        if (VecParse.unwrap(general["hdr"]) as? Bool) == true,
           ProcessInfo.processInfo.environment["WP_NO_HDR_BLOOM"] == nil {
            // ⭐只换 **strength**(bloomhdrstrength 常 1.0,比 legacy 2.0 温和→不过曝泛白)。
            // **threshold 保持 legacy bloomthreshold(0.65),绝不用 bloomhdrthreshold(1.0)**:bloomhdr* 那套
            //   是为 WE 的 **HDR 渲染空间**(像素可 >1.0)设计,threshold=1.0 提取「超亮(>1)」像素发光。我们引擎
            //   bloom FBO 是 8-bit **LDR**(bgra8,clamp [0,1]),提取式 saturate(maxc−threshold);threshold=1.0 →
            //   maxc 最多 1.0 → saturate(≤0)=0 → **bloom 全空、辉光消失**(用户报"hdr 没效果"真因)。LDR 下用
            //   0.65 才提得到亮区。结果:温和 strength(不过曝)+ 正常 threshold(有辉光)=用户要的 HDR 观感。
            if let v = VecParse.unwrap(general["bloomhdrstrength"]) as? NSNumber { postBloomStr = v.floatValue }
        }
        var postLCStr: Float = 0.2
        for (sceneObjIndex, obj) in objects.enumerated() {
            // 文本图层(时钟/日期):有 text 字段、无 image。单独处理。
            // ⚠ 必须走 effectiveVisible(self AND 父链),与图像层(下方 L781)一致:文本层常挂在被
            //   开关/combo 条件控制的父容器/装饰条下(如 3732211725「Misty Valley」的月相符号 ☾☽ 是
            //   Stick H/V 装饰条的子层,父条由 combo `stickh` 二选一显隐)。parseTextLayer 内部只看本对象
            //   自身 visible(其自身 newproperty=true 恒显),不看父链 → 父条隐藏(stickh==1 时 Stick H 隐)
            //   时它的月相子层仍渲 → 左右多出装饰。这里先按父链门控,父被隐则连同子文本一起不建。
            if obj["image"] == nil, obj["text"] != nil,
               ((obj["id"] as? NSNumber).map { effectiveVisible($0.intValue) } ?? true),
               var tl = Self.parseTextLayer(obj, canvas: canvas) {
                // 文本图层常挂在带缩放的时钟容器上:用累积绝对 origin + 累积缩放,
                // 否则月相/问候/日期会按未缩放距离散开。
                if let id = (obj["id"] as? NSNumber)?.intValue {
                    tl.originPx = absoluteOrigin(id)   // localOrigin[id] 已含 origin 脚本真值(见首帧求值)
                    tl.scale = absoluteScale(id)
                    tl.anglesDeg.z = absoluteAngle(id)  // #2(d):文本层也用累积绝对 z 角。父角=0 时 == 自身角。
                    // 文本图层的 origin 同样可能是脚本(时钟/日期/Day):接脚本、记父链变换供每帧重算。
                    if let os = originScriptOf[id] {
                        tl.originScript = os
                        tl.baseLocalOrigin = originBaseOf[id] ?? .zero
                        tl.parentAbsOrigin = parentAbsoluteOrigin(id)
                        tl.parentAbsScale = parentAbsoluteScale(id)
                        tl.parentAbsAngle = parentAbsoluteAngle(id)
                    }
                    // #3:文本层 angles 脚本(罕见但对齐 image 路径处理)。
                    if let asx = angleScriptOf[id] {
                        tl.angleScript = asx
                        tl.baseLocalAngles = angleBaseOf[id] ?? .zero
                        tl.parentAbsAngle = parentAbsoluteAngle(id)
                    }
                }
                // 文本层特效(2026-06-11):此前 parseTextLayer 硬编码 effects:[] → 时钟/日期/Day 上的
                // pulse/blurprecise 等特效被静默丢弃(违反"不漏用任何 pkg 数据")。与图像层一致解析进 effects
                // 链(SceneRenderEngine 的统一图层循环会据此建 mask/aux/特效链并跑 WEEffectChain;文本纹理每秒
                // 刷新、effectedTexture 每帧重算)。effectVisible 仍过滤引用未定义属性/条件不命中的特效。
                tl.effects = Self.parseEffects(obj["effects"], keepWENamed: true, source: source)
                tl.effectPassOverrides = Self.parseEffectPassOverridesPerEffect(obj["effects"])
                tl.sceneObjIndex = sceneObjIndex
                layers.append(tl); continue
            }
            // sound 对象(ObjectParser.cpp:168-169/206-221):有 "sound" 数组、无 image。
            // 解析存下(播放未实现,但不静默丢)。
            if obj["image"] == nil, let snd = Self.parseSound(obj) { sounds.append(snd); continue }
            // light / shape(VolumeLight)对象(ObjectParser.cpp:174-177):识别 + log 占位,不当未知丢。
            if obj["image"] == nil, obj["light"] != nil {
                Log.write("scene: light object not supported (id=\((obj["id"] as? NSNumber)?.intValue ?? -1), name=\(obj["name"] as? String ?? ""))")
                continue
            }
            if obj["image"] == nil, obj["shape"] != nil {
                let sid = (obj["id"] as? NSNumber)?.intValue ?? -1
                let sname = obj["name"] as? String ?? ""
                // ⭐自绘满画布特效 shape quad(如 lightshafts 阳光/光束):shape="quad" 且无 image,但挂一个
                //   **DIRECTDRAW 自绘后处理特效**(group="colorize" 的 lightshafts,combo DIRECTDRAW=1 时 frag
                //   `albedo=CAST4(0)` 忽略基底、把光束自绘到透明全屏 quad)。旧码无条件当 VolumeLight 丢 → 凯尔希
                //   ×Mon3tr(3462491575)龙上方阳光缺失。误分类修正:这种带自绘特效的 shape quad 应建成满画布
                //   透明底 + additive 合成的特效承载层(光束足迹由 shader 的 point0..3 透视 UV 决定,不靠 quad 尺寸)。
                //   只在对象**可见**(effectiveVisible:自身 + 父链 visible,默认开)且 WP_NO_LIGHTSHAFTS 未设时建。
                let shapeVisible = sid >= 0 ? effectiveVisible(sid) : Self.parseVisible(obj["visible"])
                let shapeFx = Self.parseEffects(obj["effects"], keepWENamed: true, source: source)
                let hasSelfDraw = ProcessInfo.processInfo.environment["WP_NO_LIGHTSHAFTS"] == nil
                    && shapeFx.contains { $0.weCombos["DIRECTDRAW"] == "1" }
                if shapeVisible, hasSelfDraw {
                    // ⭐**严格按 pkg**(不再猜):shape:"quad" 无 size 字段 → 用**画布尺寸**(=WE 无 size 时
                    //   fullscreen-model 的忠实回退,CImage.cpp:233-235;全库 17 个 shape quad 全无 size=普遍形式);
                    //   origin 用**对象的绝对 origin**(2094,2406,含父链),不再用画布中心;angles 用绝对 z 弧度
                    //   (1.05964≈60.7°)。lightshafts.vert `gl_Position=MVP·a_Position`:MVP(origin/size/angles)
                    //   把光束 UV[0,1] 盒子映射到屏幕这个 quad 足迹上 → 光束足迹 = 该 quad。之前**猜的 size×1.5+居中**
                    //   把整片光束盒子拉成 1.5× 全屏 = 用户指出「光占满屏」的直接原因;改回 ×1.0 + 真实 origin →
                    //   光束限制在画布尺寸的旋转 quad 足迹内、锚在头顶附近。15 个 constantshadervalues 已全部忠实喂入。
                    let lsAngle = sid >= 0 ? absoluteAngle(sid) : VecParse.f3(obj["angles"]).z
                    let lsOrigin = sid >= 0 ? absoluteOrigin(sid) : VecParse.f3(obj["origin"])
                    var ls = LayerDesc(
                        id: sid,
                        name: sname,
                        originPx: SIMD3(lsOrigin.x, lsOrigin.y, 0),
                        sizePx: SIMD2(canvas.x, canvas.y),
                        scale: SIMD3(1, 1, 1),
                        anglesDeg: SIMD3(0, 0, lsAngle),
                        parallax: SIMD2(0, 0),
                        visible: shapeVisible,
                        texturePath: nil,
                        color: SIMD4(1, 1, 1, 1),
                        blend: .additive,        // DIRECTDRAW 光束:加性合成(shader 已写 alpha=光束强度)
                        isSolid: false,
                        effects: shapeFx
                    )
                    ls.effectPassOverrides = Self.parseEffectPassOverridesPerEffect(obj["effects"])
                    ls.selfDrawFullscreen = true
                    ls.sceneObjIndex = sceneObjIndex
                    layers.append(ls)
                    Log.write("scene: lightshafts self-draw quad built (id=\(sid), name=\(sname), fx=\(shapeFx.map { $0.weName }))")
                    continue
                }
                Log.write("scene: shape/VolumeLight object not supported (id=\(sid), name=\(sname))")
                continue
            }
            // 3D 透视场景的运行时相机对象(camera:"default"、**静态** origin=eye,String 而非关键帧 dict):
            // 取它当真正的相机眼位(看 -z),替代顶层编辑器残留 scene.camera(土星 id=243 origin=(0,0,2.3)→土星居中;
            // 顶层 eye=(3.66,...)→土星左偏)。WP_NO_CAMERA_OBJ=1 退回顶层 scene.camera。
            if camera.isPerspective, obj["camera"] != nil, obj["image"] == nil, camera.objEye == nil,
               let originStr = obj["origin"] as? String,
               ProcessInfo.processInfo.environment["WP_NO_CAMERA_OBJ"] == nil {
                camera.objEye = VecParse.f3(originStr, default: .zero)
                if let fv = (obj["fov"] as? NSNumber)?.floatValue { camera.objFov = fv }
                Log.write("scene: 3D runtime camera object (id=\((obj["id"] as? NSNumber)?.intValue ?? -1)) " +
                          "eye=\(camera.objEye!) fov=\(camera.objFov ?? camera.fov) (替代顶层编辑器残留 scene.camera eye=\(camera.eye))")
            }
            // 相机路径对象(WE 编辑器 camera track):带 `camera:"default"`、无 image,承载 origin/zoom 关键帧 = 2D 运镜。
            // 只在**确有 origin/zoom 关键帧动画**时建 cameraAnim(静态相机对象只取上面的 objEye)。WP_NO_CAMERA_ANIM 退。
            if obj["image"] == nil, obj["camera"] != nil,
               ProcessInfo.processInfo.environment["WP_NO_CAMERA_ANIM"] == nil,
               cameraAnim == nil {
                // ⭐开场运镜可被用户属性关闭:camera 对象的 visible 常绑「开场动画/Opening animation」开关
                //   (如 Lucy 3521337568:camera_paths_1640 visible={user:"newproperty"})。用户关掉该开关 →
                //   parseVisible=false → 不建 cameraAnim → 不播放飞入运镜(相机停在静止取景,内容一开始就到位)。
                //   修复用户报「关闭开场动画后仍会播放一次」:此前忽略 visible 恒建 cameraAnim,重载时又从 t=0 重播。
                guard Self.parseVisible(obj["visible"]) else {
                    Log.write("scene: camera-path 运镜被用户属性关闭(visible=false)→ 跳过开场飞入")
                    continue
                }
                let originAnim = WEKeyframeAnimation.parse(obj["origin"])
                let zoomAnim = WEKeyframeAnimation.parse(obj["zoom"])
                if originAnim != nil || zoomAnim != nil {
                    var ca = CameraPathAnim(origin: originAnim, zoom: zoomAnim)
                    if let oa = originAnim {
                        ca.lengthFrames = oa.length; ca.fps = oa.fps
                        // 静止态眼位 = 末关键帧(mode:single 在 length 之后 clamp 到最后一帧)。已含 base 偏移。
                        let vr = oa.evaluate(time: oa.length / max(1, oa.fps))
                        ca.originAtRest = SIMD2(vr.count > 0 ? vr[0] : 0, vr.count > 1 ? vr[1] : 0)
                    } else if let za = zoomAnim {
                        ca.lengthFrames = za.length; ca.fps = za.fps
                    }
                    if let za = zoomAnim { ca.zoomAtRest = za.evaluate(time: za.length / max(1, za.fps)).first ?? 1 }
                    cameraAnim = ca
                    Log.write("scene: camera-path anim (id=\((obj["id"] as? NSNumber)?.intValue ?? -1)) " +
                              "origin=\(originAnim != nil) zoom=\(zoomAnim != nil) len=\(ca.lengthFrames)f@\(ca.fps) " +
                              "originRest=\(ca.originAtRest) zoomRest=\(ca.zoomAtRest)")
                }
                continue   // 相机对象不画美术内容
            }
            // 跨层逻辑控制器(applyUserProperties / Dock 显隐):无 image 容器对象,visible 挂用 getLayer 写**其它**层的
            //   脚本(土星 Dock 主控 id=425:据 scriptProperties.enableDock 每帧写各图标层 alpha/visible)。会被下方
            //   image guard 丢弃,但正是「关任务栏后隐藏图标」的控制逻辑。收集成 logicScript 由引擎安装层注册表+每帧
            //   跑 update + readLayerWrites 回灌目标层。仅 {script}+getLayer token+update() 才进 → 零影响。WP_NO_APPLY_USERPROPS 关。
            if obj["image"] == nil,
               ProcessInfo.processInfo.environment["WP_NO_APPLY_USERPROPS"] == nil,
               let vdict = obj["visible"] as? [String: Any], let vsrc = vdict["script"] as? String,
               vsrc.contains("getLayer") || vsrc.contains("getObjectByName") || vsrc.contains("getObjectById"),
               let ls = Self.parseVectorScript(obj["visible"],
                            tag: "logic:\((obj["name"] as? String) ?? "?")", canvas: canvas),
               ls.usesLayerAPI {
                logicScripts.append(ls)
                Log.write("xlayer: collected logic controller '\(obj["name"] as? String ?? "?")' (id=\((obj["id"] as? NSNumber)?.intValue ?? -1))")
                continue   // 容器对象本身不渲染(无 image),逻辑由 logicScript 承载
            }
            guard let imageRef = obj["image"] as? String else { continue }  // 只取 image 图层

            // 全屏后处理层(fullscreenlayer):不画美术内容,但承载该壁纸的真 WE 后处理特效链
            // (bloom + filmgrain + localcontrast 等)。把可见 effect 按 scene 顺序解析进 postChain,
            // 引擎在最终合成帧上依次跑 WEEffectChain(真转译 shader),替代旧手写假 bloom。
            if imageRef.contains("fullscreenlayer") {
                // 该层自身可见(postprocessing 总开关)才启用后处理链。
                // ⚠ **累加**(`+=`)不是覆盖(`=`):一张壁纸可有**多个全屏后处理层**(如 3732211725「Misty Valley」
                //   场景序 raindrop_on_glass → tint → blur),WE 按图层序依次在下方画面上跑。旧代码用 `=` 直接覆盖 →
                //   只活**最后一个**,前面的(玻璃水珠雨 raindrop_on_glass + 调色 tint)全被丢 → "雨的特效没了"。
                //   按场景顺序 append,保留全部后处理链的正确先后。单后处理层壁纸 `+=` 等价于 `=`,零影响。
                if Self.parseVisible(obj["visible"]) {
                    let added = Self.parseEffects(obj["effects"], keepWENamed: true, source: source)
                    if !added.isEmpty {
                        postChain += added
                        // 此刻 layers.count = 该后处理层之下(渲染序在前)的图层数 → 其上的图层从此下标起。
                        // 取**最后一个**有效后处理层的位置(多后处理层时,只有最末层之上的图层才完全不被后处理)。
                        postChainLayerCutoff = layers.count
                    }
                }
                // 旧字段仍解析一份(postChain 为空时的安全回退,如转译引擎缺失)。
                Self.parsePostProcess(obj, bloom: &postBloom, bloomTh: &postBloomTh, bloomStr: &postBloomStr,
                                      lc: &postLC, lcStr: &postLCStr)
                continue
            }
            // projectlayer:WE 的「组合层/中间渲染目标」,把若干子层合成进一个纹理,
            // 自身无美术内容。
            if imageRef.contains("projectlayer") {
                // 先把组合层指令(effect.json 的 fbos / passes 的 command/source/target/bind)解析建模,
                // 存进 doc.projectLayers,供 SceneRenderEngine 搭 FBO 链(渲染不在本任务)。
                let pl = Self.parseProjectLayer(obj, imageRef: imageRef, source: source,
                                                absoluteOrigin: absoluteOrigin, absoluteScale: absoluteScale)
                projectLayers.append(pl)
                // 当它只挂未实现的交互效果(cursorripple 鼠标点击涟漪)时,直接当 quad 画会出假同心圆。
                // 跳过这类容器层的常规渲染 —— 但记下 cursorripple,用全局鼠标水波(applied 到底层水面)替代。
                if Self.onlyHasInteractiveEffects(obj) {
                    // 仅当该层可见(开关 newproperty6 开)才启用鼠标水波;关了就不波动。
                    if Self.hasCursorRippleEffect(obj), Self.parseVisible(obj["visible"]) {
                        hasCursorRipple = true
                        // 此刻 layers 里已有的层 = 该 projectlayer 下方的层(渲染序在前)→ 它们才被 cursorripple 折射。
                        cursorRippleCutoff = layers.count
                        rippleParams = Self.parseRippleParams(obj)
                        rippleMaskPath = Self.parseRippleMask(obj, source: source)   // 力场遮罩(限定水面)
                    }
                    continue
                }
                // 其它 projectlayer(组合/FBO 链)的实际合成渲染由引擎据 doc.projectLayers 完成;
                // 此处不再当普通 quad 画(避免画出中间纹理的原始内容),跳过常规图层路径。
                continue
            }
            // solidlayer:无纹理纯色填充层(如背景色块、花田)。
            let isSolid = imageRef.contains("solidlayer")
            // composelayer:WE 组合层,**音频条常挂在 composelayer 上**(实测 3233141951 的「下/中/剑音条」
            // image 都是 models/util/composelayer.json)。它不含 "projectlayer" 故没被上面的容器分支拦下,
            // 会掉进常规图层路径按 composelayer.json 当贴图渲染 → 条不是原版/不出。
            let isCompose = imageRef.contains("composelayer")

            // solidlayer + 音频条 effect → 渲染成频谱条(由系统音频驱动,自创 makeAudioBarsLayer 路径)。
            // ⚠ composelayer **不**走这里:它的基底是 _rt_FullFrameBuffer(场景 FBO),makeAudioBarsLayer 会把
            // 基底当贴图渲成暗矩形框(回归)。composelayer 音频条统一走下方 frameBufferInput(场景 FBO 输入 +
            // region-fit + 真音频 shader),对齐 lwe「composelayer 就是普通 Image+effect 链」。
            if isSolid, let bars = Self.parseAudioBars(obj) {
                // #4:传入 absoluteOrigin/absoluteScale(含父链),否则音频条层用裸 origin 绕过层级变换 → 错位。
                if var barsLayer = Self.makeAudioBarsLayer(obj, bars: bars, id: (obj["id"] as? NSNumber)?.intValue ?? -1,
                                                           effectiveVisible: effectiveVisible,
                                                           absoluteOrigin: absoluteOrigin,
                                                           absoluteScale: absoluteScale, source: source) {
                    barsLayer.sceneObjIndex = sceneObjIndex
                    layers.append(barsLayer)
                }
                continue
            }
            // solidlayer 依赖其它未实现 effect(非音频条)→ 跳过避免画白块。
            if isSolid, Self.dependsOnUnsupportedEffect(obj) { continue }

            // visible 可能是 bool 或 {"value":bool,...}(用户可控属性);两种都解。
            // 用 effectiveVisible(AND 上父组链),否则挂在父组开关上的图层控制不了(见上方注释)。
            let visible = (obj["id"] as? NSNumber).map { effectiveVisible($0.intValue) } ?? Self.parseVisible(obj["visible"])

            // 解析链:image -> models/x.json -> materials/x.json -> textures[0] -> materials/<base>.tex
            var texPath: String? = nil
            var blend: BlendMode = .normal
            var color = SIMD4<Float>(1, 1, 1, 1)
            // 基础材质 shader/combos/常量(供 SceneRenderEngine 的转译材质渲染路径)。
            var matShader: String? = nil
            var matCombos: [String: String] = [:]
            var matConstants: [String: [Float]] = [:]
            // model.json 的真布尔(ModelParser.cpp:24-31):fullscreen/passthrough/autosize/solidlayer/nopadding +
            // width/height/puppet。替掉旧的「image 路径字符串猜测」,改读真字段。
            let modelJSON = source.json(for: imageRef)
            // model.json `instanced:true` = WE 场景实例化(instancing)的占位模板(如本壁纸 3147346398 的
            // id=535「Solid Placeholder」,model = {instanced:true, material:solidlayer_instance, solidlayer:true})。
            // 真 WE 靠实例缓冲把它画 N 份(各有自己的位置/尺寸,常由音频/脚本驱动),**不把模板本身当一个满屏 quad
            // 画一遍**。实例化未实现时,直接当 solid 渲染模板会按其占位 transform 画出一整块(本例 color=「0 0 0」、
            // size 256×256 × scale 16.4×10.66 = 4199×2729 的纯黑块)盖在最上层 → 黑死整个场景。故跳过该模板。
            if (modelJSON?["instanced"] as? NSNumber)?.boolValue == true {
                // ⭐**例外:带 alpha 关键帧的 instanced 占位 = 开场淡出层**(2026-06-14,修「开场动画一直不渲染」):
                //   如 3147346398 id=535「Solid Placeholder」,alpha 关键帧 frame0=1→末帧=0(黑层淡出露出场景)。
                //   旧码无条件跳过(为绕开「永久黑块盖死场景」)——但那黑块的真因是 **alpha 关键帧没动画**(=刚修的
                //   hasKeyframeAnim:纯关键帧场景被当静态→只画 t=0 黑帧)。alpha 能动画后,这种占位应**渲染+淡出**
                //   (t=0 黑→淡到透明露出场景,末了 alpha=0 不可见、无残留黑块)= 正确开场动画。仅**无 alpha 关键帧**
                //   的纯静态占位模板才跳过(防满屏黑)。WP_NO_INSTANCED_INTRO=1 退回全部跳过(A/B)。
                let hasAlphaKeyframe = (obj["alpha"] as? [String: Any])?["animation"] != nil
                    && ProcessInfo.processInfo.environment["WP_NO_INSTANCED_INTRO"] == nil
                if !hasAlphaKeyframe {
                    Log.write("scene: skip instanced placeholder layer (id=\((obj["id"] as? NSNumber)?.intValue ?? -1), name=\(obj["name"] as? String ?? ""))")
                    continue
                }
                Log.write("scene: instanced 占位含 alpha 关键帧(开场淡出)→ 渲染+动画(不跳过,id=\((obj["id"] as? NSNumber)?.intValue ?? -1))")
            }
            var mdlSolid = false, mdlFullscreen = false, mdlPassthrough = false, mdlAutosize = false, mdlNoPadding = false
            var mdlWidth: Int? = nil, mdlHeight: Int? = nil, mdlPuppet: String? = nil
            // composelayer/passthrough 层主纹理槽是 `_rt_FullFrameBuffer`(渲染目标名,非文件)→ 标记此层
            // 输入为「下方已合成整帧场景」,不当文件解析、不因 texPath==nil 被丢(见 textures 解析处赋值)。
            // composelayer.json 是 WE 内置模型(不在 pkg,source.json 取不到 → modelJSON=nil),本质是
            // _rt_FullFrameBuffer 合成层。
            // **lwe 的做法(CImage.cpp,逐行核对)**:composelayer 不区分「全屏 vs 区域性」——统一为:贴图名
            // `_rt_FullFrameBuffer` → CRenderable 解析成场景主 FBO → setupPasses 首 pass 输入 = 该 FBO、几何用
            // **该层 origin/size 的 quad**(非强制全屏)、跑特效链、末 pass 按该层屏幕位置+blend 贴回场景 FBO。
            // 全屏(打雷 pulse)只是 origin=画布中心、size=画布的特例。**「只对 pulse 启用」是我方自加的限制,非 lwe**。
            // **✅ 通用区域性 composelayer 默认开(2026-06,全库 15 张回归 mean≈0 零回归)**:任何「所有特效都已
            // 转译进 manifest(或 pulse)」的 composelayer 都走 frameBufferInput——区域 origin/size + 画布 UV 采样 +
            // 贴回 normal(见下方 frameBufferInput 块 / scene_vertex 的 fb 分支),天然限定 pkg 区域、不过曝。
            //   - **排除无特效 composelayer**(如 id=378/393「时间」框,effects=[]):纯 no-op,引擎 runLayerEffects
            //     不处理→白占位框,故 `!rawEffects.isEmpty`。
            //   - **排除含未转译特效的**:渲不全会留残缺,按铁律不渲(`allSatisfy(已转译或pulse)`)。
            // 实测受益:3233141951 id=228「音条-身体」(工坊音频 shader 2846660316,用户开了 newproperty10)正确
            //   响应音频渲身体频谱(曾因 ramp≈silent 误判它静态/坏,实为 loud vs silent diff 40.5=真响应音频)。
            // WP_NO_COMPOSELAYER_ALL=1 退回仅 pulse;WP_NO_COMPOSELAYER=1 同义(旧名兼容)。
            let rawEffects = obj["effects"] as? [[String: Any]] ?? []
            let composeHasPulse = rawEffects.contains { e in
                let f = ((e["file"] as? String) ?? "").lowercased()
                let n = ((e["name"] as? String) ?? "").lowercased()
                return f.contains("pulse") || n.contains("pulse")
            }
            // ✅ **通用区域性 composelayer 默认开(2026-06,四层修复完成,全库 15 张零回归实测)**:任何「所有特效
            //   都已转译(或 pulse)」的 composelayer 都走 frameBufferInput。四层都做对了(见 composelayer-thunder 记忆):
            //   ①region-fit(regionFit 标志,只非-pulse)②opacitymask 按 manifest combo==MASK 判定(catch影子)
            //   ③全画布遮罩裁到 region ④regionFit 层用 translucent alpha-over 贴回(透明区透出场景,非 normal 覆盖)。
            //   id=228 身体音频:navy 频谱被影子遮罩裁成身体形状、0.72 alpha 混合、响应音频。WP_NO_COMPOSELAYER_ALL=1 退回仅 pulse。
            func composeEffectRenderable(_ e: [String: Any]) -> Bool {
                // ⭐必须**可见**(未被 user 属性/condition gate 关)。被 gate 关的特效在 visible 过滤后不剩,
                //   若仍据它把该 composelayer 当 frameBufferInput,引擎会把整帧场景压进该层小 region 显示
                //   (=「壁纸小型版」白块,被 bloom 过曝成纯白)。黑猫 Lonely Cat 时钟上方白块真因:Bar2/Bar3 的
                //   Simple_Audio_Bars 被 barstyle 属性 gate 关(默认 barstyle=1,Bar2 是 ==2 变体、Bar3 是 ==3),
                //   visible 过滤后无特效,旧逻辑用 rawEffects 看到「文件已转译」仍判可渲 → 白块。
                guard Self.effectVisible(e["visible"]) else { return false }
                let file = (e["file"] as? String) ?? ""
                let fl = file.lowercased(), nl = ((e["name"] as? String) ?? "").lowercased()
                if fl.contains("pulse") || nl.contains("pulse") { return true }
                // ⭐纯变换/装饰特效(scroll 滚动 / fisheye 鱼眼)只**变换已有内容**、不产生内容。它们单独在一个
                //   composelayer 上(主内容特效如音频条已被 gate 关)时,不该让该层当 frameBufferInput——否则
                //   它们作用于 footprint 压缩的场景 = 透明/黑色碎片(黑猫 Bar3 漏网真因:Simple_Audio_Bars 被
                //   barstyle gate 关、只剩 scroll → 渲出场景碎片;白块修复只挡住了「纯音频条 gate 关」的 Bar2)。
                //   需别的产内容特效(音频条/pulse/调色)visible 才算该层有内容。Bar1(fisheye+**可见**音频条):
                //   音频条产内容 → frameBufferInput,fisheye 修饰它,不受此排除影响(此处只在「只剩纯变换」时挡)。
                if fl.contains("scroll") || fl.contains("fisheye") { return false }
                let wn = Self.weEffectName(file)
                return Self.isEffectTranspiled(wn)
            }
            // 至少有一个可渲 effect(pulse 或已转译)即走 frameBufferInput;旁挂的未转译 effect 在
            // runLayerEffects(we.has 守卫)里逐个跳过——对齐 lwe 的逐 effect 取舍(CImage 不存在「全部 effect
            // 都得支持否则整层降级」的 all-or-nothing 门)。旧的 allSatisfy 会因任一未转译 effect 把整个音频
            // composelayer 降级为贴图渲(条彻底不出 / 暗框,如 3680422061 的包裹层、3716133097 的 gradient_color)。
            var isFrameBufferInput = isCompose && rawEffects.contains(where: composeEffectRenderable)
            if ProcessInfo.processInfo.environment["WP_NO_COMPOSELAYER_ALL"] != nil
                || ProcessInfo.processInfo.environment["WP_NO_COMPOSELAYER"] != nil {
                isFrameBufferInput = isCompose && composeHasPulse   // 保守退回仅 pulse(打雷)
            }
            // model.json "cropoffset":WE 把贴图透明边裁掉省显存,记录裁剪后图相对原始全幅的偏移(纹理像素)。
            // 渲染时须据此重定位,否则各部件按裸 origin 居中、缺这一步 → 整个角色摊开散架(头发/头/五官分离)。
            // lwe 的 ModelParser 不读此字段(故 lwe 同样会散),这是照真 WE 行为补的。应用见下方 originPx 调整。
            var mdlCropOffset = SIMD2<Float>(0, 0)
            // 首 pass 的 textures/usertextures(供 instance 覆盖用)。
            var firstPassTextures: [Int: String] = [:]
            if let model = modelJSON {
                mdlSolid       = (model["solidlayer"]  as? NSNumber)?.boolValue ?? false
                mdlFullscreen  = (model["fullscreen"]  as? NSNumber)?.boolValue ?? false
                mdlPassthrough = (model["passthrough"] as? NSNumber)?.boolValue ?? false
                mdlAutosize    = (model["autosize"]    as? NSNumber)?.boolValue ?? false
                mdlNoPadding   = (model["nopadding"]   as? NSNumber)?.boolValue ?? false
                mdlWidth       = (model["width"]  as? NSNumber)?.intValue
                mdlHeight      = (model["height"] as? NSNumber)?.intValue
                mdlPuppet      = model["puppet"] as? String
                mdlCropOffset  = VecParse.f2(model["cropoffset"])
                if let matPath = model["material"] as? String,
                   let mat = source.json(for: matPath),
                   let passes = mat["passes"] as? [[String: Any]],
                   let pass0 = passes.first {
                    blend = BlendMode(raw: pass0["blending"] as? String)
                    // 捕获基础材质 shader + combos + 常量(供转译材质渲染路径;plain genericimage 不影响)。
                    matShader = pass0["shader"] as? String
                    if let cb = pass0["combos"] as? [String: Any] {
                        for (k, v) in cb {
                            if let n = v as? NSNumber { matCombos[k] = "\(n.intValue)" } else { matCombos[k] = "\(v)" }
                        }
                    }
                    if let cs = pass0["constantshadervalues"] as? [String: Any] {
                        for (k, v) in cs {
                            if let n = v as? NSNumber { matConstants[k] = [n.floatValue] }
                            else if let s = v as? String { matConstants[k] = s.split(separator: " ").compactMap { Float($0) } }
                            else if let arr = v as? [Any] { matConstants[k] = arr.compactMap { ($0 as? NSNumber)?.floatValue } }
                        }
                    }
                    if let texs = pass0["textures"] as? [Any] {
                        firstPassTextures = Self.parseTextureMap(texs)
                        // 审计修复(#5):主纹理固定取 slot0(parseTextureMap 的 [0]),不用 compactMap.first。
                        // 旧写法跳过 null,slot0 为 null 时会误把 slot1(辅助贴图)当主纹理;现 slot0 空就视为无主纹理。
                        if let base = firstPassTextures[0], !base.isEmpty {
                            // `_rt_FullFrameBuffer`(及 _rt_ 前缀)是 WE 的**渲染目标名**(场景主 FBO),非文件——
                            // composelayer/passthrough 层以它当 g_Texture0 = 「该层之下已合成的整帧场景」,在其上跑特效
                            // (如打雷 pulse 周期增亮、调色合成)再写回场景。lwe FBOProvider 同样按 _rt_ 名查场景 FBO。
                            // 标记后不当文件解析、也不在下方因 texPath==nil 被丢;渲染时由 compositeSceneBelow 喂入。
                            if base.lowercased().contains("_rt_") {
                                // `_rt_FullFrameBuffer` 基底 = composelayer 的场景 FBO,不当文件解析 texPath。
                                // ⭐但 frameBufferInput **是否成立由上方 composeEffectRenderable(含 visible 判定)决定**,
                                //   这里**不**再无条件设 true。否则 visible 过滤后无可渲特效的 composelayer
                                //   (黑猫 Bar2/Bar3 音频条被 barstyle gate 关)仍会把整帧场景压进 region 显示=白块。
                                //   isFrameBufferInput 保持 890 的判定:有 visible 可渲特效(打雷 pulse/正常音频条/调色)→ true;
                                //   全 gate 关 → false → texPath 留 nil → 下方 975 因无特效无贴图 continue 跳过(WE 行为:该层不可见)。
                            } else {
                                texPath = Self.resolveTexture(base: base, source: source)
                            }
                        }
                    }
                }
            }
            // instance 块(ObjectParser.cpp:315-328):instance.textures / instance.usertextures
            // 覆盖首 pass 的纹理槽(index→name)。textures 槽 0 = 主纹理 → 若被覆盖,主纹理路径随之改。
            if let instance = obj["instance"] as? [String: Any] {
                if let itex = instance["textures"] as? [Any] {
                    let parsed = Self.parseTextureMap(itex)
                    for (slot, name) in parsed { firstPassTextures[slot] = name }
                    // 覆盖了槽 0(主纹理)→ 重解析主纹理路径(WE 行为:instance 覆盖首 pass texture[0])。
                    if let base0 = parsed[0], !base0.isEmpty {
                        texPath = Self.resolveTexture(base: base0, source: source)
                    }
                }
                // usertextures 也并进首 pass 纹理映射(WE 单独存 usertextures,这里合并到同一槽空间;
                // 渲染未消费 usertextures 语义,仅保证不丢)。
                if let utex = instance["usertextures"] as? [Any] {
                    let parsed = Self.parseTextureMap(utex)
                    for (slot, name) in parsed { firstPassTextures[slot] = name }
                }
            }
            // 真布尔修正 isSolid:路径含 "solidlayer"(WE 也认)或 model.json solidlayer 真字段任一为真。
            let isSolidReal = isSolid || mdlSolid
            // 颜色:对象级 color 优先(solidlayer 的填充色就在这里),其次材质常量。
            // color/alpha 都可能被脚本属性包成 {"value":...},先 unwrap。
            if let c = obj["color"] { color = VecParse.f4(c, default: color) }
            if let a = VecParse.unwrap(obj["alpha"]) as? NSNumber { color.w = a.floatValue }

            // texture_override 特效(workshop 3224559305 "Texture Override"):纯色层靠它把**真实美术贴图**
            //   塞进来(pass.textures[1]=贴图名,textures[0]=null 用层基底)。本壁纸「白影轻扬」3497488774 的 41 个
            //   美术层(草地/身体/栅栏/杂草/云…)全这么做。引擎不处理 → 全退成纯色填充(color=None→白)→ 整屏泛白。
            //   真义(texture_override.frag,RETAIN_ORIG=0 默认):用覆盖贴图 g_Texture1 替换层基底,**不乘 g_Color4**。
            //   故:把覆盖贴图设为层基底纹理 + color 置白(不被填充色染),按普通图像层渲染;飘动等其余特效仍在链里跑。
            //   (texture_override 自身不在 manifest → runLayerEffects 的 we.has 门控自动跳过,无害。)
            // 多层 texture_override(耳朵 758/732、大地、花1/2/3:多个 texture_override 各带 uvOffset/scale/angle
            //   变换 + RETAIN_ORIG 前后合成,中间可夹 auto_sway 扭曲)。单层 hack(只取第一张贴图、无定位、丢后续
            //   合成层)对它们远不够 → 只渲一层 wispy 外毛、丢实心基底 → 耳朵 splay 散开(用户实测"骨骼问题很大")。
            //   这类层**保持纯 solidlayer 不套 hack** → texture_override 进 manifest 后由特效链逐 pass 真合成
            //   (solidEffectCanvasSize 给层尺寸画布当 g_Texture0;每 pass g_Texture1=覆盖贴图按 uvOffset 定位;
            //   RETAIN_ORIG=0 替换 / =1 用 blendFg(POS0)/blendBg(POS1) 前后合成)。WP_NO_TEXOVERRIDE_FX 退旧单层 hack。
            let texOvCount = (obj["effects"] as? [Any])?.reduce(0) { acc, e in
                acc + ((((e as? [String: Any])?["file"] as? String)?.contains("texture_override") ?? false) ? 1 : 0)
            } ?? 0
            let multiTexOvChain = texOvCount > 1
                && ProcessInfo.processInfo.environment["WP_NO_TEXOVERRIDE_FX"] == nil
            var texOverridden = false
            if texPath == nil, !multiTexOvChain, let ovBase = Self.textureOverrideBase(obj),
               let ovPath = Self.resolveTexture(base: ovBase, source: source) {
                texPath = ovPath
                texOverridden = true
                color = SIMD4(1, 1, 1, color.w)
            }

            // solidlayer 没有纹理但要画;有纹理但解析不到、又不是 solid 的,跳过。
            // frameBufferInput(composelayer/_rt_FullFrameBuffer)无自有贴图但要渲(输入=下方场景),不丢。
            if texPath == nil && !isSolidReal && !isFrameBufferInput { continue }

            // keepWENamed:保留所有有 weName 的真 WE 转译特效(godrays/iris/shimmer/swing/blur/
            // twirl 等没有旧 kind 映射的也照样跑真 shader),不再被 kind==.none 门丢掉。
            let effects = Self.parseEffects(obj["effects"], keepWENamed: true, source: source)
            // effect pass override(ObjectParser.cpp:381-394):与 effects 一一对应(保序、含被滤掉的位置→空)。
            let passOverrides = Self.parseEffectPassOverridesPerEffect(obj["effects"])
            // animationlayers(puppet warp,ObjectParser.cpp:439-463):rate/visible/blend/animation,解析存下。
            var animLayers = Self.parseAnimationLayers(obj["animationlayers"])
            // 排除被 init 脚本 .stop() 的事件动画层(互动/特殊cg 等):它们默认不播,只在交互/事件触发时 play。
            //   (本对象名在 stoppedAnims 里 → 去掉对应名的动画层。)修知更鸟眼睛因常驻叠 `特殊cg` 而恒闭。
            if let objNm = obj["name"] as? String, let stopped = stoppedAnims[objNm], !stopped.isEmpty {
                animLayers.removeAll { stopped.contains($0.name) }
            }
            let size = VecParse.floats(obj["size"])
            // 用累积绝对 origin(含父层偏移),否则带 parent 的图层(如企鹅部件)会跑到角落。
            let objId = (obj["id"] as? NSNumber)?.intValue ?? -1
            var absOrigin = objId >= 0 ? absoluteOrigin(objId) : VecParse.f3(obj["origin"])
            let absScale = objId >= 0 ? absoluteScale(objId) : VecParse.f3(obj["scale"], default: SIMD3(1, 1, 1))
            // alignment(CImage.cpp:228-248):origin 默认是 quad 中心;alignment 串含 top/bottom/left/right
            // 时把中心平移 ±scaledSize/2,使 origin 落到具名边(贴边音频条等)。lwe 只用单串 horizontalalign
            // ?? alignment、搜全 4 关键字(verticalalign 在 CImage 定位里未用,此处忠实照搬)。originPx 与 lwe
            // pre-flip 同为 y 向下空间 → 公式直接套(top:-sy/2、bottom:+sy/2、left:+sx/2、right:-sx/2)。
            let alignSize = VecParse.floats(obj["size"])
            let alignStr = ((obj["horizontalalign"] as? String) ?? (obj["alignment"] as? String) ?? "").lowercased()
            if !alignStr.isEmpty, alignStr != "center", alignSize.count >= 2 {
                let sx = alignSize[0] * absScale.x * 0.5, sy = alignSize[1] * absScale.y * 0.5
                if alignStr.contains("top")         { absOrigin.y -= sy }
                else if alignStr.contains("bottom") { absOrigin.y += sy }
                if alignStr.contains("left")        { absOrigin.x += sx }
                else if alignStr.contains("right")  { absOrigin.x -= sx }
            }
            // #2(d):渲染角度用**累积**绝对 z 角(自身 + 所有祖先 z 角)。父角=0 时 == 自身角(零变化)。
            // 角度三元组只 z 分量有效(matModel 只取 .z),x/y 保留原始裸值。
            var absAngles = VecParse.f3(obj["angles"])
            if objId >= 0 { absAngles.z = absoluteAngle(objId) }
            // cropoffset 重定位(发饰挡眼 / 角色部件对位真因)。lwe **完全不读** cropoffset(grep 0 命中;
            // ModelParser.cpp:19-33 只读 material/solidlayer/fullscreen/passthrough/autosize/nopadding/
            // width/height/puppet),故照**真 WE 语义**补(已授权扣 pkg 数据)。判定逻辑全部引擎级、逐对象读
            // 该对象自己的 pkg 数据(parent 字段 + 主贴图 .tex 头),**不对任何单张壁纸特判、不靠 env 门控**。
            // ── 真 WE 语义 ────────────────────────────────────────────────────────────────
            //   WE 把贴图裁进 POT 容器(texW/texH=2048…,内容 imgW/imgH 放左上角)省显存,内容相对原图发生位移;
            //   cropoffset 记录该位移(原图像素)。渲染 quad=裁后内容(铺满),须按 cropoffset 平移回原位。
            // ── 应用条件【最终,2026-06 数据定论】:贴图容器是 **2 的幂(真 POT 填充)** ──────────────
            //   读该对象主贴图 .tex 头:容器 texW/texH **都是 2 的幂** ⇒ 内容被存进 POT 大容器(如 1198→2048),
            //   cropoffset 是**真重定位偏移**,应用 `origin + cropoffset`(部件自身局部空间,经父链 scale/angle 变换)。
            //   容器**非 2 的幂**(如 1088/1856/960/1984/680=DXT 块对齐微填充)⇒ 贴图近内容尺寸存,cropoffset 是
            //   编辑器残留/已烘进 origin,套用会把本已正确的裸 origin 弄散 ⇒ **跳过**。
            // ── 全库 52 对象验证 100% 干净分离(纯 pkg 数据,跨 parent/puppet 都成立)───────────────────
            //   · 御剑 3233141951(要应用):全 15 对象容器=2048/4096/1024/512/256 全 POT。用户实测 +cropoffset
            //     露眼(发饰)、刀归位;含 puppet(刀/朱鹤/挂饰)与有父(面具/挂饰 parent=576)也都 POT → 一起应用。
            //   · 猫娘 3718960337(不应用):全 13 对象容器=1088/1856/960/832… 全非POT。baseline 贴合官方 preview;
            //     含 puppet(双眼/脚)非POT → 跳过,故不再把脸/装饰搞散(此前 rule-C 误判的根因)。
            //   · 伊蕾娜 3302695207(1984×… 非POT)、Postscript 3693137898(680×… 非POT):全跳过,baseline 正确。
            //   关键:御剑「发饰」与猫娘「发饰星链」其它属性全同(非puppet/无父/有 crop),**唯一**区别就是容器
            //   POT 与否——这才是 WE 当年是否按 POT 导出+记 cropoffset 的真信号。lwe 不读 cropoffset(此为补真 WE 语义)。
            func isPOT(_ n: Int) -> Bool { n > 0 && (n & (n - 1)) == 0 }
            var texContainerPOT = false
            if let tp = texPath, let blob = source.data(for: tp), let h = TexDecoder.headerWH(blob) {
                texContainerPOT = isPOT(h.texW) && isPOT(h.texH)
            }
            // ⭐cropoffset 规则(2026-06-10 终版,经两组用户实测铁证定):**顶层件=全量应用,有父子件=不应用**。
            //   铁证:① 刀(顶层,crop(0.5,−386.5))全量后刀刃落胸口=WE 截图位置(用户最早实测"加了偏移才跟WE相同";
            //   静息时 WE 龙嘴并不含刀——"含刀"是俯冲动画瞬间,preview 录的就是那段);② 面具/挂饰(parent=576)
            //   无偏移=用户确认正确 → 子件 origin 是父相对坐标,编辑器裁剪补偿已在父链/相对坐标里,再加=重复计算。
            //   lwe/repkg 不读 cropoffset 是它们的缺口(lwe autosize 也是 TODO),非权威。
            //   ⚠️preview.gif 不能当位置基准(camerapreview=true,WE 用独立预览相机拍的特写,画面运动一半是相机);
            //   位置基准=用户桌面截图(实况壁纸)。WP_CROP_FRAC=x 诊断覆盖(对全部件,含子件)。
            var cropShiftPx = SIMD2<Float>(0, 0)
            if objId >= 0, texContainerPOT,
               ProcessInfo.processInfo.environment["WP_NO_CROPOFFSET"] == nil,
               (mdlCropOffset.x != 0 || mdlCropOffset.y != 0) {
                // 父链累积 scale/angle(无父 → 单位 (1,1)/0,cropoffset 即世界平移);有父则把局部 crop 旋到世界。
                let pScale = parentOf[objId] != nil ? parentAbsoluteScale(objId) : SIMD3<Float>(1, 1, 1)
                let pAngle = parentOf[objId] != nil ? parentAbsoluteAngle(objId) : 0
                // ⭐终版(2026-06-10,动画修复后用户实况验证):**顶层=×0.5 半量 / 有父=×0 不应用**。
                //   刀半量后刀刃正好进静息龙嘴(用户:"正确位置跟半量差不多,刀应跟龙嘴中");发饰半量=用户一贯"最接近";
                //   面具/挂饰(parent=576)=0 用户确认。早先试此组合被否是因龙动画未修(卡bind高位)嘴刀对不上,非规则错。
                let defaultFrac: Float = parentOf[objId] == nil ? 0.5 : 0.0   // 顶层半量 / 有父不应用
                let frac = Float(ProcessInfo.processInfo.environment["WP_CROP_FRAC"] ?? "") ?? defaultFrac
                let lx = mdlCropOffset.x * frac
                let ly = mdlCropOffset.y * frac
                let shift = rotateVec2(SIMD2(pScale.x * lx, pScale.y * ly), pAngle)
                cropShiftPx = shift
                absOrigin.x += shift.x
                absOrigin.y += shift.y
            }
            // scale 字段可能挂 WE JS 脚本(如 "Second" 秒进度条:value.x=second/60)。每帧由该脚本驱动 scale。
            let scaleScript = Self.parseVectorScript(obj["scale"], tag: obj["name"] as? String ?? "scale", canvas: canvas)
            var layer = LayerDesc(
                id: objId,
                name: obj["name"] as? String ?? "",
                originPx: absOrigin,
                sizePx: size.count >= 2 ? SIMD2(size[0], size[1]) : nil,
                scale: absScale,
                anglesDeg: absAngles,
                parallax: objId >= 0 ? effectiveParallaxDepth(objId) : VecParse.parallaxDepth(obj),
                visible: visible,
                texturePath: texPath,
                color: color,
                // texOverridden 层也用 .translucent(alpha-over):texture_override(RETAIN_ORIG=0)输出恒为带 alpha
                // 的轮廓内容(贴图 DXT5/RG88 直 alpha 已正确解码),WE 一律 alpha-over 贴回。此前误用 blend(=.normal=
                // 关混合)→ 贴图整块不透明覆盖、透明区显残留 RGB = 硬边矩形块(且 95% 透明的「前装饰」整块挡住时钟牌)。
                blend: (isSolidReal || texOverridden) ? .translucent : blend,
                isSolid: isSolidReal && !texOverridden,
                effects: effects
            )
            layer.scaleScript = scaleScript
            // 缺口B/D:visible/alpha/color 字段挂的 WE JS 脚本(lwe 每帧 reevaluate)。parseVectorScript
            // 对非 {script:...} 字段返回 nil(普通层零影响);静态 visible/color 仍作脚本失败/不可用的回退。
            // ⭐运行时动态建层(音频条):有些壁纸把 init/update 脚本挂在 **visible** 字段上,init 里调
            //   thisScene.createLayer 建 NUM_BARS 根 bar、update 里按音频写每根 bar 的 origin/scale/alignment。
            //   这类脚本的 update() 是 void(不返回 bool)——若当普通 visibleScript 跑 runBool,首帧 init 会因
            //   getLayerIndex/createLayer 未定义抛 JS 异常,音频条永远不显示。改:检测到 createsLayers 时把它
            //   路由到 instancedBarsScript(引擎多实例渲染该 bar 模板),并注入模板层真实 origin/scale/angles
            //   (脚本 `baseOrigin = thisLayer.origin` 要读对);visibleScript 留 nil(不当布尔脚本驱动)。
            let visScript = Self.parseVectorScript(obj["visible"], tag: "vis:\(layer.name)", canvas: canvas)
            if let vs = visScript, vs.createsLayers {
                vs.setTemplateLayerTransform(origin: absOrigin, scale: absScale, angles: absAngles)
                layer.instancedBarsScript = vs
                // bar 模板基准像素尺寸:bar.json autosize → 纹理 wh;scene.json size 字段(此壁纸="4 4")即等于
                //   纹理 4×4(autosize 取纹理像素)。脚本每帧的 bar.scale 乘此基准得屏上一根 bar 的几何尺寸。
                layer.instancedBarBaseSize = size.count >= 2 ? SIMD2(size[0], size[1]) : SIMD2(4, 4)
                layer.visibleScript = nil
            } else {
                layer.visibleScript = visScript
            }
            layer.alphaScript   = Self.parseVectorScript(obj["alpha"],   tag: "alpha:\(layer.name)", canvas: canvas)
            layer.colorScript   = Self.parseVectorScript(obj["color"],   tag: "col:\(layer.name)", canvas: canvas)
            layer.cropOffset = mdlCropOffset
            layer.cropShiftPx = cropShiftPx
            // 对象 origin/angles 的 WE 关键帧动画(如头发/发饰随头摆动)。无 animation 时返回 nil(零影响)。
            // 无父链的层(头发0202/发饰 parent=None)关键帧值即绝对值;有父链时 update() 走父链变换。
            layer.originKeyAnim = WEKeyframeAnimation.parse(obj["origin"])
            layer.angleKeyAnim = WEKeyframeAnimation.parse(obj["angles"])
            // 对象 alpha 关键帧(开场动画黑层淡出等)。无 animation → nil(零影响)。
            layer.alphaKeyAnim = WEKeyframeAnimation.parse(obj["alpha"])
            layer.frameBufferInput = isFrameBufferInput
            // 区域性 composelayer(非 pulse:音频/调色/能量等):特效要在该层 region [0,1] 空间跑(裁场景+遮罩到 region)。
            // pulse(打雷)= false → 走原全屏画布 UV 路径(已验证,不动,避免回归)。
            layer.regionFit = isFrameBufferInput && !composeHasPulse
            // ⭐剑音条「透明长条」真因+修复(2026-06-10):御剑剑/下音条=regionFit composelayer,其 Simple_Audio_Bars
            // 特效 combo **TRANSPARENCY=0(PRESERVE)** → shader 输出 `alpha=scene.w`。真 WE 里 composelayer 读写
            // 同一不透明主 FBO(alpha恒1),条外 bar=0 处原样写回=无感;但我方 refract 壁纸走 compositeSceneBelow
            // **快照**(≠真合成、缺上层/折射粒子、刀渲在条上)作 g_Texture0、以 translucent(alpha≈1)贴回 →
            // 整片 footprint 被快照替换 = 刀周围半透明长条。修:这类层覆写 TRANSPARENCY→1(REPLACE,alpha=bar*opacity:
            // bar=0→透明无长条、bar>0→正常画条),与 lwe 可见结果一致且不依赖快照精度。作用域极窄(仅 regionFit
            // composelayer + weName 含 simple_audio_bars + 显式 TRANSPARENCY==0);另两张用此特效的壁纸是 solidlayer
            // (非 composelayer)不受影响,本壁纸中/下音条无显式 TRANSPARENCY 键(默认 REPLACE)不动。零回归。
            if layer.regionFit {
                for ei in layer.effects.indices
                where layer.effects[ei].weName.lowercased().contains("simple_audio_bars")
                    && layer.effects[ei].weCombos["TRANSPARENCY"] == "0" {
                    layer.effects[ei].weCombos["TRANSPARENCY"] = "1"
                }
            }
            // _rt_FullFrameBuffer composelayer:effectedTexture 是整帧画布底图,但绘制框用 **pkg 真实 origin/size**
            // (打雷 = 上部 3840×1400,非全屏)。过去强制全屏 quad → 打雷覆盖整朵云(用户报「只有上面一部分打雷」)。
            // 不再压扁/接缝的原因:scene_vertex 对 fb 层改用**画布 UV**(屏幕位置)采样整帧底图,quad 只是覆盖框,
            // 区域内 1:1 取底图,区域外不绘制 → 效果天然限定在 pkg 区域。origin/size 保持解析出的真值,不覆写。
            if isFrameBufferInput {
                // 全屏 composelayer(打雷 pulse):effectedTexture = 整帧场景+特效(不透明),贴回用 **normal 覆盖**
                //   (不能 additive,否则场景翻倍过曝)。
                // 区域性 composelayer(regionFit,如音频条):effectedTexture 被影子等遮罩裁出**透明区**(非身体部分),
                //   必须 **translucent(alpha-over)** 贴回 → 透明区让下方场景透出、不透明的条 alpha 混合;若用 normal
                //   覆盖,透明区会盖住场景(显黑/显裁后场景)= 大方框(第④层真因)。
                layer.blend = layer.regionFit ? .translucent : .normal
            }
            layer.isPassthrough = mdlPassthrough
            layer.baseScale = absScale     // 脚本 update(value) 的输入基准(通常 (1,1,1))
            layer.materialShader = matShader
            layer.materialCombos = matCombos
            layer.materialConstants = matConstants
            // origin 字段挂的 WE JS 脚本(挂件容器/时钟/日期/鼠标指针):每帧驱动该层**局部** origin。
            // 复用首帧已建好的实例(originScriptOf),avoid 重复 eval。无脚本则保持静态 originPx(零变化)。
            if objId >= 0, let os = originScriptOf[objId] {
                layer.originScript = os
                layer.baseLocalOrigin = originBaseOf[objId] ?? .zero
                layer.parentAbsOrigin = parentAbsoluteOrigin(objId)
                layer.parentAbsScale = parentAbsoluteScale(objId)
                layer.parentAbsAngle = parentAbsoluteAngle(objId)
            }
            // #3:angles 脚本(zRotation 等):每帧重算本层局部 z 角 → 渲染角 = parentAbsAngle + 脚本局部 z。
            if objId >= 0, let asx = angleScriptOf[objId] {
                layer.angleScript = asx
                layer.baseLocalAngles = angleBaseOf[objId] ?? .zero
                layer.parentAbsAngle = parentAbsoluteAngle(objId)
            }
            // model.json 真布尔(ModelParser.cpp:24-31),替掉旧字符串猜测。仅解析存下,渲染按需消费。
            layer.isFullscreen = mdlFullscreen
            layer.isPassthrough = mdlPassthrough
            layer.autosize = mdlAutosize
            layer.noPadding = mdlNoPadding
            layer.modelWidth = mdlWidth
            layer.modelHeight = mdlHeight
            layer.puppet = mdlPuppet
            // 部件间 attachment(scene.json 对象级 "attachment",如「头部」):本子部件挂到父对象 puppet 的同名
            // MDAT 挂点。须:① 自身有 attachment 串 ② 有父 ③ 父对象有 puppet。满足才记下父 puppet/size + 父渲染变换,
            // 由 SceneRenderEngine 把本子蒙皮顶点搬到父 mesh-local 空间、用父 transform 渲(拼回脸到光头)。
            // 不满足(全库绝大多数:无 attachment / 父非 puppet)→ 字段保持 nil,走原有渲染路径(零回归)。
            if objId >= 0, let att = obj["attachment"] as? String, !att.isEmpty,
               let pid = parentOf[objId], let pinfo = parentPuppetInfo(pid) {
                layer.attachment = att
                layer.parentPuppet = pinfo.puppet
                layer.parentPuppetSize = pinfo.size
                layer.parentAnimId = pinfo.animId
                layer.parentAnimRate = pinfo.animRate
                let pT = resolveTransform(pid, 0)
                // + attachShiftOf(pid):父 puppet 自身若也挂在更上层骨上,其渲染中心 = 静态 + 挂点位移;
                //   子必须用含位移的父中心定位(嵌套挂点),否则父移子不移=分离。非嵌套时 =0 零回归。
                let pShift = attachShiftOf(pid)
                layer.parentRenderOrigin = SIMD2(pT.origin.x + pShift.x, pT.origin.y + pShift.y)
                layer.parentRenderScale = SIMD2(pT.scale.x, pT.scale.y)
                layer.parentRenderAngle = pT.angle
                layer.attachParentObjId = pid   // 挂点骨所属对象(每帧位移传播)
                // 纯 quad 部件(无自身 puppet)用:裸局部 origin(相对父挂点的偏移,父 mesh-local 像素)。
                // 注:不能用 absOrigin(那是经父链解析的世界 origin,attach 公式要的是局部偏移)。
                let localOrg = VecParse.f3(obj["origin"])
                layer.attachLocalOrigin = SIMD2(localOrg.x, localOrg.y)
            } else if objId >= 0, ProcessInfo.processInfo.environment["WP_NO_ATTACH_INHERIT"] == nil {
                // 子孙继承挂点(2026-06-11,凯尔希头发缺失修复):对象**自身**无 attachment,但祖先链里有
                // 「attachment 串 + 其父有 puppet」的**容器**(凯尔希:2754「头发」attach 到身体 puppet 的"头发"
                // 挂点,但该容器**无 image**=纯变换;真正的头发图层 2548主发/638/785/2704刘海 是它的子,自身无
                // attachment、直接父 2754 非 puppet → 旧 gate 不命中 → 回退静态低位 origin → 头浮上去、头发留
                // 原地 = 头顶秃)。修:往上找最近这样的容器祖先 c,把中间链(自身→c,含 c)的局部 origin **累加**进
                // attachLocalOrigin → 挂点公式 attachPos+attachLocalOrigin 把各头发部件放到挂点(随头骨动)+各自
                // 偏移。中间容器若有 scale/angle 未折叠(凯尔希头发链均纯平移,够用);WP_NO_ATTACH_INHERIT=1 退回。
                var accum = VecParse.f3(obj["origin"])   // 自身局部 origin
                var cur = parentOf[objId]
                var hops = 0
                while let c = cur, hops < 32 {
                    hops += 1
                    let cobj = objById[c]
                    if let att = cobj?["attachment"] as? String, !att.isEmpty,
                       let cpid = parentOf[c], let pinfo = parentPuppetInfo(cpid) {
                        layer.attachment = att
                        layer.parentPuppet = pinfo.puppet
                        layer.parentPuppetSize = pinfo.size
                        layer.parentAnimId = pinfo.animId
                        layer.parentAnimRate = pinfo.animRate
                        let pT = resolveTransform(cpid, 0)
                        // + attachShiftOf(cpid):挂点容器的父(如知更鸟头)自身也挂着上层骨时,把其挂点位移并入,
                        //   五官/头发才跟着头一起到位(白蛋脸根因)。非嵌套 =0 零回归。
                        let cShift = attachShiftOf(cpid)
                        layer.parentRenderOrigin = SIMD2(pT.origin.x + cShift.x, pT.origin.y + cShift.y)
                        layer.parentRenderScale = SIMD2(pT.scale.x, pT.scale.y)
                        layer.parentRenderAngle = pT.angle
                        layer.attachParentObjId = cpid   // 挂点骨所属对象=容器的父(如头);其每帧位移要传给本层(五官)
                        let cOrg = VecParse.f3(cobj?["origin"])
                        accum += cOrg   // (旧)裸加挂点容器局部 origin —— 漏中间容器 scale,WP_NO_ATTACH_CONTAINER_SCALE 时退回
                        // ⭐2026-06-18 修「两组脸」:子相对挂点骨父(cpid)的偏移要含中间容器 scale/angle 复合,
                        //   不能裸加(麻匪头发容器 scale=2.02 反消身体 0.49,漏乘→五官拉散 176px)。relOriginUnder 等价
                        //   resolveTransform 把 cpid 当根。凯尔希/知更鸟容器 scale=1 时与裸加逐位相同→零回归。
                        if ProcessInfo.processInfo.environment["WP_NO_ATTACH_CONTAINER_SCALE"] != nil {
                            layer.attachLocalOrigin = SIMD2(accum.x, accum.y)
                        } else {
                            let rel = relOriginUnder(objId, cpid, 0).origin
                            layer.attachLocalOrigin = SIMD2(rel.x, rel.y)
                        }
                        break
                    }
                    accum += VecParse.f3(cobj?["origin"])   // 折叠中间容器局部 origin
                    cur = parentOf[c]
                }
            }
            layer.animationLayers = animLayers
            layer.effectPassOverrides = passOverrides
            // 对象级 colorBlendMode / brightness(ObjectParser.cpp:292-293,均可被 user 包装,故先 unwrap)。
            // 仅解析存下,渲染暂未消费(见 LayerDesc 字段处的 TODO)。
            if let cbm = VecParse.unwrap(obj["colorBlendMode"]) as? NSNumber { layer.colorBlendMode = cbm.intValue }
            if let br = VecParse.unwrap(obj["brightness"]) as? NSNumber { layer.brightness = br.floatValue }
            layer.sceneObjIndex = sceneObjIndex
            layers.append(layer)
            // ⭐cursorripple 也可挂在**普通水面图层自己**上(非 projectlayer):黑猫 Lonely Cat 的主背景
            //   LonelyCAT.json 带混合特效 [waterripple,reflection,cursorripple,pulse,shake]。旧逻辑只在
            //   projectlayer + 纯交互特效分支(L785)检测 → 黑猫这层既非 projectlayer、又混了非交互特效,
            //   两个门都不过 → hasCursorRipple 恒 false → rippleSim 从不创建 → 水面不响应鼠标。
            //   修:普通图层 append 后也检测。cutoff = layers.count(**含刚 append 的水层自己**——cursorripple 在
            //   它上面,折射作用于该水面;其上的 ripple1440p/光束/时钟 index≥cutoff 不被折射)。effectiveVisible
            //   过滤(黑猫每语言版本主背景都带 cursorripple,只当前可见的那个设一次)。WEEffectChain 仍 deny
            //   cursorripple(它跑不了流体 sim,见 weDenied),由 CursorRippleSim 专用路径渲。WP_NO_LAYER_RIPPLE 退回。
            if !hasCursorRipple, objId >= 0, effectiveVisible(objId),
               Self.hasCursorRippleEffect(obj),
               ProcessInfo.processInfo.environment["WP_NO_LAYER_RIPPLE"] == nil {
                hasCursorRipple = true
                cursorRippleCutoff = layers.count
                rippleParams = Self.parseRippleParams(obj)
                rippleMaskPath = Self.parseRippleMask(obj, source: source)
            }
        }
        // 对象 dependencies 拓扑排序(忠实移植 lwe CScene::addObjectToRenderOrder,CScene.cpp:287-320):
        // 含 dependencies 的对象须排在其依赖之后(依赖先渲染=在下层)。后序插入、原数组序作 tie-break。
        // 全库仅 2 张含 dependencies 且 dep 本就排在依赖者之前 → 对现有库零像素变化;保真补全 + 面向未来工坊壁纸。
        if dependsOn.values.contains(where: { !$0.isEmpty }) {
            let layerById = Dictionary(layers.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            var ordered: [LayerDesc] = []; ordered.reserveCapacity(layers.count)
            var seen = Set<Int>(); var inProgress = Set<Int>()
            func emit(_ id: Int) {
                if seen.contains(id) || inProgress.contains(id) { return }   // 已排 / 环(防御)→ 跳
                inProgress.insert(id)
                for dep in (dependsOn[id] ?? []) where dep != id && layerById[dep] != nil { emit(dep) }
                inProgress.remove(id)
                if let l = layerById[id] { ordered.append(l); seen.insert(id) }
            }
            for l in layers { emit(l.id) }
            layers = ordered
            // 依赖重排会打乱 layers 顺序 → 之前按数组下标记的后处理边界失效。重排极罕见(全库 2 张,
            //   且与「上方文本不被后处理」无关),保守关闭 above-post 拆分,退回旧整帧后处理(零回归)。
            postChainLayerCutoff = 0
        }

        // 标记后处理边界之上的图层(WE 语义:fullscreenlayer 后处理只作用其下方场景;其上 UI/文本叠在已后处理画面之上)。
        //   仅当后处理链真有(postChain 非空)且边界落在有效区间内才标记;否则全 false(行为同旧:全部参与后处理)。
        if !postChain.isEmpty && postChainLayerCutoff > 0 && postChainLayerCutoff < layers.count {
            for i in postChainLayerCutoff..<layers.count { layers[i].abovePost = true }
        }

        // ── 同 parallaxDepth 组继承 cropoffset(剑音条跟刀)──────────────────────────────────
        // frameBufferInput 音频条(composelayer)自身无贴图、无 cropoffset。若它与某个已应用 cropoffset 的对象
        // **同一 parallaxDepth(同视觉平面)**,说明被设计贴在那个对象上(御剑:剑音条/670 与刀同深度 2.8/3.2)。
        // 那个对象被 cropoffset 移走后,音频条须继承**最近的同深度 cropoffset 对象**的偏移才能继续贴住刀。
        // 引擎级:读 pkg 的 parallaxDepth + cropoffset,全库通用,非单壁纸 hack。WP_NO_CROPOFFSET 下全零 → 自然无操作。
        for i in layers.indices where layers[i].frameBufferInput
            && layers[i].cropShiftPx == SIMD2<Float>(0, 0)
            && (layers[i].parallax.x != 0 || layers[i].parallax.y != 0) {
            var best: (dist: Float, shift: SIMD2<Float>)? = nil
            for j in layers.indices where j != i
                && layers[j].parallax == layers[i].parallax
                && (layers[j].cropShiftPx.x != 0 || layers[j].cropShiftPx.y != 0) {
                // 用 **base(减去 cropShift 的原始)origin** 求最近,而非变换后 origin:否则系数一变(刀全量/火1半量),
                // 谁被 cropoffset 移得更近就翻 → 剑音条乱跟(踩过:刀全量后火1半量更近,剑音条跟火1偏下偏右离开刀)。
                // base 不随系数变:剑音条 base 离刀 base 极近(~40px)、离火1 base 远(~200px),稳定跟刀。
                let bjx = layers[j].originPx.x - layers[j].cropShiftPx.x
                let bjy = layers[j].originPx.y - layers[j].cropShiftPx.y
                let dx = layers[i].originPx.x - bjx
                let dy = layers[i].originPx.y - bjy
                let dist = dx * dx + dy * dy
                if best == nil || dist < best!.dist { best = (dist, layers[j].cropShiftPx) }
            }
            if let b = best {
                layers[i].originPx.x += b.shift.x
                layers[i].originPx.y += b.shift.y
            }
        }

        let emitters = ParticleParser.parseLayers(scene: scene, source: source, effectiveVisible: effectiveVisible,
                                                   absoluteOrigin: absoluteOrigin, absoluteScale: absoluteScale)
        var doc = SceneDocument(canvasWidth: cw, canvasHeight: ch, clearColor: clear, layers: layers, emitters: emitters)
        doc.ambientColor = VecParse.f3(general["ambientcolor"], default: .zero)   // lwe 默认 vec3(0);读 pkg 真值,不硬编码
        doc.hasCursorRipple = hasCursorRipple
        doc.cursorRippleLayerCutoff = cursorRippleCutoff
        doc.rippleParams = rippleParams
        doc.rippleMaskPath = rippleMaskPath
        doc.cameraParallax = cameraParallax
        doc.cameraParallaxAmount = cameraParallaxAmount
        doc.cameraParallaxMouseInfluence = cameraParallaxMouseInfluence
        doc.cameraParallaxDelay = cameraParallaxDelay
        doc.cameraShake = cameraShake
        doc.cameraShakeAmplitude = cameraShakeAmplitude
        doc.cameraShakeRoughness = cameraShakeRoughness
        doc.cameraShakeSpeed = cameraShakeSpeed
        doc.changedUserPropertyNames = changedUserPropertyNames   // 跨层控制器首帧 applyUserProperties 用
        doc.logicScripts = logicScripts                           // 无 image 容器上的 Dock 等跨层控制器脚本
        doc.postChain = postChain
        doc.postChainLayerCutoff = postChainLayerCutoff
        doc.postBloom = postBloom; doc.postBloomThreshold = postBloomTh; doc.postBloomStrength = postBloomStr
        doc.postBloomTint = postBloomTint
        doc.postLocalContrast = postLC; doc.postLocalContrastStrength = postLCStr
        doc.sounds = sounds
        doc.camera = camera
        doc.cameraAnim = cameraAnim
        doc.projectLayers = projectLayers
        // 时间滤镜检测:任一对象的 visible 脚本含 getHours + timeStage(昼夜主题主控脚本签名)
        //   → 标记 hasTimeFilter,引擎据此施加时段色彩分级(白影轻扬 3497488774 等)。
        for obj in objects {
            guard let v = obj["visible"] as? [String: Any], let s = v["script"] as? String else { continue }
            if s.contains("getHours") && (s.contains("timeStage") || s.contains("customTimeStage")) {
                doc.hasTimeFilter = true
                break
            }
        }

        // ⭐composelayer 软化阴影(2026-06-19,从 pkg + 真 WE 逆向):带特效 composelayer(如「星_阴影」opacity 0.6)
        //   且**有 image 后代**时,其后代应渲进该 composelayer 的 FBO(走 opacity 软化 + 在它 z 位身后合成),
        //   而非展平交错硬渲盖脸。判据=该 composelayer frameBufferInput **且**有 image 后代(=它处理子内容,非处理场景;
        //   音频条/打雷/blur 这类 frameBufferInput 但无 image 后代 → 不命中 → 处理场景,零回归)。
        //   WP_NO_COMPOSE_IMAGE_FBO=1 退回(后代回主场景硬渲)。
        if ProcessInfo.processInfo.environment["WP_NO_COMPOSE_IMAGE_FBO"] == nil {
            // frameBufferInput composelayer 的 obj-id 集
            let fbCompose = Set(layers.filter { $0.frameBufferInput }.map { $0.id })
            if !fbCompose.isEmpty {
                let layerIds = Set(layers.map { $0.id })
                for i in layers.indices {
                    // 沿父链(从本层的直接父起)找最近的 frameBufferInput composelayer 祖先
                    var cur = parentOf[layers[i].id], hops = 0
                    while let c = cur, hops < 32 {
                        hops += 1
                        if fbCompose.contains(c) { layers[i].renderIntoComposeId = c; break }
                        cur = parentOf[c]
                    }
                }
                // 仅当某 composelayer 确有 image 后代命中时才算「有 image 后代」(否则它仍处理场景)
                let adopted = Set(layers.compactMap { $0.renderIntoComposeId })
                // 标记:本身被采纳为「子内容容器」的 composelayer(供引擎判定用其 child FBO 当输入)
                for i in layers.indices where adopted.contains(layers[i].id) {
                    // 该 composelayer 用 child-image FBO 当特效输入(而非场景)。复用 frameBufferInput 流程,引擎据
                    //   childImageLayerIndices 非空切换输入源。此处无需额外标记(引擎按 childImageLayerIndices 判)。
                    _ = layerIds
                }
            }
        }
        // 渲染覆盖清单:逐 scene 对象列出【已渲染/未渲染 + 原因】,写日志(/tmp/coverage_<id>.log)。
        // 目的:系统性发现被「跳过」的渲染项(如曾漏的打雷 composelayer),不再靠用户逐个指出。
        Self.writeCoverageReport(objects: objects, layers: layers, emitters: emitters, sounds: sounds,
                                 projectLayers: projectLayers, postChain: postChain, source: source,
                                 wallpaperID: item?.id)
        return doc
    }

    /// 渲染覆盖清单:逐 scene 对象判定【已渲染/未渲染 + 原因】,写日志(/tmp/coverage_<id>.log + 主日志摘要)。
    /// 系统性暴露被跳过的渲染项(曾漏渲打雷 composelayer / audioline 音频可视化等),不再靠用户逐个发现。
    private static func writeCoverageReport(objects: [[String: Any]], layers: [LayerDesc],
                                            emitters: [ParticleEmitterDesc], sounds: [SoundDesc],
                                            projectLayers: [ProjectLayerDesc], postChain: [LayerEffect],
                                            source: SceneSource, wallpaperID: String?) {
        let layerIds = Set(layers.map { $0.id })
        let projIds = Set(projectLayers.map { $0.id })
        let soundIds = Set(sounds.map { $0.id })
        // 父链可见性(self AND 祖先 visible),对齐 build() 的 effectiveVisible:用于把「自身 visible=true
        // 但父被开关/combo 条件隐藏」的子层(如装饰条下的月相符号)正确归类为「父链隐藏」而非误报脚本失败。
        var selfVis: [Int: Bool] = [:]; var parentMap: [Int: Int] = [:]
        for o in objects {
            guard let oid = (o["id"] as? NSNumber)?.intValue else { continue }
            selfVis[oid] = Self.parseVisible(o["visible"])
            if let p = (o["parent"] as? NSNumber)?.intValue { parentMap[oid] = p }
        }
        func auditEffectiveVisible(_ oid: Int) -> Bool {
            var v = selfVis[oid] ?? true; var pid = parentMap[oid]; var n = 0
            while let p = pid, n < 16 { v = v && (selfVis[p] ?? true); pid = parentMap[p]; n += 1 }
            return v
        }
        var lines: [String] = []
        var rendered = 0, notRendered = 0
        for obj in objects {
            let id = (obj["id"] as? NSNumber)?.intValue ?? -1
            let name = obj["name"] as? String ?? ""
            let image = (obj["image"] as? String ?? "").lowercased()
            let visible = Self.parseVisible(obj["visible"])
            // 读 model.json 真布尔(composelayer/solidlayer/instanced 判定)。
            var mdlInstanced = false, mdlSolid = false
            if !image.isEmpty, let m = source.json(for: obj["image"] as? String ?? "") {
                mdlInstanced = (m["instanced"] as? NSNumber)?.boolValue ?? false
                mdlSolid = (m["solidlayer"] as? NSNumber)?.boolValue ?? false
            }
            var status = "未渲染", reason = ""
            if layerIds.contains(id) {
                status = "已渲染"
                reason = (obj["text"] != nil) ? "文本层"
                    : (image.isEmpty && obj["shape"] != nil ? "自绘满画布特效层(DIRECTDRAW 光束/lightshafts,additive 合成)"
                    : (image.contains("solidlayer") || mdlSolid ? "纯色/音频条层" : "图层"))
            } else if projIds.contains(id) {
                status = "已渲染"; reason = "projectlayer 组合层(FBO 链)"
            } else if soundIds.contains(id) {
                status = "已解析"; reason = "声音对象(播放未实现,WE 侧也常静音)"
            } else if obj["particle"] != nil {
                status = visible ? "已渲染" : "未渲染"; reason = visible ? "粒子系统(ParticleParser)" : "粒子层 visible=false"
            } else if !visible {
                reason = "visible=false(设计隐藏,lwe 同样不渲)"
            } else if image.contains("fullscreenlayer") {
                status = "已处理"; reason = "全屏后处理层 → postChain(\(postChain.count) 特效)"
            } else if image.contains("composelayer") {
                reason = "🔴 composelayer 被跳过:贴图槽是 _rt_FullFrameBuffer(整帧底图),其渲染未实现(如打雷/调色合成层)"
            } else if mdlInstanced {
                reason = "instanced 实例化占位模板(WE 靠实例缓冲画 N 份,模板本身不渲)"
            } else if image.isEmpty, obj["light"] != nil || obj["shape"] != nil {
                reason = "light/VolumeLight 体积光(lwe 同样不渲)"
            } else if image.isEmpty, obj["text"] != nil {
                // 文本层未成层:区分「父链被隐藏」(设计隐藏,如装饰条下的月相符号,父条由 combo 开关二选一)
                // 与「脚本求值失败」(真问题)。前者对齐 lwe 父继承,不是缺口。
                reason = auditEffectiveVisible(id)
                    ? "🔴 文本层脚本求值失败被丢(parseTextLayer 返回 nil)"
                    : "文本层父链隐藏(父对象 visible=false,lwe 同样不渲)"
            } else if (image.contains("solidlayer") || mdlSolid), Self.dependsOnUnsupportedEffect(obj) {
                reason = "🔴 solidlayer 挂未实现的音频可视化特效(如 audioline)被 dependsOnUnsupportedEffect 跳过"
            } else if image.isEmpty, obj["camera"] != nil {
                // 相机路径对象(camera:"default" + origin/zoom 关键帧)= 2D 场景运镜(开场推近等)。
                let hasAnim = WEKeyframeAnimation.parse(obj["origin"]) != nil || WEKeyframeAnimation.parse(obj["zoom"]) != nil
                status = hasAnim ? "已处理" : "未渲染"
                reason = hasAnim ? "相机路径对象 → 场景运镜(origin/zoom 关键帧驱动投影,见 cameraAnim)"
                                 : "相机路径对象(无 origin/zoom 关键帧 → 相机静态,不影响投影)"
            } else if image.isEmpty {
                reason = "无 image 且非 text/sound/light/particle → 跳过"
            } else {
                reason = "🔴 有 image 但未成层:贴图解码失败 / texPath nil / 依赖未实现特效"
            }
            if status == "未渲染" { notRendered += 1 } else { rendered += 1 }
            lines.append("[\(status)] id=\(id) name=\(name.isEmpty ? "(空)" : name) img=\(image.isEmpty ? "(无)" : (image as NSString).lastPathComponent) — \(reason)")
        }
        let header = "===== 渲染覆盖清单 wallpaper=\(wallpaperID ?? "?") 共\(objects.count)对象: 已渲染\(rendered) 未渲染\(notRendered) ====="
        let body = ([header] + lines).joined(separator: "\n")
        // 写独立覆盖日志 + 主日志摘要(未渲染项,便于修改)。
        let path = "/tmp/coverage_\(wallpaperID ?? "scene").log"
        try? body.write(toFile: path, atomically: true, encoding: .utf8)
        Log.write("coverage: \(rendered) 已渲染 / \(notRendered) 未渲染 → \(path)")
        for l in lines where l.hasPrefix("[未渲染]") { Log.write("  " + l) }
    }

    /// 解析 sound 对象(ObjectParser.cpp:206-221)。"sound" 是字符串数组(音频文件路径)。
    /// 即便暂不播放也解析存下,不静默丢。非 sound 对象返回 nil。
    private static func parseSound(_ obj: [String: Any]) -> SoundDesc? {
        guard let arr = obj["sound"] as? [Any] else { return nil }
        let paths = arr.compactMap { $0 as? String }.filter { !$0.isEmpty }
        return SoundDesc(
            id: (obj["id"] as? NSNumber)?.intValue ?? -1,
            name: obj["name"] as? String ?? "",
            playbackmode: obj["playbackmode"] as? String,   // 可选;loop/random 等
            sounds: paths,
            volume: (VecParse.unwrap(obj["volume"]) as? NSNumber)?.floatValue ?? 1,
            minTime: (obj["mintime"] as? NSNumber)?.floatValue ?? 0,
            maxTime: (obj["maxtime"] as? NSNumber)?.floatValue ?? 0,
            startSilent: (VecParse.unwrap(obj["startsilent"]) as? NSNumber)?.boolValue ?? false
        )
    }

    /// 解析 WE 的 TextureMap(ObjectParser.cpp:396-423):数组,index→纹理名。
    /// 元素可为 null(跳过该 index)、字符串(纹理名)、或 {"name": "..."} 对象。
    private static func parseTextureMap(_ arr: [Any]) -> [Int: String] {
        var out: [Int: String] = [:]
        for (idx, cur) in arr.enumerated() {
            if cur is NSNull { continue }
            if let s = cur as? String {
                if !s.isEmpty { out[idx] = s }
            } else if let dict = cur as? [String: Any], let name = dict["name"] as? String {
                out[idx] = name
            }
        }
        return out
    }

    /// 解析 animationlayers(puppet warp,ObjectParser.cpp:439-463 / ImageAnimationLayer)。
    /// 每条:id(必需)+ rate(默认1)/visible(默认 false)/blend(默认1)/animation(默认0),
    /// 各字段可被 user/脚本属性包装,故经 unwrap 取最终值。仅解析存下,渲染未实现。
    private static func parseAnimationLayers(_ raw: Any?) -> [AnimationLayerDesc] {
        guard let arr = raw as? [[String: Any]] else { return [] }
        var out: [AnimationLayerDesc] = []
        for cur in arr {
            guard let id = (cur["id"] as? NSNumber)?.intValue else { continue }   // id 必需
            var d = AnimationLayerDesc(id: id)
            if let n = VecParse.unwrap(cur["rate"])  as? NSNumber { d.rate = n.floatValue }
            d.visible = (VecParse.unwrap(cur["visible"]) as? Bool) ?? false       // WE 默认 false
            if let n = VecParse.unwrap(cur["blend"]) as? NSNumber { d.blend = n.floatValue }
            if let n = VecParse.unwrap(cur["animation"]) as? NSNumber { d.animation = n.intValue }
            d.additive = (VecParse.unwrap(cur["additive"]) as? Bool) ?? false
            d.name = (cur["name"] as? String) ?? ""
            out.append(d)
        }
        return out
    }

    /// 解析每个 effect 的 pass override 列表(ObjectParser.cpp:381-394),与 obj.effects 一一对应、保序。
    /// 注:parseEffects 会按 visible / kind 过滤掉部分 effect,而 effectPassOverrides 这里**不**过滤,
    /// 用原始 effects 数组的同序索引。引擎用时按 effect 的 weName/位置自行对齐(渲染未消费此数据,仅建模)。
    /// 每个 pass 的 constants 保留 property/condition/script 绑定(EffectConstantBinding),不再拍平丢信息。
    private static func parseEffectPassOverridesPerEffect(_ raw: Any?) -> [[EffectPassOverrideDesc]] {
        guard let arr = raw as? [[String: Any]] else { return [] }
        var out: [[EffectPassOverrideDesc]] = []
        for e in arr {
            guard let passes = e["passes"] as? [[String: Any]] else { out.append([]); continue }
            var perEffect: [EffectPassOverrideDesc] = []
            for ps in passes {
                var d = EffectPassOverrideDesc()
                d.id = (ps["id"] as? NSNumber)?.intValue ?? -1
                d.shaderOverride = ps["shader"] as? String     // Object.h:61 shaderOverride
                if let combos = ps["combos"] as? [String: Any] {
                    for (k, v) in combos {
                        if let n = v as? NSNumber { d.combos[k] = "\(n.intValue)" } else { d.combos[k] = "\(v)" }
                    }
                }
                if let texs = ps["textures"] as? [Any] { d.textures = Self.parseTextureMap(texs) }
                if let consts = ps["constantshadervalues"] as? [String: Any] {
                    for (k, v) in consts { d.constants[k] = Self.parseConstantBinding(v) }
                }
                perEffect.append(d)
            }
            out.append(perEffect)
        }
        return out
    }

    /// 把单个 effect-pass constant 解析成 EffectConstantBinding,保留 property/condition/script 绑定信息。
    /// 现状:WEEffectChain 消费的是求值后的字符串(value);这里额外**保留**绑定标记,供未来逐帧
    /// property/script 求值用(对应 ObjectParser.cpp:330-336 的 bindScriptContext,本任务不实现求值)。
    private static func parseConstantBinding(_ v: Any) -> EffectConstantBinding {
        var b = EffectConstantBinding(value: "")
        if let dict = v as? [String: Any] {
            // 脚本绑定:{script:..., value:...}
            if dict["script"] is String { b.hasScript = true }
            // 条件形:{user:{name,condition}, value:...}
            if let userObj = dict["user"] as? [String: Any] {
                b.property = userObj["name"] as? String
                b.condition = userObj["condition"] as? String
            } else if let userKey = dict["user"] as? String {
                // 短形:{user:"key", value:...}
                b.property = userKey
            }
        }
        // 求值后的最终值(经 unwrap 套用 override/condition/默认),转成字符串给 WEEffectChain 当 csv。
        let resolved = VecParse.unwrap(v)
        if let s = resolved as? String { b.value = s }
        else if let n = resolved as? NSNumber { b.value = "\(n)" }
        else if let bl = resolved as? Bool { b.value = bl ? "1" : "0" }
        return b
    }

    /// 解析 projectlayer 组合层(ObjectParser 的 projectlayer + EffectParser 的 fbos/command)。
    /// 把 effect.json 声明的 fbos[] 与各 pass 的 command/source/target/bind 抽出来建模,供 SceneRenderEngine
    /// 搭 FBO 链(渲染不在本任务)。effect.json 路径来自 obj.effects[].file。
    private static func parseProjectLayer(_ obj: [String: Any], imageRef: String, source: SceneSource,
                                          absoluteOrigin: (Int) -> SIMD3<Float>,
                                          absoluteScale: (Int) -> SIMD3<Float>) -> ProjectLayerDesc {
        let objId = (obj["id"] as? NSNumber)?.intValue ?? -1
        let size = VecParse.floats(obj["size"])
        var pl = ProjectLayerDesc(
            id: objId,
            name: obj["name"] as? String ?? "",
            imageRef: imageRef
        )
        pl.originPx = objId >= 0 ? absoluteOrigin(objId) : VecParse.f3(obj["origin"])
        pl.sizePx = size.count >= 2 ? SIMD2(size[0], size[1]) : nil
        pl.visible = Self.parseVisible(obj["visible"])
        // 转译特效链(若该层有真 shader 内容);与普通层一致用 keepWENamed。
        pl.effects = Self.parseEffects(obj["effects"], keepWENamed: true, source: source)
        // 读各 effect 的 effect.json,抽 fbos[] + passes 的 command/source/target/bind(EffectParser.cpp:47-114)。
        guard let effects = obj["effects"] as? [[String: Any]] else { return pl }
        for e in effects {
            guard let file = e["file"] as? String, let effJSON = source.json(for: file) else { continue }
            // fbos[](Effect.h FBO):name/format/scale/unique。
            if let fbos = effJSON["fbos"] as? [[String: Any]] {
                for f in fbos {
                    guard let name = f["name"] as? String else { continue }
                    pl.fbos.append(EffectFBODesc(
                        name: name,
                        format: (f["format"] as? String) ?? "rgba8888",
                        scale: (f["scale"] as? NSNumber)?.floatValue ?? 1,
                        unique: (f["unique"] as? NSNumber)?.boolValue ?? false
                    ))
                }
            }
            // passes 的 command/source/target/bind(EffectParser.cpp:55-75)。仅在 command 存在时建 command desc。
            if let passes = effJSON["passes"] as? [[String: Any]] {
                for ps in passes {
                    guard let cmd = ps["command"] as? String else { continue }
                    var c = EffectCommandDesc(command: cmd,
                                              source: ps["source"] as? String,
                                              target: ps["target"] as? String)
                    if let binds = ps["bind"] as? [[String: Any]] {
                        for b in binds {
                            if let idx = (b["index"] as? NSNumber)?.intValue, let nm = b["name"] as? String {
                                c.binds[idx] = nm
                            }
                        }
                    }
                    pl.commands.append(c)
                }
            }
        }
        return pl
    }

    /// 解析 fullscreenlayer 上的后处理 effect(bloom / localcontrast)。
    private static func parsePostProcess(_ obj: [String: Any], bloom: inout Bool, bloomTh: inout Float,
                                         bloomStr: inout Float, lc: inout Bool, lcStr: inout Float) {
        guard let effects = obj["effects"] as? [[String: Any]] else { return }
        for e in effects {
            guard Self.parseVisible(e["visible"]) else { continue }
            let file = ((e["file"] as? String) ?? "").lowercased()
            var csv: [String: Any] = [:]
            for pass in (e["passes"] as? [[String: Any]] ?? []) {
                if let c = pass["constantshadervalues"] as? [String: Any] { csv.merge(c) { a, _ in a } }
            }
            func f(_ k: String) -> Float? { (VecParse.unwrap(csv[k]) as? NSNumber)?.floatValue }
            if file.contains("bloom") {
                bloom = true
                if let t = f("Threshold") { bloomTh = t }
                if let s = f("strength") { bloomStr = s }
            } else if file.contains("localcontrast") {
                lc = true
                if let s = f("strength") { lcStr = s }
            }
            // filmgrain 等暂略(影响小)。
        }
    }

    /// 该层的 effects 是否含 cursorripple(鼠标划过水波)。
    private static func hasCursorRippleEffect(_ obj: [String: Any]) -> Bool {
        guard let effects = obj["effects"] as? [[String: Any]] else { return false }
        // cursorripple 特效自己也可被 user 属性 gate 关(如 cursoreffect 开关,默认开)——关了就不起波。
        return effects.contains {
            (($0["file"] as? String) ?? "").lowercased().contains("cursorripple")
                && Self.effectVisible($0["visible"])
        }
    }

    /// 解析 cursorripple 的参数 (strength, scale, speed, decay)。分散在多个 pass 的 csv 里。
    private static func parseRippleParams(_ obj: [String: Any]) -> SIMD4<Float> {
        var strength: Float = 1, scale: Float = 1, speed: Float = 1, decay: Float = 1
        guard let effects = obj["effects"] as? [[String: Any]] else { return SIMD4(1,1,1,1) }
        for e in effects where (((e["file"] as? String) ?? "").lowercased().contains("cursorripple")) {
            for pass in (e["passes"] as? [[String: Any]] ?? []) {
                guard let csv = pass["constantshadervalues"] as? [String: Any] else { continue }
                if let v = VecParse.unwrap(csv["ripplestrength"]) as? NSNumber { strength = v.floatValue }
                if let v = VecParse.unwrap(csv["ripplescale"]) as? NSNumber { scale = v.floatValue }
                if let v = VecParse.unwrap(csv["ripplespeed"]) as? NSNumber { speed = v.floatValue }
                if let v = VecParse.unwrap(csv["rippledecay"]) as? NSNumber { decay = v.floatValue }
            }
        }
        return SIMD4(strength, scale, speed, decay)
    }

    /// 取 cursorripple 的碰撞遮罩:simulate_force pass 的 textures 里含 "mask" 的那张
    /// (如 masks/cursorripple_simulate_force_mask_xxx)。它在 simulate pass 把力场限定在水面区(黑)、
    /// 陆地(白)force 归零 → 鼠标划过草地不起波。经 resolveMask 解到 materials/<ref>.tex。
    // 审计修复(#6):接受 source,把多级回退传给 resolveMask(力场遮罩解析更稳)。
    private static func parseRippleMask(_ obj: [String: Any], source: SceneSource? = nil) -> String? {
        guard let effects = obj["effects"] as? [[String: Any]] else { return nil }
        for e in effects where (((e["file"] as? String) ?? "").lowercased().contains("cursorripple")) {
            for pass in (e["passes"] as? [[String: Any]] ?? []) {
                for t in (pass["textures"] as? [Any] ?? []) {
                    if let s = t as? String, s.lowercased().contains("mask") { return Self.resolveMask(s, source: source) }
                }
            }
        }
        return nil
    }

    /// 从 effect 的 file 路径取 WEEffectChain 的 manifest key:
    ///  - workshop:'effects/' 之后去掉 '/effect.json' 的整条(如 'workshop/2822917890/bloom');
    ///  - builtin:'effects/' 之后的首段(如 'bloom'/'filmgrain'/'localcontrast')。
    /// 与 we_build_effects.py 的 keying 一致。
    static func weEffectName(_ file: String) -> String {
        let f = file.replacingOccurrences(of: "\\", with: "/")
        guard let r = f.range(of: "effects/") else { return "" }
        var rest = String(f[r.upperBound...])
        if rest.contains("workshop/") {
            if rest.hasSuffix("/effect.json") { rest = String(rest.dropLast("/effect.json".count)) }
            return rest
        }
        return String(rest.split(separator: "/").first ?? "")
    }

    /// 解析 object.effects[] → [LayerEffect]。每个 effect 的参数打包进 SIMD4 槽,
    /// 含义随类型(见 SceneRenderEngine 的 effect shader)。原始 GLSL 参数名见各 .frag。
    /// keepWENamed=true 时不丢弃 kind==.none 但有真 WE effect(weName 非空)的 effect
    /// —— 供后处理链(bloom/filmgrain/localcontrast 这类纯 WE 转译特效)解析。
    /// source(缺陷 3):传进后 resolveMask 能走多级 fallback(materials/<ref>.tex / <ref>.tex / 内置),
    /// 解开遮罩 .tex 不在 materials/<base>.tex 时被静默丢弃的 bug。为 nil 时退回旧单级解析(无 source 调用点)。
    static func parseEffects(_ raw: Any?, keepWENamed: Bool = false, source: SceneSource? = nil) -> [LayerEffect] {
        guard let arr = raw as? [[String: Any]] else { return [] }
        var out: [LayerEffect] = []
        for e in arr {
            // effect 自身可见性(可被脚本属性包装 / 绑用户开关)。
            guard Self.effectVisible(e["visible"]) else {
                Log.write("FXDIAG parse-drop visible-gate file=\((e["file"] as? String) ?? "?") visible=\(String(describing: e["visible"]).prefix(120))")
                continue
            }
            let kind = LayerEffectKind(file: (e["file"] as? String) ?? "")
            let weName = Self.weEffectName((e["file"] as? String) ?? "")
            // 旧内联路径:只要已知 kind;后处理链路径:保留任何有 weName 的 WE 转译特效。
            guard kind != .none || (keepWENamed && !weName.isEmpty) else {
                Log.write("FXDIAG parse-drop no-kind file=\((e["file"] as? String) ?? "?")")
                continue
            }
            // 取第一个 pass 的 constantshadervalues。
            let passes = e["passes"] as? [[String: Any]] ?? []
            let csv = (passes.first?["constantshadervalues"] as? [String: Any]) ?? [:]
            func f(_ k: String, _ d: Float) -> Float {
                if let n = VecParse.unwrap(csv[k]) as? NSNumber { return n.floatValue }
                return d
            }
            func col(_ k: String, _ d: SIMD3<Float>) -> SIMD3<Float> {
                VecParse.f3(csv[k], default: d)
            }
            var p = SIMD4<Float>(0, 0, 0, 0)
            switch kind {
            case .shake:        // p = [speed, strength, dirAngle, 0]
                p = SIMD4(f("speed", 1), f("strength", 0.1), 0, 0)
            case .waterwaves:   // p = [direction(rad), speed, scale, strength]
                p = SIMD4(f("direction", 0), f("speed", 5), f("scale", 200), f("strength", 0.1))
            case .foliagesway:  // p = [speeduv, strength, phase, power]
                p = SIMD4(f("speeduv", 5), f("strength", 0.4), f("phase", 0.5), f("power", 1))
            case .waterripple:  // p = [animationspeed, scale, ripplestrength, ratio]
                p = SIMD4(f("animationspeed", 0.15), f("scale", 1), f("ripplestrength", 0.1), f("ratio", 1))
            case .waterflow:    // p = [speed, phasescale, strength, 0]
                p = SIMD4(f("speed", 1), f("phasescale", 2), f("strength", 1), 0)
            case .scroll:       // p = [speedx, speedy, repeatX, repeatY]
                let rep = VecParse.f2(csv["repeat"], default: SIMD2(1, 1))
                p = SIMD4(f("speedx", 0.2), f("speedy", 0.2), rep.x, rep.y)
            case .tint:         // p = [r, g, b, alpha]
                let c = col("color", SIMD3(1, 0, 0)); p = SIMD4(c.x, c.y, c.z, f("alpha", 1))
            case .opacity:      // p = [alpha, 0, 0, 0]
                p = SIMD4(f("alpha", 1), 0, 0, 0)
            case .pulse:        // p = [speed, amount, power, 0](无音频→正弦呼吸)
                p = SIMD4(f("speed", 3), f("amount", 1), f("power", 1), 0)
            case .none: break
            }
            // 逐特效辅助贴图:pass.textures[N](N≥1,非 null)→ shader 采样器 g_TextureN(WE 约定)。
            // 这是定位类/位移类效果正确渲染的关键:
            //   - opacitymask 槽(waterripple/foliagesway 的 g_Texture1,combo=MASK)把效果限定在白区
            //     (如水面/树叶),不绑则退白 → 整层位移(房子跟着波动)。
            //   - 法线/相位槽(waterripple g_Texture2=normal、waterflow g_Texture2=phase)是位移源贴图,
            //     不绑则退白 → 乱位移。
            //   - flowmask 槽(shake/waterflow 的 g_Texture1)是流向场,按 slot 字面绑定即正确。
            // 引用可能是 pkg-local(masks/.../effects/...)或 WE 内置(同名在 assets),由引擎解析。
            var weAux: [Int: String] = [:]
            var maskPath: String? = nil   // opacitymask 贴图(pkg 内路径)
            // **opacitymask 槽按 manifest 的 g_Texture<N> combo=="MASK" 判定(转译已捕获),不靠贴图名**。
            //   旧逻辑靠名含 "mask" → 漏掉叫「影子」等的遮罩(opacity 效果)→ MASK combo 没设 → 大方框/不裁形状。
            // 缺陷 2:weName 是去前后缀相对路径,直查 weMaskSlots[weName] 对 workshop 副本(带前缀完整 key)
            //   会 miss → 走 basename 回退(同名=同副本 shader 同 → mask slot 声明一致)。
            let maskSlots = Self.weMaskSlotsFor(weName)
            // 缺陷 1(slot-occupancy):某 slot 在 manifest 声明了任意 combo(MASK/OPACITYMASK/…)→ scene pass
            //   给该 slot 绑非空贴图时,镜像 lwe ShaderUnit.cpp:531-619 自动启用该 combo(textureSlotUsed→1)。
            //   收集本 effect 实际被绑了非空贴图的 slot 的 combo 名,稍后据此置位 weCombos(不覆盖 pkg 显式 combo)。
            let slotCombos = Self.weSlotCombosFor(weName)
            var occupancyCombos = Set<String>()   // 据被占用 slot 派生的 combo 名
            // 辅助贴图(含 opacitymask)可绑在**任意一个 pass** 的 textures[] 上,不只首 pass。
            //   典型:blur 的 Fade 遮罩(blur_combine_mask)绑在第 4 个 pass(blur_combine,combo=MASK)的
            //   textures[1],而首 pass(downsample)无 textures → 旧逻辑只读 passes.first 永远找不到遮罩,
            //   MASK combo 不置位 → 走 MASK-0 变体(mask 恒=1)→ 整层均匀模糊(漏掉「中间清晰、两边模糊」的
            //   边缘渐变 Fade)。改:遍历所有 pass 收集 textures[](先出现的 slot 优先,与 WE 逐 pass 绑定等价——
            //   每个 g_TextureN 槽只被声明它的那个 pass 用,跨 pass 无歧义)。
            let env = ProcessInfo.processInfo.environment
            let noSlotOcc = env["WP_NO_MASK_SLOT_OCCUPANCY"] != nil
            let noSourceResolve = env["WP_NO_MASK_SOURCE_RESOLVE"] != nil   // 缺陷 3 A/B 退回(resolveMask 不传 source)
            for ps in passes {
                guard let texs = ps["textures"] as? [Any] else { continue }
                for (idx, t) in texs.enumerated() where idx >= 1 {
                    guard let s = VecParse.unwrap(t) as? String, !s.isEmpty else { continue }
                    if weAux[idx] == nil { weAux[idx] = s }
                    // 缺陷 1:slot 被绑了非空贴图 → 启用该 slot manifest 声明的 combo(lwe slot-occupancy)。
                    if !noSlotOcc, let combo = slotCombos[idx] { occupancyCombos.insert(combo) }
                    // 缺陷 3:传 source 让 resolveMask 走多级 fallback(否则只找 materials/<base>.tex → 遮罩静默丢)。
                    // maskSlots / occupancy(MASK)命中 MASK 槽,或贴图名含 mask(兜底)→ 视作遮罩贴图。
                    let isMaskSlot = maskSlots.contains(idx) || (!noSlotOcc && slotCombos[idx] == "MASK")
                    if maskPath == nil, isMaskSlot || s.lowercased().contains("mask") {
                        maskPath = Self.resolveMask(s, source: noSourceResolve ? nil : source)
                        // 缺陷 3 诊断:source-on(实际)vs source-off(旧)解析路径不同 → 旧路径会丢遮罩。
                        if env["WP_MASK_DIAG"] != nil {
                            let withSrc = Self.resolveMask(s, source: source)
                            let noSrc = Self.resolveMask(s, source: nil)
                            if withSrc != noSrc {
                                let okSrc = source?.data(for: withSrc) != nil
                                let okNo = source?.data(for: noSrc) != nil
                                Log.write("MASKDIAG-D3 fx=\(weName) ref=\(s) withSource=\(withSrc)(exists=\(okSrc)) "
                                    + "oldNoSource=\(noSrc)(exists=\(okNo))")
                            }
                        }
                    }
                }
            }
            // 转译引擎数据:csv→真实参数;pass.combos→变体键。weName 已在上面据 file 取出。
            // 逐 pass csv → [[k:v]](多 pass effect 如 bloom 各 pass 的 strength/Tint 可不同);
            // 合并版(weParams)= 全 pass 同名后写覆盖,供只读单 pass 的旧路径用。
            func packCSV(_ d: [String: Any]) -> [String: String] {
                var r: [String: String] = [:]
                for (k, v) in d {
                    if let s = VecParse.unwrap(v) as? String { r[k] = s }
                    else if let n = VecParse.unwrap(v) as? NSNumber { r[k] = "\(n)" }
                }
                return r
            }
            var weParamsPerPass: [[String: String]] = []
            var weParams: [String: String] = [:]
            for ps in passes {
                let pc = packCSV((ps["constantshadervalues"] as? [String: Any]) ?? [:])
                weParamsPerPass.append(pc)
                for (k, v) in pc { weParams[k] = v }
            }
            // 关键帧属性动画:constantshadervalues 里 `{animation:{...},value:..}` 的项(如 opacity 的 alpha
            // 淡入淡出包络=打雷)。packCSV 已把它 unwrap 成静态 value 当 fallback;这里额外存动画,每帧求值覆盖。
            var weAnim: [String: WEKeyframeAnimation] = [:]
            for ps in passes {
                guard let cs = ps["constantshadervalues"] as? [String: Any] else { continue }
                for (k, v) in cs { if let anim = WEKeyframeAnimation.parse(v) { weAnim[k] = anim } }
            }
            // combo 取**全 pass 的并集**,不能只读 passes.first ——多 pass effect 的关键 combo 常落在
            // 后面的 pass 上。典型:blur 的 COMPOSITE(投影/辉光)由场景设在第 4 个 combine pass;只读
            // 首个 pass(downsample,无 combo)会丢掉它 → 变体退回 base(COMPOSITE=0「只返回 effect」),
            // combine 把模糊图乘上 compositecolor(此场景="0 0 0"黑)直接当整层返回 → 整层成一坨黑(实测
            // 3257043844 的 2B 碎片层)。并集后 selectVariant 命中 {COMPOSITE:N} 变体,投影正确合成回原图。
            // 注:每 pass 自身的 combo(如 gaussian_y 的 VERTICAL)已由各 pass 的 material 在 build 期烘进
            // 对应变体,并集里带上 VERTICAL 无害(material 逐 pass 覆盖,且 selectVariant 子集打分优先更具体的)。
            var weCombos: [String: String] = [:]
            for ps in passes {
                guard let cb = ps["combos"] as? [String: Any] else { continue }
                for (k, v) in cb { if let n = v as? NSNumber { weCombos[k] = "\(n.intValue)" } else { weCombos[k] = "\(v)" } }
            }
            let pkgMaskExplicit = weCombos["MASK"]   // pkg 显式 MASK combo(在 occupancy/缺陷5 置位**之前**取,缺陷5诊断用)
            // 缺陷 1:slot-occupancy 派生的 combo(被绑非空贴图的 slot 声明的 combo)置 1。
            //   镜像 lwe 合并顺序(ShaderUnit.cpp:668-690)——m_combos(pkg 显式 combo)先 #define、
            //   m_discoveredCombos(slot-occupancy)仅在未定义时补:**pkg 显式 combo 优先**,不覆盖。
            //   覆盖 MASK 以外的遮罩类(OPACITYMASK)及其它 slot 声明 combo(NORMALMAP/PBRMASKS…)。
            for combo in occupancyCombos where weCombos[combo] == nil { weCombos[combo] = "1" }
            // 遮罩是隐式 combo:分配了含 "mask" 的辅助槽 → MASK=1(让 shader 走 #if MASK 分支采样
            // opacitymask 限定白区)。对没有 MASK combo 的 effect(如 waterflow,其 g_Texture1 是 flowmask)
            // 此 combo 无对应变体,selectVariant 自动回退 base,无害;真正的 localization 由 weAux 字面绑定提供。
            // 缺陷 5:仅在 pkg **未显式**给 MASK combo 时才置位(对齐 lwe ShaderUnit.cpp:597 / 合并顺序:
            //   m_combos 先于 m_discoveredCombos)。pkg 显式 MASK:0(作者关闭遮罩)必须保留,不能被无条件 1 覆盖。
            //   WP_NO_MASK_EXPLICIT_RESPECT=1 退回旧无条件置 1(A/B)。
            let respectExplicit = env["WP_NO_MASK_EXPLICIT_RESPECT"] == nil
            if maskPath != nil, !respectExplicit || weCombos["MASK"] == nil { weCombos["MASK"] = "1" }
            // 诊断(WP_MASK_DIAG=1):逐项报告每个缺陷的修复是否实际改变了本 effect 的结果。
            if env["WP_MASK_DIAG"] != nil {
                let directMask = weMaskSlots[weName] != nil
                let viaBasename = !directMask && !weMaskSlotsFor(weName).isEmpty
                if !occupancyCombos.isEmpty || maskPath != nil || viaBasename || (pkgMaskExplicit == "0") {
                    Log.write("MASKDIAG fx=\(weName) maskPath=\(maskPath ?? "nil") occCombos=\(occupancyCombos.sorted()) "
                        + "viaBasename=\(viaBasename) pkgMASK=\(pkgMaskExplicit ?? "nil") finalMASK=\(weCombos["MASK"] ?? "nil")")
                }
            }
            var le = LayerEffect(kind: kind, p: p, maskPath: maskPath,
                                 weName: weName, weParams: weParams,
                                 weParamsPerPass: weParamsPerPass, weCombos: weCombos,
                                 weAux: weAux)
            le.weAnim = weAnim
            out.append(le)
        }
        return out
    }

    /// 把 mask 基名解析为 pkg 内 .tex 路径。
    /// 审计修复(#6):补上与 resolveTexture 相同的多级回退(materials/<base>.tex、<base>.tex、
    /// .tex 后缀、allPaths 末段文件名匹配)。source 提供时按文件存在性逐级命中;为 nil 时退回
    /// 旧的单级 "materials/<base>.tex"(保持无 source 调用点的现有行为)。
    private static func resolveMask(_ base: String, source: SceneSource? = nil) -> String {
        if base.hasSuffix(".tex") { return base }
        guard let source = source else {
            return "materials/\(base).tex"   // 无 source:遮罩通常在 materials/masks/ 下
        }
        let candidates = [
            "materials/\(base).tex",
            "\(base).tex"
        ]
        for c in candidates where source.data(for: c) != nil { return c }
        // 兜底:在所有路径里找文件名匹配的 .tex
        let target = (base as NSString).lastPathComponent + ".tex"
        if let m = source.allPaths.first(where: { ($0 as NSString).lastPathComponent == target }) { return m }
        return "materials/\(base).tex"   // 全部未命中:退回默认猜测(与旧行为一致)
    }

    /// 该层是否只挂了未实现的交互效果(cursorripple 等鼠标交互)。
    /// 这类层(常是 projectlayer 组合层)没美术内容,直接画会出杂物,应跳过。
    private static func onlyHasInteractiveEffects(_ obj: [String: Any]) -> Bool {
        guard let effects = obj["effects"] as? [[String: Any]], !effects.isEmpty else { return false }
        let interactive = ["cursorripple", "cursor", "click", "mouse"]
        for e in effects {
            let f = ((e["file"] as? String) ?? "").lowercased()
            // 有任何一个不是交互类的效果 → 不跳过(可能有真内容)。
            if !interactive.contains(where: { f.contains($0) }) { return false }
        }
        return true
    }

    /// 检测某 solidlayer 是否挂了音频条 effect。是 → 返回标记 desc(条数/颜色/间距仅作记录;
    /// 真实绘制参数 + perspective 透视由 makeAudioBarsLayer 经 parseEffects 从 effects 链取真值喂
    /// WEEffectChain)。非音频条返回 nil。
    private static func parseAudioBars(_ obj: [String: Any]) -> AudioBarsDesc? {
        guard let effects = obj["effects"] as? [[String: Any]] else { return nil }
        for e in effects {
            let file = ((e["file"] as? String) ?? "").lowercased()
            // 仅按文件名匹配(原始英文名)。⚠️ 本会话曾试过「按常量内容(栏的条数等)识别汉化/改名音频条」
            // 让 3233141951 id=228「音条-身体」渲染,但它是 composelayer(_rt_FullFrameBuffer)+ opacity/影子,
            // 走 makeAudioBarsLayer 后底图渲成**暗矩形框**(回归)。content 识别本身对,但 composelayer 基底未处理 →
            // 暂回退文件名匹配(id=228 仍跳过),待 makeAudioBarsLayer 支持「composelayer 基底用透明底」后再启用 content 识别。
            guard file.contains("audio") && (file.contains("bar") || file.contains("spectrum")) else { continue }
            var desc = AudioBarsDesc()
            // 从 pass 的 constantshadervalues 读条数/颜色/间距(记录用;实绘走 parseEffects 的 weParams)。
            if let passes = e["passes"] as? [[String: Any]], let p0 = passes.first,
               let csv = p0["constantshadervalues"] as? [String: Any] {
                if let bc = VecParse.unwrap(csv["Bar Count"] ?? csv["栏的条数"]) as? NSNumber { desc.barCount = max(4, min(64, bc.intValue)) }
                if let s = VecParse.unwrap(csv["Bar Spacing"] ?? csv["栏的间距"]) as? NSNumber { desc.spacing = s.floatValue }
                if let cs = VecParse.unwrap(csv["Bar Color"]) as? String {
                    let a = VecParse.floats(cs); if a.count >= 3 { desc.color = SIMD3(a[0], a[1], a[2]) }
                }
            }
            return desc
        }
        return nil
    }

    /// 构建音频条图层(用 solidlayer 的位置/尺寸 + 解析出的 bars 参数)。
    /// #4:absoluteOrigin/absoluteScale(含父链层级变换)由主图像路径同名闭包传入;音频条层 origin 不再裸取。
    /// 可见性走 effectiveVisible(self AND 父链):音频条常挂在被开关/容器控制的父组下(如 3233141951 的
    /// 下音条01 parent=下音条02,父被 newproperty12 关时子也应隐),只看自身 visible 会漏掉父开关 → 误显。
    private static func makeAudioBarsLayer(_ obj: [String: Any], bars: AudioBarsDesc, id objId: Int,
                                           effectiveVisible: (Int) -> Bool,
                                           absoluteOrigin: (Int) -> SIMD3<Float>,
                                           absoluteScale: (Int) -> SIMD3<Float>,
                                           source: SceneSource? = nil) -> LayerDesc? {
        let visible = objId >= 0 ? effectiveVisible(objId) : Self.parseVisible(obj["visible"])
        guard visible else { return nil }
        let size = VecParse.floats(obj["size"])
        // 含父链的绝对 origin / scale;无 id 时退裸值(与主图像路径一致)。
        let absOrigin = objId >= 0 ? absoluteOrigin(objId) : VecParse.f3(obj["origin"])
        let scale = objId >= 0 ? absoluteScale(objId) : VecParse.f3(obj["scale"], default: SIMD3(1, 1, 1))
        // WE 频谱条层挂了真实的 effects 链 [Simple_Audio_Bars, perspective]:Simple_Audio_Bars
        // (真 WE 着色器)据系统音频频谱 + pkg 参数(Bar Count/Color/Spacing/Bounds/opacity/AA + combos
        // ANTIALIAS/CLIP_*)把条画到透明底图上;perspective(单应变换)用 4 角 point0-3 把条贴到场景梯形
        // (地板/水面)。两者均已转译进 manifest。keepWENamed=true 保留这些 kind==.none 的真 WE 特效
        // (否则被 `kind != .none` 门滤掉),且**保序**(Simple_Audio_Bars 先画、perspective 后扭)。
        let fx = SceneDocument.parseEffects(obj["effects"], keepWENamed: true, source: source)
        return LayerDesc(
            id: objId,
            name: obj["name"] as? String ?? "AudioBars",
            originPx: absOrigin,   // #4:含父链绝对 origin(原裸 VecParse.f3 → 父相对错位 ~1450px)
            sizePx: size.count >= 2 ? SIMD2(size[0], size[1]) : SIMD2(256, 256),
            scale: scale,
            anglesDeg: VecParse.f3(obj["angles"]),
            parallax: .zero,
            visible: true,
            texturePath: nil,
            // 条色已由 Simple_Audio_Bars 的 u_BarColor 烘进 effectedTexture,主 pass 顶点色取白(1,1,1,1)
            // 避免二次着色(否则非白条色会被平方,过饱和)。
            color: SIMD4(1, 1, 1, 1),
            blend: .translucent,
            isSolid: false,
            effects: fx,
            text: nil,
            audioBars: bars
        )
    }

    /// 已转译进 manifest 的 effect 名集合(WEEffects.json 顶层 key,读一次)。供 dependsOnUnsupportedEffect
    /// 判断某音频可视化 effect 是否**已转译**——已转译的能真渲染(走 useWE 真 shader),不再当未实现跳过。
    static let transpiledEffectNames: Set<String> = {
        let paths = [
            ProcessInfo.processInfo.environment["WP_MANIFEST_DIR"].map { URL(fileURLWithPath: $0).appendingPathComponent("WEEffects.json") },
            Bundle.main.resourceURL?.appendingPathComponent("WEEffects.json"),
            URL(fileURLWithPath: NSString(string: "~/Developer/LiveWallpaper/Tools/generated/WEEffects.json").expandingTildeInPath)
        ].compactMap { $0 }
        for p in paths {
            if let d = try? Data(contentsOf: p),
               let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { return Set(j.keys) }
        }
        return []
    }()

    /// transpiledEffectNames 的 basename(最后一段)集合,排除 material/。供 isEffectTranspiled 做 workshop
    /// 副本回退:同名特效是同副本(shader 相同),basename 命中即视为已转译。与 WEEffectChain.resolvedKey 一致。
    static let transpiledBasenames: Set<String> = {
        Set(transpiledEffectNames.compactMap { k in
            k.hasPrefix("material/") ? nil : k.components(separatedBy: "/").last
        })
    }()

    /// effect 名(weEffectName 产出的去前后缀路径,如 workshop/<id>/…/Simple_Audio_Bars)是否已转译。
    /// 精确路径命中 → 是;否则按 basename 兜底(workshop 副本/双层嵌套路径同名 → 同副本)。这是
    /// composelayer 音频条「上下两条只渲一条」的修复:Bar2/Bar3 的 Simple_Audio_Bars 副本路径精确不命中,
    /// 之前被判 composeEffectRenderable=false → 整层跳过;basename 兜底后正确识别为可渲。
    static func isEffectTranspiled(_ wn: String) -> Bool {
        if wn.isEmpty { return false }
        if transpiledEffectNames.contains(wn) { return true }
        guard wn.contains("/") else { return false }
        let base = wn.components(separatedBy: "/").last ?? wn
        return transpiledBasenames.contains(base)
    }

    /// 每个 effect 的「opacitymask 槽」索引集合(manifest 里 g_Texture<N> 的 combo=="MASK" → 槽 N)。
    /// **正解:opacitymask 由 shader 槽的 mode/combo 判定(转译已捕获),不是靠贴图名含 "mask"**。
    /// 旧逻辑靠名字 → 遮罩贴图叫「影子」(opacity 效果)等不含 "mask" 的会漏判 → 没设 MASK combo → 选无遮罩
    /// base 变体 → 效果填满整个矩形(如 3233141951 id=228 身体音频条没被身体剪影遮罩=大方框)。
    static let weMaskSlots: [String: Set<Int>] = {
        let paths = [
            ProcessInfo.processInfo.environment["WP_MANIFEST_DIR"].map { URL(fileURLWithPath: $0).appendingPathComponent("WEEffects.json") },
            Bundle.main.resourceURL?.appendingPathComponent("WEEffects.json"),
            URL(fileURLWithPath: NSString(string: "~/Developer/LiveWallpaper/Tools/generated/WEEffects.json").expandingTildeInPath)
        ].compactMap { $0 }
        for p in paths {
            guard let d = try? Data(contentsOf: p),
                  let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            var out: [String: Set<Int>] = [:]
            for (name, val) in j {
                guard let e = val as? [String: Any], let variants = e["variants"] as? [[String: Any]] else { continue }
                var slots = Set<Int>()
                for v in variants {
                    for pass in (v["passes"] as? [[String: Any]] ?? []) {
                        guard let um = pass["uniformMeta"] as? [String: Any] else { continue }
                        for (un, meta) in um {
                            guard un.hasPrefix("g_Texture"), let md = meta as? [String: Any],
                                  (md["combo"] as? String) == "MASK",
                                  let n = Int(un.dropFirst("g_Texture".count)) else { continue }
                            slots.insert(n)
                        }
                    }
                }
                if !slots.isEmpty { out[name] = slots }
            }
            return out
        }
        return [:]
    }()

    /// **缺陷 1(slot-occupancy combo)** & **缺陷 2(basename fallback)** 数据源:
    /// 每个 effect 的「g_Texture<N> sampler 声明的 combo 名」映射(manifest uniformMeta 里 g_Texture<N>.combo,
    /// 不限 MASK——含 OPACITYMASK/NORMALMAP/PBRMASKS/… 全部)。镜像 lwe ShaderUnit.cpp:531-619:某 scene pass
    /// 给某 slot 绑了**非空贴图** → 该 sampler 声明的 combo 自动启用(textureSlotUsed → comboValue=1)。
    /// 旧引擎只对「贴图名含 mask」或「manifest 已声明该 slot 的 MASK combo」启用 → 遮罩贴图叫 shadow/影子/fade
    /// 且变体 manifest 没显式声明该 slot MASK combo 时漏判 → MASK-1 变体没选 → shader 硬编码 mask=1 → 整矩形。
    static let weSlotCombos: [String: [Int: String]] = {
        let paths = [
            Bundle.main.resourceURL?.appendingPathComponent("WEEffects.json"),
            URL(fileURLWithPath: NSString(string: "~/Developer/LiveWallpaper/Tools/generated/WEEffects.json").expandingTildeInPath)
        ].compactMap { $0 }
        for p in paths {
            guard let d = try? Data(contentsOf: p),
                  let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            var out: [String: [Int: String]] = [:]
            for (name, val) in j {
                guard let e = val as? [String: Any], let variants = e["variants"] as? [[String: Any]] else { continue }
                var slots: [Int: String] = [:]
                for v in variants {
                    for pass in (v["passes"] as? [[String: Any]] ?? []) {
                        guard let um = pass["uniformMeta"] as? [String: Any] else { continue }
                        for (un, meta) in um {
                            guard un.hasPrefix("g_Texture"), let md = meta as? [String: Any],
                                  let combo = md["combo"] as? String,
                                  let n = Int(un.dropFirst("g_Texture".count)) else { continue }
                            // 同 slot 在不同变体里 combo 名一致(同 sampler 声明);首次记下即可。
                            if slots[n] == nil { slots[n] = combo }
                        }
                    }
                }
                if !slots.isEmpty { out[name] = slots }
            }
            return out
        }
        return [:]
    }()

    /// **缺陷 2(basename fallback)**:weMaskSlots / weSlotCombos 的 key 是完整 manifest 路径
    /// (workshop 副本带前缀,甚至双层嵌套);壁纸 effect 的 weName(去前后缀的相对路径)往往不等于该完整 key
    /// → 直查 weMaskSlots[weName]=nil → 漏掉遮罩。镜像 WEEffectChain.resolvedKey 的 basenameIndex
    /// (SceneModel.swift basenameIndex 同口径):basename(最后一段)→ 任意已转译同名 key(同名=同副本 shader 同
    /// → mask slot 声明相同)。供 weMaskSlotsFor / weSlotCombosFor 在 weName 直查失败时回退。
    static let weSlotComboBasenameIndex: [String: String] = {
        var idx: [String: String] = [:]
        for k in weSlotCombos.keys where !k.hasPrefix("material/") {
            let base = k.components(separatedBy: "/").last ?? k
            // 平局取最短路径 key(最接近「通用」),与 WEEffectChain.basenameIndex 取向一致。
            if let cur = idx[base], cur.count <= k.count { continue }
            idx[base] = k
        }
        return idx
    }()

    /// weName → mask slot 集合(缺陷 2:原 key 优先,失败按 basename 回退到同名副本)。
    static func weMaskSlotsFor(_ weName: String) -> Set<Int> {
        if let s = weMaskSlots[weName] { return s }
        if ProcessInfo.processInfo.environment["WP_NO_MASK_BASENAME"] != nil { return [] }
        guard weName.contains("/") else { return [] }
        let base = weName.components(separatedBy: "/").last ?? weName
        if let k = weSlotComboBasenameIndex[base], let s = weMaskSlots[k] { return s }
        return []
    }

    /// weName → {slot: comboName}(缺陷 1/2:slot-occupancy combo 派生;原 key 优先,失败按 basename 回退)。
    static func weSlotCombosFor(_ weName: String) -> [Int: String] {
        if let s = weSlotCombos[weName] { return s }
        if ProcessInfo.processInfo.environment["WP_NO_MASK_BASENAME"] != nil { return [:] }
        guard weName.contains("/") else { return [:] }
        let base = weName.components(separatedBy: "/").last ?? weName
        if let k = weSlotComboBasenameIndex[base], let s = weSlotCombos[k] { return s }
        return [:]
    }

    /// manifest 里声明了 g_AudioSpectrum* 的 effect 名集合(= 需系统音频频谱的音频可视化 effect)。
    /// 按 manifest **真值**识别音频层,覆盖汉化/全下划线路径(英文文件名匹配会漏,如本库 2846660316 的
    /// effect file 是全下划线)。g_AudioSpectrum 声明在 frag/vert 的 uniforms(不在 uniformMeta),三处都扫。
    /// 与 WEEffectChain.usesAudioSpectrum 同口径,只是在 SceneDocument 解析期从 JSON 直接读(读一次)。
    static let weAudioEffectNames: Set<String> = {
        let paths = [
            ProcessInfo.processInfo.environment["WP_MANIFEST_DIR"].map { URL(fileURLWithPath: $0).appendingPathComponent("WEEffects.json") },
            Bundle.main.resourceURL?.appendingPathComponent("WEEffects.json"),
            URL(fileURLWithPath: NSString(string: "~/Developer/LiveWallpaper/Tools/generated/WEEffects.json").expandingTildeInPath)
        ].compactMap { $0 }
        func stageHasAudio(_ stage: Any?) -> Bool {
            guard let s = stage as? [String: Any], let us = s["uniforms"] as? [[String: Any]] else { return false }
            return us.contains { ($0["name"] as? String)?.hasPrefix("g_AudioSpectrum") ?? false }
        }
        for p in paths {
            guard let d = try? Data(contentsOf: p),
                  let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            var out = Set<String>()
            for (name, val) in j {
                guard let e = val as? [String: Any], let variants = e["variants"] as? [[String: Any]] else { continue }
                outer: for v in variants {
                    for pass in (v["passes"] as? [[String: Any]] ?? []) {
                        if let um = pass["uniformMeta"] as? [String: Any],
                           um.keys.contains(where: { $0.hasPrefix("g_AudioSpectrum") }) { out.insert(name); break outer }
                        if stageHasAudio(pass["frag"]) || stageHasAudio(pass["vert"]) { out.insert(name); break outer }
                    }
                }
            }
            return out
        }
        return []
    }()

    /// solidlayer 是否依赖**未实现**的 effect(音频条/频谱可视化等)才有形状 → 跳过避免裸白块。
    /// ⚠ 已转译的音频可视化**放行**(走 useWE 真 shader)。识别按 manifest 真值(weAudioEffectNames),
    /// 覆盖汉化/全下划线路径;不再按对象名黑名单丢层(lwe 的 CImage 只看 visible,从不按名丢层——
    /// 旧的 :按对象名含 audio/频谱 兜底丢整层 会把汉化命名、effect 已转译的音频 solidlayer 整层误丢)。
    private static func dependsOnUnsupportedEffect(_ obj: [String: Any]) -> Bool {
        let effects = obj["effects"] as? [[String: Any]] ?? []
        var hasAudioViz = false, hasUnsupported = false
        for e in effects {
            let rawFile = (e["file"] as? String) ?? ""
            let file = rawFile.lowercased()
            let wn = Self.weEffectName(rawFile)
            // manifest 真值(声明 g_AudioSpectrum)优先,辅以英文文件名兜底(未进 manifest 的音频特效)。
            let isAudio = (!wn.isEmpty && Self.weAudioEffectNames.contains(wn))
                || file.contains("audio") || file.contains("bars") || file.contains("spectrum") || file.contains("visualiz")
            guard isAudio else { continue }
            hasAudioViz = true
            if !Self.isEffectTranspiled(wn) { hasUnsupported = true }
        }
        if hasAudioViz { return hasUnsupported }   // 有音频可视化:全已转译→放行(条能渲);有未转译→跳(避免裸白块)
        return false   // 删除按对象名兜底丢层(对齐 lwe「不按名丢层」)
    }

    /// 解析文本图层(时钟/日期)。返回 nil = 不渲染(如可见性关闭)。
    /// canvas:场景画布尺寸,注入文本脚本的 engine.canvasSize(部分脚本会读)。
    private static func parseTextLayer(_ obj: [String: Any], canvas: SIMD2<Float>) -> LayerDesc? {
        guard Self.parseVisible(obj["visible"]) else { return nil }
        let name = (obj["name"] as? String ?? "").lowercased()
        let layerName = obj["name"] as? String ?? ""

        // 严格按 pkg:文字层用**自身** color,缺省 = WE 默认白(1,1,1)。**不继承父层颜色** ——
        //   WE 的父子层级只传递变换(origin/scale/angle/alpha),颜色各对象独立(实测玛奇玛 3725148661:
        //   父 "DAY DATE TIME" 静态深红渲 MONDAY,子 Date/Clock 无色 → 应为白;此前误乘父色把日期/时间染红)。
        let color = VecParse.f3(obj["color"], default: SIMD3(1, 1, 1))
        // pointsize 可能带 user 覆盖。
        var pt: CGFloat = 32
        if let n = VecParse.unwrap(obj["pointsize"]) as? NSNumber { pt = CGFloat(n.floatValue) }
        let scale = VecParse.f3(obj["scale"], default: SIMD3(1, 1, 1))
        let align = (obj["horizontalalign"] as? String) ?? "center"
        let vAlign = (obj["verticalalign"] as? String) ?? "center"
        let fontName = (obj["font"] as? String) ?? "systemfont_consolas"
        // WE 文本图层的显式 size(画布单位):时钟 584×156、日期 1679×162 等。它定义文本在屏上的盒子,
        // 屏上大小 = size×scale(不是 pointsize 的自然像素)。无 size 的(部分静态文本/问候)→ 退 autosize。
        let sizeArr = VecParse.floats(obj["size"])
        let boxSize: SIMD2<Float>? = sizeArr.count >= 2 ? SIMD2(sizeArr[0], sizeArr[1]) : nil

        // WE 的 text 图层文本由 JS 脚本逐帧生成。优先跑真脚本(WEScript):
        //   text = {"script": "...update()...", "value": "...", "scriptproperties": {...}}
        let textField = obj["text"] as? [String: Any]
        let scriptSrc = textField?["script"] as? String
        let rawText = (VecParse.unwrap(obj["text"]) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let kind: TextLayerKind
        if let src = scriptSrc {
            // scriptproperties:图层级覆盖(每项可能是裸值或 {user,value} → 经 unwrap 解出最终值)。
            let overrides = Self.resolveScriptProperties(textField?["scriptproperties"])
            if let js = WEScript(script: src, propertyOverrides: overrides, tag: layerName, canvas: canvas) {
                kind = .script(js)
            } else {
                // 脚本无法运行:退化到名字推断的近似类型(时钟/日期/星期/问候)。
                Log.write("scene: text script unavailable, fallback approx for \(layerName)")
                kind = Self.approxKind(name: name, rawText: rawText) ?? .staticText("")
                if case .staticText("") = kind { return nil }
            }
        } else if let k = Self.approxKind(name: name, rawText: rawText) {
            kind = k
        } else {
            // 静态文字:渲染真实内容(如 ☾ 月相符号、固定标签)。
            // 跳过:空、脚本源码、以及算不出的脚本占位(歌名/艺术家的 "Text Layer"、"<Date>" 等)。
            let lower = rawText.lowercased()
            let isPlaceholder = lower == "text layer" || lower == "day"
                || (lower.hasPrefix("<") && lower.hasSuffix(">")) || lower.contains("12:34:56")
                || lower == "undefined" || lower == "null"
            // 合法长字幕(如土星 707/720「November 1980 / Humanity's first visitor to saturn」99/147 字符)曾被
            //   `count <= 40` 误丢。改**按内容判**占位/脚本垃圾(含 `{`/`undefined`/脚本源码/已知占位串)而非纯长度——
            //   长度只是脚本占位的弱信号,真长文本(姊妹短字幕 VOYAGER 1/CASSINI 正常渲)同样合法。WP_NO_LONGTEXT 退回旧 <=40 守卫。
            let lengthOK = ProcessInfo.processInfo.environment["WP_NO_LONGTEXT"] != nil ? (rawText.count <= 40) : true
            guard !rawText.isEmpty, lengthOK,
                  !rawText.contains("export"), !rawText.contains("function"),
                  !rawText.contains("{"), !rawText.contains("undefined"),
                  !isPlaceholder else { return nil }
            kind = .staticText(rawText)
        }

        // 锚点 size 文本(歌名 size="2 2" + 大 scale)与 media 文本(歌名/艺术家):WE 忽略 size 框,按
        // pointsize×scale 渲染。把 boxSizePx 设 nil → 不当尺寸盒子、不按 size.x 折行(否则 2px 折行宽度
        // 把"NIGHT DANCER"挤成竖排碎块);useScreenPointSize 让渲染端用 pt×scale 定屏上字高。
        // (先算 isAnchor,renderPt 才能按各路径的「屏上字高」定纹理分辨率。)
        let isMediaText: Bool = { if case .script(let s) = kind { return s.isMediaDriven }; return false }()
        let isAnchor = isMediaText || (boxSize.map { $0.y < Float(pt) } ?? false)

        // ── 文字纹理分辨率(清晰度修复)────────────────────────────────────────────────
        // 真因:旧码把 renderPt 钉死在 128/64,与文字**屏上像素高**脱钩。时钟盒子(如黑猫 Clock 12:
        //   size.y=161×scale.y≈1.05 ≈ 169 画布 px;Retina backing 2× → 屏上 ~340 物理 px)被渲成 128px
        //   纹理再双线性**放大**贴上去 → 发虚/模糊(用户报「字体异常模糊」)。
        // 正解:按文字的**屏上画布字高**定 renderPt,再乘 supersample(覆盖 Retina 2×+留余量),纹理 1:1
        //   或超采样贴屏 → 锐利。各路径的屏上画布字高:
        //     · 锚点/media:srcPointSize × |scale.y|(WE 真义=pointsize×scale)
        //     · 盒子文本:box.y × |scale.y|(盒子定屏上高,见 textQuad)
        //     · autosize:无盒子,屏上高 = 纹理像素×scale(纹理像素由 renderPt 决定)→ 保留 pt×2 旧义,
        //       但乘进 |scale.y| 余量,scale>1 时也不被放糊。
        // renderPt 改变**不影响屏上尺寸**(仅盒子/锚点路径):
        //   · 盒子文本屏上高由 box×scale 决定(SceneRenderEngine.textQuad/L987),纹理只定字形纵横比+AA。
        //   · 锚点/media 屏上比例 = srcPt/renderPt(L981),renderPt 与 texHeight 同比 → 比例抵消、屏上字号不变。
        //   · autosize 路径屏上高 = 纹理像素×scale,纹理像素∝renderPt → 改 renderPt 会**放大**字。故 autosize
        //     **保持旧公式不动**(纯静态标签/问候,无盒子无锚点;改了会动到表观字号 = 回归风险),只提盒子/锚点。
        // WP_NO_TEXT_HIDPI=1 退回旧的固定 128/64(A/B 诊断本修复)。
        let scaleY = max(0.0001, CGFloat(abs(scale.y)))
        let renderPt: CGFloat
        if ProcessInfo.processInfo.environment["WP_NO_TEXT_HIDPI"] != nil {
            renderPt = boxSize != nil ? max(128, pt * 2) : max(64, pt * 2)   // 旧行为(退路)
        } else if isAnchor {
            // 锚点/media:屏上字高 = srcPt×scale.y。supersample 2.5× 覆盖 Retina 2×+余量。
            renderPt = min(512, max(64, pt * scaleY * 2.5))
        } else if let bs = boxSize {
            // 盒子文本(时钟/日期):屏上字高 = box.y×scale.y。supersample 2.5×。floor 128 保底。
            // 上限 512pt(=旧 128 的 4×,任意现实显示都锐利)防极大盒子(整屏标题)的纹理爆显存/超 8192 宽限。
            renderPt = min(512, max(128, CGFloat(bs.y) * scaleY * 2.5))
        } else {
            renderPt = max(64, pt * 2)        // autosize:屏上字号 ∝ renderPt,保持旧义不动(零回归)
        }
        var text = TextLayerDesc(kind: kind, color: color, pointSize: renderPt)
        text.srcPointSize = pt        // pkg 原始 pointsize:屏上字高 = pt×scale(WE 真义,size 盒子太小=锚点时用)
        text.align = align
        text.verticalAlign = vAlign
        text.fontName = fontName
        text.boxSizePx = isAnchor ? nil : boxSize
        text.useScreenPointSize = isAnchor

        // ── 描边/阴影/字重(R15)── 严格按 pkg(实据见 TextLayerDesc 注释)──────────────
        // 描边走特效链(textoutline7x7,下方 tl.effects 解析,已支持);粗斜体由字体文件承载(FontRegistry)。
        // 这里只补两件「数据真存在却此前没渲」的事:
        //   ① castshadow(WE 真实对象字段,bool):true → 文本投影。pkg 无投影色/偏移/模糊字段 → 用 WE 默认软黑投影
        //      (色黑、偏移与模糊按渲染字号比例,缩到盒子后比例稳定)。全库恒 false,故零回归;仅未来开了的壁纸生效。
        //   ② 字体名暗示粗/斜但系统体不粗/不斜时,用 CoreText trait 合成兜底(resolveFont 内施加)——
        //      不改变已正确加载的粗体字(那些字体本身就粗),只补「取不到带 weight 变体、落了 regular」的退化情形。
        if VecParse.unwrap(obj["castshadow"]) as? Bool == true {
            text.castShadow = true
            text.shadowColor = SIMD3(0, 0, 0)
            // WE 编辑器文本投影默认是细软黑投影;pkg 不带参数 → 取与渲染字号成比例的小偏移/模糊近似。
            let rp = Float(renderPt)
            text.shadowOffsetPx = SIMD2(rp * 0.04, rp * 0.04)
            text.shadowBlurPx = CGFloat(rp * 0.03)
        }
        let fnLower = fontName.lowercased()
        text.wantsBold = ["-bold", " bold", "_bold", "black", "heavy", "-semibold"].contains { fnLower.contains($0) }
        text.wantsItalic = ["italic", "oblique"].contains { fnLower.contains($0) }

        // 有显式 size:屏上尺寸 = size×scale 盒子(WE 行为),引擎按字形纵横比适配进盒子并按 align 放置
        //   → 这里 sizePx=nil(引擎对 text 层走 boxSizePx 专路,不用 LayerDesc.sizePx 的拉伸贴满)。
        // 无显式 size:autosize(取文本纹理像素)× scale,保持旧行为(静态文本/问候)。
        // 文字颜色已烤进纹理,白色不二次染;但**透明度 alpha 要读**(WE 时钟/日期常 alpha:0.5):
        // 照图像层做法(SceneModel:758)取 obj["alpha"] 写进 color.w,否则文字按 100% 不透明渲染、比原版偏实。
        var textAlpha: Float = 1
        if let a = VecParse.unwrap(obj["alpha"]) as? NSNumber { textAlpha = a.floatValue }
        // 对象级 brightness(WE g_Brightness,ObjectParser.cpp:293,默认 1)。WE 在材质 pass 用
        // g_Brightness 乘 albedo.rgb;时钟/日期文本常带 brightness>1(如 3732211725「Misty Valley」
        // Date=1.98、DAY DATE TIME=1.4)让白字更亮。文本走 parseTextLayer + 上层 `continue`,从不经过
        // 图像层那条 brightness 解析(L1097),故旧代码丢掉了 brightness → 文字比 WE 偏暗。这里读出并交给
        // SceneRenderEngine(litColor = color.rgb × brightness,L760)施加一次,与图像层口径一致。
        var textBrightness: Float = 1
        if let br = VecParse.unwrap(obj["brightness"]) as? NSNumber { textBrightness = br.floatValue }
        var desc = LayerDesc(
            id: (obj["id"] as? NSNumber)?.intValue ?? -1,
            name: layerName,
            originPx: VecParse.f3(obj["origin"]),
            sizePx: nil,                      // text 层尺寸由 boxSizePx(有则盒子)或 autosize 决定
            scale: scale,
            anglesDeg: VecParse.f3(obj["angles"]),
            parallax: VecParse.f2(obj["parallaxDepth"]),
            visible: true,
            texturePath: nil,
            color: SIMD4(1, 1, 1, textAlpha), // 颜色烤进纹理(白不二次染),仅 alpha 透明度生效
            blend: .translucent,
            isSolid: false,
            effects: [],
            text: text
        )
        desc.brightness = textBrightness
        return desc
    }

    /// 按图层名 / value 文本推断近似类型(脚本不可用或无脚本时的回退)。返回 nil = 无法识别。
    private static func approxKind(name: String, rawText: String) -> TextLayerKind? {
        let upper = rawText.uppercased()
        if upper.contains("GOOD") && (upper.contains("MORNING") || upper.contains("AFTERNOON")
            || upper.contains("EVENING") || upper.contains("NIGHT")) {
            return .greeting
        } else if upper == "DAY" || (name.hasPrefix("day") && !name.hasPrefix("date"))
                    || name.contains("星期") || name == "week" {
            return .dayOfWeek
        } else if name.contains("秒") || name.contains("seconds") {   // 秒(SS)独立文本层(名常带后缀如「秒(正片叠底)」→ 用 contains)
            return .seconds
        } else if name.contains("clock") || name.contains("时钟") || name.contains("time") || name.contains("时分") {
            return .clock          // 时分 = HH:mm(某些壁纸时/分独立于秒)
        } else if name.contains("date") || name.contains("日期") || name == "dy" {
            return .date
        }
        return nil
    }

    /// 把 text.scriptproperties / 字段.scriptproperties 拍平成「脚本属性 name → 最终值」。
    /// 每项可能是裸值,或 {user,value}(用户/项目覆盖)→ 经 VecParse.unwrap 解出。
    /// NSNumber 进一步归一:整数值的 number 当 Bool 时由 JS shim 判定,这里只负责传 Bool/Double/String。
    static func resolveScriptProperties(_ raw: Any?) -> [String: Any] {
        guard let dict = raw as? [String: Any] else { return [:] }
        var out: [String: Any] = [:]
        for (k, v) in dict {
            let resolved = VecParse.unwrap(v)
            // ⚠ NSNumber 必须**先**判 CFBoolean 类型(再决定 Bool/Double),不能用 `case let b as Bool` 兜头:
            //   JSONSerialization 把 `1`/`0` 解成普通 __NSCFNumber,而 Swift 的 `NSNumber as? Bool` 对 0/1 **会成功**
            //   (返回 true/false)→ 整数标量 scriptproperty(如 Dock 的 `layoutMode: 1`)会被错当 Bool=true,
            //   导致脚本里 `config.layoutMode === 1` 恒 false → 布局分支全不跑 → idealTargetalpha 留 undefined →
            //   target_opa=NaN → 图标 alpha 恒 NaN → Dock 启用时图标也不显示。先按 CFBoolean 判型即可正确区分:
            //   真布尔(true/false)→ CFBoolean → boolValue;数字(1/0/0.3)→ 普通 NSNumber → doubleValue。
            switch resolved {
            case let n as NSNumber:
                if CFGetTypeID(n) == CFBooleanGetTypeID() { out[k] = n.boolValue }   // 真 Bool(CFBoolean)
                else { out[k] = n.doubleValue }                                       // 数字标量(含整数 1/0)
            case let b as Bool: out[k] = b                                            // 兜底(理论上 NSNumber 已覆盖)
            case let s as String: out[k] = s
            default: break
            }
        }
        return out
    }

    /// 解析挂在矢量字段(scale/origin/…)上的 WE JS 脚本。返回可运行的 WEScript,否则 nil。
    /// canvas:场景画布尺寸(orthogonalprojection w/h),注入 engine.canvasSize 供 origin 脚本读。
    static func parseVectorScript(_ field: Any?, tag: String, canvas: SIMD2<Float>) -> WEScript? {
        guard let dict = field as? [String: Any], let src = dict["script"] as? String else { return nil }
        let overrides = resolveScriptProperties(dict["scriptproperties"])
        return WEScript(script: src, propertyOverrides: overrides, tag: tag, canvas: canvas)
    }

    /// #3:angles **脚本**产出的 z 角是度数(zRotation 滑块单位),转弧度供 matModel/rotateVec2(均吃弧度)用。
    /// 注:scene.json 的**静态** angles 本就是弧度(SceneRenderEngine.matModel 注释),只有脚本路径走此换算。
    static func scriptAngleZToRadians(_ deg: Float) -> Float { deg * .pi / 180 }

    /// 载入某壁纸在「壁纸设置」里设的覆盖值(user-key → 值)。无 item 或无覆盖返回空。
    private static func loadOverrides(_ item: WallpaperItem?) -> [String: WallpaperProperty.Value] {
        guard let item else { return [:] }
        let store = WallpaperPropertyStore.shared
        let props = store.properties(forID: item.id, folderURL: item.folderURL)
        var out: [String: WallpaperProperty.Value] = [:]
        for p in props {
            // 每个属性都放它的「有效值」(用户覆盖 or project.json 默认),不只放用户改过的。
            // 原因:visible:{user:{name:<prop>,condition:<串>}} 的条件层(天气/时段开关)求值时,
            // unwrap 要拿**该属性的当前值**和 condition 比。若 overrides 缺这个 prop,旧代码退回拿
            // 「图层自身的 value 字段」当属性值——而那是图层默认显隐(bool),不是属性值,导致条件全判错。
            // 实测 3302695207:天气 newproperty72 默认=3(雪),却因此退化判成「晴」。塞入 project.json
            // 默认后条件正确求值(雪层显、晴层隐)。store.value 无覆盖时本就回退 project.json 默认。
            out[p.id] = store.value(forID: item.id, property: p, folderURL: item.folderURL)
        }
        // 测试/诊断通道:WP_OVERRIDE="key=val;key2=val2" 直接注入覆盖值(headless --render 无 UI/UserDefaults 时
        // 验证滑块传播)。按对应属性类型解释:slider→number、bool→bool(true/1)、color→"r g b" 串、combo/text→串。
        // 仅诊断用,不影响真实 app(app 走 UserDefaults)。
        if let ov = ProcessInfo.processInfo.environment["WP_OVERRIDE"], !ov.isEmpty {
            let byKey = Dictionary(props.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for pair in ov.split(separator: ";") {
                let kv = pair.split(separator: "=", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
                guard kv.count == 2, let prop = byKey[kv[0]] else { continue }
                let raw = kv[1]
                switch prop.type {
                case .slider: if let n = Double(raw) { out[kv[0]] = .number(n) }
                case .bool: out[kv[0]] = .bool(raw == "true" || raw == "1")
                case .color: out[kv[0]] = .color(WallpaperPropertyStore.parseColor(raw))
                case .combo, .textinput, .label: out[kv[0]] = .string(raw)
                }
            }
        }
        return out
    }

    /// 用户在「壁纸设置」里**改过**(有效值 ≠ project.json 默认)的属性名(project.json key)。
    /// 跨层控制器脚本(土星 Dock)首帧据此派发 applyUserProperties(changed),触发其重置派生状态(隐藏图标)。
    /// WE 真义:applyUserProperties 在属性**变化**时被调用,changed 是变化的属性集;壁纸加载时已被用户改过的
    ///   属性(如关掉的 dock=0)也算「相对默认的变化」,故首帧派发它们让脚本立即生效。未改的属性不入集 →
    ///   脚本走 pkg 默认(零回归)。无 item / 无属性 → 空集。
    /// 与 loadOverrides 同源(WP_OVERRIDE 诊断通道注入的覆盖也计入「改过」,便于 headless 验证)。
    private static func changedUserProperties(_ item: WallpaperItem?) -> [String] {
        guard let item else { return [] }
        let store = WallpaperPropertyStore.shared
        let props = store.properties(forID: item.id, folderURL: item.folderURL)
        // WP_OVERRIDE 诊断键(headless 无 UserDefaults 时):这些显式视为「改过」。
        var forced = Set<String>()
        if let ov = ProcessInfo.processInfo.environment["WP_OVERRIDE"], !ov.isEmpty {
            for pair in ov.split(separator: ";") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                if let k = kv.first { forced.insert(String(k).trimmingCharacters(in: .whitespaces)) }
            }
        }
        var changed: [String] = []
        for p in props where p.type != .label {   // label 是说明文本,无值,跳过
            let eff = store.value(forID: item.id, property: p, folderURL: item.folderURL)
            let def = store.defaultValue(forID: item.id, property: p, folderURL: item.folderURL)
            if forced.contains(p.id) || !Self.valuesEqual(eff, def) { changed.append(p.id) }
        }
        return changed
    }

    /// 比较两个属性值是否相等(判定用户是否改过)。数值用小容差;颜色逐分量容差;布尔/串精确。
    private static func valuesEqual(_ a: WallpaperProperty.Value, _ b: WallpaperProperty.Value) -> Bool {
        switch (a, b) {
        case let (.bool(x), .bool(y)): return x == y
        case let (.number(x), .number(y)): return abs(x - y) < 1e-6
        case let (.string(x), .string(y)): return x == y
        case let (.color(x), .color(y)): return abs(x.x - y.x) < 1e-4 && abs(x.y - y.y) < 1e-4 && abs(x.z - y.z) < 1e-4
        default: return false
        }
    }

    /// visible 字段:可能是 Bool,或 {"value": Bool, "user": ...}(用户可控属性)。
    /// 经 unwrap 走覆盖逻辑(用户在设置里关了某图层 → 这里返回 false)。缺省 = true。
    private static func parseVisible(_ v: Any?) -> Bool {
        if let b = VecParse.unwrap(v) as? Bool { return b }
        return true
    }

    /// 特效级 visible:与 parseVisible 同(bool / {user,value} / {script}),但**额外**:若 visible 绑定的
    /// `user` 属性在 project.json 的 properties 里**根本没定义**(VecParse.overrides 无该 key——loadOverrides
    /// 已把所有已定义属性都填入,故 nil ⟺ 未定义),则该特效**隐藏**(不跑)。
    /// 真因:壁纸作者套模板时常引用一个自己没暴露的开关(如 3732211725「Misty Valley」blur 的 visible
    /// `{user:'blur', value:true}`,但 project.json 无 'blur' 属性)。旧的 unwrap 对"未定义属性"回退到 value=true
    /// → 特效照跑 → 整屏被 blur 糊;而真 WE(实测)是**不显示**引用未定义属性的特效 → 清晰。
    /// 注:属性**已定义**(即便用户没改、用 pkg 默认)时 overrides 有该 key → 走正常 parseVisible(零影响,
    /// 如 waterflow 的 cloudsmouvement、tint 的 darkambient 仍按开关/默认正常生效)。仅作用于特效级,不动对象级。
    private static func effectVisible(_ v: Any?) -> Bool {
        if let dict = v as? [String: Any] {
            var userKey: String? = nil
            if let s = dict["user"] as? String { userKey = s }
            else if let u = dict["user"] as? [String: Any], let n = u["name"] as? String { userKey = n }
            if let key = userKey, VecParse.overrides[key] == nil { return false }   // 引用未定义属性 → 隐藏(对齐真 WE)
        }
        return parseVisible(v)
    }

    /// 把 material textures[0] 的 base 名解析为 pkg 内实际 .tex 路径。
    /// texture_override 特效(workshop 3224559305)的覆盖贴图名:pass.textures 里第一个非空字符串
    /// (textures[0]=null 表示用层基底,textures[1]=真实美术贴图名,如 "身体"/"草地")。
    /// 特效隐藏(visible 关 / 引用未定义属性)则不覆盖。无 texture_override 返回 nil。
    private static func textureOverrideBase(_ obj: [String: Any]) -> String? {
        guard let effects = obj["effects"] as? [[String: Any]] else { return nil }
        for e in effects {
            guard let file = e["file"] as? String, file.contains("texture_override") else { continue }
            guard Self.effectVisible(e["visible"]) else { continue }
            guard let passes = e["passes"] as? [[String: Any]], let p0 = passes.first,
                  let texs = p0["textures"] as? [Any] else { continue }
            for t in texs {
                if let s = VecParse.unwrap(t) as? String, !s.isEmpty { return s }
            }
        }
        return nil
    }

    private static func resolveTexture(base: String, source: SceneSource) -> String? {
        let candidates = [
            "materials/\(base).tex",
            "\(base).tex",
            base.hasSuffix(".tex") ? base : "\(base).tex"
        ]
        for c in candidates where source.data(for: c) != nil { return c }
        // 兜底:在所有路径里找文件名匹配的 .tex
        let target = (base as NSString).lastPathComponent + ".tex"
        return source.allPaths.first { ($0 as NSString).lastPathComponent == target }
    }
}
