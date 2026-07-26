#!/bin/bash
# 把 LiveWallpaper.app 打包成可分发的 DMG(路 A:无 Apple 公证,自带去隔离助手)。
# 用法: ./build.sh release && ./makedmg.sh
# 因为没经 Apple 公证,别人下载后双击 app 会被 Gatekeeper 拦("已损坏/无法验证开发者")。
# 故 DMG 内放:① 一键安装并打开.command(自动复制到 /Applications + 去隔离 + 打开)
#             ② 如何打开.txt(手动步骤,兜底)。
set -e
cd "$(dirname "$0")"

APP="LiveWallpaper.app"
VOL="Live Wallpaper"
DMG="LiveWallpaper.dmg"
STAGE="dmg_stage"

[ -d "$APP" ] || { echo "找不到 $APP,先运行 ./build.sh release"; exit 1; }

echo "==> 准备 DMG 内容"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"   # 软链,支持拖拽安装

# ① 一键安装并打开(用户右键→打开 这个 .command;它复制 app 到 /Applications、去隔离、打开)
cat > "$STAGE/① 一键安装并打开.command" << 'CMDEOF'
#!/bin/bash
# 双击(或右键→打开)我:自动安装 LiveWallpaper 并去除「已损坏」拦截。
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
echo "正在安装 LiveWallpaper ..."
killall LiveWallpaper 2>/dev/null || true
sleep 1
rm -rf "/Applications/LiveWallpaper.app"
cp -R "$HERE/LiveWallpaper.app" "/Applications/"
# 去除隔离属性(关键:消除「已损坏/无法验证」拦截)
xattr -dr com.apple.quarantine "/Applications/LiveWallpaper.app" 2>/dev/null || true
echo "安装完成,正在打开 ..."
open "/Applications/LiveWallpaper.app"
echo ""
echo "✅ 已打开。首次运行请到 系统设置 → 隐私与安全性 → 屏幕录制,勾选 LiveWallpaper(用于音频可视化壁纸)。"
echo "(此窗口可关闭)"
CMDEOF
chmod +x "$STAGE/① 一键安装并打开.command"

# ② 手动说明(兜底)
cat > "$STAGE/② 如何打开(必读).txt" << 'TXTEOF'
【LiveWallpaper 安装说明】

本应用未经 Apple 公证,首次打开会被系统拦截(显示"已损坏"或"无法验证开发者"),
这是 macOS 对未公证应用的正常拦截,不是病毒,按下面任一方法即可正常使用。

== 方法一(最简单):==
右键点击本窗口里的「① 一键安装并打开.command」→ 选择"打开"→ 再点"打开"。
它会自动把 LiveWallpaper 装到「应用程序」并打开。

== 方法二(手动):==
1. 把 LiveWallpaper 拖到右边的「应用程序(Applications)」文件夹。
2. 打开「终端」(在 启动台→其他 里),粘贴这行并回车:
   xattr -dr com.apple.quarantine /Applications/LiveWallpaper.app
3. 到「应用程序」里双击 LiveWallpaper 打开。

== 首次运行授权 ==
打开后,到 系统设置 → 隐私与安全性 → 屏幕录制,勾选 LiveWallpaper
(用于捕获系统音频驱动音频可视化壁纸,不会录制/上传任何屏幕内容),然后重新打开应用。

== 注意 ==
本版本仅支持 Apple 芯片(M1/M2/M3/M4 等)的 Mac;Intel 芯片暂不支持。
TXTEOF

echo "==> 生成 DMG"
hdiutil create -volname "$VOL" \
    -srcfolder "$STAGE" \
    -ov -format UDZO \
    "$DMG"

rm -rf "$STAGE"
SIZE=$(du -h "$DMG" | cut -f1)
echo "==> 完成: $(pwd)/$DMG ($SIZE)"
echo "    分发给用户:发这个 .dmg;用户按里面「② 如何打开(必读).txt」操作即可。"
