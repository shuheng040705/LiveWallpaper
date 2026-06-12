import SwiftUI
import AppKit

/// 嵌入主窗口的设置表单。卡片全宽,macOS 系统设置风格:每行"标题在左、控件在右"。
struct SettingsForm: View {
    let actions: LibraryActions
    var currentItem: WallpaperItem?

    private let accent = Color(red: 0.92, green: 0.36, blue: 0.62)

    @State private var showSteamLogin = false
    @State private var steamAccount = PreferencesStore.shared.steamAccount

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                nowPlayingCard
                playbackCard
                displayCard
                qualityCard
                generalCard
                soundCard
                rotationCard
                workshopCard
                foldersCard
                aboutCard
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
            .padding(.top, 2)
            .frame(maxWidth: .infinity)
        }
        .tint(accent)
        .sheet(isPresented: $showSteamLogin) {
            SteamLoginSheet(onDone: { steamAccount = PreferencesStore.shared.steamAccount })
        }
    }

    // MARK: - 创意工坊下载

    private var workshopCard: some View {
        card("创意工坊下载", "cart.fill", .orange) {
            row("SteamCMD",
                WorkshopDownloader.shared.isSteamCMDAvailable ? "已安装,可直接下载工坊壁纸"
                                                              : "未安装(终端:brew install --cask steamcmd)") {
                Image(systemName: WorkshopDownloader.shared.isSteamCMDAvailable ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(WorkshopDownloader.shared.isSteamCMDAvailable ? .green : .orange)
            }
            row("Steam 账号",
                steamAccount == nil ? "匿名只能下老壁纸;登录后可下新壁纸" : "已登录:\(steamAccount!)",
                divider: false) {
                Button(steamAccount == nil ? "登录" : "重新登录") { showSteamLogin = true }
                    .controlSize(.small)
            }
        }
    }

    // MARK: - 卡片容器(全宽)

    private func card<Content: View>(_ title: String, _ icon: String, _ tint: Color,
                                     @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(tint, in: RoundedRectangle(cornerRadius: 6))
                Text(title).font(.system(size: 13, weight: .semibold))
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 8)
            VStack(spacing: 0) { content() }
                .padding(.horizontal, 16).padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.07), lineWidth: 1))
    }

    private func row<Right: View>(_ title: String, _ subtitle: String? = nil,
                                  divider: Bool = true, @ViewBuilder right: () -> Right) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13))
                    if let subtitle { Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 12)
                right()
            }
            .padding(.vertical, 10)
            if divider { Divider().opacity(0.35) }
        }
    }

    private func switchRow(_ title: String, _ subtitle: String? = nil, divider: Bool = true,
                          _ binding: Binding<Bool>, _ onChange: @escaping (Bool) -> Void) -> some View {
        row(title, subtitle, divider: divider) {
            Toggle("", isOn: binding).labelsHidden().toggleStyle(.switch)
                .onChange(of: binding.wrappedValue) { v in onChange(v) }
        }
    }

    // MARK: - 当前壁纸预览

    @State private var thumb: NSImage?

    private var nowPlayingCard: some View {
        HStack(spacing: 14) {
            ZStack {
                if let thumb {
                    Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(.quaternary)
                        .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
                }
            }
            .frame(width: 120, height: 67.5)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.1)))

            VStack(alignment: .leading, spacing: 4) {
                Text(currentItem == nil ? "未设置壁纸" : "正在播放")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(accent)
                Text(currentItem?.title ?? "从壁纸库选一张吧")
                    .font(.system(size: 15, weight: .bold)).lineLimit(2)
                if let t = currentItem?.type {
                    TypeBadge(type: t)
                }
            }
            Spacer()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(
            LinearGradient(colors: [accent.opacity(0.18), .purple.opacity(0.12)],
                           startPoint: .leading, endPoint: .trailing)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.08), lineWidth: 1))
        .onAppear(perform: loadThumb)
        .id(currentItem?.id)   // 切换壁纸时重载缩略图
    }

    private func loadThumb() {
        thumb = nil
        guard let url = currentItem?.previewURL else { return }
        ThumbnailCache.shared.thumbnail(for: url) { img in self.thumb = img }
    }

    // MARK: - 播放控制

    private var playbackCard: some View {
        card("播放控制", "play.fill", .pink) {
            HStack(spacing: 10) {
                pillButton(actions.isPaused() ? "继续" : "暂停",
                           actions.isPaused() ? "play.fill" : "pause.fill") { actions.onTogglePause() }
                pillButton("换一张", "shuffle") { actions.onNext() }
                pillButton("关闭壁纸", "stop.fill", destructive: true) { actions.onClear() }
            }
            .padding(.vertical, 8)
        }
    }

    private func pillButton(_ title: String, _ icon: String,
                            destructive: Bool = false, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 11, weight: .medium))
                Text(title).font(.system(size: 12, weight: .medium))
            }
            .frame(maxWidth: .infinity).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 9).fill(.white.opacity(0.08)))
            .foregroundStyle(destructive ? .red : .primary)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 显示与渲染

    @State private var videoFill = PreferencesStore.shared.videoFill
    @State private var mainScreenOnly = PreferencesStore.shared.mainScreenOnly
    @State private var parallax = PreferencesStore.shared.parallaxStrength
    @State private var frameCap = PreferencesStore.shared.frameRateCap
    @State private var showIcons = DesktopIcons.isVisible
    @State private var metalFX = PreferencesStore.shared.metalFXEnabled
    @State private var renderScale = PreferencesStore.shared.renderScale
    @State private var fxaa = PreferencesStore.shared.fxaaEnabled
    @State private var scaleMode = PreferencesStore.shared.wallpaperScaleMode
    @State private var syncPresent = PreferencesStore.shared.syncPresent
    @State private var compositeMaxFrames = PreferencesStore.shared.compositeMaxFrames
    @State private var textureQuality = PreferencesStore.shared.textureQuality

    private var displayCard: some View {
        card("显示与渲染", "sparkles.tv.fill", .indigo) {
            row("视频填充方式", "铺满裁切,或完整显示(可能留黑边)") {
                Picker("", selection: $videoFill) {
                    Text("铺满").tag(true)
                    Text("完整").tag(false)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 130)
                .onChange(of: videoFill) { v in actions.onVideoFillChanged(v) }
            }
            switchRow("仅主显示器", "多显示器时只在主屏显示壁纸", $mainScreenOnly) {
                actions.onMainScreenOnlyChanged($0)
            }
            row("场景动效强度", "调整场景壁纸的视差/漂浮幅度", divider: true) {
                HStack(spacing: 8) {
                    Slider(value: $parallax, in: 0...1.6)
                        .frame(width: 180)
                        .onChange(of: parallax) { v in PreferencesStore.shared.parallaxStrength = v }
                    Text(parallax < 0.05 ? "关" : String(format: "%.0f%%", parallax * 100))
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary).frame(width: 38, alignment: .trailing)
                }
            }
            row("动画帧率上限", "壁纸是后台动效,越低越省 CPU/电(30 已很流畅;CPU 偏高时调低)", divider: true) {
                Picker("", selection: $frameCap) {
                    Text("省电 15").tag(15)
                    Text("平衡 30").tag(30)
                    Text("流畅 60").tag(60)
                    Text("不限").tag(0)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 240)
                .onChange(of: frameCap) { v in PreferencesStore.shared.frameRateCap = v }
            }
            switchRow("显示桌面图标", "关闭可获得更干净的壁纸效果(会重启访达)", divider: false, $showIcons) {
                DesktopIcons.setVisible($0)
            }
        }
    }

    // MARK: - 画质 / 性能

    private var qualityCard: some View {
        card("画质 / 性能", "speedometer", .teal) {
            switchRow("MetalFX 升采样", "低分辨率渲染 + MetalFX 升采样到全屏(省 GPU,画质优于双线性)", $metalFX) {
                PreferencesStore.shared.metalFXEnabled = $0
            }
            row("渲染分辨率", "越低越省 GPU(配合 MetalFX/双线性升采样);100%=原生", divider: true) {
                HStack(spacing: 8) {
                    Slider(value: $renderScale, in: 0.5...1.0, step: 0.05)
                        .frame(width: 180)
                        .onChange(of: renderScale) { v in PreferencesStore.shared.renderScale = v }
                    Text(String(format: "%.0f%%", renderScale * 100))
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary).frame(width: 38, alignment: .trailing)
                }
            }
            switchRow("FXAA 抗锯齿", "呈现时做一次快速抗锯齿,边缘更平滑(开销很低)", divider: true, $fxaa) {
                PreferencesStore.shared.fxaaEnabled = $0
            }
            row("屏幕适配", "屏幕长宽比≠壁纸时:填满=裁切边缘(WE 默认)/黑边=全可见留黑边/拉伸=全屏无黑边但变形。内屏 16:10 看 16:9 壁纸边缘特效被裁时换「黑边」或「拉伸」", divider: true) {
                Picker("", selection: $scaleMode) {
                    Text("填满").tag(0); Text("黑边").tag(1); Text("拉伸").tag(2)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 200)
                .onChange(of: scaleMode) { v in
                    PreferencesStore.shared.wallpaperScaleMode = v
                    actions.onAssetsPathChanged()   // 重载让 ndcScale 即时生效
                }
            }
            switchRow("同步呈现(修内屏撕裂)", "Mac 内屏(120Hz ProMotion)上连续动画壁纸出现横向分带/撕裂时开启(同步 present)。若开启后壁纸变黑请关掉", divider: true, $syncPresent) {
                PreferencesStore.shared.syncPresent = $0
                actions.onAssetsPathChanged()   // 重载重建图层让 presentsWithTransaction 生效
            }
            row("合成层最大帧数", "带特效的层渲满 N 帧后冻结省 GPU;∞=不限(音频/水波等持续动画需 ∞)", divider: true) {
                Picker("", selection: $compositeMaxFrames) {
                    Text("∞").tag(0); Text("1").tag(1); Text("2").tag(2)
                    Text("3").tag(3); Text("5").tag(5); Text("8").tag(8); Text("13").tag(13)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 260)
                .onChange(of: compositeMaxFrames) { v in PreferencesStore.shared.compositeMaxFrames = v }
            }
            row("纹理质量", "大纹理上限:低 512px / 中 1024px / 高 原始。降低省显存(小纹理不受影响)", divider: false) {
                Picker("", selection: $textureQuality) {
                    Text("低").tag(0); Text("中").tag(1); Text("高").tag(2)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 150)
                .onChange(of: textureQuality) { v in
                    PreferencesStore.shared.textureQuality = v
                    actions.onAssetsPathChanged()   // 纹理在加载时下采样 → 重载当前壁纸生效
                }
            }
        }
    }

    // MARK: - 通用

    @State private var loginEnabled = LoginItem.isEnabled
    @State private var powerEnabled = true
    @State private var occlusionThreshold = PreferencesStore.shared.occlusionThreshold

    private var generalCard: some View {
        card("通用", "gearshape.fill", .gray) {
            switchRow("开机自动启动", "登录时自动在后台运行", $loginEnabled) {
                actions.onLoginChanged($0); loginEnabled = LoginItem.isEnabled
            }
            switchRow("遮挡时自动暂停", "桌面被全屏/窗口遮挡时暂停渲染省电(台前调度也省)", $powerEnabled) {
                actions.onPowerChanged($0)
            }
            row("暂停遮挡阈值", "遮挡达此比例即停渲染;「仅全屏」只在真正全屏时停", divider: false) {
                Picker("", selection: $occlusionThreshold) {
                    Text("仅全屏").tag(0)
                    Text("90%").tag(90)
                    Text("75%").tag(75)
                    Text("50%").tag(50)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 240)
                .disabled(!powerEnabled)
                .onChange(of: occlusionThreshold) { v in PreferencesStore.shared.occlusionThreshold = v }
            }
        }
        .onAppear { loginEnabled = LoginItem.isEnabled }
    }

    // MARK: - 声音

    @State private var muted = PreferencesStore.shared.isMuted
    @State private var volume = PreferencesStore.shared.volume

    private var soundCard: some View {
        card("声音", "speaker.wave.2.fill", .pink) {
            switchRow("静音视频壁纸", "视频壁纸不发出声音", $muted) { actions.onMuteChanged($0) }
            row("音量", divider: false) {
                HStack(spacing: 8) {
                    Slider(value: $volume, in: 0...1).frame(width: 180)
                        .disabled(muted)
                        .onChange(of: volume) { v in actions.onVolumeChanged(v) }
                    Text("\(Int(volume * 100))%")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary).frame(width: 38, alignment: .trailing)
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

    private var rotationCard: some View {
        card("自动轮换", "arrow.triangle.2.circlepath", .purple) {
            switchRow("开启自动轮换", "每隔一段时间自动更换桌面壁纸", divider: rotEnabled, $rotEnabled) {
                PreferencesStore.shared.rotationEnabled = $0; actions.onRotationChanged()
            }
            if rotEnabled {
                row("更换间隔") {
                    Picker("", selection: $rotInterval) {
                        ForEach(intervals, id: \.self) { m in
                            Text(m < 60 ? "\(m)分钟" : "\(m/60)小时").tag(m)
                        }
                    }
                    .labelsHidden().frame(width: 110)
                    .onChange(of: rotInterval) { v in PreferencesStore.shared.rotationIntervalMinutes = v; actions.onRotationChanged() }
                }
                switchRow("随机顺序", "关闭则按列表顺序依次切换", $rotShuffle) {
                    PreferencesStore.shared.rotationShuffle = $0
                }
                switchRow("仅轮换收藏", "只在收藏 ♥ 的壁纸之间切换", divider: false, $rotFavOnly) {
                    PreferencesStore.shared.rotationFavoritesOnly = $0
                }
            }
        }
    }

    // MARK: - 资源目录

    @State private var libraryPath = PreferencesStore.shared.libraryRoot.path
    @State private var assetsPath = PreferencesStore.shared.weAssetsPath ?? (BuiltinAssets.shared.root?.path ?? "")
    @State private var assetsOK = BuiltinAssets.shared.isAvailable

    private var foldersCard: some View {
        card("资源目录", "folder.fill", .blue) {
            folderBlock("壁纸库目录", "从这里扫描你导入的壁纸",
                        path: libraryPath, ok: FileManager.default.fileExists(atPath: libraryPath), divider: true) {
                if let p = chooseFolder() {
                    libraryPath = p
                    PreferencesStore.shared.libraryRoot = URL(fileURLWithPath: p)
                    actions.onLibraryRootChanged()
                }
            }
            folderBlock("Wallpaper Engine 资源目录", "场景壁纸的粒子贴图、着色器从这里读取",
                        path: assetsPath.isEmpty ? "(未找到)" : assetsPath, ok: assetsOK, divider: false,
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
                             divider: Bool, warning: String? = nil, choose: @escaping () -> Void) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 7) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13))
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(ok ? .green : .orange).font(.system(size: 12))
                    Text(path)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 9).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 7).fill(.black.opacity(0.18)))
                    Button("选择…", action: choose).controlSize(.small)
                }
                if let warning {
                    Text(warning).font(.system(size: 10.5)).foregroundStyle(.orange)
                }
            }
            .padding(.vertical, 10)
            if divider { Divider().opacity(0.35) }
        }
    }

    // MARK: - 关于

    private var aboutCard: some View {
        card("关于", "info.circle.fill", .teal) {
            row("Live Wallpaper", "版本 1.0 · 原生 macOS 动态壁纸", divider: false) {
                Button(role: .destructive) { actions.onQuit() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "power").font(.system(size: 11))
                        Text("退出").font(.system(size: 12, weight: .medium))
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(.red.opacity(0.15)))
                    .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
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
