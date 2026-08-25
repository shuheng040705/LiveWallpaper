import XCTest
@testable import LiveWallpaper

final class PuppetEyeSemanticsTests: XCTestCase {
    private func strayNoseFixture() -> (indices: [UInt16], positions: [SIMD2<Float>], uv: [SIMD2<Float>]) {
        var indices = [UInt16](repeating: 0, count: 2760)
        indices.replaceSubrange(2469..<2475, with: [553, 554, 556, 555, 553, 556])
        var positions = [SIMD2<Float>](repeating: .zero, count: 714)
        var uv = [SIMD2<Float>](repeating: .zero, count: 714)
        positions[553] = SIMD2(720.4552, 864.6265); uv[553] = SIMD2(0.51207, 0.16758)
        positions[554] = SIMD2(742.5624, 954.1605); uv[554] = SIMD2(0.51629, 0.15239)
        positions[555] = SIMD2(804.4624, 954.1605); uv[555] = SIMD2(0.52809, 0.15239)
        positions[556] = SIMD2(812.2000, 859.0999); uv[556] = SIMD2(0.52956, 0.16851)
        return (indices, positions, uv)
    }

    func testKnownStrayPuppetPartIsDegeneratedWithoutChangingPartOrder() {
        var fixture = strayNoseFixture()
        let groups = [PuppetMesh.DrawGroup(id: 31, startIndex: 2469, indexCount: 6)]

        let suppressed = PuppetMesh.sanitizeKnownStrayParts(
            size: SIMD2(5247, 5894), indices: &fixture.indices, groups: groups,
            rawPos: fixture.positions, uv: fixture.uv, boneCount: 79
        )

        XCTAssertEqual(suppressed, [31])
        XCTAssertEqual(Array(fixture.indices[2469..<2475]), [553, 553, 553, 553, 553, 553])
        XCTAssertEqual(groups[0].startIndex, 2469)
        XCTAssertEqual(groups[0].indexCount, 6)
    }

    func testStrayPartSanitizerDoesNotMatchAnotherPuppetWithSamePartId() {
        var fixture = strayNoseFixture()
        fixture.uv[553].x += 0.01
        let original = fixture.indices

        let suppressed = PuppetMesh.sanitizeKnownStrayParts(
            size: SIMD2(5247, 5894), indices: &fixture.indices,
            groups: [PuppetMesh.DrawGroup(id: 31, startIndex: 2469, indexCount: 6)],
            rawPos: fixture.positions, uv: fixture.uv, boneCount: 79
        )

        XCTAssertTrue(suppressed.isEmpty)
        XCTAssertEqual(fixture.indices, original)
    }

    func testRecognizesEyeAndBlinkSemanticsAcrossWorkshopLanguages() {
        let names = [
            "eye", "Left Iris", "pupil highlight", "eyelid",
            "眨眼", "左眼组合", "瞳孔", "瞬き", "まばたき", "눈 깜빡임",
        ]

        for name in names {
            XCTAssertTrue(
                SceneRenderEngine.eyeSemanticName(name),
                "应识别眼部/眨眼语义：\(name)"
            )
        }
    }

    func testGenericObjectAndBodyAnimationNamesAreNotEyes() {
        let names = [
            "人物", "character", "body", "head", "hair",
            "animation 1", "待机", "呼吸", "左手", "尾巴",
        ]

        for name in names {
            XCTAssertFalse(
                SceneRenderEngine.eyeSemanticName(name),
                "普通全身/部件名不能误判为眼睛：\(name)"
            )
        }
    }

    func testIrisOcclusionFollowsTheWholeEyelidOpeningTravel() {
        XCTAssertEqual(WEBlinkIrisOcclusion.sweep(travelRatio: 1), 1, accuracy: 0.0001)
        XCTAssertEqual(WEBlinkIrisOcclusion.sweep(travelRatio: 0.9), 1, accuracy: 0.0001)
        XCTAssertEqual(WEBlinkIrisOcclusion.sweep(travelRatio: 0.45), 0.5, accuracy: 0.0001)
        XCTAssertEqual(WEBlinkIrisOcclusion.sweep(travelRatio: 0), 0, accuracy: 0.0001)

        // 旧睁眼公式在 r=0.5 时已经返回 0（整颗虹膜全露）；现在眼皮还有一半行程时
        // 虹膜仍应有一半以上被遮挡，直到眼睑完全复位才完整出现。
        XCTAssertGreaterThan(WEBlinkIrisOcclusion.sweep(travelRatio: 0.5), 0.5)

        // 缓入缓出：接近睁开时比线性更快收尾，接近闭合时比线性更早藏好，
        // 中点仍保持 0.5，避免改变眨眼的整体节拍。
        XCTAssertLessThan(WEBlinkIrisOcclusion.sweep(travelRatio: 0.09), 0.05)
        XCTAssertGreaterThan(WEBlinkIrisOcclusion.sweep(travelRatio: 0.81), 0.95)
    }

    func testIrisOcclusionFeatherIsSmoothAndBounded() {
        XCTAssertEqual(WEBlinkIrisOcclusion.featherAlpha(sampleY: -3, clipY: 0, halfWidth: 2), 1, accuracy: 0.0001)
        XCTAssertEqual(WEBlinkIrisOcclusion.featherAlpha(sampleY: 0, clipY: 0, halfWidth: 2), 0.5, accuracy: 0.0001)
        XCTAssertEqual(WEBlinkIrisOcclusion.featherAlpha(sampleY: 3, clipY: 0, halfWidth: 2), 0, accuracy: 0.0001)
    }
}
