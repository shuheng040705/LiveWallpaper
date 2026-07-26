#!/usr/bin/env python3
"""
全库特效覆盖扫描器 —— 不渲染、不截图,纯静态查出「pkg 引用了但引擎渲不出」的特效缺口。

动机:历史上几乎每个渲染缺口(auto_sway 兽耳 / fog 泛白 / audio_base 音频条 / rounded_mask 圆盘 …)
都是同一类:pkg 引用了某 workshop/pkg-local 特效,但 manifest 里没有它、或它实际用到的 combo 变体没成功
转译(转译工具静默部分成功)。这类问题 100% 能静态检测——本工具把它们直接列出来,免得每次靠肉眼看
泛白截图再逆向排查。

用法:
  python3 tools/we_coverage_scan.py            # 全库扫描,按缺口数排序列出有问题的壁纸
  python3 tools/we_coverage_scan.py <id>       # 只扫某张壁纸,逐特效列 T1/T2 缺口
  python3 tools/we_coverage_scan.py --summary  # 只打全库汇总(哪些特效缺、被多少壁纸引用)

输出两档(**与引擎运行期解析逐项对齐**,见下方「对齐引擎」注释):
  T1 (硬缺口) 特效 key 在 manifest 完全找不到(含 basename 兜底,= 引擎 isEffectTranspiled/resolvedKey)
             → 引擎 we.has 门控跳过、必定不渲染。
  T2 (combo缺口) 特效在(多变体),但该壁纸请求的某个 **非默认(≠0)combo key=value 没有任一变体提供**
             (= 引擎 WEEffectChain.unsupportedCombos)→ 引擎 best/partial-match 退到默认/近似变体,该
             渲染模式没被转译。

⚠ **历史误报教训(2026-06-20 对齐重写)**:旧版本把大量「引擎实测 RAN 在跑」的特效报成缺口,反复吓到
   用户。三类误报真因,本版全部消除:
   ① **没过滤可见性**:报的特效全在 `visible:false` 的层(deformer_simulation 在「空间模拟 后头发/脸/
      前头发」)或 `visible:false` 的 effect(tint BLENDMODE=3 在「脸皮」,effect 自带 visible:false)
      或 instanced 占位隐藏层(背景的 `____________________`)→ 引擎 parseEffects 的 effectVisible 门控
      /instanced 跳过根本不建这些层 → 不渲染 ≠ 缺口。本版复刻 parseVisible + effectVisible + instanced 跳过。
   ② **T2 用整组 combo 子集判据**(used ⊆ 某单一变体)远比引擎严:引擎 selectVariant 有 **partial-match
      兜底**(满足任一请求 combo 即选该变体),且 unsupportedCombos 是**逐 key** 判「任一变体提供该 key=value」
      (不要求同一变体提供全部)。本版改逐 key、且只看 ≠0、且要求 variants>1(= unsupportedCombos)。
   ③ **basename 索引取首个 key**:引擎取「combo 覆盖最全」的同名 key(平局取最短)。本版复刻。
   验证锚点:白影(3497488774)引擎实跑 ENGINEGAPS 为空(0 缺口),本版对它也报 0 缺口。
"""
import sys, os, json, glob
sys.path.insert(0, os.path.dirname(__file__))
import we_build_effects as B

MANI = os.path.join(os.path.dirname(__file__), "generated", "WEEffects.json")

# 引擎侧特殊处理、**不走 manifest** 的特效 basename → manifest 里查不到属正常,不算缺口。
# 加进来前必须在 Sources/ 里确认确有按名处理的代码路径(避免漏报真缺口)。
ENGINE_HANDLED = {
    "texture_override",   # SceneModel.textureOverrideBase:纯色层取覆盖贴图,we.has 门控故意跳过 manifest
}


# ───────────────────────────── 对齐引擎:可见性门控 ─────────────────────────────
# 引擎 SceneModel.parseVisible:visible 是字面 bool false → 隐藏;dict(脚本/用户开关绑定)或缺省 → 默认可见。
def layer_visible(o):
    v = o.get("visible")
    if isinstance(v, bool):
        return v
    # 字典(脚本 / {user,value} 绑定)、数字、缺省:引擎默认可见(parseVisible 非 bool 一律 true)。
    # 注:数字 0/1 在 pkg 里的 layer.visible 几乎不出现(用 bool),按引擎语义非 bool → true。
    return True


# 引擎 SceneModel.effectVisible:effect 自带 visible 字段;字面 bool false → 丢该 effect;
# {user:key,...} 引用「未定义」用户属性 → 隐藏(本扫描无 overrides 上下文,保守视为可见,不漏报)。
def effect_visible(e):
    v = e.get("visible")
    if isinstance(v, bool):
        return v
    return True


# 引擎跳过 instanced:true 的占位隐藏层(SceneRenderEngine「skip instanced placeholder layer」)。
def is_instanced_placeholder(o):
    return bool(o.get("instanced")) or bool(o.get("isInstance"))


# ───────────────────────────── 对齐引擎:key 提取 ─────────────────────────────
# 复刻 SceneModel.weEffectName:含 "workshop/" → 保留整段(去 /effect.json);否则取 effects/ 后**首段**。
def we_effect_name(file_str):
    f = (file_str or "").replace("\\", "/")
    idx = f.find("effects/")
    if idx < 0:
        return ""
    rest = f[idx + len("effects/"):]
    if "workshop/" in rest:
        if rest.endswith("/effect.json"):
            rest = rest[:-len("/effect.json")]
        return rest
    return rest.split("/", 1)[0]


# ───────────────────────────── 对齐引擎:manifest 解析 ─────────────────────────────
def _combo_coverage(m, key):
    """该 key 全变体声明过的 distinct combo 赋值数(= 引擎 comboCoverage)。"""
    s = set()
    for v in m.get(key, {}).get("variants", []):
        for ck, cv in (v.get("combos") or {}).items():
            s.add(f"{ck}={cv}")
    return len(s)


def load_manifest():
    m = json.load(open(MANI))
    # 引擎 basenameIndex:排除 material/,同 basename 取 combo 覆盖最全的 key,平局取最短路径。
    idx = {}
    for k in m:
        if k.startswith("material/"):
            continue
        base = k.rsplit("/", 1)[-1]
        cur = idx.get(base)
        if cur is not None:
            cc, kc = _combo_coverage(m, cur), _combo_coverage(m, k)
            if cc > kc or (cc == kc and len(cur) <= len(k)):
                continue
        idx[base] = k
    return m, idx


def resolve_key(eff_key, manifest, bn_index):
    """引擎 resolvedKey / isEffectTranspiled 逻辑:
    精确 key 优先;否则**仅当含 '/'** 才按 basename 命中(裸名无 '/' 不兜底=引擎语义)。"""
    if eff_key in manifest:
        return eff_key
    if "/" not in eff_key:
        return None
    base = eff_key.rsplit("/", 1)[-1]
    return bn_index.get(base)


def unsupported_combos(eff_key, used_combo, manifest, bn_index):
    """复刻引擎 WEEffectChain.unsupportedCombos:逐 key 判「请求了非默认(≠0)值但无任一变体提供该 key=value」。
    仅 variants>1(combo 系统活跃)时判;value 默认 0 缺省即正确,只报 ≠0 的。返回缺失的 [key=value] 列表。"""
    rk = resolve_key(eff_key, manifest, bn_index)
    if rk is None:
        return []
    variants = manifest[rk].get("variants", [])
    if len(variants) <= 1:
        return []
    gaps = []
    for k, v in used_combo:
        sv = str(v)
        if sv in ("0", "0.0"):
            continue
        if not any(str(var.get("combos", {}).get(k)) == sv for var in variants):
            gaps.append(f"{k}={sv}")
    return sorted(gaps)


def scan_one_pkg(pkg_path):
    """扫单个 pkg,返回 {eff_key: set(combo_tuple)}。
    **对齐引擎**:只收**可见层**(parseVisible)、非 instanced 占位、**可见 effect**(effectVisible)的特效。"""
    files = B.pkg_files(pkg_path)
    if not files:
        return {}
    scene = next((B._parse_json_lenient(v.decode("utf-8", "ignore"))
                  for k, v in files.items() if k.endswith("scene.json")), None)
    if not scene:
        return {}
    out = {}

    def collect_effects(o):
        # o 是一个 scene 对象(层):已通过可见性 + 非 instanced 门控,收其可见 effect。
        for e in (o.get("effects") or []):
            if not isinstance(e, dict):
                continue
            if not effect_visible(e):
                continue  # 引擎 effectVisible 门控:effect 自带 visible:false → 丢
            f = (e.get("file") or "").replace("\\", "/")
            if "effects/" not in f:
                continue
            key = we_effect_name(f)
            if not key:
                continue
            rec = out.setdefault(key, set())
            for ps in (e.get("passes") or []):
                if isinstance(ps, dict):
                    c = ps.get("combos") or {}
                    rec.add(tuple(sorted((k, str(v)) for k, v in c.items())))

    def visit(o):
        if isinstance(o, dict):
            # 层级可见性门控:visible:false 字面值或 instanced 占位 → 引擎不建该层 → 跳过其 effects。
            if "effects" in o and (not layer_visible(o) or is_instanced_placeholder(o)):
                # 仍递归其它字段(嵌套对象可能含独立层),但不收本层 effects。
                for k, v in o.items():
                    if k != "effects":
                        visit(v)
                return
            if "effects" in o:
                collect_effects(o)
            for v in o.values():
                visit(v)
        elif isinstance(o, list):
            for v in o:
                visit(v)

    visit(scene)
    return out


def gaps_for_pkg(eff_combos, manifest, bn_index):
    """返回 (t1, t2):t1=[eff_key 硬缺],t2=[(eff_key, used_combo) combo缺]。
    T1 = 引擎 isEffectTranspiled 为假;T2 = 引擎 unsupportedCombos 非空。"""
    t1, t2 = [], []
    for eff_key, combos in eff_combos.items():
        if eff_key.rsplit("/", 1)[-1] in ENGINE_HANDLED:
            continue  # 引擎侧特殊处理,不走 manifest,非缺口
        rk = resolve_key(eff_key, manifest, bn_index)
        if rk is None:
            # 引擎 isEffectTranspiled 同款:裸名(无 '/')= 内置共享特效名,引擎自带,不判缺口。
            if "/" in eff_key:
                t1.append(eff_key)
            continue
        for uc in combos:
            for kv in unsupported_combos(eff_key, uc, manifest, bn_index):
                t2.append((eff_key, kv))
    # T2 去重(逐 key=value;同特效多 pass 可能重复)。
    t2 = sorted(set(t2))
    return t1, t2


def title_of(pkg_path):
    pid = os.path.basename(os.path.dirname(pkg_path))
    pj = os.path.join(os.path.dirname(pkg_path), "project.json")
    if os.path.exists(pj):
        try:
            return pid, json.load(open(pj)).get("title", "")
        except Exception:
            pass
    return pid, ""


def fmt_combos(kvs):
    """kvs = ['KEY=VALUE', ...](同特效缺失的各 combo 赋值)→ 紧凑串。"""
    return "{" + ", ".join(kvs) + "}" if kvs else "(base)"


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    flags = {a for a in sys.argv[1:] if a.startswith("--")}
    manifest, bn_index = load_manifest()
    print(f"manifest: {len(manifest)} keys\n")

    if args:  # 单张壁纸
        pid = args[0]
        pkg = os.path.join(B.WORKSHOP, pid, "scene.pkg")
        if not os.path.exists(pkg):
            print(f"找不到 {pkg}")
            return
        _, title = title_of(pkg)
        ec = scan_one_pkg(pkg)
        t1, t2 = gaps_for_pkg(ec, manifest, bn_index)
        print(f"== {pid} 「{title}」:引用 {len(ec)} 个特效(仅可见层/可见 effect)==")
        if not t1 and not t2:
            print("✅ 无特效缺口(所有可见引用的特效+combo 都能渲,= 引擎实跑)")
        for k in sorted(t1):
            print(f"  ❌ T1 硬缺:{k}  → manifest 完全没有,必定不渲染")
        # T2 按特效聚合各缺失 key=value。
        by_eff = {}
        for k, kv in t2:
            by_eff.setdefault(k, []).append(kv)
        for k in sorted(by_eff):
            print(f"  ⚠️ T2 combo缺:{k}  缺变体={fmt_combos(sorted(by_eff[k]))}  → 无任一变体提供,回退默认变体(渲染模式未转译)")
        return

    # 全库
    pkgs = sorted(glob.glob(os.path.join(B.WORKSHOP, "*", "scene.pkg")))
    rows, t1_ref, t2_ref = [], {}, {}
    for pkg in pkgs:
        ec = scan_one_pkg(pkg)
        t1, t2 = gaps_for_pkg(ec, manifest, bn_index)
        if t1 or t2:
            pid, title = title_of(pkg)
            rows.append((len(t1) + len(t2), pid, title, t1, t2))
        for k in t1:
            t1_ref[k] = t1_ref.get(k, 0) + 1
        for k, _ in t2:
            t2_ref[k] = t2_ref.get(k, 0) + 1

    print(f"扫描 {len(pkgs)} 张壁纸,{len(rows)} 张有特效缺口\n")
    print("=== 全库汇总:被引用但缺失的特效 ===")
    print("-- T1 硬缺(特效根本不在 manifest)--")
    for k, n in sorted(t1_ref.items(), key=lambda x: -x[1]):
        print(f"  {n:3d} 张引用  {k}")
    if not t1_ref:
        print("  (无)")
    print("-- T2 combo 缺(特效在但某 combo 无变体)--")
    for k, n in sorted(t2_ref.items(), key=lambda x: -x[1]):
        print(f"  {n:3d} 张引用  {k}")
    if not t2_ref:
        print("  (无)")

    if "--summary" not in flags:
        print("\n=== 逐壁纸(缺口数降序)===")
        for _, pid, title, t1, t2 in sorted(rows, reverse=True):
            print(f"\n{pid} 「{title}」  T1={len(t1)} T2={len(set(k for k, _ in t2))}")
            for k in sorted(t1):
                print(f"    ❌ {k}")
            by_eff = {}
            for k, kv in t2:
                by_eff.setdefault(k, []).append(kv)
            for k in sorted(by_eff):
                print(f"    ⚠️ {k} {fmt_combos(sorted(by_eff[k]))}")


if __name__ == "__main__":
    main()
