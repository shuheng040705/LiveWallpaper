import Foundation
import Combine
import simd

/// 一个壁纸可调属性(来自 project.json 的 general.properties)。
/// WE 属性类型:color / bool / slider / combo / text / textinput / group / scenetexture。
/// 我们生成 UI 的只有前 4 种可交互类型;text/group 仅作标签。
struct WallpaperProperty: Identifiable {
    let id: String          // 属性 key(也是 scene.json 里 user 字段引用的名字)
    let type: Kind
    let label: String       // 显示文案(去 HTML、翻译本地化 key)
    let order: Int          // 显示顺序
    var condition: String = ""   // 显示条件(如 "clock.value == true"),空=总是显示
    var supported: Bool = true   // 当前渲染是否真支持(否则面板里标灰)
    // 各类型的取值约束
    var sliderMin: Double = 0
    var sliderMax: Double = 1
    var sliderStep: Double = 0.01
    var comboOptions: [(label: String, value: String)] = []

    enum Kind: String {
        case color, bool, slider, combo, textinput
        case label   // text/group/其它:只显示不可交互
    }

    /// 当前值(覆盖值优先,否则默认值)。存成统一的字符串/数值表示。
    enum Value: Equatable {
        case color(SIMD3<Float>)   // 0-1 RGB
        case bool(Bool)
        case number(Double)
        case string(String)
    }
}

/// 解析 + 持久化某个壁纸的属性。覆盖值存 UserDefaults(key = "wp.<id>.<propKey>")。
/// ObservableObject:覆盖值存在 UserDefaults(非 @Published 存储属性),所以 setValue/reset
/// 写完后手动 objectWillChange.send(),让设置面板里观察本 store 的视图自然重算重读 value。
final class WallpaperPropertyStore: ObservableObject {
    static let shared = WallpaperPropertyStore()
    private let d = UserDefaults.standard

    // project.json 的 general.properties 解析缓存(按 path)。loadOverrides 现在给每个属性都求值
    // (条件层显隐需要属性默认),一个场景 123 个属性逐个 rawDefault 会把 project.json 重复解析上百遍;
    // reloadInPlace 又频繁触发 → 缓存一次解析。project.json 一个会话内不变,失效无需考虑。
    private let cacheLock = NSLock()
    private var propsCache: [String: [String: Any]] = [:]
    private func cachedProps(_ folderURL: URL) -> [String: Any] {
        let path = folderURL.appendingPathComponent("project.json").path
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let c = propsCache[path] { return c }
        let props = (((try? Data(contentsOf: URL(fileURLWithPath: path)))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })?
            .flatMap { $0["general"] as? [String: Any] }?["properties"] as? [String: Any]) ?? [:]
        propsCache[path] = props
        return props
    }

    /// 读取某壁纸的全部可调属性(含当前值)。folderURL 下的 project.json。
    func properties(forID id: String, folderURL: URL) -> [WallpaperProperty] {
        let props = cachedProps(folderURL)
        guard !props.isEmpty else { return [] }

        var out: [WallpaperProperty] = []
        for (key, raw) in props {
            guard let p = raw as? [String: Any] else { continue }
            let typeRaw = (p["type"] as? String) ?? ""
            let order = (p["order"] as? NSNumber)?.intValue ?? 999
            let label = Self.cleanLabel((p["text"] as? String) ?? key)

            let kind: WallpaperProperty.Kind
            switch typeRaw {
            case "color": kind = .color
            case "bool": kind = .bool
            case "slider": kind = .slider
            case "combo": kind = .combo
            case "textinput": kind = .textinput
            default: kind = .label   // text/group/scenetexture 等:仅标签
            }
            // 只保留可交互的 + 有意义的标签(纯 HTML 横幅跳过)。
            guard kind != .label else { continue }
            // 纯 HTML 横幅/作者推广(关注/赞赏/链接):跳过。
            // 判据:原文本含 <a>/<img>/http 链接,或清理后为空,或标签过长(说明是段文案不是属性名)。
            let rawText = (p["text"] as? String) ?? ""
            let isBanner = rawText.contains("<a ") || rawText.contains("<img") ||
                           rawText.contains("http") || rawText.contains("space.bilibili")
            // 只跳过真正的横幅(含链接/图片)或清理后为空的标签。**不再按长度砍** ——
            // 标签现在取第一段(短),旧的 `label.count > 24` 会把双语控件标签全误杀。
            if label.isEmpty || isBanner { continue }

            var prop = WallpaperProperty(id: key, type: kind, label: label, order: order)
            prop.condition = (p["condition"] as? String) ?? ""
            prop.supported = Self.isSupported(key: key, kind: kind, label: label)
            if kind == .slider {
                prop.sliderMin = (p["min"] as? NSNumber)?.doubleValue ?? 0
                prop.sliderMax = (p["max"] as? NSNumber)?.doubleValue ?? 1
                prop.sliderStep = (p["step"] as? NSNumber)?.doubleValue ?? 0.01
            }
            if kind == .combo, let opts = p["options"] as? [[String: Any]] {
                prop.comboOptions = opts.compactMap { o in
                    guard let v = o["value"] else { return nil }
                    // 审计修复(#3):combo 选项值的数字走 anyAsString 归一(整数去 ".0"),
                    // 与 valueAsString / VecParse.unwrap 一致,避免选项值 "3" 与求值出的 "3.0" 不匹配。
                    let valStr = Self.anyAsString(v)
                    let lbl = Self.cleanLabel((o["label"] as? String) ?? valStr)
                    return (lbl, valStr)
                }
            }
            out.append(prop)
        }
        return out.sorted { $0.order < $1.order }
    }

    /// 当前渲染是否真支持这个属性。
    /// 支持:图层/粒子可见性开关(bool)、颜色(color→solidlayer/tint/粒子染色)、
    ///      图层变换滑块(位置/大小/缩放)、环境粒子开关与颜色(阳光/微尘/雨雪雾)。
    /// 不支持(标灰):时钟/日期文字、鼠标拖尾/交互、音频可视化/音量、语音、文本输入。
    private static func isSupported(key: String, kind: WallpaperProperty.Kind, label: String) -> Bool {
        let l = label.lowercased()
        // 明确尚未实现的功能(独立模块,非属性映射能解决)。
        // 已实现并移出本表:时钟/日期、鼠标拖尾、阳光/微尘、音频可视化(频谱条颜色/数量)。
        // 仍未实现:音量/语音(无音频播放模块)、fps。
        let unsupported = ["音量", "volume", "语音", "voice", "soundtrack", "fps", "帧率"]
        if unsupported.contains(where: { l.contains($0) }) { return false }
        // textinput 一律不支持(没有对应渲染钩子)。
        if kind == .textinput { return false }
        // 其余(可见性 bool、配色 color、位置/大小 slider、环境粒子开关/颜色/数量)默认支持。
        return true
    }

    /// 某属性的当前值(覆盖优先,否则 project.json 默认)。
    func value(forID id: String, property: WallpaperProperty, folderURL: URL) -> WallpaperProperty.Value {
        let key = storeKey(id, property.id)
        // 有覆盖值则用覆盖。
        if d.object(forKey: key) != nil {
            switch property.type {
            case .color:
                if let s = d.string(forKey: key) { return .color(Self.parseColor(s)) }
            case .bool: return .bool(d.bool(forKey: key))
            case .slider: return .number(d.double(forKey: key))
            case .combo, .textinput: if let s = d.string(forKey: key) { return .string(s) }
            case .label: break
            }
        }
        return defaultValue(forID: id, property: property, folderURL: folderURL)
    }

    /// project.json 里的默认值。
    func defaultValue(forID id: String, property: WallpaperProperty, folderURL: URL) -> WallpaperProperty.Value {
        let raw = rawDefault(forID: id, key: property.id, folderURL: folderURL)
        switch property.type {
        case .color:
            if let s = raw as? String { return .color(Self.parseColor(s)) }
            return .color(SIMD3(1, 1, 1))
        case .bool:
            return .bool((raw as? Bool) ?? false)
        case .slider:
            // 审计修复(#6):滑块缺 value 时回退到该 slider 的 min(对齐 lwe:CPropertySlider 以
            // min 为默认)。旧代码钉 0,会让正区间(如缩放 0.5..2)塌缩到 0。property.sliderMin 已在
            // properties() 里从 p["min"] 读入(缺 min 时其自身默认 0),故连 min 都没有时自然再退 0。
            // 有 value 时仍走 raw 的正常返回路径。
            return .number((raw as? NSNumber)?.doubleValue ?? property.sliderMin)
        case .combo, .textinput:
            // 审计修复(#3):combo 默认值的数字也走 anyAsString 归一(整数去 ".0"),
            // 与选项值串一致,否则默认选中项匹配不到对应选项。
            if let n = raw as? NSNumber { return .string(Self.anyAsString(n)) }
            return .string((raw as? String) ?? "")
        case .label:
            return .string("")
        }
    }

    /// 写入覆盖值。
    func setValue(_ value: WallpaperProperty.Value, forID id: String, propertyKey: String) {
        let key = storeKey(id, propertyKey)
        switch value {
        case .color(let c):
            d.set(String(format: "%.6f %.6f %.6f", c.x, c.y, c.z), forKey: key)
        case .bool(let b): d.set(b, forKey: key)
        case .number(let n): d.set(n, forKey: key)
        case .string(let s): d.set(s, forKey: key)
        }
        objectWillChange.send()   // 通知设置面板重算重读(色块/值即时刷新)
    }

    /// 求值属性的显示条件(如 "clock.value == true" / "tuowei.value == false")。
    /// 条件里引用的是别的属性 key 的当前值。空条件=总显示。只支持 WE 常见的简单等式。
    func conditionMet(_ condition: String, forID id: String, allProps: [WallpaperProperty], folderURL: URL) -> Bool {
        let cond = condition.trimmingCharacters(in: .whitespaces)
        guard !cond.isEmpty else { return true }
        // 解析 "<key>.value <op> <rhs>"(op ∈ ==,!=)。多条件用 && / || 连接。
        // 简化:按 && 拆(WE 绝大多数是单条件或 && 串联)。
        let parts = cond.components(separatedBy: "&&")
        for part in parts {
            if !evalSingle(part.trimmingCharacters(in: .whitespaces), id: id, allProps: allProps, folderURL: folderURL) {
                return false
            }
        }
        return true
    }

    private func evalSingle(_ expr: String, id: String, allProps: [WallpaperProperty], folderURL: URL) -> Bool {
        // 形如 "clock.value == true"
        let ops = ["==", "!="]
        for op in ops {
            guard let r = expr.range(of: op) else { continue }
            let lhs = String(expr[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
            let rhs = String(expr[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            let key = lhs.replacingOccurrences(of: ".value", with: "")
            guard let prop = allProps.first(where: { $0.id == key }) else { return true } // 引用未知属性→不挡
            let cur = value(forID: id, property: prop, folderURL: folderURL)
            let curStr = Self.valueAsString(cur)
            let rhsClean = rhs.replacingOccurrences(of: "\"", with: "").lowercased()
            let eq = curStr.lowercased() == rhsClean
            return op == "==" ? eq : !eq
        }
        return true   // 无法解析的条件不挡显示
    }

    private static func valueAsString(_ v: WallpaperProperty.Value) -> String {
        switch v {
        case .bool(let b): return b ? "true" : "false"
        case .number(let n):
            // 审计修复(#3):与 VecParse.unwrap 的条件求值统一 —— 整数值去掉无意义的 ".0"
            // (旧 "\(n)" 对 3.0 产 "3.0",而条件 RHS / combo 值常是 "3" → 比较失败)。非整数保留小数。
            return (n == n.rounded()) ? String(Int(n)) : "\(n)"
        case .string(let s): return s
        case .color(let c):
            // 审计修复(#8):与 SceneModel.VecParse.unwrap 的 color 串形统一 —— 用
            // %.6f(产 "1.000000 0.000000 0.000000"),而非 "\(c.x)..."(产 "1.0 0.0 0.0")。
            // 否则两套口径比 condition 相等时错配。只改本文件即可对齐。
            return String(format: "%.6f %.6f %.6f", c.x, c.y, c.z)
        }
    }

    /// 审计修复(#3):把任意 JSON 标量(combo 选项/默认值)归一成字符串 —— 数字整数去 ".0",
    /// 非整数保留小数,非数字按原样插值。与 valueAsString(.number) / VecParse.unwrap 的数字串形一致,
    /// 让 combo 选项值、combo 默认、条件 RHS 三处比较口径统一。
    private static func anyAsString(_ v: Any) -> String {
        if let n = v as? NSNumber {
            // Bool 也是 NSNumber:保持 true/false 原样,不走数值分支。
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
            let d = n.doubleValue
            return (d == d.rounded()) ? String(Int(d)) : "\(d)"
        }
        return "\(v)"
    }

    /// 重置某壁纸的所有覆盖(回到 project.json 默认)。
    func reset(forID id: String, folderURL: URL) {
        let props = properties(forID: id, folderURL: folderURL)
        for p in props { d.removeObject(forKey: storeKey(id, p.id)) }
        objectWillChange.send()
    }

    /// 是否有任何覆盖。
    func hasOverrides(forID id: String, folderURL: URL) -> Bool {
        properties(forID: id, folderURL: folderURL).contains { d.object(forKey: storeKey(id, $0.id)) != nil }
    }

    // MARK: - 内部

    private func storeKey(_ id: String, _ propKey: String) -> String { "wp.\(id).\(propKey)" }

    private func rawDefault(forID id: String, key: String, folderURL: URL) -> Any? {
        guard let p = cachedProps(folderURL)[key] as? [String: Any] else { return nil }
        return p["value"]
    }

    /// "0.8 0.73 0.63" → SIMD3。
    static func parseColor(_ s: String) -> SIMD3<Float> {
        let parts = s.split(separator: " ").compactMap { Float($0) }
        guard parts.count >= 3 else { return SIMD3(1, 1, 1) }
        return SIMD3(parts[0], parts[1], parts[2])
    }

    /// WE 内置本地化词条(ui_* key)→ 中文。常见的几十个。
    private static let localization: [String: String] = [
        "ui_browse_properties_scheme_color": "配色方案",
        "ui_browse_properties_background_color": "背景颜色",
        "ui_browse_properties_color": "颜色",
        "ui_browse_properties_opacity": "不透明度",
        "ui_browse_properties_alpha": "不透明度",
        "ui_browse_properties_speed": "速度",
        "ui_browse_properties_scale": "缩放",
        "ui_browse_properties_strength": "强度",
        "ui_browse_properties_brightness": "亮度",
        "ui_browse_properties_saturation": "饱和度",
        "ui_browse_properties_contrast": "对比度",
        "ui_browse_properties_volume": "音量",
        "ui_browse_properties_size": "大小",
        "ui_browse_properties_amount": "数量",
        "ui_browse_properties_direction": "方向",
        "ui_browse_properties_intensity": "强度",
        "ui_browse_properties_blur": "模糊",
        "ui_browse_properties_audio_responsive": "音频响应",
    ]

    /// 去掉 HTML 标签、翻译本地化 key、压缩空白,取可读文案。
    static func cleanLabel(_ s: String) -> String {
        // 1) 本地化 key 直接查表。
        if let zh = localization[s] { return zh }
        // 2) WE 作者常把控件名写成「中文<br>English<br><br>」多语/多行。取**第一段非空**文本作标签,
        //    绝不把多语整段拼接 —— 否则标签又长又含双语,既难读又会被横幅长度启发式误杀(把整页控件
        //    砍到只剩「配色方案」)。先按 <br> 拆行,逐段去 HTML,取第一段有内容的。
        let segments = s.replacingOccurrences(of: "(?i)<br\\s*/?>", with: "\n", options: .regularExpression)
                        .components(separatedBy: "\n")
        var t = ""
        for seg in segments {
            let x = seg.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                       .replacingOccurrences(of: "&nbsp;", with: " ")
                       .trimmingCharacters(in: .whitespacesAndNewlines)
            if !x.isEmpty { t = x; break }
        }
        // 3) 还是 ui_ 开头(没翻译到的)→ 取最后一段,下划线转空格,首字母大写。
        if t.hasPrefix("ui_") {
            let last = t.split(separator: "_").last.map(String.init) ?? t
            return last.capitalized
        }
        return t
    }
}
