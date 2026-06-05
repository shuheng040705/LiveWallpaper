#!/usr/bin/env python3
# 验证假设:scene.pkg 里的 GPU 纹理 = LZ4-block 压缩的 DXT(BC1/BC3) 块。
# 自带 LZ4 block 解码 + DXT 解码,合成一个 scene 的 image 图层为 PNG,与 preview 对比。
import struct, glob, os, json, sys, io

ROOT='/Users/a55555/Library/Application Support/CrossOver/Bottles/Steam/drive_c/Program Files (x86)/Steam/steamapps/workshop/content/431960'
wid = sys.argv[1] if len(sys.argv)>1 else '3504284734'
OUT = sys.argv[2] if len(sys.argv)>2 else '/tmp/lz4_%s.png'%wid

def rd(path):
    d=open(path,'rb').read();o=0
    def i():
        nonlocal o;v=struct.unpack_from('<i',d,o)[0];o+=4;return v
    ml=i();o+=ml;c=i();E=[]
    for _ in range(c):
        nl=i();nm=d[o:o+nl].decode('utf-8','replace');o+=nl;of=i();sz=i();E.append((nm,of,sz))
    b=o;return {n.replace(chr(92),'/'):d[b+of:b+of+sz] for n,of,sz in E}

def mip0(blob):
    o=0
    def nt():
        nonlocal o;e=blob.index(0,o);v=blob[o:e].decode('latin1');o=e+1;return v
    def I():
        nonlocal o;v=struct.unpack_from('<i',blob,o)[0];o+=4;return v
    nt();nt();fmt=I();flags=I();tw=I();th=I();iw=I();ih=I();I();m3=nt();ver=int(m3[-1]);I();mc=I()
    if ver>=4:I()
    I();w=I();h=I();isC=I();szU=I();szC=I();return fmt,ver,isC,w,h,szU,blob[o:o+szC]

def lz4_block(src, dst_size):
    out=bytearray(); i=0; n=len(src)
    while i<n:
        tok=src[i]; i+=1
        lit=tok>>4
        if lit==15:
            while True:
                b=src[i];i+=1;lit+=b
                if b!=255:break
        out+=src[i:i+lit]; i+=lit
        if i>=n: break
        off=src[i]|(src[i+1]<<8); i+=2
        ml=tok&15
        if ml==15:
            while True:
                b=src[i];i+=1;ml+=b
                if b!=255:break
        ml+=4
        start=len(out)-off
        for j in range(ml):
            out.append(out[start+j])
    return bytes(out[:dst_size])

def c565(c):
    r=(c>>11)&31; g=(c>>5)&63; b=c&31
    return (r*255//31, g*255//63, b*255//31)

def dxt_decode(data,w,h,bc):  # bc=1 (DXT1) or 3 (DXT5)
    out=bytearray(w*h*4)
    bw=(w+3)//4; bh=(h+3)//4; p=0
    for by in range(bh):
        for bx in range(bw):
            if bc==3:
                a0,a1=data[p],data[p+1]; abits=int.from_bytes(data[p+2:p+8],'little'); cp=p+8
                al=[a0,a1]
                if a0>a1:
                    for k in range(1,7): al.append(((7-k)*a0+k*a1)//7)
                else:
                    for k in range(1,5): al.append(((5-k)*a0+k*a1)//5)
                    al+=[0,255]
            else:
                cp=p; abits=0; al=None
            c0,c1=struct.unpack_from('<HH',data,cp); bits=struct.unpack_from('<I',data,cp+4)[0]
            r0,g0,b0=c565(c0); r1,g1,b1=c565(c1)
            if bc==1 and c0<=c1:
                pal=[(r0,g0,b0,255),(r1,g1,b1,255),((r0+r1)//2,(g0+g1)//2,(b0+b1)//2,255),(0,0,0,0)]
            else:
                pal=[(r0,g0,b0,255),(r1,g1,b1,255),((2*r0+r1)//3,(2*g0+g1)//3,(2*b0+b1)//3,255),((r0+2*r1)//3,(g0+2*g1)//3,(b0+2*b1)//3,255)]
            p+=(8 if bc==1 else 16)
            for py in range(4):
                for px in range(4):
                    x=bx*4+px;y=by*4+py
                    if x<w and y<h:
                        ci=(bits>>(2*(4*py+px)))&3
                        col=list(pal[ci])
                        if bc==3:
                            ai=(abits>>(3*(4*py+px)))&7; col[3]=al[ai]
                        o=(y*w+x)*4; out[o:o+4]=bytes(col)
    return out

def get_rgba(blob):
    fmt,ver,isC,w,h,szU,data=mip0(blob)
    if fmt==0:
        if data[:4]==b'\x89PNG' or data[:3]==b'\xff\xd8\xff': return ('enc',data,w,h)
        return None
    raw = lz4_block(data,szU) if isC else data
    if len(raw)<szU: return ('short',raw,w,h)
    if fmt==7: return ('rgba',dxt_decode(raw,w,h,1),w,h)
    if fmt in (4,6): return ('rgba',dxt_decode(raw,w,h,3),w,h)
    if fmt==8:
        out=bytearray(w*h*4)
        for i in range(w*h): out[i*4]=raw[i*2];out[i*4+1]=raw[i*2+1];out[i*4+2]=0;out[i*4+3]=255
        return ('rgba',out,w,h)
    if fmt==9:
        out=bytearray(w*h*4)
        for i in range(w*h): v=raw[i];out[i*4]=out[i*4+1]=out[i*4+2]=v;out[i*4+3]=255
        return ('rgba',out,w,h)
    return None

try: from PIL import Image
except ImportError: print("NO_PIL");sys.exit(3)

f=rd(os.path.join(ROOT,wid,'scene.pkg'))
scene=json.loads(f['scene.json'])
op=scene.get('general',{}).get('orthogonalprojection',{})
CW,CH=int(op.get('width',1920)),int(op.get('height',1080))
canvas=Image.new('RGBA',(CW,CH),(20,20,20,255))
def J(key):
    bn=os.path.basename(key)
    for k in f:
        if os.path.basename(k)==bn and k.endswith('.json'):
            try:return json.loads(f[k])
            except:return None
    return None
placed=0;fails=0
for obj in scene.get('objects',[]):
    if not isinstance(obj.get('image'),str): continue
    if obj.get('visible',True)==False: continue
    m=J(obj['image']);
    if not m or not m.get('material'): continue
    mat=J(m['material'])
    if not mat: continue
    tex=None
    for ps in mat.get('passes',[]):
        for t in (ps.get('textures') or []):
            if t:tex=t;break
        if tex:break
    if not tex: continue
    key=next((k for k in f if os.path.basename(k)==os.path.basename(tex)+'.tex'),None)
    if not key: continue
    try: r=get_rgba(f[key])
    except Exception as e: r=None; fails+=1
    if not r or r[0] in ('short',): fails+=1; continue
    kind,buf,w,h=r
    img=Image.open(io.BytesIO(buf)).convert('RGBA') if kind=='enc' else Image.frombytes('RGBA',(w,h),bytes(buf))
    sz=obj.get('size')
    sw,sh=([float(x) for x in sz.split()] if sz else [w,h])
    sc=obj.get('scale','1 1 1').split(); ew,eh=int(sw*float(sc[0])),int(sh*float(sc[1]))
    if ew<1 or eh<1 or ew>20000 or eh>20000: continue
    img=img.resize((ew,eh))
    ori=obj.get('origin','0 0 0').split(); cx,cy=float(ori[0]),float(ori[1])
    px=int(cx-ew/2); py=int(CH-(cy+eh/2))
    canvas.alpha_composite(img,(px,py)); placed+=1
canvas.convert('RGB').save(OUT)
print("PLACED %d FAILS %d -> %s (%dx%d)"%(placed,fails,OUT,CW,CH))
