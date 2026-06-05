import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - 基础工具

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xff)/255, green: CGFloat((hex >> 8) & 0xff)/255,
            blue: CGFloat(hex & 0xff)/255, alpha: a)
}
let space = CGColorSpaceCreateDeviceRGB()

func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: stops.map { $0.1 } as CFArray,
               locations: stops.map { $0.0 })!
}

/// 连续圆角(近似 squircle)的圆角矩形路径。
func roundedRect(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

let S: CGFloat = 1024

/// 在 1024×1024 透明画布上:画带阴影的圆角底板 → 裁剪 → 调用 design 填充内容 → 顶部高光。
func render(_ name: String, _ design: (CGContext, CGRect) -> Void) {
    let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8,
                        bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.setAllowsAntialiasing(true)

    let margin = S * 0.085
    let art = CGRect(x: margin, y: margin, width: S - 2*margin, height: S - 2*margin)
    let radius = art.width * 0.2237   // macOS 连续圆角比例
    let path = roundedRect(art, radius)

    // 阴影(底板投影)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -S*0.012), blur: S*0.05, color: rgb(0x000000, 0.32))
    ctx.addPath(path); ctx.setFillColor(rgb(0x000000, 1)); ctx.fillPath()
    ctx.restoreGState()

    // 裁剪进圆角内绘制
    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    design(ctx, art)
    ctx.restoreGState()

    // 顶部细高光 + 内描边,增加质感
    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    let gloss = gradient([(0, rgb(0xffffff, 0.18)), (0.12, rgb(0xffffff, 0.0))])
    ctx.drawLinearGradient(gloss, start: CGPoint(x: 0, y: art.maxY),
                           end: CGPoint(x: 0, y: art.maxY - art.height*0.5), options: [])
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(roundedRect(art.insetBy(dx: 1, dy: 1), radius)); ctx.setLineWidth(2)
    ctx.setStrokeColor(rgb(0xffffff, 0.12)); ctx.strokePath()
    ctx.restoreGState()

    guard let img = ctx.makeImage() else { return }
    let url = URL(fileURLWithPath: "/tmp/icongen/\(name).png")
    let dst = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dst, img, nil)
    CGImageDestinationFinalize(dst)
    print("wrote \(name).png")
}

// 小工具:填充径向光晕
func glow(_ ctx: CGContext, center: CGPoint, radius: CGFloat, _ color: CGColor, _ coreAlpha: CGFloat = 1) {
    let g = gradient([(0, color), (0.5, color), (1, rgb(0xffffff, 0))])
    ctx.saveGState()
    ctx.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center,
                           endRadius: radius, options: [])
    ctx.restoreGState()
}

// 星点
func stars(_ ctx: CGContext, _ rect: CGRect, _ pts: [(CGFloat, CGFloat, CGFloat, CGFloat)]) {
    for (x, y, r, a) in pts {
        ctx.setFillColor(rgb(0xffffff, a))
        let c = CGPoint(x: rect.minX + rect.width*x, y: rect.minY + rect.height*y)
        ctx.fillEllipse(in: CGRect(x: c.x-r, y: c.y-r, width: r*2, height: r*2))
    }
}

// MARK: - A. 暮色山峦(精修当前风格)
func designA(_ ctx: CGContext, _ r: CGRect) {
    let bg = gradient([(0, rgb(0x2A1E4F)), (0.45, rgb(0x6A4A9E)), (0.78, rgb(0xB06FB8)), (1, rgb(0xE6A6C6))])
    ctx.drawLinearGradient(bg, start: CGPoint(x: r.minX, y: r.maxY),
                           end: CGPoint(x: r.maxX, y: r.minY), options: [])
    stars(ctx, r, [(0.18,0.82,5,0.9),(0.30,0.70,3.5,0.7),(0.12,0.62,3,0.6),
                   (0.78,0.86,4,0.85),(0.86,0.74,3,0.6),(0.66,0.90,3,0.7),(0.40,0.86,3,0.55)])
    // 月亮 + 光晕
    let moon = CGPoint(x: r.minX + r.width*0.66, y: r.minY + r.height*0.70)
    glow(ctx, center: moon, radius: r.width*0.26, rgb(0xFFF3D6, 0.55))
    ctx.setFillColor(rgb(0xFFF7E6))
    ctx.fillEllipse(in: CGRect(x: moon.x-r.width*0.10, y: moon.y-r.width*0.10, width: r.width*0.20, height: r.width*0.20))
    // 后山(浅、雾)
    func ridge(_ ys: [CGFloat], _ color: CGColor) {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        let n = ys.count
        for (i, y) in ys.enumerated() {
            p.addLine(to: CGPoint(x: r.minX + r.width*CGFloat(i)/CGFloat(n-1), y: r.minY + r.height*y))
        }
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY)); p.closeSubpath()
        ctx.addPath(p); ctx.setFillColor(color); ctx.fillPath()
    }
    ridge([0.30,0.46,0.34,0.52,0.40,0.30], rgb(0x7E5DA8, 0.85))
    ridge([0.10,0.30,0.18,0.40,0.22,0.12,0.26], rgb(0x4C3A78, 0.95))
}

// MARK: - B. 暖阳沙丘
func designB(_ ctx: CGContext, _ r: CGRect) {
    let bg = gradient([(0, rgb(0xFF5E87)), (0.5, rgb(0xFF8F5A)), (1, rgb(0xFFD06B))])
    ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: r.maxY), end: CGPoint(x: 0, y: r.minY), options: [])
    // 太阳
    let sun = CGPoint(x: r.minX + r.width*0.5, y: r.minY + r.height*0.66)
    glow(ctx, center: sun, radius: r.width*0.34, rgb(0xFFF6E0, 0.6))
    ctx.setFillColor(rgb(0xFFF9EC))
    ctx.fillEllipse(in: CGRect(x: sun.x-r.width*0.135, y: sun.y-r.width*0.135, width: r.width*0.27, height: r.width*0.27))
    // 沙丘三层曲线
    func dune(_ baseY: CGFloat, _ amp: CGFloat, _ phase: CGFloat, _ color: CGColor) {
        let p = CGMutablePath(); p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + r.height*baseY))
        let steps = 40
        for i in 0...steps {
            let t = CGFloat(i)/CGFloat(steps)
            let x = r.minX + r.width*t
            let y = r.minY + r.height*(baseY + amp*sin(t * .pi * 1.6 + phase))
            p.addLine(to: CGPoint(x: x, y: y))
        }
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY)); p.closeSubpath()
        ctx.addPath(p); ctx.setFillColor(color); ctx.fillPath()
    }
    dune(0.40, 0.05, 0.3, rgb(0xE8607E, 0.9))
    dune(0.26, 0.06, 1.4, rgb(0xC24C77, 0.95))
    dune(0.13, 0.05, 2.6, rgb(0x8E3A6B))
}

// MARK: - C. 桌面显示器(点题:动态壁纸)
func designC(_ ctx: CGContext, _ r: CGRect) {
    let bg = gradient([(0, rgb(0x2A3350)), (1, rgb(0x161B2A))])
    ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: r.maxY), end: CGPoint(x: 0, y: r.minY), options: [])
    // 显示器外框
    let scr = CGRect(x: r.minX + r.width*0.16, y: r.minY + r.height*0.26,
                     width: r.width*0.68, height: r.height*0.46)
    let bz = scr.insetBy(dx: -r.width*0.025, dy: -r.width*0.025)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: r.width*0.05, color: rgb(0x000000, 0.4))
    ctx.addPath(roundedRect(bz, r.width*0.05)); ctx.setFillColor(rgb(0x0E1220)); ctx.fillPath()
    ctx.restoreGState()
    // 屏幕里的迷你壁纸
    let scrR = r.width*0.035
    ctx.saveGState(); ctx.addPath(roundedRect(scr, scrR)); ctx.clip()
    let wp = gradient([(0, rgb(0x6A4A9E)), (0.6, rgb(0xB06FB8)), (1, rgb(0xF0B6CE))])
    ctx.drawLinearGradient(wp, start: CGPoint(x: scr.minX, y: scr.maxY), end: CGPoint(x: scr.maxX, y: scr.minY), options: [])
    let moon = CGPoint(x: scr.minX + scr.width*0.70, y: scr.minY + scr.height*0.66)
    glow(ctx, center: moon, radius: scr.width*0.22, rgb(0xFFF3D6, 0.6))
    ctx.setFillColor(rgb(0xFFF7E6)); ctx.fillEllipse(in: CGRect(x: moon.x-scr.width*0.07, y: moon.y-scr.width*0.07, width: scr.width*0.14, height: scr.width*0.14))
    // 迷你山
    let mp = CGMutablePath(); mp.move(to: CGPoint(x: scr.minX, y: scr.minY))
    mp.addLine(to: CGPoint(x: scr.minX + scr.width*0.30, y: scr.minY + scr.height*0.42))
    mp.addLine(to: CGPoint(x: scr.minX + scr.width*0.52, y: scr.minY + scr.height*0.18))
    mp.addLine(to: CGPoint(x: scr.minX + scr.width*0.78, y: scr.minY + scr.height*0.50))
    mp.addLine(to: CGPoint(x: scr.maxX, y: scr.minY + scr.height*0.24))
    mp.addLine(to: CGPoint(x: scr.maxX, y: scr.minY)); mp.closeSubpath()
    ctx.addPath(mp); ctx.setFillColor(rgb(0x4C3A78, 0.92)); ctx.fillPath()
    ctx.restoreGState()
    // 屏幕反光
    ctx.saveGState(); ctx.addPath(roundedRect(scr, scrR)); ctx.clip()
    let sh = gradient([(0, rgb(0xffffff, 0.18)), (0.4, rgb(0xffffff, 0))])
    ctx.drawLinearGradient(sh, start: CGPoint(x: scr.minX, y: scr.maxY), end: CGPoint(x: scr.minX + scr.width*0.5, y: scr.midY), options: [])
    ctx.restoreGState()
    // 底座
    ctx.setFillColor(rgb(0x0E1220))
    let standW = r.width*0.10, standTop = bz.minY
    ctx.fill(CGRect(x: r.midX - standW/2, y: standTop - r.height*0.06, width: standW, height: r.height*0.06))
    ctx.addPath(roundedRect(CGRect(x: r.midX - r.width*0.13, y: standTop - r.height*0.085, width: r.width*0.26, height: r.height*0.03), r.width*0.012))
    ctx.fillPath()
    // 播放圆点(动态暗示)
    let play = CGPoint(x: scr.maxX - r.width*0.02, y: scr.maxY - r.width*0.02)
    _ = play
}

// MARK: - D. 极光流动(抽象 / 动感)
func designD(_ ctx: CGContext, _ r: CGRect) {
    let bg = gradient([(0, rgb(0x141A2E)), (1, rgb(0x0B0E1A))])
    ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: r.maxY), end: CGPoint(x: 0, y: r.minY), options: [])
    stars(ctx, r, [(0.20,0.84,3.5,0.8),(0.78,0.88,3,0.7),(0.55,0.92,2.5,0.6),(0.34,0.90,2.5,0.5),(0.88,0.78,2.5,0.55)])
    // 极光带:多条半透明曲线带,叠出流动感
    func band(_ baseY: CGFloat, _ amp: CGFloat, _ phase: CGFloat, _ thick: CGFloat, _ c0: CGColor, _ c1: CGColor) {
        let p = CGMutablePath()
        let steps = 60
        var top: [CGPoint] = [], bot: [CGPoint] = []
        for i in 0...steps {
            let t = CGFloat(i)/CGFloat(steps); let x = r.minX + r.width*t
            let y = r.minY + r.height*(baseY + amp*sin(t * .pi * 2 + phase))
            top.append(CGPoint(x: x, y: y + r.height*thick/2))
            bot.append(CGPoint(x: x, y: y - r.height*thick/2))
        }
        p.move(to: top[0]); top.forEach { p.addLine(to: $0) }
        bot.reversed().forEach { p.addLine(to: $0) }; p.closeSubpath()
        ctx.saveGState(); ctx.addPath(p); ctx.clip()
        let g = gradient([(0, c0), (1, c1)])
        ctx.drawLinearGradient(g, start: CGPoint(x: r.minX, y: r.maxY), end: CGPoint(x: r.maxX, y: r.minY), options: [])
        ctx.restoreGState()
    }
    band(0.62, 0.10, 0.6, 0.16, rgb(0x3BE0C4, 0.55), rgb(0x5A8CFF, 0.35))
    band(0.50, 0.12, 2.0, 0.20, rgb(0x9B5CFF, 0.50), rgb(0x3BE0C4, 0.30))
    band(0.38, 0.10, 3.4, 0.16, rgb(0xFF6FB0, 0.50), rgb(0x9B5CFF, 0.30))
    // 顶部柔光
    glow(ctx, center: CGPoint(x: r.midX, y: r.minY + r.height*0.55), radius: r.width*0.5, rgb(0x6FA8FF, 0.10))
}

render("A_twilight", designA)
render("B_sunset", designB)
render("C_desktop", designC)
render("D_aurora", designD)
