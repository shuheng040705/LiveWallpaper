#!/usr/bin/env python3
"""
WE 着色器方言 → Metal(MSL)转译器原型。
管线:WE GLSL 方言 →(本预处理器:prelude+include+combo+uniform-block+varying)→ 标准 Vulkan GLSL
      → glslangValidator → SPIR-V → spirv-cross → MSL。

WE 的 .vert/.frag 是 HLSL/GLSL 混合方言,方言宏(mul/frac/texSample2D/CAST*/lerp/saturate)
由引擎在编译期注入 prelude;此处重建该 prelude(GLSL 目标)。参考 linux-wallpaperengine 的做法。

用法: we_transpile.py <shader.frag|.vert> [COMBO=val ...]
"""
import sys, os, re, subprocess, tempfile

WE = os.path.expanduser("~/Library/Application Support/CrossOver/Bottles/Steam/drive_c/Program Files (x86)/Steam/steamapps/common/wallpaper_engine/assets")
SHADERS = os.path.join(WE, "shaders")

# WE 方言 → GLSL 的 prelude(宏 + 兼容函数)。frac/lerp/saturate/mul/CAST*/texSample* 等。
PRELUDE = r"""
#define frac(x) fract(x)
#define lerp(a,b,t) mix(a,b,t)
#define saturate(x) clamp(x, 0.0, 1.0)
#define atan2(y,x) atan(y,x)
#define ddx(x) dFdx(x)
#define ddy(x) dFdy(-(x))
#define fmod(x,y) ((x)-(y)*trunc((x)/(y)))
#define log10(x) (log2(x) * 0.301029995663981)
#define CAST2(x) vec2(x)
#define CAST3(x) vec3(x)
#define CAST4(x) vec4(x)
#define CAST2X2(x) mat2(x)
#define CAST3X3(x) mat3(x)
#define CAST4X4(x) mat4(x)
// HLSL tex2D/SampleLevel 截断坐标到 .xy(WE 个别 shader 把 vec4 varying 整个传进 texSample2D,
// 如 clipping_mask 的 `varying vec4 v_TexCoord` → texSample2D(g_Texture0, v_TexCoord);xy=主 UV、
// zw=备用)。GLSL 的 texture(sampler2D, ...) 只收 vec2 → 「no matching overloaded function」。
// 用 (uv).xy 取前两维:vec2 时 .xy 恒等、vec4/含括号表达式时截断,均安全(2D 采样坐标本就 2 维;
// 全库 builtin 的 texSample2D* 坐标实测都是 vec2,故对现有通过的 shader 是恒等)。
#define texSample2D(s,uv) texture(s,(uv).xy)
#define texSample2DLod(s,uv,l) textureLod(s,(uv).xy,l)
#define texSample2DGrad(s,uv,dx,dy) textureGrad(s,(uv).xy,dx,dy)
// WE common.h 权威定义 mul(x,y)=(y)*(x)(见参考 ShaderUnit.cpp:30)。WE shader 写
// mul(pos, MVP) 期望 = MVP*pos(列主序正确变换)。之前误按 HLSL 语义写成 (a)*(b)=pos*MVP=转置,
// 仅当 MVP=单位阵(全屏后处理)时碰巧等价;非平凡变换会转置错。照 WE 改成 (b)*(a)。
#define mul(a,b) ((b)*(a))
"""

def read(path):
    with open(path, encoding="utf-8", errors="ignore") as f:
        return f.read()

# ---- #require 模块(对齐 ShaderUnit.cpp:313-377）----
# WE shader 可写 `#require LightingV1` 等指令,引擎据此「动态生成」对应函数桩注入源码。
# linux-wallpaperengine 的 resolveRequireModule()/generateLightingV1():LightingV1 → 生成
# PerformLighting_V1(...) 桩(因 lwe 尚不支持光源对象,返回 vec3(0.0) 无动态光贡献)。我们同理:
# 不解析 #require 会让任何含该指令的 workshop shader 残留 `#require`(GLSL 非法预处理指令)→ 编译失败被跳过。
# 处理:comment 掉 `#require`(`#r`→`//`,保持长度不变,与参考一致),并在该位置注入桩函数定义。
def _module_lighting_v1():
    # 与 ShaderUnit.cpp::generateLightingV1 逐字对齐:返回 vec3(0.0) 的 PerformLighting_V1 桩。
    return ("// begin of generated module LightingV1\n"
            "vec3 PerformLighting_V1(vec3 worldPos, vec3 albedo, vec3 normal, vec3 viewDir,\n"
            "    vec3 specularTint, vec3 baseReflectance, float roughness, float metallic)\n"
            "{\n"
            "    return vec3(0.0);\n"
            "}\n"
            "// end of generated module LightingV1\n")

# moduleName → 生成代码(空串表示未知模块,照参考仅注释掉指令、不注入)。
_REQUIRE_MODULES = {
    "LightingV1": _module_lighting_v1,
}

_REQUIRE_RE = re.compile(r'^([ \t]*)#require[ \t]+(\S+)[ \t]*\r?$', re.M)
def resolve_requires(src):
    """解析 `#require <Module>`:注释掉指令并在原位注入对应模块桩(ShaderUnit.cpp::preprocessRequires)。
    未知模块仅注释掉指令(与参考 resolveRequireModule 返回空串一致)。无 #require 时为恒等变换。"""
    def repl(m):
        indent, name = m.group(1), m.group(2)
        gen = _REQUIRE_MODULES.get(name)
        code = gen() if gen else ""
        # comment 掉原指令(保留缩进),桩代码插在其后
        return f"{indent}// [we_transpile] #require {name}\n{code}"
    return _REQUIRE_RE.sub(repl, src)

def inline_includes(src, seen=None, search_dirs=None):
    if seen is None: seen = set()
    dirs = (search_dirs or []) + [SHADERS]   # 先找 effect 本地,再找全局 common
    out = []
    for line in src.splitlines():
        m = re.match(r'\s*#include\s+"([^"]+)"', line)
        if m:
            name = m.group(1)
            if name in seen:
                continue
            seen.add(name)
            p = next((os.path.join(d, name) for d in dirs if os.path.exists(os.path.join(d, name))), None)
            if p:
                out.append(f"// >>> include {name}")
                out.append(inline_includes(read(p), seen, search_dirs))
                out.append(f"// <<< end {name}")
            else:
                out.append(f"// MISSING include {name}")
        else:
            out.append(line)
    return "\n".join(out)

# 默认 combo(被传入的真实 combo 覆盖)。BLENDMODE 等被当数值用,未定义会「undeclared identifier」。
# 注:仅作最末兜底;每个 shader 的 [COMBO] 行自带 default(如 bloom apply 的 BLENDMODE 默认 31=
# 加性叠加),由 combo_defaults() 提取,优先级高于此处,低于 scene/material 真实 combo。
DEFAULT_COMBOS = {"BLENDMODE": "0"}

# 提取 shader 源里 [COMBO] 行声明的 combo 默认值:
#   // [COMBO] {"combo":"BLENDMODE","default":31,...}  → {"BLENDMODE":"31"}
# 这是 WE 编译期注入的 combo 初值(场景未覆盖时用);漏掉会让 BLENDMODE 等退 0 → 画面错
# (如 bloom apply 退成 BlendNormal「替换」而非「加性」,整帧被暗淡的辉光图替换变黑)。
import json as _json
_COMBO_LINE_RE = re.compile(r'//\s*\[COMBO\]\s*(\{.*\})')
def combo_defaults(src):
    out = {}
    for line in src.splitlines():
        m = _COMBO_LINE_RE.search(line)
        if not m:
            continue
        try:
            j = _json.loads(m.group(1))
        except Exception:
            continue
        c = j.get("combo")
        if c is not None and j.get("default") is not None:
            d = j["default"]
            # default 可能是数值(直接用)或字符串(options 名,跳过——只数值参与预处理 #if)。
            if isinstance(d, (int, float)):
                out[c] = str(int(d) if float(d).is_integer() else d)
    return out

# ---- sampler 的 combo/require/requireany 联动(对齐 ShaderUnit.cpp::parseParameterConfiguration 531-619)----
# WE 的 sampler uniform 可带元数据 `// {"combo":"X","require":{...},"requireany":bool,"default":...}`。
# 引擎据「该贴图槽是否被占用」+「其它 combo 的值」决定是否「发现/启用」该采样 combo(写进 #define)。
# 不实现会让某些单通道法线/遮罩 shader 的采样分支(`#if MASK`/`#if TEX` 等)取不到应有的 combo 值 → 走错
# 分支(漏采遮罩/法线)。这是 WE 编译期注入的「discovered combos」,优先级最低(不覆盖 scene/material combo)。
_SAMPLER_META_RE = re.compile(r'uniform\s+(sampler2D\w*)\s+(g_Texture(\d+))\s*;\s*//\s*(\{.*\})')
def discover_sampler_combos(src, current_combos, bound_slots):
    """据 sampler 元数据 + 已绑定的贴图槽(bound_slots:被占用的 slot 索引集合)+ 现有 combo,
    复刻 ShaderUnit.cpp:531-619 推导出应启用的采样 combo。返回 {COMBO: value}(仅「发现」的,
    不含已由 scene/material 提供的)。current_combos 用原始大小写键查 require(与 m_combos 一致)。
    src 应为含元数据注释的原始源(strip_meta 前)。无命中(全库现状)时返回空 → 现有 effect 零影响。"""
    discovered = {}
    def _has(macro):
        return macro in current_combos
    def _val_eq(macro, want):
        # m_combos[macro] == item.value():按数值比较(combo 值与 require 值都规整成数字串再比)
        if macro not in current_combos:
            return False
        try:
            return float(current_combos[macro]) == float(want)
        except (TypeError, ValueError):
            return str(current_combos[macro]) == str(want)
    for m in _SAMPLER_META_RE.finditer(src):
        try:
            j = _json.loads(m.group(4))
        except Exception:
            continue
        combo = j.get("combo")
        if combo is None:                       # 无 combo 的 sampler 直接忽略(ShaderUnit:545)
            continue
        index = int(m.group(3))                 # g_TextureN 的 N(ShaderUnit 从名字第 9 位取)
        defvalue = j.get("default")
        require = j.get("require")
        requireany = bool(j.get("requireany"))
        texture_slot_used = index in bound_slots
        is_required = False
        combo_value = 1
        if texture_slot_used:
            # 贴图存在则该 combo 必须置位(通常无 default)。ShaderUnit:553-556
            is_required = True
        elif isinstance(require, dict):
            if requireany:
                # requireany:require 里**任一**项不匹配当前 combo 即视为需要。ShaderUnit:558-571
                for macro, want in require.items():
                    it_missing = macro not in current_combos
                    if it_missing or (macro in current_combos and not _val_eq(macro, want)):
                        is_required = True
                        break
            else:
                # all-match:先置 True,若**任一** require 项已存在且匹配 → 置 False。ShaderUnit:572-587
                is_required = True
                for macro, want in require.items():
                    if (macro in current_combos) and _val_eq(macro, want):
                        is_required = False
                        break
        # 槽未占用但被判需要时,须有数值 default 才真正启用(ShaderUnit:590-611)
        if is_required and not texture_slot_used:
            if defvalue is None:
                is_required = False
            elif combo in current_combos:
                # 已有 combo 提供该值,无需再发现
                is_required = False
            elif isinstance(defvalue, str):
                try:
                    combo_value = int(defvalue)        # 字符串数值 default → 转 int
                except ValueError:
                    # default 是纹理名(如 "util/white")而非数值 → 无法确定 combo 值,跳过(不抛)
                    is_required = False
            elif isinstance(defvalue, (int, float)):
                combo_value = int(defvalue)
            else:
                is_required = False
        if is_required:
            discovered[combo] = str(combo_value)   # ShaderUnit:613-618 emplace 到 discoveredCombos
    return discovered

# GLSL ≥400 的保留字,WE 当普通标识符用 → 改名。sample(godrays/blur 的 vec4 变量)。
def rename_reserved(src):
    # \bsample\b 只匹配独立小写 sample(不碰 texSample2D / noiseSample / sampleDrop)。
    src = re.sub(r'\bsample\b', 'samp_', src)
    # HLSL 隐式截断:WE 把 vec4 传给 rotateVec2(vec2,float)(如 shimmer 的 v_TexCoord)。
    # GLSL 不允许 → 给 rotateVec2 的标识符首参补 .xy(vec2.xy 是恒等,vec4.xy 截断,均安全)。
    src = re.sub(r'rotateVec2\(\s*(\w+)\s*,', r'rotateVec2(\1.xy,', src)
    # HLSL 把 float uniform 经 int() 存进 float、再当 int 用(循环计数 `for(int i=-x;i<=x;...)`)。
    # GLSL 不允许 float→int 隐式转。整条 RHS 就是 int(...) 时,把声明改成 int(后续 float 运算 GLSL 会自动 int→float)。
    src = re.sub(r'\bfloat\s+(\w+)\s*=\s*int\(([^;]*)\)\s*;', r'int \1 = int(\2);', src)
    # HLSL 的 `%` 在浮点上等价 fmod,结果再隐式截断进 uint;GLSL 的 `%` 仅整数、且 float→uint 隐式转非法
    #(旧版 Simple_Audio_Bars:`uint barFreq1 = frequency % RESOLUTION;`,frequency 是 float、RESOLUTION 是
    # int 宏 → glslang「' to ' temp highp uint」)。新版 WE 自身已改用 mod2(frequency, float(RESOLUTION)) 再
    # int() 索引,语义即「浮点取模后截断为整」。照此重写为 int NAME = int(mod(float(A), float(B)));(GLSL mod
    # = fmod,忠实 HLSL;声明改 int 供数组索引,uint 同样合法但 int 与新版一致)。仅命中带 `%` 的 uint 声明。
    src = re.sub(r'\buint\s+(\w+)\s*=\s*(.+?)\s*%\s*(.+?)\s*;',
                 r'int \1 = int(mod(float(\2), float(\3)));', src)
    # HLSL `int X = step(...)`:step 返回 float、HLSL 隐式截断进 int(旧版 Simple_Audio_Bars 的
    # `int bar = step(...)`)。但该变量随后还乘 smoothstep 等 float(`bar *= ...`),WE 新版正是把它改成
    # `float bar = float(step(...))`(声明即 float,边缘硬切但后续浮点裁剪正确)。GLSL float→int 隐式转非法,
    # 故照新版把这类 step 初始化的 int 声明改回 float(忠实 WE 新版、且修旧版乘 float 被再截断为 0 的隐患)。
    src = re.sub(r'\bint\s+(\w+)\s*=\s*(step\s*\()', r'float \1 = \2', src)
    # HLSL 赋值截断:`vec3/vec2/float X = texSample2D(...);`(返回 vec4)。GLSL 要显式 swizzle。
    swz = {"vec3": ".rgb", "vec2": ".rg", "float": ".r"}
    def _trunc(m):
        return f"{m.group(1)}{m.group(2)} {m.group(3)} = {m.group(4)}{swz[m.group(2)]};"
    src = re.sub(r'(\s*)(vec3|vec2|float)\s+(\w+)\s*=\s*(texSample2D\w*\(.*\))\s*;\s*$',
                 _trunc, src, flags=re.MULTILINE)

    # vec4 varying 实为 2D 坐标:个别 shader 把坐标 varying 过声明成 vec4(vert 只写 .xy、.zw 恒未用),
    # frag 却拿它整体做 2D 向量算术(clipping_mask 的 `varying vec4 v_TexCoord` → `v_TexCoord*2.0-1.0-
    # texScaleCenter`,后者 vec2)。HLSL 把 vec4 截断到 vec2 再算;GLSL 的 vec4±vec2 直接类型错。修法:
    # 检出「被当 2D 坐标用」的 vec4 varying —— 即该 vec4 varying 在本 frag 出现裸算术(其前/后紧邻 +-*/),
    # 则把它所有「裸用」(非声明、其后无 swizzle)统一改成 .xy(忠实 HLSL 截断;.zw 既未被 vert 写,丢弃无损)。
    # 类型感知 + 需出现裸算术才触发:全库仅 clipping_mask 命中,正常 vec4 varying(.xy/.zw 双坐标用)不动。
    for V in set(re.findall(r'\bvarying\s+vec4\s+(\w+)\s*;', src)):
        used_in_arith = (re.search(r'\b' + re.escape(V) + r'\s*[*/+\-]\s*[\d(]', src)
                         or re.search(r'[*/+\-]\s*' + re.escape(V) + r'\b(?!\s*\.)', src))
        if not used_in_arith:
            continue
        # 改裸用 → V.xy:其后是 . 或 ; 的不改 —— 排除已有 swizzle(V.xxx)与声明行 `varying vec4 V;`
        #(声明里 V 后紧跟 ;)。故不必再特判声明。
        src = re.sub(r'\b' + re.escape(V) + r'\b(?!\s*[.;])', V + '.xy', src)

    # HLSL `lerp`(=mix)隐式截断:`X.rgb = mix(X, V3, s);` —— X 是 vec4、V3 是 vec3,HLSL 把 vec4 首参
    # 截断成 vec3 与 V3 同型,结果再写回 X.rgb(shift_hue / hue_shift 的 `albedo.rgb = mix(albedo,
    # newAlbedo, mask)`)。GLSL 的 mix 三参须同型 → 「no matching overloaded function」。LHS 已是
    # X.rgb/.xyz(vec3),故把 mix 的同名首参 X 补成 X.rgb/.xyz(与 LHS 同 swizzle),即 HLSL 语义。
    # 仅命中「首参 == 被赋值的同一变量、且其后无 swizzle」的这一畸形(全库仅这两行),正常 mix 不动。
    src = re.sub(r'\b(\w+)\.(rgb|xyz)(\s*=\s*(?:mix|lerp)\s*\(\s*)\1\b(?!\s*\.)',
                 r'\1.\2\3\1.\2', src)

    # HLSL 标量广播:`X.rgb = greyscale(...);` —— WE 的 greyscale(vec3) 返回 float,HLSL 允许标量广播到
    # vec3,GLSL 不允许 → glslang「cannot convert from 'float' to '3-component vector'」(color_grading 的
    # GREYSCALE 变体)。窄规则:仅对已知返回标量的函数(greyscale)在赋给 .rgb/.xyz 时把整个调用包成
    # vec3(...),即 HLSL 标量广播语义。其它赋给 .rgb/.xyz 的函数(mix/pow/invertValue/vibrance/... 全返回
    # vec3)不动 —— 不靠类型猜测、只针对已知标量函数,绝不误伤本就是 vec3 的赋值。
    src = re.sub(r'(\.(?:rgb|xyz)\s*=\s*)(greyscale\s*\((?:[^();]|\([^()]*\))*\))(\s*;)',
                 r'\1vec3(\2)\3', src)

    # HLSL float/int 作三元条件:`vecN x = cond ? a : b;`,cond 是 float/int(非 bool)→ HLSL 视非零为真。
    # GLSL 的 ?: 条件须 bool → 「boolean expression expected」(frame_builder 的 `vec4 final = outside ?
    # inSmooth : outSmooth`,outside 是 float 标志)。用 bool(cond) 包裹(bool(float)/bool(int) 都合法,
    # 非零即真,正合 HLSL)。仅命中「= 单标识符 ?」这一形态(全库仅 frame_builder 的 outside 与 color_grading
    # 的 LINEAR 组合宏;后者 bool(0/1) 同样正确,且其行在 base 变体被 #if 剔除 → 零影响)。
    # 负向断言:`=` 须是真赋值号 —— 前不可是 =!<>(排除 == != <= >=)、后不可紧跟 =(排除 ==)。
    src = re.sub(r'(?<![=!<>])(=\s*)(?!=)([A-Za-z_]\w*)(\s*\?)', r'\1bool(\2)\3', src)

    # HLSL 向量乘法尺寸不匹配截断:`vec2/vec3 N = V4 * ...`,V4 是 vec4 局部/uniform/varying,右乘 vec2 等
    # 小向量(iris_movement 的 `vec2 da = transformedCursorPosition * g_CursorScale * ...`,后者 vec2)→
    # HLSL 把 vec4 截断到较小操作数尺寸再逐分量乘。GLSL 拒绝 vec4*vec2 → 类型错。按 LHS 声明尺寸给该 vec4
    # 首项补 .xy/.xyz(类型感知:仅当首项确为本文件声明的 vec4 标识符才补,全库仅此一处命中,非盲改)。
    v4names = set(re.findall(r'\bvec4\s+(\w+)', src))
    v4names |= set(re.findall(r'(?:uniform|varying|attribute|in|out)\s+vec4\s+(\w+)', src))
    if v4names:
        swz2 = {"vec2": ".xy", "vec3": ".xyz"}
        def _vmul(m):
            return (f"{m.group(1)} {m.group(2)} = {m.group(3)}{swz2[m.group(1)]} *"
                    if m.group(3) in v4names else m.group(0))
        src = re.sub(r'\b(vec2|vec3)\s+(\w+)\s*=\s*([A-Za-z_]\w*)\s*\*', _vmul, src)

    # HLSL 标量字面量广播进 min/max 的向量参数:`max(0, albedo.rgb)`(nitro frag) —— 首参是裸数字字面量
    # `0`、次参是向量(`.rgb` swizzle)。HLSL 把标量 0 广播成 vec3(0,0,0) 与 albedo.rgb 同型逐分量取 max。
    # GLSL 的 max/min 无 max(int|float, vec3) 重载(genType,float 仅允许标量在第二参)→「no matching
    # overloaded function」。修法:把首参字面量提升成与次参 swizzle 同尺寸的 vecN(literal)(HLSL 广播语义)。
    # 窄规则:仅命中「min/max(<纯数字字面量>, <标识符>.<2~4 位 swizzle>)」—— 次参须是带向量 swizzle 的单标识符。
    # 全库 builtin 仅 nitro 命中;其余 max/min(标量,标量) 是合法 GLSL,次参无向量 swizzle → 不触发,零影响。
    _swz_vec = {2: "vec2", 3: "vec3", 4: "vec4"}
    def _mm(m):
        fn, lit, var, swz = m.group(1), m.group(2), m.group(3), m.group(4)
        n = len(swz)
        if n < 2 or n > 4:               # 单分量 swizzle(.r/.x)是标量 → 不需广播
            return m.group(0)
        v = "." in lit and lit or (lit + ".0")
        return f"{fn}({_swz_vec[n]}({v}), {var}.{swz})"
    src = re.sub(r'\b(max|min)\s*\(\s*([0-9]+(?:\.[0-9]*)?)\s*,\s*([A-Za-z_]\w*)\.([xyzwrgba]+)\s*\)',
                 _mm, src)

    # HLSL 把关系比较 `(a < b)` 当 float(真=1.0/假=0.0)直接参与算术:`depth *= (depth < limit) * 6.0;`
    # (bokeh_blur 的 gaussian.frag,PRECISE 分支)。GLSL 的 `<`/`>`/`<=`/`>=` 返回 **bool**,bool*float
    # 非法 → glslang「no operation '*' exists that takes ... 'bool' and ... 'float'」,且该错误会让 glslang
    # 中途 abort、连带报「missing #endif」(实为解析中断的次生现象,非真的 #if/#endif 不配对)。修法:把
    # 「直接与 `*`/`/` 算术相邻的、括号内的单个关系比较」包成 float(...)(HLSL bool→float 语义)。
    # ⚠️ 已撤销(2026-06):此处曾加一条全局正则把「与 `*`//` 相邻的括号内关系比较」包 float(...) 以救
    # bokeh_blur(gaussian.frag PRECISE 分支)。但该规则太宽,**误伤 workshop shader 2846660316**
    # (凯尔希·思衡托 3718176724 主角特效)——把它的某处比较/三元表达式包坏 → 整屏噪点(meanDiff 106)。
    # agent 当初只验了 builtin 语料、没验 workshop。bokeh_blur 本就是**旧有失败**(不修≠回归),而破坏一张
    # 正常壁纸不可接受。故撤销整条规则(t2/raindrop 不依赖它,仍正常)。bokeh 的真解需针对 gaussian.frag
    # 那一行做**精确**改写(非全局正则),留待后续。
    return src

# ---- 链接驱动的 varying vec2↔vec4 双向兼容(对齐 ShaderUnit.cpp:379-440)----
# WE 的 vert/frag 用同名 varying 跨阶段传值,但两阶段对同一 varying 的声明类型可能不一致
# (HLSL 隐式截断/补齐使其在 WE 内合法)。GLSL/SPIR-V 的阶段接口按 location 严格按类型匹配,
# 类型不一致 → 链接/建管线失败。参考用两个「链接驱动」函数解决,均需查对端 stage 的接口:
#   ① applyLinkedVaryingCompatibility(顶点阶段):若 frag 声明 `varying vec4 NAME` 而 vert 声明
#      `varying vec2 NAME` → 把 vert 的声明升成 vec4,并把 vert 里对 NAME 的整体赋值 `NAME = expr;`
#      包成 `NAME = vec4(expr, 0.0, 1.0);`(补齐到 vec4,与 frag 端类型一致)。
#   ② applyFragmentTexCoordCompatibility(片元阶段):若 frag 把宽 v_TexCoord(vec3/vec4)直接与
#      CAST2(...) 做算术(HLSL 截断到 vec2 再算),GLSL 的 vecN±vec2 类型错 → 在这些算术处把
#      v_TexCoord 改成 v_TexCoord.xy。
# 这取代旧的「单向截断 + 具名 hack」:改成查两 stage 接口、按链接关系驱动,适用任意 workshop shader。
_VARYING_DECL_RE = re.compile(r'\bvarying\s+(\w+)\s+(\w+)\s*(\[[^\]]*\])?\s*;')
def _collect_varying_types(src):
    """src 内每个 varying 名 → 其声明类型(vec2/vec3/vec4/...);用于查对端 stage 接口。"""
    out = {}
    for m in _VARYING_DECL_RE.finditer(src):
        out[m.group(2)] = m.group(1)
    return out

def apply_linked_varying_compat(src, stage, link_src):
    """据对端 stage 源(link_src,已 include 展开)做 varying 双向兼容。link_src 为空则只做不依赖
    对端的片元侧截断(②)。对两阶段类型本就一致的 varying 是恒等变换(现有 28+29 effect 零影响)。"""
    link_types = _collect_varying_types(link_src or "")
    if stage == "vert":
        # ① vert vec2 + frag vec4 → 升 vert 到 vec4 并补齐赋值(ShaderUnit.cpp:379-415)
        self_types = _collect_varying_types(src)
        for name, vtype in list(self_types.items()):
            if vtype != "vec2":
                continue
            if link_types.get(name) != "vec4":
                continue
            # 升声明 vec2→vec4
            src = re.sub(r'\bvarying\s+vec2\s+' + re.escape(name) + r'\s*;',
                         f'varying vec4 {name};', src)
            # 把对 NAME 的整体赋值 `NAME = expr;`(其后无 swizzle)补齐成 vec4(expr, 0.0, 1.0)
            assign_re = re.compile(r'(^|\n)([ \t]*)' + re.escape(name) + r'\b(?!\s*\.)\s*=\s*([^;\n]+);')
            def _wrap(m):
                return f"{m.group(1)}{m.group(2)}{name} = vec4({m.group(3)}, 0.0, 1.0);"
            src = assign_re.sub(_wrap, src)
        # 审计修复 #4:反向(vert vec4 + frag vec2,如 workshop color_grading)。Metal/SPIR-V 的阶段接口按
        # location **严格按类型匹配**,vec4(vert out)↔vec2(frag in)不一致 → makeRenderPipelineState 建不成。
        # 选不丢数据的方向:把**顶点输出降到与片元一致的宽度**(片元只消费它声明的 .xy 分量,降维无损)。
        # color_grading 的 vert 是 `varying vec4 v_TexCoord; ... v_TexCoord.xy = a_TexCoord;`(只写 .xy),frag
        # 声明 `varying vec2 v_TexCoord`。降法:
        #   ① 声明 vec4→vec2(与 frag 一致);
        #   ② 若 vert 对 NAME 有「整体赋值」`NAME = expr;`(其后无 swizzle,expr 是 vecN)→ 截成 `NAME = (expr).xy;`;
        #      已是部分写 `NAME.xy = ...`(. 后跟 xy)的在 vec2 上恒合法,不改。
        # 安全护栏:仅当 vert 对 NAME **没有写 .z/.w/.zw 等高位分量**(写了说明 vert 确实用到 >2 维,降维会丢数据)
        #   才降;否则保守跳过(留给链接层,与改动前一致),绝不丢数据。frag 宽于 vert 的本不该出现(片元读不到
        #   未传的分量),不处理。仅命中 vert>frag 的窄化,现有两阶段同型 varying 零影响。
        for name, vtype in list(self_types.items()):
            if vtype != "vec4":
                continue
            if link_types.get(name) != "vec2":
                continue
            # 护栏:vert 是否对 NAME 写了高位分量(.z/.w/.zw/.zwx... 任意含 z/w 的写)。
            hi_write = re.search(r'\b' + re.escape(name) + r'\.[xyzwrgba]*[zwba][xyzwrgba]*\s*=(?!=)', src)
            if hi_write:
                continue   # vert 用到 >2 维 → 降维会丢数据,保守不动
            # ① 降声明 vec4→vec2
            src = re.sub(r'\bvarying\s+vec4\s+' + re.escape(name) + r'\s*;',
                         f'varying vec2 {name};', src)
            # ② 整体赋值 `NAME = expr;`(其后非 . / 非 ;)→ 截 .xy(expr 原为宽向量,取前两维与 frag 一致)
            assign_re = re.compile(r'(^|\n)([ \t]*)' + re.escape(name) + r'\b(?!\s*[.;])\s*=\s*([^;\n]+);')
            def _narrow(m):
                return f"{m.group(1)}{m.group(2)}{name} = ({m.group(3)}).xy;"
            src = assign_re.sub(_narrow, src)
    elif stage == "frag":
        # ② 宽 v_TexCoord(vec3/vec4)与 CAST2(...) 做算术 → 在算术处截 .xy(ShaderUnit.cpp:417-440)
        if re.search(r'\bvarying\s+vec[34]\s+v_TexCoord\s*;', src):
            tex_before = re.compile(r'\bv_TexCoord\b(\s*[-+*/]\s*CAST2\s*\()')
            cast_before = re.compile(r'(CAST2\s*\([^)]+\)\s*[-+*/]\s*)\bv_TexCoord\b')
            if tex_before.search(src) or cast_before.search(src):
                src = tex_before.sub(r'v_TexCoord.xy\1', src)
                src = cast_before.sub(r'\1v_TexCoord.xy', src)
    return src

def strip_meta(src):
    # 去掉 uniform 行尾的 JSON 元数据注释 // {...} 和 // [COMBO] {...} 行。
    lines = []
    for line in src.splitlines():
        if re.match(r'\s*//\s*\[COMBO\]', line):
            continue
        # 个别 workshop 着色器把 varying 写成带 swizzle 的非法声明(frame_builder frag 的
        # `varying vec4 v_Size.xy;`)。声明上的 .xy 无意义、基名 v_Size 才是 varying,且与同 effect
        # vert 的 `varying vec4 v_Size;` 及 frag 内用法(v_Size.xy/.zw)一致 → 去掉声明名上的 swizzle
        # 后缀使其可被转成 out/in(否则残留 `varying`→core profile 报错)。仅命中此非法形态,不动正常声明。
        line = re.sub(r'^(\s*(?:varying|attribute)\s+\S+\s+\w+)\.[xyzwrgba]+(\s*;)', r'\1\2', line)
        # 去掉行内 // {...} 元数据(保留普通注释里不含 { 的)
        line = re.sub(r'//\s*\{.*$', '', line)
        lines.append(line)
    return "\n".join(lines)

_IF_RE = re.compile(r'^\s*#\s*(?:if|ifdef|ifndef)\b')
_ENDIF_RE = re.compile(r'^\s*#\s*endif\b')
def balance_ifdefs(src):
    """修补 #if/#endif 不配对:① 深度已为 0 时再来的 #endif(多余)注释掉;② EOF 仍有未闭合 #if 则补足
    #endif。对配对良好的着色器是恒等变换(深度永不<0、EOF 为 0),故不动现有通过的着色器(它们必然平衡,
    否则 glslang 早拒)。某些 workshop 自定义着色器源就多/少一个 #endif —— 如 simple_audio_bars_modified /
    enhanced 的 vert 源多一个 #endif(8 个 #if / 9 个 #endif,DEFORMITY 块外多出的孤立 #endif),WE 自带
    预处理器对此宽容;此处复现该宽容(仅平衡指令,不伪造任何渲染数据/系数)。"""
    out, depth = [], 0
    for line in src.splitlines():
        if _IF_RE.match(line):
            depth += 1; out.append(line)
        elif _ENDIF_RE.match(line):
            if depth == 0:
                out.append("// [we_transpile] 丢弃多余 #endif: " + line.strip())
            else:
                depth -= 1; out.append(line)
        else:
            out.append(line)
    if depth > 0:
        out.append("// [we_transpile] 补足 %d 个缺失 #endif" % depth)
        out.extend(["#endif"] * depth)
    return "\n".join(out)

# ---- 预处理条件求值(对齐 C/GLSL 预处理器,供 classify_uniforms 跳过死分支里的 uniform)----
# classify_uniforms 会把所有 `uniform ...;` 行**无条件**从 body 提到顶部 UBO/sampler 段。但 WE 着色器
# 常把 uniform 写在 `#if LIGHTS_SHADOW_MAPPING` / `#if LIGHTING` 等条件块内 —— 当 combo 关闭时这些块在
# body 里会被 glslang 的预处理器剔除,可被提到顶部的副本却仍**无条件**存在。一般情形下(类型合法)只是
# 多塞了几个不用的 uniform 进 UBO,无害;但 fluidsimulation_combine.frag 的 `#if LIGHTS_SHADOW_MAPPING`
# 块里声明的是 `uniform sampler2DComparison g_Texture6;` —— sampler2DComparison 是 WE/HLSL 方言的比较
# (shadow)采样器类型,GLSL 无此关键字 → glslang 在该提到顶部的 sampler 声明处报
# 「syntax error, unexpected IDENTIFIER, expecting COMMA or SEMICOLON」+「Missing entry point」,整个 frag
# 编不过。真值参照 WE:LIGHTS_SHADOW_MAPPING 仅在场景开启 shadow mapping 时为 1,effect 链默认(LIGHTING=0)
# 该块整体不参与编译。故 classify_uniforms 接受当前 combo,**只提取在当前 combo 下存活的** uniform —— 与
# WE「从预处理后的源收集 uniform」一致,死分支里的 sampler2DComparison 自然不再被提出。
# 这只 gate「条件块内」的 uniform;顶层(depth 0)uniform 永远存活,故对现有通过的着色器零影响。
def _pp_value(tok, active):
    tok = tok.strip()
    if re.fullmatch(r'[+-]?\d+', tok):
        return int(tok)
    m = re.fullmatch(r'defined\s*\(?\s*(\w+)\s*\)?', tok)
    if m:
        return 1 if m.group(1).upper() in active else 0
    name = tok.upper()
    if name in active:
        try:
            return int(float(active[name]))
        except (TypeError, ValueError):
            return 0
    return 0   # 未定义宏 → 0(C 预处理器语义)

# 预处理布尔表达式求值:支持 && || ! () 与比较(WE 着色器的 #if 守卫含
# `#if FOLLOWCURSOR && !MANUALCONTROL`、`#if PERSPECTIVE == 1` 等)。把表达式转成 Python 可 eval 的
# 形式(标识符/比较先归约成 0/1),再求值。**无法解析时返回 None**,调用方据此回退到「无条件提取」
# (保守:宁可多提一个无害 uniform,也不误把活跃块里的 uniform 留在 body 触发 non-opaque 报错)。
def _pp_eval_if(expr, active):
    expr = expr.strip()
    # 去掉行尾注释(`// NOISE` 之类),C 预处理器不看注释
    expr = re.sub(r'//.*$', '', expr).strip()
    expr = re.sub(r'/\*.*?\*/', '', expr).strip()
    if not expr:
        return None
    # 先把比较子式(A OP B,A/B 为标识符或整数)替换成其布尔值的 1/0
    def _cmp(m):
        a = _pp_value(m.group(1), active); op = m.group(2); b = _pp_value(m.group(3), active)
        r = {'==': a == b, '!=': a != b, '>=': a >= b,
             '<=': a <= b, '>': a > b, '<': a < b}[op]
        return '1' if r else '0'
    expr = re.sub(r'(defined\s*\(?\s*\w+\s*\)?|[A-Za-z_]\w*|-?\d+)\s*(==|!=|>=|<=|>|<)\s*'
                  r'(defined\s*\(?\s*\w+\s*\)?|[A-Za-z_]\w*|-?\d+)', _cmp, expr)
    # 剩余的裸标识符/defined(X)/整数 → 0/1
    def _atom(m):
        return '1' if _pp_value(m.group(0), active) else '0'
    expr = re.sub(r'defined\s*\(?\s*\w+\s*\)?|[A-Za-z_]\w*|-?\d+', _atom, expr)
    # 此时 expr 只应含 0/1 与 && || ! ( ) 空格。转成 Python 布尔后 eval。
    if not re.fullmatch(r'[01\s&|!()]*', expr):
        return None
    # 0/1 → True/False(避免依赖被禁用的 bool 内建);&& || ! → and or not
    py = expr.replace('&&', ' and ').replace('||', ' or ').replace('!', ' not ')
    py = re.sub(r'\b1\b', 'True', py)
    py = re.sub(r'\b0\b', 'False', py)
    try:
        return bool(eval(py, {"__builtins__": {}}, {}))
    except Exception:
        return None

def classify_uniforms(src, active_combos=None):
    """把 loose uniform 拆成:sampler(带 binding)+ 其余打进一个 UBO。返回 (新body, ubo_decl, sampler_decls)。
    active_combos:当前生效的 combo(name→str,**大写键**),用于剔除死 #if 分支里的 uniform(见上方注释)。
    为 None 时退回旧行为(无条件提取),保持向后兼容。"""
    active = active_combos
    sampler_decls = []
    ubo_members = []
    body = []
    binding = 0
    cond_stack = []   # 每层 [本分支条件已被某分支取过, 本层当前活跃]
    def _live():
        return all(s[1] for s in cond_stack) if cond_stack else True
    def _parent_live():
        return all(s[1] for s in cond_stack[:-1]) if len(cond_stack) > 1 else True
    for line in src.splitlines():
        s = line.strip()
        # 仅当提供了 active_combos 时才跟踪条件层级(否则保持旧的无条件行为)
        if active is not None:
            d = re.match(r'#\s*(ifdef|ifndef|if|elif|else|endif)\b(.*)', s)
            if d:
                kind, rest = d.group(1), d.group(2)
                if kind == 'ifdef':
                    c = rest.strip().split()[0].upper() in active if rest.strip() else True
                    cond_stack.append([c, c and (_live())])
                elif kind == 'ifndef':
                    c = (rest.strip().split()[0].upper() not in active) if rest.strip() else True
                    cond_stack.append([c, c and (_live())])
                elif kind == 'if':
                    r = _pp_eval_if(rest, active)
                    # 无法求值(None)→ 保守视为「真」(保持无条件提取该块里的 uniform)
                    c = True if r is None else r
                    cond_stack.append([c, c and (_live())])
                elif kind == 'elif' and cond_stack:
                    p = _parent_live()
                    if cond_stack[-1][0]:
                        cond_stack[-1][1] = False
                    else:
                        r = _pp_eval_if(rest, active)
                        c = True if r is None else r
                        cond_stack[-1][0] = cond_stack[-1][0] or c
                        cond_stack[-1][1] = c and p
                elif kind == 'else' and cond_stack:
                    p = _parent_live()
                    cond_stack[-1][1] = (not cond_stack[-1][0]) and p
                    cond_stack[-1][0] = True
                elif kind == 'endif' and cond_stack:
                    cond_stack.pop()
                body.append(line)
                continue
        # 末尾可带数组维度 [N](如 g_AudioSpectrum16Left[16])。漏掉数组后缀会让该 uniform 既不进
        # UBO 也不进 sampler、留在 body 当 loose 非透明 uniform → Vulkan GLSL「non-opaque uniforms
        # outside a block」报错(audio-reactive pulse 的频谱数组就栽在这)。捕获后保留维度搬进 UBO。
        m = re.match(r'\s*uniform\s+(\S+)\s+(\w+)\s*(\[[^\]]*\])?\s*;', line)
        if m:
            # 死 #if 分支里的 uniform 不提取(留在 body,由 glslang 预处理器随该块一起剔除)。
            if active is not None and not _live():
                body.append(line)
                continue
            typ, name, arr = m.group(1), m.group(2), (m.group(3) or "")
            if "sampler" in typ:
                sampler_decls.append(f"layout(set=0, binding={binding}) uniform {typ} {name}{arr};")
                binding += 1
            else:
                ubo_members.append(f"    {typ} {name}{arr};")
            continue
        body.append(line)
    ubo = ""
    if ubo_members:
        ubo = "layout(set=0, binding=15, std140) uniform _Globals {\n" + "\n".join(ubo_members) + "\n};"
    return "\n".join(body), ubo, "\n".join(sampler_decls)

# 行尾可带普通注释(如 `varying vec4 v_TexCoord; // xy = coord`)。strip_meta 只去 //{json} 元数据,
# 普通注释会留下 → 若不容忍,带注释的 varying/attribute 不被转成 in/out,残留 `varying`(core profile
# 已移除)→「varying no longer supported」+ Missing entry point(frame_builder 的 vert 即此)。
VARYING_RE = re.compile(r'(\s*)varying\s+\S+\s+(\w+)\s*(\[[^\]]*\])?\s*;\s*(?://.*)?$')
ATTRIB_RE  = re.compile(r'(\s*)attribute\s+\S+\s+(\w+)\s*(\[[^\]]*\])?\s*;\s*(?://.*)?$')

def collect_varyings(*srcs):
    """跨 vert+frag 收集所有 varying 名,排序成稳定的 name→location(两阶段一致才能匹配)。
    数组 varying(如 `varying vec2 v_TexCoord[4]`)占 N 个连续 location,location 计数要按
    数组大小累加,否则后面的 varying 会和数组的尾巴撞 location(glslang 报错)。"""
    sizes = {}
    for s in srcs:
        for line in s.splitlines():
            m = VARYING_RE.match(line)
            if m:
                name = m.group(2)
                sz = 1
                if m.group(3):  # "[4]" 之类
                    try: sz = max(1, int(m.group(3).strip("[]")))
                    except ValueError: sz = 1
                sizes[name] = max(sizes.get(name, 1), sz)
    locs, loc = {}, 0
    for n in sorted(sizes):
        locs[n] = loc
        loc += sizes[n]
    return locs

def convert_stage(src, stage, vary_locs):
    # varying/attribute → in/out,location 用「跨阶段共享」的 name→loc 表(避免 #if 错位)。
    out_decl = ""
    attr_loc = 0
    res = []
    for line in src.splitlines():
        mv = VARYING_RE.match(line)
        ma = ATTRIB_RE.match(line)
        if mv:
            kw = "in" if stage == "frag" else "out"
            loc = vary_locs[mv.group(2)]
            # 重建声明(保留类型)
            decl = line.strip()[len("varying"):].strip()
            res.append(f"{mv.group(1)}layout(location={loc}) {kw} {decl}")
        elif ma and stage == "vert":
            decl = line.strip()[len("attribute"):].strip()
            res.append(f"{ma.group(1)}layout(location={attr_loc}) in {decl}")
            attr_loc += 1
        else:
            res.append(line)
    src = "\n".join(res)
    if stage == "frag" and "gl_FragColor" in src:
        out_decl = "layout(location=0) out vec4 _fragColor;"
        src = src.replace("gl_FragColor", "_fragColor")
    return src, out_decl

_IN_DECL_RE = re.compile(r'^(\s*layout\(location=\d+\)\s+in\s+)(\S+)\s+(\w+)(\s*;.*)$', re.M)
def shadow_written_inputs(body):
    """HLSL 的 PS 输入是值拷贝、可写;GLSL 的 `in` varying 只读。若 frag body 给某个 `in` varying
    赋值(=/+=/-=/*=//=),GLSL 报「l-value required, can't modify shader input」(geometric_transform
    frag 直接写 v_TexCoord.y/.x 做几何变形)。修法:把被写的 in 声明改名为 _we_ro_<name>,并在 main()
    开头插入 `<type> <name> = _we_ro_<name>;` 的可写拷贝 —— 后续对 <name> 的读写都落在该局部上,语义
    与 HLSL 一致。vert↔frag 接口按 layout(location) 数字匹配,改名不影响。只读的 in(常态)不动,故
    现有通过的着色器零影响。"""
    decls = {m.group(3): m.group(2) for m in _IN_DECL_RE.finditer(body)}
    if not decls:
        return body
    written = [n for n, _ in decls.items()
               if re.search(r'\b' + re.escape(n) + r'\b(?:\.[xyzwrgba]+)?\s*[-+*/]?=(?!=)', body)]
    if not written:
        return body
    def _ren(m):
        return (f"{m.group(1)}{m.group(2)} _we_ro_{m.group(3)}{m.group(4)}"
                if m.group(3) in written else m.group(0))
    body = _IN_DECL_RE.sub(_ren, body)
    copies = "".join(f"\n    {decls[n]} {n} = _we_ro_{n};" for n in written)
    body = re.sub(r'(\bvoid\s+main\s*\(\s*\)\s*\{)', r'\1' + copies, body, count=1)
    return body

def preprocess(path, stage, combos, vary_locs, search_dirs=None, link_src=None, bound_slots=None):
    """link_src:对端 stage(frag→vert / vert→frag)已 include 展开的源,用于链接驱动的 varying 兼容
    (item 4)。调用方(main / build 脚本)已为 collect_varyings 算过两 stage 源,顺带传进来即可。
    bound_slots:本 pass 占用的贴图槽索引集合(material textures 非空项 + effect.json bind 的 index),
    供 sampler combo/require/requireany 联动(item 5)推导应启用的采样 combo。"""
    src = read(path)
    src = inline_includes(src, search_dirs=search_dirs)
    src = resolve_requires(src)                # #require 模块 → 注入函数桩(item 2)
    cdefaults = combo_defaults(src)            # [COMBO] 行声明的 combo 初值(strip 前提取)
    # sampler 联动 combo(item 5):据贴图槽占用 + 现有 combo 推导;在 strip_meta 前用含元数据的源。
    # 现有 combo = [COMBO] 默认 + scene/material(查 require/已提供判定);发现结果优先级最低。
    pre_combos = dict(cdefaults); pre_combos.update(combos)
    sampler_discovered = discover_sampler_combos(src, pre_combos, bound_slots or set())
    src = strip_meta(src)
    src = apply_linked_varying_compat(src, stage, link_src)  # varying vec2↔vec4 双向兼容(item 4)
    src = rename_reserved(src)
    # combo 优先级(低→高):全局兜底 < {shader [COMBO] 默认 ∪ sampler 发现} < scene/material 真实 combo。
    # (ShaderUnit:[COMBO] 默认与 sampler 发现都进 m_discoveredCombos,同级,均不覆盖 m_combos。)
    merged = dict(DEFAULT_COMBOS); merged.update(cdefaults); merged.update(sampler_discovered); merged.update(combos)
    # combo 名统一 toupper(ShaderUnit.cpp:664):WE 编译期对每个 combo `#define` 都先大写名字,
    # 故 shader 里写小写/混合大小写的 combo 名(如 `#if foo`)也能取到值。我们之前用原样 key →
    # 小写/混合 combo 名会取不到、退 0。这里先收敛到大写键(同名大小写不同则后者覆盖,与参考
    # addedCombos 去重一致),再生成 #define。当前 28+29 effect 的 combo 名全大写 → 恒等,零影响。
    upper = {}
    for k, v in merged.items():
        upper[k.upper()] = v
    # 用大写后的活跃 combo 作为预处理求值上下文,剔除死 #if 分支里的 uniform(如 LIGHTS_SHADOW_MAPPING=0
    # 时 fluidsimulation_combine.frag 的 sampler2DComparison g_Texture6)。upper 即 glslang 将见到的全部
    # #define,二者一致 → 被 gate 掉的 uniform 其对应 body 块也被 glslang 剔除,引用一并消失,语义不变。
    body, ubo, samplers = classify_uniforms(src, active_combos=upper)
    body, out_decl = convert_stage(body, stage, vary_locs)
    if stage == "frag":
        body = shadow_written_inputs(body)      # frag 写 `in` varying → 改可写局部拷贝(HLSL 语义)
    body = balance_ifdefs(body)                 # 修补源里 #if/#endif 不配对(body 含全部预处理指令,header 无)
    combo_defs = "\n".join(f"#define {k} {v}" for k, v in upper.items())
    header = f"#version 450\n{PRELUDE}\n{combo_defs}\n{ubo}\n{samplers}\n{out_decl}\n"
    return header + body

def _fix_agx_oscilloscope(msl):
    """AGX Metal 后端崩溃后处理(audio_responsive_oscilloscope 等音频频谱 shader)。

    spirv-cross 把 32 路 audio varying 重建成 `spvUnsafeArray<float4, 32> audioValue`,在循环里
    用循环变量动态索引这个模板结构体的「返回引用的 operator[]」并消费整个 float4
    (`audioValue[i >> 2][i & 3]`)。macOS 的 AGX(Apple GPU)Metal 后端在
    makeRenderPipelineState 时把这种构造 lowering 到机器码会崩(XPC_ERROR_CONNECTION_INTERRUPTED,
    多次重试后失败)——注意:前端 makeLibrary(源码→AIR)和离线 `metal -c` 都成功,只崩后端。

    修复:在循环前把 spvUnsafeArray 拷进一个普通 C 数组 `float4 _av4[N]`,循环里改成动态索引这个
    普通数组。语义完全相同,但普通数组的动态索引能被 AGX 干净 lowering(已用最小复现实测确认:
    spvUnsafeArray 动态索引崩、普通 float4[] 动态索引不崩)。

    实测进一步定位(最小复现二分):真正的崩点是「对 spvUnsafeArray<float4,32> 做**大范围**动态
    下标索引」——`audioValue[i>>2]`(i=0..31 → 索引 0..7,但 spirv-cross 把它当满 32 长度模板)
    以及拷贝循环 `for(_k<32) tmp[_k]=audioValue[_k]` 都会崩;把拷贝改成**静态完全展开**
    (`tmp[0]=audioValue[0]; … tmp[7]=audioValue[7];`,零动态 spvUnsafeArray 索引)最稳,3/3 通过。

    精确匹配:只命中 `spvUnsafeArray<float4, N> NAME` 且别处出现 `NAME[<dynamic>][...]` 的场景。
    其余 shader 不含该模式 → 全库无副作用(no-op)。
    """
    # 找形如:spvUnsafeArray<float4, 32> audioValue = {};
    m = re.search(r'spvUnsafeArray<\s*float4\s*,\s*(\d+)\s*>\s+(\w+)\s*=\s*\{\}\s*;', msl)
    if not m:
        return msl
    count = int(m.group(1)); name = m.group(2)
    # 只有当该名字在某处被「动态(非纯数字)下标」索引时才需要修(静态展开的赋值 audioValue[0]=… 不算)。
    dyn = re.search(re.escape(name) + r'\[\s*[^\]\d][^\]]*\]\s*\[', msl)
    if not dyn:
        return msl
    fixed_name = '_av4_' + name
    # 拷贝槽数 copy_n:动态下标 `NAME[i >> 2]`(i=0..count-1)只能触达 0..count/4-1。**关键**:实测
    # 中「被动态索引的 float4 数组若全 32 槽都初始化」也会崩(不是 spvUnsafeArray 独有);只有当被
    # 动态索引的普通数组**只填到实际可达的少数槽**(此例 8)时 AGX 才能正常 lowering。因此这里只
    # 静态拷贝可达的 copy_n 槽,数组也只声明 copy_n 大,避免大宽度动态索引数组进后端。
    copy_n = (count + 3) // 4
    # 注入点:紧跟最后一个静态展开赋值 `NAME[count-1] = ...;` 之后(此时 spvUnsafeArray 已填满)。
    last_assign = re.search(re.escape(name) + r'\[\s*' + str(count - 1) + r'\s*\]\s*=\s*[^;]+;', msl)
    if not last_assign:
        return msl
    pos = last_assign.end()
    # 步骤 1:先把所有对 NAME 的「动态下标」用法改成 FIXED(静态数字下标=填充赋值,保持指向原数组)。
    #         必须先做,且只作用于已有正文,避免改到下面注入的拷贝里 NAME[k]/FIXED[k]。
    msl = re.sub(re.escape(name) + r'(\[\s*[^\]\d][^\]]*\])', fixed_name + r'\1', msl)
    # 步骤 2:在填充完成处注入**静态完全展开**的普通 C 数组拷贝(零动态索引,注入文本不再被步骤 1 触碰)。
    copies = ''.join(f'\n    {fixed_name}[{k}] = {name}[{k}];' for k in range(copy_n))
    inject = ('\n    // AGX-FIX(_fix_agx_oscilloscope): hoist the dynamically-indexed audio float4s into a\n'
              '    // small plain C array (statically unrolled, only the reachable slots) so the dynamic\n'
              '    // index in the loop lowers cleanly on the macOS AGX Metal backend (see function doc).\n'
              f'    float4 {fixed_name}[{copy_n}];' + copies)
    msl = msl[:pos] + inject + msl[pos:]
    return msl

def transpile(path, stage, combos, vary_locs, verbose=False, link_src=None):
    glsl = preprocess(path, stage, combos, vary_locs, link_src=link_src)
    with tempfile.NamedTemporaryFile("w", suffix=f".{stage}", delete=False) as f:
        f.write(glsl); glsl_path = f.name
    spv = glsl_path + ".spv"
    r = subprocess.run(["glslangValidator", "-V", "-S", stage, glsl_path, "-o", spv],
                       capture_output=True, text=True)
    if r.returncode != 0:
        if verbose: print(glsl)
        raise RuntimeError(f"glslang FAILED ({stage}):\n{r.stdout}\n{r.stderr}")
    r2 = subprocess.run(["spirv-cross", "--msl", "--msl-version", "20000", spv],
                        capture_output=True, text=True)
    if r2.returncode != 0:
        raise RuntimeError(f"spirv-cross FAILED ({stage}):\n{r2.stderr}")
    return _fix_agx_oscilloscope(r2.stdout)

def main():
    path = sys.argv[1]
    combos = {}
    for a in sys.argv[2:]:
        if "=" in a:
            k, v = a.split("=", 1); combos[k] = v   # 审计修复 #6:maxsplit=1,防 `A=B=C` 解包崩
    # 找配对的 vert/frag,建共享 varying location 表。
    base = path.rsplit(".", 1)[0]
    vert_path, frag_path = base + ".vert", base + ".frag"
    # 链接驱动的 varying 兼容需对端 stage 的 include 展开源(item 4):vert 编译时看 frag、反之亦然。
    vraw = inline_includes(read(vert_path)) if os.path.exists(vert_path) else ""
    fraw = inline_includes(read(frag_path)) if os.path.exists(frag_path) else ""
    vary_locs = collect_varyings(strip_meta(vraw), strip_meta(fraw))
    link_for = {"vert": fraw, "frag": vraw}      # 对端源
    for p, stage in [(vert_path, "vert"), (frag_path, "frag")]:
        if not os.path.exists(p): continue
        print(f"\n========== {stage.upper()}  {os.path.basename(p)} ==========")
        try:
            print(transpile(p, stage, combos, vary_locs, verbose=True, link_src=link_for[stage]))
        except RuntimeError as e:
            print("FAIL:", e)

if __name__ == "__main__":   # 审计修复 #6:删除重复的 __main__ 块(原文件末尾 main() 被调两次)
    main()
