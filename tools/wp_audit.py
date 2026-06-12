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
import struct, json, sys, os, glob

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

# ---- 已知引擎缺口/约定(实测积累;审查时据此给参数打标) ----
def audit_object(ob, F):
    """返回 (类型, [审查行...])。每行 = (级别, 参数, 说明)。级别: OK/GAP/SKIP/ERR/VERIFY"""
    rows = []
    name = ob.get('name', '?')
    has_img = 'image' in ob
    has_par = 'particle' in ob
    img = ob.get('image', '')
    typ = 'particle' if has_par else ('image' if has_img else 'other')

    # visible / 条件可见性
    vis = ob.get('visible')
    if vis is False:
        rows.append(('SKIP', 'visible=false', '设计隐藏,lwe/WE 同样不渲 → 合法跳过'))
    elif isinstance(vis, dict):
        rows.append(('OK', 'visible(条件)', f'用户属性条件 {json.dumps(vis,ensure_ascii=False)} → 引擎走 effectiveVisible(已实现)'))

    # 变换
    for key, note in [('origin','位置'),('size','尺寸'),('scale','缩放'),('angles','旋转Z')]:
        if key in ob and ob[key] not in (None,''):
            rows.append(('OK', key, f'{note} → matModel 已应用'))
    if ob.get('parallaxDepth') not in (None,''):
        rows.append(('OK','parallaxDepth','视差 → 已实现(鼠标驱动+delay)'))

    # cropoffset(⚠️ 解析了但未应用)
    co = ob.get('cropoffset')
    if co not in (None, '', '0 0 0', '0.00000 0.00000 0.00000'):
        rows.append(('GAP','cropoffset',f'={co} —— ⚠️ 解析存下但**未应用**(SceneModel TODO);贴图裁剪重定位语义未解,会导致该层位置偏(如挡住眼/部件散)'))

    # composelayer / _rt_FullFrameBuffer
    if 'composelayer' in str(img).lower():
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

    # 特效逐个
    for e in ob.get('effects', []):
        ef = str(e.get('file',''))
        efl = ef.lower()
        csv = (e.get('passes') or [{}])[0].get('constantshadervalues', {}) if e.get('passes') else {}
        is_audio_name = ('audio' in efl and ('bar' in efl or 'spectrum' in efl))
        is_audio_content = any(('栏的条数' in k or '栏的间距' in k or 'bar count' in k.lower() or 'spectrum' in k.lower()) for k in csv.keys())
        if is_audio_content and not is_audio_name:
            rows.append(('OK','effect(音频条·改名/汉化)',f'{ef} —— 文件名不含 audio/bar,但走 per-Image FBO composelayer + usesAudioSpectrum(扫 frag/vert.uniforms 的 g_AudioSpectrum)检测,真 shader 渲染(不再靠文件名 parseAudioBars)'))
        elif 'cursorripple' in efl:
            rows.append(('OK','effect:cursorripple','走 CursorRippleSim(鼠标水波)'))
        else:
            rows.append(('VERIFY','effect',f'{os.path.basename(os.path.dirname(ef)) or ef} → 若已转译进 WEEffects.json 则走真 shader,否则跳过(查 WEEffects.json)'))

    # puppet + animationlayers
    if has_img:
        mdl = jload(F, img.split('/')[-1]) if img else None
        if mdl and mdl.get('puppet'):
            rows.append(('OK','puppet(网格)',f'{mdl.get("puppet")} → 非矩形 bind 网格直渲(已实现)'))
            if ob.get('animationlayers'):
                al = ob['animationlayers'][0]
                rows.append(('VERIFY','animationlayers(骨骼动画)',f'animation={al.get("animation")} → MDLS/MDLA 蒙皮已实现(MDLS0004/MDLA0006);⚠️ 精度/对位需肉眼验证(离体UV岛如眼睛需精确落到位)'))

    # 粒子
    if has_par:
        rows.append(('VERIFY','particle',f'{ob["particle"]} → 粒子系统(发射/初始化/算子真移植 lwe);⚠️ instanceoverride(count/size/speed/rate/lifetime 对象级已修)、remapvalue+fbm(Gouttes 部分)、双oscillate(只留最后一个)等逐项见 KNOWN_GAPS'))

    # 声音
    if 'sound' in ob or (not has_img and not has_par and ob.get('sound')):
        rows.append(('GAP','sound','播放走 AudioPlayback,但默认静音(PreferencesStore.isMuted=true)→ 不出声 + 音频条无源'))

    return typ, rows

KNOWN_GAPS = """
已知引擎缺口清单(审查时对照;实测积累。⚠️=真缺口 / ✅=已修(2026-06) / ⏭️=lwe同样不做):
  ✅ composelayer 区域性(_rt_FullFrameBuffer 非 pulse/非音频条):**已实现 per-Image FBO 合成**(footprint copy 采场景进层 [0,1] FBO=lwe composelayer 首 copy pass,CImage.cpp:785-853;FBO 用未缩放 raw size CImage.cpp:239)。
  ✅ 音频条 effect 改名/汉化:走 per-Image FBO + usesAudioSpectrum(扫 frag/vert.uniforms)检测,不再靠文件名。
  ✅ 音频条 composelayer FBO 比例:用未缩放 size(非 size×scale),修各向异性 scale 把条压扁(下音条)。
  ⚠️ 图层遮挡:头发等不透明层按渲染序盖在脸上(faithful),眼睛靠贴图 alpha 缝隙+puppet warp 精确对位才露出。
  ⚠️ 音频条:渲染对,但靠 ScreenCaptureKit 系统音频驱动;采集守护进程坏(callback 不触发)→ 重启 Mac;壁纸自带音乐默认静音(isMuted,lwe 默认播——未改)。
  ⚠️ 关键帧动画贝塞尔手柄:WEKeyframeAnimation 线性插值,缺 front/back 切线手柄(头发/发饰摇摆缓动机械)。lwe 不实现关键帧,需照 WE 数据补。
  ✅ cropoffset:**已实现**——按主贴图 .tex 容器是否 POT 判定,POT→origin+cropoffset(经父链scale/angle)应用,非POT→跳过(2026-06,WP_NO_CROPOFFSET 可关)。
  ✅ remapvalue+fbmnoise:**已实现** velocity+simplex **和** speed+fbm(ParticleSystem remapSourceSpeed/remapFbm/fbm(),带 WE 语义假设标注 octaves4/lacunarity2/gain0.5;lwe 无 remapvalue,按真 WE 移植)。
  ⚠️ 多个 oscillateposition(雪的双摆):单字段只留最后一个。
  ⚠️ 3D 透视相机 eye≠0:未应用(lwe Camera.cpp:50 有透视 eye;正交等价已对,透视待补)。
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
        typ, rows = audit_object(ob, F)
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
