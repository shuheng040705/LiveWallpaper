#!/usr/bin/env python3
"""Manifest A/B 回归:同一 binary,6-3 manifest vs 重生成 manifest,逐张像素对比。
用法:
  python3 tools/manifest_regress.py render <suffix>   # 用当前 .app 渲全库 → /tmp/abreg/<id>_<suffix>.png
  python3 tools/manifest_regress.py compare <a> <b>    # 逐张 <id>_<a> vs <id>_<b> diff 汇总
渲染用 WP_TEST_BANDS=loud(音频特效确定性最大化暴露差异)。
"""
import os, sys, subprocess, glob
sys.path.insert(0, os.path.dirname(__file__))
_a = sys.argv; sys.argv = [sys.argv[0]]
from texfmt import rd
sys.argv = _a

ROOT = "/Users/a55555/Library/Application Support/CrossOver/Bottles/Steam/drive_c/Program Files (x86)/Steam/steamapps/workshop/content/431960"
BIN = "/Users/a55555/Developer/LiveWallpaper/LiveWallpaper.app/Contents/MacOS/LiveWallpaper"
OUT = "/tmp/abreg"
FRAMES, LONG = "12", "1000"

def scene_ids():
    ids = []
    for d in sorted(os.listdir(ROOT)):
        p = os.path.join(ROOT, d, "scene.pkg")
        if not os.path.isfile(p):
            continue
        try:
            f = rd(p)
            if "scene.json" in f:
                ids.append(d)
        except Exception:
            pass
    return ids

def render(suffix):
    os.makedirs(OUT, exist_ok=True)
    ids = scene_ids()
    env = dict(os.environ); env["WP_TEST_BANDS"] = "loud"
    print(f"[{suffix}] 渲染 {len(ids)} 张 …")
    ok = 0
    for i, wid in enumerate(ids):
        out = f"{OUT}/{wid}_{suffix}.png"
        try:
            subprocess.run([BIN, "--warmrender", wid, out, FRAMES, LONG],
                           env=env, capture_output=True, text=True, timeout=180)
            if os.path.isfile(out):
                ok += 1
            else:
                print(f"  [{i+1}/{len(ids)}] {wid}: 无输出")
        except Exception as e:
            print(f"  [{i+1}/{len(ids)}] {wid}: 异常 {e}")
    print(f"[{suffix}] 成功 {ok}/{len(ids)}")

def compare(sa, sb):
    from PIL import Image
    import numpy as np
    rows = []
    for pa in sorted(glob.glob(f"{OUT}/*_{sa}.png")):
        wid = os.path.basename(pa)[:-len(f"_{sa}.png")]
        pb = f"{OUT}/{wid}_{sb}.png"
        if not os.path.isfile(pb):
            rows.append((wid, "NO_B", 0, 0)); continue
        a = np.asarray(Image.open(pa).convert("RGB")).astype(float)
        b = np.asarray(Image.open(pb).convert("RGB")).astype(float)
        if a.shape != b.shape:
            rows.append((wid, f"SHAPE {a.shape}!={b.shape}", -1, -1)); continue
        d = np.abs(a - b)
        rows.append((wid, "", round(float(d.mean()), 3), round(float((d.sum(2) > 8).mean() * 100), 2)))
    rows.sort(key=lambda r: -r[2] if isinstance(r[2], (int, float)) else 0)
    print(f"{'id':>12} {'meanDiff':>9} {'nonzero%':>9}  note")
    changed = 0
    for wid, note, md, nz in rows:
        flag = "  <- CHANGED" if isinstance(md, (int, float)) and md > 0.5 else ""
        if isinstance(md, (int, float)) and md > 0.5:
            changed += 1
        print(f"{wid:>12} {md:>9} {nz:>9}  {note}{flag}")
    print(f"\n{len(rows)} total; {changed} with meanDiff>0.5 (verify each is improvement not regression).")

if __name__ == "__main__":
    if sys.argv[1] == "render":
        render(sys.argv[2])
    elif sys.argv[1] == "compare":
        compare(sys.argv[2], sys.argv[3])
