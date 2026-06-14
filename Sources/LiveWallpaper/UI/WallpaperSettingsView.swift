import SwiftUI

/// 主界面右侧滑出的壁纸设置边栏(嵌入式,随窗口高度撑满)。
/// 选中壁纸即应用 + 滑出本边栏,在此直接调该壁纸的可调属性。
struct WallpaperSettingsPanel: View {
    let item: WallpaperItem
    var onApply: () -> Void
    var onClose: () -> Void
    var onUnsubscribe: (() -> Void)? = nil   // 取消订阅 + 删除本地(创意工坊条目才有)

    @State private var version = 0   // 改动后递增,触发条件重算 + 控件刷新
    @ObservedObject private var store = WallpaperPropertyStore.shared
    private let accent = Color(red: 0.92, green: 0.36, blue: 0.62)

    /// 直接从 item 派生,绝不为空/失步(修「时全时空」)。
    private var allProperties: [WallpaperProperty] {
        store.properties(forID: item.id, folderURL: item.folderURL)
    }
    /// 按 condition 过滤后实际显示的(condition 依赖当前值,version 变就重算)。
    private var visibleProperties: [WallpaperProperty] {
        let all = allProperties
        _ = version   // 让 SwiftUI 知道依赖 version
        return all.filter {
            store.conditionMet($0.condition, forID: item.id, allProps: all, folderURL: item.folderURL)
        }
    }

    /// 把可见属性按 WE 分组拼成有序渲染单元:顶层属性逐条 single,连续同组成员合成 group。
    /// 属性已按 order 排序、同组成员连续(解析时按 order 归组),故顺扫即可。
    private enum RenderUnit: Identifiable {
        case single(WallpaperProperty)
        case group(title: String, props: [WallpaperProperty])
        var id: String {
            switch self {
            case .single(let p): return "s.\(p.id)"
            case .group(let t, let ps): return "g.\(t).\(ps.first?.id ?? "")"
            }
        }
    }
    private func renderUnits(for props: [WallpaperProperty]) -> [RenderUnit] {
        var units: [RenderUnit] = []
        var i = 0
        while i < props.count {
            if let g = props[i].group {
                var members: [WallpaperProperty] = []
                while i < props.count, props[i].group == g { members.append(props[i]); i += 1 }
                units.append(.group(title: g, props: members))
            } else {
                units.append(.single(props[i])); i += 1
            }
        }
        return units
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            let props = visibleProperties
            // WE 属性面板:无 index 的 WE 标准属性(schemecolor 等)在分隔线**上**(通用「属性」);
            // 有 index 的作者自定义属性在分隔线**下**(该壁纸专属可调属性)。分区依据来自 pkg(见 isGeneral)。
            let generalUnits = renderUnits(for: props.filter { $0.isGeneral })
            let customUnits = renderUnits(for: props.filter { !$0.isGeneral })
            if props.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(generalUnits) { unit in unitView(unit) }      // 分隔线上:通用属性
                        if !generalUnits.isEmpty && !customUnits.isEmpty {
                            Divider().opacity(0.55).padding(.vertical, 2)      // WE 分隔线
                        }
                        ForEach(customUnits) { unit in unitView(unit) }        // 分隔线下:壁纸专属
                    }
                    .padding(.horizontal, 18).padding(.vertical, 16)
                    // 不再用 .id(...version...) 破坏性重建子树 —— 那会在选色时销毁正与系统颜色面板
                    // 绑定的 ColorPicker、令其脱钩(色块不跟手)。store 现为 ObservableObject,改值
                    // 会发通知让 body 自然重算重读 value,无需强制重建。
                }
                Divider().opacity(0.4)
                resetBar
            }
            // 取消订阅栏(始终在底部,即使无可调属性也可用)。
            if onUnsubscribe != nil {
                Divider().opacity(0.4)
                unsubscribeBar
            }
        }
        .frame(maxHeight: .infinity)
        .background(VisualEffectView(material: .sidebar).ignoresSafeArea())
        .id(item.id)   // 切换壁纸时强制重建,彻底避免状态残留
    }

    /// 渲染一个 RenderUnit(单条属性 / 折叠组),供分隔线上下两段复用。
    @ViewBuilder
    private func unitView(_ unit: RenderUnit) -> some View {
        switch unit {
        case .single(let prop):
            PropertyControl(item: item, prop: prop, accent: accent,
                            onChange: { version += 1; onApply() })
        case .group(let title, let members):
            PropertyGroupSection(item: item, title: title, props: members, accent: accent,
                                 onChange: { version += 1; onApply() })
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "slider.horizontal.3").font(.system(size: 15)).foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 1) {
                Text("壁纸设置").font(.system(size: 14, weight: .bold))
                Text(item.title).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill").font(.system(size: 15)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain).help("关闭")
        }
        .padding(.horizontal, 16).padding(.top, 36).padding(.bottom, 14)
    }

    private var resetBar: some View {
        HStack {
            Button {
                store.reset(forID: item.id, folderURL: item.folderURL)
                version += 1; onApply()
            } label: {
                Label("恢复默认", systemImage: "arrow.uturn.backward").font(.system(size: 11.5))
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            Spacer()
            Text("\(visibleProperties.filter { $0.type != .label }.count) 项").font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "slider.horizontal.below.rectangle").font(.system(size: 30)).foregroundStyle(.tertiary)
            Text("这个壁纸没有可调属性").font(.system(size: 12)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(20)
    }

    private var unsubscribeBar: some View {
        Button(action: confirmUnsubscribe) {
            HStack(spacing: 7) {
                Image(systemName: "xmark.bin").font(.system(size: 12))
                Text("取消订阅并删除壁纸").font(.system(size: 12, weight: .medium))
                Spacer()
            }
            .foregroundStyle(.red)
            .padding(.horizontal, 16).padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("取消该壁纸的创意工坊订阅,并把壁纸文件夹移到废纸篓")
    }

    /// 确认后:取消订阅 + 删除本地壁纸(回调里完成,并关闭本面板)。
    private func confirmUnsubscribe() {
        let a = NSAlert()
        a.messageText = "取消订阅「\(item.title)」?"
        a.informativeText = "将取消该壁纸的创意工坊订阅,并把壁纸文件夹移到废纸篓(可在废纸篓恢复)。"
        a.alertStyle = .warning
        a.addButton(withTitle: "取消订阅并删除")
        a.addButton(withTitle: "取消")
        if a.runModal() == .alertFirstButtonReturn { onUnsubscribe?() }
    }
}

/// 单条属性控件(边栏 + sheet 共用)。改动即时持久化 + 回调。
struct PropertyControl: View {
    let item: WallpaperItem
    let prop: WallpaperProperty
    let accent: Color
    var onChange: () -> Void

    @ObservedObject private var store = WallpaperPropertyStore.shared

    var body: some View {
        // 未实现的功能:整条标灰、禁用、加「开发中」徽标 + 悬停说明。仍然显示出来。
        control
            .disabled(!prop.supported)
            .opacity(prop.supported ? 1 : 0.45)
            .overlay(alignment: .topTrailing) {
                if !prop.supported {
                    Text("开发中").font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white).padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Capsule().fill(.gray))
                        .offset(y: -2)
                }
            }
            .help(prop.supported ? "" : "此功能尚未实现,设置会保存但暂不影响画面")
    }

    @ViewBuilder
    private var control: some View {
        let value = store.value(forID: item.id, property: prop, folderURL: item.folderURL)
        switch prop.type {
        case .bool:
            Toggle(isOn: boolBinding(value)) { Text(prop.label).font(.system(size: 12.5)) }
                .toggleStyle(.switch).tint(accent)
        case .color:
            HStack {
                Text(prop.label).font(.system(size: 12.5)).lineLimit(1)
                Spacer()
                ColorPicker("", selection: colorBinding(value), supportsOpacity: false).labelsHidden()
            }
        case .slider:
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(prop.label).font(.system(size: 12.5)).lineLimit(1)
                    Spacer()
                    if case .number(let n) = value {
                        Text(String(format: "%.2f", n)).font(.system(size: 10.5).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Slider(value: numberBinding(value), in: prop.sliderRange).tint(accent)
            }
        case .combo:
            HStack {
                Text(prop.label).font(.system(size: 12.5)).lineLimit(1)
                Spacer()
                Picker("", selection: stringBinding(value)) {
                    ForEach(prop.comboOptions, id: \.value) { Text($0.label).tag($0.value) }
                }
                .labelsHidden().fixedSize()
            }
        case .textinput:
            VStack(alignment: .leading, spacing: 3) {
                Text(prop.label).font(.system(size: 12.5))
                TextField("", text: stringBinding(value)).textFieldStyle(.roundedBorder).font(.system(size: 12))
            }
        case .label:
            // type=None 说明文本(作者头/分节说明):次要文字,可换行,不可交互。
            Text(prop.label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func boolBinding(_ v: WallpaperProperty.Value) -> Binding<Bool> {
        Binding(get: { if case .bool(let b) = v { return b }; return false },
                set: { store.setValue(.bool($0), forID: item.id, propertyKey: prop.id); onChange() })
    }
    private func colorBinding(_ v: WallpaperProperty.Value) -> Binding<Color> {
        Binding(
            get: { if case .color(let c) = v { return Color(red: Double(c.x), green: Double(c.y), blue: Double(c.z)) }; return .white },
            set: { newColor in
                let rgb = NSColor(newColor).usingColorSpace(.sRGB) ?? .white
                store.setValue(.color(SIMD3(Float(rgb.redComponent), Float(rgb.greenComponent), Float(rgb.blueComponent))),
                               forID: item.id, propertyKey: prop.id)
                onChange()
            })
    }
    private func numberBinding(_ v: WallpaperProperty.Value) -> Binding<Double> {
        Binding(get: { if case .number(let n) = v { return n }; return prop.sliderMin },
                set: { store.setValue(.number($0), forID: item.id, propertyKey: prop.id); onChange() })
    }
    private func stringBinding(_ v: WallpaperProperty.Value) -> Binding<String> {
        Binding(get: { if case .string(let s) = v { return s }; return "" },
                set: { store.setValue(.string($0), forID: item.id, propertyKey: prop.id); onChange() })
    }
}

/// WE 分组(type='group'):可折叠的子菜单。标题 + 右侧 → 箭头,默认折叠,展开显示组内控件。
/// 对齐 WE 属性面板:pkg 用 group 分类 → 我们也分类成折叠组;pkg 没分类 → 不会走到这里(全顶层)。
struct PropertyGroupSection: View {
    let item: WallpaperItem
    let title: String
    let props: [WallpaperProperty]
    let accent: Color
    var onChange: () -> Void

    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Text(title).font(.system(size: 13, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 6)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(accent)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(props) { p in
                        PropertyControl(item: item, prop: p, accent: accent, onChange: onChange)
                    }
                }
                .padding(.leading, 6)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

/// 单个壁纸的设置面板:读 project.json 的可调属性,生成控件,改动即时持久化 + 通知重渲染。
struct WallpaperSettingsView: View {
    let item: WallpaperItem
    var onApply: () -> Void          // 改动后回调(重新加载该壁纸使其生效)
    var onClose: () -> Void

    @State private var properties: [WallpaperProperty] = []
    @State private var version = 0   // 改动后刷新
    private let store = WallpaperPropertyStore.shared
    private let accent = Color(red: 0.92, green: 0.36, blue: 0.62)

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            if properties.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(properties) { prop in
                            propertyRow(prop)
                        }
                    }
                    .padding(20)
                    .id(version)
                }
            }
            Divider().opacity(0.4)
            footer
        }
        .frame(width: 440, height: 560)
        .background(VisualEffectView(material: .windowBackground).ignoresSafeArea())
        .onAppear { properties = store.properties(forID: item.id, folderURL: item.folderURL) }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "slider.horizontal.3").font(.system(size: 18)).foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 1) {
                Text("壁纸设置").font(.system(size: 15, weight: .bold))
                Text(item.title).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
    }

    @ViewBuilder
    private func propertyRow(_ prop: WallpaperProperty) -> some View {
        let value = store.value(forID: item.id, property: prop, folderURL: item.folderURL)
        switch prop.type {
        case .bool:
            Toggle(isOn: boolBinding(prop, value)) {
                Text(prop.label).font(.system(size: 13))
            }
            .toggleStyle(.switch).tint(accent)
        case .color:
            HStack {
                Text(prop.label).font(.system(size: 13))
                Spacer()
                ColorPicker("", selection: colorBinding(prop, value), supportsOpacity: false)
                    .labelsHidden()
            }
        case .slider:
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(prop.label).font(.system(size: 13))
                    Spacer()
                    if case .number(let n) = value {
                        Text(String(format: "%.2f", n)).font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Slider(value: numberBinding(prop, value), in: prop.sliderRange)
                    .tint(accent)
            }
        case .combo:
            HStack {
                Text(prop.label).font(.system(size: 13))
                Spacer()
                Picker("", selection: stringBinding(prop, value)) {
                    ForEach(prop.comboOptions, id: \.value) { opt in
                        Text(opt.label).tag(opt.value)
                    }
                }
                .labelsHidden().fixedSize()
            }
        case .textinput:
            VStack(alignment: .leading, spacing: 4) {
                Text(prop.label).font(.system(size: 13))
                TextField("", text: stringBinding(prop, value))
                    .textFieldStyle(.roundedBorder).font(.system(size: 12))
            }
        case .label:
            EmptyView()
        }
    }

    private var footer: some View {
        HStack {
            Button {
                store.reset(forID: item.id, folderURL: item.folderURL)
                version += 1
                onApply()
            } label: {
                Label("恢复默认", systemImage: "arrow.uturn.backward")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            Spacer()
            Button("完成") { onClose() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "slider.horizontal.below.rectangle").font(.system(size: 36)).foregroundStyle(.tertiary)
            Text("这个壁纸没有可调属性").font(.system(size: 13)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(.vertical, 40)
    }

    // MARK: - Bindings(改动即写入 + 触发重渲染)

    private func boolBinding(_ p: WallpaperProperty, _ v: WallpaperProperty.Value) -> Binding<Bool> {
        Binding(
            get: { if case .bool(let b) = v { return b }; return false },
            set: { store.setValue(.bool($0), forID: item.id, propertyKey: p.id); version += 1; onApply() }
        )
    }
    private func colorBinding(_ p: WallpaperProperty, _ v: WallpaperProperty.Value) -> Binding<Color> {
        Binding(
            get: { if case .color(let c) = v { return Color(red: Double(c.x), green: Double(c.y), blue: Double(c.z)) }; return .white },
            set: { newColor in
                let rgb = NSColor(newColor).usingColorSpace(.sRGB) ?? .white
                store.setValue(.color(SIMD3(Float(rgb.redComponent), Float(rgb.greenComponent), Float(rgb.blueComponent))),
                               forID: item.id, propertyKey: p.id)
                version += 1; onApply()
            }
        )
    }
    private func numberBinding(_ p: WallpaperProperty, _ v: WallpaperProperty.Value) -> Binding<Double> {
        Binding(
            get: { if case .number(let n) = v { return n }; return p.sliderMin },
            set: { store.setValue(.number($0), forID: item.id, propertyKey: p.id); version += 1; onApply() }
        )
    }
    private func stringBinding(_ p: WallpaperProperty, _ v: WallpaperProperty.Value) -> Binding<String> {
        Binding(
            get: { if case .string(let s) = v { return s }; return "" },
            set: { store.setValue(.string($0), forID: item.id, propertyKey: p.id); version += 1; onApply() }
        )
    }
}
