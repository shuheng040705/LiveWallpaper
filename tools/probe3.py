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

f=rd(os.path.join(ROOT,'1184092135','scene.pkg'))
blob=f['PzSrkM0.tex']
L=[]
def p(*a): L.append(' '.join(str(x) for x in a))
p("blobsize", len(blob))
# 各种图片签名位置
sigs={'PNG':b'\x89PNG','JPG':b'\xff\xd8\xff','BMP':b'BM','DDS':b'DDS ','RIFF':b'RIFF','GIF':b'GIF8','TIFF_II':b'II*\x00','TIFF_MM':b'MM\x00*'}
for name,s in sigs.items():
    pos=blob.find(s)
    p("  %-8s @ %d"%(name,pos))
# 找第二个 NUL 之后再数 8 个 int 的精确字节
# 头: TEXV0005\0 TEXI0001\0 = 18 bytes, +7 int(28) = 46, TEXB0002\0 = 9 -> 55
# 然后逐 int dump 头部 64 字节的 hex(只在末尾)
o=0
e=blob.index(0,o); m1=blob[o:e]; o=e+1
e=blob.index(0,o); m2=blob[o:e]; o=e+1
o+=28
e=blob.index(0,o); m3=blob[o:e]; o=e+1
p("after m3 offset", o)
ints=[struct.unpack_from('<i',blob,o+4*j)[0] for j in range(8)]
p("8 ints from data-region start:", ints)
# 假设 data 从 o + 8*4 - ?  我们已知 szC=1962045 出现在某处; 反推 data 起点 = blobsize - 1962045
guess = len(blob) - 1962045
p("if data is last 1962045 bytes, starts @", guess, "first4hex", blob[guess:guess+4].hex())
# 也试 last bytes
p("last image candidate first8hex(@%d): %s"%(guess, blob[guess:guess+8].hex()))
open('/Users/a55555/Developer/LiveWallpaper/tools/probe3_result.txt','w').write('\n'.join(L)+'\n')
print("done")
