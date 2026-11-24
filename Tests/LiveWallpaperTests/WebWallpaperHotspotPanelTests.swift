import AppKit
import XCTest
@testable import LiveWallpaper

@MainActor
final class WebWallpaperHotspotPanelTests: XCTestCase {
    func testHotspotMouseSequenceUsesScreenCoordinatesAndExcludesDrags() throws {
        _ = NSApplication.shared
        var clicks: [CGPoint] = []
        let panel = WebWallpaperHotspotPanel(frame: CGRect(x: 40, y: 90, width: 80, height: 50)) {
            clicks.append($0)
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
        XCTAssertEqual(clicks, [panel.convertPoint(toScreen: local)])
    }
}
