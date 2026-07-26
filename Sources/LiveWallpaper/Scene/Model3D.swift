import Foundation
import simd
import JavaScriptCore

// 单-JSContext 脚本宿主:太阳系等 3D 场景的对象变换/位置由 JS 脚本逐帧算,且**跨脚本共享 `shared`**
// (vp1 写 shared.vp1posx,p1 读它定位)。WEScript 是每脚本独立 context(shared 不互通,只够 2D 时钟用);
// 这里复用 WEScript 的 prelude/shim/stripModuleSyntax,但把**全部脚本注册进同一个 context**共享 globalThis.shared。
// 每脚本用 IIFE 包裹隔离其 update/init(否则全局 update 互相覆盖)。
final class Scene3DScriptHost {
    private let ctx = JSContext()!
    private struct Handle { let update: JSValue?; let initFn: JSValue? }
    private var handles: [String: Handle] = [:]      // "id:prop" → 句柄
    private var currents: [String: SIMD3<Float>] = [:] // 每脚本当前值(逐 tick 演进:支持累积/状态脚本)
    private var texts: [String: String] = [:]          // 文字脚本(text 属性)的字符串结果
    private(set) var registered = 0

    /// 太阳系 Main 模拟(VSOP87D 日心模拟)用 `Date.now()`(墙钟毫秒)算时间步进:
    ///   `realDeltaMs = clamp(now - lastRealTime, 0, 100)`、`deltaSeconds = realDeltaMs/1000 * actualTimeMultiplier`、
    ///   `actualTimeMultiplier = timenum(0-1) × TIME_UNITS[timedw]`(timedw=时间单位档:0=秒/s … 6=年/s)。
    /// **不读 engine.runtime**。烘焙/逐帧若用真墙钟,相邻 tick 的 now 几乎不变 → realDeltaMs≈0 → 模拟不推进 →
    /// 行星定格(就是 R4「行星静止」缺口的根因)。故把 `Date.now()` 改为**引擎 sim 时钟驱动**:首帧锚定真实当前时刻
    /// (让模拟从真实天文日期起算,忠实 WE「实时太阳系」),其后按 `锚点 + engine.runtime*1000` 推进(逐帧 dt 真实) →
    /// realDeltaMs = frametime*1000(被 clamp 到 ≤100ms,与 WE 一致)> 0 → 行星随时间公转(R4 修复)。
    ///
    /// **速度**:pkg 默认 timenum=1/timedw=0 = 实时(1 秒/秒,行星几乎不可见地慢——这是写实科普壁纸,用户拖速度滑块加速)。
    ///   WP_SOLAR_SPEED 不直接乘 Date.now()(会被脚本 clamp(…,100) 吃掉,无效),而是**预置 storage 的 timedw 档位**
    ///   (走 pkg 自己的速度脚本 id=859/860 路径,忠实)让模拟以该速度跑,供验证/演示。值=时间单位档 0-6(默认 nil=不预置=实时)。
    static let solarSpeedUnit: Int? = WPEnv.vars["WP_SOLAR_SPEED"].flatMap { Int($0) }.map { max(0, min(6, $0)) }
    private var nowAnchorMs: Double = 0      // 首帧锚定的真实当前毫秒(模拟起算日期)
    private var nowAnchored = false
    /// sim 时钟开关:**仅日心太阳系模拟启用**(让 Date.now() 随 engine.runtime 推进 → 行星公转)。
    /// 默认关闭 → Date.now() 恒返回 init 时的真实墙钟(与改前一致),故土星/其它 3D 场景的 Date.now() 行为零变化(零回归)。
    /// 由 Scene3DRuntime 在检测到 shared.currentFocus(Main 模拟独有)后调 enableSimClock() 开启。
    private var simClockEnabled = false
    func enableSimClock() {
        simClockEnabled = true
        ctx.evaluateScript("globalThis.__simClockOn = true;")   // 开启 Date.now()/new Date() 的 sim 时钟覆盖(仅太阳系)
        // WP_SOLAR_SPEED:预置 pkg 速度脚本(id=859/860)的 storage 档位 → 模拟以该速度档运行(忠实走 pkg 速度路径)。
        // 默认 nil 时不预置 → 用 pkg 默认实时(timedw=0)。仅验证/演示用;正常运行不设此变量 → 行为=pkg 默认。
        if let unit = Self.solarSpeedUnit {
            ctx.evaluateScript("if(globalThis.storage){ globalThis.storage.set('timedw_storage', \(unit)); globalThis.storage.set('timenum_storage', 1); }")
        }
    }

    init() {
        ctx.exceptionHandler = { _, _ in }
        ctx.evaluateScript(WEScript.preludeSource)
        // storage 桩(时间倍率/单位脚本 id=859/860 用 storage.get/set 存档;prelude 只定义 localStorage)。
        // 与 localStorage 同构,本地内存即可(单会话无需持久化);缺它会让倍率脚本走 catch 分支(默认值仍对)。
        ctx.evaluateScript("""
        globalThis.storage = globalThis.storage || {
          __d: Object.create(null),
          get(k){ k=String(k); return Object.prototype.hasOwnProperty.call(this.__d,k)?this.__d[k]:undefined; },
          set(k,v){ this.__d[String(k)]=v; }, remove(k){ delete this.__d[String(k)]; }
        };
        """)
        // Date.now()/new Date() 引擎 sim 时钟覆盖(见上注释)。**仅当 __simClockOn(=日心太阳系模拟,enableSimClock 置位)
        // 时**返回 sim 毫秒 __nowSimMs;否则**完全透传真实墙钟**(土星等 HUD 时钟/Date 动画行为与改前一致,零回归)。
        // __nowSimMs 由 tick 每帧写入;new Date()(无/单参)也读它(保持模拟日期一致)。
        ctx.evaluateScript("""
        globalThis.__simClockOn = false;
        globalThis.__nowSimMs = Date.now();
        (function(){
          var RealDate = Date;
          function D(a,b,c,d,e,f,g){
            if (this instanceof D) {
              if (arguments.length === 0) return globalThis.__simClockOn ? new RealDate(globalThis.__nowSimMs) : new RealDate();
              if (arguments.length === 1) return new RealDate(a);
              return new RealDate(a, b||0, (c===undefined?1:c), d||0, e||0, f||0, g||0);
            }
            return (globalThis.__simClockOn ? new RealDate(globalThis.__nowSimMs) : new RealDate()).toString();
          }
          D.now = function(){ return globalThis.__simClockOn ? globalThis.__nowSimMs : RealDate.now(); };
          D.parse = RealDate.parse; D.UTC = RealDate.UTC;
          D.prototype = RealDate.prototype;
          globalThis.Date = D;
        })();
        """)
    }

    static func key(_ id: Int, _ prop: String) -> String { "\(id):\(prop)" }

    func register(id: Int, prop: String, source: String, scriptProps: [String: Any], staticValue: SIMD3<Float>) {
        // scriptproperties 解包({user,value}→value)供 shim 的 __wePropOverrides。
        var ov: [String: Any] = [:]
        for (k, v) in scriptProps {
            if let d = v as? [String: Any], let inner = d["value"] { ov[k] = inner } else { ov[k] = v }
        }
        ctx.setObject(ov, forKeyedSubscript: "__wePropOverrides" as NSString)
        ctx.evaluateScript(WEScript.shimSource)            // 重定义 createScriptProperties(读本脚本的覆盖)
        let body = WEScript.stripModuleSyntax(source)
        let wrapped = "(function(){ try {\n\(body)\nreturn {u:(typeof update!=='undefined')?update:null, i:(typeof init!=='undefined')?init:null}; } catch(e){ return {u:null,i:null}; } })()"
        guard let r = ctx.evaluateScript(wrapped), r.isObject else { return }
        let u = r.objectForKeyedSubscript("u"); let i = r.objectForKeyedSubscript("i")
        handles[Self.key(id, prop)] = Handle(update: (u?.isObject == true) ? u : nil,
                                             initFn: (i?.isObject == true) ? i : nil)
        currents[Self.key(id, prop)] = staticValue
        registered += 1
    }

    func runInit() {
        for (key, h) in handles {
            guard let i = h.initFn else { continue }
            let c = currents[key] ?? .zero
            let v = ctx.evaluateScript("({x:\(c.x),y:\(c.y),z:\(c.z)})")!
            _ = i.call(withArguments: [v])
        }
    }

    /// 跑一帧:更新 engine.runtime/frametime + Date.now() sim 时钟,对每个脚本调 update(current),把结果存回 currents(演进)。
    func tick(runtime: Double, frametime: Double) {
        ctx.setObject(runtime, forKeyedSubscript: "__rt" as NSString)
        ctx.setObject(frametime, forKeyedSubscript: "__ft" as NSString)
        ctx.evaluateScript("engine.runtime=__rt; engine.frametime=__ft; engine.timeOfDay=(__rt/86400)%1;")
        // Date.now() sim 时钟:**仅日心太阳系模拟**(simClockEnabled)启用——首帧锚定真实当前毫秒(模拟从真实天文日期
        // 起算),其后按 锚点 + runtime*1000 推进(逐帧真实 dt),使 Main 模拟 realDeltaMs = now-lastRealTime = frametime*1000
        // (被脚本 clamp 到 ≤100ms,与 WE 一致)> 0 → 行星随时间公转(R4 修复)。速度由 storage 预置的 timedw 档(WP_SOLAR_SPEED)决定。
        // 未启用(土星等)则不动 __nowSimMs(恒 = init 时墙钟)→ Date.now() 行为与改前一致(零回归)。
        if simClockEnabled {
            if !nowAnchored { nowAnchored = true; nowAnchorMs = Date().timeIntervalSince1970 * 1000.0 }
            let simNowMs = nowAnchorMs + runtime * 1000.0
            ctx.setObject(simNowMs, forKeyedSubscript: "__nowSimMs" as NSString)
        }
        for (key, h) in handles {
            guard let u = h.update else { continue }
            let c = currents[key] ?? .zero
            let arg = ctx.evaluateScript("({x:\(c.x),y:\(c.y),z:\(c.z)})")!
            guard let ret = u.call(withArguments: [arg]) else { continue }
            // 文字脚本(text/textzhen 等属性)update() 返回 string → 存 texts(供 HUD 文字层用)。
            if ret.isString { texts[key] = ret.toString() ?? ""; continue }
            let obj = (ret.isObject && !ret.isUndefined && !ret.isNull) ? ret : arg
            // 数值返回(标量 scale)→ 各轴同值;对象 → x/y/z
            if ret.isNumber {
                let s = ret.toDouble(); if s.isFinite { currents[key] = SIMD3(Float(s), Float(s), Float(s)) }
                continue
            }
            let x = obj.objectForKeyedSubscript("x")?.toDouble() ?? Double(c.x)
            let y = obj.objectForKeyedSubscript("y")?.toDouble() ?? Double(c.y)
            let z = obj.objectForKeyedSubscript("z")?.toDouble() ?? Double(c.z)
            if x.isFinite && y.isFinite && z.isFinite { currents[key] = SIMD3(Float(x), Float(y), Float(z)) }
        }
    }

    func value(id: Int, prop: String) -> SIMD3<Float>? { currents[Self.key(id, prop)] }
    func textValue(id: Int, prop: String = "text") -> String? { texts[Self.key(id, prop)] }
    func has(id: Int, prop: String) -> Bool { handles[Self.key(id, prop)]?.update != nil }

    // MARK: - effect uniform 脚本(轨道 guidao 等:层 effect 的 constantshadervalue 脚本读 shared 算 uniform)
    private var uniformHandles: [String: JSValue] = [:]   // uniform key → update 函数
    /// 注册一个 effect uniform 脚本(在同一 context,看得见宿主 shared)。key 唯一(如 "517:[P1] OrbitA")。
    func registerUniform(key: String, source: String) {
        let body = WEScript.stripModuleSyntax(source)
        let wrapped = "(function(){ try {\n\(body)\nreturn (typeof update!=='undefined')?update:null; } catch(e){ return null; } })()"
        if let r = ctx.evaluateScript(wrapped), r.isObject { uniformHandles[key] = r }
    }
    /// 评估 uniform 脚本(对 shared 求值)→ comps 个分量(1=标量/各轴同值,3=vec3 x/y/z)。
    func evalUniform(key: String, comps: Int) -> [Float] {
        guard let u = uniformHandles[key] else { return [Float](repeating: 0, count: comps) }
        let arg = ctx.evaluateScript("({x:0,y:0,z:0})")!
        guard let ret = u.call(withArguments: [arg]) else { return [Float](repeating: 0, count: comps) }
        if ret.isNumber { let v = Float(ret.toDouble()); return comps == 1 ? [v] : [v, v, v] }
        if comps == 1 {
            let x = ret.objectForKeyedSubscript("x")
            let v = (x?.isUndefined == false) ? (x?.toDouble() ?? 0) : ret.toDouble()
            return [Float(v.isFinite ? v : 0)]
        }
        let x = ret.objectForKeyedSubscript("x")?.toDouble() ?? 0
        let y = ret.objectForKeyedSubscript("y")?.toDouble() ?? 0
        let z = ret.objectForKeyedSubscript("z")?.toDouble() ?? 0
        return [Float(x.isFinite ? x : 0), Float(y.isFinite ? y : 0), Float(z.isFinite ? z : 0)]
    }
    func hasUniform(_ key: String) -> Bool { uniformHandles[key] != nil }
    /// 评估某层的 visible 脚本(读宿主 shared)→ bool。无 visible 脚本则返 nil(用静态可见性)。
    /// 太阳系灵动岛/通知等容器靠 visible 脚本条件显隐;静态壁纸无交互→默认隐藏,其子层(边框等)随之隐藏。
    func evalLayerVisible(id: Int) -> Bool? {
        guard let h = handles[Self.key(id, "visible")], let u = h.update else { return nil }
        let arg = ctx.evaluateScript("true")!
        guard let ret = u.call(withArguments: [arg]), !ret.isUndefined, !ret.isNull else { return nil }
        if ret.isBoolean { return ret.toBool() }
        if ret.isNumber { return ret.toDouble() != 0 }
        return nil
    }

    // MARK: - thisScene.getLayer 真实层 + 回灌(太阳系 Main 模拟用 getLayer(name).origin=轨道位置 驱动行星)
    /// 安装真实场景层:name/id→层对象,origin/scale/angles 用 defineProperty 记脏(_o/_s/_a)。
    /// 让 Main 模拟的 `thisScene.getLayer(name).origin = 计算位置` 命中真层、被 readLayerOverrides 读回。
    func installLayers(_ defs: [[String: Any]]) {
        ctx.setObject(defs, forKeyedSubscript: "__weLayerDefs" as NSString)
        ctx.evaluateScript(Self.installDirtyLayersSource)
    }
    /// tick 后读回 Main 模拟经 getLayer 设过的 origin/scale/angles(只含记脏的层 → 不误碰未被驱动的节点)。
    func readLayerOverrides() -> [Int: [String: SIMD3<Float>]] {
        guard let s = ctx.evaluateScript(Self.readOverridesSource)?.toString(),
              let data = s.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: [String: [Double]]] else { return [:] }
        var out: [Int: [String: SIMD3<Float>]] = [:]
        for (k, e) in obj {
            guard let id = Int(k) else { continue }
            var m: [String: SIMD3<Float>] = [:]
            if let v = e["o"], v.count == 3 { m["origin"] = SIMD3(Float(v[0]), Float(v[1]), Float(v[2])) }
            if let v = e["s"], v.count == 3 { m["scale"]  = SIMD3(Float(v[0]), Float(v[1]), Float(v[2])) }
            if let v = e["a"], v.count == 3 { m["angles"] = SIMD3(Float(v[0]), Float(v[1]), Float(v[2])) }
            if !m.isEmpty { out[id] = m }
        }
        return out
    }
    private static let installDirtyLayersSource = """
    (function() {
      var defs = globalThis.__weLayerDefs || [];
      var layers = {}; var list = [];
      function mk(d) {
        var o = { id: d.id, name: String(d.name||''), visible: true, alpha: 1, text: '',
                  _o: null, _s: null, _a: null,
                  color: new Vec4(1,1,1,1), parallaxDepth: new Vec2(0,0),
                  getMaterial: function(){ return null; } };
        Object.defineProperty(o, 'origin', { get: function(){ return this._o || new Vec3(0,0,0); }, set: function(v){ this._o = v; }, configurable: true });
        Object.defineProperty(o, 'scale',  { get: function(){ return this._s || new Vec3(1,1,1); }, set: function(v){ this._s = v; }, configurable: true });
        Object.defineProperty(o, 'angles', { get: function(){ return this._a || new Vec3(0,0,0); }, set: function(v){ this._a = v; }, configurable: true });
        return o;
      }
      for (var i=0;i<defs.length;i++){ var d=defs[i]||{}; var o=mk(d); layers[String(d.id)]=o; if(o.name) layers[o.name]=o; list.push(o); }
      globalThis.__layers = layers; globalThis.__layerList = list;
      if(!globalThis.thisScene) globalThis.thisScene = {};
      globalThis.thisScene.getLayer = function(name){ var k=String(name); return (globalThis.__layers && globalThis.__layers[k]) ? globalThis.__layers[k] : globalThis.__missingLayer; };
      globalThis.thisScene.enumerateLayers = function(){ return globalThis.__layerList || []; };
    })();
    """
    private static let readOverridesSource = """
    (function(){
      var out={}; var L=globalThis.__layers||{}; var seen={};
      for(var k in L){ var o=L[k]; if(!o||o.id==null||seen[o.id])continue; seen[o.id]=1;
        var e={};
        if(o._o!=null)e.o=[+o._o.x||0,+o._o.y||0,+o._o.z||0];
        if(o._s!=null)e.s=[+o._s.x||0,+o._s.y||0,+o._s.z||0];
        if(o._a!=null)e.a=[+o._a.x||0,+o._a.y||0,+o._a.z||0];
        if(e.o||e.s||e.a)out[String(o.id)]=e;
      }
      return JSON.stringify(out);
    })()
    """
    /// 诊断:shared 里有多少键、含哪些(判断 Main 模拟是否把 sun_D_real/txh_deg 等算进 shared)。
    func sharedDump() -> String {
        ctx.evaluateScript("(function(){try{var k=Object.keys(shared);return k.length+' keys: '+k.join(',');}catch(e){return 'err';}})()")?.toString() ?? "?"
    }
    /// shared 是否含某键(判场景类型:日心太阳系模拟写 currentFocus/viewScale,土星等无)。
    func sharedHas(_ key: String) -> Bool {
        ctx.evaluateScript("(typeof shared!=='undefined' && shared['\(key)']!==undefined)")?.toBool() ?? false
    }
    /// 读 shared 里的数值(无/非数值→nil)。
    func sharedNum(_ key: String) -> Double? {
        guard let v = ctx.evaluateScript("(typeof shared!=='undefined' ? shared['\(key)'] : undefined)"),
              v.isNumber else { return nil }
        let d = v.toDouble(); return d.isFinite ? d : nil
    }
    /// 导出 shared 快照 JSON(注入给 per-layer 2D 脚本用;比 toDictionary 稳,含嵌套也行)。
    func sharedJSON() -> String {
        ctx.evaluateScript("(function(){try{return JSON.stringify(shared);}catch(e){return '{}';}})()")?.toString() ?? "{}"
    }
}

// MARK: - MDLV0023 3D 几何模型(太阳系/土星等透视场景的行星/天空盒/环)
//
// 与 PuppetMesh 的 MDLV(80字节蒙皮顶点)不同:这些是**纯几何 3D 模型**,顶点 **48 字节**
// (pos float3 + normal float3 + tangent float4 + uv float2),vfmt=15。逐字节逆向 + 多文件交叉
// 验证(s1.mdl 8064顶点法线单位长、索引合法、文件大小自洽)。
//
// 格式(小端):
//  [0:9]  "MDLV0023"\0
//  [9]    u32 version(15)   [13] u32 unk(1)   [17] u32 submeshCount
//  每 submesh:material cstr(null结尾) + u32 reserved + 3f bboxMin + 3f bboxMax
//             + u32 vfmt + u32 vertexBytes + 顶点[vertexBytes/48] + u32 indexBytes + u16[indexBytes/2]
//             + (非末尾)若干 0x00 padding
struct MDLGeometry {
    struct Submesh { let material: String; let indexStart: Int; let indexCount: Int }
    let positions: [SIMD3<Float>]
    let normals: [SIMD3<Float>]
    let uvs: [SIMD2<Float>]
    let indices: [UInt32]          // 统一升到 u32(submesh 拼接后顶点基址偏移可能超 u16)
    let submeshes: [Submesh]

    /// 交错 GPU 顶点缓冲:每顶点 8 个 float = pos.xyz, uv.xy, normal.xyz(32 字节)。
    func interleaved() -> [Float] {
        var out = [Float](); out.reserveCapacity(positions.count * 8)
        for i in 0..<positions.count {
            let p = positions[i], n = normals[i], t = uvs[i]
            out.append(p.x); out.append(p.y); out.append(p.z)
            out.append(t.x); out.append(t.y)
            out.append(n.x); out.append(n.y); out.append(n.z)
        }
        return out
    }

    static func parse(_ data: Data) -> MDLGeometry? {
        let b = [UInt8](data)
        let stride = 48
        guard b.count >= 21, let magic = String(bytes: b[0..<8], encoding: .ascii),
              magic == "MDLV0023" || magic == "MDLV0021" else { return nil }
        func u32(_ o: Int) -> UInt32 {
            guard o + 4 <= b.count else { return 0 }
            return UInt32(b[o]) | (UInt32(b[o+1]) << 8) | (UInt32(b[o+2]) << 16) | (UInt32(b[o+3]) << 24)
        }
        func f32(_ o: Int) -> Float { Float(bitPattern: u32(o)) }
        var o = 9
        _ = u32(o); o += 4               // version
        _ = u32(o); o += 4               // unk
        let submeshCount = Int(u32(o)); o += 4
        guard submeshCount > 0, submeshCount < 4096 else { return nil }

        var positions = [SIMD3<Float>](), normals = [SIMD3<Float>](), uvs = [SIMD2<Float>]()
        var indices = [UInt32](), submeshes = [MDLGeometry.Submesh]()
        for si in 0..<submeshCount {
            // material cstr
            let mstart = o
            while o < b.count && b[o] != 0 { o += 1 }
            guard o < b.count else { return nil }
            let material = String(bytes: b[mstart..<o], encoding: .utf8) ?? ""
            o += 1                        // NUL
            _ = u32(o); o += 4            // reserved
            o += 24                       // bbox min(3f)+max(3f)
            _ = u32(o); o += 4            // vfmt
            let vbl = Int(u32(o)); o += 4
            guard vbl > 0, vbl % stride == 0, o + vbl + 4 <= b.count else { return nil }
            let nv = vbl / stride
            let vbase = positions.count
            for vi in 0..<nv {
                let vo = o + vi * stride
                positions.append(SIMD3(f32(vo), f32(vo + 4), f32(vo + 8)))
                normals.append(SIMD3(f32(vo + 12), f32(vo + 16), f32(vo + 20)))
                uvs.append(SIMD2(f32(vo + 40), f32(vo + 44)))   // tangent xyzw @[24:40], uv @[40:48]
            }
            o += vbl
            let ibl = Int(u32(o)); o += 4
            // 索引类型按顶点数定:>65535 顶点 u16 寻址不到 → 用 u32(球体01 849202顶点实测=u32,
            // s1 8064顶点=u16)。这是导出器「能用u16就u16,否则u32」的标准约定。
            let idxSize = nv > 65535 ? 4 : 2
            guard ibl > 0, ibl % idxSize == 0, o + ibl <= b.count else { return nil }
            let ni = ibl / idxSize
            let istart = indices.count
            for ii in 0..<ni {
                let io = o + ii * idxSize
                let idx: UInt32 = idxSize == 4
                    ? (UInt32(b[io]) | (UInt32(b[io+1]) << 8) | (UInt32(b[io+2]) << 16) | (UInt32(b[io+3]) << 24))
                    : (UInt32(b[io]) | (UInt32(b[io+1]) << 8))
                indices.append(UInt32(vbase) + idx)
            }
            o += ibl
            submeshes.append(.init(material: material, indexStart: istart, indexCount: ni))
            // 非末尾 submesh 后有 0x00 padding(数量不定)→ 跳到下一个非零字节。
            if si < submeshCount - 1 {
                while o < b.count && b[o] == 0 { o += 1 }
            }
        }
        guard !positions.isEmpty, !indices.isEmpty else { return nil }
        return MDLGeometry(positions: positions, normals: normals, uvs: uvs, indices: indices, submeshes: submeshes)
    }
}

// MARK: - 3D 场景对象(逐对象:几何 + 世界矩阵 + 材质)

struct Model3DMaterial {
    var baseColorTex: String?      // 解析到的 .tex 相对路径
    var color: SIMD3<Float> = SIMD3(1, 1, 1)
    var brightness: Float = 1
    var alpha: Float = 1
    var translucent: Bool = false  // blending=translucent → alpha 混合;否则不透明
    var lighting: Bool = false      // LIGHTING combo(generic4 默认开=1,genericimage4 默认关=0;combos 显式覆盖)
}

struct Model3DObject {
    let id: Int
    let name: String
    let meshPath: String           // .mdl 相对路径(去重建 GPU 缓冲用)
    let geometry: MDLGeometry
    var world: simd_float4x4
    // 逐 submesh 材质(submesh 顺序与 geometry.submeshes 对齐;不足则用 [0])
    var materials: [Model3DMaterial]
}

/// 透视场景运行时:解析几何/材质/节点树 + 单-context 脚本宿主,支持**逐帧求值**(live 相机动画/轨道)
/// 或一次性烘焙(脚本过多时)。土星(75脚本)逐帧 live;太阳系(765脚本)烘焙到 settled 时刻。
final class Scene3DRuntime {
    struct NodeInfo {
        let parent: Int?
        let originRaw: Any?; let scaleRaw: Any?; let anglesRaw: Any?; let sizeRaw: Any?
        let originScripted: Bool; let scaleScripted: Bool; let anglesScripted: Bool
    }
    /// 轨道显示层(guidao effect 全屏后处理:读 sim 算出的 shared 轨道参数画椭圆)。inner=P1-P4,outer=P5-P9。
    struct OrbitLayer { let id: Int; let inner: Bool; let statics: [String: [Float]] }
    private(set) var orbitLayers: [OrbitLayer] = []
    /// 太阳辉光屏幕精灵(sun-1/2/4 投影辉光;flarez/lense=lens flare 元素,定位在太阳屏幕位置)。
    struct SunSprite { let id: Int; let name: String; let image: String; let sizePx: SIMD2<Float>; let isFlare: Bool; let horizontal: Bool }
    private(set) var sunSprites: [SunSprite] = []
    /// 太阳的投影屏幕 UV(sun-1 origin 脚本写 shared.sunScreenX/Y;0..1,0,0=左上)。lens flare 定位用。
    func sunScreenUV() -> SIMD2<Float> {
        guard let h = host else { return SIMD2(0.5, 0.5) }
        return SIMD2(Float(h.sharedNum("sunScreenX") ?? 0.5), Float(h.sharedNum("sunScreenY") ?? 0.5))
    }
    /// 精灵投影后的屏幕 UV(0..1,0,0=左上)。origin 脚本返回 value=(uvX-0.5, -uvY+0.5) → uv=(v.x+0.5, 0.5-v.y)。
    func spriteScreenUV(_ id: Int) -> SIMD2<Float> {
        let v = host?.evalUniform(key: "\(id):__origin", comps: 3) ?? [0, 0, 0]
        return SIMD2((v.count > 0 ? v[0] : 0) + 0.5, 0.5 - (v.count > 1 ? v[1] : 0))
    }
    /// 精灵 scale 脚本当前值(屏幕尺寸 = sizePx × scale × 因子)。
    func spriteScale(_ id: Int) -> Float {
        (host?.evalUniform(key: "\(id):__scale", comps: 1) ?? [0]).first ?? 0
    }
    private(set) var models: [Model3DObject] = []     // world 由 recompute() 更新
    /// 场景方向光/点光(土星/太阳系:sun 驱动 ldirectional+lpoint;创建昼夜终止线 N·L 漫反射)。
    /// id=节点 id(world 由 recompute 求出,光源世界位置=worldsById[id].columns.3),directional=方向光否则点光。
    struct SceneLight { let id: Int; let directional: Bool; let color: SIMD3<Float>; let intensity: Float; let radius: Float }
    private(set) var lights: [SceneLight] = []
    /// general.ambientcolor(脚本则取 value 静态;lwe/WE 默认 vec3(0))。喂 LIGHTING 材质 g_LightAmbientColor。
    private(set) var ambientColor: SIMD3<Float> = .zero
    private(set) var worldsById: [Int: simd_float4x4] = [:]   // 逐帧同步给 GPU 用
    private(set) var layerOverrides: [Int: [String: SIMD3<Float>]] = [:]  // Main 模拟 getLayer 设的 origin/scale/angles
    private(set) var uiRoots: Set<Int> = []                   // 屏幕 UI 根容器 id(其下层走正交屏幕坐标)
    private var nodes: [Int: NodeInfo] = [:]
    private var nodeOrder: [Int] = []
    private let host: Scene3DScriptHost?
    var scriptCount: Int { host?.registered ?? 0 }
    /// 任一**模型**的节点祖先链含脚本驱动的 origin/angles(=有限时长关键帧入场:从下升起+倾入再 hold)。
    /// 土星(3589454154):全部件挂在根 459 下,459.origin/angles 是 Vec3 关键帧脚本(t0→t30 升起+倾入,t>30 hold
    /// 末关键帧=settled)。判据用于「入场动画」逐帧驱动模型(相机静态→动模型不漂)。日心太阳系靠 getLayer/currentFocus
    /// 公转(走 scene3DSolarOrbit 另一路),其行星节点本身 origin 不带脚本 → 此判据不会误命中(且 solarOrbit 优先级更高)。
    var hasModelKeyframeAnim: Bool {
        for m in models {
            var cur: Int? = m.id, depth = 0
            while let c = cur, let n = nodes[c], depth < 64 {
                if n.originScripted || n.anglesScripted { return true }
                cur = n.parent; depth += 1
            }
        }
        return false
    }
    /// 入场动画 settled 时刻(秒)= 模型祖先链 origin/angles 脚本 scriptproperties 里所有关键帧时间(键以 't' 开头,
    /// 如 t1..t4 / tt1 / t22)的最大值。脚本在末关键帧之后 hold,故此后停刷模型可省 CPU(土星=30)。算不出 → 0(=不停刷)。
    var modelAnimEndTime: Double {
        var maxT: Double = 0
        var seen = Set<Int>()
        func scanScript(_ raw: Any?) {
            guard let d = raw as? [String: Any], d["script"] != nil,
                  let sp = d["scriptproperties"] as? [String: Any] else { return }
            for (k, v) in sp where k.hasPrefix("t") {
                let num = (v as? NSNumber)?.doubleValue
                    ?? ((v as? [String: Any])?["value"] as? NSNumber)?.doubleValue
                if let t = num, t.isFinite, t > maxT { maxT = t }
            }
        }
        for m in models {
            var cur: Int? = m.id, depth = 0
            while let c = cur, let n = nodes[c], depth < 64 {
                if !seen.contains(c) { seen.insert(c); scanScript(n.originRaw); scanScript(n.anglesRaw) }
                cur = n.parent; depth += 1
            }
        }
        return maxT
    }
    /// 任一**模型**的祖先链含「持续自转」angles 脚本(随时间累积无终点,settle 后仍转)。与有限入场关键帧
    /// (modelAnimEndTime 后 hold)区分:持续自转脚本用 `engine.frametime` 逐帧累加角度。
    /// 土星 3589454154「土星赤道中心」455/458/468:`accumulatedTime += engine.frametime;
    ///   value.y = accumulatedTime/(baseRotationTime/(f·shared.kv))*360 % 360` → 行星/环/陨石绕 Y 轴持续旋转。
    ///   kv 由对象 700 visible 脚本从 1 ramp 到 100(t=2..36s,绑用户属性 kv=100),稳态环约 0.76°/s(≈8 分钟/圈,
    ///   清晰可见;这是用户所见 WE「环动态」的真实机制)。入场 459 origin/angles 用 `engine.runtime` 关键帧插值
    ///   (到末关键帧 hold)不引用 frametime → 不命中。命中 → render3D 在 settle 后仍逐帧 recompute(相机静态,不漂)。
    var hasContinuousModelRotation: Bool {
        var seen = Set<Int>()
        func isSpin(_ raw: Any?) -> Bool {
            guard let d = raw as? [String: Any], let src = d["script"] as? String else { return false }
            return src.contains("engine.frametime")
        }
        for m in models {
            var cur: Int? = m.id, depth = 0
            while let c = cur, let n = nodes[c], depth < 64 {
                if !seen.contains(c) { seen.insert(c); if isSpin(n.anglesRaw) || isSpin(n.originRaw) { return true } }
                cur = n.parent; depth += 1
            }
        }
        return false
    }
    var sharedDump: String { host?.sharedDump() ?? "no host" }
    func sharedJSON() -> String { host?.sharedJSON() ?? "{}" }
    func sharedHas(_ key: String) -> Bool { host?.sharedHas(key) ?? false }
    func sharedNum(_ key: String) -> Double? { host?.sharedNum(key) }
    /// 评估所有节点 visible 脚本(读宿主 shared)→ 返回**自身 visible 脚本判定为 false 的节点 id 集**。
    /// 太阳系灵动岛/通知/媒体面板等靠 visible 脚本条件显隐;静态壁纸无交互→脚本判 false→该子树隐藏。
    func hiddenNodeIds() -> Set<Int> {
        guard let h = host else { return [] }
        var hidden = Set<Int>()
        for id in nodeOrder { if h.evalLayerVisible(id: id) == false { hidden.insert(id) } }
        return hidden
    }
    /// 该层或任一祖先在 hidden 集里 → 隐藏(WE 父组 visible 继承,含脚本判定)。
    func isHiddenByAncestor(_ id: Int, hidden: Set<Int>) -> Bool {
        var cur: Int? = id, d = 0
        while let c = cur, d < 64 { if hidden.contains(c) { return true }; cur = nodes[c]?.parent; d += 1 }
        return false
    }
    /// 取轨道层某 uniform 当前值(脚本→对 shared 求值;否则静态)。material=去掉|中文的材质名。
    func orbitUniform(_ layerId: Int, _ material: String, comps: Int) -> [Float] {
        if host?.hasUniform("\(layerId):\(material)") == true {
            return host!.evalUniform(key: "\(layerId):\(material)", comps: comps)
        }
        if let ol = orbitLayers.first(where: { $0.id == layerId }), let s = ol.statics[material], !s.isEmpty {
            if comps == 1 { return [s[0]] }
            return s.count >= 3 ? Array(s.prefix(3)) : [s[0], s[0], s[0]]
        }
        return [Float](repeating: 0, count: comps)
    }
    func textValue(id: Int) -> String? { host?.textValue(id: id) }
    func scriptValue(id: Int, prop: String) -> SIMD3<Float>? { host?.value(id: id, prop: prop) }

    /// 解析出的主光照(喂 3D frag):L=世界空间「表面→光源」方向(归一化)、颜色、强度、环境光。
    /// 方向光:用其世界旋转的前向(-Z)再取反指向光源;点光:光源世界位置 → 朝原点(场景中心=被照天体)。
    /// sun 驱动脚本已在 bake/recompute 后写入 worldsById,故必须在 recompute() 之后调用。返回 nil = 无光照(2D 等)。
    struct ResolvedLight { let dir: SIMD3<Float>; let color: SIMD3<Float>; let intensity: Float; let ambient: SIMD3<Float> }
    func lightInfo() -> ResolvedLight? {
        guard let l = lights.first else { return nil }   // 土星/太阳系均单主光(directional 优先 or 唯一 point)
        let main = lights.first(where: { $0.directional }) ?? l
        let w = worldsById[main.id] ?? matrix_identity_float4x4
        let pos = SIMD3(w.columns.3.x, w.columns.3.y, w.columns.3.z)
        let fwd = SIMD3(w.columns.2.x, w.columns.2.y, w.columns.2.z)   // 世界 +Z 列(旋转编码的光源方向)
        var dir: SIMD3<Float>
        if !main.directional && simd_length(pos) > 0.05 {
            dir = simd_normalize(pos)                                   // 点光有真实位置:朝原点天体
        } else if simd_length(fwd) > 1e-5 {
            dir = simd_normalize(fwd)
        } else {
            dir = SIMD3(0, 0, 1)
        }
        let i = max(0, min(main.intensity, 8)) / 8.0 * 2.0
        return ResolvedLight(dir: dir, color: main.color, intensity: min(i, 1.5), ambient: ambientColor)
    }

    // MARK: - 方向光 / 阴影(土星:scene.general.lightconfig directional+directionalshadow=1)
    //  方向光 id=259(ldirectional)依 shared.sun_pos* 朝太阳;环(462)/陨石(479)是 shadow caster 投在行星(456)→
    //  行星赤道出现暗带(经典土星环影),正好落在 HUD 时钟/信息文字处 → 白字得以读出。我们原 model3d_fragment
    //  只 albedo×color×brightness 零光照 → 行星均匀亮、白字被冲掉。补 N·L 漫反射 + 环阴影暗带。
    private(set) var directionalLightId: Int?
    private(set) var pointLightId: Int?
    private(set) var pointLightVisible = false
    private(set) var sunModelId: Int?            // 视觉太阳模型(485/520);其世界位置=光源方向锚
    private(set) var planetModelId: Int?         // 行星(球体01)
    private(set) var ringModelId: Int?           // 土星环(投影 caster)

    /// 行星中心世界坐标(阴影正交相机的注视点)。
    func planetCenterWorld() -> SIMD3<Float> {
        guard let pid = planetModelId, let w = worldsById[pid] else { return SIMD3(0, 0, -2) }
        return SIMD3(w.columns.3.x, w.columns.3.y, w.columns.3.z)
    }
    /// 行星世界半径估计(用三轴 scale 取最大;球体01 是单位球,世界半径≈scale)。
    func planetWorldRadius() -> Float {
        guard let pid = planetModelId, let w = worldsById[pid] else { return 1.5 }
        let sx = simd_length(SIMD3(w.columns.0.x, w.columns.0.y, w.columns.0.z))
        let sy = simd_length(SIMD3(w.columns.1.x, w.columns.1.y, w.columns.1.z))
        let sz = simd_length(SIMD3(w.columns.2.x, w.columns.2.y, w.columns.2.z))
        return max(sx, max(sy, sz))
    }
    /// 指向太阳的单位方向(世界空间,= 行星→太阳模型)。N·L 与阴影相机都用它。
    func sunWorldDirection() -> SIMD3<Float> {
        let c = planetCenterWorld()
        if let sid = sunModelId, let w = worldsById[sid] {
            let sp = SIMD3(w.columns.3.x, w.columns.3.y, w.columns.3.z)
            let d = sp - c
            if simd_length(d) > 1e-4 { return simd_normalize(d) }
        }
        if let h = host {
            let sp = SIMD3(Float(h.sharedNum("sun_posx") ?? -1), Float(h.sharedNum("sun_posy") ?? 0), Float(h.sharedNum("sun_posz") ?? 0))
            if simd_length(sp) > 1e-4 { return simd_normalize(sp) }
        }
        return simd_normalize(SIMD3(-1, 0, 0))
    }

    init?(source: SceneSource) {
        guard let sj = source.data(for: "scene.json"),
              let root = (try? JSONSerialization.jsonObject(with: sj)) as? [String: Any],
              let objects = root["objects"] as? [[String: Any]] else { return nil }
        func intOf(_ v: Any?) -> Int? { (v as? NSNumber)?.intValue ?? (v as? String).flatMap { Int($0) } }
        func isScript(_ v: Any?) -> Bool { (v as? [String: Any])?["script"] != nil }

        // 脚本宿主:注册全部对象全部 {script} 属性(共享单 context 的 globalThis.shared)。WP_NO_3D_SCRIPTS=1 关。
        let h: Scene3DScriptHost? = WPEnv.vars["WP_NO_3D_SCRIPTS"] == nil ? Scene3DScriptHost() : nil
        var hasHeliocentricSim = false   // 日心太阳系模拟(Main 写 shared.currentFocus)→ 启用 Date.now() sim 时钟,行星公转
        if let h = h {
            for o in objects {
                guard let id = intOf(o["id"]) else { continue }
                for (prop, v) in o {
                    guard let d = v as? [String: Any], let src = d["script"] as? String else { continue }
                    // 静态识别日心模拟:仅 Main(VSOP87D)脚本写 `shared.currentFocus`。土星等无 → Date.now() 行为不变(零回归)。
                    if src.contains("shared.currentFocus") { hasHeliocentricSim = true }
                    var sp = d["scriptproperties"] as? [String: Any] ?? [:]
                    // 调试覆盖(默认遵 pkg 值):mode(1中点log/2线性/3/4真比例)、initialFocus(0总览 1-13天体)。
                    if let m = WPEnv.vars["WP_SOLAR_MODE"], let mv = Double(m), sp["mode"] != nil { sp["mode"] = mv }
                    if let fc = WPEnv.vars["WP_SOLAR_FOCUS"], let fv = Double(fc), sp["initialFocus"] != nil { sp["initialFocus"] = fv }
                    let sv: SIMD3<Float> = (prop == "scale") ? SIMD3(1, 1, 1) : Self.f3(d["value"], .zero)
                    h.register(id: id, prop: prop, source: src, scriptProps: sp, staticValue: sv)
                }
            }
            // 仅日心太阳系启用 sim 时钟(Date.now() 随 engine.runtime 推进 → 行星公转);WP_NO_SOLAR_ORBIT=1 关。
            if hasHeliocentricSim && WPEnv.vars["WP_NO_SOLAR_ORBIT"] == nil { h.enableSimClock() }
            // 安装真实场景层(name/id→层对象),让 Main 模拟 thisScene.getLayer(name).origin=轨道位置 命中真层。
            var ldefs: [[String: Any]] = []
            for o in objects { if let id = intOf(o["id"]) { ldefs.append(["id": id, "name": (o["name"] as? String) ?? ""]) } }
            h.installLayers(ldefs)
            h.runInit()
            // 轨道显示层(guidao/guidao2 effect):注册其 effect uniform 脚本(读 shared 算椭圆参数)。
            for o in objects {
                guard let id = intOf(o["id"]), let effects = o["effects"] as? [[String: Any]] else { continue }
                for ef in effects {
                    let file = (ef["file"] as? String) ?? ""
                    let inner = file.contains("/guidao/")
                    let outer = file.contains("/guidao2/")
                    guard inner || outer else { continue }
                    guard let passes = ef["passes"] as? [[String: Any]], let p0 = passes.first,
                          let csv = p0["constantshadervalues"] as? [String: Any] else { continue }
                    var statics: [String: [Float]] = [:]
                    for (k, v) in csv {
                        let mat = String(k.split(separator: "|").first ?? Substring(k)).trimmingCharacters(in: .whitespaces)
                        if let d = v as? [String: Any], let src = d["script"] as? String {
                            h.registerUniform(key: "\(id):\(mat)", source: src)
                        } else if statics[mat] == nil {
                            statics[mat] = Self.parseFloats(v)
                        }
                    }
                    orbitLayers.append(OrbitLayer(id: id, inner: inner, statics: statics))
                }
            }
            // 太阳辉光精灵(sun-1/2/4:origin 自投影 FIXED_CAM_DIST)+ lens flare(flarez/lense:定位在太阳屏幕处)。
            for o in objects {
                guard let id = intOf(o["id"]) else { continue }
                let name = (o["name"] as? String) ?? ""
                let img = (o["image"] as? String) ?? ""
                let originScript = (o["origin"] as? [String: Any])?["script"] as? String
                let isProjSun = (originScript?.contains("FIXED_CAM_DIST") ?? false) || (originScript?.contains("sunScreen") ?? false)
                let isFlare = name.lowercased().contains("flare") || img.contains("flarez") || img.contains("lense")
                guard isProjSun || isFlare else { continue }
                if let src = originScript { h.registerUniform(key: "\(id):__origin", source: src) }
                if let sc = o["scale"] as? [String: Any], let scsrc = sc["script"] as? String { h.registerUniform(key: "\(id):__scale", source: scsrc) }
                let sizeP = Self.parseFloats(o["size"])
                let horizontal = name.contains("zh") || img.contains("flarezh")
                sunSprites.append(SunSprite(id: id, name: name, image: img,
                                            sizePx: SIMD2(sizeP.first ?? 256, sizeP.count > 1 ? sizeP[1] : (sizeP.first ?? 256)),
                                            isFlare: isFlare && !isProjSun, horizontal: horizontal))
            }
        }
        self.host = h

        // 节点树(全对象,含纯变换中间节点)
        for o in objects {
            guard let id = intOf(o["id"]) else { continue }
            nodes[id] = NodeInfo(parent: intOf(o["parent"]),
                                 originRaw: o["origin"], scaleRaw: o["scale"], anglesRaw: o["angles"], sizeRaw: o["size"],
                                 originScripted: isScript(o["origin"]),
                                 scaleScripted: isScript(o["scale"]),
                                 anglesScripted: isScript(o["angles"]))
            nodeOrder.append(id)
        }
        // 识别**屏幕 UI 根**(Phase1 判据):parent=None 顶层容器,其子树用画布像素坐标(任一后代静态 origin |x|或|y|>50)。
        // 土星里 = 395「Sykm UI 4k」(dock 图标 1780,340 这种)。其下全是屏幕族(正交渲染);其余=3D 族(透视)。
        var rootCanvas: [Int: Bool] = [:]
        for id in nodeOrder {
            let o = Self.f3(nodes[id]?.originRaw, .zero)
            if abs(o.x) > 50 || abs(o.y) > 50 { rootCanvas[chainTopStatic(id)] = true }
        }
        uiRoots = Set(rootCanvas.filter { $0.value }.keys)

        // 模型对象(几何 + 材质;world 占位,recompute 填)
        var geoCache: [String: MDLGeometry] = [:]
        // 模型可见性:bool / {user,value:bool}(短形,如星座/网格 value:false→隐藏)/ {user:{condition}}(长形,
        // 分辨率变体,无 override 无法解→渲)/ {script}(默认渲,脚本运行时判)。修旧 `as NSNumber` 对 dict 判不出
        // → 星座(constellation)/网格(coordinategrid)的 value:false 被当可见渲出亮白网格(WE 是暗背景)。
        func modelVisible(_ v: Any?) -> Bool {
            if let n = v as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue }
            if let d = v as? [String: Any] {
                if d["script"] != nil { return true }
                if let bv = d["value"] as? NSNumber, CFGetTypeID(bv) == CFBooleanGetTypeID() { return bv.boolValue }
                if let bv = d["value"] as? Bool { return bv }
            }
            return true
        }
        // 光源 / 太阳 / 行星 / 环 识别(土星环影所需:方向光朝向 + caster/receiver 几何)。
        for o in objects {
            guard let id = intOf(o["id"]) else { continue }
            if let lt = o["light"] as? String {
                if lt == "ldirectional" { directionalLightId = id }
                else if lt == "lpoint" {
                    pointLightId = id
                    if let n = o["visible"] as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() { pointLightVisible = n.boolValue }
                    else if let bv = o["visible"] as? Bool { pointLightVisible = bv }
                    else { pointLightVisible = true }   // 缺省可见(土星 433 显式 false → 点光关闭)
                }
            }
        }
        for o in objects {
            guard let id = intOf(o["id"]), let modelPath = o["model"] as? String else { continue }
            if !modelVisible(o["visible"]) { continue }
            let geo: MDLGeometry
            if let g = geoCache[modelPath] { geo = g }
            else if let d = source.data(for: modelPath), let g = MDLGeometry.parse(d) { geoCache[modelPath] = g; geo = g }
            else { continue }
            var mats: [Model3DMaterial] = []
            for sm in geo.submeshes { mats.append(Self.resolveMaterial(path: sm.material, source: source)) }
            if mats.isEmpty { mats = [Model3DMaterial()] }
            let nm = o["name"] as? String ?? ""
            // 行星(球体01)/ 环(木星环)/ 视觉太阳(name=sun) 标记。
            if modelPath.contains("球体01") { planetModelId = id }
            else if modelPath.contains("木星环") { ringModelId = id }
            if nm == "sun" && sunModelId == nil { sunModelId = id }
            models.append(Model3DObject(id: id, name: nm, meshPath: modelPath,
                                        geometry: geo, world: matrix_identity_float4x4, materials: mats))
        }
        // 场景光源(WE 3D 光照:ldirectional/lpoint;color/intensity/radius 取 pkg,缺省 WE 默认)。
        // 光源 id 也是节点 → world 由 recompute 求出,光源世界位置/方向喂 frag 做 N·L 漫反射昼夜终止线。
        for o in objects {
            guard let id = intOf(o["id"]), let light = o["light"] as? String else { continue }
            let dir = light == "ldirectional"
            let color = Self.f3(o["color"], SIMD3(1, 1, 1))   // WE 默认白光
            let intensity = Self.parseFloats(o["intensity"]).first ?? 1.0
            let radius = Self.parseFloats(o["radius"]).first ?? 0
            lights.append(SceneLight(id: id, directional: dir, color: color, intensity: intensity, radius: radius))
        }
        if let gen = root["general"] as? [String: Any] { ambientColor = Self.f3(gen["ambientcolor"], .zero) }
        if models.isEmpty { return nil }
    }

    /// 父链顶端(静态,用于分类)。
    func chainTopStatic(_ id: Int) -> Int {
        var cur = id, depth = 0
        while let p = nodes[cur]?.parent, nodes[p] != nil, depth < 64 { cur = p; depth += 1 }
        return cur
    }
    /// 该层是否屏幕空间 UI(chainTop 在 uiRoots → 正交渲染);否则 3D 浮空(透视)。
    func isScreenLayer(_ id: Int) -> Bool { uiRoots.contains(chainTopStatic(id)) }

    /// 屏幕族层的**画布盒尺寸** = size字段 × 该层**自身局部 scale**(排除父链的 3D 缩放)。
    /// 文字按此盒适配(否则用纹理自然像素会过大重叠)。无 size → nil(用纹理自然像素兜底)。
    func canvasBoxSize(_ id: Int) -> SIMD2<Float>? {
        guard let n = nodes[id], let s = n.sizeRaw as? String else { return nil }
        let p = s.split(separator: " ").compactMap { Float($0) }   // size 是 2 分量 "w h"(f3 要 3 分量,不能用)
        guard p.count >= 2, p[0] > 0, p[1] > 0 else { return nil }
        let sc = n.scaleScripted ? (host?.value(id: id, prop: "scale") ?? Self.f3(n.scaleRaw, SIMD3(1,1,1))) : Self.f3(n.scaleRaw, SIMD3(1,1,1))
        return SIMD2(p[0] * sc.x, p[1] * sc.y)
    }

    /// 屏幕族层的**画布像素位置**:沿父链累加各节点局部 origin(脚本节点用宿主脚本返回=画布像素,
    /// 静态节点用静态值),到 UI 根为止。不走 worldsById(那是 3D-TRS 把 UI 缩成微小值)。平移为主。
    func canvasOrigin(_ id: Int) -> SIMD2<Float> {
        var sum = SIMD2<Float>(0, 0); var cur = id; var depth = 0
        while let n = nodes[cur], depth < 64 {
            let scripted = n.originScripted
            let o: SIMD3<Float> = (scripted ? (host?.value(id: cur, prop: "origin") ?? Self.f3(n.originRaw, .zero)) : Self.f3(n.originRaw, .zero))
            sum.x += o.x; sum.y += o.y
            if uiRoots.contains(cur) { break }      // 到 UI 根(屏幕锚)停
            guard let p = n.parent, nodes[p] != nil else { break }
            cur = p; depth += 1
        }
        return sum
    }

    /// 推进脚本一帧(逐帧 live 用,time=自加载起的 sim 秒)。
    func tick(time: Double, dt: Double) { host?.tick(runtime: time, frametime: dt) }
    /// 从 0 累进到 toTime(烘焙用:脚本过多不逐帧时,在加载时跑到 settled 时刻冻结)。
    func bake(toTime: Double, steps: Int = 90) {
        guard let host = host else { return }
        let d = toTime / Double(max(1, steps))
        for s in 0..<steps { host.tick(runtime: Double(s + 1) * d, frametime: d) }
    }
    /// 用当前脚本态(或静态)重算所有模型世界矩阵 → models[i].world。
    func recompute() {
        // 太阳系:Main 模拟经 thisScene.getLayer(name).origin/scale/angles=… 驱动行星位置/半径/自转。
        // tick 后读回这些 override,优先级最高(覆盖静态/透传脚本)。土星等无 getLayer 写入则为空,零影响。
        layerOverrides = host?.readLayerOverrides() ?? [:]
        var locals: [Int: simd_float4x4] = [:]
        for (id, n) in nodes {
            let ov = layerOverrides[id]
            func res(_ scripted: Bool, _ prop: String, _ raw: Any?, _ def: SIMD3<Float>) -> SIMD3<Float> {
                if let o = ov?[prop] { return o }   // Main 模拟设的最高优先级
                if scripted, let host = host, let v = host.value(id: id, prop: prop) { return v }
                return Self.f3(raw, def)
            }
            let origin = res(n.originScripted, "origin", n.originRaw, .zero)
            let scale = res(n.scaleScripted, "scale", n.scaleRaw, SIMD3(1, 1, 1))
            var angles = res(n.anglesScripted, "angles", n.anglesRaw, .zero)
            // 角度:Main 模拟 override 恒为度;脚本自转常输出度(0-360);静态弧度。override 或任一分量 >2π → 度转弧度。
            if ov?["angles"] != nil || abs(angles.x) > 6.3 || abs(angles.y) > 6.3 || abs(angles.z) > 6.3 { angles = angles * (Float.pi / 180) }
            locals[id] = Self.trs(t: origin, anglesRad: angles, s: scale)
        }
        var cache: [Int: simd_float4x4] = [:]
        func world(_ id: Int, _ depth: Int = 0) -> simd_float4x4 {
            if let w = cache[id] { return w }
            guard depth < 64, let n = nodes[id] else { return matrix_identity_float4x4 }
            let l = locals[id] ?? matrix_identity_float4x4
            let w = (n.parent != nil && nodes[n.parent!] != nil) ? world(n.parent!, depth + 1) * l : l
            cache[id] = w; return w
        }
        // 全节点世界矩阵(不止模型:2D HUD/dock 层的脚本驱动父节点位置也在内,供引擎覆盖 2D 层 origin)。
        worldsById.removeAll(keepingCapacity: true)
        for id in nodeOrder { worldsById[id] = world(id) }
        for i in models.indices { models[i].world = worldsById[models[i].id] ?? matrix_identity_float4x4 }
    }

    // MARK: - 静态解析助手
    /// 解析 constantshadervalue 静态值 → [Float](标量/字符串"a b c"/{value:...})。
    static func parseFloats(_ v: Any?) -> [Float] {
        if let n = v as? NSNumber { return [n.floatValue] }
        if let s = v as? String { return s.split(separator: " ").compactMap { Float($0) } }
        if let d = v as? [String: Any] { return parseFloats(d["value"]) }
        return []
    }
    static func f3(_ v: Any?, _ d: SIMD3<Float>) -> SIMD3<Float> {
        func parseVec(_ s: String) -> SIMD3<Float> {
            let p = s.split(separator: " ").compactMap { Float($0) }
            if p.count >= 3 { return SIMD3(p[0], p[1], p[2]) }
            if p.count == 1 { return SIMD3(p[0], p[0], p[0]) }
            return d
        }
        if let s = v as? String { return parseVec(s) }
        if let dict = v as? [String: Any] {
            if let s = dict["value"] as? String { return parseVec(s) }
            if let inner = dict["value"] as? [String: Any], let s = inner["value"] as? String { return parseVec(s) }
        }
        return d
    }

    /// 解析模型材质 json:textures[0]=baseColor、constantshadervalues 的 Color/brightness/Alpha、blending。
    static func resolveMaterial(path: String, source: SceneSource) -> Model3DMaterial {
        var m = Model3DMaterial()
        guard let d = source.data(for: path),
              let root = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let passes = root["passes"] as? [[String: Any]], let p0 = passes.first else { return m }
        m.translucent = (p0["blending"] as? String) == "translucent"
        // LIGHTING combo:WE 着色器各有默认值 —— generic4.frag `LIGHTING default:1`(行星/天体默认受光);
        // genericimage4.frag `LIGHTING default:0`(天空盒/UI 平涂)。pkg 的 combos 显式键再覆盖默认。
        // 旧码只在 combos.LIGHTING==1 时开 → 土星行星(generic4 且 combos 无 LIGHTING 键)漏光照而平涂。
        let shader = (p0["shader"] as? String) ?? ""
        m.lighting = (shader == "generic4")   // 仅 generic4 默认开;其余(genericimage4 等)默认关
        if let combos = p0["combos"] as? [String: Any], let lit = combos["LIGHTING"] as? NSNumber {
            m.lighting = lit.intValue == 1
        }
        if let texs = p0["textures"] as? [Any], let first = texs.first as? String, !first.isEmpty {
            // 贴图名 → .tex 相对路径:优先 materials/<name>.tex,回退 <name>.tex
            m.baseColorTex = "materials/\(first).tex"
            if source.data(for: m.baseColorTex!) == nil {
                m.baseColorTex = "\(first).tex"
            }
        }
        if let csv = p0["constantshadervalues"] as? [String: Any] {
            func f(_ k: String) -> Float? {
                if let n = csv[k] as? NSNumber { return n.floatValue }
                if let s = csv[k] as? String { return Float(s.split(separator: " ").first ?? "") }
                return nil
            }
            if let c = csv["Color"] as? String {
                let v = c.split(separator: " ").compactMap { Float($0) }
                if v.count >= 3 { m.color = SIMD3(v[0], v[1], v[2]) }
            }
            if let br = f("brightness") { m.brightness = br }
            if let a = f("Alpha") ?? f("alpha") { m.alpha = a }
        }
        return m
    }

    /// 3D TRS:T(origin) · Rz · Ry · Rx · S(scale)(列主序,右手系;angles 为弧度欧拉)。
    static func trs(t: SIMD3<Float>, anglesRad a: SIMD3<Float>, s: SIMD3<Float>) -> simd_float4x4 {
        let (cx, sx) = (cos(a.x), sin(a.x))
        let (cy, sy) = (cos(a.y), sin(a.y))
        let (cz, sz) = (cos(a.z), sin(a.z))
        let rx = simd_float4x4(columns: (SIMD4(1,0,0,0), SIMD4(0,cx,sx,0), SIMD4(0,-sx,cx,0), SIMD4(0,0,0,1)))
        let ry = simd_float4x4(columns: (SIMD4(cy,0,-sy,0), SIMD4(0,1,0,0), SIMD4(sy,0,cy,0), SIMD4(0,0,0,1)))
        let rz = simd_float4x4(columns: (SIMD4(cz,sz,0,0), SIMD4(-sz,cz,0,0), SIMD4(0,0,1,0), SIMD4(0,0,0,1)))
        let scale = simd_float4x4(diagonal: SIMD4(s.x, s.y, s.z, 1))
        var tm = matrix_identity_float4x4
        tm.columns.3 = SIMD4(t.x, t.y, t.z, 1)
        return tm * rz * ry * rx * scale
    }
}
