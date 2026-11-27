import XCTest
@testable import LiveWallpaper

final class SceneCursorInputTests: XCTestCase {
    private final class Fixture: SceneSource {
        var allPaths = ["scene.json"]
        let data: Data
        convenience init(size: String = "20 20", solid: Bool = true, source: String? = nil) throws {
            let callback = source ?? """
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
            try self.init(objects: [object])
        }
        init(objects: [[String: Any]]) throws {
            let scene: [String: Any] = [
                "general": ["orthogonalprojection": ["width": 100, "height": 100]],
                "objects": objects,
            ]
            data = try JSONSerialization.data(withJSONObject: scene)
        }
        func data(for relativePath: String) -> Data? { relativePath == "scene.json" ? data : nil }
    }

    func testOverlappingImageLayersRespectSolidVisibilityAndPropagation() throws {
        func layer(id: Int, name: String, size: String, visible: Bool = true,
                   solid: Bool = true, stop: Bool = false, scripted: Bool = true) -> [String: Any] {
            let callback = """
                export function cursorDown() { shared.\(name) = (shared.\(name) || '') + 'd'; }
                export function cursorUp() { shared.\(name) += 'u'; }
                export function cursorClick() { shared.\(name) += 'c'; }
                export function cursorEnter() { shared.\(name)Hover = (shared.\(name)Hover || '') + 'e'; }
                export function cursorLeave() { shared.\(name)Hover += 'l'; }
                """
            var object: [String: Any] = ["id": id, "name": name, "image": "models/util/solidlayer.json",
                                         "origin": "50 50 0", "size": size, "solid": solid,
                                         "disablepropagation": stop, "visible": visible]
            if scripted { object["visible"] = ["value": visible, "script": callback] }
            return object
        }
        let back = layer(id: 1, name: "back", size: "70 70")
        let cases: [(name: String, visible: Bool, solid: Bool, stop: Bool, scripted: Bool,
                     frontReceives: Bool, backReceives: Bool)] = [
            ("ordinary overlap", true, true, false, true, true, true),
            ("visible blocker", true, true, true, true, true, false),
            ("non-solid overlay", true, false, true, true, false, true),
            ("hidden blocker", false, true, true, true, true, true),
            ("static blocker", true, true, true, false, false, false),
        ]
        for scenario in cases {
            let front = layer(id: 2, name: "front", size: "20 20", visible: scenario.visible,
                              solid: scenario.solid, stop: scenario.stop, scripted: scenario.scripted)
            let source = try Fixture(objects: [back, front])
            let document = try XCTUnwrap(SceneDocument.build(from: source))
            let script = try XCTUnwrap(document.layers.first { $0.id == 1 }?.visibleScript)
            guard let engine = SceneRenderEngine() else { throw XCTSkip("Metal unavailable") }
            engine.load(document: document, source: source)
            engine.update(time: 0, mouseNorm: .zero)
            func state() throws -> [String: String] {
                let data = Data(script.sharedJSON().utf8)
                return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
            }
            func click(_ point: CGPoint) {
                engine.routeCursor(.down, at: point)
                engine.routeCursor(.up, at: point)
            }
            let center = CGPoint(x: 0.5, y: 0.5), exposed = CGPoint(x: 0.3, y: 0.5)
            XCTAssertEqual(engine.containsCursorHotspot(at: center),
                           scenario.frontReceives || scenario.backReceives, scenario.name)
            XCTAssertTrue(engine.containsCursorHotspot(at: exposed), scenario.name)
            click(center)
            let overlap = try state()
            XCTAssertEqual(overlap["front"], scenario.frontReceives ? "duc" : nil, scenario.name)
            XCTAssertEqual(overlap["back"], scenario.backReceives ? "duc" : nil, scenario.name)
            click(exposed)
            let exposedBackground = try state()
            XCTAssertEqual(exposedBackground["front"], overlap["front"], scenario.name)
            XCTAssertEqual(exposedBackground["back"], (overlap["back"] ?? "") + "duc", scenario.name)
            // A glow driven by enter/leave on the background stays on while a blocker
            // prevents visiting it. Leaving the foreground removes only its own glow.
            engine.routeCursor(.hover, at: center)
            engine.routeCursor(.hover, at: exposed)
            let hover = try state()
            XCTAssertEqual(hover["backHover"], "e", scenario.name)
            XCTAssertEqual(hover["frontHover"], scenario.frontReceives ? "elel" : nil, scenario.name)
        }
    }

    func testFullscreenAndNonSolidLayersLeaveDesktopUnclaimed() throws {
        let point = CGPoint(x: 0.7, y: 0.2)
        for solid in [true, false] {
            let source = try Fixture(size: "400 400", solid: solid)
            let doc = try XCTUnwrap(SceneDocument.build(from: source))
            guard let engine = SceneRenderEngine() else { throw XCTSkip("Metal unavailable") }
            engine.load(document: doc, source: source)
            engine.update(time: 0, mouseNorm: .zero)
            XCTAssertFalse(engine.containsCursorHotspot(at: point))
            XCTAssertEqual(engine.interactiveHitAt(mouseNorm: SIMD2(0.4, 0.6)), solid ? 42 : nil)
        }
    }

    func testGlobalInputWorksWithoutSolidRegionsOrCursorCallbacks() throws {
        let source = try Fixture(solid: false, source: """
            export function update(value) {
                const { cursorLeftDown, cursorScreenPosition } = input;
                shared.pressed = cursorLeftDown;
                shared.screen = [cursorScreenPosition.x, cursorScreenPosition.y];
                shared.dimensions = [engine.canvasSize.x, engine.screenResolution.x];
                return value;
            }
            """)
        let doc = try XCTUnwrap(SceneDocument.build(from: source))
        let script = try XCTUnwrap(doc.layers.first?.visibleScript)
        guard let engine = SceneRenderEngine() else { throw XCTSkip("Metal unavailable") }
        engine.load(document: doc, source: source)
        engine.update(time: 0, mouseNorm: .zero)
        engine.setScreenResolution(SIMD2(800, 300))
        XCTAssertTrue(engine.needsDesktopInput)
        let point = CGPoint(x: 0.1, y: 0.3)
        XCTAssertFalse(engine.containsCursorHotspot(at: point))
        for (phase, pressed) in [(WallpaperPointerPhase.down, true), (.leave, true), (.drag, true), (.up, false),
                                 (.down, true), (.cancel, false)] {
            engine.routeCursor(phase, at: point)
            _ = script.runBool(current: true)
            let state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(script.sharedJSON().utf8)) as? [String: Any])
            XCTAssertEqual(state["pressed"] as? Bool, pressed)
            let coords = try XCTUnwrap(state["screen"] as? [Double])
            XCTAssertEqual(coords.count, 2)
            XCTAssertEqual(state["dimensions"] as? [Int], [100, 800])
            XCTAssertEqual(coords.first ?? 0, 80, accuracy: 0.001)
            XCTAssertEqual(coords.last ?? 0, 90, accuracy: 0.001)
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
        runtime.dispatchCursor(.down, hit: .init(id: 27, world: .zero, local: .zero))
        XCTAssertTrue(played.isEmpty)
        runtime.dispatchCursor(.click, hit: .init(id: 27, world: .zero, local: .zero))
        XCTAssertEqual(played, [27])
    }

    func testSceneCursorCallbacksUseRenderedGeometryAndReleaseTarget() throws {
        let source = try Fixture()
        let doc = try XCTUnwrap(SceneDocument.build(from: source))
        let target = try XCTUnwrap(doc.layers.first(where: { $0.id == 42 })?.visibleScript)
        guard let engine = SceneRenderEngine() else { throw XCTSkip("Metal unavailable") }
        engine.load(document: doc, source: source)
        engine.update(time: 0, mouseNorm: .zero)
        let inside = CGPoint(x: 0.73, y: 0.24), outside = CGPoint(x: 0.73, y: 0.76)
        XCTAssertTrue(engine.containsCursorHotspot(at: inside))
        XCTAssertFalse(engine.containsCursorHotspot(at: outside))
        func result() throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(target.sharedJSON().utf8)) as? [String: Any])
        }
        engine.routeCursor(.down, at: inside)
        engine.routeCursor(.drag, at: outside)
        engine.routeCursor(.up, at: outside)
        XCTAssertNil(try result()["values"])
        XCTAssertEqual(try result()["events"] as? String, "down,up", "release outside must end the drag without a click")
        engine.routeCursor(.down, at: inside)
        engine.routeCursor(.up, at: inside)
        XCTAssertEqual(try result()["events"] as? String, "down,up")
        let values = try XCTUnwrap(try result()["values"] as? [NSNumber])
        XCTAssertEqual(values.count, 5)
        guard values.count == 5 else { return }
        XCTAssertEqual(values[0].doubleValue, 73, accuracy: 0.001)
        XCTAssertEqual(values[1].doubleValue, 76, accuracy: 0.001)
        XCTAssertEqual(values[2].doubleValue, 13, accuracy: 0.001)
        XCTAssertEqual(values[3].doubleValue, 14, accuracy: 0.001, "local Y starts at the upper edge of the image")
        XCTAssertFalse(values[4].boolValue)
    }
}
