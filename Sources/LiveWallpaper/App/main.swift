import AppKit

// 开发期:无界面渲染模式(--render <id> <out.png>),渲染完即退出,不启动 App。
if SceneHeadless.runIfRequested() { exit(0) }
// 开发期:验证转译特效(--testeffect <effect> <out.png>)。
if WEEffectTest.runIfRequested() { exit(0) }

Log.reset()
Log.write("=== LiveWallpaper 启动 ===")

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate

// 菜单栏常驻代理:无 Dock 图标,可弹出窗口。
app.setActivationPolicy(.accessory)
app.run()
