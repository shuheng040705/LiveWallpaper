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
        // WE 语义(UserSettingParser.cpp:31-44 解析 + DynamicValue.cpp:244-256/274-284 求值):
        //   condition 与 name 都是字符串;字段最终值 = (属性当前值的字符串 == condition 串) ? 1 : 0。
        //   注意:WE 只做**纯字符串相等**(`==`),没有 `!=`/数值比较 —— 条件触发仅发生在属性以
        //   String 更新时,boolValue = (m_condition.condition == newValue)。所以这里把 override 当前值
        //   转成与 WE getString() 等价的字符串再比较;命中→true(1),否则→false(0)。
        //   这让 visible:{user:{name,condition}} 的图层/特效显隐正确(此前全走默认回退)。
        if let userObj = dict["user"] as? [String: Any],
           let name = userObj["name"] as? String,
           let condition = userObj["condition"] as? String {
            // 取该属性的当前(覆盖)值;无覆盖时落到 "value" 默认(下方短形之后的 fallthrough 处理)。
            if let ov = overrides[name] {
                let cur: String
                switch ov {
                case .bool(let b): cur = b ? "1" : "0"   // bool 属性的串形(WE 条件常写 condition:"1"/"0")
                case .number(let n):
                    // 整数值去掉 .0 后缀,匹配 combo/scene 里的整数串(如 "2");非整数保留小数。
                    cur = (n == n.rounded()) ? String(Int(n)) : String(n)
                case .string(let s): cur = s            // combo 选项值本就是串(WallpaperProperties 存 "\(v)")
                case .color(let c): cur = String(format: "%.6f %.6f %.6f", c.x, c.y, c.z)
                }
                return (cur == condition)
            }
            // 无覆盖:用属性的「默认值」即 scene 里同字段的 "value" 当当前值,按同样语义比较。
            // value 多为裸串/数字;统一转串后比 condition。这样未被用户改动的条件属性也能正确求值。
            if let dv = dict["value"] {
                let cur: String
                if let b = dv as? Bool { cur = b ? "1" : "0" }
                else if let n = dv as? NSNumber {
                    cur = (n.doubleValue == n.doubleValue.rounded()) ? String(n.intValue) : "\(n)"
                } else if let s = dv as? String { cur = s }
                else { cur = "\(dv)" }
                return (cur == condition)
            }
            return false   // 既无覆盖也无默认:WE 下属性未连接→条件不成立。
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
        let a = floats(s); guard a.count >= 2 else { return d }
        return SIMD2(a[0], a[1])
    }
    static func f3(_ s: Any?, default d: SIMD3<Float> = .zero) -> SIMD3<Float> {
        let a = floats(s); guard a.count >= 3 else { return d }
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
    var originPx: SIMD3<Float>    // 图层中心(场景像素坐标,y 向下)
    var sizePx: SIMD2<Float>?     // 显式 size;nil=autosize(取纹理像素尺寸)
    var cropOffset: SIMD2<Float> = .zero   // model.json cropoffset(裁剪重定位,纹理像素;多部件角色用)
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
    var regionFit: Bool = false      // 区域性 composelayer(非 pulse):特效在该层 region [0,1] 空间跑(裁场景+遮罩到 region)。pulse/打雷=false(走全屏画布 UV,不动)。
    var autosize: Bool = false       // model.json "autosize":尺寸取纹理像素(无显式 size 时)
    var noPadding: Bool = false      // model.json "nopadding"
    var modelWidth: Int? = nil       // model.json "width"(可选)
    var modelHeight: Int? = nil      // model.json "height"(可选)
    var puppet: String? = nil        // model.json "puppet":puppet warp 的模型文件
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
    var cameraShakeRoughness: Float = 1
    var cameraShakeSpeed: Float = 1
    // 后处理(fullscreenlayer 上的 bloom/filmgrain/localcontrast 等):真 WE 转译特效链,
    // 按 scene 顺序、仅可见者。在最终合成帧上依次跑 WEEffectChain(替代旧的手写假 bloom)。
    var postChain: [LayerEffect] = []
    // —— 后处理回退字段(postChain 非空时不用):bloom 已是 lwe 真 4-pass 移植(见 PostProcess)。——
    // 触发条件:相机级 general.bloom=true(WE 相机内建,无 effects/bloom 文件夹故进不了 manifest/postChain),
    // 或 fullscreenlayer 上 file 含 "bloom" 的特效未被转译覆盖。默认值取 WE 真 shader 注解(threshold 0.65/strength 2)。
    var postBloom = false
    var postBloomThreshold: Float = 0.65
    var postBloomStrength: Float = 2.0
    var postBloomTint: SIMD3<Float> = SIMD3(1, 1, 1)
    var postLocalContrast = false
    var postLocalContrastStrength: Float = 0.2

    /// 从 SceneSource 解析 scene.json 并解析图层→纹理引用链。
    /// item 提供时,载入用户在「壁纸设置」里的覆盖值,使可调属性生效。
    static func build(from source: SceneSource, item: WallpaperItem? = nil) -> SceneDocument? {
        // 载入该壁纸的属性覆盖(user-key → 值),供 VecParse.unwrap 在解析时套用。
        VecParse.overrides = Self.loadOverrides(item)
        defer { VecParse.overrides = [:] }   // 解析完清掉,避免影响下一个场景

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
        let clear = VecParse.f4(general["clearcolor"], default: SIMD4(0, 0, 0, 1))
        // 相机视差总开关(general.cameraparallax,可被脚本属性包装)。关时全场景无视差/漂移。
        let cameraParallax = (VecParse.unwrap(general["cameraparallax"]) as? Bool) ?? true
        func gf(_ k: String, _ d: Float) -> Float { (VecParse.unwrap(general[k]) as? NSNumber)?.floatValue ?? d }
        let cameraParallaxAmount = gf("cameraparallaxamount", 1)
        let cameraParallaxMouseInfluence = gf("cameraparallaxmouseinfluence", 1)
        let cameraParallaxDelay = gf("cameraparallaxdelay", 0)
        let cameraShake = (VecParse.unwrap(general["camerashake"]) as? Bool) ?? false
        let cameraShakeAmplitude = gf("camerashakeamplitude", 0)
        let cameraShakeRoughness = gf("camerashakeroughness", 1)
        let cameraShakeSpeed = gf("camerashakespeed", 1)

        let objects = scene["objects"] as? [[String: Any]] ?? []

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
        for obj in objects {
            guard let id = (obj["id"] as? NSNumber)?.intValue else { continue }
            selfVisible[id] = forceShow.contains(id) ? true : Self.parseVisible(obj["visible"])
        }
        func effectiveVisible(_ id: Int) -> Bool {
            if forceShow.contains(id) { return true }
            var v = selfVisible[id] ?? true
            var pid = parentOf[id], n = 0
            while let p = pid, n < 16 { v = v && (selfVisible[p] ?? true); pid = parentOf[p]; n += 1 }
            return v
        }

        var layers: [LayerDesc] = []
        var sounds: [SoundDesc] = []
        var projectLayers: [ProjectLayerDesc] = []
        var hasCursorRipple = false
        var cursorRippleCutoff = 0
        var rippleParams = SIMD4<Float>(1, 1, 1, 1)
        var rippleMaskPath: String? = nil
        var postChain: [LayerEffect] = []
        var postBloom = false, postLC = false
        // 辉光参数取 pkg 真实 general(bloomstrength/threshold/tint);缺省值用 WE 真 shader 注解
        // (downsample_quarter_bloom.frag:strength 默认 2、threshold 默认 0.65、tint 默认 "1 1 1"),
        // 不再用凭感觉的弱默认(0.9/0.8)。每张壁纸读各自真值,数据驱动。
        var postBloomTh: Float = (VecParse.unwrap(general["bloomthreshold"]) as? NSNumber)?.floatValue ?? 0.65
        var postBloomStr: Float = (VecParse.unwrap(general["bloomstrength"]) as? NSNumber)?.floatValue ?? 2.0
        let postBloomTint = VecParse.f3(general["bloomtint"], default: SIMD3(1, 1, 1))
        // 相机级 bloom:WE 的 general.bloom 是相机内建后处理(无 effects/bloom 文件夹 → 不进 manifest/postChain),
        // 之前只看 fullscreenlayer 的 bloom 特效 → 相机级 bloom 被静默丢弃。这里直接据 general.bloom 触发回退真 bloom。
        if (VecParse.unwrap(general["bloom"]) as? Bool) == true { postBloom = true }
        var postLCStr: Float = 0.2
        for obj in objects {
            // 文本图层(时钟/日期):有 text 字段、无 image。单独处理。
            if obj["image"] == nil, obj["text"] != nil, var tl = Self.parseTextLayer(obj, canvas: canvas) {
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
                Log.write("scene: shape/VolumeLight object not supported (id=\((obj["id"] as? NSNumber)?.intValue ?? -1), name=\(obj["name"] as? String ?? ""))")
                continue
            }
            guard let imageRef = obj["image"] as? String else { continue }  // 只取 image 图层

            // 全屏后处理层(fullscreenlayer):不画美术内容,但承载该壁纸的真 WE 后处理特效链
            // (bloom + filmgrain + localcontrast 等)。把可见 effect 按 scene 顺序解析进 postChain,
            // 引擎在最终合成帧上依次跑 WEEffectChain(真转译 shader),替代旧手写假 bloom。
            if imageRef.contains("fullscreenlayer") {
                // 该层自身可见(postprocessing 总开关)才启用后处理链。
                if Self.parseVisible(obj["visible"]) {
                    postChain = Self.parseEffects(obj["effects"], keepWENamed: true)
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
                if let layer = Self.makeAudioBarsLayer(obj, bars: bars, id: (obj["id"] as? NSNumber)?.intValue ?? -1,
                                                       effectiveVisible: effectiveVisible,
                                                       absoluteOrigin: absoluteOrigin,
                                                       absoluteScale: absoluteScale) { layers.append(layer) }
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
                Log.write("scene: skip instanced placeholder layer (id=\((obj["id"] as? NSNumber)?.intValue ?? -1), name=\(obj["name"] as? String ?? ""))")
                continue
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
                let file = (e["file"] as? String) ?? ""
                let fl = file.lowercased(), nl = ((e["name"] as? String) ?? "").lowercased()
                if fl.contains("pulse") || nl.contains("pulse") { return true }
                let wn = Self.weEffectName(file)
                return !wn.isEmpty && Self.transpiledEffectNames.contains(wn)
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
                                isFrameBufferInput = true
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

            // solidlayer 没有纹理但要画;有纹理但解析不到、又不是 solid 的,跳过。
            // frameBufferInput(composelayer/_rt_FullFrameBuffer)无自有贴图但要渲(输入=下方场景),不丢。
            if texPath == nil && !isSolidReal && !isFrameBufferInput { continue }

            // keepWENamed:保留所有有 weName 的真 WE 转译特效(godrays/iris/shimmer/swing/blur/
            // twirl 等没有旧 kind 映射的也照样跑真 shader),不再被 kind==.none 门丢掉。
            let effects = Self.parseEffects(obj["effects"], keepWENamed: true)
            // effect pass override(ObjectParser.cpp:381-394):与 effects 一一对应(保序、含被滤掉的位置→空)。
            let passOverrides = Self.parseEffectPassOverridesPerEffect(obj["effects"])
            // animationlayers(puppet warp,ObjectParser.cpp:439-463):rate/visible/blend/animation,解析存下。
            let animLayers = Self.parseAnimationLayers(obj["animationlayers"])
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
            // 缺口A:cropoffset 重定位(多部件角色散架真因)。WE 把贴图透明边裁掉省显存,model.json.cropoffset
            // 记录裁剪后子图相对原始全幅锚点的位移(纹理像素)。多部件角色部件的 origin 是很小的父-局部值,
            // 真实摆位必须叠加 cropoffset(数据证:凯尔希 puppet 各部件 localOrigin−cropoffset 收敛到同一锚点)。
            // **正确空间(纠正旧 naive 失败版的关键)**:cropoffset 在部件**自身局部空间**,经**父**累积 scale/angle
            // 变换后从 absOrigin 减去 —— 等价于 resolveTransform 累积前 `localOrigin −= cropoffset`(单级精确)。
            // 旧 naive 版误用**自身累积** scale/angle(含部件自身 scale/angle)→ 多变换一层 → 更散,已撤;此为纠正版。
            // 仅对**有 parent 的 child 层**启用。**默认关(opt-in WP_CROPOFFSET=1)**:实测此纠正版公式
            // 改善伊蕾娜未尽之旅(长发恢复)但**破坏 Postscript(头部散架)**——根因是 cropoffset 在不同壁纸里
            // 有的已烘进 origin(再减=双重修正→散)、有的没有,**无通用判别规则**可零回归区分(前任亦因此禁用)。
            // 真正解需建模 WE 完整的纹理 rect/padding 体系(较大工程)。故默认关、保留代码供将来;WP_CROPOFFSET=1 试开。
            if ProcessInfo.processInfo.environment["WP_CROPOFFSET"] != nil,
               objId >= 0, parentOf[objId] != nil,
               (mdlCropOffset.x != 0 || mdlCropOffset.y != 0) {
                let pScale = parentAbsoluteScale(objId)
                let pAngle = parentAbsoluteAngle(objId)
                let shift = rotateVec2(SIMD2(pScale.x * mdlCropOffset.x, pScale.y * mdlCropOffset.y), pAngle)
                absOrigin.x -= shift.x
                absOrigin.y -= shift.y
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
                parallax: VecParse.f2(obj["parallaxDepth"]),
                visible: visible,
                texturePath: texPath,
                color: color,
                blend: isSolidReal ? .translucent : blend,
                isSolid: isSolidReal,
                effects: effects
            )
            layer.scaleScript = scaleScript
            // 缺口B/D:visible/alpha/color 字段挂的 WE JS 脚本(lwe 每帧 reevaluate)。parseVectorScript
            // 对非 {script:...} 字段返回 nil(普通层零影响);静态 visible/color 仍作脚本失败/不可用的回退。
            layer.visibleScript = Self.parseVectorScript(obj["visible"], tag: "vis:\(layer.name)", canvas: canvas)
            layer.alphaScript   = Self.parseVectorScript(obj["alpha"],   tag: "alpha:\(layer.name)", canvas: canvas)
            layer.colorScript   = Self.parseVectorScript(obj["color"],   tag: "col:\(layer.name)", canvas: canvas)
            layer.cropOffset = mdlCropOffset
            // 对象 origin/angles 的 WE 关键帧动画(如头发/发饰随头摆动)。无 animation 时返回 nil(零影响)。
            // 无父链的层(头发0202/发饰 parent=None)关键帧值即绝对值;有父链时 update() 走父链变换。
            layer.originKeyAnim = WEKeyframeAnimation.parse(obj["origin"])
            layer.angleKeyAnim = WEKeyframeAnimation.parse(obj["angles"])
            layer.frameBufferInput = isFrameBufferInput
            // 区域性 composelayer(非 pulse:音频/调色/能量等):特效要在该层 region [0,1] 空间跑(裁场景+遮罩到 region)。
            // pulse(打雷)= false → 走原全屏画布 UV 路径(已验证,不动,避免回归)。
            layer.regionFit = isFrameBufferInput && !composeHasPulse
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
            layer.animationLayers = animLayers
            layer.effectPassOverrides = passOverrides
            // 对象级 colorBlendMode / brightness(ObjectParser.cpp:292-293,均可被 user 包装,故先 unwrap)。
            // 仅解析存下,渲染暂未消费(见 LayerDesc 字段处的 TODO)。
            if let cbm = VecParse.unwrap(obj["colorBlendMode"]) as? NSNumber { layer.colorBlendMode = cbm.intValue }
            if let br = VecParse.unwrap(obj["brightness"]) as? NSNumber { layer.brightness = br.floatValue }
            layers.append(layer)
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
        doc.postChain = postChain
        doc.postBloom = postBloom; doc.postBloomThreshold = postBloomTh; doc.postBloomStrength = postBloomStr
        doc.postBloomTint = postBloomTint
        doc.postLocalContrast = postLC; doc.postLocalContrastStrength = postLCStr
        doc.sounds = sounds
        doc.camera = camera
        doc.projectLayers = projectLayers

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
                reason = (obj["text"] != nil) ? "文本层" : (image.contains("solidlayer") || mdlSolid ? "纯色/音频条层" : "图层")
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
                reason = "🔴 文本层脚本求值失败被丢(parseTextLayer 返回 nil)"
            } else if (image.contains("solidlayer") || mdlSolid), Self.dependsOnUnsupportedEffect(obj) {
                reason = "🔴 solidlayer 挂未实现的音频可视化特效(如 audioline)被 dependsOnUnsupportedEffect 跳过"
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
        pl.effects = Self.parseEffects(obj["effects"], keepWENamed: true)
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
        return effects.contains { (($0["file"] as? String) ?? "").lowercased().contains("cursorripple") }
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
    static func parseEffects(_ raw: Any?, keepWENamed: Bool = false) -> [LayerEffect] {
        guard let arr = raw as? [[String: Any]] else { return [] }
        var out: [LayerEffect] = []
        for e in arr {
            // effect 自身可见性(可被脚本属性包装)。
            guard Self.parseVisible(e["visible"]) else { continue }
            let kind = LayerEffectKind(file: (e["file"] as? String) ?? "")
            let weName = Self.weEffectName((e["file"] as? String) ?? "")
            // 旧内联路径:只要已知 kind;后处理链路径:保留任何有 weName 的 WE 转译特效。
            guard kind != .none || (keepWENamed && !weName.isEmpty) else { continue }
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
            let maskSlots = Self.weMaskSlots[weName] ?? []
            if let p0 = passes.first, let texs = p0["textures"] as? [Any] {
                for (idx, t) in texs.enumerated() where idx >= 1 {
                    guard let s = VecParse.unwrap(t) as? String, !s.isEmpty else { continue }
                    weAux[idx] = s
                    if maskPath == nil, maskSlots.contains(idx) || s.lowercased().contains("mask") {
                        maskPath = Self.resolveMask(s)
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
            // 遮罩是隐式 combo:分配了含 "mask" 的辅助槽 → MASK=1(让 shader 走 #if MASK 分支采样
            // opacitymask 限定白区)。对没有 MASK combo 的 effect(如 waterflow,其 g_Texture1 是 flowmask)
            // 此 combo 无对应变体,selectVariant 自动回退 base,无害;真正的 localization 由 weAux 字面绑定提供。
            if maskPath != nil { weCombos["MASK"] = "1" }
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
                                           absoluteScale: (Int) -> SIMD3<Float>) -> LayerDesc? {
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
        let fx = SceneDocument.parseEffects(obj["effects"], keepWENamed: true)
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
            Bundle.main.resourceURL?.appendingPathComponent("WEEffects.json"),
            URL(fileURLWithPath: NSString(string: "~/Developer/LiveWallpaper/Tools/generated/WEEffects.json").expandingTildeInPath)
        ].compactMap { $0 }
        for p in paths {
            if let d = try? Data(contentsOf: p),
               let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { return Set(j.keys) }
        }
        return []
    }()

    /// 每个 effect 的「opacitymask 槽」索引集合(manifest 里 g_Texture<N> 的 combo=="MASK" → 槽 N)。
    /// **正解:opacitymask 由 shader 槽的 mode/combo 判定(转译已捕获),不是靠贴图名含 "mask"**。
    /// 旧逻辑靠名字 → 遮罩贴图叫「影子」(opacity 效果)等不含 "mask" 的会漏判 → 没设 MASK combo → 选无遮罩
    /// base 变体 → 效果填满整个矩形(如 3233141951 id=228 身体音频条没被身体剪影遮罩=大方框)。
    static let weMaskSlots: [String: Set<Int>] = {
        let paths = [
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

    /// manifest 里声明了 g_AudioSpectrum* 的 effect 名集合(= 需系统音频频谱的音频可视化 effect)。
    /// 按 manifest **真值**识别音频层,覆盖汉化/全下划线路径(英文文件名匹配会漏,如本库 2846660316 的
    /// effect file 是全下划线)。g_AudioSpectrum 声明在 frag/vert 的 uniforms(不在 uniformMeta),三处都扫。
    /// 与 WEEffectChain.usesAudioSpectrum 同口径,只是在 SceneDocument 解析期从 JSON 直接读(读一次)。
    static let weAudioEffectNames: Set<String> = {
        let paths = [
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
            if wn.isEmpty || !Self.transpiledEffectNames.contains(wn) { hasUnsupported = true }
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
            guard !rawText.isEmpty, rawText.count <= 40,
                  !rawText.contains("export"), !rawText.contains("function"), !rawText.contains("{"),
                  !isPlaceholder else { return nil }
            kind = .staticText(rawText)
        }

        // WE 用大字号渲染纹理、再靠 layer.size×scale 的盒子定屏上大小;字号太小会糊。
        // 故纹理总以大字号渲染求清晰(纹理像素只用来定字形纵横比 + 抗锯齿质量),
        // 真正的屏上尺寸由引擎据 boxSizePx×scale 适配(见 SceneRenderEngine.textQuad)。
        // 有盒子时把渲染字号再抬高(让纹理高分辨率,缩到盒子也锐利);无盒子时保留旧 ≥64 行为。
        let renderPt: CGFloat = boxSize != nil ? max(128, pt * 2) : max(64, pt * 2)
        var text = TextLayerDesc(kind: kind, color: color, pointSize: renderPt)
        text.align = align
        text.verticalAlign = vAlign
        text.fontName = fontName
        text.boxSizePx = boxSize

        // 有显式 size:屏上尺寸 = size×scale 盒子(WE 行为),引擎按字形纵横比适配进盒子并按 align 放置
        //   → 这里 sizePx=nil(引擎对 text 层走 boxSizePx 专路,不用 LayerDesc.sizePx 的拉伸贴满)。
        // 无显式 size:autosize(取文本纹理像素)× scale,保持旧行为(静态文本/问候)。
        // 文字颜色已烤进纹理,白色不二次染;但**透明度 alpha 要读**(WE 时钟/日期常 alpha:0.5):
        // 照图像层做法(SceneModel:758)取 obj["alpha"] 写进 color.w,否则文字按 100% 不透明渲染、比原版偏实。
        var textAlpha: Float = 1
        if let a = VecParse.unwrap(obj["alpha"]) as? NSNumber { textAlpha = a.floatValue }
        return LayerDesc(
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
    }

    /// 按图层名 / value 文本推断近似类型(脚本不可用或无脚本时的回退)。返回 nil = 无法识别。
    private static func approxKind(name: String, rawText: String) -> TextLayerKind? {
        let upper = rawText.uppercased()
        if upper.contains("GOOD") && (upper.contains("MORNING") || upper.contains("AFTERNOON")
            || upper.contains("EVENING") || upper.contains("NIGHT")) {
            return .greeting
        } else if upper == "DAY" || (name.hasPrefix("day") && !name.hasPrefix("date")) {
            return .dayOfWeek
        } else if name.contains("clock") || name == "时钟" || name.contains("time") {
            return .clock
        } else if name.contains("date") || name == "日期" || name == "dy" {
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
            switch resolved {
            case let b as Bool: out[k] = b
            case let n as NSNumber:
                // Bool 经 NSNumber 包装(CFBoolean)时 objCType 是 "c";其余按 Double。
                if CFGetTypeID(n) == CFBooleanGetTypeID() { out[k] = n.boolValue }
                else { out[k] = n.doubleValue }
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
        return out
    }

    /// visible 字段:可能是 Bool,或 {"value": Bool, "user": ...}(用户可控属性)。
    /// 经 unwrap 走覆盖逻辑(用户在设置里关了某图层 → 这里返回 false)。缺省 = true。
    private static func parseVisible(_ v: Any?) -> Bool {
        if let b = VecParse.unwrap(v) as? Bool { return b }
        return true
    }

    /// 把 material textures[0] 的 base 名解析为 pkg 内实际 .tex 路径。
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
