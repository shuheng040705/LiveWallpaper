import XCTest
@testable import LiveWallpaper

final class WEEffectVariantTests: XCTestCase {
    private func effect(_ variants: [[String: String]]) -> WEEffectChain.EffectDef {
        .init(variants: variants.map { .init(combos: $0, passes: []) })
    }

    func testRequestedBlendModeTakesPriorityOverUnrelatedMatchingSettings() {
        let screen = ["BLENDMODE": "7"]
        let settings = ["GAMMA": "1", "MASK": "1"]
        let def = effect([[:], settings, screen, ["BLENDMODE": "13", "GAMMA": "1", "MASK": "1"]])
        let selected = WEEffectChain.selectVariant(def, combos: ["BLENDMODE": 7, "GAMMA": 1, "MASK": 1])
        XCTAssertEqual(selected?.combos, screen)
    }

    func testMissingRequestedBlendModePreservesInputBySkippingThatEffect() {
        let def = effect([[:], ["TOOLS": "1"], ["BLENDMODE": "13", "TOOLS": "1"]])
        XCTAssertNil(WEEffectChain.selectVariant(def, combos: ["BLENDMODE": "7", "TOOLS": 1]))
        XCTAssertEqual(WEEffectChain.selectVariant(def, combos: ["TOOLS": 1])?.combos, ["TOOLS": "1"])
    }

    func testEffectsWithoutBlendVariantsKeepTheirMatchingPermutation() {
        let def = effect([[:], ["TOOLS": "1"]])
        XCTAssertEqual(WEEffectChain.selectVariant(def, combos: ["TOOLS": 1, "BLENDMODE": 7])?.combos, ["TOOLS": "1"])
        XCTAssertEqual(WEEffectChain.selectVariant(def, combos: ["BLENDMODE": 7])?.combos, [:])
    }

    func testDefaultBlendDoesNotSelectAnotherModeEvenWhenOtherOptionsMatch() {
        let other = ["TOOLS": "1", "GAMMA": "1", "MASK": "1", "BLENDMODE": "13"]
        let zero = ["BLENDMODE": "0"]
        let def = effect([other, [:], zero])
        XCTAssertEqual(WEEffectChain.selectVariant(def, combos: ["TOOLS": 1, "GAMMA": 1, "MASK": 1])?.combos, [:])
        XCTAssertEqual(WEEffectChain.selectVariant(def, combos: ["BLENDMODE": 0, "TOOLS": 1])?.combos, zero)
    }

    func testUnboundMaskCannotStandInForAnUnmaskedBlend() {
        for flag in ["MASK", "OPACITYMASK"] {
            let masked = ["BLENDMODE": "7", "TOOLS": "1", "GAMMA": "1", flag: "1"]
            let def = effect([[:], masked])
            XCTAssertNil(WEEffectChain.selectVariant(def, combos: ["BLENDMODE": 7, "TOOLS": 1, "GAMMA": 1]))
            XCTAssertEqual(WEEffectChain.selectVariant(def, combos: masked)?.combos, masked)
        }
    }
}
