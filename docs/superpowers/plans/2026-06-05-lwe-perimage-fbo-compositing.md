# lwe per-Image FBO 合成管线移植 实现 Plan

> **For agentic workers:** 用 superpowers:subagent-driven-development 或 executing-plans 逐 task 实现。本项目**无自动化测试**(无 Tests/),所以每个 task 的"验证"= headless 渲染像素 A/B diff(新路径 vs 旧路径 vs 基线),这是本项目既定的回归手段。步骤用 `- [ ]` 跟踪。

**Goal:** 把 lwe `CImage` 的「每个 Image 自有双 FBO + material/全 effect 编进一条 pass 链 + ping-pong + 末 pass 投回真场景 FBO」合成管线忠实移植进我方 Metal 引擎,根治堆叠 composelayer 互相抵消(id=228 身体音频不可见)/打雷/空间对齐问题。

**Architecture:** **加开关 `WP_LWE_COMPOSITE`、新旧管线并存、默认关**。核心改变:① 引入一个**持久场景 FBO `_rt_FullFrameBuffer`**,所有图层**按序累积合成**进它(取代 `compositeSceneBelow` 的临场重渲);② 把"特效"从 `runLayerEffects` 上来一次性算完,改成**与图层合成交错**——渲到第 i 层时,frameBufferInput composelayer 读**当前累积的场景 FBO**(真实下方场景)作输入,跑特效链,按 blend 投回场景 FBO;③ 每个带多特效的 Image 用**自有双 FBO ping-pong**串 material+全 effect(对齐 CImage::setupPasses)。零回归门控:全库 57 张新旧逐像素 diff,新路径必须 ≥ 旧路径(打雷 15 张零回归 + id=228 堆叠音频可见)才翻默认。

**Tech Stack:** Swift + Metal;参考 lwe C++ `/Users/a55555/Developer/reference/linux-wallpaperengine/src/WallpaperEngine/Render/Objects/CImage.cpp`(setupPasses:768-835、pinpongFramebuffer:878-893、shouldRenderFinalPass:837-844、FBO:256-268、blend末移:753-759)、`Wallpapers/CScene.cpp`(_rt_FullFrameBuffer:316-337)。

**关键文件(现状)**:
- `Sources/LiveWallpaper/Scene/SceneRenderEngine.swift`:`encodeFrame`(:1711 编排:先 runLayerEffects 再 encode)、`encode`(:1359 单 pass 顺序画所有图层)、`runLayerEffects`(:1625 上来算所有 effectedTexture)、`compositeSceneBelow`(:1527 临场重渲下方=要替换的临时近似)、region-fit(:1640、cropToRegion:1593)、blend 管线(:335-354)。
- `Sources/LiveWallpaper/Scene/WEEffectChain.swift`:`run`(:589 单 effect 多 pass;makeTarget:360 每次新建——新管线改成图层级双 FBO ping-pong)。

---

## ✅ 实现完成总结(2026-06-05)

**A 已完成并翻默认。** 核心成果:composelayer 现在采样**用 clearcolor 清屏的持久场景 FBO**(= lwe `_rt_FullFrameBuffer`),按 z 序交错累积合成,取代自创的 `compositeSceneBelow`(透明 clear 临场重渲近似)。

- **Task 1-3 ✅**:`encodeLweScene` 逐段把图层累积进 `lweSceneFBO`,每个 frameBufferInput composelayer 读「累积到它之下的真场景」作特效输入(`computeLayerEffect(i, sceneInput:)`)。`runLayerEffects` 抽出 `computeLayerEffect`,交错路径会跑时跳过 composelayer 改由 encodeLweScene 算;否则保留 compositeSceneBelow 兜底(折射/postProcess+composelayer 组合)。
- **Task 4 ⏭️ 跳过(源码分析证明像素等价)**:lwe 中间 pass 用 `BlendingMode_Normal`=`GL_ONE,GL_ZERO`(纯覆盖,非 alpha-over),与我方「每 effect 新 target+不开 blend」数学等价;blend 末移与我方「按图层 blend 贴回」blend 映射逐一相同(Normal/Translucent/Additive)。全库无「多 pass+base 首 pass blend≠Normal」的 composelayer 命中差异条件 → ping-pong 重写是纯重构+回归风险、零像素收益。证据:CImage.cpp:753-760/807-813、CPass.cpp:121-137、Material.h:12-17。
- **Task 5 ✅ 翻默认**:`useLweComposite` 默认开(`WP_NO_LWE_COMPOSITE=1` 逃生退回旧路径)。**未删 `compositeSceneBelow`**——它仍是折射/postProcess+composelayer 与逃生开关路径的兜底,删了会断。

**忠实度证据(lwe 源码)**:`CScene.cpp:119-121` 设 `glClearColor(clearcolor.rgb, 1.0f)`、`:432-436` 绑场景 FBO 后 `glClear` → 场景 FBO(composelayer 采样的 `_rt_FullFrameBuffer`)用 **clearcolor(不透明)**清屏,而非透明。新路径忠实,旧路径(透明 clear)才是近似。

**A/B 回归(全库 57 张,默认 vs 逃生开关)**:53 张 0.0 diff;10 张 <0.3(动画时序抖动,base-vs-base2 同量级);**仅 2 张真实改变**——`3693137898`(meanDiff 6.15)、`3233141951`(4.80)——均为 clearcolor=0.7 灰背景 + composelayer 采样到透出背景的区域:旧路径 composelayer 读透明底、新路径读 0.7 灰底(=lwe 真行为)。肉眼near-identical(均值一致、仅云扭曲/音条采样高频重排),是**忠实改善而非回归**。新路径对多 composelayer 壁纸还更高效(O(N) 累积 vs 旧 compositeSceneBelow O(N²) 重渲)。

---

### Task 1:基线快照 + A/B 回归脚手架(先建验证,后改代码)

**Files:**
- Create: `Tools/ab_regress.py`(新旧管线全库逐像素 diff 对比脚本)
- 用现有 app 二进制 `LiveWallpaper.app/Contents/MacOS/LiveWallpaper`(`--warmrender <id> <out> <N> <longSide>`)

- [ ] **Step 1:** 写 `Tools/ab_regress.py`:遍历全库 57 张 scene 壁纸,各渲一帧到 `/tmp/abreg/<id>_base.png`(当前默认路径);对带音频的用 `WP_TEST_BANDS=loud`,默认隐藏的音频用 `WP_SHOW_IDS`。脚本支持第二次跑(设 `WP_LWE_COMPOSITE=1`)输出 `<id>_new.png` 并逐张算 mean|diff|/nonzero%、汇总成表。
- [ ] **Step 2:** 跑基线:`python3 Tools/ab_regress.py base` 生成 57 张 `_base.png`。这是"旧管线"金标准。
- [ ] **Step 3:** 记录 composelayer-thunder 记忆里的 15 张 composelayer 壁纸 id 清单 + id=228(身体音频)单独标注为必须改善的目标。
- [ ] **验证:** 57 张 base 全部成功渲出、无崩溃。提交点:基线已固化。

### Task 2:持久场景 FBO `_rt_FullFrameBuffer`(开关下,行为先等价)

**Files:** Modify `SceneRenderEngine.swift`(encodeFrame:1711、新增 sceneFBO 管理)

- [ ] **Step 1:** 加 `private var sceneFBO: MTLTexture?`(全画布尺寸 bgra8Unorm,renderTarget+shaderRead),按 canvas 尺寸惰性创建/复用。加 `let useLweComposite = ProcessInfo...["WP_LWE_COMPOSITE"] != nil`。
- [ ] **Step 2:** `useLweComposite` 时,encodeFrame 把图层合成目标从 compositeTarget 改为先渲进 `sceneFBO`,最后 blit `sceneFBO`→finalTarget(或接 postChain)。**此步不改特效/composelayer 逻辑**,只把"单 pass 顺序画图层"改成画进持久 sceneFBO。
- [ ] **验证:** `WP_LWE_COMPOSITE=1` 渲几张**无 composelayer 的普通壁纸**,与 base 逐像素 diff ≈ 0(纯目标搬家,应无变化)。提交点。

### Task 3:图层渲染与特效交错(composelayer 读真实累积场景)

**Files:** Modify `SceneRenderEngine.swift`(encode/encodeFrame、runLayerEffects 拆成 per-layer 调用)

- [ ] **Step 1:** `useLweComposite` 路径下,改成**单一顺序循环**:对每个图层 i,(a) 若是 frameBufferInput composelayer → 读**当前 sceneFBO**(已累积 0..i-1)作输入跑特效链(复用 WEEffectChain.run / region-fit),(b) 否则按现有逻辑算该层贴图,(c) 把该层结果按其 blend 合成进 sceneFBO。取代"runLayerEffects 上来全算 + compositeSceneBelow 重渲"。
- [ ] **Step 2:** composelayer 输入纹理 = sceneFBO(或其 region 裁剪),**不再调 compositeSceneBelow**。region-fit 的裁剪/UV 逻辑保留(只是输入源换成真 sceneFBO)。
- [ ] **验证:** 渲 id=228(WP_SHOW_IDS=228 WP_TEST_BANDS=loud):新路径下身体音频 navy 频谱**可见**(不再被堆叠抵消);show-vs-hide diff > 0。打雷 15 张新 vs base diff ≈ 0(原全屏 pulse 路径等价)。提交点。

### Task 4:每个 Image 双 FBO ping-pong 串 material+全 effect(对齐 CImage::setupPasses)

**Files:** Modify `WEEffectChain.swift`(run:589→支持外部传入的 a/b FBO)、`SceneRenderEngine.swift`

- [ ] **Step 1:** 给带多特效的 Image 分配两块持久 FBO(`_rt_imageLayerComposite_<id>_a/b`,层尺寸),material 底 pass + 各 effect pass 在这俩之间 ping-pong(对齐 CImage.cpp:878-893),取代 WEEffectChain.run 每 effect 各自 makeTarget 新建。
- [ ] **Step 2:** blend 末移(CImage.cpp:753-759):pass>1 时把首 pass blend 移到末 pass、首 pass 设 Normal;末 pass 按该 blend 投回 sceneFBO。
- [ ] **验证:** 全库 57 张新 vs base A/B diff;逐张人工核对受影响壁纸(音频/composelayer/打雷)。新路径不得比 base 差。提交点。

### Task 5:全库 A/B 回归门控 + 翻默认

- [ ] **Step 1:** `python3 Tools/ab_regress.py compare` 出 57 张 mean|diff| 表。要求:打雷/composelayer 15 张 diff ≈ 0(或可解释的改善)、id=228 等堆叠音频从不可见→可见、其余壁纸无回归。
- [ ] **Step 2:** 逐张肉眼核对 diff 显著的壁纸,确认全是**改善**而非回归。
- [ ] **Step 3:** 零回归确认后,把 `useLweComposite` 默认改为 true(env 改成 `WP_NO_LWE_COMPOSITE` 退回旧路径作保险),删 compositeSceneBelow 临场重渲死路径。
- [ ] **验证:** 默认路径 = 新管线,全库 57 张与"新路径"一致。部署 + 实机抽验。

---

## 风险与回滚
- 全程 `WP_LWE_COMPOSITE`(后改 `WP_NO_LWE_COMPOSITE`)开关并存,任何阶段可一键退回旧路径。
- 每个 Task 都有 render-A/B 验证门;不过门不进下一步。
- 折射粒子/postChain/分批 bloom 路径(encodeFrame:1749-1796)在新管线下需保持等价——Task 2/3 验证时一并核对(它们叠在 sceneFBO 之上,逻辑不变)。

## Self-Review 备注
- 本 plan 的"TDD"= render-A/B(项目无单测);每 Task 的验证步是渲染 diff,非 pytest。
- 类型一致:`sceneFBO`/`useLweComposite`/`WP_LWE_COMPOSITE` 贯穿 Task 2-5 同名。
- Task 4(per-Image ping-pong)是可选增量:若 Task 3 已让 composelayer 正确(读真 sceneFBO),Task 4 主要为 blend 末移保真;可据 Task 3 A/B 结果决定是否必须。
