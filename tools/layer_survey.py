#!/usr/bin/env python3
# 普查全库:多图层/多部件/深层级位置敏感壁纸
import sys, os, json, struct
sys.path.insert(0, 'Tools')
from texfmt import rd

ROOT = "/Users/a55555/Library/Application Support/CrossOver/Bottles/Steam/drive_c/Program Files (x86)/Steam/steamapps/workshop/content/431960"

PART_WORDS_CN = ['头', '发', '眼', '手', '身', '衣', '脸', '嘴', '腿', '脚', '臂',
                 '耳', '尾', '翼', '翅', '裙', '帽', '角', '胸', '腰', '肩', '颈',
                 '睫', '眉', '齿', '舌', '指', '掌', '膝', '肘', '腹', '背', '皮肤']
PART_WORDS_EN = ['hair', 'eye', 'body', 'arm', 'hand', 'head', 'face', 'leg',
                 'foot', 'feet', 'mouth', 'ear', 'tail', 'wing', 'skirt', 'hat',
                 'horn', 'chest', 'waist', 'shoulder', 'neck', 'lash', 'brow',
                 'tooth', 'teeth', 'cloth', 'dress', 'finger', 'skin', 'cheek',
                 'nose', 'lip', 'bang', 'pupil', 'iris', 'blink', 'mob', 'fringe']

def is_part_name(nm):
    if not nm:
        return False
    low = nm.lower()
    for w in PART_WORDS_EN:
        if w in low:
            return True
    for w in PART_WORDS_CN:
        if w in nm:
            return True
    return False

def nonzero_vec(v):
    # v 形如 "x y z" 或列表;判断是否任一非零
    if v is None:
        return False
    if isinstance(v, str):
        parts = v.replace(',', ' ').split()
    elif isinstance(v, (list, tuple)):
        parts = v
    else:
        return False
    try:
        return any(abs(float(p)) > 1e-9 for p in parts)
    except Exception:
        return False

def non_identity_scale(v):
    if v is None:
        return False
    if isinstance(v, str):
        parts = v.replace(',', ' ').split()
    elif isinstance(v, (list, tuple)):
        parts = v
    else:
        return False
    try:
        return any(abs(float(p) - 1.0) > 1e-6 for p in parts)
    except Exception:
        return False

def max_parent_depth(objs):
    # 用 obj['parent'] 建图。parent 可能是 id 数字或字符串。
    by_id = {}
    for o in objs:
        oid = o.get('id')
        if oid is not None:
            by_id[str(oid)] = o
    depth_cache = {}
    def depth(oid, seen):
        if oid in depth_cache:
            return depth_cache[oid]
        o = by_id.get(oid)
        if o is None:
            return 0
        par = o.get('parent')
        if par is None or str(par) == '' or str(par) == str(oid):
            depth_cache[oid] = 1
            return 1
        spar = str(par)
        if spar in seen:  # cycle guard
            depth_cache[oid] = 1
            return 1
        if spar not in by_id:
            depth_cache[oid] = 1
            return 1
        d = 1 + depth(spar, seen | {oid})
        depth_cache[oid] = d
        return d
    md = 0
    for oid in by_id:
        md = max(md, depth(oid, set()))
    return md

def _load_json(f, path):
    if not path:
        return None
    key = str(path).replace('\\', '/')
    blob = f.get(key)
    if blob is None:
        base = os.path.basename(key)
        for k in f:
            if k.endswith(base) and k.endswith('.json'):
                blob = f[k]
                break
    if blob is None:
        return None
    try:
        return json.loads(blob)
    except Exception:
        return None

def find_model_info(f, image_path):
    # 在这个库格式里, object['image'] 直接指向 models/*.json (模型文件)。
    # 也兼容旧格式: image json -> .model -> model json。
    # 返回 (cropoffset, has_puppet)。
    j = _load_json(f, image_path)
    if j is None:
        return None, False
    # 单跳: image 本身就是 model
    if 'cropoffset' in j or 'puppet' in j or 'autosize' in j or 'solidlayer' in j:
        return j.get('cropoffset'), bool(j.get('puppet'))
    # 双跳: image -> model
    model = j.get('model')
    if model:
        mj = _load_json(f, model)
        if mj is not None:
            return mj.get('cropoffset'), bool(mj.get('puppet'))
    return j.get('cropoffset'), bool(j.get('puppet'))

results = []
errors = []
skipped_no_scene = []

ids = sorted(os.listdir(ROOT))
scanned = 0
for wid in ids:
    d = os.path.join(ROOT, wid)
    if not os.path.isdir(d):
        continue
    pkg = os.path.join(d, 'scene.pkg')
    if not os.path.exists(pkg):
        # 可能是 video/web 壁纸
        skipped_no_scene.append((wid, 'no scene.pkg'))
        continue
    try:
        f = rd(pkg)
    except Exception as e:
        errors.append((wid, 'rd:' + str(e)))
        continue
    scene_blob = f.get('scene.json')
    if scene_blob is None:
        skipped_no_scene.append((wid, 'pkg-no-scene.json'))
        continue
    try:
        sc = json.loads(scene_blob)
    except Exception as e:
        errors.append((wid, 'json:' + str(e)))
        continue
    scanned += 1
    objs = sc.get('objects', []) or []
    n = len(objs)
    with_parent = 0
    with_scale = 0
    with_angle = 0
    with_crop = 0
    image_jsons = []
    part_named = 0
    parent_of_part = {}  # parent id -> count of part-named children
    for o in objs:
        par = o.get('parent')
        if par is not None and str(par) != '' and str(par) != str(o.get('id')):
            with_parent += 1
        if non_identity_scale(o.get('scale')):
            with_scale += 1
        if nonzero_vec(o.get('angles')):
            with_angle += 1
        nm = o.get('name', '')
        img = o.get('image')
        if img:
            image_jsons.append(img)
        if is_part_name(nm):
            part_named += 1
            if par is not None:
                parent_of_part[str(par)] = parent_of_part.get(str(par), 0) + 1
    # cropoffset / puppet 统计(尽力,库小)
    with_puppet = 0
    for o in objs:
        img = o.get('image')
        if not img:
            continue
        co, has_pup = find_model_info(f, img)
        if nonzero_vec(co):
            with_crop += 1
        if has_pup:
            with_puppet += 1
    md = max_parent_depth(objs)
    distinct_imgs = len(set(image_jsons))
    # 多部件角色启发:有共享 parent 的多个部件名子层 且 image 指向多个不同 json
    max_shared = max(parent_of_part.values()) if parent_of_part else 0
    is_multipart = (part_named >= 4 and max_shared >= 3 and distinct_imgs >= 4) or \
                   (part_named >= 6 and with_parent >= 4) or \
                   (with_puppet >= 1 and with_parent >= 4 and part_named >= 3)
    results.append({
        'id': wid,
        'objectCount': n,
        'maxParentDepth': md,
        'objsWithParent': with_parent,
        'objsWithNonIdentityScale': with_scale,
        'objsWithAngle': with_angle,
        'objsWithCropoffset': with_crop,
        'objsWithPuppet': with_puppet,
        'partNamed': part_named,
        'distinctImages': distinct_imgs,
        'maxSharedParentParts': max_shared,
        'isMultiPartCharacter': is_multipart,
    })

# 位置敏感度评分: 深层级权重最高,其次多部件,其次带 scale/angle/crop 的子层
def score(r):
    s = 0
    s += r['maxParentDepth'] * 100
    s += (50 if r['isMultiPartCharacter'] else 0)
    s += r['objsWithParent'] * 3
    s += r['objsWithNonIdentityScale'] * 2
    s += r['objsWithAngle'] * 1
    s += r['objsWithCropoffset'] * 6
    s += r.get('objsWithPuppet', 0) * 8
    s += r['partNamed'] * 2
    return s

results.sort(key=score, reverse=True)

out = {
    'scanned': scanned,
    'errors': errors,
    'skipped_no_scene_count': len(skipped_no_scene),
    'total_multipart': sum(1 for r in results if r['isMultiPartCharacter']),
    'deepest': max((r['maxParentDepth'] for r in results), default=0),
    'depth_histogram': {},
    'results': results,
}
hist = {}
for r in results:
    hist[r['maxParentDepth']] = hist.get(r['maxParentDepth'], 0) + 1
out['depth_histogram'] = dict(sorted(hist.items()))

with open('Tools/layer_survey_result.json', 'w') as fp:
    json.dump(out, fp, ensure_ascii=False, indent=2)

print("scanned scene wallpapers:", scanned)
print("skipped (no scene.json / video/web):", len(skipped_no_scene))
print("errors:", len(errors), errors[:5])
print("total multipart characters:", out['total_multipart'])
print("deepest parent chain:", out['deepest'])
print("depth histogram:", out['depth_histogram'])
print("--- TOP 15 by position sensitivity ---")
for r in results[:18]:
    print("%-12s n=%3d depth=%d par=%3d scale=%3d ang=%3d crop=%3d pup=%2d part=%3d distimg=%3d shared=%2d MP=%s" % (
        r['id'], r['objectCount'], r['maxParentDepth'], r['objsWithParent'],
        r['objsWithNonIdentityScale'], r['objsWithAngle'], r['objsWithCropoffset'],
        r.get('objsWithPuppet', 0),
        r['partNamed'], r['distinctImages'], r['maxSharedParentParts'],
        'Y' if r['isMultiPartCharacter'] else '-'))
