import Foundation

/// 用 SteamCMD 下载 Wallpaper Engine(appid 431960)的创意工坊壁纸。
/// 实测:匿名即可下载大多数老壁纸、内容为明文、force_install_dir 可控落点。下完移动到
/// 壁纸库目录,FolderWatcher 自动刷新进库。支持并发(最多同时 maxConcurrent 个)。
///
/// 注意:依赖系统装有 steamcmd(brew install --cask steamcmd)。未装时给出提示。
final class WorkshopDownloader: ObservableObject {
    static let shared = WorkshopDownloader()
    private let stagingDirectoryOverride: URL?
    private let executableOverride: URL?
    private let libraryDirectoryOverride: URL?
    private let accountOverride: String?
    struct Timeouts {
        var login: TimeInterval = 90
        var commandStart: TimeInterval = 60
        var noProgress: TimeInterval = 180
        var retryDelay: TimeInterval = 2
    }
    private let timeouts: Timeouts
    init(stagingDirectory: URL? = nil, executable: URL? = nil, libraryDirectory: URL? = nil, account: String? = nil,
         timeouts: Timeouts = Timeouts()) {
        stagingDirectoryOverride = stagingDirectory
        executableOverride = executable
        libraryDirectoryOverride = libraryDirectory
        self.timeouts = timeouts
        accountOverride = account
    }
    private let appID = "431960"
    static let simultaneousDownloads = 3
    var maximumConcurrentDownloads: Int { Self.simultaneousDownloads }

    struct Job: Identifiable, Equatable {
        let id: String          // workshop id
        var title: String
        var state: State = .queued
        var startTime: Date?    // 开始下载的时刻(算已用时间)
        var totalBytes: Int64 = 0       // 网页抓的目标大小;完成时被 steamcmd 真实值覆盖
        var attempt = 1
        var elapsed: TimeInterval = 0   // 完成时的真实耗时

        // 实时进度。主信号是临时目录里 .patch 文件按块(24B/块)的增长(每条目、高频、对大小文件都管用);
        // content_log.txt 的真实字节更新太稀疏,只用来显示精确 MB/速度,以及拿总块数 N。
        var committedChunks: Int = 0    // 已提交块数 = patch 文件大小 / 24
        var totalChunks: Int = 0        // 总块数(content_log 的 "Downloading N chunks")
        var downloadedBytes: Int64 = 0  // content_log 报的真实已下载字节(可能滞后)
        var logTotal: Int64 = 0         // content_log 报的真实总字节(比网页值权威;并发时用来匹配任务)
        var liveSpeedMBps: Double = 0   // 实时速度:由「有效已下载量」逐次轮询增量算 + EMA 平滑
        var lastSampleBytes: Int64?     // 上次 content_log 字节采样(锁速度起点用,保留)
        var lastSampleTime: Date?
        var lastSpeedBytes: Int64 = -1  // 上次算速度时的有效已下载字节(-1=未初始化)
        var lastSpeedTime: Date?        // 上次算速度的时刻
        var phase: Phase = .queued
        /// true 时先让当前库所属的 CrossOver Steam 接管；未接管/客户端退出才回退 SteamCMD。
        var preferSteamClient = false
        var expectedSteamID64: String?

        enum State: Equatable { case queued, connecting, downloading, done, cancelled, failed(String) }
        enum Phase: Equatable {
            case queued
            case subscribing
            case waitingForSteamClient
            case steamClientDownloading
            case startingDownloader
            case authenticating
            case preparing
            case transferring
            case installing
            case reconnecting
        }

        /// 完成时的平均速度 MB/s(真实:总字节 ÷ 真实耗时)。
        var avgSpeedMBps: Double {
            guard elapsed > 0.1, totalBytes > 0 else { return 0 }
            return Double(totalBytes) / 1_048_576 / elapsed
        }
        /// 真实总字节:优先用 content_log 的权威值,退回网页估算值。
        var effectiveTotal: Int64 { logTotal > 0 ? logTotal : totalBytes }
        /// 总块数:优先 content_log 的 N,退回按 ~1MB/块从总字节估算。
        var effectiveTotalChunks: Int {
            if totalChunks > 0 { return totalChunks }
            if effectiveTotal > 0 { return max(1, Int((Double(effectiveTotal) / 1_048_576).rounded(.up))) }
            return 0
        }
        /// 下载完成比例 0…1;还拿不到进度时返回 nil(UI 显示不确定进度条)。
        /// **关键(修进度跳变)**:块进度(committedChunks/totalChunks)只在**真实 N(totalChunks)到手后**才用——
        /// 那时分子分母同为「块」,精确高频。N 到手前**绝不**用「块数 ÷ (字节/1MB) 估算块数」当分母
        /// (Steam 块 0.5–2MB 不均、估算分母错且非常数倍 → N 一到分母突变,百分比整段跳 23%→60%)。
        /// N 未到时改用 content_log 的**字节比例**(与 N 后的块比例同源,切换平滑)。
        var fraction: Double? {
            if totalChunks > 0, committedChunks > 0 {
                return min(0.99, Double(committedChunks) / Double(totalChunks))
            }
            if downloadedBytes > 0, effectiveTotal > 0 {
                return min(0.99, Double(downloadedBytes) / Double(effectiveTotal))
            }
            return nil
        }
        var sizeMB: Double { Double(effectiveTotal) / 1_048_576 }
        /// 有效已下载字节:与进度条同源(块进度 × 总大小);算速率/显示「已下载 MB」共用,保证一致平滑。
        var effectiveDownloadedBytes: Int64 {
            if let f = fraction { return Int64(f * Double(effectiveTotal)) }
            return downloadedBytes
        }
        var downloadedMB: Double { Double(effectiveDownloadedBytes) / 1_048_576 }

        /// 首页 hero/卡片使用的短状态，避免准备阶段一律显示“下载中”造成假卡观感。
        var compactStatus: String {
            switch state {
            case .queued:
                return phase == .subscribing ? "正在订阅" : "排队中"
            case .connecting:
                switch phase {
                case .queued: return "排队中"
                case .subscribing: return "正在订阅"
                case .waitingForSteamClient: return "等待 Steam"
                case .steamClientDownloading: return "Steam 下载"
                case .startingDownloader: return "启动服务"
                case .authenticating: return "Steam 登录"
                case .preparing: return "连接 CDN"
                case .transferring: return "准备传输"
                case .installing: return "安装中"
                case .reconnecting: return "断线重连"
                }
            case .downloading:
                if phase == .installing { return "安装中" }
                return fraction.map { String(format: "%d%%", Int($0 * 100)) } ?? "下载中"
            case .done:
                return "已完成"
            case .cancelled:
                return "已取消"
            case .failed:
                return "失败"
            }
        }
    }

    @Published private(set) var jobs: [Job] = []
    @Published var loginExpired = false   // 检测到账号登录失效 → UI 弹「重新登录」提醒

    private let startupLock = NSLock()
    private let loginQueue = DispatchQueue(label: "workshop.login", qos: .utility)
    private let workerQueue = DispatchQueue(label: "workshop.worker", qos: .utility, attributes: .concurrent)
    // 只在主线程调度；槽位在实际 worker 退出之后释放，终态通知不能提前释放。
    private var runningSlots: [String: Int] = [:]
    private var authenticationInProgress = false
    private let lock = NSLock()
    private var processes: [String: Process] = [:]   // 进行中的 steamcmd(供取消)
    private var cancelledSet: Set<String> = []        // 已请求取消的 id
    private var discardingIDs: Set<String> = []
    private var stopping = false
    private var isStopping: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopping
    }
    private struct ClientRoute {
        let context: CrossOverSteamClient.Context
        let processIdentifier: pid_t
        let logBaseline: UInt64
        let initialManifest: CrossOverSteamClient.ManifestItemState
    }
    private var clientRoutes: [String: ClientRoute] = [:]

    /// 每个 worker 有独立 HOME、运行目录、输出与进度日志。
    private final class Session {
        let slot: Int
        let group = DispatchGroup()
        let condition = NSCondition()
        var process: Process?
        var input: Pipe?
        var output = Data()
        var terminated = false
        var generation = UUID()
        var ready = false
        var account: String?
        var outputHandle: FileHandle?
        var logsReady = false
        init(slot: Int) { self.slot = slot }
    }
    private var sessions: [String: Session] = [:] // lock 保护
    private func itemRoot(_ id: String) -> URL { stagingRoot.appendingPathComponent("Items/" + id) }
    private func workerRoot(_ slot: Int) -> URL { stagingRoot.appendingPathComponent("Workers/\(slot)") }
    private func workerHome(_ slot: Int) -> URL { workerRoot(slot).appendingPathComponent("home") }

    /// 稳定暂存目录：网络失败后保留 .patch/chunk，重试时 SteamCMD 可以续传。
    /// 旧实现每次 retry 都删 /tmp/lw_dl_<id>，任何断网都会从 0 开始。
    private var stagingRoot: URL {
        if let stagingDirectoryOverride { return stagingDirectoryOverride }
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("com.a55555.livewallpaper/SteamWorkshop", isDirectory: true)
    }

    /// steamcmd 可执行路径(brew cask 的 wrapper)。
    private var steamcmdPath: String? {
        if let executableOverride { return executableOverride.path }
        let candidates = ["/opt/homebrew/bin/steamcmd", "/usr/local/bin/steamcmd"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    var isSteamCMDAvailable: Bool { steamcmdPath != nil }

    /// UI 在主线程查询：只有与当前壁纸库同一个 bottle 的 Steam mini-app 在线才算可用。
    var isCrossOverSteamAvailable: Bool {
        precondition(Thread.isMainThread)
        return CrossOverSteamClient.activeContext(
            for: PreferencesStore.shared.libraryRoot,
            expectedSteamID64: SteamWebSession.shared.steamID64
        ) != nil
    }

    var isAnyDownloadBackendAvailable: Bool {
        precondition(Thread.isMainThread)
        return isSteamCMDAvailable || isCrossOverSteamAvailable
    }

    /// Homebrew 的 steamcmd 是两层 shell wrapper。直接运行最终二进制，取消时 SIGTERM 才会
    /// 真正送到下载进程，而不是只杀掉外层脚本后留下继续耗带宽的孙进程。
    private var steamcmdBinary: URL? {
        if let executableOverride { return executableOverride }
        guard let wrapper = steamcmdPath else { return nil }
        return Self.resolveSteamCMDBinary(wrapper: URL(fileURLWithPath: wrapper))
    }

    static func resolveSteamCMDBinary(wrapper: URL, fileManager: FileManager = .default) -> URL {
        let resolved = wrapper.resolvingSymlinksInPath()
        let directory = resolved.deletingLastPathComponent()
        // 新版 cask 把 wrapper 放在 .homebrew-command-wrappers/ 中，与 MacOS/ 同级。
        let candidates = [
            directory.appendingPathComponent("MacOS/steamcmd"),
            directory.deletingLastPathComponent().appendingPathComponent("MacOS/steamcmd"),
        ]
        if let binary = candidates.first(where: { fileManager.isExecutableFile(atPath: $0.path) }) {
            return binary
        }
        return resolved
    }

    private func makeSteamCMDProcess(arguments: [String], executable override: URL? = nil, home: URL? = nil) -> Process? {
        guard let executable = override ?? steamcmdBinary else { return nil }
        let p = Process()
        p.executableURL = executable
        p.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        if let home { env["HOME"] = home.path }

        // 直接运行 Homebrew Cask 内的最终二进制时，补回 steamcmd.sh 设置的动态库环境。
        if executable.lastPathComponent == "steamcmd",
           executable.deletingLastPathComponent().lastPathComponent == "MacOS" {
            let root = executable.deletingLastPathComponent().path
            env["DYLD_LIBRARY_PATH"] = [root, env["DYLD_LIBRARY_PATH"]]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ":")
            env["DYLD_FRAMEWORK_PATH"] = [root, env["DYLD_FRAMEWORK_PATH"]]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ":")
            p.currentDirectoryURL = executable.deletingLastPathComponent()
        }
        p.environment = env
        return p
    }

    /// 未完成(排队/连接/下载中)的任务数,供工具栏角标显示。
    var activeCount: Int { jobs.filter { $0.state == .connecting || $0.state == .downloading }.count }
    var queuedCount: Int { jobs.filter { $0.state == .queued }.count }

    var pendingCount: Int {
        jobs.filter { switch $0.state { case .queued, .connecting, .downloading: return true; default: return false } }.count
    }

    /// 终止 steamcmd。⚠ `Process.terminate()` 只把 SIGTERM 发给**直接子进程**,而 Homebrew 的
    /// `/opt/homebrew/bin/steamcmd` 是 shell wrapper,`steamcmd.sh` 末行用 `$DEBUGGER "$STEAMEXE" "$@"`
    /// (**没有 exec**)把真正的 steamcmd 当孙进程跑 → SIGTERM 只到脚本,真正在下载的进程既不退出也不
    /// 放开管道写端。这里先 SIGTERM 给进程组(子进程默认与我们同组时 kill(-pid) 会误伤自己,故只在
    /// 确认它自成一组时才用),再对直接子进程升级 SIGKILL 兜底。
    private static func killProcessTree(_ p: Process) {
        guard p.isRunning else { return }
        let pid = p.processIdentifier
        guard pid > 0 else { return }
        // 若子进程自成进程组(pgid == pid),可以安全地整组终止,覆盖孙进程。
        let pgid = getpgid(pid)
        if pgid == pid { kill(-pid, SIGTERM) } else { p.terminate() }
        // 宽限 3s 后升级 SIGKILL(整组优先)。
        _ = waitExit(p, timeout: 3)
        if p.isRunning {
            if pgid == pid { kill(-pid, SIGKILL) } else { kill(pid, SIGKILL) }
        }
    }

    /// 有限等待进程退出(轮询 isRunning)。返回是否已退出。
    /// 不用 `waitUntilExit()`:它无限阻塞,而 brew wrapper 在等不肯退的孙进程时永远不返回
    /// (见 killProcessTree 注释)——收尾路径必须保证有界,状态机才一定能走到终态。
    private static func waitExit(_ p: Process, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning {
            if Date() >= deadline { return false }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return true
    }

    /// 加入下载队列。`waitForSubscription` 用于首页直下：先立刻显示“正在订阅”，订阅事务
    /// 完成后再由 `beginReservedDownload` 放行，避免先启动 SteamCMD 再与 Steam Client 抢文件。
    func enqueue(
        id: String,
        title: String,
        sizeBytes: Int64 = 0,
        preferSteamClient: Bool = false,
        expectedSteamID64: String? = nil,
        waitForSubscription: Bool = false
    ) {
        DispatchQueue.main.async {
            // 已有同 id 任务时不重复排队 —— 但**失败/取消的任务是刻意保留在列表里的**(见 finish),
            // 旧代码在这里一律 return,导致首页 hero 的「重试」、工坊卡片点击、详情页「下载」按钮
            // 对失败任务全部**点了没反应也无提示**(只有下载管理窗口的重试图标走 retry(id:) 才有效)。
            // → 同 id 若处于可重来的终态(失败/取消),直接转交 retry 复用该条目重新排队。
            if let i = self.jobs.firstIndex(where: { $0.id == id }) {
                switch self.jobs[i].state {
                case .failed, .cancelled:
                    self.jobs[i].preferSteamClient = preferSteamClient
                    self.jobs[i].expectedSteamID64 = expectedSteamID64
                    self.retryLocked(index: i, waitForSubscription: waitForSubscription)
                default:
                    break   // 排队中/下载中/已完成待移除:忽略重复请求(现状行为)
                }
                return
            }
            var job = Job(id: id, title: title, totalBytes: sizeBytes)
            job.preferSteamClient = preferSteamClient
            job.expectedSteamID64 = expectedSteamID64
            if waitForSubscription { job.phase = .subscribing }
            self.jobs.append(job)
            if !waitForSubscription { self.configureClientRoute(for: job) }
            self.pump()
        }
    }

    /// 放行一个正在“订阅”的占位任务。若 Steam 客户端此刻不可用，worker 会自然回退 SteamCMD。
    func beginReservedDownload(id: String, preferSteamClient: Bool, expectedSteamID64: String?) {
        DispatchQueue.main.async {
            guard let i = self.jobs.firstIndex(where: { $0.id == id }),
                  self.jobs[i].state == .queued,
                  self.jobs[i].phase == .subscribing else { return }
            self.jobs[i].preferSteamClient = preferSteamClient
            self.jobs[i].expectedSteamID64 = expectedSteamID64
            self.jobs[i].phase = .queued
            self.configureClientRoute(for: self.jobs[i])
            self.pump()
        }
    }

    /// 必须在主线程：在订阅成功/重试时重新绑定当下真实运行的 CrossOver Steam。
    private func configureClientRoute(for job: Job) {
        precondition(Thread.isMainThread)
        var route: ClientRoute?
        if job.preferSteamClient,
           let active = CrossOverSteamClient.activeContext(
               for: PreferencesStore.shared.libraryRoot,
               expectedSteamID64: job.expectedSteamID64
           ) {
            route = ClientRoute(
                context: active.context,
                processIdentifier: active.processIdentifier,
                logBaseline: CrossOverSteamClient.fileSize(active.context.workshopLogURL),
                initialManifest: CrossOverSteamClient.manifestItemState(active.context, id: job.id)
            )
        }
        lock.lock()
        if let route { clientRoutes[job.id] = route } else { clientRoutes.removeValue(forKey: job.id) }
        lock.unlock()
    }

    func prewarm() { /* 各 worker 按需启动；不再占用全局 Steam IPC。 */ }

    func shutdown() {
        lock.lock(); stopping = true
        let active = Array(sessions.values)
        let processes = Array(processes.values)
        lock.unlock()
        for p in processes where p.isRunning { p.terminate() }
        for session in active { session.group.wait(); shutdownSession(session, graceful: false) }
    }

    /// 独立运行时只复制一次；各下载不能一起写 Homebrew 的 package/config 或默认 Steam 日志。
    private func prepareWorker(_ session: Session, id: String) throws -> URL {
        let fm = FileManager.default
        guard let binary = steamcmdBinary else { throw CocoaError(.fileNoSuchFile) }
        let root = workerRoot(session.slot)
        let home = workerHome(session.slot)
        try fm.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let runtime = root.appendingPathComponent("MacOS")
        var executable = binary
        if executableOverride == nil {
            let source = binary.deletingLastPathComponent()
            let version = "\(source.path)|\((try? fm.attributesOfItem(atPath: binary.path)[.modificationDate]) ?? "")"
            let marker = root.appendingPathComponent("runtime-version")
            if (try? String(contentsOf: marker, encoding: .utf8)) != version {
                try? fm.removeItem(at: runtime)
                try fm.copyItem(at: source, to: runtime)
                try version.write(to: marker, atomically: true, encoding: .utf8)
            }
            executable = runtime.appendingPathComponent("steamcmd")
            // 沿用用户已授权的缓存凭据，不保存密码，不让 worker 修改用户的 Steam 配置。
            let sourceSteam = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Steam")
            let targetSteam = home.appendingPathComponent("Library/Application Support/Steam")
            try fm.createDirectory(at: targetSteam.appendingPathComponent("config"), withIntermediateDirectories: true)
            // SteamAPI 在 HOME 下查找 macOS 的 IPC helper。缺少入口时会初始化失败，
            // 即使账号缓存完全正确也永远等不到登录；只复用系统助手，配置/日志仍独立。
            for name in ["Steam.AppBundle", "com.valvesoftware.steam.ipctool.plist"] {
                let from = sourceSteam.appendingPathComponent(name), to = targetSteam.appendingPathComponent(name)
                if fm.fileExists(atPath: from.path), !fm.fileExists(atPath: to.path) {
                    try fm.createSymbolicLink(at: to, withDestinationURL: from)
                }
            }
            for name in ["config/config.vdf", "config/loginusers.vdf", "registry.vdf"] {
                let from = sourceSteam.appendingPathComponent(name), to = targetSteam.appendingPathComponent(name)
                if fm.fileExists(atPath: from.path) {
                    try? fm.removeItem(at: to)
                    try fm.copyItem(at: from, to: to)
                    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: to.path)
                }
            }
        }
        let log = home.appendingPathComponent("Library/Application Support/Steam/logs/content_log.txt")
        try? fm.removeItem(at: log)
        session.condition.lock(); session.logsReady = true; session.condition.unlock()
        let item = itemRoot(id)
        try fm.createDirectory(at: item, withIntermediateDirectories: true)
        // 升级前的未完成内容迁入独立目录，保留可续传的块。
        for kind in ["content", "downloads"] {
            let relative = "steamapps/workshop/\(kind)/\(appID)/\(id)"
            let old = stagingRoot.appendingPathComponent(relative), new = item.appendingPathComponent(relative)
            if fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) {
                try fm.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: old, to: new)
            }
        }
        let oldPatches = stagingRoot.appendingPathComponent("steamapps/workshop/downloads")
        let newPatches = item.appendingPathComponent("steamapps/workshop/downloads")
        if let files = try? fm.contentsOfDirectory(at: oldPatches, includingPropertiesForKeys: nil) {
            for file in files where file.lastPathComponent.hasSuffix("_\(id).patch") {
                try fm.createDirectory(at: newPatches, withIntermediateDirectories: true)
                let target = newPatches.appendingPathComponent(file.lastPathComponent)
                if !fm.fileExists(atPath: target.path) { try fm.moveItem(at: file, to: target) }
            }
        }
        return executable
    }

    /// 异步补上网页抓到的目标大小(仅用于进度百分比估算)。下载已先行开始,**不需等它**。
    func updateSize(id: String, bytes: Int64) {
        guard bytes > 0 else { return }
        DispatchQueue.main.async {
            if let i = self.jobs.firstIndex(where: { $0.id == id }), self.jobs[i].totalBytes == 0 {
                self.jobs[i].totalBytes = bytes
            }
        }
    }

    private enum SessionReadyResult {
        case success
        case failure(String)
    }

    /// workerQueue 专用；仅为本条目建立会话，初始化与传输都可取消。
    private func ensureSessionReady(for id: String, session: Session) -> SessionReadyResult {
        // 仅冷启动/登录串行，传输保持并行。macOS Steam IPC helper 在同时初始化时会竞争。
        while !startupLock.try() {
            if isCancelled(id) { return .failure("用户取消下载") }
            Thread.sleep(forTimeInterval: 0.1)
        }
        defer { startupLock.unlock() }
        if isStopping { return .failure("下载服务正在退出") }
        if isCancelled(id) { return .failure("用户取消下载") }
        let wantedAccount = accountOverride ?? PreferencesStore.shared.steamAccount ?? "anonymous"
        if session.ready, session.account == wantedAccount, session.process?.isRunning == true {
            return .success
        }
        shutdownSession(session, graceful: true)

        do {
            try FileManager.default.createDirectory(at: itemRoot(id), withIntermediateDirectories: true)
        } catch {
            return .failure("无法创建下载暂存目录：\(error.localizedDescription)")
        }
        let executable: URL
        do { executable = try prepareWorker(session, id: id) }
        catch { return .failure("无法准备独立下载服务：\(error.localizedDescription)") }
        guard let p = makeSteamCMDProcess(arguments: [
            "+force_install_dir", itemRoot(id).path,
            "+login", wantedAccount
        ], executable: executable, home: workerHome(session.slot)) else {
            return .failure("未安装 SteamCMD")
        }

        let input = Pipe()
        let output = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = output

        session.condition.lock()
        session.output.removeAll(keepingCapacity: true)
        session.terminated = false
        let generation = UUID()
        session.generation = generation
        session.condition.unlock()

        let outputHandle = output.fileHandleForReading
        session.outputHandle = outputHandle
        outputHandle.readabilityHandler = { handle in
            let data = handle.availableData
            session.condition.lock()
            guard session.generation == generation else {
                session.condition.unlock()
                handle.readabilityHandler = nil
                return
            }
            if data.isEmpty {
                handle.readabilityHandler = nil
                session.terminated = true
            } else {
                session.output.append(data)
                if session.output.count > 262_144 { session.output.removeFirst(session.output.count - 262_144) }
            }
            session.condition.broadcast()
            session.condition.unlock()
        }
        p.terminationHandler = { _ in
            session.condition.lock()
            guard session.generation == generation else {
                session.condition.unlock()
                return
            }
            session.terminated = true
            session.condition.broadcast()
            session.condition.unlock()
        }

        do {
            try p.run()
        } catch {
            outputHandle.readabilityHandler = nil
            return .failure("SteamCMD 启动失败：\(error.localizedDescription)")
        }
        session.process = p
        session.input = input
        session.account = wantedAccount
        session.ready = false
        // 启动/登录同样属于任务，取消时必须能终止它，而不是等满 90 秒。
        setProcess(id, p)
        defer { setProcess(id, nil) }

        let deadline = Date().addingTimeInterval(timeouts.login)
        while Date() < deadline {
            if isStopping {
                shutdownSession(session, graceful: false)
                return .failure("下载服务正在退出")
            }
            if isCancelled(id) {
                shutdownSession(session, graceful: false)
                return .failure("用户取消下载")
            }
            let snapshot = sessionSnapshot(session)
            if Self.outputShowsLoginSuccess(snapshot) {
                session.ready = true
                DispatchQueue.main.async { self.loginExpired = false }
                return .success
            }
            if Self.outputShowsAuthenticationFailure(snapshot) {
                DispatchQueue.main.async { self.loginExpired = wantedAccount != "anonymous" }
                shutdownSession(session, graceful: false)
                return .failure(wantedAccount == "anonymous"
                    ? "匿名 Steam 会话登录失败"
                    : "SteamCMD 登录已失效，请在设置中重新登录")
            }
            if Self.outputShowsConnectionFailure(snapshot) {
                shutdownSession(session, graceful: false)
                return .failure("连接 Steam/CDN 失败，请检查网络或代理后重试")
            }
            if sessionDidTerminate(session) {
                let suffix = String(snapshot.suffix(500))
                shutdownSession(session, graceful: false)
                return .failure("SteamCMD 初始化时退出\(suffix.isEmpty ? "" : "：\(suffix)")")
            }
            waitForSessionOutput(session, until: min(deadline, Date().addingTimeInterval(0.25)))
        }
        shutdownSession(session, graceful: false)
        return .failure("SteamCMD 登录超时，请检查网络或代理设置")
    }

    private static func outputShowsLoginSuccess(_ output: String) -> Bool {
        output.contains("Waiting for user info...OK") || output.contains("Logged in OK")
    }

    static func outputShowsAuthenticationFailure(_ output: String) -> Bool {
        output.localizedCaseInsensitiveContains("Invalid Password") ||
        output.localizedCaseInsensitiveContains("FAILED login") ||
        output.localizedCaseInsensitiveContains("Login Failure") ||
        output.localizedCaseInsensitiveContains("Steam Guard") ||
        output.localizedCaseInsensitiveContains("two-factor") ||
        output.localizedCaseInsensitiveContains("password:") ||
        output.localizedCaseInsensitiveContains("Cached credentials not found")
    }

    static func outputShowsConnectionFailure(_ output: String) -> Bool {
        output.localizedCaseInsensitiveContains("No Connection") ||
        output.localizedCaseInsensitiveContains("Failed to get list of download sources") ||
        output.localizedCaseInsensitiveContains("ERROR (Timeout)")
    }

    private func resetSessionOutput(_ session: Session) {
        session.condition.lock()
        session.output.removeAll(keepingCapacity: true)
        session.condition.unlock()
    }

    private func sessionSnapshot(_ session: Session) -> String {
        session.condition.lock()
        let data = session.output
        session.condition.unlock()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func sessionDidTerminate(_ session: Session) -> Bool {
        session.condition.lock()
        let terminated = session.terminated
        session.condition.unlock()
        return terminated || session.process?.isRunning != true
    }

    private func waitForSessionOutput(_ session: Session, until deadline: Date) {
        session.condition.lock()
        _ = session.condition.wait(until: deadline)
        session.condition.unlock()
    }

    /// workerQueue 专用。graceful 用于正常退出；取消/超时必须直接终止当前下载。
    private func shutdownSession(_ session: Session, graceful: Bool) {
        guard let p = session.process else {
            session.ready = false
            session.account = nil
            session.input = nil
            return
        }
        if p.isRunning, graceful, let input = session.input,
           let data = "quit\n".data(using: .utf8) {
            try? input.fileHandleForWriting.write(contentsOf: data)
            _ = Self.waitExit(p, timeout: 2)
        }
        if p.isRunning { Self.killProcessTree(p) }
        session.input?.fileHandleForWriting.closeFile()
        session.input = nil
        session.outputHandle?.readabilityHandler = nil
        session.outputHandle = nil
        p.terminationHandler = nil
        session.process = nil
        session.ready = false
        session.account = nil
        session.condition.lock()
        session.generation = UUID()
        session.terminated = true
        session.condition.broadcast()
        session.condition.unlock()
    }

    /// 在 main 线程调:把空闲并发槽位填上排队任务。
    private func pump() {
        guard !isStopping else { return }
        guard !authenticationInProgress else { return }
        var freeSlots = (0..<maximumConcurrentDownloads).filter { !runningSlots.values.contains($0) }
        for i in jobs.indices {
            guard !freeSlots.isEmpty else { break }
            let id = jobs[i].id
            lock.lock(); let discarding = discardingIDs.contains(id); lock.unlock()
            if jobs[i].state == .queued, jobs[i].phase != .subscribing, !discarding, runningSlots[id] == nil {
                let session = Session(slot: freeSlots.removeFirst())
                runningSlots[id] = session.slot
                session.group.enter()
                lock.lock(); sessions[id] = session; lock.unlock()
                jobs[i].state = .connecting
                jobs[i].phase = .startingDownloader
                jobs[i].startTime = Date()
                workerQueue.async {
                    self.download(id: id, session: session)
                    self.shutdownSession(session, graceful: true)
                    self.lock.lock(); self.sessions.removeValue(forKey: id); self.lock.unlock()
                    session.group.leave()
                    DispatchQueue.main.async { self.runningSlots.removeValue(forKey: id); self.pump() }
                }
            }
        }
        ensureLogPolling()   // 有活跃任务就开始抓 content_log 的真实进度
    }

    private func download(id: String, session: Session) {
        let t0 = Date()
        if let route = clientRoute(for: id) {
            switch waitForCrossOverSteam(id: id, route: route) {
            case .completed(let bytes):
                Log.write("WorkshopDownloader \(id): CrossOver Steam 完成并通过 ACF/目录双重校验")
                finish(id, .done, bytes: bytes, elapsed: Date().timeIntervalSince(t0))
                return
            case .cancelled:
                finish(id, .cancelled)
                return
            case .fallback(let reason):
                Log.write("WorkshopDownloader \(id): CrossOver 未接管，回退独立 SteamCMD — \(reason)")
            case .failed(let reason):
                Log.write("WorkshopDownloader \(id): CrossOver 已接管但未完成 — \(reason)")
                finish(id, .failed(reason))
                return
            }
        }
        guard steamcmdPath != nil else {
            finish(id, .failed("Steam 客户端未接管，且未安装 SteamCMD")); return
        }
        let downloaded = itemRoot(id)
            .appendingPathComponent("steamapps/workshop/content/\(appID)/\(id)").path
        var lastOut = ""
        var ok = false
        for retry in 1...2 {
            if isCancelled(id) { break }
            setPhase(id, retry == 1 ? .startingDownloader : .preparing, state: .connecting)
            setPhase(id, .authenticating, state: .connecting)
            switch ensureSessionReady(for: id, session: session) {
            case .failure(let reason):
                lastOut = reason
                break
            case .success:
                setPhase(id, .preparing, state: .connecting)
                let result = runDownloadCommand(id: id, session: session)
                lastOut = result.output
                if result.succeeded, FileManager.default.fileExists(atPath: downloaded) {
                    ok = true
                }
            }
            if ok || isCancelled(id) || lastOut.contains("File Not Found") ||
                Self.outputShowsAuthenticationFailure(lastOut) {
                break
            }
            Log.write("WorkshopDownloader \(id): 独立会话第 \(retry) 次下载失败，保留暂存内容重试")
            shutdownSession(session, graceful: false)
            if retry == 1 {
                setPhase(id, .reconnecting, state: .connecting)
                Thread.sleep(forTimeInterval: timeouts.retryDelay)
                DispatchQueue.main.async { if let i = self.jobs.firstIndex(where: { $0.id == id }) { self.jobs[i].attempt = 2 } }
            }
        }

        guard ok else {
            if isCancelled(id) { finish(id, .cancelled); return }   // 取消:保留 tmp,UI 决定保留/删除
            let out = lastOut
            // steamcmd 登录失败的真实文案不止 "FAILED login":缓存过期是 "ERROR (Invalid Password)",
            // 还有 "Login Failure"/"Rate Limit Exceeded"/Steam Guard 等。统一识别,避免误报成"网络问题"。
            let rateLimited = out.contains("Rate Limit")
            let loginIssue = out.contains("Invalid Password") || out.contains("FAILED login") ||
                             out.contains("Login Failure") || out.contains("Steam Guard") ||
                             out.contains("two-factor") || out.contains("Two-factor") ||
                             out.contains("登录已失效") || rateLimited
            let connectionIssue = out.contains("No Connection") ||
                                  out.contains("Failed to get list of download sources") ||
                                  out.contains("连接 Steam/CDN 超时") ||
                                  out.contains("登录超时")
            let hasAccount = accountOverride != nil || PreferencesStore.shared.steamAccount != nil
            let reason: String
            if out.contains("File Not Found") {
                reason = "工坊条目不存在或已下架"
            } else if rateLimited {
                reason = "Steam 登录请求过于频繁,请稍等几分钟后重试"
            } else if loginIssue && hasAccount {
                reason = "Steam 账号登录已失效,请重新登录后重试"
                DispatchQueue.main.async { self.loginExpired = true }   // 触发 UI 重新登录提醒
            } else if connectionIssue || Self.outputShowsConnectionFailure(out) || out.contains("连接 Steam/CDN 失败") {
                reason = "连接 Steam CDN 失败，请检查网络或代理后重试（暂存进度已保留）"
            } else if out.contains("下载进度长时间未增长") {
                reason = "下载长时间无响应，已自动重试；暂存进度已保留，可稍后继续"
            } else if !hasAccount {
                reason = "未登录 Steam,新壁纸需先登录账号"
                DispatchQueue.main.async { self.loginExpired = true }
            } else {
                reason = "下载失败(已重试),请检查网络后再试"
            }
            Log.write("WorkshopDownloader \(id): \(reason)\n\(out.suffix(300))")
            finish(id, .failed(reason)); return
        }

        // 移动到壁纸库目录(「旧的让位→移入→失败回滚」防两头空,理由见 installDownloaded 注释)。
        do {
            setPhase(id, .installing, state: .downloading)
            guard !isCancelled(id) else { finish(id, .cancelled); return }
            try installDownloaded(from: downloaded, id: id)
            Log.write("WorkshopDownloader \(id): done → \((libraryDirectoryOverride ?? PreferencesStore.shared.libraryRoot).appendingPathComponent(id).path)")
            finish(id, .done, bytes: Self.parseBytes(lastOut), elapsed: Date().timeIntervalSince(t0))
        } catch {
            finish(id, .failed("移动文件失败: \(error.localizedDescription)"))
        }
    }

    private enum CrossOverWaitResult {
        case completed(bytes: Int64)
        case fallback(String)
        case failed(String)
        case cancelled
    }

    /// workerQueue 专用。只读观察 CrossOver Steam，不伪装 WE 的 AppID、不改 ACF。
    /// 20 秒内没有任何单项接管证据才安全回退；一旦 Steam 已接管就绝不并行写同一个库。
    private func waitForCrossOverSteam(id: String, route: ClientRoute) -> CrossOverWaitResult {
        setPhase(id, .waitingForSteamClient, state: .connecting)
        let claimDeadline = Date().addingTimeInterval(20)
        let ownedDeadline = Date().addingTimeInterval(30 * 60)
        // 历史清单里有记录不代表客户端接管了本次下载。必须观察本次日志或清单变化。
        var claimed = false
        var consecutiveComplete = 0

        while !isCancelled(id) {
            let observation = CrossOverSteamClient.observe(
                route.context,
                id: id,
                logBaseline: route.logBaseline
            )

            if observation.isComplete {
                consecutiveComplete += 1
                if consecutiveComplete >= 2 {
                    return .completed(bytes: observation.manifestState.installedSize ?? 0)
                }
            } else {
                consecutiveComplete = 0
            }

            if !claimed, observation.hasTakenOver(since: route.initialManifest) {
                claimed = true
                Log.write("WorkshopDownloader \(id): CrossOver Steam 已识别该订阅")
            }

            if !CrossOverSteamClient.processIsRunning(route.processIdentifier) {
                return .fallback("对应 Steam 客户端已退出")
            }
            if claimed {
                setPhase(
                    id,
                    observation.clientSuspendedAfterBaseline ? .waitingForSteamClient : .steamClientDownloading,
                    state: observation.clientSuspendedAfterBaseline ? .connecting : .downloading
                )
                if Date() >= ownedDeadline {
                    return .failed("Steam 客户端已接管但 30 分钟仍未完成；请检查其下载队列后重试")
                }
            } else if Date() >= claimDeadline {
                // 最后再完整读一次，防止恰好处于 ACF 原子替换窗口。
                Thread.sleep(forTimeInterval: 0.25)
                let final = CrossOverSteamClient.observe(
                    route.context,
                    id: id,
                    logBaseline: route.logBaseline
                )
                if final.isComplete { continue }
                if !final.targetMentionedAfterBaseline,
                   final.manifestState == route.initialManifest {
                    return .fallback("20 秒内未发现该条目的队列或清单变化")
                }
                claimed = true
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return .cancelled
    }

    private struct DownloadCommandResult {
        var succeeded: Bool
        var output: String
    }

    /// 向本条目独享的会话发送命令；超时只重启本条目。
    private func runDownloadCommand(id: String, session: Session) -> DownloadCommandResult {
        guard session.ready, let p = session.process, p.isRunning,
              let input = session.input,
              let command = "workshop_download_item \(appID) \(id)\n".data(using: .utf8) else {
            return DownloadCommandResult(succeeded: false, output: "SteamCMD 会话未就绪")
        }
        resetSessionOutput(session)
        setProcess(id, p)
        do {
            try input.fileHandleForWriting.write(contentsOf: command)
        } catch {
            setProcess(id, nil)
            shutdownSession(session, graceful: false)
            return DownloadCommandResult(succeeded: false, output: "发送 SteamCMD 下载命令失败：\(error.localizedDescription)")
        }

        let startedAt = Date()
        var lastProgressAt = startedAt
        var lastChunks = committedChunks(forID: id)
        var sawCommandStart = false
        while !isCancelled(id) {
            let output = sessionSnapshot(session)
            if !sawCommandStart, output.contains("Downloading item \(id)") {
                sawCommandStart = true
                setPhase(id, .preparing, state: .connecting)
            }
            let chunks = committedChunks(forID: id)
            if chunks > lastChunks {
                lastChunks = chunks
                lastProgressAt = Date()
                setPhase(id, .transferring, state: .downloading)
            }
            if Self.outputShowsDownloadSuccess(output, id: id) {
                setProcess(id, nil)
                return DownloadCommandResult(succeeded: true, output: output)
            }
            if Self.outputShowsDownloadFailure(output, id: id) {
                setProcess(id, nil)
                return DownloadCommandResult(succeeded: false, output: output)
            }
            if sessionDidTerminate(session) {
                setProcess(id, nil)
                return DownloadCommandResult(succeeded: false, output: output + "\nSteamCMD 会话意外退出")
            }

            // “有日志”不代表有下载。SteamCMD 遇到代理/CDN 故障会持续打印 Retrying，
            // 旧版因此永远碰不到 10 分钟静默超时。现在按真正的 patch 块是否增长判断。
            let now = Date()
            if let reason = Self.downloadTimeoutReason(
                sawCommandStart: sawCommandStart,
                elapsed: now.timeIntervalSince(startedAt),
                idle: now.timeIntervalSince(lastProgressAt),
                startTimeout: timeouts.commandStart, progressTimeout: timeouts.noProgress
            ) {
                Log.write("WorkshopDownloader \(id): \(reason)，重启本项会话")
                setProcess(id, nil)
                shutdownSession(session, graceful: false)
                return DownloadCommandResult(succeeded: false, output: output + "\n[LiveWallpaper] \(reason)")
            }
            waitForSessionOutput(session, until: Date().addingTimeInterval(0.25))
        }

        setProcess(id, nil)
        shutdownSession(session, graceful: false)
        return DownloadCommandResult(succeeded: false, output: "用户取消下载")
    }

    static func outputShowsDownloadSuccess(_ output: String, id: String) -> Bool {
        output.contains("Success. Downloaded item \(id) ")
    }

    static func outputShowsDownloadFailure(_ output: String, id: String) -> Bool {
        output.contains("ERROR! Download item \(id) failed") ||
        outputShowsAuthenticationFailure(output) || outputShowsConnectionFailure(output)
    }

    static func downloadTimeoutReason(sawCommandStart: Bool, elapsed: TimeInterval, idle: TimeInterval, startTimeout: TimeInterval = 60, progressTimeout: TimeInterval = 180) -> String? {
        if !sawCommandStart, elapsed > startTimeout { return "连接 Steam/CDN 超时" }
        // 第一块一直未到也必须超时；原来 lastChunks > 0 会让零进度任务永远卡住。
        if sawCommandStart, idle > progressTimeout { return "下载进度长时间未增长" }
        return nil
    }

    /// 把下载好的目录移入壁纸库(正常完成与「取消但保留」共用)。纯文件操作,任意线程可调。
    /// ⚠ 不能「先删旧再移动」:removeItem 成功而 moveItem 失败(磁盘满 / 目标卷是用户自选的外置盘
    ///   且已卸载或无权限)时,旧壁纸已被**直接删除**(非废纸篓)且新的没落地 → 两头皆空、不可恢复。
    ///   改成「旧的先改名让位 → 移入新的 → 成功才删旧;任何一步失败就把旧的改回来」。
    private func installDownloaded(from downloaded: String, id: String) throws {
        let dest = (libraryDirectoryOverride ?? PreferencesStore.shared.libraryRoot).appendingPathComponent(id)
        let fm = FileManager.default
        var parked: URL?          // 旧壁纸的临时让位路径
        do {
            if fm.fileExists(atPath: dest.path) {
                let p = dest.deletingLastPathComponent()
                    .appendingPathComponent(".\(id).replacing-\(UUID().uuidString.prefix(8))")
                try fm.moveItem(at: dest, to: p)
                parked = p
            }
            try fm.moveItem(atPath: downloaded, toPath: dest.path)
            if let p = parked { try? fm.removeItem(at: p) }   // 新的已就位,旧的可以删了
        } catch {
            // 回滚:把让位的旧壁纸放回原处,保证失败后用户仍有原来那份可用。
            if let p = parked, !fm.fileExists(atPath: dest.path) {
                try? fm.moveItem(at: p, to: dest)
            }
            throw error
        }
    }

    /// 用账号+密码登录一次 steamcmd(让它缓存凭据,后续下载免密)。
    /// 返回 (成功, 是否需要 Steam Guard 验证码, 提示)。在后台线程调用。
    private final class LoginOutput {
        private let lock = NSLock()
        private var data = Data()
        func store(_ value: Data) { lock.lock(); data = value; lock.unlock() }
        func text() -> String {
            lock.lock(); defer { lock.unlock() }
            return String(decoding: data, as: UTF8.self)
        }
    }

    func login(account: String, password: String, guardCode: String?,
               completion: @escaping (Bool, Bool, String) -> Void) {
        guard steamcmdPath != nil else { completion(false, false, "未安装 SteamCMD"); return }
        loginQueue.async {
            // 暂停调度并等现有任务收尾，再更新用户授权缓存。
            DispatchQueue.main.sync { self.authenticationInProgress = true }
            defer { DispatchQueue.main.async { self.authenticationInProgress = false; self.pump() } }
            self.workerQueue.sync(flags: .barrier) {}
            guard let p = self.makeSteamCMDProcess(arguments: ["+login", account, "+quit"]) else {
                DispatchQueue.main.async { completion(false, false, "未安装 SteamCMD") }
                return
            }
            // ⚠ 安全(审计):密码/Steam Guard 验证码**不能**放进 argv。macOS 上同一 uid 的任何进程
            //   都能用 `ps -ef` / KERN_PROCARGS2 读到完整命令行,登录过程可达数十秒(含等验证码),
            //   期间账号+密码+验证码三者明文可见。而且 /opt/homebrew/bin/steamcmd 是 shell wrapper、
            //   steamcmd.sh 又不 exec,同一份 argv 会同时出现在两个进程里。
            //   改走 stdin:argv 只留账号,密码与验证码经管道喂进去。
            //   已实测(用不存在的账号验证机制):steamcmd 在 stdin 是管道时仍会打印 "password: "
            //   并从管道读取,随后正常走登录流程 → 该方式可用。
            let inPipe = Pipe()
            p.standardInput = inPipe
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
            do { try p.run() } catch { DispatchQueue.main.async { completion(false, false, "启动失败") }; return }
            var feed = password + "\n"
            if let g = guardCode, !g.isEmpty { feed += g + "\n" }   // 令牌提示紧随密码之后
            if let d = feed.data(using: .utf8) { inPipe.fileHandleForWriting.write(d) }
            try? inPipe.fileHandleForWriting.close()   // 必须关,否则 steamcmd 会一直等输入
            // 读输出不能无限等 EOF：网络无响应时，登录弹窗以前会一直转圈。
            let captured = LoginOutput()
            let readComplete = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .utility).async {
                captured.store(pipe.fileHandleForReading.readDataToEndOfFile())
                readComplete.signal()
            }
            let timedOut = readComplete.wait(timeout: .now() + 120) == .timedOut
            if timedOut {
                if p.isRunning { Self.killProcessTree(p) }
                _ = readComplete.wait(timeout: .now() + 5)
            }
            _ = Self.waitExit(p, timeout: 5)
            let out = captured.text()
            let success = out.contains("Waiting for user info...OK") || out.contains("Logged in OK")
            let needGuard = out.contains("Steam Guard") || out.contains("two-factor") || out.contains("Two-factor")
            DispatchQueue.main.async {
                if success {
                    PreferencesStore.shared.steamAccount = account
                    self.loginExpired = false

                }
                let msg: String
                if success { msg = "登录成功" }
                else if timedOut || Self.outputShowsConnectionFailure(out) {
                    msg = "连接 Steam 超时或失败，请检查网络或代理后重试"
                } else if needGuard { msg = "需要 Steam 令牌验证码" }
                else { msg = "登录失败,请检查账号密码" }
                completion(success, needGuard, msg)
            }
        }
    }

    private func setState(_ id: String, _ s: Job.State) {
        DispatchQueue.main.async {
            if let i = self.jobs.firstIndex(where: { $0.id == id }) { self.jobs[i].state = s }
        }
    }

    private func setPhase(_ id: String, _ phase: Job.Phase, state: Job.State? = nil) {
        DispatchQueue.main.async {
            guard let i = self.jobs.firstIndex(where: { $0.id == id }) else { return }
            self.jobs[i].phase = phase
            if let state { self.jobs[i].state = state }
        }
    }

    private func finish(_ id: String, _ s: Job.State, bytes: Int64 = 0, elapsed: TimeInterval = 0) {
        lock.lock(); let discarding = discardingIDs.contains(id); lock.unlock()
        // 退订会主动丢弃下载，不弹“保留文件”询问；由 discard 等 worker 收尾后统一清理。
        if discarding { return }
        clearTracking(id)
        DispatchQueue.main.async {
            if let i = self.jobs.firstIndex(where: { $0.id == id }) {
                self.jobs[i].state = s
                if case .done = s {
                    self.jobs[i].phase = .installing
                    if bytes > 0 { self.jobs[i].totalBytes = bytes }   // steamcmd 报的真实大小
                    self.jobs[i].elapsed = elapsed                     // 真实耗时 → avgSpeedMBps 真实平均速度
                }
            }
            self.pump()   // 有空位就启动下一个
            // 保留本次会话的完成记录，由下载中心手动清除。
        }
    }

    /// 从 steamcmd 的 "Success ... (69933475 bytes)" 里解析真实字节数。
    private static func parseBytes(_ s: String) -> Int64 {
        guard let r = s.range(of: #"\(\d+ bytes\)"#, options: .regularExpression) else { return 0 }
        return Int64(String(s[r].filter(\.isNumber))) ?? 0
    }

    /// 请求取消下载:杀掉正在跑的 steamcmd。临时文件保留,由 resolveCancelled 决定去留。
    func requestCancel(id: String) {
        lock.lock()
        cancelledSet.insert(id)
        let p = processes[id]
        lock.unlock()
        // ⚠ 不能只 terminate():SIGTERM 到不了真正在下载的孙进程(brew wrapper 不 exec,见 killProcessTree
        //   注释),wrapper 会陪着孙进程一起不退 → download 线程收尾等它时被无限卡住、孙进程继续烧带宽。
        //   杀整棵树;killProcessTree 内含 3s 宽限的同步 sleep,不能在调用方线程(常是主线程)跑,丢后台队列。
        if let p { DispatchQueue.global(qos: .utility).async { Self.killProcessTree(p) } }
        DispatchQueue.main.async {
            // 还在排队没轮到的直接删掉(它不会进 download);正在下的等进程退出后转 .cancelled
            if let i = self.jobs.firstIndex(where: { $0.id == id }), self.jobs[i].state == .queued {
                self.jobs.remove(at: i)
                self.clearTracking(id)
            }
            self.pump()
        }
    }

    /// 退订的确定性收尾：先阻止安装，等本条目的 worker 退出后再清暂存并允许删除库目录。
    /// 普通“取消下载”仍保留原先的保留/删除询问。
    func discard(id: String, completion: @escaping () -> Void) {
        precondition(Thread.isMainThread)
        guard WallpaperUninstallPolicy.isSteamWorkshopID(id) else { completion(); return }
        lock.lock()
        cancelledSet.insert(id)
        discardingIDs.insert(id)
        let process = processes[id]
        let session = sessions[id]
        lock.unlock()
        if let process { DispatchQueue.global(qos: .utility).async { Self.killProcessTree(process) } }
        let cleanup = {
            for kind in ["content", "downloads"] {
                let folder = self.stagingRoot.appendingPathComponent("steamapps/workshop/\(kind)/\(self.appID)/\(id)")
                try? FileManager.default.removeItem(at: folder)
            }
            try? FileManager.default.removeItem(at: self.itemRoot(id))
            self.removePatchFiles(forID: id)
            self.clearTracking(id)
            DispatchQueue.main.async {
                self.jobs.removeAll { $0.id == id }
                self.lock.lock(); self.discardingIDs.remove(id); self.lock.unlock()
                self.pump()
                completion()
            }
        }
        if let session { session.group.notify(queue: workerQueue, execute: cleanup) }
        else { workerQueue.async(execute: cleanup) }
    }

    /// 取消后处理临时文件:keep=保留(若恰好已下完则入库),否则删除。最后移除任务。
    func resolveCancelled(id: String, keep: Bool) {
        loginQueue.async {
            self.lock.lock(); let session = self.sessions[id]; self.lock.unlock()
            session?.group.wait()
            let downloaded = self.itemRoot(id)
                .appendingPathComponent("steamapps/workshop/content/\(self.appID)/\(id)").path
            if keep, FileManager.default.fileExists(atPath: downloaded + "/project.json") {
                // 与正常完成路径共用 installDownloaded 的让位/回滚:旧代码在这里直接 removeItem(dest)
                // 再 move,move 一失败(磁盘满/权限)旧壁纸已被永久删掉、两头皆空。
                do {
                    try self.installDownloaded(from: downloaded, id: id)
                    Log.write("WorkshopDownloader \(id): cancelled-but-kept (was complete)")
                } catch {
                    Log.write("WorkshopDownloader \(id): cancelled-but-kept 入库失败: \(error.localizedDescription)(旧壁纸未受影响)")
                }
            }
            if !keep || FileManager.default.fileExists(atPath: downloaded) {
                try? FileManager.default.removeItem(atPath: downloaded)
            }
            if !keep { try? FileManager.default.removeItem(at: self.itemRoot(id)) }
            self.removePatchFiles(forID: id)
            self.clearTracking(id)
            DispatchQueue.main.async { self.jobs.removeAll { $0.id == id } }
        }
    }

    /// 清掉所有已完成/失败/取消的任务。
    func clearFinished() {
        DispatchQueue.main.async {
            self.jobs.removeAll {
                switch $0.state { case .done, .failed, .cancelled: return true; default: return false }
            }
        }
    }

    /// 重新下载一个失败/取消的任务:清掉进度与状态,重新排队。
    func retry(id: String) {
        DispatchQueue.main.async {
            guard let i = self.jobs.firstIndex(where: { $0.id == id }) else { return }
            self.retryLocked(index: i)
        }
    }

    /// retry 的实现体。**必须在主线程调用**(jobs 只在主线程读写)。
    /// 抽出来是为了让 enqueue 对「同 id 的失败/取消任务」也能走重下,而不是被去重直接丢弃。
    private func retryLocked(index i: Int, waitForSubscription: Bool = false) {
        let id = jobs[i].id
        if runningSlots[id] != nil {
            lock.lock(); let session = sessions[id]; lock.unlock()
            if let session { session.group.notify(queue: .main) { self.retry(id: id) } }
            else { DispatchQueue.main.async { self.retry(id: id) } }
            return
        }
        var j = jobs[i]
        j.attempt = 1
        j.state = .queued; j.startTime = nil; j.elapsed = 0
        j.phase = waitForSubscription ? .subscribing : .queued
        j.committedChunks = 0; j.totalChunks = 0
        j.downloadedBytes = 0; j.logTotal = 0
        j.liveSpeedMBps = 0; j.lastSpeedBytes = -1; j.lastSpeedTime = nil
        j.lastSampleBytes = nil; j.lastSampleTime = nil
        jobs[i] = j
        lock.lock(); cancelledSet.remove(j.id); lock.unlock()
        if !waitForSubscription { configureClientRoute(for: j) }
        pump()
    }

    /// 从列表移除一个任务(失败/取消/完成的;若正在下则先杀进程)+ 清临时目录。
    func remove(id: String) {
        DispatchQueue.main.async { self.discard(id: id) {} }
    }


    // MARK: - 真实下载进度
    //
    // steamcmd 的 workshop_download_item 不在 stdout 报进度,下载文件还是预分配+非稀疏的
    // (du/文件大小会瞬间跳满),所以进度要从别处拿。两个信号配合:
    //  1) 主信号——每条目临时目录里的 .patch 文件(downloads/state_<app>_<app>_<id>.patch)
    //     每提交一块追加 24 字节,所以「已提交块数 = 文件大小/24」。它每条目独立、高频更新,
    //     对大文件小文件都管用。总块数 N 从 content_log 的 "Downloading N chunks for depot 431960" 拿
    //     (拿不到就按 ~1MB/块从总字节估算)。fraction = 已提交块 / 总块。
    //  2) 辅助信号——content_log.txt 的 "update started : download <已下载>/<总>" 行有真实字节,
    //     但更新很稀疏(~1-2 分钟一次),只用来显示精确的 已下载/总 MB 与实时速度。
    // 每个 worker 的 HOME、content_log、下载暂存目录各自独立，日志按任务关联。

    private let logQueue = DispatchQueue(label: "workshop.contentlog")
    private var logTimer: DispatchSourceTimer?   // 仅主线程访问
    private struct LogCursor { var offset: UInt64 = 0; var tail = "" }
    private var logCursors: [String: LogCursor] = [:] // logQueue 专用

    static func isActive(_ s: Job.State) -> Bool {
        switch s { case .queued, .connecting, .downloading: return true; default: return false }
    }

    /// 有活跃任务时开始轮询 content_log(已在跑则忽略)。主线程调用。
    private func ensureLogPolling() {
        guard logTimer == nil, jobs.contains(where: { Self.isActive($0.state) }) else { return }
        let timer = DispatchSource.makeTimerSource(queue: logQueue)
        timer.schedule(deadline: .now() + 0.4, repeating: 0.4)
        timer.setEventHandler { [weak self] in self?.pollLog() }
        logTimer = timer
        timer.resume()
    }

    private func stopLogPolling() {   // 主线程调用
        logTimer?.cancel()
        logTimer = nil
    }

    /// 每个会话只读自己的 HOME 下的日志，绝不按大小猜任务归属。
    private func pollLog() {
        lock.lock(); let active = sessions; lock.unlock()
        var updates: [(String, [(cur: Int64, tot: Int64)], [Int])] = []
        for (id, session) in active {
            session.condition.lock()
            let ready = session.logsReady, generation = session.generation
            session.condition.unlock()
            guard ready else { continue }
            let key = "\(id):\(generation)"
            var cursor = logCursors[key] ?? LogCursor()
            let url = workerHome(session.slot).appendingPathComponent("Library/Application Support/Steam/logs/content_log.txt")
            var samples: [(cur: Int64, tot: Int64)] = []; var counts: [Int] = []
            if let fh = try? FileHandle(forReadingFrom: url) {
                defer { try? fh.close() }
                let end = (try? fh.seekToEnd()) ?? 0
                if end < cursor.offset { cursor = LogCursor() }
                if end > cursor.offset {
                    try? fh.seek(toOffset: cursor.offset)
                    let data = (try? fh.readToEnd()) ?? Data(); cursor.offset = end
                    var lines = (cursor.tail + String(decoding: data, as: UTF8.self)).components(separatedBy: "\n")
                    cursor.tail = lines.popLast() ?? ""
                    for line in lines {
                        if line.contains("AppID \(appID)"), let sample = Self.parseDownloadLine(line) { samples.append(sample) }
                        if let n = Self.parseChunkCount(line, appID: appID) { counts.append(n) }
                    }
                }
            }
            logCursors[key] = cursor
            updates.append((id, samples, counts))
        }
        let keys = Set(updates.map { $0.0 })
        logCursors = logCursors.filter { keys.contains($0.key.components(separatedBy: ":")[0]) }
        DispatchQueue.main.async { self.applyLogSamples(updates) }
    }

    private func applyLogSamples(_ updates: [(String, [(cur: Int64, tot: Int64)], [Int])]) {
        let now = Date()
        for (id, samples, counts) in updates {
            guard let i = jobs.firstIndex(where: { $0.id == id && Self.isActive($0.state) }) else { continue }
            if let n = counts.last { jobs[i].totalChunks = n }
            for sample in samples {
                jobs[i].logTotal = sample.tot
                jobs[i].downloadedBytes = max(jobs[i].downloadedBytes, sample.cur)
                jobs[i].lastSampleTime = now
                if sample.cur > 0 { jobs[i].state = .downloading; jobs[i].phase = .transferring }
            }
        }
        // 主信号:每个活跃任务查 .patch 块进度(单调),并按「有效已下载量」逐次增量算实时速率。
        // patch 块数高频增长(每块即更新),所以速率不再依赖稀疏的 content_log 字节采样。
        for i in jobs.indices where Self.isActive(jobs[i].state) {
            let c = committedChunks(forID: jobs[i].id)
            if c > jobs[i].committedChunks {
                jobs[i].committedChunks = c
                jobs[i].state = .downloading
                jobs[i].phase = .transferring
            }
            // 速率用**单调的块量**算(committedChunks × 真实平均块大小),不用会随分母切换突跳的 fraction →
            // 速度无尖峰、无长时间不更新(修复3)。N 未到时按 1MB/块近似(仅影响极早期速度显示)。
            let bytesPerChunk = jobs[i].totalChunks > 0
                ? Double(jobs[i].effectiveTotal) / Double(jobs[i].totalChunks)
                : 1_048_576.0
            let eff = Int64(Double(jobs[i].committedChunks) * bytesPerChunk)
            if jobs[i].lastSpeedBytes >= 0, let lt = jobs[i].lastSpeedTime {
                let dt = now.timeIntervalSince(lt)
                if dt >= 1.0 {   // 1s 窗口:平掉块提交的突发,速率更稳更准
                    let inst = Double(eff - jobs[i].lastSpeedBytes) / 1_048_576 / dt
                    if inst >= 0 {
                        // EMA 平滑:新旧各半
                        jobs[i].liveSpeedMBps = jobs[i].liveSpeedMBps > 0 ? jobs[i].liveSpeedMBps * 0.5 + inst * 0.5 : inst
                    }
                    jobs[i].lastSpeedBytes = eff
                    jobs[i].lastSpeedTime = now
                }
            } else {
                jobs[i].lastSpeedBytes = eff
                jobs[i].lastSpeedTime = now
            }
        }
        if !jobs.contains(where: { Self.isActive($0.state) }) { stopLogPolling() }
    }

    /// 读该任务临时目录里的 .patch 文件大小 → 已提交块数(每块 24 字节)。读不到返回 0。
    private func committedChunks(forID id: String) -> Int {
        let dir = itemRoot(id).appendingPathComponent("steamapps/workshop/downloads").path
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir),
              let name = files.first(where: { $0.hasSuffix("_\(id).patch") }),
              let attrs = try? FileManager.default.attributesOfItem(atPath: dir + "/" + name),
              let size = (attrs[.size] as? NSNumber)?.intValue else { return 0 }
        return size / 24
    }

    private func removePatchFiles(forID id: String) {
        let dir = stagingRoot.appendingPathComponent("steamapps/workshop/downloads")
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil
        ) else { return }
        for file in files where file.lastPathComponent.hasSuffix("_\(id).patch") {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// 解析 "… : download <cur>/<tot>, …" 里的 (已下载, 总) 字节。非进度行返回 nil。
    static func parseDownloadLine(_ line: String) -> (cur: Int64, tot: Int64)? {
        guard let r = line.range(of: #"download \d+/\d+"#, options: .regularExpression) else { return nil }
        let parts = line[r].dropFirst("download ".count).split(separator: "/")
        guard parts.count == 2, let cur = Int64(parts[0]), let tot = Int64(parts[1]), tot > 0 else { return nil }
        return (cur, tot)
    }

    /// 解析 "Downloading <N> chunks for depot <appID>" 里的总块数 N。非该行返回 nil。
    static func parseChunkCount(_ line: String, appID: String) -> Int? {
        guard line.contains("chunks for depot \(appID)"),
              let r = line.range(of: #"Downloading \d+ chunks"#, options: .regularExpression) else { return nil }
        return Int(line[r].filter(\.isNumber))
    }

    // MARK: - 共享状态(processes/cancelledSet)线程安全访问

    private func setProcess(_ id: String, _ p: Process?) {
        lock.lock(); if let p { processes[id] = p } else { processes.removeValue(forKey: id) }; lock.unlock()
    }
    private func isCancelled(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }; return stopping || cancelledSet.contains(id)
    }
    private func clearTracking(_ id: String) {
        lock.lock()
        processes.removeValue(forKey: id)
        clientRoutes.removeValue(forKey: id)
        cancelledSet.remove(id)
        lock.unlock()
    }
    private func clientRoute(for id: String) -> ClientRoute? {
        lock.lock(); defer { lock.unlock() }
        return clientRoutes[id]
    }
}
