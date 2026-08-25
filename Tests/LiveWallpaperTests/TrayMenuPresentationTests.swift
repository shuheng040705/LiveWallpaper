import XCTest
@testable import LiveWallpaper

final class TrayMenuPresentationTests: XCTestCase {
    func testRunningWallpaperMenuState() {
        let state = TrayMenuPresentation(
            currentTitle: "琉璃",
            isPaused: false,
            isMuted: true,
            rotationEnabled: true,
            pendingDownloads: 3
        )

        XCTAssertEqual(state.currentSummary, "当前：琉璃")
        XCTAssertEqual(state.pauseTitle, "暂停壁纸")
        XCTAssertEqual(state.muteTitle, "取消静音")
        XCTAssertEqual(state.downloadsTitle, "下载管理（3）…")
    }

    func testEmptyPausedStateHasExpectedActions() {
        let state = TrayMenuPresentation(
            currentTitle: nil,
            isPaused: true,
            isMuted: false,
            rotationEnabled: false,
            pendingDownloads: 0
        )

        XCTAssertEqual(state.currentSummary, "当前：未选择壁纸")
        XCTAssertEqual(state.pauseTitle, "继续壁纸")
        XCTAssertEqual(state.muteTitle, "静音")
        XCTAssertEqual(state.downloadsTitle, "下载管理…")
    }
}
