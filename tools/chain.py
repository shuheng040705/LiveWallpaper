#!/usr/bin/env python3
# 诊断 image->model->material->texture 解析链,并统计 43 个 scene 的命中率。
import struct, glob, os, json

ROOT = "/Users/a55555/Library/Application Support/CrossOver/Bottles/Steam/drive_c/Program Files (x86)/Steam/steamapps/workshop/content/431960"
OUT = "/Users/a55555/Developer/LiveWallpaper/tools/chain_result.txt"
lines = []
def p(*a): lines.append(' '.join(str(x) for x in a))
def safe(s): return ''.join(c if (32 <= ord(c) < 127) else '?' for c in str(s))

def rd(path):
    d=open(path,'rb').read();o=0
    def i():
        nonlocal o;v=struct.unpack_from('<i',d,o)[0];o+=4;return v
    ml=i();o+=ml;c=i();E=[]
    for _ in range(c):
        nl=i();nm=d[o:o+nl].decode('utf-8','replace');o+=nl;of=i();sz=i();E.append((nm,of,sz))
    b=o;return {n.replace(chr(92),'/'):d[b+of:b+of+sz] for n,of,sz in E}

def J(files,key):
    # 容错:按 basename 找
    if key in files: return json.loads(files[key])
    bn=os.path.basename(key)
    for k in files:
        if os.path.basename(k)==bn: return json.loads(files[k])
    return None

# 1) 详查 2983345987
target = os.path.join(ROOT,'2983345987','scene.pkg')
f = rd(target)
p("=== 2983345987 files ===")
for k in sorted(f): p("  ", safe(k), len(f[k]))
sj = json.loads(f['scene.json'])
objs = sj.get('objects',[])
p("objects:", len(objs))
for o in objs:
    if 'image' in o:
        p("IMG obj id", o.get('id'), "image=", safe(o.get('image')))
        m = J(f, o['image'])
        p("  model:", safe(json.dumps(m, ensure_ascii=False))[:200] if m else "NOT FOUND")
        if m and 'material' in m:
            mat = J(f, m['material'])
            p("  material keys:", list(mat.keys()) if mat else "NOT FOUND")
            if mat:
                for pi,ps in enumerate(mat.get('passes',[])):
                    p("    pass",pi,"shader=",safe(ps.get('shader')),"textures=",safe(json.dumps(ps.get('textures'),ensure_ascii=False)))

# 2) 全量命中率
p("\n=== 43 scene texture-resolution survey ===")
ok=0; total=0; nolayer=0
for pk in sorted(glob.glob(os.path.join(ROOT,'*/scene.pkg'))):
    wid=os.path.basename(os.path.dirname(pk))
    try: f=rd(pk)
    except Exception as e: p(wid,"PKG_FAIL",e); continue
    try: sj=json.loads(f['scene.json'])
    except Exception as e: p(wid,"SCENE_FAIL",e); continue
    imgs=[o for o in sj.get('objects',[]) if 'image' in o]
    if not imgs: nolayer+=1; p(wid,"NO_IMAGE_LAYER objects=",len(sj.get('objects',[]))); continue
    total+=1
    # 试解析第一个 image 层纹理
    resolved=False; reason=""
    o=imgs[0]
    m=J(f,o['image'])
    if not m: reason="model_missing"
    else:
        mp=m.get('material')
        mat=J(f,mp) if mp else None
        if not mat: reason="material_missing mat="+safe(str(mp))
        else:
            passes=mat.get('passes',[])
            tex=None
            for ps in passes:
                ts=ps.get('textures') or []
                for t in ts:
                    if t: tex=t; break
                if tex: break
            if not tex: reason="no_texture_in_passes shader="+safe(str(passes[0].get('shader') if passes else None))
            else:
                # 找 .tex 文件
                cand=os.path.basename(tex)+'.tex'
                hit=any(os.path.basename(k)==cand for k in f)
                if hit: resolved=True
                else: reason="tex_file_missing tex="+safe(tex)
    if resolved: ok+=1
    else: p(wid,"MISS",reason)
p("\nRESOLVED %d/%d image-scenes (no-image-layer scenes: %d)"%(ok,total,nolayer))

open(OUT,'w').write('\n'.join(lines)+'\n')
print("done", len(lines), "lines ->", OUT)
