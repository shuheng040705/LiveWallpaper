#!/usr/bin/env python3
# 逐部件 puppet 渲染审计:渲染全库含骨骼(puppet)的壁纸,出对照图供逐张核对正确性。
# 用法:
#   python3 Tools/wp_puppet_audit.py            # 渲染所有 puppet 壁纸(修复版)+ 拼图 → /tmp/puppet_audit/
#   python3 Tools/wp_puppet_audit.py --ba <id>   # 对单张做「修复前(WP_ATTACH_ADD_BONEPOS) vs 修复后」对照
# 思路(用户方向):识别每张 puppet 壁纸 → 逐个无头渲染(暖机 settle 姿态)→ 拼对照图 → 人工/视觉核对哪个部件没归位。
import struct, json, os, sys, subprocess, glob

ROOT="/Users/a55555/Library/Application Support/CrossOver/Bottles/Steam/drive_c/Program Files (x86)/Steam/steamapps/workshop/content/431960"
BIN=os.environ.get("WP_BIN", "/Users/a55555/Developer/LiveWallpaper/.build/release/LiveWallpaper")
OUT="/tmp/puppet_audit"
WARM=os.environ.get("WP_WARMUP","60")
LONG=os.environ.get("WP_LONG","900")

def read_pkg(path):
    d=open(path,'rb').read(); o=0
    def i():
        nonlocal o; v=struct.unpack_from('<i',d,o)[0]; o+=4; return v
    ml=i(); o+=ml; c=i(); E=[]
    for _ in range(c):
        nl=i(); nm=d[o:o+nl].decode('utf-8','replace'); o+=nl; of=i(); sz=i(); E.append((nm.replace('\\','/'),of,sz))
    b=o; return {n:d[b+of:b+of+sz] for n,of,sz in E}

def title(wid):
    try: return json.load(open(os.path.join(ROOT,wid,'project.json'))).get('title','?')
    except: return '?'

def puppet_wallpapers():
    rows=[]
    for wid in sorted(os.listdir(ROOT)):
        if not wid.isdigit(): continue
        pkg=os.path.join(ROOT,wid,'scene.pkg')
        if not os.path.exists(pkg): continue
        try: F=read_pkg(pkg)
        except: continue
        npup=sum(1 for k in F if k.lower().endswith('_puppet.mdl'))
        if npup==0: continue
        sj=None
        for k in F:
            if k.endswith('scene.json'):
                try: sj=json.loads(F[k].decode('utf-8','replace'))
                except: pass
                break
        natt=sum(1 for ob in (sj.get('objects',[]) if sj else []) if ob.get('attachment'))
        rows.append((wid,npup,natt))
    rows.sort(key=lambda r:-r[2])
    return rows

def render(wid, out, extra_env=None):
    env=dict(os.environ); env["WP_WARMUP"]=WARM
    if extra_env: env.update(extra_env)
    r=subprocess.run([BIN,"--render",wid,out,LONG], env=env, capture_output=True, text=True, timeout=300)
    return os.path.exists(out)

def montage(items, outpath, cols=3):
    from PIL import Image, ImageDraw
    imgs=[(lbl, Image.open(p).convert('RGB')) for lbl,p in items if os.path.exists(p)]
    if not imgs: print("无图可拼"); return
    cw=max(im.width for _,im in imgs); ch=max(im.height for _,im in imgs)
    pad=8; lblh=22
    rows=(len(imgs)+cols-1)//cols
    W=cols*(cw+pad)+pad; H=rows*(ch+lblh+pad)+pad
    canvas=Image.new('RGB',(W,H),(40,40,40)); dr=ImageDraw.Draw(canvas)
    for idx,(lbl,im) in enumerate(imgs):
        r,c=divmod(idx,cols); x=pad+c*(cw+pad); y=pad+r*(ch+lblh+pad)
        dr.text((x+2,y+2),lbl,fill=(255,255,150)); canvas.paste(im,(x,y+lblh))
    canvas.save(outpath); print(f"拼图 -> {outpath} ({W}x{H}, {len(imgs)} 张)")

if __name__=="__main__":
    os.makedirs(OUT, exist_ok=True)
    if len(sys.argv)>=3 and sys.argv[1]=="--ba":
        wid=sys.argv[2]
        a=os.path.join(OUT,f"{wid}_fixed.png"); b=os.path.join(OUT,f"{wid}_old.png")
        print(f"渲染修复后…"); render(wid,a)
        print(f"渲染修复前(WP_ATTACH_ADD_BONEPOS)…"); render(wid,b,{"WP_ATTACH_ADD_BONEPOS":"1"})
        montage([("FIXED",a),("OLD(bonepos)",b)], os.path.join(OUT,f"{wid}_BA.png"), cols=2)
    else:
        rows=puppet_wallpapers()
        print(f"含 puppet 壁纸 {len(rows)} 张,逐张渲染(warmup={WARM})…")
        items=[]
        for wid,npup,natt in rows:
            out=os.path.join(OUT,f"{wid}.png")
            ok=render(wid,out)
            print(f"  {wid} puppet={npup} attach={natt} {'OK' if ok else 'FAIL'}  {title(wid)[:34]}")
            if ok: items.append((f"{wid} att{natt}", out))
        montage(items, os.path.join(OUT,"ALL_puppet.png"), cols=4)
