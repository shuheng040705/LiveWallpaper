import XCTest
import Combine
@testable import LiveWallpaper

final class WorkshopDownloaderTests: XCTestCase {
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
    /// 使用一个已下架条目，只验证“常驻登录 → 接收命令 → 返回终态”，不会写入壁纸库。
    func testLivePersistentSessionAcceptsCommand() throws {
        guard ProcessInfo.processInfo.environment["LW_STEAMCMD_INTEGRATION"] == "1" else {
            throw XCTSkip("仅在 Release 验收时运行")
        }

        let downloader = WorkshopDownloader.shared
        let terminal = expectation(description: "SteamCMD command reaches a terminal state")
        var subscriptions = Set<AnyCancellable>()
        downloader.$jobs
            .sink { jobs in
                guard let job = jobs.first(where: { $0.id == "3659146882" }) else { return }
                switch job.state {
                case .failed, .done:
                    terminal.fulfill()
                default:
                    break
                }
            }
            .store(in: &subscriptions)

        downloader.prewarm()
        downloader.enqueue(id: "3659146882", title: "SteamCMD integration probe")
        wait(for: [terminal], timeout: 45)

        guard let job = downloader.jobs.first(where: { $0.id == "3659146882" }) else {
            return XCTFail("探针任务没有保留终态")
        }
        if case .failed(let reason) = job.state {
            XCTAssertTrue(reason.contains("不存在") || reason.contains("下架"))
        } else if case .done = job.state {
            XCTFail("已下架的探针条目不应被安装")
        }
        downloader.shutdown()
    }
}
