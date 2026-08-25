import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 主界面右侧滑出的壁纸设置边栏(嵌入式,随窗口高度撑满)。
/// 选中壁纸即应用 + 滑出本边栏,在此直接调该壁纸的可调属性。
struct WallpaperSettingsPanel: View {
    let item: WallpaperItem
    var onApply: () -> Void
    var onClose: () -> Void
    var onUnsubscribe: (() -> Void)? = nil   // 取消订阅 + 删除本地(创意工坊条目才有)

    @State private var version = 0   // 改动后递增,触发条件重算 + 控件刷新
    @ObservedObject private var store = WallpaperPropertyStore.shared
    @ObservedObject private var presets = WallpaperPresetStore.shared
    @State private var selectedPresetID: UUID?
    /// WE 的 schemecolor 对未绑定画面效果的视频仍作为壁纸配色方案存在；在 macOS 侧用于当前属性面板的
    /// 强调色，场景壁纸若把它绑定到图层/特效则还会继续走 WallpaperPropertyStore 影响画面。
    private var accent: Color {
        if let property = schemeColorProp,
           case .color(let c) = store.value(forID: item.id, property: property, folderURL: item.folderURL) {
            return Color(red: Double(c.x), green: Double(c.y), blue: Double(c.z))
        }
        return .accentColor
    }

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
    private var renderUnits: [RenderUnit] {
        let props = visibleProperties
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
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    wallpaperInfo
                    quickActions
                    sectionDivider(title: "属性")
                    GeneralPropertiesSection(item: item, accent: accent,
                                             schemeColorProp: schemeColorProp,
                                             onChange: { version += 1; onApply() })
                    // project.json 自定义属性(去掉已并进通用区的 schemecolor)。
                    if !customRenderUnits.isEmpty {
                        sectionDivider(title: "壁纸专属")
                        ForEach(customRenderUnits) { unit in
                            switch unit {
                            case .single(let prop):
                                PropertyControl(item: item, prop: prop, accent: accent,
                                                onChange: { version += 1; onApply() })
                            case .group(let title, let members):
                                PropertyGroupSection(item: item, title: title, props: members, accent: accent,
                                                     onChange: { version += 1; onApply() })
                            }
                        }
                    }
                    sectionDivider(title: "我的预设")
                    presetSection
                }
                .padding(.horizontal, 18).padding(.vertical, 14)
                // 不再用 .id(...version...) 破坏性重建子树 —— 那会在选色时销毁正与系统颜色面板
                // 绑定的 ColorPicker、令其脱钩(色块不跟手)。store 现为 ObservableObject,改值
                // 会发通知让 body 自然重算重读 value,无需强制重建。
            }
            Divider().opacity(0.4)
            resetBar
            // 取消订阅栏(始终在底部,即使无可调属性也可用)。
            if onUnsubscribe != nil {
                Divider().opacity(0.4)
                unsubscribeBar
            }
        }
        .frame(maxHeight: .infinity)
        .background(VisualEffectView(material: .sidebar).ignoresSafeArea())
        .tint(accent)
        .id(item.id)   // 切换壁纸时强制重建,彻底避免状态残留
        .onAppear { selectedPresetID = presets.presets(for: item.id).first?.id }
    }

    /// project.json 里的 schemecolor 属性(若有)→ 并进通用区「主题配色」。
    private var schemeColorProp: WallpaperProperty? {
        allProperties.first { $0.id == "schemecolor" }
    }
    /// 自定义属性渲染单元:从 renderUnits 里剔除 schemecolor(已在通用区显示)。
    private var customRenderUnits: [RenderUnit] {
        renderUnits.compactMap { unit in
            switch unit {
            case .single(let p): return p.id == "schemecolor" ? nil : unit
            case .group(let title, let ps):
                let kept = ps.filter { $0.id != "schemecolor" }
                return kept.isEmpty ? nil : .group(title: title, props: kept)
            }
        }
    }

    private func sectionDivider(title: String) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.tertiary)
                .textCase(.uppercase)
            Rectangle().fill(Color.secondary.opacity(0.25)).frame(height: 1)
        }
        .padding(.top, 6).padding(.bottom, 2)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "slider.horizontal.3").font(.system(size: 15)).foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 1) {
                Text("属性").font(.system(size: 14, weight: .bold))
                Text("配置当前壁纸").font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill").font(.system(size: 15)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain).help("关闭")
        }
        .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 14)
    }

    private var wallpaperInfo: some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                if let url = item.previewURL, let image = NSImage(contentsOf: url) {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    ZStack {
                        Color.white.opacity(0.05)
                        Image(systemName: "photo").foregroundStyle(.tertiary)
                    }
                }
            }
            .frame(width: 66, height: 66)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.10)))

            VStack(alignment: .leading, spacing: 5) {
                Text(item.title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                Label(item.type.displayName, systemImage: typeIcon)
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                if WallpaperUninstallPolicy.isSteamWorkshopID(item.id) {
                    Text("创意工坊 · \(item.id)")
                        .font(.system(size: 9.5).monospacedDigit()).foregroundStyle(.tertiary)
                } else {
                    Text("本地壁纸").font(.system(size: 9.5)).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var typeIcon: String {
        switch item.type {
        case .video: return "film"
        case .scene: return "sparkles.rectangle.stack"
        case .web: return "globe"
        case .application: return "app"
        case .unknown: return "questionmark.square"
        }
    }

    private var quickActions: some View {
        HStack(spacing: 8) {
            if WallpaperUninstallPolicy.isSteamWorkshopID(item.id) {
                quickButton("Steam", icon: "safari") {
                    if let url = URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=\(item.id)") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            quickButton("访达", icon: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([item.folderURL])
            }
            quickButton("复制 ID", icon: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.id, forType: .string)
            }
        }
    }

    private func quickButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 10.5, weight: .medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.055)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
    }

    private var currentPresets: [WallpaperPreset] { presets.presets(for: item.id) }

    private var selectedPreset: WallpaperPreset? {
        guard let id = selectedPresetID else { return nil }
        return currentPresets.first { $0.id == id }
    }

    private var presetSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Picker("", selection: $selectedPresetID) {
                    Text(currentPresets.isEmpty ? "还没有预设" : "选择预设").tag(UUID?.none)
                    ForEach(currentPresets) { preset in
                        Text(preset.name).tag(Optional(preset.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)

                Button("加载") { loadSelectedPreset() }
                    .disabled(selectedPreset == nil)
            }

            HStack(spacing: 8) {
                presetButton("保存", icon: "plus") { savePreset() }
                presetButton("导入", icon: "square.and.arrow.down") { importPreset() }
                presetButton("导出", icon: "square.and.arrow.up") { exportSelectedPreset() }
                    .disabled(selectedPreset == nil)
                Button {
                    if let preset = selectedPreset {
                        presets.delete(preset)
                        selectedPresetID = currentPresets.first?.id
                    }
                } label: {
                    Image(systemName: "trash").frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .disabled(selectedPreset == nil)
                .help("删除所选预设")
            }
        }
    }

    private func presetButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon).font(.system(size: 10.5))
                .frame(maxWidth: .infinity)
        }
        .controlSize(.small)
    }

    private func savePreset() {
        let alert = NSAlert()
        alert.messageText = "保存当前配置"
        alert.informativeText = "输入预设名称；同名预设会被更新。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        let field = NSTextField(string: "我的预设")
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let preset = presets.saveCurrent(name: field.stringValue, item: item)
        selectedPresetID = preset.id
    }

    private func loadSelectedPreset() {
        guard let preset = selectedPreset else { return }
        do {
            try presets.apply(preset, to: item)
            version += 1
            onApply()
        } catch {
            showPresetError(error)
        }
    }

    private func exportSelectedPreset() {
        guard let preset = selectedPreset else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(safeFileName(preset.name)).livewallpaper-preset.json"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try presets.exportData(preset).write(to: url, options: .atomic)
        } catch {
            showPresetError(error)
        }
    }

    private func importPreset() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let preset = try presets.importData(Data(contentsOf: url), for: item)
            try presets.apply(preset, to: item)
            selectedPresetID = preset.id
            version += 1
            onApply()
        } catch {
            showPresetError(error)
        }
    }

    private func safeFileName(_ raw: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        return raw.components(separatedBy: invalid).joined(separator: "-")
    }

    private func showPresetError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "预设操作失败"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    private var resetBar: some View {
        HStack {
            Button {
                store.reset(forID: item.id, folderURL: item.folderURL)
                GeneralWallpaperSettings.shared.reset(item.id)   // 通用区也恢复默认
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

    private var unsubscribeBar: some View {
        Button(action: { onUnsubscribe?() }) {
            HStack(spacing: 7) {
                Image(systemName: "xmark.bin").font(.system(size: 12))
                Text("卸载（同时同步订阅）").font(.system(size: 12, weight: .medium))
                Spacer()
            }
            .foregroundStyle(.red)
            .padding(.horizontal, 16).padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("先取消创意工坊订阅；成功后再把本地文件夹移到废纸篓")
    }

}

/// WE 通用属性区。按壁纸类型/项目能力显示，所有可见控件都接到真实渲染路径。
struct GeneralPropertiesSection: View {
    let item: WallpaperItem
    let accent: Color
    let schemeColorProp: WallpaperProperty?   // project.json 的 schemecolor(若有)
    var onChange: () -> Void

    @ObservedObject private var g = GeneralWallpaperSettings.shared
    @ObservedObject private var propStore = WallpaperPropertyStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if item.type == .scene {
                Toggle(isOn: Binding(get: { g.audioListen(item.id) },
                                     set: { g.setAudioListen($0, item.id); onChange() })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("音频响应").font(.system(size: 12.5))
                        Text("开启后会采集系统播放声音；默认关闭")
                            .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    }
                }.toggleStyle(.switch).tint(accent)
            }

            if schemeColorProp != nil {
                HStack {
                    Text("配色方案").font(.system(size: 12.5)).lineLimit(1)
                    Spacer()
                    ColorPicker("", selection: schemeBinding, supportsOpacity: false).labelsHidden()
                }
            }

            if supportsMediaControls {
                sliderRow(label: "音量", value: Binding(get: { g.volume(item.id) },
                                                      set: { g.setVolume($0, item.id); onChange() }),
                          range: 0...100, format: "%.0f")
                sliderRow(label: "播放速度", value: Binding(get: { g.playbackSpeed(item.id) },
                                                         set: { g.setPlaybackSpeed($0, item.id); onChange() }),
                          range: 0...100, format: "%.0f")

                HStack {
                    Text("对齐").font(.system(size: 12.5)).lineLimit(1)
                    Spacer()
                    Picker("", selection: Binding(get: { g.alignment(item.id) },
                                                  set: { g.setAlignment($0, item.id); onChange() })) {
                        ForEach(GeneralWallpaperSettings.Alignment.allCases) { value in
                            Text(value.label).tag(value)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }

                sliderRow(label: "位置", value: Binding(get: { g.position(item.id) },
                                                       set: { g.setPosition($0, item.id); onChange() }),
                          range: 0...100, format: "%.0f")
                    .opacity(positionAvailable ? 1 : 0.45)
                    .disabled(!positionAvailable)
                    .help(positionAvailable ? "移动填充模式下被裁切的可见区域" : "当前对齐模式没有裁切区域")
            }

            if GeneralWallpaperSettings.hasParallax(item.id) {
                Toggle(isOn: Binding(get: { g.mouseParallax(item.id) },
                                     set: { g.setMouseParallax($0, item.id); onChange() })) {
                    Text("鼠标视差").font(.system(size: 12.5))
                }.toggleStyle(.switch).tint(accent)
            }

            if supportsMediaControls {
                Toggle(isOn: Binding(get: { g.flip(item.id) },
                                     set: { g.setFlip($0, item.id); onChange() })) {
                    Text("水平翻转").font(.system(size: 12.5))
                }.toggleStyle(.switch).tint(accent)

                HStack {
                    Text("图片筛选器").font(.system(size: 12.5)).lineLimit(1)
                    Spacer()
                    Picker("", selection: Binding(get: { g.filter(item.id) },
                                                  set: { g.setFilter($0, item.id); onChange() })) {
                        ForEach(GeneralWallpaperSettings.ImageFilter.allCases) { f in
                            Text(f.label).tag(f)
                        }
                    }
                    .labelsHidden().fixedSize()
                }

                Toggle(isOn: Binding(get: { g.showColorOptions(item.id) },
                                     set: { g.setShowColorOptions($0, item.id); onChange() })) {
                    Text("显示颜色选项").font(.system(size: 12.5))
                }.toggleStyle(.switch).tint(accent)

                if g.showColorOptions(item.id) {
                    VStack(alignment: .leading, spacing: 10) {
                        sliderRow(label: "亮度", value: Binding(get: { g.brightness(item.id) },
                                                              set: { g.setBrightness($0, item.id); onChange() }),
                                  range: 0...200, format: "%.0f")
                        sliderRow(label: "对比度", value: Binding(get: { g.contrast(item.id) },
                                                               set: { g.setContrast($0, item.id); onChange() }),
                                  range: 0...200, format: "%.0f")
                        sliderRow(label: "饱和度", value: Binding(get: { g.saturation(item.id) },
                                                               set: { g.setSaturation($0, item.id); onChange() }),
                                  range: 0...200, format: "%.0f")
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.035)))
                }
            }
        }
    }

    private var supportsMediaControls: Bool { item.type == .scene || item.type == .video }

    private var positionAvailable: Bool {
        let mode = g.effectiveScaleMode(item.id)
        return mode == GeneralWallpaperSettings.Alignment.cover.rawValue
            || mode == GeneralWallpaperSettings.Alignment.balanced.rawValue
    }

    /// 主题配色绑定:有 schemecolor 属性 → 读写 WallpaperPropertyStore;否则用本地占位(@State)。
    private var schemeBinding: Binding<Color> {
        if let p = schemeColorProp {
            return Binding(
                get: {
                    if case .color(let c) = propStore.value(forID: item.id, property: p, folderURL: item.folderURL) {
                        return Color(red: Double(c.x), green: Double(c.y), blue: Double(c.z))
                    }
                    return .white
                },
                set: { newColor in
                    let rgb = NSColor(newColor).usingColorSpace(.sRGB) ?? .white
                    propStore.setValue(.color(SIMD3(Float(rgb.redComponent), Float(rgb.greenComponent), Float(rgb.blueComponent))),
                                       forID: item.id, propertyKey: p.id)
                    onChange()
                })
        }
        // 只有 schemeColorProp 非空时才渲染 ColorPicker；此分支只是满足 Binding 的完整性。
        return .constant(.white)
    }

    @ViewBuilder
    private func sliderRow(label: String, value: Binding<Double>, range: ClosedRange<Double>, format: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).font(.system(size: 12.5)).lineLimit(1)
                Spacer()
                Text(String(format: format, value.wrappedValue)).font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range).tint(accent)
        }
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
    private let accent = Color.accentColor

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
