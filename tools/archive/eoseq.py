from PIL import Image, ImageDraw
box=(720,160,940,280)
frames=[6,9,12,15,18]
s=4
imgs=[(w,Image.open('/tmp/eo_w%d.png'%w).convert('RGB').crop(box).resize((box[2]-box[0])*s and ((box[2]-box[0])*s,(box[3]-box[1])*s),Image.NEAREST)) for w in frames]
cw,ch=imgs[0][1].size
strip=Image.new('RGB',((cw+10)*len(imgs),ch+20),(40,40,40)); d=ImageDraw.Draw(strip)
x=0
for w,im in imgs:
    d.text((x+4,3),"w=%d"%w,fill=(255,255,0)); strip.paste(im,(x,20)); x+=cw+10
strip.save('/tmp/eo_seq.png'); print(strip.size)
