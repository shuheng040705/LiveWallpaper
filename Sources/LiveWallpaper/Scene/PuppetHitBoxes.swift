import Foundation
import simd

/// MDLS stores optional oriented boxes in each bone's local coordinates. The
/// puppet draw order resolves overlaps independently of the array of bones.
final class PuppetHitBoxes {
    struct Box {
        let name: String
        let halfSize: SIMD3<Float>
        let transform: simd_float4x4

        func contains(_ point: SIMD2<Float>, bone: simd_float4x4) -> Bool {
            // Orthographic projection. Even for a bone rotated out of the image
            // plane, a pixel belongs to the projected box if its line meets all slabs.
            let frame = bone * transform
            let determinant = frame.determinant
            guard determinant.isFinite, determinant != 0 else { return false }
            let inverse = frame.inverse
            let origin = inverse * SIMD4<Float>(point.x, point.y, 0, 1)
            let direction = inverse.columns.2
            var low = -Float.infinity, high = Float.infinity
            for axis in 0..<3 {
                let o = origin[axis], d = direction[axis], h = halfSize[axis]
                guard o.isFinite, d.isFinite else { return false }
                if d == 0 {
                    guard abs(o) <= h else { return false }
                } else {
                    let t0 = (-h - o) / d, t1 = (h - o) / d
                    low = max(low, min(t0, t1))
                    high = min(high, max(t0, t1))
                    if low > high { return false }
                }
            }
            return true
        }
    }

    let boxes: [Box]
    let order: [Int]
    // Assigned by the same skinning operation that updates this layer's vertices.
    // Array copy-on-write keeps the pose until the next rendered frame.
    var drawnPose: [simd_float4x4]?

    private init(boxes: [Box], order: [Int]) {
        self.boxes = boxes
        self.order = order
    }

    func name(at point: SIMD2<Float>, using pose: [simd_float4x4]) -> String? {
        guard point.x.isFinite, point.y.isFinite, pose.count == boxes.count else { return nil }
        for index in order.reversed() where boxes[index].contains(point, bone: pose[index]) {
            return boxes[index].name
        }
        return nil
    }

    /// Starts immediately after the skeleton's last bone. The MDLS section's
    /// absolute end bounds every read, including variable-length IK records.
    static func decode(_ bytes: ArraySlice<UInt8>, version: Int, names: [String]) -> PuppetHitBoxes? {
        guard (2...4).contains(version), !names.isEmpty else { return nil }
        var reader = SkeletonTail(bytes)
        do {
            let links = try reader.uint16()
            for _ in 0..<links {
                try reader.skipString()
                try reader.skip(8 + 64)
            }
            if try reader.flag() { try reader.skip(64 * (names.count + links)) }
            let constraints = try reader.uint32()
            for _ in 0..<constraints {
                try reader.skip(12)
                if version >= 4, try reader.uint32() & 2 != 0 { try reader.skip(8) }
            }
            let maps = try reader.uint16()
            try reader.skip(4 * maps)
            for _ in 0..<maps { try reader.skip(16 * reader.uint16()) }
            let sets = try reader.uint16()
            for _ in 0..<sets {
                try reader.skip(4)
                try reader.skip(4 * reader.uint32())
                let elements = try reader.uint16()
                for _ in 0..<elements {
                    try reader.skip(4)
                    let joints = try reader.uint16()
                    for _ in 0..<joints {
                        try reader.skip(16)
                        try reader.skip(4 * reader.uint16())
                    }
                }
            }
            guard try reader.flag() else { return nil }
            let boxes = try names.enumerated().map { index, name in
                let half = try SIMD3<Float>(reader.float(), reader.float(), reader.float())
                guard half.x >= 0, half.y >= 0, half.z >= 0 else { throw SkeletonTail.Invalid.data }
                let transform = try simd_float4x4(columns: (reader.column(), reader.column(), reader.column(), reader.column()))
                return Box(name: name.isEmpty ? String(index) : name, halfSize: half, transform: transform)
            }
            guard try reader.flag() else { return nil }
            let order = try names.map { _ in try reader.uint32() }
            guard order.allSatisfy(boxes.indices.contains) else { return nil }
            if version >= 3, try reader.flag() { try reader.skip(4 * names.count) }
            guard reader.atEnd else { return nil }
            return PuppetHitBoxes(boxes: boxes, order: order)
        } catch {
            return nil
        }
    }

    private struct SkeletonTail {
        enum Invalid: Error { case data }
        private var bytes: ArraySlice<UInt8>
        var atEnd: Bool { bytes.isEmpty }
        init(_ bytes: ArraySlice<UInt8>) { self.bytes = bytes }

        mutating func skip(_ length: Int) throws {
            guard length >= 0, length <= bytes.count else { throw Invalid.data }
            bytes = bytes.dropFirst(length)
        }

        mutating func skipString() throws {
            guard let end = bytes.firstIndex(of: 0) else { throw Invalid.data }
            bytes = bytes[(end + 1)...]
        }

        mutating func flag() throws -> Bool {
            guard let value = bytes.popFirst(), value <= 1 else { throw Invalid.data }
            return value != 0
        }

        mutating func uint16() throws -> Int {
            guard bytes.count >= 2 else { throw Invalid.data }
            let i = bytes.startIndex
            let n = Int(bytes[i]) | Int(bytes[i + 1]) << 8
            bytes = bytes.dropFirst(2)
            return n
        }

        mutating func uint32() throws -> Int {
            let low = try uint16(), high = try uint16()
            return low | high << 16
        }

        mutating func float() throws -> Float {
            let value = try Float(bitPattern: UInt32(uint32()))
            guard value.isFinite else { throw Invalid.data }
            return value
        }

        mutating func column() throws -> SIMD4<Float> {
            try SIMD4(float(), float(), float(), float())
        }
    }
}
