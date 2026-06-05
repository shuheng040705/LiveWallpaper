# Wallpaper Engine "scene" Wallpaper Format — Implementation Spec

For a native Swift/Metal renderer. Every byte layout / field / enum below was verified against real
files under Steam appid 431960 (Wallpaper Engine) on this machine.

Verification tags:
- [V]        verified this session by parsing real bytes / decoding real data.
- [V-survey] verified by aggregating over all 43 scene.pkg (470 materials, 418 .tex).
- [I]        strong inference from structure, not fully byte-proven.
- [?]        uncertain / not fully cracked; flagged for follow-up.

================================================================================
## 0. Environment reality check  [V]
================================================================================
ROOT = /Users/a55555/Library/Application Support/CrossOver/Bottles/Steam/drive_c/Program Files (x86)/Steam/steamapps/workshop/content/431960

- The requested sample ROOT/3504284734/ DOES NOT EXIST. There are NO pre-unpacked scene folders at
  all (0 dirs contain scene/ materials/ textures/). Everything is packed in scene.pkg.
- 108 workshop items: 43 are scene wallpapers (have scene.pkg); the rest are video (.mp4),
  web/spine (index.html), etc.
- A scene wallpaper folder contains: scene.pkg (all logic+assets+textures), project.json (metadata
  wrapper), preview.{jpg,gif}, and OPTIONALLY .cach/ (compiled shaders + ASTC cache). 16/108 have .cach/.
- Working sample used: ROOT/3713659808/ (1 image layer + effects + particles + text; has .cach/).
  Other samples: 3302695207, 2983345987, 3459341124, 3497756108, 3600080989, 1184092135.

================================================================================
## 1. scene.pkg container format  [V-survey: 43/43 pass]
================================================================================
Flat uncompressed archive: header, entry table, contiguous payload blob. ALL integers are signed
int32 little-endian. Strings are int32-length-prefixed UTF-8, NO NUL terminator. Payloads are stored
verbatim (the container does not compress entries; individual .tex may be internally compressed §4).

  offset  type            field
  0       i32             magicLen                 (= 8 in all files)
  4       char[magicLen]  magic                    ASCII "PKGV00xx"
  +       i32             entryCount
          --- entry table, entryCount times ---
          i32             nameLen
          char[nameLen]   name                     UTF-8, '/'-separated (e.g. "materials/rock.json")
          i32             offset                   payload start, RELATIVE to dataBase
          i32             size                     payload length
          --- end table ---
  dataBase = file position right after the last entry record
          --- payload blob: raw bytes, contiguous, in entry order ---
          file[i] = bytes[dataBase + offset_i : dataBase + offset_i + size_i]

Verified:
- magic versions present: PKGV0018, 0020, 0021, 0022, 0023. The version does NOT change the layout;
  one parser reads all. [V-survey]
- offset is relative to dataBase (NOT absolute, NOT from file start). First entry offset = 0. [V]
- Invariant dataBase + lastEntry.offset + lastEntry.size == fileSize holds for ALL 43 pkgs, no gaps,
  no padding. [V-survey]
- Example 3713659808/scene.pkg: magic=PKGV0023, entryCount=59, dataBase=2971, fileSize=5826135,
  invariant exact; extracted scene.json (27051 B) -> json.loads OK. [V]
- Entry dirs: materials/ models/ effects/ shaders/ particles/ fonts/ shapes/(rare), scene.json at
  root, nested workshop/<id>/...  Extensions inside pkg: .json .tex .vert .frag .otf .png(rare). [V]

Reference parser (Python, verified; translate to Swift):

  import struct
  def parse_pkg(path):
      d = open(path, "rb").read(); p = 0
      (mlen,)  = struct.unpack_from("<i", d, p); p += 4
      magic    = d[p:p+mlen].decode("ascii"); p += mlen
      (count,) = struct.unpack_from("<i", d, p); p += 4
      entries = []
      for _ in range(count):
          (nlen,) = struct.unpack_from("<i", d, p); p += 4
          name    = d[p:p+nlen].decode("utf-8"); p += nlen
          (off,)  = struct.unpack_from("<i", d, p); p += 4
          (size,) = struct.unpack_from("<i", d, p); p += 4
          entries.append((name, off, size))
      base = p
      return {n: d[base+o:base+o+s] for n, o, s in entries}

Swift: read file into Data; Int32 LE via withUnsafeBytes { $0.loadUnaligned(fromByteOffset: p, as: Int32.self) }.

================================================================================
## 2. scene.json structure  [V on 3713659808, cross-checked]
================================================================================
Top-level keys: camera, general, objects, version.  version = 5 (also 4 seen).

### 2.1 camera  [V]
  { "center":"0 0 -1", "eye":"0 0 0", "up":"0 1 0" }   (three vec3 strings, space-separated floats)
Default look-down-(-Z); combined with general.orthogonalprojection it is an orthographic camera.

### 2.2 general  [V]  (vec3/color are space-separated strings; rest are number/bool)
  orthogonalprojection : {"width":2560,"height":1440}   <- scene design resolution (ints)
  clearcolor           : "0.7 0.7 0.7"     clearenabled: true
  ambientcolor, skylightcolor : "0.3 0.3 0.3"
  fov:50  nearz:0.0099999998  farz:10000  zoom:1.0  perspectiveoverridefov:90
  camerafade, camerapreview (bool); cameraparallax(true)+amount/delay/mouseinfluence
  camerashake(bool)+amplitude/roughness/speed
  bloom(false)+strength/threshold/tint; bloomhdr feather/iterations/scatter/strength/threshold
  hdr(false)
  gravitydirection "0 -1 0", gravitystrength 1.0; winddirection "0.707 0.707 0", windenabled, windstrength
For Phase A only orthogonalprojection (canvas size) and clearcolor matter; bloom/hdr are global PP, ignore.

### 2.3 objects[] — layers  [V]
Discriminate layer type by which content key is present:
  image layer    : has "image"   (+ usually "size")
  particle layer : has "particle"
  text layer     : has "text"     (+ font, pointsize, align...)
  shape layer    : has "shape"     (value e.g. "quad")
  (light layer: not present in these 43 samples; structure unknown [?])

Common fields: id(int,unique), name, origin("x y z"), angles("x y z" euler deg), scale("x y z"),
parent(int id or absent), parallaxDepth("x y"), visible(bool; absent => true), castshadow, clampuvs,
disablepropagation, locktransforms, solid (bools), effects[] (§2.4).

IMAGE layer — full field set [V] (object 0 of sample):
  { "id":61, "name":"Image_294794726763801",
    "image":"models/Image_294794726763801.json",   <- points to a MODEL json (NOT the tex directly)
    "size":"2048 3072",                             <- quad size in scene units (w h)
    "origin":"1279.58 -268.69 0", "scale":"1.28385 1.28385 1.28385",
    "parallaxDepth":"0 0",                          <- per-layer parallax response (x y)
    "angles":"0 0 0",                               (present on some image layers)
    "visible":true,                                 (absent => true)
    "castshadow":false, "clampuvs":true, "disablepropagation":false,
    "effects":[ ... ] }
Layer->texture chain (VERIFIED):
  object.image  ->  models/<x>.json  {"material":"materials/<x>.json","autosize":true}
                ->  materials/<x>.json  passes[0].textures[0] = base name "Foo"
                ->  the pkg entry  materials/Foo.tex
  autosize:true => quad takes the texture's pixel size. Color/alpha/blend come from the MATERIAL
  pass (§3), not the object. [V]

PARTICLE layer [V] (object 3):
  { "id":711, "name":"...", "particle":"particles/presets/fog1.json",
    "origin":..,"angles":..,"scale":..,"parent":17, "solid":true,
    "instanceoverride":{"id":712,"alpha":0.61,"size":1.91} }

SHAPE layer [V] (object 2) — procedural quad used as an effect surface:
  { "id":99, "name":"...", "shape":"quad", "origin":..,"angles":..,"scale":..,"parent":17,
    "parallaxDepth":"0 0", "castshadow":false,"clampuvs":true,
    "effects":[ {"file":"effects/lightshafts/effect.json", ...} ] }

TEXT layer [V] (object 4) keys: text, font, pointsize, color, brightness, anchor, horizontalalign,
verticalalign, blockalign, backgroundcolor, backgroundbrightness, opaquebackground, padding,
maxwidth/maxrows/limit*, depthtest + transforms. (Ignorable for Phase A.)

### 2.4 effects[] on a layer  [V]
  { "file":"effects/foliagesway/effect.json", "id":20, "name":"", "visible":true,
    "passes":[                                   <- per-pass OVERRIDES (parallel to effect.json)
      { "id":21,
        "constantshadervalues":{ "strength":0.42, "speeduv":6.14, ... },  <- uniform values
        "combos":{ "VERTICAL":1 },                                        <- #define overrides
        "textures":[ null, "masks/foliagesway_mask_b0c38454", null ] }    <- per-slot tex binds
    ] }
textures[] entries are base names (no extension); null = keep default/framebuffer. They resolve to
materials/<name>.tex in the pkg. [V]

================================================================================
## 3. model JSON & material JSON  [V + V-survey over 470 materials]
================================================================================
model JSON (models/*.json) [V]:
  { "autosize":true, "material":"materials/Image_294794726763801.json" }      (just a pointer)

material JSON (materials/*.json) [V]:
  { "passes":[
      { "shader":"genericimage4",                 <- shader base name (§5)
        "textures":["201 卡提希娅"],              <- ordered sampler binds (base names) -> g_Texture{i}
        "blending":"translucent",                 <- enum (below)
        "cullmode":"nocull",                      <- enum
        "depthtest":"disabled",                   <- enum (always disabled in samples)
        "depthwrite":"disabled",                  <- enum (always disabled)
        "combos":{"LIGHTING":0,"REFLECTION":0},   <- #define name->int, selects shader variant
        "constantshadervalues":{...},             <- uniform defaults (optional)
        "alphawriting":"default" }                <- optional
  ] }
Material = ordered list of passes; each pass = one shader + textures + render state + combos.
textures[i] -> sampler g_Texture{i}.  [V]

Enum value sets (VERIFIED across all 470 materials) [V-survey]:
  blending  : normal(227), translucent(194), additive(49)
              translucent = standard alpha-over; additive = src+dst; normal = opaque/replace
              (effect passes that overwrite the framebuffer). [I on exact math]
  cullmode  : nocull(467), normal(3)
  depthtest : disabled(470/470)
  depthwrite: disabled(470/470)
  alphawriting: default (when present)
  Other pass keys seen: combos, constantshadervalues, textures, usertextures(1).
  Material top-level only ever has "passes".

effect definition JSON (effects/<name>/effect.json) [V] — a mini render-graph:
  { "version":1, "replacementkey":"blur", "group":"blur", "performance":"expensive",
    "passes":[
      { "material":"materials/effects/blur_downsample4.json",
        "target":"_rt_QuarterCompoBuffer1",                <- output FBO (absent = backbuffer)
        "bind":[ {"name":"previous","index":0} ] },        <- inputs by FBO/keyword name+slot
      ... ],
    "fbos":[ {"name":"_rt_QuarterCompoBuffer1","scale":4,"format":"rgba_backbuffer"}, ... ],
    "dependencies":[ "materials/...","shaders/..." ] }
"previous" = the layer's current result; fbos[].scale = downscale factor. This is the post-processing
system. IGNORABLE for Phase A. [V]

================================================================================
## 4. Texture format .tex  [V byte-exact + V-survey on 418 textures]
================================================================================
.tex files live INSIDE scene.pkg (e.g. materials/201 卡提希娅.tex). Three nested NUL-terminated
ASCII magics, header ints, then an image/mip container. ALL ints int32 LE.

  0    NT-string  magic1 = "TEXV0005\0"     container format version (0005 in all 418)
  +    NT-string  magic2 = "TEXI0001\0"     image header magic (0001 in all 418)
  +    i32        format                    pixel format enum (table below)
  +    i32        flags                     bitfield; commonly 2 (384x), also 0 (31x), 6 (3x)
  +    i32        textureWidth              padded/POT texture width  (e.g. 2048)
  +    i32        textureHeight             padded/POT texture height (e.g. 3072)
  +    i32        imageWidth                actual image px width      (== mip0 width)
  +    i32        imageHeight               actual image px height
  +    i32        unkInt0                   varies; ignorable
  +    NT-string  magic3 = "TEXB000x\0"     MIPMAP container version: 0002 / 0003 / 0004
  +    i32        imageCount                (= 1 in all 418 samples; >1 would be array/cube)
       --- per image, imageCount times ---
  +    i32        mipCount                  number of mip levels; CAN be -1 (=> "auto"/unknown,
                                            treat as: read mips until payload is consumed)
  +    (i32       unkImage0)                ONLY present when magic3 == TEXB0004 (value 0)   <-- VERSION DIFF
  +    i32        freeImageType             FreeImage codec hint (see notes)
         --- per mip, mipCount times ---
  +    i32        mipWidth
  +    i32        mipHeight
  +    i32        isCompressed              0 = stored raw, 1 = compressed (codec depends on TEXB ver)
  +    i32        sizeUncompressed          decompressed byte size (0 for free-image PNG/JPG)
  +    i32        sizeCompressed            length of the data blob that follows
  +    byte[sizeCompressed]  data

IMPORTANT version difference (VERIFIED) [V]:
  TEXB0004 has an extra int (value 0) BETWEEN mipCount and freeImageType (the per-image preamble is
  [unkImage0=0, freeImageType] = 2 ints). TEXB0003/0002 have only [freeImageType] = 1 int.
  After that, each mip record is the SAME 5 ints [w, h, isCompressed, sizeUncompressed, sizeCompressed]
  for both versions. (Earlier confusion came from mis-placing these per-image ints as per-mip.)
  Verified: 132 free-image textures (PNG/JPG, fmt0) parse to EXACT EOF including multi-mip pyramids
  (e.g. 赞助 fmt0/v4: mip0 1000x471 PNG 261797B, mip1 500x235, mip2 250x117 — consumed == total;
  2k bg fmt0/v3: 2560x1440,1280x720,...,320x180 — consumed == total;
  201 卡提希娅 fmt0/v4: 2048x3072,...,128x192 — consumed == total). [V]

mip0 (the only level Phase A needs) is extracted correctly for ALL 418 textures regardless of
version/format (its w/h/isC/szU/szC are always right). [V-survey]

### Compression codec — depends on magic3 (TEXB) version  [V / V-survey]
- TEXB0004: compressed blobs are LZ4 BLOCK (data starts 04 00 ...). VERIFIED by decoding two masks
  with a hand-written LZ4-block decoder to EXACT sizeUncompressed (1920x1080 RG8 -> 4,147,200 B;
  272x440 R8 -> 119,680 B). [V]  (Swift: any LZ4 block decompressor; pass the known dst size.)
- TEXB0003: compressed blobs are DEFLATE/zlib for the common case (data starts 78 9c) and decode with
  zlib.decompress. NOTE: for some multi-mip GPU masks the single-blob zlib over the whole-texture
  sizeUncompressed did not round-trip in my quick test — those textures split data across mips and
  need a full per-mip walk; single-mip v3 textures (e.g. iris_mask fmt9 544x720 -> 391,680 B) decode
  cleanly. [V for single-mip; multi-mip GPU pyramid not fully cracked [?]]
- TEXB0002: 1 sample only (old free image); its per-image layout differs and was not decoded. [?]
- isCompressed == 0: blob is the raw image as-is (free-image PNG/JPG, or raw pixels — see fmt0 note).

### format enum — VERIFIED by exact integer pixel-size match over 418 textures  [V-survey]
  format | meaning                                  | bytes/px | count | evidence
  -------+------------------------------------------+----------+-------+-------------------------------
    0    | FREE IMAGE: blob is usually a full PNG    |   n/a    | 158   | extracted real 2048x3072 PNG
         | (89 50 4E 47) or JPG (FF D8); BUT 25 of   |          |       | (3,844,777 B, valid IEND) [V];
         | these are RAW pixels, not an encoded file |          |       | 113 PNG + 19 JPG + 25 raw/other
         | (e.g. waterripplenormal/waterflowphase)   |          |       | (those use freeImageType!=PNG/JPG)
    4    | RGBA8 (32-bit)                            |   4.0    |  19   | szU == w*h*4 (19/19)
    6    | RGBA8 (variant; decodes same)             |   4.0    |   2   | szU == w*h*4
    7    | RG8 / LA8 (2-channel)                     |   2.0    |  16   | szU == w*h*2
    8    | RG8 / LA8 (2-channel)                     |   2.0    |  93   | szU == w*h*2 (flow/shake masks)
    9    | R8 / A8 (single channel)                  |   1.0    | 130   | szU == w*h*1 (130/130, opacity masks)
  (For format 0, sniff the blob: PNG/JPG magic => encoded; else raw pixels per freeImageType. [V])
  freeImageType seen: 3 and 5 (PNG variants), 4, 1 (non-free). Treat fmt0 by blob magic. [I]

NOTABLE: NO block-compressed (DXT/BC/ASTC) textures exist inside any scene.pkg here. All GPU textures
are plain RGBA8/RG8/R8 wrapped in zlib(v3)/LZ4(v4). The LAYER base images are format 0 (PNG/JPG) —
the easy case. The non-free formats are dominated by effect masks. [V-survey]

### Verified mip0 extractor (Python; for the common format-0 base art) [V]
  def tex_first_mip(blob):
      import struct
      def nt(b,p): e=b.index(0,p); return b[p:e].decode('latin1'), e+1
      p=0; m1,p=nt(blob,p); m2,p=nt(blob,p)                 # TEXV0005, TEXI0001
      fmt,flags,tw,th,iw,ih,unk = struct.unpack_from("<7i",blob,p); p+=28
      m3,p=nt(blob,p); ver=int(m3[-1])                      # TEXB000x
      imageCount = struct.unpack_from("<i",blob,p)[0]; p+=4
      mipCount   = struct.unpack_from("<i",blob,p)[0]; p+=4
      if ver>=4: p+=4                                       # unkImage0 (TEXB0004 only!)
      freeType   = struct.unpack_from("<i",blob,p)[0]; p+=4
      w,h,isC,szU,szC = struct.unpack_from("<5i",blob,p); p+=20
      data = blob[p:p+szC]
      return fmt, ver, w, h, isC, szU, data                 # fmt0+PNG/JPG: data is the image file

Decode rules:
  - fmt 0 & data[:4]==PNG or data[:2]==JPG  -> hand to MTKTextureLoader/CGImageSource. Phase A done.
  - fmt 0 & raw                              -> raw pixels (rare; effect normals). skip for Phase A.
  - fmt 4/6, isC -> zlib(v3)/LZ4(v4) decompress -> raw RGBA8 -> MTLTexture .rgba8Unorm.
  - fmt 8 -> .rg8Unorm (2bpp);  fmt 9 -> .r8Unorm (1bpp), after the same decompress.

### .cach/ ASTC files — pre-decoded GPU textures  [V]
Some items cache ASTC copies under .cach/textures/ or .cach/astc/, named <sha256>_astc_<NxN>.astc
(block 4x4 or 8x8). These are STANDARD .astc container files: magic 0x5CA1AB13, byte4..6 = block
dims, byte7..15 = 3x 24-bit-LE image dims, then raw ASTC blocks. VERIFIED payload ==
ceil(w/bx)*ceil(h/by)*16 exactly (5760x3240 @8x8 -> 4,665,600 B; 1024x2048 @4x4 -> 2,097,152 B;
3840x2504 @8x8 -> 2,403,840 B). Directly loadable as MTLPixelFormat .astc_4x4_ldr / .astc_8x8_ldr.
CAVEAT: the sha256 filename is a content hash, NOT the scene base name, so mapping .astc back to a
layer needs WE's asset-cache index (absent here). For Phase A, decoding the format-0 PNG from the pkg
is simpler and unambiguous. [V]

.cach/ also has (when present):
  shaders/manifest.json = { "objects": { "<objectId>": ["<shaderSha256>", ...] } }  -> maps a scene
       object id to the compiled-shader-cache hashes it uses. [V]
  shaders/setting.json  = { "shaders": [] }. [V]

================================================================================
## 5. Shaders  [V]
================================================================================
WE ships shaders as RAW GLSL source inside the pkg (shaders/**/*.vert, *.frag) in its own
preprocessor dialect, and separately caches COMPILED Metal + preprocessed GLSL under .cach/.

### 5.1 In-pkg raw GLSL (source of truth) [V]
Example shaders/effects/shimmer.frag (2815 B):
  - // [COMBO] {json} directives declaring combo variants & UI metadata
  - #include "common.h", #include "common_blending.h"  (WE builtin virtual includes, not in pkg)
  - uniform sampler2D g_Texture0; // {json}   (sampler slots w/ metadata: "material":"framebuffer",
    "mode":"opacitymask", "combo":"MASK", ...)
  - HLSL-ish macros: texSample2D, mul, frac, saturate, CAST3, rotateVec2, ApplyBlending
  - #if MASK / #if MODE==1 / #endif combo branches; writes gl_FragColor
The base image shaders (genericimage4, genericimage2, genericparticle) are NOT in the pkg — they are
WE builtins; only effect/workshop shaders are bundled. [V]

### 5.2 .cach compiled Metal (MSL), transpiled via SPIRV-Cross [V]
.cach/shaders/<sha256>.metal. Example = genericimage4 fragment (FULL FILE, 673 B):

  // Source: shaders/genericimage4.frag
  // Stage: fragment
  // Defines:
  //   FOG = 1  GLSL = 1  HLSL = 0  LIGHTING = 0  REFLECTION = 0
  #include <metal_stdlib>
  #include <simd/simd.h>
  using namespace metal;
  struct main0_out { float4 glOutColor [[color(0)]]; };
  struct main0_in  { float2 v_TexCoord [[user(locn0)]]; };
  fragment main0_out main0(main0_in in [[stage_in]],
          constant float4& g_Color4 [[buffer(0)]],
          texture2d<float> g_Texture0 [[texture(0)]], sampler g_Texture0Smplr [[sampler(0)]])
  {
      main0_out out = {};
      float4 color = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord) * g_Color4;
      out.glOutColor = color;
      return out;
  }

Paired vertex (genericimage2.vert -> ba901b81....metal, FULL):

  // Source: shaders/genericimage2.vert  Stage: vertex
  struct main0_out { float2 v_TexCoord [[user(locn0)]]; float4 gl_Position [[position]]; };
  struct main0_in  { float3 a_Position [[attribute(0)]]; float2 a_TexCoord [[attribute(1)]]; };
  vertex main0_out main0(main0_in in [[stage_in]],
          constant float4x4& g_ModelViewProjectionMatrix [[buffer(0)]])
  {
      main0_out out = {};
      out.v_TexCoord = in.a_TexCoord;
      out.gl_Position = g_ModelViewProjectionMatrix * float4(in.a_Position, 1.0);
      return out;
  }

Conventions: entry point always main0; buffer(0) = MVP (vert) / g_Color4 (frag); texture(0)/sampler(0)
= g_Texture0. Header comments record // Source: and resolved // Defines: per permutation. [V]

### 5.3 .cach/shaders/preprocessed/<sha256>.{vert,frag}.glsl [V]
Fully-preprocessed desktop GLSL (#version 330, all macros/#defines expanded, includes inlined).
genericimage4.frag.glsl (35 KB) opens with the WE macro prelude (#define texSample2D texture;
#define mul(x,y) ((y)*(x)); #define saturate(x) clamp(x,0,1); ...) and ends in main() writing
gl_FragColor. GLSL equivalent of the cached Metal. [V]

### 5.4 Coexistence & reuse assessment
- GLSL (raw, in pkg) AND Metal (compiled, in .cach) BOTH exist, for DIFFERENT shaders: pkg has
  effect/workshop GLSL; .cach has compiled Metal for whatever that wallpaper used (incl. builtins
  genericimage*). They overlap by purpose, not file. [V]
- Reusing .cach .metal directly is VIABLE for Phase A for the trivial generics (genericimage4 frag =
  sample * color). Risks:
    1. .cach exists for only 16/108 items and contains only the permutations THAT item compiled
       (specific combo defines). Not a complete shader set; cannot rely on it for an arbitrary
       wallpaper. [V]
    2. Filenames are sha256(source+defines); to pick the right .metal read the // Source://Defines:
       header or use manifest.json — no name index. [V]
    3. MSL uses SPIRV-Cross conventions (explicit [[buffer/texture/sampler]] indices, main0). Compile
       with device.makeLibrary(source:); feed matching argument-table indices.
    4. Beyond genericimage you will need to compile WE's GLSL yourself (resolve // [COMBO], supply
       common.h) or port shaders by hand. The cache won't cover it.
- RECOMMENDATION: for Phase A, hand-write a 2-line Metal shader (texture.sample * color). Keep the
  cached .metal as a reference/validation oracle.

================================================================================
## 6. Phase A — minimal path to display one image layer statically
================================================================================
Goal: draw the bottom image layer of a scene as a static textured quad.

1. parse_pkg("scene.pkg") (§1) -> dict name->bytes. [V]
2. Parse scene.json (§2). Read general.orthogonalprojection -> canvas (W,H) and clearcolor.
3. Pick base layer: from objects[], take image layers (have "image"), skip visible:false. Background
   is typically the first image object / the one with largest size and parallaxDepth ~ 0. Read its
   origin, size, scale, angles.
4. Resolve its texture (§2.3): object.image -> models/X.json -> material.passes[0].textures[0] base
   name -> pkg entry materials/<name>.tex. Read pass blending (translucent => alpha-over) and any
   constantshadervalues color (default white). [V]
5. Decode the texture with tex_first_mip() (§4):
     - format 0 (158/418, the common case) & PNG/JPG blob -> MTKTextureLoader.newTexture(data:) or
       CGImageSource. DONE. Byte-verified to be a valid standalone image. [V]  <== SIMPLEST ROUTE
     - format 4/6 -> decompress (zlib v3 / LZ4 v4) -> raw RGBA8 -> MTLTexture .rgba8Unorm.
       fmt8 -> .rg8Unorm; fmt9 -> .r8Unorm.
     - If avoiding .tex AND item has .cach/: the .astc files are standard ASTC, directly loadable as
       .astc_4x4_ldr/.astc_8x8_ldr — but hash->layer mapping is painful (§4); prefer pkg .tex. [V]
6. Geometry: unit quad. Model matrix = translate(origin) * rotate(angles, usually 0) * scale(scale) *
   size (quad is size.x by size.y centered at origin). [I]
7. Camera: orthographic sized to orthogonalprojection (W x H), looking down -Z (camera.eye/center/up
   is identity-ish). Map scene units 1:1 to the ortho box (WE places objects in a pixel-like space
   matching the design resolution). [I]
8. Pipeline: trivial Metal — vertex multiplies quad by MVP, passes UV; fragment samples texture *
   constant color (mirror genericimage4 §5.2). Blend from material: translucent => srcAlpha/
   1-srcAlpha; additive => one/one; depthtest/write disabled (always); cull none. Clear to clearcolor.
   Draw layers back-to-front in objects[] order. [I on ordering]

SMALLEST-RISK SUBSET: steps 1-5 with format-0 textures gets pixels on screen. Most scene wallpapers'
base art is format 0 (PNG/JPG) [113 PNG + 19 JPG of 158 fmt0 across the set], so a renderer doing
pkg -> scene.json -> material -> format-0 .tex -> PNG -> textured ortho quad displays the majority of
these wallpapers' base layers with NO LZ4/zlib/ASTC and NO shader-cache dependency. [V]

================================================================================
## 7. Open items / uncertainties
================================================================================
- light layer structure: none in these 43 samples; unspecified. [?]
- TEXI flags (2 vs 0 vs 6): correlates with clamp/mip but not needed to decode. [?]
- format 6 vs 4 (both RGBA8) and 7 vs 8 (both RG8): likely sRGB/linear or normal-map hint; treat by
  channel count for upload, refine later. [I]
- Multi-mip GPU pyramids (mipCount==-1) in TEXB0003/0004: mip0 is correct; full per-mip walk for
  compressed pyramids not fully cracked (single-mip + all free-image multi-mip DO round-trip). Not
  Phase-A-blocking. [?]
- TEXB0002 (1 sample) free-image layout differs; not decoded. [?]
- format 0 "raw" subtype (25 textures, e.g. waterripplenormal/waterflowphase) carries raw pixels not
  an encoded file; sniff blob magic before handing to an image loader. [V]
- Scene-unit -> ortho-box scale (step 7) assumed 1:1 with design resolution; verify visually after
  first layer renders. [I]
- Mapping .cach/*.astc (sha256) back to a layer needs WE's global asset cache DB, absent here. [?]

================================================================================
## Appendix: verified aggregate counts
================================================================================
- 43 scene.pkg, all parse; magics PKGV0018/0020/0021/0022/0023; invariant 43/43. [V-survey]
- 470 materials: blending {normal 227, translucent 194, additive 49}; cullmode {nocull 467, normal 3};
  depthtest/depthwrite all "disabled". Top shaders: genericimage4(153), genericparticle(78),
  effects/shake(25), effects/foliagesway(18), effects/waterflow(11), genericimage2(11),
  effects/godrays_gaussian(10), effects/waterwaves(8), effects/waterripple(7), effects/iris(6),
  effects/opacity(6), effects/blur_gaussian(6), ... [V-survey]
- 418 .tex: format {0:158, 9:130, 8:93, 4:19, 7:16, 6:2}; magic1 TEXV0005 (418/418);
  magic2 TEXI0001 (418/418); magic3 {TEXB0004:257, TEXB0003:160, TEXB0002:1}. [V-survey]
- format 0 blobs: 113 PNG + 19 JPG (encoded) + 25 raw/other (=158). [V-survey]
- Codec: TEXB0004 = LZ4 block (verified exact on samples); TEXB0003 = zlib (single-mip verified). [V]
- ASTC cache files: standard 0x5CA1AB13 container, directly loadable; payload sizes exact. [V]
