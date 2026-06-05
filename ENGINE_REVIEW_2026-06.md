# 全项目代码评审 2026-06(7-agent 并行 + lwe 逐文件对照)

审阅范围:`Sources/LiveWallpaper/` 全部 Swift + `tools/` 转译器,逐个对照 `linux-wallpaperengine`(lwe)真源。
状态标记:**[已修]** = 本轮已移植 lwe 对应并零回归实测;**[待办]** = 真问题、未动;**[平台]** = lwe 无对应的本平台 bug。

总评:**没有系统性伪造 / 逐壁纸硬调**。主干(变换/混合/视差/坐标/粒子算子/std140 布局/combo 语义)是可逐行对上 lwe 的真移植。问题集中在少数默认值、几处自创近似、和一批"注释考古"噪声。

---

## 🔴 真 Bug

### R1. pulse/shake/hue_shift 音频特效**恒不脉动** [待办]
`WEEffectChain.swift:176-186`(usesAudioSpectrum)+ manifest 生成器
- 生成的 pulse MSL 的 `_Globals` 里有 `g_AudioSpectrum16Left/Right[16]`,但 manifest 的 pulse 变体 **vert 阶段 uniforms 没列这两个数组** → 引擎认为不存在 → 频谱恒 0 → 永不脉动。
- lwe(CPass.cpp:785-790)对**每个 pass 无条件**绑频谱,不依赖"清单是否列出"。
- 命中 5 个:pulse、shake、workshop 2718465779·3676150801·2193274282。
- 修法:`we_build_effects.py` 对 vert 也抽 `g_AudioSpectrum*` 数组。**需重生成 manifest(有把 workshop shader 转坏的已知隐患,需单张验证后再全量)**。

### R2. condition 求值对**非-combo 属性**用错语义 [待办]
`SceneModel.swift:40-62`(VecParse.unwrap 条件形)
- 我方把 override 当前值无条件转字符串再 `==` condition(bool→"1"/"0"、number→串…)。
- lwe(DynamicValue.cpp:213):**只在连接属性以 String 类型更新时**才触发 condition;bool/slider 属性直接取 bool/数值,condition 被忽略。
- combo 属性碰巧一致 ✅;**bool/slider 属性会发散**——是"背景污染/残留覆盖"类问题尚未根治的残留面。
- 修法:override 带类型分派(.string→比较,.bool→返回 bool,.number→≠0)。**动 override 核心,需单独一轮 + 重测背景污染。**

### R3. VideoTexture `attachRetention` 漏锁竞态 [平台]
`VideoTexture.swift:110-114`
- `currentTexture()`(后台渲染线程)持 `avLock` 写 `pending`;但 `attachRetention()`(commit 路径)`let hold=pending; pending.removeAll()` **不持锁** → Swift Array 并发访问 = 数据竞争,可能崩溃/丢帧。文件自称"已加锁"但漏了这条路径。
- 只影响**视频壁纸**(mp4)。修法:attachRetention 整体包 avLock。

### R4. mat3 std140 布局写错 [待办·潜伏]
`WEEffectChain.swift:412` `case "mat3": n=12` 连续写
- std140 的 mat3 每列占 vec4(16B),应写在字节 0/16/32;连续写 12 float 会错位。
- 当前是死路径(g_NormalModelMatrix 没赋值源 → 留 0),一旦接入法线矩阵就散架。修法:按 3×vec4 写。

---

## 🟠 偏离 lwe 的默认值 / 自创

### [已修] 本轮移植的 6 处
| 项 | 改动 | lwe 真源 |
|---|---|---|
| clearcolor 默认 | 黑→**白 vec3(1)** + alpha 恒 1 | WallpaperParser.cpp:44 / CScene.cpp:91 |
| camerashake roughness/speed | 1→**0** | WallpaperParser.cpp:63-64 |
| bloom threshold/strength | 0.65/2.0→**0** | WallpaperParser.cpp:51-52 |
| **g_TexelSize/Half** | per-pass 纹理尺寸→**恒定全场景尺寸** | CPass.cpp:783-784 |
| **engine.runtime** | 实例存活秒→**全局 g_Time**(脚本共享时钟) | EngineObject.cpp:27 |
| **engine.timeOfDay** | 含秒 /86400→**分钟粒度 (h*60+m)/1440** | EngineObject.cpp:31 |
| **effect 链音频** | 64段重采样→**原生 16/32/64** | CPass.cpp:785-790 |

### O1. TexDecoder RG88/R8 通道魔改 [待办·需 shader 协同]
`TexDecoder.swift:339-364`
- 我方 RG88 默认 `(R,R,R,G)`、R8 `(R,R,R,1)`;lwe(CTexture.cpp:143-164)是 GL_RG8/GL_R8 直采 = `(R,G,0,1)`/`(R,0,0,1)`。
- 是肉眼试出来的(改成 lwe 值精灵变彩色实心块)。正解在**采样 shader 端**(精灵采 .a 当 alpha),非解码端改通道。**别单独动。**

### O2. g_PointerPosition 默认 0.5 且与 g_ParallaxPosition 合并 [待办]
`WEEffectChain.swift:503-505`
- lwe(CPass.cpp:779-780)给真实鼠标 + g_PointerPositionLast;我方合并成一个 `cursor`、默认居中。交互特效(xray/depthparallax)恒在中心。

### O3. 粒子:ropetrail/remapvalue/warmup 是自创(lwe 无) [记录]
`ParticleSystem.swift`
- ropetrail 逐粒子轨迹(含 0.02/0.1 两个无来源魔法数)、remapvalue operator、warmup 预热——lwe 都没有,是"贴近真 WE、偏离开源 lwe"的再实现。视觉通常更对,但不能算"移植"。operator 控制点不随鼠标联动、vortex 涡心近似、layer scale 不缩 size、emitter randomPeriodic 未实现 = 真实功能缺口。

### O4. 转译器正则 hack 群 [记录·技术债]
`we_transpile.py:212-320`
- lwe 靠 `#define` 宏 + 真 glslang/SPIRV-Cross;我方为"凑过编译"加了十几条窄正则(texSample2D 加 .xy、max 窄正则、各具名 shader 截断)。当前不误伤,但正确性靠"全库正好只命中一处"的脆弱假设——line 314-319 已真实翻过一次车(workshop 噪点)。

---

## 🟡 死代码 / 隐患 / 混乱

- **scene_combos() 的 `nm='workshop'` key bug**(we_build_effects.py:213):当前被 USED 巧合挡住=定时炸弹,与 scan_post_workshop_effects 用了两套不一致解析。[待办]
- **TEXB0004 extra-header「自洽探测」启发式**(TexDecoder:217-254):把 lwe 确定性解析改成概率猜测,违"通用渲染"铁律。应据 magic 子版本固定判定。[待办]
- **WEKeyframeAnimation 线性插值丢贝塞尔手柄**(WEKeyframeAnimation.swift):发饰/音频条 opacity"拐点硬/不平滑"的根因。lwe 自身不实现关键帧,是照真 WE 自实现,缺手柄。[待办]
- **renderPuppetIntoFBO/makePuppetFBO 死代码**(SceneRenderEngine:2046-2092):puppet 已改直渲三角网格,旧 FBO 路径无调用点。
- **WallpaperSettingsView 双份 UI**(其一疑似死代码)、**WallpaperItem.isPlayable 注释自相矛盾**、**TextLayerRenderer 折行注释互相打架**(48 行 wordWrapping 被 100000 吊死)。
- **CursorRippleSim**:lwe 树里无对照源,~10 个魔法数(decay 1.5/radius 60/1.61…)无独立验证手段;内部一致性检查通过但"对不对只能跑真 WE 逐像素比"。
- **大量"曾试/已撤销/审计修复#N"注释考古**(SceneRenderEngine 尤甚):功能正确但信噪比低,代码在不停自证清白反而显可疑,建议迁到设计文档。

---

## ✅ 核验为正确的关键断言(用户最担心的几处)

- **blend 因子** `.sourceAlpha`(SceneRenderEngine:345-360)= lwe CPass.cpp:132/136 GL_SRC_ALPHA ✅
- **matOrtho/matModel 旋转符号/camera eye 抵消/视差 refW 两轴共用 canvas.x** = 逐行对上 lwe ✅
- **resolveTransform 父子链** = lwe #602 迭代版数学等价 ✅
- **粒子 ring/vortex/turbulence/oscillate/fadeValue/精灵 aspect 校正** = 逐行对上 lwe CParticle.cpp ✅
- **std140 spectrum 数组 float4[N].x 布局、AudioCapture 各 N 独立分桶、combo 整数语义** ✅
- **属性覆盖系统(背景污染疑点)**:setValue/reset 只被用户 binding 调用,key 按壁纸隔离,每次按 item 重读 + defer 清空 → **无跨壁纸残留、无写脏默认值**,存储层健康(残留面只在 R2 的 condition 类型语义)
- **colorspace/XDR 修复**(SceneRenderer:42 sRGB)、**WENoise**(逐字节 100% 对上 lwe,连 0xD「怪味」都照抄)

---

## 平台 bug(lwe 无对应,非移植项)

- **R3 VideoTexture 漏锁**(上)
- **PreferencesStore.swift:9 硬编码 `/Users/a55555/...` 默认库路径** → 别人机器/全新安装扫空库,应 homeDirectoryForCurrentUser 拼接。**对本机无影响**。
- DesktopIcons.setVisible 主线程同步 killall Finder;WebRenderer 目录穿越前缀旁路(需恶意壁纸 HTML)。
