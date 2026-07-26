#!/usr/bin/env python3
"""
增量补特效:珂莱塔 3749242222 的 nitro 特效 BLENDMODE=31 变体缺口。

Clock 图层用 workshop/3373145169/nitro 且 combos={BLENDMODE:31};
该 workshop nitro 是内置 effects/nitro 的逐字节副本(仅注释 JSON key 顺序不同),
manifest 里以**裸名** key `nitro` 命中(引擎 resolvedKey 按 basename 兜底:
workshop/3373145169/nitro → nitro)。现有 `nitro` key 有 2 变体 {} / {MASK:1},
combo 系统活跃,但无 BLENDMODE=31 变体 → 回退默认变体(渲染模式未转译)。

本脚本**只 build 内置 effects/nitro 的 {BLENDMODE:31} 这一个变体**,就地追加进现有
`nitro` key 的 variants 末尾(已存在则跳过)。其余 key / 变体逐字节不动。

⚠ 绝不全量 regen(manifest-regen-hazard:会把别的特效如 2846660316 转坏)。
"""
import os, sys, json

HERE = os.path.dirname(os.path.abspath(__file__))   # tools/
sys.path.insert(0, HERE)
import we_build_effects as B   # 同目录 we_transpile

OUT = os.path.join(HERE, "generated")
MANIFEST = os.path.join(OUT, "WEEffects.json")

assert B.OUT == OUT, f"OUT 不一致: {B.OUT} != {OUT}"
os.makedirs(B.MSL_DIR, exist_ok=True)

manifest = json.load(open(MANIFEST, encoding="utf-8"))
before = json.dumps(manifest.get("nitro"), sort_keys=True)


def combos_equal(a, b):
    return {k: str(v) for k, v in a.items()} == {k: str(v) for k, v in b.items()}


def build_builtin_variant(name, combos):
    ck = B.combo_key(combos)
    rec, err, misses = B.build_effect(name, combos, ck)
    for (pi, sb, st) in misses:
        print(f"  MISS {name}/{ck}: pass {pi} {sb}.{st} 缺 shader", file=sys.stderr)
    if rec and rec["passes"] and any(pp.get("frag") for pp in rec["passes"]):
        return {"combos": {k: str(v) for k, v in combos.items()}, "passes": rec["passes"]}, None
    return None, (err or "no frag")


def append_builtin_variant(name, combos):
    existing = manifest.get(name, {}).get("variants", [])
    if any(combos_equal(v.get("combos", {}), combos) for v in existing):
        print(f"[SKIP] {name} {B.combo_key(combos)} 变体已存在")
        return
    v, err = build_builtin_variant(name, combos)
    if not v:
        print(f"ERROR: {name} {B.combo_key(combos)} 变体失败: {err}", file=sys.stderr)
        sys.exit(3)
    if name not in manifest:
        print(f"ERROR: {name} 不存在于 manifest(本应已有裸名 key)", file=sys.stderr)
        sys.exit(4)
    manifest[name]["variants"].append(v)
    print(f"[OK] {name} 追加 {B.combo_key(combos)} (现 {len(manifest[name]['variants'])} 变体)")


# 珂莱塔 nitro:追加 BLENDMODE=31(Clock 实际组合)
append_builtin_variant("nitro", {"BLENDMODE": "31"})

after = json.dumps(manifest.get("nitro"), sort_keys=True)
print("nitro 变化:" , "yes" if after != before else "no")

json.dump(manifest, open(MANIFEST, "w", encoding="utf-8"), indent=1, ensure_ascii=False)
print("manifest 已写回:", MANIFEST)
