import XCTest
@testable import LiveWallpaper

final class LayerEffectAnimationTests: XCTestCase {
    private func linearAnimation(from start: Float, to end: Float, length: Float = 10) -> WEKeyframeAnimation {
        let keys = [
            WEKeyframeAnimation.Key(frame: 0, value: start, front: nil, back: nil),
            WEKeyframeAnimation.Key(frame: length, value: end, front: nil, back: nil),
        ]
        return WEKeyframeAnimation(channels: [keys], fps: 1, length: length,
                                   mode: .single, relative: false, base: [])
    }

    func testVectorAnimationWritesEveryComponent() {
        var effect = LayerEffect(kind: .none, p: .zero, maskPath: nil)
        effect.weParams = ["offset": "0 0"]
        effect.weParamsPerPass = [["offset": "0 0"]]
        effect.weAnimPerPass = [[
            "offset": WEKeyframeAnimation(
                channels: [
                    linearAnimation(from: 0, to: 10).channels[0],
                    linearAnimation(from: 10, to: 20).channels[0],
                ],
                fps: 1, length: 10, mode: .single, relative: false, base: []
            )
        ]]

        effect.applyKeyframeAnimations(at: 5)

        XCTAssertEqual(effect.weParams["offset"], "5.0 15.0")
        XCTAssertEqual(effect.weParamsPerPass[0]["offset"], "5.0 15.0")
    }

    func testSameParameterCanAnimateDifferentlyPerPass() {
        var effect = LayerEffect(kind: .none, p: .zero, maskPath: nil)
        effect.weParams = ["scale": "0"]
        effect.weParamsPerPass = [["scale": "0"], ["scale": "100"]]
        effect.weAnimPerPass = [
            ["scale": linearAnimation(from: 0, to: 10)],
            ["scale": linearAnimation(from: 100, to: 200)],
        ]

        effect.applyKeyframeAnimations(at: 5)

        XCTAssertEqual(effect.weParamsPerPass[0]["scale"], "5.0")
        XCTAssertEqual(effect.weParamsPerPass[1]["scale"], "150.0")
        XCTAssertEqual(effect.weParams["scale"], "150.0", "合并视图应保持后 pass 覆盖前 pass 的语义")
    }

    func testStaticValueInLaterPassStillWinsMergedView() {
        var effect = LayerEffect(kind: .none, p: .zero, maskPath: nil)
        effect.weParams = ["strength": "99"]
        effect.weParamsPerPass = [["strength": "0"], ["strength": "99"]]
        effect.weAnimPerPass = [
            ["strength": linearAnimation(from: 0, to: 10)],
            [:],
        ]

        effect.applyKeyframeAnimations(at: 5)

        XCTAssertEqual(effect.weParamsPerPass[0]["strength"], "5.0")
        XCTAssertEqual(effect.weParams["strength"], "99")
    }

    func testLoopAnimationWrapsNegativePlaybackTime() {
        var animation = linearAnimation(from: 0, to: 10)
        animation.mode = .loop

        XCTAssertEqual(animation.evaluate(time: -1).first ?? -1, 9, accuracy: 0.001)
    }

    func testMirrorAnimationWrapsNegativePlaybackTime() {
        var animation = linearAnimation(from: 0, to: 10)
        animation.mode = .mirror

        XCTAssertEqual(animation.evaluate(time: -1).first ?? -1, 1, accuracy: 0.001)
        XCTAssertEqual(animation.evaluate(time: -11).first ?? -1, 9, accuracy: 0.001)
    }
}
