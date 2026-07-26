#!/usr/bin/env python3
"""
增量补特效:壁纸 3521337568(Cyberpunk: Edgerunner-Lucy[4K])的 shine 渲染缺口。

  内置 effect `shine`(scene 用 effects/shine,5-pass:downsample2→cast→gaussian_x→gaussian_y→combine)
  图层「Lucy」的 cast pass(pass 1)scene combos = {EDGES:3, SAMPLES:2},但 manifest 现有 9 个 shine 变体
  cast 均为 EDGES=4(默认)/SAMPLES≤3,无 EDGES=3 → 运行时退回不对的变体(cast=EDGES-4_SAMPLES-1)→
  光晕边数(EDGES)与采样质量(SAMPLES)都不对。

  ⚠ 实测运行时整 effect 的请求 combos = {EDGES:3, SAMPLES:2, MASK:1, VERTICAL:1}:
    - MASK:1 由 pass0(downsample2)textures 槽 'masks/shine_downsample2_mask_*' 隐式派生(SceneModel maskPath)
    - VERTICAL:1 由 pass3(gaussian_y)的 material 自带,且各变体 build 期已逐 pass 烘进
  selectVariant 选「请求子集且命中最多」者。若只追加 {EDGES:3,SAMPLES:2}(2 命中),会与现有
  {MASK:1,VERTICAL:1}(同 2 命中)打平、且 MASK 变体在前先被选中 → cast 仍退回 EDGES-4_SAMPLES-1(没生效)。
  故追加 {EDGES:3, SAMPLES:2, MASK:1}(3 命中)唯一胜出 → cast = EDGES-3_MASK-1_SAMPLES-2。
  (cast shader 不含 #if MASK,带 MASK 仅影响文件名不改 cast 内容;真正消费 MASK 的是 downsample2)

⚠ 绝不全量 regen(we_build_effects.main 会重建全部 131 key,潜在回归可能把 2846660316 转坏=整屏 Esperanta 噪点)。
本脚本只 build「shine」的 EDGES-3_SAMPLES-2 一个变体,**就地合并**进现有 manifest 的 shine key 末尾(已存在则跳过)。
其余 key(含 2846660316)逐字节不动。

内置 shine 的 effect-dir shader 与 pkg 副本逐字节一致(已校验 8 个 stage 全 SAME),
故用 build_effect(读 $WE/effects/shine)= 用 pkg 副本 build,结果等价。
"""
import os, sys, json

HERE = os.path.dirname(os.path.abspath(__file__))   # 本 worktree 的 tools/(含已打补丁的 we_transpile)
sys.path.insert(0, HERE)
import we_build_effects as B   # 这会 import 同目录的 we_transpile

OUT = os.path.join(HERE, "generated")
MANIFEST = os.path.join(OUT, "WEEffects.json")

assert B.OUT == OUT, f"OUT 不一致: {B.OUT} != {OUT}"
os.makedirs(B.MSL_DIR, exist_ok=True)

manifest = json.load(open(MANIFEST, encoding="utf-8"))
before_keys = set(manifest.keys())

SHINE_KEY = "shine"
combos = {"EDGES": "3", "SAMPLES": "2", "MASK": "1"}
ck = B.combo_key(combos)   # "EDGES-3_MASK-1_SAMPLES-2"


def combos_equal(a, b):
    return {k: str(v) for k, v in a.items()} == {k: str(v) for k, v in b.items()}


if SHINE_KEY not in manifest:
    print(f"ERROR: manifest 无内置 key '{SHINE_KEY}'", file=sys.stderr)
    sys.exit(2)

existing = manifest[SHINE_KEY].get("variants", [])
already = any(combos_equal(v.get("combos", {}), combos) for v in existing)
if already:
    print(f"[SKIP] {SHINE_KEY} {ck} 变体已存在(共 {len(existing)} 变体)")
    sys.exit(0)

rec, err, misses = B.build_effect(SHINE_KEY, combos, ck)
for (pi, sb, st) in misses:
    print(f"  MISS {SHINE_KEY}/{ck}: pass {pi} {sb}.{st} 缺 shader", file=sys.stderr)
if not (rec and rec["passes"] and any(pp.get("frag") for pp in rec["passes"])):
    print(f"ERROR: {SHINE_KEY} {ck} build 失败: {err or 'no frag'}", file=sys.stderr)
    sys.exit(3)

manifest[SHINE_KEY]["variants"].append({"combos": combos, "passes": rec["passes"]})
print(f"[OK] {SHINE_KEY} 追加 {ck} (现 {len(manifest[SHINE_KEY]['variants'])} 变体)")
for pi, p in enumerate(rec["passes"]):
    print(f"   pass{pi} shader={p.get('shader')} "
          f"frag={p.get('frag', {}).get('metal')} vert={p.get('vert', {}).get('metal')}")

after_keys = set(manifest.keys())
print("新增 key:", sorted(after_keys - before_keys) or "(无,只追加变体)")
print("修改 key(variants 追加):", SHINE_KEY)

json.dump(manifest, open(MANIFEST, "w", encoding="utf-8"), indent=1, ensure_ascii=False)
print("manifest 已写回:", MANIFEST)
