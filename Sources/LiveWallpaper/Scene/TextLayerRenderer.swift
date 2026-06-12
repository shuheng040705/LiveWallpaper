import Foundation
import CoreText
import CoreGraphics
import AppKit

/// 文本图层(时钟/日期等)→ RGBA8 纹理。
/// WE 的 text 图层文本由 **JS 脚本** 每帧生成(见 WEScript);我们跑真脚本拿字符串。
/// 脚本不可用 / 无脚本时:能按系统时间算的(时钟/日期/星期/问候)用旧近似;否则静态串。
enum TextLayerKind {
    case script(WEScript)   // 真 WE JS 脚本驱动(时钟/日期/…),每秒跑一次拿字符串
    case clock      // HH:MM(近似回退)
    case date       // 日期(近似回退)
    case dayOfWeek  // 星期(SAT)
    case greeting   // 按时段问候(GOOD MORNING/AFTERNOON/EVENING)
    case staticText(String)
}

struct TextLayerDesc {
    var kind: TextLayerKind
    var color: SIMD3<Float>
    var pointSize: CGFloat          // 渲染字号(放大求清晰,= renderPt);屏上真实大小另算
    var srcPointSize: CGFloat = 32  // pkg 原始 pointsize:屏上字高 = srcPointSize × scale(WE 真义)
    var useScreenPointSize = false  // 锚点 size/media 文本:屏上按 srcPointSize×scale,不塞 box、不按 box 折行
    var use12h: Bool = false
    var align: String = "center"   // left/center/right(horizontalalign)
    var verticalAlign: String = "center"   // top/center/bottom(verticalalign)
    var fontName: String = "systemfont_consolas"   // WE 字体名(systemfont_* / pkg 字体)
    // WE 文本图层的显式 size(画布单位,未乘 scale)。非 nil 时:文本按 size×scale 的盒子定尺寸
    // (WE 行为——盒子定屏上大小,不靠 pointsize 的自然像素),保持字形纵横比按高度适配进盒子,
    // 多余空间按 align 放置。nil = autosize(取文本纹理自然像素,旧行为;无显式 size 的静态文本/问候)。
    var boxSizePx: SIMD2<Float>? = nil
}

enum TextLayerRenderer {
    /// 渲染当前文本到 RGBA8 像素。返回 (pixels, w, h)。
    /// 审计修复(#1):新增可选 simTime(引擎累计 sim 时间,秒),透传给脚本驱动的 currentString,
    ///   让脚本图层动画与引擎 sim-time 同步;默认 nil 时脚本回退墙钟(旧行为)。
    static func render(_ desc: TextLayerDesc, simTime: Double? = nil) -> (pixels: [UInt8], width: Int, height: Int)? {
        let str = currentString(desc, simTime: simTime)
        guard !str.isEmpty else { return nil }

        let nsColor = NSColor(srgbRed: CGFloat(desc.color.x), green: CGFloat(desc.color.y),
                              blue: CGFloat(desc.color.z), alpha: 1)
        let font = resolveFont(desc.fontName, size: desc.pointSize)
        let para = NSMutableParagraphStyle()
        para.alignment = desc.align == "left" ? .left : (desc.align == "right" ? .right : .center)
        // 折行:WE 文本框有显式宽度时,长文本应按框宽 word-wrap(超宽换行),而不是无限单行被
        //   下游按盒子缩放压扁。para.lineBreakMode = .byWordWrapping 让 CoreText 按 boundingRect
        //   的宽度上限折行。
        para.lineBreakMode = .byWordWrapping

        var attrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: nsColor, .paragraphStyle: para
        ]

        // 描边/阴影/字重脚手架:
        //   TextLayerDesc 目前**没有** stroke/shadow/bold/italic 字段(见 SceneModel,本文件不可改),
        //   故无法数据驱动这些效果。下面保留实现接线点(注释掉的赋值即「补字段后」该怎么写),
        //   需 SceneModel 给 TextLayerDesc 补:
        //     - var strokeColor: SIMD3<Float>? 与 var strokeWidthPx: CGFloat?  → 描边
        //     - var shadowColor: SIMD3<Float>?、var shadowOffsetPx: SIMD2<Float>?、var shadowBlurPx: CGFloat? → 阴影
        //     - var bold: Bool / var italic: Bool(或 var weight: Float) → 字重/斜体(同时影响 resolveFont 取带 weight 的字体变体)
        //   补字段后,把下面注释解开并用 desc 的对应字段替换占位:
        //
        //   if let sc = desc.strokeColor, let sw = desc.strokeWidthPx, sw > 0 {
        //       // 负值 = 同时填充+描边(WE 描边在字形外侧叠加);正值只描边镂空。
        //       attrs[.strokeColor] = NSColor(srgbRed: CGFloat(sc.x), green: CGFloat(sc.y), blue: CGFloat(sc.z), alpha: 1)
        //       // strokeWidth 是相对字号的百分比(负=填充+描边)。WE 给的是像素宽 → 折算成 -%。
        //       attrs[.strokeWidth] = -(sw / desc.pointSize) * 100.0
        //   }
        //   if let shc = desc.shadowColor {
        //       let shadow = NSShadow()
        //       shadow.shadowColor = NSColor(srgbRed: CGFloat(shc.x), green: CGFloat(shc.y), blue: CGFloat(shc.z), alpha: 1)
        //       if let off = desc.shadowOffsetPx { shadow.shadowOffset = NSSize(width: CGFloat(off.x), height: CGFloat(-off.y)) } // y 取负:翻转坐标系内向下
        //       shadow.shadowBlurRadius = desc.shadowBlurPx ?? 0
        //       attrs[.shadow] = shadow
        //       // 注意:有阴影/描边时下面的 pad / boundingRect 需放大,避免效果被裁(见 pad 处)。
        //   }
        //   字重/斜体:在 resolveFont 内按 desc.bold/desc.italic 用 NSFontManager.convert(_:toHaveTrait:)
        //     施加 .boldFontMask/.italicFontMask(或 monospacedSystemFont(weight:))。当前无字段 → 用注册体本身的字重。
        attrs[.paragraphStyle] = para   // no-op 写回(保持 attrs 为 var);补字段解开上面赋值后可删此行。

        // 符号字形回退 + 加粗(月相 ☽/☾ 等):WE 在 Windows(CrossOver)用 Arial 渲符号——但实测 Windows Arial.TTF
        //   同样**不含** ☽(U+263D)/☾(U+263E),走 Windows 字体链回退到 Segoe UI Symbol(粗实月牙、亮)。
        //   macOS 上 Arial/Helvetica 也无该字形,CoreText 默认回退到 **Menlo**(等宽体,月牙细瘦、AA 边发暗
        //   → 形状不同 + 整体偏暗)。修法:对**基础字体渲不出**的字符,改用含该字形且更饱满的符号体
        //   (Arial Unicode MS,Arial 家族、macOS 自带、月牙更粗亮),并加细描边补偿小字号 AA 发暗
        //   —— 让 ☽/☾ 接近 WE 的亮实月牙。普通拉丁字(基础字体能渲)不受影响 → 不动其它壁纸时钟/日期外观。
        // WP_NO_MOONFIX=1 退回旧的「单一字体 + CoreText 自动回退」(A/B 诊断符号字形改动)。
        let attr = (ProcessInfo.processInfo.environment["WP_NO_MOONFIX"] != nil)
            ? NSAttributedString(string: str, attributes: attrs)
            : Self.makeAttributed(str, baseAttrs: attrs, baseFont: font, pointSize: desc.pointSize)

        // 折行宽度上限:优先用 WE 文本框的显式宽度 boxSizePx.x(画布单位)。注意 boxSizePx 未乘 scale,
        //   而这里的纹理按 pointSize 的自然像素绘制——两者单位不同(框是画布单位,纹理是字号像素)。
        //   直接拿 boxSizePx.x 作像素宽上限是「合理默认」近似:让超过该宽度的文本折行,避免极端压扁;
        //   纹理产出后下游再按盒子缩放。要做到与 WE 完全一致的换行点,需 SceneModel 提供「框宽对应的字号像素宽」
        //   (即把 boxSizePx 与最终屏上 scale 一起传进来);当前仅有未缩放 boxSizePx,故只能这样近似。
        // 折行宽度上限:**默认不折行**(单行,超宽则溢出框 —— 这是 lwe/WE 的真实行为:文本框 size 只作
        //   对齐/参考,limitwidth 没开时长文本溢出而非换行)。之前按 box.x 折行是我方自创,且 box.x 是画布单位、
        //   纹理是 renderPt 字号像素,单位错配 → 把本该一行的日期(框 1679 但 128 字号下宽 ~2000px)折成两行。
        //   `\n` 字面换行仍保留(byWordWrapping 不影响显式换行)。极宽单行不会让 boundingRect 膨胀(单行无指数爆炸)。
        //   TODO:WE 对象 limitwidth=true 时才按 maxwidth 折行 + maxrows 限行——补字段后在此据其折行。
        let maxWidth: CGFloat = 100000
        let bounds = attr.boundingRect(with: CGSize(width: maxWidth, height: 100000),
                                       options: [.usesLineFragmentOrigin, .usesFontLeading])
        // 留点边距,避免抗锯齿边缘被裁。
        // TODO: 补 stroke/shadow 字段后,这里 pad 应加上 max(strokeWidthPx, shadowBlurPx+|shadowOffset|),
        //   否则描边/阴影会被纹理边界裁掉。
        let pad: CGFloat = desc.pointSize * 0.3
        let w = Int(ceil(bounds.width + pad * 2)), h = Int(ceil(bounds.height + pad * 2))
        guard w > 0, h > 0, w < 8192, h < 2048 else { return nil }

        var px = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: cs, bitmapInfo: info) else { return nil }
        // 审计修复(#2):多行文本(如 "GOOD\nMORNING")在 flipped:false 的 CGContext 里用
        //   attr.draw(with:) 会上下颠倒(行序反转、且可能裁切)。改为翻转坐标系绘制:
        //   先把 CGContext 原点移到顶部再 scale(1,-1),让 y 向下增长,文本从上到下正确排版。
        //   单行(时钟)时高度只有一行,翻转后基线位置一致,外观不变。
        ctx.saveGState()
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsCtx
        attr.draw(with: CGRect(x: pad, y: pad, width: bounds.width, height: bounds.height),
                  options: [.usesLineFragmentOrigin, .usesFontLeading])
        NSGraphicsContext.restoreGraphicsState()
        ctx.restoreGState()

        // CGContext 产出的是 premultiplied alpha;场景 shader 按 straight alpha 采样混合,
        // 不还原会让半透明边缘发暗、甚至整块发白。这里把 RGB 除回 alpha → straight。
        for i in stride(from: 0, to: px.count, by: 4) {
            let a = px[i + 3]
            if a > 0 && a < 255 {
                px[i]   = UInt8(min(255, Int(px[i])   * 255 / Int(a)))
                px[i+1] = UInt8(min(255, Int(px[i+1]) * 255 / Int(a)))
                px[i+2] = UInt8(min(255, Int(px[i+2]) * 255 / Int(a)))
            }
        }
        return (px, w, h)
    }

    /// 当前应显示的字符串。脚本层跑真 JS;跑不出来回退到对应近似类型。
    /// 审计修复(#1):新增可选 simTime(引擎累计 sim 时间,秒),透传给脚本作时间源;默认 nil 时
    ///   脚本回退墙钟(旧行为)。注意:时钟/日期类脚本读的是 JSC 原生 `new Date()`(真实时间),
    ///   不受 simTime/runtime 影响;simTime 只服务脚本里的动画/平滑(engine.runtime/frametime)。
    static func currentString(_ desc: TextLayerDesc, simTime: Double? = nil) -> String {
        switch desc.kind {
        case .script(let s):
            switch s.runString(current: "", simTime: simTime) {
            case .string(let out): return out
            case .vec3, .failed:
                // 纯 media 文本(歌名/艺术家):没在播音乐时就该**空**,绝不能回退成时钟(否则歌名位置
                // 冒出一个时间 = 用户报的"music name 没识别")。其余脚本层多是时钟/日期 → 时钟近似兜底。
                if s.isMediaDriven { return "" }
                return fallbackClock(desc)
            }
        case .staticText(let s): return s
        case .clock: return fallbackClock(desc)
        case .date:
            let f = DateFormatter()
            f.dateFormat = "MM / dd"
            return f.string(from: Date())
        case .dayOfWeek:
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US")
            f.dateFormat = "EEE"
            return f.string(from: Date()).uppercased()
        case .greeting:
            // 铁律:不伪造内容。WE 的问候语由该层的 JS 脚本计算(本地化/自定义文案),不在 pkg 里写死。
            // 脚本能跑时 kind=.script 走真脚本;跑不了就不该凭空造 "GOOD MORNING"(英文、固定阈值=伪造)。
            // 退回空串(宁可不显示也不造假);要正确显示需实现该层 WE 脚本(见 ENGINE_PORT_TODO 脚本写回)。
            return ""
        }
    }

    private static func fallbackClock(_ desc: TextLayerDesc) -> String {
        let f = DateFormatter()
        f.dateFormat = desc.use12h ? "h:mm" : "HH:mm"
        return f.string(from: Date())
    }

    // MARK: - 符号字形回退

    /// 含 ☽/☾ 等符号字形且较饱满的回退体(macOS 自带)。优先 Arial Unicode MS(Arial 家族、月牙粗亮),
    /// 退 STIXGeneral / Apple Symbols。缓存命中名,避免每帧 NSFont(name:) 查找。
    private static var _symbolFallbackName: String? = {
        for n in ["Arial Unicode MS", "ArialUnicodeMS", "STIXGeneral-Regular", "STIXGeneral", "Apple Symbols", "AppleSymbols"] {
            if let f = NSFont(name: n, size: 12), (f as CTFont).hasGlyph(for: "\u{263E}") { return f.fontName }
        }
        return nil
    }()

    /// 构造属性串:逐字符检测**基础字体能否渲该字形**;不能→改用符号回退体 + 细描边(thicken/提亮)。
    /// 普通字(基础字体可渲)沿用 baseAttrs(零变化)。无可用符号体时退回纯 baseAttrs(= 旧 CoreText 自动回退)。
    private static func makeAttributed(_ str: String, baseAttrs: [NSAttributedString.Key: Any],
                                       baseFont: NSFont, pointSize: CGFloat) -> NSAttributedString {
        let ctBase = baseFont as CTFont
        // 快路:所有字符基础字体都能渲 → 直接用 baseAttrs(绝大多数时钟/日期/拉丁文本)。
        let needsFallback = str.unicodeScalars.contains { sc in
            // 跳过空白/控制/变体选择符(它们无独立字形,不触发回退)。
            if sc.value < 0x20 || sc.value == 0x20 || (0xFE00...0xFE0F).contains(sc.value) { return false }
            return !ctBase.hasGlyph(for: String(sc))
        }
        guard needsFallback, let symName = _symbolFallbackName,
              let symBase = NSFont(name: symName, size: pointSize) else {
            return NSAttributedString(string: str, attributes: baseAttrs)
        }
        let symFont = symBase
        // 细描边(负值=填充+外描边,WE 描边语义):按字号 ~10% 厚度补偿小字号 AA 发暗,让月牙更亮实。
        let strokePct: CGFloat = 8.0
        let out = NSMutableAttributedString()
        for ch in str {
            let s = String(ch)
            // 该字符的任一 scalar 基础字体渲不出 → 整字符用符号回退体 + 描边。
            let needSym = ch.unicodeScalars.contains { sc in
                if sc.value < 0x20 || sc.value == 0x20 || (0xFE00...0xFE0F).contains(sc.value) { return false }
                return !ctBase.hasGlyph(for: String(sc))
            }
            if needSym {
                var a = baseAttrs
                a[.font] = symFont
                a[.strokeColor] = a[.foregroundColor]
                a[.strokeWidth] = -strokePct
                out.append(NSAttributedString(string: s, attributes: a))
            } else {
                out.append(NSAttributedString(string: s, attributes: baseAttrs))
            }
        }
        return out
    }

    // MARK: - 字体解析

    /// WE 字体名 → NSFont。
    /// - systemfont_consolas → 等宽:SF Mono(SFNSMono.ttf),回退 Menlo（都是 WE consolas 在 mac 的对应等宽体）。
    /// - 其它 systemfont_<name>:按名找系统同名字体;等宽类名(mono/code/courier)→ 等宽回退,否则系统字体。
    /// - 非 systemfont_(pkg 自带 .ttf/.otf,通常已注册或按 family 名可取)→ 按名取;取不到回退系统字体。
    /// 关键:MONOSPACE 外观必须保住——consolas/任何含 mono/consol/courier/code 的名都落到等宽体。
    static func resolveFont(_ weName: String, size: CGFloat) -> NSFont {
        let lower = weName.lowercased()
        let bare = lower.hasPrefix("systemfont_") ? String(lower.dropFirst("systemfont_".count)) : lower

        // 审计修复(#3):优先用 FontRegistry 已注册的 pkg 字体。pkg 自带字体(.ttf/.otf)由**上层**
        //   (SceneRenderEngine 解析文本层时调 FontRegistry.shared.register,把 desc.fontName 改写成
        //   注册后的 PostScript 名)注册——本文件拿不到 pkg 字节/SceneSource,无法在此注册,故需上层先注册。
        //   这里只要 weName 不是 systemfont_ 前缀(即可能是已注册的 PS 名/pkg family 名),就先直接尝试
        //   NSFont(name:);命中即用回原版字体,不再被下面的 mono 启发式抢走(否则 consolas 外的 pkg 字体
        //   若名里含 mono/code 等会被误判等宽 → 落系统字体 = 「不是原版」)。
        if !lower.hasPrefix("systemfont_"), let f = NSFont(name: weName, size: size) {
            return f
        }

        let monospaceMarkers = ["consol", "mono", "courier", "code", "menlo", "terminal", "fixed"]
        let wantsMono = monospaceMarkers.contains { bare.contains($0) }

        if wantsMono {
            return monospaceFont(size: size)
        }

        // 直接按 family / PostScript 名找(pkg 字体或 systemfont_arial 等)。
        // 常见映射:arial→Helvetica/Arial,helvetica→Helvetica,times→Times。
        let candidates: [String]
        switch bare {
        case "arial":      candidates = ["Arial", "ArialMT", "Helvetica Neue", "Helvetica"]
        case "helvetica":  candidates = ["Helvetica Neue", "Helvetica"]
        case "times", "timesnewroman": candidates = ["Times New Roman", "Times"]
        case "verdana":    candidates = ["Verdana", "Helvetica Neue"]
        case "tahoma":     candidates = ["Tahoma", "Helvetica Neue"]
        case "georgia":    candidates = ["Georgia", "Times"]
        default:
            // 用原始名直接尝试(pkg 自带字体注册后按 family 名可取);加几个常见变体。
            candidates = [weName, bare, bare.capitalized,
                          weName.replacingOccurrences(of: "_", with: " ")]
        }
        for name in candidates {
            if let f = NSFont(name: name, size: size) { return f }
        }
        // 实在找不到:系统无衬线体(保持可读)。
        return NSFont.systemFont(ofSize: size, weight: .regular)
    }

    /// 等宽体:优先 SF Mono(系统等宽 API,即 SFNSMono),其名无法经 NSFont(name:) 直取,故用专用 API;
    /// 回退 Menlo / Andale Mono / Courier New。这些都是 WE consolas 在 mac 上合适的等宽对应体。
    private static func monospaceFont(size: CGFloat) -> NSFont {
        if #available(macOS 10.15, *) {
            // SF Mono(SFNSMono.ttf)。形态最接近 consolas 的现代等宽。
            return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        }
        for name in ["Menlo", "Menlo-Regular", "Andale Mono", "Courier New", "Courier"] {
            if let f = NSFont(name: name, size: size) { return f }
        }
        return NSFont.userFixedPitchFont(ofSize: size) ?? NSFont.systemFont(ofSize: size)
    }
}

/// 壁纸自带字体注册器:WE 文本层的 `font` 常是 pkg 内路径(如 "fonts/Atami-Regular.otf"),
/// 这些字体**未注册进系统** → `NSFont(name:)` 取不到 → 时钟/文字落系统字体,「不是原版」。
/// 这里从 SceneSource 取字体字节,用 CoreText 注册,返回可供 NSFont(name:) 用的 PostScript 名。
final class FontRegistry {
    static let shared = FontRegistry()
    private var cache: [String: String?] = [:]   // 字体路径 → 已注册 PostScript 名(nil=失败,避免重试)
    private let lock = NSLock()

    /// 注册并解析字体路径,返回 PostScript 名(已缓存则直接返回)。线程安全。
    func register(path: String, source: SceneSource) -> String? {
        lock.lock(); defer { lock.unlock() }
        if let cached = cache[path] { return cached }
        // 字体几乎都在 WE 本体 assets/fonts/(不在壁纸 pkg)。先试壁纸源,再回退内置 assets。
        var data = source.data(for: path)
        if data == nil {
            let base = (path as NSString).lastPathComponent
            data = source.data(for: "fonts/\(base)") ?? source.data(for: base)
                ?? BuiltinAssets.shared.fontData(forReference: path)
        }
        guard let d = data,
              let provider = CGDataProvider(data: d as CFData),
              let cgFont = CGFont(provider) else {
            Log.write("FontRegistry: cannot load font \(path)")
            cache[path] = nil as String?; return nil
        }
        var err: Unmanaged<CFError>?
        // 注册失败通常是「已注册过」(多壁纸/重载共享同名字体),不致命——仍取 PostScript 名。
        _ = CTFontManagerRegisterGraphicsFont(cgFont, &err)
        err?.release()
        let ps = cgFont.postScriptName as String?
        cache[path] = ps
        Log.write("FontRegistry: registered \(path) → \(ps ?? "nil")")
        return ps
    }
}

extension CTFont {
    /// 该字体是否含字符串里所有 scalar 的真实字形(glyph id 非 0)。用于判断是否需符号回退。
    func hasGlyph(for s: String) -> Bool {
        let u = Array(s.utf16)
        guard !u.isEmpty else { return true }
        var g = [CGGlyph](repeating: 0, count: u.count)
        return CTFontGetGlyphsForCharacters(self, u, &g, u.count) && g.allSatisfy { $0 != 0 }
    }
}
