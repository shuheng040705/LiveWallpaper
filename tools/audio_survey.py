#!/usr/bin/env python3
# 普查整个壁纸库:哪些壁纸含音频反应式对象。
# 运行: cd /Users/a55555/Developer/LiveWallpaper; python3 Tools/audio_survey.py
import struct, os, json, sys

ROOT = "/Users/a55555/Library/Application Support/CrossOver/Bottles/Steam/drive_c/Program Files (x86)/Steam/steamapps/workshop/content/431960"

# texfmt.rd 的逐字拷贝(避免 import 触发 texfmt 顶层副作用)
def rd(path):
    d=open(path,'rb').read();o=0
    def i():
        nonlocal o;v=struct.unpack_from('<i',d,o)[0];o+=4;return v
    ml=i();o+=ml;c=i();E=[]
    for _ in range(c):
        nl=i();nm=d[o:o+nl].decode('utf-8','replace');o+=nl;of=i();sz=i();E.append((nm,of,sz))
    b=o;return {n.replace(chr(92),'/'):d[b+of:b+of+sz] for n,of,sz in E}

AUDIO_FILE_TOKENS = ('2846660316', 'audio', 'visualiz', 'spectrum')
BARCOUNT_TOKENS   = ('栏的条数', 'Bar Count', 'BarCount', 'u_BarCount')

def is_truthy_visible(v):
    # WE visible 可能是 bool / "true" / 数字 / 带 user/value 的 dict。
    # 注意:形如 {"user":"newproperty10","value":false} 时,'value' 才是默认状态,
    # 'user' 是绑定的用户属性名(字符串),绝不能当布尔用。
    if isinstance(v, bool): return v
    if isinstance(v, (int, float)): return bool(v)
    if isinstance(v, str): return v.strip().lower() not in ('false', '0', '')
    if isinstance(v, dict):
        if 'value' in v: return is_truthy_visible(v['value'])
        return True
    return True  # 默认存在即可见(WE 缺省 visible=true)

def visible_field(obj):
    # 返回 obj 是否默认可见(用于"是否全部默认隐藏")
    if 'visible' not in obj:
        return True  # 字段缺省 => 默认可见
    return is_truthy_visible(obj['visible'])

def passes_of_object(obj):
    """遍历对象所有 effect 的所有 pass,yield (effect_dict, pass_dict)。"""
    for eff in (obj.get('effects') or []):
        if not isinstance(eff, dict):
            continue
        for ps in (eff.get('passes') or []):
            if isinstance(ps, dict):
                yield eff, ps

def shape_value(combos):
    if not isinstance(combos, dict):
        return None
    for k, v in combos.items():
        if isinstance(k, str) and k.upper() == 'SHAPE':
            return v
    return None

def classify_object(obj):
    """判定对象是否为音频对象。返回 (is_audio, shape_values_set, hit_reasons)。"""
    if not isinstance(obj, dict):
        return False, set(), set()
    is_audio = False
    shapes = set()
    reasons = set()

    # 条件1: 某 effect 的 file 含 audio token
    for eff in (obj.get('effects') or []):
        if not isinstance(eff, dict):
            continue
        fpath = eff.get('file')
        if isinstance(fpath, str):
            low = fpath.lower()
            for tok in AUDIO_FILE_TOKENS:
                if tok.lower() in low:
                    is_audio = True
                    reasons.add('effect.file~%s' % tok)

    # 条件2/3: pass 级 combos 有 SHAPE / constantshadervalues 含 BarCount token
    for eff, ps in passes_of_object(obj):
        combos = ps.get('combos')
        sv = shape_value(combos)
        if sv is not None:
            is_audio = True
            reasons.add('combos.SHAPE')
            shapes.add(sv)
        csv = ps.get('constantshadervalues')
        if isinstance(csv, dict):
            for ck in csv.keys():
                if not isinstance(ck, str):
                    continue
                for tok in BARCOUNT_TOKENS:
                    if tok.lower() in ck.lower():
                        is_audio = True
                        reasons.add('csv.%s' % tok)

    return is_audio, shapes, reasons

def uses_composelayer(obj):
    img = obj.get('image')
    return isinstance(img, str) and img.replace('\\','/') == 'models/util/composelayer.json'

def load_title(wid):
    pj = os.path.join(ROOT, wid, 'project.json')
    try:
        with open(pj, 'r', encoding='utf-8', errors='replace') as fh:
            data = json.load(fh)
        t = data.get('title')
        if isinstance(t, str) and t.strip():
            return t
    except Exception:
        pass
    return None

def get_objects(scene):
    objs = scene.get('objects')
    if isinstance(objs, list):
        return objs
    if isinstance(objs, dict):
        return list(objs.values())
    return []

def main():
    if not os.path.isdir(ROOT):
        print("ROOT not found:", ROOT, file=sys.stderr)
        sys.exit(1)

    all_ids = sorted(d for d in os.listdir(ROOT) if os.path.isdir(os.path.join(ROOT, d)))
    total_folders = len(all_ids)

    pkg_ok = 0
    no_scene = 0
    read_fail = 0
    audio_wallpapers = []

    # 规律统计
    shape_dist = {}            # shape value -> count of audio objects using it
    n_audio_objs_total = 0
    n_compose_objs = 0
    n_all_hidden_wp = 0

    for wid in all_ids:
        pkg = os.path.join(ROOT, wid, 'scene.pkg')
        if not os.path.isfile(pkg):
            no_scene += 1
            continue
        try:
            files = rd(pkg)
        except Exception:
            read_fail += 1
            continue
        sj = files.get('scene.json')
        if sj is None:
            no_scene += 1
            continue
        try:
            scene = json.loads(sj.decode('utf-8', 'replace'))
        except Exception:
            read_fail += 1
            continue
        pkg_ok += 1

        objects = get_objects(scene)
        audio_objs = []
        wp_shapes = set()
        for obj in objects:
            is_audio, shapes, reasons = classify_object(obj)
            if is_audio:
                audio_objs.append((obj, shapes, reasons))
                wp_shapes |= shapes

        if not audio_objs:
            continue

        # 该壁纸是含音频对象的
        compose_flags = [uses_composelayer(o) for (o, s, r) in audio_objs]
        visible_flags = [visible_field(o) for (o, s, r) in audio_objs]
        all_hidden = all(not v for v in visible_flags)
        all_compose = all(compose_flags) and len(compose_flags) > 0

        for sv in wp_shapes:
            shape_dist[sv] = shape_dist.get(sv, 0) + 1
        n_audio_objs_total += len(audio_objs)
        n_compose_objs += sum(1 for c in compose_flags if c)
        if all_hidden:
            n_all_hidden_wp += 1

        title = load_title(wid)
        audio_wallpapers.append({
            'id': wid,
            'name': title or wid,
            'audioObjectCount': len(audio_objs),
            'shapes': sorted([str(s) for s in wp_shapes]),
            'usesComposelayer': all_compose,
            'composeCount': sum(1 for c in compose_flags if c),
            'allDefaultHidden': all_hidden,
            'visibleFlags': visible_flags,
            'objNames': [str(o.get('name','?')) for (o, s, r) in audio_objs],
        })

    # 输出报告
    audio_wallpapers.sort(key=lambda w: (-w['audioObjectCount'], w['id']))

    print("="*70)
    print("音频对象普查报告")
    print("="*70)
    print("扫描文件夹总数      :", total_folders)
    print("成功读到 scene pkg  :", pkg_ok)
    print("无 scene.json(跳过):", no_scene)
    print("读取/解析失败(计数):", read_fail)
    print("含音频对象的壁纸数  :", len(audio_wallpapers))
    print()
    print("-"*70)
    print("含音频对象的壁纸完整列表")
    print("-"*70)
    for w in audio_wallpapers:
        print("id=%s  名=%s" % (w['id'], w['name']))
        print("    音频对象数=%d  SHAPE=%s  全compose=%s(compose对象%d个)  全默认隐藏=%s" % (
            w['audioObjectCount'], w['shapes'], w['usesComposelayer'], w['composeCount'], w['allDefaultHidden']))
        print("    对象名: %s" % w['objNames'])
    print()
    print("-"*70)
    print("规律总结")
    print("-"*70)
    print("音频对象总计           :", n_audio_objs_total)
    print("其中 composelayer 对象 :", n_compose_objs,
          "(%.0f%%)" % (100.0*n_compose_objs/n_audio_objs_total if n_audio_objs_total else 0))
    print("全部默认隐藏的壁纸     :", n_all_hidden_wp, "/", len(audio_wallpapers))
    print("SHAPE 分布(值: 用到的壁纸数):")
    for sv in sorted(shape_dist, key=lambda x: str(x)):
        print("    SHAPE=%s -> %d 张壁纸" % (sv, shape_dist[sv]))

    # 返回结构供调用方使用
    return {
        'totalFolders': total_folders,
        'pkgScanned': pkg_ok,
        'noScene': no_scene,
        'readFail': read_fail,
        'audioWallpapers': audio_wallpapers,
        'shapeDist': shape_dist,
        'nAudioObjsTotal': n_audio_objs_total,
        'nComposeObjs': n_compose_objs,
        'nAllHiddenWp': n_all_hidden_wp,
    }

if __name__ == '__main__':
    result = main()
    # 同时落地 JSON 便于程序读取
    out = '/Users/a55555/Developer/LiveWallpaper/Tools/audio_survey_result.json'
    with open(out, 'w', encoding='utf-8') as fh:
        json.dump(result, fh, ensure_ascii=False, indent=2)
    print("\nJSON ->", out)
