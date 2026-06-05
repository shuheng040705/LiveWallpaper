import AppKit

// 生成一个壁纸主题的 app 图标:粉紫渐变圆角方块 + 中央山+太阳剪影 + 闪烁星点。
// 输出多尺寸 PNG 到 iconset 目录,再由脚本转 .icns。

func drawIcon(size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext

    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    // macOS 大圆角(约 22.37% squircle 近似)
    let r = size * 0.2237
    let path = NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r)
    path.addClip()

    // 背景渐变:粉 → 紫 → 深蓝
    let cs = CGColorSpaceCreateDeviceRGB()
    let grad = CGGradient(colorsSpace: cs, colors: [
        CGColor(red: 1.00, green: 0.45, blue: 0.72, alpha: 1),   // 粉
        CGColor(red: 0.62, green: 0.35, blue: 0.92, alpha: 1),   // 紫
        CGColor(red: 0.20, green: 0.18, blue: 0.45, alpha: 1)    // 深蓝紫
    ] as CFArray, locations: [0, 0.5, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: size), end: CGPoint(x: size, y: 0), options: [])

    // 远山剪影(下半部,半透明白)
    let mountain = NSBezierPath()
    mountain.move(to: CGPoint(x: 0, y: size * 0.30))
    mountain.line(to: CGPoint(x: size * 0.28, y: size * 0.50))
    mountain.line(to: CGPoint(x: size * 0.45, y: size * 0.38))
    mountain.line(to: CGPoint(x: size * 0.70, y: size * 0.58))
    mountain.line(to: CGPoint(x: size * 0.88, y: size * 0.42))
    mountain.line(to: CGPoint(x: size, y: size * 0.50))
    mountain.line(to: CGPoint(x: size, y: 0))
    mountain.line(to: CGPoint(x: 0, y: 0))
    mountain.close()
    NSColor(white: 1, alpha: 0.18).setFill()
    mountain.fill()

    // 太阳/月亮(右上,柔光圆)
    let sunR = size * 0.13
    let sunC = CGPoint(x: size * 0.68, y: size * 0.66)
    let glow = CGGradient(colorsSpace: cs, colors: [
        CGColor(red: 1, green: 0.95, blue: 0.85, alpha: 0.95),
        CGColor(red: 1, green: 0.9, blue: 0.8, alpha: 0)
    ] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: sunC, startRadius: 0,
                           endCenter: sunC, endRadius: sunR * 2.2, options: [])
    NSColor(calibratedRed: 1, green: 0.97, blue: 0.9, alpha: 1).setFill()
    NSBezierPath(ovalIn: CGRect(x: sunC.x - sunR, y: sunC.y - sunR, width: sunR*2, height: sunR*2)).fill()

    // 星点/粒子
    NSColor(white: 1, alpha: 0.9).setFill()
    let stars: [(CGFloat, CGFloat, CGFloat)] = [
        (0.20, 0.78, 0.012), (0.35, 0.70, 0.008), (0.50, 0.82, 0.010),
        (0.82, 0.80, 0.009), (0.28, 0.60, 0.007), (0.90, 0.62, 0.008)
    ]
    for (x, y, s) in stars {
        let rr = size * s
        NSBezierPath(ovalIn: CGRect(x: size*x - rr, y: size*y - rr, width: rr*2, height: rr*2)).fill()
    }

    img.unlockFocus()
    return img
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

// iconset 需要的尺寸
let specs: [(name: String, px: CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)
]
for spec in specs {
    let img = drawIcon(size: spec.px)
    guard let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { continue }
    let path = "\(outDir)/\(spec.name).png"
    try? png.write(to: URL(fileURLWithPath: path))
}
print("WROTE iconset to \(outDir)")
