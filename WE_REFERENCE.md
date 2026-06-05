# WE 对照表 — 本引擎的根本工作方式

**原则:任何渲染特性,先读 WE 本体源码,照着移植,不靠猜。**
出问题时第一步永远是「找到对应的 WE 源文件读一遍」,而不是凭直觉改参数。

## 铁律(用户反复强调,违反就是把所有壁纸都改坏)

1. **只调用壁纸 pkg / WE / 依赖项里的真实文件,绝不自造**。每个壁纸自带 scene.json /
   材质 / 贴图 / 粒子定义,引擎直接读这些。自造一张贴图或写死一个区域,换张壁纸就废。
2. **不准凭感觉加全局系数**(`×0.45` 降亮、默认渐隐、强转 additive……)。这些不是 WE,
   而且作用于所有壁纸。WE 不过曝靠的是真实 maxcount/size/alpha/贴图亮度 + 真实 blending。
3. **找不到真实贴图就跳过该发射器,宁可不画也不画假的**(可能是未安装的依赖项,WE 同理)。
4. **必读的 pkg 字段**:`instanceoverride.alpha`(图层级透明度)、材质 `blending`(60 additive /
   25 translucent / 0 normal,实测全库)、`combos.REFRACT`、`textures[1]`(折射法线贴图)。

## WE 源码位置(本机 CrossOver bottle)

```
WE = ~/Library/Application Support/CrossOver/Bottles/Steam/drive_c/Program Files (x86)/Steam/steamapps/common/wallpaper_engine/assets
```

- **着色器**:`$WE/shaders/*.{vert,frag,h}`(通用)+ `$WE/effects/<name>/shaders/effects/*.{vert,frag}`(每个 effect)
- **effect 定义**:`$WE/effects/<name>/effect.json`(passes 流水线 + fbos 渲染目标 + bind)
- **粒子**:`$WE/particles/`(示例)+ 用户壁纸 pkg 内的 `particles/*.json`

## 各特性 → WE 源文件对照(移植前必读)

| 本引擎特性 | WE 源文件 | 关键点 |
|---|---|---|
| 图层合成 | `shaders/genericimage2/4.{vert,frag}` | mvp + 混合模式 |
| 粒子渲染 | `shaders/genericparticle.{vert,frag}` + `shaders/common_particles.h` | 见下「粒子」 |
| 粒子精灵表帧 | `common_particles.h: ComputeSpriteFrame` | **currentFrame = floor(lifetime × numFrames)**,按粒子生命周期推进,非墙钟、非随机 |
| 粒子朝向 | `common_particles.h: ComputeParticleTangents(rotation)` | 普通精灵用 rotation.z;`TRAILRENDERER` 用 `ComputeParticleTrailTangents(velocity)`(rope 拖尾按速度) |
| 折射粒子 | `genericparticle.frag REFRACT 分支` | `color.rgb *= 屏幕底图(_rt_FullFrameBuffer)采样(uv+法线偏移)`;低 alpha |
| 鼠标涟漪 | `effects/cursorripple/shaders/effects/*.frag`(3 pass) | apply_force→simulate_force→combine,512² ping-pong 力场 RGBA=四向力 |
| 水波/水流/摇摆 | `effects/{waterwaves,waterflow,waterripple,foliagesway,shake}/shaders/effects/*.frag` | UV 位移;带 mask 纹理限定区域 |
| 染色/透明/脉动 | `effects/{tint,opacity,pulse}/shaders/effects/*.frag` | 颜色操作;BlendMode 见 `shaders/common_blending.h` |
| 音频条 | `effects/.../Simple_Audio_Bars` + `perspective` effect | 频谱条 + 4 角透视贴合到场景 |

## 转译特效引擎(真 WE shader,已上线)

不再手写近似特效——直接**转译 WE 的真实着色器**跑在 Metal 上(参考 Wallpaper Gallery.app 用 DXC 的思路)。
- 工具:`Tools/we_transpile.py`(WE GLSL 方言→Metal:重建 prelude/include/combo/UBO/varying-loc)+ `Tools/we_build_effects.py`(打包 manifest+MSL,扫全库 combo 变体)。`brew install glslang spirv-cross`。
- 运行:`Sources/.../WEEffectChain.swift` 加载 manifest、编译真 WE shader、按真实参数喂 uniform、多 pass 合成。`SceneRenderEngine.weVerified` 白名单控制哪些走真 shader。`--testeffect <eff> <out>` 隔离验证。build.sh 打包进 app。
- **两个致命坑**(见 memory `we-shader-transpile`):① spirv-cross 的 MSL 资源索引 ≠ SPIR-V binding,**必须解析 MSL 签名拿真实 [[texture(N)]]**;② MASK 是隐式 combo(分配遮罩→MASK=1)。

## 已照 WE 做对的(别再当 bug 改)

- **折射粒子**:已照 `genericparticle.frag` REFRACT 分支做。多 pass:层+非折射粒子渲到离屏
  `refractSceneTex`(= WE `_rt_FullFrameBuffer`)→ 折射粒子单独 pass 用 `particle_refract_fragment`
  采样底图:`color.rgb = albedo*v_Color*底图(screenUV+法线偏移)`。法线贴图取材质 `textures[1]`。
  偏移按粒子屏占比缩放(对应 WE `v_ScreenTangents`)。仅在场景含折射发射器时走多 pass,其余单 pass 不变。
- **粒子精灵表帧**:`currentFrame = floor(lifeProgress × numFrames)`,按每粒子生命周期推进(非墙钟)。
- **粒子混合**:用材质真实 `blending`,解析失败退 translucent(不再强转 additive)。
- **纹理容器 padding(关键!)**:.tex 的 TEXI 头有 7 个 int:format, flags, **textureW/H(容器,pow2)**,
  **imageW/H(真实图像)**, unk。容器是 pow2(如 4096×2048),真实图(3840×1080)在**左上角**,
  右/下是 padding。必须按 imageW/imageH 裁掉 padding,否则 uv[0,1] 采到灰边 → 壁纸右下露灰。
  见 `TexDecoder.finish()`。之前忽略了 imageW/H,导致超宽壁纸只铺到屏幕一半。
- **画布↔屏幕宽高比**:画布宽高比 ≠ 屏幕时用 **cover**(等比放大铺满 + 裁掉溢出边,不拉伸),
  在顶点着色器对 NDC 乘 `ndcScale`。宽高比一致时为单位、零影响。见 `SceneRenderEngine.encodeFrame`。
- **父子层级变换**:子 origin 在父局部空间,换算到世界要逐级「乘父缩放 + 加父原点」,有效缩放 =
  自身 × 所有祖先缩放。只累加不乘缩放会让带缩放容器的子元素(时钟挂件的月相/文字)散开。
  见 `SceneModel.absoluteOrigin/absoluteScale`。
- **脚本驱动文本层**:WE 用 JS 填充时钟/日期/星期/问候/正在播放歌曲等。我们不跑 JS,但
  按系统时间算得出的(clock/date/dayOfWeek/greeting)就算出来照显;算不出的(歌名/艺术家,
  其 `value` 只是占位 "Text Layer"/"<Date>")**跳过不画**,绝不显示占位串。月相 ☾ 等是静态
  文本层,照常渲染。判定见 `SceneModel.parseTextLayer`。

- **相机视差**:照 lwe `CScene.cpp:394-406` + `CImage.cpp:1097-1106`。每帧
  `displacement = mix(displacement, (mouseUV−0.5)×amount×influence, clamp(cameraparallaxdelay×dt秒,0,1))`(带时间平滑),
  逐层 `off = (parallaxDepth+amount)×displacement×sceneWidth`(**x/y 都乘 width**,非各轴)。删了旧的 `0.03`/`0.02`
  像素换算魔法系数与瞬时跟随。方向沿用本引擎负号约定(lwe 自身坐标系符号不适用,同 matModel rotate 取负的教训)。
  parallaxStrength 滑块作整体强度乘子(默认 1=纯 lwe)。新增解析 `cameraparallaxdelay`。cameraParallax 开启即计入
  isAnimated(因 +amount 使 depth=0 层也随相机平移)。见 `SceneRenderEngine.parallaxOffset/update`。
- **相机抖动(camerashake)**:**lwe 只在 parser 读 amplitude/roughness/speed,渲染代码一行都没用**(grep 全库确认)。
  无真实公式可移植 → **不渲染**(对齐 lwe),删掉了旧的自造 `0.02+双频值噪声`。字段仍解析存下备查。
- **相机级 bloom(general.bloom)**:WE 的 bloom 是相机内建后处理,**无 `effects/bloom` 文件夹** → 永远进不了
  manifest/postChain。照 lwe(`WallpaperApplication.cpp:106-132` vfs `bloomeffect.json` + `CScene.cpp:135-151` 的
  `_rt_4/_rt_8/_rt_Bloom` FBO)移植**真 4-pass**:downsample_quarter_bloom(全→¼:2×2 box+亮度阈值+饱和度提升)
  → downsample_eighth_blur_v(¼→⅛:X 向 13-tap 高斯)→ blur_h_bloom(⅛→⅛:Y 向)→ combine(场景+bloom)。全用
  WE 自带 `materials/util` 真 shader(非自造)。由 `general.bloom=true` 触发(此前 parsePostProcess 只看
  fullscreenlayer 的 bloom 特效 → 相机级 bloom 被**静默丢弃**)。strength/threshold/tint 取 general 真值,缺省
  2/0.65/(1,1,1)(=真 shader 注解默认)。见 `PostProcess.swift`。

## 已知未照 WE 的地方(待补,别假装做对了)

## 鼠标涟漪(cursorripple)架构(2026-06-02 排查清楚,关键!)

cursorripple 在 WE 里挂在一个 **projectlayer(组合层)**上(`models/util/projectlayer.json`),它**只折射该
projectlayer 在渲染序中**下方**的层**,上方的层(草地/前景/UI)完全不受影响。这就是 WE 把涟漪限定在水道的
真正机制 —— **靠层序,不是靠遮罩**(实测 3680422061:bg1 水底图在下→被折射;咕咕嘎嘎草地层、gu* 草丛、
时钟都在 projectlayer 之上→不折射)。该 effect 自带的 simulate_force opacitymask 往往是空的(全黑+默认点)。

本引擎不渲染 projectlayer,而是把 combine 全局套层——故必须用 `SceneDocument.cursorRippleLayerCutoff`
(= projectlayer 出现时已解析的层数)在 encode 时只对 `layers[0..<cutoff]` 套折射。见 `SceneModel.build`
记 cutoff、`SceneRenderEngine.encode` 的 `li < cursorRippleCutoff`。

**两个曾犯的错(都已修)**:
1. **强度不能乘进 sim 力场**:力场是逐帧 ping-pong 反馈的持久量,`force *= ripplestrength`(<1)会每帧复合
   → 几帧归零 = "完全不涟漪"。WE 的 `g_RippleStrength` **只用在 combine 折射**(`off=dir×-0.1×ripplestrength`)。
2. **不能按"有遮罩"判定折射哪层**:草地层也带遮罩(foliagesway/waterripple),按遮罩判定会让草地起波。
   必须按层序(cutoff)。

simulate_force 力场组合已照搬 WE 真值(`force.xzy+=up` 等 ×1/3);apply_force 半径 `60/scale`=真 `v_PointDelta.y`;
combine 照 `cursorripple_combine.frag`(`off=dir×-0.1×ripplestrength`)。强度过强只能调 combine,绝不调 sim。

## 已知未照 WE 的地方(待补,别假装做对了)

- **粒子朝向**:我用「速度大就 atan2(vel) 对齐」的近似;WE 是 rotation 数据驱动 + trail renderer 才按速度。够用但非精确。
- **折射偏移幅度**:WE `v_ScreenTangents` 含粒子完整屏幕切基;我用粒子屏占比近似缩放(机制对、幅度近似)。
- **音频条透视**:perspective 4 角投影未实现,频谱条还是平铺。

## 格式规格

见 memory `we-scene-format` / `we-builtin-assets`:scene.pkg / .tex(含 TEXS 精灵表段) / 父子图层 / cameraparallax 等。
