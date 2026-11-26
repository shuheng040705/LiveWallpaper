import XCTest
import simd
@testable import LiveWallpaper

final class PuppetHitBoxesTests: XCTestCase {
    /// An independently authored two-bone MDLS tail with a link, bind matrices,
    /// constraint, map and IK chain before its two optional collision records.
    private func tail(order: [UInt32] = [0, 1], version: Int = 4, includeBoxes: Bool = true,
                      includeOrder: Bool = true) -> [UInt8] {
        var bytes = [UInt8]()
        func short(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { bytes += $0 } }
        func word(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { bytes += $0 } }
        func scalar(_ value: Float) { word(value.bitPattern) }
        func matrix(x: Float = 0) {
            var m = matrix_identity_float4x4
            m.columns.3.x = x
            for i in 0..<4 { for j in 0..<4 { scalar(m[i][j]) } }
        }
        short(1)                               // link
        bytes += Array("handle".utf8) + [0]
        word(0); word(1); matrix()
        bytes.append(1); matrix(); matrix(); matrix()
        word(1); word(0); word(0); word(1)      // constraint
        if version >= 4 { word(2); scalar(0.5); scalar(1.5) }
        short(1); word(9); short(1); word(1)    // map
        scalar(10); scalar(2); scalar(3)
        short(1); word(0); word(1); word(0)     // IK set and link
        short(1); word(1); short(1)             // element and joint
        word(0); word(0); scalar(1); scalar(2)
        short(1); word(1)
        bytes.append(includeBoxes ? 1 : 0)
        if includeBoxes {
            scalar(10); scalar(1); scalar(0.5); matrix()
            scalar(3); scalar(2); scalar(1); matrix(x: 2)
        }
        bytes.append(includeOrder ? 1 : 0)
        if includeOrder { order.forEach(word) }
        if version >= 3 { bytes.append(1); word(0); word(1) }
        return bytes
    }

    func testRotatedAndAnimatedBoxesRespectDrawOrderAndAuthoredNames() throws {
        let names = ["wind 鈴", ""]
        for version in 2...4 {
            let boxes = try XCTUnwrap(PuppetHitBoxes.decode(tail(version: version)[...], version: version, names: names))
            let rotated = simd_float4x4(simd_quatf(angle: .pi / 2, axis: [0, 0, 1]))
            var pose = [rotated, matrix_identity_float4x4]
            XCTAssertEqual(boxes.name(at: [0, 5], using: pose), "wind 鈴")
            XCTAssertNil(boxes.name(at: [6, 5], using: pose))
            XCTAssertEqual(boxes.name(at: [0, 0], using: pose), "1")
            pose[1].columns.3.x = 30
            XCTAssertEqual(boxes.name(at: [0, 0], using: pose), "wind 鈴")
            XCTAssertEqual(boxes.name(at: [32, 0], using: pose), "1")
            let reverse = try XCTUnwrap(PuppetHitBoxes.decode(tail(order: [1, 0], version: version)[...], version: version, names: names))
            XCTAssertEqual(reverse.name(at: [0, 0], using: [rotated, matrix_identity_float4x4]), "wind 鈴")
        }
    }

    func testParsedPuppetUsesLastSkinningPoseWithoutScriptBoneAPIOrAnimations() throws {
        var data = Data("MDLV0023\0".utf8)
        func word(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func scalar(_ value: Float) { word(value.bitPattern) }
        word(0); word(3 * 80)
        for column in 0..<3 {
            scalar(Float(column * 15)); scalar(Float(column % 2))
            data.append(Data(repeating: 0, count: 32))
            [1, 0, 0, 0].forEach(word)
            [1, 0, 0, 0, 0.25, 0.5].forEach(scalar)
        }
        word(6); data.append(contentsOf: [0, 0, 1, 0, 2, 0])
        data.append(Data("MDLS0004\0".utf8))
        let endField = data.count
        word(0); word(2)
        for (index, name) in ["wing", "fin"].enumerated() {
            data.append(Data(name.utf8)); data.append(0)
            word(UInt32(index)); word(.max); word(64)
            for k in 0..<16 { scalar(k.isMultiple(of: 5) ? 1 : 0) }
            data.append(0)
        }
        data.append(contentsOf: tail())
        withUnsafeBytes(of: UInt32(data.count).littleEndian) { data.replaceSubrange(endField..<endField + 4, with: $0) }
        let mesh = try XCTUnwrap(PuppetMesh.parse(data, size: [100, 100]))
        XCTAssertTrue(mesh.hasHitBoxes)
        XCTAssertTrue(mesh.scriptBones.isEmpty)
        XCTAssertFalse(mesh.hasSkin)
        XCTAssertEqual(mesh.hitBoxName(at: .zero), "fin")
        var moved = matrix_identity_float4x4
        moved.columns.3.x = 30
        _ = mesh.skinVerts(world: [matrix_identity_float4x4, moved])
        XCTAssertEqual(mesh.hitBoxName(at: .zero), "wing")
        XCTAssertEqual(mesh.hitBoxName(at: [32, 0]), "fin")
        XCTAssertNil(mesh.hitBoxName(at: [15, 0]))
        let withoutBoxes = try XCTUnwrap(PuppetMesh.parse(data.prefix(endField + 8), size: [100, 100]))
        XCTAssertFalse(withoutBoxes.hasHitBoxes)
    }

    func testOutOfPlaneProjectionAndMissingOrInvalidSections() throws {
        let names = ["bar", "handle"]
        let bytes = tail()
        let boxes = try XCTUnwrap(PuppetHitBoxes.decode(bytes[...], version: 4, names: names))
        let edgeOn = simd_float4x4(simd_quatf(angle: .pi / 2, axis: [0, 1, 0]))
        let singular = simd_float4x4(diagonal: [0, 0, 0, 1])
        XCTAssertEqual(boxes.name(at: [0.4, 0], using: [edgeOn, singular]), "bar")
        XCTAssertNil(boxes.name(at: [1.5, 0], using: [edgeOn, singular]))
        XCTAssertNil(boxes.name(at: [.nan, 0], using: [edgeOn, singular]))
        XCTAssertNil(PuppetHitBoxes.decode(tail(includeBoxes: false)[...], version: 4, names: names))
        XCTAssertNil(PuppetHitBoxes.decode(tail(includeOrder: false)[...], version: 4, names: names))
        XCTAssertNil(PuppetHitBoxes.decode(tail(order: [0, 7])[...], version: 4, names: names))
        for length in 0..<bytes.count {
            XCTAssertNil(PuppetHitBoxes.decode(bytes.prefix(length), version: 4, names: names))
        }
    }
}
