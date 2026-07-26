import SwiftUI

/// 悬浮式滚动指示器(floating scroll indicator)—— 仿 iOS 悬浮滚动条 thumb:
/// 浮在 ScrollView 右侧的半透明玻璃胶囊,高度 ∝ 可视比例、纵向位置 ∝ 滚动进度,
/// 滚动时淡入、停止 ~1.4s 后淡出。贴合 WaifuX 深色玻璃风格(半透明白 + .ultraThinMaterial + 细描边)。
///
/// 用法:在 ScrollView 外层包一个 `.floatingScrollIndicator()`,内层最外的内容容器
/// 加 `.trackScrollOffset()` 来上报滚动偏移与内容高度。
///
/// 实现要点:
///   ① 读位置:内容容器用 GeometryReader 在 `.named("wpScroll")` 坐标系下取 minY(= -滚动偏移)
///      与自身高度,通过 ScrollOffsetKey(PreferenceKey)上报;外层用 GeometryReader 取视口高度。
///   ② overlay thumb:由 contentHeight / viewportHeight 算 fraction(可视比例)与
///      progress(0...1 滚动进度),映射到 thumb 高度与 y 偏移。
///   ③ 淡入淡出:offset 变化即 opacity→1,用 DispatchWorkItem 防抖 1.4s 后 opacity→0(带动画)。
///
/// 截图验证:设 env `WP_SCROLLBAR_DEBUG=1` 让指示器常显(生产不设此 env 时按正常淡入淡出)。

// MARK: - 偏移上报

private struct ScrollMetrics: Equatable {
    var offset: CGFloat = 0        // 已滚动距离(>=0)
    var contentHeight: CGFloat = 0 // 内容总高
}

private struct ScrollOffsetKey: PreferenceKey {
    static var defaultValue = ScrollMetrics()
    static func reduce(value: inout ScrollMetrics, nextValue: () -> ScrollMetrics) {
        let n = nextValue()
        if n.contentHeight > 0 { value = n }   // 取有效(内容高 > 0)的那一份
    }
}

extension View {
    /// 标记 ScrollView 内最外层内容容器,上报滚动偏移 + 内容高度。
    func trackScrollOffset() -> some View {
        background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: ScrollOffsetKey.self,
                    value: ScrollMetrics(
                        offset: -geo.frame(in: .named("wpScroll")).minY,
                        contentHeight: geo.size.height
                    )
                )
            }
        )
    }

    /// 给 ScrollView 包上悬浮滚动指示器(右侧浮动玻璃胶囊)。
    func floatingScrollIndicator() -> some View {
        modifier(FloatingScrollIndicatorModifier())
    }
}

// MARK: - 修饰器

private struct FloatingScrollIndicatorModifier: ViewModifier {
    @State private var metrics = ScrollMetrics()
    // WP_SCROLLBAR_DEBUG=1 时强制常显(截图验证用),生产为 false 走正常淡入淡出。
    @State private var visible = WPEnv.vars["WP_SCROLLBAR_DEBUG"] != nil
    @State private var hideWork: DispatchWorkItem?
    @State private var isHovering = false

    // 指示器外观常量
    private let trackInset: CGFloat = 6      // 距右边缘
    private let thumbWidth: CGFloat = 5
    private let minThumbHeight: CGFloat = 36
    private let verticalPadding: CGFloat = 8 // 上下留白
    private var forceVisible: Bool { WPEnv.vars["WP_SCROLLBAR_DEBUG"] != nil }

    func body(content: Content) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .topTrailing) {
                content
                    .coordinateSpace(name: "wpScroll")
                    .onPreferenceChange(ScrollOffsetKey.self) { m in
                        metrics = m
                        pulse()
                    }
                // 指示器作为 ScrollView 的同级兄弟叠在其上(ZStack),避免 NSScrollView 把 overlay 压到层下。
                indicator(viewport: geo.size.height)
                    .padding(.trailing, trackInset)
                    .padding(.vertical, verticalPadding)
                    .opacity(visible ? 1 : 0)
                    .animation(.easeOut(duration: visible ? 0.18 : 0.5), value: visible)
                    .allowsHitTesting(false)
            }
        }
    }

    // 内容比视口高才显示
    private func scrollable(viewport: CGFloat) -> Bool {
        metrics.contentHeight > viewport + 1 && viewport > 0
    }

    @ViewBuilder
    private func indicator(viewport: CGFloat) -> some View {
        if scrollable(viewport: viewport) {
            let trackHeight = max(0, viewport - verticalPadding * 2)
            let fraction = min(1, viewport / metrics.contentHeight)          // 可视比例
            let thumbHeight = max(minThumbHeight, trackHeight * fraction)
            let maxOffset = max(0, metrics.contentHeight - viewport)         // 可滚动距离
            let progress = maxOffset > 0 ? min(1, max(0, metrics.offset / maxOffset)) : 0
            let thumbY = (trackHeight - thumbHeight) * (forceVisible ? 0.5 : progress)
            let w = isHovering ? thumbWidth + 3 : thumbWidth

            // 实底色(半透明白)打底,确保任意背景与离屏渲染下都清晰可见;再叠玻璃材质+细描边出玻璃质感。
            Capsule(style: .continuous)
                .fill(forceVisible ? AnyShapeStyle(Color.red) : AnyShapeStyle(Color.white.opacity(isHovering ? 0.42 : 0.28)))
                .background(Capsule(style: .continuous).fill(.ultraThinMaterial))
                .overlay(Capsule(style: .continuous).strokeBorder(Color.white.opacity(0.22), lineWidth: 0.5))
                .frame(width: forceVisible ? 14 : w, height: thumbHeight)
                .shadow(color: .black.opacity(0.35), radius: 4, y: 1)
                .offset(y: thumbY)
                .frame(maxHeight: .infinity, alignment: .top)
                .animation(.easeOut(duration: 0.12), value: isHovering)
                .contentShape(Capsule().inset(by: -10))
                .onHover { isHovering = $0; if $0 { pulse() } }
        }
    }

    /// 触发淡入,并安排 1.4s 后淡出(debug 常显时不淡出)。
    private func pulse() {
        if !visible { visible = true }
        hideWork?.cancel()
        guard !forceVisible else { return }
        let work = DispatchWorkItem {
            if !isHovering { withAnimation(.easeOut(duration: 0.5)) { visible = false } }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: work)
    }
}
