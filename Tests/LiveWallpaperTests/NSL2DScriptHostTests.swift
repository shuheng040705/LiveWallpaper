import XCTest
@testable import LiveWallpaper

final class NSL2DScriptHostTests: XCTestCase {
    private let library = """
    globalThis.shared = globalThis.shared || {};
    var parallaxChanged = false;
    shared.libraryInitRan = false;
    shared.calcDepth = function(value) {
        return value.add(new Vec2(2, 4).multiply(engine.userProperties.parallax_center));
    };
    export function init(value) {
        shared.libraryInitRan = true;
        return value;
    }
    export function applyUserProperties(changed) {
        parallaxChanged = changed.hasOwnProperty('parallax_center');
    }
    shared.parallaxChanged = function() { return parallaxChanged; };
    """

    private let layerScript = """
    let original;
    export function init(value) {
        original = value.copy();
        return value;
    }
    export function applyUserProperties(changed) {
        if (shared.parallaxChanged()) {
            thisLayer.parallaxDepth = shared.calcDepth(original);
        }
    }
    """

    func testLibraryInitAndInitialUserPropertiesDriveParallaxDepth() throws {
        let host = NSL2DScriptHost(canvas: SIMD2(3840, 2160))
        host.setUserProperties(["parallax_center": .number(0.5)])
        XCTAssertTrue(host.registerLibrary(source: library).ok)
        XCTAssertTrue(host.register(
            id: 943, prop: "parallaxDepth", source: layerScript,
            scriptProps: [:], layerName: "Sky", staticValue: SIMD3(-2, -1.8, 0)
        ))

        host.runInit()
        XCTAssertEqual(host.eval("shared.libraryInitRan"), "true")
        host.dispatchInitialUserProperties()

        let value = try XCTUnwrap(host.value(id: 943, prop: "parallaxDepth"))
        XCTAssertEqual(value.x, -1, accuracy: 0.0001)
        XCTAssertEqual(value.y, 0.2, accuracy: 0.0001)
    }

    func testSharedEffectConstantApplyWritesBackToExactPass() throws {
        let host = NSL2DScriptHost(canvas: SIMD2(3840, 2160))
        host.setUserProperties(["parallax_center": .number(0.5)])
        XCTAssertTrue(host.registerLibrary(source: library).ok)
        XCTAssertTrue(host.registerEffectConstant(
            id: 1280, effectIndex: 5, passIndex: 0, property: "scale",
            source: layerScript.replacingOccurrences(
                of: "thisLayer.parallaxDepth", with: "thisObject.scale"
            ),
            scriptProps: [:], layerName: "Ground", staticValue: [0.6, 2.2]
        ))

        host.runInit()
        host.dispatchInitialUserProperties()

        let value = try XCTUnwrap(host.effectValue(
            id: 1280, effectIndex: 5, passIndex: 0, property: "scale"
        ))
        XCTAssertEqual(value[0], 1.6, accuracy: 0.0001)
        XCTAssertEqual(value[1], 4.2, accuracy: 0.0001)
    }

    func testUserColorIsExposedAsWEVector() {
        let host = NSL2DScriptHost(canvas: SIMD2(3840, 2160))
        host.setUserProperties(["theme": .color(SIMD3(0.25, 0.5, 0.75))])

        XCTAssertEqual(host.eval("engine.userProperties.theme.multiply(2).x"), "0.5")
        XCTAssertEqual(host.eval("engine.userProperties.theme.subtract(new Vec3(0,0.25,0)).y"), "0.25")
    }

    func testPropertyObjectForwardsLayerValueAndKeepsItsOwnAnimation() throws {
        let host = NSL2DScriptHost(canvas: SIMD2(3840, 2160))
        host.setUserProperties(["parallax_center": .number(0.5)])
        XCTAssertTrue(host.registerLibrary(source: library).ok)
        let script = """
        export function init(value) {
            shared.propertyAnimationLength = thisObject.getAnimation().frameCount;
            thisObject.angles = value.copy();
            return value;
        }
        export function applyUserProperties(changed) {
            let value = thisObject.angles;
            value.z = 17;
            thisObject.angles = value;
        }
        """
        XCTAssertTrue(host.register(
            id: 713, prop: "angles", source: script, scriptProps: [:],
            layerName: "Light Shaft", staticValue: SIMD3(1, 2, 3), animationLength: 30
        ))

        host.runInit()
        host.dispatchInitialUserProperties()

        XCTAssertEqual(host.eval("shared.propertyAnimationLength"), "30")
        let value = try XCTUnwrap(host.value(id: 713, prop: "angles"))
        XCTAssertEqual(value.x, 1, accuracy: 0.0001)
        XCTAssertEqual(value.y, 2, accuracy: 0.0001)
        XCTAssertEqual(value.z, 17, accuracy: 0.0001)
    }
}
