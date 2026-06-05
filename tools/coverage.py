#!/usr/bin/env python3
# 对 43 个 scene 分类:简单(图层纹理几乎都是 format-0 PNG/JPG,现在就能渲染好)
# vs 复杂(含 DXT 压缩纹理 / 大量图层 / 效果 / 粒子)。
import struct, glob, os, json

ROOT='/Users/a55555/Library/Application Support/CrossOver/Bottles/Steam/drive_c/Program Files (x86)/Steam/steamapps/workshop/content/431960'
OUT='/Users/a55555/Developer/LiveWallpaper/tools/coverage_result.txt'
L=[]
def p(*a): L.append(' '.join(str(x) for x in a))

def rd(path):
    d=open(path,'rb').read();o=0
    def i():
        nonlocal o;v=struct.unpack_from('<i',d,o)[0];o+=4;return v
    ml=i();o+=ml;c=i();E=[]
    for _ in range(c):
        nl=i();nm=d[o:o+nl].decode('utf-8','replace');o+=nl;of=i();sz=i();E.append((nm,of,sz))
    b=o;return {n.replace(chr(92),'/'):d[b+of:b+of+sz] for n,of,sz in E}

def texfmt(blob):
    o=0
    def nt():
        nonlocal o;e=blob.index(0,o);v=blob[o:e].decode('latin1');o=e+1;return v
    def I():
        nonlocal o;v=struct.unpack_from('<i',blob,o)[0];o+=4;return v
    try:
        nt();nt();fmt=I();[I() for _ in range(6)];nt()  # 到 fmt
        return fmt
    except: return -1

def J(f,key):
    bn=os.path.basename(key)
    for k in f:
        if os.path.basename(k)==bn and k.endswith('.json'):
            try: return json.loads(f[k])
            except: return None
    return None

simple=0; complexc=0
p("%-12s %5s %5s %5s %5s %6s  %s"%("id","imgL","fmt0","dxt","part","class","title"))
for pk in sorted(glob.glob(os.path.join(ROOT,'*/scene.pkg'))):
    wid=os.path.basename(os.path.dirname(pk))
    try:
        f=rd(pk); sj=json.loads(f['scene.json'])
    except: p(wid,"PARSE_FAIL"); continue
    title=""
    try: title=json.load(open(os.path.join(ROOT,wid,'project.json'))).get('title','')[:30]
    except: pass
    objs=sj.get('objects',[])
    imgL=[o for o in objs if isinstance(o.get('image'),str) and o.get('visible',True)]
    nfmt0=ndxt=nother=0
    has_effects=False
    for o in imgL:
        if o.get('effects'): has_effects=True
        m=J(f,o['image'])
        if not m: continue
        mat=J(f,m.get('material','')) if m.get('material') else None
        if not mat: continue
        tex=None
        for ps in mat.get('passes',[]):
            for t in (ps.get('textures') or []):
                if t: tex=t;break
            if tex:break
        if not tex: continue
        cand=os.path.basename(tex)+'.tex'
        key=next((k for k in f if os.path.basename(k)==cand),None)
        if not key: continue
        fm=texfmt(f[key])
        if fm==0: nfmt0+=1
        elif fm in (4,6,7): ndxt+=1
        else: nother+=1
    npart=len([o for o in objs if 'particle' in o])
    # 分类:图层<=3 且 无DXT纹理 且 无粒子 → 简单
    is_simple = (len(imgL)<=4 and ndxt==0 and npart==0)
    cls="简单" if is_simple else "复杂"
    if is_simple: simple+=1
    else: complexc+=1
    p("%-12s %5d %5d %5d %5d  %4s  %s"%(wid,len(imgL),nfmt0,ndxt,npart,cls,title))

p("")
p("简单(现在就能原生渲染好): %d"%simple)
p("复杂(需DXT解码+效果+粒子): %d"%complexc)
open(OUT,'w').write('\n'.join(L)+'\n')
print("done",len(L),"->",OUT)
