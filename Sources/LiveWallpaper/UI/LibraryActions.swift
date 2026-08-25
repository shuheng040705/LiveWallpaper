import Foundation

/// 主窗口需要的所有回调,集中成一个结构体传递,避免超长参数列表。
/// 由 AppDelegate 填充,把 UI 操作接到运行中的渲染器/轮换器/系统。
struct LibraryActions {
    var onSelect: (WallpaperItem) -> Void          // 应用某张壁纸
    var onMuteChanged: (Bool) -> Void
    var onVolumeChanged: (Double) -> Void
    var onRotationChanged: () -> Void              // 轮换偏好变了 → 重排定时器
    var onLoginChanged: (Bool) -> Void
    var onPowerChanged: (Bool) -> Void
    var onAssetsPathChanged: () -> Void            // WE 资源目录变了 → 重载当前 scene
    var onLibraryRootChanged: () -> Void           // 壁纸库目录变了 → 重新扫描
    var onNext: () -> Void                         // 立即换一张
    var onTogglePause: () -> Void                  // 暂停/继续
    var onClear: () -> Void                        // 关闭当前壁纸
    var onQuit: () -> Void
    var isPaused: () -> Bool
    var onVideoFillChanged: (Bool) -> Void         // 视频填充模式
    var onMainScreenOnlyChanged: (Bool) -> Void    // 仅主显示器
    var onDesktopIconsChanged: (Bool) -> Void      // 桌面图标显示
    var onDelete: (WallpaperItem) -> Void          // 仅卸载本地壁纸(移到废纸篓)
    var onApplySettings: (WallpaperItem) -> Void   // 壁纸属性改了 → 若正在播放则重载使其生效
    var onUnsubscribe: (WallpaperItem) -> Void     // Steam 退订成功后再卸载本地壁纸
}
