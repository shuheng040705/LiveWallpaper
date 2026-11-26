import AppKit
import XCTest
@testable import LiveWallpaper

@MainActor
final class WebWallpaperHotspotPanelTests: XCTestCase {
    func testWallpaperPriorityOnlyClaimsASmallRegionOnTheCurrentDisplay() {
        let viewport = CGSize(width: 1728, height: 1117)
        let point = CGPoint(x: 0.43, y: 0.61)
        let rect = WallpaperDesktopInput.pointerRegion(around: point, viewSize: viewport)
        XCTAssertTrue(rect.contains(point))
        XCTAssertEqual(rect.width * viewport.width, 12, accuracy: 0.001)
        XCTAssertEqual(rect.height * viewport.height, 12, accuracy: 0.001)
        let edge = WallpaperDesktopInput.pointerRegion(around: .zero, viewSize: viewport)
        XCTAssertEqual(edge.origin, .zero)
        XCTAssertEqual(edge.width * viewport.width, 6, accuracy: 0.001)
        XCTAssertEqual(WallpaperDesktopInput.pointerRegion(around: point, viewSize: .zero), .zero)
    }

    func testHotspotForwardsOriginalPressDragReleaseAndCancellation() throws {
        _ = NSApplication.shared
        var phases: [WallpaperPointerPhase] = []
        var points: [CGPoint] = []
        let panel = WallpaperHotspotPanel(frame: CGRect(x: 40, y: 90, width: 80, height: 50)) { phase, point, _ in
            phases.append(phase)
            points.append(point)
        }
        defer { panel.close() }
        let surface = try XCTUnwrap(panel.contentView)
        let local = CGPoint(x: 24, y: 19)
        func event(_ type: NSEvent.EventType, _ point: CGPoint, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: modifiers,
                timestamp: 0, windowNumber: panel.windowNumber, context: nil, eventNumber: 1,
                clickCount: 1, pressure: 1))
        }

        surface.mouseDown(with: try event(.leftMouseDown, local))
        surface.mouseUp(with: try event(.leftMouseUp, local))
        surface.mouseDown(with: try event(.leftMouseDown, local))
        surface.mouseDragged(with: try event(.leftMouseDragged, CGPoint(x: 38, y: 19)))
        surface.mouseUp(with: try event(.leftMouseUp, local))
        surface.mouseDown(with: try event(.leftMouseDown, local, modifiers: .command))
        surface.mouseUp(with: try event(.leftMouseUp, local))
        surface.mouseDown(with: try event(.leftMouseDown, local))
        panel.setReceivingClicks(false)
        surface.mouseUp(with: try event(.leftMouseUp, local))
        XCTAssertEqual(phases, [.down, .up, .down, .drag, .up, .down, .cancel])
        XCTAssertEqual(points[3], panel.convertPoint(toScreen: CGPoint(x: 38, y: 19)))
        XCTAssertEqual(points.first, panel.convertPoint(toScreen: local))
    }
}
