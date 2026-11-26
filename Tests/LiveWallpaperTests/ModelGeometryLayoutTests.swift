import XCTest
import simd
@testable import LiveWallpaper

final class ModelGeometryLayoutTests: XCTestCase {
    private func file(formats: [UInt32]) -> Data {
        var data = Data("MDLV0023\0".utf8)
        func append(_ word: UInt32) {
            withUnsafeBytes(of: word.littleEndian) { data.append(contentsOf: $0) }
        }
        func floats(_ values: [Float]) { values.forEach { append($0.bitPattern) } }
        append(15)
        append(1)
        append(UInt32(formats.count))
        for (mesh, format) in formats.enumerated() {
            data.append(contentsOf: "materials/test.json\0".utf8)
            append(0)
            let x = Float(mesh * 10)
            // The authored box is deliberately larger than the triangle.
            floats([x - 1, -2, -3, x + 4, 5, 6])
            append(format)
            append(format == 0x9 ? 60 : 144)
            for (vx, vy, u, v) in [(0,0,0.25,0.5),(1,0,1,0),(0,1,0,1)] {
                floats([x + Float(vx), Float(vy), 0])
                if format != 0x9 { floats([0, 1, 0, 1, 0, 0, 1]) }
                floats([Float(u), Float(v)])
            }
            append(6)
            data.append(contentsOf: [0,0,1,0,2,0])
            data.append(contentsOf: [0,0,0,0,0,0])
        }
        return data
    }

    func testPositionUVAndFullLayoutCanShareAnIndexedModel() throws {
        let mesh = try XCTUnwrap(MDLGeometry.parse(file(formats: [0x9, 0xf])))
        XCTAssertEqual(mesh.positions.count, 6)
        XCTAssertEqual(mesh.uvs[0], SIMD2(0.25, 0.5))
        XCTAssertEqual(mesh.uvs[3], mesh.uvs[0])
        XCTAssertEqual(Array(mesh.normals.prefix(3)), Array(repeating: SIMD3(0,0,1), count: 3))
        XCTAssertEqual(Array(mesh.normals.suffix(3)), Array(repeating: SIMD3(0,1,0), count: 3))
        XCTAssertEqual(mesh.indices, [0,1,2,3,4,5])
        XCTAssertEqual(mesh.submeshes.map(\.indexStart), [0,3])
        XCTAssertEqual(mesh.bounds.min, SIMD3(-1,-2,-3))
        XCTAssertEqual(mesh.bounds.max, SIMD3(14,5,6))
    }

    func testUnsupportedLayoutCannotMasqueradeAsThe48ByteLayout() {
        XCTAssertNil(MDLGeometry.parse(file(formats: [0x8])))
    }
}
