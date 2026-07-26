#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
壁纸渲染逐参数审查工具(wallpaper render audit)。

目的:对照 scene.pkg 把每个 scene 对象的**所有关键参数**提取出来,逐项判定我方引擎
      【✅已正确处理 / ⚠️已知未处理(差什么) / ⏭️合法跳过 / ❌疑似错误 / ❓需肉眼验证】,
      让「每张壁纸做到了什么、没做到什么」一目了然。配合引擎的 /tmp/coverage_<id>.log(逐对象渲染状态)。

用法: python3 Tools/wp_audit.py <workshopId>
      python3 Tools/wp_audit.py 3233141951

输出:逐对象参数审查表 + 汇总(成功/已知缺口/跳过/需验证)。known-gaps 来自实测积累(见底部 KNOWN_GAPS)。
"""
import struct, json, sys, os, glob, re

LOWER_TOOLS = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "tools"))
if LOWER_TOOLS not in sys.path:
    sys.path.insert(0, LOWER_TOOLS)
try:
    import we_coverage_scan as effect_coverage
except Exception:
    effect_coverage = None

WORKSHOP_ROOTS = [
    "/Users/a55555/Library/Application Support/CrossOver/Bottles/Steam/drive_c/Program Files (x86)/Steam/steamapps/workshop/content/431960",
    "/Users/a55555/Library/Application Support/Steam/steamapps/workshop/content/431960",
]

def find_pkg(wid):
    for root in WORKSHOP_ROOTS:
        p = os.path.join(root, wid, "scene.pkg")
        if os.path.exists(p):
            return p, os.path.join(root, wid)
    return None, None

def read_pkg(path):
    d = open(path, 'rb').read(); o = 0
    def i():
        nonlocal o; v = struct.unpack_from('<i', d, o)[0]; o += 4; return v
    ml = i(); o += ml; c = i(); E = []
    for _ in range(c):
        nl = i(); nm = d[o:o+nl].decode('utf-8', 'replace'); o += nl; of = i(); sz = i(); E.append((nm, of, sz))
    b = o
    return {n.replace(chr(92), '/'): d[b+of:b+of+sz] for n, of, sz in E}

def jload(F, needle):
    for k in F:
        if k.endswith(needle) and (k.endswith('.json')):
            try: return json.loads(F[k].decode('utf-8', 'replace'))
            except Exception: return None
    return None

def load_effect_context():
    """加载与引擎同源的特效 manifest/别名索引。失败时返回空,审计降级为 ❓ 而非虚假 ✅。"""
    if effect_coverage is None:
        return {}, {}
    try:
        return effect_coverage.load_manifest()
    except Exception:
        return {}, {}

def parallax_components(value):
    """尽力读取 WE 的 vec2 序列化；无法静态解开用户属性/脚本时返回 None。"""
    if isinstance(value, dict):
        if "value" in value:
            return parallax_components(value["value"])
        return None
    if isinstance(value, (list, tuple)) and len(value) >= 2:
        try:
            return float(value[0]), float(value[1])
        except (TypeError, ValueError):
            return None
    if isinstance(value, str):
        try:
            parts = value.replace(",", " ").split()
            if len(parts) >= 2:
                return float(parts[0]), float(parts[1])
        except ValueError:
            pass
    return None

def audit_effect(e, manifest, basename_index):
    """按引擎 manifest + combo 选择逻辑审查单个 effect,不再仅凭文件名判“已实现”."""
    ef = str(e.get("file", "")).replace("\\", "/")
    label = os.path.basename(os.path.dirname(ef)) or ef or "(无路径)"
    if e.get("visible") is False:
        return ("SKIP", f"effect:{label}", "effect.visible=false,WE 同样不执行 → 合法跳过")
    if effect_coverage is None or not manifest:
        return ("VERIFY", f"effect:{label}", "无法读取 WEEffects.json,不能证明 shader/变体已实现")

    key = effect_coverage.we_effect_name(ef)
    if not key:
        return ("ERR", f"effect:{label}", f"无法从路径解析 WE effect key:{ef}")
    basename = key.rsplit("/", 1)[-1]
    if basename in effect_coverage.ENGINE_HANDLED:
        return ("VERIFY", f"effect:{key}", "走引擎特殊路径而非 manifest;需抓帧确认输出与 WE 一致")

    resolved = effect_coverage.resolve_key(key, manifest, basename_index)
    if resolved is None:
        if "/" in key:
            return ("ERR", f"effect:{key}", "T1:manifest 无精确项或 basename 兼容项,引擎必定无法执行该特效")
        return ("VERIFY", f"effect:{key}", "内置短名未在 manifest 命中;需结合运行覆盖日志确认是否走特殊实现")

    combos = {}
    for ps in (e.get("passes") or []):
        if isinstance(ps, dict):
            for k, v in (ps.get("combos") or {}).items():
                combos[k] = str(v)
    gaps = effect_coverage.unsupported_combos(key, combos.items(), manifest, basename_index)
    if gaps:
        return ("GAP", f"effect:{key}",
                "T2:缺少 combo 变体 " + ", ".join(gaps) + f";当前只能回退近似变体({resolved})")
    return ("VERIFY", f"effect:{key}",
            f"manifest/所请求 combo 已覆盖({resolved});静态链路可执行,画面/参数忠实度仍需抓帧")

def audit_scripts(ob):
    """递归审查对象脚本。已知桩明确报 ⚠️,其余脚本一律 ❓,不把“能 eval”冒充“语义正确”."""
    scripts = []
    def walk(v, path=()):
        if isinstance(v, dict):
            for k, child in v.items():
                if k == "script" and isinstance(child, str) and child.strip():
                    scripts.append((path + (k,), child))
                else:
                    walk(child, path + (k,))
        elif isinstance(v, list):
            for index, child in enumerate(v):
                walk(child, path + (index,))
    walk(ob)
    if not scripts:
        return []

    combined = "\n".join(source for _, source in scripts)
    known_stubs = [
        (("video.", "getVideoTexture("), "视频 play/pause/rate/currentTime 仍是 no-op 桩,脚本剪辑/播放控制未生效"),
        (("getMaterial(",), "跨层 getMaterial 当前返回 null,材质读写脚本未实现"),
    ]
    rows = []
    for tokens, note in known_stubs:
        if any(token in combined for token in tokens):
            rows.append(("GAP", "script API", note))

    # alpha/origin/angles/scale/color 自身字段的关键帧已连接真实时间轴控制器。其余 getAnimation
    # （具名/跨层、effect 常量、animationlayers、scale 等）仍返回占位，必须继续报缺口。
    supported_animation_fields = {"alpha", "origin", "angles", "scale", "color"}
    supported_animation_scripts = 0
    unsupported_animation_scripts = 0
    for path, source in scripts:
        if "getAnimationCount(" in source:
            unsupported_animation_scripts += 1
            continue
        if "getAnimation(" not in source:
            continue
        root_field = path[0] if path and isinstance(path[0], str) else None
        field_value = ob.get(root_field) if root_field else None
        named_query = re.search(r"getAnimation\s*\(\s*[^)\s]", source) is not None
        if (root_field in supported_animation_fields and isinstance(field_value, dict)
                and isinstance(field_value.get("animation"), dict) and not named_query):
            supported_animation_scripts += 1
        else:
            unsupported_animation_scripts += 1
    if unsupported_animation_scripts:
        rows.append((
            "GAP", "script API",
            "具名/跨层或非 alpha/origin/angles/scale/color 字段的动画查询仍返回占位；"
            "getAnimationCount、结束回调及 animationlayers 控制尚未连接真实状态机"
        ))
    if supported_animation_scripts:
        rows.append((
            "VERIFY", "script animation",
            f"{supported_animation_scripts} 段同字段关键帧脚本已连接 rate/play/pause/stop/setFrame/getFrame；"
            "运行语义已测试，最终相位/画面仍需真 WE 抓帧"
        ))

    thumbnail_scripts = [(path, source) for path, source in scripts if "mediaThumbnailChanged" in source]
    if thumbnail_scripts:
        supported_media_fields = {"visible", "alpha", "origin", "angles", "scale", "color", "text"}
        supported = sum(
            1 for path, _ in thumbnail_scripts
            if path and isinstance(path[0], str) and path[0] in supported_media_fields
        )
        unsupported = len(thumbnail_scripts) - supported
        if unsupported:
            rows.append((
                "GAP", "script media thumbnail",
                f"{unsupported} 段 effect/animationlayers/其它未接管字段的封面回调没有运行时宿主"
            ))
        if supported:
            rows.append((
                "VERIFY", "script media thumbnail",
                f"{supported} 段属性回调已按真实封面 revision 派发 hasThumbnail + 5 个 Vec3 调色板字段；"
                "颜色聚类算法未公开，需与真 WE 封面配色抓帧校准"
            ))
    if not rows:
        rows.append(("VERIFY", "script", f"发现 {len(scripts)} 段脚本;JavaScriptCore 可执行不等于 WE API/事件语义完整,需运行时 API 覆盖+抓帧"))
    return rows

# ---- 已知引擎缺口/约定(实测积累;审查时据此给参数打标) ----
def audit_object(ob, F, manifest=None, basename_index=None):
    """返回 (类型, [审查行...])。每行 = (级别, 参数, 说明)。级别: OK/GAP/SKIP/ERR/VERIFY"""
    rows = []
    name = ob.get('name', '?')
    has_img = 'image' in ob
    has_par = 'particle' in ob
    img = ob.get('image', '')
    typ = 'particle' if has_par else ('image' if has_img else 'other')
    serialized = json.dumps(ob, ensure_ascii=False)
    if "$mediaThumbnail" in serialized or "$mediaPreviousThumbnail" in serialized:
        rows.append((
            "GAP", "album-cover texture",
            "$mediaThumbnail/$mediaPreviousThumbnail 动态 usertexture 尚未绑定到 MediaRemote 封面纹理"
        ))

    # visible / 条件可见性
    vis = ob.get('visible')
    instanced = bool(ob.get("instanced")) or bool(ob.get("isInstance"))
    if vis is False:
        rows.append(('SKIP', 'visible=false', '设计隐藏,lwe/WE 同样不渲 → 合法跳过'))
    elif instanced:
        rows.append(('SKIP', 'instanced', '实例化占位模板本体不渲染 → 合法跳过'))
    elif isinstance(vis, dict):
        if isinstance(vis.get("script"), str):
            rows.append(('VERIFY', 'visible(script)', '已接 JavaScriptCore 求值,但依赖的 WE API/事件是否完整需结合 script API 审计'))
        else:
            rows.append(('OK', 'visible(用户条件)', f'用户属性条件 {json.dumps(vis,ensure_ascii=False)} → VecParse/effectiveVisible 已实现'))

    # 变换
    for key, note in [('origin','位置'),('size','尺寸'),('scale','缩放'),('angles','旋转Z')]:
        if key in ob and ob[key] not in (None,''):
            rows.append(('OK', key, f'{note} → matModel 已应用'))
    if ob.get('parallaxDepth') not in (None,''):
        depth = parallax_components(ob.get('parallaxDepth'))
        if depth is not None and depth[0] == 0 and depth[1] == 0:
            rows.append(('OK', 'parallaxDepth',
                         '0 0 → 按 WE 语义完全关闭该控制组视差(图层/粒子均不再强制最小深度)'))
        else:
            rows.append((
                'VERIFY', 'parallaxDepth',
                f'={ob.get("parallaxDepth")} —— 已实现父级传播/disablepropagation、控制节点锚点、'
                'amount+mouseInfluence、delay=dt/duration；运动方向与幅度仍需真 WE 抓帧校准'
            ))

    # cropoffset:已实现 POT 主贴图重定位,但是否命中取决于真实 .tex 容器/内容尺寸,静态对象字段不足以判定。
    co = ob.get('cropoffset')
    if co not in (None, '', '0 0 0', '0.00000 0.00000 0.00000'):
        rows.append(('VERIFY','cropoffset',f'={co} —— 引擎在主贴图容器为 POT 时应用世界位移,非POT跳过;需核对纹理头和部件对位'))

    # composelayer / _rt_FullFrameBuffer
    if vis is not False and not instanced and 'composelayer' in str(img).lower():
        effs = ob.get('effects', [])
        has_pulse = any('pulse' in str(e.get('file','')).lower() for e in effs)
        is_audio = any(('audio' in str(e.get('file','')).lower() and ('bar' in str(e.get('file','')).lower() or 'spectrum' in str(e.get('file','')).lower())) for e in effs)
        if is_audio:
            rows.append(('OK','composelayer(音频条)','走 parseAudioBars → 真 WE shader 渲染(需系统音频驱动才动)'))
        elif has_pulse:
            rows.append(('OK','composelayer(pulse/打雷)','frameBufferInput → 按 pkg 区域 + 画布UV 采样(已修)'))
        elif not effs:
            rows.append(('OK','composelayer(无特效容器)','透明变换容器(如时钟父层)→ 容器本身不画(faithful);子层经 resolveTransform 拿到父变换(已实现父链),位置对'))
        else:
            rows.append(('OK','composelayer(_rt_FullFrameBuffer)',f'effects={[e.get("file","") for e in effs]} —— per-Image FBO 合成已实现(footprint copy 采场景进层 [0,1] FBO + 特效链 + 末 pass blend,= lwe composelayer)'))

    # 特效逐个:按真实 manifest + combo 覆盖判断 T1/T2,有 shader 也只判 ❓,不冒充视觉正确。
    if manifest is None or basename_index is None:
        manifest, basename_index = load_effect_context()
    for e in (ob.get('effects', []) if vis is not False and not instanced else []):
        ef = str(e.get('file',''))
        efl = ef.lower()
        csv = (e.get('passes') or [{}])[0].get('constantshadervalues', {}) if e.get('passes') else {}
        is_audio_name = ('audio' in efl and ('bar' in efl or 'spectrum' in efl))
        is_audio_content = any(('栏的条数' in k or '栏的间距' in k or 'bar count' in k.lower() or 'spectrum' in k.lower()) for k in csv.keys())
        if is_audio_content and not is_audio_name:
            rows.append(('VERIFY','effect(音频条·改名/汉化)',f'{ef} —— 可按频谱 uniform 识别;仍需系统音频+抓帧验证形状/透明度'))
        elif 'cursorripple' in efl:
            rows.append(('VERIFY','effect:cursorripple','走 CursorRippleSim;交互力场、遮罩和折射幅度需抓帧/鼠标验证'))
        rows.append(audit_effect(e, manifest, basename_index))

    # puppet + animationlayers
    if has_img:
        mdl = jload(F, img.split('/')[-1]) if img else None
        if mdl and mdl.get('puppet'):
            puppet_path = str(mdl.get("puppet")).replace("\\", "/")
            rows.append(('OK','puppet(网格)',f'{puppet_path} → 非矩形 bind 网格直渲(已实现)'))
            puppet_blob = F.get(puppet_path)
            if puppet_blob and b"masks/clipping_mask_" in puppet_blob:
                rows.append((
                    'OK', 'puppet(clipping)',
                    'MDLV 子网格 target/source 裁剪关系已解析；source 随本帧骨骼蒙皮生成动态屏幕遮罩，'
                    '虹膜/高光 target 在眨眼闭合时同步裁掉'
                ))
            if ob.get('animationlayers'):
                al = ob['animationlayers'][0]
                rows.append(('VERIFY','animationlayers(骨骼动画)',f'animation={al.get("animation")} → MDLS/MDLA 蒙皮已实现(MDLS0004/MDLA0006);⚠️ 精度/对位需肉眼验证(离体UV岛如眼睛需精确落到位)'))

    # 粒子
    if has_par:
        rows.append(('VERIFY','particle',f'{ob["particle"]} → 发射/对象级 override、remapvalue+fbm、多个 oscillateposition 均已接入;随机分布/算子组合仍需实时累积抓帧'))

    # 声音
    if 'sound' in ob or (not has_img and not has_par and ob.get('sound')):
        rows.append(('GAP','sound','播放走 AudioPlayback,但默认静音(PreferencesStore.isMuted=true)→ 不出声 + 音频条无源'))

    rows.extend(audit_scripts(ob))
    return typ, rows

KNOWN_GAPS = """
已知引擎缺口清单(审查时对照;实测积累。⚠️=真缺口 / ✅=已修(2026-06) / ⏭️=lwe同样不做):
  ✅ composelayer 区域性(_rt_FullFrameBuffer 非 pulse/非音频条):**已实现 per-Image FBO 合成**(footprint copy 采场景进层 [0,1] FBO=lwe composelayer 首 copy pass,CImage.cpp:785-853;FBO 用未缩放 raw size CImage.cpp:239)。
  ✅ 音频条 effect 改名/汉化:走 per-Image FBO + usesAudioSpectrum(扫 frag/vert.uniforms)检测,不再靠文件名。
  ✅ 音频条 composelayer FBO 比例:用未缩放 size(非 size×scale),修各向异性 scale 把条压扁(下音条)。
  ⚠️ 图层遮挡:头发等不透明层按渲染序盖在脸上(faithful),眼睛靠贴图 alpha 缝隙+puppet warp 精确对位才露出。
  ⚠️ 音频条:渲染对,但靠 ScreenCaptureKit 系统音频驱动;采集守护进程坏(callback 不触发)→ 重启 Mac;壁纸自带音乐默认静音(isMuted,lwe 默认播——未改)。
  ✅ 特效关键帧常量:**已逐 pass 应用**到普通图层/composelayer/fullscreen 后处理,vec2 不再丢;front/back 三次贝塞尔已实现。❓ 手柄单位/最终画面仍需真 WE 抓帧校准。
  ✅ 属性关键帧脚本:alpha/origin/angles/scale/color 的同字段 getAnimation 已连接 rate/play/pause/stop/setFrame/getFrame；⚠️ 具名/跨层动画、animationlayers 控制、结束回调/getAnimationCount 仍缺。
  ❓ mediaThumbnailChanged:直接属性脚本已按真实 MediaRemote artwork revision 派发 hasThumbnail + 五个 Vec3 颜色；调色板聚类需真 WE 校准。⚠️ effect/animationlayers 回调宿主及 $mediaThumbnail 动态纹理绑定仍缺。
  ✅ cropoffset:**已实现**——按主贴图 .tex 容器是否 POT 判定,POT→origin+cropoffset(经父链scale/angle)应用,非POT→跳过(2026-06,WP_NO_CROPOFFSET 可关)。
  ✅ remapvalue+fbmnoise:**已实现** velocity+simplex **和** speed+fbm(ParticleSystem remapSourceSpeed/remapFbm/fbm(),带 WE 语义假设标注 octaves4/lacunarity2/gain0.5;lwe 无 remapvalue,按真 WE 移植)。
  ✅ 多个 oscillateposition(雪的双摆):已用数组逐个保留并叠加。
  ✅ 3D 透视相机 eye/center/up/near/far/fov:已进入 perspective view/projection;❓ 需逐壁纸取景对照。
  ✅ 鼠标视差公式:**已按 WE 控制节点模型重写**——父级默认传播、disablepropagation 截断、锚点-相机静态项、
     X/Y 分别按场景宽高、delay=dt/duration 且 0=立即、depth=0 真关闭(含粒子)；g_PointerPosition 保持
     原始交互光标，g_ParallaxPosition 单独使用 delay+mouseInfluence 且不乘 amount。❓ 最终幅度/方向仍需真 WE 抓帧。
  ✅ 无 image 动态父容器:origin 关键帧和 script-only 容器均逐帧下放到图片/文字后代，并同步动态视差锚点；
     同一容器每帧只执行一次脚本(按 id 缓存)，不再把拖拽/弹跳/sin 位移冻结在加载帧。
  ✅ puppet inter-puppet attachment:**已实现**(数据在父 .mdl 的 MDAT0001 具名挂点;quad+puppet 统一锚点 attachPos+子origin;眼/睑/耳跟随父骨动画含旋转放大;眨眼)。2026-06-07,凯尔希。lwe 不做。
  ⏭️ VolumeLight/light/shape、camerashake:跳过(lwe 同样未实现,非我方独缺)。
  ⏭️ visible=false / instanced 占位 / projectlayer 容器:合法跳过(faithful)。
"""

def main():
    if len(sys.argv) < 2:
        print("用法: python3 Tools/wp_audit.py <workshopId>"); return
    wid = sys.argv[1]
    pkg, folder = find_pkg(wid)
    if not pkg:
        print(f"找不到 {wid} 的 scene.pkg"); return
    F = read_pkg(pkg)
    sc = None
    for k in F:
        if k.endswith('scene.json'):
            sc = json.loads(F[k].decode('utf-8','replace')); break
    if not sc:
        print("无 scene.json"); return
    objs = sc.get('objects', [])
    manifest, basename_index = load_effect_context()
    # 读引擎覆盖日志(若有)
    cov = {}
    covpath = f"/tmp/coverage_{wid}.log"
    if os.path.exists(covpath):
        for ln in open(covpath, encoding='utf-8'):
            if 'id=' in ln and ('已渲染' in ln or '未渲染' in ln):
                try:
                    oid = ln.split('id=')[1].split(' ')[0]
                    cov[oid] = '已渲染' if '已渲染' in ln else '未渲染'
                except Exception: pass

    print(f"===== 渲染逐参数审查 wallpaper={wid} 共{len(objs)}对象 =====")
    if cov: print(f"(已读引擎覆盖日志 {covpath}:{sum(1 for v in cov.values() if v=='已渲染')}已渲染/{sum(1 for v in cov.values() if v=='未渲染')}未渲染)")
    tally = {'OK':0,'GAP':0,'SKIP':0,'ERR':0,'VERIFY':0}
    sym = {'OK':'✅','GAP':'⚠️','SKIP':'⏭️','ERR':'❌','VERIFY':'❓'}
    for ob in objs:
        oid = str(ob.get('id','?')); nm = ob.get('name','(空)')
        typ, rows = audit_object(ob, F, manifest, basename_index)
        cstat = cov.get(oid, '?')
        if not rows: continue
        print(f"\n[{typ}] id={oid} {nm!r}  引擎覆盖={cstat}")
        for lvl, param, note in rows:
            tally[lvl] += 1
            print(f"   {sym[lvl]} {param}: {note}")
    print(f"\n===== 汇总: ✅{tally['OK']} ⚠️已知缺口{tally['GAP']} ⏭️合法跳过{tally['SKIP']} ❌错误{tally['ERR']} ❓需验证{tally['VERIFY']} =====")
    print(KNOWN_GAPS)

if __name__ == '__main__':
    main()
