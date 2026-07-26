#!/usr/bin/env python3
"""
增量补特效:珂莱塔 3749242222 + 电锯人玛奇玛 3725148661 的 4 个渲染缺口。

  珂莱塔 3749242222:
    1) workshop/3373145169/psyhue   新 key,base + {AUDIOPROCESSING:3}    (图层 Clock/Seconds/Week/Date)
    2) workshop/3685680567/heart    新 key,base                          (图层 Heart 1)
    3) xray  追加 {BLENDMODE:30} 变体(不动已有 {} / {MASK:1})           (图层 00039-3908269513)
  电锯人玛奇玛 3725148661:
    4) blur  追加 {KERNEL:2, VERTICAL:1} 变体(不动已有 8 变体)          (图层 影子)

⚠ 绝不全量 regen(we_build_effects.main 会重建全部 key,可能把 2846660316 转坏)。
本脚本只 build 这 4 个目标的指定变体,**就地合并**进现有 manifest:
  - psyhue / heart:各新增 1 个 key
  - xray / blur:在现有 key 的 variants 末尾追加缺失变体(已存在则跳过)
其余 key 逐字节不动。
"""
import os, sys, json

HERE = os.path.dirname(os.path.abspath(__file__))   # tools/
sys.path.insert(0, HERE)
import we_build_effects as B   # 同目录 we_transpile

OUT = os.path.join(HERE, "generated")
MANIFEST = os.path.join(OUT, "WEEffects.json")
KOLETA = os.path.expanduser("~/Library/Application Support/CrossOver/Bottles/Steam/drive_c/Program Files (x86)/Steam/steamapps/workshop/content/431960/3749242222/scene.pkg")
MAKIMA = os.path.expanduser("~/Library/Application Support/CrossOver/Bottles/Steam/drive_c/Program Files (x86)/Steam/steamapps/workshop/content/431960/3725148661/scene.pkg")

assert B.OUT == OUT, f"OUT 不一致: {B.OUT} != {OUT}"
assert os.path.exists(KOLETA), f"missing pkg {KOLETA}"
assert os.path.exists(MAKIMA), f"missing pkg {MAKIMA}"
os.makedirs(B.MSL_DIR, exist_ok=True)

manifest = json.load(open(MANIFEST, encoding="utf-8"))
before_keys = set(manifest.keys())
before_xray = json.dumps(manifest.get("xray"), sort_keys=True)
before_blur = json.dumps(manifest.get("blur"), sort_keys=True)


def combos_equal(a, b):
    return {k: str(v) for k, v in a.items()} == {k: str(v) for k, v in b.items()}


def build_workshop_variant(eff_key, pkg, combos, force_slots=None):
    ck = B.combo_key(combos)
    rec, err, misses = B.build_workshop_effect(eff_key, pkg, combos, ck, force_slots=force_slots)
    for (pi, sb, st) in misses:
        print(f"  MISS {eff_key}/{ck}: pass {pi} {sb}.{st} 缺 shader", file=sys.stderr)
    if rec and rec["passes"] and any(pp.get("frag") for pp in rec["passes"]):
        return {"combos": combos, "passes": rec["passes"]}, None
    return None, (err or "no frag")


def build_builtin_variant(name, combos):
    ck = B.combo_key(combos)
    rec, err, misses = B.build_effect(name, combos, ck)
    for (pi, sb, st) in misses:
        print(f"  MISS {name}/{ck}: pass {pi} {sb}.{st} 缺 shader", file=sys.stderr)
    if rec and rec["passes"] and any(pp.get("frag") for pp in rec["passes"]):
        return {"combos": {k: str(v) for k, v in combos.items()}, "passes": rec["passes"]}, None
    return None, (err or "no frag")


def add_new_workshop_key(eff_key, pkg, variants_in):
    """新 key:转译 variants_in(每个是 combos dict),写整条 {variants:[...]}。"""
    force_slots = B.scene_bound_slots_for(eff_key, pkg)
    built = []
    for combos in variants_in:
        v, err = build_workshop_variant(eff_key, pkg, combos, force_slots=force_slots)
        if v:
            built.append(v); print(f"[OK] {eff_key} {B.combo_key(combos)}")
        else:
            print(f"[FAIL] {eff_key} {B.combo_key(combos)}: {err}", file=sys.stderr)
    if not built:
        print(f"ERROR: {eff_key} 全部变体失败", file=sys.stderr); sys.exit(2)
    if eff_key in manifest:
        print(f"WARN: {eff_key} 已存在,覆盖其 variants", file=sys.stderr)
    manifest[eff_key] = {"variants": built}


def append_builtin_variant(name, combos):
    """内置 effect:在现有 key 末尾追加缺失变体(已存在则跳过)。"""
    existing = manifest.get(name, {}).get("variants", [])
    if any(combos_equal(v.get("combos", {}), combos) for v in existing):
        print(f"[SKIP] {name} {B.combo_key(combos)} 变体已存在")
        return
    v, err = build_builtin_variant(name, combos)
    if not v:
        print(f"ERROR: {name} {B.combo_key(combos)} 变体失败: {err}", file=sys.stderr); sys.exit(3)
    if name not in manifest:
        manifest[name] = {"variants": []}
    manifest[name]["variants"].append(v)
    print(f"[OK] {name} 追加 {B.combo_key(combos)} (现 {len(manifest[name]['variants'])} 变体)")


# ---------- 珂莱塔 ----------
# 1) psyhue:Clock 等用 {AUDIOPROCESSING:3};base + 该变体
add_new_workshop_key("workshop/3373145169/psyhue", KOLETA, [{}, {"AUDIOPROCESSING": "3"}])
# 2) heart:Heart 1 用 base
add_new_workshop_key("workshop/3685680567/heart", KOLETA, [{}])
# 3) xray:追加 BLENDMODE=30(scene 实际组合)
append_builtin_variant("xray", {"BLENDMODE": "30"})

# ---------- 玛奇玛 ----------
# 4) blur:追加 KERNEL=2,VERTICAL=1(影子 实际组合)
append_builtin_variant("blur", {"KERNEL": "2", "VERTICAL": "1"})

after_keys = set(manifest.keys())
print("\n新增 key:", sorted(after_keys - before_keys))
print("修改 key(variants 追加):",
      [k for k, b in (("xray", before_xray), ("blur", before_blur))
       if json.dumps(manifest.get(k), sort_keys=True) != b])

json.dump(manifest, open(MANIFEST, "w", encoding="utf-8"), indent=1, ensure_ascii=False)
print("manifest 已写回:", MANIFEST, f"({len(before_keys)} → {len(after_keys)} keys)")
