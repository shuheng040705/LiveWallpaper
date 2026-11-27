import AppKit
import XCTest
@testable import LiveWallpaper

final class WallpaperDesktopRoutingTests: XCTestCase {
    func testDesktopShadowLeavesWallpaperClickableAndDesktopItemKeepsItsFrame() {
        let display = CGRect(x: -1200, y: 150, width: 1200, height: 800)
        let mainHeight: CGFloat = 1080
        let iconLevel = Int(CGWindowLevelForKey(.desktopIconWindow))
        func window(_ name: String, _ frame: CGRect, alpha: Double = 1) -> [String: Any] {
            [kCGWindowOwnerPID as String: pid_t(0), kCGWindowOwnerName as String: name,
             kCGWindowLayer as String: iconLevel + 1, kCGWindowAlpha as String: alpha,
             kCGWindowBounds as String: frame.dictionaryRepresentation]
        }
        let shadow = CGRect(x: -1200, y: 130, width: 1200, height: 94)
        let item = CGRect(x: -80, y: 175, width: 64, height: 64)
        let exclusions = WallpaperDesktopInput.desktopItemWindowFrames(
            [window("Window Server", shadow), window("Desktop widget", item),
             window("Hidden widget", shadow, alpha: 0)], display: display, mainHeight: mainHeight)
        XCTAssertEqual(exclusions, [CGRect(x: -80, y: mainHeight - item.maxY, width: 64, height: 64)])
        let panels = WallpaperDesktopInput.uncoveredRegions([display], excluding: exclusions)
        XCTAssertTrue(panels.contains { $0.contains(CGPoint(x: -600, y: display.maxY - 50)) })
        XCTAssertTrue(panels.contains { $0.contains(CGPoint(x: display.minX + 5, y: display.minY + 2)) })
        XCTAssertFalse(panels.contains { $0.contains(CGPoint(x: item.midX, y: mainHeight - item.midY)) })
    }

    @MainActor
    func testPassiveSceneAndVideoInstallOneDesktopRouterAndReleaseItOnStop() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let desktop = DesktopWindow(screen: screen)
        defer { desktop.close() }
        let host = try XCTUnwrap(desktop.contentView)
        let scene = SceneRenderer()
        let video = VideoRenderer()
        let cases: [(WallpaperRenderer, () -> WallpaperDesktopInput?)] = [
            (scene, { scene.desktopInput }), (video, { video.desktopInput })
        ]
        for (renderer, input) in cases {
            renderer.attach(to: host)
            renderer.start()
            weak var original = input()
            XCTAssertNotNil(original)
            renderer.pause()
            renderer.resume()
            XCTAssertTrue(input() === original)
            renderer.stop()
            XCTAssertNil(input())
            XCTAssertNil(original)
        }
    }

    func testStageOwnerChangesWhenTheFinderBrowsingWindowJoinsTheShelf() throws {
        let finder = try XCTUnwrap(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first)
        let manager = try XCTUnwrap(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.WindowManager").first)
        let screen = CGRect(x: -1440, y: -100, width: 1440, height: 900)
        let icons = Int(CGWindowLevelForKey(.desktopIconWindow))
        func window(_ application: NSRunningApplication, _ level: Int, _ bounds: CGRect) -> [String: Any] {
            [kCGWindowOwnerPID as String: application.processIdentifier, kCGWindowLayer as String: level,
             kCGWindowBounds as String: bounds.dictionaryRepresentation]
        }
        let finderDesktop = window(finder, icons, screen)
        let backdrop = window(manager, icons, screen)
        let browser = window(finder, 0, CGRect(x: -1200, y: 60, width: 900, height: 470))
        let shelf = window(manager, 0, CGRect(x: -1440, y: 120, width: 130, height: 120))
        let otherDisplay = window(finder, icons, CGRect(x: 0, y: 0, width: 1728, height: 1117))
        XCTAssertFalse(WallpaperDesktopInput.desktopIsRevealed(windows: [shelf, browser, otherDisplay, backdrop, finderDesktop], display: screen))
        XCTAssertTrue(WallpaperDesktopInput.desktopIsRevealed(windows: [shelf, otherDisplay, finderDesktop, backdrop], display: screen))
        XCTAssertFalse(WallpaperDesktopInput.desktopIsRevealed(windows: [shelf, browser], display: screen))
    }

    func testObservedHitCompletesBeforeTheSecondClickOnTheRevealedDesktop() {
        let start = CGPoint(x: 0.32, y: 0.7)
        let end = CGPoint(x: 0.39, y: 0.82)
        var events: [WallpaperPointerPhase] = []
        var locations: [CGPoint] = []
        var counts: [Int] = []
        let queue = WallpaperDesktopGestures { phase, point, count in
            events.append(phase)
            locations.append(point)
            counts.append(count)
        }
        var answer: ((Bool) -> Void)?
        queue.receive(.down, at: start, count: 1, from: .monitor) { answer = $0 }
        queue.receive(.drag, at: end, count: 0, from: .monitor)
        queue.receive(.up, at: end, count: 1, from: .monitor)
        queue.receive(.down, at: start, count: 2, from: .panel)
        queue.receive(.up, at: start, count: 2, from: .monitor)
        XCTAssertTrue(queue.isTrackingPanel)
        queue.receive(.up, at: start, count: 2, from: .panel)
        XCTAssertTrue(events.isEmpty)
        answer?(true)
        XCTAssertEqual(events, [.down, .drag, .up, .down, .up])
        XCTAssertEqual(locations, [start, end, end, start, start])
        XCTAssertEqual(counts, [1, 0, 1, 2, 2])
    }

    func testBlankObservedClickAndLateAnswersAfterWallpaperChangeAreDiscarded() {
        var events: [WallpaperPointerPhase] = []
        let queue = WallpaperDesktopGestures { phase, _, _ in events.append(phase) }
        var first: ((Bool) -> Void)?
        var second: ((Bool) -> Void)?
        queue.receive(.down, at: .zero, count: 1, from: .monitor) { first = $0 }
        queue.receive(.up, at: .zero, count: 1, from: .monitor)
        queue.receive(.down, at: .zero, count: 2, from: .monitor) { second = $0 }
        queue.receive(.up, at: .zero, count: 2, from: .monitor)
        second?(true)
        first?(false)
        XCTAssertEqual(events, [.down, .up])

        queue.receive(.down, at: .zero, count: 1, from: .monitor) { first = $0 }
        queue.reset()
        first?(true)
        XCTAssertEqual(events, [.down, .up])
        queue.receive(.down, at: .zero, count: 1, from: .panel)
        queue.reset()
        XCTAssertEqual(events, [.down, .up, .down, .cancel])
    }
}
