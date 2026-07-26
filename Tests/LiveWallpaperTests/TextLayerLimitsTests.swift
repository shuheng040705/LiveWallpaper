import XCTest
import CoreGraphics
@testable import LiveWallpaper

/// WE 文本层的宽度/行数限制(limitwidth / maxwidth / limitrows / maxrows / limituseellipsis)。
///
/// 这几个字段此前完全没解析,折行宽度写死 100000 = 永不折行 —— 开了 limitwidth 的层被渲成一条
/// 超宽单行(白影轻扬的公告段落本该 2 行、媒体信息层的长歌名本该截断)。全库 32 个对象 / 9 张壁纸受影响。
///
/// 这里用渲出的**纹理尺寸**作判据:折行后宽度必然变窄、高度变高;截断到 N 行后高度不超过 N 行。
/// 不比对像素,只比对结构,避免受字体/AA 差异影响。
final class TextLayerLimitsTests: XCTestCase {

    /// 一段足够长、必然超过 maxWidth 的英文文本(有空格 → 可 word-wrap)。
    private let longText = "The Time Filter feature is not compatible with the High Performance material settings."

    private func desc(limitWidth: Bool, maxWidth: CGFloat = 200,
                      limitRows: Bool = false, maxRows: Int = 1,
                      ellipsis: Bool = false) -> TextLayerDesc {
        var d = TextLayerDesc(kind: .staticText(longText), color: SIMD3(1, 1, 1), pointSize: 32)
        d.srcPointSize = 32          // ptScale = 1 → maxWidth 直接按像素用
        d.fontName = "systemfont_consolas"
        d.limitWidth = limitWidth
        d.maxWidth = maxWidth
        d.limitRows = limitRows
        d.maxRows = maxRows
        d.useEllipsis = ellipsis
        return d
    }

    /// limitwidth=false(WE 默认)→ 单行,不折行。这是回归护栏:绝大多数文本层走这条路,行为必须不变。
    func testNoLimitRendersSingleWideLine() throws {
        let r = try XCTUnwrap(TextLayerRenderer.render(desc(limitWidth: false)))
        XCTAssertGreaterThan(r.width, 600, "不限宽时长文本应渲成一条宽单行")
        XCTAssertLessThan(r.height, 120, "不限宽时不应折行 → 高度约等于一行")
    }

    /// limitwidth=true → 按 maxwidth 折行:宽度被压到上限附近,高度相应变高。
    func testLimitWidthWrapsText() throws {
        let unlimited = try XCTUnwrap(TextLayerRenderer.render(desc(limitWidth: false)))
        let wrapped = try XCTUnwrap(TextLayerRenderer.render(desc(limitWidth: true, maxWidth: 200)))
        XCTAssertLessThan(wrapped.width, unlimited.width, "折行后宽度应显著变窄")
        XCTAssertGreaterThan(wrapped.height, unlimited.height, "折行后行数增加 → 高度应变高")
        // 允许少量抗锯齿边距;宽度不该远超 maxWidth。
        XCTAssertLessThan(wrapped.width, 200 + 120, "折行宽度应受 maxwidth 约束")
    }

    /// maxwidth 越小 → 行越多 → 纹理越高。验证的是「确实按该值折行」而不是随便折了一下。
    func testSmallerMaxWidthProducesMoreRows() throws {
        let wide = try XCTUnwrap(TextLayerRenderer.render(desc(limitWidth: true, maxWidth: 400)))
        let narrow = try XCTUnwrap(TextLayerRenderer.render(desc(limitWidth: true, maxWidth: 160)))
        XCTAssertGreaterThan(narrow.height, wide.height, "maxwidth 更小应折出更多行")
        XCTAssertLessThan(narrow.width, wide.width)
    }

    /// limitrows=true + maxrows=1 → 截回单行(媒体信息层的长歌名就是这个用法)。
    func testLimitRowsTruncatesToSingleRow() throws {
        let wrapped = try XCTUnwrap(TextLayerRenderer.render(desc(limitWidth: true, maxWidth: 200)))
        let clamped = try XCTUnwrap(TextLayerRenderer.render(
            desc(limitWidth: true, maxWidth: 200, limitRows: true, maxRows: 1)))
        XCTAssertLessThan(clamped.height, wrapped.height, "限到 1 行后高度应明显低于多行版本")
    }

    /// maxrows=2 的高度应介于 1 行与不限行之间(逐级生效,不是一刀切)。
    func testMaxRowsIsMonotonic() throws {
        func h(_ rows: Int) throws -> Int {
            try XCTUnwrap(TextLayerRenderer.render(
                desc(limitWidth: true, maxWidth: 200, limitRows: true, maxRows: rows))).height
        }
        let h1 = try h(1), h2 = try h(2), h3 = try h(3)
        XCTAssertLessThan(h1, h2, "2 行应高于 1 行")
        XCTAssertLessThanOrEqual(h2, h3, "3 行不应低于 2 行")
    }

    /// limituseellipsis=true → 截断处补省略号,内容变宽一点点(同样行数下更满)。
    /// 只断言「不崩且仍产出有效纹理」+ 行高不变,省略号本身的像素差异不做像素级断言。
    func testEllipsisKeepsSameRowHeight() throws {
        let plain = try XCTUnwrap(TextLayerRenderer.render(
            desc(limitWidth: true, maxWidth: 200, limitRows: true, maxRows: 1, ellipsis: false)))
        let dotted = try XCTUnwrap(TextLayerRenderer.render(
            desc(limitWidth: true, maxWidth: 200, limitRows: true, maxRows: 1, ellipsis: true)))
        XCTAssertEqual(plain.height, dotted.height, accuracy: 8, "加省略号不应改变行高")
        XCTAssertGreaterThan(dotted.width, 0)
    }

    /// 短文本(本就不超宽)开了 limitwidth 也不应被改动 —— 防止误伤不需要折行的层。
    func testShortTextUnaffectedByLimits() throws {
        var d = desc(limitWidth: true, maxWidth: 400, limitRows: true, maxRows: 1)
        d.kind = .staticText("12:34")
        let limited = try XCTUnwrap(TextLayerRenderer.render(d))
        var d2 = d
        d2.limitWidth = false; d2.limitRows = false
        let plain = try XCTUnwrap(TextLayerRenderer.render(d2))
        XCTAssertEqual(limited.width, plain.width, accuracy: 2, "短文本不该因限宽而改变")
        XCTAssertEqual(limited.height, plain.height, accuracy: 2)
    }
}

private func XCTAssertEqual(_ a: Int, _ b: Int, accuracy: Int, _ msg: String = "",
                            file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertLessThanOrEqual(abs(a - b), accuracy, msg, file: file, line: line)
}
