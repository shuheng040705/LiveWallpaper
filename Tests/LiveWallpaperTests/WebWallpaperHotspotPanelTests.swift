import AppKit
import XCTest
@testable import LiveWallpaper

@MainActor
final class WebWallpaperHotspotPanelTests: XCTestCase {
    func testHotspotForwardsOriginalPressDragReleaseAndCancellation() throws {
        _ = NSApplication.shared
        var phases: [WallpaperPointerPhase] = []
        var points: [CGPoint] = []
        let panel = WebWallpaperHotspotPanel(frame: CGRect(x: 40, y: 90, width: 80, height: 50)) { phase, point in
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
