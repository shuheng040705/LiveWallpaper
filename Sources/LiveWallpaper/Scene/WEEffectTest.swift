import Metal
import MetalKit
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// 无界面验证转译特效:`--testeffect <effect> <out.png> [time] [param=val ...]`
/// 用程序化网格作输入(便于看 UV 位移),跑 WEEffectChain 的真 WE 着色器,输出 PNG。
enum WEEffectTest {
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let idx = args.firstIndex(of: "--testeffect") else { return false }
        guard idx + 2 < args.count else {
            FileHandle.standardError.write("usage: --testeffect <effect> <out.png> [time] [param=val ...]\n".data(using: .utf8)!)
            exit(1)
        }
        let effect = args[idx + 1]
        let outPath = args[idx + 2]
        let time = (idx + 3 < args.count ? Float(args[idx + 3]) : nil) ?? 2.0
        var params: [String: Any] = [:]
        var combos: [String: Any] = [:]      // combo:K=V → 选变体
        for a in args[(idx + 3)...] where a.contains("=") {
            if a.hasPrefix("combo:") {
                let kv = a.dropFirst(6).split(separator: "=", maxSplits: 1)
                if kv.count == 2 { combos[String(kv[0])] = String(kv[1]) }
            } else {
                let kv = a.split(separator: "=", maxSplits: 1)
                if kv.count == 2 { params[String(kv[0])] = String(kv[1]) }
            }
        }

        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            print("no metal"); exit(1)
        }
        guard let chain = WEEffectChain(device: device) else { print("no chain/manifest"); exit(1) }
        guard chain.has(effect) else {
            print("effect '\(effect)' not in manifest. available: \(chain.availableEffects.sorted().joined(separator: ", "))")
            exit(1)
        }
        var W = 512, H = 512
        let input: MTLTexture
        if let inPath = params["input"] as? String {
            // 用真实 PNG 作输入(MTKTextureLoader,带 mipmap,与引擎图层纹理一致)。
            let loader = MTKTextureLoader(device: device)
            let genMip = (params["mip"] as? String) != "0"
            params.removeValue(forKey: "mip")
            let opts: [MTKTextureLoader.Option: Any] = [.SRGB: false, .generateMipmaps: genMip,
                                                        .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue)]
            input = (try? loader.newTexture(URL: URL(fileURLWithPath: inPath), options: opts)) ?? makeGrid(device: device, w: W, h: H)
            W = input.width; H = input.height
            params.removeValue(forKey: "input")
        } else {
            if let gw = (params["gw"] as? String).flatMap({ Int($0) }) { W = gw }
            if let gh = (params["gh"] as? String).flatMap({ Int($0) }) { H = gh }
            params.removeValue(forKey: "gw"); params.removeValue(forKey: "gh")
            input = makeGrid(device: device, w: W, h: H)
        }
        guard let cmd = queue.makeCommandBuffer() else { exit(1) }
        // 音频反应特效(pulse 等)直测:用 AudioCapture.spectrum16(尊重 WP_TEST_BANDS=loud|silent
        // 注入态),无需真实捕获即可确定性验证音频 uniform → shader 链路。
        let audio = WEEffectChain.AudioSpectrum(s16: AudioCapture.shared.spectrum16,
                                                s32: AudioCapture.shared.spectrum32,
                                                s64: AudioCapture.shared.bands)
        guard let result = chain.run(effect: effect, input: input, pkgParams: params,
                                     combos: combos, auxTextures: [:], time: time,
                                     audio: audio, commandBuffer: cmd) else {
            print("run returned nil"); exit(1)
        }
        // 结果在 .private,需 blit 到 .shared 才能读回。
        let rd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: W, height: H, mipmapped: false)
        rd.usage = [.shaderRead]; rd.storageMode = .shared
        let readable = device.makeTexture(descriptor: rd)!
        if let blit = cmd.makeBlitCommandEncoder() {
            blit.copy(from: result, sourceSlice: 0, sourceLevel: 0,
                      sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                      sourceSize: MTLSize(width: W, height: H, depth: 1),
                      to: readable, destinationSlice: 0, destinationLevel: 0,
                      destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            blit.endEncoding()
        }
        cmd.commit(); cmd.waitUntilCompleted()
        writePNG(readable, w: W, h: H, to: outPath)
        print("WROTE \(outPath) (effect=\(effect) time=\(time) params=\(params))")
        exit(0)
    }

    /// 网格 + 渐变测试图:横竖白线 + RGB 渐变底,UV 位移一眼可见。
    private static func makeGrid(device: MTLDevice, w: Int, h: Int) -> MTLTexture {
        var px = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let o = (y * w + x) * 4
                let grid = (x % 32 < 2 || y % 32 < 2)
                // BGRA
                px[o]   = grid ? 255 : UInt8(255 * y / h)       // B
                px[o+1] = grid ? 255 : UInt8(255 * x / w)       // G
                px[o+2] = grid ? 255 : 128                       // R
                px[o+3] = 255
            }
        }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        d.usage = [.shaderRead]; d.storageMode = .shared
        let t = device.makeTexture(descriptor: d)!
        px.withUnsafeBytes { t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: w * 4) }
        return t
    }

    private static func writePNG(_ tex: MTLTexture, w: Int, h: Int, to path: String) {
        let rb = w * 4
        var raw = [UInt8](repeating: 0, count: rb * h)
        tex.getBytes(&raw, bytesPerRow: rb, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let ctx = CGContext(data: &raw, width: w, height: h, bitsPerComponent: 8, bytesPerRow: rb,
                                  space: cs, bitmapInfo: info.rawValue), let img = ctx.makeImage(),
              let dst = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { print("png fail"); return }
        CGImageDestinationAddImage(dst, img, nil); CGImageDestinationFinalize(dst)
    }
}
