import AppKit
import XCTest
@testable import LiveWallpaper

@MainActor
final class WebWallpaperHotspotPanelTests: XCTestCase {
    func testRevealedDesktopLeavesHolesForDesktopItems() {
        let first = CGRect(x: 0, y: 0, width: 90, height: 70)
        let second = CGRect(x: 110, y: 10, width: 25, height: 25)
        let icon = CGRect(x: 15, y: 15, width: 30, height: 30)
        let widget = CGRect(x: 40, y: 40, width: 100, height: 75)
        let regions = WallpaperDesktopInput.uncoveredRegions([first, second], excluding: [icon, widget])
        // Check every pixel center, including the overlap between the two exclusions.
        for y in 0..<100 {
            for x in 0..<140 {
                let point = CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)
                let expected = (first.contains(point) || second.contains(point)) && !icon.contains(point) && !widget.contains(point)
                XCTAssertEqual(regions.contains { $0.contains(point) }, expected)
            }
        }
    }

    func testHotspotForwardsOriginalPressDragReleaseAndCancellation() throws {
        _ = NSApplication.shared
        var phases: [WallpaperPointerPhase] = []
        var points: [CGPoint] = []
        var canStart = true
        let panel = WallpaperHotspotPanel(frame: CGRect(x: 40, y: 90, width: 80, height: 50),
                                         canStart: { _ in canStart }) { phase, point, _ in
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
        canStart = false
        surface.mouseDown(with: try event(.leftMouseDown, local))
        surface.mouseDragged(with: try event(.leftMouseDragged, local))
        surface.mouseUp(with: try event(.leftMouseUp, local))
        XCTAssertEqual(phases, [.down, .up, .down, .drag, .up, .down, .cancel])
        XCTAssertEqual(points[3], panel.convertPoint(toScreen: CGPoint(x: 38, y: 19)))
        XCTAssertEqual(points.first, panel.convertPoint(toScreen: local))
    }
}
