#!/usr/bin/env python3
# 从真实 scene.pkg 推导布局。只输出干净 ASCII(字段名+整数),不输出 hex/二进制 repr。
import struct, glob, os, json

ROOT = "/Users/a55555/Library/Application Support/CrossOver/Bottles/Steam/drive_c/Program Files (x86)/Steam/steamapps/workshop/content/431960"
out = []
def p(*a): out.append(' '.join(str(x) for x in a))
def safe(s):  # 只留可见 ASCII 字母数字
    return ''.join(c if (c.isalnum() or c in '._-/') else '?' for c in s)

def read_pkg(path):
    d = open(path, 'rb').read(); off = 0
    def i32():
        nonlocal off; v = struct.unpack_from('<i', d, off)[0]; off += 4; return v
    mlen = i32(); magic = d[off:off+mlen].decode('utf-8','replace'); off += mlen
    count = i32(); entries = []
    for _ in range(count):
        nlen = i32(); name = d[off:off+nlen].decode('utf-8','replace'); off += nlen
        o = i32(); sz = i32(); entries.append((name, o, sz))
    base = off
    return safe(magic), {name.replace('\\','/'): d[base+o:base+o+sz] for name,o,sz in entries}

pkgs = sorted(glob.glob(os.path.join(ROOT, '*/scene.pkg')))
p("PKG_COUNT", len(pkgs))
magic, files = read_pkg(pkgs[0])
p("SAMPLE", os.path.basename(os.path.dirname(pkgs[0])))
p("MAGIC_SAFE", magic)
p("FILE_COUNT", len(files))
p("EXT_HISTOGRAM:")
hist = {}
for k in files:
    e = k.rsplit('.',1)[-1] if '.' in k else '(none)'
    hist[e] = hist.get(e,0)+1
for e,c in sorted(hist.items(), key=lambda x:-x[1]):
    p("  ext", e, c)

sj_key = next(k for k in files if k.endswith('scene.json'))
sj = json.loads(files[sj_key])
p("SCENE_TOPKEYS", ','.join(sorted(sj.keys())))
gen = sj.get('general', {})
p("GENERAL_KEYS", ','.join(sorted(gen.keys())))
op = gen.get('orthogonalprojection')
if isinstance(op, dict): p("ORTHO_W", op.get('width'), "ORTHO_H", op.get('height'))
objs = sj.get('objects', [])
p("OBJ_COUNT", len(objs))
img = next(o for o in objs if 'image' in o)
p("IMGLAYER_FIELDS", ','.join(sorted(img.keys())))
for k in ['origin','angles','scale','size','parallaxDepth','color','alpha','blendmode','visible','id','name']:
    if k in img: p("  img."+k, safe(str(img[k]))[:60])

# resolve chain
mp = img['image']
mk = next(k for k in files if os.path.basename(k)==os.path.basename(mp))
model = json.loads(files[mk]); p("MODEL_KEYS", ','.join(sorted(model.keys())))
matp = model.get('material'); p("MODEL_MATERIAL", safe(matp))
matk = next(k for k in files if os.path.basename(k)==os.path.basename(matp))
mat = json.loads(files[matk]); p("MAT_KEYS", ','.join(sorted(mat.keys())))
ps0 = mat['passes'][0]
p("PASS0_KEYS", ','.join(sorted(ps0.keys())))
p("PASS0_SHADER", safe(str(ps0.get('shader'))))
p("PASS0_BLENDING", safe(str(ps0.get('blending'))))
texs = ps0.get('textures', [])
p("PASS0_TEX_COUNT", len(texs))
for t in texs: p("  tex", safe(str(t)))

# .tex header — clean ints only
tex0 = texs[0]
texk = next(k for k in files if k.endswith(tex0+'.tex'))
td = files[texk]; p("TEX_KEY", safe(texk)); p("TEX_BYTES", len(td))
o = 0
def cstr():
    global o; e = td.index(b'\x00', o); v = safe(td[o:e].decode('latin1')); o = e+1; return v
def I():
    global o; v = struct.unpack_from('<i', td, o)[0]; o += 4; return v
p("TEX_CONTAINER", cstr())
p("TEX_off_after_container", o)
hdr = [I() for _ in range(7)]
p("TEX_HDR7_ints", ','.join(str(x) for x in hdr))
p("TEX_off_after_hdr7", o)
imgc = cstr()
p("TEX_IMGCONTAINER", imgc)
p("TEX_off_after_imgcontainer", o)
nextints = struct.unpack_from('<iiiiii', td, o)
p("TEX_next6_ints", ','.join(str(x) for x in nextints))

# 关键:在整个 .tex 里找内嵌 PNG / JPEG 签名
png = td.find(b'\x89PNG\r\n\x1a\n')
jpg = td.find(b'\xff\xd8\xff')
p("EMBED_PNG_at", png)
p("EMBED_JPG_at", jpg)
if png >= 0:
    iend = td.find(b'IEND', png)
    p("EMBED_PNG_IEND_at", iend, "trailing_size", len(td)-png)
# 统计本壁纸所有 .tex 的内嵌图片占比
n_tex=n_png=n_jpg=0
for k,v in files.items():
    if k.endswith('.tex'):
        n_tex+=1
        if v.find(b'\x89PNG\r\n\x1a\n')>=0: n_png+=1
        elif v.find(b'\xff\xd8\xff')>=0: n_jpg+=1
p("THIS_WP_TEX_TOTAL", n_tex, "with_PNG", n_png, "with_JPG", n_jpg)

open('/Users/a55555/Developer/LiveWallpaper/tools/probe_result.txt','w').write('\n'.join(out)+'\n')
print("WROTE", len(out), "lines")
