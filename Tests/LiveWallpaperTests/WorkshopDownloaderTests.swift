import XCTest
import Combine
@testable import LiveWallpaper

final class WorkshopDownloaderTests: XCTestCase {
    @MainActor
    func testUnsubscribeDiscardRemovesPartialAndCommittedStagingWithoutTouchingAnotherItem() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "1234567890"
        let content = root.appendingPathComponent("steamapps/workshop/content/431960/\(id)")
        let partial = root.appendingPathComponent("steamapps/workshop/downloads/431960/\(id)")
        let other = root.appendingPathComponent("steamapps/workshop/downloads/431960/1234567891")
        for folder in [content, partial, other] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("payload".utf8).write(to: folder.appendingPathComponent("test.dat"))
        }
        let done = expectation(description: "Discard finished")
        let downloader = WorkshopDownloader(stagingDirectory: root)
        downloader.discard(id: id) {
            XCTAssertFalse(FileManager.default.fileExists(atPath: content.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: other.appendingPathComponent("test.dat").path))
            done.fulfill()
        }
        wait(for: [done], timeout: 3)
    }

    private func makeDownloaderFixture(timeouts: WorkshopDownloader.Timeouts = .init()) throws -> (WorkshopDownloader, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let script = root.appendingPathComponent("steamcmd-fixture")
        // Exercise the real scheduler, pipes, cancellation and installation with controllable processes.
        let body = """
        #!/bin/sh
        base="\(root.path)"
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "+force_install_dir" ]; then shift; dest="$1"; fi
          shift
        done
        touch "$base/boot.$$"
        echo 'Waiting for user info...OK'
        while read -r command app item; do
          if [ "$command" = 'quit' ]; then exit 0; fi
          if [ "$command" != 'workshop_download_item' ]; then continue; fi
          echo "Downloading item $item ..."
          mkdir -p "$HOME/Library/Application Support/Steam/logs" "$dest/steamapps/workshop/downloads"
          chunks=1
          if [ "$item" = '1234567891' ]; then chunks=3; fi
          echo 'Downloading 4 chunks for depot 431960' >> "$HOME/Library/Application Support/Steam/logs/content_log.txt"
          echo "AppID 431960 update started : download $((chunks * 1024))/4096" >> "$HOME/Library/Application Support/Steam/logs/content_log.txt"
          printf MO42 > "$dest/steamapps/workshop/downloads/state_431960_431960_$item.patch"
          dd if=/dev/zero bs=20 count=1 >> "$dest/steamapps/workshop/downloads/state_431960_431960_$item.patch" 2>/dev/null
          touch "$base/started.$item.$$"
          while [ ! -f "$base/release.$item" ]; do sleep 0.05; done
          mkdir -p "$dest/steamapps/workshop/content/431960/$item"
          echo '{}' > "$dest/steamapps/workshop/content/431960/$item/project.json"
          echo "Success. Downloaded item $item to destination (1024 bytes)"
        done
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let library = root.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        return (WorkshopDownloader(stagingDirectory: root.appendingPathComponent("cache"), executable: script,
                                   libraryDirectory: library, account: "fixture", timeouts: timeouts), root)
    }

    @MainActor
    func testThreeRealWorkersOverlapAndCancellingOneDoesNotCancelOthers() throws {
        let (downloader, root) = try makeDownloaderFixture()
        defer { downloader.shutdown(); try? FileManager.default.removeItem(at: root) }
        let ids = ["1234567890", "1234567891", "1234567892", "1234567893"]
        let started = expectation(description: "Three processes have received their commands")
        for id in ids { downloader.enqueue(id: id, title: id) }
        DispatchQueue.global().async {
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
                if ids.prefix(3).allSatisfy({ id in names.contains(where: { $0.hasPrefix("started." + id + ".") }) }) {
                    started.fulfill(); return
                }
                Thread.sleep(forTimeInterval: 0.02)
            }
        }
        wait(for: [started], timeout: 6)
        XCTAssertEqual(downloader.activeCount, 3)
        XCTAssertEqual(downloader.jobs.first(where: { $0.id == ids[3] })?.state, .queued)
        downloader.requestCancel(id: ids[0])
        for id in ids.dropFirst() { try Data().write(to: root.appendingPathComponent("release." + id)) }
        let completed = expectation(description: "Other workers finish and queued work starts")
        var observation: AnyCancellable?
        var fulfilled = false
        observation = downloader.$jobs.removeDuplicates().sink { jobs in
            if !fulfilled, jobs.contains(where: { $0.id == ids[0] && $0.state == .cancelled }), ids.dropFirst().allSatisfy({ id in jobs.contains(where: { $0.id == id && $0.state == .done }) }) { fulfilled = true; completed.fulfill() }
        }
        wait(for: [completed], timeout: 10)
        observation?.cancel()
        XCTAssertEqual(downloader.jobs.first(where: { $0.id == ids[0] })?.state, .cancelled)
        for id in ids.dropFirst() {
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("library/" + id + "/project.json").path))
        }
    }

    @MainActor
    func testEqualSizedConcurrentDownloadsKeepIndependentProgress() throws {
        let (downloader, root) = try makeDownloaderFixture()
        defer { downloader.shutdown(); try? FileManager.default.removeItem(at: root) }
        let sampled = expectation(description: "Progress from independent log files is attributed by item")
        var fulfilled = false
        let observation = downloader.$jobs.sink { jobs in
            guard !fulfilled,
                  let first = jobs.first(where: { $0.id == "1234567890" }),
                  let second = jobs.first(where: { $0.id == "1234567891" }),
                  first.logTotal == 4096, second.logTotal == 4096,
                  first.downloadedBytes == 1024, second.downloadedBytes == 3072 else { return }
            XCTAssertEqual(first.fraction, 0.25)
            XCTAssertEqual(second.fraction, 0.75)
            fulfilled = true; sampled.fulfill()
        }
        downloader.enqueue(id: "1234567890", title: "A", sizeBytes: 4096)
        downloader.enqueue(id: "1234567891", title: "B", sizeBytes: 4096)
        wait(for: [sampled], timeout: 6)
        observation.cancel()
    }

    @MainActor
    func testSixQueuedDownloadsReuseThreeAuthenticatedProcesses() throws {
        let (downloader, root) = try makeDownloaderFixture()
        defer { downloader.shutdown(); try? FileManager.default.removeItem(at: root) }
        let ids = (0..<6).map { "123456789" + String($0) }
        for id in ids { try Data().write(to: root.appendingPathComponent("release." + id)) }
        let finished = expectation(description: "All queued jobs finish with pooled processes")
        var fulfilled = false
        let observation = downloader.$jobs.sink { jobs in
            if !fulfilled, jobs.count == 6, jobs.allSatisfy({ $0.state == .done }) { fulfilled = true; finished.fulfill() }
        }
        for id in ids { downloader.enqueue(id: id, title: id) }
        wait(for: [finished], timeout: 8)
        observation.cancel()
        let boots = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix("boot.") }
        XCTAssertEqual(boots.count, 3, "A new wallpaper must reuse a healthy logged-in worker")
    }

    func testSteamDownloadRateParsingRejectsConnectionAdjustmentMessages() {
        let job = WorkshopDownloader.Job(id: "1234567890", title: "Header only", totalBytes: 24_000_000)
        XCTAssertNil(job.fraction)
        XCTAssertEqual(job.effectiveDownloadedBytes, 0)
        XCTAssertNil(WorkshopDownloader.parseDownloadRate("Increasing target number of download connections to 9 (rate was 0.000, now 18.912)"))
        XCTAssertEqual(WorkshopDownloader.parseDownloadRate("[date] Current download rate: 8.389 Mbps")!, 1.0000467300415039, accuracy: 0.00001)
        XCTAssertEqual(WorkshopDownloader.parseDownloadRate("Current download rate: 0.000 Mbps"), 0)
    }

    @MainActor
    func testPositiveReportedTransferRateKeepsConstantHeaderDownloadAlive() throws {
        let (downloader, root) = try makeDownloaderFixture(timeouts: .init(login: 2, commandStart: 1, noProgress: 0.8, retryDelay: 0.01))
        defer { downloader.shutdown(); try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("steamcmd-fixture")
        var body = try String(contentsOf: script, encoding: .utf8)
        body = body.replacingOccurrences(of: "while [ ! -f \"$base/release.$item\" ]; do sleep 0.05; done", with: "while [ ! -f \"$base/release.$item\" ]; do echo 'Current download rate: 8.389 Mbps' >> \"$HOME/Library/Application Support/Steam/logs/content_log.txt\"; sleep 0.1; done")
        body = body.replacingOccurrences(of: "$((chunks * 1024))/4096", with: "0/4096")
        try body.write(to: script, atomically: true, encoding: .utf8)
        let id = "1234567890"
        let completed = expectation(description: "Rate samples prevent a false stall restart")
        var sawUnknownPercentage = false
        var fulfilled = false
        let observation = downloader.$jobs.sink { jobs in
            if let job = jobs.first, job.state == .downloading, job.liveSpeedMBps > 0, job.downloadedBytes == 0, job.fraction == nil { sawUnknownPercentage = true }
            if !fulfilled, jobs.first?.state == .done { fulfilled = true; completed.fulfill() }
        }
        downloader.enqueue(id: id, title: "Active transfer with a fixed header")
        DispatchQueue.global().asyncAfter(deadline: .now() + 2.5) { try? Data().write(to: root.appendingPathComponent("release." + id)) }
        wait(for: [completed], timeout: 6)
        observation.cancel()
        XCTAssertTrue(sawUnknownPercentage, "A constant 24B MO42 header must not appear as a completed chunk")
        XCTAssertEqual(downloader.jobs.first?.attempt, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix("boot.") }.count, 1)
    }

    @MainActor
    func testDiscardInSharedSlotPreservesAnotherItemsPartialFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Workers/0/Content/steamapps/workshop/downloads/431960")
        for id in ["1234567890", "1234567891"] {
            let path = folder.appendingPathComponent(id)
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            try Data("resumable".utf8).write(to: path.appendingPathComponent("partial.dat"))
        }
        let downloader = WorkshopDownloader(stagingDirectory: root)
        let cleaned = expectation(description: "Only the unsubscribed item is removed")
        downloader.discard(id: "1234567890") { cleaned.fulfill() }
        wait(for: [cleaned], timeout: 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("1234567890").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("1234567891/partial.dat").path))
    }

    @MainActor
    func testStalledWorkerRetriesAndReleasesSlotWhileOtherDownloadsComplete() throws {
        let (downloader, root) = try makeDownloaderFixture(timeouts: .init(login: 2, commandStart: 0.4, noProgress: 0.4, retryDelay: 0.01))
        defer { downloader.shutdown(); try? FileManager.default.removeItem(at: root) }
        let stalled = "1234567890", healthy = "1234567891"
        try Data().write(to: root.appendingPathComponent("release." + healthy))
        let terminal = expectation(description: "Watchdog terminates instead of hanging forever")
        var observation: AnyCancellable?
        var fulfilled = false
        observation = downloader.$jobs.removeDuplicates().sink { jobs in
            guard jobs.contains(where: { $0.id == healthy && $0.state == .done }),
                  let job = jobs.first(where: { $0.id == stalled }) else { return }
            if case .failed = job.state, !fulfilled { fulfilled = true; terminal.fulfill() }
        }
        downloader.enqueue(id: stalled, title: "Stalled fixture")
        downloader.enqueue(id: healthy, title: "Healthy fixture")
        wait(for: [terminal], timeout: 12)
        observation?.cancel()
        let starts = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix("started." + stalled + ".") }
        XCTAssertEqual(starts.count, 2, "A stalled transfer should restart once in a fresh process")
        XCTAssertEqual(downloader.jobs.first(where: { $0.id == stalled })?.attempt, 2)
    }

    @MainActor
    func testLiveParallelIsolatedSteamCMDDownloads() throws {
        guard ProcessInfo.processInfo.environment["LW_PARALLEL_STEAMCMD_INTEGRATION"] == "1" else { throw XCTSkip("显式启用真实并发下载验收") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lw-parallel-" + UUID().uuidString)
        let library = root.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let account = UserDefaults(suiteName: "com.a55555.livewallpaper")?.string(forKey: "steamAccount")
        guard let account, !account.isEmpty else { throw XCTSkip("真实并发下载需要已登录的下载账号") }
        let downloader = WorkshopDownloader(stagingDirectory: root, libraryDirectory: library, account: account)
        defer { downloader.shutdown() }
        let titles = ["3820975067": "Phoenix - Halloween", "3829799406": "MeiMei in Snowy Street"]
        let finished = expectation(description: "Two independent SteamCMD downloads reach a terminal state")
        var observation: AnyCancellable?
        var terminalIDs = Set<String>()
        var sawOverlap = false
        var fulfilled = false
        observation = downloader.$jobs.removeDuplicates().sink { jobs in
            if jobs.filter({ $0.state == .connecting || $0.state == .downloading }).count == 2 { sawOverlap = true }
            terminalIDs.formUnion(jobs.filter { !WorkshopDownloader.isActive($0.state) }.map(\.id))
            if !fulfilled, terminalIDs.count == 2 { fulfilled = true; finished.fulfill() }
        }
        for (id, title) in titles { downloader.enqueue(id: id, title: title) }
        wait(for: [finished], timeout: 480)
        observation?.cancel()
        XCTAssertTrue(sawOverlap)
        for job in downloader.jobs { XCTAssertEqual(job.state, .done, job.title) }
        for id in titles.keys { XCTAssertTrue(LocalWallpaperProbe.isReady(at: library.appendingPathComponent(id))) }
        print("Parallel SteamCMD isolated artifacts: " + root.path)
    }

    @MainActor
    func testLiveWarmSessionAvoidsSecondLogin() throws {
        guard ProcessInfo.processInfo.environment["LW_STEAMCMD_SPEED_INTEGRATION"] == "1" else { throw XCTSkip("显式启用真实登录复用测速") }
        let account = UserDefaults(suiteName: "com.a55555.livewallpaper")?.string(forKey: "steamAccount")
        guard let account, !account.isEmpty else { throw XCTSkip("测速需要现有下载账号") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lw-speed-" + UUID().uuidString)
        let library = root.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let downloader = WorkshopDownloader(stagingDirectory: root, libraryDirectory: library, account: account)
        defer { downloader.shutdown() }
        let firstID = "3829782620", secondID = "3829799406"
        let finished = expectation(description: "Two real downloads finish using the same authenticated process")
        var scheduledSecond = false, fulfilled = false
        var coldStart = Date(), secondStart: Date?
        var coldInitialization: TimeInterval?, warmInitialization: TimeInterval?
        let stderr = root.appendingPathComponent("Workers/0/home/Library/Application Support/Steam/logs/stderr.txt")
        func processMarkers() -> Set<String> {
            let text = (try? String(contentsOf: stderr, encoding: .utf8)) ?? ""
            let regex = try! NSRegularExpression(pattern: #"objc\[(\d+)\]"#)
            return Set(regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { (text as NSString).substring(with: $0.range(at: 1)) })
        }
        var firstProcesses = Set<String>()
        let observation = downloader.$jobs.sink { jobs in
            for job in jobs where job.phase == .preparing || job.phase == .transferring {
                if job.id == firstID, coldInitialization == nil { coldInitialization = Date().timeIntervalSince(coldStart) }
                if job.id == secondID, warmInitialization == nil, let start = secondStart { warmInitialization = Date().timeIntervalSince(start) }
            }
            if jobs.contains(where: { $0.id == firstID && $0.state == .done }), !scheduledSecond {
                scheduledSecond = true; firstProcesses = processMarkers()
                // 给完成 worker 的收尾与槽位释放一个主队列轮次。
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    secondStart = Date()
                    downloader.enqueue(id: secondID, title: "MeiMei in Snowy Street")
                }
            }
            if !fulfilled, scheduledSecond, jobs.count == 2, jobs.allSatisfy({ !WorkshopDownloader.isActive($0.state) }) { fulfilled = true; finished.fulfill() }
            if !fulfilled, !scheduledSecond, jobs.contains(where: { if case .failed = $0.state { return true }; return false }) { fulfilled = true; finished.fulfill() }
        }
        coldStart = Date()
        downloader.enqueue(id: firstID, title: "Still - Minimal Wallpaper for Your Focus")
        wait(for: [finished], timeout: 480)
        observation.cancel()
        for job in downloader.jobs { XCTAssertEqual(job.state, .done, job.title) }
        for id in [firstID, secondID] { XCTAssertTrue(LocalWallpaperProbe.isReady(at: library.appendingPathComponent(id))) }
        XCTAssertNotNil(warmInitialization)
        if let warmInitialization { XCTAssertLessThan(warmInitialization, 3, "The next item must not repeat Steam login") }
        if !firstProcesses.isEmpty { XCTAssertEqual(processMarkers(), firstProcesses, "SteamCMD must reuse the actual process") }
        print("SteamCMD speed benchmark: cold login=\(coldInitialization ?? -1)s, warm initialization=\(warmInitialization ?? -1)s, artifacts=\(root.path)")
    }

    func testResolvesCurrentHomebrewCaskWrapperToBinary() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let wrapper = root.appendingPathComponent(".homebrew-command-wrappers/steamcmd")
        let binary = root.appendingPathComponent("MacOS/steamcmd")
        for file in [wrapper, binary] {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\n".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        let symlink = root.appendingPathComponent("steamcmd")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: wrapper)
        XCTAssertEqual(WorkshopDownloader.resolveSteamCMDBinary(wrapper: symlink).path, binary.path)
    }

    func testConnectionFailureIsTerminalWithoutPretendingCredentialsExpired() {
        let output = "Logging in user ...ERROR (No Connection)\nSteam>"
        XCTAssertTrue(WorkshopDownloader.outputShowsConnectionFailure(output))
        XCTAssertFalse(WorkshopDownloader.outputShowsAuthenticationFailure(output))
        XCTAssertTrue(WorkshopDownloader.outputShowsDownloadFailure(output, id: "3458955634"))
        XCTAssertFalse(WorkshopDownloader.outputShowsConnectionFailure("Retrying..."))
        XCTAssertTrue(WorkshopDownloader.outputShowsAuthenticationFailure("Cached credentials not found.\npassword:"))
    }

    func testZeroProgressDownloadAlsoTimesOut() {
        XCTAssertEqual(WorkshopDownloader.downloadTimeoutReason(sawCommandStart: true, elapsed: 601, idle: 601),
                       "下载进度长时间未增长")
        XCTAssertNil(WorkshopDownloader.downloadTimeoutReason(sawCommandStart: true, elapsed: 3600, idle: 5))
        XCTAssertEqual(WorkshopDownloader.downloadTimeoutReason(sawCommandStart: false, elapsed: 121, idle: 121),
                       "连接 Steam/CDN 超时")
    }

    func testItemIDPrefixDoesNotCompleteAnotherDownload() {
        XCTAssertFalse(WorkshopDownloader.outputShowsDownloadSuccess(
            "Success. Downloaded item 34589556340 to /tmp/item", id: "3458955634"))
        XCTAssertFalse(WorkshopDownloader.outputShowsDownloadFailure(
            "ERROR! Download item 9999999999 failed (File Not Found).", id: "3458955634"))
    }

    func testShutdownCancelsQueuedWorkBeforeStartingSteam() {
        let downloader = WorkshopDownloader()
        downloader.shutdown()
        let updated = expectation(description: "Enqueue callback completed")
        downloader.enqueue(id: "1234567890", title: "Shutdown regression")
        DispatchQueue.main.async {
            XCTAssertEqual(downloader.jobs.first?.state, .queued)
            updated.fulfill()
        }
        wait(for: [updated], timeout: 2)
    }

    func testPersistentSessionRecognizesOnlyMatchingSuccessfulItem() {
        let output = """
        Downloading item 3458955634 ...
        Success. Downloaded item 3458955634 to "/tmp/item" (1257628 bytes)
        Steam>
        """

        XCTAssertTrue(
            WorkshopDownloader.outputShowsDownloadSuccess(output, id: "3458955634")
        )
        XCTAssertFalse(
            WorkshopDownloader.outputShowsDownloadSuccess(output, id: "3723185938")
        )
    }

    func testPersistentSessionRecognizesDownloadFailure() {
        let output = "ERROR! Download item 3458955634 failed (File Not Found)."

        XCTAssertTrue(
            WorkshopDownloader.outputShowsDownloadFailure(output, id: "3458955634")
        )
    }

    func testUnrelatedOutputDoesNotFinishActiveCommand() {
        let output = """
        Waiting for client config...OK
        Waiting for user info...OK
        Steam>
        """

        XCTAssertFalse(
            WorkshopDownloader.outputShowsDownloadSuccess(output, id: "3458955634")
        )
        XCTAssertFalse(
            WorkshopDownloader.outputShowsDownloadFailure(output, id: "3458955634")
        )
    }

    /// 手工/发布验收用的真实 SteamCMD 探针。默认跳过，避免普通单测依赖网络。
    /// 使用不可能存在的条目 0，只验证“常驻登录 → 接收命令 → 返回终态”，不会写入壁纸库。
    func testLivePersistentSessionAcceptsCommand() throws {
        guard ProcessInfo.processInfo.environment["LW_STEAMCMD_INTEGRATION"] == "1" else {
            throw XCTSkip("仅在 Release 验收时运行")
        }

        let downloader = WorkshopDownloader.shared
        guard downloader.isSteamCMDAvailable else { throw XCTSkip("未安装 SteamCMD") }
        defer { downloader.shutdown() }
        let probeID = "0"
        let terminal = expectation(description: "SteamCMD command reaches a terminal state")
        var subscriptions = Set<AnyCancellable>()
        downloader.$jobs
            .sink { jobs in
                guard let job = jobs.first(where: { $0.id == probeID }) else { return }
                switch job.state {
                case .failed, .done:
                    terminal.fulfill()
                default:
                    break
                }
            }
            .store(in: &subscriptions)

        downloader.prewarm()
        downloader.enqueue(id: probeID, title: "SteamCMD integration probe")
        wait(for: [terminal], timeout: 120)

        guard let job = downloader.jobs.first(where: { $0.id == probeID }) else {
            return XCTFail("探针任务没有保留终态")
        }
        if case .failed(let reason) = job.state {
            if reason.contains("连接 Steam") || reason.contains("未登录 Steam") {
                throw XCTSkip("Steam 网络或下载授权不可用：\(reason)")
            }
            XCTAssertTrue(reason.contains("不存在") || reason.contains("下架"))
        } else if case .done = job.state {
            XCTFail("无效的探针条目不应被安装")
        }
    }
}
