#!/usr/bin/env python3
import glob, os
from PIL import Image
import numpy as np

frames = sorted(glob.glob('/tmp/live_*.png'), key=lambda p: int(p.split('_')[1].split('.')[0]))
print("frames:", len(frames))

# montage: tile downscaled frames in a grid
thumbs = []
metric = []
for f in frames:
    im = Image.open(f).convert('RGB')
    arr = np.asarray(im).astype(np.float32)
    h, w, _ = arr.shape
    # darkness fraction (black bands): pixels with luma < 20
    luma = arr.mean(axis=2)
    dark_frac = float((luma < 16).mean())
    # vertical doubling proxy: does bottom portion repeat top? compare each row to row+h/2
    half = h // 2
    a = luma[:half]
    b = luma[half:half+half]
    diff = float(np.abs(a - b).mean())
    metric.append((int(f.split('_')[1].split('.')[0]), dark_frac, diff))
    t = im.resize((192, 108))
    thumbs.append((os.path.basename(f), t))

print("frame  dark_frac  tophalf_vs_bottomhalf_diff")
for n, d, di in metric:
    flag = "  <== DARK" if d > 0.02 else ""
    print(f"{n:5d}  {d:.4f}     {di:7.2f}{flag}")

# worst dark frame
worst = max(metric, key=lambda x: x[1])
print("\nWORST DARK FRAME:", worst)

# build montage 6 cols
cols = 6
rows = (len(thumbs) + cols - 1) // cols
tw, th = 192, 108
canvas = Image.new('RGB', (cols*tw, rows*th), (40,40,40))
from PIL import ImageDraw
d = ImageDraw.Draw(canvas)
for i,(name,t) in enumerate(thumbs):
    x = (i % cols) * tw; y = (i // cols) * th
    canvas.paste(t, (x, y))
    d.text((x+2, y+2), name.replace('live_','').replace('.png',''), fill=(255,255,0))
canvas.save('/tmp/montage_sd.png')
print("saved /tmp/montage_sd.png", canvas.size)
