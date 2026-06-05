#!/usr/bin/env python3
"""A/B 全库回归对比(A=lwe per-Image FBO 合成管线移植)。
用法:
  python3 Tools/ab_regress.py base      # 旧管线(默认)→ /tmp/abreg/<id>_base.png
  python3 Tools/ab_regress.py new       # 新管线(WP_LWE_COMPOSITE=1)→ <id>_new.png
  python3 Tools/ab_regress.py compare   # 逐张 base vs new 像素 diff 汇总表
本项目无单测,render-A/B 是既定回归手段。每张渲 1 帧(warmup 后)、longSide 1000。
"""
import os, sys, subprocess, json, glob
sys.path.insert(0, os.path.join(os.path.dirname(__file__)))
# texfmt.py 有模块级 CLI 代码(读 sys.argv[1] 当壁纸 id),import 时会拿到本脚本的参数而崩;
# import 前先把 argv 清空(让它取默认 wid),import 后还原。
_saved_argv = sys.argv
sys.argv = [sys.argv[0]]
from texfmt import rd
sys.argv = _saved_argv

ROOT = "/Users/a55555/Library/Application Support/CrossOver/Bottles/Steam/drive_c/Program Files (x86)/Steam/steamapps/workshop/content/431960"
BIN = "/Users/a55555/Developer/LiveWallpaper/LiveWallpaper.app/Contents/MacOS/LiveWallpaper"
OUT = "/tmp/abreg"
FRAMES, LONG = "12", "1000"

def scene_ids():
    ids = []
    for d in sorted(os.listdir(ROOT)):
        pkg = os.path.join(ROOT, d, "scene.pkg")
        if not os.path.isfile(pkg):
            continue
        try:
            files = rd(pkg)
            if "scene.json" in files:
                ids.append(d)
        except Exception:
            pass
    return ids

def render(mode):
    os.makedirs(OUT, exist_ok=True)
    ids = scene_ids()
    env = dict(os.environ)
    # 默认已是新(lwe)管线;base 用逃生开关退回旧 compositeSceneBelow 路径,new 走默认。
    if mode == "base":
        env["WP_NO_LWE_COMPOSITE"] = "1"
    print(f"[{mode}] 渲染 {len(ids)} 张 scene 壁纸 …")
    ok = 0
    for i, wid in enumerate(ids):
        out = f"{OUT}/{wid}_{mode}.png"
        try:
            r = subprocess.run([BIN, "--warmrender", wid, out, FRAMES, LONG],
                               env=env, capture_output=True, text=True, timeout=120)
            if os.path.isfile(out):
                ok += 1
            else:
                print(f"  [{i+1}/{len(ids)}] {wid}: 无输出  {r.stdout.strip()[-80:]} {r.stderr.strip()[-80:]}")
        except Exception as e:
            print(f"  [{i+1}/{len(ids)}] {wid}: 异常 {e}")
    print(f"[{mode}] 成功 {ok}/{len(ids)} → {OUT}/*_{mode}.png")

def compare():
    from PIL import Image
    import numpy as np
    rows = []
    for base in sorted(glob.glob(f"{OUT}/*_base.png")):
        wid = os.path.basename(base)[:-len("_base.png")]
        new = f"{OUT}/{wid}_new.png"
        if not os.path.isfile(new):
            rows.append((wid, "NO_NEW", 0, 0)); continue
        a = np.asarray(Image.open(base).convert("RGB")).astype(float)
        b = np.asarray(Image.open(new).convert("RGB")).astype(float)
        if a.shape != b.shape:
            rows.append((wid, f"SHAPE {a.shape}!={b.shape}", 0, 0)); continue
        d = np.abs(a - b)
        rows.append((wid, "", round(float(d.mean()), 3), round(float((d.sum(2) > 8).mean() * 100), 2)))
    rows.sort(key=lambda r: -r[2] if isinstance(r[2], (int, float)) else 0)
    print(f"{'id':>12} {'meanDiff':>9} {'nonzero%':>9}  note")
    nonzero = 0
    for wid, note, md, nz in rows:
        flag = "  ← 变化" if isinstance(md, (int, float)) and md > 0.5 else ""
        if isinstance(md, (int, float)) and md > 0.5:
            nonzero += 1
        print(f"{wid:>12} {md:>9} {nz:>9}  {note}{flag}")
    print(f"\n共 {len(rows)} 张,meanDiff>0.5 的 {nonzero} 张(需逐张确认是改善而非回归)。")

if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else "base"
    if mode == "compare":
        compare()
    else:
        render(mode)
