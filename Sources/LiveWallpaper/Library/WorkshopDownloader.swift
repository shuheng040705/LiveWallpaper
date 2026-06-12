import Foundation

/// 用 SteamCMD 下载 Wallpaper Engine(appid 431960)的创意工坊壁纸。
/// 实测:匿名即可下载大多数老壁纸、内容为明文、force_install_dir 可控落点。下完移动到
/// 壁纸库目录,FolderWatcher 自动刷新进库。支持并发(最多同时 maxConcurrent 个)。
///
/// 注意:依赖系统装有 steamcmd(brew install --cask steamcmd)。未装时给出提示。
final class WorkshopDownloader: ObservableObject {
    static let shared = WorkshopDownloader()
    private let appID = "431960"
    private let maxConcurrent = 3   // 同时下载数

    struct Job: Identifiable, Equatable {
        let id: String          // workshop id
        var title: String
        var state: State = .queued
        var startTime: Date?    // 开始下载的时刻(算已用时间)
        var totalBytes: Int64 = 0       // 网页抓的目标大小;完成时被 steamcmd 真实值覆盖
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

        enum State: Equatable { case queued, connecting, downloading, done, cancelled, failed(String) }

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
    }

    @Published private(set) var jobs: [Job] = []
    @Published var loginExpired = false   // 检测到账号登录失效 → UI 弹「重新登录」提醒

    private let loginQueue = DispatchQueue(label: "workshop.login", qos: .utility)
    private let lock = NSLock()
    private var processes: [String: Process] = [:]   // 进行中的 steamcmd(供取消)
    private var cancelledSet: Set<String> = []        // 已请求取消的 id

    /// steamcmd 可执行路径(brew cask 的 wrapper)。
    private var steamcmdPath: String? {
        let candidates = ["/opt/homebrew/bin/steamcmd", "/usr/local/bin/steamcmd"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    var isSteamCMDAvailable: Bool { steamcmdPath != nil }

    /// 未完成(排队/连接/下载中)的任务数,供工具栏角标显示。
    var pendingCount: Int {
        jobs.filter { switch $0.state { case .queued, .connecting, .downloading: return true; default: return false } }.count
    }

    /// 加入下载队列。title 仅用于显示,sizeBytes 来自网页(估算进度)。
    func enqueue(id: String, title: String, sizeBytes: Int64 = 0) {
        DispatchQueue.main.async {
            guard !self.jobs.contains(where: { $0.id == id }) else { return }
            self.jobs.append(Job(id: id, title: title, totalBytes: sizeBytes))
            self.pump()
        }
    }

    private var didPrewarm = false
    /// 预热 + **登录续期**:app 启动后台跑一次 steamcmd 登录。
    /// 配了账号就用账号 `+login <account> +quit` —— steamcmd 每次成功登录都会从 Steam 拿一个新的
    /// refresh token 并存回 config.vdf,所以这相当于给登录态**续期**。只要在 token 服务端有效期内
    /// (隔天就掉的那种)打开过 app,登录就一直有效,缓解「天天要重新登录」。
    /// 续期失败(token 已被作废)→ 立刻标记 loginExpired,让 UI 及时提醒重新登录,而不是等下载失败才知道。
    /// 没配账号则匿名预热(仅 bootstrap,跳过首次下载冷启动)。
    func prewarm() {
        guard !didPrewarm, let steamcmd = steamcmdPath else { return }
        didPrewarm = true
        let account = PreferencesStore.shared.steamAccount
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: steamcmd)
            p.arguments = ["+login", account ?? "anonymous", "+quit"]
            p.standardInput = FileHandle.nullDevice
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
            guard (try? p.run()) != nil else { return }
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            p.waitUntilExit()
            guard let account else {
                Log.write("WorkshopDownloader: steamcmd 预热完成(匿名)"); return
            }
            let ok = out.contains("Waiting for user info...OK") || out.contains("Logged in OK")
            DispatchQueue.main.async { self.loginExpired = !ok }
            Log.write("WorkshopDownloader: 账号 \(account) token 续期\(ok ? "成功" : "失败(需重新登录)")")
        }
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

    /// 在 main 线程调:把空闲并发槽位填上排队任务。
    private func pump() {
        let active = jobs.filter { $0.state == .connecting || $0.state == .downloading }.count
        var slots = maxConcurrent - active
        guard slots > 0 else { return }
        for i in jobs.indices where slots > 0 {
            if jobs[i].state == .queued {
                let id = jobs[i].id
                jobs[i].state = .connecting
                jobs[i].startTime = Date()
                slots -= 1
                DispatchQueue.global(qos: .utility).async { [weak self] in self?.download(id: id) }
            }
        }
        ensureLogPolling()   // 有活跃任务就开始抓 content_log 的真实进度
    }

    private func download(id: String) {
        guard let steamcmd = steamcmdPath else {
            finish(id, .failed("未安装 SteamCMD")); return
        }
        let tmp = NSTemporaryDirectory() + "lw_dl_\(id)"
        let downloaded = tmp + "/steamapps/workshop/content/\(appID)/\(id)"
        let t0 = Date()
        setState(id, .downloading)

        // 登录策略:配了 Steam 账号就**先用账号**(能下它拥有的一切,新老条目都行),匿名仅作兜底。
        // (实测:匿名下不了新发布条目,会先白等约 20 秒重试再轮到账号——用户常在此期间误以为卡住而取消。
        //  账号能下时,账号优先 → 立刻开始下载、立刻产出 patch/content_log → 进度百分比立刻可见。)
        var attempts: [String] = []
        if let acct = PreferencesStore.shared.steamAccount { attempts.append(acct) }
        attempts.append("anonymous")

        var lastOut = ""
        var ok = false
        outer: for login in attempts {
            for retry in 1...2 {   // steamcmd 冷启动偶发 No Connection,每种登录重试 2 次
                if isCancelled(id) { break outer }
                try? FileManager.default.removeItem(atPath: tmp)
                let p = Process()
                p.executableURL = URL(fileURLWithPath: steamcmd)
                p.arguments = ["+force_install_dir", tmp, "+login", login,
                               "+workshop_download_item", appID, id, "+quit"]
                p.standardInput = FileHandle.nullDevice   // 避免 Steam Guard 交互阻塞读管道
                let pipe = Pipe()
                p.standardOutput = pipe; p.standardError = pipe
                do { try p.run() } catch { finish(id, .failed("启动失败: \(error.localizedDescription)")); return }
                setProcess(id, p)
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                setProcess(id, nil)
                lastOut = String(data: data, encoding: .utf8) ?? ""

                if isCancelled(id) { break outer }   // 取消:保留临时目录,交给 UI 询问保留/删除
                if lastOut.contains("Success") && FileManager.default.fileExists(atPath: downloaded) {
                    ok = true; break outer
                }
                if lastOut.contains("File Not Found") { break outer }  // 条目不存在,别试了
                if lastOut.contains("FAILED login") || lastOut.contains("Invalid Password") ||
                   lastOut.contains("two-factor") || lastOut.contains("Steam Guard") {
                    Log.write("WorkshopDownloader \(id): login '\(login)' needs auth"); break
                }
                Log.write("WorkshopDownloader \(id): login=\(login) retry \(retry) failed")
                Thread.sleep(forTimeInterval: 2)
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
                             out.contains("two-factor") || out.contains("Two-factor") || rateLimited
            let hasAccount = PreferencesStore.shared.steamAccount != nil
            let reason: String
            if out.contains("File Not Found") {
                reason = "工坊条目不存在或已下架"
            } else if rateLimited {
                reason = "Steam 登录请求过于频繁,请稍等几分钟后重试"
            } else if loginIssue && hasAccount {
                reason = "Steam 账号登录已失效,请重新登录后重试"
                DispatchQueue.main.async { self.loginExpired = true }   // 触发 UI 重新登录提醒
            } else if !hasAccount {
                reason = "未登录 Steam,新壁纸需先登录账号"
                DispatchQueue.main.async { self.loginExpired = true }
            } else {
                reason = "下载失败(已重试),请检查网络后再试"
            }
            Log.write("WorkshopDownloader \(id): \(reason)\n\(out.suffix(300))")
            finish(id, .failed(reason)); return
        }

        // 移动到壁纸库目录。
        let dest = PreferencesStore.shared.libraryRoot.appendingPathComponent(id)
        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.moveItem(atPath: downloaded, toPath: dest.path)
            try? FileManager.default.removeItem(atPath: tmp)
            Log.write("WorkshopDownloader \(id): done → \(dest.path)")
            finish(id, .done, bytes: Self.parseBytes(lastOut), elapsed: Date().timeIntervalSince(t0))
        } catch {
            finish(id, .failed("移动文件失败: \(error.localizedDescription)"))
        }
    }

    /// 用账号+密码登录一次 steamcmd(让它缓存凭据,后续下载免密)。
    /// 返回 (成功, 是否需要 Steam Guard 验证码, 提示)。在后台线程调用。
    func login(account: String, password: String, guardCode: String?,
               completion: @escaping (Bool, Bool, String) -> Void) {
        guard let steamcmd = steamcmdPath else { completion(false, false, "未安装 SteamCMD"); return }
        loginQueue.async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: steamcmd)
            var args = ["+login", account, password]
            if let g = guardCode, !g.isEmpty { args.append(g) }
            args.append("+quit")
            p.arguments = args
            p.standardInput = FileHandle.nullDevice
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
            do { try p.run() } catch { DispatchQueue.main.async { completion(false, false, "启动失败") }; return }
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            p.waitUntilExit()
            let success = out.contains("Waiting for user info...OK") || out.contains("Logged in OK")
            let needGuard = out.contains("Steam Guard") || out.contains("two-factor") || out.contains("Two-factor")
            DispatchQueue.main.async {
                if success { PreferencesStore.shared.steamAccount = account; self.loginExpired = false }
                let msg = success ? "登录成功" : (needGuard ? "需要 Steam 令牌验证码" : "登录失败,请检查账号密码")
                completion(success, needGuard, msg)
            }
        }
    }

    private func setState(_ id: String, _ s: Job.State) {
        DispatchQueue.main.async {
            if let i = self.jobs.firstIndex(where: { $0.id == id }) { self.jobs[i].state = s }
        }
    }

    private func finish(_ id: String, _ s: Job.State, bytes: Int64 = 0, elapsed: TimeInterval = 0) {
        clearTracking(id)
        DispatchQueue.main.async {
            if let i = self.jobs.firstIndex(where: { $0.id == id }) {
                self.jobs[i].state = s
                if case .done = s {
                    if bytes > 0 { self.jobs[i].totalBytes = bytes }   // steamcmd 报的真实大小
                    self.jobs[i].elapsed = elapsed                     // 真实耗时 → avgSpeedMBps 真实平均速度
                }
            }
            self.pump()   // 有空位就启动下一个
            // 完成的 8 秒后从列表移除(失败/取消的保留让用户看到/决定)。
            if case .done = s {
                DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                    self.jobs.removeAll { $0.id == id && $0.state == .done }
                }
            }
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
        p?.terminate()
        DispatchQueue.main.async {
            // 还在排队没轮到的直接删掉(它不会进 download);正在下的等进程退出后转 .cancelled
            if let i = self.jobs.firstIndex(where: { $0.id == id }), self.jobs[i].state == .queued {
                self.jobs.remove(at: i)
                self.clearTracking(id)
            }
            self.pump()
        }
    }

    /// 取消后处理临时文件:keep=保留(若恰好已下完则入库),否则删除。最后移除任务。
    func resolveCancelled(id: String, keep: Bool) {
        loginQueue.async {
            let tmp = NSTemporaryDirectory() + "lw_dl_\(id)"
            let downloaded = tmp + "/steamapps/workshop/content/\(self.appID)/\(id)"
            if keep, FileManager.default.fileExists(atPath: downloaded + "/project.json") {
                let dest = PreferencesStore.shared.libraryRoot.appendingPathComponent(id)
                try? FileManager.default.removeItem(at: dest)
                try? FileManager.default.moveItem(atPath: downloaded, toPath: dest.path)
                Log.write("WorkshopDownloader \(id): cancelled-but-kept (was complete)")
            }
            try? FileManager.default.removeItem(atPath: tmp)
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
            var j = self.jobs[i]
            j.state = .queued; j.startTime = nil; j.elapsed = 0
            j.committedChunks = 0; j.totalChunks = 0
            j.downloadedBytes = 0; j.logTotal = 0
            j.liveSpeedMBps = 0; j.lastSpeedBytes = -1; j.lastSpeedTime = nil
            j.lastSampleBytes = nil; j.lastSampleTime = nil
            self.jobs[i] = j
            self.lock.lock(); self.cancelledSet.remove(id); self.lock.unlock()
            self.pump()
        }
    }

    /// 从列表移除一个任务(失败/取消/完成的;若正在下则先杀进程)+ 清临时目录。
    func remove(id: String) {
        lock.lock(); cancelledSet.insert(id); let p = processes[id]; lock.unlock()
        p?.terminate()
        DispatchQueue.main.async {
            self.jobs.removeAll { $0.id == id }
            self.clearTracking(id)
            self.pump()
        }
        loginQueue.async { try? FileManager.default.removeItem(atPath: NSTemporaryDirectory() + "lw_dl_\(id)") }
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
    // content_log 是全局的(并发下载共用、行里只有 appid),并发时按总字节/开始时间匹配任务;
    // .patch 文件名带 item id,所以块进度天然按条目区分。

    private let logQueue = DispatchQueue(label: "workshop.contentlog")
    private var logTimer: DispatchSourceTimer?   // 仅主线程访问
    private var logOffset: UInt64 = 0            // 已读到的位置,仅 logQueue 访问
    private var logTail = ""                     // 跨次读取的半行缓冲,仅 logQueue 访问

    private var contentLogURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Steam/logs/content_log.txt")
    }

    static func isActive(_ s: Job.State) -> Bool {
        switch s { case .queued, .connecting, .downloading: return true; default: return false }
    }

    /// 有活跃任务时开始轮询 content_log(已在跑则忽略)。主线程调用。
    private func ensureLogPolling() {
        guard logTimer == nil, jobs.contains(where: { Self.isActive($0.state) }) else { return }
        logQueue.async { [weak self] in
            guard let self else { return }
            // 从文件当前末尾开始读,忽略历史日志
            self.logOffset = (try? FileHandle(forReadingFrom: self.contentLogURL).seekToEnd()) ?? 0
            self.logTail = ""
        }
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

    /// 读 content_log 新增内容,解析出字节采样与总块数。在 logQueue 上跑。
    private func pollLog() {
        var samples: [(cur: Int64, tot: Int64)] = []
        var chunkCounts: [Int] = []
        if let fh = try? FileHandle(forReadingFrom: contentLogURL) {
            defer { try? fh.close() }
            let end = (try? fh.seekToEnd()) ?? 0
            if end < logOffset { logOffset = 0; logTail = "" }   // 日志被轮转/重建
            if end > logOffset {
                try? fh.seek(toOffset: logOffset)
                let data = (try? fh.readToEnd()) ?? Data()
                logOffset = end
                if let chunk = String(data: data, encoding: .utf8) {
                    var lines = (logTail + chunk).components(separatedBy: "\n")
                    logTail = lines.popLast() ?? ""   // 末行可能不完整,留到下次
                    for line in lines {
                        if line.contains("AppID \(appID)"), let s = Self.parseDownloadLine(line) {
                            samples.append(s)
                        } else if let n = Self.parseChunkCount(line, appID: appID) {
                            chunkCounts.append(n)
                        }
                    }
                }
            }
        }
        DispatchQueue.main.async { self.applyLogSamples(samples, chunkCounts: chunkCounts) }
    }

    /// 把采样/块数应用到对应任务,并轮询各任务的 .patch 块进度;没有活跃任务则停轮询。主线程调用。
    private func applyLogSamples(_ samples: [(cur: Int64, tot: Int64)], chunkCounts: [Int]) {
        let now = Date()
        // 总块数 N:分配给最近开始、还没拿到 N 的活跃任务(.patch 名带 id,块计数本身按条目区分)
        for n in chunkCounts {
            let pool = jobs.indices.filter { Self.isActive(jobs[$0].state) && jobs[$0].totalChunks == 0 }
            if let i = pool.max(by: { (jobs[$0].startTime ?? .distantPast) < (jobs[$1].startTime ?? .distantPast) }) {
                jobs[i].totalChunks = n
            }
        }
        // content_log 真实字节(更准的 已下载/总 MB):只更新字节/总量,速度统一在下面按有效量算。
        for s in samples {
            guard let i = matchJob(total: s.tot, cur: s.cur) else { continue }
            if jobs[i].state == .connecting { jobs[i].state = .downloading }
            jobs[i].logTotal = s.tot
            jobs[i].downloadedBytes = max(jobs[i].downloadedBytes, s.cur)   // 单调,防乱序行
            jobs[i].lastSampleBytes = s.cur
            jobs[i].lastSampleTime = now
        }
        // 主信号:每个活跃任务查 .patch 块进度(单调),并按「有效已下载量」逐次增量算实时速率。
        // patch 块数高频增长(每块即更新),所以速率不再依赖稀疏的 content_log 字节采样。
        for i in jobs.indices where Self.isActive(jobs[i].state) {
            let c = committedChunks(forID: jobs[i].id)
            if c > jobs[i].committedChunks { jobs[i].committedChunks = c }
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
        let dir = NSTemporaryDirectory() + "lw_dl_\(id)/steamapps/workshop/downloads"
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir),
              let name = files.first(where: { $0.hasSuffix("_\(id).patch") }),
              let attrs = try? FileManager.default.attributesOfItem(atPath: dir + "/" + name),
              let size = (attrs[.size] as? NSNumber)?.intValue else { return 0 }
        return size / 24
    }

    /// content_log 是全局的,按总字节(tot)把进度行匹配到对应任务。
    private func matchJob(total: Int64, cur: Int64) -> Int? {
        let active = jobs.indices.filter { Self.isActive(jobs[$0].state) }
        guard !active.isEmpty else { return nil }
        if active.count == 1 { return active[0] }                                  // 只有一个,直接给它
        if let i = active.first(where: { jobs[$0].logTotal == total }) { return i } // 已锁定相同总量
        // 还没锁定 total 的任务里,挑网页估算大小最接近的(都没估算值就退回全部里最接近的)
        let pool = active.filter { jobs[$0].logTotal == 0 }
        let cands = pool.isEmpty ? active : pool
        return cands.min(by: { sizeDist(jobs[$0].totalBytes, total) < sizeDist(jobs[$1].totalBytes, total) })
    }
    private func sizeDist(_ a: Int64, _ b: Int64) -> Double {
        a <= 0 ? .greatestFiniteMagnitude : abs(Double(a) - Double(b))
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
        lock.lock(); defer { lock.unlock() }; return cancelledSet.contains(id)
    }
    private func clearTracking(_ id: String) {
        lock.lock(); processes.removeValue(forKey: id); cancelledSet.remove(id); lock.unlock()
    }
}
