import Foundation
import simd

struct SceneModelHit {
    let id: Int
    let local: SIMD3<Float>
    let world: SIMD3<Float>
    let depth: Float
}

/// The camera ray for a point on the presented wallpaper, in world coordinates.
struct ScenePickRay {
    let origin: SIMD3<Double>
    let direction: SIMD3<Double>
    let cameraForward: SIMD3<Double>

    init?(screen: CGPoint, uvScale: SIMD2<Float>, uvOffset: SIMD2<Float>,
          ndcScale: SIMD2<Float>, viewProjection: simd_float4x4, allowOutsideImage: Bool = false) {
        let uv = (SIMD2(Float(screen.x), Float(screen.y)) - 0.5) * uvScale + 0.5 + uvOffset
        if !allowOutsideImage {
            guard (0...1).contains(screen.x), (0...1).contains(screen.y),
                  (0...1).contains(uv.x), (0...1).contains(uv.y) else { return nil }
        }
        let x = Double((2 * uv.x - 1) / ndcScale.x)
        let y = Double((1 - 2 * uv.y) / ndcScale.y)
        let inverse = simd_double4x4(viewProjection).inverse
        let mid = inverse * SIMD4(x, y, 0.5, 1)
        let eye = inverse * SIMD4(0, 0, 1, 0)
        guard mid.w > 0, eye.w != 0 else { return nil }
        origin = eye.xyz / eye.w
        let delta = mid.xyz / mid.w - origin
        let length = simd_length(delta)
        guard length > 0, length.isFinite else { return nil }
        direction = delta / length
        // For a perspective projection, clip w gives signed depth along the view axis.
        cameraForward = SIMD3(Double(viewProjection.columns.0.w),
                              Double(viewProjection.columns.1.w),
                              Double(viewProjection.columns.2.w))
    }
}

/// Model cursor events use the union of the exported mesh bounds in the object's
/// local frame. It stays fixed as an animation or skin deforms the vertices.
struct SceneModelBounds {
    var min: SIMD3<Float>
    var max: SIMD3<Float>

    private var center: SIMD3<Double> { (SIMD3<Double>(min) + SIMD3<Double>(max)) / 2 }

    mutating func include(_ box: SceneModelBounds) {
        min = simd_min(min, box.min)
        max = simd_max(max, box.max)
    }

    func hit(id: Int, world: simd_float4x4, depth: Float, ray: ScenePickRay) -> SceneModelHit? {
        guard max.x > min.x, max.y >= min.y, max.z >= min.z else { return nil }
        let inverse = simd_double4x4(world).inverse
        let o = (inverse * SIMD4(ray.origin, 1)).xyz
        // Keeping this unnormalised preserves the world ray's distance parameter.
        let d = (inverse * SIMD4(ray.direction, 0)).xyz
        guard simd_length_squared(o).isFinite, simd_length_squared(d).isFinite else { return nil }

        var enter = -Double.infinity, exit = Double.infinity
        for axis in 0..<3 {
            let lo = Double(min[axis]), hi = Double(max[axis])
            if d[axis] == 0 {
                // A parallel ray on a face is not an entering intersection.
                if o[axis] <= lo || o[axis] >= hi { return nil }
            } else {
                let a = (lo - o[axis]) / d[axis], b = (hi - o[axis]) / d[axis]
                enter = Swift.max(enter, Swift.min(a, b))
                exit = Swift.min(exit, Swift.max(a, b))
                if enter > exit { return nil }
            }
        }
        guard enter.isFinite else { return nil }
        let local = SIMD3<Float>(o + enter * d - center)
        let position = SIMD3<Float>(ray.origin + enter * ray.direction)
        return SceneModelHit(id: id, local: local, world: position, depth: depth)
    }

    /// Outside the box, continue dragging on a view-facing plane through the last
    /// local contact. Keeping that anchor in model space follows transforms between events.
    func projectCapture(id: Int, world: simd_float4x4, depth: Float, ray: ScenePickRay,
                        previousLocal: SIMD3<Float>) -> SceneModelHit? {
        let transform = simd_double4x4(world)
        let anchor = (transform * SIMD4(SIMD3<Double>(previousLocal) + center, 1)).xyz
        let denominator = simd_dot(ray.direction, ray.cameraForward)
        guard abs(denominator) > Double.ulpOfOne else { return nil }
        let distance = simd_dot(anchor - ray.origin, ray.cameraForward) / denominator
        let position = ray.origin + ray.direction * distance
        let local = (transform.inverse * SIMD4(position, 1)).xyz - center
        let localPoint = SIMD3<Float>(local), worldPoint = SIMD3<Float>(position)
        guard simd_length_squared(localPoint).isFinite, simd_length_squared(worldPoint).isFinite else { return nil }
        return SceneModelHit(id: id, local: localPoint, world: worldPoint, depth: depth)
    }
}

private extension simd_double4x4 {
    init(_ m: simd_float4x4) {
        self.init(columns: (SIMD4<Double>(m.columns.0), SIMD4<Double>(m.columns.1),
                            SIMD4<Double>(m.columns.2), SIMD4<Double>(m.columns.3)))
    }
}

private extension SIMD4 where Scalar == Double {
    var xyz: SIMD3<Double> { SIMD3(x, y, z) }
}
