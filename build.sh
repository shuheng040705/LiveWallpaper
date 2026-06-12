#!/bin/bash
# 用 SwiftPM 构建,再打包成可运行的 .app(带 Info.plist → 菜单栏代理、固定 bundle id)。
set -e
cd "$(dirname "$0")"

CONFIG="${1:-release}"   # ./build.sh debug 出调试版
APP="LiveWallpaper.app"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"

BIN=".build/$CONFIG/LiveWallpaper"

echo "==> 打包 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/LiveWallpaper"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# app 图标(若已生成)
[ -f build_icon/AppIcon.icns ] && cp build_icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# 打包 WE 内置资源(粒子贴图 materials/ + 着色器 shaders/ + particles/ + effects/)进 bundle。
# 这样场景渲染读 app 包内文件,运行时不访问 ~/Documents,彻底消除「文稿」权限弹窗。
# ⚠ effects/ 必须打包:内置特效自带的相位/法线/流向贴图(如 waterflow 的 effects/waterflowphase、
#   waterripple 法线图)埋在 effects/<fx>/materials/effects/ 下,缺它则 g_Texture 辅助槽退白 →
#   屋檐水流不流、涟漪/晃动等位移类特效在打包版里全失效(headless 跑 ~/Documents/assets 看不出)。
ASSETS_SRC="${WE_ASSETS:-$HOME/Documents/assets}"
if [ -d "$ASSETS_SRC" ]; then
  mkdir -p "$APP/Contents/Resources/assets"
  for sub in materials shaders particles effects; do
    [ -d "$ASSETS_SRC/$sub" ] && cp -R "$ASSETS_SRC/$sub" "$APP/Contents/Resources/assets/" 2>/dev/null || true
  done
  echo "==> 已打包内置资源: $(du -sh "$APP/Contents/Resources/assets" 2>/dev/null | awk '{print $1}')"
fi

# 打包转译出的 WE 特效(manifest + MSL)进 bundle,供 WEEffectChain 加载真 WE 着色器。
if [ -f Tools/generated/WEEffects.json ]; then
  cp Tools/generated/WEEffects.json "$APP/Contents/Resources/WEEffects.json"
  cp -R Tools/generated/we_effects "$APP/Contents/Resources/we_effects" 2>/dev/null || true
  echo "==> 已打包 WE 转译特效: $(ls Tools/generated/we_effects/*.metal 2>/dev/null | wc -l | tr -d ' ') 个着色器"
fi

# 代码签名:优先用固定的自签名证书「LiveWallpaper Self-Signed」(签名身份稳定,
# 屏幕录制等 TCC 权限授权一次后永久记住,不会每次 build 都重新申请)。
# 没有该证书时回退 adhoc(每次 build 身份变,权限会重新询问)。
# 注:用不带 -v 的列表(证书是自签名「未受信任」,但签名不需要信任,只验证才需要)。
SIGN_HASH=$(security find-identity -p codesigning 2>/dev/null | grep "LiveWallpaper Self-Signed" | head -1 | awk '{print $2}')
if [ -n "$SIGN_HASH" ]; then
  codesign --force --deep --sign "$SIGN_HASH" "$APP" 2>/dev/null && echo "==> 已用固定证书签名(权限持久)" || codesign --force --sign - "$APP" 2>/dev/null || true
else
  codesign --force --sign - "$APP" 2>/dev/null || true
  echo "==> adhoc 签名(无固定证书;权限可能每次重问)"
fi

# 部署到 /Applications/(用户实际运行的位置)。重要:bundle id 相同时 `open` 会被 LaunchServices
# 重定向到已注册的 /Applications/ 副本,所以只构建到开发目录会让用户一直跑旧版。除非 NO_DEPLOY=1。
if [ "${NO_DEPLOY:-0}" != "1" ]; then
  echo "==> 部署到 /Applications/"
  killall LiveWallpaper 2>/dev/null && sleep 1 || true
  rm -rf /Applications/LiveWallpaper.app
  cp -R "$APP" /Applications/LiveWallpaper.app
  if [ -n "$SIGN_HASH" ]; then
    codesign --force --deep --sign "$SIGN_HASH" /Applications/LiveWallpaper.app 2>/dev/null || true
  fi
  /System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -f /Applications/LiveWallpaper.app 2>/dev/null || true
  echo "==> 已部署: /Applications/LiveWallpaper.app"
fi

echo "==> 完成: $(pwd)/$APP"
echo "运行:  open '/Applications/LiveWallpaper.app'"
echo "在 Xcode 里开发:  open '$(pwd)/Package.swift'"
