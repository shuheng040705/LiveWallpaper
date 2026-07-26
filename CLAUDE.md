# LiveWallpaper — 项目铁律与关键约定

## 项目定位

macOS 上的 Wallpaper Engine 兼容动态壁纸渲染器（Swift + Metal）。目标：**完美渲染所有 WE 壁纸**。

## 渲染铁律

- **引擎读 pkg 通用渲染**：绝不逐壁纸硬调、猜位、手工对位。发现问题找通用真因、改底层、全库通用。
- **严格按 pkg 值渲染**：字段缺省时查 WE / lwe 的真实默认值，绝不自创继承、推导或"为好看"的偏差规则。
- **判对错从 pkg 数据逐项核对**：位置 / cropoffset / 对位等必须从 pkg 确切数值逐项推导验证，不靠肉眼比对截图。
- **WE 实渲是最终真值**：lwe 有未实现、退化、不忠实之处，仅作参考、可被推翻。判对错优先以 WE 实渲（pkg preview / 实机截图逐像素 A/B）为准。
  - lwe 参考源码：`/Users/a55555/Developer/reference/linux-wallpaperengine`
- **颜色/亮度差异 ≠ bug**（显示器调色不同）：判壁纸对错看结构，不看颜色。

## 部署（必读）

- 用户跑的是 **`/Applications/LiveWallpaper.app`**。改完必须跑 `./build.sh`（release，自动部署 + 重启）。**只 build 不部署 = 用户跑旧版**。
- 裸 `.build/release` 二进制读默认值；部署版 `.app` 读用户 UserDefaults。**查用户可见行为必须用 .app**。
- 做完直接部署，用户自己判断；不要部署前询问，不要私自撤回。

## manifest 雷区

- **绝不全量重生成 `tools/generated/WEEffects.json`**（会把 2846660316 转坏成噪点）。
- 只用 `tools/we_add_effects.py` **增量追加**。
- `/Applications` 部署版是回滚锚点。
- `tools/generated/` 必须保持 git 跟踪（被 build.sh 消费），不得加入 .gitignore。

## headless 验证陷阱

- `--render` 默认 t=0 会渲到开场白闪层（可能整屏纯白假回归）：须 warmup 100+ 帧或 `--warmrender`。
- 眨眼壁纸须 `WP_BLINK_FORCE=1` 才渲得到闭眼帧。
- 后处理特效 headless 不应用，须实机验证。
- 测黑边须显式 `WxH` 分辨率参数（如 `1728x1117`），`--render 9999` 测不出黑边。

## 测试

- Swift：`swift test`（Tests/LiveWallpaperTests）
- Python 工具：`python3 -m unittest discover tools/tests`

## 沟通约定

- 对用户提壁纸一律用 project.json 的 **title 名字**，不甩 workshop 数字 id（代码/路径里继续用 id）。
