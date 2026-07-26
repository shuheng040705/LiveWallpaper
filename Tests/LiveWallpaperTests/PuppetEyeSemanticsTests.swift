import XCTest
@testable import LiveWallpaper

final class PuppetEyeSemanticsTests: XCTestCase {
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
}
