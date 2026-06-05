#!/usr/bin/env python3
# 批量渲染全部 43 个 scene(用真实 Swift binary),与各自 preview 拼成对比图,
# montage 成接触印相表供逐页审查。生成 quality_report.txt 统计每个 scene 的图层命中率。
import subprocess, os, glob, json, struct, sys
from PIL import Image, ImageDraw, ImageFont

ROOT='/Users/a55555/Library/Application Support/CrossOver/Bottles/Steam/drive_c/Program Files (x86)/Steam/steamapps/workshop/content/431960'
DEV='/Users/a55555/Developer/LiveWallpaper'
BIN=subprocess.run(['swift','build','--show-bin-path'],cwd=DEV,capture_output=True,text=True).stdout.strip()+'/LiveWallpaper'
QDIR='/tmp/q'; os.makedirs(QDIR,exist_ok=True)
CELL_H=300  # 每张图高度

def scene_ids():
    ids=[]
    for pk in sorted(glob.glob(os.path.join(ROOT,'*/scene.pkg'))):
        ids.append(os.path.basename(os.path.dirname(pk)))
    return ids

def title_of(wid):
    try: return json.load(open(os.path.join(ROOT,wid,'project.json'))).get('title','')[:24]
    except: return wid

def load_h(path, h):
    try:
        im=Image.open(path).convert('RGB')
        w=int(im.width*h/im.height)
        return im.resize((max(1,w),h))
    except: return None

def preview_png(wid):
    for ext in ('jpg','png','gif','jpeg'):
        src=os.path.join(ROOT,wid,'preview.'+ext)
        if os.path.exists(src):
            out=os.path.join(QDIR,'p_%s.png'%wid)
            subprocess.run(['sips','-s','format','png',src,'--out',out],capture_output=True)
            return out
    return None

ids=scene_ids()
report=[]
report.append("%-12s %5s %5s %6s  %s"%("id","imgL","gpu","cover","title"))
pairs=[]
for wid in ids:
    rpath=os.path.join(QDIR,'r_%s.png'%wid)
    res=subprocess.run([BIN,'--render',wid,rpath,'1000','3.0'],capture_output=True,text=True)
    out=(res.stdout or '')+(res.stderr or '')
    imgL=gpu=0
    for line in out.splitlines():
        line=line.replace('\x00','')
        if 'layers(image):' in line:
            try: imgL=int(line.split('layers(image):')[1].strip().split()[0])
            except: pass
        if line.startswith('gpu layers:'):
            try: gpu=int(line.split(':')[1].strip())
            except: pass
    cover = ('%d/%d'%(gpu,imgL)) if imgL else '-'
    report.append("%-12s %5d %5d %6s  %s"%(wid,imgL,gpu,cover,title_of(wid)))

    # 拼对比图: [render | preview]
    rim=load_h(rpath,CELL_H)
    pim=load_h(preview_png(wid) or '',CELL_H)
    if rim is None and pim is None: continue
    if rim is None: rim=Image.new('RGB',(CELL_H,CELL_H),(60,0,0))
    if pim is None: pim=Image.new('RGB',(CELL_H,CELL_H),(0,0,60))
    gap=6; labelH=22
    W=rim.width+gap+pim.width
    pair=Image.new('RGB',(W,CELL_H+labelH),(25,25,25))
    pair.paste(rim,(0,labelH)); pair.paste(pim,(rim.width+gap,labelH))
    d=ImageDraw.Draw(pair)
    d.text((4,4),"%s  %s  [我的渲染 | 官方preview]"%(wid,cover),fill=(230,230,230))
    pairs.append(pair)

# montage: 每页 5 行
def make_sheets(pairs, per=5):
    sheets=[]
    for i in range(0,len(pairs),per):
        grp=pairs[i:i+per]
        W=max(p.width for p in grp); H=sum(p.height for p in grp)+ (len(grp)-1)*8
        sh=Image.new('RGB',(W,H),(10,10,10))
        y=0
        for p in grp:
            sh.paste(p,(0,y)); y+=p.height+8
        sheets.append(sh)
    return sheets

sheets=make_sheets(pairs,5)
for i,sh in enumerate(sheets):
    sh.save(os.path.join(QDIR,'sheet_%02d.png'%i))

open(os.path.join(DEV,'tools','quality_report.txt'),'w').write('\n'.join(report)+'\n')
print("RENDERED %d scenes, %d sheets -> %s/sheet_*.png"%(len(ids),len(sheets),QDIR))
print('\n'.join(report))
