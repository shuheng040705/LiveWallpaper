import XCTest
import Combine
@testable import LiveWallpaper

final class WorkshopDownloaderTests: XCTestCase {
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
