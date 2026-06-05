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
    enum Result {
        case string(String)
        case vec3(SIMD3<Float>)
        case failed              // 脚本抛错/不可用 → 调用方回退
    }

    private let context = JSContext()!
    private let updateFn: JSValue?
    /// 脚本声明的属性最终值(name → JS 值),已套用图层覆盖。供调试 / 日志。
    private(set) var resolvedProps: [String: Any] = [:]
    /// JS 异常标记。用 class 引用盒,避免在 init 里 exceptionHandler 闭包过早捕获 self。
    private final class Flag { var hit = false }
    private let exFlag = Flag()
    var didFail: Bool {
        get { exFlag.hit }
        set { exFlag.hit = newValue }
    }
    let sourceTag: String        // 仅用于日志(图层名)

    /// 脚本里有无 init():首帧跑一次(WE 生命周期)。
    private let initFn: JSValue?
    /// 该脚本实例的起始时刻(steady clock):engine.runtime = now - start(对标 WE sStartTime)。
    private let startTime = Date()
    /// 审计修复(#1):若上层传入 sim time,则以首帧 sim time 为起点算 runtime(sim 域),
    ///   保证脚本动画与引擎 sim-time 同步、无头渲染确定。nil = 尚未用过 sim time(走墙钟回退)。
    private var startSimTime: Double? = nil
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
    /// 脚本是否用音频(调 engine.registerAudioBuffers / 读 __audio*)→ 引擎据此采集音频并每帧喂 setAudioSpectrum。
    let usesAudio: Bool
    /// 上次派发的签名,用于 lwe 式去重:仅在变化时再派发,避免每帧重复触发脚本回调。
    private var lastMediaPropertiesSig: String? = nil
    private var lastMediaTimelineSig: String? = nil
    private var lastMediaPlaybackSig: String? = nil

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

        // JS 异常 → 记一笔并标记失败(update() 仍可能返回 undefined,调用方据 didFail/nil 回退)。
        // 只捕获引用盒(非 self),避免在所有存储属性初始化完成前引用 self。
        let flag = exFlag
        context.exceptionHandler = { _, exc in
            flag.hit = true
            Log.write("WEScript[\(tag)] JS exception: \(exc?.toString() ?? "?")")
        }

        // 0) 注入 WE prelude(Vec2/3/4、WEMath、WEColor、console no-op、localStorage、input、
        //    engine、thisLayer/thisScene 桩 + setInterval/__weRunIntervals)。必须在脚本 eval 前:
        //    stripModuleSyntax 删掉了脚本对 WEMath/WEColor 等的 import,这些全局把它们补回来,
        //    复杂脚本(console.log / setInterval / 读写 thisLayer 等)才不会因缺全局抛错回退。
        context.evaluateScript(WEScript.preludeSource)

        // 0b) 注入 engine.canvasSize(WE 的渲染画布尺寸,这里用场景 orthogonalprojection w/h)。
        //     WE 挂件容器/时钟/日期的 origin 脚本第一行就读 engine.canvasSize.x/y,缺它必抛 TypeError → 回退。
        if let engine = context.objectForKeyedSubscript("engine"), engine.isObject {
            let cs: [String: Any] = ["x": canvas.x, "y": canvas.y]
            engine.setObject(cs, forKeyedSubscript: "canvasSize" as NSString)
        }

        // 1) 注入 createScriptProperties shim + 覆盖表。shim 是纯 JS,链式 addX/finish。
        //    覆盖值通过原生注入的 __wePropOverrides 提供:finish() 时按 name 用覆盖替换默认。
        let overridesObj = WEScript.toJSObject(propertyOverrides)
        context.setObject(overridesObj, forKeyedSubscript: "__wePropOverrides" as NSString)
        context.evaluateScript(WEScript.shimSource)

        // 2) 去 module 化脚本体,eval 之。eval 后 scriptProperties / update 落在全局。
        let body = WEScript.stripModuleSyntax(script)
        context.evaluateScript(body)
        if exFlag.hit { return nil }   // 直接读引用盒(此时 updateFn 尚未赋值,不能用 self.didFail)

        // 3) 取 update 句柄。注意:这是核心契约——文本/矢量脚本都靠 update(value) 的**返回值**
        //    模型(实测时钟脚本就是返回 string;别破坏)。update 缺失才判失败。
        guard let fn = context.objectForKeyedSubscript("update"), !fn.isUndefined else {
            Log.write("WEScript[\(tag)] no update() after eval")
            return nil
        }
        self.updateFn = fn

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

        // 解析后的属性快照(scriptProperties 是普通对象)。
        if let sp = context.objectForKeyedSubscript("scriptProperties"), sp.isObject,
           let dict = sp.toDictionary() as? [String: Any] {
            resolvedProps = dict
        }
    }

    /// 跑一次脚本,传入当前值。回退判定交给调用方(failed / 非预期类型)。
    /// 审计修复(#1):新增可选 simTime/frametime 参数;上层应传以保证脚本动画与 sim-time 同步、
    ///   无头渲染确定。默认 nil 时 tickFrame 回退用墙钟 Date()(旧行为,调用方不改也能编)。
    ///   - simTime:引擎累计 sim 时间(秒),用作 engine.runtime 的时间源。
    ///   - frametime:引擎本帧 sim dt(秒,对标 lwe `g_Time - g_TimeLast`);音频平滑等脚本依赖它。
    ///     传入时 engine.frametime 直接取此真实帧间隔;nil 时回退用 runtime 差近似。
    func runString(current: String, simTime: Double? = nil, frametime: Double? = nil) -> Result {
        guard let fn = updateFn else { return .failed }
        didFail = false
        tickFrame(initArg: current, simTime: simTime, frametime: frametime)  // 刷新 engine.runtime/frametime/timeOfDay + 首帧 init(传当前值) + 跑 intervals
        guard let ret = fn.call(withArguments: [current]), !didFail else { return .failed }
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
        guard let fn = updateFn else { return .failed }
        didFail = false
        // 传一个带 x/y/z 的普通对象;脚本会读写其分量并 return。
        let arg: [String: Any] = ["x": current.x, "y": current.y, "z": current.z]
        tickFrame(initArg: arg, simTime: simTime, frametime: frametime)      // 同 runString:刷新 runtime + 首帧 init(传当前 Vec3) + 跑 intervals
        guard let ret = fn.call(withArguments: [arg]), !didFail else { return .failed }
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
        guard let fn = updateFn else { return nil }
        didFail = false
        tickFrame(initArg: current, simTime: simTime, frametime: frametime)
        guard let ret = fn.call(withArguments: [current]), !didFail else { return nil }
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
        guard let fn = updateFn else { return nil }
        didFail = false
        tickFrame(initArg: current, simTime: simTime, frametime: frametime)
        guard let ret = fn.call(withArguments: [Double(current)]), !didFail else { return nil }
        if ret.isNumber { let d = ret.toDouble(); return d.isFinite ? Float(d) : nil }
        return nil
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

    /// 把真实场景层(名/id)注入 __layers 注册表 + __layerList 列表,让 `thisScene.getLayer(name)`
    /// 命中真实层、`thisScene.enumerateLayers()` 返回真实列表(此前返回 __missingLayer / [])。
    /// 对标 lwe `installSceneLayers`:按 id 与 name 双键登记同一层对象。
    /// 本轮范围:层对象带 name/id + 基础矢量属性桩(origin/scale/... 取默认,够 getLayer 命中读 name/id),
    /// **属性写回(把脚本对层对象的修改 applyLayerUpdates 回灌引擎)留 TODO**,见下。
    /// **调用方应在场景层就绪后(通常构造脚本实例后、首帧前)调用一次**;层集合变化时可重复调用。
    /// - Parameter layers: (name, id) 列表;name 为空的层只按 id 登记。
    func setSceneLayers(_ layers: [(name: String, id: Int)]) {
        // 把 (name,id) 列表交给一段 JS 重建注册表 + 列表,层对象在 JS 侧造,getMaterial 等才是
        // 真正可调用的 JS 函数(原生 Swift 闭包 setObject 不会被桥成可调用 JS function)。
        // 用原生注入的 __weLayerDefs 传数据(避免拼字符串/转义问题),由 installLayersSource 消费。
        let defs: [[String: Any]] = layers.map { ["name": $0.name, "id": $0.id] }
        context.setObject(defs, forKeyedSubscript: "__weLayerDefs" as NSString)
        context.evaluateScript(WEScript.installLayersSource)
        // TODO(属性写回 / applyLayerUpdates):lwe 在 evaluate 后会把脚本对层对象的写改(visible/
        //   alpha/origin/scale/color 等)回灌到引擎 Object(syncLayerObjectProperties 的反向)。
        //   本轮只做「getLayer 能命中、读属性不抛错」;脚本对返回层对象的修改目前不回灌引擎。
        //   调用方接入时需:每帧/按需读 __layers[id] 的属性,diff 后应用到对应渲染层。
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
    func dispatchMediaState(title: String?, artist: String?, positionSec: Double?, lengthSec: Double?) {
        let t = title ?? ""
        let a = artist ?? ""
        let pos = positionSec ?? 0
        let len = lengthSec ?? 0

        // 1) properties:title+artist 变化时派发(同 lwe propertiesSignature = title\nartist)。
        if let fn = mediaPropertiesChangedFn {
            let sig = t + "\n" + a
            if lastMediaPropertiesSig != sig {
                lastMediaPropertiesSig = sig
                let event: [String: Any] = ["title": t, "artist": a, "albumTitle": ""]
                _ = fn.call(withArguments: [event])
            }
        }

        // 2) timeline:position(取整秒)+duration 变化时派发(同 lwe timelineSignature)。
        if let fn = mediaTimelineChangedFn {
            let sig = "\(Int(max(0, pos)))\n\(len)"
            if lastMediaTimelineSig != sig {
                lastMediaTimelineSig = sig
                let event: [String: Any] = ["position": pos, "duration": len]
                _ = fn.call(withArguments: [event])
            }
        }

        // TODO(playback/thumbnail):lwe 还派发 mediaPlaybackChanged({state})、mediaThumbnailChanged
        //   ({url, primary/secondary/tertiary/highContrastColor})。播放态/封面数据源就绪后,
        //   调用方可扩展本方法签名传入,并按下方 mediaPlaybackChangedFn 句柄派发。
        _ = mediaPlaybackChangedFn  // 句柄已取,数据源就绪后启用(去重用 lastMediaPlaybackSig)。
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
        // 1) runtime/frametime/timeOfDay。runtime = 实例存活秒数(对标 sStartTime)。
        //    审计修复(#1):优先用 sim time(simTime - startSimTime);未提供时回退墙钟 Date()(默认/旧行为)。
        let runtime: Double
        if let st = simTime {
            if startSimTime == nil { startSimTime = st }
            runtime = max(0, st - (startSimTime ?? st))
        } else {
            runtime = Date().timeIntervalSince(startTime)
        }
        // frametime:优先用引擎传入的本帧真实 dt(对标 lwe g_Time - g_TimeLast);否则用 runtime 差近似。
        let frame = max(0, frametime ?? (runtime - lastRuntime))
        lastRuntime = runtime
        if let engine = context.objectForKeyedSubscript("engine"), engine.isObject {
            engine.setObject(runtime, forKeyedSubscript: "runtime" as NSString)
            engine.setObject(frame, forKeyedSubscript: "frametime" as NSString)
            // timeOfDay:当地一天内的归一化进度 [0,1)(WE: secondsOfDay / 86400)。
            let cal = Calendar.current
            let c = cal.dateComponents([.hour, .minute, .second], from: Date())
            let secs = Double((c.hour ?? 0) * 3600 + (c.minute ?? 0) * 60 + (c.second ?? 0))
            engine.setObject(secs / 86400.0, forKeyedSubscript: "timeOfDay" as NSString)
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
    private static let preludeSource = """
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
      openUserShortcut() { return undefined; }
    };
    globalThis.__missingLayer = {
      text: '', name: '', visible: false, alpha: 0,
      origin: new Vec3(0, 0, 0), scale: new Vec3(1, 1, 1), angles: new Vec3(0, 0, 0),
      color: new Vec4(0, 0, 0, 0), parallaxDepth: new Vec2(0, 0),
      getMaterial() { return null; }
    };
    globalThis.thisLayer = globalThis.thisLayer || {
      text: '', name: '', visible: true, alpha: 1,
      origin: new Vec3(0, 0, 0), scale: new Vec3(1, 1, 1), angles: new Vec3(0, 0, 0),
      color: new Vec4(1, 1, 1, 1), parallaxDepth: new Vec2(0, 0),
      getMaterial() { return null; }
    };
    globalThis.thisScene = globalThis.thisScene || {
      getLayer(name) { return globalThis.__missingLayer; },
      enumerateLayers() { return []; }
    };
    """

    // MARK: - createScriptProperties shim

    /// 纯 JS 实现的 createScriptProperties():链式 addCheckbox/addSlider/addText/addColor/addCombo,
    /// finish() 返回一个对象,每个 name → 其值。值优先取 __wePropOverrides[name](图层/用户覆盖),
    /// 否则取该 addX 调用里的 value(脚本默认)。
    private static let shimSource = """
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

    /// 消费原生注入的 __weLayerDefs([{name,id}]),重建 __layers(name→obj、id→obj 双键)+
    /// __layerList(有序),并把 thisScene.getLayer/enumerateLayers 指向它们(覆盖 prelude 死桩)。
    /// 层对象在 JS 侧构造,getMaterial 是真正的 JS 函数;属性与 thisLayer/__missingLayer 同构,
    /// 脚本读 name/id/origin/scale/... 均不抛错。对标 lwe installSceneLayers 的双键登记。
    private static let installLayersSource = """
    (function() {
      var defs = globalThis.__weLayerDefs || [];
      var layers = {};
      var list = [];
      for (var i = 0; i < defs.length; i++) {
        var d = defs[i] || {};
        var obj = {
          id: d.id, name: String(d.name || ''),
          visible: true, alpha: 1, text: '',
          origin: new Vec3(0, 0, 0), scale: new Vec3(1, 1, 1), angles: new Vec3(0, 0, 0),
          color: new Vec4(1, 1, 1, 1), parallaxDepth: new Vec2(0, 0),
          getMaterial: function() { return null; }
        };
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
    })();
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
