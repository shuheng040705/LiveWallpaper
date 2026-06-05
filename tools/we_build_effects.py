#!/usr/bin/env python3
"""
WE effect 打包器:把全库 scene 用到的 effect 的真实着色器转译成 Metal + 生成 manifest,
供引擎的多 pass 特效合成器消费。

每个 effect 读 effect.json 的 passes;每个 pass 经 material → shader(effects/<name>),
转译 vert+frag → MSL(各自一个 MTLLibrary,入口 main0,避免结构名冲突),
spirv-cross --reflect 出 uniform 布局(name/offset/type)+ sampler binding。

输出:
  Tools/generated/we_effects/<shader>__<stage>.metal   每个 (shader,stage) 一份 MSL
  Tools/generated/WEEffects.json                        manifest(effect→passes→{shader,target,binds,vs/fs:{metal,uniforms,samplers}})
"""
import sys, os, json, subprocess, tempfile, glob, struct
sys.path.insert(0, os.path.dirname(__file__))
import we_transpile as T

WE = os.path.expanduser("~/Library/Application Support/CrossOver/Bottles/Steam/drive_c/Program Files (x86)/Steam/steamapps/common/wallpaper_engine/assets")
WORKSHOP = os.path.expanduser("~/Library/Application Support/CrossOver/Bottles/Steam/drive_c/Program Files (x86)/Steam/steamapps/workshop/content/431960")
SHARED_SHADERS = os.path.join(WE, "shaders")   # 全局共享 shader 目录($WE/shaders/<base>.vert)
OUT = os.path.join(os.path.dirname(__file__), "generated")
MSL_DIR = os.path.join(OUT, "we_effects")

# 原先只列「全库实测用到的」effect(省构建)。现改为转译**全部**内置 effect(用户要求补全):
# 自动发现 $WE/effects 下所有 effect(排除 _empty 占位)。转译失败的会被记进
# WEEffects.fail.json 并大声报错,不影响其余 manifest 生成。
USED = sorted(d for d in os.listdir(os.path.join(WE, "effects"))
              if os.path.isdir(os.path.join(WE, "effects", d)) and d != "_empty")

import re

# WE 的 effect.json / material 是**宽松 JSON**:常带尾随逗号(如 `"...vert",\n],`),
# 标准 json 解析会报 "Expecting value" 直接崩。原 USED 白名单里那 28 个恰好 JSON 干净,
# 所以一直没踩到;补全全部内置 effect 时 fluidsimulation 等就崩了。这里在标准解析失败时
# **仅**去掉 } / ] 前的尾逗号后重试(不动注释,避免误伤字符串里的 // 或 http://)。
#
# 审计修复 #5:旧实现 `re.sub(r',(\s*[}\]])', r'\1', text)` 会**误删字符串值里**的尾逗号——
# 若某字符串内容形如 `"a,]"` / `"foo, }"`,正则不区分引号内外,会把字符串里的 `,` 连同其后的
# `]`/`}` 误判成尾逗号删掉,破坏数据。改为**字符串感知**扫描:逐字符跟踪是否在字符串内
# (处理 \ 转义),仅在**字符串外**遇到「逗号 + 可选空白 + } 或 ]」时丢弃该逗号;字符串内的任何
# 字符(含 `,`/`]`/`}`/引号转义)原样保留。对干净 JSON 是恒等(无字符串外尾逗号),零影响。
def _strip_trailing_commas(text):
    out = []
    i, n = 0, len(text)
    in_str = False
    while i < n:
        c = text[i]
        if in_str:
            out.append(c)
            if c == '\\' and i + 1 < n:      # 转义序列:原样保留下一个字符(含 \" \\ 等)
                out.append(text[i + 1]); i += 2; continue
            if c == '"':
                in_str = False
            i += 1
            continue
        if c == '"':
            in_str = True; out.append(c); i += 1; continue
        if c == ',':
            # 向后看跳过空白:若紧接 } 或 ] → 这是字符串外的尾逗号,丢弃
            j = i + 1
            while j < n and text[j] in ' \t\r\n':
                j += 1
            if j < n and text[j] in '}]':
                i += 1   # 丢弃逗号(其后空白与 }/] 由后续循环原样输出)
                continue
        out.append(c); i += 1
    return "".join(out)

def _parse_json_lenient(text):
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return json.loads(_strip_trailing_commas(text))
def _load_json_lenient(path):
    return _parse_json_lenient(open(path, encoding="utf-8", errors="ignore").read())

# 从原始(未剥离)着色器源提取 uniform 的 JSON 元数据:g_Speed ← pkg 参数 "speed",及默认值。
# 行形如:  uniform float g_Speed; // {"material":"speed","default":5,"range":[...]}
UNIFORM_META_RE = re.compile(r'uniform\s+\S+\s+(\w+)\s*;\s*//\s*(\{.*\})')
def extract_uniform_meta(src):
    meta = {}
    for line in src.splitlines():
        m = UNIFORM_META_RE.search(line)
        if not m: continue
        name = m.group(1)
        try: j = json.loads(m.group(2))
        except Exception: continue
        meta[name] = {"material": j.get("material"), "default": j.get("default"),
                      "combo": j.get("combo")}
    return meta

def reflect(spv):
    r = subprocess.run(["spirv-cross", spv, "--reflect"], capture_output=True, text=True)
    j = json.loads(r.stdout)
    uniforms = []
    for t in j.get("types", {}).values():
        if t.get("name") == "_Globals":
            for m in t.get("members", []):
                u = {"name": m["name"], "offset": m["offset"], "type": m["type"]}
                # 数组成员(如 float g_AudioSpectrum16Left[16]):记录元素数 + std140 步长(每元素
                # 对齐到 16B,spirv-cross MSL 用 float4[N] 表示,值落在每个 float4 的 .x)。Swift 侧
                # 据此按 offset + i*stride 写第 i 个元素,否则只写到第 0 个。
                arr = m.get("array")
                if arr:
                    u["array"] = arr[0] if isinstance(arr, list) else arr
                    u["arrayStride"] = m.get("array_stride", 16)
                uniforms.append(u)
    return uniforms

# 关键:spirv-cross 给 MSL 的 [[texture(N)]]/[[buffer(N)]]/[[sampler(N)]] 索引,
# 与 SPIR-V binding 装饰**不一致**(它自行重排)。必须从生成的 MSL 签名解析真实索引来绑定。
def parse_msl_resources(msl):
    texs = {m[0]: int(m[1]) for m in re.findall(r'texture(?:2d|cube|3d)<[^>]*>\s+(\w+)\s*\[\[texture\((\d+)\)\]\]', msl)}
    samps = {m[0][:-5] if m[0].endswith("Smplr") else m[0]: int(m[1])
             for m in re.findall(r'\bsampler\s+(\w+)\s*\[\[sampler\((\d+)\)\]\]', msl)}
    bm = re.search(r'_Globals&\s+\w+\s*\[\[buffer\((\d+)\)\]\]', msl)
    ubuf = int(bm.group(1)) if bm else 0
    samplers = [{"name": n, "texIndex": ti, "sampIndex": samps.get(n, ti)} for n, ti in texs.items()]
    return samplers, ubuf

def transpile_stage(eff_shaders_dir, shader_base, stage, combos, vary_locs, link_src=None, bound_slots=None,
                    extra_search_dirs=None):
    """转译一个 shader 的一个 stage → (msl, uniforms, samplers)。shader 在 eff_shaders_dir(可为 effect
    本地 shaders 目录,或共享 $WE/shaders 回退目录——见 resolve_pass_shader 的 shader_dir)。
    link_src:对端 stage 的 include 展开源,供链接驱动的 varying vec2↔vec4 双向兼容(item 4)。
    bound_slots:本 pass 占用的贴图槽索引,供 sampler combo/require 联动(item 5)。
    extra_search_dirs:额外的 include 搜索目录(共享 shader 回退时带上 effect 本地目录)。"""
    path = os.path.join(eff_shaders_dir, shader_base + "." + stage)
    if not os.path.exists(path):
        return None
    glsl = T.preprocess(path, stage, combos, vary_locs,
                        search_dirs=[eff_shaders_dir] + list(extra_search_dirs or []),
                        link_src=link_src, bound_slots=bound_slots)
    g = tempfile.NamedTemporaryFile("w", suffix="." + stage, delete=False); g.write(glsl); g.close()
    spv = g.name + ".spv"
    r = subprocess.run(["glslangValidator", "-V", "-S", stage, g.name, "-o", spv], capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f"glslang {stage}: " + (r.stdout or r.stderr)[-200:])
    msl = subprocess.run(["spirv-cross", spv, "--msl", "--msl-version", "20000"], capture_output=True, text=True).stdout
    uniforms = reflect(spv)                       # uniform 布局(offset)走 SPIR-V 反射
    samplers, ubuf = parse_msl_resources(msl)     # 贴图/sampler/buffer 索引走 MSL 真实签名
    return msl, uniforms, samplers, ubuf

# ---- .tex 纹理格式(供 item 3 TEX0FORMAT 注入)----
# .tex 头:NUL 结尾 magic "TEXVxxxx",再 NUL 结尾 "TEXIxxxx",随后 7 个 int32 LE,第 1 个即 format。
# 与 Sources/.../TexDecoder.swift:160-164 同算法。format 枚举:8=RG88、9=R8(单通道,见 common_fragment.h)。
def tex_format(blob):
    if not blob:
        return None
    i = blob.find(b"TEXV")
    if i < 0:
        return None
    o = i
    z = blob.find(b"\x00", o)                 # 跳过 "TEXVxxxx\0"
    if z < 0:
        return None
    o = z + 1
    z = blob.find(b"\x00", o)                 # 跳过 "TEXIxxxx\0"
    if z < 0:
        return None
    o = z + 1
    if o + 4 > len(blob):
        return None
    return struct.unpack_from("<i", blob, o)[0]

# texture0 是 RG88(8)/R8(9) 时注入对应 TEX0FORMAT combo(CPass.cpp:544-550)。其它格式/无 texture0 → 不注入
# (与参考 `if (texture0 != nullptr)` + 仅 RG88/R8 两分支一致)。让单通道法线/遮罩 shader 的 TEX0FORMAT 分支走对。
def tex0format_combo(t0_name, tex_reader):
    """t0_name:material/pass 的 textures[0](纹理基名,如 'masks/foo')。tex_reader(rel)→bytes|None。
    解析其 .tex 格式;RG88→{'TEX0FORMAT':'8'}、R8→{'TEX0FORMAT':'9'},否则 {}。"""
    if not t0_name or tex_reader is None:
        return {}
    blob = tex_reader(f"materials/{t0_name}.tex")
    fmt = tex_format(blob)
    if fmt == 8:
        return {"TEX0FORMAT": "8"}
    if fmt == 9:
        return {"TEX0FORMAT": "9"}
    return {}

def resolve_shader(pass_obj):
    """pass → shader basename(如 'effects/waterwaves')。"""
    mat = pass_obj.get("material")
    if mat:
        mp = os.path.join(WE, "effects", "_x_", mat)  # 占位,下面用绝对
    sh = pass_obj.get("shader")
    return sh

def scene_combos():
    """扫全库 scene,收集每个 effect 实际用到的 combo 组合(变体)。"""
    import struct, glob
    ROOT = os.path.expanduser("~/Library/Application Support/CrossOver/Bottles/Steam/drive_c/Program Files (x86)/Steam/steamapps/workshop/content/431960")
    def unpack(p):
        b=open(p,'rb').read();o=0;ml=struct.unpack_from('<i',b,o)[0];o+=4;mg=b[o:o+ml].decode('utf-8','ignore');o+=ml
        if not mg.startswith('PKGV'):return None
        n=struct.unpack_from('<i',b,o)[0];o+=4;e=[]
        for _ in range(n):
            nl=struct.unpack_from('<i',b,o)[0];o+=4;nm=b[o:o+nl].decode('utf-8','ignore');o+=nl
            of=struct.unpack_from('<i',b,o)[0];o+=4;sz=struct.unpack_from('<i',b,o)[0];o+=4;e.append((nm,of,sz))
        base=o;return {nm.replace('\\','/'):b[base+of:base+of+sz] for nm,of,sz in e}
    out = {}
    for pkg in sorted(glob.glob(os.path.join(ROOT,'*','scene.pkg'))):
        files=unpack(pkg)
        if not files: continue
        scene=next((_parse_json_lenient(v.decode('utf-8','ignore')) for k,v in files.items() if k.endswith('scene.json')),None)
        if not scene: continue
        def visit(o):
            if isinstance(o,dict):
                for e in (o.get('effects') or []):
                    if not isinstance(e,dict): continue
                    f=e.get('file','')
                    if 'effects/' not in f: continue
                    nm=f.split('effects/')[1].split('/')[0]
                    for ps in (e.get('passes') or []):
                        c=ps.get('combos') if isinstance(ps,dict) else None
                        if c: out.setdefault(nm,set()).add(tuple(sorted((k,str(v)) for k,v in c.items())))
                for v in o.values(): visit(v)
            elif isinstance(o,list):
                for v in o: visit(v)
        visit(scene)
    return out

def combo_key(combos):
    return "base" if not combos else "_".join(f"{k}-{v}" for k,v in sorted(combos.items()))

# ---- 基础材质 shader(genericimage2/3/4)的转译(供基础图层渲染路径,非 effect 后处理)----
# 图层材质 pass 直接引用共享 shader 目录的 genericimage2/3/4(带 NORMALMAP/REFLECTION/LIGHTING/
# EMISSIVE_MAP/PBRMASKS/FOG 等 combo)。转译器实测能处理(含 common_pbr*.h/common_fog.h)。
# 与 effect 一样按「全库实际用到的 combo 组合」建变体(新壁纸用到未见组合时需重建,同 effect 模型)。
MATERIAL_SHADERS = ("genericimage2", "genericimage3", "genericimage4")

def material_combos():
    """扫全库 scene 图层材质,收集 genericimage2/3/4 实际用到的 combo 组合。
    返回 {shader_base: set(frozenset((k,v)...))}。"""
    out = {}
    for pkg in sorted(glob.glob(os.path.join(WORKSHOP, "*", "scene.pkg"))):
        files = unpack_pkg(pkg)
        if not files:
            continue
        for fn, blob in files.items():
            if not (fn.startswith("materials/") and fn.endswith(".json")):
                continue
            try:
                m = _parse_json_lenient(blob.decode("utf-8", "ignore"))
            except Exception:
                continue
            for ps in (m.get("passes") or []):
                sh = ps.get("shader", "")
                if sh in MATERIAL_SHADERS:
                    cb = ps.get("combos") if isinstance(ps.get("combos"), dict) else {}
                    out.setdefault(sh, set()).add(frozenset((k, str(v)) for k, v in cb.items()))
    return out

def build_material(shader_base, combos):
    """转译 $WE/shaders/<shader_base>.{vert,frag}(单 shader,非多 pass)→ 一个 {vert,frag} pass 记录。
    缺文件或转译失败返回 None。"""
    vp = os.path.join(SHARED_SHADERS, shader_base + ".vert")
    fp = os.path.join(SHARED_SHADERS, shader_base + ".frag")
    if not (os.path.exists(vp) and os.path.exists(fp)):
        return None
    vsrc = open(vp, encoding="utf-8", errors="ignore").read()
    fsrc = open(fp, encoding="utf-8", errors="ignore").read()
    vary_locs = T.collect_varyings(vsrc, fsrc)
    ck = combo_key(combos)
    rec = {}
    for stage in ("vert", "frag"):
        link = fsrc if stage == "vert" else vsrc
        res = transpile_stage(SHARED_SHADERS, shader_base, stage, combos, vary_locs, link_src=link)
        if res is None:
            return None
        msl, uniforms, samplers, ubuf = res
        mfile = f"material__{shader_base}__{ck}__{stage}.metal"
        with open(os.path.join(MSL_DIR, mfile), "w") as f:
            f.write(msl)
        rec[stage] = {"metal": mfile, "entry": "main0", "uniforms": uniforms,
                      "samplers": samplers, "ubuf": ubuf}
    # uniform 元数据(材质键 + 默认值),供渲染端把 g_Roughness/Metallic/EmissiveColor 等从
    # 材质 constantshadervalues 喂真值(缺则退默认)。与 build_effect_passes 同法。
    rec["uniformMeta"] = {**extract_uniform_meta(vsrc), **extract_uniform_meta(fsrc)}
    return rec

def fbo_scales(edef):
    """effect.json 的 fbos[] → {name: scale}(降采样目标的分辨率分母)。"""
    out = {}
    for f in edef.get("fbos", []):
        if isinstance(f, dict) and f.get("name"):
            out[f["name"]] = int(f.get("scale", 1) or 1)
    return out

def pass_bound_slots(p, mat_textures):
    """本 pass 占用的贴图槽索引集合(item 5 的 textureSlotUsed,对齐 CPass m_passTextures)。
    = material/pass 的 textures[] 中非空项的下标 ∪ effect.json pass 的 bind[].index ∪ pass.textures 非空项。
    供 sampler combo/require 联动判定「贴图槽是否被占用」。"""
    slots = set()
    for arr in (mat_textures, p.get("textures")):
        if isinstance(arr, list):
            for idx, t in enumerate(arr):
                if t:  # 非 null/非空名 → 该槽被占用
                    slots.add(idx)
    for b in (p.get("bind") or []):
        if isinstance(b, dict) and isinstance(b.get("index"), int):
            slots.add(b["index"])
    return slots

def resolve_pass_shader(p, shaders_dir, file_reader):
    """pass → (shader_base, material_combos, material_textures, shader_dir)。material 可能携带 pass 级
    combos(如 VERTICAL=1)与 textures[](槽位绑定)。file_reader(rel) → 文本 or None(builtin 读磁盘
    相对 effect 目录;workshop 读 pkg map)。

    共享材质/共享 shader 回退(refraction 等内置 effect):某些 pass 的 material 指向 effect 目录里没有的
    共享材质(如 pass0=materials/util/effectcomposebackground.json),它在 $WE/materials/<相对路径>;
    该共享材质引用的 shader(如 effectcomposebackground)也常在共享 shader 目录 $WE/shaders/ 而非
    effect 自己的 shaders/。这里:① material 在 effect 目录找不到时回退读 $WE/<matrel>;② 返回 shader
    文件实际所在目录 shader_dir(默认 effect 本地 shaders_dir;若本地无 .vert/.frag 而 $WE/shaders 有则回退之),
    供 build_effect_passes 据此定位 .vert/.frag 与 include 搜索。"""
    shader = p.get("shader")
    mat_combos = {}
    mat_textures = None
    if not shader:
        matrel = p.get("material")
        if matrel:
            txt = file_reader(matrel)
            if txt is None:
                # effect 目录没有 → 回退到全局共享材质 $WE/<matrel>(util/effectcomposebackground 等)。
                shared_mp = os.path.join(WE, matrel.replace("\\", "/"))
                if os.path.exists(shared_mp):
                    txt = open(shared_mp, encoding="utf-8", errors="ignore").read()
            if txt is not None:
                mat = _parse_json_lenient(txt)
                mps = (mat.get("passes") or [{}])[0]
                shader = mps.get("shader")
                if isinstance(mps.get("combos"), dict):
                    mat_combos = {k: str(v) for k, v in mps["combos"].items()}
                if isinstance(mps.get("textures"), list):
                    mat_textures = mps["textures"]
    # shader 文件所在目录:优先 effect 本地 shaders_dir;若本地两个 stage 都没有、而共享 $WE/shaders 有 → 回退共享。
    shader_dir = shaders_dir
    if shader:
        local_has = any(os.path.exists(os.path.join(shaders_dir, shader + ext)) for ext in (".vert", ".frag"))
        if not local_has:
            shared_has = any(os.path.exists(os.path.join(SHARED_SHADERS, shader + ext)) for ext in (".vert", ".frag"))
            if shared_has:
                shader_dir = SHARED_SHADERS
    return shader, mat_combos, mat_textures, shader_dir

def build_effect_passes(edef, combos, ckey, shaders_dir, file_reader, tex_reader=None):
    """通用 pass 构建:builtin 与 workshop 共用。shaders_dir = .vert/.frag 所在目录;
    file_reader 读 material(builtin=磁盘相对 effect 目录,workshop=pkg map)。
    tex_reader(rel)→bytes|None 读 .tex 二进制(供 item 3 TEX0FORMAT 注入)。
    fbos 的 scale 写进每个 pass 的 targetScale(目标降采样分母,默认 1)。"""
    scales = fbo_scales(edef)
    passes_out = []
    stage_misses = []   # (pass_index, shader_base, stage) 缺 .vert/.frag 文件 → transpile_stage 返回 None
    for i, p in enumerate(edef.get("passes", [])):
        # ---- command pass(无 material/shader,只有 "command")----
        # WE 的 effect pass 除 material/shader 外还有 command 形式:motionblur 的 pass1
        # `{"command":"copy","target":"_rt_FullCompoBuffer1","source":"_rt_FullCompoBuffer2"}` 把本帧累积
        # 结果回拷到持久缓冲(供下一帧 previous 采样);fluidsimulation 末尾的 ping-pong
        # `{"command":"swap","source":...,"target":...}` 交换两个 FBO。这类 pass 没有着色器、无可转译,
        # 原逻辑落到 `not base → "pass i no shader"` 会把**整个 effect**判失败(连已转译的渲染 pass 一起丢)。
        # 改:识别任意 command pass,产出标记记录 {"command", "copy": cmd=="copy", "target", "source", "bind"},
        # 不进 transpile、不计 fail;运行时侧据此做 blit/全屏拷贝(copy)或 FBO 交换(swap)。
        cmd = p.get("command")
        if cmd:
            passes_out.append({
                "command": cmd,
                "copy": (cmd == "copy"),
                "target": p.get("target"),
                "source": p.get("source"),
                "bind": p.get("bind", []),
            })
            continue
        base, mat_combos, mat_textures, stage_dir = resolve_pass_shader(p, shaders_dir, file_reader)
        if not base:
            return None, f"pass {i} no shader", stage_misses
        bound_slots = pass_bound_slots(p, mat_textures)   # item 5:本 pass 占用的贴图槽
        # item 3:texture0(slot 0)若绑定单通道 .tex(RG88/R8)→ 注入 TEX0FORMAT。texture0 名取
        # pass.textures[0] 或 material.textures[0](非空)。后处理 effect 的 slot0 多是离屏帧缓冲(无 .tex)→ 不注入。
        t0_name = None
        for arr in (p.get("textures"), mat_textures):
            if isinstance(arr, list) and arr and arr[0]:
                t0_name = arr[0]; break
        tex0_combo = tex0format_combo(t0_name, tex_reader)
        # stage_dir:本 pass shader 的 .vert/.frag 实际所在目录(effect 本地或共享 $WE/shaders 回退)。
        # include 搜索 dir 同时含 effect 本地与共享目录($WE/shaders 由 inline_includes 末尾兜底,这里
        # 显式带上 stage_dir 与 effect 本地 shaders_dir 以便共享 shader 仍能引用 effect 私有 include)。
        search_dirs = [stage_dir, shaders_dir] if stage_dir != shaders_dir else [shaders_dir]
        vpath = os.path.join(stage_dir, base + ".vert")
        fpath = os.path.join(stage_dir, base + ".frag")
        vraw = T.inline_includes(T.read(vpath), search_dirs=search_dirs) if os.path.exists(vpath) else ""
        fraw = T.inline_includes(T.read(fpath), search_dirs=search_dirs) if os.path.exists(fpath) else ""
        # 变体 combos + material 自带 combos(如 blur_gaussian_y 的 VERTICAL=1)合并。
        # 关键:同一 shader 被多个 pass 用且各带不同 material combo(bloom 的 blur_x/blur_y
        # 共用 blur_gaussian 但 y 多 VERTICAL=1)时,MSL 不同 → 文件名必须含「合并后」combo,
        # 否则后一个 pass 覆盖前一个的 .metal,两个 pass 错误共用同一份(blur_y 退化成 blur_x)。
        # 更关键:同一 pass 的 vert/frag 必须用**同一套 combo** —— combo 的 [COMBO] 默认值常只声明在
        # 一个 stage(如 godrays_downsample2 的 NOISE 默认只在 frag 声明),若各 stage 只读自己的默认,
        # vert NOISE=0 / frag NOISE=1 → 一方产 v_NoiseTexCoord 另一方不产 → 顶点输出/片元输入接口不匹配,
        # makeRenderPipelineState 抛错、整 pass 被跳过(godrays 因此漏掉 downsample 阈值 pass → 洗白)。
        # 故:先并两 stage 的 [COMBO] 默认作为基底,再让 scene/material combo 覆盖。
        stage_defaults = {**T.combo_defaults(vraw), **T.combo_defaults(fraw)}
        pass_combos = dict(stage_defaults); pass_combos.update(combos); pass_combos.update(mat_combos)
        # item 3:TEX0FORMAT 由材质纹理格式派生,等同 CPass 在拷贝 pass.combos 后 insert_or_assign,
        # 故置于最高优先级覆盖(仅当 texture0 为 RG88/R8 时存在;后处理 effect 普遍为空 → 无影响)。
        pass_combos.update(tex0_combo)
        pck = combo_key(pass_combos)
        meta = {**extract_uniform_meta(vraw), **extract_uniform_meta(fraw)}  # uniform→{material,default}
        vsrc = T.strip_meta(vraw); fsrc = T.strip_meta(fraw)
        vary_locs = T.collect_varyings(vsrc, fsrc)
        entry = base.replace("/", "__")
        target = p.get("target")
        pass_rec = {"shader": base, "target": target, "bind": p.get("bind", []),
                    "uniformMeta": meta, "targetScale": scales.get(target, 1)}
        # 链接驱动的 varying 兼容(item 4):vert 编译看 frag 接口、frag 看 vert 接口(include 展开源)。
        link_for = {"vert": fraw, "frag": vraw}
        for stage in ["vert", "frag"]:
            res = transpile_stage(stage_dir, base, stage, pass_combos, vary_locs,
                                  link_src=link_for[stage], bound_slots=bound_slots,
                                  extra_search_dirs=[shaders_dir] if stage_dir != shaders_dir else None)
            if res is None:
                # 缺 base.<stage> 文件(transpile_stage 路径不存在 → None)。记一条而非纯 continue,
                # 便于汇总(纯 post-process effect 常只有 frag,无 vert 属正常,但 frag 缺失需暴露)。
                stage_misses.append((i, base, stage))
                continue
            msl, uniforms, samplers, ubuf = res
            mfile = f"{entry}__{pck}__{stage}.metal"
            with open(os.path.join(MSL_DIR, mfile), "w") as f:
                f.write(msl)
            pass_rec[stage] = {"metal": mfile, "entry": "main0", "uniforms": uniforms,
                               "samplers": samplers, "ubuf": ubuf}
        passes_out.append(pass_rec)
    return {"passes": passes_out}, None, stage_misses

def build_effect(name, combos, ckey):
    """WE 内置 effect(读 assets/effects/<name>)。"""
    ejson = os.path.join(WE, "effects", name, "effect.json")
    if not os.path.exists(ejson):
        return None, f"no effect.json", []
    edef = _load_json_lenient(ejson)
    eff_dir = os.path.join(WE, "effects", name)
    eff_shaders = os.path.join(eff_dir, "shaders")
    def reader(rel):
        mp = os.path.join(eff_dir, rel)
        return open(mp, encoding="utf-8", errors="ignore").read() if os.path.exists(mp) else None
    def tex_reader(rel):   # .tex 二进制(item 3 TEX0FORMAT),相对 effect 目录
        mp = os.path.join(eff_dir, rel)
        return open(mp, "rb").read() if os.path.exists(mp) else None
    return build_effect_passes(edef, combos, ckey, eff_shaders, reader, tex_reader)

# ---- pkg-sourced workshop 后处理 effect ----

def unpack_pkg(p):
    """PKGV 解包 → {relpath: bytes}。与 SceneSource / probe_scene 同格式。"""
    try:
        b = open(p, "rb").read()
    except Exception:
        return None
    o = 0
    ml = struct.unpack_from("<i", b, o)[0]; o += 4
    mg = b[o:o+ml].decode("utf-8", "ignore"); o += ml
    if not mg.startswith("PKGV"):
        return None
    n = struct.unpack_from("<i", b, o)[0]; o += 4
    e = []
    for _ in range(n):
        nl = struct.unpack_from("<i", b, o)[0]; o += 4
        nm = b[o:o+nl].decode("utf-8", "ignore"); o += nl
        of = struct.unpack_from("<i", b, o)[0]; o += 4
        sz = struct.unpack_from("<i", b, o)[0]; o += 4
        e.append((nm, of, sz))
    base = o
    return {nm.replace("\\", "/"): b[base+of:base+of+sz] for nm, of, sz in e}

# pkg → 解包缓存(同一 pkg 只解一次);workshop effect key → 已建。
_pkg_cache = {}
def pkg_files(pkg_path):
    if pkg_path not in _pkg_cache:
        _pkg_cache[pkg_path] = unpack_pkg(pkg_path)
    return _pkg_cache[pkg_path]

def build_workshop_effect(eff_key, pkg_path, combos, ckey):
    """workshop effect(shaders/材质/effect.json 在 pkg 内)。eff_key 如 'workshop/2822917890/bloom'。
    把 pkg 内 shaders/* 写到临时目录(保留 shaders/ 下的相对路径,供 #include 互引),按算法转译。"""
    files = pkg_files(pkg_path)
    if not files:
        return None, "pkg unpack fail", []
    ejson_rel = f"effects/{eff_key}/effect.json"
    if ejson_rel not in files:
        return None, f"no {ejson_rel}", []
    edef = _parse_json_lenient(files[ejson_rel].decode("utf-8", "ignore"))
    # pkg 内 shaders/* → 临时目录(保留 'shaders/' 之后的相对路径)。shader base 形如
    # 'workshop/2822917890/effects/blur_gaussian',故 search_dir = 该临时根。
    shdir = _pkg_shader_dir(pkg_path, files)
    def reader(rel):  # material 相对 pkg 根
        v = files.get(rel.replace("\\", "/"))
        return v.decode("utf-8", "ignore") if v is not None else None
    def tex_reader(rel):  # .tex 二进制(item 3 TEX0FORMAT),相对 pkg 根
        return files.get(rel.replace("\\", "/"))
    return build_effect_passes(edef, combos, ckey, shdir, reader, tex_reader)

_shader_dir_cache = {}
def _pkg_shader_dir(pkg_path, files):
    if pkg_path in _shader_dir_cache:
        return _shader_dir_cache[pkg_path]
    d = tempfile.mkdtemp(prefix="we_pkgsh_")
    for k, v in files.items():
        if k.startswith("shaders/"):
            rel = k[len("shaders/"):]
            fp = os.path.join(d, rel)
            os.makedirs(os.path.dirname(fp), exist_ok=True)
            open(fp, "wb").write(v)
    _shader_dir_cache[pkg_path] = d
    return d

def scan_post_workshop_effects():
    """扫全库 scene.pkg,找任何 object 上引用 effects/workshop/.../ 的 effect。
    返回 {eff_key: (pkg_path, {combo_tuple,...})}:eff_key = 'effects/' 之后去掉 '/effect.json';
    combo_tuple 是该 effect 在某 scene 里 pass.combos 的 (k,v) 排序元组(变体)。
    注:多 pass effect 的 per-pass material combos(如 blur_y 的 VERTICAL=1)由 build_effect_passes 逐 pass
    自带合并;但**整 effect 级**的 scene combos(如 Simple_Audio_Bars 的 ANTIALIAS/CLIP_HIGH/CLIP_LOW)只在
    scene 的 pass.combos 里,base 变体不含 → 必须按 scene 实际组合另建变体,否则视觉错(audio-bars 退 base
    无 CLIP 时静音仍显半高条;antialias 也丢)。故收集 scene combos,base + 各组合都建。"""
    found = {}  # eff_key -> [pkg_path, set_of_combo_tuples]
    # 排序后取首个 pkg,保证同一 eff_key 内嵌多处时结果可复现(此前未排序 → glob 文件系统序不定,
    # 多 homed 的 Simple_Audio_Bars 选到含旧版源的 pkg 时随机失败)。
    for pkg in sorted(glob.glob(os.path.join(WORKSHOP, "*", "scene.pkg"))):
        files = pkg_files(pkg)
        if not files:
            continue
        scene = next((_parse_json_lenient(v.decode("utf-8", "ignore"))
                      for k, v in files.items() if k.endswith("scene.json")), None)
        if not scene:
            continue
        def visit(o):
            if isinstance(o, dict):
                for e in (o.get("effects") or []):
                    if not isinstance(e, dict):
                        continue
                    f = (e.get("file") or "").replace("\\", "/")
                    if "effects/workshop/" not in f:
                        continue
                    key = f.split("effects/", 1)[1]
                    if key.endswith("/effect.json"):
                        key = key[:-len("/effect.json")]
                    rec = found.setdefault(key, [pkg, set()])
                    for ps in (e.get("passes") or []):
                        if not isinstance(ps, dict):
                            continue
                        c = ps.get("combos") or {}
                        if c:
                            rec[1].add(tuple(sorted((k, str(v)) for k, v in c.items())))
                        # 隐式 MASK:pass 分配了含 "mask" 的纹理槽 → WE/lwe 自动开 MASK(ShaderUnit.cpp:545-556:
                        # 带 "combo" 注解的采样器被绑贴图时注入 MASK=1)。内置 effects 循环已派生,workshop 此前漏了
                        # → workshop pulse(打雷)等的 MASK 变体从没烘出 → 运行期回退无遮罩变体 → 整帧增亮不限定云带。
                        # 这里照 pass.textures 派生:任一槽名含 "mask" → 在(各 combo 组合 + 空)基础上加 MASK:1 变体。
                        texs = ps.get("textures") or []
                        if any(isinstance(t, str) and "mask" in t.lower() for t in texs):
                            cm = dict(c); cm["MASK"] = "1"
                            rec[1].add(tuple(sorted((k, str(v)) for k, v in cm.items())))
                for v in o.values():
                    visit(v)
            elif isinstance(o, list):
                for v in o:
                    visit(v)
        visit(scene)
    return found

def scan_pkg_local_effects():
    """扫全库 scene.pkg,找 object 引用的 **pkg-local 自定义** effect —— 即 effect.json 在 pkg 内、
    但 effect 名既不在 WE assets 的内置 USED 列表里、路径也不含 'effects/workshop/' 的那一类
    (如 2B NieR 壁纸的 'effects/t2/...' 驱动头发/手臂畸变)。这类此前被两个 scanner 同时漏掉:
    builtin scanner 只扫 $WE/effects 的 USED;workshop scanner 只认 'effects/workshop/' 前缀。
    返回 {eff_key: (pkg_path, {combo_tuple,...})}:eff_key = 'effects/' 之后去掉 '/effect.json'
    (此处即裸 effect 名,如 't2',与运行时 SceneModel 取 'effects/' 后首段一致);combo_tuple 同
    scan_post_workshop_effects(每个 scene pass.combos 的 (k,v) 排序元组 + 含 mask 纹理时的隐式 MASK)。
    与 build_workshop_effect 复用同一条 pkg-shader 读取/转译路径。"""
    used = set(USED)
    found = {}  # eff_key -> [pkg_path, set_of_combo_tuples]
    for pkg in sorted(glob.glob(os.path.join(WORKSHOP, "*", "scene.pkg"))):
        files = pkg_files(pkg)
        if not files:
            continue
        scene = next((_parse_json_lenient(v.decode("utf-8", "ignore"))
                      for k, v in files.items() if k.endswith("scene.json")), None)
        if not scene:
            continue
        def visit(o):
            if isinstance(o, dict):
                for e in (o.get("effects") or []):
                    if not isinstance(e, dict):
                        continue
                    f = (e.get("file") or "").replace("\\", "/")
                    if "effects/" not in f:
                        continue
                    if "effects/workshop/" in f:        # workshop scanner 的地盘,跳过
                        continue
                    key = f.split("effects/", 1)[1]
                    if key.endswith("/effect.json"):
                        key = key[:-len("/effect.json")]
                    name = key.split("/")[0]
                    if name in used:                    # 内置 effect 由 builtin scanner 处理
                        continue
                    if f"effects/{key}/effect.json" not in files:  # effect.json 必须真在 pkg 内
                        continue
                    rec = found.setdefault(key, [pkg, set()])
                    for ps in (e.get("passes") or []):
                        if not isinstance(ps, dict):
                            continue
                        c = ps.get("combos") or {}
                        if c:
                            rec[1].add(tuple(sorted((k, str(v)) for k, v in c.items())))
                        # 隐式 MASK(同 workshop scanner):pass 分配含 "mask" 的纹理槽 → 加 MASK:1 变体。
                        texs = ps.get("textures") or []
                        if any(isinstance(t, str) and "mask" in t.lower() for t in texs):
                            cm = dict(c); cm["MASK"] = "1"
                            rec[1].add(tuple(sorted((k, str(v)) for k, v in cm.items())))
                for v in o.values():
                    visit(v)
            elif isinstance(o, list):
                for v in o:
                    visit(v)
        visit(scene)
    return found

def main():
    os.makedirs(MSL_DIR, exist_ok=True)
    used_combos = scene_combos()          # effect → {comboSet,...}
    manifest = {}
    ok = []; fail = []; variant_count = 0
    for name in USED:
        # 变体集合:base + 全库实际用到的 combo 组合。
        variants = [{}]
        for cs in sorted(used_combos.get(name, set())):
            variants.append({k: v for k, v in cs})
        # MASK 是「隐式 combo」:pkg 不写,但图层分配了遮罩纹理时 WE 自动开。
        # 若 effect 着色器用到 MASK,补 MASK=1 变体(及与各 pkg combo 的组合)。
        ej = os.path.join(WE, "effects", name, "effect.json")
        uses_mask = False
        if os.path.exists(ej):
            edj = _load_json_lenient(ej)
            for p in edj.get("passes", []):
                sh = p.get("shader")
                if not sh:
                    mr = p.get("material")
                    if mr and os.path.exists(os.path.join(WE, "effects", name, mr)):
                        sh = _load_json_lenient(os.path.join(WE, "effects", name, mr)).get("passes", [{}])[0].get("shader")
                if not sh: continue
                for ext in (".frag", ".vert"):
                    sp = os.path.join(WE, "effects", name, "shaders", sh + ext)
                    if os.path.exists(sp) and "MASK" in open(sp, encoding="utf-8", errors="ignore").read():
                        uses_mask = True
        if uses_mask:
            base_variants = list(variants)
            for bv in base_variants:
                mv = dict(bv); mv["MASK"] = "1"
                if mv not in variants: variants.append(mv)
        built = []
        for combos in variants:
            ck = combo_key(combos)
            try:
                rec, err, misses = build_effect(name, combos, ck)
                # 缺 .vert/.frag 文件的 stage(transpile_stage→None)逐条记录(不再静默 continue)
                for (pi, sb, st) in misses:
                    fail.append((f"{name}/{ck}", f"pass {pi} {sb}.{st} 缺 shader 文件"))
                # 「建成」判据:任一 pass 有 frag(原只看 passes[0])。对 pass0 为 copy/swap 等命令 pass、
                # 或 pass0 仅 compose 而真正渲染在后续 pass 的 effect(motionblur 等),只看 passes[0] 会误判失败。
                if rec and rec["passes"] and any(pp.get("frag") for pp in rec["passes"]):
                    built.append({"combos": combos, "passes": rec["passes"]}); variant_count += 1
                else:
                    # 所有变体(不止 base)失败都记 fail,带 effect_key/combo 标识
                    fail.append((f"{name}/{ck}", err or "no frag"))
            except Exception as e:
                # 所有变体异常都记 fail,带标识 + 截断异常文本
                fail.append((f"{name}/{ck}", str(e)[:200]))
        if built:
            manifest[name] = {"variants": built}; ok.append(name)

    # ---- pkg-sourced workshop 后处理 effect(如 bloom / Simple_Audio_Bars)。key = 'effects/' 后去 '/effect.json'。----
    # base + scene 实际用到的 combo 组合都建:per-pass material combos(VERTICAL 等)逐 pass 自带合并;
    # 整 effect 级 scene combos(ANTIALIAS/CLIP_* 等)base 不含,须按 scene 组合另建变体(否则视觉错)。
    ws_ok = []
    for eff_key, (pkg_path, combo_sets) in sorted(scan_post_workshop_effects().items()):
        variants_in = [{}]
        for cs in sorted(combo_sets):
            cd = {k: v for k, v in cs}
            if cd not in variants_in:
                variants_in.append(cd)
        built = []
        for combos in variants_in:
            ck = combo_key(combos)
            try:
                rec, err, misses = build_workshop_effect(eff_key, pkg_path, combos, ck)
                # 缺 .vert/.frag 文件的 stage(transpile_stage→None)逐条记录(不再静默 continue)
                for (pi, sb, st) in misses:
                    fail.append((f"{eff_key}/{ck}", f"pass {pi} {sb}.{st} 缺 shader 文件"))
                # 「建成」判据:任一 pass 有 frag(原只看 passes[0])。对 pass0 为 copy/swap 等命令 pass、
                # 或 pass0 仅 compose 而真正渲染在后续 pass 的 effect(motionblur 等),只看 passes[0] 会误判失败。
                if rec and rec["passes"] and any(pp.get("frag") for pp in rec["passes"]):
                    built.append({"combos": combos, "passes": rec["passes"]}); variant_count += 1
                else:
                    # 所有变体(不止 base)失败都记 fail,带 effect_key/combo 标识
                    fail.append((f"{eff_key}/{ck}", err or "no frag"))
            except Exception as e:
                # 所有变体异常都记 fail,带标识 + 截断异常文本
                fail.append((f"{eff_key}/{ck}", str(e)[:200]))
        if built:
            manifest[eff_key] = {"variants": built}; ws_ok.append(eff_key)

    # ---- pkg-local 自定义 effect(既非内置 USED、也非 effects/workshop/ 前缀;如 2B NieR 的 't2')。----
    # 与 workshop effect 共用 build_workshop_effect 的 pkg-shader 读取/转译路径;manifest key 用裸 effect 名
    # (如 't2',与运行时 SceneModel 取 'effects/' 后首段一致)。base + scene 实际 combo 组合都建,同 workshop。
    pl_ok = []
    for eff_key, (pkg_path, combo_sets) in sorted(scan_pkg_local_effects().items()):
        variants_in = [{}]
        for cs in sorted(combo_sets):
            cd = {k: v for k, v in cs}
            if cd not in variants_in:
                variants_in.append(cd)
        built = []
        for combos in variants_in:
            ck = combo_key(combos)
            try:
                rec, err, misses = build_workshop_effect(eff_key, pkg_path, combos, ck)
                for (pi, sb, st) in misses:
                    fail.append((f"{eff_key}/{ck}", f"pass {pi} {sb}.{st} 缺 shader 文件"))
                if rec and rec["passes"] and any(pp.get("frag") for pp in rec["passes"]):
                    built.append({"combos": combos, "passes": rec["passes"]}); variant_count += 1
                else:
                    fail.append((f"{eff_key}/{ck}", err or "no frag"))
            except Exception as e:
                fail.append((f"{eff_key}/{ck}", str(e)[:200]))
        if built:
            manifest[eff_key] = {"variants": built}; pl_ok.append(eff_key)

    # ---- 基础材质 shader(genericimage2/3/4)的 combo 变体(供基础图层渲染路径)。----
    # key = "material/<shader>";结构同 effect(variants:[{combos,passes:[{vert,frag}]}]),单 pass。
    mat_ok = []
    for shader_base, combo_sets in sorted(material_combos().items()):
        variants = [{}]
        # 库实际用到的 combo 组合。
        for cs in sorted(combo_sets, key=lambda s: sorted(s)):
            d = {k: v for k, v in cs}
            if d not in variants:
                variants.append(d)
        # 为「适配所有壁纸」预建该 shader **声明的**每个特性 combo(单开)+ 常见 PBR 组合,
        # 即使本库未用(从 .frag 的 {"combo":"X"} 注解提取)。combo 默认值多为 0,这里建 =1 变体。
        fp = os.path.join(SHARED_SHADERS, shader_base + ".frag")
        declared = sorted(set(re.findall(r'"combo"\s*:\s*"([A-Za-z_]+)"',
                          open(fp, encoding="utf-8", errors="ignore").read()))) if os.path.exists(fp) else []
        for cb in declared:
            d = {cb: "1"}
            if d not in variants:
                variants.append(d)
        # 常见多特性组合(法线+光照+PBR遮罩;反射+法线)——覆盖典型 PBR/反射壁纸。
        for combo_dict in ({"NORMALMAP": "1", "LIGHTING": "1", "PBRMASKS": "1"},
                           {"REFLECTION": "1", "NORMALMAP": "1"},
                           {"EMISSIVE_MAP": "1"}):
            d = {k: v for k, v in combo_dict.items() if k in declared}
            if d and d not in variants:
                variants.append(d)
        built = []
        for combos in variants:
            ck = combo_key(combos)
            try:
                rec = build_material(shader_base, combos)
                if rec and rec.get("frag"):
                    built.append({"combos": combos, "passes": [rec]}); variant_count += 1
                else:
                    fail.append((f"material/{shader_base}/{ck}", "transpile 失败/缺文件"))
            except Exception as e:
                fail.append((f"material/{shader_base}/{ck}", str(e)[:200]))
        if built:
            manifest[f"material/{shader_base}"] = {"variants": built}; mat_ok.append(shader_base)

    # 先写 manifest(无论后续是否因失败退出,manifest 必须落盘,别让失败导致 manifest 不生成)。
    json.dump(manifest, open(os.path.join(OUT, "WEEffects.json"), "w"), indent=1, ensure_ascii=False)
    # 失败清单落盘:每条 {"key": "effect/combo", "error": "..."},供排查所有(含非 base)变体失败。
    fail_records = [{"key": n, "error": e} for n, e in fail]
    json.dump(fail_records, open(os.path.join(OUT, "WEEffects.fail.json"), "w"), indent=1, ensure_ascii=False)
    print(f"=== 打包完成:{len(ok)} builtin + {len(ws_ok)} workshop + {len(pl_ok)} pkg-local + {len(mat_ok)} 基础材质 OK, {len(fail)} FAIL;变体总数 {variant_count} ===")
    if mat_ok: print("材质 OK:", ", ".join(mat_ok))
    print("OK :", ", ".join(ok))
    print("WORKSHOP:", ", ".join(ws_ok))
    if pl_ok: print("PKG-LOCAL:", ", ".join(pl_ok))
    for n, e in fail: print(f"FAIL {n}: {e}")
    print(f"MSL 文件: {len(os.listdir(MSL_DIR))}")
    print(f"fail.json: {len(fail_records)} 条 → {os.path.join(OUT, 'WEEffects.fail.json')}")
    # 有失败 → 退出码 1(manifest 已先写出,不影响下游消费已成功的部分)。
    if fail:
        sys.exit(1)

if __name__ == "__main__":
    main()
