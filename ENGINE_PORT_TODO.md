# LiveWallpaper 引擎保真度清单（待移植）

> 2026-06-02 生成。逐子系统拿 Swift 实现对照 linux-wallpaperengine(lwe) + WE bottle 真实源码，
> 找出**还没照 WE/lwe 移植好**的地方（近似/缺失/解析未消费/硬编码魔法系数）。
> `[ ]` 待修 / `[x]` 已修 / `[~]` 部分。组内按视觉影响排序。

**好消息（已忠实，勿当 bug 改）**：特效转译覆盖率完整（45 内置 effect 全进 manifest，fail.json 空）；
相机视差已照 lwe `CScene.cpp:394-406`+`CImage.cpp:1097-1106`（`(depth+amount)×displacement×width`+delay 平滑）；
camerashake 不渲染（对齐 lwe）；bloom 4-pass 逐行忠实 WE shader；blending 32 方程 / 父子变换 resolveTransform / AudioPlayback 均忠实。

---

## 🟣 A. 粒子系统（13 项）

**高影响**
- [x] 精灵朝向：已删 `speed>500`+atan2 臆造，sprite 恒用 rotation（无 rotationrandom→0，非 rnd2π），rope/trail 仍走速度路径（lwe ComputeParticleTangents）
- [x] overbright：解析 `ui_editor_properties_overbright`(默认1)折进实例 col.rgb，sprite/rope 共用 visualState 一处生效（lwe genericparticle.frag:119）
- [ ] 精灵表无帧间混合(SPRITESHEETBLEND) — `ParticleSystem.swift:880-895` 只 floor 硬切；WE `common_particles.h` 用 `frac(lifetime×numFrames)` mix(cur,next)

**中影响**
- [ ] ropetrail 长度启发式硬编码 — `ParticleSystem.swift:449-467` `maxTrailSeconds=0.1`+采样 0.02；应按 `renderer.length` 秒×segments 等时快照
- [x] rope UV smoothing 缺 uniformLifetimes 门控 — `:829` 已加 `&& lifetimeMin==lifetimeMax`（lwe CParticle.cpp:2187）
- [x] rope UV 滚动速率（上一轮被误改成 ×0.5）→ 改回 lwe 真值 `fmod(time,10000)×usableLength`（1 周期/秒，CParticle.cpp:2203）
- [x] gravity 未乘 instanceoverride.speed — `:347` 已加 `* ioSpeed`（lwe CParticle.cpp:1054）
- [ ] vortex 中心用 emitterOrigin 近似，未用 controlpoint — `:365`；lwe `:1361`
- [ ] vortex 缺 ring/infiniteAxis/audio 分支 — `:360-391`；lwe `:1324-1432`

**低影响**
- [~] velocityrandom Y 翻转：**不改**——本引擎 Y-up vs lwe Y-down 的坐标系差异，盲翻会反转所有粒子初速度（同 matModel 教训）。现状对称 velmin/max 无碍
- [x] angularvelocity 积分 ×ioSpeed（lwe CParticle.cpp:1088，与 init×speed 的 speed² 一致）
- [x] angularmovement：force×ioSpeed + 角阻力 drag（lwe CParticle.cpp:1097）。force 只取 .z 对 2D 精灵正确（单轴 rotation）
- [~] movement 积分顺序：**暂不改**——「先位移后受力」半步相位差，价值微小但影响所有粒子轨迹，风险>收益

## 🟡 B. 材质 / 合成 / 折射（8 项）

**高影响**
- [~] 主图层材质 combos/PBR（大件，分步）：
  - [x] 步1 转译：we_build_effects 扩展，genericimage2/3/4 全 combo 变体(36个)进 manifest，0 失败、引擎加载无错
  - [x] 步2地基：SceneModel 捕获图层材质 shader/combos/constantshadervalues 进 LayerDesc(编译通过)
  - [x] 步3 渲染路径：WEEffectChain.encodeMaterialLayer(材质 pipeline+uniform+纹理+unit quad)+ SceneRenderEngine 图层循环路由(有意义 combo 走转译 genericimage,plain 走 scene_fragment)。base 自验证 99.5%+ 视觉一致、零回归
  - [ ] 步4 光照子系统：解析 light 对象 → LIGHTING/NORMALMAP/PBR
  - ⚠️ 验证卡点：**全库 0 张壁纸用 LIGHTING/REFLECTION/NORMALMAP**，渲染路径需测试壁纸才能验证
- [ ] HDR 渲染目标缺失，全链 8-bit LDR clamp — `SceneRenderEngine.swift:1257/1273/1315`；WE 有 hdr_downsample/combine_hdr(fp16)

**折射（中-低）**
- [x] g_RefractAmount：改读材质 `ui_editor_properties_refract_amount`(per-group 顶点 uniform)，实库雨幕 -0.05~-0.44(含符号翻转)/magic_pulse 1，缺省退 WE 默认 0.05
- [ ] 折射法线解包硬编码 DXT5 swizzle，未按 TEX1FORMAT 选 — `:1957`
- [x] 折射片元 g_Overbright：折射粒子 in.color 已含 overbright(visualState 折入)，= WE albedo×v_Color×g_Overbright
- [ ] REFRACT 当布尔，WE 是 options 多值 — `:1248`
- [ ] 折射屏幕偏移未做宽高比校正 — `:1960`
- [ ] 非 solid 层无条件乘 object color — `:1757`

## 🔵 C. 特效转译 / 相机 / FBO（6 项）
> 转译覆盖率 ✅ 完整（45 内置全转译，0 失败）

**高影响**
- [ ] FBO 像素格式被丢弃 → fluidsimulation 数值崩坏 — `we_build_effects.py:226` 只读 scale；`WEEffectChain.swift:210` 一律 bgra8。fluidsim 需 r16f/rg16f、glitter 需 r8
- [ ] FBO `fit`(固定像素尺寸)未实现 — fluidsim 用 fit:256

**中影响**
- [ ] 透视相机 `eye` 平移被丢弃 — `SceneModel.swift:314` 解析未消费；抽样 47 场景全部有非默认 eye
- [ ] FBO `clear`/`unique` 标记未实现，跨帧反馈缓冲被每帧清 — `WEEffectChain.swift:533`
- [ ] 建议：修好 FBO 格式前把 fluidsimulation 临时加入 weDenied

**低影响**
- [ ] swap/copy 命令语义待 fluidsim 修好后回归验证

## 🟢 D. 音频 / 脚本 / 文本（9 项）

**高影响**
- [ ] JS 脚本音频缓冲区从不填充 → audio-reactive 脚本永远静默 — `WEScriptRuntime.swift:341`；lwe `ScriptEngine.cpp:1254` 每帧 updateAudioArray
- [x] 脚本 sim-time：已把引擎 time/dt(frametime) 喂进所有 runVec3/runString(并行轮)

**中影响**
- [ ] pulse/shake 喂 64 段重采样而非独立 16 段 — `SceneRenderEngine.swift:899`（已有 spectrum16 没用上）
- [x] 音频分桶：改回 WE 线性单 bin `band*2`，16/32 用 >>1/>>2 移位(并行轮)
- [ ] thisScene/thisLayer 层绑定是死桩，层间脚本通信失效 — `WEScriptRuntime.swift:398`
- [ ] 媒体事件 API(歌名/进度/封面)缺失
- [ ] 文本富文本/描边/阴影/字重未实现 — `TextLayerRenderer.swift:43`

**低影响**
- [ ] 音频输入滑动块而非双缓冲整块 — `AudioCapture.swift:248`
- [ ] 文本多行不按盒子宽度折行 — `TextLayerRenderer.swift:47`

---

**合计约 36 项。** 建议优先级前 5：① 粒子朝向(rotation)、② 主材质 combos/PBR、③ 脚本音频缓冲、④ fluidsimulation FBO 格式、⑤ HDR 链。
