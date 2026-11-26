import XCTest
@testable import LiveWallpaper

final class SceneCursorInputTests: XCTestCase {
    private final class Fixture: SceneSource {
        var allPaths = ["scene.json"]
        let data: Data
        init(size: String = "20 20", solid: Bool = true) throws {
            let callback = """
                export function cursorClick(e) {
                    shared.values = [e.worldPosition.x, e.worldPosition.y,
                                     e.localPosition.x, e.localPosition.y, input.cursorLeftDown];
                }
                export function cursorDown(e) { shared.events = 'down'; }
                export function cursorUp(e) { shared.events += ',up'; }
                """
            let object: [String: Any] = [
                "id": 42, "name": "button", "image": "models/util/solidlayer.json",
                "origin": "70 80 0", "angles": "0 0 0", "size": size, "scale": "1 1 1", "solid": solid,
                "visible": ["value": true, "script": callback],
            ]
            let scene: [String: Any] = [
                "general": ["orthogonalprojection": ["width": 100, "height": 100]],
                "objects": [object],
            ]
            data = try JSONSerialization.data(withJSONObject: scene)
        }
        func data(for relativePath: String) -> Data? { relativePath == "scene.json" ? data : nil }
    }

    func testFullscreenAndNonSolidLayersLeaveDesktopUnclaimed() throws {
        let point = CGPoint(x: 0.7, y: 0.2)
        for solid in [true, false] {
            let source = try Fixture(size: "400 400", solid: solid)
            let doc = try XCTUnwrap(SceneDocument.build(from: source))
            guard let engine = SceneRenderEngine() else { throw XCTSkip("Metal unavailable") }
            engine.load(document: doc, source: source)
            engine.update(time: 0, mouseNorm: .zero)
            XCTAssertTrue(engine.cursorHotspots(at: point).isEmpty)
            XCTAssertEqual(engine.interactiveHitAt(mouseNorm: SIMD2(0.4, 0.6)), solid ? 42 : nil)
        }
    }

    func testClickPlaysOnlyReferencedSceneSoundLayer() throws {
        let runtime = try XCTUnwrap(WEScript(script: """
        export function cursorClick() { thisScene.getLayer("touchhead.mp3").play(); }
        """, propertyOverrides: [:], tag: "scene sound"))
        runtime.setSceneLayers([
            .init(id: 27, name: "touchhead.mp3", parentId: nil, visible: true, alpha: 1,
                  color: SIMD4(repeating: 1), origin: .zero, scale: .one, angles: .zero, size: .zero),
        ])
        var played: [Int] = []
        runtime.setSoundLayerPlayback { played.append($0) }
        runtime.dispatchCursor(.down, world: .zero, local: .zero)
        XCTAssertTrue(played.isEmpty)
        runtime.dispatchCursor(.click, world: .zero, local: .zero)
        XCTAssertEqual(played, [27])
    }

    func testSceneCursorCallbacksUseRenderedGeometryAndCapturePress() throws {
        let source = try Fixture()
        let doc = try XCTUnwrap(SceneDocument.build(from: source))
        let target = try XCTUnwrap(doc.layers.first(where: { $0.id == 42 })?.visibleScript)
        guard let engine = SceneRenderEngine() else { throw XCTSkip("Metal unavailable") }
        engine.load(document: doc, source: source)
        engine.update(time: 0, mouseNorm: .zero)
        let inside = CGPoint(x: 0.73, y: 0.24), outside = CGPoint(x: 0.73, y: 0.76)
        XCTAssertTrue(engine.cursorHotspots(at: inside).contains { $0.contains(inside) })
        XCTAssertTrue(engine.cursorHotspots(at: outside).isEmpty)
        func result() throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(target.sharedJSON().utf8)) as? [String: Any])
        }
        engine.routeCursor(.down, at: inside)
        engine.routeCursor(.drag, at: outside)
        engine.routeCursor(.up, at: outside)
        XCTAssertNil(try result()["values"])
        XCTAssertEqual(try result()["events"] as? String, "down,up")
        engine.routeCursor(.down, at: inside)
        engine.routeCursor(.up, at: inside)
        let values = try XCTUnwrap(try result()["values"] as? [NSNumber])
        XCTAssertEqual(values.count, 5)
        guard values.count == 5 else { return }
        XCTAssertEqual(values[0].doubleValue, 73, accuracy: 0.001)
        XCTAssertEqual(values[1].doubleValue, 76, accuracy: 0.001)
        XCTAssertEqual(values[2].doubleValue, 13, accuracy: 0.001)
        XCTAssertEqual(values[3].doubleValue, 6, accuracy: 0.001)
        XCTAssertFalse(values[4].boolValue)
    }
}
