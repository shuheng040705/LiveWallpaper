import simd
import Foundation

/// WE 粒子湍流(turbulence / turbulentvelocityrandom)用的 Perlin + curl 噪声。
/// **逐字移植** 自参考 linux-wallpaperengine 的 `Render/Utils/NoiseUtils.h`
/// (perlinGrad 个别 case 的"怪味"也照抄,保证与 WE 同形、同结果)。
enum WENoise {
    /// 标准 Ken Perlin 256 置换表(下方运行时×2 成 512,供环绕索引)。
    private static let base: [Int] = [
        151, 160, 137, 91, 90, 15, 131, 13, 201, 95, 96, 53, 194, 233, 7, 225,
        140, 36, 103, 30, 69, 142, 8, 99, 37, 240, 21, 10, 23, 190, 6, 148,
        247, 120, 234, 75, 0, 26, 197, 62, 94, 252, 219, 203, 117, 35, 11, 32,
        57, 177, 33, 88, 237, 149, 56, 87, 174, 20, 125, 136, 171, 168, 68, 175,
        74, 165, 71, 134, 139, 48, 27, 166, 77, 146, 158, 231, 83, 111, 229, 122,
        60, 211, 133, 230, 220, 105, 92, 41, 55, 46, 245, 40, 244, 102, 143, 54,
        65, 25, 63, 161, 1, 216, 80, 73, 209, 76, 132, 187, 208, 89, 18, 169,
        200, 196, 135, 130, 116, 188, 159, 86, 164, 100, 109, 198, 173, 186, 3, 64,
        52, 217, 226, 250, 124, 123, 5, 202, 38, 147, 118, 126, 255, 82, 85, 212,
        207, 206, 59, 227, 47, 16, 58, 17, 182, 189, 28, 42, 223, 183, 170, 213,
        119, 248, 152, 2, 44, 154, 163, 70, 221, 153, 101, 155, 167, 43, 172, 9,
        129, 22, 39, 253, 19, 98, 108, 110, 79, 113, 224, 232, 178, 185, 112, 104,
        218, 246, 97, 228, 251, 34, 242, 193, 238, 210, 144, 12, 191, 179, 162, 241,
        81, 51, 145, 235, 249, 14, 239, 107, 49, 192, 214, 31, 181, 199, 106, 157,
        184, 84, 204, 176, 115, 121, 50, 45, 127, 4, 150, 254, 138, 236, 205, 93,
        222, 114, 67, 29, 24, 72, 243, 141, 128, 195, 78, 66, 215, 61, 156, 180
    ]
    static let perm: [Int] = base + base   // 512,索引最大 511(AA+1)

    @inline(__always) static func grad(_ hash: Int, _ x: Double, _ y: Double, _ z: Double) -> Double {
        switch hash & 0xF {
        case 0x0: return x + y;  case 0x1: return -x + y
        case 0x2: return x - y;  case 0x3: return -x - y
        case 0x4: return x + z;  case 0x5: return -x + z
        case 0x6: return x - z;  case 0x7: return -x - z
        case 0x8: return y + z;  case 0x9: return -y + z
        case 0xA: return y - z;  case 0xB: return -y - z
        case 0xC: return y + x;  case 0xD: return -y + z
        case 0xE: return y - x;  default:  return -y - z   // 0xF
        }
    }
    @inline(__always) static func ease(_ t: Double) -> Double { t*t*t*(t*(t*6 - 15) + 10) }
    @inline(__always) static func lerp(_ t: Double, _ a: Double, _ b: Double) -> Double { a + t*(b-a) }

    static func perlin(_ px: Double, _ py: Double, _ pz: Double) -> Double {
        let X = Int(floor(px)) & 255, Y = Int(floor(py)) & 255, Z = Int(floor(pz)) & 255
        let x = px - floor(px), y = py - floor(py), z = pz - floor(pz)
        let u = ease(x), v = ease(y), w = ease(z)
        let A = perm[X] + Y, AA = perm[A] + Z, AB = perm[A+1] + Z
        let B = perm[X+1] + Y, BA = perm[B] + Z, BB = perm[B+1] + Z
        return lerp(w,
            lerp(v, lerp(u, grad(perm[AA], x, y, z),     grad(perm[BA], x-1, y, z)),
                    lerp(u, grad(perm[AB], x, y-1, z),   grad(perm[BB], x-1, y-1, z))),
            lerp(v, lerp(u, grad(perm[AA+1], x, y, z-1), grad(perm[BA+1], x-1, y, z-1)),
                    lerp(u, grad(perm[AB+1], x, y-1, z-1), grad(perm[BB+1], x-1, y-1, z-1))))
    }
    static func perlinVec3(_ p: SIMD3<Float>) -> SIMD3<Float> {
        let x = Double(p.x), y = Double(p.y), z = Double(p.z)
        return SIMD3(Float(perlin(x, y, z)),
                     Float(perlin(x+89.2, y+33.1, z+57.3)),
                     Float(perlin(x+100.3, y+120.1, z+142.2)))
    }
    /// curl(perlinVec3):有限差分旋度 → 平滑卷曲的流体式运动场。
    static func curl(_ p: SIMD3<Float>) -> SIMD3<Float> {
        let e: Float = 1e-4
        let x0 = perlinVec3(p - SIMD3(e,0,0)), x1 = perlinVec3(p + SIMD3(e,0,0))
        let y0 = perlinVec3(p - SIMD3(0,e,0)), y1 = perlinVec3(p + SIMD3(0,e,0))
        let z0 = perlinVec3(p - SIMD3(0,0,e)), z1 = perlinVec3(p + SIMD3(0,0,e))
        return SIMD3((y1.z - y0.z) - (z1.y - z0.y),
                     (z1.x - z0.x) - (x1.z - x0.z),
                     (x1.y - x0.y) - (y1.x - y0.x)) / (2*e)
    }
}
