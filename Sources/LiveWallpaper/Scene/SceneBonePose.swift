import Foundation
import simd

/// Per-instance pose of an authored 2D puppet. All state is owned by the scene render thread.
final class SceneBonePose {
    struct Bone {
        let name: String
        let parent: Int
        let bind: simd_float4x4
        let physics: Physics

        init(name: String, parent: Int, bind: simd_float4x4, physics: Physics = .init()) {
            self.name = name; self.parent = parent; self.bind = bind; self.physics = physics
        }
    }

    struct Physics {
        let translation: Bool
        let rotation: Bool
        let mass: Float
        let stiffness: Float
        let damping: Float
        let angularStiffness: Float
        let angularDamping: Float
        let travelLimit: Float?

        init(_ metadata: [String: Any] = [:]) {
            func scalar(_ key: String, _ fallback: Float, _ range: ClosedRange<Float>) -> Float {
                guard let n = (metadata[key] as? NSNumber)?.floatValue, n.isFinite else { return fallback }
                return min(range.upperBound, max(range.lowerBound, n))
            }
            let springEnabled = metadata["se"] as? Bool != false
            translation = springEnabled && metadata["t"] as? Bool == true
            rotation = springEnabled && metadata["r"] as? Bool == true && metadata["raz"] as? Bool != false
            mass = scalar("m", 1, 0.01...10000)
            stiffness = scalar("ts", 80, 0...10000)
            damping = scalar("tf", 8, 0...1000)
            angularStiffness = scalar("rs", 80, 0...10000)
            angularDamping = scalar("rf", 8, 0...1000)
            travelLimit = metadata["lt"] as? Bool == true ? scalar("ltmax", 100, 0...100000) : nil
        }
    }

    private struct Motion {
        var delta: SIMD3<Float> = .zero
        var velocity: SIMD3<Float> = .zero
        var angle: Float = 0
        var spin: Float = 0
    }

    let bones: [Bone]
    private let names: [String: Int]
    private var base: [simd_float4x4]
    private var overrides = [Int: simd_float4x4]()
    private var motion = [Int: Motion]()
    var layerToScene = matrix_identity_float4x4
    private(set) var world: [simd_float4x4]
    private var bindUploadsRemaining = 0
    var hasDeformation: Bool { !overrides.isEmpty || !motion.isEmpty || bindUploadsRemaining > 0 }

    init(bones: [Bone]) {
        self.bones = bones
        names = Dictionary(bones.enumerated().filter { !$0.element.name.isEmpty }.map { ($0.element.name, $0.offset) },
                           uniquingKeysWith: { first, _ in first })
        base = bones.map(\.bind)
        world = base
        rebuild()
    }

    func index(name: String) -> Int { names[name] ?? -1 }

    private func parentWorld(_ i: Int) -> simd_float4x4 {
        let p = bones[i].parent
        return p >= 0 && p < i ? world[p] : matrix_identity_float4x4
    }

    private func local(_ i: Int) -> simd_float4x4 {
        var m = overrides[i] ?? base[i]
        if let v = motion[i] {
            let t = m.columns.3
            if v.angle != 0 { m *= simd_float4x4(simd_quatf(angle: v.angle, axis: SIMD3(0, 0, 1))) }
            m.columns.3 = t + SIMD4(v.delta, 0)
        }
        return m
    }

    private func rebuild() {
        for i in bones.indices { world[i] = parentWorld(i) * local(i) }
    }

    func transform(_ i: Int, inScene: Bool) -> simd_float4x4? {
        guard bones.indices.contains(i) else { return nil }
        return inScene ? layerToScene * world[i] : local(i)
    }

    func setTransform(_ matrix: simd_float4x4, _ i: Int, inScene: Bool) {
        guard bones.indices.contains(i), matrix.isFiniteAffine else { return }
        let parent = layerToScene * parentWorld(i)
        guard !inScene || abs(parent.determinant) > 1e-7 else { return }
        var next = inScene ? parent.inverse * matrix : matrix
        guard next.isFiniteAffine else { return }
        let def = bones[i]
        if def.physics.translation {
            var v = motion[i] ?? Motion()
            v.delta = next.columns.3.xyz - base[i].columns.3.xyz
            v.velocity = .zero
            next.columns.3 = base[i].columns.3
            motion[i] = v
        }
        // The supplied matrix already includes this frame’s angular displacement.
        // Store the underlying pose so rotating and writing a translation does not apply it twice.
        if let v = motion[i], v.angle != 0 {
            next *= simd_float4x4(simd_quatf(angle: -v.angle, axis: SIMD3(0, 0, 1)))
        }
        if simd_almost_equal_elements(next, base[i], 1e-4) { overrides.removeValue(forKey: i) }
        else { overrides[i] = next }
        bindUploadsRemaining = 4
        rebuild()
    }

    /// WE impulses are specified in scene axes. Convert vectors without translating them.
    func impulse(_ i: Int, direction: SIMD3<Float>, angular: SIMD3<Float>) {
        guard bones.indices.contains(i), direction.allFinite, angular.allFinite else { return }
        let p = bones[i].physics
        guard p.translation || p.rotation else { return }
        let parent = layerToScene * parentWorld(i)
        guard abs(parent.determinant) > 1e-7 else { return }
        var v = motion[i] ?? Motion()
        if p.translation { v.velocity += (parent.inverse * SIMD4(direction, 0)).xyz / p.mass }
        if p.rotation { v.spin += angular.z / p.mass }
        motion[i] = v
    }

    func reset(_ i: Int?) {
        if let i {
            guard bones.indices.contains(i) else { return }
            motion.removeValue(forKey: i); overrides.removeValue(forKey: i)
        } else {
            motion.removeAll(); overrides.removeAll()
        }
        bindUploadsRemaining = 4
        rebuild()
    }

    func advance(frameTime: Double, animatedLocal: [simd_float4x4]?) {
        if let animatedLocal, animatedLocal.count == bones.count { base = animatedLocal }
        // Fixed maximum step and a bounded catch-up decouple damping from display refresh and sleep.
        var remaining = Float(min(0.1, max(0, frameTime)))
        while remaining > 0 && !motion.isEmpty {
            let dt = min(remaining, 1 / Float(240))
            for i in Array(motion.keys) {
                guard var v = motion[i] else { continue }
                let p = bones[i].physics
                // Backward Euler remains stable for very light or stiff authored bones.
                let k = p.stiffness / p.mass, ak = p.angularStiffness / p.mass
                v.velocity = (v.velocity - v.delta * (dt * k)) / (1 + dt * p.damping + dt * dt * k)
                v.delta += v.velocity * dt
                v.spin = (v.spin - v.angle * dt * ak) / (1 + dt * p.angularDamping + dt * dt * ak)
                v.angle += v.spin * dt
                if let limit = p.travelLimit, simd_length(v.delta) > limit { v.delta = simd_normalize(v.delta) * limit }
                if !v.delta.allFinite || !v.velocity.allFinite || !v.angle.isFinite || !v.spin.isFinite ||
                    (simd_length_squared(v.delta) + simd_length_squared(v.velocity) < 1e-6 && abs(v.angle) + abs(v.spin) < 1e-5) {
                    motion.removeValue(forKey: i); bindUploadsRemaining = 4
                } else { motion[i] = v }
            }
            remaining -= dt
        }
        rebuild()
    }

    func didUpload() { if overrides.isEmpty && motion.isEmpty { bindUploadsRemaining = max(0, bindUploadsRemaining - 1) } }
}

private extension SIMD4 where Scalar == Float {
    var xyz: SIMD3<Float> { SIMD3(x, y, z) }
}
private extension SIMD3 where Scalar == Float {
    var allFinite: Bool { x.isFinite && y.isFinite && z.isFinite }
}
extension simd_float4x4 {
    var isFiniteAffine: Bool {
        for c in 0..<4 {
            for r in 0..<4 where !self[c][r].isFinite { return false }
        }
        return abs(columns.0.w) < 1e-5 && abs(columns.1.w) < 1e-5 && abs(columns.2.w) < 1e-5 && abs(columns.3.w - 1) < 1e-5
    }
    var columnMajor: [Float] { (0..<4).flatMap { c in (0..<4).map { self[c][$0] } } }
    init?(columns values: [Float]) {
        guard values.count == 16 else { return nil }
        self = matrix_identity_float4x4
        for c in 0..<4 { for r in 0..<4 { self[c][r] = values[c * 4 + r] } }
        guard isFiniteAffine else { return nil }
    }
}
