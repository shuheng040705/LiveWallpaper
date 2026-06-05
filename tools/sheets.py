#!/usr/bin/env python3
# 用已渲染好的 /tmp/q/r_*.png 和 preview,生成小尺寸可读对比页(每页3对,限宽1200)。
import os, glob, json
from PIL import Image, ImageDraw

ROOT='/Users/a55555/Library/Application Support/CrossOver/Bottles/Steam/drive_c/Program Files (x86)/Steam/steamapps/workshop/content/431960'
QDIR='/tmp/q'; OUT='/tmp/sheets'; os.makedirs(OUT,exist_ok=True)
CELL_H=240; MAXW=560

def title(wid):
    try: return json.load(open(os.path.join(ROOT,wid,'project.json'))).get('title','')[:22]
    except: return wid

def loadh(p,h,maxw):
    try:
        im=Image.open(p).convert('RGB'); w=int(im.width*h/im.height)
        if w>maxw:
            h2=int(h*maxw/w); w=maxw
            return im.resize((w,h2))
        return im.resize((max(1,w),h))
    except: return None

ids=[os.path.basename(p)[2:-4] for p in sorted(glob.glob(os.path.join(QDIR,'r_*.png')))]
pairs=[]
for wid in ids:
    rim=loadh(os.path.join(QDIR,'r_%s.png'%wid),CELL_H,MAXW)
    pim=loadh(os.path.join(QDIR,'p_%s.png'%wid),CELL_H,MAXW)
    if rim is None: rim=Image.new('RGB',(200,CELL_H),(60,0,0))
    if pim is None: pim=Image.new('RGB',(200,CELL_H),(0,0,60))
    H=max(rim.height,pim.height); gap=6; lab=20
    W=rim.width+gap+pim.width
    pr=Image.new('RGB',(W,H+lab),(25,25,25))
    pr.paste(rim,(0,lab)); pr.paste(pim,(rim.width+gap,lab))
    ImageDraw.Draw(pr).text((4,4),"%s  %s  [mine | preview]"%(wid,title(wid)),fill=(235,235,235))
    pairs.append(pr)

for i in range(0,len(pairs),3):
    grp=pairs[i:i+3]
    W=max(p.width for p in grp); Hs=sum(p.height for p in grp)+(len(grp)-1)*8
    sh=Image.new('RGB',(W,Hs),(10,10,10)); y=0
    for p in grp: sh.paste(p,(0,y)); y+=p.height+8
    sh.save(os.path.join(OUT,'s_%02d.png'%(i//3)))
print("made",(len(pairs)+2)//3,"sheets in",OUT)
