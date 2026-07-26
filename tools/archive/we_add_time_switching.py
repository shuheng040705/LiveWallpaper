#!/usr/bin/env python3
"""安全增量:把白影轻扬(3497488774)pkg 内的 time_switching 时段 LUT 调色 effect 转译进 manifest。

⚠ 不全量 regen(2846660316 噪点雷区,见记忆 manifest-regen-hazard)。
做法:用 we_build_effects 的 build_workshop_effect 只建 time_switching 这一个 key(combos 走
shader [COMBO] 默认:CLAMP=1,QUAD_SIZE=16,BLENDMODE=0,TBLENDMODE=0,LUT_FLIP_Y=0),
读现有 WEEffects.json,**仅追加/更新** key='time_switching',原样回写其余 128 个 key。

用法:python3 tools/we_add_time_switching.py
"""
import os, sys, json, glob
sys.path.insert(0, os.path.dirname(__file__))
import we_build_effects as B

WID = "3497488774"
EFF_KEY = "time_switching"
MANIFEST = os.path.join(B.OUT, "WEEffects.json")

def main():
    os.makedirs(B.MSL_DIR, exist_ok=True)
    pkg = os.path.join(B.WORKSHOP, WID, "scene.pkg")
    if not os.path.exists(pkg):
        # 退回到任意含该 effect 的 pkg
        cands = []
        for p in sorted(glob.glob(os.path.join(B.WORKSHOP, "*", "scene.pkg"))):
            fs = B.pkg_files(p)
            if fs and f"effects/{EFF_KEY}/effect.json" in fs:
                cands.append(p)
        if not cands:
            print("FATAL: time_switching effect.json 不在任何 pkg")
            return 1
        pkg = cands[0]
    files = B.pkg_files(pkg)
    if not files or f"effects/{EFF_KEY}/effect.json" not in files:
        print(f"FATAL: {pkg} 内无 effects/{EFF_KEY}/effect.json")
        return 1

    # scene pass 无 combos → 只建 base 变体(shader [COMBO] 默认会被 build_effect_passes 烘入)。
    variants_in = [{}]
    built = []
    fails = []
    for combos in variants_in:
        ck = B.combo_key(combos)
        try:
            # force_slots:LUT 槽 1..4 由 scene 绑(textures=[null,清晨,original,日落,夜晚]),
            # 显式传以确保 sampler 不被任何 gate 掉(本 shader 无 gate,稳妥起见仍传)。
            rec, err, misses = B.build_workshop_effect(EFF_KEY, pkg, combos, ck, force_slots={1, 2, 3, 4})
            for (pi, sb, st) in misses:
                fails.append(f"pass {pi} {sb}.{st} 缺 shader 文件")
            if rec and rec["passes"] and any(pp.get("frag") for pp in rec["passes"]):
                built.append({"combos": combos, "passes": rec["passes"]})
            else:
                fails.append(err or "no frag")
        except Exception as e:
            fails.append(str(e)[:300])

    if not built:
        print("FATAL: time_switching 转译失败:", fails)
        return 1

    # 读现有 manifest,仅更新本 key,原样保留其余(安全增量)。
    man = json.load(open(MANIFEST, encoding="utf-8"))
    before = len(man)
    man[EFF_KEY] = {"variants": built}
    # 稳定写回(同 we_build_effects 的 indent=1, ensure_ascii=False)
    json.dump(man, open(MANIFEST, "w"), indent=1, ensure_ascii=False)
    after = len(man)
    print(f"OK: time_switching 已并入 manifest（{before}→{after} keys，变体 {len(built)}）")
    # 摘要:列出本 effect 的 pass samplers/uniforms 以便核对 g_Texture1..4 / g_Stage 是否齐全
    for vi, v in enumerate(built):
        for pi, p in enumerate(v["passes"]):
            fs = p.get("frag", {})
            print(f"  variant{vi} pass{pi} shader={p.get('shader')} samplers={[s.get('name') for s in fs.get('samplers', [])]}")
            print(f"           frag uniforms(name->material): " +
                  ", ".join(f"{u.get('name')}<-{(p.get('uniformMeta', {}).get(u.get('name')) or {}).get('material','?')}" for u in fs.get('uniforms', [])))
            vsd = p.get("vert", {})
            print(f"           vert uniforms: {[u.get('name') for u in vsd.get('uniforms', [])]}")
    if fails:
        print("  注:部分非致命 miss:", fails)
    return 0

if __name__ == "__main__":
    sys.exit(main())
