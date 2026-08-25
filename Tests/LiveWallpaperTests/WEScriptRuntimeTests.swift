import XCTest
@testable import LiveWallpaper

final class WEScriptRuntimeTests: XCTestCase {
    func testExceptionWithThrowingToStringDoesNotReenterHandlerForever() {
        let script = """
        export function update(value) {
            throw {
                toString() {
                    throw new Error("nested formatting failure");
                }
            };
        }
        """
        let runtime = WEScript(
            script: script,
            propertyOverrides: [:],
            tag: "throwing-toString-test"
        )

        XCTAssertNotNil(runtime)
        XCTAssertNil(runtime?.runScalar(current: 1, simTime: 1, frametime: 1.0 / 60.0))
        XCTAssertEqual(runtime?.didFail, true)
    }

    func testTemplateLayerSizeUsesRealGeometryAndValueSemantics() {
        let script = """
        export function update(value) {
            let imageSize = thisLayer.size;
            imageSize.x *= thisLayer.scale.x * 0.5;
            imageSize.y *= thisLayer.scale.y * 0.5;
            return new Vec3(imageSize.x, imageSize.y, value.z);
        }
        """
        let runtime = WEScript(
            script: script,
            propertyOverrides: [:],
            tag: "template-layer-size-test"
        )
        runtime?.setTemplateLayerTransform(
            origin: .zero,
            scale: SIMD3(0.15, 0.2, 1),
            angles: .zero
        )
        runtime?.setTemplateLayerSize(SIMD2(400, 200))

        guard case .vec3(let first)? = runtime?.runVec3(
            current: .zero,
            simTime: 1,
            frametime: 1.0 / 60.0
        ), case .vec3(let second)? = runtime?.runVec3(
            current: .zero,
            simTime: 2,
            frametime: 1.0 / 60.0
        ) else {
            return XCTFail("size-backed script did not return a vector")
        }
        XCTAssertEqual(first.x, 30, accuracy: 0.001)
        XCTAssertEqual(first.y, 20, accuracy: 0.001)
        XCTAssertEqual(second.x, first.x, accuracy: 0.001)
        XCTAssertEqual(second.y, first.y, accuracy: 0.001)
        XCTAssertEqual(runtime?.didFail, false)
    }

    func testGetParentUsesFullSceneObjectTreeAndLocalGeometry() {
        let script = """
        var parent;
        export function init() {
            parent = thisLayer.getParent();
        }
        export function update(value) {
            if (!parent || !parent.visible) return new Vec3(-1, -1, -1);
            return parent.origin.add(thisLayer.origin);
        }
        """
        let runtime = WEScript(
            script: script,
            propertyOverrides: [:],
            tag: "parent-object-tree-test"
        )
        runtime?.setTemplateLayerTransform(
            origin: SIMD3(10, 20, 0),
            scale: SIMD3(0.5, 0.5, 1),
            angles: .zero
        )
        runtime?.setTemplateLayerIdentity(
            id: 2,
            name: "Child",
            parentId: 1,
            visible: true,
            alpha: 1,
            color: SIMD4(repeating: 1)
        )
        runtime?.setSceneLayers([
            .init(
                id: 1,
                name: "Container without image",
                parentId: nil,
                visible: true,
                alpha: 0.75,
                color: SIMD4(0.1, 0.2, 0.3, 1),
                origin: SIMD3(100, 200, 0),
                scale: SIMD3(repeating: 1),
                angles: .zero,
                size: .zero
            ),
            .init(
                id: 2,
                name: "Child",
                parentId: 1,
                visible: true,
                alpha: 1,
                color: SIMD4(repeating: 1),
                origin: SIMD3(10, 20, 0),
                scale: SIMD3(0.5, 0.5, 1),
                angles: .zero,
                size: SIMD2(64, 64)
            )
        ])

        guard case .vec3(let result)? = runtime?.runVec3(
            current: .zero,
            simTime: 1,
            frametime: 1.0 / 60.0
        ) else {
            return XCTFail("getParent-backed script did not return a vector")
        }
        XCTAssertEqual(result.x, 110, accuracy: 0.001)
        XCTAssertEqual(result.y, 220, accuracy: 0.001)
        XCTAssertEqual(result.z, 0, accuracy: 0.001)
        XCTAssertEqual(runtime?.didFail, false)
    }

    func testReinstallingEqualSceneTreePreservesParentObjectIdentity() {
        let script = """
        var cachedParent;
        export function init() {
            cachedParent = thisLayer.getParent();
            cachedParent.marker = 7;
        }
        export function update(value) {
            let freshParent = thisLayer.getParent();
            return new Vec3(cachedParent.marker, freshParent.marker, cachedParent === freshParent ? 1 : 0);
        }
        """
        let runtime = WEScript(script: script, propertyOverrides: [:], tag: "stable-parent-identity-test")
        runtime?.setTemplateLayerTransform(origin: .zero, scale: SIMD3(repeating: 1), angles: .zero)
        runtime?.setTemplateLayerIdentity(
            id: 2, name: "Child", parentId: 1, visible: true, alpha: 1, color: SIMD4(repeating: 1)
        )
        let definitions: [WEScript.SceneLayerDefinition] = [
            .init(
                id: 1, name: "Parent", parentId: nil, visible: true, alpha: 1,
                color: SIMD4(repeating: 1), origin: .zero, scale: SIMD3(repeating: 1),
                angles: .zero, size: .zero
            ),
            .init(
                id: 2, name: "Child", parentId: 1, visible: true, alpha: 1,
                color: SIMD4(repeating: 1), origin: .zero, scale: SIMD3(repeating: 1),
                angles: .zero, size: .zero
            )
        ]
        runtime?.setSceneLayers(definitions)
        _ = runtime?.runVec3(current: .zero, simTime: 1)
        runtime?.setSceneLayers(definitions)
        guard case .vec3(let result)? = runtime?.runVec3(current: .zero, simTime: 2) else {
            return XCTFail("parent identity script failed")
        }
        XCTAssertEqual(result, SIMD3(7, 7, 1))
        XCTAssertEqual(runtime?.didFail, false)
    }

    func testVectorArgumentHasWEValueMethods() {
        let script = """
        var initial;
        export function init(value) {
            initial = value.copy();
        }
        export function update(value) {
            return initial.multiply(new Vec3(2, 3, 1));
        }
        """
        let runtime = WEScript(script: script, propertyOverrides: [:], tag: "vec3-argument-test")
        guard case .vec3(let result)? = runtime?.runVec3(
            current: SIMD3(4, 5, 6),
            simTime: 1,
            frametime: 1.0 / 60.0
        ) else {
            return XCTFail("Vec3 method-backed script failed")
        }
        XCTAssertEqual(result.x, 8, accuracy: 0.001)
        XCTAssertEqual(result.y, 15, accuracy: 0.001)
        XCTAssertEqual(result.z, 6, accuracy: 0.001)
        XCTAssertEqual(runtime?.didFail, false)
    }

    func testTransformMatrixContainsParentResolvedWorldTranslation() {
        let script = """
        export function update(value) {
            let matrix = thisLayer.getTransformMatrix().m;
            return new Vec3(matrix[12], matrix[13], matrix[14]);
        }
        """
        let runtime = WEScript(script: script, propertyOverrides: [:], tag: "transform-matrix-test")
        runtime?.setTemplateLayerTransform(origin: SIMD3(10, 20, 3), scale: SIMD3(repeating: 1), angles: .zero)
        runtime?.setTemplateLayerIdentity(
            id: 2, name: "Child", parentId: 1, visible: true, alpha: 1, color: SIMD4(repeating: 1)
        )
        runtime?.setSceneLayers([
            .init(
                id: 1, name: "Parent", parentId: nil, visible: true, alpha: 1,
                color: SIMD4(repeating: 1), origin: SIMD3(100, 200, 7),
                scale: SIMD3(repeating: 1), angles: .zero, size: .zero
            ),
            .init(
                id: 2, name: "Child", parentId: 1, visible: true, alpha: 1,
                color: SIMD4(repeating: 1), origin: SIMD3(10, 20, 3),
                scale: SIMD3(repeating: 1), angles: .zero, size: .zero
            )
        ])
        guard case .vec3(let result)? = runtime?.runVec3(current: .zero, simTime: 1) else {
            return XCTFail("getTransformMatrix-backed script failed")
        }
        XCTAssertEqual(result.x, 110, accuracy: 0.001)
        XCTAssertEqual(result.y, 220, accuracy: 0.001)
        XCTAssertEqual(result.z, 10, accuracy: 0.001)
        XCTAssertEqual(runtime?.didFail, false)
    }

    func testTemplateVideoControlSurfaceDoesNotCrashScriptLifecycle() {
        let script = """
        let layerVideo;
        export function init() {
            layerVideo = thisLayer.getVideoTexture();
            layerVideo.stop();
            layerVideo.setCurrentTime(0);
        }
        export function update(value) {
            return layerVideo.isPlaying() === 1;
        }
        """
        let runtime = WEScript(script: script, propertyOverrides: [:], tag: "video-control-surface-test")
        XCTAssertEqual(runtime?.runBool(current: false, simTime: 1), true)
        XCTAssertEqual(runtime?.didFail, false)
    }

    func testPlaybackOnlyScriptRunsInitBeforeMediaEventAndUpdatesVisibility() {
        let script = """
        export function init() {
            thisLayer.visible = false;
        }
        export function mediaPlaybackChanged(event) {
            thisLayer.visible = event.state !== MediaPlaybackEvent.PLAYBACK_STOPPED;
        }
        """
        let runtime = WEScript(script: script, propertyOverrides: [:], tag: "playback-event-test")
        XCTAssertNotNil(runtime)
        XCTAssertEqual(runtime?.usesMediaEvents, true)

        runtime?.dispatchMediaState(
            title: "Track",
            artist: "Artist",
            positionSec: 1,
            lengthSec: 60,
            playbackState: 1
        )
        XCTAssertEqual(runtime?.runBool(current: false, simTime: 1), true)

        runtime?.dispatchMediaState(
            title: "",
            artist: "",
            positionSec: 0,
            lengthSec: 0,
            playbackState: 0
        )
        XCTAssertEqual(runtime?.runBool(current: true, simTime: 2), false)
        XCTAssertEqual(runtime?.didFail, false)
    }

    func testThumbnailEventUsesVec3ColorsAndDeduplicatesByArtworkRevision() {
        let script = """
        var calls = 0;
        var sum = new Vec3(0, 0, 0);
        var hasThumbnail = false;
        export function mediaThumbnailChanged(event) {
            calls += 1;
            hasThumbnail = event.hasThumbnail;
            sum = event.primaryColor
                .add(event.secondaryColor)
                .add(event.tertiaryColor)
                .add(event.textColor)
                .add(event.highContrastColor);
        }
        export function update(value) {
            return new Vec3(calls, sum.x + sum.y + sum.z, hasThumbnail ? 1 : 0);
        }
        """
        let runtime = WEScript(script: script, propertyOverrides: [:], tag: "thumbnail-event-test")
        let palette = NowPlayingProvider.ThumbnailPalette(
            hasThumbnail: true,
            primaryColor: SIMD3(0.1, 0.2, 0.3),
            secondaryColor: SIMD3(0.2, 0.3, 0.4),
            tertiaryColor: SIMD3(0.3, 0.4, 0.5),
            textColor: SIMD3(repeating: 1),
            highContrastColor: .zero
        )

        runtime?.dispatchMediaState(
            title: "Track", artist: "Artist", positionSec: 0, lengthSec: 60,
            playbackState: 1, thumbnailRevision: 7, thumbnailPalette: palette
        )
        guard case .vec3(let first)? = runtime?.runVec3(current: .zero, simTime: 0) else {
            return XCTFail("thumbnail callback did not return Vec3-derived state")
        }
        XCTAssertEqual(first.x, 1, accuracy: 0.001)
        XCTAssertEqual(first.y, 5.7, accuracy: 0.001)
        XCTAssertEqual(first.z, 1, accuracy: 0.001)

        runtime?.dispatchMediaState(
            title: "Track 2", artist: "Artist", positionSec: 1, lengthSec: 60,
            playbackState: 1, thumbnailRevision: 7, thumbnailPalette: .missing
        )
        guard case .vec3(let sameRevision)? = runtime?.runVec3(current: .zero, simTime: 1) else {
            return XCTFail("thumbnail callback state disappeared")
        }
        XCTAssertEqual(sameRevision.x, 1, accuracy: 0.001)
        XCTAssertEqual(sameRevision.z, 1, accuracy: 0.001)

        runtime?.dispatchMediaState(
            title: "Track 3", artist: "Artist", positionSec: 2, lengthSec: 60,
            playbackState: 1, thumbnailRevision: 8, thumbnailPalette: .missing
        )
        guard case .vec3(let changedRevision)? = runtime?.runVec3(current: .zero, simTime: 2) else {
            return XCTFail("new thumbnail revision was not dispatched")
        }
        XCTAssertEqual(changedRevision.x, 2, accuracy: 0.001)
        XCTAssertEqual(changedRevision.z, 0, accuracy: 0.001)
        XCTAssertEqual(runtime?.didFail, false)
    }

    func testEngineTimeoutFiresOnceAndCanBeCancelled() {
        let script = """
        var result = 0;
        export function init() {
            engine.setTimeout(function() { result += 2; }, 500);
            let cancel = engine.setTimeout(function() { result += 100; }, 250);
            cancel();
        }
        export function update(value) {
            return result;
        }
        """
        let runtime = WEScript(script: script, propertyOverrides: [:], tag: "timeout-test")
        XCTAssertEqual(runtime?.runScalar(current: 0, simTime: 0), 0)
        XCTAssertEqual(runtime?.runScalar(current: 0, simTime: 0.25), 0)
        XCTAssertEqual(runtime?.runScalar(current: 0, simTime: 0.5), 2)
        XCTAssertEqual(runtime?.runScalar(current: 0, simTime: 1), 2)
        XCTAssertEqual(runtime?.didFail, false)
    }

    func testTemplateAnimationRateControlsKeyframeTime() {
        let script = """
        let animation;
        export function init() {
            animation = thisLayer.getAnimation();
            animation.rate = 2;
        }
        export function update(value) {
            return value;
        }
        """
        let runtime = WEScript(script: script, propertyOverrides: [:], tag: "animation-rate-test")
        runtime?.setTemplateAnimation(frameCount: 300, fps: 30)

        XCTAssertEqual(runtime?.runScalar(current: 0, simTime: 0), 0)
        XCTAssertEqual(runtime?.runScalar(current: 0, simTime: 1), 0)
        XCTAssertEqual(runtime?.controlledAnimationTime(defaultTime: 1) ?? -1, 2, accuracy: 0.001)
        XCTAssertEqual(runtime?.didFail, false)
    }

    func testTemplateAnimationPauseSetFrameAndResume() {
        let script = """
        let animation;
        export function init() {
            animation = thisObject.getAnimation();
            animation.setFrame(90);
            animation.pause();
        }
        export function update(value) {
            if (value === 1) animation.play();
            return value;
        }
        """
        let runtime = WEScript(script: script, propertyOverrides: [:], tag: "animation-transport-test")
        runtime?.setTemplateAnimation(frameCount: 300, fps: 30)

        XCTAssertEqual(runtime?.runScalar(current: 0, simTime: 0), 0)
        XCTAssertEqual(runtime?.controlledAnimationTime(defaultTime: 0) ?? -1, 3, accuracy: 0.001)
        XCTAssertEqual(runtime?.runScalar(current: 0, simTime: 5), 0)
        XCTAssertEqual(runtime?.controlledAnimationTime(defaultTime: 5) ?? -1, 3, accuracy: 0.001)
        XCTAssertEqual(runtime?.runScalar(current: 1, simTime: 5), 1)
        XCTAssertEqual(runtime?.runScalar(current: 0, simTime: 6), 0)
        XCTAssertEqual(runtime?.controlledAnimationTime(defaultTime: 6) ?? -1, 4, accuracy: 0.001)
        XCTAssertEqual(runtime?.didFail, false)
    }

    func testBoundClockPositionAndDateScriptsRunWithoutStackOverflow() {
        let originScript = """
        var weizhi = { x: 0, y: 0, z: 0 };
        var weizhix = 0, weizhiy = 0, weizhiz = 0;
        export function init(value) {
            weizhi = value;
            weizhix = value.x;
            weizhiy = value.y;
            weizhiz = value.z;
            return value;
        }
        export function update(value) {
            value = weizhi;
            value.x = 2940.6069 + weizhix;
            value.y = 1651.2385 + weizhiy;
            value.z = weizhiz;
            let scale = thisLayer.scale;
            let imageSize = thisLayer.size;
            let canvasSize = engine.canvasSize;
            imageSize.x *= scale.x * 0.5;
            imageSize.y *= scale.y * 0.5;
            value.x = Math.min(Math.max(value.x, imageSize.x), canvasSize.x - imageSize.x);
            value.y = Math.min(Math.max(value.y, imageSize.y), canvasSize.y - imageSize.y);
            console.log(value);
            return value;
        }
        """
        let origin = WEScript(script: originScript, propertyOverrides: [:], tag: "clock-origin-test",
                              canvas: SIMD2(3840, 2160))
        origin?.setTemplateLayerTransform(origin: .zero, scale: SIMD3(repeating: 0.15), angles: .zero)
        origin?.setTemplateLayerSize(SIMD2(379, 219))
        guard case .vec3(let position)? = origin?.runVec3(current: .zero, simTime: 1, frametime: 1.0 / 60.0) else {
            return XCTFail("clock position script failed")
        }
        XCTAssertEqual(position.x, 2940.6069, accuracy: 0.001)
        XCTAssertEqual(position.y, 1651.2385, accuracy: 0.001)

        let dateScript = """
        export function update(value) {
            let date = new Date();
            let months = [' JAN ', ' FEB ', ' MAR ', ' APR ', ' MAY ', ' JUN ',
                          ' JUL ', ' AUG ', ' SEP ', ' OCT ', ' NOV ', ' DEC '];
            return date.getDate() + '' + months[date.getMonth()] + '' + date.getFullYear();
        }
        """
        let date = WEScript(script: dateScript, propertyOverrides: [:], tag: "date-test")
        guard case .string(let dateText)? = date?.runString(current: "", simTime: 1) else {
            return XCTFail("date text script failed")
        }
        XCTAssertFalse(dateText.isEmpty)
        XCTAssertEqual(date?.didFail, false)
    }

    func testRuntimeCanMoveFromCreatingThreadToWorkerQueue() {
        let script = """
        export function update(value) {
            let date = new Date();
            return date.getFullYear() + "-" + (date.getMonth() + 1);
        }
        """
        let runtime = WEScript(script: script, propertyOverrides: [:], tag: "worker-queue-test")
        let finished = expectation(description: "worker queue script evaluation")
        let lock = NSLock()
        var output: WEScript.Result?

        DispatchQueue(label: "WEScriptRuntimeTests.worker").async {
            let result = runtime?.runString(current: "", simTime: 1)
            lock.lock()
            output = result
            lock.unlock()
            finished.fulfill()
        }
        wait(for: [finished], timeout: 2)
        lock.lock()
        let result = output
        lock.unlock()
        guard case .string(let text)? = result else {
            return XCTFail("runtime failed after moving to a worker queue")
        }
        XCTAssertFalse(text.isEmpty)
        XCTAssertEqual(runtime?.didFail, false)
    }

    func testEffectVectorScriptReceivesSharedStateFromObjectScript() {
        let controller = WEScript(
            script: """
            export function update(value) {
                shared.dockAlpha = 0.25;
                return value;
            }
            """,
            propertyOverrides: [:],
            tag: "shared-controller-test"
        )
        let effect = WEScript(
            script: """
            export var scriptProperties = createScriptProperties()
                .addSlider({ name: 'alpha', value: 0.35 })
                .finish();
            export function update(value) {
                let alpha = scriptProperties.alpha * shared.dockAlpha;
                return new Vec2(alpha, alpha);
            }
            """,
            propertyOverrides: ["alpha": 0.4],
            tag: "shared-effect-test"
        )

        XCTAssertEqual(controller?.runBool(current: true, simTime: 1), true)
        effect?.injectShared(controller?.sharedJSON() ?? "{}")
        let value = effect?.runFloats(current: [0, 0.3], simTime: 1, frametime: 1.0 / 60.0)

        XCTAssertEqual(value?.count, 2)
        XCTAssertEqual(value?[0] ?? -1, 0.1, accuracy: 0.0001)
        XCTAssertEqual(value?[1] ?? -1, 0.1, accuracy: 0.0001)
    }

    func testEffectVectorScriptSupportsVec4() {
        let runtime = WEScript(
            script: """
            export function update(value) {
                return new Vec4(value.x + 1, value.y + 2, value.z + 3, value.w + 4);
            }
            """,
            propertyOverrides: [:],
            tag: "effect-vec4-test"
        )

        XCTAssertEqual(
            runtime?.runFloats(current: [1, 2, 3, 4], simTime: 1),
            [2, 4, 6, 8]
        )
    }
}
