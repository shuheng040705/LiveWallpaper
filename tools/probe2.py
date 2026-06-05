#!/usr/bin/env python3
import struct, os
ROOT='/Users/a55555/Library/Application Support/CrossOver/Bottles/Steam/drive_c/Program Files (x86)/Steam/steamapps/workshop/content/431960'

def rd(path):
    d=open(path,'rb').read();o=[0]
    def i():
        v=struct.unpack_from('<i',d,o[0])[0];o[0]+=4;return v
    ml=i();o[0]+=ml;c=i();E=[]
    for _ in range(c):
        nl=i();nm=d[o[0]:o[0]+nl].decode('utf-8','replace');o[0]+=nl;of=i();sz=i();E.append((nm,of,sz))
    b=o[0];return {n.replace(chr(92),'/'):d[b+of:b+of+sz] for n,of,sz in E}

class R:
    def __init__(self,blob): self.b=blob; self.o=0
    def nt(self):
        e=self.b.index(0,self.o); v=self.b[self.o:e].decode('latin1'); self.o=e+1; return v
    def I(self):
        v=struct.unpack_from('<i',self.b,self.o)[0]; self.o+=4; return v

L=[]
def p(*a): L.append(' '.join(str(x) for x in a))

f=rd(os.path.join(ROOT,'1184092135','scene.pkg'))
p("files:", len(f))
for k in sorted(f):
    if k.endswith('.tex'):
        blob=f[k]
        r=R(blob)
        m1=r.nt(); m2=r.nt()
        fmt=r.I(); flags=r.I(); tw=r.I(); th=r.I(); iw=r.I(); ih=r.I(); unk=r.I()
        m3=r.nt(); ver=int(m3[-1])
        p("tex %s : m1=%s m2=%s fmt=%d flags=%d texWH=%dx%d imgWH=%dx%d unk=%d m3=%s"%(
            os.path.basename(k),m1,m2,fmt,flags,tw,th,iw,ih,unk,m3))
        # 接下来按 TEXB0002 探:打印后续 12 个 int + 找内嵌图片
        ints=[struct.unpack_from('<i',blob,r.o+4*j)[0] for j in range(12)]
        p("  next12ints:", ints)
        png=blob.find(b'\x89PNG'); jpg=blob.find(b'\xff\xd8\xff')
        p("  PNG@%d JPG@%d totalbytes=%d"%(png,jpg,len(blob)))
        if png>=0:
            iend=blob.find(b'IEND',png)
            p("  PNG IEND@%d  pngsize~%d"%(iend, (iend+8-png) if iend>=0 else -1))

open('/Users/a55555/Developer/LiveWallpaper/tools/probe2_result.txt','w').write('\n'.join(L)+'\n')
print("done",len(L))
