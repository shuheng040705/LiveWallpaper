# WE 3D 场景 HUD/UI 完整渲染 实现计划

> **For agentic workers:** 用 superpowers:subagent-driven-development 或 executing-plans 逐阶段执行。步骤用 `- [ ]` 勾选。每阶段末尾**必须用 headless 渲染 + 肉眼对比**验证后再进下一阶段。

**Goal:** 让两张 WE 3D 透视壁纸(土星 3589454154、太阳系 3662790108)不仅渲出 3D 模型,还正确渲出它们脚本驱动的 2D/标签 UI(时钟/SATURN 文字/Voyager-Cassini 浮空标签/任务栏 dock),达到接近真 WE 的"live"效果。

**Architecture:** 核心架构决策——**对 3D 透视场景,单-context 脚本宿主(`Scene3DScriptHost`)是所有对象属性(变换/文字/可见性/alpha/color)的唯一真相源,逐帧 tick**。渲染器据每个对象的坐标空间分流:3D 模型 + 3D 世界坐标的浮空标签走透视投影(viewProj3D,带深度);屏幕空间 UI(dock)走正交。**3D 场景下绕过 per-layer WEScript 路径**(它每脚本独立 context、没有 shared,根本算不对)。当前代码里"注入 shared 到 per-layer 脚本"是临时补丁,本计划用宿主驱动一切替换它。

**Tech Stack:** Swift + Metal(渲染)、JavaScriptCore(跑 WE 的 JS 脚本)、已有的 `WEScript`(2D 时钟用,每脚本独立 context)、本会话新建的 `Scene3DScriptHost`/`Scene3DRuntime`(单-context,共享 shared)。

---

## 当前状态(2026-06-08,已完成,勿重做)

**已工作并部署**(`WP_3D_HUD` 默认关 → 当前桌面是干净的 3D 模型渲染):
- `Sources/LiveWallpaper/Scene/Model3D.swift`(新文件,367行):
  - `MDLGeometry.parse`:MDLV0023 48字节几何(pos/normal/tangent/uv);**大网格(>65535顶点)索引用 u32**(不是 u16,这是个坑)。
  - `Scene3DScriptHost`:单 JSContext,注册全部对象脚本、共享 `globalThis.shared`,复用 `WEScript.preludeSource/shimSource/stripModuleSyntax`。`tick(runtime,frametime)`/`runInit`/`value(id,prop)`/`sharedJSON()`/`sharedDump()`。
  - `Scene3DRuntime`:解析几何/材质/节点树;`bake(toTime:)` 顺序跑脚本到 settled、`recompute()` 算世界矩阵(`worldsById` 全节点)。
- `Sources/LiveWallpaper/Scene/SceneRenderEngine.swift`:
  - `matPerspective`:**Metal 深度约定 [0,1]**(不是 OpenGL [-1,1],否则近半球被裁=半个行星)。
  - 3D 属性块(搜 `models3D`/`scene3DRuntime`/`pipeline3DOpaque`/`depthTex3D`/`build3DModels`/`render3D`/`U3GPU`)。
  - `model3d_vertex`/`model3d_fragment`(shaderSource 里):MVP + baseColor×Color×brightness。
  - `load()`:`document.camera.isPerspective` → `build3DModels`,默认清空 layers 早返回(`WP_3D_HUD==nil`);烘焙到 `WP_3D_TIME`(默认20s)= 土星居中好构图。
  - `encodeFrame`:`if has3DScene { render3D; (WP_3D_HUD时叠2D); return }`。
- `Sources/LiveWallpaper/Renderers/SceneRenderer.swift:77`:**已修 preview-fallback bug**——`layerCount==0 && !engine.has3DScene` 才回退预览(否则 3D 场景被误判加载失败→显示 preview.gif 那"两张图循环")。
- `WEScriptRuntime.swift`:`preludeSource`/`shimSource` 改 internal;加了 `WEScript.injectShared(json)`(临时补丁,本计划会替换)。

**调试钩子**(env):`WP_3D_HUD=1`(开2D叠加,目前不工作)、`WP_3D_TIME=<秒>`、`WP_3D_LIVE=1`、`WP_NO_3D_SCRIPTS=1`、`WP_3D_SOLO=<名字>`、`WP_3D_HUD_LOG=1`、`WP_3D_LABEL_K=<系数>`。

**已验证的关键事实**:
- 宿主跑完 Main 模拟后 `shared` 有 **324 键**(sun_D_real/txh_deg/各行星位置/dock 屏幕坐标 target_posx_r8 等)——数据齐全,可行性已证。
- HUD 文字层(simtime2/dis/ang/SYKM/Voyager/Cassini 共8个)的位置是 **3D 世界坐标**(如 (-0.36,-0.288)),不是屏幕像素 → 必须透视渲染。
- per-layer 2D 脚本报 `shared.sun_D_real undefined`(独立 context 无 shared)→ 文字算不出。
- 注入 shared + 透视渲染都试过但 HUD 仍不显示(文字空 / 坐标系未吃透)——**不要重复这条试错路**,按本计划的"先吃透约定再写"。

---

## 已知未决问题(必须先调查,见 Phase 1)

1. **坐标空间判据**:一个 3D 场景的 2D 层,怎么判定它是「3D 世界浮空标签」(透视渲染)还是「屏幕空间 UI/dock」(正交渲染)?候选:看该层 origin 脚本返回值量级 / 看父链顶端是不是相机锚 / WE 的 `perspective` 字段。**必须实际扒 pkg + 读 lwe CImage 确认,不能猜。**
2. **3D 标签的尺寸与朝向**:浮空文字是「世界尺寸的 3D quad」还是「世界位置 + 屏幕固定尺寸的 billboard」?WE 文本在 3D 场景怎么定大小。
3. **文字内容时序**:文字脚本读 shared.X,这些值哪些是 bake 时就定的、哪些要逐帧。先用 bake 快照(静态文字)够不够像。
4. **dock auto-hide**:dock 由鼠标 hover 触发显隐(target/current_pos),静止时是否本就隐藏(那就不用渲)。
5. **逐帧性能**:765 脚本逐帧 tick 多慢(土星75可行,太阳系765可能要节流/烘焙)。

---

## File Structure

| 文件 | 职责 | 改动类型 |
|---|---|---|
| `Sources/LiveWallpaper/Scene/Model3D.swift` | MDLV几何 + 单-context 宿主 + 运行时;**扩展**宿主算 text/bool/scalar 结果、暴露逐帧求值接口 | 修改 |
| `Sources/LiveWallpaper/Scene/Scene3DLayers.swift` | **新建**:3D 场景的 2D/标签层描述(id/坐标空间/文字源/可见源)+ 从宿主求值 | 新建 |
| `Sources/LiveWallpaper/Scene/SceneRenderEngine.swift` | 3D 渲染 pass:模型(已有)+ 透视标签 pass + 屏幕 UI pass;逐帧 tick 宿主 | 修改 |
| `Sources/LiveWallpaper/Scene/WEScriptRuntime.swift` | 清理临时 `injectShared`(被宿主路径取代) | 修改/清理 |
| 调试脚本 `Tools/probe_3d_hud.py` | **新建**:扒某 3D 壁纸的 2D 层坐标/父链/脚本,辅助 Phase 1 调查 | 新建 |

---

## Phase 0:基线快照与回归护栏

- [ ] **Step 1:确认当前 3D 模型渲染基线**
  Run: `.build/release/LiveWallpaper --render 3589454154 /tmp/p0_sat.png 1280 5`
  Run: `python3 -c "from PIL import Image;import numpy as np;a=np.asarray(Image.open('/tmp/p0_sat.png').convert('RGB'));print((a.max(2)>20).mean()*100)"`
  Expected: ≈21.9(居中土星)。**这是回归基线:后续任何阶段后土星模型本身不能比这差。**

- [ ] **Step 2:确认 2D 壁纸零回归基线**
  Run: `.build/release/LiveWallpaper --render 3718176724 /tmp/p0_2d.png 800 2`
  Expected: 非黑≈99.9。**3D 改动绝不能碰 2D 路径。**

- [ ] **Step 3:commit 基线说明(无代码改动,仅本计划文件)**
  ```bash
  git add docs/superpowers/plans/2026-06-08-3d-scene-hud-ui.md
  git commit -m "docs: 3D HUD/UI 分阶段实现计划"
  ```

---

## Phase 1:调查——吃透 2D 层在 3D 场景的坐标空间约定

> 本阶段**不写渲染代码**,只产出「判据 + 数据表」。这是之前试错失败的根因,必须先做。

- [ ] **Step 1:写 `Tools/probe_3d_hud.py`**——扒土星 3589454154 的全部**非 model 对象**(2D/text),输出每个:id/name/有无 image/有无 text(脚本?)/origin(静态值或脚本)/parent/parent 链顶端 id。复用本仓库其它 probe 脚本的 `read_pkg`。
  验证:打印出 simtime2/dis/ang/SYKM/Voyager/Cassini/各 dock 图标(r1-r8/l1-l8/o)/clock/SATURN 的完整链。

- [ ] **Step 2:读 lwe 怎么处理 3D 场景的非模型层**——`/Users/a55555/Developer/reference/linux-wallpaperengine`,搜 `perspective`/`CImage` 的投影选择。lwe 大概率不支持 3D 场景(强 require orthogonalprojection),但确认它对每个对象的 model/view 矩阵怎么搭(有没有 per-object 的「屏幕空间 vs 世界空间」标志)。

- [ ] **Step 3:实测分类**——用 probe 数据 + 宿主算出的每层 `value(id,"origin")` 和 `worldsById[id]`,把每个 2D 层归类:**(A) 3D 世界标签**(world xy 量级 <~10,父链接到 3D 相机锚)/**(B) 屏幕 UI**(origin 是画布像素量级 100s-1000s,如 dock target_posx)。产出一张分类表写进本文件。
  验证:每个可见 2D 层都有明确 A/B 归类 + 它的位置来源(宿主哪个值)。

- [ ] **Step 4:确定判据**——从分类表反推一个**通用判据**(不是逐层硬编码):如「该层主 quad 的 world 平移落在相机视锥的世界尺度内 → A;否则按画布像素 → B」。写进计划 + 在 probe 脚本里实现一个 `classify(layer)` 函数验证全 8 文字层 + dock 都分类正确。
  **Phase 1 出口:有判据 + 全层分类表,经数据验证。** commit。

### Phase 1 结论(2026-06-08 已完成,`Tools/probe_3d_hud.py`)
**判据 = 父链顶端容器**(probe 的 chainTop):
- **A 族 3D 浮空标签**:chainTop = 3D 场景根(土星里 id=459,或 703/705/711 等 3D 标签锚)。origin 是**微小世界坐标**(26.73=(-2.2,0.04),Voyager=(0,0.06))。→ 透视渲染 `viewProj3D × 宿主worldsById[id] × billboard`。成员:`26.73`(读txh_deg)、`SYKM`、`Voyager 1`、`Cassini`。
- **B 族屏幕 HUD/dock**:chainTop = UI 根 id=395「Sykm UI 4k」。origin 是**画布像素**(clock 局部 (0,120),Volume (-300,42),dock dr (1920,1080) = 3840×2160 画布中心)。→ 正交渲染 `matOrtho(3840×2160) × 画布空间位置`。成员:**clock、SATURN、Volume、DATE、DAY、95%(读audio_v)、IFO、simtime1/2、dis(读sun_D_real)、ang(读txh_deg)、48个 dock 图标(r1-8/l1-8/dr1-8/dl1-5/o/do/icontmd)**。

**关键坑**:宿主 `worldsById[id]` 用 3D-TRS 算,对 B 族(UI 根在 3D 里被缩到 ~0.001)给的是**微小 3D 值,不是屏幕坐标**(simtime2 worldXY=(-0.36,-0.288) 而局部 origin 是 (-300,-40))。所以:
- A 族:用 `worldsById[id]`(3D 世界)→ 透视。
- B 族:**不能用 worldsById**;要单独算「画布空间链」= 从该层沿父链累加到 UI 根 395(每节点的局部 origin:脚本节点用宿主 `value(id,"origin")` 的脚本返回=画布像素,静态节点用静态值;平移为主,scale 用于 hover),UI 根当屏幕锚(identity)→ 正交渲染。
- 画布尺寸:B 族用 **3840×2160**(dock 在 1920,1080=中心证实),不是 1920×1080 fallback。

**判据通用性**:不硬编码 id——找**所有 parent=None 的顶层容器**,其子树 origin 量级是画布像素(>~50)的=UI 根(屏幕族);其子树是微小世界坐标的=3D 根。土星里 459=3D 根、395=UI 根、703/705/711=3D 标签小锚。太阳系同理(Phase 6 验)。

---

## Phase 2:宿主成为 3D 场景 2D 层的唯一真相源(文字 + 位置 + 可见性)

- [ ] **Step 1:扩展 `Scene3DScriptHost` 求值非 Vec3 结果**——`tick()` 时对每个脚本,除存 Vec3 外,也存其 String 返回(文字)和 Bool 返回(可见)。加 `textValue(id)->String?`、`boolValue(id,prop)->Bool?`。
  验证(单测式):headless 跑土星,Log 打印 simtime2/dis/ang/SYKM 的 textValue → 应是非空字符串(如距离数字/"SYKM"),不再是空。

- [ ] **Step 2:新建 `Scene3DLayers.swift`**——`struct Hud3DLayer { id; space: .world|.screen; texture源(text→CoreText渲 or image贴图); sizePx; }`。从 `Scene3DRuntime` + Phase1 判据构建可见 2D 层列表(排除 model 对象、排除 vis=false)。文字纹理走现有 `TextLayerRenderer`(传宿主算的字符串,不走 per-layer WEScript)。
  验证:Log 打印构建出的 Hud3DLayer 列表(每个 id/space/有无文字纹理)。

- [ ] **Step 3:删除临时 `injectShared` 路径**——`SceneRenderEngine.load()` 里的注入块、`WEScript.injectShared`、`encodeFrame` 里的透视 mvp 试验块,全删(被 Phase2/3 的宿主驱动取代)。
  验证:编译过;`WP_3D_HUD` 默认仍是干净 3D 土星(回归 Phase0 Step1)。

---

## Phase 3:渲染——透视浮空标签(空间 A)

- [ ] **Step 1:决定标签变换**(据 Phase1 Step2 的 WE 约定):浮空标签 mvp = `viewProj3D × T(worldPos) × billboard(面向相机) × S(worldSize)`。worldSize 从该层 size + WE 文本尺寸约定推。先实现「固定面向相机的 billboard」。
- [ ] **Step 2:在 `render3D` 后加「标签 pass」**——对 space==.world 的 Hud3DLayer,用透视 mvp 画文字纹理 quad(alpha 混合,深度只读或关——标签通常浮在最前)。
  验证:headless 土星 → Voyager/Cassini/距离/角度 等标签**出现在土星旁的合理 3D 位置**(肉眼对比 WE preview)。这是第一个可见里程碑。`WP_3D_LABEL_K` 仍可调尺寸。

---

## Phase 4:渲染——屏幕空间 UI / dock(空间 B)+ auto-hide

- [ ] **Step 1:判断 dock 静止可见性**——据 Phase1 Step4 + 宿主的 current_opa_*/current_pos_*:静止(无鼠标)时 dock 是否本就隐藏。若隐藏 → 本阶段只需「鼠标进入时显示」(可暂缓,记为已知缺口)。
- [ ] **Step 2:屏幕 UI 正交 pass**——对 space==.screen 的层,用 `matOrtho(canvas)` + 宿主算的屏幕坐标画。clock/SATURN/Volume/date 若是屏幕空间在此出现。
  验证:headless 土星 → 屏幕 HUD(若静止可见)出现在正确屏幕位置。

---

## Phase 5:逐帧 live(时钟跳动 / 自转 / 标签数值更新)

- [ ] **Step 1:逐帧 tick 宿主**——`render3D`/`update()` 里,土星(脚本≤200)每帧 `host.tick(elapsed,dt) + recompute()`;太阳系(765)节流(每 N 帧 或 烘焙)。性能实测(warmrender 帧率)。
- [ ] **Step 2:文字/可见/位置每帧取宿主值**——Hud3DLayer 每帧从宿主刷新文字纹理(变了才重渲)+ 变换。
  验证:`--warmrender 3589454154 out 600 1280` 跨帧 → 时钟数字变化、标签数值更新(对比两帧)。

---

## Phase 6:太阳系 + 收尾

- [ ] **Step 1:太阳系 3662790108**——同管线跑,行星极小(scale 0.001-0.02,真比例)→ 主视觉是轨道线/标签/dock;验证非黑且 UI 就位。
- [ ] **Step 2:默认开启**——验证稳定后把 3D-HUD 从 `WP_3D_HUD` 门控改默认开(2D 壁纸仍零影响:has3DScene 门控)。部署 + 用户实机判。
- [ ] **Step 3:polish**——bloom(sun brightness10 发光)、cullmode/alphawriting honor、标签朝向/尺寸微调对齐 WE。

---

## 验证总则(每阶段必做)
- **headless `--render <id> <out> 1280 5`** 出图肉眼对比 WE preview(`pkg/preview.jpg|gif`)+ 用户截图。
- **回归**:土星模型基线非黑≈21.9 不退;2D 壁纸(3718176724)非黑≈99.9 不退。
- **实机**:阶段里程碑后 `./build.sh release` + 重启 app + 用户看(headless 会骗人——preview-fallback 那个 bug 就是 headless≠live 的教训,见当前状态)。
- 跨帧动画用 `--warmrender <id> out <N> 1280`(顺序跑 N 帧写末帧)。

## 风险与边界
- 太阳系是 230KB Main 模拟 + 765 脚本的完整 app;**stub thisLayer/thisScene 下 sim 可能不完全保真**(相机/某些值偏),接受「尽量接近」而非像素级。
- 真 WE 的文本/标签 3D 约定若 lwe 没有参考,需从 pkg 数据反推 + 实机对齐(同本仓库一贯做法:扒 pkg、对 WE 实测、不靠记忆)。
