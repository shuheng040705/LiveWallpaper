import Foundation
import simd
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// 无界面渲染:给定壁纸 id,把 scene 渲染成 PNG。用于开发期肉眼验证坐标/混合/排序。
/// 用法: LiveWallpaper --render <workshopId> <out.png> [maxLongSide]
enum SceneHeadless {

    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        if args.contains("--perf") { return runPerf(args: args) }
        if args.contains("--ropetest") { return runRopeTest(args: args) }
        if args.contains("--motion") { return runMotion(args: args) }
        if args.contains("--warmrender") { return runWarm(args: args) }
        if args.contains("--dumpparts") { return runDumpParts(args: args) }
        if args.contains("--dumptex") { return runDumpTex(args: args) }
        if args.contains("--audiodump") { return runAudioDump(args: args) }
        guard let idx = args.firstIndex(of: "--render") else { return false }
        guard idx + 2 < args.count else {
            FileHandle.standardError.write("usage: --render <workshopId> <out.png> [maxLongSide]\n".data(using: .utf8)!)
            exit(2)
        }
        let id = args[idx + 1]
        let outPath = args[idx + 2]
        let maxLong = (idx + 3 < args.count) ? Int(args[idx + 3]) : nil

        let root = PreferencesStore.shared.libraryRoot
        let folder = root.appendingPathComponent(id)

        guard let project = try? Data(contentsOf: folder.appendingPathComponent("project.json")),
              let json = try? JSONSerialization.jsonObject(with: project) as? [String: Any] else {
            err("no project.json in \(folder.path)"); exit(1)
        }
        let item = WallpaperItem(
            id: id, folderURL: folder,
            title: json["title"] as? String ?? id,
            type: WallpaperType(raw: json["type"] as? String),
            fileName: json["file"] as? String,
            previewName: json["preview"] as? String,
            tags: []
        )

        guard let source = SceneSourceFactory.make(for: item) else { err("cannot open scene source"); exit(1) }
        print("paths in source: \(source.allPaths.count)")
        guard let doc = SceneDocument.build(from: source, item: item) else { err("cannot parse scene.json"); exit(1) }
        print("canvas \(doc.canvasWidth)x\(doc.canvasHeight), layers(image): \(doc.layers.count)")
        for (i, l) in doc.layers.enumerated() {
            let fx = l.effects.isEmpty ? "" : " effects=[" + l.effects.map { "\($0.kind)" }.joined(separator: ",") + "]"
            print(String(format: "  layer[%d] id=%d vis=%@ tex=%@ origin=(%.0f,%.0f) size=%@ blend=%@ name=%@%@",
                         i, l.id, l.visible ? "Y" : "N", l.texturePath ?? "nil",
                         l.originPx.x, l.originPx.y,
                         l.sizePx.map { "\(Int($0.x))x\(Int($0.y))" } ?? "auto",
                         l.blend.rawValue, l.name, fx))
        }

        guard let engine = SceneRenderEngine() else { err("no Metal device"); exit(1) }
        engine.load(document: doc, source: source)
        print("gpu layers: \(engine.layerCount), parallax: \(engine.hasParallax)")
        // 渲染缺口直接打到 stdout。引擎内部只经 Log.write 记录,而 Log 是**异步队列写文件**,
        // headless 渲完立刻 exit → 日志往往还没落盘就丢了(且 Log.reset 还会清掉正在运行的 app 的日志),
        // 所以做全库渲染审计时拿不到。这里同步打印一份,便于批量收割「引擎自报渲不出的项」。
        if !engine.renderGaps.isEmpty {
            print("ENGINEGAPS(\(engine.renderGaps.count)): " + engine.renderGaps.joined(separator: " | "))
        } else {
            print("ENGINEGAPS(0)")
        }
        // 可选第 4 参 = 模拟时间(秒)。推进:应用视差 + 步进/上传粒子实例。否则离屏帧不含粒子/视差。
        let simTime = (idx + 4 < args.count) ? Double(args[idx + 4]) : nil
        // 视差复现:WP_MOUSE_X/Y(屏幕归一化 [-1,1])让离屏帧能重现实时鼠标位置下的逐层视差分离。
        // 视差有平滑(delay),需多帧暖机让 displacement 收敛到目标。
        let env = WPEnv.vars
        let mx = Float(env["WP_MOUSE_X"] ?? "0") ?? 0
        let my = Float(env["WP_MOUSE_Y"] ?? "0") ?? 0
        let warm = Int(env["WP_WARMUP"] ?? "0") ?? 0
        if warm > 0 {
            let dt = 1.0 / 60.0
            for i in 0..<warm { engine.update(time: (simTime ?? 0) + Double(i) * dt, mouseNorm: SIMD2<Float>(mx, my)) }
        } else if mx != 0 || my != 0 {
            let dt = 1.0 / 60.0
            for i in 0..<120 { engine.update(time: (simTime ?? 0) + Double(i) * dt, mouseNorm: SIMD2<Float>(mx, my)) }
        } else {
            engine.update(time: simTime ?? 0, mouseNorm: SIMD2<Float>(0, 0))
        }
        print("particles: \(engine.particleDiagnostics)")
        if let simTime { print("simulated time: \(simTime)s") }

        var w = Int(doc.canvasWidth), h = Int(doc.canvasHeight)
        // 第3参支持 "WxH"(显式目标尺寸,用于复现屏幕宽高比不匹配),或单值 maxLong(等比缩放)。
        if idx + 3 < args.count, args[idx + 3].contains("x") {
            let parts = args[idx + 3].split(separator: "x").compactMap { Int($0) }
            if parts.count == 2 { w = parts[0]; h = parts[1] }
        } else if let maxLong, max(w, h) > maxLong {
            let s = Double(maxLong) / Double(max(w, h))
            w = Int(Double(w) * s); h = Int(Double(h) * s)
        }
        let ok = engine.renderToPNG(width: w, height: h, outURL: URL(fileURLWithPath: outPath))
        print(ok ? "WROTE \(outPath) (\(w)x\(h))" : "RENDER FAILED")
        exit(ok ? 0 : 1)
    }

    private static func err(_ s: String) {
        FileHandle.standardError.write(("ERROR: " + s + "\n").data(using: .utf8)!)
    }

    /// 调试:把每个图层的解码贴图导出为 PNG + parts.json(origin/scale/size/cropOffset),
    /// 供 Python 离线拼装、反推 cropoffset 公式。用法: --dumpparts <id> <outdir>
    private static func runDumpParts(args: [String]) -> Bool {
        guard let idx = args.firstIndex(of: "--dumpparts"), idx + 2 < args.count else {
            err("usage: --dumpparts <id> <outdir>"); exit(2)
        }
        let id = args[idx + 1]
        let outDir = args[idx + 2]
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        let root = PreferencesStore.shared.libraryRoot
        let folder = root.appendingPathComponent(id)
        guard let project = try? Data(contentsOf: folder.appendingPathComponent("project.json")),
              let json = try? JSONSerialization.jsonObject(with: project) as? [String: Any] else {
            err("no project.json"); exit(1)
        }
        let item = WallpaperItem(id: id, folderURL: folder, title: json["title"] as? String ?? id,
                                 type: WallpaperType(raw: json["type"] as? String),
                                 fileName: json["file"] as? String,
                                 previewName: json["preview"] as? String, tags: [])
        guard let source = SceneSourceFactory.make(for: item),
              let doc = SceneDocument.build(from: source, item: item) else { err("cannot open scene"); exit(1) }
        print("canvas \(doc.canvasWidth)x\(doc.canvasHeight), layers \(doc.layers.count)")
        var meta: [[String: Any]] = []
        for (i, l) in doc.layers.enumerated() {
            var pngName = ""
            var texW = 0, texH = 0
            if let tp = l.texturePath, let blob = source.data(for: tp),
               case .rgba8(let px, let w, let h)? = TexDecoder.decodeFirstMipWithFlags(blob)?.tex {
                texW = w; texH = h
                pngName = String(format: "p%02d.png", i)
                writeRGBA8PNG(px, width: w, height: h, to: outDir + "/" + pngName)
            }
            meta.append([
                "i": i, "id": l.id, "name": l.name, "png": pngName,
                "origin": [l.originPx.x, l.originPx.y],
                "scale": [l.scale.x, l.scale.y],
                "size": l.sizePx.map { [$0.x, $0.y] } ?? [Float(texW), Float(texH)],
                "cropOffset": [l.cropOffset.x, l.cropOffset.y],
                "angleZ": l.anglesDeg.z, "texW": texW, "texH": texH, "visible": l.visible,
            ])
        }
        let jsonData = try! JSONSerialization.data(withJSONObject: ["canvasW": doc.canvasWidth, "canvasH": doc.canvasHeight, "parts": meta], options: [.prettyPrinted])
        try! jsonData.write(to: URL(fileURLWithPath: outDir + "/parts.json"))
        print("WROTE \(meta.count) parts → \(outDir)")
        exit(0)
    }

    /// 调试:解码 pkg 内任意 .tex 为 PNG(看遮罩/贴图形状)。用法: --dumptex <id> <texpath> <out.png>
    private static func runDumpTex(args: [String]) -> Bool {
        guard let idx = args.firstIndex(of: "--dumptex"), idx + 3 < args.count else {
            err("usage: --dumptex <id> <texpath> <out.png>"); exit(2)
        }
        let id = args[idx + 1], texpath = args[idx + 2], out = args[idx + 3]
        let root = PreferencesStore.shared.libraryRoot
        let folder = root.appendingPathComponent(id)
        let item = WallpaperItem(id: id, folderURL: folder, title: id, type: .scene,
                                 fileName: nil, previewName: nil, tags: [])
        guard let source = SceneSourceFactory.make(for: item) else { err("no source"); exit(1) }
        guard let blob = source.data(for: texpath) else { err("no tex \(texpath)"); exit(1) }
        guard let dec = TexDecoder.decodeFirstMipWithFlags(blob)?.tex else { err("decode nil"); exit(1) }
        switch dec {
        case .rgba8(let px, let w, let h):
            writeRGBA8PNG(px, width: w, height: h, to: out)
            print("WROTE rgba8 \(w)x\(h) → \(out)")
        case .encoded(let data):
            // 内嵌图片(PNG/JPG)→ 直接写字节(扩展名按实际)。
            try? data.write(to: URL(fileURLWithPath: out))
            print("WROTE encoded \(data.count) bytes → \(out)")
        default:
            err("tex is video/other"); exit(1)
        }
        exit(0)
    }

    /// 直接 RGBA8 像素 → PNG(非预乘,保留直通 alpha,供离线拼装)。
    private static func writeRGBA8PNG(_ pixels: [UInt8], width: Int, height: Int, to path: String) {
        guard width > 0, height > 0, pixels.count >= width * height * 4 else { return }
        // 预乘 alpha(CGContext 不支持非预乘 .last;预乘后颜色在 PIL 里拼装看位置足够准)。
        var px = pixels
        var i = 0
        while i + 3 < px.count {
            let a = Int(px[i+3])
            px[i]   = UInt8(Int(px[i])   * a / 255)
            px[i+1] = UInt8(Int(px[i+1]) * a / 255)
            px[i+2] = UInt8(Int(px[i+2]) * a / 255)
            i += 4
        }
        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)   // RGBA 预乘
        guard let ctx = CGContext(data: &px, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4, space: cs, bitmapInfo: info.rawValue),
              let cg = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                         UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, cg, nil)
        CGImageDestinationFinalize(dest)
    }

    /// 性能 profile:--perf <id> [frames] [WxH] —— 跑 N 帧(默认 180)真实 update+encodeFrame+GPU 执行,
    /// 配合 WP_PERF 分项计时(每 60 帧打印 skin/part/other/enc 均值)。渲染分辨率默认 3840×2160(模拟内屏);
    /// 可传 WxH。模拟实时:复用同 inter/target 纹理跨帧。用于定位 scene 壁纸 CPU 大头。
    private static func runPerf(args: [String]) -> Bool {
        guard let idx = args.firstIndex(of: "--perf"), idx + 1 < args.count else {
            err("usage: --perf <id> [frames] [WxH]  (设 WP_PERF=1;默认 180 帧 @ 3840x2160)"); exit(2)
        }
        let id = args[idx + 1]
        let frames = (idx + 2 < args.count) ? (Int(args[idx + 2]) ?? 180) : 180
        var outW = 3840, outH = 2160
        if idx + 3 < args.count, args[idx + 3].contains("x") {
            let p = args[idx + 3].split(separator: "x").compactMap { Int($0) }
            if p.count == 2 { outW = p[0]; outH = p[1] }
        }
        let root = PreferencesStore.shared.libraryRoot
        let folder = root.appendingPathComponent(id)
        guard let project = try? Data(contentsOf: folder.appendingPathComponent("project.json")),
              let json = try? JSONSerialization.jsonObject(with: project) as? [String: Any] else {
            err("no project.json in \(folder.path)"); exit(1)
        }
        let item = WallpaperItem(id: id, folderURL: folder, title: json["title"] as? String ?? id,
                                 type: WallpaperType(raw: json["type"] as? String),
                                 fileName: json["file"] as? String,
                                 previewName: json["preview"] as? String, tags: [])
        guard let source = SceneSourceFactory.make(for: item),
              let doc = SceneDocument.build(from: source, item: item),
              let engine = SceneRenderEngine() else { err("cannot open scene"); exit(1) }
        engine.load(document: doc, source: source)
        err("PERF id=\(id) frames=\(frames) out=\(outW)x\(outH) WP_PERF=\(engine.perfOn ? "on" : "OFF(set WP_PERF=1)")")
        let ok = engine.renderFramesToPNG(width: outW, height: outH, frames: frames, dt: 1.0/30.0,
                                          outURL: URL(fileURLWithPath: "/tmp/perf_\(id).png"))
        err(ok ? "PERF done → /tmp/perf_\(id).png" : "PERF render failed")
        exit(ok ? 0 : 1)
    }

    /// rope 验证:--ropetest <id> <out.png> [frames] [longSide]
    /// 跑 N 帧并让光标沿斜向 + 正弦曲线扫过画布(rope 需移动光标才连成链),渲染末帧 + 打印 rope 诊断。
    private static func runRopeTest(args: [String]) -> Bool {
        guard let idx = args.firstIndex(of: "--ropetest"), idx + 2 < args.count else {
            err("usage: --ropetest <id> <out.png> [frames] [longSide]"); exit(2)
        }
        let id = args[idx + 1], outPath = args[idx + 2]
        let frames = (idx + 3 < args.count) ? (Int(args[idx + 3]) ?? 90) : 90
        let longSide = (idx + 4 < args.count) ? (Int(args[idx + 4]) ?? 1600) : 1600
        let root = PreferencesStore.shared.libraryRoot
        let folder = root.appendingPathComponent(id)
        guard let project = try? Data(contentsOf: folder.appendingPathComponent("project.json")),
              let json = try? JSONSerialization.jsonObject(with: project) as? [String: Any] else {
            err("no project.json in \(folder.path)"); exit(1)
        }
        let item = WallpaperItem(id: id, folderURL: folder, title: json["title"] as? String ?? id,
                                 type: WallpaperType(raw: json["type"] as? String),
                                 fileName: json["file"] as? String,
                                 previewName: json["preview"] as? String, tags: [])
        guard let source = SceneSourceFactory.make(for: item),
              let doc = SceneDocument.build(from: source, item: item),
              let engine = SceneRenderEngine() else { err("cannot open scene"); exit(1) }
        engine.load(document: doc, source: source)
        // 光标扫掠:x 从 -0.6→0.6 线性,y 走 1.5 周期正弦(给绳一段弧),驱动拖尾链积累。
        let dt = 1.0 / 60.0
        for i in 0..<max(2, frames) {
            let t = Double(i) * dt
            let phase = Float(i) / Float(max(1, frames - 1))
            let mx = -0.6 + 1.2 * phase
            let my = 0.3 * sin(phase * 6.2831853 * 1.5)
            engine.update(time: t, mouseNorm: SIMD2<Float>(mx, my))
        }
        var w = Int(doc.canvasWidth), h = Int(doc.canvasHeight)
        if max(w, h) > longSide { let s = Double(longSide)/Double(max(w,h)); w = Int(Double(w)*s); h = Int(Double(h)*s) }
        let ok = engine.renderToPNG(width: w, height: h, outURL: URL(fileURLWithPath: outPath))
        print("rope diag after \(frames) cursor-sweep frames:\n\(engine.particleDiagnostics)")
        print(ok ? "WROTE \(outPath) (\(w)x\(h))" : "RENDER FAILED")
        exit(ok ? 0 : 1)
    }

    /// 音频采集诊断:--audiodump <秒> —— 采集 N 秒系统音频,打印频谱峰值/各段,实测采集→FFT 电平。
    /// 用法:先播放响亮音频,再跑 `LiveWallpaper --audiodump 6`。不依赖显示器/壁纸窗口。
    private static func runAudioDump(args: [String]) -> Bool {
        let idx = args.firstIndex(of: "--audiodump")!
        let secs = (idx + 1 < args.count) ? (Double(args[idx + 1]) ?? 5) : 5
        err("audiodump: 采集 \(secs)s 系统音频 —— 现在请播放响亮音频 …")
        AudioCapture.shared.acquire()
        let start = Date()
        var maxBands = [Float](repeating: 0, count: 64)
        var samples = 0
        while Date().timeIntervalSince(start) < secs {
            let b = AudioCapture.shared.bands
            for i in 0..<min(64, b.count) { maxBands[i] = max(maxBands[i], b[i]) }
            if (b.max() ?? 0) > 0.001 { samples += 1 }
            Thread.sleep(forTimeInterval: 0.05)
        }
        let peak = maxBands.max() ?? 0
        let avg = maxBands.reduce(0, +) / 64
        let cur64 = AudioCapture.shared.bands
        let cur16 = AudioCapture.shared.spectrum16
        print("=== audiodump \(secs)s ===")
        print(String(format: "64段 峰值(时间最大)=%.3f  均值=%.3f  非零帧=%d", peak, avg, samples))
        print("逐段峰值64: " + maxBands.map { String(format: "%.2f", $0) }.joined(separator: " "))
        print("当前16段: " + cur16.map { String(format: "%.2f", $0) }.joined(separator: " "))
        print("当前64段: " + cur64.map { String(format: "%.2f", $0) }.joined(separator: " "))
        return true
    }

    /// 多帧暖机渲染:--warmrender <id> <out.png> <N帧> [longSide]
    /// 复用同一 target + 纹理池跑 N 帧,只存最后一帧 —— 复现实时才出现的 GPU 残留/累积 bug。
    private static func runWarm(args: [String]) -> Bool {
        guard let idx = args.firstIndex(of: "--warmrender"), idx + 3 < args.count else {
            err("usage: --warmrender <id> <out.png> <N> [longSide]"); exit(2)
        }
        let id = args[idx + 1], outPath = args[idx + 2]
        let n = Int(args[idx + 3]) ?? 120
        let longSide = (idx + 4 < args.count) ? (Int(args[idx + 4]) ?? 1600) : 1600
        let root = PreferencesStore.shared.libraryRoot
        let folder = root.appendingPathComponent(id)
        guard let project = try? Data(contentsOf: folder.appendingPathComponent("project.json")),
              let json = try? JSONSerialization.jsonObject(with: project) as? [String: Any] else {
            err("no project.json in \(folder.path)"); exit(1)
        }
        let item = WallpaperItem(id: id, folderURL: folder, title: json["title"] as? String ?? id,
                                 type: WallpaperType(raw: json["type"] as? String),
                                 fileName: json["file"] as? String,
                                 previewName: json["preview"] as? String, tags: [])
        guard let source = SceneSourceFactory.make(for: item),
              let doc = SceneDocument.build(from: source, item: item),
              let engine = SceneRenderEngine() else { err("cannot open scene"); exit(1) }
        engine.load(document: doc, source: source)
        var w = Int(doc.canvasWidth), h = Int(doc.canvasHeight)
        if max(w, h) > longSide { let s = Double(longSide)/Double(max(w,h)); w = Int(Double(w)*s); h = Int(Double(h)*s) }
        let ok = engine.renderFramesToPNG(width: w, height: h, frames: n, dt: 1.0/60.0,
                                          outURL: URL(fileURLWithPath: outPath))
        print(ok ? "WROTE \(outPath) (\(w)x\(h)) after \(n) frames" : "FAILED")
        exit(ok ? 0 : 1)
    }

    /// 帧间运动指标:--motion <id> [W] [t0] [dt]
    /// 渲两帧(t0 与 t0+dt),输出灰度 |Δ| 均值 + 变化>25 的像素百分比(对照 WG 0.2%/2.4)。
    private static func runMotion(args: [String]) -> Bool {
        guard let idx = args.firstIndex(of: "--motion"), idx + 1 < args.count else {
            err("usage: --motion <id> [longSide] [t0] [dt]"); exit(2)
        }
        let id = args[idx + 1]
        let longSide = (idx + 2 < args.count) ? (Int(args[idx + 2]) ?? 1280) : 1280
        let t0 = (idx + 3 < args.count) ? (Double(args[idx + 3]) ?? 1.5) : 1.5
        let dt = (idx + 4 < args.count) ? (Double(args[idx + 4]) ?? 0.066) : 0.066

        let root = PreferencesStore.shared.libraryRoot
        let folder = root.appendingPathComponent(id)
        guard let project = try? Data(contentsOf: folder.appendingPathComponent("project.json")),
              let json = try? JSONSerialization.jsonObject(with: project) as? [String: Any] else {
            err("no project.json in \(folder.path)"); exit(1)
        }
        let item = WallpaperItem(id: id, folderURL: folder, title: json["title"] as? String ?? id,
                                 type: WallpaperType(raw: json["type"] as? String),
                                 fileName: json["file"] as? String,
                                 previewName: json["preview"] as? String, tags: [])
        guard let source = SceneSourceFactory.make(for: item),
              let doc = SceneDocument.build(from: source, item: item),
              let engine = SceneRenderEngine() else { err("cannot open scene"); exit(1) }
        engine.load(document: doc, source: source)

        var w = Int(doc.canvasWidth), h = Int(doc.canvasHeight)
        if max(w, h) > longSide { let s = Double(longSide)/Double(max(w,h)); w = Int(Double(w)*s); h = Int(Double(h)*s) }

        // 渲两帧到磁盘(用稳定的 renderToPNG 路径),外部用 Python 算运动指标。
        engine.update(time: t0, mouseNorm: SIMD2<Float>(0, 0))
        _ = engine.renderToPNG(width: w, height: h, outURL: URL(fileURLWithPath: "/tmp/motion_a.png"))
        engine.update(time: t0 + dt, mouseNorm: SIMD2<Float>(0, 0))
        _ = engine.renderToPNG(width: w, height: h, outURL: URL(fileURLWithPath: "/tmp/motion_b.png"))
        print(String(format: "MOTION id=%@ %dx%d t0=%.3f dt=%.3f -> wrote /tmp/motion_a.png /tmp/motion_b.png", id, w, h, t0, dt))
        print("particles: \(engine.particleDiagnostics)")
        exit(0)
    }
}
