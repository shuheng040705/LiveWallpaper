#!/usr/bin/env python3
"""
WE 真值 A/B 对比 —— 逆向 fog/fade 高光柔化。
读 Parallels 共享文件夹里的真 WE 截图,渲染我方同尺寸版本,逐像素 diff + 头/天空区亮度·clip 对比。

用法:
  python3 tools/we_ab.py                 # 自动读 ~/Downloads/we_ref/ 里最新 png 当真值
  python3 tools/we_ab.py <we截图路径>      # 指定真值
  python3 tools/we_ab.py <we截图> <frames> # 指定我方渲染预热帧(默认90)
环境变量(传给我方引擎渲染,做 A/B 隔离用):如 WP_NO_LIGHTSHAFTS=1 python3 tools/we_ab.py
输出:/tmp/ab_side.png(并排)/tmp/ab_diff.png(diff热图) + 终端打印分区亮度/clip 对比。
"""
import sys, os, glob, subprocess
import numpy as np
from PIL import Image, ImageChops

WID = os.environ.get("WP_AB_WID", "3497488774")   # WP_AB_WID=3743162382 切到流萤×知更鸟×星
APP = "/Applications/LiveWallpaper.app/Contents/MacOS/LiveWallpaper"
REFDIR = "/Users/a55555/Downloads/we_ref"
# 分区(图像分数坐标,任意分辨率通用):按壁纸给脸/阴影区。看到真值后可再精调。
REGIONS_BY_WID = {
    "3497488774": {            # 白影轻扬
        "全图": (0.0, 0.0, 1.0, 1.0),
        "头部":  (0.42, 0.08, 0.54, 0.42),
        "头后天空": (0.40, 0.05, 0.52, 0.20),
    },
    "3743162382": {            # 流萤×知更鸟×星(逆向刘海阴影):三角色脸
        "全图": (0.0, 0.0, 1.0, 1.0),
        "星脸(左)":   (0.20, 0.06, 0.40, 0.40),
        "知更鸟脸(中)": (0.42, 0.05, 0.60, 0.38),
        "流萤脸(右)":  (0.66, 0.18, 0.86, 0.52),
    },
}
REGIONS = REGIONS_BY_WID.get(WID, {"全图": (0.0, 0.0, 1.0, 1.0)})


def stats(arr, box):
    H, W = arr.shape[:2]
    x0, y0, x1, y1 = box
    c = arr[int(y0 * H):int(y1 * H), int(x0 * W):int(x1 * W)]
    if c.size == 0:
        return None
    l = c.mean(2)
    return (l.mean(), 100 * (l > 250).mean(), 100 * (c.min(2) >= 254).mean())


def main():
    args = [a for a in sys.argv[1:]]
    ref_path = None
    frames = 90
    if args and os.path.exists(args[0]):
        ref_path = args[0]; args = args[1:]
    if args and args[0].isdigit():
        frames = int(args[0])
    if ref_path is None:
        pngs = sorted(glob.glob(os.path.join(REFDIR, "*.png")) + glob.glob(os.path.join(REFDIR, "*.jpg")),
                      key=os.path.getmtime)
        if not pngs:
            print(f"❌ {REFDIR} 里没有截图。把 WE 截图放进去再跑。"); return
        ref_path = pngs[-1]
    print(f"WE 真值: {ref_path}")
    we = Image.open(ref_path).convert("RGB")
    W, H = we.size
    print(f"真值尺寸: {W}×{H}  (我方按此宽渲染)")

    # 我方渲染(同宽;按画布 16:9 出图,后面 resize 到真值精确尺寸对齐)
    out = "/tmp/ab_mine.png"
    env = dict(os.environ)
    r = subprocess.run([APP, "--warmrender", WID, out, str(frames), str(W)],
                       capture_output=True, text=True, env=env)
    if not os.path.exists(out):
        print("❌ 渲染失败:", r.stderr[-300:]); return
    mine = Image.open(out).convert("RGB")
    if mine.size != (W, H):
        print(f"⚠ 我方渲染 {mine.size} ≠ 真值 {(W,H)}(画布/显示比例不同),resize 对齐")
        mine = mine.resize((W, H))

    wa, ma = np.asarray(we), np.asarray(mine)
    # diff 热图
    d = np.asarray(ImageChops.difference(we, mine)).sum(2)
    print(f"\n逐像素 diff: mean={d.mean():.1f} max={d.max()} 显著差(>40)占 {100*(d>40).mean():.1f}%")
    Image.fromarray((np.clip(d, 0, 255)).astype("uint8")).save("/tmp/ab_diff.png")

    print(f"\n{'区域':<10}{'WE mean/clip/纯白':<28}{'我方 mean/clip/纯白':<28}{'Δmean'}")
    for nm, box in REGIONS.items():
        ws, ms = stats(wa, box), stats(ma, box)
        if ws and ms:
            print(f"{nm:<10}{f'{ws[0]:.0f} / {ws[1]:.1f}% / {ws[2]:.1f}%':<28}"
                  f"{f'{ms[0]:.0f} / {ms[1]:.1f}% / {ms[2]:.1f}%':<28}{ms[0]-ws[0]:+.0f}")

    # 并排
    side = Image.new("RGB", (W * 2 + 20, H), (30, 30, 30))
    side.paste(we, (0, 0)); side.paste(mine, (W + 20, 0))
    side.save("/tmp/ab_side.png")
    print("\n并排=/tmp/ab_side.png(左WE/右我方)  diff热图=/tmp/ab_diff.png  我方渲染=/tmp/ab_mine.png")
    print("目标:把『我方』各区 mean/clip 调到接近 WE(尤其头部/头后天空的 clip→0)。")


if __name__ == "__main__":
    main()
