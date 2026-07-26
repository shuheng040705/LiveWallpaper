import Foundation

/// 进程级环境变量快照。
///
/// `ProcessInfo.processInfo.environment` **每次访问都重建整份字典**——实测(swiftc -O,本机 53 个 env
/// 变量)单次 24.3 µs,而把字典取出来复用只要 0.022 µs、`static let` 缓存 0.0016 µs(相差 1116× / 14944×)。
///
/// 本工程用 env 做了大量 A/B 逃生开关(`WP_NO_*` / `WP_DBG_*` / `WP_TEST_*`),其中不少写在**渲染线程的
/// 逐层 / 逐特效循环里且 env 判据在最前面**(短路救不了),例如 `update()` 的 `for i in layers.indices`、
/// `encode()` 的 `for li in liLo..<liHi`、`computeLayerEffect` 的 effects 循环。
///
/// 2026-07-26 审计实测:真机采样(壁纸 3742497499、3840×2160 画布、30 fps)渲染线程 5488 个样本里
/// **1659 个(30.2%)落在 `ProcessInfo.environment.getter`**,约 6.9 ms/帧。最贵的单项是
/// `SceneRenderEngine.weDenied`(7.0%,`static var` 计算属性每次重建),其次 `pointerXform`、
/// `WEEffectChain.comboAwareKey`、`computeLayerEffect`、`encode`、`update`。
///
/// 进程内没有任何 `setenv`/`putenv`(已 grep 全仓确认),env 在启动后不会变,所以快照一次与逐次读取
/// **语义完全等价**;env 仍在进程启动时生效,所有 A/B 开关的用法不变。
enum WPEnv {
    /// 启动时读一次的环境变量快照。用法与原来完全相同:`WPEnv.vars["WP_XXX"]`。
    static let vars: [String: String] = ProcessInfo.processInfo.environment
}
