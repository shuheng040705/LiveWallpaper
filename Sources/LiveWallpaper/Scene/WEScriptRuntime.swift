import Foundation
import JavaScriptCore

/// WE 的时钟/日期/进度条等图层由 **JavaScript 脚本** 每帧驱动:
///   text 图层的 text = {"script": "...export function update(value){...}"}
///   "Second" 这类层把 script 挂在 scale/origin/alpha 等矢量字段上。
/// WG/WE 内嵌 JS 引擎逐帧跑这些脚本生成字符串(或 Vec3)。本类用 JavaScriptCore 还原:
///   - 去掉 ES module 语法(export / import / export let __workshopId=…),保留可 eval 的函数体;
///   - 注入 createScriptProperties() 链式 shim,按「图层 scriptproperties 覆盖 > 脚本 addX 默认」解析属性;
///   - 每次刷新调用 update(currentValue),拿返回值(String / Vec3)。
/// JSC 原生支持 new Date()。脚本抛错/用到不可用 API 时,调用方回退到旧近似(并 Log)。
final class WEScript {
    /// 注入脚本上下文的 scene 对象元数据。这里保留的是 pkg 的局部变换，
    /// 因为 WE 脚本通过 `parent.origin + thisLayer.origin` 等方式自行组合父子坐标。
    struct SceneLayerDefinition: Equatable {
        var id: Int
        var name: String
        var parentId: Int?
        var visible: Bool
        var alpha: Float
        var color: SIMD4<Float>
        var origin: SIMD3<Float>
        var scale: SIMD3<Float>
        var angles: SIMD3<Float>
        var size: SIMD2<Float>
    }

    enum Result {
        case string(String)
        case vec3(SIMD3<Float>)
        case failed              // 脚本抛错/不可用 → 调用方回退
    }

    private let context = JSContext()!
    /// 已安装对象树。相同定义重复传入时必须保持 JS 对象身份：脚本常在 init 中缓存 parent，
    /// 若 SceneRenderEngine.load 再建一遍，缓存引用会与 thisScene/getParent 的新注册表分叉。
    private var installedSceneLayerDefs: [SceneLayerDefinition]? = nil
    private let updateFn: JSValue?
    /// 脚本声明的属性最终值(name → JS 值),已套用图层覆盖。供调试 / 日志。
    private(set) var resolvedProps: [String: Any] = [:]
    /// JS 异常标记。用 class 引用盒,避免在 init 里 exceptionHandler 闭包过早捕获 self。
    private final class Flag {
        var hit = false
        var formattingException = false
        var exception: JSValue? = nil
    }
    private let exFlag = Flag()
    var didFail: Bool {
        get { exFlag.hit }
        set {
            exFlag.hit = newValue
            if !newValue { exFlag.exception = nil }
        }
    }
    let sourceTag: String        // 仅用于日志(图层名)

    /// 脚本里有无 init():首帧跑一次(WE 生命周期)。
    private let initFn: JSValue?
    /// 墙钟兜底起点:仅当上层未传引擎 sim time 时,engine.runtime 回退 now - startTime。
    /// 正常路径 runtime = 引擎全局 sim time(lwe g_Time,所有脚本共享),见 tickFrame。
    private let startTime = Date()
    /// 上次 run 的 runtime 秒,用来算 engine.frametime(帧间隔)。
    private var lastRuntime: Double = 0
    /// init() 是否已调过(首帧调一次)。
    private var didInit = false

    // MARK: - 媒体(now-playing)状态 / 回调句柄(审计修复 #3)
    /// 脚本若定义了 mediaPropertiesChanged / mediaTimelineChanged / mediaPlaybackChanged,
    /// init 时取其全局句柄(本运行时把脚本 eval 在全局,故媒体回调也落在全局,同 update/init)。
    private let mediaPropertiesChangedFn: JSValue?
    private let mediaTimelineChangedFn: JSValue?
    private let mediaPlaybackChangedFn: JSValue?
    private let mediaThumbnailChangedFn: JSValue?
    /// 任一媒体回调存在。渲染器只给这类脚本推送媒体快照，普通脚本零额外工作。
    private(set) var usesMediaEvents = false
    /// 纯 media 驱动文本层(无 update,只有 mediaPropertiesChanged):歌名/艺术家。失败不回退时钟。
    let isMediaDriven: Bool
    /// 脚本是否用音频(调 engine.registerAudioBuffers / 读 __audio*)→ 引擎据此采集音频并每帧喂 setAudioSpectrum。
    let usesAudio: Bool
    /// 脚本是否在 init 里调 thisScene.createLayer(运行时动态建层,如音频条 64 根 bar)。
    /// 引擎据此走「多实例渲染同一模型」路径(runDynamicBars),不把它当普通 visible/scale 脚本(其 update void)。
    let createsLayers: Bool
    /// 脚本是否用跨层 API(thisScene.getLayer / engine.getObjectBy*):控制器脚本写**其它**层的
    /// visible/alpha/origin/scale/…(土星壁纸 Dock 主控脚本据 scriptProperties.enableDock 写各图标层
    /// `getLayer(name).visible/alpha=…`;伊蕾娜昼夜、夜莺视频时段切换同类)。引擎据此对**此脚本**安装
    /// 真实层注册表(setSceneLayers)并每帧 readLayerWrites 回灌目标层。仅含此 token 的脚本才安装记脏
    /// 层 → 普通自层脚本(时钟/秒/now-playing)零影响。
    let usesLayerAPI: Bool
    /// 上次派发的签名,用于 lwe 式去重:仅在变化时再派发,避免每帧重复触发脚本回调。
    private var lastMediaPropertiesSig: String? = nil
    private var lastMediaTimelineSig: String? = nil
    private var lastMediaPlaybackSig: String? = nil
    private var lastMediaThumbnailSig: String? = nil
    private struct MediaState {
        var title: String
        var artist: String
        var position: Double
        var duration: Double
        var playbackState: Int?
        var thumbnailRevision: Int?
        var thumbnailPalette: NowPlayingProvider.ThumbnailPalette?
    }
    /// 调用方先写入最新快照；真正回调在下一次 tickFrame 的 init 之后派发，保证 WE 生命周期顺序。
    private var pendingMediaState: MediaState? = nil

    /// - Parameters:
    ///   - script: 原始脚本源码(含 ES module 语法)。
    ///   - propertyOverrides: 该图层 text.scriptproperties / 字段.scriptproperties 解出的覆盖
    ///        (脚本属性 name → 已 unwrap 的值:Bool/Double/String)。优先于脚本里 addX 的 value。
    ///   - tag: 日志标签(图层名)。
    ///   - canvas: 场景画布尺寸(WE 的 orthogonalprojection w/h)。注入成 engine.canvasSize。
    ///        WE 挂件容器/时钟的 origin 脚本第一行就是 `value.x = scriptProperties.x * engine.canvasSize.x`;
    ///        不注入会 TypeError 抛错 → 脚本失败 → 调用方退回旧画布快照(飘字根因 B)。
    init?(script: String, propertyOverrides: [String: Any], tag: String, canvas: SIMD2<Float> = SIMD2(1920, 1080)) {
        self.sourceTag = tag
        // 纯局部检查(无 self):脚本是否用音频。供引擎决定采集音频 + 每帧喂频谱。
        self.usesAudio = script.contains("registerAudioBuffers") || script.contains("__audio")
        // 纯局部检查:脚本是否运行时建层(thisScene.createLayer,音频条 64 根 bar)。
        self.createsLayers = script.contains("createLayer")
        // 纯局部检查:脚本是否用跨层 API(getLayer/getObjectBy*)→ 控制器脚本写**其它**层(Dock 显隐等)。
        self.usesLayerAPI = script.contains("getLayer") || script.contains("getObjectByName")
            || script.contains("getObjectById") || script.contains("getParent")

        // JS 异常 → 记一笔并标记失败(update() 仍可能返回 undefined,调用方据 didFail/nil 回退)。
        // 只捕获引用盒(非 self),避免在所有存储属性初始化完成前引用 self。
        let flag = exFlag
        context.exceptionHandler = { _, exc in
            flag.hit = true
            // exceptionHandler 正运行在 JSC 抛异常的栈上。在这里读取 JSValue 的 message/toString
            // 都可能再次进入 JSC 并同步重入 handler。只保存句柄；等 call/evaluateScript 完全返回后
            // 再由 reportException() 格式化，彻底切断 handler → JS → handler 的递归链。
            if !flag.formattingException { flag.exception = exc }
        }

        // 0) 注入 WE prelude(Vec2/3/4、WEMath、WEColor、console no-op、localStorage、input、
        //    engine、thisLayer/thisScene 桩 + setInterval/__weRunIntervals)。必须在脚本 eval 前:
        //    stripModuleSyntax 删掉了脚本对 WEMath/WEColor 等的 import,这些全局把它们补回来,
        //    复杂脚本(console.log / setInterval / 读写 thisLayer 等)才不会因缺全局抛错回退。
        context.evaluateScript(WEScript.preludeSource)

        // 0b) 注入 engine.canvasSize + engine.screenResolution(WE 的渲染画布尺寸,这里用场景
        //     orthogonalprojection w/h)。WE 挂件容器/时钟/日期/灵动岛/拖拽脚本第一行就读
        //     engine.canvasSize.x/y 或 engine.screenResolution.x/y,缺任一必抛 TypeError →
        //     整个时钟挂件脚本崩、时钟不显示。screenResolution 用画布尺寸作为合理值(脚本主要用它
        //     做相对定位,画布即渲染区域;真实屏幕分辨率会被等比 cover 到画布,相对位置一致)。
        if let engine = context.objectForKeyedSubscript("engine"), engine.isObject {
            let cs: [String: Any] = ["x": canvas.x, "y": canvas.y]
            engine.setObject(cs, forKeyedSubscript: "canvasSize" as NSString)
            engine.setObject(cs, forKeyedSubscript: "screenResolution" as NSString)
        }
        // 0c) 注入 video 播放控制桩。视频图层(MP4 动态贴图)的可见性/播放控制脚本会读
        //     video.isPlaying/duration/rate/getCurrentTime() 并调 play()/pause()/stop()/setCurrentTime()。
        //     我方 VideoTexture 自管「一直播放 + 手动循环」,这里给个**恒在播放**的桩:让这类脚本不再因
        //     缺 video 全局每帧抛 TypeError(刷日志),可见性脚本据 isPlaying=true 正常返回可见。方法均 no-op
        //     (播放真由 VideoTexture 控,脚本的 start/end/speed 修剪暂不接,层照常全程播放)。
        context.evaluateScript("""
        globalThis.video = {
          isPlaying: true, rate: 1.0, duration: 1e9,
          play: function(){}, pause: function(){}, stop: function(){},
          setRate: function(){}, setCurrentTime: function(){}, getCurrentTime: function(){ return 0; }
        };
        """)

        // 1) 注入 createScriptProperties shim + 覆盖表。shim 是纯 JS,链式 addX/finish。
        //    覆盖值通过原生注入的 __wePropOverrides 提供:finish() 时按 name 用覆盖替换默认。
        let overridesObj = WEScript.toJSObject(propertyOverrides)
        context.setObject(overridesObj, forKeyedSubscript: "__wePropOverrides" as NSString)
        context.evaluateScript(WEScript.shimSource)

        // 2) 去 module 化脚本体,eval 之。eval 后 scriptProperties / update 落在全局。
        let body = WEScript.stripModuleSyntax(script)
        context.evaluateScript(body)
        if exFlag.hit {
            Self.reportException(exFlag, tag: tag)
            return nil
        }   // 直接读引用盒(此时 updateFn 尚未赋值,不能用 self.didFail)

        // 3) 取 update 句柄。注意:这是核心契约——文本/矢量脚本都靠 update(value) 的**返回值**
        //    模型(实测时钟脚本就是返回 string;别破坏)。update 缺失才判失败。
        // update 句柄。**纯 media 文本**(歌名/艺术家:无 update,只有 mediaPropertiesChanged)不能因缺
        // update 丢弃 —— 否则 Now Playing 整组文本消失,正是用户报的"music name 没识别"。无 update **且**
        // 无任何 media 回调才判失败。update 仍是时钟/矢量脚本的核心契约(返回值模型),有则照常用。
        let updateCandidate = context.objectForKeyedSubscript("update")
        let hasUpdate = updateCandidate.map { !$0.isUndefined } ?? false
        // 显式接 ctx(不捕获 self):此时 self 的存储属性尚未全初始化,捕获 self 的闭包会触发
        // Swift「self used before initialized」。同下方 grabFn 的写法。
        func hasGlobalFn(_ ctx: JSContext, _ n: String) -> Bool {
            guard let f = ctx.objectForKeyedSubscript(n) else { return false }
            return !f.isUndefined && !f.isNull && f.isObject
        }
        guard hasUpdate || hasGlobalFn(context, "mediaPropertiesChanged") || hasGlobalFn(context, "mediaTimelineChanged")
            || hasGlobalFn(context, "mediaPlaybackChanged") || hasGlobalFn(context, "mediaThumbnailChanged") else {
            Log.write("WEScript[\(tag)] no update() nor media callback after eval")
            return nil
        }
        self.updateFn = hasUpdate ? updateCandidate : nil

        // 3b) 可选 init():部分复杂脚本把一次性初始化放在 init() 里(WE 生命周期首帧调一次)。
        //     时钟脚本没有 init,这里取到的就是 nil/undefined,不影响其返回值模型。
        if let initF = context.objectForKeyedSubscript("init"), !initF.isUndefined, !initF.isNull {
            self.initFn = initF
        } else {
            self.initFn = nil
        }

        // 3c) 媒体事件回调(审计修复 #3):脚本若定义 mediaPropertiesChanged/mediaTimelineChanged/
        //     mediaPlaybackChanged,取其全局句柄(对标 lwe 模块 export 的同名函数)。无则留 nil,
        //     dispatchMediaState 时直接 no-op。
        // grabFn 显式接 ctx(不捕获 self):媒体句柄是 let 无默认,须 init 内赋值;捕获 self 的局部函数
        // 在它们赋值完成前调用会触发 Swift 「self used before all stored properties initialized」。
        func grabFn(_ ctx: JSContext, _ name: String) -> JSValue? {
            guard let f = ctx.objectForKeyedSubscript(name), !f.isUndefined, !f.isNull,
                  f.isObject else { return nil }
            return f
        }
        self.mediaPropertiesChangedFn = grabFn(context, "mediaPropertiesChanged")
        self.mediaTimelineChangedFn = grabFn(context, "mediaTimelineChanged")
        self.mediaPlaybackChangedFn = grabFn(context, "mediaPlaybackChanged")
        self.mediaThumbnailChangedFn = grabFn(context, "mediaThumbnailChanged")
        self.usesMediaEvents = self.mediaPropertiesChangedFn != nil || self.mediaTimelineChangedFn != nil
            || self.mediaPlaybackChangedFn != nil || self.mediaThumbnailChangedFn != nil
        // applyUserProperties(WE 生命周期:用户改属性时回调):Dock 等控制器脚本导出。有则记下,引擎在场景
        //   加载后(scriptProperties 已注入用户值)派发已变化的属性名,触发脚本重置派生状态。
        self.hasApplyUserProperties = hasGlobalFn(context, "applyUserProperties")
        // 纯 media 驱动文本(歌名/艺术家):无 update(),只有 mediaPropertiesChanged 把 now-playing 写进
        // thisLayer.text。这类层"当前字符串"由 dispatchMediaState 设、runString 读回 thisLayer.text,
        // 失败时**不可**回退成时钟(它不是时钟层,见 TextLayerRenderer.currentString)。
        self.isMediaDriven = !hasUpdate &&
            (self.mediaPropertiesChangedFn != nil || self.mediaTimelineChangedFn != nil)

        // 解析后的属性快照(scriptProperties 是普通对象)。
        if let sp = context.objectForKeyedSubscript("scriptProperties"), sp.isObject,
           let dict = sp.toDictionary() as? [String: Any] {
            resolvedProps = dict
        }
    }

    /// 在 JS call/evaluateScript 已经退栈后格式化并记录最近一次异常。
    ///
    /// 只读取字符串异常本身或标准 Error.message，不执行任意异常对象的 toString。读取 message
    /// 若碰到恶意 getter 再次抛错，exceptionHandler 会因 formattingException=true 仅记 hit，
    /// 不会覆盖原异常或递归格式化。
    private static func reportException(_ flag: Flag, tag: String) {
        guard flag.hit else { return }
        flag.formattingException = true
        var message = "JavaScript exception"
        if let exc = flag.exception {
            if exc.isString {
                message = exc.toString() ?? message
            } else if let errorMessage = exc.objectForKeyedSubscript("message"),
                      errorMessage.isString {
                message = errorMessage.toString() ?? message
            }
        }
        flag.exception = nil
        flag.formattingException = false
        Log.write("WEScript[\(tag)] JS exception: \(message)")
    }

    private func reportException() {
        Self.reportException(exFlag, tag: sourceTag)
    }

    /// 跑一次脚本,传入当前值。回退判定交给调用方(failed / 非预期类型)。
    /// 审计修复(#1):新增可选 simTime/frametime 参数;上层应传以保证脚本动画与 sim-time 同步、
    ///   无头渲染确定。默认 nil 时 tickFrame 回退用墙钟 Date()(旧行为,调用方不改也能编)。
    ///   - simTime:引擎累计 sim 时间(秒),用作 engine.runtime 的时间源。
    ///   - frametime:引擎本帧 sim dt(秒,对标 lwe `g_Time - g_TimeLast`);音频平滑等脚本依赖它。
    ///     传入时 engine.frametime 直接取此真实帧间隔;nil 时回退用 runtime 差近似。
    func runString(current: String, simTime: Double? = nil, frametime: Double? = nil) -> Result {
        didFail = false
        tickFrame(initArg: current, simTime: simTime, frametime: frametime)
        // 纯 media 文本(歌名/艺术家):无 update()。now-playing 由 dispatchMediaState 写进 thisLayer.text,
        // 这里直接读回(不需要 update 返回值)。无歌曲信息时 text 为空 → .failed 让调用方回退 pkg value/空。
        if updateFn == nil {
            if isMediaDriven, let layer = context.objectForKeyedSubscript("thisLayer"),
               layer.isObject, let textVal = layer.objectForKeyedSubscript("text"), textVal.isString {
                let s = textVal.toString() ?? ""
                if !s.isEmpty { return .string(s) }
            }
            return .failed
        }
        let fn = updateFn!
        guard let ret = fn.call(withArguments: [current]), !didFail else {
            reportException()
            return .failed
        }
        if ret.isString { return .string(ret.toString()) }
        // 某些脚本可能返回 number 等;转成字符串兜底。
        if ret.isNumber { return .string(ret.toString()) }
        // 返回值模型没拿到(undefined/null):部分脚本不 return,而是直接写 thisLayer.text。
        // 读回 thisLayer.text 作兜底——非空且非失败才用,否则仍判 failed 走调用方近似回退。
        // (时钟脚本会走上面的 isString 分支,不到这里,故此兜底不影响其返回值模型。)
        if !didFail, let layer = context.objectForKeyedSubscript("thisLayer"),
           layer.isObject, let textVal = layer.objectForKeyedSubscript("text"),
           textVal.isString {
            let s = textVal.toString() ?? ""
            if !s.isEmpty { return .string(s) }
        }
        return .failed
    }

    /// 矢量脚本(scale/origin/…):传入当前 Vec3,期望返回带 x/y/z 的对象**或标量**。
    /// 审计修复(#1):同 runString,新增可选 simTime/frametime;上层应传引擎 sim 时间(秒)做时间源、
    ///   本帧 sim dt 做 frametime,默认 nil 回退墙钟/runtime 差。
    func runVec3(current: SIMD3<Float>, simTime: Double? = nil, frametime: Double? = nil) -> Result {
        didFail = false
        // WE 传入的属性矢量是 Vec3，不是仅有 x/y/z 的桥接字典。官方脚本会直接调用
        // value.copy()/multiply()/hasOwnProperty()；普通对象会在这些调用处失败。
        context.setObject([Double(current.x), Double(current.y), Double(current.z)],
                          forKeyedSubscript: "__weCurrentVec3" as NSString)
        guard let arg = context.evaluateScript(
            "new Vec3(__weCurrentVec3[0], __weCurrentVec3[1], __weCurrentVec3[2])"
        ) else { return .failed }
        tickFrame(initArg: arg, simTime: simTime, frametime: frametime)      // 同 runString:刷新 runtime + 首帧 init(传当前 Vec3) + 跑 intervals
        // 只有媒体回调的属性脚本也必须完成 init + 事件派发；没有 update 返回值时保留静态/关键帧通道。
        guard let fn = updateFn else { return .failed }
        guard let ret = fn.call(withArguments: [arg]), !didFail else {
            reportException()
            return .failed
        }
        // WE 标量缩放:scale 脚本(如「主三角」音频缩放)update() 直接 return 一个数字 → 各轴同乘该标量。
        // 旧代码只认 ret.isObject,数字返回必失败回退。这里先收标量分支。
        if ret.isNumber {
            let s = ret.toDouble()
            guard s.isFinite else { return .failed }
            return .vec3(SIMD3(Float(s), Float(s), Float(s)))
        }
        guard ret.isObject else { return .failed }
        let x = ret.objectForKeyedSubscript("x")?.toDouble() ?? Double(current.x)
        let y = ret.objectForKeyedSubscript("y")?.toDouble() ?? Double(current.y)
        let z = ret.objectForKeyedSubscript("z")?.toDouble() ?? Double(current.z)
        guard x.isFinite, y.isFinite, z.isFinite else { return .failed }
        return .vec3(SIMD3(Float(x), Float(y), Float(z)))
    }

    /// 布尔脚本(对象/特效 visible:lwe 每帧 reevaluate)。update(value) 据 engine.timeOfDay / Date /
    /// Math.random / 音频 返回 bool(或可转 bool 的数字)。返回 nil = 脚本不可用/抛错 → 调用方回退静态值。
    func runBool(current: Bool, simTime: Double? = nil, frametime: Double? = nil) -> Bool? {
        didFail = false
        tickFrame(initArg: current, simTime: simTime, frametime: frametime)
        guard let fn = updateFn else {
            guard !didFail, let layer = context.objectForKeyedSubscript("thisLayer"), layer.isObject,
                  let value = layer.objectForKeyedSubscript("visible"),
                  value.isBoolean || value.isNumber else { return nil }
            return value.toBool()
        }
        guard let ret = fn.call(withArguments: [current]), !didFail else {
            reportException()
            return nil
        }
        if ret.isBoolean || ret.isNumber { return ret.toBool() }
        // 部分脚本不 return、直接写 thisLayer.visible。
        if let layer = context.objectForKeyedSubscript("thisLayer"), layer.isObject,
           let v = layer.objectForKeyedSubscript("visible"), v.isBoolean || v.isNumber {
            return v.toBool()
        }
        return nil
    }

    /// 标量脚本(alpha:lwe 每帧 reevaluate)。update(value) 传当前标量、期望返回数字。
    /// 返回 nil = 不可用/抛错/非有限 → 调用方回退静态值。
    func runScalar(current: Float, simTime: Double? = nil, frametime: Double? = nil) -> Float? {
        didFail = false
        tickFrame(initArg: current, simTime: simTime, frametime: frametime)
        guard let fn = updateFn else {
            guard !didFail, let layer = context.objectForKeyedSubscript("thisLayer"), layer.isObject,
                  let value = layer.objectForKeyedSubscript("alpha"), value.isNumber else { return nil }
            let result = value.toDouble()
            return result.isFinite ? Float(result) : nil
        }
        guard let ret = fn.call(withArguments: [Double(current)]), !didFail else {
            reportException()
            return nil
        }
        if ret.isNumber { let d = ret.toDouble(); return d.isFinite ? Float(d) : nil }
        return nil
    }

    /// 把外部(3D 单-context 宿主跑出的)`shared` 快照合并进本脚本的 context。
    /// 3D 场景:per-layer 2D 脚本各自独立 context、无 shared(读 shared.sun_D_real 等会抛错→文字空/位置错)。
    /// 引擎在建好层后,把宿主算出的 shared(324 键:行星位置/角度/dock 屏幕坐标)注入每层脚本 → 文字/位置算得出。
    func injectShared(_ json: String) {
        guard !json.isEmpty, json != "{}" else { return }
        context.setObject(json, forKeyedSubscript: "__injJSON" as NSString)
        context.evaluateScript("(function(){try{var s=JSON.parse(__injJSON); if(typeof shared==='undefined'||!shared)shared={}; for(var k in s)shared[k]=s[k];}catch(e){}})()")
    }

    // MARK: - 运行时动态图层(thisScene.createLayer:音频条等脚本运行时生成的层)

    /// 一根运行时动态图层(脚本 createLayer 出来的 bar)读回的变换。引擎据此多实例渲染同一 bar 模型。
    /// origin/scale/angles 是 WE 对象空间(像素;与本层 originPx 同空间),alignment 是 'centre'/'bottom'/'top'。
    struct DynamicBar {
        var origin: SIMD3<Float>
        var scale: SIMD3<Float>
        var angles: SIMD3<Float>     // 此脚本 anglesY 滑块单位=度
        var alignment: String
    }

    /// 把模板层(thisLayer)的真实场景 origin/scale/angles 注入,供脚本 `baseOrigin = thisLayer.origin` 读对。
    /// 必须在首次 runDynamicBars(init)之前调用一次。
    /// ⚠ 必须注入真正的 **Vec3 实例**(不是裸 {x,y,z} 对象):脚本 `baseOrigin = thisLayer.origin; baseOrigin.copy()`
    ///   会调 Vec3.copy(),裸对象无此方法 → 抛异常被脚本 try/catch 吞掉 → 所有 bar 静止不更新。故用 JS new Vec3(...)。
    func setTemplateLayerTransform(origin: SIMD3<Float>, scale: SIMD3<Float>, angles: SIMD3<Float>) {
        guard let layer = context.objectForKeyedSubscript("thisLayer"), layer.isObject else { return }
        context.evaluateScript("""
        (function(){
          if (typeof thisLayer === 'undefined' || !thisLayer) return;
          thisLayer.origin = new Vec3(\(origin.x), \(origin.y), \(origin.z));
          thisLayer.scale  = new Vec3(\(scale.x), \(scale.y), \(scale.z));
          thisLayer.angles = new Vec3(\(angles.x), \(angles.y), \(angles.z));
        })();
        """)
    }

    /// 把模板层的真实 WE `size` 注入脚本上下文。
    ///
    /// `thisLayer.size` 是 scene.json 当前对象的局部尺寸。拖拽/屏幕边界脚本会将它与
    /// `thisLayer.scale` 相乘；缺失时位置脚本直接抛 TypeError，随后回退到 pkg 的裸 value。
    /// prelude 的 size getter 返回 copy，因此脚本可原地修改读取值而不会逐帧污染真实尺寸。
    func setTemplateLayerSize(_ size: SIMD2<Float>) {
        guard let layer = context.objectForKeyedSubscript("thisLayer"), layer.isObject else { return }
        context.evaluateScript("""
        (function(){
          if (typeof thisLayer === 'undefined' || !thisLayer) return;
          thisLayer.size = new Vec2(\(size.x), \(size.y));
        })();
        """)
    }

    /// 绑定当前脚本所属对象的身份和基础属性。`getParent()` 会在 setSceneLayers 安装对象树后，
    /// 按 parent id 返回同一个注册层对象；无父对象时严格返回 null。
    func setTemplateLayerIdentity(id: Int, name: String, parentId: Int?,
                                  visible: Bool, alpha: Float, color: SIMD4<Float>) {
        guard let layer = context.objectForKeyedSubscript("thisLayer"), layer.isObject else { return }
        layer.setObject(id, forKeyedSubscript: "id" as NSString)
        layer.setObject(name, forKeyedSubscript: "name" as NSString)
        layer.setObject(parentId.map(NSNumber.init(value:)) ?? NSNull(),
                        forKeyedSubscript: "_parentId" as NSString)
        layer.setObject(visible, forKeyedSubscript: "visible" as NSString)
        layer.setObject(Double(alpha), forKeyedSubscript: "alpha" as NSString)
        context.setObject([Double(color.x), Double(color.y), Double(color.z), Double(color.w)],
                          forKeyedSubscript: "__weTemplateColor" as NSString)
        context.evaluateScript("""
        if (globalThis.thisLayer && Array.isArray(globalThis.__weTemplateColor)) {
          thisLayer.color = new Vec4(__weTemplateColor[0], __weTemplateColor[1],
                                     __weTemplateColor[2], __weTemplateColor[3]);
        }
        """)
    }

    /// 配置当前属性脚本对应的 WE 关键帧时间轴。脚本经 thisLayer/thisObject.getAnimation()
    /// 修改 rate/play/pause/stop/setFrame，Swift 求值关键帧时再读取同一控制器的当前帧。
    func setTemplateAnimation(frameCount: Float, fps: Float) {
        context.evaluateScript("""
        if (globalThis.__weAnimationController) {
          __weAnimationController.frameCount = \(max(0, frameCount));
          __weAnimationController.fps = \(max(0.0001, fps));
          __weAnimationController._baseFrame = 0;
          __weAnimationController._baseRuntime = engine.runtime;
        }
        """)
    }

    /// 把脚本控制器的当前帧换算成关键帧求值秒数。未绑定时间轴时返回默认全局时间。
    func controlledAnimationTime(defaultTime: Float) -> Float {
        context.setObject(Double(defaultTime), forKeyedSubscript: "__weAnimationDefaultTime" as NSString)
        guard let value = context.evaluateScript("""
        (function(){
          var animation = globalThis.__weAnimationController;
          if (!animation || !(animation.frameCount > 0) || !(animation.fps > 0)) {
            return globalThis.__weAnimationDefaultTime;
          }
          return animation.getFrame() / animation.fps;
        })()
        """), value.isNumber else { return defaultTime }
        let time = value.toDouble()
        return time.isFinite ? Float(time) : defaultTime
    }

    /// 驱动一帧「动态层脚本」(音频条):首帧先跑 init()(建 bars 数组),再每帧跑 update()(按音频
    /// 写各 bar 的 origin/scale/alignment),然后把 thisLayer + 所有 createLayer 出来的 bar 读回。
    /// 返回每根 bar 的变换(含模板层 thisLayer 自身,index 0)。失败/异常 → 返回 nil(调用方回退不画条)。
    /// - 调用方应先 setAudioSpectrum 喂当帧频谱、再调本方法;simTime/dt 透传给 engine.runtime/frametime。
    func runDynamicBars(simTime: Double? = nil, frametime: Double? = nil) -> [DynamicBar]? {
        guard createsLayers, let upd = updateFn else { return nil }
        didFail = false
        tickFrame(initArg: 0, simTime: simTime, frametime: frametime)  // 首帧 init() 建 bars + 跑 intervals
        if didFail { return nil }
        // __barList = [thisLayer, ...__createdLayers](顺序与脚本 bars.push 一致:模板在前,createLayer 在后)。
        // 由原生重建(不依赖脚本是否自行维护),保证引擎读回顺序确定。
        context.evaluateScript("globalThis.__barList = [globalThis.thisLayer].concat(globalThis.__createdLayers || []);")
        _ = upd.call(withArguments: [])   // update() 是 void:就地改各 bar 的 scale/origin/alignment
        if didFail { return nil }
        guard let listVal = context.objectForKeyedSubscript("__barList"),
              listVal.isObject, let arr = listVal.toArray() else { return nil }
        var out: [DynamicBar] = []
        out.reserveCapacity(arr.count)
        for case let item as [String: Any] in arr {
            func vec3(_ key: String, _ d: SIMD3<Float>) -> SIMD3<Float> {
                guard let v = item[key] as? [String: Any] else { return d }
                let x = (v["x"] as? NSNumber)?.floatValue ?? d.x
                let y = (v["y"] as? NSNumber)?.floatValue ?? d.y
                let z = (v["z"] as? NSNumber)?.floatValue ?? d.z
                return SIMD3(x, y, z)
            }
            out.append(DynamicBar(
                origin: vec3("origin", .zero),
                scale: vec3("scale", SIMD3(1, 1, 1)),
                angles: vec3("angles", .zero),
                alignment: (item["alignment"] as? String) ?? "centre"))
        }
        return out.isEmpty ? nil : out
    }

    // MARK: - 音频频谱注入(审计修复 #1:最高优先)

    /// 把引擎采集的音频频谱写进 JSContext 的 __audio16/32/64,让 audio-reactive 脚本(频谱缩放/
    /// 颜色脉动等)拿到真实数据(此前 prelude 全 0、从不填充 → 永远静默)。
    /// 对标 lwe `updateAudioArray`:`average` 是真实频谱,`left`/`right` 暂镜像 average
    /// (PlaybackRecorder 目前只给平均,分声道留待数据源就绪)。
    /// **调用方(SceneRenderEngine 每帧)应在 runString/runVec3 之前调用**,把当帧频谱喂进来;
    /// 不调用则维持 prelude 的全 0(脚本读到静音,行为同旧)。
    /// - Parameters:
    ///   - s16: 16 段频谱(engine.AUDIO_RESOLUTION_16);长度不足按 0 补、超出截断。
    ///   - s32: 32 段频谱。
    ///   - s64: 64 段频谱。
    func setAudioSpectrum(s16: [Float], s32: [Float], s64: [Float]) {
        writeAudioBuffer(name: "__audio16", values: s16, count: 16)
        writeAudioBuffer(name: "__audio32", values: s32, count: 32)
        writeAudioBuffer(name: "__audio64", values: s64, count: 64)
    }

    /// 写一组频谱到 globalThis[name] 的 average/left/right(三者同值,镜像 average,同 lwe)。
    /// 形状与 prelude 一致:`{ average:[count], left:[count], right:[count] }`。
    /// **就地改既有对象的三个通道属性**(而非替换整个对象):脚本通常在 init 里调
    /// engine.registerAudioBuffers(N) 拿到 __audioN 的**引用**并长期持有,若整体替换对象,
    /// 脚本持有的旧引用会变陈旧、读不到新频谱。对标 lwe updateAudioArray 的 setChannel(就地写)。
    private func writeAudioBuffer(name: String, values: [Float], count: Int) {
        // 归一化到固定长度(不足补 0、超出截断),保证 JS 侧数组长度恒等于分辨率。
        var channel = [Double](repeating: 0, count: count)
        for i in 0..<min(count, values.count) {
            let v = values[i]
            channel[i] = v.isFinite ? Double(v) : 0
        }
        // 取既有 __audioN 对象就地改;缺失(理论不会,prelude 已建)则新建后回写全局。
        let audio: JSValue
        if let existing = context.objectForKeyedSubscript(name), existing.isObject {
            audio = existing
        } else {
            guard let fresh = JSValue(newObjectIn: context) else { return }
            audio = fresh
            context.setObject(audio, forKeyedSubscript: name as NSString)
        }
        // left/right 镜像 average(分声道留待数据源就绪,同 lwe)。
        audio.setObject(channel, forKeyedSubscript: "average" as NSString)
        audio.setObject(channel, forKeyedSubscript: "left" as NSString)
        audio.setObject(channel, forKeyedSubscript: "right" as NSString)
    }

    // MARK: - thisScene/thisLayer 真实层绑定(审计修复 #2)

    /// 把完整 scene 对象树注入 __layers 注册表 + __layerList 列表,让 `thisScene.getLayer(name)`
    /// 命中真实层、`thisLayer.getParent()` 返回真实父对象、`enumerateLayers()` 返回真实列表。
    /// 对标 lwe `installSceneLayers`:按 id 与 name 双键登记同一层对象。
    /// **调用方应在场景层就绪后(通常构造脚本实例后、首帧前)调用一次**;层集合变化时可重复调用。
    /// - Parameter layers: 所有 scene 对象的局部属性；无 image 的父容器也必须保留。
    func setSceneLayers(_ layers: [SceneLayerDefinition]) {
        if installedSceneLayerDefs == layers { return }
        installedSceneLayerDefs = layers
        // 把对象定义交给一段 JS 重建注册表 + 列表,层对象在 JS 侧造,getMaterial 等才是
        // 真正可调用的 JS 函数(原生 Swift 闭包 setObject 不会被桥成可调用 JS function)。
        // 用原生注入的 __weLayerDefs 传数据(避免拼字符串/转义问题),由 installLayersSource 消费。
        let defs: [[String: Any]] = layers.map {
            [
                "name": $0.name,
                "id": $0.id,
                "parentId": $0.parentId.map(NSNumber.init(value:)) ?? NSNull(),
                "visible": $0.visible,
                "alpha": Double($0.alpha),
                "color": [Double($0.color.x), Double($0.color.y), Double($0.color.z), Double($0.color.w)],
                "origin": [Double($0.origin.x), Double($0.origin.y), Double($0.origin.z)],
                "scale": [Double($0.scale.x), Double($0.scale.y), Double($0.scale.z)],
                "angles": [Double($0.angles.x), Double($0.angles.y), Double($0.angles.z)],
                "size": [Double($0.size.x), Double($0.size.y)]
            ]
        }
        context.setObject(defs, forKeyedSubscript: "__weLayerDefs" as NSString)
        context.evaluateScript(WEScript.installLayersSource)
        // 跨层写回:installLayersSource 已用 defineProperty 把每个层对象的 visible/alpha/color/origin/
        //   scale/angles 做成「getter 返默认/脚本写过的值、setter 记脏(_v/_al/...)」。脚本经
        //   `thisScene.getLayer(name).visible = false`(Dock 据 enableDock 隐藏图标)写入后,引擎每帧调
        //   readLayerWrites() 读回**仅被脚本写过**的字段、按 id 应用到目标层(见调用方)。
    }

    /// 一层被脚本写过的属性(跨层写回)。只含脚本**确实写过**的字段(其余 nil → 不动目标层)。
    struct LayerWrite {
        var visible: Bool? = nil
        var alpha: Float? = nil
        var color: SIMD3<Float>? = nil
        var origin: SIMD3<Float>? = nil
        var scale: SIMD3<Float>? = nil
        var angles: SIMD3<Float>? = nil
    }

    /// 读回控制器脚本经 `thisScene.getLayer(name).<prop> = …` 写过的属性(跨层写回)。
    /// 返回 id → 该层被写过的属性集(只含脚本动过的字段)。无 getLayer 写入 / 未安装记脏层 → 空 → 零影响。
    /// 调用方(SceneRenderEngine 每帧 runBool 跑完脚本后)据此把 visible/alpha 等应用到目标层。
    func readLayerWrites() -> [Int: LayerWrite] {
        guard usesLayerAPI,
              let s = context.evaluateScript(WEScript.readWritesSource)?.toString(),
              let data = s.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: [String: Any]] else { return [:] }
        var out: [Int: LayerWrite] = [:]
        func vec3(_ a: Any?) -> SIMD3<Float>? {
            guard let arr = a as? [Any], arr.count == 3,
                  let x = (arr[0] as? NSNumber)?.floatValue,
                  let y = (arr[1] as? NSNumber)?.floatValue,
                  let z = (arr[2] as? NSNumber)?.floatValue,
                  x.isFinite, y.isFinite, z.isFinite else { return nil }
            return SIMD3(x, y, z)
        }
        for (k, e) in obj {
            guard let id = Int(k) else { continue }
            var w = LayerWrite()
            if let b = e["v"] as? NSNumber { w.visible = b.boolValue }
            if let a = e["al"] as? NSNumber, a.floatValue.isFinite { w.alpha = a.floatValue }
            w.color = vec3(e["c"])
            w.origin = vec3(e["o"])
            w.scale = vec3(e["s"])
            w.angles = vec3(e["an"])
            if w.visible != nil || w.alpha != nil || w.color != nil || w.origin != nil || w.scale != nil || w.angles != nil {
                out[id] = w
            }
        }
        return out
    }

    /// 是否导出了 applyUserProperties(WE 生命周期:用户在设置里改属性时调用,传 changedUserProperties)。
    private(set) var hasApplyUserProperties: Bool = false

    /// 把「已变化的用户属性」按用户属性名(project.json key,如 'dock')派发给脚本的 applyUserProperties。
    /// WE 真义:scriptProperties 已经过 {user:'dock'} 链接拿到用户的当前值(本引擎在构造时由 unwrap/overrides
    /// 完成注入,故 enableDock 已是 false);applyUserProperties(changed) 让脚本据变化**立即重置/更新**派生状态
    /// (Dock 的 reinitializeCurrentIcons/setAllLayerProperties)。无导出此函数 → no-op(多数脚本在 update 首帧
    /// init 已读 scriptProperties,不依赖此回调)。
    /// - Parameter changedUserNames: 已变化的**用户属性名**(project.json key)集合。空集 → no-op。
    func applyUserProperties(_ changedUserNames: [String]) {
        guard hasApplyUserProperties, !changedUserNames.isEmpty,
              let fn = context.objectForKeyedSubscript("applyUserProperties"), fn.isObject else { return }
        // changedUserProperties:WE 传 {userName: value} 形;脚本(Dock)只用 hasOwnProperty(name)/startsWith('show_'),
        // 不读 value → 这里传值为 true 的占位对象即可触发其 needsReset/needsIconVisibilityUpdate 分支。
        var changed: [String: Any] = [:]
        for n in changedUserNames { changed[n] = true }
        _ = fn.call(withArguments: [changed])
    }

    // MARK: - 媒体事件派发(审计修复 #3)

    /// 据已声明的 MediaPlaybackEvent 常量,向脚本派发 now-playing 事件:
    ///   - title/artist 变化 → mediaPropertiesChanged({ title, artist, albumTitle })
    ///   - position/duration 变化 → mediaTimelineChanged({ position, duration })
    /// 对标 lwe `dispatchMediaEvents`:用签名去重,仅在变化时再触发脚本回调(避免每帧重复)。
    /// 时间用秒(脚本侧自行 formatMediaTime);歌名/歌手不在此截断(lwe 的 fallbackTextValue
    /// 截断属「脚本失败时的兜底文本」,这里走的是脚本回调真实路径,原样传)。
    /// **now-playing 真实数据源由调用方接入并每帧/变化时调用本方法**;脚本未注册对应回调则 no-op。
    /// - Parameters:
    ///   - title: 曲目标题(nil 视为空串)。
    ///   - artist: 艺人(nil 视为空串)。
    ///   - positionSec: 当前播放位置(秒,nil 视为 0)。
    ///   - lengthSec: 总时长(秒,nil 视为 0)。
    func dispatchMediaState(title: String?, artist: String?, positionSec: Double?, lengthSec: Double?,
                            playbackState: Int? = nil, thumbnailRevision: Int? = nil,
                            thumbnailPalette: NowPlayingProvider.ThumbnailPalette? = nil) {
        guard usesMediaEvents else { return }
        pendingMediaState = MediaState(
            title: title ?? "",
            artist: artist ?? "",
            position: positionSec ?? 0,
            duration: lengthSec ?? 0,
            playbackState: playbackState,
            thumbnailRevision: thumbnailRevision,
            thumbnailPalette: thumbnailPalette
        )
    }

    /// 在 init 完成后派发最新媒体快照。签名去重与 lwe 一致，调用方可每帧写入而不重复触发。
    private func dispatchPendingMediaState() {
        guard let state = pendingMediaState else { return }
        // 1) properties:title+artist 变化时派发(同 lwe propertiesSignature = title\nartist)。
        if let fn = mediaPropertiesChangedFn {
            let sig = state.title + "\n" + state.artist
            if lastMediaPropertiesSig != sig {
                lastMediaPropertiesSig = sig
                let event: [String: Any] = [
                    "title": state.title,
                    "artist": state.artist,
                    "albumTitle": ""
                ]
                _ = fn.call(withArguments: [event])
            }
        }

        // 2) timeline:position(取整秒)+duration 变化时派发(同 lwe timelineSignature)。
        if let fn = mediaTimelineChangedFn {
            let sig = "\(Int(max(0, state.position)))\n\(state.duration)"
            if lastMediaTimelineSig != sig {
                lastMediaTimelineSig = sig
                let event: [String: Any] = ["position": state.position, "duration": state.duration]
                _ = fn.call(withArguments: [event])
            }
        }

        // 3) playback:0 stopped / 1 playing / 2 paused。数据源是系统 MediaRemote，
        //    无系统会话时回退壁纸 AudioPlayback 的真实状态。
        if let fn = mediaPlaybackChangedFn, let playback = state.playbackState {
            let sig = String(playback)
            if lastMediaPlaybackSig != sig {
                lastMediaPlaybackSig = sig
                _ = fn.call(withArguments: [["state": playback]])
            }
        }

        // 4) thumbnail:只按封面内容 revision 派发，不因同封面的曲目/时间线变化而重复触发。
        // 颜色全部是 Vec3（官方 MediaThumbnailEvent 类型），不能用 Swift 字典冒充，否则脚本的
        // subtract/multiply/add 等 Vec3 方法会在回调后续 update 中失败。
        if let fn = mediaThumbnailChangedFn,
           let revision = state.thumbnailRevision,
           let palette = state.thumbnailPalette {
            let sig = String(revision)
            if lastMediaThumbnailSig != sig {
                lastMediaThumbnailSig = sig
                context.setObject([
                    Double(palette.primaryColor.x), Double(palette.primaryColor.y), Double(palette.primaryColor.z),
                    Double(palette.secondaryColor.x), Double(palette.secondaryColor.y), Double(palette.secondaryColor.z),
                    Double(palette.tertiaryColor.x), Double(palette.tertiaryColor.y), Double(palette.tertiaryColor.z),
                    Double(palette.textColor.x), Double(palette.textColor.y), Double(palette.textColor.z),
                    Double(palette.highContrastColor.x), Double(palette.highContrastColor.y),
                    Double(palette.highContrastColor.z)
                ], forKeyedSubscript: "__weMediaThumbnailColors" as NSString)
                context.setObject(palette.hasThumbnail,
                                  forKeyedSubscript: "__weMediaHasThumbnail" as NSString)
                let event = context.evaluateScript("""
                (function(){
                  var c = globalThis.__weMediaThumbnailColors;
                  return {
                    hasThumbnail: !!globalThis.__weMediaHasThumbnail,
                    primaryColor: new Vec3(c[0], c[1], c[2]),
                    secondaryColor: new Vec3(c[3], c[4], c[5]),
                    tertiaryColor: new Vec3(c[6], c[7], c[8]),
                    textColor: new Vec3(c[9], c[10], c[11]),
                    highContrastColor: new Vec3(c[12], c[13], c[14])
                  };
                })()
                """)
                if let event { _ = fn.call(withArguments: [event]) }
            }
        }
    }

    // MARK: - 生命周期 / 每帧刷新

    /// 每次 update() 前调:1) 刷新 engine.runtime/frametime/timeOfDay(对标 WE updateRuntimeGlobals);
    /// 2) 首帧调一次脚本的 init(value)(若有,传入当前值);3) 跑已注册的 setInterval 回调(__weRunIntervals)。
    /// 顺序与 WE 一致:先有 runtime,再 init,再 intervals(intervals 判定要用到 engine.runtime)。
    /// initArg:首帧 init() 的入参(WE 的 init(value) 拿当前属性值;矢量脚本传 Vec3 对象、文本脚本传字符串)。
    /// 审计修复(#1):新增可选 simTime/frametime 参数作为时间源,用引擎传入的 sim 时间(time/dt)而非墙钟 Date(),
    ///   让脚本动画与引擎 sim-time 同步、无头渲染确定。**上层(SceneRenderEngine 的 runString/runVec3 调用方)
    ///   应把引擎 sim time/dt 传进来**;为不破坏现有调用方编译,simTime/frametime 默认 nil 时仍回退旧行为。
    ///   - frametime:本帧 sim dt(秒,对标 lwe `g_Time - g_TimeLast`)。优先直接用它当 engine.frametime
    ///     (音频平滑 `value += delta*min(1,frametime*smoothing)` 等脚本依赖真实帧间隔);未提供时回退 runtime 差近似。
    private func tickFrame(initArg: Any, simTime: Double? = nil, frametime: Double? = nil) {
        // 1) runtime/frametime/timeOfDay。
        //    lwe(EngineObject.cpp:27):engine.runtime = 全局 g_Time(引擎启动以来总时间),**所有脚本共享同一时钟**,
        //    不是各自从 0 起(之前的 simTime - startSimTime 偏移是自创,会让多脚本相位不同步、与 effect 链 g_Time 不同源)。
        //    故 runtime 直接 = 传入的引擎 sim time;未提供 sim time 时回退墙钟(仅兜底)。
        let runtime: Double = simTime ?? Date().timeIntervalSince(startTime)
        // frametime:优先用引擎传入的本帧真实 dt(对标 lwe g_Time - g_TimeLast,EngineObject.cpp:23);否则用 runtime 差近似。
        let frame = max(0, frametime ?? (runtime - lastRuntime))
        lastRuntime = runtime
        if let engine = context.objectForKeyedSubscript("engine"), engine.isObject {
            engine.setObject(runtime, forKeyedSubscript: "runtime" as NSString)
            engine.setObject(frame, forKeyedSubscript: "frametime" as NSString)
            // timeOfDay:lwe(EngineObject.cpp:31)= g_Daytime;WallpaperApplication.cpp:870 g_Daytime = (tm_hour*60 + tm_min)/(24*60)
            // —— **分钟粒度、不含秒**,且与 effect 链的 g_Daytime 同公式。之前含秒的 /86400 是自创偏差。
            let c = Calendar.current.dateComponents([.hour, .minute], from: Date())
            let dayMinutes = Double((c.hour ?? 0) * 60 + (c.minute ?? 0))
            engine.setObject(dayMinutes / 1440.0, forKeyedSubscript: "timeOfDay" as NSString)
        }
        // 2) 首帧 init(value)(WE 生命周期:layer 首次 tick 前调 _init 一次,传入当前属性值)。
        //    传当前值是关键:scale 脚本(如「主三角」音频缩放)init(value){ initialValue = value.x }——
        //    空参调用会让 value undefined → value.x 抛 TypeError → initialValue=NaN → update 全崩(噪声根因)。
        if !didInit {
            didInit = true
            if let initF = initFn {
                _ = initF.call(withArguments: [initArg])   // 抛错由 exceptionHandler 记录;不阻断后续 update
            }
        }
        // 2b) WE 在对象 init 后派媒体事件；事件可直接改 thisLayer.visible/alpha/text。
        dispatchPendingMediaState()
        // 3) 跑 intervals(注册在默认 bucket;回调到点才触发)。纯 JS,缺失则 no-op。
        if let runIntervals = context.objectForKeyedSubscript("__weRunIntervals"),
           runIntervals.isObject {
            _ = runIntervals.call(withArguments: [])
        }
    }

    // MARK: - module 语法剥离

    /// 去掉 ES module 语法,让脚本体可被 JSC 当普通脚本 eval:
    ///   - `export let __workshopId = '…';` 整行删除(否则 export 语法报错,且无意义)
    ///   - 行首 `import …` 删除(资源引用,本地无对应)
    ///   - `export var/let/const/function …` → 去掉 `export ` 前缀,声明保留为全局
    ///   - 余下 `export ` 关键字一律去掉
    /// 注意只动 module 关键字,不碰函数体逻辑。
    static func stripModuleSyntax(_ src: String) -> String {
        var out: [String] = []
        for rawLine in src.components(separatedBy: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            // __workshopId 行(可能 export let / let / export var）：整行删。
            if trimmed.contains("__workshopId") { continue }
            // import 行删。
            if trimmed.hasPrefix("import ") || trimmed.hasPrefix("import(") { continue }
            var line = rawLine
            // 去行首 export 前缀(保留缩进),只匹配以 export 开头的声明,避免误伤字符串内 "export"。
            if let r = line.range(of: #"^(\s*)export\s+"#, options: .regularExpression) {
                let leading = line.prefix(while: { $0 == " " || $0 == "\t" })
                line.replaceSubrange(r, with: String(leading))
            }
            out.append(line)
        }
        return out.joined(separator: "\n")
    }

    // MARK: - WE prelude(运行时全局)

    /// WE 脚本运行时全局 prelude(对标 linux-wallpaperengine ScriptEngine::installBuiltins）。
    /// 全是标准 JS,JSC 全支持。在每个脚本 eval **前**注入,补回 stripModuleSyntax 删掉的 import
    /// (WEMath/WEColor/Vec* 等),并提供 console no-op / localStorage / input / engine /
    /// thisLayer / thisScene 桩,让复杂脚本不再因缺全局抛错回退。engine.runtime/frametime/
    /// timeOfDay 由 Swift 每帧(tickFrame)刷新;setInterval 注册的回调由 __weRunIntervals 每帧跑。
    /// 注意:这里**不**定义 createScriptProperties(由下面的 shimSource 定义,带 __wePropOverrides 覆盖)。
    static let preludeSource = """
    globalThis.__weNum = function(v, fallback) {
      var n = parseFloat(v);
      return Number.isFinite(n) ? n : fallback;
    };
    globalThis.__weParts = function(v) {
      if (typeof v === 'string') return v.trim().split(/\\s+/).map(Number);
      if (typeof v === 'number') return [v, v, v, v];
      if (v && typeof v === 'object') return [v.x || 0, v.y || 0, v.z || 0, v.w || 0];
      return [0, 0, 0, 0];
    };
    globalThis.Vec2 = class Vec2 {
      constructor(x, y) { var p = __weParts(x); this.x = __weNum(x, p[0] || 0); this.y = __weNum(y, p[1] || 0); }
      copy() { return new Vec2(this.x, this.y); }
      lengthSqr() { return this.x * this.x + this.y * this.y; }
      length() { return Math.sqrt(this.lengthSqr()); }
      normalize() { var l = this.length(); return l ? this.divide(l) : new Vec2(0, 0); }
      add(v) { var p = __weParts(v); return new Vec2(this.x + p[0], this.y + p[1]); }
      subtract(v) { var p = __weParts(v); return new Vec2(this.x - p[0], this.y - p[1]); }
      multiply(v) { var p = __weParts(v); return new Vec2(this.x * p[0], this.y * p[1]); }
      divide(v) { var p = __weParts(v); return new Vec2(this.x / p[0], this.y / p[1]); }
      dot(v) { return this.x * v.x + this.y * v.y; }
      mix(v, a) { return new Vec2(this.x + (v.x - this.x) * a, this.y + (v.y - this.y) * a); }
      toString() { return this.x + ' ' + this.y; }
    };
    globalThis.Vec3 = class Vec3 {
      constructor(x, y, z) { var p = __weParts(x); this.x = __weNum(x, p[0] || 0); this.y = __weNum(y, p[1] || 0); this.z = __weNum(z, p[2] || 0); }
      copy() { return new Vec3(this.x, this.y, this.z); }
      equals(v) { return Math.abs(this.x - v.x) < 0.0001 && Math.abs(this.y - v.y) < 0.0001 && Math.abs(this.z - v.z) < 0.0001; }
      lengthSqr() { return this.x * this.x + this.y * this.y + this.z * this.z; }
      length() { return Math.sqrt(this.lengthSqr()); }
      normalize() { var l = this.length(); return l ? this.divide(l) : new Vec3(0, 0, 0); }
      add(v) { var p = __weParts(v); return new Vec3(this.x + p[0], this.y + p[1], this.z + p[2]); }
      subtract(v) { var p = __weParts(v); return new Vec3(this.x - p[0], this.y - p[1], this.z - p[2]); }
      multiply(v) { var p = __weParts(v); return new Vec3(this.x * p[0], this.y * p[1], this.z * p[2]); }
      divide(v) { var p = __weParts(v); return new Vec3(this.x / p[0], this.y / p[1], this.z / p[2]); }
      dot(v) { return this.x * v.x + this.y * v.y + this.z * v.z; }
      cross(v) { return new Vec3(this.y * v.z - this.z * v.y, this.z * v.x - this.x * v.z, this.x * v.y - this.y * v.x); }
      mix(v, a) { return new Vec3(this.x + (v.x - this.x) * a, this.y + (v.y - this.y) * a, this.z + (v.z - this.z) * a); }
      min(v) { return new Vec3(Math.min(this.x, v.x), Math.min(this.y, v.y), Math.min(this.z, v.z)); }
      max(v) { return new Vec3(Math.max(this.x, v.x), Math.max(this.y, v.y), Math.max(this.z, v.z)); }
      abs() { return new Vec3(Math.abs(this.x), Math.abs(this.y), Math.abs(this.z)); }
      sign() { return new Vec3(Math.sign(this.x), Math.sign(this.y), Math.sign(this.z)); }
      round() { return new Vec3(Math.round(this.x), Math.round(this.y), Math.round(this.z)); }
      floor() { return new Vec3(Math.floor(this.x), Math.floor(this.y), Math.floor(this.z)); }
      ceil() { return new Vec3(Math.ceil(this.x), Math.ceil(this.y), Math.ceil(this.z)); }
      toString() { return this.x + ' ' + this.y + ' ' + this.z; }
    };
    globalThis.Vec4 = class Vec4 {
      constructor(x, y, z, w) { var p = __weParts(x); this.x = __weNum(x, p[0] || 0); this.y = __weNum(y, p[1] || 0); this.z = __weNum(z, p[2] || 0); this.w = __weNum(w, p[3] || 0); }
      copy() { return new Vec4(this.x, this.y, this.z, this.w); }
      toString() { return this.x + ' ' + this.y + ' ' + this.z + ' ' + this.w; }
    };
    // WE Matrix4 至少以 column-major `m[12...14]` 暴露世界平移。场景脚本用它判断组件位于
    // 画布哪一侧；这里按当前父链的局部 origin/scale/angles 动态合成，跨层脚本改值后也立即生效。
    globalThis.__weWorldTransform = function(layer, seen) {
      if (!layer) return { origin: new Vec3(0, 0, 0), scale: new Vec3(1, 1, 1), angle: 0 };
      seen = seen || Object.create(null);
      var key = String(layer.id);
      if (seen[key]) return { origin: layer.origin.copy(), scale: layer.scale.copy(), angle: layer.angles.z || 0 };
      seen[key] = true;
      var parent = typeof layer.getParent === 'function' ? layer.getParent() : null;
      var lo = layer.origin, ls = layer.scale, la = layer.angles;
      if (!parent) return { origin: lo.copy(), scale: ls.copy(), angle: Number(la.z) || 0 };
      var p = __weWorldTransform(parent, seen);
      var x = p.scale.x * lo.x, y = p.scale.y * lo.y;
      var c = Math.cos(p.angle), s = Math.sin(p.angle);
      return {
        origin: new Vec3(p.origin.x + c * x - s * y, p.origin.y + s * x + c * y,
                         p.origin.z + p.scale.z * lo.z),
        scale: new Vec3(p.scale.x * ls.x, p.scale.y * ls.y, p.scale.z * ls.z),
        angle: p.angle + (Number(la.z) || 0)
      };
    };
    globalThis.__weGetTransformMatrix = function(layer) {
      var t = __weWorldTransform(layer), c = Math.cos(t.angle), s = Math.sin(t.angle);
      return { m: [
        c * t.scale.x, s * t.scale.x, 0, 0,
        -s * t.scale.y, c * t.scale.y, 0, 0,
        0, 0, t.scale.z, 0,
        t.origin.x, t.origin.y, t.origin.z, 1
      ] };
    };
    // 图层脚本期望从 thisLayer 取得控制对象。当前 VideoTexture 仍由宿主连续播放，
    // 因此这里只提供不抛异常的兼容控制面；真实剪辑/暂停/倍速仍由审计列为缺口。
    globalThis.__weVideoStub = {
      duration: 1e9, rate: 1,
      isPlaying: function(){ return 1; },
      play: function(){}, pause: function(){}, stop: function(){},
      setRate: function(v){ this.rate = Number(v) || 0; },
      setCurrentTime: function(){}, getCurrentTime: function(){ return 0; }
    };
    globalThis.__weAnimationStub = {
      pause: function(){}, play: function(){}, stop: function(){},
      setFrame: function(){}, getFrame: function(){ return 0; },
      frameCount: 0, rate: 1
    };
    globalThis.__weAnimationController = {
      frameCount: 0, fps: 30,
      _rate: 1, _playing: true, _baseFrame: 0, _baseRuntime: 0,
      _sync: function() {
        if (this._playing) {
          this._baseFrame += (engine.runtime - this._baseRuntime) * this.fps * this._rate;
          this._baseRuntime = engine.runtime;
        }
      },
      get rate() { return this._rate; },
      set rate(value) {
        this._sync();
        var next = Number(value);
        this._rate = Number.isFinite(next) ? next : 1;
      },
      play: function() {
        this._sync();
        this._playing = true;
        this._baseRuntime = engine.runtime;
      },
      pause: function() {
        this._sync();
        this._playing = false;
      },
      stop: function() {
        this._playing = false;
        this._baseFrame = 0;
        this._baseRuntime = engine.runtime;
      },
      setFrame: function(frame) {
        var next = Number(frame);
        this._baseFrame = Number.isFinite(next) ? next : 0;
        this._baseRuntime = engine.runtime;
      },
      getFrame: function() {
        this._sync();
        return this._baseFrame;
      }
    };
    globalThis.thisObject = globalThis.thisObject || {
      getAnimation: function(){ return globalThis.__weAnimationController; }
    };
    globalThis.WEColor = {
      rgb2hsv(c) {
        var r = c.x, g = c.y, b = c.z, max = Math.max(r, g, b), min = Math.min(r, g, b), d = max - min;
        var h = 0;
        if (d !== 0) h = max === r ? (((g - b) / d) % 6) : max === g ? ((b - r) / d + 2) : ((r - g) / d + 4);
        h = ((h / 6) + 1) % 1;
        return new Vec3(h, max === 0 ? 0 : d / max, max);
      },
      hsv2rgb(c) {
        var h = ((c.x % 1) + 1) % 1, s = c.y, v = c.z, i = Math.floor(h * 6), f = h * 6 - i;
        var p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s);
        switch (i % 6) { case 0: return new Vec3(v, t, p); case 1: return new Vec3(q, v, p); case 2: return new Vec3(p, v, t); case 3: return new Vec3(p, q, v); case 4: return new Vec3(t, p, v); default: return new Vec3(v, p, q); }
      }
    };
    globalThis.WEMath = {
      smoothStep(edge0, edge1, x) {
        edge0 = Number(edge0); edge1 = Number(edge1); x = Number(x);
        if (!Number.isFinite(edge0) || !Number.isFinite(edge1) || !Number.isFinite(x)) return 0;
        if (edge0 === edge1) return x < edge0 ? 0 : 1;
        var t = Math.max(0, Math.min(1, (x - edge0) / (edge1 - edge0)));
        return t * t * (3 - 2 * t);
      },
      smootherStep(edge0, edge1, x) {
        edge0 = Number(edge0); edge1 = Number(edge1); x = Number(x);
        if (!Number.isFinite(edge0) || !Number.isFinite(edge1) || !Number.isFinite(x)) return 0;
        if (edge0 === edge1) return x < edge0 ? 0 : 1;
        var t = Math.max(0, Math.min(1, (x - edge0) / (edge1 - edge0)));
        return t * t * t * (t * (t * 6 - 15) + 10);
      },
      clamp(x, min, max) {
        x = Number(x); min = Number(min); max = Number(max);
        if (!Number.isFinite(x)) return 0;
        return Math.max(min, Math.min(max, x));
      },
      saturate(x) {
        x = Number(x);
        if (!Number.isFinite(x)) return 0;
        return Math.max(0, Math.min(1, x));
      },
      mix(a, b, t) {
        a = Number(a); b = Number(b); t = Number(t);
        if (!Number.isFinite(a) || !Number.isFinite(b) || !Number.isFinite(t)) return 0;
        return a + (b - a) * t;
      },
      lerp(a, b, t) {
        a = Number(a); b = Number(b); t = Number(t);
        if (!Number.isFinite(a) || !Number.isFinite(b) || !Number.isFinite(t)) return 0;
        return a + (b - a) * t;
      }
    };
    globalThis.__audio16 = { average: Array(16).fill(0), left: Array(16).fill(0), right: Array(16).fill(0) };
    globalThis.__audio32 = { average: Array(32).fill(0), left: Array(32).fill(0), right: Array(32).fill(0) };
    globalThis.__audio64 = { average: Array(64).fill(0), left: Array(64).fill(0), right: Array(64).fill(0) };
    globalThis.__intervals = [];
    globalThis.__timeouts = [];
    globalThis.shared = globalThis.shared || {};
    globalThis.localStorage = globalThis.localStorage || {
      __data: Object.create(null),
      getItem(key) { key = String(key); return Object.prototype.hasOwnProperty.call(this.__data, key) ? this.__data[key] : null; },
      setItem(key, value) { this.__data[String(key)] = String(value); },
      get(key) { return this.getItem(key); },
      set(key, value) { this.setItem(key, value); },
      removeItem(key) { delete this.__data[String(key)]; },
      remove(key) { delete this.__data[String(key)]; },
      clear() { this.__data = Object.create(null); }
    };
    globalThis.MediaPlaybackEvent = globalThis.MediaPlaybackEvent || {
      PLAYBACK_STOPPED: 0, PLAYBACK_PLAYING: 1, PLAYBACK_PAUSED: 2
    };
    globalThis.input = globalThis.input || {
      cursorPosition: new Vec2(0, 0),
      // cursorScreenPosition:WE 提供的「光标在屏幕的归一化位置 [0,1]」(土星 Dock 主控读它算触发区:
      //   `3840 * input.cursorScreenPosition.x / engine.screenResolution.x`)。缺它则 Dock update() 读
      //   `cursorScreenPosition.x` 抛 TypeError → 整段 update 中断 → 图标显隐永不更新(任务栏关不掉)。
      //   headless 无真实光标 → 给 (0,0) 合理桩(光标在左上角,远离 Dock → isMouseInZone=false,Dock 不悬停)。
      cursorScreenPosition: new Vec2(0, 0),
      cursorWorldPosition: new Vec3(0, 0, 0)
    };
    globalThis.console = globalThis.console || {
      log() {}, warn() {}, error() {}, info() {}, debug() {}
    };
    globalThis.__weRunIntervals = function() {
      var list = globalThis.__intervals;
      for (var i = 0; i < list.length; i++) {
        var interval = list[i];
        if (!interval.active || typeof interval.callback !== 'function') continue;
        if (engine.runtime < interval.next) continue;
        interval.next = engine.runtime + interval.delay;
        interval.callback();
      }
      var timeouts = globalThis.__timeouts;
      for (var j = 0; j < timeouts.length; j++) {
        var timeout = timeouts[j];
        if (!timeout.active || typeof timeout.callback !== 'function') continue;
        if (engine.runtime < timeout.next) continue;
        timeout.active = false;
        timeout.callback();
      }
      if (timeouts.length > 128) {
        globalThis.__timeouts = timeouts.filter(function(timeout) { return timeout.active; });
      }
    };
    globalThis.engine = {
      runtime: 0,
      frametime: 0,
      timeOfDay: 0,
      canvasSize: { x: 1920, y: 1080 },
      mouseSize: { x: 64, y: 64 },
      AUDIO_RESOLUTION_16: 16,
      AUDIO_RESOLUTION_32: 32,
      AUDIO_RESOLUTION_64: 64,
      registerAudioBuffers(resolution) {
        if (resolution === 64) return globalThis.__audio64;
        if (resolution === 32) return globalThis.__audio32;
        return globalThis.__audio16;
      },
      setInterval(callback, delayMs) {
        var d = Math.max(0.001, Number(delayMs || 0) / 1000);
        var interval = { callback: callback, delay: d, next: this.runtime + d, active: true };
        globalThis.__intervals.push(interval);
        return function() { interval.active = false; };
      },
      setTimeout(callback, delayMs) {
        var d = Math.max(0, Number(delayMs || 0) / 1000);
        var timeout = { callback: callback, next: this.runtime + d, active: true };
        globalThis.__timeouts.push(timeout);
        return function() { timeout.active = false; };
      },
      openUserShortcut() { return undefined; }
    };
    globalThis.__missingLayer = {
      id: -1, _parentId: null, text: '', name: '', visible: false, alpha: 0,
      origin: new Vec3(0, 0, 0), scale: new Vec3(1, 1, 1), angles: new Vec3(0, 0, 0),
      color: new Vec4(0, 0, 0, 0), parallaxDepth: new Vec2(0, 0), size: new Vec2(0, 0),
      getParent() { return null; },
      getTransformMatrix() { return __weGetTransformMatrix(this); },
      getAnimation() { return __weAnimationStub; },
      getVideoTexture() { return __weVideoStub; },
      getTextureAnimation() { return __weAnimationStub; },
      getMaterial() { return null; }
    };
    globalThis.thisLayer = globalThis.thisLayer || {
      id: -1, _parentId: null, text: '', name: '', visible: true, alpha: 1,
      origin: new Vec3(0, 0, 0), scale: new Vec3(1, 1, 1), angles: new Vec3(0, 0, 0),
      color: new Vec4(1, 1, 1, 1), parallaxDepth: new Vec2(0, 0),
      _size: new Vec2(0, 0),
      // WE 的原生 size getter 返回一个向量值。官方拖拽/反弹脚本会先取
      // `imageSize = thisLayer.size` 再原地乘 scale；若这里返回持久对象，图层尺寸会每帧
      // 被再次缩小。返回 copy 才与 WE 的值语义一致。
      get size() { return this._size.copy(); },
      set size(v) { this._size = new Vec2(v && v.x, v && v.y); },
      getParent() {
        if (this._parentId === null || this._parentId === undefined) return null;
        var key = String(this._parentId);
        return globalThis.__layers && globalThis.__layers[key] ? globalThis.__layers[key] : null;
      },
      getTransformMatrix() { return __weGetTransformMatrix(this); },
      getAnimation() { return __weAnimationController; },
      getVideoTexture() { return __weVideoStub; },
      getTextureAnimation() { return __weAnimationStub; },
      getMaterial() { return null; }
    };
    // 运行时动态建层:音频条脚本 init() 调 thisScene.createLayer 建 N 根 bar、getLayerIndex 取基准、
    // sortLayer 排序。本引擎把这些 bar 当「同一模型的多实例」渲染(见 SceneRenderEngine 多实例路径),
    // 故此处只需让脚本能建对象、读写其 origin/scale/angles/alignment,并把它们登记进 __barList 供 Swift 读回。
    globalThis.__createdLayers = [];   // createLayer 出来的对象(不含模板 thisLayer)
    globalThis.__barList = [];         // 引擎读回用:模板 thisLayer + 所有 createLayer 对象,按脚本 push 顺序
    globalThis.__makeDynamicLayer = function(modelPath) {
      // 与 thisLayer 同构的可读写层对象。脚本会写 origin/scale/angles/alignment;引擎读回这些。
      return {
        name: '', model: String(modelPath || ''),
        visible: true, alpha: 1, text: '',
        origin: new Vec3(0, 0, 0), scale: new Vec3(1, 1, 1), angles: new Vec3(0, 0, 0),
        color: new Vec4(1, 1, 1, 1), parallaxDepth: new Vec2(0, 0), size: new Vec2(0, 0),
        alignment: 'centre',
        getMaterial: function() { return null; }
      };
    };
    globalThis.thisScene = globalThis.thisScene || {
      getLayer(name) { return globalThis.__missingLayer; },
      enumerateLayers() { return []; },
      // 模板层 thisLayer 的索引基准。脚本只用其相对关系(getLayerIndex→sortLayer),返回稳定占位即可。
      getLayerIndex(layer) { return 0; },
      createLayer(modelPath) {
        var obj = globalThis.__makeDynamicLayer(modelPath);
        globalThis.__createdLayers.push(obj);
        return obj;
      },
      // 把动态层排到 index 处。本引擎按 __barList 顺序统一画 bar,排序无额外语义 → no-op。
      sortLayer(layer, index) {},
      removeLayer(layer) {}
    };
    """

    // MARK: - createScriptProperties shim

    /// 纯 JS 实现的 createScriptProperties():链式 addCheckbox/addSlider/addText/addColor/addCombo,
    /// finish() 返回一个对象,每个 name → 其值。值优先取 __wePropOverrides[name](图层/用户覆盖),
    /// 否则取该 addX 调用里的 value(脚本默认)。
    static let shimSource = """
    var createScriptProperties = function() {
        var defs = {};
        var add = function(o) { if (o && o.name !== undefined) defs[o.name] = o.value; return builder; };
        var builder = {
            addCheckbox: add, addSlider: add, addText: add,
            addColor: add, addCombo: add, addTextInput: add,
            finish: function() {
                var out = {};
                for (var k in defs) {
                    if (typeof __wePropOverrides !== 'undefined' && __wePropOverrides &&
                        Object.prototype.hasOwnProperty.call(__wePropOverrides, k)) {
                        out[k] = __wePropOverrides[k];
                    } else {
                        out[k] = defs[k];
                    }
                }
                return out;
            }
        };
        return builder;
    };
    """

    // MARK: - 场景层安装(setSceneLayers 用)

    /// 消费原生注入的 __weLayerDefs,重建 __layers(name→obj、id→obj 双键)+
    /// __layerList(有序),并把 thisScene.getLayer/enumerateLayers 指向它们(覆盖 prelude 死桩)。
    /// 层对象在 JS 侧构造,getMaterial 是真正的 JS 函数;属性与 thisLayer/__missingLayer 同构,
    /// 脚本读 name/id/origin/scale/... 均不抛错。对标 lwe installSceneLayers 的双键登记。
    ///
    /// 跨层写回:visible/alpha/color/origin/scale/angles 用 defineProperty 记脏(_v/_al/_c/_o/_s/_an),
    ///   getter 返当前值(默认或脚本写过的)、setter 记脏 → readLayerWrites() 只读回脚本写过的字段。
    ///   play()/pause()/getVideoTexture()/getTextureAnimation() 给 no-op 桩(Dock 图标的点击/悬停音效层
    ///   `getLayer("v1").play()` 不抛错;播放真由引擎控)。
    private static let installLayersSource = """
    (function() {
      var defs = globalThis.__weLayerDefs || [];
      var layers = {};
      var list = [];
      function vec(a, n, fallback) {
        var out = [];
        for (var i = 0; i < n; i++) {
          var value = a && a.length > i ? Number(a[i]) : fallback[i];
          out.push(Number.isFinite(value) ? value : fallback[i]);
        }
        return out;
      }
      function mk(d) {
        var c = vec(d.color, 4, [1, 1, 1, 1]);
        var o3 = vec(d.origin, 3, [0, 0, 0]);
        var s3 = vec(d.scale, 3, [1, 1, 1]);
        var a3 = vec(d.angles, 3, [0, 0, 0]);
        var sz = vec(d.size, 2, [0, 0]);
        var o = { id: d.id, name: String(d.name || ''), text: '',
                  _parentId: d.parentId === null || d.parentId === undefined ? null : Number(d.parentId),
                  _v: null, _al: null, _c: null, _o: null, _s: null, _an: null,
                  _baseVisible: d.visible !== false, _baseAlpha: Number(d.alpha),
                  _baseColor: new Vec4(c[0], c[1], c[2], c[3]),
                  _baseOrigin: new Vec3(o3[0], o3[1], o3[2]),
                  _baseScale: new Vec3(s3[0], s3[1], s3[2]),
                  _baseAngles: new Vec3(a3[0], a3[1], a3[2]),
                  size: new Vec2(sz[0], sz[1]),
                  parallaxDepth: new Vec2(0, 0),
                  getParent: function(){
                    if (this._parentId === null || this._parentId === undefined) return null;
                    var key = String(this._parentId);
                    return globalThis.__layers && globalThis.__layers[key] ? globalThis.__layers[key] : null;
                  },
                  getTransformMatrix: function(){ return __weGetTransformMatrix(this); },
                  getAnimation: function(){ return __weAnimationStub; },
                  getMaterial: function(){ return null; },
                  getVideoTexture: function(){ return __weVideoStub; },
                  getTextureAnimation: function(){ return __weAnimationStub; },
                  play: function(){}, pause: function(){}, stop: function(){} };
        if (!Number.isFinite(o._baseAlpha)) o._baseAlpha = 1;
        Object.defineProperty(o, 'visible', { get: function(){ return this._v === null ? this._baseVisible : this._v; }, set: function(v){ this._v = !!v; }, configurable: true, enumerable: true });
        Object.defineProperty(o, 'alpha',   { get: function(){ return this._al === null ? this._baseAlpha : this._al; }, set: function(v){ this._al = +v; }, configurable: true, enumerable: true });
        Object.defineProperty(o, 'color',   { get: function(){ return this._c || this._baseColor.copy(); }, set: function(v){ this._c = v; }, configurable: true, enumerable: true });
        Object.defineProperty(o, 'origin',  { get: function(){ return this._o || this._baseOrigin.copy(); }, set: function(v){ this._o = v; }, configurable: true, enumerable: true });
        Object.defineProperty(o, 'scale',   { get: function(){ return this._s || this._baseScale.copy(); }, set: function(v){ this._s = v; }, configurable: true, enumerable: true });
        Object.defineProperty(o, 'angles',  { get: function(){ return this._an || this._baseAngles.copy(); }, set: function(v){ this._an = v; }, configurable: true, enumerable: true });
        return o;
      }
      for (var i = 0; i < defs.length; i++) {
        var d = defs[i] || {};
        var obj = mk(d);
        layers[String(d.id)] = obj;          // id 键(字符串化,同 lwe std::to_string(id))
        if (obj.name) layers[obj.name] = obj; // name 键(非空时)
        list.push(obj);
      }
      globalThis.__layers = layers;
      globalThis.__layerList = list;
      if (!globalThis.thisScene) globalThis.thisScene = {};
      globalThis.thisScene.getLayer = function(name) {
        var key = String(name);
        return (globalThis.__layers && globalThis.__layers[key]) ? globalThis.__layers[key] : globalThis.__missingLayer;
      };
      globalThis.thisScene.enumerateLayers = function() {
        return globalThis.__layerList || [];
      };
      // 真实层列表里查 layer 的索引(按对象引用,回退按 id);找不到返回 0(脚本只用相对关系)。
      globalThis.thisScene.getLayerIndex = function(layer) {
        var l = globalThis.__layerList || [];
        for (var i = 0; i < l.length; i++) {
          if (l[i] === layer || (layer && l[i] && l[i].id === layer.id)) return i;
        }
        return 0;
      };
    })();
    """

    /// 读回**仅被脚本写过**的层属性(跨层写回):遍历 __layers,导出脏字段。Swift 侧按 id 应用到目标层。
    /// 每 id 去重(name 键与 id 键指向同一对象)。无 __layers / 无写入 → 返回 {} → 引擎不动任何层。
    private static let readWritesSource = """
    (function(){
      var out={}; var L=globalThis.__layers||{}; var seen={};
      function v3(o){ return o ? [+o.x||0,+o.y||0,+o.z||0] : null; }
      for(var k in L){ var o=L[k]; if(!o||o.id==null||seen[o.id])continue; seen[o.id]=1;
        var e={};
        if(o._v!==null)  e.v = o._v ? 1 : 0;
        if(o._al!==null) e.al = +o._al;
        if(o._c!==null)  e.c = [+o._c.x||0,+o._c.y||0,+o._c.z||0];
        if(o._o!==null)  e.o = v3(o._o);
        if(o._s!==null)  e.s = v3(o._s);
        if(o._an!==null) e.an = v3(o._an);
        if(e.v!==undefined||e.al!==undefined||e.c||e.o||e.s||e.an) out[String(o.id)]=e;
      }
      return JSON.stringify(out);
    })()
    """

    /// Swift 字典 → JS 对象(供 __wePropOverrides)。仅处理 Bool/Double/Int/String。
    private static func toJSObject(_ dict: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (k, v) in dict {
            switch v {
            case let b as Bool: out[k] = b
            case let n as NSNumber: out[k] = n
            case let d as Double: out[k] = d
            case let s as String: out[k] = s
            default: break
            }
        }
        return out
    }
}
