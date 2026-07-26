import Foundation
import simd
import JavaScriptCore

/// 2D 场景的**单 JSContext 共享脚本宿主**(白影轻扬 3497488774 等用脚本库 id=13 的壁纸)。
///
/// 背景:WEScriptRuntime 每脚本独立 context、`globalThis.shared` 各自空,跨脚本只能传 JSON(数据,
/// 传不了活的类/函数)→ 2D 场景所有 `shared.*` 调用抛错 → 轻扬摇摆/时钟事件/时段变色集体失效。
///
/// 本宿主参照 Scene3DScriptHost(Model3D.swift):**所有脚本跑同一 context、共享活的 `shared`**。
/// 流程:
///   1. registerLibrary(source) 先跑库脚本 populate `shared`(eventDispatcher/aniScheduler/
///      SwayParamsClass/startSwayAniLayerList…)。库依赖 engine.isRunningInEditor/Vec3/
///      createScriptProperties/thisLayer/thisObject —— prelude+shim 提供大部分,本宿主补齐
///      NSL 特有缺口(isRunningInEditor / setTimeout / userProperties / thisObject /
///      thisLayer.getAnimationLayer 等),否则库在模块顶层(line 64)就抛错。
///   2. register(id,prop,source,scriptProps) 把各层脚本 eval 进同一 context(IIFE 隔离 init/update,
///      但 shared 共享)。每层带自己的 thisLayer / thisObject / scriptProperties(call 前绑定)。
///   3. tick(runtime,frametime) 每帧:刷新 engine.runtime/frametime/timeOfDay → 跑 intervals →
///      派发周期事件(secondlyRandom 等)→ 调库 update()(aniScheduler.calcInterpolators)→
///      逐层调 update(传当前值)→ 把结果存 currents/texts/visibles。
///   4. value/textValue/visible 读回供引擎写层。
///
/// env 门控:由调用方(SceneRenderEngine)用 WP_2D_SCRIPT_HOST 决定是否建本宿主;默认关 → 零回归。
final class NSL2DScriptHost {
    private let ctx = JSContext()!
    private let canvas: SIMD2<Float>

    /// 每层一个句柄:init/update/applyUserProperties + 该层 thisLayer/thisObject(JSValue)。
    private struct Handle {
        let id: Int
        let prop: String
        let update: JSValue?
        let initFn: JSValue?
        let applyUser: JSValue?
        let thisLayer: JSValue
        let thisObject: JSValue
    }
    private var handles: [String: Handle] = [:]
    private var order: [String] = []                       // 注册顺序(init/update 按此)
    private var currents: [String: SIMD3<Float>] = [:]     // 矢量属性(origin/scale/angles)当前值
    private var texts: [String: String] = [:]              // text 属性
    private var visibles: [String: Bool] = [:]             // visible 属性
    private var alphas: [String: Float] = [:]              // alpha 属性
    private(set) var registered = 0
    private(set) var libraryOK = false

    static func key(_ id: Int, _ prop: String) -> String { "\(id):\(prop)" }

    init(canvas: SIMD2<Float>) {
        self.canvas = canvas
        ctx.exceptionHandler = { _, exc in
            Log.write("NSL2DScriptHost JS exception: \(exc?.toString() ?? "?")")
        }
        // 1) prelude(Vec*/WEMath/engine/thisLayer/thisScene/console/localStorage…)
        ctx.evaluateScript(WEScript.preludeSource)
        // 1b) NSL 特有全局补齐(prelude 没提供 → 不补库在模块顶层就抛错):
        //     - engine.isRunningInEditor()/setTimeout/userProperties
        //     - thisObject(getCallSourceInfo 用)
        //     - thisLayer.getAnimationLayer 系(sway 配置 puppet 动画层用,见下方 __weMakeAniLayerStub)
        ctx.setObject(["x": canvas.x, "y": canvas.y], forKeyedSubscript: "__weCanvas" as NSString)
        ctx.evaluateScript(Self.nslGlobalsSource)
    }

    // MARK: - 库注册

    struct LibraryResult { let ok: Bool; let error: String?; let sharedKeys: [String] }

    /// 跑库脚本 populate shared。库在全局定义 update()(calcInterpolators);本宿主单独保存为 __nslLibUpdate。
    func registerLibrary(source: String) -> LibraryResult {
        // shim(createScriptProperties:库自身也用,读其默认值,无 user 覆盖)。
        ctx.setObject([String: Any](), forKeyedSubscript: "__wePropOverrides" as NSString)
        ctx.evaluateScript(WEScript.shimSource)
        let body = WEScript.stripModuleSyntax(source)
        // 库在全局 eval(shared 挂载、类定义都落在全局);末尾把 update 句柄存为 __nslLibUpdate。
        let wrapped = """
        (function(){ try {
        \(body)
        globalThis.__nslLibUpdate = (typeof update !== 'undefined') ? update : null;
        return 'OK';
        } catch(e){ return 'ERR: '+e; } })()
        """
        let r = ctx.evaluateScript(wrapped)
        let msg = r?.toString() ?? "?"
        let ok = msg == "OK"
        libraryOK = ok
        let keys = ctx.evaluateScript("(function(){try{return Object.keys(shared);}catch(e){return [];}})()")?
            .toArray()?.compactMap { $0 as? String } ?? []
        return LibraryResult(ok: ok, error: ok ? nil : msg, sharedKeys: keys)
    }

    // MARK: - 层脚本注册

    /// 注册一个层脚本(同 context,看得见 shared)。IIFE 隔离 init/update,但 thisLayer/thisObject/
    /// scriptProperties 在 eval 时绑定本层(脚本顶层 `new shared.SwayParamsClass(...)` 也在此跑)。
    @discardableResult
    func register(id: Int, prop: String, source: String, scriptProps: [String: Any],
                  layerName: String = "", staticValue: SIMD3<Float> = .zero) -> Bool {
        let k = Self.key(id, prop)
        // 该层 scriptproperties 覆盖(unwrap {user,value}→value)。
        var ov: [String: Any] = [:]
        for (kk, vv) in scriptProps {
            if let d = vv as? [String: Any], let inner = d["value"] { ov[kk] = inner } else { ov[kk] = vv }
        }
        ctx.setObject(ov, forKeyedSubscript: "__wePropOverrides" as NSString)
        ctx.evaluateScript(WEScript.shimSource)            // 重定义 createScriptProperties(读本层覆盖)
        // 本层 thisLayer / thisObject(独立对象,带 getAnimationLayer 系;脚本顶层 new SwayParams 会引用它)。
        // ⚠**同一层的多个属性脚本(origin/text/visible…)必须共享同一个 thisLayer 对象**:时钟 203 的 text 脚本
        //   `shared.clockLayer4 = thisLayer`、origin 脚本 `thisLayer.size`/`thisLayer.origin` 操作同一层;若每次
        //   register 都新建 __nslTL_<id> → origin 句柄持有旧对象、setLayerSize 改新对象 → 读不到回灌宽度(居中错)。
        //   故已存在则复用。
        let tlKey = "__nslTL_\(id)"
        ctx.evaluateScript("if (typeof globalThis['\(tlKey)'] === 'undefined' || !globalThis['\(tlKey)']) { globalThis['\(tlKey)'] = __weMakeLayerObj(\(id), \(jsString(layerName))); }")
        ctx.evaluateScript("globalThis.thisLayer = globalThis.\(tlKey); globalThis.thisObject = globalThis.\(tlKey);")
        let body = WEScript.stripModuleSyntax(source)
        // IIFE 隔离:返回 {i:init, u:update, a:applyUserProperties}。脚本顶层语句(建 SwayParams 记录)在此执行。
        let wrapped = """
        (function(){ try {
        \(body)
        return { i:(typeof init!=='undefined')?init:null,
                 u:(typeof update!=='undefined')?update:null,
                 a:(typeof applyUserProperties!=='undefined')?applyUserProperties:null }; }
        catch(e){ globalThis.__nslLastErr=String(e); return {i:null,u:null,a:null,err:String(e)}; } })()
        """
        guard let r = ctx.evaluateScript(wrapped), r.isObject else { return false }
        if let err = r.objectForKeyedSubscript("err"), err.isString {
            Log.write("NSL2D register id=\(id) \(prop) [\(layerName)] eval err: \(err.toString() ?? "?")")
        }
        let tl = ctx.evaluateScript("globalThis.\(tlKey)")!
        let i = r.objectForKeyedSubscript("i"); let u = r.objectForKeyedSubscript("u")
        let a = r.objectForKeyedSubscript("a")
        handles[k] = Handle(id: id, prop: prop,
                            update: (u?.isObject == true) ? u : nil,
                            initFn: (i?.isObject == true) ? i : nil,
                            applyUser: (a?.isObject == true) ? a : nil,
                            thisLayer: tl, thisObject: tl)
        order.append(k)
        currents[k] = staticValue
        registered += 1
        return true
    }

    /// 一次性:注册并立即跑 init(给有界测试 / 立即需要副作用的库设置层用)。返回诊断串。
    func registerAndInit(id: Int, prop: String, source: String, scriptProps: [String: Any], layerName: String = "") -> String {
        guard register(id: id, prop: prop, source: source, scriptProps: scriptProps, layerName: layerName) else { return "register FAILED" }
        guard let h = handles[Self.key(id, prop)] else { return "no handle" }
        bindThis(h)
        guard let i = h.initFn else { return "OK(no init)" }
        let arg = ctx.evaluateScript("true")!
        let before = ctx.evaluateScript("globalThis.__nslLastErr")
        _ = i.call(withArguments: [arg])
        let after = ctx.evaluateScript("globalThis.__nslLastErr")
        if let a = after, !a.isUndefined, !a.isNull, a.toString() != before?.toString() {
            return "init THREW: \(a.toString() ?? "?")"
        }
        return "init OK"
    }

    /// 跑所有已注册层的 init(库 init 已在 registerLibrary 时随顶层执行;这里跑各层 init)。
    func runInit() {
        for k in order {
            guard let h = handles[k] else { continue }
            bindThis(h)
            guard let i = h.initFn else { continue }
            // init 参数 = 该属性当前值(visible→bool true、矢量→{x,y,z}、其它→1)。
            let arg = initArg(for: h)
            _ = i.call(withArguments: [arg])
            // init 可能就地写 thisLayer.origin/visible 等 → 读回。
            readBackFromThisLayer(h)
        }
    }

    // MARK: - 每帧驱动

    /// 跑一帧:刷新时间 → 跑 intervals → 派发周期事件 → 库 update(calcInterpolators)→ 逐层 update。
    /// periodicEvents:本帧要派发的周期事件名(secondlyRandom/clockUpdate 等;由调用方按秒/帧节奏给)。
    func tick(runtime: Double, frametime: Double, periodicEvents: [String] = []) {
        ctx.setObject(runtime, forKeyedSubscript: "__rt" as NSString)
        ctx.setObject(frametime, forKeyedSubscript: "__ft" as NSString)
        ctx.evaluateScript("engine.runtime=__rt; engine.frametime=__ft; engine.timeOfDay=(__rt/86400)%1; if(typeof __weRunIntervals==='function')__weRunIntervals(); if(typeof __weRunTimeouts==='function')__weRunTimeouts();")
        // 周期事件派发(经 eventDispatcher;库的监听器据此推进动画/时钟)。
        for ev in periodicEvents {
            ctx.setObject(ev, forKeyedSubscript: "__nslEvt" as NSString)
            ctx.evaluateScript("(function(){try{ if(shared.eventDispatcher){ shared.eventDispatcher.registerEvent(__nslEvt); shared.eventDispatcher.dispatchEventToAll(new shared.Event(__nslEvt)); } }catch(e){}})()")
        }
        // 库 update(needToCalcInterpolator 时推进过渡插值器)。
        if let lib = ctx.objectForKeyedSubscript("__nslLibUpdate"), lib.isObject {
            _ = lib.call(withArguments: [])
        }
        // 逐层 update。
        for k in order {
            guard let h = handles[k], let u = h.update else { continue }
            bindThis(h)
            let arg = currentArg(for: h)
            guard let ret = u.call(withArguments: [arg]) else { continue }
            storeReturn(h, ret: ret, fallback: arg)
            readBackFromThisLayer(h)
        }
    }

    /// 派发 applyUserProperties(用户属性变更:草摆/头摆 refreshable 据此 restartSwayAni)。
    func dispatchApplyUserProperties(_ changed: [String: Any]) {
        ctx.setObject(changed, forKeyedSubscript: "__nslChanged" as NSString)
        let arg = ctx.evaluateScript("(function(){try{return JSON.parse(JSON.stringify(__nslChanged));}catch(e){return {};}})()")!
        // 库自身的 applyUserProperties(同步分类)先跑。
        ctx.evaluateScript("(function(){try{ if(typeof globalThis.__nslLibApplyUser==='function')globalThis.__nslLibApplyUser(__nslChanged); }catch(e){}})()")
        for k in order {
            guard let h = handles[k], let a = h.applyUser else { continue }
            bindThis(h)
            _ = a.call(withArguments: [arg])
            readBackFromThisLayer(h)
        }
    }

    // MARK: - 读回

    func value(id: Int, prop: String) -> SIMD3<Float>? { currents[Self.key(id, prop)] }
    func textValue(id: Int, prop: String = "text") -> String? { texts[Self.key(id, prop)] }
    func visibleValue(id: Int) -> Bool? { visibles[Self.key(id, "visible")] }
    func alphaValue(id: Int) -> Float? { alphas[Self.key(id, "alpha")] }
    func has(id: Int, prop: String) -> Bool { handles[Self.key(id, prop)] != nil }
    /// 该层注册的脚本动画层指令(getAnimationLayer 配置:per-anim-layer frame offset/blend/rate)。
    /// 引擎据此把 sway 的相位/混合/速率喂给 puppet 动画层。空=该层无脚本动画层配置。
    func animLayerCommands(id: Int) -> [AniLayerCommand] {
        let key = "\(id)"
        ctx.setObject(key, forKeyedSubscript: "__nslAniQ" as NSString)
        guard let s = ctx.evaluateScript("(function(){try{var m=globalThis.__weAniCmds||{};return JSON.stringify(m[__nslAniQ]||[]);}catch(e){return '[]';}})()")?.toString(),
              let d = s.data(using: .utf8),
              let arr = (try? JSONSerialization.jsonObject(with: d)) as? [[String: Any]] else { return [] }
        return arr.compactMap { e in
            guard let idx = (e["i"] as? NSNumber)?.intValue else { return nil }
            return AniLayerCommand(index: idx,
                                   frameOffset: Float((e["f"] as? NSNumber)?.doubleValue ?? 0),
                                   blend: Float((e["b"] as? NSNumber)?.doubleValue ?? 1),
                                   rate: Float((e["r"] as? NSNumber)?.doubleValue ?? 1),
                                   visible: ((e["v"] as? NSNumber)?.boolValue ?? true))
        }
    }

    /// 回灌真实文字度量:把某层的 thisLayer.size 设为实测宽高(层单位)。时钟居中脚本(203 offset())读
    /// thisLayer.size.x + shared.clockLayer4.size.x 算居中;宿主默认桩 size=(0,0) → 算出不居中。回灌后 offset() 算对。
    func setLayerSize(id: Int, width: Float, height: Float) {
        ctx.setObject(id, forKeyedSubscript: "__nslSzId" as NSString)
        ctx.setObject(Double(width), forKeyedSubscript: "__nslSzW" as NSString)
        ctx.setObject(Double(height), forKeyedSubscript: "__nslSzH" as NSString)
        // 每层 thisLayer 存在全局 __nslTL_<id>;直接写它的 size(offset() 读的就是它,也即 shared.clockLayer4)。
        ctx.evaluateScript("(function(){try{var tl=globalThis['__nslTL_'+__nslSzId]; if(tl){ tl.size = new Vec2(__nslSzW, __nslSzH); } }catch(e){}})()")
    }

    /// 强制重派 clockUpdate(text 变化驱动 203 的 checkOffset→reset→offset() 重算居中)+ 跑 origin 层 update。
    /// 回灌 size 后调用一次,让时钟脚本据真实宽度算出居中 origin。返回 203 算出的 origin(诊断)。
    @discardableResult
    func forceClockRecenter() -> SIMD3<Float>? {
        ctx.evaluateScript("(function(){try{ if(shared.eventDispatcher){ shared.eventDispatcher.dispatchEventToAll(new shared.Event('clockUpdate')); } }catch(e){}})()")
        if let lib = ctx.objectForKeyedSubscript("__nslLibUpdate"), lib.isObject { _ = lib.call(withArguments: []) }
        for k in order {
            guard let h = handles[k], let u = h.update, h.prop == "origin" else { continue }
            bindThis(h)
            let arg = currentArg(for: h)
            if let ret = u.call(withArguments: [arg]) { storeReturn(h, ret: ret, fallback: arg) }
            readBackFromThisLayer(h)
        }
        return value(id: 203, prop: "origin")
    }

    func sharedDump() -> String {
        ctx.evaluateScript("(function(){try{var k=Object.keys(shared);return k.length+' keys';}catch(e){return 'err';}})()")?.toString() ?? "?"
    }
    /// shared 的**数据**快照 JSON(活的类/函数 JSON.stringify 会丢/抛 → 用 replacer 只保留可序列化数据键:
    /// STARTS_WITH/END_WITH 等常量、时段因子等数值/字符串。供注入各层 WEScript 让 shared 数据读得到)。
    func sharedDumpJSON() -> String {
        ctx.evaluateScript("""
        (function(){ try {
          var out={};
          for (var k in shared) {
            var v = shared[k];
            var t = typeof v;
            if (t === 'number' || t === 'string' || t === 'boolean') out[k] = v;
            else if (v && t === 'object' && !(v instanceof Map) && !(v instanceof Set) && typeof v.calcNodeParam !== 'function') {
              // 普通数据对象(如 clockLayer 的 {size:{x,y}}):浅拷贝可序列化字段。
              try { var s = JSON.stringify(v); if (s && s.length < 4000) out[k] = JSON.parse(s); } catch(e){}
            }
          }
          return JSON.stringify(out);
        } catch(e){ return '{}'; } })()
        """)?.toString() ?? "{}"
    }
    func eval(_ s: String) -> String { ctx.evaluateScript(s)?.toString() ?? "<nil>" }

    /// 单个脚本动画层指令(sway 经 getAnimationLayer(i).setFrame/.blend/.rate/.visible 配置)。
    struct AniLayerCommand {
        let index: Int          // animationlayer 索引(getAnimationLayer(i))
        let frameOffset: Float  // setFrame(frameCount * -offset) 的 offset(0..1,相位偏移)
        let blend: Float        // 混合权重
        let rate: Float         // 播放速率
        let visible: Bool
    }

    // MARK: - 内部

    private func bindThis(_ h: Handle) {
        ctx.setObject(h.thisLayer, forKeyedSubscript: "thisLayer" as NSString)
        ctx.setObject(h.thisObject, forKeyedSubscript: "thisObject" as NSString)
        // 当前层 id 设给全局(getAnimationLayer 把指令归到本层)。
        ctx.setObject(h.id, forKeyedSubscript: "__weCurLayerId" as NSString)
    }
    private func initArg(for h: Handle) -> JSValue {
        switch h.prop {
        case "visible": return ctx.evaluateScript("true")!
        case "alpha", "scale": return ctx.evaluateScript("1")!
        case "text": return ctx.evaluateScript("''")!
        default:
            let c = currents[Self.key(h.id, h.prop)] ?? .zero
            return ctx.evaluateScript("(new Vec3(\(c.x),\(c.y),\(c.z)))")!
        }
    }
    private func currentArg(for h: Handle) -> JSValue {
        switch h.prop {
        case "visible": return ctx.evaluateScript("\(visibles[Self.key(h.id, h.prop)] ?? true)")!
        case "alpha": return ctx.evaluateScript("\(alphas[Self.key(h.id, h.prop)] ?? 1)")!
        case "text": return ctx.evaluateScript(jsString(texts[Self.key(h.id, h.prop)] ?? ""))!
        default:
            let c = currents[Self.key(h.id, h.prop)] ?? .zero
            return ctx.evaluateScript("(new Vec3(\(c.x),\(c.y),\(c.z)))")!
        }
    }
    private func storeReturn(_ h: Handle, ret: JSValue, fallback: JSValue) {
        let k = Self.key(h.id, h.prop)
        if h.prop == "visible" {
            if ret.isBoolean || ret.isNumber { visibles[k] = ret.toBool() }
            return
        }
        if h.prop == "alpha" {
            if ret.isNumber { let d = ret.toDouble(); if d.isFinite { alphas[k] = Float(d) } }
            return
        }
        if h.prop == "text" {
            if ret.isString { texts[k] = ret.toString() ?? "" }
            return
        }
        // 矢量(origin/scale/angles)
        if ret.isNumber {
            let s = ret.toDouble(); if s.isFinite { currents[k] = SIMD3(Float(s), Float(s), Float(s)) }
            return
        }
        let obj = (ret.isObject && !ret.isUndefined && !ret.isNull) ? ret : fallback
        let c = currents[k] ?? .zero
        let x = obj.objectForKeyedSubscript("x")?.toDouble() ?? Double(c.x)
        let y = obj.objectForKeyedSubscript("y")?.toDouble() ?? Double(c.y)
        let z = obj.objectForKeyedSubscript("z")?.toDouble() ?? Double(c.z)
        if x.isFinite && y.isFinite && z.isFinite { currents[k] = SIMD3(Float(x), Float(y), Float(z)) }
    }
    /// 部分脚本不 return、直接写 thisLayer.origin/visible/alpha/text(applyUserProperties 尤其如此)。读回。
    private func readBackFromThisLayer(_ h: Handle) {
        let k = Self.key(h.id, h.prop)
        let tl = h.thisLayer
        switch h.prop {
        case "visible":
            if let v = tl.objectForKeyedSubscript("visible"), v.isBoolean || v.isNumber { visibles[k] = v.toBool() }
        case "alpha":
            if let v = tl.objectForKeyedSubscript("alpha"), v.isNumber { let d = v.toDouble(); if d.isFinite { alphas[k] = Float(d) } }
        case "text":
            if let v = tl.objectForKeyedSubscript("text"), v.isString { let s = v.toString() ?? ""; if !s.isEmpty { texts[k] = s } }
        case "origin", "scale", "angles":
            if let v = tl.objectForKeyedSubscript(h.prop), v.isObject {
                let x = v.objectForKeyedSubscript("x")?.toDouble()
                let y = v.objectForKeyedSubscript("y")?.toDouble()
                let z = v.objectForKeyedSubscript("z")?.toDouble()
                if let x = x, let y = y, x.isFinite, y.isFinite {
                    currents[k] = SIMD3(Float(x), Float(y), Float(z ?? 0))
                }
            }
        default: break
        }
    }
    private func jsString(_ s: String) -> String {
        let esc = s.replacingOccurrences(of: "\\", with: "\\\\")
                   .replacingOccurrences(of: "'", with: "\\'")
                   .replacingOccurrences(of: "\n", with: "\\n")
                   .replacingOccurrences(of: "\r", with: "")
        return "'\(esc)'"
    }

    // MARK: - NSL 特有全局(prelude 缺,补齐;否则库模块顶层抛错)

    private static let nslGlobalsSource = """
    (function(){
      if (typeof engine === 'undefined' || !engine) globalThis.engine = {};
      // getCallSourceInfo() 读 thisObject(prelude 只给了 thisLayer)→ 缺则 registerListener/dispatch 抛
      // ReferenceError。给个默认全局(每层注册时会被本层对象覆盖,见 register/bindThis)。
      if (typeof globalThis.thisObject === 'undefined') globalThis.thisObject = globalThis.thisLayer || { name: '' };
      // Vec4 补 multiply/add(prelude Vec4 极简;颜色脚本 newColor.multiply(weight) 用)。
      if (typeof Vec4 === 'function' && !Vec4.prototype.multiply) {
        Vec4.prototype.multiply = function(v){ var p = (typeof v==='number')?[v,v,v,v]:__weParts(v); return new Vec4(this.x*p[0], this.y*p[1], this.z*p[2], this.w*(p[3]||1)); };
        Vec4.prototype.add = function(v){ var p=__weParts(v); return new Vec4(this.x+p[0], this.y+p[1], this.z+p[2], this.w+p[3]); };
        Vec4.prototype.multiplyScalar = function(s){ s=Number(s); return new Vec4(this.x*s, this.y*s, this.z*s, this.w*s); };
      }
      // __missingLayer 补桩(getParent 链可能命中它):加 size/getParent/getAnimation 防 TypeError。
      if (globalThis.__missingLayer) {
        var ml = globalThis.__missingLayer;
        if (!ml.size) ml.size = new Vec2(0,0);
        if (typeof ml.getParent !== 'function') ml.getParent = function(){ return ml; };
        if (typeof ml.getAnimation !== 'function') ml.getAnimation = function(){ return { rate:1, frame:0, frameCount:1, play:function(){}, stop:function(){}, setFrame:function(){} }; };
        if (typeof ml.getAnimationLayer !== 'function') ml.getAnimationLayer = function(){ return { frameCount:1, play:function(){}, stop:function(){}, setFrame:function(){}, blend:1, rate:1, visible:false }; };
      }
      // NSL line 64: const isRunningInEditor = engine.isRunningInEditor()  → 缺则抛错。运行时(非编辑器)返回 false。
      engine.isRunningInEditor = function(){ return false; };
      engine.canvasSize = { x: __weCanvas.x, y: __weCanvas.y };
      engine.screenResolution = { x: __weCanvas.x, y: __weCanvas.y };
      // 用户属性(UserPropertyCategory._bindUserProperties 遍历 Object.keys(engine.userProperties))。
      engine.userProperties = engine.userProperties || {};
      // setTimeout / 模拟时钟超时队列(NSL delayedStartAni / removeTask 用 engine.setTimeout)。
      globalThis.__timeouts = [];
      engine.setTimeout = function(cb, delayMs){
        var d = Math.max(0, Number(delayMs||0)/1000);
        var t = { cb: cb, fire: engine.runtime + d, done: false };
        globalThis.__timeouts.push(t);
        return function(){ t.done = true; };
      };
      globalThis.__weRunTimeouts = function(){
        var L = globalThis.__timeouts; if(!L) return;
        for (var i=0;i<L.length;i++){ var t=L[i]; if(t.done) continue; if(engine.runtime>=t.fire){ t.done=true; try{ if(typeof t.cb==='function') t.cb(); }catch(e){} } }
      };
      // 脚本动画层指令收集(getAnimationLayer(i).setFrame/.blend/.rate/.visible → 归到当前层 __weCurLayerId)。
      globalThis.__weAniCmds = {};   // layerId(string) → [ {i,f,b,r,v}, ... ]
      globalThis.__weCurLayerId = 0;
      // 一个脚本动画层句柄:记录它收到的配置,push 进 __weAniCmds[当前层]。
      globalThis.__weMakeAniLayer = function(index){
        var lid = String(globalThis.__weCurLayerId);
        index = parseInt(index, 10); if (!isFinite(index)) index = 0;   // 数组分支传 String(i),统一成整数
        var cmd = { i: index, f: 0, b: 1, r: 1, v: true };
        if (!globalThis.__weAniCmds[lid]) globalThis.__weAniCmds[lid] = [];
        // 同层同 index 覆盖(restartSwayAni 会重配)。
        var arr = globalThis.__weAniCmds[lid], found=false;
        for (var k=0;k<arr.length;k++){ if(arr[k].i===index){ arr[k]=cmd; found=true; break; } }
        if(!found) arr.push(cmd);
        return {
          frameCount: 1,                 // 归一帧数:setFrame(frameCount*-offset) → f=offset(0..1)
          _index: index,
          play: function(){ cmd.v = true; },
          stop: function(){ cmd.v = false; },
          setFrame: function(fr){ cmd.f = -Number(fr)||0; },   // 库传 frameCount*-offset → 这里取正 offset
          set blend(v){ cmd.b = Number(v)||0; }, get blend(){ return cmd.b; },
          set rate(v){ cmd.r = Number(v)||1; }, get rate(){ return cmd.r; },
          set visible(v){ cmd.v = !!v; }, get visible(){ return cmd.v; }
        };
      };
      // 构造一个层对象(thisLayer/thisObject):含 sway 用的 getAnimationLayer 系 + 常见层 API 桩。
      globalThis.__weMakeLayerObj = function(id, name){
        var o = {
          id: id, name: String(name||''), visible: true, alpha: 1, text: '',
          origin: new Vec3(0,0,0), scale: new Vec3(1,1,1), angles: new Vec3(0,0,0),
          color: new Vec4(1,1,1,1), parallaxDepth: new Vec2(0,0),
          // size/padding:文本层/居中脚本(时钟 203 offset())读 thisLayer.size.x。无真实文本度量 → 给 0 占位
          // (脚本读得到、不抛 TypeError;真实居中需引擎回灌文本度量,见报告「时钟居中」缺口)。
          size: new Vec2(0,0), padding: 0,
          _aniCount: 16,                  // 假定足够多动画层(sway 索引 0..10);引擎按真实 anim 层数裁。
          getMaterial: function(){ return null; },
          getAnimationLayerCount: function(){ return this._aniCount; },
          getAnimationLayer: function(i){ globalThis.__weCurLayerId = id; return globalThis.__weMakeAniLayer(i); },
          // 部件树/动画查询桩(部分脚本读父层/动画做相对运算;无真实树 → 返回安全占位,不抛错)。
          getParent: function(){ return globalThis.__missingLayer; },
          getAnimation: function(){ return { rate: 1, frame: 0, frameCount: 1, play: function(){}, stop: function(){}, setFrame: function(){} }; },
          getAnimationCount: function(){ return 0; }
        };
        return o;
      };
    })();
    """
}
