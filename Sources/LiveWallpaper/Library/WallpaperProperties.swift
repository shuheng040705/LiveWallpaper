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
    // 所属分组标题(WE 的 type='group' 标记):nil=顶层。pkg 用 group 分组时按 order 归组;
    // pkg 无分组(全库 138 张里 126 张如此)→ 全部 nil → 面板扁平,与 WE 一致(不强行分组)。
    var group: String? = nil
    // type=None 的说明文本(作者头/分节说明 HTML 文本):只显示不可交互,渲染为次要文字。
    var isText: Bool = false
    // 各类型的取值约束
    var sliderMin: Double = 0
    var sliderMax: Double = 1
    var sliderStep: Double = 0.01
    var comboOptions: [(label: String, value: String)] = []

    /// SwiftUI 的 `Slider(in:)` 要求 lowerBound <= upperBound,且零宽区间会异常。
    /// 某些壁纸的 slider 属性 min/max 反了(或缺 max 默认 1 < min)→ 直接用 `min...max`
    /// 会触发 "Range requires lowerBound <= upperBound" 致整个 app 崩溃(打不开/黑屏)。
    /// 这里始终返回一个合法、非零宽的闭区间,任何脏数据都不再崩。
    var sliderRange: ClosedRange<Double> {
        let lo = Swift.min(sliderMin, sliderMax)
        var hi = Swift.max(sliderMin, sliderMax)
        if !(hi > lo) { hi = lo + Swift.max(abs(sliderStep), 0.0001) }   // 零宽/相等 → 撑开一点
        return lo...hi
    }

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
    // 缓存 general.localization 的「当前语言译文表」(key 如 "ui_av_amp" → 已选语言的富文本值)。
    // 属性 text 字段在很多 WE 壁纸里是本地化 KEY(不是直接文案),真正文案在 general.localization
    // 的各语言子表里。这里按 path 缓存已挑好语言的扁平表,parse 时拿 key 查表得显示文案。
    private var localizationCache: [String: [String: String]] = [:]
    private func cachedProps(_ folderURL: URL) -> [String: Any] {
        let path = folderURL.appendingPathComponent("project.json").path
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let c = propsCache[path] { return c }
        let general = (((try? Data(contentsOf: URL(fileURLWithPath: path)))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })?
            .flatMap { $0["general"] as? [String: Any] }) ?? [:]
        let props = (general["properties"] as? [String: Any]) ?? [:]
        propsCache[path] = props
        localizationCache[path] = Self.pickLocalization(general["localization"] as? [String: Any])
        return props
    }

    /// 取某壁纸已选语言的本地化译文表(可能为空)。依赖 cachedProps 已填充(properties() 入口先调它)。
    private func cachedLocalization(_ folderURL: URL) -> [String: String] {
        let path = folderURL.appendingPathComponent("project.json").path
        cacheLock.lock(); defer { cacheLock.unlock() }
        return localizationCache[path] ?? [:]
    }

    /// 从 general.localization 的多语言字典里挑一套语言并扁平成 [key: 文案]。
    /// 语言选择(中文优先):zh-chs(简体,WE 实测用此键)→ 其它 zh 变体(zh-cn/zh-hant/zh)→
    /// en-us → 任意一套。WE 的语言键带连字符(zh-chs / en-us),容错地用前缀/包含匹配。
    /// 缺 localization 表 → 返回空表(parse 走原 raw text,零回归)。
    static func pickLocalization(_ loc: [String: Any]?) -> [String: String] {
        guard let loc = loc, !loc.isEmpty else { return [:] }
        // 把每个语言子表归一成 [String:String]。
        func table(_ k: String) -> [String: String]? {
            guard let raw = loc[k] as? [String: Any] else { return nil }
            var t: [String: String] = [:]
            for (kk, vv) in raw { if let s = vv as? String { t[kk] = s } }
            return t.isEmpty ? nil : t
        }
        let keys = Array(loc.keys)
        // 1) 精确/前缀匹配简体中文。WE 实测键为 "zh-chs"。
        func firstMatch(_ pred: (String) -> Bool) -> [String: String]? {
            keys.first(where: pred).flatMap { table($0) }
        }
        if let t = table("zh-chs") { return t }
        if let t = firstMatch({ let l = $0.lowercased(); return l.hasPrefix("zh-chs") || l == "zh-cn" || l == "zh-hans" || l.hasPrefix("zh-hans") }) { return t }
        if let t = firstMatch({ $0.lowercased().hasPrefix("zh") }) { return t }   // 任意 zh 变体(含 zh-hant 繁体)
        if let t = table("en-us") { return t }
        if let t = firstMatch({ $0.lowercased().hasPrefix("en") }) { return t }
        // 兜底:任意一套非空译文。
        for k in keys { if let t = table(k) { return t } }
        return [:]
    }

    /// 读取某壁纸的全部可调属性(含当前值),**按 WE 的 order 排序并归组**。
    /// 归组规则(对齐 WE 属性面板):按 order 升序走查;遇到 `type='group'` 标记开启新分组,
    /// 其后的属性都归该组,直到下一个 group 标记;首个 group 之前的属性是顶层(group=nil)。
    /// pkg 没有 group 标记 → 全部顶层 → 面板扁平(满足「pkg 没分类我们也不分类」)。
    /// type=None 的 HTML 文本(作者头/分节说明)保留为 isText 标签显示;纯分隔条/图片横幅跳过。
    func properties(forID id: String, folderURL: URL) -> [WallpaperProperty] {
        let props = cachedProps(folderURL)
        guard !props.isEmpty else { return [] }
        // 壁纸自带的本地化译文表(可能为空)。属性 text 若是本地化 KEY 且表里命中 → 用译文。
        let loc = cachedLocalization(folderURL)

        // 先按 order 排好序再走查(归组依赖顺序)。
        let entries = props.compactMap { (k, raw) -> (key: String, p: [String: Any], order: Int)? in
            guard let p = raw as? [String: Any] else { return nil }
            return (k, p, (p["order"] as? NSNumber)?.intValue ?? 999)
        }.sorted { $0.order < $1.order }

        var out: [WallpaperProperty] = []
        var currentGroup: String? = nil
        for e in entries {
            let p = e.p
            let typeRaw = (p["type"] as? String) ?? ""
            // text 字段可能是本地化 KEY(如 "ui_av_amp")→ 通过壁纸自带 localization 表解析成显示文案;
            // 命不中表(或无表)→ 用原始 text(可能本就是直接文案或多语整段)。
            let rawText = Self.resolveText((p["text"] as? String) ?? "", loc)

            // 分组标记:开启新分组(本身不作为可渲染属性)。
            if typeRaw == "group" {
                let title = Self.cleanLabel(rawText)
                currentGroup = title.isEmpty ? nil : title
                continue
            }

            // type=None 或 type="text":作者头 / 分节标题 / 说明文本。WE 用这两者渲染面板的分节标题
            //   (如「★ 镜头设置 ★」「♦ 统一时钟设置」)+ 说明块 + 时钟格式帮助 → 是面板的结构骨架,**应显示**
            //   (旧码把 type="text" 落到 default:continue 全跳过 → 面板只剩扁平一串开关、丢了所有分节标题)。
            //   纯分隔条(只有装饰符)/纯图片横幅跳过,其余作文本显示;condition 由 visibleProperties 过滤
            //   (含字面 "false" 的调试/隐藏说明会被新修的 evalSingle 正确隐藏)。
            if typeRaw.isEmpty || typeRaw == "text" {
                let plain = Self.plainText(rawText)
                if plain.isEmpty || Self.isDecorativeOnly(plain) || (rawText.contains("<img") && plain.isEmpty) { continue }
                // ⭐分节标题(★/♦ 开头的 text):这是 pkg 用 text 项表达的「分类边界」(白影没有 type='group',
                //   而是用 ★ 镜头设置 ★ / ♦ 统一时钟设置 这类带符号的分节标题把后续属性归到各类下)。
                //   命中即**开启一个新折叠分组**:标题=取该 header 的首段(★...★ / ♦... 标题行,去掉后面的
                //   帮助正文);若 header 还带正文(如时钟格式说明),把正文作为该组内第一条 isText 说明显示。
                //   下一个 ★/♦ header 之前的所有属性都归本组(currentGroup),与原 type='group' 同套渲染管线。
                if let title = Self.sectionHeaderTitle(rawText) {
                    currentGroup = title
                    let body = Self.sectionHeaderBody(rawText, title: title)
                    if !body.isEmpty && !Self.isDecorativeOnly(body) {
                        var t = WallpaperProperty(id: e.key, type: .label, label: body, order: e.order)
                        t.group = currentGroup
                        t.isText = true
                        t.condition = (p["condition"] as? String) ?? ""
                        out.append(t)
                    }
                    continue
                }
                var t = WallpaperProperty(id: e.key, type: .label, label: plain, order: e.order)
                t.group = currentGroup
                t.isText = true
                t.condition = (p["condition"] as? String) ?? ""   // text 说明也带 condition(如 clock_lunar_calendar_info)
                out.append(t)
                continue
            }

            let kind: WallpaperProperty.Kind
            switch typeRaw {
            case "color": kind = .color
            case "bool": kind = .bool
            case "slider": kind = .slider
            case "combo": kind = .combo
            case "textinput": kind = .textinput
            default: continue   // scenetexture / usershortcut 等:暂不渲染
            }
            let label = Self.cleanLabel(rawText.isEmpty ? e.key : rawText)
            if label.isEmpty { continue }

            var prop = WallpaperProperty(id: e.key, type: kind, label: label, order: e.order)
            prop.group = currentGroup
            prop.condition = (p["condition"] as? String) ?? ""
            prop.supported = Self.isSupported(key: e.key, kind: kind, label: label)
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
                    // 选项 label 也可能是本地化 KEY(多数壁纸是直接文案,命不中表则原样回退)。
                    let lbl = Self.cleanLabel(Self.resolveText((o["label"] as? String) ?? valStr, loc))
                    return (lbl, valStr)
                }
            }
            out.append(prop)
        }
        return out   // 已按 order 顺序
    }

    /// 该壁纸是否用 WE 的 type='group' 做了分组(决定面板是否分组渲染)。
    func hasGroups(forID id: String, folderURL: URL) -> Bool {
        properties(forID: id, folderURL: folderURL).contains { $0.group != nil }
    }

    /// 把属性/组/选项的 text 字段解析成「最终的原始文案串」(尚未去 HTML)。
    /// 若 text 命中壁纸自带 localization 表(text 本身就是本地化 KEY,如 "ui_av_amp")→ 返回该语言译文
    /// (含 HTML,交由 cleanLabel/plainText 去标签);否则原样返回(text 本就是直接文案或多语整段)。
    /// 空表(壁纸无 localization)→ 永远原样返回 → 零回归。
    static func resolveText(_ text: String, _ loc: [String: String]) -> String {
        if text.isEmpty { return text }
        if let translated = loc[text] { return translated }
        return text
    }

    /// 去 HTML 标签 + 解实体 + 压空白,得纯文本(用于 type=None 说明文本整段显示)。
    /// 与 cleanLabel 不同:不只取第一段,保留整段可读文字(作者头是多语整块)。
    static func plainText(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "(?i)<br\\s*/?>", with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        // &nbsp; 以及作者漏写分号的裸 &nbsp(WE 富文本里常见)都当空格。
        t = t.replacingOccurrences(of: "&nbsp;?", with: " ", options: .regularExpression)
             .replacingOccurrences(of: "&amp;", with: "&")
             .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
        // 压多余空白
        t = t.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 是否只由装饰/分隔符组成(WE 作者常用 ━─│┃═= 等画分隔线 → 我们用折叠分组,分隔线是噪点)。
    static func isDecorativeOnly(_ plain: String) -> Bool {
        let decorative = Set("━─│┃═=-_~·•＝＿※*▪▫◆◇■□●○☆★ ")
        return !plain.isEmpty && plain.allSatisfy { decorative.contains($0) }
    }

    /// 分节标题符号:WE 作者用 ★ / ♦ 开头的 text 项做属性面板的「分类标题」(没有 type='group' 时的
    /// 替代分组方式,如白影 3497488774:★ 镜头设置 ★ / ★ 交互设置 ★ / ♦ 统一时钟设置 …)。
    /// 普通说明 text(FAQ、各时段说明、农历格式帮助)不含这些符号 → 不会被误判成分类标题。
    private static let sectionHeaderMarks = Set("★♦◆◇■□▶▼")

    /// 若该 text 项是一个分节标题(首段含 ★/♦ 等分类符号),返回**干净的分类标题**(去 HTML、去前后
    /// 装饰符与空白);否则返回 nil。标题只取 header 的首段(<br> 之前),后面的帮助正文不并入标题。
    static func sectionHeaderTitle(_ rawText: String) -> String? {
        // cleanLabel 已经取首段非空文本(白影 header 的标题就在第一段:「♦ 统一时钟设置」在帮助正文之前)。
        let first = cleanLabel(rawText)
        guard !first.isEmpty, first.contains(where: { sectionHeaderMarks.contains($0) }) else { return nil }
        // 去掉首尾的分类符号与空白,留下纯标题文字(「★ 镜头设置 ★」→「镜头设置」)。
        let trimSet = CharacterSet(charactersIn: "★♦◆◇■□▶▼ \t")
        let title = first.trimmingCharacters(in: trimSet)
        return title.isEmpty ? first : title   // 去符号后空了(纯符号)→ 退回原首段(不会发生,纯符号已被 isDecorativeOnly 拦)
    }

    /// 取分节标题 header 在标题行之后剩余的帮助正文(如时钟格式说明);没有正文返回空串。
    /// 用整段 plainText 减去标题首段:plainText 把 <br> 折成空格连续成一段,故按「标题文字」首次出现处
    /// 之后的部分即为正文(找不到标题/无剩余 → 空)。
    static func sectionHeaderBody(_ rawText: String, title: String) -> String {
        let whole = plainText(rawText)
        // 用 cleanLabel 的首段(含符号)作为切割锚,确保把整行标题(★ 镜头设置 ★)都切掉。
        let firstLine = cleanLabel(rawText)
        if let r = whole.range(of: firstLine) {
            return String(whole[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // 退化:按纯标题文字切。
        if let r = whole.range(of: title) {
            let after = String(whole[r.upperBound...])
            // 跳过标题后可能残留的尾部符号(★)。
            return after.trimmingCharacters(in: CharacterSet(charactersIn: "★♦◆◇■□▶▼ \t"))
        }
        return ""
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
        // textinput:多数没有渲染钩子(时钟/媒体 format 串、自定义语言 token 表)→ 标「开发中」。
        // 但**时段阈值**(ts_morning/ts_daytime/ts_sunset/ts_night)已接通引擎:用户改这几个 H:MM
        //   会改变昼夜时段切换时刻(SceneModel.effectiveTimeStage 读 ts_* 用户覆盖)→ 这些 textinput 真生效,
        //   标灰「开发中」是误判,应可用。其余 textinput 仍未接(format 串读 pkg 默认不读用户覆盖)→ 保持标灰。
        if kind == .textinput {
            let wiredTextInputs: Set<String> = ["ts_morning", "ts_daytime", "ts_sunset", "ts_night"]
            return wiredTextInputs.contains(key)
        }
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
        // ⭐字面布尔条件 "false" / "true"(WE 作者用来**永久隐藏**调试/未启用属性,如白影的
        //   alignmentfliph / rate / show_hc / debug / character_hp 等 condition:"false")。旧码把 "false"
        //   当作属性 key 去查 → 查不到 → return true(不挡)→ 这些本该隐藏的属性被错误显示在面板上。
        //   先在求值入口判定字面量:false/0 → 隐藏,true/1 → 显示(对齐 WE PropertyParser 把 "false" 解析成
        //   恒假条件)。注意只对**裸字面量**生效,不影响 "x.value == false" 这类比较(下面 == 分支处理)。
        let lit = expr.trimmingCharacters(in: .whitespaces).lowercased()
        if lit == "false" || lit == "0" { return false }
        if lit == "true" || lit == "1" { return true }
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
        // ⭐裸布尔条件 "<key>.value"(无 ==/!=,WE 最常见:`ff_ds.value`、`bf_particle.value && bf_ds.value`):
        //   求该属性当前布尔值(真→显示)。前缀 "!" = 取反。旧码无此分支 → 一律 return true 不挡 →
        //   「显示详细设置」开关(bf_ds/ff_ds)关闭时详细项(大小/速度/不透明度/数量/颜色)仍展开(用户报)。
        var e = expr
        var negate = false
        while e.hasPrefix("!") { negate.toggle(); e = String(e.dropFirst()).trimmingCharacters(in: .whitespaces) }
        let key = e.replacingOccurrences(of: ".value", with: "").trimmingCharacters(in: .whitespaces)
        if let prop = allProps.first(where: { $0.id == key }) {
            let s = Self.valueAsString(value(forID: id, property: prop, folderURL: folderURL)).lowercased()
            let truth = (s == "true") || ((Double(s) ?? 0) != 0)   // bool→true/false;slider/number→≠0
            return negate ? !truth : truth
        }
        return true   // 引用未知属性 → 不挡显示
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
        "ui_browse_properties_alignmentfliph": "水平翻转",
        "ui_browse_properties_alignmentflipv": "垂直翻转",
        "ui_browse_properties_rate": "速率",
        "ui_browse_properties_alignment": "对齐",
        "ui_browse_properties_offset": "偏移",
        "ui_browse_properties_zoom": "缩放",
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
                       .replacingOccurrences(of: "&nbsp;?", with: " ", options: .regularExpression)
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
