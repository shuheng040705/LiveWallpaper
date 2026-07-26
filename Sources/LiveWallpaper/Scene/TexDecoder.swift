import Foundation

/// 解码后的纹理:统一为 RGBA8 像素,或一个可交给 MTKTextureLoader 的编码图片(PNG/JPG),
/// 或一段视频容器(MP4 动态贴图,交给 VideoTexture 逐帧播放)。
enum DecodedTex {
    case encoded(Data)                                   // format 0:完整 PNG/JPG
    case rgba8(pixels: [UInt8], width: Int, height: Int) // 其余一律软件解码成 RGBA8
    case video(Data)                                     // MP4/MOV 视频纹理(原始容器字节)
}

/// WE .tex 头第 2 个 int 的纹理 flags(对齐 reference Texture.h:TextureFlags)。
/// 驱动采样器选择:ClampUVs→clampToEdge(否则 WE 默认 repeat);NoInterpolation→nearest(否则 linear)。
struct TexFlags {
    static let noInterpolation = 1      // GL_NEAREST(否则 GL_LINEAR)
    static let clampUVs        = 2      // GL_CLAMP_TO_EDGE(否则 GL_REPEAT,WE 默认)
    static let isGif           = 4      // 动画/精灵表(TEXS 段存在)
    static let clampUVsBorder  = 8
    static let video           = 32     // MP4 视频纹理(对齐 reference TextureFlags_Video)
    static let alphaChannelPriority = 524288   // RG88/R8:alpha 在 G/R 通道(见 CPass TEX0FORMAT)

    /// 原始 flags 位。
    let raw: Int
    init(_ raw: Int) { self.raw = raw }

    var nearest: Bool { raw & TexFlags.noInterpolation != 0 }
    var clamp: Bool   { raw & (TexFlags.clampUVs | TexFlags.clampUVsBorder) != 0 }
}

/// 精灵表帧信息(从 .tex 内嵌的 TEXS 段解析)。WE 把动画帧的 UV 矩形存在 .tex 尾部,
/// 而非单独 .tex-json。一帧 = (x, y, w, h) 像素矩形 + 时长秒。
struct SpriteSheetInfo {
    var frameCount: Int
    var frameDuration: Float        // 每帧秒数(取首帧,通常等时)
    var frames: [(x: Float, y: Float, w: Float, h: Float)]   // 像素矩形(相对整张 tex)
}

extension TexDecoder {
    /// 解析 .tex 内嵌的 TEXS 精灵表/动画段。无则返回 nil。
    /// 帧字段顺序严格对齐 reference TextureParser.cpp:
    ///   TEXS0002/0003(parseFrame 110-123):[frameNumber u32, frametime f32, x f32, y f32, width1 f32, width2 f32, height2 f32, height1 f32]
    ///   TEXS0001(parseFrameV1 95-108):   [frameNumber u32, frametime f32, x u32, y u32, width1 u32, unk u32, unk u32, height1 u32]
    /// frameCount 后:仅 TEXS0003 多 gifWidth/gifHeight(u32);0001/0002 没有(其 gif 尺寸取首帧 w/h)。
    /// 帧矩形用 (x, y, width1, height1) 像素坐标,引擎据此 + tex 实际宽高换算 UV。
    static func spriteSheet(_ blob: Data) -> SpriteSheetInfo? {
        let bytes = [UInt8](blob)
        // 找 "TEXS" 魔数(WE 把动画段放在所有 mip 之后,无法精确定位偏移,故扫描)。
        guard let pos = find(bytes, pattern: [0x54, 0x45, 0x58, 0x53]) else { return nil }
        var o = pos
        guard o + 8 <= bytes.count else { return nil }
        // magic "TEXSxxxx" 8 字节 + null 终止符。版本号取第 8 个 ASCII 数字。
        let verDigit = bytes[o + 7]
        guard verDigit >= 0x31, verDigit <= 0x33 else { return nil }   // 仅 0001/0002/0003
        let version = Int(verDigit - 0x30)
        guard o + 9 <= bytes.count else { return nil }
        o += 9
        func i32() -> Int? {
            guard o + 4 <= bytes.count else { return nil }
            let v = UInt32(bytes[o]) | (UInt32(bytes[o+1])<<8) | (UInt32(bytes[o+2])<<16) | (UInt32(bytes[o+3])<<24)
            o += 4; return Int(Int32(bitPattern: v))
        }
        func f32() -> Float? {
            guard o + 4 <= bytes.count else { return nil }
            let v = UInt32(bytes[o]) | (UInt32(bytes[o+1])<<8) | (UInt32(bytes[o+2])<<16) | (UInt32(bytes[o+3])<<24)
            o += 4; return Float(bitPattern: v)
        }
        guard let fc = i32(), fc > 0, fc < 65536 else { return nil }
        if version == 3 {                       // TEXS0003 才有 gifWidth/gifHeight
            guard i32() != nil, i32() != nil else { return nil }
        }
        var frames: [(x: Float, y: Float, w: Float, h: Float)] = []
        var dur: Float = 1.0 / 24
        for _ in 0..<fc {
            guard i32() != nil else { break }            // frameNumber(忽略)
            guard let d = f32() else { break }           // frametime(秒)
            let x: Float, y: Float, w: Float, h: Float
            if version == 1 {                            // parseFrameV1:坐标是 u32
                guard let xi = i32(), let yi = i32(), let wi = i32(),
                      i32() != nil, i32() != nil, let hi = i32() else { break }
                x = Float(xi); y = Float(yi); w = Float(wi); h = Float(hi)
            } else {                                     // parseFrame:坐标是 f32(width2/height2 忽略)
                guard let xf = f32(), let yf = f32(), let w1 = f32(),
                      f32() != nil, f32() != nil, let h1 = f32() else { break }
                x = xf; y = yf; w = w1; h = h1
            }
            if d > 0.0001 { dur = d }
            frames.append((x: x, y: y, w: w, h: h))
        }
        guard !frames.isEmpty, frames[0].w > 0, frames[0].h > 0 else { return nil }
        return SpriteSheetInfo(frameCount: frames.count, frameDuration: dur, frames: frames)
    }

    private static func find(_ bytes: [UInt8], pattern: [UInt8]) -> Int? {
        guard bytes.count >= pattern.count else { return nil }
        var i = 0
        let end = bytes.count - pattern.count
        while i <= end {
            var ok = true
            for j in 0..<pattern.count where bytes[i+j] != pattern[j] { ok = false; break }
            if ok { return i }
            i += 1
        }
        return nil
    }
}

/// 解析 Wallpaper Engine 的 .tex 容器并取 mip0。
/// 关键(实测修正 spec):GPU 纹理是 LZ4-block 压缩的 DXT(BC1/BC3)或 raw RG8/R8;
/// format 0 是内嵌 PNG/JPG(可能再被 LZ4 压一层)。详见 WE_SCENE_SPEC.md 与 memory we-scene-format。
enum TexDecoder {

    // 审计修复(HIGH):移除 findImageSignature ——原 format 0 兜底用它从 blob 偏移 0
    // 全局扫描签名,会把容器中段字节误判为图片起点。改为只信任 mip0 数据本身的签名判定后,
    // 此函数已无调用方,删除以免留下危险的「乱扫」入口与死代码警告。

    private static func isImageData(_ b: [UInt8]) -> Bool {
        guard b.count >= 3 else { return false }
        let png = b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E
        let jpg = b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF
        return png || jpg
    }

    /// ISO-BMFF 容器(MP4/MOV):box 头 size(4) + 'ftyp'(4)。WE 用它做视频纹理(动态贴图)。
    private static func isVideoContainer(_ b: [UInt8]) -> Bool {
        guard b.count >= 12 else { return false }
        return b[4] == 0x66 && b[5] == 0x74 && b[6] == 0x79 && b[7] == 0x70   // "ftyp"
    }

    /// 视频纹理 → 返回原始 MP4 字节,交给上层决定逐帧播放还是只取首帧。
    private static func videoTex(_ data: Data) -> DecodedTex? {
        // 体积下限防御:太小不像有效视频。
        guard data.count > 1024 else { return nil }
        return .video(data)
    }

    /// 旧 API:只取解码结果(flags 不需要时用)。内部走带 flags 的实现。
    static func decodeFirstMip(_ blob: Data) -> DecodedTex? {
        return decodeFirstMipWithFlags(blob)?.tex
    }

    /// 只读 .tex 头(TEXV/TEXI 前 7 个 int),不解码像素。返回:
    ///   texW/texH = 容器尺寸(POT,如 2048×2048);imgW/imgH = 真实内容尺寸(如 1198×1200)。
    /// 用途:cropoffset 判定。容器≠内容(texW≠imgW)⇒ 贴图被裁进 POT 容器、内容相对原图发生位移,
    /// cropoffset 是真实重定位偏移,须应用;texW==imgW(未裁,如 Postscript 五官 680×836 原样存)⇒
    /// cropoffset 是编辑器残留元数据,套用会让本已正确的裸 origin 散开,**不应用**。
    /// 头布局与 decodeFirstMipWithFlags:160-167 一致(2 个 C 串 magic + format,flags,texW,texH,imgW,imgH,unk)。
    static func headerWH(_ blob: Data) -> (texW: Int, texH: Int, imgW: Int, imgH: Int)? {
        let bytes = [UInt8](blob)
        var p = 0
        func readCString() -> String? {
            guard let nul = bytes[p...].firstIndex(of: 0) else { return nil }
            let s = String(bytes: bytes[p..<nul], encoding: .ascii)
            p = nul + 1
            return s
        }
        func readI32() -> Int? {
            guard p + 4 <= bytes.count else { return nil }
            let v = UInt32(bytes[p]) | (UInt32(bytes[p+1]) << 8) | (UInt32(bytes[p+2]) << 16) | (UInt32(bytes[p+3]) << 24)
            p += 4
            return Int(Int32(bitPattern: v))
        }
        guard let m1 = readCString(), m1.hasPrefix("TEXV") else { return nil }
        guard readCString() != nil else { return nil }                            // TEXI0001
        guard readI32() != nil, readI32() != nil,                                 // format, flags
              let texW = readI32(), let texH = readI32(),
              let imgW = readI32(), let imgH = readI32() else { return nil }
        return (texW, texH, imgW, imgH)
    }

    /// .tex 头 + freeimage 判定:返回 (容器 texW/texH, 内容 imgW/imgH, 是否 freeimage 内嵌图片(PNG/JPG/...))。
    /// 用途:**真 WE 对 freeimage 纹理的 g_TextureNResolution 仍按头部(容器,内容)喂**,而实际 GPU 纹理是
    /// FreeImage 解码的内容尺寸 → 修正系数 imgH/texH 把 UV 压到内容上半部 = "错位采样"是 WE 的真实行为
    /// (御剑「影子」遮罩 4096×4096 容器/4096×2296 内容 → 遮罩只用上 56%(发顶区)→ 身体音频条从发缘起、不上脸)。
    /// lwe 对 FIF 特判成 (内容,内容)=修正1(CTexture.cpp:127-134)→ lwe≠真 WE;我们按真 WE。
    static func headerInfo(_ blob: Data) -> (texW: Int, texH: Int, imgW: Int, imgH: Int, freeImage: Bool)? {
        let bytes = [UInt8](blob)
        var p = 0
        func readCString() -> String? {
            guard let nul = bytes[p...].firstIndex(of: 0) else { return nil }
            let s = String(bytes: bytes[p..<nul], encoding: .ascii)
            p = nul + 1
            return s
        }
        func readI32() -> Int? {
            guard p + 4 <= bytes.count else { return nil }
            let v = UInt32(bytes[p]) | (UInt32(bytes[p+1]) << 8) | (UInt32(bytes[p+2]) << 16) | (UInt32(bytes[p+3]) << 24)
            p += 4
            return Int(Int32(bitPattern: v))
        }
        guard let m1 = readCString(), m1.hasPrefix("TEXV") else { return nil }
        guard readCString() != nil else { return nil }                            // TEXI0001
        guard readI32() != nil, readI32() != nil,                                 // format, flags
              let texW = readI32(), let texH = readI32(),
              let imgW = readI32(), let imgH = readI32(), readI32() != nil else { return nil }
        guard let m3 = readCString(), m3.hasPrefix("TEXB") else { return nil }
        let ver = Int(String(m3.suffix(1))) ?? 0
        guard readI32() != nil else { return nil }                                // imageCount
        var fif = -1
        if ver >= 3 { fif = readI32() ?? -1 }                                     // freeImageFormat(0003/0004)
        return (texW, texH, imgW, imgH, fif != -1)
    }

    /// 解码 + 带出 WE 纹理 flags(.tex 头第 2 个 int)。draw 时按 flags 选采样器(repeat/clamp、linear/nearest)。
    /// dataTexture=true:把双通道格式(RG88)当**数据贴图**解(R→R、G→G,如 waterflow 流向场 R=水平/G=垂直、
    /// 法线 RG=xy),而非默认的「亮度 R + alpha G」(精灵/颜色贴图用)。仅特效辅助槽(flowmask/法线/相位)传 true。
    static func decodeFirstMipWithFlags(_ blob: Data, dataTexture: Bool = false) -> (tex: DecodedTex, flags: TexFlags)? {
        let bytes = [UInt8](blob)
        var p = 0

        func readCString() -> String? {
            guard let nul = bytes[p...].firstIndex(of: 0) else { return nil }
            let s = String(bytes: bytes[p..<nul], encoding: .ascii)
            p = nul + 1
            return s
        }
        func readI32() -> Int? {
            guard p + 4 <= bytes.count else { return nil }
            let v = UInt32(bytes[p]) | (UInt32(bytes[p+1]) << 8) | (UInt32(bytes[p+2]) << 16) | (UInt32(bytes[p+3]) << 24)
            p += 4
            return Int(Int32(bitPattern: v))
        }

        guard let m1 = readCString(), m1.hasPrefix("TEXV") else { return nil }
        guard readCString() != nil else { return nil }                            // TEXI0001
        // TEXI 头 7 个 int:format, flags, textureW(容器/pow2), textureH, imageW(真实), imageH, unk。
        // 第 2 个 int = flags(对齐 reference Texture.h:NoInterpolation/ClampUVs/...),驱动采样器选择。
        guard let format = readI32(), let flagsRaw = readI32(),
              let texW = readI32(), let texH = readI32(),
              let imgW = readI32(), let imgH = readI32(), readI32() != nil
        else { return nil }
        // 容器尺寸 texW/texH(pow2)在裁切时用 imgW/imgH;但 texW/texH 仍保留下来,
        // 供下方 TEXB0004 extra-header 启发式判定 mip0 宽高是否与容器声明自洽(审计修复 2)。
        let flags = TexFlags(flagsRaw)

        guard let m3 = readCString(), m3.hasPrefix("TEXB") else { return nil }
        let ver = Int(String(m3.suffix(1))) ?? 0

        // === 容器头(对齐 reference TextureParser.cpp:parseContainer 175-205)===
        // 顺序:magic(已读) → imageCount → (TEXB0003/0004 才有)freeImageFormat → (TEXB0004 才有)isVideoMp4。
        // freeImageFormat == FIF_UNKNOWN(-1)→ 走 GPU/像素格式解码;否则整块字节是某编码图片(BMP/TGA/WEBP/PSD/GIF/...),
        // 交给 MTKTextureLoader(ImageIO,等价于 reference 的 stb_image 路径)。
        guard let imageCount = readI32(), imageCount > 0 else { return nil }
        var freeImageType = -1                 // FIF_UNKNOWN
        var isVideoMp4 = false
        if ver == 4 {
            guard let fif = readI32() else { return nil }
            freeImageType = fif
            guard let vid = readI32() else { return nil }
            isVideoMp4 = (vid == 1)
            // reference:FIF_UNKNOWN && isVideoMp4 → 当作 MP4(FIF_MP4 == FIF_WEBP == 35)。
            if freeImageType == -1 && isVideoMp4 { freeImageType = 35 }
        } else if ver == 3 {
            guard let fif = readI32() else { return nil }
            freeImageType = fif
        }
        // TEXB0004 的 mip 头比 0003/0002 多:2 个可忽略 u32 + 一个 null 结尾 json 串 + 1 个可忽略 u32。
        let hasMipJsonHeader = (ver == 4)
        // 是否在 mip 头里带 compression+uncompressedSize(TEXB0002/0003/0004 有,TEXB0001 没有)。
        let hasCompressionField = (ver >= 2)

        // 容器纹理是 pow2(如 4096×2048),真实图像(imgW×imgH,如 3840×1080)放在**左上角**,
        // 右/下是无用 padding。WE 采样时按 image/container 缩放 uv;我们直接裁成真实图像,
        // 这样 uv[0,1] 正好覆盖图片,壁纸才铺满屏幕(否则右下角露出 padding = 灰边)。
        func finish(_ pixels: [UInt8], _ cw: Int, _ ch: Int) -> DecodedTex {
            guard imgW > 0, imgH > 0, imgW <= cw, imgH <= ch, (imgW < cw || imgH < ch),
                  pixels.count >= cw * ch * 4 else {
                return .rgba8(pixels: pixels, width: cw, height: ch)
            }
            var out = [UInt8](repeating: 0, count: imgW * imgH * 4)
            for y in 0..<imgH {
                let src = y * cw * 4
                let dst = y * imgW * 4
                out.replaceSubrange(dst..<dst + imgW * 4, with: pixels[src..<src + imgW * 4])
            }
            return .rgba8(pixels: out, width: imgW, height: imgH)
        }

        /// 解析单个 mip 头并返回 (w, h, 已解压字节)。cursor 前进到该 mip 数据之后。
        /// 严格按 reference parseMipmap(40-93):TEXB0004 头部 extra → w,h →(有压缩字段时)compression,uncompressedSize → compressedSize → data。
        func readMip() -> (w: Int, h: Int, raw: [UInt8])? {
            // TEXB0004 的 mip 头:reference parseMipmap(44-54)说有 extra 头(2 u32 + json 串 + 1 u32),
            // 但实测本库 192/192 个 TEXB0004 文件 w/h 紧跟 mipCount、**没有** extra 头(当前 WE 版本已去掉)。
            // 审计修复(HIGH):收紧 extra-header 探测。原判定只看「下两个 i32 是否落在 1..16384」,
            // 太宽松——容器中段随机字节常落在该区间,猜错就整条 mip 偏移错位→彩色噪点。
            // 改为对「无 extra 头」假设做一次完整的自洽探测(不前进 cursor):
            //   1) w/h 既要在 1..16384,又要 ≤ 容器声明的 texW/texH(mip0 即容器全尺寸,
            //      更小 mip 只会更小,故 ≤ 必成立;texW/texH 异常时退回 16384 上界);
            //   2) 把后续字段(压缩字段 + compressedSize)按「无 extra 头」布局读出,
            //      要求 compressedSize 为正、且 p+compressedSize 落在 blob 内(自洽)。
            // 两条都满足才认定无 extra 头;否则保守按 reference 消费 extra 头(兼容旧格式)。
            // 实测本库 192/192 个 TEXB0004 是无 extra 头,该路径仍命中,v4 贴图解码不变。
            // 风险说明:若某文件确有 extra 头、且其 extra 字节又恰好自洽成合法 mip 头,理论上仍可能误判;
            // 但叠加「w/h ≤ texW/texH 的 pow2 容器约束 + 数据长度自洽」后,误判概率已远低于原版。
            if hasMipJsonHeader {
                let save = p
                let wBound = (texW >= 1 && texW <= 16384) ? texW : 16384
                let hBound = (texH >= 1 && texH <= 16384) ? texH : 16384
                func plausibleDim(_ v: Int?, _ bound: Int) -> Bool {
                    guard let v = v, v >= 1, v <= 16384, v <= bound else { return false }
                    return true
                }
                // 探测「无 extra 头」布局:w, h, [compression, uncompressedSize], compressedSize
                let w0 = readI32(); let h0 = readI32()
                var selfConsistent = false
                if plausibleDim(w0, wBound), plausibleDim(h0, hBound) {
                    if hasCompressionField { _ = readI32(); _ = readI32() }   // compression, uncompressedSize
                    if let szC0 = readI32(), szC0 > 0, p + szC0 <= bytes.count {
                        selfConsistent = true     // compressedSize 落在 blob 内 → 自洽,判定无 extra 头
                    }
                }
                p = save                          // 探测不前进 cursor,真正读取在下方统一进行
                if !selfConsistent {
                    guard readI32() != nil, readI32() != nil else { return nil }   // 2 个可忽略 u32
                    guard readCString() != nil else { return nil }                 // json 串
                    guard readI32() != nil else { return nil }                     // 1 个可忽略 u32
                }
            }
            guard let w = readI32(), let h = readI32() else { return nil }
            var compression = 0
            var szU = 0
            if hasCompressionField {
                guard let c = readI32(), let u = readI32() else { return nil }
                compression = c; szU = u
            }
            let szCopt = readI32()
            guard let szC = szCopt, szC > 0, p + szC <= bytes.count, w > 0, h > 0 else {
                Log.write("  readMip GUARD-FAIL: w=\(w) h=\(h) comp=\(compression) szU=\(szU) szC=\(String(describing: szCopt)) p=\(p) total=\(bytes.count)")
                return nil
            }
            // 未压缩时 compressedSize 即字节长度(reference 注释:此变量实为 mip 字节数)。
            if compression == 0 { szU = szC }
            let mip = Array(bytes[p..<(p + szC)])
            p += szC
            if compression == 1 {
                guard let d = LZ4.decodeBlock(mip, expectedSize: szU), d.count >= szU else {
                    Log.write("  TexDecoder fmt\(format) fif\(freeImageType) ver\(ver): LZ4 fail (szC=\(szC) szU=\(szU))")
                    return nil
                }
                return (w, h, d)
            }
            return (w, h, mip)
        }

        // 解码主体产出 DecodedTex?,公共出口统一附带 flags。
        func body() -> DecodedTex? {
            // mip0 = image0 的第一个 mip。WE 容器是多 image × 多 mip;我们只渲染 mip0,但仍按头读完
            // 整张 image0 的 mip 链,让 cursor 落在 TEXS 段前(避免 spriteSheet 扫描错位)。
            guard let mip0Count = readI32(), mip0Count > 0 else { return nil }
            guard let (w, h, raw) = readMip() else {
                Log.write("  TexDecoder: readMip(mip0) nil (fmt=\(format) fif=\(freeImageType) ver=\(ver) img=\(imgW)x\(imgH))")
                return nil
            }
            // 跳过 image0 剩余 mip(更小的 mip 不需要,但要前进 cursor)。失败不致命:mip0 已拿到。
            if mip0Count > 1 {
                for _ in 1..<mip0Count { if readMip() == nil { break } }
            }

            // === freeimage 容器:整块是编码图片(或视频)→ 交给上层解码器 ===
            // 对齐 reference CTexture.cpp:63-69(freeImageFormat != UNKNOWN → stbi_load_from_memory)。
            if freeImageType != -1 {
                // MP4 视频纹理(FIF_MP4/WEBP==35 且 isVideoMp4,或 flags Video 位)走视频路径;
                // ISO-BMFF 容器无论 flag 如何都当视频(否则会被当编码图喂给 ImageIO 失败)。
                if isVideoContainer(raw) { return videoTex(Data(raw)) }
                // 其余一律把字节交给 MTKTextureLoader(ImageIO):PNG/JPG/BMP/TGA/WEBP/PSD/GIF/TIFF/...
                // BMP/TGA 无固定魔数,不做签名校验,交给加载器判定格式。
                return .encoded(Data(raw))
            }

            // === format 0 (ARGB8888):内嵌 PNG/JPG、MP4 视频、或 (LZ4 压过的) raw RGBA8 ===
            // 注意:freeImageType==-1 时 fmt0 一般是 raw RGBA8;历史样本里也有签名图片(老 TEXB0001/0002),
            // 由下面对 mip0 数据(raw)起始字节的 isImageData 签名判定覆盖(不再全局乱扫)。
            if format == 0 {
                if isImageData(raw) { return .encoded(Data(raw)) }
                // 视频必须先于 raw-RGBA8 判定:MP4 字节数常 ≥ w*h*4,会被误当像素铺成噪点。
                if isVideoContainer(raw) { return videoTex(Data(raw)) }
                if raw.count >= w * h * 4 { return finish(Array(raw.prefix(w * h * 4)), w, h) }
                // 审计修复(HIGH):删除原从 blob 偏移 0 全局扫描 PNG/JPG 签名的兜底——
                // 它会把容器中段随机字节误判成图片起点,切出乱码。mip0 数据(raw)已在上面做过
                // isImageData 签名判定;raw 不是图片也凑不够 RGBA8 时,宁可返回 nil(失败)
                // 也不靠全局乱扫猜起点。正常 RGBA8888 路径(签名图 / 足量像素)不受影响。
                return nil
            }

            // === GPU / 像素格式 → 解块/重排为 RGBA8 ===
            // 对照 reference Texture.h:TextureFormat 枚举码。
            switch format {
            case 7:        // DXT1 / BC1
                guard let rgba = DXT.decode(raw, width: w, height: h, bc: 1) else { return nil }
                return finish(rgba, w, h)
            case 6:        // DXT3 / BC2:4-bit 显式 alpha(独立块),区别于 DXT5 的插值 alpha
                guard let rgba = DXT.decode(raw, width: w, height: h, bc: 2) else { return nil }
                return finish(rgba, w, h)
            case 4:        // DXT5 / BC3:3-bit 插值 alpha
                guard let rgba = DXT.decode(raw, width: w, height: h, bc: 3) else { return nil }
                return finish(rgba, w, h)
            case 1:        // RGB888:每像素 3 字节 → RGBA8(alpha=255)
                guard let rgba = PixelFormat.rgb888(raw, width: w, height: h) else { return nil }
                return finish(rgba, w, h)
            case 2:        // RGB565:每像素 2 字节 → RGBA8(alpha=255)
                guard let rgba = PixelFormat.rgb565(raw, width: w, height: h) else { return nil }
                return finish(rgba, w, h)
            case 8:        // RG88:每像素 2 字节,两种语义按用途分流(见 dataTexture 参数)
                // ① 默认(精灵/颜色贴图,beam/fog 等):WE 里是「亮度 R + alpha G」→ 解为 (R,R,R,G)
                //    (R 广播到 RGB、G 当 alpha)。曾试过对全体解成 (R,G,0,1) → 精灵变彩色实心块,故只对数据贴图用。
                // ② dataTexture=true(特效辅助槽:waterflow 流向场 R=水平/G=垂直、法线 RG=xy):必须保留**双通道**
                //    → 解为 (R,G,0,255),对齐 lwe 的 GL_RG8,让着色器采 .rg 拿到真实方向矢量。否则 G 被丢进 alpha、
                //    采 .rg 拿到 (R,R)≈(127,127) → 流量≈0 → 屋檐三股水流几乎不流、不向下(实测 3174556087)。
                guard raw.count >= w * h * 2 else { return nil }
                let px = w * h
                var out = [UInt8](repeating: 255, count: px * 4)
                for i in 0..<px {
                    if dataTexture {
                        out[i*4] = raw[i*2]; out[i*4+1] = raw[i*2 + 1]; out[i*4+2] = 0   // (R,G,0,255)
                    } else {
                        let lum = raw[i*2]                                                // (R,R,R,G)
                        out[i*4] = lum; out[i*4+1] = lum; out[i*4+2] = lum
                        out[i*4+3] = raw[i*2 + 1]
                    }
                }
                return finish(out, w, h)
            case 9:        // R8:按用途分流(同 RG88 的 dataTexture 机制)。
                // ① albedo(精灵/图层 g_Texture0):WE ConvertTexture0Format(common_fragment.h:106)铁证 =
                //    vec4(1,1,1,R) → **RGB 恒白、alpha=R**(R 是形状/密度蒙版,颜色全由 v_Color/图层 color 给)。
                //    旧实现 (R,R,R,R) 把 R 也塞进 RGB → 火/烟/碎屑(fire1/fog1/debris1 R8 精灵)被 R 二次压暗、
                //    丢饱和 → 用户报「火焰不像真 WE」。改回 WE 真义:白 RGB + alpha=R(颜色纯由 tint 给)。
                // ② dataTexture=true(特效遮罩 godrays/foliagesway/waterripple_mask、碰撞遮罩):shader 直接采
                //    .r 当遮罩值,不走 ConvertTexture0Format → 必须保留 R 在 R 通道 → (R,R,R,R)。
                //    WP_R8_OPAQUE / WP_NO_R8_ALPHA=1 退回旧 (R,R,R,255)(诊断)。
                guard raw.count >= w * h else { return nil }
                let env9 = WPEnv.vars
                let r8legacy = env9["WP_R8_OPAQUE"] != nil || env9["WP_NO_R8_ALPHA"] != nil
                var out = [UInt8](repeating: 255, count: w * h * 4)
                if dataTexture {
                    for i in 0..<(w * h) { let v = raw[i]; out[i*4] = v; out[i*4+1] = v; out[i*4+2] = v; out[i*4+3] = v }
                } else if r8legacy {
                    for i in 0..<(w * h) { let v = raw[i]; out[i*4] = v; out[i*4+1] = v; out[i*4+2] = v }   // (R,R,R,255)
                } else {
                    for i in 0..<(w * h) { out[i*4 + 3] = raw[i] }   // (255,255,255,R) = WE ConvertTexture0Format
                }
                return finish(out, w, h)
            // --- HDR / 高位深(保守:线性截断到 [0,1] 的 RGBA8,见 HDRFormat 注释)---
            case 10:       // RG1616f
                guard let rgba = HDRFormat.rg1616f(raw, width: w, height: h) else { return nil }
                return finish(rgba, w, h)
            case 11:       // R16f
                guard let rgba = HDRFormat.r16f(raw, width: w, height: h) else { return nil }
                return finish(rgba, w, h)
            case 13:       // RGBa1010102
                guard let rgba = HDRFormat.rgb10a2(raw, width: w, height: h) else { return nil }
                return finish(rgba, w, h)
            case 14:       // RGBA16161616f
                guard let rgba = HDRFormat.rgba16f(raw, width: w, height: h) else { return nil }
                return finish(rgba, w, h)
            case 15:       // RGB161616f
                guard let rgba = HDRFormat.rgb16f(raw, width: w, height: h) else { return nil }
                return finish(rgba, w, h)
            case 12:       // BC7:暂缓(软件 BC7 解码复杂;Apple GPU 不原生支持 BC7)。
                Log.write("  TexDecoder: BC7 (format 12) not yet supported, skipping")
                return nil
            default:
                Log.write("  TexDecoder: unknown format \(format), skipping")
                return nil
            }
        }   // end body()

        return body().map { ($0, flags) }
    }
}

/// LZ4 block 格式解码(无 frame 头)。
enum LZ4 {
    static func decodeBlock(_ src: [UInt8], expectedSize: Int) -> [UInt8]? {
        var out = [UInt8](); out.reserveCapacity(expectedSize)
        var i = 0
        let n = src.count
        while i < n {
            let token = Int(src[i]); i += 1
            var litLen = token >> 4
            if litLen == 15 {
                while i < n { let b = Int(src[i]); i += 1; litLen += b; if b != 255 { break } }
            }
            guard i + litLen <= n else { out.append(contentsOf: src[i..<n]); break }
            out.append(contentsOf: src[i..<(i + litLen)]); i += litLen
            if i >= n { break }
            guard i + 2 <= n else { break }
            let offset = Int(src[i]) | (Int(src[i+1]) << 8); i += 2
            if offset == 0 { return nil }
            var matchLen = token & 15
            if matchLen == 15 {
                while i < n { let b = Int(src[i]); i += 1; matchLen += b; if b != 255 { break } }
            }
            matchLen += 4
            var start = out.count - offset
            if start < 0 { return nil }
            for _ in 0..<matchLen { out.append(out[start]); start += 1 }
        }
        return out
    }
}

/// DXT/S3TC 解码 → RGBA8。Apple Silicon GPU 不原生支持 S3TC,故软件解。
///   bc==1 → BC1 / DXT1(format 7):8字节块,1-bit alpha(c0<=c1 时第4色透明)。
///   bc==2 → BC2 / DXT3(format 6):16字节块,前8字节=16×4-bit **显式** alpha,后8字节=BC1 颜色(始终4色,无1-bit alpha)。
///   bc==3 → BC3 / DXT5(format 4):16字节块,前8字节=2 端点 + 16×3-bit **插值** alpha,后8字节=BC1 颜色。
/// 对齐 reference Render/CTexture.cpp:150-155(DXT5→DXT5_EXT, DXT3→DXT3_EXT, DXT1→DXT1_EXT)。
enum DXT {
    private static func color565(_ c: UInt16) -> (UInt8, UInt8, UInt8) {
        let r = Int((c >> 11) & 0x1F), g = Int((c >> 5) & 0x3F), b = Int(c & 0x1F)
        return (UInt8(r * 255 / 31), UInt8(g * 255 / 63), UInt8(b * 255 / 31))
    }

    static func decode(_ data: [UInt8], width: Int, height: Int, bc: Int) -> [UInt8]? {
        let blockBytes = (bc == 1) ? 8 : 16
        let bw = (width + 3) / 4, bh = (height + 3) / 4
        guard data.count >= bw * bh * blockBytes else { return nil }
        var out = [UInt8](repeating: 0, count: width * height * 4)
        var p = 0
        for by in 0..<bh {
            for bx in 0..<bw {
                var alpha = [UInt8](repeating: 255, count: 16)
                var colorOff = p
                if bc == 2 {
                    // BC2:16 个像素各 4-bit 显式 alpha(小端逐字节,低半字节=偶数像素)。
                    for k in 0..<8 {
                        let byte = data[p + k]
                        alpha[k*2]   = UInt8((Int(byte & 0x0F) * 255) / 15)
                        alpha[k*2+1] = UInt8((Int(byte >> 4)   * 255) / 15)
                    }
                    colorOff = p + 8
                } else if bc == 3 {
                    let a0 = data[p], a1 = data[p+1]
                    var abits: UInt64 = 0
                    for k in 0..<6 { abits |= UInt64(data[p+2+k]) << (8 * k) }
                    var al = [Int](repeating: 0, count: 8)
                    al[0] = Int(a0); al[1] = Int(a1)
                    if a0 > a1 {
                        for k in 1...6 { al[k+1] = ((7-k)*Int(a0) + k*Int(a1)) / 7 }
                    } else {
                        for k in 1...4 { al[k+1] = ((5-k)*Int(a0) + k*Int(a1)) / 5 }
                        al[6] = 0; al[7] = 255
                    }
                    for px in 0..<16 {
                        let idx = Int((abits >> (3 * px)) & 7)
                        alpha[px] = UInt8(al[idx])
                    }
                    colorOff = p + 8
                }
                let c0 = UInt16(data[colorOff]) | (UInt16(data[colorOff+1]) << 8)
                let c1 = UInt16(data[colorOff+2]) | (UInt16(data[colorOff+3]) << 8)
                let bits = UInt32(data[colorOff+4]) | (UInt32(data[colorOff+5]) << 8)
                         | (UInt32(data[colorOff+6]) << 16) | (UInt32(data[colorOff+7]) << 24)
                let (r0, g0, b0) = color565(c0), (r1, g1, b1) = color565(c1)
                var pal = [(UInt8, UInt8, UInt8, UInt8)](repeating: (0,0,0,0), count: 4)
                pal[0] = (r0, g0, b0, 255); pal[1] = (r1, g1, b1, 255)
                // 1-bit alpha 模式只在 BC1 生效;BC2/BC3 颜色块始终用 4 色插值(alpha 来自单独的块)。
                if bc == 1 && c0 <= c1 {
                    pal[2] = (UInt8((Int(r0)+Int(r1))/2), UInt8((Int(g0)+Int(g1))/2), UInt8((Int(b0)+Int(b1))/2), 255)
                    pal[3] = (0, 0, 0, 0)
                } else {
                    pal[2] = (UInt8((2*Int(r0)+Int(r1))/3), UInt8((2*Int(g0)+Int(g1))/3), UInt8((2*Int(b0)+Int(b1))/3), 255)
                    pal[3] = (UInt8((Int(r0)+2*Int(r1))/3), UInt8((Int(g0)+2*Int(g1))/3), UInt8((Int(b0)+2*Int(b1))/3), 255)
                }
                p += blockBytes
                for py in 0..<4 {
                    for px in 0..<4 {
                        let x = bx*4 + px, y = by*4 + py
                        if x < width && y < height {
                            let pix = 4 * py + px
                            let ci = Int((bits >> (2 * pix)) & 3)
                            let (cr, cg, cb, ca) = pal[ci]
                            let o = (y * width + x) * 4
                            out[o] = cr; out[o+1] = cg; out[o+2] = cb
                            out[o+3] = (bc == 1) ? ca : alpha[pix]
                        }
                    }
                }
            }
        }
        return out
    }
}

/// 直接像素格式(无块压缩)→ RGBA8。对齐 reference Texture.h 枚举的位布局。
enum PixelFormat {
    /// RGB888(format 1):每像素 3 字节 R,G,B,无 alpha → 补 255。
    static func rgb888(_ raw: [UInt8], width: Int, height: Int) -> [UInt8]? {
        let px = width * height
        guard raw.count >= px * 3 else { return nil }
        var out = [UInt8](repeating: 255, count: px * 4)
        for i in 0..<px {
            out[i*4]   = raw[i*3]
            out[i*4+1] = raw[i*3+1]
            out[i*4+2] = raw[i*3+2]
        }
        return out
    }

    /// RGB565(format 2):每像素 2 字节小端,RRRRR GGGGGG BBBBB,无 alpha → 补 255。
    static func rgb565(_ raw: [UInt8], width: Int, height: Int) -> [UInt8]? {
        let px = width * height
        guard raw.count >= px * 2 else { return nil }
        var out = [UInt8](repeating: 255, count: px * 4)
        for i in 0..<px {
            let c = UInt16(raw[i*2]) | (UInt16(raw[i*2+1]) << 8)
            let r = Int((c >> 11) & 0x1F), g = Int((c >> 5) & 0x3F), b = Int(c & 0x1F)
            out[i*4]   = UInt8(r * 255 / 31)
            out[i*4+1] = UInt8(g * 255 / 63)
            out[i*4+2] = UInt8(b * 255 / 31)
        }
        return out
    }
}

/// HDR / 高位深格式(保守):lwe 自身的 CTexture.cpp 并不真正上传这些格式(setupInternalFormat 会抛
/// "Cannot determine texture format"),所以它们在 WE 壁纸里几乎只出现在离屏 RT,而非磁盘贴图。
/// 这里仍尽量解出一张可视的 RGBA8(线性截断到 [0,1]),保证不崩、能显示,而非精确 HDR。
enum HDRFormat {
    /// IEEE half(16-bit float)→ Float。
    private static func half(_ h: UInt16) -> Float {
        let sign = Int(h >> 15) & 1
        let exp  = Int(h >> 10) & 0x1F
        let frac = Int(h) & 0x3FF
        let s: Float = sign == 1 ? -1 : 1
        if exp == 0 {
            return s * Float(frac) * (1.0 / 1024.0) * (1.0 / 16384.0)   // subnormal: 2^-24 * frac
        } else if exp == 0x1F {
            return frac == 0 ? s * Float.infinity : Float.nan
        }
        return s * Float(frac == 0 ? 1.0 : 1.0 + Float(frac) / 1024.0) * powf(2, Float(exp - 15))
    }

    private static func clampByte(_ v: Float) -> UInt8 {
        if v.isNaN { return 0 }
        let c = max(0, min(1, v))
        return UInt8(c * 255 + 0.5)
    }

    /// R16f(format 11):每像素 1×half → (R,R,R,1)。
    static func r16f(_ raw: [UInt8], width: Int, height: Int) -> [UInt8]? {
        let px = width * height
        guard raw.count >= px * 2 else { return nil }
        var out = [UInt8](repeating: 255, count: px * 4)
        for i in 0..<px {
            let r = clampByte(half(UInt16(raw[i*2]) | (UInt16(raw[i*2+1]) << 8)))
            out[i*4] = r; out[i*4+1] = r; out[i*4+2] = r
        }
        return out
    }

    /// RG1616f(format 10):每像素 2×half(R,G) → (R,G,0,1)。
    static func rg1616f(_ raw: [UInt8], width: Int, height: Int) -> [UInt8]? {
        let px = width * height
        guard raw.count >= px * 4 else { return nil }
        var out = [UInt8](repeating: 255, count: px * 4)
        for i in 0..<px {
            let r = half(UInt16(raw[i*4])   | (UInt16(raw[i*4+1]) << 8))
            let g = half(UInt16(raw[i*4+2]) | (UInt16(raw[i*4+3]) << 8))
            out[i*4] = clampByte(r); out[i*4+1] = clampByte(g); out[i*4+2] = 0
        }
        return out
    }

    /// RGBA16161616f(format 14):每像素 4×half → (R,G,B,A)。
    static func rgba16f(_ raw: [UInt8], width: Int, height: Int) -> [UInt8]? {
        let px = width * height
        guard raw.count >= px * 8 else { return nil }
        var out = [UInt8](repeating: 0, count: px * 4)
        for i in 0..<px {
            for c in 0..<4 {
                out[i*4+c] = clampByte(half(UInt16(raw[i*8 + c*2]) | (UInt16(raw[i*8 + c*2 + 1]) << 8)))
            }
        }
        return out
    }

    /// RGB161616f(format 15):每像素 3×half → (R,G,B,1)。
    static func rgb16f(_ raw: [UInt8], width: Int, height: Int) -> [UInt8]? {
        let px = width * height
        guard raw.count >= px * 6 else { return nil }
        var out = [UInt8](repeating: 255, count: px * 4)
        for i in 0..<px {
            for c in 0..<3 {
                out[i*4+c] = clampByte(half(UInt16(raw[i*6 + c*2]) | (UInt16(raw[i*6 + c*2 + 1]) << 8)))
            }
        }
        return out
    }

    /// RGBa1010102(format 13):每像素 1×u32 小端,R10 G10 B10 A2(低位起 R)→ (R,G,B,A)。
    static func rgb10a2(_ raw: [UInt8], width: Int, height: Int) -> [UInt8]? {
        let px = width * height
        guard raw.count >= px * 4 else { return nil }
        var out = [UInt8](repeating: 255, count: px * 4)
        for i in 0..<px {
            let v = UInt32(raw[i*4]) | (UInt32(raw[i*4+1]) << 8)
                  | (UInt32(raw[i*4+2]) << 16) | (UInt32(raw[i*4+3]) << 24)
            let r = Int(v & 0x3FF), g = Int((v >> 10) & 0x3FF), b = Int((v >> 20) & 0x3FF), a = Int((v >> 30) & 0x3)
            out[i*4]   = UInt8(r * 255 / 1023)
            out[i*4+1] = UInt8(g * 255 / 1023)
            out[i*4+2] = UInt8(b * 255 / 1023)
            out[i*4+3] = UInt8(a * 255 / 3)
        }
        return out
    }
}
