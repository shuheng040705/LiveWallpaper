from PIL import Image, ImageDraw
box=(720,160,940,280)
frames=[0,3,6,9,12,15,18,24]
s=4; bw=(box[2]-box[0])*s; bh=(box[3]-box[1])*s
cols=4; rows=2
strip=Image.new('RGB',((bw+8)*cols, (bh+18)*rows),(40,40,40)); d=ImageDraw.Draw(strip)
for i,w in enumerate(frames):
    im=Image.open('/tmp/blink_w%d.png'%w).convert('RGB').crop(box).resize((bw,bh),Image.NEAREST)
    cx=(i%cols)*(bw+8); cy=(i//cols)*(bh+18)
    d.text((cx+4,cy+3),"f=%d (%.2fs)"%(w,w/30),fill=(255,255,0)); strip.paste(im,(cx,cy+18))
strip.save('/tmp/blink_seq.png'); print(strip.size)
