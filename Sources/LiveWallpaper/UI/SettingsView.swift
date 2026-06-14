import SwiftUI
import AppKit

/// 嵌入主窗口的设置页。原生 macOS「系统设置」风格:Form + 分组 Section + LabeledContent,
/// 自动获得圆角分组、左标题右控件的系统外观。配色使用系统强调色,不再硬编码品牌色。
struct SettingsForm: View {
    let actions: LibraryActions
    var currentItem: WallpaperItem?

    @State private var showSteamLogin = false
    @State private var steamAccount = PreferencesStore.shared.steamAccount

    var body: some View {
        Form {
            nowPlayingSection
            playbackSection
            displaySection
            qualitySection
            generalSection
            soundSection
            rotationSection
            workshopSection
            foldersSection
            aboutSection
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showSteamLogin) {
            SteamLoginSheet(onDone: { steamAccount = PreferencesStore.shared.steamAccount })
        }
    }

    // MARK: - 通用行辅助(标题 + 可选副标题 + 右侧控件)

    @ViewBuilder
    private func row<Control: View>(_ title: String, _ subtitle: String? = nil,
                                    @ViewBuilder control: () -> Control) -> some View {
        LabeledContent {
            control()
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    @ViewBuilder
    private func toggleRow(_ title: String, _ subtitle: String? = nil,
                           _ binding: Binding<Bool>, _ onChange: @escaping (Bool) -> Void) -> some View {
        Toggle(isOn: binding) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .onChange(of: binding.wrappedValue) { v in onChange(v) }
    }

    // MARK: - 当前壁纸预览

    @State private var thumb: NSImage?

    private var nowPlayingSection: some View {
        Section {
            HStack(spacing: 14) {
                ZStack {
                    if let thumb {
                        Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Rectangle().fill(.quaternary)
                            .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
                    }
                }
                .frame(width: 116, height: 65)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.separator))

                VStack(alignment: .leading, spacing: 4) {
                    Text(currentItem == nil ? "未设置壁纸" : "正在播放")
                        .font(.caption.weight(.semibold)).foregroundStyle(currentItem == nil ? .secondary : Color.accentColor)
                    Text(currentItem?.title ?? "从壁纸库选一张吧")
                        .font(.headline).lineLimit(2)
                    if let t = currentItem?.type { TypeBadge(type: t) }
                }
                Spacer()
            }
            .padding(.vertical, 4)
            .onAppear(perform: loadThumb)
            .id(currentItem?.id)
        }
    }

    private func loadThumb() {
        thumb = nil
        guard let url = currentItem?.previewURL else { return }
        ThumbnailCache.shared.thumbnail(for: url) { img in self.thumb = img }
    }

    // MARK: - 播放控制

    private var playbackSection: some View {
        Section("播放控制") {
            HStack(spacing: 10) {
                Button {
                    actions.onTogglePause()
                } label: {
                    Label(actions.isPaused() ? "继续" : "暂停",
                          systemImage: actions.isPaused() ? "play.fill" : "pause.fill")
                        .frame(maxWidth: .infinity)
                }
                Button { actions.onNext() } label: {
                    Label("换一张", systemImage: "shuffle").frame(maxWidth: .infinity)
                }
                Button(role: .destructive) { actions.onClear() } label: {
                    Label("关闭壁纸", systemImage: "stop.fill").frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
    }

    // MARK: - 显示与渲染

    @State private var mainScreenOnly = PreferencesStore.shared.mainScreenOnly
    @State private var parallax = PreferencesStore.shared.parallaxStrength
    @State private var frameCap = PreferencesStore.shared.frameRateCap
    @State private var showIcons = DesktopIcons.isVisible

    private var displaySection: some View {
        Section("显示与渲染") {
            toggleRow("仅主显示器", "多显示器时只在主屏显示壁纸", $mainScreenOnly) {
                actions.onMainScreenOnlyChanged($0)
            }
            row("场景动效强度", "调整场景壁纸的视差 / 漂浮幅度") {
                HStack(spacing: 8) {
                    Slider(value: $parallax, in: 0...1.6)
                        .frame(width: 170)
                        .onChange(of: parallax) { v in PreferencesStore.shared.parallaxStrength = v }
                    Text(parallax < 0.05 ? "关" : String(format: "%.0f%%", parallax * 100))
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
            }
            row("动画帧率上限", "壁纸是后台动效,越低越省 CPU / 电(30 已很流畅)") {
                Picker("", selection: $frameCap) {
                    Text("省电 15").tag(15)
                    Text("平衡 30").tag(30)
                    Text("流畅 60").tag(60)
                    Text("不限").tag(0)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .onChange(of: frameCap) { v in PreferencesStore.shared.frameRateCap = v }
            }
            toggleRow("显示桌面图标", "关闭可获得更干净的壁纸效果(会重启访达)", $showIcons) {
                DesktopIcons.setVisible($0)
            }
        }
    }

    // MARK: - 画质 / 性能

    @State private var metalFX = PreferencesStore.shared.metalFXEnabled
    @State private var renderScale = PreferencesStore.shared.renderScale
    @State private var fxaa = PreferencesStore.shared.fxaaEnabled
    @State private var scaleMode = PreferencesStore.shared.wallpaperScaleMode
    @State private var syncPresent = PreferencesStore.shared.syncPresent
    @State private var compositeMaxFrames = PreferencesStore.shared.compositeMaxFrames
    @State private var textureQuality = PreferencesStore.shared.textureQuality

    private var qualitySection: some View {
        Section("画质 / 性能") {
            toggleRow("MetalFX 升采样", "低分辨率渲染 + 升采样到全屏(省 GPU,画质优于双线性)", $metalFX) {
                PreferencesStore.shared.metalFXEnabled = $0
            }
            row("渲染分辨率", "越低越省 GPU;100% = 原生") {
                HStack(spacing: 8) {
                    Slider(value: $renderScale, in: 0.5...1.0, step: 0.05)
                        .frame(width: 170)
                        .onChange(of: renderScale) { v in PreferencesStore.shared.renderScale = v }
                    Text(String(format: "%.0f%%", renderScale * 100))
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
            }
            toggleRow("FXAA 抗锯齿", "呈现时做一次快速抗锯齿,边缘更平滑(开销很低)", $fxaa) {
                PreferencesStore.shared.fxaaEnabled = $0
            }
            row("屏幕适配", "屏幕比例 ≠ 壁纸时:填满裁切 / 留黑边 / 拉伸 / 自适应") {
                Picker("", selection: $scaleMode) {
                    Text("填满").tag(0); Text("黑边").tag(1); Text("拉伸").tag(2); Text("自适应").tag(3)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .onChange(of: scaleMode) { v in
                    PreferencesStore.shared.wallpaperScaleMode = v
                    actions.onAssetsPathChanged()
                }
            }
            toggleRow("同步呈现(修内屏撕裂)", "内屏(120Hz ProMotion)出现横向分带 / 撕裂时开启;若变黑请关掉", $syncPresent) {
                PreferencesStore.shared.syncPresent = $0
                actions.onAssetsPathChanged()
            }
            row("合成层最大帧数", "带特效的层渲满 N 帧后冻结省 GPU;∞ = 不限(音频 / 水波等需 ∞)") {
                Picker("", selection: $compositeMaxFrames) {
                    Text("∞").tag(0); Text("1").tag(1); Text("2").tag(2)
                    Text("3").tag(3); Text("5").tag(5); Text("8").tag(8); Text("13").tag(13)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .onChange(of: compositeMaxFrames) { v in PreferencesStore.shared.compositeMaxFrames = v }
            }
            row("纹理质量", "大纹理上限:低 512px / 中 1024px / 高 原始") {
                Picker("", selection: $textureQuality) {
                    Text("低").tag(0); Text("中").tag(1); Text("高").tag(2)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .onChange(of: textureQuality) { v in
                    PreferencesStore.shared.textureQuality = v
                    actions.onAssetsPathChanged()
                }
            }
        }
    }

    // MARK: - 通用

    @State private var loginEnabled = LoginItem.isEnabled
    @State private var powerEnabled = true
    @State private var occlusionThreshold = PreferencesStore.shared.occlusionThreshold

    private var generalSection: some View {
        Section("通用") {
            toggleRow("开机自动启动", "登录时自动在后台运行", $loginEnabled) {
                actions.onLoginChanged($0); loginEnabled = LoginItem.isEnabled
            }
            toggleRow("遮挡时自动暂停", "桌面被全屏 / 窗口遮挡时暂停渲染省电", $powerEnabled) {
                actions.onPowerChanged($0)
            }
            row("暂停遮挡阈值", "遮挡达此比例即停渲染;「仅全屏」只在真正全屏时停") {
                Picker("", selection: $occlusionThreshold) {
                    Text("仅全屏").tag(0)
                    Text("90%").tag(90)
                    Text("75%").tag(75)
                    Text("50%").tag(50)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .disabled(!powerEnabled)
                .onChange(of: occlusionThreshold) { v in PreferencesStore.shared.occlusionThreshold = v }
            }
        }
        .onAppear { loginEnabled = LoginItem.isEnabled }
    }

    // MARK: - 声音

    @State private var muted = PreferencesStore.shared.isMuted
    @State private var volume = PreferencesStore.shared.volume

    private var soundSection: some View {
        Section("声音") {
            toggleRow("静音视频壁纸", "视频壁纸不发出声音", $muted) { actions.onMuteChanged($0) }
            row("音量") {
                HStack(spacing: 8) {
                    Slider(value: $volume, in: 0...1).frame(width: 170)
                        .disabled(muted)
                        .onChange(of: volume) { v in actions.onVolumeChanged(v) }
                    Text("\(Int(volume * 100))%")
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
                .opacity(muted ? 0.4 : 1)
            }
        }
    }

    // MARK: - 自动轮换

    @State private var rotEnabled = PreferencesStore.shared.rotationEnabled
    @State private var rotInterval = PreferencesStore.shared.rotationIntervalMinutes
    @State private var rotShuffle = PreferencesStore.shared.rotationShuffle
    @State private var rotFavOnly = PreferencesStore.shared.rotationFavoritesOnly
    private let intervals = [5, 15, 30, 60, 180]

    private var rotationSection: some View {
        Section("自动轮换") {
            toggleRow("开启自动轮换", "每隔一段时间自动更换桌面壁纸", $rotEnabled) {
                PreferencesStore.shared.rotationEnabled = $0; actions.onRotationChanged()
            }
            if rotEnabled {
                row("更换间隔") {
                    Picker("", selection: $rotInterval) {
                        ForEach(intervals, id: \.self) { m in
                            Text(m < 60 ? "\(m) 分钟" : "\(m/60) 小时").tag(m)
                        }
                    }
                    .labelsHidden().fixedSize()
                    .onChange(of: rotInterval) { v in PreferencesStore.shared.rotationIntervalMinutes = v; actions.onRotationChanged() }
                }
                toggleRow("随机顺序", "关闭则按列表顺序依次切换", $rotShuffle) {
                    PreferencesStore.shared.rotationShuffle = $0
                }
                toggleRow("仅轮换收藏", "只在收藏 ♥ 的壁纸之间切换", $rotFavOnly) {
                    PreferencesStore.shared.rotationFavoritesOnly = $0
                }
            }
        }
    }

    // MARK: - 创意工坊下载

    private var workshopSection: some View {
        Section("创意工坊下载") {
            row("SteamCMD",
                WorkshopDownloader.shared.isSteamCMDAvailable ? "已安装,可直接下载工坊壁纸"
                                                              : "未安装(终端:brew install --cask steamcmd)") {
                Image(systemName: WorkshopDownloader.shared.isSteamCMDAvailable ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(WorkshopDownloader.shared.isSteamCMDAvailable ? .green : .orange)
            }
            row("Steam 账号",
                steamAccount == nil ? "匿名只能下老壁纸;登录后可下新壁纸" : "已登录:\(steamAccount!)") {
                Button(steamAccount == nil ? "登录" : "重新登录") { showSteamLogin = true }
            }
        }
    }

    // MARK: - 资源目录

    @State private var libraryPath = PreferencesStore.shared.libraryRoot.path
    @State private var assetsPath = PreferencesStore.shared.weAssetsPath ?? (BuiltinAssets.shared.root?.path ?? "")
    @State private var assetsOK = BuiltinAssets.shared.isAvailable

    private var foldersSection: some View {
        Section("资源目录") {
            folderBlock("壁纸库目录", "从这里扫描你导入的壁纸",
                        path: libraryPath, ok: FileManager.default.fileExists(atPath: libraryPath)) {
                if let p = chooseFolder() {
                    libraryPath = p
                    PreferencesStore.shared.libraryRoot = URL(fileURLWithPath: p)
                    actions.onLibraryRootChanged()
                }
            }
            folderBlock("Wallpaper Engine 资源目录", "场景壁纸的粒子贴图、着色器从这里读取",
                        path: assetsPath.isEmpty ? "(未找到)" : assetsPath, ok: assetsOK,
                        warning: assetsOK ? nil : "未找到,场景粒子会用程序化替代") {
                if let p = chooseFolder() {
                    assetsPath = p
                    PreferencesStore.shared.weAssetsPath = p
                    BuiltinAssets.shared.resolveRoot()
                    assetsOK = BuiltinAssets.shared.isAvailable
                    actions.onAssetsPathChanged()
                }
            }
        }
    }

    private func folderBlock(_ title: String, _ subtitle: String, path: String, ok: Bool,
                             warning: String? = nil, choose: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(ok ? .green : .orange)
                Text(path)
                    .font(.caption.monospaced())
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5)))
                Button("选择…", action: choose)
            }
            if let warning {
                Text(warning).font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - 关于

    private var aboutSection: some View {
        Section {
            row("Live Wallpaper", "版本 1.0 · 原生 macOS 动态壁纸") {
                Button(role: .destructive) { actions.onQuit() } label: {
                    Label("退出", systemImage: "power")
                }
            }
        }
    }

    // MARK: - helpers

    private func chooseFolder() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}
