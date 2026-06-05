#!/usr/bin/env python3
# 诊断单个失败纹理:1184092135 / PzSrkM0.tex 为何解码失败。
import struct, os, json

ROOT='/Users/a55555/Library/Application Support/CrossOver/Bottles/Steam/drive_c/Program Files (x86)/Steam/steamapps/workshop/content/431960'
def rd(path):
    d=open(path,'rb').read();o=0
    def i():
        nonlocal o;v=struct.unpack_from('<i',d,o)[0];o+=4;return v
    ml=i();o+=ml;c=i();E=[]
    for _ in range(c):
        nl=i();nm=d[o:o+nl].decode('utf-8','replace');o+=nl;of=i();sz=i();E.append((nm,of,sz))
    b=o;return {n.replace(chr(92),'/'):d[b+of:b+of+sz] for n,of,sz in E}

L=[]
def p(*a): L.append(' '.join(str(x) for x in a))

for wid,texhint in [('1184092135','PzSrkM0'),('3713073223',None)]:
    f=rd(os.path.join(ROOT,wid,'scene.pkg'))
    p("=== %s ==="%wid)
    texs=[k for k in f if k.endswith('.tex')]
    for k in texs:
        blob=f[k]; o=0
        def nt():
            global o; e=blob.index(0,o); v=blob[o:e].decode('latin1'); o=e+1; return v
        def I():
            global o; v=struct.unpack_from('<i',blob,o)[0]; o+=4; return v
        try:
            o=0
            m1=nt(); m2=nt(); fmt=I(); flags=I(); tw=I(); th=I(); iw=I(); ih=I(); unk=I()
            m3=nt(); ver=int(m3[-1]); imgc=I(); mip=I()
            if ver>=4: I()
            free=I(); w=I(); h=I(); isC=I(); szU=I(); szC=I()
            sig=blob[o:o+4].hex()
            p("  %-30s fmt=%d ver=%s isC=%d mip=%d w=%d h=%d szU=%d szC=%d free=%d m1=%s m3=%s sig=%s"%(
                os.path.basename(k)[:30],fmt,m3,isC,mip,w,h,szU,szC,free,m1,m3,sig))
        except Exception as e:
            p("  %-30s PARSE_ERR %s"%(os.path.basename(k)[:30],e))

open('/Users/a55555/Developer/LiveWallpaper/tools/probe1_result.txt','w').write('\n'.join(L)+'\n')
print("done")
