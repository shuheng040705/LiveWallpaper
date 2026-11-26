import XCTest
import simd
@testable import LiveWallpaper

final class SceneModelPickingTests: XCTestCase {
    // A Metal right-handed perspective camera at the origin, vertical FOV 90°.
    private let projection = simd_float4x4(columns: (
        SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0),
        SIMD4(0, 0, -10.0 / 9.0, -1), SIMD4(0, 0, -10.0 / 9.0, 0)
    ))

    private func ray(at point: CGPoint, uvScale: SIMD2<Float> = .one,
                     offset: SIMD2<Float> = .zero, ndc: SIMD2<Float> = .one) -> ScenePickRay? {
        ScenePickRay(screen: point, uvScale: uvScale, uvOffset: offset, ndcScale: ndc, viewProjection: projection)
    }

    func testTransformedAsymmetricMeshReportsModelUnitsFromBoxCenter() throws {
        let bounds = SceneModelBounds(min: SIMD3(-0.7, -0.8, -0.25), max: SIMD3(0.8, 1.2, 0.75))
        // A rotated and mirrored model under a translated, nonuniformly scaled parent.
        let world = simd_float4x4(columns: (
            SIMD4(0, -2, 0, 0), SIMD4(-0.5, 0, 0, 0),
            SIMD4(0, 0, 0.75, 0), SIMD4(1, -0.25, -4, 1)
        ))
        let entered = SIMD3<Float>(0.15, -0.2, 0.75)
        let expected = world * SIMD4(entered, 1)
        let clip = projection * expected
        let screen = CGPoint(x: CGFloat(0.5 + clip.x / clip.w / 2),
                             y: CGFloat(0.5 - clip.y / clip.w / 2))
        let hit = try XCTUnwrap(bounds.hit(id: 57, world: world, depth: 4, ray: XCTUnwrap(ray(at: screen))))
        XCTAssertEqual(hit.id, 57)
        XCTAssertEqual(hit.depth, 4)
        let local = entered - (bounds.min + bounds.max) / 2
        XCTAssertLessThan(simd_distance(hit.local, local), 1e-5)
        XCTAssertLessThan(simd_distance(hit.world, SIMD3(expected.x, expected.y, expected.z)), 1e-5)
    }

    func testCropOffsetAndFitBlackBarsUseThePresentedImage() throws {
        // The right half of the encoded texture is stretched to fill the screen.
        let cropped = try XCTUnwrap(ray(at: CGPoint(x: 0.5, y: 0.5), uvScale: SIMD2(0.5, 1), offset: SIMD2(0.25, 0)))
        XCTAssertNil(ray(at: CGPoint(x: 0.5, y: 0.1), uvScale: SIMD2(1, 2)))
        XCTAssertNil(ray(at: CGPoint(x: -0.001, y: 0.5)))
        var world = matrix_identity_float4x4
        world.columns.3 = SIMD4(1.5, 0, -3, 1)
        let box = SceneModelBounds(min: SIMD3(repeating: -0.2), max: SIMD3(repeating: 0.2))
        let hit = try XCTUnwrap(box.hit(id: 1, world: world, depth: 3, ray: cropped))
        XCTAssertEqual(hit.world.z, -2.8, accuracy: 0.0001)
        XCTAssertEqual(hit.world.x, 1.4, accuracy: 0.0001)
        let unoffset = try XCTUnwrap(ray(at: CGPoint(x: 0.5, y: 0.5)))
        XCTAssertNil(box.hit(id: 1, world: world, depth: 3, ray: unoffset))
    }

    func testAxisParallelRayAndCollapsedModelDoNotClaimClicks() throws {
        let r = try XCTUnwrap(ray(at: CGPoint(x: 0.5, y: 0.5)))
        var world = matrix_identity_float4x4
        world.columns.3.z = -3
        let box = SceneModelBounds(min: SIMD3(repeating: -1), max: SIMD3(repeating: 1))
        XCTAssertNotNil(box.hit(id: 1, world: world, depth: 3, ray: r))
        world.columns.3.x = 1
        XCTAssertNil(box.hit(id: 1, world: world, depth: 3, ray: r))
        world.columns.3.x = 0
        world.columns.0.x = 0
        XCTAssertNil(box.hit(id: 1, world: world, depth: 3, ray: r))
    }

    func testCaptureFollowsTheTransformedLocalAnchorThroughALetterbox() throws {
        let box = SceneModelBounds(min: SIMD3(0, -2, -1), max: SIMD3(2, 2, 1))
        let world = simd_float4x4(columns: (
            SIMD4(0, 2, 0, 0), SIMD4(-1, 0, 0, 0),
            SIMD4(0, 0, 0.5, 0), SIMD4(2, 1, -4, 1)
        ))
        let point = CGPoint(x: 0.5, y: 0)
        let scale = SIMD2<Float>(1, 2)
        XCTAssertNil(ray(at: point, uvScale: scale))
        let outside = try XCTUnwrap(ScenePickRay(screen: point, uvScale: scale, uvOffset: .zero, ndcScale: .one,
                                                 viewProjection: projection, allowOutsideImage: true))
        let hit = try XCTUnwrap(box.projectCapture(id: 32, world: world, depth: 4,
                                                  ray: outside, previousLocal: SIMD3(0, 0, 1)))
        XCTAssertLessThan(simd_distance(hit.world, SIMD3(0, 7, -3.5)), 1e-5)
        XCTAssertLessThan(simd_distance(hit.local, SIMD3(2, 2, 1)), 1e-5)
        XCTAssertNil(box.hit(id: 32, world: world, depth: 4, ray: outside))
    }
}
