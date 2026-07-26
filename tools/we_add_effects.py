#!/usr/bin/env python3
"""
WEEffects.json **增量**构建器:只转译/合并指定的 builtin、workshop 或 pkg-local effect key,
不全量重建。

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


def normalized_combos(combos):
    return {str(k): str(v) for k, v in (combos or {}).items()}


def pending_variants(existing, requested):
    """只返回 manifest 尚不存在的 combo；已有变体保持原记录和 Metal 文件不动。"""
    existing_keys = {
        tuple(sorted(normalized_combos(v.get("combos")).items()))
        for v in existing
    }
    pending, seen = [], set()
    for combos in requested:
        normalized = normalized_combos(combos)
        key = tuple(sorted(normalized.items()))
        if key in existing_keys or key in seen:
            continue
        seen.add(key)
        pending.append(normalized)
    return pending


def builtin_uses_mask(name):
    """复用全量构建器口径：任一 stage 引用 MASK，就为实际 combo 同时烘 MASK=1 变体。"""
    ejson = os.path.join(B.WE, "effects", name, "effect.json")
    if not os.path.exists(ejson):
        return False
    edef = B._load_json_lenient(ejson)
    for p in edef.get("passes", []):
        shader = p.get("shader")
        material = p.get("material")
        if not shader and material:
            material_path = os.path.join(B.WE, "effects", name, material)
            if os.path.exists(material_path):
                shader = B._load_json_lenient(material_path).get("passes", [{}])[0].get("shader")
        if not shader:
            continue
        for ext in (".frag", ".vert"):
            shader_path = os.path.join(B.WE, "effects", name, "shaders", shader + ext)
            if os.path.exists(shader_path):
                if "MASK" in open(shader_path, encoding="utf-8", errors="ignore").read():
                    return True
    return False


def main():
    manifest = json.load(open(MANI))
    before = len(manifest)
    print(f"当前 manifest: {before} keys")

    scan = B.scan_post_workshop_effects()          # 全库 effects/workshop/ 引用 → (pkg, combo_sets)
    # pkg-local 内置特效(effect.json 在 pkg 内、非 workshop 前缀、非 WE assets 内置;如「白影轻扬」3497488774
    # 的 fog)被 workshop scanner 漏掉 → 并入(setdefault:workshop 同名优先不覆盖)。同走 build_workshop_effect。
    for k, v in B.scan_pkg_local_effects().items():
        scan.setdefault(k, v)
    builtin_combos = B.scene_combos()
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
        is_builtin = eff_key in B.USED
        if eff_key not in scan and not is_builtin:
            print(f"✗ {eff_key}: 全库 scene 未引用(scan 未命中),跳过")
            continue
        pkg_path = None
        force_slots = set()
        combo_sets = builtin_combos.get(eff_key, set()) if is_builtin else scan[eff_key][1]
        if not is_builtin:
            pkg_path = scan[eff_key][0]
            # scene 绑的覆盖贴图槽(effect.json 不声明、由 scene 绑)→ 供 sampler combo(texture_override 的
            # g_Texture1 ENABLE)在转译期派生,否则变体无 g_Texture1、覆盖贴图永远采不到。
            force_slots = B.scene_bound_slots_for(eff_key, pkg_path)
        # base({}) + scene 实际用到的 combo 组合,逐变体建(与 we_build_effects.main 同口径)。
        variants_in = [{}]
        for cs in sorted(combo_sets):
            cd = {k: v for k, v in cs}
            if cd not in variants_in:
                variants_in.append(cd)
        # 内置 effect 与全量构建器一致：shader 使用 MASK 时，为每个实际组合派生 MASK=1。
        if is_builtin and builtin_uses_mask(eff_key):
            for base_variant in list(variants_in):
                masked = dict(base_variant)
                masked["MASK"] = "1"
                if masked not in variants_in:
                    variants_in.append(masked)
        existing = manifest.get(eff_key, {}).get("variants", [])
        variants_in = pending_variants(existing, variants_in)
        if not variants_in:
            print(f"  ↷ {eff_key}: 所有 scene combo 已存在，未重建")
            continue
        built = []
        for combos in variants_in:
            ck = B.combo_key(combos)
            try:
                if is_builtin:
                    rec, err, misses = B.build_effect(eff_key, combos, ck)
                else:
                    rec, err, misses = B.build_workshop_effect(
                        eff_key, pkg_path, combos, ck, force_slots=force_slots
                    )
                if rec and rec["passes"] and any(pp.get("frag") for pp in rec["passes"]):
                    built.append({"combos": combos, "passes": rec["passes"]})
                    print(f"  ✓ {eff_key}  combos={combos or '(base)'}")
                else:
                    print(f"  ✗ {eff_key}  combos={combos or '(base)'}: {err or 'no frag'}")
            except Exception as e:
                print(f"  ✗ {eff_key}  combos={combos or '(base)'}: EXC {str(e)[:200]}")
        if built:
            manifest.setdefault(eff_key, {"variants": []})
            manifest[eff_key].setdefault("variants", []).extend(built)
            added.append(eff_key)
            print(f"→ 增量合并 {eff_key}: +{len(built)} 变体，旧变体保留")

    if added:
        json.dump(manifest, open(MANI, "w"), indent=1, ensure_ascii=False)
        print(f"\n写回 manifest: {before} → {len(manifest)} keys(更新 {added})")
    else:
        print("\n无可合并条目,manifest 未改动")


if __name__ == "__main__":
    main()
