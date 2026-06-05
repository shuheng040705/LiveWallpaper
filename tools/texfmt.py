#!/usr/bin/env python3
# 列出某个 scene.pkg 里每个 distinct .tex 的格式/版本/压缩/mip0 magic。
import struct, glob, os, sys

ROOT = "/Users/a55555/Library/Application Support/CrossOver/Bottles/Steam/drive_c/Program Files (x86)/Steam/steamapps/workshop/content/431960"
OUT = "/Users/a55555/Developer/LiveWallpaper/tools/texfmt_result.txt"
wid = sys.argv[1] if len(sys.argv) > 1 else "3302695207"
lines = []
def p(*a): lines.append(' '.join(str(x) for x in a))

def rd(path):
    d=open(path,'rb').read();o=0
    def i():
        nonlocal o;v=struct.unpack_from('<i',d,o)[0];o+=4;return v
    ml=i();o+=ml;c=i();E=[]
    for _ in range(c):
        nl=i();nm=d[o:o+nl].decode('utf-8','replace');o+=nl;of=i();sz=i();E.append((nm,of,sz))
    b=o;return {n.replace(chr(92),'/'):d[b+of:b+of+sz] for n,of,sz in E}

def hdr(blob):
    o=0
    def nt():
        nonlocal o; e=blob.index(0,o); v=blob[o:e].decode('latin1'); o=e+1; return v
    def I():
        nonlocal o; v=struct.unpack_from('<i',blob,o)[0]; o+=4; return v
    m1=nt(); m2=nt()
    fmt,flags,tw,th,iw,ih,unk=[I() for _ in range(7)]
    m3=nt(); ver=int(m3[-1])
    imgc=I(); mip=I()
    if ver>=4: I()
    free=I()
    w,h,isC,szU,szC=[I() for _ in range(5)]
    magic=blob[o:o+4]
    sig='PNG' if magic[:4]==b'\x89PNG' else ('JPG' if magic[:3]==b'\xff\xd8\xff' else ('zlib' if magic[:2]==b'\x78\x9c' else ('lz4?' if magic[0:1]==b'\x04' else magic.hex())))
    return fmt,ver,isC,w,h,szU,szC,free,sig

f = rd(os.path.join(ROOT, wid, 'scene.pkg'))
texs = sorted(k for k in f if k.endswith('.tex'))
p("scene", wid, "distinct .tex:", len(texs))
p("%-42s %3s %3s %3s %5s %5s %10s %10s %s" % ("name","fmt","ver","isC","w","h","szU","szC","sig"))
for k in texs:
    try:
        fmt,ver,isC,w,h,szU,szC,free,sig = hdr(f[k])
        nm=k[:40]
        p("%-42s %3d %3d %3d %5d %5d %10d %10d %s(free=%d)" % (nm,fmt,ver,isC,w,h,szU,szC,sig,free))
    except Exception as e:
        p("%-42s ERR %s" % (k[:40], e))

open(OUT,'w').write('\n'.join(lines)+'\n')
print("done", len(lines), "->", OUT)
