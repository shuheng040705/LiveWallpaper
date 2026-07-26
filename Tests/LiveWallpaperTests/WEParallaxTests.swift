import XCTest
@testable import LiveWallpaper

private final class MemorySceneSource: SceneSource {
    let files: [String: Data]
    init(json: [String: Any]) throws {
        files = ["scene.json": try JSONSerialization.data(withJSONObject: json)]
    }
    func data(for relativePath: String) -> Data? { files[relativePath] }
    var allPaths: [String] { Array(files.keys) }
}

final class WEParallaxTests: XCTestCase {
    func testZeroDepthDisablesLayerCompletely() {
        let offset = WEParallaxMath.layerOffset(
            depth: .zero,
            anchor: SIMD2(1982, 1053),
            camera: SIMD2(1920, 1080),
            pointerCentered: SIMD2(-0.5, -0.5),
            sceneSize: SIMD2(3840, 2160),
            amount: 0.03,
            mouseInfluence: 0.36
        )

        XCTAssertEqual(offset, .zero)
    }

    /// open-wallpaper-engine 的 WPUniformSource parallax 单元样例：
    /// 3840×2160、pointer=(0,1)、influence=.36、anchor=(1982,1053)。
    func testLayerOffsetMatchesWEReferenceFormula() {
        let offset = WEParallaxMath.layerOffset(
            depth: SIMD2(-1.56, -0.79),
            anchor: SIMD2(1982, 1053),
            camera: SIMD2(1920, 1080),
            pointerCentered: SIMD2(-0.5, -0.5),
            sceneSize: SIMD2(3840, 2160),
            amount: 0.03,
            mouseInfluence: 0.36
        )

        XCTAssertEqual(offset.x, -35.24976, accuracy: 0.0001)
        XCTAssertEqual(offset.y, -8.57466, accuracy: 0.0001)
    }

    func testVerticalMouseOffsetUsesSceneHeightRatherThanWidth() {
        let offset = WEParallaxMath.layerOffset(
            depth: SIMD2(repeating: 1),
            anchor: SIMD2(960, 540),
            camera: SIMD2(960, 540),
            pointerCentered: SIMD2(0, 0.5),
            sceneSize: SIMD2(1920, 1080),
            amount: 1,
            mouseInfluence: 1
        )

        XCTAssertEqual(offset.x, 0, accuracy: 0.001)
        XCTAssertEqual(offset.y, -540, accuracy: 0.001)
    }

    func testDelayIsDurationAndZeroMeansImmediate() {
        let target = SIMD2<Float>(0.5, -0.25)

        XCTAssertEqual(
            WEParallaxMath.smoothPointer(
                current: .zero, target: target, delay: 2, deltaTime: 0.5
            ),
            target * 0.25
        )
        XCTAssertEqual(
            WEParallaxMath.smoothPointer(
                current: .zero, target: target, delay: 0, deltaTime: 0.5
            ),
            target
        )
    }

    func testShaderParallaxUsesInfluenceButNotCameraAmount() {
        let position = WEParallaxMath.shaderPosition(
            smoothedPointer: SIMD2(0.25, -0.25),
            mouseInfluence: 0.4,
            enabled: true
        )

        XCTAssertEqual(position.x, 0.6, accuracy: 0.0001)
        XCTAssertEqual(position.y, 0.4, accuracy: 0.0001)
        XCTAssertEqual(
            WEParallaxMath.shaderPosition(
                smoothedPointer: SIMD2(0.25, -0.25),
                mouseInfluence: 0.4,
                enabled: false
            ),
            SIMD2(repeating: 0.5)
        )
    }

    func testParallaxControllerPropagatesToOutermostParentByDefault() {
        let controller = WEParallaxResolver.controllerID(
            for: 3,
            parentOf: [3: 2, 2: 1],
            parentPropagates: { _ in true }
        )

        XCTAssertEqual(controller, 1)
    }

    func testDisablePropagationStopsBeforeThatParent() {
        let controller = WEParallaxResolver.controllerID(
            for: 3,
            parentOf: [3: 2, 2: 1],
            parentPropagates: { $0 != 2 }
        )

        XCTAssertEqual(controller, 3)
    }

    func testScriptOnlyNonImageAncestorIsKeptForRuntimeAnchorUpdates() throws {
        let source = try MemorySceneSource(json: [
            "general": [
                "cameraparallax": true,
                "orthogonalprojection": ["width": 1920, "height": 1080],
            ],
            "objects": [
                [
                    "id": 1,
                    "name": "Dynamic group",
                    "origin": [
                        "value": "100 200 0",
                        "script": """
                        export function update(value) {
                            value.x = engine.runtime * 10.0;
                            return value;
                        }
                        """,
                    ],
                    "scale": "1 1 1",
                    "parallaxDepth": "0.5 0.5",
                ],
                [
                    "id": 2,
                    "parent": 1,
                    "name": "Solid child",
                    "image": "models/util/solidlayer.json",
                    "origin": "10 20 0",
                    "size": "100 100",
                    "scale": "1 1 1",
                    "color": "1 1 1",
                    "visible": true,
                ],
            ],
        ])

        let document = try XCTUnwrap(SceneDocument.build(from: source))
        let layer = try XCTUnwrap(document.layers.first)

        XCTAssertEqual(layer.parallaxAnchorId, 1)
        XCTAssertEqual(layer.ancestorOriginId, 1)
        XCTAssertNil(layer.ancestorOriginAnim)
        XCTAssertNotNil(layer.ancestorOriginScript)
    }

    func testQuartzToAppKitConversionUsesMainDisplayHeight() {
        let point = WEMouseViewportMath.appKitPoint(
            fromQuartz: CGPoint(x: -200, y: -100),
            mainDisplayHeight: 1080
        )

        XCTAssertEqual(point.x, -200)
        XCTAssertEqual(point.y, 1180)
    }

    func testMouseCoordinatesAreRelativeToTargetViewportAndClamped() {
        let viewport = CGRect(x: 1920, y: 0, width: 2560, height: 1440)

        XCTAssertEqual(
            WEMouseViewportMath.normalized(
                point: CGPoint(x: viewport.midX, y: viewport.midY),
                viewport: viewport
            ),
            .zero
        )
        XCTAssertEqual(
            WEMouseViewportMath.normalized(
                point: CGPoint(x: 100, y: 2000),
                viewport: viewport
            ),
            SIMD2(-1, 1)
        )
    }
}
