import XCTest
@testable import LiveWallpaper

final class WERenderSemanticsTests: XCTestCase {
    func testRuntimeChildVisibilityCannotPierceHiddenParent() {
        let parents = [167: 166, 175: 166]
        let visibility = [166: false, 167: true, 175: true]

        XCTAssertFalse(
            WEVisibilityResolver.ancestorsVisible(for: 167, parentOf: parents) {
                visibility[$0] ?? true
            }
        )
        XCTAssertFalse(
            WEVisibilityResolver.effectiveVisible(for: 167, parentOf: parents) {
                visibility[$0] ?? true
            }
        )

        var runtimeChildVisible = true
        runtimeChildVisible = runtimeChildVisible
            && WEVisibilityResolver.ancestorsVisible(for: 167, parentOf: parents) {
                visibility[$0] ?? true
            }
        XCTAssertFalse(runtimeChildVisible)
    }

    func testRelativeOriginAnimationDoesNotApplyCropOffsetTwice() {
        XCTAssertEqual(
            WECropOffsetPolicy.defaultFraction(hasParent: false, hasRelativeOriginAnimation: true),
            0
        )
        XCTAssertEqual(
            WECropOffsetPolicy.defaultFraction(hasParent: false, hasRelativeOriginAnimation: false),
            0.5
        )
        XCTAssertEqual(
            WECropOffsetPolicy.defaultFraction(hasParent: true, hasRelativeOriginAnimation: false),
            0
        )
    }

    func testFreeImageResolutionUsesActualUploadedTextureDimensions() {
        let unpadded = WEAuxTextureResolution.resolve(
            uploadedWidth: 4096,
            uploadedHeight: 2296,
            imageWidth: 4096,
            imageHeight: 2296
        )
        XCTAssertEqual(unpadded, SIMD4<Float>(4096, 2296, 4096, 2296))

        let padded = WEAuxTextureResolution.resolve(
            uploadedWidth: 4096,
            uploadedHeight: 4096,
            imageWidth: 4096,
            imageHeight: 2296
        )
        XCTAssertEqual(padded, SIMD4<Float>(4096, 4096, 4096, 2296))
    }

    func testComposeLayerCanReferenceParallaxTargetByDelimitedName() {
        XCTAssertEqual(
            WEComposeParallaxAssociation.referencedLayerName(
                composeName: "音条-身体",
                availableNames: ["背景", "身体", "头"]
            ),
            "身体"
        )
        XCTAssertEqual(
            WEComposeParallaxAssociation.referencedLayerName(
                composeName: "Audio Bars - Body",
                availableNames: ["Background", "Body"]
            ),
            "Body"
        )
    }

    func testComposeParallaxAssociationRejectsAmbiguousSubstring() {
        XCTAssertNil(
            WEComposeParallaxAssociation.referencedLayerName(
                composeName: "身体音条",
                availableNames: ["身体"]
            )
        )
        XCTAssertNil(
            WEComposeParallaxAssociation.referencedLayerName(
                composeName: "音条-身",
                availableNames: ["身"]
            )
        )
    }

    func testComposeOpacityMaskIsLimitedByLinkedContentAlpha() {
        let mask: [UInt8] = [
            200, 100, 50, 255,
            200, 100, 50, 255,
            200, 100, 50, 255,
        ]
        let content: [UInt8] = [
            9, 9, 9, 0,
            9, 9, 9, 128,
            9, 9, 9, 255,
        ]
        let result = WEComposeOpacityMask.intersect(
            mask: mask, maskWidth: 3, maskHeight: 1,
            content: content, contentWidth: 3, contentHeight: 1
        )

        XCTAssertEqual(result, [
            0, 0, 0, 255,
            100, 50, 25, 255,
            200, 100, 50, 255,
        ])
    }
}
