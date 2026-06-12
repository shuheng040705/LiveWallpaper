#!/usr/bin/env python3
"""
WEEffects.json **增量**构建器:只转译/合并指定的 workshop effect key,不全量重建。

为什么要增量:全量 we_build_effects.py 有把 workshop 2846660316(Esperanta)转坏成整屏噪点的
潜在回归;manifest 是回滚锚点。新壁纸下载后引入的、当前 manifest 早于其构建时间而漏掉的
effect(如 audio_base / simple_gradient_audio_bar 这类音频条),用本脚本只补这几条、保持其余 key
逐字不动 → 零回归。做法与 bokeh_blur 当初的安全增量一致(memory: manifest-regen-hazard)。

用法:
  cd /Users/a55555/Developer/LiveWallpaper
  python3 tools/we_add_effects.py workshop/3588616811/audio_base workshop/3403631383/simple_gradient_audio_bar
不带参数则打印「全库扫到但当前 manifest 缺失」的候选 key 供选。
"""
import sys, os, json
sys.path.insert(0, os.path.dirname(__file__))
import we_build_effects as B

MANI = os.path.join(os.path.dirname(__file__), "generated", "WEEffects.json")


def main():
    manifest = json.load(open(MANI))
    before = len(manifest)
    print(f"当前 manifest: {before} keys")

    scan = B.scan_post_workshop_effects()          # 全库 effects/workshop/ 引用 → (pkg, combo_sets)
    targets = sys.argv[1:]
    if not targets:
        missing = sorted(k for k in scan if k not in manifest)
        print(f"\n全库扫到但 manifest 缺失的 workshop effect({len(missing)}):")
        for k in missing:
            print("  ", k)
        print("\n传想补的 key 作参数即可。")
        return

    os.makedirs(B.MSL_DIR, exist_ok=True)
    added = []
    for eff_key in targets:
        if eff_key not in scan:
            print(f"✗ {eff_key}: 全库 scene 未引用(scan 未命中),跳过")
            continue
        pkg_path, combo_sets = scan[eff_key]
        # base({}) + scene 实际用到的 combo 组合,逐变体建(与 we_build_effects.main 同口径)
        variants_in = [{}]
        for cs in sorted(combo_sets):
            cd = {k: v for k, v in cs}
            if cd not in variants_in:
                variants_in.append(cd)
        built = []
        for combos in variants_in:
            ck = B.combo_key(combos)
            try:
                rec, err, misses = B.build_workshop_effect(eff_key, pkg_path, combos, ck)
                if rec and rec["passes"] and any(pp.get("frag") for pp in rec["passes"]):
                    built.append({"combos": combos, "passes": rec["passes"]})
                    print(f"  ✓ {eff_key}  combos={combos or '(base)'}")
                else:
                    print(f"  ✗ {eff_key}  combos={combos or '(base)'}: {err or 'no frag'}")
            except Exception as e:
                print(f"  ✗ {eff_key}  combos={combos or '(base)'}: EXC {str(e)[:200]}")
        if built:
            manifest[eff_key] = {"variants": built}
            added.append(eff_key)
            print(f"→ 合并 {eff_key}: {len(built)} 变体")

    if added:
        json.dump(manifest, open(MANI, "w"), indent=1, ensure_ascii=False)
        print(f"\n写回 manifest: {before} → {len(manifest)} keys(新增 {added})")
    else:
        print("\n无可合并条目,manifest 未改动")


if __name__ == "__main__":
    main()
