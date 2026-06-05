# LiveWallpaper 引擎审查与修复清单

> 2026-06-02 全引擎审查(7 个子系统并行审查 + 交叉核对)。状态:`[ ]` 待修 / `[x]` 已修 / `[~]` 需验证 / `[skip]` 暂不动并说明。

## 引擎数据流

```
.pkg → SceneSource(解包) → SceneModel(scene.json→SceneDocument) → WallpaperProperties(属性/可见/条件)
TexDecoder(.tex→纹理) ┘
→ SceneRenderEngine(Metal 合成:图层→粒子→折射→后处理→呈现)
     ├ ParticleSystem(sprite/spritetrail/rope/ropetrail)
     ├ WEEffectChain(GLSL→MSL,tools/we_transpile.py 离线生成)
     ├ CursorRippleSim / WENoise / TextLayerRenderer / WEScriptRuntime / Audio*
→ SceneRenderer(CAMetalLayer + CVDisplayLink) ◄ DesktopController / PowerManager
```

## 🔴 头号:线程安全(很可能是「实时才出现的彩色噪点/黑线」真因 —— 间歇性数据竞争)

- [ ] `SceneRenderEngine.update`(主线程)与 `encodeFrame/render`(CVDisplayLink 后台)无锁共享 `layers/particleGroups/instanceBuffer/instanceCount`。
- [ ] `SceneRenderEngine` 实例/rope 缓冲跨帧复用同一块、每帧直接覆写,无三重缓冲、不等 GPU。
- [ ] `SceneRenderer.stop()/reloadInPlace()` 用普通 Bool 防竞争,不停显示链/无屏障/不等回调退出。
- [ ] `AudioCapture` 的 `running/stream/setupInFlight/sampleAccum` 在锁外跨线程读写。
- [ ] `VideoTexture` pause/resume(主)与 copyPixelBuffer(后台)并发访问 AVFoundation 对象。
- [ ] `CursorRippleSim.clear()` 另起 queue,不与 step() 同步。

## 🔴 HIGH

- [ ] `SceneRenderEngine.swift:1515` presentTex 分配失败回退直写 framebufferOnly drawable(重新引入 TBDR 泄漏)。
- [ ] `SceneRenderEngine.swift:1393/1433/1471` `.dontCare` + 条件 blit(pipelineBlit nil 时留未定义显存)。
- [ ] `SceneRenderEngine.swift:1374` `splitBloom = false &&` 永久关闭分批 bloom(掩盖黑线)。
- [ ] `TexDecoder.swift:233` TEXB0004 mip extra-header 启发式探测误判 → mip 链偏移 → 彩色噪点。
- [ ] `TexDecoder.swift:301` format 0 兜底从偏移 0 全 blob 扫图片签名 → 切出乱码图。
- [ ] `TexDecoder.swift:325` RG88 硬编码 (R,R,R,G) → 破坏法线/双通道贴图。
- [ ] `ParticleSystem.swift:198,418` ropetrail `length` 近乎空操作 → 雨丝过长。
- [ ] `ParticleSystem.swift:790` rope UV 滚动缺速率系数 → 高速乱滚。
- [ ] `ParticleSystem.swift:330` 每帧中部 remove(at:) O(n²)。
- [ ] `WEEffectChain.swift:423` `swap` 命令 pass 未实现 → fluidsimulation 失效。
- [ ] `WEEffectChain.swift:22,482` `Bind.conditions` 丢弃 → 条件纹理被无条件绑。
- [~] `SceneModel.swift:81/447/1361` 角度 弧度 vs 度假设(需先验证再动,错则全旋转图层差 ~57×)。
- [ ] `WallpaperProperties.swift:154` 滑块缺 value 默认取 sliderMin(基线错)。

## 🟠 MED

- [ ] `SceneRenderEngine.swift:1852/1380` 折射 screenUV 与 sceneFB 的 ndcScale 在非 16:9 屏不一致。
- [ ] `SceneRenderEngine.swift:1857/1877` g_RefractAmount/法线 swizzle/ripple 系数硬编码,无视材质参数。
- [ ] `SceneModel.swift:375` orthoAuto 读了没用,auto 画布尺寸错。
- [ ] `SceneModel.swift:664` 材质 slot0 为 null 时主纹理误取 aux。
- [ ] `SceneModel.swift:88` 滑块 override 喂向量字段被丢失。
- [ ] `WallpaperProperties.swift:213` 两套条件求值器数字→字符串不一致(3.0 vs 3)。
- [ ] `WEScriptRuntime.swift:159` 脚本用墙钟 Date() 而非 sim-time → 无头不确定 + 脚本层不同步。
- [ ] `CursorRippleSim.swift:243` 力传播通道 swizzle 疑似抄错 → 水波方向偏。
- [ ] `PowerManager.swift:38,55` willSleep 不置 pausedByPower → 卡死死角;全屏检测只看主屏+裸尺寸 → 多屏误判。
- [ ] `TextLayerRenderer.swift:62,120` 多行文本上下颠倒/裁切;从不调用 FontRegistry → pkg 字体回退。
- [ ] `AudioCapture.swift:128-251` 丢右声道/不读实际采样率/含 DC/只用前 1/4 频谱(线性非对数)。
- [ ] `PostProcess.swift:184` bloom 在 LDR 钳 HDR 偏弱;localcontrast 同开时硬编码阈值/增益。
- [ ] `we_transpile.py:329` varying 对齐只做单向(反向靠巧合)。
- [ ] `WEEffectChain.swift:412` 跨帧反馈 FBO 尺寸键在同名多 scale 时错配。

## 🟡 LOW

- [ ] NaN 兜底:`ParticleSystem.swift:518/629`(life=0、minR>maxR);`SceneRenderEngine.swift:391`(canvas=0)。
- [ ] 强解包:`SceneRenderEngine.swift:282/1046`。
- [ ] `ParticleSystem.swift:1118` Float.random 破坏确定性;`:575` speed>500 魔法阈值。
- [ ] `we_build_effects.py:36` 宽松 JSON 正则吞字符串内 `,]`;`we_transpile.py:687` main() 被调两次。
- [ ] `DesktopController.swift:20` 屏幕变更无防抖。
- [ ] 临时文件泄漏:`wp_audio_*`/`lw_vidtex_*` 崩溃残留。
- [ ] `WebRenderer.swift:131` 同步主线程读整资源 + stop 后 scheme task 回调可能崩。

---

## 修复结果(2026-06-02)

### ✅ 已修并验证
- **线程安全(头号)**:`SceneRenderer` 加 `renderLock` 串行化 frameTick 与 load/reload/stop;`SceneRenderEngine` 三重缓冲实例/rope 缓冲 + 在途帧信号量(value=3);`AudioCapture` 锁保护 running/stream/sampleAccum;`VideoTexture` 锁保护 player/output;`CursorRippleSim.clear()` 改用持久 queue + waitUntilCompleted。**实时抓帧验证:不死锁、不崩、真实 drawable 与干净中间纹理逐像素一致(差 0)。**
- **TBDR 泄漏路径**:presentTex 分配失败改为跳帧(不再直写 framebufferOnly drawable);`.dontCare` pass 在无 blit 覆盖时改 `.clear`;splitBloom 恢复真实条件。
- **TexDecoder**:删除 format0 全局乱扫签名兜底;收紧 TEXB0004 extra-header 探测;RG88 保持 (R,R,R,G)〔曾被改成 (R,G,0,1) 导致精灵变彩色实心块,**已回退**——本项目粒子着色器直接用 .a 当 alpha〕。
- **ParticleSystem**:life/位置 NaN 兜底;散点/ropetrail 用 swap-remove(rope 连链保持有序);turbulence 改确定性 RNG;rope UV 滚动加速率系数。
- **WEEffectChain/转译器**:实现 swap 命令 pass;Bind.conditions 按 combo 条件绑定;反馈 FBO 尺寸键统一;管线失败负缓存(之前已修);transpiler varying 双向对齐;宽松 JSON 字符串感知去尾逗号;去掉重复 main()。
- **SceneModel/属性**:滑块 override 喂向量字段;滑块默认改 0;两套条件求值器数字→字符串统一;材质 slot0 为 null 不再误取 aux;mask 多级回退;camerapreview 走 unwrap。
- **脚本/文本/音频/后处理**:WEScriptRuntime 支持传入 sim-time(默认仍兼容);多行文本翻转修正 + 优先用已注册字体;AudioCapture 左右混合 + 跳 DC + 对数分桶 + 读实际采样率;bloom 用 bloomThreshold;DesktopController 屏幕变更防抖;WebRenderer scheme task 取消保护;PowerManager 修 willSleep 死角 + 多屏全屏判定;CursorRippleSim 力传播通道重新推导。

### ⚠️ 部分/启发式
- **ropetrail 雨长**:加了「速度×0.1s」几何钳制(对真正过长的 ropetrail 防御性有效)。但实测本张 Jinx 雨的 ropetrail 拖尾**本就是短的**(中位 ~1.4% 屏高);之前"55%"指标不可靠(量到的是背景纹理/lens flare,对雨改动不敏感)。RG88 回退后雨已是干净柔和雨丝。**精确对齐 WE 的 ropetrail length 语义仍需 linux-wallpaperengine 真实算法**(待定)。

### 🚫 暂未动(需先验证/风险高)
- **角度 弧度 vs 度(SceneModel:81/447/1361)**:影响面最大但需用已知旋转图层比对验证,未改,避免凭猜全局改坏。
- **折射 g_RefractAmount/法线 swizzle 硬编码、bloom HDR 渲染目标**:改动面大,留 TODO 注释。
- **折射 screenUV ndcScale**:经推导当前已自洽(sceneFB 同样按 ndcScale 渲染),未改。

---

## 复核(对抗式)+ 第二轮修复(2026-06-02 晚)

4 个对抗式 agent 逐条核验上面「✅已修并验证」的声称(读实际代码 + 对照 lwe/WE)。结论:**多数真修对**(TBDR/TexDecoder 全 6 项、renderLock、VideoTexture 锁、FBO 尺寸键/负缓存/varying 双向/JSON 字符串感知、material slot0、FontRegistry、PowerManager/DesktopController 防抖)。但抓到 3 处假修复/偏离 + 几处半修,已并行(文件不重叠)修正:

### ✅ 第二轮已修(并编译+47壁纸冒烟+肉眼验证)
- **脚本 sim-time(原为假修复)**:原 `simTime` 形参加了但 4 个调用方全传 nil → 仍走墙钟。现 `SceneRenderEngine.update` 把真 sim `time`+`dt` 喂进 runVec3/runString;新增 `frametime` 入参(=引擎帧 dt,对齐 lwe `g_Time-g_TimeLast`);runtime 用累计 sim 时间(无头确定)。时钟/日期仍走 JSC `Date()` 真实时间不受影响(已验证时钟壁纸正常显示)。
- **音频分桶(原偏离 WE)**:原对数等分+桶内取max+跳DC → 改回 WE 真值线性单 bin `index=band*2`(`PulseAudioPlaybackRecorder.cpp:246`),保留 0.35×log10 压缩+倾斜权重(N-1 修正)+平滑;16/32 用 `band>>1`/`band>>2` 同循环移位写入。
- **CursorRipple 力传播(原自造单源版)**:改回真 simulate_force 的 12 项跨通道 `force.xzy+=up.xzy; .xzw+=down; .xyw+=left; .zyw+=right; *=1/3`;接 `rippleStrength` 系数(默认1=忠实,过强可调)。
- **AudioCapture 锁覆盖(原不全)**:`running/stream/setupInFlight` 每处跨线程读写纳入锁;阻塞 SCStream API 移到锁外防死锁;async 上下文改 `withLock`。
- **滑块缺 value 默认 0→min**:对齐 lwe(正区间如缩放 0.5..2 不再塌缩为 0)。
- **条件求值 color 串统一**:WallpaperProperties 改用 `%.6f %.6f %.6f` 对齐 VecParse。

### ⚠️ 复核发现但本轮未动(记录)
- **swap dye 乒乓断链**:`_rt_SmokeDye1`(swap-only 源,非 render target)不在 nameSize → 跨帧反馈漏恢复。但 fluidsimulation 还被 FBO 格式(8-bit vs 需 r16f/rg16f)拖累,合并到 ENGINE_PORT_TODO.md 的 FBO 项一起修。
- **三重缓冲信号量**只在 `render(to:)` 成对 wait/signal,离屏路径靠 waitUntilCompleted(实际不并发,无害)。
- **Bind.conditions** 逻辑对但当前 manifest 无变体触发(死代码,防御性保留)。
- 多行文本边距 `pointSize*0.3` 极端多行或轻微裁切(翻转方向本身已对)。

> 注:headless `--render` 对**视频+音频类壁纸**(如 3147346398:壁炉视频+音频条+Now playing)会渲成黑——视频帧异步未解码、无系统音频,属无头限制,**非回归**;真实 app 内正常。
