#!/bin/bash
# 把 LiveWallpaper.app 打包成可分发的 DMG。
# 用法: ./makedmg.sh   (先确保 ./build.sh release 已生成 LiveWallpaper.app)
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
# 软链 /Applications,让用户拖拽安装
ln -s /Applications "$STAGE/Applications"

echo "==> 生成 DMG"
hdiutil create -volname "$VOL" \
    -srcfolder "$STAGE" \
    -ov -format UDZO \
    "$DMG"

rm -rf "$STAGE"
SIZE=$(du -h "$DMG" | cut -f1)
echo "==> 完成: $(pwd)/$DMG ($SIZE)"
