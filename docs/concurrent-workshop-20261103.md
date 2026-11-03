# 创意工坊并发下载与界面更新

## 行为

- 默认同时执行 3 项，超过的按加入顺序排队；完成或取消后补充空闲槽位。
- 每项拥有独立的 SteamCMD 输出、HOME、内容日志和可续传暂存目录。运行时固定为 3 份，复用在应用缓存中；不把 SteamCMD 打进发行包。
- 仅初始化和登录串行，文件传输并行，避免 macOS Steam IPC helper 同时初始化时竞争。独立 HOME 必须能找到用户已安装的 Steam IPC helper；复用助手入口，配置与日志仍各自独立。
- 60 秒未进入命令、180 秒无真实块增长会重启本项并重试一次。登录本身有 90 秒上限。失败保持可见，支持手动继续下载，保留原来的暂存数据。
- 取消、退订和移除先等待本项 worker 退出，再清理本项文件；不等待或终止其他下载。槽位由实际 worker 退出释放。
- 完成记录保留到手动清除。进度和速度按任务关联，不再根据文件大小猜测全局日志归属；界面不再外推虚假百分比。

## 界面

原生 SwiftUI 页面使用低饱和青色、深色分层背景、预览卡片、类型导航、独立详情栏和下载中心。卡片与详情保留「订阅并下载 → 取消订阅并删除」的统一状态。下载中心显示并行数、等待数、各项进度与错误，并可单独取消或重试。

设计调研只参考公开界面与交互层级，未复制第三方代码、标志或素材：

- [Lively Wallpaper](https://github.com/lively-community/lively)：官方 `resources/figma_promo_16x9.jpg` 中的搜索、图片网格和功能层级。
- [Equinox](https://github.com/rlxone/Equinox)：官方 `repo/screen.png` 中的 macOS 面板、留白、圆角和操作布局。

## 验证

- Swift 完整测试：117 项，其中 114 项通过、3 项显式开启的外部网络验收默认跳过。
- 使用真实子进程测试 3 项同时运行，第 4 项等待，取消一项后其余完成、空闲槽位继续调度。
- 两项总大小相同的下载分别写自己的日志与 patch，确认进度分别为 25% 和 75%，不会串项。
- 使用停滞子进程验证自动重试有界，健康任务能够继续完成。
- 最后再次运行下载器专项测试：14 项，12 项通过、2 项外部网络验收默认跳过。
- Release 已部署到 `/Applications/LiveWallpaper.app` 并重启；已核对开发包与安装包可执行文件 SHA-256 相同。通过原生 UI 检查下载中心开关、筛选弹出位置、详情打开与关闭，订阅按钮保持可见。
- 真实 Steam 下载验收使用独立临时壁纸库，不修改用户的 Steam 订阅和现有壁纸。实际吞吐仍受 Steam CDN 与代理连接影响；一次早期验收中一项完成，另一项连接停滞，触发重试。随后用串行冷启动的最终实现复验通过：Phoenix - Halloween 与 MeiMei in Snowy Street 两项先后完成；传输时段确实重叠，其中一项无进度后自动重试成功。总验收耗时 310.5 秒，完整性检查确认主文件均已落盘。

运行网络验收：

```sh
LW_PARALLEL_STEAMCMD_INTEGRATION=1 DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter WorkshopDownloaderTests.testLiveParallelIsolatedSteamCMDDownloads
```
