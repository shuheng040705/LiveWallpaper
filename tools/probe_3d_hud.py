#!/usr/bin/env python3
# Phase 1 调查:扒某 3D 透视壁纸里**非 model 对象**(2D/文字/UI)的结构,
# 判定每个层是「3D 世界浮空标签」还是「屏幕空间 UI」。配合引擎 WP_3D_HUD_LOG 的 hostXY 一起看。
# 用法: python3 Tools/probe_3d_hud.py 3589454154
import struct, os, json, sys, re
ROOT = "/Users/a55555/Library/Application Support/CrossOver/Bottles/Steam/drive_c/Program Files (x86)/Steam/steamapps/workshop/content/431960"

def read_pkg(path):
    d = open(path, 'rb').read(); off = 0
    def i32():
        nonlocal off; v = struct.unpack_from('<i', d, off)[0]; off += 4; return v
    mlen = i32(); off += mlen; count = i32(); ents = []
    for _ in range(count):
        nlen = i32(); name = d[off:off+nlen].decode('utf-8', 'replace'); off += nlen
        o = i32(); sz = i32(); ents.append((name, o, sz))
    base = off
    return {n.replace('\\', '/'): d[base+o:base+o+sz] for n, o, sz in ents}

def f3(v):
    if isinstance(v, str):
        p = v.split()
        try: return (float(p[0]), float(p[1]), float(p[2]))
        except: return None
    if isinstance(v, dict):
        val = v.get('value')
        if isinstance(val, str):
            p = val.split()
            try: return (float(p[0]), float(p[1]), float(p[2]))
            except: return None
    return None

def main(tid):
    files = read_pkg(os.path.join(ROOT, tid, "scene.pkg"))
    sj = json.loads(next(files[k] for k in files if k.endswith('scene.json')))
    objs = sj.get('objects', [])
    byid = {o.get('id'): o for o in objs}
    gen = sj.get('general', {})
    proj = gen.get('orthogonalprojection')
    print(f"== {tid} orthogonalprojection={proj} (null=3D透视) fov={gen.get('fov')} ==")

    def chain_top(oid, depth=0):
        o = byid.get(oid)
        if not o or depth > 40: return oid
        p = o.get('parent')
        return chain_top(p, depth+1) if (p is not None and p in byid) else oid

    print(f"\n非 model 对象(2D/文字/UI),共 {sum(1 for o in objs if not o.get('model'))} 个;只列有 image 或 text 的:")
    print(f"{'id':>5} {'name':16} {'kind':6} {'origin':28} {'parent':>6} {'chainTop':>8}  textScript?")
    for o in objs:
        if o.get('model'):
            continue
        oid = o.get('id'); nm = str(o.get('name'))[:16]
        has_img = bool(o.get('image'))
        textf = o.get('text')
        has_text = isinstance(textf, dict) or (isinstance(textf, str) and textf)
        if not has_img and not has_text:
            continue
        kind = 'text' if has_text else 'image'
        origin = o.get('origin')
        org_s = ('SCRIPT' if isinstance(origin, dict) and 'script' in origin else '') + str(f3(origin) if not (isinstance(origin, dict) and 'script' in origin) else origin.get('value'))
        textscript = ''
        if isinstance(textf, dict) and 'script' in textf:
            textscript = 'YES(reads:' + ','.join(sorted(set(re.findall(r'shared\.(\w+)', textf['script'])))[:4]) + ')'
        top = chain_top(oid)
        topnm = str(byid.get(top, {}).get('name'))[:10] if top in byid else '?'
        print(f"{oid:>5} {nm:16} {kind:6} {org_s[:28]:28} {str(o.get('parent')):>6} {str(top)+'/'+topnm:>8}  {textscript}")

if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "3589454154")
