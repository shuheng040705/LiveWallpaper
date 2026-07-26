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
    case seconds    // 秒(SS,近似回退;某些壁纸把时/分/秒拆成独立文本层,如「白影轻扬」时分+秒+星期)
    case date       // 日期(近似回退)
    case dayOfWeek  // 星期(SAT)
    case greeting   // 按时段问候(GOOD MORNING/AFTERNOON/EVENING)
    // WE 时钟 format scriptproperty 驱动(如 "HH:mm" / "MM/dd" / ":ss" / "[W]"):脚本无 update() 跑不起来时,
    // 直接按 pkg 的 format 串渲染(比按图层名瞎猜的 .clock/.seconds/.date 忠实——修白影"21掉下方/FRI非Friday/日期带空格")。
    case clockFormat(String)
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

    // ── WE 文本框的宽度/行数限制(2026-07-27 补:此前完全没解析,折行宽度写死 100000 = 永不折行)──
    // WE 语义(ITextLayer):limitwidth 开时按 maxwidth(像素)自动折行;limitrows 开时只保留前
    // maxrows 行,limituseellipsis 则在截断处加省略号。默认 false/500/1/false。
    // 影响:开了 limitwidth 的层原来被渲成一条超宽单行 —— 白影轻扬的公告段落(WE 里 2 行)冲出面板;
    // 媒体信息层(maxrows=1)的长歌名不截断,横向拖出画面。全库 32 个对象 / 9 张壁纸受影响。
    var limitWidth = false
    var maxWidth: CGFloat = 500
    var limitRows = false
    var maxRows = 1
    var useEllipsis = false

    // ── 描边/阴影/字重(R15)──────────────────────────────────────────────────────
    // 关键实据(扒全库 157 张 pkg、331 个文本对象 + lwe 源码核对,2026-06-14):
    //   • WE 文本对象**没有** strokecolor/strokesize/shadowcolor/shadowoffset/bold/italic 字段
    //     —— 全库 raw 字节搜索 0 命中。任务设想的「scene 对象级描边/阴影/粗斜体字段」在 WE 数据模型里不存在。
    //   • 真正的 WE 文本**描边/外框**走**后处理特效**(workshop shader,如 `textoutline7x7`,
    //     带 outlinecolor/width/threshold/opacity 的 constantshadervalues)。本引擎已支持:该 shader 已转译
    //     (workshop__3565237853__effects__textoutline7x7__base__frag.metal)、已进 WEEffects.json、
    //     parseTextLayer 也已把 obj["effects"] 解进特效链(走 WEEffectChain 统一管线)→ **描边已数据驱动可渲**。
    //   • **粗体/斜体**在 WE 里由**字体文件本身**承载(如 Quicksand-Bold.otf / LEMONMILK-Light.otf),
    //     没有独立 bool。FontRegistry 注册 pkg 字体 + resolveFont 按 PS 名取 → 粗细已随字体本身落地。
    //   • 唯一**真实存在却此前未渲**的对象级文本样式字段 = `castshadow`(bool,投影开关)。
    //     全库恒 false(无壁纸开),lwe 也直接丢弃不读;但它是 WE_SCENE_SPEC 里的合法基础对象字段,
    //     故按「严格按 pkg、有字段才渲」补:castshadow=true → CoreText NSShadow 投影(WE 默认软黑投影)。
    // WP_NO_TEXT_STROKE=1 关闭本节全部新增渲染(castshadow 投影 + 字重 trait 合成回退),A/B 诊断。
    var castShadow = false                 // pkg `castshadow`(bool):WE 文本投影开关;true 才渲投影
    var shadowColor: SIMD3<Float> = SIMD3(0, 0, 0)   // 投影色(WE 默认黑;pkg 无独立字段)
    var shadowOffsetPx: SIMD2<Float> = SIMD2(0, 0)   // 投影偏移(渲染像素;按字号比例算,见 parseTextLayer)
    var shadowBlurPx: CGFloat = 0          // 投影模糊半径(渲染像素)
    var wantsBold = false                  // 字体名暗示粗体(*-Bold/Black/Heavy)但系统取到的体不粗 → trait 合成兜底
    var wantsItalic = false                // 字体名暗示斜体(*-Italic/Oblique)→ trait 合成兜底
}

enum TextLayerRenderer {
    /// 渲染当前文本到 RGBA8 像素。返回 (pixels, w, h)。
    /// 审计修复(#1):新增可选 simTime(引擎累计 sim 时间,秒),透传给脚本驱动的 currentString,
    ///   让脚本图层动画与引擎 sim-time 同步;默认 nil 时脚本回退墙钟(旧行为)。
    static func render(_ desc: TextLayerDesc, simTime: Double? = nil) -> (pixels: [UInt8], width: Int, height: Int)? {
        let str = currentString(desc, simTime: simTime)
        guard !str.isEmpty else { return nil }

        let noStroke = WPEnv.vars["WP_NO_TEXT_STROKE"] != nil
        let nsColor = NSColor(srgbRed: CGFloat(desc.color.x), green: CGFloat(desc.color.y),
                              blue: CGFloat(desc.color.z), alpha: 1)
        // 字重/斜体(R15):resolveFont 取到的体若与字体名暗示的粗/斜不符(取不到带 weight 变体、落了 regular),
        //   用 NSFontManager trait 合成兜底;已正确加载的粗/斜体不受影响(它们本身就有 trait)。WP_NO_TEXT_STROKE 关闭。
        let font = noStroke
            ? resolveFont(desc.fontName, size: desc.pointSize)
            : styledFont(resolveFont(desc.fontName, size: desc.pointSize),
                         wantsBold: desc.wantsBold, wantsItalic: desc.wantsItalic)
        let para = NSMutableParagraphStyle()
        para.alignment = desc.align == "left" ? .left : (desc.align == "right" ? .right : .center)
        // 折行:WE 文本框有显式宽度时,长文本应按框宽 word-wrap(超宽换行),而不是无限单行被
        //   下游按盒子缩放压扁。para.lineBreakMode = .byWordWrapping 让 CoreText 按 boundingRect
        //   的宽度上限折行。
        para.lineBreakMode = .byWordWrapping

        var attrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: nsColor, .paragraphStyle: para
        ]

        // 投影(R15):WE `castshadow:true` → CoreText NSShadow 软投影。pkg 不带投影色/偏移/模糊 →
        //   用 parseTextLayer 算好的 WE 默认软黑投影参数(见 TextLayerDesc 注释里实据)。
        //   翻转坐标系(下方 scaleBy(1,-1))内 y 向下,故 shadowOffset.height 取 +offy 即屏上向下投影。
        //   严格按 pkg:castShadow=false(全库恒此值)时不加 → 普通文字零变化。WP_NO_TEXT_STROKE 关闭。
        var extraPad: CGFloat = 0
        if desc.castShadow && !noStroke {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor(srgbRed: CGFloat(desc.shadowColor.x), green: CGFloat(desc.shadowColor.y),
                                         blue: CGFloat(desc.shadowColor.z), alpha: 1)
            shadow.shadowOffset = NSSize(width: CGFloat(desc.shadowOffsetPx.x), height: CGFloat(desc.shadowOffsetPx.y))
            shadow.shadowBlurRadius = desc.shadowBlurPx
            attrs[.shadow] = shadow
            // 投影会越出字形外接框 → 纹理须留够边距容下「偏移 + 模糊」,否则投影被裁。
            extraPad = max(abs(CGFloat(desc.shadowOffsetPx.x)), abs(CGFloat(desc.shadowOffsetPx.y))) + desc.shadowBlurPx * 2
        }

        // 符号字形回退 + 加粗(月相 ☽/☾ 等):WE 在 Windows(CrossOver)用 Arial 渲符号——但实测 Windows Arial.TTF
        //   同样**不含** ☽(U+263D)/☾(U+263E),走 Windows 字体链回退到 Segoe UI Symbol(粗实月牙、亮)。
        //   macOS 上 Arial/Helvetica 也无该字形,CoreText 默认回退到 **Menlo**(等宽体,月牙细瘦、AA 边发暗
        //   → 形状不同 + 整体偏暗)。修法:对**基础字体渲不出**的字符,改用含该字形且更饱满的符号体
        //   (Arial Unicode MS,Arial 家族、macOS 自带、月牙更粗亮),并加细描边补偿小字号 AA 发暗
        //   —— 让 ☽/☾ 接近 WE 的亮实月牙。普通拉丁字(基础字体能渲)不受影响 → 不动其它壁纸时钟/日期外观。
        // WP_NO_MOONFIX=1 退回旧的「单一字体 + CoreText 自动回退」(A/B 诊断符号字形改动)。
        var attr = (WPEnv.vars["WP_NO_MOONFIX"] != nil)
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
        //   ⭐2026-07-27 补齐:WE 的 limitwidth=true 时按 maxwidth 折行、limitrows=true 时截到 maxrows
        //   (limituseellipsis 则加省略号)。这三个字段此前根本没解析,折行宽度写死 100000 = 永不折行。
        //   单位说明:maxwidth 与 pointsize 同在 WE 的文本栅格化像素空间(实测吻合:白影轻扬 id 4385
        //   maxwidth 1242.6 / size.x 1238),而本函数正是按 desc.pointSize 的自然像素绘制 → 可直接用。
        //   但我们为求清晰会把字号放大到 renderPt(desc.pointSize),故 maxwidth 要按同一比例放大,
        //   否则折行点会偏早(字变大了、可用宽度没变)。
        let ptScale = desc.srcPointSize > 0 ? desc.pointSize / desc.srcPointSize : 1
        let maxWidth: CGFloat = desc.limitWidth ? max(1, desc.maxWidth * ptScale) : 100000
        if desc.limitRows, desc.maxRows > 0 {
            attr = Self.truncate(attr, toRows: desc.maxRows, width: maxWidth, ellipsis: desc.useEllipsis)
        }
        let bounds = attr.boundingRect(with: CGSize(width: maxWidth, height: 100000),
                                       options: [.usesLineFragmentOrigin, .usesFontLeading])
        // 留点边距,避免抗锯齿边缘被裁;有投影(castshadow)时再加 extraPad 容下偏移+模糊(R15)。
        let pad: CGFloat = desc.pointSize * 0.3 + extraPad
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
        // ⭐裁切到墨迹包围盒(去掉 pointSize×0.3 的对称防裁边距)。该边距加在**宽文本**上会把
        //   texAspect=texW/texH 压小(对称 pad 缩纵横比)→ 下游 quadW=box.y×texAspect 渲得偏窄,
        //   且锚点定位 -quadW/2 内缩 → 时分文字渲窄 + 与秒之间留空隙。WE 文本透明背景**无边距**
        //   (203 recenter 脚本注释「透明背景时无边距」明说)→ 时分:秒紧贴、字宽足。裁到 alpha>0
        //   包围盒 + extraPad(保 castshadow 投影不被裁)后 texW/texH=真实墨迹纵横比 → quadW/recenter
        //   /锚点全用紧致宽,自动对齐 WE。WP_NO_TEXT_INKTRIM=1 退回旧全边距纹理(A/B)。
        if WPEnv.vars["WP_NO_TEXT_INKTRIM"] == nil {
            // **水平**裁到墨迹包围盒(去左右防裁边距 → 锚点定位用真实墨迹右/左缘、消除与秒的间隙)。
            var minX = w, maxX = -1
            for y in 0..<h {
                let row = y * w * 4
                for x in 0..<w where px[row + x * 4 + 3] > 0 {
                    if x < minX { minX = x }; if x > maxX { maxX = x }
                }
            }
            // **垂直**只去 AA 边距(pointSize×0.3)、**保留整行高**:纵横比 texW/texH 的分母必须是**行高**
            //   (bounds.height)而非墨迹高。数字「14:37」无降部 → 墨迹高≈0.7×行高 → 若用墨迹高当分母,
            //   quadW=box.y×inkW/inkH 会偏宽 ~70%(=用户「时分太大」)。垂直裁到行盒 [pad, h-pad](=bounds.height)
            //   令分母=行高 → 字宽正确。保留 extraPad(castshadow)余量不裁投影。
            let aaPad = Int((desc.pointSize * 0.3).rounded())      // pad - extraPad = 纯 AA 防裁边距
            let hMargin = Int(ceil(extraPad)) + 1                  // 水平保阴影 + 1px AA
            if maxX >= minX {
                let x0 = max(0, minX - hMargin), x1 = min(w - 1, maxX + hMargin)
                let y0 = max(0, aaPad), y1 = min(h - 1, h - 1 - aaPad)
                let nw = x1 - x0 + 1, nh = y1 - y0 + 1
                if nw > 0, nh > 0, nh <= h, nw < w || nh < h {
                    var out = [UInt8](repeating: 0, count: nw * nh * 4)
                    for y in 0..<nh {
                        let src = ((y0 + y) * w + x0) * 4
                        let dst = y * nw * 4
                        for b in 0..<(nw * 4) { out[dst + b] = px[src + b] }
                    }
                    return (out, nw, nh)
                }
            }
        }
        return (px, w, h)
    }

    /// 按 WE 的 limitrows/maxrows/limituseellipsis 语义把文本截断到前 N 行。
    /// 用 CoreText 的排版结果找第 N 行的字符边界(与实际绘制同一套换行规则),而不是数 "\n" ——
    /// limitwidth 折出来的软换行同样计入行数,WE 也是按视觉行算。
    private static func truncate(_ attr: NSAttributedString, toRows rows: Int,
                                 width: CGFloat, ellipsis: Bool) -> NSAttributedString {
        guard rows > 0, attr.length > 0 else { return attr }
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: width, height: 1_000_000), transform: nil)
        let framesetter = CTFramesetterCreateWithAttributedString(attr)
        let frame = CTFramesetterCreateFrame(framesetter, CFRangeMake(0, 0), path, nil)
        guard let lines = CTFrameGetLines(frame) as? [CTLine], lines.count > rows else { return attr }
        let lastRange = CTLineGetStringRange(lines[rows - 1])
        var cut = lastRange.location + lastRange.length
        cut = max(0, min(cut, attr.length))
        guard cut < attr.length else { return attr }
        let out = NSMutableAttributedString(
            attributedString: attr.attributedSubstring(from: NSRange(location: 0, length: cut)))
        // 去掉截断处遗留的换行/空白,免得末尾多出一个空行。
        while out.length > 0, let last = out.string.last, last.isWhitespace || last.isNewline {
            out.deleteCharacters(in: NSRange(location: out.length - 1, length: 1))
        }
        if ellipsis, out.length > 0 {
            let attrs = out.attributes(at: out.length - 1, effectiveRange: nil)
            out.append(NSAttributedString(string: "\u{2026}", attributes: attrs))
        }
        return out
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
        case .seconds:
            let f = DateFormatter(); f.dateFormat = "ss"
            return f.string(from: Date())
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
        case .clockFormat(let fmt):
            return formatClock(fmt, date: Date())
        }
    }

    /// WE 时钟 format 串解释器:扫描 format,按 token 替换为当前时间分量(其余字符=字面量原样输出)。
    /// token(对齐 pkg 脚本 getFormated*,均补零2位):HH=24时 hh=12时 mm=分 ss=秒 MM=月 dd=日;[W]=英文全称星期(混合大小写)。
    /// 例:"HH:mm"→"15:08"、":ss"→":21"、"MM/dd"→"06/19"、"[W]"→"Friday"。
    static func formatClock(_ fmt: String, date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.locale = Locale(identifier: "en_US")
        let c = cal.dateComponents([.hour, .minute, .second, .month, .day, .weekday], from: date)
        func p2(_ n: Int?) -> String { String(format: "%02d", n ?? 0) }
        let weekdays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        let chars = Array(fmt)
        var out = ""; var i = 0
        while i < chars.count {
            if i + 2 < chars.count, chars[i] == "[", chars[i + 1] == "W", chars[i + 2] == "]" {
                out += weekdays[max(0, min(6, (c.weekday ?? 1) - 1))]; i += 3; continue
            }
            if i + 1 < chars.count {
                switch String(chars[i...i + 1]) {
                case "HH": out += p2(c.hour); i += 2; continue
                case "hh": let h = (c.hour ?? 0) % 12; out += p2(h == 0 ? 12 : h); i += 2; continue
                case "mm": out += p2(c.minute); i += 2; continue
                case "ss": out += p2(c.second); i += 2; continue
                case "MM": out += p2(c.month); i += 2; continue
                case "dd": out += p2(c.day); i += 2; continue
                default: break
                }
            }
            out.append(chars[i]); i += 1
        }
        return out
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

    // MARK: - 字重/斜体合成(R15)

    /// 字重/斜体兜底:WE 的粗/斜由字体文件承载(*-Bold.otf 等);FontRegistry + resolveFont 取到带 weight 的体时
    /// 本函数是 no-op(传入的 base 已是粗/斜体,traits 已含)。仅当**取不到带 weight 变体**(如 systemfont_ 或注册失败
    /// 落了 regular)而字体名又暗示粗/斜时,用 NSFontManager 合成 bold/italic trait 补上,避免「该粗的渲成细」。
    /// 已带对应 trait 的体不会被二次加粗/加斜(convert 幂等)。无 wants 时直接返回 base → 普通文字零变化。
    static func styledFont(_ base: NSFont, wantsBold: Bool, wantsItalic: Bool) -> NSFont {
        guard wantsBold || wantsItalic else { return base }
        let mgr = NSFontManager.shared
        var f = base
        let cur = mgr.traits(of: f)
        if wantsBold && !cur.contains(.boldFontMask) {
            f = mgr.convert(f, toHaveTrait: .boldFontMask)
        }
        if wantsItalic && !cur.contains(.italicFontMask) {
            f = mgr.convert(f, toHaveTrait: .italicFontMask)
        }
        return f
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
