import XCTest
@testable import LiveWallpaper

final class SceneModelCursorIntegrationTests: XCTestCase {
    private let center = CGPoint(x: 0.5, y: 0.5)
    private let blank = CGPoint(x: 0.02, y: 0.02)

    /// Two original model files, each with a single material and a declared picking box.
    /// The drawn face occupies only half the box, as it can in a real authored model.
    private final class Fixture: SceneSource {
        private let files: [String: Data]
        var allPaths: [String] { Array(files.keys) }
        func data(for relativePath: String) -> Data? { files[relativePath] }

        init(nearFirst: Bool = false, stop: Bool = false, nearVisible: Bool = true,
             nearClick: String = "") throws {
            func mdl(material: String) -> Data {
                var data = Data("MDLV0023\0".utf8)
                func u32(_ number: UInt32) {
                    var n = number.littleEndian
                    withUnsafeBytes(of: &n) { data.append(contentsOf: $0) }
                }
                func f(_ value: Float) { u32(value.bitPattern) }
                u32(15); u32(1); u32(1)
                data.append(contentsOf: material.utf8); data.append(0); u32(0)
                [-0.7, -0.7, -0.1, 0.7, 0.7, 0.1].forEach { f($0) }
                u32(15); u32(3 * 48)
                for (x, y): (Float, Float) in [(-0.65, -0.6), (0.65, -0.6), (0, 0.6)] {
                    [x, y, 0, 0, 0, 1, 1, 0, 0, 1, 0, 0].forEach(f)
                }
                u32(6); data.append(contentsOf: [0, 0, 1, 0, 2, 0])
                return data
            }
            func object(_ name: String, id: Int, z: Int, visible: Bool,
                        blocks: Bool, click: String) -> [String: Any] {
                let script = """
                    let presses = 0;
                    function append(tag) {
                        if (!shared.events) shared.events = [];
                        shared.events.push(thisLayer.name + '.' + tag);
                    }
                    export function cursorDown(e) {
                        presses++;
                        append('down');
                        shared[thisLayer.name] = [presses, e.localPosition.z,
                            e.worldPosition.z, input.cursorScreenPosition.x, input.cursorLeftDown];
                    }
                    function coordinates(e) {
                        return [e.localPosition.x, e.localPosition.y, e.localPosition.z,
                            e.worldPosition.x, e.worldPosition.y, e.worldPosition.z];
                    }
                    export function cursorMove(e) {
                        if (input.cursorLeftDown) {
                            append('drag');
                            shared[thisLayer.name + 'Drag'] = coordinates(e);
                        }
                    }
                    export function cursorUp(e) {
                        append(input.cursorLeftDown ? 'stillDown' : 'up');
                        shared[thisLayer.name + 'Up'] = coordinates(e);
                    }
                    export function cursorClick(e) { append('click'); \(click) }
                    """
                return ["id": id, "name": name, "model": "models/\(name).mdl", "origin": "0 0 \(z)",
                        "angles": ["value": "0 0 0", "script": script], "disablepropagation": blocks,
                        "visible": visible] // omission of 'solid' exercises the default
            }
            let near = object("near", id: 51, z: 0, visible: nearVisible, blocks: stop, click: nearClick)
            let far = object("far", id: 82, z: -1, visible: true, blocks: false, click: "")
            func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
            func material(_ color: String) throws -> Data {
                try json(["passes": [["constantshadervalues": ["Color": color]]]])
            }
            let scene: [String: Any] = [
                "general": ["fov": 60, "nearz": 0.01, "farz": 100],
                "camera": ["eye": "0 0 3", "center": "0 0 0", "up": "0 1 0"],
                "objects": nearFirst ? [near, far] : [far, near]
            ]
            files = ["scene.json": try json(scene), "models/near.mdl": mdl(material: "near.json"),
                     "models/far.mdl": mdl(material: "far.json"), "near.json": try material("1 0 0"),
                     "far.json": try material("0 1 0")]
        }
    }

    private func load(_ fixture: Fixture) throws -> SceneRenderEngine {
        let doc = try XCTUnwrap(SceneDocument.build(from: fixture))
        guard let engine = SceneRenderEngine() else { throw XCTSkip("Metal unavailable") }
        engine.load(document: doc, source: fixture)
        engine.setScreenResolution(SIMD2(160, 90))
        engine.update(time: 0, mouseNorm: .zero)
        XCTAssertTrue(engine.has3DScene)
        XCTAssertTrue(engine.needsDesktopInput)
        return engine
    }

    private func state(_ engine: SceneRenderEngine) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(engine.sceneSharedJSON().utf8)) as? [String: Any])
    }

    private func click(_ engine: SceneRenderEngine, at point: CGPoint) {
        engine.routeCursor(.hover, at: point)
        engine.routeCursor(.down, at: point)
        engine.routeCursor(.up, at: point)
    }

    func testOverlappingModelsReceiveEventsInCameraOrderAndShareState() throws {
        for nearFirst in [true, false] {
            let engine = try load(Fixture(nearFirst: nearFirst))
            XCTAssertFalse(engine.containsCursorHotspot(at: blank))
            click(engine, at: center)
            let first = try state(engine)
            XCTAssertEqual(first["events"] as? [String], ["near.down", "far.down", "near.up", "near.click", "far.up", "far.click"])
            let near = try XCTUnwrap(first["near"] as? [NSNumber])
            XCTAssertEqual(near[0].intValue, 1)
            XCTAssertEqual(near[1].floatValue, 0.1, accuracy: 1e-4)
            XCTAssertEqual(near[2].floatValue, 0.1, accuracy: 1e-4)
            XCTAssertEqual(near[3].floatValue, 80, accuracy: 1e-4)
            XCTAssertTrue(near[4].boolValue)

            engine.routeCursor(.down, at: center)
            engine.routeCursor(.drag, at: blank)
            engine.routeCursor(.up, at: blank)
            click(engine, at: blank)
            let second = try state(engine)
            let tail = try XCTUnwrap(second["events"] as? [String]).dropFirst(6)
            XCTAssertEqual(Array(tail), ["near.down", "far.down", "near.drag", "far.drag", "near.up", "far.up"])
            XCTAssertEqual((second["near"] as? [NSNumber])?.first?.intValue, 2)
        }
    }

    func testHiddenModelCanHandleEventAndStartsBlockingOnlyAfterBecomingVisible() throws {
        let engine = try load(Fixture(stop: true, nearVisible: false, nearClick: "thisLayer.visible = true;"))
        // Validate both the drawn material and the input path across the scripted change.
        func centerPixel(_ time: Double) throws -> [UInt8] {
            engine.update(time: time, mouseNorm: .zero)
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
            defer { try? FileManager.default.removeItem(at: file) }
            XCTAssertTrue(engine.renderToPNG(width: 160, height: 90, outURL: file))
            let image = try XCTUnwrap(SceneRenderEngine.decodeEncodedRGBA(Data(contentsOf: file)))
            let i = ((image.h / 2) * image.w + image.w / 2) * 4
            return Array(image.px[i..<(i + 3)])
        }
        let before = try centerPixel(0)
        XCTAssertGreaterThan(before[1], before[0])
        click(engine, at: center)
        let after = try centerPixel(0.02)
        XCTAssertGreaterThan(after[0], after[1])
        click(engine, at: center)
        let events = try XCTUnwrap(state(engine)["events"] as? [String])
        XCTAssertEqual(events, ["near.down", "far.down", "near.up", "near.click", "far.up", "far.click",
                                "near.down", "near.up", "near.click"])
    }

    func testCapturedModelTracksTheCursorBeyondItsBoundsUntilRelease() throws {
        let engine = try load(Fixture(stop: true))
        engine.routeCursor(.hover, at: center)
        engine.routeCursor(.down, at: center)
        engine.routeCursor(.drag, at: blank)
        engine.routeCursor(.up, at: CGPoint(x: 1 - blank.x, y: blank.y))
        let output = try state(engine)
        XCTAssertEqual(output["events"] as? [String], ["near.down", "near.drag", "near.up"])
        let drag = try XCTUnwrap(output["nearDrag"] as? [Float])
        let release = try XCTUnwrap(output["nearUp"] as? [Float])
        for i in [0, 3] { // local / world XYZ coincide for this untransformed model
            XCTAssertLessThan(drag[i], -0.7)
            XCTAssertGreaterThan(release[i], 0.7)
            XCTAssertEqual(-drag[i], release[i], accuracy: 1e-5)
            XCTAssertGreaterThan(drag[i + 1], 0.7)
            XCTAssertEqual(drag[i + 1], release[i + 1], accuracy: 1e-5)
            XCTAssertEqual(drag[i + 2], 0.1, accuracy: 1e-5)
            XCTAssertEqual(release[i + 2], 0.1, accuracy: 1e-5)
        }
    }
}
