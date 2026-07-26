#!/usr/bin/env python3
"""
增量补特效:壁纸 3742071135(Girl | Dark Background)的两个渲染缺口。
  1) workshop/3168465326/color_grading__extension  combo {GAMMA:1}(+ base)  —— 新 key
  2) workshop/3021673417/Simple_Audio_Bars  追加 SHAPE=7 变体
     {ANTIALIAS:1,CLIP_HIGH:1,RESOLUTION:64,SHAPE:7}                          —— 在现有 key 末尾追加

⚠ 绝不全量 regen(we_build_effects.main 会重建全部 130 key,可能把 2846660316 转坏)。
本脚本只 build 这两个目标的指定变体,**就地合并**进现有 manifest:
  - color_grading__extension:新增 1 个 key(base + GAMMA-1 两变体)
  - Simple_Audio_Bars:在现有 key 的 variants 末尾追加缺失的 SHAPE=7 变体(已存在则跳过)
其余 key 逐字节不动。
"""
import os, sys, json

HERE = os.path.dirname(os.path.abspath(__file__))   # 本 worktree 的 tools/(含已打补丁的 we_transpile)
sys.path.insert(0, HERE)
import we_build_effects as B   # 这会 import 同目录的 we_transpile(带 isLeftChannel/isRightChannel 修)

OUT = os.path.join(HERE, "generated")
MANIFEST = os.path.join(OUT, "WEEffects.json")
PKG = os.path.expanduser("~/Library/Application Support/CrossOver/Bottles/Steam/drive_c/Program Files (x86)/Steam/steamapps/workshop/content/431960/3742071135/scene.pkg")

# 让 build 输出的 .metal 落到本 worktree 的 generated/we_effects/(B.MSL_DIR 已指向同目录)
assert B.OUT == OUT, f"OUT 不一致: {B.OUT} != {OUT}"
os.makedirs(B.MSL_DIR, exist_ok=True)

manifest = json.load(open(MANIFEST, encoding="utf-8"))
before_keys = set(manifest.keys())

def build_variant(eff_key, combos):
    ck = B.combo_key(combos)
    rec, err, misses = B.build_workshop_effect(eff_key, PKG, combos, ck)
    for (pi, sb, st) in misses:
        print(f"  MISS {eff_key}/{ck}: pass {pi} {sb}.{st} 缺 shader", file=sys.stderr)
    if rec and rec["passes"] and any(pp.get("frag") for pp in rec["passes"]):
        return {"combos": combos, "passes": rec["passes"]}, None
    return None, (err or "no frag")

# ---------- 1) color_grading__extension:新 key,base + GAMMA=1 ----------
CG_KEY = "workshop/3168465326/color_grading__extension"
cg_variants = []
for combos in ([{}, {"GAMMA": "1"}]):
    v, err = build_variant(CG_KEY, combos)
    if v:
        cg_variants.append(v); print(f"[OK] {CG_KEY} {B.combo_key(combos)}")
    else:
        print(f"[FAIL] {CG_KEY} {B.combo_key(combos)}: {err}", file=sys.stderr)
if not cg_variants:
    print("ERROR: color_grading__extension 全部变体失败", file=sys.stderr); sys.exit(2)
if CG_KEY in manifest:
    print(f"WARN: {CG_KEY} 已存在,覆盖其 variants", file=sys.stderr)
manifest[CG_KEY] = {"variants": cg_variants}

# ---------- 2) Simple_Audio_Bars:追加 SHAPE=7 变体(不动已有) ----------
SAB_KEY = "workshop/3021673417/Simple_Audio_Bars"
sab_combos = {"ANTIALIAS": "1", "CLIP_HIGH": "1", "RESOLUTION": "64", "SHAPE": "7"}

def combos_equal(a, b):
    return {k: str(v) for k, v in a.items()} == {k: str(v) for k, v in b.items()}

existing = manifest.get(SAB_KEY, {}).get("variants", [])
already = any(combos_equal(v.get("combos", {}), sab_combos) for v in existing)
if already:
    print(f"[SKIP] {SAB_KEY} SHAPE=7 变体已存在")
else:
    v, err = build_variant(SAB_KEY, sab_combos)
    if not v:
        print(f"ERROR: {SAB_KEY} SHAPE=7 变体失败: {err}", file=sys.stderr); sys.exit(3)
    if SAB_KEY not in manifest:
        manifest[SAB_KEY] = {"variants": []}
    manifest[SAB_KEY]["variants"].append(v)
    print(f"[OK] {SAB_KEY} 追加 {B.combo_key(sab_combos)} (现 {len(manifest[SAB_KEY]['variants'])} 变体)")

after_keys = set(manifest.keys())
print("新增 key:", sorted(after_keys - before_keys))
print("修改 key(variants 追加):", SAB_KEY if not already else "(无)")

json.dump(manifest, open(MANIFEST, "w", encoding="utf-8"), indent=1, ensure_ascii=False)
print("manifest 已写回:", MANIFEST)
